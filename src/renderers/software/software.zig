// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The software renderer: rasterizes a window's display list into a pixel
//! buffer. It is the reference renderer (golden tests compare against it)
//! and runs on microcontrollers, rendering either into a full framebuffer or
//! band by band into a few lines of memory.
//!
//! Text is drawn with TrueType fonts: glyph outlines go through the same
//! anti-aliased filler as paths, and are cached per size and quarter-pixel
//! horizontal offset. There is no hinting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/core.zig");
const Point = core.Point;
const Rect = core.Rect;
const Region = core.Region;
const Brush = core.Brush;
const Rgba8 = core.Rgba8;
const mul8 = @import("../../core/graphics.zig").mul8;
const GradientStops = @import("../../core/graphics.zig").GradientStops;
const rendering = core.rendering;
const DisplayList = rendering.DisplayList;
const Command = DisplayList.Command;
const path = core.path;
const Font = core.Font;
const text_layout = core.text.layout;
const raster = @import("raster.zig");
pub const spans = @import("spans.zig");
const gpu_batch = @import("../gpu/batch.zig");
const gpu_reference = @import("../gpu/reference.zig");
pub const layers = @import("layers.zig");

/// 16-bit RGB, the common format of small displays.
pub const Rgb565 = packed struct(u16) {
    b: u5,
    g: u6,
    r: u5,

    pub fn fromRgb8(r: u8, g: u8, b: u8) Rgb565 {
        return .{ .r = @intCast(r >> 3), .g = @intCast(g >> 2), .b = @intCast(b >> 3) };
    }

    pub fn toRgb8(p: Rgb565) [3]u8 {
        const r: u8 = p.r;
        const g: u8 = p.g;
        const b: u8 = p.b;
        return .{ (r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2) };
    }
};

/// Composites premultiplied `src` over `dst`.
pub fn blend(comptime P: type, dst: *P, src: Rgba8) void {
    if (src.a == 0 and src.r == 0 and src.g == 0 and src.b == 0) return;
    const inv = 255 - src.a;
    switch (P) {
        Rgba8 => dst.* = .{
            .r = src.r + mul8(dst.r, inv),
            .g = src.g + mul8(dst.g, inv),
            .b = src.b + mul8(dst.b, inv),
            .a = src.a + mul8(dst.a, inv),
        },
        Rgb565 => {
            if (src.a == 255) {
                dst.* = .fromRgb8(src.r, src.g, src.b);
                return;
            }
            const d = dst.toRgb8();
            dst.* = .fromRgb8(src.r + mul8(d[0], inv), src.g + mul8(d[1], inv), src.b + mul8(d[2], inv));
        },
        else => @compileError("unsupported pixel type " ++ @typeName(P)),
    }
}

/// Asks for `bytes` to be brought into the cache (a line at a time).
fn prefetchBytes(bytes: []const u8) void {
    const line = 64;
    var i: usize = 0;
    while (i < bytes.len) : (i += line) @prefetch(bytes.ptr + i, .{});
    if (bytes.len > 0) @prefetch(bytes.ptr + bytes.len - 1, .{});
}

/// Pixels blended at once with a solid color: the most a row's coverage is
/// gathered for on the stack.
const row_chunk = 256;

/// A pixel buffer showing part of a window.
pub fn Canvas(comptime P: type) type {
    return struct {
        const Self = @This();

        pixels: []P,
        width: u32,
        height: u32,
        stride: u32,
        /// Window coordinates of pixel (0, 0).
        origin_x: i32 = 0,
        origin_y: i32 = 0,

        pub fn init(pixels: []P, width: u32, height: u32) Self {
            std.debug.assert(pixels.len >= @as(usize, width) * height);
            return .{ .pixels = pixels, .width = width, .height = height, .stride = width };
        }

        /// The window area this canvas covers.
        pub fn bounds(c: Self) Rect {
            return .{
                .x = @floatFromInt(c.origin_x),
                .y = @floatFromInt(c.origin_y),
                .width = @floatFromInt(c.width),
                .height = @floatFromInt(c.height),
            };
        }

        /// The pixel at window coordinates (x, y), which must be inside.
        fn at(c: Self, x: i32, y: i32) *P {
            const col: usize = @intCast(x - c.origin_x);
            const row: usize = @intCast(y - c.origin_y);
            return &c.pixels[row * c.stride + col];
        }

        /// Asks for pixels x0 to x1 of row y to be brought into the cache,
        /// if the row is inside: blending a shape's next row while its
        /// memory is on its way (a small board's waits for each row
        /// otherwise; it only guesses ahead along a row).
        fn prefetch(c: Self, x0: i32, x1: i32, y: i32) void {
            if (!spans.enabled or y < c.origin_y or y >= c.origin_y + @as(i32, @intCast(c.height)) or x1 <= x0) return;
            // Whole rows follow each other: the CPU sees that itself.
            if (x1 - x0 == c.stride) return;
            prefetchBytes(std.mem.sliceAsBytes(c.span(x0, x1, y)));
        }

        /// Pixels x0 to x1 (window coordinates) of row y, which must be
        /// inside.
        fn span(c: Self, x0: i32, x1: i32, y: i32) []P {
            return c.pixels[@as(usize, @intCast(y - c.origin_y)) * c.stride ..][@intCast(x0 - c.origin_x)..@intCast(x1 - c.origin_x)];
        }

        pub fn fill(c: Self, value: P) void {
            for (0..c.height) |row| @memset(c.pixels[row * c.stride ..][0..c.width], value);
        }
    };
}

/// A rectangle of whole pixels [x0, x1) x [y0, y1), in window coordinates.
pub const PixelRect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    /// Pixels whose centers fall inside `r`.
    pub fn centersIn(r: Rect) PixelRect {
        return .{
            .x0 = toInt(@round(r.x)),
            .y0 = toInt(@round(r.y)),
            .x1 = toInt(@round(r.right())),
            .y1 = toInt(@round(r.bottom())),
        };
    }

    /// Pixels touched by `r`.
    pub fn touching(r: Rect) PixelRect {
        return .{
            .x0 = toInt(@floor(r.x)),
            .y0 = toInt(@floor(r.y)),
            .x1 = toInt(@ceil(r.right())),
            .y1 = toInt(@ceil(r.bottom())),
        };
    }

    pub fn intersect(a: PixelRect, b: PixelRect) PixelRect {
        return .{ .x0 = @max(a.x0, b.x0), .y0 = @max(a.y0, b.y0), .x1 = @min(a.x1, b.x1), .y1 = @min(a.y1, b.y1) };
    }

    pub fn isEmpty(r: PixelRect) bool {
        return r.x1 <= r.x0 or r.y1 <= r.y0;
    }

    pub fn width(r: PixelRect) u32 {
        return @intCast(r.x1 - r.x0);
    }

    pub fn height(r: PixelRect) u32 {
        return @intCast(r.y1 - r.y0);
    }

    /// Pixels lying wholly inside `r`.
    pub fn within(r: Rect) PixelRect {
        return .{
            .x0 = toInt(@ceil(r.x)),
            .y0 = toInt(@ceil(r.y)),
            .x1 = toInt(@floor(r.right())),
            .y1 = toInt(@floor(r.bottom())),
        };
    }

    pub fn area(r: PixelRect) u64 {
        return if (r.isEmpty()) 0 else @as(u64, r.width()) * r.height();
    }

    pub fn contains(a: PixelRect, b: PixelRect) bool {
        return b.isEmpty() or (a.x0 <= b.x0 and a.y0 <= b.y0 and a.x1 >= b.x1 and a.y1 >= b.y1);
    }
};

pub fn toInt(f: f32) i32 {
    return @intFromFloat(fclamp(f, -1e9, 1e9));
}

// `@max`, `@min`, `@ceil` and `@floor` of floats as compares and
// conversions: 32-bit ARM's floating-point unit has no instructions for
// them, and LLVM calls the C library for each (fmaxf, ceilf), pixel after
// pixel. The same results, NaN included (as fmaxf and fminf keep the
// number). Microcontrollers keep theirs: smaller.

inline fn fmax(a: f32, b: f32) f32 {
    return if (!spans.enabled) @max(a, b) else if (a > b or b != b) a else b;
}

inline fn fmin(a: f32, b: f32) f32 {
    return if (!spans.enabled) @min(a, b) else if (a < b or b != b) a else b;
}

/// `std.math.clamp` (itself on microcontrollers: the same code).
const fclamp = if (spans.enabled) clampCompared else std.math.clamp;

inline fn clampCompared(x: f32, lo: f32, hi: f32) f32 {
    return fmax(lo, fmin(x, hi));
}

/// `toInt(@ceil(x))`.
inline fn ceilInt(x: f32) i32 {
    if (!spans.enabled) return toInt(@ceil(x));
    const t = toInt(x);
    return t + @intFromBool(@as(f32, @floatFromInt(t)) < x);
}

/// `toInt(@floor(x))`.
inline fn floorInt(x: f32) i32 {
    if (!spans.enabled) return toInt(@floor(x));
    const t = toInt(x);
    return t - @intFromBool(@as(f32, @floatFromInt(t)) > x);
}

/// Where a gradient is sampled at window position p: at
/// dot(p - center, axis) + 0.5 for a linear one, at |(p - center) * axis|
/// (per axis) for a radial one. The GPU renderer's shaders take the same
/// (the batcher puts the center at its quad's).
pub const PaintGeometry = struct { center: Point, axis: [2]f32 };

/// How `brush` spans `box`.
pub fn paintGeometry(brush: Brush, box: Rect) PaintGeometry {
    const center: Point = .{ .x = box.x + box.width / 2, .y = box.y + box.height / 2 };
    const inv = struct {
        fn f(x: f32) f32 {
            return if (x != 0) 1 / x else 0;
        }
    }.f;
    switch (brush) {
        .solid => return .{ .center = center, .axis = .{ 0, 0 } },
        .linear_gradient => |g| {
            if (g.line) |l| {
                // From the start (0) to the end (1), square to the line in
                // fractions of the box: t = (u - start) . d / |d|^2.
                const d = [2]f32{ l[1][0] - l[0][0], l[1][1] - l[0][1] };
                const k = inv(d[0] * d[0] + d[1] * d[1]);
                return .{
                    .center = .{ .x = box.x + (l[0][0] + d[0] / 2) * box.width, .y = box.y + (l[0][1] + d[1] / 2) * box.height },
                    .axis = .{ d[0] * k * inv(box.width), d[1] * k * inv(box.height) },
                };
            }
            // CSS: 0deg points up, 90deg right; the corners at 0 and 1.
            const a = std.math.degreesToRadians(g.angle);
            const dir = [2]f32{ @sin(a), -@cos(a) };
            const len = inv(@abs(box.width * dir[0]) + @abs(box.height * dir[1]));
            return .{ .center = center, .axis = .{ dir[0] * len, dir[1] * len } };
        },
        .radial_gradient => |g| {
            if (g.ellipse) |e| return .{
                .center = .{ .x = box.x + e.center[0] * box.width, .y = box.y + e.center[1] * box.height },
                .axis = .{ inv(e.radius[0] * box.width), inv(e.radius[1] * box.height) },
            };
            // To the farthest corner.
            const radius = inv(@sqrt(box.width * box.width + box.height * box.height) / 2);
            return .{ .center = center, .axis = .{ radius, radius } };
        },
    }
}

/// A brush prepared for sampling within a shape.
const Paint = union(enum) {
    solid: Rgba8,
    linear: struct { stops: GradientStops, geometry: PaintGeometry },
    radial: struct { stops: GradientStops, geometry: PaintGeometry },

    /// `brush` must outlive the paint.
    fn init(brush: *const Brush, shape: Rect) Paint {
        return switch (brush.*) {
            .solid => |c| .{ .solid = c.premultiplied() },
            .linear_gradient => |g| .{ .linear = .{ .stops = g.stops, .geometry = paintGeometry(brush.*, shape) } },
            .radial_gradient => |g| .{ .radial = .{ .stops = g.stops, .geometry = paintGeometry(brush.*, shape) } },
        };
    }

    /// The color at window position (x, y).
    fn at(p: Paint, x: f32, y: f32) Rgba8 {
        return switch (p) {
            .solid => |c| c,
            .linear => |g| {
                const dx = x - g.geometry.center.x;
                const dy = y - g.geometry.center.y;
                return g.stops.sample(dx * g.geometry.axis[0] + dy * g.geometry.axis[1] + 0.5);
            },
            .radial => |g| {
                const dx = (x - g.geometry.center.x) * g.geometry.axis[0];
                const dy = (y - g.geometry.center.y) * g.geometry.axis[1];
                return g.stops.sample(@sqrt(dx * dx + dy * dy));
            },
        };
    }
};

/// The pixels of row `y` within `pixels` that `shape` (with corners of
/// `radius`) covers entirely, with their centers at least half a pixel
/// inside it: [x0, x1). Empty (x0 >= x1) if none. Level with a corner,
/// they reach into it as far as the arc allows (with a margin, so that
/// what the distance function says of them is still full coverage): only
/// the pixels the arc crosses are left to compute one by one (but on
/// microcontrollers, which stop at the corners and keep the code small).
fn fullSpan(shape: Rect, radius: f32, y: i32, pixels: PixelRect) [2]i32 {
    const top: f32 = @floatFromInt(y);
    const bottom = top + 1;
    if (top < shape.y or bottom > shape.y + shape.height) return .{ pixels.x1, pixels.x1 };
    // Between the corners' rows, the whole width.
    const straight = top >= shape.y + radius and bottom <= shape.y + shape.height - radius;
    var x0f = shape.x;
    var x1f = shape.x + shape.width;
    if (!straight and !spans.enabled) {
        // Between the two corners (microcontrollers: smaller).
        x0f = shape.x + radius;
        x1f = shape.x + shape.width - radius;
    } else if (!straight) {
        // How far below (or above) the corners' centers the row's
        // pixel centers are, and how far in from the side the arc is
        // at least half a pixel away.
        const py = top + 0.5;
        const dy = fmax(fmax(shape.y + radius - py, py - (shape.y + shape.height - radius)), 0);
        const reach = radius - 0.5 - 1e-3;
        // At least half a pixel, as from any side (corners smaller
        // than that).
        const inset = fmax(0.5, radius - if (reach > dy) @sqrt(reach * reach - dy * dy) else 0);
        x0f = shape.x + inset - 0.5;
        x1f = shape.x + shape.width - inset + 0.5;
    }
    const x0 = std.math.clamp(ceilInt(x0f), pixels.x0, pixels.x1);
    const x1 = std.math.clamp(floorInt(x1f), x0, pixels.x1);
    return .{ x0, x1 };
}

