// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The item tree. Every built-in element (`Rectangle`, `Text`, layouts, ...)
//! embeds an `Item` header holding its tree links, geometry properties and
//! vtable. Items are owned by their component; the tree only links them.
//! Like properties, items must not move once linked or bound.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const Callback = @import("callbacks.zig").Callback;
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Size = geometry.Size;
const Rect = geometry.Rect;
const Affine = geometry.Affine;
const Projective = geometry.Projective;
const Image = @import("image.zig").Image;

/// Whether items can be rotated and scaled. An app can leave it out (about
/// 18 KB of code with the software renderer, for microcontrollers) by
/// declaring in its root file `pub const zigulee_options = .{ .transforms =
/// false };`: items are then drawn, and hit, as laid out.
pub const transforms = blk: {
    const root = @import("root");
    if (@hasDecl(root, "zigulee_options") and @hasField(@TypeOf(root.zigulee_options), "transforms"))
        break :blk root.zigulee_options.transforms;
    break :blk true;
};

/// Whether items can be blurred (`blur`), and faded with their children
/// as one (`opacity`): both draw into a layer, an image of their own. An
/// app can leave them out (microcontrollers) by declaring in its root file
/// `pub const zigulee_options = .{ .effects = false };`: blur is then
/// ignored, and opacity applies to each thing drawn.
pub const effects = blk: {
    const root = @import("root");
    if (@hasDecl(root, "zigulee_options") and @hasField(@TypeOf(root.zigulee_options), "effects"))
        break :blk root.zigulee_options.effects;
    break :blk true;
};

/// Whether a Text whose text changes repaints only where its lines are,
/// not its whole box (a short label in a wide item). An app can leave it
/// out (microcontrollers) by declaring in its root file `pub const
/// zigulee_options = .{ .text_bounds = false };`: its whole box is repainted.
pub const text_bounds = blk: {
    const root = @import("root");
    if (@hasDecl(root, "zigulee_options") and @hasField(@TypeOf(root.zigulee_options), "text_bounds"))
        break :blk root.zigulee_options.text_bounds;
    break :blk true;
};

/// How an item's content (and children) is rotated and scaled, around
/// `origin` (by default the item's center), and blurred. It does not change
/// the layout. Kept apart from the item: only items that transform have
/// one.
pub const ItemTransform = struct {
    /// Degrees, clockwise.
    rotation: Property(f32) = .init(0),
    scale_x: Property(f32) = .init(1),
    scale_y: Property(f32) = .init(1),
    /// In the item's coordinates; null: its center.
    origin_x: Property(?f32) = .init(null),
    origin_y: Property(?f32) = .init(null),
    /// The blur's standard deviation (as CSS's `filter: blur()`), in the
    /// item's coordinates; 0: none.
    blur: Property(f32) = .init(0),
    /// Tilted in depth around its origin, in degrees: about the horizontal
    /// axis (the top going away), then the vertical one (the right side
    /// going away). Seen in perspective, from the parent's `perspective`.
    rotation_x: Property(f32) = .init(0),
    rotation_y: Property(f32) = .init(0),
    /// For its children tilted in depth: how far the viewer is from the
    /// item's plane, looking at its center (CSS's `perspective`).
    perspective: Property(f32) = .init(default_perspective),
    /// SVG path data in the item's coordinates: it and its children show
    /// only inside (with effects); empty: everywhere.
    clip_path: Property([]const u8) = .init(""),
    /// An image stretched over the item: it and its children show only
    /// where it is opaque, as much as it is (with effects; QML's
    /// `OpacityMask`).
    mask_image: Property(?Image) = .init(null),
    /// An element whose drawing masks it and its children instead, as
    /// much as it is opaque (`mask-source`; QML's `maskSource`): drawn as
    /// if it were a child, even when not visible. Set once, when built.
    mask_source: ?*Item = null,
    /// The mask shows what it covers no more, and what it does not.
    mask_inverted: Property(bool) = .init(false),
    /// Drawn (with its children) into an image kept while what it draws is
    /// the same, which is shown turned as it is (with effects): turning,
    /// or under something that changes, it is not drawn again. Edges and
    /// text turned so are a little softer.
    prefer_rendering_cache: Property(bool) = .init(false),

    /// The perspective of items whose parent sets none.
    pub const default_perspective = 1000;

    pub fn deinit(self: *ItemTransform) void {
        self.blur.deinit();
        self.rotation_x.deinit();
        self.rotation_y.deinit();
        self.perspective.deinit();
        self.clip_path.deinit();
        self.mask_image.deinit();
        self.mask_inverted.deinit();
        self.prefer_rendering_cache.deinit();
        self.rotation.deinit();
        self.scale_x.deinit();
        self.scale_y.deinit();
        self.origin_x.deinit();
        self.origin_y.deinit();
    }
};
const layout = @import("layout.zig");
const LayoutInfo = layout.LayoutInfo;
const Orientation = layout.Orientation;
const input = @import("input.zig");
const ItemRenderer = @import("rendering.zig").ItemRenderer;
const Window = @import("window.zig").Window;

