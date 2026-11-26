// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The native Windows backend: shows a `zigulee.Window` in a Win32 window,
//! with no other dependency than the system's libraries. Same interface as
//! the SDL3 and macOS backends:
//!
//!     try windows.init();
//!     defer windows.deinit();
//!     const window = try windows.Window.create(gpa, &ui_window, .{ .title = "Hello" });
//!     defer window.destroy();
//!     try window.run();
//!
//! Windows draw with Direct3D 12 (the GPU renderer) or with the software
//! renderer, whose frames are copied to the window (GDI). They follow the
//! monitor's DPI (per-monitor DPI awareness). Keyboard input goes through
//! the system's input methods (IMM: composed text is shown in place, the
//! candidate window by the caret). Screen readers see the accessible
//! items (uia.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const dnd = core.dnd;
const gestures = core.gestures;
const Rgba8 = core.Rgba8;
const input = core.input;
const Key = input.Key;
const c = @import("win32_c");

// (Casts in windows.h's macros: HWND_TOPMOST, HWND_NOTOPMOST.)
const hwnd_topmost: usize = std.math.maxInt(usize);
const hwnd_notopmost: usize = std.math.maxInt(usize) - 1;
const uia = @import("zigulee-uia");
const d3d12 = @import("zigulee-d3d12");

const log = std.log.scoped(.zigulee_windows);

pub const Error = error{ Win32Failed, D3d12Failed } || Allocator.Error;

