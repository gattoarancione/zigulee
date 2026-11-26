// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Web content (`WebView`): a native web view (WKWebView, an `<iframe>`
//! on the web) made by a backend's provider (`setProvider`) and placed
//! over the element, in the window's native view (`Window.native_view`).
//! It always shows above zigulee's content (popups too), unrotated and
//! unclipped by its ancestors; hidden with the element.
//!
//! Native views are made once the element is in a window, and follow its
//! geometry after each render (`syncWindow`). What the page does comes
//! back through `reportLoading` and the like, on the UI thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const ChangeTracker = @import("properties.zig").ChangeTracker;
const Callback = @import("callbacks.zig").Callback;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const Window = @import("window.zig").Window;
const StringBuffer = @import("strings.zig").StringBuffer;

const log = std.log.scoped(.zigulee);

/// A backend's web views. `Native` is the backend's handle.
pub const Provider = struct {
    ctx: ?*anyopaque = null,
    vtable: *const VTable,

    pub const Native = anyopaque;

    pub const VTable = struct {
        /// A web view in `host` (the window's `native_view`, null where the
        /// backend has none), hidden until placed; null if it cannot.
        create: *const fn (ctx: ?*anyopaque, host: ?*anyopaque, view: *WebView) ?*Native,
        destroy: *const fn (ctx: ?*anyopaque, native: *Native) void,
        /// Where it shows, in the window's coordinates (logical pixels,
        /// from the top left), and whether it does.
        place: *const fn (ctx: ?*anyopaque, native: *Native, rect: Rect, visible: bool) void,
        load_url: *const fn (ctx: ?*anyopaque, native: *Native, url: []const u8) void,
        load_html: *const fn (ctx: ?*anyopaque, native: *Native, html: []const u8) void,
        back: *const fn (ctx: ?*anyopaque, native: *Native) void,
        forward: *const fn (ctx: ?*anyopaque, native: *Native) void,
        reload: *const fn (ctx: ?*anyopaque, native: *Native) void,
        stop: *const fn (ctx: ?*anyopaque, native: *Native) void,
        /// Runs `code` in the page; the result comes through
        /// `reportJavaScript`, in order.
        run_javascript: *const fn (ctx: ?*anyopaque, native: *Native, code: []const u8) void,
        /// Stores a cookie for the web views (a `Set-Cookie` header's
        /// value, for `url`: HttpOnly and Secure kept); `reportCookieStored`
        /// once it is, or could not be. Null: not on this platform.
        set_cookie: ?*const fn (ctx: ?*anyopaque, native: *Native, url: []const u8, cookie: []const u8) void = null,
    };
};

var provider: ?Provider = null;
var views: std.ArrayList(*WebView) = .empty;

pub fn setProvider(p: ?Provider) void {
    for (views.items) |v| v.dropNative();
    provider = p;
    for (views.items) |v| v.available.set(p != null);
}

pub fn hasWebViews() bool {
    return provider != null;
}

/// Makes the native views of `window`'s web views that have none yet, and
/// places them where their elements are now. The window calls it after
/// rendering.
pub fn syncWindow(window: *Window) void {
    for (views.items) |v| if (v.item.window() == window) v.sync(window);
}

/// `syncWindow` for every window (web views are also made between frames).
pub fn update() void {
    for (views.items) |v| if (v.item.window()) |w| v.sync(w);
}

/// The web view `native` is, if it is still there.
fn find(native: *Provider.Native) ?*WebView {
    for (views.items) |v| if (v.native == native) return v;
    return null;
}

// ---- What the page did (on the UI thread) ----

/// A page started (`true`) or stopped loading.
pub fn reportLoading(native: *Provider.Native, loading: bool) void {
    const v = find(native) orelse return;
    v.loading.set(loading);
}

/// A page finished loading, or failed with `error_text`.
pub fn reportFinished(native: *Provider.Native, error_text: ?[]const u8) void {
    const v = find(native) orelse return;
    v.loading.set(false);
    if (error_text) |e| {
        v.error_text.set(v.error_buffer.format(v.gpa, "{s}", .{e}));
        v.failed.call(.{});
    } else {
        v.error_text.set("");
        v.finished.call(.{});
    }
}

/// The page shown is at `url` now (a link followed, a redirect): `url`
/// says so, without loading it again.
pub fn reportUrl(native: *Provider.Native, url: []const u8) void {
    const v = find(native) orelse return;
    if (std.mem.eql(u8, url, v.url.getUntracked())) return;
    const s = v.url_buffer.format(v.gpa, "{s}", .{url});
    v.applied.url = std.hash.Wyhash.hash(0, s);
    v.url.set(s);
}

