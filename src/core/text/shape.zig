// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Shaping: turns a line's characters into positioned glyphs with the
//! font's OpenType tables (opentype.zig). Arabic letters take their joining
//! forms (isolated, initial, medial, final), ligatures form, and marks are
//! placed on their base. Fonts without OpenType Arabic forms use the
//! Unicode presentation forms they map instead (bitmap fonts too).
//!
//! layout.zig shapes only lines that need it (right-to-left text,
//! combining marks); other text keeps the simple path (character map and
//! kerning).

const std = @import("std");
const builtin = @import("builtin");
const bidi = @import("bidi.zig");
const ot = @import("opentype.zig");
const tt = @import("truetype.zig");
const layout = @import("layout.zig");
const Font = tt.Font;
const tag = tt.tag;
pub const Info = ot.Info;
pub const Buffer = ot.Buffer;

/// Whether fonts' OpenType tables are used. An app can leave them out
/// (about 25 KB of code, for microcontrollers) by declaring in its root
/// file `pub const zigulee_options = .{ .opentype_shaping = false };`: lines
/// are still reordered, and Arabic letters still join with the fonts'
/// presentation forms.
pub const opentype_shaping = blk: {
    const root = @import("root");
    if (@hasDecl(root, "zigulee_options") and @hasField(@TypeOf(root.zigulee_options), "opentype_shaping"))
        break :blk root.zigulee_options.opentype_shaping;
    break :blk true;
};

/// Characters per shaped line: longer lines take the simple path. Smaller
/// on microcontrollers, where the buffers live on a small stack.
pub const max_chars = if (builtin.os.tag == .freestanding and !builtin.cpu.arch.isWasm()) 64 else 256;

// Feature masks.
const global = 1;
const isol = 2;
const fina = 4;
const medi = 8;
const init = 16;

const arabic_gsub = [_]ot.Feature{
    .{ .tag = tag("ccmp"), .mask = global },
    .{ .tag = tag("locl"), .mask = global },
    .{ .tag = tag("isol"), .mask = isol },
    .{ .tag = tag("fina"), .mask = fina },
    .{ .tag = tag("medi"), .mask = medi },
    .{ .tag = tag("init"), .mask = init },
    .{ .tag = tag("rlig"), .mask = global },
    .{ .tag = tag("calt"), .mask = global },
    .{ .tag = tag("liga"), .mask = global },
};

const other_gsub = [_]ot.Feature{
    .{ .tag = tag("ccmp"), .mask = global },
    .{ .tag = tag("locl"), .mask = global },
    .{ .tag = tag("rlig"), .mask = global },
};

const gpos_features = [_]ot.Feature{
    .{ .tag = tag("kern"), .mask = global },
    .{ .tag = tag("mark"), .mask = global },
    .{ .tag = tag("mkmk"), .mask = global },
    .{ .tag = tag("curs"), .mask = global },
    .{ .tag = tag("dist"), .mask = global },
};

/// Whether a character makes its line need shaping.
pub fn needsShaping(cp: u21) bool {
    return bidi.isRtlCodePoint(cp) or (cp >= 0x300 and bidi.class(cp) == .NSM);
}

pub fn isArabic(cp: u21) bool {
    return (cp >= 0x600 and cp <= 0x6ff) or (cp >= 0x750 and cp <= 0x77f) or (cp >= 0x8a0 and cp <= 0x8ff) or
        (cp >= 0xfb50 and cp <= 0xfdff) or (cp >= 0xfe70 and cp <= 0xfeff);
}

fn isHebrew(cp: u21) bool {
    return (cp >= 0x590 and cp <= 0x5ff) or (cp >= 0xfb1d and cp <= 0xfb4f);
}

// ---- Arabic joining ----

/// How a character joins its neighbors: U none, R to the one before (on
/// its right), D both sides, C joins both without changing (tatweel, ZWJ),
/// T transparent (marks: skipped).
pub const Joining = enum { U, R, D, C, T };

const JoinRange = struct { first: u21, last: u21, type: Joining };

