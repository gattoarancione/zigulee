// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Video decoding with Media Foundation (Windows): whatever the system
//! plays (MP4: H.264, HEVC with its extension, ...; AVI, WMV, and with the
//! system's extensions WebM and Matroska), with the soundtrack. A source
//! reader decodes frames to RGB32 and the sound to stereo floats, on the
//! player's thread. Embedded videos are read from memory.

const std = @import("std");
const zigulee = @import("zigulee");
const c = @import("win32_c");
const video = zigulee.core.video;
const Rgba8 = zigulee.core.Rgba8;

const log = std.log.scoped(.zigulee_windows);

pub const decoder: video.Decoder = .{ .name = "mediafoundation", .open = open };

fn guid(a: u32, b: u16, cc: u16, d: [8]u8) c.GUID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = cc, .Data4 = d };
}
fn mediaType(format: u32) c.GUID {
    return guid(format, 0x0000, 0x0010, .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 });
}

// From mfapi.h, mfidl.h and mfreadwrite.h.
const enable_video_processing = guid(0xfb394f3d, 0xccf1, 0x42ee, .{ 0xbb, 0xb3, 0xf9, 0xb8, 0x45, 0xd5, 0x68, 0x1d });
const mt_major_type = guid(0x48eba18e, 0xf8c9, 0x4687, .{ 0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f });
const mt_subtype = guid(0xf7e34c9a, 0x42e8, 0x4714, .{ 0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5 });
const mt_frame_size = guid(0x1652c33d, 0xd6b2, 0x4012, .{ 0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d });
const mt_default_stride = guid(0x644b4e48, 0x1e02, 0x4516, .{ 0xb0, 0xeb, 0xc0, 0x1c, 0xa9, 0xd4, 0x9a, 0xc6 });
const mt_audio_channels = guid(0x37e48bf5, 0x645e, 0x4c5b, .{ 0x89, 0xde, 0xad, 0xa9, 0xe2, 0x9b, 0x69, 0x6a });
const mt_audio_rate = guid(0x5faeeae7, 0x0290, 0x4c31, .{ 0x9e, 0x8a, 0xc5, 0x34, 0xf6, 0x8d, 0x9d, 0xba });
const mt_audio_bits = guid(0xf2deb57f, 0x40fa, 0x4764, .{ 0xaa, 0x33, 0xed, 0x4f, 0x2d, 0x1f, 0xf6, 0x69 });
const pd_duration = guid(0x6c990d33, 0xbb8e, 0x477a, .{ 0x85, 0x98, 0x0d, 0x5d, 0x96, 0xfc, 0xd8, 0x8a });
const media_video = mediaType(0x73646976);
const media_audio = mediaType(0x73647561);
const format_rgb32 = mediaType(22); // D3DFMT_X8R8G8B8
const format_float = mediaType(3); // WAVE_FORMAT_IEEE_FLOAT
const guid_null = std.mem.zeroes(c.GUID);

const first_video: u32 = 0xfffffffc;
const first_audio: u32 = 0xfffffffd;
const all_streams: u32 = 0xfffffffe;
const media_source: u32 = 0xffffffff;
const end_of_stream = 0x2;
const type_changed = 0x20;
const mf_version = 0x0002_0070;
const vt_i8 = 20;

/// Exported by mfplat, not declared in the MinGW headers.
extern "mfplat" fn MFCreateMFByteStreamOnStream(stream: ?*c.IStream, bytes: *?*c.IMFByteStream) callconv(.winapi) c.HRESULT;

/// A PROPVARIANT holding a 64-bit integer (its layout, without the union).
const PropVariant = extern struct { vt: u16 = 0, reserved: [3]u16 = .{ 0, 0, 0 }, value: i64 = 0, more: usize = 0 };

/// Releases a COM object (or nothing, given null).
fn release(obj: anytype) void {
    if (@typeInfo(@TypeOf(obj)) == .optional) {
        if (obj) |o| _ = o.*.lpVtbl.*.Release.?(o);
    } else _ = obj.*.lpVtbl.*.Release.?(obj);
}

const Reader = struct {
    gpa: std.mem.Allocator,
    com: bool,
    reader: *c.IMFSourceReader,
    info: video.Info,
    stride: i32,
    channels: u32 = 2,
    /// Sound decoded and not handed over yet (interleaved stereo).
    sound: std.ArrayList(f32) = .empty,
    sound_used: usize = 0,
    /// After a seek: sound before this (in 100 ns) is dropped.
    sound_from: i64 = 0,
    audio_done: bool = false,

    /// Reads the size and stride of the current video type.
    fn readVideoType(r: *Reader) bool {
        var t: ?*c.IMFMediaType = null;
        if (r.reader.lpVtbl.*.GetCurrentMediaType.?(r.reader, first_video, &t) < 0) return false;
        defer release(t);
        var size: u64 = 0;
        if (t.?.lpVtbl.*.GetUINT64.?(t, &mt_frame_size, &size) < 0) return false;
        r.info.width = @intCast(size >> 32);
        r.info.height = @truncate(size);
        var stride: u32 = 0;
        r.stride = if (t.?.lpVtbl.*.GetUINT32.?(t, &mt_default_stride, &stride) >= 0) @bitCast(stride) else @intCast(r.info.width * 4);
        return r.info.width > 0 and r.info.height > 0;
    }
};

