// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Colors, brushes and pixels.

const std = @import("std");
const interpolate = @import("animations.zig").interpolate;

/// An sRGB color with straight (non-premultiplied) alpha.
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

    pub const transparent: Color = .{};
    pub const black: Color = .rgb(0x000000);
    pub const white: Color = .rgb(0xffffff);

    /// From `0xRRGGBB`, fully opaque.
    pub fn rgb(hex: u24) Color {
        return .{ .r = @truncate(hex >> 16), .g = @truncate(hex >> 8), .b = @truncate(hex), .a = 0xff };
    }

    /// From `0xRRGGBBAA`.
    pub fn rgba(hex: u32) Color {
        return .{ .r = @truncate(hex >> 24), .g = @truncate(hex >> 16), .b = @truncate(hex >> 8), .a = @truncate(hex) };
    }

    pub fn withAlpha(c: Color, a: u8) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
    }

    pub fn isTransparent(c: Color) bool {
        return c.a == 0;
    }

    pub fn premultiplied(c: Color) Rgba8 {
        return .{ .r = mul8(c.r, c.a), .g = mul8(c.g, c.a), .b = mul8(c.b, c.a), .a = c.a };
    }
};

/// `a * b / 255`, rounded.
pub fn mul8(a: u8, b: u8) u8 {
    const p = @as(u32, a) * b + 128;
    return @intCast((p + (p >> 8)) >> 8);
}

/// A pixel with premultiplied alpha, the format images and the software
/// renderer work in.
pub const Rgba8 = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

    pub const transparent: Rgba8 = .{};

    /// Back to straight alpha (lossy for low alpha).
    pub fn unpremultiplied(p: Rgba8) Color {
        if (p.a == 0) return .transparent;
        const a: u32 = p.a;
        return .{
            .r = @intCast(@min(255, (@as(u32, p.r) * 255 + a / 2) / a)),
            .g = @intCast(@min(255, (@as(u32, p.g) * 255 + a / 2) / a)),
            .b = @intCast(@min(255, (@as(u32, p.b) * 255 + a / 2) / a)),
            .a = p.a,
        };
    }

    /// Scales all channels by `f` / 255.
    pub fn scale(p: Rgba8, f: u8) Rgba8 {
        return .{ .r = mul8(p.r, f), .g = mul8(p.g, f), .b = mul8(p.b, f), .a = mul8(p.a, f) };
    }
};

pub const GradientStop = struct {
    color: Color,
    /// 0 at the start of the gradient, 1 at the end.
    position: f32,
};

/// Stops of a gradient: borrowed, like strings, so brushes stay small.
pub const GradientStops = struct {
    items: []const GradientStop = &.{},

    pub fn init(stops: []const GradientStop) GradientStops {
        return .{ .items = stops };
    }

    pub fn slice(s: GradientStops) []const GradientStop {
        return s.items;
    }

    pub fn eql(a: GradientStops, b: GradientStops) bool {
        if (a.items.ptr == b.items.ptr and a.items.len == b.items.len) return true;
        if (a.items.len != b.items.len) return false;
        for (a.items, b.items) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }

    /// The color at `t`, interpolated in premultiplied space.
    pub fn sample(s: GradientStops, t: f32) Rgba8 {
        const stops = s.items;
        if (stops.len == 0) return .transparent;
        if (t <= stops[0].position) return stops[0].color.premultiplied();
        for (stops[1..], 1..) |b, i| {
            if (t > b.position) continue;
            const a = stops[i - 1];
            const span = b.position - a.position;
            const f = if (span <= 0) 1 else (t - a.position) / span;
            return lerpPremultiplied(a.color.premultiplied(), b.color.premultiplied(), f);
        }
        return stops[stops.len - 1].color.premultiplied();
    }

    fn allTransparent(s: GradientStops) bool {
        for (s.items) |stop| if (!stop.color.isTransparent()) return false;
        return true;
    }
};

