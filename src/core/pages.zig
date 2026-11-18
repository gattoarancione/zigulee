// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Pages and flows: `StackLayout` (one of its children shown), `SwipeView`
//! (its children side by side, swiped from one to the next), `StackView`
//! (pages pushed and popped, sliding in and out) and `FlowLayout` (its
//! children in rows, wrapping).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const ChangeTracker = @import("properties.zig").ChangeTracker;
const Callback = @import("callbacks.zig").Callback;
const Timer = @import("timers.zig").Timer;
const time = @import("time.zig");
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Size = geometry.Size;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const ItemVTable = item_mod.ItemVTable;
const layout = @import("layout.zig");
const LayoutInfo = layout.LayoutInfo;
const Orientation = layout.Orientation;
const input = @import("input.zig");
const Window = @import("window.zig").Window;
const animations = @import("animations.zig");
const loader = @import("loader.zig");

const log = std.log.scoped(.zigulee_pages);

/// The largest of the children's constraints (a page shows any of them).
fn childrenInfo(item: *Item, o: Orientation) LayoutInfo {
    var info: LayoutInfo = .{};
    var children = item.layoutChildren();
    while (children.next()) |c| info = info.merge(c.layoutInfo(o));
    return info;
}

fn Ref(comptime L: type) type {
    return struct { layout: *L, index: u32 };
}

/// Shows the child at `current-index` (the others are hidden: their
/// visibility is the layout's), each filling it. It takes the largest of
/// their constraints. Append the children, then call `setup`.
pub const StackLayout = struct {
    item: Item = .init(&vtable),
    current_index: Property(i32) = .init(0),
    count: Property(i32) = .init(0),
    gpa: ?Allocator = null,

    pub fn deinit(self: *StackLayout) void {
        self.item.deinit();
        self.current_index.deinit();
        self.count.deinit();
    }

    pub fn setup(self: *StackLayout, gpa: Allocator) Allocator.Error!void {
        self.gpa = gpa;
        var children = self.item.layoutChildren();
        var i: u32 = 0;
        while (children.next()) |c| : (i += 1) {
            const r: Ref(StackLayout) = .{ .layout = self, .index = i };
            c.x.set(0);
            c.y.set(0);
            try c.width.setBinding(gpa, r, width);
            try c.height.setBinding(gpa, r, height);
            try c.visible.setBinding(gpa, r, shown);
        }
        self.count.set(@intCast(i));
    }

    fn width(r: Ref(StackLayout)) f32 {
        return r.layout.item.width.get();
    }
    fn height(r: Ref(StackLayout)) f32 {
        return r.layout.item.height.get();
    }
    fn shown(r: Ref(StackLayout)) bool {
        return r.layout.current_index.get() == r.index;
    }

    fn layoutInfo(i: *Item, o: Orientation) LayoutInfo {
        return childrenInfo(i, o);
    }

    fn childrenChanged(i: *Item) void {
        const self: *StackLayout = @fieldParentPtr("item", i);
        if (self.gpa) |gpa| self.setup(gpa) catch log.err("out of memory laying out pages", .{});
    }

    const vtable: ItemVTable = .{ .name = "StackLayout", .layoutInfo = layoutInfo, .childrenChanged = childrenChanged, .is_layout = true };
};

