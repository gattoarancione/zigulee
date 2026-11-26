// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! A small D-Bus client: enough of the protocol for the accessibility bus
//! (AT-SPI). Connects to a bus over a Unix socket (EXTERNAL
//! authentication), sends method calls, replies and signals, and reads
//! messages as they come.
//!
//! Values are written and read one at a time in the order of their
//! signature (the caller knows it): see `Writer` and `Reader`. Only
//! little-endian messages are read (what every machine zigulee runs on
//! sends); others are dropped.
//!
//! Needs libc (the sockets).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = std.c;

const log = std.log.scoped(.zigulee_dbus);

pub const Error = error{ ConnectFailed, AuthFailed, Disconnected, BadMessage, Timeout, CallFailed } || Allocator.Error;

// ---- Marshalling ----

/// The alignment of a value of the type starting with `t`.
fn alignOf(t: u8) usize {
    return switch (t) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 'h', 's', 'o', 'a' => 4,
        else => 8, // x t d ( {
    };
}

/// Builds a message body (or header). Out of memory is remembered and
/// reported by `finish`, so values can be written without `try`.
pub const Writer = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    oom: bool = false,

    pub fn init(gpa: Allocator) Writer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(w: *Writer) void {
        w.buf.deinit(w.gpa);
    }

    /// The bytes written.
    pub fn finish(w: *Writer) Allocator.Error![]const u8 {
        if (w.oom) return error.OutOfMemory;
        return w.buf.items;
    }

    fn append(w: *Writer, bytes: []const u8) void {
        w.buf.appendSlice(w.gpa, bytes) catch {
            w.oom = true;
        };
    }

    fn pad(w: *Writer, n: usize) void {
        while (w.buf.items.len % n != 0 and !w.oom) w.append(&.{0});
    }

    fn int(w: *Writer, comptime T: type, v: T) void {
        w.pad(@sizeOf(T));
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        w.append(&b);
    }

    pub fn byte(w: *Writer, v: u8) void {
        w.append(&.{v});
    }
    pub fn boolean(w: *Writer, v: bool) void {
        w.int(u32, @intFromBool(v));
    }
    pub fn int16(w: *Writer, v: i16) void {
        w.int(i16, v);
    }
    pub fn int32(w: *Writer, v: i32) void {
        w.int(i32, v);
    }
    pub fn uint32(w: *Writer, v: u32) void {
        w.int(u32, v);
    }
    pub fn int64(w: *Writer, v: i64) void {
        w.int(i64, v);
    }
    pub fn double(w: *Writer, v: f64) void {
        w.int(u64, @bitCast(v));
    }
    /// A string (`s`), or an object path (`o`).
    pub fn string(w: *Writer, s: []const u8) void {
        w.uint32(@intCast(s.len));
        w.append(s);
        w.append(&.{0});
    }
    pub fn signature(w: *Writer, s: []const u8) void {
        w.byte(@intCast(s.len));
        w.append(s);
        w.append(&.{0});
    }
    /// A variant: its signature; the value follows.
    pub fn variant(w: *Writer, sig: []const u8) void {
        w.signature(sig);
    }
    /// A struct's (or dict entry's) start; its fields follow.
    pub fn structure(w: *Writer) void {
        w.pad(8);
    }

    pub const Array = struct { length_at: usize, start: usize };

    /// An array of elements of the type starting with `element`; write
    /// them, then `endArray`.
    pub fn beginArray(w: *Writer, element: u8) Array {
        w.uint32(0);
        const at = w.buf.items.len -| 4;
        w.pad(alignOf(element));
        return .{ .length_at = at, .start = w.buf.items.len };
    }
    pub fn endArray(w: *Writer, a: Array) void {
        if (w.oom) return;
        std.mem.writeInt(u32, w.buf.items[a.length_at..][0..4], @intCast(w.buf.items.len - a.start), .little);
    }

    /// An object reference, `(so)`: a bus name and an object path.
    pub fn ref(w: *Writer, name: []const u8, path: []const u8) void {
        w.structure();
        w.string(name);
        w.string(path);
    }
};

