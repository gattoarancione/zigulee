// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Built-in items: the elements every `.zge` file builds on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const ChangeTracker = @import("properties.zig").ChangeTracker;
const Callback = @import("callbacks.zig").Callback;
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Rect = geometry.Rect;
const Brush = @import("graphics.zig").Brush;
const Color = @import("graphics.zig").Color;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const ItemVTable = item_mod.ItemVTable;
const layout = @import("layout.zig");
const LayoutInfo = layout.LayoutInfo;
const Orientation = layout.Orientation;
const Segment = layout.Segment;
const input = @import("input.zig");
const rendering = @import("rendering.zig");
const path_mod = @import("path.zig");
const ItemRenderer = rendering.ItemRenderer;
const TextMeasurer = rendering.TextMeasurer;
const Window = @import("window.zig").Window;
const time = @import("time.zig");
const image = @import("image.zig");
const image_loader = @import("image_loader.zig");
const model_mod = @import("model.zig");
const text_mod = @import("text/text.zig");
const Font = text_mod.Font;
const Size = geometry.Size;

const log = std.log.scoped(.zigulee);

fn parentOf(comptime T: type, i: *Item) *T {
    return @alignCast(@fieldParentPtr("item", i));
}

/// A container with no visuals of its own.
pub const Empty = struct {
    item: Item = .init(&vtable),

    pub fn deinit(self: *Empty) void {
        self.item.deinit();
    }

    const vtable: ItemVTable = .{ .name = "Empty" };
};

/// A Rectangle's shadow (`drop-shadow-*`): its shape, offset and blurred,
/// drawn under it. Kept apart: only rectangles with a shadow have one.
pub const DropShadow = struct {
    offset_x: Property(f32) = .init(0),
    offset_y: Property(f32) = .init(0),
    /// As CSS's blur radius: the shadow fades over about this far on
    /// both sides of its edge.
    blur: Property(f32) = .init(0),
    color: Property(Color) = .init(.transparent),

    pub fn deinit(self: *DropShadow) void {
        self.offset_x.deinit();
        self.offset_y.deinit();
        self.blur.deinit();
        self.color.deinit();
    }
};

pub const Rectangle = struct {
    item: Item = .init(&vtable),
    background: Property(Brush) = .init(.transparent),
    border_color: Property(Brush) = .init(.transparent),
    border_width: Property(f32) = .init(0),
    border_radius: Property(f32) = .init(0),
    /// Clip children (and their input) to this rectangle, its corners
    /// rounded by `border_radius` (square without effects).
    clip: Property(bool) = .init(false),
    shadow: ?*DropShadow = null,

    pub fn deinit(self: *Rectangle) void {
        self.item.deinit();
        self.background.deinit();
        self.border_color.deinit();
        self.border_width.deinit();
        self.border_radius.deinit();
        self.clip.deinit();
    }

    const vtable: ItemVTable = .{ .name = "Rectangle", .render = render, .clipsChildren = clipsChildren, .clipRadius = clipRadius };

    fn render(i: *Item, r: ItemRenderer) void {
        const self = parentOf(Rectangle, i);
        const style: rendering.RectangleStyle = .{
            .background = self.background.get(),
            .border_color = self.border_color.get(),
            .border_width = self.border_width.get(),
            .border_radius = self.border_radius.get(),
        };
        const size = i.size();
        if (self.shadow) |d| {
            const color = d.color.get();
            if (!color.isTransparent() and size.width > 0 and size.height > 0) r.drawShadow(
                .{ .x = d.offset_x.get(), .y = d.offset_y.get(), .width = size.width, .height = size.height },
                .{ .color = color, .blur = d.blur.get(), .border_radius = style.border_radius },
            );
        }
        const has_border = style.border_width > 0 and !style.border_color.isTransparent();
        if (style.background.isTransparent() and !has_border) return;
        r.drawRectangle(size, style);
    }

    fn clipsChildren(i: *Item) bool {
        return parentOf(Rectangle, i).clip.get();
    }

    fn clipRadius(i: *Item) f32 {
        return parentOf(Rectangle, i).border_radius.get();
    }
};

/// The font for text: an explicit font, else a registered font matching
/// family and weight, else the window's default font.
/// The window's fallback fonts, for text of `item`.
pub fn fallbackFonts(item: *Item) []const *const Font {
    const w = item.window() orelse return &.{};
    return w.fallback_fonts.get();
}

pub fn resolveFont(item: *Item, font: ?*const Font, family: []const u8, weight: i32) ?*const Font {
    if (font) |f| return f;
    const w = item.window() orelse return null;
    if (family.len > 0 or weight != 400) {
        if (w.findFont(family, @intCast(std.math.clamp(weight, 1, 1000)))) |f| return f;
    }
    return w.default_font.get();
}

/// Whether Text has `letter_spacing`, and Text and StyledText fit their
/// font size to their box (`font_size_mode`). An app can leave them out (their code, and three
/// properties a Text, for microcontrollers) by declaring in its root file
/// `pub const zigulee_options = .{ .text_fitting = false };`.
pub const text_fitting = blk: {
    const root = @import("root");
    if (@hasDecl(root, "zigulee_options") and @hasField(@TypeOf(root.zigulee_options), "text_fitting"))
        break :blk root.zigulee_options.text_fitting;
    break :blk true;
};

/// A Text (or StyledText) property left out without `text_fitting`.
pub fn Fitting(comptime T: type) type {
    return if (text_fitting) Property(T) else void;
}

pub const Text = struct {
    item: Item = .init(&vtable),
    text: Property([]const u8) = .init(""),
    /// Null: found by family and weight, else the window's default font.
    font: Property(?*const Font) = .init(null),
    /// A family registered with `Window.registerFont` (empty: default).
    font_family: Property([]const u8) = .init(""),
    font_weight: Property(i32) = .init(400),
    color: Property(Brush) = .init(.color(.black)),
    font_size: Property(f32) = .init(14),
    horizontal_alignment: Property(rendering.TextHorizontalAlignment) = .init(.left),
    vertical_alignment: Property(rendering.TextVerticalAlignment) = .init(.top),
    wrap: Property(rendering.TextWrap) = .init(.no_wrap),
    /// Lines too long for the item: cut, or shortened with "…".
    overflow: Property(rendering.TextOverflow) = .init(.clip),
    /// Pixels added after each character (negative: closer together).
    letter_spacing: Fitting(f32) = if (text_fitting) .init(0) else {},
    /// Smaller than `font_size` when the text would not fit the item.
    font_size_mode: Fitting(rendering.FontSizeMode) = if (text_fitting) .init(.fixed) else {},
    /// How small fitting may make it.
    minimum_font_size: Fitting(f32) = if (text_fitting) .init(12) else {},

    pub fn deinit(self: *Text) void {
        self.item.deinit();
        self.overflow.deinit();
        if (text_fitting) {
            self.letter_spacing.deinit();
            self.font_size_mode.deinit();
            self.minimum_font_size.deinit();
        }
        self.text.deinit();
        self.font.deinit();
        self.font_family.deinit();
        self.font_weight.deinit();
        self.color.deinit();
        self.font_size.deinit();
        self.horizontal_alignment.deinit();
        self.vertical_alignment.deinit();
        self.wrap.deinit();
    }

    const vtable: ItemVTable = .{
        .name = "Text",
        .render = render,
        .layoutInfo = layoutInfo,
        .accessible_role = .text,
        .accessibleLabel = accessibleLabel,
    };

    fn accessibleLabel(i: *Item) []const u8 {
        return parentOf(Text, i).text.get();
    }

    fn resolvedFont(self: *Text) ?*const Font {
        return resolveFont(&self.item, self.font.get(), self.font_family.get(), self.font_weight.get());
    }

    fn measurer(self: *Text) TextMeasurer {
        if (self.resolvedFont()) |f| return .fromFont(f);
        return if (self.item.window()) |w| w.text_measurer else .approximate;
    }

    fn spacing(self: *Text) f32 {
        return if (text_fitting) self.letter_spacing.get() else 0;
    }

    fn mode(self: *Text) rendering.FontSizeMode {
        return if (text_fitting) self.font_size_mode.get() else .fixed;
    }

    fn measure(self: *Text, text: []const u8, font_size: f32, max_width: ?f32) Size {
        if (self.resolvedFont()) |f| return text_mod.layout.measureMetrics(text_mod.layout.Metrics.initFallbacks(f, fallbackFonts(&self.item), font_size).withSpacing(self.spacing()), text, max_width);
        return self.measurer().measure(text, font_size, max_width);
    }

    fn layoutInfo(i: *Item, orientation: Orientation) LayoutInfo {
        const self = parentOf(Text, i);
        const text = self.text.get();
        const font_size = self.font_size.get();
        const wraps = self.wrap.get() == .word_wrap;
        const fit_mode = self.mode();
        // Fitted text can shrink down to its smallest size.
        const smallest = if (text_fitting) @min(font_size, self.minimum_font_size.get()) else font_size;
        switch (orientation) {
            .horizontal => {
                const s = self.measure(text, font_size, null);
                const narrowest = if (fit_mode == .horizontal_fit or fit_mode == .fit) self.measure(text, smallest, null).width else s.width;
                // Elided text can shrink down to its ellipsis.
                const min = if (wraps) 0 else if (self.overflow.get() == .elide) @min(narrowest, self.ellipsisWidth()) else narrowest;
                return .{ .min = min, .preferred = s.width, .stretch = 1 };
            },
            .vertical => {
                // Wrapped text is as tall as it needs to be at its width.
                const width: ?f32 = if (wraps) i.width.get() else null;
                const s = self.measure(text, font_size, width);
                const min = if (fit_mode == .vertical_fit or fit_mode == .fit) self.measure(text, smallest, width).height else s.height;
                return .{ .min = min, .preferred = s.height, .stretch = 0 };
            },
        }
    }

    fn ellipsisWidth(self: *Text) f32 {
        const m = text_mod.layout.Metrics.initFallbacks(self.resolvedFont(), fallbackFonts(&self.item), self.font_size.get()).withSpacing(self.spacing());
        return text_mod.layout.ellipsis(m).width();
    }

    /// The size it is shown at: `font_size`, or with a `font_size_mode`,
    /// the largest (in half pixels, down to `minimum_font_size`) whose text
    /// fits the item.
    pub fn fittedFontSize(self: *Text) f32 {
        const size = self.font_size.get();
        const fit_mode = self.mode();
        if (!text_fitting or fit_mode == .fixed or self.fits(size, fit_mode)) return size;
        const smallest = @min(size, if (text_fitting) self.minimum_font_size.get() else size);
        // Sizes `smallest + k / 2`: the largest k that fits (0 if none).
        var lo: u32 = 0;
        var hi: u32 = @intFromFloat(@max(0, @ceil((size - smallest) * 2)));
        while (lo + 1 < hi) {
            const mid = (lo + hi) / 2;
            if (self.fits(smallest + @as(f32, @floatFromInt(mid)) / 2, fit_mode)) lo = mid else hi = mid;
        }
        return smallest + @as(f32, @floatFromInt(lo)) / 2;
    }

    fn fits(self: *Text, font_size: f32, fit_mode: rendering.FontSizeMode) bool {
        const wraps = self.wrap.get() == .word_wrap;
        const width = self.item.width.get();
        const s = self.measure(self.text.get(), font_size, if (wraps) width else null);
        // A little room for rounding.
        const wide = wraps or s.width <= width + 0.01;
        const tall = s.height <= self.item.height.get() + 0.01;
        return switch (fit_mode) {
            .fixed => true,
            .horizontal_fit => wide,
            .vertical_fit => tall,
            .fit => wide and tall,
        };
    }

    fn render(i: *Item, r: ItemRenderer) void {
        const self = parentOf(Text, i);
        r.drawText(i.size(), .{
            .text = self.text.get(),
            .font = self.resolvedFont(),
            .color = self.color.get(),
            .font_size = self.fittedFontSize(),
            .letter_spacing = self.spacing(),
            .horizontal_alignment = self.horizontal_alignment.get(),
            .vertical_alignment = self.vertical_alignment.get(),
            .wrap = self.wrap.get(),
            .fallbacks = fallbackFonts(i),
            .overflow = self.overflow.get(),
        });
    }
};

