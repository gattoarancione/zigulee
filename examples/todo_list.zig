// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The todo list of the todo example (todo.zig, todo.zge): a `VecModel`
//! owned by Zig, changed through the UI's callbacks. Separate from the
//! window code so tests can run it headless (tests/ui_test.zig).

const std = @import("std");
const zigulee = @import("zigulee");
const ui = @import("todo_ui");

pub const Todo = struct {
    gpa: std.mem.Allocator,
    app: *ui.TodoApp,
    /// The rows; their titles are allocated with `gpa`.
    items: zigulee.VecModel(ui.TodoItem),

    pub fn init(self: *Todo, gpa: std.mem.Allocator, app: *ui.TodoApp) void {
        self.* = .{ .gpa = gpa, .app = app, .items = .init(gpa) };
        app.items.set(self.items.model());
        app.add.setHandler(self, add);
        app.toggle.setHandler(self, toggle);
        app.remove.setHandler(self, remove);
        app.clear_done.setHandler(self, clearDone);
    }

    pub fn deinit(self: *Todo) void {
        for (0..self.items.rowCount()) |i| self.gpa.free(self.items.rowData(i).?.title);
        self.items.deinit();
    }

    pub fn add(self: *Todo, text: []const u8) void {
        const title = std.mem.trim(u8, text, " \t");
        if (title.len == 0) return;
        // The UI's text changes as the user types: keep a copy.
        const owned = self.gpa.dupe(u8, title) catch return;
        self.items.push(.{ .title = owned, .done = false }) catch {
            self.gpa.free(owned);
            return;
        };
        self.updateRemaining();
    }

    pub fn toggle(self: *Todo, index: i32, done: bool) void {
        const i: usize = @intCast(index);
        var row = self.items.rowData(i) orelse return;
        row.done = done;
        self.items.setRowData(i, row);
        self.updateRemaining();
    }

    pub fn remove(self: *Todo, index: i32) void {
        const i: usize = @intCast(index);
        if (i >= self.items.rowCount()) return;
        // The row's elements are gone once `remove` returns.
        self.gpa.free(self.items.remove(i).title);
        self.updateRemaining();
    }

    pub fn clearDone(self: *Todo) void {
        var i = self.items.rowCount();
        while (i > 0) {
            i -= 1;
            if (self.items.rowData(i).?.done) self.gpa.free(self.items.remove(i).title);
        }
        self.updateRemaining();
    }

    fn updateRemaining(self: *Todo) void {
        var n: i32 = 0;
        for (0..self.items.rowCount()) |i| {
            if (!self.items.rowData(i).?.done) n += 1;
        }
        self.app.remaining.set(n);
    }
};
