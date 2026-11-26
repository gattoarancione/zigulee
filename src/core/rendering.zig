// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The interface between items and renderers, the recording renderer whose
//! display list rasterizers consume, and text measurement.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Size = geometry.Size;
const Rect = geometry.Rect;
const Affine = geometry.Affine;
const Projective = geometry.Projective;
const graphics = @import("graphics.zig");
const Brush = graphics.Brush;
const Color = graphics.Color;
const image = @import("image.zig");
const raster3d = @import("raster3d.zig");
const text_mod = @import("text/text.zig");
const effects = @import("item.zig").effects;
const text_bounds = @import("item.zig").text_bounds;
const Font = text_mod.Font;

pub const RectangleStyle = struct {
    background: Brush = .transparent,
    border_color: Brush = .transparent,
    border_width: f32 = 0,
    border_radius: f32 = 0,
};

/// A rectangle's shadow (`drop-shadow-*`): its rounded shape, blurred.
pub const ShadowStyle = struct {
    color: Color,
    /// As CSS's: twice the standard deviation of the Gaussian blur.
    blur: f32 = 0,
    border_radius: f32 = 0,

    /// How far past its shape the shadow shows (three deviations).
    pub fn reach(s: ShadowStyle) f32 {
        return @max(0, s.blur) * 1.5;
    }

    /// Where `box`'s shadow shows.
    pub fn ink(s: ShadowStyle, box: Rect) Rect {
        const e = s.reach();
        return .{ .x = box.x - e, .y = box.y - e, .width = box.width + 2 * e, .height = box.height + 2 * e };
    }
};

/// What of a layer shows (`LayerStyle.mask`): a rectangle (rounded by
/// `radius`), the inside of an SVG path, where an image is opaque, or where
/// the layer's first `commands` draw (an element's drawing), in the
/// coordinates `transform` maps to the window's (an element's own: rotated
/// with it); or, `inverted`, all but that.
pub const LayerMask = struct {
    /// The rectangle (in physical pixels once the commands are, as a
    /// command's `rect` with a `transform`).
    rect: Rect,
    transform: Affine,
    /// The rectangle's corner radius (scaled as the commands are).
    radius: f32 = 0,
    /// SVG path data in the element's coordinates, over `box` (borrowed
    /// from the element); empty: the rectangle.
    path: []const u8 = "",
    /// An image stretched over the rectangle: its alpha is how much shows
    /// (borrowed from the element).
    image: ?*const image.Image = null,
    /// How many of the layer's commands, first, draw the mask (an
    /// element's drawing: its alpha is how much shows) rather than what
    /// shows.
    commands: u32 = 0,
    inverted: bool = false,
    /// The mask's commands show by how bright they are (an SVG mask), not
    /// only by how opaque.
    luminance: bool = false,
    /// The element's bounds, in its coordinates: where the path's
    /// coordinates lie in `rect`.
    box: Rect = .empty,

    /// Where it can show, in the window (null: anywhere, a path's).
    pub fn bounds(m: LayerMask) ?Rect {
        if (m.path.len > 0 or m.commands > 0 or m.inverted) return null;
        return m.transform.mapRect(m.rect);
    }

    fn hash(m: LayerMask, h: *HashingRenderer) void {
        h.rect(m.rect);
        h.rect(m.box);
        h.float(m.radius);
        h.hasher.update(std.mem.asBytes(&m.commands));
        h.tag(@intFromBool(m.inverted));
        h.tag(@intFromBool(m.luminance));
        inline for (.{ m.transform.a, m.transform.b, m.transform.c, m.transform.d, m.transform.tx, m.transform.ty }) |f| h.float(f);
        h.hasher.update(m.path);
        if (m.image) |img| h.imageId(img.*) else h.tag(0);
    }
};

/// A layer (`DisplayList.Command.layer`): the commands after it, up to its
/// `end_layer`, drawn into an image of their own, which is blurred, then
/// drawn with the layer's opacity (an element and its children fading as
/// one), mapped by `projection` if it has one (tilted in depth), shown only
/// inside `mask` if it has one (a rotated clip, a `clip-path`).
pub const LayerStyle = struct {
    /// The blur's standard deviation (0: none).
    blur: f32 = 0,
    /// Where the image, drawn flat over the layer's `rect`, shows (window
    /// coordinates to window coordinates).
    projection: ?Projective = null,
    mask: ?LayerMask = null,
    /// How many commands it holds, nested layers' included (its
    /// `end_layer` follows them).
    count: u32 = 0,
    /// What they draw, hashed: a renderer can keep the image while it is
    /// the same.
    hash: u64 = 0,

    /// How far past what it holds the blur shows (three deviations).
    pub fn reach(s: LayerStyle) f32 {
        return 3 * @max(0, s.blur);
    }
};

/// `r` grown by `by` on every side.
pub fn grow(r: Rect, by: f32) Rect {
    if (by <= 0 or r.isEmpty()) return r;
    return .{ .x = r.x - by, .y = r.y - by, .width = r.width + 2 * by, .height = r.height + 2 * by };
}

pub const TextHorizontalAlignment = enum { left, center, right };
pub const TextVerticalAlignment = enum { top, center, bottom };
pub const TextWrap = enum { no_wrap, word_wrap };

pub const TextStyle = struct {
    /// Borrowed from the item; valid until the item's text changes.
    text: []const u8,
    /// Null: the text cannot be drawn (no font available).
    font: ?*const Font = null,
    color: Brush,
    font_size: f32,
    horizontal_alignment: TextHorizontalAlignment = .left,
    vertical_alignment: TextVerticalAlignment = .top,
    wrap: TextWrap = .no_wrap,
    /// Fonts for characters `font` lacks (`Window.addFallbackFont`).
    fallbacks: []const *const Font = &.{},
    overflow: TextOverflow = .clip,
    /// Pixels added after each character.
    letter_spacing: f32 = 0,
};

/// How a Text's font size follows its box (`font-size-mode`, as Qt's
/// `fontSizeMode`): the largest size up to `font-size`, down to
/// `minimum-font-size`, whose text fits.
pub const FontSizeMode = enum {
    /// `font-size` always.
    fixed,
    /// Its width (unwrapped text: wrapped text keeps to the width).
    horizontal_fit,
    /// Its height.
    vertical_fit,
    /// Both.
    fit,
};

/// What a line too long for its item shows (`overflow`).
pub const TextOverflow = enum {
    /// Cut at the item's edge.
    clip,
    /// Shortened with "…" ("Long tex…"). With word wrap, the last line that
    /// fits the height is, if more text follows.
    elide,
};

