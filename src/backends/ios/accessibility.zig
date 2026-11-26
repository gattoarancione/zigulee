// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! VoiceOver support on iOS: shows a zigulee window's accessible items
//! (`zigulee.core.accessibility`) to UIKit as UIAccessibilityElements.
//!
//! VoiceOver on iOS moves through a flat list: the view lists one element
//! per item a user acts on or reads (buttons, texts, fields...), in tree
//! order; groups only order them. A table's row is one element, read as
//! its cells (as UITableView's are). Each element (a subclass of
//! UIAccessibilityElement made at run time) answers from the latest
//! snapshot and performs actions through zigulee. Elements are kept per item,
//! so VoiceOver does not lose its place when the snapshot changes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const a11y = core.accessibility;

const objc = @import("zigulee-apple").objc;
const id = objc.id;
const SEL = objc.SEL;
const BOOL = objc.BOOL;
const NSRect = objc.NSRect;
const msg = objc.msg;
const class = objc.class;
const nsString = objc.nsString;

extern "c" fn UIAccessibilityIsVoiceOverRunning() BOOL;
extern "c" fn UIAccessibilityPostNotification(notification: u32, argument: id) void;
const layout_changed: u32 = 1001;

// UIAccessibilityTraits.
const trait_button: u64 = 1 << 0;
const trait_image: u64 = 1 << 2;
const trait_selected: u64 = 1 << 3;
const trait_static_text: u64 = 1 << 6;
const trait_not_enabled: u64 = 1 << 8;
const trait_updates_frequently: u64 = 1 << 10;
const trait_adjustable: u64 = 1 << 12;
const trait_tab_bar: u64 = 1 << 15;
const trait_header: u64 = 1 << 16;

// ---- The bridge ----

