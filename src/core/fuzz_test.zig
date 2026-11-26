// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Fuzz targets of the runtime (see fuzz.zig). Besides not crashing, each
//! checks what must hold for any input.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const core = @import("core.zig");
const Target = core.fuzz.Target;
const Input = core.fuzz.Input;
const layout = core.layout;
const text_edit = core.text_edit;

pub const targets = [_]Target{
    .{ .name = "box-layout", .run = boxLayout, .corpus = &.{ "", "\x03\x00\x01", "\x0c\xff\xff\xff\x00\x00\x00\x00\x10\x20\x30\x40" } },
    .{ .name = "grid-layout", .run = gridLayout, .corpus = &.{ "", "\x04\x00\x02\x01" } },
    .{ .name = "png", .run = pngRoundTrip, .corpus = &.{ "", "\x02\x02\xff\x00\x00\xff\x00\xff\x00\xff" } },
    .{ .name = "animated-images", .run = animatedImages, .corpus = &.{ "", "\x02\x03\x02\x00\x01\x02\x03\x01\x00\x02\x01" } },
    .{ .name = "font", .run = damagedFonts, .corpus = &.{ "", "\x01\x10\x00" } },
    .{ .name = "path", .run = pathData, .corpus = &.{ "", "M 0 0 L 10 10 Z", "M1 2a3 4 5 1 0 6 7" } },
    .{ .name = "text-boundaries", .run = textBoundaries, .corpus = &.{ "", "abc def", "e\u{301}\u{1F44D}\u{1F3FD}\xff\xfe a\n\nb" } },
    .{ .name = "po", .run = poCatalogs, .corpus = &.{ "", "\x01\x02\x03\x04\x05\x06\x07\x08" } },
    .{ .name = "bidi", .run = bidiOrder, .corpus = &.{ "", "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b" } },
    .{ .name = "shaping", .run = shaping, .corpus = &.{ "", "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d" } },
    .{ .name = "text-editing", .run = textEditing, .corpus = &.{ "", "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x00\x01", "\x05\x05\x03\x03\x06\x06" } },
};

test "fuzz targets on their corpus" {
    inline for (targets) |t| try core.fuzz.runCorpus(t);
}

fn floatIn(s: *Input, lo: f32, hi: f32) f32 {
    const v = s.valueRangeAtMost(u16, 0, 1000);
    return lo + (hi - lo) * @as(f32, @floatFromInt(v)) / 1000;
}

fn count(s: *Input, max: u32) usize {
    return s.valueRangeAtMost(u32, 0, max);
}

fn randomInfo(s: *Input) layout.LayoutInfo {
    const min = floatIn(s, 0, 200);
    return .{
        .min = min,
        // Sometimes unbounded, sometimes below the minimum (inconsistent).
        .max = switch (s.valueRangeAtMost(u8, 0, 3)) {
            0 => std.math.inf(f32),
            1 => floatIn(s, 0, 100),
            else => min + floatIn(s, 0, 300),
        },
        .preferred = floatIn(s, 0, 300),
        .stretch = floatIn(s, 0, 3),
    };
}

fn expectFinite(x: f32) !void {
    if (!std.math.isFinite(x)) return error.NotFinite;
}

/// Box layouts give finite, ordered segments.
pub fn boxLayout(_: Allocator, s: *Input) !void {
    const n = count(s, 12);
    var items: [12]layout.LayoutInfo = undefined;
    var out: [12]layout.Segment = undefined;
    for (items[0..n]) |*it| it.* = randomInfo(s);
    const data: layout.BoxLayoutData = .{
        .size = floatIn(s, 0, 2000),
        .spacing = floatIn(s, 0, 20),
        .padding = .{ .begin = floatIn(s, 0, 30), .end = floatIn(s, 0, 30) },
        .alignment = s.value(layout.Alignment),
    };
    layout.solveBox(data, items[0..n], out[0..n]);
    var end: f32 = -std.math.inf(f32);
    for (out[0..n]) |seg| {
        try expectFinite(seg.pos);
        try expectFinite(seg.size);
        try testing.expect(seg.size >= 0);
        // Each segment starts after the previous one ends.
        try testing.expect(seg.pos >= end - 0.01);
        end = seg.pos + seg.size;
    }
    const info = layout.boxLayoutInfo(items[0..n], data.spacing, data.padding);
    try expectFinite(info.min);
    try expectFinite(info.preferred);
    try testing.expect(info.max >= info.min);
}

