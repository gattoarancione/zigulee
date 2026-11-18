// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Touches and gestures: backends report each finger (`dispatchTouch`) and
//! trackpad gestures (`dispatchTrackpad`). One finger works as the mouse
//! (buttons, lists, drags); a second one over a `PinchArea` makes a pinch
//! (scale and rotation, about the fingers' middle). A `SwipeArea` reports
//! a quick drag (of the mouse or a finger) left, right, up or down,
//! without taking clicks from what is in it.

const std = @import("std");
const Property = @import("properties.zig").Property;
const Callback = @import("callbacks.zig").Callback;
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Rect = geometry.Rect;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const ItemVTable = item_mod.ItemVTable;
const input = @import("input.zig");
const Window = @import("window.zig").Window;

pub const TouchPhase = enum { down, moved, up, cancelled };

/// What a window knows of the fingers on it.
pub const TouchState = struct {
    const max = 10;
    points: [max]struct { id: u64 = 0, at: Point = .{}, down: bool = false } = @splat(.{}),
    /// The finger working as the mouse.
    primary: ?u64 = null,
    /// A pinch: its area, its fingers, how far apart and at what angle they
    /// started.
    pinch: ?*PinchArea = null,
    fingers: [2]u64 = .{ 0, 0 },
    start_distance: f32 = 1,
    start_angle: f32 = 0,
    /// A trackpad gesture's area.
    trackpad: ?*PinchArea = null,

    fn find(s: *TouchState, id: u64) ?usize {
        for (&s.points, 0..) |*p, i| if (p.down and p.id == id) return i;
        return null;
    }

    fn count(s: *const TouchState) usize {
        var n: usize = 0;
        for (s.points) |p| n += @intFromBool(p.down);
        return n;
    }

    fn at(s: *TouchState, id: u64) Point {
        return s.points[s.find(id).?].at;
    }
};

/// A finger `id` touched, moved on, left or was taken from the window
/// (`at`: window coordinates).
pub fn dispatchTouch(w: *Window, id: u64, phase: TouchPhase, at: Point) void {
    const s = &w.touch;
    // Activity, unless the finger goes on as the pointer (which tells it).
    var as_pointer = false;
    defer if (!as_pointer) w.input_activity.call(.{});
    switch (phase) {
        .down => {
            const slot = for (&s.points) |*p| {
                if (!p.down) break p;
            } else return;
            slot.* = .{ .id = id, .at = at, .down = true };
            if (s.pinch != null) return;
            if (s.count() == 2) {
                // Two fingers: a pinch, if over a PinchArea.
                var other: u64 = 0;
                for (s.points) |p| if (p.down and p.id != id) {
                    other = p.id;
                };
                const a = s.at(other);
                const middle: Point = .{ .x = (a.x + at.x) / 2, .y = (a.y + at.y) / 2 };
                if (pinchAreaAt(&w.root.item, middle)) |area| {
                    if (s.primary != null) w.cancelPointer();
                    s.primary = null;
                    s.pinch = area;
                    s.fingers = .{ other, id };
                    s.start_distance = @max(distance(a, at), 1);
                    s.start_angle = angle(a, at);
                    area.begin(middle);
                    return;
                }
            }
            if (s.primary == null and s.count() == 1) {
                s.primary = id;
                as_pointer = true;
                w.dispatchPointer(.{ .pressed = .{ .position = at } });
            }
        },
        .moved => {
            const i = s.find(id) orelse return;
            s.points[i].at = at;
            if (s.pinch) |area| {
                if (id != s.fingers[0] and id != s.fingers[1]) return;
                const a = s.at(s.fingers[0]);
                const b = s.at(s.fingers[1]);
                area.update(distance(a, b) / s.start_distance, std.math.radiansToDegrees(angle(a, b) - s.start_angle), .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 });
            } else if (s.primary == id) {
                as_pointer = true;
                w.dispatchPointer(.{ .moved = .{ .position = at } });
            }
        },
        .up, .cancelled => {
            const i = s.find(id) orelse return;
            s.points[i].down = false;
            if (s.pinch) |area| {
                if (id == s.fingers[0] or id == s.fingers[1]) {
                    s.pinch = null;
                    area.end();
                }
            } else if (s.primary == id) {
                s.primary = null;
                if (phase == .up) {
                    as_pointer = true;
                    w.dispatchPointer(.{ .released = .{ .position = at } });
                } else w.cancelPointer();
            }
        },
    }
}

