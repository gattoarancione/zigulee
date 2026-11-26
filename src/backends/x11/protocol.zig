// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! A small X11 client: enough of the core protocol for a zigulee window.
//! Connects to the display in `DISPLAY` over its Unix socket (with the
//! MIT-MAGIC-COOKIE-1 from the Xauthority file, if there is one), sends
//! requests, waits for replies and reads events.
//!
//! Requests are buffered until `flush` (or a round trip). Everything is
//! little-endian (we say so in the setup: the server converts).
//!
//! Needs libc (the socket, the Xauthority file).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = std.c;

const log = std.log.scoped(.zigulee_x11);

pub const Error = error{ NoDisplay, ConnectFailed, SetupFailed, NoVisual, Disconnected, RequestFailed, Timeout } || Allocator.Error;

// Request opcodes.
pub const op = struct {
    pub const create_window = 1;
    pub const change_window_attributes = 2;
    pub const destroy_window = 4;
    pub const map_window = 8;
    pub const configure_window = 12;
    pub const intern_atom = 16;
    pub const change_property = 18;
    pub const delete_property = 19;
    pub const get_property = 20;
    pub const set_selection_owner = 22;
    pub const convert_selection = 24;
    pub const send_event = 25;
    pub const translate_coordinates = 40;
    pub const set_input_focus = 42;
    pub const open_font = 45;
    pub const create_pixmap = 53;
    pub const free_pixmap = 54;
    pub const create_gc = 55;
    pub const free_gc = 60;
    pub const put_image = 72;
    pub const get_image = 73;
    pub const create_cursor = 93;
    pub const create_glyph_cursor = 94;
    pub const get_keyboard_mapping = 101;
};

// Event codes.
pub const ev = struct {
    pub const key_press = 2;
    pub const key_release = 3;
    pub const button_press = 4;
    pub const button_release = 5;
    pub const motion_notify = 6;
    pub const enter_notify = 7;
    pub const leave_notify = 8;
    pub const focus_in = 9;
    pub const focus_out = 10;
    pub const expose = 12;
    pub const map_notify = 19;
    pub const configure_notify = 22;
    pub const property_notify = 28;
    pub const selection_clear = 29;
    pub const selection_request = 30;
    pub const selection_notify = 31;
    pub const client_message = 33;
    pub const mapping_notify = 34;
};

// Predefined atoms.
pub const atom = struct {
    pub const primary = 1;
    pub const atom_ = 4;
    pub const cardinal = 6;
    pub const resource_manager = 23;
    pub const string = 31;
    pub const wm_name = 39;
    pub const wm_normal_hints = 40;
    pub const wm_size_hints = 41;
    pub const wm_class = 67;
};

pub const Event = [32]u8;

/// A reply's bytes (32, and more for some).
pub const Reply = struct {
    bytes: []u8,

    pub fn deinit(r: Reply, gpa: Allocator) void {
        gpa.free(r.bytes);
    }
    pub fn u8At(r: Reply, at: usize) u8 {
        return r.bytes[at];
    }
    pub fn u16At(r: Reply, at: usize) u16 {
        return std.mem.readInt(u16, r.bytes[at..][0..2], .little);
    }
    pub fn u32At(r: Reply, at: usize) u32 {
        return std.mem.readInt(u32, r.bytes[at..][0..4], .little);
    }
    /// What follows the first 32 bytes.
    pub fn data(r: Reply) []const u8 {
        return r.bytes[32..];
    }
};

pub fn u16Of(e: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, e[at..][0..2], .little);
}
pub fn i16Of(e: []const u8, at: usize) i16 {
    return @bitCast(u16Of(e, at));
}
pub fn u32Of(e: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, e[at..][0..4], .little);
}

