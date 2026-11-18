// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Web views on Linux with WebKitGTK (GTK 3: webkit2gtk-4.1, or 4.0), for
//! the X11 backends (native and SDL3 on X11): each web view is a GTK
//! window of its own, made a child of the zigulee window (its X window,
//! given as a `Host` in the window's `native_view`) and placed over the
//! `WebView` element, in physical pixels.
//!
//! WebKitGTK is loaded at run time (with GTK, which it brings in): without
//! it, `available` is false. GTK talks to the X server over a connection
//! of its own and works through GLib's main loop, which the backend runs
//! with its own (`prepare` and `dispatch` around its poll, or `iterate`
//! now and then). A click in the page gives it the keyboard; the backend
//! takes it back on a click on zigulee's content. Not on Wayland (a window
//! cannot hold another program's surface there) or KMS.

const std = @import("std");
const zigulee = @import("zigulee");
const webview = zigulee.core.webview;
const Native = webview.Provider.Native;
const c = std.c;

const log = std.log.scoped(.zigulee_webkitgtk);

pub const provider: webview.Provider = .{ .vtable = &.{
    .create = create,
    .destroy = destroy,
    .place = place,
    .load_url = loadUrl,
    .load_html = loadHtml,
    .back = back,
    .forward = forward,
    .reload = reload,
    .stop = stop,
    .run_javascript = runJavascript,
} };

/// What a backend puts in `native_view`: its X window, and its physical
/// pixels per logical pixel.
pub const Host = struct {
    window: u32 = 0,
    scale: f32 = 1,
};

const gpa = std.heap.c_allocator;

// ---- The libraries ----

const Widget = opaque {};
const GdkWindow = opaque {};
const Display = opaque {};
const JSValue = opaque {};
const GError = extern struct { domain: u32, code: c_int, message: ?[*:0]const u8 };
const Callback = *const fn () callconv(.c) void;
const AsyncReady = *const fn (?*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) void;

