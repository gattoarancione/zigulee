// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Web views with WebKit (macOS and iOS): a WKWebView added to the
//! window's view (an NSView or a UIView) and placed over the `WebView`
//! element. Navigation is reported by a WKNavigationDelegate, the title,
//! address and history by key-value observing, all on the main thread.

const std = @import("std");
const builtin = @import("builtin");
const zigulee = @import("zigulee");
const objc = @import("objc.zig");
const webview = zigulee.core.webview;
const Native = webview.Provider.Native;
const id = objc.id;
const SEL = objc.SEL;
const msg = objc.msg;
const class = objc.class;

const log = std.log.scoped(.zigulee_apple);

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

const ios = builtin.os.tag == .ios;
const CGRect = objc.NSRect;

/// One web view: the WKWebView, and the view it is in.
const View = struct {
    wk: id,
    host: id,
};

/// Every web view made (what the delegate's reports look up).
var made: std.ArrayList(*View) = .empty;
const gpa = std.heap.c_allocator;

const observed = [_][:0]const u8{ "title", "URL", "canGoBack", "canGoForward" };
const ns_url_error_cancelled = -999;

fn of(native: *Native) *View {
    return @ptrCast(@alignCast(native));
}

fn byWebView(wk: id) ?*View {
    for (made.items) |v| if (v.wk == wk) return v;
    return null;
}

fn alive(v: *View) bool {
    return std.mem.indexOfScalar(*View, made.items, v) != null;
}

fn create(_: ?*anyopaque, host: ?*anyopaque, _: *webview.WebView) ?*Native {
    const h: id = host orelse return null;
    if (class("WKWebView") == null) return null;
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    const config = msg(id, msg(id, class("WKWebViewConfiguration"), "alloc", .{}), "init", .{});
    defer msg(void, config, "release", .{});
    const wk = msg(id, msg(id, class("WKWebView"), "alloc", .{}), "initWithFrame:configuration:", .{ CGRect{}, config }) orelse return null;
    const v = gpa.create(View) catch {
        msg(void, wk, "release", .{});
        return null;
    };
    v.* = .{ .wk = wk, .host = h };
    made.append(gpa, v) catch {
        gpa.destroy(v);
        msg(void, wk, "release", .{});
        return null;
    };
    msg(void, wk, "setNavigationDelegate:", .{delegate()});
    for (observed) |key| msg(void, wk, "addObserver:forKeyPath:options:context:", .{ delegate(), objc.nsString(key), @as(usize, 1), @as(?*anyopaque, null) });
    msg(void, wk, "setHidden:", .{true});
    msg(void, h, "addSubview:", .{wk});
    return @ptrCast(v);
}

fn destroy(_: ?*anyopaque, native: *Native) void {
    const v = of(native);
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    for (observed) |key| msg(void, v.wk, "removeObserver:forKeyPath:", .{ delegate(), objc.nsString(key) });
    msg(void, v.wk, "setNavigationDelegate:", .{@as(id, null)});
    msg(void, v.wk, "stopLoading", .{});
    msg(void, v.wk, "removeFromSuperview", .{});
    msg(void, v.wk, "release", .{});
    if (std.mem.indexOfScalar(*View, made.items, v)) |i| _ = made.swapRemove(i);
    gpa.destroy(v);
}

fn place(_: ?*anyopaque, native: *Native, rect: zigulee.core.Rect, visible: bool) void {
    const v = of(native);
    var frame: CGRect = .{ .origin = .{ .x = rect.x, .y = rect.y }, .size = .{ .width = rect.width, .height = rect.height } };
    // AppKit's views count from the bottom, unless flipped (zigulee's is).
    if (!ios and !msg(bool, v.host, "isFlipped", .{})) {
        const bounds = msg(CGRect, v.host, "bounds", .{});
        frame.origin.y = bounds.size.height - rect.y - rect.height;
    }
    msg(void, v.wk, "setFrame:", .{frame});
    msg(void, v.wk, "setHidden:", .{!visible});
}

fn loadUrl(_: ?*anyopaque, native: *Native, url: []const u8) void {
    const v = of(native);
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    const u = msg(id, class("NSURL"), "URLWithString:", .{objc.nsString(url)});
    if (u == null) return webview.reportFinished(native, "not a URL");
    _ = msg(id, v.wk, "loadRequest:", .{msg(id, class("NSURLRequest"), "requestWithURL:", .{u})});
}

