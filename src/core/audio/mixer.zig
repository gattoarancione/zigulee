// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The mixer: voices (clips playing) added up into stereo 32-bit float
//! frames, which an output (a backend's audio device) pulls from its own
//! thread.
//!
//! The UI thread starts and changes voices through commands, handed over
//! in a lock-free queue (one producer, one consumer); the audio thread
//! applies them at the start of each `render` and owns the voices' state.
//! What the UI reads back (playing or not, the position) goes through
//! atomics, and voices that end are reported on the UI thread by `update`.
//! Voices live in fixed slots: mixing never allocates.
//!
//! Changes of gain and pan, starts after a seek, pauses and stops are
//! ramped over a few milliseconds (no clicks). Clips at another sample rate
//! or played at another speed are resampled (linear interpolation).

const std = @import("std");
const Clip = @import("clip.zig").Clip;
const Feed = @import("feed.zig").Feed;

const log = std.log.scoped(.zigulee_audio);

pub const max_voices = 32;
/// Gain changes are spread over this many seconds.
const ramp_seconds = 0.004;

/// A voice: its slot, and which use of the slot (a stale id does nothing).
pub const Voice = packed struct(u32) {
    slot: u8,
    generation: u24,
};

pub const PlayOptions = struct {
    /// 0 silent, 1 as recorded.
    gain: f32 = 1,
    /// -1 left, 0 center, 1 right.
    pan: f32 = 0,
    /// Playback rate (2: an octave up, twice as fast).
    speed: f32 = 1,
    looping: bool = false,
    /// Where to start, in frames of the clip.
    start: u32 = 0,
    paused: bool = false,
    /// Rises from silence over this many milliseconds.
    fade_in_ms: u32 = 0,
};

/// Called on the UI thread (in `update`) when a voice ends by itself or
/// after `release` (not when stopped).
pub const Listener = struct {
    ctx: ?*anyopaque,
    ended: *const fn (ctx: ?*anyopaque, voice: Voice) void,
};

/// A backend's audio output: pulls frames from the mixer.
pub const Output = struct {
    ctx: ?*anyopaque,
    vtable: *const VTable,

    pub const Error = error{AudioUnavailable};

    pub const VTable = struct {
        /// Starts calling `mixer.render` (from any thread, as the device
        /// needs frames); returns the frames per second it plays.
        start: *const fn (ctx: ?*anyopaque, mixer: *Mixer) Error!u32,
        /// Stops; when it returns, no `render` is running or will run.
        stop: *const fn (ctx: ?*anyopaque) void,
    };
};

const Command = struct {
    op: enum { play, stop, gain, pan, speed, looping, paused, seek, master },
    voice: Voice = .{ .slot = 0, .generation = 0 },
    clip: ?*const Clip = null,
    feed: ?*Feed = null,
    value: f32 = 0,
    flag: bool = false,
    frame: u32 = 0,
    /// Seconds a fade takes (play: in; stop: out); 0 for the short ramp.
    fade: f32 = 0,
};

/// Single producer (the UI thread), single consumer (the audio thread).
const Queue = struct {
    const size = 128;
    items: [size]Command = undefined,
    head: std.atomic.Value(u32) = .init(0),
    tail: std.atomic.Value(u32) = .init(0),

    fn push(q: *Queue, c: Command) bool {
        const head = q.head.load(.monotonic);
        if (head -% q.tail.load(.acquire) >= size) return false;
        q.items[head % size] = c;
        q.head.store(head +% 1, .release);
        return true;
    }

    fn pop(q: *Queue) ?Command {
        const tail = q.tail.load(.monotonic);
        if (tail == q.head.load(.acquire)) return null;
        const c = q.items[tail % size];
        q.tail.store(tail +% 1, .release);
        return c;
    }
};

