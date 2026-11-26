// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The native macOS backend: shows a `zigulee.Window` in an AppKit window,
//! with no other dependency than the system's frameworks (talked to
//! through the Objective-C runtime, objc.zig). Same interface as the SDL3
//! backend:
//!
//!     try macos.init();
//!     defer macos.deinit();
//!     const window = try macos.Window.create(gpa, &ui_window, .{ .title = "Hello" });
//!     defer window.destroy();
//!     try window.run();
//!
//! Windows draw with OpenGL (the GPU renderer) or with the software
//! renderer, whose frames become the contents of the view's layer.
//! Keyboard input goes through the system's text input (NSTextInputClient):
//! input methods, dead keys and the character palette work. VoiceOver sees
//! the accessible items (accessibility.zig). The application menu has Quit
//! (Cmd+Q), which closes every window.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const dnd = core.dnd;
const gestures = core.gestures;
const Rgba8 = core.Rgba8;
const input = core.input;
const Key = input.Key;
const objc = @import("zigulee-apple").objc;
const id = objc.id;
const SEL = objc.SEL;
const BOOL = objc.BOOL;
const NSPoint = objc.NSPoint;
const NSSize = objc.NSSize;
const NSRect = objc.NSRect;
const NSRange = objc.NSRange;
const msg = objc.msg;
const class = objc.class;
const nsString = objc.nsString;
const Bridge = @import("accessibility.zig").Bridge;
const metal = @import("zigulee-apple").metal;

const log = std.log.scoped(.zigulee_macos);

pub const Error = error{ CocoaFailed, OpenGlFailed, MetalFailed } || Allocator.Error;

// ---- Frameworks ----

extern "c" const NSDefaultRunLoopMode: id;
extern "c" const NSPasteboardTypeString: id;
extern "c" const NSAppearanceNameAqua: id;
extern "c" const NSAppearanceNameDarkAqua: id;
extern "c" const kCGColorSpaceSRGB: ?*anyopaque;
extern "c" fn CGColorSpaceCreateWithName(name: ?*anyopaque) ?*anyopaque;
extern "c" fn CGColorSpaceRelease(space: ?*anyopaque) void;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits: usize, bytes_per_row: usize, space: ?*anyopaque, info: u32) ?*anyopaque;
extern "c" fn CGBitmapContextCreateImage(context: ?*anyopaque) ?*anyopaque;
extern "c" fn CGContextRelease(context: ?*anyopaque) void;
extern "c" fn CGImageRelease(image: ?*anyopaque) void;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;

/// Premultiplied RGBA, in memory order (kCGImageAlphaPremultipliedLast |
/// kCGBitmapByteOrder32Big).
const bitmap_info: u32 = 1 | (4 << 12);

pub const RendererKind = enum {
    /// Metal, else OpenGL, else software.
    auto,
    /// The GPU renderer on Metal: the window fails to open without it.
    metal,
    /// The GPU renderer (OpenGL 4.1 core): the window fails to open
    /// without it.
    opengl,
    /// The software renderer: only what changed is redrawn.
    software,
};

pub const Options = struct {
    title: [:0]const u8 = "zigulee",
    resizable: bool = true,
    renderer: RendererKind = .auto,
    /// Not shown (for tests, or shown later with `Window.show`).
    hidden: bool = false,
};

extern "c" fn clock_gettime_nsec_np(clock: u32) u64;
const clock_monotonic = 6;
var start_ns: u64 = 0;

/// Milliseconds since `init` (a monotonic clock): the clock zigulee's timers
/// and animations run on.
pub fn now() u64 {
    if (start_ns == 0) start_ns = clock_gettime_nsec_np(clock_monotonic);
    return (clock_gettime_nsec_np(clock_monotonic) - start_ns) / std.time.ns_per_ms;
}

// ---- The application ----

var app: id = null;
var open_windows: ?*Window = null;

/// Sound: the mixer plays through CoreAudio (from `init` to `deinit`).
var audio_output: @import("zigulee-apple").coreaudio.Output = .{};

