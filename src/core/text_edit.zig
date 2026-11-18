// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Text editing logic used by `TextInput`: character and word boundaries,
//! caret geometry and hit testing over laid-out text, and an undo history.
//! Offsets are byte offsets into UTF-8 text, always on code point
//! boundaries.

const std = @import("std");
const Allocator = std.mem.Allocator;
const layout = @import("text/layout.zig");
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Size = geometry.Size;
const TextHorizontalAlignment = @import("rendering.zig").TextHorizontalAlignment;

pub const Metrics = layout.Metrics;
pub const Line = layout.Line;

// ---- Boundaries ----

fn isContinuation(b: u8) bool {
    return b & 0xc0 == 0x80;
}

/// `i` moved back to a code point boundary and into the text.
pub fn clampOffset(text: []const u8, i: usize) usize {
    var j = @min(i, text.len);
    while (j > 0 and j < text.len and isContinuation(text[j])) j -= 1;
    return j;
}

/// The start of the code point before `i`.
pub fn prevCodePoint(text: []const u8, i: usize) usize {
    var j = i;
    while (j > 0) {
        j -= 1;
        if (!isContinuation(text[j])) break;
    }
    return j;
}

/// The end of the code point at `i`.
pub fn nextCodePoint(text: []const u8, i: usize) usize {
    if (i >= text.len) return text.len;
    var j = i + 1;
    while (j < text.len and isContinuation(text[j])) j += 1;
    return j;
}

fn codePointAt(text: []const u8, i: usize) u21 {
    if (i >= text.len) return 0;
    const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return 0xfffd;
    if (i + n > text.len) return 0xfffd;
    return std.unicode.utf8Decode(text[i..][0..n]) catch 0xfffd;
}

/// Code points that attach to the one before them: combining marks,
/// variation selectors, emoji skin tones, the zero-width joiner, keycaps
/// and emoji tags. (An approximation of Unicode's extended grapheme
/// clusters, without tables.)
fn extends(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036f,
        0x0483...0x0489,
        0x0591...0x05bd,
        0x0610...0x061a,
        0x064b...0x065f,
        0x0670,
        0x06d6...0x06dc,
        0x06df...0x06e4,
        0x0900...0x0903,
        0x093a...0x094f,
        0x0e31,
        0x0e34...0x0e3a,
        0x0e47...0x0e4e,
        0x1ab0...0x1aff,
        0x1dc0...0x1dff,
        0x200c,
        0x200d,
        0x20d0...0x20ff,
        0xfe00...0xfe0f,
        0xfe20...0xfe2f,
        0x1f3fb...0x1f3ff,
        0xe0020...0xe007f,
        0xe0100...0xe01ef,
        => true,
        else => false,
    };
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1f1e6 and cp <= 0x1f1ff;
}

/// The start of the character (grapheme cluster) before `i`.
pub fn prevChar(text: []const u8, i: usize) usize {
    var j = prevCodePoint(text, i);
    // Flags are pairs of regional indicators.
    if (isRegionalIndicator(codePointAt(text, j))) {
        var count: usize = 0;
        var k = j;
        while (k > 0) {
            const p = prevCodePoint(text, k);
            if (!isRegionalIndicator(codePointAt(text, p))) break;
            count += 1;
            k = p;
        }
        if (count % 2 == 1) j = prevCodePoint(text, j);
        return j;
    }
    while (j > 0) {
        const cp = codePointAt(text, j);
        const p = prevCodePoint(text, j);
        // A mark attaches to what precedes it; anything after a joiner
        // joins the sequence.
        if (extends(cp) or codePointAt(text, p) == 0x200d) {
            j = p;
            continue;
        }
        break;
    }
    return j;
}

