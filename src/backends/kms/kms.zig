// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The KMS backend (`zigulee-kms`): a `zigulee.Window` full screen on a
//! display, with no desktop: embedded Linux, kiosks, a console. The display
//! is driven with kernel mode setting (drm.zig: no libdrm), input read
//! from the kernel's event devices (evdev.zig: keyboards, mice,
//! touchscreens). Same interface as the other backends:
//!
//!     try kms.init();
//!     defer kms.deinit();
//!     const window = try kms.Window.create(gpa, &ui_window, .{});
//!     defer window.destroy();
//!     try window.run();
//!
//! The window takes the display's preferred mode, divided by the scale
//! (`ZIGULEE_SCALE`, default 1): its size is the display's, whatever
//! `ui.size()` was. A display mounted turned is set with `ZIGULEE_ROTATION`
//! (or `Options.rotation`): 90, 180 or 270 degrees clockwise; the window
//! is drawn upright and turned as it is copied, input turned back. A touch
//! panel covering only part of the display: `ZIGULEE_TOUCH_AREA`
//! (`Options.touch_area`, `WxH+X+Y` in display pixels). It draws with the software renderer into two buffers
//! (each brought up to date with what changed since it was last shown),
//! flipped at the display's refresh. The device is `ZIGULEE_DRM_DEVICE`, else
//! the first card with a connected display. Keys go through libxkbcommon
//! when there is one (layout from `XKB_DEFAULT_LAYOUT`...), else a US
//! layout; the kernel repeats them. Mice show a hardware cursor;
//! touchscreens act as a pointer. Ctrl+Alt+Backspace closes the window
//! (the keyboard is grabbed: the console does not see it). The run needs
//! access to /dev/dri and /dev/input (the video and input groups), and no
//! other program showing on the display (no desktop session on it).
//!
//! Without a DRM device with a connected display, the window goes on the
//! framebuffer device instead, if there is one (the fbdev backend's
//! screen: /dev/fb0, or `ZIGULEE_FB_DEVICE`; a cursor drawn in software,
//! the text console in graphics mode meanwhile).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const Rgba8 = core.Rgba8;
const input = core.input;
pub const drm = @import("drm.zig");
pub const evdev = @import("zigulee-evdev");
pub const Input = evdev.Input;
const fbdev = @import("zigulee-fbdev");
const fb = fbdev.fb;
const xkb = @import("zigulee-xkb");
const c = std.c;

const log = std.log.scoped(.zigulee_kms);

pub const Error = drm.Error || error{AlreadyOpen};

pub const RendererKind = enum {
    /// The software renderer (the only one, for now).
    auto,
    software,
};

