// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Shaping tests, with fonts built in memory: their GSUB, GPOS and GDEF
//! tables written by the small builder below.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const gpa = testing.allocator;
const Font = @import("truetype.zig").Font;
const layout = @import("layout.zig");
const shape = @import("shape.zig");
const test_font = @import("test_font.zig");
const text_edit = @import("../text_edit.zig");

// ---- Writing OpenType layout tables ----

const W = struct {
    a: Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn u16_(w: *W, v: u16) void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .big);
        w.bytes.appendSlice(w.a, &b) catch @panic("OOM");
    }
    fn i16_(w: *W, v: i16) void {
        w.u16_(@bitCast(v));
    }
    fn tag(w: *W, t: *const [4]u8) void {
        w.bytes.appendSlice(w.a, t) catch @panic("OOM");
    }
    fn raw(w: *W, b: []const u8) void {
        w.bytes.appendSlice(w.a, b) catch @panic("OOM");
    }
    fn pos(w: *const W) u16 {
        return @intCast(w.bytes.items.len);
    }
    fn patch(w: *W, at: usize, v: u16) void {
        std.mem.writeInt(u16, w.bytes.items[at..][0..2], v, .big);
    }
    fn done(w: *W) []u8 {
        return w.bytes.toOwnedSlice(w.a) catch @panic("OOM");
    }
};

fn coverage(w: *W, glyphs: []const u16) void {
    w.u16_(1);
    w.u16_(@intCast(glyphs.len));
    for (glyphs) |g| w.u16_(g);
}

const LookupDef = struct { type: u16, flag: u16 = 0, subtable: []const u8 };
const FeatureDef = struct { tag: *const [4]u8, lookups: []const u16 };

/// A GSUB or GPOS table: one script, its default language with every
/// feature, one subtable per lookup.
fn layoutTable(a: Allocator, script: *const [4]u8, features: []const FeatureDef, lookups: []const LookupDef) []u8 {
    var w: W = .{ .a = a };
    w.u16_(1);
    w.u16_(0);
    w.u16_(10);
    w.u16_(0); // feature list
    w.u16_(0); // lookup list
    // Script list: one script, a default LangSys with all features.
    w.u16_(1);
    w.tag(script);
    w.u16_(8);
    w.u16_(4);
    w.u16_(0);
    w.u16_(0);
    w.u16_(0xffff);
    w.u16_(@intCast(features.len));
    for (0..features.len) |i| w.u16_(@intCast(i));
    // Feature list.
    const fl = w.pos();
    w.patch(6, fl);
    w.u16_(@intCast(features.len));
    const records = w.pos();
    for (features) |f| {
        w.tag(f.tag);
        w.u16_(0);
    }
    for (features, 0..) |f, i| {
        w.patch(records + i * 6 + 4, w.pos() - fl);
        w.u16_(0);
        w.u16_(@intCast(f.lookups.len));
        for (f.lookups) |l| w.u16_(l);
    }
    // Lookup list.
    const ll = w.pos();
    w.patch(8, ll);
    w.u16_(@intCast(lookups.len));
    const offsets = w.pos();
    for (lookups) |_| w.u16_(0);
    for (lookups, 0..) |l, i| {
        const at = w.pos();
        w.patch(offsets + i * 2, at - ll);
        w.u16_(l.type);
        w.u16_(l.flag);
        w.u16_(1);
        w.u16_(8);
        w.raw(l.subtable);
    }
    return w.done();
}

/// Single substitution, format 2 (`from` sorted).
fn singleSubst(a: Allocator, from: []const u16, to: []const u16) []u8 {
    var w: W = .{ .a = a };
    w.u16_(2);
    w.u16_(@intCast(6 + to.len * 2));
    w.u16_(@intCast(to.len));
    for (to) |g| w.u16_(g);
    coverage(&w, from);
    return w.done();
}

/// Single substitution, format 1: adds `delta`.
fn singleSubstDelta(a: Allocator, from: []const u16, delta: i16) []u8 {
    var w: W = .{ .a = a };
    w.u16_(1);
    w.u16_(6);
    w.i16_(delta);
    coverage(&w, from);
    return w.done();
}

