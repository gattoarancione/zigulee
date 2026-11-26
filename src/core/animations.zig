// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Animation descriptions (the `animate prop { ... }` construct), easing
//! curves and value interpolation. The animated bindings themselves live on
//! `Property(T)`: `setAnimated` and `setAnimatedBinding`.

const std = @import("std");

pub const Direction = enum { normal, reverse, alternate, alternate_reverse };

pub const Animation = struct {
    duration_ms: u32 = 0,
    delay_ms: u32 = 0,
    easing: Easing = .linear,
    /// Number of iterations; null repeats forever.
    iterations: ?u32 = 1,
    direction: Direction = .normal,

    pub fn isInstant(self: Animation) bool {
        return self.duration_ms == 0 and self.delay_ms == 0;
    }
};

pub const Easing = union(enum) {
    linear,
    ease,
    ease_in,
    ease_out,
    ease_in_out,
    ease_in_quad,
    ease_out_quad,
    ease_in_out_quad,
    ease_in_cubic,
    ease_out_cubic,
    ease_in_out_cubic,
    ease_out_back,
    ease_out_elastic,
    ease_out_bounce,
    /// CSS `cubic-bezier(x1, y1, x2, y2)`.
    cubic_bezier: [4]f32,
    /// A spring settling over the duration (`spring(bounce)`): 0 comes to
    /// rest without overshooting, up to 1 bounces more and more.
    spring: f32,

    /// Maps linear progress `t` in [0, 1] to eased progress. Endpoints map
    /// to 0 and 1; some curves overshoot in between.
    pub fn apply(self: Easing, t: f32) f32 {
        if (t <= 0) return 0;
        if (t >= 1) return 1;
        return switch (self) {
            .linear => t,
            .ease => cubicBezier(.{ 0.25, 0.1, 0.25, 1 }, t),
            .ease_in => cubicBezier(.{ 0.42, 0, 1, 1 }, t),
            .ease_out => cubicBezier(.{ 0, 0, 0.58, 1 }, t),
            .ease_in_out => cubicBezier(.{ 0.42, 0, 0.58, 1 }, t),
            .ease_in_quad => t * t,
            .ease_out_quad => 1 - (1 - t) * (1 - t),
            .ease_in_out_quad => if (t < 0.5) 2 * t * t else 1 - std.math.pow(f32, -2 * t + 2, 2) / 2,
            .ease_in_cubic => t * t * t,
            .ease_out_cubic => 1 - std.math.pow(f32, 1 - t, 3),
            .ease_in_out_cubic => if (t < 0.5) 4 * t * t * t else 1 - std.math.pow(f32, -2 * t + 2, 3) / 2,
            .ease_out_back => blk: {
                const c1 = 1.70158;
                const c3 = c1 + 1;
                break :blk 1 + c3 * std.math.pow(f32, t - 1, 3) + c1 * std.math.pow(f32, t - 1, 2);
            },
            .ease_out_elastic => blk: {
                const c4 = (2 * std.math.pi) / 3.0;
                break :blk std.math.pow(f32, 2, -10 * t) * @sin((t * 10 - 0.75) * c4) + 1;
            },
            .ease_out_bounce => bounceOut(t),
            .cubic_bezier => |p| cubicBezier(p, t),
            .spring => |bounce| springAt(bounce, t),
        };
    }
};

/// A damped spring's position at `t` (its rest at 1), its damping from
/// `bounce` (1 - damping ratio), its stiffness such that it is within
/// 0.1% of rest at t = 1.
fn springAt(bounce: f32, t: f32) f32 {
    const zeta = std.math.clamp(1 - bounce, 0.05, 1);
    const omega = @log(1000.0) / zeta;
    const decay = @exp(-zeta * omega * t);
    if (zeta >= 1) return 1 - decay * (1 + omega * t); // critically damped
    const wd = omega * @sqrt(1 - zeta * zeta);
    return 1 - decay * (@cos(wd * t) + zeta * omega / wd * @sin(wd * t));
}

/// How far the same spring (`springAt`) is carried at `t` by a speed it
/// starts with: per unit of speed (in values per duration), from rest at
/// its target. A spring retargeted while it moves adds it, times that
/// speed, to its course from the value it was at.
pub fn springCarry(bounce: f32, t: f32) f32 {
    if (t <= 0 or t >= 1) return 0;
    const zeta = std.math.clamp(1 - bounce, 0.05, 1);
    const omega = @log(1000.0) / zeta;
    const decay = @exp(-zeta * omega * t);
    if (zeta >= 1) return decay * t;
    const wd = omega * @sqrt(1 - zeta * zeta);
    return decay * @sin(wd * t) / wd;
}