/// Grid layouts give finite segments.
pub fn gridLayout(_: Allocator, s: *Input) !void {
    const n = count(s, 10);
    var cells: [10]layout.GridCell = undefined;
    for (cells[0..n]) |*c| c.* = .{
        .index = s.valueRangeAtMost(u16, 0, 6),
        .span = s.valueRangeAtMost(u16, 1, 3),
        .info = randomInfo(s),
    };
    var tracks: [16]layout.LayoutInfo = undefined;
    var track_out: [16]layout.Segment = undefined;
    var out: [10]layout.Segment = undefined;
    const data: layout.GridLayoutData = .{ .size = floatIn(s, 0, 1000), .spacing = floatIn(s, 0, 10) };
    const t = layout.gridTrackCount(cells[0..n]);
    _ = layout.gridLayoutInfo(cells[0..n], data.spacing, data.padding, tracks[0..t]);
    layout.solveGrid(data, cells[0..n], tracks[0..t], track_out[0..t], out[0..n]);
    for (out[0..n]) |seg| {
        try expectFinite(seg.pos);
        try expectFinite(seg.size);
        try testing.expect(seg.size >= 0);
    }
}

/// PNGs round trip exactly; damaged PNGs and any bytes fail cleanly.
pub fn pngRoundTrip(gpa: Allocator, s: *Input) !void {
    const w = s.valueRangeAtMost(u32, 1, 8);
    const h = s.valueRangeAtMost(u32, 1, 8);
    const pixels = try gpa.alloc(core.Rgba8, w * h);
    defer gpa.free(pixels);
    s.bytes(std.mem.sliceAsBytes(pixels));
    // Premultiplied: no channel above alpha.
    for (pixels) |*p| {
        p.r = @min(p.r, p.a);
        p.g = @min(p.g, p.a);
        p.b = @min(p.b, p.a);
    }
    const png = try core.png.encode(gpa, w, h, pixels);
    defer gpa.free(png);
    {
        var img = try core.png.decode(gpa, png);
        defer img.deinit(gpa);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(pixels), std.mem.sliceAsBytes(img.pixels));
    }
    const damaged = try gpa.dupe(u8, png);
    defer gpa.free(damaged);
    const flips = s.valueRangeAtMost(u8, 1, 8);
    for (0..flips) |_| damaged[s.index(damaged.len)] ^= s.valueRangeAtMost(u8, 1, 255);
    if (core.png.decode(gpa, damaged)) |ok| {
        var d = ok;
        d.deinit(gpa);
    } else |_| {}
    var raw: [256]u8 = undefined;
    const n = s.slice(&raw);
    if (core.png.decode(gpa, raw[0..n])) |ok| {
        var d = ok;
        d.deinit(gpa);
    } else |_| {}
}

/// GIFs and animated PNGs play every frame; damaged ones, and any bytes,
/// play what they can or fail cleanly, with any frame shown in any order.
pub fn animatedImages(gpa: Allocator, s: *Input) !void {
    const w = s.valueRangeAtMost(u16, 1, 6);
    const h = s.valueRangeAtMost(u16, 1, 6);
    const frame_count: usize = s.valueRangeAtMost(u8, 1, 4);
    var frames: [4][]u8 = undefined;
    for (frames[0..frame_count]) |*f| {
        f.* = try gpa.alloc(u8, @as(usize, w) * h);
        for (f.*) |*i| i.* = s.valueRangeAtMost(u8, 0, 3);
    }
    defer for (frames[0..frame_count]) |f| gpa.free(f);
    const file = if (s.value(bool)) blk: {
        const indices: [4][]const u8 = .{ frames[0], frames[@min(1, frame_count - 1)], frames[@min(2, frame_count - 1)], frames[@min(3, frame_count - 1)] };
        break :blk try core.gif.testGif(gpa, w, h, indices[0..frame_count], s.valueRangeAtMost(u16, 0, 20), s.valueRangeAtMost(u16, 0, 3));
    } else blk: {
        var images: [4][]core.Rgba8 = undefined;
        for (images[0..frame_count], frames[0..frame_count]) |*img, f| {
            img.* = try gpa.alloc(core.Rgba8, f.len);
            for (img.*, f) |*p, i| p.* = if (i == 3) .transparent else .{ .r = 80 * i, .g = 255, .b = 0, .a = 255 };
        }
        defer for (images[0..frame_count]) |img| gpa.free(img);
        var views: [4][]const core.Rgba8 = undefined;
        for (views[0..frame_count], images[0..frame_count]) |*v, img| v.* = img;
        break :blk try core.video.apng.encode(gpa, w, h, views[0..frame_count], 40);
    };
    defer gpa.free(file);
    {
        var a = try core.animated.Animation.open(gpa, file);
        defer a.close();
        try testing.expectEqual(frame_count, a.frameCount());
        try playAround(&a, s);
    }
    const damaged = try gpa.dupe(u8, file);
    defer gpa.free(damaged);
    const flips = s.valueRangeAtMost(u8, 1, 8);
    for (0..flips) |_| damaged[s.index(damaged.len)] ^= s.valueRangeAtMost(u8, 1, 255);
    if (core.animated.Animation.open(gpa, damaged[0 .. damaged.len - s.index(damaged.len / 2)])) |ok| {
        var a = ok;
        defer a.close();
        try playAround(&a, s);
    } else |_| {}
    var raw: [256]u8 = undefined;
    const n = s.slice(&raw);
    if (core.animated.Animation.open(gpa, raw[0..n])) |ok| {
        var a = ok;
        defer a.close();
        try playAround(&a, s);
    } else |_| {}
}

