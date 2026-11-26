// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! A TrueType font reader: metrics, character mapping, kerning (GPOS pair
//! adjustments, or the legacy `kern` table) and glyph
//! outlines (the GSUB, GPOS and GDEF tables are applied by opentype.zig), read directly from the font file bytes (no copies, no
//! allocation except while decoding an outline). Handles `.ttf` files and
//! `.ttc` collections with TrueType (quadratic) outlines; CFF-based OpenType
//! fonts are not supported.
//!
//! Font data is untrusted: every read is bounds-checked, and malformed
//! fonts produce `error.InvalidFont` rather than undefined behavior.

const std = @import("std");
const bitmap_font = @import("bitmap_font.zig");
const Allocator = std.mem.Allocator;
const path = @import("../path.zig");
const Point = @import("../geometry.zig").Point;

pub const Error = error{ InvalidFont, UnsupportedFont };

/// Bounds-checked big-endian reads. Offsets are u64 so that arithmetic on
/// values from the file cannot overflow, even on 32-bit targets.
pub const Bytes = struct {
    data: []const u8,

    pub fn slice(b: Bytes, off: u64, len: u64) Error![]const u8 {
        if (off > b.data.len or len > b.data.len - off) return error.InvalidFont;
        return b.data[@intCast(off)..][0..@intCast(len)];
    }
    pub fn u8At(b: Bytes, off: u64) Error!u8 {
        return (try b.slice(off, 1))[0];
    }
    pub fn i8At(b: Bytes, off: u64) Error!i8 {
        return @bitCast(try b.u8At(off));
    }
    pub fn u16At(b: Bytes, off: u64) Error!u16 {
        return std.mem.readInt(u16, (try b.slice(off, 2))[0..2], .big);
    }
    pub fn i16At(b: Bytes, off: u64) Error!i16 {
        return @bitCast(try b.u16At(off));
    }
    pub fn u32At(b: Bytes, off: u64) Error!u32 {
        return std.mem.readInt(u32, (try b.slice(off, 4))[0..4], .big);
    }
    /// A 2.14 fixed-point number.
    pub fn f2dot14At(b: Bytes, off: u64) Error!f32 {
        return @as(f32, @floatFromInt(try b.i16At(off))) / 16384;
    }
};

pub const Table = struct { offset: u64, length: u64 };

