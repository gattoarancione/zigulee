// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! SDL3 platform backend: shows a `zigulee.Window` in a desktop window on
//! macOS, Windows and Linux, rendering with OpenGL (the GPU renderer) when
//! available, else with the software renderer (`Options.renderer`).
//!
//! The event loop sleeps until there is something to do: an input event,
//! the next timer, or the next frame of a running animation (paced by
//! vsync). With the software renderer, frames redraw only the changed
//! region, and only that region is uploaded to the GPU texture.
//!
//!     try sdl3.init();
//!     defer sdl3.deinit();
//!     const window = try sdl3.Window.create(gpa, &ui_window, .{ .title = "Hello" });
//!     defer window.destroy();
//!     try window.run();
//!
//! The window's accessible items are shown to screen readers on macOS
//! (VoiceOver: src/backends/macos/accessibility.zig), Windows (UI
//! Automation: src/backends/windows/uia.zig) and Linux (AT-SPI:
//! src/backends/linux/atspi.zig). For a native window without SDL,
//! see the zigulee-macos backend.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const c = @import("sdl3_c");
const webkitgtk = switch (builtin.os.tag) {
    .linux => @import("zigulee-webkitgtk"),
    else => struct {},
};
const core = zigulee.core;
const dnd = core.dnd;
const gestures = core.gestures;
const Rgba8 = core.Rgba8;
const input = core.input;
const Key = input.Key;

const log = std.log.scoped(.zigulee_sdl3);

/// Screen reader support: VoiceOver (macOS), UI Automation (Windows) and
/// AT-SPI (Linux).
const a11y_bridge = switch (builtin.os.tag) {
    .macos => @import("zigulee-macos").accessibility,
    .windows => @import("zigulee-uia"),
    .linux => @import("zigulee-atspi"),
    else => struct {
        pub const Bridge = void;
    },
};
const has_a11y = switch (builtin.os.tag) {
    .macos, .windows, .linux => true,
    else => false,
};

/// AT-SPI messages wake the event loop with an event of this type.
var atspi_event: u32 = 0;

fn atspiWake() void {
    var e: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    e.type = atspi_event;
    _ = c.SDL_PushEvent(&e);
}

/// Dark title bars on Windows (10 and later).
const dwm = if (builtin.os.tag == .windows) struct {
    extern "dwmapi" fn DwmSetWindowAttribute(hwnd: ?*anyopaque, attribute: u32, value: *const anyopaque, size: u32) callconv(.winapi) i32;
    const use_immersive_dark_mode = 20;
} else struct {};

/// The Direct3D 12 renderer (Windows only).
const D3d12Renderer = if (builtin.os.tag == .windows) @import("zigulee-d3d12").Renderer else void;

/// The Metal renderer (macOS only).
const MetalRenderer = if (builtin.os.tag == .macos) @import("zigulee-macos").metal.Renderer else void;

pub const Error = error{ SdlError, OpenGlFailed } || Allocator.Error;

fn sdlError(what: []const u8) error{SdlError} {
    log.err("{s} failed: {s}", .{ what, std.mem.span(c.SDL_GetError()) });
    return error.SdlError;
}

/// Sound: the mixer plays through SDL (from `init` to `deinit`).
pub const audio = @import("audio.zig");
/// File dialogs: SDL's (the platform's own).
pub const file_dialogs = @import("dialogs.zig");
/// Tray icons through SDL (on Linux).
pub const tray_icons = @import("tray.zig");
var audio_output: audio.Output = .{};
/// The microphone and the camera through SDL.
pub const capture = @import("capture.zig");
var microphone: capture.Microphone = .{};
var camera_device: capture.Camera = .{};

/// `open-url`: SDL hands the link to the system.
fn openUrl(_: ?*anyopaque, url: []const u8) bool {
    const z = std.heap.c_allocator.dupeZ(u8, url) catch return false;
    defer std.heap.c_allocator.free(z);
    return c.SDL_OpenURL(z.ptr);
}

/// Initializes SDL's video subsystem, and makes SDL the mixer's audio
/// output (the device opens when something plays). Call once, before
/// creating windows.
pub fn init() Error!void {
    // Fingers come as touches (the first one works as the mouse in the
    // core): not also as mouse events.
    _ = c.SDL_SetHint(c.SDL_HINT_TOUCH_MOUSE_EVENTS, "0");
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return sdlError("SDL_Init");
    core.audio.mixer().setOutput(audio_output.output());
    core.dialogs.setFileDialogs(file_dialogs.provider);
    core.audio.setInput(microphone.input());
    core.links.setOpener(.{ .open = openUrl });
    if (builtin.os.tag == .macos) core.webview.setProvider(@import("zigulee-macos").webview.provider);
    if (builtin.os.tag == .windows) core.webview.setProvider(@import("zigulee-windows").webview.provider);
    // On X11 only (`native_view` is null on Wayland).
    if (builtin.os.tag == .linux) core.webview.setProvider(webkitgtk.provider);
    core.camera.setProvider(camera_device.provider());
    // Video: SDL decodes none; on macOS, AVFoundation does.
    if (builtin.os.tag == .macos) core.video.addDecoder(@import("zigulee-macos").avfoundation.decoder);
    // The menus in the menu bar at the top of the screen.
    if (builtin.os.tag == .macos) core.menus.setMenuBar(@import("zigulee-macos").menubar.provider);
    // Tray icons and notifications.
    core.tray.setProvider(switch (builtin.os.tag) {
        .macos => @import("zigulee-macos").tray.provider,
        .windows => @import("zigulee-windows").tray.provider,
        .linux => .{
            .show = tray_icons.icons.show,
            .remove = tray_icons.icons.remove,
            .notify = @import("zigulee-atspi").notifications.provider.notify,
            .poll = @import("zigulee-atspi").notifications.provider.poll,
        },
        else => tray_icons.icons,
    });
    // Redraws while macOS resizes a window (its event loop is blocked).
    _ = c.SDL_AddEventWatch(eventWatch, null);
}

pub fn deinit() void {
    core.audio.mixer().setOutput(null);
    core.dialogs.setFileDialogs(null);
    core.audio.setInput(null);
    core.links.setOpener(null);
    core.webview.setProvider(null);
    core.camera.setProvider(null);
    if (builtin.os.tag == .macos) core.video.removeDecoder("avfoundation");
    if (builtin.os.tag == .macos) core.menus.setMenuBar(null);
    core.tray.setProvider(null);
    if (builtin.os.tag == .windows) @import("zigulee-windows").tray.removeAll();
    c.SDL_RemoveEventWatch(eventWatch, null);
    for (&cursors) |*cur| if (cur.*) |p| {
        c.SDL_DestroyCursor(p);
        cur.* = null;
    };
    c.SDL_Quit();
}

/// The open windows (each event goes to its own).
var open_windows: ?*Window = null;

fn windowFor(id: c.SDL_WindowID) ?*Window {
    var it = open_windows;
    while (it) |w| : (it = w.next) if (c.SDL_GetWindowID(w.handle) == id) return w;
    return null;
}

/// The window an event is for, if any.
fn eventWindowId(e: *const c.SDL_Event) ?c.SDL_WindowID {
    return switch (e.type) {
        c.SDL_EVENT_WINDOW_FIRST...c.SDL_EVENT_WINDOW_LAST => e.window.windowID,
        c.SDL_EVENT_MOUSE_MOTION => e.motion.windowID,
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => e.button.windowID,
        c.SDL_EVENT_MOUSE_WHEEL => e.wheel.windowID,
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => e.key.windowID,
        c.SDL_EVENT_TEXT_INPUT => e.text.windowID,
        c.SDL_EVENT_TEXT_EDITING => e.edit.windowID,
        c.SDL_EVENT_DROP_BEGIN, c.SDL_EVENT_DROP_FILE, c.SDL_EVENT_DROP_TEXT, c.SDL_EVENT_DROP_POSITION, c.SDL_EVENT_DROP_COMPLETE => e.drop.windowID,
        c.SDL_EVENT_FINGER_DOWN, c.SDL_EVENT_FINGER_MOTION, c.SDL_EVENT_FINGER_UP, c.SDL_EVENT_FINGER_CANCELED => e.tfinger.windowID,
        c.SDL_EVENT_PINCH_BEGIN, c.SDL_EVENT_PINCH_UPDATE, c.SDL_EVENT_PINCH_END => e.pinch.windowID,
        else => null,
    };
}

/// Sends an event to the window it is for (quitting closes them all).
pub fn dispatchEvent(e: *const c.SDL_Event) void {
    if (e.type == c.SDL_EVENT_QUIT) {
        var it = open_windows;
        while (it) |w| : (it = w.next) w.closed = true;
        return;
    }
    const w = windowFor(eventWindowId(e) orelse return) orelse return;
    w.handleEvent(e);
}

const step_ = step;