const Fns = struct {
    // GLib and GObject.
    g_main_context_default: *const fn () callconv(.c) *anyopaque,
    g_main_context_acquire: *const fn (*anyopaque) callconv(.c) c_int,
    g_main_context_release: *const fn (*anyopaque) callconv(.c) void,
    g_main_context_prepare: *const fn (*anyopaque, *c_int) callconv(.c) c_int,
    g_main_context_query: *const fn (*anyopaque, c_int, *c_int, [*]c.pollfd, c_int) callconv(.c) c_int,
    g_main_context_check: *const fn (*anyopaque, c_int, [*]c.pollfd, c_int) callconv(.c) c_int,
    g_main_context_dispatch: *const fn (*anyopaque) callconv(.c) void,
    g_main_context_iteration: *const fn (?*anyopaque, c_int) callconv(.c) c_int,
    g_signal_connect_data: *const fn (*anyopaque, [*:0]const u8, Callback, ?*anyopaque, ?*anyopaque, c_int) callconv(.c) c_ulong,
    g_object_unref: *const fn (*anyopaque) callconv(.c) void,
    g_free: *const fn (?*anyopaque) callconv(.c) void,
    g_error_free: *const fn (*GError) callconv(.c) void,
    // GTK and GDK.
    gdk_set_allowed_backends: *const fn ([*:0]const u8) callconv(.c) void,
    gtk_init_check: *const fn (?*c_int, ?*anyopaque) callconv(.c) c_int,
    gtk_window_new: *const fn (c_int) callconv(.c) *Widget,
    gtk_window_move: *const fn (*Widget, c_int, c_int) callconv(.c) void,
    gtk_window_resize: *const fn (*Widget, c_int, c_int) callconv(.c) void,
    gtk_container_add: *const fn (*Widget, *Widget) callconv(.c) void,
    gtk_widget_show: *const fn (*Widget) callconv(.c) void,
    gtk_widget_hide: *const fn (*Widget) callconv(.c) void,
    gtk_widget_realize: *const fn (*Widget) callconv(.c) void,
    gtk_widget_grab_focus: *const fn (*Widget) callconv(.c) void,
    gtk_widget_destroy: *const fn (*Widget) callconv(.c) void,
    gtk_widget_get_window: *const fn (*Widget) callconv(.c) ?*GdkWindow,
    gdk_window_get_scale_factor: *const fn (*GdkWindow) callconv(.c) c_int,
    gdk_x11_window_get_xid: *const fn (*GdkWindow) callconv(.c) c_ulong,
    gdk_x11_get_default_xdisplay: *const fn () callconv(.c) ?*Display,
    // Xlib (GDK's connection).
    XReparentWindow: *const fn (*Display, c_ulong, c_ulong, c_int, c_int) callconv(.c) c_int,
    XSetInputFocus: *const fn (*Display, c_ulong, c_int, c_ulong) callconv(.c) c_int,
    XDefaultRootWindow: *const fn (*Display) callconv(.c) c_ulong,
    XFlush: *const fn (*Display) callconv(.c) c_int,
    // WebKit and JavaScriptCore.
    webkit_web_view_new: *const fn () callconv(.c) *Widget,
    webkit_web_view_load_uri: *const fn (*Widget, [*:0]const u8) callconv(.c) void,
    webkit_web_view_load_html: *const fn (*Widget, [*:0]const u8, ?[*:0]const u8) callconv(.c) void,
    webkit_web_view_go_back: *const fn (*Widget) callconv(.c) void,
    webkit_web_view_go_forward: *const fn (*Widget) callconv(.c) void,
    webkit_web_view_reload: *const fn (*Widget) callconv(.c) void,
    webkit_web_view_stop_loading: *const fn (*Widget) callconv(.c) void,
    webkit_web_view_can_go_back: *const fn (*Widget) callconv(.c) c_int,
    webkit_web_view_can_go_forward: *const fn (*Widget) callconv(.c) c_int,
    webkit_web_view_get_title: *const fn (*Widget) callconv(.c) ?[*:0]const u8,
    webkit_web_view_get_uri: *const fn (*Widget) callconv(.c) ?[*:0]const u8,
    webkit_web_view_evaluate_javascript: *const fn (*Widget, [*]const u8, isize, ?[*:0]const u8, ?[*:0]const u8, ?*anyopaque, AsyncReady, ?*anyopaque) callconv(.c) void,
    webkit_web_view_evaluate_javascript_finish: *const fn (*Widget, *anyopaque, *?*GError) callconv(.c) ?*JSValue,
    webkit_network_error_quark: *const fn () callconv(.c) u32,
    jsc_value_is_undefined: *const fn (*JSValue) callconv(.c) c_int,
    jsc_value_is_string: *const fn (*JSValue) callconv(.c) c_int,
    jsc_value_to_string: *const fn (*JSValue) callconv(.c) ?[*:0]u8,
    jsc_value_to_json: *const fn (*JSValue, c_uint) callconv(.c) ?[*:0]u8,
};

const gtk_window_popup = 1;
// WebKitLoadEvent.
const load_started = 0;
const load_committed = 2;
const load_finished = 3;
const network_error_cancelled = 302;
const revert_to_parent = 2;

var lib: Fns = undefined;
var state: enum { untried, ready, missing } = .untried;

/// WebKitGTK with GTK started, or null without them (tried once).
fn library() ?*const Fns {
    if (state == .untried) {
        state = .missing;
        const handle = c.dlopen("libwebkit2gtk-4.1.so.0", .{ .LAZY = true }) orelse c.dlopen("libwebkit2gtk-4.0.so.37", .{ .LAZY = true }) orelse {
            log.info("WebKitGTK not found: no web views", .{});
            return null;
        };
        // Its dependencies' functions too (GTK, GLib, Xlib, ...).
        inline for (@typeInfo(Fns).@"struct".fields) |f| {
            @field(lib, f.name) = @ptrCast(@alignCast(c.dlsym(handle, f.name ++ "") orelse {
                log.info("WebKitGTK has no {s}: no web views", .{f.name});
                return null;
            }));
        }
        // In the zigulee window's X server (not on Wayland, even if there).
        lib.gdk_set_allowed_backends("x11");
        if (lib.gtk_init_check(null, null) == 0) {
            log.info("GTK cannot start (no X display): no web views", .{});
            return null;
        }
        state = .ready;
    }
    return if (state == .ready) &lib else null;
}

