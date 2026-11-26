// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Windows accessibility: shows a zigulee window's accessible items
//! (`zigulee.core.accessibility`) to screen readers (Narrator, NVDA, JAWS)
//! through UI Automation.
//!
//! Each accessible item gets a provider object (COM, written here) that
//! answers from the latest snapshot and performs actions through zigulee;
//! the window's root provider is returned to UI Automation when it asks
//! the window (WM_GETOBJECT, through a window procedure placed in front of
//! the backend's). Providers are kept per item, so a screen reader does not
//! lose its place when the snapshot changes; those of items that are gone
//! answer UIA_E_ELEMENTNOTAVAILABLE until released.
//!
//! The declarations come from the Windows SDK headers that ship with Zig
//! (translated: module "uia_c"). Everything runs on the window's thread:
//! the providers use COM threading, so UI Automation brings its calls there
//! (while the thread handles window messages).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const a11y = core.accessibility;
const c = @import("uia_c");

const log = std.log.scoped(.zigulee_uia);

fn guid(a: u32, b: u16, cc: u16, d: [8]u8) c.GUID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = cc, .Data4 = d };
}

// Interface IDs (from the headers' __CRT_UUID_DECL).
const iid_unknown = guid(0x00000000, 0x0000, 0x0000, .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 });
const iid_simple = guid(0xd6dd68d1, 0x86fd, 0x4332, .{ 0x86, 0x66, 0x9a, 0xbe, 0xde, 0xa2, 0xd2, 0x4c });
const iid_fragment = guid(0xf7063da8, 0x8359, 0x439c, .{ 0x92, 0x97, 0xbb, 0xc5, 0x29, 0x9a, 0x7d, 0x87 });
const iid_fragment_root = guid(0x620ce2a5, 0xab8f, 0x40a9, .{ 0x86, 0xcb, 0xde, 0x3c, 0x75, 0x59, 0x9b, 0x58 });
const iid_invoke = guid(0x54fcb24b, 0xe18e, 0x47a2, .{ 0xb4, 0xd3, 0xec, 0xcb, 0xe7, 0x75, 0x99, 0xa2 });
const iid_value = guid(0xc7935180, 0x6fb3, 0x4201, .{ 0xb1, 0x74, 0x7d, 0xf7, 0x3a, 0xdb, 0xf6, 0x4a });
const iid_range = guid(0x36dc7aef, 0x33e6, 0x4691, .{ 0xaf, 0xe1, 0x2b, 0xe7, 0x27, 0x4b, 0x3d, 0x33 });
const iid_toggle = guid(0x56d00bd0, 0xc4f4, 0x433c, .{ 0xa8, 0x36, 0x1a, 0x52, 0xa5, 0x7e, 0x08, 0x92 });
const iid_selection_item = guid(0x2acad808, 0xb2d4, 0x452d, .{ 0xa4, 0x07, 0x91, 0xff, 0x1a, 0xd1, 0x67, 0xb2 });
const iid_selection = guid(0xfb8b03af, 0x3bdf, 0x48d4, .{ 0xbd, 0x36, 0x1a, 0x65, 0x79, 0x3b, 0xe1, 0x68 });

const S_OK: c.HRESULT = 0;
const E_NOINTERFACE: c.HRESULT = @bitCast(@as(u32, 0x80004002));
const E_INVALIDARG: c.HRESULT = @bitCast(@as(u32, 0x80070057));
const E_OUTOFMEMORY: c.HRESULT = @bitCast(@as(u32, 0x8007000E));
const UIA_E_ELEMENTNOTAVAILABLE: c.HRESULT = @bitCast(@as(u32, 0x80040201));
const UIA_E_INVALIDOPERATION: c.HRESULT = @bitCast(@as(u32, 0x80131509));

const VT_EMPTY = 0;
const VT_I4 = 3;
const VT_BSTR = 8;
const VT_BOOL = 11;
const VT_UNKNOWN = 13;

fn eqlGuid(a: *const c.GUID, b: *const c.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

/// A BSTR with `s`'s text (UTF-8 to UTF-16); null if out of memory.
fn bstr(s: []const u8) c.BSTR {
    var buf: [512]u16 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(&buf));
    const wide = std.unicode.utf8ToUtf16LeAlloc(fba.allocator(), s) catch
        std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, s) catch return null;
    defer if (wide.ptr != &buf) std.heap.page_allocator.free(wide);
    return c.SysAllocStringLen(wide.ptr, @intCast(wide.len));
}

fn setBstr(v: [*c]c.VARIANT, s: []const u8) void {
    v.*.unnamed_0.unnamed_0.vt = VT_BSTR;
    v.*.unnamed_0.unnamed_0.unnamed_0.bstrVal = bstr(s);
}

fn setI4(v: [*c]c.VARIANT, i: i32) void {
    v.*.unnamed_0.unnamed_0.vt = VT_I4;
    v.*.unnamed_0.unnamed_0.unnamed_0.lVal = i;
}

fn setBool(v: [*c]c.VARIANT, b: bool) void {
    v.*.unnamed_0.unnamed_0.vt = VT_BOOL;
    v.*.unnamed_0.unnamed_0.unnamed_0.boolVal = if (b) -1 else 0;
}

/// UI Automation's control type for a role.
fn controlType(role: core.AccessibleRole) i32 {
    return switch (role) {
        .button => c.UIA_ButtonControlTypeId,
        .checkbox, .switch_ => c.UIA_CheckBoxControlTypeId,
        .radio_button => c.UIA_RadioButtonControlTypeId,
        .combobox => c.UIA_ComboBoxControlTypeId,
        .list => c.UIA_ListControlTypeId,
        .list_item => c.UIA_ListItemControlTypeId,
        .slider => c.UIA_SliderControlTypeId,
        .spinbox => c.UIA_SpinnerControlTypeId,
        .tab => c.UIA_TabItemControlTypeId,
        .tab_list => c.UIA_TabControlTypeId,
        .table => c.UIA_TableControlTypeId,
        .table_row => c.UIA_DataItemControlTypeId,
        .table_cell => c.UIA_TextControlTypeId,
        .column_header => c.UIA_HeaderItemControlTypeId,
        .text => c.UIA_TextControlTypeId,
        .text_input => c.UIA_EditControlTypeId,
        .progress_indicator => c.UIA_ProgressBarControlTypeId,
        .image => c.UIA_ImageControlTypeId,
        .group, .tab_panel, .unset, .none => c.UIA_GroupControlTypeId,
    };
}

const Pattern = enum { invoke, toggle, range, value, selection_item, selection };

fn isSelectionItem(role: core.AccessibleRole) bool {
    return role == .list_item or role == .table_row;
}

fn patternsOf(role: core.AccessibleRole) []const Pattern {
    return switch (role) {
        .list_item, .table_row => &.{ .invoke, .selection_item },
        .list, .table => &.{.selection},
        .button, .tab, .radio_button, .column_header => &.{.invoke},
        .checkbox, .switch_ => &.{.toggle},
        .slider, .spinbox, .progress_indicator => &.{.range},
        .text_input, .combobox => &.{.value},
        else => &.{},
    };
}

