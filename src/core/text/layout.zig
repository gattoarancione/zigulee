// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Text layout with a font: line breaking (explicit newlines, and word
//! wrapping at spaces when a width is given) and glyph positioning with
//! kerning. Measurement and rendering both use this, so they always agree.
//! Characters the font lacks come from fallback fonts, if given; letter
//! spacing widens (or narrows) every character's advance. Long
//! lines can be elided ("Long tex…"). Lines with right-to-left text or
//! combining marks are shaped (shape.zig: Arabic forms, ligatures, mark
//! positioning) and shown in visual order (bidi.zig); other lines use the
//! character map and kerning only.

const std = @import("std");
const Font = @import("truetype.zig").Font;
const bidi = @import("bidi.zig");
const shape = @import("shape.zig");
const Size = @import("../geometry.zig").Size;

/// A line of text: `text[start..end]`, `width` pixels wide.
pub const Line = struct {
    start: usize,
    end: usize,
    width: f32,
};

/// Decodes the code point at `i`; invalid UTF-8 yields U+FFFD for one byte.
pub fn decode(text: []const u8, i: usize) struct { cp: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return .{ .cp = 0xfffd, .len = 1 };
    if (i + len > text.len) return .{ .cp = 0xfffd, .len = 1 };
    const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return .{ .cp = 0xfffd, .len = 1 };
    return .{ .cp = cp, .len = len };
}

/// A glyph of the primary font (`font` 0) or of a fallback font (`font`
/// k: `fallbacks[k - 1]`).
pub const Glyph = struct {
    id: u16,
    font: u8 = 0,
};

/// Glyph metrics: a font's (with fallbacks for the characters it lacks), or
/// an approximation without one (each code point 0.6 em wide, lines 1.2 em
/// tall), so editing still works fontless.
pub const Metrics = struct {
    font: ?*const Font,
    /// Fonts for characters `font` lacks, tried in order.
    fallbacks: []const *const Font = &.{},
    font_size: f32,
    scale: f32,
    /// Pixels added after each character (negative: closer together).
    spacing: f32 = 0,

    pub fn init(font: ?*const Font, font_size: f32) Metrics {
        return .{ .font = font, .font_size = font_size, .scale = if (font) |f| f.scale(font_size) else 1 };
    }

    pub fn initFallbacks(font: ?*const Font, fallbacks: []const *const Font, font_size: f32) Metrics {
        var m: Metrics = .init(font, font_size);
        m.fallbacks = fallbacks[0..@min(fallbacks.len, 255)];
        return m;
    }

    /// These metrics with `spacing` pixels after each character.
    pub fn withSpacing(m: Metrics, spacing: f32) Metrics {
        var out = m;
        out.spacing = spacing;
        return out;
    }

    /// The font glyph `g` is in.
    pub fn fontOf(m: Metrics, g: Glyph) ?*const Font {
        return if (g.font == 0) m.font else m.fallbacks[g.font - 1];
    }

    /// The glyph for `cp`: from the font, else the first fallback that has
    /// it, else the font's missing glyph.
    pub fn glyph(m: Metrics, cp: u21) Glyph {
        const f = m.font orelse return .{ .id = 0 };
        const id = f.glyphIndex(cp);
        if (id != 0 or cp < 0x20) return .{ .id = id };
        for (m.fallbacks, 1..) |fallback, k| {
            const fid = fallback.glyphIndex(cp);
            if (fid != 0) return .{ .id = fid, .font = @intCast(k) };
        }
        return .{ .id = 0 };
    }

    /// Advance of glyph `g` (with the letter spacing), plus kerning after
    /// `prev`.
    pub fn advance(m: Metrics, prev: ?Glyph, g: Glyph) f32 {
        const f = m.fontOf(g) orelse return 0.6 * m.font_size + m.spacing;
        var a = @as(f32, @floatFromInt(f.advanceWidth(g.id))) * f.scale(m.font_size) + m.spacing;
        if (prev) |p| a += m.kerning(p, g);
        return a;
    }

    /// Kerning between glyphs of the same font.
    pub fn kerning(m: Metrics, prev: Glyph, g: Glyph) f32 {
        if (prev.font != g.font) return 0;
        const f = m.fontOf(g) orelse return 0;
        return @as(f32, @floatFromInt(f.kerning(prev.id, g.id))) * f.scale(m.font_size);
    }

    pub fn lineHeight(m: Metrics) f32 {
        return if (m.font) |f| f.lineHeight(m.font_size) else 1.2 * m.font_size;
    }
};