pub const ImageStyle = struct {
    image: image.Image,
    fit: image.ImageFit = .contain,
    rendering: image.ImageRendering = .smooth,
    /// Replaces the image's colors, keeping its alpha.
    colorize: ?Brush = null,
    /// Stretches only the middle of the image (implies `fit = .fill`).
    nine_slice: ?image.NineSlice = null,
    /// Drawn flat over the command's `rect`, then mapped by this (a layer
    /// tilted in depth; `fit` is `.fill`).
    projection: ?Projective = null,
    /// A 3D scene (`View3D`'s): drawn by the renderer over the command's
    /// `rect` if it can, else its picture (`image` only stands for it:
    /// its version changes with the scene).
    scene: ?*const raster3d.SceneSource = null,
};

pub const PathStyle = struct {
    /// SVG path data. Borrowed from the item.
    commands: []const u8,
    fill: Brush = .transparent,
    stroke: Brush = .transparent,
    stroke_width: f32 = 0,
    /// The area of path coordinates shown in the item, scaled uniformly
    /// and centered. Null: the path's own bounding box.
    viewbox: ?Rect = null,
    /// The viewbox stretched over the item (not scaled uniformly).
    stretch: bool = false,
    /// With a `viewbox`: the area of path coordinates that gradients
    /// span, mapped as the path is (an SVG drawing's whole viewBox). Null:
    /// they span the item.
    paint_box: ?Rect = null,
    /// The viewbox shrunk by half the stroke's width, keeping the stroke
    /// inside the item (paths drawn together, an SVG's, share their
    /// viewbox exactly instead).
    inset_stroke: bool = true,
};

/// What items draw into. Coordinates are relative to the current origin,
/// which the tree walk moves with `translate`. Items draw within their own
/// bounds (`size`), which keeps dirty-region tracking exact.
pub const ItemRenderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        drawRectangle: *const fn (*anyopaque, Size, RectangleStyle) void,
        drawText: *const fn (*anyopaque, Size, TextStyle) void,
        drawImage: *const fn (*anyopaque, Size, ImageStyle) void,
        drawPath: *const fn (*anyopaque, Size, PathStyle) void,
        /// The shadow of `box` (in the item's coordinates, outside its
        /// bounds as far as it is offset and blurred).
        drawShadow: *const fn (*anyopaque, Rect, ShadowStyle) void,
        translate: *const fn (*anyopaque, Point) void,
        /// Rotates or scales what follows (applied after the translations
        /// so far).
        transform: *const fn (*anyopaque, Affine) void,
        /// Intersects the clip with `rect`; false if nothing remains visible.
        /// Rotated, what follows until `restore` is drawn as a layer
        /// masked by it (with effects).
        clip: *const fn (*anyopaque, Rect) bool,
        /// Shows what follows, until `restore`, only inside SVG path data
        /// (in the current coordinates, over `size`; borrowed until the
        /// frame is drawn). Without effects, nothing is clipped.
        clipPath: *const fn (*anyopaque, Size, []const u8) void,
        /// Intersects the clip with `rect`, its corners rounded by
        /// `radius` (with effects; else square); false if nothing remains
        /// visible.
        clipRounded: *const fn (*anyopaque, Rect, f32) bool,
        /// Shows what follows, until `restore`, only where an image
        /// stretched over `size` is opaque, as much as it is (`inverted`:
        /// where it is not). Without effects, nothing is masked.
        maskImage: *const fn (*anyopaque, Size, *const image.Image, bool) void,
        /// As `maskImage`, by what is drawn from here to `endMaskShape`
        /// (an element's drawing, at full opacity; `luminance`: by its
        /// brightness), then what follows until `restore` shows through it.
        beginMaskShape: *const fn (*anyopaque, Size, bool, bool) void,
        endMaskShape: *const fn (*anyopaque) void,
        save: *const fn (*anyopaque) void,
        restore: *const fn (*anyopaque) void,
        /// Multiplies the opacity of everything drawn until `restore`.
        applyOpacity: *const fn (*anyopaque, f32) void,
        /// Draws what follows, until `endLayer`, as one image: blurred
        /// (`blur`: the standard deviation), then faded by `opacity`, and
        /// mapped by `projection` (in the current coordinates) if given.
        beginLayer: *const fn (*anyopaque, f32, f32, ?Projective) void,
        endLayer: *const fn (*anyopaque) void,
    };

    pub fn drawRectangle(r: ItemRenderer, size: Size, style: RectangleStyle) void {
        r.vtable.drawRectangle(r.ptr, size, style);
    }
    pub fn drawText(r: ItemRenderer, size: Size, style: TextStyle) void {
        r.vtable.drawText(r.ptr, size, style);
    }
    pub fn drawImage(r: ItemRenderer, size: Size, style: ImageStyle) void {
        // Not pixels (an SVG drawing, or nothing): only an Image draws it.
        const img = style.image;
        // A 3D scene's picture may be drawn only when asked for.
        if (style.scene == null and (img.pixels.len < @as(usize, img.width) * img.height or img.pixels.len == 0)) return;
        r.vtable.drawImage(r.ptr, size, style);
    }
    pub fn drawPath(r: ItemRenderer, size: Size, style: PathStyle) void {
        r.vtable.drawPath(r.ptr, size, style);
    }
    pub fn drawShadow(r: ItemRenderer, box: Rect, style: ShadowStyle) void {
        r.vtable.drawShadow(r.ptr, box, style);
    }
    pub fn transform(r: ItemRenderer, m: Affine) void {
        r.vtable.transform(r.ptr, m);
    }

    pub fn translate(r: ItemRenderer, by: Point) void {
        r.vtable.translate(r.ptr, by);
    }
    pub fn clip(r: ItemRenderer, rect: Rect) bool {
        return r.vtable.clip(r.ptr, rect);
    }
    pub fn clipPath(r: ItemRenderer, size: Size, path: []const u8) void {
        r.vtable.clipPath(r.ptr, size, path);
    }
    pub fn clipRounded(r: ItemRenderer, rect: Rect, radius: f32) bool {
        return r.vtable.clipRounded(r.ptr, rect, radius);
    }
    pub fn maskImage(r: ItemRenderer, size: Size, img: *const image.Image, inverted: bool) void {
        r.vtable.maskImage(r.ptr, size, img, inverted);
    }
    pub fn beginMaskShape(r: ItemRenderer, size: Size, inverted: bool, luminance: bool) void {
        r.vtable.beginMaskShape(r.ptr, size, inverted, luminance);
    }
    pub fn endMaskShape(r: ItemRenderer) void {
        r.vtable.endMaskShape(r.ptr);
    }
    pub fn save(r: ItemRenderer) void {
        r.vtable.save(r.ptr);
    }
    pub fn restore(r: ItemRenderer) void {
        r.vtable.restore(r.ptr);
    }
    pub fn applyOpacity(r: ItemRenderer, opacity: f32) void {
        r.vtable.applyOpacity(r.ptr, opacity);
    }
    pub fn beginLayer(r: ItemRenderer, opacity: f32, blur: f32, projection: ?Projective) void {
        r.vtable.beginLayer(r.ptr, opacity, blur, projection);
    }
    pub fn endLayer(r: ItemRenderer) void {
        r.vtable.endLayer(r.ptr);
    }
};

