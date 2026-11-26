// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! VoiceOver support: shows a zigulee window's accessible items
//! (`zigulee.core.accessibility`) to macOS through NSAccessibility.
//!
//! Each accessible item gets an element (a subclass of
//! NSAccessibilityElement made at run time) that answers from the latest
//! snapshot and performs actions through zigulee. The window's content view
//! lists the top-level elements. Elements are kept per item, so VoiceOver
//! does not lose its place when the snapshot changes.
//!
//! Everything runs on the main thread (AppKit asks there, and that is where
//! the zigulee event loop runs).

const std = @import("std");
const builtin = @import("builtin");
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
const sel = objc.sel;
const nsString = objc.nsString;
const objc_allocateClassPair = objc.objc_allocateClassPair;
const objc_registerClassPair = objc.objc_registerClassPair;
const class_addMethod = objc.class_addMethod;
const class_addIvar = objc.class_addIvar;
const class_getInstanceVariable = objc.class_getInstanceVariable;
const ivar_getOffset = objc.ivar_getOffset;
const objc_autoreleasePoolPush = objc.objc_autoreleasePoolPush;
const objc_autoreleasePoolPop = objc.objc_autoreleasePoolPop;
extern "c" fn NSAccessibilityPostNotification(element: id, notification: id) void;

fn nsNumber(v: f64) id {
    return msg(id, class("NSNumber"), "numberWithDouble:", .{v});
}

fn nsBool(v: bool) id {
    return msg(id, class("NSNumber"), "numberWithBool:", .{v});
}

// ---- The bridge ----

