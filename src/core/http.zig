// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! HTTP requests (the `HttpRequest` element): `http://` and `https://`,
//! any method, with headers and a body, made on a thread of their own so
//! the UI goes on meanwhile; the answer's status and body come back on
//! the UI's thread. Without threads (microcontrollers, the web), requests
//! fail.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const properties = @import("properties.zig");
const Property = properties.Property;
const Callback = @import("callbacks.zig").Callback;
const model = @import("model.zig");
const item_mod = @import("item.zig");
const Timer = @import("timers.zig").Timer;

pub const threaded = !builtin.single_threaded and builtin.os.tag != .freestanding;

const log = std.log.scoped(.zigulee);

/// Answers bigger than this fail (with `error.StreamTooLong`).
pub const max_response = 64 << 20;

pub const Method = enum { get, post, put, patch, delete, head };

pub const Options = struct {
    method: Method = .get,
    url: []const u8,
    /// "Name: value" each.
    headers: []const []const u8 = &.{},
    body: []const u8 = "",
};

pub const Response = struct {
    status: u16,
    body: []u8,
};

/// A request in progress: `start` it, then `poll` until it is done (or
/// `cancel` it).
pub const Request = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    options: Options,
    /// Who frees it: the requester once done, the worker once cancelled
    /// (whichever comes second).
    state: std.atomic.Value(State) = .init(.running),
    result: anyerror!Response = error.Unfinished,

    pub const State = enum(u8) { running, done, cancelled };

    /// Starts `options` (copied) on a thread of its own.
    pub fn start(gpa: Allocator, options: Options) Allocator.Error!*Request {
        const r = try gpa.create(Request);
        r.* = .{ .gpa = gpa, .arena = .init(gpa), .options = undefined };
        errdefer r.free();
        const a = r.arena.allocator();
        const headers = try a.alloc([]const u8, options.headers.len);
        for (headers, options.headers) |*h, o| h.* = try a.dupe(u8, o);
        r.options = .{ .method = options.method, .url = try a.dupe(u8, options.url), .headers = headers, .body = try a.dupe(u8, options.body) };
        if (threaded) {
            if (std.Thread.spawn(.{}, run, .{r})) |t| {
                t.detach();
                return r;
            } else |_| {}
        }
        r.result = error.NoNetwork;
        r.state.store(.done, .release);
        return r;
    }

    fn run(r: *Request) void {
        r.result = fetch(r.gpa, r.options);
        // Its last touch, unless nobody wants it any more.
        if (r.state.cmpxchgStrong(.running, .done, .acq_rel, .acquire) != null) r.free();
    }

    /// The response, or what went wrong, once done (null while running).
    /// The response's body is the caller's; call `cancel` after.
    pub fn poll(r: *Request) ?(anyerror!Response) {
        if (r.state.load(.acquire) != .done) return null;
        const res = r.result;
        r.result = error.Taken;
        return res;
    }

    /// Lets go of the request (a response not taken goes too).
    pub fn cancel(r: *Request) void {
        // Still running: the worker frees it when done.
        if (r.state.cmpxchgStrong(.running, .cancelled, .acq_rel, .acquire) == null) return;
        r.free();
    }

    fn free(r: *Request) void {
        if (r.result) |res| r.gpa.free(res.body) else |_| {}
        r.arena.deinit();
        r.gpa.destroy(r);
    }
};

/// Makes the request, blocking.
pub fn fetch(gpa: Allocator, options: Options) !Response {
    var t: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer t.deinit();
    var client: std.http.Client = .{ .allocator = gpa, .io = t.io() };
    defer client.deinit();
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(gpa);
    for (options.headers) |h| {
        const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
        try headers.append(gpa, .{ .name = std.mem.trim(u8, h[0..colon], " "), .value = std.mem.trim(u8, h[colon + 1 ..], " ") });
    }
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const method: std.http.Method = switch (options.method) {
        .get => .GET,
        .post => .POST,
        .put => .PUT,
        .patch => .PATCH,
        .delete => .DELETE,
        .head => .HEAD,
    };
    const has_body = options.body.len > 0 or method.requestHasBody();
    const result = try client.fetch(.{
        .location = .{ .url = options.url },
        .method = method,
        .payload = if (has_body) options.body else null,
        .extra_headers = headers.items,
        .response_writer = &body.writer,
        .keep_alive = false,
    });
    if (body.written().len > max_response) return error.StreamTooLong;
    return .{ .status = @intFromEnum(result.status), .body = try body.toOwnedSlice() };
}

// ---- The HttpRequest element ----