pub const RendererKind = enum {
    /// Direct3D 12, else software.
    auto,
    /// The GPU renderer on Direct3D 12: the window fails to open without
    /// it.
    d3d12,
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

var frequency: i64 = 0;
var start_ticks: i64 = 0;

fn ticks() i64 {
    var t: c.LARGE_INTEGER = undefined;
    _ = c.QueryPerformanceCounter(&t);
    return t.QuadPart;
}

/// Milliseconds since `init` (a monotonic clock): the clock zigulee's timers
/// and animations run on.
pub fn now() u64 {
    if (frequency == 0) {
        var f: c.LARGE_INTEGER = undefined;
        _ = c.QueryPerformanceFrequency(&f);
        frequency = f.QuadPart;
        start_ticks = ticks();
    }
    return @intCast(@divTrunc((ticks() - start_ticks) * 1000, frequency));
}

// ---- The application ----

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZiguleeWindow");
var class_atom: c.ATOM = 0;
var instance: c.HINSTANCE = null;
var open_windows: ?*Window = null;

/// Milliseconds between animation frames.
const frame_interval = 16;

/// Sound: the mixer plays through WASAPI (from `init` to `deinit`).
var audio_output: @import("wasapi.zig").Output = .{};

/// Registers the window class (and makes the process DPI aware), and makes
/// WASAPI the mixer's audio output (the device opens when something
/// plays). Call once, before creating windows.
pub fn init() Error!void {
    if (class_atom != 0) return;
    _ = now();
    core.audio.mixer().setOutput(audio_output.output());
    core.video.addDecoder(@import("mediafoundation.zig").decoder);
    core.dialogs.setFileDialogs(@import("filedialog.zig").provider);
    core.tray.setProvider(@import("tray.zig").provider);
    core.links.setOpener(.{ .open = openUrl });
    core.webview.setProvider(@import("webview.zig").provider);
    // Per-monitor DPI awareness (v2): sizes in physical pixels, scaled by
    // zigulee (no blurry bitmap stretching by the system).
    _ = c.SetProcessDpiAwarenessContext(@ptrFromInt(@as(usize, @bitCast(@as(isize, -4)))));
    instance = c.GetModuleHandleW(null);
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.style = c.CS_OWNDC;
    wc.lpfnWndProc = windowProc;
    wc.hInstance = instance;
    wc.hIcon = c.LoadIconW(null, @ptrFromInt(32512)); // IDI_APPLICATION
    wc.lpszClassName = class_name;
    class_atom = c.RegisterClassExW(&wc);
    if (class_atom == 0) return error.Win32Failed;
}

pub fn deinit() void {
    if (class_atom == 0 or open_windows != null) return;
    core.audio.mixer().setOutput(null);
    core.video.removeDecoder("mediafoundation");
    core.dialogs.setFileDialogs(null);
    core.tray.setProvider(null);
    core.links.setOpener(null);
    core.webview.setProvider(null);
    @import("tray.zig").removeAll();
    _ = c.UnregisterClassW(class_name, instance);
    class_atom = 0;
}

/// One event loop iteration for every open window: waits for a message (at
/// most `max_wait_ms`, or until the next timer or animation frame),
/// handles the messages, fires timers, runs change handlers and draws what
/// changed.
pub fn step(max_wait_ms: ?u32) Error!void {
    core.updateTimersAndAnimations(now());
    var timeout: ?u64 = null; // null: until a message
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

    if (timeout != 0) {
        const ms: c.DWORD = if (timeout) |t| @intCast(@min(t, 0xFFFF_FFFE)) else c.INFINITE;
        _ = c.MsgWaitForMultipleObjectsEx(0, null, ms, c.QS_ALLINPUT, c.MWMO_INPUTAVAILABLE);
    }
    var m: c.MSG = undefined;
    while (c.PeekMessageW(&m, null, 0, 0, c.PM_REMOVE) != 0) {
        if (m.message == c.WM_QUIT) {
            it = open_windows;
            while (it) |w| : (it = w.next) w.closed = true;
            continue;
        }
        _ = c.TranslateMessage(&m);
        _ = c.DispatchMessageW(&m);
    }

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

// ---- Windows ----

/// A pixel as GDI's 32-bit bitmaps have it.
const Bgra8 = extern struct { b: u8, g: u8, r: u8, a: u8 };

pub const Window = struct {
    gpa: Allocator,
    ui: *core.Window,
    hwnd: c.HWND = null,
    /// The software renderer's framebuffer, in physical pixels (kept
    /// between frames: only what changed is redrawn), and what the window
    /// shows of it (as GDI wants it).
    framebuffer: []Rgba8 = &.{},
    shown: []Bgra8 = &.{},
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,
    software: zigulee.software.Renderer(Rgba8),
    /// With Direct3D 12: the renderer.
    d3d12: ?*d3d12.Renderer = null,
    full_redraw: bool = true,
    /// Set when the user closes the window; `run` returns.
    closed: bool = false,
    last_frame: u64 = 0,
    a11y: ?*uia.Bridge = null,
    /// Takes drops from other applications (registered with OLE).
    drop_target: DropTarget = undefined,
    drop_registered: bool = false,
    cursor: input.MouseCursor = .default,
    /// The color scheme the title bar shows.
    scheme: ?core.ColorScheme = null,
    /// Full screen, maximized and the like, as asked and as shown.
    state: core.WindowStateSync = .{},
    /// Full screen: the window made a borderless one over the monitor, and
    /// what it was before.
    full_screen: bool = false,
    saved_style: c.LONG_PTR = 0,
    saved_placement: c.WINDOWPLACEMENT = undefined,
    /// While being created: sizes are set at the end.
    creating: bool = true,
    tracking_mouse: bool = false,
    /// Text being composed by an input method.
    composing: bool = false,
    /// The first half of a character outside the BMP (WM_CHAR).
    high_surrogate: u16 = 0,
    next: ?*Window = null,

    /// Opens a window showing `ui`, sized to `ui.size()` in logical pixels
    /// (scaled for the monitor). `ui` must outlive the window.
    pub fn create(gpa: Allocator, ui: *core.Window, options: Options) Error!*Window {
        try init();
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .ui = ui, .software = .init(gpa) };
        errdefer self.software.deinit();
        errdefer self.freeBuffers();

        var style: c.DWORD = c.WS_OVERLAPPEDWINDOW;
        if (!options.resizable) style &= ~@as(c.DWORD, c.WS_THICKFRAME | c.WS_MAXIMIZEBOX);
        const title = std.unicode.utf8ToUtf16LeAllocZ(gpa, options.title) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidUtf8 => error.Win32Failed,
        };
        defer gpa.free(title);
        const use_default: c_int = @bitCast(@as(u32, 0x80000000)); // CW_USEDEFAULT
        // The window procedure finds the window from here on.
        _ = c.CreateWindowExW(0, class_name, title.ptr, style, use_default, use_default, 100, 100, null, null, instance, self) orelse return error.Win32Failed;
        errdefer {
            _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);
            _ = c.DestroyWindow(self.hwnd);
        }

        // The client area: the zigulee window's size, at the window's DPI.
        const dpi = c.GetDpiForWindow(self.hwnd);
        const scale: f32 = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96 else 1;
        const size = ui.size();
        var rect: c.RECT = .{ .left = 0, .top = 0, .right = @intFromFloat(@round(size.width * scale)), .bottom = @intFromFloat(@round(size.height * scale)) };
        _ = c.AdjustWindowRectExForDpi(&rect, style, 0, 0, dpi);
        _ = c.SetWindowPos(self.hwnd, null, 0, 0, rect.right - rect.left, rect.bottom - rect.top, c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);

        switch (options.renderer) {
            .software => {},
            .d3d12 => self.openD3d12() catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.D3d12Failed,
            },
            .auto => self.openD3d12() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => log.info("Direct3D 12 unavailable ({t}): using the software renderer", .{err}),
            },
        }
        errdefer self.closeD3d12();
        self.creating = false;
        try self.syncSize();

        ui.clipboard = .{ .ctx = null, .getFn = getClipboard, .setFn = setClipboard };
        ui.native_view = self.hwnd;
        errdefer ui.clipboard = null;
        self.a11y = try uia.Bridge.create(gpa, ui, @ptrCast(self.hwnd));
        // Files and text dropped from other applications.
        self.drop_target = .{ .com = .{ .lpVtbl = @constCast(&DropTarget.vtable) }, .owner = self };
        if (c.OleInitialize(null) >= 0 and c.RegisterDragDrop(self.hwnd, &self.drop_target.com) >= 0) self.drop_registered = true;
        self.updateScheme();
        if (!options.hidden) self.show();
        self.next = open_windows;
        open_windows = self;
        return self;
    }

    pub fn show(self: *Window) void {
        _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
        _ = c.SetForegroundWindow(self.hwnd);
    }

    pub fn destroy(self: *Window) void {
        var link = &open_windows;
        while (link.*) |w| : (link = &w.next) if (w == self) {
            link.* = self.next;
            break;
        };
        if (self.drop_registered) _ = c.RevokeDragDrop(self.hwnd);
        if (self.a11y) |b| b.destroy();
        self.ui.clipboard = null;
        self.ui.native_view = null;
        self.closeD3d12();
        _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(self.hwnd);
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

    /// Shows another zigulee window in this one (live reloading), sized to
    /// the current window. `ui` must outlive the window or the next call.
    pub fn setUi(self: *Window, ui: *core.Window) Error!void {
        self.ui.clipboard = null;
        self.ui.native_view = null;
        if (self.a11y) |b| b.destroy();
        self.a11y = null;
        self.ui = ui;
        ui.clipboard = .{ .ctx = null, .getFn = getClipboard, .setFn = setClipboard };
        ui.native_view = self.hwnd;
        self.a11y = try uia.Bridge.create(self.gpa, ui, @ptrCast(self.hwnd));
        try self.syncSize();
        self.full_redraw = true;
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(self.gpa, title) catch return;
        defer self.gpa.free(wide);
        _ = c.SetWindowTextW(self.hwnd, wide.ptr);
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

    /// After a round of messages: a frame if anything changed, the cursor,
    /// the input method's windows and what assistive technology sees.
    fn afterEvents(self: *Window) Error!void {
        if (self.needsFrame()) try self.render();
        self.updateScheme();
        self.updateState();
        self.updateCursor(false);
        if (self.ui.ime_cursor_rect_changed) {
            self.ui.ime_cursor_rect_changed = false;
            self.placeImeWindows();
        }
        if (self.a11y) |b| {
            b.scale = self.software.scale_factor;
            try b.update();
        }
    }

    /// Follows the client area's size in pixels, and the DPI.
    fn syncSize(self: *Window) Error!void {
        var r: c.RECT = undefined;
        _ = c.GetClientRect(self.hwnd, &r);
        const width: u32 = @intCast(@max(1, r.right - r.left));
        const height: u32 = @intCast(@max(1, r.bottom - r.top));
        const dpi = c.GetDpiForWindow(self.hwnd);
        const scale: f32 = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96 else 1;
        self.software.scale_factor = scale;
        self.ui.setSize(.{ .width = @as(f32, @floatFromInt(width)) / scale, .height = @as(f32, @floatFromInt(height)) / scale });
        self.full_redraw = true;
        if (self.d3d12 != null) {
            self.pixel_width = width;
            self.pixel_height = height;
            return;
        }
        if (width == self.pixel_width and height == self.pixel_height and self.framebuffer.len > 0) return;
        const n = @as(usize, width) * height;
        const framebuffer = try self.gpa.alloc(Rgba8, n);
        errdefer self.gpa.free(framebuffer);
        const shown = try self.gpa.alloc(Bgra8, n);
        @memset(framebuffer, .transparent);
        @memset(shown, .{ .b = 0, .g = 0, .r = 0, .a = 0 });
        self.freeBuffers();
        self.framebuffer = framebuffer;
        self.shown = shown;
        self.pixel_width = width;
        self.pixel_height = height;
    }

    /// Draws what changed and shows it.
    pub fn render(self: *Window) Error!void {
        self.last_frame = now();
        const mode: core.RenderMode = if (self.full_redraw) .full else .partial;
        if (self.d3d12) |d| {
            d.setScaleFactor(self.software.scale_factor);
            _ = d.renderWindow(self.ui, self.pixel_width, self.pixel_height, mode) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.D3d12Failed,
            };
            self.full_redraw = false;
            return;
        }
        const canvas: zigulee.software.Canvas(Rgba8) = .init(self.framebuffer, self.pixel_width, self.pixel_height);
        const region = try self.software.renderWindow(self.ui, canvas, mode);
        self.full_redraw = false;
        if (region.isEmpty()) return;
        // What changed, converted for GDI and copied to the window.
        const box = region.boundingBox();
        const x0: u32 = @intFromFloat(std.math.clamp(@floor(box.x), 0, @as(f32, @floatFromInt(self.pixel_width))));
        const y0: u32 = @intFromFloat(std.math.clamp(@floor(box.y), 0, @as(f32, @floatFromInt(self.pixel_height))));
        const x1: u32 = @intFromFloat(std.math.clamp(@ceil(box.x + box.width), 0, @as(f32, @floatFromInt(self.pixel_width))));
        const y1: u32 = @intFromFloat(std.math.clamp(@ceil(box.y + box.height), 0, @as(f32, @floatFromInt(self.pixel_height))));
        if (x0 >= x1 or y0 >= y1) return;
        for (y0..y1) |y| {
            const row = y * self.pixel_width;
            for (self.framebuffer[row + x0 .. row + x1], self.shown[row + x0 .. row + x1]) |p, *q| q.* = .{ .b = p.b, .g = p.g, .r = p.r, .a = p.a };
        }
        const dc = c.GetDC(self.hwnd);
        defer _ = c.ReleaseDC(self.hwnd, dc);
        self.blit(dc, x0, y0, x1, y1);
    }

    /// Copies a rectangle of `shown` to the window.
    fn blit(self: *Window, dc: c.HDC, x0: u32, y0: u32, x1: u32, y1: u32) void {
        if (self.shown.len == 0 or x0 >= x1 or y0 >= y1) return;
        // A top-down bitmap of the rows y0..y1 (whole rows: no ambiguity
        // about where a top-down bitmap's source rectangle starts).
        var info = std.mem.zeroes(c.BITMAPINFO);
        info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
        info.bmiHeader.biWidth = @intCast(self.pixel_width);
        info.bmiHeader.biHeight = -@as(i32, @intCast(y1 - y0));
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = c.BI_RGB;
        const rows = self.shown[@as(usize, y0) * self.pixel_width ..];
        const w: c_int = @intCast(x1 - x0);
        const h: c_int = @intCast(y1 - y0);
        _ = c.StretchDIBits(dc, @intCast(x0), @intCast(y0), w, h, @intCast(x0), 0, w, h, rows.ptr, &info, c.DIB_RGB_COLORS, c.SRCCOPY);
    }

    fn openD3d12(self: *Window) d3d12.Error!void {
        const renderer = try self.gpa.create(d3d12.Renderer);
        errdefer self.gpa.destroy(renderer);
        renderer.* = try .init(self.gpa, @ptrCast(self.hwnd));
        self.d3d12 = renderer;
    }

    fn closeD3d12(self: *Window) void {
        const d = self.d3d12 orelse return;
        d.deinit();
        self.gpa.destroy(d);
        self.d3d12 = null;
    }

    fn actualState(self: *Window) core.WindowState {
        return .{
            .fullscreen = self.full_screen,
            .maximized = !self.full_screen and c.IsZoomed(self.hwnd) != 0,
            .minimized = c.IsIconic(self.hwnd) != 0,
            .always_on_top = c.GetWindowLongPtrW(self.hwnd, c.GWL_EXSTYLE) & c.WS_EX_TOPMOST != 0,
        };
    }

    /// The window put in the state the app asks for, if that changed.
    fn updateState(self: *Window) void {
        const want = self.state.sync(self.ui) orelse return;
        const is = self.actualState();
        if (want.always_on_top != is.always_on_top) {
            const after: c.HWND = @ptrFromInt(if (want.always_on_top) hwnd_topmost else hwnd_notopmost);
            _ = c.SetWindowPos(self.hwnd, after, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
        }
        if (want.fullscreen != self.full_screen) self.setFullScreen(want.fullscreen);
        if (want.fullscreen) return;
        if (want.minimized) {
            if (!is.minimized) _ = c.ShowWindow(self.hwnd, c.SW_MINIMIZE);
        } else if (want.maximized) {
            if (!is.maximized or is.minimized) _ = c.ShowWindow(self.hwnd, c.SW_MAXIMIZE);
        } else if (is.maximized or is.minimized) _ = c.ShowWindow(self.hwnd, c.SW_RESTORE);
    }

    /// Borderless over its monitor, or back as it was.
    fn setFullScreen(self: *Window, on: bool) void {
        if (on) {
            self.saved_placement = std.mem.zeroes(c.WINDOWPLACEMENT);
            self.saved_placement.length = @sizeOf(c.WINDOWPLACEMENT);
            _ = c.GetWindowPlacement(self.hwnd, &self.saved_placement);
            self.saved_style = c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE);
            var mi = std.mem.zeroes(c.MONITORINFO);
            mi.cbSize = @sizeOf(c.MONITORINFO);
            if (c.GetMonitorInfoW(c.MonitorFromWindow(self.hwnd, c.MONITOR_DEFAULTTONEAREST), &mi) == 0) return;
            self.full_screen = true;
            _ = c.SetWindowLongPtrW(self.hwnd, c.GWL_STYLE, self.saved_style & ~@as(c.LONG_PTR, c.WS_OVERLAPPEDWINDOW));
            const r = mi.rcMonitor;
            _ = c.SetWindowPos(self.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED);
        } else {
            self.full_screen = false;
            _ = c.SetWindowLongPtrW(self.hwnd, c.GWL_STYLE, self.saved_style);
            _ = c.SetWindowPlacement(self.hwnd, &self.saved_placement);
            _ = c.SetWindowPos(self.hwnd, null, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED);
        }
    }

    /// The title bar light or dark, as the window's content (Windows 10
    /// 20H1 and later).
    fn updateScheme(self: *Window) void {
        const scheme = self.ui.colorScheme();
        if (self.scheme == scheme) return;
        self.scheme = scheme;
        const dark: c.BOOL = @intFromBool(scheme == .dark);
        _ = c.DwmSetWindowAttribute(self.hwnd, 20, &dark, @sizeOf(c.BOOL)); // DWMWA_USE_IMMERSIVE_DARK_MODE
    }

    /// Shows the cursor the window asks for, while the pointer is over the
    /// client area (`force`: even if it did not change).
    fn updateCursor(self: *Window, force: bool) void {
        const want = self.ui.mouseCursor();
        if (want == self.cursor and !force) return;
        var p: c.POINT = undefined;
        if (c.GetCursorPos(&p) == 0 or c.WindowFromPoint(p) != self.hwnd) return;
        _ = c.ScreenToClient(self.hwnd, &p);
        var r: c.RECT = undefined;
        _ = c.GetClientRect(self.hwnd, &r);
        if (p.x < r.left or p.y < r.top or p.x >= r.right or p.y >= r.bottom) return;
        self.cursor = want;
        _ = c.SetCursor(if (want == .none) null else c.LoadCursorW(null, @ptrFromInt(systemCursor(want))));
    }

    // ---- Input ----

    /// A position in the client area (pixels), in logical pixels.
    fn logical(self: *const Window, x: i32, y: i32) core.Point {
        const s = self.software.scale_factor;
        return .{ .x = @as(f32, @floatFromInt(x)) / s, .y = @as(f32, @floatFromInt(y)) / s };
    }

    fn pointAt(self: *const Window, lparam: c.LPARAM) core.Point {
        const bits: usize = @bitCast(lparam);
        const x: i16 = @bitCast(@as(u16, @truncate(bits)));
        const y: i16 = @bitCast(@as(u16, @truncate(bits >> 16)));
        return self.logical(x, y);
    }

    fn mouseButton(self: *Window, button: input.PointerButton, pressed: bool, wparam: c.WPARAM, lparam: c.LPARAM) void {
        const p = self.pointAt(lparam);
        if (pressed) {
            // The keyboard back from a native view over the window (a web
            // view).
            if (c.GetFocus() != self.hwnd) _ = c.SetFocus(self.hwnd);
            // Keep the events while a button is held, outside the window too.
            _ = c.SetCapture(self.hwnd);
            self.ui.dispatchPointer(.{ .pressed = .{ .position = p, .button = button, .modifiers = modifiers() } });
        } else {
            self.ui.dispatchPointer(.{ .released = .{ .position = p, .button = button } });
            const held = c.MK_LBUTTON | c.MK_RBUTTON | c.MK_MBUTTON | c.MK_XBUTTON1 | c.MK_XBUTTON2;
            if (wparam & held == 0) _ = c.ReleaseCapture();
        }
        self.updateCursor(false);
    }

    /// A touch screen's finger, to the core (the first one works as the
    /// mouse, two pinch). False for other pointers.
    fn touch(self: *Window, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) bool {
        const id: u32 = @truncate(wparam & 0xffff);
        var kind: c.POINTER_INPUT_TYPE = 0;
        if (c.GetPointerType(id, &kind) == 0 or kind != c.PT_TOUCH) return false;
        const bits: usize = @bitCast(lparam);
        var p: c.POINT = .{ .x = @as(i16, @bitCast(@as(u16, @truncate(bits)))), .y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))) };
        _ = c.ScreenToClient(self.hwnd, &p);
        gestures.dispatchTouch(self.ui, id, switch (message) {
            c.WM_POINTERDOWN => .down,
            c.WM_POINTERUPDATE => .moved,
            c.WM_POINTERUP => .up,
            else => .cancelled,
        }, self.logical(p.x, p.y));
        return true;
    }

    fn mouseMoved(self: *Window, lparam: c.LPARAM) void {
        if (!self.tracking_mouse) {
            // Be told when the pointer leaves.
            var track: c.TRACKMOUSEEVENT = .{ .cbSize = @sizeOf(c.TRACKMOUSEEVENT), .dwFlags = c.TME_LEAVE, .hwndTrack = self.hwnd, .dwHoverTime = 0 };
            self.tracking_mouse = c.TrackMouseEvent(&track) != 0;
        }
        self.ui.dispatchPointer(.{ .moved = .{ .position = self.pointAt(lparam) } });
        self.updateCursor(false);
    }

    /// Logical pixels scrolled per wheel notch.
    const wheel_step = 40;

    fn wheel(self: *Window, horizontal: bool, wparam: c.WPARAM, lparam: c.LPARAM) void {
        // The position is on the screen.
        const bits: usize = @bitCast(lparam);
        var p: c.POINT = .{ .x = @as(i16, @bitCast(@as(u16, @truncate(bits)))), .y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))) };
        _ = c.ScreenToClient(self.hwnd, &p);
        const notches = @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(wparam >> 16)))))) / 120;
        const delta: core.Point = if (horizontal) .{ .x = -notches * wheel_step, .y = 0 } else .{ .x = 0, .y = notches * wheel_step };
        self.ui.dispatchPointer(.{ .wheel = .{ .position = self.logical(p.x, p.y), .delta = delta } });
    }

    /// A key pressed: special keys and shortcuts (text comes as WM_CHAR).
    /// Whether it was handled.
    fn keyDown(self: *Window, vk: c.WPARAM, lparam: c.LPARAM, pressed: bool) bool {
        const mods = modifiers();
        const kind: input.KeyEventKind = if (pressed) .pressed else .released;
        const repeat = pressed and (@as(usize, @bitCast(lparam)) >> 30) & 1 != 0;
        if (specialKey(vk, mods)) |text| {
            self.ui.dispatchKey(kind, .{ .text = text, .modifiers = mods, .repeat = repeat });
            return true;
        }
        // Shortcuts (Ctrl+C, Ctrl+S, ...) produce no text: send the key.
        // (Ctrl+Alt is AltGr, which types text.)
        if (mods.control and !mods.alt) {
            const letter: ?u8 = switch (vk) {
                'A'...'Z' => @intCast(vk - 'A' + 'a'),
                '0'...'9' => @intCast(vk),
                else => null,
            };
            if (letter) |ch| {
                self.ui.dispatchKey(kind, .{ .text = ascii[ch..][0..1], .modifiers = mods, .repeat = repeat });
                return true;
            }
        }
        return false;
    }

    /// A UTF-16 unit of typed text (WM_CHAR).
    fn char(self: *Window, unit: u16) void {
        if (std.unicode.utf16IsHighSurrogate(unit)) {
            self.high_surrogate = unit;
            return;
        }
        const cp: u21 = if (std.unicode.utf16IsLowSurrogate(unit)) blk: {
            defer self.high_surrogate = 0;
            if (self.high_surrogate == 0) return;
            break :blk std.unicode.utf16DecodeSurrogatePair(&.{ self.high_surrogate, unit }) catch return;
        } else unit;
        // Control characters come as special keys (WM_KEYDOWN).
        if (cp < 0x20 or cp == 0x7f) return;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        self.ui.dispatchKey(.pressed, .{ .text = buf[0..n] });
        self.ui.dispatchKey(.released, .{ .text = buf[0..n] });
    }

    /// The input method's composition changed (WM_IME_COMPOSITION).
    fn imeComposition(self: *Window, lparam: c.LPARAM) void {
        const himc = c.ImmGetContext(self.hwnd) orelse return;
        defer _ = c.ImmReleaseContext(self.hwnd, himc);
        const flags: u32 = @truncate(@as(usize, @bitCast(lparam)));
        var buf: [256]u16 = undefined;
        var utf8: [1024]u8 = undefined;
        if (flags & c.GCS_RESULTSTR != 0) {
            const text = compositionString(himc, c.GCS_RESULTSTR, &buf, &utf8);
            if (self.composing) {
                self.composing = false;
                self.ui.dispatchPreedit("", 0);
            }
            if (text.len > 0) {
                self.ui.dispatchKey(.pressed, .{ .text = text });
                self.ui.dispatchKey(.released, .{ .text = text });
            }
        }
        if (flags & c.GCS_COMPSTR != 0) {
            const text = compositionString(himc, c.GCS_COMPSTR, &buf, &utf8);
            // The caret: UTF-16 units to bytes.
            var cursor = text.len;
            if (flags & c.GCS_CURSORPOS != 0) {
                const units: usize = @intCast(@max(0, c.ImmGetCompositionStringW(himc, c.GCS_CURSORPOS, null, 0)));
                var i: usize = 0;
                var counted: usize = 0;
                while (i < text.len and counted < units) {
                    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                    counted += if (len == 4) 2 else 1;
                    i += len;
                }
                cursor = @min(i, text.len);
            }
            self.composing = text.len > 0;
            self.ui.dispatchPreedit(text, cursor);
        }
    }

    /// Places the input method's candidate and composition windows by the
    /// caret.
    fn placeImeWindows(self: *Window) void {
        const r = self.ui.ime_cursor_rect orelse return;
        const himc = c.ImmGetContext(self.hwnd) orelse return;
        defer _ = c.ImmReleaseContext(self.hwnd, himc);
        const s = self.software.scale_factor;
        const x: c.LONG = @intFromFloat(@round(r.x * s));
        const y: c.LONG = @intFromFloat(@round(r.y * s));
        const bottom: c.LONG = @intFromFloat(@round((r.y + r.height) * s));
        var composition = std.mem.zeroes(c.COMPOSITIONFORM);
        composition.dwStyle = c.CFS_POINT;
        composition.ptCurrentPos = .{ .x = x, .y = y };
        _ = c.ImmSetCompositionWindow(himc, &composition);
        var candidate = std.mem.zeroes(c.CANDIDATEFORM);
        candidate.dwStyle = c.CFS_EXCLUDE;
        candidate.ptCurrentPos = .{ .x = x, .y = bottom };
        candidate.rcArea = .{ .left = x, .top = y, .right = x + @as(c.LONG, @intFromFloat(@max(1, @round(r.width * s)))), .bottom = bottom };
        _ = c.ImmSetCandidateWindow(himc, &candidate);
    }

    /// The window's messages; null: the default handling.
    fn handle(self: *Window, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) ?c.LRESULT {
        switch (message) {
            c.WM_CLOSE => {
                // The window stays open: `run` returns and the application
                // destroys it.
                self.closed = true;
                return 0;
            },
            c.WM_SIZE => {
                if (self.creating) return 0;
                // Maximized, minimized or restored, perhaps by the user.
                self.state.report(self.ui, self.actualState());
                if (wparam == c.SIZE_MINIMIZED) return 0;
                self.syncSize() catch {
                    log.err("could not resize the framebuffer", .{});
                    return 0;
                };
                // Also during a live resize, when the event loop is blocked:
                // draw now.
                core.updateTimersAndAnimations(now());
                core.runChangeHandlers();
                self.render() catch log.err("could not draw the window", .{});
                return 0;
            },
            c.WM_DPICHANGED => {
                // The system suggests a size for the new DPI.
                const r: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = c.SetWindowPos(self.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
                return 0;
            },
            c.WM_PAINT => {
                var ps: c.PAINTSTRUCT = undefined;
                const dc = c.BeginPaint(self.hwnd, &ps);
                if (self.d3d12 == null) self.blit(dc, 0, 0, self.pixel_width, self.pixel_height);
                _ = c.EndPaint(self.hwnd, &ps);
                return 0;
            },
            c.WM_ERASEBKGND => return 1,
            c.WM_MOUSEMOVE => self.mouseMoved(lparam),
            c.WM_MOUSELEAVE => {
                self.tracking_mouse = false;
                self.ui.dispatchPointer(.exit);
            },
            c.WM_LBUTTONDOWN => self.mouseButton(.left, true, wparam, lparam),
            c.WM_LBUTTONUP => self.mouseButton(.left, false, wparam, lparam),
            c.WM_RBUTTONDOWN => self.mouseButton(.right, true, wparam, lparam),
            c.WM_RBUTTONUP => self.mouseButton(.right, false, wparam, lparam),
            c.WM_MBUTTONDOWN => self.mouseButton(.middle, true, wparam, lparam),
            c.WM_MBUTTONUP => self.mouseButton(.middle, false, wparam, lparam),
            c.WM_XBUTTONDOWN => {
                self.mouseButton(.other, true, wparam, lparam);
                return 1;
            },
            c.WM_XBUTTONUP => {
                self.mouseButton(.other, false, wparam, lparam);
                return 1;
            },
            // Fingers on a touch screen (taken: not also as the mouse);
            // a mouse or a pen goes on as mouse messages.
            c.WM_POINTERDOWN, c.WM_POINTERUPDATE, c.WM_POINTERUP, c.WM_POINTERCAPTURECHANGED => return if (self.touch(message, wparam, lparam)) 0 else null,
            c.WM_MOUSEWHEEL => self.wheel(false, wparam, lparam),
            c.WM_MOUSEHWHEEL => self.wheel(true, wparam, lparam),
            c.WM_KEYDOWN => _ = self.keyDown(wparam, lparam, true),
            c.WM_KEYUP => _ = self.keyDown(wparam, lparam, false),
            // Alt+F4 and the window menu stay the system's.
            c.WM_SYSKEYDOWN => return if (self.keyDown(wparam, lparam, true)) 0 else null,
            c.WM_SYSKEYUP => return if (self.keyDown(wparam, lparam, false)) 0 else null,
            c.WM_CHAR => self.char(@truncate(wparam)),
            c.WM_IME_SETCONTEXT => {
                // Composed text is shown in place, not in the system's window.
                const isc_showuicompositionwindow: usize = 0x80000000;
                return c.DefWindowProcW(self.hwnd, message, wparam, @bitCast(@as(usize, @bitCast(lparam)) & ~isc_showuicompositionwindow));
            },
            c.WM_IME_STARTCOMPOSITION => self.placeImeWindows(),
            c.WM_IME_COMPOSITION => self.imeComposition(lparam),
            c.WM_IME_ENDCOMPOSITION => if (self.composing) {
                self.composing = false;
                self.ui.dispatchPreedit("", 0);
            },
            c.WM_SETCURSOR => {
                if (@as(u16, @truncate(@as(usize, @bitCast(lparam)))) != c.HTCLIENT) return null;
                self.updateCursor(true);
                return 1;
            },
            else => return null,
        }
        return 0;
    }
};