pub fn tag(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

/// A glyph's bounding box in font units (y up).
pub const Box = struct {
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

pub const Font = struct {
    /// The font file; borrowed and must outlive the font.
    data: []const u8,
    units_per_em: u16,
    /// Distance from the baseline to the top of the line (positive).
    ascender: i16,
    /// Distance from the baseline to the bottom of the line (negative).
    descender: i16,
    line_gap: i16,
    num_glyphs: u16,

    num_hmetrics: u16,
    loca_long: bool,
    hmtx: Table,
    loca: Table,
    glyf: Table,
    cmap: struct { offset: u64, format: u16 },
    kern: ?struct { offset: u64, count: u16 },
    /// Pair-adjustment lookups of the GPOS `kern` feature, in lookup order.
    gpos_kern: ?GposKern,
    /// OpenType layout tables, for shaping (opentype.zig).
    gsub: ?Table = null,
    gpos: ?Table = null,
    gdef: ?Table = null,
    /// The height of lowercase letters in font units (0 if unknown).
    x_height: i16 = 0,
    /// Set for pre-rendered fonts (bitmap_font.zig): glyphs are images, not
    /// outlines.
    bitmap: ?bitmap_font.Tables = null,

    const max_kern_lookups = 16;

    const GposKern = struct {
        lookups: [max_kern_lookups]u64,
        count: u8,
    };

    /// Opens a TrueType font, or a pre-rendered one (bitmap_font.zig).
    pub fn init(data: []const u8) Error!Font {
        return initIndex(data, 0);
    }

    fn initBitmap(data: []const u8) Error!Font {
        const f = bitmap_font.open(data) catch return error.InvalidFont;
        const none: Table = .{ .offset = 0, .length = 0 };
        return .{
            .data = data,
            .units_per_em = f.units_per_em,
            .ascender = f.ascender,
            .descender = f.descender,
            .line_gap = f.line_gap,
            .num_glyphs = f.glyph_count,
            .num_hmetrics = 0,
            .loca_long = false,
            .hmtx = none,
            .loca = none,
            .glyf = none,
            .cmap = .{ .offset = 0, .format = 0 },
            .kern = null,
            .gpos_kern = null,
            .bitmap = f.tables,
        };
    }

    /// The pre-rendered image of `glyph` at `pixel_size` (the nearest size
    /// the font has); null for outline fonts.
    pub fn glyphImage(self: *const Font, glyph: u16, pixel_size: f32) ?bitmap_font.Image {
        const t = self.bitmap orelse return null;
        return bitmap_font.image(self.data, t, self.num_glyphs, glyph, pixel_size);
    }

    /// Opens font `index` of a `.ttc` collection (or 0 for a plain font).
    pub fn initIndex(data: []const u8, index: u32) Error!Font {
        if (bitmap_font.isBitmapFont(data)) return if (index == 0) initBitmap(data) else error.InvalidFont;
        const b: Bytes = .{ .data = data };
        var base: u64 = 0;
        if (try b.u32At(0) == tag("ttcf")) {
            if (index >= try b.u32At(8)) return error.InvalidFont;
            base = try b.u32At(12 + @as(u64, index) * 4);
        } else if (index != 0) return error.InvalidFont;

        const version = try b.u32At(base);
        if (version == tag("OTTO")) return error.UnsupportedFont;
        if (version != 0x00010000 and version != tag("true")) return error.InvalidFont;

        var head: ?Table = null;
        var hhea: ?Table = null;
        var maxp: ?Table = null;
        var cmap: ?Table = null;
        var hmtx: ?Table = null;
        var loca: ?Table = null;
        var glyf: ?Table = null;
        var kern: ?Table = null;
        var gpos: ?Table = null;
        var gsub: ?Table = null;
        var gdef: ?Table = null;
        var os2: ?Table = null;
        const num_tables = try b.u16At(base + 4);
        for (0..num_tables) |i| {
            const rec = base + 12 + @as(u64, i) * 16;
            const t: Table = .{ .offset = try b.u32At(rec + 8), .length = try b.u32At(rec + 12) };
            _ = try b.slice(t.offset, t.length);
            switch (try b.u32At(rec)) {
                tag("head") => head = t,
                tag("hhea") => hhea = t,
                tag("maxp") => maxp = t,
                tag("cmap") => cmap = t,
                tag("hmtx") => hmtx = t,
                tag("loca") => loca = t,
                tag("glyf") => glyf = t,
                tag("kern") => kern = t,
                tag("GPOS") => gpos = t,
                tag("GSUB") => gsub = t,
                tag("GDEF") => gdef = t,
                tag("OS/2") => os2 = t,
                else => {},
            }
        }
        if (glyf == null or loca == null) {
            return if (head != null and cmap != null) error.UnsupportedFont else error.InvalidFont;
        }
        const head_t = head orelse return error.InvalidFont;
        const hhea_t = hhea orelse return error.InvalidFont;
        const maxp_t = maxp orelse return error.InvalidFont;

        const units_per_em = try b.u16At(head_t.offset + 18);
        if (units_per_em < 16 or units_per_em > 16384) return error.InvalidFont;

        var font: Font = .{
            .data = data,
            .units_per_em = units_per_em,
            .ascender = try b.i16At(hhea_t.offset + 4),
            .descender = try b.i16At(hhea_t.offset + 6),
            .line_gap = try b.i16At(hhea_t.offset + 8),
            .num_hmetrics = try b.u16At(hhea_t.offset + 34),
            .num_glyphs = try b.u16At(maxp_t.offset + 4),
            .loca_long = try b.i16At(head_t.offset + 50) != 0,
            .hmtx = hmtx orelse return error.InvalidFont,
            .loca = loca.?,
            .glyf = glyf.?,
            .cmap = try findCmap(b, cmap orelse return error.InvalidFont),
            .kern = null,
            .gpos_kern = null,
            .gsub = gsub,
            .gpos = gpos,
            .gdef = gdef,
        };
        // The x-height: OS/2's (version 2 and later), else the top of "x".
        if (os2) |t| if (t.length >= 88 and (b.u16At(t.offset) catch 0) >= 2) {
            font.x_height = b.i16At(t.offset + 86) catch 0;
        };
        if (font.x_height <= 0) {
            if (font.glyphBox(font.glyphIndex('x'))) |box| font.x_height = box.y_max;
        }
        if (kern) |k| font.kern = findKernPairs(b, k) catch null;
        if (gpos) |g| font.gpos_kern = findGposKern(b, g) catch null;
        return font;
    }

    pub fn bytes(self: *const Font) Bytes {
        return .{ .data = self.data };
    }

    /// Pixels per font unit at a font size (the em height) in pixels.
    pub fn scale(self: *const Font, font_size: f32) f32 {
        return font_size / @as(f32, @floatFromInt(self.units_per_em));
    }

    /// Baseline-to-baseline distance in pixels.
    pub fn lineHeight(self: *const Font, font_size: f32) f32 {
        const units = @as(f32, @floatFromInt(self.ascender)) - @as(f32, @floatFromInt(self.descender)) + @as(f32, @floatFromInt(self.line_gap));
        return units * self.scale(font_size);
    }

    /// The glyph for a code point; 0 (the "missing glyph") if there is none.
    pub fn glyphIndex(self: *const Font, codepoint: u21) u16 {
        if (self.bitmap) |t| return bitmap_font.glyphIndex(self.data, t, codepoint);
        const g = self.lookupCmap(codepoint) catch 0;
        return if (g < self.num_glyphs) g else 0;
    }

    fn lookupCmap(self: *const Font, cp: u21) Error!u16 {
        const b = self.bytes();
        const sub = self.cmap.offset;
        switch (self.cmap.format) {
            4 => {
                if (cp > 0xffff) return 0;
                const seg_x2 = try b.u16At(sub + 6);
                const segs = seg_x2 / 2;
                const ends = sub + 14;
                const starts = ends + seg_x2 + 2;
                const deltas = starts + seg_x2;
                const ranges = deltas + seg_x2;
                var lo: u32 = 0;
                var hi: u32 = segs;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (try b.u16At(ends + mid * 2) < cp) lo = mid + 1 else hi = mid;
                }
                if (lo >= segs) return 0;
                const start = try b.u16At(starts + lo * 2);
                if (start > cp) return 0;
                const delta = try b.u16At(deltas + lo * 2);
                const range = try b.u16At(ranges + lo * 2);
                if (range == 0) return @truncate(@as(u32, cp) +% delta);
                const g = try b.u16At(ranges + lo * 2 + range + (@as(u64, cp) - start) * 2);
                return if (g == 0) 0 else @truncate(@as(u32, g) +% delta);
            },
            12 => {
                const groups = try b.u32At(sub + 12);
                var lo: u64 = 0;
                var hi: u64 = groups;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    const g = sub + 16 + mid * 12;
                    if (try b.u32At(g + 4) < cp) {
                        lo = mid + 1;
                    } else if (try b.u32At(g) > cp) {
                        hi = mid;
                    } else {
                        const glyph = @as(u64, try b.u32At(g + 8)) + (cp - try b.u32At(g));
                        return if (glyph > 0xffff) 0 else @intCast(glyph);
                    }
                }
                return 0;
            },
            else => return 0,
        }
    }

    /// Horizontal advance in font units.
    pub fn advanceWidth(self: *const Font, glyph: u16) u16 {
        if (self.bitmap) |t| return bitmap_font.advanceWidth(self.data, t, self.num_glyphs, glyph);
        if (self.num_hmetrics == 0) return 0;
        const i = @min(glyph, self.num_hmetrics - 1);
        return self.bytes().u16At(self.hmtx.offset + @as(u64, i) * 4) catch 0;
    }

    /// Kerning adjustment between two glyphs in font units: from the GPOS
    /// `kern` feature if the font has one, else from the `kern` table.
    pub fn kerning(self: *const Font, left: u16, right: u16) i16 {
        if (self.bitmap) |t| return bitmap_font.kerning(self.data, t, left, right);
        if (self.gpos_kern) |gk| {
            var total: i32 = 0;
            for (gk.lookups[0..gk.count]) |lookup| total += gposPairAdjustment(self.bytes(), lookup, left, right) catch 0;
            return @intCast(std.math.clamp(total, std.math.minInt(i16), std.math.maxInt(i16)));
        }
        const k = self.kern orelse return 0;
        const key = (@as(u32, left) << 16) | right;
        var lo: u64 = 0;
        var hi: u64 = k.count;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const pair = k.offset + mid * 6;
            const v = self.bytes().u32At(pair) catch return 0;
            if (v < key) lo = mid + 1 else if (v > key) hi = mid else return self.bytes().i16At(pair + 4) catch 0;
        }
        return 0;
    }

    /// The glyph's data in the `glyf` table; null for empty glyphs (space).
    fn glyphData(self: *const Font, glyph: u16) Error!?Bytes {
        if (glyph >= self.num_glyphs or self.bitmap != null) return error.InvalidFont;
        const b = self.bytes();
        const start: u64, const end: u64 = if (self.loca_long) .{
            try b.u32At(self.loca.offset + @as(u64, glyph) * 4),
            try b.u32At(self.loca.offset + @as(u64, glyph) * 4 + 4),
        } else .{
            @as(u64, try b.u16At(self.loca.offset + @as(u64, glyph) * 2)) * 2,
            @as(u64, try b.u16At(self.loca.offset + @as(u64, glyph) * 2 + 2)) * 2,
        };
        if (end <= start) return null;
        if (end > self.glyf.length) return error.InvalidFont;
        return .{ .data = try b.slice(self.glyf.offset + start, end - start) };
    }

    /// Bounding box in font units, or null for an empty glyph.
    pub fn glyphBox(self: *const Font, glyph: u16) ?Box {
        const g = (self.glyphData(glyph) catch return null) orelse return null;
        const box: Box = .{
            .x_min = g.i16At(2) catch return null,
            .y_min = g.i16At(4) catch return null,
            .x_max = g.i16At(6) catch return null,
            .y_max = g.i16At(8) catch return null,
        };
        if (box.x_max < box.x_min or box.y_max < box.y_min) return null;
        return box;
    }

    /// Appends the glyph's outline to `out` in font units (y up), as closed
    /// contours of lines and quadratic curves.
    pub fn glyphOutline(self: *const Font, gpa: Allocator, glyph: u16, out: *std.ArrayList(path.Command)) (Error || Allocator.Error)!void {
        try self.appendGlyph(gpa, glyph, .{}, out, 0);
    }

    fn appendGlyph(self: *const Font, gpa: Allocator, glyph: u16, transform: Affine, out: *std.ArrayList(path.Command), depth: u8) (Error || Allocator.Error)!void {
        if (depth > 8) return error.InvalidFont;
        const g = (try self.glyphData(glyph)) orelse return;
        const contours = try g.i16At(0);
        if (contours >= 0) {
            try appendSimpleGlyph(gpa, g, @intCast(contours), transform, out);
            return;
        }
        // Composite glyph: transformed references to other glyphs.
        var off: u64 = 10;
        while (true) {
            const flags = try g.u16At(off);
            const component = try g.u16At(off + 2);
            off += 4;
            var dx: f32 = 0;
            var dy: f32 = 0;
            if (flags & 0x0001 != 0) { // ARG_1_AND_2_ARE_WORDS
                if (flags & 0x0002 != 0) {
                    dx = @floatFromInt(try g.i16At(off));
                    dy = @floatFromInt(try g.i16At(off + 2));
                }
                off += 4;
            } else {
                if (flags & 0x0002 != 0) {
                    dx = @floatFromInt(try g.i8At(off));
                    dy = @floatFromInt(try g.i8At(off + 1));
                }
                off += 2;
            }
            // (Point-matched placement, without ARGS_ARE_XY_VALUES, is
            // treated as no offset.)
            var m: Affine = .{ .e = dx, .f = dy };
            if (flags & 0x0008 != 0) { // WE_HAVE_A_SCALE
                m.a = try g.f2dot14At(off);
                m.d = m.a;
                off += 2;
            } else if (flags & 0x0040 != 0) { // WE_HAVE_AN_X_AND_Y_SCALE
                m.a = try g.f2dot14At(off);
                m.d = try g.f2dot14At(off + 2);
                off += 4;
            } else if (flags & 0x0080 != 0) { // WE_HAVE_A_TWO_BY_TWO
                m.a = try g.f2dot14At(off);
                m.b = try g.f2dot14At(off + 2);
                m.c = try g.f2dot14At(off + 4);
                m.d = try g.f2dot14At(off + 6);
                off += 8;
            }
            try self.appendGlyph(gpa, component, transform.compose(m), out, depth + 1);
            if (flags & 0x0020 == 0) break; // MORE_COMPONENTS
        }
    }
};

