// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The iOS backend: shows a `zigulee.Window` with UIKit (iPhone, iPad, the
//! simulator, and Macs through Mac Catalyst), with no other dependency
//! than the system's frameworks (talked to through the Objective-C
//! runtime). Same interface as the other backends:
//!
//!     try ios.init();
//!     defer ios.deinit();
//!     const window = try ios.Window.create(gpa, &ui_window, .{ .title = "Hello" });
//!     defer window.destroy();
//!     try window.run();
//!
//! UIKit owns the start of an iOS app (`UIApplicationMain`), so the app's
//! `main` runs from `start`, called by the program's real `main` (the
//! build's `iosApp` writes that one): UIKit starts, and once the app has
//! launched, `main` runs, with the event loop turning in `step` as
//! elsewhere. When `main` returns, the app exits.
//!
//! Windows draw with Metal (the GPU renderer) or the software renderer,
//! whose frames become the contents of the view's layer. Fingers are
//! touches (one works as the mouse, two pinch); on iPad and Mac, the
//! pointer hovers and the trackpad or wheel scrolls. The on-screen
//! keyboard shows while a text field has the focus (UIKeyInput: text, no
//! input methods' composition yet); hardware keyboards send their special
//! keys and shortcuts. The safe area and the keyboard's height reach the
//! window's `safe-area-*` and `keyboard-height`. VoiceOver sees the
//! accessible items (accessibility.zig).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const gestures = core.gestures;
const Rgba8 = core.Rgba8;
const input = core.input;
const Key = input.Key;
const apple = @import("zigulee-apple");
const objc = apple.objc;
const metal = apple.metal;
const id = objc.id;
const SEL = objc.SEL;
const BOOL = objc.BOOL;
const NSPoint = objc.NSPoint;
const NSSize = objc.NSSize;
const NSRect = objc.NSRect;
const msg = objc.msg;
const class = objc.class;
const nsString = objc.nsString;
const Bridge = @import("accessibility.zig").Bridge;

const log = std.log.scoped(.zigulee_ios);

pub const Error = error{
    /// UIKit did not give the app a scene (a place to show windows).
    UIKitFailed,
    /// The app's `main` was not started by `start` (UIKit is not running).
    NotStarted,
    MetalFailed,
} || Allocator.Error;

// ---- Frameworks ----

extern "c" const kCFRunLoopDefaultMode: ?*anyopaque;
extern "c" fn CFRunLoopRunInMode(mode: ?*anyopaque, seconds: f64, return_after_source_handled: bool) i32;
const run_loop_handled_source = 4;
extern "c" fn UIApplicationMain(argc: c_int, argv: ?*anyopaque, principal: id, delegate: id) c_int;
extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *?*anyopaque;
extern "c" const UIKeyboardWillChangeFrameNotification: id;
extern "c" const UIKeyboardWillHideNotification: id;
extern "c" const UIKeyboardFrameEndUserInfoKey: id;
extern "c" const kCGColorSpaceSRGB: ?*anyopaque;
extern "c" fn CGColorSpaceCreateWithName(name: ?*anyopaque) ?*anyopaque;
extern "c" fn CGColorSpaceRelease(space: ?*anyopaque) void;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits: usize, bytes_per_row: usize, space: ?*anyopaque, info: u32) ?*anyopaque;
extern "c" fn CGBitmapContextCreateImage(context: ?*anyopaque) ?*anyopaque;
extern "c" fn CGContextRelease(context: ?*anyopaque) void;
extern "c" fn CGImageRelease(image: ?*anyopaque) void;

/// Premultiplied RGBA, in memory order (kCGImageAlphaPremultipliedLast |
/// kCGBitmapByteOrder32Big).
const bitmap_info: u32 = 1 | (4 << 12);

const UIEdgeInsets = extern struct { top: f64 = 0, left: f64 = 0, bottom: f64 = 0, right: f64 = 0 };

// Zig's stack traces look modules up with a dyld function iOS does not
// export; dladdr knows the same.
comptime {
    if (builtin.os.tag == .ios) @export(&imageHeaderContaining, .{ .name = "_dyld_get_image_header_containing_address" });
}

const DlInfo = extern struct { fname: ?[*:0]const u8, fbase: ?*anyopaque, sname: ?[*:0]const u8, saddr: ?*anyopaque };
extern "c" fn dladdr(address: *const anyopaque, info: *DlInfo) c_int;

fn imageHeaderContaining(address: *const anyopaque) callconv(.c) ?*anyopaque {
    var info: DlInfo = undefined;
    return if (dladdr(address, &info) != 0) info.fbase else null;
}

pub const RendererKind = enum {
    /// Metal, else software.
    auto,
    /// The GPU renderer on Metal: the window fails to open without it.
    metal,
    /// The software renderer: only what changed is redrawn.
    software,
};