pub const TextInput = @import("text_input.zig").TextInput;

pub const PopupClosePolicy = @import("window.zig").PopupClosePolicy;

/// Content shown above everything else while open (`show()` / `close()`),
/// positioned like any child of its parent. Initialize in place with
/// `init`.
pub const PopupWindow = struct {
    item: Item = .init(&vtable),
    close_policy: Property(PopupClosePolicy) = .init(.close_on_click),
    is_open: Property(bool) = .init(false),
    /// Drawn on top of everything, but pointer input goes past it (a
    /// tooltip).
    input_transparent: Property(bool) = .init(false),
    /// When shown, moved back inside the window if it would stick out
    /// (sets `x` and `y`).
    fit_in_window: Property(bool) = .init(false),
    /// When shown, covers the whole window (a modal dialog's backdrop):
    /// `x`, `y`, `width` and `height` follow the window.
    fill_window: Property(bool) = .init(false),
    /// Where it was shown in the window, and the window's size then (a
    /// menu keeps its submenus in the window with them).
    window_x: Property(f32) = .init(0),
    window_y: Property(f32) = .init(0),
    window_width: Property(f32) = .init(0),
    window_height: Property(f32) = .init(0),
    /// While it is closed, a drag this way begun within `edge_margin` of
    /// the window's opposite edge pulls it out (a drawer): `edge_dragged`
    /// with how far it went, then `edge_released` with how far and how
    /// fast (pixels a second, that way). No margin: none.
    open_swipe: Property(SwipeDirection) = .init(.right),
    edge_margin: Property(f32) = .init(0),
    edge_dragged: Callback(fn (f32) void) = .{},
    edge_released: Callback(fn (f32, f32) void) = .{},
    gpa: Allocator = undefined,

    pub fn init(self: *PopupWindow, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.item.visible.set(false);
    }

    pub fn deinit(self: *PopupWindow) void {
        if (self.item.window()) |w| w.forgetPopup(&self.item);
        self.item.deinit();
        self.close_policy.deinit();
        self.is_open.deinit();
        self.input_transparent.deinit();
        self.fit_in_window.deinit();
        self.fill_window.deinit();
        self.window_x.deinit();
        self.window_y.deinit();
        self.window_width.deinit();
        self.window_height.deinit();
        self.open_swipe.deinit();
        self.edge_margin.deinit();
    }

    pub fn show(self: *PopupWindow) void {
        const w = self.item.window() orelse return;
        if (self.fill_window.get()) self.fill() catch {};
        if (self.fit_in_window.get()) self.fit(w.size());
        const at = self.item.absolutePosition();
        self.window_x.set(at.x);
        self.window_y.set(at.y);
        self.window_width.set(w.size().width);
        self.window_height.set(w.size().height);
        self.item.visible.set(true);
        self.is_open.set(true);
        w.openPopup(&self.item, self.close_policy.get(), closedByWindow, self.input_transparent.get());
    }

    /// Binds its geometry to cover the window (from its parent's place).
    fn fill(self: *PopupWindow) Allocator.Error!void {
        const F = struct {
            fn x(p: *PopupWindow) f32 {
                return -(if (p.item.parent) |par| par.absolutePosition().x else 0);
            }
            fn y(p: *PopupWindow) f32 {
                return -(if (p.item.parent) |par| par.absolutePosition().y else 0);
            }
            fn width(p: *PopupWindow) f32 {
                return if (p.item.window()) |w| w.root.item.width.get() else 0;
            }
            fn height(p: *PopupWindow) f32 {
                return if (p.item.window()) |w| w.root.item.height.get() else 0;
            }
        };
        try self.item.x.setBinding(self.gpa, self, F.x);
        try self.item.y.setBinding(self.gpa, self, F.y);
        try self.item.width.setBinding(self.gpa, self, F.width);
        try self.item.height.setBinding(self.gpa, self, F.height);
    }

    /// Moves it (in its parent) so that it lies inside `window`, as far
    /// as it fits.
    fn fit(self: *PopupWindow, window: Size) void {
        const at = self.item.absolutePosition();
        const size = self.item.size();
        const dx = std.math.clamp(at.x, 0, @max(0, window.width - size.width)) - at.x;
        const dy = std.math.clamp(at.y, 0, @max(0, window.height - size.height)) - at.y;
        if (dx != 0) self.item.x.set(self.item.x.get() + dx);
        if (dy != 0) self.item.y.set(self.item.y.get() + dy);
    }

    pub fn close(self: *PopupWindow) void {
        if (self.item.window()) |w| w.forgetPopup(&self.item);
        self.item.visible.set(false);
        self.is_open.set(false);
    }

    fn closedByWindow(i: *Item) void {
        const self = parentOf(PopupWindow, i);
        self.item.visible.set(false);
        self.is_open.set(false);
    }

    pub const vtable: ItemVTable = .{ .name = "PopupWindow", .is_popup = true };
};
pub const InputType = @import("text_input.zig").InputType;

pub const AudioElement = @import("audio/audio.zig").AudioElement;
pub const VideoElement = @import("video/video.zig").VideoElement;
pub const AnimatedImageElement = @import("animated.zig").AnimatedImageElement;
pub const Loader = @import("loader.zig").Loader;
pub const DragArea = @import("dnd.zig").DragArea;
pub const DropArea = @import("dnd.zig").DropArea;
pub const PinchArea = @import("gestures.zig").PinchArea;
pub const SwipeArea = @import("gestures.zig").SwipeArea;
pub const Shortcut = @import("shortcuts.zig").Shortcut;
pub const StackLayout = @import("pages.zig").StackLayout;
pub const SwipeView = @import("pages.zig").SwipeView;
pub const StackView = @import("pages.zig").StackView;
pub const FlowLayout = @import("pages.zig").FlowLayout;
pub const SplitView = @import("split.zig").SplitView;
pub const TreeState = @import("tree.zig").TreeState;
pub const Selection = @import("selection.zig").Selection;
pub const ListLayout = @import("listlayout.zig").ListLayout;
pub const TableRow = @import("listlayout.zig").TableRow;
pub const StyledText = @import("richtext.zig").StyledText;
pub const SwipeDirection = @import("gestures.zig").SwipeDirection;
pub const PropertyAnimation = @import("timeline.zig").PropertyAnimation;
pub const PauseAnimation = @import("timeline.zig").PauseAnimation;
pub const SequentialAnimation = @import("timeline.zig").SequentialAnimation;
pub const ParallelAnimation = @import("timeline.zig").ParallelAnimation;

