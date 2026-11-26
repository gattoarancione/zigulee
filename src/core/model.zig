// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Models: row-based data sources that drive `for` repeaters.
//!
//! Bindings that read a model through `Model(T)` depend on it like on a
//! property. Repeaters additionally attach a `ModelListener` to receive
//! fine-grained row notifications, so they can update only affected rows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const properties = @import("properties.zig");
const Property = properties.Property;

/// Receives row-level change notifications from a model.
pub const ModelListener = struct {
    vtable: *const VTable,
    prev: ?*ModelListener = null,
    next: ?*ModelListener = null,
    notify: ?*ModelNotify = null,

    pub const VTable = struct {
        rowChanged: *const fn (*ModelListener, row: usize) void,
        rowsAdded: *const fn (*ModelListener, index: usize, count: usize) void,
        rowsRemoved: *const fn (*ModelListener, index: usize, count: usize) void,
        reset: *const fn (*ModelListener) void,
    };

    /// Stops receiving notifications.
    pub fn detach(self: *ModelListener) void {
        const n = self.notify orelse return;
        if (self.prev) |p| p.next = self.next else n.listeners = self.next;
        if (self.next) |nx| nx.prev = self.prev;
        self.prev = null;
        self.next = null;
        self.notify = null;
    }
};

/// Change-notification state embedded in every model implementation.
/// Must not move once a binding or listener depends on it.
pub const ModelNotify = struct {
    row_count: Property(void) = .init({}),
    row_data: Property(void) = .init({}),
    listeners: ?*ModelListener = null,

    pub fn deinit(self: *ModelNotify) void {
        while (self.listeners) |l| l.detach();
        self.row_count.deinit();
        self.row_data.deinit();
    }

    pub fn attach(self: *ModelNotify, l: *ModelListener) void {
        l.detach();
        l.notify = self;
        l.prev = null;
        l.next = self.listeners;
        if (self.listeners) |head| head.prev = l;
        self.listeners = l;
    }

    pub fn trackRowCount(self: *ModelNotify) void {
        self.row_count.get();
    }

    pub fn trackRowData(self: *ModelNotify) void {
        self.row_data.get();
    }

    pub fn rowChanged(self: *ModelNotify, row: usize) void {
        self.row_data.notifyChanged();
        var it = self.listeners;
        while (it) |l| {
            it = l.next;
            l.vtable.rowChanged(l, row);
        }
    }

    pub fn rowsAdded(self: *ModelNotify, index: usize, count: usize) void {
        if (count == 0) return;
        self.row_count.notifyChanged();
        self.row_data.notifyChanged();
        var it = self.listeners;
        while (it) |l| {
            it = l.next;
            l.vtable.rowsAdded(l, index, count);
        }
    }

    pub fn rowsRemoved(self: *ModelNotify, index: usize, count: usize) void {
        if (count == 0) return;
        self.row_count.notifyChanged();
        self.row_data.notifyChanged();
        var it = self.listeners;
        while (it) |l| {
            it = l.next;
            l.vtable.rowsRemoved(l, index, count);
        }
    }

    pub fn reset(self: *ModelNotify) void {
        self.row_count.notifyChanged();
        self.row_data.notifyChanged();
        var it = self.listeners;
        while (it) |l| {
            it = l.next;
            l.vtable.reset(l);
        }
    }
};