pub const Options = struct {
    /// Shown in the app switcher (on iPad) and the title bar (on Mac).
    title: [:0]const u8 = "zigulee",
    /// On Mac, whether the user can resize the window (phones and tablets
    /// give apps the whole screen, or the part of it the user chose).
    resizable: bool = true,
    renderer: RendererKind = .auto,
    /// Not shown (shown later with `Window.show`).
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

/// The app's `main`, run once UIKit has launched.
var app_main: ?*const fn () void = null;
var launched = false;
/// The scene windows go into, once UIKit connects it.
var scene: id = null;
/// False while the app is in the background (nothing is drawn).
var foreground = true;
var open_windows: ?*Window = null;

/// Starts UIKit, then runs `main(process)` once the app has launched
/// (exiting when it returns). Call from the program's `main`, with its
/// `std.process.Init`.
pub fn start(process: std.process.Init, comptime main: anytype) noreturn {
    const Main = struct {
        var saved: std.process.Init = undefined;
        fn run() void {
            main(saved) catch |err| {
                log.err("{t}", .{err});
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
                std.process.exit(1);
            };
        }
    };
    Main.saved = process;
    app_main = Main.run;
    const pool = objc.objc_autoreleasePoolPush();
    // Made before UIKit looks them up by name.
    _ = appDelegateClass();
    _ = sceneDelegateClass();
    _ = UIApplicationMain(_NSGetArgc().*, _NSGetArgv().*, null, nsString("ZiguleeAppDelegate"));
    objc.objc_autoreleasePoolPop(pool);
    std.process.exit(0);
}

/// Sound: the mixer plays through CoreAudio (from `init` to `deinit`).
var audio_output: apple.coreaudio.Output = .{};

/// Makes CoreAudio the mixer's audio output (the device starts when
/// something plays) and AVFoundation a video decoder. Call once, before
/// creating windows.
pub fn init() Error!void {
    _ = now();
    if (!launched) return error.NotStarted;
    core.audio.mixer().setOutput(audio_output.output());
    core.video.addDecoder(apple.avfoundation.decoder);
    core.links.setOpener(.{ .open = openUrl });
    core.webview.setProvider(apple.webview.provider);
    core.location.setProvider(apple.location.provider);
}

pub fn deinit() void {
    core.audio.mixer().setOutput(null);
    core.video.removeDecoder("avfoundation");
    core.links.setOpener(null);
    core.webview.setProvider(null);
    core.location.setProvider(null);
}

/// `open-url`: UIApplication hands it to the app for it (Safari, Mail,
/// ...), later; taken if it is a URL.
fn openUrl(_: ?*anyopaque, url: []const u8) bool {
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    const u = objc.msg(objc.id, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)});
    if (u == null) return false;
    const app = objc.msg(objc.id, objc.class("UIApplication"), "sharedApplication", .{});
    const options = objc.msg(objc.id, objc.class("NSDictionary"), "dictionary", .{});
    objc.msg(void, app, "openURL:options:completionHandler:", .{ u, options, @as(?*anyopaque, null) });
    return true;
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
    while (it) |w| : (it = w.next) if (foreground and w.needsFrame()) {
        // Animations: at the display's pace.
        const next = if (core.hasActiveAnimations() and !w.full_redraw and !w.ui.redraw_requested) w.last_frame + w.frameInterval() else 0;
        const wait = next -| now();
        timeout = if (timeout) |t| @min(t, wait) else wait;
    };
    if (timeout == null) if (core.nextTimerDeadline()) |deadline| {
        timeout = deadline -| now();
    };
    if (max_wait_ms) |m| timeout = if (timeout) |t| @min(t, m) else m;
    runLoop(if (timeout) |t| @as(f64, @floatFromInt(t)) / 1000 else 1e10);

    core.updateTimersAndAnimations(now());
    core.runChangeHandlers();
    it = open_windows;
    while (it) |w| : (it = w.next) try w.afterEvents();
}