/// The end of the character (grapheme cluster) at `i`.
pub fn nextChar(text: []const u8, i: usize) usize {
    if (i >= text.len) return text.len;
    const first = codePointAt(text, i);
    var j = nextCodePoint(text, i);
    if (isRegionalIndicator(first)) {
        if (j < text.len and isRegionalIndicator(codePointAt(text, j))) j = nextCodePoint(text, j);
        return j;
    }
    while (j < text.len) {
        const cp = codePointAt(text, j);
        if (cp == 0x200d) {
            // The joiner and what it joins.
            j = nextCodePoint(text, nextCodePoint(text, j));
            continue;
        }
        if (!extends(cp)) break;
        j = nextCodePoint(text, j);
    }
    return j;
}

pub const Class = enum { space, word, punct };

pub fn classAt(text: []const u8, i: usize) Class {
    const b = text[i];
    if (b == ' ' or b == '\t' or b == '\n' or b == '\r') return .space;
    if (std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80) return .word;
    return .punct;
}

/// The start of the word before `i` (skipping spaces first), as for
/// Ctrl+Left and Ctrl+Backspace.
pub fn prevWordStart(text: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and classAt(text, prevChar(text, j)) == .space) j = prevChar(text, j);
    if (j == 0) return 0;
    const class = classAt(text, prevChar(text, j));
    while (j > 0 and classAt(text, prevChar(text, j)) == class) j = prevChar(text, j);
    return j;
}

/// The end of the word after `i` (skipping spaces first), as for
/// Ctrl+Right and Ctrl+Delete.
pub fn nextWordEnd(text: []const u8, i: usize) usize {
    var j = i;
    while (j < text.len and classAt(text, j) == .space) j = nextChar(text, j);
    if (j >= text.len) return text.len;
    const class = classAt(text, j);
    while (j < text.len and classAt(text, j) == class) j = nextChar(text, j);
    return j;
}

pub const Range = struct {
    start: usize,
    end: usize,
};

/// The word (or run of spaces or punctuation) at `i`, for double clicks.
pub fn wordAt(text: []const u8, i: usize) Range {
    if (text.len == 0) return .{ .start = 0, .end = 0 };
    // At the end, or between a word and something else: take the left side.
    const at = if (i >= text.len or (i > 0 and classAt(text, i) != .word and classAt(text, prevChar(text, i)) == .word)) prevChar(text, i) else i;
    const class = classAt(text, at);
    var start = at;
    while (start > 0 and classAt(text, prevChar(text, start)) == class) start = prevChar(text, start);
    var end = nextChar(text, at);
    while (end < text.len and classAt(text, end) == class) end = nextChar(text, end);
    return .{ .start = start, .end = end };
}

/// The paragraph (text between newlines) containing `i`.
pub fn paragraphAt(text: []const u8, i: usize) Range {
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..@min(i, text.len)], '\n')) |n| n + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, text, @min(i, text.len), '\n') orelse text.len;
    return .{ .start = start, .end = end };
}

// ---- Geometry ----

