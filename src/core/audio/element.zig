// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The `Audio` element: plays its `source` through the process's mixer.
//! Not drawn.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("../properties.zig").Property;
const ChangeTracker = @import("../properties.zig").ChangeTracker;
const Callback = @import("../callbacks.zig").Callback;
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const ItemVTable = item_mod.ItemVTable;
const Timer = @import("../timers.zig").Timer;
const audio = @import("audio.zig");
const Clip = audio.Clip;
const Voice = audio.Voice;

/// The most voices one element plays at once (`voices`).
pub const max_voices = 8;
/// How often `position` follows playback, in milliseconds.
const position_interval_ms = 50;

/// Plays `source` while `playing` (set it, or call `play()` and `stop()`).
/// `play()` starts the sound again from the start; with `voices` above 1
/// it starts another voice over those still playing (the oldest is cut
/// when there are too many): the same sound in quick succession. Voices
/// rise over `fade_in_ms` and, when stopped, fall over `fade_out_ms`; a
/// new `source` fades in while the old one fades out. Changes apply when
/// change handlers run. Initialize in place with `init`.
pub const AudioElement = struct {
    item: Item = .init(&vtable),
    source: Property(Clip) = .init(.empty),
    /// 0 silent, 1 as recorded.
    volume: Property(f32) = .init(1),
    /// -1 left, 0 center, 1 right.
    pan: Property(f32) = .init(0),
    /// Playback rate: 2 plays twice as fast, an octave up.
    speed: Property(f32) = .init(1),
    loop: Property(bool) = .init(false),
    playing: Property(bool) = .init(false),
    paused: Property(bool) = .init(false),
    voices: Property(i32) = .init(1),
    fade_in_ms: Property(i64) = .init(0),
    fade_out_ms: Property(i64) = .init(0),
    /// Where the newest voice is, in milliseconds; setting it seeks.
    position_ms: Property(i64) = .init(0),
    /// The length of `source`, in milliseconds.
    duration_ms: Property(i64) = .init(0),
    /// Playback ended by itself (not when stopped, and never while
    /// looping).
    finished: Callback(fn () void) = .{},

    /// Voices, playing or fading out after a stop. They do not move (the
    /// mixer reads each one's clip).
    slots: [2 * max_voices]Slot = @splat(.{}),
    /// Counts the voices started (which is the newest).
    started: u32 = 0,
    poll: Timer = .{},
    tracker: ChangeTracker(Settings) = undefined,
    /// The settings the voices follow (what the element itself sets, too).
    applied: Settings = undefined,

    const Slot = struct {
        state: enum { free, playing, releasing } = .free,
        voice: Voice = undefined,
        /// What the voice plays (the source when it started).
        clip: Clip = .empty,
        order: u32 = 0,
    };

    const Settings = struct {
        source: Clip,
        volume: f32,
        pan: f32,
        speed: f32,
        loop: bool,
        playing: bool,
        paused: bool,
        position_ms: i64,
    };

    pub fn init(self: *AudioElement, gpa: Allocator) void {
        self.* = .{};
        self.tracker.init(gpa, self, settings, apply);
        self.applied = .{ .source = .empty, .volume = 1, .pan = 0, .speed = 1, .loop = false, .playing = false, .paused = false, .position_ms = 0 };
        apply(self, self.tracker.value);
    }

    pub fn deinit(self: *AudioElement) void {
        for (&self.slots) |*slot| if (slot.state != .free) self.cut(slot);
        self.tracker.deinit();
        self.poll.deinit();
        self.item.deinit();
        self.source.deinit();
        self.volume.deinit();
        self.pan.deinit();
        self.speed.deinit();
        self.loop.deinit();
        self.playing.deinit();
        self.paused.deinit();
        self.voices.deinit();
        self.fade_in_ms.deinit();
        self.fade_out_ms.deinit();
        self.position_ms.deinit();
        self.duration_ms.deinit();
    }

    /// Plays the sound from the start (over the voices still playing, up
    /// to `voices`).
    pub fn play(self: *AudioElement) void {
        self.start(0);
    }

    /// Stops every voice (fading out over `fade_out_ms`) and goes back to
    /// the start.
    pub fn stop(self: *AudioElement) void {
        self.releaseVoices();
        self.setPlaying(false);
        self.setPosition(0);
    }

    /// How many voices are playing (not fading out after a stop).
    pub fn playingVoices(self: *const AudioElement) usize {
        var n: usize = 0;
        for (self.slots) |slot| n += @intFromBool(slot.state == .playing);
        return n;
    }

    /// The settings now, without depending on them.
    fn current(self: *AudioElement) Settings {
        return .{
            .source = self.source.getUntracked(),
            .volume = self.volume.getUntracked(),
            .pan = self.pan.getUntracked(),
            .speed = self.speed.getUntracked(),
            .loop = self.loop.getUntracked(),
            .playing = self.playing.getUntracked(),
            .paused = self.paused.getUntracked(),
            .position_ms = self.position_ms.getUntracked(),
        };
    }

    fn settings(self: *AudioElement) Settings {
        return .{
            .source = self.source.get(),
            .volume = self.volume.get(),
            .pan = self.pan.get(),
            .speed = self.speed.get(),
            .loop = self.loop.get(),
            .playing = self.playing.get(),
            .paused = self.paused.get(),
            .position_ms = self.position_ms.get(),
        };
    }

    fn apply(self: *AudioElement, s: Settings) void {
        const was = self.applied;
        self.applied = s;
        const m = audio.mixer();
        if (!s.source.eql(was.source)) {
            // The old sound fades out as the new one starts.
            self.releaseVoices();
            self.duration_ms.set(@intCast(s.source.durationMs()));
            self.setPosition(0);
            if (s.playing) self.start(0);
            return;
        }
        if (s.playing != was.playing) {
            if (s.playing) self.start(s.position_ms) else self.stop();
            return;
        }
        for (self.slots) |slot| if (slot.state == .playing) {
            if (s.volume != was.volume) m.setGain(slot.voice, s.volume);
            if (s.pan != was.pan) m.setPan(slot.voice, s.pan);
            if (s.speed != was.speed) m.setSpeed(slot.voice, s.speed);
            if (s.loop != was.loop) m.setLooping(slot.voice, s.loop);
            if (s.paused != was.paused) m.setPaused(slot.voice, s.paused);
        };
        if (s.position_ms != was.position_ms) if (self.newest()) |slot|
            m.seek(slot.voice, frameAt(slot.clip, s.position_ms));
    }

    fn frameAt(clip: Clip, ms: i64) u32 {
        const f = @as(u64, @intCast(@max(ms, 0))) * clip.sample_rate / 1000;
        return @intCast(@min(f, clip.frames()));
    }

    fn milliseconds(p: *Property(i64)) u32 {
        return @intCast(std.math.clamp(p.getUntracked(), 0, std.math.maxInt(u32)));
    }

    /// The voice started last that is still playing.
    fn newest(self: *AudioElement) ?*Slot {
        var best: ?*Slot = null;
        for (&self.slots) |*slot| if (slot.state == .playing and (best == null or slot.order > best.?.order)) {
            best = slot;
        };
        return best;
    }

    /// The voice started first that is in `state`.
    fn oldest(self: *AudioElement, state: @FieldType(Slot, "state")) ?*Slot {
        var best: ?*Slot = null;
        for (&self.slots) |*slot| if (slot.state == state and (best == null or slot.order < best.?.order)) {
            best = slot;
        };
        return best;
    }

    /// Starts a voice at `ms` into the source.
    fn start(self: *AudioElement, ms: i64) void {
        // As set now, even before change handlers run (`play()` right after
        // setting the volume, say).
        const s = self.current();
        self.applied = s;
        const limit: usize = @intCast(std.math.clamp(self.voices.getUntracked(), 1, max_voices));
        while (self.playingVoices() >= limit) self.cut(self.oldest(.playing).?);
        const slot = self.oldest(.free) orelse blk: {
            const fading = self.oldest(.releasing).?;
            self.cut(fading);
            break :blk fading;
        };
        slot.clip = s.source;
        const v = audio.mixer().play(&slot.clip, .{
            .gain = s.volume,
            .pan = s.pan,
            .speed = s.speed,
            .looping = s.loop,
            .paused = s.paused,
            .start = frameAt(s.source, ms),
            .fade_in_ms = milliseconds(&self.fade_in_ms),
        }, .{ .ctx = self, .ended = ended }) orelse {
            // No sound (no output, or nothing to play).
            if (self.playingVoices() == 0) self.setPlaying(false);
            return;
        };
        self.started +%= 1;
        // (Not the clip: the audio thread may be reading it.)
        slot.state = .playing;
        slot.voice = v;
        slot.order = self.started;
        self.setPlaying(true);
        self.setPosition(ms);
        if (!self.poll.isRunning()) self.poll.start(.repeated, position_interval_ms, self, follow);
    }

    /// Stops a voice at once.
    fn cut(self: *AudioElement, slot: *Slot) void {
        _ = self;
        audio.mixer().stop(slot.voice);
        slot.state = .free;
    }

    /// Fades out the voices playing (over `fade_out_ms`).
    fn releaseVoices(self: *AudioElement) void {
        const fade = milliseconds(&self.fade_out_ms);
        for (&self.slots) |*slot| if (slot.state == .playing) {
            if (fade == 0) {
                self.cut(slot);
            } else {
                audio.mixer().release(slot.voice, fade);
                slot.state = .releasing;
            }
        };
        self.poll.stop();
    }

    /// Sets `playing` as the element (not a change to act on). Only when
    /// it changes: a binding (`playing: level == 2`) that started the sound
    /// stays.
    fn setPlaying(self: *AudioElement, on: bool) void {
        self.applied.playing = on;
        if (self.playing.getUntracked() != on) self.playing.set(on);
    }

    fn setPosition(self: *AudioElement, ms: i64) void {
        self.applied.position_ms = ms;
        self.position_ms.set(ms);
    }

    fn follow(self: *AudioElement) void {
        const slot = self.newest() orelse return;
        if (slot.clip.sample_rate == 0) return;
        const frame = audio.mixer().position(slot.voice);
        self.setPosition(@intCast(@as(u64, frame) * 1000 / slot.clip.sample_rate));
    }

    fn ended(ctx: ?*anyopaque, voice: Voice) void {
        const self: *AudioElement = @ptrCast(@alignCast(ctx));
        const slot = for (&self.slots) |*slot| {
            if (slot.state != .free and slot.voice == voice) break slot;
        } else return;
        const was = slot.state;
        slot.state = .free;
        if (was == .releasing or self.playingVoices() > 0) return;
        self.poll.stop();
        self.setPlaying(false);
        self.setPosition(0);
        self.finished.call(.{});
    }

    const vtable: ItemVTable = .{ .name = "Audio" };
};

