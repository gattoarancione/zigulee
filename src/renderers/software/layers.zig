// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Layers (`DisplayList.Command.layer`): what an element and its children
//! draw, rasterized into an image of its own, blurred, then drawn faded as
//! one. Both renderers draw display lists with their layers replaced by
//! those images (`Layers.flatten`): the software renderer as any image, the
//! GPU renderer as a texture, so they show the same pixels. An image is
//! kept while what its layer holds is the same: a fade, or a blur that does
//! not change, is rasterized once. A layer with a mask (a rotated or rounded
//! clip, a `clip-path`, a `mask-image`) keeps only what is inside it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/core.zig");
const Rect = core.Rect;
const Rgba8 = core.Rgba8;
const DisplayList = core.rendering.DisplayList;
const Command = DisplayList.Command;
const software = @import("software.zig");
const PixelRect = software.PixelRect;

/// Layers bigger than this many pixels are drawn without an image (faded
/// piece by piece, not blurred).
const max_pixels = 4096 * 4096;
/// Images not drawn for this many frames are let go.
const keep_frames = 30;

/// Each image drawn is a new version: GPU renderers keep textures by the
/// pixels' address and version, and let the older ones go.
var versions: std.atomic.Value(u32) = .init(1);

pub const Layers = struct {
    gpa: Allocator,
    /// Draws what layers hold (made for the first one).
    inner: ?*software.Renderer(Rgba8) = null,
    images: std.ArrayList(Image) = .empty,
    out: std.ArrayList(Command) = .empty,
    scratch: std.ArrayList(Rgba8) = .empty,
    frame: u64 = 1,

    const Image = struct {
        /// What it shows (the layer's contents, blur, scale and place).
        key: u64,
        pixels: []Rgba8,
        width: u32,
        height: u32,
        version: u32,
        /// The frame it was last drawn in.
        used: u64,
    };

    pub fn init(gpa: Allocator) Layers {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Layers) void {
        if (self.inner) |r| {
            r.deinit();
            self.gpa.destroy(r);
        }
        for (self.images.items) |img| self.gpa.free(img.pixels);
        self.images.deinit(self.gpa);
        self.out.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
    }

    /// Starts a frame: images not drawn for a while are let go.
    pub fn newFrame(self: *Layers) void {
        self.frame += 1;
        var i: usize = 0;
        while (i < self.images.items.len) {
            if (self.frame - self.images.items[i].used > keep_frames) {
                self.gpa.free(self.images.items[i].pixels);
                _ = self.images.swapRemove(i);
            } else i += 1;
        }
        if (self.inner) |r| r.layers.newFrame();
    }

    /// `commands` (in physical pixels, `scale` per logical one) with each
    /// layer replaced by an image of what it holds; `commands` itself when
    /// there is none. Valid until the next call.
    pub fn flatten(self: *Layers, commands: []const Command, scale: f32) Allocator.Error![]const Command {
        if (!core.effects) return commands;
        for (commands) |c| {
            if (c == .layer) break;
        } else return commands;
        self.out.clearRetainingCapacity();
        try self.append(commands, scale, 1, null);
        return self.out.items;
    }

    /// Appends `commands`, their layers as images. Within a layer drawn
    /// without one, `fade` multiplies their opacities and `clip` limits
    /// them.
    fn append(self: *Layers, commands: []const Command, scale: f32, fade: f32, clip: ?Rect) Allocator.Error!void {
        var i: usize = 0;
        while (i < commands.len) : (i += 1) {
            switch (commands[i]) {
                .layer => |l| {
                    const inner = commands[i + 1 ..][0..l.style.count];
                    // To its `end_layer` (the loop steps past it).
                    i += l.style.count + 1;
                    if (fade == 1 and clip == null) if (try self.image(l, inner, scale)) |cmd| {
                        try self.out.append(self.gpa, cmd);
                        continue;
                    };
                    // Without an image: piece by piece, not blurred (nor
                    // masked: an element's mask is not drawn).
                    const within = if (clip) |c| c.intersection(l.clip) else l.clip;
                    const shape_len = if (l.style.mask) |m| @min(m.commands, inner.len) else 0;
                    try self.append(inner[shape_len..], scale, fade * l.opacity, within);
                },
                .end_layer => {},
                else => {
                    var cmd = commands[i];
                    if (fade != 1 or clip != null) switch (cmd) {
                        inline else => |*c| {
                            c.opacity *= fade;
                            if (clip) |k| c.clip = c.clip.intersection(k);
                        },
                    };
                    try self.out.append(self.gpa, cmd);
                },
            }
        }
    }

    /// An image command showing layer `l` (holding `inner`), drawn now or
    /// kept from before; null if it cannot have one (too big, or no
    /// memory).
    fn image(self: *Layers, l: Command.Draw(core.rendering.LayerStyle), inner: []const Command, scale: f32) Allocator.Error!?Command {
        const shape_len = if (l.style.mask) |m| @min(m.commands, inner.len) else 0;
        var area = PixelRect.touching(l.rect);
        // Kept as it is (`prefer-rendering-cache`, not turned): shown as
        // any image, pixel for pixel.
        const mapping = if (l.style.projection) |h| (if (std.meta.eql(h, core.Projective.identity)) null else h) else null;
        // Mapped (tilted in depth, turned): with a transparent pixel
        // around, which smooths its edges once sampled. Kept as it is too:
        // the same image whether turned or not.
        if (l.style.projection != null and !area.isEmpty()) area = .{ .x0 = area.x0 - 1, .y0 = area.y0 - 1, .x1 = area.x1 + 1, .y1 = area.y1 + 1 };
        if (area.isEmpty()) return null;
        const w = area.width();
        const h = area.height();
        const n = @as(usize, w) * h;
        if (n > max_pixels) return null;
        var hasher: std.hash.Wyhash = .init(l.style.hash);
        hasher.update(std.mem.asBytes(&[_]f32{ l.style.blur, scale }));
        hasher.update(std.mem.asBytes(&[_]i32{ area.x0, area.y0, area.x1, area.y1 }));
        const key = hasher.final();

        const img = for (self.images.items) |*it| {
            if (it.key == key and it.width == w and it.height == h) break it;
        } else blk: {
            // A new image: into the pixels of one not drawn this frame, or
            // new ones.
            const it = for (self.images.items) |*it| {
                if (it.used != self.frame) break it;
            } else new: {
                const pixels = self.gpa.alloc(Rgba8, n) catch return null;
                self.images.append(self.gpa, .{ .key = 0, .pixels = pixels, .width = 0, .height = 0, .version = 0, .used = 0 }) catch {
                    self.gpa.free(pixels);
                    return null;
                };
                break :new &self.images.items[self.images.items.len - 1];
            };
            if (it.pixels.len < n) {
                const pixels = self.gpa.alloc(Rgba8, n) catch return null;
                self.gpa.free(it.pixels);
                it.pixels = pixels;
            }
            it.key = 0;
            self.draw(it.pixels[0..n], area, inner[shape_len..], scale, l.style.blur, l.style.mask, inner[0..shape_len]) catch return null;
            it.* = .{ .key = key, .pixels = it.pixels, .width = w, .height = h, .version = versions.fetchAdd(1, .monotonic), .used = self.frame };
            break :blk it;
        };
        img.used = self.frame;
        const rect: Rect = .{ .x = @floatFromInt(area.x0), .y = @floatFromInt(area.y0), .width = @floatFromInt(w), .height = @floatFromInt(h) };
        return .{ .image = .{
            .rect = rect,
            .clip = l.clip,
            .opacity = l.opacity,
            .style = .{
                .image = .{ .width = w, .height = h, .pixels = img.pixels[0..n], .version = img.version },
                .fit = .fill,
                .rendering = if (mapping != null) .smooth else .pixelated,
                .projection = mapping,
            },
        } };
    }

    /// Rasterizes `inner` into `pixels` (covering `area`), blurs them, and
    /// keeps what is inside `mask` (drawn by `shape`, an element's mask).
    fn draw(self: *Layers, pixels: []Rgba8, area: PixelRect, inner: []const Command, scale: f32, blur: f32, mask: ?core.rendering.LayerMask, shape: []const Command) Allocator.Error!void {
        const r = self.inner orelse blk: {
            const r = try self.gpa.create(software.Renderer(Rgba8));
            r.* = .init(self.gpa);
            self.inner = r;
            break :blk r;
        };
        r.scale_factor = scale;
        @memset(pixels, Rgba8.transparent);
        const canvas: software.Canvas(Rgba8) = .{ .pixels = pixels, .width = area.width(), .height = area.height(), .stride = area.width(), .origin_x = area.x0, .origin_y = area.y0 };
        try r.drawCommands(canvas, inner, canvas.bounds());
        if (blur > 0) {
            try self.scratch.resize(self.gpa, pixels.len);
            gaussianBlur(pixels, self.scratch.items, area.width(), area.height(), blur);
        }
        const m = mask orelse return;
        // The mask's shape, white, then its coverage taken.
        try self.scratch.resize(self.gpa, pixels.len);
        const coverage = self.scratch.items;
        @memset(coverage, Rgba8.transparent);
        const shape_canvas: software.Canvas(Rgba8) = .{ .pixels = coverage, .width = area.width(), .height = area.height(), .stride = area.width(), .origin_x = area.x0, .origin_y = area.y0 };
        const white: core.Brush = .color(.white);
        const translated = m.transform.isTranslation();
        const rect = if (translated) m.rect.translate(m.transform.offset()) else m.rect;
        const at: ?core.Affine = if (translated) null else m.transform;
        const bounds = shape_canvas.bounds();
        var shapes: std.ArrayList(Command) = .empty;
        defer shapes.deinit(self.gpa);
        const place: Command.Draw(void) = .{ .rect = rect, .clip = bounds, .opacity = 1, .transform = at, .style = {} };
        if (m.commands > 0) {
            try shapes.appendSlice(self.gpa, shape);
        } else if (m.image) |img| {
            try maskShapes(self.gpa, &shapes, place, img.*);
        } else if (m.path.len > 0) {
            try shapes.append(self.gpa, .{ .path = .{ .rect = rect, .clip = bounds, .opacity = 1, .transform = at, .style = .{ .commands = m.path, .fill = white, .viewbox = m.box, .inset_stroke = false } } });
        } else {
            try shapes.append(self.gpa, .{ .rectangle = .{ .rect = rect, .clip = bounds, .opacity = 1, .transform = at, .style = .{ .background = white, .border_radius = m.radius } } });
        }
        try r.drawCommands(shape_canvas, shapes.items, bounds);
        // By brightness: of the colors as drawn (premultiplied: in their
        // opacity already).
        if (m.luminance) for (coverage) |*c| {
            c.a = @intCast((@as(u32, c.r) * 54 + @as(u32, c.g) * 183 + @as(u32, c.b) * 19) / 256);
        };
        if (m.inverted) {
            for (pixels, coverage) |*p, c| p.* = scaled(p.*, 255 - c.a);
        } else for (pixels, coverage) |*p, c| p.* = scaled(p.*, c.a);
    }
};