/// One iteration of the event loop for every open window: waits for
/// something to do (at most `max_wait_ms`, if given), dispatches events,
/// fires timers, runs change handlers and renders what changed.
pub fn step(max_wait_ms: ?u32) Error!void {
    core.updateTimersAndAnimations(now());
    var timeout: i32 = -1; // nothing to do: wait for an event
    var idle = true;
    var needs_frame = false;
    var it = open_windows;
    while (it) |w| : (it = w.next) if (w.needsFrame()) {
        needs_frame = true;
        idle = idle and w.idle_frame;
    };
    if (needs_frame) {
        timeout = if (idle) 16 else 0;
    } else if (core.nextTimerDeadline()) |deadline| {
        timeout = @intCast(@min(deadline -| now(), std.math.maxInt(i32)));
    }
    if (max_wait_ms) |m| timeout = if (timeout < 0) @intCast(@min(m, std.math.maxInt(i32))) else @min(timeout, @as(i32, @intCast(@min(m, std.math.maxInt(i32)))));

    // GLib's loop (web views on Linux) runs every 10 ms: SDL cannot wait
    // for it.
    if (builtin.os.tag == .linux and webkitgtk.active()) timeout = if (timeout < 0) 10 else @min(timeout, 10);

    var event: c.SDL_Event = undefined;
    if (timeout != 0 and c.SDL_WaitEventTimeout(&event, timeout)) dispatchEvent(&event);
    while (c.SDL_PollEvent(&event)) dispatchEvent(&event);
    if (builtin.os.tag == .linux) webkitgtk.iterate();

    core.updateTimersAndAnimations(now());
    core.runChangeHandlers();
    it = open_windows;
    while (it) |w| : (it = w.next) try w.afterEvents();
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

fn eventWatch(_: ?*anyopaque, e: [*c]c.SDL_Event) callconv(.c) bool {
    // SDL sends this (data1 = 1) about 60 times a second during a live
    // resize: draw now, the normal loop only resumes when it ends.
    if (e.*.type == c.SDL_EVENT_WINDOW_EXPOSED and e.*.window.data1 == 1) {
        if (windowFor(e.*.window.windowID)) |w| w.liveResizeFrame() catch |err| log.err("redrawing during a resize failed: {t}", .{err});
    }
    return true;
}

/// SDL's system cursors, made when first shown.
var cursors: [c.SDL_SYSTEM_CURSOR_COUNT]?*c.SDL_Cursor = @splat(null);

fn systemCursor(cursor: input.MouseCursor) c.SDL_SystemCursor {
    return switch (cursor) {
        .default, .none, .help => c.SDL_SYSTEM_CURSOR_DEFAULT,
        .pointer => c.SDL_SYSTEM_CURSOR_POINTER,
        .progress => c.SDL_SYSTEM_CURSOR_PROGRESS,
        .wait => c.SDL_SYSTEM_CURSOR_WAIT,
        .crosshair => c.SDL_SYSTEM_CURSOR_CROSSHAIR,
        .text => c.SDL_SYSTEM_CURSOR_TEXT,
        .move, .grab, .grabbing => c.SDL_SYSTEM_CURSOR_MOVE,
        .not_allowed => c.SDL_SYSTEM_CURSOR_NOT_ALLOWED,
        .col_resize, .ew_resize => c.SDL_SYSTEM_CURSOR_EW_RESIZE,
        .row_resize, .ns_resize => c.SDL_SYSTEM_CURSOR_NS_RESIZE,
        .nesw_resize => c.SDL_SYSTEM_CURSOR_NESW_RESIZE,
        .nwse_resize => c.SDL_SYSTEM_CURSOR_NWSE_RESIZE,
    };
}

/// Milliseconds since `init`, the clock zigulee's timers and animations run on.
pub fn now() u64 {
    return c.SDL_GetTicks();
}

pub const Options = struct {
    title: [:0]const u8 = "zigulee",
    resizable: bool = true,
    renderer: RendererKind = .auto,
    /// Not shown (for tests, or to show later with `SDL_ShowWindow`).
    hidden: bool = false,
};

pub const RendererKind = enum {
    /// Metal (macOS), else OpenGL if the system has it, else software.
    auto,
    /// The GPU renderer on Metal (macOS only): the window fails to open
    /// without it.
    metal,
    /// The GPU renderer on Vulkan (the system's Vulkan library, or MoltenVK
    /// on macOS, loaded at run time): the window fails to open without it.
    vulkan,
    /// The GPU renderer on Direct3D 12 (Windows only): the window fails to
    /// open without it.
    d3d12,
    /// The GPU renderer, with OpenGL 3.3 (or OpenGL ES 3.0): the window
    /// fails to open without it.
    opengl,
    /// The software renderer: what changed is redrawn on the CPU and
    /// uploaded to a texture.
    software,
};

pub const Window = struct {
    gpa: Allocator,
    ui: *core.Window,
    handle: *c.SDL_Window,
    /// The window as web views see it on Linux (`native_view`, on X11).
    web_host: if (builtin.os.tag == .linux) webkitgtk.Host else void = if (builtin.os.tag == .linux) .{} else {},
    /// With the software renderer: SDL's renderer, to show the framebuffer.
    renderer: ?*c.SDL_Renderer = null,
    texture: ?*c.SDL_Texture = null,
    /// With OpenGL: the context and the GPU renderer.
    gl_context: c.SDL_GLContext = null,
    /// With Metal (macOS): SDL's Metal view, its layer and the renderer.
    metal_view: c.SDL_MetalView = null,
    metal_layer: ?*anyopaque = null,
    metal: ?*MetalRenderer = null,
    /// With Vulkan.
    vulkan: ?*zigulee.gpu.vulkan.Renderer = null,
    /// With Direct3D 12 (Windows).
    d3d12: ?*D3d12Renderer = null,
    gpu: ?*zigulee.gpu.gl.Renderer = null,
    /// The framebuffer, in physical pixels; kept between frames so only
    /// changed areas are redrawn.
    framebuffer: []Rgba8 = &.{},
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,
    software: zigulee.software.Renderer(Rgba8),
    full_redraw: bool = true,
    /// Set when the user closes the window; `run` returns.
    closed: bool = false,
    /// A drop from another application, gathered until it completes:
    /// its kind, its data (files: one path per line), where.
    drop_kind: []const u8 = "",
    drop_data: std.ArrayList(u8) = .empty,
    drop_at: core.Point = .{},
    /// A frame was drawn but nothing changed while animations run (e.g.
    /// off-screen): pace the loop instead of spinning.
    idle_frame: bool = false,
    /// The accessibility bridge (macOS, with a Cocoa window; Windows).
    a11y: ?*a11y_bridge.Bridge = null,
    /// The color scheme the window's frame shows.
    scheme: ?core.ColorScheme = null,
    /// Fullscreen, maximized and the like, as asked and as shown.
    state: core.WindowStateSync = .{},
    /// The cursor shown over the window.
    cursor: input.MouseCursor = .default,
    /// In the list of open windows.
    next: ?*Window = null,

    /// Opens a window showing `ui`, sized to `ui.size()` in logical pixels.
    /// `ui` must outlive the window.
    pub fn create(gpa: Allocator, ui: *core.Window, options: Options) Error!*Window {
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .ui = ui, .handle = undefined, .software = .init(gpa) };
        errdefer self.software.deinit();
        const opened = switch (options.renderer) {
            .software => false,
            .metal => blk: {
                self.openMetal(options) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => sdlError("opening a Metal window"),
                };
                break :blk true;
            },
            .vulkan => blk: {
                self.openVulkan(options) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => sdlError("opening a Vulkan window"),
                };
                break :blk true;
            },
            .d3d12 => blk: {
                self.openD3d12(options) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => sdlError("opening a Direct3D 12 window"),
                };
                break :blk true;
            },
            .opengl => blk: {
                self.openGl(options) catch |err| return switch (err) {
                    error.SdlError => sdlError("opening an OpenGL window"),
                    error.OutOfMemory, error.OpenGlFailed => |e| e,
                    error.MissingGlFunction, error.ShaderFailed => error.OpenGlFailed,
                };
                break :blk true;
            },
            .auto => blk: {
                if (builtin.os.tag == .macos) {
                    if (self.openMetal(options)) break :blk true else |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => log.info("Metal unavailable: trying OpenGL", .{}),
                    }
                }
                self.openGl(options) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        log.info("OpenGL unavailable: using the software renderer", .{});
                        break :blk false;
                    },
                };
                break :blk true;
            },
        };
        if (!opened) {
            self.handle = self.openWindow(options, 0) orelse return sdlError("SDL_CreateWindow");
            errdefer c.SDL_DestroyWindow(self.handle);
            const renderer = c.SDL_CreateRenderer(self.handle, null) orelse return sdlError("SDL_CreateRenderer");
            self.renderer = renderer;
            _ = c.SDL_SetRenderVSync(renderer, 1);
        }
        errdefer self.closeRendering();
        try self.syncSize();
        _ = c.SDL_StartTextInput(self.handle);
        ui.clipboard = .{ .ctx = null, .getFn = getClipboard, .setFn = setClipboard };
        ui.native_view = self.nativeView();
        try self.startAccessibility();
        self.next = open_windows;
        open_windows = self;
        return self;
    }

    /// A window the size of the UI.
    fn openWindow(self: *const Window, options: Options, extra: c.SDL_WindowFlags) ?*c.SDL_Window {
        var flags: c.SDL_WindowFlags = c.SDL_WINDOW_HIGH_PIXEL_DENSITY | extra;
        if (options.resizable) flags |= c.SDL_WINDOW_RESIZABLE;
        if (options.hidden) flags |= c.SDL_WINDOW_HIDDEN;
        const size = self.ui.size();
        return c.SDL_CreateWindow(options.title.ptr, @intFromFloat(@round(size.width)), @intFromFloat(@round(size.height)), flags);
    }

    /// OpenGL could not be used (with `.auto`, not an error).
    fn glUnavailable(what: []const u8) error{SdlError} {
        log.info("{s} failed: {s}", .{ what, std.mem.span(c.SDL_GetError()) });
        return error.SdlError;
    }

    /// An OpenGL window, context and renderer; nothing is left open on
    /// failure.
    fn openGl(self: *Window, options: Options) (Error || zigulee.gpu.gl.Error)!void {
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 3);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_FLAGS, c.SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_DOUBLEBUFFER, 1);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_ALPHA_SIZE, 8);
        const handle = self.openWindow(options, c.SDL_WINDOW_OPENGL) orelse return glUnavailable("SDL_CreateWindow (OpenGL)");
        errdefer c.SDL_DestroyWindow(handle);
        setSrgb(handle);
        const context = c.SDL_GL_CreateContext(handle) orelse return glUnavailable("SDL_GL_CreateContext");
        errdefer _ = c.SDL_GL_DestroyContext(context);
        if (!c.SDL_GL_MakeCurrent(handle, context)) return glUnavailable("SDL_GL_MakeCurrent");
        _ = c.SDL_GL_SetSwapInterval(1);
        const functions = try zigulee.gpu.gl.Functions.load({}, struct {
            fn f(_: void, name: [*:0]const u8) ?*const anyopaque {
                return @ptrCast(c.SDL_GL_GetProcAddress(name));
            }
        }.f);
        const gpu = try self.gpa.create(zigulee.gpu.gl.Renderer);
        errdefer self.gpa.destroy(gpu);
        gpu.* = try .init(self.gpa, functions);
        self.handle = handle;
        self.gl_context = context;
        self.gpu = gpu;
    }

    /// Closes the renderer and the window.
    /// A window with a CAMetalLayer, drawn into by the Metal renderer.
    fn openMetal(self: *Window, options: Options) (Error || error{ MetalUnavailable, ShaderFailed })!void {
        if (builtin.os.tag != .macos) return error.MetalUnavailable;
        const objc = @import("zigulee-macos").objc;
        const renderer = try self.gpa.create(MetalRenderer);
        errdefer self.gpa.destroy(renderer);
        renderer.* = try .init(self.gpa);
        errdefer renderer.deinit();
        const handle = self.openWindow(options, c.SDL_WINDOW_METAL) orelse return glUnavailable("SDL_CreateWindow (Metal)");
        errdefer c.SDL_DestroyWindow(handle);
        const view = c.SDL_Metal_CreateView(handle) orelse return glUnavailable("SDL_Metal_CreateView");
        const layer = c.SDL_Metal_GetLayer(view);
        objc.msg(void, layer, "setDevice:", .{renderer.device});
        objc.msg(void, layer, "setPixelFormat:", .{@as(usize, 80)}); // BGRA8Unorm
        objc.msg(void, layer, "setFramebufferOnly:", .{false});
        setSrgb(handle);
        self.handle = handle;
        self.metal_view = view;
        self.metal_layer = layer;
        self.metal = renderer;
    }

    /// A window drawn with Vulkan, through a surface made from its native
    /// handles.
    fn openVulkan(self: *Window, options: Options) (Error || zigulee.gpu.vulkan.Error)!void {
        const flags: c.SDL_WindowFlags = if (builtin.os.tag == .macos) c.SDL_WINDOW_METAL else 0;
        const handle = self.openWindow(options, flags) orelse return glUnavailable("SDL_CreateWindow (Vulkan)");
        errdefer c.SDL_DestroyWindow(handle);
        const props = c.SDL_GetWindowProperties(handle);
        var view: c.SDL_MetalView = null;
        errdefer if (view != null) c.SDL_Metal_DestroyView(view);
        const surface: zigulee.gpu.vulkan.Surface = switch (builtin.os.tag) {
            .macos => blk: {
                view = c.SDL_Metal_CreateView(handle) orelse return glUnavailable("SDL_Metal_CreateView");
                setSrgb(handle);
                break :blk .{ .metal = c.SDL_Metal_GetLayer(view) };
            },
            .windows => .{ .win32 = .{
                .hinstance = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WIN32_INSTANCE_POINTER, null),
                .hwnd = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null),
            } },
            else => if (c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null)) |wl_surface| .{ .wayland = .{
                .display = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null),
                .surface = wl_surface,
            } } else .{ .xlib = .{
                .display = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null),
                .window = @intCast(c.SDL_GetNumberProperty(props, c.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0)),
            } },
        };
        const renderer = try self.gpa.create(zigulee.gpu.vulkan.Renderer);
        errdefer self.gpa.destroy(renderer);
        renderer.* = try .init(self.gpa, surface);
        self.handle = handle;
        self.metal_view = view;
        self.vulkan = renderer;
    }

    /// A window drawn with Direct3D 12 (Windows).
    fn openD3d12(self: *Window, options: Options) (Error || error{ D3d12Unavailable, D3d12Failed, ShaderFailed })!void {
        if (builtin.os.tag != .windows) return error.D3d12Unavailable;
        const handle = self.openWindow(options, 0) orelse return glUnavailable("SDL_CreateWindow (Direct3D 12)");
        errdefer c.SDL_DestroyWindow(handle);
        const hwnd = c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(handle), c.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null);
        const renderer = try self.gpa.create(D3d12Renderer);
        errdefer self.gpa.destroy(renderer);
        renderer.* = try .init(self.gpa, @ptrCast(@alignCast(hwnd)));
        self.handle = handle;
        self.d3d12 = renderer;
    }

    /// Where web views go: the window's content view on macOS, its HWND on
    /// Windows; null elsewhere.
    fn nativeView(self: *Window) ?*anyopaque {
        if (builtin.os.tag == .windows) return c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(self.handle), c.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null);
        if (builtin.os.tag == .linux) {
            const xid = c.SDL_GetNumberProperty(c.SDL_GetWindowProperties(self.handle), c.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
            if (xid == 0) return null; // Wayland
            self.web_host = .{ .window = @intCast(xid), .scale = self.software.scale_factor };
            return &self.web_host;
        }
        if (builtin.os.tag != .macos) return null;
        const objc = @import("zigulee-macos").objc;
        const ns_window = c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(self.handle), c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) orelse return null;
        return objc.msg(objc.id, ns_window, "contentView", .{});
    }

    /// macOS: the window's colors are sRGB (converted for wide-gamut
    /// displays), as with the software renderer.
    fn setSrgb(handle: *c.SDL_Window) void {
        if (builtin.os.tag != .macos) return;
        const objc = @import("zigulee-macos").objc;
        const ns_window = c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(handle), c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) orelse return;
        objc.msg(void, ns_window, "setColorSpace:", .{objc.msg(objc.id, objc.class("NSColorSpace"), "sRGBColorSpace", .{})});
    }

    fn closeRendering(self: *Window) void {
        if (builtin.os.tag == .windows) if (self.d3d12) |d| {
            d.deinit();
            self.gpa.destroy(d);
            self.d3d12 = null;
        };
        if (self.vulkan) |v| {
            v.deinit();
            self.gpa.destroy(v);
            self.vulkan = null;
            if (builtin.os.tag == .macos) c.SDL_Metal_DestroyView(self.metal_view);
        }
        if (builtin.os.tag == .macos) if (self.metal) |m| {
            m.deinit();
            self.gpa.destroy(m);
            self.metal = null;
            c.SDL_Metal_DestroyView(self.metal_view);
        };
        if (self.gpu) |gpu| {
            _ = c.SDL_GL_MakeCurrent(self.handle, self.gl_context);
            gpu.deinit();
            self.gpa.destroy(gpu);
            _ = c.SDL_GL_DestroyContext(self.gl_context);
            self.gpu = null;
        }
        if (self.texture) |t| c.SDL_DestroyTexture(t);
        self.texture = null;
        if (self.renderer) |r| c.SDL_DestroyRenderer(r);
        self.renderer = null;
        c.SDL_DestroyWindow(self.handle);
    }

    fn startAccessibility(self: *Window) Allocator.Error!void {
        const props = c.SDL_GetWindowProperties(self.handle);
        switch (builtin.os.tag) {
            .macos => {
                const ns_window = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) orelse return;
                self.a11y = try a11y_bridge.Bridge.create(self.gpa, self.ui, ns_window);
            },
            .windows => {
                const hwnd = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null) orelse return;
                self.a11y = try a11y_bridge.Bridge.create(self.gpa, self.ui, @ptrCast(@alignCast(hwnd)));
            },
            .linux => {
                // Not for windows nobody sees (tests).
                const driver = std.mem.span(c.SDL_GetCurrentVideoDriver() orelse return);
                if (std.mem.eql(u8, driver, "dummy") or std.mem.eql(u8, driver, "offscreen")) return;
                if (atspi_event == 0) atspi_event = c.SDL_RegisterEvents(1);
                if (atspi_event != 0) a11y_bridge.wake = atspiWake;
                self.a11y = a11y_bridge.Bridge.create(self.gpa, self.ui, .{}) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    else => {
                        log.info("no screen reader support (AT-SPI: {t})", .{err});
                        return;
                    },
                };
            },
            else => {},
        }
    }

    fn stopAccessibility(self: *Window) void {
        if (!has_a11y) return;
        if (self.a11y) |b| b.destroy();
        self.a11y = null;
    }

    pub fn destroy(self: *Window) void {
        var link = &open_windows;
        while (link.*) |w| : (link = &w.next) if (w == self) {
            link.* = self.next;
            break;
        };
        self.stopAccessibility();
        self.ui.clipboard = null;
        self.ui.native_view = null;
        if (builtin.os.tag == .linux) webkitgtk.detach(&self.web_host);
        _ = c.SDL_StopTextInput(self.handle);
        self.closeRendering();
        self.software.deinit();
        self.drop_data.deinit(self.gpa);
        self.gpa.free(self.framebuffer);
        self.gpa.destroy(self);
    }

    /// Shows another zigulee window in this one (live reloading), sized to
    /// the current window. `ui` must outlive the window or the next call.
    pub fn setUi(self: *Window, ui: *core.Window) Error!void {
        self.ui.clipboard = null;
        self.ui.native_view = null;
        self.stopAccessibility();
        self.ui = ui;
        ui.clipboard = .{ .ctx = null, .getFn = getClipboard, .setFn = setClipboard };
        ui.native_view = self.nativeView();
        try self.startAccessibility();
        try self.syncSize();
        self.full_redraw = true;
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        _ = c.SDL_SetWindowTitle(self.handle, title.ptr);
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

    /// After a round of events: the input method, the cursor, a frame if
    /// anything changed, and what assistive technology sees.
    fn afterEvents(self: *Window) Error!void {
        if (self.ui.ime_cursor_rect_changed) self.updateTextInputArea();
        self.updateCursor();
        if (self.needsFrame()) try self.render();
        self.updateScheme();
        self.updateState();
        if (has_a11y) if (self.a11y) |b| {
            if (builtin.os.tag == .windows) b.scale = self.software.scale_factor;
            if (builtin.os.tag == .linux) {
                b.scale = self.software.scale_factor;
                b.title = std.mem.span(c.SDL_GetWindowTitle(self.handle));
                var x: c_int = 0;
                var y: c_int = 0;
                _ = c.SDL_GetWindowPosition(self.handle, &x, &y);
                b.position = .{ x, y };
                b.setActive(c.SDL_GetWindowFlags(self.handle) & c.SDL_WINDOW_INPUT_FOCUS != 0);
            }
            // Only running out of memory stops the loop.
            b.update() catch |err| if (err == error.OutOfMemory) return error.OutOfMemory;
        };
    }

    /// The window put in the state the app asks for, if that changed.
    fn updateState(self: *Window) void {
        const before = self.state.shown;
        const want = self.state.sync(self.ui) orelse return;
        var ok = true;
        if (want.fullscreen != before.fullscreen) ok = c.SDL_SetWindowFullscreen(self.handle, want.fullscreen) and ok;
        if (want.minimized and !before.minimized) {
            ok = c.SDL_MinimizeWindow(self.handle) and ok;
        } else if (want.maximized and (!before.maximized or before.minimized)) {
            ok = c.SDL_MaximizeWindow(self.handle) and ok;
        } else if ((before.maximized and !want.maximized) or (before.minimized and !want.minimized)) {
            ok = c.SDL_RestoreWindow(self.handle) and ok;
        }
        if (want.always_on_top != before.always_on_top) ok = c.SDL_SetWindowAlwaysOnTop(self.handle, want.always_on_top) and ok;
        // What the system cannot do (here), the app is not told it did.
        if (!ok) self.reportState();
    }

    /// The state the window is in (after the user or the system changed
    /// it), told to the app.
    fn reportState(self: *Window) void {
        const flags = c.SDL_GetWindowFlags(self.handle);
        self.state.report(self.ui, .{
            .fullscreen = flags & c.SDL_WINDOW_FULLSCREEN != 0,
            .maximized = flags & c.SDL_WINDOW_MAXIMIZED != 0,
            .minimized = flags & c.SDL_WINDOW_MINIMIZED != 0,
            .always_on_top = flags & c.SDL_WINDOW_ALWAYS_ON_TOP != 0,
        });
    }

    /// The title bar light or dark, as the window's content (macOS and
    /// Windows).
    fn updateScheme(self: *Window) void {
        const scheme = self.ui.colorScheme();
        if (self.scheme == scheme) return;
        self.scheme = scheme;
        const props = c.SDL_GetWindowProperties(self.handle);
        switch (builtin.os.tag) {
            .macos => if (c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null)) |ns_window| {
                @import("zigulee-macos").cocoa.setAppearance(ns_window, scheme);
            },
            .windows => if (c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null)) |hwnd| {
                const dark: i32 = @intFromBool(scheme == .dark);
                _ = dwm.DwmSetWindowAttribute(hwnd, dwm.use_immersive_dark_mode, &dark, @sizeOf(i32));
            },
            else => {},
        }
    }

    /// Shows the cursor the window asks for, while the pointer is over it.
    fn updateCursor(self: *Window) void {
        if (c.SDL_GetMouseFocus() != self.handle) return;
        const want = self.ui.mouseCursor();
        if (want == self.cursor) return;
        self.cursor = want;
        if (want == .none) {
            _ = c.SDL_HideCursor();
            return;
        }
        const index: usize = @intCast(systemCursor(want));
        if (cursors[index] == null) cursors[index] = c.SDL_CreateSystemCursor(systemCursor(want));
        if (cursors[index]) |cur| _ = c.SDL_SetCursor(cur);
        _ = c.SDL_ShowCursor();
    }

    /// A frame drawn while the window is being resized.
    fn liveResizeFrame(self: *Window) Error!void {
        try self.syncSize();
        core.updateTimersAndAnimations(now());
        core.runChangeHandlers();
        try self.render();
    }

    /// Tells the input method where the caret is, for its candidate window.
    fn updateTextInputArea(self: *Window) void {
        self.ui.ime_cursor_rect_changed = false;
        const r = self.ui.ime_cursor_rect orelse return;
        const rect: c.SDL_Rect = .{ .x = @intFromFloat(@round(r.x)), .y = @intFromFloat(@round(r.y)), .w = @intFromFloat(@max(1, @round(r.width))), .h = @intFromFloat(@round(r.height)) };
        _ = c.SDL_SetTextInputArea(self.handle, &rect, 0);
    }

    fn needsFrame(self: *const Window) bool {
        return self.full_redraw or self.ui.redraw_requested or core.hasActiveAnimations();
    }

    /// Follows the window's logical size and pixel density.
    fn syncSize(self: *Window) Error!void {
        var w: c_int = 0;
        var h: c_int = 0;
        var pw: c_int = 0;
        var ph: c_int = 0;
        if (!c.SDL_GetWindowSize(self.handle, &w, &h)) return sdlError("SDL_GetWindowSize");
        if (!c.SDL_GetWindowSizeInPixels(self.handle, &pw, &ph)) return sdlError("SDL_GetWindowSizeInPixels");
        self.ui.setSize(.{ .width = @floatFromInt(w), .height = @floatFromInt(h) });
        self.software.scale_factor = if (w > 0) @as(f32, @floatFromInt(pw)) / @as(f32, @floatFromInt(w)) else 1;
        if (builtin.os.tag == .linux) self.web_host.scale = self.software.scale_factor;
        self.full_redraw = true;

        const width: u32 = @intCast(@max(pw, 1));
        const height: u32 = @intCast(@max(ph, 1));
        if (builtin.os.tag == .macos) if (self.metal_layer) |layer| {
            const objc = @import("zigulee-macos").objc;
            objc.msg(void, layer, "setDrawableSize:", .{objc.NSSize{ .width = @floatFromInt(width), .height = @floatFromInt(height) }});
        };
        if (self.gpu != null or self.metal_layer != null or self.vulkan != null or (builtin.os.tag == .windows and self.d3d12 != null)) {
            self.pixel_width = width;
            self.pixel_height = height;
            return;
        }
        if (width == self.pixel_width and height == self.pixel_height and self.texture != null) return;
        const framebuffer = try self.gpa.alloc(Rgba8, @as(usize, width) * height);
        self.gpa.free(self.framebuffer);
        self.framebuffer = framebuffer;
        if (self.texture) |t| c.SDL_DestroyTexture(t);
        self.texture = c.SDL_CreateTexture(self.renderer.?, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STREAMING, @intCast(width), @intCast(height)) orelse
            return sdlError("SDL_CreateTexture");
        _ = c.SDL_SetTextureBlendMode(self.texture, c.SDL_BLENDMODE_NONE);
        self.pixel_width = width;
        self.pixel_height = height;
    }

    /// Renders what changed, uploads it and presents the frame (with
    /// OpenGL: renders and presents the whole frame).
    pub fn render(self: *Window) Error!void {
        if (builtin.os.tag == .windows) if (self.d3d12) |d| {
            d.setScaleFactor(self.software.scale_factor);
            const region = d.renderWindow(self.ui, self.pixel_width, self.pixel_height, if (self.full_redraw) .full else .partial) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return sdlError("drawing with Direct3D 12"),
            };
            self.full_redraw = false;
            self.idle_frame = region.isEmpty();
            return;
        };
        if (self.vulkan) |v| {
            v.setScaleFactor(self.software.scale_factor);
            const region = v.renderWindow(self.ui, self.pixel_width, self.pixel_height, if (self.full_redraw) .full else .partial) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return sdlError("drawing with Vulkan"),
            };
            self.full_redraw = false;
            self.idle_frame = region.isEmpty();
            return;
        }
        if (builtin.os.tag == .macos) if (self.metal) |m| {
            m.setScaleFactor(self.software.scale_factor);
            const region = try m.renderWindow(self.ui, self.pixel_width, self.pixel_height, if (self.full_redraw) .full else .partial, self.metal_layer);
            self.full_redraw = false;
            self.idle_frame = region.isEmpty();
            return;
        };
        if (self.gpu) |gpu| {
            if (!c.SDL_GL_MakeCurrent(self.handle, self.gl_context)) return sdlError("SDL_GL_MakeCurrent");
            gpu.setScaleFactor(self.software.scale_factor);
            const region = try gpu.renderWindow(self.ui, self.pixel_width, self.pixel_height, if (self.full_redraw) .full else .partial);
            self.full_redraw = false;
            // Nothing changed (an animation off-screen, say): no frame.
            self.idle_frame = region.isEmpty();
            if (region.isEmpty()) return;
            if (!c.SDL_GL_SwapWindow(self.handle)) return sdlError("SDL_GL_SwapWindow");
            return;
        }
        const canvas: zigulee.software.Canvas(Rgba8) = .init(self.framebuffer, self.pixel_width, self.pixel_height);
        const region = try self.software.renderWindow(self.ui, canvas, if (self.full_redraw) .full else .partial);
        self.full_redraw = false;
        self.idle_frame = region.isEmpty();
        if (region.isEmpty()) return;

        const texture = self.texture.?;
        const bounds: core.Rect = .{ .width = @floatFromInt(self.pixel_width), .height = @floatFromInt(self.pixel_height) };
        for (region.slice()) |dirty| {
            const r = dirty.intersection(bounds);
            if (r.isEmpty()) continue;
            const rect: c.SDL_Rect = .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .w = @intFromFloat(r.width), .h = @intFromFloat(r.height) };
            const first = @as(usize, @intCast(rect.y)) * self.pixel_width + @as(usize, @intCast(rect.x));
            if (!c.SDL_UpdateTexture(texture, &rect, &self.framebuffer[first], @intCast(self.pixel_width * 4))) return sdlError("SDL_UpdateTexture");
        }
        if (!c.SDL_RenderTexture(self.renderer.?, texture, null, null)) return sdlError("SDL_RenderTexture");
        if (!c.SDL_RenderPresent(self.renderer.?)) return sdlError("SDL_RenderPresent");
    }

    /// Translates an SDL event into zigulee input.
    pub fn handleEvent(self: *Window, event: *const c.SDL_Event) void {
        const ui = self.ui;
        switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => self.closed = true,
            c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED => {
                self.syncSize() catch log.err("could not resize the framebuffer", .{});
            },
            c.SDL_EVENT_WINDOW_EXPOSED => self.full_redraw = true,
            c.SDL_EVENT_WINDOW_MAXIMIZED, c.SDL_EVENT_WINDOW_MINIMIZED, c.SDL_EVENT_WINDOW_RESTORED, c.SDL_EVENT_WINDOW_ENTER_FULLSCREEN, c.SDL_EVENT_WINDOW_LEAVE_FULLSCREEN => self.reportState(),
            c.SDL_EVENT_WINDOW_MOUSE_LEAVE => ui.dispatchPointer(.exit),
            c.SDL_EVENT_MOUSE_MOTION => ui.dispatchPointer(.{ .moved = .{ .position = .{ .x = event.motion.x, .y = event.motion.y } } }),
            c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
                const position: core.Point = .{ .x = event.button.x, .y = event.button.y };
                const button: input.PointerButton = switch (event.button.button) {
                    c.SDL_BUTTON_LEFT => .left,
                    c.SDL_BUTTON_RIGHT => .right,
                    c.SDL_BUTTON_MIDDLE => .middle,
                    else => .other,
                };
                const mods = c.SDL_GetModState();
                const modifiers: input.Modifiers = .{
                    .shift = mods & c.SDL_KMOD_SHIFT != 0,
                    .control = mods & c.SDL_KMOD_CTRL != 0,
                    .alt = mods & c.SDL_KMOD_ALT != 0,
                    .meta = mods & c.SDL_KMOD_GUI != 0,
                };
                // The keyboard back from a web view.
                if (builtin.os.tag == .linux and event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN) webkitgtk.takeKeyboard(&self.web_host);
                ui.dispatchPointer(if (event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN)
                    .{ .pressed = .{ .position = position, .button = button, .modifiers = modifiers } }
                else
                    .{ .released = .{ .position = position, .button = button } });
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                const flip: f32 = if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1 else 1;
                ui.dispatchPointer(.{
                    .wheel = .{
                        .position = .{ .x = event.wheel.mouse_x, .y = event.wheel.mouse_y },
                        // Scrolling up or left reveals content above or to the left.
                        .delta = .{ .x = -event.wheel.x * flip * wheel_step, .y = event.wheel.y * flip * wheel_step },
                    },
                });
            },
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => self.handleKey(&event.key),
            // Fingers: at 0...1 of the window.
            c.SDL_EVENT_FINGER_DOWN, c.SDL_EVENT_FINGER_MOTION, c.SDL_EVENT_FINGER_UP, c.SDL_EVENT_FINGER_CANCELED => {
                const size = ui.size();
                const at: core.Point = .{ .x = event.tfinger.x * size.width, .y = event.tfinger.y * size.height };
                gestures.dispatchTouch(ui, event.tfinger.fingerID, switch (event.type) {
                    c.SDL_EVENT_FINGER_DOWN => .down,
                    c.SDL_EVENT_FINGER_MOTION => .moved,
                    c.SDL_EVENT_FINGER_UP => .up,
                    else => .cancelled,
                }, at);
            },
            // A trackpad pinch (its scale since the last one), where the
            // pointer is.
            c.SDL_EVENT_PINCH_BEGIN, c.SDL_EVENT_PINCH_UPDATE, c.SDL_EVENT_PINCH_END => {
                var x: f32 = 0;
                var y: f32 = 0;
                _ = c.SDL_GetMouseState(&x, &y);
                const at: core.Point = .{ .x = x, .y = y };
                switch (event.type) {
                    c.SDL_EVENT_PINCH_BEGIN => gestures.dispatchTrackpad(ui, .began, 0, 0, at),
                    c.SDL_EVENT_PINCH_UPDATE => gestures.dispatchTrackpad(ui, .changed, event.pinch.scale - 1, 0, at),
                    else => gestures.dispatchTrackpad(ui, .ended, 0, 0, at),
                }
            },
            c.SDL_EVENT_DROP_BEGIN => {
                self.drop_kind = "";
                self.drop_data.clearRetainingCapacity();
            },
            // Over the window: what it carries is told at the drop.
            c.SDL_EVENT_DROP_POSITION => {
                self.drop_at = .{ .x = event.drop.x, .y = event.drop.y };
                _ = dnd.externalMoved(ui, &.{ dnd.file_kind, dnd.text_kind }, self.drop_at);
            },
            c.SDL_EVENT_DROP_FILE, c.SDL_EVENT_DROP_TEXT => {
                self.drop_at = .{ .x = event.drop.x, .y = event.drop.y };
                self.drop_kind = if (event.type == c.SDL_EVENT_DROP_FILE) dnd.file_kind else dnd.text_kind;
                if (self.drop_data.items.len > 0) self.drop_data.append(self.gpa, '\n') catch {};
                if (event.drop.data) |d| self.drop_data.appendSlice(self.gpa, std.mem.span(d)) catch {};
            },
            // Dropped (with data), or left the window (without).
            c.SDL_EVENT_DROP_COMPLETE => {
                if (self.drop_kind.len > 0) {
                    _ = dnd.externalDropped(ui, self.drop_kind, self.drop_data.items, self.drop_at);
                } else dnd.externalLeft(ui);
                self.drop_kind = "";
                self.drop_data.clearRetainingCapacity();
            },
            c.SDL_EVENT_TEXT_INPUT => {
                const text = std.mem.span(event.text.text);
                ui.dispatchKey(.pressed, .{ .text = text });
                ui.dispatchKey(.released, .{ .text = text });
            },
            c.SDL_EVENT_TEXT_EDITING => {
                const text = std.mem.span(event.edit.text);
                // `start` counts code points.
                var cursor: usize = text.len;
                if (event.edit.start >= 0) {
                    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
                    var n: i32 = 0;
                    while (n < event.edit.start) : (n += 1) _ = view.nextCodepointSlice() orelse break;
                    cursor = view.i;
                }
                ui.dispatchPreedit(text, cursor);
            },
            else => {},
        }
    }

    /// Pixels scrolled per wheel notch.
    const wheel_step = 40;

    fn handleKey(self: *Window, key: *const c.SDL_KeyboardEvent) void {
        const kind: input.KeyEventKind = if (key.down) .pressed else .released;
        const modifiers: input.Modifiers = .{
            .shift = key.mod & c.SDL_KMOD_SHIFT != 0,
            .control = key.mod & c.SDL_KMOD_CTRL != 0,
            .alt = key.mod & c.SDL_KMOD_ALT != 0,
            .meta = key.mod & c.SDL_KMOD_GUI != 0,
        };
        if (specialKey(key.key)) |text| {
            self.ui.dispatchKey(kind, .{ .text = text, .modifiers = modifiers, .repeat = key.repeat });
            return;
        }
        // Shortcuts (Ctrl+C, Cmd+S, ...) produce no text input: send the key.
        if ((modifiers.control or modifiers.meta) and key.key >= 0x20 and key.key < 0x7f) {
            const char: *const [1]u8 = &ascii[@intCast(key.key)];
            self.ui.dispatchKey(kind, .{ .text = char, .modifiers = modifiers, .repeat = key.repeat });
        }
    }
};