fn multipleSubst(a: Allocator, glyph: u16, sequence: []const u16) []u8 {
    var w: W = .{ .a = a };
    w.u16_(1);
    w.u16_(0); // coverage
    w.u16_(1);
    w.u16_(8);
    w.u16_(@intCast(sequence.len));
    for (sequence) |g| w.u16_(g);
    w.patch(2, w.pos());
    coverage(&w, &.{glyph});
    return w.done();
}

fn ligatureSubst(a: Allocator, components: []const u16, ligature: u16) []u8 {
    var w: W = .{ .a = a };
    w.u16_(1);
    w.u16_(0); // coverage
    w.u16_(1);
    w.u16_(8); // the set
    w.u16_(1);
    w.u16_(4); // the ligature, from the set
    w.u16_(ligature);
    w.u16_(@intCast(components.len));
    for (components[1..]) |g| w.u16_(g);
    w.patch(2, w.pos());
    coverage(&w, components[0..1]);
    return w.done();
}

/// Chained context, format 3: one glyph per coverage; applies `lookup` to
/// the first input glyph.
fn chainContext(a: Allocator, backtrack: []const u16, input: []const u16, lookahead: []const u16, lookup: u16) []u8 {
    var w: W = .{ .a = a };
    w.u16_(3);
    var patches: [16]usize = undefined;
    var n: usize = 0;
    for ([_][]const u16{ backtrack, input, lookahead }) |seq| {
        w.u16_(@intCast(seq.len));
        for (seq) |_| {
            patches[n] = w.pos();
            n += 1;
            w.u16_(0);
        }
    }
    w.u16_(1);
    w.u16_(0);
    w.u16_(lookup);
    var k: usize = 0;
    for ([_][]const u16{ backtrack, input, lookahead }) |seq| for (seq) |g| {
        w.patch(patches[k], w.pos());
        k += 1;
        coverage(&w, &.{g});
    };
    return w.done();
}

fn pairPos(a: Allocator, first: u16, second: u16, x_advance: i16) []u8 {
    var w: W = .{ .a = a };
    w.u16_(1);
    w.u16_(0); // coverage
    w.u16_(0x4);
    w.u16_(0);
    w.u16_(1);
    w.u16_(12);
    w.u16_(1);
    w.u16_(second);
    w.i16_(x_advance);
    w.patch(2, w.pos());
    coverage(&w, &.{first});
    return w.done();
}

/// Mark-to-base (or mark-to-mark, the same layout) with one mark class.
fn markAttach(a: Allocator, mark: u16, mark_anchor: [2]i16, bases: []const u16, base_anchor: [2]i16) []u8 {
    var w: W = .{ .a = a };
    w.u16_(1);
    w.u16_(0); // mark coverage
    w.u16_(0); // base coverage
    w.u16_(1);
    w.u16_(0); // mark array
    w.u16_(0); // base array
    w.patch(2, w.pos());
    coverage(&w, &.{mark});
    w.patch(4, w.pos());
    coverage(&w, bases);
    const ma = w.pos();
    w.patch(8, ma);
    w.u16_(1);
    w.u16_(0);
    w.u16_(6);
    w.u16_(1);
    w.i16_(mark_anchor[0]);
    w.i16_(mark_anchor[1]);
    const ba = w.pos();
    w.patch(10, ba);
    w.u16_(@intCast(bases.len));
    const anchor_at: u16 = @intCast(2 + bases.len * 2);
    for (bases) |_| w.u16_(anchor_at);
    w.u16_(1);
    w.i16_(base_anchor[0]);
    w.i16_(base_anchor[1]);
    return w.done();
}

/// GDEF with glyph classes.
fn gdef(a: Allocator, classes: []const [2]u16) []u8 {
    var w: W = .{ .a = a };
    w.u16_(1);
    w.u16_(0);
    w.u16_(12);
    w.u16_(0);
    w.u16_(0);
    w.u16_(0);
    w.u16_(2);
    w.u16_(@intCast(classes.len));
    for (classes) |c| {
        w.u16_(c[0]);
        w.u16_(c[0]);
        w.u16_(c[1]);
    }
    return w.done();
}

// ---- Fonts ----

/// A glyph (no outline: shaping only needs advances).
fn box(advance: u16) test_font.Glyph {
    return .{ .empty = .{ .advance = advance } };
}

// Glyphs of the Arabic test font.
const beh = 10;
const beh_init = 11;
const beh_fina = 12;
const beh_fina_after_init = 13;
const alef = 20;
const alef_fina = 22;
const lam = 30;
const lam_alef = 40;
const high_hamza = 50;
const fatha = 60;

