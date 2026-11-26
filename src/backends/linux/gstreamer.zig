// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Video decoding with GStreamer (Linux): whatever the installed plugins
//! play (MP4, WebM, Matroska, Ogg, AVI, ...; H.264 needs gst-libav or
//! another decoder plugin). libgstreamer is loaded at run time: without
//! it, only animated PNG plays. Used by the X11, Wayland and KMS backends.
//!
//! Two pipelines read the file, one for the picture and one for the sound
//! (a video without sound would otherwise stall), each ending in an appsink
//! the player's thread pulls from: frames as RGBA, sound as 48 kHz stereo
//! floats. An embedded video is read from an in-memory file.

const std = @import("std");
const builtin = @import("builtin");
const zigulee = @import("zigulee");
const video = zigulee.core.video;
const Rgba8 = zigulee.core.Rgba8;
const c = std.c;

const log = std.log.scoped(.zigulee_gstreamer);

pub const decoder: video.Decoder = .{ .name = "gstreamer", .open = open };

const audio_rate = 48000;

// ---- libgstreamer ----

const Element = opaque {};
const Sample = opaque {};
const Caps = opaque {};
const Structure = opaque {};
const GError = extern struct { domain: u32, code: c_int, message: ?[*:0]const u8 };

const MiniObject = extern struct {
    type: usize,
    refcount: c_int,
    lockstate: c_int,
    flags: c_uint,
    copy: ?*anyopaque,
    dispose: ?*anyopaque,
    free: ?*anyopaque,
    priv_uint: c_uint,
    priv_pointer: ?*anyopaque,
};
const Buffer = extern struct {
    mini_object: MiniObject,
    pool: ?*anyopaque,
    pts: u64,
    dts: u64,
    duration: u64,
    offset: u64,
    offset_end: u64,
};
const MapInfo = extern struct {
    memory: ?*anyopaque = null,
    flags: c_uint = 0,
    data: ?[*]const u8 = null,
    size: usize = 0,
    maxsize: usize = 0,
    user_data: [4]?*anyopaque = @splat(null),
    reserved: [4]?*anyopaque = @splat(null),
};

const state_null = 1;
const state_paused = 3;
const state_playing = 4;
const change_failure = 0;
const format_time = 3;
const seek_flush_accurate = 1 | 2;
const map_read = 1;
const clock_time_none = std.math.maxInt(u64);
const second = 1_000_000_000;

const Fns = struct {
    gst_init: *const fn (?*c_int, ?*anyopaque) callconv(.c) void,
    gst_parse_launch: *const fn ([*:0]const u8, *?*GError) callconv(.c) ?*Element,
    gst_bin_get_by_name: *const fn (*Element, [*:0]const u8) callconv(.c) ?*Element,
    gst_element_set_state: *const fn (*Element, c_int) callconv(.c) c_int,
    gst_element_get_state: *const fn (*Element, ?*c_int, ?*c_int, timeout: u64) callconv(.c) c_int,
    gst_element_query_duration: *const fn (*Element, c_int, *i64) callconv(.c) c_int,
    gst_element_seek_simple: *const fn (*Element, c_int, c_int, i64) callconv(.c) c_int,
    gst_object_unref: *const fn (*anyopaque) callconv(.c) void,
    gst_sample_get_buffer: *const fn (*Sample) callconv(.c) ?*Buffer,
    gst_sample_get_caps: *const fn (*Sample) callconv(.c) ?*Caps,
    gst_caps_get_structure: *const fn (*Caps, c_uint) callconv(.c) ?*Structure,
    gst_structure_get_int: *const fn (*Structure, [*:0]const u8, *c_int) callconv(.c) c_int,
    gst_buffer_map: *const fn (*Buffer, *MapInfo, c_int) callconv(.c) c_int,
    gst_buffer_unmap: *const fn (*Buffer, *MapInfo) callconv(.c) void,
    gst_mini_object_unref: *const fn (*anyopaque) callconv(.c) void,
    g_error_free: *const fn (*GError) callconv(.c) void,
};
const AppFns = struct {
    gst_app_sink_try_pull_sample: *const fn (*Element, timeout: u64) callconv(.c) ?*Sample,
    gst_app_sink_is_eos: *const fn (*Element) callconv(.c) c_int,
};

const Library = struct { gst: Fns, app: AppFns };