/// From Unicode's ArabicShaping.txt (Arabic blocks); letters not listed are
/// U, marks T.
const join_ranges = [_]JoinRange{
    .{ .first = 0x0620, .last = 0x0620, .type = .D },
    .{ .first = 0x0622, .last = 0x0625, .type = .R },
    .{ .first = 0x0626, .last = 0x0626, .type = .D },
    .{ .first = 0x0627, .last = 0x0627, .type = .R },
    .{ .first = 0x0628, .last = 0x0628, .type = .D },
    .{ .first = 0x0629, .last = 0x0629, .type = .R },
    .{ .first = 0x062A, .last = 0x062E, .type = .D },
    .{ .first = 0x062F, .last = 0x0632, .type = .R },
    .{ .first = 0x0633, .last = 0x063F, .type = .D },
    .{ .first = 0x0640, .last = 0x0640, .type = .C },
    .{ .first = 0x0641, .last = 0x0647, .type = .D },
    .{ .first = 0x0648, .last = 0x0648, .type = .R },
    .{ .first = 0x0649, .last = 0x064A, .type = .D },
    .{ .first = 0x066E, .last = 0x066F, .type = .D },
    .{ .first = 0x0671, .last = 0x0673, .type = .R },
    .{ .first = 0x0675, .last = 0x0677, .type = .R },
    .{ .first = 0x0678, .last = 0x0687, .type = .D },
    .{ .first = 0x0688, .last = 0x0699, .type = .R },
    .{ .first = 0x069A, .last = 0x06BF, .type = .D },
    .{ .first = 0x06C0, .last = 0x06C0, .type = .R },
    .{ .first = 0x06C1, .last = 0x06C2, .type = .D },
    .{ .first = 0x06C3, .last = 0x06CB, .type = .R },
    .{ .first = 0x06CC, .last = 0x06CC, .type = .D },
    .{ .first = 0x06CD, .last = 0x06CD, .type = .R },
    .{ .first = 0x06CE, .last = 0x06CE, .type = .D },
    .{ .first = 0x06CF, .last = 0x06CF, .type = .R },
    .{ .first = 0x06D0, .last = 0x06D1, .type = .D },
    .{ .first = 0x06D2, .last = 0x06D3, .type = .R },
    .{ .first = 0x06D5, .last = 0x06D5, .type = .R },
    .{ .first = 0x06EE, .last = 0x06EF, .type = .R },
    .{ .first = 0x06FA, .last = 0x06FC, .type = .D },
    .{ .first = 0x06FF, .last = 0x06FF, .type = .D },
    .{ .first = 0x0750, .last = 0x0758, .type = .D },
    .{ .first = 0x0759, .last = 0x075B, .type = .R },
    .{ .first = 0x075C, .last = 0x076A, .type = .D },
    .{ .first = 0x076B, .last = 0x076C, .type = .R },
    .{ .first = 0x076D, .last = 0x0770, .type = .D },
    .{ .first = 0x0771, .last = 0x0771, .type = .R },
    .{ .first = 0x0772, .last = 0x0772, .type = .D },
    .{ .first = 0x0773, .last = 0x0774, .type = .R },
    .{ .first = 0x0775, .last = 0x0777, .type = .D },
    .{ .first = 0x0778, .last = 0x0779, .type = .R },
    .{ .first = 0x077A, .last = 0x077F, .type = .D },
    .{ .first = 0x08A0, .last = 0x08A9, .type = .D },
    .{ .first = 0x08AA, .last = 0x08AC, .type = .R },
    .{ .first = 0x08AE, .last = 0x08AE, .type = .R },
    .{ .first = 0x08AF, .last = 0x08B0, .type = .D },
    .{ .first = 0x08B1, .last = 0x08B2, .type = .R },
    .{ .first = 0x08B3, .last = 0x08B4, .type = .D },
    .{ .first = 0x08B6, .last = 0x08B8, .type = .D },
    .{ .first = 0x08B9, .last = 0x08B9, .type = .R },
    .{ .first = 0x08BA, .last = 0x08BD, .type = .D },
};

comptime {
    for (join_ranges[1..], join_ranges[0 .. join_ranges.len - 1]) |r, prev| {
        if (r.first > r.last or r.first <= prev.last) @compileError("join_ranges must be sorted and disjoint");
    }
}

pub fn joining(cp: u21) Joining {
    if (cp == 0x200D) return .C;
    if (cp >= 0x0620 and cp <= 0x08BD) {
        var lo: usize = 0;
        var hi: usize = join_ranges.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const r = join_ranges[mid];
            if (cp < r.first) hi = mid else if (cp > r.last) lo = mid + 1 else return r.type;
        }
    }
    return switch (bidi.class(cp)) {
        .NSM => .T,
        .BN => if (cp == 0x200C) .U else .T,
        else => .U,
    };
}

pub const Form = enum(u8) { none, isol, fina, medi, init };