// ---- The bridge ----

pub const Bridge = struct {
    gpa: Allocator,
    ui: *core.Window,
    hwnd: c.HWND,
    tracker: a11y.Tracker,
    /// The latest snapshot, and where each item is in it.
    nodes: []const a11y.Node = &.{},
    index: std.AutoHashMapUnmanaged(*core.Item, u32) = .empty,
    /// The provider of each accessible item (the bridge holds a reference).
    elements: std.AutoHashMapUnmanaged(*core.Item, *Element) = .empty,
    /// The window's: the fragment root.
    root: *Element,
    old_proc: c.LONG_PTR = 0,
    focused: ?*core.Item = null,
    updated: bool = false,
    next_id: i32 = 1,
    /// Physical pixels per logical pixel (screen coordinates are physical).
    scale: f32 = 1,

    /// Shows `ui`'s accessible items in window `hwnd`. Call `update` from
    /// the event loop. Both must outlive the bridge.
    pub fn create(gpa: Allocator, ui: *core.Window, hwnd: c.HWND) Allocator.Error!*Bridge {
        // Providers live in the window thread's apartment (single-threaded:
        // UI Automation's calls are brought to this thread). If the thread
        // already joined one, that one.
        _ = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
        const self = try gpa.create(Bridge);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .ui = ui, .hwnd = hwnd, .tracker = .init(gpa, ui), .root = undefined };
        self.root = try Element.create(gpa, self, null, 0);
        try bridges.append(gpa, self);
        // UI Automation asks the window for its root provider.
        self.old_proc = c.SetWindowLongPtrW(hwnd, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&windowProc)));
        return self;
    }

    pub fn destroy(self: *Bridge) void {
        if (self.old_proc != 0) _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_WNDPROC, self.old_proc);
        // Clients holding providers are told they are gone.
        _ = c.UiaReturnRawElementProvider(self.hwnd, 0, 0, null);
        _ = c.UiaDisconnectProvider(&self.root.simple);
        for (bridges.items, 0..) |b, i| if (b == self) {
            _ = bridges.swapRemove(i);
            break;
        };
        if (bridges.items.len == 0) {
            bridges.deinit(self.gpa);
            bridges = .empty;
        }
        var it = self.elements.valueIterator();
        while (it.next()) |e| {
            e.*.bridge = null;
            _ = Element.release(e.*);
        }
        self.root.bridge = null;
        _ = Element.release(self.root);
        self.elements.deinit(self.gpa);
        self.index.deinit(self.gpa);
        self.tracker.deinit();
        self.gpa.destroy(self);
    }

    /// Takes a new snapshot if anything changed, and tells listening
    /// clients what did.
    pub fn update(self: *Bridge) Allocator.Error!void {
        if (!self.tracker.isDirty() and self.updated) return;
        self.updated = true;
        var old_values: std.AutoHashMapUnmanaged(*core.Item, u64) = .empty;
        defer old_values.deinit(self.gpa);
        for (self.nodes) |n| try old_values.put(self.gpa, n.item, std.hash.Wyhash.hash(0, n.value));
        var old_selected: std.AutoHashMapUnmanaged(*core.Item, bool) = .empty;
        defer old_selected.deinit(self.gpa);
        for (self.nodes) |n| if (isSelectionItem(n.role)) try old_selected.put(self.gpa, n.item, n.checked);
        const old_count = self.nodes.len;

        self.nodes = try self.tracker.update();
        self.index.clearRetainingCapacity();
        for (self.nodes, 0..) |n, i| try self.index.put(self.gpa, n.item, @intCast(i));

        // Providers of items that are gone, and new ones.
        var stale: std.ArrayList(*core.Item) = .empty;
        defer stale.deinit(self.gpa);
        var it = self.elements.iterator();
        while (it.next()) |e| if (!self.index.contains(e.key_ptr.*)) try stale.append(self.gpa, e.key_ptr.*);
        for (stale.items) |item| {
            const e = self.elements.fetchRemove(item).?.value;
            e.bridge = null;
            _ = c.UiaDisconnectProvider(&e.simple);
            _ = Element.release(e);
        }
        var added = false;
        for (self.nodes) |n| {
            const gop = try self.elements.getOrPut(self.gpa, n.item);
            if (!gop.found_existing) {
                gop.value_ptr.* = Element.create(self.gpa, self, n.item, self.next_id) catch |err| {
                    _ = self.elements.remove(n.item);
                    return err;
                };
                self.next_id += 1;
                added = true;
            }
        }

        if (c.UiaClientsAreListening() == 0) {
            self.focused = self.focusedItem();
            return;
        }
        if (added or stale.items.len > 0 or old_count != self.nodes.len) {
            _ = c.UiaRaiseStructureChangedEvent(&self.root.simple, c.StructureChangeType_ChildrenInvalidated, null, 0);
        }
        for (self.nodes) |n| {
            const before = old_values.get(n.item) orelse continue;
            if (before == std.hash.Wyhash.hash(0, n.value)) continue;
            var old: c.VARIANT = std.mem.zeroes(c.VARIANT);
            var new: c.VARIANT = std.mem.zeroes(c.VARIANT);
            setBstr(&new, n.value);
            _ = c.UiaRaiseAutomationPropertyChangedEvent(&self.elements.get(n.item).?.simple, c.UIA_ValueValuePropertyId, old, new);
            _ = c.VariantClear(&new);
            _ = &old;
        }
        // Items selected or no longer.
        for (self.nodes, 0..) |n, i| {
            const before = old_selected.get(n.item) orelse continue;
            if (before == n.checked) continue;
            const e = &self.elements.get(n.item).?.simple;
            var old: c.VARIANT = std.mem.zeroes(c.VARIANT);
            var new: c.VARIANT = std.mem.zeroes(c.VARIANT);
            setBool(&old, before);
            setBool(&new, n.checked);
            _ = c.UiaRaiseAutomationPropertyChangedEvent(e, c.UIA_SelectionItemIsSelectedPropertyId, old, new);
            const multiple = if (self.containerOf(@intCast(i))) |k| self.nodes[k].multiselectable else false;
            const event = if (!multiple) (if (n.checked) c.UIA_SelectionItem_ElementSelectedEventId else continue) else if (n.checked) c.UIA_SelectionItem_ElementAddedToSelectionEventId else c.UIA_SelectionItem_ElementRemovedFromSelectionEventId;
            _ = c.UiaRaiseAutomationEvent(e, event);
        }
        const focused = self.focusedItem();
        if (focused != self.focused) {
            self.focused = focused;
            if (focused) |f| _ = c.UiaRaiseAutomationEvent(&self.elements.get(f).?.simple, c.UIA_AutomationFocusChangedEventId);
        }
    }

    fn focusedItem(self: *const Bridge) ?*core.Item {
        for (self.nodes) |n| if (n.focused) return n.item;
        return null;
    }

    fn node(self: *const Bridge, item: *core.Item) ?a11y.Node {
        const i = self.index.get(item) orelse return null;
        return self.nodes[i];
    }

    /// The list or table node `i` (an item of it) is in.
    fn containerOf(self: *const Bridge, i: u32) ?u32 {
        var p = self.nodes[i].parent;
        while (p) |k| : (p = self.nodes[k].parent) {
            if (self.nodes[k].role == .list or self.nodes[k].role == .table) return k;
        }
        return null;
    }

    fn elementAt(self: *const Bridge, i: usize) *Element {
        return self.elements.get(self.nodes[i].item).?;
    }

    /// The `which`'th (first or last) child of `parent` (null: the
    /// window).
    fn child(self: *const Bridge, parent: ?*core.Item, last: bool) ?*Element {
        const p: ?u32 = if (parent) |item| self.index.get(item) orelse return null else null;
        var found: ?usize = null;
        for (self.nodes, 0..) |n, i| if (n.parent == p) {
            found = i;
            if (!last) break;
        };
        return if (found) |i| self.elementAt(i) else null;
    }

    fn sibling(self: *const Bridge, item: *core.Item, next: bool) ?*Element {
        const i = self.index.get(item) orelse return null;
        const p = self.nodes[i].parent;
        if (next) {
            var j = i + 1;
            while (j < self.nodes.len) : (j += 1) if (self.nodes[j].parent == p) return self.elementAt(j);
        } else {
            var j = i;
            while (j > 0) {
                j -= 1;
                if (self.nodes[j].parent == p) return self.elementAt(j);
            }
        }
        return null;
    }

    /// Screen rectangle (physical pixels) of a window rectangle.
    fn screenRect(self: *const Bridge, r: core.Rect) c.UiaRect {
        var origin: c.POINT = .{ .x = 0, .y = 0 };
        _ = c.ClientToScreen(self.hwnd, &origin);
        const s: f64 = self.scale;
        return .{ .left = @as(f64, @floatFromInt(origin.x)) + r.x * s, .top = @as(f64, @floatFromInt(origin.y)) + r.y * s, .width = r.width * s, .height = r.height * s };
    }

    /// The innermost item at screen point (x, y).
    fn itemAt(self: *const Bridge, x: f64, y: f64) ?*Element {
        var origin: c.POINT = .{ .x = 0, .y = 0 };
        _ = c.ClientToScreen(self.hwnd, &origin);
        const px: f32 = @floatCast((x - @as(f64, @floatFromInt(origin.x))) / self.scale);
        const py: f32 = @floatCast((y - @as(f64, @floatFromInt(origin.y))) / self.scale);
        var found: ?usize = null;
        for (self.nodes, 0..) |n, i| {
            const r = n.bounds;
            if (px >= r.x and py >= r.y and px < r.x + r.width and py < r.y + r.height) found = i;
        }
        return if (found) |i| self.elementAt(i) else null;
    }
};