/// A font with Arabic forms, a ligature, a contextual alternate, a
/// decomposition, kerning and mark positioning.
pub fn arabicFont(a: Allocator) ![]u8 {
    var glyphs: [61]test_font.Glyph = @splat(.{ .empty = .{ .advance = 0 } });
    glyphs[0] = box(500);
    const advances = [_][2]u16{ .{ beh, 500 }, .{ beh_init, 400 }, .{ beh_fina, 450 }, .{ beh_fina_after_init, 420 }, .{ alef, 200 }, .{ alef_fina, 220 }, .{ lam, 300 }, .{ lam_alef, 480 }, .{ 51, 110 }, .{ 52, 120 }, .{ fatha, 0 }, .{ 1, 250 } };
    for (advances) |adv| glyphs[adv[0]] = box(adv[1]);
    const gsub_lookups = [_]LookupDef{
        .{ .type = 1, .subtable = singleSubst(a, &.{beh}, &.{beh_init}) }, // 0 init
        .{ .type = 1, .subtable = singleSubstDelta(a, &.{ beh, alef }, 2) }, // 1 fina
        .{ .type = 4, .flag = 0x8, .subtable = ligatureSubst(a, &.{ lam, alef_fina }, lam_alef) }, // 2 rlig
        .{ .type = 6, .subtable = chainContext(a, &.{beh_init}, &.{beh_fina}, &.{}, 4) }, // 3 calt
        .{ .type = 1, .subtable = singleSubst(a, &.{beh_fina}, &.{beh_fina_after_init}) }, // 4 (nested)
        .{ .type = 2, .subtable = multipleSubst(a, high_hamza, &.{ 51, 52 }) }, // 5 ccmp
    };
    defer for (gsub_lookups) |l| a.free(l.subtable);
    const gsub = layoutTable(a, "arab", &.{
        .{ .tag = "ccmp", .lookups = &.{5} },
        .{ .tag = "init", .lookups = &.{0} },
        .{ .tag = "fina", .lookups = &.{1} },
        .{ .tag = "rlig", .lookups = &.{2} },
        .{ .tag = "calt", .lookups = &.{3} },
    }, &gsub_lookups);
    defer a.free(gsub);
    const gpos_lookups = [_]LookupDef{
        .{ .type = 2, .subtable = pairPos(a, beh_init, beh_fina_after_init, -50) },
        .{ .type = 4, .subtable = markAttach(a, fatha, .{ 100, 0 }, &.{ beh, beh_init, beh_fina, beh_fina_after_init }, .{ 250, 700 }) },
    };
    defer for (gpos_lookups) |l| a.free(l.subtable);
    const gpos = layoutTable(a, "arab", &.{
        .{ .tag = "kern", .lookups = &.{0} },
        .{ .tag = "mark", .lookups = &.{1} },
    }, &gpos_lookups);
    defer a.free(gpos);
    const classes = gdef(a, &.{ .{ lam_alef, 2 }, .{ fatha, 3 } });
    defer a.free(classes);
    return test_font.build(a, &glyphs, &.{
        .{ .codepoint = ' ', .glyph = 1 },
        .{ .codepoint = 0x628, .glyph = beh },
        .{ .codepoint = 0x627, .glyph = alef },
        .{ .codepoint = 0x644, .glyph = lam },
        .{ .codepoint = 0x674, .glyph = high_hamza },
        .{ .codepoint = 0x64E, .glyph = fatha },
    }, .{ .tables = &.{ .{ .tag = "GSUB", .data = gsub }, .{ .tag = "GPOS", .data = gpos }, .{ .tag = "GDEF", .data = classes } } });
}

const Shaped = struct { glyph: u16, byte: usize, len: usize, x: f32, advance: f32, dx: f32 = 0, dy: f32 = 0 };

/// The glyphs of `text` (one line) in the order shown, or in logical order.
fn glyphsOf(font: *const Font, text: []const u8, visual: bool, out: []Shaped) []Shaped {
    const m: layout.Metrics = .init(font, 10);
    const line: layout.Line = .{ .start = 0, .end = text.len, .width = 0 };
    var it: layout.GlyphIterator = if (visual) .initMetrics(m, text, line) else .initLogical(m, text, line);
    var n: usize = 0;
    while (it.next()) |g| : (n += 1) out[n] = .{ .glyph = g.glyph, .byte = g.byte, .len = g.len, .x = g.x, .advance = g.advance, .dx = g.dx, .dy = g.dy };
    return out[0..n];
}