/// Type-erased handle to a model of rows of type `T`.
pub fn Model(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Row = T;

        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            rowCount: *const fn (*anyopaque) usize,
            rowData: *const fn (*anyopaque, row: usize) ?T,
            /// Null for read-only models.
            setRowData: ?*const fn (*anyopaque, row: usize, value: T) void,
            notify: *const fn (*anyopaque) *ModelNotify,
            /// Made again by each evaluation of the expression that made
            /// it (a list literal's, a filter's): whoever keeps it copies
            /// it (`Kept`).
            scratch: bool = false,
        };

        /// Number of rows; tracked as a dependency.
        pub fn rowCount(self: Self) usize {
            self.vtable.notify(self.ptr).trackRowCount();
            return self.vtable.rowCount(self.ptr);
        }

        /// Row data, or null if out of range; tracked as a dependency.
        pub fn rowData(self: Self, row: usize) ?T {
            self.vtable.notify(self.ptr).trackRowData();
            return self.vtable.rowData(self.ptr, row);
        }

        /// Writes a row (e.g. from a two-way binding in a delegate).
        /// Ignored by read-only models.
        pub fn setRowData(self: Self, row: usize, value: T) void {
            if (self.vtable.setRowData) |f| f(self.ptr, row, value);
        }

        pub fn attach(self: Self, listener: *ModelListener) void {
            self.vtable.notify(self.ptr).attach(listener);
        }
    };
}

/// A read-only model over a slice (e.g. an array literal in `.zge`).
/// Must not move once used.
/// Whether `T` is a `Model(...)`.
pub fn isModel(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Row") and @TypeOf(T.Row) == type and T == Model(T.Row);
}

pub fn SliceModel(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []const T,
        notify: ModelNotify = .{},

        pub fn init(items: []const T) Self {
            return .{ .items = items };
        }

        pub fn deinit(self: *Self) void {
            self.notify.deinit();
        }

        pub fn model(self: *Self) Model(T) {
            return .{ .ptr = self, .vtable = &vtable };
        }

        const vtable: Model(T).VTable = .{
            .rowCount = rowCount,
            .rowData = rowData,
            .setRowData = null,
            .notify = notifyOf,
        };

        fn cast(p: *anyopaque) *Self {
            return @ptrCast(@alignCast(p));
        }
        fn rowCount(p: *anyopaque) usize {
            return cast(p).items.len;
        }
        fn rowData(p: *anyopaque, row: usize) ?T {
            const self = cast(p);
            return if (row < self.items.len) self.items[row] else null;
        }
        fn notifyOf(p: *anyopaque) *ModelNotify {
            return &cast(p).notify;
        }
    };
}

/// A model of `n` rows recomputed by a binding (`[a, b + 1]` in `.zge`):
/// `update` stores new values and notifies only the rows that changed.
/// Must not move once used.
pub fn ArrayModel(comptime T: type, comptime n: usize) type {
    return struct {
        const Self = @This();

        values: [n]T = undefined,
        filled: bool = false,
        notify: ModelNotify = .{},

        pub fn deinit(self: *Self) void {
            self.notify.deinit();
        }

        pub fn update(self: *Self, values: [n]T) Model(T) {
            if (!self.filled) {
                self.values = values;
                self.filled = true;
            } else for (values, 0..) |v, i| {
                const changed = !properties.valuesEqual(T, self.values[i], v);
                self.values[i] = v; // even when equal: the old one may be freed
                if (changed) self.notify.rowChanged(i);
            }
            return .{ .ptr = self, .vtable = &vtable };
        }

        const vtable: Model(T).VTable = .{
            .rowCount = rowCount,
            .rowData = rowData,
            .setRowData = null,
            .notify = notifyOf,
            .scratch = true,
        };

        fn cast(p: *anyopaque) *Self {
            return @ptrCast(@alignCast(p));
        }
        fn rowCount(p: *anyopaque) usize {
            return if (cast(p).filled) n else 0;
        }
        fn rowData(p: *anyopaque, row: usize) ?T {
            const self = cast(p);
            return if (self.filled and row < n) self.values[row] else null;
        }
        fn notifyOf(p: *anyopaque) *ModelNotify {
            return &cast(p).notify;
        }
    };
}

