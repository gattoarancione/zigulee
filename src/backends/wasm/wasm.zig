// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! WebAssembly backend: shows a `zigulee.Window` in a browser `<canvas>`,
//! with the JavaScript glue in zigulee.js. The app (built for
//! wasm32-freestanding) creates its UI in an exported `zigulee_main` and
//! calls `show`:
//!
//!     const wasm = @import("zigulee-wasm");
//!     pub const std_options = wasm.std_options;
//!     pub const panic = wasm.panic;
//!
//!     export fn zigulee_main() void {
//!         const app = ui.App.create(wasm.allocator) catch return;
//!         wasm.show(app.window());
//!     }
//!
//! The page drives everything through the exports below: it passes input
//! and the time, and asks for frames. With WebGL2 (the GPU renderer, whose
//! OpenGL calls the glue implements on the canvas's WebGL2 context) frames
//! are drawn directly; otherwise the software renderer draws them and the
//! page copies the pixels that changed to the canvas. Both at the display's
//! pixel density.

const std = @import("std");
const zigulee = @import("zigulee");
const core = zigulee.core;
const Rgba8 = core.Rgba8;

/// The app's allocator (the browser gives memory in pages).
pub const allocator = std.heap.wasm_allocator;

extern "env" fn zigulee_js_log(level: u32, ptr: [*]const u8, len: usize) void;
extern "env" fn zigulee_js_copy(ptr: [*]const u8, len: usize) void;
extern "env" fn zigulee_js_open_url(ptr: [*]const u8, len: usize) bool;
extern "env" fn zigulee_js_fetch(id: u32, ptr: [*]const u8, len: usize) void;
extern "env" fn zigulee_js_webview_create(view: u32) bool;
extern "env" fn zigulee_js_webview_destroy(view: u32) void;
extern "env" fn zigulee_js_webview_place(view: u32, x: f32, y: f32, w: f32, h: f32, visible: bool) void;
extern "env" fn zigulee_js_webview_load(view: u32, ptr: [*]const u8, len: usize, html: bool) void;
extern "env" fn zigulee_js_webview_command(view: u32, command: u32) void;
extern "env" fn zigulee_js_webview_run(view: u32, ptr: [*]const u8, len: usize) void;
extern "env" fn zigulee_js_sensor_available(kind: u32) bool;
extern "env" fn zigulee_js_sensor_start(kind: u32) void;
extern "env" fn zigulee_js_sensor_stop(kind: u32) void;
extern "env" fn zigulee_js_location_available() bool;
extern "env" fn zigulee_js_location_start() void;
extern "env" fn zigulee_js_location_stop() void;

/// Log messages go to the browser console.
pub const std_options: std.Options = .{ .logFn = logFn };

fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";
    const text = std.fmt.bufPrint(&buf, prefix ++ format, args) catch buf[0..];
    zigulee_js_log(@intFromEnum(level), text.ptr, text.len);
}

/// Panics are logged (as errors) before the module traps.
pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, _: ?usize) noreturn {
        zigulee_js_log(0, msg.ptr, msg.len);
        @trap();
    }
}.f);

const State = struct {
    ui: *core.Window,
    renderer: zigulee.software.Renderer(Rgba8),
    /// What the renderer draws into (premultiplied; kept between frames).
    framebuffer: []Rgba8 = &.{},
    /// What the canvas shows (straight alpha, as ImageData wants).
    present: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    full_redraw: bool = true,
    /// The area changed by the last frame, in pixels.
    dirty: [4]i32 = .{ 0, 0, 0, 0 },
    /// With WebGL2: the GPU renderer.
    gpu: ?*zigulee.gpu.gl.Renderer = null,
};

/// The OpenGL functions, imported from the page (module "zigulee_gl"),
/// which implements them with WebGL2.
fn webGlFunctions() zigulee.gpu.gl.Functions {
    var f: zigulee.gpu.gl.Functions = undefined;
    inline for (@typeInfo(zigulee.gpu.gl.Functions).@"struct".fields) |field| {
        @field(f, field.name) = @extern(field.type, .{ .name = field.name, .library_name = "zigulee_gl" });
    }
    return f;
}

var state: ?State = null;

