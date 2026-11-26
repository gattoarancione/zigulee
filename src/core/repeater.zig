// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Dynamic subtrees: `for` (Repeater) and `if` (Conditional).
//!
//! Both are items whose children are the root items of component instances
//! they create and destroy. Inside a layout their children are laid out as
//! if they were the layout's own children.
//!
//! An instance type is a component with:
//!
//!     pub const Context = ...; // what instances need from their parent
//!     pub fn create(gpa: Allocator, ctx: Context, ...) Allocator.Error!*Instance
//!     pub fn destroy(self: *Instance) void
//!     pub fn rootItem(self: *Instance) *Item
//!
//! where `create` takes `(index: usize, data: T)` for a repeater, and
//! repeater instances also have `pub fn update(self, index: usize, data: T) void`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const properties = @import("properties.zig");
const Property = properties.Property;
const ChangeTracker = properties.ChangeTracker;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const ItemVTable = item_mod.ItemVTable;
const model_mod = @import("model.zig");
const Model = model_mod.Model;
const ModelListener = model_mod.ModelListener;

const log = std.log.scoped(.zigulee);

const conditional_vtable: ItemVTable = .{ .name = "Conditional", .flatten_in_layout = true };

fn notifyParent(item: *Item) void {
    const parent = item.parent orelse return;
    if (parent.vtable.childrenChanged) |f| f(parent);
}