/// Handlers for another element's callbacks (`Connections { target: x;
/// clicked => { ... } }`), added to the ones it has; they run while
/// `enabled`. Not drawn: the generated code connects them.
pub const Connections = struct {
    item: Item = .init(&vtable),
    enabled: Property(bool) = .init(true),

    pub fn deinit(self: *Connections) void {
        self.item.deinit();
        self.enabled.deinit();
    }

    const vtable: ItemVTable = .{ .name = "Connections" };
};
pub const FileDialogElement = @import("dialogs.zig").FileDialogElement;
pub const FileDialogMode = @import("dialogs.zig").FileDialogMode;
pub const Settings = @import("settings.zig").Settings;
pub const StandardPaths = @import("paths.zig").StandardPaths;
pub const Canvas = @import("canvas.zig").Canvas;
pub const LineChart = @import("charts.zig").LineChart;
pub const BarChart = @import("charts.zig").BarChart;
pub const PieChart = @import("charts.zig").PieChart;
pub const HttpRequest = @import("http.zig").HttpRequest;
pub const SystemTrayIcon = @import("tray.zig").SystemTrayIcon;
pub const Notification = @import("tray.zig").Notification;
pub const Microphone = @import("audio/capture.zig").Microphone;
pub const Camera = @import("camera.zig").Camera;
pub const Accelerometer = @import("sensors.zig").Accelerometer;
pub const Gyroscope = @import("sensors.zig").Gyroscope;
pub const Compass = @import("sensors.zig").Compass;
pub const OrientationSensor = @import("sensors.zig").OrientationSensor;
pub const PositionSource = @import("location.zig").PositionSource;
pub const MapView = @import("map.zig").MapView;
pub const MapItem = @import("map.zig").MapItem;
pub const MapPolyline = @import("map.zig").MapPolyline;
pub const WebView = @import("webview.zig").WebView;
pub const View3D = @import("view3d.zig").View3D;
pub const SceneModel = @import("view3d.zig").SceneModel;
pub const SceneNode = @import("view3d.zig").SceneNode;
pub const PerspectiveCamera = @import("view3d.zig").PerspectiveCamera;
pub const DirectionalLight = @import("view3d.zig").DirectionalLight;
pub const PointLight = @import("view3d.zig").PointLight;
pub const KeyboardInput = @import("keyboard_input.zig").KeyboardInput;
pub const HttpMethod = @import("http.zig").Method;
pub const PlatformMenu = @import("menus.zig").PlatformMenu;
pub const PlatformMenuItem = @import("menus.zig").PlatformMenuItem;

/// Calls `triggered` every `interval_ms` while `running` (the `Timer`
/// element). Changes apply when change handlers run. Initialize in place
/// with `init`.
pub const TimerElement = struct {
    item: Item = .init(&vtable),
    interval_ms: Property(i64) = .init(1000),
    running: Property(bool) = .init(true),
    triggered: Callback(fn () void) = .{},
    timer: @import("timers.zig").Timer = .{},
    tracker: @import("properties.zig").ChangeTracker(Config) = undefined,

    const Config = struct { running: bool, interval_ms: i64 };

    pub fn init(self: *TimerElement, gpa: Allocator) void {
        self.* = .{};
        self.tracker.init(gpa, self, config, apply);
        apply(self, self.tracker.value);
    }

    pub fn deinit(self: *TimerElement) void {
        self.tracker.deinit();
        self.timer.deinit();
        self.item.deinit();
        self.interval_ms.deinit();
        self.running.deinit();
    }

    fn config(self: *TimerElement) Config {
        return .{ .running = self.running.get(), .interval_ms = self.interval_ms.get() };
    }

    fn apply(self: *TimerElement, s: Config) void {
        if (s.running) self.timer.start(.repeated, @intCast(@max(s.interval_ms, 1)), self, fire) else self.timer.stop();
    }

    fn fire(self: *TimerElement) void {
        self.triggered.call(.{});
    }

    /// Sets `running` (`start()` in `.zge`).
    pub fn start(self: *TimerElement) void {
        self.running.set(true);
    }

    /// Clears `running` (`stop()`).
    pub fn stop(self: *TimerElement) void {
        self.running.set(false);
    }

    /// Runs from now: the next `triggered` a whole `interval` away
    /// (`restart()`; an inactivity timeout restarts on input).
    pub fn restart(self: *TimerElement) void {
        self.running.set(true);
        self.timer.start(.repeated, @intCast(@max(self.interval_ms.getUntracked(), 1)), self, fire);
    }

    const vtable: ItemVTable = .{ .name = "Timer" };
};

/// Turns pointer input into properties and callbacks.
pub const TouchArea = struct {
    item: Item = .init(&vtable),
    /// The pointer's shape over it.
    mouse_cursor: Property(input.MouseCursor) = .init(.default),
    pressed: Property(bool) = .init(false),
    has_hover: Property(bool) = .init(false),
    mouse_x: Property(f32) = .init(0),
    mouse_y: Property(f32) = .init(0),
    pressed_x: Property(f32) = .init(0),
    pressed_y: Property(f32) = .init(0),
    /// The keyboard modifiers held at the last press (Shift-click,
    /// Ctrl-click...).
    modifiers: Property(input.Modifiers) = .init(.{}),
    /// Left button pressed and released inside.
    clicked: Callback(fn () void) = .{},
    /// Pointer moved while pressed.
    moved: Callback(fn () void) = .{},
    /// Every press and release, any button, moves over it or while
    /// pressed, and a press taken away.
    pointer_event: Callback(fn (input.TouchAreaEvent) void) = .{},
    /// Right button pressed and released inside (a context menu's cue).
    right_clicked: Callback(fn () void) = .{},
    /// A second click within `double_click_interval_ms` of the first, close
    /// to it: called instead of `clicked` for it, when it has a handler (as
    /// Qt's MouseArea).
    double_clicked: Callback(fn () void) = .{},
    double_click_interval_ms: Property(i64) = .init(400),
    last_click: ?struct { at: Point, ms: u64 } = null,
    scroll_event: Callback(fn (input.PointerEvent) input.EventResult) = .{},

    pub fn deinit(self: *TouchArea) void {
        self.item.deinit();
        self.mouse_cursor.deinit();
        self.pressed.deinit();
        self.has_hover.deinit();
        self.mouse_x.deinit();
        self.mouse_y.deinit();
        self.pressed_x.deinit();
        self.pressed_y.deinit();
        self.modifiers.deinit();
        self.double_click_interval_ms.deinit();
    }

    /// How far apart a double click's clicks may be.
    const double_click_distance = 8;

    const vtable: ItemVTable = .{ .name = "TouchArea", .inputEvent = inputEvent, .mouseCursor = mouseCursor };

    fn mouseCursor(i: *Item) input.MouseCursor {
        const self = parentOf(TouchArea, i);
        return if (self.item.isEnabled()) self.mouse_cursor.get() else .default;
    }

    fn inputEvent(i: *Item, event: input.PointerEvent, _: *Window) input.InputEventResult {
        const self = parentOf(TouchArea, i);
        if (!self.item.isEnabled()) {
            self.has_hover.set(false);
            self.pressed.set(false);
            return .ignored;
        }
        if (event.position()) |p| {
            self.mouse_x.set(p.x);
            self.mouse_y.set(p.y);
        }
        const inside = if (event.position()) |p| (Rect{ .width = i.width.get(), .height = i.height.get() }).contains(p) else false;
        switch (event) {
            .exit => {
                // A press taken away (by a Flickable dragging, say).
                if (self.pressed.get()) self.pointer_event.call(.{.{ .kind = .cancel, .modifiers = self.modifiers.get() }});
                self.has_hover.set(false);
                self.pressed.set(false);
                return .accepted;
            },
            .moved => {
                self.has_hover.set(inside);
                if (inside or self.pressed.get()) self.pointer_event.call(.{.{ .kind = .move, .modifiers = self.modifiers.get() }});
                if (!self.pressed.get()) return .accepted;
                self.moved.call(.{});
                return .grab;
            },
            .pressed => |p| {
                self.modifiers.set(p.modifiers);
                self.pointer_event.call(.{.{ .kind = .down, .button = p.button, .modifiers = p.modifiers }});
                if (p.button != .left) return .accepted;
                self.pressed_x.set(p.position.x);
                self.pressed_y.set(p.position.y);
                self.pressed.set(true);
                self.has_hover.set(true);
                return .grab;
            },
            .released => |p| {
                self.pointer_event.call(.{.{ .kind = .up, .button = p.button, .modifiers = self.modifiers.get() }});
                if (p.button == .right and inside) self.right_clicked.call(.{});
                if (p.button != .left or !self.pressed.get()) return .accepted;
                self.pressed.set(false);
                self.has_hover.set(inside);
                if (inside) self.click(p.position);
                return .accepted;
            },
            .wheel => return if (self.scroll_event.call(.{event}) == .accept) .accepted else .ignored,
        }
    }

    /// `clicked`, or `double_clicked` if the last click was close enough,
    /// in time and place (a third click starts again). The handler may
    /// destroy the touch area: nothing is touched after it.
    fn click(self: *TouchArea, at: Point) void {
        const now = time.now();
        const double = if (self.last_click) |c| blk: {
            const interval: u64 = @intCast(@max(self.double_click_interval_ms.get(), 0));
            break :blk now -| c.ms <= interval and @abs(c.at.x - at.x) <= double_click_distance and @abs(c.at.y - at.y) <= double_click_distance;
        } else false;
        self.last_click = if (double) null else .{ .at = at, .ms = now };
        if (double and self.double_clicked.hasHandler()) self.double_clicked.call(.{}) else self.clicked.call(.{});
    }
};

/// Receives keyboard input when focused. Takes focus when clicked (unless
/// a child handles the click) or via Tab navigation.
pub const FocusScope = struct {
    item: Item = .init(&vtable),
    has_focus: Property(bool) = .init(false),
    key_pressed: Callback(fn (input.KeyEvent) input.EventResult) = .{},
    key_released: Callback(fn (input.KeyEvent) input.EventResult) = .{},
    focus_changed: Callback(fn (bool) void) = .{},

    pub fn deinit(self: *FocusScope) void {
        self.item.deinit();
        self.has_focus.deinit();
    }

    /// Requests keyboard focus, if the item is in a window.
    pub fn focus(self: *FocusScope) void {
        if (self.item.window()) |w| w.setFocusItem(&self.item);
    }

    const vtable: ItemVTable = .{
        .name = "FocusScope",
        .inputEvent = inputEvent,
        .keyEvent = keyEvent,
        .focusEvent = focusEvent,
        .acceptsFocus = acceptsFocus,
    };

    fn acceptsFocus(i: *Item) bool {
        return i.isEnabled();
    }

    fn inputEvent(i: *Item, event: input.PointerEvent, w: *Window) input.InputEventResult {
        if (event == .pressed and acceptsFocus(i)) w.setFocusItem(i);
        return .ignored;
    }

    fn keyEvent(i: *Item, kind: input.KeyEventKind, event: input.KeyEvent, _: *Window) input.EventResult {
        const self = parentOf(FocusScope, i);
        if (!self.item.isEnabled()) return .reject;
        return switch (kind) {
            .pressed => self.key_pressed.call(.{event}),
            .released => self.key_released.call(.{event}),
        };
    }

    fn focusEvent(i: *Item, event: input.FocusEvent, _: *Window) void {
        const self = parentOf(FocusScope, i);
        const has = event == .focus_in;
        self.has_focus.set(has);
        self.focus_changed.call(.{has});
    }
};

