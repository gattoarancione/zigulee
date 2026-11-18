// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The native X11 backend (`zigulee-x11`): shows a `zigulee.Window` in an X11
//! window, talking to the X server directly (protocol.zig: no Xlib, no
//! xcb). Same interface as the SDL3, macOS and Windows backends:
//!
//!     try x11.init();
//!     defer x11.deinit();
//!     const window = try x11.Window.create(gpa, &ui_window, .{ .title = "Hello" });
//!     defer window.destroy();
//!     try window.run();
//!
//! Windows draw with the software renderer; what changed is sent to the
//! server (PutImage). The scale is the desktop's `Xft.dpi` / 96. Keys are
//! read with the server's keyboard mapping (Shift, Caps Lock and AltGr
//! levels); input methods and dead keys are not supported yet. The
//! clipboard is the CLIPBOARD selection (UTF-8). Screen readers see the
//! accessible items through AT-SPI (src/backends/linux/atspi.zig). Wayland
//! desktops run it through XWayland.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const dnd = core.dnd;
const Rgba8 = core.Rgba8;
const input = core.input;
const Key = input.Key;
const atspi = @import("zigulee-atspi");
const webkitgtk = @import("zigulee-webkitgtk");
pub const protocol = @import("protocol.zig");
const op = protocol.op;
const ev = protocol.ev;
const le16 = protocol.le16;
const le32 = protocol.le32;
const u16Of = protocol.u16Of;
const i16Of = protocol.i16Of;
const u32Of = protocol.u32Of;
const c = std.c;

const log = std.log.scoped(.zigulee_x11);

pub const Error = protocol.Error;

pub const RendererKind = enum {
    /// The software renderer (the only one, for now).
    auto,
    software,
};

pub const Options = struct {
    title: [:0]const u8 = "zigulee",
    resizable: bool = true,
    renderer: RendererKind = .auto,
    /// Not shown (for tests, or shown later with `Window.show`).
    hidden: bool = false,
};

var start_ns: ?u64 = null;

fn monotonicNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Milliseconds since `init` (a monotonic clock): the clock zigulee's timers
/// and animations run on.
pub fn now() u64 {
    if (start_ns == null) start_ns = monotonicNs();
    return (monotonicNs() - start_ns.?) / std.time.ns_per_ms;
}

/// Milliseconds between animation frames.
const frame_interval = 16;

// ---- The application ----

const Atoms = struct {
    wm_protocols: u32 = 0,
    wm_delete_window: u32 = 0,
    net_wm_name: u32 = 0,
    net_wm_pid: u32 = 0,
    // Full screen, maximized and the like (EWMH).
    net_wm_state: u32 = 0,
    net_wm_state_fullscreen: u32 = 0,
    net_wm_state_maximized_vert: u32 = 0,
    net_wm_state_maximized_horz: u32 = 0,
    net_wm_state_above: u32 = 0,
    net_wm_state_hidden: u32 = 0,
    wm_change_state: u32 = 0,
    utf8_string: u32 = 0,
    clipboard: u32 = 0,
    targets: u32 = 0,
    text: u32 = 0,
    incr: u32 = 0,
    selection: u32 = 0,
    gtk_theme_variant: u32 = 0,
    // Drops from other applications (XDND).
    xdnd_aware: u32 = 0,
    xdnd_enter: u32 = 0,
    xdnd_position: u32 = 0,
    xdnd_status: u32 = 0,
    xdnd_leave: u32 = 0,
    xdnd_drop: u32 = 0,
    xdnd_finished: u32 = 0,
    xdnd_selection: u32 = 0,
    xdnd_type_list: u32 = 0,
    xdnd_action_copy: u32 = 0,
    uri_list: u32 = 0,
    text_plain_utf8: u32 = 0,
};

const App = struct {
    gpa: Allocator,
    conn: *protocol.Conn,
    atoms: Atoms = .{},
    /// Physical pixels per logical pixel (`Xft.dpi` / 96).
    scale: f32 = 1,
    cursor_font: u32 = 0,
    cursors: [@typeInfo(input.MouseCursor).@"enum".fields.len]u32 = @splat(0),
    /// What we put on the clipboard (while we own it).
    clipboard: ?[]u8 = null,
    /// Written to wake the loop (AT-SPI messages arrive on another thread).
    wake_pipe: [2]c.fd_t = .{ -1, -1 },
    /// A drag from another application (XDND): its source window, what it
    /// carries (`dnd.file_kind`, ...) as which type, where it is.
    dnd_source: u32 = 0,
    dnd_kind: []const u8 = "",
    dnd_type: u32 = 0,
    dnd_at: core.Point = .{},
    dnd_accepted: bool = false,
};

var app: ?App = null;
var open_windows: ?*Window = null;

/// Sound: the mixer plays through PipeWire (from `init` to `deinit`).
var audio_output: @import("zigulee-pipewire").Output = .{};

/// Connects to the X server (`DISPLAY`). Called by `Window.create` if
/// needed.
pub fn init() Error!void {
    if (app != null) return;
    _ = now();
    core.audio.mixer().setOutput(audio_output.output());
    core.video.addDecoder(@import("zigulee-gstreamer").decoder);
    core.dialogs.setFileDialogs(atspi.portal.provider);
    core.tray.setProvider(atspi.notifications.provider);
    core.links.setOpener(atspi.openuri.opener);
    core.webview.setProvider(webkitgtk.provider);
    const gpa = std.heap.c_allocator;
    const conn = try protocol.Conn.open(gpa);
    errdefer conn.close();
    var a: App = .{ .gpa = gpa, .conn = conn };
    inline for (@typeInfo(Atoms).@"struct".fields) |f| {
        const name = comptime atomName(f.name);
        @field(a.atoms, f.name) = try conn.internAtom(name);
    }
    a.scale = try desktopScale(conn);
    if (c.pipe(&a.wake_pipe) == 0) {
        atspi.wake = wake;
    } else a.wake_pipe = .{ -1, -1 };
    app = a;
}

