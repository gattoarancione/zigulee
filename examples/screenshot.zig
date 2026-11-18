// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Renders a small card UI with the software renderer and saves it as a PNG:
//!
//!     zig build run-screenshot -- [out.png] [font.ttf]
//!
//! Uses the fonts bundled in `examples/fonts` (Inter and JetBrains Mono),
//! or the given TrueType font for all text.
//!
//!     Window {
//!         background: #f1f5f9;
//!         card := Rectangle {
//!             background: white; border-radius: 16px;
//!             border-width: 1px; border-color: #e2e8f0;
//!             VerticalLayout {
//!                 padding: 16px; spacing: 12px;
//!                 Rectangle {
//!                     background: @linear-gradient(135deg, #6366f1, #ec4899); border-radius: 10px;
//!                     Text { text: "Hello, zigulee!"; font-size: 22px; color: white; }
//!                     Text { text: "Rendered in software ..."; wrap: word-wrap; color: #e0e7ff; }
//!                 }
//!                 HorizontalLayout {
//!                     spacing: 12px;
//!                     Path { commands: "..."; fill: #f59e0b; }   // star
//!                     Path { commands: "..."; stroke: #0f172a; stroke-width: 3px; } // check mark
//!                     Image { source: ...; image-rendering: pixelated; }
//!                 }
//!             }
//!         }
//!     }

const std = @import("std");
const zigulee = @import("zigulee");
const core = zigulee.core;
const items = core.items;
const Color = core.Color;

const Card = struct {
    window: zigulee.Window = undefined,
    card: items.Rectangle = .{},
    column: items.BoxLayout = .vertical(),
    banner: items.Rectangle = .{},
    banner_column: items.BoxLayout = .vertical(),
    title: items.Text = .{},
    body: items.Text = .{},
    code: items.Text = .{},
    row: items.BoxLayout = .horizontal(),
    row_constraints: core.LayoutConstraints = .{},
    star: items.Path = .{},
    check: items.Path = .{},
    icon: items.Image = .{},

    fn init(self: *Card, gpa: std.mem.Allocator, icon: core.Image) !void {
        self.* = .{};
        self.window.init(gpa, .{ .width = 320, .height = 260 });
        self.window.root.background.set(.color(.rgb(0xf1f5f9)));

        self.window.rootItem().appendChild(&self.card.item);
        self.card.item.setGeometry(.{ .x = 20, .y = 20, .width = 280, .height = 220 });
        self.card.background.set(.color(.white));
        self.card.border_radius.set(16);
        self.card.border_width.set(1);
        self.card.border_color.set(.color(.rgb(0xe2e8f0)));

        self.card.item.appendChild(&self.column.item);
        self.column.item.appendChildren(&.{ &self.banner.item, &self.row.item });
        self.column.setPadding(16);
        self.column.spacing.set(12);
        self.banner.background.set(.linear(135, &.{
            .{ .color = .rgb(0x6366f1), .position = 0 },
            .{ .color = .rgb(0xec4899), .position = 1 },
        }));
        self.banner.border_radius.set(10);
        self.banner.item.appendChild(&self.banner_column.item);
        self.banner_column.item.appendChildren(&.{ &self.title.item, &self.body.item, &self.code.item });
        self.banner_column.setPadding(12);
        self.banner_column.spacing.set(4);
        self.title.text.set("Hello, zigulee!");
        self.title.font_size.set(22);
        self.title.color.set(.color(.white));
        self.body.text.set("Rendered in software with a TrueType font read directly in Zig: no C libraries.");
        self.body.font_size.set(13);
        self.body.wrap.set(.word_wrap);
        self.body.color.set(.color(.rgb(0xe0e7ff)));
        self.code.text.set("try window.render(...);");
        self.code.font_size.set(11);
        self.code.color.set(.color(.rgb(0xfef3c7)));

        self.row.item.constraints = &self.row_constraints;
        self.row_constraints.min_height.set(48);
        self.row_constraints.max_height.set(48);
        self.row.spacing.set(12);
        self.row.item.appendChildren(&.{ &self.star.item, &self.check.item, &self.icon.item });

        self.star.commands.set("M50 0 L61 35 L98 35 L68 57 L79 91 L50 70 L21 91 L32 57 L2 35 L39 35 Z");
        self.star.viewbox.set(.{ .width = 100, .height = 100 });
        self.star.fill.set(.color(.rgb(0xf59e0b)));
        self.check.commands.set("M4 12 L10 18 L20 6");
        self.check.viewbox.set(.{ .width = 24, .height = 24 });
        self.check.stroke.set(.color(.rgb(0x0f172a)));
        self.check.stroke_width.set(3);
        self.icon.source.set(icon);
        self.icon.image_rendering.set(.pixelated);

        try self.row.setup(gpa);
        try self.banner_column.setup(gpa);
        try self.banner_column.item.fillParent(gpa);
        try self.column.setup(gpa);
        try self.column.item.fillParent(gpa);
    }

    fn deinit(self: *Card) void {
        self.window.deinit();
        self.icon.deinit();
        self.check.deinit();
        self.star.deinit();
        self.row.deinit();
        self.row_constraints.deinit();
        self.code.deinit();
        self.body.deinit();
        self.title.deinit();
        self.banner_column.deinit();
        self.banner.deinit();
        self.column.deinit();
        self.card.deinit();
    }
};

