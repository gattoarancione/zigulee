// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The device's position: a backend's provider (`setProvider`) delivers
//! fixes, from any thread; `update` (from `updateTimersAndAnimations`)
//! passes the newest to the `PositionSource` elements, on the UI thread.
//!
//! The position is followed while a `PositionSource` is `active`. The
//! first time, the platform asks the user.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const ChangeTracker = @import("properties.zig").ChangeTracker;
const Callback = @import("callbacks.zig").Callback;
const item_mod = @import("item.zig");
const time = @import("time.zig");

const log = std.log.scoped(.zigulee);

/// A fix. Unknown values are NaN.
pub const Position = struct {
    /// Degrees north (WGS 84).
    latitude: f64,
    /// Degrees east.
    longitude: f64,
    /// Meters above sea level.
    altitude: f64 = std.math.nan(f64),
    /// Meters: the radius the true position is likely within.
    accuracy: f64 = std.math.nan(f64),
    /// Meters a second over the ground.
    speed: f64 = std.math.nan(f64),
    /// Degrees clockwise from true north, where it is heading.
    direction: f64 = std.math.nan(f64),
    /// When it was taken: milliseconds since 1970 (UTC).
    timestamp: i64 = 0,
};

/// Why there is no position.
pub const Failure = enum(u8) {
    none,
    /// The user (or the system's settings) did not allow it.
    permission_denied,
    /// No fix could be had (no signal, location services off).
    unavailable,
    /// None came in time.
    timeout,
};

/// A backend's location service.
pub const Provider = struct {
    ctx: ?*anyopaque,
    vtable: *const VTable,

    pub const Error = error{ LocationUnavailable, OutOfMemory };

    pub const VTable = struct {
        /// Whether the platform has a location service.
        available: *const fn (ctx: ?*anyopaque) bool,
        /// Starts delivering fixes to `sink` (from any thread). It may take
        /// a while (the user is asked first).
        start: *const fn (ctx: ?*anyopaque, sink: *const Sink) Error!void,
        /// Stops; when it returns, `sink` is not running and will not be
        /// called.
        stop: *const fn (ctx: ?*anyopaque) void,
        /// Called on the UI thread at each update while it runs.
        poll: ?*const fn (ctx: ?*anyopaque) void = null,
    };

    pub const Sink = struct {
        ctx: ?*anyopaque,
        position: *const fn (ctx: ?*anyopaque, p: Position) void,
        failed: *const fn (ctx: ?*anyopaque, why: Failure) void,
    };
};

var provider: ?Provider = null;
var running = false;
const sink: Provider.Sink = .{ .ctx = null, .position = sinkPosition, .failed = sinkFailed };
var sources: std.ArrayList(*PositionSource) = .empty;

/// The newest fix and failure, guarded by `lock`.
var lock: std.atomic.Value(bool) = .init(false);
var incoming: Position = .{ .latitude = 0, .longitude = 0 };
var fresh = false;
var failure: ?Failure = null;
/// The last fix passed on (new elements start from it).
var last: ?Position = null;

fn acquire() void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn release() void {
    lock.store(false, .release);
}

fn sinkPosition(_: ?*anyopaque, p: Position) void {
    acquire();
    defer release();
    incoming = p;
    fresh = true;
}

fn sinkFailed(_: ?*anyopaque, why: Failure) void {
    acquire();
    defer release();
    failure = why;
}

/// The location service to use (null: none); stops the current one.
pub fn setProvider(p: ?Provider) void {
    if (running) {
        provider.?.vtable.stop(provider.?.ctx);
        running = false;
    }
    provider = p;
    last = null;
    for (sources.items) |s| s.available.set(hasLocation());
    refresh();
}

pub fn hasLocation() bool {
    const p = provider orelse return false;
    return p.vtable.available(p.ctx);
}

/// Whether the position is followed (the event loop keeps waking up for
/// `update`).
pub fn busy() bool {
    return running;
}

