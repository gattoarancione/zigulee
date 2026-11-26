// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Rows of pixels blended several at a time: with the CPU's vector unit
//! (NEON on ARM, SSE/AVX on x86) where it has one, else one by one. Each
//! gives exactly the pixels `blend` gives pixel by pixel.

const std = @import("std");
const builtin = @import("builtin");
const graphics = @import("../../core/graphics.zig");
const Rgba8 = graphics.Rgba8;
const mul8 = graphics.mul8;
const software = @import("software.zig");
const Rgb565 = software.Rgb565;
const blend = software.blend;

/// Pixels per step; null where vectors would not pay (no vector unit:
/// microcontrollers). The pixels are taken apart as little-endian words.
const lanes: ?comptime_int = if (std.simd.suggestVectorLength(u16) != null and builtin.cpu.arch.endian() == .little) 8 else null;

/// Whether the renderer blends rows here. Without a vector unit it keeps
/// to its pixel-by-pixel loops: microcontrollers, whose flash and RAM are
/// counted, get no code they would not run faster.
pub const enabled = lanes != null;

/// Whether pixels that blending would leave as they are (transparent) or
/// replace (opaque) are looked for, n at a time, to skip the work. Not on
/// 32-bit ARM: the answer goes from NEON to the CPU's registers, which
/// waits for NEON to finish (on a Cortex-A7, longer than blending them).
/// The same pixels either way.
const skips = !arm_neon;

/// `src` (premultiplied), scaled by `opacity`, over `dst`.
pub fn blendRow(comptime P: type, dst: []P, src: []const Rgba8, opacity: u8) void {
    std.debug.assert(dst.len == src.len);
    var i: usize = 0;
    if (lanes) |n| while (i + n <= dst.len) : (i += n) {
        if (P == Rgba8) {
            var s: Px(n) = @bitCast(src[i..][0..n].*);
            if (opacity != 255) s = mul8V(4 * n, s, @splat(opacity));
            storeRgba(dst[i..][0..n], s, .{ .empty = skips, .full = skips });
            continue;
        }
        var s = loadPlanes(src[i..][0..n]);
        if (opacity != 255) inline for (channels) |ch| {
            @field(s, ch) = mul8V(n, @field(s, ch), @splat(opacity));
        };
        store(P, dst[i..][0..n], s, .{ .empty = skips, .full = skips });
    };
    for (dst[i..], src[i..]) |*d, c| blend(P, d, c.scale(opacity));
}

/// Opaque `src` over `dst`: copied (as `blend` would replace them).
pub fn copyRow(comptime P: type, dst: []P, src: []const Rgba8) void {
    std.debug.assert(dst.len == src.len);
    switch (P) {
        Rgba8 => @memcpy(dst, src),
        Rgb565 => {
            var i: usize = 0;
            if (lanes) |n| while (i + n <= dst.len) : (i += n) store(P, dst[i..][0..n], loadPlanes(src[i..][0..n]), .{ .known_full = true });
            for (dst[i..], src[i..]) |*d, c| d.* = .fromRgb8(c.r, c.g, c.b);
        },
        else => @compileError("unsupported pixel type " ++ @typeName(P)),
    }
}

/// `color` (premultiplied) over `dst`, each pixel scaled by its coverage.
pub fn blendCoverage(comptime P: type, dst: []P, color: Rgba8, coverage: []const u8) void {
    std.debug.assert(dst.len == coverage.len);
    var i: usize = 0;
    if (lanes) |n| {
        const c = splatPlanes(n, color);
        const cp = splatPixel(n, color);
        while (i + n <= dst.len) : (i += n) {
            const k: @Vector(n, u8) = coverage[i..][0..n].*;
            if (skips and @reduce(.Max, k) == 0) continue;
            if (P == Rgba8) {
                storeRgba(dst[i..][0..n], mul8V(4 * n, cp, spread(n, k)), .{});
                continue;
            }
            var s: Planes(n) = undefined;
            inline for (channels) |ch| @field(s, ch) = mul8V(n, @field(c, ch), k);
            store(P, dst[i..][0..n], s, .{});
        }
    }
    for (dst[i..], coverage[i..]) |*d, k| if (k != 0) blend(P, d, color.scale(k));
}