/// Where the lines of a text draw call of `size` show, in its coordinates:
/// the box of its lines as aligned, with half an em around for glyphs
/// reaching past their advance and their line (italics, accents) and a
/// pixel for hinting; within `size`, as text is cut to its item. All of
/// `size` for wrapped elided text (only the lines that fit show).
pub fn textInk(size: Size, s: TextStyle) Rect {
    const all: Rect = .fromOriginSize(.{}, size);
    const font = s.font orelse return .{};
    if (s.text.len == 0 or s.font_size <= 0) return .{};
    if (s.wrap == .word_wrap and s.overflow == .elide) return all;
    const metrics = text_mod.layout.Metrics.initFallbacks(font, s.fallbacks, s.font_size).withSpacing(s.letter_spacing);
    var lines: f32 = 0;
    var widest: f32 = 0;
    var it: text_mod.layout.LineIterator = .initMetrics(metrics, s.text, if (s.wrap == .word_wrap) size.width else null);
    while (it.next()) |l| {
        lines += 1;
        widest = @max(widest, l.width);
    }
    const block = font.lineHeight(s.font_size) * lines;
    const x = switch (s.horizontal_alignment) {
        .left => 0,
        .center => (size.width - widest) / 2,
        .right => size.width - widest,
    };
    const y = switch (s.vertical_alignment) {
        .top => 0,
        .center => (size.height - block) / 2,
        .bottom => size.height - block,
    };
    const m = s.font_size / 2 + 1;
    return (Rect{ .x = x - m, .y = y - m, .width = widest + 2 * m, .height = block + 2 * m }).intersection(all);
}