/// `fullSpan`, the rows between the corners' (all the same) worked out
/// once, in `straight`: no rounding row after row.
fn rowSpan(shape: Rect, radius: f32, y: i32, pixels: PixelRect, straight: *?[2]i32) [2]i32 {
    const top: f32 = @floatFromInt(y);
    if (top < shape.y + radius or top + 1 > shape.y + shape.height - radius) return fullSpan(shape, radius, y, pixels);
    if (straight.* == null) straight.* = fullSpan(shape, radius, y, pixels);
    return straight.*.?;
}

/// A fully opaque color as a pixel (what `blend` stores for it).
fn opaquePixel(comptime P: type, c: Rgba8) P {
    return switch (P) {
        Rgba8 => c,
        Rgb565 => .fromRgb8(c.r, c.g, c.b),
        else => @compileError("unsupported pixel type " ++ @typeName(P)),
    };
}

fn alpha8(coverage: f32) u8 {
    // `@round`, without its call into the C library on CPUs with no
    // rounding instruction (32-bit ARM): the value is not negative, and
    // its fraction is exact. (Microcontrollers keep the call: smaller.)
    const x = fclamp(coverage, 0, 1) * 255;
    if (!spans.enabled) return @intFromFloat(@round(x));
    const whole: u8 = @intFromFloat(x);
    return whole + @intFromBool(x - @as(f32, @floatFromInt(whole)) >= 0.5);
}

/// Signed distance from (px, py) to a rounded rectangle (negative inside).
/// How much of the pixel centered at (`px`, `py`) the shadow of the
/// rounded rectangle `r` covers, blurred by a Gaussian of deviation
/// `sigma`: exact for a rectangle (the blur is separable), with the
/// corners rounded by the blurred distance to the shape. Shaders compute
/// the same.
pub fn shadowCoverage(px: f32, py: f32, r: Rect, radius: f32, sigma: f32) f32 {
    const d = roundedRectDistance(px, py, r, radius);
    if (sigma <= 0) return std.math.clamp(0.5 - d, 0, 1);
    const k = 1 / (sigma * std.math.sqrt2);
    const across = (erf((px - r.x) * k) - erf((px - r.right()) * k)) * 0.5;
    const down = (erf((py - r.y) * k) - erf((py - r.bottom()) * k)) * 0.5;
    return @max(0, @min(across * down, 0.5 - 0.5 * erf(d * k)));
}

/// The error function, within 5e-4 (as the shaders compute it).
pub fn erf(x: f32) f32 {
    const a = @abs(x);
    var t = 1 + (0.278393 + (0.230389 + 0.078108 * a * a) * a) * a;
    t *= t;
    const e = 1 - 1 / (t * t);
    return if (x < 0) -e else e;
}

pub fn roundedRectDistance(px: f32, py: f32, r: Rect, radius: f32) f32 {
    const qx = @abs(px - (r.x + r.width / 2)) - (r.width / 2 - radius);
    const qy = @abs(py - (r.y + r.height / 2)) - (r.height / 2 - radius);
    const ox = fmax(qx, 0);
    const oy = fmax(qy, 0);
    return @sqrt(ox * ox + oy * oy) + fmin(fmax(qx, qy), 0) - radius;
}