/// x' = a x + c y + e, y' = b x + d y + f
const Affine = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    fn apply(t: Affine, x: f32, y: f32) Point {
        return .{ .x = t.a * x + t.c * y + t.e, .y = t.b * x + t.d * y + t.f };
    }

    /// `t` applied after `inner`.
    fn compose(t: Affine, inner: Affine) Affine {
        return .{
            .a = t.a * inner.a + t.c * inner.b,
            .b = t.b * inner.a + t.d * inner.b,
            .c = t.a * inner.c + t.c * inner.d,
            .d = t.b * inner.c + t.d * inner.d,
            .e = t.a * inner.e + t.c * inner.f + t.e,
            .f = t.b * inner.e + t.d * inner.f + t.f,
        };
    }
};

const GlyphPoint = struct { x: f32, y: f32, on: bool };

fn appendSimpleGlyph(gpa: Allocator, g: Bytes, contours: u16, transform: Affine, out: *std.ArrayList(path.Command)) (Error || Allocator.Error)!void {
    if (contours == 0) return;
    const ends_off: u64 = 10;
    const num_points = @as(u32, try g.u16At(ends_off + (@as(u64, contours) - 1) * 2)) + 1;
    const instructions = try g.u16At(ends_off + @as(u64, contours) * 2);
    var off = ends_off + @as(u64, contours) * 2 + 2 + instructions;

    const points = try gpa.alloc(GlyphPoint, num_points);
    defer gpa.free(points);
    const flags = try gpa.alloc(u8, num_points);
    defer gpa.free(flags);

    var i: u32 = 0;
    while (i < num_points) {
        const f = try g.u8At(off);
        off += 1;
        flags[i] = f;
        i += 1;
        if (f & 0x08 != 0) { // REPEAT_FLAG
            const repeat = try g.u8At(off);
            off += 1;
            for (0..repeat) |_| {
                if (i >= num_points) return error.InvalidFont;
                flags[i] = f;
                i += 1;
            }
        }
    }
    var x: i32 = 0;
    for (flags, points) |f, *p| {
        if (f & 0x02 != 0) { // X_SHORT_VECTOR
            const dx: i32 = try g.u8At(off);
            off += 1;
            x += if (f & 0x10 != 0) dx else -dx;
        } else if (f & 0x10 == 0) {
            x += try g.i16At(off);
            off += 2;
        }
        p.x = @floatFromInt(x);
        p.on = f & 0x01 != 0;
    }
    var y: i32 = 0;
    for (flags, points) |f, *p| {
        if (f & 0x04 != 0) { // Y_SHORT_VECTOR
            const dy: i32 = try g.u8At(off);
            off += 1;
            y += if (f & 0x20 != 0) dy else -dy;
        } else if (f & 0x20 == 0) {
            y += try g.i16At(off);
            off += 2;
        }
        p.y = @floatFromInt(y);
    }

    var start: u32 = 0;
    for (0..contours) |c| {
        const end = @as(u32, try g.u16At(ends_off + c * 2)) + 1;
        if (end <= start or end > num_points) return error.InvalidFont;
        try appendContour(gpa, points[start..end], transform, out);
        start = end;
    }
}