/// Sets up the application (the menu bar, a Dock icon) and makes CoreAudio
/// the mixer's audio output (the device starts when something plays). Call
/// once, before creating windows.
pub fn init() Error!void {
    _ = now();
    core.audio.mixer().setOutput(audio_output.output());
    core.video.addDecoder(@import("zigulee-apple").avfoundation.decoder);
    core.dialogs.setFileDialogs(@import("filedialog.zig").provider);
    core.menus.setMenuBar(@import("menubar.zig").provider);
    core.tray.setProvider(@import("tray.zig").provider);
    core.audio.setInput(@import("capture.zig").microphone);
    core.camera.setProvider(@import("capture.zig").camera_provider);
    core.location.setProvider(@import("zigulee-apple").location.provider);
    core.links.setOpener(.{ .open = openUrl });
    core.webview.setProvider(@import("zigulee-apple").webview.provider);
    app = msg(id, class("NSApplication"), "sharedApplication", .{});
    if (app == null) return error.CocoaFailed;
    _ = msg(BOOL, app, "setActivationPolicy:", .{@as(isize, 0)}); // regular
    msg(void, app, "setDelegate:", .{msg(id, msg(id, appDelegateClass(), "alloc", .{}), "init", .{})});
    // A menu bar with the application menu, and Quit in it.
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    const bar = msg(id, msg(id, class("NSMenu"), "alloc", .{}), "init", .{});
    const app_item = msg(id, msg(id, class("NSMenuItem"), "alloc", .{}), "init", .{});
    msg(void, bar, "addItem:", .{app_item});
    const app_menu = msg(id, msg(id, class("NSMenu"), "alloc", .{}), "init", .{});
    const quit = msg(id, msg(id, class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{ nsString("Quit"), objc.sel("terminate:"), nsString("q") });
    msg(void, app_menu, "addItem:", .{quit});
    msg(void, app_item, "setSubmenu:", .{app_menu});
    msg(void, app, "setMainMenu:", .{bar});
    msg(void, app, "finishLaunching", .{});
}

pub fn deinit() void {
    core.audio.mixer().setOutput(null);
    core.video.removeDecoder("avfoundation");
    core.dialogs.setFileDialogs(null);
    core.menus.setMenuBar(null);
    core.tray.setProvider(null);
    core.audio.setInput(null);
    core.camera.setProvider(null);
    core.location.setProvider(null);
    core.links.setOpener(null);
    core.webview.setProvider(null);
}

/// `open-url`: NSWorkspace opens it with the application for it.
fn openUrl(_: ?*anyopaque, url: []const u8) bool {
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    const u = msg(id, class("NSURL"), "URLWithString:", .{nsString(url)});
    if (u == null) return false;
    return msg(BOOL, msg(id, class("NSWorkspace"), "sharedWorkspace", .{}), "openURL:", .{u});
}

/// One event loop iteration for every open window: waits for an event (at
/// most `max_wait_ms`, or until the next timer or animation frame),
/// handles the events, fires timers, runs change handlers and draws what
/// changed.
pub fn step(max_wait_ms: ?u32) Error!void {
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    core.updateTimersAndAnimations(now());
    var timeout: ?u64 = null; // null: until an event
    var it = open_windows;
    while (it) |w| : (it = w.next) if (w.needsFrame()) {
        // Animations: at the display's pace.
        const next = if (core.hasActiveAnimations() and !w.full_redraw and !w.ui.redraw_requested) w.last_frame + w.frameInterval() else 0;
        const wait = next -| now();
        timeout = if (timeout) |t| @min(t, wait) else wait;
    };
    if (timeout == null) if (core.nextTimerDeadline()) |deadline| {
        timeout = deadline -| now();
    };
    if (max_wait_ms) |m| timeout = if (timeout) |t| @min(t, m) else m;

    const date = if (timeout) |t|
        msg(id, class("NSDate"), "dateWithTimeIntervalSinceNow:", .{@as(f64, @floatFromInt(t)) / 1000})
    else
        msg(id, class("NSDate"), "distantFuture", .{});
    var event = nextEvent(date);
    while (event != null) : (event = nextEvent(msg(id, class("NSDate"), "distantPast", .{}))) {
        msg(void, app, "sendEvent:", .{event});
    }
    msg(void, app, "updateWindows", .{});

    core.updateTimersAndAnimations(now());
    core.runChangeHandlers();
    it = open_windows;
    while (it) |w| : (it = w.next) try w.afterEvents();
}

fn nextEvent(until: id) id {
    return msg(id, app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ @as(u64, std.math.maxInt(u64)), until, NSDefaultRunLoopMode, true });
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

// ---- Windows ----

pub const Window = struct {
    gpa: Allocator,
    ui: *core.Window,
    ns_window: id,
    view: id,
    delegate: id,
    /// The software renderer's framebuffer, in physical pixels (kept
    /// between frames: only what changed is redrawn).
    framebuffer: []Rgba8 = &.{},
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,
    software: zigulee.software.Renderer(Rgba8),
    /// A CoreGraphics context over the framebuffer.
    bitmap: ?*anyopaque = null,
    /// With Metal: the renderer and the view's layer.
    metal: ?*metal.Renderer = null,
    metal_layer: id = null,
    /// With OpenGL: the context and the GPU renderer.
    gl_context: id = null,
    gpu: ?*zigulee.gpu.gl.Renderer = null,
    gl_size: [2]u32 = .{ 0, 0 },
    full_redraw: bool = true,
    /// Set when the user closes the window (or quits); `run` returns.
    closed: bool = false,
    last_frame: u64 = 0,
    a11y: ?*Bridge = null,
    cursor: input.MouseCursor = .default,
    cursor_hidden: bool = false,
    /// The color scheme the window's frame shows.
    scheme: ?core.ColorScheme = null,
    /// Full screen, zoomed and the like, as asked and as shown.
    state: core.WindowStateSync = .{},
    tracking: id = null,
    /// Text being composed by an input method.
    marked: bool = false,
    marked_len16: usize = 0,
    next: ?*Window = null,

    /// Opens a window showing `ui`, sized to `ui.size()` in points. `ui`
    /// must outlive the window.
    pub fn create(gpa: Allocator, ui: *core.Window, options: Options) Error!*Window {
        if (app == null) try init();
        const pool = objc.objc_autoreleasePoolPush();
        defer objc.objc_autoreleasePoolPop(pool);
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .ui = ui, .ns_window = null, .view = null, .delegate = null, .software = .init(gpa) };
        errdefer self.software.deinit();
        // AppKit may have the view resized (allocating the framebuffer)
        // while a renderer is being tried.
        errdefer {
            if (self.bitmap) |b| CGContextRelease(b);
            gpa.free(self.framebuffer);
        }

        const size = ui.size();
        const rect: NSRect = .{ .size = .{ .width = size.width, .height = size.height } };
        var style: usize = 1 | 2 | 4; // titled, closable, miniaturizable
        if (options.resizable) style |= 8;
        self.ns_window = msg(id, msg(id, class("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ rect, style, @as(usize, 2), false }) orelse return error.CocoaFailed;
        errdefer msg(void, self.ns_window, "release", .{});
        msg(void, self.ns_window, "setReleasedWhenClosed:", .{false});
        msg(void, self.ns_window, "setTitle:", .{nsString(options.title)});
        msg(void, self.ns_window, "setAcceptsMouseMovedEvents:", .{true});
        msg(void, self.ns_window, "center", .{});

        self.view = msg(id, msg(id, viewClass(), "alloc", .{}), "initWithFrame:", .{rect});
        objc.ivarPtr(self.view, view_offset).* = self;
        msg(void, self.ns_window, "setContentView:", .{self.view});
        msg(void, self.view, "release", .{}); // the window keeps it
        // Drops from other applications: files and text.
        const dragged = msg(id, class("NSMutableArray"), "array", .{});
        msg(void, dragged, "addObject:", .{nsString(file_url_type)});
        msg(void, dragged, "addObject:", .{nsString(string_type)});
        msg(void, self.view, "registerForDraggedTypes:", .{dragged});
        _ = msg(BOOL, self.ns_window, "makeFirstResponder:", .{self.view});
        self.delegate = msg(id, msg(id, delegateClass(), "alloc", .{}), "init", .{});
        objc.ivarPtr(self.delegate, delegate_offset).* = self;
        msg(void, self.ns_window, "setDelegate:", .{self.delegate});
        errdefer {
            objc.ivarPtr(self.view, view_offset).* = null;
            objc.ivarPtr(self.delegate, delegate_offset).* = null;
            msg(void, self.ns_window, "setDelegate:", .{@as(id, null)});
            msg(void, self.delegate, "release", .{});
        }

        const gpu = switch (options.renderer) {
            .software => false,
            .metal => blk: {
                self.openMetal() catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.MetalFailed,
                };
                break :blk true;
            },
            .opengl => blk: {
                self.openGl() catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.OpenGlFailed,
                };
                break :blk true;
            },
            .auto => blk: {
                self.openMetal() catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        log.info("Metal unavailable: trying OpenGL", .{});
                        self.openGl() catch |gl_err| switch (gl_err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => {
                                log.info("OpenGL unavailable: using the software renderer", .{});
                                break :blk false;
                            },
                        };
                    },
                };
                break :blk true;
            },
        };
        if (!gpu) {
            // Frames become the contents of the view's layer.
            msg(void, self.view, "setWantsLayer:", .{true});
            const layer = msg(id, self.view, "layer", .{});
            msg(void, layer, "setContentsGravity:", .{nsString("topLeft")});
        }
        errdefer self.closeGl();
        errdefer self.closeMetal();
        try self.syncSize();

        ui.clipboard = .{ .ctx = null, .getFn = getClipboard, .setFn = setClipboard };
        ui.native_view = self.view;
        self.a11y = try Bridge.create(gpa, ui, self.ns_window);
        self.updateScheme();
        if (!options.hidden) self.show();
        self.next = open_windows;
        open_windows = self;
        return self;
    }

    /// Shows the window (and brings the application forward).
    pub fn show(self: *Window) void {
        msg(void, self.ns_window, "makeKeyAndOrderFront:", .{@as(id, null)});
        msg(void, app, "activateIgnoringOtherApps:", .{true});
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
        if (self.cursor_hidden) msg(void, class("NSCursor"), "unhide", .{});
        objc.ivarPtr(self.view, view_offset).* = null;
        objc.ivarPtr(self.delegate, delegate_offset).* = null;
        msg(void, self.ns_window, "setDelegate:", .{@as(id, null)});
        msg(void, self.delegate, "release", .{});
        self.closeGl();
        self.closeMetal();
        msg(void, self.ns_window, "orderOut:", .{@as(id, null)});
        msg(void, self.ns_window, "close", .{});
        msg(void, self.ns_window, "release", .{});
        if (self.bitmap) |b| CGContextRelease(b);
        self.software.deinit();
        self.gpa.free(self.framebuffer);
        self.gpa.destroy(self);
    }

    /// Shows another zigulee window in this one (live reloading), sized to
    /// the current window. `ui` must outlive the window or the next call.
    pub fn setUi(self: *Window, ui: *core.Window) Error!void {
        self.ui.clipboard = null;
        self.ui.native_view = null;
        if (self.a11y) |b| b.destroy();
        self.a11y = null;
        self.ui = ui;
        ui.clipboard = .{ .ctx = null, .getFn = getClipboard, .setFn = setClipboard };
        ui.native_view = self.view;
        self.a11y = try Bridge.create(self.gpa, ui, self.ns_window);
        try self.syncSize();
        self.full_redraw = true;
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        msg(void, self.ns_window, "setTitle:", .{nsString(title)});
    }

    /// Physical pixels per point.
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

    /// What AppKit shows the window as.
    fn actualState(self: *Window) core.WindowState {
        const full = msg(usize, self.ns_window, "styleMask", .{}) & full_screen_mask != 0;
        return .{
            .fullscreen = full,
            .maximized = !full and msg(BOOL, self.ns_window, "isZoomed", .{}),
            .minimized = msg(BOOL, self.ns_window, "isMiniaturized", .{}),
            .always_on_top = msg(isize, self.ns_window, "level", .{}) > normal_window_level,
        };
    }

    /// The window put in the state the app asks for, if that changed (as
    /// AppKit does it: zooming and full screen toggle).
    fn updateState(self: *Window) void {
        const want = self.state.sync(self.ui) orelse return;
        const is = self.actualState();
        if (want.always_on_top != is.always_on_top) msg(void, self.ns_window, "setLevel:", .{if (want.always_on_top) floating_window_level else normal_window_level});
        if (want.minimized != is.minimized) {
            if (want.minimized) msg(void, self.ns_window, "miniaturize:", .{@as(id, null)}) else msg(void, self.ns_window, "deminiaturize:", .{@as(id, null)});
        }
        if (want.fullscreen != is.fullscreen) msg(void, self.ns_window, "toggleFullScreen:", .{@as(id, null)});
        if (!want.fullscreen and want.maximized != is.maximized) msg(void, self.ns_window, "zoom:", .{@as(id, null)});
    }

    /// The user (or AppKit) changed the window's state: the app is told.
    fn reportState(self: *Window) void {
        self.state.report(self.ui, self.actualState());
    }

    /// Milliseconds between frames on the window's screen.
    fn frameInterval(self: *const Window) u64 {
        const screen = msg(id, self.ns_window, "screen", .{});
        const fps = if (screen != null) msg(isize, screen, "maximumFramesPerSecond", .{}) else 60;
        return @intCast(@divTrunc(1000, @max(fps, 1)));
    }

    /// After a round of events: a frame if anything changed, the cursor,
    /// the input method's caret and what assistive technology sees.
    fn afterEvents(self: *Window) Error!void {
        if (self.needsFrame()) try self.render();
        self.updateScheme();
        self.updateState();
        self.updateCursor(false);
        if (self.ui.ime_cursor_rect_changed) {
            self.ui.ime_cursor_rect_changed = false;
            const context = msg(id, self.view, "inputContext", .{});
            if (context != null) msg(void, context, "invalidateCharacterCoordinates", .{});
        }
        if (self.a11y) |b| try b.update();
    }

    /// Follows the view's size in points and pixels.
    fn syncSize(self: *Window) Error!void {
        const bounds = msg(NSRect, self.view, "bounds", .{});
        const backing = msg(NSRect, self.view, "convertRectToBacking:", .{bounds});
        self.ui.setSize(.{ .width = @floatCast(bounds.size.width), .height = @floatCast(bounds.size.height) });
        self.software.scale_factor = if (bounds.size.width > 0) @floatCast(backing.size.width / bounds.size.width) else 1;
        self.full_redraw = true;
        const width: u32 = @intFromFloat(@max(1, @round(backing.size.width)));
        const height: u32 = @intFromFloat(@max(1, @round(backing.size.height)));
        if (self.metal_layer != null) {
            msg(void, self.metal_layer, "setContentsScale:", .{@as(f64, self.software.scale_factor)});
            msg(void, self.metal_layer, "setDrawableSize:", .{NSSize{ .width = @floatFromInt(width), .height = @floatFromInt(height) }});
        }
        if (self.gpu != null or self.metal != null) {
            self.pixel_width = width;
            self.pixel_height = height;
            return;
        }
        if (width == self.pixel_width and height == self.pixel_height and self.bitmap != null) return;
        const framebuffer = try self.gpa.alloc(Rgba8, @as(usize, width) * height);
        @memset(framebuffer, .transparent);
        const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        defer CGColorSpaceRelease(space);
        const bitmap = CGBitmapContextCreate(framebuffer.ptr, width, height, 8, @as(usize, width) * 4, space, bitmap_info) orelse {
            self.gpa.free(framebuffer);
            return error.CocoaFailed;
        };
        if (self.bitmap) |b| CGContextRelease(b);
        self.gpa.free(self.framebuffer);
        self.framebuffer = framebuffer;
        self.bitmap = bitmap;
        self.pixel_width = width;
        self.pixel_height = height;
    }

    /// Draws what changed and shows it.
    pub fn render(self: *Window) Error!void {
        self.last_frame = now();
        if (self.metal) |m| {
            m.setScaleFactor(self.software.scale_factor);
            _ = try m.renderWindow(self.ui, self.pixel_width, self.pixel_height, if (self.full_redraw) .full else .partial, self.metal_layer);
            self.full_redraw = false;
            return;
        }
        if (self.gpu) |gpu| {
            msg(void, self.gl_context, "makeCurrentContext", .{});
            if (self.gl_size[0] != self.pixel_width or self.gl_size[1] != self.pixel_height) {
                msg(void, self.gl_context, "update", .{});
                self.gl_size = .{ self.pixel_width, self.pixel_height };
            }
            gpu.setScaleFactor(self.software.scale_factor);
            const region = try gpu.renderWindow(self.ui, self.pixel_width, self.pixel_height, if (self.full_redraw) .full else .partial);
            self.full_redraw = false;
            if (!region.isEmpty()) msg(void, self.gl_context, "flushBuffer", .{});
            return;
        }
        const canvas: zigulee.software.Canvas(Rgba8) = .init(self.framebuffer, self.pixel_width, self.pixel_height);
        const region = try self.software.renderWindow(self.ui, canvas, if (self.full_redraw) .full else .partial);
        self.full_redraw = false;
        if (region.isEmpty()) return;
        // The layer shows a snapshot of the framebuffer (copied when the
        // framebuffer next changes).
        const image = CGBitmapContextCreateImage(self.bitmap) orelse return error.CocoaFailed;
        defer CGImageRelease(image);
        const layer = msg(id, self.view, "layer", .{});
        msg(void, layer, "setContentsScale:", .{@as(f64, self.software.scale_factor)});
        msg(void, layer, "setContents:", .{@as(id, image)});
    }

    /// The view hosts a CAMetalLayer, drawn into by the Metal renderer.
    fn openMetal(self: *Window) (Error || metal.Error)!void {
        const renderer = try self.gpa.create(metal.Renderer);
        errdefer self.gpa.destroy(renderer);
        renderer.* = try .init(self.gpa);
        errdefer renderer.deinit();
        const layer = msg(id, class("CAMetalLayer"), "layer", .{}) orelse return error.MetalUnavailable;
        msg(void, layer, "setDevice:", .{renderer.device});
        msg(void, layer, "setPixelFormat:", .{@as(usize, 80)}); // BGRA8Unorm
        msg(void, layer, "setFramebufferOnly:", .{false});
        // The colors are sRGB, as the software renderer's.
        const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        defer CGColorSpaceRelease(space);
        msg(void, layer, "setColorspace:", .{@as(id, space)});
        msg(void, self.view, "setLayer:", .{layer});
        msg(void, self.view, "setWantsLayer:", .{true});
        self.metal_layer = layer;
        self.metal = renderer;
    }

    fn closeMetal(self: *Window) void {
        const renderer = self.metal orelse return;
        renderer.deinit();
        self.gpa.destroy(renderer);
        self.metal = null;
        self.metal_layer = null;
    }

    fn openGl(self: *Window) (Error || zigulee.gpu.gl.Error)!void {
        const attributes = [_]u32{
            99, 0x4100, // NSOpenGLPFAOpenGLProfile: 4.1 core
            8, 24, // color size
            11, 8, // alpha size
            5, // double buffer
            73, // accelerated
            0,
        };
        const format = msg(id, msg(id, class("NSOpenGLPixelFormat"), "alloc", .{}), "initWithAttributes:", .{&attributes}) orelse return error.OpenGlFailed;
        defer msg(void, format, "release", .{});
        const context = msg(id, msg(id, class("NSOpenGLContext"), "alloc", .{}), "initWithFormat:shareContext:", .{ format, @as(id, null) }) orelse return error.OpenGlFailed;
        errdefer msg(void, context, "release", .{});
        msg(void, self.view, "setWantsBestResolutionOpenGLSurface:", .{true});
        // The colors are sRGB: the window converts them for the display.
        msg(void, self.ns_window, "setColorSpace:", .{msg(id, class("NSColorSpace"), "sRGBColorSpace", .{})});
        msg(void, context, "setView:", .{self.view});
        msg(void, context, "makeCurrentContext", .{});
        const swap_interval: i32 = 1;
        msg(void, context, "setValues:forParameter:", .{ &swap_interval, @as(isize, 222) });
        const functions = try zigulee.gpu.gl.Functions.load({}, struct {
            fn f(_: void, name: [*:0]const u8) ?*const anyopaque {
                return dlsym(@ptrFromInt(@as(usize, @bitCast(@as(isize, -2)))), name); // RTLD_DEFAULT
            }
        }.f);
        const gpu = try self.gpa.create(zigulee.gpu.gl.Renderer);
        errdefer self.gpa.destroy(gpu);
        gpu.* = try .init(self.gpa, functions);
        self.gl_context = context;
        self.gpu = gpu;
    }

    fn closeGl(self: *Window) void {
        const gpu = self.gpu orelse return;
        msg(void, self.gl_context, "makeCurrentContext", .{});
        gpu.deinit();
        self.gpa.destroy(gpu);
        self.gpu = null;
        msg(void, class("NSOpenGLContext"), "clearCurrentContext", .{});
        msg(void, self.gl_context, "clearDrawable", .{});
        msg(void, self.gl_context, "release", .{});
        self.gl_context = null;
    }

    /// The title bar (and other system-drawn parts) light or dark, as the
    /// window's content.
    fn updateScheme(self: *Window) void {
        const scheme = self.ui.colorScheme();
        if (self.scheme == scheme) return;
        self.scheme = scheme;
        setAppearance(self.ns_window, scheme);
    }

    /// Shows the cursor the window asks for, while the pointer is over it
    /// (`force`: even if it did not change).
    fn updateCursor(self: *Window, force: bool) void {
        const want = self.ui.mouseCursor();
        if (want == self.cursor and !force) return;
        const location = msg(NSPoint, self.ns_window, "mouseLocationOutsideOfEventStream", .{});
        const p = msg(NSPoint, self.view, "convertPoint:fromView:", .{ location, @as(id, null) });
        const bounds = msg(NSRect, self.view, "bounds", .{});
        if (p.x < 0 or p.y < 0 or p.x >= bounds.size.width or p.y >= bounds.size.height) return;
        self.cursor = want;
        if (want == .none) {
            if (!self.cursor_hidden) msg(void, class("NSCursor"), "hide", .{});
            self.cursor_hidden = true;
            return;
        }
        if (self.cursor_hidden) msg(void, class("NSCursor"), "unhide", .{});
        self.cursor_hidden = false;
        msg(void, msg(id, class("NSCursor"), systemCursor(want), .{}), "set", .{});
    }

    // ---- Input ----

    /// A trackpad pinch or rotation, by its phase.
    fn trackpad(self: *Window, event: id, magnify: f32, rotate: f32) void {
        const at = self.position(event);
        switch (msg(usize, event, "phase", .{})) {
            1 => { // began
                gestures.dispatchTrackpad(self.ui, .began, 0, 0, at);
                if (magnify != 0 or rotate != 0) gestures.dispatchTrackpad(self.ui, .changed, magnify, rotate, at);
            },
            8, 16 => gestures.dispatchTrackpad(self.ui, .ended, 0, 0, at), // ended, cancelled
            else => gestures.dispatchTrackpad(self.ui, .changed, magnify, rotate, at),
        }
    }

    /// Where a drag from another application is, in the view.
    fn dragPoint(self: *Window, info: id) core.Point {
        const location = msg(NSPoint, info, "draggingLocation", .{});
        const p = msg(NSPoint, self.view, "convertPoint:fromView:", .{ location, @as(id, null) });
        return .{ .x = @floatCast(p.x), .y = @floatCast(p.y) };
    }

    /// A drag from another application moved over the view: whether it
    /// can be dropped there (a copy), or not.
    fn dragMoved(self: *Window, info: id) usize {
        const pb = msg(id, info, "draggingPasteboard", .{});
        const kind: []const u8 = if (pasteboardHas(pb, file_url_type)) dnd.file_kind else if (pasteboardHas(pb, string_type)) dnd.text_kind else return 0;
        return if (dnd.externalMoved(self.ui, &.{kind}, self.dragPoint(info))) drag_operation_copy else 0;
    }

    /// Dropped: its files (paths, one per line) or its text.
    fn dragDropped(self: *Window, info: id) bool {
        const pool = objc.objc_autoreleasePoolPush();
        defer objc.objc_autoreleasePoolPop(pool);
        const pb = msg(id, info, "draggingPasteboard", .{});
        const at = self.dragPoint(info);
        if (pasteboardHas(pb, file_url_type)) {
            const classes = msg(id, class("NSArray"), "arrayWithObject:", .{class("NSURL")});
            const urls = msg(id, pb, "readObjectsForClasses:options:", .{ classes, @as(id, null) });
            var paths: std.ArrayList(u8) = .empty;
            defer paths.deinit(self.gpa);
            const n = if (urls == null) 0 else msg(usize, urls, "count", .{});
            for (0..n) |i| {
                const url = msg(id, urls, "objectAtIndex:", .{i});
                if (!msg(BOOL, url, "isFileURL", .{})) continue;
                if (paths.items.len > 0) paths.append(self.gpa, '\n') catch return false;
                paths.appendSlice(self.gpa, objc.utf8(msg(id, url, "path", .{}))) catch return false;
            }
            if (paths.items.len == 0) return false;
            return dnd.externalDropped(self.ui, dnd.file_kind, paths.items, at);
        }
        const text = msg(id, pb, "stringForType:", .{nsString(string_type)});
        if (text == null) return false;
        return dnd.externalDropped(self.ui, dnd.text_kind, objc.utf8(text), at);
    }

    fn position(self: *Window, event: id) core.Point {
        const location = msg(NSPoint, event, "locationInWindow", .{});
        const p = msg(NSPoint, self.view, "convertPoint:fromView:", .{ location, @as(id, null) });
        return .{ .x = @floatCast(p.x), .y = @floatCast(p.y) };
    }

    fn mouseButton(self: *Window, event: id, pressed: bool) void {
        const button: input.PointerButton = switch (msg(isize, event, "buttonNumber", .{})) {
            0 => .left,
            1 => .right,
            2 => .middle,
            else => .other,
        };
        // The keyboard back from a native view over the window (a web view).
        if (pressed and msg(id, self.ns_window, "firstResponder", .{}) != self.view)
            _ = msg(BOOL, self.ns_window, "makeFirstResponder:", .{self.view});
        const p = self.position(event);
        self.ui.dispatchPointer(if (pressed)
            .{ .pressed = .{ .position = p, .button = button, .modifiers = modifiers(event) } }
        else
            .{ .released = .{ .position = p, .button = button } });
        self.updateCursor(false);
    }

    fn mouseMoved(self: *Window, event: id) void {
        self.ui.dispatchPointer(.{ .moved = .{ .position = self.position(event) } });
        self.updateCursor(false);
    }

    fn scrollWheel(self: *Window, event: id) void {
        var dx: f32 = @floatCast(msg(f64, event, "scrollingDeltaX", .{}));
        var dy: f32 = @floatCast(msg(f64, event, "scrollingDeltaY", .{}));
        // A mouse wheel counts lines; trackpads give points.
        if (!msg(BOOL, event, "hasPreciseScrollingDeltas", .{})) {
            dx *= wheel_step;
            dy *= wheel_step;
        }
        self.ui.dispatchPointer(.{ .wheel = .{ .position = self.position(event), .delta = .{ .x = dx, .y = dy } } });
    }

    /// Points scrolled per wheel notch.
    const wheel_step = 40;

    fn keyDown(self: *Window, event: id) void {
        const mods = modifiers(event);
        const chars = objc.utf8(msg(id, event, "charactersIgnoringModifiers", .{}));
        const repeat = msg(BOOL, event, "isARepeat", .{});
        // While composing, the input method gets every key.
        if (!self.marked) {
            if (specialKey(chars, mods)) |text| {
                self.ui.dispatchKey(.pressed, .{ .text = text, .modifiers = mods, .repeat = repeat });
                return;
            }
            // Shortcuts (Cmd+C, Ctrl+A...) produce no text: send the key.
            if ((mods.control or mods.meta) and chars.len == 1 and chars[0] >= 0x20 and chars[0] < 0x7f) {
                const lower = ascii[std.ascii.toLower(chars[0])..][0..1];
                self.ui.dispatchKey(.pressed, .{ .text = lower, .modifiers = mods, .repeat = repeat });
                return;
            }
        }
        // Text: through the system's text input (insertText:,
        // setMarkedText:...).
        msg(void, self.view, "interpretKeyEvents:", .{msg(id, class("NSArray"), "arrayWithObject:", .{event})});
    }

    fn keyUp(self: *Window, event: id) void {
        const mods = modifiers(event);
        const chars = objc.utf8(msg(id, event, "charactersIgnoringModifiers", .{}));
        if (specialKey(chars, mods)) |text| self.ui.dispatchKey(.released, .{ .text = text, .modifiers = mods });
    }

    fn insertText(self: *Window, string: id) void {
        const text = objc.utf8(plainString(string));
        if (self.marked) {
            self.marked = false;
            self.ui.dispatchPreedit("", 0);
        }
        if (text.len == 0) return;
        self.ui.dispatchKey(.pressed, .{ .text = text });
        self.ui.dispatchKey(.released, .{ .text = text });
    }

    fn setMarkedText(self: *Window, string: id, selected: NSRange) void {
        const ns = plainString(string);
        const text = objc.utf8(ns);
        self.marked = text.len > 0;
        self.marked_len16 = if (ns != null) msg(usize, ns, "length", .{}) else 0;
        // The caret: UTF-16 units to bytes.
        var cursor: usize = 0;
        var units: usize = 0;
        while (cursor < text.len and units < selected.location) {
            const len = std.unicode.utf8ByteSequenceLength(text[cursor]) catch 1;
            units += if (len == 4) 2 else 1;
            cursor += len;
        }
        self.ui.dispatchPreedit(text, @min(cursor, text.len));
    }

    /// Where the caret is, on the screen (for the input method's window).
    fn caretOnScreen(self: *Window) NSRect {
        const r = self.ui.ime_cursor_rect orelse core.Rect{};
        const in_view: NSRect = .{ .origin = .{ .x = r.x, .y = r.y }, .size = .{ .width = @max(1, r.width), .height = r.height } };
        const in_window = msg(NSRect, self.view, "convertRect:toView:", .{ in_view, @as(id, null) });
        return msg(NSRect, self.ns_window, "convertRectToScreen:", .{in_window});
    }
};

