// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! What a function or callback returns, kept by the call that made it
//! (used by generated code). A function makes its strings and lists in
//! memory of its own, one place per function: several bindings calling it
//! would each hold the same memory, rewritten by the next call. Each call
//! keeps a copy instead: strings, lists the function made (not models
//! handed on, which stay live), and `.zge` structs of them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

/// A call's copies of `T`: the latest, and the one before (still read
/// while a property compares its old value with the new one). A list is
/// kept in one model of the call's own, updated row by row.
pub fn Kept(comptime T: type) type {
    return struct {
        const Self = @This();
        const is_list = model.isModel(T);

        slots: [2]Slot = .{ .{}, .{} },
        current: u1 = 0,
        rows: if (is_list) model.DerivedModel(T.Row) else void = if (is_list) .{} else {},

        pub fn deinit(self: *Self, gpa: Allocator) void {
            for (&self.slots) |*s| s.deinit(gpa);
            if (comptime is_list) self.rows.deinit(gpa);
        }

        /// `value`, copied where the call keeps it (as it is if it holds
        /// nothing of the function's, or out of memory).
        pub fn keep(self: *Self, gpa: Allocator, value: T) T {
            if (comptime !needsCopy(T)) return value;
            if (comptime is_list) if (!value.vtable.scratch) return value;
            self.current +%= 1;
            const slot = &self.slots[self.current];
            slot.reset(gpa);
            const c: Copier = .{ .gpa = gpa, .slot = slot };
            if (comptime is_list) {
                var rows: std.ArrayList(T.Row) = .empty;
                defer rows.deinit(gpa);
                for (0..value.rowCount()) |i| {
                    const r = value.rowData(i) orelse continue;
                    rows.append(gpa, c.copy(T.Row, r) catch r) catch break;
                }
                return self.rows.update(gpa, rows.items);
            }
            return c.copy(T, value) catch value;
        }
    };
}

/// Memory of one copy, and the lists made in it (let go before it is
/// used again: bindings may be reading them).
const Slot = struct {
    arena: ?std.heap.ArenaAllocator = null,
    lists: std.ArrayList(*model.ModelNotify) = .empty,

    fn reset(s: *Slot, gpa: Allocator) void {
        for (s.lists.items) |n| n.deinit();
        s.lists.clearRetainingCapacity();
        if (s.arena) |*a| {
            _ = a.reset(.retain_capacity);
        } else s.arena = .init(gpa);
    }

    fn deinit(s: *Slot, gpa: Allocator) void {
        for (s.lists.items) |n| n.deinit();
        s.lists.deinit(gpa);
        if (s.arena) |*a| a.deinit();
    }
};

const Copier = struct {
    gpa: Allocator,
    slot: *Slot,

    fn copy(c: Copier, comptime T: type, v: T) Allocator.Error!T {
        if (comptime !needsCopy(T)) return v;
        const a = c.slot.arena.?.allocator();
        if (T == []const u8) return a.dupe(u8, v);
        switch (@typeInfo(T)) {
            .optional => |o| return if (v) |x| try c.copy(o.child, x) else null,
            .@"struct" => |s| {
                if (comptime model.isModel(T)) {
                    if (!v.vtable.scratch) return v;
                    const n = v.rowCount();
                    const rows = try a.alloc(T.Row, n);
                    var k: usize = 0;
                    for (0..n) |i| if (v.rowData(i)) |r| {
                        rows[k] = try c.copy(T.Row, r);
                        k += 1;
                    };
                    const list = try a.create(model.SliceModel(T.Row));
                    list.* = .init(rows[0..k]);
                    try c.slot.lists.append(c.gpa, &list.notify);
                    return list.model();
                }
                var out = v;
                inline for (s.fields) |f| @field(out, f.name) = try c.copy(f.type, @field(v, f.name));
                return out;
            },
            else => return v,
        }
    }
};

/// Whether a `T` can hold memory of the function that made it: strings,
/// lists, and `.zge` structs (and optionals) of them.
fn needsCopy(comptime T: type) bool {
    comptime {
        if (T == []const u8) return true;
        switch (@typeInfo(T)) {
            .optional => |o| return needsCopy(o.child),
            .@"struct" => |s| {
                if (model.isModel(T)) return true;
                if (!@hasDecl(T, "zge_struct")) return false;
                for (s.fields) |f| if (needsCopy(f.type)) return true;
                return false;
            },
            else => return false,
        }
    }
}

const testing = std.testing;

test "kept copies: strings and lists outlive what made them, live models stay live" {
    const Person = struct {
        pub const zge_struct = {};
        name: []const u8,
        tags: model.Model([]const u8),
        age: i32,
    };
    var scratch: model.ArrayModel([]const u8, 2) = .{};
    defer scratch.deinit();
    var name: [8]u8 = "Ada     ".*;
    var kept: Kept(Person) = .{};
    defer kept.deinit(testing.allocator);
    const p = kept.keep(testing.allocator, .{ .name = name[0..3], .tags = scratch.update(.{ "a", "b" }), .age = 3 });
    // What made them changes: the copies do not.
    @memcpy(name[0..3], "Bob");
    _ = scratch.update(.{ "x", "y" });
    try testing.expectEqualStrings("Ada", p.name);
    try testing.expectEqualStrings("b", p.tags.rowData(1).?);
    try testing.expectEqual(@as(i32, 3), p.age);

    // A list made by the function: the call's own, row by row.
    var rows: Kept(model.Model([]const u8)) = .{};
    defer rows.deinit(testing.allocator);
    const first = rows.keep(testing.allocator, scratch.update(.{ "one", "two" }));
    _ = scratch.update(.{ "three", "four" });
    try testing.expectEqualStrings("two", first.rowData(1).?);
    const second = rows.keep(testing.allocator, scratch.update(.{ "one", "five" }));
    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expectEqualStrings("five", second.rowData(1).?);

    // A model handed on: the same one, live.
    var live: model.SliceModel([]const u8) = .init(&.{"z"});
    defer live.deinit();
    const same = rows.keep(testing.allocator, live.model());
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&live)), same.ptr);
}
