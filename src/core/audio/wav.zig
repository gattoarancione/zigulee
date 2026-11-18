// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! WAV files (RIFF/WAVE): PCM at 8, 16, 24 or 32 bits, or 32-bit float;
//! mono or stereo. The clip reads the file's samples in place.

const std = @import("std");
const Clip = @import("clip.zig").Clip;

pub const Error = error{ NotWav, UnsupportedFormat };

/// The clip in WAV file `bytes` (which it refers to: they must outlive
/// it).
pub fn decode(bytes: []const u8) Error!Clip {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return error.NotWav;
    var at: usize = 12;
    var fmt: ?[]const u8 = null;
    while (at + 8 <= bytes.len) {
        const id = bytes[at..][0..4];
        const size = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        const body = bytes[at + 8 .. @min(bytes.len, at + 8 + @as(usize, size))];
        if (std.mem.eql(u8, id, "fmt ")) fmt = body;
        if (std.mem.eql(u8, id, "data")) {
            const f = fmt orelse return error.NotWav;
            if (f.len < 16) return error.NotWav;
            var tag = std.mem.readInt(u16, f[0..2], .little);
            const channels = std.mem.readInt(u16, f[2..4], .little);
            const rate = std.mem.readInt(u32, f[4..8], .little);
            const bits = std.mem.readInt(u16, f[14..16], .little);
            // WAVE_FORMAT_EXTENSIBLE: the real format is the sub-format's.
            if (tag == 0xFFFE and f.len >= 26) tag = std.mem.readInt(u16, f[24..26], .little);
            const format: @import("clip.zig").SampleFormat = switch (tag) {
                1 => switch (bits) {
                    8 => .u8,
                    16 => .i16,
                    24 => .i24,
                    32 => .i32,
                    else => return error.UnsupportedFormat,
                },
                3 => if (bits == 32) .f32 else return error.UnsupportedFormat,
                else => return error.UnsupportedFormat,
            };
            if (channels != 1 and channels != 2) return error.UnsupportedFormat;
            if (rate == 0) return error.NotWav;
            const frame_bytes = @as(usize, format.bytes()) * channels;
            return .{ .format = format, .channels = @intCast(channels), .sample_rate = rate, .data = body[0 .. body.len - body.len % frame_bytes] };
        }
        // Chunks are padded to even sizes.
        at += 8 + std.mem.alignForward(usize, size, 2);
    }
    return error.NotWav;
}

/// A WAV file of 16-bit `samples` (`channels` interleaved), for tests and
/// tools.
pub fn encode16(gpa: std.mem.Allocator, samples: []const i16, channels: u16, sample_rate: u32) std.mem.Allocator.Error![]u8 {
    const data_len: u32 = @intCast(samples.len * 2);
    const out = try gpa.alloc(u8, 44 + data_len);
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_len, .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little);
    std.mem.writeInt(u16, out[22..24], channels, .little);
    std.mem.writeInt(u32, out[24..28], sample_rate, .little);
    std.mem.writeInt(u32, out[28..32], sample_rate * channels * 2, .little);
    std.mem.writeInt(u16, out[32..34], channels * 2, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_len, .little);
    for (samples, 0..) |s, i| std.mem.writeInt(i16, out[44 + 2 * i ..][0..2], s, .little);
    return out;
}

test "a WAV file read back" {
    const t = std.testing;
    const bytes = try encode16(t.allocator, &.{ 0, 16384, -16384, 32767 }, 2, 22050);
    defer t.allocator.free(bytes);
    const c = try decode(bytes);
    try t.expectEqual(@as(u8, 2), c.channels);
    try t.expectEqual(@as(u32, 22050), c.sample_rate);
    try t.expectEqual(@as(u32, 2), c.frames());
    try t.expectEqual(@as(f32, 0.5), c.sample(0, 1));
    try t.expectEqual(@as(f32, -0.5), c.sample(1, 0));
    try t.expectError(error.NotWav, decode("RIFF\x00\x00\x00\x00WAVX"));
    try t.expectError(error.NotWav, decode(""));
}

test "chunks before the data, and an extensible float format" {
    const t = std.testing;
    var buf: [128]u8 = @splat(0);
    @memcpy(buf[0..12], "RIFF\x00\x00\x00\x00WAVE");
    @memcpy(buf[12..20], "LIST\x03\x00\x00\x00"); // odd size: padded
    var at: usize = 24;
    @memcpy(buf[at..][0..8], "fmt \x28\x00\x00\x00");
    std.mem.writeInt(u16, buf[at + 8 ..][0..2], 0xFFFE, .little);
    std.mem.writeInt(u16, buf[at + 10 ..][0..2], 1, .little);
    std.mem.writeInt(u32, buf[at + 12 ..][0..4], 44100, .little);
    std.mem.writeInt(u16, buf[at + 22 ..][0..2], 32, .little);
    std.mem.writeInt(u16, buf[at + 32 ..][0..2], 3, .little); // sub-format: float
    at += 8 + 40;
    @memcpy(buf[at..][0..8], "data\x04\x00\x00\x00");
    const v: f32 = 0.75;
    @memcpy(buf[at + 8 ..][0..4], std.mem.asBytes(&v));
    const c = try decode(buf[0 .. at + 12]);
    try t.expectEqual(@as(f32, 0.75), c.sample(0, 0));
    try t.expectEqual(@as(u32, 44100), c.sample_rate);
}