pub const ItemVTable = struct {
    name: []const u8,
    /// Intrinsic constraints. Null: the default, merged with the
    /// constraints of any child layouts.
    layoutInfo: ?*const fn (*Item, Orientation) LayoutInfo = null,
    /// Draws the item within its own bounds.
    render: ?*const fn (*Item, ItemRenderer) void = null,
    /// Pointer events; positions are relative to the item.
    inputEvent: ?*const fn (*Item, input.PointerEvent, *Window) input.InputEventResult = null,
    keyEvent: ?*const fn (*Item, input.KeyEventKind, input.KeyEvent, *Window) input.EventResult = null,
    focusEvent: ?*const fn (*Item, input.FocusEvent, *Window) void = null,
    /// Input method composition text (see `Window.dispatchPreedit`).
    preeditEvent: ?*const fn (*Item, text: []const u8, cursor: usize, *Window) void = null,
    acceptsFocus: ?*const fn (*Item) bool = null,
    clipsChildren: ?*const fn (*Item) bool = null,
    /// The radius of the clip's corners, when it clips its children.
    clipRadius: ?*const fn (*Item) f32 = null,
    /// Sees pointer events before the item's children do, and may take
    /// them over (e.g. a `Flickable` turning a press into a drag).
    inputEventFilter: ?*const fn (*Item, input.PointerEvent, *Window) input.InputEventFilterResult = null,
    /// Called when children are added or removed by a repeater or
    /// conditional (layouts rebind their children).
    childrenChanged: ?*const fn (*Item) void = null,
    /// Repeaters: the model's row count, and showing only the rows
    /// `first..first + count` (a `ListLayout` asks; see `Repeater.showRows`).
    modelRowCount: ?*const fn (*Item) usize = null,
    showRows: ?*const fn (*Item, first: usize, count: usize) void = null,
    /// Where scrolling over it settles (a list's rows, a table's columns),
    /// for a `Flickable` with `snap_to_items`: along `o`, the snap position
    /// nearest `at` (`dir` 0), or the first past it (1: further along, -1:
    /// back), in its own coordinates; null: none.
    snapPosition: ?*const fn (*Item, o: Orientation, at: f32, dir: i2) ?f32 = null,
    /// Label for assistive technology when none is set explicitly.
    accessibleLabel: ?*const fn (*Item) []const u8 = null,
    /// The value read out for the item (a text field's text).
    accessibleValue: ?*const fn (*Item) []const u8 = null,
    /// The pointer's shape over the item (null: the default).
    mouseCursor: ?*const fn (*Item) input.MouseCursor = null,
    accessible_role: AccessibleRole = .none,
    /// Layout items fill their parent and contribute their constraints to it.
    is_layout: bool = false,
    /// Repeaters and conditionals: their children take part in the parent
    /// layout as if they were the parent's own children.
    flatten_in_layout: bool = false,
    /// A `ListLayout`: repeaters in it start with no rows, then show those
    /// it asks for.
    shows_rows: bool = false,
    /// Popups: drawn above everything else when open, not laid out, and
    /// skipped by the normal drawing and input traversal.
    is_popup: bool = false,
};