pub const TrackpadPhase = enum { began, changed, ended };

/// A trackpad pinch or rotation (macOS): `magnify` grows the scale by that
/// fraction, `rotate` turns by that many degrees (clockwise), at `at`.
pub fn dispatchTrackpad(w: *Window, phase: TrackpadPhase, magnify: f32, rotate: f32, at: Point) void {
    const s = &w.touch;
    w.input_activity.call(.{});
    switch (phase) {
        .began => {
            if (s.trackpad) |area| area.end();
            s.trackpad = pinchAreaAt(&w.root.item, at);
            if (s.trackpad) |area| area.begin(at);
        },
        .changed => {
            const area = s.trackpad orelse return;
            area.update(area.scale.getUntracked() * (1 + magnify), area.rotation.getUntracked() + rotate, at);
        },
        .ended => {
            const area = s.trackpad orelse return;
            s.trackpad = null;
            area.end();
        },
    }
}

fn distance(a: Point, b: Point) f32 {
    return @sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y));
}

fn angle(a: Point, b: Point) f32 {
    return std.math.atan2(b.y - a.y, b.x - a.x);
}

/// Scaled and turned by two fingers (or a trackpad): `scale` (1 at the
/// start) and `rotation` (degrees, clockwise; `pinch-scale` and
/// `pinch-rotation` in `.zge`) follow them while `active`,
/// about `center-x`, `center-y` (its coordinates). `started`, `updated`
/// and `finished` mark the gesture. Draws nothing.
pub const PinchArea = struct {
    item: Item = .init(&vtable),
    enabled: Property(bool) = .init(true),
    active: Property(bool) = .init(false),
    scale: Property(f32) = .init(1),
    rotation: Property(f32) = .init(0),
    center_x: Property(f32) = .init(0),
    center_y: Property(f32) = .init(0),
    started: Callback(fn () void) = .{},
    updated: Callback(fn () void) = .{},
    finished: Callback(fn () void) = .{},

    pub fn deinit(self: *PinchArea) void {
        if (self.item.window()) |w| {
            if (w.touch.pinch == self) w.touch.pinch = null;
            if (w.touch.trackpad == self) w.touch.trackpad = null;
        }
        self.item.deinit();
        self.enabled.deinit();
        self.active.deinit();
        self.scale.deinit();
        self.rotation.deinit();
        self.center_x.deinit();
        self.center_y.deinit();
    }

    const vtable: ItemVTable = .{ .name = "PinchArea" };

    fn setCenter(self: *PinchArea, at: Point) void {
        const local = self.item.fromWindow(at);
        self.center_x.set(local.x);
        self.center_y.set(local.y);
    }

    fn begin(self: *PinchArea, at: Point) void {
        self.scale.set(1);
        self.rotation.set(0);
        self.setCenter(at);
        self.active.set(true);
        self.started.call(.{});
    }

    fn update(self: *PinchArea, scale: f32, rotation: f32, at: Point) void {
        self.scale.set(scale);
        self.rotation.set(rotation);
        self.setCenter(at);
        self.updated.call(.{});
    }

    fn end(self: *PinchArea) void {
        self.active.set(false);
        self.finished.call(.{});
    }
};

/// The topmost enabled PinchArea at `p` (window coordinates).
fn pinchAreaAt(item: *Item, p: Point) ?*PinchArea {
    if (!item.visible.get()) return null;
    var found: ?*PinchArea = null;
    var it = item.first_child;
    while (it) |c| : (it = c.next_sibling) {
        if (pinchAreaAt(c, p)) |a| found = a;
    }
    if (found) |a| return a;
    if (item.vtable != &PinchArea.vtable) return null;
    const self: *PinchArea = @fieldParentPtr("item", item);
    if (!self.enabled.get()) return null;
    const local = item.fromWindow(p);
    if (!(Rect{ .width = item.width.get(), .height = item.height.get() }).contains(local)) return null;
    return self;
}

pub const SwipeDirection = enum { left, right, up, down };