/// Lets UIKit handle events, waiting at most `seconds` for the first.
fn runLoop(seconds: f64) void {
    var result = CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, true);
    var more: u32 = 0;
    while (result == run_loop_handled_source and more < 256) : (more += 1) {
        result = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);
    }
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
    ui_window: id,
    controller: id,
    view: id,
    /// The software renderer's framebuffer, in physical pixels (kept
    /// between frames: only what changed is redrawn).
    framebuffer: []Rgba8 = &.{},
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,
    software: zigulee.software.Renderer(Rgba8),
    /// A CoreGraphics context over the framebuffer.
    bitmap: ?*anyopaque = null,
    /// With Metal: the renderer and its layer (over the view's).
    metal: ?*metal.Renderer = null,
    metal_layer: id = null,
    full_redraw: bool = true,
    /// Set when the system takes the window away; `run` returns.
    closed: bool = false,
    last_frame: u64 = 0,
    a11y: ?*Bridge = null,
    /// The color scheme the status bar and keyboard show.
    scheme: ?core.ColorScheme = null,
    /// Full screen (the status bar hidden), as asked and as shown.
    state: core.WindowStateSync = .{},
    /// The on-screen keyboard is up for a text field (the view is the
    /// first responder; else the controller is, for hardware keys).
    typing: bool = false,
    /// Where the pointer was in the last scroll (trackpad, wheel).
    scrolled: NSPoint = .{},
    next: ?*Window = null,

    /// Opens a window showing `ui`, filling the screen (on Mac, sized to
    /// `ui.size()`). `ui` must outlive the window.
    pub fn create(gpa: Allocator, ui: *core.Window, options: Options) Error!*Window {
        if (!launched) return error.NotStarted;
        const pool = objc.objc_autoreleasePoolPush();
        defer objc.objc_autoreleasePoolPop(pool);
        // UIKit connects the scene soon after launching.
        const asked = now();
        while (scene == null) {
            if (now() - asked > 10_000) return error.UIKitFailed;
            runLoop(0.05);
        }
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .ui = ui, .ui_window = null, .controller = null, .view = null, .software = .init(gpa) };
        errdefer self.software.deinit();
        errdefer {
            if (self.bitmap) |b| CGContextRelease(b);
            gpa.free(self.framebuffer);
        }

        msg(void, scene, "setTitle:", .{nsString(options.title)});
        self.ui_window = msg(id, msg(id, class("UIWindow"), "alloc", .{}), "initWithWindowScene:", .{scene}) orelse return error.UIKitFailed;
        errdefer msg(void, self.ui_window, "release", .{});
        self.controller = msg(id, msg(id, controllerClass(), "alloc", .{}), "init", .{});
        objc.ivarPtr(self.controller, controller_offset).* = self;
        errdefer msg(void, self.controller, "release", .{});
        self.view = msg(id, msg(id, viewClass(), "alloc", .{}), "initWithFrame:", .{msg(NSRect, self.ui_window, "bounds", .{})});
        objc.ivarPtr(self.view, view_offset).* = self;
        msg(void, self.view, "setMultipleTouchEnabled:", .{true});
        msg(void, self.controller, "setView:", .{self.view});
        msg(void, self.view, "release", .{}); // the controller keeps it
        errdefer objc.ivarPtr(self.view, view_offset).* = null;
        // The pointer hovering (iPad, Mac) and scrolling with a trackpad or
        // wheel (not with fingers: those are touches).
        const hover = msg(id, msg(id, class("UIHoverGestureRecognizer"), "alloc", .{}), "initWithTarget:action:", .{ self.view, objc.sel("ziguleeHover:") });
        msg(void, self.view, "addGestureRecognizer:", .{hover});
        msg(void, hover, "release", .{});
        const scroll = msg(id, msg(id, class("UIPanGestureRecognizer"), "alloc", .{}), "initWithTarget:action:", .{ self.view, objc.sel("ziguleeScroll:") });
        msg(void, scroll, "setAllowedScrollTypesMask:", .{@as(isize, 3)}); // continuous, discrete
        msg(void, scroll, "setAllowedTouchTypes:", .{msg(id, class("NSArray"), "array", .{})});
        msg(void, self.view, "addGestureRecognizer:", .{scroll});
        msg(void, scroll, "release", .{});
        msg(void, self.ui_window, "setRootViewController:", .{self.controller});
        const center = msg(id, class("NSNotificationCenter"), "defaultCenter", .{});
        msg(void, center, "addObserver:selector:name:object:", .{ self.controller, objc.sel("ziguleeKeyboard:"), UIKeyboardWillChangeFrameNotification, @as(id, null) });
        msg(void, center, "addObserver:selector:name:object:", .{ self.controller, objc.sel("ziguleeKeyboard:"), UIKeyboardWillHideNotification, @as(id, null) });
        errdefer msg(void, center, "removeObserver:", .{self.controller});

        const gpu = switch (options.renderer) {
            .software => false,
            .metal => blk: {
                self.openMetal() catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.MetalFailed;
                break :blk true;
            },
            .auto => blk: {
                self.openMetal() catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        log.info("Metal unavailable: using the software renderer", .{});
                        break :blk false;
                    },
                };
                break :blk true;
            },
        };
        if (!gpu) msg(void, msg(id, self.view, "layer", .{}), "setContentsGravity:", .{nsString("resize")});
        errdefer self.closeMetal();
        if (builtin.os.tag == .maccatalyst) self.requestSize(ui.size(), options.resizable);

        ui.clipboard = .{ .ctx = null, .getFn = getClipboard, .setFn = setClipboard };
        ui.native_view = self.view;
        self.a11y = try Bridge.create(gpa, ui, self.view);
        self.next = open_windows;
        open_windows = self;
        if (!options.hidden) self.show();
        try self.syncSize();
        return self;
    }

    /// Shows the window (above the app's others).
    pub fn show(self: *Window) void {
        msg(void, self.ui_window, "makeKeyAndVisible", .{});
        _ = msg(BOOL, if (self.typing) self.view else self.controller, "becomeFirstResponder", .{});
        msg(void, self.view, "layoutIfNeeded", .{});
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
        msg(void, msg(id, class("NSNotificationCenter"), "defaultCenter", .{}), "removeObserver:", .{self.controller});
        objc.ivarPtr(self.view, view_offset).* = null;
        objc.ivarPtr(self.controller, controller_offset).* = null;
        _ = msg(BOOL, self.view, "resignFirstResponder", .{});
        self.closeMetal();
        msg(void, self.ui_window, "setHidden:", .{true});
        msg(void, self.ui_window, "setRootViewController:", .{@as(id, null)});
        msg(void, self.controller, "release", .{});
        msg(void, self.ui_window, "release", .{});
        if (self.bitmap) |b| CGContextRelease(b);
        self.software.deinit();
        self.gpa.free(self.framebuffer);
        self.gpa.destroy(self);
    }

    /// Shows another zigulee window in this one (live reloading). `ui` must
    /// outlive the window or the next call.
    pub fn setUi(self: *Window, ui: *core.Window) Error!void {
        self.ui.clipboard = null;
        self.ui.native_view = null;
        if (self.a11y) |b| b.destroy();
        self.a11y = null;
        self.ui = ui;
        ui.clipboard = .{ .ctx = null, .getFn = getClipboard, .setFn = setClipboard };
        ui.native_view = self.view;
        self.a11y = try Bridge.create(self.gpa, ui, self.view);
        try self.syncSize();
        self.full_redraw = true;
    }

    pub fn setTitle(_: *Window, title: [:0]const u8) void {
        msg(void, scene, "setTitle:", .{nsString(title)});
    }

    /// Physical pixels per point.
    pub fn scaleFactor(self: *const Window) f32 {
        return self.software.scale_factor;
    }

    /// Runs the event loop until the window is taken away (other open
    /// windows keep working meanwhile).
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

    /// Milliseconds between frames on the window's screen.
    fn frameInterval(self: *const Window) u64 {
        const screen = msg(id, self.ui_window, "screen", .{});
        const fps = if (screen != null) msg(isize, screen, "maximumFramesPerSecond", .{}) else 60;
        return @intCast(@divTrunc(1000, @max(fps, 1)));
    }

    /// After a round of events: a frame if anything changed (in the
    /// foreground), the keyboard, the status bar and what VoiceOver sees.
    fn afterEvents(self: *Window) Error!void {
        if (foreground and self.needsFrame()) try self.render();
        self.updateKeyboard();
        self.updateScheme();
        self.updateState();
        if (self.a11y) |b| try b.update();
    }

    /// The on-screen keyboard up while a text field has the focus.
    fn updateKeyboard(self: *Window) void {
        const want = self.ui.ime_cursor_rect != null;
        if (want == self.typing) return;
        self.typing = want;
        if (want) {
            _ = msg(BOOL, self.view, "becomeFirstResponder", .{});
        } else {
            _ = msg(BOOL, self.controller, "becomeFirstResponder", .{});
        }
    }

    /// The status bar, the keyboard and system-drawn parts light or dark,
    /// as the window's content.
    fn updateScheme(self: *Window) void {
        const scheme = self.ui.colorScheme();
        if (self.scheme == scheme) return;
        self.scheme = scheme;
        msg(void, self.ui_window, "setOverrideUserInterfaceStyle:", .{@as(isize, if (scheme == .dark) 2 else 1)});
        msg(void, self.controller, "setNeedsStatusBarAppearanceUpdate", .{});
    }

    /// Full screen: the status bar hidden, the home indicator out of the
    /// way. The rest (maximized, minimized, on top) is not up to apps.
    fn updateState(self: *Window) void {
        const want = self.state.sync(self.ui) orelse return;
        msg(void, self.controller, "setNeedsStatusBarAppearanceUpdate", .{});
        msg(void, self.controller, "setNeedsUpdateOfHomeIndicatorAutoHidden", .{});
        self.state.report(self.ui, .{ .fullscreen = want.fullscreen });
    }

    /// On Mac: the window sized to `size` (in points), and kept so unless
    /// `resizable`.
    fn requestSize(self: *Window, size: core.Size, resizable: bool) void {
        _ = self;
        if (!resizable) {
            const restrictions = msg(id, scene, "sizeRestrictions", .{});
            const s: NSSize = .{ .width = size.width, .height = size.height };
            if (restrictions != null) {
                msg(void, restrictions, "setMinimumSize:", .{s});
                msg(void, restrictions, "setMaximumSize:", .{s});
            }
        }
        const geometry = msg(id, scene, "effectiveGeometry", .{});
        var frame: NSRect = if (geometry != null) msg(NSRect, geometry, "systemFrame", .{}) else .{};
        frame.size = .{ .width = size.width, .height = size.height };
        const prefs = msg(id, msg(id, class("UIWindowSceneGeometryPreferencesMac"), "alloc", .{}), "initWithSystemFrame:", .{frame}) orelse return;
        defer msg(void, prefs, "release", .{});
        msg(void, scene, "requestGeometryUpdateWithPreferences:errorHandler:", .{ prefs, @as(id, null) });
    }

    /// Follows the view's size in points and pixels, and its safe area.
    fn syncSize(self: *Window) Error!void {
        const bounds = msg(NSRect, self.view, "bounds", .{});
        const scale: f32 = @floatCast(msg(f64, self.view, "contentScaleFactor", .{}));
        self.ui.setSize(.{ .width = @floatCast(bounds.size.width), .height = @floatCast(bounds.size.height) });
        self.syncInsets();
        self.software.scale_factor = scale;
        self.full_redraw = true;
        const width: u32 = @intFromFloat(@max(1, @round(bounds.size.width * scale)));
        const height: u32 = @intFromFloat(@max(1, @round(bounds.size.height * scale)));
        if (self.metal_layer != null) {
            msg(void, self.metal_layer, "setFrame:", .{bounds});
            msg(void, self.metal_layer, "setContentsScale:", .{@as(f64, scale)});
            msg(void, self.metal_layer, "setDrawableSize:", .{NSSize{ .width = @floatFromInt(width), .height = @floatFromInt(height) }});
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
            return error.UIKitFailed;
        };
        if (self.bitmap) |b| CGContextRelease(b);
        self.gpa.free(self.framebuffer);
        self.framebuffer = framebuffer;
        self.bitmap = bitmap;
        self.pixel_width = width;
        self.pixel_height = height;
    }

    /// The safe area: what the status bar, the notch, the home indicator
    /// and rounded corners leave clear.
    fn syncInsets(self: *Window) void {
        const insets = msg(UIEdgeInsets, self.view, "safeAreaInsets", .{});
        self.ui.safe_area_top.set(@floatCast(insets.top));
        self.ui.safe_area_left.set(@floatCast(insets.left));
        self.ui.safe_area_bottom.set(@floatCast(insets.bottom));
        self.ui.safe_area_right.set(@floatCast(insets.right));
    }

    /// The keyboard moved: how much of the view it covers (`frame`: on the
    /// screen; null: hidden).
    fn keyboardMoved(self: *Window, frame: ?NSRect) void {
        const bounds = msg(NSRect, self.view, "bounds", .{});
        const covered: f64 = if (frame) |f| blk: {
            const screen = msg(id, self.ui_window, "screen", .{});
            if (screen == null) break :blk 0;
            const r = msg(NSRect, self.view, "convertRect:fromCoordinateSpace:", .{ f, msg(id, screen, "coordinateSpace", .{}) });
            break :blk std.math.clamp(bounds.size.height - r.origin.y, 0, bounds.size.height);
        } else 0;
        self.ui.keyboard_height.set(@floatCast(covered));
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
        const canvas: zigulee.software.Canvas(Rgba8) = .init(self.framebuffer, self.pixel_width, self.pixel_height);
        const region = try self.software.renderWindow(self.ui, canvas, if (self.full_redraw) .full else .partial);
        self.full_redraw = false;
        if (region.isEmpty()) return;
        // The layer shows a snapshot of the framebuffer.
        const image = CGBitmapContextCreateImage(self.bitmap) orelse return error.UIKitFailed;
        defer CGImageRelease(image);
        const layer = msg(id, self.view, "layer", .{});
        msg(void, layer, "setContentsScale:", .{@as(f64, self.software.scale_factor)});
        msg(void, layer, "setContents:", .{@as(id, image)});
    }

    /// A CAMetalLayer over the view's layer, drawn into by the Metal
    /// renderer.
    fn openMetal(self: *Window) (Error || metal.Error)!void {
        const renderer = try self.gpa.create(metal.Renderer);
        errdefer self.gpa.destroy(renderer);
        renderer.* = try .init(self.gpa);
        errdefer renderer.deinit();
        const layer = msg(id, class("CAMetalLayer"), "layer", .{}) orelse return error.MetalUnavailable;
        msg(void, layer, "setDevice:", .{renderer.device});
        msg(void, layer, "setPixelFormat:", .{@as(usize, 80)}); // BGRA8Unorm
        msg(void, layer, "setFramebufferOnly:", .{false});
        msg(void, layer, "setOpaque:", .{false});
        // The colors are sRGB, as the software renderer's.
        const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        defer CGColorSpaceRelease(space);
        msg(void, layer, "setColorspace:", .{@as(id, space)});
        msg(void, msg(id, self.view, "layer", .{}), "addSublayer:", .{layer});
        self.metal_layer = layer;
        self.metal = renderer;
    }

    fn closeMetal(self: *Window) void {
        const renderer = self.metal orelse return;
        msg(void, self.metal_layer, "removeFromSuperlayer", .{});
        renderer.deinit();
        self.gpa.destroy(renderer);
        self.metal = null;
        self.metal_layer = null;
    }

    // ---- Input ----

    /// Each finger in `touches` (an NSSet of UITouch), by its phase.
    fn touches(self: *Window, set: id, phase: gestures.TouchPhase) void {
        const all = msg(id, set, "allObjects", .{});
        for (0..msg(usize, all, "count", .{})) |i| {
            const touch = msg(id, all, "objectAtIndex:", .{i});
            const p = msg(NSPoint, touch, "locationInView:", .{self.view});
            gestures.dispatchTouch(self.ui, @intFromPtr(touch.?), phase, .{ .x = @floatCast(p.x), .y = @floatCast(p.y) });
        }
    }

    /// The pointer over the view, with no button down (iPad, Mac).
    fn hovered(self: *Window, recognizer: id) void {
        const p = msg(NSPoint, recognizer, "locationInView:", .{self.view});
        switch (msg(isize, recognizer, "state", .{})) {
            1, 2 => self.ui.dispatchPointer(.{ .moved = .{ .position = .{ .x = @floatCast(p.x), .y = @floatCast(p.y) } } }), // began, changed
            else => self.ui.dispatchPointer(.exit),
        }
    }

    /// A trackpad or wheel scrolled: by how much since the last time.
    fn scrolledBy(self: *Window, recognizer: id) void {
        const t = msg(NSPoint, recognizer, "translationInView:", .{self.view});
        const state = msg(isize, recognizer, "state", .{});
        if (state == 1) self.scrolled = .{}; // began
        const delta: core.Point = .{ .x = @floatCast(t.x - self.scrolled.x), .y = @floatCast(t.y - self.scrolled.y) };
        self.scrolled = if (state == 1 or state == 2) t else .{};
        if (delta.x == 0 and delta.y == 0) return;
        const p = msg(NSPoint, recognizer, "locationInView:", .{self.view});
        self.ui.dispatchPointer(.{ .wheel = .{ .position = .{ .x = @floatCast(p.x), .y = @floatCast(p.y) }, .delta = delta } });
    }

    /// Text from the on-screen keyboard (or a hardware one's characters).
    fn insertText(self: *Window, string: id) void {
        const text = objc.utf8(string);
        if (text.len == 0) return;
        const key = if (std.mem.eql(u8, text, "\n")) Key.@"return" else if (std.mem.eql(u8, text, "\t")) Key.tab else text;
        self.ui.dispatchKey(.pressed, .{ .text = key });
        self.ui.dispatchKey(.released, .{ .text = key });
    }

    fn deleteBackward(self: *Window) void {
        self.ui.dispatchKey(.pressed, .{ .text = Key.backspace });
        self.ui.dispatchKey(.released, .{ .text = Key.backspace });
    }

    /// Hardware keys (an NSSet of UIPress): special keys and shortcuts go
    /// to zigulee; false if some were not taken (the characters typed, which
    /// come back through `insertText`).
    fn presses(self: *Window, set: id, kind: input.KeyEventKind) bool {
        var all_taken = true;
        const all = msg(id, set, "allObjects", .{});
        for (0..msg(usize, all, "count", .{})) |i| {
            const key = msg(id, msg(id, all, "objectAtIndex:", .{i}), "key", .{});
            if (key == null or !self.press(key, kind)) all_taken = false;
        }
        return all_taken;
    }

    fn press(self: *Window, key: id, kind: input.KeyEventKind) bool {
        const flags = msg(usize, key, "modifierFlags", .{});
        const mods: input.Modifiers = .{
            .shift = flags & (1 << 17) != 0,
            .control = flags & (1 << 18) != 0,
            .alt = flags & (1 << 19) != 0,
            .meta = flags & (1 << 20) != 0,
        };
        if (specialKey(msg(isize, key, "keyCode", .{}), mods)) |text| {
            self.ui.dispatchKey(kind, .{ .text = text, .modifiers = mods });
            return true;
        }
        // Shortcuts (Cmd+C, Ctrl+A...) produce no text: send the key.
        const chars = objc.utf8(msg(id, key, "charactersIgnoringModifiers", .{}));
        if ((mods.control or mods.meta) and chars.len == 1 and chars[0] >= 0x20 and chars[0] < 0x7f) {
            self.ui.dispatchKey(kind, .{ .text = ascii[std.ascii.toLower(chars[0])..][0..1], .modifiers = mods });
            return true;
        }
        return false;
    }
};