/// Reads a message body, value by value.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub const ReadError = error{BadMessage};

    fn pad(r: *Reader, n: usize) ReadError!void {
        r.pos = std.mem.alignForward(usize, r.pos, n);
        if (r.pos > r.data.len) return error.BadMessage;
    }

    fn take(r: *Reader, n: usize) ReadError![]const u8 {
        if (r.data.len - r.pos < n) return error.BadMessage;
        defer r.pos += n;
        return r.data[r.pos..][0..n];
    }

    fn int(r: *Reader, comptime T: type) ReadError!T {
        try r.pad(@sizeOf(T));
        return std.mem.readInt(T, (try r.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    pub fn byte(r: *Reader) ReadError!u8 {
        return (try r.take(1))[0];
    }
    pub fn boolean(r: *Reader) ReadError!bool {
        return try r.int(u32) != 0;
    }
    pub fn int16(r: *Reader) ReadError!i16 {
        return r.int(i16);
    }
    pub fn int32(r: *Reader) ReadError!i32 {
        return r.int(i32);
    }
    pub fn uint32(r: *Reader) ReadError!u32 {
        return r.int(u32);
    }
    pub fn int64(r: *Reader) ReadError!i64 {
        return r.int(i64);
    }
    pub fn double(r: *Reader) ReadError!f64 {
        return @bitCast(try r.int(u64));
    }
    /// A string (`s`) or object path (`o`).
    pub fn string(r: *Reader) ReadError![]const u8 {
        const n = try r.uint32();
        const s = try r.take(n);
        _ = try r.take(1); // its terminating 0
        return s;
    }
    pub fn signature(r: *Reader) ReadError![]const u8 {
        const n = try r.byte();
        const s = try r.take(n);
        _ = try r.take(1);
        return s;
    }
    pub fn structure(r: *Reader) ReadError!void {
        try r.pad(8);
    }
    /// An array of elements of the type starting with `element`: read them
    /// while `r.pos` is before the returned end.
    pub fn array(r: *Reader, element: u8) ReadError!usize {
        const n = try r.uint32();
        try r.pad(alignOf(element));
        if (r.data.len - r.pos < n) return error.BadMessage;
        return r.pos + n;
    }

    /// Skips the values of signature `sig`.
    pub fn skip(r: *Reader, sig: []const u8) ReadError!void {
        var i: usize = 0;
        while (i < sig.len) try r.skipOne(sig, &i);
    }

    fn skipOne(r: *Reader, sig: []const u8, i: *usize) ReadError!void {
        if (i.* >= sig.len) return error.BadMessage;
        const t = sig[i.*];
        i.* += 1;
        switch (t) {
            'y' => _ = try r.byte(),
            'n', 'q' => _ = try r.int(u16),
            'b', 'i', 'u', 'h' => _ = try r.int(u32),
            'x', 't', 'd' => _ = try r.int(u64),
            's', 'o' => _ = try r.string(),
            'g' => _ = try r.signature(),
            'v' => {
                const inner = try r.signature();
                var j: usize = 0;
                try r.skipOne(inner, &j);
                if (j != inner.len) return error.BadMessage;
            },
            'a' => {
                if (i.* >= sig.len) return error.BadMessage;
                const end = try r.array(sig[i.*]);
                r.pos = end;
                try skipType(sig, i);
            },
            '(', '{' => {
                try r.structure();
                const close: u8 = if (t == '(') ')' else '}';
                while (i.* < sig.len and sig[i.*] != close) try r.skipOne(sig, i);
                if (i.* >= sig.len) return error.BadMessage;
                i.* += 1;
            },
            else => return error.BadMessage,
        }
    }
};

/// Moves `i` past one complete type of `sig`.
fn skipType(sig: []const u8, i: *usize) error{BadMessage}!void {
    if (i.* >= sig.len) return error.BadMessage;
    const t = sig[i.*];
    i.* += 1;
    switch (t) {
        'a' => try skipType(sig, i),
        '(', '{' => {
            const close: u8 = if (t == '(') ')' else '}';
            while (i.* < sig.len and sig[i.*] != close) try skipType(sig, i);
            if (i.* >= sig.len) return error.BadMessage;
            i.* += 1;
        },
        else => {},
    }
}

// ---- Messages ----

pub const Type = enum(u8) { call = 1, reply = 2, err = 3, signal = 4, _ };

/// No reply wanted (a method call's flag).
pub const no_reply_expected: u8 = 1;

pub const Message = struct {
    type: Type,
    flags: u8 = 0,
    serial: u32 = 0,
    path: []const u8 = "",
    interface: []const u8 = "",
    member: []const u8 = "",
    error_name: []const u8 = "",
    reply_serial: u32 = 0,
    destination: []const u8 = "",
    sender: []const u8 = "",
    signature: []const u8 = "",
    body: []const u8 = "",

    pub fn reader(m: *const Message) Reader {
        return .{ .data = m.body };
    }

    /// The bytes of the message, with serial `serial`.
    pub fn encode(m: *const Message, gpa: Allocator, serial: u32) Allocator.Error![]u8 {
        var w: Writer = .init(gpa);
        errdefer w.deinit();
        w.byte('l');
        w.byte(@intFromEnum(m.type));
        w.byte(m.flags);
        w.byte(1);
        w.uint32(@intCast(m.body.len));
        w.uint32(serial);
        const fields = w.beginArray('(');
        const strings = [_]struct { u8, []const u8, []const u8 }{
            .{ 1, "o", m.path },
            .{ 2, "s", m.interface },
            .{ 3, "s", m.member },
            .{ 4, "s", m.error_name },
            .{ 6, "s", m.destination },
            .{ 7, "s", m.sender },
        };
        for (strings) |f| if (f[2].len > 0) {
            w.structure();
            w.byte(f[0]);
            w.variant(f[1]);
            w.string(f[2]);
        };
        if (m.reply_serial != 0) {
            w.structure();
            w.byte(5);
            w.variant("u");
            w.uint32(m.reply_serial);
        }
        if (m.signature.len > 0) {
            w.structure();
            w.byte(8);
            w.variant("g");
            w.signature(m.signature);
        }
        w.endArray(fields);
        w.pad(8);
        w.append(m.body);
        _ = try w.finish();
        return w.buf.toOwnedSlice(gpa);
    }

    /// How long the message starting with `data` is, once its fixed header
    /// is there (null: not yet).
    fn length(data: []const u8) error{BadMessage}!?usize {
        if (data.len < 16) return null;
        if (data[0] != 'l' and data[0] != 'B') return error.BadMessage;
        const endian: std.builtin.Endian = if (data[0] == 'l') .little else .big;
        const body = std.mem.readInt(u32, data[4..8], endian);
        const fields = std.mem.readInt(u32, data[12..16], endian);
        if (body > 1 << 27 or fields > 1 << 26) return error.BadMessage;
        return std.mem.alignForward(usize, 16 + fields, 8) + body;
    }

    /// Parses one whole message (its slices point into `data`).
    pub fn parse(data: []const u8) error{ BadMessage, BigEndian }!Message {
        if (data.len < 16) return error.BadMessage;
        if (data[0] == 'B') return error.BigEndian;
        var r: Reader = .{ .data = data, .pos = 1 };
        var m: Message = .{ .type = @enumFromInt(try r.byte()) };
        m.flags = try r.byte();
        _ = try r.byte(); // version
        const body_len = try r.uint32();
        m.serial = try r.uint32();
        const end = try r.array('(');
        while (r.pos < end) {
            try r.structure();
            const code = try r.byte();
            const sig = try r.signature();
            switch (code) {
                1, 2, 3, 4, 6, 7 => {
                    if (sig.len != 1 or (sig[0] != 's' and sig[0] != 'o')) return error.BadMessage;
                    const s = try r.string();
                    switch (code) {
                        1 => m.path = s,
                        2 => m.interface = s,
                        3 => m.member = s,
                        4 => m.error_name = s,
                        6 => m.destination = s,
                        else => m.sender = s,
                    }
                },
                5 => {
                    if (!std.mem.eql(u8, sig, "u")) return error.BadMessage;
                    m.reply_serial = try r.uint32();
                },
                8 => {
                    if (!std.mem.eql(u8, sig, "g")) return error.BadMessage;
                    m.signature = try r.signature();
                },
                else => try r.skip(sig),
            }
        }
        try r.pad(8);
        m.body = try r.take(body_len);
        return m;
    }
};

// ---- Connections ----

/// A received message, with the bytes it points into.
pub const Received = struct {
    bytes: []u8,
    message: Message,

    pub fn deinit(self: Received, gpa: Allocator) void {
        gpa.free(self.bytes);
    }
};

pub const Connection = struct {
    gpa: Allocator,
    fd: c.fd_t,
    serial: u32 = 0,
    /// Given by the bus.
    unique_name: []const u8 = "",
    /// Bytes received and not yet parsed.
    in: std.ArrayList(u8) = .empty,
    /// Messages received while waiting for a reply.
    pending: std.ArrayList(Received) = .empty,

    /// Connects to the bus at `address` (a D-Bus address: `unix:path=...`
    /// or `unix:abstract=...`, alternatives separated by `;`).
    pub fn open(gpa: Allocator, address: []const u8) Error!*Connection {
        var alternatives = std.mem.tokenizeScalar(u8, address, ';');
        const fd = while (alternatives.next()) |a| {
            if (connectTo(a)) |fd| break fd;
        } else return error.ConnectFailed;
        errdefer _ = c.close(fd);
        try authenticate(fd);
        const self = try gpa.create(Connection);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .fd = fd };
        errdefer self.in.deinit(gpa);
        var hello = try self.call(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "Hello" }, "", "");
        defer hello.deinit(gpa);
        var r = hello.message.reader();
        self.unique_name = try gpa.dupe(u8, r.string() catch return error.BadMessage);
        return self;
    }

    pub fn close(self: *Connection) void {
        _ = c.close(self.fd);
        for (self.pending.items) |p| p.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.in.deinit(self.gpa);
        self.gpa.free(self.unique_name);
        self.gpa.destroy(self);
    }

    pub const Target = struct {
        destination: []const u8,
        path: []const u8,
        interface: []const u8,
        member: []const u8,
    };

    /// Sends a message (its serial is set here); returns the serial.
    pub fn send(self: *Connection, m: Message) Error!u32 {
        self.serial +%= 1;
        if (self.serial == 0) self.serial = 1;
        const bytes = try m.encode(self.gpa, self.serial);
        defer self.gpa.free(bytes);
        try writeAll(self.fd, bytes);
        return self.serial;
    }

    /// Calls a method and waits for its reply (at most 5 s); other
    /// messages received meanwhile are kept for `next`. The reply may be
    /// an error (`message.type == .err`).
    pub fn call(self: *Connection, target: Target, sig: []const u8, body: []const u8) Error!Received {
        const serial = try self.send(.{ .type = .call, .destination = target.destination, .path = target.path, .interface = target.interface, .member = target.member, .signature = sig, .body = body });
        var waited: u32 = 0;
        while (true) {
            while (try self.parseOne()) |r| {
                if ((r.message.type == .reply or r.message.type == .err) and r.message.reply_serial == serial) return r;
                self.pending.append(self.gpa, r) catch |err| {
                    r.deinit(self.gpa);
                    return err;
                };
            }
            if (waited >= 5000) return error.Timeout;
            if (try self.fill(100)) {} else waited += 100;
        }
    }

    /// Like `call`, but an error reply is `error.CallFailed`.
    pub fn callOk(self: *Connection, target: Target, sig: []const u8, body: []const u8) Error!Received {
        const r = try self.call(target, sig, body);
        if (r.message.type == .err) {
            log.info("{s}.{s} failed: {s}", .{ target.interface, target.member, r.message.error_name });
            r.deinit(self.gpa);
            return error.CallFailed;
        }
        return r;
    }

    /// The next message received, if any, waiting at most `timeout_ms`
    /// for one (0: not at all).
    pub fn next(self: *Connection, timeout_ms: u32) Error!?Received {
        if (self.pending.items.len > 0) return self.pending.orderedRemove(0);
        if (try self.parseOne()) |r| return r;
        // Read what there is, then (once) wait.
        while (try self.fill(0)) if (try self.parseOne()) |r| return r;
        if (timeout_ms > 0 and try self.fill(timeout_ms)) {
            while (try self.fill(0)) {}
            return self.parseOne();
        }
        return null;
    }

    /// A message from the bytes received, if one is complete.
    fn parseOne(self: *Connection) Error!?Received {
        while (true) {
            const len = (Message.length(self.in.items) catch return error.BadMessage) orelse return null;
            if (self.in.items.len < len) return null;
            const bytes = try self.gpa.dupe(u8, self.in.items[0..len]);
            self.in.replaceRangeAssumeCapacity(0, len, &.{});
            const m = Message.parse(bytes) catch |err| {
                self.gpa.free(bytes);
                if (err == error.BigEndian) {
                    log.info("big-endian message dropped", .{});
                    continue;
                }
                return error.BadMessage;
            };
            return .{ .bytes = bytes, .message = m };
        }
    }

    /// Reads what has arrived, waiting at most `timeout_ms` for it;
    /// whether anything did.
    fn fill(self: *Connection, timeout_ms: u32) Error!bool {
        var p = [1]c.pollfd{.{ .fd = self.fd, .events = c.POLL.IN, .revents = 0 }};
        const n = c.poll(&p, 1, @intCast(timeout_ms));
        if (n <= 0) return false;
        var buf: [4096]u8 = undefined;
        const got = c.recv(self.fd, &buf, buf.len, 0);
        if (got <= 0) {
            if (got < 0 and std.posix.errno(got) == .INTR) return false;
            return error.Disconnected;
        }
        try self.in.appendSlice(self.gpa, buf[0..@intCast(got)]);
        return true;
    }

    /// Replies to method call `to` (unless it wants no reply).
    pub fn reply(self: *Connection, to: *const Message, sig: []const u8, body: []const u8) Error!void {
        if (to.flags & no_reply_expected != 0) return;
        _ = try self.send(.{ .type = .reply, .destination = to.sender, .reply_serial = to.serial, .signature = sig, .body = body });
    }

    /// Replies to method call `to` with an error.
    pub fn replyError(self: *Connection, to: *const Message, name: []const u8, text: []const u8) Error!void {
        if (to.flags & no_reply_expected != 0) return;
        var w: Writer = .init(self.gpa);
        defer w.deinit();
        w.string(text);
        _ = try self.send(.{ .type = .err, .destination = to.sender, .reply_serial = to.serial, .error_name = name, .signature = "s", .body = try w.finish() });
    }
};