/// Converts one contour (on-curve points and quadratic control points, with
/// implied on-curve midpoints between consecutive controls) to commands.
fn appendContour(gpa: Allocator, pts: []const GlyphPoint, t: Affine, out: *std.ArrayList(path.Command)) Allocator.Error!void {
    const n = pts.len;
    if (n == 0) return;
    const P = struct {
        fn of(p: GlyphPoint) Point {
            return .{ .x = p.x, .y = p.y };
        }
        fn mid(a: Point, b: Point) Point {
            return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
        }
    };
    // Start on an on-curve point if there is one, else between the first
    // two control points. `first` is the index processed first after it.
    var start: Point = undefined;
    var first: usize = 0;
    var count: usize = n;
    if (for (pts, 0..) |p, i| {
        if (p.on) break i;
    } else null) |i| {
        start = P.of(pts[i]);
        first = (i + 1) % n;
        count = n - 1;
    } else {
        start = P.mid(P.of(pts[0]), P.of(pts[n - 1]));
    }

    try out.append(gpa, .{ .move_to = t.apply(start.x, start.y) });
    var control: ?Point = null;
    for (0..count) |k| {
        const p = pts[(first + k) % n];
        const pt = P.of(p);
        if (p.on) {
            if (control) |c| {
                try out.append(gpa, .{ .quad_to = .{ .c = t.apply(c.x, c.y), .p = t.apply(pt.x, pt.y) } });
            } else {
                try out.append(gpa, .{ .line_to = t.apply(pt.x, pt.y) });
            }
            control = null;
        } else {
            if (control) |c| {
                const m = P.mid(c, pt);
                try out.append(gpa, .{ .quad_to = .{ .c = t.apply(c.x, c.y), .p = t.apply(m.x, m.y) } });
            }
            control = pt;
        }
    }
    if (control) |c| try out.append(gpa, .{ .quad_to = .{ .c = t.apply(c.x, c.y), .p = t.apply(start.x, start.y) } });
    try out.append(gpa, .close);
}