const step_ = step;

/// Gives an NSWindow the light or dark appearance (its title bar, and
/// system-drawn controls in it).
pub fn setAppearance(ns_window: id, scheme: core.ColorScheme) void {
    const name = if (scheme == .dark) NSAppearanceNameDarkAqua else NSAppearanceNameAqua;
    msg(void, ns_window, "setAppearance:", .{msg(id, class("NSAppearance"), "appearanceNamed:", .{name})});
}

/// An NSString (from an NSString or an NSAttributedString).
fn plainString(s: id) id {
    if (s == null) return null;
    if (msg(BOOL, s, "isKindOfClass:", .{class("NSAttributedString")})) return msg(id, s, "string", .{});
    return s;
}

const ascii: [128]u8 = blk: {
    var a: [128]u8 = undefined;
    for (&a, 0..) |*c, i| c.* = i;
    break :blk a;
};

fn modifiers(event: id) input.Modifiers {
    const flags = msg(usize, event, "modifierFlags", .{});
    return .{
        .shift = flags & (1 << 17) != 0,
        .control = flags & (1 << 18) != 0,
        .alt = flags & (1 << 19) != 0,
        .meta = flags & (1 << 20) != 0,
    };
}

/// zigulee's code for a special key, from the key's characters (AppKit uses
/// the same function key codes).
fn specialKey(chars: []const u8, mods: input.Modifiers) ?[]const u8 {
    const view = std.unicode.Utf8View.init(chars) catch return null;
    var it = view.iterator();
    const cp = it.nextCodepoint() orelse return null;
    if (it.nextCodepoint() != null) return null;
    return switch (cp) {
        0x7f, 0x08 => Key.backspace,
        0xF728 => Key.delete,
        0x0d, 0x03 => Key.@"return",
        0x09 => if (mods.shift) Key.back_tab else Key.tab,
        0x19 => Key.back_tab,
        0x1b => Key.escape,
        0xF700 => Key.up_arrow,
        0xF701 => Key.down_arrow,
        0xF702 => Key.left_arrow,
        0xF703 => Key.right_arrow,
        0xF729 => Key.home,
        0xF72B => Key.end,
        0xF72C => Key.page_up,
        0xF72D => Key.page_down,
        else => null,
    };
}

