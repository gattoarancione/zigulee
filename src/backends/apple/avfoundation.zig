// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Video decoding with AVFoundation (macOS): whatever the system plays
//! (MP4 and QuickTime files: H.264, HEVC, ProRes, ... with AAC, ALAC, ...
//! sound). An `AVAssetReader` decodes frames to BGRA and the soundtrack to
//! 48 kHz stereo floats, on the player's thread. Used by the native macOS
//! backend and, on macOS, by the SDL3 one.
//!
//! AVFoundation reads files: an embedded video is written to a temporary
//! file first (removed when closed).

const std = @import("std");
const zigulee = @import("zigulee");
const objc = @import("objc.zig");
const video = zigulee.core.video;
const Rgba8 = zigulee.core.Rgba8;
const id = objc.id;
const msg = objc.msg;
const class = objc.class;

const log = std.log.scoped(.zigulee_apple);

pub const decoder: video.Decoder = .{ .name = "avfoundation", .open = open };

// ---- CoreMedia, CoreVideo, AVFoundation ----

const CMTime = extern struct { value: i64, timescale: i32, flags: u32, epoch: i64 };
const CMTimeRange = extern struct { start: CMTime, duration: CMTime };
const cm_time_valid = 1;
const cm_time_positive_infinity = 4;

extern "c" fn CMSampleBufferGetPresentationTimeStamp(sbuf: ?*anyopaque) CMTime;
extern "c" fn CMSampleBufferGetImageBuffer(sbuf: ?*anyopaque) ?*anyopaque;
extern "c" fn CMSampleBufferGetDataBuffer(sbuf: ?*anyopaque) ?*anyopaque;
extern "c" fn CMBlockBufferGetDataLength(bb: ?*anyopaque) usize;
extern "c" fn CMBlockBufferCopyDataBytes(bb: ?*anyopaque, offset: usize, length: usize, dest: *anyopaque) i32;
extern "c" fn CVPixelBufferLockBaseAddress(pb: ?*anyopaque, flags: u64) i32;
extern "c" fn CVPixelBufferUnlockBaseAddress(pb: ?*anyopaque, flags: u64) i32;
extern "c" fn CVPixelBufferGetBaseAddress(pb: ?*anyopaque) ?[*]const u8;
extern "c" fn CVPixelBufferGetBytesPerRow(pb: ?*anyopaque) usize;
extern "c" fn CVPixelBufferGetWidth(pb: ?*anyopaque) usize;
extern "c" fn CVPixelBufferGetHeight(pb: ?*anyopaque) usize;
extern "c" fn CFRelease(obj: ?*anyopaque) void;

extern const kCVPixelBufferPixelFormatTypeKey: id;
extern const AVMediaTypeVideo: id;
extern const AVMediaTypeAudio: id;
extern const AVFormatIDKey: id;
extern const AVSampleRateKey: id;
extern const AVNumberOfChannelsKey: id;
extern const AVLinearPCMBitDepthKey: id;
extern const AVLinearPCMIsFloatKey: id;
extern const AVLinearPCMIsNonInterleaved: id;
extern const AVLinearPCMIsBigEndianKey: id;

const pixel_format_bgra = 0x42475241; // 'BGRA'
const audio_format_pcm = 0x6c70636d; // 'lpcm'
const reader_failed = 3;
const audio_rate = 48000;

