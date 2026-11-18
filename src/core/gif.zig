// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! GIF images, still or animated: decoded frame by frame onto a canvas
//! (`AnimatedImage` plays them; `@image-url` shows their first frame).
//! Frames are composited as browsers do: transparent pixels let the
//! picture under them show, and each frame's disposal clears or restores
//! its area before the next one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const graphics = @import("graphics.zig");
const Rgba8 = graphics.Rgba8;

pub const DecodeError = error{ InvalidGif, OutOfMemory };

pub fn isGif(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a");
}

/// A color table: where it is in the file, and its entries.
pub const Table = struct { at: usize, len: usize };

pub const Frame = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    delay_ms: u32,
    /// After showing it: 0 leave, 1 clear its area, 2 restore its area (as
    /// APNG's).
    dispose: u8,
    transparent: ?u8,
    interlaced: bool,
    /// Its color table (offset in the file, entries); else the global one.
    palette: ?Table,
    /// The LZW minimum code size, then the data's sub-blocks.
    data: usize,
};

/// A GIF's frames, and the picture as far as it is drawn. The bytes are
/// borrowed.
pub const Gif = struct {
    gpa: Allocator,
    bytes: []const u8,
    width: u32 = 0,
    height: u32 = 0,
    global: ?Table = null,
    frames: std.ArrayList(Frame) = .empty,
    /// How many times it plays (0: forever).
    plays: u32 = 1,
    canvas: []Rgba8 = &.{},
    saved: []Rgba8 = &.{},
    indices: []u8 = &.{},
    /// The next frame `advance` draws.
    next: usize = 0,
    pending: ?Frame = null,

    pub fn open(gpa: Allocator, bytes: []const u8) DecodeError!*Gif {
        const g = try gpa.create(Gif);
        g.* = .{ .gpa = gpa, .bytes = bytes };
        errdefer g.close();
        try g.parse();
        const n = @as(usize, g.width) * g.height;
        g.canvas = try gpa.alloc(Rgba8, n);
        @memset(g.canvas, Rgba8.transparent);
        g.saved = try gpa.alloc(Rgba8, n);
        return g;
    }

    pub fn close(g: *Gif) void {
        const gpa = g.gpa;
        g.frames.deinit(gpa);
        gpa.free(g.canvas);
        gpa.free(g.saved);
        gpa.free(g.indices);
        gpa.destroy(g);
    }

    fn parse(g: *Gif) DecodeError!void {
        const b = g.bytes;
        if (!isGif(b) or b.len < 13) return error.InvalidGif;
        g.width = std.mem.readInt(u16, b[6..8], .little);
        g.height = std.mem.readInt(u16, b[8..10], .little);
        if (g.width == 0 or g.height == 0) return error.InvalidGif;
        var pos: usize = 13;
        if (b[10] & 0x80 != 0) {
            const len = @as(usize, 2) << @intCast(b[10] & 7);
            g.global = .{ .at = pos, .len = len };
            pos += 3 * len;
            if (pos > b.len) return error.InvalidGif;
        }
        var shown_cs: u32 = 0;
        var dispose: u8 = 0;
        var transparent: ?u8 = null;
        var looping = false;
        // A file cut short keeps the frames before the cut.
        while (pos < b.len) {
            switch (b[pos]) {
                0x3b => break,
                0x21 => {
                    if (pos + 2 > b.len) break;
                    const label = b[pos + 1];
                    pos += 2;
                    const first = pos;
                    if (label == 0xf9 and pos + 6 <= b.len and b[pos] == 4) {
                        const packed_byte = b[pos + 1];
                        dispose = switch ((packed_byte >> 2) & 7) {
                            2 => 1,
                            3 => 2,
                            else => 0,
                        };
                        shown_cs = std.mem.readInt(u16, b[pos + 2 ..][0..2], .little);
                        transparent = if (packed_byte & 1 != 0) b[pos + 4] else null;
                    } else if (label == 0xff and pos + 12 <= b.len and b[pos] == 11 and
                        (std.mem.eql(u8, b[pos + 1 ..][0..11], "NETSCAPE2.0") or std.mem.eql(u8, b[pos + 1 ..][0..11], "ANIMEXTS1.0")))
                    {
                        const sub = pos + 12;
                        if (sub + 4 <= b.len and b[sub] >= 3 and b[sub + 1] == 1) {
                            const count = std.mem.readInt(u16, b[sub + 2 ..][0..2], .little);
                            looping = true;
                            // Repeats after the first play; 0: forever.
                            g.plays = if (count == 0) 0 else @as(u32, count) + 1;
                        }
                    }
                    pos = skipBlocks(b, first) orelse break;
                },
                0x2c => {
                    if (pos + 10 > b.len) break;
                    const d = b[pos + 1 ..][0..9];
                    var f: Frame = .{
                        .x = std.mem.readInt(u16, d[0..2], .little),
                        .y = std.mem.readInt(u16, d[2..4], .little),
                        .width = std.mem.readInt(u16, d[4..6], .little),
                        .height = std.mem.readInt(u16, d[6..8], .little),
                        // As browsers: too fast means 100 ms.
                        .delay_ms = if (shown_cs <= 1) 100 else shown_cs * 10,
                        .dispose = dispose,
                        .transparent = transparent,
                        .interlaced = d[8] & 0x40 != 0,
                        .palette = null,
                        .data = 0,
                    };
                    pos += 10;
                    if (d[8] & 0x80 != 0) {
                        const len = @as(usize, 2) << @intCast(d[8] & 7);
                        f.palette = .{ .at = pos, .len = len };
                        pos += 3 * len;
                        if (pos > b.len) break;
                    }
                    if (pos >= b.len) break;
                    f.data = pos;
                    const end = skipBlocks(b, pos + 1) orelse b.len;
                    if (f.width > 0 and f.height > 0 and (f.palette != null or g.global != null)) try g.frames.append(g.gpa, f);
                    pos = end;
                    shown_cs = 0;
                    dispose = 0;
                    transparent = null;
                },
                else => break,
            }
        }
        if (g.frames.items.len == 0) return error.InvalidGif;
        if (!looping) g.plays = 1;
        var largest: usize = 0;
        for (g.frames.items) |f| largest = @max(largest, @as(usize, f.width) * f.height);
        g.indices = try g.gpa.alloc(u8, largest);
    }

    /// Draws the next frame onto the canvas.
    pub fn advance(g: *Gif) DecodeError!void {
        if (g.next >= g.frames.items.len) return;
        const w = g.width;
        if (g.pending) |p| {
            const area = g.clipped(p);
            switch (p.dispose) {
                1 => for (0..area.height) |row| @memset(g.canvas[(area.y + row) * w + area.x ..][0..area.width], Rgba8.transparent),
                2 => for (0..area.height) |row| @memcpy(g.canvas[(area.y + row) * w + area.x ..][0..area.width], g.saved[row * area.width ..][0..area.width]),
                else => {},
            }
        }
        var f = g.frames.items[g.next];
        if (g.next == 0 and f.dispose == 2) f.dispose = 1;
        const area = g.clipped(f);
        if (f.dispose == 2) for (0..area.height) |row| @memcpy(g.saved[row * area.width ..][0..area.width], g.canvas[(area.y + row) * w + area.x ..][0..area.width]);

        const pixels = @as(usize, f.width) * f.height;
        const decoded = lzw(g.bytes, f.data, g.indices[0..pixels]);
        const table = f.palette orelse g.global.?;
        for (0..decoded) |i| {
            const index = g.indices[i];
            if (f.transparent == index) continue;
            const row = if (f.interlaced) interlacedRow(@intCast(i / f.width), f.height) else i / f.width;
            const x = f.x + i % f.width;
            const y = f.y + row;
            if (x >= w or y >= g.height) continue;
            g.canvas[y * w + x] = if (index < table.len) blk: {
                const c = g.bytes[table.at + 3 * @as(usize, index) ..][0..3];
                break :blk .{ .r = c[0], .g = c[1], .b = c[2], .a = 255 };
            } else .{ .r = 0, .g = 0, .b = 0, .a = 255 };
        }
        g.pending = f;
        g.next += 1;
    }

    /// Whether frame `i` hides everything before it.
    pub fn isKey(g: *const Gif, i: usize) bool {
        const f = g.frames.items[i];
        return i == 0 or (f.transparent == null and f.x == 0 and f.y == 0 and f.width >= g.width and f.height >= g.height);
    }

    pub fn restart(g: *Gif) void {
        @memset(g.canvas, Rgba8.transparent);
        g.next = 0;
        g.pending = null;
    }

    pub fn delay(g: *const Gif, i: usize) u32 {
        return g.frames.items[i].delay_ms;
    }

    /// The part of `f` on the canvas.
    fn clipped(g: *const Gif, f: Frame) struct { x: usize, y: usize, width: usize, height: usize } {
        const x = @min(f.x, g.width);
        const y = @min(f.y, g.height);
        return .{ .x = x, .y = y, .width = @min(f.width, g.width - x), .height = @min(f.height, g.height - y) };
    }
};

