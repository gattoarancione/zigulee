// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! PNG decoding (to premultiplied RGBA) and encoding (for golden tests and
//! screenshots). Supports all non-interlaced color types and bit depths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const graphics = @import("graphics.zig");
const Rgba8 = graphics.Rgba8;
const Color = graphics.Color;
const image = @import("image.zig");
const OwnedImage = image.OwnedImage;

pub const DecodeError = error{
    InvalidPng,
    UnsupportedPng,
} || Allocator.Error;

pub const signature = "\x89PNG\r\n\x1a\n";

pub const ColorType = enum(u8) {
    gray = 0,
    rgb = 2,
    palette = 3,
    gray_alpha = 4,
    rgba = 6,

    fn channels(c: ColorType) u32 {
        return switch (c) {
            .gray, .palette => 1,
            .gray_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }
};

pub const Header = struct {
    width: u32,
    height: u32,
    depth: u8,
    color: ColorType,

    fn bitsPerPixel(h: Header) u32 {
        return h.color.channels() * h.depth;
    }

    fn rowBytes(h: Header) usize {
        return (@as(usize, h.width) * h.bitsPerPixel() + 7) / 8;
    }
};

/// Decodes a PNG file. The caller owns the returned image.
pub fn decode(gpa: Allocator, bytes: []const u8) DecodeError!OwnedImage {
    if (!std.mem.startsWith(u8, bytes, signature)) return error.InvalidPng;
    var pos: usize = signature.len;

    var header: ?Header = null;
    var palette: [256]Color = @splat(Color.black);
    var transparent_key: ?[3]u16 = null;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);

    while (true) {
        if (pos + 12 > bytes.len) return error.InvalidPng;
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4];
        if (pos + 12 + len > bytes.len) return error.InvalidPng;
        const data = bytes[pos + 8 ..][0..len];
        const crc = std.mem.readInt(u32, bytes[pos + 8 + len ..][0..4], .big);
        if (std.hash.Crc32.hash(bytes[pos + 4 .. pos + 8 + len]) != crc) return error.InvalidPng;
        pos += 12 + len;

        if (std.mem.eql(u8, kind, "IHDR")) {
            header = try parseHeader(data);
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            try readPalette(data, &palette);
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            readTransparency(header orelse return error.InvalidPng, data, &palette, &transparent_key);
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        } else if (kind[0] & 0x20 == 0) {
            return error.UnsupportedPng; // unknown critical chunk
        }
    }

    const h = header orelse return error.InvalidPng;
    var result: OwnedImage = try .init(gpa, h.width, h.height);
    errdefer result.deinit(gpa);
    try decodePixels(gpa, h, idat.items, &palette, transparent_key, result.pixels);
    return result;
}

/// The IHDR chunk's contents.
pub fn parseHeader(data: []const u8) DecodeError!Header {
    if (data.len != 13) return error.InvalidPng;
    const color = std.enums.fromInt(ColorType, data[9]) orelse return error.InvalidPng;
    const h: Header = .{
        .width = std.mem.readInt(u32, data[0..4], .big),
        .height = std.mem.readInt(u32, data[4..8], .big),
        .depth = data[8],
        .color = color,
    };
    const valid_depth = switch (color) {
        .gray => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8 or h.depth == 16,
        .palette => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8,
        else => h.depth == 8 or h.depth == 16,
    };
    if (!valid_depth or h.width == 0 or h.height == 0) return error.InvalidPng;
    if (data[10] != 0 or data[11] != 0) return error.InvalidPng;
    if (data[12] != 0) return error.UnsupportedPng; // interlaced
    return h;
}

/// The PLTE chunk's colors, into `palette`.
pub fn readPalette(data: []const u8, palette: *[256]Color) DecodeError!void {
    if (data.len % 3 != 0 or data.len > 768) return error.InvalidPng;
    for (0..data.len / 3) |i| palette[i] = .{ .r = data[i * 3], .g = data[i * 3 + 1], .b = data[i * 3 + 2], .a = 255 };
}

/// The tRNS chunk: palette alphas, or the transparent color.
pub fn readTransparency(h: Header, data: []const u8, palette: *[256]Color, key: *?[3]u16) void {
    switch (h.color) {
        .palette => for (data, 0..) |a, i| {
            if (i < 256) palette[i].a = a;
        },
        .gray => if (data.len >= 2) {
            const v = std.mem.readInt(u16, data[0..2], .big);
            key.* = .{ v, v, v };
        },
        .rgb => if (data.len >= 6) {
            key.* = .{
                std.mem.readInt(u16, data[0..2], .big),
                std.mem.readInt(u16, data[2..4], .big),
                std.mem.readInt(u16, data[4..6], .big),
            };
        },
        else => {},
    }
}