const step_ = step;

const ascii: [128]u8 = blk: {
    var a: [128]u8 = undefined;
    for (&a, 0..) |*c, i| c.* = i;
    break :blk a;
};

/// zigulee's code for a special key, from its USB HID usage (UIKeyboardHIDUsage).
fn specialKey(usage: isize, mods: input.Modifiers) ?[]const u8 {
    return switch (usage) {
        0x28, 0x58 => Key.@"return",
        0x29 => Key.escape,
        0x2A => Key.backspace,
        0x2B => if (mods.shift) Key.back_tab else Key.tab,
        0x4A => Key.home,
        0x4B => Key.page_up,
        0x4C => Key.delete,
        0x4D => Key.end,
        0x4E => Key.page_down,
        0x4F => Key.right_arrow,
        0x50 => Key.left_arrow,
        0x51 => Key.down_arrow,
        0x52 => Key.up_arrow,
        else => null,
    };
}

fn getClipboard(_: ?*anyopaque, gpa: Allocator) ?[]u8 {
    const board = msg(id, class("UIPasteboard"), "generalPasteboard", .{});
    const s = msg(id, board, "string", .{});
    if (s == null) return null;
    return gpa.dupe(u8, objc.utf8(s)) catch null;
}

fn setClipboard(_: ?*anyopaque, text: []const u8) void {
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    msg(void, msg(id, class("UIPasteboard"), "generalPasteboard", .{}), "setString:", .{nsString(text)});
}