/// Shows `ui` in the page's canvas. `ui` must stay alive.
pub fn show(ui: *core.Window) void {
    _ = &exports;
    if (state) |*s| s.renderer.deinit();
    state = .{ .ui = ui, .renderer = .init(allocator) };
    ui.clipboard = .{ .ctx = null, .getFn = getClipboard, .setFn = setClipboard };
    core.links.setOpener(.{ .open = openUrl });
    core.webview.setProvider(web_views);
    core.sensors.setProvider(sensors);
    core.location.setProvider(location);
    core.image_loader.fetcher = .{ .start = fetchStart };
}

// ---- Images from the network: the browser's fetch ----

/// Asks the page to fetch `r`'s URL, with its headers ("url\nheader..."):
/// it answers with `zigulee_wasm_fetched`.
fn fetchStart(r: *core.image_loader.Request) bool {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    text.appendSlice(allocator, r.url) catch return false;
    for (r.options.headers) |h| {
        text.append(allocator, '\n') catch return false;
        text.appendSlice(allocator, h) catch return false;
    }
    zigulee_js_fetch(@intCast(@intFromPtr(r)), text.items.ptr, text.items.len);
    return true;
}

// ---- Web views: an <iframe> over the canvas ----

const web_views: core.webview.Provider = .{ .vtable = &.{
    .create = webCreate,
    .destroy = webDestroy,
    .place = webPlace,
    .load_url = webLoadUrl,
    .load_html = webLoadHtml,
    .back = webBack,
    .forward = webForward,
    .reload = webReload,
    .stop = webStop,
    .run_javascript = webRun,
} };

var next_web_view: u32 = 1;

/// The page's number for a web view, as its handle.
fn webId(native: *core.webview.Provider.Native) u32 {
    return @intCast(@intFromPtr(native));
}
fn webNative(view: u32) *core.webview.Provider.Native {
    return @ptrFromInt(view);
}

fn webCreate(_: ?*anyopaque, _: ?*anyopaque, _: *core.webview.WebView) ?*core.webview.Provider.Native {
    const view = next_web_view;
    if (!zigulee_js_webview_create(view)) return null;
    next_web_view += 1;
    return webNative(view);
}
fn webDestroy(_: ?*anyopaque, native: *core.webview.Provider.Native) void {
    zigulee_js_webview_destroy(webId(native));
}
fn webPlace(_: ?*anyopaque, native: *core.webview.Provider.Native, r: core.Rect, visible: bool) void {
    zigulee_js_webview_place(webId(native), r.x, r.y, r.width, r.height, visible);
}
fn webLoadUrl(_: ?*anyopaque, native: *core.webview.Provider.Native, url: []const u8) void {
    core.webview.reportLoading(native, true);
    zigulee_js_webview_load(webId(native), url.ptr, url.len, false);
}
fn webLoadHtml(_: ?*anyopaque, native: *core.webview.Provider.Native, html: []const u8) void {
    core.webview.reportLoading(native, true);
    zigulee_js_webview_load(webId(native), html.ptr, html.len, true);
}
fn webBack(_: ?*anyopaque, native: *core.webview.Provider.Native) void {
    zigulee_js_webview_command(webId(native), 0);
}
fn webForward(_: ?*anyopaque, native: *core.webview.Provider.Native) void {
    zigulee_js_webview_command(webId(native), 1);
}
fn webReload(_: ?*anyopaque, native: *core.webview.Provider.Native) void {
    zigulee_js_webview_command(webId(native), 2);
}
fn webStop(_: ?*anyopaque, native: *core.webview.Provider.Native) void {
    zigulee_js_webview_command(webId(native), 3);
}
fn webRun(_: ?*anyopaque, native: *core.webview.Provider.Native, code: []const u8) void {
    zigulee_js_webview_run(webId(native), code.ptr, code.len);
}

/// Motion sensors: the page's devicemotion and deviceorientation events,
/// passed in by `zigulee_wasm_sensor`.
const sensors: core.sensors.Provider = .{ .ctx = null, .vtable = &.{
    .available = sensorAvailable,
    .start = sensorStart,
    .stop = sensorStop,
} };
var sensor_sink: ?*const core.sensors.Provider.Sink = null;