/// Like the other backends' (the title and size do not apply: the window
/// is the display).
pub const Options = struct {
    title: [:0]const u8 = "zigulee",
    resizable: bool = true,
    renderer: RendererKind = .auto,
    hidden: bool = false,
    /// How the display shows the window, turned clockwise (null:
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

// ---- The display ----

const App = struct {
    /// The DRM device (-1 on the framebuffer device).
    fd: c.fd_t = -1,
    output: drm.Output = undefined,
    /// What the display showed before (restored at the end).
    saved: drm.Crtc = .{},
    /// Without a DRM display: the framebuffer device's screen.
    screen: ?fb.Screen = null,
    console: fb.Console = .{},
    devices: [16]evdev.Device = undefined,
    device_count: usize = 0,
    scale: f32 = 1,
    cursor: drm.Buffer = .{},
    cursor_shown: bool = false,
};

var app: ?App = null;
var window: ?*Window = null;

/// Sound: the mixer plays through PipeWire (from `init` to `deinit`).
var audio_output: @import("zigulee-pipewire").Output = .{};

/// Opens the display and the input devices. Called by `Window.create` if
/// needed.
pub fn init() Error!void {
    if (app != null) return;
    _ = now();
    var a: App = .{ .scale = fbdev.envScale() };
    if (drm.open()) |opened| {
        a.fd, a.output = opened;
        _ = drm.call(a.fd, drm.ioc.set_master, @constCast(&@as(u32, 0)));
        a.saved = .{ .crtc_id = a.output.crtc };
        _ = drm.call(a.fd, drm.ioc.get_crtc, &a.saved);
        log.info("display {d}x{d}@{d}", .{ a.output.mode.hdisplay, a.output.mode.vdisplay, a.output.mode.vrefresh });
    } else |err| {
        // No DRM display: the framebuffer device, if there is one.
        a.screen = fb.Screen.open() catch return err;
        a.console = .graphics();
        log.info("no DRM display ({t}): the framebuffer device, {d}x{d}", .{ err, a.screen.?.width, a.screen.?.height });
    }
    core.audio.mixer().setOutput(audio_output.output());
    core.video.addDecoder(@import("zigulee-gstreamer").decoder);
    a.device_count = evdev.openAll(&a.devices);
    app = a;
    log.info("{d} input devices", .{a.device_count});
}

/// Whether the window is on the framebuffer device (no DRM display).
pub fn onFramebuffer() bool {
    return if (app) |a| a.screen != null else false;
}

/// Gives the display back and closes the devices (once the window is
/// destroyed).
pub fn deinit() void {
    if (window != null) return;
    const a = &(app orelse return);
    core.audio.mixer().setOutput(null);
    core.video.removeDecoder("gstreamer");
    for (a.devices[0..a.device_count]) |d| evdev.close(d);
    if (a.screen) |*screen| {
        screen.close();
        a.console.restore();
    } else {
        a.cursor.destroy(a.fd);
        _ = drm.call(a.fd, drm.ioc.drop_master, @constCast(&@as(u32, 0)));
        _ = c.close(a.fd);
    }
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
    buffers: [2]drm.Buffer = .{ .{}, .{} },
    /// What changed in each buffer since it was last brought up to date
    /// (a few rectangles, each copied on its own).
    stale: [2]core.Region = .{ .{}, .{} },
    /// The buffer being shown.
    front: ?usize = null,
    flip_pending: bool = false,
    full_redraw: bool = true,
    unshown: bool = false,
    closed: bool = false,
    last_frame: u64 = 0,
    presented: u32 = 0,
    cursor: input.MouseCursor = .default,
    rotation: Rotation = .none,

    /// Shows `ui` full screen (one window at a time). `ui` must outlive the
    /// window.
    pub fn create(gpa: Allocator, ui: *core.Window, options: Options) Error!*Window {
        if (window != null) return error.AlreadyOpen;
        try init();
        const a = &app.?;
        const rotation = options.rotation orelse Rotation.fromEnv();
        // The display's pixels, and the window's: the same, turned.
        const sw: u32 = if (a.screen) |screen| screen.width else a.output.mode.hdisplay;
        const sh: u32 = if (a.screen) |screen| screen.height else a.output.mode.vdisplay;
        if (a.screen) |*screen| {
            screen.rotation = rotation;
            screen.invalidate(.{ .width = @floatFromInt(sw), .height = @floatFromInt(sh) });
        }
        const w, const h = rotation.turnedSize(sw, sh);
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        const lw = @as(f32, @floatFromInt(w)) / a.scale;
        const lh = @as(f32, @floatFromInt(h)) / a.scale;
        self.* = .{ .gpa = gpa, .ui = ui, .input = .{ .ui = ui, .scale = a.scale, .width = lw, .height = lh, .rotation = rotation, .touch_area = options.touch_area orelse evdev.touchAreaFromEnv() }, .pixel_width = w, .pixel_height = h, .software = .init(gpa), .rotation = rotation };
        errdefer self.software.deinit();
        self.software.scale_factor = a.scale;
        self.framebuffer = try gpa.alloc(Rgba8, @as(usize, w) * h);
        errdefer gpa.free(self.framebuffer);
        @memset(self.framebuffer, .transparent);
        errdefer for (&self.buffers) |*b| b.destroy(a.fd);
        if (a.screen == null) for (&self.buffers) |*b| {
            b.* = try drm.Buffer.create(a.fd, sw, sh);
        };
        ui.setSize(.{ .width = lw, .height = lh });
        self.input.position = .{ .x = lw / 2, .y = lh / 2 };
        // The keyboard: libxkbcommon with the default layout, if there is
        // one.
        if (xkb.Keyboard.init()) |k| {
            var kb = k;
            if (kb.setKeymapNames(.{})) self.input.keyboard = kb else kb.deinit();
        }
        window = self;
        self.updateCursor(true);
        return self;
    }

    pub fn destroy(self: *Window) void {
        window = null;
        if (app) |*a| if (a.screen) |*screen| {
            screen.setCursor(null, 1);
        } else {
            // What the display showed before.
            if (a.saved.fb_id != 0) {
                var connector = a.output.connector;
                var crtc = a.saved;
                crtc.set_connectors_ptr = @intFromPtr(&connector);
                crtc.count_connectors = 1;
                _ = drm.call(a.fd, drm.ioc.set_crtc, &crtc);
            }
            var off: drm.Cursor = .{ .flags = 1, .crtc_id = a.output.crtc };
            _ = drm.call(a.fd, drm.ioc.cursor, &off);
            a.cursor_shown = false;
            for (&self.buffers) |*b| b.destroy(a.fd);
        };
        if (self.input.keyboard) |*k| k.deinit();
        self.software.deinit();
        self.gpa.free(self.framebuffer);
        self.gpa.destroy(self);
    }

    /// Shows another zigulee window (live reloading), sized to the display.
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
        return self.full_redraw or self.unshown or self.ui.redraw_requested or core.hasActiveAnimations();
    }

    /// Draws what changed and shows it (flipping to a buffer brought up to
    /// date; on the framebuffer device, panning or in place).
    pub fn render(self: *Window) Error!void {
        const a = &app.?;
        var changed: core.Region = .{};
        // Animations: on the framebuffer device, no flips to wait for,
        // every 16 ms at most.
        if (self.full_redraw or self.ui.redraw_requested or (core.hasActiveAnimations() and (a.screen == null or now() >= self.last_frame + 16))) {
            self.last_frame = now();
            const full = self.full_redraw;
            const canvas: zigulee.software.Canvas(Rgba8) = .init(self.framebuffer, self.pixel_width, self.pixel_height);
            const region = try self.software.renderWindow(self.ui, canvas, if (full) .full else .partial);
            self.full_redraw = false;
            changed = region;
            if (full) changed.add(.{ .width = @floatFromInt(self.pixel_width), .height = @floatFromInt(self.pixel_height) });
        }
        if (a.screen) |*screen| {
            self.updateCursor(false);
            if (screen.present(self.framebuffer, changed.slice())) self.presented += 1;
            return;
        }
        // In the display's pixels.
        for (changed.slice()) |r| {
            const on_screen = turnedRect(self.rotation, r, self.pixel_width, self.pixel_height);
            for (&self.stale) |*s| s.add(on_screen);
        }
        if (changed.isEmpty() and !self.unshown) return;
        // The buffer not on screen.
        const back: usize = if (self.front) |f| 1 - f else 0;
        const b = &self.buffers[back];
        for (self.stale[back].slice()) |r| copy(self.framebuffer, self.rotation, b, r);
        self.stale[back].clear();
        if (self.front == null) {
            // The first frame: set the mode.
            var connector = a.output.connector;
            var crtc: drm.Crtc = .{ .crtc_id = a.output.crtc, .fb_id = b.fb, .set_connectors_ptr = @intFromPtr(&connector), .count_connectors = 1, .mode_valid = 1, .mode = a.output.mode };
            if (!drm.call(a.fd, drm.ioc.set_crtc, &crtc)) return error.ModeSetFailed;
        } else {
            var flip: drm.PageFlip = .{ .crtc_id = a.output.crtc, .fb_id = b.fb, .flags = drm.page_flip_event };
            if (!drm.call(a.fd, drm.ioc.page_flip, &flip)) {
                // Busy: again once the last flip is done.
                self.unshown = true;
                self.stale[back].add(.{ .width = @floatFromInt(b.width), .height = @floatFromInt(b.height) });
                return;
            }
            self.flip_pending = true;
        }
        self.front = back;
        self.unshown = false;
        self.presented += 1;
    }

    /// The hardware cursor: shown while there is a mouse, at the pointer
    /// (on the framebuffer device, drawn by `render`).
    fn updateCursor(self: *Window, force: bool) void {
        const a = &app.?;
        if (a.screen) |*screen| return fbdev.updateCursor(screen, self.ui, &self.input, a.devices[0..a.device_count], a.scale);
        const has_mouse = for (a.devices[0..a.device_count]) |d| {
            if (d.kind == .mouse) break true;
        } else false;
        const want = self.ui.mouseCursor();
        if (has_mouse and (force or want != self.cursor)) {
            self.cursor = want;
            if (want == .none) {
                var off: drm.Cursor = .{ .flags = 1, .crtc_id = a.output.crtc };
                _ = drm.call(a.fd, drm.ioc.cursor, &off);
                a.cursor_shown = false;
            } else if (!a.cursor_shown) {
                if (a.cursor.handle == 0) {
                    a.cursor = drm.Buffer.create(a.fd, 64, 64) catch return;
                    drawArrow(&a.cursor, @intFromFloat(@min(3, @max(1, a.scale))), self.rotation);
                }
                var set: drm.Cursor = .{ .flags = 1, .crtc_id = a.output.crtc, .width = 64, .height = 64, .handle = a.cursor.handle };
                a.cursor_shown = drm.call(a.fd, drm.ioc.cursor, &set);
            }
        }
        if (a.cursor_shown and (force or self.input.cursor_moved)) {
            self.input.cursor_moved = false;
            // The arrow's tip on the display, less where it is in the image.
            const tip = self.rotation.toScreen(.{ .x = self.input.position.x * a.scale, .y = self.input.position.y * a.scale }, @floatFromInt(self.pixel_width), @floatFromInt(self.pixel_height));
            const in_image = arrowTip(self.rotation);
            var move: drm.Cursor = .{ .flags = 2, .crtc_id = a.output.crtc, .x = @as(i32, @intFromFloat(tip.x)) - in_image[0], .y = @as(i32, @intFromFloat(tip.y)) - in_image[1] };
            _ = drm.call(a.fd, drm.ioc.cursor, &move);
        }
    }

    fn afterEvents(self: *Window) Error!void {
        if (self.input.quit) self.closed = true;
        if (app.?.screen != null) return self.render();
        if (self.needsFrame() and !self.flip_pending) try self.render();
        self.updateCursor(false);
    }
};

