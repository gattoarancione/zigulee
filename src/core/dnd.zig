// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Drag and drop within the application: a `DragArea` is dragged (its
//! `kind` and `data`, strings), a `DropArea` takes what it `accepts`.
//!
//! A press on a DragArea moved past a few pixels starts the drag; the
//! topmost DropArea under the pointer that accepts the kind is told it
//! entered, where the pointer is, then that it left or that it was dropped
//! on. Escape, or a scroll view taking the gesture over, cancels it. The
//! DragArea itself draws nothing: what shows the drag binds to its
//! `dragging` and offsets (`x: drag.dragging ? drag.offset-x : 0px`).

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

/// How far the pointer moves before a press becomes a drag (pixels).
pub const threshold: f32 = 4;

pub const DragArea = struct {
    item: Item = .init(&vtable),
    /// What is dragged: DropAreas accept it by kind.
    kind: Property([]const u8) = .init(""),
    data: Property([]const u8) = .init(""),
    dragging: Property(bool) = .init(false),
    /// The pointer since the press, while dragging (window pixels).
    offset_x: Property(f32) = .init(0),
    offset_y: Property(f32) = .init(0),
    started: Callback(fn () void) = .{},
    /// The drag ended: dropped on a DropArea (true), or not.
    finished: Callback(fn (bool) void) = .{},
    /// Pressed and released without dragging.
    clicked: Callback(fn () void) = .{},

    pressed: bool = false,
    press: Point = .{},
    target: ?*DropArea = null,
    window: ?*Window = null,

    pub fn deinit(self: *DragArea) void {
        // Only while dragging is the window (and a target) known to be
        // there.
        if (self.dragging.getUntracked()) {
            if (self.window) |w| if (w.active_drag == @as(?*anyopaque, self)) {
                w.active_drag = null;
            };
            if (self.target) |t| t.leave();
        }
        self.item.deinit();
        self.kind.deinit();
        self.data.deinit();
        self.dragging.deinit();
        self.offset_x.deinit();
        self.offset_y.deinit();
    }

    const vtable: ItemVTable = .{ .name = "DragArea", .inputEvent = inputEvent, .mouseCursor = mouseCursor };

    fn of(i: *Item) *DragArea {
        return @fieldParentPtr("item", i);
    }

    fn mouseCursor(i: *Item) input.MouseCursor {
        const self = of(i);
        if (!self.item.isEnabled()) return .default;
        return if (self.dragging.get()) .move else .default;
    }

    fn inputEvent(i: *Item, event: input.PointerEvent, w: *Window) input.InputEventResult {
        const self = of(i);
        if (!self.item.isEnabled()) return .ignored;
        switch (event) {
            .pressed => |p| {
                if (p.button != .left) return .ignored;
                self.pressed = true;
                self.press = i.windowTransform().apply(p.position);
                return .grab;
            },
            .moved => |m| {
                if (!self.pressed) return .accepted;
                const at = i.windowTransform().apply(m.position);
                const dx = at.x - self.press.x;
                const dy = at.y - self.press.y;
                if (!self.dragging.get()) {
                    if (@abs(dx) < threshold and @abs(dy) < threshold) return .grab;
                    self.begin(w);
                }
                self.offset_x.set(dx);
                self.offset_y.set(dy);
                self.hover(dropAreaAt(&w.root.item, at, self.kind.get()), at);
                return .grab;
            },
            .released => |r| {
                if (r.button != .left or !self.pressed) return .accepted;
                self.pressed = false;
                if (!self.dragging.get()) {
                    if ((Rect{ .width = i.width.get(), .height = i.height.get() }).contains(r.position)) self.clicked.call(.{});
                    return .accepted;
                }
                const at = i.windowTransform().apply(r.position);
                self.hover(dropAreaAt(&w.root.item, at, self.kind.get()), at);
                const target = self.target;
                self.target = null;
                if (target) |t| t.drop(self.data.get());
                self.end(target != null);
                return .accepted;
            },
            // The gesture went elsewhere (a scroll view took it).
            .exit => {
                if (self.dragging.get()) self.cancel();
                self.pressed = false;
                return .accepted;
            },
            .wheel => return .ignored,
        }
    }

    fn begin(self: *DragArea, w: *Window) void {
        self.window = w;
        w.active_drag = self;
        w.cancel_drag = cancelErased;
        self.dragging.set(true);
        self.started.call(.{});
    }

    fn hover(self: *DragArea, target: ?*DropArea, at: Point) void {
        if (target != self.target) {
            if (self.target) |t| t.leave();
            self.target = target;
            if (target) |t| t.enter(self.kind.get(), self.data.get());
        }
        if (target) |t| {
            const local = t.item.fromWindow(at);
            t.drag_x.set(local.x);
            t.drag_y.set(local.y);
        }
    }

    /// Ends the drag without a drop (Escape).
    pub fn cancel(self: *DragArea) void {
        if (!self.dragging.get()) return;
        if (self.target) |t| t.leave();
        self.target = null;
        self.pressed = false;
        self.end(false);
    }

    fn cancelErased(p: *anyopaque) void {
        const self: *DragArea = @ptrCast(@alignCast(p));
        self.cancel();
    }

    fn end(self: *DragArea, accepted: bool) void {
        if (self.window) |w| if (w.active_drag == @as(?*anyopaque, self)) {
            w.active_drag = null;
        };
        self.window = null;
        self.dragging.set(false);
        self.offset_x.set(0);
        self.offset_y.set(0);
        self.finished.call(.{accepted});
    }
};

