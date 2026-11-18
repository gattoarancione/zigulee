// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const truetype = @import("truetype.zig");
const Font = truetype.Font;
const layout = @import("layout.zig");
const test_font = @import("test_font.zig");
const glyph = test_font.glyph;
const path = @import("../path.zig");

const gpa = testing.allocator;

test "metrics and character mapping" {
    const bytes = try test_font.standard(gpa);
    defer gpa.free(bytes);
    const font = try Font.init(bytes);
    try testing.expectEqual(@as(u16, 1000), font.units_per_em);
    try testing.expectEqual(@as(i16, 800), font.ascender);
    try testing.expectEqual(@as(i16, -200), font.descender);
    try testing.expectEqual(@as(u16, 8), font.num_glyphs);
    try testing.expectEqual(@as(f32, 20), font.lineHeight(20));

    try testing.expectEqual(@as(u16, glyph.A), font.glyphIndex('A'));
    try testing.expectEqual(@as(u16, glyph.space), font.glyphIndex(' '));
    try testing.expectEqual(@as(u16, 0), font.glyphIndex('Z')); // missing
    try testing.expectEqual(@as(u16, 0), font.glyphIndex(0x1F600)); // beyond the BMP
    try testing.expectEqual(@as(u16, 550), font.advanceWidth(glyph.A));
    try testing.expectEqual(@as(u16, 250), font.advanceWidth(glyph.space));
    try testing.expectEqual(@as(i16, -100), font.kerning(glyph.A, glyph.B));
    try testing.expectEqual(@as(i16, 0), font.kerning(glyph.B, glyph.A));
    try testing.expectEqual(truetype.Box{ .x_min = 0, .y_min = 0, .x_max = 500, .y_max = 700 }, font.glyphBox(glyph.B).?);
    try testing.expectEqual(@as(?truetype.Box, null), font.glyphBox(glyph.space));
}

test "format 12 character map" {
    const glyphs = [_]test_font.Glyph{ .{ .empty = .{ .advance = 100 } }, .{ .empty = .{ .advance = 200 } } };
    const bytes = try test_font.build(gpa, &glyphs, &.{ .{ .codepoint = 0x1F600, .glyph = 1 }, .{ .codepoint = 'x', .glyph = 1 } }, .{ .cmap_format = 12 });
    defer gpa.free(bytes);
    const font = try Font.init(bytes);
    try testing.expectEqual(@as(u16, 1), font.glyphIndex(0x1F600));
    try testing.expectEqual(@as(u16, 1), font.glyphIndex('x'));
    try testing.expectEqual(@as(u16, 0), font.glyphIndex('y'));
}

fn outline(font: *const Font, g: u16) !std.ArrayList(path.Command) {
    var list: std.ArrayList(path.Command) = .empty;
    errdefer list.deinit(gpa);
    try font.glyphOutline(gpa, g, &list);
    return list;
}

test "simple glyph outlines" {
    const bytes = try test_font.standard(gpa);
    defer gpa.free(bytes);
    const font = try Font.init(bytes);

    var a = try outline(&font, glyph.A);
    defer a.deinit(gpa);
    try testing.expectEqualSlices(path.Command, &.{
        .{ .move_to = .{ .x = 0, .y = 0 } },
        .{ .line_to = .{ .x = 250, .y = 700 } },
        .{ .line_to = .{ .x = 500, .y = 0 } },
        .close,
    }, a.items);

    // Two contours: outer square and hole.
    var b = try outline(&font, glyph.B);
    defer b.deinit(gpa);
    var closes: usize = 0;
    for (b.items) |c| if (c == .close) {
        closes += 1;
    };
    try testing.expectEqual(@as(usize, 2), closes);
}