fn refresh() void {
    const wanted = for (sources.items) |s| {
        if (s.active.getUntracked()) break true;
    } else false;
    if (wanted == running) return;
    const p = provider orelse return;
    if (!wanted) {
        p.vtable.stop(p.ctx);
        running = false;
        return;
    }
    if (!p.vtable.available(p.ctx)) return;
    acquire();
    fresh = false;
    failure = null;
    release();
    p.vtable.start(p.ctx, &sink) catch |err| {
        log.info("no location: {t}", .{err});
        for (sources.items) |s| if (s.active.getUntracked()) s.error_.set(.unavailable);
        return;
    };
    running = true;
}

/// Passes the newest fix (or failure) on. Call on the UI thread once per
/// event loop iteration.
pub fn update() void {
    if (!running) return;
    const p = provider orelse return;
    if (p.vtable.poll) |poll| poll(p.ctx);
    acquire();
    const fix: ?Position = if (fresh) incoming else null;
    fresh = false;
    const why = failure;
    failure = null;
    release();
    const now = time.now();
    // Copied: an `updated` handler may add or remove sources.
    var list: [32]*PositionSource = undefined;
    const n = @min(sources.items.len, list.len);
    @memcpy(list[0..n], sources.items[0..n]);
    if (why) |w| for (list[0..n]) |s| if (s.active.getUntracked()) s.error_.set(w);
    if (fix) |f| {
        last = f;
        for (list[0..n]) |s| s.take(f, now);
    }
}

fn cleanUp(gpa: Allocator) void {
    if (sources.items.len > 0) return;
    sources.deinit(gpa);
    sources = .empty;
}

// ---- The element ----

/// The device's position while `active` (`PositionSource`). Not drawn.
pub const PositionSource = struct {
    item: item_mod.Item = .init(&vtable),
    active: Property(bool) = .init(false),
    /// There is a location service (the platform's, through the backend).
    available: Property(bool) = .init(false),
    /// At most one fix this often (ms; 0: as they come).
    minimum_interval: Property(i64) = .init(0),
    /// Whether a fix has come (the values below mean something).
    valid: Property(bool) = .init(false),
    latitude: Property(f32) = .init(0),
    longitude: Property(f32) = .init(0),
    altitude: Property(f32) = .init(0),
    altitude_valid: Property(bool) = .init(false),
    accuracy: Property(f32) = .init(0),
    speed: Property(f32) = .init(0),
    speed_valid: Property(bool) = .init(false),
    direction: Property(f32) = .init(0),
    direction_valid: Property(bool) = .init(false),
    /// When the fix was taken (since 1970, UTC).
    timestamp: Property(i64) = .init(0),
    /// Why there is no fix (`none` once one comes).
    error_: Property(Failure) = .init(.none),
    updated: Callback(fn () void) = .{},

    gpa: Allocator = undefined,
    tracker: ChangeTracker(bool) = undefined,
    /// When the last fix was taken in (ms on the UI clock).
    taken: ?u64 = null,

    const vtable: item_mod.ItemVTable = .{ .name = "PositionSource" };

    pub fn init(self: *PositionSource, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.available.set(hasLocation());
        sources.append(gpa, self) catch {};
        self.tracker.init(gpa, self, activeNow, activeChanged);
    }

    pub fn deinit(self: *PositionSource) void {
        for (sources.items, 0..) |s, i| if (s == self) {
            _ = sources.orderedRemove(i);
            break;
        };
        refresh();
        cleanUp(self.gpa);
        self.tracker.deinit();
        self.item.deinit();
        inline for (.{ "active", "available", "minimum_interval", "valid", "latitude", "longitude", "altitude", "altitude_valid", "accuracy", "speed", "speed_valid", "direction", "direction_valid", "timestamp", "error_" }) |f| @field(self, f).deinit();
    }

    fn activeNow(self: *PositionSource) bool {
        return self.active.get();
    }

    fn activeChanged(self: *PositionSource, on: bool) void {
        self.taken = null;
        refresh();
        // Followed already for another source: where it was last.
        if (on and running) if (last) |l| self.take(l, time.now());
    }

    fn take(self: *PositionSource, p: Position, now: u64) void {
        if (!self.active.getUntracked()) return;
        const interval = self.minimum_interval.getUntracked();
        if (interval > 0) if (self.taken) |t| {
            if (now -| t < @as(u64, @intCast(interval))) return;
        };
        self.taken = now;
        const known = struct {
            fn f(prop: *Property(f32), valid: ?*Property(bool), v: f64) void {
                const ok = !std.math.isNan(v);
                if (ok) prop.set(@floatCast(v));
                if (valid) |b| b.set(ok);
            }
        }.f;
        self.latitude.set(@floatCast(p.latitude));
        self.longitude.set(@floatCast(p.longitude));
        known(&self.altitude, &self.altitude_valid, p.altitude);
        known(&self.accuracy, null, p.accuracy);
        known(&self.speed, &self.speed_valid, p.speed);
        known(&self.direction, &self.direction_valid, p.direction);
        self.timestamp.set(p.timestamp);
        self.valid.set(true);
        self.error_.set(.none);
        self.updated.call(.{});
    }
};