/// What draws a mask image over `place`: the image stretched, or an SVG
/// drawing's shapes (as opaque as their paints).
fn maskShapes(gpa: Allocator, out: *std.ArrayList(Command), place: Command.Draw(void), img: core.Image) Allocator.Error!void {
    const d = img.vector orelse {
        if (img.pixels.len == 0 or img.pixels.len < @as(usize, img.width) * img.height) return;
        try out.append(gpa, .{ .image = .{ .rect = place.rect, .clip = place.clip, .opacity = 1, .transform = place.transform, .style = .{ .image = img, .fit = .fill } } });
        return;
    };
    const vb = d.viewbox;
    if (!(vb.width > 0 and vb.height > 0)) return;
    const scale = @sqrt(place.rect.width / vb.width * place.rect.height / vb.height);
    for (d.shapes) |shape| try out.append(gpa, .{ .path = .{ .rect = place.rect, .clip = place.clip, .opacity = 1, .transform = place.transform, .style = .{
        .commands = shape.commands,
        .fill = opaqueAs(shape.fill),
        .stroke = opaqueAs(shape.stroke),
        .stroke_width = shape.stroke_width * scale,
        .viewbox = vb,
        .stretch = true,
        .inset_stroke = false,
    } } });
}

/// White, as opaque as `paint` (a gradient: fully).
fn opaqueAs(paint: ?core.svg.Paint) core.Brush {
    const p = paint orelse return .transparent;
    return switch (p) {
        .color => |c| .color(.{ .r = 255, .g = 255, .b = 255, .a = c.a }),
        else => .color(.white),
    };
}

