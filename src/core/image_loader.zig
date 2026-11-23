// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Images loaded while the program runs: from a file (a path, or a
//! `file://` URL) or the network (`http://`, `https://`, with headers of
//! one's own, its progress followed), decoded (PNG, GIF, SVG) on a thread
//! of their own so the UI goes on meanwhile. Without threads, files load
//! at once, and the network is reached through the platform's `fetcher`
//! (the browser's, on the web) or not at all (microcontrollers). `Shared` keeps them by URL for all who show them, and for a
//! while after.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const image = @import("image.zig");
const png = @import("png.zig");
const gif = @import("gif.zig");
const animated = @import("animated.zig");
const svg = @import("svg.zig");

pub const threaded = !builtin.single_threaded and builtin.os.tag != .freestanding;
const has_files = builtin.os.tag != .freestanding;

const log = std.log.scoped(.zigulee_images);

pub const Error = error{
    /// No such file, or the server said no.
    NotFound,
    /// Not a PNG, GIF or SVG (or a broken one).
    InvalidImage,
    /// The network could not be reached, or not here.
    NetworkFailed,
} || Allocator.Error;

/// A decoded image and what it owns.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    image: image.Image,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
    }
};

/// Each image loaded is a new version: renderers that keep images by their
/// pixels' address (a GPU's textures) do not take one for another freed
/// there before.
var versions: std.atomic.Value(u32) = .init(1);

/// Decodes `bytes` (PNG, GIF's first frame, SVG) into an image owning its
/// data. `bytes` must stay as long as the image does when animated (it is
/// the animation), so they are copied into it.
pub fn decode(gpa: Allocator, bytes: []const u8) Error!Loaded {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const version = versions.fetchAdd(1, .monotonic);
    if (svg.isSvg(bytes)) {
        const d = try a.create(svg.Drawing);
        d.* = svg.parse(a, bytes) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidImage;
        return .{ .arena = arena, .image = .{ .width = @intFromFloat(@ceil(d.width)), .height = @intFromFloat(@ceil(d.height)), .pixels = &.{}, .vector = d, .version = version } };
    }
    const owned = (if (gif.isGif(bytes)) animated.decodeGif(a, bytes) else png.decode(a, bytes)) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidImage;
    const anim: []const u8 = if (animated.isAnimated(a, bytes)) try a.dupe(u8, bytes) else "";
    return .{ .arena = arena, .image = .{ .width = owned.width, .height = owned.height, .pixels = owned.pixels, .animation = anim, .version = version, .is_opaque = image.allOpaque(owned.pixels) } };
}

fn isNetwork(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://");
}

/// How to load: what to say to servers, and where to keep what comes from
/// the network.
pub const Options = struct {
    /// The User-Agent header (null: the HTTP client's).
    user_agent: ?[]const u8 = null,
    /// More headers, each `Name: value`.
    headers: []const []const u8 = &.{},
    /// A file keeping what was fetched, read instead while younger than
    /// `max_age_s` (null: none).
    cache_path: ?[]const u8 = null,
    max_age_s: i64 = 7 * 24 * 60 * 60,
};

/// The bytes at `url` (allocated with `gpa`). Blocks: run it off the UI's
/// thread when it can take a while.
pub fn fetch(gpa: Allocator, url: []const u8) Error![]u8 {
    return fetchWith(gpa, url, .{});
}

/// `fetch` as `options` say.
pub fn fetchWith(gpa: Allocator, url: []const u8, options: Options) Error![]u8 {
    return fetchCounting(gpa, url, options, null);
}

/// How much of a body has come, and how much there is (0: not said).
pub const Progress = struct {
    /// (Bytes in a `usize`: 32-bit targets have no 64-bit atomics, and
    /// bodies are at most `max_body`.)
    received: std.atomic.Value(usize) = .init(0),
    total: std.atomic.Value(usize) = .init(0),

    /// From 0 to 1 (0 while the size is not known).
    pub fn fraction(p: *const Progress) f32 {
        const total = p.total.load(.monotonic);
        if (total == 0) return 0;
        const got: f32 = @floatFromInt(@min(p.received.load(.monotonic), total));
        return got / @as(f32, @floatFromInt(total));
    }
};

