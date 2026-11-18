// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The native Wayland backend (`zigulee-wayland`): shows a `zigulee.Window` as
//! an xdg-shell toplevel, talking to the compositor directly
//! (protocol.zig: no libwayland). Same interface as the other backends:
//!
//!     try wayland.init();
//!     defer wayland.deinit();
//!     const window = try wayland.Window.create(gpa, &ui_window, .{ .title = "Hello" });
//!     defer window.destroy();
//!     try window.run();
//!
//! Windows draw with the software renderer into shared-memory buffers
//! (two, each brought up to date with what changed since it was last
//! shown), paced by the compositor's frame callbacks, at the outputs'
//! integer scale. The title bar is the compositor's where it offers one
//! (xdg-decoration); elsewhere (GNOME, Weston) a minimal one is drawn: drag
//! to move, double-click to maximize, a close button, resizing from the
//! edges. The keyboard goes through libxkbcommon (xkb.zig, loaded at run
//! time): layouts, dead keys and compose sequences, key repeat. Cursors
//! use the cursor-shape protocol where there is one. The clipboard is the
//! seat's selection (UTF-8 text). Screen readers see the accessible items
//! (AT-SPI).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const dnd = core.dnd;
const gestures = core.gestures;
const Rgba8 = core.Rgba8;
const input = core.input;
const Key = input.Key;
const atspi = @import("zigulee-atspi");
pub const protocol = @import("protocol.zig");
pub const xkb = @import("zigulee-xkb");
const Arg = protocol.Conn.Arg;
const c = std.c;

const log = std.log.scoped(.zigulee_wayland);

pub const Error = protocol.Error || error{ NoCompositorGlobals, ConfigureTimeout };

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

fn monotonicNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

var start_ns: ?u64 = null;

/// Milliseconds since `init` (a monotonic clock): the clock zigulee's timers
/// and animations run on.
pub fn now() u64 {
    if (start_ns == null) start_ns = monotonicNs();
    return (monotonicNs() - start_ns.?) / std.time.ns_per_ms;
}

/// The height of the title bar drawn when the compositor draws none
/// (logical pixels).
const bar_height = 32;
/// How far from the edges a press resizes (drawn title bar only).
const resize_margin = 5;

// ---- Objects ----

const Kind = enum {
    display,
    registry,
    sync,
    frame,
    compositor,
    shm,
    wm_base,
    seat,
    pointer,
    keyboard,
    touch,
    output,
    surface,
    xdg_surface,
    toplevel,
    decoration_manager,
    decoration,
    buffer,
    data_device_manager,
    data_device,
    data_source,
    data_offer,
    cursor_shape_manager,
    cursor_shape_device,
    other,
};

const Object = struct {
    kind: Kind,
    window: ?*Window = null,
    /// Which buffer (for buffers), which output (for outputs).
    index: u32 = 0,
};

const Output = struct { id: u32, name: u32, scale: i32 = 1 };

const App = struct {
    gpa: Allocator,
    conn: *protocol.Conn,
    objects: std.AutoHashMapUnmanaged(u32, Object) = .empty,
    registry: u32 = 0,
    compositor: u32 = 0,
    compositor_version: u32 = 0,
    shm: u32 = 0,
    wm_base: u32 = 0,
    seat: u32 = 0,
    data_device_manager: u32 = 0,
    decoration_manager: u32 = 0,
    cursor_shape_manager: u32 = 0,
    outputs: std.ArrayList(Output) = .empty,
    pointer: u32 = 0,
    keyboard_id: u32 = 0,
    touch: u32 = 0,
    /// The window each finger touched (by its id).
    touch_windows: [10]struct { id: i32 = 0, window: ?*Window = null } = @splat(.{}),
    data_device: u32 = 0,
    cursor_shape_device: u32 = 0,
    sync_done: bool = false,
    keyboard: ?xkb.Keyboard = null,
    keyboard_focus: ?*Window = null,
    pointer_focus: ?*Window = null,
    /// The serial of the pointer's entering (to set its cursor), and of
    /// the last input event (to start a move or set the clipboard).
    pointer_serial: u32 = 0,
    input_serial: u32 = 0,
    pointer_position: core.Point = .{},
    /// Wheel or finger (axis_source).
    axis_finger: bool = false,
    mods: input.Modifiers = .{},
    altgr: bool = false,
    repeat_rate: u32 = 25,
    repeat_delay: u32 = 600,
    repeat_key: ?u32 = null,
    repeat_next: u64 = 0,
    /// The clipboard: our source and its text, and the current offer.
    source: u32 = 0,
    source_text: ?[]u8 = null,
    offer: u32 = 0,
    offer_mime: ?[]const u8 = null,
    pending_offer_mime: ?[]const u8 = null,
    data_device_version: u32 = 0,
    /// The newest offer has files (`text/uri-list`).
    pending_offer_uris: bool = false,
    /// A drag from another application over a window: its offer, what it
    /// carries (`dnd.file_kind` or `dnd.text_kind`), the type asked for,
    /// where it is.
    dnd_offer: u32 = 0,
    dnd_window: ?*Window = null,
    dnd_serial: u32 = 0,
    dnd_kind: []const u8 = "",
    dnd_mime: ?[]const u8 = null,
    dnd_at: core.Point = .{},
    /// Written to wake the loop (AT-SPI messages arrive on another thread).
    wake_pipe: [2]c.fd_t = .{ -1, -1 },

    fn add(a: *App, kind: Kind) Error!u32 {
        const id = a.conn.newId();
        try a.objects.put(a.gpa, id, .{ .kind = kind });
        return id;
    }

    fn addFor(a: *App, kind: Kind, w: ?*Window, index: u32) Error!u32 {
        const id = a.conn.newId();
        try a.objects.put(a.gpa, id, .{ .kind = kind, .window = w, .index = index });
        return id;
    }

    fn bind(a: *App, name: u32, interface: []const u8, version: u32, kind: Kind) Error!u32 {
        const id = try a.add(kind);
        try a.conn.request(a.registry, 0, &.{ .{ .uint = name }, .{ .string = interface }, .{ .uint = version }, .{ .object = id } });
        return id;
    }

    /// Waits until the compositor has handled everything sent so far
    /// (handling events meanwhile).
    fn roundTrip(a: *App) Error!void {
        const id = try a.add(.sync);
        try a.conn.request(1, 0, &.{.{ .object = id }}); // wl_display.sync
        a.sync_done = false;
        const until = now() + 5000;
        while (!a.sync_done) {
            if (now() > until) return error.Timeout;
            if (try a.conn.next(100)) |m| {
                var msg = m;
                try handleEvent(&msg);
            }
        }
    }
};

var app: ?App = null;
var open_windows: ?*Window = null;

/// Sound: the mixer plays through PipeWire (from `init` to `deinit`).
var audio_output: @import("zigulee-pipewire").Output = .{};

/// Connects to the compositor (`WAYLAND_DISPLAY`). Called by
/// `Window.create` if needed.
pub fn init() Error!void {
    if (app != null) return;
    _ = now();
    core.audio.mixer().setOutput(audio_output.output());
    core.video.addDecoder(@import("zigulee-gstreamer").decoder);
    core.dialogs.setFileDialogs(atspi.portal.provider);
    core.tray.setProvider(atspi.notifications.provider);
    core.links.setOpener(atspi.openuri.opener);
    const gpa = std.heap.c_allocator;
    const conn = try protocol.Conn.open(gpa);
    app = .{ .gpa = gpa, .conn = conn };
    const a = &app.?;
    errdefer {
        a.objects.deinit(gpa);
        a.outputs.deinit(gpa);
        conn.close();
        app = null;
    }
    try a.objects.put(gpa, 1, .{ .kind = .display });
    a.registry = try a.add(.registry);
    try conn.request(1, 1, &.{.{ .object = a.registry }}); // get_registry
    try a.roundTrip(); // the globals
    if (a.compositor == 0 or a.shm == 0 or a.wm_base == 0) {
        log.info("the compositor lacks wl_compositor, wl_shm or xdg_wm_base", .{});
        return error.NoCompositorGlobals;
    }
    try a.roundTrip(); // the seat's capabilities, the outputs' scales
    a.keyboard = xkb.Keyboard.init();
    if (c.pipe(&a.wake_pipe) == 0) {
        atspi.wake = wake;
    } else a.wake_pipe = .{ -1, -1 };
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
    if (a.keyboard) |*k| k.deinit();
    if (a.source_text) |t| a.gpa.free(t);
    if (a.wake_pipe[0] >= 0) {
        atspi.wake = null;
        _ = c.close(a.wake_pipe[0]);
        _ = c.close(a.wake_pipe[1]);
    }
    a.objects.deinit(a.gpa);
    a.outputs.deinit(a.gpa);
    a.conn.close();
    app = null;
}

