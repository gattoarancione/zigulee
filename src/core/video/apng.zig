// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Animated PNG (APNG): video that zigulee decodes itself, on every platform
//! (for UI animations, short clips, tests). A plain PNG plays as a single
//! frame. No sound.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const png = @import("../png.zig");
const graphics = @import("../graphics.zig");
const Rgba8 = graphics.Rgba8;
const Color = graphics.Color;
const video = @import("video.zig");

/// Files can be read where there is a file system.
const has_files = builtin.os.tag != .freestanding;

pub const decoder: video.Decoder = .{ .name = "apng", .open = open };

fn open(_: ?*anyopaque, gpa: Allocator, source: video.Source) video.Error!?video.Stream {
    var owned: ?[]u8 = null;
    const bytes = if (source.bytes.len > 0) source.bytes else blk: {
        if (!has_files or !isPngName(source.path)) return null;
        owned = readFile(gpa, source.path) orelse return error.ReadFailed;
        break :blk owned.?;
    };
    errdefer if (owned) |o| gpa.free(o);
    if (!std.mem.startsWith(u8, bytes, png.signature)) {
        if (owned != null) return error.InvalidVideo;
        return null;
    }
    const a = try gpa.create(Apng);
    errdefer gpa.destroy(a);
    a.* = .{ .gpa = gpa, .owned = owned };
    a.parse(bytes) catch |err| {
        a.free();
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidVideo,
        };
    };
    return .{ .ctx = a, .vtable = &.{ .info = info, .frame = frame, .audio = noAudio, .seek = seek, .close = close } };
}

fn isPngName(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".png") or std.ascii.endsWithIgnoreCase(path, ".apng");
}

fn readFile(gpa: Allocator, path: []const u8) ?[]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .unlimited) catch null;
}

const Frame = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    delay_ms: u32,
    /// After showing it: 0 leave, 1 clear its area, 2 restore its area.
    dispose: u8,
    /// 0 replace its area, 1 draw over it.
    blend: u8,
    /// Its compressed data: `parts[first..][0..count]`.
    first: u32 = 0,
    count: u32 = 0,
};