fn lerpPremultiplied(a: Rgba8, b: Rgba8, t: f32) Rgba8 {
    const f = std.math.clamp(t, 0, 1);
    const ch = struct {
        fn c(x: u8, y: u8, k: f32) u8 {
            const xf: f32 = @floatFromInt(x);
            const yf: f32 = @floatFromInt(y);
            return @intFromFloat(@round(xf + (yf - xf) * k));
        }
    }.c;
    return .{ .r = ch(a.r, b.r, f), .g = ch(a.g, b.g, f), .b = ch(a.b, b.b, f), .a = ch(a.a, b.a, f) };
}

pub const LinearGradient = struct {
    /// Direction in degrees, as in CSS: 0 points up, 90 right, 180 down.
    angle: f32 = 180,
    stops: GradientStops = .{},
    /// SVG's geometry instead of the angle: from a start to an end point,
    /// as fractions of the box painted (0, 0 its top left corner, 1, 1 its
    /// bottom right), with lines of one color square to that line in
    /// those fractions (as SVG's `objectBoundingBox`). Only paths take it
    /// on the GPU; other shapes draw it about their own center.
    line: ?[2][2]f32 = null,

    pub fn eql(a: *const LinearGradient, b: *const LinearGradient) bool {
        return a == b or (a.angle == b.angle and std.meta.eql(a.line, b.line) and a.stops.eql(b.stops));
    }
};

/// A circular gradient from the center of the shape to its farthest corner.
pub const RadialGradient = struct {
    stops: GradientStops = .{},
    /// SVG's geometry instead: an ellipse, its center and radii as
    /// fractions of the box painted (see `LinearGradient.line`).
    ellipse: ?Ellipse = null,

    pub const Ellipse = struct { center: [2]f32, radius: [2]f32 };

    pub fn eql(a: *const RadialGradient, b: *const RadialGradient) bool {
        return a == b or (std.meta.eql(a.ellipse, b.ellipse) and a.stops.eql(b.stops));
    }
};

