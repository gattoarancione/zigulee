// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Models of interpreter values: array literals and `for i in n` counts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const ModelNotify = zigulee.core.ModelNotify;
const Value = @import("value.zig").Value;

/// The rows of an array literal (`[a, b * 2]`), updated by the binding
/// that evaluates it: only rows whose value changed are reported. Each row
/// owns its strings, freed once listeners have seen the replacement.
pub const ArrayModel = struct {
    gpa: Allocator,
    rows: std.ArrayList(Row) = .empty,
    notify: ModelNotify = .{},

    const Row = struct {
        value: Value,
        arena: std.heap.ArenaAllocator,
    };

    pub fn init(gpa: Allocator) ArrayModel {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ArrayModel) void {
        self.notify.deinit();
        for (self.rows.items) |*r| r.arena.deinit();
        self.rows.deinit(self.gpa);
    }

    pub fn model(self: *ArrayModel) zigulee.Model(Value) {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Sets the rows; returns the model.
    pub fn update(self: *ArrayModel, values: []const Value) Allocator.Error!zigulee.Model(Value) {
        if (values.len != self.rows.items.len) {
            // A different length: start over.
            var old = self.rows;
            self.rows = .empty;
            try self.rows.ensureTotalCapacity(self.gpa, values.len);
            for (values) |v| self.rows.appendAssumeCapacity(try newRow(self.gpa, v));
            self.notify.reset();
            for (old.items) |*r| r.arena.deinit();
            old.deinit(self.gpa);
            return self.model();
        }
        for (values, 0..) |v, i| {
            if (self.rows.items[i].value.eql(v)) continue;
            var old = self.rows.items[i];
            self.rows.items[i] = try newRow(self.gpa, v);
            self.notify.rowChanged(i);
            old.arena.deinit();
        }
        return self.model();
    }

    fn newRow(gpa: Allocator, v: Value) Allocator.Error!Row {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        return .{ .value = try v.clone(arena.allocator()), .arena = arena };
    }

    const vtable: zigulee.Model(Value).VTable = .{
        .rowCount = rowCount,
        .rowData = rowData,
        .setRowData = null,
        .notify = getNotify,
    };

    fn cast(p: *anyopaque) *ArrayModel {
        return @ptrCast(@alignCast(p));
    }

    fn rowCount(p: *anyopaque) usize {
        return cast(p).rows.items.len;
    }

    fn rowData(p: *anyopaque, row: usize) ?Value {
        const self = cast(p);
        if (row >= self.rows.items.len) return null;
        return self.rows.items[row].value;
    }

    fn getNotify(p: *anyopaque) *ModelNotify {
        return &cast(p).notify;
    }
};

/// Rows 0, 1, ... n-1 (`for i in n`).
pub const CountModel = struct {
    count: usize = 0,
    notify: ModelNotify = .{},

    pub fn deinit(self: *CountModel) void {
        self.notify.deinit();
    }

    pub fn model(self: *CountModel) zigulee.Model(Value) {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn setCount(self: *CountModel, n: usize) void {
        const old = self.count;
        if (n == old) return;
        self.count = n;
        if (n > old) self.notify.rowsAdded(old, n - old) else self.notify.rowsRemoved(n, old - n);
    }

    const vtable: zigulee.Model(Value).VTable = .{
        .rowCount = rowCount,
        .rowData = rowData,
        .setRowData = null,
        .notify = getNotify,
    };

    fn cast(p: *anyopaque) *CountModel {
        return @ptrCast(@alignCast(p));
    }

    fn rowCount(p: *anyopaque) usize {
        return cast(p).count;
    }

    fn rowData(p: *anyopaque, row: usize) ?Value {
        if (row >= cast(p).count) return null;
        return .{ .int = @intCast(row) };
    }

    fn getNotify(p: *anyopaque) *ModelNotify {
        return &cast(p).notify;
    }
};

test "array model reports changed rows only" {
    const gpa = std.testing.allocator;
    var m: ArrayModel = .init(gpa);
    defer m.deinit();
    const model = try m.update(&.{ .{ .string = "a" }, .{ .int = 1 } });
    try std.testing.expectEqual(@as(usize, 2), model.rowCount());
    var buf: [1]u8 = .{'b'};
    _ = try m.update(&.{ .{ .string = &buf }, .{ .int = 1 } });
    buf[0] = 'x'; // the model kept its own copy
    try std.testing.expectEqualStrings("b", model.rowData(0).?.string);

    var c: CountModel = .{};
    defer c.deinit();
    c.setCount(3);
    try std.testing.expectEqual(@as(i32, 2), c.model().rowData(2).?.int);
}