fn sensorAvailable(_: ?*anyopaque, kind: core.sensors.Kind) bool {
    return zigulee_js_sensor_available(@intFromEnum(kind));
}
fn sensorStart(_: ?*anyopaque, kind: core.sensors.Kind, sink: *const core.sensors.Provider.Sink) core.sensors.Provider.Error!void {
    sensor_sink = sink;
    zigulee_js_sensor_start(@intFromEnum(kind));
}
fn sensorStop(_: ?*anyopaque, kind: core.sensors.Kind) void {
    zigulee_js_sensor_stop(@intFromEnum(kind));
}

/// The position: the page's geolocation, passed in by
/// `zigulee_wasm_position` and `zigulee_wasm_position_error`.
const location: core.location.Provider = .{ .ctx = null, .vtable = &.{
    .available = locationAvailable,
    .start = locationStart,
    .stop = locationStop,
} };
var location_sink: ?*const core.location.Provider.Sink = null;

fn locationAvailable(_: ?*anyopaque) bool {
    return zigulee_js_location_available();
}
fn locationStart(_: ?*anyopaque, sink: *const core.location.Provider.Sink) core.location.Provider.Error!void {
    location_sink = sink;
    zigulee_js_location_start();
}
fn locationStop(_: ?*anyopaque) void {
    zigulee_js_location_stop();
}

/// `open-url`: a new tab (the browser may block it outside a click).
fn openUrl(_: ?*anyopaque, url: []const u8) bool {
    return zigulee_js_open_url(url.ptr, url.len);
}

fn getClipboard(_: ?*anyopaque, gpa: std.mem.Allocator) ?[]u8 {
    // The browser gives clipboard text only with a paste event (which the
    // glue sends as typed text): nothing to read here.
    _ = gpa;
    return null;
}

fn setClipboard(_: ?*anyopaque, text: []const u8) void {
    zigulee_js_copy(text.ptr, text.len);
}

fn modifiers(m: u32) core.input.Modifiers {
    return .{ .shift = m & 1 != 0, .control = m & 2 != 0, .alt = m & 4 != 0, .meta = m & 8 != 0 };
}