fn load(comptime T: type, lib: *anyopaque) ?T {
    var fns: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        @field(fns, f.name) = @ptrCast(@alignCast(c.dlsym(lib, f.name ++ "") orelse {
            log.info("GStreamer has no {s}: no video", .{f.name});
            return null;
        }));
    }
    return fns;
}

/// libgstreamer's functions, or null without it (looked up once).
fn library() ?*const Library {
    const S = struct {
        var lib: Library = undefined;
        var tried = false;
        var found = false;
    };
    if (!S.tried) {
        S.tried = true;
        const gst = c.dlopen("libgstreamer-1.0.so.0", .{ .LAZY = true }) orelse {
            log.info("libgstreamer not found: only animated PNG plays", .{});
            return null;
        };
        const app = c.dlopen("libgstapp-1.0.so.0", .{ .LAZY = true }) orelse {
            log.info("libgstapp not found: only animated PNG plays", .{});
            return null;
        };
        S.lib = .{ .gst = load(Fns, gst) orelse return null, .app = load(AppFns, app) orelse return null };
        S.lib.gst.gst_init(null, null);
        S.found = true;
    }
    return if (S.found) &S.lib else null;
}

/// `memfd_create` as a system call: glibc only has it from 2.27, and
/// older systems (2.25 on some ARM boards) are targets too.
fn memfdCreate(name: [*:0]const u8, flags: u32) c_int {
    const rc = std.os.linux.memfd_create(name, flags);
    return if (std.os.linux.errno(rc) == .SUCCESS) @intCast(rc) else -1;
}

// ---- The decoder ----

/// A pipeline ending in an appsink.
const Pipeline = struct {
    pipeline: *Element,
    sink: *Element,

    fn close(p: Pipeline, gst: *const Fns) void {
        _ = gst.gst_element_set_state(p.pipeline, state_null);
        gst.gst_object_unref(p.sink);
        gst.gst_object_unref(p.pipeline);
    }
};

/// `filesrc location=path ! decodebin ! <tail> ! appsink`, prerolled and
/// playing; null if it does not (no such stream, no plugin).
fn pipeline(lib: *const Library, gpa: std.mem.Allocator, path: []const u8, tail: []const u8) ?Pipeline {
    const gst = &lib.gst;
    var desc: std.ArrayList(u8) = .empty;
    defer desc.deinit(gpa);
    desc.appendSlice(gpa, "filesrc location=\"") catch return null;
    for (path) |ch| {
        if (ch == '"' or ch == '\\') desc.append(gpa, '\\') catch return null;
        desc.append(gpa, ch) catch return null;
    }
    desc.print(gpa, "\" ! decodebin ! {s} ! appsink name=sink sync=false max-buffers=4\x00", .{tail}) catch return null;
    var err: ?*GError = null;
    const p = gst.gst_parse_launch(@ptrCast(desc.items.ptr), &err);
    if (err) |e| {
        log.info("GStreamer: {s}", .{if (e.message) |m| std.mem.span(m) else "?"});
        gst.g_error_free(e);
        if (p) |el| gst.gst_object_unref(el);
        return null;
    }
    const pl = p orelse return null;
    const sink = gst.gst_bin_get_by_name(pl, "sink") orelse {
        gst.gst_object_unref(pl);
        return null;
    };
    const result: Pipeline = .{ .pipeline = pl, .sink = sink };
    if (gst.gst_element_set_state(pl, state_paused) == change_failure or
        gst.gst_element_get_state(pl, null, null, 5 * second) == change_failure or
        gst.gst_element_set_state(pl, state_playing) == change_failure)
    {
        result.close(gst);
        return null;
    }
    return result;
}

const Reader = struct {
    gpa: std.mem.Allocator,
    lib: *const Library,
    pictures: Pipeline,
    sounds: ?Pipeline,
    info: video.Info,
    /// The in-memory file of an embedded video.
    memfd: c_int = -1,
    /// A frame pulled ahead (the first, to know the size).
    pending: ?*Sample = null,
    /// Sound pulled and not handed over yet.
    sound: std.ArrayList(f32) = .empty,
    sound_used: usize = 0,

    fn pull(r: *Reader, sink: *Element) ?*Sample {
        while (true) {
            if (r.lib.app.gst_app_sink_try_pull_sample(sink, second)) |s| return s;
            if (r.lib.app.gst_app_sink_is_eos(sink) != 0) return null;
        }
    }
};