/// Its children side by side (or one above the other, `vertical`), each
/// filling it, one shown: `current-index`. A drag along them (of the mouse
/// or a finger) moves between them; let go, it settles on the nearest one
/// (or the next, if dragged far enough).
/// Setting `current-index` slides there. Append the children, then call
/// `setup`. Initialize in place with `init`.
pub const SwipeView = struct {
    item: Item = .init(&vtable),
    current_index: Property(i32) = .init(0),
    count: Property(i32) = .init(0),
    interactive: Property(bool) = .init(true),
    /// Where it is, in pages (2.5: halfway from the third to the fourth).
    position: Property(f32) = .init(0),
    /// The pages left to right, or top to bottom.
    orientation: Property(Orientation) = .init(.horizontal),

    gpa: Allocator = undefined,
    set_up: bool = false,
    tracker: ChangeTracker(i32) = undefined,
    state: enum { idle, pressed, dragging } = .idle,
    press: Point = .{},
    press_position: f32 = 0,

    const start_distance = 8;
    const slide: animations.Animation = .{ .duration_ms = 250, .easing = .ease_out };

    pub fn init(self: *SwipeView, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.tracker.init(gpa, self, index, slideTo);
    }

    pub fn deinit(self: *SwipeView) void {
        self.tracker.deinit();
        self.item.deinit();
        self.current_index.deinit();
        self.count.deinit();
        self.interactive.deinit();
        self.position.deinit();
        self.orientation.deinit();
    }

    pub fn setup(self: *SwipeView, gpa: Allocator) Allocator.Error!void {
        self.gpa = gpa;
        self.set_up = true;
        var children = self.item.layoutChildren();
        var i: u32 = 0;
        while (children.next()) |c| : (i += 1) {
            const r: Ref(SwipeView) = .{ .layout = self, .index = i };
            try c.x.setBinding(gpa, r, childX);
            try c.y.setBinding(gpa, r, childY);
            try c.width.setBinding(gpa, r, width);
            try c.height.setBinding(gpa, r, height);
        }
        self.count.set(@intCast(i));
        self.position.set(@floatFromInt(self.clamped(self.current_index.getUntracked())));
    }

    fn childX(r: Ref(SwipeView)) f32 {
        const l = r.layout;
        if (l.orientation.get() != .horizontal) return 0;
        return (@as(f32, @floatFromInt(r.index)) - l.position.get()) * l.item.width.get();
    }
    fn childY(r: Ref(SwipeView)) f32 {
        const l = r.layout;
        if (l.orientation.get() != .vertical) return 0;
        return (@as(f32, @floatFromInt(r.index)) - l.position.get()) * l.item.height.get();
    }

    /// How far `p` is from the press along the pages, and across them.
    fn travel(self: *SwipeView, p: Point) struct { f32, f32 } {
        const dx = p.x - self.press.x;
        const dy = p.y - self.press.y;
        return if (self.orientation.get() == .vertical) .{ dy, dx } else .{ dx, dy };
    }

    /// A page's length along them.
    fn pageLength(self: *SwipeView) f32 {
        return @max(if (self.orientation.get() == .vertical) self.item.height.get() else self.item.width.get(), 1);
    }
    fn width(r: Ref(SwipeView)) f32 {
        return r.layout.item.width.get();
    }
    fn height(r: Ref(SwipeView)) f32 {
        return r.layout.item.height.get();
    }

    fn clamped(self: *SwipeView, i: i32) i32 {
        return std.math.clamp(i, 0, @max(self.count.getUntracked() - 1, 0));
    }

    fn index(self: *SwipeView) i32 {
        return self.current_index.get();
    }

    fn slideTo(self: *SwipeView, i: i32) void {
        const target: f32 = @floatFromInt(self.clamped(i));
        self.position.setAnimated(self.gpa, target, slide) catch self.position.set(target);
    }

    fn layoutInfo(i: *Item, o: Orientation) LayoutInfo {
        return childrenInfo(i, o);
    }

    fn childrenChanged(i: *Item) void {
        const self: *SwipeView = @fieldParentPtr("item", i);
        if (self.set_up) self.setup(self.gpa) catch log.err("out of memory laying out pages", .{});
    }

    fn clips(_: *Item) bool {
        return true;
    }

    /// Its pages get presses; a drag along the pages is its.
    fn inputEventFilter(i: *Item, event: input.PointerEvent, _: *Window) input.InputEventFilterResult {
        const self: *SwipeView = @fieldParentPtr("item", i);
        if (!self.interactive.get()) return .forward_and_ignore;
        switch (event) {
            .pressed => |p| {
                if (p.button != .left) return .forward_and_ignore;
                self.begin(p.position);
                return .forward_and_intercept_grab;
            },
            .moved => |m| switch (self.state) {
                .idle => return .forward_and_ignore,
                .pressed => {
                    const along, const across = self.travel(m.position);
                    if (@abs(along) < start_distance or @abs(along) < @abs(across)) return .forward_and_intercept_grab;
                    self.state = .dragging;
                    return .intercept;
                },
                .dragging => return .intercept,
            },
            .released => {
                if (self.state == .dragging) return .intercept;
                self.state = .idle;
                return .forward_and_ignore;
            },
            .wheel, .exit => return .forward_and_ignore,
        }
    }

    fn begin(self: *SwipeView, at: Point) void {
        self.state = .pressed;
        self.press = at;
        self.press_position = self.position.getUntracked();
    }

    fn inputEvent(i: *Item, event: input.PointerEvent, _: *Window) input.InputEventResult {
        const self: *SwipeView = @fieldParentPtr("item", i);
        if (!self.interactive.get()) return .ignored;
        const w = self.pageLength();
        switch (event) {
            .pressed => |p| {
                if (p.button != .left) return .ignored;
                self.begin(p.position);
                return .grab;
            },
            .moved => |m| {
                if (self.state == .idle) return .ignored;
                const dx = self.travel(m.position)[0];
                if (self.state == .pressed and @abs(dx) >= start_distance) self.state = .dragging;
                if (self.state == .dragging) {
                    // Past the first and last pages: a little, resisting.
                    const last: f32 = @floatFromInt(@max(self.count.getUntracked() - 1, 0));
                    self.position.set(std.math.clamp(self.press_position - dx / w, -0.25, last + 0.25));
                }
                return .grab;
            },
            .released => |r| {
                const was = self.state;
                self.state = .idle;
                if (was != .dragging) return .accepted;
                const dx = self.travel(r.position)[0];
                const from: i32 = @intFromFloat(@round(self.press_position));
                // A fifth of a page is enough to go to the next.
                const to = if (dx < -w / 5) from + 1 else if (dx > w / 5) from - 1 else from;
                const next = self.clamped(to);
                if (next == self.current_index.getUntracked()) {
                    self.slideTo(next); // back where it was
                } else self.current_index.set(next);
                return .accepted;
            },
            .exit => {
                if (self.state == .dragging) self.slideTo(self.current_index.getUntracked());
                self.state = .idle;
                return .accepted;
            },
            .wheel => return .ignored,
        }
    }

    const vtable: ItemVTable = .{
        .name = "SwipeView",
        .layoutInfo = layoutInfo,
        .childrenChanged = childrenChanged,
        .clipsChildren = clips,
        .inputEvent = inputEvent,
        .inputEventFilter = inputEventFilter,
        .is_layout = true,
    };
};