pub fn reportTitle(native: *Provider.Native, title: []const u8) void {
    const v = find(native) orelse return;
    v.title.set(v.title_buffer.format(v.gpa, "{s}", .{title}));
}

pub fn reportHistory(native: *Provider.Native, can_go_back: bool, can_go_forward: bool) void {
    const v = find(native) orelse return;
    v.can_go_back.set(can_go_back);
    v.can_go_forward.set(can_go_forward);
}

/// A `set_cookie` is done: stored, or not (`ok` false: it could not be
/// read). Pages held for the cookies load once they all are.
pub fn reportCookieStored(native: *Provider.Native, ok: bool) void {
    const v = find(native) orelse return;
    if (!ok) log.warn("web view: a cookie could not be set", .{});
    v.storing_cookies -|= 1;
    if (v.storing_cookies == 0 and v.held) {
        v.held = false;
        v.show();
    }
}

/// The result of a `run_javascript` (as text: a string as it is, other
/// values as the page would print them), or its error.
pub fn reportJavaScript(native: *Provider.Native, result: []const u8, failed: bool) void {
    const v = find(native) orelse return;
    const s = v.result_buffer.format(v.gpa, "{s}", .{result});
    if (failed) v.javascript_failed.call(.{s}) else v.javascript_finished.call(.{s});
}

// ---- The element ----