/// The windows with a bridge (their window procedure finds it here).
var bridges: std.ArrayList(*Bridge) = .empty;

fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    const self = for (bridges.items) |b| {
        if (b.hwnd == hwnd) break b;
    } else return c.DefWindowProcW(hwnd, message, wparam, lparam);
    if (message == c.WM_GETOBJECT and @as(i32, @truncate(lparam)) == c.UiaRootObjectId) {
        return c.UiaReturnRawElementProvider(hwnd, wparam, lparam, &self.root.simple);
    }
    const old: c.WNDPROC = @ptrFromInt(@as(usize, @bitCast(self.old_proc)));
    return c.CallWindowProcW(old, hwnd, message, wparam, lparam);
}

// ---- Providers ----

/// A provider: one COM object with an interface pointer per interface it
/// implements (each a pointer to its vtable).
const Element = struct {
    simple: c.IRawElementProviderSimple = .{ .lpVtbl = @constCast(&simple_vtbl) },
    fragment: c.IRawElementProviderFragment = .{ .lpVtbl = @constCast(&fragment_vtbl) },
    root: c.IRawElementProviderFragmentRoot = .{ .lpVtbl = @constCast(&root_vtbl) },
    invoke: c.IInvokeProvider = .{ .lpVtbl = @constCast(&invoke_vtbl) },
    toggle: c.IToggleProvider = .{ .lpVtbl = @constCast(&toggle_vtbl) },
    range: c.IRangeValueProvider = .{ .lpVtbl = @constCast(&range_vtbl) },
    value: c.IValueProvider = .{ .lpVtbl = @constCast(&value_vtbl) },
    selection_item: c.ISelectionItemProvider = .{ .lpVtbl = @constCast(&selection_item_vtbl) },
    selection: c.ISelectionProvider = .{ .lpVtbl = @constCast(&selection_vtbl) },
    refs: u32 = 1,
    gpa: Allocator,
    /// Null once the bridge is gone (or the item is no longer accessible).
    bridge: ?*Bridge,
    /// Null for the window's root provider.
    item: ?*core.Item,
    id: i32,

    fn create(gpa: Allocator, bridge: *Bridge, item: ?*core.Item, id: i32) Allocator.Error!*Element {
        const e = try gpa.create(Element);
        e.* = .{ .gpa = gpa, .bridge = bridge, .item = item, .id = id };
        return e;
    }

    fn addRef(e: *Element) u32 {
        e.refs += 1;
        return e.refs;
    }

    fn release(e: *Element) u32 {
        e.refs -= 1;
        const left = e.refs;
        if (left == 0) e.gpa.destroy(e);
        return left;
    }

    /// The live node behind the provider, or null if gone.
    fn live(e: *Element) ?struct { *Bridge, a11y.Node } {
        const b = e.bridge orelse return null;
        const item = e.item orelse return null;
        return .{ b, b.node(item) orelse return null };
    }

    fn hasPattern(e: *Element, p: Pattern) bool {
        _, const n = e.live() orelse return false;
        return std.mem.indexOfScalar(Pattern, patternsOf(n.role), p) != null;
    }

    fn queryInterface(e: *Element, riid: [*c]const c.IID, out: [*c]?*anyopaque) c.HRESULT {
        if (out == null) return E_INVALIDARG;
        const p: ?*anyopaque = if (eqlGuid(riid, &iid_unknown) or eqlGuid(riid, &iid_simple))
            &e.simple
        else if (eqlGuid(riid, &iid_fragment))
            &e.fragment
        else if (eqlGuid(riid, &iid_fragment_root) and e.item == null)
            &e.root
        else if (eqlGuid(riid, &iid_invoke) and e.hasPattern(.invoke))
            &e.invoke
        else if (eqlGuid(riid, &iid_toggle) and e.hasPattern(.toggle))
            &e.toggle
        else if (eqlGuid(riid, &iid_range) and e.hasPattern(.range))
            &e.range
        else if (eqlGuid(riid, &iid_value) and e.hasPattern(.value))
            &e.value
        else if (eqlGuid(riid, &iid_selection_item) and e.hasPattern(.selection_item))
            &e.selection_item
        else if (eqlGuid(riid, &iid_selection) and e.hasPattern(.selection))
            &e.selection
        else
            null;
        out.* = p;
        if (p == null) return E_NOINTERFACE;
        _ = e.addRef();
        return S_OK;
    }

    /// The Element behind an interface pointer of the field `field`.
    fn of(comptime field: []const u8, p: anytype) *Element {
        return @fieldParentPtr(field, @as(*@FieldType(Element, field), @ptrCast(p)));
    }

    fn Unknown(comptime field: []const u8, comptime T: type) type {
        return struct {
            fn qi(this: [*c]T, riid: [*c]const c.IID, out: [*c]?*anyopaque) callconv(.c) c.HRESULT {
                return of(field, this).queryInterface(riid, out);
            }
            fn add(this: [*c]T) callconv(.c) c.ULONG {
                return of(field, this).addRef();
            }
            fn rel(this: [*c]T) callconv(.c) c.ULONG {
                return of(field, this).release();
            }
        };
    }

    // IRawElementProviderSimple

    const SimpleU = Unknown("simple", c.IRawElementProviderSimple);
    const simple_vtbl: c.IRawElementProviderSimpleVtbl = .{
        .QueryInterface = SimpleU.qi,
        .AddRef = SimpleU.add,
        .Release = SimpleU.rel,
        .get_ProviderOptions = providerOptions,
        .GetPatternProvider = patternProvider,
        .GetPropertyValue = propertyValue,
        .get_HostRawElementProvider = hostProvider,
    };

    fn providerOptions(_: [*c]c.IRawElementProviderSimple, out: [*c]c.enum_ProviderOptions) callconv(.c) c.HRESULT {
        // Calls come in on the window's thread (its COM apartment).
        out.* = c.ProviderOptions_ServerSideProvider | c.ProviderOptions_UseComThreading;
        return S_OK;
    }

    fn patternProvider(this: [*c]c.IRawElementProviderSimple, pattern: c.PATTERNID, out: [*c][*c]c.IUnknown) callconv(.c) c.HRESULT {
        const e = of("simple", this);
        out.* = null;
        const p: ?Pattern = switch (pattern) {
            c.UIA_InvokePatternId => .invoke,
            c.UIA_TogglePatternId => .toggle,
            c.UIA_RangeValuePatternId => .range,
            c.UIA_ValuePatternId => .value,
            c.UIA_SelectionItemPatternId => .selection_item,
            c.UIA_SelectionPatternId => .selection,
            else => null,
        };
        const which = p orelse return S_OK;
        if (!e.hasPattern(which)) return S_OK;
        const iface: *anyopaque = switch (which) {
            .invoke => &e.invoke,
            .toggle => &e.toggle,
            .range => &e.range,
            .value => &e.value,
            .selection_item => &e.selection_item,
            .selection => &e.selection,
        };
        _ = e.addRef();
        out.* = @ptrCast(@alignCast(iface));
        return S_OK;
    }

    fn propertyValue(this: [*c]c.IRawElementProviderSimple, property: c.PROPERTYID, out: [*c]c.VARIANT) callconv(.c) c.HRESULT {
        const e = of("simple", this);
        out.* = std.mem.zeroes(c.VARIANT);
        // The window itself: what the window's host provider says.
        if (e.item == null) {
            if (property == c.UIA_FrameworkIdPropertyId) setBstr(out, "zigulee");
            return S_OK;
        }
        _, const n = e.live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        switch (property) {
            c.UIA_ControlTypePropertyId => setI4(out, controlType(n.role)),
            c.UIA_NamePropertyId => setBstr(out, n.label),
            c.UIA_HelpTextPropertyId => if (n.description.len > 0) setBstr(out, n.description),
            c.UIA_IsEnabledPropertyId => setBool(out, n.enabled),
            c.UIA_HasKeyboardFocusPropertyId => setBool(out, n.focused),
            c.UIA_IsKeyboardFocusablePropertyId => setBool(out, n.enabled and patternsOf(n.role).len > 0),
            c.UIA_IsControlElementPropertyId, c.UIA_IsContentElementPropertyId => setBool(out, true),
            c.UIA_FrameworkIdPropertyId => setBstr(out, "zigulee"),
            c.UIA_AutomationIdPropertyId => {
                var buf: [24]u8 = undefined;
                setBstr(out, std.fmt.bufPrint(&buf, "zigulee-{d}", .{e.id}) catch "");
            },
            else => {},
        }
        return S_OK;
    }

    fn hostProvider(this: [*c]c.IRawElementProviderSimple, out: [*c][*c]c.IRawElementProviderSimple) callconv(.c) c.HRESULT {
        const e = of("simple", this);
        out.* = null;
        // The window's root: the window's own properties come from the
        // window (title, position, the system's window patterns).
        if (e.item == null) if (e.bridge) |b| return c.UiaHostProviderFromHwnd(b.hwnd, out);
        return S_OK;
    }

    // IRawElementProviderFragment

    const FragmentU = Unknown("fragment", c.IRawElementProviderFragment);
    const fragment_vtbl: c.IRawElementProviderFragmentVtbl = .{
        .QueryInterface = FragmentU.qi,
        .AddRef = FragmentU.add,
        .Release = FragmentU.rel,
        .Navigate = navigate,
        .GetRuntimeId = runtimeId,
        .get_BoundingRectangle = boundingRectangle,
        .GetEmbeddedFragmentRoots = embeddedRoots,
        .SetFocus = setFocus,
        .get_FragmentRoot = fragmentRoot,
    };

    fn returnFragment(target: ?*Element, out: [*c][*c]c.IRawElementProviderFragment) c.HRESULT {
        if (target) |t| {
            _ = t.addRef();
            out.* = &t.fragment;
        } else out.* = null;
        return S_OK;
    }

    fn navigate(this: [*c]c.IRawElementProviderFragment, direction: c.enum_NavigateDirection, out: [*c][*c]c.IRawElementProviderFragment) callconv(.c) c.HRESULT {
        const e = of("fragment", this);
        out.* = null;
        const b = e.bridge orelse return UIA_E_ELEMENTNOTAVAILABLE;
        if (e.item == null) {
            // The window: its children (its parent and siblings are the
            // host's).
            return switch (direction) {
                c.NavigateDirection_FirstChild => returnFragment(b.child(null, false), out),
                c.NavigateDirection_LastChild => returnFragment(b.child(null, true), out),
                else => S_OK,
            };
        }
        const item = e.item.?;
        const n = b.node(item) orelse return UIA_E_ELEMENTNOTAVAILABLE;
        return switch (direction) {
            c.NavigateDirection_Parent => returnFragment(if (n.parent) |p| b.elementAt(p) else b.root, out),
            c.NavigateDirection_NextSibling => returnFragment(b.sibling(item, true), out),
            c.NavigateDirection_PreviousSibling => returnFragment(b.sibling(item, false), out),
            c.NavigateDirection_FirstChild => returnFragment(b.child(item, false), out),
            c.NavigateDirection_LastChild => returnFragment(b.child(item, true), out),
            else => S_OK,
        };
    }

    fn runtimeId(this: [*c]c.IRawElementProviderFragment, out: [*c][*c]c.SAFEARRAY) callconv(.c) c.HRESULT {
        const e = of("fragment", this);
        out.* = null;
        // The window's comes from its host.
        if (e.item == null) return S_OK;
        const ids = [2]c.LONG{ c.UiaAppendRuntimeId, e.id };
        const array = c.SafeArrayCreateVector(VT_I4, 0, ids.len) orelse return E_OUTOFMEMORY;
        for (ids, 0..) |v, i| {
            var index: c.LONG = @intCast(i);
            var value = v;
            _ = c.SafeArrayPutElement(array, &index, &value);
        }
        out.* = array;
        return S_OK;
    }

    fn boundingRectangle(this: [*c]c.IRawElementProviderFragment, out: [*c]c.UiaRect) callconv(.c) c.HRESULT {
        const e = of("fragment", this);
        out.* = std.mem.zeroes(c.UiaRect);
        if (e.item == null) return S_OK; // the host's
        const b, const n = e.live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        out.* = b.screenRect(n.bounds);
        return S_OK;
    }

    fn embeddedRoots(_: [*c]c.IRawElementProviderFragment, out: [*c][*c]c.SAFEARRAY) callconv(.c) c.HRESULT {
        out.* = null;
        return S_OK;
    }

    fn setFocus(this: [*c]c.IRawElementProviderFragment) callconv(.c) c.HRESULT {
        const e = of("fragment", this);
        const b, const n = e.live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        _ = a11y.perform(b.ui, n.item, .focus);
        return S_OK;
    }

    fn fragmentRoot(this: [*c]c.IRawElementProviderFragment, out: [*c][*c]c.IRawElementProviderFragmentRoot) callconv(.c) c.HRESULT {
        const e = of("fragment", this);
        const b = e.bridge orelse {
            out.* = null;
            return UIA_E_ELEMENTNOTAVAILABLE;
        };
        _ = b.root.addRef();
        out.* = &b.root.root;
        return S_OK;
    }

    // IRawElementProviderFragmentRoot (the window's)

    const RootU = Unknown("root", c.IRawElementProviderFragmentRoot);
    const root_vtbl: c.IRawElementProviderFragmentRootVtbl = .{
        .QueryInterface = RootU.qi,
        .AddRef = RootU.add,
        .Release = RootU.rel,
        .ElementProviderFromPoint = fromPoint,
        .GetFocus = getFocus,
    };

    fn fromPoint(this: [*c]c.IRawElementProviderFragmentRoot, x: f64, y: f64, out: [*c][*c]c.IRawElementProviderFragment) callconv(.c) c.HRESULT {
        const e = of("root", this);
        const b = e.bridge orelse return UIA_E_ELEMENTNOTAVAILABLE;
        return returnFragment(b.itemAt(x, y), out);
    }

    fn getFocus(this: [*c]c.IRawElementProviderFragmentRoot, out: [*c][*c]c.IRawElementProviderFragment) callconv(.c) c.HRESULT {
        const e = of("root", this);
        const b = e.bridge orelse return UIA_E_ELEMENTNOTAVAILABLE;
        const f = b.focusedItem() orelse return returnFragment(null, out);
        return returnFragment(b.elements.get(f), out);
    }

    // Patterns

    fn act(e: *Element, action: a11y.Action) c.HRESULT {
        const b, const n = e.live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        _ = a11y.perform(b.ui, n.item, action);
        return S_OK;
    }

    // An item of a list or table: selected, selects.

    const SelectionItemU = Unknown("selection_item", c.ISelectionItemProvider);
    const selection_item_vtbl: c.ISelectionItemProviderVtbl = .{
        .QueryInterface = SelectionItemU.qi,
        .AddRef = SelectionItemU.add,
        .Release = SelectionItemU.rel,
        .Select = selectIt,
        .AddToSelection = addToSelection,
        .RemoveFromSelection = removeFromSelection,
        .get_IsSelected = isSelected,
        .get_SelectionContainer = selectionContainer,
    };

    fn selectIt(this: [*c]c.ISelectionItemProvider) callconv(.c) c.HRESULT {
        return of("selection_item", this).act(.select);
    }

    fn addToSelection(this: [*c]c.ISelectionItemProvider) callconv(.c) c.HRESULT {
        const b, const n = of("selection_item", this).live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        if (n.checked) return S_OK;
        if (!a11y.setSelected(n.item, true)) _ = a11y.perform(b.ui, n.item, .select);
        return S_OK;
    }

    fn removeFromSelection(this: [*c]c.ISelectionItemProvider) callconv(.c) c.HRESULT {
        _, const n = of("selection_item", this).live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        if (!n.checked) return S_OK;
        return if (a11y.setSelected(n.item, false)) S_OK else UIA_E_INVALIDOPERATION;
    }

    fn isSelected(this: [*c]c.ISelectionItemProvider, out: [*c]c.BOOL) callconv(.c) c.HRESULT {
        _, const n = of("selection_item", this).live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        out.* = @intFromBool(n.checked);
        return S_OK;
    }

    fn selectionContainer(this: [*c]c.ISelectionItemProvider, out: [*c][*c]c.IRawElementProviderSimple) callconv(.c) c.HRESULT {
        const e = of("selection_item", this);
        out.* = null;
        const b, const n = e.live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        const k = b.containerOf(b.index.get(n.item).?) orelse return S_OK;
        const container = b.elementAt(k);
        _ = container.addRef();
        out.* = &container.simple;
        return S_OK;
    }

    // A list or table: its items selected (those shown).

    const SelectionU = Unknown("selection", c.ISelectionProvider);
    const selection_vtbl: c.ISelectionProviderVtbl = .{
        .QueryInterface = SelectionU.qi,
        .AddRef = SelectionU.add,
        .Release = SelectionU.rel,
        .GetSelection = getSelection,
        .get_CanSelectMultiple = canSelectMultiple,
        .get_IsSelectionRequired = isSelectionRequired,
    };

    fn getSelection(this: [*c]c.ISelectionProvider, out: [*c][*c]c.SAFEARRAY) callconv(.c) c.HRESULT {
        out.* = null;
        const b, const n = of("selection", this).live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        const self_index = b.index.get(n.item).?;
        var count: c.ULONG = 0;
        for (b.nodes, 0..) |item, i| {
            if (isSelectionItem(item.role) and item.checked and b.containerOf(@intCast(i)) == self_index) count += 1;
        }
        const array = c.SafeArrayCreateVector(VT_UNKNOWN, 0, count) orelse return E_OUTOFMEMORY;
        var k: c.LONG = 0;
        for (b.nodes, 0..) |item, i| {
            if (!(isSelectionItem(item.role) and item.checked and b.containerOf(@intCast(i)) == self_index)) continue;
            // The array holds a reference of its own.
            _ = c.SafeArrayPutElement(array, &k, &b.elementAt(i).simple);
            k += 1;
        }
        out.* = array;
        return S_OK;
    }

    fn canSelectMultiple(this: [*c]c.ISelectionProvider, out: [*c]c.BOOL) callconv(.c) c.HRESULT {
        _, const n = of("selection", this).live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        out.* = @intFromBool(n.multiselectable);
        return S_OK;
    }

    fn isSelectionRequired(this: [*c]c.ISelectionProvider, out: [*c]c.BOOL) callconv(.c) c.HRESULT {
        _ = of("selection", this).live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        out.* = 0;
        return S_OK;
    }

    const InvokeU = Unknown("invoke", c.IInvokeProvider);
    const invoke_vtbl: c.IInvokeProviderVtbl = .{ .QueryInterface = InvokeU.qi, .AddRef = InvokeU.add, .Release = InvokeU.rel, .Invoke = invokeIt };

    fn invokeIt(this: [*c]c.IInvokeProvider) callconv(.c) c.HRESULT {
        return of("invoke", this).act(.default);
    }

    const ToggleU = Unknown("toggle", c.IToggleProvider);
    const toggle_vtbl: c.IToggleProviderVtbl = .{ .QueryInterface = ToggleU.qi, .AddRef = ToggleU.add, .Release = ToggleU.rel, .Toggle = toggleIt, .get_ToggleState = toggleState };

    fn toggleIt(this: [*c]c.IToggleProvider) callconv(.c) c.HRESULT {
        return of("toggle", this).act(.default);
    }

    fn toggleState(this: [*c]c.IToggleProvider, out: [*c]c.enum_ToggleState) callconv(.c) c.HRESULT {
        _, const n = of("toggle", this).live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        out.* = if (n.checked) c.ToggleState_On else c.ToggleState_Off;
        return S_OK;
    }

    const RangeU = Unknown("range", c.IRangeValueProvider);
    const range_vtbl: c.IRangeValueProviderVtbl = .{
        .QueryInterface = RangeU.qi,
        .AddRef = RangeU.add,
        .Release = RangeU.rel,
        .SetValue = rangeSet,
        .get_Value = rangeValue,
        .get_IsReadOnly = rangeReadOnly,
        .get_Maximum = rangeMaximum,
        .get_Minimum = rangeMinimum,
        .get_LargeChange = rangeStep,
        .get_SmallChange = rangeStep,
    };

    fn rangeSet(this: [*c]c.IRangeValueProvider, v: f64) callconv(.c) c.HRESULT {
        const e = of("range", this);
        _, const n = e.live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        var buf: [32]u8 = undefined;
        _ = a11y.setValue(n.item, std.fmt.bufPrint(&buf, "{d}", .{v}) catch return E_INVALIDARG);
        return S_OK;
    }

    fn rangeValue(this: [*c]c.IRangeValueProvider, out: [*c]f64) callconv(.c) c.HRESULT {
        _, const n = of("range", this).live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        out.* = std.fmt.parseFloat(f64, n.value) catch 0;
        return S_OK;
    }

    fn rangeReadOnly(this: [*c]c.IRangeValueProvider, out: [*c]c.WINBOOL) callconv(.c) c.HRESULT {
        _, const n = of("range", this).live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        out.* = @intFromBool(n.role == .progress_indicator or !n.enabled);
        return S_OK;
    }

    fn rangeMaximum(this: [*c]c.IRangeValueProvider, out: [*c]f64) callconv(.c) c.HRESULT {
        _, const n = of("range", this).live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        out.* = n.value_maximum;
        return S_OK;
    }

    fn rangeMinimum(this: [*c]c.IRangeValueProvider, out: [*c]f64) callconv(.c) c.HRESULT {
        _, const n = of("range", this).live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        out.* = n.value_minimum;
        return S_OK;
    }

    fn rangeStep(this: [*c]c.IRangeValueProvider, out: [*c]f64) callconv(.c) c.HRESULT {
        _, const n = of("range", this).live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        out.* = if (n.value_step > 0) n.value_step else 1;
        return S_OK;
    }

    const ValueU = Unknown("value", c.IValueProvider);
    const value_vtbl: c.IValueProviderVtbl = .{ .QueryInterface = ValueU.qi, .AddRef = ValueU.add, .Release = ValueU.rel, .SetValue = valueSet, .get_Value = valueValue, .get_IsReadOnly = valueReadOnly };

    fn valueSet(this: [*c]c.IValueProvider, text: c.LPCWSTR) callconv(.c) c.HRESULT {
        _, const n = of("value", this).live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        const wide = std.mem.span(text);
        var buf: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const utf8 = std.unicode.utf16LeToUtf8Alloc(fba.allocator(), wide) catch return E_INVALIDARG;
        _ = a11y.setValue(n.item, utf8);
        return S_OK;
    }

    fn valueValue(this: [*c]c.IValueProvider, out: [*c]c.BSTR) callconv(.c) c.HRESULT {
        _, const n = of("value", this).live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        out.* = bstr(n.value);
        return S_OK;
    }

    fn valueReadOnly(this: [*c]c.IValueProvider, out: [*c]c.WINBOOL) callconv(.c) c.HRESULT {
        _, const n = of("value", this).live() orelse return UIA_E_ELEMENTNOTAVAILABLE;
        out.* = @intFromBool(!n.enabled);
        return S_OK;
    }
};