fn connect(instance: *anyopaque, signal: [*:0]const u8, handler: anytype, id: u32) void {
    _ = lib.g_signal_connect_data(instance, signal, @ptrCast(handler), @ptrFromInt(id), null, 0);
}

// ---- GLib's main loop, run with the backend's ----

var max_priority: c_int = 0;
var acquired = false;

/// Fills `fds` with what GLib waits for (when web views were made) and
/// lowers `timeout_ms` to its next deadline; returns how many. The
/// backend polls them with its own, then calls `dispatch`.
pub fn prepare(fds: []c.pollfd, timeout_ms: *?u64) usize {
    if (state != .ready) return 0;
    const ctx = lib.g_main_context_default();
    if (lib.g_main_context_acquire(ctx) == 0) return 0;
    acquired = true;
    const ready = lib.g_main_context_prepare(ctx, &max_priority) != 0;
    var wait: c_int = -1;
    const n: usize = @intCast(@max(0, lib.g_main_context_query(ctx, max_priority, &wait, fds.ptr, @intCast(fds.len))));
    const deadline: ?u64 = if (ready) 0 else if (wait >= 0) @intCast(wait) else null;
    if (deadline) |d| timeout_ms.* = if (timeout_ms.*) |t| @min(t, d) else d;
    return @min(n, fds.len);
}

/// Runs what is ready, after the poll (`fds` as `prepare` gave them, with
/// their results).
pub fn dispatch(fds: []c.pollfd) void {
    if (!acquired) return;
    acquired = false;
    const ctx = lib.g_main_context_default();
    if (lib.g_main_context_check(ctx, max_priority, fds.ptr, @intCast(fds.len)) != 0) lib.g_main_context_dispatch(ctx);
    lib.g_main_context_release(ctx);
}

/// Runs what is ready without waiting, for backends that cannot poll
/// GLib's descriptors (call it every few milliseconds while `active`).
pub fn iterate() void {
    if (state != .ready) return;
    var n: usize = 0;
    while (n < 100 and lib.g_main_context_iteration(null, 0) != 0) n += 1;
}

/// Web views were made (GLib's loop needs running).
pub fn active() bool {
    return state == .ready;
}

// ---- The web views ----

const View = struct {
    id: u32,
    host: ?*Host,
    window: *Widget,
    web: *Widget,
    xid: c_ulong,
    /// The page being loaded failed (WebKit still says it finished).
    failed: bool = false,

    fn native(self: *View) *Native {
        return @ptrCast(self);
    }
};

var views: std.ArrayList(*View) = .empty;
var next_id: u32 = 1;

fn byId(data: ?*anyopaque) ?*View {
    const id: u32 = @intCast(@intFromPtr(data));
    for (views.items) |v| if (v.id == id) return v;
    return null;
}

fn of(native: *Native) *View {
    return @ptrCast(@alignCast(native));
}

fn create(_: ?*anyopaque, native_view: ?*anyopaque, _: *webview.WebView) ?*Native {
    const host: *Host = @ptrCast(@alignCast(native_view orelse return null));
    const l = library() orelse return null;
    const display = l.gdk_x11_get_default_xdisplay() orelse return null;
    const v = gpa.create(View) catch return null;
    const window = l.gtk_window_new(gtk_window_popup);
    const web = l.webkit_web_view_new();
    l.gtk_container_add(window, web);
    l.gtk_widget_show(web);
    l.gtk_widget_realize(window);
    const xid = l.gdk_x11_window_get_xid(l.gtk_widget_get_window(window).?);
    // Inside the zigulee window, hidden until placed.
    _ = l.XReparentWindow(display, xid, host.window, 0, 0);
    _ = l.XFlush(display);
    v.* = .{ .id = next_id, .host = host, .window = window, .web = web, .xid = xid };
    next_id +%= 1;
    views.append(gpa, v) catch {
        l.gtk_widget_destroy(window);
        gpa.destroy(v);
        return null;
    };
    l.gtk_widget_grab_focus(web);
    connect(web, "load-changed", &loadChanged, v.id);
    connect(web, "load-failed", &loadFailed, v.id);
    connect(web, "notify::title", &changed, v.id);
    connect(web, "notify::uri", &changed, v.id);
    connect(web, "web-process-terminated", &crashed, v.id);
    connect(web, "button-press-event", &pressed, v.id);
    return v.native();
}