// For embedded videos.
extern "c" fn mkstemps(template: [*:0]u8, suffix_len: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;

fn number(v: u32) id {
    return msg(id, class("NSNumber"), "numberWithUnsignedInt:", .{v});
}

// ---- The decoder ----

const Reader = struct {
    gpa: std.mem.Allocator,
    asset: id,
    video_track: id,
    audio_track: id,
    reader: id = null,
    video_out: id = null,
    audio_out: id = null,
    info: video.Info,
    /// The temporary file of an embedded video.
    temp_path: ?[:0]u8 = null,
    /// A frame decoded ahead (the first, to know the size).
    pending: ?*anyopaque = null,
    /// Sound decoded and not handed over yet.
    sound: std.ArrayList(f32) = .empty,
    sound_used: usize = 0,

    /// A reader from `ms` on (AVAssetReader cannot seek).
    fn start(r: *Reader, ms: u64) video.Error!void {
        r.stop();
        var err: id = null;
        const reader = msg(id, class("AVAssetReader"), "assetReaderWithAsset:error:", .{ r.asset, &err }) orelse return error.InvalidVideo;
        if (ms > 0) {
            const range: CMTimeRange = .{
                .start = .{ .value = @intCast(ms), .timescale = 1000, .flags = cm_time_valid, .epoch = 0 },
                .duration = .{ .value = 0, .timescale = 1, .flags = cm_time_valid | cm_time_positive_infinity, .epoch = 0 },
            };
            msg(void, reader, "setTimeRange:", .{range});
        }
        const pixels = msg(id, class("NSMutableDictionary"), "dictionary", .{});
        msg(void, pixels, "setObject:forKey:", .{ number(pixel_format_bgra), kCVPixelBufferPixelFormatTypeKey });
        const vout = msg(id, class("AVAssetReaderTrackOutput"), "assetReaderTrackOutputWithTrack:outputSettings:", .{ r.video_track, pixels });
        msg(void, vout, "setAlwaysCopiesSampleData:", .{false});
        if (!msg(bool, reader, "canAddOutput:", .{vout})) return error.UnsupportedVideo;
        msg(void, reader, "addOutput:", .{vout});
        var aout: id = null;
        if (r.audio_track != null) {
            const pcm = msg(id, class("NSMutableDictionary"), "dictionary", .{});
            msg(void, pcm, "setObject:forKey:", .{ number(audio_format_pcm), AVFormatIDKey });
            msg(void, pcm, "setObject:forKey:", .{ number(audio_rate), AVSampleRateKey });
            msg(void, pcm, "setObject:forKey:", .{ number(2), AVNumberOfChannelsKey });
            msg(void, pcm, "setObject:forKey:", .{ number(32), AVLinearPCMBitDepthKey });
            msg(void, pcm, "setObject:forKey:", .{ number(1), AVLinearPCMIsFloatKey });
            msg(void, pcm, "setObject:forKey:", .{ number(0), AVLinearPCMIsNonInterleaved });
            msg(void, pcm, "setObject:forKey:", .{ number(0), AVLinearPCMIsBigEndianKey });
            aout = msg(id, class("AVAssetReaderTrackOutput"), "assetReaderTrackOutputWithTrack:outputSettings:", .{ r.audio_track, pcm });
            if (msg(bool, reader, "canAddOutput:", .{aout})) {
                msg(void, reader, "addOutput:", .{aout});
            } else aout = null;
        }
        if (!msg(bool, reader, "startReading", .{})) return error.InvalidVideo;
        r.reader = msg(id, reader, "retain", .{});
        r.video_out = msg(id, vout, "retain", .{});
        r.audio_out = if (aout) |a| msg(id, a, "retain", .{}) else null;
    }

    fn stop(r: *Reader) void {
        if (r.pending) |p| CFRelease(p);
        r.pending = null;
        r.sound.clearRetainingCapacity();
        r.sound_used = 0;
        if (r.reader) |reader| {
            msg(void, reader, "cancelReading", .{});
            msg(void, reader, "release", .{});
        }
        if (r.video_out) |o| msg(void, o, "release", .{});
        if (r.audio_out) |o| msg(void, o, "release", .{});
        r.reader = null;
        r.video_out = null;
        r.audio_out = null;
    }

    fn nextVideo(r: *Reader) ?*anyopaque {
        if (r.pending) |p| {
            r.pending = null;
            return p;
        }
        const out = r.video_out orelse return null;
        const sample: ?*anyopaque = msg(?*anyopaque, out, "copyNextSampleBuffer", .{});
        if (sample == null and msg(isize, r.reader, "status", .{}) == reader_failed) log.info("AVFoundation could not decode the video", .{});
        return sample;
    }
};

fn open(_: ?*anyopaque, gpa: std.mem.Allocator, source: video.Source) video.Error!?video.Stream {
    // Embedded: an MP4 or QuickTime file (an "ftyp" box first).
    if (source.bytes.len > 0 and !(source.bytes.len > 12 and std.mem.eql(u8, source.bytes[4..8], "ftyp"))) return null;
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);

    var temp_path: ?[:0]u8 = null;
    errdefer if (temp_path) |p| {
        _ = unlink(p);
        gpa.free(p);
    };
    const path: []const u8 = if (source.bytes.len > 0) blk: {
        temp_path = try writeTemp(gpa, source.bytes);
        break :blk temp_path.?;
    } else source.path;

    const url = msg(id, class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
    const asset = msg(id, class("AVURLAsset"), "URLAssetWithURL:options:", .{ url, @as(id, null) }) orelse return error.InvalidVideo;
    const videos = msg(id, asset, "tracksWithMediaType:", .{AVMediaTypeVideo});
    if (msg(usize, videos, "count", .{}) == 0) {
        // Not a video (or not one AVFoundation reads): another decoder's.
        if (temp_path) |p| {
            _ = unlink(p);
            gpa.free(p);
            temp_path = null;
        }
        return null;
    }
    const sounds = msg(id, asset, "tracksWithMediaType:", .{AVMediaTypeAudio});
    const duration = msg(CMTime, asset, "duration", .{});

    const r = try gpa.create(Reader);
    errdefer gpa.destroy(r);
    r.* = .{
        .gpa = gpa,
        .asset = msg(id, asset, "retain", .{}),
        .video_track = msg(id, msg(id, videos, "objectAtIndex:", .{@as(usize, 0)}), "retain", .{}),
        .audio_track = if (msg(usize, sounds, "count", .{}) > 0) msg(id, msg(id, sounds, "objectAtIndex:", .{@as(usize, 0)}), "retain", .{}) else null,
        .info = .{
            .width = 0,
            .height = 0,
            .duration_ms = if (duration.flags & cm_time_valid != 0 and duration.timescale > 0) @intCast(@divTrunc(duration.value * 1000, duration.timescale)) else 0,
        },
        .temp_path = temp_path,
    };
    errdefer close(r);
    try r.start(0);
    if (r.audio_out != null) r.info.audio_rate = audio_rate;
    // The first frame gives the size.
    const first = r.nextVideo() orelse return error.InvalidVideo;
    r.pending = first;
    const pb = CMSampleBufferGetImageBuffer(first) orelse return error.InvalidVideo;
    r.info.width = @intCast(CVPixelBufferGetWidth(pb));
    r.info.height = @intCast(CVPixelBufferGetHeight(pb));
    temp_path = null; // the reader has it
    return .{ .ctx = r, .vtable = &.{ .info = info, .frame = frame, .audio = audio, .seek = seek, .close = close } };
}

/// Writes `bytes` to a new temporary file; returns its path.
fn writeTemp(gpa: std.mem.Allocator, bytes: []const u8) video.Error![:0]u8 {
    const dir = std.mem.span(std.c.getenv("TMPDIR") orelse "/tmp/");
    const sep = if (std.mem.endsWith(u8, dir, "/")) "" else "/";
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}{s}zigulee-video-XXXXXX.mp4", .{ dir, sep }, 0);
    errdefer gpa.free(path);
    const fd = mkstemps(path.ptr, 4);
    if (fd < 0) return error.ReadFailed;
    defer _ = std.c.close(fd);
    var at: usize = 0;
    while (at < bytes.len) {
        const n = std.c.write(fd, bytes[at..].ptr, bytes.len - at);
        if (n <= 0) {
            _ = unlink(path);
            return error.ReadFailed;
        }
        at += @intCast(n);
    }
    return path;
}

