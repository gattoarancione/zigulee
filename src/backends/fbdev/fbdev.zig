// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The fbdev backend (`zigulee-fbdev`): a `zigulee.Window` full screen on the
//! Linux framebuffer device (/dev/fb0), with no desktop: older kernels
//! and boards whose display has no DRM driver (SPI panels with fbtft,
//! vendor kernels). Where there is a DRM driver, the KMS backend is the
//! better choice (it falls back to this screen when there is none).
//! Same interface as the other backends:
//!
//!     try fbdev.init();
//!     defer fbdev.deinit();
//!     const window = try fbdev.Window.create(gpa, &ui_window, .{});
//!     defer window.destroy();
//!     try window.run();
//!
//! The window takes the screen's size divided by the scale (`ZIGULEE_SCALE`,
//! default 1). A panel mounted turned is set with `ZIGULEE_ROTATION` (or
//! `Options.rotation`): 90, 180 or 270 degrees clockwise. The window is
//! then drawn upright and turned as it is copied to the screen, touches
//! and the mouse turned back (cheaper than turning the content in `.zge`,
//! which draws every pixel through a transform). A touch panel covering
//! only part of the screen: `ZIGULEE_TOUCH_AREA` (`Options.touch_area`,
//! `WxH+X+Y` in screen pixels). It draws with the software renderer, converting to the
//! screen's pixel format (fb.zig), into the page not shown and pans to it
//! when the driver can, else in place. The device is `ZIGULEE_FB_DEVICE`,
//! else /dev/fb0. Input as with KMS (the kernel's event devices,
//! zigulee-evdev): keys through libxkbcommon when there is one, mice with a
//! cursor drawn in software, touchscreens as a pointer, Ctrl+Alt+Backspace
//! to close. The text console is in graphics mode meanwhile. The run needs
//! access to /dev/fb0 and /dev/input (the video and input groups), and to
//! the console (/dev/tty0, the tty group) or to run on it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const Rgba8 = core.Rgba8;
pub const fb = @import("fb.zig");
pub const evdev = @import("zigulee-evdev");
pub const Input = evdev.Input;
const xkb = @import("zigulee-xkb");
const c = std.c;

const log = std.log.scoped(.zigulee_fbdev);

pub const Error = fb.Error || error{AlreadyOpen};

pub const RendererKind = enum {
    /// The software renderer (the only one).
    auto,
    software,
};

/// Like the other backends' (the title and size do not apply: the window
/// is the screen).
pub const Options = struct {
    title: [:0]const u8 = "zigulee",
    resizable: bool = true,
    renderer: RendererKind = .auto,
    hidden: bool = false,
    /// How the screen shows the window, turned clockwise (null:
    /// `ZIGULEE_ROTATION`, else upright).
    rotation: ?Rotation = null,
    /// The part of the screen the touch panel covers, in screen pixels
    /// before the rotation (null: `ZIGULEE_TOUCH_AREA`, else all of it).
    touch_area: ?core.Rect = null,
};

pub const Rotation = evdev.Rotation;

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

/// The scale (`ZIGULEE_SCALE`, at least 1).
pub fn envScale() f32 {
    const s = c.getenv("ZIGULEE_SCALE") orelse return 1;
    return @max(1, std.fmt.parseFloat(f32, std.mem.span(s)) catch 1);
}

/// Whether there is a mouse among the devices (the cursor is shown).
pub fn hasMouse(devices: []const evdev.Device) bool {
    for (devices) |d| if (d.kind == .mouse) return true;
    return false;
}

const App = struct {
    screen: fb.Screen,
    console: fb.Console,
    devices: [16]evdev.Device = undefined,
    device_count: usize = 0,
    scale: f32 = 1,
};

var app: ?App = null;
var window: ?*Window = null;

/// Sound: the mixer plays through PipeWire (from `init` to `deinit`).
var audio_output: @import("zigulee-pipewire").Output = .{};

/// Opens the screen and the input devices. Called by `Window.create` if
/// needed.
pub fn init() Error!void {
    if (app != null) return;
    _ = now();
    var screen = try fb.Screen.open();
    errdefer screen.close();
    core.audio.mixer().setOutput(audio_output.output());
    core.video.addDecoder(@import("zigulee-gstreamer").decoder);
    var a: App = .{ .screen = screen, .console = .graphics(), .scale = envScale() };
    a.device_count = evdev.openAll(&a.devices);
    app = a;
    log.info("screen {d}x{d}, {d} input devices", .{ screen.width, screen.height, a.device_count });
}