fn getClipboard(_: ?*anyopaque, gpa: Allocator) ?[]u8 {
    const text = c.SDL_GetClipboardText() orelse return null;
    defer c.SDL_free(text);
    return gpa.dupe(u8, std.mem.span(text)) catch null;
}

fn setClipboard(_: ?*anyopaque, text: []const u8) void {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const z = fba.allocator().dupeZ(u8, text) catch std.heap.page_allocator.dupeZ(u8, text) catch return;
    defer if (!fba.ownsSlice(z)) std.heap.page_allocator.free(z);
    _ = c.SDL_SetClipboardText(z.ptr);
}

const ascii: [128]u8 = blk: {
    var table: [128]u8 = undefined;
    for (&table, 0..) |*b, i| b.* = i;
    break :blk table;
};

fn specialKey(key: c.SDL_Keycode) ?[]const u8 {
    return switch (key) {
        c.SDLK_BACKSPACE => Key.backspace,
        c.SDLK_TAB => Key.tab,
        c.SDLK_RETURN, c.SDLK_KP_ENTER => Key.@"return",
        c.SDLK_ESCAPE => Key.escape,
        c.SDLK_DELETE => Key.delete,
        c.SDLK_LEFT => Key.left_arrow,
        c.SDLK_RIGHT => Key.right_arrow,
        c.SDLK_UP => Key.up_arrow,
        c.SDLK_DOWN => Key.down_arrow,
        c.SDLK_HOME => Key.home,
        c.SDLK_END => Key.end,
        c.SDLK_PAGEUP => Key.page_up,
        c.SDLK_PAGEDOWN => Key.page_down,
        else => null,
    };
}

