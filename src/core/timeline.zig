// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Animations started and stopped from code (as Qt's): `PropertyAnimation`
//! (a property from a value to another), `PauseAnimation`, and the
//! `SequentialAnimation` and `ParallelAnimation` that group them (their
//! children, in the item tree of animations). The one started (a group's
//! root) drives them all on one timer, by time: a frame late lands where
//! it should, and the values of steps passed are set at their end.
//!
//! A property animation's property is reached through `Target`: generated
//! code (or the interpreter) captures the start and end values when it
//! begins, and sets the value between them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const ChangeTracker = @import("properties.zig").ChangeTracker;
const Callback = @import("callbacks.zig").Callback;
const Timer = @import("timers.zig").Timer;
const time = @import("time.zig");
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const animations = @import("animations.zig");
const Easing = animations.Easing;

/// How often a running animation sets its values, in milliseconds.
const frame_ms = 16;

pub const Kind = enum { property, pause, sequential, parallel };

/// A property animation's property.
pub const Target = struct {
    ctx: *anyopaque,
    /// Captures the start and end values (the current value, unless a
    /// start is given).
    begin: *const fn (*anyopaque) void,
    /// Sets the value at `t` (0: start, 1: end; eased, may overshoot).
    apply: *const fn (*anyopaque, t: f32) void,
};

