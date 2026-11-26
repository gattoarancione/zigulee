// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Runs the app defined in video.zge: `zig build run-video`, or
//! `zig build run-video -- movie.mp4` to play a file.
//!
//!     video [file] [--screenshot out.png [frames]]
//!
//! With --screenshot, saves a frame and exits.

const std = @import("std");
const zigulee = @import("zigulee");
/// zigulee-sdl3, or the native backend chosen with `-Dbackend=...`.
const backend = @import("zigulee-backend");
const ui = @import("video_ui");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var screenshot: ?[]const u8 = null;
    var frames: usize = 10;
    var file: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--screenshot") and i + 1 < args.len) {
            screenshot = args[i + 1];
            i += 1;
            if (i + 1 < args.len) if (std.fmt.parseInt(usize, args[i + 1], 10)) |n| {
                frames = n;
                i += 1;
            } else |_| {};
        } else file = args[i];
    }

    const app = try ui.VideoDemo.create(gpa);
    defer app.destroy();
    app.file.set(file);
    const regular: zigulee.Font = try .init(@embedFile("fonts/inter/Inter-Regular.ttf"));
    const bold: zigulee.Font = try .init(@embedFile("fonts/inter/Inter-Bold.ttf"));
    app.window().default_font.set(&regular);
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
        .renderer = if (screenshot != null) .software else .auto,
    });
    defer window.destroy();

    const path = screenshot orelse return window.run();
    for (0..frames) |_| try window.step(20);
    const png = try zigulee.core.png.encode(gpa, window.pixel_width, window.pixel_height, window.framebuffer);
    defer gpa.free(png);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = png });
}
