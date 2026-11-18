// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Makes the video example's clip (examples/video/demo.png): an animated
//! PNG drawn here (a snowy hill, falling snow, a bouncing ball), so it is
//! free to use and plays on every platform.
//!
//!     zig build video-demo

const std = @import("std");
const zigulee = @import("zigulee");
const Rgba8 = zigulee.core.Rgba8;

const width = 320;
const height = 180;
const frames = 48;
const delay_ms = 40;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const out = if (args.len > 1) args[1] else "examples/video/demo.png";

    const pixels = try arena.alloc([]Rgba8, frames);
    for (pixels, 0..) |*p, i| {
        p.* = try arena.alloc(Rgba8, width * height);
        draw(p.*, @as(f32, @floatFromInt(i)) / frames);
    }
    const consts = try arena.alloc([]const Rgba8, frames);
    for (consts, pixels) |*c, p| c.* = p;
    const bytes = try zigulee.core.video.apng.encode(arena, width, height, consts, delay_ms);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out, .data = bytes });
}

fn rgb(r: f32, g: f32, b: f32) Rgba8 {
    return .{ .r = @intFromFloat(std.math.clamp(r, 0, 1) * 255), .g = @intFromFloat(std.math.clamp(g, 0, 1) * 255), .b = @intFromFloat(std.math.clamp(b, 0, 1) * 255), .a = 255 };
}

/// One frame at time `t` (0 to 1: the loop).
fn draw(p: []Rgba8, t: f32) void {
    const tau = 2 * std.math.pi;
    // The ball: a bounce per loop, across and back.
    const bx = 160 + 110 * @sin(tau * t);
    const bounce = @abs(@sin(tau * t * 2));
    const by = 128 - 80 * bounce;
    const squash = 1 + 0.25 * (1 - std.math.clamp(bounce * 6, 0, 1));
    for (0..height) |yi| for (0..width) |xi| {
        const x: f32 = @floatFromInt(xi);
        const y: f32 = @floatFromInt(yi);
        // Sky, then a hill.
        var c = rgb(0.55 + 0.25 * y / height, 0.78 + 0.15 * y / height, 0.98);
        const hill = 140 + 12 * @sin(x / 40 + 1);
        if (y > hill) c = rgb(0.93, 0.96, 1.0);
        // The ball's shadow, then the ball.
        const sx = (x - bx) / (18 * (1.4 - 0.5 * bounce));
        const sy = (y - 141) / 4;
        if (sx * sx + sy * sy < 1) c = rgb(0.75, 0.82, 0.92);
        const dx = (x - bx) / (14 * squash);
        const dy = (y - by) * squash / 14;
        if (dx * dx + dy * dy < 1) {
            const shade = 0.75 + 0.25 * (-dx - dy) / 1.5;
            c = rgb(0.98 * shade, 0.45 * shade, 0.30 * shade);
        }
        p[yi * width + xi] = c;
    };
    // Snow: flakes falling one screen per loop (so it loops).
    var seed: u32 = 7;
    for (0..60) |_| {
        seed = seed *% 1664525 +% 1013904223;
        const fx: f32 = @floatFromInt((seed >> 8) % width);
        seed = seed *% 1664525 +% 1013904223;
        const fy0: f32 = @floatFromInt((seed >> 8) % height);
        const fy = @mod(fy0 + t * height, height);
        const drift = 3 * @sin(tau * (t + fy0 / height));
        const xi: usize = @intFromFloat(@mod(fx + drift, width));
        const yi: usize = @intFromFloat(fy);
        p[yi * width + xi] = rgb(1, 1, 1);
        if (xi + 1 < width) p[yi * width + xi + 1] = rgb(1, 1, 1);
    }
}