fn expectGlyphs(expected: []const u16, got: []const Shaped) !void {
    var ids: [32]u16 = undefined;
    for (got, 0..) |g, i| ids[i] = g.glyph;
    try testing.expectEqualSlices(u16, expected, ids[0..got.len]);
}

// ---- Tests ----

test "Arabic joining forms" {
    var forms: [4]shape.Form = undefined;
    // Beh alef beh: the first joins the alef, which cannot join forward.
    shape.joiningForms(&.{ 0x628, 0x627, 0x628 }, forms[0..3]);
    try testing.expectEqualSlices(shape.Form, &.{ .init, .fina, .isol }, forms[0..3]);
    // Beh beh beh, with a mark (transparent) inside.
    shape.joiningForms(&.{ 0x628, 0x64E, 0x628, 0x628 }, &forms);
    try testing.expectEqualSlices(shape.Form, &.{ .init, .none, .medi, .fina }, &forms);
    // A space (non-joining) and a tatweel (join-causing).
    shape.joiningForms(&.{ 0x628, ' ', 0x640, 0x628 }, &forms);
    try testing.expectEqualSlices(shape.Form, &.{ .isol, .none, .none, .fina }, &forms);
}

test "Arabic presentation forms" {
    try testing.expectEqual(@as(?u21, 0xFE91), shape.presentationForm(0x628, .init));
    try testing.expectEqual(@as(?u21, 0xFEE0), shape.presentationForm(0x644, .medi));
    try testing.expectEqual(@as(?u21, 0xFEF2), shape.presentationForm(0x64A, .fina));
    try testing.expectEqual(@as(?u21, 0xFEF0), shape.presentationForm(0x649, .fina));
    try testing.expectEqual(@as(?u21, 0xFE80), shape.presentationForm(0x621, .isol));
    try testing.expectEqual(@as(?u21, null), shape.presentationForm(0x627, .init));
    try testing.expectEqual(@as(?u21, null), shape.presentationForm(0x41, .isol));
}

test "single substitutions, contextual alternates and kerning" {
    const bytes = try arabicFont(gpa);
    defer gpa.free(bytes);
    const font: Font = try .init(bytes);
    var buf: [8]Shaped = undefined;

    // بب: initial beh, then a final beh replaced after an initial one.
    const two = "\u{628}\u{628}";
    try expectGlyphs(&.{ beh_init, beh_fina_after_init }, glyphsOf(&font, two, false, &buf));
    // Shown right to left; the pair is kerned (on the first, the right one).
    const shown = glyphsOf(&font, two, true, &buf);
    try expectGlyphs(&.{ beh_fina_after_init, beh_init }, shown);
    try testing.expectEqual(@as(f32, 0), shown[0].x);
    try testing.expectApproxEqAbs(@as(f32, 4.2), shown[1].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 3.5), shown[1].advance, 1e-4);
    try testing.expectEqual(@as(usize, 2), shown[0].byte);
    try testing.expectEqual(@as(usize, 0), shown[1].byte);

    // ببب: initial, medial (the font has none: unchanged), final; no
    // contextual alternate (the final does not follow an initial).
    try expectGlyphs(&.{ beh_init, beh, beh_fina }, glyphsOf(&font, "\u{628}\u{628}\u{628}", false, &buf));

    // Lines measure as shown.
    const size = layout.measureMetrics(.init(&font, 10), two, null);
    try testing.expectApproxEqAbs(@as(f32, 7.7), size.width, 1e-4);
}

