// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Web views on Windows with WebView2 (Microsoft Edge's engine): a
//! controller in the window (its HWND, the window's `native_view`),
//! placed over the `WebView` element, in physical pixels.
//!
//! WebView2 needs its runtime, which Windows 11 has (and Windows 10 gets
//! with Edge). It is found through `WebView2Loader.dll` when the
//! application ships one, else in the registry, where the runtime's own
//! DLL is called the way the loader would. The browser keeps its data
//! (cookies, cache) in the application's cache folder. Everything happens
//! on the UI thread, through its message loop; COM is initialized there
//! (single-threaded apartment).
//!
//! The COM interfaces are declared here by their methods' places in the
//! vtables (WebView2.h, SDK 1.0.4314.35).

const std = @import("std");
const builtin = @import("builtin");
const zigulee = @import("zigulee");
const c = @import("win32_c");
const webview = zigulee.core.webview;
const Native = webview.Provider.Native;

const log = std.log.scoped(.zigulee_windows);

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
    .set_cookie = setCookie,
} };

const gpa = std.heap.page_allocator;

// ---- COM, by vtable index ----

/// A COM object: its first word points to its vtable.
const Object = opaque {};

fn Method(comptime Ret: type, comptime Args: type) type {
    const fields = @typeInfo(Args).@"struct".fields;
    var params: [fields.len + 1]type = undefined;
    params[0] = *Object;
    for (fields, 0..) |f, i| params[i + 1] = f.type;
    const attrs: [params.len]std.builtin.Type.Fn.Param.Attributes = @splat(.{});
    const final = params;
    return *const @Fn(&final, &attrs, Ret, .{ .@"callconv" = .winapi });
}

/// Calls method `index` of `obj`'s vtable.
fn call(comptime Ret: type, obj: *Object, comptime index: usize, args: anytype) Ret {
    const vtable: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    const f: Method(Ret, @TypeOf(args)) = @ptrCast(@alignCast(vtable.*[index]));
    return @call(.auto, f, .{obj} ++ args);
}

fn release(obj: ?*Object) void {
    if (obj) |o| _ = call(u32, o, 2, .{});
}

const HRESULT = c.HRESULT;
const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

fn ok(hr: HRESULT) bool {
    return hr >= 0;
}

// ICoreWebView2Environment
const env_create_controller = 3;
// ICoreWebView2Controller
const controller_put_is_visible = 4;
const controller_put_bounds = 6;
const controller_close = 24;
const controller_get_core = 25;
// ICoreWebView2
const core_get_source = 4;
const core_navigate = 5;
const core_navigate_to_string = 6;
const core_add_navigation_starting = 7;
const core_remove_navigation_starting = 8;
const core_add_source_changed = 11;
const core_remove_source_changed = 12;
const core_add_history_changed = 13;
const core_remove_history_changed = 14;
const core_add_navigation_completed = 15;
const core_remove_navigation_completed = 16;
const core_execute_script = 29;
const core_reload = 31;
const core_get_can_go_back = 38;
const core_get_can_go_forward = 39;
const core_go_back = 40;
const core_go_forward = 41;
const core_stop = 43;
const core_add_document_title_changed = 46;
const core_remove_document_title_changed = 47;
const core_get_document_title = 48;
// ICoreWebView2_2
const core2_get_cookie_manager = 66;
// ICoreWebView2CookieManager
const cookies_create_cookie = 3;
const cookies_add_or_update_cookie = 6;
// ICoreWebView2Cookie
const cookie_put_expires = 9;
const cookie_put_is_http_only = 11;
const cookie_put_same_site = 13;
const cookie_put_is_secure = 15;
// ICoreWebView2NavigationCompletedEventArgs
const args_get_is_success = 3;
const args_get_web_error_status = 4;

const web_error_operation_canceled = 14;

// ---- Handlers (what WebView2 calls back) ----

const Kind = enum { environment, controller, navigation_starting, navigation_completed, source_changed, history_changed, title_changed, script };