/// Decodes compressed image data (the IDAT chunks' contents, joined) of an
/// image `h.width` x `h.height` into premultiplied `out`.
pub fn decodePixels(gpa: Allocator, h: Header, compressed: []const u8, palette: *const [256]Color, key: ?[3]u16, out: []Rgba8) DecodeError!void {
    const row_bytes = h.rowBytes();
    const raw_len = (row_bytes + 1) * h.height;

    // Inflate.
    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    {
        var in: std.Io.Reader = .fixed(compressed);
        var w: std.Io.Writer = .fixed(raw);
        var decompress: flate.Decompress = .init(&in, .zlib, &.{});
        const n = decompress.reader.streamRemaining(&w) catch return error.InvalidPng;
        if (n != raw_len) return error.InvalidPng;
    }

    // Undo the per-row filters in place.
    const bpp = @max(1, h.bitsPerPixel() / 8);
    var prev: ?[]const u8 = null;
    for (0..h.height) |y| {
        const filter = raw[y * (row_bytes + 1)];
        const row = raw[y * (row_bytes + 1) + 1 ..][0..row_bytes];
        try unfilter(filter, row, prev, bpp);
        prev = row;
    }

    for (0..h.height) |y| {
        const row = raw[y * (row_bytes + 1) + 1 ..][0..row_bytes];
        for (0..h.width) |x| {
            out[y * h.width + x] = readPixel(h, row, x, palette, key).premultiplied();
        }
    }
}

fn unfilter(filter: u8, row: []u8, prev: ?[]const u8, bpp: usize) DecodeError!void {
    for (row, 0..) |*c, i| {
        const a: u8 = if (i >= bpp) row[i - bpp] else 0;
        const b: u8 = if (prev) |p| p[i] else 0;
        const ab: u8 = if (i >= bpp) (if (prev) |p| p[i - bpp] else 0) else 0;
        c.* +%= switch (filter) {
            0 => 0,
            1 => a,
            2 => b,
            3 => @intCast((@as(u16, a) + b) / 2),
            4 => paeth(a, b, ab),
            else => return error.InvalidPng,
        };
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Reads sample `index` (of `depth` bits) from a row.
fn sample(row: []const u8, index: usize, depth: u8) u16 {
    return switch (depth) {
        16 => std.mem.readInt(u16, row[index * 2 ..][0..2], .big),
        8 => row[index],
        else => blk: {
            const per_byte = 8 / depth;
            const byte = row[index / per_byte];
            const shift: u3 = @intCast(8 - depth * (index % per_byte + 1));
            const mask = (@as(u16, 1) << @intCast(depth)) - 1;
            break :blk (byte >> shift) & mask;
        },
    };
}

fn to8(v: u16, depth: u8) u8 {
    return switch (depth) {
        16 => @intCast(v >> 8),
        8 => @intCast(v),
        else => @intCast(v * 255 / ((@as(u16, 1) << @intCast(depth)) - 1)),
    };
}

fn readPixel(h: Header, row: []const u8, x: usize, palette: *const [256]Color, key: ?[3]u16) Color {
    const n = h.color.channels();
    const s = struct {
        fn at(r: []const u8, i: usize, d: u8) u16 {
            return sample(r, i, d);
        }
    }.at;
    switch (h.color) {
        .palette => return palette[s(row, x, h.depth)],
        .gray => {
            const v = s(row, x, h.depth);
            const g = to8(v, h.depth);
            const transparent = if (key) |k| k[0] == v else false;
            return .{ .r = g, .g = g, .b = g, .a = if (transparent) 0 else 255 };
        },
        .gray_alpha => {
            const g = to8(s(row, x * n, h.depth), h.depth);
            return .{ .r = g, .g = g, .b = g, .a = to8(s(row, x * n + 1, h.depth), h.depth) };
        },
        .rgb => {
            const r = s(row, x * n, h.depth);
            const g = s(row, x * n + 1, h.depth);
            const b = s(row, x * n + 2, h.depth);
            const transparent = if (key) |k| k[0] == r and k[1] == g and k[2] == b else false;
            return .{ .r = to8(r, h.depth), .g = to8(g, h.depth), .b = to8(b, h.depth), .a = if (transparent) 0 else 255 };
        },
        .rgba => return .{
            .r = to8(s(row, x * n, h.depth), h.depth),
            .g = to8(s(row, x * n + 1, h.depth), h.depth),
            .b = to8(s(row, x * n + 2, h.depth), h.depth),
            .a = to8(s(row, x * n + 3, h.depth), h.depth),
        },
    }
}

/// Encodes premultiplied pixels as an 8-bit RGBA PNG. The caller owns the
/// returned bytes.
pub fn encode(gpa: Allocator, width: u32, height: u32, pixels: []const Rgba8) Allocator.Error![]u8 {
    const compressed = try compressPixels(gpa, width, height, pixels);
    defer gpa.free(compressed);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, @intFromEnum(ColorType.rgba), 0, 0, 0 };
    try writeChunk(gpa, &out, "IHDR", &ihdr);
    try writeChunk(gpa, &out, "IDAT", compressed);
    try writeChunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

/// Premultiplied pixels as zlib-compressed 8-bit RGBA scanlines (an IDAT
/// chunk's contents). The caller owns the returned bytes.
pub fn compressPixels(gpa: Allocator, width: u32, height: u32, pixels: []const Rgba8) Allocator.Error![]u8 {
    std.debug.assert(pixels.len == @as(usize, width) * height);

    // Raw scanlines with filter 0 (none), straight alpha.
    const row_bytes = @as(usize, width) * 4;
    const raw = try gpa.alloc(u8, (row_bytes + 1) * height);
    defer gpa.free(raw);
    for (0..height) |y| {
        raw[y * (row_bytes + 1)] = 0;
        for (0..width) |x| {
            const c = pixels[y * width + x].unpremultiplied();
            raw[y * (row_bytes + 1) + 1 + x * 4 ..][0..4].* = .{ c.r, c.g, c.b, c.a };
        }
    }

    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer compressed.deinit();
    {
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        const compress = try gpa.create(flate.Compress);
        defer gpa.destroy(compress);
        compress.* = flate.Compress.init(&compressed.writer, window, .zlib, .default) catch return error.OutOfMemory;
        compress.writer.writeAll(raw) catch return error.OutOfMemory;
        compress.finish() catch return error.OutOfMemory;
    }

    return gpa.dupe(u8, compressed.written());
}

pub fn writeChunk(gpa: Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) Allocator.Error!void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    const start = out.items.len;
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc, std.hash.Crc32.hash(out.items[start..]), .big);
    try out.appendSlice(gpa, &crc);
}