/// Reports a quick drag over it, of the mouse or a finger: `swiped(dir)`
/// once it went `distance` (40 px by default) mostly one way. While
/// dragging, `swiping` and `offset-x`, `offset-y` (from the press) follow
/// it, for what shows the swipe. A press that does not move goes to what
/// is in it (buttons still click). Draws nothing.
pub const SwipeArea = struct {
    item: Item = .init(&vtable),
    enabled: Property(bool) = .init(true),
    distance: Property(f32) = .init(40),
    swiping: Property(bool) = .init(false),
    offset_x: Property(f32) = .init(0),
    offset_y: Property(f32) = .init(0),
    swiped: Callback(fn (SwipeDirection) void) = .{},

    state: enum { idle, pressed, swiping } = .idle,
    press: Point = .{},

    /// How far a press moves before it is a swipe (and not a click).
    const start_distance = 8;

    pub fn deinit(self: *SwipeArea) void {
        self.item.deinit();
        self.enabled.deinit();
        self.distance.deinit();
        self.swiping.deinit();
        self.offset_x.deinit();
        self.offset_y.deinit();
    }

    const vtable: ItemVTable = .{ .name = "SwipeArea", .inputEvent = inputEvent, .inputEventFilter = inputEventFilter };

    fn of(i: *Item) *SwipeArea {
        return @fieldParentPtr("item", i);
    }

    fn moved(self: *SwipeArea, p: Point) bool {
        return @abs(p.x - self.press.x) >= start_distance or @abs(p.y - self.press.y) >= start_distance;
    }

    /// What is in it gets the press; once it moves, the swipe takes over.
    fn inputEventFilter(i: *Item, event: input.PointerEvent, _: *Window) input.InputEventFilterResult {
        const self = of(i);
        if (!self.enabled.get()) return .forward_and_ignore;
        switch (event) {
            .pressed => |p| {
                if (p.button != .left) return .forward_and_ignore;
                self.state = .pressed;
                self.press = p.position;
                return .forward_and_intercept_grab;
            },
            .moved => |m| switch (self.state) {
                .idle => return .forward_and_ignore,
                .pressed => {
                    if (!self.moved(m.position)) return .forward_and_intercept_grab;
                    self.state = .swiping;
                    return .intercept;
                },
                .swiping => return .intercept,
            },
            .released => {
                if (self.state == .swiping) return .intercept;
                self.state = .idle;
                return .forward_and_ignore;
            },
            .wheel, .exit => return .forward_and_ignore,
        }
    }

    fn inputEvent(i: *Item, event: input.PointerEvent, _: *Window) input.InputEventResult {
        const self = of(i);
        if (!self.enabled.get()) return .ignored;
        switch (event) {
            .pressed => |p| {
                if (p.button != .left) return .ignored;
                self.state = .pressed;
                self.press = p.position;
                return .grab;
            },
            .moved => |m| {
                if (self.state == .idle) return .ignored;
                if (self.state == .pressed and self.moved(m.position)) self.state = .swiping;
                if (self.state == .swiping) {
                    if (!self.swiping.get()) self.swiping.set(true);
                    self.offset_x.set(m.position.x - self.press.x);
                    self.offset_y.set(m.position.y - self.press.y);
                }
                return .grab;
            },
            .released => |r| {
                const was = self.state;
                self.reset();
                if (was != .swiping) return .accepted;
                const dx = r.position.x - self.press.x;
                const dy = r.position.y - self.press.y;
                const far = self.distance.get();
                if (@abs(dx) >= @abs(dy) and @abs(dx) >= far) {
                    self.swiped.call(.{if (dx < 0) SwipeDirection.left else SwipeDirection.right});
                } else if (@abs(dy) > @abs(dx) and @abs(dy) >= far) {
                    self.swiped.call(.{if (dy < 0) SwipeDirection.up else SwipeDirection.down});
                }
                return .accepted;
            },
            .exit => {
                self.reset();
                return .accepted;
            },
            .wheel => return .ignored,
        }
    }

    fn reset(self: *SwipeArea) void {
        self.state = .idle;
        if (self.swiping.getUntracked()) self.swiping.set(false);
        self.offset_x.set(0);
        self.offset_y.set(0);
    }
};

// ---- Tests ----

const testing = std.testing;
const core = @import("core.zig");