/// A premultiplied pixel `p` times `a` / 255.
fn scaled(p: Rgba8, a: u8) Rgba8 {
    if (a == 255) return p;
    const k: u16 = a;
    return .{
        .r = @intCast((@as(u16, p.r) * k + 127) / 255),
        .g = @intCast((@as(u16, p.g) * k + 127) / 255),
        .b = @intCast((@as(u16, p.b) * k + 127) / 255),
        .a = @intCast((@as(u16, p.a) * k + 127) / 255),
    };
}

/// Blurs premultiplied `pixels` (`w` x `h`, transparent around them) with
/// a Gaussian of standard deviation `sigma`, approximated by three box
/// blurs each way. `scratch` holds as many pixels.
pub fn gaussianBlur(pixels: []Rgba8, scratch: []Rgba8, w: u32, h: u32, sigma: f32) void {
    for (boxRadii(sigma)) |r| {
        // Rows into columns, then back: blurred both ways.
        boxBlur(pixels, scratch, w, h, r);
        boxBlur(scratch, pixels, h, w, r);
    }
}

/// The radii of three box blurs that together approximate a Gaussian of
/// deviation `sigma` (as W3C's filter effects describe).
fn boxRadii(sigma: f32) [3]u32 {
    const n: f32 = 3;
    var lower = @floor(@sqrt(12 * sigma * sigma / n + 1));
    if (@mod(lower, 2) == 0) lower -= 1;
    const upper = lower + 2;
    const m = @round((12 * sigma * sigma - n * lower * lower - 4 * n * lower - 3 * n) / (-4 * lower - 4));
    var radii: [3]u32 = undefined;
    for (&radii, 0..) |*r, i| {
        const size = if (@as(f32, @floatFromInt(i)) < m) lower else upper;
        r.* = @intFromFloat(@max(0, (size - 1) / 2));
    }
    return radii;
}

