// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Sound through WASAPI: the mixer's output, played on the default output
//! device in shared mode. A thread of its own (with COM in its own
//! apartment, apart from the UI thread's) opens the device the first time
//! something plays, then waits for the device to ask for frames and asks
//! the mixer for them.

const std = @import("std");
const zigulee = @import("zigulee");
const c = @import("win32_c");
const audio = zigulee.core.audio;

const log = std.log.scoped(.zigulee_windows);

fn guid(a: u32, b: u16, cc: u16, d: [8]u8) c.GUID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = cc, .Data4 = d };
}

const clsid_enumerator = guid(0xbcde0395, 0xe52f, 0x467c, .{ 0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e });
const iid_enumerator = guid(0xa95664d2, 0x9614, 0x4f35, .{ 0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6 });
const iid_audio_client = guid(0x1cb9ad4c, 0xdbfa, 0x4c32, .{ 0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2 });
const iid_render_client = guid(0xf294acfc, 0x3146, 0x4483, .{ 0xa7, 0xbf, 0xad, 0xdc, 0xa7, 0xc2, 0x60, 0xe2 });
const subtype_float = guid(0x00000003, 0x0000, 0x0010, .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 });

const e_render = 0;
const e_console = 0;
const clsctx_all = 0x17;
const shared_mode = 0;
const stream_flags = 0x00040000 | 0x08000000 | 0x80000000; // event callback, resample to the device (default quality)
const speakers_stereo = 0x1 | 0x2; // front left, front right
/// The device buffer, in 100 ns units: 20 ms.
const buffer_duration = 200_000;

/// Releases a COM object.
fn release(obj: anytype) void {
    if (obj) |o| _ = o.*.lpVtbl.*.Release.?(o);
}

