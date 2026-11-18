// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Sound through CoreAudio: the mixer's output, played by the default
//! output Audio Unit on macOS (which follows the system's choice of
//! device), the remote I/O one on iOS. The
//! unit opens the first time something plays (programs without sound never
//! start it), and calls the mixer from CoreAudio's real-time thread.

const std = @import("std");
const builtin = @import("builtin");
const zigulee = @import("zigulee");
const audio = zigulee.core.audio;

const log = std.log.scoped(.zigulee_apple);

// ---- AudioToolbox ----

const OSStatus = i32;
const AudioComponent = ?*opaque {};
const AudioUnit = ?*opaque {};

const AudioComponentDescription = extern struct {
    componentType: u32,
    componentSubType: u32,
    componentManufacturer: u32,
    componentFlags: u32 = 0,
    componentFlagsMask: u32 = 0,
};

const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32 = 0,
};

const AudioBuffer = extern struct {
    mNumberChannels: u32,
    mDataByteSize: u32,
    mData: ?*anyopaque,
};

const AudioBufferList = extern struct {
    mNumberBuffers: u32,
    mBuffers: [1]AudioBuffer,
};

const RenderCallback = *const fn (ref: ?*anyopaque, flags: *u32, time: ?*const anyopaque, bus: u32, frames: u32, data: ?*AudioBufferList) callconv(.c) OSStatus;

const AURenderCallbackStruct = extern struct {
    inputProc: RenderCallback,
    inputProcRefCon: ?*anyopaque,
};

extern "c" fn AudioComponentFindNext(component: AudioComponent, desc: *const AudioComponentDescription) AudioComponent;
extern "c" fn AudioComponentInstanceNew(component: AudioComponent, out: *AudioUnit) OSStatus;
extern "c" fn AudioComponentInstanceDispose(unit: AudioUnit) OSStatus;
extern "c" fn AudioUnitSetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: ?*const anyopaque, size: u32) OSStatus;
extern "c" fn AudioUnitGetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: ?*anyopaque, size: *u32) OSStatus;
extern "c" fn AudioUnitInitialize(unit: AudioUnit) OSStatus;
extern "c" fn AudioUnitUninitialize(unit: AudioUnit) OSStatus;
extern "c" fn AudioOutputUnitStart(unit: AudioUnit) OSStatus;
extern "c" fn AudioOutputUnitStop(unit: AudioUnit) OSStatus;

fn fourCc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

const kAudioUnitType_Output = fourCc("auou");
const kAudioUnitSubType_DefaultOutput = fourCc("def ");
const kAudioUnitSubType_RemoteIO = fourCc("rioc");
const output_subtype = if (builtin.os.tag == .macos) kAudioUnitSubType_DefaultOutput else kAudioUnitSubType_RemoteIO;
const kAudioUnitManufacturer_Apple = fourCc("appl");
const kAudioFormatLinearPCM = fourCc("lpcm");
const kAudioFormatFlagIsFloat = 1 << 0;
const kAudioFormatFlagIsPacked = 1 << 3;
const kAudioUnitProperty_StreamFormat = 8;
const kAudioUnitProperty_SetRenderCallback = 23;
const kAudioUnitScope_Input = 1;
const kAudioUnitScope_Output = 2;

// ---- The output ----