/// Rasterizes display lists into canvases of pixel type `P` (`Rgba8` or
/// `Rgb565`). Keeps scratch memory between frames.
pub fn Renderer(comptime P: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        /// Physical pixels per logical pixel (2 on a typical HiDPI
        /// display). Canvases and returned regions are in physical pixels.
        scale_factor: f32 = 1,
        display_list: DisplayList,
        path_commands: std.ArrayList(path.Command) = .empty,
        polylines: path.Polylines = .{},
        mask: raster.Mask = .{},
        glyphs: GlyphCache = .{},
        /// Draws rotated and scaled commands, as the GPU renderer does
        /// (made when one comes).
        transformed: ?*gpu_batch.Batcher = null,
        /// Draws layers into images of their own.
        layers: layers.Layers,
        /// Per command of a frame: whether a later one hides it.
        hidden: std.ArrayList(bool) = .empty,
        /// Texts laid out lately (not on microcontrollers).
        texts: if (spans.enabled) TextCache else void = if (spans.enabled) .{} else {},

        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa, .display_list = .init(gpa, .empty), .layers = .init(gpa) };
        }

        pub fn deinit(self: *Self) void {
            self.layers.deinit();
            self.hidden.deinit(self.gpa);
            if (spans.enabled) self.texts.deinit(self.gpa);
            self.display_list.deinit();
            self.path_commands.deinit(self.gpa);
            self.polylines.deinit(self.gpa);
            self.mask.deinit(self.gpa);
            self.glyphs.deinit(self.gpa);
            if (self.transformed) |b| {
                b.deinit();
                self.gpa.destroy(b);
            }
        }

        /// Renders the window into `canvas`, a framebuffer covering the
        /// window that keeps its contents between frames: in `.partial`
        /// mode only what changed is redrawn. Returns the redrawn region.
        pub fn renderWindow(self: *Self, window: *core.Window, canvas: Canvas(P), mode: core.RenderMode) Allocator.Error!Region {
            const region = try self.record(window, mode);
            try self.drawCommands(canvas, self.display_list.commands.items, canvas.bounds());
            return region;
        }

        /// Line-by-line rendering for devices without a framebuffer: the
        /// redrawn region is rendered in bands of `band_height` lines into
        /// `band` (at least window width x `band_height` pixels), and each
        /// finished band is passed to `flush(ctx, band_canvas)`.
        pub fn renderWindowInBands(
            self: *Self,
            window: *core.Window,
            mode: core.RenderMode,
            band: []P,
            band_height: u32,
            ctx: anytype,
            comptime flush: fn (@TypeOf(ctx), Canvas(P)) void,
        ) Allocator.Error!Region {
            const region = try self.record(window, mode);
            for (region.slice()) |r| {
                const area = PixelRect.centersIn(r);
                if (area.isEmpty()) continue;
                const w = area.width();
                std.debug.assert(band.len >= @as(usize, w) * band_height);
                var y = area.y0;
                while (y < area.y1) : (y += @intCast(band_height)) {
                    const h: u32 = @intCast(@min(@as(i32, @intCast(band_height)), area.y1 - y));
                    var canvas: Canvas(P) = .{ .pixels = band, .width = w, .height = h, .stride = w, .origin_x = area.x0, .origin_y = y };
                    canvas.fill(std.mem.zeroes(P));
                    try self.drawCommands(canvas, self.display_list.commands.items, canvas.bounds());
                    flush(ctx, canvas);
                }
            }
            return region;
        }

        /// Records the window's draw calls, converted to physical pixels,
        /// and returns the redrawn region in physical pixels.
        fn record(self: *Self, window: *core.Window, mode: core.RenderMode) Allocator.Error!Region {
            self.display_list.reset(.fromOriginSize(.{}, window.size()));
            self.layers.newFrame();
            const region = try window.renderAt(self.display_list.renderer(), mode, self.scale_factor);
            if (self.display_list.out_of_memory) return error.OutOfMemory;
            const s = self.scale_factor;
            if (s == 1) return region;
            for (self.display_list.commands.items) |*cmd| scaleCommand(cmd, s);
            var physical: Region = .{};
            for (region.slice()) |r| physical.add(scaleRect(r, s).roundOut());
            return physical;
        }

        /// Draws `commands` into `canvas`, limited to `clip` (window
        /// coordinates).
        pub fn drawCommands(self: *Self, canvas: Canvas(P), commands: []const Command, clip: Rect) Allocator.Error!void {
            const bounds = PixelRect.centersIn(canvas.bounds().intersection(clip));
            const flat = try self.layers.flatten(commands, self.scale_factor);
            const hidden = if (spans.enabled) try self.hiddenCommands(flat, bounds) else &.{};
            for (flat, 0..) |*cmd, i| {
                if (hidden.len > 0 and hidden[i]) continue;
                switch (cmd.*) {
                    inline else => |c| if (core.transforms and c.transform != null) {
                        try self.drawTransformed(canvas, cmd, clip);
                        continue;
                    },
                }
                // A layer tilted in depth: as the GPU renderer maps it (a
                // transform: not in programs built without them).
                if (core.transforms and cmd.* == .image and cmd.image.style.projection != null) {
                    try self.drawTransformed(canvas, cmd, clip);
                    continue;
                }
                try self.drawCommand(canvas, cmd, bounds);
            }
        }

        /// Which of `cmds` a later one hides: all the pixels it would touch
        /// are replaced by an opaque image or rectangle drawn after it (the
        /// window's background under a full-screen picture). Not drawing
        /// them saves going through those pixels, which on a small board's
        /// memory is most of the cost.
        fn hiddenCommands(self: *Self, cmds: []const Command, bounds: PixelRect) Allocator.Error![]const bool {
            try self.hidden.resize(self.gpa, cmds.len);
            const hidden = self.hidden.items;
            @memset(hidden, false);
            var covers: [4]PixelRect = undefined;
            var n: usize = 0;
            var i = cmds.len;
            while (i > 0) {
                i -= 1;
                const cmd = &cmds[i];
                if (touchedPixels(cmd, bounds)) |touched| {
                    for (covers[0..n]) |c| if (c.contains(touched)) {
                        hidden[i] = true;
                        break;
                    };
                }
                if (hidden[i]) continue;
                const cover = coveredPixels(cmd, bounds, self.scale_factor) orelse continue;
                if (cover.isEmpty()) continue;
                if (n < covers.len) {
                    covers[n] = cover;
                    n += 1;
                } else {
                    // Keep the largest.
                    var smallest: usize = 0;
                    for (covers[1..], 1..) |c, k| if (c.area() < covers[smallest].area()) {
                        smallest = k;
                    };
                    if (cover.area() > covers[smallest].area()) covers[smallest] = cover;
                }
            }
            return hidden;
        }

        /// All the pixels `cmd` may draw (within `bounds`); null if not
        /// known (turned, a path).
        fn touchedPixels(cmd: *const Command, bounds: PixelRect) ?PixelRect {
            switch (cmd.*) {
                inline else => |c| if (core.transforms and c.transform != null) return null,
            }
            return switch (cmd.*) {
                .rectangle => |c| drawArea(c.rect, c.clip, bounds),
                .image => |c| if (c.style.projection != null) null else drawArea(c.rect, c.clip, bounds),
                .text => |c| drawArea(c.rect, c.clip, bounds),
                .shadow => |c| drawArea(c.style.ink(c.rect), c.clip, bounds),
                .path, .layer, .end_layer => null,
            };
        }

        /// The pixels `cmd` replaces with opaque ones (within `bounds`);
        /// null if none for sure.
        fn coveredPixels(cmd: *const Command, bounds: PixelRect, scale: f32) ?PixelRect {
            switch (cmd.*) {
                inline else => |c| if (core.transforms and c.transform != null) return null,
            }
            switch (cmd.*) {
                .rectangle => |c| {
                    const s = &c.style;
                    if (alpha8(c.opacity) != 255 or s.background != .solid or s.background.solid.a != 255) return null;
                    if (s.border_width > 0 and !s.border_color.isTransparent()) return null;
                    // Away from the rounded corners: the rows between
                    // them, or the columns, whichever is more.
                    const r = c.rect;
                    const radius = @min(s.border_radius, r.width / 2, r.height / 2);
                    const rows = PixelRect.within(.{ .x = r.x, .y = r.y + radius, .width = r.width, .height = r.height - 2 * radius });
                    const cols = PixelRect.within(.{ .x = r.x + radius, .y = r.y, .width = r.width - 2 * radius, .height = r.height });
                    const inside = if (rows.area() >= cols.area()) rows else cols;
                    return inside.intersect(PixelRect.centersIn(c.clip)).intersect(bounds);
                },
                .image => |c| {
                    const s = &c.style;
                    if (!s.image.is_opaque or s.colorize != null or s.projection != null or s.scene != null or alpha8(c.opacity) != 255) return null;
                    const dest = imageDest(s, c.rect, scale) orelse return null;
                    return PixelRect.centersIn(dest.intersection(c.rect)).intersect(PixelRect.centersIn(c.clip)).intersect(bounds);
                },
                else => return null,
            }
        }

        fn drawCommand(self: *Self, canvas: Canvas(P), cmd: *const Command, bounds: PixelRect) Allocator.Error!void {
            switch (cmd.*) {
                .rectangle => |*c| drawRectangle(canvas, c, bounds),
                .image => |*c| if (c.style.scene) |sc| {
                    // A 3D scene: its picture, drawn on the CPU.
                    var with = c.*;
                    with.style.image = sc.picture() orelse return;
                    with.style.scene = null;
                    drawImage(canvas, &with, bounds, self.scale_factor);
                } else drawImage(canvas, c, bounds, self.scale_factor),
                .path => |*c| try self.drawPath(canvas, c, bounds),
                .shadow => |*c| drawShadow(canvas, c, bounds),
                .text => |*c| try self.drawText(canvas, c, bounds),
                // Drawn as images (`layers.flatten`).
                .layer, .end_layer => {},
            }
        }

        /// A rotated or scaled command: built as the GPU renderer builds it
        /// and shaded on the CPU, as its reference does (the same pixels).
        fn drawTransformed(self: *Self, canvas: Canvas(P), cmd: *const Command, clip: Rect) Allocator.Error!void {
            const b = self.transformed orelse blk: {
                const nb = try self.gpa.create(gpu_batch.Batcher);
                errdefer self.gpa.destroy(nb);
                nb.* = try .init(self.gpa);
                self.transformed = nb;
                break :blk nb;
            };
            var one = cmd.*;
            switch (one) {
                inline else => |*c| c.clip = c.clip.intersection(clip),
            }
            const width: u32 = @intCast(@max(0, canvas.origin_x + @as(i32, @intCast(canvas.width))));
            const height: u32 = @intCast(@max(0, canvas.origin_y + @as(i32, @intCast(canvas.height))));
            const frame = try b.buildCommands((&one)[0..1], width, height);
            gpu_reference.drawOnto(&frame, P, canvas);
        }

        fn drawArea(rect: Rect, clip: Rect, bounds: PixelRect) PixelRect {
            return PixelRect.touching(rect).intersect(PixelRect.centersIn(clip)).intersect(bounds);
        }

        fn drawRectangle(canvas: Canvas(P), cmd: *const Command.Draw(rendering.RectangleStyle), bounds: PixelRect) void {
            const s = &cmd.style;
            const r = cmd.rect;
            const pixels = drawArea(r, cmd.clip, bounds);
            if (pixels.isEmpty()) return;
            const radius = @min(s.border_radius, r.width / 2, r.height / 2);
            const bw = @min(s.border_width, r.width / 2, r.height / 2);
            const has_border = bw > 0 and !s.border_color.isTransparent();
            const has_background = !s.background.isTransparent();
            const inner: Rect = .{ .x = r.x + bw, .y = r.y + bw, .width = r.width - 2 * bw, .height = r.height - 2 * bw };
            const inner_radius = @max(0, radius - bw);
            const background = Paint.init(&s.background, r);
            const border = Paint.init(&s.border_color, r);
            const opacity = cmd.opacity;
            // Where the background covers whole pixels: the shape inside the
            // border (or the whole shape without one), away from its
            // rounded corners. There its coverage is 1, as the distance
            // function would say: no distance to compute, and a solid color
            // is the same for the whole span.
            const fill = if (has_border) inner else r;
            const fill_radius = if (has_border) inner_radius else radius;
            const span_color: ?Rgba8 = if (background == .solid) background.solid.scale(alpha8(opacity)) else null;
            // The rows between the corners have the same span.
            var straight: if (spans.enabled) ?[2]i32 else void = if (spans.enabled) null else {};

            var y = pixels.y0;
            while (y < pixels.y1) : (y += 1) {
                if (spans.enabled and y + 1 < pixels.y1) canvas.prefetch(pixels.x0, pixels.x1, y + 1);
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                var x = pixels.x0;
                const span = if (has_background) (if (spans.enabled) rowSpan(fill, fill_radius, y, pixels, &straight) else fullSpan(fill, fill_radius, y, pixels)) else .{ pixels.x1, pixels.x1 };
                // All of the row in the span, in a solid color: blended
                // at once, without setting up the edges' distances.
                if (spans.enabled and span[0] == pixels.x0 and span[1] == pixels.x1 and span[1] > span[0]) if (span_color) |c| {
                    const row = canvas.span(span[0], span[1], y);
                    if (c.a == 255) @memset(row, opaquePixel(P, c)) else spans.blendColor(P, row, c);
                    continue;
                };
                while (x < pixels.x1) : (x += 1) {
                    if (x == span[0] and span[1] > span[0]) {
                        const row = canvas.pixels[@as(usize, @intCast(y - canvas.origin_y)) * canvas.stride ..];
                        const from: usize = @intCast(span[0] - canvas.origin_x);
                        const to: usize = @intCast(span[1] - canvas.origin_x);
                        if (span_color) |c| {
                            if (c.a == 255) {
                                @memset(row[from..to], opaquePixel(P, c));
                            } else if (spans.enabled) {
                                spans.blendColor(P, row[from..to], c);
                            } else for (row[from..to]) |*dst| blend(P, dst, c);
                        } else for (row[from..to], 0..) |*dst, i| {
                            const px = @as(f32, @floatFromInt(span[0] + @as(i32, @intCast(i)))) + 0.5;
                            blend(P, dst, background.at(px, py).scale(alpha8(opacity)));
                        }
                        x = span[1] - 1;
                        continue;
                    }
                    const px = @as(f32, @floatFromInt(x)) + 0.5;
                    const outer = fclamp(0.5 - roundedRectDistance(px, py, r, radius), 0, 1);
                    if (outer == 0) continue;
                    const dst = canvas.at(x, y);
                    if (has_border) {
                        const in = fclamp(0.5 - roundedRectDistance(px, py, inner, inner_radius), 0, 1);
                        if (has_background and in > 0) blend(P, dst, background.at(px, py).scale(alpha8(in * opacity)));
                        if (outer > in) blend(P, dst, border.at(px, py).scale(alpha8((outer - in) * opacity)));
                    } else if (has_background) {
                        blend(P, dst, background.at(px, py).scale(alpha8(outer * opacity)));
                    }
                }
            }
        }

        fn drawShadow(canvas: Canvas(P), cmd: *const Command.Draw(rendering.ShadowStyle), bounds: PixelRect) void {
            const s = &cmd.style;
            const r = cmd.rect;
            const pixels = drawArea(s.ink(r), cmd.clip, bounds);
            if (pixels.isEmpty()) return;
            const radius = @min(s.border_radius, r.width / 2, r.height / 2);
            const sigma = @max(0, s.blur) / 2;
            const color = s.color.premultiplied();
            var y = pixels.y0;
            while (y < pixels.y1) : (y += 1) {
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                var x = pixels.x0;
                while (x < pixels.x1) : (x += 1) {
                    const coverage = shadowCoverage(@as(f32, @floatFromInt(x)) + 0.5, py, r, radius, sigma);
                    if (coverage > 0) blend(P, canvas.at(x, y), color.scale(alpha8(coverage * cmd.opacity)));
                }
            }
        }

        /// `scale` sizes nine-slice borders, which are given in image pixels
        /// but drawn at their logical size.
        fn drawImage(canvas: Canvas(P), cmd: *const Command.Draw(rendering.ImageStyle), bounds: PixelRect, scale: f32) void {
            const s = &cmd.style;
            const img = s.image;
            if (img.width == 0 or img.height == 0) return;
            const r = cmd.rect;
            const iw: f32 = @floatFromInt(img.width);
            const ih: f32 = @floatFromInt(img.height);

            const dest = imageDest(s, r, scale) orelse return;
            const pixels = PixelRect.centersIn(dest.intersection(r)).intersect(PixelRect.centersIn(cmd.clip)).intersect(bounds);
            if (pixels.isEmpty()) return;
            const tile = imageTile(s, dest, scale);

            const colorize: ?Paint = if (s.colorize) |*c| Paint.init(c, r) else null;
            const opacity = alpha8(cmd.opacity);

            // Drawn at its own size on whole pixels (an icon, a
            // background): each pixel is one of the image's, as sampling
            // would give it, blended a row at a time.
            if (spans.enabled and s.nine_slice == null and tile == null and colorize == null and dest.width == iw and dest.height == ih and
                dest.x == @floor(dest.x) and dest.y == @floor(dest.y))
            {
                const dx = toInt(dest.x);
                const dy = toInt(dest.y);
                var y = pixels.y0;
                while (y < pixels.y1) : (y += 1) {
                    const line = img.pixels[@as(usize, @intCast(y - dy)) * img.width ..];
                    const from = line[@intCast(pixels.x0 - dx)..@intCast(pixels.x1 - dx)];
                    if (y + 1 < pixels.y1) {
                        canvas.prefetch(pixels.x0, pixels.x1, y + 1);
                        if (pixels.x1 - pixels.x0 != img.width) prefetchBytes(std.mem.sliceAsBytes(line[img.width..][@intCast(pixels.x0 - dx)..@intCast(pixels.x1 - dx)]));
                    }
                    if (img.is_opaque and opacity == 255) {
                        spans.copyRow(P, canvas.span(pixels.x0, pixels.x1, y), from);
                    } else spans.blendRow(P, canvas.span(pixels.x0, pixels.x1, y), from, opacity);
                }
                return;
            }

            var y = pixels.y0;
            while (y < pixels.y1) : (y += 1) {
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                const v = if (s.nine_slice) |n|
                    nineSliceMap(py - dest.y, dest.height, ih, n.top, n.bottom, scale)
                else if (tile) |t|
                    tileMap(py - dest.y, t[1]) * ih
                else
                    (py - dest.y) * ih / dest.height;
                var x = pixels.x0;
                while (x < pixels.x1) : (x += 1) {
                    const px = @as(f32, @floatFromInt(x)) + 0.5;
                    const u = if (s.nine_slice) |n|
                        nineSliceMap(px - dest.x, dest.width, iw, n.left, n.right, scale)
                    else if (tile) |t|
                        tileMap(px - dest.x, t[0]) * iw
                    else
                        (px - dest.x) * iw / dest.width;
                    var c = switch (s.rendering) {
                        .pixelated => nearest(img, u, v),
                        .smooth => bilinear(img, u, v),
                    };
                    if (colorize) |paint| c = paint.at(px, py).scale(c.a);
                    blend(P, canvas.at(x, y), c.scale(opacity));
                }
            }
        }

        fn drawPath(self: *Self, canvas: Canvas(P), cmd: *const Command.Draw(rendering.PathStyle), bounds: PixelRect) Allocator.Error!void {
            const Ctx = struct { self: *Self, canvas: Canvas(P), cmd: *const Command.Draw(rendering.PathStyle) };
            try pathMasks(self.gpa, .{ .commands = &self.path_commands, .polylines = &self.polylines, .mask = &self.mask }, cmd, bounds, Ctx{ .self = self, .canvas = canvas, .cmd = cmd }, struct {
                fn f(ctx: Ctx, pixels: PixelRect, mask: *const raster.Mask, brush: *const Brush) Allocator.Error!void {
                    _ = mask;
                    ctx.self.blendMask(ctx.canvas, pixels, brush, ctx.cmd);
                }
            }.f);
        }

        fn drawText(self: *Self, canvas: Canvas(P), cmd: *const Command.Draw(rendering.TextStyle), bounds: PixelRect) Allocator.Error!void {
            // Text stays within its item, like every other draw call.
            const clip = PixelRect.centersIn(cmd.clip.intersection(cmd.rect)).intersect(bounds);
            if (clip.isEmpty()) return;
            const paint = Paint.init(&cmd.style.color, cmd.rect);
            const pen: Pen = .{ .canvas = canvas, .clip = clip, .paint = &paint, .opacity = alpha8(cmd.opacity), .font_size = cmd.style.font_size };
            // Laid out as before, when all its lines show here.
            if (spans.enabled) if (try self.texts.get(self.gpa, cmd)) |kept| if (kept[0].whole(clip)) {
                for (kept[1]) |g| try self.drawGlyph(pen, g.font, g.glyph, g.x, g.y);
                return;
            };
            const Ctx = struct { self: *Self, pen: Pen };
            try placeGlyphs(cmd, clip, Ctx{ .self = self, .pen = pen }, struct {
                fn f(ctx: Ctx, font: *const Font, glyph: u16, pen_x: f32, pen_y: i32) Allocator.Error!void {
                    try ctx.self.drawGlyph(ctx.pen, font, glyph, pen_x, pen_y);
                }
            }.f);
        }

        /// Where and how glyphs are drawn.
        const Pen = struct {
            canvas: Canvas(P),
            clip: PixelRect,
            paint: *const Paint,
            opacity: u8,
            font_size: f32,
        };

        fn drawGlyph(self: *Self, pen: Pen, font: *const Font, glyph: u16, pen_x: f32, pen_y: i32) Allocator.Error!void {
            var ix: i32 = toInt(@floor(pen_x));
            var sub: u8 = @intFromFloat(@round((pen_x - @floor(pen_x)) * GlyphCache.subpixels));
            if (sub == GlyphCache.subpixels) {
                ix += 1;
                sub = 0;
            }
            // A pre-rendered glyph is drawn from the font itself: no copy in
            // the cache (it would grow with every new glyph, in one block).
            if (font.bitmap != null) {
                const img = font.glyphImage(glyph, pen.font_size) orelse return;
                const gx0 = ix + img.left;
                const gy0 = pen_y + img.top;
                const area_: PixelRect = (PixelRect{ .x0 = gx0, .y0 = gy0, .x1 = gx0 + @as(i32, img.width), .y1 = gy0 + @as(i32, img.height) }).intersect(pen.clip);
                if (area_.isEmpty()) return;
                var y = area_.y0;
                while (y < area_.y1) : (y += 1) {
                    if (spans.enabled and pen.paint.* == .solid and area_.width() <= row_chunk) {
                        var row: [row_chunk]u8 = undefined;
                        const cov = row[0..area_.width()];
                        for (cov, 0..) |*k, i| k.* = img.coverage(@intCast(area_.x0 + @as(i32, @intCast(i)) - gx0), @intCast(y - gy0));
                        spans.scaleCoverage(cov, pen.opacity);
                        spans.blendCoverage(P, pen.canvas.span(area_.x0, area_.x1, y), pen.paint.solid, cov);
                        continue;
                    }
                    var x = area_.x0;
                    while (x < area_.x1) : (x += 1) {
                        const cov = img.coverage(@intCast(x - gx0), @intCast(y - gy0));
                        if (cov == 0) continue;
                        const c = pen.paint.at(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
                        blend(P, pen.canvas.at(x, y), c.scale(mul8(cov, pen.opacity)));
                    }
                }
                return;
            }
            const bmp = try self.glyphs.get(self.gpa, font, glyph, pen.font_size, sub, &self.path_commands, &self.polylines, &self.mask);
            const coverage = self.glyphs.pool.items[bmp.offset..][0 .. @as(usize, bmp.width) * bmp.height];
            const gx0 = ix + bmp.left;
            const gy0 = pen_y + bmp.top;
            const area_: PixelRect = (PixelRect{ .x0 = gx0, .y0 = gy0, .x1 = gx0 + @as(i32, @intCast(bmp.width)), .y1 = gy0 + @as(i32, @intCast(bmp.height)) }).intersect(pen.clip);
            if (area_.isEmpty()) return;
            var y = area_.y0;
            while (y < area_.y1) : (y += 1) {
                const line_cov = coverage[@as(usize, @intCast(y - gy0)) * bmp.width ..];
                if (spans.enabled and y + 1 < area_.y1) pen.canvas.prefetch(area_.x0, area_.x1, y + 1);
                if (spans.enabled and pen.paint.* == .solid and area_.width() <= row_chunk) {
                    var row: [row_chunk]u8 = undefined;
                    const cov = row[0..area_.width()];
                    @memcpy(cov, line_cov[@intCast(area_.x0 - gx0)..@intCast(area_.x1 - gx0)]);
                    spans.scaleCoverage(cov, pen.opacity);
                    spans.blendCoverage(P, pen.canvas.span(area_.x0, area_.x1, y), pen.paint.solid, cov);
                    continue;
                }
                var x = area_.x0;
                while (x < area_.x1) : (x += 1) {
                    const cov = line_cov[@intCast(x - gx0)];
                    if (cov == 0) continue;
                    const c = pen.paint.at(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
                    blend(P, pen.canvas.at(x, y), c.scale(mul8(cov, pen.opacity)));
                }
            }
        }

        fn blendMask(self: *Self, canvas: Canvas(P), pixels: PixelRect, brush: *const Brush, cmd: *const Command.Draw(rendering.PathStyle)) void {
            const paint = Paint.init(brush, pathPaintRect(&cmd.style, cmd.rect));
            // A solid color: the mask's rows, a chunk at a time.
            if (spans.enabled and paint == .solid) {
                for (0..pixels.height()) |row| {
                    const y = pixels.y0 + @as(i32, @intCast(row));
                    if (spans.enabled and y + 1 < pixels.y1) canvas.prefetch(pixels.x0, pixels.x1, y + 1);
                    const line = self.mask.cells.items[row * self.mask.stride() ..][0..pixels.width()];
                    var x: usize = 0;
                    while (x < line.len) {
                        const n = @min(row_chunk, line.len - x);
                        var buf: [row_chunk]u8 = undefined;
                        spans.coverage8(buf[0..n], line[x..][0..n], cmd.opacity);
                        const x0 = pixels.x0 + @as(i32, @intCast(x));
                        spans.blendCoverage(P, canvas.span(x0, x0 + @as(i32, @intCast(n)), y), paint.solid, buf[0..n]);
                        x += n;
                    }
                }
                return;
            }
            for (0..pixels.height()) |row| {
                const y = pixels.y0 + @as(i32, @intCast(row));
                for (0..pixels.width()) |col| {
                    const coverage = self.mask.coverage(@intCast(col), @intCast(row));
                    if (coverage <= 0) continue;
                    const x = pixels.x0 + @as(i32, @intCast(col));
                    const c = paint.at(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
                    blend(P, canvas.at(x, y), c.scale(alpha8(coverage * cmd.opacity)));
                }
            }
        }
    };
}

/// Where an image is drawn in its item's rect `r` (before clipping to it);
/// null if nothing shows.
pub fn imageDest(s: *const rendering.ImageStyle, r: Rect, scale: f32) ?Rect {
    const iw: f32 = @floatFromInt(s.image.width);
    const ih: f32 = @floatFromInt(s.image.height);
    const dest: Rect = if (s.nine_slice != null) r else switch (s.fit) {
        .fill => r,
        .contain, .cover => blk: {
            const sx = r.width / iw;
            const sy = r.height / ih;
            const fit = if (s.fit == .contain) @min(sx, sy) else @max(sx, sy);
            break :blk centered(r, iw * fit, ih * fit);
        },
        .preserve => centered(r, iw * scale, ih * scale),
        .tile, .tile_horizontally, .tile_vertically => r,
    };
    if (dest.width <= 0 or dest.height <= 0) return null;
    return dest;
}

/// The size of one tile of an image drawn over `dest` (`imageDest`'s) if
/// it is tiled; null if not or if the tiles would be empty.
pub fn imageTile(s: *const rendering.ImageStyle, dest: Rect, scale: f32) ?[2]f32 {
    if (s.nine_slice != null) return null;
    const iw: f32 = @floatFromInt(s.image.width);
    const ih: f32 = @floatFromInt(s.image.height);
    const t = s.fit.tileSize(.{ iw * scale, ih * scale }, .{ dest.width, dest.height }) orelse return null;
    if (!(t[0] > 0 and t[1] > 0)) return null;
    return t;
}

/// Where `x` (from the start of the tiles) falls in its tile of `size`: 0
/// at the tile's start, 1 at its end.
pub fn tileMap(x: f32, size: f32) f32 {
    const k = @floor(x / size);
    return (x - k * size) / size;
}

/// Paths are drawn at their rect's position with the fraction of a pixel
/// rounded to this: the GPU renderer keeps their masks by that fraction
/// (noise in where a shape is computed to be would otherwise make new
/// ones), and both draw them there.
pub const path_steps: f32 = 64;

/// A path rect's coordinate `v` as drawn: whole pixels and a fraction
/// rounded to 1 / `path_steps`.
pub fn pathOrigin(v: f32) struct { i32, f32 } {
    const whole = toInt(@floor(v + 0.5 / path_steps));
    return .{ whole, @round((v - @as(f32, @floatFromInt(whole))) * path_steps) / path_steps };
}

/// How a path's coordinates (in `source`, its viewbox or bounds) map into
/// its item's `rect`: at a uniform scale, centered (or stretched), keeping
/// a stroke inside the item unless told not to.
fn pathTransform(s: *const rendering.PathStyle, rect: Rect, source: Rect) path.Transform {
    const strokes = s.stroke_width > 0 and !s.stroke.isTransparent();
    const inset = if (strokes and s.inset_stroke) s.stroke_width / 2 else 0;
    const target: Rect = .{ .x = rect.x + inset, .y = rect.y + inset, .width = rect.width - 2 * inset, .height = rect.height - 2 * inset };
    return if (s.stretch) .fit(source, target) else .contain(source, target);
}

/// The box a path's gradients span: its `paint_box` where the path puts
/// it, else its item's `rect`.
pub fn pathPaintRect(s: *const rendering.PathStyle, rect: Rect) Rect {
    const box = s.paint_box orelse return rect;
    const t = pathTransform(s, rect, s.viewbox orelse return rect);
    const p0 = t.apply(.{ .x = box.x, .y = box.y });
    const p1 = t.apply(.{ .x = box.x + box.width, .y = box.y + box.height });
    return .{ .x = p0.x, .y = p0.y, .width = p1.x - p0.x, .height = p1.y - p0.y };
}

/// Scratch memory for rasterizing paths.
pub const PathScratch = struct {
    commands: *std.ArrayList(path.Command),
    polylines: *path.Polylines,
    mask: *raster.Mask,
};

/// Rasterizes a path's fill, then its stroke, into coverage masks over
/// `pixels` (within `bounds`), passing each to `emit` with its brush.
pub fn pathMasks(
    gpa: Allocator,
    scratch: PathScratch,
    cmd: *const Command.Draw(rendering.PathStyle),
    bounds: PixelRect,
    ctx: anytype,
    comptime emit: fn (@TypeOf(ctx), PixelRect, *const raster.Mask, *const Brush) Allocator.Error!void,
) Allocator.Error!void {
    const s = &cmd.style;
    scratch.commands.clearRetainingCapacity();
    path.parse(gpa, s.commands, scratch.commands) catch |err| switch (err) {
        error.InvalidPath => return,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const strokes = s.stroke_width > 0 and !s.stroke.isTransparent();
    const half = if (strokes) s.stroke_width / 2 else 0;

    // Map the viewbox (or the path's own bounds) into the item.
    const source = s.viewbox orelse blk: {
        try path.flatten(gpa, scratch.commands.items, .{}, 0.1, scratch.polylines);
        break :blk scratch.polylines.bounds();
    };
    const x, const fx = pathOrigin(cmd.rect.x);
    const y, const fy = pathOrigin(cmd.rect.y);
    var rect = cmd.rect;
    rect.x = @as(f32, @floatFromInt(x)) + fx;
    rect.y = @as(f32, @floatFromInt(y)) + fy;
    try path.flatten(gpa, scratch.commands.items, pathTransform(s, rect, source), 0.2, scratch.polylines);

    const shape = scratch.polylines.bounds();
    const reach: Rect = .{ .x = shape.x - half - 1, .y = shape.y - half - 1, .width = shape.width + 2 * half + 2, .height = shape.height + 2 * half + 2 };
    const pixels = PixelRect.touching(reach).intersect(PixelRect.centersIn(cmd.clip)).intersect(bounds);
    if (pixels.isEmpty()) return;
    const origin: Point = .{ .x = @floatFromInt(pixels.x0), .y = @floatFromInt(pixels.y0) };
    const mask = scratch.mask;
    const polylines = scratch.polylines;

    if (!s.fill.isTransparent()) {
        try mask.reset(gpa, pixels.width(), pixels.height());
        for (polylines.subpaths.items) |sub| {
            const pts = polylines.subpathPoints(sub);
            for (pts, 0..) |p, i| mask.addEdge(p.sub(origin), pts[(i + 1) % pts.len].sub(origin));
        }
        mask.accumulate();
        try emit(ctx, pixels, mask, &s.fill);
    }
    if (strokes) {
        try mask.reset(gpa, pixels.width(), pixels.height());
        for (polylines.subpaths.items) |sub| {
            const pts = polylines.subpathPoints(sub);
            if (pts.len == 1) mask.addStrokeSegment(pts[0].sub(origin), pts[0].sub(origin), half);
            for (pts[0 .. pts.len - 1], pts[1..]) |a, b| mask.addStrokeSegment(a.sub(origin), b.sub(origin), half);
            if (sub.closed and pts.len > 2) mask.addStrokeSegment(pts[pts.len - 1].sub(origin), pts[0].sub(origin), half);
        }
        try emit(ctx, pixels, mask, &s.stroke);
    }
}

/// Lays out a text draw call and passes each glyph to `emit`, at its pen
/// position (`pen_x` in window pixels, `pen_y` the baseline row). Lines
/// outside `clip` are skipped.
pub fn placeGlyphs(
    cmd: *const Command.Draw(rendering.TextStyle),
    clip: PixelRect,
    ctx: anytype,
    comptime emit: anytype,
) Allocator.Error!void {
    try placeGlyphsIn(false, cmd, clip, ctx, emit);
}

/// Where the lines shown are: the top of the first and the last (as
/// `placeGlyphs` compares them with the clip), and their height. Null if
/// none.
pub const LineSpan = ?struct { first_top: f32, last_top: f32, line_height: f32 };

/// `placeGlyphs`, telling where its lines are if `lines_kept` (else not
/// keeping track: as small as before where nothing asks).
pub fn placeGlyphsIn(
    comptime lines_kept: bool,
    cmd: *const Command.Draw(rendering.TextStyle),
    clip: PixelRect,
    ctx: anytype,
    comptime emit: anytype,
) Allocator.Error!(if (lines_kept) LineSpan else void) {
    const none = if (lines_kept) @as(LineSpan, null) else {};
    const s = &cmd.style;
    const font = s.font orelse return none;
    if (s.text.len == 0 or s.font_size <= 0) return none;
    const r = cmd.rect;
    const max_width: ?f32 = if (s.wrap == .word_wrap) r.width else null;
    const metrics = text_layout.Metrics.initFallbacks(font, s.fallbacks, s.font_size).withSpacing(s.letter_spacing);
    const line_height = font.lineHeight(s.font_size);
    const ascent = @as(f32, @floatFromInt(font.ascender)) * font.scale(s.font_size);
    // The lines, counted and kept: laying them out again costs as much
    // (microcontrollers do, to spare their stack).
    var kept: [if (spans.enabled) 32 else 0]text_layout.Line = undefined;
    var lines: usize = 0;
    var counter: text_layout.LineIterator = .initMetrics(metrics, s.text, max_width);
    while (counter.next()) |l| : (lines += 1) {
        if (kept.len > 0 and lines < kept.len) kept[lines] = l;
    }
    // Elided wrapped text shows only the lines that fit.
    const elide = s.overflow == .elide;
    const shown = if (elide and max_width != null) @min(lines, @max(1, @as(usize, @intFromFloat(@floor(r.height / line_height))))) else lines;
    const block = line_height * @as(f32, @floatFromInt(shown));
    const top = r.y + switch (s.vertical_alignment) {
        .top => 0,
        .center => (r.height - block) / 2,
        .bottom => r.height - block,
    };

    var it: text_layout.LineIterator = .initMetrics(metrics, s.text, max_width);
    var row: usize = 0;
    var span: LineSpan = null;
    while (row < shown) : (row += 1) {
        const full_line = if (kept.len > 0 and lines <= kept.len) kept[row] else it.next() orelse break;
        const baseline = top + @as(f32, @floatFromInt(row)) * line_height + ascent;
        if (lines_kept) {
            if (span) |*sp| sp.last_top = baseline - ascent else span = .{ .first_top = baseline - ascent, .last_top = baseline - ascent, .line_height = line_height };
        }
        if (baseline - ascent > @as(f32, @floatFromInt(clip.y1)) or baseline - ascent + line_height < @as(f32, @floatFromInt(clip.y0))) continue;
        // The line, or what is left of it before an ellipsis: when too
        // wide, or the last line shown of more.
        var line = full_line;
        var ellipsis = false;
        const dots = text_layout.ellipsis(metrics);
        if (elide) {
            const last_of_more = row + 1 == shown and shown < lines;
            if (last_of_more and line.width + dots.width() <= r.width) {
                ellipsis = true; // room for it after the whole line
            } else {
                // Shorter than the item, or than the line itself when
                // more text follows (it must end with the ellipsis).
                const e = text_layout.elide(metrics, s.text, line, if (last_of_more) @min(r.width, line.width - 0.001) else r.width);
                if (e.elided) {
                    line = .{ .start = line.start, .end = e.end, .width = e.width };
                    ellipsis = true;
                }
            }
        }
        const shown_width = line.width + if (ellipsis) dots.width() else 0;
        const left = r.x + switch (s.horizontal_alignment) {
            .left => 0,
            .center => (r.width - shown_width) / 2,
            .right => r.width - shown_width,
        };
        const pen_y: i32 = toInt(@round(baseline));
        // A right-to-left paragraph ends on the left: the ellipsis
        // goes there.
        const rtl = ellipsis and text_layout.paragraphLevelAt(s.text, line.start) == 1;
        const text_left = if (rtl) left + dots.width() else left;
        var glyphs: text_layout.GlyphIterator = .initMetrics(metrics, s.text, line);
        while (glyphs.next()) |g| try emit(ctx, g.font orelse font, g.glyph, text_left + g.x + g.dx, pen_y + toInt(@round(g.dy)));
        if (ellipsis) {
            const dots_font = metrics.fontOf(dots.glyph) orelse font;
            const dots_left = if (rtl) left else left + line.width;
            for (0..dots.count) |k| try emit(ctx, dots_font, dots.glyph.id, dots_left + dots.advance * @as(f32, @floatFromInt(k)), pen_y);
        }
    }
    if (lines_kept) return span;
}

/// Where the glyphs of texts drawn lately go: laid out once, and again
/// only when something that places them changes (the text, its fonts,
/// size, spacing, wrapping, alignment or box). Laying out is most of a
/// label's cost on a small board.
pub const TextCache = struct {
    map: std.HashMapUnmanaged(Key, Run, Context, std.hash_map.default_max_load_percentage) = .empty,
    glyphs: std.ArrayList(Placed) = .empty,
    /// The keys' texts.
    texts: std.ArrayList(u8) = .empty,

    /// Texts longer than this (a document) are laid out each time, as
    /// only what shows of them is.
    const max_text = 512;
    /// Past this many glyphs or bytes of text, it starts again.
    const max_glyphs = 8192;
    const max_bytes = 32 * 1024;

    const Placed = struct { font: *const Font, glyph: u16, x: f32, y: i32 };

    pub const Run = struct {
        start: u32,
        len: u32,
        lines: LineSpan,

        /// Whether drawing within `clip` shows all its lines (as
        /// `placeGlyphs` would): then its glyphs are the ones it would
        /// place.
        fn whole(r: Run, clip: PixelRect) bool {
            const l = r.lines orelse return true;
            return !(l.last_top > @as(f32, @floatFromInt(clip.y1)) or l.first_top + l.line_height < @as(f32, @floatFromInt(clip.y0)));
        }
    };

    /// Everything `placeGlyphs` reads but the text (fonts by their data
    /// too: one freed and another loaded where it was is not taken for
    /// it).
    const Fixed = extern struct {
        font: usize,
        font_data: usize,
        font_len: usize,
        fallbacks: usize,
        fallbacks_len: usize,
        font_size: u32,
        letter_spacing: u32,
        rect: [4]u32,
        wrap: u32,
        overflow: u32,
        horizontal: u32,
        vertical: u32,
    };

    const Key = struct {
        text: []const u8,
        fixed: Fixed,

        fn of(cmd: *const Command.Draw(rendering.TextStyle), text: []const u8) Key {
            const s = &cmd.style;
            const r = cmd.rect;
            const font = s.font.?;
            return .{ .text = text, .fixed = .{
                .font = @intFromPtr(font),
                .font_data = @intFromPtr(font.data.ptr),
                .font_len = font.data.len,
                .fallbacks = @intFromPtr(s.fallbacks.ptr),
                .fallbacks_len = s.fallbacks.len,
                .font_size = @bitCast(s.font_size),
                .letter_spacing = @bitCast(s.letter_spacing),
                .rect = .{ @bitCast(r.x), @bitCast(r.y), @bitCast(r.width), @bitCast(r.height) },
                .wrap = @intFromEnum(s.wrap),
                .overflow = @intFromEnum(s.overflow),
                .horizontal = @intFromEnum(s.horizontal_alignment),
                .vertical = @intFromEnum(s.vertical_alignment),
            } };
        }
    };

    const Context = struct {
        pub fn hash(_: Context, k: Key) u64 {
            var h: std.hash.Wyhash = .init(0);
            h.update(k.text);
            h.update(std.mem.asBytes(&k.fixed));
            return h.final();
        }
        pub fn eql(_: Context, a: Key, b: Key) bool {
            return std.mem.eql(u8, a.text, b.text) and std.mem.eql(u8, std.mem.asBytes(&a.fixed), std.mem.asBytes(&b.fixed));
        }
    };

    pub fn deinit(c: *TextCache, gpa: Allocator) void {
        c.map.deinit(gpa);
        c.glyphs.deinit(gpa);
        c.texts.deinit(gpa);
    }

    fn clear(c: *TextCache) void {
        c.map.clearRetainingCapacity();
        c.glyphs.clearRetainingCapacity();
        c.texts.clearRetainingCapacity();
    }

    /// The glyphs of `cmd`, laid out now if they are not kept; null if it
    /// is not kept (no font, a long text).
    pub fn get(c: *TextCache, gpa: Allocator, cmd: *const Command.Draw(rendering.TextStyle)) Allocator.Error!?struct { Run, []const Placed } {
        const s = &cmd.style;
        if (s.font == null or s.text.len > max_text) return null;
        if (c.map.get(Key.of(cmd, s.text))) |run| return .{ run, c.glyphs.items[run.start..][0..run.len] };
        if (c.glyphs.items.len > max_glyphs or c.texts.items.len + s.text.len > max_bytes) c.clear();
        // Laid out whole (no line left out), into the pool.
        const start = c.glyphs.items.len;
        const everywhere: PixelRect = .{ .x0 = -1_000_000_000, .y0 = -1_000_000_000, .x1 = 1_000_000_000, .y1 = 1_000_000_000 };
        const Ctx = struct { c: *TextCache, gpa: Allocator };
        const lines = placeGlyphsIn(true, cmd, everywhere, Ctx{ .c = c, .gpa = gpa }, struct {
            fn f(ctx: Ctx, font: *const Font, glyph: u16, x: f32, y: i32) Allocator.Error!void {
                try ctx.c.glyphs.append(ctx.gpa, .{ .font = font, .glyph = glyph, .x = x, .y = y });
            }
        }.f) catch |err| {
            c.glyphs.shrinkRetainingCapacity(start);
            return err;
        };
        const text_start = c.texts.items.len;
        try c.texts.appendSlice(gpa, s.text);
        const run: Run = .{ .start = @intCast(start), .len = @intCast(c.glyphs.items.len - start), .lines = lines };
        // The key's text: the copy (the item's may change in place).
        try c.map.put(gpa, Key.of(cmd, c.texts.items[text_start..]), run);
        return .{ run, c.glyphs.items[run.start..][0..run.len] };
    }
};

/// How glyph outlines are rasterized.
pub const TextRendering = packed struct(u8) {
    /// Light hinting, vertical only: glyphs are scaled vertically so that
    /// the x-height falls on a whole pixel (sharp tops and bottoms of
    /// lowercase letters). Horizontal metrics, and so layout, are unchanged.
    hinting: bool = true,
    /// Outlines thickened slightly at small sizes (up to 0.3 px), as macOS
    /// does: thin stems no longer look washed out.
    stem_darkening: bool = true,
    _: u6 = 0,

    /// Pixels the outline grows by at `font_size` (Pathfinder's factors,
    /// which follow macOS).
    pub fn darkening(t: TextRendering, font_size: f32) Point {
        if (!t.stem_darkening or font_size >= 72) return .{};
        return .{ .x = @min(0.3, 0.0121 * font_size), .y = @min(0.3, 0.0121 * 1.25 * font_size) };
    }

    /// The vertical scale for `font` at `font_size`: the x-height on a
    /// whole number of pixels.
    pub fn verticalScale(t: TextRendering, font: *const Font, font_size: f32) f32 {
        const scale = font.scale(font_size);
        if (!t.hinting or font.x_height <= 0) return scale;
        const height = @as(f32, @floatFromInt(font.x_height)) * scale;
        if (height < 2) return scale;
        return scale * @round(height) / height;
    }
};

/// Moves every outline edge outwards by `amount` (pixels, per axis):
/// filled areas grow, holes shrink, whichever way the font winds its
/// contours.
pub fn dilate(polylines: *path.Polylines, amount: Point) void {
    if (amount.x == 0 and amount.y == 0) return;
    // Outer contours set the orientation (they enclose the most area).
    var area: f32 = 0;
    for (polylines.subpaths.items) |sub| {
        const pts = polylines.subpathPoints(sub);
        for (pts, 0..) |p, i| {
            const q = pts[(i + 1) % pts.len];
            area += p.x * q.y - q.x * p.y;
        }
    }
    if (area == 0) return;
    const sign: f32 = if (area > 0) 1 else -1;
    for (polylines.subpaths.items) |sub| {
        const pts = polylines.points.items[sub.start..][0..sub.len];
        if (pts.len < 3) continue;
        // Edges' outward normals, from the original points.
        const first = pts[0];
        var prev = pts[pts.len - 1];
        for (pts, 0..) |*p, i| {
            const next = if (i + 1 < pts.len) pts[i + 1] else first;
            const n0 = normal(prev, p.*, sign);
            const n1 = normal(p.*, next, sign);
            var b: Point = .{ .x = n0.x + n1.x, .y = n0.y + n1.y };
            const len = @sqrt(b.x * b.x + b.y * b.y);
            prev = p.*;
            if (len < 1e-6) continue;
            b = .{ .x = b.x / len, .y = b.y / len };
            // A corner moves further, so both edges move by the amount (up
            // to a limit at sharp corners).
            const k = 1 / @max(b.x * n0.x + b.y * n0.y, 0.5);
            p.* = .{ .x = p.x + b.x * k * amount.x, .y = p.y + b.y * k * amount.y };
        }
    }
}

fn normal(a: Point, b: Point, sign: f32) Point {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1e-6) return .{};
    return .{ .x = sign * dy / len, .y = -sign * dx / len };
}

/// Rasterized glyphs: 8-bit coverage bitmaps positioned relative to the pen
/// (integer x, baseline y).
pub const GlyphCache = struct {
    map: std.AutoHashMapUnmanaged(Key, Bitmap) = .empty,
    pool: std.ArrayList(u8) = .empty,
    /// How outlines are rasterized (cached glyphs keep theirs).
    options: TextRendering = .{},

    /// Horizontal positions are rounded to this fraction of a pixel.
    pub const subpixels = 4;
    /// The cache is cleared when it holds more glyphs than this.
    const max_glyphs = 2048;

    pub const Key = struct {
        font: usize,
        glyph: u16,
        /// Font size in 1/64 px.
        size: u32,
        subpixel: u8,
        options: TextRendering = .{},
    };

    pub const Bitmap = struct {
        left: i32,
        top: i32,
        width: u32,
        height: u32,
        offset: usize,
    };

    pub fn deinit(c: *GlyphCache, gpa: Allocator) void {
        c.map.deinit(gpa);
        c.pool.deinit(gpa);
    }

    fn get(
        c: *GlyphCache,
        gpa: Allocator,
        font: *const Font,
        glyph: u16,
        font_size: f32,
        subpixel: u8,
        commands: *std.ArrayList(path.Command),
        polylines: *path.Polylines,
        mask: *raster.Mask,
    ) Allocator.Error!Bitmap {
        // Pre-rendered glyphs sit on whole pixels.
        const sub = if (font.bitmap != null) 0 else subpixel;
        const key: Key = .{
            .font = @intFromPtr(font),
            .glyph = glyph,
            .size = @intFromFloat(@round(font_size * 64)),
            .subpixel = sub,
            .options = c.options,
        };
        if (c.map.get(key)) |b| return b;
        if (c.map.count() >= max_glyphs) {
            c.map.clearRetainingCapacity();
            c.pool.clearRetainingCapacity();
        }
        const bitmap = if (font.bitmap != null)
            try unpack(c, gpa, font, glyph, font_size)
        else
            try rasterize(c, gpa, font, glyph, font_size, subpixel, commands, polylines, mask);
        try c.map.put(gpa, key, bitmap);
        return bitmap;
    }

    /// A pre-rendered glyph's image, as 8-bit coverage.
    pub fn unpack(c: *GlyphCache, gpa: Allocator, font: *const Font, glyph: u16, font_size: f32) Allocator.Error!Bitmap {
        const img = font.glyphImage(glyph, font_size) orelse return .{ .left = 0, .top = 0, .width = 0, .height = 0, .offset = 0 };
        const offset = c.pool.items.len;
        try c.pool.ensureUnusedCapacity(gpa, @as(usize, img.width) * img.height);
        for (0..img.height) |y| for (0..img.width) |x| c.pool.appendAssumeCapacity(img.coverage(x, y));
        return .{ .left = img.left, .top = img.top, .width = img.width, .height = img.height, .offset = offset };
    }

    /// Renders a glyph into the pool (not the map).
    pub fn rasterize(
        c: *GlyphCache,
        gpa: Allocator,
        font: *const Font,
        glyph: u16,
        font_size: f32,
        subpixel: u8,
        commands: *std.ArrayList(path.Command),
        polylines: *path.Polylines,
        mask: *raster.Mask,
    ) Allocator.Error!Bitmap {
        const empty: Bitmap = .{ .left = 0, .top = 0, .width = 0, .height = 0, .offset = 0 };
        const box = font.glyphBox(glyph) orelse return empty;
        commands.clearRetainingCapacity();
        font.glyphOutline(gpa, glyph, commands) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return empty,
        };
        const scale = font.scale(font_size);
        const scale_y = c.options.verticalScale(font, font_size);
        const grow = c.options.darkening(font_size);
        const fx = @as(f32, @floatFromInt(subpixel)) / subpixels;
        const x0 = @floor(@as(f32, @floatFromInt(box.x_min)) * scale + fx - grow.x);
        const x1 = @ceil(@as(f32, @floatFromInt(box.x_max)) * scale + fx + grow.x);
        const y0 = @floor(-@as(f32, @floatFromInt(box.y_max)) * scale_y - grow.y);
        const y1 = @ceil(-@as(f32, @floatFromInt(box.y_min)) * scale_y + grow.y);
        const width: u32 = @intFromFloat(@max(0, x1 - x0));
        const height: u32 = @intFromFloat(@max(0, y1 - y0));
        if (width == 0 or height == 0 or width > 4096 or height > 4096) return empty;

        // Font units (y up) to bitmap pixels (y down).
        const transform: path.Transform = .{ .scale = .{ .x = scale, .y = -scale_y }, .offset = .{ .x = fx - x0, .y = -y0 } };
        try path.flatten(gpa, commands.items, transform, 0.1, polylines);
        dilate(polylines, grow);
        try mask.reset(gpa, width, height);
        for (polylines.subpaths.items) |sub| {
            const pts = polylines.subpathPoints(sub);
            for (pts, 0..) |p, i| mask.addEdge(p, pts[(i + 1) % pts.len]);
        }
        mask.accumulate();

        const offset = c.pool.items.len;
        try c.pool.ensureUnusedCapacity(gpa, @as(usize, width) * height);
        for (0..height) |y| for (0..width) |x| {
            c.pool.appendAssumeCapacity(alpha8(mask.coverage(@intCast(x), @intCast(y))));
        };
        return .{ .left = @intFromFloat(x0), .top = @intFromFloat(y0), .width = width, .height = height, .offset = offset };
    }
};