/// `color` (premultiplied) over all of `dst`.
pub fn blendColor(comptime P: type, dst: []P, color: Rgba8) void {
    var i: usize = 0;
    if (lanes) |n| {
        if (color.r | color.g | color.b | color.a == 0) {
            i = dst.len - dst.len % n;
        } else if (P == Rgba8) {
            const c = splatPixel(n, color);
            while (i + n <= dst.len) : (i += n) storeRgba(dst[i..][0..n], c, .{});
        } else {
            const c = splatPlanes(n, color);
            while (i + n <= dst.len) : (i += n) store(P, dst[i..][0..n], c, .{});
        }
    }
    for (dst[i..]) |*d| blend(P, d, color);
}

/// Coverage in [0, 1] (a path's mask), times `opacity` (0 to 1), as
/// `alpha8` gives it: into `out`.
pub fn coverage8(out: []u8, coverage: []const f32, opacity: f32) void {
    std.debug.assert(out.len == coverage.len);
    var i: usize = 0;
    if (lanes) |n| while (i + n <= out.len) : (i += n) {
        const F = @Vector(n, f32);
        const v = @as(F, coverage[i..][0..n].*) * @as(F, @splat(opacity));
        // Clamped and rounded with compares and conversions: ARM's vectors
        // have no rounding (`@round` would call `roundf` lane by lane), and
        // `@min`/`@max` keep to IEEE's NaN rules the same way.
        const zero: F = @splat(0);
        const one: F = @splat(1);
        const x = @select(f32, v > zero, @select(f32, v < one, v, one), zero) * @as(F, @splat(255));
        const whole: @Vector(n, u32) = @intFromFloat(x);
        const up = x - @as(F, @floatFromInt(whole)) >= @as(F, @splat(0.5));
        const bytes: @Vector(n, u8) = @truncate(whole + @select(u32, up, @as(@Vector(n, u32), @splat(1)), @as(@Vector(n, u32), @splat(0))));
        out[i..][0..n].* = bytes;
    };
    for (out[i..], coverage[i..]) |*o, c| o.* = @intFromFloat(@round(std.math.clamp(c * opacity, 0, 1) * 255));
}

/// `mul8` coverage by `opacity`, in place.
pub fn scaleCoverage(coverage: []u8, opacity: u8) void {
    if (opacity == 255) return;
    var i: usize = 0;
    if (lanes) |n| while (i + n <= coverage.len) : (i += n) {
        const v: @Vector(n, u8) = coverage[i..][0..n].*;
        coverage[i..][0..n].* = mul8V(n, v, @splat(opacity));
    };
    for (coverage[i..]) |*c| c.* = mul8(c.*, opacity);
}

// ---- RGBA: n pixels as 4n bytes (r, g, b, a, r, ...) ----
//
// Blending into RGBA is bound by reading and writing the pixels, not by
// computing them: kept as they are in memory, it does the least (taking
// them apart into channels costs more, on a Cortex-A7 as on a desktop).

fn Px(comptime n: comptime_int) type {
    return @Vector(4 * n, u8);
}

fn splatPixel(comptime n: comptime_int, c: Rgba8) Px(n) {
    return @bitCast(@as([n]Rgba8, @splat(c)));
}

/// Each of `k` four times: a factor for each byte of n pixels.
fn spread(comptime n: comptime_int, k: @Vector(n, u8)) Px(n) {
    const mask = comptime blk: {
        var m: [4 * n]i32 = undefined;
        for (&m, 0..) |*e, j| e.* = j / 4;
        break :blk m;
    };
    return @shuffle(u8, k, undefined, mask);
}

/// Each pixel's alpha in its four bytes.
fn alphas(comptime n: comptime_int, p: Px(n)) Px(n) {
    const mask = comptime blk: {
        var m: [4 * n]i32 = undefined;
        for (&m, 0..) |*e, j| e.* = j / 4 * 4 + 3;
        break :blk m;
    };
    return @shuffle(u8, p, undefined, mask);
}

