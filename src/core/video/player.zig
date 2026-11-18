// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Plays a video: decodes frames ahead (a few, in a queue) and the
//! soundtrack (into a mixer feed), and shows each frame when its time comes.
//! The clock is the sound's (how far the mixer has played it), so picture
//! and sound stay together; without sound, it is the UI clock.
//!
//! Decoding runs on a thread of its own, where there are threads (the
//! stream is opened, read and closed there); elsewhere (the web, a
//! microcontroller) `update` decodes on the UI thread as frames are due.
//! Seeking happens in place (the stream seeks, the frames and sound decoded
//! ahead are dropped), so it can follow a pointer.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const video = @import("video.zig");
const audio = @import("../audio/audio.zig");
const Rgba8 = @import("../graphics.zig").Rgba8;
const Image = @import("../image.zig").Image;
const time = @import("../time.zig");

const log = std.log.scoped(.zigulee_video);

pub const threaded = !builtin.single_threaded and builtin.os.tag != .freestanding;

/// Frames decoded ahead.
const queue_len = 4;
/// Soundtrack decoded ahead, in seconds.
const audio_ahead = 0.5;
const audio_chunk = 1024;

pub const Options = struct {
    /// Where to start, in milliseconds.
    start_ms: u64 = 0,
    looping: bool = false,
    paused: bool = false,
    volume: f32 = 1,
};