/// An 8x8 pixel-art smiley.
fn smiley(gpa: std.mem.Allocator) !core.OwnedImage {
    const art = [8]*const [8]u8{
        "..####..",
        ".#....#.",
        "#.#..#.#",
        "#......#",
        "#.#..#.#",
        "#..##..#",
        ".#....#.",
        "..####..",
    };
    var img: core.OwnedImage = try .init(gpa, 8, 8);
    for (art, 0..) |line, y| for (line, 0..) |c, x| {
        img.pixels[y * 8 + x] = if (c == '#') Color.rgb(0x16a34a).premultiplied() else .transparent;
    };
    return img;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const out_path = if (args.len > 1) args[1] else "screenshot.png";
    const custom_bytes: ?[]u8 = if (args.len > 2)
        try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], gpa, .limited(64 << 20))
    else
        null;
    defer if (custom_bytes) |b| gpa.free(b);
    var custom: ?core.Font = if (custom_bytes) |b| try core.Font.init(b) else null;
    var regular: core.Font = try .init(@embedFile("fonts/inter/Inter-Regular.ttf"));
    var bold: core.Font = try .init(@embedFile("fonts/inter/Inter-Bold.ttf"));
    var mono: core.Font = try .init(@embedFile("fonts/jetbrains-mono/JetBrainsMono-Regular.ttf"));

    var icon = try smiley(gpa);
    defer icon.deinit(gpa);
    var ui: Card = undefined;
    try ui.init(gpa, icon.image());
    defer ui.deinit();
    if (custom) |*f| {
        ui.window.default_font.set(f);
    } else {
        ui.window.default_font.set(&regular);
        ui.title.font.set(&bold);
        ui.code.font.set(&mono);
    }

    const size = ui.window.size();
    const width: u32 = @intFromFloat(size.width);
    const height: u32 = @intFromFloat(size.height);
    const pixels = try gpa.alloc(core.Rgba8, @as(usize, width) * height);
    defer gpa.free(pixels);

    var renderer: zigulee.software.Renderer(core.Rgba8) = .init(gpa);
    defer renderer.deinit();
    _ = try renderer.renderWindow(&ui.window, .init(pixels, width, height), .full);

    const bytes = try core.png.encode(gpa, width, height, pixels);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = bytes });
    std.debug.print("wrote {s} ({d}x{d})\n", .{ out_path, width, height });
}