test "one finger works as the mouse; two over a pinch area pinch and turn" {
    var w: Window = undefined;
    w.init(testing.allocator, .{ .width = 200, .height = 200 });
    defer w.deinit();
    var pinch: PinchArea = .{};
    defer pinch.deinit();
    var button: core.items.TouchArea = .{};
    defer button.deinit();
    w.rootItem().appendChildren(&.{ &pinch.item, &button.item });
    pinch.item.setGeometry(.{ .width = 200, .height = 150 });
    button.item.setGeometry(.{ .y = 150, .width = 200, .height = 50 });
    var clicks: usize = 0;
    button.clicked.setHandler(&clicks, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);

    // A tap on the button clicks it.
    dispatchTouch(&w, 1, .down, .{ .x = 100, .y = 175 });
    dispatchTouch(&w, 1, .up, .{ .x = 100, .y = 175 });
    try testing.expectEqual(@as(usize, 1), clicks);

    // Two fingers 40 px apart, then 80, and turned a quarter.
    dispatchTouch(&w, 2, .down, .{ .x = 80, .y = 50 });
    dispatchTouch(&w, 3, .down, .{ .x = 120, .y = 50 });
    try testing.expect(pinch.active.get());
    try testing.expectEqual(@as(f32, 100), pinch.center_x.get());
    dispatchTouch(&w, 3, .moved, .{ .x = 160, .y = 50 });
    try testing.expectApproxEqAbs(@as(f32, 2), pinch.scale.get(), 0.001);
    dispatchTouch(&w, 3, .moved, .{ .x = 80, .y = 90 });
    try testing.expectApproxEqAbs(@as(f32, 90), pinch.rotation.get(), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), pinch.scale.get(), 0.001);
    dispatchTouch(&w, 2, .up, .{ .x = 80, .y = 50 });
    try testing.expect(!pinch.active.get());
    dispatchTouch(&w, 3, .up, .{ .x = 80, .y = 90 });

    // A trackpad pinch: 10% larger, twice; turned 5 degrees.
    dispatchTrackpad(&w, .began, 0, 0, .{ .x = 50, .y = 50 });
    dispatchTrackpad(&w, .changed, 0.1, 0, .{ .x = 50, .y = 50 });
    dispatchTrackpad(&w, .changed, 0.1, 5, .{ .x = 50, .y = 50 });
    try testing.expectApproxEqAbs(@as(f32, 1.21), pinch.scale.get(), 0.001);
    try testing.expectEqual(@as(f32, 5), pinch.rotation.get());
    dispatchTrackpad(&w, .ended, 0, 0, .{ .x = 50, .y = 50 });
    try testing.expect(!pinch.active.get());
}

test "a swipe over what still takes clicks" {
    var w: Window = undefined;
    w.init(testing.allocator, .{ .width = 200, .height = 100 });
    defer w.deinit();
    var swipe: SwipeArea = .{};
    defer swipe.deinit();
    var button: core.items.TouchArea = .{};
    defer button.deinit();
    w.rootItem().appendChild(&swipe.item);
    swipe.item.appendChild(&button.item);
    swipe.item.setGeometry(.{ .width = 200, .height = 100 });
    button.item.setGeometry(.{ .width = 200, .height = 100 });
    const Log = struct {
        clicks: usize = 0,
        dir: ?SwipeDirection = null,
        fn click(self: *@This()) void {
            self.clicks += 1;
        }
        fn swiped(self: *@This(), d: SwipeDirection) void {
            self.dir = d;
        }
    };
    var log: Log = .{};
    button.clicked.setHandler(&log, Log.click);
    swipe.swiped.setHandler(&log, Log.swiped);

    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 100, .y = 50 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 102, .y = 51 } } });
    try testing.expectEqual(@as(usize, 1), log.clicks);
    try testing.expectEqual(@as(?SwipeDirection, null), log.dir);

    // Left, by a finger (the mouse it works as).
    dispatchTouch(&w, 7, .down, .{ .x = 150, .y = 50 });
    dispatchTouch(&w, 7, .moved, .{ .x = 120, .y = 52 });
    try testing.expect(swipe.swiping.get());
    try testing.expectEqual(@as(f32, -30), swipe.offset_x.get());
    dispatchTouch(&w, 7, .moved, .{ .x = 60, .y = 55 });
    dispatchTouch(&w, 7, .up, .{ .x = 60, .y = 55 });
    try testing.expectEqual(@as(?SwipeDirection, .left), log.dir);
    try testing.expectEqual(@as(usize, 1), log.clicks); // not a click
    try testing.expect(!swipe.swiping.get());

    // Too short: no swipe.
    log.dir = null;
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 100, .y = 50 } } });
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = 100, .y = 70 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 100, .y = 70 } } });
    try testing.expectEqual(@as(?SwipeDirection, null), log.dir);
}