pub const DropArea = struct {
    item: Item = .init(&vtable),
    /// The kind it takes ("": any).
    accepts: Property([]const u8) = .init(""),
    /// A drag it takes is over it.
    contains_drag: Property(bool) = .init(false),
    /// What is over it (while `contains_drag`).
    drag_kind: Property([]const u8) = .init(""),
    drag_data: Property([]const u8) = .init(""),
    /// Where the pointer is, in its coordinates.
    drag_x: Property(f32) = .init(0),
    drag_y: Property(f32) = .init(0),
    entered: Callback(fn () void) = .{},
    exited: Callback(fn () void) = .{},
    /// Dropped on it: the dragged data.
    dropped: Callback(fn ([]const u8) void) = .{},

    pub fn deinit(self: *DropArea) void {
        self.item.deinit();
        self.accepts.deinit();
        self.contains_drag.deinit();
        self.drag_kind.deinit();
        self.drag_data.deinit();
        self.drag_x.deinit();
        self.drag_y.deinit();
    }

    const vtable: ItemVTable = .{ .name = "DropArea" };

    fn takes(self: *DropArea, kind: []const u8) bool {
        if (!self.item.isEnabled()) return false;
        const accepts = self.accepts.get();
        return accepts.len == 0 or std.mem.eql(u8, accepts, kind);
    }

    fn enter(self: *DropArea, kind: []const u8, data: []const u8) void {
        self.drag_kind.set(kind);
        self.drag_data.set(data);
        self.contains_drag.set(true);
        self.entered.call(.{});
    }

    fn leave(self: *DropArea) void {
        if (!self.contains_drag.getUntracked()) return;
        self.contains_drag.set(false);
        self.drag_kind.set("");
        self.drag_data.set("");
        self.exited.call(.{});
    }

    fn drop(self: *DropArea, data: []const u8) void {
        self.contains_drag.set(false);
        self.drag_kind.set("");
        self.drag_data.set("");
        self.dropped.call(.{data});
    }
};

/// The topmost visible DropArea at `p` (window coordinates) taking `kind`.
pub fn dropAreaAt(item: *Item, p: Point, kind: []const u8) ?*DropArea {
    if (!item.visible.get() or !item.enabled.get()) return null;
    // Later children are on top: the last match among them wins.
    var found: ?*DropArea = null;
    var it = item.first_child;
    while (it) |c| : (it = c.next_sibling) {
        if (dropAreaAt(c, p, kind)) |d| found = d;
    }
    if (found) |d| return d;
    if (item.vtable != &DropArea.vtable) return null;
    const self: *DropArea = @fieldParentPtr("item", item);
    if (!self.takes(kind)) return null;
    const local = item.fromWindow(p);
    if (!(Rect{ .width = item.width.get(), .height = item.height.get() }).contains(local)) return null;
    return self;
}

// ---- From other applications ----
//
// Backends report drags from other applications (files, text) over a
// window: their kinds while they move (those they may be, when the
// platform tells only at the drop), then the drop or their leaving.

/// The kinds of a drag from another application.
pub const file_kind = "file";
pub const text_kind = "text";