fn info(ctx: *anyopaque) video.Info {
    const r: *Reader = @ptrCast(@alignCast(ctx));
    return r.info;
}

fn frame(ctx: *anyopaque, pixels: []Rgba8) video.Error!?u64 {
    const r: *Reader = @ptrCast(@alignCast(ctx));
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    const sample = r.nextVideo() orelse return null;
    defer CFRelease(sample);
    const t = CMSampleBufferGetPresentationTimeStamp(sample);
    const ms: u64 = if (t.flags & cm_time_valid != 0 and t.timescale > 0 and t.value > 0) @intCast(@divTrunc(t.value * 1000, t.timescale)) else 0;
    const pb = CMSampleBufferGetImageBuffer(sample) orelse return ms;
    if (CVPixelBufferLockBaseAddress(pb, 1) != 0) return ms;
    defer _ = CVPixelBufferUnlockBaseAddress(pb, 1);
    const base = CVPixelBufferGetBaseAddress(pb) orelse return ms;
    const stride = CVPixelBufferGetBytesPerRow(pb);
    const w = @min(CVPixelBufferGetWidth(pb), r.info.width);
    const h = @min(CVPixelBufferGetHeight(pb), r.info.height);
    for (0..h) |y| {
        const row = base[y * stride ..];
        const out = pixels[y * r.info.width ..][0..w];
        for (out, 0..) |*p, x| p.* = .{ .r = row[4 * x + 2], .g = row[4 * x + 1], .b = row[4 * x], .a = row[4 * x + 3] };
    }
    return ms;
}