/// A model computed from another (`m.filter(...)`, `m.sort(...)`,
/// `m.reverse()` in `.zge`): `update` stores the rows of the latest
/// evaluation and notifies what changed (each row, or everything if the
/// count did). Must not move once used.
pub fn DerivedModel(comptime T: type) type {
    return struct {
        const Self = @This();

        rows: std.ArrayList(T) = .empty,
        filled: bool = false,
        notify: ModelNotify = .{},
        /// Strings the rows were made with (`map`): those of the rows
        /// shown, and those of the next evaluation.
        strings: [2]?std.heap.ArenaAllocator = .{ null, null },
        current: u1 = 0,

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.notify.deinit();
            self.rows.deinit(gpa);
            for (&self.strings) |*a| if (a.*) |*arena| arena.deinit();
        }

        /// Where the next evaluation keeps the strings it makes (valid
        /// while its rows are shown, and one evaluation more).
        pub fn nextStrings(self: *Self, gpa: Allocator) Allocator {
            const next = &self.strings[self.current +% 1];
            if (next.*) |*a| {
                _ = a.reset(.retain_capacity);
            } else next.* = .init(gpa);
            return next.*.?.allocator();
        }

        pub fn update(self: *Self, gpa: Allocator, rows: []const T) Model(T) {
            if (!self.filled or rows.len != self.rows.items.len) {
                self.rows.clearRetainingCapacity();
                self.rows.appendSlice(gpa, rows) catch {};
                if (self.filled) self.notify.reset();
                self.filled = true;
            } else for (rows, 0..) |v, i| {
                const changed = !properties.valuesEqual(T, self.rows.items[i], v);
                self.rows.items[i] = v;
                if (changed) self.notify.rowChanged(i);
            }
            // The strings just made are the rows' now.
            if (self.strings[self.current +% 1] != null) self.current +%= 1;
            return .{ .ptr = self, .vtable = &vtable };
        }

        const vtable: Model(T).VTable = .{
            .rowCount = rowCount,
            .rowData = rowData,
            .setRowData = null,
            .notify = notifyOf,
            .scratch = true,
        };

        fn cast(p: *anyopaque) *Self {
            return @ptrCast(@alignCast(p));
        }
        fn rowCount(p: *anyopaque) usize {
            return cast(p).rows.items.len;
        }
        fn rowData(p: *anyopaque, row: usize) ?T {
            const self = cast(p);
            return if (row < self.rows.items.len) self.rows.items[row] else null;
        }
        fn notifyOf(p: *anyopaque) *ModelNotify {
            return &cast(p).notify;
        }
    };
}

/// Sorts `rows` by `keys` (the same length), stably: ascending numbers,
/// false before true, strings by their bytes.
pub fn sortByKeys(comptime T: type, comptime K: type, gpa: Allocator, rows: []T, keys: []const K) void {
    const order = gpa.alloc(usize, rows.len) catch return;
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.sort.block(usize, order, keys, struct {
        fn less(k: []const K, a: usize, b: usize) bool {
            return switch (K) {
                []const u8 => std.mem.order(u8, k[a], k[b]) == .lt,
                bool => !k[a] and k[b],
                else => k[a] < k[b],
            };
        }
    }.less);
    const copy = gpa.dupe(T, rows) catch return;
    defer gpa.free(copy);
    for (rows, order) |*r, o| r.* = copy[o];
}

test "derived models notify what changed, and sort by keys" {
    var d: DerivedModel(i32) = .{};
    defer d.deinit(std.testing.allocator);
    const m = d.update(std.testing.allocator, &.{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 3), m.rowCount());
    _ = d.update(std.testing.allocator, &.{ 1, 5, 3 });
    try std.testing.expectEqual(@as(?i32, 5), m.rowData(1));

    var rows = [_][]const u8{ "pear", "fig", "apple", "kiwi" };
    const keys = [_]i32{ 4, 3, 5, 4 };
    sortByKeys([]const u8, i32, std.testing.allocator, &rows, &keys);
    try std.testing.expectEqualStrings("fig", rows[0]);
    try std.testing.expectEqualStrings("pear", rows[1]); // stable
    try std.testing.expectEqualStrings("kiwi", rows[2]);
    try std.testing.expectEqualStrings("apple", rows[3]);
}