/// Displays an image (`Image { source: ...; }`), or one loaded while the
/// program runs from `source-url` (a file, or `http(s)://`), in the
/// background (`status` says how it goes). Initialize in place with
/// `init` to load from URLs.
pub const Image = struct {
    item: Item = .init(&vtable),
    source: Property(?image.Image) = .init(null),
    source_url: Property([]const u8) = .init(""),
    /// Headers sent with `source_url` (each `Name: value`).
    source_headers: Property(model_mod.Model([]const u8)) = .init(model_mod.emptyModel([]const u8)),
    status: Property(image.ImageStatus) = .init(.none),
    /// How much of `source_url` has come, 0 to 1 (0 while its size is not
    /// known; 1 once loaded).
    progress: Property(f32) = .init(0),
    image_fit: Property(image.ImageFit) = .init(.contain),
    image_rendering: Property(image.ImageRendering) = .init(.smooth),
    /// Draws the image's shape in this brush instead of its colors.
    colorize: Property(?Brush) = .init(null),
    nine_slice: Property(?image.NineSlice) = .init(null),

    gpa: ?Allocator = null,
    url_tracker: @import("properties.zig").ChangeTracker(u64) = undefined,
    /// The image of `source-url`, shared with other Images showing it.
    shared: ?*image_loader.Shared = null,
    /// Checks on the request while it loads.
    poll_timer: @import("timers.zig").Timer = .{},

    pub fn init(self: *Image, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.url_tracker.init(gpa, self, urlHash, urlChanged);
    }

    pub fn deinit(self: *Image) void {
        if (self.gpa != null) self.url_tracker.deinit();
        self.poll_timer.deinit();
        if (self.shared) |e| image_loader.release(e);
        self.item.deinit();
        self.source.deinit();
        self.source_url.deinit();
        self.source_headers.deinit();
        self.status.deinit();
        self.progress.deinit();
        self.image_fit.deinit();
        self.image_rendering.deinit();
        self.colorize.deinit();
        self.nine_slice.deinit();
    }

    fn urlHash(self: *Image) u64 {
        var h: std.hash.Wyhash = .init(0);
        h.update(self.source_url.get());
        const m = self.source_headers.get();
        for (0..m.rowCount()) |i| {
            h.update("\n");
            h.update(m.rowData(i) orelse "");
        }
        return h.final();
    }

    /// Another URL (or other headers): the image of it, shared with the
    /// Images showing it already (one load for all).
    fn urlChanged(self: *Image, _: u64) void {
        self.poll_timer.stop();
        const old = self.shared;
        self.shared = null;
        // Taken before the old one is let go: the same image is not loaded
        // again.
        defer if (old) |e| image_loader.release(e);
        const url = self.source_url.getUntracked();
        if (url.len == 0) {
            self.source.set(null);
            self.progress.set(0);
            self.status.set(.none);
            return;
        }
        const gpa = self.gpa.?;
        var headers: std.ArrayList([]const u8) = .empty;
        defer headers.deinit(gpa);
        const m = self.source_headers.getUntracked();
        for (0..m.rowCount()) |i| headers.append(gpa, m.rowData(i) orelse continue) catch {};
        self.shared = image_loader.acquire(url, .{ .headers = headers.items }) catch {
            self.source.set(null);
            self.status.set(.failed);
            return;
        };
        self.status.set(.loading);
        self.progress.set(0);
        self.poll();
        // Not there yet: nothing shown meanwhile (the old image may go
        // when let go).
        if (self.status.getUntracked() == .loading) {
            self.source.set(null);
            self.poll_timer.start(.repeated, 15, self, poll);
        }
    }

    fn poll(self: *Image) void {
        const e = self.shared orelse return;
        const result = e.poll() orelse {
            self.progress.set(e.fraction());
            return;
        };
        self.poll_timer.stop();
        self.progress.set(1);
        if (result) |img| {
            self.source.set(img);
            self.status.set(.ready);
        } else |err| {
            log.warn("cannot load the image '{s}': {t}", .{ self.source_url.getUntracked(), err });
            self.source.set(null);
            self.status.set(.failed);
        }
    }

    const vtable: ItemVTable = .{
        .name = "Image",
        .render = render,
        .layoutInfo = layoutInfo,
        .accessible_role = .image,
    };

    /// Prefers the image's natural size.
    fn layoutInfo(i: *Item, o: Orientation) LayoutInfo {
        const img = parentOf(Image, i).source.get() orelse return .{};
        const natural: f32 = @floatFromInt(if (o == .horizontal) img.width else img.height);
        return .{ .preferred = natural };
    }

    fn render(i: *Item, r: ItemRenderer) void {
        const self = parentOf(Image, i);
        const img = self.source.get() orelse return;
        if (img.vector) |d| return self.renderVector(d, r);
        const style: rendering.ImageStyle = .{
            .image = img,
            .fit = self.image_fit.get(),
            .rendering = self.image_rendering.get(),
            .colorize = self.colorize.get(),
            .nine_slice = self.nine_slice.get() orelse img.nine_slice,
        };
        r.drawImage(i.size(), style);
    }

    /// Draws `img` stretched over `size` (as `image-fit: fill`): an SVG
    /// drawing's shapes, or its pixels. For items showing images of their
    /// own (StyledText's).
    pub fn drawPicture(item: *Item, img: image.Image, size: Size, r: ItemRenderer) void {
        if (img.vector) |d| {
            if (d.viewbox.width <= 0 or d.viewbox.height <= 0 or size.width <= 0 or size.height <= 0) return;
            r.save();
            defer r.restore();
            if (!r.clip(.{ .width = size.width, .height = size.height })) return;
            drawShapes(item, d, r, size, d.viewbox, true, null);
            return;
        }
        r.drawImage(size, .{ .image = img, .fit = .fill });
    }

    /// An SVG drawing's shapes, each a path in the drawing's viewbox,
    /// fitted as `image-fit` says.
    fn renderVector(self: *Image, d: *const @import("svg.zig").Drawing, r: ItemRenderer) void {
        const size = self.item.size();
        var vb = d.viewbox;
        if (vb.width <= 0 or vb.height <= 0 or size.width <= 0 or size.height <= 0) return;
        const fit = self.image_fit.get();
        // Cover: the middle part of the viewbox with the item's shape (at
        // the scale that fills it); preserve: at the drawing's own size.
        if (fit == .cover or fit == .preserve) {
            const s = if (fit == .cover) @max(size.width / vb.width, size.height / vb.height) else d.width / vb.width;
            const w = size.width / s;
            const h = size.height / s;
            vb = .{ .x = vb.x + (vb.width - w) / 2, .y = vb.y + (vb.height - h) / 2, .width = w, .height = h };
        }
        // Like a browser, nothing outside the viewport.
        r.save();
        defer r.restore();
        if (!r.clip(.{ .width = size.width, .height = size.height })) return;
        const colorize = self.colorize.get();
        if (fit.tileSize(.{ d.width, d.height }, .{ size.width, size.height })) |t| {
            if (!(t[0] > 0 and t[1] > 0)) return;
            // The whole drawing in each tile, up to a limit on how many.
            const cols: usize = @intFromFloat(@min(@ceil(size.width / t[0]), max_vector_tiles));
            const rows: usize = @intFromFloat(@min(@ceil(size.height / t[1]), max_vector_tiles / @as(f32, @floatFromInt(@max(cols, 1)))));
            for (0..rows) |row| for (0..cols) |col| {
                r.save();
                defer r.restore();
                r.translate(.{ .x = @as(f32, @floatFromInt(col)) * t[0], .y = @as(f32, @floatFromInt(row)) * t[1] });
                drawShapes(&self.item, d, r, .{ .width = t[0], .height = t[1] }, vb, true, colorize);
            };
            return;
        }
        drawShapes(&self.item, d, r, size, vb, fit == .fill, colorize);
    }

    /// How many tiles of an SVG drawing are drawn at most (each is drawn as
    /// paths).
    const max_vector_tiles = 1024;

    /// A drawing's shapes over `size`, their viewbox `vb` scaled uniformly
    /// or stretched.
    const svg = @import("svg.zig");

    /// A drawing's shapes over `size`, their viewbox `vb` scaled uniformly
    /// or stretched.
    fn drawShapes(item: *Item, d: *const svg.Drawing, r: ItemRenderer, size: Size, vb: Rect, stretch: bool, colorize: ?Brush) void {
        const box: Rect = .{ .width = size.width, .height = size.height };
        const fit = if (stretch) path_mod.Transform.fit(vb, box) else path_mod.Transform.contain(vb, box);
        const place: Drawn = .{
            .item = item,
            .d = d,
            .size = size,
            .vb = vb,
            .stretch = stretch,
            .colorize = colorize,
            .to_item = .{ .a = fit.scale.x, .d = fit.scale.y, .tx = fit.offset.x, .ty = fit.offset.y },
            // Strokes scale with the drawing.
            .scale = @sqrt(fit.scale.x * fit.scale.y),
        };
        for (d.shapes) |shape| place.shape(r, shape);
    }

    /// Where a drawing goes in an Image.
    const Drawn = struct {
        item: *Item,
        d: *const svg.Drawing,
        size: Size,
        vb: Rect,
        stretch: bool,
        colorize: ?Brush,
        /// From the drawing's coordinates to the item's.
        to_item: geometry.Affine,
        scale: f32,

        fn brush(p: Drawn, paint: ?svg.Paint) Brush {
            const v = paint orelse return .transparent;
            if (p.colorize) |b| return b;
            return switch (v) {
                .color => |col| .color(col),
                .current => .color(.black),
                .gradient => |b| b,
            };
        }

        /// A shape, clipped, masked and blurred as it says.
        fn shape(p: Drawn, r: ItemRenderer, s: svg.Shape) void {
            const special = s.clip.len > 0 or s.mask.len > 0 or s.blur > 0;
            if (special) r.save();
            defer if (special) r.restore();
            const blurred = s.blur > 0;
            if (blurred) r.beginLayer(1, s.blur * p.scale, null);
            defer if (blurred) r.endLayer();
            if (s.clip.len > 0) {
                // In the drawing's coordinates, then back.
                r.transform(p.to_item);
                r.clipPath(.{ .width = @max(1, p.vb.x + p.vb.width), .height = @max(1, p.vb.y + p.vb.height) }, s.clip);
                if (p.to_item.inverse()) |back| r.transform(back);
            }
            if (s.mask.len > 0) {
                r.beginMaskShape(p.size, false, true);
                for (s.mask) |m| p.shape(r, m);
                r.endMaskShape();
            }
            if (s.text) |t| return p.text(r, t, s.fill);
            r.drawPath(p.size, .{
                .commands = s.commands,
                .fill = p.brush(s.fill),
                .stroke = p.brush(s.stroke),
                .stroke_width = s.stroke_width * p.scale,
                .viewbox = p.vb,
                .stretch = p.stretch,
                .inset_stroke = false,
                .paint_box = p.d.viewbox,
            });
        }

        /// Text on its baseline, in the item's font.
        fn text(p: Drawn, r: ItemRenderer, t: svg.Text, fill: ?svg.Paint) void {
            const px = t.size * p.scale;
            if (!(px > 0)) return;
            const font = resolveFont(p.item, null, "", if (t.bold) 700 else 400);
            const fallbacks = fallbackFonts(p.item);
            const measured = if (font) |f|
                text_mod.layout.measureMetrics(.initFallbacks(f, fallbacks, px), t.content, null)
            else if (p.item.window()) |w| w.text_measurer.measure(t.content, px, null) else rendering.TextMeasurer.approximate.measure(t.content, px, null);
            const ascent = if (font) |f| @as(f32, @floatFromInt(f.ascender)) * f.scale(px) else px * 0.8;
            const at = p.to_item.apply(.{ .x = t.x, .y = t.y });
            const left = switch (t.anchor) {
                .start => at.x,
                .middle => at.x - measured.width / 2,
                .end => at.x - measured.width,
            };
            r.save();
            defer r.restore();
            r.translate(.{ .x = left, .y = at.y - ascent });
            r.drawText(.{ .width = measured.width + 2, .height = measured.height }, .{
                .text = t.content,
                .font = font,
                .color = p.brush(fill),
                .font_size = px,
                .fallbacks = fallbacks,
            });
        }
    };
};