test "all-off-curve contours use implied on-curve midpoints" {
    const bytes = try test_font.standard(gpa);
    defer gpa.free(bytes);
    const font = try Font.init(bytes);
    var o = try outline(&font, glyph.O);
    defer o.deinit(gpa);
    // Per contour: move, 8 quads, close.
    try testing.expectEqual(@as(usize, 20), o.items.len);
    const start = o.items[0].move_to;
    // The last quad of the contour returns to the start.
    try testing.expectEqual(start, o.items[8].quad_to.p);
    // Curve points lie on edge midpoints, inside the octagon's radius.
    const r = std.math.hypot(start.x - 250, start.y - 350);
    try testing.expect(r > 240 and r < 270);
}

test "composite glyphs place transformed components" {
    const bytes = try test_font.standard(gpa);
    defer gpa.free(bytes);
    const font = try Font.init(bytes);
    var c = try outline(&font, glyph.C);
    defer c.deinit(gpa);
    try testing.expectEqual(@as(usize, 10), c.items.len); // 2 x (move, 3 lines, close)
    try testing.expectEqual(path.Command{ .move_to = .{ .x = 0, .y = 0 } }, c.items[0]);
    // Second copy: scaled 1.75 and offset by (150, 250).
    try testing.expectEqual(path.Command{ .move_to = .{ .x = 150, .y = 250 } }, c.items[5]);
    try testing.expectEqual(path.Command{ .line_to = .{ .x = 150, .y = 600 } }, c.items[6]);
}

/// A font with GPOS kerning between glyphs 1..4 (all 500 units wide).
fn gposFont(extension: bool) ![]u8 {
    const glyphs = [_]test_font.Glyph{
        .{ .empty = .{ .advance = 500 } }, .{ .empty = .{ .advance = 500 } },
        .{ .empty = .{ .advance = 500 } }, .{ .empty = .{ .advance = 500 } },
        .{ .empty = .{ .advance = 500 } },
    };
    return test_font.build(gpa, &glyphs, &.{
        .{ .codepoint = 'a', .glyph = 1 }, .{ .codepoint = 'b', .glyph = 2 },
        .{ .codepoint = 'c', .glyph = 3 }, .{ .codepoint = 'd', .glyph = 4 },
    }, .{
        // The legacy table must be ignored when GPOS has kerning.
        .kerning = &.{.{ .left = 1, .right = 2, .value = -999 }},
        .gpos = .{
            .extension = extension,
            .pairs = &.{
                .{ .left = 1, .right = 2, .value = -50 },
                .{ .left = 1, .right = 4, .value = 30 },
                .{ .left = 3, .right = 1, .value = -70 },
            },
            // Glyphs 1 and 2 are class 1 on the left; 3 and 4 classes 1 and 2
            // on the right. Format 1 above wins for pairs it lists.
            .class_kerning = .{
                .first = &.{ .{ .glyph = 1, .class = 1 }, .{ .glyph = 2, .class = 1 } },
                .second = &.{ .{ .glyph = 3, .class = 1 }, .{ .glyph = 4, .class = 2 } },
                .class1_count = 2,
                .class2_count = 3,
                .values = &.{ 0, 0, 0, 0, -20, -40 },
            },
            .decoy_pairs = &.{.{ .left = 2, .right = 1, .value = -500 }},
        },
    });
}

test "GPOS pair kerning: pairs, classes, extension lookups" {
    for ([_]bool{ false, true }) |extension| {
        const bytes = try gposFont(extension);
        defer gpa.free(bytes);
        const font = try Font.init(bytes);
        try testing.expect(font.gpos_kern != null);
        try testing.expectEqual(@as(i16, -50), font.kerning(1, 2)); // format 1, not the kern table
        try testing.expectEqual(@as(i16, 30), font.kerning(1, 4)); // format 1 wins over classes
        try testing.expectEqual(@as(i16, -70), font.kerning(3, 1));
        try testing.expectEqual(@as(i16, -20), font.kerning(1, 3)); // classes (1, 1)
        try testing.expectEqual(@as(i16, -40), font.kerning(2, 4)); // classes (1, 2)
        try testing.expectEqual(@as(i16, 0), font.kerning(2, 2)); // class 2 = 0
        try testing.expectEqual(@as(i16, 0), font.kerning(2, 1)); // only in a non-kern feature
        try testing.expectEqual(@as(i16, 0), font.kerning(4, 4)); // not covered
        // Layout applies it: "ab" = 500 + 500 - 50 units at 1000 upem.
        try testing.expectEqual(@as(f32, 9.5), layout.measure(&font, "ab", 10, null).width);
    }
}