/// Makes a request with `send()` (the `HttpRequest` element): the answer
/// is `status` and `response`, then `finished`; or `error`, then
/// `failed`, if there was none. Initialize in place with `init`.
pub const HttpRequest = struct {
    item: item_mod.Item = .init(&vtable),
    url: Property([]const u8) = .init(""),
    method: Property(Method) = .init(.get),
    /// "Name: value" each.
    headers: Property(model.Model([]const u8)) = .init(model.emptyModel([]const u8)),
    body: Property([]const u8) = .init(""),
    loading: Property(bool) = .init(false),
    /// The HTTP status of the last answer (0 before one, or without one).
    status: Property(i32) = .init(0),
    response: Property([]const u8) = .init(""),
    /// What went wrong when there was no answer ("" otherwise).
    error_text: Property([]const u8) = .init(""),
    finished: Callback(fn () void) = .{},
    failed: Callback(fn () void) = .{},

    gpa: Allocator = undefined,
    request: ?*Request = null,
    poll_timer: Timer = .{},
    /// What `response` and `error_text` show.
    response_owned: []u8 = &.{},
    error_owned: []u8 = &.{},

    pub fn init(self: *HttpRequest, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
    }

    pub fn deinit(self: *HttpRequest) void {
        self.poll_timer.deinit();
        if (self.request) |r| r.cancel();
        self.item.deinit();
        inline for (.{ "url", "method", "headers", "body", "loading", "status", "response", "error_text" }) |f| @field(self, f).deinit();
        self.gpa.free(self.response_owned);
        self.gpa.free(self.error_owned);
    }

    /// Makes the request (dropping one still running).
    pub fn send(self: *HttpRequest) void {
        self.abort();
        var headers: std.ArrayList([]const u8) = .empty;
        defer headers.deinit(self.gpa);
        const m = self.headers.getUntracked();
        for (0..m.vtable.rowCount(m.ptr)) |i| headers.append(self.gpa, m.vtable.rowData(m.ptr, i) orelse continue) catch {};
        self.request = Request.start(self.gpa, .{
            .method = self.method.getUntracked(),
            .url = self.url.getUntracked(),
            .headers = headers.items,
            .body = self.body.getUntracked(),
        }) catch return self.fail(error.OutOfMemory);
        self.loading.set(true);
        self.poll_timer.start(.repeated, 15, self, poll);
        self.poll();
    }

    /// Drops the request running, if any (no answer comes).
    pub fn abort(self: *HttpRequest) void {
        const r = self.request orelse return;
        r.cancel();
        self.request = null;
        self.poll_timer.stop();
        self.loading.set(false);
    }

    fn poll(self: *HttpRequest) void {
        const r = self.request orelse return;
        const result = r.poll() orelse return;
        r.cancel();
        self.request = null;
        self.poll_timer.stop();
        const res = result catch |err| return self.fail(err);
        const old = self.response_owned;
        self.response_owned = res.body;
        self.setError("");
        self.status.set(res.status);
        self.response.set(res.body);
        self.gpa.free(old);
        self.loading.set(false);
        self.finished.call(.{});
    }

    fn fail(self: *HttpRequest, err: anyerror) void {
        log.warn("request to '{s}' failed: {t}", .{ self.url.getUntracked(), err });
        self.setError(@errorName(err));
        self.status.set(0);
        self.loading.set(false);
        self.failed.call(.{});
    }

    fn setError(self: *HttpRequest, text: []const u8) void {
        const copy = self.gpa.dupe(u8, text) catch return;
        const old = self.error_owned;
        self.error_owned = copy;
        self.error_text.set(copy);
        self.gpa.free(old);
    }

    const vtable: item_mod.ItemVTable = .{ .name = "HttpRequest" };
};

// ---- Testing ----