/// A shared model with no rows: the default value of model properties.
/// (A plain global so it can be a field's default value; UI state is
/// single-threaded.)
pub fn emptyModel(comptime T: type) Model(T) {
    const Static = struct {
        var instance: SliceModel(T) = .init(&.{});
    };
    return Static.instance.model();
}

/// The rows 0, 1, ..., count - 1 (`for i in n` in `.zge`). Must not move
/// once used.
pub const CountModel = struct {
    count: usize = 0,
    notify: ModelNotify = .{},

    pub fn deinit(self: *CountModel) void {
        self.notify.deinit();
    }

    pub fn setCount(self: *CountModel, count: usize) void {
        const old = self.count;
        self.count = count;
        if (count > old) self.notify.rowsAdded(old, count - old) else if (count < old) self.notify.rowsRemoved(count, old - count);
    }

    pub fn model(self: *CountModel) Model(i32) {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Model(i32).VTable = .{
        .rowCount = rowCount,
        .rowData = rowData,
        .setRowData = null,
        .notify = notifyOf,
    };

    fn cast(p: *anyopaque) *CountModel {
        return @ptrCast(@alignCast(p));
    }
    fn rowCount(p: *anyopaque) usize {
        return cast(p).count;
    }
    fn rowData(p: *anyopaque, row: usize) ?i32 {
        return if (row < cast(p).count) @intCast(row) else null;
    }
    fn notifyOf(p: *anyopaque) *ModelNotify {
        return &cast(p).notify;
    }
};

/// A model backed by a growable array. Must not move once used.
pub fn VecModel(comptime T: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        items: std.ArrayList(T) = .empty,
        notify: ModelNotify = .{},

        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            self.notify.deinit();
            self.items.deinit(self.gpa);
            self.* = undefined;
        }

        pub fn rowCount(self: *Self) usize {
            self.notify.trackRowCount();
            return self.items.items.len;
        }

        pub fn rowData(self: *Self, row: usize) ?T {
            self.notify.trackRowData();
            return if (row < self.items.items.len) self.items.items[row] else null;
        }

        pub fn setRowData(self: *Self, row: usize, value: T) void {
            if (row >= self.items.items.len) return;
            self.items.items[row] = value;
            self.notify.rowChanged(row);
        }

        pub fn push(self: *Self, value: T) Allocator.Error!void {
            try self.items.append(self.gpa, value);
            self.notify.rowsAdded(self.items.items.len - 1, 1);
        }

        pub fn insert(self: *Self, index: usize, value: T) Allocator.Error!void {
            try self.items.insert(self.gpa, index, value);
            self.notify.rowsAdded(index, 1);
        }

        pub fn remove(self: *Self, index: usize) T {
            const v = self.items.orderedRemove(index);
            self.notify.rowsRemoved(index, 1);
            return v;
        }

        /// Replaces all rows.
        pub fn setAll(self: *Self, values: []const T) Allocator.Error!void {
            self.items.clearRetainingCapacity();
            try self.items.appendSlice(self.gpa, values);
            self.notify.reset();
        }

        pub fn model(self: *Self) Model(T) {
            return .{ .ptr = self, .vtable = &vtable };
        }

        const vtable: Model(T).VTable = .{
            .rowCount = erasedRowCount,
            .rowData = erasedRowData,
            .setRowData = erasedSetRowData,
            .notify = erasedNotify,
        };

        fn cast(p: *anyopaque) *Self {
            return @ptrCast(@alignCast(p));
        }
        fn erasedRowCount(p: *anyopaque) usize {
            return cast(p).items.items.len;
        }
        fn erasedRowData(p: *anyopaque, row: usize) ?T {
            const self = cast(p);
            return if (row < self.items.items.len) self.items.items[row] else null;
        }
        fn erasedSetRowData(p: *anyopaque, row: usize, value: T) void {
            cast(p).setRowData(row, value);
        }
        fn erasedNotify(p: *anyopaque) *ModelNotify {
            return &cast(p).notify;
        }
    };
}