const step_ = step;

/// The display's pixels a rectangle of the window's covers.
fn turnedRect(rotation: Rotation, r: core.Rect, w: u32, h: u32) core.Rect {
    if (rotation == .none or r.isEmpty()) return r;
    const x0 = @floor(r.x);
    const y0 = @floor(r.y);
    const whole: core.Rect = .{ .x = x0, .y = y0, .width = @ceil(r.x + r.width) - x0, .height = @ceil(r.y + r.height) - y0 };
    return rotation.rectToScreen(whole, @floatFromInt(w), @floatFromInt(h));
}

/// Copies a rectangle of the display (`r`) from the framebuffer, turned
/// as `rotation` says, into a buffer (as XRGB8888).
fn copy(framebuffer: []const Rgba8, rotation: Rotation, b: *drm.Buffer, r: core.Rect) void {
    if (r.isEmpty()) return;
    const x0: u32 = @intFromFloat(std.math.clamp(@floor(r.x), 0, @as(f32, @floatFromInt(b.width))));
    const y0: u32 = @intFromFloat(std.math.clamp(@floor(r.y), 0, @as(f32, @floatFromInt(b.height))));
    const x1: u32 = @intFromFloat(std.math.clamp(@ceil(r.x + r.width), 0, @as(f32, @floatFromInt(b.width))));
    const y1: u32 = @intFromFloat(std.math.clamp(@ceil(r.y + r.height), 0, @as(f32, @floatFromInt(b.height))));
    const pixels = b.pixels();
    for (y0..y1) |y| {
        const from = rotation.row(y, b.width, b.height);
        // Upright or turned 180°, several pixels at once.
        const done = fb.convertRow(.xrgb, std.mem.sliceAsBytes(pixels[y * b.stride ..][0..b.width]), framebuffer, from, x0, x1, 0xff000000);
        const dst = pixels[y * b.stride ..][done..x1];
        for (dst, done..) |*q, x| {
            const p = framebuffer[@intCast(from.base + @as(isize, @intCast(x)) * from.step)];
            q.* = 0xff000000 | @as(u32, p.r) << 16 | @as(u32, p.g) << 8 | p.b;
        }
    }
}