pub const Conn = struct {
    gpa: Allocator,
    fd: c.fd_t,
    /// Requests not yet sent.
    out: std.ArrayList(u8) = .empty,
    /// Bytes received and not yet parsed.
    in: std.ArrayList(u8) = .empty,
    /// Events received while waiting for a reply.
    events: std.ArrayList(Event) = .empty,
    /// The sequence number of the last request.
    seq: u16 = 0,
    id_base: u32 = 0,
    id_mask: u32 = 0,
    next_id: u32 = 1,
    /// The longest request, in bytes.
    max_request: usize = 4 * 65535,
    root: u32 = 0,
    root_visual: u32 = 0,
    root_depth: u8 = 0,
    colormap: u32 = 0,
    /// Whether the root visual is 24-bit TrueColor in 32-bit pixels, red
    /// in the high byte (the software renderer's frames are converted to
    /// that).
    bgrx: bool = false,
    min_keycode: u8 = 8,
    max_keycode: u8 = 255,
    /// The keyboard mapping: `per_keycode` keysyms for each keycode from
    /// `min_keycode`.
    keysyms: []u32 = &.{},
    per_keycode: u8 = 0,

    /// Connects to the display in `DISPLAY` (a local one: `:N`, `:N.S`,
    /// `unix:N`).
    pub fn open(gpa: Allocator) Error!*Conn {
        const display = std.mem.span(c.getenv("DISPLAY") orelse return error.NoDisplay);
        return openDisplay(gpa, display);
    }

    pub fn openDisplay(gpa: Allocator, display: []const u8) Error!*Conn {
        const colon = std.mem.lastIndexOfScalar(u8, display, ':') orelse return error.NoDisplay;
        const host = display[0..colon];
        if (host.len > 0 and !std.mem.eql(u8, host, "unix")) return error.ConnectFailed; // TCP: not supported
        const rest = display[colon + 1 ..];
        const number = rest[0 .. std.mem.indexOfScalar(u8, rest, '.') orelse rest.len];
        if (number.len == 0) return error.NoDisplay;
        const fd = connectLocal(number) orelse return error.ConnectFailed;
        errdefer _ = c.close(fd);
        const self = try gpa.create(Conn);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .fd = fd };
        errdefer self.freeBuffers();
        try self.setup(number);
        try self.loadKeymap();
        return self;
    }

    pub fn close(self: *Conn) void {
        self.flush() catch {};
        _ = c.close(self.fd);
        self.freeBuffers();
        self.gpa.destroy(self);
    }

    fn freeBuffers(self: *Conn) void {
        self.out.deinit(self.gpa);
        self.in.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.gpa.free(self.keysyms);
    }

    pub fn newId(self: *Conn) u32 {
        defer self.next_id += 1;
        return self.id_base | (self.next_id & self.id_mask);
    }

    // ---- Setup ----

    fn setup(self: *Conn, number: []const u8) Error!void {
        var cookie: [16]u8 = undefined;
        const has_cookie = readCookie(number, &cookie);
        const name = "MIT-MAGIC-COOKIE-1";
        var req: [12 + 20 + 16]u8 = @splat(0);
        req[0] = 'l';
        std.mem.writeInt(u16, req[2..4], 11, .little);
        std.mem.writeInt(u16, req[4..6], 0, .little);
        var len: usize = 12;
        if (has_cookie) {
            std.mem.writeInt(u16, req[6..8], name.len, .little);
            std.mem.writeInt(u16, req[8..10], 16, .little);
            @memcpy(req[12..][0..name.len], name);
            @memcpy(req[12 + 20 ..][0..16], &cookie);
            len = req.len;
        }
        try writeAll(self.fd, req[0..len]);

        var head: [8]u8 = undefined;
        try self.readExact(&head);
        const extra = @as(usize, std.mem.readInt(u16, head[6..8], .little)) * 4;
        const body = try self.gpa.alloc(u8, extra);
        defer self.gpa.free(body);
        try self.readExact(body);
        if (head[0] != 1) {
            const reason_len = head[1];
            log.info("X server refused the connection: {s}", .{body[0..@min(reason_len, body.len)]});
            return error.SetupFailed;
        }
        if (body.len < 32) return error.SetupFailed;
        self.id_base = std.mem.readInt(u32, body[4..8], .little);
        self.id_mask = std.mem.readInt(u32, body[8..12], .little);
        const vendor_len = std.mem.readInt(u16, body[16..18], .little);
        self.max_request = @as(usize, std.mem.readInt(u16, body[18..20], .little)) * 4;
        const formats = body[21];
        self.min_keycode = body[26];
        self.max_keycode = body[27];
        var at: usize = 32 + std.mem.alignForward(usize, vendor_len, 4);
        // Pixmap formats: the bits per pixel of each depth.
        var bpp24: u8 = 0;
        for (0..formats) |_| {
            if (at + 8 > body.len) return error.SetupFailed;
            if (body[at] == 24) bpp24 = body[at + 1];
            at += 8;
        }
        // The first screen.
        if (at + 40 > body.len) return error.SetupFailed;
        const screen = body[at..];
        self.root = std.mem.readInt(u32, screen[0..4], .little);
        self.colormap = std.mem.readInt(u32, screen[4..8], .little);
        self.root_visual = std.mem.readInt(u32, screen[32..36], .little);
        self.root_depth = screen[38];
        const depths = screen[39];
        at += 40;
        for (0..depths) |_| {
            if (at + 8 > body.len) return error.SetupFailed;
            const depth = body[at];
            const visuals = std.mem.readInt(u16, body[at + 2 ..][0..2], .little);
            at += 8;
            for (0..visuals) |_| {
                if (at + 24 > body.len) return error.SetupFailed;
                const v = body[at..];
                const id = std.mem.readInt(u32, v[0..4], .little);
                if (id == self.root_visual and depth == 24 and v[4] == 4 and // TrueColor
                    std.mem.readInt(u32, v[8..12], .little) == 0xff0000 and
                    std.mem.readInt(u32, v[12..16], .little) == 0x00ff00 and
                    std.mem.readInt(u32, v[16..20], .little) == 0x0000ff and bpp24 == 32)
                    self.bgrx = true;
                at += 24;
            }
        }
        if (!self.bgrx) {
            log.info("the X screen's visual is not 24-bit TrueColor in 32-bit pixels", .{});
            return error.NoVisual;
        }
    }

    /// Reads the keyboard mapping (again, after a MappingNotify).
    pub fn loadKeymap(self: *Conn) Error!void {
        const count: u8 = self.max_keycode - self.min_keycode + 1;
        const seq = try self.request(op.get_keyboard_mapping, 0, &.{&.{ self.min_keycode, count, 0, 0 }});
        const r = try self.reply(seq);
        defer r.deinit(self.gpa);
        const per = r.u8At(1);
        const n = @as(usize, count) * per;
        if (r.data().len < n * 4) return error.RequestFailed;
        const keysyms = try self.gpa.alloc(u32, n);
        for (keysyms, 0..) |*k, i| k.* = std.mem.readInt(u32, r.data()[i * 4 ..][0..4], .little);
        self.gpa.free(self.keysyms);
        self.keysyms = keysyms;
        self.per_keycode = per;
    }

    /// The keysym of `keycode` at `index` (0: unshifted, 1: shifted, 4 and
    /// 5: with AltGr), or 0.
    pub fn keysym(self: *const Conn, keycode: u8, index: usize) u32 {
        if (keycode < self.min_keycode or index >= self.per_keycode) return 0;
        const at = @as(usize, keycode - self.min_keycode) * self.per_keycode + index;
        return if (at < self.keysyms.len) self.keysyms[at] else 0;
    }

    /// A keycode producing `sym` (unshifted), or null.
    pub fn keycodeOf(self: *const Conn, sym: u32) ?u8 {
        if (self.per_keycode == 0) return null;
        for (0..self.keysyms.len / self.per_keycode) |i| {
            if (self.keysyms[i * self.per_keycode] == sym) return @intCast(self.min_keycode + i);
        }
        return null;
    }

    // ---- Requests ----

    /// Queues a request: opcode, its data byte, and its body (parts,
    /// concatenated and padded). Returns its sequence number.
    pub fn request(self: *Conn, opcode: u8, data: u8, parts: []const []const u8) Error!u16 {
        var len: usize = 4;
        for (parts) |p| len += p.len;
        const padded = std.mem.alignForward(usize, len, 4);
        if (padded > self.max_request) return error.RequestFailed;
        if (self.out.items.len + padded > 1 << 16) try self.flush();
        try self.out.ensureUnusedCapacity(self.gpa, padded);
        self.out.appendSliceAssumeCapacity(&.{ opcode, data });
        var l: [2]u8 = undefined;
        std.mem.writeInt(u16, &l, @intCast(padded / 4), .little);
        self.out.appendSliceAssumeCapacity(&l);
        for (parts) |p| self.out.appendSliceAssumeCapacity(p);
        self.out.appendNTimesAssumeCapacity(0, padded - len);
        self.seq +%= 1;
        return self.seq;
    }

    pub fn flush(self: *Conn) Error!void {
        if (self.out.items.len == 0) return;
        defer self.out.clearRetainingCapacity();
        try writeAll(self.fd, self.out.items);
    }

    /// Waits for the reply to request `seq` (at most 5 s); events received
    /// meanwhile are kept for `nextEvent`.
    pub fn reply(self: *Conn, seq: u16) Error!Reply {
        try self.flush();
        var waited: u32 = 0;
        while (true) {
            while (try self.parseOne()) |m| {
                const s = std.mem.readInt(u16, m[2..4], .little);
                if (m[0] == 1 and s == seq) return .{ .bytes = m };
                defer self.gpa.free(m);
                if (m[0] == 0) {
                    logError(m);
                    if (s == seq) return error.RequestFailed;
                } else if (m[0] != 1) try self.events.append(self.gpa, m[0..32].*);
            }
            if (waited >= 5000) return error.Timeout;
            if (!try self.fill(100)) waited += 100;
        }
    }

    /// The next event, waiting at most `timeout_ms` for one (0: not at
    /// all). Errors from requests without replies are logged.
    pub fn nextEvent(self: *Conn, timeout_ms: u32) Error!?Event {
        try self.flush();
        if (self.events.items.len > 0) return self.events.orderedRemove(0);
        var waited = false;
        while (true) {
            while (try self.parseOne()) |m| {
                defer self.gpa.free(m);
                if (m[0] == 0) logError(m) else if (m[0] != 1) return m[0..32].*;
            }
            if (waited) return null;
            if (!try self.fill(timeout_ms)) {
                if (timeout_ms == 0) return null;
                waited = true;
            } else while (try self.fill(0)) {}
        }
    }

    /// Whether there is something to read (events already received count).
    pub fn pending(self: *const Conn) bool {
        return self.events.items.len > 0 or self.in.items.len >= 32;
    }

    fn logError(m: []const u8) void {
        log.warn("X error {d} (request {d}.{d}, value 0x{x})", .{ m[1], m[10], std.mem.readInt(u16, m[8..10], .little), std.mem.readInt(u32, m[4..8], .little) });
    }

    /// A message from the bytes received, if one is complete (owned).
    fn parseOne(self: *Conn) Error!?[]u8 {
        if (self.in.items.len < 32) return null;
        const len: usize = if (self.in.items[0] == 1) 32 + 4 * @as(usize, std.mem.readInt(u32, self.in.items[4..8], .little)) else 32;
        if (self.in.items.len < len) return null;
        const m = try self.gpa.dupe(u8, self.in.items[0..len]);
        self.in.replaceRangeAssumeCapacity(0, len, &.{});
        return m;
    }

    /// Reads what has arrived, waiting at most `timeout_ms` for it; whether
    /// anything did.
    fn fill(self: *Conn, timeout_ms: u32) Error!bool {
        var p = [1]c.pollfd{.{ .fd = self.fd, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&p, 1, @intCast(@min(timeout_ms, std.math.maxInt(i32)))) <= 0) return false;
        var buf: [16384]u8 = undefined;
        const got = c.read(self.fd, &buf, buf.len);
        if (got <= 0) {
            if (got < 0 and std.posix.errno(got) == .INTR) return false;
            return error.Disconnected;
        }
        try self.in.appendSlice(self.gpa, buf[0..@intCast(got)]);
        return true;
    }

    fn readExact(self: *Conn, buf: []u8) Error!void {
        var got: usize = 0;
        while (got < buf.len) {
            var p = [1]c.pollfd{.{ .fd = self.fd, .events = c.POLL.IN, .revents = 0 }};
            if (c.poll(&p, 1, 5000) <= 0) return error.Timeout;
            const n = c.read(self.fd, buf[got..].ptr, buf.len - got);
            if (n <= 0) return error.Disconnected;
            got += @intCast(n);
        }
    }

    // ---- Helpers for common requests ----

    pub fn internAtom(self: *Conn, name: []const u8) Error!u32 {
        const seq = try self.request(op.intern_atom, 0, &.{ &le16(@intCast(name.len)), &.{ 0, 0 }, name });
        const r = try self.reply(seq);
        defer r.deinit(self.gpa);
        return r.u32At(8);
    }

    /// Sets a property (`format` 8, 16 or 32; `data` in bytes).
    pub fn changeProperty(self: *Conn, window: u32, property: u32, kind: u32, format: u8, data: []const u8) Error!void {
        const units: u32 = @intCast(data.len / (format / 8));
        _ = try self.request(op.change_property, 0, &.{ &le32(window), &le32(property), &le32(kind), &.{ format, 0, 0, 0 }, &le32(units), data });
    }

    /// A property's value (at most `max_bytes`), or null if it has none.
    pub fn getProperty(self: *Conn, window: u32, property: u32, kind: u32, max_bytes: u32) Error!?Reply {
        const seq = try self.request(op.get_property, 0, &.{ &le32(window), &le32(property), &le32(kind), &le32(0), &le32(max_bytes / 4) });
        const r = try self.reply(seq);
        if (r.u32At(8) == 0) { // type None: no such property
            r.deinit(self.gpa);
            return null;
        }
        return r;
    }

    pub fn sendEvent(self: *Conn, destination: u32, mask: u32, event: *const Event) Error!void {
        _ = try self.request(op.send_event, 0, &.{ &le32(destination), &le32(mask), event });
    }
};