/// `fetchWith`, counting what comes into `progress`.
fn fetchCounting(gpa: Allocator, url: []const u8, options: Options, progress: ?*Progress) Error![]u8 {
    if (isNetwork(url)) {
        if (!threaded) return error.NetworkFailed;
        if (options.cache_path) |path| if (readFresh(gpa, path, options.max_age_s)) |bytes| return bytes;
        const bytes = try fetchHttp(gpa, url, options, progress);
        if (options.cache_path) |path| @import("settings.zig").writeFile(gpa, path, bytes) catch |err|
            log.info("cannot keep '{s}' in the cache: {t}", .{ url, err });
        return bytes;
    }
    if (!has_files) return error.NotFound;
    const path = if (std.ascii.startsWithIgnoreCase(url, "file://")) url["file://".len..] else url;
    var t: std.Io.Threaded = .init_single_threaded;
    return std.Io.Dir.cwd().readFileAlloc(t.io(), path, gpa, .limited(256 << 20)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.NotFound,
    };
}

/// The file at `path` if it is younger than `max_age_s` seconds.
fn readFresh(gpa: Allocator, path: []const u8, max_age_s: i64) ?[]u8 {
    if (!has_files) return null;
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch return null;
    const age_ns = std.Io.Clock.real.now(io).nanoseconds - st.mtime.nanoseconds;
    if (age_ns > @as(i96, max_age_s) * std.time.ns_per_s) return null;
    return cwd.readFileAlloc(io, path, gpa, .limited(64 << 20)) catch null;
}

/// The largest body read.
const max_body = 256 << 20;

/// A GET of `url` (as `std.http.Client.fetch` makes it), the body counted
/// into `progress` as it comes.
fn fetchHttp(gpa: Allocator, url: []const u8, options: Options, progress: ?*Progress) Error![]u8 {
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
    return fetchFrom(gpa, &client, url, options.user_agent, headers.items, progress) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotFound => error.NotFound,
        else => {
            log.warn("cannot fetch '{s}': {t}", .{ url, err });
            return error.NetworkFailed;
        },
    };
}

fn fetchFrom(gpa: Allocator, client: *std.http.Client, url: []const u8, user_agent: ?[]const u8, headers: []const std.http.Header, progress: ?*Progress) ![]u8 {
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(3),
        .headers = .{ .user_agent = if (user_agent) |ua| .{ .override = ua } else .default },
        .extra_headers = headers,
        .keep_alive = false,
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (response.head.status.class() != .success) return error.NotFound;
    if (progress) |p| if (response.head.content_length) |n| p.total.store(@intCast(@min(n, max_body)), .monotonic);
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer gpa.free(decompress_buffer);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    while (true) {
        _ = reader.stream(&body.writer, .limited(64 * 1024)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return response.bodyErr().?,
            error.WriteFailed => return error.OutOfMemory,
        };
        if (progress) |p| p.received.store(body.written().len, .monotonic);
        if (body.written().len > max_body) return error.StreamTooLong;
    }
    return body.toOwnedSlice();
}

/// Fetches and decodes `url`, blocking.
pub fn load(gpa: Allocator, url: []const u8) Error!Loaded {
    return loadWith(gpa, url, .{});
}

/// `load` as `options` say.
pub fn loadWith(gpa: Allocator, url: []const u8, options: Options) Error!Loaded {
    return loadCounting(gpa, url, options, null);
}

fn loadCounting(gpa: Allocator, url: []const u8, options: Options, progress: ?*Progress) Error!Loaded {
    const bytes = try fetchCounting(gpa, url, options, progress);
    defer gpa.free(bytes);
    return decode(gpa, bytes);
}

/// Fetches from the network where there are no threads (a browser's
/// `fetch`): set by the backend. `start` begins fetching `r.url` (with
/// `r.options.headers`), following `r.progress`, and calls `r.fetched`
/// when done; false if it cannot.
pub const Fetcher = struct { start: *const fn (r: *Request) bool };
pub var fetcher: ?Fetcher = null;

/// Requests not yet freed: a cancelled one lives on until its worker is
/// done with it.
var alive: std.atomic.Value(usize) = .init(0);

/// For tests: waits until every request is freed, cancelled ones included
/// (their workers free them, perhaps after the test is over).
pub fn waitForRequests() void {
    for (0..2500) |_| {
        if (alive.load(.acquire) == 0) return;
        var t: std.Io.Threaded = .init_single_threaded;
        t.io().sleep(.fromMilliseconds(2), .awake) catch {};
    }
}

