// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! OpenType layout: applies a font's GSUB substitutions and GPOS
//! positioning to a buffer of glyphs, for the features shape.zig asks for.
//!
//! Supported: single, multiple, ligature, contextual and chained contextual
//! substitutions; single and pair adjustments, cursive attachment,
//! mark-to-base, mark-to-ligature, mark-to-mark and contextual positioning;
//! extension lookups, lookup flags (ignoring bases, ligatures or marks,
//! mark attachment classes, mark filtering sets) and GDEF glyph classes.
//! Not supported: alternate and reverse chaining substitutions, device
//! tables and font variations.
//!
//! Font data is untrusted: every read is bounds-checked, and malformed
//! tables make a lookup do nothing.

const std = @import("std");
const tt = @import("truetype.zig");
const Font = tt.Font;
const Bytes = tt.Bytes;
const Table = tt.Table;
const Error = tt.Error;
const tag = tt.tag;
const coverageIndex = tt.coverageIndex;
const classOf = tt.classOf;

/// GDEF glyph classes.
pub const base_class = 1;
pub const ligature_class = 2;
pub const mark_class = 3;

pub const no_attach = std.math.maxInt(u16);

/// A glyph being shaped.
pub const Info = struct {
    glyph: u16,
    /// The font (index into the metrics' fonts) the glyph is in.
    font: u8 = 0,
    /// GDEF class (0 unknown, 1 base, 2 ligature, 3 mark, 4 component).
    class: u8 = base_class,
    /// The characters it shows, as logical indices: [char, char_end).
    char: u16,
    char_end: u16,
    /// The features that apply to it (`Feature.mask` bits).
    mask: u16 = 0,
    /// Marks skipped by a ligature remember which component they follow.
    lig_id: u8 = 0,
    lig_comp: u8 = 0,
    /// Shown right to left.
    rtl: bool = false,
    /// Positioning, in font units (y up).
    x_advance: i32 = 0,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    /// For attached glyphs (marks, cursive): the glyph the offsets are
    /// from.
    attach: u16 = no_attach,
    /// Cursive attachment: offsets are from `attach` in y only.
    cursive: bool = false,
};

/// The glyphs of a line; lookups apply to `info[lo..hi]` (one run of one
/// font) and may change its length.
pub const Buffer = struct {
    info: []Info,
    len: usize,
    lo: usize = 0,
    hi: usize = 0,
    next_lig_id: u8 = 1,

    /// Opens a gap of `n` glyphs after `at` (copies of `info[at]`).
    pub fn insert(b: *Buffer, at: usize, n: usize) bool {
        if (b.len + n > b.info.len) return false;
        std.mem.copyBackwards(Info, b.info[at + 1 + n .. b.len + n], b.info[at + 1 .. b.len]);
        for (b.info[at + 1 ..][0..n]) |*x| x.* = b.info[at];
        b.len += n;
        b.hi += n;
        return true;
    }

    pub fn remove(b: *Buffer, at: usize) void {
        std.mem.copyForwards(Info, b.info[at .. b.len - 1], b.info[at + 1 .. b.len]);
        b.len -= 1;
        b.hi -= 1;
    }
};

/// A feature to apply, to the glyphs whose mask has `mask`'s bits.
pub const Feature = struct { tag: u32, mask: u16 };

pub const max_lookups = 64;

/// The lookups to apply, in lookup-list order.
pub const Lookups = struct {
    items: [max_lookups]Item = undefined,
    count: u8 = 0,
    lookup_list: u64 = 0,

    pub const Item = struct { index: u16, mask: u16 };

    /// Whether any lookup applies to glyphs with `mask`.
    pub fn has(l: *const Lookups, mask: u16) bool {
        for (l.items[0..l.count]) |it| if (it.mask & mask != 0) return true;
        return false;
    }
};

/// The lookups of `features` in a GSUB or GPOS table, for `script` (else
/// the default script, else Latin); the required feature applies to all.
pub fn collect(font: *const Font, table: ?Table, script: u32, features: []const Feature) Lookups {
    var out: Lookups = .{};
    const t = table orelse return out;
    collectIn(font.bytes(), t.offset, script, features, &out) catch return .{};
    return out;
}