pub const Item = struct {
    vtable: *const ItemVTable,
    parent: ?*Item = null,
    first_child: ?*Item = null,
    last_child: ?*Item = null,
    prev_sibling: ?*Item = null,
    next_sibling: ?*Item = null,

    /// Position relative to the parent, and size.
    x: Property(f32) = .init(0),
    y: Property(f32) = .init(0),
    width: Property(f32) = .init(0),
    height: Property(f32) = .init(0),

    /// Invisible items (and their children) are not drawn, do not receive
    /// input and cannot take focus. They still take space in layouts.
    visible: Property(bool) = .init(true),
    /// Disabled items, and their children with them (`isEnabled`), take
    /// no input and cannot take focus. They are drawn as they are: the
    /// widgets grey themselves.
    enabled: Property(bool) = .init(true),
    /// Applies to the item and its children.
    opacity: Property(f32) = .init(1),

    /// Explicit `min-width`, `preferred-height`, ... overrides, if any.
    constraints: ?*LayoutConstraints = null,
    /// Explicit accessibility properties, if any.
    accessible: ?*AccessibleProperties = null,
    /// Rotation and scale, if any.
    transform: ?*ItemTransform = null,

    pub fn init(vtable: *const ItemVTable) Item {
        return .{ .vtable = vtable };
    }

    /// Unlinks the item (and detaches its children) and releases its
    /// geometry bindings. Called by each concrete item's `deinit`.
    pub fn deinit(self: *Item) void {
        self.removeFromParent();
        while (self.first_child) |c| c.removeFromParent();
        self.x.deinit();
        self.y.deinit();
        self.width.deinit();
        self.height.deinit();
        self.visible.deinit();
        self.enabled.deinit();
        self.opacity.deinit();
        self.* = undefined;
    }

    pub fn appendChild(self: *Item, child: *Item) void {
        std.debug.assert(child.parent == null);
        child.parent = self;
        child.prev_sibling = self.last_child;
        child.next_sibling = null;
        if (self.last_child) |l| l.next_sibling = child else self.first_child = child;
        self.last_child = child;
        if (self.window()) |w| w.requestRedraw();
    }

    /// Inserts `child` before `before`, or at the end if `before` is null.
    pub fn insertChildBefore(self: *Item, child: *Item, before: ?*Item) void {
        const b = before orelse return self.appendChild(child);
        std.debug.assert(child.parent == null and b.parent == self);
        child.parent = self;
        child.next_sibling = b;
        child.prev_sibling = b.prev_sibling;
        if (b.prev_sibling) |p| p.next_sibling = child else self.first_child = child;
        b.prev_sibling = child;
        if (self.window()) |w| w.requestRedraw();
    }

    /// Appends several children in order.
    pub fn appendChildren(self: *Item, items: []const *Item) void {
        for (items) |c| self.appendChild(c);
    }

    pub fn removeFromParent(self: *Item) void {
        const parent = self.parent orelse return;
        if (self.window()) |w| w.itemRemoved(self);
        if (self.prev_sibling) |p| p.next_sibling = self.next_sibling else parent.first_child = self.next_sibling;
        if (self.next_sibling) |n| n.prev_sibling = self.prev_sibling else parent.last_child = self.prev_sibling;
        self.parent = null;
        self.prev_sibling = null;
        self.next_sibling = null;
    }

    /// True if this item and all its ancestors are visible.
    pub fn isVisibleInTree(self: *Item) bool {
        var it: ?*Item = self;
        while (it) |i| : (it = i.parent) if (!i.visible.get()) return false;
        return true;
    }

    /// True if this item and all its ancestors are enabled: what `.zge`
    /// reads as its `enabled` (as QML's), while setting it sets the item's
    /// own.
    pub fn isEnabled(self: *Item) bool {
        var it: ?*Item = self;
        while (it) |i| : (it = i.parent) if (!i.enabled.get()) return false;
        return true;
    }

    pub fn isEnabledUntracked(self: *Item) bool {
        var it: ?*Item = self;
        while (it) |i| : (it = i.parent) if (!i.enabled.getUntracked()) return false;
        return true;
    }

    pub fn childCount(self: *const Item) usize {
        var n: usize = 0;
        var it = self.first_child;
        while (it) |c| : (it = c.next_sibling) n += 1;
        return n;
    }

    pub fn root(self: *Item) *Item {
        var it = self;
        while (it.parent) |p| it = p;
        return it;
    }

    /// The window this item is shown in, if it is in one.
    pub fn window(self: *Item) ?*Window {
        return Window.fromRootItem(self.root());
    }

    /// True if `self` is `other` or one of its ancestors.
    pub fn contains(self: *const Item, other: *const Item) bool {
        var it: ?*const Item = other;
        while (it) |i| : (it = i.parent) if (i == self) return true;
        return false;
    }

    /// The next item in pre-order (depth-first) traversal of the tree.
    pub fn nextInTree(self: *Item) ?*Item {
        if (self.first_child) |c| return c;
        var it: ?*Item = self;
        while (it) |i| : (it = i.parent) if (i.next_sibling) |n| return n;
        return null;
    }

    /// The previous item in pre-order traversal of the tree.
    pub fn previousInTree(self: *Item) ?*Item {
        var p = self.prev_sibling orelse return self.parent;
        while (p.last_child) |c| p = c;
        return p;
    }

    pub fn geometry(self: *Item) Rect {
        return .{ .x = self.x.get(), .y = self.y.get(), .width = self.width.get(), .height = self.height.get() };
    }

    pub fn size(self: *Item) Size {
        return .{ .width = self.width.get(), .height = self.height.get() };
    }

    /// Position of the item's origin in window coordinates.
    pub fn absolutePosition(self: *Item) Point {
        var p: Point = .{};
        var it: ?*Item = self;
        while (it) |i| : (it = i.parent) p = p.add(.{ .x = i.x.get(), .y = i.y.get() });
        return p;
    }

    pub fn absoluteGeometry(self: *Item) Rect {
        return Rect.fromOriginSize(self.absolutePosition(), self.size());
    }

    /// The rotation and scale of its content, around its origin, in its
    /// own coordinates; null if it has none.
    pub fn localTransform(self: *Item) ?Affine {
        if (!transforms) return null;
        const t = self.transform orelse return null;
        const degrees = t.rotation.get();
        const sx = t.scale_x.get();
        const sy = t.scale_y.get();
        if (degrees == 0 and sx == 1 and sy == 1) return null;
        const o: Point = .{
            .x = t.origin_x.get() orelse self.width.get() / 2,
            .y = t.origin_y.get() orelse self.height.get() / 2,
        };
        return Affine.translation(o).mul(Affine.rotation(degrees)).mul(Affine.scaling(sx, sy)).mul(Affine.translation(.{ .x = -o.x, .y = -o.y }));
    }

    /// Where its drawing (and its children's), laid flat in its parent,
    /// shows when tilted in depth (`rotation_x`, `rotation_y`): a mapping in
    /// the parent's coordinates, around its origin, seen from the parent's
    /// `perspective` over the parent's center. Null if it is not tilted.
    pub fn projection(self: *Item) ?Projective {
        if (!transforms) return null;
        const t = self.transform orelse return null;
        const rx = t.rotation_x.get();
        const ry = t.rotation_y.get();
        if (rx == 0 and ry == 0) return null;
        const origin: Point = .{
            .x = self.x.get() + (t.origin_x.get() orelse self.width.get() / 2),
            .y = self.y.get() + (t.origin_y.get() orelse self.height.get() / 2),
        };
        var center = origin;
        var d: f32 = ItemTransform.default_perspective;
        if (self.parent) |p| {
            center = .{ .x = p.width.get() / 2, .y = p.height.get() / 2 };
            if (p.transform) |pt| d = pt.perspective.get();
        }
        return perspective(origin, center, @max(1, d), rx, ry);
    }

    /// Points of the plane turned by `rx` then `ry` degrees around `origin`
    /// (`rx` about the horizontal axis, `ry` about the vertical one), seen
    /// from `d` in front of `center`.
    pub fn perspective(origin: Point, center: Point, d: f32, rx: f32, ry: f32) Projective {
        const ax = rx * std.math.pi / 180;
        const ay = ry * std.math.pi / 180;
        const cx = @cos(ax);
        const sx = @sin(ax);
        const cy = @cos(ay);
        const sy = @sin(ay);
        // The plane's point (u, v, 0), from the origin, turned: x, y and its
        // depth (toward the viewer).
        const r = [3][2]f32{ .{ cy, 0 }, .{ sx * sy, cx }, .{ -sy * cx, sx } };
        // Seen from the viewer: x' = c + (o + x - c) d / (d - z).
        const m: Projective = .{ .m = .{
            .{ d * r[0][0] - center.x * r[2][0], d * r[0][1] - center.x * r[2][1], d * origin.x },
            .{ d * r[1][0] - center.y * r[2][0], d * r[1][1] - center.y * r[2][1], d * origin.y },
            .{ -r[2][0], -r[2][1], d },
        } };
        return m.mul(Projective.fromAffine(Affine.translation(.{ .x = -origin.x, .y = -origin.y })));
    }

    /// How much its content (and children) is blurred: the standard
    /// deviation, 0 for none.
    /// Whether it is drawn into an image kept while it is the same
    /// (`prefer-rendering-cache`).
    pub fn prefersRenderingCache(self: *Item) bool {
        if (!effects) return false;
        const t = self.transform orelse return false;
        return t.prefer_rendering_cache.get();
    }

    pub fn blurRadius(self: *Item) f32 {
        if (!effects) return 0;
        const t = self.transform orelse return 0;
        return @max(0, t.blur.get());
    }

    /// The shape it and its children show in (`clip-path`: SVG path data
    /// in its coordinates); empty: no shape.
    pub fn clipPath(self: *Item) []const u8 {
        if (!effects) return "";
        const t = self.transform orelse return "";
        return t.clip_path.get();
    }

    /// The image it and its children show through (`mask-image`; valid
    /// until it changes); null: none.
    pub fn maskImage(self: *Item) ?*const Image {
        if (!effects) return null;
        const t = self.transform orelse return null;
        return if (t.mask_image.getPtr().*) |*img| img else null;
    }

    /// The element whose drawing masks it and its children (`mask-source`);
    /// null: none.
    pub fn maskSource(self: *Item) ?*Item {
        if (!effects) return null;
        const t = self.transform orelse return null;
        return t.mask_source;
    }

    /// Whether its mask (image or element) is inverted.
    pub fn maskInverted(self: *Item) bool {
        if (!effects) return false;
        const t = self.transform orelse return false;
        return t.mask_inverted.get();
    }

    /// The radius of the corners of its children's clip (0 without
    /// effects: square).
    pub fn clipRadius(self: *Item) f32 {
        if (!effects) return 0;
        const f = self.vtable.clipRadius orelse return 0;
        return @max(0, f(self));
    }

    /// From its coordinates to the window's (with the ancestors'
    /// rotations and scales).
    pub fn windowTransform(self: *Item) Affine {
        var m = Affine.translation(.{ .x = self.x.get(), .y = self.y.get() });
        if (self.localTransform()) |l| m = m.mul(l);
        return if (self.parent) |p| p.windowTransform().mul(m) else m;
    }

    /// A window point in its coordinates (through the ancestors' tilts in
    /// depth too).
    pub fn fromWindow(self: *Item, p: Point) Point {
        const nowhere: Point = .{ .x = std.math.inf(f32), .y = std.math.inf(f32) };
        var q = if (self.parent) |parent| parent.fromWindow(p) else p;
        if (transforms) if (self.projection()) |h| {
            q = (h.inverse() orelse return nowhere).apply(q) orelse return nowhere;
        };
        q = q.sub(.{ .x = self.x.get(), .y = self.y.get() });
        if (self.localTransform()) |m| q = (m.inverse() orelse return nowhere).apply(q);
        return q;
    }

    pub fn setGeometry(self: *Item, rect: Rect) void {
        self.x.set(rect.x);
        self.y.set(rect.y);
        self.width.set(rect.width);
        self.height.set(rect.height);
    }

    /// Binds the geometry to cover the parent (the default for an element
    /// without explicit geometry, and for layouts).
    pub fn fillParent(self: *Item, gpa: Allocator) Allocator.Error!void {
        self.x.set(0);
        self.y.set(0);
        try self.width.setBinding(gpa, self, struct {
            fn f(i: *Item) f32 {
                return if (i.parent) |p| p.width.get() else 0;
            }
        }.f);
        try self.height.setBinding(gpa, self, struct {
            fn f(i: *Item) f32 {
                return if (i.parent) |p| p.height.get() else 0;
            }
        }.f);
    }

    /// Effective constraints: intrinsic, then explicit overrides.
    pub fn layoutInfo(self: *Item, orientation: Orientation) LayoutInfo {
        var info = if (self.vtable.layoutInfo) |f| f(self, orientation) else self.childLayoutsInfo(orientation);
        if (self.constraints) |c| info = c.apply(orientation, info);
        return info.normalized();
    }

    fn childLayoutsInfo(self: *Item, orientation: Orientation) LayoutInfo {
        var info: LayoutInfo = .{};
        var it = self.first_child;
        while (it) |c| : (it = c.next_sibling) {
            if (c.vtable.is_layout) info = info.merge(c.layoutInfo(orientation));
        }
        return info;
    }

    pub fn accessibleRole(self: *Item) AccessibleRole {
        if (self.accessible) |a| {
            const r = a.role.get();
            if (r != .unset) return r;
        }
        return self.vtable.accessible_role;
    }

    pub fn accessibleLabel(self: *Item) []const u8 {
        if (self.accessible) |a| {
            const label = a.label.get();
            if (label.len > 0) return label;
        }
        return if (self.vtable.accessibleLabel) |f| f(self) else "";
    }

    pub fn accessibleValue(self: *Item) []const u8 {
        if (self.accessible) |a| {
            const value = a.value.get();
            if (value.len > 0) return value;
        }
        return if (self.vtable.accessibleValue) |f| f(self) else "";
    }

    /// Tells a layout (or other container) that children were added or
    /// removed, so it takes them into account.
    pub fn notifyChildrenChanged(self: *Item) void {
        if (self.vtable.childrenChanged) |f| f(self);
    }

    pub fn clipsChildren(self: *Item) bool {
        return if (self.vtable.clipsChildren) |f| f(self) else false;
    }

    pub fn acceptsFocus(self: *Item) bool {
        const f = self.vtable.acceptsFocus orelse return false;
        return self.isEnabled() and f(self);
    }

    pub const ChildIterator = struct {
        next_item: ?*Item,
        reverse: bool,

        pub fn next(it: *ChildIterator) ?*Item {
            const c = it.next_item orelse return null;
            it.next_item = if (it.reverse) c.prev_sibling else c.next_sibling;
            return c;
        }
    };

    pub fn children(self: *Item) ChildIterator {
        return .{ .next_item = self.first_child, .reverse = false };
    }

    /// Children from topmost (last) to bottommost (first).
    pub fn childrenReversed(self: *Item) ChildIterator {
        return .{ .next_item = self.last_child, .reverse = true };
    }

    /// Iterates the children a layout positions: like `children`, but the
    /// children of repeaters and conditionals take their place.
    pub const LayoutChildIterator = struct {
        next_item: ?*Item,
        /// The repeater being expanded, if any.
        inside: ?*Item = null,

        pub fn next(it: *LayoutChildIterator) ?*Item {
            while (true) {
                const c = it.next_item orelse {
                    const r = it.inside orelse return null;
                    it.inside = null;
                    it.next_item = r.next_sibling;
                    continue;
                };
                if (c.vtable.is_popup) {
                    it.next_item = c.next_sibling;
                    continue;
                }
                if (it.inside == null and c.vtable.flatten_in_layout) {
                    it.inside = c;
                    it.next_item = c.first_child;
                    continue;
                }
                it.next_item = c.next_sibling;
                return c;
            }
        }
    };

    pub fn layoutChildren(self: *Item) LayoutChildIterator {
        return .{ .next_item = self.first_child };
    }

    pub fn layoutChildCount(self: *Item) usize {
        var n: usize = 0;
        var it = self.layoutChildren();
        while (it.next()) |_| n += 1;
        return n;
    }
};

