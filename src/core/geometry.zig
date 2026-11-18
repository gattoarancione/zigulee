// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Geometry in logical pixels.

const std = @import("std");

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Point, b: Point) Point {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
};

pub const Size = struct {
    width: f32 = 0,
    height: f32 = 0,
};

/// An axis-aligned rectangle. `contains` is half-open: [x, x + width).
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub const empty: Rect = .{};

    pub fn fromOriginSize(o: Point, s: Size) Rect {
        return .{ .x = o.x, .y = o.y, .width = s.width, .height = s.height };
    }

    pub fn origin(r: Rect) Point {
        return .{ .x = r.x, .y = r.y };
    }

    pub fn size(r: Rect) Size {
        return .{ .width = r.width, .height = r.height };
    }

    pub fn right(r: Rect) f32 {
        return r.x + r.width;
    }

    pub fn bottom(r: Rect) f32 {
        return r.y + r.height;
    }

    pub fn isEmpty(r: Rect) bool {
        return !(r.width > 0 and r.height > 0);
    }

    pub fn area(r: Rect) f32 {
        return if (r.isEmpty()) 0 else r.width * r.height;
    }

    pub fn contains(r: Rect, p: Point) bool {
        return p.x >= r.x and p.y >= r.y and p.x < r.right() and p.y < r.bottom();
    }

    pub fn containsRect(r: Rect, o: Rect) bool {
        if (o.isEmpty()) return true;
        return o.x >= r.x and o.y >= r.y and o.right() <= r.right() and o.bottom() <= r.bottom();
    }

    pub fn intersects(a: Rect, b: Rect) bool {
        return !a.intersection(b).isEmpty();
    }

    /// The overlap of `a` and `b`; empty if they do not overlap.
    pub fn intersection(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (x1 <= x0 or y1 <= y0) return empty;
        return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
    }

    /// The bounding box of `a` and `b`; empty rectangles are ignored.
    pub fn unionWith(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        return .{ .x = x0, .y = y0, .width = @max(a.right(), b.right()) - x0, .height = @max(a.bottom(), b.bottom()) - y0 };
    }

    pub fn translate(r: Rect, by: Point) Rect {
        return .{ .x = r.x + by.x, .y = r.y + by.y, .width = r.width, .height = r.height };
    }

    /// Expands to whole pixels, so partial redraws cover anti-aliased edges.
    pub fn roundOut(r: Rect) Rect {
        const x0 = @floor(r.x);
        const y0 = @floor(r.y);
        return .{ .x = x0, .y = y0, .width = @ceil(r.right()) - x0, .height = @ceil(r.bottom()) - y0 };
    }
};

