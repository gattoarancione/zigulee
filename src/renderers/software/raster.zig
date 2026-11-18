// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Anti-aliased coverage masks for paths: an exact-area polygon filler
//! (signed-area accumulation, as in font-rs) and a distance-based stroker.
//! The same filler will rasterize glyph outlines.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Point = @import("../../core/geometry.zig").Point;

/// A coverage mask over `width` x `height` pixels. Fill values are
/// accumulated per row: each row has two spare cells so that edges at the
/// right boundary stay within the row.
pub const Mask = struct {
    cells: std.ArrayList(f32) = .empty,
    width: u32 = 0,
    height: u32 = 0,

    pub fn stride(m: *const Mask) usize {
        return @as(usize, m.width) + 2;
    }

    pub fn deinit(m: *Mask, gpa: Allocator) void {
        m.cells.deinit(gpa);
    }

    pub fn reset(m: *Mask, gpa: Allocator, width: u32, height: u32) Allocator.Error!void {
        m.width = width;
        m.height = height;
        try m.cells.resize(gpa, (@as(usize, width) + 2) * height);
        @memset(m.cells.items, 0);
    }

    /// Adds a polygon edge for filling. Coordinates are relative to the
    /// mask; parts outside it are handled (edges left of the mask still
    /// contribute winding). Call `accumulate` after all edges.
    pub fn addEdge(m: *Mask, a: Point, b: Point) void {
        const w: f32 = @floatFromInt(m.width);
        // Split at the left and right boundaries; outside parts become
        // vertical edges on the boundary, which keep the winding right.
        var pts: [4]Point = undefined;
        var n: usize = 0;
        pts[n] = a;
        n += 1;
        const lo = @min(a.x, b.x);
        const hi = @max(a.x, b.x);
        var cuts: [2]f32 = undefined;
        var ncuts: usize = 0;
        if (lo < 0 and hi > 0) {
            cuts[ncuts] = (0 - a.x) / (b.x - a.x);
            ncuts += 1;
        }
        if (lo < w and hi > w) {
            cuts[ncuts] = (w - a.x) / (b.x - a.x);
            ncuts += 1;
        }
        if (ncuts == 2 and cuts[0] > cuts[1]) std.mem.swap(f32, &cuts[0], &cuts[1]);
        for (cuts[0..ncuts]) |t| {
            pts[n] = .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
            n += 1;
        }
        pts[n] = b;
        n += 1;
        for (0..n - 1) |i| {
            const p0 = pts[i];
            const p1 = pts[i + 1];
            m.addClampedEdge(
                .{ .x = std.math.clamp(p0.x, 0, w), .y = p0.y },
                .{ .x = std.math.clamp(p1.x, 0, w), .y = p1.y },
            );
        }
    }

    fn addClampedEdge(m: *Mask, p0_in: Point, p1_in: Point) void {
        if (p0_in.y == p1_in.y) return;
        const dir: f32 = if (p0_in.y < p1_in.y) 1 else -1;
        const p0 = if (dir > 0) p0_in else p1_in;
        const p1 = if (dir > 0) p1_in else p0_in;
        const h: f32 = @floatFromInt(m.height);
        if (p1.y <= 0 or p0.y >= h) return;

        const w: f32 = @floatFromInt(m.width);
        const dxdy = (p1.x - p0.x) / (p1.y - p0.y);
        var x = p0.x;
        if (p0.y < 0) x -= p0.y * dxdy;
        const row_begin: usize = @intFromFloat(@max(0, p0.y));
        const row_end: usize = @intFromFloat(@min(h, @ceil(p1.y)));
        const stride_ = m.stride();
        const cells = m.cells.items;

        for (row_begin..row_end) |row| {
            const line = row * stride_;
            const yf: f32 = @floatFromInt(row);
            const dy = @min(yf + 1, p1.y) - @max(yf, p0.y);
            const xnext = x + dxdy * dy;
            const d = dy * dir;
            // The endpoints are within [0, w]; clamp away rounding error so
            // cell indices stay in the row.
            const x0 = std.math.clamp(@min(x, xnext), 0, w);
            const x1 = std.math.clamp(@max(x, xnext), 0, w);
            const x0floor = @floor(x0);
            const x0i: usize = @intFromFloat(x0floor);
            const x1ceil = @ceil(x1);
            const x1i: usize = @intFromFloat(x1ceil);
            if (x1i <= x0i + 1) {
                // Within one cell: split by the average x position.
                const xmf = 0.5 * (x + xnext) - x0floor;
                cells[line + x0i] += d - d * xmf;
                cells[line + x0i + 1] += d * xmf;
            } else {
                // Across several cells: trapezoid areas.
                const s = 1 / (x1 - x0);
                const x0f = x0 - x0floor;
                const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
                const x1f = x1 - x1ceil + 1;
                const am = 0.5 * s * x1f * x1f;
                cells[line + x0i] += d * a0;
                if (x1i == x0i + 2) {
                    cells[line + x0i + 1] += d * (1 - a0 - am);
                } else {
                    const a1 = s * (1.5 - x0f);
                    cells[line + x0i + 1] += d * (a1 - a0);
                    for (x0i + 2..x1i - 1) |xi| cells[line + xi] += d * s;
                    const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                    cells[line + x1i - 1] += d * (1 - a2 - am);
                }
                cells[line + x1i] += d * am;
            }
            x = xnext;
        }
    }

    /// Turns accumulated edges into coverage in [0, 1] (non-zero winding).
    pub fn accumulate(m: *Mask) void {
        const stride_ = m.stride();
        for (0..m.height) |row| {
            var acc: f32 = 0;
            const line = m.cells.items[row * stride_ ..][0..m.width];
            for (line) |*c| {
                acc += c.*;
                c.* = @min(1, @abs(acc));
            }
        }
    }

    /// Clears to zero coverage, for `addStrokeSegment`.
    pub fn clear(m: *Mask) void {
        @memset(m.cells.items, 0);
    }

    /// Adds the coverage of a round-capped line of width `2 * half_width`
    /// from `a` to `b` (overlaps take the maximum). Joins come out round.
    pub fn addStrokeSegment(m: *Mask, a: Point, b: Point, half_width: f32) void {
        const reach = half_width + 1;
        const fx0 = @max(0, @floor(@min(a.x, b.x) - reach));
        const fy0 = @max(0, @floor(@min(a.y, b.y) - reach));
        const fx1 = @min(@as(f32, @floatFromInt(m.width)), @ceil(@max(a.x, b.x) + reach));
        const fy1 = @min(@as(f32, @floatFromInt(m.height)), @ceil(@max(a.y, b.y) + reach));
        if (fx1 <= fx0 or fy1 <= fy0) return;
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const len2 = dx * dx + dy * dy;
        const stride_ = m.stride();
        var y: usize = @intFromFloat(fy0);
        while (y < @as(usize, @intFromFloat(fy1))) : (y += 1) {
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            var x: usize = @intFromFloat(fx0);
            while (x < @as(usize, @intFromFloat(fx1))) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const t = if (len2 == 0) 0 else std.math.clamp(((px - a.x) * dx + (py - a.y) * dy) / len2, 0, 1);
                const ex = px - (a.x + dx * t);
                const ey = py - (a.y + dy * t);
                const cov = std.math.clamp(half_width + 0.5 - @sqrt(ex * ex + ey * ey), 0, 1);
                const cell = &m.cells.items[y * stride_ + x];
                cell.* = @max(cell.*, cov);
            }
        }
    }

    pub fn coverage(m: *const Mask, x: u32, y: u32) f32 {
        return m.cells.items[@as(usize, y) * m.stride() + x];
    }
};