pub const Output = struct {
    mixer: ?*audio.Mixer = null,
    thread: ?std.Thread = null,
    /// Signaled by the device when it needs frames, and by `stop`.
    wake: c.HANDLE = null,
    /// Signaled by the thread once the device is open (or failed to).
    ready: c.HANDLE = null,
    /// The device's rate, or 0 if it could not be opened.
    rate: u32 = 0,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn output(self: *Output) audio.Output {
        return .{ .ctx = self, .vtable = &.{ .start = start, .stop = stop } };
    }

    fn start(ctx: ?*anyopaque, mixer: *audio.Mixer) audio.Output.Error!u32 {
        const self: *Output = @ptrCast(@alignCast(ctx));
        self.mixer = mixer;
        self.rate = 0;
        self.stopping.store(false, .release);
        self.wake = c.CreateEventW(null, c.FALSE, c.FALSE, null);
        self.ready = c.CreateEventW(null, c.FALSE, c.FALSE, null);
        if (self.wake == null or self.ready == null) {
            self.closeEvents();
            return error.AudioUnavailable;
        }
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            self.closeEvents();
            return error.AudioUnavailable;
        };
        _ = c.WaitForSingleObject(self.ready, c.INFINITE);
        if (self.rate == 0) {
            // It failed and returned.
            self.thread.?.join();
            self.thread = null;
            self.closeEvents();
            return error.AudioUnavailable;
        }
        return self.rate;
    }

    fn stop(ctx: ?*anyopaque) void {
        const self: *Output = @ptrCast(@alignCast(ctx));
        self.stopping.store(true, .release);
        _ = c.SetEvent(self.wake);
        // Once the thread is gone, nothing calls the mixer.
        if (self.thread) |t| t.join();
        self.thread = null;
        self.closeEvents();
    }

    fn closeEvents(self: *Output) void {
        if (self.wake != null) _ = c.CloseHandle(self.wake);
        if (self.ready != null) _ = c.CloseHandle(self.ready);
        self.wake = null;
        self.ready = null;
    }

    /// The audio thread: opens the device, then feeds it until `stop`.
    fn run(self: *Output) void {
        const com = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
        defer if (com >= 0) c.CoUninitialize();
        var task: u32 = 0;
        const mmcss = c.AvSetMmThreadCharacteristicsW(std.unicode.utf8ToUtf16LeStringLiteral("Pro Audio"), &task);
        defer if (mmcss != null) {
            _ = c.AvRevertMmThreadCharacteristics(mmcss);
        };

        var enumerator: ?*c.IMMDeviceEnumerator = null;
        var device: ?*c.IMMDevice = null;
        var client: ?*c.IAudioClient = null;
        var render: ?*c.IAudioRenderClient = null;
        defer {
            release(render);
            release(client);
            release(device);
            release(enumerator);
        }
        const frames = self.open(&enumerator, &device, &client, &render) catch |err| {
            log.info("no audio: {t}", .{err});
            _ = c.SetEvent(self.ready);
            return;
        };
        const cl = client.?;
        _ = c.SetEvent(self.ready);
        defer _ = cl.*.lpVtbl.*.Stop.?(cl);

        while (!self.stopping.load(.acquire)) {
            _ = c.WaitForSingleObject(self.wake, 200);
            if (self.stopping.load(.acquire)) break;
            if (!self.feed(cl, render.?, frames)) {
                // The device is gone (unplugged, say): keep the mixer
                // going at its pace, silently, so voices still end.
                var scratch: [2 * 480]f32 = undefined;
                self.mixer.?.render(scratch[0 .. 2 * @min(480, self.rate / 100)]);
                c.Sleep(10);
            }
        }
    }

    const OpenError = error{ NoDevice, InitializeFailed, NoRenderClient, StartFailed };

    /// Opens the default device; returns its buffer's size in frames.
    fn open(self: *Output, enumerator: *?*c.IMMDeviceEnumerator, device: *?*c.IMMDevice, client: *?*c.IAudioClient, render: *?*c.IAudioRenderClient) OpenError!u32 {
        if (c.CoCreateInstance(&clsid_enumerator, null, clsctx_all, &iid_enumerator, @ptrCast(enumerator)) < 0) return error.NoDevice;
        const en = enumerator.*.?;
        if (en.*.lpVtbl.*.GetDefaultAudioEndpoint.?(en, e_render, e_console, device) < 0) return error.NoDevice;
        const dev = device.*.?;
        if (dev.*.lpVtbl.*.Activate.?(dev, &iid_audio_client, clsctx_all, null, @ptrCast(client)) < 0) return error.NoDevice;
        const cl = client.*.?;

        // The device's rate (the shared mode mix), so it does not resample
        // the mix again.
        var mix: ?*c.WAVEFORMATEX = null;
        var rate: u32 = 48000;
        if (cl.*.lpVtbl.*.GetMixFormat.?(cl, &mix) >= 0) {
            if (mix) |m| rate = m.nSamplesPerSec;
            c.CoTaskMemFree(mix);
        }
        // What the mixer gives: interleaved stereo 32-bit floats.
        var format = std.mem.zeroes(c.WAVEFORMATEXTENSIBLE);
        format.Format.wFormatTag = c.WAVE_FORMAT_EXTENSIBLE;
        format.Format.nChannels = 2;
        format.Format.nSamplesPerSec = rate;
        format.Format.wBitsPerSample = 32;
        format.Format.nBlockAlign = 2 * @sizeOf(f32);
        format.Format.nAvgBytesPerSec = rate * 2 * @sizeOf(f32);
        format.Format.cbSize = @sizeOf(c.WAVEFORMATEXTENSIBLE) - @sizeOf(c.WAVEFORMATEX);
        format.Samples.wValidBitsPerSample = 32;
        format.dwChannelMask = speakers_stereo;
        format.SubFormat = subtype_float;
        if (cl.*.lpVtbl.*.Initialize.?(cl, shared_mode, stream_flags, buffer_duration, 0, @ptrCast(&format), null) < 0) return error.InitializeFailed;
        if (cl.*.lpVtbl.*.SetEventHandle.?(cl, self.wake) < 0) return error.InitializeFailed;
        var frames: u32 = 0;
        if (cl.*.lpVtbl.*.GetBufferSize.?(cl, &frames) < 0) return error.InitializeFailed;
        if (cl.*.lpVtbl.*.GetService.?(cl, &iid_render_client, @ptrCast(render)) < 0) return error.NoRenderClient;

        self.rate = rate;
        // A first buffer before starting: no glitch at the start.
        _ = self.feed(cl, render.*.?, frames);
        if (cl.*.lpVtbl.*.Start.?(cl) < 0) {
            self.rate = 0;
            return error.StartFailed;
        }
        return frames;
    }

    /// Fills the part of the device's buffer it has played; false if the
    /// device is no longer usable.
    fn feed(self: *Output, cl: *c.IAudioClient, render: *c.IAudioRenderClient, frames: u32) bool {
        var padding: u32 = 0;
        if (cl.*.lpVtbl.*.GetCurrentPadding.?(cl, &padding) < 0) return false;
        const free = frames -| padding;
        if (free == 0) return true;
        var data: [*c]u8 = null;
        if (render.*.lpVtbl.*.GetBuffer.?(render, free, &data) < 0 or data == null) return false;
        const out: [*]f32 = @ptrCast(@alignCast(data));
        self.mixer.?.render(out[0 .. 2 * @as(usize, free)]);
        return render.*.lpVtbl.*.ReleaseBuffer.?(render, free, 0) >= 0;
    }
};

// ---- Tests ----

const testing = std.testing;

test "the mixer plays through WASAPI (silence)" {
    var out: Output = .{};
    var mixer: audio.Mixer = .{};
    mixer.setOutput(out.output());
    defer mixer.setOutput(null);

    // 50 ms of silence: the whole path, without a sound.
    var data: [2400 * 2]u8 = @splat(0);
    const clip: audio.Clip = .{ .format = .i16, .channels = 1, .sample_rate = 48000, .data = &data };
    const v = mixer.play(&clip, .{}, null) orelse return error.SkipZigTest; // no audio device
    try testing.expect(mixer.sample_rate >= 8000);

    // The audio thread plays it to its end.
    var waited: u32 = 0;
    while (mixer.isPlaying(v)) : (waited += 1) {
        if (waited > 200) return error.TestUnexpectedResult; // 2 s
        c.Sleep(10);
    }
    mixer.update();
    try testing.expect(!mixer.busy());

    // A looping voice, stopped: the call returns once the thread let it go.
    const w = mixer.play(&clip, .{ .looping = true }, null).?;
    try testing.expect(mixer.isPlaying(w));
    mixer.stop(w);
    try testing.expect(!mixer.isPlaying(w));
}