pub const Bridge = struct {
    gpa: Allocator,
    ui: *core.Window,
    ns_window: id,
    view: id,
    tracker: a11y.Tracker,
    /// The element of each accessible item (retained).
    elements: std.AutoHashMapUnmanaged(*core.Item, id) = .empty,
    /// The latest snapshot, and where each item is in it.
    nodes: []const a11y.Node = &.{},
    index: std.AutoHashMapUnmanaged(*core.Item, u32) = .empty,
    focused: ?*core.Item = null,
    /// Update even when VoiceOver is off (tests, other assistive apps).
    always: bool = false,

    /// Shows `ui`'s accessible items in `ns_window` (an NSWindow). Call
    /// `update` from the event loop. Both must outlive the bridge.
    pub fn create(gpa: Allocator, ui: *core.Window, ns_window: id) Allocator.Error!*Bridge {
        const self = try gpa.create(Bridge);
        self.* = .{
            .gpa = gpa,
            .ui = ui,
            .ns_window = ns_window,
            .view = msg(id, ns_window, "contentView", .{}),
            .tracker = .init(gpa, ui),
        };
        // For tools like Accessibility Inspector, which read the tree without
        // VoiceOver running.
        self.always = std.c.getenv("ZIGULEE_ACCESSIBILITY") != null;
        // The content view groups the elements.
        msg(void, self.view, "setAccessibilityElement:", .{true});
        msg(void, self.view, "setAccessibilityRole:", .{nsString("AXGroup")});
        return self;
    }

    pub fn destroy(self: *Bridge) void {
        msg(void, self.view, "setAccessibilityChildren:", .{@as(id, null)});
        var it = self.elements.valueIterator();
        while (it.next()) |e| {
            setData(e.*, null);
            msg(void, e.*, "release", .{});
        }
        self.elements.deinit(self.gpa);
        self.index.deinit(self.gpa);
        self.tracker.deinit();
        self.gpa.destroy(self);
    }

    /// Brings the elements up to date if anything changed, and tells
    /// VoiceOver what did.
    pub fn update(self: *Bridge) Allocator.Error!void {
        if (!self.tracker.isDirty()) return;
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);
        if (!self.always and !voiceOverRunning()) return;
        var old_values: std.AutoHashMapUnmanaged(*core.Item, u64) = .empty;
        defer old_values.deinit(self.gpa);
        for (self.nodes) |n| try old_values.put(self.gpa, n.item, std.hash.Wyhash.hash(0, n.value));
        var old_selected: std.AutoHashMapUnmanaged(*core.Item, bool) = .empty;
        defer old_selected.deinit(self.gpa);
        for (self.nodes) |n| if (isSelectionItem(n.role)) try old_selected.put(self.gpa, n.item, n.checked);

        self.nodes = try self.tracker.update();
        self.index.clearRetainingCapacity();
        for (self.nodes, 0..) |n, i| try self.index.put(self.gpa, n.item, @intCast(i));

        // Elements of items that are gone.
        var stale: std.ArrayList(*core.Item) = .empty;
        defer stale.deinit(self.gpa);
        var it = self.elements.iterator();
        while (it.next()) |e| if (!self.index.contains(e.key_ptr.*)) try stale.append(self.gpa, e.key_ptr.*);
        for (stale.items) |item| {
            const e = self.elements.fetchRemove(item).?.value;
            setData(e, null);
            msg(void, e, "release", .{});
        }
        // New ones.
        for (self.nodes) |n| {
            const gop = try self.elements.getOrPut(self.gpa, n.item);
            if (!gop.found_existing) {
                const e = msg(id, msg(id, elementClass(), "alloc", .{}), "init", .{});
                setData(e, self);
                setItem(e, n.item);
                gop.value_ptr.* = e;
            }
        }
        msg(void, self.view, "setAccessibilityChildren:", .{self.childrenOf(null)});

        // What VoiceOver should hear about.
        for (self.nodes) |n| {
            const before = old_values.get(n.item) orelse continue;
            if (before != std.hash.Wyhash.hash(0, n.value)) NSAccessibilityPostNotification(self.elements.get(n.item).?, nsString("AXValueChanged"));
        }
        // Lists and tables whose selection changed (told once each).
        var reselected: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
        defer reselected.deinit(self.gpa);
        for (self.nodes) |n| {
            const before = old_selected.get(n.item) orelse continue;
            if (before == n.checked) continue;
            if (n.parent) |p| if (isSelectionContainer(self.nodes[p].role)) try reselected.put(self.gpa, p, {});
        }
        for (reselected.keys()) |p| {
            const container = self.nodes[p];
            NSAccessibilityPostNotification(self.elements.get(container.item).?, nsString(if (container.role == .table) "AXSelectedRowsChanged" else "AXSelectedChildrenChanged"));
        }
        var focused: ?*core.Item = null;
        for (self.nodes) |n| {
            if (n.focused) focused = n.item;
        }
        if (focused != self.focused) {
            self.focused = focused;
            if (focused) |f| NSAccessibilityPostNotification(self.elements.get(f).?, nsString("AXFocusedUIElementChanged"));
        }
        NSAccessibilityPostNotification(self.view, nsString("AXLayoutChanged"));
    }

    fn node(self: *const Bridge, item: *core.Item) ?a11y.Node {
        const i = self.index.get(item) orelse return null;
        return self.nodes[i];
    }

    /// An NSArray of the elements whose parent is `parent` (null: the
    /// window).
    fn childrenOf(self: *Bridge, parent: ?*core.Item) id {
        const array = msg(id, class("NSMutableArray"), "array", .{});
        const parent_index: ?u32 = if (parent) |p| self.index.get(p) else null;
        for (self.nodes) |n| {
            if (n.parent != parent_index) continue;
            msg(void, array, "addObject:", .{self.elements.get(n.item).?});
        }
        return array;
    }

    /// An NSArray of the elements of `container`'s children with `role`
    /// (any selection item when null), only the selected ones if
    /// `selected_only`.
    fn childrenWith(self: *Bridge, container: *core.Item, role: ?core.AccessibleRole, selected_only: bool) id {
        const array = msg(id, class("NSMutableArray"), "array", .{});
        const parent_index = self.index.get(container) orelse return array;
        for (self.nodes) |n| {
            if (n.parent != parent_index) continue;
            if (if (role) |r| n.role != r else !isSelectionItem(n.role)) continue;
            if (selected_only and !(isSelectionItem(n.role) and n.checked)) continue;
            msg(void, array, "addObject:", .{self.elements.get(n.item).?});
        }
        return array;
    }

    /// Selects `container`'s items in `wanted` (an NSArray of elements),
    /// and only those.
    fn selectOnly(self: *Bridge, container: a11y.Node, wanted: id) void {
        const parent_index = self.index.get(container.item) orelse return;
        // Snapshot first: selecting changes the items.
        var items: std.ArrayList(struct { *core.Item, bool, bool }) = .empty;
        defer items.deinit(self.gpa);
        for (self.nodes) |n| {
            if (n.parent != parent_index or !isSelectionItem(n.role)) continue;
            const want = wanted != null and msg(BOOL, wanted, "containsObject:", .{self.elements.get(n.item).?});
            items.append(self.gpa, .{ n.item, n.checked, want }) catch return;
        }
        for (items.items) |entry| {
            const item, const was, const want = entry;
            if (was != want) _ = select(self, item, want, container.multiselectable);
        }
    }

    /// `bounds` (window coordinates, top-left origin) on the screen.
    fn screenFrame(self: *Bridge, bounds: core.Rect) NSRect {
        const content = msg(NSRect, self.view, "frame", .{});
        const in_window: NSRect = .{
            .origin = .{ .x = bounds.x, .y = content.size.height - bounds.y - bounds.height },
            .size = .{ .width = bounds.width, .height = bounds.height },
        };
        return msg(NSRect, self.ns_window, "convertRectToScreen:", .{in_window});
    }
};

