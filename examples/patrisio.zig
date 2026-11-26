// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Patrisio's Snowy Adventure (`zig build run-patrisio`): a side-scrolling
//! platformer written entirely in patrisio.zge. This file only opens the
//! window.
//!
//!     patrisio [--screenshot out.png [frames [x]]]
//!
//! With --screenshot, saves a frame and exits: the title screen, or, given
//! a number of frames, the game after that many steps of running right
//! (jumping now and then), from the start or from `x` in the level.

const std = @import("std");
const zigulee = @import("zigulee");
/// zigulee-sdl3, or a native backend with `-Dbackend=...`.
const backend = @import("zigulee-backend");
const ui = @import("patrisio_ui");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const screenshot: ?[]const u8 = if (args.len > 2 and std.mem.eql(u8, args[1], "--screenshot")) args[2] else null;
    const frames: u32 = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 0;
    const from: ?f32 = if (args.len > 4) try std.fmt.parseFloat(f32, args[4]) else null;

    const regular: zigulee.Font = try .init(@embedFile("fonts/inter/Inter-Regular.ttf"));
    const bold: zigulee.Font = try .init(@embedFile("fonts/inter/Inter-Bold.ttf"));
    const app = try ui.PatrisioGame.create(gpa);
    defer app.destroy();
    try app.window().registerFont("Inter", 400, &regular);
    try app.window().registerFont("Inter", 700, &bold);

    try backend.init();
    defer backend.deinit();
    // Screenshots are silent.
    if (screenshot != null) zigulee.core.audio.mixer().setOutput(null);
    const title = try gpa.dupeZ(u8, app.title.get());
    defer gpa.free(title);
    const window = try backend.Window.create(gpa, app.window(), .{
        .title = title,
        .resizable = false,
        // Screenshots come from the software renderer's framebuffer.
        .renderer = if (screenshot != null) .software else .auto,
    });
    defer window.destroy();

    const path = screenshot orelse return window.run();
    if (frames > 0) {
        app.invoke_start();
        if (from) |x| {
            app.px.set(x);
            app.camera.set(@max(0, x - 200));
        }
        app.right.set(true);
        for (0..frames) |f| {
            // A jump every two seconds.
            if (f % 120 == 30) app.jump_wanted.set(8);
            app.jump_held.set(f % 120 >= 30 and f % 120 < 45);
            app.invoke_tick();
            zigulee.runChangeHandlers();
        }
    }
    for (0..5) |_| try window.step(10);
    const png = try zigulee.core.png.encode(gpa, window.pixel_width, window.pixel_height, window.framebuffer);
    defer gpa.free(png);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = png });
}