/// Text laid out in lines, as `drawText` lays it out (from the top, each
/// line aligned in `box_width`): caret positions and hit testing.
pub const TextLayout = struct {
    metrics: Metrics,
    text: []const u8,
    /// Wrap width (null: lines break at newlines only).
    max_width: ?f32 = null,
    alignment: TextHorizontalAlignment = .left,
    /// The width lines are aligned in (drawn `box_width` wide).
    box_width: f32 = 0,

    /// Where `line` starts: as `drawText` aligns it.
    pub fn lineLeft(l: TextLayout, line: Line) f32 {
        return switch (l.alignment) {
            .left => 0,
            .center => (l.box_width - line.width) / 2,
            .right => l.box_width - line.width,
        };
    }

    pub fn lineHeight(l: TextLayout) f32 {
        return l.metrics.lineHeight();
    }

    fn lines(l: TextLayout) layout.LineIterator {
        return .initMetrics(l.metrics, l.text, l.max_width);
    }

    pub fn size(l: TextLayout) Size {
        var it = l.lines();
        var width: f32 = 0;
        var n: f32 = 0;
        while (it.next()) |line| {
            width = @max(width, line.width);
            n += 1;
        }
        return .{ .width = width, .height = n * l.lineHeight() };
    }

    pub const LineInfo = struct {
        line: Line,
        index: usize,
        /// Where the next line starts (the text length for the last line).
        next_start: usize,
        last: bool,
    };

    /// The line showing the caret at `offset`. A line covers its start up
    /// to the next line's start, so offsets in spaces swallowed by wrapping
    /// belong to the line before.
    pub fn lineOf(l: TextLayout, offset: usize) LineInfo {
        var it = l.lines();
        var current = it.next().?;
        var index: usize = 0;
        while (it.next()) |next| {
            if (offset < next.start) return .{ .line = current, .index = index, .next_start = next.start, .last = false };
            current = next;
            index += 1;
        }
        return .{ .line = current, .index = index, .next_start = l.text.len, .last = true };
    }

    /// Line number `index`, clamped to the last line.
    pub fn lineAt(l: TextLayout, index: usize) LineInfo {
        var it = l.lines();
        var current = it.next().?;
        var i: usize = 0;
        while (it.next()) |next| {
            if (i == index) return .{ .line = current, .index = i, .next_start = next.start, .last = false };
            current = next;
            i += 1;
        }
        return .{ .line = current, .index = i, .next_start = l.text.len, .last = true };
    }

    /// The x position of `offset` on `line`: the edge where the character
    /// at `offset` starts (its right edge if it reads right to left).
    pub fn xOf(l: TextLayout, line: Line, offset: usize) f32 {
        return l.lineLeft(line) + l.xInLine(line, offset);
    }

    /// `xOf` from the line's start.
    fn xInLine(l: TextLayout, line: Line, offset: usize) f32 {
        var glyphs: layout.GlyphIterator = .initMetrics(l.metrics, l.text, line);
        // After the line's last character: beside the logically last glyph.
        var after_last: ?f32 = null;
        var mark: ?f32 = null;
        while (glyphs.next()) |g| {
            if (offset >= g.byte and offset < g.byte + g.len) {
                // Marks take no room: what they sit on decides.
                if (g.advance == 0) {
                    mark = g.x;
                    continue;
                }
                // Inside a ligature: a share of its width per byte.
                const part = @as(f32, @floatFromInt(offset - g.byte)) / @as(f32, @floatFromInt(g.len)) * g.advance;
                return if (g.rtl) g.x + g.advance - part else g.x + part;
            }
            if (g.byte + g.len == line.end and g.advance > 0) after_last = if (g.rtl) g.x else g.x + g.advance;
        }
        return mark orelse after_last orelse (if (line.end > line.start) line.width else 0);
    }

    /// The top-left corner of the caret at `offset`.
    pub fn caret(l: TextLayout, offset: usize) Point {
        const info = l.lineOf(offset);
        return .{ .x = l.xOf(info.line, offset), .y = @as(f32, @floatFromInt(info.index)) * l.lineHeight() };
    }

    /// The offset on `line` closest to `x`.
    pub fn offsetInLine(l: TextLayout, line: Line, at: f32) usize {
        const x = at - l.lineLeft(line);
        var glyphs: layout.GlyphIterator = .initMetrics(l.metrics, l.text, line);
        var right_edge: usize = line.end;
        while (glyphs.next()) |g| {
            if (g.advance == 0) continue; // marks
            // Left of a glyph's middle: its left edge, where a left-to-right
            // character starts and a right-to-left one ends.
            if (x < g.x + g.advance / 2) return if (g.rtl) g.byte + g.len else g.byte;
            right_edge = if (g.rtl) g.byte else g.byte + g.len;
        }
        return right_edge;
    }

    /// The offset closest to `p`.
    pub fn offsetAt(l: TextLayout, p: Point) usize {
        const row: usize = if (p.y <= 0) 0 else @intFromFloat(@floor(p.y / l.lineHeight()));
        return l.offsetInLine(l.lineAt(row).line, p.x);
    }
};