const testing = std.testing;

test "encode then decode round-trips premultiplied pixels" {
    const gpa = testing.allocator;
    var pixels: [6]Rgba8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = Color.rgba(@intCast(0x10203000 + i * 0x2a + 0xff)).premultiplied();
    pixels[5] = .transparent;
    const bytes = try encode(gpa, 3, 2, &pixels);
    defer gpa.free(bytes);
    var img = try decode(gpa, bytes);
    defer img.deinit(gpa);
    try testing.expectEqual(@as(u32, 3), img.width);
    try testing.expectEqualSlices(Rgba8, &pixels, img.pixels);
}

test "decodes a palette image with transparency, filters and low bit depth" {
    // 4x2, 2-bit palette: [red, green, blue, transparent], filter types 0 and 2.
    const gpa = testing.allocator;
    const raw = [_]u8{
        0, 0b00_01_10_11, // row 0: red green blue transparent
        2, 0b01_00_00_01, // row 1, "up" filter: adds the row above
    };
    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer compressed.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const compress = try gpa.create(flate.Compress);
    defer gpa.destroy(compress);
    compress.* = try flate.Compress.init(&compressed.writer, window, .zlib, .default);
    try compress.writer.writeAll(&raw);
    try compress.finish();

    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try file.appendSlice(gpa, signature);
    try writeChunk(gpa, &file, "IHDR", &.{ 0, 0, 0, 4, 0, 0, 0, 2, 2, 3, 0, 0, 0 });
    try writeChunk(gpa, &file, "PLTE", &.{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0 });
    try writeChunk(gpa, &file, "tRNS", &.{ 255, 255, 255, 0 });
    try writeChunk(gpa, &file, "IDAT", compressed.written());
    try writeChunk(gpa, &file, "IEND", "");

    var img = try decode(gpa, file.items);
    defer img.deinit(gpa);
    const red = Color.rgb(0xff0000).premultiplied();
    const green = Color.rgb(0x00ff00).premultiplied();
    const blue = Color.rgb(0x0000ff).premultiplied();
    // Row 1 is the byte 0b00_01_10_11 + 0b01_00_00_01 = 0b01_01_11_00:
    // green, green, transparent, red.
    try testing.expectEqualSlices(Rgba8, &.{ red, green, blue, .transparent, green, green, .transparent, red }, img.pixels);
}

test "rejects corrupt data" {
    try testing.expectError(error.InvalidPng, decode(testing.allocator, "not a png"));
    const gpa = testing.allocator;
    const bytes = try encode(gpa, 1, 1, &.{.transparent});
    defer gpa.free(bytes);
    bytes[20] ^= 1; // inside IHDR: CRC mismatch
    try testing.expectError(error.InvalidPng, decode(gpa, bytes));
}
