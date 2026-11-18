// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Vector paths: SVG path-data parsing and flattening into polylines.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Rect = geometry.Rect;

/// A path command in absolute coordinates. Arcs and the shorthand forms
/// are converted to these when parsing.
pub const Command = union(enum) {
    move_to: Point,
    line_to: Point,
    quad_to: struct { c: Point, p: Point },
    cubic_to: struct { c1: Point, c2: Point, p: Point },
    close,
};

pub const ParseError = error{InvalidPath} || Allocator.Error;

/// Parses SVG path data (`M`, `L`, `H`, `V`, `C`, `S`, `Q`, `T`, `A`, `Z`,
/// absolute and relative) into `out`.
pub fn parse(gpa: Allocator, text: []const u8, out: *std.ArrayList(Command)) ParseError!void {
    var p: Parser = .{ .text = text };
    var current: Point = .{};
    var start: Point = .{};
    // Previous control point, for the S and T shorthands.
    var last_cubic_ctrl: ?Point = null;
    var last_quad_ctrl: ?Point = null;
    var cmd: u8 = 0;

    while (true) {
        p.skipSeparators();
        if (p.done()) break;
        if (std.ascii.isAlphabetic(p.peek())) {
            cmd = p.next();
        } else if (cmd == 0 or cmd == 'Z' or cmd == 'z') {
            return error.InvalidPath;
        }
        const rel = std.ascii.isLower(cmd);
        const base: Point = if (rel) current else .{};
        var cubic_ctrl: ?Point = null;
        var quad_ctrl: ?Point = null;

        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                current = base.add(try p.point());
                start = current;
                try out.append(gpa, .{ .move_to = current });
                // Further coordinate pairs are implicit line-tos.
                cmd = if (rel) 'l' else 'L';
            },
            'L' => {
                current = base.add(try p.point());
                try out.append(gpa, .{ .line_to = current });
            },
            'H' => {
                const x = try p.number();
                current.x = if (rel) current.x + x else x;
                try out.append(gpa, .{ .line_to = current });
            },
            'V' => {
                const y = try p.number();
                current.y = if (rel) current.y + y else y;
                try out.append(gpa, .{ .line_to = current });
            },
            'C' => {
                const c1 = base.add(try p.point());
                const c2 = base.add(try p.point());
                current = base.add(try p.point());
                try out.append(gpa, .{ .cubic_to = .{ .c1 = c1, .c2 = c2, .p = current } });
                cubic_ctrl = c2;
            },
            'S' => {
                const c1 = reflect(last_cubic_ctrl, current);
                const c2 = base.add(try p.point());
                current = base.add(try p.point());
                try out.append(gpa, .{ .cubic_to = .{ .c1 = c1, .c2 = c2, .p = current } });
                cubic_ctrl = c2;
            },
            'Q' => {
                const c = base.add(try p.point());
                current = base.add(try p.point());
                try out.append(gpa, .{ .quad_to = .{ .c = c, .p = current } });
                quad_ctrl = c;
            },
            'T' => {
                const c = reflect(last_quad_ctrl, current);
                current = base.add(try p.point());
                try out.append(gpa, .{ .quad_to = .{ .c = c, .p = current } });
                quad_ctrl = c;
            },
            'A' => {
                const rx = try p.number();
                const ry = try p.number();
                const rotation = try p.number();
                const large = try p.flag();
                const sweep = try p.flag();
                const end = base.add(try p.point());
                try arcToCubics(gpa, out, current, rx, ry, rotation, large, sweep, end);
                current = end;
            },
            'Z' => {
                try out.append(gpa, .close);
                current = start;
            },
            else => return error.InvalidPath,
        }
        last_cubic_ctrl = cubic_ctrl;
        last_quad_ctrl = quad_ctrl;
    }
}

fn reflect(ctrl: ?Point, around: Point) Point {
    const c = ctrl orelse return around;
    return .{ .x = 2 * around.x - c.x, .y = 2 * around.y - c.y };
}