// ---- Tests (Windows) ----

const testing = std.testing;

const clsid_cuiautomation = guid(0xff48dba4, 0x60ef, 0x4201, .{ 0xaa, 0x87, 0x54, 0x10, 0x3e, 0xef, 0x59, 0x4e });
const iid_automation = guid(0x30cbe57d, 0xd9d0, 0x452a, .{ 0xab, 0x13, 0x7a, 0xc5, 0xac, 0x48, 0x25, 0xee });
const iid_invoke_pattern = guid(0xfb377fbe, 0x8ea6, 0x46d5, .{ 0x9c, 0x73, 0x64, 0x99, 0x64, 0x2d, 0x30, 0x59 });

/// A window (hidden) with a button and a check box.
const TestWindow = struct {
    hwnd: c.HWND,
    ui: core.Window,
    button: core.items.Rectangle = .{},
    check: core.items.Rectangle = .{},
    button_props: core.AccessibleProperties = .{},
    check_props: core.AccessibleProperties = .{},
    pressed: u32 = 0,

    fn init(self: *TestWindow) !void {
        const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
        self.* = .{
            .hwnd = c.CreateWindowExW(0, class, class, c.WS_POPUP, 100, 100, 200, 100, null, null, null, null) orelse return error.SkipZigTest,
            .ui = undefined,
        };
        self.ui.init(testing.allocator, .{ .width = 200, .height = 100 });
        const root = self.ui.rootItem();
        root.appendChild(&self.button.item);
        root.appendChild(&self.check.item);
        self.button.item.setGeometry(.{ .x = 10, .y = 20, .width = 80, .height = 30 });
        self.check.item.setGeometry(.{ .x = 100, .y = 20, .width = 80, .height = 30 });
        self.button.item.accessible = &self.button_props;
        self.button_props.role.set(.button);
        self.button_props.label.set("OK");
        self.button_props.action_default.setHandler(&self.pressed, struct {
            fn f(n: *u32) void {
                n.* += 1;
            }
        }.f);
        self.check.item.accessible = &self.check_props;
        self.check_props.role.set(.checkbox);
        self.check_props.label.set("Remember");
        self.check_props.checkable.set(true);
        self.check_props.checked.set(true);
    }

    fn deinit(self: *TestWindow) void {
        self.button_props.deinit();
        self.check_props.deinit();
        self.button.deinit();
        self.check.deinit();
        self.ui.deinit();
        _ = c.DestroyWindow(self.hwnd);
    }
};