/// Where sub-blocks starting at `pos` end (after their terminator).
fn skipBlocks(b: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos < b.len) {
        const len = b[pos];
        pos += 1 + @as(usize, len);
        if (len == 0) return pos;
    }
    return null;
}

/// The row an interlaced image's `i`th row of data goes to: every 8th row
/// from 0, every 8th from 4, every 4th from 2, then every 2nd from 1.
fn interlacedRow(i: u32, height: u32) u32 {
    const passes = [_][2]u32{ .{ 0, 8 }, .{ 4, 8 }, .{ 2, 4 }, .{ 1, 2 } };
    var n = i;
    for (passes) |p| {
        const rows = if (height > p[0]) (height - p[0] + p[1] - 1) / p[1] else 0;
        if (n < rows) return p[0] + n * p[1];
        n -= rows;
    }
    return height - 1;
}

/// Decompresses the LZW data at `at` (its minimum code size, then
/// sub-blocks) into `out`; returns how many indices it holds (less than
/// `out.len` if the data ends early).
fn lzw(b: []const u8, at: usize, out: []u8) usize {
    // Indices are bytes: 8 bits at most (2 at least, as decoders take it).
    if (at >= b.len or b[at] > 8) return 0;
    const min: u4 = @intCast(@max(b[at], 2));
    const clear: u16 = @as(u16, 1) << min;
    const eoi = clear + 1;
    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var first: [4096]u8 = undefined;
    var lengths: [4096]u16 = undefined;
    for (0..clear) |c| {
        suffix[c] = @intCast(c);
        first[c] = @intCast(c);
        lengths[c] = 1;
    }
    var size: u5 = @as(u5, min) + 1;
    var next: u16 = eoi + 1;
    var prev: ?u16 = null;
    var n: usize = 0;

    // Bits, least significant first, across sub-blocks.
    var pos = at + 1;
    var block_end = pos;
    var bits: u32 = 0;
    var count: u5 = 0;
    while (true) {
        if (n >= out.len) return out.len;
        while (count < size) {
            if (pos == block_end) {
                if (pos >= b.len or b[pos] == 0) return n;
                block_end = pos + 1 + b[pos];
                pos += 1;
                if (block_end > b.len) block_end = b.len;
                if (pos == block_end) return n;
            }
            bits |= @as(u32, b[pos]) << count;
            pos += 1;
            count += 8;
        }
        const code: u16 = @intCast(bits & ((@as(u32, 1) << size) - 1));
        bits >>= size;
        count -= size;

        if (code == clear) {
            size = @as(u5, min) + 1;
            next = eoi + 1;
            prev = null;
            continue;
        }
        if (code == eoi) return n;
        const p = prev orelse {
            if (code >= clear) return n;
            if (n < out.len) out[n] = @intCast(code);
            n += 1;
            prev = code;
            continue;
        };
        var entry = code;
        if (code < next) {
            if (code >= clear and code <= eoi) return n;
        } else if (code == next and next < 4096) {
            // The previous string and its own first index.
            entry = next;
            prefix[next] = p;
            suffix[next] = first[p];
            first[next] = first[p];
            lengths[next] = lengths[p] + 1;
        } else return n;
        // Its string, written backwards from its end.
        const len = lengths[entry];
        var e = entry;
        var k: usize = len;
        while (k > 0) {
            k -= 1;
            if (n + k < out.len) out[n + k] = suffix[e];
            if (k > 0) e = prefix[e];
        }
        n += len;
        if (n >= out.len) return out.len;
        if (code < next and next < 4096) {
            prefix[next] = p;
            suffix[next] = first[code];
            first[next] = first[p];
            lengths[next] = lengths[p] + 1;
        }
        if (next < 4096) next += 1;
        if (size < 12 and next == @as(u16, 1) << @intCast(size)) size += 1;
        prev = code;
    }
}