const Parser = struct {
    text: []const u8,
    pos: usize = 0,

    fn done(p: *Parser) bool {
        return p.pos >= p.text.len;
    }

    fn peek(p: *Parser) u8 {
        return p.text[p.pos];
    }

    fn next(p: *Parser) u8 {
        p.pos += 1;
        return p.text[p.pos - 1];
    }

    fn skipSeparators(p: *Parser) void {
        while (!p.done() and (std.ascii.isWhitespace(p.peek()) or p.peek() == ',')) p.pos += 1;
    }

    fn number(p: *Parser) ParseError!f32 {
        p.skipSeparators();
        const begin = p.pos;
        if (!p.done() and (p.peek() == '-' or p.peek() == '+')) p.pos += 1;
        var seen_dot = false;
        var digits: usize = 0;
        while (!p.done()) : (p.pos += 1) {
            const c = p.peek();
            if (std.ascii.isDigit(c)) {
                digits += 1;
            } else if (c == '.' and !seen_dot) {
                seen_dot = true;
            } else break;
        }
        if (digits == 0) return error.InvalidPath;
        if (!p.done() and (p.peek() == 'e' or p.peek() == 'E')) {
            p.pos += 1;
            if (!p.done() and (p.peek() == '-' or p.peek() == '+')) p.pos += 1;
            while (!p.done() and std.ascii.isDigit(p.peek())) p.pos += 1;
        }
        return std.fmt.parseFloat(f32, p.text[begin..p.pos]) catch error.InvalidPath;
    }

    fn point(p: *Parser) ParseError!Point {
        const x = try p.number();
        return .{ .x = x, .y = try p.number() };
    }

    /// Arc flags are single digits and may be written without separators.
    fn flag(p: *Parser) ParseError!bool {
        p.skipSeparators();
        if (p.done()) return error.InvalidPath;
        return switch (p.next()) {
            '0' => false,
            '1' => true,
            else => error.InvalidPath,
        };
    }
};