/// Pages pushed on top of each other (`push(Page)`, a component) and popped
/// (`pop()`): the top one shows, sliding in from the right when pushed and
/// out to the right when popped. `initial-page` is the first one; one
/// always stays. Initialize in place with `init`.
pub const StackView = struct {
    item: Item = .init(&vtable),
    initial_page: Property(loader.Component) = .init(null),
    depth: Property(i32) = .init(0),
    /// A page is sliding in or out.
    busy: Property(bool) = .init(false),

    gpa: Allocator = undefined,
    pages: std.ArrayList(Page) = .empty,
    tracker: ChangeTracker(loader.Component) = undefined,
    timer: Timer = .{},
    /// A slide: pushing (the top page coming in) or popping (going out).
    slide: ?struct { push: bool, start_ms: u64 } = null,

    const Page = struct { factory: *const loader.ComponentFactory, instance: *anyopaque };
    const slide_ms = 250;

    pub fn init(self: *StackView, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.tracker.init(gpa, self, initialPage, initialChanged);
    }

    pub fn deinit(self: *StackView) void {
        self.timer.deinit();
        self.tracker.deinit();
        while (self.pages.items.len > 0) self.destroyTop();
        self.pages.deinit(self.gpa);
        self.item.deinit();
        self.initial_page.deinit();
        self.depth.deinit();
        self.busy.deinit();
    }

    fn initialPage(self: *StackView) loader.Component {
        return self.initial_page.get();
    }

    /// The first page: set, or replaced (with no slide).
    fn initialChanged(self: *StackView, c: loader.Component) void {
        self.finishSlide();
        while (self.pages.items.len > 0) self.destroyTop();
        if (c) |f| _ = self.add(f);
        self.layoutPages(0);
        self.depth.set(@intCast(self.pages.items.len));
    }

    /// Shows `c` on top, sliding in.
    pub fn push(self: *StackView, c: loader.Component) void {
        const f = c orelse return;
        self.finishSlide();
        if (!self.add(f)) return;
        self.depth.set(@intCast(self.pages.items.len));
        if (self.pages.items.len == 1) return self.layoutPages(0);
        self.startSlide(true);
    }

    /// Takes the top page off (sliding out), unless it is the only one.
    pub fn pop(self: *StackView) void {
        self.finishSlide();
        if (self.pages.items.len < 2) return;
        self.startSlide(false);
    }

    /// Back to the first page (no slide).
    pub fn clear(self: *StackView) void {
        self.finishSlide();
        while (self.pages.items.len > 1) self.destroyTop();
        self.layoutPages(0);
        self.depth.set(@intCast(self.pages.items.len));
    }

    fn add(self: *StackView, f: *const loader.ComponentFactory) bool {
        const inst = f.create(f.ctx, self.gpa) catch return false;
        const root = f.root(f.ctx, inst);
        root.width.setBinding(self.gpa, self, pageWidth) catch {};
        root.height.setBinding(self.gpa, self, pageHeight) catch {};
        root.y.set(0);
        self.pages.append(self.gpa, .{ .factory = f, .instance = inst }) catch {
            f.destroy(f.ctx, inst);
            return false;
        };
        self.item.appendChild(root);
        return true;
    }

    fn pageWidth(self: *StackView) f32 {
        return self.item.width.get();
    }
    fn pageHeight(self: *StackView) f32 {
        return self.item.height.get();
    }

    fn destroyTop(self: *StackView) void {
        const p = self.pages.pop() orelse return;
        p.factory.root(p.factory.ctx, p.instance).removeFromParent();
        p.factory.destroy(p.factory.ctx, p.instance);
    }

    fn rootOf(p: Page) *Item {
        return p.factory.root(p.factory.ctx, p.instance);
    }

    /// The pages where they are `t` into a slide (0: before, 1: done):
    /// the top one coming in from (or going out to) the right, the one
    /// below moving a third of the way along; the others hidden.
    fn layoutPages(self: *StackView, t: f32) void {
        const n = self.pages.items.len;
        const w = self.item.width.getUntracked();
        for (self.pages.items, 0..) |p, i| {
            const root = rootOf(p);
            const sliding = self.slide != null;
            if (i + 1 == n) {
                root.visible.set(true);
                const k = if (!sliding) 0 else if (self.slide.?.push) 1 - t else t;
                root.x.set(k * w);
            } else if (i + 2 == n and sliding) {
                root.visible.set(true);
                const k = if (self.slide.?.push) t else 1 - t;
                root.x.set(-k * w / 3);
            } else {
                root.visible.set(i + 1 == n);
                root.x.set(0);
            }
        }
    }

    fn startSlide(self: *StackView, push_it: bool) void {
        self.slide = .{ .push = push_it, .start_ms = time.now() };
        self.busy.set(true);
        self.layoutPages(0);
        self.timer.start(.repeated, 16, self, tick);
    }

    fn tick(self: *StackView) void {
        const s = self.slide orelse return self.timer.stop();
        const elapsed: f32 = @floatFromInt(time.now() -| s.start_ms);
        const t = @min(elapsed / slide_ms, 1);
        if (t >= 1) return self.finishSlide();
        self.layoutPages((animations.Easing{ .ease_out = {} }).apply(t));
    }

    /// Ends a slide where it goes (a popped page goes).
    fn finishSlide(self: *StackView) void {
        const s = self.slide orelse return;
        self.timer.stop();
        self.slide = null;
        if (!s.push) {
            self.destroyTop();
            self.depth.set(@intCast(self.pages.items.len));
        }
        self.layoutPages(0);
        self.busy.set(false);
    }

    fn layoutInfo(i: *Item, o: Orientation) LayoutInfo {
        return childrenInfo(i, o);
    }

    fn clips(_: *Item) bool {
        return true;
    }

    const vtable: ItemVTable = .{ .name = "StackView", .layoutInfo = layoutInfo, .clipsChildren = clips };
};