/// Roles reported to assistive technology (`accessible-role`).
pub const AccessibleRole = enum {
    /// Not set: the item type's own role.
    unset,
    /// Not reported (its children still are).
    none,
    button,
    checkbox,
    radio_button,
    combobox,
    list,
    list_item,
    slider,
    spinbox,
    switch_,
    tab,
    tab_list,
    table,
    text,
    text_input,
    progress_indicator,
    image,
    group,
    tab_panel,
    /// A row of a table: its cells are its children.
    table_row,
    table_cell,
    /// A table's column title (clicked to sort, say).
    column_header,
};

/// Explicit accessibility properties (`accessible-role`, `accessible-label`,
/// ...) and actions assistive technology can perform. Attach with
/// `item.accessible = &a`; generated code does it for elements that set
/// any of them.
pub const AccessibleProperties = struct {
    role: Property(AccessibleRole) = .init(.unset),
    label: Property([]const u8) = .init(""),
    description: Property([]const u8) = .init(""),
    /// The current value as read out (a slider's "40", a field's text).
    value: Property([]const u8) = .init(""),
    /// For values in a range (sliders, spin boxes, progress).
    value_minimum: Property(f32) = .init(0),
    value_maximum: Property(f32) = .init(0),
    value_step: Property(f32) = .init(0),
    checkable: Property(bool) = .init(false),
    checked: Property(bool) = .init(false),
    enabled: Property(bool) = .init(true),
    placeholder_text: Property([]const u8) = .init(""),
    /// A list's or table's: several of its items can be selected at once.
    multiselectable: Property(bool) = .init(false),

    /// The main action: press a button, toggle a check box...
    action_default: Callback(fn () void) = .{},
    action_increment: Callback(fn () void) = .{},
    action_decrement: Callback(fn () void) = .{},
    action_set_value: Callback(fn ([]const u8) void) = .{},
    /// An item of a list or table: select it, and only it.
    action_select: Callback(fn () void) = .{},
    /// An item of a list or table: add it to the selection (true) or
    /// remove it (false).
    action_set_selected: Callback(fn (bool) void) = .{},

    pub fn deinit(self: *AccessibleProperties) void {
        inline for (std.meta.fields(AccessibleProperties)) |f| {
            if (@hasDecl(f.type, "deinit")) @field(self, f.name).deinit();
        }
    }
};