/// An affine transform: `x' = a x + c y + tx`, `y' = b x + d y + ty`
/// (rotation, scale and translation, as items transform their content).
pub const Affine = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    pub const identity: Affine = .{};

    pub fn translation(by: Point) Affine {
        return .{ .tx = by.x, .ty = by.y };
    }

    pub fn scaling(sx: f32, sy: f32) Affine {
        return .{ .a = sx, .d = sy };
    }

    /// `degrees` clockwise (y points down).
    pub fn rotation(degrees: f32) Affine {
        const r = degrees * std.math.pi / 180;
        const cos = @cos(r);
        const sin = @sin(r);
        return .{ .a = cos, .b = sin, .c = -sin, .d = cos };
    }

    /// `m` applied first, then `self`.
    pub fn mul(self: Affine, m: Affine) Affine {
        return .{
            .a = self.a * m.a + self.c * m.b,
            .b = self.b * m.a + self.d * m.b,
            .c = self.a * m.c + self.c * m.d,
            .d = self.b * m.c + self.d * m.d,
            .tx = self.a * m.tx + self.c * m.ty + self.tx,
            .ty = self.b * m.tx + self.d * m.ty + self.ty,
        };
    }

    pub fn apply(self: Affine, p: Point) Point {
        return .{ .x = self.a * p.x + self.c * p.y + self.tx, .y = self.b * p.x + self.d * p.y + self.ty };
    }

    /// The inverse, if there is one (not for a scale of 0).
    pub fn inverse(self: Affine) ?Affine {
        const det = self.a * self.d - self.b * self.c;
        if (@abs(det) < 1e-12) return null;
        const inv = 1 / det;
        return .{
            .a = self.d * inv,
            .b = -self.b * inv,
            .c = -self.c * inv,
            .d = self.a * inv,
            .tx = (self.c * self.ty - self.d * self.tx) * inv,
            .ty = (self.b * self.tx - self.a * self.ty) * inv,
        };
    }

    /// Only a translation (what most items have: no rotation or scale).
    pub fn isTranslation(self: Affine) bool {
        return self.a == 1 and self.b == 0 and self.c == 0 and self.d == 1;
    }

    pub fn offset(self: Affine) Point {
        return .{ .x = self.tx, .y = self.ty };
    }

    /// The bounding box of `r` transformed.
    pub fn mapRect(self: Affine, r: Rect) Rect {
        if (self.isTranslation()) return r.translate(self.offset());
        const corners = [4]Point{ self.apply(.{ .x = r.x, .y = r.y }), self.apply(.{ .x = r.right(), .y = r.y }), self.apply(.{ .x = r.right(), .y = r.bottom() }), self.apply(.{ .x = r.x, .y = r.bottom() }) };
        var x0 = corners[0].x;
        var y0 = corners[0].y;
        var x1 = x0;
        var y1 = y0;
        for (corners[1..]) |p| {
            x0 = @min(x0, p.x);
            y0 = @min(y0, p.y);
            x1 = @max(x1, p.x);
            y1 = @max(y1, p.y);
        }
        return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
    }

    pub fn eql(a: Affine, b: Affine) bool {
        return std.meta.eql(a, b);
    }
};

test "affine transforms compose, invert and map rectangles" {
    const t = std.testing;
    const m = Affine.translation(.{ .x = 10, .y = 0 }).mul(Affine.rotation(90));
    const p = m.apply(.{ .x = 1, .y = 0 });
    try t.expectApproxEqAbs(@as(f32, 10), p.x, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 1), p.y, 1e-5);
    const back = m.inverse().?.apply(p);
    try t.expectApproxEqAbs(@as(f32, 1), back.x, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 0), back.y, 1e-5);
    const box = Affine.rotation(90).mapRect(.{ .width = 4, .height = 2 });
    try t.expectApproxEqAbs(@as(f32, -2), box.x, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 2), box.width, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 4), box.height, 1e-5);
    try t.expectEqual(@as(?Affine, null), Affine.scaling(0, 1).inverse());
}

