// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The GPU renderer's frame builder: turns a window's display list into
//! one vertex buffer of quads for a single shader (shader.zig), plus the
//! textures it samples. It needs no GPU, so it is tested on its own
//! (reference.zig runs frames on the CPU).
//!
//! - Rectangles (rounded, with borders) are shaded exactly in the shader,
//!   from their signed distance, like the software renderer.
//! - Glyphs and path masks are rasterized on the CPU, with the software
//!   renderer's code, into a coverage atlas (one channel), and cached.
//! - Gradients are sampled from a texture with a row per gradient.
//! - Images are textures of their own (the executor uploads and caches
//!   them by identity, as `Image.eql`).
//!
//! Clips are per vertex, so the whole frame batches into few draws: a new
//! one only when the image texture changes.
//!
//! A partial frame has only what intersects the area that changed
//! (`Frame.full` false, `Frame.region`): the executor keeps the previous
//! frame, clears that area and draws over it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/core.zig");
const Rect = core.Rect;
const Brush = core.Brush;
const Rgba8 = core.Rgba8;
const rendering = core.rendering;
const DisplayList = rendering.DisplayList;
const Command = DisplayList.Command;
const path = core.path;
const Font = core.Font;
const software = @import("../software/software.zig");
const raster = @import("../software/raster.zig");
const PixelRect = software.PixelRect;
const GlyphCache = software.GlyphCache;

/// One corner of a quad. Everything but `pos` and `uv` is the same for the
/// quad's four corners.
pub const Vertex = extern struct {
    /// Window position, in physical pixels.
    pos: [2]f32,
    /// Atlas texel (coverage) or normalized image coordinates.
    uv: [2]f32,
    /// The shape (and the paint's geometry): x, y, width, height.
    rect: [4]f32,
    /// Corner radius, border width, inner radius, `Kind`.
    shape: [4]f32,
    /// Pixels drawn: x0, y0, x1, y1 (whole pixels).
    clip: [4]f32,
    /// A solid paint (premultiplied, times the opacity), or the opacity
    /// in all four for other paints.
    color: [4]f32,
    /// `PaintType`, gradient row (texture y), direction x, y.
    paint: [4]f32,
    /// The position in the shape's coordinates: `pos` itself, or before
    /// the item's rotation and scale. Shapes and paints are computed from
    /// it (clips from `pos`).
    local: [2]f32,
    /// To a multiple of 16 bytes (Metal's float4 alignment: its vertex
    /// struct has the same layout).
    _pad: [2]f32 = .{ 0, 0 },
};

pub const Kind = enum(u8) {
    /// A rounded rectangle, less its inside past the border width.
    rect = 0,
    /// The inside of a rounded rectangle's border.
    rect_inner = 1,
    /// Coverage from the atlas.
    coverage = 2,
    /// An image, as is.
    image = 3,
    /// The paint, where the image is opaque.
    image_colorize = 4,
    /// A rounded rectangle's shadow: corner radius, blur deviation.
    shadow = 5,
};

pub const PaintType = enum(u8) { solid = 0, linear = 1, radial = 2 };

/// A 3D scene the executor draws into the texture of `Frame.images[image]`
/// (`width` x `height` pixels), when it draws 3D (`Batcher.gpu_scenes`).
pub const SceneDraw = struct {
    image: u32,
    source: *const core.raster3d.SceneSource,
    width: u32,
    height: u32,
};

/// Consecutive quads drawn with the same image texture.
pub const Draw = struct {
    /// First index, and how many.
    first: u32,
    count: u32,
    /// Index into `Frame.images`, or null.
    image: ?u32 = null,
    /// Bilinear filtering of the image (else nearest).
    smooth: bool = true,
};

pub const atlas_size = 1024;
/// Path masks: positions rounded as `software.pathOrigin` does, stored in
/// tiles of at most `path_tile` texels square.
const path_tile = 256;
pub const gradient_width = 256;
pub const gradient_rows = 256;

/// What the GPU draws for one frame. Valid until the next `build`.
pub const Frame = struct {
    width: u32,
    height: u32,
    /// The whole frame is drawn; else only `region` is.
    full: bool = true,
    /// What this frame redraws, in whole pixels (empty: nothing changed).
    region: core.Region = .{},
    vertices: []const Vertex,
    indices: []const u32,
    draws: []const Draw,
    images: []const core.Image,
    /// The images that are 3D scenes, for executors that draw them.
    scenes: []const SceneDraw = &.{},
    /// The coverage atlas (`atlas_size` squared, one byte per texel), and
    /// its rows changed since the last frame: [first, end).
    atlas: []const u8,
    atlas_dirty: [2]u32,
    /// Gradient rows (`gradient_width` premultiplied RGBA texels each),
    /// `gradient_count` of them used.
    gradients: []const u8,
    gradient_count: u32,
};

const AtlasEntry = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    /// Offset of the bitmap from the pen (glyphs) or the path's position.
    left: i32,
    top: i32,
};