test "ligatures, decompositions and marks" {
    const bytes = try arabicFont(gpa);
    defer gpa.free(bytes);
    const font: Font = try .init(bytes);
    var buf: [8]Shaped = undefined;

    // لا: lam and final alef form one glyph, for both characters.
    const la = glyphsOf(&font, "\u{644}\u{627}", true, &buf);
    try expectGlyphs(&.{lam_alef}, la);
    try testing.expectEqual(@as(usize, 0), la[0].byte);
    try testing.expectEqual(@as(usize, 4), la[0].len);

    // With a mark between them (the ligature skips marks): the mark stays.
    const marked = glyphsOf(&font, "\u{644}\u{64E}\u{627}", false, &buf);
    try expectGlyphs(&.{ lam_alef, fatha }, marked);
    try testing.expectEqual(@as(usize, 6), marked[0].len);

    // ٴ decomposes into two glyphs.
    try expectGlyphs(&.{ 51, 52 }, glyphsOf(&font, "\u{674}", false, &buf));

    // بَ: the fatha sits on the beh's anchor, taking no room.
    const beh_fatha = glyphsOf(&font, "\u{628}\u{64E}", true, &buf);
    try expectGlyphs(&.{ fatha, beh }, beh_fatha);
    try testing.expectEqual(@as(f32, 0), beh_fatha[0].advance);
    try testing.expectApproxEqAbs(@as(f32, 1.5), beh_fatha[0].x + beh_fatha[0].dx, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -7), beh_fatha[0].dy, 1e-4);
    try testing.expectEqual(@as(f32, 0), beh_fatha[1].x);
    try testing.expectEqual(@as(f32, 5), layout.measureMetrics(.init(&font, 10), "\u{628}\u{64E}", null).width);
}

test "carets inside ligatures" {
    const bytes = try arabicFont(gpa);
    defer gpa.free(bytes);
    const font: Font = try .init(bytes);
    // "لا" is one glyph 4.8 wide, read from the right: between the lam
    // and the alef is its middle.
    const l: text_edit.TextLayout = .{ .metrics = .init(&font, 10), .text = "\u{644}\u{627}", .max_width = null };
    try testing.expectApproxEqAbs(@as(f32, 4.8), l.caret(0).x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2.4), l.caret(2).x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), l.caret(4).x, 1e-4);
}

/// A font without OpenType forms, mapping the presentation forms instead.
fn presentationFont() ![]u8 {
    var glyphs: [12]test_font.Glyph = undefined;
    for (&glyphs, 0..) |*g, i| g.* = box(@intCast(100 + i * 10));
    return test_font.build(gpa, &glyphs, &.{
        .{ .codepoint = 0x628, .glyph = 1 },
        .{ .codepoint = 0x627, .glyph = 2 },
        .{ .codepoint = 0x644, .glyph = 3 },
        .{ .codepoint = 0xFE8F, .glyph = 4 }, // beh isolated
        .{ .codepoint = 0xFE91, .glyph = 5 }, // beh initial
        .{ .codepoint = 0xFE8E, .glyph = 6 }, // alef final
        .{ .codepoint = 0xFEFB, .glyph = 7 }, // lam-alef isolated
        .{ .codepoint = 0xFEFC, .glyph = 8 }, // lam-alef final
        .{ .codepoint = 0xFEDF, .glyph = 9 }, // lam initial
    }, .{});
}

test "presentation forms for fonts without OpenType forms" {
    const bytes = try presentationFont();
    defer gpa.free(bytes);
    const font: Font = try .init(bytes);
    var buf: [8]Shaped = undefined;
    // باب: initial beh, final alef, isolated beh.
    try expectGlyphs(&.{ 5, 6, 4 }, glyphsOf(&font, "\u{628}\u{627}\u{628}", false, &buf));
    // لا alone, and after a beh (joined: the final form).
    try expectGlyphs(&.{7}, glyphsOf(&font, "\u{644}\u{627}", false, &buf));
    try expectGlyphs(&.{ 5, 8 }, glyphsOf(&font, "\u{628}\u{644}\u{627}", false, &buf));
    // A lam the font has no form of keeps its glyph... with one: initial.
    try expectGlyphs(&.{ 9, 1 }, glyphsOf(&font, "\u{644}\u{628}", false, &buf));
}

test "shaping damaged fonts does not crash" {
    const bytes = try arabicFont(gpa);
    defer gpa.free(bytes);
    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();
    const damaged = try gpa.dupe(u8, bytes);
    defer gpa.free(damaged);
    var buf: [32]Shaped = undefined;
    for (0..300) |_| {
        @memcpy(damaged, bytes);
        // Damage the layout tables (after the glyph data).
        for (0..8) |_| damaged[random.intRangeLessThan(usize, damaged.len / 2, damaged.len)] = random.int(u8);
        const font = Font.init(damaged) catch continue;
        _ = glyphsOf(&font, "\u{644}\u{64E}\u{627} \u{628}\u{628}\u{674}\u{628}\u{64E}", true, &buf);
    }
}