// ---- Tests (SDL's dummy video driver: no display needed) ----

const testing = std.testing;

fn initHeadless() !void {
    _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_DRIVER, "dummy");
    // No display or GPU in headless runs: SDL's software renderer.
    _ = c.SDL_SetHint(c.SDL_HINT_RENDER_DRIVER, "software");
    init() catch return error.SkipZigTest; // driver not compiled in
}

fn pushEvent(event: c.SDL_Event) void {
    var e = event;
    _ = c.SDL_PushEvent(&e);
}

fn windowId(w: *Window) c.SDL_WindowID {
    return c.SDL_GetWindowID(w.handle);
}

/// The presented pixel at logical (x, y), read back from the renderer.
fn presentedPixel(w: *Window, x: c_int, y: c_int) !core.Color {
    const surface = c.SDL_RenderReadPixels(w.renderer.?, null) orelse return error.SdlError;
    defer c.SDL_DestroySurface(surface);
    var color: core.Color = .{};
    const s: c_int = @intFromFloat(w.scaleFactor());
    if (!c.SDL_ReadSurfacePixel(surface, x * s, y * s, &color.r, &color.g, &color.b, &color.a)) return error.SdlError;
    return color;
}

const TestUi = struct {
    ui: core.Window = undefined,
    button: core.items.Rectangle = .{},
    touch: core.items.TouchArea = .{},
    keys: core.items.FocusScope = .{},
    /// Rotated and scaled: the GPU renderers' transformed quads.
    tilted: core.items.Rectangle = .{},
    tilt: core.ItemTransform = .{},
    /// Its shadow (turned with it), and the button's.
    tilt_shadow: core.items.DropShadow = .{},
    button_shadow: core.items.DropShadow = .{},
    clicks: usize = 0,
    typed: [16]u8 = undefined,
    typed_len: usize = 0,

    fn init(t: *TestUi) !void {
        t.* = .{};
        t.ui.init(testing.allocator, .{ .width = 120, .height = 80 });
        t.ui.rootItem().appendChildren(&.{ &t.button.item, &t.keys.item });
        t.button.item.setGeometry(.{ .x = 10, .y = 10, .width = 50, .height = 30 });
        t.button.background.set(.color(.rgb(0xff0000)));
        t.ui.rootItem().appendChild(&t.tilted.item);
        t.tilted.item.setGeometry(.{ .x = 67, .y = 13, .width = 36, .height = 18 });
        t.tilted.border_radius.set(6);
        t.tilted.border_width.set(2);
        t.tilted.border_color.set(.color(.rgb(0x111827)));
        t.tilted.background.set(.linear(90, &.{ .{ .color = .rgb(0x22c55e), .position = 0 }, .{ .color = .rgb(0x0ea5e9), .position = 1 } }));
        t.tilted.item.transform = &t.tilt;
        t.tilt.rotation.set(30);
        t.tilt.scale_x.set(1.2);
        t.tilted.shadow = &t.tilt_shadow;
        t.tilt_shadow.offset_x.set(2);
        t.tilt_shadow.offset_y.set(3);
        t.tilt_shadow.blur.set(4);
        t.tilt_shadow.color.set(.rgba(0x00000080));
        t.button.shadow = &t.button_shadow;
        t.button_shadow.offset_y.set(2);
        t.button_shadow.blur.set(3);
        t.button_shadow.color.set(.rgba(0x7c3aed90));
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
        t.tilted.deinit();
        t.tilt.deinit();
        t.tilt_shadow.deinit();
        t.button_shadow.deinit();
    }
};