const testing = std.testing;

fn fillPolygon(m: *Mask, pts: []const Point) void {
    for (pts, 0..) |p, i| m.addEdge(p, pts[(i + 1) % pts.len]);
    m.accumulate();
}

fn total(m: *const Mask) f32 {
    var sum: f32 = 0;
    for (0..m.height) |y| for (0..m.width) |x| {
        sum += m.coverage(@intCast(x), @intCast(y));
    };
    return sum;
}

test "filled area matches polygon area" {
    var m: Mask = .{};
    defer m.deinit(testing.allocator);
    try m.reset(testing.allocator, 10, 10);
    // A triangle with area 0.5 * 8 * 6 = 24, at fractional positions.
    fillPolygon(&m, &.{ .{ .x = 1.3, .y = 1.7 }, .{ .x = 9.3, .y = 1.7 }, .{ .x = 1.3, .y = 7.7 } });
    try testing.expectApproxEqAbs(@as(f32, 24), total(&m), 1e-3);

    // Pixel-aligned square: crisp edges.
    try m.reset(testing.allocator, 10, 10);
    fillPolygon(&m, &.{ .{ .x = 2, .y = 2 }, .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 4 }, .{ .x = 2, .y = 4 } });
    try testing.expectEqual(@as(f32, 1), m.coverage(2, 2));
    try testing.expectEqual(@as(f32, 0), m.coverage(5, 2));
    try testing.expectEqual(@as(f32, 0), m.coverage(1, 3));
    try testing.expectApproxEqAbs(@as(f32, 6), total(&m), 1e-4);
}