fn wake() void {
    const a = app orelse return;
    _ = c.write(a.wake_pipe[1], "w", 1);
}

/// One event loop iteration for every open window: waits for an event (at
/// most `max_wait_ms`, or until the next timer, key repeat or frame),
/// handles the events, fires timers, runs change handlers and draws what
/// changed.
pub fn step(max_wait_ms: ?u32) Error!void {
    const a = &(app orelse return);
    core.updateTimersAndAnimations(now());
    var timeout: ?u64 = null; // null: until an event
    var it = open_windows;
    while (it) |w| : (it = w.next) if (w.needsFrame() and w.canPresent()) {
        const next = if (core.hasActiveAnimations() and !w.full_redraw and !w.ui.redraw_requested) w.last_frame + 16 else 0;
        const wait = next -| now();
        timeout = if (timeout) |t| @min(t, wait) else wait;
    };
    if (core.nextTimerDeadline()) |deadline| timeout = @min(timeout orelse std.math.maxInt(u64), deadline -| now());
    if (a.repeat_key != null) timeout = @min(timeout orelse std.math.maxInt(u64), a.repeat_next -| now());
    if (max_wait_ms) |m| timeout = if (timeout) |t| @min(t, m) else m;

    try a.conn.flush();
    if (timeout != 0 and !a.conn.pending()) {
        var fds = [2]c.pollfd{
            .{ .fd = a.conn.fd, .events = c.POLL.IN, .revents = 0 },
            .{ .fd = a.wake_pipe[0], .events = c.POLL.IN, .revents = 0 },
        };
        const ms: c_int = if (timeout) |t| @intCast(@min(t, std.math.maxInt(i32))) else -1;
        _ = c.poll(&fds, if (a.wake_pipe[0] >= 0) 2 else 1, ms);
        if (fds[1].revents != 0) {
            var buf: [64]u8 = undefined;
            _ = c.read(a.wake_pipe[0], &buf, buf.len);
        }
    }
    while (try a.conn.next(0)) |m| {
        var msg = m;
        try handleEvent(&msg);
    }
    // Key repeat.
    if (a.repeat_key) |code| if (now() >= a.repeat_next) {
        a.repeat_next = now() + 1000 / @max(1, a.repeat_rate);
        if (a.keyboard_focus) |w| w.keyEvent(code, true, true);
    };

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

fn windowOfSurface(id: u32) ?*Window {
    var it = open_windows;
    while (it) |w| : (it = w.next) if (w.surface == id) return w;
    return null;
}

// ---- Events ----

fn handleEvent(m: *protocol.Message) Error!void {
    const a = &app.?;
    const obj = a.objects.get(m.sender) orelse return;
    switch (obj.kind) {
        .display => switch (m.opcode) {
            0 => { // error
                const object = m.uint();
                const code = m.uint();
                log.warn("Wayland protocol error (object {d}, code {d}): {s}", .{ object, code, m.string() });
                return error.ProtocolError;
            },
            1 => _ = a.objects.remove(m.uint()), // delete_id
            else => {},
        },
        .registry => if (m.opcode == 0) { // global
            const name = m.uint();
            const interface = m.string();
            const version = m.uint();
            try global(name, interface, version);
        },
        .sync => if (m.opcode == 0) {
            a.sync_done = true;
        },
        .frame => if (m.opcode == 0) if (obj.window) |w| {
            w.frame_pending = false;
        },
        .wm_base => if (m.opcode == 0) try a.conn.request(a.wm_base, 3, &.{.{ .uint = m.uint() }}), // ping: pong
        .seat => if (m.opcode == 0) try seatCapabilities(m.uint()),
        .output => if (m.opcode == 3) { // scale
            for (a.outputs.items) |*o| if (o.id == m.sender) {
                o.scale = m.int();
            };
            var it = open_windows;
            while (it) |w| : (it = w.next) w.updateScale();
        },
        .surface => if (obj.window) |w| switch (m.opcode) {
            0, 1 => { // enter, leave
                const output = m.uint();
                w.outputEntered(output, m.opcode == 0);
            },
            2 => { // preferred_buffer_scale (v6)
                w.preferred_scale = @max(1, m.int());
                w.updateScale();
            },
            else => {},
        },
        .xdg_surface => if (m.opcode == 0) if (obj.window) |w| try w.surfaceConfigure(m.uint()),
        .toplevel => if (obj.window) |w| switch (m.opcode) {
            0 => { // configure
                w.pending_width = m.int();
                w.pending_height = m.int();
                const states = m.array();
                w.maximized = false;
                w.fullscreen = false;
                w.activated = false;
                var i: usize = 0;
                while (i + 4 <= states.len) : (i += 4) switch (std.mem.readInt(u32, states[i..][0..4], .little)) {
                    1 => w.maximized = true,
                    2 => w.fullscreen = true,
                    4 => w.activated = true,
                    else => {},
                };
                // Compositors say nothing of minimizing (until the window
                // is active again) or of staying on top (not done).
                const shown = w.state.shown;
                w.state.report(w.ui, .{ .fullscreen = w.fullscreen, .maximized = w.maximized, .minimized = shown.minimized and !w.activated, .always_on_top = shown.always_on_top });
            },
            1 => w.closed = true, // close
            else => {},
        },
        .decoration => if (m.opcode == 0) if (obj.window) |w| {
            w.csd = m.uint() != 2; // server_side: 2
        },
        .buffer => if (m.opcode == 0) if (obj.window) |w| { // release
            if (obj.index < w.buffers.len) w.buffers[obj.index].busy = false;
        },
        .pointer => try pointerEvent(m),
        .touch => touchEvent(m),
        .keyboard => try keyboardEvent(m),
        .data_device => switch (m.opcode) {
            0 => { // data_offer: a new offer
                const id = m.uint();
                try a.objects.put(a.gpa, id, .{ .kind = .data_offer });
                a.pending_offer_mime = null;
                a.pending_offer_uris = false;
            },
            1 => { // enter: a drag over one of our surfaces
                a.dnd_serial = m.uint();
                a.dnd_window = windowOfSurface(m.uint());
                a.dnd_at = .{ .x = m.fixed(), .y = m.fixed() };
                a.dnd_offer = m.uint();
                a.dnd_kind = if (a.pending_offer_uris) dnd.file_kind else if (a.pending_offer_mime != null) dnd.text_kind else "";
                a.dnd_mime = if (a.pending_offer_uris) "text/uri-list" else a.pending_offer_mime;
                // set_actions: copy (version 3)
                if (a.dnd_offer != 0 and a.data_device_version >= 3) try a.conn.request(a.dnd_offer, 4, &.{ .{ .uint = 1 }, .{ .uint = 1 } });
                try dragMoved();
            },
            2 => { // leave
                if (a.dnd_window) |w| dnd.externalLeft(w.ui);
                try endDrag();
            },
            3 => { // motion
                _ = m.uint();
                a.dnd_at = .{ .x = m.fixed(), .y = m.fixed() };
                try dragMoved();
            },
            4 => try dragDropped(), // drop
            5 => { // selection
                const id = m.uint();
                if (a.offer != 0 and a.offer != id) try a.conn.request(a.offer, 2, &.{}); // destroy
                a.offer = id;
                a.offer_mime = if (id != 0) a.pending_offer_mime else null;
            },
            else => {},
        },
        .data_offer => if (m.opcode == 0) { // offer: a mime type
            const mime = m.string();
            if (std.mem.eql(u8, mime, "text/uri-list")) a.pending_offer_uris = true;
            for (text_mimes) |t| if (std.mem.eql(u8, mime, t)) {
                // The best text type offered.
                if (a.pending_offer_mime == null or rank(t) < rank(a.pending_offer_mime.?)) a.pending_offer_mime = t;
            };
        },
        .data_source => switch (m.opcode) {
            1 => { // send: the text, to the fd
                _ = m.string();
                const fd = a.conn.takeFd();
                if (fd >= 0) {
                    defer _ = c.close(fd);
                    if (a.source_text) |text| writeAllFd(fd, text);
                }
            },
            2 => { // cancelled: another source took over
                if (m.sender == a.source) {
                    if (a.source_text) |t| a.gpa.free(t);
                    a.source_text = null;
                    a.source = 0;
                }
                try a.conn.request(m.sender, 1, &.{}); // destroy
            },
            else => {},
        },
        else => {},
    }
}

const text_mimes = [_][]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain" };

fn rank(mime: []const u8) usize {
    for (text_mimes, 0..) |t, i| if (std.mem.eql(u8, t, mime)) return i;
    return text_mimes.len;
}

fn global(name: u32, interface: []const u8, version: u32) Error!void {
    const a = &app.?;
    const eql = std.mem.eql;
    if (eql(u8, interface, "wl_compositor")) {
        a.compositor_version = @min(version, 6);
        a.compositor = try a.bind(name, interface, a.compositor_version, .compositor);
    } else if (eql(u8, interface, "wl_shm")) {
        a.shm = try a.bind(name, interface, 1, .shm);
    } else if (eql(u8, interface, "xdg_wm_base")) {
        a.wm_base = try a.bind(name, interface, 1, .wm_base);
    } else if (eql(u8, interface, "wl_seat") and a.seat == 0) {
        a.seat = try a.bind(name, interface, @min(version, 5), .seat);
    } else if (eql(u8, interface, "wl_output")) {
        const id = try a.bind(name, interface, @min(version, 2), .output);
        try a.outputs.append(a.gpa, .{ .id = id, .name = name });
    } else if (eql(u8, interface, "wl_data_device_manager")) {
        a.data_device_manager = try a.bind(name, interface, @min(version, 3), .data_device_manager);
        a.data_device_version = @min(version, 3);
    } else if (eql(u8, interface, "zxdg_decoration_manager_v1")) {
        a.decoration_manager = try a.bind(name, interface, 1, .decoration_manager);
    } else if (eql(u8, interface, "wp_cursor_shape_manager_v1")) {
        a.cursor_shape_manager = try a.bind(name, interface, 1, .cursor_shape_manager);
    }
}

fn seatCapabilities(caps: u32) Error!void {
    const a = &app.?;
    if (caps & 1 != 0 and a.pointer == 0) {
        a.pointer = try a.add(.pointer);
        try a.conn.request(a.seat, 0, &.{.{ .object = a.pointer }});
        if (a.cursor_shape_manager != 0) {
            a.cursor_shape_device = try a.add(.cursor_shape_device);
            try a.conn.request(a.cursor_shape_manager, 1, &.{ .{ .object = a.cursor_shape_device }, .{ .object = a.pointer } });
        }
    }
    if (caps & 4 != 0 and a.touch == 0) {
        a.touch = try a.add(.touch);
        try a.conn.request(a.seat, 2, &.{.{ .object = a.touch }}); // get_touch
    }
    if (caps & 2 != 0 and a.keyboard_id == 0) {
        a.keyboard_id = try a.add(.keyboard);
        try a.conn.request(a.seat, 1, &.{.{ .object = a.keyboard_id }});
    }
    if (a.data_device_manager != 0 and a.data_device == 0) {
        a.data_device = try a.add(.data_device);
        try a.conn.request(a.data_device_manager, 1, &.{ .{ .object = a.data_device }, .{ .object = a.seat } });
    }
}

/// Fingers on a window: to the core, which makes the first one the mouse
/// and two a pinch.
fn touchEvent(m: *protocol.Message) void {
    const a = &app.?;
    switch (m.opcode) {
        0 => { // down
            _ = m.uint();
            _ = m.uint();
            const w = windowOfSurface(m.uint()) orelse return;
            const finger = m.int();
            const at: core.Point = .{ .x = m.fixed(), .y = m.fixed() };
            for (&a.touch_windows) |*t| if (t.window == null) {
                t.* = .{ .id = finger, .window = w };
                break;
            };
            gestures.dispatchTouch(w.ui, @bitCast(@as(i64, finger)), .down, at);
        },
        1 => { // up
            _ = m.uint();
            _ = m.uint();
            const finger = m.int();
            for (&a.touch_windows) |*t| if (t.window != null and t.id == finger) {
                const w = t.window.?;
                t.window = null;
                gestures.dispatchTouch(w.ui, @bitCast(@as(i64, finger)), .up, lastTouch(w, finger));
            };
        },
        2 => { // motion
            _ = m.uint();
            const finger = m.int();
            const at: core.Point = .{ .x = m.fixed(), .y = m.fixed() };
            for (a.touch_windows) |t| if (t.window != null and t.id == finger) gestures.dispatchTouch(t.window.?.ui, @bitCast(@as(i64, finger)), .moved, at);
        },
        4 => { // cancel: every finger
            for (&a.touch_windows) |*t| if (t.window) |w| {
                t.window = null;
                gestures.dispatchTouch(w.ui, @bitCast(@as(i64, t.id)), .cancelled, lastTouch(w, t.id));
            };
        },
        else => {}, // frame, shape, orientation
    }
}

/// Where finger `id` last was on `w` (`up` does not say).
fn lastTouch(w: *Window, finger: i32) core.Point {
    const id: u64 = @bitCast(@as(i64, finger));
    for (w.ui.touch.points) |p| if (p.down and p.id == id) return p.at;
    return .{};
}

fn pointerEvent(m: *protocol.Message) Error!void {
    const a = &app.?;
    switch (m.opcode) {
        0 => { // enter
            const serial = m.uint();
            const surface = m.uint();
            const x = m.fixed();
            const y = m.fixed();
            a.pointer_serial = serial;
            a.pointer_focus = windowOfSurface(surface);
            if (a.pointer_focus) |w| {
                try w.applyCursor(true);
                w.pointerMoved(x, y);
            }
        },
        1 => { // leave
            if (a.pointer_focus) |w| w.ui.dispatchPointer(.exit);
            a.pointer_focus = null;
        },
        2 => { // motion
            _ = m.uint();
            const x = m.fixed();
            const y = m.fixed();
            if (a.pointer_focus) |w| w.pointerMoved(x, y);
        },
        3 => { // button
            const serial = m.uint();
            _ = m.uint();
            const code = m.uint();
            const pressed = m.uint() == 1;
            a.input_serial = serial;
            if (a.pointer_focus) |w| try w.pointerButton(code, pressed);
        },
        4 => { // axis
            _ = m.uint();
            const axis = m.uint();
            const value = m.fixed();
            // A wheel gives 10 per notch: zigulee's step is 40.
            const f: f32 = if (a.axis_finger) 1 else 4;
            const delta: core.Point = if (axis == 0) .{ .x = 0, .y = -value * f } else .{ .x = -value * f, .y = 0 };
            if (a.pointer_focus) |w| w.pointerWheel(delta);
        },
        6 => a.axis_finger = m.uint() == 1, // axis_source
        else => {},
    }
}

fn keyboardEvent(m: *protocol.Message) Error!void {
    const a = &app.?;
    switch (m.opcode) {
        0 => { // keymap
            const format = m.uint();
            const size = m.uint();
            const fd = a.conn.takeFd();
            if (fd < 0) return;
            defer _ = c.close(fd);
            if (format != 1 or size == 0) return;
            const k = if (a.keyboard) |*k| k else return;
            const mem = c.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
            if (mem == c.MAP_FAILED) return;
            defer _ = c.munmap(@alignCast(mem), size);
            const bytes: [*]const u8 = @ptrCast(mem);
            // The keymap ends with a 0 (size counts it).
            if (bytes[size - 1] == 0) k.setKeymap(@ptrCast(bytes));
        },
        1 => { // enter
            a.input_serial = m.uint();
            a.keyboard_focus = windowOfSurface(m.uint());
            if (a.keyboard_focus) |w| w.focused = true;
        },
        2 => { // leave
            if (a.keyboard_focus) |w| w.focused = false;
            a.keyboard_focus = null;
            a.repeat_key = null;
        },
        3 => { // key
            a.input_serial = m.uint();
            _ = m.uint();
            const code = m.uint();
            const pressed = m.uint() == 1;
            if (a.keyboard_focus) |w| w.keyEvent(code, pressed, false);
        },
        4 => { // modifiers
            _ = m.uint();
            const depressed = m.uint();
            const latched = m.uint();
            const locked = m.uint();
            const group = m.uint();
            setModifiers(depressed, latched, locked, group);
        },
        5 => { // repeat_info
            a.repeat_rate = @intCast(@max(0, m.int()));
            a.repeat_delay = @intCast(@max(0, m.int()));
        },
        else => {},
    }
}

fn setModifiers(depressed: u32, latched: u32, locked: u32, group: u32) void {
    const a = &app.?;
    const k = if (a.keyboard) |*k| k else return;
    k.updateModifiers(depressed, latched, locked, group);
    a.mods = .{
        .shift = k.modifierActive("Shift"),
        .control = k.modifierActive("Control"),
        .alt = k.modifierActive("Mod1"),
        .meta = k.modifierActive("Mod4"),
    };
    a.altgr = k.modifierActive("Mod5");
}

fn writeAllFd(fd: c.fd_t, bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = c.write(fd, bytes[done..].ptr, bytes.len - done);
        if (n <= 0) return;
        done += @intCast(n);
    }
}

