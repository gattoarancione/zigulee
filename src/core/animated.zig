// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Animated images (GIF, APNG): decoded frame by frame on the UI thread,
//! as they show (no thread, little memory: the picture, and what a frame
//! restores), and the `AnimatedImage` element that plays them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const ChangeTracker = @import("properties.zig").ChangeTracker;
const Callback = @import("callbacks.zig").Callback;
const Timer = @import("timers.zig").Timer;
const ImageItem = @import("items.zig").Image;
const image = @import("image.zig");
const Image = image.Image;
const Rgba8 = @import("graphics.zig").Rgba8;
const png = @import("png.zig");
const gif = @import("gif.zig");
const Apng = @import("video/apng.zig").Apng;

const log = std.log.scoped(.zigulee_animated);

/// Whether `bytes` is an image with more than one frame.
pub fn isAnimated(gpa: Allocator, bytes: []const u8) bool {
    if (gif.isGif(bytes)) {
        var a = Animation.open(gpa, bytes) catch return false;
        defer a.close();
        return a.frameCount() > 1;
    }
    if (!std.mem.startsWith(u8, bytes, png.signature)) return false;
    var pos: usize = png.signature.len;
    while (pos + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4];
        if (std.mem.eql(u8, kind, "acTL")) return true;
        if (std.mem.eql(u8, kind, "IDAT")) return false;
        pos += 12 + @as(usize, len);
    }
    return false;
}

/// The first frame of a GIF (for `@image-url`), owned.
pub fn decodeGif(gpa: Allocator, bytes: []const u8) !image.OwnedImage {
    const g = try gif.Gif.open(gpa, bytes);
    defer g.close();
    try g.advance();
    const out: image.OwnedImage = try .init(gpa, g.width, g.height);
    @memcpy(out.pixels, g.canvas);
    return out;
}

/// An animated image being shown, frame by frame.
pub const Animation = struct {
    impl: union(enum) { apng: *Apng, gif: *gif.Gif },
    /// The frame on the picture (null: none yet).
    shown: ?usize = null,

    pub const Error = error{ InvalidImage, OutOfMemory };

    /// `bytes` (borrowed) is a GIF or a PNG.
    pub fn open(gpa: Allocator, bytes: []const u8) Error!Animation {
        if (gif.isGif(bytes)) return .{ .impl = .{ .gif = gif.Gif.open(gpa, bytes) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidImage,
        } } };
        return .{ .impl = .{ .apng = Apng.open(gpa, bytes) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidImage,
        } } };
    }

    pub fn close(a: *Animation) void {
        switch (a.impl) {
            inline else => |d| d.close(),
        }
    }

    pub fn width(a: *const Animation) u32 {
        return switch (a.impl) {
            .apng => |d| d.header.width,
            .gif => |d| d.width,
        };
    }

    pub fn height(a: *const Animation) u32 {
        return switch (a.impl) {
            .apng => |d| d.header.height,
            .gif => |d| d.height,
        };
    }

    pub fn frameCount(a: *const Animation) usize {
        return switch (a.impl) {
            inline else => |d| d.frames.items.len,
        };
    }

    pub fn delay(a: *const Animation, i: usize) u32 {
        return switch (a.impl) {
            inline else => |d| d.delay(i),
        };
    }

    /// How many times it plays (0: forever).
    pub fn plays(a: *const Animation) u32 {
        return switch (a.impl) {
            inline else => |d| d.plays,
        };
    }

    /// The picture: the frame shown (with those before it under it).
    pub fn pixels(a: *const Animation) []const Rgba8 {
        return switch (a.impl) {
            inline else => |d| d.canvas,
        };
    }

    /// Draws the picture as frame `i` shows: on from the frame shown, or
    /// from the last frame before `i` that hides what came before.
    pub fn show(a: *Animation, i: usize) Error!void {
        const target = @min(i, a.frameCount() - 1);
        switch (a.impl) {
            inline else => |d| {
                if (a.shown == null or target < a.shown.?) {
                    d.restart();
                    var start = target;
                    while (start > 0 and !d.isKey(start)) start -= 1;
                    d.next = start;
                }
                while (d.next <= target) {
                    _ = d.advance() catch |err| return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => error.InvalidImage,
                    };
                }
            },
        }
        a.shown = target;
    }
};

