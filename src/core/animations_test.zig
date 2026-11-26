// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const core = @import("core.zig");
const Property = core.Property;
const Animation = core.Animation;

const gpa = testing.allocator;

/// The clock is shared by all tests on this thread, so tests work relative
/// to the time at which they start.
fn at(base: u64, offset: u64) void {
    core.updateTimersAndAnimations(base + offset);
}

const linear_1s: Animation = .{ .duration_ms = 1000 };

test "setAnimated interpolates over time and then goes idle" {
    const t0 = core.now();
    var p: Property(f32) = .init(0);
    defer p.deinit();

    try p.setAnimated(gpa, 100, linear_1s);
    try testing.expectEqual(@as(f32, 0), p.get());
    try testing.expect(core.hasActiveAnimations());

    at(t0, 250);
    try testing.expectEqual(@as(f32, 25), p.get());
    at(t0, 999);
    try testing.expectApproxEqAbs(@as(f32, 99.9), p.get(), 1e-3);
    at(t0, 1000);
    try testing.expectEqual(@as(f32, 100), p.get());
    try testing.expect(!core.hasActiveAnimations());
}

test "retargeting mid-animation continues from the in-flight value" {
    const t0 = core.now();
    var p: Property(f32) = .init(0);
    defer p.deinit();

    try p.setAnimated(gpa, 100, linear_1s);
    at(t0, 500);
    try p.setAnimated(gpa, 0, linear_1s); // from 50 back to 0
    try testing.expectEqual(@as(f32, 50), p.get());
    at(t0, 1000);
    try testing.expectEqual(@as(f32, 25), p.get());
    at(t0, 1500);
    try testing.expectEqual(@as(f32, 0), p.get());
}

test "set cancels a running animation" {
    const t0 = core.now();
    var p: Property(i32) = .init(0);
    defer p.deinit();
    try p.setAnimated(gpa, 100, linear_1s);
    at(t0, 300);
    p.set(-1);
    at(t0, 600);
    try testing.expectEqual(@as(i32, -1), p.get());
    try testing.expect(!core.hasActiveAnimations());
}

test "instant animation and unchanged value do not animate" {
    var p: Property(f32) = .init(5);
    defer p.deinit();
    try p.setAnimated(gpa, 7, .{});
    try testing.expectEqual(@as(f32, 7), p.get());
    try testing.expect(!p.hasBinding());
    try p.setAnimated(gpa, 7, linear_1s);
    try testing.expect(!p.hasBinding());
}

const Box = struct {
    expanded: Property(bool) = .init(false),
    width: Property(f32) = .init(0),
    area: Property(f32) = .init(0),

    fn targetWidth(self: *Box) f32 {
        return if (self.expanded.get()) 300 else 100;
    }
    fn computeArea(self: *Box) f32 {
        return self.width.get() * 2;
    }
    fn deinit(self: *Box) void {
        self.area.deinit();
        self.width.deinit();
        self.expanded.deinit();
    }
};

test "animated binding animates changes but not the initial value" {
    const t0 = core.now();
    var b: Box = .{};
    defer b.deinit();
    try b.width.setAnimatedBinding(gpa, &b, Box.targetWidth, .{ .duration_ms = 200, .easing = .ease_in_out });
    try b.area.setBinding(gpa, &b, Box.computeArea);

    try testing.expectEqual(@as(f32, 100), b.width.get());
    try testing.expectEqual(@as(f32, 200), b.area.get());
    try testing.expect(!core.hasActiveAnimations());

    b.expanded.set(true);
    try testing.expectEqual(@as(f32, 100), b.width.get());
    at(t0, 100); // halfway: ease-in-out is symmetric
    try testing.expectApproxEqAbs(@as(f32, 200), b.width.get(), 0.05);
    try testing.expectApproxEqAbs(@as(f32, 400), b.area.get(), 0.1); // dependents follow each frame
    at(t0, 200);
    try testing.expectEqual(@as(f32, 300), b.width.get());
    try testing.expectEqual(@as(f32, 600), b.area.get());
    try testing.expect(!core.hasActiveAnimations());

    // Animations start when the binding is next evaluated (normally the
    // next frame), so read once right after the change, as a render would.
    b.expanded.set(false);
    try testing.expectEqual(@as(f32, 300), b.width.get());
    at(t0, 250);
    try testing.expect(b.width.get() < 300);
    try testing.expect(core.hasActiveAnimations());
    at(t0, 400);
    try testing.expectEqual(@as(f32, 100), b.width.get());
}