// ---- Windows ----

/// A shared-memory buffer the compositor shows.
const Buffer = struct {
    id: u32 = 0,
    memory: []align(std.heap.page_size_min) u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// The compositor is still reading it.
    busy: bool = false,
    /// What changed since it was last brought up to date (buffer pixels).
    stale: core.Rect = .empty,

    fn pixels(b: *Buffer) []u32 {
        return @alignCast(std.mem.bytesAsSlice(u32, b.memory));
    }
};

pub const Window = struct {
    gpa: Allocator,
    ui: *core.Window,
    surface: u32 = 0,
    xdg_surface: u32 = 0,
    toplevel: u32 = 0,
    decoration: u32 = 0,
    /// The title bar is ours to draw.
    csd: bool = true,
    hidden: bool = false,
    configured: bool = false,
    pending_width: i32 = 0,
    pending_height: i32 = 0,
    /// The content's size (logical pixels, without the title bar).
    width: u32 = 0,
    height: u32 = 0,
    maximized: bool = false,
    fullscreen: bool = false,
    /// Full screen, maximized and the like, as asked and as shown.
    state: core.WindowStateSync = .{},
    activated: bool = false,
    focused: bool = false,
    scale: u32 = 1,
    preferred_scale: i32 = 0,
    outputs: std.ArrayList(u32) = .empty,
    /// The software renderer's framebuffer (the content, in physical
    /// pixels: kept between frames, only what changed is redrawn).
    framebuffer: []Rgba8 = &.{},
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,
    software: zigulee.software.Renderer(Rgba8),
    buffers: [2]Buffer = .{ .{}, .{} },
    /// The buffer last shown, and how many have been.
    last_buffer: ?usize = null,
    presented: u32 = 0,
    full_redraw: bool = true,
    /// Drawn but not yet shown (no buffer was free, or a frame was due).
    unshown: bool = false,
    frame_pending: bool = false,
    closed: bool = false,
    last_frame: u64 = 0,
    a11y: ?*atspi.Bridge = null,
    title: []u8 = &.{},
    cursor: input.MouseCursor = .default,
    /// The shape shown (the content's cursor, or a resize arrow).
    shown_cursor: ?u32 = null,
    scheme: core.ColorScheme = .light,
    close_pressed: bool = false,
    last_bar_click: u64 = 0,
    next: ?*Window = null,

    /// Opens a window showing `ui`, sized to `ui.size()` in logical pixels.
    /// `ui` must outlive the window.
    pub fn create(gpa: Allocator, ui: *core.Window, options: Options) Error!*Window {
        try init();
        const a = &app.?;
        const conn = a.conn;
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .ui = ui, .software = .init(gpa), .hidden = options.hidden };
        errdefer self.software.deinit();
        errdefer self.freeBuffers();
        const size = ui.size();
        self.width = @intFromFloat(@max(1, @round(size.width)));
        self.height = @intFromFloat(@max(1, @round(size.height)));
        self.title = try gpa.dupe(u8, options.title);
        errdefer gpa.free(self.title);

        self.surface = try a.addFor(.surface, self, 0);
        try conn.request(a.compositor, 0, &.{.{ .object = self.surface }});
        self.xdg_surface = try a.addFor(.xdg_surface, self, 0);
        try conn.request(a.wm_base, 2, &.{ .{ .object = self.xdg_surface }, .{ .object = self.surface } });
        self.toplevel = try a.addFor(.toplevel, self, 0);
        try conn.request(self.xdg_surface, 1, &.{.{ .object = self.toplevel }});
        try conn.request(self.toplevel, 2, &.{.{ .string = options.title }}); // set_title
        try conn.request(self.toplevel, 3, &.{.{ .string = "zigulee" }}); // set_app_id
        if (a.decoration_manager != 0) {
            // Ask for the compositor's title bar.
            self.decoration = try a.addFor(.decoration, self, 0);
            try conn.request(a.decoration_manager, 1, &.{ .{ .object = self.decoration }, .{ .object = self.toplevel } });
            try conn.request(self.decoration, 1, &.{.{ .uint = 2 }});
        }
        if (!options.resizable) {
            const h: i32 = @intCast(self.height + (if (a.decoration_manager == 0) @as(u32, bar_height) else 0));
            for ([_]u16{ 7, 8 }) |opcode| try conn.request(self.toplevel, opcode, &.{ .{ .int = @intCast(self.width) }, .{ .int = h } });
        }
        try conn.request(self.surface, 6, &.{}); // commit: asks for a configure
        self.next = open_windows;
        open_windows = self;
        errdefer open_windows = self.next;

        // The first configure.
        const until = now() + 5000;
        while (!self.configured) {
            if (now() > until) return error.ConfigureTimeout;
            if (try conn.next(100)) |m| {
                var msg = m;
                try handleEvent(&msg);
            }
        }
        self.updateScale();
        try self.syncSize();

        ui.clipboard = .{ .ctx = self, .getFn = getClipboard, .setFn = setClipboard };
        self.a11y = atspi.Bridge.create(gpa, ui, .{}) catch |err| blk: {
            log.info("no screen reader support (AT-SPI: {t})", .{err});
            break :blk null;
        };
        if (self.a11y) |b| b.title = self.title;
        return self;
    }

    pub fn show(self: *Window) void {
        self.hidden = false;
        self.full_redraw = true;
    }

    pub fn destroy(self: *Window) void {
        var link = &open_windows;
        while (link.*) |w| : (link = &w.next) if (w == self) {
            link.* = self.next;
            break;
        };
        if (self.a11y) |b| b.destroy();
        self.ui.clipboard = null;
        if (app) |*a| {
            if (a.keyboard_focus == self) {
                a.keyboard_focus = null;
                a.repeat_key = null;
            }
            if (a.pointer_focus == self) a.pointer_focus = null;
            const conn = a.conn;
            for (&self.buffers) |*b| if (b.id != 0) conn.request(b.id, 0, &.{}) catch {};
            if (self.decoration != 0) conn.request(self.decoration, 0, &.{}) catch {};
            conn.request(self.toplevel, 0, &.{}) catch {};
            conn.request(self.xdg_surface, 0, &.{}) catch {};
            conn.request(self.surface, 0, &.{}) catch {};
            conn.flush() catch {};
            // Their remaining events go nowhere.
            var it = a.objects.iterator();
            while (it.next()) |e| if (e.value_ptr.window == self) {
                e.value_ptr.window = null;
            };
        }
        self.outputs.deinit(self.gpa);
        self.software.deinit();
        self.freeBuffers();
        self.gpa.free(self.title);
        self.gpa.destroy(self);
    }

    fn freeBuffers(self: *Window) void {
        for (&self.buffers) |*b| {
            if (b.memory.len > 0) _ = c.munmap(b.memory.ptr, b.memory.len);
            b.* = .{};
        }
        self.gpa.free(self.framebuffer);
        self.framebuffer = &.{};
    }

    /// Shows another zigulee window in this one (live reloading), sized to
    /// the current window. `ui` must outlive the window or the next call.
    pub fn setUi(self: *Window, ui: *core.Window) Error!void {
        self.ui.clipboard = null;
        if (self.a11y) |b| b.destroy();
        self.a11y = null;
        self.ui = ui;
        ui.clipboard = .{ .ctx = self, .getFn = getClipboard, .setFn = setClipboard };
        self.a11y = atspi.Bridge.create(self.gpa, ui, .{}) catch null;
        if (self.a11y) |b| b.title = self.title;
        ui.setSize(.{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) });
        self.full_redraw = true;
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        const copy = self.gpa.dupe(u8, title) catch return;
        self.gpa.free(self.title);
        self.title = copy;
        if (self.a11y) |b| b.title = copy;
        app.?.conn.request(self.toplevel, 2, &.{.{ .string = title }}) catch {};
    }

    /// Physical pixels per logical pixel.
    pub fn scaleFactor(self: *const Window) f32 {
        return self.software.scale_factor;
    }

    pub fn run(self: *Window) Error!void {
        while (!self.closed) try self.step(null);
    }

    /// One event loop iteration, for every open window (see `step`).
    pub fn step(_: *Window, max_wait_ms: ?u32) Error!void {
        return step_(max_wait_ms);
    }

    fn needsFrame(self: *const Window) bool {
        return self.full_redraw or self.unshown or self.ui.redraw_requested or core.hasActiveAnimations();
    }

    /// Whether a frame can be shown now (else: wait for the compositor).
    fn canPresent(self: *const Window) bool {
        return self.configured and !self.hidden and !self.frame_pending;
    }

    fn barHeight(self: *const Window) u32 {
        return if (self.csd) bar_height else 0;
    }

    /// The window put in the state the app asks for, if that changed.
    fn updateState(self: *Window) Error!void {
        const conn = app.?.conn;
        const before = self.state.shown;
        const want = self.state.sync(self.ui) orelse return;
        if (want.fullscreen != before.fullscreen) {
            if (want.fullscreen) {
                try conn.request(self.toplevel, 11, &.{.{ .object = 0 }}); // set_fullscreen, on any output
            } else try conn.request(self.toplevel, 12, &.{}); // unset_fullscreen
        }
        if (want.maximized != before.maximized) try conn.request(self.toplevel, if (want.maximized) 9 else 10, &.{});
        if (want.minimized and !before.minimized) try conn.request(self.toplevel, 13, &.{}); // set_minimized
    }

    fn afterEvents(self: *Window) Error!void {
        if (self.needsFrame() and self.canPresent()) try self.render();
        try self.updateState();
        const scheme = self.ui.colorScheme();
        if (scheme != self.scheme) {
            self.scheme = scheme;
            self.full_redraw = true; // the title bar's colors
        }
        if (self.ui.mouseCursor() != self.cursor) {
            self.cursor = self.ui.mouseCursor();
            try self.applyCursor(false);
        }
        if (self.a11y) |b| {
            b.scale = self.software.scale_factor;
            b.setActive(self.focused or self.activated);
            b.update() catch |err| if (err == error.OutOfMemory) return error.OutOfMemory;
        }
    }

    // ---- Configuration, size, scale ----

    fn surfaceConfigure(self: *Window, serial: u32) Error!void {
        const conn = app.?.conn;
        try conn.request(self.xdg_surface, 4, &.{.{ .uint = serial }}); // ack_configure
        // 0: our choice. The size includes our title bar.
        if (self.pending_width > 0) self.width = @intCast(self.pending_width);
        if (self.pending_height > 0) self.height = @intCast(@max(1, self.pending_height - @as(i32, @intCast(self.barHeight()))));
        self.configured = true;
        try self.syncSize();
    }

    fn outputEntered(self: *Window, output: u32, entered: bool) void {
        if (entered) {
            self.outputs.append(self.gpa, output) catch {};
        } else for (self.outputs.items, 0..) |o, i| if (o == output) {
            _ = self.outputs.swapRemove(i);
            break;
        };
        self.updateScale();
    }

    /// The scale: what the compositor prefers, else the largest of the
    /// outputs the window is on.
    fn updateScale(self: *Window) void {
        const a = &app.?;
        var scale: i32 = 1;
        if (self.preferred_scale > 0) {
            scale = self.preferred_scale;
        } else for (self.outputs.items) |id| for (a.outputs.items) |o| if (o.id == id) {
            scale = @max(scale, o.scale);
        };
        const s: u32 = @intCast(@max(1, scale));
        if (s == self.scale) return;
        self.scale = s;
        self.syncSize() catch log.err("could not resize the framebuffer", .{});
    }

    /// Follows the content's size and the scale.
    fn syncSize(self: *Window) Error!void {
        self.software.scale_factor = @floatFromInt(self.scale);
        self.ui.setSize(.{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) });
        self.full_redraw = true;
        const pw = self.width * self.scale;
        const ph = self.height * self.scale;
        if (pw == self.pixel_width and ph == self.pixel_height and self.framebuffer.len > 0) return;
        const framebuffer = try self.gpa.alloc(Rgba8, @as(usize, pw) * ph);
        @memset(framebuffer, .transparent);
        self.gpa.free(self.framebuffer);
        self.framebuffer = framebuffer;
        self.pixel_width = pw;
        self.pixel_height = ph;
    }

    /// A buffer of the surface's size (content and title bar), not in use.
    fn freeBuffer(self: *Window) Error!?*Buffer {
        const a = &app.?;
        const w = self.pixel_width;
        const h = self.pixel_height + self.barHeight() * self.scale;
        for (&self.buffers, 0..) |*b, i| {
            if (b.id != 0 and (b.width != w or b.height != h)) {
                // The old size: replaced.
                try a.conn.request(b.id, 0, &.{});
                _ = c.munmap(b.memory.ptr, b.memory.len);
                b.* = .{};
            }
            if (b.id == 0) {
                const size = @as(usize, w) * h * 4;
                const fd = memfdCreate("zigulee", std.os.linux.MFD.CLOEXEC);
                if (fd < 0) return error.Disconnected;
                if (c.ftruncate(fd, @intCast(size)) != 0) {
                    _ = c.close(fd);
                    return error.OutOfMemory;
                }
                const mem = c.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
                if (mem == c.MAP_FAILED) {
                    _ = c.close(fd);
                    return error.OutOfMemory;
                }
                const pool = try a.add(.other);
                try a.conn.request(a.shm, 0, &.{ .{ .object = pool }, .{ .fd = fd }, .{ .int = @intCast(size) } });
                b.id = try a.addFor(.buffer, self, @intCast(i));
                try a.conn.request(pool, 0, &.{ .{ .object = b.id }, .{ .int = 0 }, .{ .int = @intCast(w) }, .{ .int = @intCast(h) }, .{ .int = @intCast(w * 4) }, .{ .uint = 1 } }); // XRGB8888
                try a.conn.request(pool, 1, &.{}); // the pool can go: the buffer keeps the memory
                b.memory = @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(mem)))[0..size];
                b.width = w;
                b.height = h;
                b.stale = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) };
            }
            if (!b.busy) return b;
        }
        return null;
    }

    // ---- Drawing ----

    /// Draws what changed and shows it (in a buffer brought up to date).
    pub fn render(self: *Window) Error!void {
        self.last_frame = now();
        const s: f32 = @floatFromInt(self.scale);
        const bar: f32 = @floatFromInt(self.barHeight() * self.scale);
        var changed: core.Rect = .empty;
        if (self.needsFrame()) {
            const full = self.full_redraw;
            const canvas: zigulee.software.Canvas(Rgba8) = .init(self.framebuffer, self.pixel_width, self.pixel_height);
            const region = try self.software.renderWindow(self.ui, canvas, if (full) .full else .partial);
            self.full_redraw = false;
            const box = region.boundingBox();
            if (!box.isEmpty()) changed = .{ .x = box.x, .y = box.y + bar, .width = box.width, .height = box.height };
            if (full) changed = .{ .width = @floatFromInt(self.pixel_width), .height = @as(f32, @floatFromInt(self.pixel_height)) + bar };
        }
        _ = s;
        for (&self.buffers) |*b| if (b.id != 0) {
            b.stale = b.stale.unionWith(changed);
        };
        if (changed.isEmpty() and !self.unshown) return;
        const b = try self.freeBuffer() orelse {
            self.unshown = true; // when one is released
            return;
        };
        b.stale = b.stale.unionWith(changed);
        self.copyInto(b);
        const conn = app.?.conn;
        try conn.request(self.surface, 1, &.{ .{ .object = b.id }, .{ .int = 0 }, .{ .int = 0 } }); // attach
        if (app.?.compositor_version >= 3) try conn.request(self.surface, 8, &.{.{ .int = @intCast(self.scale) }}); // set_buffer_scale
        const damage = if (changed.isEmpty()) core.Rect{ .width = @floatFromInt(b.width), .height = @floatFromInt(b.height) } else changed;
        if (app.?.compositor_version >= 4) {
            try conn.request(self.surface, 9, &.{ .{ .int = @intFromFloat(@floor(damage.x)) }, .{ .int = @intFromFloat(@floor(damage.y)) }, .{ .int = @intFromFloat(@ceil(damage.width + 1)) }, .{ .int = @intFromFloat(@ceil(damage.height + 1)) } });
        } else try conn.request(self.surface, 2, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = std.math.maxInt(i32) }, .{ .int = std.math.maxInt(i32) } });
        const callback = try app.?.addFor(.frame, self, 0);
        try conn.request(self.surface, 3, &.{.{ .object = callback }}); // frame
        try conn.request(self.surface, 6, &.{}); // commit
        b.busy = true;
        self.frame_pending = true;
        self.unshown = false;
        self.last_buffer = (@intFromPtr(b) - @intFromPtr(&self.buffers[0])) / @sizeOf(Buffer);
        self.presented += 1;
    }

    /// Brings a buffer up to date: its stale rectangle, from the title bar
    /// and the framebuffer.
    fn copyInto(self: *Window, b: *Buffer) void {
        const r = b.stale;
        b.stale = .empty;
        if (r.isEmpty()) return;
        const x0: u32 = @intFromFloat(std.math.clamp(@floor(r.x), 0, @as(f32, @floatFromInt(b.width))));
        const y0: u32 = @intFromFloat(std.math.clamp(@floor(r.y), 0, @as(f32, @floatFromInt(b.height))));
        const x1: u32 = @intFromFloat(std.math.clamp(@ceil(r.x + r.width), 0, @as(f32, @floatFromInt(b.width))));
        const y1: u32 = @intFromFloat(std.math.clamp(@ceil(r.y + r.height), 0, @as(f32, @floatFromInt(b.height))));
        const bar = self.barHeight() * self.scale;
        const pixels = b.pixels();
        for (y0..y1) |y| {
            const out = pixels[y * b.width ..][x0..x1];
            if (y < bar) {
                for (out, x0..) |*p, x| p.* = self.barPixel(@intCast(x), @intCast(y), b.width);
            } else {
                const row = (y - bar) * self.pixel_width;
                for (self.framebuffer[row + x0 .. row + x1], out) |p, *q| q.* = 0xff000000 | @as(u32, p.r) << 16 | @as(u32, p.g) << 8 | p.b;
            }
        }
    }

    /// Our title bar's pixel at (x, y): its background, and a close button
    /// (an ×) on the right.
    fn barPixel(self: *const Window, x: u32, y: u32, width: u32) u32 {
        const dark = self.scheme == .dark;
        const background: u32 = if (dark) 0xff2b2b2b else 0xffebebeb;
        const foreground: u32 = if (dark) 0xffe0e0e0 else 0xff303030;
        const s = self.scale;
        const size = bar_height * s;
        if (x + size < width) return background;
        // The × in the last square, 2 logical pixels thick.
        const bx: i32 = @intCast(x - (width - size));
        const by: i32 = @intCast(y);
        const lo: i32 = @intCast(11 * s);
        const hi: i32 = @intCast(21 * s);
        if (bx < lo or bx > hi or by < lo or by > hi) return if (self.close_pressed) (if (dark) 0xff444444 else 0xffd0d0d0) else background;
        const thick: i32 = @intCast(s);
        if (@abs(bx - by) <= thick or @abs(bx + by - lo - hi) <= thick) return foreground;
        return if (self.close_pressed) (if (dark) 0xff444444 else 0xffd0d0d0) else background;
    }

    // ---- Input ----

    /// Where a resize from (x, y) would grab (xdg_toplevel edges), or 0.
    fn edgeAt(self: *const Window, x: f32, y: f32) u32 {
        if (!self.csd or self.maximized) return 0;
        const w: f32 = @floatFromInt(self.width);
        const h: f32 = @floatFromInt(self.height + self.barHeight());
        var edges: u32 = 0;
        if (y < resize_margin) edges |= 1;
        if (y >= h - resize_margin) edges |= 2;
        if (x < resize_margin) edges |= 4;
        if (x >= w - resize_margin) edges |= 8;
        return edges;
    }

    fn pointerMoved(self: *Window, x: f32, y: f32) void {
        const a = &app.?;
        a.pointer_position = .{ .x = x, .y = y };
        self.applyCursor(false) catch {};
        const bar: f32 = @floatFromInt(self.barHeight());
        if (y < bar or self.edgeAt(x, y) != 0) return;
        self.ui.dispatchPointer(.{ .moved = .{ .position = .{ .x = x, .y = y - bar } } });
    }

    fn pointerButton(self: *Window, code: u32, pressed: bool) Error!void {
        const a = &app.?;
        const p = a.pointer_position;
        const bar: f32 = @floatFromInt(self.barHeight());
        const button: input.PointerButton = switch (code) {
            0x110 => .left,
            0x111 => .right,
            0x112 => .middle,
            else => .other,
        };
        // Our title bar and edges.
        if (self.csd) {
            const in_close = p.y < bar and p.x >= @as(f32, @floatFromInt(self.width)) - bar_height;
            if (!pressed and self.close_pressed) {
                self.close_pressed = false;
                self.full_redraw = true;
                if (in_close) self.closed = true;
                return;
            }
            // The window manager's actions need the seat (headless
            // compositors may have none).
            const edges = if (in_close or a.seat == 0) 0 else self.edgeAt(p.x, p.y);
            if (pressed and button == .left and edges != 0) {
                return a.conn.request(self.toplevel, 6, &.{ .{ .object = a.seat }, .{ .uint = a.input_serial }, .{ .uint = edges } }); // resize
            }
            if (p.y < bar) {
                if (!pressed) return;
                if (button == .right and a.seat != 0) return a.conn.request(self.toplevel, 4, &.{ .{ .object = a.seat }, .{ .uint = a.input_serial }, .{ .int = @intFromFloat(p.x) }, .{ .int = @intFromFloat(p.y) } }); // show_window_menu
                if (button != .left) return;
                if (in_close) {
                    self.close_pressed = true;
                    self.full_redraw = true;
                    return;
                }
                // Double click: maximize (or back); else drag to move.
                if (now() - self.last_bar_click < 400) {
                    self.last_bar_click = 0;
                    return a.conn.request(self.toplevel, if (self.maximized) 10 else 9, &.{});
                }
                self.last_bar_click = now();
                if (a.seat == 0) return;
                return a.conn.request(self.toplevel, 5, &.{ .{ .object = a.seat }, .{ .uint = a.input_serial } }); // move
            }
        }
        const position: core.Point = .{ .x = p.x, .y = p.y - bar };
        self.ui.dispatchPointer(if (pressed)
            .{ .pressed = .{ .position = position, .button = button, .modifiers = a.mods } }
        else
            .{ .released = .{ .position = position, .button = button } });
    }

    fn pointerWheel(self: *Window, delta: core.Point) void {
        const p = app.?.pointer_position;
        const bar: f32 = @floatFromInt(self.barHeight());
        if (p.y < bar) return;
        self.ui.dispatchPointer(.{ .wheel = .{ .position = .{ .x = p.x, .y = p.y - bar }, .delta = delta } });
    }

    /// The cursor: the content's, or a resize arrow over the edges
    /// (`force`: even if it did not change).
    fn applyCursor(self: *Window, force: bool) Error!void {
        const a = &app.?;
        if (a.pointer_focus != self or a.pointer == 0) return;
        const p = a.pointer_position;
        const in_bar = p.y < @as(f32, @floatFromInt(self.barHeight()));
        const in_close = in_bar and p.x >= @as(f32, @floatFromInt(self.width)) - bar_height;
        const edges = if (in_close) 0 else self.edgeAt(p.x, p.y);
        const shape: u32 = if (edges != 0) edgeShape(edges) else if (in_bar) 1 else cursorShape(self.cursor);
        if (!force and self.shown_cursor == shape) return;
        self.shown_cursor = shape;
        if (shape == 0) {
            // Hidden: no cursor surface.
            return a.conn.request(a.pointer, 0, &.{ .{ .uint = a.pointer_serial }, .{ .object = 0 }, .{ .int = 0 }, .{ .int = 0 } });
        }
        if (a.cursor_shape_device != 0) try a.conn.request(a.cursor_shape_device, 1, &.{ .{ .uint = a.pointer_serial }, .{ .uint = shape } });
    }

    /// A key pressed or released (evdev code).
    fn keyEvent(self: *Window, code: u32, pressed: bool, repeat: bool) void {
        const a = &app.?;
        const k = if (a.keyboard) |*k| k else return;
        const mods = a.mods;
        const kind: input.KeyEventKind = if (pressed) .pressed else .released;
        if (pressed and !repeat and k.repeats(code)) {
            a.repeat_key = code;
            a.repeat_next = now() + a.repeat_delay;
        } else if (!pressed and a.repeat_key == code) a.repeat_key = null;
        if (a.repeat_rate == 0) a.repeat_key = null;

        const key = if (pressed) k.press(code) else xkb.Key{ .sym = k.keysym(code), .text = "" };
        if (specialKey(key.sym, mods)) |text| return self.ui.dispatchKey(kind, .{ .text = text, .modifiers = mods, .repeat = repeat });
        // Shortcuts (Ctrl+C, Ctrl+S, ...): the key, lower case.
        if (mods.control and !a.altgr and key.sym < 0x80 and std.ascii.isAlphanumeric(@intCast(key.sym))) {
            return self.ui.dispatchKey(kind, .{ .text = ascii[std.ascii.toLower(@intCast(key.sym))..][0..1], .modifiers = mods, .repeat = repeat });
        }
        if (!pressed or key.text.len == 0 or key.text[0] < 0x20 or key.text[0] == 0x7f) return;
        self.ui.dispatchKey(.pressed, .{ .text = key.text, .repeat = repeat });
        self.ui.dispatchKey(.released, .{ .text = key.text });
    }
};

