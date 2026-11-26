// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! What assistive technology (screen readers) sees of a window: the items
//! with an accessible role, their texts, values and states, and the actions
//! it can perform on them. Platform bridges (VoiceOver, ...) read a
//! snapshot with `Tracker.update` whenever its dependencies change, and
//! map it to the platform's accessibility API.

const std = @import("std");
const Allocator = std.mem.Allocator;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const AccessibleRole = item_mod.AccessibleRole;
const Window = @import("window.zig").Window;
const PropertyTracker = @import("properties.zig").PropertyTracker;
const Rect = @import("geometry.zig").Rect;

pub const Node = struct {
    item: *Item,
    /// The index of the nearest accessible ancestor in the snapshot (null:
    /// the window).
    parent: ?u32,
    role: AccessibleRole,
    label: []const u8,
    description: []const u8 = "",
    value: []const u8 = "",
    value_minimum: f32 = 0,
    value_maximum: f32 = 0,
    value_step: f32 = 0,
    placeholder_text: []const u8 = "",
    checkable: bool = false,
    /// Checked, or (an item of a list or table, a tab) selected.
    checked: bool = false,
    /// A list or table whose items can be selected several at once.
    multiselectable: bool = false,
    enabled: bool = true,
    /// It or something inside it has the keyboard focus.
    focused: bool = false,
    /// In window coordinates (logical pixels).
    bounds: Rect,
};

pub const Action = enum {
    /// Press a button, toggle a check box, open a combo box...
    default,
    increment,
    decrement,
    /// Give it the keyboard focus.
    focus,
    /// Select it, and only it (an item of a list or table; without a
    /// handler, its default action).
    select,
};

/// The accessible items of `window`, in tree order, each after its
/// accessible ancestors. Invisible items and their children are left out;
/// items without a role are skipped, but their children are not.
pub fn collect(window: *Window, gpa: Allocator, out: *std.ArrayList(Node)) Allocator.Error!void {
    out.clearRetainingCapacity();
    try visit(window, gpa, out, &window.root.item, null, .{});
}

const Offset = struct { x: f32 = 0, y: f32 = 0 };

fn visit(window: *Window, gpa: Allocator, out: *std.ArrayList(Node), item: *Item, parent: ?u32, origin: Offset) Allocator.Error!void {
    if (!item.visible.get()) return;
    const pos: Offset = .{ .x = origin.x + item.x.get(), .y = origin.y + item.y.get() };
    var here = parent;
    const role = item.accessibleRole();
    if (role != .none and role != .unset) {
        var node: Node = .{
            .item = item,
            .parent = parent,
            .role = role,
            .label = item.accessibleLabel(),
            .bounds = .{ .x = pos.x, .y = pos.y, .width = item.width.get(), .height = item.height.get() },
            .value = item.accessibleValue(),
            .focused = if (window.focus_item) |f| item.contains(f) else false,
            .enabled = item.isEnabled(),
        };
        if (item.accessible) |a| {
            node.description = a.description.get();
            node.value_minimum = a.value_minimum.get();
            node.value_maximum = a.value_maximum.get();
            node.value_step = a.value_step.get();
            node.placeholder_text = a.placeholder_text.get();
            node.checkable = a.checkable.get();
            node.checked = a.checked.get();
            node.enabled = node.enabled and a.enabled.get();
            node.multiselectable = a.multiselectable.get();
        }
        try out.append(gpa, node);
        here = @intCast(out.items.len - 1);
        // Controls are read as a whole: their label is not another node.
        if (isLeaf(role)) return;
    }
    var children = item.children();
    while (children.next()) |c| try visit(window, gpa, out, c, here, pos);
}

/// Roles whose children are part of them (a button's text) rather than
/// nodes of their own.
pub fn isLeaf(role: AccessibleRole) bool {
    return switch (role) {
        .button, .checkbox, .radio_button, .switch_, .slider, .spinbox, .combobox, .list_item, .tab, .text_input, .progress_indicator, .image, .text, .table_cell, .column_header => true,
        .unset, .none, .list, .tab_list, .tab_panel, .table, .table_row, .group => false,
    };
}

/// Performs `action` on `item`; false if it does not support it. The
/// default action of a text field without a handler focuses it.
pub fn perform(window: *Window, item: *Item, action: Action) bool {
    if (action == .focus) return focus(window, item);
    const a = item.accessible orelse return action == .default and focus(window, item);
    if (action == .select and !a.action_select.hasHandler()) return perform(window, item, .default);
    const cb = switch (action) {
        .default => &a.action_default,
        .increment => &a.action_increment,
        .decrement => &a.action_decrement,
        .select => &a.action_select,
        .focus => unreachable,
    };
    if (!cb.hasHandler()) return action == .default and focus(window, item);
    cb.call(.{});
    return true;
}

/// Sets the value of `item` (a text field's text, a slider's position).
pub fn setValue(item: *Item, value: []const u8) bool {
    const a = item.accessible orelse return false;
    if (!a.action_set_value.hasHandler()) return false;
    a.action_set_value.call(.{value});
    return true;
}

/// Adds `item` (of a list or table) to the selection, or removes it; false
/// if it cannot be.
pub fn setSelected(item: *Item, on: bool) bool {
    const a = item.accessible orelse return false;
    if (!a.action_set_selected.hasHandler()) return false;
    a.action_set_selected.call(.{on});
    return true;
}

/// Focuses `item`, or the first item inside it that takes focus.
fn focus(window: *Window, item: *Item) bool {
    var it: ?*Item = item;
    while (it) |i| : (it = nextWithin(i, item)) {
        if (i.acceptsFocus() and i.isVisibleInTree()) {
            window.setFocusItem(i);
            return true;
        }
    }
    return false;
}

fn nextWithin(item: *Item, scope: *Item) ?*Item {
    if (item.first_child) |c| return c;
    var it = item;
    while (it != scope) : (it = it.parent.?) {
        if (it.next_sibling) |n| return n;
    }
    return null;
}

/// Keeps a snapshot of a window's accessible items, and reports when
/// anything in it changes (`setChangeListener`), so a bridge updates the
/// platform only then. Must not move after `update`.
pub const Tracker = struct {
    gpa: Allocator,
    window: *Window,
    tracker: PropertyTracker,
    nodes: std.ArrayList(Node) = .empty,

    pub fn init(gpa: Allocator, window: *Window) Tracker {
        return .{ .gpa = gpa, .window = window, .tracker = .init(gpa) };
    }

    pub fn deinit(self: *Tracker) void {
        self.tracker.deinit();
        self.nodes.deinit(self.gpa);
    }

    /// `listener(ctx)` is called the first time something in the snapshot
    /// changes after an `update` (not from inside the property graph's
    /// evaluation: it must only schedule work).
    pub fn setChangeListener(self: *Tracker, ctx: anytype, comptime listener: fn (@TypeOf(ctx)) void) void {
        self.tracker.setDirtyListener(ctx, listener);
    }

    pub fn isDirty(self: *Tracker) bool {
        return self.tracker.isDirty();
    }

    /// Brings the snapshot up to date, if anything changed.
    pub fn update(self: *Tracker) Allocator.Error![]const Node {
        if (self.tracker.isDirty()) {
            const r = self.tracker.evaluate(self, collectTracked);
            try r;
        }
        return self.nodes.items;
    }

    fn collectTracked(self: *Tracker) Allocator.Error!void {
        // Focus is not a property: read the window's focus generation.
        _ = self.window.focus_generation.get();
        return collect(self.window, self.gpa, &self.nodes);
    }
};
