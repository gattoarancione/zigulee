// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! A window: the root of an item tree, input dispatch (pointer grabs,
//! hover, keyboard focus) and dirty-region tracking for partial redraws.
//! Platform backends (Phase 4) feed it events and render it on request.

const std = @import("std");
const Allocator = std.mem.Allocator;
const properties = @import("properties.zig");
const Property = properties.Property;
const PropertyTracker = properties.PropertyTracker;
const Callback = @import("callbacks.zig").Callback;
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Size = geometry.Size;
const Rect = geometry.Rect;
const Affine = geometry.Affine;
const Projective = geometry.Projective;
const Region = geometry.Region;
const graphics = @import("graphics.zig");
const Brush = graphics.Brush;
const item_mod = @import("item.zig");
const core_effects = item_mod.effects;
/// Tilts are transforms: their code goes in programs built without them.
const core_transforms = item_mod.transforms;
const Item = item_mod.Item;
const ItemVTable = item_mod.ItemVTable;
const input = @import("input.zig");
const path_mod = @import("path.zig");
const items = @import("items.zig");
const time = @import("time.zig");
const Image = @import("image.zig").Image;
const rendering = @import("rendering.zig");
const ItemRenderer = rendering.ItemRenderer;
const TextMeasurer = rendering.TextMeasurer;
const Font = @import("text/text.zig").Font;

pub const RegisteredFont = struct {
    family: []const u8,
    weight: u16,
    font: *const Font,
};

/// The root item of every window's tree.
pub const WindowItem = struct {
    item: Item = .init(&vtable),
    background: Property(Brush) = .init(.color(.white)),

    const vtable: ItemVTable = .{ .name = "Window", .render = render };

    fn render(i: *Item, r: ItemRenderer) void {
        const self: *WindowItem = @alignCast(@fieldParentPtr("item", i));
        r.drawRectangle(i.size(), .{ .background = self.background.get() });
    }
};

/// The system clipboard, provided by the backend. Without one, a window
/// keeps copied text to itself.
pub const Clipboard = struct {
    ctx: ?*anyopaque,
    /// The clipboard's text, allocated with `gpa` (null if there is none).
    getFn: *const fn (ctx: ?*anyopaque, gpa: Allocator) ?[]u8,
    setFn: *const fn (ctx: ?*anyopaque, text: []const u8) void,
};

/// When an open popup closes by itself.
pub const PopupClosePolicy = enum {
    /// After a click inside it (once handled), or a press outside.
    close_on_click,
    /// On a press outside it.
    close_on_click_outside,
    /// Only when closed explicitly.
    no_auto_close,
};

const OpenPopup = struct {
    item: *Item,
    policy: PopupClosePolicy,
    /// Drawn on top, but input goes past it (a tooltip).
    transparent: bool = false,
    /// Called when the window closes it.
    on_close: ?*const fn (*Item) void = null,
};

pub const RenderMode = enum {
    /// Redraw only what changed since the last frame.
    partial,
    /// Redraw the whole window.
    full,
};

/// Whether a window looks light or dark: backends style what the system
/// draws around it (the title bar) to match.
pub const ColorScheme = enum {
    /// From the window's background: dark if it is.
    auto,
    light,
    dark,
};

/// How a window is shown (`Window.fullscreen` and the like): what the app
/// asks for, and what the system or the user did.
pub const WindowState = struct {
    fullscreen: bool = false,
    maximized: bool = false,
    minimized: bool = false,
    always_on_top: bool = false,

    pub fn eql(a: WindowState, b: WindowState) bool {
        return std.meta.eql(a, b);
    }
};

/// Keeps a backend's window as the app asks (`sync`), and the app's
/// properties as the window is (`report`, when the user maximizes it from
/// the title bar, say). A backend has one per window.
pub const WindowStateSync = struct {
    /// What the system window is in, as far as the backend knows.
    shown: WindowState = .{},
    /// Synced once: before, what the window reports (as it opens) does not
    /// undo what the app asked for.
    started: bool = false,

    /// What changed in what the app asks for since the window was last
    /// put in a state, if anything: the backend applies it and the state
    /// becomes the shown one.
    pub fn sync(self: *WindowStateSync, ui: *Window) ?WindowState {
        self.started = true;
        const want = ui.windowState();
        if (want.eql(self.shown)) return null;
        self.shown = want;
        return want;
    }

    /// The window is now in `actual` (the system or the user put it
    /// there): the app's properties follow.
    pub fn report(self: *WindowStateSync, ui: *Window, actual: WindowState) void {
        self.shown = actual;
        if (!self.started) return;
        if (!ui.windowState().eql(actual)) ui.setWindowState(actual);
    }
};