// ---- Tests ----

const testing = std.testing;
const runChangeHandlers = @import("properties.zig").runChangeHandlers;

const FakeLocation = struct {
    started: bool = false,
    sink: ?*const Provider.Sink = null,

    fn provider(self: *FakeLocation) Provider {
        return .{ .ctx = self, .vtable = &.{ .available = available, .start = start, .stop = stop } };
    }
    fn of(ctx: ?*anyopaque) *FakeLocation {
        return @ptrCast(@alignCast(ctx));
    }
    fn available(_: ?*anyopaque) bool {
        return true;
    }
    fn start(ctx: ?*anyopaque, s: *const Provider.Sink) Provider.Error!void {
        of(ctx).started = true;
        of(ctx).sink = s;
    }
    fn stop(ctx: ?*anyopaque) void {
        of(ctx).started = false;
    }
};

test "a position source follows the position while active" {
    var fake: FakeLocation = .{};
    setProvider(fake.provider());
    defer setProvider(null);
    const t0 = time.now() + 1000;
    time.advanceTo(t0);

    var src: PositionSource = undefined;
    src.init(testing.allocator);
    defer src.deinit();
    try testing.expect(src.available.get() and !fake.started);
    src.active.set(true);
    runChangeHandlers();
    try testing.expect(fake.started and busy());

    // Refused first: the error, no fix.
    fake.sink.?.failed(null, .permission_denied);
    update();
    try testing.expectEqual(Failure.permission_denied, src.error_.get());
    try testing.expect(!src.valid.get());

    fake.sink.?.position(null, .{ .latitude = 45.4642, .longitude = 9.19, .accuracy = 12, .timestamp = 1_763_000_000_000 });
    update();
    try testing.expect(src.valid.get());
    try testing.expectApproxEqAbs(@as(f32, 45.4642), src.latitude.get(), 1e-4);
    try testing.expectEqual(@as(f32, 12), src.accuracy.get());
    try testing.expect(!src.altitude_valid.get() and !src.speed_valid.get());
    try testing.expectEqual(@as(i64, 1_763_000_000_000), src.timestamp.get());
    try testing.expectEqual(Failure.none, src.error_.get());

    // At most one a second: the next within it is skipped.
    src.minimum_interval.set(1000);
    time.advanceTo(t0 + 400);
    fake.sink.?.position(null, .{ .latitude = 46, .longitude = 9.19, .altitude = 120, .speed = 1.5 });
    update();
    try testing.expectApproxEqAbs(@as(f32, 45.4642), src.latitude.get(), 1e-4);
    time.advanceTo(t0 + 1100);
    fake.sink.?.position(null, .{ .latitude = 46, .longitude = 9.19, .altitude = 120, .speed = 1.5 });
    update();
    try testing.expectEqual(@as(f32, 46), src.latitude.get());
    try testing.expect(src.altitude_valid.get() and src.speed_valid.get() and !src.direction_valid.get());

    // Another source started meanwhile starts where it is.
    var other: PositionSource = undefined;
    other.init(testing.allocator);
    defer other.deinit();
    other.active.set(true);
    runChangeHandlers();
    try testing.expectEqual(@as(f32, 46), other.latitude.get());

    src.active.set(false);
    other.active.set(false);
    runChangeHandlers();
    try testing.expect(!fake.started and !busy());
}

test "without a provider, no location" {
    var src: PositionSource = undefined;
    src.init(testing.allocator);
    defer src.deinit();
    src.active.set(true);
    runChangeHandlers();
    try testing.expect(!src.available.get() and !busy());
}
