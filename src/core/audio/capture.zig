// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Sound from the microphone: a backend's input (`setInput`) captures it
//! on its own thread into a ring buffer; `update` (from
//! `updateTimersAndAnimations`) hands it on the UI thread to the
//! `Microphone` elements, which show its level and record it.
//!
//! The input runs while a `Microphone` is `active` or recording, and
//! stops when none is. Recordings are mono, 16-bit, at the input's rate:
//! a clip (`recorded`) that an `Audio` element plays, or a WAV file
//! (`save-recording`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("../properties.zig").Property;
const ChangeTracker = @import("../properties.zig").ChangeTracker;
const Callback = @import("../callbacks.zig").Callback;
const item_mod = @import("../item.zig");
const Clip = @import("clip.zig").Clip;
const wav = @import("wav.zig");
const audio = @import("audio.zig");

const log = std.log.scoped(.zigulee_audio);

/// A backend's audio input.
pub const Input = struct {
    ctx: ?*anyopaque,
    vtable: *const VTable,

    pub const Error = error{AudioUnavailable};

    pub const VTable = struct {
        /// Starts calling `sink.write` (from any thread) with captured
        /// frames; returns the frames per second it captures.
        start: *const fn (ctx: ?*anyopaque, sink: *const Sink) Error!u32,
        /// Stops; when it returns, `sink.write` is not running and will
        /// not be called.
        stop: *const fn (ctx: ?*anyopaque) void,
    };

    pub const Sink = struct {
        ctx: ?*anyopaque,
        /// `samples` interleaved, `channels` per frame.
        write: *const fn (ctx: ?*anyopaque, samples: []const f32, channels: u8) void,
    };
};

/// Mono samples, from the capture thread (one producer) to the UI thread
/// (one consumer). When it is full, new samples are dropped. Allocated
/// when the input first starts (half a megabyte: not in every program).
const Ring = struct {
    const size = 1 << 17; // nearly 3 s at 48 kHz
    samples: []f32 = &.{},
    head: std.atomic.Value(u32) = .init(0),
    tail: std.atomic.Value(u32) = .init(0),

    fn write(r: *Ring, samples: []const f32, channels: u8) void {
        if (r.samples.len == 0) return;
        var head = r.head.load(.monotonic);
        const tail = r.tail.load(.acquire);
        const ch: usize = @max(channels, 1);
        var i: usize = 0;
        while (i + ch <= samples.len) : (i += ch) {
            if (head -% tail >= size) break;
            var sum: f32 = 0;
            for (samples[i..][0..ch]) |s| sum += s;
            r.samples[head % size] = sum / @as(f32, @floatFromInt(ch));
            head +%= 1;
        }
        r.head.store(head, .release);
    }

    /// Up to `out.len` samples: how many.
    fn read(r: *Ring, out: []f32) usize {
        var tail = r.tail.load(.monotonic);
        const head = r.head.load(.acquire);
        var n: usize = 0;
        while (n < out.len and tail != head) : (n += 1) {
            out[n] = r.samples[tail % size];
            tail +%= 1;
        }
        r.tail.store(tail, .release);
        return n;
    }

    fn clear(r: *Ring) void {
        r.tail.store(r.head.load(.acquire), .release);
    }
};

var input: ?Input = null;
var running = false;
var rate: u32 = 48000;
var ring: Ring = .{};
const sink: Input.Sink = .{ .ctx = null, .write = sinkWrite };
var mics: std.ArrayList(*Microphone) = .empty;
var gpa_used: ?Allocator = null;

fn sinkWrite(_: ?*anyopaque, samples: []const f32, channels: u8) void {
    ring.write(samples, channels);
}

/// The input to capture from (null: none); stops the current one.
pub fn setInput(i: ?Input) void {
    if (running) {
        input.?.vtable.stop(input.?.ctx);
        running = false;
    }
    input = i;
    for (mics.items) |m| m.available.set(i != null);
    refresh();
}

pub fn hasInput() bool {
    return input != null;
}

/// Whether the input runs (the event loop keeps waking up for `update`).
pub fn busy() bool {
    return running;
}

/// Starts or stops the input as the microphones need.
fn refresh() void {
    const wanted = for (mics.items) |m| {
        if (m.wantsInput()) break true;
    } else false;
    if (wanted == running) return;
    const in = input orelse return;
    if (!wanted) {
        in.vtable.stop(in.ctx);
        running = false;
        return;
    }
    if (ring.samples.len == 0) {
        const gpa = gpa_used orelse return;
        ring.samples = gpa.alloc(f32, Ring.size) catch {
            log.warn("no memory for the microphone's buffer", .{});
            return;
        };
    }
    ring.clear();
    rate = in.vtable.start(in.ctx, &sink) catch |err| {
        log.info("no microphone: {t}", .{err});
        return;
    };
    running = true;
}

