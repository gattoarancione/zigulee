// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Runs the app defined in hello.zge: `zig build run-hello`.
//! `--screenshot out.png [count]` renders the first frame to a file instead.

const std = @import("std");
const zigulee = @import("zigulee");
/// zigulee-sdl3, or zigulee-macos with `-Dbackend=macos`.
const backend = @import("zigulee-backend");
const ui = @import("hello_ui");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const screenshot: ?[]const u8 = if (args.len > 2 and std.mem.eql(u8, args[1], "--screenshot")) args[2] else null;

    const app = try ui.Hello.create(gpa);
    defer app.destroy();
    // `--screenshot out.png 12` starts with a count of 12.
    if (args.len > 3) app.count.set(try std.fmt.parseInt(i32, args[3], 10));
    var font: zigulee.Font = try .init(@embedFile("fonts/inter/Inter-Regular.ttf"));
    app.window().default_font.set(&font);

    try backend.init();
    defer backend.deinit();
    const title = try gpa.dupeZ(u8, app.title.get());
    defer gpa.free(title);
    const window = try backend.Window.create(gpa, app.window(), .{
        .title = title,
        // Screenshots come from the software renderer's framebuffer.
        .renderer = if (screenshot != null) .software else .auto,
    });
    defer window.destroy();

    const path = screenshot orelse return window.run();
    for (0..10) |_| try window.step(10);
    const png = try zigulee.core.png.encode(gpa, window.pixel_width, window.pixel_height, window.framebuffer);
    defer gpa.free(png);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = png });
}