/// A pre-rendered font (core.text.bitmap_font) made from the TrueType font
/// `font`: `codepoints` (sorted, without duplicates) at each of `sizes`
/// (pixels), with their advances and the kerning between them.
pub fn makeBitmapFont(gpa: Allocator, font: *const Font, sizes: []const u16, codepoints: []const u21) (Allocator.Error || error{GlyphTooLarge})![]u8 {
    const bf = core.text.bitmap_font;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The original glyph of each new glyph: 0 is the missing glyph.
    const source = try arena.alloc(u16, codepoints.len + 1);
    source[0] = 0;
    for (codepoints, source[1..]) |cp, *g| g.* = font.glyphIndex(cp);
    const advances = try arena.alloc(u16, source.len);
    for (source, advances) |g, *a| a.* = font.advanceWidth(g);
    var kerning: std.ArrayList(bf.Spec.Kern) = .empty;
    for (source[1..], 1..) |l, i| for (source[1..], 1..) |r, j| {
        const k = font.kerning(l, r);
        if (k != 0) try kerning.append(arena, .{ .left = @intCast(i), .right = @intCast(j), .value = k });
    };

    var cache: GlyphCache = .{};
    defer cache.deinit(gpa);
    var commands: std.ArrayList(path.Command) = .empty;
    defer commands.deinit(gpa);
    var polylines: path.Polylines = .{};
    defer polylines.deinit(gpa);
    var mask: raster.Mask = .{};
    defer mask.deinit(gpa);
    const strikes = try arena.alloc(bf.Spec.Strike, sizes.len);
    for (sizes, strikes) |size, *strike| {
        const glyphs = try arena.alloc(bf.Spec.GlyphImage, source.len);
        for (source, glyphs) |g, *out| {
            const b = try cache.rasterize(gpa, font, g, @floatFromInt(size), 0, &commands, &polylines, &mask);
            if (b.width > 255 or b.height > 255 or b.left < -128 or b.left > 127 or b.top < -128 or b.top > 127) return error.GlyphTooLarge;
            out.* = .{
                .width = @intCast(b.width),
                .height = @intCast(b.height),
                .left = @intCast(b.left),
                .top = @intCast(b.top),
                .coverage = try arena.dupe(u8, cache.pool.items[b.offset..][0 .. b.width * b.height]),
            };
        }
        strike.* = .{ .pixel_size = size, .glyphs = glyphs };
    }
    return bf.encode(gpa, .{
        .units_per_em = font.units_per_em,
        .ascender = font.ascender,
        .descender = font.descender,
        .line_gap = font.line_gap,
        .codepoints = codepoints,
        .advances = advances,
        .kerning = kerning.items,
        .strikes = strikes,
    });
}

