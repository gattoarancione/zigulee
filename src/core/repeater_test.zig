// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const core = @import("core.zig");
const items = core.items;
const Window = core.Window;
const Item = core.Item;

const gpa = testing.allocator;

/// The repeated component: a 20px tall row with a label.
const Row = struct {
    pub const Context = *List;

    list: *List,
    rect: items.Rectangle = .{},
    label: items.Text = .{},
    constraints: core.LayoutConstraints = .{},
    index: usize,

    pub fn create(alloc: std.mem.Allocator, list: *List, index: usize, data: []const u8) std.mem.Allocator.Error!*Row {
        const self = try alloc.create(Row);
        self.* = .{ .list = list, .index = index };
        self.rect.item.constraints = &self.constraints;
        self.constraints.min_height.set(20);
        self.constraints.max_height.set(20);
        self.rect.item.appendChild(&self.label.item);
        self.label.text.set(data);
        list.created += 1;
        return self;
    }

    pub fn update(self: *Row, index: usize, data: []const u8) void {
        self.index = index;
        self.label.text.set(data);
    }

    pub fn destroy(self: *Row) void {
        self.label.deinit();
        self.rect.deinit();
        self.constraints.deinit();
        self.list.destroyed += 1;
        gpa.destroy(self);
    }

    pub fn rootItem(self: *Row) *Item {
        return &self.rect.item;
    }
};

/// The conditional component: a 10px tall banner.
const Banner = struct {
    pub const Context = *List;

    rect: items.Rectangle = .{},
    constraints: core.LayoutConstraints = .{},

    pub fn create(alloc: std.mem.Allocator, _: *List) std.mem.Allocator.Error!*Banner {
        const self = try alloc.create(Banner);
        self.* = .{};
        self.rect.item.constraints = &self.constraints;
        self.constraints.min_height.set(10);
        self.constraints.max_height.set(10);
        return self;
    }

    pub fn destroy(self: *Banner) void {
        self.rect.deinit();
        self.constraints.deinit();
        gpa.destroy(self);
    }

    pub fn rootItem(self: *Banner) *Item {
        return &self.rect.item;
    }
};

/// VerticalLayout { if show_banner : Banner {}  for name in names : Row {}  footer := Rectangle {} }
const List = struct {
    window: Window = undefined,
    column: items.BoxLayout = .vertical(),
    banner: core.Conditional(Banner) = undefined,
    rows: core.Repeater([]const u8, Row) = undefined,
    footer: items.Rectangle = .{},
    names: core.VecModel([]const u8) = undefined,
    show_banner: core.Property(bool) = .init(false),
    created: usize = 0,
    destroyed: usize = 0,

    fn create() !*List {
        const l = try gpa.create(List);
        l.* = .{};
        l.window.init(gpa, .{ .width = 100, .height = 200 });
        l.names = .init(gpa);
        try l.banner.init(gpa, l);
        try l.rows.init(gpa, l);
        try l.banner.condition.setBinding(gpa, &l.show_banner, struct {
            fn f(p: *core.Property(bool)) bool {
                return p.get();
            }
        }.f);

        l.window.rootItem().appendChild(&l.column.item);
        l.column.item.appendChildren(&.{ &l.banner.item, &l.rows.item, &l.footer.item });
        try l.column.setup(gpa);
        try l.column.item.fillParent(gpa);
        try l.rows.setModel(l.names.model());
        return l;
    }

    fn destroy(l: *List) void {
        l.window.deinit();
        l.rows.deinit();
        l.banner.deinit();
        l.footer.deinit();
        l.column.deinit();
        l.names.deinit();
        l.show_banner.deinit();
        gpa.destroy(l);
    }

    fn rowAt(l: *List, i: usize) *Row {
        return l.rows.instance(i);
    }
};