/// Hashes everything drawn through it. Dirty tracking uses this to tell
/// whether an item's appearance actually changed.
pub const HashingRenderer = struct {
    hasher: std.hash.Wyhash = .init(0),
    /// Number of draw calls seen.
    calls: usize = 0,
    /// What is drawn outside the item's bounds (shadows), in its
    /// coordinates; empty if nothing.
    overflow: Rect = .{},
    /// Text draw calls seen, and where their lines are (`textInk`).
    texts: if (text_bounds) usize else void = if (text_bounds) 0 else {},
    text_ink: if (text_bounds) Rect else void = if (text_bounds) .{} else {},
    /// Whether it translated, transformed or began a layer (then where
    /// text shows is not said by `text_ink`).
    moved: if (text_bounds) bool else void = if (text_bounds) false else {},

    pub fn renderer(self: *HashingRenderer) ItemRenderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn final(self: *HashingRenderer) u64 {
        return self.hasher.final();
    }

    /// Where it drew, in the item's coordinates, if it only drew text:
    /// the box of its lines, not the whole item. Null otherwise.
    pub fn textOnly(self: *const HashingRenderer) ?Rect {
        if (!text_bounds) return null;
        return if (self.calls > 0 and self.texts == self.calls and !self.moved) self.text_ink else null;
    }

    const vtable: ItemRenderer.VTable = .{
        .drawRectangle = drawRectangle,
        .drawText = drawText,
        .drawImage = drawImage,
        .drawPath = drawPath,
        .drawShadow = drawShadow,
        .translate = translate,
        .transform = transform,
        .clip = clip,
        .clipPath = clipPath,
        // Without effects, clips are square and nothing is masked (as
        // drawn).
        .clipRounded = if (effects) clipRounded else squareClip,
        .maskImage = if (effects) maskImage else DisplayList.noMaskImage,
        .beginMaskShape = if (effects) beginMaskShape else DisplayList.noMaskShape,
        .endMaskShape = if (effects) endMaskShape else DisplayList.noEnd,
        .save = save,
        .restore = restore,
        .applyOpacity = applyOpacity,
        .beginLayer = beginLayer,
        .endLayer = endLayer,
    };

    fn cast(p: *anyopaque) *HashingRenderer {
        return @ptrCast(@alignCast(p));
    }

    fn tag(self: *HashingRenderer, t: u8) void {
        self.hasher.update(&.{t});
    }

    fn float(self: *HashingRenderer, f: f32) void {
        self.hasher.update(&std.mem.toBytes(@as(u32, @bitCast(f))));
    }

    fn brush(self: *HashingRenderer, b: Brush) void {
        switch (b) {
            .solid => |c| self.hasher.update(&.{ 0, c.r, c.g, c.b, c.a }),
            .linear_gradient => |g| {
                self.tag(1);
                self.float(g.angle);
                self.stops(g.stops);
                if (g.line) |l| for (l) |pt| for (pt) |v| self.float(v);
            },
            .radial_gradient => |g| {
                self.tag(2);
                self.stops(g.stops);
                if (g.ellipse) |e| for ([_][2]f32{ e.center, e.radius }) |pt| for (pt) |v| self.float(v);
            },
        }
    }

    fn stops(self: *HashingRenderer, s: graphics.GradientStops) void {
        self.tag(@intCast(@min(s.items.len, 255)));
        for (s.slice()) |stop| {
            self.hasher.update(&.{ stop.color.r, stop.color.g, stop.color.b, stop.color.a });
            self.float(stop.position);
        }
    }

    fn rect(self: *HashingRenderer, r: Rect) void {
        inline for (.{ r.x, r.y, r.width, r.height }) |f| self.float(f);
    }

    /// Images compare by identity: the same pixels (or drawing) in the
    /// same version are the same image (a video's frames are versions).
    fn imageId(self: *HashingRenderer, img: image.Image) void {
        self.hasher.update(&std.mem.toBytes(@intFromPtr(img.pixels.ptr)));
        self.hasher.update(&std.mem.toBytes(@intFromPtr(img.vector)));
        self.hasher.update(&std.mem.toBytes(img.version));
        self.hasher.update(&std.mem.toBytes([2]u32{ img.width, img.height }));
    }

    fn drawImage(p: *anyopaque, size: Size, style: ImageStyle) void {
        const self = cast(p);
        self.calls += 1;
        self.tag(8);
        self.float(size.width);
        self.float(size.height);
        self.imageId(style.image);
        self.hasher.update(&.{ @intFromEnum(style.fit), @intFromEnum(style.rendering) });
        if (style.colorize) |c| self.brush(c) else self.tag(0);
        if (style.nine_slice) |n| self.hasher.update(&std.mem.toBytes([4]u32{ n.top, n.right, n.bottom, n.left })) else self.tag(0);
    }

    fn drawPath(p: *anyopaque, size: Size, style: PathStyle) void {
        const self = cast(p);
        self.calls += 1;
        self.tag(9);
        self.float(size.width);
        self.float(size.height);
        self.hasher.update(&std.mem.toBytes(style.commands.len));
        self.hasher.update(style.commands);
        self.brush(style.fill);
        self.brush(style.stroke);
        self.float(style.stroke_width);
        if (style.viewbox) |v| self.rect(v) else self.tag(0);
        if (style.paint_box) |v| self.rect(v) else self.tag(0);
        self.hasher.update(&.{ @intFromBool(style.stretch), @intFromBool(style.inset_stroke) });
    }

    fn drawShadow(p: *anyopaque, box: Rect, style: ShadowStyle) void {
        const self = cast(p);
        self.calls += 1;
        self.tag(11);
        self.rect(box);
        self.hasher.update(&.{ style.color.r, style.color.g, style.color.b, style.color.a });
        self.float(style.blur);
        self.float(style.border_radius);
        self.overflow = self.overflow.unionWith(style.ink(box));
    }

    fn drawRectangle(p: *anyopaque, size: Size, style: RectangleStyle) void {
        const self = cast(p);
        self.calls += 1;
        self.tag(1);
        self.float(size.width);
        self.float(size.height);
        self.brush(style.background);
        self.brush(style.border_color);
        self.float(style.border_width);
        self.float(style.border_radius);
    }

    fn drawText(p: *anyopaque, size: Size, style: TextStyle) void {
        const self = cast(p);
        self.calls += 1;
        if (text_bounds) {
            self.texts += 1;
            self.text_ink = self.text_ink.unionWith(textInk(size, style));
        }
        self.tag(2);
        self.float(size.width);
        self.float(size.height);
        self.hasher.update(&std.mem.toBytes(style.text.len));
        self.hasher.update(style.text);
        self.hasher.update(&std.mem.toBytes(@intFromPtr(style.font)));
        for (style.fallbacks) |f| self.hasher.update(&std.mem.toBytes(@intFromPtr(f)));
        self.brush(style.color);
        self.float(style.font_size);
        self.float(style.letter_spacing);
        self.hasher.update(&.{
            @intFromEnum(style.horizontal_alignment),
            @intFromEnum(style.vertical_alignment),
            @intFromEnum(style.wrap),
            @intFromEnum(style.overflow),
        });
    }

    fn translate(p: *anyopaque, by: Point) void {
        const self = cast(p);
        if (text_bounds) self.moved = true;
        self.tag(3);
        self.float(by.x);
        self.float(by.y);
    }

    fn transform(p: *anyopaque, m: Affine) void {
        const self = cast(p);
        if (text_bounds) self.moved = true;
        self.tag(10);
        inline for (.{ m.a, m.b, m.c, m.d, m.tx, m.ty }) |f| self.float(f);
    }

    fn clip(p: *anyopaque, r: Rect) bool {
        const self = cast(p);
        self.tag(4);
        self.rect(r);
        return true;
    }

    fn clipPath(p: *anyopaque, size: Size, path: []const u8) void {
        const self = cast(p);
        self.tag(14);
        self.float(size.width);
        self.float(size.height);
        self.hasher.update(path);
    }

    fn squareClip(p: *anyopaque, r: Rect, _: f32) bool {
        return clip(p, r);
    }

    fn clipRounded(p: *anyopaque, r: Rect, radius: f32) bool {
        const self = cast(p);
        self.tag(15);
        self.rect(r);
        self.float(radius);
        return true;
    }

    fn maskImage(p: *anyopaque, size: Size, img: *const image.Image, inverted: bool) void {
        const self = cast(p);
        self.tag(16);
        self.float(size.width);
        self.float(size.height);
        self.imageId(img.*);
        self.tag(@intFromBool(inverted));
    }

    fn beginMaskShape(p: *anyopaque, size: Size, inverted: bool, luminance: bool) void {
        const self = cast(p);
        self.tag(17);
        self.float(size.width);
        self.float(size.height);
        self.tag(@intFromBool(inverted));
        self.tag(@intFromBool(luminance));
    }

    fn endMaskShape(p: *anyopaque) void {
        cast(p).tag(18);
    }

    fn save(p: *anyopaque) void {
        cast(p).tag(5);
    }

    fn restore(p: *anyopaque) void {
        cast(p).tag(6);
    }

    fn applyOpacity(p: *anyopaque, opacity: f32) void {
        const self = cast(p);
        self.tag(7);
        self.float(opacity);
    }

    fn beginLayer(p: *anyopaque, opacity: f32, blur: f32, projection: ?Projective) void {
        const self = cast(p);
        if (text_bounds) self.moved = true;
        self.tag(12);
        self.float(opacity);
        self.float(blur);
        if (projection) |h| {
            for (h.m) |row| for (row) |f| self.float(f);
        } else self.tag(0);
    }

    fn endLayer(p: *anyopaque) void {
        cast(p).tag(13);
    }

    /// `commands` (a layer's), hashed: where they are and what they draw.
    fn hashCommands(commands: []const DisplayList.Command) u64 {
        var h: HashingRenderer = .{};
        for (commands) |cmd| {
            switch (cmd) {
                inline else => |c| {
                    h.rect(c.rect);
                    // Only where it cuts what is drawn: a clip bigger
                    // elsewhere (a turning layer's) draws the same pixels.
                    h.rect(c.clip.intersection(grow(reachOf(cmd), 1)));
                    h.float(c.opacity);
                    if (c.transform) |m| {
                        inline for (.{ m.a, m.b, m.c, m.d, m.tx, m.ty }) |f| h.float(f);
                    } else h.tag(0);
                },
            }
            switch (cmd) {
                .rectangle => |c| drawRectangle(&h, c.rect.size(), c.style),
                .text => |c| drawText(&h, c.rect.size(), c.style),
                .image => |c| drawImage(&h, c.rect.size(), c.style),
                .path => |c| drawPath(&h, c.rect.size(), c.style),
                .shadow => |c| drawShadow(&h, c.rect, c.style),
                .layer => |c| {
                    beginLayer(&h, c.opacity, c.style.blur, c.style.projection);
                    if (c.style.mask) |m| m.hash(&h) else h.tag(0);
                },
                .end_layer => endLayer(&h),
            }
        }
        return h.final();
    }
};