/// Splits text into lines.
pub const LineIterator = struct {
    metrics: Metrics,
    text: []const u8,
    /// Wrap lines longer than this (null: break only at newlines).
    max_width: ?f32,
    pos: usize = 0,
    finished: bool = false,

    pub fn init(font: *const Font, text: []const u8, font_size: f32, max_width: ?f32) LineIterator {
        return initMetrics(.init(font, font_size), text, max_width);
    }

    pub fn initMetrics(metrics: Metrics, text: []const u8, max_width: ?f32) LineIterator {
        return .{ .metrics = metrics, .text = text, .max_width = max_width };
    }

    pub fn next(it: *LineIterator) ?Line {
        if (it.finished) return null;
        const r = it.fit(it.pos);
        it.pos = r.next;
        if (r.wrapped) {
            while (it.pos < it.text.len and it.text[it.pos] == ' ') it.pos += 1;
        }
        // Text ending in a newline has an empty last line.
        if (it.pos >= it.text.len and !r.newline) it.finished = true;
        return r.line;
    }

    const Fit = struct { line: Line, next: usize, newline: bool, wrapped: bool };

    /// Takes as much text from `start` as fits on one line.
    fn fit(it: *LineIterator, start: usize) Fit {
        const r = it.fitWith(start, null) orelse {
            // Text that needs shaping: break with its shaped advances, and
            // measure the line as it will be shown.
            var advances: [shape.max_chars]f32 = undefined;
            const n = shapedAdvances(it.metrics, it.text, start, &advances);
            var f = it.fitWith(start, advances[0..n]).?;
            var glyphs: GlyphIterator = .initLogical(it.metrics, it.text, f.line);
            f.line.width = 0;
            while (glyphs.next()) |g| f.line.width = @max(f.line.width, g.x + g.advance);
            return f;
        };
        return r;
    }

    /// With the advances of the characters from `start` if given, else
    /// null if a character needing shaping comes within reach of them.
    fn fitWith(it: *LineIterator, start: usize, shaped: ?[]const f32) ?Fit {
        var x: f32 = 0;
        var prev: ?Glyph = null;
        var i = start;
        var k: usize = 0;
        // The last place a line could break: after the text before a space.
        var last_break: ?Fit = null;
        while (i < it.text.len) : (k += 1) {
            const d = decode(it.text, i);
            if (d.cp == '\n') return .{ .line = .{ .start = start, .end = i, .width = x }, .next = i + 1, .newline = true, .wrapped = false };
            const g = it.metrics.glyph(d.cp);
            if (shaped == null and k < shape.max_chars and shape.needsShaping(d.cp)) return null;
            const advance = if (shaped) |a| (if (k < a.len) a[k] else it.metrics.advance(prev, g)) else it.metrics.advance(prev, g);

            if (it.max_width) |max| if (x + advance > max and i > start) {
                if (d.cp == ' ') return .{ .line = .{ .start = start, .end = i, .width = x }, .next = i, .newline = false, .wrapped = true };
                if (last_break) |b| return b;
                // A word longer than the line: break inside it.
                return .{ .line = .{ .start = start, .end = i, .width = x }, .next = i, .newline = false, .wrapped = true };
            };
            if (d.cp == ' ' and i > start) {
                last_break = .{ .line = .{ .start = start, .end = i, .width = x }, .next = i, .newline = false, .wrapped = true };
            }
            x += advance;
            prev = g;
            i += d.len;
        }
        return .{ .line = .{ .start = start, .end = i, .width = x }, .next = i, .newline = false, .wrapped = false };
    }
};