/// Converts an SVG elliptical arc to cubic Béziers (SVG 1.1, F.6.5).
fn arcToCubics(gpa: Allocator, out: *std.ArrayList(Command), p0: Point, rx_in: f32, ry_in: f32, rotation_deg: f32, large: bool, sweep: bool, p1: Point) Allocator.Error!void {
    if (p0.x == p1.x and p0.y == p1.y) return;
    var rx = @abs(rx_in);
    var ry = @abs(ry_in);
    if (rx == 0 or ry == 0) return out.append(gpa, .{ .line_to = p1 });

    const phi = std.math.degreesToRadians(rotation_deg);
    const cos = @cos(phi);
    const sin = @sin(phi);
    const dx2 = (p0.x - p1.x) / 2;
    const dy2 = (p0.y - p1.y) / 2;
    const x1p = cos * dx2 + sin * dy2;
    const y1p = -sin * dx2 + cos * dy2;

    const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1) {
        rx *= @sqrt(lambda);
        ry *= @sqrt(lambda);
    }
    const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var coef = if (den == 0) 0 else @sqrt(@max(0, num / den));
    if (large == sweep) coef = -coef;
    const cxp = coef * rx * y1p / ry;
    const cyp = -coef * ry * x1p / rx;
    const cx = cos * cxp - sin * cyp + (p0.x + p1.x) / 2;
    const cy = sin * cxp + cos * cyp + (p0.y + p1.y) / 2;

    const theta1 = angleBetween(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    var dtheta = angleBetween((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    if (!sweep and dtheta > 0) dtheta -= 2 * std.math.pi;
    if (sweep and dtheta < 0) dtheta += 2 * std.math.pi;

    const segments: usize = @intFromFloat(@max(1, @ceil(@abs(dtheta) / (std.math.pi / 2.0) - 1e-4)));
    const delta = dtheta / @as(f32, @floatFromInt(segments));
    const k = 4.0 / 3.0 * @tan(delta / 4);
    const map = struct {
        fn f(ux: f32, uy: f32, crx: f32, cry: f32, c: f32, s: f32, ccx: f32, ccy: f32) Point {
            return .{ .x = ccx + crx * c * ux - cry * s * uy, .y = ccy + crx * s * ux + cry * c * uy };
        }
    }.f;
    for (0..segments) |i| {
        const t1 = theta1 + delta * @as(f32, @floatFromInt(i));
        const t2 = t1 + delta;
        const c1 = map(@cos(t1) - k * @sin(t1), @sin(t1) + k * @cos(t1), rx, ry, cos, sin, cx, cy);
        const c2 = map(@cos(t2) + k * @sin(t2), @sin(t2) - k * @cos(t2), rx, ry, cos, sin, cx, cy);
        const end = if (i == segments - 1) p1 else map(@cos(t2), @sin(t2), rx, ry, cos, sin, cx, cy);
        try out.append(gpa, .{ .cubic_to = .{ .c1 = c1, .c2 = c2, .p = end } });
    }
}

fn angleBetween(ux: f32, uy: f32, vx: f32, vy: f32) f32 {
    return std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
}

/// Maps path coordinates: `p * scale + offset`.
pub const Transform = struct {
    scale: Point = .{ .x = 1, .y = 1 },
    offset: Point = .{},

    pub fn apply(t: Transform, p: Point) Point {
        return .{ .x = p.x * t.scale.x + t.offset.x, .y = p.y * t.scale.y + t.offset.y };
    }

    /// The length of the difference (dx, dy) once mapped.
    pub fn length(t: Transform, dx: f32, dy: f32) f32 {
        const x = dx * t.scale.x;
        const y = dy * t.scale.y;
        return @sqrt(x * x + y * y);
    }

    /// Maps `from` into `to` at a uniform scale, centered (SVG's default
    /// `xMidYMid meet`).
    pub fn contain(from: Rect, to: Rect) Transform {
        const sx = if (from.width > 0) to.width / from.width else std.math.inf(f32);
        const sy = if (from.height > 0) to.height / from.height else std.math.inf(f32);
        var scale = @min(sx, sy);
        if (std.math.isInf(scale)) scale = 1;
        const w = from.width * scale;
        const h = from.height * scale;
        return .{
            .scale = .{ .x = scale, .y = scale },
            .offset = .{ .x = to.x + (to.width - w) / 2 - from.x * scale, .y = to.y + (to.height - h) / 2 - from.y * scale },
        };
    }

    /// Maps `from` onto `to`, stretching.
    pub fn fit(from: Rect, to: Rect) Transform {
        const sx = if (from.width > 0) to.width / from.width else 1;
        const sy = if (from.height > 0) to.height / from.height else 1;
        return .{ .scale = .{ .x = sx, .y = sy }, .offset = .{ .x = to.x - from.x * sx, .y = to.y - from.y * sy } };
    }
};

/// Flattened subpaths.
pub const Polylines = struct {
    points: std.ArrayList(Point) = .empty,
    subpaths: std.ArrayList(Subpath) = .empty,

    pub const Subpath = struct {
        start: u32,
        len: u32,
        /// Ended with `Z`. (Fills close every subpath regardless.)
        closed: bool,
    };

    pub fn deinit(self: *Polylines, gpa: Allocator) void {
        self.points.deinit(gpa);
        self.subpaths.deinit(gpa);
    }

    pub fn clear(self: *Polylines) void {
        self.points.clearRetainingCapacity();
        self.subpaths.clearRetainingCapacity();
    }

    pub fn subpathPoints(self: *const Polylines, s: Subpath) []const Point {
        return self.points.items[s.start..][0..s.len];
    }

    pub fn bounds(self: *const Polylines) Rect {
        if (self.points.items.len == 0) return .empty;
        var x0 = std.math.inf(f32);
        var y0 = std.math.inf(f32);
        var x1 = -std.math.inf(f32);
        var y1 = -std.math.inf(f32);
        for (self.points.items) |p| {
            x0 = @min(x0, p.x);
            y0 = @min(y0, p.y);
            x1 = @max(x1, p.x);
            y1 = @max(y1, p.y);
        }
        return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
    }
};

/// Flattens `commands` (mapped through `transform`) into line segments
/// deviating at most about `tolerance` pixels from the curves.
pub fn flatten(gpa: Allocator, commands: []const Command, transform: Transform, tolerance: f32, out: *Polylines) Allocator.Error!void {
    out.clear();
    var current: Point = .{};
    // The current point before the transform: segment counts come from
    // untransformed differences scaled, the same wherever the path is
    // (offsets round differently in mapped coordinates).
    var source: Point = .{};
    // Where the subpath began, untransformed.
    var start: Point = .{};
    var open = false;
    for (commands) |c| {
        switch (c) {
            .move_to => |p| {
                try finishSubpath(gpa, out, &open, false);
                source = p;
                start = p;
                current = transform.apply(p);
                try beginSubpath(gpa, out, current);
                open = true;
            },
            .line_to => |p| {
                if (!open) {
                    try beginSubpath(gpa, out, current);
                    start = source;
                }
                open = true;
                source = p;
                current = transform.apply(p);
                try out.points.append(gpa, current);
            },
            .quad_to => |q| {
                if (!open) {
                    try beginSubpath(gpa, out, current);
                    start = source;
                }
                open = true;
                const c1 = transform.apply(q.c);
                const end = transform.apply(q.p);
                const dd = transform.length(source.x - 2 * q.c.x + q.p.x, source.y - 2 * q.c.y + q.p.y);
                const n = segmentCount(dd / 4, tolerance);
                for (1..n + 1) |i| {
                    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
                    const u = 1 - t;
                    try out.points.append(gpa, .{
                        .x = u * u * current.x + 2 * u * t * c1.x + t * t * end.x,
                        .y = u * u * current.y + 2 * u * t * c1.y + t * t * end.y,
                    });
                }
                current = end;
                source = q.p;
            },
            .cubic_to => |q| {
                if (!open) {
                    try beginSubpath(gpa, out, current);
                    start = source;
                }
                open = true;
                const c1 = transform.apply(q.c1);
                const c2 = transform.apply(q.c2);
                const end = transform.apply(q.p);
                const dd = @max(
                    transform.length(source.x - 2 * q.c1.x + q.c2.x, source.y - 2 * q.c1.y + q.c2.y),
                    transform.length(q.c1.x - 2 * q.c2.x + q.p.x, q.c1.y - 2 * q.c2.y + q.p.y),
                );
                const n = segmentCount(dd * 0.75, tolerance);
                for (1..n + 1) |i| {
                    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
                    const u = 1 - t;
                    const a = u * u * u;
                    const b = 3 * u * u * t;
                    const d = 3 * u * t * t;
                    const e = t * t * t;
                    try out.points.append(gpa, .{
                        .x = a * current.x + b * c1.x + d * c2.x + e * end.x,
                        .y = a * current.y + b * c1.y + d * c2.y + e * end.y,
                    });
                }
                current = end;
                source = q.p;
            },
            .close => {
                if (open) {
                    const s = out.subpaths.items[out.subpaths.items.len - 1];
                    current = out.points.items[s.start];
                    source = start;
                }
                try finishSubpath(gpa, out, &open, true);
            },
        }
    }
    try finishSubpath(gpa, out, &open, false);
}

fn length(x: f32, y: f32) f32 {
    return @sqrt(x * x + y * y);
}

/// Wang's formula: segments needed for a curve with the given scaled
/// second difference.
fn segmentCount(scaled_dd: f32, tolerance: f32) usize {
    const n = @ceil(@sqrt(scaled_dd / @max(tolerance, 1e-3)));
    return @intFromFloat(std.math.clamp(n, 1, 128));
}

/// Whether `p` is inside the fill of SVG path data `text` (mapped by
/// `transform`; non-zero winding, every subpath closed, as fills are).
pub fn contains(gpa: Allocator, text: []const u8, transform: Transform, p: Point) ParseError!bool {
    var commands: std.ArrayList(Command) = .empty;
    defer commands.deinit(gpa);
    try parse(gpa, text, &commands);
    var lines: Polylines = .{};
    defer lines.deinit(gpa);
    try flatten(gpa, commands.items, transform, 0.25, &lines);
    var winding: i32 = 0;
    for (lines.subpaths.items) |sp| {
        const pts = lines.subpathPoints(sp);
        for (pts, 0..) |a, i| {
            const b = pts[(i + 1) % pts.len];
            // Edges crossing the horizontal line through `p`, right of it.
            if ((a.y <= p.y) == (b.y <= p.y)) continue;
            const x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x);
            if (x > p.x) winding += if (b.y > a.y) 1 else -1;
        }
    }
    return winding != 0;
}

fn beginSubpath(gpa: Allocator, out: *Polylines, p: Point) Allocator.Error!void {
    try out.subpaths.append(gpa, .{ .start = @intCast(out.points.items.len), .len = 0, .closed = false });
    try out.points.append(gpa, p);
}

fn finishSubpath(gpa: Allocator, out: *Polylines, open: *bool, closed: bool) Allocator.Error!void {
    _ = gpa;
    if (!open.*) return;
    open.* = false;
    const s = &out.subpaths.items[out.subpaths.items.len - 1];
    s.len = @intCast(out.points.items.len - s.start);
    s.closed = closed;
}

const testing = std.testing;

test "curves flatten into as many segments wherever they are" {
    // Squashed flat, this curve needs exactly 3 segments by Wang's
    // formula: computed from mapped points, rounding made it 3 or 4 by
    // where the path was (the GPU renderer draws masks near the origin).
    var list = try parseAll("M 0 0 C 10 0 10 10 0 10");
    defer list.deinit(testing.allocator);
    var a: Polylines = .{};
    defer a.deinit(testing.allocator);
    var b: Polylines = .{};
    defer b.deinit(testing.allocator);
    const scale: Point = .{ .x = 0.24, .y = 0 };
    try flatten(testing.allocator, list.items, .{ .scale = scale, .offset = .{ .x = 39.952, .y = 3.952 } }, 0.2, &a);
    try flatten(testing.allocator, list.items, .{ .scale = scale, .offset = .{ .x = 0.95875, .y = 0.953125 } }, 0.2, &b);
    try testing.expectEqual(a.points.items.len, b.points.items.len);
}

fn parseAll(text: []const u8) !std.ArrayList(Command) {
    var list: std.ArrayList(Command) = .empty;
    errdefer list.deinit(testing.allocator);
    try parse(testing.allocator, text, &list);
    return list;
}

test "parse absolute, relative and shorthand commands" {
    var list = try parseAll("M10,10 l5 0 H30 v10 h-20 z m 1 1 2 2");
    defer list.deinit(testing.allocator);
    const expected = [_]Command{
        .{ .move_to = .{ .x = 10, .y = 10 } },
        .{ .line_to = .{ .x = 15, .y = 10 } },
        .{ .line_to = .{ .x = 30, .y = 10 } },
        .{ .line_to = .{ .x = 30, .y = 20 } },
        .{ .line_to = .{ .x = 10, .y = 20 } },
        .close,
        .{ .move_to = .{ .x = 11, .y = 11 } },
        .{ .line_to = .{ .x = 13, .y = 13 } },
    };
    try testing.expectEqualSlices(Command, &expected, list.items);
}

test "parse curves, reflections and compact numbers" {
    var list = try parseAll("M0 0C10 0 20 10 20 20S30 40 40 40Q50 40 50 50T60 60M-1.5e1-.5.5.5");
    defer list.deinit(testing.allocator);
    try testing.expectEqual(Point{ .x = 20, .y = 30 }, list.items[2].cubic_to.c1); // reflected
    try testing.expectEqual(Point{ .x = 50, .y = 60 }, list.items[4].quad_to.c);
    try testing.expectEqual(Point{ .x = -15, .y = -0.5 }, list.items[5].move_to);
    try testing.expectEqual(Point{ .x = 0.5, .y = 0.5 }, list.items[6].line_to);
}

test "arcs become cubics ending exactly at the endpoint" {
    // A half circle of radius 10 from (0,0) to (20,0), with packed flags.
    var list = try parseAll("M0 0A10 10 0 0120 0");
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), list.items.len); // move + 2 quarter arcs
    try testing.expectEqual(Point{ .x = 20, .y = 0 }, list.items[2].cubic_to.p);
    // The midpoint lies on the circle (sweep 1 = clockwise on screen = upwards here).
    const mid = list.items[1].cubic_to.p;
    try testing.expectApproxEqAbs(@as(f32, 10), mid.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, -10), mid.y, 1e-3);
}