/// Explicit size constraints for an item (`min-width: 50px;` and so on).
/// Null means "not set". Attach with `item.constraints = &c`.
pub const LayoutConstraints = struct {
    min_width: Property(?f32) = .init(null),
    max_width: Property(?f32) = .init(null),
    preferred_width: Property(?f32) = .init(null),
    horizontal_stretch: Property(?f32) = .init(null),
    min_height: Property(?f32) = .init(null),
    max_height: Property(?f32) = .init(null),
    preferred_height: Property(?f32) = .init(null),
    vertical_stretch: Property(?f32) = .init(null),

    pub fn deinit(self: *LayoutConstraints) void {
        inline for (std.meta.fields(LayoutConstraints)) |f| @field(self, f.name).deinit();
    }

    /// Fixes the size along both axes, like an explicit `width`/`height`
    /// inside a layout.
    pub fn setFixedSize(self: *LayoutConstraints, s: Size) void {
        self.min_width.set(s.width);
        self.max_width.set(s.width);
        self.preferred_width.set(s.width);
        self.min_height.set(s.height);
        self.max_height.set(s.height);
        self.preferred_height.set(s.height);
    }

    fn apply(self: *LayoutConstraints, orientation: Orientation, base: LayoutInfo) LayoutInfo {
        var info = base;
        const min, const max, const preferred, const stretch = switch (orientation) {
            .horizontal => .{ self.min_width.get(), self.max_width.get(), self.preferred_width.get(), self.horizontal_stretch.get() },
            .vertical => .{ self.min_height.get(), self.max_height.get(), self.preferred_height.get(), self.vertical_stretch.get() },
        };
        if (min) |v| info.min = v;
        if (max) |v| info.max = v;
        if (preferred) |v| info.preferred = v;
        if (stretch) |v| info.stretch = v;
        return info;
    }
};

