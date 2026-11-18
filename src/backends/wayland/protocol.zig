// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! A small Wayland client: the wire protocol (messages to and from
//! objects, file descriptors passed alongside), over the compositor's
//! socket (`$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`). The interfaces themselves
//! (which opcode means what) are in wayland.zig, which uses them.
//!
//! Requests are buffered until `flush`. Linux only (libc).

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = std.c;

const log = std.log.scoped(.zigulee_wayland);

pub const Error = error{ NoDisplay, ConnectFailed, Disconnected, ProtocolError, Timeout } || Allocator.Error;

const Iovec = extern struct { base: ?*anyopaque, len: usize };
const MsgHdr = extern struct {
    name: ?*anyopaque = null,
    namelen: u32 = 0,
    iov: [*]Iovec,
    iovlen: usize,
    control: ?*anyopaque,
    controllen: usize,
    flags: c_int = 0,
};
extern "c" fn sendmsg(fd: c.fd_t, msg: *const MsgHdr, flags: c_int) isize;
extern "c" fn recvmsg(fd: c.fd_t, msg: *MsgHdr, flags: c_int) isize;

/// struct cmsghdr: length, level, type; then the data, aligned.
const cmsg_header = std.mem.alignForward(usize, @sizeOf(usize) + 8, @sizeOf(usize));
const sol_socket = 1;
const scm_rights = 1;
const msg_nosignal = 0x4000;
const msg_cmsg_cloexec = 0x40000000;

/// Fixed-point numbers (24.8).
pub fn fixedToFloat(v: i32) f32 {
    return @as(f32, @floatFromInt(v)) / 256;
}

/// An event: the object it is from, its opcode and its arguments.
pub const Message = struct {
    sender: u32,
    opcode: u16,
    args: []const u8,
    pos: usize = 0,

    pub fn uint(m: *Message) u32 {
        if (m.args.len - m.pos < 4) return 0;
        defer m.pos += 4;
        return std.mem.readInt(u32, m.args[m.pos..][0..4], .little);
    }
    pub fn int(m: *Message) i32 {
        return @bitCast(m.uint());
    }
    pub fn fixed(m: *Message) f32 {
        return fixedToFloat(m.int());
    }
    /// A string (without its terminating 0); "" for null.
    pub fn string(m: *Message) []const u8 {
        const bytes = m.array();
        return if (bytes.len > 0) bytes[0 .. bytes.len - 1] else "";
    }
    pub fn array(m: *Message) []const u8 {
        const len = m.uint();
        if (m.args.len - m.pos < len) return "";
        defer m.pos += std.mem.alignForward(usize, len, 4);
        return m.args[m.pos..][0..len];
    }
};

