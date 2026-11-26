// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Makes the sounds of the Patrisio example (examples/patrisio/*.wav):
//! effects and a looping tune, synthesized here (square, triangle and
//! noise voices, like an old game console), so they are free to use.
//!
//!     zig build patrisio-sounds

const std = @import("std");

const rate = 22050;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, if (args.len > 1) args[1] else "examples/patrisio", .{});
    defer dir.close(init.io);
    const sounds = .{
        .{ "jump.wav", jump },
        .{ "fish.wav", fish },
        .{ "bonk.wav", bonk },
        .{ "stomp.wav", stomp },
        .{ "ouch.wav", ouch },
        .{ "lose.wav", lose },
        .{ "win.wav", win },
        .{ "theme.wav", theme },
    };
    inline for (sounds) |s| {
        const samples = try s[1](arena);
        try dir.writeFile(init.io, .{ .sub_path = s[0], .data = try wav(arena, samples) });
    }
}

// ---- Voices ----

fn square(phase: f64, duty: f64) f32 {
    return if (phase - @floor(phase) < duty) 1 else -1;
}

fn triangle(phase: f64) f32 {
    const p: f32 = @floatCast(phase - @floor(phase));
    return 4 * @abs(p - 0.5) - 1;
}

var noise_state: u32 = 0x1234567;
fn noise() f32 {
    noise_state = noise_state *% 1664525 +% 1013904223;
    return @as(f32, @floatFromInt(noise_state >> 16)) / 32768 - 1;
}

/// The frequency of MIDI note `n`.
fn hz(n: f64) f64 {
    return 440 * std.math.pow(f64, 2, (n - 69) / 12);
}

/// A sound of `seconds`, silent.
fn buffer(gpa: std.mem.Allocator, seconds: f64) ![]f32 {
    const out = try gpa.alloc(f32, @intFromFloat(seconds * rate));
    @memset(out, 0);
    return out;
}

/// Adds a tone from `from` to `to` Hz (exponentially) over `seconds` at
/// `start`, fading from `gain` to silence.
fn sweep(out: []f32, start: f64, seconds: f64, from: f64, to: f64, gain: f32, comptime wave: enum { square, thin, triangle }) void {
    var phase: f64 = 0;
    const first: usize = @intFromFloat(start * rate);
    const n: usize = @intFromFloat(seconds * rate);
    for (0..n) |i| {
        if (first + i >= out.len) break;
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        phase += from * std.math.pow(f64, to / from, t) / rate;
        const v = switch (wave) {
            .square => square(phase, 0.5),
            .thin => square(phase, 0.25),
            .triangle => triangle(phase),
        };
        out[first + i] += v * gain * envelope(i, n);
    }
}

/// Up in 3 ms, then down to silence.
fn envelope(i: usize, n: usize) f32 {
    const attack = 66;
    if (i < attack) return @as(f32, @floatFromInt(i)) / attack;
    return 1 - @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
}

fn hiss(out: []f32, start: f64, seconds: f64, gain: f32) void {
    const first: usize = @intFromFloat(start * rate);
    const n: usize = @intFromFloat(seconds * rate);
    for (0..n) |i| {
        if (first + i >= out.len) break;
        out[first + i] += noise() * gain * (1 - @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)));
    }
}

// ---- The effects ----

fn jump(gpa: std.mem.Allocator) ![]f32 {
    const out = try buffer(gpa, 0.2);
    sweep(out, 0, 0.2, 300, 860, 0.3, .thin);
    return out;
}

fn fish(gpa: std.mem.Allocator) ![]f32 {
    const out = try buffer(gpa, 0.36);
    sweep(out, 0, 0.08, hz(83), hz(83), 0.25, .square);
    sweep(out, 0.07, 0.29, hz(88), hz(88), 0.25, .square);
    return out;
}

fn bonk(gpa: std.mem.Allocator) ![]f32 {
    const out = try buffer(gpa, 0.14);
    sweep(out, 0, 0.14, 180, 70, 0.6, .triangle);
    hiss(out, 0, 0.03, 0.25);
    return out;
}

fn stomp(gpa: std.mem.Allocator) ![]f32 {
    const out = try buffer(gpa, 0.2);
    sweep(out, 0, 0.18, 600, 120, 0.28, .square);
    hiss(out, 0, 0.06, 0.15);
    return out;
}

fn ouch(gpa: std.mem.Allocator) ![]f32 {
    const out = try buffer(gpa, 0.55);
    var phase: f64 = 0;
    for (out, 0..) |*o, i| {
        const t = @as(f64, @floatFromInt(i)) / rate;
        const f = 760 * std.math.pow(f64, 0.3, t / 0.55) * (1 + 0.07 * @sin(2 * std.math.pi * 16 * t));
        phase += f / rate;
        o.* += square(phase, 0.5) * 0.25 * envelope(i, out.len);
    }
    return out;
}