test "corrupted GPOS tables never crash kerning lookups" {
    const bytes = try gposFont(true);
    defer gpa.free(bytes);
    for (0..bytes.len) |n| exercise(bytes[0..n]);
    const copy = try gpa.dupe(u8, bytes);
    defer gpa.free(copy);
    var prng: std.Random.DefaultPrng = .init(0x9905);
    const random = prng.random();
    for (0..3000) |_| {
        @memcpy(copy, bytes);
        // Corrupt mostly near the end, where GPOS is.
        for (0..1 + random.uintLessThan(usize, 3)) |_| {
            copy[copy.len - 1 - random.uintLessThan(usize, @min(copy.len, 400))] = random.int(u8);
        }
        exercise(copy);
    }
}

test "line breaking and measurement" {
    const bytes = try test_font.standard(gpa);
    defer gpa.free(bytes);
    const font = try Font.init(bytes);
    // At 10px: A/B/O/C are 5.5px wide, space 2.5px, i 2px; A then B kerns -1px.
    try testing.expectEqual(@as(f32, 10), layout.measure(&font, "AB", 10, null).width);
    try testing.expectEqual(@as(f32, 10), layout.measure(&font, "", 10, null).height); // one empty line
    try testing.expectEqual(@as(f32, 30), layout.measure(&font, "A\n\nB", 10, null).height);
    try testing.expectEqual(@as(f32, 20), layout.measure(&font, "A\n", 10, null).height);

    // "OO OO OO" at width 25: each "OO" is 11px, "OO OO" is 24.5px.
    var it: layout.LineIterator = .init(&font, "OO OO OO", 10, 25);
    const l1 = it.next().?;
    const l2 = it.next().?;
    try testing.expectEqual(@as(?layout.Line, null), it.next());
    try testing.expectEqualStrings("OO OO", "OO OO OO"[l1.start..l1.end]);
    try testing.expectEqualStrings("OO", "OO OO OO"[l2.start..l2.end]);
    try testing.expectEqual(@as(f32, 24.5), l1.width);

    // A word longer than the line breaks inside the word.
    it = .init(&font, "OOOOOO", 10, 12);
    var lines: usize = 0;
    while (it.next()) |l| : (lines += 1) try testing.expect(l.width <= 12);
    try testing.expectEqual(@as(usize, 3), lines);

    // Even a single glyph wider than the line is placed (no infinite loop).
    try testing.expectEqual(@as(f32, 20), layout.measure(&font, "OO", 10, 1).height);
}

test "glyph positions include kerning" {
    const bytes = try test_font.standard(gpa);
    defer gpa.free(bytes);
    const font = try Font.init(bytes);
    var it: layout.GlyphIterator = .init(&font, "ABi", 10, .{ .start = 0, .end = 3, .width = 0 });
    const expected = [_]struct { u16, f32, usize }{ .{ glyph.A, 0, 0 }, .{ glyph.B, 4.5, 1 }, .{ glyph.i, 10, 2 } };
    for (expected) |e| {
        const g = it.next().?;
        try testing.expectEqual(e[0], g.glyph);
        try testing.expectEqual(e[1], g.x);
        try testing.expectEqual(e[2], g.byte);
        try testing.expectEqual(@as(usize, 1), g.len);
    }
    try testing.expectEqual(@as(?layout.PositionedGlyph, null), it.next());
}

