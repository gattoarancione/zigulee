// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Builds small TrueType fonts in memory, for tests that must not depend on
//! font files. `standard` is a geometric test font; `build` assembles any
//! set of glyphs.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pt = struct {
    x: i16,
    y: i16,
    on: bool = true,
};

pub const Component = struct {
    glyph: u16,
    dx: i16,
    dy: i16,
    /// Uniform scale (written as 2.14 fixed point) if not 1.
    scale: f32 = 1,
};

pub const Glyph = union(enum) {
    empty: struct { advance: u16 },
    simple: struct { advance: u16, contours: []const []const Pt },
    composite: struct { advance: u16, components: []const Component, box: [4]i16 },

    fn advance(g: Glyph) u16 {
        return switch (g) {
            inline else => |v| v.advance,
        };
    }
};

pub const Mapping = struct { codepoint: u21, glyph: u16 };
pub const KernPair = struct { left: u16, right: u16, value: i16 };

pub const GlyphClass = struct { glyph: u16, class: u16 };

/// Class-based kerning (GPOS pair adjustment format 2).
pub const ClassKerning = struct {
    /// Classes of first glyphs (every listed glyph is covered).
    first: []const GlyphClass,
    second: []const GlyphClass,
    class1_count: u16,
    class2_count: u16,
    /// `class1_count` rows of `class2_count` adjustments.
    values: []const i16,
};

pub const Gpos = struct {
    /// Per-pair kerning (format 1).
    pairs: []const KernPair = &.{},
    class_kerning: ?ClassKerning = null,
    /// Wrap the kerning lookup in an extension lookup (type 9).
    extension: bool = false,
    /// Pairs in a lookup used only by a non-kerning feature; must not apply.
    decoy_pairs: []const KernPair = &.{},
};

pub const Options = struct {
    units_per_em: u16 = 1000,
    ascender: i16 = 800,
    descender: i16 = -200,
    line_gap: i16 = 0,
    cmap_format: u16 = 4,
    /// Legacy `kern` table pairs.
    kerning: []const KernPair = &.{},
    gpos: ?Gpos = null,
    /// More tables, as given (e.g. GSUB, GDEF, or a GPOS instead of
    /// `gpos`).
    tables: []const RawTable = &.{},
};

pub const RawTable = struct { tag: *const [4]u8, data: []const u8 };

const Writer = struct {
    gpa: Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn u8_(w: *Writer, v: u8) !void {
        try w.bytes.append(w.gpa, v);
    }
    fn u16_(w: *Writer, v: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .big);
        try w.bytes.appendSlice(w.gpa, &b);
    }
    fn i16_(w: *Writer, v: i16) !void {
        try w.u16_(@bitCast(v));
    }
    fn u32_(w: *Writer, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        try w.bytes.appendSlice(w.gpa, &b);
    }
    fn zeros(w: *Writer, n: usize) !void {
        try w.bytes.appendNTimes(w.gpa, 0, n);
    }
    fn pad4(w: *Writer) !void {
        while (w.bytes.items.len % 4 != 0) try w.u8_(0);
    }
};