/// A shelf packer over the coverage atlas.
const Atlas = struct {
    pixels: []u8 = &.{},
    shelves: std.ArrayList(Shelf) = .empty,
    next_y: u32 = padding,
    dirty: [2]u32 = .{ 0, 0 },

    const Shelf = struct { y: u32, height: u32, x: u32 };
    const padding = 1;

    fn deinit(a: *Atlas, gpa: Allocator) void {
        gpa.free(a.pixels);
        a.shelves.deinit(gpa);
    }

    fn clear(a: *Atlas) void {
        a.shelves.clearRetainingCapacity();
        a.next_y = padding;
        @memset(a.pixels, 0);
        a.dirty = .{ 0, atlas_size };
    }

    /// Room for `w` x `h` texels; null when full. Entries have a texel of
    /// nothing all around (the atlas's edges too): sampled between texels
    /// (rotated glyphs), they blend with nothing, wherever they are.
    fn alloc(a: *Atlas, gpa: Allocator, w: u32, h: u32) Allocator.Error!?[2]u32 {
        if (w + 2 * padding > atlas_size or h + 2 * padding > atlas_size) return null;
        for (a.shelves.items) |*s| {
            if (h <= s.height and h * 2 >= s.height and s.x + w + padding <= atlas_size) {
                const at = .{ s.x, s.y };
                s.x += w + padding;
                return at;
            }
        }
        if (a.next_y + h + padding > atlas_size) return null;
        try a.shelves.append(gpa, .{ .y = a.next_y, .height = h, .x = padding + w + padding });
        const at = .{ padding, a.next_y };
        a.next_y += h + padding;
        return at;
    }

    fn write(a: *Atlas, at: [2]u32, w: u32, h: u32, coverage: []const u8) void {
        for (0..h) |row| @memcpy(a.pixels[(at[1] + row) * atlas_size + at[0] ..][0..w], coverage[row * w ..][0..w]);
        if (a.dirty[0] == a.dirty[1]) a.dirty = .{ at[1], at[1] + h } else a.dirty = .{ @min(a.dirty[0], at[1]), @max(a.dirty[1], at[1] + h) };
    }
};