const step_ = step;

const ascii: [128]u8 = blk: {
    var t: [128]u8 = undefined;
    for (&t, 0..) |*b, i| b.* = i;
    break :blk t;
};

/// zigulee's code for a special key, from its keysym (X11 keysyms).
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

/// wp_cursor_shape_device_v1 shapes (0: hidden).
fn cursorShape(cursor: input.MouseCursor) u32 {
    return switch (cursor) {
        .none => 0,
        .default => 1,
        .help => 3,
        .pointer => 4,
        .progress => 5,
        .wait => 6,
        .crosshair => 8,
        .text => 9,
        .move => 13,
        .not_allowed => 15,
        .grab => 16,
        .grabbing => 17,
        .ew_resize => 26,
        .ns_resize => 27,
        .nesw_resize => 28,
        .nwse_resize => 29,
        .col_resize => 30,
        .row_resize => 31,
    };
}

fn edgeShape(edges: u32) u32 {
    return switch (edges) {
        1 => 19, // n
        2 => 22, // s
        4 => 25, // w
        8 => 18, // e
        5 => 21, // nw
        9 => 20, // ne
        6 => 24, // sw
        10 => 23, // se
        else => 1,
    };
}

// ---- The clipboard (the seat's selection) ----

fn setClipboard(_: ?*anyopaque, text: []const u8) void {
    const a = &(app orelse return);
    if (a.data_device_manager == 0 or a.data_device == 0) return;
    const copy = a.gpa.dupe(u8, text) catch return;
    if (a.source_text) |t| a.gpa.free(t);
    a.source_text = copy;
    a.source = a.add(.data_source) catch return;
    a.conn.request(a.data_device_manager, 0, &.{.{ .object = a.source }}) catch return;
    for (text_mimes) |mime| a.conn.request(a.source, 0, &.{.{ .string = mime }}) catch return;
    a.conn.request(a.data_device, 1, &.{ .{ .object = a.source }, .{ .uint = a.input_serial } }) catch return;
    a.conn.flush() catch {};
}