test "headless window: render, click, type, resize" {
    try initHeadless();
    defer deinit();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    const w = try Window.create(testing.allocator, &t.ui, .{ .title = "test" });
    defer w.destroy();

    try w.step(0);
    try testing.expect(!w.ui.redraw_requested);
    try testing.expectEqual(core.Color.rgb(0xff0000), try presentedPixel(w, 20, 20));
    try testing.expectEqual(core.Color.white, try presentedPixel(w, 100, 70));

    // A click on the button turns it blue on the next frame.
    var down: c.SDL_Event = .{ .button = .{ .type = c.SDL_EVENT_MOUSE_BUTTON_DOWN, .windowID = windowId(w), .button = c.SDL_BUTTON_LEFT, .down = true, .clicks = 1, .x = 30, .y = 20 } };
    pushEvent(down);
    down.button.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    down.button.down = false;
    pushEvent(down);
    try w.step(0);
    try testing.expectEqual(@as(usize, 1), t.clicks);
    try testing.expectEqual(core.Color.rgb(0x0000ff), try presentedPixel(w, 20, 20));

    // Text input and special keys reach the focused item.
    t.keys.focus();
    var text: c.SDL_Event = .{ .text = .{ .type = c.SDL_EVENT_TEXT_INPUT, .windowID = windowId(w), .text = "hi" } };
    pushEvent(text);
    pushEvent(.{ .key = .{ .type = c.SDL_EVENT_KEY_DOWN, .windowID = windowId(w), .key = c.SDLK_BACKSPACE, .down = true } });
    try w.step(0);
    try testing.expectEqualStrings("hi" ++ Key.backspace, t.typed[0..t.typed_len]);
    text.text.text = "!";

    // Resizing the window resizes the zigulee window.
    _ = c.SDL_SetWindowSize(w.handle, 200, 150);
    _ = c.SDL_SyncWindow(w.handle);
    try w.step(0);
    try testing.expectEqual(core.Size{ .width = 200, .height = 150 }, t.ui.size());
    try testing.expectEqual(core.Color.white, try presentedPixel(w, 190, 140));

    // Closing ends the loop.
    pushEvent(.{ .window = .{ .type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED, .windowID = windowId(w) } });
    try w.run();
    try testing.expect(w.closed);
}