/// A load in progress: `start` it, then `poll` until it is done (or
/// `cancel` it). It loads on a thread of its own when there are threads.
pub const Request = struct {
    gpa: Allocator,
    url: []const u8,
    /// Its strings the request's own.
    options: Options = .{},
    /// Who frees it: the requester once done, the worker once cancelled
    /// (whichever comes second).
    state: std.atomic.Value(State) = .init(.loading),
    result: ?Loaded = null,
    err: ?Error = null,
    progress: Progress = .{},

    pub const State = enum(u8) { loading, done, cancelled };

    pub fn start(gpa: Allocator, url: []const u8) Allocator.Error!*Request {
        return startWith(gpa, url, .{});
    }

    /// `start` as `options` say.
    pub fn startWith(gpa: Allocator, url: []const u8, options: Options) Allocator.Error!*Request {
        const r = try gpa.create(Request);
        errdefer gpa.destroy(r);
        const own_url = try gpa.dupe(u8, url);
        errdefer gpa.free(own_url);
        const ua = if (options.user_agent) |u| try gpa.dupe(u8, u) else null;
        errdefer if (ua) |u| gpa.free(u);
        const cache = if (options.cache_path) |c| try gpa.dupe(u8, c) else null;
        errdefer if (cache) |c| gpa.free(c);
        const headers = try gpa.alloc([]const u8, options.headers.len);
        var copied: usize = 0;
        errdefer {
            for (headers[0..copied]) |h| gpa.free(h);
            gpa.free(headers);
        }
        for (headers, options.headers) |*h, o| {
            h.* = try gpa.dupe(u8, o);
            copied += 1;
        }
        r.* = .{ .gpa = gpa, .url = own_url, .options = .{ .user_agent = ua, .headers = headers, .cache_path = cache, .max_age_s = options.max_age_s } };
        _ = alive.fetchAdd(1, .monotonic);
        if (threaded) {
            if (std.Thread.spawn(.{}, run, .{r})) |t| {
                t.detach();
                return r;
            } else |_| {}
        }
        // No threads: the browser fetches it (`fetched` when it came), or
        // here and now.
        if (!threaded and isNetwork(own_url)) if (fetcher) |f| if (f.start(r)) return r;
        run(r);
        return r;
    }

    /// What the platform's fetch brought (`fetcher`): the body and its
    /// HTTP status (0: no answer). On the UI thread.
    pub fn fetched(r: *Request, body: []const u8, status: u16) void {
        if (status >= 200 and status < 300) {
            if (decode(r.gpa, body)) |l| {
                r.result = l;
            } else |err| r.err = err;
        } else r.err = if (status == 0) error.NetworkFailed else error.NotFound;
        r.progress.received.store(body.len, .monotonic);
        if (r.state.cmpxchgStrong(.loading, .done, .acq_rel, .acquire) != null) r.free();
    }

    fn run(r: *Request) void {
        if (loadCounting(r.gpa, r.url, r.options, &r.progress)) |l| {
            r.result = l;
        } else |err| r.err = err;
        // Its last touch, unless nobody wants it any more.
        if (r.state.cmpxchgStrong(.loading, .done, .acq_rel, .acquire) != null) r.free();
    }

    /// The image, or what went wrong, once done (null while loading). The
    /// image is the caller's from then on; call `cancel` after.
    pub fn poll(r: *Request) ?(Error!Loaded) {
        if (r.state.load(.acquire) != .done) return null;
        if (r.err) |e| return e;
        const l = r.result.?;
        r.result = null;
        return l;
    }

    /// Lets go of the request (what it loaded, unless taken, goes too).
    pub fn cancel(r: *Request) void {
        // Still loading: the worker frees it when done.
        if (r.state.cmpxchgStrong(.loading, .cancelled, .acq_rel, .acquire) == null) return;
        r.free();
    }

    fn free(r: *Request) void {
        if (r.result) |*l| l.deinit();
        r.gpa.free(r.url);
        if (r.options.user_agent) |u| r.gpa.free(u);
        if (r.options.cache_path) |c| r.gpa.free(c);
        for (r.options.headers) |h| r.gpa.free(h);
        r.gpa.free(r.options.headers);
        r.gpa.destroy(r);
        _ = alive.fetchSub(1, .release);
    }

    /// How far it has come, 0 to 1 (1 when done; 0 while the size is not
    /// known).
    pub fn fraction(r: *Request) f32 {
        if (r.state.load(.acquire) == .done) return 1;
        return r.progress.fraction();
    }
};

