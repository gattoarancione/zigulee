// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The `Video` element: plays `source` (or the file `source_file`) and
//! shows it like an `Image` (which it is, underneath: `image_fit`, the
//! video's size as its preferred size).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("../properties.zig").Property;
const ChangeTracker = @import("../properties.zig").ChangeTracker;
const Callback = @import("../callbacks.zig").Callback;
const Timer = @import("../timers.zig").Timer;
const ImageItem = @import("../items.zig").Image;
const video = @import("video.zig");
const Player = video.Player;

const log = std.log.scoped(.zigulee_video);

/// How often the picture follows playback, in milliseconds.
const poll_ms = 10;

/// Shows `source` (a video embedded with `@video-url`) or `source_file` (a
/// file read while playing, which wins when set). It shows the first frame
/// until it plays: set `playing` (or call `play()`); `stop()` goes back to
/// the start. `position_ms` follows playback, and setting it seeks. The
/// soundtrack plays through the mixer. Changes apply when change handlers
/// run. Initialize in place with `init`.
pub const VideoElement = struct {
    image: ImageItem = .{},
    source: Property(video.Source) = .init(.none),
    source_file: Property([]const u8) = .init(""),
    playing: Property(bool) = .init(false),
    paused: Property(bool) = .init(false),
    loop: Property(bool) = .init(false),
    /// The soundtrack's volume: 0 silent, 1 as recorded.
    volume: Property(f32) = .init(1),
    position_ms: Property(i64) = .init(0),
    /// The length, once known (0 until then).
    duration_ms: Property(i64) = .init(0),
    /// Playback ended by itself (not when stopped, and never while
    /// looping). The last frame stays.
    finished: Callback(fn () void) = .{},

    gpa: Allocator = undefined,
    player: ?*Player = null,
    poll: Timer = .{},
    tracker: ChangeTracker(Settings) = undefined,
    /// The settings the player follows (what the element itself sets, too).
    applied: Settings = undefined,

    const Settings = struct {
        source: video.Source,
        /// `source_file`'s hash (the string itself may be freed).
        file: u64,
        playing: bool,
        paused: bool,
        loop: bool,
        volume: f32,
        position_ms: i64,
    };

    pub fn init(self: *VideoElement, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.tracker.init(gpa, self, settings, apply);
        self.applied = .{ .source = .none, .file = std.hash.Wyhash.hash(0, ""), .playing = false, .paused = false, .loop = false, .volume = 1, .position_ms = 0 };
        apply(self, self.tracker.value);
    }

    pub fn deinit(self: *VideoElement) void {
        self.unload();
        self.tracker.deinit();
        self.poll.deinit();
        self.image.deinit();
        self.source.deinit();
        self.source_file.deinit();
        self.playing.deinit();
        self.paused.deinit();
        self.loop.deinit();
        self.volume.deinit();
        self.position_ms.deinit();
        self.duration_ms.deinit();
    }

    /// Plays from the start.
    pub fn play(self: *VideoElement) void {
        self.applied = self.current();
        self.load(0, true);
    }

    /// Stops and goes back to the start (showing the first frame).
    pub fn stop(self: *VideoElement) void {
        self.applied = self.current();
        self.load(0, false);
    }

    fn settings(self: *VideoElement) Settings {
        return .{
            .source = self.source.get(),
            .file = std.hash.Wyhash.hash(0, self.source_file.get()),
            .playing = self.playing.get(),
            .paused = self.paused.get(),
            .loop = self.loop.get(),
            .volume = self.volume.get(),
            .position_ms = self.position_ms.get(),
        };
    }

    /// The settings now, without depending on them.
    fn current(self: *VideoElement) Settings {
        return .{
            .source = self.source.getUntracked(),
            .file = std.hash.Wyhash.hash(0, self.source_file.getUntracked()),
            .playing = self.playing.getUntracked(),
            .paused = self.paused.getUntracked(),
            .loop = self.loop.getUntracked(),
            .volume = self.volume.getUntracked(),
            .position_ms = self.position_ms.getUntracked(),
        };
    }

    fn apply(self: *VideoElement, s: Settings) void {
        const was = self.applied;
        self.applied = s;
        if (!s.source.eql(was.source) or s.file != was.file) {
            // From the start, unless a position was set with it.
            return self.load(if (s.position_ms != was.position_ms) s.position_ms else 0, s.playing);
        }
        if (s.playing != was.playing) {
            if (!s.playing) return self.stop();
            // Again from the start if it had played to the end.
            if (self.player == null or self.player.?.finished()) return self.load(0, true);
            self.player.?.setPaused(s.paused);
            self.startPolling();
        }
        const p = self.player orelse {
            if (s.position_ms != was.position_ms) self.load(s.position_ms, s.playing);
            return;
        };
        if (s.position_ms != was.position_ms) {
            // In place: the frame there shows soon, even paused.
            p.seek(@intCast(@max(s.position_ms, 0)));
            self.startPolling();
        }
        if (s.paused != was.paused) {
            p.setPaused(s.paused or !s.playing);
            self.startPolling();
        }
        if (s.loop != was.loop) p.setLooping(s.loop);
        if (s.volume != was.volume) p.setVolume(s.volume);
    }

    /// Opens the source at `start_ms`, playing or showing that frame.
    fn load(self: *VideoElement, start_ms: i64, play_it: bool) void {
        self.unload();
        const s = self.applied;
        const file = self.source_file.getUntracked();
        const source: video.Source = if (file.len > 0) .{ .path = file } else s.source;
        self.setPlaying(false);
        if (source.isNone()) {
            self.image.source.set(null);
            self.duration_ms.set(0);
            return;
        }
        const start: u64 = @intCast(@max(start_ms, 0));
        self.player = Player.open(self.gpa, source, .{
            .start_ms = start,
            .looping = s.loop,
            .paused = !play_it or s.paused,
            .volume = s.volume,
        }) catch |err| {
            log.info("cannot play the video: {t}", .{err});
            self.image.source.set(null);
            self.duration_ms.set(0);
            return;
        };
        const p = self.player.?;
        self.duration_ms.set(@intCast(p.info.duration_ms));
        self.image.source.set(p.frame());
        self.setPosition(@intCast(start));
        self.setPlaying(play_it);
        self.startPolling();
    }

    fn unload(self: *VideoElement) void {
        self.poll.stop();
        if (self.player) |p| p.close();
        self.player = null;
    }

    fn startPolling(self: *VideoElement) void {
        if (!self.poll.isRunning()) self.poll.start(.repeated, poll_ms, self, follow);
    }

    /// Shows the frame due, follows the position, notices the end.
    fn follow(self: *VideoElement) void {
        const p = self.player orelse return self.poll.stop();
        if (p.update()) self.image.source.set(p.frame());
        const playing = self.applied.playing and !self.applied.paused;
        if (playing) self.setPosition(@intCast(p.position()));
        if (playing and p.finished()) {
            // Held at the end: a seek from here shows that frame, still.
            p.setPaused(true);
            self.poll.stop();
            self.setPlaying(false);
            self.finished.call(.{});
            return;
        }
        // Paused or stopped, once the frame for where it is shows: nothing
        // to follow.
        if (!playing and !p.busy() and p.frame() != null) self.poll.stop();
    }

    /// Sets `playing` as the element (not a change to act on), only if it
    /// changes (a binding that started it stays).
    fn setPlaying(self: *VideoElement, on: bool) void {
        self.applied.playing = on;
        if (self.playing.getUntracked() != on) self.playing.set(on);
    }

    fn setPosition(self: *VideoElement, ms: i64) void {
        self.applied.position_ms = ms;
        self.position_ms.set(ms);
    }
};

