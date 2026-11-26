// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! `SplitView`: its children side by side (or one above the other), with a
//! handle between each two that the pointer drags to share the room
//! between them, each kept at its minimum size or more.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Size = geometry.Size;
const graphics = @import("graphics.zig");
const Brush = graphics.Brush;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const ItemVTable = item_mod.ItemVTable;
const layout = @import("layout.zig");
const LayoutInfo = layout.LayoutInfo;
const Orientation = layout.Orientation;
const input = @import("input.zig");
const rendering = @import("rendering.zig");
const Window = @import("window.zig").Window;

const log = std.log.scoped(.zigulee_split);

/// Its children (the panes) side by side, or one above the other with
/// `vertical`, sharing its size: at first by their preferred sizes, then as
/// the handles between them are dragged (each pane stays within its
/// minimum and maximum). `handle-width` is the room a handle takes,
/// `handle-color` its line. Append the children, then call `setup`.
pub const SplitView = struct {
    item: Item = .init(&vtable),
    vertical: Property(bool) = .init(false),
    handle_width: Property(f32) = .init(6),
    handle_color: Property(Brush) = .init(.color(.rgba(0x80808066))),

    gpa: ?Allocator = null,
    /// Each pane's share of the room (summing to 1).
    shares: std.ArrayList(f32) = .empty,
    /// Bumped when the shares change (the panes' bindings read it).
    version: Property(u32) = .init(0),
    handles: std.ArrayList(*Handle) = .empty,

    pub fn deinit(self: *SplitView) void {
        if (self.gpa) |gpa| {
            for (self.handles.items) |h| {
                h.item.removeFromParent();
                h.item.deinit();
                gpa.destroy(h);
            }
            self.handles.deinit(gpa);
            self.shares.deinit(gpa);
        }
        self.version.deinit();
        self.item.deinit();
        self.vertical.deinit();
        self.handle_width.deinit();
        self.handle_color.deinit();
    }

    /// The panes (its children, not its handles).
    const Panes = struct {
        it: Item.LayoutChildIterator,
        fn next(p: *Panes) ?*Item {
            while (p.it.next()) |c| if (c.vtable != &Handle.vtable) return c;
            return null;
        }
    };

    fn panes(self: *SplitView) Panes {
        return .{ .it = self.item.layoutChildren() };
    }

    fn paneCount(self: *SplitView) usize {
        var n: usize = 0;
        var p = self.panes();
        while (p.next()) |_| n += 1;
        return n;
    }

    pub fn setup(self: *SplitView, gpa: Allocator) Allocator.Error!void {
        self.gpa = gpa;
        const n = self.paneCount();
        // Shares: kept for the panes it had; by preferred sizes at first.
        if (self.shares.items.len != n) {
            try self.shares.resize(gpa, n);
            const o: Orientation = if (self.vertical.getUntracked()) .vertical else .horizontal;
            var total: f32 = 0;
            var p = self.panes();
            var i: usize = 0;
            while (p.next()) |c| : (i += 1) {
                const pref = c.layoutInfo(o).preferred;
                self.shares.items[i] = if (pref > 0) pref else 100;
                total += self.shares.items[i];
            }
            for (self.shares.items) |*s| s.* /= @max(total, 1);
        }
        // A handle between each two panes, on top of them.
        const want = if (n > 1) n - 1 else 0;
        while (self.handles.items.len > want) {
            const h = self.handles.pop().?;
            h.item.removeFromParent();
            h.item.deinit();
            gpa.destroy(h);
        }
        for (self.handles.items) |h| h.item.removeFromParent();
        while (self.handles.items.len < want) {
            const h = try gpa.create(Handle);
            h.* = .{ .split = self, .index = @intCast(self.handles.items.len) };
            try self.handles.append(gpa, h);
        }
        for (self.handles.items) |h| self.item.appendChild(&h.item);

        var p = self.panes();
        var i: u32 = 0;
        while (p.next()) |c| : (i += 1) {
            const r: Ref = .{ .split = self, .index = i };
            try c.x.setBinding(gpa, r, paneX);
            try c.y.setBinding(gpa, r, paneY);
            try c.width.setBinding(gpa, r, paneWidth);
            try c.height.setBinding(gpa, r, paneHeight);
        }
        for (self.handles.items) |h| {
            const r: Ref = .{ .split = self, .index = h.index };
            try h.item.x.setBinding(gpa, r, handleX);
            try h.item.y.setBinding(gpa, r, handleY);
            try h.item.width.setBinding(gpa, r, handleWidth);
            try h.item.height.setBinding(gpa, r, handleHeight);
        }
    }

    const Ref = struct { split: *SplitView, index: u32 };

    /// Along the split: its length, and the room the panes share.
    fn room(self: *SplitView) struct { length: f32, panes: f32 } {
        const length = if (self.vertical.get()) self.item.height.get() else self.item.width.get();
        const handles: f32 = @floatFromInt(self.handles.items.len);
        return .{ .length = length, .panes = @max(0, length - handles * self.handle_width.get()) };
    }

    /// Pane `i`'s start and size along the split.
    fn span(self: *SplitView, i: u32) struct { start: f32, size: f32 } {
        _ = self.version.get();
        const r = self.room();
        const hw = self.handle_width.get();
        var start: f32 = 0;
        for (self.shares.items[0..@min(i, self.shares.items.len)]) |s| start += s * r.panes + hw;
        const share = if (i < self.shares.items.len) self.shares.items[i] else 0;
        return .{ .start = start, .size = share * r.panes };
    }

    fn paneX(r: Ref) f32 {
        return if (r.split.vertical.get()) 0 else r.split.span(r.index).start;
    }
    fn paneY(r: Ref) f32 {
        return if (r.split.vertical.get()) r.split.span(r.index).start else 0;
    }
    fn paneWidth(r: Ref) f32 {
        return if (r.split.vertical.get()) r.split.item.width.get() else r.split.span(r.index).size;
    }
    fn paneHeight(r: Ref) f32 {
        return if (r.split.vertical.get()) r.split.span(r.index).size else r.split.item.height.get();
    }
    /// Handle `i`: after pane `i`.
    fn handleStart(r: Ref) f32 {
        const s = r.split.span(r.index);
        return s.start + s.size;
    }
    fn handleX(r: Ref) f32 {
        return if (r.split.vertical.get()) 0 else handleStart(r);
    }
    fn handleY(r: Ref) f32 {
        return if (r.split.vertical.get()) handleStart(r) else 0;
    }
    fn handleWidth(r: Ref) f32 {
        return if (r.split.vertical.get()) r.split.item.width.get() else r.split.handle_width.get();
    }
    fn handleHeight(r: Ref) f32 {
        return if (r.split.vertical.get()) r.split.handle_width.get() else r.split.item.height.get();
    }

    /// Moves handle `k` by `delta` along the split: the room between the
    /// panes on its sides, within their minimums and maximums.
    pub fn moveHandle(self: *SplitView, k: usize, delta: f32) void {
        if (k + 1 >= self.shares.items.len) return;
        const avail = self.room().panes;
        if (avail <= 0) return;
        const o: Orientation = if (self.vertical.getUntracked()) .vertical else .horizontal;
        var p = self.panes();
        var i: usize = 0;
        var a_info: LayoutInfo = .{};
        var b_info: LayoutInfo = .{};
        while (p.next()) |c| : (i += 1) {
            if (i == k) a_info = c.layoutInfo(o);
            if (i == k + 1) b_info = c.layoutInfo(o);
        }
        const a = self.shares.items[k] * avail;
        const b = self.shares.items[k + 1] * avail;
        const both = a + b;
        // Pane a's new size, within both panes' limits.
        const lo = @max(a_info.min, both - b_info.max);
        const hi = @min(a_info.max, both - b_info.min);
        const new_a = if (lo <= hi) std.math.clamp(a + delta, lo, hi) else a;
        self.shares.items[k] = new_a / avail;
        self.shares.items[k + 1] = (both - new_a) / avail;
        self.version.set(self.version.getUntracked() +% 1);
    }

    fn layoutInfo(i: *Item, o: Orientation) LayoutInfo {
        const self: *SplitView = @fieldParentPtr("item", i);
        const along: Orientation = if (self.vertical.get()) .vertical else .horizontal;
        var info: LayoutInfo = .{ .min = 0, .preferred = 0, .max = std.math.inf(f32) };
        var p = self.panes();
        var n: f32 = 0;
        while (p.next()) |c| : (n += 1) {
            const ci = c.layoutInfo(o);
            if (o == along) {
                info.min += ci.min;
                info.preferred += ci.preferred;
            } else {
                info.min = @max(info.min, ci.min);
                info.preferred = @max(info.preferred, ci.preferred);
            }
        }
        if (o == along and n > 1) {
            const handles = (n - 1) * self.handle_width.get();
            info.min += handles;
            info.preferred += handles;
        }
        return info;
    }

    fn childrenChanged(i: *Item) void {
        const self: *SplitView = @fieldParentPtr("item", i);
        if (self.gpa) |gpa| self.setup(gpa) catch log.err("out of memory laying out panes", .{});
    }

    const vtable: ItemVTable = .{ .name = "SplitView", .layoutInfo = layoutInfo, .childrenChanged = childrenChanged, .clipsChildren = clips, .is_layout = true };

    fn clips(_: *Item) bool {
        return true;
    }
};