fn isSelectionItem(role: core.AccessibleRole) bool {
    return role == .list_item or role == .table_row;
}

fn isSelectionContainer(role: core.AccessibleRole) bool {
    return role == .list or role == .table;
}

/// Adds `item` to its list's selection or removes it (selecting only it
/// when one at a time is selected).
fn select(b: *Bridge, item: *core.Item, on: bool, multiple: bool) bool {
    if (!on) return a11y.setSelected(item, false);
    return (multiple and a11y.setSelected(item, true)) or a11y.perform(b.ui, item, .select);
}

fn voiceOverRunning() bool {
    const workspace = msg(id, class("NSWorkspace"), "sharedWorkspace", .{});
    return msg(BOOL, workspace, "isVoiceOverEnabled", .{});
}

// ---- The element class ----

var element_class: id = null;
var data_offset: isize = 0;
var item_offset: isize = 0;

fn elementClass() id {
    if (element_class) |c| return c;
    const cls = objc_allocateClassPair(objc.objc_getClass("NSAccessibilityElement"), "ZiguleeAccessibilityElement", 0);
    _ = class_addIvar(cls, "zigulee_bridge", @sizeOf(usize), std.math.log2_int(usize, @alignOf(usize)), "^v");
    _ = class_addIvar(cls, "zigulee_item", @sizeOf(usize), std.math.log2_int(usize, @alignOf(usize)), "^v");
    inline for (.{
        .{ "accessibilityRole", &Methods.role, "@@:" },
        .{ "accessibilitySubrole", &Methods.subrole, "@@:" },
        .{ "accessibilityLabel", &Methods.label, "@@:" },
        .{ "accessibilityHelp", &Methods.help, "@@:" },
        .{ "accessibilityValue", &Methods.value, "@@:" },
        .{ "accessibilityMinValue", &Methods.minValue, "@@:" },
        .{ "accessibilityMaxValue", &Methods.maxValue, "@@:" },
        .{ "accessibilityPlaceholderValue", &Methods.placeholder, "@@:" },
        .{ "accessibilityParent", &Methods.parent, "@@:" },
        .{ "accessibilityChildren", &Methods.children, "@@:" },
        .{ "accessibilityFrame", &Methods.frame, "{CGRect={CGPoint=dd}{CGSize=dd}}@:" },
        .{ "isAccessibilityElement", &Methods.isElement, "c@:" },
        .{ "isAccessibilityEnabled", &Methods.enabled, "c@:" },
        .{ "isAccessibilityFocused", &Methods.focused, "c@:" },
        .{ "isAccessibilitySelected", &Methods.selected, "c@:" },
        .{ "accessibilityPerformPress", &Methods.press, "c@:" },
        .{ "accessibilityPerformIncrement", &Methods.increment, "c@:" },
        .{ "accessibilityPerformDecrement", &Methods.decrement, "c@:" },
        .{ "setAccessibilityValue:", &Methods.setValue, "v@:@" },
        .{ "setAccessibilityFocused:", &Methods.setFocused, "v@:c" },
        .{ "setAccessibilitySelected:", &Methods.setSelected, "v@:c" },
        .{ "accessibilitySelectedChildren", &Methods.selectedChildren, "@@:" },
        .{ "setAccessibilitySelectedChildren:", &Methods.setSelectedChildren, "v@:@" },
        .{ "accessibilityRows", &Methods.rows, "@@:" },
        .{ "accessibilitySelectedRows", &Methods.selectedRows, "@@:" },
        .{ "setAccessibilitySelectedRows:", &Methods.setSelectedChildren, "v@:@" },
        .{ "accessibilityColumnHeaderUIElements", &Methods.columnHeaders, "@@:" },
        .{ "isAccessibilitySelectorAllowed:", &Methods.selectorAllowed, "c@::" },
    }) |m| _ = class_addMethod(cls, sel(m[0]), @ptrCast(m[1]), m[2]);
    objc_registerClassPair(cls);
    data_offset = ivar_getOffset(class_getInstanceVariable(cls, "zigulee_bridge"));
    item_offset = ivar_getOffset(class_getInstanceVariable(cls, "zigulee_item"));
    element_class = cls;
    return cls;
}