fn playAround(a: *core.animated.Animation, s: *Input) !void {
    for (0..6) |_| {
        a.show(s.index(a.frameCount() + 1)) catch |err| switch (err) {
            error.InvalidImage => return,
            else => return err,
        };
        try testing.expectEqual(@as(usize, a.width()) * a.height(), a.pixels().len);
    }
}

/// Damaged fonts are rejected or usable.
pub fn damagedFonts(gpa: Allocator, s: *Input) !void {
    // A pre-rendered font half the time, a TrueType font otherwise.
    const font_bytes = if (s.value(bool)) try smallBitmapFont(gpa) else try core.text.test_font.standard(gpa);
    defer gpa.free(font_bytes);
    const flips = s.valueRangeAtMost(u8, 0, 12);
    for (0..flips) |_| font_bytes[s.index(font_bytes.len)] ^= s.valueRangeAtMost(u8, 1, 255);
    const font = core.Font.init(font_bytes) catch return;
    var commands: std.ArrayList(core.path.Command) = .empty;
    defer commands.deinit(gpa);
    for (0..@min(font.num_glyphs, 32)) |g| {
        const glyph: u16 = @intCast(g);
        _ = font.advanceWidth(glyph);
        _ = font.glyphBox(glyph);
        _ = font.kerning(glyph, @intCast((g + 1) % @max(font.num_glyphs, 1)));
        commands.clearRetainingCapacity();
        font.glyphOutline(gpa, glyph, &commands) catch {};
    }
    for ("AaBOi Z") |c| _ = font.glyphIndex(c);
    for (0..@min(font.num_glyphs, 8)) |g| if (font.glyphImage(@intCast(g), floatIn(s, 1, 50))) |img| {
        for (0..img.height) |y| for (0..img.width) |x| std.mem.doNotOptimizeAway(img.coverage(x, y));
    };
    const size = core.text.measure(&font, "AB OBi\nAAA", 12, 30);
    try expectFinite(size.width);
    try expectFinite(size.height);
}

fn smallBitmapFont(gpa: Allocator) ![]u8 {
    const bf = core.text.bitmap_font;
    const cov = [_]u8{ 0, 255, 128, 64, 255, 0 };
    const g: bf.Spec.GlyphImage = .{ .width = 3, .height = 2, .left = 1, .top = -2, .coverage = &cov };
    return bf.encode(gpa, .{
        .units_per_em = 1000,
        .ascender = 800,
        .descender = -200,
        .line_gap = 0,
        .codepoints = &.{ 'A', 'B', 'O', 'i' },
        .advances = &.{ 500, 550, 560, 570, 200 },
        .kerning = &.{.{ .left = 1, .right = 2, .value = -50 }},
        .strikes = &.{ .{ .pixel_size = 10, .glyphs = &.{ g, g, g, g, g } }, .{ .pixel_size = 30, .glyphs = &.{ .{}, g, .{}, g, .{} } } },
    });
}