/// Assembles a TrueType font. The caller owns the returned bytes.
pub fn build(gpa: Allocator, glyphs: []const Glyph, mapping: []const Mapping, opts: Options) ![]u8 {
    // Each table is written separately, then placed after the directory.
    var tables: [16]struct { tag: *const [4]u8, w: Writer } = undefined;
    var count: usize = 0;
    defer for (tables[0..count]) |*t| t.w.bytes.deinit(gpa);
    const add = struct {
        fn f(ts: anytype, n: *usize, a: Allocator, t: *const [4]u8) *Writer {
            ts[n.*] = .{ .tag = t, .w = .{ .gpa = a } };
            n.* += 1;
            return &ts[n.* - 1].w;
        }
    }.f;

    // glyf + loca
    var loca_offsets: std.ArrayList(u32) = .empty;
    defer loca_offsets.deinit(gpa);
    const glyf = add(&tables, &count, gpa, "glyf");
    for (glyphs) |g| {
        try loca_offsets.append(gpa, @intCast(glyf.bytes.items.len));
        switch (g) {
            .empty => {},
            .simple => |s| try writeSimple(glyf, s.contours),
            .composite => |c| {
                try glyf.i16_(-1);
                for (c.box) |v| try glyf.i16_(v);
                for (c.components, 0..) |comp, i| {
                    const more: u16 = if (i + 1 < c.components.len) 0x0020 else 0;
                    const scaled: u16 = if (comp.scale != 1) 0x0008 else 0;
                    try glyf.u16_(0x0001 | 0x0002 | more | scaled); // word args, xy values
                    try glyf.u16_(comp.glyph);
                    try glyf.i16_(comp.dx);
                    try glyf.i16_(comp.dy);
                    if (scaled != 0) try glyf.i16_(@intFromFloat(@round(comp.scale * 16384)));
                }
            },
        }
        try glyf.pad4();
    }
    try loca_offsets.append(gpa, @intCast(glyf.bytes.items.len));
    const loca = add(&tables, &count, gpa, "loca");
    for (loca_offsets.items) |o| try loca.u32_(o);

    // head (long loca offsets)
    var bbox = [4]i16{ 0, opts.descender, 0, opts.ascender };
    for (glyphs) |g| if (g == .simple) for (g.simple.contours) |c| for (c) |p| {
        bbox[0] = @min(bbox[0], p.x);
        bbox[2] = @max(bbox[2], p.x);
    };
    const head = add(&tables, &count, gpa, "head");
    try head.u32_(0x00010000);
    try head.u32_(0x00010000);
    try head.u32_(0); // checksum adjustment
    try head.u32_(0x5F0F3CF5);
    try head.u16_(0);
    try head.u16_(opts.units_per_em);
    try head.zeros(16); // created, modified
    for (bbox) |v| try head.i16_(v);
    try head.zeros(6); // macStyle, lowestRecPPEM, fontDirectionHint
    try head.i16_(1); // indexToLocFormat: long
    try head.i16_(0);

    // hhea
    var max_advance: u16 = 0;
    for (glyphs) |g| max_advance = @max(max_advance, g.advance());
    const hhea = add(&tables, &count, gpa, "hhea");
    try hhea.u32_(0x00010000);
    try hhea.i16_(opts.ascender);
    try hhea.i16_(opts.descender);
    try hhea.i16_(opts.line_gap);
    try hhea.u16_(max_advance);
    try hhea.zeros(22);
    try hhea.u16_(@intCast(glyphs.len)); // numberOfHMetrics

    // maxp (version 0.5)
    const maxp = add(&tables, &count, gpa, "maxp");
    try maxp.u32_(0x00005000);
    try maxp.u16_(@intCast(glyphs.len));

    // hmtx
    const hmtx = add(&tables, &count, gpa, "hmtx");
    for (glyphs) |g| {
        try hmtx.u16_(g.advance());
        try hmtx.i16_(0);
    }

    // cmap with a single Unicode subtable
    const sorted = try gpa.dupe(Mapping, mapping);
    defer gpa.free(sorted);
    std.mem.sort(Mapping, sorted, {}, struct {
        fn lt(_: void, a: Mapping, b: Mapping) bool {
            return a.codepoint < b.codepoint;
        }
    }.lt);
    const cmap = add(&tables, &count, gpa, "cmap");
    try cmap.u16_(0);
    try cmap.u16_(1);
    try cmap.u16_(3);
    try cmap.u16_(if (opts.cmap_format == 12) 10 else 1);
    try cmap.u32_(12);
    if (opts.cmap_format == 12) {
        try cmap.u16_(12);
        try cmap.u16_(0);
        try cmap.u32_(@intCast(16 + sorted.len * 12));
        try cmap.u32_(0);
        try cmap.u32_(@intCast(sorted.len));
        for (sorted) |m| {
            try cmap.u32_(m.codepoint);
            try cmap.u32_(m.codepoint);
            try cmap.u32_(m.glyph);
        }
    } else {
        // One segment per character (idDelta maps it), plus the 0xFFFF end.
        const segs: u16 = @intCast(sorted.len + 1);
        try cmap.u16_(4);
        try cmap.u16_(16 + segs * 8);
        try cmap.u16_(0);
        try cmap.u16_(segs * 2);
        try cmap.zeros(6); // search hints (unused by readers that search)
        for (sorted) |m| try cmap.u16_(@intCast(m.codepoint));
        try cmap.u16_(0xffff);
        try cmap.u16_(0);
        for (sorted) |m| try cmap.u16_(@intCast(m.codepoint));
        try cmap.u16_(0xffff);
        for (sorted) |m| try cmap.u16_(@truncate(@as(u32, m.glyph) -% m.codepoint));
        try cmap.u16_(1);
        try cmap.zeros(@as(usize, segs) * 2); // idRangeOffset
    }

    if (opts.kerning.len > 0) {
        const pairs = try gpa.dupe(KernPair, opts.kerning);
        defer gpa.free(pairs);
        std.mem.sort(KernPair, pairs, {}, struct {
            fn lt(_: void, a: KernPair, b: KernPair) bool {
                return (@as(u32, a.left) << 16 | a.right) < (@as(u32, b.left) << 16 | b.right);
            }
        }.lt);
        const kern = add(&tables, &count, gpa, "kern");
        try kern.u16_(0);
        try kern.u16_(1);
        try kern.u16_(0);
        try kern.u16_(@intCast(14 + pairs.len * 6));
        try kern.u16_(0x0001); // format 0, horizontal
        try kern.u16_(@intCast(pairs.len));
        try kern.zeros(6);
        for (pairs) |p| {
            try kern.u16_(p.left);
            try kern.u16_(p.right);
            try kern.i16_(p.value);
        }
    }

    if (opts.gpos) |g| {
        const gpos = add(&tables, &count, gpa, "GPOS");
        try writeGpos(gpos, g);
    }

    for (opts.tables) |t| {
        const w = add(&tables, &count, gpa, t.tag);
        try w.bytes.appendSlice(gpa, t.data);
    }

    // Directory, then the tables.
    var out: Writer = .{ .gpa = gpa };
    errdefer out.bytes.deinit(gpa);
    try out.u32_(0x00010000);
    try out.u16_(@intCast(count));
    try out.zeros(6);
    var offset: u32 = @intCast(12 + count * 16);
    for (tables[0..count]) |*t| {
        try out.bytes.appendSlice(gpa, t.tag);
        try out.u32_(0);
        try out.u32_(offset);
        try out.u32_(@intCast(t.w.bytes.items.len));
        offset += @intCast((t.w.bytes.items.len + 3) / 4 * 4);
    }
    for (tables[0..count]) |*t| {
        try out.bytes.appendSlice(gpa, t.w.bytes.items);
        try out.pad4();
    }
    return out.bytes.toOwnedSlice(gpa);
}

