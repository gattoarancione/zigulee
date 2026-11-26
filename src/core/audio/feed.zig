// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! A feed: sound produced while it plays (a video's soundtrack, decoded as
//! the video goes), as stereo 32-bit float frames in a ring. One thread
//! writes it, the mixer reads it (`Mixer.playFeed`); neither waits for the
//! other. How far the mixer has read is the clock a video follows.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Feed = struct {
    /// Interleaved stereo frames, `capacity` of them.
    ring: []f32,
    capacity: usize,
    /// Frames per second of what is written.
    sample_rate: u32,
    /// Frames written and read, ever, wrapping (the ring index is modulo
    /// `capacity`). Machine words: 32-bit machines have no 64-bit atomics.
    written: std.atomic.Value(usize) = .init(0),
    read: std.atomic.Value(usize) = .init(0),
    /// The writer has no more: the voice ends once it has read everything.
    finished: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: Allocator, capacity: usize, sample_rate: u32) Allocator.Error!Feed {
        return .{ .ring = try gpa.alloc(f32, 2 * capacity), .capacity = capacity, .sample_rate = sample_rate };
    }

    pub fn deinit(f: *Feed, gpa: Allocator) void {
        gpa.free(f.ring);
        f.* = undefined;
    }

    /// Starts over, empty. Only while no voice plays it.
    pub fn reset(f: *Feed) void {
        f.written.store(0, .release);
        f.read.store(0, .release);
        f.finished.store(false, .release);
    }

    // ---- The writer ----

    /// How many frames can be written now.
    pub fn space(f: *const Feed) usize {
        return f.capacity - (f.written.load(.monotonic) -% f.read.load(.acquire));
    }

    /// Writes as many of `frames` (interleaved stereo) as fit; returns how
    /// many frames it wrote.
    pub fn write(f: *Feed, frames: []const f32) usize {
        const n = @min(frames.len / 2, f.space());
        const start = f.written.load(.monotonic);
        for (0..n) |i| {
            const index = (start +% i) % f.capacity;
            f.ring[2 * index] = frames[2 * i];
            f.ring[2 * index + 1] = frames[2 * i + 1];
        }
        f.written.store(start +% n, .release);
        return n;
    }

    /// No more frames will be written.
    pub fn finish(f: *Feed) void {
        f.finished.store(true, .release);
    }

    // ---- The reader (the mixer) ----

    /// Frames written and not read yet.
    pub fn available(f: *const Feed) usize {
        return f.written.load(.acquire) -% f.read.load(.monotonic);
    }

    /// Channel `channel` of the `i`th unread frame (`i < available()`).
    pub fn at(f: *const Feed, i: usize, channel: u1) f32 {
        const index = (f.read.load(.monotonic) +% i) % f.capacity;
        return f.ring[2 * index + channel];
    }

    /// Marks `n` frames read.
    pub fn consume(f: *Feed, n: usize) void {
        f.read.store(f.read.load(.monotonic) +% n, .release);
    }
};

test "a feed fills, wraps and drains" {
    const t = std.testing;
    var f: Feed = try .init(t.allocator, 4, 1000);
    defer f.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), f.write(&.{ 1, 1, 2, 2, 3, 3 }));
    try t.expectEqual(@as(usize, 1), f.write(&.{ 4, 4, 5, 5 })); // full
    try t.expectEqual(@as(f32, 2), f.at(1, 1));
    f.consume(3);
    try t.expectEqual(@as(usize, 2), f.write(&.{ 6, 6, 7, 7 }));
    try t.expectEqual(@as(f32, 4), f.at(0, 0));
    try t.expectEqual(@as(f32, 7), f.at(2, 1)); // wrapped
    try t.expectEqual(@as(usize, 3), f.available());
}