fn collectIn(b: Bytes, g: u64, script: u32, features: []const Feature, out: *Lookups) Error!void {
    if (try b.u16At(g) != 1) return;
    const script_list = g + try b.u16At(g + 4);
    const feature_list = g + try b.u16At(g + 6);
    out.lookup_list = g + try b.u16At(g + 8);

    var lang_sys: ?u64 = null;
    var best: u8 = 0;
    const scripts = try b.u16At(script_list);
    for (0..scripts) |i| {
        const rec = script_list + 2 + @as(u64, i) * 6;
        const t = try b.u32At(rec);
        const score: u8 = if (t == script) 3 else if (t == tag("DFLT")) 2 else if (t == tag("latn")) 1 else 0;
        if (score <= best) continue;
        const s = script_list + try b.u16At(rec + 4);
        const default_lang = try b.u16At(s);
        if (default_lang == 0) continue;
        lang_sys = s + default_lang;
        best = score;
    }
    const ls = lang_sys orelse return;
    const feature_count = try b.u16At(feature_list);
    const required = try b.u16At(ls + 2);
    const n = try b.u16At(ls + 4);
    var k: u64 = 0;
    while (k <= n) : (k += 1) {
        const index = if (k == n) required else try b.u16At(ls + 6 + k * 2);
        if (index >= feature_count) continue;
        const rec = feature_list + 2 + @as(u64, index) * 6;
        const ftag = try b.u32At(rec);
        var mask: u16 = 0;
        if (k == n) {
            mask = 0xffff;
        } else for (features) |f| {
            if (f.tag == ftag) mask |= f.mask;
        }
        if (mask == 0) continue;
        const feat = feature_list + try b.u16At(rec + 4);
        const lookups = try b.u16At(feat + 2);
        for (0..lookups) |li| {
            const lookup = try b.u16At(feat + 4 + @as(u64, li) * 2);
            for (out.items[0..out.count]) |*it| {
                if (it.index == lookup) {
                    it.mask |= mask;
                    break;
                }
            } else if (out.count < max_lookups) {
                out.items[out.count] = .{ .index = lookup, .mask = mask };
                out.count += 1;
            }
        }
    }
    std.mem.sort(Lookups.Item, out.items[0..out.count], {}, struct {
        fn lt(_: void, a: Lookups.Item, c: Lookups.Item) bool {
            return a.index < c.index;
        }
    }.lt);
}

/// The GDEF tables used.
pub const Gdef = struct {
    glyph_classes: u64 = 0,
    mark_classes: u64 = 0,
    mark_sets: u64 = 0,

    pub fn of(font: *const Font) Gdef {
        const t = font.gdef orelse return .{};
        const b = font.bytes();
        const g = t.offset;
        var d: Gdef = .{};
        if ((b.u16At(g) catch 0) != 1) return .{};
        const minor = b.u16At(g + 2) catch return .{};
        const classes = b.u16At(g + 4) catch 0;
        const marks = b.u16At(g + 10) catch 0;
        if (classes != 0) d.glyph_classes = g + classes;
        if (marks != 0) d.mark_classes = g + marks;
        if (minor >= 2) {
            const sets = b.u16At(g + 12) catch 0;
            if (sets != 0) d.mark_sets = g + sets;
        }
        return d;
    }

    /// The glyph's class; 0 without a class table.
    pub fn class(d: Gdef, b: Bytes, glyph: u16) u8 {
        if (d.glyph_classes == 0) return 0;
        return @truncate(classOf(b, d.glyph_classes, glyph) catch 0);
    }

    fn markClass(d: Gdef, b: Bytes, glyph: u16) u16 {
        if (d.mark_classes == 0) return 0;
        return classOf(b, d.mark_classes, glyph) catch 0;
    }

    fn inMarkSet(d: Gdef, b: Bytes, set: u16, glyph: u16) bool {
        if (d.mark_sets == 0) return false;
        const count = b.u16At(d.mark_sets + 2) catch return false;
        if (set >= count) return false;
        const cov = b.u32At(d.mark_sets + 4 + @as(u64, set) * 4) catch return false;
        return (coverageIndex(b, d.mark_sets + cov, glyph) catch null) != null;
    }
};

pub const Kind = enum { gsub, gpos };

