// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The microphone and the camera through SDL: the default recording
//! device, read from SDL's audio thread, and the first camera, whose frames
//! are fetched on the UI thread (converted to RGBA by SDL). SDL asks the
//! platform for permission (macOS asks the user the first time; a camera
//! refused shows nothing).

const std = @import("std");
const zigulee = @import("zigulee");
const c = @import("sdl3_c");
const audio = zigulee.core.audio;
const camera = zigulee.core.camera;

const log = std.log.scoped(.zigulee_sdl3);

// ---- Microphone ----

pub const Microphone = struct {
    stream: ?*c.SDL_AudioStream = null,
    sink: ?*const audio.Input.Sink = null,
    buffer: [1024]f32 = undefined,

    pub fn input(self: *Microphone) audio.Input {
        return .{ .ctx = self, .vtable = &.{ .start = start, .stop = stop } };
    }

    fn start(ctx: ?*anyopaque, sink: *const audio.Input.Sink) audio.Input.Error!u32 {
        const self: *Microphone = @ptrCast(@alignCast(ctx));
        if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
            log.info("no audio: {s}", .{std.mem.span(c.SDL_GetError())});
            return error.AudioUnavailable;
        }
        var device: c.SDL_AudioSpec = undefined;
        var device_frames: c_int = 0;
        const rate: c_int = if (c.SDL_GetAudioDeviceFormat(c.SDL_AUDIO_DEVICE_DEFAULT_RECORDING, &device, &device_frames) and device.freq > 0) device.freq else 48000;
        const spec: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_F32, .channels = 1, .freq = rate };
        self.sink = sink;
        self.stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_RECORDING, &spec, heard, self) orelse {
            log.info("no microphone: {s}", .{std.mem.span(c.SDL_GetError())});
            c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
            return error.AudioUnavailable;
        };
        if (!c.SDL_ResumeAudioStreamDevice(self.stream)) log.info("cannot start the microphone: {s}", .{std.mem.span(c.SDL_GetError())});
        return @intCast(rate);
    }

    fn stop(ctx: ?*anyopaque) void {
        const self: *Microphone = @ptrCast(@alignCast(ctx));
        // The callback runs under the stream's lock: none runs after this.
        c.SDL_DestroyAudioStream(self.stream);
        self.stream = null;
        self.sink = null;
        c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
    }

    /// SDL's audio thread: `available` bytes were recorded.
    fn heard(userdata: ?*anyopaque, stream: ?*c.SDL_AudioStream, available: c_int, _: c_int) callconv(.c) void {
        const self: *Microphone = @ptrCast(@alignCast(userdata));
        const sink = self.sink orelse return;
        var left: usize = @intCast(@max(available, 0));
        while (left > 0) {
            const want: c_int = @intCast(@min(left, self.buffer.len * @sizeOf(f32)));
            const got = c.SDL_GetAudioStreamData(stream, &self.buffer, want);
            if (got <= 0) return;
            const n: usize = @intCast(got);
            sink.write(sink.ctx, self.buffer[0 .. n / @sizeOf(f32)], 1);
            left -|= n;
        }
    }
};

// ---- Camera ----

pub const Camera = struct {
    device: ?*c.SDL_Camera = null,
    sink: ?*const camera.Provider.Sink = null,
    pixels: std.ArrayList(zigulee.core.Rgba8) = .empty,
    denied: bool = false,

    pub fn provider(self: *Camera) camera.Provider {
        return .{ .ctx = self, .vtable = &.{ .start = start, .stop = stop, .poll = poll } };
    }

    fn start(ctx: ?*anyopaque, sink: *const camera.Provider.Sink) camera.Provider.Error!void {
        const self: *Camera = @ptrCast(@alignCast(ctx));
        if (!c.SDL_InitSubSystem(c.SDL_INIT_CAMERA)) {
            log.info("no camera: {s}", .{std.mem.span(c.SDL_GetError())});
            return error.CameraUnavailable;
        }
        errdefer c.SDL_QuitSubSystem(c.SDL_INIT_CAMERA);
        var count: c_int = 0;
        const ids = c.SDL_GetCameras(&count);
        defer c.SDL_free(ids);
        if (ids == null or count == 0) {
            log.info("no camera found", .{});
            return error.CameraUnavailable;
        }
        self.device = c.SDL_OpenCamera(ids[0], null) orelse {
            log.info("cannot open the camera: {s}", .{std.mem.span(c.SDL_GetError())});
            return error.CameraUnavailable;
        };
        self.sink = sink;
        self.denied = false;
    }

    fn stop(ctx: ?*anyopaque) void {
        const self: *Camera = @ptrCast(@alignCast(ctx));
        c.SDL_CloseCamera(self.device);
        self.device = null;
        self.sink = null;
        self.pixels.deinit(std.heap.c_allocator);
        self.pixels = .empty;
        c.SDL_QuitSubSystem(c.SDL_INIT_CAMERA);
    }

    /// The UI thread: the newest frame, if one came.
    fn poll(ctx: ?*anyopaque) void {
        const self: *Camera = @ptrCast(@alignCast(ctx));
        const device = self.device orelse return;
        const sink = self.sink orelse return;
        if (c.SDL_GetCameraPermissionState(device) < 0) {
            if (!self.denied) log.info("the camera was not allowed", .{});
            self.denied = true;
            return;
        }
        var timestamp: u64 = 0;
        const frame = c.SDL_AcquireCameraFrame(device, &timestamp) orelse return;
        defer c.SDL_ReleaseCameraFrame(device, frame);
        const rgba = c.SDL_ConvertSurface(frame, c.SDL_PIXELFORMAT_RGBA32) orelse return;
        defer c.SDL_DestroySurface(rgba);
        const w: usize = @intCast(rgba.*.w);
        const h: usize = @intCast(rgba.*.h);
        const pitch: usize = @intCast(rgba.*.pitch);
        self.pixels.resize(std.heap.c_allocator, w * h) catch return;
        const src: [*]const u8 = @ptrCast(rgba.*.pixels.?);
        for (0..h) |y| {
            const row = src[y * pitch ..][0 .. w * 4];
            for (self.pixels.items[y * w ..][0..w], 0..) |*p, x| p.* = .{ .r = row[x * 4], .g = row[x * 4 + 1], .b = row[x * 4 + 2], .a = 255 };
        }
        sink.frame(sink.ctx, self.pixels.items, @intCast(w), @intCast(h));
    }
};

// ---- Tests ----

const testing = std.testing;

test "recording from SDL's dummy audio driver" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    _ = c.SDL_SetHint(c.SDL_HINT_AUDIO_DRIVER, "dummy");
    defer _ = c.SDL_ResetHint(c.SDL_HINT_AUDIO_DRIVER);
    var mic: Microphone = .{};
    audio.setInput(mic.input());
    defer audio.setInput(null);
    var el: audio.Microphone = undefined;
    el.init(testing.allocator);
    defer el.deinit();
    try testing.expect(el.available.get());
    el.record();
    try testing.expect(mic.stream != null);
    // The dummy device records silence, in time.
    var t: std.Io.Threaded = .init_single_threaded;
    for (0..200) |_| {
        audio.capture.update();
        if (el.duration_ms.get() >= 50) break;
        t.io().sleep(.fromMilliseconds(5), .awake) catch {};
    }
    el.stop();
    try testing.expect(mic.stream == null);
    try testing.expect(el.recorded.get().frames() > 0);
}