/// The paths of a `text/uri-list` (what X11 and Wayland drops carry): its
/// `file://` URIs, percent-decoded, one per line (owned). Other URIs and
/// comments are left out.
pub fn pathsFromUriList(gpa: std.mem.Allocator, list: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.tokenizeAny(u8, list, "\r\n");
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var rest = std.mem.cutPrefix(u8, line, "file://") orelse continue;
        // "file://host/path": the path from its first slash.
        rest = rest[std.mem.indexOfScalar(u8, rest, '/') orelse continue ..];
        if (out.items.len > 0) try out.append(gpa, '\n');
        var i: usize = 0;
        while (i < rest.len) {
            if (rest[i] == '%' and i + 2 < rest.len) {
                if (std.fmt.parseInt(u8, rest[i + 1 ..][0..2], 16)) |byte| {
                    try out.append(gpa, byte);
                    i += 3;
                    continue;
                } else |_| {}
            }
            try out.append(gpa, rest[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// A drag from another application moved over `w`, at `at` (window
/// coordinates), of one of `kinds`: whether a DropArea there takes it (the
/// platform shows the drop as possible, or not).
pub fn externalMoved(w: *Window, kinds: []const []const u8, at: Point) bool {
    var found: ?*DropArea = null;
    var kind: []const u8 = "";
    for (kinds) |k| if (dropAreaAt(&w.root.item, at, k)) |d| {
        found = d;
        kind = k;
        break;
    };
    const current: ?*DropArea = @ptrCast(@alignCast(w.external_drop_area));
    if (found != current) {
        if (current) |cur| cur.leave();
        w.external_drop_area = found;
        if (found) |f| f.enter(kind, "");
    }
    if (found) |f| {
        const local = f.item.fromWindow(at);
        f.drag_x.set(local.x);
        f.drag_y.set(local.y);
    }
    return found != null;
}

/// The drag from another application left `w` (or was cancelled).
pub fn externalLeft(w: *Window) void {
    const current: ?*DropArea = @ptrCast(@alignCast(w.external_drop_area));
    w.external_drop_area = null;
    if (current) |cur| cur.leave();
}

/// Dropped on `w` at `at`: `data` of `kind` (`file_kind`: paths, one per
/// line; `text_kind`). Whether a DropArea took it.
pub fn externalDropped(w: *Window, kind: []const u8, data: []const u8, at: Point) bool {
    externalLeft(w);
    const target = dropAreaAt(&w.root.item, at, kind) orelse return false;
    target.drop(data);
    return true;
}

// ---- Tests ----

const testing = std.testing;
const core = @import("core.zig");

const Log = struct {
    dropped: [64]u8 = undefined,
    dropped_len: usize = 0,
    finished: ?bool = null,
    entered: usize = 0,

    fn onDrop(self: *Log, data: []const u8) void {
        @memcpy(self.dropped[0..data.len], data);
        self.dropped_len = data.len;
    }
    fn onFinish(self: *Log, ok: bool) void {
        self.finished = ok;
    }
    fn onEnter(self: *Log) void {
        self.entered += 1;
    }
};

fn pointer(w: *Window, comptime kind: std.meta.Tag(input.PointerEvent), x: f32, y: f32) void {
    const p: Point = .{ .x = x, .y = y };
    w.dispatchPointer(switch (kind) {
        .pressed => .{ .pressed = .{ .position = p } },
        .released => .{ .released = .{ .position = p } },
        .moved => .{ .moved = .{ .position = p } },
        else => unreachable,
    });
}

test "dragging onto a drop area that takes the kind, and onto one that does not" {
    var w: Window = undefined;
    w.init(testing.allocator, .{ .width = 300, .height = 100 });
    defer w.deinit();
    var card: DragArea = .{};
    defer card.deinit();
    var bin: DropArea = .{};
    defer bin.deinit();
    var other: DropArea = .{};
    defer other.deinit();
    w.rootItem().appendChildren(&.{ &card.item, &bin.item, &other.item });
    card.item.setGeometry(.{ .x = 0, .y = 0, .width = 50, .height = 50 });
    bin.item.setGeometry(.{ .x = 100, .y = 0, .width = 80, .height = 80 });
    other.item.setGeometry(.{ .x = 200, .y = 0, .width = 80, .height = 80 });
    card.kind.set("card");
    card.data.set("ace");
    bin.accepts.set("card");
    other.accepts.set("file");
    var log: Log = .{};
    bin.dropped.setHandler(&log, Log.onDrop);
    bin.entered.setHandler(&log, Log.onEnter);
    card.finished.setHandler(&log, Log.onFinish);

    // A small move is not a drag.
    pointer(&w, .pressed, 10, 10);
    pointer(&w, .moved, 12, 11);
    try testing.expect(!card.dragging.get());
    pointer(&w, .moved, 130, 20);
    try testing.expect(card.dragging.get());
    try testing.expectEqual(@as(f32, 120), card.offset_x.get());
    try testing.expect(bin.contains_drag.get());
    try testing.expectEqualStrings("ace", bin.drag_data.get());
    try testing.expectEqual(@as(f32, 30), bin.drag_x.get());
    pointer(&w, .moved, 230, 20); // over one that does not take cards
    try testing.expect(!bin.contains_drag.get());
    try testing.expect(!other.contains_drag.get());
    pointer(&w, .moved, 140, 20);
    try testing.expectEqual(@as(usize, 2), log.entered);
    pointer(&w, .released, 140, 20);
    try testing.expectEqualStrings("ace", log.dropped[0..log.dropped_len]);
    try testing.expectEqual(@as(?bool, true), log.finished);
    try testing.expect(!card.dragging.get());
    try testing.expectEqual(@as(f32, 0), card.offset_x.get());

    // Dropped where nothing takes it.
    pointer(&w, .pressed, 10, 10);
    pointer(&w, .moved, 60, 90);
    pointer(&w, .released, 60, 90);
    try testing.expectEqual(@as(?bool, false), log.finished);

    // Escape cancels.
    log.finished = null;
    pointer(&w, .pressed, 10, 10);
    pointer(&w, .moved, 130, 20);
    try testing.expect(bin.contains_drag.get());
    w.dispatchKey(.pressed, .{ .text = input.Key.escape });
    try testing.expect(!card.dragging.get());
    try testing.expect(!bin.contains_drag.get());
    try testing.expectEqual(@as(?bool, false), log.finished);
    pointer(&w, .released, 130, 20); // nothing more
    try testing.expectEqual(@as(?bool, false), log.finished);
}

test "drags from other applications: hovered, left, dropped by kind" {
    var w: Window = undefined;
    w.init(testing.allocator, .{ .width = 200, .height = 100 });
    defer w.deinit();
    var files: DropArea = .{};
    defer files.deinit();
    var texts: DropArea = .{};
    defer texts.deinit();
    w.rootItem().appendChildren(&.{ &files.item, &texts.item });
    files.item.setGeometry(.{ .width = 100, .height = 100 });
    texts.item.setGeometry(.{ .x = 100, .width = 100, .height = 100 });
    files.accepts.set(file_kind);
    texts.accepts.set(text_kind);
    var log: Log = .{};
    files.dropped.setHandler(&log, Log.onDrop);

    // The kind not known yet: either.
    const either = [_][]const u8{ file_kind, text_kind };
    try testing.expect(externalMoved(&w, &either, .{ .x = 20, .y = 20 }));
    try testing.expect(files.contains_drag.get());
    try testing.expect(externalMoved(&w, &either, .{ .x = 150, .y = 20 }));
    try testing.expect(!files.contains_drag.get());
    try testing.expect(texts.contains_drag.get());
    externalLeft(&w);
    try testing.expect(!texts.contains_drag.get());

    // Files dropped on the text area: not taken; on the files area: taken.
    try testing.expect(!externalDropped(&w, file_kind, "/tmp/a.txt", .{ .x = 150, .y = 20 }));
    try testing.expect(externalDropped(&w, file_kind, "/tmp/a.txt\n/tmp/b.txt", .{ .x = 20, .y = 20 }));
    try testing.expectEqualStrings("/tmp/a.txt\n/tmp/b.txt", log.dropped[0..log.dropped_len]);
}

test "uri lists to paths" {
    const paths = try pathsFromUriList(testing.allocator, "# from a file manager\r\nfile:///home/me/My%20Photos/a.png\r\nhttps://example.com/x\r\nfile://host/tmp/b%2Bc.txt\r\n");
    defer testing.allocator.free(paths);
    try testing.expectEqualStrings("/home/me/My Photos/a.png\n/tmp/b+c.txt", paths);
}