const step_ = step;

/// `open-url`: the shell opens it with the application for it.
fn openUrl(_: ?*anyopaque, url: []const u8) bool {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, url) catch return false;
    defer std.heap.page_allocator.free(wide);
    const r = c.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), wide.ptr, null, null, c.SW_SHOWNORMAL);
    return @intFromPtr(r) > 32;
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (message == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const w: *Window = @ptrCast(@alignCast(cs.lpCreateParams));
        w.hwnd = hwnd;
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(w)));
        return c.DefWindowProcW(hwnd, message, wparam, lparam);
    }
    const data = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (data != 0) {
        const w: *Window = @ptrFromInt(@as(usize, @bitCast(data)));
        if (w.handle(message, wparam, lparam)) |result| return result;
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

/// The composition's string `which` (GCS_COMPSTR, GCS_RESULTSTR), in UTF-8
/// (truncated if longer than `utf8`).
fn compositionString(himc: c.HIMC, which: c.DWORD, buf: []u16, utf8: []u8) []const u8 {
    const bytes = c.ImmGetCompositionStringW(himc, which, buf.ptr, @intCast(buf.len * 2));
    if (bytes <= 0) return "";
    const units = buf[0..@min(buf.len, @as(usize, @intCast(bytes)) / 2)];
    var len: usize = 0;
    var it = std.unicode.Utf16LeIterator.init(units);
    while (it.nextCodepoint() catch null) |cp| {
        const n = std.unicode.utf8CodepointSequenceLength(cp) catch break;
        if (len + n > utf8.len) break;
        _ = std.unicode.utf8Encode(cp, utf8[len..]) catch break;
        len += n;
    }
    return utf8[0..len];
}

const ascii: [128]u8 = blk: {
    var a: [128]u8 = undefined;
    for (&a, 0..) |*ch, i| ch.* = i;
    break :blk a;
};

fn keyDown(vk: c_int) bool {
    return c.GetKeyState(vk) < 0;
}

fn modifiers() input.Modifiers {
    return .{
        .shift = keyDown(c.VK_SHIFT),
        .control = keyDown(c.VK_CONTROL),
        .alt = keyDown(c.VK_MENU),
        .meta = keyDown(c.VK_LWIN) or keyDown(c.VK_RWIN),
    };
}

/// zigulee's code for a special key.
fn specialKey(vk: c.WPARAM, mods: input.Modifiers) ?[]const u8 {
    return switch (vk) {
        c.VK_BACK => Key.backspace,
        c.VK_TAB => if (mods.shift) Key.back_tab else Key.tab,
        c.VK_RETURN => Key.@"return",
        c.VK_ESCAPE => Key.escape,
        c.VK_DELETE => Key.delete,
        c.VK_LEFT => Key.left_arrow,
        c.VK_RIGHT => Key.right_arrow,
        c.VK_UP => Key.up_arrow,
        c.VK_DOWN => Key.down_arrow,
        c.VK_HOME => Key.home,
        c.VK_END => Key.end,
        c.VK_PRIOR => Key.page_up,
        c.VK_NEXT => Key.page_down,
        else => null,
    };
}

/// The system cursor (IDC_*) for a cursor shape.
fn systemCursor(cursor: input.MouseCursor) usize {
    return switch (cursor) {
        .default, .none => 32512, // arrow
        .text => 32513, // I-beam
        .wait => 32514,
        .crosshair => 32515,
        .nwse_resize => 32642,
        .nesw_resize => 32643,
        .col_resize, .ew_resize => 32644,
        .row_resize, .ns_resize => 32645,
        .move, .grab, .grabbing => 32646, // size all
        .not_allowed => 32648,
        .pointer => 32649, // hand
        .progress => 32650, // arrow and hourglass
        .help => 32651,
    };
}

/// The clipboard's text (its line ends become \n).
fn getClipboard(_: ?*anyopaque, gpa: Allocator) ?[]u8 {
    if (c.OpenClipboard(null) == 0) return null;
    defer _ = c.CloseClipboard();
    const handle = c.GetClipboardData(c.CF_UNICODETEXT) orelse return null;
    const ptr = c.GlobalLock(handle) orelse return null;
    defer _ = c.GlobalUnlock(handle);
    const wide = std.mem.span(@as([*:0]const u16, @ptrCast(@alignCast(ptr))));
    const text = std.unicode.utf16LeToUtf8Alloc(gpa, wide) catch return null;
    // \r\n to \n, in place.
    var len: usize = 0;
    for (text, 0..) |ch, i| {
        if (ch == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
        text[len] = ch;
        len += 1;
    }
    return gpa.realloc(text, len) catch text[0..len];
}

/// Puts text on the clipboard (with \r\n line ends, as Windows has them).
fn setClipboard(_: ?*anyopaque, text: []const u8) void {
    const gpa = std.heap.page_allocator;
    var crlf: std.ArrayList(u8) = .empty;
    defer crlf.deinit(gpa);
    for (text, 0..) |ch, i| {
        if (ch == '\n' and (i == 0 or text[i - 1] != '\r')) crlf.append(gpa, '\r') catch return;
        crlf.append(gpa, ch) catch return;
    }
    const wide = std.unicode.utf8ToUtf16LeAllocZ(gpa, crlf.items) catch return;
    defer gpa.free(wide);
    const bytes = (wide.len + 1) * 2;
    const handle = c.GlobalAlloc(c.GMEM_MOVEABLE, bytes) orelse return;
    const ptr: [*]u16 = @ptrCast(@alignCast(c.GlobalLock(handle) orelse {
        _ = c.GlobalFree(handle);
        return;
    }));
    @memcpy(ptr[0 .. wide.len + 1], wide[0 .. wide.len + 1]);
    _ = c.GlobalUnlock(handle);
    if (c.OpenClipboard(null) == 0) {
        _ = c.GlobalFree(handle);
        return;
    }
    defer _ = c.CloseClipboard();
    _ = c.EmptyClipboard();
    // The clipboard owns the memory from now on.
    if (c.SetClipboardData(c.CF_UNICODETEXT, handle) == null) _ = c.GlobalFree(handle);
}

// ---- Tests (on Windows) ----

const testing = std.testing;

/// The pixel the window shows at (x, y) logical pixels.
fn shownPixel(w: *Window, x: f32, y: f32) core.Color {
    const s = w.scaleFactor();
    const px: usize = @intFromFloat(x * s);
    const py: usize = @intFromFloat(y * s);
    const p = w.shown[py * w.pixel_width + px];
    return .{ .r = p.r, .g = p.g, .b = p.b, .a = p.a };
}

/// A mouse message's position: (x, y) logical pixels in the client area.
fn at(w: *Window, x: f32, y: f32) c.LPARAM {
    const s = w.scaleFactor();
    const px: u16 = @intFromFloat(x * s);
    const py: u16 = @intFromFloat(y * s);
    return @intCast(@as(u32, px) | @as(u32, py) << 16);
}

fn send(w: *Window, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) void {
    _ = c.SendMessageW(w.hwnd, message, wparam, lparam);
}

/// Holds Ctrl down (for this thread's key state) while `body` runs.
fn withControl(w: *Window, vk: c.WPARAM) void {
    var state: [256]u8 = undefined;
    _ = c.GetKeyboardState(&state);
    var down = state;
    down[c.VK_CONTROL] = 0x80;
    _ = c.SetKeyboardState(&down);
    send(w, c.WM_KEYDOWN, vk, 0);
    _ = c.SetKeyboardState(&state);
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
    try init();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    const w = try Window.create(testing.allocator, &t.ui, .{ .title = "test", .hidden = true, .renderer = .software });
    defer w.destroy();

    try step(0);
    try testing.expect(!t.ui.redraw_requested);
    try testing.expectEqual(core.Size{ .width = 120, .height = 80 }, t.ui.size());
    try testing.expectEqual(core.Color.rgb(0xff0000), shownPixel(w, 20, 20));
    try testing.expectEqual(core.Color.white, shownPixel(w, 100, 70));

    // A click on the button turns it blue on the next frame.
    send(w, c.WM_LBUTTONDOWN, c.MK_LBUTTON, at(w, 30, 20));
    send(w, c.WM_LBUTTONUP, 0, at(w, 30, 20));
    try step(0);
    try testing.expectEqual(@as(usize, 1), t.clicks);
    try testing.expectEqual(core.Color.rgb(0x0000ff), shownPixel(w, 20, 20));

    // Text (with a character outside the BMP: two WM_CHARs), special keys
    // and shortcuts reach the focused item.
    t.keys.focus();
    for ([_]u16{ 'h', 0xe9, 0xd83d, 0xde00 }) |unit| send(w, c.WM_CHAR, unit, 0);
    send(w, c.WM_KEYDOWN, c.VK_RETURN, 0);
    send(w, c.WM_CHAR, '\r', 0); // what TranslateMessage adds: not text
    send(w, c.WM_KEYDOWN, c.VK_LEFT, 0);
    withControl(w, 'C');
    try testing.expectEqualStrings("hé😀" ++ Key.@"return" ++ Key.left_arrow ++ "c", t.typed[0..t.typed_len]);

    // Resizing the window resizes the zigulee window, and redraws.
    var frame: c.RECT = undefined;
    _ = c.GetWindowRect(w.hwnd, &frame);
    _ = c.SetWindowPos(w.hwnd, null, 0, 0, frame.right - frame.left + 80, frame.bottom - frame.top + 70, c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    var client: c.RECT = undefined;
    _ = c.GetClientRect(w.hwnd, &client);
    const s = w.scaleFactor();
    try testing.expectEqual(@as(f32, @floatFromInt(client.right)) / s, t.ui.size().width);
    try testing.expect(t.ui.size().width > 120 and t.ui.size().height > 80);
    try testing.expectEqual(core.Color.white, shownPixel(w, t.ui.size().width - 5, t.ui.size().height - 5));

    // Closing ends the loop (the window stays until destroyed).
    send(w, c.WM_CLOSE, 0, 0);
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
    // steps at most: system messages may wake one early).
    var steps: usize = 0;
    while (!fired and now() - start < 1000) : (steps += 1) try step(1000);
    try testing.expect(fired);
    const elapsed = now() - start;
    if (elapsed < 45 or steps >= 10) {
        std.debug.print("timer fired after {d} ms, {d} steps\n", .{ elapsed, steps });
        return error.TestUnexpectedResult;
    }

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
    try testing.expectEqual(core.Color.white, shownPixel(w, 30, 15));
}

test "the title bar follows the window's color scheme" {
    try init();
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 60, .height = 30 });
    defer ui.deinit();
    const w = try Window.create(testing.allocator, &ui, .{ .hidden = true, .renderer = .software });
    defer w.destroy();
    try testing.expectEqual(core.ColorScheme.light, w.scheme.?);
    // A dark background (a dark theme) makes it dark.
    ui.root.background.set(.color(.rgb(0x202020)));
    try step(0);
    try testing.expectEqual(core.ColorScheme.dark, w.scheme.?);
}

test "the clipboard is the system's, with Windows line ends" {
    try init();
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 60, .height = 30 });
    defer ui.deinit();
    const w = try Window.create(testing.allocator, &ui, .{ .hidden = true, .renderer = .software });
    defer w.destroy();
    ui.clipboard.?.setFn(null, "zigulee\nclipboard é");
    const text = ui.clipboardText(testing.allocator) orelse {
        log.info("no clipboard: skipped", .{});
        return error.SkipZigTest;
    };
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("zigulee\nclipboard é", text);
}