/// A glyph placed on a line: `x` pixels from the line start. It shows
/// `text[byte .. byte + len]` (several characters for a ligature).
pub const PositionedGlyph = struct {
    glyph: u16,
    /// The font the glyph is in (null without a font).
    font: ?*const Font,
    x: f32,
    advance: f32,
    byte: usize,
    len: usize,
    /// Shown right to left: its text starts at its right edge.
    rtl: bool = false,
    /// Where it is drawn, from (`x`, the baseline): shaping moves glyphs
    /// (marks onto their base). y down.
    dx: f32 = 0,
    dy: f32 = 0,
};

/// The advances of the characters from `start` (to the end of its
/// paragraph, at most `out.len`), shaped; ligatures' on their first
/// character. Returns how many.
fn shapedAdvances(m: Metrics, text: []const u8, start: usize, out: []f32) usize {
    var end = start;
    var n: usize = 0;
    while (end < text.len and n < out.len) : (n += 1) {
        const d = decode(text, end);
        if (d.cp == '\n') break;
        end += d.len;
    }
    @memset(out[0..n], 0);
    const c = Complex.of(m, text, .{ .start = start, .end = end, .width = 0 }, false) orelse return 0;
    for (c.glyphs[0..c.n]) |g| out[g.char] += g.advance;
    return n;
}

/// The direction (0 left to right, 1 right to left) of the paragraph
/// containing `offset`.
pub fn paragraphLevelAt(text: []const u8, offset: usize) u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..@min(offset, text.len)], '\n')) |i| i + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return bidi.paragraphLevel(text[start..end]);
}

/// Characters per line shaped and laid out in visual order; longer lines
/// show unshaped, in logical order.
pub const max_bidi_chars = shape.max_chars;