/// A voice's state, owned by the audio thread.
const State = struct {
    active: bool = false,
    generation: u24 = 0,
    clip: *const Clip = &Clip.empty,
    /// Or what it reads as it is written (`position` is then from the
    /// first unread frame).
    feed: ?*Feed = null,
    /// 8-aligned everywhere: Zig aligns f64 to 4 on Xtensa, GCC to 8, and
    /// the ESP32-S3 firmware's C (Zig's) must agree with GCC on sizes.
    position: f64 align(8) = 0,
    speed: f32 = 1,
    looping: bool = false,
    paused: bool = false,
    stopping: bool = false,
    gain: f32 = 1,
    pan: f32 = 0,
    /// Fading (in or out) by `fade_step` a frame, not the short ramp.
    fading: bool = false,
    fade_step: f32 = 0,
    /// Where the ramps are now.
    level: f32 = 0,
    left: f32 = 1,
    right: f32 = 1,
};

pub const Mixer = struct {
    output: ?Output = null,
    running: bool = false,
    /// Frames per second of the output.
    sample_rate: u32 = 48000,
    queue: Queue = .{},
    states: [max_voices]State = @splat(.{}),
    master: f32 = 1,

    // The UI thread's side: which slots are in use, by which generation.
    owned: [max_voices]bool = @splat(false),
    generations: [max_voices]u24 = @splat(0),
    listeners: [max_voices]?Listener = @splat(null),
    /// The data each slot's clip reads (empty for feeds).
    data: [max_voices][]const u8 = @splat(&.{}),

    // Read back by the UI thread.
    /// The generation each slot's voice last ended (by itself or stopped).
    ended: [max_voices]std.atomic.Value(u32) = @splat(.init(0)),
    /// Each slot's position, in frames of its clip.
    positions: [max_voices]std.atomic.Value(u32) = @splat(.init(0)),

    // ---- The UI thread ----

    /// The output to play through (null: none); stops the current one.
    pub fn setOutput(m: *Mixer, output: ?Output) void {
        if (m.running) {
            m.output.?.vtable.stop(m.output.?.ctx);
            m.running = false;
            // Nothing plays any more: every voice has ended.
            m.drain();
            for (&m.states, 0..) |*s, i| if (s.active) {
                s.active = false;
                m.ended[i].store(s.generation, .release);
            };
        }
        m.output = output;
    }

    /// Starts the output if it is not running; false if there is none or
    /// it fails.
    fn ensureRunning(m: *Mixer) bool {
        if (m.running) return true;
        const out = m.output orelse return false;
        m.drain(); // nobody else is applying commands
        m.sample_rate = out.vtable.start(out.ctx, m) catch |err| {
            log.info("audio output unavailable: {t}", .{err});
            m.output = null;
            return false;
        };
        m.running = true;
        return true;
    }

    fn send(m: *Mixer, c: Command) bool {
        if (!m.running) {
            // No audio thread: apply it here (only stale voices are left).
            m.apply(c);
            return true;
        }
        return m.queue.push(c);
    }

    /// Plays `clip` (which must outlive the voice); null if there is no
    /// output or no free voice.
    pub fn play(m: *Mixer, clip: *const Clip, options: PlayOptions, listener: ?Listener) ?Voice {
        if (clip.frames() == 0 or !m.ensureRunning()) return null;
        const v = m.claim(listener) orelse return null;
        const slot = v.slot;
        m.data[slot] = clip.data;
        m.positions[slot].store(@min(options.start, clip.frames()), .monotonic);
        const fade = @as(f32, @floatFromInt(options.fade_in_ms)) / 1000;
        const ok = m.send(.{ .op = .play, .voice = v, .clip = clip, .value = options.gain, .frame = options.start, .flag = options.looping, .fade = fade }) and
            m.send(.{ .op = .pan, .voice = v, .value = options.pan }) and
            m.send(.{ .op = .speed, .voice = v, .value = options.speed }) and
            m.send(.{ .op = .paused, .voice = v, .flag = options.paused });
        if (!ok) {
            m.owned[slot] = false;
            return null;
        }
        return v;
    }

    /// Plays what is written to `feed` (which must outlive the voice), as
    /// it is written; the voice ends when the feed is finished and read.
    /// Its position is the frames read. `start` and `looping` do not apply.
    pub fn playFeed(m: *Mixer, feed: *Feed, options: PlayOptions, listener: ?Listener) ?Voice {
        if (!m.ensureRunning()) return null;
        const v = m.claim(listener) orelse return null;
        m.positions[v.slot].store(0, .monotonic);
        const fade = @as(f32, @floatFromInt(options.fade_in_ms)) / 1000;
        const ok = m.send(.{ .op = .play, .voice = v, .feed = feed, .value = options.gain, .fade = fade }) and
            m.send(.{ .op = .pan, .voice = v, .value = options.pan }) and
            m.send(.{ .op = .speed, .voice = v, .value = options.speed }) and
            m.send(.{ .op = .paused, .voice = v, .flag = options.paused });
        if (!ok) {
            m.owned[v.slot] = false;
            return null;
        }
        return v;
    }

    /// A free voice slot, for a new voice.
    fn claim(m: *Mixer, listener: ?Listener) ?Voice {
        const slot = for (m.owned, 0..) |o, i| {
            if (!o) break i;
        } else {
            log.info("no free voice ({d} playing)", .{max_voices});
            return null;
        };
        m.data[slot] = &.{};
        m.generations[slot] +%= 1;
        if (m.generations[slot] == 0) m.generations[slot] = 1;
        m.owned[slot] = true;
        m.listeners[slot] = listener;
        return .{ .slot = @intCast(slot), .generation = m.generations[slot] };
    }

    fn mine(m: *const Mixer, v: Voice) bool {
        return v.slot < max_voices and m.owned[v.slot] and m.generations[v.slot] == v.generation;
    }

    /// Stops a voice (fading out over a few milliseconds); when it returns,
    /// the mixer no longer reads the voice's clip.
    pub fn stop(m: *Mixer, v: Voice) void {
        if (!m.mine(v)) return;
        if (m.running) {
            while (!m.queue.push(.{ .op = .stop, .voice = v })) std.atomic.spinLoopHint();
            m.waitEnded(v);
        }
        m.owned[v.slot] = false;
        m.listeners[v.slot] = null;
    }

    /// Stops every voice whose clip reads `data` (before it is freed).
    pub fn stopReading(m: *Mixer, data: []const u8) void {
        if (data.len == 0) return;
        const lo = @intFromPtr(data.ptr);
        const hi = lo + data.len;
        for (0..max_voices) |i| {
            if (!m.owned[i]) continue;
            const d = m.data[i];
            if (d.len == 0 or @intFromPtr(d.ptr) >= hi or @intFromPtr(d.ptr) + d.len <= lo) continue;
            m.stop(.{ .slot = @intCast(i), .generation = m.generations[i] });
        }
    }

    /// Fades a voice out over `fade_ms` and ends it, without waiting: it
    /// is playing (and reads its clip) until then, and its listener is told
    /// when it ends. `stop` still ends it at once.
    pub fn release(m: *Mixer, v: Voice, fade_ms: u32) void {
        if (m.mine(v)) _ = m.send(.{ .op = .stop, .voice = v, .fade = @as(f32, @floatFromInt(fade_ms)) / 1000 });
    }

    pub fn setGain(m: *Mixer, v: Voice, gain: f32) void {
        if (m.mine(v)) _ = m.send(.{ .op = .gain, .voice = v, .value = gain });
    }
    pub fn setPan(m: *Mixer, v: Voice, pan: f32) void {
        if (m.mine(v)) _ = m.send(.{ .op = .pan, .voice = v, .value = pan });
    }
    pub fn setSpeed(m: *Mixer, v: Voice, speed: f32) void {
        if (m.mine(v)) _ = m.send(.{ .op = .speed, .voice = v, .value = speed });
    }
    pub fn setLooping(m: *Mixer, v: Voice, looping: bool) void {
        if (m.mine(v)) _ = m.send(.{ .op = .looping, .voice = v, .flag = looping });
    }
    pub fn setPaused(m: *Mixer, v: Voice, paused: bool) void {
        if (m.mine(v)) _ = m.send(.{ .op = .paused, .voice = v, .flag = paused });
    }
    /// Moves a voice to `frame` of its clip.
    pub fn seek(m: *Mixer, v: Voice, frame: u32) void {
        if (!m.mine(v)) return;
        m.positions[v.slot].store(frame, .monotonic);
        _ = m.send(.{ .op = .seek, .voice = v, .frame = frame });
    }
    /// The gain of everything.
    pub fn setMasterGain(m: *Mixer, gain: f32) void {
        _ = m.send(.{ .op = .master, .value = gain });
    }

    /// Whether a voice is still playing (or paused).
    pub fn isPlaying(m: *const Mixer, v: Voice) bool {
        return m.mine(v) and m.ended[v.slot].load(.acquire) != v.generation;
    }

    /// A voice's position in frames of its clip (as of the last `render`).
    pub fn position(m: *const Mixer, v: Voice) u32 {
        if (!m.mine(v)) return 0;
        return m.positions[v.slot].load(.monotonic);
    }

    /// Frees the voices that ended and tells their listeners. Call on the
    /// UI thread once per event loop iteration (`updateTimersAndAnimations`
    /// does).
    pub fn update(m: *Mixer) void {
        for (0..max_voices) |i| {
            if (!m.owned[i] or m.ended[i].load(.acquire) != m.generations[i]) continue;
            m.owned[i] = false;
            const listener = m.listeners[i];
            m.listeners[i] = null;
            if (listener) |l| l.ended(l.ctx, .{ .slot = @intCast(i), .generation = m.generations[i] });
        }
    }

    /// Whether any voice is playing (the event loop keeps waking up for
    /// `update` while one is).
    pub fn busy(m: *const Mixer) bool {
        for (m.owned) |o| if (o) return true;
        return false;
    }

    /// Waits until the audio thread has finished a voice (its fade out
    /// takes a few milliseconds, plus the time until the device next needs
    /// frames).
    fn waitEnded(m: *Mixer, v: Voice) void {
        var spins: u64 = 0;
        while (m.ended[v.slot].load(.acquire) != v.generation) : (spins += 1) {
            if (spins > 200_000_000) {
                log.info("the audio thread did not answer: going on", .{});
                return;
            }
            std.atomic.spinLoopHint();
        }
    }

    // ---- The audio thread ----

    fn drain(m: *Mixer) void {
        while (m.queue.pop()) |c| m.apply(c);
    }

    fn apply(m: *Mixer, c: Command) void {
        if (c.op == .master) {
            m.master = c.value;
            return;
        }
        const s = &m.states[c.voice.slot];
        if (c.op == .play) {
            const clip = c.clip orelse &Clip.empty;
            s.* = .{
                .active = true,
                .generation = c.voice.generation,
                .clip = clip,
                .feed = c.feed,
                .position = if (c.feed == null) @floatFromInt(@min(c.frame, clip.frames())) else 0,
                .looping = c.flag and c.feed == null,
                .gain = c.value,
            };
            m.startFade(s, c.value, c.fade);
            return;
        }
        if (!s.active or s.generation != c.voice.generation) return;
        switch (c.op) {
            .stop => {
                s.stopping = true;
                m.startFade(s, s.level, c.fade);
            },
            .gain => s.gain = c.value,
            .pan => s.pan = std.math.clamp(c.value, -1, 1),
            .speed => s.speed = @max(0, c.value),
            .looping => s.looping = c.flag,
            .paused => s.paused = c.flag,
            .seek => if (s.feed == null) {
                s.position = @floatFromInt(@min(c.frame, s.clip.frames()));
            },
            .play, .master => unreachable,
        }
    }

    /// Moves the level by `span` over `seconds` (0: the short ramp).
    fn startFade(m: *const Mixer, s: *State, span: f32, seconds: f32) void {
        s.fading = seconds > 0 and span > 0;
        if (s.fading) s.fade_step = span / (seconds * @as(f32, @floatFromInt(m.sample_rate)));
    }

    /// Mixes the next `out.len / 2` stereo frames into `out` (replacing
    /// what is there). Called by the output, from its thread.
    pub fn render(m: *Mixer, out: []f32) void {
        @memset(out, 0);
        m.drain();
        const frames = out.len / 2;
        const step_level = 1 / (ramp_seconds * @as(f32, @floatFromInt(m.sample_rate)));
        for (&m.states, 0..) |*s, slot| {
            if (!s.active) continue;
            const clip = s.clip;
            const n = clip.frames();
            const rate_step = @as(f64, @floatFromInt(clip.sample_rate)) / @as(f64, @floatFromInt(m.sample_rate));
            const feed_step = if (s.feed) |feed| @as(f64, @floatFromInt(feed.sample_rate)) / @as(f64, @floatFromInt(m.sample_rate)) else 0;
            const target_left = @min(1, 1 - s.pan);
            const target_right = @min(1, 1 + s.pan);
            for (0..frames) |f| {
                const target = if (s.paused or s.stopping) 0 else s.gain;
                s.level = toward(s.level, target, if (s.fading) s.fade_step else step_level);
                if (s.fading and s.level == target and !s.stopping) s.fading = false;
                s.left = toward(s.left, target_left, step_level);
                s.right = toward(s.right, target_right, step_level);
                if (s.stopping and s.level == 0) {
                    s.active = false;
                    break;
                }
                if (s.paused and s.level == 0) continue;
                if (s.feed) |feed| {
                    // As written: wait for frames (silence) unless the
                    // writer is done.
                    const avail = feed.available();
                    const i: usize = @intFromFloat(@floor(s.position));
                    if (i + 1 >= avail) {
                        if (feed.finished.load(.acquire)) {
                            feed.consume(avail);
                            s.active = false;
                            break;
                        }
                        continue;
                    }
                    const frac: f32 = @floatCast(s.position - @floor(s.position));
                    out[2 * f] += lerp(feed.at(i, 0), feed.at(i + 1, 0), frac) * s.level * s.left;
                    out[2 * f + 1] += lerp(feed.at(i, 1), feed.at(i + 1, 1), frac) * s.level * s.right;
                    s.position += feed_step * s.speed;
                    const whole = @floor(s.position);
                    feed.consume(@intFromFloat(whole));
                    s.position -= whole;
                    continue;
                }
                const i: u32 = @intFromFloat(@floor(s.position));
                const frac: f32 = @floatCast(s.position - @floor(s.position));
                const j = if (i + 1 < n) i + 1 else if (s.looping) 0 else i;
                const l = lerp(clip.sample(i, 0), clip.sample(j, 0), frac);
                const r = lerp(clip.sample(i, 1), clip.sample(j, 1), frac);
                out[2 * f] += l * s.level * s.left;
                out[2 * f + 1] += r * s.level * s.right;
                s.position += rate_step * s.speed;
                if (s.position >= @as(f64, @floatFromInt(n))) {
                    if (s.looping) {
                        s.position = @mod(s.position, @as(f64, @floatFromInt(n)));
                    } else {
                        s.active = false;
                        break;
                    }
                }
            }
            if (s.feed) |feed| {
                m.positions[slot].store(@truncate(feed.read.load(.monotonic)), .monotonic);
            } else m.positions[slot].store(@intFromFloat(@min(s.position, @as(f64, @floatFromInt(n)))), .monotonic);
            if (!s.active) m.ended[slot].store(s.generation, .release);
        }
        for (out) |*x| x.* = std.math.clamp(x.* * m.master, -1, 1);
    }
};