/// Picks the best Unicode subtable of `cmap`.
fn findCmap(b: Bytes, cmap: Table) Error!@FieldType(Font, "cmap") {
    const num = try b.u16At(cmap.offset + 2);
    var best: ?@FieldType(Font, "cmap") = null;
    var best_score: u8 = 0;
    for (0..num) |i| {
        const rec = cmap.offset + 4 + @as(u64, i) * 8;
        const platform = try b.u16At(rec);
        const encoding = try b.u16At(rec + 2);
        const sub = cmap.offset + try b.u32At(rec + 4);
        const format = b.u16At(sub) catch continue;
        const score: u8 = switch (format) {
            12 => if ((platform == 3 and encoding == 10) or platform == 0) 5 else 0,
            4 => if (platform == 3 and encoding == 1) 4 else if (platform == 0) 3 else if (platform == 3 and encoding == 0) 2 else 0,
            else => 0,
        };
        if (score > best_score) {
            best_score = score;
            best = .{ .offset = sub, .format = format };
        }
    }
    return best orelse error.UnsupportedFont;
}

/// The sorted pair list of the first horizontal format 0 `kern` subtable.
fn findKernPairs(b: Bytes, kern: Table) Error!@FieldType(Font, "kern") {
    if (try b.u16At(kern.offset) != 0) return null; // Apple's version 1 layout
    const tables = try b.u16At(kern.offset + 2);
    var sub = kern.offset + 4;
    for (0..tables) |_| {
        const length = try b.u16At(sub + 2);
        const coverage = try b.u16At(sub + 4);
        // Format 0, horizontal, not minimum values, not cross-stream.
        if (coverage >> 8 == 0 and coverage & 0x7 == 0x1) {
            const count = try b.u16At(sub + 6);
            _ = try b.slice(sub + 14, @as(u64, count) * 6);
            return .{ .offset = sub + 14, .count = count };
        }
        sub += length;
    }
    return null;
}