fn writeAll(fd: c.fd_t, bytes: []const u8) Error!void {
    // No SIGPIPE if the bus is gone: an error instead.
    const flags: u32 = if (builtin.os.tag == .linux) c.MSG.NOSIGNAL else 0;
    var done: usize = 0;
    while (done < bytes.len) {
        const n = c.send(fd, bytes[done..].ptr, bytes.len - done, flags);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return error.Disconnected;
        }
        done += @intCast(n);
    }
}

/// A socket connected to one address (`unix:path=...` or
/// `unix:abstract=...`), or null.
fn connectTo(address: []const u8) ?c.fd_t {
    const params = std.mem.cutPrefix(u8, address, "unix:") orelse return null;
    var addr: c.sockaddr.un = .{ .path = @splat(0) };
    var len: usize = 0;
    var abstract = false;
    var it = std.mem.tokenizeScalar(u8, params, ',');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const key = kv[0..eq];
        if (!std.mem.eql(u8, key, "path") and !std.mem.eql(u8, key, "abstract")) continue;
        abstract = std.mem.eql(u8, key, "abstract");
        if (abstract and builtin.os.tag != .linux) return null;
        // The value, unescaped (%XX), after a 0 for an abstract name.
        len = @intFromBool(abstract);
        var i: usize = eq + 1;
        while (i < kv.len) : (len += 1) {
            if (len >= addr.path.len - 1) return null;
            if (kv[i] == '%' and i + 2 < kv.len) {
                addr.path[len] = std.fmt.parseInt(u8, kv[i + 1 ..][0..2], 16) catch return null;
                i += 3;
            } else {
                addr.path[len] = kv[i];
                i += 1;
            }
        }
    }
    if (len == 0) return null;
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return null;
    if (builtin.os.tag.isDarwin()) {
        const one: c_int = 1;
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
    }
    const size: c.socklen_t = @intCast(@offsetOf(c.sockaddr.un, "path") + len + @intFromBool(!abstract));
    if (c.connect(fd, @ptrCast(&addr), size) != 0) {
        _ = c.close(fd);
        return null;
    }
    return fd;
}