fn getClipboard(_: ?*anyopaque, gpa: Allocator) ?[]u8 {
    return receiveClipboard(gpa) catch |err| {
        log.info("clipboard: {t}", .{err});
        return null;
    };
}

/// Asks the selection's owner for its text, and reads it (at most 1 s,
/// handling events meanwhile: the owner may be us).
fn receiveClipboard(gpa: Allocator) Error!?[]u8 {
    const a = &app.?;
    if (a.offer == 0) return null;
    const mime = a.offer_mime orelse return null;
    return try receiveOffer(gpa, a.offer, mime);
}

/// A drag over a window moved: whether a DropArea there takes it, told to
/// the compositor (by accepting the type, or none).
fn dragMoved() Error!void {
    const a = &app.?;
    const w = a.dnd_window orelse return;
    const ok = a.dnd_kind.len > 0 and dnd.externalMoved(w.ui, &.{a.dnd_kind}, a.dnd_at);
    if (a.dnd_offer == 0) return;
    if (ok) {
        try a.conn.request(a.dnd_offer, 0, &.{ .{ .uint = a.dnd_serial }, .{ .string = a.dnd_mime.? } }); // accept
    } else {
        try a.conn.request(a.dnd_offer, 0, &.{ .{ .uint = a.dnd_serial }, .{ .string = null } });
    }
}