pub const Player = struct {
    gpa: Allocator,
    source: video.Source,
    info: video.Info = .{ .width = 0, .height = 0 },

    // Decoded frames: frame number k is in slot k % queue_len.
    frames: [queue_len][]Rgba8 = @splat(&.{}),
    times: [queue_len]u64 = @splat(0),
    /// Frames decoded (by the worker).
    decoded: std.atomic.Value(u32) = .init(0),
    /// Frames the UI is done with (their slots are free).
    released: std.atomic.Value(u32) = .init(0),

    // The UI's: the frame showing (a copy), and the next one to look at.
    shown: []Rgba8 = &.{},
    has_frame: bool = false,
    version: u32 = 0,
    next: u32 = 0,
    /// The next frame shows at once (the first, and the first after a
    /// seek), not when due.
    fresh: bool = true,

    // The soundtrack.
    feed: ?audio.Feed = null,
    voice: ?audio.Voice = null,
    /// The mixer plays it (it has an output).
    sound: bool = false,
    audio_on: std.atomic.Value(bool) = .init(false),
    volume: f32 = 1,

    // Seeking: the UI asks (target, then request), the worker answers
    // (ack) with the first frame decoded from there.
    seek_target: std.atomic.Value(u32) = .init(0),
    seek_request: std.atomic.Value(u32) = .init(0),
    seek_ack: std.atomic.Value(u32) = .init(0),
    epoch_first: std.atomic.Value(u32) = .init(0),
    requested: u32 = 0,
    seeking: bool = false,

    // The worker's progress, and what the UI asks of it.
    done: std.atomic.Value(bool) = .init(false),
    /// When the last frame ends, on the clock (once `done`).
    end_ms: std.atomic.Value(u32) = .init(std.math.maxInt(u32)),
    looping: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    open_error: ?video.Error = null,

    // The worker's own.
    stream: ?video.Stream = null,
    first_ms: u64 = 0,
    video_done: bool = false,
    audio_done: bool = false,
    offset: u64 = 0,
    last_time: u64 = 0,
    seek_done: u32 = 0,
    audio_buf: [2 * audio_chunk]f32 = undefined,

    // The thread, and how it waits.
    thread: if (threaded) ?std.Thread else void = if (threaded) null else {},
    io: if (threaded) std.Io.Threaded else void = if (threaded) .init_single_threaded else {},
    wake: std.Io.Event = .unset,
    ready: std.Io.Event = .unset,
    go: std.Io.Event = .unset,

    // The clock (the UI's): the video's time is `start_ms` plus what
    // played since.
    start_ms: u64 = 0,
    audio_clock: bool = false,
    started_at: u64 = 0,
    paused_at: ?u64 = null,

    /// Opens `source` (the first decoder that recognizes it) and starts
    /// playing it (or shows its first frame, if paused).
    pub fn open(gpa: Allocator, source: video.Source, options: Options) video.Error!*Player {
        const p = try gpa.create(Player);
        errdefer gpa.destroy(p);
        // Its own copy of the path (a property's string can go).
        const path = try gpa.dupe(u8, source.path);
        errdefer gpa.free(path);
        p.* = .{ .gpa = gpa, .source = .{ .bytes = source.bytes, .path = path }, .first_ms = options.start_ms, .start_ms = options.start_ms, .volume = options.volume };
        p.looping.store(options.looping, .release);
        if (threaded) {
            p.thread = std.Thread.spawn(.{}, run, .{p}) catch return error.OutOfMemory;
            p.ready.waitUncancelable(p.io.io());
            if (p.open_error) |err| {
                p.thread.?.join();
                p.freeBuffers();
                return err;
            }
        } else {
            p.openStream() catch |err| {
                p.freeBuffers();
                return err;
            };
        }

        // The soundtrack, if the mixer can play it.
        if (p.feed) |*feed| {
            p.voice = audio.mixer().playFeed(feed, .{ .gain = options.volume, .paused = options.paused }, null);
            p.sound = p.voice != null;
            p.audio_clock = p.sound;
        }
        p.audio_on.store(p.sound, .release);
        p.started_at = time.now();
        if (options.paused) p.paused_at = p.started_at;
        if (threaded) p.go.set(p.io.io());
        _ = p.update();
        return p;
    }

    /// Stops and frees everything.
    pub fn close(p: *Player) void {
        // The mixer stops reading the feed before it goes.
        if (p.voice) |v| audio.mixer().stop(v);
        if (threaded) {
            p.stopping.store(true, .release);
            p.go.set(p.io.io());
            p.wake.set(p.io.io());
            if (p.thread) |t| t.join();
        } else if (p.stream) |s| s.close();
        p.freeBuffers();
        p.gpa.free(p.source.path);
        p.gpa.destroy(p);
    }

    fn freeBuffers(p: *Player) void {
        for (p.frames) |f| p.gpa.free(f);
        p.gpa.free(p.shown);
        if (p.feed) |*f| f.deinit(p.gpa);
        p.frames = @splat(&.{});
        p.shown = &.{};
        p.feed = null;
    }

    fn wakeWorker(p: *Player) void {
        if (threaded) p.wake.set(p.io.io());
    }

    // ---- The UI's side ----

    /// Shows the frame due now (decoding it first without a thread);
    /// returns whether the frame changed.
    pub fn update(p: *Player) bool {
        if (!threaded) while (p.fill()) {};
        if (p.seeking) {
            if (p.seek_ack.load(.acquire) != p.requested) return false;
            // The worker is there: what it decoded before goes, the clock
            // and the sound start from there.
            p.seeking = false;
            p.next = p.epoch_first.load(.acquire);
            p.released.store(p.next, .release);
            p.fresh = true;
            p.started_at = time.now();
            if (p.paused_at != null) p.paused_at = p.started_at;
            if (p.sound) {
                p.voice = audio.mixer().playFeed(&p.feed.?, .{ .gain = p.volume, .paused = p.paused_at != null }, null);
                p.audio_clock = p.voice != null;
            }
            p.wakeWorker();
        }
        const clk = p.clock();
        const decoded = p.decoded.load(.acquire);
        var pick: ?u32 = null;
        while (p.next < decoded) {
            // The first frame shows at once, the others when due (after a
            // seek, those before the position are skipped).
            if (!p.fresh and p.times[p.next % queue_len] > clk) break;
            pick = p.next;
            p.next += 1;
            p.fresh = false;
        }
        const k = pick orelse return false;
        @memcpy(p.shown, p.frames[k % queue_len]);
        p.has_frame = true;
        p.version +%= 1;
        p.released.store(p.next, .release);
        p.wakeWorker();
        return true;
    }

    /// The frame showing, if one is decoded.
    pub fn frame(p: *const Player) ?Image {
        if (!p.has_frame) return null;
        return .{ .width = p.info.width, .height = p.info.height, .pixels = p.shown, .version = p.version };
    }

    /// Whether a frame is still to come for where it is (it is seeking,
    /// or the first frame from there is not decoded yet).
    pub fn busy(p: *const Player) bool {
        return p.seeking or p.fresh;
    }

    /// Goes to `ms`: the frame there shows as soon as it is decoded (paused
    /// too), and playback goes on from there. Cheap: seeks can follow a
    /// pointer (the worker only does the latest).
    pub fn seek(p: *Player, ms: u64) void {
        // The mixer stops reading the feed: the worker refills it.
        if (p.voice) |v| audio.mixer().stop(v);
        p.voice = null;
        p.audio_clock = false;
        p.start_ms = ms;
        p.seek_target.store(@intCast(@min(ms, std.math.maxInt(u32))), .release);
        p.requested +%= 1;
        p.seek_request.store(p.requested, .release);
        p.seeking = true;
        p.wakeWorker();
    }

    /// Where playback is in the video, in milliseconds (within the
    /// current loop: the clock itself goes on across loops).
    pub fn position(p: *Player) u64 {
        const clk = p.clock();
        const length = p.info.duration_ms;
        const end: u64 = p.end_ms.load(.acquire);
        if (clk >= end) return if (length > 0) length else end;
        return if (length > 0) clk % length else clk;
    }

    /// Whether it played to the end (never while looping).
    pub fn finished(p: *Player) bool {
        if (p.seeking or !p.done.load(.acquire)) return false;
        if (p.next < p.decoded.load(.acquire)) return false;
        if (p.voice) |v| if (audio.mixer().isPlaying(v)) return false;
        return p.clock() >= p.end_ms.load(.acquire);
    }

    pub fn setPaused(p: *Player, paused: bool) void {
        const now = time.now();
        if (paused and p.paused_at == null) p.paused_at = now;
        if (!paused) if (p.paused_at) |at| {
            p.started_at += now - at;
            p.paused_at = null;
        };
        if (p.voice) |v| audio.mixer().setPaused(v, paused);
    }

    pub fn setVolume(p: *Player, volume: f32) void {
        p.volume = volume;
        if (p.voice) |v| audio.mixer().setGain(v, volume);
    }

    pub fn setLooping(p: *Player, looping: bool) void {
        p.looping.store(looping, .release);
    }

    /// The video's time now: the sound's, or the UI clock's (held while
    /// seeking).
    fn clock(p: *Player) u64 {
        if (p.seeking) return p.start_ms;
        if (p.audio_clock) {
            const feed = &p.feed.?;
            const played = @as(u64, feed.read.load(.acquire)) * 1000 / feed.sample_rate;
            if (!(feed.finished.load(.acquire) and feed.available() == 0)) return p.start_ms + played;
            // The sound is over (shorter than the picture): the UI clock
            // goes on from there.
            p.audio_clock = false;
            p.started_at = time.now() -| played;
        }
        const now = p.paused_at orelse time.now();
        return p.start_ms + (now -| p.started_at);
    }

    // ---- The decoding side ----

    fn run(p: *Player) void {
        const io = p.io.io();
        p.openStream() catch |err| {
            p.open_error = err;
            p.ready.set(io);
            return;
        };
        // The first frame before `open` returns, so it shows at once.
        _ = p.decodeFrame();
        p.ready.set(io);
        p.go.waitUncancelable(io);
        while (!p.stopping.load(.acquire)) {
            p.wake.reset();
            if (!p.fill()) p.wake.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }) catch {};
        }
        p.stream.?.close();
    }

    fn openStream(p: *Player) video.Error!void {
        const s = try video.open(p.gpa, p.source);
        errdefer s.close();
        p.info = s.info();
        if (p.info.width == 0 or p.info.height == 0) return error.InvalidVideo;
        const n = @as(usize, p.info.width) * p.info.height;
        for (&p.frames) |*f| {
            f.* = try p.gpa.alloc(Rgba8, n);
            @memset(f.*, Rgba8.transparent);
        }
        p.shown = try p.gpa.alloc(Rgba8, n);
        if (p.info.audio_rate > 0) p.feed = try .init(p.gpa, @intFromFloat(audio_ahead * @as(f64, @floatFromInt(p.info.audio_rate))), p.info.audio_rate);
        if (p.first_ms > 0) try s.seek(p.first_ms);
        p.stream = s;
    }

    /// A seek the UI asked for (the latest): the stream goes there, what
    /// was decoded ahead goes.
    fn serviceSeek(p: *Player) bool {
        const request = p.seek_request.load(.acquire);
        if (request == p.seek_done) return false;
        p.seek_done = request;
        p.stream.?.seek(p.seek_target.load(.acquire)) catch |err| log.info("cannot seek: {t}", .{err});
        // No voice reads the feed (the UI stopped it before asking).
        if (p.feed) |*f| f.reset();
        p.offset = 0;
        p.video_done = false;
        p.audio_done = false;
        p.end_ms.store(std.math.maxInt(u32), .release);
        p.done.store(false, .release);
        p.epoch_first.store(p.decoded.load(.monotonic), .release);
        p.seek_ack.store(request, .release);
        return true;
    }

    /// Decodes the next frame, if there is room; returns whether it tried.
    fn decodeFrame(p: *Player) bool {
        const decoded = p.decoded.load(.monotonic);
        if (p.video_done or decoded - p.released.load(.acquire) >= queue_len) return false;
        const slot = decoded % queue_len;
        if (p.stream.?.frame(p.frames[slot]) catch |err| blk: {
            log.info("cannot decode a frame: {t}", .{err});
            break :blk null;
        }) |t| {
            p.times[slot] = t + p.offset;
            p.last_time = p.times[slot];
            p.decoded.store(decoded + 1, .release);
        } else p.video_done = true;
        return true;
    }

    /// Decodes what there is room for; returns whether it did anything.
    fn fill(p: *Player) bool {
        if (p.serviceSeek()) return true;
        if (p.done.load(.monotonic)) return false;
        const s = p.stream.?;
        var did = p.decodeFrame();
        const audio_on = p.audio_on.load(.acquire);
        if (!audio_on) p.audio_done = true;
        if (audio_on and !p.audio_done and p.feed.?.space() >= audio_chunk) {
            const n = s.audio(&p.audio_buf) catch 0;
            if (n == 0) p.audio_done = true else _ = p.feed.?.write(p.audio_buf[0 .. 2 * n]);
            did = true;
        }
        if (p.video_done and p.audio_done) {
            const length = if (p.info.duration_ms > 0) p.info.duration_ms else p.last_time - p.offset + 40;
            if (p.looping.load(.acquire) and p.last_time > 0) {
                // Again from the start, on the same clock.
                s.seek(0) catch {};
                p.offset += length;
                p.video_done = false;
                p.audio_done = false;
            } else {
                p.end_ms.store(@intCast(@min(p.offset + length, std.math.maxInt(u32) - 1)), .release);
                if (p.feed) |*f| f.finish();
                p.done.store(true, .release);
            }
            did = true;
        }
        return did;
    }
};

