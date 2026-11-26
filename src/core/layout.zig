// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Layout solvers. These are pure functions over slices: the item layer
//! (`items.zig`) wraps them in bindings, and the compiler will call them
//! directly from generated code. Each orientation is solved independently.

const std = @import("std");

pub const Orientation = enum { horizontal, vertical };

const inf = std.math.inf(f32);

/// Size constraints of an element along one orientation.
pub const LayoutInfo = struct {
    min: f32 = 0,
    max: f32 = inf,
    preferred: f32 = 0,
    /// Relative share of extra space. If every item in a layout has 0, they
    /// all grow equally.
    stretch: f32 = 1,

    /// Combines the constraints of an element with those of a layout nested
    /// inside it: the result satisfies both.
    pub fn merge(a: LayoutInfo, b: LayoutInfo) LayoutInfo {
        const min = @max(a.min, b.min);
        return .{
            .min = min,
            .max = @max(min, @min(a.max, b.max)),
            .preferred = @max(a.preferred, b.preferred),
            .stretch = @min(a.stretch, b.stretch),
        };
    }

    /// Preferred size, clamped to [min, max].
    pub fn preferredBounded(self: LayoutInfo) f32 {
        return std.math.clamp(self.preferred, self.min, @max(self.min, self.max));
    }

    /// Fixes inconsistent constraints: max >= min.
    pub fn normalized(self: LayoutInfo) LayoutInfo {
        var r = self;
        r.max = @max(r.min, r.max);
        return r;
    }
};

pub const Alignment = enum { stretch, start, end, center, space_between, space_around };

pub const Padding = struct {
    begin: f32 = 0,
    end: f32 = 0,

    fn total(p: Padding) f32 {
        return p.begin + p.end;
    }
};

/// A position and size along one axis.
pub const Segment = struct {
    pos: f32 = 0,
    size: f32 = 0,
};

pub const BoxLayoutData = struct {
    size: f32,
    spacing: f32 = 0,
    padding: Padding = .{},
    alignment: Alignment = .stretch,
};

fn spacingTotal(n: usize, spacing: f32) f32 {
    return if (n > 1) spacing * @as(f32, @floatFromInt(n - 1)) else 0;
}

/// Constraints of a box layout along its own axis: the children's
/// constraints summed, plus spacing and padding.
pub fn boxLayoutInfo(items: []const LayoutInfo, spacing: f32, padding: Padding) LayoutInfo {
    const extra = padding.total() + spacingTotal(items.len, spacing);
    if (items.len == 0) return .{ .min = extra, .preferred = extra };
    var r: LayoutInfo = .{ .min = extra, .max = extra, .preferred = extra, .stretch = 0 };
    for (items) |raw| {
        const it = raw.normalized();
        r.min += it.min;
        r.max += it.max;
        r.preferred += it.preferredBounded();
        r.stretch += it.stretch;
    }
    return r;
}

/// Constraints of a box layout across its axis: wide enough for the widest
/// child's minimum, no wider than the narrowest child's maximum.
pub fn boxLayoutInfoOrtho(items: []const LayoutInfo, padding: Padding) LayoutInfo {
    const extra = padding.total();
    if (items.len == 0) return .{ .min = extra, .preferred = extra };
    var r: LayoutInfo = .{ .min = 0, .max = inf, .preferred = 0, .stretch = inf };
    for (items) |raw| {
        const it = raw.normalized();
        r.min = @max(r.min, it.min);
        r.max = @min(r.max, it.max);
        r.preferred = @max(r.preferred, it.preferredBounded());
        r.stretch = @min(r.stretch, it.stretch);
    }
    r.max = @max(r.min, r.max);
    r.preferred = std.math.clamp(r.preferred, r.min, r.max);
    r.min += extra;
    r.max += extra;
    r.preferred += extra;
    return r;
}

/// Positions `items` along one axis. `out` must have the same length.
pub fn solveBox(data: BoxLayoutData, items: []const LayoutInfo, out: []Segment) void {
    std.debug.assert(out.len == items.len);
    const n = items.len;
    if (n == 0) return;
    const available = @max(0, data.size - data.padding.total() - spacingTotal(n, data.spacing));

    for (items, out) |it, *o| o.size = it.preferredBounded();
    distribute(items, out, available, data.alignment == .stretch);

    var total: f32 = 0;
    for (out) |o| total += o.size;
    const leftover = @max(0, available - total);
    const count: f32 = @floatFromInt(n);

    var pos = data.padding.begin;
    var gap = data.spacing;
    switch (data.alignment) {
        .stretch, .start => {},
        .end => pos += leftover,
        .center => pos += leftover / 2,
        .space_between => if (n > 1) {
            gap += leftover / (count - 1);
        } else {
            pos += leftover / 2;
        },
        .space_around => {
            pos += leftover / count / 2;
            gap += leftover / count;
        },
    }
    for (out) |*o| {
        o.pos = pos;
        pos += o.size + gap;
    }
}