/// Plays an animated image (`source`, from `@image-url` of a GIF or an
/// animated PNG) and shows it like an `Image`. It plays when shown, for as
/// many times as the file says (forever, usually), at `speed`; `playing`
/// false holds the frame shown. `current_frame` follows it, and setting it
/// shows that frame. A still image shows as it is. Changes apply when
/// change handlers run. Initialize in place with `init`.
pub const AnimatedImageElement = struct {
    image: ImageItem = .{},
    source: Property(?Image) = .init(null),
    playing: Property(bool) = .init(true),
    speed: Property(f32) = .init(1),
    current_frame: Property(i32) = .init(0),
    frame_count: Property(i32) = .init(0),
    /// It played as many times as the file says (not when stopped). The
    /// last frame stays.
    finished: Callback(fn () void) = .{},

    gpa: Allocator = undefined,
    animation: ?Animation = null,
    timer: Timer = .{},
    tracker: ChangeTracker(Settings) = undefined,
    applied: Settings = undefined,
    /// Plays finished since it started.
    played: u32 = 0,
    version: u32 = 0,

    const Settings = struct {
        /// The file played (or the still image's pixels).
        file: [*]const u8,
        file_len: usize,
        playing: bool,
        speed: f32,
        frame: i32,
    };

    pub fn init(self: *AnimatedImageElement, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.tracker.init(gpa, self, settings, apply);
        self.applied = .{ .file = "".ptr, .file_len = 0, .playing = true, .speed = 1, .frame = 0 };
        apply(self, self.tracker.value);
    }

    pub fn deinit(self: *AnimatedImageElement) void {
        self.unload();
        self.tracker.deinit();
        self.timer.deinit();
        self.image.deinit();
        self.source.deinit();
        self.playing.deinit();
        self.speed.deinit();
        self.current_frame.deinit();
        self.frame_count.deinit();
    }

    fn settings(self: *AnimatedImageElement) Settings {
        const src = self.source.get();
        const key: []const u8 = if (src) |s| (if (s.animation.len > 0) s.animation else std.mem.sliceAsBytes(s.pixels)) else "";
        return .{ .file = key.ptr, .file_len = key.len, .playing = self.playing.get(), .speed = self.speed.get(), .frame = self.current_frame.get() };
    }

    fn apply(self: *AnimatedImageElement, s: Settings) void {
        const was = self.applied;
        self.applied = s;
        if (s.file != was.file or s.file_len != was.file_len) {
            self.load();
            // From the start, unless a frame was set with it.
            self.showFrame(if (s.frame != was.frame) s.frame else 0);
            self.played = 0;
            return self.schedule();
        }
        if (s.frame != was.frame) self.showFrame(s.frame);
        if (s.playing != was.playing and s.playing and self.atEnd()) {
            // Played to the end: again from the start.
            self.played = 0;
            self.showFrame(0);
        }
        self.schedule();
    }

    fn load(self: *AnimatedImageElement) void {
        self.unload();
        const src = self.source.getUntracked() orelse {
            self.image.source.set(null);
            self.frame_count.set(0);
            return;
        };
        if (src.animation.len == 0) {
            self.image.source.set(src);
            self.frame_count.set(1);
            return;
        }
        self.animation = Animation.open(self.gpa, src.animation) catch |err| {
            log.info("cannot play the animated image: {t}", .{err});
            self.image.source.set(src);
            self.frame_count.set(1);
            return;
        };
        self.frame_count.set(@intCast(self.animation.?.frameCount()));
    }

    fn unload(self: *AnimatedImageElement) void {
        self.timer.stop();
        if (self.animation) |*a| a.close();
        self.animation = null;
    }

    /// Shows frame `i` (and says so in `current_frame`).
    fn showFrame(self: *AnimatedImageElement, i: i32) void {
        const a = &(self.animation orelse return self.setFrame(0));
        const n: i32 = @intCast(a.frameCount());
        const frame: usize = @intCast(std.math.clamp(i, 0, n - 1));
        a.show(frame) catch |err| {
            log.info("cannot decode the animated image: {t}", .{err});
            return self.unload();
        };
        self.version +%= 1;
        const src = self.source.getUntracked().?;
        self.image.source.set(.{ .width = a.width(), .height = a.height(), .pixels = a.pixels(), .version = self.version, .nine_slice = src.nine_slice });
        self.setFrame(@intCast(frame));
    }

    fn setFrame(self: *AnimatedImageElement, i: i32) void {
        self.applied.frame = i;
        self.current_frame.set(i);
    }

    /// Whether the last play has ended, on its last frame.
    fn atEnd(self: *const AnimatedImageElement) bool {
        const a = self.animation orelse return false;
        return a.plays() != 0 and self.played >= a.plays();
    }

    /// The timer for the frame shown, if playing.
    fn schedule(self: *AnimatedImageElement) void {
        self.timer.stop();
        const a = self.animation orelse return;
        const s = self.applied;
        if (!s.playing or s.speed <= 0 or a.frameCount() < 2 or self.atEnd()) return;
        const ms = @as(f32, @floatFromInt(a.delay(a.shown orelse 0))) / s.speed;
        self.timer.start(.single_shot, @intFromFloat(@max(1, @round(ms))), self, tick);
    }

    fn tick(self: *AnimatedImageElement) void {
        const a = self.animation orelse return;
        var next = (a.shown orelse 0) + 1;
        if (next == a.frameCount()) {
            self.played += 1;
            if (self.atEnd()) {
                self.applied.playing = false;
                if (self.playing.getUntracked()) self.playing.set(false);
                self.finished.call(.{});
                return;
            }
            next = 0;
        }
        self.showFrame(@intCast(next));
        self.schedule();
    }
};