pub fn scaleRect(r: Rect, s: f32) Rect {
    return .{ .x = r.x * s, .y = r.y * s, .width = r.width * s, .height = r.height * s };
}

/// Converts a draw call from logical to physical pixels.
pub fn scaleCommand(cmd: *Command, s: f32) void {
    switch (cmd.*) {
        inline else => |*c| {
            c.rect = scaleRect(c.rect, s);
            c.clip = scaleRect(c.clip, s);
            // Rotated or scaled: the same rotation, between scaled
            // coordinates (S M S⁻¹: only the translation scales).
            if (c.transform) |*m| {
                m.tx *= s;
                m.ty *= s;
            }
        },
    }
    switch (cmd.*) {
        .rectangle => |*c| {
            c.style.border_width *= s;
            c.style.border_radius *= s;
        },
        .text => |*c| {
            c.style.font_size *= s;
            c.style.letter_spacing *= s;
        },
        .path => |*c| c.style.stroke_width *= s,
        .shadow => |*c| {
            c.style.blur *= s;
            c.style.border_radius *= s;
        },
        .layer => |*c| {
            c.style.blur *= s;
            if (c.style.projection) |*h| h.* = h.conjugate(.scaling(s, s));
            // As a command's rect and transform (the path stays over `box`).
            if (c.style.mask) |*m| {
                m.rect = scaleRect(m.rect, s);
                m.radius *= s;
                m.transform.tx *= s;
                m.transform.ty *= s;
            }
        },
        .image => |*c| if (c.style.projection) |*h| {
            h.* = h.conjugate(.scaling(s, s));
        },
        .end_layer => {},
    }
}