/// Adjusts `out[i].size` so the sizes add up to `available` where the
/// constraints allow: shrinking (towards each min, proportionally to the
/// slack) when too large, and, if `grow`, growing by stretch factor
/// (respecting each max) when too small.
fn distribute(items: []const LayoutInfo, out: []Segment, available: f32, grow: bool) void {
    var total: f32 = 0;
    for (out) |o| total += o.size;

    if (total > available) {
        var slack: f32 = 0;
        for (items, out) |it, o| slack += o.size - it.min;
        if (slack <= 0) return;
        const ratio = @min(1, (total - available) / slack);
        for (items, out) |it, *o| o.size -= (o.size - it.min) * ratio;
        return;
    }
    if (!grow) return;

    var all_zero = true;
    for (items) |it| if (it.stretch > 0) {
        all_zero = false;
    };

    var remaining = available - total;
    // Each pass either places all remaining space or saturates at least one
    // item at its max, so `items.len + 1` passes always suffice.
    for (0..items.len + 1) |_| {
        if (remaining <= 1e-4) break;
        var weights: f32 = 0;
        for (items, out) |it, o| {
            if (o.size < it.max) weights += if (all_zero) 1 else it.stretch;
        }
        if (weights <= 0) break;
        var used: f32 = 0;
        for (items, out) |it, *o| {
            if (o.size >= it.max) continue;
            const w = if (all_zero) 1 else it.stretch;
            const grown = @min(o.size + remaining * w / weights, @max(it.min, it.max));
            used += grown - o.size;
            o.size = grown;
        }
        remaining -= used;
    }
}

/// Places an item with constraints `info` inside the space `seg`: it takes
/// the whole space if allowed, otherwise its max size, centered.
pub fn fitInSegment(seg: Segment, info: LayoutInfo) Segment {
    const size = std.math.clamp(seg.size, info.min, @max(info.min, info.max));
    if (size >= seg.size) return .{ .pos = seg.pos, .size = size };
    return .{ .pos = seg.pos + (seg.size - size) / 2, .size = size };
}

/// A grid cell along one orientation: column (or row) index and span.
pub const GridCell = struct {
    index: u16,
    span: u16 = 1,
    info: LayoutInfo,
};

pub const GridLayoutData = struct {
    size: f32,
    spacing: f32 = 0,
    padding: Padding = .{},
};

/// Number of columns (or rows) the cells occupy.
pub fn gridTrackCount(cells: []const GridCell) usize {
    var n: usize = 0;
    for (cells) |c| n = @max(n, @as(usize, c.index) + @max(c.span, 1));
    return n;
}

/// Computes the constraints of each column (or row) into `tracks`, which
/// must hold `gridTrackCount(cells)` entries.
fn computeTracks(cells: []const GridCell, spacing: f32, tracks: []LayoutInfo) void {
    std.debug.assert(tracks.len >= gridTrackCount(cells));
    @memset(tracks, .{ .min = 0, .max = 0, .preferred = 0, .stretch = 0 });
    var has_cell_buf: [256]bool = @splat(false);
    const has_cell = has_cell_buf[0..@min(tracks.len, has_cell_buf.len)];

    for (cells) |c| {
        if (c.span > 1) continue;
        const t = &tracks[c.index];
        const info = c.info.normalized();
        t.min = @max(t.min, info.min);
        t.max = @max(t.max, info.max);
        t.preferred = @max(t.preferred, info.preferredBounded());
        t.stretch = @max(t.stretch, info.stretch);
        if (c.index < has_cell.len) has_cell[c.index] = true;
    }
    for (tracks, 0..) |*t, i| {
        if (i < has_cell.len and !has_cell[i]) t.max = inf;
        t.max = @max(t.min, t.max);
    }

    // Spanning cells: spread any missing min/preferred size evenly.
    for (cells) |c| {
        if (c.span <= 1) continue;
        const span_tracks = tracks[c.index..][0..c.span];
        const info = c.info.normalized();
        const gaps = spacing * @as(f32, @floatFromInt(c.span - 1));
        const span_count: f32 = @floatFromInt(c.span);

        var min_sum = gaps;
        for (span_tracks) |t| min_sum += t.min;
        if (info.min > min_sum) for (span_tracks) |*t| {
            t.min += (info.min - min_sum) / span_count;
            t.max = @max(t.max, t.min);
        };

        var pref_sum = gaps;
        for (span_tracks) |t| pref_sum += t.preferred;
        if (info.preferred > pref_sum) for (span_tracks) |*t| {
            t.preferred += (info.preferred - pref_sum) / span_count;
            t.max = @max(t.max, t.preferred);
        };
        for (span_tracks) |*t| t.stretch = @max(t.stretch, info.stretch);
    }
}