/// Blends n pixels `s` (bytes) over `dst`.
fn storeRgba(dst: anytype, s: Px(dst.len), comptime checks: Checks) void {
    const n = dst.len;
    if (checks.empty and @reduce(.Max, s) == 0) return;
    const a = alphas(n, s);
    if (checks.full and @reduce(.Min, a) == 255) {
        dst.* = @bitCast(s);
        return;
    }
    const d: Px(n) = @bitCast(dst.*);
    dst.* = @bitCast(s +| mul8V(4 * n, d, @as(Px(n), @splat(255)) - a));
}

// ---- RGB565: n pixels as four planes (reds, greens, blues, alphas) ----
//
// As ARM's NEON code is written (pixman's): eight pixels' channels each in
// a register, the four side by side. Unpacking and packing 5-6-5 pixels
// is computing, which this does with the least work (on a Cortex-A7, a
// third faster than with the pixels' bytes as they come).

fn Planes(comptime n: comptime_int) type {
    return struct { r: @Vector(n, u8), g: @Vector(n, u8), b: @Vector(n, u8), a: @Vector(n, u8) };
}

const channels = .{ "r", "g", "b", "a" };

/// The pixels' bytes taken apart by channel (a single `vld4` on ARM).
fn split(comptime n: comptime_int, p: @Vector(4 * n, u8)) Planes(n) {
    var out: Planes(n) = undefined;
    inline for (channels, 0..) |ch, k| {
        const mask = comptime blk: {
            var m: [n]i32 = undefined;
            for (&m, 0..) |*e, j| e.* = j * 4 + k;
            break :blk m;
        };
        @field(out, ch) = @shuffle(u8, p, undefined, mask);
    }
    return out;
}

/// The channels put back together into pixels (`vst4` on ARM).
fn join(comptime n: comptime_int, c: Planes(n)) @Vector(4 * n, u8) {
    const halves = comptime blk: {
        var m: [2 * n]i32 = undefined;
        for (0..n) |j| {
            m[j] = j;
            m[n + j] = ~@as(i32, @intCast(j));
        }
        break :blk m;
    };
    const rg = @shuffle(u8, c.r, c.g, halves);
    const ba = @shuffle(u8, c.b, c.a, halves);
    const mask = comptime blk: {
        var m: [4 * n]i32 = undefined;
        for (0..n) |j| {
            m[4 * j] = j;
            m[4 * j + 1] = n + j;
            m[4 * j + 2] = ~@as(i32, @intCast(j));
            m[4 * j + 3] = ~@as(i32, @intCast(n + j));
        }
        break :blk m;
    };
    return @shuffle(u8, rg, ba, mask);
}

fn loadPlanes(src: anytype) Planes(src.len) {
    return split(src.len, @bitCast(src.*));
}

fn splatPlanes(comptime n: comptime_int, c: Rgba8) Planes(n) {
    // Each channel through a local: Zig 0.16's own aarch64 code (Debug
    // builds on ARM Macs) splats `c.r` for `@splat(c.g)`.
    const r: u8 = c.r;
    const g: u8 = c.g;
    const b: u8 = c.b;
    const a: u8 = c.a;
    return .{ .r = @splat(r), .g = @splat(g), .b = @splat(b), .a = @splat(a) };
}

/// 32-bit ARM with NEON (`mul8V` in three instructions per eight lanes).
const arm_neon = builtin.cpu.arch == .arm and std.Target.arm.featureSetHas(builtin.cpu.features, .neon);