/// What the four animation elements share (their `node`).
pub const Node = struct {
    item: Item,
    kind: Kind,
    /// One run, in milliseconds (property and pause animations).
    duration_ms: Property(i64) = .init(250),
    easing: Property(Easing) = .init(.linear),
    /// Runs; -1: forever.
    loops: Property(i32) = .init(1),
    /// Setting it starts or stops the animation (a group's children
    /// follow their group).
    running: Property(bool) = .init(false),
    paused: Property(bool) = .init(false),
    /// It ran to its end (not when stopped).
    finished: Callback(fn () void) = .{},

    target: ?Target = null,
    gpa: Allocator = undefined,
    timer: Timer = .{},
    tracker: ChangeTracker(Settings) = undefined,
    applied: Settings = .{ .running = false, .paused = false },
    /// When it started (or would have, given the time it was paused).
    start_ms: u64 = 0,
    paused_at: u64 = 0,
    /// Its values captured (property animations), for this run.
    begun: bool = false,

    const Settings = struct { running: bool, paused: bool };

    pub fn init(self: *Node, gpa: Allocator, kind: Kind) void {
        self.* = .{ .item = .init(vtableFor(kind)), .kind = kind, .gpa = gpa };
        self.tracker.init(gpa, self, settings, apply);
    }

    pub fn deinit(self: *Node) void {
        self.timer.deinit();
        self.tracker.deinit();
        self.item.deinit();
        self.duration_ms.deinit();
        self.easing.deinit();
        self.loops.deinit();
        self.running.deinit();
        self.paused.deinit();
    }

    /// Typed `Target` from `begin(ctx)` and `apply(ctx, t)`.
    pub fn setTarget(self: *Node, ctx: anytype, comptime begin: fn (@TypeOf(ctx)) void, comptime apply_fn: fn (@TypeOf(ctx), f32) void) void {
        const Ctx = @TypeOf(ctx);
        const W = struct {
            fn b(p: *anyopaque) void {
                begin(@as(Ctx, @ptrCast(@alignCast(p))));
            }
            fn a(p: *anyopaque, t: f32) void {
                apply_fn(@as(Ctx, @ptrCast(@alignCast(p))), t);
            }
        };
        self.target = .{ .ctx = @ptrCast(@constCast(ctx)), .begin = W.b, .apply = W.a };
    }

    /// From the start.
    pub fn start(self: *Node) void {
        self.applied = .{ .running = true, .paused = false };
        self.restart();
        if (!self.running.getUntracked()) self.running.set(true);
        if (self.paused.getUntracked()) self.paused.set(false);
    }

    /// Where it is: values stay as they are.
    pub fn stop(self: *Node) void {
        self.applied = .{ .running = false, .paused = false };
        self.timer.stop();
        if (self.running.getUntracked()) self.running.set(false);
        if (self.paused.getUntracked()) self.paused.set(false);
    }

    pub fn pause(self: *Node) void {
        if (!self.applied.running or self.applied.paused) return;
        self.applied.paused = true;
        self.paused_at = time.now();
        self.timer.stop();
        if (!self.paused.getUntracked()) self.paused.set(true);
    }

    pub fn @"resume"(self: *Node) void {
        if (!self.applied.running or !self.applied.paused) return;
        self.applied.paused = false;
        self.start_ms += time.now() -| self.paused_at;
        self.timer.start(.repeated, frame_ms, self, tick);
        if (self.paused.getUntracked()) self.paused.set(false);
    }

    fn settings(self: *Node) Settings {
        return .{ .running = self.running.get(), .paused = self.paused.get() };
    }

    fn apply(self: *Node, s: Settings) void {
        const was = self.applied;
        if (s.running != was.running) {
            if (s.running) self.start() else self.stop();
        }
        if (s.paused != self.applied.paused) {
            if (s.paused) self.pause() else self.@"resume"();
        }
    }

    fn restart(self: *Node) void {
        self.start_ms = time.now();
        self.reset();
        self.seek(0);
        self.timer.start(.repeated, frame_ms, self, tick);
    }

    /// Ready to capture values again (it and what it groups).
    fn reset(self: *Node) void {
        self.begun = false;
        var it = self.item.first_child;
        while (it) |c| : (it = c.next_sibling) if (nodeOf(c)) |n| n.reset();
    }

    fn tick(self: *Node) void {
        const elapsed = time.now() -| self.start_ms;
        const total = self.totalMs();
        if (total) |end| if (elapsed >= end) {
            self.seek(end);
            self.stop();
            self.finished.call(.{});
            return;
        };
        self.seek(elapsed);
    }

    // ---- Time ----

    /// One run, in milliseconds.
    fn onceMs(self: *Node) ?u64 {
        switch (self.kind) {
            .property, .pause => return @intCast(@max(self.duration_ms.getUntracked(), 0)),
            .sequential => {
                var sum: u64 = 0;
                var it = self.item.first_child;
                while (it) |c| : (it = c.next_sibling) if (nodeOf(c)) |n| {
                    sum += n.totalMs() orelse return null;
                };
                return sum;
            },
            .parallel => {
                var longest: u64 = 0;
                var it = self.item.first_child;
                while (it) |c| : (it = c.next_sibling) if (nodeOf(c)) |n| {
                    longest = @max(longest, n.totalMs() orelse return null);
                };
                return longest;
            },
        }
    }

    /// All its runs; null: forever.
    fn totalMs(self: *Node) ?u64 {
        const once = self.onceMs() orelse return null;
        const loops = self.loops.getUntracked();
        if (loops < 0) return null;
        return once * @as(u64, @intCast(loops));
    }

    /// Sets what it animates as at `ms` from its start.
    fn seek(self: *Node, ms: u64) void {
        const once = self.onceMs() orelse 0;
        const loops = self.loops.getUntracked();
        if (loops == 0) return;
        // Where in its run (at the end of its last one, once past it).
        var local: u64 = 0;
        if (once > 0) {
            const run = ms / once;
            local = if (loops > 0 and run >= @as(u64, @intCast(loops))) once else ms % once;
        }
        switch (self.kind) {
            .pause => {},
            .property => {
                const t = self.target orelse return;
                if (!self.begun) {
                    self.begun = true;
                    t.begin(t.ctx);
                }
                const raw: f32 = if (once == 0) 1 else @as(f32, @floatFromInt(@min(local, once))) / @as(f32, @floatFromInt(once));
                t.apply(t.ctx, self.easing.getUntracked().apply(raw));
            },
            .sequential => {
                var at: u64 = 0;
                var it = self.item.first_child;
                while (it) |c| : (it = c.next_sibling) {
                    const n = nodeOf(c) orelse continue;
                    if (local < at) break;
                    const len = n.totalMs();
                    n.seek(local - at);
                    at += len orelse break;
                }
            },
            .parallel => {
                var it = self.item.first_child;
                while (it) |c| : (it = c.next_sibling) {
                    const n = nodeOf(c) orelse continue;
                    const len = n.totalMs();
                    n.seek(if (len) |l| @min(local, l) else local);
                }
            },
        }
    }

    fn nodeOf(item: *Item) ?*Node {
        inline for (.{ &property_vtable, &pause_vtable, &sequential_vtable, &parallel_vtable }) |v| {
            if (item.vtable == v) return @alignCast(@fieldParentPtr("item", item));
        }
        return null;
    }

    const property_vtable: item_mod.ItemVTable = .{ .name = "PropertyAnimation" };
    const pause_vtable: item_mod.ItemVTable = .{ .name = "PauseAnimation" };
    const sequential_vtable: item_mod.ItemVTable = .{ .name = "SequentialAnimation" };
    const parallel_vtable: item_mod.ItemVTable = .{ .name = "ParallelAnimation" };

    fn vtableFor(kind: Kind) *const item_mod.ItemVTable {
        return switch (kind) {
            .property => &property_vtable,
            .pause => &pause_vtable,
            .sequential => &sequential_vtable,
            .parallel => &parallel_vtable,
        };
    }
};

/// An animation element of `kind`: its `node`, with the functions `.zge`
/// calls (`start()`, `stop()`, `pause()`, `resume()`). Initialize in
/// place with `init`.
pub fn Animation(comptime kind: Kind) type {
    return struct {
        const Self = @This();
        node: Node = undefined,

        pub fn init(self: *Self, gpa: Allocator) void {
            self.node.init(gpa, kind);
        }

        pub fn deinit(self: *Self) void {
            self.node.deinit();
        }

        pub fn start(self: *Self) void {
            self.node.start();
        }

        pub fn stop(self: *Self) void {
            self.node.stop();
        }

        pub fn pause(self: *Self) void {
            self.node.pause();
        }

        /// `resume()` in `.zge`.
        pub fn resumeAnimation(self: *Self) void {
            self.node.@"resume"();
        }
    };
}