/// Constraints of a grid layout along one orientation. `tracks` is scratch
/// space of `gridTrackCount(cells)` entries.
pub fn gridLayoutInfo(cells: []const GridCell, spacing: f32, padding: Padding, tracks: []LayoutInfo) LayoutInfo {
    computeTracks(cells, spacing, tracks);
    return boxLayoutInfo(tracks, spacing, padding);
}

/// Positions grid cells along one orientation. `tracks` and `track_out`
/// are scratch space of `gridTrackCount(cells)` entries; `out` has one
/// segment per cell.
pub fn solveGrid(data: GridLayoutData, cells: []const GridCell, tracks: []LayoutInfo, track_out: []Segment, out: []Segment) void {
    std.debug.assert(out.len == cells.len);
    const n = gridTrackCount(cells);
    computeTracks(cells, data.spacing, tracks[0..n]);
    solveBox(.{ .size = data.size, .spacing = data.spacing, .padding = data.padding }, tracks[0..n], track_out[0..n]);
    for (cells, out) |c, *o| {
        const first = track_out[c.index];
        const last = track_out[c.index + @max(c.span, 1) - 1];
        o.* = .{ .pos = first.pos, .size = last.pos + last.size - first.pos };
    }
}

const testing = std.testing;

fn expectSegments(expected: []const [2]f32, actual: []const Segment) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectApproxEqAbs(e[0], a.pos, 1e-3);
        try testing.expectApproxEqAbs(e[1], a.size, 1e-3);
    }
}

test "box: equal stretch with padding and spacing" {
    var out: [3]Segment = undefined;
    solveBox(.{ .size = 320, .spacing = 5, .padding = .{ .begin = 5, .end = 5 } }, &.{ .{}, .{}, .{} }, &out);
    try expectSegments(&.{ .{ 5, 100 }, .{ 110, 100 }, .{ 215, 100 } }, &out);
}

test "box: stretch factors and max constraints" {
    var out: [3]Segment = undefined;
    solveBox(.{ .size = 300 }, &.{ .{ .stretch = 1 }, .{ .stretch = 2 }, .{ .stretch = 0 } }, &out);
    try expectSegments(&.{ .{ 0, 100 }, .{ 100, 200 }, .{ 300, 0 } }, &out);

    // The capped item stops at 50; the rest goes to the other one.
    solveBox(.{ .size = 300 }, &.{ .{ .max = 50 }, .{}, .{ .min = 20, .max = 20 } }, &out);
    try expectSegments(&.{ .{ 0, 50 }, .{ 50, 230 }, .{ 280, 20 } }, &out);
}

test "box: all-zero stretch grows everything equally" {
    var out: [2]Segment = undefined;
    solveBox(.{ .size = 100 }, &.{ .{ .stretch = 0, .preferred = 10 }, .{ .stretch = 0, .preferred = 30 } }, &out);
    try expectSegments(&.{ .{ 0, 40 }, .{ 40, 60 } }, &out);
}

test "box: overflow shrinks towards minimums proportionally to slack" {
    var out: [2]Segment = undefined;
    solveBox(.{ .size = 150 }, &.{ .{ .preferred = 100 }, .{ .preferred = 100, .min = 50 } }, &out);
    // slack 100 + 50, need to lose 50: item 0 loses 33.3, item 1 loses 16.7
    try expectSegments(&.{ .{ 0, 66.667 }, .{ 66.667, 83.333 } }, &out);

    solveBox(.{ .size = 10 }, &.{ .{ .preferred = 100, .min = 40 }, .{ .preferred = 100, .min = 40 } }, &out);
    try expectSegments(&.{ .{ 0, 40 }, .{ 40, 40 } }, &out); // cannot go below min
}

test "box: non-stretch alignments" {
    const fixed: LayoutInfo = .{ .min = 20, .max = 20, .preferred = 20 };
    var out: [2]Segment = undefined;
    solveBox(.{ .size = 100, .alignment = .start }, &.{ fixed, fixed }, &out);
    try expectSegments(&.{ .{ 0, 20 }, .{ 20, 20 } }, &out);
    solveBox(.{ .size = 100, .alignment = .end }, &.{ fixed, fixed }, &out);
    try expectSegments(&.{ .{ 60, 20 }, .{ 80, 20 } }, &out);
    solveBox(.{ .size = 100, .alignment = .center }, &.{ fixed, fixed }, &out);
    try expectSegments(&.{ .{ 30, 20 }, .{ 50, 20 } }, &out);
    solveBox(.{ .size = 100, .alignment = .space_between }, &.{ fixed, fixed }, &out);
    try expectSegments(&.{ .{ 0, 20 }, .{ 80, 20 } }, &out);
    solveBox(.{ .size = 100, .alignment = .space_around }, &.{ fixed, fixed }, &out);
    try expectSegments(&.{ .{ 15, 20 }, .{ 65, 20 } }, &out);
    // Preferred sizes are used, not stretched.
    solveBox(.{ .size = 100, .alignment = .start }, &.{ .{ .preferred = 30 }, .{ .preferred = 10 } }, &out);
    try expectSegments(&.{ .{ 0, 30 }, .{ 30, 10 } }, &out);
}