test "window state: asked by the app, followed when the window changes" {
    try initHeadless();
    defer deinit();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    const w = try Window.create(testing.allocator, &t.ui, .{ .title = "state" });
    defer w.destroy();
    try w.step(0);
    // The headless driver can make a window full screen, not keep it on
    // top: the app's properties say what happened.
    t.ui.fullscreen.set(true);
    t.ui.always_on_top.set(true);
    try w.step(0);
    try w.step(0);
    try testing.expect(c.SDL_GetWindowFlags(w.handle) & c.SDL_WINDOW_FULLSCREEN != 0);
    try testing.expect(t.ui.fullscreen.get());
    try testing.expect(!t.ui.always_on_top.get());
    // Back from full screen by someone else (the user): the app's
    // property follows.
    _ = c.SDL_SetWindowFullscreen(w.handle, false);
    try w.step(0);
    try testing.expect(!t.ui.fullscreen.get());
}

test "the loop sleeps until the next timer" {
    try initHeadless();
    defer deinit();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    const w = try Window.create(testing.allocator, &t.ui, .{});
    defer w.destroy();
    try w.step(0); // first frame

    var fired = false;
    var timer: core.Timer = .{};
    defer timer.deinit();
    timer.start(.single_shot, 50, &fired, struct {
        fn f(flag: *bool) void {
            flag.* = true;
        }
    }.f);
    const start = now();
    // Nothing else to do: the loop sleeps until the timer is due. (A
    // window system event may wake a step early: a few steps, not a busy
    // loop.)
    var steps: usize = 0;
    while (!fired and now() - start < 1000) : (steps += 1) try w.step(1000);
    try testing.expect(fired);
    const elapsed = now() - start;
    if (elapsed < 45 or steps >= 10) {
        std.debug.print("timer fired after {d} ms, {d} steps\n", .{ elapsed, steps });
        return error.TestUnexpectedResult;
    }
}