/// EXTERNAL authentication: the bus knows the user from the socket.
fn authenticate(fd: c.fd_t) Error!void {
    var uid_buf: [16]u8 = undefined;
    const uid = std.fmt.bufPrint(&uid_buf, "{d}", .{c.getuid()}) catch unreachable;
    var line: [64]u8 = undefined;
    const auth = std.fmt.bufPrint(&line, "\x00AUTH EXTERNAL {x}\r\n", .{uid}) catch unreachable;
    try writeAll(fd, auth);
    var answer: [256]u8 = undefined;
    var got: usize = 0;
    while (std.mem.indexOf(u8, answer[0..got], "\r\n") == null) {
        if (got == answer.len) return error.AuthFailed;
        var p = [1]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&p, 1, 5000) <= 0) return error.Timeout;
        const n = c.recv(fd, answer[got..].ptr, answer.len - got, 0);
        if (n <= 0) return error.AuthFailed;
        got += @intCast(n);
    }
    if (!std.mem.startsWith(u8, answer[0..got], "OK ")) return error.AuthFailed;
    try writeAll(fd, "BEGIN\r\n");
}

// ---- Tests ----

const testing = std.testing;

test "values written and read back, with their alignment" {
    var w: Writer = .init(testing.allocator);
    defer w.deinit();
    w.byte(7);
    w.int32(-5);
    w.string("hi");
    const a = w.beginArray('(');
    for (0..2) |i| {
        w.structure();
        w.string("name");
        w.uint32(@intCast(i));
    }
    w.endArray(a);
    w.variant("d");
    w.double(1.5);
    w.boolean(true);
    const bytes = try w.finish();
    try testing.expectEqual(@as(usize, 0), std.mem.indexOfScalar(u8, bytes, 7).?);
    try testing.expectEqual(@as(i32, -5), std.mem.readInt(i32, bytes[4..8], .little));

    var r: Reader = .{ .data = bytes };
    try testing.expectEqual(@as(u8, 7), try r.byte());
    try testing.expectEqual(@as(i32, -5), try r.int32());
    try testing.expectEqualStrings("hi", try r.string());
    const end = try r.array('(');
    var n: u32 = 0;
    while (r.pos < end) : (n += 1) {
        try r.structure();
        try testing.expectEqualStrings("name", try r.string());
        try testing.expectEqual(n, try r.uint32());
    }
    try testing.expectEqual(@as(u32, 2), n);
    try testing.expectEqualStrings("d", try r.signature());
    try testing.expectEqual(@as(f64, 1.5), try r.double());
    try testing.expect(try r.boolean());
    try testing.expectEqual(bytes.len, r.pos);

    // The same, skipped by signature.
    var s: Reader = .{ .data = bytes };
    try s.skip("yisa(su)vb");
    try testing.expectEqual(bytes.len, s.pos);
}