pub const Bridge = struct {
    gpa: Allocator,
    ui: *core.Window,
    /// The view listing the elements (their container).
    view: id,
    tracker: a11y.Tracker,
    /// The element of each item VoiceOver visits (retained).
    elements: std.AutoHashMapUnmanaged(*core.Item, id) = .empty,
    /// The latest snapshot, and where each item is in it.
    nodes: []const a11y.Node = &.{},
    index: std.AutoHashMapUnmanaged(*core.Item, u32) = .empty,
    /// The elements in order (retained).
    list: id = null,
    /// Update even when VoiceOver is off (tests).
    always: bool = false,

    /// Shows `ui`'s accessible items in `view`. Call `update` from the
    /// event loop. Both must outlive the bridge.
    pub fn create(gpa: Allocator, ui: *core.Window, view: id) Allocator.Error!*Bridge {
        const self = try gpa.create(Bridge);
        self.* = .{ .gpa = gpa, .ui = ui, .view = view, .tracker = .init(gpa, ui) };
        msg(void, view, "setIsAccessibilityElement:", .{false});
        return self;
    }

    pub fn destroy(self: *Bridge) void {
        var it = self.elements.valueIterator();
        while (it.next()) |e| {
            setData(e.*, null);
            msg(void, e.*, "release", .{});
        }
        if (self.list != null) msg(void, self.list, "release", .{});
        self.elements.deinit(self.gpa);
        self.index.deinit(self.gpa);
        self.tracker.deinit();
        self.gpa.destroy(self);
    }

    /// The elements, in the order VoiceOver visits them (an NSArray, or
    /// null before the first update).
    pub fn accessibilityElements(self: *Bridge) id {
        return self.list;
    }

    /// Brings the elements up to date if anything changed, and tells
    /// VoiceOver.
    pub fn update(self: *Bridge) Allocator.Error!void {
        if (!self.tracker.isDirty()) return;
        if (!self.always and !UIAccessibilityIsVoiceOverRunning()) return;
        const pool = objc.objc_autoreleasePoolPush();
        defer objc.objc_autoreleasePoolPop(pool);

        self.nodes = try self.tracker.update();
        self.index.clearRetainingCapacity();
        for (self.nodes, 0..) |n, i| try self.index.put(self.gpa, n.item, @intCast(i));

        // Elements of items that are gone (or now only group others).
        var stale: std.ArrayList(*core.Item) = .empty;
        defer stale.deinit(self.gpa);
        var it = self.elements.iterator();
        while (it.next()) |e| {
            const i = self.index.get(e.key_ptr.*);
            if (i == null or !self.visited(i.?)) try stale.append(self.gpa, e.key_ptr.*);
        }
        for (stale.items) |item| {
            const e = self.elements.fetchRemove(item).?.value;
            setData(e, null);
            msg(void, e, "release", .{});
        }
        const list = msg(id, msg(id, class("NSMutableArray"), "alloc", .{}), "init", .{});
        for (self.nodes, 0..) |n, i| {
            if (!self.visited(@intCast(i))) continue;
            const gop = try self.elements.getOrPut(self.gpa, n.item);
            if (!gop.found_existing) {
                const e = msg(id, msg(id, elementClass(), "alloc", .{}), "initWithAccessibilityContainer:", .{self.view});
                setData(e, self);
                setItem(e, n.item);
                gop.value_ptr.* = e;
            }
            msg(void, list, "addObject:", .{gop.value_ptr.*});
        }
        if (self.list != null) msg(void, self.list, "release", .{});
        self.list = list;
        UIAccessibilityPostNotification(layout_changed, null);
    }

    /// Whether VoiceOver visits node `i`: what users act on or read, and
    /// groups with nothing visited inside (a labelled picture of shapes).
    fn visited(self: *const Bridge, i: u32) bool {
        const n = self.nodes[i];
        if (n.role == .table_row) return true;
        if (self.inRow(i)) return false;
        if (a11y.isLeaf(n.role)) return true;
        if (n.label.len == 0) return false;
        for (self.nodes) |other| if (other.parent == i) return false;
        return true;
    }

    /// Whether node `i` is inside a table's row (read with it).
    fn inRow(self: *const Bridge, i: u32) bool {
        var p = self.nodes[i].parent;
        while (p) |k| : (p = self.nodes[k].parent) {
            if (self.nodes[k].role == .table_row) return true;
        }
        return false;
    }

    /// A row's cells' labels, ", " between them (an NSString, or null).
    fn rowLabel(self: *const Bridge, item: *core.Item) id {
        const row = self.index.get(item) orelse return null;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        for (self.nodes, 0..) |n, k| {
            if (n.label.len == 0 or !self.within(@intCast(k), row)) continue;
            if (text.items.len > 0) text.appendSlice(self.gpa, ", ") catch return null;
            text.appendSlice(self.gpa, n.label) catch return null;
        }
        return if (text.items.len > 0) nsString(text.items) else null;
    }

    /// Whether node `i` is under node `ancestor`.
    fn within(self: *const Bridge, i: u32, ancestor: u32) bool {
        var p = self.nodes[i].parent;
        while (p) |k| : (p = self.nodes[k].parent) {
            if (k == ancestor) return true;
        }
        return false;
    }

    fn node(self: *const Bridge, item: *core.Item) ?a11y.Node {
        const i = self.index.get(item) orelse return null;
        return self.nodes[i];
    }
};

// ---- The element class ----

var element_class: id = null;
var data_offset: isize = 0;
var item_offset: isize = 0;

fn elementClass() id {
    if (element_class) |c| return c;
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("UIAccessibilityElement"), "ZiguleeAccessibilityElement", 0);
    _ = objc.class_addIvar(cls, "zigulee_bridge", @sizeOf(usize), std.math.log2_int(usize, @alignOf(usize)), "^v");
    _ = objc.class_addIvar(cls, "zigulee_item", @sizeOf(usize), std.math.log2_int(usize, @alignOf(usize)), "^v");
    inline for (.{
        .{ "accessibilityLabel", &Methods.label, "@@:" },
        .{ "accessibilityHint", &Methods.hint, "@@:" },
        .{ "accessibilityValue", &Methods.value, "@@:" },
        .{ "accessibilityTraits", &Methods.traits, "Q@:" },
        .{ "accessibilityFrameInContainerSpace", &Methods.frame, "{CGRect={CGPoint=dd}{CGSize=dd}}@:" },
        .{ "isAccessibilityElement", &Methods.isElement, "c@:" },
        .{ "accessibilityActivate", &Methods.activate, "c@:" },
        .{ "accessibilityIncrement", &Methods.increment, "v@:" },
        .{ "accessibilityDecrement", &Methods.decrement, "v@:" },
    }) |m| _ = objc.class_addMethod(cls, objc.sel(m[0]), @ptrCast(m[1]), m[2]);
    objc.objc_registerClassPair(cls);
    data_offset = objc.ivar_getOffset(objc.class_getInstanceVariable(cls, "zigulee_bridge"));
    item_offset = objc.ivar_getOffset(objc.class_getInstanceVariable(cls, "zigulee_item"));
    element_class = cls;
    return cls;
}