// ---- Tests ----

const testing = std.testing;
const core = @import("../core.zig");

/// An output the test renders for itself.
const TestOutput = struct {
    fn output() audio.Output {
        return .{ .ctx = null, .vtable = &.{ .start = start, .stop = stopIt } };
    }
    fn start(_: ?*anyopaque, _: *audio.Mixer) audio.Output.Error!u32 {
        return 1000;
    }
    fn stopIt(_: ?*anyopaque) void {}
};

/// Runs `f(el)` (which may wait for voices to end) while another thread
/// renders as the audio device would.
fn whileRendering(el: *AudioElement, comptime f: fn (*AudioElement) void) !void {
    var done: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, struct {
        fn run(d: *std.atomic.Value(bool)) void {
            var buf: [2 * 4]f32 = undefined;
            while (!d.load(.acquire)) audio.mixer().render(&buf);
        }
    }.run, .{&done});
    f(el);
    done.store(true, .release);
    t.join();
}

test "the Audio element plays, follows its properties, finishes and stops" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const m = audio.mixer();
    m.setOutput(TestOutput.output());
    defer m.setOutput(null);
    var data: [200]u8 = @splat(0x20); // 100 frames
    const clip: Clip = .{ .format = .i16, .channels = 1, .sample_rate = 1000, .data = &data };

    var el: AudioElement = undefined;
    el.init(testing.allocator);
    defer el.deinit();
    var finished: usize = 0;
    el.finished.setHandler(&finished, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);
    el.source.set(clip);
    core.runChangeHandlers();
    try testing.expectEqual(@as(i64, 100), el.duration_ms.get());

    // play(): to the end, then `finished`.
    el.play();
    try testing.expect(el.playing.get());
    var buf: [2 * 60]f32 = undefined;
    m.render(&buf);
    core.updateTimersAndAnimations(core.now() + position_interval_ms);
    try testing.expectEqual(@as(i64, 60), el.position_ms.get());
    m.render(&buf);
    core.updateTimersAndAnimations(core.now() + 1);
    try testing.expect(!el.playing.get());
    try testing.expectEqual(@as(usize, 1), finished);
    try testing.expectEqual(@as(i64, 0), el.position_ms.get());

    // `playing` set, looping, seeking: never finishes; stopping.
    el.loop.set(true);
    el.playing.set(true);
    core.runChangeHandlers();
    try testing.expectEqual(@as(usize, 1), el.playingVoices());
    el.position_ms.set(90);
    core.runChangeHandlers();
    m.render(&buf);
    core.updateTimersAndAnimations(core.now() + position_interval_ms);
    try testing.expectEqual(@as(i64, 50), el.position_ms.get()); // 90 + 60 - 100
    try testing.expect(el.playing.get());
    try whileRendering(&el, struct {
        fn f(e: *AudioElement) void {
            e.playing.set(false);
            core.runChangeHandlers();
        }
    }.f);
    try testing.expectEqual(@as(usize, 0), el.playingVoices());
    try testing.expectEqual(@as(usize, 1), finished);

    // Several voices: play() over the one playing, up to `voices`.
    el.loop.set(false);
    el.voices.set(2);
    el.play();
    el.play();
    try whileRendering(&el, AudioElement.play); // cuts the oldest
    try testing.expectEqual(@as(usize, 2), el.playingVoices());
    try whileRendering(&el, AudioElement.stop);
    try testing.expect(!el.playing.get());
    core.updateTimersAndAnimations(core.now() + 1);
    try testing.expectEqual(@as(usize, 1), finished);
}