fn atomName(comptime field: []const u8) []const u8 {
    @setEvalBranchQuota(10_000);
    if (std.mem.eql(u8, field, "selection")) return "ZIGULEE_SELECTION";
    if (std.mem.eql(u8, field, "net_wm_name")) return "_NET_WM_NAME";
    if (std.mem.eql(u8, field, "net_wm_pid")) return "_NET_WM_PID";
    if (std.mem.eql(u8, field, "gtk_theme_variant")) return "_GTK_THEME_VARIANT";
    if (comptime std.mem.startsWith(u8, field, "net_wm_state")) {
        comptime var name: []const u8 = "_";
        inline for (field) |ch| name = name ++ &[_]u8{std.ascii.toUpper(ch)};
        return name;
    }
    if (std.mem.eql(u8, field, "uri_list")) return "text/uri-list";
    if (std.mem.eql(u8, field, "text_plain_utf8")) return "text/plain;charset=utf-8";
    if (comptime std.mem.startsWith(u8, field, "xdnd_")) {
        // XdndEnter, XdndActionCopy, ...
        comptime var name: []const u8 = "Xdnd";
        comptime var upper = true;
        inline for (field["xdnd_".len..]) |ch| {
            if (ch == '_') {
                upper = true;
            } else {
                name = name ++ &[_]u8{if (upper) std.ascii.toUpper(ch) else ch};
                upper = false;
            }
        }
        return name;
    }
    var buf: [field.len]u8 = undefined;
    for (field, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
    const final = buf;
    return &final;
}

/// `Xft.dpi` / 96, from the desktop's resources (1 without them).
fn desktopScale(conn: *protocol.Conn) Error!f32 {
    const r = try conn.getProperty(conn.root, protocol.atom.resource_manager, protocol.atom.string, 1 << 16) orelse return 1;
    defer r.deinit(conn.gpa);
    const len = @min(r.u32At(16), r.data().len);
    var lines = std.mem.tokenizeScalar(u8, r.data()[0..len], '\n');
    while (lines.next()) |line| {
        const value = std.mem.cutPrefix(u8, line, "Xft.dpi:") orelse continue;
        const dpi = std.fmt.parseFloat(f32, std.mem.trim(u8, value, " \t")) catch continue;
        if (dpi >= 48) return @max(1, dpi / 96);
    }
    return 1;
}

/// Closes the connection, once every window is destroyed.
pub fn deinit() void {
    if (open_windows != null) return;
    const a = &(app orelse return);
    core.audio.mixer().setOutput(null);
    core.video.removeDecoder("gstreamer");
    core.dialogs.setFileDialogs(null);
    core.tray.setProvider(null);
    core.links.setOpener(null);
    core.webview.setProvider(null);
    if (a.clipboard) |t| a.gpa.free(t);
    if (a.wake_pipe[0] >= 0) {
        atspi.wake = null;
        _ = c.close(a.wake_pipe[0]);
        _ = c.close(a.wake_pipe[1]);
    }
    a.conn.close();
    app = null;
}

fn wake() void {
    const a = app orelse return;
    _ = c.write(a.wake_pipe[1], "w", 1);
}

/// One event loop iteration for every open window: waits for an event (at
/// most `max_wait_ms`, or until the next timer or animation frame),
/// handles the events, fires timers, runs change handlers and draws what
/// changed.
pub fn step(max_wait_ms: ?u32) Error!void {
    const a = &(app orelse return);
    core.updateTimersAndAnimations(now());
    var timeout: ?u64 = null; // null: until an event
    var it = open_windows;
    while (it) |w| : (it = w.next) if (w.needsFrame()) {
        const next = if (core.hasActiveAnimations() and !w.full_redraw and !w.ui.redraw_requested) w.last_frame + frame_interval else 0;
        const wait = next -| now();
        timeout = if (timeout) |t| @min(t, wait) else wait;
    };
    if (timeout == null) if (core.nextTimerDeadline()) |deadline| {
        timeout = deadline -| now();
    };
    if (max_wait_ms) |m| timeout = if (timeout) |t| @min(t, m) else m;

    try a.conn.flush();
    // The X connection, the wake pipe (ignored when -1) and what GLib's
    // loop waits for (web views).
    var fds: [2 + 64]c.pollfd = undefined;
    fds[0] = .{ .fd = a.conn.fd, .events = c.POLL.IN, .revents = 0 };
    fds[1] = .{ .fd = a.wake_pipe[0], .events = c.POLL.IN, .revents = 0 };
    const glib = webkitgtk.prepare(fds[2..], &timeout);
    if (a.conn.pending()) timeout = 0;
    if (timeout != 0 or glib > 0) {
        const ms: c_int = if (timeout) |t| @intCast(@min(t, std.math.maxInt(i32))) else -1;
        _ = c.poll(&fds, @intCast(2 + glib), ms);
        if (fds[1].revents != 0) {
            var buf: [64]u8 = undefined;
            _ = c.read(a.wake_pipe[0], &buf, buf.len);
        }
    }
    while (try a.conn.nextEvent(0)) |e| dispatch(&e);
    webkitgtk.dispatch(fds[2..][0..glib]);

    core.updateTimersAndAnimations(now());
    core.runChangeHandlers();
    it = open_windows;
    while (it) |w| : (it = w.next) try w.afterEvents();
    try a.conn.flush();
}

/// Runs the event loop until every window is closed (the application
/// destroys them afterwards).
pub fn runAll() Error!void {
    while (true) {
        var open = false;
        var it = open_windows;
        while (it) |w| : (it = w.next) open = open or !w.closed;
        if (!open) return;
        try step(null);
    }
}

fn windowFor(id: u32) ?*Window {
    var it = open_windows;
    while (it) |w| : (it = w.next) if (w.id == id) return w;
    return null;
}

/// Sends an event to the window it is for.
fn dispatch(e: *const protocol.Event) void {
    const a = &app.?;
    const kind = e[0] & 0x7f;
    const id: u32 = switch (kind) {
        ev.key_press, ev.key_release, ev.button_press, ev.button_release, ev.motion_notify, ev.enter_notify, ev.leave_notify => u32Of(e, 12),
        ev.focus_in, ev.focus_out, ev.expose, ev.map_notify, ev.configure_notify, ev.client_message, ev.property_notify => u32Of(e, 4),
        ev.selection_request, ev.selection_clear => u32Of(e, 8),
        ev.mapping_notify => {
            if (e[4] == 1) a.conn.loadKeymap() catch |err| log.warn("keyboard mapping: {t}", .{err});
            return;
        },
        else => return,
    };
    const w = windowFor(id) orelse return;
    w.handle(e);
}

// ---- Windows ----

pub const Window = struct {
    gpa: Allocator,
    ui: *core.Window,
    id: u32 = 0,
    gc: u32 = 0,
    /// The software renderer's framebuffer, in physical pixels (kept
    /// between frames: only what changed is redrawn), and what the window
    /// shows of it, as the server's pixels (0xRRGGBB).
    framebuffer: []Rgba8 = &.{},
    shown: []u32 = &.{},
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,
    software: zigulee.software.Renderer(Rgba8),
    full_redraw: bool = true,
    /// Set when the user closes the window; `run` returns.
    closed: bool = false,
    mapped: bool = false,
    last_frame: u64 = 0,
    a11y: ?*atspi.Bridge = null,
    cursor: input.MouseCursor = .default,
    /// The color scheme the title bar shows.
    scheme: ?core.ColorScheme = null,
    /// Full screen, maximized and the like, as asked and as shown.
    state: core.WindowStateSync = .{},
    focused: bool = false,
    /// The keyboard went to a child window (a web view's).
    focus_in_child: bool = false,
    /// The window as web views see it (`native_view`).
    web_host: webkitgtk.Host = .{},
    /// On the screen (pixels), for assistive technology; stale after a
    /// move until asked again.
    position: [2]i32 = .{ 0, 0 },
    position_stale: bool = true,
    next: ?*Window = null,

    /// Opens a window showing `ui`, sized to `ui.size()` in logical pixels
    /// (scaled for the desktop). `ui` must outlive the window.
    pub fn create(gpa: Allocator, ui: *core.Window, options: Options) Error!*Window {
        try init();
        const a = &app.?;
        const conn = a.conn;
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .ui = ui, .software = .init(gpa) };
        errdefer self.software.deinit();
        errdefer self.freeBuffers();
        self.software.scale_factor = a.scale;

        const size = ui.size();
        const width: u16 = @intFromFloat(@max(1, @round(size.width * a.scale)));
        const height: u16 = @intFromFloat(@max(1, @round(size.height * a.scale)));
        self.id = conn.newId();
        // Values in the order of their mask bits: background (none: no
        // flashing on resize), events.
        const events: u32 = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x8000 | 0x20000 | 0x200000 | 0x400000;
        _ = try conn.request(op.create_window, 0, &.{
            &le32(self.id), &le32(conn.root), &le16(0), &le16(0),
            &le16(width), &le16(height), &le16(0), &le16(1), // input-output
            &le32(0), // the parent's visual
            &le32(0x1 | 0x800),
            &le32(0),
            &le32(events),
        });
        errdefer _ = conn.request(op.destroy_window, 0, &.{&le32(self.id)}) catch {};
        try self.setTitleChecked(options.title);
        try conn.changeProperty(self.id, protocol.atom.wm_class, protocol.atom.string, 8, "zigulee\x00Zigulee\x00");
        try conn.changeProperty(self.id, a.atoms.wm_protocols, protocol.atom.atom_, 32, &le32(a.atoms.wm_delete_window));
        try conn.changeProperty(self.id, a.atoms.net_wm_pid, protocol.atom.cardinal, 32, &le32(@intCast(c.getpid())));
        // Takes drops from other applications (XDND version 5).
        try conn.changeProperty(self.id, a.atoms.xdnd_aware, protocol.atom.atom_, 32, &le32(5));
        if (!options.resizable) {
            // WM_NORMAL_HINTS: the same minimum and maximum size.
            var hints: [18 * 4]u8 = @splat(0);
            std.mem.writeInt(u32, hints[0..4], 16 | 32, .little); // PMinSize | PMaxSize
            for ([_]usize{ 5, 7 }) |i| {
                std.mem.writeInt(u32, hints[i * 4 ..][0..4], width, .little);
                std.mem.writeInt(u32, hints[(i + 1) * 4 ..][0..4], height, .little);
            }
            try conn.changeProperty(self.id, protocol.atom.wm_normal_hints, protocol.atom.wm_size_hints, 32, &hints);
        }
        self.gc = conn.newId();
        _ = try conn.request(op.create_gc, 0, &.{ &le32(self.gc), &le32(self.id), &le32(0x10000), &le32(0) }); // no GraphicsExpose
        try self.syncSize(width, height);

        ui.clipboard = .{ .ctx = self, .getFn = getClipboard, .setFn = setClipboard };
        errdefer ui.clipboard = null;
        self.web_host = .{ .window = self.id, .scale = a.scale };
        ui.native_view = &self.web_host;
        errdefer ui.native_view = null;
        self.startAccessibility(options.title);
        self.updateScheme() catch {};
        if (!options.hidden) try self.show();
        try conn.flush();
        self.next = open_windows;
        open_windows = self;
        return self;
    }

    pub fn show(self: *Window) Error!void {
        _ = try app.?.conn.request(op.map_window, 0, &.{&le32(self.id)});
        try app.?.conn.flush();
    }

    pub fn destroy(self: *Window) void {
        var link = &open_windows;
        while (link.*) |w| : (link = &w.next) if (w == self) {
            link.* = self.next;
            break;
        };
        if (self.a11y) |b| b.destroy();
        self.ui.clipboard = null;
        self.ui.native_view = null;
        webkitgtk.detach(&self.web_host);
        if (app) |a| {
            _ = a.conn.request(op.free_gc, 0, &.{&le32(self.gc)}) catch {};
            _ = a.conn.request(op.destroy_window, 0, &.{&le32(self.id)}) catch {};
            a.conn.flush() catch {};
        }
        self.software.deinit();
        self.freeBuffers();
        self.gpa.destroy(self);
    }

    fn freeBuffers(self: *Window) void {
        self.gpa.free(self.framebuffer);
        self.gpa.free(self.shown);
        self.framebuffer = &.{};
        self.shown = &.{};
    }

    fn startAccessibility(self: *Window, title: []const u8) void {
        self.a11y = atspi.Bridge.create(self.gpa, self.ui, .{}) catch |err| {
            log.info("no screen reader support (AT-SPI: {t})", .{err});
            return;
        };
        self.a11y.?.title = title;
    }

    /// Shows another zigulee window in this one (live reloading), sized to
    /// the current window. `ui` must outlive the window or the next call.
    pub fn setUi(self: *Window, ui: *core.Window) Error!void {
        self.ui.clipboard = null;
        self.ui.native_view = null;
        const title = if (self.a11y) |b| b.title else "";
        if (self.a11y) |b| b.destroy();
        self.a11y = null;
        self.ui = ui;
        ui.clipboard = .{ .ctx = self, .getFn = getClipboard, .setFn = setClipboard };
        ui.native_view = &self.web_host;
        self.startAccessibility(title);
        ui.setSize(.{ .width = @as(f32, @floatFromInt(self.pixel_width)) / self.software.scale_factor, .height = @as(f32, @floatFromInt(self.pixel_height)) / self.software.scale_factor });
        self.full_redraw = true;
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        self.setTitleChecked(title) catch {};
    }

    fn setTitleChecked(self: *Window, title: []const u8) Error!void {
        const a = &app.?;
        try a.conn.changeProperty(self.id, a.atoms.net_wm_name, a.atoms.utf8_string, 8, title);
        try a.conn.changeProperty(self.id, protocol.atom.wm_name, protocol.atom.string, 8, title);
    }

    /// Physical pixels per logical pixel.
    pub fn scaleFactor(self: *const Window) f32 {
        return self.software.scale_factor;
    }

    /// Runs the event loop until this window is closed (other open windows
    /// keep working meanwhile).
    pub fn run(self: *Window) Error!void {
        while (!self.closed) try self.step(null);
    }

    /// One event loop iteration, for every open window (see `step`).
    pub fn step(_: *Window, max_wait_ms: ?u32) Error!void {
        return step_(max_wait_ms);
    }

    fn needsFrame(self: *const Window) bool {
        return self.full_redraw or self.ui.redraw_requested or core.hasActiveAnimations();
    }

    /// After a round of events: a frame if anything changed, the cursor,
    /// the title bar's scheme and what assistive technology sees.
    fn afterEvents(self: *Window) Error!void {
        if (self.needsFrame()) try self.render();
        try self.updateScheme();
        try self.updateState();
        try self.updateCursor();
        if (self.a11y) |b| {
            if (self.position_stale and self.mapped) try self.queryPosition();
            b.scale = self.software.scale_factor;
            b.position = self.position;
            b.setActive(self.focused);
            b.update() catch |err| if (err == error.OutOfMemory) return error.OutOfMemory;
        }
    }

    /// XDND client messages: a drag from another application entering,
    /// moving over, leaving or dropped on the window.
    fn xdnd(self: *Window, kind: u32, e: *const protocol.Event) Error!void {
        const a = &app.?;
        const l = [5]u32{ u32Of(e, 12), u32Of(e, 16), u32Of(e, 20), u32Of(e, 24), u32Of(e, 28) };
        if (kind == a.atoms.xdnd_enter) {
            a.dnd_source = l[0];
            a.dnd_accepted = false;
            // Its types: in the message, or (more than three) on the source.
            var types: std.ArrayList(u32) = .empty;
            defer types.deinit(a.gpa);
            if (l[1] & 1 != 0) {
                if (try a.conn.getProperty(l[0], a.atoms.xdnd_type_list, protocol.atom.atom_, 4096)) |r| {
                    defer r.deinit(a.conn.gpa);
                    const d = r.data();
                    var i: usize = 0;
                    while (i + 4 <= d.len) : (i += 4) try types.append(a.gpa, std.mem.readInt(u32, d[i..][0..4], .little));
                }
            } else for (l[2..5]) |t| if (t != 0) try types.append(a.gpa, t);
            a.dnd_kind = "";
            a.dnd_type = 0;
            for (types.items) |t| if (t == a.atoms.uri_list) {
                a.dnd_kind = dnd.file_kind;
                a.dnd_type = t;
            };
            if (a.dnd_type == 0) for ([_]u32{ a.atoms.utf8_string, a.atoms.text_plain_utf8, protocol.atom.string }) |want| {
                if (std.mem.indexOfScalar(u32, types.items, want) != null) {
                    a.dnd_kind = dnd.text_kind;
                    a.dnd_type = want;
                    break;
                }
            };
        } else if (kind == a.atoms.xdnd_position) {
            if (l[0] != a.dnd_source) return;
            if (self.position_stale) try self.queryPosition();
            const s = self.software.scale_factor;
            const root_x: i32 = @as(i16, @bitCast(@as(u16, @truncate(l[2] >> 16))));
            const root_y: i32 = @as(i16, @bitCast(@as(u16, @truncate(l[2]))));
            a.dnd_at = .{ .x = @as(f32, @floatFromInt(root_x - self.position[0])) / s, .y = @as(f32, @floatFromInt(root_y - self.position[1])) / s };
            a.dnd_accepted = a.dnd_kind.len > 0 and dnd.externalMoved(self.ui, &.{a.dnd_kind}, a.dnd_at);
            // XdndStatus: accepted (and more positions wanted), with copying.
            try self.xdndSend(a.atoms.xdnd_status, .{ self.id, @as(u32, if (a.dnd_accepted) 1 else 0) | 2, 0, 0, if (a.dnd_accepted) a.atoms.xdnd_action_copy else 0 });
        } else if (kind == a.atoms.xdnd_leave) {
            if (l[0] != a.dnd_source) return;
            dnd.externalLeft(self.ui);
            a.dnd_source = 0;
        } else if (kind == a.atoms.xdnd_drop) {
            if (l[0] != a.dnd_source) return;
            const source = a.dnd_source;
            a.dnd_source = 0;
            var taken = false;
            if (a.dnd_accepted) {
                if (try convertSelection(self, a.gpa, a.atoms.xdnd_selection, a.dnd_type, l[2])) |data| {
                    defer a.gpa.free(data);
                    if (std.mem.eql(u8, a.dnd_kind, dnd.file_kind)) {
                        const paths = try dnd.pathsFromUriList(a.gpa, data);
                        defer a.gpa.free(paths);
                        taken = dnd.externalDropped(self.ui, dnd.file_kind, paths, a.dnd_at);
                    } else taken = dnd.externalDropped(self.ui, dnd.text_kind, data, a.dnd_at);
                }
            }
            if (!taken) dnd.externalLeft(self.ui);
            // XdndFinished: to the source, whether it was taken.
            a.dnd_source = source;
            defer a.dnd_source = 0;
            try self.xdndSend(a.atoms.xdnd_finished, .{ self.id, @intFromBool(taken), if (taken) a.atoms.xdnd_action_copy else 0, 0, 0 });
        }
    }

    /// An XDND client message to the drag's source.
    fn xdndSend(self: *Window, kind: u32, l: [5]u32) Error!void {
        _ = self;
        const a = &app.?;
        var e: protocol.Event = @splat(0);
        e[0] = ev.client_message;
        e[1] = 32;
        @memcpy(e[4..8], &le32(a.dnd_source));
        @memcpy(e[8..12], &le32(kind));
        for (l, 0..) |v, i| @memcpy(e[12 + 4 * i ..][0..4], &le32(v));
        try a.conn.sendEvent(a.dnd_source, 0, &e);
        try a.conn.flush();
    }

    /// The window put in the state the app asks for, if that changed (once
    /// mapped: the window manager only takes requests then).
    fn updateState(self: *Window) Error!void {
        if (!self.mapped) return;
        const a = &app.?;
        const before = self.state.shown;
        const want = self.state.sync(self.ui) orelse return;
        if (want.fullscreen != before.fullscreen) try self.netWmState(want.fullscreen, a.atoms.net_wm_state_fullscreen, 0);
        if (want.maximized != before.maximized) try self.netWmState(want.maximized, a.atoms.net_wm_state_maximized_vert, a.atoms.net_wm_state_maximized_horz);
        if (want.always_on_top != before.always_on_top) try self.netWmState(want.always_on_top, a.atoms.net_wm_state_above, 0);
        if (want.minimized != before.minimized) {
            if (want.minimized) {
                // ICCCM: iconic state.
                try self.rootMessage(a.atoms.wm_change_state, .{ 3, 0, 0, 0, 0 });
            } else _ = try a.conn.request(op.map_window, 0, &.{&le32(self.id)});
        }
        try a.conn.flush();
    }

    /// Asks the window manager to add or remove states (EWMH).
    fn netWmState(self: *Window, on: bool, first: u32, second: u32) Error!void {
        try self.rootMessage(app.?.atoms.net_wm_state, .{ @intFromBool(on), first, second, 1, 0 });
    }

    /// A client message about this window to the window manager.
    fn rootMessage(self: *Window, kind: u32, l: [5]u32) Error!void {
        const conn = app.?.conn;
        var e: protocol.Event = @splat(0);
        e[0] = ev.client_message;
        e[1] = 32;
        @memcpy(e[4..8], &le32(self.id));
        @memcpy(e[8..12], &le32(kind));
        for (l, 0..) |v, i| @memcpy(e[12 + 4 * i ..][0..4], &le32(v));
        // Substructure redirect and notify.
        try conn.sendEvent(conn.root, 0x100000 | 0x80000, &e);
    }

    /// The states the window manager says the window is in.
    fn reportState(self: *Window) Error!void {
        const a = &app.?;
        var s: core.WindowState = .{};
        if (try a.conn.getProperty(self.id, a.atoms.net_wm_state, protocol.atom.atom_, 1024)) |r| {
            defer r.deinit(a.conn.gpa);
            const n = @min(r.u32At(16), r.data().len / 4);
            var vert = false;
            var horz = false;
            for (0..n) |i| {
                const atom = std.mem.readInt(u32, r.data()[4 * i ..][0..4], .little);
                if (atom == a.atoms.net_wm_state_fullscreen) s.fullscreen = true;
                if (atom == a.atoms.net_wm_state_maximized_vert) vert = true;
                if (atom == a.atoms.net_wm_state_maximized_horz) horz = true;
                if (atom == a.atoms.net_wm_state_above) s.always_on_top = true;
                if (atom == a.atoms.net_wm_state_hidden) s.minimized = true;
            }
            s.maximized = vert and horz;
        }
        self.state.report(self.ui, s);
    }

    /// Where the window is on the screen.
    fn queryPosition(self: *Window) Error!void {
        const conn = app.?.conn;
        const seq = try conn.request(op.translate_coordinates, 0, &.{ &le32(self.id), &le32(conn.root), &le16(0), &le16(0) });
        const r = try conn.reply(seq);
        defer r.deinit(conn.gpa);
        self.position = .{ @as(i16, @bitCast(r.u16At(12))), @as(i16, @bitCast(r.u16At(14))) };
        self.position_stale = false;
    }

    /// Follows the window's size in pixels.
    fn syncSize(self: *Window, width: u32, height: u32) Error!void {
        const s = self.software.scale_factor;
        self.ui.setSize(.{ .width = @as(f32, @floatFromInt(width)) / s, .height = @as(f32, @floatFromInt(height)) / s });
        self.full_redraw = true;
        if (width == self.pixel_width and height == self.pixel_height and self.framebuffer.len > 0) return;
        const n = @as(usize, width) * height;
        const framebuffer = try self.gpa.alloc(Rgba8, n);
        errdefer self.gpa.free(framebuffer);
        const shown = try self.gpa.alloc(u32, n);
        @memset(framebuffer, .transparent);
        @memset(shown, 0);
        self.freeBuffers();
        self.framebuffer = framebuffer;
        self.shown = shown;
        self.pixel_width = width;
        self.pixel_height = height;
    }

    /// Draws what changed and shows it.
    pub fn render(self: *Window) Error!void {
        self.last_frame = now();
        const canvas: zigulee.software.Canvas(Rgba8) = .init(self.framebuffer, self.pixel_width, self.pixel_height);
        const region = try self.software.renderWindow(self.ui, canvas, if (self.full_redraw) .full else .partial);
        self.full_redraw = false;
        if (region.isEmpty()) return;
        // What changed, converted to the server's pixels and sent (whole
        // rows: they are contiguous).
        const box = region.boundingBox();
        const x0: u32 = @intFromFloat(std.math.clamp(@floor(box.x), 0, @as(f32, @floatFromInt(self.pixel_width))));
        const y0: u32 = @intFromFloat(std.math.clamp(@floor(box.y), 0, @as(f32, @floatFromInt(self.pixel_height))));
        const x1: u32 = @intFromFloat(std.math.clamp(@ceil(box.x + box.width), 0, @as(f32, @floatFromInt(self.pixel_width))));
        const y1: u32 = @intFromFloat(std.math.clamp(@ceil(box.y + box.height), 0, @as(f32, @floatFromInt(self.pixel_height))));
        if (x0 >= x1 or y0 >= y1) return;
        for (y0..y1) |y| {
            const row = y * self.pixel_width;
            for (self.framebuffer[row + x0 .. row + x1], self.shown[row + x0 .. row + x1]) |p, *q|
                q.* = @as(u32, p.r) << 16 | @as(u32, p.g) << 8 | p.b;
        }
        try self.blit(y0, y1);
    }

    /// Sends rows y0..y1 of `shown` to the window, in requests the server
    /// accepts.
    fn blit(self: *Window, y0: u32, y1: u32) Error!void {
        if (!self.mapped or self.shown.len == 0) return;
        const conn = app.?.conn;
        const row_bytes = @as(usize, self.pixel_width) * 4;
        const per_request: u32 = @intCast(@max(1, (conn.max_request - 24) / row_bytes));
        var y = y0;
        while (y < y1) {
            const rows = @min(per_request, y1 - y);
            const bytes = std.mem.sliceAsBytes(self.shown[@as(usize, y) * self.pixel_width ..][0 .. @as(usize, rows) * self.pixel_width]);
            _ = try conn.request(op.put_image, 2, &.{ // ZPixmap
                &le32(self.id),                    &le32(self.gc),
                &le16(@intCast(self.pixel_width)), &le16(@intCast(rows)),
                &le16(0),                          &le16(@intCast(y)),
                &.{ 0, 24, 0, 0 }, // left pad, depth
                bytes,
            });
            y += rows;
        }
    }

    /// The title bar light or dark, as the window's content (window
    /// managers that read GTK's hint).
    fn updateScheme(self: *Window) Error!void {
        const scheme = self.ui.colorScheme();
        if (self.scheme == scheme) return;
        self.scheme = scheme;
        const a = &app.?;
        try a.conn.changeProperty(self.id, a.atoms.gtk_theme_variant, a.atoms.utf8_string, 8, if (scheme == .dark) "dark" else "light");
    }

    /// The cursor the window asks for (the server shows it over the
    /// window).
    fn updateCursor(self: *Window) Error!void {
        const want = self.ui.mouseCursor();
        if (want == self.cursor) return;
        self.cursor = want;
        const cursor = try cursorFor(want);
        _ = try app.?.conn.request(op.change_window_attributes, 0, &.{ &le32(self.id), &le32(0x4000), &le32(cursor) });
    }

    // ---- Events ----

    fn point(self: *const Window, e: *const protocol.Event) core.Point {
        const s = self.software.scale_factor;
        return .{ .x = @as(f32, @floatFromInt(i16Of(e, 24))) / s, .y = @as(f32, @floatFromInt(i16Of(e, 26))) / s };
    }

    /// Logical pixels scrolled per wheel notch.
    const wheel_step = 40;

    fn handle(self: *Window, e: *const protocol.Event) void {
        const a = &app.?;
        switch (e[0] & 0x7f) {
            ev.key_press => self.key(e, true),
            ev.key_release => self.key(e, false),
            ev.button_press => {
                const p = self.point(e);
                const delta: ?core.Point = switch (e[1]) {
                    4 => .{ .x = 0, .y = wheel_step },
                    5 => .{ .x = 0, .y = -wheel_step },
                    6 => .{ .x = wheel_step, .y = 0 },
                    7 => .{ .x = -wheel_step, .y = 0 },
                    else => null,
                };
                if (delta) |d| return self.ui.dispatchPointer(.{ .wheel = .{ .position = p, .delta = d } });
                // The keyboard back from a web view.
                if (self.focus_in_child) {
                    _ = a.conn.request(op.set_input_focus, 2, &.{ &le32(self.id), &le32(u32Of(e, 4)) }) catch {}; // revert to the parent
                    self.focus_in_child = false;
                }
                self.ui.dispatchPointer(.{ .pressed = .{ .position = p, .button = button(e[1]), .modifiers = modifiers(u16Of(e, 28)) } });
            },
            ev.button_release => {
                if (e[1] >= 4 and e[1] <= 7) return;
                self.ui.dispatchPointer(.{ .released = .{ .position = self.point(e), .button = button(e[1]) } });
            },
            ev.motion_notify => self.ui.dispatchPointer(.{ .moved = .{ .position = self.point(e) } }),
            ev.leave_notify => {
                // Not while a button is held (the pointer is grabbed), unless
                // the grab just ended.
                const buttons_held = u16Of(e, 28) & 0x1f00 != 0;
                if (!buttons_held or e[30] == 2) self.ui.dispatchPointer(.exit);
            },
            ev.focus_in, ev.focus_out => if (e[1] != 5) { // not NotifyPointer
                self.focused = e[0] & 0x7f == ev.focus_in;
                // NotifyInferior: to a child window.
                self.focus_in_child = !self.focused and e[1] == 2;
            },
            ev.expose => {
                const y = u16Of(e, 10);
                const h = u16Of(e, 14);
                self.blit(y, @min(self.pixel_height, @as(u32, y) + h)) catch |err| log.warn("expose: {t}", .{err});
            },
            ev.map_notify => {
                self.mapped = true;
                self.full_redraw = true;
            },
            ev.property_notify => if (u32Of(e, 8) == a.atoms.net_wm_state) {
                self.reportState() catch |err| log.warn("window state: {t}", .{err});
            },
            ev.configure_notify => {
                const w = u16Of(e, 20);
                const h = u16Of(e, 22);
                // Synthetic ones (from the window manager) say where the
                // window is on the screen.
                if (e[0] & 0x80 != 0) {
                    self.position = .{ i16Of(e, 16), i16Of(e, 18) };
                    self.position_stale = false;
                } else self.position_stale = true;
                if (w != self.pixel_width or h != self.pixel_height) self.syncSize(w, h) catch log.err("could not resize the framebuffer", .{});
            },
            ev.client_message => {
                const kind = u32Of(e, 8);
                if (kind == a.atoms.wm_protocols and u32Of(e, 12) == a.atoms.wm_delete_window) self.closed = true;
                self.xdnd(kind, e) catch |err| log.info("drop: {t}", .{err});
            },
            ev.selection_request => answerSelectionRequest(e) catch |err| log.warn("clipboard: {t}", .{err}),
            ev.selection_clear => if (u32Of(e, 12) == a.atoms.clipboard) {
                if (a.clipboard) |t| a.gpa.free(t);
                a.clipboard = null;
            },
            else => {},
        }
    }

    fn key(self: *Window, e: *const protocol.Event, pressed: bool) void {
        const conn = app.?.conn;
        const keycode = e[1];
        const state = u16Of(e, 28);
        const mods = modifiers(state);
        const kind: input.KeyEventKind = if (pressed) .pressed else .released;
        const base = conn.keysym(keycode, 0);
        if (specialKey(base, mods)) |text| return self.ui.dispatchKey(kind, .{ .text = text, .modifiers = mods });
        const altgr = state & 0x80 != 0; // Mod5: ISO_Level3_Shift
        // Shortcuts (Ctrl+C, Ctrl+S, ...): the key, unshifted.
        if (mods.control and !altgr) {
            if (base < 0x80 and (std.ascii.isAlphanumeric(@intCast(base)))) {
                return self.ui.dispatchKey(kind, .{ .text = ascii[std.ascii.toLower(@intCast(base))..][0..1], .modifiers = mods });
            }
        }
        if (!pressed) return;
        // Text: the keysym at the level Shift, Caps Lock and AltGr select.
        const letter = base < 0x80 and std.ascii.isAlphabetic(@intCast(base));
        const shifted = mods.shift != (state & 0x2 != 0 and letter);
        var level: usize = @intFromBool(shifted);
        if (altgr and conn.keysym(keycode, 4 + level) != 0) level += 4;
        var sym = conn.keysym(keycode, level);
        if (sym == 0) sym = base;
        if (shifted and level == 1 and sym == base and letter) sym = std.ascii.toUpper(@intCast(base));
        const cp = protocol.keysymToCodepoint(sym) orelse return;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        self.ui.dispatchKey(.pressed, .{ .text = buf[0..n] });
        self.ui.dispatchKey(.released, .{ .text = buf[0..n] });
    }
};