/// A lookup's header.
const Lookup = struct {
    offset: u64,
    type: u16,
    flag: u16,
    filter: u16,
    subtables: u16,

    const right_to_left = 0x1;
    const ignore_base = 0x2;
    const ignore_ligatures = 0x4;
    const ignore_marks = 0x8;
    const use_filter = 0x10;

    fn read(b: Bytes, offset: u64) Error!Lookup {
        const subtables = try b.u16At(offset + 4);
        const flag = try b.u16At(offset + 2);
        return .{
            .offset = offset,
            .type = try b.u16At(offset),
            .flag = flag,
            .subtables = subtables,
            .filter = if (flag & use_filter != 0) try b.u16At(offset + 6 + @as(u64, subtables) * 2) else 0,
        };
    }
};

/// Applies the lookups (of `kind`'s table) to the run
/// `buf.info[buf.lo..buf.hi]`, whose glyphs are `font`'s.
pub fn apply(font: *const Font, kind: Kind, lookups: *const Lookups, buf: *Buffer) void {
    var ctx: Ctx = .{ .b = font.bytes(), .buf = buf, .gdef = .of(font), .kind = kind, .lookup_list = lookups.lookup_list };
    for (lookups.items[0..lookups.count]) |it| {
        const lookup = ctx.lookup(it.index) catch continue;
        var i = buf.lo;
        while (i < buf.hi) {
            if (buf.info[i].mask & it.mask == 0 or ctx.skipped(lookup, i)) {
                i += 1;
                continue;
            }
            const next = ctx.applyAt(lookup, i) catch null;
            i = if (next) |n| @max(n, i + 1) else i + 1;
        }
    }
}

/// Where a sequence matched: buffer positions.
const max_context = 32;
const Positions = struct {
    at: [max_context]usize = undefined,
    n: usize = 0,
};

/// How a sequence's glyphs are compared: by glyph id, by class or by
/// coverage, with one u16 per glyph at `data`.
const Matcher = struct {
    how: enum { glyph, class, coverage },
    data: u64,
    /// The class definition table, or what coverage offsets are from.
    base: u64 = 0,

    fn matches(m: Matcher, b: Bytes, k: u64, glyph: u16) Error!bool {
        const v = try b.u16At(m.data + k * 2);
        return switch (m.how) {
            .glyph => v == glyph,
            .class => try classOf(b, m.base, glyph) == v,
            .coverage => try coverageIndex(b, m.base + v, glyph) != null,
        };
    }
};