fn toward(v: f32, target: f32, step: f32) f32 {
    return if (v < target) @min(target, v + step) else @max(target, v - step);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

// ---- Tests ----

const testing = std.testing;

/// An output that does nothing: the test calls `render` itself.
const TestOutput = struct {
    rate: u32,
    started: u32 = 0,
    stopped: u32 = 0,

    fn output(t: *TestOutput) Output {
        return .{ .ctx = t, .vtable = &.{ .start = start, .stop = stopIt } };
    }
    fn start(ctx: ?*anyopaque, _: *Mixer) Output.Error!u32 {
        const t: *TestOutput = @ptrCast(@alignCast(ctx));
        t.started += 1;
        return t.rate;
    }
    fn stopIt(ctx: ?*anyopaque) void {
        const t: *TestOutput = @ptrCast(@alignCast(ctx));
        t.stopped += 1;
    }
};

/// Stops `v` the way the UI thread does, while this thread renders as the
/// audio thread would.
fn stopRendering(m: *Mixer, v: Voice) !void {
    var done: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, struct {
        fn run(mx: *Mixer, voice: Voice, d: *std.atomic.Value(bool)) void {
            mx.stop(voice);
            d.store(true, .release);
        }
    }.run, .{ m, v, &done });
    var buf: [2 * 4]f32 = undefined;
    while (!done.load(.acquire)) m.render(&buf);
    t.join();
}