// ---- GPOS kerning ----

/// Finds the lookups of the `kern` feature for Latin (or the default
/// script), or of every `kern` feature if the font has neither.
fn findGposKern(b: Bytes, gpos: Table) Error!?Font.GposKern {
    const g = gpos.offset;
    if (try b.u16At(g) != 1) return null;
    const script_list = g + try b.u16At(g + 4);
    const feature_list = g + try b.u16At(g + 6);
    const lookup_list = g + try b.u16At(g + 8);

    // The default language system of the preferred script.
    var lang_sys: ?u64 = null;
    var best: u8 = 0;
    const scripts = try b.u16At(script_list);
    for (0..scripts) |i| {
        const rec = script_list + 2 + @as(u64, i) * 6;
        const score: u8 = switch (try b.u32At(rec)) {
            tag("latn") => 2,
            tag("DFLT") => 1,
            else => 0,
        };
        if (score <= best) continue;
        const script = script_list + try b.u16At(rec + 4);
        const default_lang = try b.u16At(script);
        if (default_lang == 0) continue;
        lang_sys = script + default_lang;
        best = score;
    }

    var indices: [Font.max_kern_lookups]u16 = undefined;
    var count: usize = 0;
    const features = try b.u16At(feature_list);
    const Collect = struct {
        fn feature(bb: Bytes, list: u64, n: u16, index: u16, out: *[Font.max_kern_lookups]u16, len: *usize) Error!void {
            if (index >= n) return;
            const rec = list + 2 + @as(u64, index) * 6;
            if (try bb.u32At(rec) != tag("kern")) return;
            const feat = list + try bb.u16At(rec + 4);
            const lookups = try bb.u16At(feat + 2);
            for (0..lookups) |k| {
                const li = try bb.u16At(feat + 4 + @as(u64, k) * 2);
                if (std.mem.indexOfScalar(u16, out[0..len.*], li) != null) continue;
                if (len.* == out.len) return;
                out[len.*] = li;
                len.* += 1;
            }
        }
    };
    if (lang_sys) |ls| {
        const required = try b.u16At(ls + 2);
        if (required != 0xffff) try Collect.feature(b, feature_list, features, required, &indices, &count);
        const n = try b.u16At(ls + 4);
        for (0..n) |k| try Collect.feature(b, feature_list, features, try b.u16At(ls + 6 + @as(u64, k) * 2), &indices, &count);
    } else {
        for (0..features) |fi| try Collect.feature(b, feature_list, features, @intCast(fi), &indices, &count);
    }
    if (count == 0) return null;

    // Lookups apply in lookup-list order.
    std.mem.sort(u16, indices[0..count], {}, std.sort.asc(u16));
    var result: Font.GposKern = .{ .lookups = undefined, .count = 0 };
    const lookup_count = try b.u16At(lookup_list);
    for (indices[0..count]) |li| {
        if (li >= lookup_count) continue;
        result.lookups[result.count] = lookup_list + try b.u16At(lookup_list + 2 + @as(u64, li) * 2);
        result.count += 1;
    }
    return if (result.count > 0) result else null;
}