/// A web page (`WebView`): `url` loads (and follows the page's
/// navigation), or `html` shows that text. Initialize in place with
/// `init`.
pub const WebView = struct {
    item: Item = .init(&vtable),
    url: Property([]const u8) = .init(""),
    html: Property([]const u8) = .init(""),
    title: Property([]const u8) = .init(""),
    loading: Property(bool) = .init(false),
    can_go_back: Property(bool) = .init(false),
    can_go_forward: Property(bool) = .init(false),
    /// What went wrong with the last page ("" otherwise).
    error_text: Property([]const u8) = .init(""),
    /// The platform has web views (the backend made one).
    available: Property(bool) = .init(false),
    finished: Callback(fn () void) = .{},
    failed: Callback(fn () void) = .{},
    javascript_finished: Callback(fn ([]const u8) void) = .{},
    javascript_failed: Callback(fn ([]const u8) void) = .{},

    gpa: Allocator = undefined,
    native: ?*Provider.Native = null,
    /// No native view could be made in this window.
    failed_in: ?*Window = null,
    tracker: ChangeTracker(Source) = undefined,
    /// What the native view shows (hashes: the strings may go).
    applied: Source = .{},
    placed: ?Placement = null,
    url_buffer: StringBuffer = .{},
    title_buffer: StringBuffer = .{},
    error_buffer: StringBuffer = .{},
    result_buffer: StringBuffer = .{},
    /// Cookies set before there was a native view, sent when there is
    /// (each its URL, then its value).
    cookies: std.ArrayList([]const u8) = .empty,
    /// Cookies sent and not stored yet: pages wait for them.
    storing_cookies: u32 = 0,
    /// A page waits for the cookies.
    held: bool = false,

    const Source = struct { url: u64 = 0, html: u64 = 0 };
    const Placement = struct { rect: Rect, visible: bool };

    pub fn init(self: *WebView, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.available.set(hasWebViews());
        views.append(gpa, self) catch {};
        self.tracker.init(gpa, self, source, sourceChanged);
        self.applied = self.tracker.value;
    }

    pub fn deinit(self: *WebView) void {
        self.dropNative();
        for (views.items, 0..) |v, i| if (v == self) {
            _ = views.orderedRemove(i);
            break;
        };
        if (views.items.len == 0) {
            views.deinit(self.gpa);
            views = .empty;
        }
        self.tracker.deinit();
        self.item.deinit();
        inline for (.{ "url", "html", "title", "loading", "can_go_back", "can_go_forward", "error_text", "available" }) |f| @field(self, f).deinit();
        inline for (.{ "url_buffer", "title_buffer", "error_buffer", "result_buffer" }) |f| @field(self, f).deinit(self.gpa);
        for (self.cookies.items) |s| self.gpa.free(s);
        self.cookies.deinit(self.gpa);
    }

    fn source(self: *WebView) Source {
        return .{ .url = std.hash.Wyhash.hash(0, self.url.get()), .html = std.hash.Wyhash.hash(0, self.html.get()) };
    }

    /// `url` or `html` changed: shown, unless the page itself got there.
    fn sourceChanged(self: *WebView, s: Source) void {
        const was = self.applied;
        self.applied = s;
        if (s.url != was.url or s.html != was.html) self.show();
    }

    /// Loads what `url` and `html` say (`html` when set).
    fn show(self: *WebView) void {
        const p = provider orelse return;
        const n = self.native orelse return;
        if (self.storing_cookies > 0) {
            self.held = true;
            return;
        }
        const html = self.html.getUntracked();
        const url = self.url.getUntracked();
        if (html.len > 0) {
            p.vtable.load_html(p.ctx, n, html);
        } else if (url.len > 0) {
            p.vtable.load_url(p.ctx, n, url);
        }
    }

    fn sync(self: *WebView, window: *Window) void {
        const p = provider orelse return;
        if (self.native == null) {
            if (self.failed_in == window) return;
            self.native = p.vtable.create(p.ctx, window.native_view, self) orelse {
                log.info("no web view in this window", .{});
                self.failed_in = window;
                self.available.set(false);
                return;
            };
            self.available.set(true);
            self.placed = null;
            self.sendCookies();
            self.show();
        }
        const pos = self.item.absolutePosition();
        const size = self.item.size();
        const rect: Rect = .{ .x = pos.x, .y = pos.y, .width = size.width, .height = size.height };
        const visible = self.item.isVisibleInTree() and size.width > 0 and size.height > 0;
        if (self.placed) |was| if (was.visible == visible and std.meta.eql(was.rect, rect)) return;
        self.placed = .{ .rect = rect, .visible = visible };
        p.vtable.place(p.ctx, self.native.?, rect, visible);
    }

    fn dropNative(self: *WebView) void {
        const n = self.native orelse return;
        self.native = null;
        self.failed_in = null;
        self.storing_cookies = 0;
        self.held = false;
        if (provider) |p| p.vtable.destroy(p.ctx, n);
    }

    fn call(self: *WebView, comptime f: []const u8) void {
        const p = provider orelse return;
        const n = self.native orelse return;
        @field(p.vtable, f)(p.ctx, n);
    }

    pub fn back(self: *WebView) void {
        self.call("back");
    }
    pub fn forward(self: *WebView) void {
        self.call("forward");
    }
    pub fn reload(self: *WebView) void {
        self.call("reload");
    }
    pub fn stop(self: *WebView) void {
        self.call("stop");
    }

    /// Runs `code` in the page: `javascript-finished(result)` then, or
    /// `javascript-failed(error)`.
    pub fn runJavascript(self: *WebView, code: []const u8) void {
        const p = provider orelse return;
        const n = self.native orelse return;
        p.vtable.run_javascript(p.ctx, n, code);
    }

    /// Stores a cookie for `url`, as a server's `Set-Cookie` header would
    /// (`"session=abc; Path=/; Secure; HttpOnly"`): a session the app has
    /// natively handed over, HttpOnly included (which the page's
    /// JavaScript cannot set). Pages loaded after it wait until it is
    /// stored. Before the web view is made, kept until it is.
    pub fn setCookie(self: *WebView, url: []const u8, cookie: []const u8) void {
        const p = provider orelse return;
        if (p.vtable.set_cookie == null) {
            log.warn("web view: cookies cannot be set on this platform", .{});
            return;
        }
        if (self.native == null) {
            const u = self.gpa.dupe(u8, url) catch return;
            const c = self.gpa.dupe(u8, cookie) catch {
                self.gpa.free(u);
                return;
            };
            self.cookies.appendSlice(self.gpa, &.{ u, c }) catch {
                self.gpa.free(u);
                self.gpa.free(c);
            };
            return;
        }
        self.storing_cookies += 1;
        p.vtable.set_cookie.?(p.ctx, self.native.?, url, cookie);
    }

    /// The cookies kept until there was a native view.
    fn sendCookies(self: *WebView) void {
        const p = provider orelse return;
        const set = p.vtable.set_cookie orelse return;
        const n = self.native orelse return;
        var i: usize = 0;
        while (i + 1 < self.cookies.items.len) : (i += 2) {
            self.storing_cookies += 1;
            set(p.ctx, n, self.cookies.items[i], self.cookies.items[i + 1]);
        }
        for (self.cookies.items) |s| self.gpa.free(s);
        self.cookies.clearRetainingCapacity();
    }

    const vtable: item_mod.ItemVTable = .{ .name = "WebView" };
};

// ---- Tests ----

const testing = std.testing;
const runChangeHandlers = @import("properties.zig").runChangeHandlers;