/// A projective transform (a homography): `(x', y') = (X / W, Y / W)` with
/// `(X, Y, W) = m (x, y, 1)`. Elements tilted in depth (`rotation-x`,
/// `rotation-y`) map their flat drawing with one. Points that would be
/// behind the viewer (`W` not positive) map to nothing.
pub const Projective = struct {
    /// Row-major.
    m: [3][3]f32 = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } },

    pub const identity: Projective = .{};

    pub fn fromAffine(a: Affine) Projective {
        return .{ .m = .{ .{ a.a, a.c, a.tx }, .{ a.b, a.d, a.ty }, .{ 0, 0, 1 } } };
    }

    /// `n` applied first, then `self`.
    pub fn mul(self: Projective, n: Projective) Projective {
        var out: Projective = undefined;
        for (0..3) |i| for (0..3) |j| {
            out.m[i][j] = self.m[i][0] * n.m[0][j] + self.m[i][1] * n.m[1][j] + self.m[i][2] * n.m[2][j];
        };
        return out;
    }

    /// Where `p` goes; null if behind the viewer.
    pub fn apply(self: Projective, p: Point) ?Point {
        const w = self.m[2][0] * p.x + self.m[2][1] * p.y + self.m[2][2];
        if (!(w > 1e-6)) return null;
        return .{
            .x = (self.m[0][0] * p.x + self.m[0][1] * p.y + self.m[0][2]) / w,
            .y = (self.m[1][0] * p.x + self.m[1][1] * p.y + self.m[1][2]) / w,
        };
    }

    /// The inverse, if there is one; scaled so that it maps the points in
    /// front of the viewer back with a positive `W`.
    pub fn inverse(self: Projective) ?Projective {
        const m = self.m;
        const c00 = m[1][1] * m[2][2] - m[1][2] * m[2][1];
        const c01 = m[1][2] * m[2][0] - m[1][0] * m[2][2];
        const c02 = m[1][0] * m[2][1] - m[1][1] * m[2][0];
        const det = m[0][0] * c00 + m[0][1] * c01 + m[0][2] * c02;
        if (!(@abs(det) > 1e-12)) return null;
        const inv = 1 / det;
        return .{ .m = .{
            .{ c00 * inv, (m[0][2] * m[2][1] - m[0][1] * m[2][2]) * inv, (m[0][1] * m[1][2] - m[0][2] * m[1][1]) * inv },
            .{ c01 * inv, (m[0][0] * m[2][2] - m[0][2] * m[2][0]) * inv, (m[0][2] * m[1][0] - m[0][0] * m[1][2]) * inv },
            .{ c02 * inv, (m[0][1] * m[2][0] - m[0][0] * m[2][1]) * inv, (m[0][0] * m[1][1] - m[0][1] * m[1][0]) * inv },
        } };
    }

    /// The bounding box of `r` mapped; null if part of it would be behind
    /// the viewer.
    pub fn mapRect(self: Projective, r: Rect) ?Rect {
        const corners = [4]Point{ .{ .x = r.x, .y = r.y }, .{ .x = r.right(), .y = r.y }, .{ .x = r.right(), .y = r.bottom() }, .{ .x = r.x, .y = r.bottom() } };
        var lo: Point = .{ .x = std.math.inf(f32), .y = std.math.inf(f32) };
        var hi: Point = .{ .x = -std.math.inf(f32), .y = -std.math.inf(f32) };
        for (corners) |c| {
            const p = self.apply(c) orelse return null;
            lo = .{ .x = @min(lo.x, p.x), .y = @min(lo.y, p.y) };
            hi = .{ .x = @max(hi.x, p.x), .y = @max(hi.y, p.y) };
        }
        return .{ .x = lo.x, .y = lo.y, .width = hi.x - lo.x, .height = hi.y - lo.y };
    }

    /// Conjugated by `a` (`a self a⁻¹`): the same mapping, between the
    /// coordinates `a` maps to.
    pub fn conjugate(self: Projective, a: Affine) Projective {
        const inv = a.inverse() orelse return self;
        return fromAffine(a).mul(self).mul(fromAffine(inv));
    }
};

test "projective transforms compose, invert and map rectangles" {
    const t = std.testing;
    // A square tilted back: its far side shorter.
    const h: Projective = .{ .m = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0.001, 1 } } };
    const near = h.apply(.{ .x = 100, .y = 0 }).?;
    const far = h.apply(.{ .x = 100, .y = 500 }).?;
    try t.expectApproxEqAbs(@as(f32, 100), near.x, 1e-4);
    try t.expectApproxEqAbs(@as(f32, 100.0 / 1.5), far.x, 1e-3);
    const back = h.inverse().?.apply(far).?;
    try t.expectApproxEqAbs(@as(f32, 100), back.x, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 500), back.y, 1e-2);
    // Behind the viewer: nothing.
    try t.expectEqual(@as(?Point, null), h.apply(.{ .x = 0, .y = -2000 }));
    try t.expectEqual(@as(?Rect, null), h.mapRect(.{ .y = -2000, .width = 10, .height = 10 }));
    // An affine one, as such.
    const a = Affine.translation(.{ .x = 3, .y = 4 }).mul(Affine.rotation(90));
    const pa = Projective.fromAffine(a).apply(.{ .x = 1, .y = 0 }).?;
    try t.expectApproxEqAbs(@as(f32, 3), pa.x, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 5), pa.y, 1e-5);
    const conj = Projective.fromAffine(Affine.scaling(2, 1)).conjugate(Affine.scaling(3, 3));
    try t.expectApproxEqAbs(@as(f32, 2), conj.m[0][0], 1e-5);
}