test "fades: stopping fades out without waiting; a new source crossfades" {
    const m = audio.mixer();
    m.setOutput(TestOutput.output());
    defer m.setOutput(null);
    var a_data: [400]u8 = @splat(0x20);
    var b_data: [400]u8 = @splat(0x10);
    const a: Clip = .{ .format = .i16, .channels = 1, .sample_rate = 1000, .data = &a_data };
    const b: Clip = .{ .format = .i16, .channels = 1, .sample_rate = 1000, .data = &b_data };

    var el: AudioElement = undefined;
    el.init(testing.allocator);
    defer el.deinit();
    var finished: usize = 0;
    el.finished.setHandler(&finished, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);
    el.source.set(a);
    el.loop.set(true);
    el.fade_in_ms.set(20);
    el.fade_out_ms.set(40);
    el.playing.set(true);
    core.runChangeHandlers();
    var buf: [2 * 10]f32 = undefined;
    m.render(&buf);
    try testing.expect(buf[2 * 9] < a.sample(0, 0)); // still rising

    // Another source: the old voice fades out, the new one in.
    el.source.set(b);
    core.runChangeHandlers();
    try testing.expectEqual(@as(usize, 1), el.playingVoices());
    try testing.expectEqual(b.data.ptr, el.newest().?.clip.data.ptr);
    var fading: usize = 0;
    for (el.slots) |slot| fading += @intFromBool(slot.state == .releasing);
    try testing.expectEqual(@as(usize, 1), fading);

    // Stopping returns at once; the voices end after their fade.
    el.stop();
    try testing.expect(!el.playing.get());
    var long: [2 * 100]f32 = undefined;
    m.render(&long);
    try testing.expectEqual(@as(f32, 0), long[2 * 99]);
    core.updateTimersAndAnimations(core.now() + 1);
    for (el.slots) |slot| try testing.expect(slot.state == .free);
    try testing.expect(!m.busy());
    try testing.expectEqual(@as(usize, 0), finished);
}