/// Builds frames. Keeps its caches (atlas, glyphs, path masks) between
/// frames.
pub const Batcher = struct {
    /// The transform of the command being built (null: none), and its
    /// clip in the window.
    xf: ?core.Affine = null,
    xf_clip: PixelRect = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },
    /// The mapping of the image being built (a layer tilted in depth),
    /// clipped by `xf_clip` too.
    proj: ?core.Projective = null,
    gpa: Allocator,
    /// Physical pixels per logical pixel.
    scale_factor: f32 = 1,
    display_list: DisplayList,
    vertices: std.ArrayList(Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,
    draws: std.ArrayList(Draw) = .empty,
    images: std.ArrayList(core.Image) = .empty,
    atlas: Atlas = .{},
    glyph_map: std.AutoHashMapUnmanaged(GlyphCache.Key, AtlasEntry) = .empty,
    path_map: std.AutoHashMapUnmanaged(PathKey, AtlasEntry) = .empty,
    gradients: []u8 = &.{},
    gradient_count: u32 = 0,
    gradient_map: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    // Scratch for rasterizing.
    glyphs: GlyphCache = .{},
    path_commands: std.ArrayList(path.Command) = .empty,
    polylines: path.Polylines = .{},
    mask: raster.Mask = .{},
    coverage: std.ArrayList(u8) = .empty,
    /// Set when the atlas filled up during this frame.
    atlas_full: bool = false,
    /// Draws layers into images (textures), as the software renderer does.
    layers: software.layers.Layers,
    /// The executor draws 3D scenes itself (`Frame.scenes`); else their
    /// pictures are drawn on the CPU.
    gpu_scenes: bool = false,
    scenes: std.ArrayList(SceneDraw) = .empty,

    /// A path mask is stored in tiles (`piece` 0, 1, ...: a large one
    /// would not fit the atlas, or would take a shelf of its own).
    const PathKey = struct { hash: u64, stroke: bool, piece: u16 = 0 };

    pub fn init(gpa: Allocator) Allocator.Error!Batcher {
        var b: Batcher = .{ .gpa = gpa, .display_list = .init(gpa, .empty), .layers = .init(gpa) };
        errdefer b.deinit();
        b.atlas.pixels = try gpa.alloc(u8, atlas_size * atlas_size);
        b.atlas.clear();
        b.gradients = try gpa.alloc(u8, gradient_width * gradient_rows * 4);
        return b;
    }

    pub fn deinit(b: *Batcher) void {
        const gpa = b.gpa;
        b.display_list.deinit();
        b.vertices.deinit(gpa);
        b.indices.deinit(gpa);
        b.draws.deinit(gpa);
        b.images.deinit(gpa);
        b.atlas.deinit(gpa);
        b.glyph_map.deinit(gpa);
        b.path_map.deinit(gpa);
        gpa.free(b.gradients);
        b.gradient_map.deinit(gpa);
        b.glyphs.deinit(gpa);
        b.path_commands.deinit(gpa);
        b.polylines.deinit(gpa);
        b.mask.deinit(gpa);
        b.coverage.deinit(gpa);
        b.layers.deinit();
        b.scenes.deinit(b.gpa);
    }

    /// The window, `width` x `height` physical pixels: all of it, or (in
    /// `.partial` mode) what changed since the last frame.
    pub fn build(b: *Batcher, window: *core.Window, width: u32, height: u32, mode: core.RenderMode) Allocator.Error!Frame {
        b.display_list.reset(.fromOriginSize(.{}, window.size()));
        const logical = try window.renderAt(b.display_list.renderer(), mode, b.scale_factor);
        if (b.display_list.out_of_memory) return error.OutOfMemory;
        if (b.scale_factor != 1) for (b.display_list.commands.items) |*cmd| software.scaleCommand(cmd, b.scale_factor);
        var frame = try b.buildCommands(b.display_list.commands.items, width, height);
        frame.full = mode == .full;
        // In physical pixels: the pixels whose centers are inside, as the
        // draw calls are clipped. The region is cleared before it is drawn,
        // so it must be what is drawn, no more: rounded outward, adjacent
        // rectangles would overlap at a fractional scale and merge into
        // their bounding box, cleared and left empty around them.
        const bounds: core.Rect = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
        frame.region = .{};
        for (logical.slice()) |r| {
            const px = PixelRect.centersIn(software.scaleRect(r, b.scale_factor));
            const p = (core.Rect{ .x = @floatFromInt(px.x0), .y = @floatFromInt(px.y0), .width = @floatFromInt(px.x1 - px.x0), .height = @floatFromInt(px.y1 - px.y0) }).intersection(bounds);
            if (!p.isEmpty()) frame.region.add(p);
        }
        if (frame.full) frame.region = if (bounds.isEmpty()) .{} else blk: {
            var all: core.Region = .{};
            all.add(bounds);
            break :blk all;
        };
        return frame;
    }

    /// `commands` in physical pixels.
    pub fn buildCommands(b: *Batcher, all: []const Command, width: u32, height: u32) Allocator.Error!Frame {
        b.xf = null;
        b.proj = null;
        b.layers.newFrame();
        const commands = try b.layers.flatten(all, b.scale_factor);
        // A full atlas is cleared and the frame built again (once; if it
        // is still full, what fitted is kept: the frame draws from it).
        for (0..2) |attempt| {
            if (attempt == 1) {
                b.atlas.clear();
                b.glyph_map.clearRetainingCapacity();
                b.path_map.clearRetainingCapacity();
            }
            b.atlas_full = false;
            b.vertices.clearRetainingCapacity();
            b.indices.clearRetainingCapacity();
            b.draws.clearRetainingCapacity();
            b.images.clearRetainingCapacity();
            b.scenes.clearRetainingCapacity();
            b.gradient_map.clearRetainingCapacity();
            b.gradient_count = 0;
            const bounds: PixelRect = .{ .x0 = 0, .y0 = 0, .x1 = @intCast(width), .y1 = @intCast(height) };
            for (commands) |*cmd| switch (cmd.*) {
                .image => |*i| if (i.style.projection) |h| {
                    try b.projected(i, h, bounds);
                } else if (i.transform) |m| {
                    try b.transformed(i, m, bounds);
                } else try b.image(i, bounds),
                inline else => |*c| if (c.transform) |m| {
                    try b.transformed(c, m, bounds);
                } else switch (cmd.*) {
                    .rectangle => |*r| try b.rectangle(r, bounds),
                    .text => |*t| try b.text(t, bounds),
                    .image => |*i| try b.image(i, bounds),
                    .path => |*p| try b.pathCommand(p, bounds),
                    .shadow => |*s| try b.shadow(s, bounds),
                    // Drawn as images (`layers.flatten`).
                    .layer, .end_layer => {},
                },
            };
            if (!b.atlas_full) break;
        }
        const dirty = b.atlas.dirty;
        b.atlas.dirty = .{ 0, 0 };
        return .{
            .width = width,
            .height = height,
            .vertices = b.vertices.items,
            .indices = b.indices.items,
            .draws = b.draws.items,
            .images = b.images.items,
            .scenes = b.scenes.items,
            .atlas = b.atlas.pixels,
            .atlas_dirty = dirty,
            .gradients = b.gradients,
            .gradient_count = b.gradient_count,
        };
    }

    /// A rotated or scaled command: built in its own coordinates (where
    /// the window's bounds and clip map to their bounding boxes), its quads'
    /// corners transformed to the window, clipped by the window's clip.
    fn transformed(b: *Batcher, c: anytype, m: core.Affine, bounds: PixelRect) Allocator.Error!void {
        const inv = m.inverse() orelse return;
        const window_clip = PixelRect.centersIn(c.clip).intersect(bounds);
        if (window_clip.isEmpty()) return;
        const clip_rect: Rect = .{ .x = @floatFromInt(window_clip.x0), .y = @floatFromInt(window_clip.y0), .width = @floatFromInt(window_clip.width()), .height = @floatFromInt(window_clip.height()) };
        var local = c.*;
        local.transform = null;
        // In its coordinates: the clip's bounding box, a pixel more.
        const back = inv.mapRect(clip_rect);
        local.clip = .{ .x = back.x - 1, .y = back.y - 1, .width = back.width + 2, .height = back.height + 2 };
        const local_bounds = PixelRect.touching(local.clip);
        b.xf = m;
        b.xf_clip = window_clip;
        defer b.xf = null;
        switch (@TypeOf(c.*)) {
            Command.Draw(rendering.RectangleStyle) => try b.rectangle(&local, local_bounds),
            Command.Draw(rendering.TextStyle) => try b.text(&local, local_bounds),
            Command.Draw(rendering.ImageStyle) => try b.image(&local, local_bounds),
            Command.Draw(rendering.PathStyle) => try b.pathCommand(&local, local_bounds),
            Command.Draw(rendering.ShadowStyle) => try b.shadow(&local, local_bounds),
            else => unreachable,
        }
    }

    /// An image mapped by `h` (a layer tilted in depth): built flat, in
    /// the part the window's clip shows, its quads cut into cells whose
    /// corners are mapped (each cell then almost affine).
    fn projected(b: *Batcher, c: *const Command.Draw(rendering.ImageStyle), h: core.Projective, bounds: PixelRect) Allocator.Error!void {
        const window_clip = PixelRect.centersIn(c.clip).intersect(bounds);
        if (window_clip.isEmpty()) return;
        const inv = h.inverse() orelse return;
        const clip_rect: Rect = .{ .x = @floatFromInt(window_clip.x0), .y = @floatFromInt(window_clip.y0), .width = @floatFromInt(window_clip.width()), .height = @floatFromInt(window_clip.height()) };
        var local = c.*;
        local.style.projection = null;
        // In its flat coordinates: what the clip shows of it, a pixel more.
        const back = inv.mapRect(clip_rect) orelse c.rect;
        local.clip = rendering.grow(back, 1).intersection(c.rect);
        if (local.clip.isEmpty()) return;
        b.proj = h;
        b.xf_clip = window_clip;
        defer b.proj = null;
        try b.image(&local, PixelRect.touching(local.clip));
    }

    // ---- Quads ----

    const Quad = struct {
        /// Where it is drawn.
        area: Rect,
        /// Texture coordinates at the area's top-left and bottom-right.
        uv0: [2]f32 = .{ 0, 0 },
        uv1: [2]f32 = .{ 0, 0 },
        rect: Rect,
        shape: [4]f32,
        clip: PixelRect,
        color: [4]f32,
        paint: [4]f32 = .{ 0, 0, 0, 0 },
    };

    /// The side of the cells a mapped quad is cut into, in its flat
    /// coordinates (each cell is drawn as if affine).
    const cell_size = 16;

    fn quad(b: *Batcher, q: Quad, texture: ?u32, smooth: bool) Allocator.Error!void {
        if (q.clip.isEmpty() or q.area.width <= 0 or q.area.height <= 0) return;
        if (b.proj == null) return b.cell(q, q.area, q.uv0, q.uv1, texture, smooth);
        // Mapped: in the cells of a grid fixed in its flat coordinates,
        // those the clip reaches. Whatever part of it the clip shows (a
        // partial frame's), its pixels are drawn as a full frame draws
        // them.
        const reach = q.area.intersection(.{ .x = @floatFromInt(q.clip.x0), .y = @floatFromInt(q.clip.y0), .width = @floatFromInt(q.clip.width()), .height = @floatFromInt(q.clip.height()) });
        if (reach.isEmpty()) return;
        const uv = struct {
            fn at(qq: Quad, x: f32, y: f32) [2]f32 {
                return .{
                    qq.uv0[0] + (qq.uv1[0] - qq.uv0[0]) * (x - qq.area.x) / qq.area.width,
                    qq.uv0[1] + (qq.uv1[1] - qq.uv0[1]) * (y - qq.area.y) / qq.area.height,
                };
            }
        }.at;
        var y = @floor(reach.y / cell_size) * cell_size;
        while (y < reach.bottom()) : (y += cell_size) {
            var x = @floor(reach.x / cell_size) * cell_size;
            while (x < reach.right()) : (x += cell_size) {
                const area = q.area.intersection(.{ .x = x, .y = y, .width = cell_size, .height = cell_size });
                if (area.isEmpty()) continue;
                try b.cell(q, area, uv(q, area.x, area.y), uv(q, area.right(), area.bottom()), texture, smooth);
            }
        }
    }

    /// The part `area` of quad `q` (`uv0`, `uv1` at its corners), its
    /// corners transformed or mapped to the window.
    fn cell(b: *Batcher, q: Quad, area: Rect, uv0: [2]f32, uv1: [2]f32, texture: ?u32, smooth: bool) Allocator.Error!void {
        // Transformed or mapped: clipped by the window's clip (q.clip is in
        // its own coordinates), glyphs sampled smoothly.
        const turned = b.xf != null or b.proj != null;
        const a = if (turned) b.xf_clip else q.clip;
        var shape = q.shape;
        if (turned and shape[3] == @as(f32, @floatFromInt(@intFromEnum(Kind.coverage)))) shape[2] = 1;
        const corners = [4][2]f32{ .{ area.x, area.y }, .{ area.right(), area.y }, .{ area.right(), area.bottom() }, .{ area.x, area.bottom() } };
        const uvs = [4][2]f32{ uv0, .{ uv1[0], uv0[1] }, uv1, .{ uv0[0], uv1[1] } };
        var positions: [4][2]f32 = undefined;
        for (corners, &positions) |corner, *pos| {
            const p: core.Point = .{ .x = corner[0], .y = corner[1] };
            pos.* = if (b.proj) |h| blk: {
                // Behind the viewer: not drawn.
                const m = h.apply(p) orelse return;
                break :blk .{ m.x, m.y };
            } else if (b.xf) |m| blk: {
                const t = m.apply(p);
                break :blk .{ t.x, t.y };
            } else corner;
        }
        const base: u32 = @intCast(b.vertices.items.len);
        try b.vertices.ensureUnusedCapacity(b.gpa, 4);
        for (corners, uvs, positions) |corner, uv, pos| {
            b.vertices.appendAssumeCapacity(.{
                .pos = pos,
                .uv = uv,
                .rect = .{ q.rect.x, q.rect.y, q.rect.width, q.rect.height },
                .shape = shape,
                .clip = .{ @floatFromInt(a.x0), @floatFromInt(a.y0), @floatFromInt(a.x1), @floatFromInt(a.y1) },
                .color = q.color,
                .paint = q.paint,
                .local = corner,
            });
        }
        try b.indices.appendSlice(b.gpa, &.{ base, base + 1, base + 2, base, base + 2, base + 3 });
        if (b.draws.items.len > 0) {
            const last = &b.draws.items[b.draws.items.len - 1];
            if (last.image == texture and (texture == null or last.smooth == smooth)) {
                last.count += 6;
                return;
            }
        }
        try b.draws.append(b.gpa, .{ .first = @intCast(b.indices.items.len - 6), .count = 6, .image = texture, .smooth = smooth });
    }

    /// The vertex color and paint for `brush` over `shape`.
    fn paint(b: *Batcher, brush: *const Brush, shape: Rect, opacity: f32) Allocator.Error!struct { [4]f32, [4]f32 } {
        switch (brush.*) {
            .solid => |c| {
                const p = c.premultiplied();
                return .{ .{
                    @as(f32, @floatFromInt(p.r)) / 255 * opacity,
                    @as(f32, @floatFromInt(p.g)) / 255 * opacity,
                    @as(f32, @floatFromInt(p.b)) / 255 * opacity,
                    @as(f32, @floatFromInt(p.a)) / 255 * opacity,
                }, .{ 0, 0, 0, 0 } };
            },
            .linear_gradient => |g| {
                const row = try b.gradientRow(g.stops) orelse return b.paint(&.{ .solid = middle(g.stops) }, shape, opacity);
                const axis = software.paintGeometry(brush.*, shape).axis;
                return .{ @splat(opacity), .{ @floatFromInt(@intFromEnum(PaintType.linear)), row, axis[0], axis[1] } };
            },
            .radial_gradient => |g| {
                const row = try b.gradientRow(g.stops) orelse return b.paint(&.{ .solid = middle(g.stops) }, shape, opacity);
                const axis = software.paintGeometry(brush.*, shape).axis;
                return .{ @splat(opacity), .{ @floatFromInt(@intFromEnum(PaintType.radial)), row, axis[0], axis[1] } };
            },
        }
    }

    fn middle(stops: core.GradientStops) core.Color {
        const c = stops.sample(0.5);
        if (c.a == 0) return .transparent;
        return .{ .r = @intCast(@min(255, @as(u32, c.r) * 255 / c.a)), .g = @intCast(@min(255, @as(u32, c.g) * 255 / c.a)), .b = @intCast(@min(255, @as(u32, c.b) * 255 / c.a)), .a = c.a };
    }

    /// The texture y of the gradient's row (the same stops share one);
    /// null when this frame has no rows left.
    fn gradientRow(b: *Batcher, stops: core.GradientStops) Allocator.Error!?f32 {
        var h: std.hash.Wyhash = .init(0);
        for (stops.slice()) |s| {
            h.update(&.{ s.color.r, s.color.g, s.color.b, s.color.a });
            h.update(std.mem.asBytes(&s.position));
        }
        const key = h.final();
        const row = b.gradient_map.get(key) orelse blk: {
            if (b.gradient_count == gradient_rows) return null;
            const r = b.gradient_count;
            b.gradient_count += 1;
            const texels = b.gradients[r * gradient_width * 4 ..][0 .. gradient_width * 4];
            for (0..gradient_width) |i| {
                const c = stops.sample(@as(f32, @floatFromInt(i)) / (gradient_width - 1));
                texels[i * 4 ..][0..4].* = .{ c.r, c.g, c.b, c.a };
            }
            try b.gradient_map.put(b.gpa, key, r);
            break :blk r;
        };
        return (@as(f32, @floatFromInt(row)) + 0.5) / gradient_rows;
    }

    // ---- Draw calls ----

    fn rectangle(b: *Batcher, cmd: *const Command.Draw(rendering.RectangleStyle), bounds: PixelRect) Allocator.Error!void {
        const s = &cmd.style;
        const r = cmd.rect;
        const pixels = PixelRect.touching(r).intersect(PixelRect.centersIn(cmd.clip)).intersect(bounds);
        if (pixels.isEmpty()) return;
        const radius = @min(s.border_radius, r.width / 2, r.height / 2);
        const bw = @min(s.border_width, r.width / 2, r.height / 2);
        const has_border = bw > 0 and !s.border_color.isTransparent();
        const area: Rect = .{ .x = @floatFromInt(pixels.x0), .y = @floatFromInt(pixels.y0), .width = @floatFromInt(pixels.width()), .height = @floatFromInt(pixels.height()) };
        const inner_radius = @max(0, radius - bw);
        if (!s.background.isTransparent()) {
            const color, const p = try b.paint(&s.background, r, cmd.opacity);
            const kind: Kind = if (has_border) .rect_inner else .rect;
            try b.quad(.{ .area = area, .rect = r, .shape = .{ radius, if (has_border) bw else 0, inner_radius, @floatFromInt(@intFromEnum(kind)) }, .clip = pixels, .color = color, .paint = p }, null, true);
        }
        if (has_border) {
            const color, const p = try b.paint(&s.border_color, r, cmd.opacity);
            try b.quad(.{ .area = area, .rect = r, .shape = .{ radius, bw, inner_radius, @floatFromInt(@intFromEnum(Kind.rect)) }, .clip = pixels, .color = color, .paint = p }, null, true);
        }
    }

    fn shadow(b: *Batcher, cmd: *const Command.Draw(rendering.ShadowStyle), bounds: PixelRect) Allocator.Error!void {
        const s = &cmd.style;
        const r = cmd.rect;
        const pixels = PixelRect.touching(s.ink(r)).intersect(PixelRect.centersIn(cmd.clip)).intersect(bounds);
        if (pixels.isEmpty()) return;
        const radius = @min(s.border_radius, r.width / 2, r.height / 2);
        const area: Rect = .{ .x = @floatFromInt(pixels.x0), .y = @floatFromInt(pixels.y0), .width = @floatFromInt(pixels.width()), .height = @floatFromInt(pixels.height()) };
        const color, _ = try b.paint(&.{ .solid = s.color }, r, cmd.opacity);
        try b.quad(.{ .area = area, .rect = r, .shape = .{ radius, @max(0, s.blur) / 2, 0, @floatFromInt(@intFromEnum(Kind.shadow)) }, .clip = pixels, .color = color }, null, true);
    }

    fn image(b: *Batcher, cmd: *const Command.Draw(rendering.ImageStyle), bounds: PixelRect) Allocator.Error!void {
        const s = &cmd.style;
        var img = s.image;
        // A 3D scene: drawn by the executor at the size it shows, or its
        // picture drawn on the CPU.
        var scene_size: ?[2]u32 = null;
        if (s.scene) |sc| {
            if (b.gpu_scenes) {
                const m = if (b.xf) |x| @sqrt(@abs(x.a * x.d - x.b * x.c)) else 1;
                scene_size = .{
                    @intFromFloat(std.math.clamp(@ceil(cmd.rect.width * m), 1, 4096)),
                    @intFromFloat(std.math.clamp(@ceil(cmd.rect.height * m), 1, 4096)),
                };
                img.width = scene_size.?[0];
                img.height = scene_size.?[1];
            } else img = sc.picture() orelse return;
        }
        if (img.width == 0 or img.height == 0) return;
        const r = cmd.rect;
        const dest = software.imageDest(s, r, b.scale_factor) orelse return;
        const clip = PixelRect.centersIn(cmd.clip).intersect(bounds);
        if (clip.isEmpty()) return;
        const index: u32 = for (b.images.items, 0..) |other, i| {
            if (scene_size == null and other.eql(img)) break @intCast(i);
        } else blk: {
            try b.images.append(b.gpa, img);
            break :blk @intCast(b.images.items.len - 1);
        };
        if (scene_size) |sz| try b.scenes.append(b.gpa, .{ .image = index, .source = s.scene.?, .width = sz[0], .height = sz[1] });
        var color: [4]f32 = @splat(cmd.opacity);
        var p: [4]f32 = .{ 0, 0, 0, 0 };
        var kind: Kind = .image;
        if (s.colorize) |*c| {
            color, p = try b.paint(c, r, cmd.opacity);
            kind = .image_colorize;
        }
        const smooth = s.rendering == .smooth;
        const iw: f32 = @floatFromInt(img.width);
        const ih: f32 = @floatFromInt(img.height);
        const shape: [4]f32 = .{ 0, 0, 0, @floatFromInt(@intFromEnum(kind)) };
        // The pixels whose centers are inside, as the software renderer
        // rounds them (GPUs break ties at edges the other way).
        const pixels = PixelRect.centersIn(dest.intersection(r));
        if (pixels.isEmpty()) return;
        const snapped: Rect = .{ .x = @floatFromInt(pixels.x0), .y = @floatFromInt(pixels.y0), .width = @floatFromInt(pixels.width()), .height = @floatFromInt(pixels.height()) };
        if (s.nine_slice) |n| {
            // Nine pieces, split at the pixels where the software renderer's
            // piecewise mapping changes, each mapped linearly.
            const xs = slicePieces(dest.x, dest.width, iw, n.left, n.right, b.scale_factor, pixels.x0, pixels.x1);
            const ys = slicePieces(dest.y, dest.height, ih, n.top, n.bottom, b.scale_factor, pixels.y0, pixels.y1);
            for (ys) |py| for (xs) |px| {
                if (px.end <= px.start or py.end <= py.start) continue;
                try b.quad(.{
                    .area = .{ .x = @floatFromInt(px.start), .y = @floatFromInt(py.start), .width = @floatFromInt(px.end - px.start), .height = @floatFromInt(py.end - py.start) },
                    .uv0 = .{ px.src0 / iw, py.src0 / ih },
                    .uv1 = .{ px.src1 / iw, py.src1 / ih },
                    .rect = r,
                    .shape = shape,
                    .clip = clip,
                    .color = color,
                    .paint = p,
                }, index, smooth);
            };
            return;
        }
        if (software.imageTile(s, dest, b.scale_factor)) |t| {
            // A quad for each tile shown, over the pixels whose centers
            // are in it.
            const visible = pixels.intersect(clip);
            if (visible.isEmpty()) return;
            var ys: TileSpans = .{ .start = dest.y, .size = t[1], .p = visible.y0, .end = visible.y1 };
            while (ys.next()) |py| {
                var xs: TileSpans = .{ .start = dest.x, .size = t[0], .p = visible.x0, .end = visible.x1 };
                while (xs.next()) |px| try b.quad(.{
                    .area = .{ .x = @floatFromInt(px.start), .y = @floatFromInt(py.start), .width = @floatFromInt(px.end - px.start), .height = @floatFromInt(py.end - py.start) },
                    .uv0 = .{ px.src0, py.src0 },
                    .uv1 = .{ px.src1, py.src1 },
                    .rect = r,
                    .shape = shape,
                    .clip = clip,
                    .color = color,
                    .paint = p,
                }, index, smooth);
            }
            return;
        }
        const shown = snapped;
        try b.quad(.{
            .area = shown,
            .uv0 = .{ (shown.x - dest.x) / dest.width, (shown.y - dest.y) / dest.height },
            .uv1 = .{ (shown.right() - dest.x) / dest.width, (shown.bottom() - dest.y) / dest.height },
            .rect = r,
            .shape = shape,
            .clip = clip,
            .color = color,
            .paint = p,
        }, index, smooth);
    }

    const Piece = struct { start: i32, end: i32, src0: f32, src1: f32 };

    /// The tiles of an image along one axis, over pixels [p, end): each
    /// tile's pixels (those whose centers `software.tileMap` puts in it)
    /// and where their edges are in it (0 to 1).
    const TileSpans = struct {
        start: f32,
        size: f32,
        p: i32,
        end: i32,

        fn tileOf(it: *const TileSpans, pixel: i32) f32 {
            return @floor((@as(f32, @floatFromInt(pixel)) + 0.5 - it.start) / it.size);
        }

        fn next(it: *TileSpans) ?Piece {
            if (it.p >= it.end) return null;
            const k = it.tileOf(it.p);
            const t0 = it.start + k * it.size;
            var e: i32 = @intFromFloat(std.math.clamp(@ceil(t0 + it.size - 0.5), @as(f32, @floatFromInt(it.p + 1)), @as(f32, @floatFromInt(it.end))));
            // Where rounding puts the boundary elsewhere, as tileMap does.
            while (e > it.p + 1 and it.tileOf(e - 1) != k) e -= 1;
            while (e < it.end and it.tileOf(e) == k) e += 1;
            const piece: Piece = .{
                .start = it.p,
                .end = e,
                .src0 = (@as(f32, @floatFromInt(it.p)) - t0) / it.size,
                .src1 = (@as(f32, @floatFromInt(e)) - t0) / it.size,
            };
            it.p = e;
            return piece;
        }
    };

    /// The three pieces of one axis of a nine-slice image drawn over pixels
    /// [p0, p1): their pixels, and the image coordinates at their edges (as
    /// software.nineSliceMap maps them).
    fn slicePieces(start: f32, dest: f32, src: f32, a_px: u32, b_px: u32, scale: f32, p0: i32, p1: i32) [3]Piece {
        const a: f32 = @floatFromInt(a_px);
        const bb: f32 = @floatFromInt(b_px);
        const shrink = if ((a + bb) * scale > dest and a + bb > 0) dest / (a + bb) else scale;
        const da = a * shrink;
        const db = bb * shrink;
        const middle_dest = dest - da - db;
        const middle_scale = if (middle_dest > 0) (src - a - bb) / middle_dest else 0;
        // The first pixel whose center maps past each border.
        var split: [2]i32 = .{ p1, p1 };
        var p = p0;
        while (p < p1) : (p += 1) {
            const t = @as(f32, @floatFromInt(p)) + 0.5 - start;
            if (split[0] == p1 and t >= da) split[0] = p;
            if (t >= dest - db) {
                split[1] = p;
                break;
            }
        }
        split[0] = @min(split[0], split[1]);
        const map = struct {
            fn f(piece: usize, x: f32, st: f32, sh: f32, a_: f32, b_: f32, src_: f32, da_: f32, mid: f32, dest_: f32, db_: f32) f32 {
                const t = x - st;
                return switch (piece) {
                    0 => t / sh,
                    1 => a_ + (t - da_) * mid,
                    else => src_ - b_ + (t - (dest_ - db_)) / sh,
                };
            }
        }.f;
        const bounds = [4]i32{ p0, split[0], split[1], p1 };
        var pieces: [3]Piece = undefined;
        for (&pieces, 0..) |*piece, k| {
            const x0: f32 = @floatFromInt(bounds[k]);
            const x1: f32 = @floatFromInt(bounds[k + 1]);
            piece.* = .{
                .start = bounds[k],
                .end = bounds[k + 1],
                .src0 = map(k, x0, start, shrink, a, bb, src, da, middle_scale, dest, db),
                .src1 = map(k, x1, start, shrink, a, bb, src, da, middle_scale, dest, db),
            };
        }
        return pieces;
    }

    fn text(b: *Batcher, cmd: *const Command.Draw(rendering.TextStyle), bounds: PixelRect) Allocator.Error!void {
        const clip = PixelRect.centersIn(cmd.clip.intersection(cmd.rect)).intersect(bounds);
        if (clip.isEmpty()) return;
        if (cmd.style.color.isTransparent()) return;
        const color, const p = try b.paint(&cmd.style.color, cmd.rect, cmd.opacity);
        const Ctx = struct { b: *Batcher, cmd: *const Command.Draw(rendering.TextStyle), clip: PixelRect, color: [4]f32, paint: [4]f32 };
        try software.placeGlyphs(cmd, clip, Ctx{ .b = b, .cmd = cmd, .clip = clip, .color = color, .paint = p }, struct {
            fn f(ctx: Ctx, font: *const Font, id: u16, pen_x: f32, pen_y: i32) Allocator.Error!void {
                try ctx.b.glyph(ctx, font, id, pen_x, pen_y);
            }
        }.f);
    }

    fn glyph(b: *Batcher, ctx: anytype, font: *const Font, id: u16, pen_x: f32, pen_y: i32) Allocator.Error!void {
        var ix: i32 = software.toInt(@floor(pen_x));
        var sub: u8 = @intFromFloat(@round((pen_x - @floor(pen_x)) * GlyphCache.subpixels));
        if (sub == GlyphCache.subpixels) {
            ix += 1;
            sub = 0;
        }
        if (font.bitmap != null) sub = 0;
        const size = ctx.cmd.style.font_size;
        const key: GlyphCache.Key = .{ .font = @intFromPtr(font), .glyph = id, .size = @intFromFloat(@round(size * 64)), .subpixel = sub, .options = b.glyphs.options };
        const entry = b.glyph_map.get(key) orelse blk: {
            b.glyphs.pool.clearRetainingCapacity();
            const bmp = if (font.bitmap != null)
                try b.glyphs.unpack(b.gpa, font, id, size)
            else
                try b.glyphs.rasterize(b.gpa, font, id, size, sub, &b.path_commands, &b.polylines, &b.mask);
            const e = try b.store(bmp.width, bmp.height, b.glyphs.pool.items[bmp.offset..][0 .. @as(usize, bmp.width) * bmp.height], bmp.left, bmp.top) orelse return;
            try b.glyph_map.put(b.gpa, key, e);
            break :blk e;
        };
        if (entry.width == 0) return;
        try b.coverageQuad(entry, ix + entry.left, pen_y + entry.top, ctx.cmd.rect, ctx.clip, ctx.color, ctx.paint);
    }

    /// Puts a coverage bitmap in the atlas; null when it is full (the frame
    /// is then built again).
    fn store(b: *Batcher, width: u32, height: u32, coverage: []const u8, left: i32, top: i32) Allocator.Error!?AtlasEntry {
        if (width == 0 or height == 0) return .{ .x = 0, .y = 0, .width = 0, .height = 0, .left = 0, .top = 0 };
        const at = try b.atlas.alloc(b.gpa, width, height) orelse {
            b.atlas_full = true;
            return null;
        };
        b.atlas.write(at, width, height, coverage);
        return .{ .x = @intCast(at[0]), .y = @intCast(at[1]), .width = @intCast(width), .height = @intCast(height), .left = left, .top = top };
    }

    fn coverageQuad(b: *Batcher, e: AtlasEntry, x: i32, y: i32, rect: Rect, clip: PixelRect, color: [4]f32, p: [4]f32) Allocator.Error!void {
        const area: Rect = .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(e.width), .height = @floatFromInt(e.height) };
        try b.quad(.{
            .area = area,
            .uv0 = .{ @floatFromInt(e.x), @floatFromInt(e.y) },
            .uv1 = .{ @floatFromInt(@as(u32, e.x) + e.width), @floatFromInt(@as(u32, e.y) + e.height) },
            .rect = rect,
            .shape = .{ 0, 0, 0, @floatFromInt(@intFromEnum(Kind.coverage)) },
            .clip = clip,
            .color = color,
            .paint = p,
        }, null, true);
    }

    fn pathCommand(b: *Batcher, cmd: *const Command.Draw(rendering.PathStyle), bounds: PixelRect) Allocator.Error!void {
        const s = &cmd.style;
        const clip = PixelRect.centersIn(cmd.clip).intersect(bounds);
        if (clip.isEmpty()) return;
        // Masks are cached by everything that shapes them; the clip applies
        // when drawing, and the position moves them by whole pixels. The
        // fraction of a pixel is rounded to 1/64 (rounding noise in where a
        // shape is computed to be would otherwise make a new mask).
        const ox, const fx = software.pathOrigin(cmd.rect.x);
        const oy, const fy = software.pathOrigin(cmd.rect.y);
        var h: std.hash.Wyhash = .init(0);
        h.update(s.commands);
        for ([_]f32{ fx, fy, cmd.rect.width, cmd.rect.height, s.stroke_width }) |v| h.update(std.mem.asBytes(&v));
        if (s.viewbox) |v| h.update(std.mem.asBytes(&v));
        h.update(&.{ @intFromBool(s.fill.isTransparent()), @intFromBool(s.stroke.isTransparent()), @intFromBool(s.stretch), @intFromBool(s.inset_stroke) });
        const hash = h.final();

        if (b.path_map.get(.{ .hash = hash, .stroke = false }) == null and b.path_map.get(.{ .hash = hash, .stroke = true }) == null) {
            // Rasterized unclipped, at the rect's fraction of a pixel.
            var local = cmd.*;
            local.rect.x = fx;
            local.rect.y = fy;
            local.clip = .{ .x = -1e6, .y = -1e6, .width = 2e6, .height = 2e6 };
            const everywhere: PixelRect = .{ .x0 = -1 << 20, .y0 = -1 << 20, .x1 = 1 << 20, .y1 = 1 << 20 };
            const Ctx = struct { b: *Batcher, hash: u64, s: *const rendering.PathStyle };
            try software.pathMasks(b.gpa, .{ .commands = &b.path_commands, .polylines = &b.polylines, .mask = &b.mask }, &local, everywhere, Ctx{ .b = b, .hash = hash, .s = &local.style }, struct {
                fn f(ctx: Ctx, pixels: PixelRect, mask: *const raster.Mask, brush: *const Brush) Allocator.Error!void {
                    const self = ctx.b;
                    const w = pixels.width();
                    const hh = pixels.height();
                    const stroke = brush == &ctx.s.stroke;
                    if (w == 0 or hh == 0) {
                        try self.path_map.put(self.gpa, .{ .hash = ctx.hash, .stroke = stroke }, .{ .x = 0, .y = 0, .width = 0, .height = 0, .left = 0, .top = 0 });
                        return;
                    }
                    var piece: u16 = 0;
                    var ty: u32 = 0;
                    while (ty < hh) : (ty += path_tile) {
                        var tx: u32 = 0;
                        while (tx < w) : (tx += path_tile) {
                            const tw = @min(path_tile, w - tx);
                            const th = @min(path_tile, hh - ty);
                            try self.coverage.resize(self.gpa, @as(usize, tw) * th);
                            for (0..th) |y| for (0..tw) |x| {
                                self.coverage.items[y * tw + x] = @intFromFloat(@round(std.math.clamp(mask.coverage(@intCast(tx + x), @intCast(ty + y)), 0, 1) * 255));
                            };
                            const e = try self.store(tw, th, self.coverage.items, pixels.x0 + @as(i32, @intCast(tx)), pixels.y0 + @as(i32, @intCast(ty))) orelse return;
                            try self.path_map.put(self.gpa, .{ .hash = ctx.hash, .stroke = stroke, .piece = piece }, e);
                            piece += 1;
                        }
                    }
                }
            }.f);
        }
        for ([_]bool{ false, true }) |stroke| {
            const brush = if (stroke) &s.stroke else &s.fill;
            var piece: u16 = 0;
            // Gradients span the paint box, about the center their
            // geometry gives (the quad's rect shapes nothing else here).
            const box = software.pathPaintRect(s, cmd.rect);
            const center = software.paintGeometry(brush.*, box).center;
            const around: Rect = .{ .x = center.x - box.width / 2, .y = center.y - box.height / 2, .width = box.width, .height = box.height };
            while (b.path_map.get(.{ .hash = hash, .stroke = stroke, .piece = piece })) |e| : (piece += 1) {
                if (e.width == 0) continue;
                const color, const p = try b.paint(brush, box, cmd.opacity);
                try b.coverageQuad(e, ox + e.left, oy + e.top, around, clip, color, p);
            }
        }
    }
};