test "a message encoded and parsed" {
    var w: Writer = .init(testing.allocator);
    defer w.deinit();
    w.string("hello");
    const m: Message = .{ .type = .call, .path = "/a/b", .interface = "x.y", .member = "Do", .destination = "x.y", .signature = "s", .body = try w.finish() };
    const bytes = try m.encode(testing.allocator, 42);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(bytes.len, (try Message.length(bytes)).?);
    const p = try Message.parse(bytes);
    try testing.expectEqual(Type.call, p.type);
    try testing.expectEqual(@as(u32, 42), p.serial);
    try testing.expectEqualStrings("/a/b", p.path);
    try testing.expectEqualStrings("Do", p.member);
    try testing.expectEqualStrings("s", p.signature);
    var r = p.reader();
    try testing.expectEqualStrings("hello", try r.string());
    try testing.expectError(error.BadMessage, Message.parse(bytes[0 .. bytes.len - 1]));
}

/// The session bus's address (tests: run them in `dbus-run-session`), or
/// null.
pub fn sessionBusAddress() ?[]const u8 {
    return std.mem.span(c.getenv("DBUS_SESSION_BUS_ADDRESS") orelse return null);
}

test "a call to the bus" {
    const address = sessionBusAddress() orelse {
        log.info("no session bus (DBUS_SESSION_BUS_ADDRESS): skipped", .{});
        return error.SkipZigTest;
    };
    const conn = try Connection.open(testing.allocator, address);
    defer conn.close();
    try testing.expect(std.mem.startsWith(u8, conn.unique_name, ":"));
    // Our own name is on the bus.
    var w: Writer = .init(testing.allocator);
    defer w.deinit();
    w.string(conn.unique_name);
    const r = try conn.callOk(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "NameHasOwner" }, "s", try w.finish());
    defer r.deinit(testing.allocator);
    var body = r.message.reader();
    try testing.expect(try body.boolean());
}