// ---- Shared by URL ----

/// An image loaded from a URL (with headers), shared by all that show it:
/// `acquire` it, `poll` it until it is there, `release` it. Once no one
/// shows it, it is kept a while (up to `keep_bytes` of such images, the
/// oldest let go first), so showing it again (a list's row scrolled back)
/// takes no load. On the UI thread only.
pub const Shared = struct {
    /// URL and headers.
    key: []u8,
    users: u32 = 0,
    request: ?*Request = null,
    loaded: ?Loaded = null,
    err: ?Error = null,
    /// When it was last let go (an order: the oldest goes first).
    released: u64 = 0,

    /// The image, or what went wrong, once there (null while loading).
    pub fn poll(e: *Shared) ?(Error!image.Image) {
        if (e.loaded) |l| return l.image;
        if (e.err) |err| return err;
        const r = e.request orelse return error.NotFound;
        const result = r.poll() orelse return null;
        r.cancel();
        e.request = null;
        if (result) |l| {
            e.loaded = l;
            return l.image;
        } else |err| {
            e.err = err;
            return err;
        }
    }

    /// How far it has loaded, 0 to 1.
    pub fn fraction(e: *Shared) f32 {
        if (e.loaded != null or e.err != null) return 1;
        const r = e.request orelse return 1;
        return r.fraction();
    }

    fn free(e: *Shared) void {
        if (e.request) |r| r.cancel();
        if (e.loaded) |*l| l.deinit();
        cache_gpa.free(e.key);
        cache_gpa.destroy(e);
    }

    fn bytes(e: *const Shared) usize {
        const l = e.loaded orelse return 0;
        return l.image.pixels.len * 4 + l.image.animation.len;
    }
};

/// The memory images no one shows may keep.
pub var keep_bytes: usize = 32 << 20;

/// Shared images live past whoever loaded them first: in memory of their
/// own.
const cache_gpa = std.heap.page_allocator;
threadlocal var shared: std.ArrayList(*Shared) = .empty;
threadlocal var released_count: u64 = 0;

/// The image at `url` (fetched with `options`' headers and user agent),
/// shared: one load for all who show it.
pub fn acquire(url: []const u8, options: Options) Allocator.Error!*Shared {
    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(cache_gpa);
    try key.appendSlice(cache_gpa, url);
    for (options.headers) |h| {
        try key.append(cache_gpa, '\n');
        try key.appendSlice(cache_gpa, h);
    }
    for (shared.items) |e| if (std.mem.eql(u8, e.key, key.items)) {
        // A failure is tried again by whoever comes after.
        if (e.users == 0 and e.err != null) {
            e.err = null;
            e.request = try Request.startWith(cache_gpa, url, options);
        }
        e.users += 1;
        return e;
    };
    const e = try cache_gpa.create(Shared);
    errdefer cache_gpa.destroy(e);
    e.* = .{ .key = try key.toOwnedSlice(cache_gpa), .users = 1 };
    errdefer cache_gpa.free(e.key);
    e.request = try Request.startWith(cache_gpa, url, options);
    try shared.append(cache_gpa, e);
    return e;
}

/// No longer shown by one of its users.
pub fn release(e: *Shared) void {
    e.users -= 1;
    if (e.users > 0) return;
    released_count += 1;
    e.released = released_count;
    // Not there (failed, or still loading): not worth keeping.
    if (e.loaded == null) {
        drop(e);
        return;
    }
    trim();
}

fn drop(e: *Shared) void {
    for (shared.items, 0..) |x, i| if (x == e) {
        _ = shared.swapRemove(i);
        break;
    };
    e.free();
}

/// Lets go of the oldest images no one shows, beyond `keep_bytes`.
fn trim() void {
    while (true) {
        var unused: usize = 0;
        var oldest: ?*Shared = null;
        for (shared.items) |e| if (e.users == 0) {
            unused += e.bytes();
            if (oldest == null or e.released < oldest.?.released) oldest = e;
        };
        if (unused <= keep_bytes) return;
        drop(oldest.?);
    }
}