fn ivar(e: id, offset: isize) *?*anyopaque {
    const base: [*]u8 = @ptrCast(e.?);
    return @ptrCast(@alignCast(base + @as(usize, @intCast(offset))));
}

fn setData(e: id, bridge: ?*Bridge) void {
    ivar(e, data_offset).* = bridge;
}

fn setItem(e: id, item: *core.Item) void {
    ivar(e, item_offset).* = item;
}

/// The bridge and the node behind an element (null once the bridge is
/// gone or the item no longer accessible).
fn lookup(e: id) ?struct { *Bridge, a11y.Node } {
    const bridge: *Bridge = @ptrCast(@alignCast(ivar(e, data_offset).* orelse return null));
    const item: *core.Item = @ptrCast(@alignCast(ivar(e, item_offset).* orelse return null));
    return .{ bridge, bridge.node(item) orelse return null };
}

fn axRole(role: core.AccessibleRole) []const u8 {
    return switch (role) {
        .button => "AXButton",
        .checkbox, .switch_ => "AXCheckBox",
        .radio_button => "AXRadioButton",
        .combobox => "AXPopUpButton",
        .list => "AXList",
        .list_item => "AXStaticText",
        .slider => "AXSlider",
        .spinbox => "AXIncrementor",
        .tab => "AXRadioButton",
        .tab_list => "AXTabGroup",
        .table => "AXTable",
        .table_row => "AXRow",
        .table_cell => "AXCell",
        .column_header => "AXButton",
        .text => "AXStaticText",
        .text_input => "AXTextField",
        .progress_indicator => "AXProgressIndicator",
        .image => "AXImage",
        .group, .tab_panel, .none, .unset => "AXGroup",
    };
}