fn open(_: ?*anyopaque, gpa: std.mem.Allocator, source: video.Source) video.Error!?video.Stream {
    // Embedded videos are read from an in-memory file: Linux only (the
    // KMS backend also builds elsewhere).
    if (source.bytes.len > 0 and (!looksLikeVideo(source.bytes) or builtin.os.tag != .linux)) return null;
    const lib = library() orelse return null;
    const gst = &lib.gst;

    var memfd: c_int = -1;
    errdefer if (memfd >= 0) {
        _ = c.close(memfd);
    };
    var proc_path: [32]u8 = undefined;
    const path: []const u8 = if (source.bytes.len > 0) blk: {
        memfd = if (builtin.os.tag == .linux) memfdCreate("zigulee-video", 0) else -1;
        if (memfd < 0) return error.ReadFailed;
        var at: usize = 0;
        while (at < source.bytes.len) {
            const n = c.write(memfd, source.bytes[at..].ptr, source.bytes.len - at);
            if (n <= 0) return error.ReadFailed;
            at += @intCast(n);
        }
        break :blk std.fmt.bufPrint(&proc_path, "/proc/self/fd/{d}", .{memfd}) catch unreachable;
    } else source.path;

    const pictures = pipeline(lib, gpa, path, "videoconvert ! video/x-raw,format=RGBA") orelse {
        // Not a video GStreamer plays: another decoder's.
        if (memfd >= 0) _ = c.close(memfd);
        memfd = -1;
        return null;
    };
    errdefer pictures.close(gst);
    const sounds = pipeline(lib, gpa, path, std.fmt.comptimePrint("audioconvert ! audioresample ! audio/x-raw,format=F32LE,layout=interleaved,channels=2,rate={d}", .{audio_rate}));
    errdefer if (sounds) |s| s.close(gst);

    const r = try gpa.create(Reader);
    errdefer gpa.destroy(r);
    r.* = .{
        .gpa = gpa,
        .lib = lib,
        .pictures = pictures,
        .sounds = sounds,
        .info = .{ .width = 0, .height = 0, .audio_rate = if (sounds != null) audio_rate else 0 },
        .memfd = memfd,
    };
    var duration: i64 = 0;
    if (gst.gst_element_query_duration(pictures.pipeline, format_time, &duration) != 0 and duration > 0)
        r.info.duration_ms = @intCast(@divTrunc(duration, 1_000_000));

    // The first frame gives the size.
    const first = r.pull(pictures.sink) orelse return error.InvalidVideo;
    r.pending = first;
    const caps = gst.gst_sample_get_caps(first) orelse return error.InvalidVideo;
    const s = gst.gst_caps_get_structure(caps, 0) orelse return error.InvalidVideo;
    var w: c_int = 0;
    var h: c_int = 0;
    if (gst.gst_structure_get_int(s, "width", &w) == 0 or gst.gst_structure_get_int(s, "height", &h) == 0 or w <= 0 or h <= 0) return error.InvalidVideo;
    r.info.width = @intCast(w);
    r.info.height = @intCast(h);
    memfd = -1; // the reader has it
    return .{ .ctx = r, .vtable = &.{ .info = info, .frame = frame, .audio = audio, .seek = seek, .close = close } };
}

/// MP4/QuickTime, AVI, WebM/Matroska, Ogg or ASF.
fn looksLikeVideo(b: []const u8) bool {
    if (b.len < 16) return false;
    return std.mem.eql(u8, b[4..8], "ftyp") or
        (std.mem.eql(u8, b[0..4], "RIFF") and std.mem.eql(u8, b[8..12], "AVI ")) or
        std.mem.eql(u8, b[0..4], "\x1a\x45\xdf\xa3") or
        std.mem.eql(u8, b[0..4], "OggS") or
        std.mem.eql(u8, b[0..4], "\x30\x26\xb2\x75");
}

fn info(ctx: *anyopaque) video.Info {
    const r: *Reader = @ptrCast(@alignCast(ctx));
    return r.info;
}