fn open(_: ?*anyopaque, gpa: std.mem.Allocator, source: video.Source) video.Error!?video.Stream {
    if (source.bytes.len > 0 and !looksLikeVideo(source.bytes)) return null;
    const com_hr = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
    const com = com_hr >= 0;
    errdefer if (com) c.CoUninitialize();
    if (c.MFStartup(mf_version, 0) < 0) {
        log.info("Media Foundation is not available", .{});
        return null;
    }
    errdefer _ = c.MFShutdown();

    var attrs: ?*c.IMFAttributes = null;
    if (c.MFCreateAttributes(&attrs, 1) < 0) return error.OutOfMemory;
    defer release(attrs);
    _ = attrs.?.lpVtbl.*.SetUINT32.?(attrs, &enable_video_processing, 1);

    var reader: ?*c.IMFSourceReader = null;
    if (source.bytes.len > 0) {
        // From memory: a stream on a copy of the bytes.
        const stream = c.SHCreateMemStream(source.bytes.ptr, @intCast(source.bytes.len)) orelse return error.OutOfMemory;
        defer release(stream);
        var bytes: ?*c.IMFByteStream = null;
        if (MFCreateMFByteStreamOnStream(stream, &bytes) < 0) return error.OutOfMemory;
        defer release(bytes);
        if (c.MFCreateSourceReaderFromByteStream(bytes, attrs, &reader) < 0) return error.UnsupportedVideo;
    } else {
        const path = std.unicode.utf8ToUtf16LeAllocZ(gpa, source.path) catch return error.ReadFailed;
        defer gpa.free(path);
        // Not a file Media Foundation reads: another decoder's.
        if (c.MFCreateSourceReaderFromURL(path.ptr, attrs, &reader) < 0) {
            _ = c.MFShutdown();
            if (com) c.CoUninitialize();
            return null;
        }
    }
    const rd = reader.?;
    errdefer release(reader);

    // The first video and sound streams only.
    _ = rd.lpVtbl.*.SetStreamSelection.?(rd, all_streams, c.FALSE);
    if (rd.lpVtbl.*.SetStreamSelection.?(rd, first_video, c.TRUE) < 0) return error.UnsupportedVideo;
    const has_audio = rd.lpVtbl.*.SetStreamSelection.?(rd, first_audio, c.TRUE) >= 0;

    // Frames as RGB32 (B, G, R, unused).
    {
        var t: ?*c.IMFMediaType = null;
        if (c.MFCreateMediaType(&t) < 0) return error.OutOfMemory;
        defer release(t);
        _ = t.?.lpVtbl.*.SetGUID.?(t, &mt_major_type, &media_video);
        _ = t.?.lpVtbl.*.SetGUID.?(t, &mt_subtype, &format_rgb32);
        if (rd.lpVtbl.*.SetCurrentMediaType.?(rd, first_video, null, t) < 0) return error.UnsupportedVideo;
    }

    const r = try gpa.create(Reader);
    errdefer gpa.destroy(r);
    r.* = .{ .gpa = gpa, .com = com, .reader = rd, .info = .{ .width = 0, .height = 0 }, .stride = 0 };
    if (!r.readVideoType()) return error.InvalidVideo;

    // The sound as 32-bit floats, stereo if the reader converts it.
    if (has_audio) audio: {
        var t: ?*c.IMFMediaType = null;
        if (c.MFCreateMediaType(&t) < 0) break :audio;
        defer release(t);
        _ = t.?.lpVtbl.*.SetGUID.?(t, &mt_major_type, &media_audio);
        _ = t.?.lpVtbl.*.SetGUID.?(t, &mt_subtype, &format_float);
        _ = t.?.lpVtbl.*.SetUINT32.?(t, &mt_audio_bits, 32);
        _ = t.?.lpVtbl.*.SetUINT32.?(t, &mt_audio_channels, 2);
        if (rd.lpVtbl.*.SetCurrentMediaType.?(rd, first_audio, null, t) < 0) {
            _ = t.?.lpVtbl.*.DeleteItem.?(t, &mt_audio_channels);
            if (rd.lpVtbl.*.SetCurrentMediaType.?(rd, first_audio, null, t) < 0) {
                _ = rd.lpVtbl.*.SetStreamSelection.?(rd, first_audio, c.FALSE);
                break :audio;
            }
        }
        var current: ?*c.IMFMediaType = null;
        if (rd.lpVtbl.*.GetCurrentMediaType.?(rd, first_audio, &current) < 0) break :audio;
        defer release(current);
        var rate: u32 = 0;
        var channels: u32 = 0;
        _ = current.?.lpVtbl.*.GetUINT32.?(current, &mt_audio_rate, &rate);
        _ = current.?.lpVtbl.*.GetUINT32.?(current, &mt_audio_channels, &channels);
        if (rate > 0 and channels > 0) {
            r.info.audio_rate = rate;
            r.channels = channels;
        }
    }
    if (r.info.audio_rate == 0) r.audio_done = true;

    var duration: PropVariant = .{};
    if (rd.lpVtbl.*.GetPresentationAttribute.?(rd, media_source, &pd_duration, @ptrCast(&duration)) >= 0 and duration.value > 0)
        r.info.duration_ms = @intCast(@divTrunc(duration.value, 10_000));
    return .{ .ctx = r, .vtable = &.{ .info = info, .frame = frame, .audio = audio, .seek = seek, .close = close } };
}