/// Dropped: its files (paths, one per line) or text, read and handed over.
fn dragDropped() Error!void {
    const a = &app.?;
    defer endDrag() catch {};
    const w = a.dnd_window orelse return;
    const mime = a.dnd_mime orelse return dnd.externalLeft(w.ui);
    if (a.dnd_offer == 0) return dnd.externalLeft(w.ui);
    const data = receiveOffer(a.gpa, a.dnd_offer, mime) catch |err| {
        log.info("drop: {t}", .{err});
        return dnd.externalLeft(w.ui);
    } orelse return dnd.externalLeft(w.ui);
    defer a.gpa.free(data);
    if (std.mem.eql(u8, a.dnd_kind, dnd.file_kind)) {
        const paths = try dnd.pathsFromUriList(a.gpa, data);
        defer a.gpa.free(paths);
        _ = dnd.externalDropped(w.ui, dnd.file_kind, paths, a.dnd_at);
    } else _ = dnd.externalDropped(w.ui, dnd.text_kind, data, a.dnd_at);
    if (a.data_device_version >= 3) try a.conn.request(a.dnd_offer, 3, &.{}); // finish
}

fn endDrag() Error!void {
    const a = &app.?;
    if (a.dnd_offer != 0) try a.conn.request(a.dnd_offer, 2, &.{}); // destroy
    a.dnd_offer = 0;
    a.dnd_window = null;
    a.dnd_kind = "";
    a.dnd_mime = null;
}