fn systemCursor(cursor: input.MouseCursor) [:0]const u8 {
    return switch (cursor) {
        .default, .none, .help, .progress, .wait, .move => "arrowCursor",
        .pointer => "pointingHandCursor",
        .crosshair => "crosshairCursor",
        .text => "IBeamCursor",
        .not_allowed => "operationNotAllowedCursor",
        .grab => "openHandCursor",
        .grabbing => "closedHandCursor",
        .col_resize, .ew_resize => "resizeLeftRightCursor",
        .row_resize, .ns_resize => "resizeUpDownCursor",
        .nesw_resize, .nwse_resize => "crosshairCursor",
    };
}

fn getClipboard(_: ?*anyopaque, gpa: Allocator) ?[]u8 {
    const board = msg(id, class("NSPasteboard"), "generalPasteboard", .{});
    const s = msg(id, board, "stringForType:", .{NSPasteboardTypeString});
    if (s == null) return null;
    return gpa.dupe(u8, objc.utf8(s)) catch null;
}

fn setClipboard(_: ?*anyopaque, text: []const u8) void {
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    const board = msg(id, class("NSPasteboard"), "generalPasteboard", .{});
    _ = msg(isize, board, "clearContents", .{});
    _ = msg(BOOL, board, "setString:forType:", .{ nsString(text), NSPasteboardTypeString });
}