const step_ = step;

fn button(detail: u8) input.PointerButton {
    return switch (detail) {
        1 => .left,
        2 => .middle,
        3 => .right,
        else => .other,
    };
}

fn modifiers(state: u16) input.Modifiers {
    return .{
        .shift = state & 0x1 != 0,
        .control = state & 0x4 != 0,
        .alt = state & 0x8 != 0, // Mod1
        .meta = state & 0x40 != 0, // Mod4
    };
}

const ascii: [128]u8 = blk: {
    var t: [128]u8 = undefined;
    for (&t, 0..) |*b, i| b.* = i;
    break :blk t;
};

/// zigulee's code for a special key, from its keysym.
fn specialKey(sym: u32, mods: input.Modifiers) ?[]const u8 {
    return switch (sym) {
        0xff08 => Key.backspace,
        0xff09 => if (mods.shift) Key.back_tab else Key.tab,
        0xfe20 => Key.back_tab, // ISO_Left_Tab
        0xff0d, 0xff8d => Key.@"return",
        0xff1b => Key.escape,
        0xffff, 0xff9f => Key.delete,
        0xff51, 0xff96 => Key.left_arrow,
        0xff52, 0xff97 => Key.up_arrow,
        0xff53, 0xff98 => Key.right_arrow,
        0xff54, 0xff99 => Key.down_arrow,
        0xff50, 0xff95 => Key.home,
        0xff57, 0xff9c => Key.end,
        0xff55, 0xff9a => Key.page_up,
        0xff56, 0xff9b => Key.page_down,
        else => null,
    };
}