/// A small set of rectangles describing what needs repainting. Overlapping
/// rectangles are merged; when full, the closest pair is merged, so the
/// region may grow slightly but never misses an area.
pub const Region = struct {
    pub const capacity = 4;

    rects: [capacity]Rect = undefined,
    len: usize = 0,

    pub fn slice(self: *const Region) []const Rect {
        return self.rects[0..self.len];
    }

    pub fn isEmpty(self: *const Region) bool {
        return self.len == 0;
    }

    pub fn clear(self: *Region) void {
        self.len = 0;
    }

    pub fn boundingBox(self: *const Region) Rect {
        var b: Rect = .empty;
        for (self.slice()) |r| b = b.unionWith(r);
        return b;
    }

    pub fn intersects(self: *const Region, r: Rect) bool {
        for (self.slice()) |s| if (s.intersects(r)) return true;
        return false;
    }

    pub fn addRegion(self: *Region, other: *const Region) void {
        for (other.slice()) |r| self.add(r);
    }

    pub fn add(self: *Region, rect: Rect) void {
        if (rect.isEmpty()) return;
        var r = rect;
        // Absorb every rectangle that overlaps, repeating as `r` grows.
        var i: usize = 0;
        while (i < self.len) {
            if (self.rects[i].containsRect(r)) return;
            if (self.rects[i].intersects(r) or r.containsRect(self.rects[i])) {
                r = r.unionWith(self.rects[i]);
                self.removeAt(i);
                i = 0;
                continue;
            }
            i += 1;
        }
        if (self.len < capacity) {
            self.rects[self.len] = r;
            self.len += 1;
            return;
        }
        // Full: merge `r` into the rectangle whose bounding box grows least.
        var best: usize = 0;
        var best_growth = std.math.inf(f32);
        for (self.slice(), 0..) |s, j| {
            const growth = s.unionWith(r).area() - s.area();
            if (growth < best_growth) {
                best_growth = growth;
                best = j;
            }
        }
        const merged = self.rects[best].unionWith(r);
        self.removeAt(best);
        self.add(merged);
    }

    fn removeAt(self: *Region, i: usize) void {
        self.rects[i] = self.rects[self.len - 1];
        self.len -= 1;
    }
};

const testing = std.testing;

test "rect intersection, union and containment" {
    const a: Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const b: Rect = .{ .x = 5, .y = 5, .width = 10, .height = 10 };
    try testing.expectEqual(Rect{ .x = 5, .y = 5, .width = 5, .height = 5 }, a.intersection(b));
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 15, .height = 15 }, a.unionWith(b));
    try testing.expect(a.intersection(.{ .x = 10, .y = 0, .width = 5, .height = 5 }).isEmpty());
    try testing.expect(a.contains(.{ .x = 0, .y = 9.9 }));
    try testing.expect(!a.contains(.{ .x = 10, .y = 5 }));
    try testing.expectEqual(a, a.unionWith(.empty));
    try testing.expectEqual(Rect{ .x = 1, .y = 2, .width = 3, .height = 2 }, (Rect{ .x = 1.5, .y = 2.2, .width = 2.2, .height = 1.1 }).roundOut());
}

test "region merges overlapping rects and stays bounded" {
    var region: Region = .{};
    region.add(.{ .x = 0, .y = 0, .width = 10, .height = 10 });
    region.add(.{ .x = 2, .y = 2, .width = 3, .height = 3 }); // contained
    try testing.expectEqual(@as(usize, 1), region.len);
    region.add(.{ .x = 100, .y = 0, .width = 10, .height = 10 });
    try testing.expectEqual(@as(usize, 2), region.len);
    region.add(.{ .x = 5, .y = 5, .width = 100, .height = 1 }); // bridges both
    try testing.expectEqual(@as(usize, 1), region.len);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 110, .height = 10 }, region.boundingBox());

    region.clear();
    for (0..10) |i| region.add(.{ .x = @floatFromInt(i * 20), .y = 0, .width = 5, .height = 5 });
    try testing.expect(region.len <= Region.capacity);
    for (0..10) |i| try testing.expect(region.intersects(.{ .x = @floatFromInt(i * 20 + 1), .y = 1, .width = 1, .height = 1 }));
}