// ---- The classes ----

var view_class: id = null;
var view_offset: isize = 0;
var delegate_class: id = null;
var delegate_offset: isize = 0;
var app_delegate_class: id = null;

fn ivarWindow(obj: id, offset: isize) ?*Window {
    return @ptrCast(@alignCast(objc.ivarPtr(obj, offset).*));
}

/// ZiguleeView: the content view, receiving input.
fn viewClass() id {
    if (view_class) |c| return c;
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("NSView"), "ZiguleeView", 0);
    _ = objc.class_addIvar(cls, "zigulee_window", @sizeOf(usize), std.math.log2_int(usize, @alignOf(usize)), "^v");
    const range = "{_NSRange=QQ}";
    const rect = "{CGRect={CGPoint=dd}{CGSize=dd}}";
    inline for (.{
        .{ "isFlipped", &View.yes, "c@:" },
        .{ "acceptsFirstResponder", &View.yes, "c@:" },
        .{ "acceptsFirstMouse:", &View.yesFor, "c@:@" },
        .{ "mouseDown:", &View.down, "v@:@" },
        .{ "rightMouseDown:", &View.down, "v@:@" },
        .{ "otherMouseDown:", &View.down, "v@:@" },
        .{ "mouseUp:", &View.up, "v@:@" },
        .{ "rightMouseUp:", &View.up, "v@:@" },
        .{ "otherMouseUp:", &View.up, "v@:@" },
        .{ "mouseMoved:", &View.moved, "v@:@" },
        .{ "mouseDragged:", &View.moved, "v@:@" },
        .{ "rightMouseDragged:", &View.moved, "v@:@" },
        .{ "otherMouseDragged:", &View.moved, "v@:@" },
        .{ "mouseExited:", &View.exited, "v@:@" },
        .{ "cursorUpdate:", &View.cursorUpdate, "v@:@" },
        .{ "scrollWheel:", &View.scroll, "v@:@" },
        .{ "keyDown:", &View.keyDown, "v@:@" },
        .{ "keyUp:", &View.keyUp, "v@:@" },
        .{ "updateTrackingAreas", &View.updateTrackingAreas, "v@:" },
        .{ "viewDidChangeBackingProperties", &View.backingChanged, "v@:" },
        // NSTextInputClient
        .{ "insertText:replacementRange:", &View.insertText, "v@:@" ++ range },
        .{ "setMarkedText:selectedRange:replacementRange:", &View.setMarkedText, "v@:@" ++ range ++ range },
        .{ "unmarkText", &View.unmarkText, "v@:" },
        .{ "hasMarkedText", &View.hasMarkedText, "c@:" },
        .{ "markedRange", &View.markedRange, range ++ "@:" },
        .{ "selectedRange", &View.selectedRange, range ++ "@:" },
        .{ "validAttributesForMarkedText", &View.validAttributes, "@@:" },
        .{ "attributedSubstringForProposedRange:actualRange:", &View.substring, "@@:" ++ range ++ "^" ++ range },
        .{ "characterIndexForPoint:", &View.characterIndex, "Q@:{CGPoint=dd}" },
        .{ "firstRectForCharacterRange:actualRange:", &View.firstRect, rect ++ "@:" ++ range ++ "^" ++ range },
        .{ "doCommandBySelector:", &View.doCommand, "v@::" },
        // Trackpad gestures
        .{ "magnifyWithEvent:", &View.magnify, "v@:@" },
        .{ "rotateWithEvent:", &View.rotate, "v@:@" },
        // NSDraggingDestination
        .{ "draggingEntered:", &View.dragUpdated, "Q@:@" },
        .{ "draggingUpdated:", &View.dragUpdated, "Q@:@" },
        .{ "draggingExited:", &View.dragExited, "v@:@" },
        .{ "performDragOperation:", &View.performDrag, "c@:@" },
    }) |m| _ = objc.class_addMethod(cls, objc.sel(m[0]), @ptrCast(m[1]), m[2]);
    _ = objc.class_addProtocol(cls, objc.objc_getProtocol("NSTextInputClient"));
    objc.objc_registerClassPair(cls);
    view_offset = objc.ivar_getOffset(objc.class_getInstanceVariable(cls, "zigulee_window"));
    view_class = cls;
    return cls;
}

const View = struct {
    fn window(self: id) ?*Window {
        return ivarWindow(self, view_offset);
    }

    fn yes(_: id, _: SEL) callconv(.c) BOOL {
        return true;
    }

    fn yesFor(_: id, _: SEL, _: id) callconv(.c) BOOL {
        return true;
    }

    fn down(self: id, _: SEL, event: id) callconv(.c) void {
        if (window(self)) |w| w.mouseButton(event, true);
    }

    fn up(self: id, _: SEL, event: id) callconv(.c) void {
        if (window(self)) |w| w.mouseButton(event, false);
    }

    fn moved(self: id, _: SEL, event: id) callconv(.c) void {
        if (window(self)) |w| w.mouseMoved(event);
    }

    fn exited(self: id, _: SEL, _: id) callconv(.c) void {
        if (window(self)) |w| w.ui.dispatchPointer(.exit);
    }

    fn cursorUpdate(self: id, _: SEL, _: id) callconv(.c) void {
        if (window(self)) |w| w.updateCursor(true);
    }

    fn scroll(self: id, _: SEL, event: id) callconv(.c) void {
        if (window(self)) |w| w.scrollWheel(event);
    }

    fn keyDown(self: id, _: SEL, event: id) callconv(.c) void {
        if (window(self)) |w| w.keyDown(event);
    }

    fn keyUp(self: id, _: SEL, event: id) callconv(.c) void {
        if (window(self)) |w| w.keyUp(event);
    }

    fn updateTrackingAreas(self: id, cmd: SEL) callconv(.c) void {
        _ = cmd;
        if (window(self)) |w| {
            if (w.tracking != null) {
                msg(void, self, "removeTrackingArea:", .{w.tracking});
                msg(void, w.tracking, "release", .{});
            }
            // Entered/exited, moved, cursor updates; in the active app, over
            // the visible rect.
            const options: usize = 0x01 | 0x02 | 0x04 | 0x40 | 0x200;
            w.tracking = msg(id, msg(id, class("NSTrackingArea"), "alloc", .{}), "initWithRect:options:owner:userInfo:", .{ NSRect{}, options, self, @as(id, null) });
            msg(void, self, "addTrackingArea:", .{w.tracking});
        }
        objc.msgSuper(void, self, viewClass(), "updateTrackingAreas", .{});
    }

    fn backingChanged(self: id, _: SEL) callconv(.c) void {
        if (window(self)) |w| w.syncSize() catch log.err("could not resize the framebuffer", .{});
    }

    fn insertText(self: id, _: SEL, string: id, _: NSRange) callconv(.c) void {
        if (window(self)) |w| w.insertText(string);
    }

    fn setMarkedText(self: id, _: SEL, string: id, selected: NSRange, _: NSRange) callconv(.c) void {
        if (window(self)) |w| w.setMarkedText(string, selected);
    }

    fn unmarkText(self: id, _: SEL) callconv(.c) void {
        if (window(self)) |w| if (w.marked) {
            w.marked = false;
            w.ui.dispatchPreedit("", 0);
        };
    }

    fn hasMarkedText(self: id, _: SEL) callconv(.c) BOOL {
        return if (window(self)) |w| w.marked else false;
    }

    fn markedRange(self: id, _: SEL) callconv(.c) NSRange {
        if (window(self)) |w| if (w.marked) return .{ .location = 0, .length = w.marked_len16 };
        return .{ .location = objc.not_found, .length = 0 };
    }

    fn selectedRange(_: id, _: SEL) callconv(.c) NSRange {
        return .{ .location = 0, .length = 0 };
    }

    fn validAttributes(_: id, _: SEL) callconv(.c) id {
        return msg(id, class("NSArray"), "array", .{});
    }

    fn substring(_: id, _: SEL, _: NSRange, _: ?*NSRange) callconv(.c) id {
        return null;
    }

    fn characterIndex(_: id, _: SEL, _: NSPoint) callconv(.c) usize {
        return objc.not_found;
    }

    fn firstRect(self: id, _: SEL, _: NSRange, _: ?*NSRange) callconv(.c) NSRect {
        return if (window(self)) |w| w.caretOnScreen() else .{};
    }

    fn doCommand(_: id, _: SEL, _: SEL) callconv(.c) void {}

    fn magnify(self: id, _: SEL, event: id) callconv(.c) void {
        if (window(self)) |w| w.trackpad(event, @floatCast(msg(f64, event, "magnification", .{})), 0);
    }

    fn rotate(self: id, _: SEL, event: id) callconv(.c) void {
        // Counterclockwise in AppKit; clockwise in zigulee.
        if (window(self)) |w| w.trackpad(event, 0, -msg(f32, event, "rotation", .{}));
    }

    fn dragUpdated(self: id, _: SEL, info: id) callconv(.c) usize {
        return if (window(self)) |w| w.dragMoved(info) else 0;
    }

    fn dragExited(self: id, _: SEL, _: id) callconv(.c) void {
        if (window(self)) |w| dnd.externalLeft(w.ui);
    }

    fn performDrag(self: id, _: SEL, info: id) callconv(.c) BOOL {
        return if (window(self)) |w| w.dragDropped(info) else false;
    }
};