fn loadHtml(_: ?*anyopaque, native: *Native, html: []const u8) void {
    const v = of(native);
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    _ = msg(id, v.wk, "loadHTMLString:baseURL:", .{ objc.nsString(html), @as(id, null) });
}

fn back(_: ?*anyopaque, native: *Native) void {
    _ = msg(id, of(native).wk, "goBack", .{});
}
fn forward(_: ?*anyopaque, native: *Native) void {
    _ = msg(id, of(native).wk, "goForward", .{});
}
fn reload(_: ?*anyopaque, native: *Native) void {
    _ = msg(id, of(native).wk, "reload", .{});
}
fn stop(_: ?*anyopaque, native: *Native) void {
    msg(void, of(native).wk, "stopLoading", .{});
}

// ---- JavaScript ----

extern const _NSConcreteStackBlock: anyopaque;

/// The completion block of `evaluateJavaScript:`, holding its web view
/// (WebKit copies it: no helpers needed for a plain pointer).
const ResultBlock = extern struct {
    isa: ?*const anyopaque = &_NSConcreteStackBlock,
    flags: c_int = 0,
    reserved: c_int = 0,
    invoke: *const fn (*ResultBlock, id, id) callconv(.c) void = finishedJs,
    descriptor: *const Descriptor = &the_descriptor,
    view: *View,

    const Descriptor = extern struct { reserved: c_ulong = 0, size: c_ulong = @sizeOf(ResultBlock) };
    const the_descriptor: Descriptor = .{};
};

fn runJavascript(_: ?*anyopaque, native: *Native, code: []const u8) void {
    const v = of(native);
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    var block: ResultBlock = .{ .view = v };
    msg(void, v.wk, "evaluateJavaScript:completionHandler:", .{ objc.nsString(code), &block });
}

fn finishedJs(block: *ResultBlock, result: id, err: id) callconv(.c) void {
    const v = block.view;
    if (!alive(v)) return;
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    if (err != null) {
        const info = msg(id, err, "userInfo", .{});
        const message = msg(id, info, "objectForKey:", .{objc.nsString("WKJavaScriptExceptionMessage")});
        const text = if (message != null) message else msg(id, err, "localizedDescription", .{});
        return webview.reportJavaScript(@ptrCast(v), objc.utf8(text), true);
    }
    webview.reportJavaScript(@ptrCast(v), objc.utf8(asText(result)), false);
}

/// A JavaScript result as text: a string as it is, other values as JSON
/// (numbers, true, arrays, objects), "" for undefined and null.
fn asText(result: id) id {
    if (result == null or msg(bool, result, "isKindOfClass:", .{class("NSNull")})) return objc.nsString("");
    if (msg(bool, result, "isKindOfClass:", .{class("NSString")})) return result;
    const fragments_allowed: usize = 4;
    const data = msg(id, class("NSJSONSerialization"), "dataWithJSONObject:options:error:", .{ result, fragments_allowed, @as(?*anyopaque, null) });
    if (data == null) return msg(id, result, "description", .{});
    return msg(id, msg(id, msg(id, class("NSString"), "alloc", .{}), "initWithData:encoding:", .{ data, @as(usize, 4) }), "autorelease", .{});
}

// ---- Cookies ----

/// The cookies of one `set_cookie` still being stored, and their web view.
const Storing = struct { view: *View, left: usize };

/// The completion block of `setCookie:` (WebKit copies it: no helpers
/// needed for a plain pointer).
const StoredBlock = extern struct {
    isa: ?*const anyopaque = &_NSConcreteStackBlock,
    flags: c_int = 0,
    reserved: c_int = 0,
    invoke: *const fn (*StoredBlock) callconv(.c) void = stored,
    descriptor: *const Descriptor = &the_descriptor,
    storing: *Storing,

    const Descriptor = extern struct { reserved: c_ulong = 0, size: c_ulong = @sizeOf(StoredBlock) };
    const the_descriptor: Descriptor = .{};
};