fn variantText(v: *c.VARIANT) ![]u8 {
    try testing.expectEqual(@as(c_ushort, VT_BSTR), v.unnamed_0.unnamed_0.vt);
    const s = v.unnamed_0.unnamed_0.unnamed_0.bstrVal;
    defer _ = c.VariantClear(v);
    return std.unicode.utf16LeToUtf8Alloc(testing.allocator, s[0..c.SysStringLen(s)]);
}

test "a window's items as UI Automation providers" {
    var w: TestWindow = undefined;
    try w.init();
    defer w.deinit();
    const bridge = try Bridge.create(testing.allocator, &w.ui, w.hwnd);
    defer bridge.destroy();
    try bridge.update();

    // The window's children: the button, then the check box.
    const root = &bridge.root.fragment;
    var first: [*c]c.IRawElementProviderFragment = null;
    try testing.expectEqual(S_OK, root.lpVtbl.*.Navigate.?(root, c.NavigateDirection_FirstChild, &first));
    defer _ = first.*.lpVtbl.*.Release.?(first);
    const button = Element.of("fragment", first);
    try testing.expectEqual(&w.button.item, button.item.?);

    var simple: ?*anyopaque = null;
    try testing.expectEqual(S_OK, first.*.lpVtbl.*.QueryInterface.?(first, &iid_simple, &simple));
    const s: [*c]c.IRawElementProviderSimple = @ptrCast(@alignCast(simple));
    defer _ = s.*.lpVtbl.*.Release.?(s);
    var v: c.VARIANT = undefined;
    try testing.expectEqual(S_OK, s.*.lpVtbl.*.GetPropertyValue.?(s, c.UIA_NamePropertyId, &v));
    const name = try variantText(&v);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("OK", name);
    try testing.expectEqual(S_OK, s.*.lpVtbl.*.GetPropertyValue.?(s, c.UIA_ControlTypePropertyId, &v));
    try testing.expectEqual(@as(c_long, c.UIA_ButtonControlTypeId), v.unnamed_0.unnamed_0.unnamed_0.lVal);

    // Parent and sibling.
    var parent: [*c]c.IRawElementProviderFragment = null;
    try testing.expectEqual(S_OK, first.*.lpVtbl.*.Navigate.?(first, c.NavigateDirection_Parent, &parent));
    defer _ = parent.*.lpVtbl.*.Release.?(parent);
    try testing.expectEqual(bridge.root, Element.of("fragment", parent));
    var next: [*c]c.IRawElementProviderFragment = null;
    try testing.expectEqual(S_OK, first.*.lpVtbl.*.Navigate.?(first, c.NavigateDirection_NextSibling, &next));
    defer _ = next.*.lpVtbl.*.Release.?(next);
    const check = Element.of("fragment", next);
    try testing.expectEqual(&w.check.item, check.item.?);

    // Bounds on screen: the client area's origin plus the item's.
    var origin: c.POINT = .{ .x = 0, .y = 0 };
    _ = c.ClientToScreen(w.hwnd, &origin);
    var rect: c.UiaRect = undefined;
    try testing.expectEqual(S_OK, first.*.lpVtbl.*.get_BoundingRectangle.?(first, &rect));
    try testing.expectEqual(@as(f64, @floatFromInt(origin.x + 10)), rect.left);
    try testing.expectEqual(@as(f64, 80), rect.width);

    // Patterns: the button invokes, the check box toggles.
    var unknown: [*c]c.IUnknown = null;
    try testing.expectEqual(S_OK, s.*.lpVtbl.*.GetPatternProvider.?(s, c.UIA_TogglePatternId, &unknown));
    try testing.expect(unknown == null);
    try testing.expectEqual(S_OK, s.*.lpVtbl.*.GetPatternProvider.?(s, c.UIA_InvokePatternId, &unknown));
    const invoke: [*c]c.IInvokeProvider = @ptrCast(@alignCast(unknown));
    try testing.expectEqual(S_OK, invoke.*.lpVtbl.*.Invoke.?(invoke));
    _ = invoke.*.lpVtbl.*.Release.?(invoke);
    try testing.expectEqual(@as(u32, 1), w.pressed);

    var toggle: ?*anyopaque = null;
    try testing.expectEqual(S_OK, next.*.lpVtbl.*.QueryInterface.?(next, &iid_toggle, &toggle));
    const t: [*c]c.IToggleProvider = @ptrCast(@alignCast(toggle));
    defer _ = t.*.lpVtbl.*.Release.?(t);
    var state: c.enum_ToggleState = undefined;
    try testing.expectEqual(S_OK, t.*.lpVtbl.*.get_ToggleState.?(t, &state));
    try testing.expectEqual(@as(c.enum_ToggleState, c.ToggleState_On), state);

    // A provider kept after its item is gone says so.
    w.check_props.role.set(.unset);
    try bridge.update();
    try testing.expectEqual(UIA_E_ELEMENTNOTAVAILABLE, t.*.lpVtbl.*.get_ToggleState.?(t, &state));
}