/// The server's cursor for a shape (from the cursor font; none: an empty
/// one), created once.
fn cursorFor(shape: input.MouseCursor) Error!u32 {
    const a = &app.?;
    const conn = a.conn;
    const slot = &a.cursors[@intFromEnum(shape)];
    if (slot.* != 0) return slot.*;
    const id = conn.newId();
    if (shape == .none) {
        const pixmap = conn.newId();
        _ = try conn.request(op.create_pixmap, 1, &.{ &le32(pixmap), &le32(conn.root), &le16(1), &le16(1) });
        _ = try conn.request(op.create_cursor, 0, &.{ &le32(id), &le32(pixmap), &le32(pixmap), &@as([12]u8, @splat(0)), &le16(0), &le16(0) });
        _ = try conn.request(op.free_pixmap, 0, &.{&le32(pixmap)});
    } else {
        if (a.cursor_font == 0) {
            a.cursor_font = conn.newId();
            const name = "cursor";
            _ = try conn.request(op.open_font, 0, &.{ &le32(a.cursor_font), &le16(name.len), &.{ 0, 0 }, name });
        }
        const glyph: u16 = switch (shape) {
            .default, .none => 68, // left_ptr
            .text => 152, // xterm
            .pointer => 60, // hand2
            .crosshair => 34,
            .wait, .progress => 150, // watch
            .help => 92, // question_arrow
            .move, .grab, .grabbing => 52, // fleur
            .not_allowed => 0, // X_cursor
            .col_resize, .ew_resize => 108, // sb_h_double_arrow
            .row_resize, .ns_resize => 116, // sb_v_double_arrow
            .nwse_resize => 14, // bottom_right_corner
            .nesw_resize => 12, // bottom_left_corner
        };
        // Black on white.
        const white: [6]u8 = @splat(0xff);
        _ = try conn.request(op.create_glyph_cursor, 0, &.{ &le32(id), &le32(a.cursor_font), &le32(a.cursor_font), &le16(glyph), &le16(glyph + 1), &@as([6]u8, @splat(0)), &white });
    }
    slot.* = id;
    return id;
}