test "a Direct3D 12 window draws what the software renderer draws" {
    try init();
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    const w = Window.create(testing.allocator, &t.ui, .{ .hidden = true, .renderer = .d3d12 }) catch |err| {
        log.info("Direct3D 12 unavailable ({t}): skipped", .{err});
        return error.SkipZigTest;
    };
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
        try w.d3d12.?.readPixels(drawn);
        @memset(expected, .transparent);
        _ = try software.renderWindow(&t.ui, .init(expected, w.pixel_width, w.pixel_height), .full);
        var off: usize = 0;
        for (expected, drawn) |e, a| {
            inline for (.{ "r", "g", "b", "a" }) |ch| {
                if (@abs(@as(i16, @field(e, ch)) - @field(a, ch)) > 3) off += 1;
            }
        }
        try testing.expectEqual(@as(usize, 0), off);
    }
}

// ---- Drops from other applications ----

/// An OLE drop target: files (`CF_HDROP`) and text (`CF_UNICODETEXT`)
/// dragged over the window from other applications. Owned by its window
/// (its reference count only answers OLE).
const DropTarget = struct {
    com: c.IDropTarget,
    owner: *Window,
    refs: u32 = 1,
    /// What the drag over the window carries (`dnd.file_kind`, ...).
    kind: []const u8 = "",

    const vtable: c.IDropTargetVtbl = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .DragEnter = dragEnter,
        .DragOver = dragOver,
        .DragLeave = dragLeave,
        .Drop = drop,
    };

    const iid_unknown = guidOf(0x00000000, 0x0000, 0x0000, .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 });
    const iid_drop_target = guidOf(0x00000122, 0x0000, 0x0000, .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 });

    fn guidOf(a: u32, b: u16, cc: u16, d: [8]u8) c.GUID {
        return .{ .Data1 = a, .Data2 = b, .Data3 = cc, .Data4 = d };
    }

    fn of(p: ?*c.IDropTarget) *DropTarget {
        return @fieldParentPtr("com", p.?);
    }

    fn queryInterface(p: ?*c.IDropTarget, riid: ?*const c.IID, out: ?*?*anyopaque) callconv(.c) c.HRESULT {
        const iid = riid.?.*;
        if (std.meta.eql(iid, iid_unknown) or std.meta.eql(iid, iid_drop_target)) {
            out.?.* = p;
            of(p).refs += 1;
            return c.S_OK;
        }
        out.?.* = null;
        return c.E_NOINTERFACE;
    }

    fn addRef(p: ?*c.IDropTarget) callconv(.c) c.ULONG {
        const self = of(p);
        self.refs += 1;
        return self.refs;
    }

    fn release(p: ?*c.IDropTarget) callconv(.c) c.ULONG {
        const self = of(p);
        self.refs -|= 1;
        return self.refs;
    }

    fn dragEnter(p: ?*c.IDropTarget, data: ?*c.IDataObject, _: c.DWORD, pt: c.POINTL, effect: ?*c.DWORD) callconv(.c) c.HRESULT {
        const self = of(p);
        self.kind = if (has(data, c.CF_HDROP)) dnd.file_kind else if (has(data, c.CF_UNICODETEXT)) dnd.text_kind else "";
        return self.moved(pt, effect);
    }

    fn dragOver(p: ?*c.IDropTarget, _: c.DWORD, pt: c.POINTL, effect: ?*c.DWORD) callconv(.c) c.HRESULT {
        return of(p).moved(pt, effect);
    }

    fn dragLeave(p: ?*c.IDropTarget) callconv(.c) c.HRESULT {
        dnd.externalLeft(of(p).owner.ui);
        return c.S_OK;
    }

    fn drop(p: ?*c.IDropTarget, data: ?*c.IDataObject, _: c.DWORD, pt: c.POINTL, effect: ?*c.DWORD) callconv(.c) c.HRESULT {
        const self = of(p);
        const where = self.point(pt);
        const gpa = self.owner.gpa;
        var taken = false;
        if (std.mem.eql(u8, self.kind, dnd.file_kind)) {
            if (filesOf(gpa, data)) |paths| {
                defer gpa.free(paths);
                taken = dnd.externalDropped(self.owner.ui, dnd.file_kind, paths, where);
            }
        } else if (std.mem.eql(u8, self.kind, dnd.text_kind)) {
            if (textOf(gpa, data)) |text| {
                defer gpa.free(text);
                taken = dnd.externalDropped(self.owner.ui, dnd.text_kind, text, where);
            }
        } else dnd.externalLeft(self.owner.ui);
        if (effect) |e| e.* = if (taken) c.DROPEFFECT_COPY else c.DROPEFFECT_NONE;
        return c.S_OK;
    }

    fn moved(self: *DropTarget, pt: c.POINTL, effect: ?*c.DWORD) c.HRESULT {
        const ok = self.kind.len > 0 and dnd.externalMoved(self.owner.ui, &.{self.kind}, self.point(pt));
        if (effect) |e| e.* = if (ok) c.DROPEFFECT_COPY else c.DROPEFFECT_NONE;
        return c.S_OK;
    }

    /// From the screen to the window, in logical pixels.
    fn point(self: *DropTarget, pt: c.POINTL) core.Point {
        var p: c.POINT = .{ .x = pt.x, .y = pt.y };
        _ = c.ScreenToClient(self.owner.hwnd, &p);
        return self.owner.logical(p.x, p.y);
    }

    fn format(cf: c_uint) c.FORMATETC {
        return .{ .cfFormat = @intCast(cf), .ptd = null, .dwAspect = c.DVASPECT_CONTENT, .lindex = -1, .tymed = c.TYMED_HGLOBAL };
    }

    fn has(data: ?*c.IDataObject, cf: c_uint) bool {
        const d = data orelse return false;
        var f = format(cf);
        return d.*.lpVtbl.*.QueryGetData.?(d, &f) == c.S_OK;
    }

    /// The data of format `cf` (the caller releases it).
    fn withData(data: ?*c.IDataObject, cf: c_uint) ?c.STGMEDIUM {
        const d = data orelse return null;
        var f = format(cf);
        var medium: c.STGMEDIUM = undefined;
        if (d.*.lpVtbl.*.GetData.?(d, &f, &medium) < 0) return null;
        return medium;
    }

    /// The paths dropped, one per line (owned).
    fn filesOf(gpa: Allocator, data: ?*c.IDataObject) ?[]u8 {
        var medium = withData(data, c.CF_HDROP) orelse return null;
        defer c.ReleaseStgMedium(&medium);
        const hdrop: c.HDROP = @ptrCast(@alignCast(medium.unnamed_0.hGlobal));
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const n = c.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
        var buf: [32768]u16 = undefined;
        for (0..n) |i| {
            const len = c.DragQueryFileW(hdrop, @intCast(i), &buf, buf.len);
            if (len == 0) continue;
            if (out.items.len > 0) out.append(gpa, '\n') catch return null;
            const utf8 = std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..len]) catch return null;
            defer gpa.free(utf8);
            out.appendSlice(gpa, utf8) catch return null;
        }
        return out.toOwnedSlice(gpa) catch null;
    }

    /// The text dropped (owned).
    fn textOf(gpa: Allocator, data: ?*c.IDataObject) ?[]u8 {
        var medium = withData(data, c.CF_UNICODETEXT) orelse return null;
        defer c.ReleaseStgMedium(&medium);
        const mem = medium.unnamed_0.hGlobal;
        const ptr: ?[*:0]const u16 = @ptrCast(@alignCast(c.GlobalLock(mem)));
        defer _ = c.GlobalUnlock(mem);
        const wide = std.mem.span(ptr orelse return null);
        return std.unicode.utf16LeToUtf8Alloc(gpa, wide) catch null;
    }
};