pub const Window = struct {
    gpa: Allocator,
    root: WindowItem = .{},
    /// See `colorScheme`.
    color_scheme: Property(ColorScheme) = .init(.auto),
    /// How the system shows the window (backends that can do it follow
    /// these, and set them when the user changes it): covering the
    /// screen, as large as it gets, in the dock or taskbar, above the
    /// other windows.
    fullscreen: Property(bool) = .init(false),
    maximized: Property(bool) = .init(false),
    minimized: Property(bool) = .init(false),
    always_on_top: Property(bool) = .init(false),
    /// How far in from each edge the window is clear of the system's
    /// bars, notches and rounded corners (set by backends on phones and
    /// tablets; 0 elsewhere).
    safe_area_top: Property(f32) = .init(0),
    safe_area_left: Property(f32) = .init(0),
    safe_area_bottom: Property(f32) = .init(0),
    safe_area_right: Property(f32) = .init(0),
    /// How much of the window's bottom the on-screen keyboard covers (0
    /// while hidden, and where there is none).
    keyboard_height: Property(f32) = .init(0),
    /// The font of `Text` items that do not set one. Must outlive the
    /// window.
    default_font: Property(?*const Font) = .init(null),
    /// Fonts found by family name and weight (`font-family`, `font-weight`).
    fonts: std.ArrayList(RegisteredFont) = .empty,
    /// Fonts for characters the others lack (emoji, other scripts,
    /// symbols), tried in order.
    fallback_fonts: Property([]const *const Font) = .init(&.{}),
    fallback_list: std.ArrayList(*const Font) = .empty,
    /// The family used when an item asks only for a weight.
    default_family: []const u8 = "",
    /// Measures text when no font is available.
    text_measurer: TextMeasurer = .approximate,
    /// Set by backends with a system clipboard.
    clipboard: ?Clipboard = null,
    /// The clipboard when `clipboard` is null.
    local_clipboard: std.ArrayList(u8) = .empty,
    /// Where the focused text input's caret is, in window coordinates, so
    /// the backend can place the input method's candidate window.
    ime_cursor_rect: ?Rect = null,
    /// Set when `ime_cursor_rect` changes; backends clear it.
    ime_cursor_rect_changed: bool = false,

    /// The backend's view the window shows in (an NSView, a UIView), for
    /// native views placed over it (`WebView`); null where there is none.
    native_view: ?*anyopaque = null,

    focus_item: ?*Item = null,
    /// Changes whenever the focus moves (for trackers: `focus_item` is not
    /// a property).
    focus_generation: Property(u32) = .init(0),
    /// Open popups, bottom to top.
    popups: std.ArrayList(OpenPopup) = .empty,
    /// Receives all pointer events while a press or drag is in progress.
    grabber: ?*Item = null,
    /// Physical pixels per window pixel, as last drawn (2 on most phones
    /// and Retina screens).
    pixel_ratio: Property(f32) = .init(1),
    /// A press at an edge of the window that may pull a closed popup out
    /// (`PopupWindow.open_swipe`).
    edge_drag: ?EdgeDrag = null,
    /// The drag in progress (a `DragArea`), and how to cancel it.
    active_drag: ?*anyopaque = null,
    cancel_drag: ?*const fn (*anyopaque) void = null,
    /// The DropArea a drag from another application is over.
    external_drop_area: ?*anyopaque = null,
    /// Fingers on the window, and the gestures they make.
    touch: @import("gestures.zig").TouchState = .{},
    /// Items that received the last pointer event; they get `exit` when the
    /// pointer leaves them.
    hovered: [max_hovered]*Item = undefined,
    hovered_len: usize = 0,
    /// Ancestors of the grabber that asked to keep filtering its events
    /// (`forward_and_intercept_grab`), outermost first.
    interceptors: [max_interceptors]*Item = undefined,
    interceptors_len: usize = 0,

    render_cache: std.AutoHashMapUnmanaged(*Item, *CacheEntry) = .empty,
    /// Areas uncovered by removed items, painted on the next render.
    pending_dirty: Region = .{},
    redraw_requested: bool = true,
    /// Called the first time something visible changes after a render, so
    /// the backend can schedule a frame.
    on_redraw_request: Callback(fn () void) = .{},
    /// Called with each pointer event before it is dispatched (window
    /// coordinates), whichever item takes it, grabbed ones included: to
    /// watch the input, not to take it.
    pointer_observed: Callback(fn (input.PointerEvent) void) = .{},
    /// Called for each press, move, release, wheel turn, finger, trackpad
    /// gesture and key (`input-activity` in `.zge`): an inactivity
    /// timeout restarts on it.
    input_activity: Callback(fn () void) = .{},

    const max_hovered = 16;
    const max_interceptors = 8;

    const CacheEntry = struct {
        tracker: PropertyTracker,
        /// What the item looked like at the last render.
        state: VisualState = .{},
    };

    /// The tracked outcome of an item's visual dependencies.
    const VisualState = struct {
        /// Window-space bounds of what the item draws; empty if it draws
        /// nothing.
        rect: Rect = .empty,
        /// Hash of the draw calls: unchanged hash and bounds mean unchanged
        /// pixels, even if a dependency changed.
        content: u64 = 0,
        /// Properties that also change how the children look.
        visible: bool = true,
        opacity: f32 = 1,
        clips: bool = false,
        /// Window-space clip area, if the item clips its children.
        clip_rect: Rect = .empty,
        /// From the item's coordinates to the window's (its position, and
        /// the rotations and scales of it and its ancestors). Children
        /// compute theirs from it, so their trackers do not depend on every
        /// ancestor's position.
        matrix: Affine = .identity,
        /// How far the blurs of it and its ancestors spread what it draws
        /// (window pixels): its `rect` includes it.
        spread: f32 = 0,
        /// It is blurred, or faded as one with its children.
        layer: bool = false,
        /// Where what it draws flat (`matrix`) shows, when it or an
        /// ancestor is tilted in depth: a mapping of window coordinates.
        projection: ?Projective = null,
        /// Its `clip-path`, `mask-image` and clip's corner radius, hashed
        /// (0: none).
        shape: u64 = 0,

        fn affectsChildrenDifferently(a: VisualState, b: VisualState) bool {
            return a.visible != b.visible or a.opacity != b.opacity or a.clips != b.clips or
                !std.meta.eql(a.clip_rect, b.clip_rect) or a.spread != b.spread or a.layer != b.layer or
                a.shape != b.shape;
        }
    };

    /// Initializes in place: the window must not move afterwards.
    pub fn init(self: *Window, gpa: Allocator, initial_size: Size) void {
        self.* = .{ .gpa = gpa };
        self.root.item.width.set(initial_size.width);
        self.root.item.height.set(initial_size.height);
    }

    pub fn deinit(self: *Window) void {
        self.on_redraw_request.clearHandler();
        self.redraw_requested = true;
        self.clearRenderCache();
        self.grabber = null;
        self.focus_item = null;
        self.hovered_len = 0;
        self.interceptors_len = 0;
        self.root.item.deinit();
        self.root.background.deinit();
        self.color_scheme.deinit();
        self.fullscreen.deinit();
        self.maximized.deinit();
        self.minimized.deinit();
        self.always_on_top.deinit();
        self.safe_area_top.deinit();
        self.safe_area_left.deinit();
        self.safe_area_bottom.deinit();
        self.safe_area_right.deinit();
        self.keyboard_height.deinit();
        self.focus_generation.deinit();
        self.default_font.deinit();
        self.fonts.deinit(self.gpa);
        self.fallback_fonts.deinit();
        self.fallback_list.deinit(self.gpa);
        self.local_clipboard.deinit(self.gpa);
        self.popups.deinit(self.gpa);
        self.* = undefined;
    }

    fn clearRenderCache(self: *Window) void {
        var it = self.render_cache.valueIterator();
        while (it.next()) |e| {
            e.*.tracker.deinit();
            self.gpa.destroy(e.*);
        }
        self.render_cache.deinit(self.gpa);
        self.render_cache = .empty;
    }

    /// The window whose root item this is (known by the root's vtable:
    /// items must not replace it).
    pub fn fromRootItem(root_item: *Item) ?*Window {
        if (root_item.vtable != &WindowItem.vtable) return null;
        const wi: *WindowItem = @alignCast(@fieldParentPtr("item", root_item));
        return @alignCast(@fieldParentPtr("root", wi));
    }

    /// Makes `font` available as `family` at `weight` (400 regular, 700
    /// bold). The first registered font also becomes the default font and
    /// family. `family` and `font` must outlive the window.
    pub fn registerFont(self: *Window, family: []const u8, weight: u16, font: *const Font) Allocator.Error!void {
        try self.fonts.append(self.gpa, .{ .family = family, .weight = weight, .font = font });
        if (self.default_family.len == 0) {
            self.default_family = family;
            if (self.default_font.getUntracked() == null) self.default_font.set(font);
        }
    }

    /// Adds a font for characters the fonts of texts lack: every text tries
    /// the fallback fonts, in the order added. `font` must outlive the
    /// window.
    pub fn addFallbackFont(self: *Window, font: *const Font) Allocator.Error!void {
        try self.fallback_list.append(self.gpa, font);
        self.fallback_fonts.set(self.fallback_list.items);
    }

    /// The registered font of `family` (empty: the default family) closest
    /// to `weight`, or null if the family is unknown.
    pub fn findFont(self: *const Window, family: []const u8, weight: u16) ?*const Font {
        const wanted = if (family.len == 0) self.default_family else family;
        var best: ?RegisteredFont = null;
        for (self.fonts.items) |f| {
            if (!std.ascii.eqlIgnoreCase(f.family, wanted)) continue;
            if (best == null or @abs(@as(i32, f.weight) - weight) < @abs(@as(i32, best.?.weight) - weight)) best = f;
        }
        return if (best) |b| b.font else null;
    }

    pub fn rootItem(self: *Window) *Item {
        return &self.root.item;
    }

    pub fn size(self: *Window) Size {
        return self.root.item.size();
    }

    pub fn setSize(self: *Window, s: Size) void {
        self.root.item.width.set(s.width);
        self.root.item.height.set(s.height);
    }

    pub fn requestRedraw(self: *Window) void {
        if (self.redraw_requested) return;
        self.redraw_requested = true;
        self.on_redraw_request.call(.{});
    }

    /// Called by `Item.removeFromParent` before `item` leaves the tree.
    pub fn itemRemoved(self: *Window, item: *Item) void {
        if (self.grabber) |g| if (item.contains(g)) {
            self.grabber = null;
        };
        if (self.focus_item) |f| if (item.contains(f)) {
            self.focus_item = null;
            self.focus_generation.set(self.focus_generation.getUntracked() +% 1);
        };
        var kept: usize = 0;
        for (self.hovered[0..self.hovered_len]) |h| {
            if (item.contains(h)) continue;
            self.hovered[kept] = h;
            kept += 1;
        }
        self.hovered_len = kept;
        kept = 0;
        for (self.interceptors[0..self.interceptors_len]) |i| {
            if (item.contains(i)) break; // the rest are descendants of it
            kept += 1;
        }
        self.interceptors_len = kept;

        var it: ?*Item = item;
        while (it) |i| : (it = nextWithin(i, item)) {
            const kv = self.render_cache.fetchRemove(i) orelse continue;
            self.pending_dirty.add(kv.value.state.rect);
            kv.value.tracker.deinit();
            self.gpa.destroy(kv.value);
        }
        self.requestRedraw();
    }

    // ---- Pointer input ----

    /// Dispatches a pointer event in window coordinates. Items are offered
    /// the event topmost first; children of a clipping item only receive
    /// events inside it.
    pub fn dispatchPointer(self: *Window, event: input.PointerEvent) void {
        self.pointer_observed.call(.{event});
        if (event != .exit) self.input_activity.call(.{});
        if (self.edgeDrag(event)) return;
        if (event == .exit) {
            self.updateHover(&.{});
            return;
        }
        if (self.grabber) |g| {
            // A click inside the top popup may close it (not one that a
            // click elsewhere just opened).
            const popup = self.topPopupContaining(g);
            self.dispatchGrabbed(g, event);
            if (event == .released) if (popup) |p| self.closeAfterClick(p);
            return;
        }
        // The topmost popup takes the events; a press outside closes it.
        if (self.topInteractivePopup()) |top_index| {
            const top = self.popups.items[top_index];
            const parent_at = if (top.item.parent) |par| par.absolutePosition() else Point{};
            // In it, or in what it shows past its bounds (a submenu).
            const inside = self.covers(top.item, event.position().?.sub(parent_at));
            if (!inside) {
                if (event == .pressed and top.policy != .no_auto_close) self.closePopupAt(top_index);
                self.updateHover(&.{});
                return;
            }
            var hover: HoverSet = .{};
            var path: Interceptors = .{};
            const parent_pos = if (top.item.parent) |par| par.absolutePosition() else Point{};
            _ = self.dispatchTo(top.item, event.relativeTo(parent_pos), &hover, &path);
            self.updateHover(hover.slice());
            if (event == .released) self.closeAfterClick(top.item);
            return;
        }
        var hover: HoverSet = .{};
        var path: Interceptors = .{};
        _ = self.dispatchTo(&self.root.item, event, &hover, &path);
        self.updateHover(hover.slice());
    }

    const EdgeDrag = struct {
        popup: *items.PopupWindow,
        direction: items.SwipeDirection,
        start: Point,
        /// Taken over from what had the press (it went that way).
        active: bool = false,
        distance: f32 = 0,
        at_ms: u64 = 0,
        speed: f32 = 0,

        /// How far `p` is from the start that way, and across.
        fn along(d: EdgeDrag, p: Point) [2]f32 {
            const dx = p.x - d.start.x;
            const dy = p.y - d.start.y;
            return switch (d.direction) {
                .right => .{ dx, @abs(dy) },
                .left => .{ -dx, @abs(dy) },
                .down => .{ dy, @abs(dx) },
                .up => .{ -dy, @abs(dx) },
            };
        }
    };

    /// How far a drag from an edge goes before it pulls a popup out.
    const edge_drag_threshold = 8;

    /// Pulls closed popups out of the window's edges (`open_swipe`): a
    /// press there goes on as usual, until it moves the popup's way: then
    /// it is the popup's. Whether `event` was taken.
    fn edgeDrag(self: *Window, event: input.PointerEvent) bool {
        switch (event) {
            .pressed => |p| {
                self.edge_drag = null;
                if (p.button != .left or self.topInteractivePopup() != null) return false;
                self.edge_drag = self.edgePopupAt(p.position);
                return false;
            },
            .moved => |m| {
                const d = &(self.edge_drag orelse return false);
                const a = d.along(m.position);
                if (!d.active) {
                    if (a[1] > edge_drag_threshold and a[1] > a[0] or a[0] < -edge_drag_threshold) {
                        self.edge_drag = null;
                        return false;
                    }
                    if (a[0] <= edge_drag_threshold) return false;
                    // Its now: what had the press lets it go.
                    self.cancelPointer();
                    d.active = true;
                    d.at_ms = time.now();
                }
                const now = time.now();
                if (now > d.at_ms) d.speed = (a[0] - d.distance) * 1000 / @as(f32, @floatFromInt(now - d.at_ms));
                d.at_ms = now;
                d.distance = a[0];
                d.popup.edge_dragged.call(.{@max(0, a[0])});
                return true;
            },
            .released => |r| {
                const d = self.edge_drag orelse return false;
                self.edge_drag = null;
                if (!d.active) return false;
                const a = d.along(r.position);
                d.popup.edge_released.call(.{ @max(0, a[0]), d.speed });
                return true;
            },
            else => {
                self.edge_drag = null;
                return false;
            },
        }
    }

    /// A closed popup that a drag from `p` at the window's edge pulls out.
    fn edgePopupAt(self: *Window, p: Point) ?EdgeDrag {
        const window = self.size();
        var it: ?*Item = &self.root.item;
        while (it) |i| : (it = i.nextInTree()) {
            if (i.vtable != &items.PopupWindow.vtable) continue;
            const popup: *items.PopupWindow = @fieldParentPtr("item", i);
            if (popup.is_open.get()) continue;
            const margin = popup.edge_margin.get();
            if (!(margin > 0)) continue;
            const direction = popup.open_swipe.get();
            const near = switch (direction) {
                .right => p.x < margin,
                .left => p.x >= window.width - margin,
                .down => p.y < margin,
                .up => p.y >= window.height - margin,
            };
            if (near) return .{ .popup = popup, .direction = direction, .start = p };
        }
        return null;
    }

    /// Whether `item` or one of its children (shown, not clipped away) is
    /// at `p` (in its parent's coordinates).
    fn covers(self: *Window, item: *Item, p: Point) bool {
        if (!item.visible.get()) return false;
        const g = item.geometry();
        const flat = untilted(item, p) orelse return false;
        var local = flat.sub(g.origin());
        if (item.localTransform()) |m| local = (m.inverse() orelse return false).apply(local);
        if (!self.inShape(item, local)) return false;
        const clips = item.clipsChildren();
        if ((Rect{ .width = g.width, .height = g.height }).contains(local) and
            (!clips or !core_effects or inRounded(local, g.size(), item.clipRadius()))) return true;
        if (clips) return false;
        var children = item.children();
        while (children.next()) |c| if (self.covers(c, local)) return true;
        return false;
    }

    /// Whether `p` (in `item`'s coordinates) is where it and its children
    /// show: inside its `clip-path`, where its `mask-image` is at least
    /// half opaque (or less, inverted). Its own bounds are not checked,
    /// nor a mask drawn by an element.
    fn inShape(self: *Window, item: *Item, p: Point) bool {
        if (!core_effects) return true;
        const shape = item.clipPath();
        const mask = item.maskImage();
        if (shape.len == 0 and mask == null) return true;
        const gpa = self.gpa;
        // Invalid path data shows nothing; without memory, anywhere.
        if (shape.len > 0 and !(path_mod.contains(gpa, shape, .{}, p) catch |e| (e == error.OutOfMemory))) return false;
        if (mask) |m| if (maskCovers(gpa, m.*, item.size(), p) == item.maskInverted()) return false;
        return true;
    }

    /// Whether `img` stretched over `size` is at least half opaque at `p`
    /// (an SVG drawing: inside one of its fills).
    fn maskCovers(gpa: Allocator, img: Image, area: Size, p: Point) bool {
        if (!(area.width > 0 and area.height > 0)) return false;
        if (img.vector) |d| {
            const t = path_mod.Transform.fit(d.viewbox, .{ .width = area.width, .height = area.height });
            for (d.shapes) |shape| {
                const fill = shape.fill orelse continue;
                if (fill == .color and fill.color.a < 128) continue;
                if (path_mod.contains(gpa, shape.commands, t, p) catch |e| (e == error.OutOfMemory)) return true;
            }
            return false;
        }
        if (img.width == 0 or img.height == 0 or img.pixels.len < @as(usize, img.width) * img.height) return false;
        const fx = std.math.clamp(@floor(p.x / area.width * @as(f32, @floatFromInt(img.width))), 0, @as(f32, @floatFromInt(img.width - 1)));
        const fy = std.math.clamp(@floor(p.y / area.height * @as(f32, @floatFromInt(img.height))), 0, @as(f32, @floatFromInt(img.height - 1)));
        return img.pixel(@intFromFloat(fx), @intFromFloat(fy)).a >= 128;
    }

    /// Whether `p`, inside `size`, is inside its corners rounded by
    /// `radius`.
    fn inRounded(p: Point, area: Size, radius: f32) bool {
        const r = @min(radius, area.width / 2, area.height / 2);
        if (!(r > 0)) return true;
        const dx = @max(r - p.x, p.x - (area.width - r), 0);
        const dy = @max(r - p.y, p.y - (area.height - r), 0);
        return dx * dx + dy * dy <= r * r;
    }

    /// `p` (in `item`'s parent's coordinates) on `item`'s drawing laid flat:
    /// itself unless it is tilted in depth; null where it shows nothing.
    fn untilted(item: *Item, p: Point) ?Point {
        if (!core_transforms) return p;
        const h = item.projection() orelse return p;
        return (h.inverse() orelse return null).apply(p);
    }

    /// Sends a grabbed event to the grabber, unless an intercepting ancestor
    /// takes the grab over first.
    fn dispatchGrabbed(self: *Window, grabber: *Item, event: input.PointerEvent) void {
        for (self.interceptors[0..self.interceptors_len], 0..) |anc, i| {
            const filter = anc.vtable.inputEventFilter orelse continue;
            const local = if (event.position()) |p| event.at(anc.fromWindow(p)) else event;
            if (filter(anc, local, self) != .intercept) continue;
            _ = deliver(grabber, .exit, self);
            self.interceptors_len = i;
            self.setGrabber(anc, deliver(anc, local, self));
            return;
        }
        const local = if (event.position()) |p| event.at(grabber.fromWindow(p)) else event;
        self.setGrabber(grabber, deliver(grabber, local, self));
    }

    fn setGrabber(self: *Window, item: *Item, result: input.InputEventResult) void {
        if (result == .grab) {
            self.grabber = item;
        } else {
            self.grabber = null;
            self.interceptors_len = 0;
        }
    }

    const Interceptors = struct {
        items: [max_interceptors]*Item = undefined,
        len: usize = 0,
    };

    const HoverSet = struct {
        items: [max_hovered]*Item = undefined,
        len: usize = 0,

        fn add(h: *HoverSet, item: *Item) void {
            if (h.len == max_hovered) return;
            h.items[h.len] = item;
            h.len += 1;
        }

        fn slice(h: *const HoverSet) []const *Item {
            return h.items[0..h.len];
        }
    };

    /// Ends the pointer's press without a release (a pinch took the finger
    /// over): what had it is told the pointer left.
    pub fn cancelPointer(self: *Window) void {
        if (self.grabber) |g| _ = deliver(g, .exit, self);
        self.grabber = null;
        self.interceptors_len = 0;
        self.updateHover(&.{});
    }

    fn deliver(item: *Item, event: input.PointerEvent, self: *Window) input.InputEventResult {
        const f = item.vtable.inputEvent orelse return .ignored;
        return f(item, event, self);
    }

    /// `event` is in the coordinates of `item`'s parent. `path` holds the
    /// intercepting ancestors of `item`.
    fn dispatchTo(self: *Window, item: *Item, event: input.PointerEvent, hover: *HoverSet, path: *Interceptors) bool {
        // Disabled: neither it nor its children; what is below gets it.
        if (!item.visible.get() or !item.enabled.get()) return false;
        const g = item.geometry();
        // Tilted in depth: where the point is on its flat drawing.
        const flat = if (event.position()) |p| event.at(untilted(item, p) orelse return false) else event;
        var local = flat.relativeTo(g.origin());
        // Rotated or scaled: the point in its own coordinates.
        if (item.localTransform()) |m| local = local.at((m.inverse() orelse return false).apply(local.position().?));
        const at = local.position().?;
        // Outside its clip path or mask: neither it nor its children.
        if (!self.inShape(item, at)) return false;
        const clips = item.clipsChildren();
        const inside = (Rect{ .width = g.width, .height = g.height }).contains(at) and
            (!clips or !core_effects or inRounded(at, g.size(), item.clipRadius()));
        if (!inside and clips) return false;

        const filter: input.InputEventFilterResult = if (!inside)
            .forward_and_ignore
        else if (item.vtable.inputEventFilter) |f| f(item, local, self) else .forward;

        if (filter != .intercept) {
            const pushed = filter == .forward_and_intercept_grab and path.len < max_interceptors;
            if (pushed) {
                path.items[path.len] = item;
                path.len += 1;
            }
            var children = item.childrenReversed();
            while (children.next()) |c| {
                // Popups get events only while open, from `dispatchPointer`.
                if (c.vtable.is_popup) continue;
                if (self.dispatchTo(c, local, hover, path)) return true;
            }
            if (pushed) path.len -= 1;
            if (filter == .forward_and_ignore) return false;
        }

        if (item.vtable.inputEvent == null) return false;
        if (item.vtable.is_popup) return false;
        hover.add(item);
        switch (deliver(item, local, self)) {
            .ignored => return false,
            .accepted => return true,
            .grab => {
                self.grabber = item;
                @memcpy(self.interceptors[0..path.len], path.items[0..path.len]);
                self.interceptors_len = path.len;
                return true;
            },
        }
    }

    /// What the app asks of the system window (read without depending on
    /// it: backends ask each frame).
    pub fn windowState(self: *Window) WindowState {
        return .{
            .fullscreen = self.fullscreen.getUntracked(),
            .maximized = self.maximized.getUntracked(),
            .minimized = self.minimized.getUntracked(),
            .always_on_top = self.always_on_top.getUntracked(),
        };
    }

    pub fn setWindowState(self: *Window, s: WindowState) void {
        self.fullscreen.set(s.fullscreen);
        self.maximized.set(s.maximized);
        self.minimized.set(s.minimized);
        self.always_on_top.set(s.always_on_top);
    }

    /// Light or dark: `color_scheme`, or with `.auto`, from the brightness
    /// of the window's background (so a dark theme gets a dark title bar).
    pub fn colorScheme(self: *Window) ColorScheme {
        const scheme = self.color_scheme.get();
        if (scheme != .auto) return scheme;
        return if (brightness(self.root.background.get()) < 0.5) .dark else .light;
    }

    /// Perceived brightness in [0, 1] (transparent counts as light: the
    /// system shows through).
    fn brightness(brush: Brush) f32 {
        const Avg = struct {
            fn of(c: graphics.Color) f32 {
                const b = (0.2126 * @as(f32, @floatFromInt(c.r)) + 0.7152 * @as(f32, @floatFromInt(c.g)) + 0.0722 * @as(f32, @floatFromInt(c.b))) / 255;
                const a = @as(f32, @floatFromInt(c.a)) / 255;
                return b * a + (1 - a);
            }
        };
        return switch (brush) {
            .solid => |c| Avg.of(c),
            inline .linear_gradient, .radial_gradient => |g| blk: {
                const stops = g.stops.slice();
                if (stops.len == 0) break :blk 1;
                var sum: f32 = 0;
                for (stops) |stop| sum += Avg.of(stop.color);
                break :blk sum / @as(f32, @floatFromInt(stops.len));
            },
        };
    }

    /// The pointer's shape: that of the item holding the pointer (while
    /// dragging), else of the innermost item under it that sets one. The
    /// backend shows it after dispatching events.
    pub fn mouseCursor(self: *Window) input.MouseCursor {
        if (self.grabber) |g| return cursorOf(g);
        for (self.hovered[0..self.hovered_len]) |h| {
            const cursor = cursorOf(h);
            if (cursor != .default) return cursor;
        }
        return .default;
    }

    fn cursorOf(item: *Item) input.MouseCursor {
        return if (item.vtable.mouseCursor) |f| f(item) else .default;
    }

    fn updateHover(self: *Window, new: []const *Item) void {
        for (self.hovered[0..self.hovered_len]) |old| {
            if (std.mem.indexOfScalar(*Item, new, old) == null) _ = deliver(old, .exit, self);
        }
        @memcpy(self.hovered[0..new.len], new);
        self.hovered_len = new.len;
    }

    // ---- Keyboard and focus ----

    /// Sends a key event to the focused item, bubbling up through its
    /// ancestors until one accepts it. Unhandled Tab / Shift+Tab move focus.
    pub fn dispatchKey(self: *Window, kind: input.KeyEventKind, event: input.KeyEvent) void {
        self.input_activity.call(.{});
        // Escape cancels a drag first.
        if (kind == .pressed and std.mem.eql(u8, event.text, input.Key.escape)) if (self.active_drag) |d| {
            self.active_drag = null;
            if (self.cancel_drag) |cancel| cancel(d);
            return;
        };
        var it = self.focus_item;
        while (it) |item| : (it = item.parent) {
            const f = item.vtable.keyEvent orelse continue;
            if (f(item, kind, event, self) == .accept) return;
        }
        if (kind != .pressed) return;
        if (std.mem.eql(u8, event.text, input.Key.escape)) if (self.topInteractivePopup()) |i| {
            self.closePopupAt(i);
            return;
        };
        // Not taken by the focused element: the application's shortcuts.
        if (@import("shortcuts.zig").handle(event)) return;
        if (std.mem.eql(u8, event.text, input.Key.tab)) {
            if (event.modifiers.shift) self.focusPrevious() else self.focusNext();
        } else if (std.mem.eql(u8, event.text, input.Key.back_tab)) {
            self.focusPrevious();
        }
    }

    /// Sends the input method's composition (pre-edit) text to the focused
    /// item; `cursor` is a byte offset in it. Empty text ends composing.
    pub fn dispatchPreedit(self: *Window, text: []const u8, cursor: usize) void {
        const item = self.focus_item orelse return;
        if (item.vtable.preeditEvent) |f| f(item, text, @min(cursor, text.len), self);
    }

    /// Copies `text` to the clipboard.
    pub fn setClipboardText(self: *Window, text: []const u8) void {
        if (self.clipboard) |c| return c.setFn(c.ctx, text);
        self.local_clipboard.clearRetainingCapacity();
        self.local_clipboard.appendSlice(self.gpa, text) catch {};
    }

    /// The clipboard's text, owned by the caller (allocated with `gpa`).
    pub fn clipboardText(self: *Window, gpa: Allocator) ?[]u8 {
        if (self.clipboard) |c| return c.getFn(c.ctx, gpa);
        return gpa.dupe(u8, self.local_clipboard.items) catch null;
    }

    pub fn setImeCursorRect(self: *Window, rect: ?Rect) void {
        if (std.meta.eql(self.ime_cursor_rect, rect)) return;
        self.ime_cursor_rect = rect;
        self.ime_cursor_rect_changed = true;
    }

    // ---- Popups ----

    /// Shows `item` above everything else (it stays where the tree puts
    /// it). `on_close` is called if the window closes it.
    /// Opens `item` as a popup above everything; a `transparent` one lets
    /// input through (a tooltip).
    pub fn openPopup(self: *Window, item: *Item, policy: PopupClosePolicy, on_close: ?*const fn (*Item) void, transparent: bool) void {
        self.forgetPopup(item);
        self.popups.append(self.gpa, .{ .item = item, .policy = policy, .on_close = on_close, .transparent = transparent }) catch return;
        self.requestRedraw();
    }

    /// The index of the topmost popup that takes input.
    fn topInteractivePopup(self: *const Window) ?usize {
        var i = self.popups.items.len;
        while (i > 0) {
            i -= 1;
            if (!self.popups.items[i].transparent) return i;
        }
        return null;
    }

    /// Removes `item` from the open popups (it closed itself).
    pub fn forgetPopup(self: *Window, item: *Item) void {
        for (self.popups.items, 0..) |p, i| if (p.item == item) {
            _ = self.popups.orderedRemove(i);
            if (self.grabber) |g| if (isInside(g, item)) {
                self.grabber = null;
                self.interceptors_len = 0;
            };
            self.requestRedraw();
            return;
        };
    }

    fn isInside(item: *Item, ancestor: *Item) bool {
        var it: ?*Item = item;
        while (it) |i| : (it = i.parent) if (i == ancestor) return true;
        return false;
    }

    fn closePopupAt(self: *Window, index: usize) void {
        const p = self.popups.orderedRemove(index);
        if (p.on_close) |f| f(p.item);
        self.requestRedraw();
    }

    /// The top popup, if `item` is inside it.
    fn topPopupContaining(self: *Window, item: *Item) ?*Item {
        const top = self.popups.items[self.topInteractivePopup() orelse return null].item;
        return if (isInside(item, top)) top else null;
    }

    /// A `close_on_click` popup closes once a click inside it is handled.
    fn closeAfterClick(self: *Window, popup: *Item) void {
        if (self.grabber != null) return;
        for (self.popups.items, 0..) |p, i| if (p.item == popup) {
            if (p.policy == .close_on_click) self.closePopupAt(i);
            return;
        };
    }

    pub fn setFocusItem(self: *Window, item: ?*Item) void {
        if (self.focus_item == item) return;
        if (self.focus_item) |old| {
            self.focus_item = null;
            if (old.vtable.focusEvent) |f| f(old, .focus_out, self);
        }
        self.focus_item = item;
        self.focus_generation.set(self.focus_generation.getUntracked() +% 1);
        if (item) |new| if (new.vtable.focusEvent) |f| f(new, .focus_in, self);
    }

    /// Moves focus to the next focusable item in tree order, wrapping.
    pub fn focusNext(self: *Window) void {
        // Within the top popup, if one is open (a dialog keeps the focus).
        const scope = self.focusScope();
        const stop = if (self.focus_item) |f| (if (isInside(f, scope)) f else scope) else scope;
        var it = stop;
        while (true) {
            it = it.nextInTree() orelse scope;
            if (!isInside(it, scope)) it = scope;
            if (it.acceptsFocus() and it.isVisibleInTree()) return self.setFocusItem(it);
            if (it == stop) return;
        }
    }

    /// Where Tab moves the focus: the top popup taking input, or the
    /// whole window.
    fn focusScope(self: *Window) *Item {
        return if (self.topInteractivePopup()) |i| self.popups.items[i].item else &self.root.item;
    }

    /// Moves focus to the previous focusable item in tree order, wrapping.
    pub fn focusPrevious(self: *Window) void {
        const scope = self.focusScope();
        const stop = if (self.focus_item) |f| (if (isInside(f, scope)) f else scope) else scope;
        var it = stop;
        while (true) {
            it = it.previousInTree() orelse lastInTree(scope);
            if (!isInside(it, scope)) it = lastInTree(scope);
            if (it.acceptsFocus() and it.isVisibleInTree()) return self.setFocusItem(it);
            if (it == stop) return;
        }
    }

    // ---- Rendering ----

    /// Renders what changed since the last call (or everything, in `.full`
    /// mode) and returns the region that was redrawn, in window pixels. Each
    /// item's visual dependencies are tracked, so the next call knows which
    /// items changed.
    pub fn render(self: *Window, renderer: ItemRenderer, mode: RenderMode) Allocator.Error!Region {
        return self.renderAt(renderer, mode, 1);
    }

    /// `render` for a renderer drawing `scale` physical pixels per window
    /// pixel: the redrawn region covers whole physical pixels (at 1.5, a
    /// window pixel's edge may cut one in half; the items around that half
    /// are drawn too).
    pub fn renderAt(self: *Window, renderer: ItemRenderer, mode: RenderMode, scale: f32) Allocator.Error!Region {
        if (scale > 0 and self.pixel_ratio.getUntracked() != scale) self.pixel_ratio.set(scale);
        var dirty = self.pending_dirty;
        try self.updateRenderCache(&dirty);
        self.pending_dirty.clear();

        const bounds: Rect = .fromOriginSize(.{}, self.size());
        if (mode == .full) {
            dirty.clear();
            dirty.add(bounds);
        }
        var region: Region = .{};
        for (dirty.slice()) |r| region.add(wholePixels(r.intersection(bounds), scale).intersection(bounds));

        for (region.slice()) |r| {
            renderer.save();
            if (renderer.clip(r)) {
                renderItem(&self.root.item, renderer);
                // Open popups, above everything.
                for (self.popups.items) |p| {
                    renderer.save();
                    if (p.item.parent) |parent| renderer.translate(parent.absolutePosition());
                    renderPopup(p.item, renderer);
                    renderer.restore();
                }
            }
            renderer.restore();
        }
        self.redraw_requested = false;
        // Native views over the window follow their elements.
        @import("webview.zig").syncWindow(self);
        return region;
    }

    /// Re-evaluates the trackers of changed (and new) items, adding their
    /// old and new bounds to `dirty`.
    fn updateRenderCache(self: *Window, dirty: *Region) Allocator.Error!void {
        var it: ?*Item = &self.root.item;
        while (it) |item| : (it = item.nextInTree()) {
            const gop = try self.render_cache.getOrPut(self.gpa, item);
            if (!gop.found_existing) {
                const entry = self.gpa.create(CacheEntry) catch |err| {
                    _ = self.render_cache.remove(item);
                    return err;
                };
                entry.* = .{ .tracker = .init(self.gpa) };
                entry.tracker.setDirtyListener(self, requestRedraw);
                gop.value_ptr.* = entry;
            } else if (!gop.value_ptr.*.tracker.isDirty()) continue;

            const entry = gop.value_ptr.*;
            const old = entry.state;
            // Parents come first: their positions are up to date.
            const parent_state: VisualState = if (item.parent) |p| self.render_cache.get(p).?.state else .{};
            entry.state = entry.tracker.evaluate(TrackCtx{ .item = item, .parent_matrix = parent_state.matrix, .parent_spread = parent_state.spread, .parent_projection = parent_state.projection }, trackedState);
            if (gop.found_existing and std.meta.eql(old, entry.state)) continue;
            // Moved, or blurred differently: so are the children (their
            // trackers did not see it).
            if (gop.found_existing and (!std.meta.eql(old.matrix, entry.state.matrix) or old.spread != entry.state.spread or !std.meta.eql(old.projection, entry.state.projection))) {
                var d = nextWithin(item, item);
                while (d) |i| : (d = nextWithin(i, item)) {
                    if (self.render_cache.get(i)) |e| e.tracker.dirty = true;
                }
            }
            dirty.add(old.rect);
            dirty.add(entry.state.rect);
            // Visibility, opacity or clipping changes repaint the children
            // too, wherever they are. (Their own bounds did not change.)
            if (gop.found_existing and old.affectsChildrenDifferently(entry.state)) {
                var d = nextWithin(item, item);
                while (d) |i| : (d = nextWithin(i, item)) {
                    if (self.render_cache.get(i)) |e| dirty.add(e.state.rect);
                }
            }
        }
    }

    const TrackCtx = struct { item: *Item, parent_matrix: Affine, parent_spread: f32 = 0, parent_projection: ?Projective = null };

    /// Reads everything that affects how `item` looks (but not its
    /// ancestors' positions: those come with `parent_origin`).
    fn trackedState(ctx: TrackCtx) VisualState {
        const item = ctx.item;
        var hasher: rendering.HashingRenderer = .{};
        if (item.vtable.render) |f| f(item, hasher.renderer());
        const clips = item.clipsChildren();
        var matrix = ctx.parent_matrix.mul(Affine.translation(.{ .x = item.x.get(), .y = item.y.get() }));
        if (item.localTransform()) |l| matrix = matrix.mul(l);
        // Rotated: its bounding box (and a pixel for the smoothed edges).
        // With what it draws outside its bounds (a shadow).
        const size_rect = Rect.fromOriginSize(.{}, item.size());
        const turned = !matrix.isTranslation();
        // Blurred: what it and its children draw spreads three deviations
        // further (in window pixels: scaled as it is).
        const blur = item.blurRadius();
        const spread = ctx.parent_spread + 3 * blur * @sqrt(@abs(matrix.a * matrix.d - matrix.b * matrix.c));
        // Tilted in depth (it or an ancestor): its flat drawing mapped.
        var projection = ctx.parent_projection;
        if (core_transforms) if (item.projection()) |h| {
            const own = h.conjugate(ctx.parent_matrix);
            projection = if (projection) |p| p.mul(own) else own;
        };
        var bounds = rendering.grow(boxOf(matrix, size_rect.unionWith(hasher.overflow), turned), spread).roundOut();
        var clip_box = if (hasher.overflow.isEmpty() and spread == 0) bounds else boxOf(matrix, size_rect, turned);
        // Only text: where its lines are (a short label in a wide item
        // repaints the label, not the item).
        if (hasher.textOnly()) |ink| bounds = if (ink.isEmpty()) .empty else rendering.grow(boxOf(matrix, ink, turned), spread).roundOut();
        if (core_transforms) if (projection) |p| {
            bounds = projected(p, bounds);
            clip_box = projected(p, clip_box);
        };
        return .{
            .matrix = matrix,
            .spread = spread,
            .projection = projection,
            .layer = isLayer(item),
            .rect = if (hasher.calls > 0) bounds else .empty,
            .content = hasher.final(),
            .visible = item.visible.get(),
            .opacity = item.opacity.get(),
            .clips = clips,
            .clip_rect = if (clips) clip_box else .empty,
            .shape = if (core_effects) shapeHash(item) else 0,
        };
    }

    /// Where `r` shows mapped by `p` (and a pixel for the smoothed edges);
    /// everywhere if part of it would be behind the viewer.
    fn projected(p: Projective, r: Rect) Rect {
        if (r.isEmpty()) return r;
        const box = p.mapRect(r) orelse return .{ .x = -1e6, .y = -1e6, .width = 2e6, .height = 2e6 };
        return rendering.grow(box, 1).roundOut();
    }

    fn shapeHash(item: *Item) u64 {
        const path = item.clipPath();
        const mask = item.maskImage();
        const source = item.maskSource();
        const radius = if (item.clipsChildren()) item.clipRadius() else 0;
        if (path.len == 0 and mask == null and source == null and radius == 0) return 0;
        var h: std.hash.Wyhash = .init(1);
        h.update(path);
        if (mask) |m| h.update(std.mem.asBytes(&.{ @intFromPtr(m.pixels.ptr), @intFromPtr(m.vector), m.version, m.width, m.height }));
        h.update(std.mem.asBytes(&radius));
        h.update(&.{@intFromBool(item.maskInverted())});
        // What the mask element draws (read here: a change to it redraws
        // what it masks).
        if (source) |s| {
            var drawn: rendering.HashingRenderer = .{};
            renderMask(item, s, drawn.renderer());
            h.update(std.mem.asBytes(&drawn.final()));
        }
        return h.final();
    }

    fn boxOf(matrix: Affine, r: Rect, turned: bool) Rect {
        var box = matrix.mapRect(r);
        if (turned) box = .{ .x = box.x - 1, .y = box.y - 1, .width = box.width + 2, .height = box.height + 2 };
        return box.roundOut();
    }

    fn renderItem(item: *Item, r: ItemRenderer) void {
        if (item.vtable.is_popup) return;
        renderContent(item, r);
    }

    fn renderPopup(item: *Item, r: ItemRenderer) void {
        renderContent(item, r);
    }

    /// Whether `item` is drawn as a layer: blurred, or faded with its
    /// children as one.
    fn isLayer(item: *Item) bool {
        if (!core_effects) return false;
        return item.blurRadius() > 0 or (item.opacity.get() < 1 and item.first_child != null);
    }

    /// How deep masks drawn by elements may nest (one masked by an
    /// element itself masked by an element...).
    const max_mask_depth = 8;
    threadlocal var mask_depth: u8 = 0;

    /// Draws `source`, masking `item`, as if it were `item`'s child (even
    /// when not visible): not if it contains `item` (it would draw itself),
    /// nor nested too deep.
    fn renderMask(item: *Item, source: *Item, r: ItemRenderer) void {
        if (source.contains(item) or mask_depth >= max_mask_depth) return;
        mask_depth += 1;
        defer mask_depth -= 1;
        renderShown(source, r, true);
    }

    /// How a kept item's flat drawing shows (in its parent's
    /// coordinates): turned around `origin`, where it is, or as it is.
    fn keptMapping(item: *Item, origin: Point) Projective {
        const m = item.localTransform() orelse return .identity;
        return .fromAffine(Affine.translation(origin).mul(m).mul(Affine.translation(.{ .x = -origin.x, .y = -origin.y })));
    }

    fn renderContent(item: *Item, r: ItemRenderer) void {
        renderShown(item, r, false);
    }

    /// `renderContent`, of an item shown even if not visible (a mask).
    fn renderShown(item: *Item, r: ItemRenderer, shown: bool) void {
        if (!shown and !item.visible.get()) return;
        const opacity = item.opacity.get();
        if (opacity <= 0) return;
        const g = item.geometry();
        r.save();
        defer r.restore();
        // Tilted in depth: drawn flat into a layer, which is mapped (in
        // the parent's coordinates). Kept as an image: the same, turned
        // as it is (the image kept as it turns).
        const tilt = if (core_effects and core_transforms) item.projection() else null;
        const kept = core_effects and tilt == null and item.prefersRenderingCache();
        const mapping: ?Projective = tilt orelse if (kept) keptMapping(item, g.origin()) else null;
        if (mapping) |h| r.beginLayer(opacity, item.blurRadius(), h);
        defer if (mapping != null) r.endLayer();
        r.translate(g.origin());
        if (!kept) if (item.localTransform()) |m| r.transform(m);
        const layer = mapping == null and isLayer(item);
        if (layer) {
            r.beginLayer(opacity, item.blurRadius(), null);
        } else if (mapping == null and opacity < 1) r.applyOpacity(opacity);
        defer if (layer) r.endLayer();
        // Shown only inside its clip path and where its mask image is
        // opaque (it and its children).
        const shape = if (core_effects) item.clipPath() else "";
        const mask = if (core_effects) item.maskImage() else null;
        const source = if (core_effects) item.maskSource() else null;
        const masked = shape.len > 0 or mask != null or source != null;
        if (masked) {
            r.save();
            if (shape.len > 0) r.clipPath(g.size(), shape);
            const inverted = item.maskInverted();
            if (mask) |m| r.maskImage(g.size(), m, inverted);
            if (source) |s| {
                r.beginMaskShape(g.size(), inverted, false);
                renderMask(item, s, r);
                r.endMaskShape();
            }
        }
        defer if (masked) r.restore();
        if (item.vtable.render) |f| f(item, r);
        if (item.clipsChildren()) {
            const box: Rect = .{ .width = g.width, .height = g.height };
            const radius = if (core_effects) item.clipRadius() else 0;
            if (!(if (radius > 0) r.clipRounded(box, radius) else r.clip(box))) return;
        }
        var children = item.children();
        while (children.next()) |c| renderItem(c, r);
    }
};

