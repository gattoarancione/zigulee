// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Sound through PipeWire (Linux): the mixer's output, as a playback stream
//! that PipeWire connects to the default output (and moves when the user
//! picks another). libpipewire is loaded at run time: without it, or
//! without a PipeWire server, `Audio` elements are silent. Used by the X11,
//! Wayland and KMS backends.
//!
//! The stream opens the first time something plays. PipeWire calls the
//! mixer from its real-time thread; the format is interleaved stereo 32-bit
//! floats at 48 kHz (PipeWire converts it to the device's).

const std = @import("std");
const zigulee = @import("zigulee");
const audio = zigulee.core.audio;
const c = std.c;

const log = std.log.scoped(.zigulee_pipewire);

const rate = 48000;

// ---- libpipewire ----

const ThreadLoop = opaque {};
const Loop = opaque {};
const Properties = opaque {};
const Stream = opaque {};
const Pod = extern struct { size: u32, type: u32 };

const Chunk = extern struct { offset: u32, size: u32, stride: i32, flags: i32 };
const Data = extern struct {
    type: u32,
    flags: u32,
    fd: i64,
    mapoffset: u32,
    maxsize: u32,
    data: ?*anyopaque,
    chunk: ?*Chunk,
};
const SpaBuffer = extern struct { n_metas: u32, n_datas: u32, metas: ?*anyopaque, datas: ?[*]Data };
const Buffer = extern struct {
    buffer: ?*SpaBuffer,
    user_data: ?*anyopaque,
    size: u64,
    /// Frames wanted (since PipeWire 0.3.49; 0 when unknown).
    requested: u64,
};

const StreamEvents = extern struct {
    version: u32 = 2,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void = null,
    state_changed: ?*const fn (?*anyopaque, old: c_int, state: c_int, err: ?[*:0]const u8) callconv(.c) void = null,
    control_info: ?*const anyopaque = null,
    io_changed: ?*const anyopaque = null,
    param_changed: ?*const anyopaque = null,
    add_buffer: ?*const anyopaque = null,
    remove_buffer: ?*const anyopaque = null,
    process: ?*const fn (?*anyopaque) callconv(.c) void = null,
    drained: ?*const anyopaque = null,
    command: ?*const anyopaque = null,
    trigger_done: ?*const anyopaque = null,
};

const state_error = -1;
const state_connecting = 1;
const state_paused = 2;
const state_streaming = 3;

const direction_output = 1;
const id_any = 0xffffffff;
const flag_autoconnect = 1 << 0;
const flag_map_buffers = 1 << 2;
const flag_rt_process = 1 << 4;

const Fns = struct {
    pw_init: *const fn (?*c_int, ?*anyopaque) callconv(.c) void,
    pw_thread_loop_new: *const fn (name: [*:0]const u8, props: ?*const anyopaque) callconv(.c) ?*ThreadLoop,
    pw_thread_loop_destroy: *const fn (*ThreadLoop) callconv(.c) void,
    pw_thread_loop_get_loop: *const fn (*ThreadLoop) callconv(.c) *Loop,
    pw_thread_loop_start: *const fn (*ThreadLoop) callconv(.c) c_int,
    pw_thread_loop_stop: *const fn (*ThreadLoop) callconv(.c) void,
    pw_thread_loop_lock: *const fn (*ThreadLoop) callconv(.c) void,
    pw_thread_loop_unlock: *const fn (*ThreadLoop) callconv(.c) void,
    pw_thread_loop_signal: *const fn (*ThreadLoop, wait_for_accept: bool) callconv(.c) void,
    pw_thread_loop_timed_wait: *const fn (*ThreadLoop, seconds: c_int) callconv(.c) c_int,
    pw_properties_new_string: *const fn ([*:0]const u8) callconv(.c) ?*Properties,
    pw_stream_new_simple: *const fn (*Loop, name: [*:0]const u8, props: ?*Properties, events: *const StreamEvents, data: ?*anyopaque) callconv(.c) ?*Stream,
    pw_stream_connect: *const fn (*Stream, direction: c_int, target: u32, flags: c_int, params: [*]const *const Pod, n_params: u32) callconv(.c) c_int,
    pw_stream_destroy: *const fn (*Stream) callconv(.c) void,
    pw_stream_dequeue_buffer: *const fn (*Stream) callconv(.c) ?*Buffer,
    pw_stream_queue_buffer: *const fn (*Stream, *Buffer) callconv(.c) c_int,
};