test "clipboard and input method composition" {
    try initHeadless();
    defer deinit();
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 120, .height = 40 });
    var field: core.items.TextInput = undefined;
    field.init(testing.allocator);
    defer {
        ui.deinit();
        field.deinit();
    }
    ui.rootItem().appendChild(&field.item);
    try field.item.fillParent(testing.allocator);
    const w = try Window.create(testing.allocator, &ui, .{});
    defer w.destroy();
    field.focus();

    // Copying goes through SDL's clipboard (if the video driver has one).
    field.text.set("copy me");
    field.selectAll();
    field.copy();
    if (c.SDL_HasClipboardText()) {
        const text = ui.clipboardText(testing.allocator).?;
        defer testing.allocator.free(text);
        try testing.expectEqualStrings("copy me", text);
    }

    // Composition events become pre-edit text; `start` counts code points.
    field.text.set("");
    var edit: c.SDL_Event = .{ .edit = .{ .type = c.SDL_EVENT_TEXT_EDITING, .windowID = windowId(w), .text = "kあ", .start = 1, .length = 0 } };
    pushEvent(edit);
    try w.step(0);
    try testing.expectEqualStrings("kあ", field.preedit.get());
    try testing.expectEqual(@as(usize, 1), field.preedit_cursor);
    edit.edit.text = "";
    edit.edit.start = 0;
    pushEvent(edit);
    pushEvent(.{ .text = .{ .type = c.SDL_EVENT_TEXT_INPUT, .windowID = windowId(w), .text = "か" } });
    try w.step(0);
    try testing.expectEqualStrings("か", field.text.get());
    try testing.expectEqualStrings("", field.preedit.get());
    try testing.expect(!ui.ime_cursor_rect_changed);
}

test "several windows: each gets its own events, and closes on its own" {
    try initHeadless();
    defer deinit();
    var a: TestUi = undefined;
    try a.init();
    defer a.deinit();
    var b: TestUi = undefined;
    try b.init();
    defer b.deinit();
    const wa = try Window.create(testing.allocator, &a.ui, .{ .title = "a" });
    defer wa.destroy();
    const wb = try Window.create(testing.allocator, &b.ui, .{ .title = "b" });
    defer wb.destroy();
    try step(0);

    // A click in b reaches only b.
    var down: c.SDL_Event = .{ .button = .{ .type = c.SDL_EVENT_MOUSE_BUTTON_DOWN, .windowID = windowId(wb), .button = c.SDL_BUTTON_LEFT, .down = true, .clicks = 1, .x = 30, .y = 20 } };
    pushEvent(down);
    down.button.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    down.button.down = false;
    pushEvent(down);
    try step(0);
    try testing.expectEqual(@as(usize, 0), a.clicks);
    try testing.expectEqual(@as(usize, 1), b.clicks);
    // Both windows render: b's button turned blue, a's is still red.
    try testing.expectEqual(core.Color.rgb(0xff0000), try presentedPixel(wa, 20, 20));
    try testing.expectEqual(core.Color.rgb(0x0000ff), try presentedPixel(wb, 20, 20));

    // Closing a leaves b open; runAll returns once both are closed.
    pushEvent(.{ .window = .{ .type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED, .windowID = windowId(wa) } });
    try step(0);
    try testing.expect(wa.closed and !wb.closed);
    pushEvent(.{ .window = .{ .type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED, .windowID = windowId(wb) } });
    try runAll();
    try testing.expect(wb.closed);
}

test "a live resize redraws without waiting for the event loop" {
    try initHeadless();
    defer deinit();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    const w = try Window.create(testing.allocator, &t.ui, .{ .title = "resize" });
    defer w.destroy();
    try step(0);
    // macOS blocks the loop while resizing; SDL's watchers see these.
    t.button.background.set(.color(.rgb(0x00ff00)));
    _ = c.SDL_SetWindowSize(w.handle, 240, 160);
    _ = c.SDL_SyncWindow(w.handle);
    pushEvent(.{ .window = .{ .type = c.SDL_EVENT_WINDOW_EXPOSED, .windowID = windowId(w), .data1 = 1 } });
    try testing.expectEqual(core.Size{ .width = 240, .height = 160 }, t.ui.size());
    try testing.expectEqual(core.Color.rgb(0x00ff00), try presentedPixel(w, 20, 20));
    try testing.expectEqual(core.Color.white, try presentedPixel(w, 230, 150));
}

test "OpenGL draws what the software renderer draws" {
    // A real display and OpenGL are needed: skipped without them.
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SkipZigTest;
    defer deinit();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    // Rounded corners, a border, a gradient and a path.
    var card: core.items.Rectangle = .{};
    defer card.deinit();
    t.ui.rootItem().appendChild(&card.item);
    card.item.setGeometry(.{ .x = 64, .y = 8, .width = 50, .height = 40 });
    card.border_radius.set(9);
    card.border_width.set(2.5);
    card.border_color.set(.color(.rgb(0x111827)));
    card.background.set(.linear(45, &.{ .{ .color = .rgb(0xf59e0b), .position = 0 }, .{ .color = .rgb(0x7c3aed), .position = 1 } }));
    var icon: core.items.Path = .{};
    defer icon.deinit();
    t.ui.rootItem().appendChild(&icon.item);
    icon.item.setGeometry(.{ .x = 12, .y = 46, .width = 30, .height = 30 });
    icon.commands.set("M 2 15 L 12 25 L 28 4");
    icon.stroke.set(.color(.rgb(0x059669)));
    icon.stroke_width.set(3);

    // An image, scaled up smoothly, and one with sharp pixels.
    var checker: [16]Rgba8 = undefined;
    for (&checker, 0..) |*p, i| p.* = if ((i % 4 + i / 4) % 2 == 0) core.Color.rgb(0x2563eb).premultiplied() else core.Color.rgba(0xfacc1580).premultiplied();
    var smooth: core.items.Image = .{};
    defer smooth.deinit();
    var sharp: core.items.Image = .{};
    defer sharp.deinit();
    t.ui.rootItem().appendChildren(&.{ &smooth.item, &sharp.item });
    smooth.source.set(.{ .width = 4, .height = 4, .pixels = &checker });
    smooth.item.setGeometry(.{ .x = 64, .y = 52, .width = 24, .height = 24 });
    sharp.source.set(.{ .width = 4, .height = 4, .pixels = &checker });
    sharp.image_rendering.set(.pixelated);
    sharp.item.setGeometry(.{ .x = 92, .y = 52, .width = 24, .height = 24 });
    // Text, if the bundled font is there (tests run from the project).
    const font_bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, "examples/fonts/inter/Inter-Regular.ttf", testing.allocator, .limited(4 << 20)) catch null;
    defer if (font_bytes) |b| testing.allocator.free(b);
    var font: core.Font = undefined;
    var label: core.items.Text = .{};
    defer label.deinit();
    if (font_bytes) |b| {
        font = try .init(b);
        t.ui.default_font.set(&font);
        t.ui.rootItem().appendChild(&label.item);
        label.text.set("Hello, GPU");
        label.font_size.set(11);
        label.item.setGeometry(.{ .x = 2, .y = 0, .width = 70, .height = 16 });
    }
    // Text rotated (its glyphs sampled between texels).
    var slanted: core.items.Text = .{};
    defer slanted.deinit();
    var slant: core.ItemTransform = .{};
    defer slant.deinit();
    if (font_bytes != null) {
        t.ui.rootItem().appendChild(&slanted.item);
        slanted.text.set("Tilt");
        slanted.font_size.set(12);
        slanted.item.setGeometry(.{ .x = 2, .y = 22, .width = 30, .height = 16 });
        slanted.item.transform = &slant;
        slant.rotation.set(-25);
    }

    const w = Window.create(testing.allocator, &t.ui, .{ .renderer = .opengl, .hidden = true, .resizable = false }) catch return error.SkipZigTest;
    defer w.destroy();
    // Drawn and read back before the buffers are swapped.
    const gpu = w.gpu.?;
    const width = w.pixel_width;
    const height = w.pixel_height;
    gpu.setScaleFactor(w.scaleFactor());
    _ = try gpu.renderWindow(&t.ui, width, height, .full);
    const drawn = try testing.allocator.alloc(Rgba8, @as(usize, width) * height);
    defer testing.allocator.free(drawn);
    gpu.readPixels(width, height, drawn);

    const expected = try testing.allocator.alloc(Rgba8, drawn.len);
    defer testing.allocator.free(expected);
    @memset(expected, .transparent);
    var software: zigulee.software.Renderer(Rgba8) = .init(testing.allocator);
    defer software.deinit();
    software.scale_factor = w.scaleFactor();
    _ = try software.renderWindow(&t.ui, .init(expected, width, height), .full);
    var off: usize = 0;
    var worst: u8 = 0;
    for (expected, drawn) |e, a| {
        var d: u8 = 0;
        inline for (.{ "r", "g", "b", "a" }) |ch| d = @max(d, @as(u8, @intCast(@abs(@as(i16, @field(e, ch)) - @field(a, ch)))));
        worst = @max(worst, d);
        if (d > 3) off += 1;
    }
    if (off > 0) std.debug.print("OpenGL: {d} of {d} pixels differ by more than 3 (worst {d})\n", .{ off, drawn.len, worst });
    try testing.expectEqual(@as(usize, 0), off);

    // A partial frame, over the last one: only the button is redrawn.
    t.button.background.set(.color(.rgb(0x00aa55)));
    const region = try gpu.renderWindow(&t.ui, width, height, .partial);
    try testing.expect(!region.isEmpty() and region.boundingBox().area() < @as(f32, @floatFromInt(drawn.len)) / 2);
    gpu.readPixels(width, height, drawn);
    @memset(expected, .transparent);
    _ = try software.renderWindow(&t.ui, .init(expected, width, height), .full);
    off = 0;
    for (expected, drawn) |e, a| {
        inline for (.{ "r", "g", "b", "a" }) |ch| {
            if (@abs(@as(i16, @field(e, ch)) - @field(a, ch)) > 3) off += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), off);
    // Nothing changed: nothing drawn.
    try testing.expect((try gpu.renderWindow(&t.ui, width, height, .partial)).isEmpty());
}