/// What a shape is filled with. Gradients are referenced, not copied: a
/// brush is 16 bytes (8 on 32-bit targets) instead of carrying its stops.
pub const Brush = union(enum) {
    solid: Color,
    /// Must outlive the brush (and anything it is set on).
    linear_gradient: *const LinearGradient,
    /// Must outlive the brush (and anything it is set on).
    radial_gradient: *const RadialGradient,

    pub const transparent: Brush = .{ .solid = .transparent };

    pub fn color(c: Color) Brush {
        return .{ .solid = c };
    }

    /// A gradient known at compile time (so it lives as long as the
    /// program). Gradients made at run time use `.{ .linear_gradient = &g }`
    /// with a `g` that outlives the brush.
    pub fn linear(comptime angle: f32, comptime stops: []const GradientStop) Brush {
        const S = struct {
            const g: LinearGradient = .{ .angle = angle, .stops = .init(stops) };
        };
        return .{ .linear_gradient = &S.g };
    }

    /// A radial gradient known at compile time (see `linear`).
    pub fn radial(comptime stops: []const GradientStop) Brush {
        const S = struct {
            const g: RadialGradient = .{ .stops = .init(stops) };
        };
        return .{ .radial_gradient = &S.g };
    }

    pub fn isTransparent(b: Brush) bool {
        return switch (b) {
            .solid => |c| c.isTransparent(),
            .linear_gradient => |g| g.stops.allTransparent(),
            .radial_gradient => |g| g.stops.allTransparent(),
        };
    }

    pub fn eql(a: Brush, b: Brush) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .solid => |c| std.meta.eql(c, b.solid),
            .linear_gradient => |g| g.eql(b.linear_gradient),
            .radial_gradient => |g| g.eql(b.radial_gradient),
        };
    }

    /// Solid colors blend; anything else switches halfway (blending
    /// gradients needs somewhere to put the result: see `Blend`).
    pub fn interpolate(a: Brush, b: Brush, t: f32) Brush {
        if (a == .solid and b == .solid) return .{ .solid = interpolateColor(a.solid, b.solid, t) };
        return if (t < 0.5) a else b;
    }

    /// Storage for animating brushes (kept by the animation): gradients of
    /// the same kind and stop count blend stop by stop into it.
    pub const Blend = struct {
        /// The value returned by the last `interpolateWith`.
        out: Gradient = .{},
        /// A copy of an in-between value an animation starts from.
        from: Gradient = .{},

        const Gradient = struct {
            stops: [max_blended_stops]GradientStop = undefined,
            linear: LinearGradient = .{},
            radial: RadialGradient = .{},

            fn owns(g: *const Gradient, b: Brush) bool {
                return switch (b) {
                    .solid => false,
                    .linear_gradient => |p| p == &g.linear,
                    .radial_gradient => |p| p == &g.radial,
                };
            }

            /// Copies `b`'s gradient here and returns a brush pointing at it.
            fn copy(g: *Gradient, b: Brush) Brush {
                switch (b) {
                    .solid => return b,
                    .linear_gradient => |p| {
                        const n = @min(p.stops.items.len, max_blended_stops);
                        @memcpy(g.stops[0..n], p.stops.items[0..n]);
                        g.linear = .{ .angle = p.angle, .stops = .init(g.stops[0..n]), .line = p.line };
                        return .{ .linear_gradient = &g.linear };
                    },
                    .radial_gradient => |p| {
                        const n = @min(p.stops.items.len, max_blended_stops);
                        @memcpy(g.stops[0..n], p.stops.items[0..n]);
                        g.radial = .{ .stops = .init(g.stops[0..n]), .ellipse = p.ellipse };
                        return .{ .radial_gradient = &g.radial };
                    },
                }
            }
        };

        /// `v`, kept valid while `out` is overwritten: an animation that
        /// starts from an in-between value calls this.
        pub fn keep(self: *Blend, v: Brush) Brush {
            return if (self.out.owns(v)) self.from.copy(v) else v;
        }

        pub fn interpolate(self: *Blend, a: Brush, b: Brush, t: f32) Brush {
            if (t == 0) return a;
            if (t == 1) return b;
            const n = stopCount(a);
            if (std.meta.activeTag(a) != std.meta.activeTag(b) or n == 0 or n != stopCount(b) or n > max_blended_stops)
                return Brush.interpolate(a, b, t);
            const as = stopsOf(a);
            const bs = stopsOf(b);
            for (self.out.stops[0..n], as, bs) |*s, sa, sb| s.* = .{
                .color = interpolateColor(sa.color, sb.color, t),
                .position = sa.position + (sb.position - sa.position) * t,
            };
            const stops: GradientStops = .init(self.out.stops[0..n]);
            switch (a) {
                .linear_gradient => |ga| {
                    self.out.linear = .{ .angle = ga.angle + (b.linear_gradient.angle - ga.angle) * t, .stops = stops, .line = if (t < 0.5) ga.line else b.linear_gradient.line };
                    return .{ .linear_gradient = &self.out.linear };
                },
                .radial_gradient => |ga| {
                    self.out.radial = .{ .stops = stops, .ellipse = if (t < 0.5) ga.ellipse else b.radial_gradient.ellipse };
                    return .{ .radial_gradient = &self.out.radial };
                },
                .solid => unreachable,
            }
        }

        fn stopsOf(b: Brush) []const GradientStop {
            return switch (b) {
                .solid => &.{},
                .linear_gradient => |g| g.stops.items,
                .radial_gradient => |g| g.stops.items,
            };
        }

        fn stopCount(b: Brush) usize {
            return stopsOf(b).len;
        }
    };
};

/// The position of a stop given none (`placeStops` gives it one).
pub const unplaced = std.math.nan(f32);

