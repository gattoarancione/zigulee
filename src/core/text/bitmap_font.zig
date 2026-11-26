// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Pre-rendered fonts for microcontrollers: the glyph images of a TrueType
//! font at a few pixel sizes, for a chosen set of characters, made at build
//! time (`zigulee.bitmapFont` in build.zig). `Font.init` opens them like a
//! TrueType file, and they are read in place: from flash, with
//! `@embedFile`.
//!
//! Advances and kerning are kept in the original font's units, so text is
//! laid out exactly as with the TrueType font. Each size ("strike") has its
//! own images, 4 bits per pixel; text at a size without a strike uses the
//! nearest one's images.
//!
//! Layout (little-endian):
//!
//!     header      32 bytes (see `Header`)
//!     ranges      range_count x { first_codepoint: u32, count: u32, first_glyph: u32 }
//!     advances    glyph_count x u16, padded to 4 bytes
//!     kerning     kern_count x { left: u16, right: u16, value: i16, pad: u16 }, sorted
//!     strikes     strike_count x { pixel_size: u16, pad: u16, glyphs: u32 (offset) }
//!     glyphs      per strike, glyph_count x { image: u32, width: u8, height: u8, left: i8, top: i8 }
//!     images      rows of 4-bit coverage, two pixels per byte, high nibble first

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const magic = "ZBF1";

const Header = extern struct {
    magic: [4]u8,
    units_per_em: u16,
    ascender: i16,
    descender: i16,
    line_gap: i16,
    glyph_count: u16,
    strike_count: u16,
    range_count: u32,
    kern_count: u32,
    images: u32,
    reserved: u32,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 32);
}

/// Where the tables of an opened font are.
pub const Tables = struct {
    ranges: u32,
    range_count: u32,
    advances: u32,
    kerning: u32,
    kern_count: u32,
    strikes: u32,
    strike_count: u16,
    images: u32,
};

pub const Error = error{InvalidFont};

pub fn isBitmapFont(data: []const u8) bool {
    return data.len >= 4 and std.mem.eql(u8, data[0..4], magic);
}

pub const Opened = struct {
    tables: Tables,
    units_per_em: u16,
    ascender: i16,
    descender: i16,
    line_gap: i16,
    glyph_count: u16,
};

fn u16At(data: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, data[at..][0..2], .little);
}

fn u32At(data: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, data[at..][0..4], .little);
}

/// Checks the tables fit in `data`.
pub fn open(data: []const u8) Error!Opened {
    if (data.len < @sizeOf(Header) or !isBitmapFont(data)) return error.InvalidFont;
    const glyph_count = u16At(data, 12);
    const strike_count = u16At(data, 14);
    const range_count = u32At(data, 16);
    const kern_count = u32At(data, 20);
    const images = u32At(data, 24);
    const units_per_em = u16At(data, 4);
    if (units_per_em < 16 or glyph_count == 0 or strike_count == 0) return error.InvalidFont;

    var at: u64 = @sizeOf(Header);
    const range_table = at;
    at += @as(u64, range_count) * 12;
    const advance_table = at;
    at += std.mem.alignForward(u64, @as(u64, glyph_count) * 2, 4);
    const kerns = at;
    at += @as(u64, kern_count) * 8;
    const strike_table = at;
    at += @as(u64, strike_count) * 8;
    if (at > data.len or images > data.len) return error.InvalidFont;
    for (0..strike_count) |s| {
        const glyphs = u32At(data, @intCast(strike_table + s * 8 + 4));
        if (@as(u64, glyphs) + @as(u64, glyph_count) * 8 > data.len) return error.InvalidFont;
        for (0..glyph_count) |g| {
            const rec = glyphs + g * 8;
            const w: u64 = data[rec + 4];
            const h: u64 = data[rec + 5];
            if (images + @as(u64, u32At(data, rec)) + (w + 1) / 2 * h > data.len) return error.InvalidFont;
        }
    }
    for (0..range_count) |r| {
        const rec: usize = @intCast(range_table + r * 12);
        if (@as(u64, u32At(data, rec + 8)) + u32At(data, rec + 4) > glyph_count) return error.InvalidFont;
    }
    return .{
        .tables = .{
            .ranges = @intCast(range_table),
            .range_count = range_count,
            .advances = @intCast(advance_table),
            .kerning = @intCast(kerns),
            .kern_count = kern_count,
            .strikes = @intCast(strike_table),
            .strike_count = strike_count,
            .images = images,
        },
        .units_per_em = units_per_em,
        .ascender = @bitCast(u16At(data, 6)),
        .descender = @bitCast(u16At(data, 8)),
        .line_gap = @bitCast(u16At(data, 10)),
        .glyph_count = glyph_count,
    };
}