/// Notes (MIDI) one after another, each `step` seconds; the last one
/// held for `last`.
fn jingle(gpa: std.mem.Allocator, notes: []const f64, step: f64, last: f64, gain: f32) ![]f32 {
    const out = try buffer(gpa, step * @as(f64, @floatFromInt(notes.len - 1)) + last);
    for (notes, 0..) |n, i| {
        const at = step * @as(f64, @floatFromInt(i));
        const len = if (i == notes.len - 1) last else step * 0.9;
        sweep(out, at, len, hz(n), hz(n), gain, .thin);
        sweep(out, at, len, hz(n - 12), hz(n - 12), gain, .triangle);
    }
    return out;
}

fn lose(gpa: std.mem.Allocator) ![]f32 {
    return jingle(gpa, &.{ 67, 66, 65, 64, 60, 55 }, 0.2, 0.8, 0.2);
}

fn win(gpa: std.mem.Allocator) ![]f32 {
    return jingle(gpa, &.{ 72, 76, 79, 84, 79, 84, 88 }, 0.11, 0.9, 0.18);
}

// ---- The tune: 8 bars at 150 beats a minute, looping ----

const tie = -1;
const rest = 0;

/// Eighth notes: C, Am, F, G, C, Am, F, G.
const melody = [_]f64{
    72, tie, 76, 79,  84, tie, 79, 76,
    81, tie, 79, 76,  72, tie, 76, rest,
    77, tie, 81, 84,  81, tie, 77, 76,
    74, tie, 79, tie, 83, 81,  79, rest,
    84, tie, 83, 84,  79, tie, 76, 79,
    81, tie, 84, 81,  76, tie, 72, 76,
    77, 81,  84, 81,  77, tie, 74, 77,
    79, tie, 74, tie, 71, tie, 74, rest,
};
const roots = [_]f64{ 48, 45, 41, 43, 48, 45, 41, 43 };

fn theme(gpa: std.mem.Allocator) ![]f32 {
    const eighth = 60.0 / 150.0 / 2.0;
    const out = try buffer(gpa, eighth * @as(f64, melody.len));
    // The melody: each note lasts until the next one (ties hold it).
    var i: usize = 0;
    while (i < melody.len) {
        var len: usize = 1;
        while (i + len < melody.len and melody[i + len] == tie) len += 1;
        if (melody[i] != rest) note(out, eighth * @as(f64, @floatFromInt(i)), eighth * @as(f64, @floatFromInt(len)) * 0.92, hz(melody[i]), 0.14);
        i += len;
    }
    // The bass: root, fifth, octave, fifth, in quarter notes.
    for (roots, 0..) |r, bar| for ([_]f64{ 0, 7, 12, 7 }, 0..) |up, beat| {
        const at = eighth * @as(f64, @floatFromInt(bar * 8 + beat * 2));
        bass(out, at, eighth * 1.8, hz(r + up), 0.3);
    };
    // Drums: a kick on beats 1 and 3, a hat on the off-beats.
    for (0..melody.len) |e| {
        const at = eighth * @as(f64, @floatFromInt(e));
        if (e % 4 == 0) sweep(out, at, 0.09, 140, 45, 0.45, .triangle);
        if (e % 2 == 1) hiss(out, at, 0.03, 0.07);
    }
    return out;
}

/// A melody note: thin square with a little vibrato, released at its end.
fn note(out: []f32, start: f64, seconds: f64, f: f64, gain: f32) void {
    var phase: f64 = 0;
    const first: usize = @intFromFloat(start * rate);
    const n: usize = @intFromFloat(seconds * rate);
    for (0..n) |i| {
        const t = @as(f64, @floatFromInt(i)) / rate;
        phase += f * (1 + 0.004 * @sin(2 * std.math.pi * 5.5 * t)) / rate;
        const attack = @min(1, @as(f32, @floatFromInt(i)) / 110);
        const release = @min(1, @as(f32, @floatFromInt(n - i)) / 440);
        const decay: f32 = 0.7 + 0.3 * @as(f32, @floatCast(@exp(-t * 6)));
        out[first + i] += square(phase, 0.25) * gain * attack * release * decay;
    }
}

fn bass(out: []f32, start: f64, seconds: f64, f: f64, gain: f32) void {
    var phase: f64 = 0;
    const first: usize = @intFromFloat(start * rate);
    const n: usize = @intFromFloat(seconds * rate);
    for (0..n) |i| {
        phase += f / rate;
        const attack = @min(1, @as(f32, @floatFromInt(i)) / 66);
        const release = @min(1, @as(f32, @floatFromInt(n - i)) / 330);
        out[first + i] += triangle(phase) * gain * attack * release;
    }
}

// ---- WAV ----

/// 16-bit mono WAV of `samples` (clamped to [-1, 1]).
fn wav(gpa: std.mem.Allocator, samples: []const f32) ![]u8 {
    const data_len: u32 = @intCast(samples.len * 2);
    const out = try gpa.alloc(u8, 44 + data_len);
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_len, .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, out[22..24], 1, .little); // mono
    std.mem.writeInt(u32, out[24..28], rate, .little);
    std.mem.writeInt(u32, out[28..32], rate * 2, .little);
    std.mem.writeInt(u16, out[32..34], 2, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_len, .little);
    for (samples, 0..) |s, i| {
        const v: i16 = @intFromFloat(std.math.clamp(s, -1, 1) * 32767);
        std.mem.writeInt(i16, out[44 + 2 * i ..][0..2], v, .little);
    }
    return out;
}