/// Places stops as CSS does: those without a position (`unplaced`) go
/// evenly between their neighbors, the first at 0 and the last at 1 if
/// unplaced; and none goes before the one preceding it.
pub fn placeStops(stops: []GradientStop) void {
    if (stops.len == 0) return;
    if (std.math.isNan(stops[0].position)) stops[0].position = 0;
    if (std.math.isNan(stops[stops.len - 1].position)) stops[stops.len - 1].position = 1;
    var i: usize = 1;
    while (i < stops.len) : (i += 1) {
        const prev = stops[i - 1].position;
        if (!std.math.isNan(stops[i].position)) {
            stops[i].position = @max(stops[i].position, prev);
            continue;
        }
        var j = i + 1;
        while (std.math.isNan(stops[j].position)) j += 1;
        const end = @max(stops[j].position, prev);
        const steps: f32 = @floatFromInt(j - i + 1);
        for (i..j) |k| stops[k].position = prev + (end - prev) * @as(f32, @floatFromInt(k - i + 1)) / steps;
        i = j - 1;
    }
}

/// `stops` placed (see `placeStops`), for gradients known at compile time.
pub fn placedStops(comptime n: usize, stops: [n]GradientStop) [n]GradientStop {
    var s = stops;
    placeStops(&s);
    return s;
}

/// Storage for gradients made at run time with `n` stops (`.zge`'s
/// `@linear-gradient` with bound colors, positions or angle): two of each
/// kind, used in turn, so a brush returned stays valid until the
/// second-next call and compares with the previous one by content.
pub fn GradientBuffer(comptime n: usize) type {
    return struct {
        stops: [2][n]GradientStop = undefined,
        linear_gradients: [2]LinearGradient = .{ .{}, .{} },
        radial_gradients: [2]RadialGradient = .{ .{}, .{} },
        current: u1 = 0,

        const Self = @This();

        pub fn linear(self: *Self, angle: f32, stops: [n]GradientStop) Brush {
            self.current +%= 1;
            self.stops[self.current] = stops;
            placeStops(&self.stops[self.current]);
            self.linear_gradients[self.current] = .{ .angle = angle, .stops = .init(&self.stops[self.current]) };
            return .{ .linear_gradient = &self.linear_gradients[self.current] };
        }

        pub fn radial(self: *Self, stops: [n]GradientStop) Brush {
            self.current +%= 1;
            self.stops[self.current] = stops;
            placeStops(&self.stops[self.current]);
            self.radial_gradients[self.current] = .{ .stops = .init(&self.stops[self.current]) };
            return .{ .radial_gradient = &self.radial_gradients[self.current] };
        }
    };
}

/// Gradients with more stops do not blend when animated (they switch
/// halfway).
pub const max_blended_stops = 8;

fn interpolateColor(a: Color, b: Color, t: f32) Color {
    return interpolate(Color, a, b, t);
}

const testing = std.testing;

test "color construction and interpolation" {
    try testing.expectEqual(Color{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 0xff }, Color.rgb(0x123456));
    try testing.expectEqual(Color{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 0x78 }, Color.rgba(0x12345678));
    const mid = interpolate(Color, .black, .white, 0.5);
    try testing.expectEqual(Color{ .r = 128, .g = 128, .b = 128, .a = 255 }, mid);
    const brush = interpolate(Brush, .color(.black), .color(.white), 1);
    try testing.expect(brush.eql(.color(.white)));
}

test "premultiplication" {
    try testing.expectEqual(Rgba8{ .r = 128, .g = 0, .b = 64, .a = 128 }, Color.rgba(0xff0080_80).premultiplied());
    try testing.expectEqual(Color.rgba(0xff0080_80), (Rgba8{ .r = 128, .g = 0, .b = 64, .a = 128 }).unpremultiplied());
    try testing.expectEqual(@as(u8, 255), mul8(255, 255));
    try testing.expectEqual(@as(u8, 0), mul8(255, 0));
    try testing.expectEqual(@as(u8, 128), mul8(255, 128));
}