/// Reads offer `offer` as `mime` (at most 1 s, handling events meanwhile:
/// its owner may be us).
fn receiveOffer(gpa: Allocator, offer: u32, mime: []const u8) Error!?[]u8 {
    const a = &app.?;
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.Disconnected;
    defer _ = c.close(fds[0]);
    try a.conn.request(offer, 1, &.{ .{ .string = mime }, .{ .fd = fds[1] } }); // receive
    try a.conn.flush(); // sends (and closes) the write end
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    const until = now() + 1000;
    while (true) {
        const left = until -| now();
        if (left == 0) return error.Timeout;
        var p = [2]c.pollfd{
            .{ .fd = fds[0], .events = c.POLL.IN, .revents = 0 },
            .{ .fd = a.conn.fd, .events = c.POLL.IN, .revents = 0 },
        };
        _ = c.poll(&p, 2, @intCast(left));
        if (p[1].revents != 0 or a.conn.pending()) {
            while (try a.conn.next(0)) |m| {
                var msg = m;
                try handleEvent(&msg);
            }
            try a.conn.flush();
        }
        if (p[0].revents != 0) {
            var buf: [4096]u8 = undefined;
            const n = c.read(fds[0], &buf, buf.len);
            if (n <= 0) break; // the end
            try text.appendSlice(gpa, buf[0..@intCast(n)]);
        }
    }
    return try text.toOwnedSlice(gpa);
}