test "a binding on playing starts and stops the sound, and stays" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const m = audio.mixer();
    m.setOutput(TestOutput.output());
    defer m.setOutput(null);
    var data: [200]u8 = @splat(0x20);
    var el: AudioElement = undefined;
    el.init(testing.allocator);
    defer el.deinit();
    el.source.set(.{ .format = .i16, .channels = 1, .sample_rate = 1000, .data = &data });
    el.loop.set(true);
    var on: Property(bool) = .init(true);
    defer on.deinit();
    try el.playing.setBinding(testing.allocator, &on, struct {
        fn f(p: *Property(bool)) bool {
            return p.get();
        }
    }.f);
    core.runChangeHandlers();
    try testing.expectEqual(@as(usize, 1), el.playingVoices());
    on.set(false);
    try whileRendering(&el, struct {
        fn f(_: *AudioElement) void {
            core.runChangeHandlers();
        }
    }.f);
    try testing.expectEqual(@as(usize, 0), el.playingVoices());
    on.set(true);
    core.runChangeHandlers();
    try testing.expectEqual(@as(usize, 1), el.playingVoices());
    try whileRendering(&el, AudioElement.stop);
}

test "without an output nothing plays" {
    var el: AudioElement = undefined;
    el.init(testing.allocator);
    defer el.deinit();
    var data: [20]u8 = @splat(0);
    el.source.set(.{ .format = .u8, .channels = 1, .sample_rate = 8000, .data = &data });
    el.play();
    try testing.expect(!el.playing.get());
}