/// SVG path data parses or fails cleanly; parsed paths flatten.
pub fn pathData(gpa: Allocator, s: *Input) !void {
    const alphabet = "MmLlHhVvCcSsQqTtAaZz0123456789.-+eE ,";
    var buf: [96]u8 = undefined;
    const n = count(s, buf.len);
    for (buf[0..n]) |*c| c.* = alphabet[s.index(alphabet.len)];
    var commands: std.ArrayList(core.path.Command) = .empty;
    defer commands.deinit(gpa);
    core.path.parse(gpa, buf[0..n], &commands) catch return;
    var lines: core.path.Polylines = .{};
    defer lines.deinit(gpa);
    try core.path.flatten(gpa, commands.items, .{}, 0.25, &lines);
}

/// Character boundaries and caret positions are valid on any bytes.
pub fn textBoundaries(_: Allocator, s: *Input) !void {
    var buf: [64]u8 = undefined;
    const text = buf[0..s.slice(&buf)];
    // Walking forward visits increasing offsets and ends at the end;
    // walking back from there returns to 0.
    var i: usize = 0;
    var steps: usize = 0;
    while (i < text.len) : (steps += 1) {
        const next = text_edit.nextChar(text, i);
        try testing.expect(next > i and next <= text.len);
        try testing.expect(text_edit.prevChar(text, next) <= i);
        i = next;
    }
    try testing.expect(steps <= text.len);
    var j = text.len;
    while (j > 0) {
        const prev = text_edit.prevChar(text, j);
        try testing.expect(prev < j);
        j = prev;
    }
    for (0..text.len + 1) |k| {
        try testing.expect(text_edit.clampOffset(text, k) <= text.len);
        const word = text_edit.wordAt(text, k);
        try testing.expect(word.start <= word.end and word.end <= text.len);
        try testing.expect(text_edit.prevWordStart(text, k) <= k);
        try testing.expect(text_edit.nextWordEnd(text, k) >= @min(k, text.len));
    }
    // Eliding cuts at a character boundary, within the line.
    {
        const m: core.text.layout.Metrics = .init(null, 10);
        const line: core.text.layout.Line = .{ .start = 0, .end = text.len, .width = core.text.layout.measureMetrics(m, text, null).width };
        const cut = core.text.layout.elide(m, text, line, floatIn(s, -10, 400));
        try testing.expect(cut.end <= text.len);
        // (In invalid UTF-8 the layout takes each bad byte as a character.)
        if (std.unicode.utf8ValidateSlice(text)) try testing.expect(text_edit.clampOffset(text, cut.end) == cut.end);
        try expectFinite(cut.width);
    }
    // Layout without a font, wrapped or not.
    const l: text_edit.TextLayout = .{
        .metrics = .init(null, 10),
        .text = text,
        .max_width = if (s.value(bool)) floatIn(s, 1, 80) else null,
    };
    try expectFinite(l.size().width);
    for (0..4) |_| {
        const o = l.offsetAt(.{ .x = floatIn(s, -10, 200), .y = floatIn(s, -10, 200) });
        try testing.expect(o <= text.len);
        const c = l.caret(o);
        try expectFinite(c.x);
        try expectFinite(c.y);
    }
}

/// Gettext catalogs made of pieces of `.po` syntax parse or fail cleanly;
/// lookups and the plural rule work on any count, and templates format
/// with any arguments.
pub fn poCatalogs(gpa: Allocator, s: *Input) !void {
    const pieces = [_][]const u8{
        "msgid ",     "msgstr ", "msgctxt ",                                                                             "msgid_plural ",                               "msgstr[0] ",                                   "msgstr[1] ", "msgstr[9] ",
        "\"\" ",      "\"a\" ",  "\"{n} b\" ",                                                                           "\"{} c {0}\" ",                               "\"\\n\\\"\" ",                                 "\n",         "\n\n",
        "#, fuzzy\n", "# c\n",   "\"Plural-Forms: nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n != 0 ? 1 : 2);\\n\"", "\"Plural-Forms: nplurals=2; plural=n>1\\n\"", "\"Plural-Forms: nplurals=1; plural=(((n\\n\"", "x",          "\"",
        "[",          "]",       "\t",
    };
    var po: std.ArrayList(u8) = .empty;
    defer po.deinit(gpa);
    while (!s.eos() and po.items.len < 2000) try po.appendSlice(gpa, pieces[s.index(pieces.len)]);
    var cat = core.i18n.Catalog.parse(gpa, po.items) catch return;
    defer cat.deinit();
    const ids = [_][]const u8{ "", "a", "{n} b", "{} c {0}" };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (0..4) |_| {
        const n: i64 = s.valueRangeAtMost(i32, -5, 1_000_000);
        const idx = cat.pluralIndex(n);
        try testing.expect(idx < cat.nplurals);
        const m: core.i18n.Message = .{ .context = if (s.value(bool)) "" else "a", .id = ids[s.index(ids.len)], .plural = if (s.value(bool)) "{n} bs" else null, .n = n };
        const template = cat.lookup(m) orelse m.id;
        out.clearRetainingCapacity();
        try core.i18n.format(&out.writer, template, &.{ .{ .string = "x" }, .{ .int = n } }, n);
    }
}