pub const Output = struct {
    unit: AudioUnit = null,
    mixer: ?*audio.Mixer = null,

    pub fn output(self: *Output) audio.Output {
        return .{ .ctx = self, .vtable = &.{ .start = start, .stop = stop } };
    }

    fn start(ctx: ?*anyopaque, mixer: *audio.Mixer) audio.Output.Error!u32 {
        const self: *Output = @ptrCast(@alignCast(ctx));
        const desc: AudioComponentDescription = .{
            .componentType = kAudioUnitType_Output,
            .componentSubType = output_subtype,
            .componentManufacturer = kAudioUnitManufacturer_Apple,
        };
        const component = AudioComponentFindNext(null, &desc) orelse return unavailable("no output unit", 0);
        var unit: AudioUnit = null;
        var status = AudioComponentInstanceNew(component, &unit);
        if (status != 0) return unavailable("AudioComponentInstanceNew", status);
        errdefer _ = AudioComponentInstanceDispose(unit);

        // The device's rate (the unit's output side), so CoreAudio does not
        // resample the mix again.
        var device: AudioStreamBasicDescription = undefined;
        var size: u32 = @sizeOf(AudioStreamBasicDescription);
        const rate: f64 = if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &device, &size) == 0 and device.mSampleRate >= 8000) device.mSampleRate else 48000;

        // What the mixer gives: interleaved stereo 32-bit floats.
        const format: AudioStreamBasicDescription = .{
            .mSampleRate = rate,
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            .mBytesPerPacket = 2 * @sizeOf(f32),
            .mFramesPerPacket = 1,
            .mBytesPerFrame = 2 * @sizeOf(f32),
            .mChannelsPerFrame = 2,
            .mBitsPerChannel = 32,
        };
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, @sizeOf(AudioStreamBasicDescription));
        if (status != 0) return unavailable("setting the stream format", status);
        const callback: AURenderCallbackStruct = .{ .inputProc = render, .inputProcRefCon = self };
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, @sizeOf(AURenderCallbackStruct));
        if (status != 0) return unavailable("setting the render callback", status);

        self.mixer = mixer;
        status = AudioUnitInitialize(unit);
        if (status != 0) return unavailable("AudioUnitInitialize", status);
        status = AudioOutputUnitStart(unit);
        if (status != 0) {
            _ = AudioUnitUninitialize(unit);
            return unavailable("AudioOutputUnitStart", status);
        }
        self.unit = unit;
        return @intFromFloat(rate);
    }

    fn unavailable(what: []const u8, status: OSStatus) error{AudioUnavailable} {
        log.info("no audio: {s} failed ({d})", .{ what, status });
        return error.AudioUnavailable;
    }

    fn stop(ctx: ?*anyopaque) void {
        const self: *Output = @ptrCast(@alignCast(ctx));
        // Stopping waits for a render in progress: none runs afterwards.
        _ = AudioOutputUnitStop(self.unit);
        _ = AudioUnitUninitialize(self.unit);
        _ = AudioComponentInstanceDispose(self.unit);
        self.unit = null;
    }

    /// CoreAudio's thread: fills the device's buffer.
    fn render(ref: ?*anyopaque, _: *u32, _: ?*const anyopaque, _: u32, frames: u32, data: ?*AudioBufferList) callconv(.c) OSStatus {
        const self: *Output = @ptrCast(@alignCast(ref));
        const list = data orelse return 0;
        const buffers: [*]AudioBuffer = &list.mBuffers;
        const b = buffers[0];
        if (list.mNumberBuffers != 1 or b.mNumberChannels != 2 or b.mData == null) {
            // Not the format asked for: silence.
            for (buffers[0..list.mNumberBuffers]) |x| if (x.mData) |p| @memset(@as([*]u8, @ptrCast(p))[0..x.mDataByteSize], 0);
            return 0;
        }
        const out: [*]f32 = @ptrCast(@alignCast(b.mData));
        const n = @min(@as(usize, frames) * 2, b.mDataByteSize / @sizeOf(f32));
        self.mixer.?.render(out[0..n]);
        return 0;
    }
};

// ---- Tests ----

const testing = std.testing;
extern "c" fn usleep(us: u32) c_int;

test "the mixer plays through CoreAudio (silence)" {
    var out: Output = .{};
    var mixer: audio.Mixer = .{};
    mixer.setOutput(out.output());
    defer mixer.setOutput(null);

    // 50 ms of silence: the whole path, without a sound.
    var data: [2400 * 2]u8 = @splat(0);
    const clip: audio.Clip = .{ .format = .i16, .channels = 1, .sample_rate = 48000, .data = &data };
    const v = mixer.play(&clip, .{}, null) orelse return error.SkipZigTest; // no audio device
    try testing.expect(out.unit != null);
    try testing.expect(mixer.sample_rate >= 8000);

    // CoreAudio's thread plays it to its end (unless there is no device
    // to play on: some build machines).
    var waited: u32 = 0;
    while (mixer.isPlaying(v)) : (waited += 1) {
        if (waited > 200) {
            log.info("CoreAudio did not ask for sound in 2 s: no device?", .{});
            return error.SkipZigTest;
        }
        _ = usleep(10_000);
    }
    mixer.update();
    try testing.expect(!mixer.busy());

    // A looping voice, stopped: the call returns once CoreAudio let it go.
    const w = mixer.play(&clip, .{ .looping = true }, null).?;
    try testing.expect(mixer.isPlaying(w));
    mixer.stop(w);
    try testing.expect(!mixer.isPlaying(w));
}