/// A provider that records what it is asked.
const Fake = struct {
    created: usize = 0,
    destroyed: usize = 0,
    rect: Rect = .{},
    visible: bool = false,
    loaded: [64]u8 = undefined,
    loaded_len: usize = 0,
    html: bool = false,
    reloads: usize = 0,
    code_len: usize = 0,
    host: ?*anyopaque = null,
    token: u8 = 0,
    /// Makes none (as without the platform's web engine).
    refuse: bool = false,
    /// The cookies asked for, each `url|cookie`.
    cookies: [4][64]u8 = undefined,
    cookie_lens: [4]usize = undefined,
    cookie_count: usize = 0,

    fn provider(self: *Fake) Provider {
        return .{ .ctx = self, .vtable = &.{
            .create = create,
            .destroy = destroy,
            .place = place,
            .load_url = loadUrl,
            .load_html = loadHtml,
            .back = noop,
            .forward = noop,
            .reload = reloadIt,
            .stop = noop,
            .run_javascript = runJs,
            .set_cookie = setCookie,
        } };
    }
    fn of(ctx: ?*anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }
    fn create(ctx: ?*anyopaque, host: ?*anyopaque, _: *WebView) ?*Provider.Native {
        if (of(ctx).refuse) return null;
        of(ctx).created += 1;
        of(ctx).host = host;
        return &of(ctx).token;
    }
    fn destroy(ctx: ?*anyopaque, _: *Provider.Native) void {
        of(ctx).destroyed += 1;
    }
    fn place(ctx: ?*anyopaque, _: *Provider.Native, rect: Rect, visible: bool) void {
        of(ctx).rect = rect;
        of(ctx).visible = visible;
    }
    fn loadUrl(ctx: ?*anyopaque, _: *Provider.Native, url: []const u8) void {
        @memcpy(of(ctx).loaded[0..url.len], url);
        of(ctx).loaded_len = url.len;
        of(ctx).html = false;
    }
    fn loadHtml(ctx: ?*anyopaque, _: *Provider.Native, html: []const u8) void {
        @memcpy(of(ctx).loaded[0..html.len], html);
        of(ctx).loaded_len = html.len;
        of(ctx).html = true;
    }
    fn noop(_: ?*anyopaque, _: *Provider.Native) void {}
    fn reloadIt(ctx: ?*anyopaque, _: *Provider.Native) void {
        of(ctx).reloads += 1;
    }
    fn runJs(ctx: ?*anyopaque, n: *Provider.Native, code: []const u8) void {
        of(ctx).code_len = code.len;
        reportJavaScript(n, "42", false);
    }
    fn setCookie(ctx: ?*anyopaque, _: *Provider.Native, url: []const u8, cookie: []const u8) void {
        const self = of(ctx);
        const s = std.fmt.bufPrint(&self.cookies[self.cookie_count], "{s}|{s}", .{ url, cookie }) catch unreachable;
        self.cookie_lens[self.cookie_count] = s.len;
        self.cookie_count += 1;
    }
    fn cookieAt(self: *const Fake, i: usize) []const u8 {
        return self.cookies[i][0..self.cookie_lens[i]];
    }
    fn shown(self: *const Fake) []const u8 {
        return self.loaded[0..self.loaded_len];
    }
};