/// A shaped line, its glyphs in the order shown (or logical order).
const Complex = struct {
    n: u16 = 0,
    glyphs: [shape.max_chars]Entry = undefined,
    /// Byte offsets of the characters (and the line end).
    start: [shape.max_chars + 1]u32 = undefined,

    const Entry = struct {
        glyph: u16,
        font: u8,
        rtl: bool,
        char: u16,
        char_end: u16,
        x: f32,
        dx: f32,
        dy: f32,
        advance: f32,
    };

    /// Null when the line needs no shaping (or is too long).
    fn of(m: Metrics, text: []const u8, line: Line, visual: bool) ?Complex {
        const base = paragraphLevelAt(text, line.start);
        var needed = base == 1 and visual;
        var count: usize = 0;
        var i = line.start;
        while (i < line.end) : (count += 1) {
            const d = decode(text, i);
            if (shape.needsShaping(d.cp)) needed = true;
            i += d.len;
        }
        if (!needed or count > shape.max_chars) return null;
        var c: Complex = .{};
        var cps: [shape.max_chars]u21 = undefined;
        var classes: [shape.max_chars]bidi.Class = undefined;
        var original: [shape.max_chars]bidi.Class = undefined;
        var levels: [shape.max_chars]u8 = undefined;
        i = line.start;
        for (0..count) |k| {
            const d = decode(text, i);
            c.start[k] = @intCast(i);
            cps[k] = d.cp;
            classes[k] = bidi.class(d.cp);
            original[k] = classes[k];
            i += d.len;
        }
        c.start[count] = @intCast(line.end);
        bidi.resolve(classes[0..count], base, levels[0..count]);
        bidi.resetTrailing(original[0..count], levels[0..count], base);

        var infos: [shape.max_chars]shape.Info = undefined;
        var buf: shape.Buffer = .{ .info = &infos, .len = 0 };
        shape.shape(m, cps[0..count], levels[0..count], &buf);
        const n = buf.len;
        c.n = @intCast(n);

        // The order shown: glyphs take their characters' levels.
        var order: [shape.max_chars]u16 = undefined;
        if (visual) {
            var glyph_levels: [shape.max_chars]u8 = undefined;
            for (infos[0..n], 0..) |g, k| glyph_levels[k] = levels[g.char];
            bidi.reorder(glyph_levels[0..n], order[0..n]);
        } else for (order[0..n], 0..) |*o, k| {
            o.* = @intCast(k);
        }

        // Pen positions of glyphs that advance it, then attached glyphs from
        // what they are attached to (by logical index).
        var x: [shape.max_chars]f32 = undefined;
        var dx: [shape.max_chars]f32 = undefined;
        var dy: [shape.max_chars]f32 = undefined;
        var advance: [shape.max_chars]f32 = undefined;
        var resolved: [shape.max_chars]bool = @splat(false);
        var pen: f32 = 0;
        for (order[0..n]) |k| {
            const g = infos[k];
            const f = m.fontOf(.{ .id = g.glyph, .font = g.font });
            const scale = if (f) |ff| ff.scale(m.font_size) else 1;
            advance[k] = if (f == null) 0.6 * m.font_size else @as(f32, @floatFromInt(g.x_advance)) * scale;
            // Letter spacing after each character, not inside joined
            // (cursive) script or after marks.
            if (g.attach == shape.ot_no_attach) advance[k] += m.spacing;
            dx[k] = @as(f32, @floatFromInt(g.x_offset)) * scale;
            dy[k] = -@as(f32, @floatFromInt(g.y_offset)) * scale;
            if (g.attach != shape.ot_no_attach and !g.cursive) continue;
            x[k] = pen;
            pen += advance[k];
            if (g.attach == shape.ot_no_attach) resolved[k] = true;
        }
        for (0..n) |k| resolveAttached(infos[0..n], k, &x, &dx, &dy, &resolved, 0);

        for (order[0..n], 0..) |k, v| {
            const g = infos[k];
            c.glyphs[v] = .{
                .glyph = g.glyph,
                .font = g.font,
                .rtl = g.rtl,
                .char = g.char,
                .char_end = g.char_end,
                .x = x[k],
                .dx = dx[k],
                .dy = dy[k],
                .advance = advance[k],
            };
        }
        return c;
    }

    /// Places glyph `k` from the glyph it is attached to.
    fn resolveAttached(infos: []const shape.Info, k: usize, x: []f32, dx: []f32, dy: []f32, resolved: []bool, depth: u8) void {
        if (resolved[k]) return;
        resolved[k] = true;
        const g = infos[k];
        const p = g.attach;
        if (p >= infos.len or depth > 16) {
            if (g.cursive) return;
            x[k] = 0;
            return;
        }
        resolveAttached(infos, p, x, dx, dy, resolved, depth + 1);
        dy[k] += dy[p];
        if (g.cursive) return;
        // Marks: drawn from their base's drawn position.
        x[k] = x[p] + dx[p] + dx[k];
        dx[k] = 0;
    }
};