test placeStops {
    var s = [_]GradientStop{
        .{ .color = .black, .position = unplaced },
        .{ .color = .black, .position = unplaced },
        .{ .color = .black, .position = 0.6 },
        .{ .color = .black, .position = 0.2 },
        .{ .color = .black, .position = unplaced },
        .{ .color = .black, .position = unplaced },
    };
    placeStops(&s);
    const want = [_]f32{ 0, 0.3, 0.6, 0.6, 0.8, 1 };
    for (s, want) |stop, w| try testing.expectApproxEqAbs(w, stop.position, 1e-6);
    const even = comptime placedStops(3, .{ .{ .color = .black, .position = unplaced }, .{ .color = .black, .position = unplaced }, .{ .color = .black, .position = unplaced } });
    try testing.expectEqual(@as(f32, 0.5), even[1].position);
}

test GradientBuffer {
    var buf: GradientBuffer(2) = .{};
    const a = buf.linear(90, .{ .{ .color = .black, .position = 0 }, .{ .color = .white, .position = 1 } });
    const b = buf.linear(90, .{ .{ .color = .black, .position = 0 }, .{ .color = .white, .position = 1 } });
    try testing.expect(a.linear_gradient != b.linear_gradient);
    try testing.expect(a.eql(b));
    const c = buf.linear(90, .{ .{ .color = .black, .position = 0 }, .{ .color = .black, .position = 1 } });
    // The new value lands where `a` was; `b` is still as it was.
    try testing.expect(!b.eql(c));
    try testing.expectEqual(Color.white, b.linear_gradient.stops.items[1].color);
    const r = buf.radial(.{ .{ .color = .white, .position = 0 }, .{ .color = .black, .position = 1 } });
    try testing.expectEqual(Color.black, r.radial_gradient.stops.items[1].color);
}

test "gradient sampling and brush equality" {
    const g = Brush.linear(90, &.{ .{ .color = .black, .position = 0 }, .{ .color = .white, .position = 1 } });
    const stops = g.linear_gradient.stops;
    try testing.expectEqual(Rgba8{ .a = 255 }, stops.sample(-1));
    try testing.expectEqual(Rgba8{ .r = 128, .g = 128, .b = 128, .a = 255 }, stops.sample(0.5));
    try testing.expectEqual(Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 }, stops.sample(2));
    // Equal by content, not only by address.
    const same: LinearGradient = .{ .angle = 90, .stops = .init(&.{ .{ .color = .black, .position = 0 }, .{ .color = .white, .position = 1 } }) };
    try testing.expect(g.eql(.{ .linear_gradient = &same }));
    try testing.expect(!g.eql(Brush.linear(45, &.{ .{ .color = .black, .position = 0 }, .{ .color = .white, .position = 1 } })));
    try testing.expect(!g.eql(.color(.black)));
    try testing.expect(@sizeOf(Brush) <= 2 * @sizeOf(usize));

    // Without storage gradients switch halfway; with a Blend they blend.
    const other = Brush.linear(270, &.{ .{ .color = .white, .position = 0 }, .{ .color = .black, .position = 1 } });
    try testing.expect(interpolate(Brush, g, other, 0.4).eql(g));
    var blend: Brush.Blend = .{};
    const half = blend.interpolate(g, other, 0.5);
    try testing.expectEqual(@as(f32, 180), half.linear_gradient.angle);
    try testing.expectEqual(Color{ .r = 128, .g = 128, .b = 128, .a = 255 }, half.linear_gradient.stops.items[0].color);
    // A kept in-between value survives the next blend.
    const kept = blend.keep(half);
    _ = blend.interpolate(g, other, 0.9);
    try testing.expectEqual(@as(f32, 180), kept.linear_gradient.angle);
    // Different kinds switch halfway.
    try testing.expect(blend.interpolate(g, .color(.black), 0.4).eql(g));
}