/// A constant clip: `frames` frames of `value` (16-bit mono).
fn constant(buf: []u8, value: i16) Clip {
    var i: usize = 0;
    while (i + 2 <= buf.len) : (i += 2) std.mem.writeInt(i16, buf[i..][0..2], value, .little);
    return .{ .format = .i16, .channels = 1, .sample_rate = 1000, .data = buf };
}

test "a voice plays to its end, ramped in, and is reported ended" {
    var out_dev: TestOutput = .{ .rate = 1000 };
    var m: Mixer = .{};
    m.setOutput(out_dev.output());
    var data: [200]u8 = undefined; // 100 frames
    const clip = constant(&data, 16384); // 0.5
    var ended: u32 = 0;
    const listener: Listener = .{ .ctx = &ended, .ended = struct {
        fn f(ctx: ?*anyopaque, _: Voice) void {
            const n: *u32 = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    }.f };
    const v = m.play(&clip, .{}, listener).?;
    try testing.expectEqual(@as(u32, 1), out_dev.started);
    try testing.expect(m.isPlaying(v));

    var buf: [2 * 60]f32 = undefined;
    m.render(&buf);
    // Ramped in over 4 frames (4 ms at 1000 Hz), then 0.5 on both sides.
    try testing.expect(buf[0] > 0 and buf[0] < 0.5);
    try testing.expectEqual(@as(f32, 0.5), buf[2 * 10]);
    try testing.expectEqual(@as(f32, 0.5), buf[2 * 10 + 1]);
    try testing.expectEqual(@as(u32, 60), m.position(v));
    m.render(&buf);
    // 40 frames left, then silence; ended.
    try testing.expectEqual(@as(f32, 0.5), buf[2 * 39]);
    try testing.expectEqual(@as(f32, 0), buf[2 * 41]);
    try testing.expect(!m.isPlaying(v));
    m.update();
    try testing.expectEqual(@as(u32, 1), ended);
    try testing.expect(!m.busy());
}

test "gain, pan, pause, stop; looping; resampling" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var out_dev: TestOutput = .{ .rate = 1000 };
    var m: Mixer = .{};
    m.setOutput(out_dev.output());
    var data: [40]u8 = undefined; // 20 frames
    const clip = constant(&data, 16384);
    const v = m.play(&clip, .{ .gain = 0.5, .pan = 1, .looping = true }, null).?;
    var buf: [2 * 30]f32 = undefined;
    m.render(&buf);
    // Panned right: the left side is silent; looping past the end.
    try testing.expectEqual(@as(f32, 0), buf[2 * 25]);
    try testing.expectEqual(@as(f32, 0.25), buf[2 * 25 + 1]);
    try testing.expect(m.isPlaying(v));

    m.setPaused(v, true);
    m.render(&buf);
    try testing.expectEqual(@as(f32, 0), buf[2 * 10 + 1]); // faded out
    const at = m.position(v);
    m.render(&buf);
    try testing.expectEqual(at, m.position(v)); // held

    m.setPaused(v, false);
    m.setSpeed(v, 2);
    m.render(buf[0 .. 2 * 7]); // 14 frames of the clip: not whole loops
    try testing.expect(m.position(v) != at);
    try stopRendering(&m, v);
    try testing.expect(!m.isPlaying(v));
    m.render(&buf);
    try testing.expectEqual(@as(f32, 0), buf[2 * 10 + 1]);

    // A clip at half the output's rate lasts twice as long.
    var slow_data: [20]u8 = undefined; // 10 frames at 500 Hz
    var slow = constant(&slow_data, 16384);
    slow.sample_rate = 500;
    const w = m.play(&slow, .{}, null).?;
    var long: [2 * 25]f32 = undefined;
    m.render(&long);
    try testing.expectEqual(@as(f32, 0.5), long[2 * 19]);
    try testing.expectEqual(@as(f32, 0), long[2 * 21]);
    try testing.expect(!m.isPlaying(w));
    m.update();
}