const testing = std.testing;

test "tree links and traversal order" {
    const vt: ItemVTable = .{ .name = "Test" };
    var a: Item = .init(&vt);
    var b: Item = .init(&vt);
    var c: Item = .init(&vt);
    var d: Item = .init(&vt);
    defer for ([_]*Item{ &d, &c, &b, &a }) |i| i.deinit();

    // a -> (b -> d), c
    a.appendChildren(&.{ &b, &c });
    b.appendChild(&d);
    try testing.expectEqual(@as(usize, 2), a.childCount());
    try testing.expectEqual(&b, a.nextInTree().?);
    try testing.expectEqual(&d, b.nextInTree().?);
    try testing.expectEqual(&c, d.nextInTree().?);
    try testing.expectEqual(@as(?*Item, null), c.nextInTree());
    try testing.expectEqual(&d, c.previousInTree().?);
    try testing.expectEqual(&a, b.previousInTree().?);
    try testing.expect(a.contains(&d));
    try testing.expect(!b.contains(&c));

    var rev = a.childrenReversed();
    try testing.expectEqual(&c, rev.next().?);
    try testing.expectEqual(&b, rev.next().?);
    try testing.expectEqual(@as(?*Item, null), rev.next());

    b.removeFromParent();
    try testing.expectEqual(&c, a.first_child.?);
    try testing.expectEqual(@as(?*Item, null), c.prev_sibling);
    try testing.expectEqual(&b, d.root());
}