/// `for row[index] in model : Instance { ... }`: one instance per model row,
/// kept in sync with the model's row notifications.
pub fn Repeater(comptime T: type, comptime Instance: type) type {
    return struct {
        const Self = @This();

        item: Item = .init(&vtable),
        gpa: Allocator,
        ctx: Instance.Context,
        model: ?Model(T) = null,
        instances: std.ArrayList(*Instance) = .empty,
        listener: ModelListener = .{ .vtable = &listener_vtable },
        /// Showing some rows only (`showRows`): the first of them. Then the
        /// instances are a ring, row `r` in `instances[r % count]`.
        window_first: ?usize = null,

        const vtable: ItemVTable = .{
            .name = "Repeater",
            .flatten_in_layout = true,
            .modelRowCount = modelRowCount,
            .showRows = showRowsOf,
        };

        /// Initializes in place; the repeater covers its parent.
        pub fn init(self: *Self, gpa: Allocator, ctx: Instance.Context) Allocator.Error!void {
            self.* = .{ .gpa = gpa, .ctx = ctx };
            try self.item.fillParent(gpa);
        }

        pub fn deinit(self: *Self) void {
            self.listener.detach();
            self.clear();
            self.instances.deinit(self.gpa);
            self.item.deinit();
        }

        /// Replaces the model and recreates all instances.
        pub fn setModel(self: *Self, model: ?Model(T)) Allocator.Error!void {
            self.listener.detach();
            self.model = model;
            if (model) |m| m.attach(&self.listener);
            try self.rebuild();
        }

        pub fn count(self: *const Self) usize {
            return self.instances.items.len;
        }

        pub fn instance(self: *Self, index: usize) *Instance {
            return self.instances.items[index];
        }

        pub fn rowCount(self: *const Self) usize {
            const m = self.model orelse return 0;
            return m.vtable.rowCount(m.ptr);
        }

        /// Keeps instances for the rows `first..first + n_rows` only (which
        /// must be rows of the model): when `first` changes, those of the rows
        /// scrolled out take the rows scrolled in (`update`), nothing is
        /// created or destroyed. Instance `i` (and child `i`) shows row
        /// `ringRow(first, n_rows, i)`.
        pub fn showRows(self: *Self, first: usize, n_rows: usize) Allocator.Error!void {
            const n = self.instances.items.len;
            if (self.window_first == null or n_rows != n) {
                self.window_first = first;
                try self.resize(n_rows);
                self.refresh();
                return notifyParent(&self.item);
            }
            const old = self.window_first.?;
            if (old == first) return;
            self.window_first = first;
            // The rows that came in.
            var r = first;
            while (r < first + n) : (r += 1) {
                if (r >= old and r < old + n) continue;
                if (self.rowData(r)) |d| self.instances.items[r % n].update(r, d);
            }
        }

        fn modelRowCount(i: *Item) usize {
            const self: *Self = @fieldParentPtr("item", i);
            return self.rowCount();
        }

        fn showRowsOf(i: *Item, first: usize, n: usize) void {
            const self: *Self = @fieldParentPtr("item", i);
            self.showRows(first, n) catch log.err("out of memory creating repeated items", .{});
        }

        /// As many instances as `n` (created or destroyed at the end).
        fn resize(self: *Self, n: usize) Allocator.Error!void {
            while (self.instances.items.len > n) destroyInstance(self.instances.pop().?);
            try self.instances.ensureTotalCapacity(self.gpa, n);
            while (self.instances.items.len < n) {
                const slot = self.instances.items.len;
                const row = ringRow(self.window_first.?, n, slot);
                // Rows past the model's end: none (the caller asked for too many).
                const data = self.rowData(row) orelse break;
                const inst = try Instance.create(self.gpa, self.ctx, row, data);
                self.instances.appendAssumeCapacity(inst);
                self.item.appendChild(inst.rootItem());
            }
        }

        /// Each instance given its row's data again (the model changed).
        fn refresh(self: *Self) void {
            const n = self.instances.items.len;
            for (self.instances.items, 0..) |inst, slot| {
                const row = ringRow(self.window_first.?, n, slot);
                if (self.rowData(row)) |d| inst.update(row, d);
            }
        }

        fn rowData(self: *Self, row: usize) ?T {
            const m = self.model orelse return null;
            return m.vtable.rowData(m.ptr, row);
        }

        fn rebuild(self: *Self) Allocator.Error!void {
            if (self.window_first == null) if (self.item.parent) |p| if (p.vtable.shows_rows) {
                self.clear();
                self.window_first = 0;
            };
            if (self.window_first != null) {
                self.refresh();
                return notifyParent(&self.item);
            }
            self.clear();
            const m = self.model orelse return notifyParent(&self.item);
            try self.insertRows(0, m.vtable.rowCount(m.ptr));
        }

        fn insertRows(self: *Self, index: usize, n: usize) Allocator.Error!void {
            defer notifyParent(&self.item);
            try self.instances.ensureUnusedCapacity(self.gpa, n);
            const before: ?*Item = if (index < self.instances.items.len) self.instances.items[index].rootItem() else null;
            var created: usize = 0;
            while (created < n) : (created += 1) {
                const row = index + created;
                const data = self.rowData(row) orelse break;
                const inst = try Instance.create(self.gpa, self.ctx, row, data);
                self.instances.insertAssumeCapacity(row, inst);
                self.item.insertChildBefore(inst.rootItem(), before);
            }
            self.renumber(index + created);
        }

        fn removeRows(self: *Self, index: usize, n: usize) void {
            const end = @min(index + n, self.instances.items.len);
            for (self.instances.items[index..end]) |inst| destroyInstance(inst);
            self.instances.replaceRangeAssumeCapacity(index, end - index, &.{});
            self.renumber(index);
            notifyParent(&self.item);
        }

        fn renumber(self: *Self, from: usize) void {
            for (self.instances.items[from..], from..) |inst, i| {
                if (self.rowData(i)) |d| inst.update(i, d);
            }
        }

        fn clear(self: *Self) void {
            for (self.instances.items) |inst| destroyInstance(inst);
            self.instances.clearRetainingCapacity();
        }

        fn destroyInstance(inst: *Instance) void {
            inst.rootItem().removeFromParent();
            inst.destroy();
        }

        const listener_vtable: ModelListener.VTable = .{
            .rowChanged = rowChanged,
            .rowsAdded = rowsAdded,
            .rowsRemoved = rowsRemoved,
            .reset = reset,
        };

        fn fromListener(l: *ModelListener) *Self {
            return @alignCast(@fieldParentPtr("listener", l));
        }

        fn rowChanged(l: *ModelListener, row: usize) void {
            const self = fromListener(l);
            if (self.window_first) |first| {
                const n = self.instances.items.len;
                if (row < first or row >= first + n) return;
                if (self.rowData(row)) |d| self.instances.items[row % n].update(row, d);
                return;
            }
            if (row >= self.instances.items.len) return;
            if (self.rowData(row)) |d| self.instances.items[row].update(row, d);
        }

        fn rowsAdded(l: *ModelListener, index: usize, n: usize) void {
            const self = fromListener(l);
            if (self.window_first != null) return reset(l);
            self.insertRows(index, n) catch log.err("out of memory creating repeated items", .{});
        }

        fn rowsRemoved(l: *ModelListener, index: usize, n: usize) void {
            const self = fromListener(l);
            if (self.window_first != null) return reset(l);
            self.removeRows(index, n);
        }

        fn reset(l: *ModelListener) void {
            fromListener(l).rebuild() catch log.err("out of memory creating repeated items", .{});
        }
    };
}