test "invalid path data is rejected" {
    var list: std.ArrayList(Command) = .empty;
    defer list.deinit(testing.allocator);
    try testing.expectError(error.InvalidPath, parse(testing.allocator, "10 10", &list));
    try testing.expectError(error.InvalidPath, parse(testing.allocator, "M10", &list));
    try testing.expectError(error.InvalidPath, parse(testing.allocator, "M0 0 X", &list));
}

test "flattening stays within tolerance of the curve" {
    var list = try parseAll("M0 0A50 50 0 0 1 100 0Z");
    defer list.deinit(testing.allocator);
    var lines: Polylines = .{};
    defer lines.deinit(testing.allocator);
    try flatten(testing.allocator, list.items, .{}, 0.25, &lines);
    try testing.expectEqual(@as(usize, 1), lines.subpaths.items.len);
    try testing.expect(lines.subpaths.items[0].closed);
    for (lines.subpathPoints(lines.subpaths.items[0])) |p| {
        const r = length(p.x - 50, p.y);
        try testing.expectApproxEqAbs(@as(f32, 50), r, 0.3);
    }
    const b = lines.bounds();
    try testing.expectApproxEqAbs(@as(f32, -50), b.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 100), b.width, 0.01);

    // Uniform fit of the 100x50 half disc into a 40x10 box: 20x10, centered.
    try flatten(testing.allocator, list.items, .contain(b, .{ .width = 40, .height = 10 }), 0.25, &lines);
    try testing.expectApproxEqAbs(@as(f32, 10), lines.bounds().x, 0.05);
    try testing.expectApproxEqAbs(@as(f32, 20), lines.bounds().width, 0.05);

    // Transform: stretch into a 10x10 box.
    try flatten(testing.allocator, list.items, .fit(b, .{ .width = 10, .height = 10 }), 0.25, &lines);
    const fb = lines.bounds();
    try testing.expectApproxEqAbs(@as(f32, 0), fb.y, 0.05);
    try testing.expectApproxEqAbs(@as(f32, 10), fb.height, 0.05);
}