// ---- Tests ----

const testing = std.testing;
const core = @import("core.zig");

test "a stack layout shows one child, sized to it" {
    var s: StackLayout = .{};
    defer s.deinit();
    var a: core.items.Rectangle = .{};
    defer a.deinit();
    var b: core.items.Rectangle = .{};
    defer b.deinit();
    s.item.appendChildren(&.{ &a.item, &b.item });
    try s.setup(testing.allocator);
    s.item.setGeometry(.{ .width = 100, .height = 50 });
    try testing.expectEqual(@as(i32, 2), s.count.get());
    try testing.expect(a.item.visible.get() and !b.item.visible.get());
    try testing.expectEqual(@as(f32, 100), b.item.width.get());
    s.current_index.set(1);
    try testing.expect(!a.item.visible.get() and b.item.visible.get());
}

test "a swipe view: dragged to the next page, settles; set to one, slides there" {
    var w: Window = undefined;
    w.init(testing.allocator, .{ .width = 100, .height = 50 });
    defer w.deinit();
    var v: SwipeView = undefined;
    v.init(testing.allocator);
    defer v.deinit();
    var pages: [3]core.items.TouchArea = .{ .{}, .{}, .{} };
    defer for (&pages) |*p| p.deinit();
    w.rootItem().appendChild(&v.item);
    for (&pages) |*p| v.item.appendChild(&p.item);
    try v.setup(testing.allocator);
    v.item.setGeometry(.{ .width = 100, .height = 50 });
    var clicks: usize = 0;
    pages[0].clicked.setHandler(&clicks, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);
    try testing.expectEqual(@as(f32, 100), pages[1].item.x.get());

    // A tap reaches the page.
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 50, .y = 20 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 50, .y = 20 } } });
    try testing.expectEqual(@as(usize, 1), clicks);
    // Dragged left 30 px: the second page.
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 80, .y = 20 } } });
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = 60, .y = 20 } } });
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = 50, .y = 20 } } });
    try testing.expectApproxEqAbs(@as(f32, 0.3), v.position.get(), 0.01);
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 50, .y = 20 } } });
    try testing.expectEqual(@as(i32, 1), v.current_index.get());
    try testing.expectEqual(@as(usize, 1), clicks);
    var now = time.now();
    core.runChangeHandlers();
    now += 300;
    core.updateTimersAndAnimations(now);
    try testing.expectEqual(@as(f32, 1), v.position.get());
    try testing.expectEqual(@as(f32, 0), pages[1].item.x.get());
    // Set from code (past the last: the last).
    v.current_index.set(7);
    core.runChangeHandlers();
    now += 300;
    core.updateTimersAndAnimations(now);
    try testing.expectEqual(@as(f32, 2), v.position.get());
}