/// Gives the screen and the console back and closes the devices (once
/// the window is destroyed).
pub fn deinit() void {
    if (window != null) return;
    const a = &(app orelse return);
    core.audio.mixer().setOutput(null);
    core.video.removeDecoder("gstreamer");
    for (a.devices[0..a.device_count]) |d| evdev.close(d);
    a.screen.close();
    a.console.restore();
    app = null;
}

pub const Window = struct {
    gpa: Allocator,
    ui: *core.Window,
    input: Input,
    /// The software renderer's framebuffer (physical pixels: kept between
    /// frames, only what changed is redrawn).
    framebuffer: []Rgba8 = &.{},
    pixel_width: u32,
    pixel_height: u32,
    software: zigulee.software.Renderer(Rgba8),
    full_redraw: bool = true,
    closed: bool = false,
    last_frame: u64 = 0,
    presented: u32 = 0,

    /// Shows `ui` full screen (one window at a time). `ui` must outlive the
    /// window.
    pub fn create(gpa: Allocator, ui: *core.Window, options: Options) Error!*Window {
        if (window != null) return error.AlreadyOpen;
        try init();
        const a = &app.?;
        const rotation = options.rotation orelse Rotation.fromEnv();
        a.screen.rotation = rotation;
        a.screen.invalidate(.{ .width = @floatFromInt(a.screen.width), .height = @floatFromInt(a.screen.height) });
        // The window's pixels: the screen's, turned.
        const w, const h = a.screen.pictureSize();
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        const lw = @as(f32, @floatFromInt(w)) / a.scale;
        const lh = @as(f32, @floatFromInt(h)) / a.scale;
        self.* = .{ .gpa = gpa, .ui = ui, .input = .{ .ui = ui, .scale = a.scale, .width = lw, .height = lh, .rotation = rotation, .touch_area = options.touch_area orelse evdev.touchAreaFromEnv() }, .pixel_width = w, .pixel_height = h, .software = .init(gpa) };
        errdefer self.software.deinit();
        self.software.scale_factor = a.scale;
        self.framebuffer = try gpa.alloc(Rgba8, @as(usize, w) * h);
        @memset(self.framebuffer, .transparent);
        ui.setSize(.{ .width = lw, .height = lh });
        self.input.position = .{ .x = lw / 2, .y = lh / 2 };
        if (xkb.Keyboard.init()) |k| {
            var kb = k;
            if (kb.setKeymapNames(.{})) self.input.keyboard = kb else kb.deinit();
        }
        window = self;
        return self;
    }

    pub fn destroy(self: *Window) void {
        window = null;
        if (app) |*a| a.screen.setCursor(null, 1);
        if (self.input.keyboard) |*k| k.deinit();
        self.software.deinit();
        self.gpa.free(self.framebuffer);
        self.gpa.destroy(self);
    }

    /// Shows another zigulee window (live reloading), sized to the screen.
    pub fn setUi(self: *Window, ui: *core.Window) Error!void {
        self.ui = ui;
        self.input.ui = ui;
        ui.setSize(.{ .width = self.input.width, .height = self.input.height });
        self.full_redraw = true;
    }

    pub fn setTitle(_: *Window, _: [:0]const u8) void {}

    pub fn show(_: *Window) void {}

    pub fn scaleFactor(self: *const Window) f32 {
        return self.software.scale_factor;
    }

    pub fn run(self: *Window) Error!void {
        while (!self.closed) try self.step(null);
    }

    pub fn step(_: *Window, max_wait_ms: ?u32) Error!void {
        return step_(max_wait_ms);
    }

    fn needsFrame(self: *const Window) bool {
        return self.full_redraw or self.ui.redraw_requested or core.hasActiveAnimations();
    }

    /// A frame to draw now (animations: every 16 ms at most, as there is
    /// no refresh to wait for).
    fn frameDue(self: *const Window) bool {
        return self.full_redraw or self.ui.redraw_requested or (core.hasActiveAnimations() and now() >= self.last_frame + 16);
    }

    /// Draws what changed and shows it, with the cursor.
    pub fn render(self: *Window) Error!void {
        const a = &app.?;
        var changed: core.Region = .{};
        if (self.frameDue()) {
            self.last_frame = now();
            const full = self.full_redraw;
            const canvas: zigulee.software.Canvas(Rgba8) = .init(self.framebuffer, self.pixel_width, self.pixel_height);
            const region = try self.software.renderWindow(self.ui, canvas, if (full) .full else .partial);
            self.full_redraw = false;
            // Each area on its own: two small changes far apart are not
            // copied with everything between them.
            changed = region;
            if (full) changed.add(.{ .width = @floatFromInt(self.pixel_width), .height = @floatFromInt(self.pixel_height) });
        }
        updateCursor(&a.screen, self.ui, &self.input, a.devices[0..a.device_count], a.scale);
        if (a.screen.present(self.framebuffer, changed.slice())) self.presented += 1;
    }

    fn afterEvents(self: *Window) Error!void {
        if (self.input.quit) self.closed = true;
        try self.render();
    }
};