// ---- The classes ----

var view_class: id = null;
var view_offset: isize = 0;
var controller_class: id = null;
var controller_offset: isize = 0;
var app_delegate_class: id = null;
var scene_delegate_class: id = null;

fn ivarWindow(obj: id, offset: isize) ?*Window {
    return @ptrCast(@alignCast(objc.ivarPtr(obj, offset).*));
}

fn addMethods(cls: id, comptime methods: anytype) void {
    inline for (methods) |m| _ = objc.class_addMethod(cls, objc.sel(m[0]), @ptrCast(m[1]), m[2]);
}

/// ZiguleeView: the view the window draws in, receiving touches and text.
fn viewClass() id {
    if (view_class) |c| return c;
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("UIView"), "ZiguleeView", 0);
    _ = objc.class_addIvar(cls, "zigulee_window", @sizeOf(usize), std.math.log2_int(usize, @alignOf(usize)), "^v");
    addMethods(cls, .{
        .{ "layoutSubviews", &View.layout, "v@:" },
        .{ "safeAreaInsetsDidChange", &View.insetsChanged, "v@:" },
        .{ "touchesBegan:withEvent:", &View.touchesBegan, "v@:@@" },
        .{ "touchesMoved:withEvent:", &View.touchesMoved, "v@:@@" },
        .{ "touchesEnded:withEvent:", &View.touchesEnded, "v@:@@" },
        .{ "touchesCancelled:withEvent:", &View.touchesCancelled, "v@:@@" },
        .{ "ziguleeHover:", &View.hover, "v@:@" },
        .{ "ziguleeScroll:", &View.scroll, "v@:@" },
        .{ "pressesBegan:withEvent:", &View.pressesBegan, "v@:@@" },
        .{ "pressesEnded:withEvent:", &View.pressesEnded, "v@:@@" },
        .{ "canBecomeFirstResponder", &yes, "c@:" },
        // UIKeyInput
        .{ "hasText", &yes, "c@:" },
        .{ "insertText:", &View.insertText, "v@:@" },
        .{ "deleteBackward", &View.deleteBackward, "v@:" },
        // UITextInputTraits: text as typed.
        .{ "autocorrectionType", &no_correction, "q@:" },
        .{ "spellCheckingType", &no_correction, "q@:" },
        .{ "smartQuotesType", &no_correction, "q@:" },
        .{ "smartDashesType", &no_correction, "q@:" },
        .{ "smartInsertDeleteType", &no_correction, "q@:" },
        .{ "autocapitalizationType", &View.noCapitals, "q@:" },
        .{ "keyboardAppearance", &View.keyboardAppearance, "q@:" },
        // VoiceOver: the elements in the view.
        .{ "isAccessibilityElement", &noFlag, "c@:" },
        .{ "accessibilityElements", &View.accessibilityElements, "@@:" },
    });
    _ = objc.class_addProtocol(cls, objc.objc_getProtocol("UIKeyInput"));
    objc.objc_registerClassPair(cls);
    view_offset = objc.ivar_getOffset(objc.class_getInstanceVariable(cls, "zigulee_window"));
    view_class = cls;
    return cls;
}