test "letter spacing after each character: measured, wrapped and placed alike" {
    const bytes = try test_font.standard(gpa);
    defer gpa.free(bytes);
    const font = try Font.init(bytes);
    const m = layout.Metrics.init(&font, 10).withSpacing(2);
    // "AB": 5.5 + 5.5 - 1 kerning, and 2 after each.
    try testing.expectEqual(@as(f32, 14), layout.measureMetrics(m, "AB", null).width);
    var it: layout.GlyphIterator = .initMetrics(m, "ABi", .{ .start = 0, .end = 3, .width = 0 });
    for ([_]f32{ 0, 6.5, 14 }) |x| try testing.expectEqual(x, it.next().?.x);

    // "OO OO OO" at width 25: "OO" is now 13px wide, "OO OO" 29.5px.
    var lines: layout.LineIterator = .initMetrics(m.withSpacing(1), "OO OO OO", 25);
    var n: usize = 0;
    while (lines.next()) |l| : (n += 1) try testing.expectEqual(@as(f32, 13), l.width);
    try testing.expectEqual(@as(usize, 3), n);

    // Closer together, and the ellipsis spaced too.
    try testing.expectEqual(@as(f32, 8), layout.measureMetrics(m.withSpacing(-1), "AB", null).width);
    try testing.expectEqual(layout.ellipsis(.init(&font, 10)).width() + 2 * @as(f32, @floatFromInt(layout.ellipsis(m).count)), layout.ellipsis(m).width());
}

test "invalid UTF-8 decodes to replacement characters" {
    try testing.expectEqual(@as(u21, 0xfffd), layout.decode("\xff", 0).cp);
    try testing.expectEqual(@as(u21, 0xfffd), layout.decode("\xe2\x82", 0).cp); // truncated
    try testing.expectEqual(@as(u21, 0x20ac), layout.decode("\xe2\x82\xac", 0).cp);
}

test "rejects non-fonts and CFF fonts" {
    try testing.expectError(error.InvalidFont, Font.init("hello"));
    try testing.expectError(error.InvalidFont, Font.init(""));
    try testing.expectError(error.UnsupportedFont, Font.init("OTTO\x00\x00\x00\x00\x00\x00\x00\x00"));
}

/// Exercises every reader entry point on a possibly corrupt font.
fn exercise(bytes: []const u8) void {
    const font = Font.init(bytes) catch return;
    var list: std.ArrayList(path.Command) = .empty;
    defer list.deinit(gpa);
    var g: u16 = 0;
    while (g < font.num_glyphs +| 2) : (g += 1) {
        list.clearRetainingCapacity();
        font.glyphOutline(gpa, g, &list) catch {};
        _ = font.glyphBox(g);
        _ = font.advanceWidth(g);
        _ = font.kerning(g, g +% 1);
        _ = font.kerning(g +% 1, g);
    }
    for ("AB Oi\xff") |c| _ = font.glyphIndex(c);
    _ = layout.measure(&font, "AB OO iC", 10, 15);
}

test "truncated and corrupted fonts never crash the reader" {
    const bytes = try test_font.standard(gpa);
    defer gpa.free(bytes);
    // Every truncation.
    for (0..bytes.len) |n| exercise(bytes[0..n]);
    // Byte corruptions throughout the file.
    const copy = try gpa.dupe(u8, bytes);
    defer gpa.free(copy);
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    for (0..2000) |_| {
        @memcpy(copy, bytes);
        for (0..1 + random.uintLessThan(usize, 4)) |_| copy[random.uintLessThan(usize, copy.len)] = random.int(u8);
        exercise(copy);
    }
}