/// A box blur of radius `r` along each of the `lines` rows of `len`
/// pixels in `src`, written transposed into `dst` (`len` rows of `lines`
/// pixels): two calls blur both ways and end as they began.
fn boxBlur(src: []const Rgba8, dst: []Rgba8, len: u32, lines: u32, r: u32) void {
    const size = 2 * r + 1;
    for (0..lines) |line| {
        const row = src[line * len ..][0..len];
        var sum: [4]u32 = .{ 0, 0, 0, 0 };
        // The window [x - r, x + r]; outside the row, transparent.
        for (0..@min(r, len)) |k| add(&sum, row[k], 1);
        for (0..len) |x| {
            if (x + r < len) add(&sum, row[x + r], 1);
            if (x >= r + 1) add(&sum, row[x - r - 1], -1);
            dst[x * lines + line] = .{
                .r = @intCast((sum[0] + size / 2) / size),
                .g = @intCast((sum[1] + size / 2) / size),
                .b = @intCast((sum[2] + size / 2) / size),
                .a = @intCast((sum[3] + size / 2) / size),
            };
        }
    }
}

fn add(sum: *[4]u32, p: Rgba8, sign: i32) void {
    if (sign > 0) {
        sum[0] += p.r;
        sum[1] += p.g;
        sum[2] += p.b;
        sum[3] += p.a;
    } else {
        sum[0] -= p.r;
        sum[1] -= p.g;
        sum[2] -= p.b;
        sum[3] -= p.a;
    }
}