/// An animated PNG's frames, and the picture as far as it is drawn
/// (`AnimatedImage` shows it frame by frame too).
pub const Apng = struct {
    gpa: Allocator,
    owned: ?[]u8,
    header: png.Header = undefined,
    palette: [256]Color = @splat(Color.black),
    key: ?[3]u16 = null,
    frames: std.ArrayList(Frame) = .empty,
    parts: std.ArrayList([]const u8) = .empty,
    duration: u64 = 0,
    /// How many times it plays (0: forever).
    plays: u32 = 1,
    /// The picture so far, and what a "restore" frame covers.
    canvas: []Rgba8 = &.{},
    saved: []Rgba8 = &.{},
    region: []Rgba8 = &.{},
    joined: std.ArrayList(u8) = .empty,
    next: usize = 0,
    time: u64 = 0,
    /// What to do with the last frame's area before the next one.
    pending: ?Frame = null,

    fn parse(a: *Apng, bytes: []const u8) (png.DecodeError || error{NotAnimation})!void {
        var pos: usize = png.signature.len;
        var animated = false;
        var have_header = false;
        var idat_seen = false;
        var idat_is_frame = false;
        while (true) {
            if (pos + 12 > bytes.len) return error.InvalidPng;
            const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
            if (pos + 12 + len > bytes.len) return error.InvalidPng;
            const kind = bytes[pos + 4 ..][0..4];
            const data = bytes[pos + 8 ..][0..len];
            pos += 12 + len;
            if (std.mem.eql(u8, kind, "IHDR")) {
                a.header = try png.parseHeader(data);
                have_header = true;
            } else if (std.mem.eql(u8, kind, "PLTE")) {
                try png.readPalette(data, &a.palette);
            } else if (std.mem.eql(u8, kind, "tRNS")) {
                if (!have_header) return error.InvalidPng;
                png.readTransparency(a.header, data, &a.palette, &a.key);
            } else if (std.mem.eql(u8, kind, "acTL")) {
                animated = true;
                if (len >= 8) a.plays = std.mem.readInt(u32, data[4..8], .big);
            } else if (std.mem.eql(u8, kind, "fcTL")) {
                if (len < 26 or !have_header) return error.InvalidPng;
                const num = std.mem.readInt(u16, data[20..22], .big);
                var den = std.mem.readInt(u16, data[22..24], .big);
                if (den == 0) den = 100;
                var shown_ms: u32 = @intCast(@as(u64, num) * 1000 / den);
                if (shown_ms == 0) shown_ms = 100; // as browsers do
                const f: Frame = .{
                    .width = std.mem.readInt(u32, data[4..8], .big),
                    .height = std.mem.readInt(u32, data[8..12], .big),
                    .x = std.mem.readInt(u32, data[12..16], .big),
                    .y = std.mem.readInt(u32, data[16..20], .big),
                    .delay_ms = shown_ms,
                    .dispose = @min(data[24], 2),
                    .blend = @min(data[25], 1),
                    .first = @intCast(a.parts.items.len),
                };
                if (f.width == 0 or f.height == 0 or @as(u64, f.x) + f.width > a.header.width or @as(u64, f.y) + f.height > a.header.height) return error.InvalidPng;
                try a.frames.append(a.gpa, f);
            } else if (std.mem.eql(u8, kind, "IDAT")) {
                if (!have_header) return error.InvalidPng;
                if (!idat_seen) {
                    idat_seen = true;
                    if (!animated) {
                        // A plain PNG: one frame, the whole picture.
                        try a.frames.append(a.gpa, .{ .x = 0, .y = 0, .width = a.header.width, .height = a.header.height, .delay_ms = 0, .dispose = 0, .blend = 0 });
                    }
                    // Without an fcTL before it, the default image is not
                    // part of the animation.
                    idat_is_frame = a.frames.items.len == 1;
                }
                if (idat_is_frame) {
                    try a.parts.append(a.gpa, data);
                    a.frames.items[0].count += 1;
                }
            } else if (std.mem.eql(u8, kind, "fdAT")) {
                if (len < 4 or a.frames.items.len == 0) return error.InvalidPng;
                const f = &a.frames.items[a.frames.items.len - 1];
                if (f.first + f.count != a.parts.items.len) return error.InvalidPng;
                try a.parts.append(a.gpa, data[4..]);
                f.count += 1;
            } else if (std.mem.eql(u8, kind, "IEND")) {
                break;
            } else if (kind[0] & 0x20 == 0) {
                return error.UnsupportedPng;
            }
        }
        if (!have_header or a.frames.items.len == 0) return error.InvalidPng;
        for (a.frames.items) |f| {
            if (f.count == 0) return error.InvalidPng;
            a.duration += f.delay_ms;
        }
        const n = @as(usize, a.header.width) * a.header.height;
        a.canvas = try a.gpa.alloc(Rgba8, n);
        @memset(a.canvas, Rgba8.transparent);
        a.saved = try a.gpa.alloc(Rgba8, n);
        a.region = try a.gpa.alloc(Rgba8, n);
    }

    /// Opens `bytes` (borrowed), a PNG, animated or not.
    pub fn open(gpa: Allocator, bytes: []const u8) (png.DecodeError || error{NotAnimation})!*Apng {
        if (!std.mem.startsWith(u8, bytes, png.signature)) return error.InvalidPng;
        const a = try gpa.create(Apng);
        a.* = .{ .gpa = gpa, .owned = null };
        a.parse(bytes) catch |err| {
            a.free();
            return err;
        };
        return a;
    }

    pub fn close(a: *Apng) void {
        a.free();
    }

    pub fn delay(a: *const Apng, i: usize) u32 {
        return a.frames.items[i].delay_ms;
    }

    fn free(a: *Apng) void {
        const gpa = a.gpa;
        a.frames.deinit(gpa);
        a.parts.deinit(gpa);
        a.joined.deinit(gpa);
        gpa.free(a.canvas);
        gpa.free(a.saved);
        gpa.free(a.region);
        if (a.owned) |o| gpa.free(o);
        gpa.destroy(a);
    }

    /// Draws the next frame onto the canvas; returns when it shows.
    pub fn advance(a: *Apng) video.Error!?u64 {
        if (a.next >= a.frames.items.len) return null;
        const w = a.header.width;
        if (a.pending) |p| switch (p.dispose) {
            1 => for (0..p.height) |row| @memset(a.canvas[(p.y + row) * w + p.x ..][0..p.width], Rgba8.transparent),
            2 => for (0..p.height) |row| @memcpy(a.canvas[(p.y + row) * w + p.x ..][0..p.width], a.saved[row * p.width ..][0..p.width]),
            else => {},
        };
        var f = a.frames.items[a.next];
        if (a.next == 0 and f.dispose == 2) f.dispose = 1;

        a.joined.clearRetainingCapacity();
        for (a.parts.items[f.first..][0..f.count]) |part| try a.joined.appendSlice(a.gpa, part);
        var h = a.header;
        h.width = f.width;
        h.height = f.height;
        const region = a.region[0 .. @as(usize, f.width) * f.height];
        png.decodePixels(a.gpa, h, a.joined.items, &a.palette, a.key, region) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidVideo,
        };

        for (0..f.height) |row| {
            const dst = a.canvas[(f.y + row) * w + f.x ..][0..f.width];
            const src = region[row * f.width ..][0..f.width];
            if (f.dispose == 2) @memcpy(a.saved[row * f.width ..][0..f.width], dst);
            if (f.blend == 0) {
                @memcpy(dst, src);
            } else for (dst, src) |*d, s| {
                const k: u16 = 255 - s.a;
                d.* = .{
                    .r = s.r + @as(u8, @intCast(@as(u16, d.r) * k / 255)),
                    .g = s.g + @as(u8, @intCast(@as(u16, d.g) * k / 255)),
                    .b = s.b + @as(u8, @intCast(@as(u16, d.b) * k / 255)),
                    .a = s.a + @as(u8, @intCast(@as(u16, d.a) * k / 255)),
                };
            }
        }
        a.pending = f;
        const t = a.time;
        a.time += f.delay_ms;
        a.next += 1;
        return t;
    }

    /// Whether frame `i` covers the whole picture, replacing it (what came
    /// before does not show).
    pub fn isKey(a: *const Apng, i: usize) bool {
        const f = a.frames.items[i];
        return f.blend == 0 and f.x == 0 and f.y == 0 and f.width == a.header.width and f.height == a.header.height;
    }

    pub fn restart(a: *Apng) void {
        @memset(a.canvas, Rgba8.transparent);
        a.next = 0;
        a.time = 0;
        a.pending = null;
    }
};