fn audio(ctx: *anyopaque, out: []f32) video.Error!usize {
    const r: *Reader = @ptrCast(@alignCast(ctx));
    if (r.sound_used >= r.sound.items.len) {
        // Decode the next piece.
        const output = r.audio_out orelse return 0;
        const pool = objc.objc_autoreleasePoolPush();
        defer objc.objc_autoreleasePoolPop(pool);
        const sample: ?*anyopaque = msg(?*anyopaque, output, "copyNextSampleBuffer", .{});
        if (sample == null) return 0;
        defer CFRelease(sample);
        const block = CMSampleBufferGetDataBuffer(sample) orelse return 0;
        const len = CMBlockBufferGetDataLength(block);
        r.sound.clearRetainingCapacity();
        r.sound_used = 0;
        try r.sound.resize(r.gpa, len / @sizeOf(f32));
        if (CMBlockBufferCopyDataBytes(block, 0, r.sound.items.len * @sizeOf(f32), r.sound.items.ptr) != 0) return 0;
    }
    const n = @min(out.len, r.sound.items.len - r.sound_used) / 2 * 2;
    @memcpy(out[0..n], r.sound.items[r.sound_used..][0..n]);
    r.sound_used += n;
    return n / 2;
}

fn seek(ctx: *anyopaque, ms: u64) video.Error!void {
    const r: *Reader = @ptrCast(@alignCast(ctx));
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    try r.start(ms);
}

fn close(ctx: *anyopaque) void {
    const r: *Reader = @ptrCast(@alignCast(ctx));
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    r.stop();
    r.sound.deinit(r.gpa);
    msg(void, r.video_track, "release", .{});
    if (r.audio_track) |t| msg(void, t, "release", .{});
    msg(void, r.asset, "release", .{});
    if (r.temp_path) |p| {
        _ = unlink(p);
        r.gpa.free(p);
    }
    r.gpa.destroy(r);
}

// ---- Tests ----

const testing = std.testing;
const test_mp4 = @embedFile("test_mp4");

test "AVFoundation decodes an MP4: frames in time, and the soundtrack" {
    const s = (try open(null, testing.allocator, .{ .bytes = test_mp4 })) orelse return error.TestUnexpectedResult;
    defer s.close();
    const i = s.info();
    try testing.expectEqual(@as(u32, 64), i.width);
    try testing.expectEqual(@as(u32, 32), i.height);
    try testing.expectEqual(@as(u64, 1200), i.duration_ms);
    try testing.expectEqual(@as(u32, audio_rate), i.audio_rate);

    var pixels: [64 * 32]Rgba8 = undefined;
    var times: [12]u64 = undefined;
    var n: usize = 0;
    while (try s.frame(&pixels)) |t| : (n += 1) {
        if (n < times.len) times[n] = t;
        const p = pixels[16 * 64 + 32];
        // Red, then green, then blue (YUV-coded: about).
        switch (n / 4) {
            0 => try testing.expect(p.r > 200 and p.g < 60 and p.b < 60),
            1 => try testing.expect(p.g > 200 and p.r < 60 and p.b < 60),
            else => try testing.expect(p.b > 200 and p.r < 60 and p.g < 60),
        }
    }
    try testing.expectEqual(@as(usize, 12), n);
    try testing.expectEqual(@as(u64, 0), times[0]);
    try testing.expectEqual(@as(u64, 500), times[5]);

    // About 1.2 s of a tone.
    var sound: [2048]f32 = undefined;
    var frames: usize = 0;
    var peak: f32 = 0;
    while (true) {
        const got = try s.audio(&sound);
        if (got == 0) break;
        frames += got;
        for (sound[0 .. 2 * got]) |x| peak = @max(peak, @abs(x));
    }
    try testing.expect(frames > 55000 and frames < 60000);
    try testing.expect(peak > 0.05); // ffmpeg's tone: 1/8

    // Seeking: the frames from there.
    try s.seek(850);
    const t = (try s.frame(&pixels)).?;
    try testing.expect(t >= 800 and t <= 900);
    try testing.expect(pixels[0].b > 200);
}

test "AVFoundation leaves other files to other decoders" {
    try testing.expectEqual(@as(?video.Stream, null), try open(null, testing.allocator, .{ .bytes = "\x89PNG\r\n\x1a\n...." }));
}