fn centered(r: Rect, w: f32, h: f32) Rect {
    return .{ .x = r.x + (r.width - w) / 2, .y = r.y + (r.height - h) / 2, .width = w, .height = h };
}

/// Maps a destination offset `t` in [0, dest) to a source coordinate for
/// nine-slice scaling: the `a` and `b` borders are drawn `scale` times their
/// source size (shrinking proportionally if they do not fit), the middle
/// stretches.
fn nineSliceMap(t: f32, dest: f32, src: f32, a_px: u32, b_px: u32, scale: f32) f32 {
    const a: f32 = @floatFromInt(a_px);
    const b: f32 = @floatFromInt(b_px);
    const shrink = if ((a + b) * scale > dest and a + b > 0) dest / (a + b) else scale;
    const da = a * shrink;
    const db = b * shrink;
    if (t < da) return t / shrink;
    if (t >= dest - db) return src - b + (t - (dest - db)) / shrink;
    const middle_dest = dest - da - db;
    const middle_src = src - a - b;
    return a + (t - da) * (if (middle_dest > 0) middle_src / middle_dest else 0);
}

fn nearest(img: core.Image, u: f32, v: f32) Rgba8 {
    const x: u32 = @intFromFloat(std.math.clamp(@floor(u), 0, @as(f32, @floatFromInt(img.width - 1))));
    const y: u32 = @intFromFloat(std.math.clamp(@floor(v), 0, @as(f32, @floatFromInt(img.height - 1))));
    return img.pixel(x, y);
}

/// Bilinear sampling at source coordinates (pixel centers at +0.5),
/// clamping at the edges.
fn bilinear(img: core.Image, u: f32, v: f32) Rgba8 {
    const maxx: f32 = @floatFromInt(img.width - 1);
    const maxy: f32 = @floatFromInt(img.height - 1);
    const fx = std.math.clamp(u - 0.5, 0, maxx);
    const fy = std.math.clamp(v - 0.5, 0, maxy);
    const x0: u32 = @intFromFloat(@floor(fx));
    const y0: u32 = @intFromFloat(@floor(fy));
    const x1 = @min(x0 + 1, img.width - 1);
    const y1 = @min(y0 + 1, img.height - 1);
    const tx = fx - @floor(fx);
    const ty = fy - @floor(fy);
    const p = [4]Rgba8{ img.pixel(x0, y0), img.pixel(x1, y0), img.pixel(x0, y1), img.pixel(x1, y1) };
    const w = [4]f32{ (1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty };
    var acc = [4]f32{ 0, 0, 0, 0 };
    for (p, w) |px, wt| {
        acc[0] += @as(f32, @floatFromInt(px.r)) * wt;
        acc[1] += @as(f32, @floatFromInt(px.g)) * wt;
        acc[2] += @as(f32, @floatFromInt(px.b)) * wt;
        acc[3] += @as(f32, @floatFromInt(px.a)) * wt;
    }
    return .{ .r = @intFromFloat(@round(acc[0])), .g = @intFromFloat(@round(acc[1])), .b = @intFromFloat(@round(acc[2])), .a = @intFromFloat(@round(acc[3])) };
}

const testing = std.testing;

test "draw calls under an opaque picture or rectangle are left out, the pixels the same" {
    if (!spans.enabled) return error.SkipZigTest;
    const gpa = testing.allocator;
    var px: [16 * 16]Rgba8 = undefined;
    for (&px, 0..) |*p, i| p.* = .{ .r = @truncate(i), .g = 40, .b = 200, .a = 255 };
    const picture: core.Image = .{ .width = 16, .height = 16, .pixels = &px, .is_opaque = true };
    var see_through = picture;
    see_through.is_opaque = false;

    var dl: DisplayList = .init(gpa, .{ .width = 16, .height = 16 });
    defer dl.deinit();
    var r: Renderer(Rgba8) = .init(gpa);
    defer r.deinit();
    const ir = dl.renderer();
    const whole: core.Size = .{ .width = 16, .height = 16 };
    // The window's fill, a button, the picture over all, a label on top.
    ir.drawRectangle(whole, .{ .background = .{ .solid = .rgb(0xffffff) } });
    ir.drawRectangle(.{ .width = 8, .height = 8 }, .{ .background = .{ .solid = .rgba(0xff000080) }, .border_radius = 3 });
    ir.drawImage(whole, .{ .image = picture });
    ir.drawRectangle(.{ .width = 4, .height = 4 }, .{ .background = .{ .solid = .rgba(0x00ff0080) } });
    const bounds: PixelRect = .{ .x0 = 0, .y0 = 0, .x1 = 16, .y1 = 16 };
    try testing.expectEqualSlices(bool, &.{ true, true, false, false }, try r.hiddenCommands(dl.commands.items, bounds));

    // Not when the picture may be see-through, faded, or leaves a part out.
    dl.commands.items[2].image.style.image = see_through;
    try testing.expectEqualSlices(bool, &.{ false, false, false, false }, try r.hiddenCommands(dl.commands.items, bounds));
    dl.commands.items[2].image.style.image = picture;
    dl.commands.items[2].image.opacity = 0.9;
    try testing.expectEqualSlices(bool, &.{ false, false, false, false }, try r.hiddenCommands(dl.commands.items, bounds));
    dl.commands.items[2].image.opacity = 1;
    dl.commands.items[2].image.clip = .{ .x = 0, .y = 0, .width = 16, .height = 12 };
    try testing.expectEqualSlices(bool, &.{ false, true, false, false }, try r.hiddenCommands(dl.commands.items, bounds));

    // An opaque rounded rectangle covers what is away from its corners.
    dl.commands.items[2] = .{ .rectangle = .{ .rect = .{ .width = 16, .height = 16 }, .clip = .{ .width = 16, .height = 16 }, .opacity = 1, .style = .{ .background = .{ .solid = .rgb(0x123456) }, .border_radius = 4 } } };
    try testing.expectEqualSlices(bool, &.{ false, false, false, false }, try r.hiddenCommands(dl.commands.items, bounds));
    dl.commands.items[1].rectangle.rect = .{ .x = 2, .y = 5, .width = 12, .height = 6 };
    try testing.expectEqualSlices(bool, &.{ false, true, false, false }, try r.hiddenCommands(dl.commands.items, bounds));
}

test "coverage to alpha: rounded as @round rounds" {
    var prng: std.Random.DefaultPrng = .init(3);
    const r = prng.random();
    for (0..100_000) |i| {
        const c = if (i < 512) @as(f32, @floatFromInt(i)) / 510 else r.float(f32) * 1.2 - 0.1;
        try testing.expectEqual(@as(u8, @intFromFloat(@round(std.math.clamp(c, 0, 1) * 255))), alpha8(c));
    }
    try testing.expectEqual(@as(u8, 0), alpha8(0.4999999 / 255.0));
}

test "full spans reach into rounded corners only where coverage is whole" {
    var prng: std.Random.DefaultPrng = .init(11);
    const r = prng.random();
    var taken: usize = 0;
    for (0..2000) |_| {
        const shape: Rect = .{ .x = r.float(f32) * 20, .y = r.float(f32) * 20, .width = 2 + r.float(f32) * 60, .height = 2 + r.float(f32) * 60 };
        const radius = @min(r.float(f32) * 24, shape.width / 2, shape.height / 2);
        const pixels: PixelRect = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 };
        var y: i32 = 0;
        while (y < 100) : (y += 1) {
            const span = fullSpan(shape, radius, y, pixels);
            var x = span[0];
            while (x < span[1]) : (x += 1) {
                const d = roundedRectDistance(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, shape, radius);
                try testing.expectEqual(@as(f32, 1), std.math.clamp(0.5 - d, 0, 1));
                taken += 1;
            }
        }
    }
    try testing.expect(taken > 100_000);
}

test "blending premultiplied colors" {
    var d: Rgba8 = core.Color.rgb(0x0000ff).premultiplied();
    blend(Rgba8, &d, core.Color.rgba(0xff000080).premultiplied());
    try testing.expectEqual(Rgba8{ .r = 128, .g = 0, .b = 127, .a = 255 }, d);
    var e: Rgb565 = .fromRgb8(0, 0, 255);
    blend(Rgb565, &e, core.Color.rgba(0xff000080).premultiplied());
    try testing.expectEqual([3]u8{ 132, 0, 123 }, e.toRgb8());
}

test "nine-slice mapping keeps borders" {
    // Source 30 wide with 10px borders, drawn 100 wide.
    try testing.expectEqual(@as(f32, 5), nineSliceMap(5, 100, 30, 10, 10, 1));
    try testing.expectEqual(@as(f32, 25), nineSliceMap(95, 100, 30, 10, 10, 1));
    try testing.expectEqual(@as(f32, 15), nineSliceMap(50, 100, 30, 10, 10, 1));
    // Drawn 10 wide: borders shrink to 5 each.
    try testing.expectEqual(@as(f32, 4), nineSliceMap(2, 10, 30, 10, 10, 1));
    // At scale 2 the borders are 20 destination pixels.
    try testing.expectEqual(@as(f32, 5), nineSliceMap(10, 100, 30, 10, 10, 2));
    try testing.expectEqual(@as(f32, 15), nineSliceMap(50, 100, 30, 10, 10, 2));
}

test "tiled images repeat at their natural size, from the top left" {
    // A 2x2 image: red, green / blue, white.
    const px = [_]Rgba8{
        core.Color.rgb(0xff0000).premultiplied(), core.Color.rgb(0x00ff00).premultiplied(),
        core.Color.rgb(0x0000ff).premultiplied(), core.Color.rgb(0xffffff).premultiplied(),
    };
    const img: core.Image = .{ .width = 2, .height = 2, .pixels = &px };
    var out: [7 * 5]Rgba8 = @splat(.transparent);
    var r: Renderer(Rgba8) = .init(testing.allocator);
    defer r.deinit();
    const cmd: Command = .{ .image = .{ .rect = .{ .x = 1, .y = 1, .width = 5, .height = 3 }, .clip = .{ .width = 7, .height = 5 }, .opacity = 1, .style = .{ .image = img, .fit = .tile, .rendering = .pixelated } } };
    try r.drawCommands(.init(&out, 7, 5), (&cmd)[0..1], .{ .width = 7, .height = 5 });
    for (0..5) |y| for (0..7) |x| {
        const inside = x >= 1 and x < 6 and y >= 1 and y < 4;
        const want: Rgba8 = if (inside) px[((y - 1) % 2) * 2 + (x - 1) % 2] else .transparent;
        try testing.expectEqual(want, out[y * 7 + x]);
    };
    // Tiled across, stretched down: each column takes the image's.
    try testing.expectEqual([2]f32{ 2, 3 }, imageTile(&.{ .image = img, .fit = .tile_horizontally }, cmd.image.rect, 1).?);
    try testing.expectEqual([2]f32{ 5, 4 }, imageTile(&.{ .image = img, .fit = .tile_vertically }, cmd.image.rect, 2).?);
    try testing.expectEqual(null, imageTile(&.{ .image = img, .fit = .tile, .nine_slice = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 } }, cmd.image.rect, 1));
    try testing.expectApproxEqAbs(@as(f32, 0.25), tileMap(4.5, 2), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.75), tileMap(-0.5, 2), 1e-6);
}

test {
    _ = raster;
    _ = spans;
}