// ---- Undo history ----

/// Edits that can be undone and redone. Consecutive typing (or deleting)
/// merges into one step until `seal` is called, e.g. when the caret moves.
pub const History = struct {
    undo_stack: std.ArrayList(Edit) = .empty,
    redo_stack: std.ArrayList(Edit) = .empty,
    open: bool = false,

    /// Replacing `removed` at `pos` with `inserted`.
    pub const Edit = struct {
        pos: usize,
        removed: std.ArrayList(u8),
        inserted: std.ArrayList(u8),
        /// Caret and anchor before the edit (restored by undo).
        cursor: usize,
        anchor: usize,
        kind: Kind,

        fn deinit(e: *Edit, gpa: Allocator) void {
            e.removed.deinit(gpa);
            e.inserted.deinit(gpa);
        }
    };

    pub const Kind = enum { typing, backspace, delete, other };

    pub fn deinit(h: *History, gpa: Allocator) void {
        h.clear(gpa);
        h.undo_stack.deinit(gpa);
        h.redo_stack.deinit(gpa);
    }

    pub fn clear(h: *History, gpa: Allocator) void {
        for (h.undo_stack.items) |*e| e.deinit(gpa);
        for (h.redo_stack.items) |*e| e.deinit(gpa);
        h.undo_stack.clearRetainingCapacity();
        h.redo_stack.clearRetainingCapacity();
        h.open = false;
    }

    /// Ends the current undo step: the next edit starts a new one.
    pub fn seal(h: *History) void {
        h.open = false;
    }

    pub fn canUndo(h: *const History) bool {
        return h.undo_stack.items.len > 0;
    }

    pub fn canRedo(h: *const History) bool {
        return h.redo_stack.items.len > 0;
    }

    pub fn record(h: *History, gpa: Allocator, pos: usize, removed: []const u8, inserted: []const u8, cursor: usize, anchor: usize, kind: Kind) Allocator.Error!void {
        for (h.redo_stack.items) |*e| e.deinit(gpa);
        h.redo_stack.clearRetainingCapacity();
        if (h.open and h.undo_stack.items.len > 0) {
            const last = &h.undo_stack.items[h.undo_stack.items.len - 1];
            if (last.kind == kind) switch (kind) {
                .typing => if (removed.len == 0 and last.removed.items.len == 0 and pos == last.pos + last.inserted.items.len and
                    std.mem.indexOfScalar(u8, inserted, '\n') == null)
                {
                    return last.inserted.appendSlice(gpa, inserted);
                },
                .backspace => if (inserted.len == 0 and pos + removed.len == last.pos) {
                    try last.removed.insertSlice(gpa, 0, removed);
                    last.pos = pos;
                    return;
                },
                .delete => if (inserted.len == 0 and pos == last.pos) {
                    return last.removed.appendSlice(gpa, removed);
                },
                .other => {},
            };
        }
        var e: Edit = .{ .pos = pos, .removed = .empty, .inserted = .empty, .cursor = cursor, .anchor = anchor, .kind = kind };
        errdefer e.deinit(gpa);
        try e.removed.appendSlice(gpa, removed);
        try e.inserted.appendSlice(gpa, inserted);
        try h.undo_stack.append(gpa, e);
        h.open = kind != .other;
    }

    /// The step to undo; apply its reverse, then call `undone`.
    pub fn peekUndo(h: *History) ?*const Edit {
        h.open = false;
        if (h.undo_stack.items.len == 0) return null;
        return &h.undo_stack.items[h.undo_stack.items.len - 1];
    }

    pub fn undone(h: *History, gpa: Allocator) Allocator.Error!void {
        try h.redo_stack.ensureUnusedCapacity(gpa, 1);
        h.redo_stack.appendAssumeCapacity(h.undo_stack.pop().?);
    }

    /// The step to redo; apply it, then call `redone`.
    pub fn peekRedo(h: *History) ?*const Edit {
        h.open = false;
        if (h.redo_stack.items.len == 0) return null;
        return &h.redo_stack.items[h.redo_stack.items.len - 1];
    }

    pub fn redone(h: *History, gpa: Allocator) Allocator.Error!void {
        try h.undo_stack.ensureUnusedCapacity(gpa, 1);
        h.undo_stack.appendAssumeCapacity(h.redo_stack.pop().?);
    }
};