pub const Conn = struct {
    gpa: Allocator,
    fd: c.fd_t,
    out: std.ArrayList(u8) = .empty,
    out_fds: std.ArrayList(c.fd_t) = .empty,
    in: std.ArrayList(u8) = .empty,
    /// File descriptors received, for the messages that carry them (in
    /// order).
    in_fds: std.ArrayList(c.fd_t) = .empty,
    /// The message being returned by `next` (its bytes are dropped on the
    /// next call).
    consumed: usize = 0,
    next_id: u32 = 2, // 1: the display

    /// Connects to the compositor (`WAYLAND_DISPLAY`, default "wayland-0",
    /// in `XDG_RUNTIME_DIR`; or an absolute path).
    pub fn open(gpa: Allocator) Error!*Conn {
        const name = if (c.getenv("WAYLAND_DISPLAY")) |d| std.mem.span(d) else "wayland-0";
        var path_buf: [256]u8 = undefined;
        const path = if (std.mem.startsWith(u8, name, "/"))
            name
        else
            std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ std.mem.span(c.getenv("XDG_RUNTIME_DIR") orelse return error.NoDisplay), name }) catch return error.NoDisplay;
        var addr: c.sockaddr.un = .{ .path = @splat(0) };
        if (path.len >= addr.path.len) return error.NoDisplay;
        @memcpy(addr.path[0..path.len], path);
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
        if (fd < 0) return error.ConnectFailed;
        errdefer _ = c.close(fd);
        if (c.connect(fd, @ptrCast(&addr), @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + 1)) != 0) return error.ConnectFailed;
        const self = try gpa.create(Conn);
        self.* = .{ .gpa = gpa, .fd = fd };
        return self;
    }

    pub fn close(self: *Conn) void {
        self.flush() catch {};
        _ = c.close(self.fd);
        for (self.in_fds.items) |fd| _ = c.close(fd);
        for (self.out_fds.items) |fd| _ = c.close(fd);
        self.out.deinit(self.gpa);
        self.out_fds.deinit(self.gpa);
        self.in.deinit(self.gpa);
        self.in_fds.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn newId(self: *Conn) u32 {
        defer self.next_id += 1;
        return self.next_id;
    }

    // ---- Requests ----

    /// An argument of a request.
    pub const Arg = union(enum) {
        uint: u32,
        int: i32,
        /// An object, or a new id (0: null).
        object: u32,
        string: ?[]const u8,
        array: []const u8,
        /// Sent, then closed here.
        fd: c.fd_t,
    };

    /// Queues a request to object `id`.
    pub fn request(self: *Conn, id: u32, opcode: u16, args: []const Arg) Error!void {
        const start = self.out.items.len;
        errdefer self.out.shrinkRetainingCapacity(start);
        try self.put(id);
        try self.put(0); // size and opcode, below
        for (args) |a| switch (a) {
            .uint => |v| try self.put(v),
            .int => |v| try self.put(@bitCast(v)),
            .object => |v| try self.put(v),
            .string => |s| if (s) |text| try self.putArray(text, true) else try self.put(0),
            .array => |bytes| try self.putArray(bytes, false),
            .fd => |fd| try self.out_fds.append(self.gpa, fd),
        };
        const size: u32 = @intCast(self.out.items.len - start);
        std.mem.writeInt(u32, self.out.items[start + 4 ..][0..4], size << 16 | opcode, .little);
        if (self.out.items.len > 1 << 15 or self.out_fds.items.len > 16) try self.flush();
    }

    fn put(self: *Conn, v: u32) Allocator.Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.out.appendSlice(self.gpa, &b);
    }

    fn putArray(self: *Conn, bytes: []const u8, zero: bool) Allocator.Error!void {
        const len = bytes.len + @intFromBool(zero);
        try self.put(@intCast(len));
        try self.out.appendSlice(self.gpa, bytes);
        try self.out.appendNTimes(self.gpa, 0, std.mem.alignForward(usize, len, 4) - bytes.len);
    }

    /// Sends the queued requests (and file descriptors).
    pub fn flush(self: *Conn) Error!void {
        var sent: usize = 0;
        while (sent < self.out.items.len) {
            var iov = [1]Iovec{.{ .base = self.out.items[sent..].ptr, .len = self.out.items.len - sent }};
            var control: [cmsg_header + 4 * 28]u8 align(@alignOf(usize)) = undefined;
            var msg: MsgHdr = .{ .iov = &iov, .iovlen = 1, .control = null, .controllen = 0 };
            const fds = self.out_fds.items[0..@min(self.out_fds.items.len, 28)];
            if (fds.len > 0) {
                const len = cmsg_header + 4 * fds.len;
                std.mem.writeInt(usize, control[0..@sizeOf(usize)], len, .little);
                std.mem.writeInt(i32, control[@sizeOf(usize)..][0..4], sol_socket, .little);
                std.mem.writeInt(i32, control[@sizeOf(usize) + 4 ..][0..4], scm_rights, .little);
                for (fds, 0..) |fd, i| std.mem.writeInt(i32, control[cmsg_header + 4 * i ..][0..4], fd, .little);
                msg.control = &control;
                msg.controllen = std.mem.alignForward(usize, len, @sizeOf(usize));
            }
            const n = sendmsg(self.fd, &msg, msg_nosignal);
            if (n < 0) {
                if (std.posix.errno(n) == .INTR) continue;
                if (std.posix.errno(n) == .AGAIN) {
                    var p = [1]c.pollfd{.{ .fd = self.fd, .events = c.POLL.OUT, .revents = 0 }};
                    _ = c.poll(&p, 1, 1000);
                    continue;
                }
                return error.Disconnected;
            }
            // The descriptors went with these bytes: ours can be closed.
            for (fds) |fd| _ = c.close(fd);
            self.out_fds.replaceRangeAssumeCapacity(0, fds.len, &.{});
            sent += @intCast(n);
        }
        self.out.clearRetainingCapacity();
    }

    // ---- Events ----

    /// The next event, waiting at most `timeout_ms` for one (0: not at
    /// all; null: forever). Its arguments are valid until the next call.
    pub fn next(self: *Conn, timeout_ms: ?u32) Error!?Message {
        if (self.consumed > 0) {
            self.in.replaceRangeAssumeCapacity(0, self.consumed, &.{});
            self.consumed = 0;
        }
        var waited = false;
        while (true) {
            if (self.in.items.len >= 8) {
                const word = std.mem.readInt(u32, self.in.items[4..8], .little);
                const size: usize = word >> 16;
                if (size < 8) return error.ProtocolError;
                if (self.in.items.len >= size) {
                    self.consumed = size;
                    return .{ .sender = std.mem.readInt(u32, self.in.items[0..4], .little), .opcode = @truncate(word), .args = self.in.items[8..size] };
                }
            }
            if (waited) return null;
            try self.flush();
            if (!try self.fill(timeout_ms)) {
                if (timeout_ms != null and timeout_ms.? == 0) return null;
                waited = true;
            }
        }
    }

    /// Whether a whole message has been received already.
    pub fn pending(self: *const Conn) bool {
        if (self.in.items.len - self.consumed < 8) return false;
        const rest = self.in.items[self.consumed..];
        return rest.len >= std.mem.readInt(u32, rest[4..8], .little) >> 16;
    }

    /// The next file descriptor received (for an event that carries one),
    /// or -1.
    pub fn takeFd(self: *Conn) c.fd_t {
        if (self.in_fds.items.len == 0) return -1;
        return self.in_fds.orderedRemove(0);
    }

    /// Reads what has arrived (waiting at most `timeout_ms`); whether
    /// anything did.
    fn fill(self: *Conn, timeout_ms: ?u32) Error!bool {
        var p = [1]c.pollfd{.{ .fd = self.fd, .events = c.POLL.IN, .revents = 0 }};
        const ms: c_int = if (timeout_ms) |t| @intCast(@min(t, std.math.maxInt(i32))) else -1;
        if (c.poll(&p, 1, ms) <= 0) return false;
        var buf: [16384]u8 = undefined;
        var iov = [1]Iovec{.{ .base = &buf, .len = buf.len }};
        var control: [cmsg_header + 4 * 28]u8 align(@alignOf(usize)) = undefined;
        var msg: MsgHdr = .{ .iov = &iov, .iovlen = 1, .control = &control, .controllen = control.len };
        const n = recvmsg(self.fd, &msg, msg_cmsg_cloexec);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) return false;
            return error.Disconnected;
        }
        // File descriptors (SCM_RIGHTS messages).
        var at: usize = 0;
        while (at + cmsg_header <= msg.controllen) {
            const len = std.mem.readInt(usize, control[at..][0..@sizeOf(usize)], .little);
            if (len < cmsg_header or at + len > msg.controllen) break;
            const level = std.mem.readInt(i32, control[at + @sizeOf(usize) ..][0..4], .little);
            const kind = std.mem.readInt(i32, control[at + @sizeOf(usize) + 4 ..][0..4], .little);
            if (level == sol_socket and kind == scm_rights) {
                var i = at + cmsg_header;
                while (i + 4 <= at + len) : (i += 4) try self.in_fds.append(self.gpa, std.mem.readInt(i32, control[i..][0..4], .little));
            }
            at += std.mem.alignForward(usize, len, @sizeOf(usize));
        }
        try self.in.appendSlice(self.gpa, buf[0..@intCast(n)]);
        return true;
    }
};

test "messages written and read back" {
    var conn: Conn = .{ .gpa = std.testing.allocator, .fd = -1 };
    defer conn.out.deinit(std.testing.allocator);
    defer conn.out_fds.deinit(std.testing.allocator);
    try conn.request(5, 2, &.{ .{ .uint = 7 }, .{ .string = "hello" }, .{ .int = -3 }, .{ .array = &.{ 1, 2, 3 } } });
    const bytes = conn.out.items;
    try std.testing.expectEqual(@as(usize, 8 + 4 + 4 + 8 + 4 + 4 + 4), bytes.len);
    try std.testing.expectEqual(@as(u32, (36 << 16) | 2), std.mem.readInt(u32, bytes[4..8], .little));
    var m: Message = .{ .sender = 5, .opcode = 2, .args = bytes[8..] };
    try std.testing.expectEqual(@as(u32, 7), m.uint());
    try std.testing.expectEqualStrings("hello", m.string());
    try std.testing.expectEqual(@as(i32, -3), m.int());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, m.array());
    try std.testing.expectEqual(@as(f32, 1.5), fixedToFloat(384));
}