test "infinite animation keeps the clock busy" {
    const t0 = core.now();
    var p: Property(f32) = .init(0);
    defer p.deinit();
    try p.setAnimated(gpa, 1, .{ .duration_ms = 100, .iterations = null, .direction = .alternate });
    at(t0, 150);
    try testing.expectEqual(@as(f32, 0.5), p.get());
    at(t0, 10_000);
    try testing.expectEqual(@as(f32, 0), p.get());
    try testing.expect(core.hasActiveAnimations());
    p.set(0);
    try testing.expect(!core.hasActiveAnimations());
}

test "animated struct values" {
    const t0 = core.now();
    const Point = struct { x: f32, y: f32 };
    var p: Property(Point) = .init(.{ .x = 0, .y = 0 });
    defer p.deinit();
    try p.setAnimated(gpa, .{ .x = 10, .y = -10 }, .{ .duration_ms = 100 });
    at(t0, 50);
    try testing.expectEqual(Point{ .x = 5, .y = -5 }, p.get());
}

test "timer drives an animation" {
    const t0 = core.now();
    const Blink = struct {
        on: Property(bool) = .init(false),
        opacity: Property(f32) = .init(0),
        timer: core.Timer = .{},
        fn toggle(self: *@This()) void {
            self.on.set(!self.on.getUntracked());
        }
        fn target(self: *@This()) f32 {
            return if (self.on.get()) 1 else 0;
        }
    };
    var b: Blink = .{};
    defer {
        b.timer.deinit();
        b.opacity.deinit();
        b.on.deinit();
    }
    try b.opacity.setAnimatedBinding(gpa, &b, Blink.target, .{ .duration_ms = 100 });
    try testing.expectEqual(@as(f32, 0), b.opacity.get());
    b.timer.start(.repeated, 500, &b, Blink.toggle);

    at(t0, 500); // timer fires, animation to 1 starts
    try testing.expectEqual(@as(f32, 0), b.opacity.get());
    at(t0, 550);
    try testing.expectEqual(@as(f32, 0.5), b.opacity.get());
    at(t0, 1000); // fires again: animate back to 0
    try testing.expectEqual(@as(f32, 1), b.opacity.get());
    at(t0, 1100);
    try testing.expectEqual(@as(f32, 0), b.opacity.get());
    try testing.expectEqual(t0 + 1500, core.nextTimerDeadline().?);
}

test "a spring retargeted while it moves keeps its speed" {
    const spring: Animation = .{ .duration_ms = 1000, .easing = .{ .spring = 0.2 } };
    const t0 = core.now();
    var p: Property(f32) = .init(0);
    defer p.deinit();
    try p.setAnimated(gpa, 100, spring);
    at(t0, 96);
    const a = p.get();
    at(t0, 100);
    const b = p.get();
    // Further on: from where it is, as fast as it was going.
    try p.setAnimated(gpa, 300, spring);
    try testing.expectApproxEqAbs(b, p.get(), 1e-3);
    at(t0, 104);
    const c = p.get();
    try testing.expect(b - a > 1);
    try testing.expectApproxEqRel(b - a, c - b, 0.15);
    // And settles at the new target.
    at(t0, 1100);
    try testing.expectEqual(@as(f32, 300), p.get());
    try testing.expect(!core.hasActiveAnimations());
}

test "a spring turned back while it moves slows down first" {
    const spring: Animation = .{ .duration_ms = 1000, .easing = .{ .spring = 0 } };
    const t0 = core.now();
    var p: Property(f32) = .init(0);
    defer p.deinit();
    try p.setAnimated(gpa, 100, spring);
    at(t0, 100);
    const turned_at = p.get();
    try p.setAnimated(gpa, 0, spring);
    // Still going up for a while (from rest, it would head down at once).
    at(t0, 110);
    try testing.expect(p.get() > turned_at);
}

test "a spring's carry starts at the speed it is given" {
    for ([_]f32{ 0, 0.3, 0.8 }) |bounce| {
        const dt = 1e-4;
        try testing.expectApproxEqRel(@as(f32, 1), @import("animations.zig").springCarry(bounce, dt) / dt, 0.05);
        try testing.expectEqual(@as(f32, 0), @import("animations.zig").springCarry(bounce, 1));
    }
}

test "an animated binding's spring keeps its speed when what it follows changes" {
    const spring: Animation = .{ .duration_ms = 1000, .easing = .{ .spring = 0 } };
    const t0 = core.now();
    var target: Property(f32) = .init(0);
    defer target.deinit();
    var p: Property(f32) = .init(0);
    defer p.deinit();
    try p.setAnimatedBinding(gpa, &target, struct {
        fn f(t: *Property(f32)) f32 {
            return t.get();
        }
    }.f, spring);
    _ = p.get();
    target.set(100);
    _ = p.get();
    at(t0, 100);
    const turned_at = p.get();
    target.set(0);
    _ = p.get();
    at(t0, 110);
    try testing.expect(p.get() > turned_at);
}