const exports = struct {
    comptime {
        @export(&resize, .{ .name = "zigulee_wasm_resize" });
        @export(&frame, .{ .name = "zigulee_wasm_frame" });
        @export(&nextWake, .{ .name = "zigulee_wasm_next_wake" });
        @export(&pixels, .{ .name = "zigulee_wasm_pixels" });
        @export(&pixelWidth, .{ .name = "zigulee_wasm_pixel_width" });
        @export(&pixelHeight, .{ .name = "zigulee_wasm_pixel_height" });
        @export(&dirty, .{ .name = "zigulee_wasm_dirty" });
        @export(&pointer, .{ .name = "zigulee_wasm_pointer" });
        @export(&drag, .{ .name = "zigulee_wasm_drag" });
        @export(&touch, .{ .name = "zigulee_wasm_touch" });
        @export(&dragLeave, .{ .name = "zigulee_wasm_drag_leave" });
        @export(&drop, .{ .name = "zigulee_wasm_drop" });
        @export(&key, .{ .name = "zigulee_wasm_key" });
        @export(&cursor, .{ .name = "zigulee_wasm_cursor" });
        @export(&preedit, .{ .name = "zigulee_wasm_preedit" });
        @export(&imeRect, .{ .name = "zigulee_wasm_ime_rect" });
        @export(&alloc, .{ .name = "zigulee_wasm_alloc" });
        @export(&free, .{ .name = "zigulee_wasm_free" });
        @export(&useGl, .{ .name = "zigulee_wasm_use_gl" });
        @export(&webLoaded, .{ .name = "zigulee_wasm_webview_loaded" });
        @export(&webResult, .{ .name = "zigulee_wasm_webview_result" });
        @export(&sensor, .{ .name = "zigulee_wasm_sensor" });
        @export(&position, .{ .name = "zigulee_wasm_position" });
        @export(&positionError, .{ .name = "zigulee_wasm_position_error" });
        @export(&fetched, .{ .name = "zigulee_wasm_fetched" });
        @export(&fetchProgress, .{ .name = "zigulee_wasm_fetch_progress" });
    }

    /// A fetch's body and HTTP status (0: no answer).
    fn fetched(id: u32, ptr: [*]const u8, len: usize, status: u32) callconv(.c) void {
        const r: *core.image_loader.Request = @ptrFromInt(id);
        r.fetched(ptr[0..len], @intCast(@min(status, 999)));
    }

    /// How much of a fetch's body came, and how much there is (0: not
    /// said).
    fn fetchProgress(id: u32, received: u32, total: u32) callconv(.c) void {
        const r: *core.image_loader.Request = @ptrFromInt(id);
        r.progress.received.store(received, .monotonic);
        r.progress.total.store(total, .monotonic);
    }

    /// A fix from geolocation (unknown values NaN; `timestamp` in ms since
    /// 1970).
    fn position(latitude: f64, longitude: f64, altitude: f64, accuracy: f64, speed: f64, heading: f64, timestamp: f64) callconv(.c) void {
        const s = location_sink orelse return;
        s.position(s.ctx, .{
            .latitude = latitude,
            .longitude = longitude,
            .altitude = altitude,
            .accuracy = accuracy,
            .speed = speed,
            .direction = heading,
            .timestamp = if (std.math.isFinite(timestamp)) @intFromFloat(timestamp) else 0,
        });
    }

    /// GeolocationPositionError's code: 1 denied, 2 unavailable, 3 timeout.
    fn positionError(code: u32) callconv(.c) void {
        const s = location_sink orelse return;
        s.failed(s.ctx, switch (code) {
            1 => .permission_denied,
            3 => .timeout,
            else => .unavailable,
        });
    }

    /// A sensor's reading (`kind`: a `core.sensors.Kind`).
    fn sensor(kind: u32, x: f32, y: f32, z: f32) callconv(.c) void {
        const s = sensor_sink orelse return;
        if (kind >= std.meta.fields(core.sensors.Kind).len) return;
        s.reading(s.ctx, @enumFromInt(kind), .{ x, y, z });
    }

    /// An iframe loaded (`failed`: it could not): its title and address,
    /// when the page is ours to read ("" otherwise), as "title\nurl".
    fn webLoaded(view: u32, ptr: [*]const u8, len: usize, failed: bool) callconv(.c) void {
        const n = webNative(view);
        const text = ptr[0..len];
        if (failed) return core.webview.reportFinished(n, text);
        const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        core.webview.reportTitle(n, text[0..nl]);
        if (nl + 1 < text.len) core.webview.reportUrl(n, text[nl + 1 ..]);
        core.webview.reportFinished(n, null);
    }

    /// JavaScript run in an iframe: its result, or its error.
    fn webResult(view: u32, ptr: [*]const u8, len: usize, failed: bool) callconv(.c) void {
        core.webview.reportJavaScript(webNative(view), ptr[0..len], failed);
    }

    /// The canvas's size in CSS pixels, and device pixels per CSS pixel.
    fn resize(width: f32, height: f32, scale: f32) callconv(.c) void {
        const s = if (state) |*s| s else return;
        s.ui.setSize(.{ .width = width, .height = height });
        s.renderer.scale_factor = if (scale > 0) scale else 1;
        const pw: u32 = @intFromFloat(@max(1, @round(width * s.renderer.scale_factor)));
        const ph: u32 = @intFromFloat(@max(1, @round(height * s.renderer.scale_factor)));
        // Resizing the canvas clears it.
        s.full_redraw = true;
        if (s.gpu != null) {
            s.width = pw;
            s.height = ph;
            return;
        }
        if (pw == s.width and ph == s.height) return;
        const n = @as(usize, pw) * ph;
        const fb = allocator.alloc(Rgba8, n) catch return;
        const present = allocator.alloc(u8, n * 4) catch {
            allocator.free(fb);
            return;
        };
        allocator.free(s.framebuffer);
        allocator.free(s.present);
        s.framebuffer = fb;
        s.present = present;
        s.width = pw;
        s.height = ph;
        s.full_redraw = true;
    }

    /// Advances to `now_ms`, runs timers and change handlers, and renders
    /// what changed. Returns whether pixels changed (see `dirty`).
    fn frame(now_ms: f64) callconv(.c) bool {
        const s = if (state) |*s| s else return false;
        core.updateTimersAndAnimations(@intFromFloat(@max(0, now_ms)));
        core.runChangeHandlers();
        if (s.width == 0) return false;
        const needs = s.full_redraw or s.ui.redraw_requested or core.hasActiveAnimations();
        if (!needs) return false;
        if (s.gpu) |gpu| {
            // Drawn on the canvas: what changed (the whole frame is shown).
            gpu.setScaleFactor(s.renderer.scale_factor);
            const region = gpu.renderWindow(s.ui, s.width, s.height, if (s.full_redraw) .full else .partial) catch return false;
            s.full_redraw = false;
            if (region.isEmpty()) return false;
            const b = region.boundingBox();
            s.dirty = .{ @intFromFloat(b.x), @intFromFloat(b.y), @intFromFloat(b.width), @intFromFloat(b.height) };
            return true;
        }
        const region = s.renderer.renderWindow(s.ui, .init(s.framebuffer, s.width, s.height), if (s.full_redraw) .full else .partial) catch return false;
        s.full_redraw = false;
        if (region.isEmpty()) return false;
        const b = region.boundingBox().intersection(.{ .width = @floatFromInt(s.width), .height = @floatFromInt(s.height) });
        const x0: u32 = @intFromFloat(@max(0, @floor(b.x)));
        const y0: u32 = @intFromFloat(@max(0, @floor(b.y)));
        const x1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(s.width)), @ceil(b.x + b.width)));
        const y1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(s.height)), @ceil(b.y + b.height)));
        if (x1 <= x0 or y1 <= y0) return false;
        // Straight alpha for the canvas.
        for (y0..y1) |y| for (x0..x1) |x| {
            const i = y * s.width + x;
            const c = s.framebuffer[i].unpremultiplied();
            s.present[i * 4 ..][0..4].* = .{ c.r, c.g, c.b, c.a };
        };
        s.dirty = .{ @intCast(x0), @intCast(y0), @intCast(x1 - x0), @intCast(y1 - y0) };
        return true;
    }

    /// Milliseconds until a frame is needed: 0 now (animations, or
    /// something changed), -1 never (until the next event).
    fn nextWake(now_ms: f64) callconv(.c) f64 {
        const s = if (state) |*s| s else return -1;
        if (s.full_redraw or s.ui.redraw_requested or core.hasActiveAnimations()) return 0;
        const deadline = core.nextTimerDeadline() orelse return -1;
        return @max(0, @as(f64, @floatFromInt(deadline)) - now_ms);
    }

    fn pixels() callconv(.c) [*]u8 {
        const s = if (state) |*s| s else return undefined;
        return s.present.ptr;
    }

    fn pixelWidth() callconv(.c) u32 {
        return if (state) |s| s.width else 0;
    }

    fn pixelHeight() callconv(.c) u32 {
        return if (state) |s| s.height else 0;
    }

    /// x, y, width, height of the last frame's changes, in pixels.
    fn dirty() callconv(.c) [*]const i32 {
        const s = if (state) |*s| s else return undefined;
        return &s.dirty;
    }

    /// kind: 0 pressed, 1 released, 2 moved, 3 wheel, 4 left the canvas.
    /// A finger (0 down, 1 moved, 2 up, 3 cancelled).
    fn touch(id: u32, phase: u32, x: f32, y: f32) callconv(.c) void {
        const s = if (state) |*s| s else return;
        core.gestures.dispatchTouch(s.ui, id, switch (phase) {
            0 => .down,
            1 => .moved,
            2 => .up,
            else => .cancelled,
        }, .{ .x = x, .y = y });
    }

    /// A drag from the page or the desktop over the canvas: of files (1)
    /// and/or text (2). Whether a DropArea there takes it.
    fn drag(kinds: u32, x: f32, y: f32) callconv(.c) u32 {
        const s = if (state) |*s| s else return 0;
        var list: [2][]const u8 = undefined;
        var n: usize = 0;
        if (kinds & 1 != 0) {
            list[n] = core.dnd.file_kind;
            n += 1;
        }
        if (kinds & 2 != 0) {
            list[n] = core.dnd.text_kind;
            n += 1;
        }
        return @intFromBool(core.dnd.externalMoved(s.ui, list[0..n], .{ .x = x, .y = y }));
    }

    fn dragLeave() callconv(.c) void {
        const s = if (state) |*s| s else return;
        core.dnd.externalLeft(s.ui);
    }

    /// Dropped: files (0: their names, one per line; a page sees no
    /// paths) or text (1).
    fn drop(kind: u32, ptr: [*]const u8, len: usize, x: f32, y: f32) callconv(.c) u32 {
        const s = if (state) |*s| s else return 0;
        const k = if (kind == 0) core.dnd.file_kind else core.dnd.text_kind;
        return @intFromBool(core.dnd.externalDropped(s.ui, k, ptr[0..len], .{ .x = x, .y = y }));
    }

    fn pointer(kind: u32, x: f32, y: f32, button: u32, mods: u32, dx: f32, dy: f32) callconv(.c) void {
        const s = if (state) |*s| s else return;
        const p: core.Point = .{ .x = x, .y = y };
        const b: core.input.PointerButton = switch (button) {
            0 => .left,
            1 => .middle,
            2 => .right,
            else => .other,
        };
        s.ui.dispatchPointer(switch (kind) {
            0 => .{ .pressed = .{ .position = p, .button = b, .modifiers = modifiers(mods) } },
            1 => .{ .released = .{ .position = p, .button = b } },
            2 => .{ .moved = .{ .position = p } },
            3 => .{ .wheel = .{ .position = p, .delta = .{ .x = dx, .y = dy } } },
            else => .exit,
        });
        core.runChangeHandlers();
    }

    /// A key (`text`: what it types, or a `Key` code) pressed or released.
    fn key(pressed: bool, text: [*]const u8, len: usize, mods: u32, repeat: bool) callconv(.c) void {
        const s = if (state) |*s| s else return;
        s.ui.dispatchKey(if (pressed) .pressed else .released, .{ .text = text[0..len], .modifiers = modifiers(mods), .repeat = repeat });
        core.runChangeHandlers();
    }

    /// Text being composed by an input method (empty: none), with the
    /// caret `cursor` bytes into it.
    fn preedit(text: [*]const u8, len: usize, cursor_bytes: usize) callconv(.c) void {
        const s = if (state) |*s| s else return;
        s.ui.dispatchPreedit(text[0..len], @min(cursor_bytes, len));
        core.runChangeHandlers();
    }

    var ime_rect: [4]f32 = .{ 0, 0, 0, 0 };

    /// Where the text caret is (CSS pixels: x, y, width, height), for the
    /// input method's window; null without a focused text field.
    fn imeRect() callconv(.c) ?[*]const f32 {
        const s = if (state) |*s| s else return null;
        const r = s.ui.ime_cursor_rect orelse return null;
        ime_rect = .{ r.x, r.y, r.width, r.height };
        return &ime_rect;
    }

    /// The cursor the window asks for (`core.input.MouseCursor`).
    fn cursor() callconv(.c) u32 {
        const s = if (state) |*s| s else return 0;
        return @intFromEnum(s.ui.mouseCursor());
    }

    /// Draws with WebGL2 from now on (the page has made the canvas's WebGL2
    /// context and implements the "zigulee_gl" imports with it). False if
    /// the shaders do not compile: the page falls back to software.
    fn useGl() callconv(.c) bool {
        const s = if (state) |*s| s else return false;
        if (s.gpu != null) return true;
        const gpu = allocator.create(zigulee.gpu.gl.Renderer) catch return false;
        gpu.* = zigulee.gpu.gl.Renderer.init(allocator, webGlFunctions()) catch {
            allocator.destroy(gpu);
            return false;
        };
        s.gpu = gpu;
        // Its frames are the canvas's own: no framebuffer to copy.
        allocator.free(s.framebuffer);
        allocator.free(s.present);
        s.framebuffer = &.{};
        s.present = &.{};
        s.full_redraw = true;
        return true;
    }

    /// Memory for the page to write strings into.
    fn alloc(len: usize) callconv(.c) ?[*]u8 {
        const m = allocator.alloc(u8, @max(len, 1)) catch return null;
        return m.ptr;
    }

    fn free(ptr: [*]u8, len: usize) callconv(.c) void {
        allocator.free(ptr[0..@max(len, 1)]);
    }
};