const full_screen_mask: usize = 1 << 14;
const normal_window_level: isize = 0;
const floating_window_level: isize = 3;

const file_url_type = "public.file-url";
const string_type = "public.utf8-plain-text";
const drag_operation_copy = 1;

fn pasteboardHas(pb: id, ty: []const u8) bool {
    const types = msg(id, class("NSArray"), "arrayWithObject:", .{nsString(ty)});
    return msg(id, pb, "availableTypeFromArray:", .{types}) != null;
}

/// ZiguleeWindowDelegate: closing and resizing.
fn delegateClass() id {
    if (delegate_class) |c| return c;
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("NSObject"), "ZiguleeWindowDelegate", 0);
    _ = objc.class_addIvar(cls, "zigulee_window", @sizeOf(usize), std.math.log2_int(usize, @alignOf(usize)), "^v");
    inline for (.{
        .{ "windowShouldClose:", &Delegate.shouldClose, "c@:@" },
        .{ "windowDidResize:", &Delegate.didResize, "v@:@" },
        .{ "windowDidChangeBackingProperties:", &Delegate.didResize, "v@:@" },
        .{ "windowDidMiniaturize:", &Delegate.stateChanged, "v@:@" },
        .{ "windowDidDeminiaturize:", &Delegate.stateChanged, "v@:@" },
        .{ "windowDidEnterFullScreen:", &Delegate.stateChanged, "v@:@" },
        .{ "windowDidExitFullScreen:", &Delegate.stateChanged, "v@:@" },
    }) |m| _ = objc.class_addMethod(cls, objc.sel(m[0]), @ptrCast(m[1]), m[2]);
    objc.objc_registerClassPair(cls);
    delegate_offset = objc.ivar_getOffset(objc.class_getInstanceVariable(cls, "zigulee_window"));
    delegate_class = cls;
    return cls;
}

const Delegate = struct {
    /// The window stays open: `run` returns and the application destroys
    /// it.
    fn shouldClose(self: id, _: SEL, _: id) callconv(.c) BOOL {
        if (ivarWindow(self, delegate_offset)) |w| w.closed = true;
        return false;
    }

    fn stateChanged(self: id, _: SEL, _: id) callconv(.c) void {
        if (ivarWindow(self, delegate_offset)) |w| w.reportState();
    }

    /// Also during a live resize, when the event loop is blocked: draw now.
    fn didResize(self: id, _: SEL, _: id) callconv(.c) void {
        const w = ivarWindow(self, delegate_offset) orelse return;
        // Zoomed or not, perhaps.
        w.reportState();
        w.syncSize() catch return log.err("could not resize the framebuffer", .{});
        core.updateTimersAndAnimations(now());
        core.runChangeHandlers();
        w.render() catch log.err("could not draw the window", .{});
    }
};

/// ZiguleeAppDelegate: Quit closes the windows instead of exiting.
fn appDelegateClass() id {
    if (app_delegate_class) |c| return c;
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("NSObject"), "ZiguleeAppDelegate", 0);
    _ = objc.class_addMethod(cls, objc.sel("applicationShouldTerminate:"), @ptrCast(&shouldTerminate), "Q@:@");
    objc.objc_registerClassPair(cls);
    app_delegate_class = cls;
    return cls;
}

fn shouldTerminate(_: id, _: SEL, _: id) callconv(.c) usize {
    var it = open_windows;
    while (it) |w| : (it = w.next) w.closed = true;
    return 0; // NSTerminateCancel: the loop returns, the app exits
}

// ---- Tests ----

const testing = std.testing;

extern "c" fn CGImageGetDataProvider(image: ?*anyopaque) ?*anyopaque;
extern "c" fn CGDataProviderCopyData(provider: ?*anyopaque) ?*anyopaque;
extern "c" fn CGImageGetBytesPerRow(image: ?*anyopaque) usize;
extern "c" fn CGImageGetWidth(image: ?*anyopaque) usize;
extern "c" fn CFDataGetBytePtr(data: ?*anyopaque) [*]const u8;
extern "c" fn CFRelease(obj: ?*anyopaque) void;

/// The pixel the window's layer shows at (x, y) points.
fn shownPixel(w: *Window, x: usize, y: usize) !core.Color {
    const image = msg(?*anyopaque, msg(id, w.view, "layer", .{}), "contents", .{}) orelse return error.NoImage;
    const data = CGDataProviderCopyData(CGImageGetDataProvider(image)) orelse return error.NoImage;
    defer CFRelease(data);
    const s: usize = @intFromFloat(w.scaleFactor());
    const at = (y * s) * CGImageGetBytesPerRow(image) + (x * s) * 4;
    const bytes = CFDataGetBytePtr(data)[at..][0..4];
    return .{ .r = bytes[0], .g = bytes[1], .b = bytes[2], .a = bytes[3] };
}

/// A mouse event at (x, y) points in the view (top-left origin).
fn mouseEvent(w: *Window, kind: usize, x: f64, y: f64) id {
    const height = msg(NSRect, w.view, "bounds", .{}).size.height;
    const in_window = msg(NSPoint, w.view, "convertPoint:toView:", .{ NSPoint{ .x = x, .y = y }, @as(id, null) });
    _ = height;
    return msg(id, class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
        kind,          in_window,                                    @as(usize, 0),
        @as(f64, 0),   msg(isize, w.ns_window, "windowNumber", .{}), @as(id, null),
        @as(isize, 0), @as(isize, 1),                                @as(f32, 1),
    });
}

fn keyEvent(w: *Window, kind: usize, chars: []const u8, flags: usize) id {
    return msg(id, class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        kind,          NSPoint{},       flags,           @as(f64, 0), msg(isize, w.ns_window, "windowNumber", .{}),
        @as(id, null), nsString(chars), nsString(chars), false,       @as(u16, 0),
    });
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

test "a native window: render, click, type, compose, resize, close" {
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    try init();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    const w = try Window.create(testing.allocator, &t.ui, .{ .title = "test", .hidden = true, .renderer = .software });
    defer w.destroy();

    try step(0);
    try testing.expect(!t.ui.redraw_requested);
    try testing.expectEqual(core.Color.rgb(0xff0000), try shownPixel(w, 20, 20));
    try testing.expectEqual(core.Color.white, try shownPixel(w, 100, 70));

    // A click on the button turns it blue on the next frame.
    msg(void, w.view, "mouseDown:", .{mouseEvent(w, 1, 30, 20)});
    msg(void, w.view, "mouseUp:", .{mouseEvent(w, 2, 30, 20)});
    try step(0);
    try testing.expectEqual(@as(usize, 1), t.clicks);
    try testing.expectEqual(core.Color.rgb(0x0000ff), try shownPixel(w, 20, 20));

    // Text, special keys and shortcuts reach the focused item.
    t.keys.focus();
    msg(void, w.view, "insertText:replacementRange:", .{ nsString("hé"), NSRange{ .location = objc.not_found } });
    msg(void, w.view, "keyDown:", .{keyEvent(w, 10, "\r", 0)});
    msg(void, w.view, "keyDown:", .{keyEvent(w, 10, "\u{F702}", 0)});
    msg(void, w.view, "keyDown:", .{keyEvent(w, 10, "c", 1 << 20)});
    try testing.expectEqualStrings("hé" ++ Key.@"return" ++ Key.left_arrow ++ "c", t.typed[0..t.typed_len]);
    // Typing goes through the system's text input to insertText:.
    msg(void, w.view, "keyDown:", .{keyEvent(w, 10, "x", 0)});
    try testing.expectEqualStrings("hé" ++ Key.@"return" ++ Key.left_arrow ++ "cx", t.typed[0..t.typed_len]);

    // An input method: composed text is pre-edit text until inserted.
    var field: core.items.TextInput = undefined;
    field.init(testing.allocator);
    defer field.deinit();
    t.ui.rootItem().appendChild(&field.item);
    field.item.setGeometry(.{ .x = 10, .y = 50, .width = 100, .height = 20 });
    field.focus();
    msg(void, w.view, "setMarkedText:selectedRange:replacementRange:", .{ nsString("kあ"), NSRange{ .location = 1 }, NSRange{ .location = objc.not_found } });
    try testing.expectEqualStrings("kあ", field.preedit.get());
    try testing.expectEqual(@as(usize, 1), field.preedit_cursor);
    try testing.expect(msg(BOOL, w.view, "hasMarkedText", .{}));
    msg(void, w.view, "insertText:replacementRange:", .{ nsString("か"), NSRange{ .location = objc.not_found } });
    try testing.expectEqualStrings("か", field.text.get());
    try testing.expectEqualStrings("", field.preedit.get());
    try testing.expect(!msg(BOOL, w.view, "hasMarkedText", .{}));
    // The candidate window goes by the caret, on the screen.
    try step(0);
    const caret = msg(NSRect, w.view, "firstRectForCharacterRange:actualRange:", .{ NSRange{}, @as(?*NSRange, null) });
    try testing.expect(caret.size.height > 0);

    // Resizing the window resizes the zigulee window, and redraws.
    msg(void, w.ns_window, "setContentSize:", .{NSSize{ .width = 200, .height = 150 }});
    try testing.expectEqual(core.Size{ .width = 200, .height = 150 }, t.ui.size());
    try testing.expectEqual(core.Color.white, try shownPixel(w, 190, 140));

    // Closing ends the loop (the window stays until destroyed).
    msg(void, w.ns_window, "performClose:", .{@as(id, null)});
    try w.run();
    try testing.expect(w.closed);
}