/// MP4/QuickTime, AVI, WebM/Matroska or ASF (WMV).
fn looksLikeVideo(b: []const u8) bool {
    if (b.len < 16) return false;
    return std.mem.eql(u8, b[4..8], "ftyp") or
        (std.mem.eql(u8, b[0..4], "RIFF") and std.mem.eql(u8, b[8..12], "AVI ")) or
        std.mem.eql(u8, b[0..4], "\x1a\x45\xdf\xa3") or
        std.mem.eql(u8, b[0..4], "\x30\x26\xb2\x75");
}

fn info(ctx: *anyopaque) video.Info {
    const r: *Reader = @ptrCast(@alignCast(ctx));
    return r.info;
}

/// The next sample of `stream` and its time (100 ns), or null at its end.
fn read(r: *Reader, stream: u32, time: *i64) ?*c.IMFSample {
    while (true) {
        var index: u32 = 0;
        var flags: u32 = 0;
        var sample: ?*c.IMFSample = null;
        if (r.reader.lpVtbl.*.ReadSample.?(r.reader, stream, 0, &index, &flags, time, &sample) < 0) return null;
        if (flags & type_changed != 0 and stream == first_video) _ = r.readVideoType();
        if (sample) |s| return s;
        if (flags & end_of_stream != 0) return null;
    }
}

fn frame(ctx: *anyopaque, pixels: []Rgba8) video.Error!?u64 {
    const r: *Reader = @ptrCast(@alignCast(ctx));
    var time: i64 = 0;
    const sample = read(r, first_video, &time) orelse return null;
    defer release(sample);
    const ms: u64 = @intCast(@max(@divTrunc(time, 10_000), 0));
    var buffer: ?*c.IMFMediaBuffer = null;
    if (sample.lpVtbl.*.ConvertToContiguousBuffer.?(sample, &buffer) < 0) return ms;
    defer release(buffer);
    var data: [*c]u8 = null;
    var max: u32 = 0;
    var len: u32 = 0;
    if (buffer.?.lpVtbl.*.Lock.?(buffer, &data, &max, &len) < 0) return ms;
    defer _ = buffer.?.lpVtbl.*.Unlock.?(buffer);
    const w = r.info.width;
    const stride: usize = @abs(r.stride);
    const rows = @min(r.info.height, len / @max(stride, 1));
    for (0..rows) |y| {
        // A negative stride: the rows go up.
        const src_row = if (r.stride < 0) r.info.height - 1 - y else y;
        const row = data[src_row * stride ..];
        for (pixels[y * w ..][0..w], 0..) |*p, x| p.* = .{ .r = row[4 * x + 2], .g = row[4 * x + 1], .b = row[4 * x], .a = 255 };
    }
    return ms;
}