pub fn glyphIndex(data: []const u8, t: Tables, cp: u21) u16 {
    // Ranges are sorted: binary search.
    var lo: u32 = 0;
    var hi: u32 = t.range_count;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const rec = t.ranges + mid * 12;
        const first = u32At(data, rec);
        if (cp < first) {
            hi = mid;
        } else if (cp >= first + u32At(data, rec + 4)) {
            lo = mid + 1;
        } else return @intCast(u32At(data, rec + 8) + (cp - first));
    }
    return 0;
}

pub fn advanceWidth(data: []const u8, t: Tables, glyph_count: u16, glyph: u16) u16 {
    if (glyph >= glyph_count) return 0;
    return u16At(data, t.advances + @as(usize, glyph) * 2);
}

pub fn kerning(data: []const u8, t: Tables, left: u16, right: u16) i16 {
    const key = (@as(u32, left) << 16) | right;
    var lo: u32 = 0;
    var hi: u32 = t.kern_count;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const rec = t.kerning + mid * 8;
        const k = (@as(u32, u16At(data, rec)) << 16) | u16At(data, rec + 2);
        if (k < key) lo = mid + 1 else if (k > key) hi = mid else return @bitCast(u16At(data, rec + 4));
    }
    return 0;
}

/// A glyph's image: `height` rows of `stride` bytes, two 4-bit pixels per
/// byte (high nibble first). `left` and `top` place it relative to the pen
/// on the baseline (y down).
pub const Image = struct {
    width: u8,
    height: u8,
    left: i8,
    top: i8,
    pixels: []const u8,

    pub fn stride(i: Image) usize {
        return (@as(usize, i.width) + 1) / 2;
    }

    /// Coverage 0..255 of pixel (x, y).
    pub fn coverage(i: Image, x: usize, y: usize) u8 {
        const b = i.pixels[y * i.stride() + x / 2];
        const nibble = if (x % 2 == 0) b >> 4 else b & 0xf;
        return nibble * 17;
    }
};

/// The image of `glyph` in the strike closest to `pixel_size`.
pub fn image(data: []const u8, t: Tables, glyph_count: u16, glyph: u16, pixel_size: f32) ?Image {
    if (glyph >= glyph_count) return null;
    var best: usize = 0;
    var best_diff: f32 = std.math.inf(f32);
    for (0..t.strike_count) |s| {
        const size: f32 = @floatFromInt(u16At(data, t.strikes + s * 8));
        const diff = @abs(size - pixel_size);
        if (diff < best_diff) {
            best = s;
            best_diff = diff;
        }
    }
    const glyphs = u32At(data, t.strikes + best * 8 + 4);
    const rec = glyphs + @as(usize, glyph) * 8;
    const img: Image = .{
        .width = data[rec + 4],
        .height = data[rec + 5],
        .left = @bitCast(data[rec + 6]),
        .top = @bitCast(data[rec + 7]),
        .pixels = &.{},
    };
    var out = img;
    out.pixels = data[t.images + u32At(data, rec) ..][0 .. img.stride() * img.height];
    return out;
}

// ---- Making them ----