/// Draws a vector shape from SVG path data (`Path { commands: "M 0 0 L ..."; }`).
pub const Path = struct {
    item: Item = .init(&vtable),
    commands: Property([]const u8) = .init(""),
    fill: Property(Brush) = .init(.transparent),
    stroke: Property(Brush) = .init(.transparent),
    stroke_width: Property(f32) = .init(0),
    /// Path coordinates shown in the item (scaled uniformly, centered);
    /// null fits the path's own bounds.
    viewbox: Property(?Rect) = .init(null),

    pub fn deinit(self: *Path) void {
        self.item.deinit();
        self.commands.deinit();
        self.fill.deinit();
        self.stroke.deinit();
        self.stroke_width.deinit();
        self.viewbox.deinit();
    }

    const vtable: ItemVTable = .{ .name = "Path", .render = render };

    fn render(i: *Item, r: ItemRenderer) void {
        const self = parentOf(Path, i);
        const style: rendering.PathStyle = .{
            .commands = self.commands.get(),
            .fill = self.fill.get(),
            .stroke = self.stroke.get(),
            .stroke_width = self.stroke_width.get(),
            .viewbox = self.viewbox.get(),
        };
        const strokes = style.stroke_width > 0 and !style.stroke.isTransparent();
        if (style.commands.len == 0 or (style.fill.isTransparent() and !strokes)) return;
        r.drawPath(i.size(), style);
    }
};

/// Index of a child within a layout, captured by its geometry bindings.
fn ChildRef(comptime L: type) type {
    return struct { layout: *L, child: *Item, index: u32 };
}

/// `HorizontalLayout` / `VerticalLayout`: places children side by side.
/// Append the children, then call `setup`.
pub const BoxLayout = struct {
    item: Item = .init(&vtable),
    orientation: Orientation,
    spacing: Property(f32) = .init(0),
    padding_left: Property(f32) = .init(0),
    padding_right: Property(f32) = .init(0),
    padding_top: Property(f32) = .init(0),
    padding_bottom: Property(f32) = .init(0),
    alignment: Property(layout.Alignment) = .init(.stretch),

    // Derived state, created by `setup`. Each binding has its own scratch
    // buffer, so re-entrant evaluation (a child's constraints depending on
    // its size, which depends on this layout) never shares memory.
    gpa: ?Allocator = null,
    arena: ?std.heap.ArenaAllocator = null,
    solve_infos: []LayoutInfo = &.{},
    segments: []Segment = &.{},
    main_infos: []LayoutInfo = &.{},
    cross_infos: []LayoutInfo = &.{},
    /// The child whose geometry is bound at each index: `setup` re-binds
    /// only children that are new or moved.
    bound: std.ArrayList(Bound) = .empty,
    solved: Property(void) = .init({}),
    info_main: Property(LayoutInfo) = .init(.{}),
    info_cross: Property(LayoutInfo) = .init(.{}),

    const Bound = struct {
        child: *Item,
        /// The binding installed on its main position. A new item at the
        /// address of a destroyed one has none (nothing else binds the
        /// geometry of a layout's children), so it is told apart.
        link: usize,
    };

    pub fn horizontal() BoxLayout {
        return .{ .orientation = .horizontal };
    }

    pub fn vertical() BoxLayout {
        return .{ .orientation = .vertical };
    }

    pub fn setPadding(self: *BoxLayout, all: f32) void {
        self.padding_left.set(all);
        self.padding_right.set(all);
        self.padding_top.set(all);
        self.padding_bottom.set(all);
    }

    pub fn deinit(self: *BoxLayout) void {
        releaseChildGeometry(&self.item);
        self.solved.deinit();
        self.info_main.deinit();
        self.info_cross.deinit();
        if (self.arena) |*a| a.deinit();
        if (self.gpa) |gpa| self.bound.deinit(gpa);
        self.item.deinit();
        self.spacing.deinit();
        self.padding_left.deinit();
        self.padding_right.deinit();
        self.padding_top.deinit();
        self.padding_bottom.deinit();
        self.alignment.deinit();
    }

    /// Binds every child's geometry to the layout. Call after appending the
    /// children, and again after adding or removing children by hand
    /// (repeaters and conditionals trigger it themselves). Children of
    /// repeaters and conditionals are laid out as if they were direct
    /// children.
    pub fn setup(self: *BoxLayout, gpa: Allocator) Allocator.Error!void {
        self.gpa = gpa;
        const n = self.item.layoutChildCount();
        if (self.arena) |*a| _ = a.reset(.retain_capacity) else self.arena = .init(gpa);
        const arena = self.arena.?.allocator();
        self.solve_infos = try arena.alloc(LayoutInfo, n);
        self.segments = try arena.alloc(Segment, n);
        self.main_infos = try arena.alloc(LayoutInfo, n);
        self.cross_infos = try arena.alloc(LayoutInfo, n);

        try self.solved.setBinding(gpa, self, solve);
        try self.info_main.setBinding(gpa, self, infoMain);
        try self.info_cross.setBinding(gpa, self, infoCross);

        const Ref = ChildRef(BoxLayout);
        try self.bound.ensureTotalCapacity(gpa, n);
        var children = self.item.layoutChildren();
        var index: u32 = 0;
        while (children.next()) |c| : (index += 1) {
            const main_pos, const main_size, const cross_pos, const cross_size = switch (self.orientation) {
                .horizontal => .{ &c.x, &c.width, &c.y, &c.height },
                .vertical => .{ &c.y, &c.height, &c.x, &c.width },
            };
            // Bound at this index already: its bindings are still right.
            if (index < self.bound.items.len) {
                const b = self.bound.items[index];
                if (b.child == c and b.link == main_pos.base.link and b.link != 0) continue;
            }
            const ref: Ref = .{ .layout = self, .child = c, .index = index };
            try main_pos.setBinding(gpa, ref, childMainPos);
            try main_size.setBinding(gpa, ref, childMainSize);
            try cross_pos.setBinding(gpa, ref, childCrossPos);
            try cross_size.setBinding(gpa, ref, childCrossSize);
            const entry: Bound = .{ .child = c, .link = main_pos.base.link };
            if (index < self.bound.items.len) self.bound.items[index] = entry else self.bound.appendAssumeCapacity(entry);
        }
        self.bound.shrinkRetainingCapacity(index);
    }

    fn cross(self: *const BoxLayout) Orientation {
        return if (self.orientation == .horizontal) .vertical else .horizontal;
    }

    fn sizeAlong(self: *BoxLayout, o: Orientation) f32 {
        return if (o == .horizontal) self.item.width.get() else self.item.height.get();
    }

    fn paddingAlong(self: *BoxLayout, o: Orientation) layout.Padding {
        return switch (o) {
            .horizontal => .{ .begin = self.padding_left.get(), .end = self.padding_right.get() },
            .vertical => .{ .begin = self.padding_top.get(), .end = self.padding_bottom.get() },
        };
    }

    fn collectInfos(self: *BoxLayout, o: Orientation, out: []LayoutInfo) void {
        var children = self.item.layoutChildren();
        var i: usize = 0;
        while (children.next()) |c| : (i += 1) out[i] = c.layoutInfo(o);
    }

    fn solve(self: *BoxLayout) void {
        // Read this layout's own inputs before filling the scratch buffer.
        const data: layout.BoxLayoutData = .{
            .size = self.sizeAlong(self.orientation),
            .spacing = self.spacing.get(),
            .padding = self.paddingAlong(self.orientation),
            .alignment = self.alignment.get(),
        };
        self.collectInfos(self.orientation, self.solve_infos);
        layout.solveBox(data, self.solve_infos, self.segments);
    }

    fn infoMain(self: *BoxLayout) LayoutInfo {
        const spacing = self.spacing.get();
        const padding = self.paddingAlong(self.orientation);
        const alignment = self.alignment.get();
        self.collectInfos(self.orientation, self.main_infos);
        var info = layout.boxLayoutInfo(self.main_infos, spacing, padding);
        // Only a stretching layout is limited by its children's maximums;
        // the other alignments place the children within any extra space.
        if (alignment != .stretch) info.max = std.math.inf(f32);
        return info;
    }

    fn infoCross(self: *BoxLayout) LayoutInfo {
        const padding = self.paddingAlong(self.cross());
        self.collectInfos(self.cross(), self.cross_infos);
        return layout.boxLayoutInfoOrtho(self.cross_infos, padding);
    }

    fn childMainPos(ref: ChildRef(BoxLayout)) f32 {
        ref.layout.solved.get();
        return ref.layout.segments[ref.index].pos;
    }

    fn childMainSize(ref: ChildRef(BoxLayout)) f32 {
        ref.layout.solved.get();
        return ref.layout.segments[ref.index].size;
    }

    fn childCrossSegment(ref: ChildRef(BoxLayout)) Segment {
        const l = ref.layout;
        const o = l.cross();
        const padding = l.paddingAlong(o);
        const available: Segment = .{ .pos = padding.begin, .size = @max(0, l.sizeAlong(o) - padding.begin - padding.end) };
        return layout.fitInSegment(available, ref.child.layoutInfo(o));
    }

    fn childCrossPos(ref: ChildRef(BoxLayout)) f32 {
        return childCrossSegment(ref).pos;
    }

    fn childCrossSize(ref: ChildRef(BoxLayout)) f32 {
        return childCrossSegment(ref).size;
    }

    const vtable: ItemVTable = .{
        .name = "BoxLayout",
        .layoutInfo = layoutInfo,
        .childrenChanged = childrenChanged,
        .is_layout = true,
    };

    fn childrenChanged(i: *Item) void {
        const self = parentOf(BoxLayout, i);
        const gpa = self.gpa orelse return;
        self.setup(gpa) catch std.log.scoped(.zigulee).err("out of memory re-laying out children", .{});
    }

    fn layoutInfo(i: *Item, o: Orientation) LayoutInfo {
        const self = parentOf(BoxLayout, i);
        if (self.arena == null) return .{};
        return if (o == self.orientation) self.info_main.get() else self.info_cross.get();
    }
};