test "system font smoke test" {
    const io = testing.io;
    const candidates = [_][]const u8{
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "C:\\Windows\\Fonts\\arial.ttf",
    };
    for (candidates) |p| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(32 << 20)) catch continue;
        defer gpa.free(bytes);
        const font = try Font.init(bytes);
        const g = font.glyphIndex('g');
        try testing.expect(g != 0);
        var list = try outline(&font, g);
        defer list.deinit(gpa);
        try testing.expect(list.items.len > 10);
        const size = layout.measure(&font, "Hello, world", 16, null);
        try testing.expect(size.width > 60 and size.width < 120);
        // Fonts with both GPOS and a legacy kern table should agree.
        if (font.gpos_kern != null and font.kern != null) {
            var legacy = font;
            legacy.gpos_kern = null;
            for ([_][2]u21{ .{ 'A', 'V' }, .{ 'T', 'o' }, .{ 'L', 'T' }, .{ 'Y', 'a' } }) |pair| {
                const l = font.glyphIndex(pair[0]);
                const r = font.glyphIndex(pair[1]);
                try testing.expectEqual(legacy.kerning(l, r), font.kerning(l, r));
            }
            try testing.expect(font.kerning(font.glyphIndex('A'), font.glyphIndex('V')) < 0);
        }
        return;
    }
    return error.SkipZigTest;
}

// ---- fallback fonts and eliding ----

/// A font with only '€' (a 600 wide square) and '…' (300 wide).
fn symbolFont(allocator: std.mem.Allocator) ![]u8 {
    const tf = @import("test_font.zig");
    const square = [_][]const tf.Pt{&.{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 600 }, .{ .x = 600, .y = 600 }, .{ .x = 600, .y = 0 } }};
    const glyphs = [_]tf.Glyph{
        .{ .empty = .{ .advance = 500 } },
        .{ .simple = .{ .advance = 600, .contours = &square } },
        .{ .simple = .{ .advance = 300, .contours = &square } },
    };
    return tf.build(allocator, &glyphs, &.{ .{ .codepoint = 0x20ac, .glyph = 1 }, .{ .codepoint = 0x2026, .glyph = 2 } }, .{});
}

test "fallback fonts give the characters the font lacks" {
    const main_bytes = try test_font.standard(gpa);
    defer gpa.free(main_bytes);
    const sym_bytes = try symbolFont(gpa);
    defer gpa.free(sym_bytes);
    const main: Font = try .init(main_bytes);
    const sym: Font = try .init(sym_bytes);

    const alone: layout.Metrics = .init(&main, 10);
    try testing.expectEqual(layout.Glyph{ .id = 0 }, alone.glyph(0x20ac)); // missing
    const m: layout.Metrics = .initFallbacks(&main, &.{&sym}, 10);
    try testing.expectEqual(layout.Glyph{ .id = test_font.glyph.A }, m.glyph('A'));
    try testing.expectEqual(layout.Glyph{ .id = 1, .font = 1 }, m.glyph(0x20ac));
    try testing.expectEqual(&sym, m.fontOf(m.glyph(0x20ac)).?);
    // Advances in the fallback font's own units; no kerning across fonts.
    try testing.expectEqual(@as(f32, 6), m.advance(m.glyph('A'), m.glyph(0x20ac)));
    try testing.expectEqual(@as(f32, 5.5 - 1), m.advance(m.glyph('A'), m.glyph('B')));
    try testing.expectEqual(@as(f32, 5.5 + 6 + 5.5), layout.measureMetrics(m, "A€A", null).width);

    var glyphs: layout.GlyphIterator = .initMetrics(m, "A€", .{ .start = 0, .end = 4, .width = 0 });
    try testing.expectEqual(&main, glyphs.next().?.font.?);
    const euro = glyphs.next().?;
    try testing.expectEqual(&sym, euro.font.?);
    try testing.expectEqual(@as(f32, 5.5), euro.x);
}