fn destroy(_: ?*anyopaque, native: *Native) void {
    const v = of(native);
    for (views.items, 0..) |x, i| if (x == v) {
        _ = views.swapRemove(i);
        break;
    };
    lib.gtk_widget_destroy(v.window);
    gpa.destroy(v);
}

/// The zigulee window `host` is going: its web views leave it (hidden), so
/// that they do not go with it behind GTK's back.
pub fn detach(host: *Host) void {
    if (state != .ready) return;
    const display = lib.gdk_x11_get_default_xdisplay() orelse return;
    if (keyboard_in == host) keyboard_in = null;
    for (views.items) |v| if (v.host == host) {
        lib.gtk_widget_hide(v.window);
        _ = lib.XReparentWindow(display, v.xid, lib.XDefaultRootWindow(display), 0, 0);
        v.host = null;
    };
    _ = lib.XFlush(display);
}

/// `rect` (logical pixels) in the host's physical pixels, divided by GTK's
/// own scale.
fn gtkRect(rect: zigulee.core.Rect, scale: f32, gtk_scale: c_int) [4]c_int {
    const s = scale / @as(f32, @floatFromInt(@max(1, gtk_scale)));
    const x0 = @round(rect.x * s);
    const y0 = @round(rect.y * s);
    return .{
        @intFromFloat(x0),
        @intFromFloat(y0),
        @intFromFloat(@max(1, @round((rect.x + rect.width) * s) - x0)),
        @intFromFloat(@max(1, @round((rect.y + rect.height) * s) - y0)),
    };
}

fn place(_: ?*anyopaque, native: *Native, rect: zigulee.core.Rect, visible: bool) void {
    const v = of(native);
    const host = v.host orelse return;
    if (!visible) return lib.gtk_widget_hide(v.window);
    const r = gtkRect(rect, host.scale, lib.gdk_window_get_scale_factor(lib.gtk_widget_get_window(v.window).?));
    lib.gtk_window_move(v.window, r[0], r[1]);
    lib.gtk_window_resize(v.window, r[2], r[3]);
    lib.gtk_widget_show(v.window);
}

fn loadUrl(_: ?*anyopaque, native: *Native, url: []const u8) void {
    const z = gpa.dupeZ(u8, url) catch return;
    defer gpa.free(z);
    lib.webkit_web_view_load_uri(of(native).web, z);
}
fn loadHtml(_: ?*anyopaque, native: *Native, html: []const u8) void {
    const z = gpa.dupeZ(u8, html) catch return;
    defer gpa.free(z);
    lib.webkit_web_view_load_html(of(native).web, z, null);
}
fn back(_: ?*anyopaque, native: *Native) void {
    lib.webkit_web_view_go_back(of(native).web);
}
fn forward(_: ?*anyopaque, native: *Native) void {
    lib.webkit_web_view_go_forward(of(native).web);
}
fn reload(_: ?*anyopaque, native: *Native) void {
    lib.webkit_web_view_reload(of(native).web);
}
fn stop(_: ?*anyopaque, native: *Native) void {
    lib.webkit_web_view_stop_loading(of(native).web);
}

fn runJavascript(_: ?*anyopaque, native: *Native, code: []const u8) void {
    const v = of(native);
    lib.webkit_web_view_evaluate_javascript(v.web, code.ptr, @intCast(code.len), null, null, null, &scriptFinished, @ptrFromInt(v.id));
}

