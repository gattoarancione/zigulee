// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Runs a frame of the GPU renderer on the CPU, as a GPU would: each
//! quad's pixels (centers inside it) shaded by shader.zig's Zig fragment
//! shader and blended premultiplied over the target. For tests: frames
//! checked without a GPU, against the software renderer.

const std = @import("std");
const core = @import("../../core/core.zig");
const Rgba8 = core.Rgba8;
const batch = @import("batch.zig");
const shader = @import("shader.zig");
const software = @import("../software/software.zig");

/// Draws `frame` over `pixels` (`frame.width` x `frame.height`), the
/// previous frame: as the GL executor, the area it redraws is cleared first.
pub fn execute(frame: *const batch.Frame, pixels: []Rgba8) void {
    for (frame.region.slice()) |r| {
        const x0: usize = @intFromFloat(@max(0, r.x));
        const y0: usize = @intFromFloat(@max(0, r.y));
        const x1: usize = @intFromFloat(@min(@as(f32, @floatFromInt(frame.width)), r.right()));
        const y1: usize = @intFromFloat(@min(@as(f32, @floatFromInt(frame.height)), r.bottom()));
        for (y0..y1) |y| @memset(pixels[y * frame.width ..][x0..x1], .transparent);
    }
    for (frame.draws) |draw| {
        var i = draw.first;
        while (i < draw.first + draw.count) : (i += 6) quad(frame, draw, i, frame.width, frame.height, pixels, 0, 0, frame.width, Rgba8, blendRgba8);
    }
}

/// Draws `frame`'s quads onto `canvas` (a software renderer's: any pixel
/// format, any part of the window), over what is there.
pub fn drawOnto(frame: *const batch.Frame, comptime P: type, canvas: software.Canvas(P)) void {
    for (frame.draws) |draw| {
        var i = draw.first;
        while (i < draw.first + draw.count) : (i += 6) quad(frame, draw, i, canvas.width, canvas.height, canvas.pixels, canvas.origin_x, canvas.origin_y, canvas.stride, P, software.blend);
    }
}

fn blendRgba8(comptime _: type, dst: *Rgba8, c: Rgba8) void {
    const inv: u16 = 255 - c.a;
    dst.* = .{
        .r = @intCast(@min(255, @as(u16, c.r) + (@as(u16, dst.r) * inv + 127) / 255)),
        .g = @intCast(@min(255, @as(u16, c.g) + (@as(u16, dst.g) * inv + 127) / 255)),
        .b = @intCast(@min(255, @as(u16, c.b) + (@as(u16, dst.b) * inv + 127) / 255)),
        .a = @intCast(@min(255, @as(u16, c.a) + (@as(u16, dst.a) * inv + 127) / 255)),
    };
}

/// One quad (indices `i`..`i + 6`: corners 0, 1, 2 and 0, 2, 3): the
/// pixels whose centers are inside (a parallelogram: rotated or not),
/// shaded with the attributes interpolated. Any other shape (a cell of a
/// mapped image) is drawn as its two triangles, as a GPU would.
fn quad(frame: *const batch.Frame, draw: batch.Draw, i: u32, width: u32, height: u32, pixels: anytype, ox: i32, oy: i32, stride: u32, comptime P: type, comptime put: anytype) void {
    const v0 = &frame.vertices[frame.indices[i]];
    const v1 = &frame.vertices[frame.indices[i + 1]];
    const v3 = &frame.vertices[frame.indices[i + 5]];
    const v2_ = &frame.vertices[frame.indices[i + 2]];
    if (@abs(v1.pos[0] + v3.pos[0] - v0.pos[0] - v2_.pos[0]) > 1e-3 or @abs(v1.pos[1] + v3.pos[1] - v0.pos[1] - v2_.pos[1]) > 1e-3) {
        triangle(frame, draw, .{ v0, v1, v2_ }, width, height, pixels, ox, oy, stride, P, put);
        triangle(frame, draw, .{ v0, v2_, v3 }, width, height, pixels, ox, oy, stride, P, put);
        return;
    }
    // Corner 0, and the edges to corners 1 and 3.
    const ex = [2]f32{ v1.pos[0] - v0.pos[0], v1.pos[1] - v0.pos[1] };
    const ey = [2]f32{ v3.pos[0] - v0.pos[0], v3.pos[1] - v0.pos[1] };
    const det = ex[0] * ey[1] - ex[1] * ey[0];
    if (det == 0) return;
    const v2 = &frame.vertices[frame.indices[i + 2]];
    const xs = [4]f32{ v0.pos[0], v1.pos[0], v2.pos[0], v3.pos[0] };
    const ys = [4]f32{ v0.pos[1], v1.pos[1], v2.pos[1], v3.pos[1] };
    const min_x = @min(@min(xs[0], xs[1]), @min(xs[2], xs[3]));
    const max_x = @max(@max(xs[0], xs[1]), @max(xs[2], xs[3]));
    const min_y = @min(@min(ys[0], ys[1]), @min(ys[2], ys[3]));
    const max_y = @max(@max(ys[0], ys[1]), @max(ys[2], ys[3]));
    const fx0: f32 = @floatFromInt(ox);
    const fy0: f32 = @floatFromInt(oy);
    const px0: i32 = @intFromFloat(@max(fx0, @ceil(min_x - 0.5)));
    const py0: i32 = @intFromFloat(@max(fy0, @ceil(min_y - 0.5)));
    const px1: i32 = @intFromFloat(@min(fx0 + @as(f32, @floatFromInt(width)), @ceil(max_x - 0.5)));
    const py1: i32 = @intFromFloat(@min(fy0 + @as(f32, @floatFromInt(height)), @ceil(max_y - 0.5)));
    var y = py0;
    while (y < py1) : (y += 1) {
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        var x = px0;
        while (x < px1) : (x += 1) {
            const cx = @as(f32, @floatFromInt(x)) + 0.5;
            // Where the center is along the edges: (s, t) in [0, 1)^2.
            const dx = cx - v0.pos[0];
            const dy = cy - v0.pos[1];
            const s = (dx * ey[1] - dy * ey[0]) / det;
            const t = (ex[0] * dy - ex[1] * dx) / det;
            if (s < 0 or s >= 1 or t < 0 or t >= 1) continue;
            const uv: [2]f32 = .{ v0.uv[0] + (v1.uv[0] - v0.uv[0]) * s + (v3.uv[0] - v0.uv[0]) * t, v0.uv[1] + (v1.uv[1] - v0.uv[1]) * s + (v3.uv[1] - v0.uv[1]) * t };
            const local: [2]f32 = .{ v0.local[0] + (v1.local[0] - v0.local[0]) * s + (v3.local[0] - v0.local[0]) * t, v0.local[1] + (v1.local[1] - v0.local[1]) * s + (v3.local[1] - v0.local[1]) * t };
            const c = shader.shade(frame, draw, v0, .{ cx, cy }, local, uv) orelse continue;
            const row: usize = @intCast(y - oy);
            const col: usize = @intCast(x - ox);
            put(P, &pixels[row * stride + col], .{ .r = channel(c[0]), .g = channel(c[1]), .b = channel(c[2]), .a = channel(c[3]) });
        }
    }
}