/// A page for the stack view tests.
const TestPage = struct {
    rect: core.items.Rectangle = .{},
    gpa: Allocator,
    var alive: usize = 0;
    const factory: loader.ComponentFactory = .{ .name = "TestPage", .create = create, .destroy = destroy, .root = root, .set_input = none };
    fn create(_: ?*anyopaque, gpa: Allocator) Allocator.Error!*anyopaque {
        const self = try gpa.create(TestPage);
        self.* = .{ .gpa = gpa };
        alive += 1;
        return self;
    }
    fn destroy(_: ?*anyopaque, p: *anyopaque) void {
        const self: *TestPage = @ptrCast(@alignCast(p));
        self.rect.deinit();
        alive -= 1;
        self.gpa.destroy(self);
    }
    fn root(_: ?*anyopaque, p: *anyopaque) *Item {
        return &@as(*TestPage, @ptrCast(@alignCast(p))).rect.item;
    }
    fn none(_: ?*anyopaque, _: *anyopaque, _: []const u8, _: []const u8, _: *const anyopaque) bool {
        return false;
    }
};

test "a stack view: pages pushed sliding in, popped sliding out" {
    var v: StackView = undefined;
    v.init(testing.allocator);
    defer v.deinit();
    v.item.setGeometry(.{ .width = 90, .height = 60 });
    v.initial_page.set(&TestPage.factory);
    core.runChangeHandlers();
    try testing.expectEqual(@as(i32, 1), v.depth.get());
    try testing.expectEqual(@as(usize, 1), TestPage.alive);

    var now = time.now();
    v.push(&TestPage.factory);
    try testing.expectEqual(@as(i32, 2), v.depth.get());
    try testing.expect(v.busy.get());
    const top = TestPage.root(null, v.pages.items[1].instance);
    try testing.expectEqual(@as(f32, 90), top.x.get()); // off to the right
    try testing.expectEqual(@as(f32, 60), top.height.get());
    now += 125;
    core.updateTimersAndAnimations(now);
    try testing.expect(top.x.get() > 0 and top.x.get() < 90);
    now += 200;
    core.updateTimersAndAnimations(now);
    try testing.expectEqual(@as(f32, 0), top.x.get());
    try testing.expect(!v.busy.get());
    const below = TestPage.root(null, v.pages.items[0].instance);
    try testing.expect(!below.visible.get());

    v.pop();
    try testing.expectEqual(@as(usize, 2), TestPage.alive); // still sliding out
    now += 300;
    core.updateTimersAndAnimations(now);
    try testing.expectEqual(@as(usize, 1), TestPage.alive);
    try testing.expectEqual(@as(i32, 1), v.depth.get());
    try testing.expect(below.visible.get());
    v.pop(); // the last one stays
    try testing.expectEqual(@as(i32, 1), v.depth.get());
}