test "a UI Automation client finds and presses the button" {
    var w: TestWindow = undefined;
    try w.init();
    defer w.deinit();
    const bridge = try Bridge.create(testing.allocator, &w.ui, w.hwnd);
    defer bridge.destroy();
    try bridge.update();

    // The client runs on another thread; this one answers its calls (they
    // come here as window messages) until it is done.
    const Client = struct {
        hwnd: c.HWND,
        result: anyerror!void = error.Unfinished,
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.result = self.find();
            self.done.store(true, .release);
        }

        fn find(self: *@This()) !void {
            if (c.CoInitializeEx(null, c.COINIT_MULTITHREADED) < 0) return error.SkipZigTest;
            defer c.CoUninitialize();
            var automation: ?*c.IUIAutomation = null;
            if (c.CoCreateInstance(&clsid_cuiautomation, null, c.CLSCTX_INPROC_SERVER, &iid_automation, @ptrCast(&automation)) < 0) {
                log.info("UI Automation unavailable: skipping", .{});
                return error.SkipZigTest;
            }
            const uia = automation.?;
            defer _ = uia.lpVtbl.*.Release.?(uia);
            var window: ?*c.IUIAutomationElement = null;
            if (uia.lpVtbl.*.ElementFromHandle.?(uia, self.hwnd, &window) < 0) return error.ElementFromHandle;
            defer _ = window.?.lpVtbl.*.Release.?(window.?);

            var name: c.VARIANT = std.mem.zeroes(c.VARIANT);
            setBstr(&name, "OK");
            defer _ = c.VariantClear(&name);
            var condition: ?*c.IUIAutomationCondition = null;
            if (uia.lpVtbl.*.CreatePropertyCondition.?(uia, c.UIA_NamePropertyId, name, &condition) < 0) return error.CreatePropertyCondition;
            defer _ = condition.?.lpVtbl.*.Release.?(condition.?);
            var button: ?*c.IUIAutomationElement = null;
            if (window.?.lpVtbl.*.FindFirst.?(window.?, c.TreeScope_Descendants, condition, &button) < 0 or button == null) return error.ButtonNotFound;
            defer _ = button.?.lpVtbl.*.Release.?(button.?);

            var control_type: c.CONTROLTYPEID = 0;
            _ = button.?.lpVtbl.*.get_CurrentControlType.?(button.?, &control_type);
            if (control_type != c.UIA_ButtonControlTypeId) return error.WrongControlType;
            var pattern: ?*c.IUIAutomationInvokePattern = null;
            if (button.?.lpVtbl.*.GetCurrentPatternAs.?(button.?, c.UIA_InvokePatternId, &iid_invoke_pattern, @ptrCast(&pattern)) < 0 or pattern == null) return error.NoInvokePattern;
            defer _ = pattern.?.lpVtbl.*.Release.?(pattern.?);
            if (pattern.?.lpVtbl.*.Invoke.?(pattern.?) < 0) return error.InvokeFailed;
        }
    };
    var client: Client = .{ .hwnd = w.hwnd };
    const thread = try std.Thread.spawn(.{}, Client.run, .{&client});
    var msg: c.MSG = undefined;
    var waited: u32 = 0;
    while (!client.done.load(.acquire)) : (waited += 1) {
        if (waited > 10_000) return error.Timeout; // 10 s
        while (c.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
            _ = c.TranslateMessage(&msg);
            _ = c.DispatchMessageW(&msg);
        }
        _ = c.MsgWaitForMultipleObjects(0, null, 0, 1, c.QS_ALLINPUT);
    }
    thread.join();
    try client.result;
    try testing.expectEqual(@as(u32, 1), w.pressed);
}