/// Any sequence of typing, keys, clicks, undo, clipboard, input method
/// text and mode changes keeps a text input consistent.
/// Any mix of directions reorders into a permutation, with levels in
/// range; lines of it lay out with every character once.
pub fn bidiOrder(_: Allocator, s: *Input) !void {
    const bidi = core.text.bidi;
    const palette = [_]u21{ 'a', ' ', '1', '(', ')', '-', '+', ',', '$', '\t', 0x5D0, 0x5D1, 0x627, 0x660, 0x301, 0x200D, 0x202B, 0x2029, '.', '\n' };
    var buf: [4 * 64]u8 = undefined;
    var len: usize = 0;
    var cps: [64]u21 = undefined;
    const n = count(s, 64);
    for (cps[0..n]) |*cp| {
        cp.* = palette[s.index(palette.len)];
        len += std.unicode.utf8Encode(cp.*, buf[len..]) catch unreachable;
    }
    const text = buf[0..len];
    var classes: [64]bidi.Class = undefined;
    var original: [64]bidi.Class = undefined;
    var levels: [64]u8 = undefined;
    var order: [64]u16 = undefined;
    for (cps[0..n], 0..) |cp, i| classes[i] = bidi.class(cp);
    original = classes;
    const base = bidi.paragraphLevel(text);
    try testing.expect(base <= 1);
    bidi.resolve(classes[0..n], base, levels[0..n]);
    bidi.resetTrailing(original[0..n], levels[0..n], base);
    for (levels[0..n]) |l| try testing.expect(l <= base + 2);
    bidi.reorder(levels[0..n], order[0..n]);
    var seen: [64]bool = @splat(false);
    for (order[0..n]) |k| {
        try testing.expect(k < n and !seen[k]);
        seen[k] = true;
    }
    // Laid out (without a font): each character of a line once.
    var lines = core.text.layout.LineIterator.initMetrics(.init(null, 10), text, 30);
    while (lines.next()) |line| {
        var glyphs: core.text.layout.GlyphIterator = .initMetrics(.init(null, 10), text, line);
        var bytes: usize = 0;
        while (glyphs.next()) |g| {
            try testing.expect(g.byte >= line.start and g.byte + g.len <= line.end);
            bytes += g.len;
        }
        try testing.expect(bytes == line.end - line.start);
    }
}

/// Shaping with a font with OpenType layout tables, damaged or not: lines
/// lay out with finite positions, glyphs inside their line, and carets and
/// hit testing within the text.
pub fn shaping(gpa: Allocator, s: *Input) !void {
    const font_bytes = try @import("text/shape_test.zig").arabicFont(gpa);
    defer gpa.free(font_bytes);
    const flips = s.valueRangeAtMost(u8, 0, 16);
    for (0..flips) |_| font_bytes[s.index(font_bytes.len)] ^= s.valueRangeAtMost(u8, 1, 255);
    const font = core.Font.init(font_bytes) catch return;
    const palette = [_]u21{ 0x628, 0x627, 0x644, 0x674, 0x64E, 0x640, 0x200D, 0x5D0, 'a', ' ', '1', '(', '\n', 0x301 };
    var buf: [4 * 48]u8 = undefined;
    var len: usize = 0;
    for (0..count(s, 48)) |_| len += std.unicode.utf8Encode(palette[s.index(palette.len)], buf[len..]) catch unreachable;
    const text = buf[0..len];
    const m: core.text.layout.Metrics = .init(&font, floatIn(s, 1, 40));
    const l: text_edit.TextLayout = .{ .metrics = m, .text = text, .max_width = if (s.value(bool)) floatIn(s, 0, 100) else null };
    var lines = core.text.layout.LineIterator.initMetrics(m, text, l.max_width);
    while (lines.next()) |line| {
        try expectFinite(line.width);
        var glyphs: core.text.layout.GlyphIterator = .initMetrics(m, text, line);
        while (glyphs.next()) |g| {
            try testing.expect(g.byte >= line.start and g.byte + g.len <= line.end);
            try expectFinite(g.x + g.dx + g.dy + g.advance);
        }
        const e = core.text.layout.elide(m, text, line, floatIn(s, 0, 50));
        try testing.expect(e.end >= line.start and e.end <= line.end);
    }
    for (0..text.len + 1) |offset| {
        const p = l.caret(offset);
        try expectFinite(p.x);
        try testing.expect(l.offsetAt(p) <= text.len);
    }
}