/// The x-advance adjustment a lookup gives the pair, from the first of its
/// pair-positioning subtables (types 2, or 9 wrapping 2) that matches.
fn gposPairAdjustment(b: Bytes, lookup: u64, left: u16, right: u16) Error!i32 {
    const kind = try b.u16At(lookup);
    const subtables = try b.u16At(lookup + 4);
    for (0..subtables) |i| {
        var sub = lookup + try b.u16At(lookup + 6 + @as(u64, i) * 2);
        var sub_kind = kind;
        if (kind == 9) { // extension: format, extension type, 32-bit offset
            sub_kind = try b.u16At(sub + 2);
            sub += try b.u32At(sub + 4);
        }
        if (sub_kind != 2) continue;
        if (try pairPosAdjustment(b, sub, left, right)) |v| return v;
    }
    return 0;
}

fn valueRecordSize(format: u16) u64 {
    return @as(u64, @popCount(format & 0xff)) * 2;
}

/// The XAdvance of a value record, if its format has one.
fn valueXAdvance(b: Bytes, record: u64, format: u16) Error!i32 {
    if (format & 0x0004 == 0) return 0;
    return try b.i16At(record + valueRecordSize(format & 0x0003));
}

/// Null if the subtable does not cover the pair.
fn pairPosAdjustment(b: Bytes, sub: u64, left: u16, right: u16) Error!?i32 {
    const format = try b.u16At(sub);
    const coverage = sub + try b.u16At(sub + 2);
    const vf1 = try b.u16At(sub + 4);
    const vf2 = try b.u16At(sub + 6);
    const index = (try coverageIndex(b, coverage, left)) orelse return null;
    const size1 = valueRecordSize(vf1);
    const size2 = valueRecordSize(vf2);
    switch (format) {
        1 => {
            // Pair sets: for each first glyph, records sorted by second glyph.
            if (index >= try b.u16At(sub + 8)) return error.InvalidFont;
            const set = sub + try b.u16At(sub + 10 + @as(u64, index) * 2);
            const record_size = 2 + size1 + size2;
            var lo: u64 = 0;
            var hi: u64 = try b.u16At(set);
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const rec = set + 2 + mid * record_size;
                const second = try b.u16At(rec);
                if (second < right) lo = mid + 1 else if (second > right) hi = mid else return try valueXAdvance(b, rec + 2, vf1);
            }
            return null;
        },
        2 => {
            // A class1 x class2 matrix of value record pairs.
            const class1 = try classOf(b, sub + try b.u16At(sub + 8), left);
            const class2 = try classOf(b, sub + try b.u16At(sub + 10), right);
            const class1_count = try b.u16At(sub + 12);
            const class2_count = try b.u16At(sub + 14);
            if (class1 >= class1_count or class2 >= class2_count) return error.InvalidFont;
            const rec = sub + 16 + (@as(u64, class1) * class2_count + class2) * (size1 + size2);
            return try valueXAdvance(b, rec, vf1);
        },
        else => return null,
    }
}

