// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Headless layout + input + partial rendering demo, equivalent to:
//!
//!     export component Demo inherits Window {
//!         var in-out <int> clicks;
//!         VerticalLayout {
//!             padding: 10px; spacing: 10px;
//!             Text { text: "Clicks: \{clicks}"; font-size: 20px; }
//!             button := Rectangle {
//!                 background: touch.pressed ? #1d4ed8 : touch.has-hover ? #3b82f6 : #60a5fa;
//!                 touch := TouchArea { clicked => { clicks += 1; } }
//!             }
//!         }
//!     }
//!
//! Each "frame" prints the dirty region and the recorded draw commands.

const std = @import("std");
const zigulee = @import("zigulee");
const items = zigulee.items;
const Color = zigulee.Color;
const DisplayList = zigulee.core.rendering.DisplayList;

const Demo = struct {
    gpa: std.mem.Allocator,
    window: zigulee.Window = undefined,
    clicks: zigulee.Property(i32) = .init(0),
    column: items.BoxLayout = .vertical(),
    label: items.Text = .{},
    label_buf: [32]u8 = undefined,
    button: items.Rectangle = .{},
    touch: items.TouchArea = .{},

    pub fn create(gpa: std.mem.Allocator) !*Demo {
        const self = try gpa.create(Demo);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa };
        self.window.init(gpa, .{ .width = 160, .height = 100 });

        self.window.rootItem().appendChild(&self.column.item);
        self.column.item.appendChildren(&.{ &self.label.item, &self.button.item });
        self.button.item.appendChild(&self.touch.item);

        self.column.setPadding(10);
        self.column.spacing.set(10);
        self.label.font_size.set(20);
        try self.label.text.setBinding(gpa, self, labelText);
        try self.button.background.setBinding(gpa, self, buttonColor);
        self.touch.clicked.setHandler(self, onClicked);

        try self.column.setup(gpa);
        try self.column.item.fillParent(gpa);
        try self.touch.item.fillParent(gpa);
        return self;
    }

    pub fn destroy(self: *Demo) void {
        self.window.deinit();
        self.touch.deinit();
        self.button.deinit();
        self.label.deinit();
        self.column.deinit();
        self.clicks.deinit();
        self.gpa.destroy(self);
    }

    fn labelText(self: *Demo) []const u8 {
        return std.fmt.bufPrint(&self.label_buf, "Clicks: {d}", .{self.clicks.get()}) catch "?";
    }

    fn buttonColor(self: *Demo) zigulee.Brush {
        const c: u24 = if (self.touch.pressed.get()) 0x1d4ed8 else if (self.touch.has_hover.get()) 0x3b82f6 else 0x60a5fa;
        return .color(.rgb(c));
    }

    fn onClicked(self: *Demo) void {
        self.clicks.set(self.clicks.get() + 1);
    }
};

fn frame(demo: *Demo, dl: *DisplayList, label: []const u8) !void {
    dl.reset(.{ .width = 160, .height = 100 });
    const region = try demo.window.render(dl.renderer(), .partial);
    std.debug.print("-- {s}: dirty {any}\n", .{ label, region.slice() });
    for (dl.commands.items) |cmd| switch (cmd) {
        .rectangle => |r| std.debug.print("   rect {d}x{d} at ({d},{d}) #{x:0>2}{x:0>2}{x:0>2}\n", .{
            r.rect.width, r.rect.height, r.rect.x, r.rect.y, r.style.background.solid.r, r.style.background.solid.g, r.style.background.solid.b,
        }),
        .text => |t| std.debug.print("   text \"{s}\" in {d}x{d} at ({d},{d})\n", .{ t.style.text, t.rect.width, t.rect.height, t.rect.x, t.rect.y }),
        .image, .path, .shadow, .layer, .end_layer => {},
    };
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const demo = try Demo.create(gpa);
    defer demo.destroy();
    var dl: DisplayList = .init(gpa, .{});
    defer dl.deinit();

    try frame(demo, &dl, "first frame");
    try frame(demo, &dl, "idle");
    demo.window.dispatchPointer(.{ .moved = .{ .position = .{ .x = 80, .y = 70 } } });
    try frame(demo, &dl, "hover");
    demo.window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 80, .y = 70 } } });
    try frame(demo, &dl, "pressed");
    demo.window.dispatchPointer(.{ .released = .{ .position = .{ .x = 80, .y = 70 } } });
    try frame(demo, &dl, "released (clicked)");
    demo.window.setSize(.{ .width = 120, .height = 100 });
    try frame(demo, &dl, "resized");
}