test "a web view: made in its window, placed, loading, following the page" {
    const gpa = testing.allocator;
    var fake: Fake = .{};
    setProvider(fake.provider());
    defer setProvider(null);
    var view: WebView = undefined;
    view.init(gpa);
    defer view.deinit();
    var window: Window = undefined;
    window.init(gpa, .{ .width = 300, .height = 200 });
    defer window.deinit();
    var host: u8 = 0;
    window.native_view = &host;
    try testing.expect(view.available.get());

    view.url.set("https://ziglang.org");
    runChangeHandlers();
    try testing.expectEqual(@as(usize, 0), fake.created); // not in a window yet
    window.rootItem().appendChild(&view.item);
    view.item.x.set(10);
    view.item.y.set(20);
    view.item.width.set(200);
    view.item.height.set(100);
    syncWindow(&window);
    try testing.expectEqual(@as(usize, 1), fake.created);
    try testing.expect(fake.host == @as(?*anyopaque, &host));
    try testing.expectEqualStrings("https://ziglang.org", fake.shown());
    try testing.expectEqual(Rect{ .x = 10, .y = 20, .width = 200, .height = 100 }, fake.rect);
    try testing.expect(fake.visible);

    view.item.visible.set(false);
    syncWindow(&window);
    try testing.expect(!fake.visible);
    view.item.visible.set(true);

    // The page.
    const n: *Provider.Native = &fake.token;
    reportLoading(n, true);
    try testing.expect(view.loading.get());
    var finished: usize = 0;
    view.finished.setHandler(&finished, struct {
        fn f(k: *usize) void {
            k.* += 1;
        }
    }.f);
    reportTitle(n, "Zig");
    reportHistory(n, true, false);
    reportFinished(n, null);
    try testing.expect(!view.loading.get());
    try testing.expectEqual(@as(usize, 1), finished);
    try testing.expectEqualStrings("Zig", view.title.get());
    try testing.expect(view.can_go_back.get());
    // A link followed: `url` follows, nothing loads again.
    fake.loaded_len = 0;
    reportUrl(n, "https://ziglang.org/learn/");
    runChangeHandlers();
    try testing.expectEqualStrings("https://ziglang.org/learn/", view.url.get());
    try testing.expectEqual(@as(usize, 0), fake.loaded_len);
    // Set from the UI: loads.
    view.url.set("https://example.com");
    runChangeHandlers();
    try testing.expectEqualStrings("https://example.com", fake.shown());
    view.html.set("<b>hi</b>");
    runChangeHandlers();
    try testing.expect(fake.html);
    reportFinished(n, "offline");
    try testing.expectEqualStrings("offline", view.error_text.get());

    view.reload();
    try testing.expectEqual(@as(usize, 1), fake.reloads);
    var result: [8]u8 = undefined;
    var result_len: usize = 0;
    const Got = struct { buf: *[8]u8, len: *usize };
    var got: Got = .{ .buf = &result, .len = &result_len };
    view.javascript_finished.setHandler(&got, struct {
        fn f(g: *Got, r: []const u8) void {
            @memcpy(g.buf[0..r.len], r);
            g.len.* = r.len;
        }
    }.f);
    view.runJavascript("6 * 7");
    try testing.expectEqualStrings("42", result[0..result_len]);

    setProvider(null);
    try testing.expectEqual(@as(usize, 1), fake.destroyed);
    try testing.expect(!view.available.get());
}

test "cookies: kept until the web view is made, and pages wait until they are stored" {
    const gpa = testing.allocator;
    var fake: Fake = .{};
    setProvider(fake.provider());
    defer setProvider(null);
    var view: WebView = undefined;
    view.init(gpa);
    defer view.deinit();
    var window: Window = undefined;
    window.init(gpa, .{ .width = 300, .height = 200 });
    defer window.deinit();
    var host: u8 = 0;
    window.native_view = &host;

    // Set before there is a native view (the app's start): kept.
    var session = "session=abc; Path=/; Secure; HttpOnly".*;
    view.setCookie("https://example.com", &session);
    @memset(&session, 'x'); // the caller's text may go
    view.url.set("https://example.com/account");
    runChangeHandlers();
    try testing.expectEqual(@as(usize, 0), fake.cookie_count);

    window.rootItem().appendChild(&view.item);
    view.item.width.set(200);
    view.item.height.set(100);
    syncWindow(&window);
    try testing.expectEqual(@as(usize, 1), fake.cookie_count);
    try testing.expectEqualStrings("https://example.com|session=abc; Path=/; Secure; HttpOnly", fake.cookieAt(0));
    // The page waits for it.
    try testing.expectEqualStrings("", fake.shown());
    const n: *Provider.Native = &fake.token;
    reportCookieStored(n, true);
    try testing.expectEqualStrings("https://example.com/account", fake.shown());

    // Set once it is made: sent now, and the next page waits too.
    view.setCookie("https://example.com", "theme=dark");
    try testing.expectEqual(@as(usize, 2), fake.cookie_count);
    view.url.set("https://example.com/settings");
    runChangeHandlers();
    try testing.expectEqualStrings("https://example.com/account", fake.shown());
    reportCookieStored(n, false); // not stored: the page loads all the same
    try testing.expectEqualStrings("https://example.com/settings", fake.shown());
}

test "a web view the backend cannot make: not available" {
    const gpa = testing.allocator;
    var fake: Fake = .{ .refuse = true };
    setProvider(fake.provider());
    defer setProvider(null);
    var view: WebView = undefined;
    view.init(gpa);
    defer view.deinit();
    var window: Window = undefined;
    window.init(gpa, .{ .width = 300, .height = 200 });
    defer window.deinit();
    window.rootItem().appendChild(&view.item);
    try testing.expect(view.available.get());
    syncWindow(&window);
    try testing.expect(!view.available.get());
    try testing.expectEqual(@as(usize, 0), fake.created);
}