const Methods = struct {
    fn role(self: id, _: SEL) callconv(.c) id {
        const b, const n = lookup(self) orelse return nsString("AXUnknown");
        _ = b;
        return nsString(axRole(n.role));
    }

    fn subrole(self: id, _: SEL) callconv(.c) id {
        _, const n = lookup(self) orelse return null;
        return if (n.role == .switch_) nsString("AXSwitch") else null;
    }

    fn label(self: id, _: SEL) callconv(.c) id {
        _, const n = lookup(self) orelse return null;
        return nsString(n.label);
    }

    fn help(self: id, _: SEL) callconv(.c) id {
        _, const n = lookup(self) orelse return null;
        return if (n.description.len > 0) nsString(n.description) else null;
    }

    fn value(self: id, _: SEL) callconv(.c) id {
        _, const n = lookup(self) orelse return null;
        if (n.checkable) return nsBool(n.checked);
        return switch (n.role) {
            .slider, .spinbox, .progress_indicator => if (std.fmt.parseFloat(f64, std.mem.trimEnd(u8, n.value, "%"))) |v|
                nsNumber(if (n.role == .progress_indicator and std.mem.endsWith(u8, n.value, "%")) v / 100 else v)
            else |_|
                nsString(n.value),
            else => nsString(n.value),
        };
    }

    fn minValue(self: id, _: SEL) callconv(.c) id {
        _, const n = lookup(self) orelse return null;
        return nsNumber(n.value_minimum);
    }

    fn maxValue(self: id, _: SEL) callconv(.c) id {
        _, const n = lookup(self) orelse return null;
        return nsNumber(n.value_maximum);
    }

    fn placeholder(self: id, _: SEL) callconv(.c) id {
        _, const n = lookup(self) orelse return null;
        return if (n.placeholder_text.len > 0) nsString(n.placeholder_text) else null;
    }

    fn parent(self: id, _: SEL) callconv(.c) id {
        const b, const n = lookup(self) orelse return null;
        const p = n.parent orelse return b.view;
        return b.elements.get(b.nodes[p].item) orelse b.view;
    }

    fn children(self: id, _: SEL) callconv(.c) id {
        const b, const n = lookup(self) orelse return msg(id, class("NSArray"), "array", .{});
        return b.childrenOf(n.item);
    }

    fn frame(self: id, _: SEL) callconv(.c) NSRect {
        const b, const n = lookup(self) orelse return std.mem.zeroes(NSRect);
        return b.screenFrame(n.bounds);
    }

    fn isElement(_: id, _: SEL) callconv(.c) BOOL {
        return true;
    }

    fn enabled(self: id, _: SEL) callconv(.c) BOOL {
        _, const n = lookup(self) orelse return false;
        return n.enabled;
    }

    fn focused(self: id, _: SEL) callconv(.c) BOOL {
        _, const n = lookup(self) orelse return false;
        return n.focused;
    }

    fn selected(self: id, _: SEL) callconv(.c) BOOL {
        _, const n = lookup(self) orelse return false;
        return (n.role == .tab or n.role == .list_item or n.role == .table_row) and n.checked;
    }

    fn perform(self: id, action: a11y.Action) BOOL {
        const b, const n = lookup(self) orelse return false;
        return a11y.perform(b.ui, n.item, action);
    }

    fn press(self: id, _: SEL) callconv(.c) BOOL {
        return perform(self, .default);
    }

    fn increment(self: id, _: SEL) callconv(.c) BOOL {
        return perform(self, .increment);
    }

    fn decrement(self: id, _: SEL) callconv(.c) BOOL {
        return perform(self, .decrement);
    }

    fn setValue(self: id, _: SEL, v: id) callconv(.c) void {
        _, const n = lookup(self) orelse return;
        const utf8 = msg(?[*:0]const u8, v, "UTF8String", .{}) orelse return;
        _ = a11y.setValue(n.item, std.mem.span(utf8));
    }

    fn setFocused(self: id, _: SEL, f: BOOL) callconv(.c) void {
        if (f) _ = perform(self, .focus);
    }

    // Lists' and tables' items selected.

    fn setSelected(self: id, _: SEL, on: BOOL) callconv(.c) void {
        const b, const n = lookup(self) orelse return;
        if (!isSelectionItem(n.role) or n.checked == on) return;
        const multiple = if (n.parent) |p| b.nodes[p].multiselectable else false;
        _ = select(b, n.item, on, multiple);
    }

    fn selectedChildren(self: id, _: SEL) callconv(.c) id {
        const b, const n = lookup(self) orelse return null;
        if (!isSelectionContainer(n.role)) return null;
        return b.childrenWith(n.item, null, true);
    }

    fn setSelectedChildren(self: id, _: SEL, wanted: id) callconv(.c) void {
        const b, const n = lookup(self) orelse return;
        if (isSelectionContainer(n.role)) b.selectOnly(n, wanted);
    }

    fn rows(self: id, _: SEL) callconv(.c) id {
        const b, const n = lookup(self) orelse return null;
        return if (n.role == .table) b.childrenWith(n.item, .table_row, false) else null;
    }

    fn selectedRows(self: id, _: SEL) callconv(.c) id {
        const b, const n = lookup(self) orelse return null;
        return if (n.role == .table) b.childrenWith(n.item, .table_row, true) else null;
    }

    fn columnHeaders(self: id, _: SEL) callconv(.c) id {
        const b, const n = lookup(self) orelse return null;
        return if (n.role == .table) b.childrenWith(n.item, .column_header, false) else null;
    }

    /// The selection's methods only where they apply (AppKit lists an
    /// element's attributes, and which can be set, from this).
    fn selectorAllowed(self: id, _: SEL, selector: SEL) callconv(.c) BOOL {
        const n: ?a11y.Node = if (lookup(self)) |found| found[1] else null;
        const kind: core.AccessibleRole = if (n) |node| node.role else .none;
        if (selector == sel("setAccessibilitySelected:")) return isSelectionItem(kind);
        if (selector == sel("accessibilitySelectedChildren") or selector == sel("setAccessibilitySelectedChildren:")) return kind == .list;
        if (selector == sel("accessibilityRows") or selector == sel("accessibilitySelectedRows") or
            selector == sel("setAccessibilitySelectedRows:") or selector == sel("accessibilityColumnHeaderUIElements")) return kind == .table;
        return objc.msgSuper(BOOL, self, elementClass(), "isAccessibilitySelectorAllowed:", .{selector});
    }
};

