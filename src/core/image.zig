// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Images: premultiplied RGBA pixel buffers, plus how items display them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const graphics = @import("graphics.zig");
const Rgba8 = graphics.Rgba8;

/// A borrowed view of premultiplied RGBA pixels, row-major and tightly
/// packed. Two images are equal when they view the same pixels in the same
/// version: pixels that change (a video's frames) get a new `version` each
/// time, so renderers upload them again.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const Rgba8,
    version: u32 = 0,
    /// Drawn nine-sliced (`@image-url("x.png", nine-slice(...))`), unless
    /// the item says otherwise.
    nine_slice: ?NineSlice = null,
    /// The animated image (GIF, APNG file) this is the first frame of:
    /// `AnimatedImage` plays it.
    animation: []const u8 = &.{},
    /// An SVG file's shapes (no pixels): an `Image` draws them at its size.
    vector: ?*const @import("svg.zig").Drawing = null,
    /// Every pixel is opaque (set where images are decoded; false: not
    /// known). A renderer copies such an image's rows instead of blending
    /// them, and draws nothing it covers.
    is_opaque: bool = false,

    pub fn pixel(img: Image, x: u32, y: u32) Rgba8 {
        return img.pixels[@as(usize, y) * img.width + x];
    }

    pub fn eql(a: Image, b: Image) bool {
        return a.width == b.width and a.height == b.height and a.pixels.ptr == b.pixels.ptr and a.version == b.version and a.vector == b.vector;
    }

    /// Another version of the same pixels: a renderer that uploaded `old`
    /// can let its copy go once it has `new`.
    pub fn supersedes(new: Image, old: Image) bool {
        return new.pixels.ptr == old.pixels.ptr and new.version != old.version;
    }
};

/// Whether every pixel's alpha is 255 (`Image.is_opaque`).
pub fn allOpaque(pixels: []const Rgba8) bool {
    if (pixels.len == 0) return false;
    for (pixels) |p| if (p.a != 255) return false;
    return true;
}

/// An image that owns its pixels.
pub const OwnedImage = struct {
    width: u32,
    height: u32,
    pixels: []Rgba8,

    pub fn init(gpa: Allocator, width: u32, height: u32) Allocator.Error!OwnedImage {
        const pixels = try gpa.alloc(Rgba8, @as(usize, width) * height);
        @memset(pixels, .transparent);
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    pub fn deinit(self: *OwnedImage, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }

    pub fn image(self: *const OwnedImage) Image {
        return .{ .width = self.width, .height = self.height, .pixels = self.pixels };
    }
};

/// Where an image loaded at run time is (`Image.source-url`).
pub const ImageStatus = enum {
    /// No URL.
    none,
    loading,
    ready,
    /// Not found, not an image, or the network failed.
    failed,
};

/// How an image is scaled into its item.
pub const ImageFit = enum {
    /// Stretched to the item's size.
    fill,
    /// Scaled to fit inside the item, keeping the aspect ratio.
    contain,
    /// Scaled to cover the item, keeping the aspect ratio; the excess is cut.
    cover,
    /// Drawn at its natural size, centered; the excess is cut.
    preserve,
    /// Repeated at its natural size from the item's top left corner; the
    /// excess is cut.
    tile,
    /// Repeated side by side at its natural width, stretched to the item's
    /// height.
    tile_horizontally,
    /// Repeated one below the other at its natural height, stretched to
    /// the item's width.
    tile_vertically,

    /// The size of one tile for the tiling fits (null for the others): the
    /// image's `natural` size along the axes it repeats on, the item's
    /// `area` along the others.
    pub fn tileSize(fit: ImageFit, natural: [2]f32, area: [2]f32) ?[2]f32 {
        return switch (fit) {
            .tile => natural,
            .tile_horizontally => .{ natural[0], area[1] },
            .tile_vertically => .{ area[0], natural[1] },
            else => null,
        };
    }
};

pub const ImageRendering = enum {
    /// Bilinear filtering.
    smooth,
    /// Nearest neighbor, for pixel art.
    pixelated,
};

/// Insets, in source pixels, of the borders that a nine-slice image keeps
/// unscaled; only the middle stretches.
pub const NineSlice = struct {
    top: u32,
    right: u32,
    bottom: u32,
    left: u32,

    pub fn uniform(n: u32) NineSlice {
        return .{ .top = n, .right = n, .bottom = n, .left = n };
    }
};