/// libpipewire's functions, or null without it (looked up once).
fn library() ?*const Fns {
    const S = struct {
        var fns: Fns = undefined;
        var tried = false;
        var found = false;
    };
    if (!S.tried) {
        S.tried = true;
        const lib = c.dlopen("libpipewire-0.3.so.0", .{ .LAZY = true }) orelse {
            log.info("libpipewire not found: no sound", .{});
            return null;
        };
        inline for (@typeInfo(Fns).@"struct".fields) |f| {
            @field(S.fns, f.name) = @ptrCast(@alignCast(c.dlsym(lib, f.name ++ "") orelse {
                log.info("libpipewire has no {s}: no sound", .{f.name});
                return null;
            }));
        }
        S.fns.pw_init(null, null);
        S.found = true;
    }
    return if (S.found) &S.fns else null;
}

/// The format offered: an EnumFormat object (as SPA's POD builder would
/// write it): raw audio, F32 (little-endian), 48 kHz, stereo (front left
/// and right).
const format_pod: [42]u32 align(8) = blk: {
    const id = 3; // SPA_TYPE_Id
    const int = 4; // SPA_TYPE_Int
    break :blk .{
        160, 15, // Object (SPA_TYPE_Object), its body's size
        0x40003, 3, // SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat
        1, 0, 4, id, 1, 0, // mediaType: audio
        2, 0, 4, id, 1, 0, // mediaSubtype: raw
        0x10001, 0, 4, id, 0x11b, 0, // AUDIO_format: F32_LE
        0x10003, 0, 4, int, rate, 0, // AUDIO_rate
        0x10004, 0, 4, int, 2, 0, // AUDIO_channels
        0x10005, 0, 16, 13, 4, id, 3, 4, // AUDIO_position: Array of Id: FL, FR
    };
};

// ---- The output ----