/// The row instance `slot` of a repeater showing `count` rows from `first`
/// shows (row `r` is in slot `r % count`).
pub fn ringRow(first: usize, count: usize, slot: usize) usize {
    if (count == 0) return first;
    return first + (slot + count - first % count) % count;
}

/// `if condition : Instance { ... }`: an instance that exists while
/// `condition` is true. Changes apply when change handlers run
/// (`runChangeHandlers`, once per event loop iteration), or immediately
/// with `sync`.
pub fn Conditional(comptime Instance: type) type {
    return struct {
        const Self = @This();

        item: Item = .init(&conditional_vtable),
        gpa: Allocator,
        ctx: Instance.Context,
        condition: Property(bool) = .init(false),
        instance: ?*Instance = null,
        tracker: ChangeTracker(bool) = undefined,

        /// Initializes in place; the conditional covers its parent.
        pub fn init(self: *Self, gpa: Allocator, ctx: Instance.Context) Allocator.Error!void {
            self.* = .{ .gpa = gpa, .ctx = ctx };
            try self.item.fillParent(gpa);
            self.tracker.init(gpa, self, evalCondition, onConditionChanged);
        }

        pub fn deinit(self: *Self) void {
            self.tracker.deinit();
            if (self.instance) |inst| {
                inst.rootItem().removeFromParent();
                inst.destroy();
            }
            self.condition.deinit();
            self.item.deinit();
        }

        /// Creates or destroys the instance to match `condition` now.
        pub fn sync(self: *Self) Allocator.Error!void {
            const want = self.condition.getUntracked();
            // What the tracker compares the next value with: what is shown
            // (it may have seen an older one, before the condition's
            // binding was set).
            self.tracker.value = want;
            if (want == (self.instance != null)) return;
            defer notifyParent(&self.item);
            if (self.instance) |inst| {
                inst.rootItem().removeFromParent();
                inst.destroy();
                self.instance = null;
            } else {
                const inst = try Instance.create(self.gpa, self.ctx);
                self.instance = inst;
                self.item.appendChild(inst.rootItem());
            }
        }

        fn evalCondition(self: *Self) bool {
            return self.condition.get();
        }

        fn onConditionChanged(self: *Self, _: bool) void {
            self.sync() catch log.err("out of memory creating conditional items", .{});
        }
    };
}

test "a conditional follows its condition after being synced at setup" {
    const Inst = struct {
        rect: @import("items.zig").Rectangle = .{},
        gpa: Allocator,
        pub const Context = void;
        pub fn create(gpa: Allocator, _: void) Allocator.Error!*@This() {
            const self = try gpa.create(@This());
            self.* = .{ .gpa = gpa };
            return self;
        }
        pub fn destroy(self: *@This()) void {
            self.rect.deinit();
            self.gpa.destroy(self);
        }
        pub fn rootItem(self: *@This()) *Item {
            return &self.rect.item;
        }
    };
    var flag: Property(bool) = .init(false);
    defer flag.deinit();
    var cond: Conditional(Inst) = undefined;
    try cond.init(std.testing.allocator, {});
    defer cond.deinit();
    // As generated code does: `if !flag`, bound then synced.
    try cond.condition.setBinding(std.testing.allocator, &flag, struct {
        fn f(p: *Property(bool)) bool {
            return !p.get();
        }
    }.f);
    try cond.sync();
    try std.testing.expect(cond.instance != null);
    // The user of the component sets the flag before change handlers run.
    flag.set(true);
    @import("properties.zig").runChangeHandlers();
    try std.testing.expect(cond.instance == null);
}