// ---- Tests ----

const testing = std.testing;

/// A GIF of `frames` (indices into a palette of red, green, blue and a
/// transparent fourth), `width` x `height`, each shown `delay_cs`
/// hundredths of a second, playing `plays` times (0: forever). Its LZW
/// data starts over every few codes, so codes stay 3 bits.
pub fn testGif(gpa: Allocator, width: u16, height: u16, frames: []const []const u8, delay_cs: u16, plays: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "GIF89a");
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, width)));
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, height)));
    try out.appendSlice(gpa, &.{ 0x81, 0, 0 }); // a global table of 4
    try out.appendSlice(gpa, &.{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0 });
    if (plays != 1) {
        try out.appendSlice(gpa, &.{ 0x21, 0xff, 11 });
        try out.appendSlice(gpa, "NETSCAPE2.0");
        const count: u16 = if (plays == 0) 0 else plays - 1;
        try out.appendSlice(gpa, &.{ 3, 1, @truncate(count), @truncate(count >> 8), 0 });
    }
    for (frames) |f| {
        try out.appendSlice(gpa, &.{ 0x21, 0xf9, 4, 0x01, @truncate(delay_cs), @truncate(delay_cs >> 8), 3, 0 });
        try out.appendSlice(gpa, &.{0x2c});
        try out.appendSlice(gpa, &.{ 0, 0, 0, 0, @truncate(width), @truncate(width >> 8), @truncate(height), @truncate(height >> 8), 0 });
        try out.append(gpa, 2); // minimum code size
        // Codes of 3 bits: clear (4), then up to 2 indices, again.
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        var bits: u32 = 0;
        var count: u5 = 0;
        for (f, 0..) |index, i| {
            if (i % 2 == 0) {
                bits |= @as(u32, 4) << count;
                count += 3;
            }
            bits |= @as(u32, index) << count;
            count += 3;
            while (count >= 8) {
                try data.append(gpa, @truncate(bits));
                bits >>= 8;
                count -= 8;
            }
        }
        bits |= @as(u32, 5) << count; // end
        count += 3;
        while (count > 0) {
            try data.append(gpa, @truncate(bits));
            bits >>= 8;
            count -|= 8;
        }
        var rest = data.items;
        while (rest.len > 0) {
            const n = @min(rest.len, 255);
            try out.append(gpa, @intCast(n));
            try out.appendSlice(gpa, rest[0..n]);
            rest = rest[n..];
        }
        try out.append(gpa, 0);
    }
    try out.append(gpa, 0x3b);
    return out.toOwnedSlice(gpa);
}