fn yes(_: id, _: SEL) callconv(.c) BOOL {
    return true;
}

fn noFlag(_: id, _: SEL) callconv(.c) BOOL {
    return false;
}

/// UITextAutocorrectionTypeNo (and the same for the other corrections).
fn no_correction(_: id, _: SEL) callconv(.c) isize {
    return 1;
}

const View = struct {
    fn window(self: id) ?*Window {
        return ivarWindow(self, view_offset);
    }

    fn layout(self: id, _: SEL) callconv(.c) void {
        objc.msgSuper(void, self, viewClass(), "layoutSubviews", .{});
        if (window(self)) |w| w.syncSize() catch log.err("could not resize the framebuffer", .{});
    }

    fn insetsChanged(self: id, _: SEL) callconv(.c) void {
        objc.msgSuper(void, self, viewClass(), "safeAreaInsetsDidChange", .{});
        if (window(self)) |w| w.syncInsets();
    }

    fn touchesBegan(self: id, _: SEL, set: id, _: id) callconv(.c) void {
        if (window(self)) |w| w.touches(set, .down);
    }

    fn touchesMoved(self: id, _: SEL, set: id, _: id) callconv(.c) void {
        if (window(self)) |w| w.touches(set, .moved);
    }

    fn touchesEnded(self: id, _: SEL, set: id, _: id) callconv(.c) void {
        if (window(self)) |w| w.touches(set, .up);
    }

    fn touchesCancelled(self: id, _: SEL, set: id, _: id) callconv(.c) void {
        if (window(self)) |w| w.touches(set, .cancelled);
    }

    fn hover(self: id, _: SEL, recognizer: id) callconv(.c) void {
        if (window(self)) |w| w.hovered(recognizer);
    }

    fn scroll(self: id, _: SEL, recognizer: id) callconv(.c) void {
        if (window(self)) |w| w.scrolledBy(recognizer);
    }

    fn pressesBegan(self: id, _: SEL, set: id, event: id) callconv(.c) void {
        if (window(self)) |w| if (w.presses(set, .pressed)) return;
        objc.msgSuper(void, self, viewClass(), "pressesBegan:withEvent:", .{ set, event });
    }

    fn pressesEnded(self: id, _: SEL, set: id, event: id) callconv(.c) void {
        if (window(self)) |w| if (w.presses(set, .released)) return;
        objc.msgSuper(void, self, viewClass(), "pressesEnded:withEvent:", .{ set, event });
    }

    fn insertText(self: id, _: SEL, string: id) callconv(.c) void {
        if (window(self)) |w| w.insertText(string);
    }

    fn deleteBackward(self: id, _: SEL) callconv(.c) void {
        if (window(self)) |w| w.deleteBackward();
    }

    fn noCapitals(_: id, _: SEL) callconv(.c) isize {
        return 0;
    }

    fn keyboardAppearance(self: id, _: SEL) callconv(.c) isize {
        const w = window(self) orelse return 0;
        return if (w.ui.colorScheme() == .dark) 1 else 2;
    }

    fn accessibilityElements(self: id, _: SEL) callconv(.c) id {
        const w = window(self) orelse return null;
        const b = w.a11y orelse return null;
        // Asked before the first update (VoiceOver just started).
        if (b.accessibilityElements() == null) b.update() catch {};
        return b.accessibilityElements();
    }
};