fn patch16(w: *Writer, at: usize, v: u16) void {
    std.mem.writeInt(u16, w.bytes.items[at..][0..2], v, .big);
}

fn writeGpos(w: *Writer, g: Gpos) !void {
    const gpa = w.gpa;
    // Subtables of the kerning lookup.
    var subtables: std.ArrayList([]u8) = .empty;
    defer {
        for (subtables.items) |b| gpa.free(b);
        subtables.deinit(gpa);
    }
    if (g.pairs.len > 0) try subtables.append(gpa, try pairPosFormat1(gpa, g.pairs));
    if (g.class_kerning) |ck| try subtables.append(gpa, try pairPosFormat2(gpa, ck));

    const has_decoy = g.decoy_pairs.len > 0;
    // Header, then script list, feature list, lookup list.
    try w.u16_(1);
    try w.u16_(0);
    try w.u16_(10); // script list right after the header
    try w.u16_(0); // feature list: patched
    try w.u16_(0); // lookup list: patched

    // ScriptList: 'latn' -> default LangSys with features 0 (kern), 1 (liga).
    const script_list = w.bytes.items.len;
    try w.u16_(1);
    try w.bytes.appendSlice(gpa, "latn");
    try w.u16_(8); // script table after this record
    try w.u16_(4); // default LangSys offset (from script)
    try w.u16_(0); // no other languages
    try w.u16_(0); // lookupOrder
    try w.u16_(0xffff); // no required feature
    try w.u16_(if (has_decoy) 2 else 1);
    try w.u16_(0);
    if (has_decoy) try w.u16_(1);
    _ = script_list;

    const feature_list = w.bytes.items.len;
    patch16(w, 6, @intCast(feature_list));
    const features: u16 = if (has_decoy) 2 else 1;
    try w.u16_(features);
    try w.bytes.appendSlice(gpa, "kern");
    try w.u16_(2 + features * 6);
    if (has_decoy) {
        try w.bytes.appendSlice(gpa, "liga");
        try w.u16_(2 + features * 6 + 6);
    }
    for (0..features) |i| {
        try w.u16_(0);
        try w.u16_(1);
        try w.u16_(@intCast(i)); // feature i uses lookup i
    }

    const lookup_list = w.bytes.items.len;
    patch16(w, 8, @intCast(lookup_list));
    try w.u16_(features);
    const lookup_offsets = w.bytes.items.len;
    try w.zeros(@as(usize, features) * 2);

    // Lookup 0: kerning, optionally through extension subtables.
    patch16(w, lookup_offsets, @intCast(w.bytes.items.len - lookup_list));
    const lookup0 = w.bytes.items.len;
    try w.u16_(if (g.extension) 9 else 2);
    try w.u16_(0);
    try w.u16_(@intCast(subtables.items.len));
    const sub_offsets = w.bytes.items.len;
    try w.zeros(subtables.items.len * 2);
    for (subtables.items, 0..) |sub, i| {
        patch16(w, sub_offsets + i * 2, @intCast(w.bytes.items.len - lookup0));
        if (g.extension) {
            try w.u16_(1);
            try w.u16_(2);
            try w.u32_(8); // the wrapped subtable follows
        }
        try w.bytes.appendSlice(gpa, sub);
    }

    if (has_decoy) {
        patch16(w, lookup_offsets + 2, @intCast(w.bytes.items.len - lookup_list));
        const decoy = try pairPosFormat1(gpa, g.decoy_pairs);
        defer gpa.free(decoy);
        try w.u16_(2);
        try w.u16_(0);
        try w.u16_(1);
        try w.u16_(8);
        try w.bytes.appendSlice(gpa, decoy);
    }
}