// ---- The clipboard (the CLIPBOARD selection) ----

fn getClipboard(ctx: ?*anyopaque, gpa: Allocator) ?[]u8 {
    const w: *Window = @ptrCast(@alignCast(ctx orelse return null));
    return requestClipboard(w, gpa) catch |err| {
        log.info("clipboard: {t}", .{err});
        return null;
    };
}

/// Asks the clipboard's owner for its text (UTF-8), and waits for it (at
/// most 1 s, answering requests meanwhile: the owner may be us).
fn requestClipboard(w: *Window, gpa: Allocator) Error!?[]u8 {
    const a = &app.?;
    return convertSelection(w, gpa, a.atoms.clipboard, a.atoms.utf8_string, 0);
}

/// Asks `selection`'s owner for it as `target`, and waits for it (as
/// `requestClipboard`).
fn convertSelection(w: *Window, gpa: Allocator, selection: u32, target: u32, time: u32) Error!?[]u8 {
    const a = &app.?;
    const conn = a.conn;
    _ = try conn.request(op.convert_selection, 0, &.{ &le32(w.id), &le32(selection), &le32(target), &le32(a.atoms.selection), &le32(time) });
    var kept: std.ArrayList(protocol.Event) = .empty;
    defer {
        // Other events, back for the loop.
        conn.events.insertSlice(conn.gpa, 0, kept.items) catch {};
        kept.deinit(gpa);
    }
    const until = now() + 1000;
    const property = while (true) {
        const left = until -| now();
        if (left == 0) return error.Timeout;
        const e = try conn.nextEvent(@intCast(left)) orelse continue;
        switch (e[0] & 0x7f) {
            ev.selection_notify => if (u32Of(&e, 4 + 4) == w.id) break u32Of(&e, 20),
            ev.selection_request => {
                answerSelectionRequest(&e) catch {};
                continue;
            },
            else => {},
        }
        try kept.append(gpa, e);
    };
    if (property == 0) return null; // no owner, or no text
    const r = try conn.getProperty(w.id, a.atoms.selection, 0, 16 << 20) orelse return null;
    defer r.deinit(conn.gpa);
    _ = try conn.request(op.delete_property, 0, &.{ &le32(w.id), &le32(a.atoms.selection) });
    if (r.u32At(8) == a.atoms.incr) return null; // sent in pieces: not supported
    const bytes = @min(@as(usize, r.u32At(16)) * (r.u8At(1) / 8), r.data().len);
    return try gpa.dupe(u8, r.data()[0..bytes]);
}