/// Lets go of every image no one shows.
pub fn clearCache() void {
    var i: usize = 0;
    while (i < shared.items.len) {
        const e = shared.items[i];
        if (e.users == 0) {
            _ = shared.swapRemove(i);
            e.free();
        } else i += 1;
    }
    if (shared.items.len == 0) shared.clearAndFree(cache_gpa);
}

// ---- Tests ----

const testing = std.testing;

fn waitDone(r: *Request) Error!Loaded {
    for (0..2000) |_| {
        if (r.poll()) |res| return res;
        var t: std.Io.Threaded = .init_single_threaded;
        t.io().sleep(.fromMilliseconds(2), .awake) catch {};
    }
    return error.NotFound;
}

/// A 2 x 1 PNG (red, blue).
fn testPng(gpa: Allocator) ![]u8 {
    const px = [_]@import("graphics.zig").Rgba8{ .{ .r = 255, .g = 0, .b = 0, .a = 255 }, .{ .r = 0, .g = 0, .b = 255, .a = 255 } };
    return png.encode(gpa, 2, 1, &px);
}

test "images decoded: PNG, SVG; others refused" {
    const bytes = try testPng(testing.allocator);
    defer testing.allocator.free(bytes);
    var l = try decode(testing.allocator, bytes);
    defer l.deinit();
    try testing.expectEqual(@as(u32, 2), l.image.width);
    try testing.expectEqual(@as(u8, 255), l.image.pixels[1].b);
    var s = try decode(testing.allocator, "<svg width='8' height='4'><rect width='8' height='4'/></svg>");
    defer s.deinit();
    try testing.expectEqual(@as(u32, 8), s.image.width);
    try testing.expectEqual(@as(usize, 1), s.image.vector.?.shapes.len);
    try testing.expect(s.image.version != l.image.version);
    try testing.expectError(error.InvalidImage, decode(testing.allocator, "not an image"));
}

test "images loaded from files, in the background" {
    if (!has_files) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try testPng(testing.allocator);
    defer testing.allocator.free(bytes);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dot.png", .data = bytes });
    const path = try std.fmt.allocPrint(testing.allocator, "file://.zig-cache/tmp/{s}/dot.png", .{tmp.sub_path});
    defer testing.allocator.free(path);

    const r = try Request.start(testing.allocator, path);
    var l = try waitDone(r);
    r.cancel();
    defer l.deinit();
    try testing.expectEqual(@as(u32, 1), l.image.height);

    const missing = try Request.start(testing.allocator, "no/such/file.png");
    try testing.expectError(error.NotFound, waitDone(missing));
    missing.cancel();
    // Cancelled while loading: freed by the worker (later: not with the
    // testing allocator, which checks for leaks at the end of the test).
    const dropped = try Request.start(std.heap.page_allocator, path[7..]);
    dropped.cancel();
}