test "box layout info along and across the axis" {
    const items = [_]LayoutInfo{ .{ .min = 10, .max = 100, .preferred = 50 }, .{ .min = 20, .max = 30, .preferred = 25, .stretch = 2 } };
    try testing.expectEqual(LayoutInfo{ .min = 40, .max = 140, .preferred = 85, .stretch = 3 }, boxLayoutInfo(&items, 5, .{ .begin = 2, .end = 3 }));
    try testing.expectEqual(LayoutInfo{ .min = 25, .max = 35, .preferred = 35, .stretch = 1 }, boxLayoutInfoOrtho(&items, .{ .begin = 2, .end = 3 }));
    try testing.expectEqual(LayoutInfo{ .min = 4, .preferred = 4 }, boxLayoutInfo(&.{}, 10, .{ .begin = 4 }));
}

test "fitInSegment centers items that cannot fill" {
    try testing.expectEqual(Segment{ .pos = 40, .size = 20 }, fitInSegment(.{ .pos = 0, .size = 100 }, .{ .max = 20 }));
    try testing.expectEqual(Segment{ .pos = 0, .size = 100 }, fitInSegment(.{ .pos = 0, .size = 100 }, .{}));
    try testing.expectEqual(Segment{ .pos = 0, .size = 150 }, fitInSegment(.{ .pos = 0, .size = 100 }, .{ .min = 150 }));
}

test "grid: columns, spans and minimums" {
    // | a (min 50) | b       |
    // | c spanning 2, min 200 |
    const cells = [_]GridCell{
        .{ .index = 0, .info = .{ .min = 50 } },
        .{ .index = 1, .info = .{} },
        .{ .index = 0, .span = 2, .info = .{ .min = 200 } },
    };
    var tracks: [2]LayoutInfo = undefined;
    var track_out: [2]Segment = undefined;
    var out: [3]Segment = undefined;

    // The spanning cell needs 200 - 50 - 10 = 140 more: 70 per column, so
    // the column minimums become 120 and 70.
    const info = gridLayoutInfo(&cells, 10, .{}, &tracks);
    try testing.expectEqual(@as(f32, 200), info.min);
    // Extra space grows both columns equally from their minimums.
    solveGrid(.{ .size = 410, .spacing = 10 }, &cells, &tracks, &track_out, &out);
    try expectSegments(&.{ .{ 0, 225 }, .{ 235, 175 }, .{ 0, 410 } }, &out);

    solveGrid(.{ .size = 200, .spacing = 10 }, &cells, &tracks, &track_out, &out);
    try expectSegments(&.{ .{ 0, 120 }, .{ 130, 70 }, .{ 0, 200 } }, &out);
}

/// Of snap positions `best` and `p`: the nearer to `at` (`dir` 0), or the
/// first past it in `dir` (1: further along, -1: back; null: none yet).
pub fn nearerSnap(best: ?f32, p: f32, at: f32, dir: i2) ?f32 {
    switch (dir) {
        0 => if (best) |b| if (@abs(b - at) <= @abs(p - at)) return b,
        1 => if (p <= at + 0.5) return best else if (best) |b| if (b <= p) return b,
        else => if (p >= at - 0.5) return best else if (best) |b| if (b >= p) return b,
    }
    return p;
}

test "the snap position nearest, or the next one either way" {
    var best: ?f32 = null;
    for ([_]f32{ 0, 30, 60, 90 }) |p| best = nearerSnap(best, p, 40, 0);
    try std.testing.expectEqual(@as(?f32, 30), best);
    best = null;
    for ([_]f32{ 90, 0, 60, 30 }) |p| best = nearerSnap(best, p, 30, 1);
    try std.testing.expectEqual(@as(?f32, 60), best);
    best = null;
    for ([_]f32{ 0, 60, 30, 90 }) |p| best = nearerSnap(best, p, 30, -1);
    try std.testing.expectEqual(@as(?f32, 0), best);
    try std.testing.expectEqual(@as(?f32, null), nearerSnap(null, 30, 30, 1));
}