fn sortedPairs(gpa: Allocator, pairs: []const KernPair) ![]KernPair {
    const sorted = try gpa.dupe(KernPair, pairs);
    std.mem.sort(KernPair, sorted, {}, struct {
        fn lt(_: void, a: KernPair, b: KernPair) bool {
            return (@as(u32, a.left) << 16 | a.right) < (@as(u32, b.left) << 16 | b.right);
        }
    }.lt);
    return sorted;
}

/// PairPos format 1: a pair set per first glyph, coverage format 1.
fn pairPosFormat1(gpa: Allocator, pairs: []const KernPair) ![]u8 {
    const sorted = try sortedPairs(gpa, pairs);
    defer gpa.free(sorted);
    var firsts: std.ArrayList(u16) = .empty;
    defer firsts.deinit(gpa);
    for (sorted) |p| if (firsts.items.len == 0 or firsts.items[firsts.items.len - 1] != p.left) try firsts.append(gpa, p.left);

    var w: Writer = .{ .gpa = gpa };
    errdefer w.bytes.deinit(gpa);
    try w.u16_(1);
    try w.u16_(0); // coverage: patched
    try w.u16_(0x0004); // value format 1: XAdvance
    try w.u16_(0);
    try w.u16_(@intCast(firsts.items.len));
    const set_offsets = w.bytes.items.len;
    try w.zeros(firsts.items.len * 2);
    for (firsts.items, 0..) |first, i| {
        patch16(&w, set_offsets + i * 2, @intCast(w.bytes.items.len));
        var n: u16 = 0;
        for (sorted) |p| if (p.left == first) {
            n += 1;
        };
        try w.u16_(n);
        for (sorted) |p| if (p.left == first) {
            try w.u16_(p.right);
            try w.i16_(p.value);
        };
    }
    patch16(&w, 2, @intCast(w.bytes.items.len));
    try w.u16_(1);
    try w.u16_(@intCast(firsts.items.len));
    for (firsts.items) |f| try w.u16_(f);
    return w.bytes.toOwnedSlice(gpa);
}