/// The glyph's index in a coverage table, or null if not covered.
pub fn coverageIndex(b: Bytes, coverage: u64, glyph: u16) Error!?u16 {
    const format = try b.u16At(coverage);
    const n = try b.u16At(coverage + 2);
    var lo: u64 = 0;
    var hi: u64 = n;
    switch (format) {
        1 => while (lo < hi) {
            const mid = (lo + hi) / 2;
            const g = try b.u16At(coverage + 4 + mid * 2);
            if (g < glyph) lo = mid + 1 else if (g > glyph) hi = mid else return @intCast(mid);
        },
        2 => while (lo < hi) {
            const mid = (lo + hi) / 2;
            const rec = coverage + 4 + mid * 6;
            if (try b.u16At(rec + 2) < glyph) {
                lo = mid + 1;
            } else if (try b.u16At(rec) > glyph) {
                hi = mid;
            } else {
                const index = @as(u32, try b.u16At(rec + 4)) + (glyph - try b.u16At(rec));
                return if (index > 0xffff) error.InvalidFont else @intCast(index);
            }
        },
        else => return error.InvalidFont,
    }
    return null;
}

/// The glyph's class in a class definition table (0 if unlisted).
pub fn classOf(b: Bytes, class_def: u64, glyph: u16) Error!u16 {
    switch (try b.u16At(class_def)) {
        1 => {
            const start = try b.u16At(class_def + 2);
            const n = try b.u16At(class_def + 4);
            if (glyph < start or glyph - start >= n) return 0;
            return try b.u16At(class_def + 6 + @as(u64, glyph - start) * 2);
        },
        2 => {
            var lo: u64 = 0;
            var hi: u64 = try b.u16At(class_def + 2);
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const rec = class_def + 4 + mid * 6;
                if (try b.u16At(rec + 2) < glyph) {
                    lo = mid + 1;
                } else if (try b.u16At(rec) > glyph) {
                    hi = mid;
                } else return try b.u16At(rec + 4);
            }
            return 0;
        },
        else => return error.InvalidFont,
    }
}