// ---- Tests ----

const testing = std.testing;

test "a window's items as NSAccessibility elements, with actions" {
    _ = msg(id, class("NSApplication"), "sharedApplication", .{});
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    const rect: NSRect = .{ .origin = .{ .x = 100, .y = 100 }, .size = .{ .width = 200, .height = 100 } };
    const ns_window = msg(id, msg(id, class("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ rect, @as(usize, 1), @as(usize, 2), false });
    defer msg(void, ns_window, "close", .{});
    msg(void, ns_window, "setReleasedWhenClosed:", .{false});
    defer msg(void, ns_window, "release", .{});

    // A window with a button (a rectangle with accessible properties) and a
    // label inside it, which is part of the button.
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 200, .height = 100 });
    defer ui.deinit();
    var button: core.items.Rectangle = .{};
    defer button.deinit();
    var label: core.items.Text = .{};
    defer label.deinit();
    var props: core.AccessibleProperties = .{};
    defer props.deinit();
    ui.rootItem().appendChild(&button.item);
    button.item.appendChild(&label.item);
    button.item.setGeometry(.{ .x = 10, .y = 20, .width = 80, .height = 30 });
    label.text.set("OK");
    button.item.accessible = &props;
    props.role.set(.button);
    props.label.set("OK");
    var pressed: u32 = 0;
    props.action_default.setHandler(&pressed, struct {
        fn f(n: *u32) void {
            n.* += 1;
        }
    }.f);

    const bridge = try Bridge.create(testing.allocator, &ui, ns_window);
    defer bridge.destroy();
    bridge.always = true;
    try bridge.update();

    const view = msg(id, ns_window, "contentView", .{});
    const kids = msg(id, view, "accessibilityChildren", .{});
    try testing.expectEqual(@as(usize, 1), msg(usize, kids, "count", .{}));
    const element = msg(id, kids, "objectAtIndex:", .{@as(usize, 0)});
    const text = struct {
        fn of(s: id) []const u8 {
            return std.mem.span(msg([*:0]const u8, s, "UTF8String", .{}));
        }
    }.of;
    try testing.expectEqualStrings("AXButton", text(msg(id, element, "accessibilityRole", .{})));
    try testing.expectEqualStrings("OK", text(msg(id, element, "accessibilityLabel", .{})));
    try testing.expectEqual(@as(usize, 0), msg(usize, msg(id, element, "accessibilityChildren", .{}), "count", .{}));
    try testing.expect(msg(BOOL, element, "isAccessibilityEnabled", .{}));
    try testing.expectEqual(view, msg(id, element, "accessibilityParent", .{}));

    // On screen: the window's content origin is at (100, 100), bottom-left,
    // and the button is 20 points below the top of the 100 point high view.
    const frame = msg(NSRect, element, "accessibilityFrame", .{});
    try testing.expectEqual(@as(f64, 80), frame.size.width);
    try testing.expectEqual(@as(f64, 100 + 100 - 20 - 30), frame.origin.y);

    try testing.expect(msg(BOOL, element, "accessibilityPerformPress", .{}));
    try testing.expectEqual(@as(u32, 1), pressed);

    // Changes show at the next update; the element is the same object.
    props.label.set("Save");
    try bridge.update();
    try testing.expectEqual(element, msg(id, msg(id, view, "accessibilityChildren", .{}), "objectAtIndex:", .{@as(usize, 0)}));
    try testing.expectEqualStrings("Save", text(msg(id, element, "accessibilityLabel", .{})));
}

test "a list's items selected through NSAccessibility" {
    _ = msg(id, class("NSApplication"), "sharedApplication", .{});
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    const rect: NSRect = .{ .origin = .{ .x = 100, .y = 100 }, .size = .{ .width = 200, .height = 100 } };
    const ns_window = msg(id, msg(id, class("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ rect, @as(usize, 1), @as(usize, 2), false });
    defer msg(void, ns_window, "close", .{});
    msg(void, ns_window, "setReleasedWhenClosed:", .{false});
    defer msg(void, ns_window, "release", .{});

    // A list of two items, several selectable.
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 200, .height = 100 });
    defer ui.deinit();
    var list: core.items.Rectangle = .{};
    defer list.deinit();
    var list_props: core.AccessibleProperties = .{};
    defer list_props.deinit();
    var rows: [2]core.items.Rectangle = .{ .{}, .{} };
    defer for (&rows) |*r| r.deinit();
    var row_props: [2]core.AccessibleProperties = .{ .{}, .{} };
    defer for (&row_props) |*p| p.deinit();
    ui.rootItem().appendChild(&list.item);
    list.item.setGeometry(.{ .width = 200, .height = 100 });
    list.item.accessible = &list_props;
    list_props.role.set(.list);
    list_props.multiselectable.set(true);
    for (&rows, &row_props, 0..) |*row, *props, i| {
        list.item.appendChild(&row.item);
        row.item.setGeometry(.{ .y = @floatFromInt(i * 30), .width = 200, .height = 30 });
        row.item.accessible = props;
        props.role.set(.list_item);
        props.label.set(if (i == 0) "Ada" else "Grace");
        props.action_set_selected.setHandler(props, struct {
            fn f(p: *core.AccessibleProperties, on: bool) void {
                p.checked.set(on);
            }
        }.f);
    }

    const bridge = try Bridge.create(testing.allocator, &ui, ns_window);
    defer bridge.destroy();
    bridge.always = true;
    try bridge.update();
    const view = msg(id, ns_window, "contentView", .{});
    const element = msg(id, msg(id, view, "accessibilityChildren", .{}), "objectAtIndex:", .{@as(usize, 0)});
    const items = msg(id, element, "accessibilityChildren", .{});
    const ada = msg(id, items, "objectAtIndex:", .{@as(usize, 0)});
    const grace = msg(id, items, "objectAtIndex:", .{@as(usize, 1)});
    const count = struct {
        fn of(array: id) usize {
            return if (array == null) 0 else msg(usize, array, "count", .{});
        }
    }.of;

    // What each says it can do.
    try testing.expect(msg(BOOL, element, "isAccessibilitySelectorAllowed:", .{sel("setAccessibilitySelectedChildren:")}));
    try testing.expect(!msg(BOOL, element, "isAccessibilitySelectorAllowed:", .{sel("setAccessibilitySelectedRows:")}));
    try testing.expect(msg(BOOL, ada, "isAccessibilitySelectorAllowed:", .{sel("setAccessibilitySelected:")}));
    try testing.expect(!msg(BOOL, ada, "isAccessibilitySelectorAllowed:", .{sel("setAccessibilitySelectedChildren:")}));

    // An item selected, then another added; then the list's choice.
    msg(void, ada, "setAccessibilitySelected:", .{true});
    try bridge.update();
    msg(void, grace, "setAccessibilitySelected:", .{true});
    try bridge.update();
    try testing.expectEqual(@as(usize, 2), count(msg(id, element, "accessibilitySelectedChildren", .{})));
    try testing.expect(msg(BOOL, ada, "isAccessibilitySelected", .{}));
    const only_grace = msg(id, class("NSArray"), "arrayWithObject:", .{grace});
    msg(void, element, "setAccessibilitySelectedChildren:", .{only_grace});
    try bridge.update();
    try testing.expect(!row_props[0].checked.get() and row_props[1].checked.get());
    try testing.expectEqual(grace, msg(id, msg(id, element, "accessibilitySelectedChildren", .{}), "objectAtIndex:", .{@as(usize, 0)}));
    msg(void, grace, "setAccessibilitySelected:", .{false});
    try bridge.update();
    try testing.expectEqual(@as(usize, 0), count(msg(id, element, "accessibilitySelectedChildren", .{})));
}