/// The cursor drawn on `screen`: shown while there is a mouse and the
/// window wants one, at the pointer.
pub fn updateCursor(screen: *fb.Screen, ui: *core.Window, in: *Input, devices: []const evdev.Device, scale: f32) void {
    const shown = hasMouse(devices) and ui.mouseCursor() != .none;
    const dot: u32 = @intFromFloat(@min(3, @max(1, scale)));
    const w, const h = screen.pictureSize();
    const tip = screen.rotation.toScreen(.{ .x = in.position.x * scale, .y = in.position.y * scale }, @floatFromInt(w), @floatFromInt(h));
    screen.setCursor(if (shown) tip else null, dot);
    in.cursor_moved = false;
}

const step_ = step;

/// One event loop iteration: waits for input (at most `max_wait_ms`, or
/// until the next timer or frame), handles it, fires timers, runs change
/// handlers and draws what changed.
pub fn step(max_wait_ms: ?u32) Error!void {
    const a = &(app orelse return);
    const w = window orelse return;
    core.updateTimersAndAnimations(now());
    var timeout: ?u64 = null;
    if (w.needsFrame()) {
        const next = if (core.hasActiveAnimations() and !w.full_redraw and !w.ui.redraw_requested) w.last_frame + 16 else 0;
        timeout = next -| now();
    }
    if (core.nextTimerDeadline()) |deadline| timeout = @min(timeout orelse std.math.maxInt(u64), deadline -| now());
    if (max_wait_ms) |m| timeout = if (timeout) |t| @min(t, m) else m;

    var fds: [16]c.pollfd = undefined;
    for (a.devices[0..a.device_count], 0..) |d, i| fds[i] = .{ .fd = d.fd, .events = c.POLL.IN, .revents = 0 };
    const ms: c_int = if (timeout) |t| @intCast(@min(t, std.math.maxInt(i32))) else -1;
    if (c.poll(&fds, @intCast(a.device_count), ms) > 0) {
        for (a.devices[0..a.device_count], 0..) |d, i| if (fds[i].revents != 0) {
            var buf: [64]evdev.Event = undefined;
            w.input.handle(d, evdev.read(d, &buf));
        };
    }

    core.updateTimersAndAnimations(now());
    core.runChangeHandlers();
    try w.afterEvents();
}

pub fn runAll() Error!void {
    while (window) |w| {
        if (w.closed) return;
        try step(null);
    }
}

// ---- Tests ----

const testing = std.testing;

test "a screen: the window drawn on it, in its format" {
    init() catch |err| {
        log.info("no framebuffer device ({t}): skipped", .{err});
        return error.SkipZigTest;
    };
    defer deinit();
    var t: evdev.TestUi = undefined;
    try t.init();
    defer t.deinit();
    const w = try Window.create(testing.allocator, &t.ui, .{});
    defer w.destroy();
    const a = &app.?;
    try testing.expectEqual(core.Size{ .width = @as(f32, @floatFromInt(a.screen.width)) / a.scale, .height = @as(f32, @floatFromInt(a.screen.height)) / a.scale }, t.ui.size());

    try step(0);
    try testing.expectEqual(@as(u32, 1), w.presented);
    const s = &a.screen;
    const pixel = struct {
        fn f(sc: *const fb.Screen, x: usize, y: usize) u32 {
            const page = sc.pageMemory(sc.shown);
            return std.mem.readVarInt(u32, page[y * sc.pitch + x * sc.format.bytes ..][0..sc.format.bytes], .little);
        }
    }.f;
    const at: usize = @intFromFloat(20 * a.scale);
    try testing.expectEqual(s.format.pack(.{ .r = 255, .g = 0, .b = 0, .a = 255 }), pixel(s, at, at));

    // A change: shown at the next step.
    t.button.background.set(.color(.rgb(0x0000ff)));
    try step(0);
    try testing.expectEqual(@as(u32, 2), w.presented);
    try testing.expectEqual(s.format.pack(.{ .r = 0, .g = 0, .b = 255, .a = 255 }), pixel(s, at, at));
}

test {
    _ = fb;
}