// ---- Tests (on a compositor: weston --backend=headless) ----

const testing = std.testing;

fn initOrSkip() !void {
    init() catch |err| {
        log.info("no Wayland compositor ({t}): skipped", .{err});
        return error.SkipZigTest;
    };
}

fn stepUntil(ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
    const until = now() + 3000;
    while (!cond(ctx)) {
        if (now() > until) return error.Timeout;
        try step(20);
    }
}

/// The pixel last shown at (x, y) logical pixels of the content.
fn shownPixel(w: *Window, x: f32, y: f32) core.Color {
    const b = &w.buffers[w.last_buffer.?];
    const s: f32 = @floatFromInt(w.scale);
    const px: usize = @intFromFloat(x * s);
    const py: usize = @intFromFloat((y + @as(f32, @floatFromInt(w.barHeight()))) * s);
    return .rgb(@truncate(b.pixels()[py * b.width + px]));
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

fn presented(w: *Window) bool {
    return w.presented > 0 and !w.needsFrame();
}

test "a native window: shown, clicked, typed in, resized, closed" {
    try initOrSkip();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    const w = try Window.create(testing.allocator, &t.ui, .{ .title = "test" });
    defer w.destroy();

    // Configured and shown: what the compositor is given.
    try stepUntil(w, presented);
    try testing.expectEqual(core.Size{ .width = 120, .height = 80 }, t.ui.size());
    try testing.expectEqual(core.Color.rgb(0xff0000), shownPixel(w, 20, 20));
    try testing.expectEqual(core.Color.white, shownPixel(w, 100, 70));
    if (w.csd) try testing.expectEqual(core.Color.rgb(0xebebeb), shownPixel(w, 5, -20)); // our title bar

    // A click (as the compositor sends it: the bar's height included).
    const a = &app.?;
    a.pointer_focus = w;
    const bar: f32 = @floatFromInt(w.barHeight());
    w.pointerMoved(30, 20 + bar);
    try w.pointerButton(0x110, true);
    try w.pointerButton(0x110, false);
    try testing.expectEqual(@as(usize, 1), t.clicks);
    const before = w.presented;
    try stepUntil(w, struct {
        fn f(win: *Window) bool {
            return win.presented > 0 and !win.needsFrame();
        }
    }.f);
    try testing.expect(w.presented > before);
    try testing.expectEqual(core.Color.rgb(0x0000ff), shownPixel(w, 20, 20));

    // Keys, through a US keymap: text with Shift, special keys, Ctrl+C.
    if (a.keyboard) |*k| if (k.setKeymapNames(.{ .layout = "us" })) {
        t.keys.focus();
        const shift = 1; // modifier masks: Shift, Control
        const control = 4;
        w.keyEvent(35, true, false); // h
        w.keyEvent(35, false, false);
        setModifiers(shift, 0, 0, 0);
        w.keyEvent(30, true, false); // a
        w.keyEvent(30, false, false);
        setModifiers(0, 0, 0, 0);
        w.keyEvent(28, true, false); // Enter
        w.keyEvent(105, true, false); // Left
        setModifiers(control, 0, 0, 0);
        w.keyEvent(46, true, false); // c
        setModifiers(0, 0, 0, 0);
        try testing.expectEqualStrings("hA" ++ Key.@"return" ++ Key.left_arrow ++ "c", t.typed[0..t.typed_len]);
        a.repeat_key = null;

        // A dead key, then a letter: one composed character.
        if (k.compose != null and k.setKeymapNames(.{ .layout = "us", .variant = "intl" })) {
            t.typed_len = 0;
            w.keyEvent(40, true, false); // ' (dead acute)
            w.keyEvent(18, true, false); // e
            a.repeat_key = null;
            try testing.expectEqualStrings("é", t.typed[0..t.typed_len]);
        }
    };

    // The compositor resizes the window (the size includes our title bar).
    w.pending_width = 200;
    w.pending_height = @intCast(150 + w.barHeight());
    w.width = 200;
    w.height = 150;
    try w.syncSize();
    try testing.expectEqual(core.Size{ .width = 200, .height = 150 }, t.ui.size());
    try stepUntil(w, presented);
    try testing.expectEqual(@as(u32, 200 * w.scale), w.buffers[w.last_buffer.?].width);
    try testing.expectEqual(core.Color.white, shownPixel(w, 195, 145));

    // The close button of our title bar, or the compositor's close.
    if (w.csd) {
        w.pointerMoved(200 - bar_height / 2, bar_height / 2);
        try w.pointerButton(0x110, true);
        try w.pointerButton(0x110, false);
    } else w.closed = true;
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
    try step(0);

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
}

test "the clipboard goes through the compositor" {
    try initOrSkip();
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 60, .height = 30 });
    defer ui.deinit();
    const w = try Window.create(testing.allocator, &ui, .{});
    defer w.destroy();
    try stepUntil(w, presented);
    ui.clipboard.?.setFn(w, "zigulee\nclipboard é");
    try app.?.roundTrip();
    const text = ui.clipboardText(testing.allocator) orelse {
        // The compositor only gives the selection to focused clients.
        log.info("no selection (no seat, or no keyboard focus): skipped", .{});
        return error.SkipZigTest;
    };
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("zigulee\nclipboard é", text);
}

test {
    _ = protocol;
}

/// `memfd_create` as a system call: glibc only has it from 2.27, and
/// older systems (2.25 on some ARM boards) are targets too.
fn memfdCreate(name: [*:0]const u8, flags: u32) c_int {
    const rc = std.os.linux.memfd_create(name, flags);
    return if (std.os.linux.errno(rc) == .SUCCESS) @intCast(rc) else -1;
}