pub fn textEditing(gpa: Allocator, s: *Input) !void {
    var window: core.Window = undefined;
    window.init(gpa, .{ .width = 120, .height = 60 });
    var field: core.items.TextInput = undefined;
    field.init(gpa);
    defer {
        window.deinit();
        field.deinit();
    }
    window.rootItem().appendChild(&field.item);
    try field.item.fillParent(gpa);
    field.font_size.set(10);
    window.setFocusItem(&field.item);
    const Key = core.input.Key;
    const texts = [_][]const u8{ "a", "Z", " ", "é", "\u{301}", "\u{1F44D}", "\u{1F3FD}", "\u{200D}", "\u{1F1EE}", "\n", ".", "\u{4E2D}", "\u{5D0}", "\u{627}", "(", "1" };
    const keys = [_][]const u8{ Key.left_arrow, Key.right_arrow, Key.up_arrow, Key.down_arrow, Key.home, Key.end, Key.backspace, Key.delete, Key.@"return", Key.page_up, Key.page_down, Key.tab };
    const shortcuts = "acxvzy";
    var steps: usize = 0;
    var now = core.now();
    while (!s.eos() and steps < 64) : (steps += 1) {
        const mods: core.input.Modifiers = .{ .shift = s.value(bool), .control = s.boolWeighted(3, 1), .alt = s.boolWeighted(4, 1), .meta = s.boolWeighted(6, 1) };
        switch (s.valueRangeAtMost(u8, 0, 9)) {
            0, 1, 2 => window.dispatchKey(.pressed, .{ .text = texts[s.index(texts.len)] }),
            3, 4 => window.dispatchKey(.pressed, .{ .text = keys[s.index(keys.len)], .modifiers = mods }),
            5 => window.dispatchKey(.pressed, .{ .text = shortcuts[s.index(shortcuts.len)..][0..1], .modifiers = .{ .control = true, .shift = mods.shift } }),
            6 => {
                const p: core.Point = .{ .x = floatIn(s, -5, 130), .y = floatIn(s, -5, 70) };
                window.dispatchPointer(.{ .pressed = .{ .position = p, .modifiers = .{ .shift = mods.shift } } });
                window.dispatchPointer(.{ .moved = .{ .position = .{ .x = floatIn(s, -5, 130), .y = p.y } } });
                window.dispatchPointer(.{ .released = .{ .position = p } });
                now += s.valueRangeAtMost(u16, 0, 700);
                core.updateTimersAndAnimations(now);
            },
            7 => window.dispatchPreedit(texts[s.index(texts.len)], count(s, 4)),
            8 => switch (s.valueRangeAtMost(u8, 0, 4)) {
                0 => field.single_line.set(!field.single_line.get()),
                1 => field.input_type.set(if (field.input_type.get() == .text) .password else .text),
                2 => field.read_only.set(!field.read_only.get()),
                3 => field.wrap.set(if (field.wrap.get() == .no_wrap) .word_wrap else .no_wrap),
                else => field.text.set("set by code"),
            },
            else => window.dispatchPointer(.{ .wheel = .{ .position = .{ .x = 10, .y = 10 }, .delta = .{ .y = floatIn(s, -80, 80) } } }),
        }
        // The text stays valid UTF-8 and the caret within it.
        const text = field.text.get();
        try testing.expect(std.unicode.utf8ValidateSlice(text));
        try testing.expect(field.cursor() <= text.len);
        try testing.expect(field.anchor() <= text.len);
        try expectFinite(field.scroll_x.get());
        try expectFinite(field.scroll_y.get());
    }
    // Drawing works whatever happened.
    var dl: core.rendering.DisplayList = .init(gpa, .{ .width = 120, .height = 60 });
    defer dl.deinit();
    _ = try window.render(dl.renderer(), .full);
}
