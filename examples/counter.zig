// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! A hand-written component in the shape the `.zge` compiler will generate:
//!
//!     export component Counter {
//!         var in-out <int> counter: 0;
//!         var out <string> label: counter > 9 ? "many" : "few";
//!         callback clicked();
//!         changed counter => { debug("counter is now \{counter}"); }
//!     }

const std = @import("std");
const zigulee = @import("zigulee");

const Counter = struct {
    gpa: std.mem.Allocator,
    counter: zigulee.Property(i32) = .init(0),
    label: zigulee.Property([]const u8) = .init(""),
    clicked: zigulee.Callback(fn () void) = .{},
    counter_changed: zigulee.ChangeTracker(i32) = undefined,

    /// Components are heap-allocated so properties never move.
    pub fn create(gpa: std.mem.Allocator) !*Counter {
        const self = try gpa.create(Counter);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa };
        try self.label.setBinding(gpa, self, labelBinding);
        self.counter_changed.init(gpa, self, counterValue, onCounterChanged);
        return self;
    }

    pub fn destroy(self: *Counter) void {
        self.counter_changed.deinit();
        self.label.deinit();
        self.counter.deinit();
        self.gpa.destroy(self);
    }

    fn labelBinding(self: *Counter) []const u8 {
        return if (self.counter.get() > 9) "many" else "few";
    }

    fn counterValue(self: *Counter) i32 {
        return self.counter.get();
    }

    fn onCounterChanged(_: *Counter, value: i32) void {
        std.debug.print("  changed: counter is now {d}\n", .{value});
    }
};

fn increment(c: *Counter) void {
    c.counter.set(c.counter.get() + 4);
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const app = try Counter.create(gpa);
    defer app.destroy();
    app.clicked.setHandler(app, increment);

    // Stand-in for the event loop: deliver three clicks.
    for (0..3) |_| {
        app.clicked.call(.{});
        zigulee.runChangeHandlers();
        std.debug.print("counter={d} label={s}\n", .{ app.counter.get(), app.label.get() });
    }
}