// ---- Tests ----

const testing = std.testing;

/// Runs `update` until the frame changes (the worker may be behind).
fn waitFrame(p: *Player) !void {
    for (0..500) |_| {
        if (p.update()) return;
        if (threaded) {
            var t: std.Io.Threaded = .init_single_threaded;
            t.io().sleep(.fromMilliseconds(2), .awake) catch {};
        }
    }
    return error.TestUnexpectedResult;
}

test "a player shows frames when due, loops, and finishes" {
    const bytes = try video.apng.testVideo(testing.allocator);
    defer testing.allocator.free(bytes);
    const t0 = time.now();
    const p = try Player.open(testing.allocator, .{ .bytes = bytes }, .{});
    defer p.close();
    // The first frame is there as soon as it opens.
    try testing.expectEqual(@as(u8, 255), p.frame().?.pixels[0].r);
    try testing.expectEqual(@as(u32, 2), p.frame().?.width);

    time.advanceTo(t0 + 120);
    try waitFrame(p);
    try testing.expectEqual(@as(u8, 255), p.frame().?.pixels[0].g);
    const v = p.frame().?.version;

    time.advanceTo(t0 + 250);
    try waitFrame(p);
    try testing.expectEqual(@as(u8, 255), p.frame().?.pixels[0].b);
    try testing.expect(p.frame().?.version != v);
    try testing.expect(!p.finished());

    time.advanceTo(t0 + 400);
    for (0..500) |_| {
        _ = p.update();
        if (p.finished()) break;
        if (threaded) {
            var t: std.Io.Threaded = .init_single_threaded;
            t.io().sleep(.fromMilliseconds(2), .awake) catch {};
        }
    }
    try testing.expect(p.finished());
    try testing.expectEqual(@as(u64, 300), p.position());
}