/// Read as a server's `Set-Cookie` header for `url` would be (HttpOnly,
/// Secure, the domain and path from the URL unless it says), into the
/// web views' cookie store: the one every WKWebView of the app shares.
fn setCookie(_: ?*anyopaque, native: *Native, url: []const u8, cookie: []const u8) void {
    const v = of(native);
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    const u = msg(id, class("NSURL"), "URLWithString:", .{objc.nsString(url)});
    if (u == null) return webview.reportCookieStored(native, false);
    const fields = msg(id, class("NSDictionary"), "dictionaryWithObject:forKey:", .{ objc.nsString(cookie), objc.nsString("Set-Cookie") });
    const cookies = msg(id, class("NSHTTPCookie"), "cookiesWithResponseHeaderFields:forURL:", .{ fields, u });
    const count = if (cookies != null) msg(usize, cookies, "count", .{}) else 0;
    if (count == 0) return webview.reportCookieStored(native, false);
    const storing = gpa.create(Storing) catch return webview.reportCookieStored(native, false);
    storing.* = .{ .view = v, .left = count };
    const store = msg(id, msg(id, msg(id, v.wk, "configuration", .{}), "websiteDataStore", .{}), "httpCookieStore", .{});
    for (0..count) |i| {
        var block: StoredBlock = .{ .storing = storing };
        msg(void, store, "setCookie:completionHandler:", .{ msg(id, cookies, "objectAtIndex:", .{i}), &block });
    }
}

fn stored(block: *StoredBlock) callconv(.c) void {
    const s = block.storing;
    s.left -= 1;
    if (s.left > 0) return;
    const v = s.view;
    gpa.destroy(s);
    if (alive(v)) webview.reportCookieStored(@ptrCast(v), true);
}

// ---- The delegate ----

var delegate_object: id = null;

fn delegate() id {
    if (delegate_object) |d| return d;
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("NSObject"), "ZiguleeWebViewDelegate", 0);
    _ = objc.class_addProtocol(cls, objc.objc_getProtocol("WKNavigationDelegate"));
    _ = objc.class_addMethod(cls, objc.sel("webView:didStartProvisionalNavigation:"), @ptrCast(&started), "v@:@@");
    _ = objc.class_addMethod(cls, objc.sel("webView:didFinishNavigation:"), @ptrCast(&finished), "v@:@@");
    _ = objc.class_addMethod(cls, objc.sel("webView:didFailNavigation:withError:"), @ptrCast(&failed), "v@:@@@");
    _ = objc.class_addMethod(cls, objc.sel("webView:didFailProvisionalNavigation:withError:"), @ptrCast(&failed), "v@:@@@");
    _ = objc.class_addMethod(cls, objc.sel("observeValueForKeyPath:ofObject:change:context:"), @ptrCast(&changed), "v@:@@@^v");
    objc.objc_registerClassPair(cls);
    delegate_object = msg(id, msg(id, cls, "alloc", .{}), "init", .{});
    return delegate_object;
}

fn started(_: id, _: SEL, wk: id, _: id) callconv(.c) void {
    const v = byWebView(wk) orelse return;
    webview.reportLoading(@ptrCast(v), true);
}

fn finished(self: id, sel: SEL, wk: id, _: id) callconv(.c) void {
    const v = byWebView(wk) orelse return;
    // The title and address as they are now (observing reports them a bit
    // later), for `finished` to see.
    changed(self, sel, null, wk, null, null);
    webview.reportFinished(@ptrCast(v), null);
}

fn failed(_: id, _: SEL, wk: id, _: id, err: id) callconv(.c) void {
    const v = byWebView(wk) orelse return;
    // Another page asked for before this one loaded: not a failure.
    if (msg(isize, err, "code", .{}) == ns_url_error_cancelled) return;
    webview.reportFinished(@ptrCast(v), objc.utf8(msg(id, err, "localizedDescription", .{})));
}

fn changed(_: id, _: SEL, _: id, wk: id, _: id, _: ?*anyopaque) callconv(.c) void {
    const v = byWebView(wk) orelse return;
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    webview.reportTitle(@ptrCast(v), objc.utf8(msg(id, wk, "title", .{})));
    const url = msg(id, wk, "URL", .{});
    // A page given as text has no address worth reporting.
    if (url != null) {
        const text = objc.utf8(msg(id, url, "absoluteString", .{}));
        if (!std.mem.eql(u8, text, "about:blank")) webview.reportUrl(@ptrCast(v), text);
    }
    webview.reportHistory(@ptrCast(v), msg(bool, wk, "canGoBack", .{}), msg(bool, wk, "canGoForward", .{}));
}

// ---- Tests ----

const testing = std.testing;

/// Runs the main run loop until `done()` (WebKit works there), at most
/// about 10 s.
fn spin(comptime done: fn (*webview.WebView) bool, view: *webview.WebView) !void {
    const loop = msg(id, class("NSRunLoop"), "currentRunLoop", .{});
    const mode = objc.nsString("kCFRunLoopDefaultMode");
    for (0..1000) |_| {
        if (done(view)) return;
        const pool = objc.objc_autoreleasePoolPush();
        defer objc.objc_autoreleasePoolPop(pool);
        _ = msg(bool, loop, "runMode:beforeDate:", .{ mode, msg(id, class("NSDate"), "dateWithTimeIntervalSinceNow:", .{@as(f64, 0.01)}) });
    }
    return error.Timeout;
}

