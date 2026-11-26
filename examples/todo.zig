// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! A todo list (`zig build run-todo`): the UI is in todo.zge, the list is
//! a `VecModel` owned by Zig (todo_list.zig). The UI asks for changes
//! through callbacks, and the rows it shows follow the model.
//!
//!     todo [--lang it] [--screenshot out.png]
//!
//! `--lang it` shows it in Italian (translations/it.po).

const std = @import("std");
const zigulee = @import("zigulee");
/// zigulee-sdl3, or zigulee-macos with `-Dbackend=macos`.
const backend = @import("zigulee-backend");
const ui = @import("todo_ui");
const Todo = @import("todo_list.zig").Todo;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var screenshot: ?[]const u8 = null;
    var lang: ?[]const u8 = null;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--screenshot")) screenshot = args[i + 1];
        if (std.mem.eql(u8, args[i], "--lang")) lang = args[i + 1];
    }

    // Translations: a catalog per language, chosen at start (it could
    // change at any time: everything translated follows).
    var italian: zigulee.core.i18n.Catalog = try .parse(gpa, @embedFile("translations/it.po"));
    defer italian.deinit();
    if (lang) |l| {
        if (std.mem.eql(u8, l, "it")) zigulee.core.i18n.setTranslator(italian.translator()) else std.debug.print("todo: no translation for '{s}'\n", .{l});
    }

    const app = try ui.TodoApp.create(gpa);
    defer app.destroy();
    var todo: Todo = undefined;
    todo.init(gpa, app);
    defer todo.deinit();
    for ([_][]const u8{ "Water the plants", "Write the docs", "Fuzz the parser" }) |t| todo.add(t);
    todo.toggle(2, true);

    const regular: zigulee.Font = try .init(@embedFile("fonts/inter/Inter-Regular.ttf"));
    app.window().default_font.set(&regular);

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