test "winding is preserved for shapes extending outside the mask" {
    var m: Mask = .{};
    defer m.deinit(testing.allocator);
    try m.reset(testing.allocator, 4, 4);
    // A big square covering the whole mask (and more on every side).
    fillPolygon(&m, &.{ .{ .x = -10, .y = -10 }, .{ .x = 20, .y = -10 }, .{ .x = 20, .y = 20 }, .{ .x = -10, .y = 20 } });
    try testing.expectApproxEqAbs(@as(f32, 16), total(&m), 1e-4);
    // A diagonal edge crossing the left boundary: the visible part lies
    // under y = (x + 4) / 2 for x in [0, 4], an area of 12.
    try m.reset(testing.allocator, 4, 4);
    fillPolygon(&m, &.{ .{ .x = -4, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 4 } });
    try testing.expectApproxEqAbs(@as(f32, 12), total(&m), 1e-3);
}

test "edges along the mask boundary stay in bounds" {
    var m: Mask = .{};
    defer m.deinit(testing.allocator);
    try m.reset(testing.allocator, 7, 9);
    // Nearly vertical edges hugging x = 0 and x = width, with rounding-prone
    // slopes: interpolation must never index outside the row.
    var prng: std.Random.DefaultPrng = .init(1);
    const r = prng.random();
    for (0..10_000) |_| {
        const a: Point = .{ .x = r.float(f32) * 1e-3, .y = r.float(f32) * 9 };
        const b: Point = .{ .x = 7 - r.float(f32) * 1e-3, .y = r.float(f32) * 9 };
        m.addEdge(a, .{ .x = 0, .y = b.y });
        m.addEdge(b, .{ .x = 7, .y = a.y });
        m.addEdge(.{ .x = -r.float(f32) * 50, .y = a.y }, .{ .x = 7 + r.float(f32) * 50, .y = b.y });
    }
    m.accumulate();
}

test "stroke coverage" {
    var m: Mask = .{};
    defer m.deinit(testing.allocator);
    try m.reset(testing.allocator, 20, 10);
    m.clear();
    // A horizontal 2px line through pixel centers from x=5 to x=15.
    m.addStrokeSegment(.{ .x = 5, .y = 5 }, .{ .x = 15, .y = 5 }, 1);
    try testing.expectEqual(@as(f32, 1), m.coverage(10, 4));
    try testing.expectEqual(@as(f32, 1), m.coverage(10, 5));
    try testing.expectEqual(@as(f32, 0), m.coverage(10, 6));
    try testing.expectEqual(@as(f32, 0), m.coverage(10, 3));
    // Round cap reaches 1px beyond the end.
    try testing.expect(m.coverage(15, 5) > 0.5);
    try testing.expectEqual(@as(f32, 0), m.coverage(18, 5));
}