/// What `encode` writes.
pub const Spec = struct {
    units_per_em: u16,
    ascender: i16,
    descender: i16,
    line_gap: i16,
    /// The characters, sorted; glyph i + 1 shows `codepoints[i]` (glyph 0 is
    /// the missing glyph).
    codepoints: []const u21,
    /// Of every glyph, the missing glyph first.
    advances: []const u16,
    kerning: []const Kern = &.{},
    strikes: []const Strike,

    pub const Kern = struct { left: u16, right: u16, value: i16 };

    pub const Strike = struct {
        pixel_size: u16,
        /// One per glyph: 8-bit coverage, `width` x `height`.
        glyphs: []const GlyphImage,
    };

    pub const GlyphImage = struct {
        width: u8 = 0,
        height: u8 = 0,
        left: i8 = 0,
        top: i8 = 0,
        coverage: []const u8 = &.{},
    };
};

/// The font file for `spec` (allocated with `gpa`).
pub fn encode(gpa: Allocator, spec: Spec) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const w = struct {
        fn int(list: *std.ArrayList(u8), a: Allocator, comptime T: type, v: T) Allocator.Error!void {
            var b: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &b, v, .little);
            try list.appendSlice(a, &b);
        }
    }.int;

    // Ranges of consecutive code points.
    var ranges: std.ArrayList([3]u32) = .empty;
    defer ranges.deinit(gpa);
    for (spec.codepoints, 1..) |cp, glyph| {
        if (ranges.items.len > 0) {
            const last = &ranges.items[ranges.items.len - 1];
            if (last[0] + last[1] == cp) {
                last[1] += 1;
                continue;
            }
        }
        try ranges.append(gpa, .{ cp, 1, @intCast(glyph) });
    }
    const glyph_count: u16 = @intCast(spec.advances.len);
    const strikes_at = @sizeOf(Header) + ranges.items.len * 12 + std.mem.alignForward(usize, spec.advances.len * 2, 4) + spec.kerning.len * 8;
    const glyphs_at = strikes_at + spec.strikes.len * 8;
    const images_at = glyphs_at + spec.strikes.len * @as(usize, glyph_count) * 8;

    try out.appendSlice(gpa, magic);
    try w(&out, gpa, u16, spec.units_per_em);
    try w(&out, gpa, i16, spec.ascender);
    try w(&out, gpa, i16, spec.descender);
    try w(&out, gpa, i16, spec.line_gap);
    try w(&out, gpa, u16, glyph_count);
    try w(&out, gpa, u16, @intCast(spec.strikes.len));
    try w(&out, gpa, u32, @intCast(ranges.items.len));
    try w(&out, gpa, u32, @intCast(spec.kerning.len));
    try w(&out, gpa, u32, @intCast(images_at));
    try w(&out, gpa, u32, 0);
    for (ranges.items) |r| for (r) |v| try w(&out, gpa, u32, v);
    for (spec.advances) |a| try w(&out, gpa, u16, a);
    while (out.items.len % 4 != 0) try out.append(gpa, 0);
    const kerns = try gpa.dupe(Spec.Kern, spec.kerning);
    defer gpa.free(kerns);
    std.mem.sort(Spec.Kern, kerns, {}, struct {
        fn lt(_: void, a: Spec.Kern, b: Spec.Kern) bool {
            return (@as(u32, a.left) << 16 | a.right) < (@as(u32, b.left) << 16 | b.right);
        }
    }.lt);
    for (kerns) |k| {
        try w(&out, gpa, u16, k.left);
        try w(&out, gpa, u16, k.right);
        try w(&out, gpa, i16, k.value);
        try w(&out, gpa, u16, 0);
    }
    std.debug.assert(out.items.len == strikes_at);
    for (spec.strikes, 0..) |s, i| {
        try w(&out, gpa, u16, s.pixel_size);
        try w(&out, gpa, u16, 0);
        try w(&out, gpa, u32, @intCast(glyphs_at + i * @as(usize, glyph_count) * 8));
    }
    // Glyph records, then the images they point at.
    var images: std.ArrayList(u8) = .empty;
    defer images.deinit(gpa);
    for (spec.strikes) |s| {
        std.debug.assert(s.glyphs.len == glyph_count);
        for (s.glyphs) |g| {
            try w(&out, gpa, u32, @intCast(images.items.len));
            try out.appendSlice(gpa, &.{ g.width, g.height, @bitCast(g.left), @bitCast(g.top) });
            const stride = (@as(usize, g.width) + 1) / 2;
            for (0..g.height) |y| for (0..stride) |bx| {
                const x = bx * 2;
                const hi = quantize(g.coverage[y * g.width + x]);
                const lo = if (x + 1 < g.width) quantize(g.coverage[y * g.width + x + 1]) else 0;
                try images.append(gpa, hi << 4 | lo);
            };
        }
    }
    std.debug.assert(out.items.len == images_at);
    try out.appendSlice(gpa, images.items);
    return out.toOwnedSlice(gpa);
}