/// PairPos format 2: class matrix; coverage format 2, ClassDef formats 2
/// (first glyphs) and 1 (second glyphs).
fn pairPosFormat2(gpa: Allocator, ck: ClassKerning) ![]u8 {
    const first = try gpa.dupe(GlyphClass, ck.first);
    defer gpa.free(first);
    const byGlyph = struct {
        fn lt(_: void, a: GlyphClass, b: GlyphClass) bool {
            return a.glyph < b.glyph;
        }
    }.lt;
    std.mem.sort(GlyphClass, first, {}, byGlyph);

    var w: Writer = .{ .gpa = gpa };
    errdefer w.bytes.deinit(gpa);
    try w.u16_(2);
    try w.u16_(0); // coverage
    try w.u16_(0x0004);
    try w.u16_(0);
    try w.u16_(0); // class def 1
    try w.u16_(0); // class def 2
    try w.u16_(ck.class1_count);
    try w.u16_(ck.class2_count);
    for (ck.values) |v| try w.i16_(v);

    // Coverage format 2: ranges of consecutive glyphs.
    patch16(&w, 2, @intCast(w.bytes.items.len));
    var ranges: std.ArrayList([3]u16) = .empty;
    defer ranges.deinit(gpa);
    for (first, 0..) |c, i| {
        if (ranges.items.len > 0 and ranges.items[ranges.items.len - 1][1] + 1 == c.glyph) {
            ranges.items[ranges.items.len - 1][1] = c.glyph;
        } else try ranges.append(gpa, .{ c.glyph, c.glyph, @intCast(i) });
    }
    try w.u16_(2);
    try w.u16_(@intCast(ranges.items.len));
    for (ranges.items) |r| for (r) |v| try w.u16_(v);

    // ClassDef 1, format 2: one range per glyph.
    patch16(&w, 8, @intCast(w.bytes.items.len));
    try w.u16_(2);
    try w.u16_(@intCast(first.len));
    for (first) |c| {
        try w.u16_(c.glyph);
        try w.u16_(c.glyph);
        try w.u16_(c.class);
    }

    // ClassDef 2, format 1: a class array from the lowest glyph.
    patch16(&w, 10, @intCast(w.bytes.items.len));
    var lo: u16 = std.math.maxInt(u16);
    var hi: u16 = 0;
    for (ck.second) |c| {
        lo = @min(lo, c.glyph);
        hi = @max(hi, c.glyph);
    }
    try w.u16_(1);
    try w.u16_(lo);
    try w.u16_(hi - lo + 1);
    for (lo..@as(usize, hi) + 1) |gl| {
        var class: u16 = 0;
        for (ck.second) |c| if (c.glyph == gl) {
            class = c.class;
        };
        try w.u16_(class);
    }
    return w.bytes.toOwnedSlice(gpa);
}

fn writeSimple(w: *Writer, contours: []const []const Pt) !void {
    var bbox = [4]i16{ std.math.maxInt(i16), std.math.maxInt(i16), std.math.minInt(i16), std.math.minInt(i16) };
    var n: u16 = 0;
    for (contours) |c| for (c) |p| {
        bbox = .{ @min(bbox[0], p.x), @min(bbox[1], p.y), @max(bbox[2], p.x), @max(bbox[3], p.y) };
        n += 1;
    };
    try w.i16_(@intCast(contours.len));
    for (bbox) |v| try w.i16_(v);
    var end: u16 = 0;
    for (contours) |c| {
        end += @intCast(c.len);
        try w.u16_(end - 1);
    }
    try w.u16_(0); // no instructions
    // Flags: on-curve bit only; the first flag uses REPEAT for a run of
    // identical flags, to exercise the decoder.
    var all: std.ArrayList(Pt) = .empty;
    defer all.deinit(w.gpa);
    for (contours) |c| try all.appendSlice(w.gpa, c);
    var i: usize = 0;
    while (i < all.items.len) {
        const f: u8 = if (all.items[i].on) 1 else 0;
        var run: usize = 1;
        while (i + run < all.items.len and run < 255 and (all.items[i + run].on) == (f == 1)) run += 1;
        if (run > 1) {
            try w.u8_(f | 0x08);
            try w.u8_(@intCast(run - 1));
        } else try w.u8_(f);
        i += run;
    }
    var prev: i16 = 0;
    for (all.items) |p| {
        try w.i16_(p.x - prev);
        prev = p.x;
    }
    prev = 0;
    for (all.items) |p| {
        try w.i16_(p.y - prev);
        prev = p.y;
    }
}