fn bounceOut(t: f32) f32 {
    const n1: f32 = 7.5625;
    const d1: f32 = 2.75;
    if (t < 1 / d1) return n1 * t * t;
    if (t < 2 / d1) {
        const x = t - 1.5 / d1;
        return n1 * x * x + 0.75;
    }
    if (t < 2.5 / d1) {
        const x = t - 2.25 / d1;
        return n1 * x * x + 0.9375;
    }
    const x = t - 2.625 / d1;
    return n1 * x * x + 0.984375;
}

/// One coordinate of a cubic Bézier with endpoints 0 and 1.
fn bezier(a1: f32, a2: f32, s: f32) f32 {
    const u = 1 - s;
    return 3 * u * u * s * a1 + 3 * u * s * s * a2 + s * s * s;
}

fn bezierSlope(a1: f32, a2: f32, s: f32) f32 {
    const u = 1 - s;
    return 3 * u * u * a1 + 6 * u * s * (a2 - a1) + 3 * s * s * (1 - a2);
}

fn cubicBezier(p: [4]f32, t: f32) f32 {
    const x1, const y1, const x2, const y2 = p;
    // Solve x(s) = t: Newton's method, then bisection if it did not converge.
    var s = t;
    for (0..8) |_| {
        const err = bezier(x1, x2, s) - t;
        if (@abs(err) < 1e-6) return bezier(y1, y2, s);
        const slope = bezierSlope(x1, x2, s);
        if (@abs(slope) < 1e-6) break;
        s -= err / slope;
    }
    var lo: f32 = 0;
    var hi: f32 = 1;
    s = t;
    for (0..32) |_| {
        const x = bezier(x1, x2, s);
        if (@abs(x - t) < 1e-6) break;
        if (x < t) lo = s else hi = s;
        s = (lo + hi) / 2;
    }
    return bezier(y1, y2, s);
}

pub const Progress = struct {
    /// Eased progress from the start value (0) to the end value (1).
    t: f32,
    finished: bool,
    /// Progress through the duration (0 to 1), not eased.
    raw: f32 = 0,
};

/// Where an animation that started at `start_ms` is at `now_ms`.
pub fn progress(anim: Animation, start_ms: u64, now_ms: u64) Progress {
    const elapsed_total = now_ms -| start_ms;
    if (elapsed_total < anim.delay_ms)
        return .{ .t = anim.easing.apply(directed(anim.direction, 0, 0)), .finished = false };
    const elapsed = elapsed_total - anim.delay_ms;

    const last_iteration: u64 = if (anim.iterations) |n| @max(n, 1) - 1 else 0;
    if (anim.duration_ms == 0 or anim.iterations == @as(?u32, 0))
        return .{ .t = anim.easing.apply(directed(anim.direction, last_iteration, 1)), .finished = true };

    const iteration = elapsed / anim.duration_ms;
    if (anim.iterations) |n| if (iteration >= n)
        return .{ .t = anim.easing.apply(directed(anim.direction, last_iteration, 1)), .finished = true };

    const raw: f32 = @as(f32, @floatFromInt(elapsed % anim.duration_ms)) / @as(f32, @floatFromInt(anim.duration_ms));
    const at = directed(anim.direction, iteration, raw);
    return .{ .t = anim.easing.apply(at), .finished = false, .raw = at };
}

fn directed(direction: Direction, iteration: u64, raw: f32) f32 {
    const odd = iteration % 2 == 1;
    return switch (direction) {
        .normal => raw,
        .reverse => 1 - raw,
        .alternate => if (odd) 1 - raw else raw,
        .alternate_reverse => if (odd) raw else 1 - raw,
    };
}

/// Interpolates between `a` (t = 0) and `b` (t = 1). Supports floats,
/// integers (rounded, clamped to the type's range), structs and unions that
/// declare `pub fn interpolate(a, b, t: f32) T`, and other structs field by
/// field.
pub fn interpolate(comptime T: type, a: T, b: T, t: f32) T {
    if (t == 0) return a;
    if (t == 1) return b;
    switch (@typeInfo(T)) {
        .float => return a + (b - a) * @as(T, @floatCast(t)),
        .int => {
            const fa: f64 = @floatFromInt(a);
            const fb: f64 = @floatFromInt(b);
            const v = @round(fa + (fb - fa) * t);
            const lo: f64 = @floatFromInt(std.math.minInt(T));
            const hi: f64 = @floatFromInt(std.math.maxInt(T));
            return @intFromFloat(std.math.clamp(v, lo, hi));
        },
        .@"struct" => |s| {
            if (@hasDecl(T, "interpolate")) return T.interpolate(a, b, t);
            var out: T = undefined;
            inline for (s.fields) |f|
                @field(out, f.name) = interpolate(f.type, @field(a, f.name), @field(b, f.name), t);
            return out;
        },
        .@"union" => {
            if (!@hasDecl(T, "interpolate")) @compileError(not_animatable ++ @typeName(T));
            return T.interpolate(a, b, t);
        },
        else => @compileError(not_animatable ++ @typeName(T)),
    }
}