test "a player starts where asked, paused, and loops" {
    const bytes = try video.apng.testVideo(testing.allocator);
    defer testing.allocator.free(bytes);
    const t0 = time.now();
    const p = try Player.open(testing.allocator, .{ .bytes = bytes }, .{ .start_ms = 150, .paused = true, .looping = true });
    defer p.close();
    if (p.frame() == null) try waitFrame(p);
    try testing.expectEqual(@as(u8, 255), p.frame().?.pixels[0].g); // the frame at 150 ms
    time.advanceTo(t0 + 1000);
    _ = p.update();
    try testing.expectEqual(@as(u64, 150), p.position()); // paused
    p.setPaused(false);
    time.advanceTo(t0 + 1000 + 200); // 350: the first frame again
    try waitFrame(p);
    try testing.expectEqual(@as(u8, 255), p.frame().?.pixels[0].r);
    try testing.expect(!p.finished());
}

test "seeking in place, paused: quick seeks end on the last one's frame" {
    const bytes = try video.apng.testVideo(testing.allocator);
    defer testing.allocator.free(bytes);
    const p = try Player.open(testing.allocator, .{ .bytes = bytes }, .{ .paused = true });
    defer p.close();
    if (p.frame() == null) try waitFrame(p);
    try testing.expectEqual(@as(u8, 255), p.frame().?.pixels[0].r);
    // Like a pointer dragged along the bar.
    p.seek(120);
    p.seek(180);
    p.seek(250);
    try testing.expect(p.busy());
    try testing.expectEqual(@as(u64, 250), p.position());
    while (p.busy()) _ = try waitFrameOrIdle(p);
    try testing.expectEqual(@as(u8, 255), p.frame().?.pixels[0].b); // the frame at 250 ms
    try testing.expectEqual(@as(u64, 250), p.position()); // still paused
    // Back, then playing from there.
    p.seek(110);
    while (p.busy()) _ = try waitFrameOrIdle(p);
    try testing.expectEqual(@as(u8, 255), p.frame().?.pixels[0].g);
    try testing.expect(!p.finished());
}

/// Runs `update` once, after a moment (the worker may be behind).
fn waitFrameOrIdle(p: *Player) !bool {
    if (threaded) {
        var t: std.Io.Threaded = .init_single_threaded;
        t.io().sleep(.fromMilliseconds(2), .awake) catch {};
    }
    return p.update();
}

test "sources no decoder recognizes" {
    try testing.expectError(error.UnsupportedVideo, Player.open(testing.allocator, .{ .bytes = "not a video" }, .{}));
}
