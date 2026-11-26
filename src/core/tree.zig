// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! A tree's rows and which are shown (`TreeState`): the rows in order, each
//! with its depth (`levels`: 0 for the top ones, a child one more than its
//! parent, right after it). What is expanded is kept here, so a TreeView
//! written in `.zge` shows `shown` (the rows whose parents are all
//! expanded) and toggles them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const ChangeTracker = @import("properties.zig").ChangeTracker;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const model = @import("model.zig");
const Model = model.Model;
const DerivedModel = model.DerivedModel;

const log = std.log.scoped(.zigulee_tree);

/// The rows of a tree shown, by their `levels` (depths) and what is
/// expanded: `shown` (the indices of the rows shown, in order),
/// `expanded` and `has-children` (by row). `toggle(row)`, `expand(row)`,
/// `collapse(row)`, `expand-all()`, `collapse-all()`; new rows start
/// expanded if `initially-expanded`. Not drawn. Initialize in place with
/// `init`.
pub const TreeState = struct {
    item: Item = .init(&vtable),
    levels: Property(Model(i32)) = .init(model.emptyModel(i32)),
    initially_expanded: Property(bool) = .init(false),
    shown: Property(Model(i32)) = .init(model.emptyModel(i32)),
    expanded: Property(Model(bool)) = .init(model.emptyModel(bool)),
    has_children: Property(Model(bool)) = .init(model.emptyModel(bool)),

    gpa: Allocator = undefined,
    tracker: ChangeTracker(u64) = undefined,
    level_of: std.ArrayList(i32) = .empty,
    open: std.ArrayList(bool) = .empty,
    shown_rows: DerivedModel(i32) = .{},
    expanded_rows: DerivedModel(bool) = .{},
    parent_rows: DerivedModel(bool) = .{},

    pub fn init(self: *TreeState, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.shown.set(self.shown_rows.update(gpa, &.{}));
        self.expanded.set(self.expanded_rows.update(gpa, &.{}));
        self.has_children.set(self.parent_rows.update(gpa, &.{}));
        self.tracker.init(gpa, self, levelsHash, levelsChanged);
    }

    pub fn deinit(self: *TreeState) void {
        self.tracker.deinit();
        self.level_of.deinit(self.gpa);
        self.open.deinit(self.gpa);
        self.shown_rows.deinit(self.gpa);
        self.expanded_rows.deinit(self.gpa);
        self.parent_rows.deinit(self.gpa);
        self.item.deinit();
        self.levels.deinit();
        self.initially_expanded.deinit();
        self.shown.deinit();
        self.expanded.deinit();
        self.has_children.deinit();
    }

    pub fn toggle(self: *TreeState, row: i32) void {
        const i = self.index(row) orelse return;
        self.open.items[i] = !self.open.items[i];
        self.recompute();
    }

    pub fn expand(self: *TreeState, row: i32) void {
        const i = self.index(row) orelse return;
        self.open.items[i] = true;
        self.recompute();
    }

    pub fn collapse(self: *TreeState, row: i32) void {
        const i = self.index(row) orelse return;
        self.open.items[i] = false;
        self.recompute();
    }

    pub fn expandAll(self: *TreeState) void {
        @memset(self.open.items, true);
        self.recompute();
    }

    pub fn collapseAll(self: *TreeState) void {
        @memset(self.open.items, false);
        self.recompute();
    }

    fn index(self: *TreeState, row: i32) ?usize {
        if (row < 0 or row >= self.open.items.len) return null;
        return @intCast(row);
    }

    /// The levels, read (and depended on).
    fn levelsHash(self: *TreeState) u64 {
        const m = self.levels.get();
        var h: std.hash.Wyhash = .init(0);
        const n = m.rowCount();
        h.update(std.mem.asBytes(&n));
        for (0..n) |i| {
            const l = m.rowData(i) orelse 0;
            h.update(std.mem.asBytes(&l));
        }
        return h.final();
    }

    fn levelsChanged(self: *TreeState, _: u64) void {
        const m = self.levels.getUntracked();
        const n = m.rowCount();
        self.level_of.resize(self.gpa, n) catch return log.err("out of memory reading a tree", .{});
        for (self.level_of.items, 0..) |*l, i| l.* = m.rowData(i) orelse 0;
        // Rows kept keep their state; new ones start as told.
        const old = self.open.items.len;
        self.open.resize(self.gpa, n) catch return log.err("out of memory reading a tree", .{});
        if (n > old) @memset(self.open.items[old..], self.initially_expanded.getUntracked());
        self.recompute();
    }

    fn recompute(self: *TreeState) void {
        const gpa = self.gpa;
        const levels = self.level_of.items;
        const n = levels.len;
        const parents = gpa.alloc(bool, n) catch return;
        defer gpa.free(parents);
        for (parents, 0..) |*p, i| p.* = i + 1 < n and levels[i + 1] > levels[i];
        // Shown: each row, unless under a collapsed one.
        var shown: std.ArrayList(i32) = .empty;
        defer shown.deinit(gpa);
        var hidden_below: ?i32 = null;
        for (levels, 0..) |l, i| {
            if (hidden_below) |h| {
                if (l > h) continue;
                hidden_below = null;
            }
            shown.append(gpa, @intCast(i)) catch return;
            if (parents[i] and !self.open.items[i]) hidden_below = l;
        }
        _ = self.shown_rows.update(gpa, shown.items);
        _ = self.expanded_rows.update(gpa, self.open.items);
        _ = self.parent_rows.update(gpa, parents);
    }

    const vtable: item_mod.ItemVTable = .{ .name = "TreeState" };
};

// ---- Tests ----

const testing = std.testing;
const core = @import("core.zig");

fn shownOf(t: *TreeState, buf: []i32) []i32 {
    const m = t.shown.get();
    const n = m.rowCount();
    for (0..n) |i| buf[i] = m.rowData(i).?;
    return buf[0..n];
}

test "a tree's rows shown by what is expanded" {
    var t: TreeState = undefined;
    t.init(testing.allocator);
    defer t.deinit();
    // 0 Fruit / 1 Apple / 2 Pear / 3 Seed (of Pear) / 4 Vegetables / 5 Leek
    var levels: core.SliceModel(i32) = .init(&.{ 0, 1, 1, 2, 0, 1 });
    defer levels.deinit();
    t.levels.set(levels.model());
    core.runChangeHandlers();
    var buf: [8]i32 = undefined;
    // Collapsed at first: the top rows.
    try testing.expectEqualSlices(i32, &.{ 0, 4 }, shownOf(&t, &buf));
    try testing.expectEqual(@as(?bool, true), t.has_children.get().rowData(0));
    try testing.expectEqual(@as(?bool, false), t.has_children.get().rowData(1));
    t.toggle(0);
    try testing.expectEqualSlices(i32, &.{ 0, 1, 2, 4 }, shownOf(&t, &buf));
    try testing.expectEqual(@as(?bool, true), t.expanded.get().rowData(0));
    t.expand(2);
    try testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3, 4 }, shownOf(&t, &buf));
    // Collapsing a parent hides its children's children too.
    t.collapse(0);
    try testing.expectEqualSlices(i32, &.{ 0, 4 }, shownOf(&t, &buf));
    t.expandAll();
    try testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3, 4, 5 }, shownOf(&t, &buf));
    t.collapseAll();
    try testing.expectEqualSlices(i32, &.{ 0, 4 }, shownOf(&t, &buf));
    t.toggle(99); // no such row
}