/// The joining form of each character.
pub fn joiningForms(cps: []const u21, forms: []Form) void {
    var prev: ?usize = null; // the last non-transparent character
    for (cps, 0..) |cp, k| {
        forms[k] = .none;
        const t = joining(cp);
        if (t == .T) continue;
        if (t == .R or t == .D) forms[k] = .isol;
        if (prev) |p| {
            const pt = joining(cps[p]);
            // Joined: the previous one joins forward, this one backward.
            if ((pt == .D or pt == .C) and (t == .R or t == .D or t == .C)) {
                forms[p] = switch (forms[p]) {
                    .isol => .init,
                    .fina => .medi,
                    else => forms[p],
                };
                if (forms[k] == .isol) forms[k] = .fina;
            }
        }
        prev = k;
    }
}

fn formMask(f: Form) u16 {
    return switch (f) {
        .none => 0,
        .isol => isol,
        .fina => fina,
        .medi => medi,
        .init => init,
    };
}

// ---- Presentation forms (fonts without OpenType Arabic forms) ----

/// For U+0621..U+064A: the first presentation form (isolated) in Arabic
/// Presentation Forms-B, and how many forms (1 none joining, 2 right
/// joining, 4 dual joining); 0 for characters without.
const presentation = blk: {
    var table: [0x64A - 0x621 + 1]struct { first: u16, count: u8 } = undefined;
    var next: u16 = 0xFE80;
    for (&table, 0x621..) |*e, cp| {
        if (cp >= 0x63B and cp <= 0x640) {
            e.* = .{ .first = 0, .count = 0 };
            continue;
        }
        // Alef maksura joins both ways, but has only two forms here.
        const count: u8 = if (cp == 0x649) 2 else switch (joining(cp)) {
            .D => 4,
            .R => 2,
            else => 1,
        };
        e.* = .{ .first = next, .count = count };
        next += count;
    }
    if (next != 0xFEF5) @compileError("presentation forms table");
    break :blk table;
};

/// The presentation form of `cp` in `form`, if Unicode has one.
pub fn presentationForm(cp: u21, form: Form) ?u21 {
    if (cp < 0x621 or cp > 0x64A) return null;
    const e = presentation[cp - 0x621];
    const k: u8 = switch (form) {
        .none => return null,
        .isol => 0,
        .fina => 1,
        .init => 2,
        .medi => 3,
    };
    if (k >= e.count) return null;
    return e.first + k;
}

/// Lam followed by an alef: the ligature's isolated form.
fn lamAlef(alef: u21) ?u21 {
    return switch (alef) {
        0x622 => 0xFEF5,
        0x623 => 0xFEF7,
        0x625 => 0xFEF9,
        0x627 => 0xFEFB,
        else => null,
    };
}

fn applyPresentationForms(font: *const Font, cps: []const u21, forms: []const Form, buf: *Buffer) void {
    var i = buf.lo;
    while (i < buf.hi) : (i += 1) {
        const info = &buf.info[i];
        if (info.char_end != info.char + 1) continue;
        const cp = cps[info.char];
        const form = forms[info.char];
        if (cp == 0x644 and (form == .init or form == .medi)) {
            // Lam-alef: the next non-mark glyph.
            var j = i + 1;
            while (j < buf.hi and buf.info[j].class == ot.mark_class) j += 1;
            if (j < buf.hi and buf.info[j].char_end == buf.info[j].char + 1) {
                if (lamAlef(cps[buf.info[j].char])) |lig| {
                    const g = font.glyphIndex(lig + @intFromBool(form == .medi));
                    if (g != 0) {
                        info.glyph = g;
                        info.char_end = buf.info[j].char_end;
                        buf.remove(j);
                        continue;
                    }
                }
            }
        }
        const pf = presentationForm(cp, form) orelse continue;
        const g = font.glyphIndex(pf);
        if (g != 0) info.glyph = g;
    }
}

// ---- Shaping ----