/// Glyph ids of the `standard` test font.
pub const glyph = struct {
    pub const notdef = 0;
    pub const space = 1;
    pub const A = 2;
    pub const B = 3;
    pub const O = 4;
    pub const C = 5;
    pub const small_square = 6;
    pub const i = 7;
};

/// A geometric test font (1000 units per em, ascender 800, descender -200):
///   'A' triangle, 'B' square with a square hole, 'O' a ring of quadratic
///   curves with only off-curve points, 'C' a composite of two small
///   squares, 'i' a narrow bar, ' ' empty. Advances are 550 (space 250,
///   'i' 200). Kerning: A followed by B is -100.
pub fn standard(gpa: Allocator) ![]u8 {
    const notdef = [_][]const Pt{
        &.{ .{ .x = 50, .y = 0 }, .{ .x = 50, .y = 700 }, .{ .x = 450, .y = 700 }, .{ .x = 450, .y = 0 } },
        &.{ .{ .x = 100, .y = 50 }, .{ .x = 400, .y = 50 }, .{ .x = 400, .y = 650 }, .{ .x = 100, .y = 650 } },
    };
    const a = [_][]const Pt{&.{ .{ .x = 0, .y = 0 }, .{ .x = 250, .y = 700 }, .{ .x = 500, .y = 0 } }};
    const b = [_][]const Pt{
        &.{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 700 }, .{ .x = 500, .y = 700 }, .{ .x = 500, .y = 0 } },
        &.{ .{ .x = 150, .y = 200 }, .{ .x = 350, .y = 200 }, .{ .x = 350, .y = 500 }, .{ .x = 150, .y = 500 } },
    };
    // Off-curve octagons approximate circles (outer clockwise, inner counter).
    const o = [_][]const Pt{
        &octagon(250, 350, 270, false),
        &octagon(250, 350, 150, true),
    };
    const square = [_][]const Pt{&.{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 200 }, .{ .x = 200, .y = 200 }, .{ .x = 200, .y = 0 } }};
    const bar = [_][]const Pt{&.{ .{ .x = 50, .y = 0 }, .{ .x = 50, .y = 700 }, .{ .x = 150, .y = 700 }, .{ .x = 150, .y = 0 } }};
    const glyphs = [_]Glyph{
        .{ .simple = .{ .advance = 500, .contours = &notdef } },
        .{ .empty = .{ .advance = 250 } },
        .{ .simple = .{ .advance = 550, .contours = &a } },
        .{ .simple = .{ .advance = 550, .contours = &b } },
        .{ .simple = .{ .advance = 550, .contours = &o } },
        .{ .composite = .{ .advance = 550, .box = .{ 0, 0, 500, 700 }, .components = &.{
            .{ .glyph = glyph.small_square, .dx = 0, .dy = 0 },
            .{ .glyph = glyph.small_square, .dx = 150, .dy = 250, .scale = 1.75 },
        } } },
        .{ .simple = .{ .advance = 200, .contours = &square } },
        .{ .simple = .{ .advance = 200, .contours = &bar } },
    };
    return build(gpa, &glyphs, &.{
        .{ .codepoint = ' ', .glyph = glyph.space },
        .{ .codepoint = 'A', .glyph = glyph.A },
        .{ .codepoint = 'B', .glyph = glyph.B },
        .{ .codepoint = 'O', .glyph = glyph.O },
        .{ .codepoint = 'C', .glyph = glyph.C },
        .{ .codepoint = 'i', .glyph = glyph.i },
    }, .{ .kerning = &.{.{ .left = glyph.A, .right = glyph.B, .value = -100 }} });
}

fn octagon(cx: i16, cy: i16, r: i16, reverse: bool) [8]Pt {
    // Control points on a regular octagon around (cx, cy); with all points
    // off-curve, the curve passes through the edge midpoints.
    var pts: [8]Pt = undefined;
    for (0..8) |k| {
        const angle = @as(f32, @floatFromInt(k)) * std.math.pi / 4.0 * (if (reverse) @as(f32, 1) else -1);
        const rf: f32 = @floatFromInt(r);
        pts[k] = .{
            .x = cx + @as(i16, @intFromFloat(@round(@cos(angle) * rf))),
            .y = cy + @as(i16, @intFromFloat(@round(@sin(angle) * rf))),
            .on = false,
        };
    }
    return pts;
}