test "voices add up and are clamped; stale and spare voices" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var out_dev: TestOutput = .{ .rate = 1000 };
    var m: Mixer = .{};
    m.setOutput(out_dev.output());
    var data: [200]u8 = undefined;
    const clip = constant(&data, 24576); // 0.75
    const a = m.play(&clip, .{}, null).?;
    _ = m.play(&clip, .{}, null).?;
    var buf: [2 * 20]f32 = undefined;
    m.render(&buf);
    try testing.expectEqual(@as(f32, 1), buf[2 * 10]); // 1.5, clamped
    try stopRendering(&m, a);
    m.stop(a); // stale: nothing
    m.setGain(a, 0.1);
    // All voices taken: the next one is refused.
    var playing: usize = 1;
    while (m.play(&clip, .{ .looping = true }, null) != null) playing += 1;
    try testing.expectEqual(@as(usize, max_voices), playing);
    m.setOutput(null);
    try testing.expectEqual(@as(u32, 1), out_dev.stopped);
}

test "no output: nothing plays" {
    var m: Mixer = .{};
    var data: [20]u8 = undefined;
    const clip = constant(&data, 1);
    try testing.expectEqual(@as(?Voice, null), m.play(&clip, .{}, null));
}

test "the command queue, across threads" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var q: Queue = .{};
    const n = 100_000;
    const Consumer = struct {
        fn run(queue: *Queue, sum: *u64) void {
            var got: u32 = 0;
            while (got < n) {
                if (queue.pop()) |c| {
                    sum.* += c.frame;
                    got += 1;
                } else std.atomic.spinLoopHint();
            }
        }
    };
    var sum: u64 = 0;
    const t = try std.Thread.spawn(.{}, Consumer.run, .{ &q, &sum });
    var i: u32 = 0;
    while (i < n) {
        if (q.push(.{ .op = .seek, .frame = i })) i += 1 else std.atomic.spinLoopHint();
    }
    t.join();
    try testing.expectEqual(@as(u64, n * (n - 1) / 2), sum);
}