// ---- Tests ----

const testing = std.testing;

test "character and word boundaries" {
    const t = "héllo, wörld  foo";
    try testing.expectEqual(@as(usize, 1), prevChar(t, 3)); // before é (2 bytes)
    try testing.expectEqual(@as(usize, 3), nextChar(t, 1));
    try testing.expectEqual(@as(usize, 1), clampOffset(t, 2));
    try testing.expectEqual(t.len, clampOffset(t, 100));

    try testing.expectEqual(@as(usize, 6), nextWordEnd(t, 0)); // "héllo"
    try testing.expectEqual(@as(usize, 7), nextWordEnd(t, 6)); // ","
    try testing.expectEqual(@as(usize, 14), nextWordEnd(t, 7)); // " wörld"
    try testing.expectEqual(t.len, nextWordEnd(t, 14));
    try testing.expectEqual(@as(usize, 16), prevWordStart(t, t.len)); // "foo"
    try testing.expectEqual(@as(usize, 8), prevWordStart(t, 16)); // "wörld  "
    try testing.expectEqual(@as(usize, 0), prevWordStart(t, 6));

    try testing.expectEqual(Range{ .start = 8, .end = 14 }, wordAt(t, 11));
    try testing.expectEqual(Range{ .start = 0, .end = 6 }, wordAt(t, 6)); // just after a word
    try testing.expectEqual(Range{ .start = 16, .end = t.len }, wordAt(t, t.len));
    try testing.expectEqual(Range{ .start = 3, .end = 6 }, paragraphAt("ab\ncde\nf", 4));
}

test "characters made of several code points" {
    const e_acute = "e\u{301}"; // e + combining acute
    const thumbs = "\u{1F44D}\u{1F3FD}"; // thumbs up + skin tone
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const flags = "\u{1F1EE}\u{1F1F9}\u{1F1EF}\u{1F1F5}"; // two flags
    const t = "a" ++ e_acute ++ thumbs ++ family ++ flags ++ "z";
    var stops: std.ArrayList(usize) = .empty;
    defer stops.deinit(testing.allocator);
    var i: usize = 0;
    while (i < t.len) {
        i = nextChar(t, i);
        try stops.append(testing.allocator, i);
    }
    const expected = [_]usize{ 1, 1 + e_acute.len, 1 + e_acute.len + thumbs.len, 1 + e_acute.len + thumbs.len + family.len, 1 + e_acute.len + thumbs.len + family.len + 8, t.len - 1, t.len };
    try testing.expectEqualSlices(usize, &expected, stops.items);
    // And backwards.
    var j: usize = t.len;
    var k = expected.len;
    while (j > 0) {
        j = prevChar(t, j);
        k -= 1;
        try testing.expectEqual(if (k == 0) 0 else expected[k - 1], j);
    }
}

test "caret positions and hit testing (approximate metrics)" {
    // 10px font: each code point 6px wide, lines 12px tall.
    const l: TextLayout = .{ .metrics = .init(null, 10), .text = "abc\nde\n" };
    try testing.expectEqual(Size{ .width = 18, .height = 36 }, l.size());
    try testing.expectEqual(Point{ .x = 12, .y = 0 }, l.caret(2));
    try testing.expectEqual(Point{ .x = 18, .y = 0 }, l.caret(3)); // before the newline
    try testing.expectEqual(Point{ .x = 0, .y = 12 }, l.caret(4));
    try testing.expectEqual(Point{ .x = 0, .y = 24 }, l.caret(7)); // empty last line

    try testing.expectEqual(@as(usize, 1), l.offsetAt(.{ .x = 7, .y = 3 }));
    try testing.expectEqual(@as(usize, 2), l.offsetAt(.{ .x = 10, .y = 3 })); // nearer the right side
    try testing.expectEqual(@as(usize, 3), l.offsetAt(.{ .x = 100, .y = 0 }));
    try testing.expectEqual(@as(usize, 6), l.offsetAt(.{ .x = 100, .y = 13 }));
    try testing.expectEqual(@as(usize, 7), l.offsetAt(.{ .x = 3, .y = 500 }));
    try testing.expectEqual(@as(usize, 0), l.offsetAt(.{ .x = -5, .y = -5 }));
}