test "eliding: where lines are cut for the ellipsis" {
    const main_bytes = try test_font.standard(gpa);
    defer gpa.free(main_bytes);
    const sym_bytes = try symbolFont(gpa);
    defer gpa.free(sym_bytes);
    const main: Font = try .init(main_bytes);
    const sym: Font = try .init(sym_bytes);

    // Without "…" in any font: "...", from '.' (missing here: notdef).
    const plain: layout.Metrics = .init(&main, 10);
    try testing.expectEqual(@as(u8, 3), layout.ellipsis(plain).count);
    // With a fallback that has it: one glyph, 3 wide.
    const m: layout.Metrics = .initFallbacks(&main, &.{&sym}, 10);
    const dots = layout.ellipsis(m);
    try testing.expectEqual(@as(u8, 1), dots.count);
    try testing.expectEqual(@as(f32, 3), dots.width());

    // "AOAOAO" is 33 wide (5.5 each). In 20: 3 letters (16.5) + "…" (3).
    const text = "AOAOAO";
    const line: layout.Line = .{ .start = 0, .end = text.len, .width = 33 };
    const cut = layout.elide(m, text, line, 20);
    try testing.expect(cut.elided);
    try testing.expectEqual(@as(usize, 3), cut.end);
    try testing.expectEqual(@as(f32, 16.5), cut.width);
    // A line that fits stays whole.
    try testing.expect(!layout.elide(m, text, line, 40).elided);
    // No space before the ellipsis.
    const spaced = "AO OA";
    const cut2 = layout.elide(m, spaced, .{ .start = 0, .end = spaced.len, .width = 24.5 }, 16);
    try testing.expectEqual(@as(usize, 2), cut2.end);
    // Not even one letter fits: just the ellipsis.
    try testing.expectEqual(@as(usize, 0), layout.elide(m, text, line, 4).end);
}

// ---- right-to-left text ----

/// The standard test font, with Hebrew alef, bet, gimel shown as its A, B
/// and O glyphs, and '(' ')' as distinct glyphs.
fn hebrewFont(allocator: std.mem.Allocator) ![]u8 {
    const tf = @import("test_font.zig");
    const tri = [_][]const tf.Pt{&.{ .{ .x = 0, .y = 0 }, .{ .x = 250, .y = 700 }, .{ .x = 500, .y = 0 } }};
    const sq = [_][]const tf.Pt{&.{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 700 }, .{ .x = 500, .y = 700 }, .{ .x = 500, .y = 0 } }};
    const glyphs = [_]tf.Glyph{
        .{ .empty = .{ .advance = 500 } },
        .{ .empty = .{ .advance = 250 } }, // space
        .{ .simple = .{ .advance = 500, .contours = &tri } }, // A, alef
        .{ .simple = .{ .advance = 600, .contours = &sq } }, // B, bet
        .{ .simple = .{ .advance = 300, .contours = &sq } }, // (
        .{ .simple = .{ .advance = 310, .contours = &sq } }, // )
    };
    return tf.build(allocator, &glyphs, &.{
        .{ .codepoint = ' ', .glyph = 1 },
        .{ .codepoint = '(', .glyph = 4 },
        .{ .codepoint = ')', .glyph = 5 },
        .{ .codepoint = 'A', .glyph = 2 },
        .{ .codepoint = 'B', .glyph = 3 },
        .{ .codepoint = 0x5d0, .glyph = 2 },
        .{ .codepoint = 0x5d1, .glyph = 3 },
    }, .{});
}