fn scriptFinished(_: ?*anyopaque, result: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const v = byId(data) orelse return;
    var err: ?*GError = null;
    const value = lib.webkit_web_view_evaluate_javascript_finish(v.web, result, &err) orelse {
        const e = err orelse return webview.reportJavaScript(v.native(), "the script could not run", true);
        defer lib.g_error_free(e);
        return webview.reportJavaScript(v.native(), if (e.message) |m| std.mem.span(m) else "the script could not run", true);
    };
    defer lib.g_object_unref(value);
    // Strings as they are, other values as JSON, undefined as "".
    if (lib.jsc_value_is_undefined(value) != 0) return webview.reportJavaScript(v.native(), "", false);
    const text = if (lib.jsc_value_is_string(value) != 0) lib.jsc_value_to_string(value) else lib.jsc_value_to_json(value, 0);
    defer lib.g_free(text);
    webview.reportJavaScript(v.native(), if (text) |t| std.mem.span(t) else "", false);
}

// ---- Events ----

fn loadChanged(_: *Widget, event: c_int, data: ?*anyopaque) callconv(.c) void {
    const v = byId(data) orelse return;
    switch (event) {
        load_started => {
            v.failed = false;
            webview.reportLoading(v.native(), true);
        },
        load_committed => reportState(v),
        load_finished => {
            reportState(v);
            if (v.failed) webview.reportLoading(v.native(), false) else webview.reportFinished(v.native(), null);
        },
        else => {},
    }
}

fn loadFailed(_: *Widget, _: c_int, _: ?[*:0]const u8, err: *GError, data: ?*anyopaque) callconv(.c) c_int {
    const v = byId(data) orelse return 0;
    v.failed = true;
    // Another page asked for before this one loaded: not a failure.
    const cancelled = err.domain == lib.webkit_network_error_quark() and err.code == network_error_cancelled;
    if (!cancelled) webview.reportFinished(v.native(), if (err.message) |m| std.mem.span(m) else "the page could not be loaded");
    // No error page of WebKit's own (as on the other platforms).
    return 1;
}

fn changed(_: *anyopaque, _: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const v = byId(data) orelse return;
    reportState(v);
}

fn crashed(_: *Widget, _: c_int, data: ?*anyopaque) callconv(.c) void {
    const v = byId(data) orelse return;
    webview.reportFinished(v.native(), "the page's process stopped");
}

/// The window whose web view has the keyboard.
var keyboard_in: ?*Host = null;

/// A click in the page: the keyboard goes to it.
fn pressed(_: *Widget, _: *anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    const v = byId(data) orelse return 0;
    const display = lib.gdk_x11_get_default_xdisplay() orelse return 0;
    _ = lib.XSetInputFocus(display, v.xid, revert_to_parent, 0);
    keyboard_in = v.host;
    return 0;
}

/// A click on zigulee's content in `host`: the keyboard comes back from its
/// web view, if one has it (for backends that cannot set the X focus
/// themselves).
pub fn takeKeyboard(host: *Host) void {
    if (keyboard_in != host) return;
    keyboard_in = null;
    const display = lib.gdk_x11_get_default_xdisplay() orelse return;
    _ = lib.XSetInputFocus(display, host.window, revert_to_parent, 0);
    _ = lib.XFlush(display);
}

/// Reports the page's title, address and history as they are.
fn reportState(v: *View) void {
    if (lib.webkit_web_view_get_title(v.web)) |t| webview.reportTitle(v.native(), std.mem.span(t));
    if (lib.webkit_web_view_get_uri(v.web)) |u| {
        const s = std.mem.span(u);
        // A page given as text has no address worth reporting.
        if (!std.mem.startsWith(u8, s, "data:") and !std.mem.eql(u8, s, "about:blank")) webview.reportUrl(v.native(), s);
    }
    webview.reportHistory(v.native(), lib.webkit_web_view_can_go_back(v.web) != 0, lib.webkit_web_view_can_go_forward(v.web) != 0);
}

// ---- Tests ----

const testing = std.testing;

