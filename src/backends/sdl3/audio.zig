// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Sound through SDL: the mixer's output, played on the default audio
//! device. SDL's audio subsystem starts the first time something plays
//! (programs without sound never open a device), and the device asks the
//! mixer for frames from SDL's audio thread.

const std = @import("std");
const zigulee = @import("zigulee");
const c = @import("sdl3_c");
const audio = zigulee.core.audio;

const log = std.log.scoped(.zigulee_sdl3);

pub const Output = struct {
    stream: ?*c.SDL_AudioStream = null,
    mixer: ?*audio.Mixer = null,
    /// Frames mixed for SDL (interleaved stereo).
    buffer: [2 * 512]f32 = undefined,

    pub fn output(self: *Output) audio.Output {
        return .{ .ctx = self, .vtable = &.{ .start = start, .stop = stop } };
    }

    fn start(ctx: ?*anyopaque, mixer: *audio.Mixer) audio.Output.Error!u32 {
        const self: *Output = @ptrCast(@alignCast(ctx));
        if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
            log.info("no audio: {s}", .{std.mem.span(c.SDL_GetError())});
            return error.AudioUnavailable;
        }
        // The device's own rate, so SDL does not resample the mix again.
        var device: c.SDL_AudioSpec = undefined;
        var device_frames: c_int = 0;
        const rate: c_int = if (c.SDL_GetAudioDeviceFormat(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &device, &device_frames) and device.freq > 0) device.freq else 48000;
        const spec: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_F32, .channels = 2, .freq = rate };
        self.mixer = mixer;
        self.stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, feed, self) orelse {
            log.info("no audio device: {s}", .{std.mem.span(c.SDL_GetError())});
            c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
            return error.AudioUnavailable;
        };
        if (!c.SDL_ResumeAudioStreamDevice(self.stream)) log.info("cannot start the audio device: {s}", .{std.mem.span(c.SDL_GetError())});
        const driver = c.SDL_GetCurrentAudioDriver();
        log.debug("audio: {s} at {d} Hz", .{ if (driver != null) std.mem.span(driver) else "?", rate });
        return @intCast(rate);
    }

    fn stop(ctx: ?*anyopaque) void {
        const self: *Output = @ptrCast(@alignCast(ctx));
        // Closes the device; the callback runs under the stream's lock, so
        // none runs once this returns.
        c.SDL_DestroyAudioStream(self.stream);
        self.stream = null;
        c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
    }

    /// SDL's audio thread: the device needs `additional` more bytes.
    fn feed(userdata: ?*anyopaque, stream: ?*c.SDL_AudioStream, additional: c_int, _: c_int) callconv(.c) void {
        const self: *Output = @ptrCast(@alignCast(userdata));
        var left: usize = @intCast(@max(additional, 0));
        while (left > 0) {
            const frames: usize = @min(left / (2 * @sizeOf(f32)) + @intFromBool(left % (2 * @sizeOf(f32)) != 0), self.buffer.len / 2);
            const out = self.buffer[0 .. 2 * frames];
            self.mixer.?.render(out);
            const bytes = out.len * @sizeOf(f32);
            _ = c.SDL_PutAudioStreamData(stream, out.ptr, @intCast(bytes));
            left -|= bytes;
        }
    }
};

// ---- Tests ----

const testing = std.testing;

test "the mixer plays through SDL's dummy audio driver" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    _ = c.SDL_SetHint(c.SDL_HINT_AUDIO_DRIVER, "dummy");
    defer _ = c.SDL_ResetHint(c.SDL_HINT_AUDIO_DRIVER);
    var out: Output = .{};
    var mixer: audio.Mixer = .{};
    mixer.setOutput(out.output());
    defer mixer.setOutput(null);

    // 50 ms of sound.
    var samples: [2400]i16 = @splat(1000);
    const wav = try audio.wav.encode16(testing.allocator, &samples, 1, 48000);
    defer testing.allocator.free(wav);
    const clip = try audio.wav.decode(wav);
    const v = mixer.play(&clip, .{}, null) orelse return error.SkipZigTest; // no audio at all
    try testing.expect(out.stream != null);
    try testing.expect(mixer.sample_rate > 0);

    // SDL's audio thread plays it to its end.
    var waited: u32 = 0;
    while (mixer.isPlaying(v)) : (waited += 1) {
        if (waited > 200) return error.TestUnexpectedResult; // 2 s
        c.SDL_Delay(10);
    }
    mixer.update();
    try testing.expect(!mixer.busy());

    // A looping voice, stopped: the call returns once SDL's thread let it go.
    const w = mixer.play(&clip, .{ .looping = true }, null).?;
    c.SDL_Delay(20);
    try testing.expect(mixer.isPlaying(w));
    mixer.stop(w);
    try testing.expect(!mixer.isPlaying(w));
}