// ---- Tests ----

const testing = std.testing;
const core = @import("../core.zig");

/// Advances the UI clock until `ok(el)` (the decoding thread may be
/// behind).
fn until(el: *VideoElement, comptime ok: fn (*VideoElement) bool) !void {
    for (0..1000) |_| {
        core.updateTimersAndAnimations(core.now() + 1);
        core.runChangeHandlers();
        if (ok(el)) return;
        if (@import("player.zig").threaded) {
            var t: std.Io.Threaded = .init_single_threaded;
            t.io().sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }
    return error.TestUnexpectedResult;
}

fn red(el: *VideoElement) bool {
    const img = el.image.source.getUntracked() orelse return false;
    return img.pixels[0].r == 255;
}
fn blue(el: *VideoElement) bool {
    const img = el.image.source.getUntracked() orelse return false;
    return img.pixels[0].b == 255;
}
fn stopped(el: *VideoElement) bool {
    return !el.playing.getUntracked();
}

test "the Video element shows the first frame, plays, finishes, plays again" {
    const bytes = try video.apng.testVideo(testing.allocator);
    defer testing.allocator.free(bytes);
    var el: VideoElement = undefined;
    el.init(testing.allocator);
    defer el.deinit();
    var finished: usize = 0;
    el.finished.setHandler(&finished, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);
    el.source.set(.{ .bytes = bytes });
    core.runChangeHandlers();
    try until(&el, red); // the first frame, not playing
    try testing.expectEqual(@as(i64, 300), el.duration_ms.get());
    try testing.expect(!el.playing.get());

    el.playing.set(true);
    core.runChangeHandlers();
    try until(&el, blue);
    try until(&el, stopped);
    try testing.expectEqual(@as(usize, 1), finished);
    try testing.expect(blue(&el)); // the last frame stays

    el.play(); // again
    try until(&el, red);
    try testing.expect(el.playing.get());
    el.stop();
    try testing.expect(!el.playing.get());
    try testing.expectEqual(@as(i64, 0), el.position_ms.get());
    try testing.expectEqual(@as(usize, 1), finished);
}

test "seeking, and sources that cannot play" {
    const bytes = try video.apng.testVideo(testing.allocator);
    defer testing.allocator.free(bytes);
    var el: VideoElement = undefined;
    el.init(testing.allocator);
    defer el.deinit();
    el.source.set(.{ .bytes = bytes });
    el.position_ms.set(250);
    core.runChangeHandlers();
    try until(&el, blue);

    el.source.set(.{ .bytes = "not a video" });
    core.runChangeHandlers();
    try testing.expectEqual(@as(?@import("../image.zig").Image, null), el.image.source.get());
    try testing.expectEqual(@as(i64, 0), el.duration_ms.get());
    el.play();
    try testing.expect(!el.playing.get());
}