test "time advances: timers fire, animations run to their end" {
    try init();
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 60, .height = 30 });
    defer ui.deinit();
    const w = try Window.create(testing.allocator, &ui, .{ .hidden = true, .renderer = .software });
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
    // Nothing else to do: the loop sleeps until the timer is due (a few
    // steps at most: system events may wake one early).
    var steps: usize = 0;
    while (!fired and now() - start < 1000) : (steps += 1) try step(1000);
    try testing.expect(fired);
    const elapsed = now() - start;
    try testing.expect(elapsed >= 45 and elapsed < 900);
    try testing.expect(steps < 10);

    // A color animation reaches its end value, with frames in between.
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

test "the title bar follows the window's color scheme" {
    try init();
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 60, .height = 30 });
    defer ui.deinit();
    const w = try Window.create(testing.allocator, &ui, .{ .hidden = true, .renderer = .software });
    defer w.destroy();
    const appearance = struct {
        fn name(win: *Window) []const u8 {
            return objc.utf8(msg(id, msg(id, win.ns_window, "appearance", .{}), "name", .{}));
        }
    }.name;
    try testing.expectEqualStrings("NSAppearanceNameAqua", appearance(w));
    // A dark background (a dark theme) makes it dark.
    ui.root.background.set(.color(.rgb(0x202020)));
    try step(0);
    try testing.expectEqualStrings("NSAppearanceNameDarkAqua", appearance(w));
    // Or set explicitly.
    ui.color_scheme.set(.light);
    try step(0);
    try testing.expectEqualStrings("NSAppearanceNameAqua", appearance(w));
}

test "window state: always on top and zoomed, as asked and as the user leaves it" {
    try init();
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 120, .height = 80 });
    defer ui.deinit();
    const w = try Window.create(testing.allocator, &ui, .{ .hidden = true, .renderer = .software });
    defer w.destroy();
    try step(0);
    try testing.expect(!w.actualState().always_on_top);
    ui.always_on_top.set(true);
    try step(0);
    try testing.expectEqual(floating_window_level, msg(isize, w.ns_window, "level", .{}));
    ui.maximized.set(true);
    try step(0);
    try testing.expect(msg(BOOL, w.ns_window, "isZoomed", .{}));
    // The user unzooms it (the green button): the app is told.
    msg(void, w.ns_window, "zoom:", .{@as(id, null)});
    try step(0);
    try testing.expect(!ui.maximized.get());
    try testing.expect(ui.always_on_top.get());
}

test "the clipboard is the system's" {
    try init();
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 60, .height = 30 });
    defer ui.deinit();
    const w = try Window.create(testing.allocator, &ui, .{ .hidden = true, .renderer = .software });
    defer w.destroy();
    ui.clipboard.?.setFn(null, "zigulee clipboard test");
    const text = ui.clipboardText(testing.allocator).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("zigulee clipboard test", text);
}

test "OpenGL draws a 3D scene as the CPU does" {
    try init();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    var view: core.items.View3D = undefined;
    view.init(testing.allocator);
    defer view.deinit();
    var cube: core.items.SceneModel = .{};
    defer cube.deinit();
    var ball: core.items.SceneModel = .{};
    defer ball.deinit();
    var light: core.items.PointLight = .{};
    defer light.deinit();
    // Over the whole window (above its button).
    t.ui.rootItem().appendChild(&view.item);
    view.item.appendChildren(&.{ &cube.item, &ball.item, &light.item });
    view.item.width.set(120);
    view.item.height.set(80);
    view.background.set(.rgb(0x101828));
    cube.color.set(.rgb(0xef4444));
    cube.placement.yaw.set(30);
    cube.placement.position_x.set(-0.8);
    ball.mesh.set(.sphere);
    ball.color.set(.rgb(0x3b82f6));
    ball.roughness.set(0.3);
    ball.placement.position_x.set(0.9);
    light.placement.position_x.set(1);
    light.placement.position_y.set(1);
    light.placement.position_z.set(3);

    const w = Window.create(testing.allocator, &t.ui, .{ .hidden = true, .renderer = .opengl, .resizable = false }) catch return error.SkipZigTest;
    defer w.destroy();
    const gpu = w.gpu.?;
    if (!gpu.batcher.gpu_scenes) return error.SkipZigTest;
    msg(void, w.gl_context, "makeCurrentContext", .{});
    gpu.setScaleFactor(w.scaleFactor());
    _ = try gpu.renderWindow(&t.ui, w.pixel_width, w.pixel_height, .full);
    const pw: usize = w.pixel_width;
    const ph: usize = w.pixel_height;
    const drawn = try testing.allocator.alloc(Rgba8, pw * ph);
    defer testing.allocator.free(drawn);
    gpu.readPixels(w.pixel_width, w.pixel_height, drawn);
    // Drawn on the GPU: no picture on the CPU.
    try testing.expectEqual(@as(u32, 0), view.width);

    const expected = try testing.allocator.alloc(Rgba8, drawn.len);
    defer testing.allocator.free(expected);
    @memset(expected, .transparent);
    var software: zigulee.software.Renderer(Rgba8) = .init(testing.allocator);
    defer software.deinit();
    software.scale_factor = w.scaleFactor();
    _ = try software.renderWindow(&t.ui, .init(expected, w.pixel_width, w.pixel_height), .full);
    // The same but for edges (multisampled here, oversampled there) and
    // rounding: the right way up, its back faces culled.
    var off: usize = 0;
    for (expected, drawn) |e, a| {
        inline for (.{ "r", "g", "b", "a" }) |ch| {
            if (@abs(@as(i16, @field(e, ch)) - @field(a, ch)) > 24) {
                off += 1;
                break;
            }
        }
    }
    try testing.expect(off < pw * ph / 50);
    // The cube's lit face, the ball.
    const cube_at = drawn[(ph / 2) * pw + pw * 40 / 120];
    const ball_at = drawn[(ph / 2) * pw + pw * 92 / 120];
    try testing.expect(cube_at.r > cube_at.b + 60);
    try testing.expect(ball_at.b > ball_at.r + 60);
}

test "OpenGL draws what the software renderer draws" {
    try init();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    var card: core.items.Rectangle = .{};
    defer card.deinit();
    t.ui.rootItem().appendChild(&card.item);
    card.item.setGeometry(.{ .x = 64, .y = 8, .width = 50, .height = 40 });
    card.border_radius.set(9);
    card.border_width.set(2.5);
    card.border_color.set(.color(.rgb(0x111827)));
    card.background.set(.linear(45, &.{ .{ .color = .rgb(0xf59e0b), .position = 0 }, .{ .color = .rgb(0x7c3aed), .position = 1 } }));

    const w = Window.create(testing.allocator, &t.ui, .{ .hidden = true, .renderer = .opengl, .resizable = false }) catch return error.SkipZigTest;
    defer w.destroy();
    // Drawn and read back before the buffers are swapped.
    const gpu = w.gpu.?;
    msg(void, w.gl_context, "makeCurrentContext", .{});
    gpu.setScaleFactor(w.scaleFactor());
    _ = try gpu.renderWindow(&t.ui, w.pixel_width, w.pixel_height, .full);
    const drawn = try testing.allocator.alloc(Rgba8, @as(usize, w.pixel_width) * w.pixel_height);
    defer testing.allocator.free(drawn);
    gpu.readPixels(w.pixel_width, w.pixel_height, drawn);

    const expected = try testing.allocator.alloc(Rgba8, drawn.len);
    defer testing.allocator.free(expected);
    @memset(expected, .transparent);
    var software: zigulee.software.Renderer(Rgba8) = .init(testing.allocator);
    defer software.deinit();
    software.scale_factor = w.scaleFactor();
    _ = try software.renderWindow(&t.ui, .init(expected, w.pixel_width, w.pixel_height), .full);
    var off: usize = 0;
    for (expected, drawn) |e, a| {
        inline for (.{ "r", "g", "b", "a" }) |ch| {
            if (@abs(@as(i16, @field(e, ch)) - @field(a, ch)) > 3) off += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), off);

    // A partial frame, over the last one: only the button is redrawn.
    t.button.background.set(.color(.rgb(0x00aa55)));
    const region = try gpu.renderWindow(&t.ui, w.pixel_width, w.pixel_height, .partial);
    try testing.expect(!region.isEmpty() and region.boundingBox().area() < @as(f32, @floatFromInt(drawn.len)) / 2);
    gpu.readPixels(w.pixel_width, w.pixel_height, drawn);
    @memset(expected, .transparent);
    _ = try software.renderWindow(&t.ui, .init(expected, w.pixel_width, w.pixel_height), .full);
    off = 0;
    for (expected, drawn) |e, a| {
        inline for (.{ "r", "g", "b", "a" }) |ch| {
            if (@abs(@as(i16, @field(e, ch)) - @field(a, ch)) > 3) off += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), off);
}