/// Where a command can draw (its clip aside), in the window; all of it for
/// layers.
fn reachOf(cmd: DisplayList.Command) Rect {
    return switch (cmd) {
        .layer, .end_layer => .{ .x = -1e9, .y = -1e9, .width = 2e9, .height = 2e9 },
        inline else => |c, tag| blk: {
            const local = if (tag == .shadow) c.style.ink(c.rect) else c.rect;
            break :blk if (c.transform) |m| m.mapRect(local) else local;
        },
    };
}

/// Records draw commands in window coordinates, dropping fully clipped ones.
pub const DisplayList = struct {
    gpa: Allocator,
    commands: std.ArrayList(Command) = .empty,
    stack: std.ArrayList(State) = .empty,
    state: State,
    /// The window's (`init`, `reset`): what layers tilted in depth keep of
    /// their flat drawing (none without effects).
    bounds: if (effects) Rect else void,
    /// The layers being recorded.
    layers: std.ArrayList(OpenLayer) = .empty,
    /// Set if a command could not be recorded.
    out_of_memory: bool = false,

    /// `opacity` is the product of the enclosing items' opacities, up to
    /// the layer the command is in, if any (the layer's image is drawn
    /// with the rest).
    pub const Command = union(enum) {
        rectangle: Draw(RectangleStyle),
        text: Draw(TextStyle),
        image: Draw(ImageStyle),
        path: Draw(PathStyle),
        /// `rect` is the shape the shadow blurs; it shows past it by
        /// `style.reach()`.
        shadow: Draw(ShadowStyle),
        /// The next `style.count` commands, then `end_layer`, drawn into an
        /// image covering `rect` (what they draw, and the blur's reach),
        /// which is drawn within `clip` with `opacity`. The commands' clips
        /// reach past `clip` by the blur's reach: the blur takes in what is
        /// around.
        layer: Draw(LayerStyle),
        end_layer: Draw(void),

        /// A draw call in window coordinates: `rect` is the item's bounds.
        /// With a `transform` (an item rotated or scaled), `rect` is in the
        /// coordinates it maps to the window's; `clip` is always the
        /// window's.
        pub fn Draw(comptime Style: type) type {
            return struct { rect: Rect, clip: Rect, opacity: f32, style: Style, transform: ?Affine = null };
        }
    };

    /// Where the coordinates are (`matrix`: to the window's), the clip and
    /// the opacity.
    const State = struct { matrix: Affine = .identity, clip: Rect, opacity: f32 = 1 };

    /// A layer being recorded: where it starts (its `layer` command). A
    /// mask's ends at the `restore` of the state it began in (`depth`: how
    /// many states were saved then).
    const OpenLayer = struct { start: usize, mask_depth: ?usize = null, rounded: ?Rounded = null };

    /// A clip with rounded corners, square to the window: what follows
    /// (from `start`, no layer of its own) is split once recorded, only
    /// its corners masked (`closeRounded`).
    const Rounded = struct { rect: Rect, matrix: Affine, radius: f32, clip: Rect };

    pub fn init(gpa: Allocator, bounds: Rect) DisplayList {
        return .{ .gpa = gpa, .state = .{ .clip = bounds }, .bounds = if (effects) bounds else {} };
    }

    pub fn deinit(self: *DisplayList) void {
        self.commands.deinit(self.gpa);
        self.stack.deinit(self.gpa);
        self.layers.deinit(self.gpa);
    }

    /// Clears recorded commands and resets the clip to `bounds`.
    pub fn reset(self: *DisplayList, bounds: Rect) void {
        self.commands.clearRetainingCapacity();
        self.stack.clearRetainingCapacity();
        self.layers.clearRetainingCapacity();
        self.state = .{ .clip = bounds };
        if (effects) self.bounds = bounds;
        self.out_of_memory = false;
    }

    pub fn renderer(self: *DisplayList) ItemRenderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: ItemRenderer.VTable = .{
        .drawRectangle = drawRectangle,
        .drawText = drawText,
        .drawImage = drawImage,
        .drawPath = drawPath,
        .drawShadow = drawShadow,
        .translate = translate,
        .transform = transform,
        .clip = clip,
        .clipPath = if (effects) clipPath else noClipPath,
        .clipRounded = if (effects) clipRounded else squareClip,
        .maskImage = if (effects) maskImage else noMaskImage,
        .beginMaskShape = if (effects) beginMaskShape else noMaskShape,
        .endMaskShape = if (effects) endMaskShape else noEnd,
        .save = save,
        .restore = restore,
        .applyOpacity = applyOpacity,
        // Without effects nothing is drawn as a layer (and the code to
        // record them is left out).
        .beginLayer = if (effects) beginLayer else noLayer,
        .endLayer = if (effects) endLayer else noEnd,
    };

    fn noLayer(_: *anyopaque, _: f32, _: f32, _: ?Projective) void {}
    fn noClipPath(_: *anyopaque, _: Size, _: []const u8) void {}
    fn noMaskImage(_: *anyopaque, _: Size, _: *const image.Image, _: bool) void {}
    fn noMaskShape(_: *anyopaque, _: Size, _: bool, _: bool) void {}
    fn squareClip(p: *anyopaque, rect: Rect, _: f32) bool {
        return clip(p, rect);
    }
    fn noEnd(_: *anyopaque) void {}

    fn cast(p: *anyopaque) *DisplayList {
        return @ptrCast(@alignCast(p));
    }

    /// Where a draw call of `size` goes: its rect, and the transform (only
    /// if not a translation), or null if it is clipped out.
    fn absolute(self: *DisplayList, size: Size) ?struct { Rect, ?Affine } {
        const local = Rect.fromOriginSize(.{}, size);
        return self.absoluteRect(local, local);
    }

    /// Where `local` goes, drawn over `ink` (its bounds, or more).
    fn absoluteRect(self: *DisplayList, local: Rect, ink: Rect) ?struct { Rect, ?Affine } {
        const m = self.state.matrix;
        if (m.isTranslation()) {
            if (!ink.translate(m.offset()).intersects(self.state.clip)) return null;
            return .{ local.translate(m.offset()), null };
        }
        if (!m.mapRect(ink).intersects(self.state.clip)) return null;
        return .{ local, m };
    }

    fn push(self: *DisplayList, cmd: Command) void {
        self.commands.append(self.gpa, cmd) catch {
            self.out_of_memory = true;
        };
    }

    fn drawRectangle(p: *anyopaque, size: Size, style: RectangleStyle) void {
        const self = cast(p);
        const at = self.absolute(size) orelse return;
        self.push(.{ .rectangle = .{ .rect = at[0], .clip = self.state.clip, .opacity = self.state.opacity, .style = style, .transform = at[1] } });
    }

    fn drawText(p: *anyopaque, size: Size, style: TextStyle) void {
        const self = cast(p);
        const at = self.absolute(size) orelse return;
        self.push(.{ .text = .{ .rect = at[0], .clip = self.state.clip, .opacity = self.state.opacity, .style = style, .transform = at[1] } });
    }

    fn drawImage(p: *anyopaque, size: Size, style: ImageStyle) void {
        const self = cast(p);
        const at = self.absolute(size) orelse return;
        self.push(.{ .image = .{ .rect = at[0], .clip = self.state.clip, .opacity = self.state.opacity, .style = style, .transform = at[1] } });
    }

    fn drawPath(p: *anyopaque, size: Size, style: PathStyle) void {
        const self = cast(p);
        const at = self.absolute(size) orelse return;
        self.push(.{ .path = .{ .rect = at[0], .clip = self.state.clip, .opacity = self.state.opacity, .style = style, .transform = at[1] } });
    }

    fn drawShadow(p: *anyopaque, box: Rect, style: ShadowStyle) void {
        const self = cast(p);
        const at = self.absoluteRect(box, style.ink(box)) orelse return;
        self.push(.{ .shadow = .{ .rect = at[0], .clip = self.state.clip, .opacity = self.state.opacity, .style = style, .transform = at[1] } });
    }

    fn translate(p: *anyopaque, by: Point) void {
        const self = cast(p);
        self.state.matrix = self.state.matrix.mul(Affine.translation(by));
    }

    fn transform(p: *anyopaque, m: Affine) void {
        const self = cast(p);
        self.state.matrix = self.state.matrix.mul(m);
    }

    /// Clips to `rect`: rotated, what follows is masked by it (with
    /// effects), within its bounding box.
    fn clip(p: *anyopaque, rect: Rect) bool {
        const self = cast(p);
        const m = self.state.matrix;
        const bounds = self.state.clip.intersection(m.mapRect(rect));
        if (effects and !bounds.isEmpty() and !axisAligned(m)) self.beginMask(.{ .rect = rect, .transform = m, .box = rect });
        self.state.clip = bounds;
        return !self.state.clip.isEmpty();
    }

    /// Whether `m` keeps rectangles rectangles (no rotation but quarter
    /// turns).
    fn axisAligned(m: Affine) bool {
        return (m.b == 0 and m.c == 0) or (m.a == 0 and m.d == 0);
    }

    fn clipPath(p: *anyopaque, size: Size, path: []const u8) void {
        const self = cast(p);
        if (path.len == 0) return;
        const box = Rect.fromOriginSize(.{}, size);
        self.beginMask(.{ .rect = box, .transform = self.state.matrix, .path = path, .box = box });
    }

    /// Clips to `rect` with rounded corners. Rotated, what follows is a
    /// layer masked by it; else only what reaches into the corners is
    /// (when the clip's state is restored).
    fn clipRounded(p: *anyopaque, rect: Rect, radius: f32) bool {
        const self = cast(p);
        const r = @min(radius, rect.width / 2, rect.height / 2);
        if (!(r > 0)) return clip(p, rect);
        const m = self.state.matrix;
        const bounds = self.state.clip.intersection(m.mapRect(rect));
        if (bounds.isEmpty()) {
            self.state.clip = bounds;
            return false;
        }
        if (!axisAligned(m)) {
            self.beginMask(.{ .rect = rect, .transform = m, .radius = r, .box = rect });
            self.state.clip = bounds;
            return true;
        }
        self.state.clip = bounds;
        self.layers.append(self.gpa, .{
            .start = self.commands.items.len,
            .mask_depth = self.stack.items.len,
            .rounded = .{ .rect = rect, .matrix = m, .radius = r, .clip = bounds },
        }) catch {
            self.out_of_memory = true;
        };
        return true;
    }

    fn maskImage(p: *anyopaque, size: Size, img: *const image.Image, inverted: bool) void {
        const self = cast(p);
        const box = Rect.fromOriginSize(.{}, size);
        self.beginMask(.{ .rect = box, .transform = self.state.matrix, .image = img, .box = box, .inverted = inverted });
    }

    /// Begins a mask whose shape is drawn next (at full opacity, in a
    /// state of its own), until `endMaskShape`.
    fn beginMaskShape(p: *anyopaque, size: Size, inverted: bool, luminance: bool) void {
        const self = cast(p);
        const box = Rect.fromOriginSize(.{}, size);
        self.beginMask(.{ .rect = box, .transform = self.state.matrix, .box = box, .inverted = inverted, .luminance = luminance });
        save(p);
        self.state.opacity = 1;
    }

    /// The commands since `beginMaskShape` are the mask's.
    fn endMaskShape(p: *anyopaque) void {
        const self = cast(p);
        // Its layer, begun in the state before (unless out of memory).
        if (self.layers.items.len > 0 and self.layers.items[self.layers.items.len - 1].mask_depth == self.stack.items.len -| 1) {
            const start = self.layers.items[self.layers.items.len - 1].start;
            if (start < self.commands.items.len and self.commands.items[start] == .layer) {
                if (self.commands.items[start].layer.style.mask) |*m| m.commands = @intCast(self.commands.items.len - start - 1);
            }
        }
        restore(p);
    }

    /// Starts a layer masked by `mask`, ended by the `restore` of the
    /// current state.
    fn beginMask(self: *DisplayList, mask: LayerMask) void {
        self.layers.append(self.gpa, .{ .start = self.commands.items.len, .mask_depth = self.stack.items.len }) catch {
            self.out_of_memory = true;
            return;
        };
        self.push(.{ .layer = .{ .rect = .empty, .clip = self.state.clip, .opacity = 1, .style = .{ .mask = mask } } });
    }

    fn applyOpacity(p: *anyopaque, opacity: f32) void {
        const self = cast(p);
        self.state.opacity *= opacity;
    }

    fn beginLayer(p: *anyopaque, opacity: f32, blur: f32, projection: ?Projective) void {
        const self = cast(p);
        // The blur in window pixels (an ancestor's scale scales it).
        const m = self.state.matrix;
        const deviation = blur * @sqrt(@abs(m.a * m.d - m.b * m.c));
        // The mapping between window coordinates.
        const h = if (projection) |pr| pr.conjugate(m) else null;
        self.layers.append(self.gpa, .{ .start = self.commands.items.len }) catch {
            self.out_of_memory = true;
            return;
        };
        self.push(.{ .layer = .{ .rect = .empty, .clip = self.state.clip, .opacity = self.state.opacity * opacity, .style = .{ .blur = deviation, .projection = h } } });
        save(p);
        // Inside, things are drawn as they are (the image is faded), and
        // around the clip as far as the blur takes them in; mapped, what
        // the window shows of the flat drawing: not what the clip does, or
        // a partial frame's image, cut to the part redrawn, would be
        // sampled otherwise than a full frame's.
        self.state.opacity = 1;
        if (effects) if (h) |hh| {
            self.state.clip = flatClip(hh, self.bounds);
        };
        self.state.clip = grow(self.state.clip, (LayerStyle{ .blur = deviation }).reach());
    }

    /// What `h` maps into `clip`, as a box (all that is in front of the
    /// viewer when the clip's corners are not all).
    fn flatClip(h: Projective, within: Rect) Rect {
        const huge: Rect = .{ .x = -1e5, .y = -1e5, .width = 2e5, .height = 2e5 };
        const inv = h.inverse() orelse return .empty;
        return (inv.mapRect(within) orelse huge).intersection(huge);
    }

    fn endLayer(p: *anyopaque) void {
        const self = cast(p);
        // The masks begun inside end first.
        restore(p);
        const open = self.layers.pop() orelse return;
        self.closeLayer(open.start);
    }

    /// Ends the layer begun at `start`: its bounds, what it holds, its
    /// `end_layer` (or nothing, if it shows nothing).
    fn closeLayer(self: *DisplayList, start: usize) void {
        if (start >= self.commands.items.len or self.commands.items[start] != .layer) return;
        const inner = self.commands.items[start + 1 ..];
        const layer = &self.commands.items[start].layer;
        // An element's drawing masking it: what shows is within it.
        const shape_len = if (layer.style.mask) |m| @min(m.commands, inner.len) else 0;
        var ink: Rect = .empty;
        for (inner[shape_len..]) |cmd| ink = ink.unionWith(inkOf(cmd));
        if (shape_len > 0 and !layer.style.mask.?.inverted) {
            var shape: Rect = .empty;
            for (inner[0..shape_len]) |cmd| shape = shape.unionWith(inkOf(cmd));
            ink = ink.intersection(shape);
        }
        const reach = layer.style.reach();
        const flat_clip = if (!effects) layer.clip else if (layer.style.projection) |h| flatClip(h, self.bounds) else layer.clip;
        ink = grow(ink, reach).intersection(grow(flat_clip, reach));
        if (layer.style.mask) |m| if (m.bounds()) |b| {
            ink = ink.intersection(b);
        };
        // Nothing to show: no layer.
        if (ink.isEmpty() or !layerInk(ink, layer.clip, layer.style.projection).intersects(layer.clip)) {
            self.commands.shrinkRetainingCapacity(start);
            return;
        }
        layer.rect = ink;
        layer.style.count = @intCast(inner.len);
        layer.style.hash = HashingRenderer.hashCommands(inner);
        if (layer.style.mask) |m| {
            var h: HashingRenderer = .{ .hasher = .init(layer.style.hash) };
            m.hash(&h);
            layer.style.hash = h.final();
        }
        const end: Command = .{ .end_layer = .{ .rect = ink, .clip = layer.clip, .opacity = layer.opacity, .style = {} } };
        self.push(end);
    }

    /// Where a layer whose image lies flat over `rect` shows, in `clip`.
    fn layerInk(rect: Rect, within: Rect, projection: ?Projective) Rect {
        const h = projection orelse return rect.intersection(within);
        return (h.mapRect(rect) orelse within).intersection(within);
    }

    /// Where `cmd` draws, in the window.
    fn inkOf(cmd: Command) Rect {
        return switch (cmd) {
            .end_layer => .empty,
            .layer => |c| layerInk(c.rect, c.clip, c.style.projection),
            inline else => |c, tag| blk: {
                const local = if (tag == .shadow) c.style.ink(c.rect) else c.rect;
                const box = if (c.transform) |m| m.mapRect(local) else local;
                break :blk box.intersection(c.clip);
            },
        };
    }

    fn save(p: *anyopaque) void {
        const self = cast(p);
        self.stack.append(self.gpa, self.state) catch {
            self.out_of_memory = true;
        };
    }

    fn restore(p: *anyopaque) void {
        const self = cast(p);
        if (self.stack.pop()) |s| self.state = s;
        // The masks begun in the state left (none without effects: the
        // code to end them is left out).
        if (effects) while (self.layers.items.len > 0) {
            const top = self.layers.items[self.layers.items.len - 1];
            const depth = top.mask_depth orelse break;
            if (depth <= self.stack.items.len) break;
            _ = self.layers.pop();
            if (top.rounded) |r| self.closeRounded(top.start, r) else self.closeLayer(top.start);
        };
    }

    /// Ends a rounded clip begun at `start`: what reaches into its corners
    /// is recorded again, for the rest of the clip as it was, and for each
    /// corner as a layer masked by the rounded rectangle (small images,
    /// not one of the whole clip).
    fn closeRounded(self: *DisplayList, start: usize, c: Rounded) void {
        if (start >= self.commands.items.len) return;
        const box = c.matrix.mapRect(c.rect);
        const rx = @min(c.radius * box.width / c.rect.width, box.width / 2);
        const ry = @min(c.radius * box.height / c.rect.height, box.height / 2);
        const corners = [4]Rect{
            .{ .x = box.x, .y = box.y, .width = rx, .height = ry },
            .{ .x = box.right() - rx, .y = box.y, .width = rx, .height = ry },
            .{ .x = box.x, .y = box.bottom() - ry, .width = rx, .height = ry },
            .{ .x = box.right() - rx, .y = box.bottom() - ry, .width = rx, .height = ry },
        };
        for (corners) |corner| {
            if (reaches(self.commands.items[start..], corner.intersection(c.clip))) break;
        } else return;
        const inner = self.gpa.dupe(Command, self.commands.items[start..]) catch {
            self.out_of_memory = true;
            return;
        };
        defer self.gpa.free(inner);
        self.commands.shrinkRetainingCapacity(start);
        // The rest: a cross of three rectangles, drawn as before.
        const cross = [3]Rect{
            .{ .x = box.x + rx, .y = box.y, .width = box.width - 2 * rx, .height = box.height },
            .{ .x = box.x, .y = box.y + ry, .width = rx, .height = box.height - 2 * ry },
            .{ .x = box.right() - rx, .y = box.y + ry, .width = rx, .height = box.height - 2 * ry },
        };
        for (cross) |piece| self.appendClipped(inner, piece.intersection(c.clip));
        const mask: LayerMask = .{ .rect = c.rect, .transform = c.matrix, .radius = c.radius, .box = c.rect };
        for (corners) |corner| {
            const within = corner.intersection(c.clip);
            if (!reaches(inner, within)) continue;
            const at = self.commands.items.len;
            self.push(.{ .layer = .{ .rect = .empty, .clip = within, .opacity = 1, .style = .{ .mask = mask } } });
            self.appendClipped(inner, within);
            self.closeLayer(at);
        }
    }

    /// Whether any of `commands` draws in `area`.
    fn reaches(commands: []const Command, area: Rect) bool {
        if (area.isEmpty()) return false;
        for (commands) |cmd| if (inkOf(cmd).intersects(area)) return true;
        return false;
    }

    /// Appends those of `commands` that draw in `area`, clipped to it (a
    /// layer only where its image shows: what it holds is drawn as before,
    /// the same image).
    fn appendClipped(self: *DisplayList, commands: []const Command, area: Rect) void {
        if (area.isEmpty()) return;
        var i: usize = 0;
        while (i < commands.len) : (i += 1) {
            const cmd = commands[i];
            if (cmd == .layer) {
                const n = cmd.layer.style.count + 2;
                const range = commands[i..@min(i + n, commands.len)];
                i += range.len - 1;
                if (!inkOf(cmd).intersects(area)) continue;
                const at = self.commands.items.len;
                self.commands.appendSlice(self.gpa, range) catch {
                    self.out_of_memory = true;
                    return;
                };
                const copy = self.commands.items[at..];
                copy[0].layer.clip = copy[0].layer.clip.intersection(area);
                if (copy[copy.len - 1] == .end_layer) copy[copy.len - 1].end_layer.clip = copy[0].layer.clip;
                continue;
            }
            if (cmd == .end_layer or !inkOf(cmd).intersects(area)) continue;
            var copy = cmd;
            switch (copy) {
                inline else => |*d| d.clip = d.clip.intersection(area),
            }
            self.push(copy);
        }
    }
};