/// "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" as a GUID.
fn guid(comptime text: *const [36]u8) c.GUID {
    @setEvalBranchQuota(10_000);
    const hex = struct {
        fn f(comptime T: type, s: []const u8) T {
            return std.fmt.parseInt(T, s, 16) catch unreachable;
        }
    }.f;
    var d4: [8]u8 = undefined;
    inline for (0..2) |i| d4[i] = hex(u8, text[19 + 2 * i ..][0..2]);
    inline for (0..6) |i| d4[2 + i] = hex(u8, text[24 + 2 * i ..][0..2]);
    return .{ .Data1 = hex(u32, text[0..8]), .Data2 = hex(u16, text[9..13]), .Data3 = hex(u16, text[14..18]), .Data4 = d4 };
}

const iid_unknown = guid("00000000-0000-0000-c000-000000000046");
const iid_core_2 = guid("9e8f0cf8-e670-4b5e-b2bc-73e061e3184c");

/// Each handler's interface (WebView2.h).
fn iid(comptime kind: Kind) c.GUID {
    return guid(switch (kind) {
        .environment => "4e8a3389-c9d8-4bd2-b6b5-124fee6cc14d",
        .controller => "6c4819f3-c9b7-4260-8127-c9f5bde7f68c",
        .navigation_starting => "9adbe429-f36d-432b-9ddc-f8881fbd76e3",
        .navigation_completed => "d33a35bf-1c49-4f98-93ab-006e0533fe1c",
        .source_changed => "3c067f9f-5388-4772-8b48-79f7ef1ab37c",
        .history_changed => "c79a420c-efd9-4058-9295-3e8b4bcab645",
        .title_changed => "f5f2b923-953e-4042-9f95-f3a118e1afd4",
        .script => "49511172-cc67-4bca-9923-137112f4c4cc",
    });
}