test "fades in and out" {
    var out_dev: TestOutput = .{ .rate = 1000 };
    var m: Mixer = .{};
    m.setOutput(out_dev.output());
    var data: [400]u8 = undefined; // 200 frames
    const clip = constant(&data, 16384); // 0.5
    var ended: u32 = 0;
    const v = m.play(&clip, .{ .fade_in_ms = 40 }, .{ .ctx = &ended, .ended = struct {
        fn f(ctx: ?*anyopaque, _: Voice) void {
            const n: *u32 = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    }.f }).?;
    var buf: [2 * 50]f32 = undefined;
    m.render(&buf);
    // Rising over 40 frames, then steady.
    try testing.expectApproxEqAbs(@as(f32, 0.25), buf[2 * 19], 0.001);
    try testing.expectEqual(@as(f32, 0.5), buf[2 * 45]);
    // Released: falls over 20 frames, without waiting; the listener is told.
    m.release(v, 20);
    try testing.expect(m.isPlaying(v));
    m.render(&buf);
    try testing.expectApproxEqAbs(@as(f32, 0.25), buf[2 * 9], 0.001);
    try testing.expectEqual(@as(f32, 0), buf[2 * 25]);
    try testing.expect(!m.isPlaying(v));
    m.update();
    try testing.expectEqual(@as(u32, 1), ended);
}

test "a feed voice plays what is written, waits when it runs out, ends when finished" {
    var out_dev: TestOutput = .{ .rate = 1000 };
    var m: Mixer = .{};
    m.setOutput(out_dev.output());
    var feed: Feed = try .init(testing.allocator, 64, 1000);
    defer feed.deinit(testing.allocator);
    var ended: u32 = 0;
    const v = m.playFeed(&feed, .{}, .{ .ctx = &ended, .ended = struct {
        fn f(ctx: ?*anyopaque, _: Voice) void {
            const n: *u32 = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    }.f }).?;
    var frames: [2 * 20]f32 = @splat(0.5);
    _ = feed.write(&frames);
    var buf: [2 * 30]f32 = undefined;
    m.render(&buf);
    try testing.expectEqual(@as(f32, 0.5), buf[2 * 10]);
    try testing.expectEqual(@as(f32, 0), buf[2 * 25]); // ran out: silence
    try testing.expect(m.isPlaying(v)); // waiting for more
    try testing.expectEqual(@as(u32, 19), m.position(v));
    _ = feed.write(frames[0..10]);
    feed.finish();
    m.render(&buf);
    try testing.expect(!m.isPlaying(v));
    m.update();
    try testing.expectEqual(@as(u32, 1), ended);
}