/// Hands what was captured to the microphones. Call on the UI thread once
/// per event loop iteration.
pub fn update() void {
    if (!running) return;
    // Small (read in a loop): it is on the stack of every event loop
    // iteration, a microcontroller's too.
    var buf: [256]f32 = undefined;
    var any = false;
    while (true) {
        const n = ring.read(&buf);
        if (n == 0) break;
        any = true;
        for (mics.items) |m| m.take(buf[0..n]);
    }
    if (!any) for (mics.items) |m| m.take(&.{});
}

// ---- The element ----

/// The longest recording, in seconds (then it stops by itself).
pub const max_seconds = 10 * 60;

/// The microphone (`Microphone`): while `active`, `level` follows how
/// loud it is; `record()` keeps what it hears until `stop()`, then
/// `recorded` is that sound and `finished` is called. Not drawn.
/// Initialize in place with `init`.
pub const Microphone = struct {
    item: item_mod.Item = .init(&vtable),
    active: Property(bool) = .init(false),
    recording: Property(bool) = .init(false),
    /// The loudest recent sample, 0 to 1 (falling off slowly).
    level: Property(f32) = .init(0),
    /// How long the recording is (so far, while recording).
    duration_ms: Property(i64) = .init(0),
    /// The last recording.
    recorded: Property(Clip) = .init(.empty),
    /// There is a microphone input (the platform's, through the backend).
    available: Property(bool) = .init(false),
    finished: Callback(fn () void) = .{},

    gpa: Allocator = undefined,
    tracker: ChangeTracker(bool) = undefined,
    /// What is being recorded.
    samples: std.ArrayList(i16) = .empty,
    /// The samples `recorded` reads.
    owned: []i16 = &.{},
    is_recording: bool = false,

    pub fn init(self: *Microphone, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.available.set(hasInput());
        gpa_used = gpa;
        mics.append(gpa, self) catch {};
        self.tracker.init(gpa, self, activeNow, activeChanged);
    }

    pub fn deinit(self: *Microphone) void {
        for (mics.items, 0..) |m, i| if (m == self) {
            _ = mics.orderedRemove(i);
            break;
        };
        refresh();
        if (mics.items.len == 0) {
            mics.deinit(self.gpa);
            mics = .empty;
            // Stopped: nothing writes to it any more.
            self.gpa.free(ring.samples);
            ring.samples = &.{};
        }
        self.tracker.deinit();
        audio.mixer().stopReading(std.mem.sliceAsBytes(self.owned));
        self.gpa.free(self.owned);
        self.samples.deinit(self.gpa);
        self.item.deinit();
        inline for (.{ "active", "recording", "level", "duration_ms", "recorded", "available" }) |f| @field(self, f).deinit();
    }

    fn activeNow(self: *Microphone) bool {
        return self.active.get();
    }

    fn activeChanged(self: *Microphone, _: bool) void {
        refresh();
        if (!self.wantsInput()) self.level.set(0);
    }

    fn wantsInput(self: *Microphone) bool {
        return self.active.getUntracked() or self.is_recording;
    }

    /// Starts recording (again, from nothing).
    pub fn record(self: *Microphone) void {
        if (!hasInput()) log.info("no microphone here: nothing is recorded", .{});
        self.samples.clearRetainingCapacity();
        self.is_recording = true;
        self.recording.set(true);
        self.duration_ms.set(0);
        refresh();
    }

    /// Stops recording: `recorded` is what was heard, then `finished` is
    /// called.
    pub fn stop(self: *Microphone) void {
        if (!self.is_recording) return;
        self.is_recording = false;
        refresh();
        if (!self.wantsInput()) self.level.set(0);
        const samples: []i16 = self.samples.toOwnedSlice(self.gpa) catch &.{};
        // The old recording may be playing.
        audio.mixer().stopReading(std.mem.sliceAsBytes(self.owned));
        self.gpa.free(self.owned);
        self.owned = samples;
        self.recorded.set(.{ .format = .i16, .channels = 1, .sample_rate = rate, .data = std.mem.sliceAsBytes(samples) });
        self.recording.set(false);
        self.finished.call(.{});
    }

    /// Writes the last recording to `path` as a WAV file.
    pub fn saveRecording(self: *Microphone, path: []const u8) void {
        const bytes = wav.encode16(self.gpa, self.owned, 1, self.recorded.getUntracked().sample_rate) catch return;
        defer self.gpa.free(bytes);
        @import("../settings.zig").writeFile(self.gpa, path, bytes) catch |err|
            log.warn("cannot save the recording to '{s}': {t}", .{ path, err });
    }

    /// Captured samples (none: a moment without any).
    fn take(self: *Microphone, samples: []const f32) void {
        if (!self.wantsInput()) return;
        var peak: f32 = 0;
        for (samples) |s| peak = @max(peak, @abs(s));
        const old = self.level.getUntracked();
        self.level.set(@min(1, @max(peak, old * 0.85)));
        if (!self.is_recording) return;
        for (samples) |s| {
            const v: i16 = @intFromFloat(std.math.clamp(s, -1, 1) * 32767);
            self.samples.append(self.gpa, v) catch return self.stop();
        }
        self.duration_ms.set(@intCast(self.samples.items.len * 1000 / rate));
        if (self.samples.items.len >= @as(usize, max_seconds) * rate) self.stop();
    }

    const vtable: item_mod.ItemVTable = .{ .name = "Microphone" };
};