/// Where the arrow's tip is in the 64x64 cursor image: turned, the arrow
/// goes from another corner.
fn arrowTip(rotation: Rotation) [2]i32 {
    return switch (rotation) {
        .none => .{ 0, 0 },
        .quarter => .{ 63, 0 },
        .half => .{ 63, 63 },
        .three_quarters => .{ 0, 63 },
    };
}

/// The arrow (fb.arrow), `s` pixels per dot, turned with the window.
fn drawArrow(b: *drm.Buffer, s: u32, rotation: Rotation) void {
    const arrow = fb.arrow;
    const pixels = b.pixels();
    @memset(pixels, 0);
    const tip = arrowTip(rotation);
    for (arrow, 0..) |row, y| for (row, 0..) |dot, x| {
        const color: u32 = switch (dot) {
            'X' => 0xff000000,
            '.' => 0xffffffff,
            else => continue,
        };
        for (0..s) |dy| for (0..s) |dx| {
            const o = rotation.vectorToScreen(.{ .x = @floatFromInt(x * s + dx), .y = @floatFromInt(y * s + dy) });
            const px = tip[0] + @as(i32, @intFromFloat(o.x));
            const py = tip[1] + @as(i32, @intFromFloat(o.y));
            if (px >= 0 and px < 64 and py >= 0 and py < 64) pixels[@as(usize, @intCast(py)) * b.stride + @as(usize, @intCast(px))] = color;
        };
    };
}