/// For tests: a server on this machine, answering each request with what
/// it was asked as JSON (its `method`, `path`, `X-Token` header as
/// `token` and `body`, and two `items`), or 404 for `/missing`. It serves
/// until `stop`.
pub const EchoServer = struct {
    threaded_io: std.Io.Threaded,
    server: std.Io.net.Server,
    port: u16,
    thread: std.Thread,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *EchoServer) !void {
        self.* = .{ .threaded_io = .init(std.heap.page_allocator, .{}), .server = undefined, .port = 0, .thread = undefined };
        const io = self.threaded_io.io();
        const addr: std.Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
        self.server = try addr.listen(io, .{ .reuse_address = true });
        self.port = self.server.socket.address.getPort();
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn serve(self: *EchoServer) void {
        const io = self.threaded_io.io();
        while (true) {
            var stream = self.server.accept(io) catch return;
            defer stream.close(io);
            if (self.stopping.load(.acquire)) return;
            var recv: [8192]u8 = undefined;
            var send_buf: [8192]u8 = undefined;
            var reader = stream.reader(io, &recv);
            var writer = stream.writer(io, &send_buf);
            var server: std.http.Server = .init(&reader.interface, &writer.interface);
            var req = server.receiveHead() catch continue;
            if (std.mem.eql(u8, req.head.target, "/missing")) {
                req.respond("{\"error\":\"none here\"}", .{ .status = .not_found, .keep_alive = false }) catch {};
                continue;
            }
            var token: []const u8 = "";
            var it = req.iterateHeaders();
            while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "x-token")) {
                token = h.value;
            };
            const token_copy = std.heap.page_allocator.dupe(u8, token) catch continue;
            defer std.heap.page_allocator.free(token_copy);
            const method = @tagName(req.head.method);
            const target = std.heap.page_allocator.dupe(u8, req.head.target) catch continue;
            defer std.heap.page_allocator.free(target);
            var body_buf: [1024]u8 = undefined;
            const body_reader = req.readerExpectNone(&body_buf);
            var body: [1024]u8 = undefined;
            const n = if (req.head.content_length) |len| blk: {
                body_reader.readSliceAll(body[0..@intCast(len)]) catch continue;
                break :blk len;
            } else 0;
            var out: [2048]u8 = undefined;
            const answer = std.fmt.bufPrint(&out, "{{\"method\":\"{s}\",\"path\":\"{s}\",\"token\":\"{s}\",\"body\":\"{s}\",\"items\":[{{\"n\":1}},{{\"n\":2}}]}}", .{ method, target, token_copy, body[0..@intCast(n)] }) catch continue;
            req.respond(answer, .{ .keep_alive = false }) catch {};
        }
    }

    /// `http://127.0.0.1:<port><path>`, in `buf`.
    pub fn url(self: *const EchoServer, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.port, path }) catch unreachable;
    }

    pub fn stop(self: *EchoServer) void {
        const io = self.threaded_io.io();
        self.stopping.store(true, .release);
        const at: std.Io.net.IpAddress = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch unreachable;
        if (at.connect(io, .{ .mode = .stream })) |conn| {
            var c = conn;
            c.close(io);
        } else |_| {}
        self.thread.join();
        self.server.deinit(io);
        self.threaded_io.deinit();
    }
};

// ---- Tests ----

const testing = std.testing;
const timers = @import("timers.zig");
const time = @import("time.zig");

fn waitFor(el: *HttpRequest) !void {
    for (0..2000) |_| {
        if (!el.loading.get()) return;
        time.advanceTo(time.now() + 15);
        timers.updateTimers();
        var t: std.Io.Threaded = .init_single_threaded;
        t.io().sleep(.fromMilliseconds(2), .awake) catch {};
    }
    return error.Timeout;
}

test "requests: a method, headers and a body sent; the answer, a 404, no server" {
    if (!threaded) return error.SkipZigTest;
    var server: EchoServer = undefined;
    try server.start();
    defer server.stop();
    var url_buf: [64]u8 = undefined;

    var el: HttpRequest = undefined;
    el.init(testing.allocator);
    defer el.deinit();
    const Count = struct {
        finished: u32 = 0,
        failed: u32 = 0,
        fn onFinished(c: *@This()) void {
            c.finished += 1;
        }
        fn onFailed(c: *@This()) void {
            c.failed += 1;
        }
    };
    var count: Count = .{};
    el.finished.setHandler(&count, Count.onFinished);
    el.failed.setHandler(&count, Count.onFailed);

    var headers: model.SliceModel([]const u8) = .init(&.{ "X-Token: abc", "Content-Type: application/json" });
    defer headers.deinit();
    el.url.set(server.url(&url_buf, "/items?page=2"));
    el.method.set(.post);
    el.headers.set(headers.model());
    el.body.set("hello");
    el.send();
    try testing.expect(el.loading.get());
    try waitFor(&el);
    try testing.expectEqual(@as(i32, 200), el.status.get());
    try testing.expectEqualStrings("{\"method\":\"POST\",\"path\":\"/items?page=2\",\"token\":\"abc\",\"body\":\"hello\",\"items\":[{\"n\":1},{\"n\":2}]}", el.response.get());
    try testing.expectEqual(@as(u32, 1), count.finished);

    el.url.set(server.url(&url_buf, "/missing"));
    el.method.set(.get);
    el.body.set("");
    el.send();
    try waitFor(&el);
    try testing.expectEqual(@as(i32, 404), el.status.get());
    try testing.expectEqualStrings("", el.error_text.get());
    try testing.expectEqual(@as(u32, 2), count.finished);

    // Sent again before the answer: only the second one answers.
    el.url.set(server.url(&url_buf, "/first"));
    el.send();
    el.url.set(server.url(&url_buf, "/second"));
    el.send();
    try waitFor(&el);
    try testing.expect(std.mem.indexOf(u8, el.response.get(), "/second") != null);
    try testing.expectEqual(@as(u32, 3), count.finished);

    // Nobody listening.
    el.url.set("http://127.0.0.1:1/");
    el.send();
    try waitFor(&el);
    try testing.expectEqual(@as(i32, 0), el.status.get());
    try testing.expect(el.error_text.get().len > 0);
    try testing.expectEqual(@as(u32, 1), count.failed);
}