const testing = std.testing;

test "binding over a model re-evaluates on row changes" {
    const gpa = testing.allocator;
    var vm: VecModel(i32) = .init(gpa);
    defer vm.deinit();
    try vm.setAll(&.{ 1, 2, 3 });

    var sum: Property(i32) = .init(0);
    defer sum.deinit();
    try sum.setBinding(gpa, vm.model(), struct {
        fn f(m: Model(i32)) i32 {
            var total: i32 = 0;
            for (0..m.rowCount()) |i| total += m.rowData(i).?;
            return total;
        }
    }.f);

    try testing.expectEqual(@as(i32, 6), sum.get());
    try vm.push(10);
    try testing.expectEqual(@as(i32, 16), sum.get());
    vm.setRowData(0, 100);
    try testing.expectEqual(@as(i32, 115), sum.get());
    _ = vm.remove(1);
    try testing.expectEqual(@as(i32, 113), sum.get());
    try vm.setAll(&.{});
    try testing.expectEqual(@as(i32, 0), sum.get());
}

test "slice, empty and count models" {
    var names: SliceModel([]const u8) = .init(&.{ "a", "b" });
    defer names.deinit();
    try testing.expectEqual(@as(usize, 2), names.model().rowCount());
    try testing.expectEqualStrings("b", names.model().rowData(1).?);
    try testing.expectEqual(@as(usize, 0), emptyModel(i32).rowCount());

    var counter: CountModel = .{};
    defer counter.deinit();
    var total: Property(i32) = .init(0);
    defer total.deinit();
    try total.setBinding(testing.allocator, counter.model(), struct {
        fn f(m: Model(i32)) i32 {
            var sum: i32 = 0;
            for (0..m.rowCount()) |i| sum += m.rowData(i).?;
            return sum;
        }
    }.f);
    counter.setCount(4);
    try testing.expectEqual(@as(i32, 6), total.get());
    counter.setCount(2);
    try testing.expectEqual(@as(i32, 1), total.get());
}

test "listeners receive row notifications" {
    const Recorder = struct {
        listener: ModelListener = .{ .vtable = &.{
            .rowChanged = rowChanged,
            .rowsAdded = rowsAdded,
            .rowsRemoved = rowsRemoved,
            .reset = reset,
        } },
        log: [8][3]usize = undefined,
        len: usize = 0,

        fn rec(l: *ModelListener, kind: usize, a: usize, b: usize) void {
            const self: *@This() = @fieldParentPtr("listener", l);
            self.log[self.len] = .{ kind, a, b };
            self.len += 1;
        }
        fn rowChanged(l: *ModelListener, row: usize) void {
            rec(l, 0, row, 0);
        }
        fn rowsAdded(l: *ModelListener, i: usize, n: usize) void {
            rec(l, 1, i, n);
        }
        fn rowsRemoved(l: *ModelListener, i: usize, n: usize) void {
            rec(l, 2, i, n);
        }
        fn reset(l: *ModelListener) void {
            rec(l, 3, 0, 0);
        }
    };

    var vm: VecModel([]const u8) = .init(testing.allocator);
    defer vm.deinit();
    var r: Recorder = .{};
    vm.model().attach(&r.listener);

    try vm.push("a");
    try vm.insert(0, "b");
    vm.setRowData(1, "c");
    _ = vm.remove(0);
    try vm.setAll(&.{ "x", "y" });
    r.listener.detach();
    try vm.push("ignored");

    const expected = [_][3]usize{ .{ 1, 0, 1 }, .{ 1, 0, 1 }, .{ 0, 1, 0 }, .{ 2, 0, 1 }, .{ 3, 0, 0 } };
    try testing.expectEqualSlices([3]usize, &expected, r.log[0..r.len]);
    try testing.expectEqualStrings("y", vm.model().rowData(1).?);
}