fn setClipboard(ctx: ?*anyopaque, text: []const u8) void {
    const w: *Window = @ptrCast(@alignCast(ctx orelse return));
    const a = &app.?;
    const copy = a.gpa.dupe(u8, text) catch return;
    if (a.clipboard) |t| a.gpa.free(t);
    a.clipboard = copy;
    _ = a.conn.request(op.set_selection_owner, 0, &.{ &le32(w.id), &le32(a.atoms.clipboard), &le32(0) }) catch {};
    a.conn.flush() catch {};
}

/// Another client (or we) asks for the clipboard's text.
fn answerSelectionRequest(e: *const protocol.Event) Error!void {
    const a = &app.?;
    const conn = a.conn;
    const time = u32Of(e, 4);
    const requestor = u32Of(e, 12);
    const selection = u32Of(e, 16);
    const target = u32Of(e, 20);
    var property = u32Of(e, 24);
    if (property == 0) property = target; // obsolete clients
    if (selection != a.atoms.clipboard or a.clipboard == null) {
        property = 0;
    } else if (target == a.atoms.targets) {
        const targets = le32(a.atoms.targets) ++ le32(a.atoms.utf8_string) ++ le32(protocol.atom.string) ++ le32(a.atoms.text);
        try conn.changeProperty(requestor, property, protocol.atom.atom_, 32, &targets);
    } else if (target == a.atoms.utf8_string or target == protocol.atom.string or target == a.atoms.text) {
        const kind = if (target == protocol.atom.string) protocol.atom.string else a.atoms.utf8_string;
        try conn.changeProperty(requestor, property, kind, 8, a.clipboard.?);
    } else property = 0;
    var notify: protocol.Event = @splat(0);
    notify[0] = ev.selection_notify;
    @memcpy(notify[4..8], &le32(time));
    @memcpy(notify[8..12], &le32(requestor));
    @memcpy(notify[12..16], &le32(selection));
    @memcpy(notify[16..20], &le32(target));
    @memcpy(notify[20..24], &le32(property));
    try conn.sendEvent(requestor, 0, &notify);
    try conn.flush();
}