/// `GridLayout`: places children in rows and columns. Append the children,
/// then call `setup` with one placement per child. A placement without a
/// column takes the next free column of its row; the instances of a
/// repeater or conditional child take consecutive columns.
pub const GridLayout = struct {
    item: Item = .init(&vtable),
    spacing: Property(f32) = .init(0),
    padding_left: Property(f32) = .init(0),
    padding_right: Property(f32) = .init(0),
    padding_top: Property(f32) = .init(0),
    padding_bottom: Property(f32) = .init(0),

    gpa: ?Allocator = null,
    arena: ?std.heap.ArenaAllocator = null,
    /// One per direct child, as given to `setup`.
    slots: std.ArrayList(Placement) = .empty,
    /// One per laid-out child, with every column resolved.
    cells: []Cell = &.{},
    solve_h: Scratch = .{},
    solve_v: Scratch = .{},
    info_h_scratch: Scratch = .{},
    info_v_scratch: Scratch = .{},
    solved_h: Property(void) = .init({}),
    solved_v: Property(void) = .init({}),
    info_h: Property(LayoutInfo) = .init(.{}),
    info_v: Property(LayoutInfo) = .init(.{}),

    pub const Placement = struct {
        row: u16,
        /// Null: the next free column in the row.
        col: ?u16 = null,
        rowspan: u16 = 1,
        colspan: u16 = 1,
    };

    const Cell = struct { row: u16, col: u16, rowspan: u16, colspan: u16 };

    const Scratch = struct {
        cells: []layout.GridCell = &.{},
        tracks: []LayoutInfo = &.{},
        track_out: []Segment = &.{},
        out: []Segment = &.{},

        fn alloc(arena: Allocator, cells: usize, tracks: usize) Allocator.Error!Scratch {
            return .{
                .cells = try arena.alloc(layout.GridCell, cells),
                .tracks = try arena.alloc(LayoutInfo, tracks),
                .track_out = try arena.alloc(Segment, tracks),
                .out = try arena.alloc(Segment, cells),
            };
        }
    };

    pub fn setPadding(self: *GridLayout, all: f32) void {
        self.padding_left.set(all);
        self.padding_right.set(all);
        self.padding_top.set(all);
        self.padding_bottom.set(all);
    }

    pub fn deinit(self: *GridLayout) void {
        releaseChildGeometry(&self.item);
        self.solved_h.deinit();
        self.solved_v.deinit();
        self.info_h.deinit();
        self.info_v.deinit();
        if (self.arena) |*a| a.deinit();
        if (self.gpa) |gpa| self.slots.deinit(gpa);
        self.item.deinit();
        self.spacing.deinit();
        self.padding_left.deinit();
        self.padding_right.deinit();
        self.padding_top.deinit();
        self.padding_bottom.deinit();
    }

    /// `placements[i]` positions the i-th direct child. Call again after
    /// adding or removing children by hand (repeaters and conditionals do
    /// it themselves).
    pub fn setup(self: *GridLayout, gpa: Allocator, placements: []const Placement) Allocator.Error!void {
        std.debug.assert(placements.len == self.item.childCount());
        if (self.gpa == null or self.slots.items.ptr != placements.ptr) {
            self.slots.clearRetainingCapacity();
            try self.slots.appendSlice(gpa, placements);
        }
        self.gpa = gpa;
        if (self.arena) |*a| _ = a.reset(.retain_capacity) else self.arena = .init(gpa);
        const arena = self.arena.?.allocator();

        // Resolve columns: explicit, or the next free one in the row.
        const n = self.item.layoutChildCount();
        self.cells = try arena.alloc(Cell, n);
        var next_col: std.AutoHashMapUnmanaged(u16, u16) = .empty;
        var children = self.item.children();
        var slot_index: usize = 0;
        var cell_index: usize = 0;
        while (children.next()) |child| : (slot_index += 1) {
            const slot = self.slots.items[slot_index];
            var col = slot.col orelse next_col.get(slot.row) orelse 0;
            const instances: usize = if (child.vtable.flatten_in_layout) child.childCount() else 1;
            for (0..instances) |_| {
                self.cells[cell_index] = .{ .row = slot.row, .col = col, .rowspan = @max(slot.rowspan, 1), .colspan = @max(slot.colspan, 1) };
                cell_index += 1;
                col += @max(slot.colspan, 1);
            }
            try next_col.put(arena, slot.row, col);
        }

        var cols: usize = 0;
        var rows: usize = 0;
        for (self.cells) |p| {
            cols = @max(cols, @as(usize, p.col) + p.colspan);
            rows = @max(rows, @as(usize, p.row) + p.rowspan);
        }
        self.solve_h = try .alloc(arena, n, cols);
        self.info_h_scratch = try .alloc(arena, n, cols);
        self.solve_v = try .alloc(arena, n, rows);
        self.info_v_scratch = try .alloc(arena, n, rows);

        try self.solved_h.setBinding(gpa, self, solveH);
        try self.solved_v.setBinding(gpa, self, solveV);
        try self.info_h.setBinding(gpa, self, infoH);
        try self.info_v.setBinding(gpa, self, infoV);

        const Ref = ChildRef(GridLayout);
        var laid_out = self.item.layoutChildren();
        var index: u32 = 0;
        while (laid_out.next()) |c| : (index += 1) {
            const ref: Ref = .{ .layout = self, .child = c, .index = index };
            try c.x.setBinding(gpa, ref, childX);
            try c.width.setBinding(gpa, ref, childWidth);
            try c.y.setBinding(gpa, ref, childY);
            try c.height.setBinding(gpa, ref, childHeight);
        }
    }

    fn padding(self: *GridLayout, o: Orientation) layout.Padding {
        return switch (o) {
            .horizontal => .{ .begin = self.padding_left.get(), .end = self.padding_right.get() },
            .vertical => .{ .begin = self.padding_top.get(), .end = self.padding_bottom.get() },
        };
    }

    fn fillCells(self: *GridLayout, o: Orientation, cells: []layout.GridCell) void {
        var children = self.item.layoutChildren();
        var i: usize = 0;
        while (children.next()) |c| : (i += 1) {
            const p = self.cells[i];
            cells[i] = switch (o) {
                .horizontal => .{ .index = p.col, .span = p.colspan, .info = c.layoutInfo(.horizontal) },
                .vertical => .{ .index = p.row, .span = p.rowspan, .info = c.layoutInfo(.vertical) },
            };
        }
    }

    fn solveAlong(self: *GridLayout, o: Orientation, s: *Scratch) void {
        const data: layout.GridLayoutData = .{
            .size = if (o == .horizontal) self.item.width.get() else self.item.height.get(),
            .spacing = self.spacing.get(),
            .padding = self.padding(o),
        };
        self.fillCells(o, s.cells);
        layout.solveGrid(data, s.cells, s.tracks, s.track_out, s.out);
    }

    fn solveH(self: *GridLayout) void {
        self.solveAlong(.horizontal, &self.solve_h);
    }

    fn solveV(self: *GridLayout) void {
        self.solveAlong(.vertical, &self.solve_v);
    }

    fn infoAlong(self: *GridLayout, o: Orientation, s: *Scratch) LayoutInfo {
        const spacing = self.spacing.get();
        const pad = self.padding(o);
        self.fillCells(o, s.cells);
        return layout.gridLayoutInfo(s.cells, spacing, pad, s.tracks);
    }

    fn infoH(self: *GridLayout) LayoutInfo {
        return self.infoAlong(.horizontal, &self.info_h_scratch);
    }

    fn infoV(self: *GridLayout) LayoutInfo {
        return self.infoAlong(.vertical, &self.info_v_scratch);
    }

    fn cellSegment(ref: ChildRef(GridLayout), o: Orientation) Segment {
        const l = ref.layout;
        const seg = switch (o) {
            .horizontal => blk: {
                l.solved_h.get();
                break :blk l.solve_h.out[ref.index];
            },
            .vertical => blk: {
                l.solved_v.get();
                break :blk l.solve_v.out[ref.index];
            },
        };
        return layout.fitInSegment(seg, ref.child.layoutInfo(o));
    }

    fn childX(ref: ChildRef(GridLayout)) f32 {
        return cellSegment(ref, .horizontal).pos;
    }

    fn childWidth(ref: ChildRef(GridLayout)) f32 {
        return cellSegment(ref, .horizontal).size;
    }

    fn childY(ref: ChildRef(GridLayout)) f32 {
        return cellSegment(ref, .vertical).pos;
    }

    fn childHeight(ref: ChildRef(GridLayout)) f32 {
        return cellSegment(ref, .vertical).size;
    }

    const vtable: ItemVTable = .{ .name = "GridLayout", .layoutInfo = layoutInfo, .childrenChanged = childrenChanged, .is_layout = true };

    fn childrenChanged(i: *Item) void {
        const self = parentOf(GridLayout, i);
        const gpa = self.gpa orelse return;
        self.setup(gpa, self.slots.items) catch std.log.scoped(.zigulee).err("out of memory re-laying out children", .{});
    }

    fn layoutInfo(i: *Item, o: Orientation) LayoutInfo {
        const self = parentOf(GridLayout, i);
        if (self.arena == null) return .{};
        return if (o == .horizontal) self.info_h.get() else self.info_v.get();
    }
};

