// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Which rows of a list are selected (`Selection`), for lists, tables,
//! trees and grids that let the user pick several: one row, rows toggled
//! one by one, or a range (from the last row picked to another, in the
//! order the rows are shown). The views written in `.zge` call its
//! functions as the user clicks and presses keys, and draw `selected`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const ChangeTracker = @import("properties.zig").ChangeTracker;
const Callback = @import("callbacks.zig").Callback;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const model = @import("model.zig");
const Model = model.Model;
const DerivedModel = model.DerivedModel;

const log = std.log.scoped(.zigulee_selection);

/// How a view lets the user select: one row (`single`, the current one);
/// several, as on desktops (`extended`: a click selects one, Ctrl- or
/// Cmd-click adds or removes one, Shift-click a range); or several, each
/// click adding or removing one (`multiple`, for touch screens).
pub const SelectionMode = enum { single, extended, multiple };

/// The selected rows of `count` rows: `selected` (by row) and
/// `selected-rows` (the rows selected, in order). `select(row)` selects
/// only `row`, `toggle(row)` adds or removes it, `extend-to(row)` selects
/// the rows from the last one selected or toggled to `row` (in the order
/// of `order`, the rows as shown, when given), `set-selected(row, on)`,
/// `select-all()`, `clear()`. `changed` is called when the selection
/// changes. When `count` shrinks, the rows gone are no longer selected.
/// Not drawn. Initialize in place with `init`.
pub const Selection = struct {
    item: Item = .init(&vtable),
    count: Property(i32) = .init(0),
    order: Property(Model(i32)) = .init(model.emptyModel(i32)),
    selected: Property(Model(bool)) = .init(model.emptyModel(bool)),
    selected_rows: Property(Model(i32)) = .init(model.emptyModel(i32)),
    changed: Callback(fn () void) = .{},

    gpa: Allocator = undefined,
    tracker: ChangeTracker(u64) = undefined,
    on: std.ArrayList(bool) = .empty,
    /// The rows as shown (empty: 0, 1, 2...).
    shown: std.ArrayList(i32) = .empty,
    /// Where a range starts: the last row selected or toggled (-1: none).
    anchor: i32 = -1,
    on_rows: DerivedModel(bool) = .{},
    rows: DerivedModel(i32) = .{},
    last: std.ArrayList(i32) = .empty,

    pub fn init(self: *Selection, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.selected.set(self.on_rows.update(gpa, &.{}));
        self.selected_rows.set(self.rows.update(gpa, &.{}));
        self.tracker.init(gpa, self, inputsHash, inputsChanged);
    }

    pub fn deinit(self: *Selection) void {
        self.tracker.deinit();
        self.on.deinit(self.gpa);
        self.shown.deinit(self.gpa);
        self.on_rows.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        self.last.deinit(self.gpa);
        self.item.deinit();
        self.count.deinit();
        self.order.deinit();
        self.selected.deinit();
        self.selected_rows.deinit();
    }

    /// Selects `row` only (none, for -1).
    pub fn select(self: *Selection, row: i32) void {
        self.readInputs();
        @memset(self.on.items, false);
        self.anchor = -1;
        if (self.index(row)) |i| {
            self.on.items[i] = true;
            self.anchor = row;
        }
        self.publish();
    }

    /// Adds `row` to the selection, or removes it.
    pub fn toggle(self: *Selection, row: i32) void {
        self.readInputs();
        const i = self.index(row) orelse return;
        self.on.items[i] = !self.on.items[i];
        self.anchor = row;
        self.publish();
    }

    pub fn setSelected(self: *Selection, row: i32, on: bool) void {
        self.readInputs();
        const i = self.index(row) orelse return;
        self.on.items[i] = on;
        self.publish();
    }

    /// Selects the rows from the last one selected or toggled to `row`, as
    /// shown (only `row`, when there is none).
    pub fn extendTo(self: *Selection, row: i32) void {
        self.readInputs();
        _ = self.index(row) orelse return;
        const from = self.position(self.anchor) orelse return self.select(row);
        const to = self.position(row) orelse return self.select(row);
        @memset(self.on.items, false);
        for (@min(from, to)..@max(from, to) + 1) |k| self.on.items[@intCast(self.rowAt(k))] = true;
        self.publish();
    }

    pub fn selectAll(self: *Selection) void {
        self.readInputs();
        @memset(self.on.items, true);
        self.publish();
    }

    pub fn clear(self: *Selection) void {
        self.readInputs();
        @memset(self.on.items, false);
        self.anchor = -1;
        self.publish();
    }

    fn index(self: *const Selection, row: i32) ?usize {
        if (row < 0 or row >= self.on.items.len) return null;
        return @intCast(row);
    }

    /// Where `row` is shown (null: not shown).
    fn position(self: *const Selection, row: i32) ?usize {
        _ = self.index(row) orelse return null;
        if (self.shown.items.len == 0) return @intCast(row);
        return std.mem.indexOfScalar(i32, self.shown.items, row);
    }

    /// The row shown at `k`.
    fn rowAt(self: *const Selection, k: usize) i32 {
        return if (self.shown.items.len == 0) @intCast(k) else self.shown.items[k];
    }

    /// The count and order, read (and depended on).
    fn inputsHash(self: *Selection) u64 {
        var h: std.hash.Wyhash = .init(0);
        const n = self.count.get();
        h.update(std.mem.asBytes(&n));
        const m = self.order.get();
        const rows = m.rowCount();
        h.update(std.mem.asBytes(&rows));
        for (0..rows) |i| {
            const r = m.rowData(i) orelse -1;
            h.update(std.mem.asBytes(&r));
        }
        return h.final();
    }

    fn inputsChanged(self: *Selection, _: u64) void {
        self.readInputs();
        self.publish();
    }

    /// The count and order as they are now (a function may be called
    /// before the change handlers have run).
    fn readInputs(self: *Selection) void {
        const n: usize = @intCast(@max(0, self.count.getUntracked()));
        // Rows kept keep their state; new ones start unselected.
        const old = self.on.items.len;
        self.on.resize(self.gpa, n) catch return log.err("out of memory selecting", .{});
        if (n > old) @memset(self.on.items[old..], false);
        if (self.anchor >= n) self.anchor = -1;
        // The rows shown, those there are.
        self.shown.clearRetainingCapacity();
        const m = self.order.getUntracked();
        for (0..m.rowCount()) |i| {
            const r = m.rowData(i) orelse continue;
            if (r >= 0 and r < n) self.shown.append(self.gpa, r) catch return log.err("out of memory selecting", .{});
        }
    }

    fn publish(self: *Selection) void {
        const gpa = self.gpa;
        var rows: std.ArrayList(i32) = .empty;
        defer rows.deinit(gpa);
        for (self.on.items, 0..) |on, i| if (on) rows.append(gpa, @intCast(i)) catch return;
        _ = self.on_rows.update(gpa, self.on.items);
        _ = self.rows.update(gpa, rows.items);
        if (std.mem.eql(i32, rows.items, self.last.items)) return;
        self.last.clearRetainingCapacity();
        self.last.appendSlice(gpa, rows.items) catch {};
        self.changed.call(.{});
    }

    const vtable: item_mod.ItemVTable = .{ .name = "Selection" };
};