test "repeater instances follow the model and join the layout" {
    const l = try List.create();
    defer l.destroy();
    try testing.expectEqual(@as(usize, 0), l.rows.count());
    try testing.expectEqual(@as(f32, 200), l.footer.item.height.get());

    try l.names.push("a");
    try l.names.push("c");
    try l.names.insert(1, "b");
    try testing.expectEqual(@as(usize, 3), l.rows.count());
    for ([_][]const u8{ "a", "b", "c" }, 0..) |name, i| {
        const row = l.rowAt(i);
        try testing.expectEqualStrings(name, row.label.text.get());
        try testing.expectEqual(i, row.index);
        try testing.expectEqual(@as(f32, @floatFromInt(i * 20)), row.rect.item.y.get());
        try testing.expectEqual(@as(f32, 100), row.rect.item.width.get());
    }
    try testing.expectEqual(@as(f32, 60), l.footer.item.y.get());
    try testing.expectEqual(@as(f32, 140), l.footer.item.height.get());
    // Tree order matches model order.
    try testing.expectEqual(&l.rowAt(0).rect.item, l.rows.item.first_child.?);
    try testing.expectEqual(&l.rowAt(2).rect.item, l.rows.item.last_child.?);

    l.names.setRowData(1, "B");
    try testing.expectEqualStrings("B", l.rowAt(1).label.text.get());
    try testing.expectEqual(@as(usize, 3), l.created); // updated in place

    _ = l.names.remove(0);
    try testing.expectEqual(@as(usize, 2), l.rows.count());
    try testing.expectEqualStrings("B", l.rowAt(0).label.text.get());
    try testing.expectEqual(@as(usize, 0), l.rowAt(0).index);
    try testing.expectEqual(@as(f32, 0), l.rowAt(0).rect.item.y.get());
    try testing.expectEqual(@as(f32, 40), l.footer.item.y.get());

    try l.names.setAll(&.{ "x", "y", "z", "w" });
    try testing.expectEqual(@as(usize, 4), l.rows.count());
    try testing.expectEqual(@as(f32, 80), l.footer.item.y.get());
    try testing.expectEqual(l.created - l.destroyed, l.rows.count());

    // A reset recreates every row, possibly at the addresses of the old
    // ones: the layout must still bind each of them.
    for (0..3) |_| {
        try l.names.setAll(&.{ "p", "q", "r", "s" });
        for (0..4) |i| {
            try testing.expectEqual(@as(f32, @floatFromInt(i * 20)), l.rowAt(i).rect.item.y.get());
            try testing.expectEqual(@as(f32, 100), l.rowAt(i).rect.item.width.get());
        }
    }
    // Rows appended and removed at the end, one at a time.
    for (0..3) |_| {
        try l.names.push("t");
        try testing.expectEqual(@as(f32, 80), l.rowAt(4).rect.item.y.get());
        _ = l.names.remove(4);
    }
    try testing.expectEqual(@as(f32, 80), l.footer.item.y.get());
}

test "repeated items are drawn and hit like any other" {
    const l = try List.create();
    defer l.destroy();
    try l.names.setAll(&.{ "one", "two" });
    l.rowAt(1).rect.background.set(.color(.black));

    var dl: core.rendering.DisplayList = .init(gpa, .{ .width = 100, .height = 200 });
    defer dl.deinit();
    _ = try l.window.render(dl.renderer(), .full);
    var found = false;
    for (dl.commands.items) |c| switch (c) {
        .rectangle => |r| if (r.style.background.eql(.color(.black))) {
            try testing.expectEqual(core.Rect{ .x = 0, .y = 20, .width = 100, .height = 20 }, r.rect);
            found = true;
        },
        .text, .image, .path, .shadow, .layer, .end_layer => {},
    };
    try testing.expect(found);

    // Removing a row repaints where it was.
    _ = try l.window.render(dl.renderer(), .partial);
    _ = l.names.remove(1);
    const region = try l.window.render(dl.renderer(), .partial);
    try testing.expect(region.boundingBox().containsRect(.{ .x = 0, .y = 20, .width = 100, .height = 20 }));
}

test "conditional instance appears and disappears with its condition" {
    const l = try List.create();
    defer l.destroy();
    try l.names.push("a");
    try testing.expectEqual(@as(?*Banner, null), l.banner.instance);

    l.show_banner.set(true);
    try testing.expectEqual(@as(?*Banner, null), l.banner.instance); // applied by change handlers
    core.runChangeHandlers();
    const banner = l.banner.instance.?;
    try testing.expectEqual(@as(f32, 10), banner.rect.item.height.get());
    try testing.expectEqual(@as(f32, 10), l.rowAt(0).rect.item.y.get()); // pushed down

    l.show_banner.set(false);
    core.runChangeHandlers();
    try testing.expectEqual(@as(?*Banner, null), l.banner.instance);
    try testing.expectEqual(@as(f32, 0), l.rowAt(0).rect.item.y.get());
}

test "repeater without a model and model replacement" {
    const l = try List.create();
    defer l.destroy();
    try l.names.setAll(&.{ "a", "b" });
    try l.rows.setModel(null);
    try testing.expectEqual(@as(usize, 0), l.rows.count());
    try l.names.push("ignored"); // detached
    try testing.expectEqual(@as(usize, 0), l.rows.count());
    try l.rows.setModel(l.names.model());
    try testing.expectEqual(@as(usize, 3), l.rows.count());
}