// ---- Tests ----

const testing = std.testing;

/// An input that writes what the test gives it, at 8 kHz stereo.
const FakeInput = struct {
    started: bool = false,
    sink: ?*const Input.Sink = null,

    fn input(self: *FakeInput) Input {
        return .{ .ctx = self, .vtable = &.{ .start = start, .stop = stopIt } };
    }
    fn start(ctx: ?*anyopaque, s: *const Input.Sink) Input.Error!u32 {
        const self: *FakeInput = @ptrCast(@alignCast(ctx));
        self.started = true;
        self.sink = s;
        return 8000;
    }
    fn stopIt(ctx: ?*anyopaque) void {
        const self: *FakeInput = @ptrCast(@alignCast(ctx));
        self.started = false;
        self.sink = null;
    }
    fn hear(self: *FakeInput, value: f32, frames: usize) void {
        var buf: [256]f32 = undefined;
        var left = frames;
        while (left > 0) {
            const n: usize = @min(left, buf.len / 2);
            @memset(buf[0 .. n * 2], value);
            self.sink.?.write(self.sink.?.ctx, buf[0 .. n * 2], 2);
            left -= n;
        }
    }
};

test "a microphone: its level while active, a recording, saved" {
    var fake: FakeInput = .{};
    var mic: Microphone = undefined;
    mic.init(testing.allocator);
    defer mic.deinit();
    try testing.expect(!mic.available.get());
    setInput(fake.input());
    defer setInput(null);
    try testing.expect(mic.available.get());
    var finished: usize = 0;
    mic.finished.setHandler(&finished, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);

    mic.active.set(true);
    @import("../properties.zig").runChangeHandlers();
    try testing.expect(fake.started);
    fake.hear(0.5, 100);
    update();
    try testing.expectApproxEqAbs(@as(f32, 0.5), mic.level.get(), 0.001);
    update(); // quiet: it falls off
    try testing.expect(mic.level.get() < 0.5);

    mic.record();
    try testing.expect(mic.recording.get());
    fake.hear(0.25, 4000); // half a second
    update();
    try testing.expectEqual(@as(i64, 500), mic.duration_ms.get());
    mic.stop();
    try testing.expect(!mic.recording.get());
    try testing.expectEqual(@as(usize, 1), finished);
    const clip = mic.recorded.get();
    try testing.expectEqual(@as(u32, 4000), clip.frames());
    try testing.expectEqual(@as(u32, 8000), clip.sample_rate);
    try testing.expectApproxEqAbs(@as(f32, 0.25), clip.sample(10, 0), 0.001);

    mic.active.set(false);
    @import("../properties.zig").runChangeHandlers();
    try testing.expect(!fake.started);
    try testing.expectEqual(@as(f32, 0), mic.level.get());

    // Recording without `active` runs the input too.
    mic.record();
    try testing.expect(fake.started);
    fake.hear(-1, 800);
    update();
    mic.stop();
    try testing.expect(!fake.started);
    try testing.expectEqual(@as(u32, 800), mic.recorded.get().frames());
    try testing.expectApproxEqAbs(@as(f32, -1), mic.recorded.get().sample(0, 0), 0.001);
}