/// A window with a list of two items, several selectable.
const ListWindow = struct {
    hwnd: c.HWND,
    ui: core.Window,
    list: core.items.Rectangle = .{},
    rows: [2]core.items.Rectangle = .{ .{}, .{} },
    list_props: core.AccessibleProperties = .{},
    row_props: [2]core.AccessibleProperties = .{ .{}, .{} },

    fn init(self: *ListWindow) !void {
        const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
        self.* = .{
            .hwnd = c.CreateWindowExW(0, class, class, c.WS_POPUP, 100, 100, 200, 100, null, null, null, null) orelse return error.SkipZigTest,
            .ui = undefined,
        };
        self.ui.init(testing.allocator, .{ .width = 200, .height = 100 });
        self.ui.rootItem().appendChild(&self.list.item);
        self.list.item.setGeometry(.{ .width = 200, .height = 100 });
        self.list.item.accessible = &self.list_props;
        self.list_props.role.set(.list);
        self.list_props.multiselectable.set(true);
        for (&self.rows, &self.row_props, 0..) |*row, *props, i| {
            self.list.item.appendChild(&row.item);
            row.item.setGeometry(.{ .y = @floatFromInt(i * 30), .width = 200, .height = 30 });
            row.item.accessible = props;
            props.role.set(.list_item);
            props.label.set(if (i == 0) "Ada" else "Grace");
            props.action_set_selected.setHandler(props, setSelected);
        }
        self.row_props[0].action_select.setHandler(self, selectFirst);
        self.row_props[1].action_select.setHandler(self, selectSecond);
    }

    fn selectFirst(self: *ListWindow) void {
        self.row_props[0].checked.set(true);
        self.row_props[1].checked.set(false);
    }

    fn selectSecond(self: *ListWindow) void {
        self.row_props[0].checked.set(false);
        self.row_props[1].checked.set(true);
    }

    fn setSelected(props: *core.AccessibleProperties, on: bool) void {
        props.checked.set(on);
    }

    fn deinit(self: *ListWindow) void {
        for (&self.row_props) |*p| p.deinit();
        for (&self.rows) |*r| r.deinit();
        self.list_props.deinit();
        self.list.deinit();
        self.ui.deinit();
        _ = c.DestroyWindow(self.hwnd);
    }
};

