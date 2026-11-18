// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Headless scrolling list, equivalent to:
//!
//!     export component List inherits Window {
//!         var in <[string]> names;
//!         var in-out <int> selected: -1;
//!         Flickable {
//!             viewport-height: column.preferred-height;
//!             column := VerticalLayout {
//!                 for name[i] in names : Rectangle {
//!                     height: 30px;
//!                     background: i == selected ? #2563eb : mod(i, 2) == 0 ? #f1f5f9 : #e2e8f0;
//!                     Text { text: name; }
//!                     TouchArea { clicked => { selected = i; } }
//!                 }
//!             }
//!         }
//!     }
//!
//! The demo taps a row, drags the list, flicks it, and prints each frame.

const std = @import("std");
const zigulee = @import("zigulee");
const items = zigulee.items;
const DisplayList = zigulee.core.rendering.DisplayList;

const Row = struct {
    pub const Context = *List;

    gpa: std.mem.Allocator,
    list: *List,
    index: zigulee.Property(usize),
    rect: items.Rectangle = .{},
    label: items.Text = .{},
    touch: items.TouchArea = .{},
    constraints: zigulee.core.LayoutConstraints = .{},

    pub fn create(gpa: std.mem.Allocator, list: *List, index: usize, name: []const u8) std.mem.Allocator.Error!*Row {
        const self = try gpa.create(Row);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .list = list, .index = .init(index) };
        self.rect.item.constraints = &self.constraints;
        self.constraints.min_height.set(30);
        self.constraints.max_height.set(30);
        self.rect.item.appendChildren(&.{ &self.label.item, &self.touch.item });
        self.label.text.set(name);
        self.label.item.x.set(8);
        self.label.item.y.set(8);
        self.label.item.width.set(100);
        self.label.item.height.set(14);
        try self.touch.item.fillParent(gpa);
        try self.rect.background.setBinding(gpa, self, background);
        self.touch.clicked.setHandler(self, select);
        return self;
    }

    pub fn update(self: *Row, index: usize, name: []const u8) void {
        self.index.set(index);
        self.label.text.set(name);
    }

    pub fn destroy(self: *Row) void {
        self.touch.deinit();
        self.label.deinit();
        self.rect.deinit();
        self.constraints.deinit();
        self.index.deinit();
        self.gpa.destroy(self);
    }

    pub fn rootItem(self: *Row) *zigulee.Item {
        return &self.rect.item;
    }

    fn background(self: *Row) zigulee.Brush {
        const i = self.index.get();
        if (self.list.selected.get() == @as(isize, @intCast(i))) return .color(.rgb(0x2563eb));
        return .color(.rgb(if (i % 2 == 0) 0xf1f5f9 else 0xe2e8f0));
    }

    fn select(self: *Row) void {
        self.list.selected.set(@intCast(self.index.get()));
    }
};

const List = struct {
    gpa: std.mem.Allocator,
    window: zigulee.Window = undefined,
    names: zigulee.VecModel([]const u8) = undefined,
    selected: zigulee.Property(isize) = .init(-1),
    flick: items.Flickable = undefined,
    column: items.BoxLayout = .vertical(),
    rows: zigulee.core.Repeater([]const u8, Row) = undefined,

    pub fn create(gpa: std.mem.Allocator) !*List {
        const self = try gpa.create(List);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa };
        self.window.init(gpa, .{ .width = 160, .height = 100 });
        self.names = .init(gpa);
        self.flick.init(gpa);
        try self.rows.init(gpa, self);

        self.window.rootItem().appendChild(&self.flick.item);
        self.flick.content().appendChild(&self.column.item);
        self.column.item.appendChild(&self.rows.item);
        try self.column.setup(gpa);
        try self.flick.item.fillParent(gpa);
        try self.column.item.fillParent(gpa);

        const content = self.flick.content();
        try content.width.setBinding(gpa, self, struct {
            fn f(l: *List) f32 {
                return l.flick.item.width.get();
            }
        }.f);
        try content.height.setBinding(gpa, self, struct {
            fn f(l: *List) f32 {
                return l.column.item.layoutInfo(.vertical).preferred;
            }
        }.f);

        try self.rows.setModel(self.names.model());
        return self;
    }

    pub fn destroy(self: *List) void {
        self.window.deinit();
        self.rows.deinit();
        self.column.deinit();
        self.flick.deinit();
        self.names.deinit();
        self.selected.deinit();
        self.gpa.destroy(self);
    }
};

fn frame(list: *List, dl: *DisplayList, label: []const u8) !void {
    dl.reset(.{ .width = 160, .height = 100 });
    const region = try list.window.render(dl.renderer(), .partial);
    std.debug.print("-- {s}: scroll y={d:.0}, dirty {d:.0}x{d:.0} at y={d:.0}, rows drawn:", .{
        label,
        list.flick.viewportPosition().y,
        region.boundingBox().width,
        region.boundingBox().height,
        region.boundingBox().y,
    });
    for (dl.commands.items) |cmd| switch (cmd) {
        .text => |t| std.debug.print(" {s}", .{t.style.text}),
        .rectangle, .image, .path, .shadow, .layer, .end_layer => {},
    };
    std.debug.print("\n", .{});
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const list = try List.create(gpa);
    defer list.destroy();
    const names = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliett" };
    try list.names.setAll(&names);

    var dl: DisplayList = .init(gpa, .{ .width = 160, .height = 100 });
    defer dl.deinit();
    const w = &list.window;
    var now: u64 = 0;

    try frame(list, &dl, "first frame");

    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 50, .y = 45 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 50, .y = 45 } } });
    try frame(list, &dl, "tap row 1");

    // Drag up 60px over 60ms, then let go: the list keeps going.
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 50, .y = 90 } } });
    var y: f32 = 90;
    while (y > 30) : (y -= 10) {
        now += 10;
        zigulee.updateTimersAndAnimations(now);
        w.dispatchPointer(.{ .moved = .{ .position = .{ .x = 50, .y = y - 10 } } });
    }
    try frame(list, &dl, "dragged");
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 50, .y = 30 } } });
    // A backend keeps producing frames while animations run.
    while (zigulee.hasActiveAnimations()) {
        now += 100;
        zigulee.updateTimersAndAnimations(now);
        try frame(list, &dl, "flicking");
    }
    try frame(list, &dl, "settled");
    try list.names.push("kilo");
    try frame(list, &dl, "row added at the end (off screen)");
}