/// `mul8`, lane by lane: (x + 128 + ((x + 128) >> 8)) >> 8 of the product
/// x. Exact: the sums stay within 16 bits.
fn mul8V(comptime len: comptime_int, a: @Vector(len, u8), b: @Vector(len, u8)) @Vector(len, u8) {
    if (arm_neon and len % 16 == 0) {
        // As NEON computes it: `vmull` (the products), `vrshr` (the
        // rounded high bytes), `vraddhn` (their rounded sum's high
        // bytes), two halves side by side as the in-order core waits for
        // each result. LLVM's own takes five per half, widening first.
        const Q = @Vector(16, u8);
        const as: [len / 16]Q = @bitCast(a);
        const bs: [len / 16]Q = @bitCast(b);
        var out: [len / 16]Q = undefined;
        for (&out, as, bs) |*o, x, y| o.* = asm (
            \\vmull.u8 q8, %[x:e], %[y:e]
            \\vmull.u8 q9, %[x:f], %[y:f]
            \\vrshr.u16 q10, q8, #8
            \\vrshr.u16 q11, q9, #8
            \\vraddhn.u16 %[o:e], q8, q10
            \\vraddhn.u16 %[o:f], q9, q11
            : [o] "=w" (-> Q),
            : [x] "w" (x),
              [y] "w" (y),
            : .{ .d16 = true, .d17 = true, .d18 = true, .d19 = true, .d20 = true, .d21 = true, .d22 = true, .d23 = true });
        return @bitCast(out);
    }
    const W = @Vector(len, u16);
    const x = @as(W, a) * @as(W, b);
    const t = (x + @as(W, @splat(128))) >> @splat(8);
    return @truncate((x + t + @as(W, @splat(128))) >> @splat(8));
}

/// What `store` checks of the pixels it blends.
const Checks = struct {
    /// Skip them if all are transparent (`blend` leaves those).
    empty: bool = false,
    /// Write them without reading `dst` if all are opaque.
    full: bool = false,
    /// They are all opaque.
    known_full: bool = false,
};

/// Blends n pixels `s` (planes) over `dst` (RGB565; RGBA for completeness).
fn store(comptime P: type, dst: anytype, s: Planes(dst.len), comptime checks: Checks) void {
    const n = dst.len;
    if (checks.empty and @reduce(.Max, s.r | s.g | s.b | s.a) == 0) return;
    const full = checks.known_full or (checks.full and @reduce(.Min, s.a) == 255);
    const inv = @as(@Vector(n, u8), @splat(255)) - s.a;
    switch (P) {
        Rgba8 => {
            if (full) {
                dst.* = @bitCast(join(n, s));
                return;
            }
            const d = split(n, @bitCast(dst.*));
            var out: Planes(n) = undefined;
            inline for (channels) |ch| @field(out, ch) = @field(s, ch) +| mul8V(n, @field(d, ch), inv);
            dst.* = @bitCast(join(n, out));
        },
        Rgb565 => {
            // As `blend`: the pixels widened to 8 bits a channel, blended
            // (their alpha unused), narrowed again.
            const W = @Vector(n, u16);
            var out = s;
            if (!full) {
                const d: W = @bitCast(dst.*);
                const r: W = (d >> @splat(11)) & @as(W, @splat(0x1f));
                const g: W = (d >> @splat(5)) & @as(W, @splat(0x3f));
                const b: W = d & @as(W, @splat(0x1f));
                out.r +|= mul8V(n, @truncate((r << @splat(3)) | (r >> @splat(2))), inv);
                out.g +|= mul8V(n, @truncate((g << @splat(2)) | (g >> @splat(4))), inv);
                out.b +|= mul8V(n, @truncate((b << @splat(3)) | (b >> @splat(2))), inv);
            }
            const ro: W = out.r;
            const go: W = out.g;
            const bo: W = out.b;
            dst.* = @bitCast(((ro >> @splat(3)) << @splat(11)) | ((go >> @splat(2)) << @splat(5)) | (bo >> @splat(3)));
        },
        else => @compileError("unsupported pixel type " ++ @typeName(P)),
    }
}

const testing = std.testing;