test "texts laid out once: the glyphs placeGlyphs places, kept while nothing that places them changes" {
    const gpa = testing.allocator;
    const bytes = try core.text.test_font.standard(gpa);
    defer gpa.free(bytes);
    const font: Font = try .init(bytes);
    var cache: TextCache = .{};
    defer cache.deinit(gpa);

    var text = "Lights and climate, all the rooms".*;
    const Cmd = Command.Draw(rendering.TextStyle);
    const cases = [_]Cmd{
        .{ .rect = .{ .x = 3.25, .y = 7.5, .width = 60, .height = 20 }, .clip = .{ .width = 200, .height = 200 }, .opacity = 1, .style = .{ .text = &text, .font = &font, .color = .{ .solid = .rgb(0) }, .font_size = 13, .horizontal_alignment = .center } },
        .{ .rect = .{ .x = 0, .y = 0, .width = 50, .height = 80 }, .clip = .{ .width = 200, .height = 200 }, .opacity = 1, .style = .{ .text = &text, .font = &font, .color = .{ .solid = .rgb(0) }, .font_size = 11, .wrap = .word_wrap, .vertical_alignment = .center } },
        .{ .rect = .{ .x = 10, .y = 10, .width = 40, .height = 30 }, .clip = .{ .width = 200, .height = 200 }, .opacity = 1, .style = .{ .text = &text, .font = &font, .color = .{ .solid = .rgb(0) }, .font_size = 12, .wrap = .word_wrap, .overflow = .elide } },
    };
    const Placed = TextCache.Placed;
    const Direct = struct {
        fn of(cmd: *const Cmd, clip: PixelRect, out: *std.ArrayList(Placed)) !void {
            try placeGlyphs(cmd, clip, out, struct {
                fn f(o: *std.ArrayList(Placed), f_: *const Font, glyph: u16, x: f32, y: i32) Allocator.Error!void {
                    try o.append(testing.allocator, .{ .font = f_, .glyph = glyph, .x = x, .y = y });
                }
            }.f);
        }
    };
    const all: PixelRect = .{ .x0 = 0, .y0 = 0, .x1 = 200, .y1 = 200 };
    for (&cases) |*cmd| {
        var direct: std.ArrayList(Placed) = .empty;
        defer direct.deinit(gpa);
        try Direct.of(cmd, all, &direct);
        const kept = (try cache.get(gpa, cmd)).?;
        try testing.expect(kept[0].whole(all));
        try testing.expectEqualSlices(Placed, direct.items, kept[1]);
        // Drawn again: the same glyphs, not laid out again.
        const before = cache.glyphs.items.len;
        const again = (try cache.get(gpa, cmd)).?;
        try testing.expectEqual(kept[0].start, again[0].start);
        try testing.expectEqual(before, cache.glyphs.items.len);
    }
    // The wrapped text, redrawn where only some of its lines show: left
    // to placeGlyphs (which leaves the others out).
    const wrapped = (try cache.get(gpa, &cases[1])).?;
    try testing.expect(wrapped[0].lines != null);
    try testing.expect(!wrapped[0].whole(.{ .x0 = 0, .y0 = 0, .x1 = 200, .y1 = 30 }));
    // The text changed where it is (an item's buffer): laid out again.
    const old = (try cache.get(gpa, &cases[0])).?;
    text[0] = 'N';
    const new = (try cache.get(gpa, &cases[0])).?;
    try testing.expect(new[0].start != old[0].start);
    var direct: std.ArrayList(Placed) = .empty;
    defer direct.deinit(gpa);
    try Direct.of(&cases[0], all, &direct);
    try testing.expectEqualSlices(Placed, direct.items, new[1]);
}

test "hinting puts the x-height on whole pixels" {
    const bytes = try core.text.test_font.standard(testing.allocator);
    defer testing.allocator.free(bytes);
    const font: Font = try .init(bytes);
    try testing.expect(font.x_height > 0);
    const on: TextRendering = .{};
    for ([_]f32{ 9, 11, 13.5, 17 }) |size| {
        const height = @as(f32, @floatFromInt(font.x_height)) * on.verticalScale(&font, size);
        try testing.expectApproxEqAbs(@round(height), height, 1e-3);
    }
    const off: TextRendering = .{ .hinting = false };
    try testing.expectEqual(font.scale(11), off.verticalScale(&font, 11));
}

test "dilating outlines grows shapes and shrinks holes, whatever the winding" {
    var polylines: path.Polylines = .{};
    defer polylines.deinit(testing.allocator);
    const square = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    const hole = [_]Point{ .{ .x = 3, .y = 3 }, .{ .x = 3, .y = 7 }, .{ .x = 7, .y = 7 }, .{ .x = 7, .y = 3 } };
    for ([_]bool{ false, true }) |reversed| {
        polylines.clear();
        for ([_][]const Point{ &square, &hole }) |contour| {
            try polylines.subpaths.append(testing.allocator, .{ .start = @intCast(polylines.points.items.len), .len = 4, .closed = true });
            for (0..4) |i| try polylines.points.append(testing.allocator, contour[if (reversed) 3 - i else i]);
        }
        dilate(&polylines, .{ .x = 0.5, .y = 0.25 });
        const b = polylines.bounds();
        try testing.expectApproxEqAbs(@as(f32, -0.5), b.x, 1e-4);
        try testing.expectApproxEqAbs(@as(f32, 11), b.width, 1e-4);
        try testing.expectApproxEqAbs(@as(f32, 10.5), b.height, 1e-4);
        // The hole: 4 x 4, now 3 x 3.5.
        var hx0: f32 = 100;
        var hx1: f32 = -100;
        var hy0: f32 = 100;
        var hy1: f32 = -100;
        for (polylines.points.items[4..8]) |p| {
            hx0 = @min(hx0, p.x);
            hx1 = @max(hx1, p.x);
            hy0 = @min(hy0, p.y);
            hy1 = @max(hy1, p.y);
        }
        try testing.expectApproxEqAbs(@as(f32, 3), hx1 - hx0, 1e-4);
        try testing.expectApproxEqAbs(@as(f32, 3.5), hy1 - hy0, 1e-4);
    }
}

test "stem darkening adds ink at small sizes only" {
    const bytes = try core.text.test_font.standard(testing.allocator);
    defer testing.allocator.free(bytes);
    const font: Font = try .init(bytes);
    var commands: std.ArrayList(path.Command) = .empty;
    defer commands.deinit(testing.allocator);
    var polylines: path.Polylines = .{};
    defer polylines.deinit(testing.allocator);
    var mask: raster.Mask = .{};
    defer mask.deinit(testing.allocator);
    const ink = struct {
        fn of(options: TextRendering, f: *const Font, size: f32, cmds: *std.ArrayList(path.Command), polys: *path.Polylines, m: *raster.Mask) !u32 {
            var cache: GlyphCache = .{ .options = options };
            defer cache.deinit(testing.allocator);
            const b = try cache.rasterize(testing.allocator, f, f.glyphIndex('A'), size, 0, cmds, polys, m);
            var sum: u32 = 0;
            for (cache.pool.items[b.offset..][0 .. b.width * b.height]) |c| sum += c;
            return sum;
        }
    }.of;
    const plain: TextRendering = .{ .hinting = false, .stem_darkening = false };
    const dark: TextRendering = .{ .hinting = false };
    try testing.expect(try ink(dark, &font, 12, &commands, &polylines, &mask) > try ink(plain, &font, 12, &commands, &polylines, &mask));
    try testing.expectEqual(try ink(plain, &font, 80, &commands, &polylines, &mask), try ink(dark, &font, 80, &commands, &polylines, &mask));
}

test "a rotated element: drawn turned, hit where it shows, redrawn over its turned bounds" {
    var window: core.Window = undefined;
    window.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer window.deinit();
    var bar: core.items.Rectangle = .{};
    defer bar.deinit();
    var touch: core.items.TouchArea = .{};
    defer touch.deinit();
    var tilt: core.ItemTransform = .{};
    defer tilt.deinit();
    window.rootItem().appendChild(&bar.item);
    bar.item.appendChild(&touch.item);
    // 60 x 10, centered at (50, 50); turned a quarter: 10 x 60.
    bar.item.setGeometry(.{ .x = 20, .y = 45, .width = 60, .height = 10 });
    touch.item.setGeometry(.{ .width = 60, .height = 10 });
    bar.background.set(.color(.rgb(0xff0000)));
    bar.item.transform = &tilt;
    var clicks: usize = 0;
    touch.clicked.setHandler(&clicks, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);

    var pixels: [100 * 100]Rgba8 = @splat(.transparent);
    var r: Renderer(Rgba8) = .init(std.testing.allocator);
    defer r.deinit();
    _ = try r.renderWindow(&window, .init(&pixels, 100, 100), .full);
    try std.testing.expect(isRed(pixels[50 * 100 + 25])); // along the bar
    try std.testing.expect(!isRed(pixels[25 * 100 + 50]));

    tilt.rotation.set(90);
    var region = try r.renderWindow(&window, .init(&pixels, 100, 100), .partial);
    // The old bounds and the turned ones.
    try std.testing.expect(region.boundingBox().containsRect(.{ .x = 45, .y = 20, .width = 10, .height = 60 }));
    try std.testing.expect(isRed(pixels[25 * 100 + 50])); // turned: up and down
    try std.testing.expect(!isRed(pixels[50 * 100 + 25]));
    try std.testing.expect(isRed(pixels[50 * 100 + 50]));

    // Hit where it shows now, not where it was laid out.
    const click = struct {
        fn at(w: *core.Window, x: f32, y: f32) void {
            w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            w.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
        }
    }.at;
    click(&window, 25, 50);
    try std.testing.expectEqual(@as(usize, 0), clicks);
    click(&window, 50, 25);
    try std.testing.expectEqual(@as(usize, 1), clicks);

    // Scaled twice, from its top-left: twice as long.
    tilt.rotation.set(0);
    tilt.scale_x.set(2);
    tilt.origin_x.set(0);
    _ = try r.renderWindow(&window, .init(&pixels, 100, 100), .partial);
    try std.testing.expect(isRed(pixels[50 * 100 + 95]));
    click(&window, 95, 50);
    try std.testing.expectEqual(@as(usize, 2), clicks);
}

test "a label's new text: redrawn over its lines, not its whole item, as a full frame would be" {
    const gpa = testing.allocator;
    const bytes = try core.text.test_font.standard(gpa);
    defer gpa.free(bytes);
    const font: Font = try .init(bytes);
    var window: core.Window = undefined;
    window.init(gpa, .{ .width = 200, .height = 80 });
    defer window.deinit();
    try window.registerFont("Inter", 400, &font);
    var label: core.items.Text = .{};
    defer label.deinit();
    window.rootItem().appendChild(&label.item);
    label.item.setGeometry(.{ .x = 10, .y = 5, .width = 180, .height = 70 });
    label.font_size.set(14);

    var pixels: [200 * 80]Rgba8 = @splat(.transparent);
    var full: [200 * 80]Rgba8 = @splat(.transparent);
    var r: Renderer(Rgba8) = .init(gpa);
    defer r.deinit();
    const H = rendering.TextHorizontalAlignment;
    const V = rendering.TextVerticalAlignment;
    for ([_]H{ .left, .center, .right }) |h| for ([_]V{ .top, .center, .bottom }) |v| {
        label.horizontal_alignment.set(h);
        label.vertical_alignment.set(v);
        label.text.set("12");
        _ = try r.renderWindow(&window, .init(&pixels, 200, 80), .full);
        for ([_][]const u8{ "13", "1388 gjpqy", "Wy\nfj", "" }) |text| {
            label.text.set(text);
            const before = pixels;
            const region = try r.renderWindow(&window, .init(&pixels, 200, 80), .partial);
            _ = try r.renderWindow(&window, .init(&full, 200, 80), .full);
            try testing.expectEqualSlices(Rgba8, &full, &pixels);
            // Short text in a wide item: less than the item.
            try testing.expect(region.boundingBox().width < 180 or region.boundingBox().height < 70);
            for (0..80) |y| for (0..200) |x| if (!std.meta.eql(before[y * 200 + x], pixels[y * 200 + x])) {
                const at: core.Rect = .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = 1, .height = 1 };
                try testing.expect(region.intersects(at));
            };
        }
    };
}

fn isRed(p: Rgba8) bool {
    return p.r > 200 and p.g < 50 and p.b < 50;
}

fn isGreen(p: Rgba8) bool {
    return p.g > 200 and p.r < 50 and p.b < 50;
}

test "clipping, rotated: to the turned rectangle; a clip path: it and its children inside it" {
    var window: core.Window = undefined;
    window.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer window.deinit();
    var frame: core.items.Rectangle = .{};
    defer frame.deinit();
    var fill: core.items.Rectangle = .{};
    defer fill.deinit();
    var tilt: core.ItemTransform = .{};
    defer tilt.deinit();
    window.rootItem().appendChild(&frame.item);
    frame.item.appendChild(&fill.item);
    // A 60 px square at the middle, clipping a red child bigger than it,
    // turned 45 degrees: a diamond, 42 px from the middle to each corner.
    frame.item.setGeometry(.{ .x = 20, .y = 20, .width = 60, .height = 60 });
    fill.item.setGeometry(.{ .x = -20, .y = -20, .width = 100, .height = 100 });
    fill.background.set(.color(.rgb(0xff0000)));
    frame.clip.set(true);
    frame.item.transform = &tilt;
    tilt.rotation.set(45);

    var pixels: [100 * 100]Rgba8 = @splat(.transparent);
    var r: Renderer(Rgba8) = .init(std.testing.allocator);
    defer r.deinit();
    _ = try r.renderWindow(&window, .init(&pixels, 100, 100), .full);
    try std.testing.expect(isRed(pixels[50 * 100 + 50]));
    try std.testing.expect(isRed(pixels[12 * 100 + 50])); // a corner, up
    try std.testing.expect(isRed(pixels[50 * 100 + 88])); // and right
    // In its bounding box, outside the diamond: not drawn.
    try std.testing.expect(!isRed(pixels[25 * 100 + 25]));
    try std.testing.expect(!isRed(pixels[80 * 100 + 80]));
    try std.testing.expect(!isRed(pixels[12 * 100 + 70]));

    // A clip path instead, unturned: the triangle above the diagonal, the
    // square's own drawing (green) and its child (red) cut along it.
    tilt.rotation.set(0);
    frame.background.set(.color(.rgb(0x00ff00)));
    fill.item.setGeometry(.{ .x = 30, .y = 0, .width = 30, .height = 30 });
    tilt.clip_path.set("M 0 0 L 60 0 L 0 60 Z");
    var partial = pixels;
    _ = try r.renderWindow(&window, .init(&partial, 100, 100), .partial);
    _ = try r.renderWindow(&window, .init(&pixels, 100, 100), .full);
    try std.testing.expectEqualSlices(Rgba8, &pixels, &partial);
    try std.testing.expect(isGreen(pixels[25 * 100 + 25])); // (5, 5) in it
    try std.testing.expect(!isGreen(pixels[75 * 100 + 75])); // (55, 55)
    try std.testing.expect(!isRed(pixels[75 * 100 + 75]));
    try std.testing.expect(isRed(pixels[25 * 100 + 65])); // the child's (45, 5)
    try std.testing.expect(!isRed(pixels[45 * 100 + 75])); // its (55, 25)
    // Split in half by the cut (local x + y = 60): half green over the
    // white window.
    const edge = pixels[50 * 100 + 49];
    try std.testing.expect(edge.g == 255 and edge.r > 100 and edge.r < 155);

    // Changed: redrawn as a full frame would be.
    tilt.clip_path.set("M 0 0 L 60 0 L 60 60 Z");
    partial = pixels;
    _ = try r.renderWindow(&window, .init(&partial, 100, 100), .partial);
    _ = try r.renderWindow(&window, .init(&pixels, 100, 100), .full);
    try std.testing.expectEqualSlices(Rgba8, &pixels, &partial);
    try std.testing.expect(!isGreen(pixels[75 * 100 + 25])); // (5, 55): out now
    try std.testing.expect(isGreen(pixels[60 * 100 + 70])); // (50, 40)
    // Gone: everything shows again.
    tilt.clip_path.set("");
    _ = try r.renderWindow(&window, .init(&pixels, 100, 100), .partial);
    try std.testing.expect(isGreen(pixels[75 * 100 + 25]));
}