test "a cookie stored (HttpOnly) before the page loads" {
    if (ios) return error.SkipZigTest;
    webview.setProvider(provider);
    defer webview.setProvider(null);
    var view: webview.WebView = undefined;
    view.init(testing.allocator);
    defer view.deinit();
    var ui: zigulee.core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 200, .height = 100 });
    defer ui.deinit();
    const host = msg(id, msg(id, class("NSView"), "alloc", .{}), "initWithFrame:", .{CGRect{ .size = .{ .width = 200, .height = 100 } }});
    defer msg(void, host, "release", .{});
    ui.native_view = host;
    ui.rootItem().appendChild(&view.item);
    view.item.width.set(200);
    view.item.height.set(60);
    // A session cookie (no expiry: not kept on disk) for a reserved domain.
    view.setCookie("https://zigulee.test/", "zigulee-test=1; Path=/; Secure; HttpOnly");
    view.html.set("<title>After</title>");
    webview.syncWindow(&ui);
    try testing.expect(view.native != null);
    try testing.expect(view.storing_cookies == 1 and view.held);
    // Stored, then the page loads.
    try spin(struct {
        fn f(v: *webview.WebView) bool {
            return std.mem.eql(u8, v.title.getUntracked(), "After") and !v.loading.getUntracked();
        }
    }.f, &view);
    try testing.expectEqual(@as(u32, 0), view.storing_cookies);
    // Not a cookie: nothing stored, nothing held.
    view.setCookie("https://zigulee.test/", "");
    try testing.expectEqual(@as(u32, 0), view.storing_cookies);
}

test "a page given as text: loaded, its title, JavaScript run in it" {
    if (ios) return error.SkipZigTest;
    webview.setProvider(provider);
    defer webview.setProvider(null);
    var view: webview.WebView = undefined;
    view.init(testing.allocator);
    defer view.deinit();
    var ui: zigulee.core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 200, .height = 100 });
    defer ui.deinit();
    const host = msg(id, msg(id, class("NSView"), "alloc", .{}), "initWithFrame:", .{CGRect{ .size = .{ .width = 200, .height = 100 } }});
    defer msg(void, host, "release", .{});
    ui.native_view = host;
    ui.rootItem().appendChild(&view.item);
    view.item.width.set(200);
    view.item.height.set(60);
    view.html.set("<title>Hello</title><p>zigulee</p>");
    webview.syncWindow(&ui);
    try testing.expect(view.native != null);
    const wk = of(view.native.?).wk;
    // Placed from the top of an unflipped view: 40 from its bottom.
    try testing.expectEqual(@as(f64, 40), msg(CGRect, wk, "frame", .{}).origin.y);

    try spin(struct {
        fn f(v: *webview.WebView) bool {
            return std.mem.eql(u8, v.title.getUntracked(), "Hello") and !v.loading.getUntracked();
        }
    }.f, &view);

    const Got = struct {
        var text: [32]u8 = undefined;
        var len: usize = 0;
        var errors: usize = 0;
        fn ok(_: *u8, r: []const u8) void {
            @memcpy(text[0..r.len], r);
            len = r.len;
        }
        fn bad(_: *u8, _: []const u8) void {
            errors += 1;
        }
    };
    var dummy: u8 = 0;
    view.javascript_finished.setHandler(&dummy, Got.ok);
    view.javascript_failed.setHandler(&dummy, Got.bad);
    view.runJavascript("document.querySelector('p').textContent + ' ' + (6 * 7)");
    try spin(struct {
        fn f(_: *webview.WebView) bool {
            return Got.len > 0;
        }
    }.f, &view);
    try testing.expectEqualStrings("zigulee 42", Got.text[0..Got.len]);
    view.runJavascript("({a: [1, true]})");
    Got.len = 0;
    try spin(struct {
        fn f(_: *webview.WebView) bool {
            return Got.len > 0;
        }
    }.f, &view);
    try testing.expectEqualStrings("{\"a\":[1,true]}", Got.text[0..Got.len]);
    view.runJavascript("no.such.thing");
    try spin(struct {
        fn f(_: *webview.WebView) bool {
            return Got.errors > 0;
        }
    }.f, &view);
}