test "a GIF's frames: colors, transparency over the frame before, the loop count" {
    // 2 x 2: red green / blue clear, then all green but one clear pixel.
    const bytes = try testGif(testing.allocator, 2, 2, &.{ &.{ 0, 1, 2, 3 }, &.{ 3, 1, 1, 1 } }, 5, 3);
    defer testing.allocator.free(bytes);
    const g = try Gif.open(testing.allocator, bytes);
    defer g.close();
    try testing.expectEqual(@as(u32, 2), g.width);
    try testing.expectEqual(@as(usize, 2), g.frames.items.len);
    try testing.expectEqual(@as(u32, 50), g.delay(0));
    try testing.expectEqual(@as(u32, 3), g.plays);
    try g.advance();
    try testing.expectEqual(Rgba8{ .r = 255, .g = 0, .b = 0, .a = 255 }, g.canvas[0]);
    try testing.expectEqual(Rgba8{ .r = 0, .g = 255, .b = 0, .a = 255 }, g.canvas[1]);
    try testing.expectEqual(Rgba8{ .r = 0, .g = 0, .b = 255, .a = 255 }, g.canvas[2]);
    try testing.expectEqual(Rgba8.transparent, g.canvas[3]);
    try g.advance();
    // Its transparent pixel shows the red under it.
    try testing.expectEqual(Rgba8{ .r = 255, .g = 0, .b = 0, .a = 255 }, g.canvas[0]);
    try testing.expectEqual(Rgba8{ .r = 0, .g = 255, .b = 0, .a = 255 }, g.canvas[3]);
}