pub fn le16(v: u16) [2]u8 {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    return b;
}

pub fn le32(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}

fn writeAll(fd: c.fd_t, bytes: []const u8) Error!void {
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

/// The display's socket: the abstract one (Linux), else the file.
fn connectLocal(number: []const u8) ?c.fd_t {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/tmp/.X11-unix/X{s}", .{number}) catch return null;
    for ([_]bool{ true, false }) |abstract| {
        if (abstract and builtin.os.tag != .linux) continue;
        var addr: c.sockaddr.un = .{ .path = @splat(0) };
        const off: usize = @intFromBool(abstract);
        if (off + path.len >= addr.path.len) return null;
        @memcpy(addr.path[off..][0..path.len], path);
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (fd < 0) return null;
        if (builtin.os.tag.isDarwin()) {
            const one: c_int = 1;
            _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
        }
        const size: c.socklen_t = @intCast(@offsetOf(c.sockaddr.un, "path") + off + path.len + @as(usize, @intFromBool(!abstract)));
        if (c.connect(fd, @ptrCast(&addr), size) == 0) return fd;
        _ = c.close(fd);
    }
    return null;
}

/// The MIT-MAGIC-COOKIE-1 for display `number`, from `XAUTHORITY` or
/// ~/.Xauthority; false if there is none.
fn readCookie(number: []const u8, out: *[16]u8) bool {
    var path_buf: [512]u8 = undefined;
    const path: [:0]const u8 = if (c.getenv("XAUTHORITY")) |p| std.mem.span(p) else blk: {
        const home = std.mem.span(c.getenv("HOME") orelse return false);
        break :blk std.fmt.bufPrintZ(&path_buf, "{s}/.Xauthority", .{home}) catch return false;
    };
    const fd = c.open(path, .{});
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var buf: [16384]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = c.read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    // Entries: family, then address, display number, name and data, each
    // with a big-endian length.
    var at: usize = 0;
    while (at + 2 <= len) {
        const family = std.mem.readInt(u16, buf[at..][0..2], .big);
        at += 2;
        var fields: [4][]const u8 = undefined;
        for (&fields) |*f| {
            if (at + 2 > len) return false;
            const n = std.mem.readInt(u16, buf[at..][0..2], .big);
            at += 2;
            if (at + n > len) return false;
            f.* = buf[at..][0..n];
            at += n;
        }
        // Local (256) or any (65535) address; this display or any.
        const local = family == 256 or family == 65535;
        const display_ok = fields[1].len == 0 or std.mem.eql(u8, fields[1], number);
        if (local and display_ok and std.mem.eql(u8, fields[2], "MIT-MAGIC-COOKIE-1") and fields[3].len == 16) {
            @memcpy(out, fields[3][0..16]);
            return true;
        }
    }
    return false;
}

// ---- Keysyms ----

/// The character a keysym types, if any (Latin-1 and Unicode keysyms,
/// the keypad's digits and operators).
pub fn keysymToCodepoint(sym: u32) ?u21 {
    if ((sym >= 0x20 and sym <= 0x7e) or (sym >= 0xa0 and sym <= 0xff)) return @intCast(sym);
    if (sym & 0xff000000 == 0x01000000) return std.math.cast(u21, sym & 0x00ffffff);
    return switch (sym) {
        0xffb0...0xffb9 => @intCast(sym - 0xffb0 + '0'), // KP_0..KP_9
        0xffaa => '*',
        0xffab => '+',
        0xffad => '-',
        0xffae => '.',
        0xffaf => '/',
        0xff80 => ' ',
        0x20ac => 0x20ac, // EuroSign
        else => null,
    };
}

pub const keysym_iso_level3_shift = 0xfe03;

test "keysyms to characters" {
    try std.testing.expectEqual(@as(?u21, 'a'), keysymToCodepoint('a'));
    try std.testing.expectEqual(@as(?u21, 0xe9), keysymToCodepoint(0xe9));
    try std.testing.expectEqual(@as(?u21, 0x3b1), keysymToCodepoint(0x010003b1));
    try std.testing.expectEqual(@as(?u21, '5'), keysymToCodepoint(0xffb5));
    try std.testing.expectEqual(@as(?u21, null), keysymToCodepoint(0xff0d));
}