pub const Output = struct {
    fns: ?*const Fns = null,
    loop: ?*ThreadLoop = null,
    stream: ?*Stream = null,
    mixer: ?*audio.Mixer = null,
    state: c_int = 0,
    events: StreamEvents = .{ .state_changed = stateChanged, .process = process },

    pub fn output(self: *Output) audio.Output {
        return .{ .ctx = self, .vtable = &.{ .start = start, .stop = stop } };
    }

    fn start(ctx: ?*anyopaque, mixer: *audio.Mixer) audio.Output.Error!u32 {
        const self: *Output = @ptrCast(@alignCast(ctx));
        const fns = library() orelse return error.AudioUnavailable;
        self.fns = fns;
        self.mixer = mixer;
        self.state = 0;
        const loop = fns.pw_thread_loop_new("zigulee-audio", null) orelse return error.AudioUnavailable;
        self.loop = loop;
        if (fns.pw_thread_loop_start(loop) < 0) {
            fns.pw_thread_loop_destroy(loop);
            self.loop = null;
            return error.AudioUnavailable;
        }
        fns.pw_thread_loop_lock(loop);
        const props = fns.pw_properties_new_string("media.type=Audio media.category=Playback media.role=Game node.latency=512/48000");
        const ok = blk: {
            const stream = fns.pw_stream_new_simple(fns.pw_thread_loop_get_loop(loop), "zigulee", props, &self.events, self) orelse break :blk false;
            self.stream = stream;
            const params = [_]*const Pod{@ptrCast(&format_pod)};
            if (fns.pw_stream_connect(stream, direction_output, id_any, flag_autoconnect | flag_map_buffers | flag_rt_process, &params, params.len) < 0) break :blk false;
            // Wait for the server's answer (state_changed signals it).
            while (self.state != state_error and self.state != state_paused and self.state != state_streaming) {
                if (fns.pw_thread_loop_timed_wait(loop, 2) != 0) break;
            }
            break :blk self.state == state_paused or self.state == state_streaming;
        };
        fns.pw_thread_loop_unlock(loop);
        if (!ok) {
            log.info("no PipeWire server to play on: no sound", .{});
            self.close();
            return error.AudioUnavailable;
        }
        return rate;
    }

    fn stop(ctx: ?*anyopaque) void {
        const self: *Output = @ptrCast(@alignCast(ctx));
        self.close();
    }

    /// Destroys the stream (no `process` runs once it is gone) and the
    /// loop.
    fn close(self: *Output) void {
        const fns = self.fns.?;
        const loop = self.loop orelse return;
        fns.pw_thread_loop_lock(loop);
        if (self.stream) |s| fns.pw_stream_destroy(s);
        self.stream = null;
        fns.pw_thread_loop_unlock(loop);
        fns.pw_thread_loop_stop(loop);
        fns.pw_thread_loop_destroy(loop);
        self.loop = null;
    }

    /// PipeWire's loop thread (with the loop locked).
    fn stateChanged(data: ?*anyopaque, _: c_int, state: c_int, err: ?[*:0]const u8) callconv(.c) void {
        const self: *Output = @ptrCast(@alignCast(data));
        self.state = state;
        if (state == state_error) log.info("PipeWire stream error: {s}", .{if (err) |e| std.mem.span(e) else "?"});
        self.fns.?.pw_thread_loop_signal(self.loop.?, false);
    }

    /// PipeWire's real-time thread: fills a buffer.
    fn process(data: ?*anyopaque) callconv(.c) void {
        const self: *Output = @ptrCast(@alignCast(data));
        const fns = self.fns.?;
        const stream = self.stream orelse return;
        const b = fns.pw_stream_dequeue_buffer(stream) orelse return;
        defer _ = fns.pw_stream_queue_buffer(stream, b);
        const spa = b.buffer orelse return;
        if (spa.n_datas < 1) return;
        const d = &spa.datas.?[0];
        const chunk = d.chunk orelse return;
        const bytes = d.data orelse return;
        const stride = 2 * @sizeOf(f32);
        var frames: usize = d.maxsize / stride;
        if (b.requested > 0) frames = @min(frames, b.requested);
        const out: [*]f32 = @ptrCast(@alignCast(bytes));
        self.mixer.?.render(out[0 .. 2 * frames]);
        chunk.offset = 0;
        chunk.stride = stride;
        chunk.size = @intCast(frames * stride);
    }
};

// ---- Tests ----

const testing = std.testing;

test "the format offered is a well-formed POD" {
    // Each property: key, flags, then a POD padded to 8 bytes.
    try testing.expectEqual(@as(usize, 8 + 160), @sizeOf(@TypeOf(format_pod)));
    try testing.expectEqual(@as(u32, 15), format_pod[1]);
    try testing.expectEqual(@as(u32, 0x10005), format_pod[34]);
}

test "the mixer plays through PipeWire (silence)" {
    var out: Output = .{};
    var mixer: audio.Mixer = .{};
    mixer.setOutput(out.output());
    defer mixer.setOutput(null);

    // 50 ms of silence: the whole path, without a sound.
    var data: [2400 * 2]u8 = @splat(0);
    const clip: audio.Clip = .{ .format = .i16, .channels = 1, .sample_rate = 48000, .data = &data };
    const v = mixer.play(&clip, .{}, null) orelse return error.SkipZigTest; // no PipeWire
    try testing.expectEqual(@as(u32, rate), mixer.sample_rate);

    // PipeWire's thread plays it to its end (unless nothing drives the
    // stream: a server without devices).
    var waited: u32 = 0;
    while (mixer.isPlaying(v)) : (waited += 1) {
        if (waited > 200) {
            log.info("PipeWire did not ask for sound in 2 s: no device?", .{});
            return error.SkipZigTest;
        }
        _ = c.nanosleep(&.{ .sec = 0, .nsec = 10 * std.time.ns_per_ms }, null);
    }
    mixer.update();
    try testing.expect(!mixer.busy());

    // A looping voice, stopped: the call returns once PipeWire let it go.
    const w = mixer.play(&clip, .{ .looping = true }, null).?;
    try testing.expect(mixer.isPlaying(w));
    mixer.stop(w);
    try testing.expect(!mixer.isPlaying(w));
}