/// Every way to blend a row against `blend`, pixel by pixel.
fn checkRows(comptime P: type, dst0: []const P, src: []const Rgba8, coverage: []const u8, color: Rgba8) !void {
    var a: [37]P = undefined;
    var b: [37]P = undefined;
    for ([_]u8{ 255, 200, 1, 0 }) |opacity| {
        @memcpy(&a, dst0);
        @memcpy(&b, dst0);
        blendRow(P, &a, src, opacity);
        for (&b, src) |*d, c| blend(P, d, c.scale(opacity));
        try testing.expectEqualSlices(P, &b, &a);
    }
    var solid: [37]Rgba8 = undefined;
    for (&solid, src) |*o, c| o.* = .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 };
    @memcpy(&a, dst0);
    @memcpy(&b, dst0);
    copyRow(P, &a, &solid);
    for (&b, solid) |*d, c| blend(P, d, c);
    try testing.expectEqualSlices(P, &b, &a);
    @memcpy(&a, dst0);
    @memcpy(&b, dst0);
    blendCoverage(P, &a, color, coverage);
    for (&b, coverage) |*d, k| blend(P, d, color.scale(k));
    try testing.expectEqualSlices(P, &b, &a);
    @memcpy(&a, dst0);
    @memcpy(&b, dst0);
    blendColor(P, &a, color);
    for (&b) |*d| blend(P, d, color);
    try testing.expectEqualSlices(P, &b, &a);
}

test "rows blended at once: the pixels blended one by one" {
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    for (0..200) |_| {
        var src: [37]Rgba8 = undefined;
        for (&src) |*p| p.* = (Rgba8{ .r = r.int(u8), .g = r.int(u8), .b = r.int(u8), .a = 255 }).scale(if (r.boolean()) 255 else r.int(u8));
        var dst: [37]Rgba8 = undefined;
        for (&dst) |*p| p.* = (Rgba8{ .r = r.int(u8), .g = r.int(u8), .b = r.int(u8), .a = 255 }).scale(r.int(u8));
        var dst565: [37]Rgb565 = undefined;
        for (&dst565) |*p| p.* = @bitCast(r.int(u16));
        var coverage: [37]u8 = undefined;
        for (&coverage) |*k| k.* = if (r.int(u2) == 0) 0 else r.int(u8);
        const color = src[0];
        try checkRows(Rgba8, &dst, &src, &coverage, color);
        try checkRows(Rgb565, &dst565, &src, &coverage, color);

        var cf: [37]f32 = undefined;
        for (&cf) |*c| c.* = r.float(f32) * 1.2 - 0.1;
        var a: [37]u8 = undefined;
        coverage8(&a, &cf, 0.7);
        for (a, cf) |got, c| try testing.expectEqual(@as(u8, @intFromFloat(@round(std.math.clamp(c * 0.7, 0, 1) * 255))), got);
        var k = coverage;
        scaleCoverage(&k, 77);
        for (k, coverage) |got, c| try testing.expectEqual(mul8(c, 77), got);
    }
}

test "pixels not premultiplied: saturated, not overflowing, as one by one" {
    var prng: std.Random.DefaultPrng = .init(11);
    const r = prng.random();
    for (0..50) |_| {
        // Straight alpha: channels above their alpha.
        var src: [37]Rgba8 = undefined;
        for (&src) |*p| p.* = .{ .r = r.int(u8) | 0x80, .g = r.int(u8), .b = r.int(u8) | 0x80, .a = r.int(u8) >> 1 };
        var dst: [37]Rgba8 = undefined;
        for (&dst) |*p| p.* = .{ .r = r.int(u8), .g = r.int(u8), .b = r.int(u8), .a = 255 };
        var dst565: [37]Rgb565 = undefined;
        for (&dst565) |*p| p.* = @bitCast(r.int(u16));
        var coverage: [37]u8 = undefined;
        for (&coverage) |*k| k.* = r.int(u8);
        try checkRows(Rgba8, &dst, &src, &coverage, src[0]);
        try checkRows(Rgb565, &dst565, &src, &coverage, src[0]);
    }
    var white: [8]Rgba8 = @splat(.{ .r = 255, .g = 255, .b = 255, .a = 255 });
    blendRow(Rgba8, &white, &@as([8]Rgba8, @splat(.{ .r = 255, .g = 0, .b = 255, .a = 128 })), 255);
    try testing.expectEqual(Rgba8{ .r = 255, .g = 127, .b = 255, .a = 255 }, white[0]);
}