fn info(ctx: *anyopaque) video.Info {
    const a: *Apng = @ptrCast(@alignCast(ctx));
    return .{ .width = a.header.width, .height = a.header.height, .duration_ms = a.duration };
}

fn frame(ctx: *anyopaque, pixels: []Rgba8) video.Error!?u64 {
    const a: *Apng = @ptrCast(@alignCast(ctx));
    const t = try a.advance() orelse return null;
    @memcpy(pixels, a.canvas);
    return t;
}

fn noAudio(_: *anyopaque, _: []f32) video.Error!usize {
    return 0;
}

fn seek(ctx: *anyopaque, ms: u64) video.Error!void {
    const a: *Apng = @ptrCast(@alignCast(ctx));
    a.restart();
    // The frame showing at `ms`.
    const frames = a.frames.items;
    var target: usize = 0;
    var at: u64 = 0;
    while (target + 1 < frames.len and at + frames[target].delay_ms <= ms) : (target += 1) at += frames[target].delay_ms;
    // Start from the last frame before it that replaces the whole picture
    // (nothing before it shows through): a key frame.
    var start = target;
    while (start > 0 and !a.isKey(start)) start -= 1;
    for (frames[0..start]) |f| a.time += f.delay_ms;
    a.next = start;
    // Draw the frames from there to the one showing at `ms`.
    while (a.next < target) _ = try a.advance();
}

fn close(ctx: *anyopaque) void {
    const a: *Apng = @ptrCast(@alignCast(ctx));
    a.free();
}