test "points inside a fill: non-zero winding, a hole wound the other way" {
    const square = "M 0 0 L 10 0 L 10 10 L 0 10 Z";
    try testing.expect(try contains(testing.allocator, square, .{}, .{ .x = 5, .y = 5 }));
    try testing.expect(!try contains(testing.allocator, square, .{}, .{ .x = 11, .y = 5 }));
    // Unclosed: closed as a fill is.
    try testing.expect(try contains(testing.allocator, "M 0 0 L 10 0 L 0 10", .{}, .{ .x = 2, .y = 2 }));
    try testing.expect(!try contains(testing.allocator, "M 0 0 L 10 0 L 0 10", .{}, .{ .x = 8, .y = 8 }));
    const ring = "M 0 0 L 10 0 L 10 10 L 0 10 Z M 3 3 L 3 7 L 7 7 L 7 3 Z";
    try testing.expect(!try contains(testing.allocator, ring, .{}, .{ .x = 5, .y = 5 }));
    try testing.expect(try contains(testing.allocator, ring, .{}, .{ .x = 1, .y = 5 }));
    try testing.expect(try contains(testing.allocator, "M 0 0 L 10 0 L 10 10 Z", .{ .scale = .{ .x = 2, .y = 2 } }, .{ .x = 15, .y = 5 }));
}