/// Its children at their preferred sizes, left to right, wrapping to the
/// next row where they do not fit (rows `spacing` apart, as they are, and
/// `padding` inside). Its height is what the rows take at its width. Append
/// the children, then call `setup`.
pub const FlowLayout = struct {
    item: Item = .init(&vtable),
    spacing: Property(f32) = .init(0),
    padding: Property(f32) = .init(0),

    gpa: ?Allocator = null,
    /// Where each child goes (`solve`, whenever the layout or a child's
    /// constraints change).
    places: std.ArrayList(geometry.Rect) = .empty,
    solved: Property(void) = .init({}),

    pub fn deinit(self: *FlowLayout) void {
        if (self.gpa) |gpa| self.places.deinit(gpa);
        self.solved.deinit();
        self.item.deinit();
        self.spacing.deinit();
        self.padding.deinit();
    }

    pub fn setup(self: *FlowLayout, gpa: Allocator) Allocator.Error!void {
        self.gpa = gpa;
        try self.places.resize(gpa, self.item.layoutChildCount());
        try self.solved.setBinding(gpa, self, solve);
        var children = self.item.layoutChildren();
        var i: u32 = 0;
        while (children.next()) |c| : (i += 1) {
            const r: Ref(FlowLayout) = .{ .layout = self, .index = i };
            try c.x.setBinding(gpa, r, childX);
            try c.y.setBinding(gpa, r, childY);
            try c.width.setBinding(gpa, r, childWidth);
            try c.height.setBinding(gpa, r, childHeight);
        }
    }

    /// A child's size: its preferred one, within its minimum and maximum.
    fn sizeOf(c: *Item) Size {
        const h = c.layoutInfo(.horizontal);
        const v = c.layoutInfo(.vertical);
        return .{ .width = std.math.clamp(h.preferred, h.min, h.max), .height = std.math.clamp(v.preferred, v.min, v.max) };
    }

    /// Lays the children out in rows `width` wide; returns the height they
    /// take (with the padding). Into `out` if given.
    fn arrange(self: *FlowLayout, width: f32, out: ?[]geometry.Rect) f32 {
        const pad = self.padding.get();
        const gap = self.spacing.get();
        var x = pad;
        var y = pad;
        var row: f32 = 0;
        var any = false;
        var children = self.item.layoutChildren();
        var i: usize = 0;
        while (children.next()) |c| : (i += 1) {
            const s = sizeOf(c);
            // Not the first of its row, and past the right edge: the next row.
            if (x > pad and x + s.width > width - pad) {
                x = pad;
                y += row + gap;
                row = 0;
            }
            if (out) |o| if (i < o.len) {
                o[i] = .{ .x = x, .y = y, .width = s.width, .height = s.height };
            };
            x += s.width + gap;
            row = @max(row, s.height);
            any = true;
        }
        return if (any) y + row + pad else 2 * pad;
    }

    fn solve(self: *FlowLayout) void {
        _ = self.arrange(self.item.width.get(), self.places.items);
    }

    fn place(r: Ref(FlowLayout)) geometry.Rect {
        r.layout.solved.get();
        const p = r.layout.places.items;
        return if (r.index < p.len) p[r.index] else .{};
    }
    fn childX(r: Ref(FlowLayout)) f32 {
        return place(r).x;
    }
    fn childY(r: Ref(FlowLayout)) f32 {
        return place(r).y;
    }
    fn childWidth(r: Ref(FlowLayout)) f32 {
        return place(r).width;
    }
    fn childHeight(r: Ref(FlowLayout)) f32 {
        return place(r).height;
    }

    /// Across: at least its widest child, preferably all in one row. Down:
    /// what the rows take at its width.
    fn layoutInfo(i: *Item, o: Orientation) LayoutInfo {
        const self: *FlowLayout = @fieldParentPtr("item", i);
        const pad = self.padding.get();
        if (o == .horizontal) {
            var widest: f32 = 0;
            var total: f32 = 0;
            var n: f32 = 0;
            var children = self.item.layoutChildren();
            while (children.next()) |c| : (n += 1) {
                const w = sizeOf(c).width;
                widest = @max(widest, w);
                total += w;
            }
            const gaps = @max(n - 1, 0) * self.spacing.get();
            return .{ .min = widest + 2 * pad, .preferred = total + gaps + 2 * pad, .max = std.math.inf(f32) };
        }
        const height = self.arrange(self.item.width.get(), null);
        return .{ .min = height, .preferred = height, .max = std.math.inf(f32) };
    }

    fn childrenChanged(i: *Item) void {
        const self: *FlowLayout = @fieldParentPtr("item", i);
        if (self.gpa) |gpa| self.setup(gpa) catch log.err("out of memory laying out a flow", .{});
    }

    const vtable: ItemVTable = .{ .name = "FlowLayout", .layoutInfo = layoutInfo, .childrenChanged = childrenChanged, .is_layout = true };
};