test "Metal (macOS) draws what the software renderer draws" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SkipZigTest;
    defer deinit();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    const w = Window.create(testing.allocator, &t.ui, .{ .renderer = .metal, .hidden = true, .resizable = false }) catch return error.SkipZigTest;
    defer w.destroy();
    const drawn = try testing.allocator.alloc(Rgba8, @as(usize, w.pixel_width) * w.pixel_height);
    defer testing.allocator.free(drawn);
    const expected = try testing.allocator.alloc(Rgba8, drawn.len);
    defer testing.allocator.free(expected);
    var software: zigulee.software.Renderer(Rgba8) = .init(testing.allocator);
    defer software.deinit();
    software.scale_factor = w.scaleFactor();
    for (0..2) |round| {
        if (round == 1) t.button.background.set(.color(.rgb(0x00aa55)));
        try w.render();
        w.metal.?.readPixels(drawn);
        @memset(expected, .transparent);
        _ = try software.renderWindow(&t.ui, .init(expected, w.pixel_width, w.pixel_height), .full);
        for (expected, drawn) |e, a| {
            inline for (.{ "r", "g", "b", "a" }) |ch| try testing.expect(@abs(@as(i16, @field(e, ch)) - @field(a, ch)) <= 3);
        }
    }
}

test "Vulkan draws what the software renderer draws" {
    // Without Vulkan (no driver, no MoltenVK): nothing to test.
    var probe = zigulee.gpu.vulkan.Renderer.init(testing.allocator, .none) catch return error.SkipZigTest;
    probe.deinit();
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SkipZigTest;
    defer deinit();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    const w = Window.create(testing.allocator, &t.ui, .{ .renderer = .vulkan, .hidden = true, .resizable = false }) catch return error.SkipZigTest;
    defer w.destroy();
    const drawn = try testing.allocator.alloc(Rgba8, @as(usize, w.pixel_width) * w.pixel_height);
    defer testing.allocator.free(drawn);
    const expected = try testing.allocator.alloc(Rgba8, drawn.len);
    defer testing.allocator.free(expected);
    var software: zigulee.software.Renderer(Rgba8) = .init(testing.allocator);
    defer software.deinit();
    software.scale_factor = w.scaleFactor();
    for (0..2) |round| {
        if (round == 1) t.button.background.set(.color(.rgb(0x00aa55)));
        try w.render();
        try w.vulkan.?.readPixels(drawn);
        @memset(expected, .transparent);
        _ = try software.renderWindow(&t.ui, .init(expected, w.pixel_width, w.pixel_height), .full);
        for (expected, drawn) |e, a| {
            inline for (.{ "r", "g", "b", "a" }) |ch| try testing.expect(@abs(@as(i16, @field(e, ch)) - @field(a, ch)) <= 3);
        }
    }
}

test {
    _ = audio;
    _ = file_dialogs;
    _ = capture;
}

test "files and text dropped from other applications" {
    try initHeadless();
    defer deinit();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    var area: core.items.DropArea = .{};
    defer area.deinit();
    t.ui.rootItem().appendChild(&area.item);
    area.item.setGeometry(.{ .width = 60, .height = 60 });
    area.accepts.set(dnd.file_kind);
    const Got = struct {
        buf: [64]u8 = undefined,
        len: usize = 0,
        fn f(self: *@This(), data: []const u8) void {
            @memcpy(self.buf[0..data.len], data);
            self.len = data.len;
        }
    };
    var got: Got = .{};
    area.dropped.setHandler(&got, Got.f);
    const w = try Window.create(testing.allocator, &t.ui, .{ .title = "test" });
    defer w.destroy();

    const id = windowId(w);
    const drop = struct {
        fn ev(win: *Window, wid: c.SDL_WindowID, kind: u32, x: f32, y: f32, data: ?[*:0]const u8) void {
            const e: c.SDL_Event = .{ .drop = .{ .type = kind, .windowID = wid, .x = x, .y = y, .data = data } };
            win.handleEvent(&e);
        }
    }.ev;
    drop(w, id, c.SDL_EVENT_DROP_BEGIN, 0, 0, null);
    drop(w, id, c.SDL_EVENT_DROP_POSITION, 20, 20, null);
    try testing.expect(area.contains_drag.get());
    drop(w, id, c.SDL_EVENT_DROP_FILE, 20, 20, "/tmp/one.png");
    drop(w, id, c.SDL_EVENT_DROP_FILE, 20, 20, "/tmp/two.png");
    drop(w, id, c.SDL_EVENT_DROP_COMPLETE, 20, 20, null);
    try testing.expectEqualStrings("/tmp/one.png\n/tmp/two.png", got.buf[0..got.len]);
    try testing.expect(!area.contains_drag.get());

    // Over it, then away: left, nothing dropped.
    got.len = 0;
    drop(w, id, c.SDL_EVENT_DROP_BEGIN, 0, 0, null);
    drop(w, id, c.SDL_EVENT_DROP_POSITION, 20, 20, null);
    drop(w, id, c.SDL_EVENT_DROP_COMPLETE, 0, 0, null);
    try testing.expect(!area.contains_drag.get());
    try testing.expectEqual(@as(usize, 0), got.len);

    // Text is not a file: not taken here.
    drop(w, id, c.SDL_EVENT_DROP_BEGIN, 0, 0, null);
    drop(w, id, c.SDL_EVENT_DROP_TEXT, 20, 20, "hello");
    drop(w, id, c.SDL_EVENT_DROP_COMPLETE, 20, 20, null);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "fingers: one works as the mouse, two pinch; a trackpad pinch" {
    try initHeadless();
    defer deinit();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    var pinch: core.items.PinchArea = .{};
    defer pinch.deinit();
    t.ui.rootItem().appendChild(&pinch.item);
    pinch.item.setGeometry(.{ .x = 0, .y = 50, .width = 120, .height = 30 });
    const w = try Window.create(testing.allocator, &t.ui, .{ .title = "test" });
    defer w.destroy();
    const id = windowId(w);
    const finger = struct {
        fn ev(win: *Window, wid: c.SDL_WindowID, kind: u32, n: u64, x: f32, y: f32) void {
            const e: c.SDL_Event = .{ .tfinger = .{ .type = kind, .windowID = wid, .fingerID = n, .x = x, .y = y } };
            win.handleEvent(&e);
        }
    }.ev;
    // A tap on the button (at 30, 20 of 120 x 80).
    finger(w, id, c.SDL_EVENT_FINGER_DOWN, 1, 30.0 / 120.0, 20.0 / 80.0);
    finger(w, id, c.SDL_EVENT_FINGER_UP, 1, 30.0 / 120.0, 20.0 / 80.0);
    try testing.expectEqual(@as(usize, 1), t.clicks);
    // Two fingers in the pinch area, spread twice as far.
    finger(w, id, c.SDL_EVENT_FINGER_DOWN, 2, 50.0 / 120.0, 65.0 / 80.0);
    finger(w, id, c.SDL_EVENT_FINGER_DOWN, 3, 70.0 / 120.0, 65.0 / 80.0);
    try testing.expect(pinch.active.get());
    finger(w, id, c.SDL_EVENT_FINGER_MOTION, 3, 90.0 / 120.0, 65.0 / 80.0);
    try testing.expectApproxEqAbs(@as(f32, 2), pinch.scale.get(), 0.01);
    finger(w, id, c.SDL_EVENT_FINGER_UP, 3, 90.0 / 120.0, 65.0 / 80.0);
    finger(w, id, c.SDL_EVENT_FINGER_UP, 2, 50.0 / 120.0, 65.0 / 80.0);
    try testing.expect(!pinch.active.get());
    try testing.expectEqual(@as(usize, 1), t.clicks);
}