/// One event loop iteration: waits for input or a page flip (at most
/// `max_wait_ms`, or until the next timer or frame), handles them, fires
/// timers, runs change handlers and draws what changed.
pub fn step(max_wait_ms: ?u32) Error!void {
    const a = &(app orelse return);
    const w = window orelse return;
    core.updateTimersAndAnimations(now());
    var timeout: ?u64 = null;
    if (w.needsFrame() and !w.flip_pending) {
        const next = if (core.hasActiveAnimations() and !w.full_redraw and !w.ui.redraw_requested) w.last_frame + 16 else 0;
        timeout = next -| now();
    }
    if (core.nextTimerDeadline()) |deadline| timeout = @min(timeout orelse std.math.maxInt(u64), deadline -| now());
    if (max_wait_ms) |m| timeout = if (timeout) |t| @min(t, m) else m;

    var fds: [17]c.pollfd = undefined;
    fds[0] = .{ .fd = a.fd, .events = c.POLL.IN, .revents = 0 };
    for (a.devices[0..a.device_count], 1..) |d, i| fds[i] = .{ .fd = d.fd, .events = c.POLL.IN, .revents = 0 };
    const ms: c_int = if (timeout) |t| @intCast(@min(t, std.math.maxInt(i32))) else -1;
    if (c.poll(&fds, @intCast(1 + a.device_count), ms) > 0) {
        if (fds[0].revents != 0 and drm.readEvents(a.fd)) w.flip_pending = false;
        for (a.devices[0..a.device_count], 1..) |d, i| if (fds[i].revents != 0) {
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
const TestUi = evdev.TestUi;

test "a display: the first frame sets the mode, the next ones flip" {
    init() catch |err| {
        log.info("no display ({t}): skipped", .{err});
        return error.SkipZigTest;
    };
    defer deinit();
    // The framebuffer device instead: tested by zigulee-fbdev.
    if (onFramebuffer()) return error.SkipZigTest;
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    const w = try Window.create(testing.allocator, &t.ui, .{});
    defer w.destroy();
    const a = &app.?;
    try testing.expectEqual(core.Size{ .width = @as(f32, @floatFromInt(a.output.mode.hdisplay)) / a.scale, .height = @as(f32, @floatFromInt(a.output.mode.vdisplay)) / a.scale }, t.ui.size());

    try step(0);
    try testing.expectEqual(@as(u32, 1), w.presented);
    // The display shows our buffer.
    var crtc: drm.Crtc = .{ .crtc_id = a.output.crtc };
    try testing.expect(drm.call(a.fd, drm.ioc.get_crtc, &crtc));
    try testing.expectEqual(w.buffers[w.front.?].fb, crtc.fb_id);
    const shown = w.buffers[w.front.?].pixels();
    const stride = w.buffers[w.front.?].stride;
    const at = @as(usize, @intFromFloat(20 * a.scale)) * stride + @as(usize, @intFromFloat(20 * a.scale));
    try testing.expectEqual(@as(u32, 0xffff0000), shown[at]);

    // A change: drawn into the other buffer, flipped to at the next vblank.
    t.button.background.set(.color(.rgb(0x0000ff)));
    const until = now() + 2000;
    while (w.presented < 2 or w.flip_pending) {
        if (now() > until) return error.Timeout;
        try step(50);
    }
    try testing.expectEqual(@as(u32, 0xff0000ff), w.buffers[w.front.?].pixels()[at]);
    try testing.expect(drm.call(a.fd, drm.ioc.get_crtc, &crtc));
    try testing.expectEqual(w.buffers[w.front.?].fb, crtc.fb_id);
}

test {
    _ = drm;
}

test "the picture copied into a display's buffer: every pixel, upright and turned" {
    const w = 37;
    const h = 5;
    var prng: std.Random.DefaultPrng = .init(9);
    const r = prng.random();
    var picture: [w * h]Rgba8 = undefined;
    for (&picture) |*p| p.* = .{ .r = r.int(u8), .g = r.int(u8), .b = r.int(u8), .a = r.int(u8) };
    for ([_]Rotation{ .none, .half, .quarter, .three_quarters }) |rotation| {
        const bw, const bh = rotation.turnedSize(w, h);
        const stride = bw + 3;
        const memory = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), stride * bh * 4);
        defer std.testing.allocator.free(memory);
        @memset(memory, 0);
        var b: drm.Buffer = .{ .width = bw, .height = bh, .stride = stride, .memory = memory };
        copy(&picture, rotation, &b, .{ .width = @floatFromInt(bw), .height = @floatFromInt(bh) });
        for (0..bh) |y| {
            const from = rotation.row(y, bw, bh);
            for (0..bw) |x| {
                const p = picture[@intCast(from.base + @as(isize, @intCast(x)) * from.step)];
                try std.testing.expectEqual(0xff000000 | @as(u32, p.r) << 16 | @as(u32, p.g) << 8 | p.b, b.pixels()[y * stride + x]);
            }
            // The padding is left alone.
            try std.testing.expectEqual(@as(u32, 0), b.pixels()[y * stride + bw]);
        }
    }
}