test "images loaded over http" {
    if (!threaded) return error.SkipZigTest;
    const bytes = try testPng(testing.allocator);
    defer testing.allocator.free(bytes);
    // A server on this machine, answering once with the PNG and once 404.
    var t: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer t.deinit();
    const io = t.io();
    const addr: std.Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    // It serves until told to stop; a last connection wakes it to see that
    // (even when a check below fails before the requests are all made).
    const Serve = struct {
        stop: std.atomic.Value(bool) = .init(false),
        /// The last request's User-Agent (read after its answer).
        agent: [128]u8 = undefined,
        agent_len: std.atomic.Value(usize) = .init(0),

        fn run(self: *@This(), s: *std.Io.net.Server, sio: std.Io, png_bytes: []const u8) void {
            while (true) {
                var stream = s.accept(sio) catch return;
                defer stream.close(sio);
                if (self.stop.load(.acquire)) return;
                var recv: [4096]u8 = undefined;
                var send: [4096]u8 = undefined;
                var reader = stream.reader(sio, &recv);
                var writer = stream.writer(sio, &send);
                var http: std.http.Server = .init(&reader.interface, &writer.interface);
                var req = http.receiveHead() catch continue;
                var headers = req.iterateHeaders();
                var token = false;
                while (headers.next()) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) {
                        const n = @min(h.value.len, self.agent.len);
                        @memcpy(self.agent[0..n], h.value[0..n]);
                        self.agent_len.store(n, .release);
                    }
                    if (std.ascii.eqlIgnoreCase(h.name, "x-token") and std.mem.eql(u8, h.value, "abc")) token = true;
                }
                // Only for whoever brings the token.
                if (std.mem.eql(u8, req.head.target, "/dot.png") or (token and std.mem.eql(u8, req.head.target, "/private.png"))) {
                    req.respond(png_bytes, .{ .keep_alive = false }) catch continue;
                } else req.respond("no", .{ .status = .not_found, .keep_alive = false }) catch continue;
            }
        }
    };
    var serve: Serve = .{};
    const thread = try std.Thread.spawn(.{}, Serve.run, .{ &serve, &server, io, bytes });
    defer {
        serve.stop.store(true, .release);
        const at: std.Io.net.IpAddress = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
        if (at.connect(io, .{ .mode = .stream })) |conn| {
            var c = conn;
            c.close(io);
        } else |_| {}
        thread.join();
    }

    var url_buf: [64]u8 = undefined;
    const r = try Request.start(testing.allocator, try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/dot.png", .{port}));
    var l = try waitDone(r);
    // All of it came, as much as the server said there was.
    try testing.expectEqual(bytes.len, r.progress.total.load(.monotonic));
    try testing.expectEqual(bytes.len, r.progress.received.load(.monotonic));
    try testing.expectEqual(@as(f32, 1), r.fraction());
    r.cancel();
    defer l.deinit();
    try testing.expectEqual(@as(u32, 2), l.image.width);

    // A header of one's own.
    const private = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/private.png", .{port});
    const refused = try Request.start(testing.allocator, private);
    try testing.expectError(error.NotFound, waitDone(refused));
    refused.cancel();
    const allowed = try Request.startWith(testing.allocator, private, .{ .headers = &.{"X-Token: abc"} });
    var pl = try waitDone(allowed);
    allowed.cancel();
    pl.deinit();
    const missing = try Request.start(testing.allocator, try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/nope.png", .{port}));
    try testing.expectError(error.NotFound, waitDone(missing));
    missing.cancel();

    // Said who asks; kept on disk, and read from there while fresh (the
    // server would say no to this address now).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/tiles/dot", .{tmp.sub_path});
    defer testing.allocator.free(cache);
    const got = try fetchWith(testing.allocator, try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/dot.png", .{port}), .{ .user_agent = "test-app (zigulee)", .cache_path = cache });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("test-app (zigulee)", serve.agent[0..serve.agent_len.load(.acquire)]);
    const kept = try fetchWith(testing.allocator, try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/nope.png", .{port}), .{ .cache_path = cache });
    defer testing.allocator.free(kept);
    try testing.expectEqualSlices(u8, bytes, kept);
    // Too old: asked again.
    try testing.expectError(error.NotFound, fetchWith(testing.allocator, try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/nope.png", .{port}), .{ .cache_path = cache, .max_age_s = -1 }));
}

test "images shared by URL: one load for all, kept a while once no one shows them" {
    if (!has_files) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try testPng(testing.allocator);
    defer testing.allocator.free(bytes);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dot.png", .data = bytes });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/dot.png", .{tmp.sub_path});
    defer testing.allocator.free(path);
    defer clearCache();

    const a = try acquire(path, .{});
    const b = try acquire(path, .{});
    try testing.expectEqual(a, b);
    // Another URL (or other headers): another image.
    const c = try acquire(path, .{ .headers = &.{"X-Token: abc"} });
    try testing.expect(c != a);
    release(c);
    const img = for (0..2000) |_| {
        if (a.poll()) |res| break try res;
        var t: std.Io.Threaded = .init_single_threaded;
        t.io().sleep(.fromMilliseconds(2), .awake) catch {};
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 2), img.width);
    try testing.expectEqual(@as(f32, 1), a.fraction());
    release(a);
    release(b);
    // Shown again: there at once.
    const again = try acquire(path, .{});
    try testing.expectEqual(a, again);
    try testing.expect(again.poll() != null);
    release(again);
    // Past what may be kept: let go.
    const keep = keep_bytes;
    defer keep_bytes = keep;
    keep_bytes = 0;
    release(try acquire(path, .{}));
    for (shared.items) |e| try testing.expect(e.users > 0);
}