test "a Metal window draws what the software renderer draws" {
    try init();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    const w = Window.create(testing.allocator, &t.ui, .{ .hidden = true, .renderer = .metal }) catch return error.SkipZigTest;
    defer w.destroy();
    const drawn = try testing.allocator.alloc(Rgba8, @as(usize, w.pixel_width) * w.pixel_height);
    defer testing.allocator.free(drawn);
    const expected = try testing.allocator.alloc(Rgba8, drawn.len);
    defer testing.allocator.free(expected);
    var software: zigulee.software.Renderer(Rgba8) = .init(testing.allocator);
    defer software.deinit();
    software.scale_factor = w.scaleFactor();
    for (0..2) |round| {
        // The second time, only the button changes (a partial frame).
        if (round == 1) t.button.background.set(.color(.rgb(0x00aa55)));
        try step(0);
        w.metal.?.readPixels(drawn);
        @memset(expected, .transparent);
        _ = try software.renderWindow(&t.ui, .init(expected, w.pixel_width, w.pixel_height), .full);
        for (expected, drawn) |e, a| {
            inline for (.{ "r", "g", "b", "a" }) |c| try testing.expect(@abs(@as(i16, @field(e, c)) - @field(a, c)) <= 3);
        }
    }
}

/// Stands for AppKit's dragging info (NSDraggingInfo): a pasteboard and
/// where the drag is, in the window.
const TestDrag = struct {
    var pasteboard: id = null;
    var location: NSPoint = .{};
    var cls: id = null;

    fn info() id {
        if (cls == null) {
            cls = objc.objc_allocateClassPair(objc.objc_getClass("NSObject"), "ZiguleeTestDrag", 0);
            _ = objc.class_addMethod(cls, objc.sel("draggingPasteboard"), @ptrCast(&board), "@@:");
            _ = objc.class_addMethod(cls, objc.sel("draggingLocation"), @ptrCast(&at), "{CGPoint=dd}@:");
            objc.objc_registerClassPair(cls);
        }
        return msg(id, msg(id, cls, "alloc", .{}), "init", .{});
    }
    fn board(_: id, _: SEL) callconv(.c) id {
        return pasteboard;
    }
    fn at(_: id, _: SEL) callconv(.c) NSPoint {
        return location;
    }
};

test "files and text dropped from other applications" {
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    try init();
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 120, .height = 80 });
    defer ui.deinit();
    var files: core.items.DropArea = .{};
    defer files.deinit();
    ui.rootItem().appendChild(&files.item);
    files.item.setGeometry(.{ .width = 60, .height = 80 });
    files.accepts.set(dnd.file_kind);
    const Got = struct {
        buf: [256]u8 = undefined,
        len: usize = 0,
        fn f(self: *@This(), data: []const u8) void {
            @memcpy(self.buf[0..data.len], data);
            self.len = data.len;
        }
    };
    var got: Got = .{};
    files.dropped.setHandler(&got, Got.f);
    const w = try Window.create(testing.allocator, &ui, .{ .hidden = true, .renderer = .software });
    defer w.destroy();

    // A private pasteboard with a file URL.
    TestDrag.pasteboard = msg(id, class("NSPasteboard"), "pasteboardWithUniqueName", .{});
    defer msg(void, TestDrag.pasteboard, "releaseGlobally", .{});
    _ = msg(isize, TestDrag.pasteboard, "clearContents", .{});
    const url = msg(id, class("NSURL"), "fileURLWithPath:", .{nsString("/tmp/zigulee drop.txt")});
    _ = msg(BOOL, TestDrag.pasteboard, "writeObjects:", .{msg(id, class("NSArray"), "arrayWithObject:", .{url})});
    const info = TestDrag.info();
    defer msg(void, info, "release", .{});

    // Over the files area (window coordinates: y from the bottom).
    TestDrag.location = msg(NSPoint, w.view, "convertPoint:toView:", .{ NSPoint{ .x = 20, .y = 20 }, @as(id, null) });
    try testing.expectEqual(@as(usize, drag_operation_copy), msg(usize, w.view, "draggingEntered:", .{info}));
    try testing.expect(files.contains_drag.get());
    // Elsewhere: not droppable there.
    TestDrag.location = msg(NSPoint, w.view, "convertPoint:toView:", .{ NSPoint{ .x = 100, .y = 20 }, @as(id, null) });
    try testing.expectEqual(@as(usize, 0), msg(usize, w.view, "draggingUpdated:", .{info}));
    try testing.expect(!files.contains_drag.get());
    msg(void, w.view, "draggingExited:", .{info});

    TestDrag.location = msg(NSPoint, w.view, "convertPoint:toView:", .{ NSPoint{ .x = 20, .y = 20 }, @as(id, null) });
    _ = msg(usize, w.view, "draggingEntered:", .{info});
    try testing.expect(msg(BOOL, w.view, "performDragOperation:", .{info}));
    try testing.expectEqualStrings("/tmp/zigulee drop.txt", got.buf[0..got.len]);

    // Text: not a file, not taken by this area.
    _ = msg(isize, TestDrag.pasteboard, "clearContents", .{});
    _ = msg(BOOL, TestDrag.pasteboard, "setString:forType:", .{ nsString("hello"), nsString(string_type) });
    got.len = 0;
    try testing.expectEqual(@as(usize, 0), msg(usize, w.view, "draggingEntered:", .{info}));
    try testing.expect(!msg(BOOL, w.view, "performDragOperation:", .{info}));
    try testing.expectEqual(@as(usize, 0), got.len);
}

/// Stands for an NSEvent of a trackpad gesture.
const TestGesture = struct {
    var phase: usize = 0;
    var magnification: f64 = 0;
    var rotation: f32 = 0;
    var location: NSPoint = .{};
    var cls: id = null;

    fn event() id {
        if (cls == null) {
            cls = objc.objc_allocateClassPair(objc.objc_getClass("NSObject"), "ZiguleeTestGesture", 0);
            _ = objc.class_addMethod(cls, objc.sel("phase"), @ptrCast(&getPhase), "Q@:");
            _ = objc.class_addMethod(cls, objc.sel("magnification"), @ptrCast(&getMagnification), "d@:");
            _ = objc.class_addMethod(cls, objc.sel("rotation"), @ptrCast(&getRotation), "f@:");
            _ = objc.class_addMethod(cls, objc.sel("locationInWindow"), @ptrCast(&getLocation), "{CGPoint=dd}@:");
            objc.objc_registerClassPair(cls);
        }
        return msg(id, msg(id, cls, "alloc", .{}), "init", .{});
    }
    fn getPhase(_: id, _: SEL) callconv(.c) usize {
        return phase;
    }
    fn getMagnification(_: id, _: SEL) callconv(.c) f64 {
        return magnification;
    }
    fn getRotation(_: id, _: SEL) callconv(.c) f32 {
        return rotation;
    }
    fn getLocation(_: id, _: SEL) callconv(.c) NSPoint {
        return location;
    }
};

test "trackpad pinches and rotations" {
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    try init();
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 120, .height = 80 });
    defer ui.deinit();
    var pinch: core.items.PinchArea = .{};
    defer pinch.deinit();
    ui.rootItem().appendChild(&pinch.item);
    pinch.item.setGeometry(.{ .width = 120, .height = 80 });
    const w = try Window.create(testing.allocator, &ui, .{ .hidden = true, .renderer = .software });
    defer w.destroy();
    const e = TestGesture.event();
    defer msg(void, e, "release", .{});
    TestGesture.location = msg(NSPoint, w.view, "convertPoint:toView:", .{ NSPoint{ .x = 40, .y = 30 }, @as(id, null) });

    TestGesture.phase = 1; // began
    TestGesture.magnification = 0;
    msg(void, w.view, "magnifyWithEvent:", .{e});
    try testing.expect(pinch.active.get());
    TestGesture.phase = 4; // changed
    TestGesture.magnification = 0.5;
    msg(void, w.view, "magnifyWithEvent:", .{e});
    try testing.expectApproxEqAbs(@as(f32, 1.5), pinch.scale.get(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40), pinch.center_x.get(), 0.5);
    TestGesture.rotation = 10; // counterclockwise
    msg(void, w.view, "rotateWithEvent:", .{e});
    try testing.expectEqual(@as(f32, -10), pinch.rotation.get());
    TestGesture.phase = 8; // ended
    msg(void, w.view, "magnifyWithEvent:", .{e});
    try testing.expect(!pinch.active.get());
}