test "placed in physical pixels, over GTK's own scale" {
    const r: zigulee.core.Rect = .{ .x = 10, .y = 20.5, .width = 100, .height = 50 };
    try testing.expectEqual([4]c_int{ 10, 21, 100, 50 }, gtkRect(r, 1, 1));
    try testing.expectEqual([4]c_int{ 15, 31, 150, 75 }, gtkRect(r, 1.5, 1));
    try testing.expectEqual([4]c_int{ 10, 21, 100, 50 }, gtkRect(r, 2, 2));
}

/// Runs GLib's loop until `done()`, at most about 30 s.
fn pump(comptime done: fn (*webview.WebView) bool, view: *webview.WebView) !void {
    for (0..3000) |_| {
        if (done(view)) return;
        iterate();
        testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return error.Timeout;
}

test "a page given as text in WebKitGTK: loaded, its title, JavaScript run in it" {
    const l = library() orelse {
        std.debug.print("no WebKitGTK or no X display: skipped\n", .{});
        return error.SkipZigTest;
    };
    const display = l.gdk_x11_get_default_xdisplay() orelse return error.SkipZigTest;
    // The zigulee window, as an X window of GTK's connection.
    const XFns = struct {
        create: *const fn (*Display, c_ulong, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) callconv(.c) c_ulong,
        map: *const fn (*Display, c_ulong) callconv(.c) c_int,
        destroy: *const fn (*Display, c_ulong) callconv(.c) c_int,
    };
    const x11 = c.dlopen("libX11.so.6", .{ .LAZY = true }) orelse return error.SkipZigTest;
    const xf: XFns = .{
        .create = @ptrCast(@alignCast(c.dlsym(x11, "XCreateSimpleWindow").?)),
        .map = @ptrCast(@alignCast(c.dlsym(x11, "XMapWindow").?)),
        .destroy = @ptrCast(@alignCast(c.dlsym(x11, "XDestroyWindow").?)),
    };
    const xwindow = xf.create(display, l.XDefaultRootWindow(display), 0, 0, 300, 200, 0, 0, 0xffffff);
    _ = xf.map(display, xwindow);
    var host: Host = .{ .window = @intCast(xwindow) };
    defer {
        detach(&host);
        _ = xf.destroy(display, xwindow);
        _ = l.XFlush(display);
    }

    webview.setProvider(provider);
    defer webview.setProvider(null);
    var view: webview.WebView = undefined;
    view.init(testing.allocator);
    defer view.deinit();
    var ui: zigulee.core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 200, .height = 100 });
    defer ui.deinit();
    ui.native_view = &host;
    ui.rootItem().appendChild(&view.item);
    view.item.width.set(200);
    view.item.height.set(60);
    view.html.set("<title>Hello</title><p>zigulee</p>");
    webview.syncWindow(&ui);
    try testing.expect(view.native != null);
    try testing.expect(view.available.get());
    try pump(struct {
        fn f(vw: *webview.WebView) bool {
            return std.mem.eql(u8, vw.title.getUntracked(), "Hello") and !vw.loading.getUntracked();
        }
    }.f, &view);
    try testing.expectEqualStrings("", view.error_text.get());

    const Got = struct {
        var text: [32]u8 = undefined;
        var len: usize = 0;
        var errors: usize = 0;
        fn good(_: *u8, r: []const u8) void {
            @memcpy(text[0..r.len], r);
            len = r.len;
        }
        fn bad(_: *u8, _: []const u8) void {
            errors += 1;
        }
    };
    var dummy: u8 = 0;
    view.javascript_finished.setHandler(&dummy, Got.good);
    view.javascript_failed.setHandler(&dummy, Got.bad);
    view.runJavascript("document.querySelector('p').textContent + ' ' + (6 * 7)");
    try pump(struct {
        fn f(_: *webview.WebView) bool {
            return Got.len > 0;
        }
    }.f, &view);
    try testing.expectEqualStrings("zigulee 42", Got.text[0..Got.len]);
    view.runJavascript("no.such.thing");
    try pump(struct {
        fn f(_: *webview.WebView) bool {
            return Got.errors > 0;
        }
    }.f, &view);
}