test "an MP4 plays through the player, on its thread" {
    video.addDecoder(decoder);
    defer video.removeDecoder(decoder.name);
    const time = zigulee.core;
    const p = try video.Player.open(testing.allocator, .{ .bytes = test_mp4 }, .{});
    defer p.close();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const t0 = time.now();
    var colors: [3]bool = .{ false, false, false };
    for (0..3000) |i| {
        time.updateTimersAndAnimations(t0 + i);
        _ = p.update();
        if (p.frame()) |img| {
            const px = img.pixels[16 * 64 + 32];
            if (px.r > 200) colors[0] = true;
            if (px.g > 200) colors[1] = true;
            if (px.b > 200) colors[2] = true;
        }
        if (p.finished()) break;
        threaded.io().sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(p.finished());
    try testing.expectEqual([3]bool{ true, true, true }, colors);
}

/// An audio output that consumes the mix in real time, on its own thread
/// (as a device would).
const RealTimeOutput = struct {
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),

    fn output(self: *RealTimeOutput) zigulee.core.audio.Output {
        return .{ .ctx = self, .vtable = &.{ .start = start, .stop = stop } };
    }
    fn start(ctx: ?*anyopaque, mixer: *zigulee.core.audio.Mixer) zigulee.core.audio.Output.Error!u32 {
        const self: *RealTimeOutput = @ptrCast(@alignCast(ctx));
        self.stopping.store(false, .release);
        self.thread = std.Thread.spawn(.{}, run, .{ self, mixer }) catch return error.AudioUnavailable;
        return 48000;
    }
    fn stop(ctx: ?*anyopaque) void {
        const self: *RealTimeOutput = @ptrCast(@alignCast(ctx));
        self.stopping.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }
    fn run(self: *RealTimeOutput, mixer: *zigulee.core.audio.Mixer) void {
        var threaded: std.Io.Threaded = .init_single_threaded;
        var buf: [2 * 480]f32 = undefined;
        while (!self.stopping.load(.acquire)) {
            mixer.render(&buf); // 10 ms
            threaded.io().sleep(.fromMilliseconds(10), .awake) catch {};
        }
    }
};

test "an MP4 with sound: the picture follows the sound's clock" {
    video.addDecoder(decoder);
    defer video.removeDecoder(decoder.name);
    var device: RealTimeOutput = .{};
    const mixer = zigulee.core.audio.mixer();
    mixer.setOutput(device.output());
    defer mixer.setOutput(null);
    const core = zigulee.core;
    const p = try video.Player.open(testing.allocator, .{ .bytes = test_mp4 }, .{});
    defer p.close();
    try testing.expect(p.voice != null);
    var threaded: std.Io.Threaded = .init_single_threaded;
    const t0 = core.now();
    var colors: [3]bool = .{ false, false, false };
    for (0..3000) |i| {
        core.updateTimersAndAnimations(t0 + i);
        _ = p.update();
        if (p.frame()) |img| {
            const px = img.pixels[16 * 64 + 32];
            if (px.r > 200) colors[0] = true;
            if (px.g > 200) colors[1] = true;
            if (px.b > 200) colors[2] = true;
        }
        if (p.finished()) break;
        threaded.io().sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expectEqual([3]bool{ true, true, true }, colors);
    try testing.expect(p.finished());
}

test "an MP4 with sound in a Video element: the picture moves" {
    video.addDecoder(decoder);
    defer video.removeDecoder(decoder.name);
    var device: RealTimeOutput = .{};
    const mixer = zigulee.core.audio.mixer();
    mixer.setOutput(device.output());
    defer mixer.setOutput(null);
    const core = zigulee.core;
    var el: video.VideoElement = undefined;
    el.init(testing.allocator);
    defer el.deinit();
    el.source.set(.{ .bytes = test_mp4 });
    el.playing.set(true);
    var threaded: std.Io.Threaded = .init_single_threaded;
    var colors: [3]bool = .{ false, false, false };
    var changes: usize = 0;
    var last: ?zigulee.core.Image = null;
    for (0..3000) |_| {
        core.updateTimersAndAnimations(core.now() + 1);
        core.runChangeHandlers();
        if (el.image.source.get()) |img| {
            if (last == null or !img.eql(last.?)) changes += 1;
            last = img;
            const px = img.pixels[16 * 64 + 32];
            if (px.r > 200) colors[0] = true;
            if (px.g > 200) colors[1] = true;
            if (px.b > 200) colors[2] = true;
        }
        if (!el.playing.get() and changes > 0) break;
        threaded.io().sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expectEqual([3]bool{ true, true, true }, colors);
}