const not_animatable = "zigulee: this type cannot be animated: ";

const testing = std.testing;

test "easing endpoints and known midpoints" {
    const all = [_]Easing{
        .linear,        .ease,             .ease_in,          .ease_out,                                    .ease_in_out,
        .ease_in_quad,  .ease_out_quad,    .ease_in_out_quad, .ease_in_cubic,                               .ease_out_cubic,
        .ease_out_back, .ease_out_elastic, .ease_out_bounce,  .{ .cubic_bezier = .{ 0.3, 0.2, 0.7, 0.9 } }, .ease_in_out_cubic,
    };
    for (all) |e| {
        try testing.expectEqual(@as(f32, 0), e.apply(0));
        try testing.expectEqual(@as(f32, 1), e.apply(1));
    }
    try testing.expectApproxEqAbs(@as(f32, 0.5), (Easing{ .ease_in_out = {} }).apply(0.5), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.25), (Easing{ .ease_in_quad = {} }).apply(0.5), 1e-6);
    // cubic-bezier(0, 0, 1, 1) is linear.
    const lin: Easing = .{ .cubic_bezier = .{ 0, 0, 1, 1 } };
    for ([_]f32{ 0.1, 0.33, 0.5, 0.9 }) |t| try testing.expectApproxEqAbs(t, lin.apply(t), 1e-4);
    // ease-in is slower than linear at the start, ease-out faster.
    try testing.expect((Easing{ .ease_in = {} }).apply(0.25) < 0.25);
    try testing.expect((Easing{ .ease_out = {} }).apply(0.25) > 0.25);
}

test "css ease curve matches reference values" {
    // Reference: Chrome's cubic-bezier(0.25, 0.1, 0.25, 1) at x = 0.5.
    try testing.expectApproxEqAbs(@as(f32, 0.8024), (Easing{ .ease = {} }).apply(0.5), 1e-3);
}

test "progress: delay, iterations and direction" {
    const anim: Animation = .{ .duration_ms = 100, .delay_ms = 50, .iterations = 2, .direction = .alternate };
    try testing.expectEqual(Progress{ .t = 0, .finished = false }, progress(anim, 1000, 1000));
    try testing.expectEqual(Progress{ .t = 0, .finished = false }, progress(anim, 1000, 1049));
    try testing.expectEqual(Progress{ .t = 0.5, .finished = false, .raw = 0.5 }, progress(anim, 1000, 1100));
    try testing.expectEqual(Progress{ .t = 0.75, .finished = false, .raw = 0.75 }, progress(anim, 1000, 1175)); // second iteration runs backwards
    try testing.expectEqual(Progress{ .t = 0, .finished = true }, progress(anim, 1000, 1250));

    const forever: Animation = .{ .duration_ms = 100, .iterations = null };
    try testing.expectEqual(Progress{ .t = 0.5, .finished = false, .raw = 0.5 }, progress(forever, 0, 1_000_050));

    const instant: Animation = .{};
    try testing.expectEqual(Progress{ .t = 1, .finished = true }, progress(instant, 0, 0));
}

test "interpolate numbers and structs" {
    try testing.expectEqual(@as(f32, 25), interpolate(f32, 0, 100, 0.25));
    try testing.expectEqual(@as(i32, -5), interpolate(i32, 0, -10, 0.5));
    try testing.expectEqual(@as(u8, 0), interpolate(u8, 10, 200, -0.5)); // overshoot clamps
    const Point = struct { x: f32, y: i16 };
    try testing.expectEqual(Point{ .x = 5, .y = 50 }, interpolate(Point, .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 100 }, 0.5));
}

test "spring easing: settles at 1, overshoots only with bounce" {
    const stiff: Easing = .{ .spring = 0 };
    const bouncy: Easing = .{ .spring = 0.6 };
    var over_stiff = false;
    var over_bouncy = false;
    var t: f32 = 0;
    while (t < 1) : (t += 0.01) {
        if (stiff.apply(t) > 1.001) over_stiff = true;
        if (bouncy.apply(t) > 1.01) over_bouncy = true;
    }
    try testing.expect(!over_stiff);
    try testing.expect(over_bouncy);
    try testing.expect(@abs(stiff.apply(0.99) - 1) < 0.01);
    try testing.expect(@abs(bouncy.apply(0.99) - 1) < 0.01);
    try testing.expectEqual(@as(f32, 1), bouncy.apply(1));
}