test "list items selected through UI Automation" {
    var w: ListWindow = undefined;
    try w.init();
    defer w.deinit();
    const bridge = try Bridge.create(testing.allocator, &w.ui, w.hwnd);
    defer bridge.destroy();
    try bridge.update();

    const item = struct {
        fn of(b: *Bridge, row: *core.items.Rectangle) [*c]c.ISelectionItemProvider {
            var p: ?*anyopaque = null;
            const e = b.elements.get(&row.item).?;
            if (e.queryInterface(&iid_selection_item, &p) != S_OK) return null;
            return @ptrCast(@alignCast(p));
        }
        fn selected(p: [*c]c.ISelectionItemProvider) bool {
            var out: c.BOOL = 0;
            _ = p.*.lpVtbl.*.get_IsSelected.?(p, &out);
            return out != 0;
        }
    };
    const ada = item.of(bridge, &w.rows[0]);
    defer _ = ada.*.lpVtbl.*.Release.?(ada);
    const grace = item.of(bridge, &w.rows[1]);
    defer _ = grace.*.lpVtbl.*.Release.?(grace);
    try testing.expect(!item.selected(ada));

    // Select: only it; add and remove: one more, one less.
    try testing.expectEqual(S_OK, ada.*.lpVtbl.*.Select.?(ada));
    try bridge.update();
    try testing.expect(item.selected(ada) and !item.selected(grace));
    try testing.expectEqual(S_OK, grace.*.lpVtbl.*.AddToSelection.?(grace));
    try bridge.update();
    try testing.expect(item.selected(ada) and item.selected(grace));
    try testing.expectEqual(S_OK, ada.*.lpVtbl.*.RemoveFromSelection.?(ada));
    try bridge.update();
    try testing.expect(!item.selected(ada) and item.selected(grace));

    // The list: several selectable, the selected ones.
    var container: [*c]c.IRawElementProviderSimple = null;
    try testing.expectEqual(S_OK, grace.*.lpVtbl.*.get_SelectionContainer.?(grace, &container));
    defer _ = container.*.lpVtbl.*.Release.?(container);
    var unknown: [*c]c.IUnknown = null;
    try testing.expectEqual(S_OK, container.*.lpVtbl.*.GetPatternProvider.?(container, c.UIA_SelectionPatternId, &unknown));
    const selection: [*c]c.ISelectionProvider = @ptrCast(@alignCast(unknown));
    defer _ = selection.*.lpVtbl.*.Release.?(selection);
    var multiple: c.BOOL = 0;
    try testing.expectEqual(S_OK, selection.*.lpVtbl.*.get_CanSelectMultiple.?(selection, &multiple));
    try testing.expect(multiple != 0);
    var array: [*c]c.SAFEARRAY = null;
    try testing.expectEqual(S_OK, selection.*.lpVtbl.*.GetSelection.?(selection, &array));
    defer _ = c.SafeArrayDestroy(array);
    var upper: c.LONG = -1;
    _ = c.SafeArrayGetUBound(array, 1, &upper);
    try testing.expectEqual(@as(c.LONG, 0), upper); // one: Grace
    var first: [*c]c.IRawElementProviderSimple = null;
    var index: c.LONG = 0;
    try testing.expectEqual(S_OK, c.SafeArrayGetElement(array, &index, @ptrCast(&first)));
    defer _ = first.*.lpVtbl.*.Release.?(first);
    try testing.expectEqual(&w.rows[1].item, Element.of("simple", first).item.?);
}