const Ctx = struct {
    b: Bytes,
    buf: *Buffer,
    gdef: Gdef,
    kind: Kind,
    lookup_list: u64,
    depth: u8 = 0,

    fn lookup(ctx: *const Ctx, index: u16) Error!Lookup {
        if (index >= try ctx.b.u16At(ctx.lookup_list)) return error.InvalidFont;
        return Lookup.read(ctx.b, ctx.lookup_list + try ctx.b.u16At(ctx.lookup_list + 2 + @as(u64, index) * 2));
    }

    /// Whether the lookup's flags skip the glyph at `i`.
    fn skipped(ctx: *const Ctx, l: Lookup, i: usize) bool {
        const info = ctx.buf.info[i];
        return switch (info.class) {
            mark_class => blk: {
                if (l.flag & Lookup.ignore_marks != 0) break :blk true;
                if (l.flag & Lookup.use_filter != 0) break :blk !ctx.gdef.inMarkSet(ctx.b, l.filter, info.glyph);
                const attach_type = l.flag >> 8;
                if (attach_type != 0) break :blk ctx.gdef.markClass(ctx.b, info.glyph) != attach_type;
                break :blk false;
            },
            base_class => l.flag & Lookup.ignore_base != 0,
            ligature_class => l.flag & Lookup.ignore_ligatures != 0,
            else => false,
        };
    }

    /// The next glyph after `i` the lookup does not skip.
    fn nextOf(ctx: *const Ctx, l: Lookup, i: usize) ?usize {
        var j = i + 1;
        while (j < ctx.buf.hi) : (j += 1) if (!ctx.skipped(l, j)) return j;
        return null;
    }

    fn prevOf(ctx: *const Ctx, l: Lookup, i: usize) ?usize {
        var j = i;
        while (j > ctx.buf.lo) {
            j -= 1;
            if (!ctx.skipped(l, j)) return j;
        }
        return null;
    }

    fn glyphAt(ctx: *const Ctx, i: usize) u16 {
        return ctx.buf.info[i].glyph;
    }

    /// Applies the lookup at `i`: the position to continue from, or null if
    /// no subtable applied.
    fn applyAt(ctx: *Ctx, l: Lookup, i: usize) Error!?usize {
        for (0..l.subtables) |s| {
            var sub = l.offset + try ctx.b.u16At(l.offset + 6 + @as(u64, s) * 2);
            var t = l.type;
            if (t == (if (ctx.kind == .gsub) @as(u16, 7) else 9)) {
                if (try ctx.b.u16At(sub) != 1) continue;
                t = try ctx.b.u16At(sub + 2);
                sub += try ctx.b.u32At(sub + 4);
            }
            const r = switch (ctx.kind) {
                .gsub => try ctx.substituteAt(l, t, sub, i),
                .gpos => try ctx.positionAt(l, t, sub, i),
            };
            if (r) |next| return next;
        }
        return null;
    }

    fn setGlyph(ctx: *Ctx, i: usize, glyph: u16) void {
        const info = &ctx.buf.info[i];
        info.glyph = glyph;
        const c = ctx.gdef.class(ctx.b, glyph);
        if (c != 0) info.class = c;
    }

    // ---- GSUB ----

    fn substituteAt(ctx: *Ctx, l: Lookup, t: u16, sub: u64, i: usize) Error!?usize {
        const b = ctx.b;
        const glyph = ctx.glyphAt(i);
        switch (t) {
            1 => {
                const index = (try coverageIndex(b, sub + try b.u16At(sub + 2), glyph)) orelse return null;
                switch (try b.u16At(sub)) {
                    1 => ctx.setGlyph(i, @truncate(@as(u32, glyph) +% @as(u16, @bitCast(try b.i16At(sub + 4))))),
                    2 => {
                        if (index >= try b.u16At(sub + 4)) return error.InvalidFont;
                        ctx.setGlyph(i, try b.u16At(sub + 6 + @as(u64, index) * 2));
                    },
                    else => return null,
                }
                return i + 1;
            },
            2 => {
                if (try b.u16At(sub) != 1) return null;
                const index = (try coverageIndex(b, sub + try b.u16At(sub + 2), glyph)) orelse return null;
                if (index >= try b.u16At(sub + 4)) return error.InvalidFont;
                const seq = sub + try b.u16At(sub + 6 + @as(u64, index) * 2);
                const n = try b.u16At(seq);
                if (n == 0) {
                    ctx.buf.remove(i);
                    return i;
                }
                _ = try b.slice(seq + 2, @as(u64, n) * 2);
                if (!ctx.buf.insert(i, n - 1)) return null;
                for (0..n) |k| ctx.setGlyph(i + k, try b.u16At(seq + 2 + @as(u64, k) * 2));
                return i + n;
            },
            4 => {
                if (try b.u16At(sub) != 1) return null;
                const index = (try coverageIndex(b, sub + try b.u16At(sub + 2), glyph)) orelse return null;
                if (index >= try b.u16At(sub + 4)) return error.InvalidFont;
                const set = sub + try b.u16At(sub + 6 + @as(u64, index) * 2);
                const count = try b.u16At(set);
                for (0..count) |k| {
                    const lig = set + try b.u16At(set + 2 + @as(u64, k) * 2);
                    const components = try b.u16At(lig + 2);
                    if (components == 0) continue;
                    var at: Positions = .{};
                    if (!try ctx.matchForward(l, i, components - 1, .{ .how = .glyph, .data = lig + 4 }, 0, &at)) continue;
                    ctx.ligate(at, try b.u16At(lig));
                    return i + 1;
                }
                return null;
            },
            5 => return ctx.context(l, sub, i),
            6 => return ctx.chainContext(l, sub, i),
            else => return null,
        }
    }

    /// Replaces the glyphs at `at` (the first is `at.at[0]`) by `glyph`.
    fn ligate(ctx: *Ctx, at: Positions, glyph: u16) void {
        const buf = ctx.buf;
        const first = at.at[0];
        const id = buf.next_lig_id;
        buf.next_lig_id +%= 1;
        if (buf.next_lig_id == 0) buf.next_lig_id = 1;
        var end = buf.info[first].char_end;
        for (at.at[1..at.n]) |p| end = @max(end, buf.info[p].char_end);
        // Marks between the components: which component they follow.
        var comp: u8 = 1;
        var k: usize = 1;
        var p = first + 1;
        while (k < at.n) : (p += 1) {
            if (p == at.at[k]) {
                comp += 1;
                k += 1;
            } else {
                buf.info[p].lig_id = id;
                buf.info[p].lig_comp = comp;
            }
        }
        // Remove the other components, last first.
        var r = at.n;
        while (r > 1) {
            r -= 1;
            buf.remove(at.at[r]);
        }
        ctx.setGlyph(first, glyph);
        const info = &buf.info[first];
        if (ctx.gdef.glyph_classes == 0) info.class = ligature_class;
        info.char_end = end;
        info.lig_id = id;
        info.lig_comp = 0;
        // Marks after the ligature (its last component's).
        var q = first + 1;
        while (q < buf.hi and buf.info[q].class == mark_class) : (q += 1) {
            if (buf.info[q].lig_id == id) continue;
            buf.info[q].lig_id = id;
            buf.info[q].lig_comp = comp;
        }
    }

    /// Matches `count` glyphs after `i` (not skipped), the k-th compared
    /// with value `first_value + k` of `m`. Fills `at` with `i` and them.
    fn matchForward(ctx: *const Ctx, l: Lookup, i: usize, count: u16, m: Matcher, first_value: u64, at: *Positions) Error!bool {
        if (count >= max_context) return false;
        at.at[0] = i;
        at.n = 1;
        var p = i;
        for (0..count) |k| {
            p = ctx.nextOf(l, p) orelse return false;
            if (!try m.matches(ctx.b, first_value + k, ctx.glyphAt(p))) return false;
            at.at[at.n] = p;
            at.n += 1;
        }
        return true;
    }

    /// Matches `count` glyphs before `i`, the k-th back compared with value
    /// k of `m`.
    fn matchBackward(ctx: *const Ctx, l: Lookup, i: usize, count: u16, m: Matcher) Error!bool {
        var p = i;
        for (0..count) |k| {
            p = ctx.prevOf(l, p) orelse return false;
            if (!try m.matches(ctx.b, k, ctx.glyphAt(p))) return false;
        }
        return true;
    }

    fn matchLookahead(ctx: *const Ctx, l: Lookup, last: usize, count: u16, m: Matcher) Error!bool {
        var p = last;
        for (0..count) |k| {
            p = ctx.nextOf(l, p) orelse return false;
            if (!try m.matches(ctx.b, k, ctx.glyphAt(p))) return false;
        }
        return true;
    }

    /// Applies the nested lookups of a matched context: `records` (lookup
    /// count, then seq index and lookup index each). Returns where to go on.
    fn applyRecords(ctx: *Ctx, at: *Positions, records: u64, count: u16) Error!usize {
        if (ctx.depth >= 6) return at.at[at.n - 1] + 1;
        _ = try ctx.b.slice(records, @as(u64, count) * 4);
        ctx.depth += 1;
        defer ctx.depth -= 1;
        for (0..count) |k| {
            const seq = try ctx.b.u16At(records + k * 4);
            const index = try ctx.b.u16At(records + k * 4 + 2);
            if (seq >= at.n) continue;
            const nested = ctx.lookup(index) catch continue;
            const p = at.at[seq];
            if (p >= ctx.buf.hi) continue;
            const before = ctx.buf.hi;
            _ = try ctx.applyAt(nested, p);
            // Glyphs added or removed move the positions after it.
            const delta = @as(isize, @intCast(ctx.buf.hi)) - @as(isize, @intCast(before));
            if (delta != 0) for (at.at[seq + 1 .. at.n]) |*q| {
                q.* = @intCast(@max(@as(isize, @intCast(p)) + 1, @as(isize, @intCast(q.*)) + delta));
            };
        }
        return @min(at.at[at.n - 1] + 1, ctx.buf.hi);
    }

    fn context(ctx: *Ctx, l: Lookup, sub: u64, i: usize) Error!?usize {
        const b = ctx.b;
        const glyph = ctx.glyphAt(i);
        switch (try b.u16At(sub)) {
            1, 2 => |format| {
                const index = (try coverageIndex(b, sub + try b.u16At(sub + 2), glyph)) orelse return null;
                const class_def: u64 = if (format == 2) sub + try b.u16At(sub + 4) else 0;
                const sets_at: u64 = if (format == 2) sub + 6 else sub + 4;
                const set_index: u16 = if (format == 2) try classOf(b, class_def, glyph) else index;
                if (set_index >= try b.u16At(sets_at)) return null;
                const set_off = try b.u16At(sets_at + 2 + @as(u64, set_index) * 2);
                if (set_off == 0) return null;
                const set = sub + set_off;
                const rules = try b.u16At(set);
                for (0..rules) |r| {
                    const rule = set + try b.u16At(set + 2 + @as(u64, r) * 2);
                    const glyphs = try b.u16At(rule);
                    const records = try b.u16At(rule + 2);
                    if (glyphs == 0) continue;
                    const m: Matcher = if (format == 2) .{ .how = .class, .data = rule + 4, .base = class_def } else .{ .how = .glyph, .data = rule + 4 };
                    var at: Positions = .{};
                    if (!try ctx.matchForward(l, i, glyphs - 1, m, 0, &at)) continue;
                    return try ctx.applyRecords(&at, rule + 4 + (@as(u64, glyphs) - 1) * 2, records);
                }
                return null;
            },
            3 => {
                const glyphs = try b.u16At(sub + 2);
                const records = try b.u16At(sub + 4);
                if (glyphs == 0) return null;
                const m: Matcher = .{ .how = .coverage, .data = sub + 6, .base = sub };
                if (!try m.matches(b, 0, glyph)) return null;
                var at: Positions = .{};
                if (!try ctx.matchForward(l, i, glyphs - 1, m, 1, &at)) return null;
                return try ctx.applyRecords(&at, sub + 6 + @as(u64, glyphs) * 2, records);
            },
            else => return null,
        }
    }

    fn chainContext(ctx: *Ctx, l: Lookup, sub: u64, i: usize) Error!?usize {
        const b = ctx.b;
        const glyph = ctx.glyphAt(i);
        switch (try b.u16At(sub)) {
            1, 2 => |format| {
                const index = (try coverageIndex(b, sub + try b.u16At(sub + 2), glyph)) orelse return null;
                var defs: [3]u64 = .{ 0, 0, 0 };
                var set_index: u16 = index;
                var sets_at = sub + 4;
                if (format == 2) {
                    for (&defs, 0..) |*d, k| d.* = sub + try b.u16At(sub + 4 + k * 2);
                    set_index = try classOf(b, defs[1], glyph);
                    sets_at = sub + 10;
                }
                if (set_index >= try b.u16At(sets_at)) return null;
                const set_off = try b.u16At(sets_at + 2 + @as(u64, set_index) * 2);
                if (set_off == 0) return null;
                const set = sub + set_off;
                const rules = try b.u16At(set);
                for (0..rules) |r| {
                    const rule = set + try b.u16At(set + 2 + @as(u64, r) * 2);
                    const backtrack = try b.u16At(rule);
                    const input_at = rule + 2 + @as(u64, backtrack) * 2;
                    const input = try b.u16At(input_at);
                    if (input == 0) continue;
                    const ahead_at = input_at + 2 + (@as(u64, input) - 1) * 2;
                    const ahead = try b.u16At(ahead_at);
                    const records_at = ahead_at + 2 + @as(u64, ahead) * 2;
                    const how: @FieldType(Matcher, "how") = if (format == 2) .class else .glyph;
                    var at: Positions = .{};
                    if (!try ctx.matchForward(l, i, input - 1, .{ .how = how, .data = input_at + 2, .base = defs[1] }, 0, &at)) continue;
                    if (!try ctx.matchBackward(l, i, backtrack, .{ .how = how, .data = rule + 2, .base = defs[0] })) continue;
                    if (!try ctx.matchLookahead(l, at.at[at.n - 1], ahead, .{ .how = how, .data = ahead_at + 2, .base = defs[2] })) continue;
                    return try ctx.applyRecords(&at, records_at + 2, try b.u16At(records_at));
                }
                return null;
            },
            3 => {
                const backtrack = try b.u16At(sub + 2);
                const input_at = sub + 4 + @as(u64, backtrack) * 2;
                const input = try b.u16At(input_at);
                if (input == 0) return null;
                const ahead_at = input_at + 2 + @as(u64, input) * 2;
                const ahead = try b.u16At(ahead_at);
                const records_at = ahead_at + 2 + @as(u64, ahead) * 2;
                const m: Matcher = .{ .how = .coverage, .data = input_at + 2, .base = sub };
                if (!try m.matches(b, 0, glyph)) return null;
                var at: Positions = .{};
                if (!try ctx.matchForward(l, i, input - 1, m, 1, &at)) return null;
                if (!try ctx.matchBackward(l, i, backtrack, .{ .how = .coverage, .data = sub + 4, .base = sub })) return null;
                if (!try ctx.matchLookahead(l, at.at[at.n - 1], ahead, .{ .how = .coverage, .data = ahead_at + 2, .base = sub })) return null;
                return try ctx.applyRecords(&at, records_at + 2, try b.u16At(records_at));
            },
            else => return null,
        }
    }

    // ---- GPOS ----

    fn positionAt(ctx: *Ctx, l: Lookup, t: u16, sub: u64, i: usize) Error!?usize {
        const b = ctx.b;
        const glyph = ctx.glyphAt(i);
        switch (t) {
            1 => {
                const index = (try coverageIndex(b, sub + try b.u16At(sub + 2), glyph)) orelse return null;
                const format = try b.u16At(sub + 4);
                switch (try b.u16At(sub)) {
                    1 => try ctx.adjust(i, sub + 6, format),
                    2 => {
                        if (index >= try b.u16At(sub + 6)) return error.InvalidFont;
                        try ctx.adjust(i, sub + 8 + @as(u64, index) * valueSize(format), format);
                    },
                    else => return null,
                }
                return i + 1;
            },
            2 => {
                const j = ctx.nextOf(l, i) orelse return null;
                const f1 = try b.u16At(sub + 4);
                const f2 = try b.u16At(sub + 6);
                const index = (try coverageIndex(b, sub + try b.u16At(sub + 2), glyph)) orelse return null;
                const second = ctx.glyphAt(j);
                const s1 = valueSize(f1);
                const s2 = valueSize(f2);
                const rec: u64 = switch (try b.u16At(sub)) {
                    1 => blk: {
                        if (index >= try b.u16At(sub + 8)) return error.InvalidFont;
                        const set = sub + try b.u16At(sub + 10 + @as(u64, index) * 2);
                        const size = 2 + s1 + s2;
                        var lo: u64 = 0;
                        var hi: u64 = try b.u16At(set);
                        while (lo < hi) {
                            const mid = (lo + hi) / 2;
                            const r = set + 2 + mid * size;
                            const g = try b.u16At(r);
                            if (g < second) lo = mid + 1 else if (g > second) hi = mid else break :blk r + 2;
                        }
                        return null;
                    },
                    2 => blk: {
                        const c1 = try classOf(b, sub + try b.u16At(sub + 8), glyph);
                        const c2 = try classOf(b, sub + try b.u16At(sub + 10), second);
                        const n1 = try b.u16At(sub + 12);
                        const n2 = try b.u16At(sub + 14);
                        if (c1 >= n1 or c2 >= n2) return error.InvalidFont;
                        break :blk sub + 16 + (@as(u64, c1) * n2 + c2) * (s1 + s2);
                    },
                    else => return null,
                };
                try ctx.adjust(i, rec, f1);
                try ctx.adjust(j, rec + s1, f2);
                return if (f2 != 0) j + 1 else j;
            },
            3 => return ctx.cursive(l, sub, i),
            4, 5, 6 => return ctx.attachMark(l, t, sub, i),
            7 => return ctx.context(l, sub, i),
            8 => return ctx.chainContext(l, sub, i),
            else => return null,
        }
    }

    /// Adds a value record to the glyph at `i`.
    fn adjust(ctx: *Ctx, i: usize, rec: u64, format: u16) Error!void {
        const info = &ctx.buf.info[i];
        var at = rec;
        if (format & 0x1 != 0) {
            info.x_offset += try ctx.b.i16At(at);
            at += 2;
        }
        if (format & 0x2 != 0) {
            info.y_offset += try ctx.b.i16At(at);
            at += 2;
        }
        if (format & 0x4 != 0) info.x_advance += try ctx.b.i16At(at);
    }

    fn anchor(ctx: *const Ctx, at: u64) Error![2]i32 {
        if (try ctx.b.u16At(at) -% 1 > 2) return error.InvalidFont;
        return .{ try ctx.b.i16At(at + 2), try ctx.b.i16At(at + 4) };
    }

    fn attachMark(ctx: *Ctx, l: Lookup, t: u16, sub: u64, i: usize) Error!?usize {
        const b = ctx.b;
        const buf = ctx.buf;
        if (try b.u16At(sub) != 1) return null;
        const mark = buf.info[i];
        if (mark.class != mark_class) return null;
        const mark_index = (try coverageIndex(b, sub + try b.u16At(sub + 2), mark.glyph)) orelse return null;
        const classes = try b.u16At(sub + 6);
        const mark_array = sub + try b.u16At(sub + 8);
        const base_array = sub + try b.u16At(sub + 10);
        if (mark_index >= try b.u16At(mark_array)) return error.InvalidFont;
        const mark_rec = mark_array + 2 + @as(u64, mark_index) * 4;
        const class = try b.u16At(mark_rec);
        if (class >= classes) return error.InvalidFont;
        const mark_anchor = try ctx.anchor(mark_array + try b.u16At(mark_rec + 2));

        // What it attaches to: the previous base (or ligature), skipping
        // marks; for mark-to-mark, the previous mark.
        var j = i;
        while (true) {
            j = ctx.prevOf(l, j) orelse return null;
            if (t == 6 or buf.info[j].class != mark_class) break;
        }
        const base = buf.info[j];
        if (t == 6 and base.class != mark_class) return null;
        const base_index = (try coverageIndex(b, sub + try b.u16At(sub + 4), base.glyph)) orelse return null;
        if (base_index >= try b.u16At(base_array)) return error.InvalidFont;
        const anchor_off: u16 = switch (t) {
            5 => blk: {
                const attach = base_array + try b.u16At(base_array + 2 + @as(u64, base_index) * 2);
                const components = try b.u16At(attach);
                if (components == 0) return null;
                const comp: u16 = if (mark.lig_id == base.lig_id and mark.lig_comp > 0) @min(mark.lig_comp, components) - 1 else components - 1;
                const off = try b.u16At(attach + 2 + (@as(u64, comp) * classes + class) * 2);
                if (off == 0) return null;
                break :blk @intCast(off + (attach - base_array));
            },
            else => try b.u16At(base_array + 2 + (@as(u64, base_index) * classes + class) * 2),
        };
        if (anchor_off == 0) return null;
        const base_anchor = try ctx.anchor(base_array + anchor_off);
        const info = &buf.info[i];
        info.attach = @intCast(j);
        info.cursive = false;
        info.x_offset = base_anchor[0] - mark_anchor[0];
        info.y_offset = base_anchor[1] - mark_anchor[1];
        return i + 1;
    }

    /// Cursive attachment: the glyph's entry joins the previous glyph's
    /// exit (in reading order).
    fn cursive(ctx: *Ctx, l: Lookup, sub: u64, i: usize) Error!?usize {
        const b = ctx.b;
        const buf = ctx.buf;
        if (try b.u16At(sub) != 1) return null;
        const cov = sub + try b.u16At(sub + 2);
        const count = try b.u16At(sub + 4);
        const this = (try coverageIndex(b, cov, buf.info[i].glyph)) orelse return null;
        const j = ctx.nextOf(l, i) orelse return null;
        const next = (try coverageIndex(b, cov, buf.info[j].glyph)) orelse return null;
        if (this >= count or next >= count) return error.InvalidFont;
        const exit_off = try b.u16At(sub + 6 + @as(u64, this) * 4 + 2);
        const entry_off = try b.u16At(sub + 6 + @as(u64, next) * 4);
        if (exit_off == 0 or entry_off == 0) return null;
        const exit = try ctx.anchor(sub + exit_off);
        const entry = try ctx.anchor(sub + entry_off);
        const first = &buf.info[i];
        const second = &buf.info[j];
        // Advances: in reading order, the first glyph ends at its exit and
        // the second starts at its entry.
        if (first.rtl) {
            // The first glyph is on the right: its left edge is its exit.
            const d = exit[0] + first.x_offset;
            first.x_advance -= d;
            first.x_offset -= d;
            second.x_advance = entry[0] + second.x_offset;
        } else {
            first.x_advance = exit[0] + first.x_offset;
            const d = entry[0] + second.x_offset;
            second.x_advance -= d;
            second.x_offset -= d;
        }
        // Vertically, the glyph after hangs from the one before (or the
        // reverse, with the right-to-left flag).
        if (l.flag & Lookup.right_to_left != 0) {
            first.attach = @intCast(j);
            first.cursive = true;
            first.y_offset = entry[1] - exit[1];
        } else {
            second.attach = @intCast(i);
            second.cursive = true;
            second.y_offset = exit[1] - entry[1];
        }
        return j;
    }
};

fn valueSize(format: u16) u64 {
    return @as(u64, @popCount(format & 0xff)) * 2;
}
