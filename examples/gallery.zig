// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Runs the gallery defined in gallery.zge: `zig build run-gallery`.
//!
//!     gallery [--dark] [--tab N] [--screenshot out.png]
//!
//! With --screenshot, renders the first frames, saves the framebuffer
//! (physical pixels) and exits.

const std = @import("std");
const zigulee = @import("zigulee");
/// zigulee-sdl3, or zigulee-macos with `-Dbackend=macos`.
const backend = @import("zigulee-backend");
const ui = @import("gallery_ui");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var screenshot: ?[]const u8 = null;
    var dark = false;
    var tab: i32 = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dark")) dark = true;
        if (std.mem.eql(u8, args[i], "--tab") and i + 1 < args.len) {
            i += 1;
            tab = try std.fmt.parseInt(i32, args[i], 10);
        }
        if (std.mem.eql(u8, args[i], "--screenshot") and i + 1 < args.len) {
            i += 1;
            screenshot = args[i];
        }
    }

    const regular: zigulee.Font = try .init(@embedFile("fonts/inter/Inter-Regular.ttf"));
    const bold: zigulee.Font = try .init(@embedFile("fonts/inter/Inter-Bold.ttf"));
    const mono: zigulee.Font = try .init(@embedFile("fonts/jetbrains-mono/JetBrainsMono-Regular.ttf"));

    const app = try ui.Gallery.create(gpa);
    defer app.destroy();
    const window = app.window();
    try window.registerFont("Inter", 400, &regular);
    try window.registerFont("Inter", 700, &bold);
    try window.registerFont("JetBrains Mono", 400, &mono);
    app.dark.set(dark);
    app.tab.set(tab);

    try backend.init();
    defer backend.deinit();
    const title = try gpa.dupeZ(u8, app.title.get());
    defer gpa.free(title);
    const sdl_window = try backend.Window.create(gpa, window, .{
        .title = title,
        // Screenshots come from the software renderer's framebuffer.
        .renderer = if (screenshot != null) .software else .auto,
    });
    defer sdl_window.destroy();

    const path = screenshot orelse return sdl_window.run();
    // Let the first frame (and any start-up animation) settle.
    for (0..30) |_| try sdl_window.step(20);
    const png = try zigulee.core.png.encode(gpa, sdl_window.pixel_width, sdl_window.pixel_height, sdl_window.framebuffer);
    defer gpa.free(png);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = png });
}