// ---- Tests ----

const testing = std.testing;
const core = @import("core.zig");

fn rowsOf(s: *Selection, buf: []i32) []i32 {
    const m = s.selected_rows.get();
    const n = m.rowCount();
    for (0..n) |i| buf[i] = m.rowData(i).?;
    return buf[0..n];
}

test "rows selected one by one, toggled, in ranges" {
    var s: Selection = undefined;
    s.init(testing.allocator);
    defer s.deinit();
    var changes: u32 = 0;
    const count = struct {
        fn f(n: *u32) void {
            n.* += 1;
        }
    }.f;
    s.changed.setHandler(&changes, count);
    s.count.set(6);
    core.runChangeHandlers();
    var buf: [8]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{}, rowsOf(&s, &buf));
    s.select(2);
    try testing.expectEqualSlices(i32, &.{2}, rowsOf(&s, &buf));
    try testing.expectEqual(@as(?bool, true), s.selected.get().rowData(2));
    s.toggle(4);
    try testing.expectEqualSlices(i32, &.{ 2, 4 }, rowsOf(&s, &buf));
    // A range from the last toggled, either way.
    s.extendTo(1);
    try testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4 }, rowsOf(&s, &buf));
    s.extendTo(5);
    try testing.expectEqualSlices(i32, &.{ 4, 5 }, rowsOf(&s, &buf));
    s.toggle(4);
    try testing.expectEqualSlices(i32, &.{5}, rowsOf(&s, &buf));
    s.selectAll();
    try testing.expectEqual(@as(usize, 6), s.selected_rows.get().rowCount());
    // Fewer rows: those gone are no longer selected.
    s.count.set(3);
    core.runChangeHandlers();
    try testing.expectEqualSlices(i32, &.{ 0, 1, 2 }, rowsOf(&s, &buf));
    const before = changes;
    s.selectAll(); // no change
    try testing.expectEqual(before, changes);
    s.clear();
    try testing.expectEqualSlices(i32, &.{}, rowsOf(&s, &buf));
    try testing.expectEqual(before + 1, changes);
    s.toggle(99); // no such row
    s.select(-1);
}

test "rows there before the change handlers have run" {
    var s: Selection = undefined;
    s.init(testing.allocator);
    defer s.deinit();
    s.count.set(3);
    s.toggle(1);
    var buf: [4]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{1}, rowsOf(&s, &buf));
    core.runChangeHandlers();
    try testing.expectEqualSlices(i32, &.{1}, rowsOf(&s, &buf));
}

test "a range in the order shown" {
    var s: Selection = undefined;
    s.init(testing.allocator);
    defer s.deinit();
    s.count.set(6);
    // A tree with rows 1 and 2 under a collapsed 0: shown 0, 3, 4, 5.
    var order: core.SliceModel(i32) = .init(&.{ 0, 3, 5, 4 });
    defer order.deinit();
    s.order.set(order.model());
    core.runChangeHandlers();
    var buf: [8]i32 = undefined;
    s.select(0);
    s.extendTo(5);
    try testing.expectEqualSlices(i32, &.{ 0, 3, 5 }, rowsOf(&s, &buf));
    // Not shown: that row alone.
    s.extendTo(2);
    try testing.expectEqualSlices(i32, &.{2}, rowsOf(&s, &buf));
}