test "absolute geometry and fillParent" {
    const vt: ItemVTable = .{ .name = "Test" };
    var parent: Item = .init(&vt);
    var child: Item = .init(&vt);
    defer {
        child.deinit();
        parent.deinit();
    }
    parent.appendChild(&child);
    parent.setGeometry(.{ .x = 10, .y = 20, .width = 100, .height = 50 });
    try child.fillParent(testing.allocator);
    child.x.set(5);
    try testing.expectEqual(Rect{ .x = 15, .y = 20, .width = 100, .height = 50 }, child.absoluteGeometry());
    parent.width.set(300);
    try testing.expectEqual(@as(f32, 300), child.width.get());
}

test "insertChildBefore and layout child flattening" {
    const plain: ItemVTable = .{ .name = "Test" };
    const flat: ItemVTable = .{ .name = "Repeater", .flatten_in_layout = true };
    var parent: Item = .init(&plain);
    var a: Item = .init(&plain);
    var rep: Item = .init(&flat);
    var r1: Item = .init(&plain);
    var r2: Item = .init(&plain);
    var b: Item = .init(&plain);
    var empty_rep: Item = .init(&flat);
    defer for ([_]*Item{ &empty_rep, &b, &r2, &r1, &rep, &a, &parent }) |i| i.deinit();

    parent.appendChildren(&.{ &a, &rep, &empty_rep });
    parent.insertChildBefore(&b, &empty_rep);
    rep.appendChild(&r2);
    rep.insertChildBefore(&r1, &r2);

    var it = parent.layoutChildren();
    for ([_]*Item{ &a, &r1, &r2, &b }) |expected| try testing.expectEqual(expected, it.next().?);
    try testing.expectEqual(@as(?*Item, null), it.next());
    try testing.expectEqual(@as(usize, 4), parent.layoutChildCount());
}