test "LZW with growing codes, and interlaced rows" {
    // "ab" repeated: the dictionary grows past 3-bit codes.
    // Encoded by hand with a minimum code size of 2: clear, then the codes
    // a GIF encoder writes for 0 1 0 1 0 1 0 1 0 1.
    const codes = [_]struct { u16, u5 }{ .{ 4, 3 }, .{ 0, 3 }, .{ 1, 3 }, .{ 6, 3 }, .{ 8, 4 }, .{ 7, 4 }, .{ 1, 4 }, .{ 5, 4 } };
    var data: [16]u8 = undefined;
    var bits: u32 = 0;
    var count: u5 = 0;
    var n: usize = 0;
    for (codes) |c| {
        bits |= @as(u32, c[0]) << count;
        count += c[1];
        while (count >= 8) : (count -= 8) {
            data[n] = @truncate(bits);
            n += 1;
            bits >>= 8;
        }
    }
    if (count > 0) {
        data[n] = @truncate(bits);
        n += 1;
    }
    var file: [32]u8 = undefined;
    file[0] = 2;
    file[1] = @intCast(n);
    @memcpy(file[2..][0..n], data[0..n]);
    file[2 + n] = 0;
    var out: [10]u8 = undefined;
    try testing.expectEqual(@as(usize, 10), lzw(&file, 0, &out));
    try testing.expectEqualSlices(u8, &.{ 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 }, &out);

    // 8 rows: 0, 4, 2, 6, 1, 3, 5, 7.
    const order = [_]u32{ 0, 4, 2, 6, 1, 3, 5, 7 };
    for (order, 0..) |row, i| try testing.expectEqual(row, interlacedRow(@intCast(i), 8));
}

test "files that are not GIFs, or cut short" {
    try testing.expectError(error.InvalidGif, Gif.open(testing.allocator, "GIF89a"));
    try testing.expectError(error.InvalidGif, Gif.open(testing.allocator, "\x89PNG"));
    const bytes = try testGif(testing.allocator, 2, 1, &.{ &.{ 0, 1 }, &.{ 1, 0 } }, 10, 0);
    defer testing.allocator.free(bytes);
    // Cut in the second frame: the first one plays.
    const g = try Gif.open(testing.allocator, bytes[0 .. bytes.len - 8]);
    defer g.close();
    try testing.expect(g.frames.items.len >= 1);
    try testing.expectEqual(@as(u32, 0), g.plays);
}