/// Shapes `cps` (with their bidi levels) into `buf` (cleared first), in
/// logical order. Positions are in font units of each glyph's font.
pub fn shape(m: layout.Metrics, cps: []const u21, levels: []const u8, buf: *Buffer) void {
    buf.len = 0;
    var forms: [max_chars]Form = undefined;
    joiningForms(cps, forms[0..cps.len]);
    for (cps, 0..) |cp, k| {
        if (buf.len == buf.info.len) break;
        const rtl = levels[k] % 2 == 1;
        var g = m.glyph(if (rtl) bidi.mirror(cp) else cp);
        const is_mark = bidi.class(cp) == .NSM;
        // Marks stay in their base's font, when it has them.
        if (is_mark and buf.len > 0) {
            const base = buf.info[buf.len - 1];
            if (base.font != g.font) if (m.fontOf(.{ .id = base.glyph, .font = base.font })) |f| {
                const id = f.glyphIndex(cp);
                if (id != 0) g = .{ .id = id, .font = base.font };
            };
        }
        buf.info[buf.len] = .{
            .glyph = g.id,
            .font = g.font,
            .char = @intCast(k),
            .char_end = @intCast(k + 1),
            .rtl = rtl,
            .class = if (is_mark) ot.mark_class else ot.base_class,
            .mask = global | formMask(forms[k]),
        };
        buf.len += 1;
    }
    // Runs of one font.
    var lo: usize = 0;
    while (lo < buf.len) {
        var hi = lo + 1;
        while (hi < buf.len and buf.info[hi].font == buf.info[lo].font) hi += 1;
        buf.lo = lo;
        buf.hi = hi;
        if (m.fontOf(.{ .id = 0, .font = buf.info[lo].font })) |f| shapeRun(f, cps, forms[0..cps.len], buf);
        lo = buf.hi;
    }
    buf.lo = 0;
    buf.hi = buf.len;
}

fn shapeRun(font: *const Font, cps: []const u21, forms: []const Form, buf: *Buffer) void {
    var arabic = false;
    var hebrew = false;
    for (buf.info[buf.lo..buf.hi]) |info| {
        const cp = cps[info.char];
        arabic = arabic or isArabic(cp);
        hebrew = hebrew or isHebrew(cp);
    }
    const script = if (arabic) tag("arab") else if (hebrew) tag("hebr") else tag("latn");
    if (!opentype_shaping) {
        if (arabic) applyPresentationForms(font, cps, forms, buf);
        for (buf.info[buf.lo..buf.hi]) |*info| info.x_advance = font.advanceWidth(info.glyph);
        legacyKerning(font, buf);
        placeMarks(font, buf);
        return;
    }
    const gdef: ot.Gdef = .of(font);
    if (gdef.glyph_classes != 0) for (buf.info[buf.lo..buf.hi]) |*info| {
        const c = gdef.class(font.bytes(), info.glyph);
        if (c != 0) info.class = c;
    };

    const gsub = ot.collect(font, font.gsub, script, if (arabic) &arabic_gsub else &other_gsub);
    if (arabic and !gsub.has(isol | fina | medi | init)) applyPresentationForms(font, cps, forms, buf);
    ot.apply(font, .gsub, &gsub, buf);

    for (buf.info[buf.lo..buf.hi]) |*info| info.x_advance = font.advanceWidth(info.glyph);
    if (font.gpos != null) {
        const gpos = ot.collect(font, font.gpos, script, &gpos_features);
        ot.apply(font, .gpos, &gpos, buf);
    } else legacyKerning(font, buf);
    placeMarks(font, buf);
}

/// The legacy kerning table: pairs as shown, left then right.
fn legacyKerning(font: *const Font, buf: *Buffer) void {
    var prev: ?usize = null;
    for (buf.lo..buf.hi) |i| {
        if (buf.info[i].class == ot.mark_class) continue;
        if (prev) |p| {
            const a = buf.info[p];
            const b = buf.info[i];
            buf.info[p].x_advance += if (b.rtl) font.kerning(b.glyph, a.glyph) else font.kerning(a.glyph, b.glyph);
        }
        prev = i;
    }
}

fn placeMarks(font: *const Font, buf: *Buffer) void {
    // Attached marks take no room; right-to-left marks the font does not
    // place are centered on their base.
    for (buf.lo..buf.hi) |i| {
        const info = &buf.info[i];
        if (info.attach != ot.no_attach) {
            if (!info.cursive) info.x_advance = 0;
            continue;
        }
        if (info.class != ot.mark_class or !info.rtl or i == buf.lo) continue;
        var j = i - 1;
        while (j > buf.lo and buf.info[j].class == ot.mark_class) j -= 1;
        if (buf.info[j].class == ot.mark_class) continue;
        const base = buf.info[j];
        info.attach = @intCast(j);
        info.x_advance = 0;
        if (font.glyphBox(base.glyph)) |bb| if (font.glyphBox(info.glyph)) |mb| {
            info.x_offset = @divTrunc(@as(i32, bb.x_min) + bb.x_max - mb.x_min - mb.x_max, 2);
            continue;
        };
        info.x_offset = @divTrunc(base.x_advance, 2);
    }
}

pub const ot_no_attach = ot.no_attach;