/// A triangle of a quad: the pixels whose centers are inside, those on an
/// edge only on one side of it (a top-left rule: an edge two triangles
/// share is drawn once), shaded with the attributes interpolated.
fn triangle(frame: *const batch.Frame, draw: batch.Draw, corners: [3]*const batch.Vertex, width: u32, height: u32, pixels: anytype, ox: i32, oy: i32, stride: u32, comptime P: type, comptime put: anytype) void {
    var v = corners;
    const edge = struct {
        fn f(a: [2]f32, b: [2]f32, p: [2]f32) f32 {
            return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
        }
    }.f;
    var area = edge(v[0].pos, v[1].pos, v[2].pos);
    if (area == 0) return;
    // The same turning way for all: a shared edge goes opposite ways.
    if (area < 0) {
        std.mem.swap(*const batch.Vertex, &v[1], &v[2]);
        area = -area;
    }
    // Which edges own their points: those going down, or flat going left.
    var owns: [3]bool = undefined;
    for (0..3) |k| {
        const a = v[(k + 1) % 3].pos;
        const b = v[(k + 2) % 3].pos;
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        owns[k] = dy > 0 or (dy == 0 and dx < 0);
    }
    const min_x = @min(v[0].pos[0], @min(v[1].pos[0], v[2].pos[0]));
    const max_x = @max(v[0].pos[0], @max(v[1].pos[0], v[2].pos[0]));
    const min_y = @min(v[0].pos[1], @min(v[1].pos[1], v[2].pos[1]));
    const max_y = @max(v[0].pos[1], @max(v[1].pos[1], v[2].pos[1]));
    const fx0: f32 = @floatFromInt(ox);
    const fy0: f32 = @floatFromInt(oy);
    const px0: i32 = @intFromFloat(@max(fx0, @floor(min_x - 0.5)));
    const py0: i32 = @intFromFloat(@max(fy0, @floor(min_y - 0.5)));
    const px1: i32 = @intFromFloat(@min(fx0 + @as(f32, @floatFromInt(width)), @ceil(max_x + 0.5)));
    const py1: i32 = @intFromFloat(@min(fy0 + @as(f32, @floatFromInt(height)), @ceil(max_y + 0.5)));
    var y = py0;
    while (y < py1) : (y += 1) {
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        var x = px0;
        while (x < px1) : (x += 1) {
            const c = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, cy };
            // Weights of the corners: from the opposite edges.
            var w: [3]f32 = undefined;
            var inside = true;
            for (0..3) |k| {
                w[k] = edge(v[(k + 1) % 3].pos, v[(k + 2) % 3].pos, c);
                if (w[k] < 0 or (w[k] == 0 and !owns[k])) inside = false;
            }
            if (!inside) continue;
            var uv: [2]f32 = .{ 0, 0 };
            var local: [2]f32 = .{ 0, 0 };
            for (0..3) |k| for (0..2) |j| {
                uv[j] += v[k].uv[j] * w[k] / area;
                local[j] += v[k].local[j] * w[k] / area;
            };
            const color = shader.shade(frame, draw, corners[0], c, local, uv) orelse continue;
            const row: usize = @intCast(y - oy);
            const col: usize = @intCast(x - ox);
            put(P, &pixels[row * stride + col], .{ .r = channel(color[0]), .g = channel(color[1]), .b = channel(color[2]), .a = channel(color[3]) });
        }
    }
}

fn channel(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}