/// ZiguleeViewController: the window's root, with the status bar's look and
/// the hardware keys while no text field has the focus.
fn controllerClass() id {
    if (controller_class) |c| return c;
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("UIViewController"), "ZiguleeViewController", 0);
    _ = objc.class_addIvar(cls, "zigulee_window", @sizeOf(usize), std.math.log2_int(usize, @alignOf(usize)), "^v");
    addMethods(cls, .{
        .{ "canBecomeFirstResponder", &yes, "c@:" },
        .{ "pressesBegan:withEvent:", &Controller.pressesBegan, "v@:@@" },
        .{ "pressesEnded:withEvent:", &Controller.pressesEnded, "v@:@@" },
        .{ "prefersStatusBarHidden", &Controller.fullScreen, "c@:" },
        .{ "prefersHomeIndicatorAutoHidden", &Controller.fullScreen, "c@:" },
        .{ "preferredStatusBarStyle", &Controller.statusBarStyle, "q@:" },
        .{ "ziguleeKeyboard:", &Controller.keyboard, "v@:@" },
    });
    objc.objc_registerClassPair(cls);
    controller_offset = objc.ivar_getOffset(objc.class_getInstanceVariable(cls, "zigulee_window"));
    controller_class = cls;
    return cls;
}

const Controller = struct {
    fn window(self: id) ?*Window {
        return ivarWindow(self, controller_offset);
    }

    fn pressesBegan(self: id, _: SEL, set: id, event: id) callconv(.c) void {
        if (window(self)) |w| if (w.presses(set, .pressed)) return;
        objc.msgSuper(void, self, controllerClass(), "pressesBegan:withEvent:", .{ set, event });
    }

    fn pressesEnded(self: id, _: SEL, set: id, event: id) callconv(.c) void {
        if (window(self)) |w| if (w.presses(set, .released)) return;
        objc.msgSuper(void, self, controllerClass(), "pressesEnded:withEvent:", .{ set, event });
    }

    fn fullScreen(self: id, _: SEL) callconv(.c) BOOL {
        const w = window(self) orelse return false;
        return w.ui.fullscreen.getUntracked();
    }

    /// Dark text on a light window, light on a dark one.
    fn statusBarStyle(self: id, _: SEL) callconv(.c) isize {
        const w = window(self) orelse return 0;
        return if (w.ui.colorScheme() == .dark) 1 else 3;
    }

    fn keyboard(self: id, _: SEL, notification: id) callconv(.c) void {
        const w = window(self) orelse return;
        if (msg(BOOL, msg(id, notification, "name", .{}), "isEqualToString:", .{UIKeyboardWillHideNotification})) return w.keyboardMoved(null);
        const info = msg(id, notification, "userInfo", .{});
        const value = msg(id, info, "objectForKey:", .{UIKeyboardFrameEndUserInfoKey});
        w.keyboardMoved(if (value != null) msg(NSRect, value, "CGRectValue", .{}) else null);
    }
};