// ---- Tests (on an X server: `xvfb-run zig build test-x11`) ----

const testing = std.testing;

fn initOrSkip() !void {
    init() catch |err| {
        log.info("no X server ({t}): skipped", .{err});
        return error.SkipZigTest;
    };
}

/// Steps the loop until `cond(ctx)` (at most 2 s).
fn stepUntil(ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
    const until = now() + 2000;
    while (!cond(ctx)) {
        if (now() > until) return error.Timeout;
        try step(20);
    }
}

/// The pixel the server shows at (x, y) logical pixels in the window.
fn serverPixel(w: *Window, x: f32, y: f32) !core.Color {
    const conn = app.?.conn;
    const s = w.scaleFactor();
    const seq = try conn.request(op.get_image, 2, &.{ &le32(w.id), &le16(@intFromFloat(x * s)), &le16(@intFromFloat(y * s)), &le16(1), &le16(1), &le32(0xffffffff) });
    const r = try conn.reply(seq);
    defer r.deinit(conn.gpa);
    const p = std.mem.readInt(u32, r.data()[0..4], .little);
    return .rgb(@truncate(p));
}

fn sendInput(w: *Window, kind: u8, detail: u8, state: u16, x: f32, y: f32) !void {
    const conn = app.?.conn;
    const s = w.scaleFactor();
    var e: protocol.Event = @splat(0);
    e[0] = kind;
    e[1] = detail;
    @memcpy(e[8..12], &le32(conn.root));
    @memcpy(e[12..16], &le32(w.id));
    @memcpy(e[24..26], &le16(@bitCast(@as(i16, @intFromFloat(x * s)))));
    @memcpy(e[26..28], &le16(@bitCast(@as(i16, @intFromFloat(y * s)))));
    @memcpy(e[28..30], &le16(state));
    e[30] = 1; // same screen
    try conn.sendEvent(w.id, 0, &e);
}

fn sendKey(w: *Window, sym: u32, state: u16) !void {
    const keycode = app.?.conn.keycodeOf(sym) orelse return error.NoSuchKey;
    try sendInput(w, ev.key_press, keycode, state, 0, 0);
    try sendInput(w, ev.key_release, keycode, state, 0, 0);
}

const TestUi = struct {
    ui: core.Window = undefined,
    button: core.items.Rectangle = .{},
    touch: core.items.TouchArea = .{},
    keys: core.items.FocusScope = .{},
    clicks: usize = 0,
    typed: [64]u8 = undefined,
    typed_len: usize = 0,

    fn init(t: *TestUi) !void {
        t.* = .{};
        t.ui.init(testing.allocator, .{ .width = 120, .height = 80 });
        t.ui.rootItem().appendChildren(&.{ &t.button.item, &t.keys.item });
        t.button.item.setGeometry(.{ .x = 10, .y = 10, .width = 50, .height = 30 });
        t.button.background.set(.color(.rgb(0xff0000)));
        t.button.item.appendChild(&t.touch.item);
        try t.touch.item.fillParent(testing.allocator);
        t.touch.clicked.setHandler(t, struct {
            fn f(self: *TestUi) void {
                self.clicks += 1;
                self.button.background.set(.color(.rgb(0x0000ff)));
            }
        }.f);
        t.keys.key_pressed.setHandler(t, struct {
            fn f(self: *TestUi, e: input.KeyEvent) input.EventResult {
                const n = @min(e.text.len, self.typed.len - self.typed_len);
                @memcpy(self.typed[self.typed_len..][0..n], e.text[0..n]);
                self.typed_len += n;
                return .accept;
            }
        }.f);
    }

    fn deinit(t: *TestUi) void {
        t.ui.deinit();
        t.keys.deinit();
        t.touch.deinit();
        t.button.deinit();
    }
};

test "a native window: render, click, type, resize, close" {
    try initOrSkip();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    const w = try Window.create(testing.allocator, &t.ui, .{ .title = "test" });
    defer w.destroy();

    // Shown, and drawn: what the server shows.
    try stepUntil(w, struct {
        fn f(win: *Window) bool {
            return win.mapped and !win.full_redraw;
        }
    }.f);
    try step(0);
    try testing.expectEqual(core.Color.rgb(0xff0000), try serverPixel(w, 20, 20));
    try testing.expectEqual(core.Color.white, try serverPixel(w, 100, 70));

    // A click on the button turns it blue.
    try sendInput(w, ev.button_press, 1, 0, 30, 20);
    try sendInput(w, ev.button_release, 1, 0x100, 30, 20);
    try stepUntil(&t, struct {
        fn f(tt: *TestUi) bool {
            return tt.clicks == 1;
        }
    }.f);
    try step(0);
    try testing.expectEqual(core.Color.rgb(0x0000ff), try serverPixel(w, 20, 20));

    // Text (Shift: a capital), special keys and shortcuts reach the
    // focused item.
    t.keys.focus();
    try sendKey(w, 'h', 0);
    try sendKey(w, 'a', 1);
    try sendKey(w, 0xff0d, 0); // Return
    try sendKey(w, 0xff51, 0); // Left
    try sendKey(w, 'c', 4); // Ctrl+C
    const expected = "hA" ++ Key.@"return" ++ Key.left_arrow ++ "c";
    try stepUntil(&t, struct {
        fn f(tt: *TestUi) bool {
            return tt.typed_len >= expected.len;
        }
    }.f);
    try testing.expectEqualStrings(expected, t.typed[0..t.typed_len]);

    // Resizing the window resizes the zigulee window, and redraws.
    const conn = app.?.conn;
    _ = try conn.request(op.configure_window, 0, &.{ &le32(w.id), &le16(0x4 | 0x8), &le16(0), &le32(200), &le32(150) });
    try stepUntil(w, struct {
        fn f(win: *Window) bool {
            return win.pixel_width == 200;
        }
    }.f);
    try testing.expectEqual(core.Size{ .width = 200 / w.scaleFactor(), .height = 150 / w.scaleFactor() }, t.ui.size());
    try step(0);
    try testing.expectEqual(core.Color.white, try serverPixel(w, t.ui.size().width - 5, t.ui.size().height - 5));

    // The window manager's close button ends the loop (the window stays
    // until destroyed).
    var close: protocol.Event = @splat(0);
    close[0] = ev.client_message;
    close[1] = 32;
    @memcpy(close[4..8], &le32(w.id));
    @memcpy(close[8..12], &le32(app.?.atoms.wm_protocols));
    @memcpy(close[12..16], &le32(app.?.atoms.wm_delete_window));
    try conn.sendEvent(w.id, 0, &close);
    try w.run();
    try testing.expect(w.closed);
}

