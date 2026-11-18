// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! A clip: sound as frames of samples (one per channel), read in place
//! from its data (a WAV file embedded in the program, say: nothing is
//! copied or converted ahead of time).

const std = @import("std");

/// How samples are stored (little-endian).
pub const SampleFormat = enum {
    /// Unsigned 8-bit, 128 for silence.
    u8,
    i16,
    /// Signed 24-bit, in 3 bytes.
    i24,
    i32,
    f32,

    pub fn bytes(f: SampleFormat) u8 {
        return switch (f) {
            .u8 => 1,
            .i16 => 2,
            .i24 => 3,
            .i32, .f32 => 4,
        };
    }
};

pub const Clip = struct {
    format: SampleFormat,
    /// 1 (mono) or 2 (stereo: left, then right).
    channels: u8,
    /// Frames per second.
    sample_rate: u32,
    /// The samples, frame after frame.
    data: []const u8,

    pub const empty: Clip = .{ .format = .i16, .channels = 1, .sample_rate = 48000, .data = &.{} };

    /// The same samples, read the same way.
    pub fn eql(a: Clip, b: Clip) bool {
        return a.format == b.format and a.channels == b.channels and a.sample_rate == b.sample_rate and
            a.data.ptr == b.data.ptr and a.data.len == b.data.len;
    }

    pub fn frames(c: Clip) u32 {
        return @intCast(c.data.len / (@as(usize, c.format.bytes()) * c.channels));
    }

    /// The length in milliseconds.
    pub fn durationMs(c: Clip) u64 {
        if (c.sample_rate == 0) return 0;
        return @as(u64, c.frames()) * 1000 / c.sample_rate;
    }

    /// Sample `channel` of `frame`, in [-1, 1]; a mono clip's one channel
    /// for either.
    pub fn sample(c: Clip, frame: u32, channel: u8) f32 {
        const ch = if (c.channels == 1) 0 else channel;
        const at = (@as(usize, frame) * c.channels + ch) * c.format.bytes();
        const b = c.data[at..];
        return switch (c.format) {
            .u8 => (@as(f32, @floatFromInt(b[0])) - 128) / 128,
            .i16 => @as(f32, @floatFromInt(std.mem.readInt(i16, b[0..2], .little))) / 32768,
            .i24 => @as(f32, @floatFromInt(std.mem.readInt(i24, b[0..3], .little))) / 8388608,
            .i32 => @as(f32, @floatFromInt(std.mem.readInt(i32, b[0..4], .little))) / 2147483648,
            .f32 => @bitCast(std.mem.readInt(u32, b[0..4], .little)),
        };
    }
};

test "samples in every format" {
    const t = std.testing;
    const u8_clip: Clip = .{ .format = .u8, .channels = 1, .sample_rate = 8000, .data = &.{ 0, 128, 255 } };
    try t.expectEqual(@as(u32, 3), u8_clip.frames());
    try t.expectEqual(@as(f32, -1), u8_clip.sample(0, 0));
    try t.expectEqual(@as(f32, 0), u8_clip.sample(1, 1));
    const i16_clip: Clip = .{ .format = .i16, .channels = 2, .sample_rate = 48000, .data = &.{ 0x00, 0x80, 0xff, 0x7f } };
    try t.expectEqual(@as(u32, 1), i16_clip.frames());
    try t.expectEqual(@as(f32, -1), i16_clip.sample(0, 0));
    try t.expectApproxEqAbs(@as(f32, 1), i16_clip.sample(0, 1), 0.0001);
    const i24_clip: Clip = .{ .format = .i24, .channels = 1, .sample_rate = 48000, .data = &.{ 0x00, 0x00, 0x40 } };
    try t.expectEqual(@as(f32, 0.5), i24_clip.sample(0, 0));
    const f: f32 = -0.25;
    const f32_clip: Clip = .{ .format = .f32, .channels = 1, .sample_rate = 48000, .data = std.mem.asBytes(&f) };
    try t.expectEqual(@as(f32, -0.25), f32_clip.sample(0, 1));
    try t.expectEqual(@as(u64, 0), Clip.empty.durationMs());
}