/// A completion or event handler: a COM object with one `Invoke`, for the
/// web view numbered `view` (gone ones are ignored).
const Handler = extern struct {
    vtable: *const VTable,
    refs: u32 = 1,
    view: u32,

    const VTable = extern struct {
        query_interface: *const fn (*Handler, *const c.GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        add_ref: *const fn (*Handler) callconv(.winapi) u32,
        release: *const fn (*Handler) callconv(.winapi) u32,
        invoke: *const anyopaque,
    };

    fn make(kind: Kind, view: u32) ?*Handler {
        const h = gpa.create(Handler) catch return null;
        h.* = .{ .vtable = switch (kind) {
            inline else => |k| &comptime vtableOf(k),
        }, .view = view };
        return h;
    }

    fn vtableOf(comptime kind: Kind) VTable {
        return .{
            .query_interface = QueryInterface(kind).f,
            .add_ref = addRef,
            .release = releaseIt,
            .invoke = switch (kind) {
                .environment => &environmentCreated,
                .controller => &controllerCreated,
                .navigation_starting => &navigationStarting,
                .navigation_completed => &navigationCompleted,
                .source_changed => &sourceChanged,
                .history_changed => &historyChanged,
                .title_changed => &titleChanged,
                .script => &scriptFinished,
            },
        };
    }

    /// Itself as its interface or IUnknown; nothing else.
    fn QueryInterface(comptime kind: Kind) type {
        return struct {
            fn f(self: *Handler, wanted: *const c.GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
                const own = comptime iid(kind);
                if (!std.meta.eql(wanted.*, own) and !std.meta.eql(wanted.*, iid_unknown)) {
                    out.* = null;
                    return E_NOINTERFACE;
                }
                out.* = self;
                _ = addRef(self);
                return S_OK;
            }
        };
    }
    fn addRef(self: *Handler) callconv(.winapi) u32 {
        self.refs += 1;
        return self.refs;
    }
    fn releaseIt(self: *Handler) callconv(.winapi) u32 {
        self.refs -= 1;
        const left = self.refs;
        if (left == 0) gpa.destroy(self);
        return left;
    }

    fn object(self: *Handler) *Object {
        return @ptrCast(self);
    }
};

// ---- The web views ----

const View = struct {
    id: u32,
    hwnd: c.HWND,
    controller: ?*Object = null,
    core: ?*Object = null,
    /// Event registrations (to remove them).
    tokens: [5]i64 = @splat(0),
    /// Asked for before the controller was ready.
    rect: zigulee.core.Rect = .{},
    visible: bool = false,
    pending: ?Pending = null,
    /// Cookies set before the controller was ready: each its URL, then
    /// its `Set-Cookie` text. Stored before the page loads.
    cookies: std.ArrayList([]u8) = .empty,

    const Pending = struct { text: []u8, html: bool };

    fn native(self: *View) *Native {
        return @ptrCast(self);
    }
};

var views: std.ArrayList(*View) = .empty;
var next_id: u32 = 1;

fn byId(id: u32) ?*View {
    for (views.items) |v| if (v.id == id) return v;
    return null;
}

fn of(native: *Native) *View {
    return @ptrCast(@alignCast(native));
}

/// The environment, shared by every web view (made once).
const Environment = struct {
    state: enum { none, creating, ready, failed } = .none,
    env: ?*Object = null,
    /// Web views waiting for it.
    waiting: std.ArrayList(u32) = .empty,
};
var environment: Environment = .{};

/// A window handle is a number, not an address: it need not be aligned as
/// the C header's `HWND` (a pointer to a struct) says, so no check.
fn toHwnd(host: *anyopaque) c.HWND {
    @setRuntimeSafety(false);
    return @ptrCast(@alignCast(host));
}

fn create(_: ?*anyopaque, host: ?*anyopaque, _: *webview.WebView) ?*Native {
    const hwnd = toHwnd(host orelse return null);
    if (environment.state == .failed) return null;
    const v = gpa.create(View) catch return null;
    v.* = .{ .id = next_id, .hwnd = hwnd };
    next_id +%= 1;
    views.append(gpa, v) catch {
        gpa.destroy(v);
        return null;
    };
    switch (environment.state) {
        .ready => makeController(v),
        .creating => environment.waiting.append(gpa, v.id) catch {},
        .none => {
            environment.waiting.append(gpa, v.id) catch {};
            if (!startEnvironment()) {
                environment.state = .failed;
                environment.waiting.clearRetainingCapacity();
                forget(v);
                return null;
            }
        },
        .failed => unreachable,
    }
    return v.native();
}

fn forget(v: *View) void {
    if (std.mem.indexOfScalar(*View, views.items, v)) |i| _ = views.swapRemove(i);
    if (v.pending) |p| gpa.free(p.text);
    for (v.cookies.items) |s| gpa.free(s);
    v.cookies.deinit(gpa);
    gpa.destroy(v);
}

fn destroy(_: ?*anyopaque, native: *Native) void {
    const v = of(native);
    if (v.core) |core| {
        _ = call(HRESULT, core, core_remove_navigation_starting, .{v.tokens[0]});
        _ = call(HRESULT, core, core_remove_navigation_completed, .{v.tokens[1]});
        _ = call(HRESULT, core, core_remove_source_changed, .{v.tokens[2]});
        _ = call(HRESULT, core, core_remove_history_changed, .{v.tokens[3]});
        _ = call(HRESULT, core, core_remove_document_title_changed, .{v.tokens[4]});
        release(core);
    }
    if (v.controller) |ctl| {
        _ = call(HRESULT, ctl, controller_close, .{});
        release(ctl);
    }
    forget(v);
}

// ---- Finding the runtime ----

const CreateWithOptions = *const fn (?[*:0]const u16, ?[*:0]const u16, ?*Object, *Object) callconv(.winapi) HRESULT;
const CreateInternal = *const fn (bool, i32, ?[*:0]const u16, ?*Object, *Object) callconv(.winapi) HRESULT;

const runtime_client = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
const arch_folder = switch (builtin.cpu.arch) {
    .aarch64 => "arm64",
    .x86 => "x86",
    else => "x64",
};

fn w(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

// The predefined keys are not aligned pointers (c.HKEY would not take them).
extern "advapi32" fn RegGetValueW(key: usize, sub_key: [*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;
const hkey_current_user: usize = 0x80000001;
const hkey_local_machine: usize = 0x80000002;
const rrf_rt_reg_sz = 0x2;

/// A string value from the registry ("" if there is none).
fn regString(root: usize, key: [*:0]const u16, name: [*:0]const u16, buf: []u16) []const u16 {
    var size: u32 = @intCast(buf.len * 2);
    if (RegGetValueW(root, key, name, rrf_rt_reg_sz, null, buf.ptr, &size) != 0) return &.{};
    const n = size / 2;
    return buf[0..if (n > 0 and buf[n - 1] == 0) n - 1 else n];
}

/// Starts making the environment: through WebView2Loader.dll, else the
/// runtime's own DLL. False if neither is there.
fn startEnvironment() bool {
    const com = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    if (!ok(com) and com != @as(HRESULT, @bitCast(@as(u32, 0x80010106)))) { // RPC_E_CHANGED_MODE
        log.info("no web views: COM: 0x{x}", .{@as(u32, @bitCast(com))});
        return false;
    }
    const handler = Handler.make(.environment, 0) orelse return false;
    defer _ = Handler.releaseIt(handler);
    const data = dataFolder();
    defer if (data) |d| gpa.free(d);
    environment.state = .creating;

    if (c.LoadLibraryW(w("WebView2Loader.dll"))) |loader| {
        if (c.GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions")) |f| {
            const create_env: CreateWithOptions = @ptrCast(f);
            if (ok(create_env(null, if (data) |d| d.ptr else null, null, handler.object()))) return true;
        }
    }
    // The installed runtime (for the machine, else for the user).
    const key = w("SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\" ++ runtime_client);
    const user_key = w("Software\\Microsoft\\EdgeUpdate\\Clients\\" ++ runtime_client);
    var loc_buf: [512]u16 = undefined;
    var ver_buf: [64]u16 = undefined;
    for ([_]struct { usize, [*:0]const u16 }{ .{ hkey_local_machine, key }, .{ hkey_current_user, user_key } }) |r| {
        const location = regString(r[0], r[1], w("location"), &loc_buf);
        const version = regString(r[0], r[1], w("pv"), &ver_buf);
        if (location.len == 0 or version.len == 0 or std.mem.eql(u16, version, std.unicode.utf8ToUtf16LeStringLiteral("0.0.0.0"))) continue;
        var path: std.ArrayList(u16) = .empty;
        defer path.deinit(gpa);
        path.appendSlice(gpa, location) catch return false;
        path.append(gpa, '\\') catch return false;
        path.appendSlice(gpa, version) catch return false;
        path.appendSlice(gpa, std.unicode.utf8ToUtf16LeStringLiteral("\\EBWebView\\" ++ arch_folder ++ "\\EmbeddedBrowserWebView.dll")) catch return false;
        path.append(gpa, 0) catch return false;
        const dll = c.LoadLibraryW(@ptrCast(path.items.ptr)) orelse continue;
        const f = c.GetProcAddress(dll, "CreateWebViewEnvironmentWithOptionsInternal") orelse continue;
        const create_env: CreateInternal = @ptrCast(f);
        if (ok(create_env(true, 0, if (data) |d| d.ptr else null, null, handler.object()))) return true;
    }
    environment.state = .none;
    log.info("no web views: the WebView2 runtime is not installed", .{});
    return false;
}

/// Where the browser keeps its data: the application's cache folder.
fn dataFolder() ?[:0]u16 {
    const dir = zigulee.core.paths.get(gpa, .app_cache) catch return null;
    defer gpa.free(dir);
    if (dir.len == 0) return null;
    const full = std.fs.path.join(gpa, &.{ dir, "WebView2" }) catch return null;
    defer gpa.free(full);
    return std.unicode.utf8ToUtf16LeAllocZ(gpa, full) catch null;
}

fn environmentCreated(_: *Handler, hr: HRESULT, env: ?*Object) callconv(.winapi) HRESULT {
    if (!ok(hr) or env == null) {
        log.info("no web views: WebView2 failed (0x{x})", .{@as(u32, @bitCast(hr))});
        environment.state = .failed;
        for (environment.waiting.items) |id| if (byId(id)) |v| webview.reportFinished(v.native(), "the WebView2 runtime could not start");
        environment.waiting.clearRetainingCapacity();
        return S_OK;
    }
    _ = call(u32, env.?, 1, .{}); // AddRef: kept
    environment.env = env;
    environment.state = .ready;
    for (environment.waiting.items) |id| if (byId(id)) |v| makeController(v);
    environment.waiting.clearRetainingCapacity();
    return S_OK;
}

fn makeController(v: *View) void {
    const handler = Handler.make(.controller, v.id) orelse return;
    defer _ = Handler.releaseIt(handler);
    _ = call(HRESULT, environment.env.?, env_create_controller, .{ v.hwnd, handler.object() });
}

fn controllerCreated(self: *Handler, hr: HRESULT, controller: ?*Object) callconv(.winapi) HRESULT {
    const v = byId(self.view) orelse return S_OK;
    const ctl = controller orelse return S_OK;
    if (!ok(hr)) {
        webview.reportFinished(v.native(), "the web view could not be made");
        return S_OK;
    }
    _ = call(u32, ctl, 1, .{});
    v.controller = ctl;
    var core: ?*Object = null;
    _ = call(HRESULT, ctl, controller_get_core, .{&core});
    v.core = core;
    if (core) |cw| {
        const events = [_]struct { Kind, usize }{
            .{ .navigation_starting, core_add_navigation_starting },
            .{ .navigation_completed, core_add_navigation_completed },
            .{ .source_changed, core_add_source_changed },
            .{ .history_changed, core_add_history_changed },
            .{ .title_changed, core_add_document_title_changed },
        };
        inline for (events, 0..) |e, i| if (Handler.make(e[0], v.id)) |h| {
            _ = call(HRESULT, cw, e[1], .{ h.object(), &v.tokens[i] });
            _ = Handler.releaseIt(h);
        };
    }
    applyPlace(v);
    var i: usize = 0;
    while (i + 1 < v.cookies.items.len) : (i += 2) {
        if (!storeCookie(v, v.cookies.items[i], v.cookies.items[i + 1])) log.warn("web view: a cookie could not be set", .{});
    }
    for (v.cookies.items) |s| gpa.free(s);
    v.cookies.clearRetainingCapacity();
    if (v.pending) |p| {
        v.pending = null;
        defer gpa.free(p.text);
        navigate(v, p.text, p.html);
    }
    return S_OK;
}

// ---- What the element asks ----

fn place(_: ?*anyopaque, native: *Native, rect: zigulee.core.Rect, visible: bool) void {
    const v = of(native);
    v.rect = rect;
    v.visible = visible;
    applyPlace(v);
}

fn applyPlace(v: *View) void {
    const ctl = v.controller orelse return;
    // In the window's physical pixels.
    const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(v.hwnd))) / 96;
    const r = v.rect;
    const bounds: c.RECT = .{
        .left = @intFromFloat(@round(r.x * scale)),
        .top = @intFromFloat(@round(r.y * scale)),
        .right = @intFromFloat(@round((r.x + r.width) * scale)),
        .bottom = @intFromFloat(@round((r.y + r.height) * scale)),
    };
    _ = call(HRESULT, ctl, controller_put_bounds, .{bounds});
    _ = call(HRESULT, ctl, controller_put_is_visible, .{@as(c.BOOL, @intFromBool(v.visible))});
}

fn navigate(v: *View, text: []const u8, html: bool) void {
    const core = v.core orelse {
        // Kept until the controller is ready.
        if (v.pending) |p| gpa.free(p.text);
        v.pending = .{ .text = gpa.dupe(u8, text) catch return, .html = html };
        return;
    };
    const wide = std.unicode.utf8ToUtf16LeAllocZ(gpa, text) catch return;
    defer gpa.free(wide);
    const hr = if (html) call(HRESULT, core, core_navigate_to_string, .{wide.ptr}) else call(HRESULT, core, core_navigate, .{wide.ptr});
    if (!ok(hr)) webview.reportFinished(v.native(), "not a URL");
}

fn loadUrl(_: ?*anyopaque, native: *Native, url: []const u8) void {
    navigate(of(native), url, false);
}
fn loadHtml(_: ?*anyopaque, native: *Native, html: []const u8) void {
    navigate(of(native), html, true);
}
fn back(_: ?*anyopaque, native: *Native) void {
    if (of(native).core) |core| _ = call(HRESULT, core, core_go_back, .{});
}
fn forward(_: ?*anyopaque, native: *Native) void {
    if (of(native).core) |core| _ = call(HRESULT, core, core_go_forward, .{});
}
fn reload(_: ?*anyopaque, native: *Native) void {
    if (of(native).core) |core| _ = call(HRESULT, core, core_reload, .{});
}
fn stop(_: ?*anyopaque, native: *Native) void {
    if (of(native).core) |core| _ = call(HRESULT, core, core_stop, .{});
}

/// Stored with the cookie manager now if the page is ready, else kept
/// until it is (and stored before it loads). WebView2 stores cookies in
/// the order asked, before later navigations: stored as far as the
/// element is concerned.
fn setCookie(_: ?*anyopaque, native: *Native, url: []const u8, cookie: []const u8) void {
    const v = of(native);
    if (v.core == null) {
        const u = gpa.dupe(u8, url) catch return webview.reportCookieStored(native, false);
        const k = gpa.dupe(u8, cookie) catch {
            gpa.free(u);
            return webview.reportCookieStored(native, false);
        };
        v.cookies.appendSlice(gpa, &.{ u, k }) catch {
            gpa.free(u);
            gpa.free(k);
            return webview.reportCookieStored(native, false);
        };
        return webview.reportCookieStored(native, true);
    }
    webview.reportCookieStored(native, storeCookie(v, url, cookie));
}

/// `cookie` (a `Set-Cookie` text) read for `url` and added to the
/// profile's cookies: false if it could not be read or stored.
fn storeCookie(v: *View, url: []const u8, text: []const u8) bool {
    const core = v.core orelse return false;
    const parsed = zigulee.core.cookie.parse(text, url) orelse return false;
    var core2: ?*Object = null;
    if (!ok(call(HRESULT, core, 0, .{ &iid_core_2, &core2 })) or core2 == null) return false;
    defer release(core2);
    var manager: ?*Object = null;
    if (!ok(call(HRESULT, core2.?, core2_get_cookie_manager, .{&manager})) or manager == null) return false;
    defer release(manager);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const wide = struct {
        fn f(al: std.mem.Allocator, s: []const u8) ?[*:0]const u16 {
            return (std.unicode.utf8ToUtf16LeAllocZ(al, s) catch return null).ptr;
        }
    }.f;
    // A leading dot: its subdomains too.
    const domain = if (parsed.host_only) parsed.domain else std.mem.concat(a, u8, &.{ ".", parsed.domain }) catch return false;
    var cookie: ?*Object = null;
    if (!ok(call(HRESULT, manager.?, cookies_create_cookie, .{
        wide(a, parsed.name) orelse return false,
        wide(a, parsed.value) orelse return false,
        wide(a, domain) orelse return false,
        wide(a, parsed.path) orelse return false,
        &cookie,
    })) or cookie == null) return false;
    defer release(cookie);
    const ck = cookie.?;
    _ = call(HRESULT, ck, cookie_put_is_http_only, .{@as(c.BOOL, @intFromBool(parsed.http_only))});
    _ = call(HRESULT, ck, cookie_put_is_secure, .{@as(c.BOOL, @intFromBool(parsed.secure))});
    if (parsed.same_site != .unset) _ = call(HRESULT, ck, cookie_put_same_site, .{@as(i32, switch (parsed.same_site) {
        .none => 0,
        .lax => 1,
        .strict, .unset => 2,
    })});
    if (parsed.expiresAt(unixNow())) |at| _ = call(HRESULT, ck, cookie_put_expires, .{@as(f64, @floatFromInt(at))});
    return ok(call(HRESULT, manager.?, cookies_add_or_update_cookie, .{ck}));
}

/// Seconds since 1970 (UTC).
fn unixNow() i64 {
    var ft: c.FILETIME = undefined;
    c.GetSystemTimeAsFileTime(&ft);
    const ticks = (@as(i64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime; // 100 ns since 1601
    return @divFloor(ticks, 10_000_000) - 11_644_473_600;
}

/// `code` wrapped to report its result or its exception as JSON
/// (ExecuteScript reports neither on its own): `{"ok": value}` or
/// `{"error": "message"}`, undefined giving `{}`.
fn wrapScript(a: std.mem.Allocator, code: []const u8) ![:0]u16 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try out.writer.writeAll("(() => { try { return JSON.stringify({ ok: (0, eval)(");
    try std.json.Stringify.value(code, .{}, &out.writer);
    try out.writer.writeAll(") }); } catch (e) { return JSON.stringify({ error: String(e) }); } })()");
    return std.unicode.utf8ToUtf16LeAllocZ(a, out.written());
}

fn runJavascript(_: ?*anyopaque, native: *Native, code: []const u8) void {
    const v = of(native);
    const core = v.core orelse return webview.reportJavaScript(native, "the page is not ready", true);
    const script = wrapScript(gpa, code) catch return;
    defer gpa.free(script);
    const handler = Handler.make(.script, v.id) orelse return;
    defer _ = Handler.releaseIt(handler);
    _ = call(HRESULT, core, core_execute_script, .{ script.ptr, handler.object() });
}

/// What a wrapped script gave (`json` is the JSON of the string it
/// returned): the result as text, and whether it is an error.
const Outcome = struct { text: []const u8, failed: bool };

fn outcome(a: std.mem.Allocator, json: []const u8) Outcome {
    const json_mod = zigulee.core.json;
    const inner = switch (json_mod.find(a, json, "") orelse return .{ .text = "", .failed = true }) {
        .string => |s| s,
        else => return .{ .text = json, .failed = false },
    };
    if (json_mod.find(a, inner, "error")) |e| return .{ .text = if (e == .string) e.string else "error", .failed = true };
    const value = json_mod.find(a, inner, "ok") orelse return .{ .text = "", .failed = false };
    return .{ .text = switch (value) {
        .string, .number, .raw => |s| s,
        .boolean => |b| if (b) "true" else "false",
        .null => "",
    }, .failed = false };
}

fn scriptFinished(self: *Handler, hr: HRESULT, result: ?[*:0]const u16) callconv(.winapi) HRESULT {
    const v = byId(self.view) orelse return S_OK;
    if (!ok(hr) or result == null) {
        webview.reportJavaScript(v.native(), "the script could not run", true);
        return S_OK;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const json = std.unicode.utf16LeToUtf8Alloc(a, std.mem.span(result.?)) catch return S_OK;
    const o = outcome(a, json);
    webview.reportJavaScript(v.native(), o.text, o.failed);
    return S_OK;
}

// ---- Events ----

fn navigationStarting(self: *Handler, _: ?*Object, _: ?*Object) callconv(.winapi) HRESULT {
    const v = byId(self.view) orelse return S_OK;
    webview.reportLoading(v.native(), true);
    return S_OK;
}

fn navigationCompleted(self: *Handler, _: ?*Object, args: ?*Object) callconv(.winapi) HRESULT {
    const v = byId(self.view) orelse return S_OK;
    const a = args orelse return S_OK;
    var success: c.BOOL = 0;
    _ = call(HRESULT, a, args_get_is_success, .{&success});
    reportState(v);
    if (success != 0) {
        webview.reportFinished(v.native(), null);
        return S_OK;
    }
    var status: i32 = 0;
    _ = call(HRESULT, a, args_get_web_error_status, .{&status});
    // Another page asked for before this one loaded: not a failure.
    if (status == web_error_operation_canceled) return S_OK;
    webview.reportFinished(v.native(), errorText(status));
    return S_OK;
}

fn errorText(status: i32) []const u8 {
    return switch (status) {
        1, 2, 4, 5 => "the site's certificate is not valid",
        6 => "the server cannot be reached",
        7 => "the connection timed out",
        8 => "the server's answer is not valid",
        9, 10 => "the connection was interrupted",
        11 => "the computer is offline",
        12 => "cannot connect to the server",
        13 => "the server's name cannot be found",
        15 => "a redirect failed",
        17, 18 => "the site wants credentials",
        else => "the page could not be loaded",
    };
}

fn sourceChanged(self: *Handler, _: ?*Object, _: ?*Object) callconv(.winapi) HRESULT {
    const v = byId(self.view) orelse return S_OK;
    reportState(v);
    return S_OK;
}
fn historyChanged(self: *Handler, _: ?*Object, _: ?*Object) callconv(.winapi) HRESULT {
    const v = byId(self.view) orelse return S_OK;
    reportState(v);
    return S_OK;
}
fn titleChanged(self: *Handler, _: ?*Object, _: ?*Object) callconv(.winapi) HRESULT {
    const v = byId(self.view) orelse return S_OK;
    reportState(v);
    return S_OK;
}

/// Reports the page's title, address and history as they are.
fn reportState(v: *View) void {
    const core = v.core orelse return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (string(a, core, core_get_document_title)) |t| webview.reportTitle(v.native(), t);
    if (string(a, core, core_get_source)) |s| {
        // A page given as text has no address worth reporting.
        if (!std.mem.startsWith(u8, s, "data:") and !std.mem.eql(u8, s, "about:blank")) webview.reportUrl(v.native(), s);
    }
    var can_back: c.BOOL = 0;
    var can_forward: c.BOOL = 0;
    _ = call(HRESULT, core, core_get_can_go_back, .{&can_back});
    _ = call(HRESULT, core, core_get_can_go_forward, .{&can_forward});
    webview.reportHistory(v.native(), can_back != 0, can_forward != 0);
}

/// A string property (LPWSTR, freed with CoTaskMemFree) as UTF-8.
fn string(a: std.mem.Allocator, obj: *Object, comptime index: usize) ?[]const u8 {
    var p: ?[*:0]u16 = null;
    if (!ok(call(HRESULT, obj, index, .{&p}))) return null;
    const s = p orelse return null;
    defer c.CoTaskMemFree(s);
    return std.unicode.utf16LeToUtf8Alloc(a, std.mem.span(s)) catch null;
}

// ---- Tests ----

const testing = std.testing;

test "window handles taken as they are, aligned or not" {
    var bytes: [8]u8 align(8) = undefined;
    try testing.expectEqual(@intFromPtr(&bytes[2]), @intFromPtr(toHwnd(&bytes[2])));
}

test "interface ids" {
    try testing.expectEqual(@as(c_ulong, 0x9e8f0cf8), iid_core_2.Data1);
    const e = iid(.environment);
    try testing.expectEqual(@as(c_ulong, 0x4e8a3389), e.Data1);
    try testing.expectEqual(@as(c_ushort, 0xc9d8), e.Data2);
    try testing.expectEqualSlices(u8, &.{ 0xb6, 0xb5, 0x12, 0x4f, 0xee, 0x6c, 0xc1, 0x4d }, &e.Data4);
}

test "scripts wrapped to report their results and errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const script = try wrapScript(a, "document.title + \"!\"");
    const text = try std.unicode.utf16LeToUtf8Alloc(a, script);
    try testing.expect(std.mem.indexOf(u8, text, "eval)(\"document.title + \\\"!\\\"\")") != null);
    // What ExecuteScript gives back: the JSON of the string returned.
    try testing.expectEqualStrings("zigulee 42", outcome(a, "\"{\\\"ok\\\":\\\"zigulee 42\\\"}\"").text);
    try testing.expectEqualStrings("{\"a\":[1,true]}", outcome(a, "\"{\\\"ok\\\":{\\\"a\\\":[1,true]}}\"").text);
    try testing.expectEqualStrings("42", outcome(a, "\"{\\\"ok\\\":42}\"").text);
    try testing.expectEqualStrings("", outcome(a, "\"{}\"").text);
    const bad = outcome(a, "\"{\\\"error\\\":\\\"ReferenceError: no is not defined\\\"}\"");
    try testing.expect(bad.failed);
    try testing.expectEqualStrings("ReferenceError: no is not defined", bad.text);
}

/// Pumps the UI thread's messages until `done()`, at most about 20 s.
fn pump(comptime done: fn (*webview.WebView) bool, view: *webview.WebView) !void {
    for (0..2000) |_| {
        if (done(view)) return;
        var m: c.MSG = undefined;
        while (c.PeekMessageW(&m, null, 0, 0, c.PM_REMOVE) != 0) {
            _ = c.TranslateMessage(&m);
            _ = c.DispatchMessageW(&m);
        }
        c.Sleep(10);
    }
    return error.Timeout;
}

test "a page given as text in WebView2: loaded, its title, JavaScript run in it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    webview.setProvider(provider);
    defer webview.setProvider(null);
    var view: webview.WebView = undefined;
    view.init(testing.allocator);
    defer view.deinit();
    var ui: zigulee.core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 200, .height = 100 });
    defer ui.deinit();
    const host = c.CreateWindowExW(0, w("STATIC"), w("zigulee"), c.WS_OVERLAPPEDWINDOW, 0, 0, 300, 200, null, null, c.GetModuleHandleW(null), null) orelse return error.SkipZigTest;
    defer _ = c.DestroyWindow(host);
    ui.native_view = host;
    ui.rootItem().appendChild(&view.item);
    view.item.width.set(200);
    view.item.height.set(60);
    view.html.set("<title>Hello</title><p>zigulee</p>");
    webview.syncWindow(&ui);
    if (view.native == null) {
        std.debug.print("no WebView2 runtime: skipped\n", .{});
        return error.SkipZigTest;
    }
    pump(struct {
        fn f(vw: *webview.WebView) bool {
            return std.mem.eql(u8, vw.title.getUntracked(), "Hello") and !vw.loading.getUntracked();
        }
    }.f, &view) catch |err| {
        if (environment.state == .failed) {
            std.debug.print("WebView2 environment unavailable: skipped\n", .{});
            return error.SkipZigTest;
        }
        return err;
    };

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