test "caret on wrapped lines" {
    // "aaa bbb" wrapped at 30px: "aaa" / "bbb"; the space belongs to line 0.
    const l: TextLayout = .{ .metrics = .init(null, 10), .text = "aaa bbb", .max_width = 30 };
    try testing.expectEqual(@as(usize, 0), l.lineOf(3).index);
    try testing.expectEqual(@as(usize, 1), l.lineOf(4).index);
    try testing.expectEqual(Point{ .x = 6, .y = 12 }, l.caret(5));
    try testing.expectEqual(@as(usize, 6), l.offsetAt(.{ .x = 13, .y = 15 }));
}

test "carets and hit testing on aligned lines" {
    // "ab" 12px and "abcd" 24px, centered in 60px: from 24 and 18.
    var l: TextLayout = .{ .metrics = .init(null, 10), .text = "ab\nabcd", .alignment = .center, .box_width = 60 };
    try testing.expectEqual(Point{ .x = 24, .y = 0 }, l.caret(0));
    try testing.expectEqual(Point{ .x = 36, .y = 0 }, l.caret(2));
    try testing.expectEqual(Point{ .x = 18, .y = 12 }, l.caret(3));
    try testing.expectEqual(@as(usize, 3), l.offsetAt(.{ .x = 19, .y = 13 }));
    try testing.expectEqual(@as(usize, 4), l.offsetAt(.{ .x = 22, .y = 13 }));
    try testing.expectEqual(@as(usize, 0), l.offsetAt(.{ .x = 5, .y = 3 }));
    // Right: lines end at the box's edge; the size is the text's.
    l.alignment = .right;
    try testing.expectEqual(Point{ .x = 60, .y = 0 }, l.caret(2));
    try testing.expectEqual(Point{ .x = 36, .y = 12 }, l.caret(3));
    try testing.expectEqual(Size{ .width = 24, .height = 24 }, l.size());
}

test "undo history merges typing" {
    const gpa = testing.allocator;
    var h: History = .{};
    defer h.deinit(gpa);
    try h.record(gpa, 0, "", "a", 0, 0, .typing);
    try h.record(gpa, 1, "", "b", 1, 1, .typing);
    try testing.expectEqual(@as(usize, 1), h.undo_stack.items.len);
    try testing.expectEqualStrings("ab", h.peekUndo().?.inserted.items);
    // peekUndo sealed the step: more typing starts a new one.
    try h.record(gpa, 2, "", "c", 2, 2, .typing);
    try testing.expectEqual(@as(usize, 2), h.undo_stack.items.len);

    try h.record(gpa, 2, "c", "", 3, 3, .backspace);
    try h.record(gpa, 1, "b", "", 2, 2, .backspace);
    try testing.expectEqual(@as(usize, 3), h.undo_stack.items.len);
    const e = h.peekUndo().?;
    try testing.expectEqualStrings("bc", e.removed.items);
    try testing.expectEqual(@as(usize, 1), e.pos);
    try testing.expectEqual(@as(usize, 3), e.cursor);

    try h.undone(gpa);
    try testing.expect(h.canRedo());
    // A new edit drops the redo steps.
    try h.record(gpa, 0, "", "x", 0, 0, .other);
    try testing.expect(!h.canRedo());
}