/// The glyphs of one line, with advances and kerning applied, from left to
/// right as shown (right-to-left text reordered, its brackets mirrored).
pub const GlyphIterator = struct {
    metrics: Metrics,
    text: []const u8,
    i: usize,
    end: usize,
    x: f32 = 0,
    prev: ?Glyph = null,
    /// Set for shaped lines: their glyphs, and the next one.
    complex: ?Complex = null,
    v: u16 = 0,

    pub fn init(font: *const Font, text: []const u8, font_size: f32, line: Line) GlyphIterator {
        return initMetrics(.init(font, font_size), text, line);
    }

    pub fn initMetrics(metrics: Metrics, text: []const u8, line: Line) GlyphIterator {
        var it: GlyphIterator = .{ .metrics = metrics, .text = text, .i = line.start, .end = line.end };
        it.complex = Complex.of(metrics, text, line, true);
        return it;
    }

    /// In logical order (the text's order), for measuring parts of lines.
    pub fn initLogical(metrics: Metrics, text: []const u8, line: Line) GlyphIterator {
        var it: GlyphIterator = .{ .metrics = metrics, .text = text, .i = line.start, .end = line.end };
        it.complex = Complex.of(metrics, text, line, false);
        return it;
    }

    pub fn next(it: *GlyphIterator) ?PositionedGlyph {
        if (it.complex) |*c| return it.nextShaped(c);
        if (it.i >= it.end) return null;
        const byte = it.i;
        const d = decode(it.text, it.i);
        it.i += d.len;
        const g = it.metrics.glyph(d.cp);
        if (it.prev) |p| it.x += it.metrics.kerning(p, g);
        const advance = it.metrics.advance(null, g);
        const placed: PositionedGlyph = .{ .glyph = g.id, .font = it.metrics.fontOf(g), .x = it.x, .advance = advance, .byte = byte, .len = d.len };
        it.x += advance;
        it.prev = g;
        return placed;
    }

    fn nextShaped(it: *GlyphIterator, c: *const Complex) ?PositionedGlyph {
        if (it.v >= c.n) return null;
        const g = c.glyphs[it.v];
        it.v += 1;
        const byte: usize = c.start[g.char];
        return .{
            .glyph = g.glyph,
            .font = it.metrics.fontOf(.{ .id = g.glyph, .font = g.font }),
            .x = g.x,
            .advance = g.advance,
            .byte = byte,
            .len = c.start[g.char_end] - byte,
            .rtl = g.rtl,
            .dx = g.dx,
            .dy = g.dy,
        };
    }
};

/// The size of laid-out text: the widest line, and all lines' height.
pub fn measure(font: *const Font, text: []const u8, font_size: f32, max_width: ?f32) Size {
    return measureMetrics(.init(font, font_size), text, max_width);
}

pub fn measureMetrics(m: Metrics, text: []const u8, max_width: ?f32) Size {
    var it: LineIterator = .initMetrics(m, text, max_width);
    var width: f32 = 0;
    var lines: f32 = 0;
    while (it.next()) |line| {
        width = @max(width, line.width);
        lines += 1;
    }
    return .{ .width = width, .height = lines * m.lineHeight() };
}

/// "…", or "..." for fonts without it: what ends an elided line.
pub const Ellipsis = struct {
    glyph: Glyph,
    count: u8,
    /// Of one glyph.
    advance: f32,

    pub fn width(e: Ellipsis) f32 {
        return e.advance * @as(f32, @floatFromInt(e.count));
    }
};

pub fn ellipsis(m: Metrics) Ellipsis {
    const g = m.glyph(0x2026);
    if (g.id != 0 or m.font == null) return .{ .glyph = g, .count = 1, .advance = m.advance(null, g) };
    const dot = m.glyph('.');
    return .{ .glyph = dot, .count = 3, .advance = m.advance(null, dot) };
}

/// Where to cut `line` so that it and an ellipsis fit in `max_width`: the
/// text kept is `text[line.start..end]`, `width` wide. A line that fits is
/// kept whole (`elided` false).
pub fn elide(m: Metrics, text: []const u8, line: Line, max_width: f32) struct { end: usize, width: f32, elided: bool } {
    if (line.width <= max_width) return .{ .end = line.end, .width = line.width, .elided = false };
    const room = max_width - ellipsis(m).width();
    var glyphs: GlyphIterator = .initLogical(m, text, line);
    var end = line.start;
    var width: f32 = 0;
    while (glyphs.next()) |g| {
        if (g.x + g.advance > room) break;
        end = g.byte + g.len;
        width = g.x + g.advance;
    }
    // Shaped again, what is kept can be wider (letters before the cut
    // take other forms): cut more until it fits.
    for (0..8) |_| {
        // No space before the ellipsis.
        while (end > line.start and text[end - 1] == ' ') end -= 1;
        if (end == line.end) break;
        var shorter: GlyphIterator = .initLogical(m, text, .{ .start = line.start, .end = end, .width = 0 });
        width = 0;
        while (shorter.next()) |g| width = @max(width, g.x + g.advance);
        if (width <= room or end == line.start) break;
        end -= 1;
        while (end > line.start and text[end] & 0xc0 == 0x80) end -= 1;
    }
    return .{ .end = end, .width = width, .elided = true };
}