fn quantize(coverage: u8) u8 {
    return @intCast((@as(u16, coverage) * 15 + 127) / 255);
}

test "encode, open and read back" {
    const gpa = std.testing.allocator;
    const cov = [_]u8{ 0, 255, 128, 255, 0, 17 }; // 3 x 2
    const glyph: Spec.GlyphImage = .{ .width = 3, .height = 2, .left = 1, .top = -2, .coverage = &cov };
    const data = try encode(gpa, .{
        .units_per_em = 1000,
        .ascender = 800,
        .descender = -200,
        .line_gap = 0,
        .codepoints = &.{ 'A', 'B', 'C', 0x2026 },
        .advances = &.{ 500, 600, 610, 620, 900 },
        .kerning = &.{ .{ .left = 2, .right = 1, .value = -40 }, .{ .left = 1, .right = 2, .value = -20 } },
        .strikes = &.{
            .{ .pixel_size = 10, .glyphs = &.{ .{}, glyph, .{}, .{}, .{} } },
            .{ .pixel_size = 20, .glyphs = &.{ .{}, .{}, glyph, .{}, .{} } },
        },
    });
    defer gpa.free(data);
    const f = try open(data);
    try std.testing.expectEqual(@as(u16, 5), f.glyph_count);
    try std.testing.expectEqual(@as(u16, 1), glyphIndex(data, f.tables, 'A'));
    try std.testing.expectEqual(@as(u16, 3), glyphIndex(data, f.tables, 'C'));
    try std.testing.expectEqual(@as(u16, 4), glyphIndex(data, f.tables, 0x2026));
    try std.testing.expectEqual(@as(u16, 0), glyphIndex(data, f.tables, 'D'));
    try std.testing.expectEqual(@as(u16, 610), advanceWidth(data, f.tables, f.glyph_count, 2));
    try std.testing.expectEqual(@as(i16, -20), kerning(data, f.tables, 1, 2));
    try std.testing.expectEqual(@as(i16, -40), kerning(data, f.tables, 2, 1));
    try std.testing.expectEqual(@as(i16, 0), kerning(data, f.tables, 1, 3));
    // The nearest strike: 12 px is closer to 10.
    const img = image(data, f.tables, f.glyph_count, 1, 12).?;
    try std.testing.expectEqual(@as(u8, 3), img.width);
    try std.testing.expectEqual(@as(i8, -2), img.top);
    try std.testing.expectEqual(@as(u8, 255), img.coverage(1, 0));
    try std.testing.expectEqual(@as(u8, 0), img.coverage(0, 0));
    try std.testing.expectEqual(@as(u8, 136), img.coverage(2, 0)); // 128 to 4 bits
    try std.testing.expectEqual(@as(u8, 17), img.coverage(2, 1));
    try std.testing.expectEqual(@as(u8, 0), image(data, f.tables, f.glyph_count, 1, 19).?.width);
    // Damaged files are rejected.
    try std.testing.expectError(error.InvalidFont, open(data[0 .. data.len - 1]));
}