/// ZiguleeAppDelegate: runs the app's `main` once launched, and gives the
/// scene its delegate.
fn appDelegateClass() id {
    if (app_delegate_class) |c| return c;
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("UIResponder"), "ZiguleeAppDelegate", 0);
    addMethods(cls, .{
        .{ "application:didFinishLaunchingWithOptions:", &AppDelegate.didFinishLaunching, "c@:@@" },
        .{ "application:configurationForConnectingSceneSession:options:", &AppDelegate.sceneConfiguration, "@@:@@@" },
        .{ "ziguleeMain", &AppDelegate.main, "v@:" },
    });
    _ = objc.class_addProtocol(cls, objc.objc_getProtocol("UIApplicationDelegate"));
    objc.objc_registerClassPair(cls);
    app_delegate_class = cls;
    return cls;
}

const AppDelegate = struct {
    fn didFinishLaunching(self: id, _: SEL, _: id, _: id) callconv(.c) BOOL {
        // The app's main runs once launching is over (its event loop then
        // turns UIKit's).
        msg(void, self, "performSelector:withObject:afterDelay:", .{ objc.sel("ziguleeMain"), @as(id, null), @as(f64, 0) });
        return true;
    }

    fn sceneConfiguration(_: id, _: SEL, _: id, session: id, _: id) callconv(.c) id {
        const config = msg(id, class("UISceneConfiguration"), "configurationWithName:sessionRole:", .{ @as(id, null), msg(id, session, "role", .{}) });
        msg(void, config, "setDelegateClass:", .{sceneDelegateClass()});
        return config;
    }

    fn main(_: id, _: SEL) callconv(.c) void {
        launched = true;
        if (app_main) |run| run();
        std.process.exit(0);
    }
};

/// ZiguleeSceneDelegate: the scene windows go into, and whether the app is
/// in the foreground.
fn sceneDelegateClass() id {
    if (scene_delegate_class) |c| return c;
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("UIResponder"), "ZiguleeSceneDelegate", 0);
    addMethods(cls, .{
        .{ "scene:willConnectToSession:options:", &SceneDelegate.connect, "v@:@@@" },
        .{ "sceneDidDisconnect:", &SceneDelegate.disconnect, "v@:@" },
        .{ "sceneWillEnterForeground:", &SceneDelegate.toForeground, "v@:@" },
        .{ "sceneDidEnterBackground:", &SceneDelegate.toBackground, "v@:@" },
    });
    _ = objc.class_addProtocol(cls, objc.objc_getProtocol("UIWindowSceneDelegate"));
    objc.objc_registerClassPair(cls);
    scene_delegate_class = cls;
    return cls;
}

const SceneDelegate = struct {
    fn connect(_: id, _: SEL, s: id, _: id, _: id) callconv(.c) void {
        if (scene != null) return;
        scene = msg(id, s, "retain", .{});
    }

    fn disconnect(_: id, _: SEL, s: id) callconv(.c) void {
        if (s != scene) return;
        var it = open_windows;
        while (it) |w| : (it = w.next) w.closed = true;
    }

    fn toForeground(_: id, _: SEL, _: id) callconv(.c) void {
        foreground = true;
        var it = open_windows;
        while (it) |w| : (it = w.next) w.full_redraw = true;
    }

    fn toBackground(_: id, _: SEL, _: id) callconv(.c) void {
        foreground = false;
    }
};

test "hardware keys" {
    try std.testing.expectEqualStrings(Key.back_tab, specialKey(0x2B, .{ .shift = true }).?);
    try std.testing.expectEqualStrings(Key.up_arrow, specialKey(0x52, .{}).?);
    try std.testing.expect(specialKey(0x04, .{}) == null); // 'a': text
}