/// Replaces children's layout bindings with their current values, so they
/// do not reference a layout that is going away.
fn releaseChildGeometry(parent: *Item) void {
    var children = parent.layoutChildren();
    while (children.next()) |c| {
        c.x.set(c.x.getUntracked());
        c.y.set(c.y.getUntracked());
        c.width.set(c.width.getUntracked());
        c.height.set(c.height.getUntracked());
    }
}

/// A scrollable viewport (`Flickable`). Append the content to `content()`
/// and give it a size; the viewport's position is the scroll offset
/// (`viewport-x` / `viewport-y`, from 0 down to `size - content size`).
///
/// A press is passed to the content (so buttons inside still work), but
/// once the pointer moves past `drag_threshold` the flickable takes over
/// the gesture: the content receives `exit` and the view scrolls instead.
/// Releasing while moving continues with a decelerating flick. With
/// `snap_y`, scrolling settles on multiples of it (rows of a list, the
/// items of a tumbler), and the wheel moves by one.
pub const Flickable = struct {
    item: Item = .init(&vtable),
    viewport: Viewport = .{},
    interactive: Property(bool) = .init(true),
    /// Horizontal and vertical positions settle on multiples of these
    /// (0: anywhere), and on the content's ends.
    snap_x: Property(f32) = .init(0),
    snap_y: Property(f32) = .init(0),
    /// Positions settle where the content says (a list's rows, a table's
    /// columns: `ItemVTable.snapPosition`), and on its ends.
    snap_to_items: Property(bool) = .init(false),
    /// Dragged past its ends, the content follows less and less, and
    /// springs back when let go; a flick into an end overshoots it and
    /// settles.
    overscroll: Property(bool) = .init(true),
    /// Called when a flick (kinetic scroll after release) starts.
    flicked: Callback(fn () void) = .{},
    gpa: Allocator,
    drag: Drag = .{},
    /// Where a snapping animation is taking the viewport (wheel steps
    /// add up from there).
    heading_x: ?f32 = null,
    heading_y: ?f32 = null,
    /// Following the content's end (`scrollToBottom`): where the viewport
    /// was last sent.
    following_end: ?f32 = null,
    end_tracker: ChangeTracker(f32) = undefined,

    pub const drag_threshold = 8;
    pub const flick_duration_ms = 500;
    /// How far a flick travels, in ms worth of the release velocity.
    pub const flick_reach_ms = 300;

    const Drag = struct {
        state: enum { idle, pressed, dragging } = .idle,
        press_pos: Point = .{},
        press_viewport: Point = .{},
        last_pos: Point = .{},
        last_time: u64 = 0,
        /// Pixels per millisecond.
        velocity: Point = .{},
    };

    /// Initializes in place (the viewport is linked as a child).
    pub fn init(self: *Flickable, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.item.appendChild(&self.viewport.item);
        self.end_tracker.init(gpa, self, endY, endMoved);
    }

    pub fn deinit(self: *Flickable) void {
        self.end_tracker.deinit();
        self.viewport.deinit();
        self.interactive.deinit();
        self.snap_x.deinit();
        self.snap_y.deinit();
        self.snap_to_items.deinit();
        self.overscroll.deinit();
        self.item.deinit();
    }

    /// Scrolls to the top.
    pub fn scrollToTop(self: *Flickable) void {
        self.following_end = null;
        self.heading_y = 0;
        self.viewport.item.y.setAnimated(self.gpa, 0, snap_animation) catch self.viewport.item.y.set(0);
    }

    /// Scrolls to the bottom, and keeps there as the content's height
    /// changes (a list measuring the rows it had estimated, rows added)
    /// until scrolled elsewhere.
    pub fn scrollToBottom(self: *Flickable) void {
        const end = self.endY();
        self.following_end = end;
        self.heading_y = end;
        self.viewport.item.y.setAnimated(self.gpa, end, snap_animation) catch self.viewport.item.y.set(end);
    }

    /// The viewport's position at the content's bottom.
    fn endY(self: *Flickable) f32 {
        return @min(0, self.item.height.get() - self.viewport.item.height.get());
    }

    fn endMoved(self: *Flickable, end: f32) void {
        const was = self.following_end orelse return;
        // Scrolled elsewhere since (not on its way there, nor there).
        const y = &self.viewport.item.y;
        if (!y.hasBinding() and y.getUntracked() != was) {
            self.following_end = null;
            return;
        }
        self.following_end = end;
        self.heading_y = end;
        y.setAnimated(self.gpa, end, snap_animation) catch y.set(end);
    }

    /// The item that holds the scrolled content.
    pub fn content(self: *Flickable) *Item {
        return &self.viewport.item;
    }

    /// The content's item: counts the changes to its children (the
    /// instances of its `for`s and `if`s too), for what measures them.
    pub const Viewport = struct {
        item: Item = .init(&viewport_vtable),
        children_changes: Property(u32) = .init(0),

        pub fn deinit(self: *Viewport) void {
            self.children_changes.deinit();
            self.item.deinit();
        }

        const viewport_vtable: ItemVTable = .{ .name = "Empty", .childrenChanged = childrenChanged };

        fn childrenChanged(i: *Item) void {
            const self: *Viewport = @fieldParentPtr("item", i);
            self.children_changes.set(self.children_changes.getUntracked() +% 1);
        }
    };

    /// The viewport's height when not given: the visible layouts' in it
    /// (those of its `for`s and `if`s too), at least the view's. Follows
    /// them as they change, come, go, show and hide.
    pub fn fittedViewportHeight(self: *Flickable) f32 {
        return @max(self.item.height.get(), self.contentInfo(.vertical).preferred);
    }

    /// The viewport's width when not given: as `fittedViewportHeight`, but
    /// the layouts' minimum, so the content fills the view's width when it
    /// can and scrolls sideways only when it cannot.
    pub fn fittedViewportWidth(self: *Flickable) f32 {
        return @max(self.item.width.get(), self.contentInfo(.horizontal).min);
    }

    /// The visible layouts in the viewport, merged.
    fn contentInfo(self: *Flickable, o: Orientation) LayoutInfo {
        _ = self.viewport.children_changes.get();
        var info: LayoutInfo = .{};
        var children = self.viewport.item.layoutChildren();
        while (children.next()) |c| {
            if (c.vtable.is_layout and c.visible.get()) info = info.merge(c.layoutInfo(o));
        }
        return info.normalized();
    }

    pub fn viewportPosition(self: *Flickable) Point {
        return .{ .x = self.viewport.item.x.get(), .y = self.viewport.item.y.get() };
    }

    /// Scrolls to `p`, clamped to the content; stops any running flick.
    pub fn setViewportPosition(self: *Flickable, p: Point) void {
        const c = self.clamp(p);
        self.viewport.item.x.set(c.x);
        self.viewport.item.y.set(c.y);
    }

    fn clamp(self: *Flickable, p: Point) Point {
        const min_x = @min(0, self.item.width.get() - self.viewport.item.width.get());
        const min_y = @min(0, self.item.height.get() - self.viewport.item.height.get());
        return .{ .x = std.math.clamp(p.x, min_x, 0), .y = std.math.clamp(p.y, min_y, 0) };
    }

    fn beginPress(self: *Flickable, pos: Point) void {
        // Stopped where it is (pulled past an end too).
        const here = self.viewportPosition();
        self.viewport.item.x.set(here.x);
        self.viewport.item.y.set(here.y);
        self.following_end = null;
        self.heading_x = null;
        self.heading_y = null;
        self.drag = .{
            .state = .pressed,
            .press_pos = pos,
            .press_viewport = self.viewportPosition(),
            .last_pos = pos,
            .last_time = time.now(),
        };
    }

    fn exceedsThreshold(self: *Flickable, pos: Point) bool {
        const d = pos.sub(self.drag.press_pos);
        return @abs(d.x) > drag_threshold or @abs(d.y) > drag_threshold;
    }

    fn dragTo(self: *Flickable, pos: Point) void {
        // The velocity of the last movement, and when it was (a release
        // after a rest does not flick).
        const now = time.now();
        const d = pos.sub(self.drag.last_pos);
        if (d.x != 0 or d.y != 0) {
            if (now > self.drag.last_time) {
                const dt: f32 = @floatFromInt(now - self.drag.last_time);
                self.drag.velocity = .{ .x = d.x / dt, .y = d.y / dt };
            }
            self.drag.last_pos = pos;
            self.drag.last_time = now;
        }
        const to = self.drag.press_viewport.add(pos.sub(self.drag.press_pos));
        const c = self.clamp(to);
        if (!self.overscroll.get()) return self.setViewportPosition(c);
        // Past an end: following less and less (as far as the view's size
        // at most), along the directions it can be pulled.
        const pull_x = self.scrolls(.horizontal);
        const pull_y = self.scrolls(.vertical) or !pull_x;
        self.viewport.item.x.set(if (pull_x) c.x + rubber(to.x - c.x, self.item.width.get()) else c.x);
        self.viewport.item.y.set(if (pull_y) c.y + rubber(to.y - c.y, self.item.height.get()) else c.y);
    }

    /// Whether the content is larger than the view along `o`.
    fn scrolls(self: *Flickable, o: Orientation) bool {
        return if (o == .horizontal)
            self.viewport.item.width.get() > self.item.width.get() + 0.5
        else
            self.viewport.item.height.get() > self.item.height.get() + 0.5;
    }

    /// How far content dragged `over` past an end goes, in a view `size`
    /// long: about as far at first, then less and less, never `size`.
    fn rubber(over: f32, size: f32) f32 {
        if (over == 0 or size <= 0) return 0;
        const a = @abs(over);
        return std.math.sign(over) * (1 - 1 / (a * 0.55 / size + 1)) * size;
    }

    /// Settles on the nearest snap position, within the content's ends
    /// (back from past them), animated: what scrolling ends with (a
    /// scroll bar let go, say).
    pub fn settle(self: *Flickable) void {
        const target = self.snapped(self.viewportPosition());
        const here = self.viewportPosition();
        if (target.x == here.x and target.y == here.y) return;
        self.viewport.item.x.setAnimated(self.gpa, target.x, snap_animation) catch self.viewport.item.x.set(target.x);
        self.viewport.item.y.setAnimated(self.gpa, target.y, snap_animation) catch self.viewport.item.y.set(target.y);
        self.heading_x = target.x;
        self.heading_y = target.y;
    }

    fn startFlick(self: *Flickable) void {
        // No flick if the pointer rested before being released.
        const resting = time.now() - self.drag.last_time > 100;
        const v = self.drag.velocity;
        const moving = !resting and (@abs(v.x) >= 0.05 or @abs(v.y) >= 0.05);
        const reach: f32 = if (moving) flick_reach_ms else 0;
        const here = self.viewportPosition();
        const aim = here.add(.{ .x = v.x * reach, .y = v.y * reach });
        const target = self.snapped(aim);
        if (!moving and target.x == here.x and target.y == here.y) return;
        // A flick (overshooting an end it runs into, from inside), or
        // settling on the nearest snap position (back from past an end).
        const Animation = @import("animations.zig").Animation;
        const anim: Animation = .{ .duration_ms = if (moving) flick_duration_ms else snap_duration_ms, .easing = .ease_out_cubic };
        const bounce: Animation = .{ .duration_ms = flick_duration_ms, .easing = .ease_out_back };
        // Into an end: aimed past it, from inside and not already there.
        const inside = self.clamp(here);
        const aim_in = self.clamp(aim);
        const over = moving and self.overscroll.get();
        const ax = if (over and aim_in.x != aim.x and here.x == inside.x and here.x != target.x) bounce else anim;
        const ay = if (over and aim_in.y != aim.y and here.y == inside.y and here.y != target.y) bounce else anim;
        self.viewport.item.x.setAnimated(self.gpa, target.x, ax) catch return;
        self.viewport.item.y.setAnimated(self.gpa, target.y, ay) catch return;
        self.heading_x = target.x;
        self.heading_y = target.y;
        if (moving) self.flicked.call(.{});
    }

    pub const snap_duration_ms = 180;
    const snap_animation: @import("animations.zig").Animation = .{ .duration_ms = snap_duration_ms, .easing = .ease_out_cubic };

    /// `p` clamped, and on the nearest snap position.
    fn snapped(self: *Flickable, p: Point) Point {
        const c = self.clamp(p);
        return .{
            .x = if (self.snaps(.horizontal)) self.snapAlong(.horizontal, c.x, 0) else c.x,
            .y = if (self.snaps(.vertical)) self.snapAlong(.vertical, c.y, 0) else c.y,
        };
    }

    fn snaps(self: *Flickable, o: Orientation) bool {
        return self.snap_to_items.get() or (if (o == .horizontal) self.snap_x.get() else self.snap_y.get()) > 0;
    }

    /// Where scrolling along `o` settles from the viewport position `pos`
    /// (0 at the start, negative further along): the nearest snap position
    /// (`dir` 0), or the first past it further along (1) or back (-1).
    /// The content's two ends are snap positions too.
    fn snapAlong(self: *Flickable, o: Orientation, pos: f32, dir: i2) f32 {
        const horizontal = o == .horizontal;
        const view = if (horizontal) self.item.width.get() else self.item.height.get();
        const extent = if (horizontal) self.viewport.item.width.get() else self.viewport.item.height.get();
        const end = @max(0, extent - view);
        // How far along, as the content's coordinates.
        const at = std.math.clamp(-pos, 0, end);
        var best: ?f32 = null;
        best = layout.nearerSnap(best, 0, at, dir);
        best = layout.nearerSnap(best, end, at, dir);
        const step = if (horizontal) self.snap_x.get() else self.snap_y.get();
        if (step > 0) switch (dir) {
            0 => best = layout.nearerSnap(best, @round(at / step) * step, at, dir),
            1 => best = layout.nearerSnap(best, (@floor((at + 0.5) / step) + 1) * step, at, dir),
            else => best = layout.nearerSnap(best, (@ceil((at - 0.5) / step) - 1) * step, at, dir),
        };
        if (self.snap_to_items.get()) {
            var children = self.viewport.item.layoutChildren();
            while (children.next()) |c| {
                const f = c.vtable.snapPosition orelse continue;
                if (!c.visible.get()) continue;
                const offset = if (horizontal) c.x.get() else c.y.get();
                if (f(c, o, at - offset, dir)) |p| best = layout.nearerSnap(best, p + offset, at, dir);
            }
        }
        return -std.math.clamp(best orelse at, 0, end);
    }

    const vtable: ItemVTable = .{
        .name = "Flickable",
        .inputEventFilter = inputEventFilter,
        .inputEvent = inputEvent,
        .clipsChildren = clipsChildren,
    };

    fn clipsChildren(_: *Item) bool {
        return true;
    }

    fn inputEventFilter(i: *Item, event: input.PointerEvent, _: *Window) input.InputEventFilterResult {
        const self = parentOf(Flickable, i);
        if (!self.interactive.get()) return .forward_and_ignore;
        switch (event) {
            .pressed => |p| {
                if (p.button != .left) return .forward_and_ignore;
                self.beginPress(p.position);
                return .forward_and_intercept_grab;
            },
            .moved => |m| switch (self.drag.state) {
                .idle => return .forward_and_ignore,
                .pressed => {
                    if (!self.exceedsThreshold(m.position)) return .forward_and_intercept_grab;
                    self.drag.state = .dragging;
                    return .intercept;
                },
                .dragging => return .intercept,
            },
            .released => {
                if (self.drag.state == .dragging) return .intercept;
                // A press that stopped it (past an end, between snap
                // positions): settled.
                if (self.drag.state == .pressed) self.settle();
                self.drag.state = .idle;
                return .forward_and_ignore;
            },
            .wheel => return .forward,
            .exit => return .forward_and_ignore,
        }
    }

    fn inputEvent(i: *Item, event: input.PointerEvent, _: *Window) input.InputEventResult {
        const self = parentOf(Flickable, i);
        if (!self.interactive.get()) return .ignored;
        switch (event) {
            // The filter already recorded the press.
            .pressed => |p| return if (p.button == .left) .grab else .ignored,
            .moved => |m| {
                if (self.drag.state == .pressed and self.exceedsThreshold(m.position)) self.drag.state = .dragging;
                switch (self.drag.state) {
                    .idle => return .ignored,
                    .pressed => return .grab,
                    .dragging => {
                        self.dragTo(m.position);
                        return .grab;
                    },
                }
            },
            .released => |r| {
                if (self.drag.state == .dragging) {
                    self.dragTo(r.position);
                    self.startFlick();
                }
                self.drag.state = .idle;
                return .accepted;
            },
            .wheel => |w| {
                self.following_end = null;
                const free = self.clamp(self.viewportPosition().add(w.delta));
                inline for (.{ .{ "x", "heading_x", Orientation.horizontal }, .{ "y", "heading_y", Orientation.vertical } }) |axis| {
                    const d = @field(w.delta, axis[0]);
                    const prop = &@field(self.viewport.item, axis[0]);
                    if (d != 0) if (self.snaps(axis[2])) {
                        // A snap position a step, from the one it is on
                        // (or heading to).
                        const from = @field(self, axis[1]) orelse prop.getUntracked();
                        const to = self.snapAlong(axis[2], from, if (d > 0) -1 else 1);
                        prop.setAnimated(self.gpa, to, snap_animation) catch prop.set(to);
                        @field(self, axis[1]) = to;
                    } else prop.set(@field(free, axis[0]));
                }
                return .accepted;
            },
            .exit => return .accepted,
        }
    }
};