test "a flow layout wraps its children into rows, its height following its width" {
    var f: FlowLayout = .{};
    defer f.deinit();
    var cs: [5]core.LayoutConstraints = @splat(.{});
    defer for (&cs) |*c| c.deinit();
    var rects: [5]core.items.Rectangle = @splat(.{});
    defer for (&rects) |*r| r.deinit();
    for (&rects, &cs) |*r, *c| {
        r.item.constraints = c;
        c.preferred_width.set(40);
        c.preferred_height.set(30);
        f.item.appendChild(&r.item);
    }
    f.spacing.set(10);
    try f.setup(testing.allocator);
    // 100 px: two a row (40 + 10 + 40), three rows.
    f.item.setGeometry(.{ .width = 100, .height = 200 });
    try testing.expectEqual(@as(f32, 50), rects[1].item.x.get());
    try testing.expectEqual(@as(f32, 0), rects[2].item.x.get());
    try testing.expectEqual(@as(f32, 40), rects[2].item.y.get());
    try testing.expectEqual(@as(f32, 80), rects[4].item.y.get());
    try testing.expectEqual(@as(f32, 110), f.item.layoutInfo(.vertical).preferred);
    // 200 px: four a row.
    f.item.setGeometry(.{ .width = 200, .height = 200 });
    try testing.expectEqual(@as(f32, 150), rects[3].item.x.get());
    try testing.expectEqual(@as(f32, 40), rects[4].item.y.get());
    try testing.expectEqual(@as(f32, 70), f.item.layoutInfo(.vertical).preferred);
    try testing.expectEqual(@as(f32, 40), f.item.layoutInfo(.horizontal).min);
}