fn setData(e: id, bridge: ?*Bridge) void {
    objc.ivarPtr(e, data_offset).* = bridge;
}

fn setItem(e: id, item: *core.Item) void {
    objc.ivarPtr(e, item_offset).* = item;
}

/// The bridge and the node behind an element (null once the bridge is
/// gone or the item no longer accessible).
fn lookup(e: id) ?struct { *Bridge, a11y.Node } {
    const bridge: *Bridge = @ptrCast(@alignCast(objc.ivarPtr(e, data_offset).* orelse return null));
    const item: *core.Item = @ptrCast(@alignCast(objc.ivarPtr(e, item_offset).* orelse return null));
    return .{ bridge, bridge.node(item) orelse return null };
}

/// What VoiceOver says a role is (with the label and value).
fn traitsOf(n: a11y.Node) u64 {
    var t: u64 = switch (n.role) {
        .button, .checkbox, .radio_button, .switch_, .combobox, .tab => trait_button,
        .slider, .spinbox => trait_adjustable,
        .progress_indicator => trait_updates_frequently,
        .image => trait_image,
        .text, .list_item, .table_row, .table_cell => trait_static_text,
        .column_header => trait_button | trait_header,
        .tab_list => trait_tab_bar,
        .text_input, .list, .table, .group, .tab_panel, .none, .unset => 0,
    };
    if (n.checked and (n.checkable or n.role == .tab or n.role == .list_item or n.role == .table_row)) t |= trait_selected;
    if (!n.enabled) t |= trait_not_enabled;
    return t;
}

const Methods = struct {
    fn label(self: id, _: SEL) callconv(.c) id {
        const b, const n = lookup(self) orelse return null;
        if (n.label.len > 0) return nsString(n.label);
        if (n.role == .table_row) return b.rowLabel(n.item);
        return if (n.role == .text_input and n.placeholder_text.len > 0) nsString(n.placeholder_text) else null;
    }

    fn hint(self: id, _: SEL) callconv(.c) id {
        _, const n = lookup(self) orelse return null;
        return if (n.description.len > 0) nsString(n.description) else null;
    }

    fn value(self: id, _: SEL) callconv(.c) id {
        _, const n = lookup(self) orelse return null;
        // A check box or switch: on or off (as UISwitch says it).
        if (n.checkable and n.role != .tab and n.role != .list_item and n.role != .table_row) return nsString(if (n.checked) "1" else "0");
        return if (n.value.len > 0) nsString(n.value) else null;
    }

    fn traits(self: id, _: SEL) callconv(.c) u64 {
        _, const n = lookup(self) orelse return 0;
        return traitsOf(n);
    }

    fn frame(self: id, _: SEL) callconv(.c) NSRect {
        _, const n = lookup(self) orelse return .{};
        return .{ .origin = .{ .x = n.bounds.x, .y = n.bounds.y }, .size = .{ .width = n.bounds.width, .height = n.bounds.height } };
    }

    fn isElement(_: id, _: SEL) callconv(.c) BOOL {
        return true;
    }

    fn perform(self: id, action: a11y.Action) BOOL {
        const b, const n = lookup(self) orelse return false;
        return a11y.perform(b.ui, n.item, action);
    }

    fn activate(self: id, _: SEL) callconv(.c) BOOL {
        return perform(self, .default);
    }

    fn increment(self: id, _: SEL) callconv(.c) void {
        _ = perform(self, .increment);
    }

    fn decrement(self: id, _: SEL) callconv(.c) void {
        _ = perform(self, .decrement);
    }
};

test "roles as traits" {
    const item: *core.Item = @ptrFromInt(@alignOf(core.Item));
    try std.testing.expectEqual(trait_button | trait_selected, traitsOf(.{ .item = item, .parent = null, .role = .checkbox, .label = "", .checkable = true, .checked = true, .bounds = .{} }));
    try std.testing.expectEqual(trait_adjustable | trait_not_enabled, traitsOf(.{ .item = item, .parent = null, .role = .slider, .label = "", .enabled = false, .bounds = .{} }));
}