/// A handle between two panes: dragged, it moves the room between them.
const Handle = struct {
    item: Item = .init(&vtable),
    split: *SplitView,
    index: u32,
    pressed: bool = false,
    last: f32 = 0,

    const vtable: ItemVTable = .{ .name = "SplitHandle", .render = render, .inputEvent = inputEvent, .mouseCursor = mouseCursor };

    fn of(i: *Item) *Handle {
        return @fieldParentPtr("item", i);
    }

    /// A line along its middle.
    fn render(i: *Item, r: rendering.ItemRenderer) void {
        const self = of(i);
        const size = i.size();
        const vertical = self.split.vertical.get();
        const line: geometry.Rect = if (vertical)
            .{ .y = @floor(size.height / 2), .width = size.width, .height = 1 }
        else
            .{ .x = @floor(size.width / 2), .width = 1, .height = size.height };
        r.save();
        defer r.restore();
        r.translate(.{ .x = line.x, .y = line.y });
        r.drawRectangle(.{ .width = line.width, .height = line.height }, .{ .background = self.split.handle_color.get() });
    }

    fn mouseCursor(i: *Item) input.MouseCursor {
        return if (of(i).split.vertical.get()) .ns_resize else .ew_resize;
    }

    fn inputEvent(i: *Item, event: input.PointerEvent, _: *Window) input.InputEventResult {
        const self = of(i);
        const vertical = self.split.vertical.get();
        switch (event) {
            .pressed => |p| {
                if (p.button != .left) return .ignored;
                self.pressed = true;
                const w = i.windowTransform().apply(p.position);
                self.last = if (vertical) w.y else w.x;
                return .grab;
            },
            .moved => |m| {
                if (!self.pressed) return .accepted;
                const w = i.windowTransform().apply(m.position);
                const along = if (vertical) w.y else w.x;
                self.split.moveHandle(self.index, along - self.last);
                // Where it is now: a pane at its limit stops the handle.
                self.last = along;
                return .grab;
            },
            .released, .exit => {
                self.pressed = false;
                return .accepted;
            },
            .wheel => return .ignored,
        }
    }
};