/// An animated PNG of `frames` (premultiplied, `width` x `height` each),
/// each shown for `delay_ms`, looping forever. The caller owns the bytes.
pub fn encode(gpa: Allocator, width: u32, height: u32, frames: []const []const Rgba8, delay_ms: u16) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, png.signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, @intFromEnum(png.ColorType.rgba), 0, 0, 0 };
    try png.writeChunk(gpa, &out, "IHDR", &ihdr);
    var actl: [8]u8 = undefined;
    std.mem.writeInt(u32, actl[0..4], @intCast(frames.len), .big);
    std.mem.writeInt(u32, actl[4..8], 0, .big);
    try png.writeChunk(gpa, &out, "acTL", &actl);
    var seq: u32 = 0;
    for (frames, 0..) |pixels, i| {
        var fctl: [26]u8 = @splat(0);
        std.mem.writeInt(u32, fctl[0..4], seq, .big);
        seq += 1;
        std.mem.writeInt(u32, fctl[4..8], width, .big);
        std.mem.writeInt(u32, fctl[8..12], height, .big);
        std.mem.writeInt(u16, fctl[20..22], delay_ms, .big);
        std.mem.writeInt(u16, fctl[22..24], 1000, .big);
        try png.writeChunk(gpa, &out, "fcTL", &fctl);
        const data = try png.compressPixels(gpa, width, height, pixels);
        defer gpa.free(data);
        if (i == 0) {
            try png.writeChunk(gpa, &out, "IDAT", data);
        } else {
            const fdat = try gpa.alloc(u8, 4 + data.len);
            defer gpa.free(fdat);
            std.mem.writeInt(u32, fdat[0..4], seq, .big);
            seq += 1;
            @memcpy(fdat[4..], data);
            try png.writeChunk(gpa, &out, "fdAT", fdat);
        }
    }
    try png.writeChunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

// ---- Tests ----

const testing = std.testing;

/// Three 2x1 frames: red, green, blue (left pixel), at 100 ms each.
pub fn testVideo(gpa: Allocator) ![]u8 {
    const red: Rgba8 = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const green: Rgba8 = .{ .r = 0, .g = 255, .b = 0, .a = 255 };
    const blue: Rgba8 = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    return encode(gpa, 2, 1, &.{ &.{ red, red }, &.{ green, red }, &.{ blue, red } }, 100);
}

test "an animated PNG plays frame by frame, and seeks" {
    const bytes = try testVideo(testing.allocator);
    defer testing.allocator.free(bytes);
    const s = (try open(null, testing.allocator, .{ .bytes = bytes })).?;
    defer s.close();
    try testing.expectEqual(video.Info{ .width = 2, .height = 1, .duration_ms = 300 }, s.info());
    var pixels: [2]Rgba8 = undefined;
    try testing.expectEqual(@as(?u64, 0), try s.frame(&pixels));
    try testing.expectEqual(@as(u8, 255), pixels[0].r);
    try testing.expectEqual(@as(?u64, 100), try s.frame(&pixels));
    try testing.expectEqual(@as(u8, 255), pixels[0].g);
    try testing.expectEqual(@as(?u64, 200), try s.frame(&pixels));
    try testing.expectEqual(@as(u8, 255), pixels[0].b);
    try testing.expectEqual(@as(?u64, null), try s.frame(&pixels));
    try s.seek(150);
    try testing.expectEqual(@as(?u64, 100), try s.frame(&pixels));
    try testing.expectEqual(@as(u8, 255), pixels[0].g);
}

test "a plain PNG is one frame; other files are not this decoder's" {
    const red: Rgba8 = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const bytes = try png.encode(testing.allocator, 1, 1, &.{red});
    defer testing.allocator.free(bytes);
    const s = (try open(null, testing.allocator, .{ .bytes = bytes })).?;
    defer s.close();
    var pixels: [1]Rgba8 = undefined;
    try testing.expectEqual(@as(?u64, 0), try s.frame(&pixels));
    try testing.expectEqual(red, pixels[0]);
    try testing.expectEqual(@as(?u64, null), try s.frame(&pixels));
    try testing.expectEqual(@as(?video.Stream, null), try open(null, testing.allocator, .{ .bytes = "\x00\x00\x00\x18ftypmp42" }));
    try testing.expectEqual(@as(?video.Stream, null), try open(null, testing.allocator, .{ .path = "movie.mp4" }));
}