// ---- Tests ----

const testing = std.testing;
const core = @import("core.zig");

fn pixel0(el: *AnimatedImageElement) Rgba8 {
    return el.image.source.getUntracked().?.pixels[0];
}

fn advance(ms: u64, now: *u64) void {
    now.* += ms;
    core.updateTimersAndAnimations(now.*);
    core.runChangeHandlers();
}

test "an animated GIF plays frame by frame, as many times as it says, and seeks" {
    // Red, green, blue: 50 ms each, played twice.
    const bytes = try gif.testGif(testing.allocator, 1, 1, &.{ &.{0}, &.{1}, &.{2} }, 5, 2);
    defer testing.allocator.free(bytes);
    try testing.expect(isAnimated(testing.allocator, bytes));
    var el: AnimatedImageElement = undefined;
    el.init(testing.allocator);
    defer el.deinit();
    var finished: usize = 0;
    el.finished.setHandler(&finished, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);
    var now = core.now();
    el.source.set(.{ .width = 1, .height = 1, .pixels = &.{.transparent}, .animation = bytes });
    core.runChangeHandlers();
    try testing.expectEqual(@as(i32, 3), el.frame_count.get());
    try testing.expectEqual(@as(u8, 255), pixel0(&el).r);

    advance(50, &now);
    try testing.expectEqual(@as(u8, 255), pixel0(&el).g);
    try testing.expectEqual(@as(i32, 1), el.current_frame.get());
    advance(50, &now);
    try testing.expectEqual(@as(u8, 255), pixel0(&el).b);
    advance(50, &now); // the second play
    try testing.expectEqual(@as(u8, 255), pixel0(&el).r);
    advance(50, &now);
    advance(50, &now);
    try testing.expectEqual(@as(u8, 255), pixel0(&el).b);
    try testing.expectEqual(@as(usize, 0), finished);
    advance(50, &now); // done: the last frame stays
    try testing.expectEqual(@as(usize, 1), finished);
    try testing.expect(!el.playing.get());
    try testing.expectEqual(@as(u8, 255), pixel0(&el).b);

    // Shown at a frame; held there while not playing.
    el.current_frame.set(1);
    core.runChangeHandlers();
    try testing.expectEqual(@as(u8, 255), pixel0(&el).g);
    advance(200, &now);
    try testing.expectEqual(@as(u8, 255), pixel0(&el).g);

    // Playing again, from the start, twice as fast.
    el.speed.set(2);
    el.playing.set(true);
    core.runChangeHandlers();
    try testing.expectEqual(@as(u8, 255), pixel0(&el).r);
    advance(25, &now);
    try testing.expectEqual(@as(u8, 255), pixel0(&el).g);
}

test "an animated PNG, a still image, and a source that cannot play" {
    const bytes = try @import("video/apng.zig").testVideo(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expect(isAnimated(testing.allocator, bytes));
    var el: AnimatedImageElement = undefined;
    el.init(testing.allocator);
    defer el.deinit();
    el.source.set(.{ .width = 1, .height = 1, .pixels = &.{.transparent}, .animation = bytes });
    core.runChangeHandlers();
    try testing.expect(el.frame_count.get() > 1);
    try testing.expectEqual(@as(u8, 255), pixel0(&el).r);
    el.current_frame.set(el.frame_count.get() - 1);
    core.runChangeHandlers();
    try testing.expectEqual(@as(u8, 255), pixel0(&el).b);

    const still = [_]Rgba8{.{ .r = 0, .g = 128, .b = 0, .a = 255 }};
    el.source.set(.{ .width = 1, .height = 1, .pixels = &still });
    core.runChangeHandlers();
    try testing.expectEqual(@as(i32, 1), el.frame_count.get());
    try testing.expectEqual(@as(u8, 128), pixel0(&el).g);

    el.source.set(.{ .width = 1, .height = 1, .pixels = &still, .animation = "GIF89a, but not" });
    core.runChangeHandlers();
    try testing.expectEqual(@as(u8, 128), pixel0(&el).g);
    try testing.expect(!isAnimated(testing.allocator, png.signature ++ "rest"));
}