/// Measures text for layout: with a font's metrics, or `approximate` when
/// no font is available.
pub const TextMeasurer = struct {
    ctx: ?*anyopaque = null,
    measureFn: *const fn (?*anyopaque, text: []const u8, font_size: f32, max_width: ?f32) Size,

    pub fn measure(self: TextMeasurer, text: []const u8, font_size: f32, max_width: ?f32) Size {
        return self.measureFn(self.ctx, text, font_size, max_width);
    }

    /// Each code point is 0.6 em wide, lines are 1.2 em tall, and wrapping
    /// breaks anywhere.
    pub const approximate: TextMeasurer = .{ .measureFn = approximateMeasure };

    /// Measures with `font`, which must outlive the measurer.
    pub fn fromFont(font: *const Font) TextMeasurer {
        return .{ .ctx = @ptrCast(@constCast(font)), .measureFn = fontMeasure };
    }
};

fn fontMeasure(ctx: ?*anyopaque, s: []const u8, font_size: f32, max_width: ?f32) Size {
    const font: *const Font = @ptrCast(@alignCast(ctx.?));
    return text_mod.measure(font, s, font_size, max_width);
}

fn approximateMeasure(_: ?*anyopaque, text: []const u8, font_size: f32, max_width: ?f32) Size {
    const char_width = 0.6 * font_size;
    const line_height = 1.2 * font_size;
    var width: f32 = 0;
    var lines: f32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const chars: f32 = @floatFromInt(std.unicode.utf8CountCodepoints(line) catch line.len);
        const line_width = chars * char_width;
        if (max_width) |mw| if (mw > 0 and line_width > mw) {
            lines += @ceil(line_width / mw);
            width = @max(width, mw);
            continue;
        };
        lines += 1;
        width = @max(width, line_width);
    }
    return .{ .width = width, .height = lines * line_height };
}