test "visibility is inherited" {
    const vt: ItemVTable = .{ .name = "Test" };
    var parent: Item = .init(&vt);
    var child: Item = .init(&vt);
    defer {
        child.deinit();
        parent.deinit();
    }
    parent.appendChild(&child);
    try testing.expect(child.isVisibleInTree());
    parent.visible.set(false);
    try testing.expect(!child.isVisibleInTree());
}

test "accessibility defaults and overrides" {
    const vt: ItemVTable = .{ .name = "Button", .accessible_role = .button, .accessibleLabel = struct {
        fn f(_: *Item) []const u8 {
            return "default";
        }
    }.f };
    var item: Item = .init(&vt);
    defer item.deinit();
    try testing.expectEqual(AccessibleRole.button, item.accessibleRole());
    try testing.expectEqualStrings("default", item.accessibleLabel());
    var a: AccessibleProperties = .{};
    defer a.deinit();
    item.accessible = &a;
    a.role.set(.checkbox);
    a.label.set("Remember me");
    try testing.expectEqual(AccessibleRole.checkbox, item.accessibleRole());
    try testing.expectEqualStrings("Remember me", item.accessibleLabel());
}

test "explicit constraints override intrinsic ones" {
    const vt: ItemVTable = .{ .name = "Test" };
    var item: Item = .init(&vt);
    defer item.deinit();
    var c: LayoutConstraints = .{};
    defer c.deinit();
    item.constraints = &c;
    c.min_width.set(30);
    c.horizontal_stretch.set(0);
    try testing.expectEqual(LayoutInfo{ .min = 30, .stretch = 0 }, item.layoutInfo(.horizontal));
    c.setFixedSize(.{ .width = 40, .height = 10 });
    try testing.expectEqual(LayoutInfo{ .min = 40, .max = 40, .preferred = 40, .stretch = 0 }, item.layoutInfo(.horizontal));
    try testing.expectEqual(LayoutInfo{ .min = 10, .max = 10, .preferred = 10 }, item.layoutInfo(.vertical));
}