pub const PropertyAnimation = Animation(.property);
pub const PauseAnimation = Animation(.pause);
pub const SequentialAnimation = Animation(.sequential);
pub const ParallelAnimation = Animation(.parallel);

// ---- Tests ----

const testing = std.testing;
const core = @import("core.zig");

/// A float animated from `from` (or where it is) to `to`.
const Slot = struct {
    value: f32 = 0,
    from: ?f32 = null,
    to: f32 = 0,
    a: f32 = 0,
    b: f32 = 0,
    begins: usize = 0,

    fn begin(self: *Slot) void {
        self.a = self.from orelse self.value;
        self.b = self.to;
        self.begins += 1;
    }
    fn apply(self: *Slot, t: f32) void {
        self.value = self.a + (self.b - self.a) * t;
    }
};

fn advanceTo(now: *u64, ms: u64) void {
    now.* += ms;
    core.updateTimersAndAnimations(now.*);
    core.runChangeHandlers();
}

test "a sequence of property animations and a pause, then in parallel, looping" {
    var seq: SequentialAnimation = .{};
    seq.init(testing.allocator);
    defer seq.deinit();
    var first: PropertyAnimation = .{};
    first.init(testing.allocator);
    defer first.deinit();
    var gap: PauseAnimation = .{};
    gap.init(testing.allocator);
    defer gap.deinit();
    var second: PropertyAnimation = .{};
    second.init(testing.allocator);
    defer second.deinit();
    seq.node.item.appendChildren(&.{ &first.node.item, &gap.node.item, &second.node.item });

    var x: Slot = .{ .to = 100 };
    var y: Slot = .{ .from = 10, .to = 20, .value = 5 };
    first.node.setTarget(&x, Slot.begin, Slot.apply);
    first.node.duration_ms.set(100);
    gap.node.duration_ms.set(50);
    second.node.setTarget(&y, Slot.begin, Slot.apply);
    second.node.duration_ms.set(100);

    var now = time.now();
    var finished: usize = 0;
    seq.node.finished.setHandler(&finished, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);
    seq.start();
    try testing.expect(seq.node.running.get());
    advanceTo(&now, 50);
    try testing.expectApproxEqAbs(@as(f32, 50), x.value, 1);
    try testing.expectEqual(@as(f32, 5), y.value); // not started
    advanceTo(&now, 80); // 130: in the pause, the first done
    try testing.expectEqual(@as(f32, 100), x.value);
    try testing.expectEqual(@as(f32, 5), y.value);
    advanceTo(&now, 70); // 200: half the second, from its own start
    try testing.expectApproxEqAbs(@as(f32, 15), y.value, 0.5);
    advanceTo(&now, 100); // past the end
    try testing.expectEqual(@as(f32, 20), y.value);
    try testing.expect(!seq.node.running.get());
    try testing.expectEqual(@as(usize, 1), finished);

    // Stopped where it is; paused and resumed later.
    x.value = 0;
    seq.start();
    advanceTo(&now, 50);
    seq.pause();
    const held = x.value;
    advanceTo(&now, 500);
    try testing.expectEqual(held, x.value);
    seq.resumeAnimation();
    advanceTo(&now, 25);
    try testing.expectApproxEqAbs(held + 25, x.value, 1.5);
    seq.stop();
    advanceTo(&now, 100);
    try testing.expectApproxEqAbs(held + 25, x.value, 1.5);
    try testing.expectEqual(@as(usize, 1), finished);
}

test "parallel animations, loops, and running set from a binding" {
    var par: ParallelAnimation = .{};
    par.init(testing.allocator);
    defer par.deinit();
    var a: PropertyAnimation = .{};
    a.init(testing.allocator);
    defer a.deinit();
    var b: PropertyAnimation = .{};
    b.init(testing.allocator);
    defer b.deinit();
    par.node.item.appendChildren(&.{ &a.node.item, &b.node.item });
    var x: Slot = .{ .from = 0, .to = 100 };
    var y: Slot = .{ .from = 0, .to = 10 };
    a.node.setTarget(&x, Slot.begin, Slot.apply);
    a.node.duration_ms.set(100);
    b.node.setTarget(&y, Slot.begin, Slot.apply);
    b.node.duration_ms.set(50);
    par.node.loops.set(2);

    var now = time.now();
    par.node.running.set(true);
    core.runChangeHandlers();
    advanceTo(&now, 50);
    try testing.expectApproxEqAbs(@as(f32, 50), x.value, 1);
    try testing.expectEqual(@as(f32, 10), y.value); // done, held
    advanceTo(&now, 75); // 125: the second run
    try testing.expectApproxEqAbs(@as(f32, 25), x.value, 1);
    try testing.expect(par.node.running.get());
    advanceTo(&now, 100);
    try testing.expect(!par.node.running.get());
    try testing.expectEqual(@as(f32, 100), x.value);
    try testing.expectEqual(@as(usize, 1), x.begins); // captured once per start

    // Forever: still running long after.
    par.node.loops.set(-1);
    par.start();
    advanceTo(&now, 10_000);
    try testing.expect(par.node.running.get());
    par.node.running.set(false);
    core.runChangeHandlers();
    try testing.expect(!par.node.running.get());
}