/// Pre-order successor of `item` that stays inside the subtree of `scope`.
fn nextWithin(item: *Item, scope: *Item) ?*Item {
    if (item.first_child) |c| return c;
    var it = item;
    while (it != scope) : (it = it.parent.?) {
        if (it.next_sibling) |n| return n;
    }
    return null;
}

/// `r` grown to whole pixels at `scale` physical pixels per window pixel
/// (in window pixels).
fn wholePixels(r: Rect, scale: f32) Rect {
    if (r.isEmpty()) return r;
    if (scale == 1) return r.roundOut();
    const x0 = @floor(r.x * scale);
    const y0 = @floor(r.y * scale);
    const x1 = @ceil(r.right() * scale);
    const y1 = @ceil(r.bottom() * scale);
    return .{ .x = x0 / scale, .y = y0 / scale, .width = (x1 - x0) / scale, .height = (y1 - y0) / scale };
}

fn lastInTree(root: *Item) *Item {
    var it = root;
    while (it.last_child) |c| it = c;
    return it;
}

test "the color scheme follows the background, unless set" {
    var w: Window = undefined;
    w.init(std.testing.allocator, .{ .width = 10, .height = 10 });
    defer w.deinit();
    try std.testing.expectEqual(ColorScheme.light, w.colorScheme()); // white
    w.root.background.set(.color(.rgb(0x202020)));
    try std.testing.expectEqual(ColorScheme.dark, w.colorScheme());
    w.root.background.set(.linear(90, &.{ .{ .color = .rgb(0x000000), .position = 0 }, .{ .color = .rgb(0x303030), .position = 1 } }));
    try std.testing.expectEqual(ColorScheme.dark, w.colorScheme());
    w.root.background.set(.transparent);
    try std.testing.expectEqual(ColorScheme.light, w.colorScheme());
    w.color_scheme.set(.dark);
    try std.testing.expectEqual(ColorScheme.dark, w.colorScheme());
}

test "window state: asked by the app, reported by the system" {
    var w: Window = undefined;
    w.init(std.testing.allocator, .{ .width = 10, .height = 10 });
    defer w.deinit();
    var sync: WindowStateSync = .{};
    // Asked before the window opens; what it reports as it opens does not
    // undo that.
    w.fullscreen.set(true);
    sync.report(&w, .{});
    try std.testing.expect(w.fullscreen.get());
    try std.testing.expect(sync.sync(&w).?.fullscreen);
    w.fullscreen.set(false);
    _ = sync.sync(&w);
    try std.testing.expect(sync.sync(&w) == null);
    // The app asks: the backend gets it once.
    w.maximized.set(true);
    w.always_on_top.set(true);
    const want = sync.sync(&w).?;
    try std.testing.expect(want.maximized and want.always_on_top and !want.fullscreen);
    try std.testing.expect(sync.sync(&w) == null);
    // The user restores it from the title bar: the app sees it, and
    // nothing is asked of the backend again.
    sync.report(&w, .{ .always_on_top = true });
    try std.testing.expect(!w.maximized.get());
    try std.testing.expect(sync.sync(&w) == null);
}