test "time advances: timers fire, animations run to their end" {
    try initOrSkip();
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 60, .height = 30 });
    defer ui.deinit();
    const w = try Window.create(testing.allocator, &ui, .{ .hidden = true });
    defer w.destroy();
    try step(0); // first frame

    var fired = false;
    var timer: core.Timer = .{};
    defer timer.deinit();
    timer.start(.single_shot, 50, &fired, struct {
        fn f(flag: *bool) void {
            flag.* = true;
        }
    }.f);
    const start = now();
    var steps: usize = 0;
    while (!fired and now() - start < 1000) : (steps += 1) try step(1000);
    try testing.expect(fired);
    const elapsed = now() - start;
    if (elapsed < 45 or steps >= 10) {
        std.debug.print("timer fired after {d} ms, {d} steps\n", .{ elapsed, steps });
        return error.TestUnexpectedResult;
    }

    var rect: core.items.Rectangle = .{};
    defer rect.deinit();
    ui.rootItem().appendChild(&rect.item);
    rect.item.setGeometry(.{ .width = 60, .height = 30 });
    rect.background.set(.color(.black));
    try step(0);
    try rect.background.setAnimated(testing.allocator, .color(.white), .{ .duration_ms = 100 });
    const until = now() + 1000;
    while (core.hasActiveAnimations() and now() < until) try step(100);
    try testing.expect(!core.hasActiveAnimations());
    try testing.expectEqual(core.Brush.color(.white), rect.background.get());
}

test "the clipboard goes through the X server" {
    try initOrSkip();
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 60, .height = 30 });
    defer ui.deinit();
    const w = try Window.create(testing.allocator, &ui, .{ .hidden = true });
    defer w.destroy();
    ui.clipboard.?.setFn(ui.clipboard.?.ctx, "zigulee\nclipboard é");
    const text = ui.clipboardText(testing.allocator) orelse return error.NoClipboard;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("zigulee\nclipboard é", text);
}

test "the title bar's scheme hint follows the window's" {
    try initOrSkip();
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 60, .height = 30 });
    defer ui.deinit();
    const w = try Window.create(testing.allocator, &ui, .{ .hidden = true });
    defer w.destroy();
    ui.root.background.set(.color(.rgb(0x202020)));
    try step(0);
    const a = &app.?;
    const r = (try a.conn.getProperty(w.id, a.atoms.gtk_theme_variant, a.atoms.utf8_string, 64)).?;
    defer r.deinit(a.conn.gpa);
    try testing.expectEqualStrings("dark", r.data()[0..r.u32At(16)]);
}

test {
    _ = protocol;
}

/// Stands for another application dragging a file over a window (XDND),
/// on a connection of its own; it answers the drop on its own thread (the
/// window waits for the data meanwhile).
const TestSource = struct {
    conn: *protocol.Conn,
    id: u32,
    finished: std.atomic.Value(u32) = .init(0),

    fn open(gpa: Allocator) !TestSource {
        const conn = try protocol.Conn.open(gpa);
        const id = conn.newId();
        _ = try conn.request(op.create_window, 0, &.{
            &le32(id), &le32(conn.root), &le16(0), &le16(0), &le16(1), &le16(1), &le16(0), &le16(2), // input-only
            &le32(0),  &le32(0),
        });
        const a = &app.?;
        _ = try conn.request(op.set_selection_owner, 0, &.{ &le32(id), &le32(a.atoms.xdnd_selection), &le32(0) });
        try conn.flush();
        return .{ .conn = conn, .id = id };
    }

    fn send(self: *TestSource, to: u32, kind: u32, l: [5]u32) !void {
        var e: protocol.Event = @splat(0);
        e[0] = ev.client_message;
        e[1] = 32;
        @memcpy(e[4..8], &le32(to));
        @memcpy(e[8..12], &le32(kind));
        for (l, 0..) |v, i| @memcpy(e[12 + 4 * i ..][0..4], &le32(v));
        try self.conn.sendEvent(to, 0, &e);
        try self.conn.flush();
    }

    /// Answers the request for its data (a URI list), until finished.
    fn serve(self: *TestSource) void {
        const a = &app.?;
        const until = now() + 3000;
        while (now() < until) {
            const e = (self.conn.nextEvent(100) catch return) orelse continue;
            switch (e[0] & 0x7f) {
                ev.selection_request => {
                    const requestor = u32Of(&e, 12);
                    const property = u32Of(&e, 24);
                    self.conn.changeProperty(requestor, property, a.atoms.uri_list, 8, "file:///tmp/zigulee%20drop.txt\r\n") catch return;
                    var n: protocol.Event = @splat(0);
                    n[0] = ev.selection_notify;
                    @memcpy(n[8..12], &le32(requestor));
                    @memcpy(n[12..16], &le32(u32Of(&e, 16)));
                    @memcpy(n[16..20], &le32(u32Of(&e, 20)));
                    @memcpy(n[20..24], &le32(property));
                    self.conn.sendEvent(requestor, 0, &n) catch return;
                    self.conn.flush() catch return;
                },
                ev.client_message => if (u32Of(&e, 8) == a.atoms.xdnd_finished) {
                    self.finished.store(1 + u32Of(&e, 16), .release); // 2: taken
                    return;
                },
                else => {},
            }
        }
    }
};

test "files dropped from other applications (XDND)" {
    try initOrSkip();
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 100, .height = 60 });
    defer ui.deinit();
    var area: core.items.DropArea = .{};
    defer area.deinit();
    ui.rootItem().appendChild(&area.item);
    area.item.setGeometry(.{ .width = 100, .height = 60 });
    area.accepts.set(dnd.file_kind);
    const Got = struct {
        buf: [128]u8 = undefined,
        len: usize = 0,
        fn f(self: *@This(), data: []const u8) void {
            @memcpy(self.buf[0..data.len], data);
            self.len = data.len;
        }
    };
    var got: Got = .{};
    area.dropped.setHandler(&got, Got.f);
    const w = try Window.create(testing.allocator, &ui, .{ .title = "drop" });
    defer w.destroy();
    try stepUntil(w, struct {
        fn f(win: *Window) bool {
            return win.mapped;
        }
    }.f);
    try w.queryPosition();

    const a = &app.?;
    var source = try TestSource.open(testing.allocator);
    defer source.conn.close();
    try source.send(w.id, a.atoms.xdnd_enter, .{ source.id, 5 << 24, a.atoms.uri_list, 0, 0 });
    const root_x: u32 = @intCast(w.position[0] + 10);
    const root_y: u32 = @intCast(w.position[1] + 10);
    try source.send(w.id, a.atoms.xdnd_position, .{ source.id, 0, (root_x << 16) | root_y, 0, a.atoms.xdnd_action_copy });
    try stepUntil(&area, struct {
        fn f(d: *core.items.DropArea) bool {
            return d.contains_drag.get();
        }
    }.f);

    try source.send(w.id, a.atoms.xdnd_drop, .{ source.id, 0, 0, 0, 0 });
    // From here, the source's connection is its thread's.
    const server = try std.Thread.spawn(.{}, TestSource.serve, .{&source});
    try stepUntil(&got, struct {
        fn f(g: *Got) bool {
            return g.len > 0;
        }
    }.f);
    server.join();
    try testing.expectEqualStrings("/tmp/zigulee drop.txt", got.buf[0..got.len]);
    try testing.expectEqual(@as(u32, 2), source.finished.load(.acquire));
    try testing.expect(!area.contains_drag.get());
}