// ---- Tests ----

const testing = std.testing;
const core = @import("core.zig");

test "panes share the room by their preferred sizes; a handle drag moves it, within their minimums" {
    var w: Window = undefined;
    w.init(testing.allocator, .{ .width = 306, .height = 100 });
    defer w.deinit();
    var split: SplitView = .{};
    defer split.deinit();
    var a: core.items.Rectangle = .{};
    defer a.deinit();
    var b: core.items.Rectangle = .{};
    defer b.deinit();
    var ca: core.LayoutConstraints = .{};
    defer ca.deinit();
    var cb: core.LayoutConstraints = .{};
    defer cb.deinit();
    a.item.constraints = &ca;
    b.item.constraints = &cb;
    ca.preferred_width.set(100);
    cb.preferred_width.set(200);
    cb.min_width.set(150);
    w.rootItem().appendChild(&split.item);
    split.item.appendChildren(&.{ &a.item, &b.item });
    try split.setup(testing.allocator);
    split.item.setGeometry(.{ .width = 306, .height = 100 });

    // 300 px of panes and a 6 px handle.
    try testing.expectApproxEqAbs(@as(f32, 100), a.item.width.get(), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 106), b.item.x.get(), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 200), b.item.width.get(), 0.01);
    try testing.expectEqual(@as(f32, 100), b.item.height.get());

    // Dragged right 30 px from the handle's middle (103).
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 103, .y = 50 } } });
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = 133, .y = 50 } } });
    try testing.expectApproxEqAbs(@as(f32, 130), a.item.width.get(), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 170), b.item.width.get(), 0.01);
    // Further: b stops at its minimum (150).
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = 250, .y = 50 } } });
    try testing.expectApproxEqAbs(@as(f32, 150), b.item.width.get(), 0.01);
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 250, .y = 50 } } });

    // Wider: the panes keep their shares.
    split.item.setGeometry(.{ .width = 606, .height = 100 });
    try testing.expectApproxEqAbs(@as(f32, 300), b.item.width.get(), 0.01);
}