fn frame(ctx: *anyopaque, pixels: []Rgba8) video.Error!?u64 {
    const r: *Reader = @ptrCast(@alignCast(ctx));
    const gst = &r.lib.gst;
    const sample = if (r.pending) |p| p else r.pull(r.pictures.sink) orelse return null;
    r.pending = null;
    defer gst.gst_mini_object_unref(sample);
    const buffer = gst.gst_sample_get_buffer(sample) orelse return 0;
    const ms: u64 = if (buffer.pts == clock_time_none) 0 else buffer.pts / 1_000_000;
    var map: MapInfo = .{};
    if (gst.gst_buffer_map(buffer, &map, map_read) == 0) return ms;
    defer gst.gst_buffer_unmap(buffer, &map);
    const data = map.data orelse return ms;
    const n = @min(pixels.len, map.size / 4);
    // RGBA rows, 4-byte aligned: tightly packed.
    for (pixels[0..n], 0..) |*p, i| p.* = .{ .r = data[4 * i], .g = data[4 * i + 1], .b = data[4 * i + 2], .a = data[4 * i + 3] };
    return ms;
}

fn audio(ctx: *anyopaque, out: []f32) video.Error!usize {
    const r: *Reader = @ptrCast(@alignCast(ctx));
    const gst = &r.lib.gst;
    if (r.sound_used >= r.sound.items.len) {
        const sounds = r.sounds orelse return 0;
        const sample = r.pull(sounds.sink) orelse return 0;
        defer gst.gst_mini_object_unref(sample);
        const buffer = gst.gst_sample_get_buffer(sample) orelse return 0;
        var map: MapInfo = .{};
        if (gst.gst_buffer_map(buffer, &map, map_read) == 0) return 0;
        defer gst.gst_buffer_unmap(buffer, &map);
        r.sound.clearRetainingCapacity();
        r.sound_used = 0;
        try r.sound.resize(r.gpa, map.size / @sizeOf(f32));
        @memcpy(std.mem.sliceAsBytes(r.sound.items), map.data.?[0 .. r.sound.items.len * @sizeOf(f32)]);
    }
    const n = @min(out.len, r.sound.items.len - r.sound_used) / 2 * 2;
    @memcpy(out[0..n], r.sound.items[r.sound_used..][0..n]);
    r.sound_used += n;
    return n / 2;
}

fn seek(ctx: *anyopaque, ms: u64) video.Error!void {
    const r: *Reader = @ptrCast(@alignCast(ctx));
    const gst = &r.lib.gst;
    if (r.pending) |p| gst.gst_mini_object_unref(p);
    r.pending = null;
    r.sound.clearRetainingCapacity();
    r.sound_used = 0;
    const at: i64 = @intCast(ms * 1_000_000);
    if (gst.gst_element_seek_simple(r.pictures.pipeline, format_time, seek_flush_accurate, at) == 0) return error.InvalidVideo;
    if (r.sounds) |s| _ = gst.gst_element_seek_simple(s.pipeline, format_time, seek_flush_accurate, at);
}

fn close(ctx: *anyopaque) void {
    const r: *Reader = @ptrCast(@alignCast(ctx));
    const gst = &r.lib.gst;
    if (r.pending) |p| gst.gst_mini_object_unref(p);
    r.pictures.close(gst);
    if (r.sounds) |s| s.close(gst);
    if (r.memfd >= 0) _ = c.close(r.memfd);
    r.sound.deinit(r.gpa);
    r.gpa.destroy(r);
}

// ---- Tests ----

const testing = std.testing;
const test_mp4 = @embedFile("test_mp4");

test "GStreamer decodes an MP4: frames in time, and the soundtrack" {
    // Needs GStreamer with an MP4 demuxer and an H.264 and AAC decoder.
    const s = (try open(null, testing.allocator, .{ .bytes = test_mp4 })) orelse return error.SkipZigTest;
    defer s.close();
    const i = s.info();
    try testing.expectEqual(@as(u32, 64), i.width);
    try testing.expectEqual(@as(u32, 32), i.height);
    try testing.expectEqual(@as(u64, 1200), i.duration_ms);

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

    if (i.audio_rate > 0) {
        var sound: [2048]f32 = undefined;
        var frames: usize = 0;
        while (true) {
            const got = try s.audio(&sound);
            if (got == 0) break;
            frames += got;
        }
        try testing.expect(frames > 55000 and frames < 60000);
    }

    try s.seek(850);
    const t = (try s.frame(&pixels)).?;
    try testing.expect(t >= 800 and t <= 900);
    try testing.expect(pixels[0].b > 200);
}

test "GStreamer leaves other files to other decoders" {
    try testing.expectEqual(@as(?video.Stream, null), try open(null, testing.allocator, .{ .bytes = "\x89PNG\r\n\x1a\n........" }));
}