fn audio(ctx: *anyopaque, out: []f32) video.Error!usize {
    const r: *Reader = @ptrCast(@alignCast(ctx));
    while (r.sound_used >= r.sound.items.len) {
        if (r.audio_done) return 0;
        var time: i64 = 0;
        const sample = read(r, first_audio, &time) orelse {
            r.audio_done = true;
            return 0;
        };
        defer release(sample);
        var buffer: ?*c.IMFMediaBuffer = null;
        if (sample.lpVtbl.*.ConvertToContiguousBuffer.?(sample, &buffer) < 0) continue;
        defer release(buffer);
        var data: [*c]u8 = null;
        var max: u32 = 0;
        var len: u32 = 0;
        if (buffer.?.lpVtbl.*.Lock.?(buffer, &data, &max, &len) < 0) continue;
        defer _ = buffer.?.lpVtbl.*.Unlock.?(buffer);
        const floats: [*]const f32 = @ptrCast(@alignCast(data));
        const ch = r.channels;
        var frames: usize = len / (4 * ch);
        var first: usize = 0;
        // After a seek, from the asked time on.
        if (time < r.sound_from) {
            const skip: usize = @intCast(@divTrunc((r.sound_from - time) * r.info.audio_rate, 10_000_000));
            if (skip >= frames) continue;
            first = skip;
        }
        frames -= first;
        r.sound.clearRetainingCapacity();
        r.sound_used = 0;
        try r.sound.resize(r.gpa, 2 * frames);
        for (0..frames) |i| {
            const f = floats[(first + i) * ch ..];
            r.sound.items[2 * i] = f[0];
            r.sound.items[2 * i + 1] = if (ch > 1) f[1] else f[0];
        }
    }
    const n = @min(out.len, r.sound.items.len - r.sound_used) / 2 * 2;
    @memcpy(out[0..n], r.sound.items[r.sound_used..][0..n]);
    r.sound_used += n;
    return n / 2;
}

fn seek(ctx: *anyopaque, ms: u64) video.Error!void {
    const r: *Reader = @ptrCast(@alignCast(ctx));
    const at: i64 = @intCast(ms * 10_000);
    var pos: PropVariant = .{ .vt = vt_i8, .value = at };
    if (r.reader.lpVtbl.*.SetCurrentPosition.?(r.reader, &guid_null, @ptrCast(&pos)) < 0) return error.InvalidVideo;
    // Frames start at the key frame before: the player catches up. The
    // sound starts where asked.
    r.sound.clearRetainingCapacity();
    r.sound_used = 0;
    r.sound_from = at;
    r.audio_done = r.info.audio_rate == 0;
}

fn close(ctx: *anyopaque) void {
    const r: *Reader = @ptrCast(@alignCast(ctx));
    release(r.reader);
    r.sound.deinit(r.gpa);
    _ = c.MFShutdown();
    if (r.com) c.CoUninitialize();
    r.gpa.destroy(r);
}

// ---- Tests ----

const testing = std.testing;
const test_mp4 = @embedFile("test_mp4");

test "Media Foundation decodes an MP4: frames in time, and the soundtrack" {
    const s = (try open(null, testing.allocator, .{ .bytes = test_mp4 })) orelse return error.SkipZigTest; // no Media Foundation (Windows N)
    defer s.close();
    const i = s.info();
    try testing.expectEqual(@as(u32, 64), i.width);
    try testing.expectEqual(@as(u32, 32), i.height);
    try testing.expectEqual(@as(u64, 1200), i.duration_ms);
    try testing.expect(i.audio_rate > 0);

    var pixels: [64 * 32]Rgba8 = undefined;
    var n: usize = 0;
    var times: [12]u64 = undefined;
    while (try s.frame(&pixels)) |t| : (n += 1) {
        if (n < times.len) times[n] = t;
        const p = pixels[16 * 64 + 32];
        switch (n / 4) {
            0 => try testing.expect(p.r > 200 and p.g < 60 and p.b < 60),
            1 => try testing.expect(p.g > 200 and p.r < 60 and p.b < 60),
            else => try testing.expect(p.b > 200 and p.r < 60 and p.g < 60),
        }
    }
    try testing.expectEqual(@as(usize, 12), n);
    try testing.expectEqual(@as(u64, 500), times[5]);

    var sound: [2048]f32 = undefined;
    var frames: usize = 0;
    var peak: f32 = 0;
    while (true) {
        const got = try s.audio(&sound);
        if (got == 0) break;
        frames += got;
        for (sound[0 .. 2 * got]) |x| peak = @max(peak, @abs(x));
    }
    const seconds = @as(f32, @floatFromInt(frames)) / @as(f32, @floatFromInt(i.audio_rate));
    try testing.expect(seconds > 1.1 and seconds < 1.3);
    try testing.expect(peak > 0.05);

    try s.seek(850);
    var last: u64 = 0;
    while (try s.frame(&pixels)) |t| last = t;
    try testing.expectEqual(@as(u64, 1100), last);
}

test "Media Foundation leaves other files to other decoders" {
    try testing.expectEqual(@as(?video.Stream, null), try open(null, testing.allocator, .{ .bytes = "\x89PNG\r\n\x1a\n........" }));
}

test "an MP4 plays through the player, on its thread" {
    video.addDecoder(decoder);
    defer video.removeDecoder(decoder.name);
    const core = zigulee.core;
    const p = video.Player.open(testing.allocator, .{ .bytes = test_mp4 }, .{}) catch |err| switch (err) {
        error.UnsupportedVideo => return error.SkipZigTest, // no Media Foundation
        else => return err,
    };
    defer p.close();
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
        c.Sleep(1);
    }
    try testing.expect(p.finished());
    try testing.expectEqual([3]bool{ true, true, true }, colors);
}