const testing = std.testing;

test "display list records clipped commands in window coordinates" {
    var dl: DisplayList = .init(testing.allocator, .{ .width = 100, .height = 100 });
    defer dl.deinit();
    const r = dl.renderer();
    r.save();
    r.translate(.{ .x = 10, .y = 10 });
    r.drawRectangle(.{ .width = 20, .height = 20 }, .{ .background = .color(.black) });
    try testing.expect(r.clip(.{ .width = 5, .height = 5 }));
    r.drawText(.{ .width = 50, .height = 10 }, .{ .text = "hi", .color = .color(.black), .font_size = 10 });
    r.translate(.{ .x = 50, .y = 0 });
    r.drawRectangle(.{ .width = 5, .height = 5 }, .{}); // outside the clip: dropped
    r.applyOpacity(0.5);
    r.restore();
    r.drawRectangle(.{ .width = 1, .height = 1 }, .{});

    try testing.expectEqual(@as(usize, 3), dl.commands.items.len);
    try testing.expectEqual(Rect{ .x = 10, .y = 10, .width = 20, .height = 20 }, dl.commands.items[0].rectangle.rect);
    try testing.expectEqual(Rect{ .x = 10, .y = 10, .width = 5, .height = 5 }, dl.commands.items[1].text.clip);
    try testing.expectEqual(Rect{ .width = 100, .height = 100 }, dl.commands.items[2].rectangle.clip);
    try testing.expectEqual(@as(f32, 1), dl.commands.items[2].rectangle.opacity); // restored
}

test "hashing renderer distinguishes draw calls" {
    var a: HashingRenderer = .{};
    var b: HashingRenderer = .{};
    var c: HashingRenderer = .{};
    a.renderer().drawRectangle(.{ .width = 1, .height = 1 }, .{ .background = .color(.black) });
    b.renderer().drawRectangle(.{ .width = 1, .height = 1 }, .{ .background = .color(.black) });
    c.renderer().drawRectangle(.{ .width = 1, .height = 1 }, .{ .background = .color(.white) });
    try testing.expectEqual(a.final(), b.final());
    try testing.expect(a.final() != c.final());
    try testing.expectEqual(@as(usize, 1), a.calls);
}

test "approximate text measurement" {
    const m = TextMeasurer.approximate;
    try testing.expectEqual(Size{ .width = 30, .height = 12 }, m.measure("hello", 10, null));
    try testing.expectEqual(Size{ .width = 30, .height = 24 }, m.measure("hello\nhi", 10, null));
    try testing.expectEqual(Size{ .width = 18, .height = 24 }, m.measure("hello", 10, 18));
}