test "a road tilted in depth, scrolling under a clip: each partial frame as a full one" {
    const gpa = std.testing.allocator;
    const W = 800;
    const H = 480;
    var window: core.Window = undefined;
    window.init(gpa, .{ .width = W, .height = H });
    defer window.deinit();
    // A road seen from behind a car, as a dashboard draws it: a clip, a
    // perspective, stripes turned 82 degrees away and moving along.
    var road: core.items.Rectangle = .{};
    defer road.deinit();
    var view: core.items.Rectangle = .{};
    defer view.deinit();
    var plane: core.items.Rectangle = .{};
    defer plane.deinit();
    var stripes: [5]core.items.Rectangle = @splat(.{});
    defer for (&stripes) |*s| s.deinit();
    var view_t: core.ItemTransform = .{};
    defer view_t.deinit();
    var plane_t: core.ItemTransform = .{};
    defer plane_t.deinit();
    window.rootItem().appendChild(&road.item);
    road.item.appendChild(&view.item);
    view.item.appendChild(&plane.item);
    for (&stripes) |*s| plane.item.appendChild(&s.item);
    road.item.setGeometry(.{ .x = 153, .y = 254, .width = 498, .height = 152 });
    road.clip.set(true);
    view.item.setGeometry(.{ .x = 147, .y = -54, .width = 200, .height = 200 });
    view_t.perspective.set(1024);
    view.item.transform = &view_t;
    plane.item.setGeometry(.{ .x = 10, .y = -440, .width = 180, .height = 1200 });
    plane_t.origin_x.set(90);
    plane_t.origin_y.set(540);
    plane_t.rotation_x.set(82);
    plane.item.transform = &plane_t;
    for (&stripes) |*s| {
        s.border_radius.set(30);
        s.background.set(.color(.rgb(0x404040)));
    }
    const place = struct {
        fn f(st: []core.items.Rectangle, offset: f32) void {
            for (st, 0..) |*s, i| {
                const y = @mod(@as(f32, @floatFromInt(i)) * 240 + offset + 120, 1200) - 120;
                s.item.setGeometry(.{ .y = y, .width = 180, .height = 120 });
            }
        }
    }.f;

    const pixels = try gpa.alloc(Rgba8, W * H);
    defer gpa.free(pixels);
    const full = try gpa.alloc(Rgba8, W * H);
    defer gpa.free(full);
    @memset(pixels, .transparent);
    var r: Renderer(Rgba8) = .init(gpa);
    defer r.deinit();
    var f: Renderer(Rgba8) = .init(gpa);
    defer f.deinit();
    place(&stripes, 0);
    _ = try r.renderWindow(&window, .init(pixels, W, H), .full);
    var offset: f32 = 0;
    for (0..80) |_| {
        offset = @mod(offset + 60.0 * 77.0 / 99.0, 1200);
        place(&stripes, offset);
        _ = try r.renderWindow(&window, .init(pixels, W, H), .partial);
        _ = try f.renderWindow(&window, .init(full, W, H), .full);
        try std.testing.expectEqualSlices(Rgba8, full, pixels);
    }

    // Stopped, under something that changes: its image kept, not drawn
    // again (as it would be were it cut to the part redrawn).
    var car: core.items.Rectangle = .{};
    defer car.deinit();
    window.rootItem().appendChild(&car.item);
    car.item.setGeometry(.{ .x = 380, .y = 300, .width = 40, .height = 40 });
    car.background.set(.color(.rgb(0xff0000)));
    _ = try r.renderWindow(&window, .init(pixels, W, H), .partial);
    const kept = r.layers.images.items[0].version;
    try std.testing.expectEqual(@as(usize, 1), r.layers.images.items.len);
    car.background.set(.color(.rgb(0x00ff00)));
    _ = try r.renderWindow(&window, .init(pixels, W, H), .partial);
    try std.testing.expectEqual(kept, r.layers.images.items[0].version);
    _ = try f.renderWindow(&window, .init(full, W, H), .full);
    try std.testing.expectEqualSlices(Rgba8, full, pixels);
}

test "prefer-rendering-cache: kept as an image while it turns or is covered, drawn again when it changes" {
    const gpa = std.testing.allocator;
    const W = 200;
    const H = 200;
    var window: core.Window = undefined;
    window.init(gpa, .{ .width = W, .height = H });
    defer window.deinit();
    // A selector: two pictures in a turned frame, a label changing over it.
    var frame: core.items.Rectangle = .{};
    defer frame.deinit();
    var back: core.items.Rectangle = .{};
    defer back.deinit();
    var mark: core.items.Rectangle = .{};
    defer mark.deinit();
    var label: core.items.Rectangle = .{};
    defer label.deinit();
    var turn: core.ItemTransform = .{};
    defer turn.deinit();
    window.rootItem().appendChild(&frame.item);
    frame.item.appendChild(&back.item);
    frame.item.appendChild(&mark.item);
    window.rootItem().appendChild(&label.item);
    frame.item.setGeometry(.{ .x = 40, .y = 40, .width = 120, .height = 120 });
    back.item.setGeometry(.{ .width = 120, .height = 120 });
    back.background.set(.color(.rgb(0x2040a0)));
    back.border_radius.set(20);
    mark.item.setGeometry(.{ .x = 50, .y = 10, .width = 20, .height = 40 });
    mark.background.set(.color(.rgb(0xffcc00)));
    label.item.setGeometry(.{ .x = 80, .y = 90, .width = 40, .height = 20 });
    label.background.set(.color(.rgb(0xff0000)));
    frame.item.transform = &turn;
    turn.prefer_rendering_cache.set(true);
    turn.rotation.set(21);

    const pixels = try gpa.alloc(Rgba8, W * H);
    defer gpa.free(pixels);
    const full = try gpa.alloc(Rgba8, W * H);
    defer gpa.free(full);
    var r: Renderer(Rgba8) = .init(gpa);
    defer r.deinit();
    var f: Renderer(Rgba8) = .init(gpa);
    defer f.deinit();
    _ = try r.renderWindow(&window, .init(pixels, W, H), .full);
    try std.testing.expectEqual(@as(usize, 1), r.layers.images.items.len);
    const kept = r.layers.images.items[0].version;
    const step = struct {
        fn same(rr: *Renderer(Rgba8), ff: *Renderer(Rgba8), w: *core.Window, px: []Rgba8, fu: []Rgba8) !void {
            _ = try rr.renderWindow(w, .init(px, W, H), .partial);
            _ = try ff.renderWindow(w, .init(fu, W, H), .full);
            try std.testing.expectEqualSlices(Rgba8, fu, px);
        }
    }.same;
    // Something over it changes: its image kept.
    label.background.set(.color(.rgb(0x00ff00)));
    try step(&r, &f, &window, pixels, full);
    try std.testing.expectEqual(kept, r.layers.images.items[0].version);
    // Turning, through 0 (not turned): the same image, turned.
    for (0..6) |k| {
        turn.rotation.set(21 - 7 * @as(f32, @floatFromInt(k)));
        try step(&r, &f, &window, pixels, full);
        try std.testing.expectEqual(kept, r.layers.images.items[0].version);
    }
    // What it draws changes: drawn again.
    mark.background.set(.color(.rgb(0xffffff)));
    try step(&r, &f, &window, pixels, full);
    try std.testing.expect(r.layers.images.items[0].version != kept);

    // Not turned: shown pixel for pixel, as drawn without it.
    turn.rotation.set(0);
    _ = try r.renderWindow(&window, .init(pixels, W, H), .full);
    turn.prefer_rendering_cache.set(false);
    _ = try f.renderWindow(&window, .init(full, W, H), .full);
    try std.testing.expectEqualSlices(Rgba8, full, pixels);
}

test "an element tilted in depth: drawn in perspective, hit where it shows, redrawn over its bounds" {
    var window: core.Window = undefined;
    window.init(std.testing.allocator, .{ .width = 200, .height = 100 });
    defer window.deinit();
    var card: core.items.Rectangle = .{};
    defer card.deinit();
    var touch: core.items.TouchArea = .{};
    defer touch.deinit();
    var tilt: core.ItemTransform = .{};
    defer tilt.deinit();
    window.rootItem().appendChild(&card.item);
    card.item.appendChild(&touch.item);
    // 100 x 60, centered in the window.
    card.item.setGeometry(.{ .x = 50, .y = 20, .width = 100, .height = 60 });
    touch.item.setGeometry(.{ .width = 100, .height = 60 });
    card.background.set(.color(.rgb(0xff0000)));
    card.item.transform = &tilt;
    var clicks: usize = 0;
    touch.clicked.setHandler(&clicks, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);

    var pixels: [200 * 100]Rgba8 = @splat(.transparent);
    var r: Renderer(Rgba8) = .init(std.testing.allocator);
    defer r.deinit();
    _ = try r.renderWindow(&window, .init(&pixels, 200, 100), .full);
    try std.testing.expect(isRed(pixels[50 * 200 + 55]));

    // Turned 60 degrees about its vertical axis, the right side away: half
    // as wide, its far side shorter than its near one.
    tilt.rotation_y.set(60);
    const region = try r.renderWindow(&window, .init(&pixels, 200, 100), .partial);
    try std.testing.expect(region.boundingBox().containsRect(.{ .x = 50, .y = 20, .width = 100, .height = 60 }));
    try std.testing.expect(!isRed(pixels[50 * 200 + 55]));
    try std.testing.expect(!isRed(pixels[50 * 200 + 145]));
    try std.testing.expect(isRed(pixels[50 * 200 + 100]));
    const height = struct {
        fn at(px: []const Rgba8, x: usize) usize {
            var n: usize = 0;
            for (0..100) |y| {
                if (isRed(px[y * 200 + x])) n += 1;
            }
            return n;
        }
    }.at;
    try std.testing.expect(height(&pixels, 80) >= height(&pixels, 120) + 3);
    try std.testing.expect(height(&pixels, 80) > 60);
    try std.testing.expect(height(&pixels, 120) < 60);
    // Its edges smoothed: some pixels part red, part the white behind.
    var partial: usize = 0;
    for (10..30) |y| for (76..124) |x| {
        const g = pixels[y * 200 + x].g;
        if (g > 30 and g < 220) partial += 1;
    };
    try std.testing.expect(partial > 10);

    // Hit where it shows, not where it was laid out.
    const click = struct {
        fn at(w: *core.Window, x: f32, y: f32) void {
            w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            w.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
        }
    }.at;
    click(&window, 55, 50);
    try std.testing.expectEqual(@as(usize, 0), clicks);
    click(&window, 100, 50);
    try std.testing.expectEqual(@as(usize, 1), clicks);

    // A parent's perspective: closer, the near side grows more.
    var near: core.ItemTransform = .{};
    defer near.deinit();
    near.perspective.set(200);
    window.rootItem().transform = &near;
    defer window.rootItem().transform = null;
    const far_height = height(&pixels, 80);
    pixels = @splat(.transparent);
    _ = try r.renderWindow(&window, .init(&pixels, 200, 100), .full);
    try std.testing.expect(height(&pixels, 80) > far_height);

    // Edge on: a line at most, nothing beside it shown or hit.
    tilt.rotation_y.set(90);
    pixels = @splat(.transparent);
    _ = try r.renderWindow(&window, .init(&pixels, 200, 100), .full);
    try std.testing.expect(!isRed(pixels[50 * 200 + 96]));
    try std.testing.expect(!isRed(pixels[50 * 200 + 104]));
    click(&window, 96, 50);
    try std.testing.expectEqual(@as(usize, 1), clicks);
}

test "a rectangle's shadow: under it, blurred, redrawn where it was and is" {
    var window: core.Window = undefined;
    window.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer window.deinit();
    var card: core.items.Rectangle = .{};
    defer card.deinit();
    var shadow: core.items.DropShadow = .{};
    defer shadow.deinit();
    window.rootItem().appendChild(&card.item);
    card.item.setGeometry(.{ .x = 30, .y = 30, .width = 40, .height = 20 });
    card.background.set(.color(.rgb(0xff0000)));
    card.border_radius.set(4);
    card.shadow = &shadow;
    shadow.offset_y.set(10);
    shadow.blur.set(8);
    shadow.color.set(.rgb(0x000000));

    var pixels: [100 * 100]Rgba8 = @splat(.transparent);
    var r: Renderer(Rgba8) = .init(std.testing.allocator);
    defer r.deinit();
    _ = try r.renderWindow(&window, .init(&pixels, 100, 100), .full);
    const at = struct {
        fn f(p: []const Rgba8, x: usize, y: usize) Rgba8 {
            return p[y * 100 + x];
        }
    }.f;
    try std.testing.expect(isRed(at(&pixels, 50, 40))); // the rectangle over it
    // Below the rectangle: dark, fading out past the shadow's edge (y 60).
    const under = at(&pixels, 50, 55);
    const edge = at(&pixels, 50, 60);
    const past = at(&pixels, 50, 64);
    try std.testing.expect(under.g < 60);
    try std.testing.expect(edge.g > under.g and past.g > edge.g);
    try std.testing.expect(edge.g > 100 and edge.g < 160);
    try std.testing.expectEqual(@as(u8, 255), at(&pixels, 50, 75).g); // beyond its reach

    // Moved: redrawn where it was and where it is.
    shadow.offset_y.set(-10);
    const region = try r.renderWindow(&window, .init(&pixels, 100, 100), .partial);
    const box = region.boundingBox();
    try std.testing.expect(box.y <= 30 - 10 - 12 and box.bottom() >= 50 + 10 + 12);
    try std.testing.expectEqual(@as(u8, 255), at(&pixels, 50, 64).g);
    try std.testing.expect(at(&pixels, 50, 24).g < 160);
}
