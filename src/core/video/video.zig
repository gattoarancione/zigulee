// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Video: sources (files embedded at build time, or read while playing),
//! the decoders that turn them into frames and sound, and a player that
//! shows the frames in time with the sound. The `Video` element plays
//! through it.
//!
//! Animated PNG is decoded here, everywhere. Other formats (MP4, ...) are
//! the platform's: a backend adds its decoder at startup,
//!
//!     zigulee.core.video.addDecoder(my_decoder);
//!
//! and the first decoder that recognizes a source plays it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rgba8 = @import("../graphics.zig").Rgba8;

pub const apng = @import("apng.zig");
pub const Player = @import("player.zig").Player;
/// The `Video` element.
pub const VideoElement = @import("element.zig").VideoElement;

/// What to play: a file's bytes (embedded with `@video-url`), or a file
/// to read while playing (`source-file`).
pub const Source = struct {
    bytes: []const u8 = "",
    path: []const u8 = "",

    pub const none: Source = .{};

    pub fn isNone(s: Source) bool {
        return s.bytes.len == 0 and s.path.len == 0;
    }

    pub fn eql(a: Source, b: Source) bool {
        return a.bytes.ptr == b.bytes.ptr and a.bytes.len == b.bytes.len and std.mem.eql(u8, a.path, b.path);
    }
};

pub const Error = error{
    /// No decoder recognizes the source.
    UnsupportedVideo,
    InvalidVideo,
    ReadFailed,
} || Allocator.Error;

/// What a stream holds.
pub const Info = struct {
    width: u32,
    height: u32,
    /// The length, or 0 if unknown.
    duration_ms: u64 = 0,
    /// The soundtrack's frames per second (stereo 32-bit floats), or 0
    /// without one.
    audio_rate: u32 = 0,
};

/// An open video, decoded in order. Its functions are called from one
/// thread at a time (the player's worker thread, where it has one).
pub const Stream = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        info: *const fn (ctx: *anyopaque) Info,
        /// Decodes the next frame into `pixels` (premultiplied, width x
        /// height): returns when to show it (ms from the start), or null
        /// after the last one.
        frame: *const fn (ctx: *anyopaque, pixels: []Rgba8) Error!?u64,
        /// The next stereo frames of the soundtrack (at most
        /// `out.len / 2`): how many, 0 at its end.
        audio: *const fn (ctx: *anyopaque, out: []f32) Error!usize,
        /// Goes to `ms`: the next frame is the one showing then, the sound
        /// continues from there.
        seek: *const fn (ctx: *anyopaque, ms: u64) Error!void,
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn info(s: Stream) Info {
        return s.vtable.info(s.ctx);
    }
    pub fn frame(s: Stream, pixels: []Rgba8) Error!?u64 {
        return s.vtable.frame(s.ctx, pixels);
    }
    pub fn audio(s: Stream, out: []f32) Error!usize {
        return s.vtable.audio(s.ctx, out);
    }
    pub fn seek(s: Stream, ms: u64) Error!void {
        return s.vtable.seek(s.ctx, ms);
    }
    pub fn close(s: Stream) void {
        s.vtable.close(s.ctx);
    }
};

/// Opens sources it recognizes.
pub const Decoder = struct {
    name: []const u8,
    ctx: ?*anyopaque = null,
    /// A stream for `source`, or null if it is not this decoder's kind.
    /// Called on the thread that will decode it.
    open: *const fn (ctx: ?*anyopaque, gpa: Allocator, source: Source) Error!?Stream,
};

var decoders: [4]?Decoder = @splat(null);

/// Adds a decoder (a backend's), tried after animated PNG.
pub fn addDecoder(d: Decoder) void {
    for (&decoders) |*slot| if (slot.* == null) {
        slot.* = d;
        return;
    };
}

pub fn removeDecoder(name: []const u8) void {
    for (&decoders) |*slot| if (slot.*) |d| if (std.mem.eql(u8, d.name, name)) {
        slot.* = null;
    };
}

/// Opens `source` with the first decoder that recognizes it.
pub fn open(gpa: Allocator, source: Source) Error!Stream {
    if (try apng.decoder.open(null, gpa, source)) |s| return s;
    for (decoders) |slot| if (slot) |d| {
        if (try d.open(d.ctx, gpa, source)) |s| return s;
    };
    return error.UnsupportedVideo;
}

test {
    _ = apng;
    _ = @import("player.zig");
    _ = @import("element.zig");
}