test "right-to-left text is shown in visual order" {
    const bytes = try hebrewFont(gpa);
    defer gpa.free(bytes);
    const font: Font = try .init(bytes);
    const m: layout.Metrics = .init(&font, 10);

    // "AB אב": the Hebrew word reads right to left, after the Latin one.
    const mixed = "AB \u{5d0}\u{5d1}";
    var it: layout.GlyphIterator = .initMetrics(m, mixed, .{ .start = 0, .end = mixed.len, .width = 0 });
    const expected = [_]struct { usize, bool }{ .{ 0, false }, .{ 1, false }, .{ 2, false }, .{ 5, true }, .{ 3, true } };
    var x: f32 = 0;
    for (expected) |e| {
        const g = it.next().?;
        try testing.expectEqual(e[0], g.byte);
        try testing.expectEqual(e[1], g.rtl);
        try testing.expectEqual(x, g.x);
        x += g.advance;
    }
    try testing.expect(it.next() == null);

    // "אב AB": a right-to-left paragraph; the Latin word keeps its order
    // and is shown first (on the left).
    const rtl = "\u{5d0}\u{5d1} AB";
    try testing.expectEqual(@as(u8, 1), layout.paragraphLevelAt(rtl, 0));
    it = .initMetrics(m, rtl, .{ .start = 0, .end = rtl.len, .width = 0 });
    for ([_]usize{ 5, 6, 4, 2, 0 }) |byte| try testing.expectEqual(byte, it.next().?.byte);

    // Brackets are mirrored in right-to-left text: "(" shows as ")".
    const brackets = "\u{5d0}(\u{5d1})";
    it = .initMetrics(m, brackets, .{ .start = 0, .end = brackets.len, .width = 0 });
    var widths: [4]f32 = undefined;
    for (&widths) |*w| w.* = it.next().?.advance;
    // Logical א ( ב ) shows, from the left, as ")" ב "(" א, mirrored: the
    // first glyph shown is the ")" character drawn as "(" (3 wide).
    try testing.expectEqual(@as(f32, 3), widths[0]);
    try testing.expectEqual(@as(f32, 3.1), widths[2]);

    // Left-to-right text takes the fast path: no reordering at all.
    it = .initMetrics(m, "AB", .{ .start = 0, .end = 2, .width = 0 });
    try testing.expect(it.complex == null);
}

test "carets and hit testing in right-to-left text" {
    const bytes = try hebrewFont(gpa);
    defer gpa.free(bytes);
    const font: Font = try .init(bytes);
    const text_edit = @import("../text_edit.zig");
    // "AB אב": A 0-5, B 5-11, space 11-13.5, ב 13.5-19.5, א 19.5-24.5.
    const l: text_edit.TextLayout = .{ .metrics = .init(&font, 10), .text = "AB \u{5d0}\u{5d1}" };
    try testing.expectEqual(@as(f32, 0), l.caret(0).x);
    try testing.expectEqual(@as(f32, 13.5), l.caret(3).x - 11); // א starts at its right edge: 24.5
    try testing.expectEqual(@as(f32, 24.5), l.caret(3).x);
    try testing.expectEqual(@as(f32, 19.5), l.caret(5).x); // ב: its right edge
    try testing.expectEqual(@as(f32, 13.5), l.caret(7).x); // after ב, the last character
    // Clicking: left half of א is after it in the text (offset 5).
    try testing.expectEqual(@as(usize, 5), l.offsetAt(.{ .x = 20, .y = 1 }));
    try testing.expectEqual(@as(usize, 3), l.offsetAt(.{ .x = 24, .y = 1 }));
    try testing.expectEqual(@as(usize, 3), l.offsetAt(.{ .x = 100, .y = 1 }));
    try testing.expectEqual(@as(usize, 0), l.offsetAt(.{ .x = -5, .y = 1 }));
}

test "eliding right-to-left text keeps its logical start" {
    const bytes = try hebrewFont(gpa);
    defer gpa.free(bytes);
    const font: Font = try .init(bytes);
    const m: layout.Metrics = .init(&font, 10);
    // אבאב: 5 + 6 + 5 + 6 = 22 wide ("..." is three 5 wide missing glyphs
    // here: 15). In 30 everything fits.
    const text = "\u{5d0}\u{5d1}\u{5d0}\u{5d1}";
    const line: layout.Line = .{ .start = 0, .end = text.len, .width = 22 };
    try testing.expect(!layout.elide(m, text, line, 30).elided);
    // In 20: the first letter (5) and "..." (15), cut in logical order:
    // the start of the text is kept.
    const cut = layout.elide(m, text, line, 20);
    try testing.expect(cut.elided);
    try testing.expectEqual(@as(usize, 2), cut.end);
}
