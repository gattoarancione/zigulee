// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Motion sensors: a backend's provider (`setProvider`) delivers readings,
//! from any thread; `update` (from `updateTimersAndAnimations`) passes the
//! newest of each kind to the sensor elements, on the UI thread.
//!
//! A sensor runs while an element of its kind is `active`. Readings follow
//! Android's (and the W3C's) axes, the device held upright in portrait: x
//! to the right, y up, z out of the screen. Without a provider of its own,
//! the orientation is worked out from the accelerometer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const ChangeTracker = @import("properties.zig").ChangeTracker;
const Callback = @import("callbacks.zig").Callback;
const item_mod = @import("item.zig");
const time = @import("time.zig");

const log = std.log.scoped(.zigulee);

pub const Kind = enum(u8) {
    /// x, y, z in m/s², gravity included (lying face up: 0, 0, 9.81).
    accelerometer,
    /// Turning about x, y, z in degrees per second (counterclockwise
    /// positive, looking down the axis).
    gyroscope,
    /// The azimuth in degrees clockwise from magnetic north, and how well
    /// calibrated it is (0 to 1).
    compass,
    /// Which way up the device is: an `Orientation`, as a number.
    orientation,
};

/// Which side of the device is up.
pub const Orientation = enum(u8) {
    unknown,
    /// Upright, as in portrait.
    top_up,
    /// Upside down.
    top_down,
    /// Turned with its left side up (landscape).
    left_up,
    /// Turned with its right side up (landscape).
    right_up,
    /// Lying on its back, the screen up.
    face_up,
    /// Lying on its screen.
    face_down,
};

/// A backend's sensors.
pub const Provider = struct {
    ctx: ?*anyopaque,
    vtable: *const VTable,

    pub const Error = error{ SensorUnavailable, OutOfMemory };

    pub const VTable = struct {
        /// Whether the platform has the sensor (it may still give no
        /// readings: a browser has the API on computers without one).
        available: *const fn (ctx: ?*anyopaque, kind: Kind) bool,
        /// Starts delivering readings of `kind` to `sink` (from any
        /// thread). It may take a while (the user is asked first).
        start: *const fn (ctx: ?*anyopaque, kind: Kind, sink: *const Sink) Error!void,
        /// Stops; when it returns, `sink.reading` is not running for
        /// `kind` and will not be called for it.
        stop: *const fn (ctx: ?*anyopaque, kind: Kind) void,
        /// Called on the UI thread at each update while a sensor runs
        /// (for backends that read sensors there).
        poll: ?*const fn (ctx: ?*anyopaque) void = null,
    };

    pub const Sink = struct {
        ctx: ?*anyopaque,
        /// A reading (see `Kind` for what the values are; unused ones 0).
        reading: *const fn (ctx: ?*anyopaque, kind: Kind, values: [3]f32) void,
    };
};

const kinds = std.meta.fields(Kind).len;

var provider: ?Provider = null;
var running: [kinds]bool = @splat(false);
const sink: Provider.Sink = .{ .ctx = null, .reading = sinkReading };
var elements: std.ArrayList(*Sensor) = .empty;
var gpa_used: ?Allocator = null;

/// The newest reading of each kind, guarded by `lock`.
var lock: std.atomic.Value(bool) = .init(false);
var incoming: [kinds][3]f32 = @splat(.{ 0, 0, 0 });
var fresh: [kinds]bool = @splat(false);
/// The orientation worked out from the accelerometer (with hysteresis).
var derived: Orientation = .unknown;

fn acquire() void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn release() void {
    lock.store(false, .release);
}

fn sinkReading(_: ?*anyopaque, kind: Kind, values: [3]f32) void {
    acquire();
    defer release();
    incoming[@intFromEnum(kind)] = values;
    fresh[@intFromEnum(kind)] = true;
}

/// The sensors to use (null: none); stops those running.
pub fn setProvider(p: ?Provider) void {
    if (provider) |old| for (&running, 0..) |*r, i| if (r.*) {
        old.vtable.stop(old.ctx, @enumFromInt(i));
        r.* = false;
    };
    provider = p;
    derived = .unknown;
    for (elements.items) |e| e.available.set(hasSensor(e.kind));
    refresh();
}

/// Whether the platform has the sensor (the orientation counts as there
/// with an accelerometer).
pub fn hasSensor(kind: Kind) bool {
    const p = provider orelse return false;
    if (p.vtable.available(p.ctx, kind)) return true;
    return kind == .orientation and p.vtable.available(p.ctx, .accelerometer);
}

/// Whether the orientation comes from the accelerometer.
fn orientationDerived() bool {
    const p = provider orelse return false;
    return !p.vtable.available(p.ctx, .orientation);
}

/// Whether a sensor runs (the event loop keeps waking up for `update`).
pub fn busy() bool {
    for (running) |r| if (r) return true;
    return false;
}

/// Starts or stops each sensor as the elements need.
fn refresh() void {
    const p = provider orelse return;
    var wanted: [kinds]bool = @splat(false);
    for (elements.items) |e| if (e.active.getUntracked()) {
        wanted[@intFromEnum(e.kind)] = true;
    };
    if (wanted[@intFromEnum(Kind.orientation)] and orientationDerived()) {
        wanted[@intFromEnum(Kind.orientation)] = false;
        wanted[@intFromEnum(Kind.accelerometer)] = true;
    }
    for (wanted, &running, 0..) |w, *r, i| {
        if (w == r.*) continue;
        const kind: Kind = @enumFromInt(i);
        if (!w) {
            p.vtable.stop(p.ctx, kind);
            r.* = false;
            continue;
        }
        if (!p.vtable.available(p.ctx, kind)) continue;
        acquire();
        fresh[i] = false;
        release();
        p.vtable.start(p.ctx, kind, &sink) catch |err| {
            log.info("no {t} sensor: {t}", .{ kind, err });
            continue;
        };
        r.* = true;
    }
}

/// Passes the newest readings on. Call on the UI thread once per event
/// loop iteration.
pub fn update() void {
    if (!busy()) return;
    const p = provider orelse return;
    if (p.vtable.poll) |poll| poll(p.ctx);
    var got: [kinds]?[3]f32 = @splat(null);
    acquire();
    for (&got, &fresh, incoming) |*g, *f, v| if (f.*) {
        g.* = v;
        f.* = false;
    };
    release();
    if (got[@intFromEnum(Kind.accelerometer)]) |a| if (orientationDerived()) {
        derived = orientationOf(a, derived);
        got[@intFromEnum(Kind.orientation)] = .{ @floatFromInt(@intFromEnum(derived)), 0, 0 };
    };
    const now = time.now();
    // Copied: a reading's handler may add or remove elements.
    var list: [64]*Sensor = undefined;
    const n = @min(elements.items.len, list.len);
    @memcpy(list[0..n], elements.items[0..n]);
    for (list[0..n]) |e| if (got[@intFromEnum(e.kind)]) |v| e.take(v, now);
}

/// Which side is up, from an accelerometer reading: the axis gravity
/// mostly lies along, when it clearly does (else the `previous` answer).
pub fn orientationOf(a: [3]f32, previous: Orientation) Orientation {
    const len = @sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    // Falling, or shaken: no telling.
    if (len < 4) return previous;
    var axis: usize = 0;
    for (1..3) |i| if (@abs(a[i]) > @abs(a[axis])) {
        axis = i;
    };
    // Mostly along it (within about 45 degrees, with some margin).
    if (@abs(a[axis]) < 0.75 * len) return previous;
    const positive = a[axis] > 0;
    return switch (axis) {
        0 => if (positive) .right_up else .left_up,
        1 => if (positive) .top_up else .top_down,
        else => if (positive) .face_up else .face_down,
    };
}

fn cleanUp(gpa: Allocator) void {
    if (elements.items.len > 0) return;
    elements.deinit(gpa);
    elements = .empty;
}

// ---- The elements ----

/// What every sensor element has. Not drawn.
pub const Sensor = struct {
    item: item_mod.Item,
    kind: Kind,
    active: Property(bool) = .init(false),
    /// There is such a sensor (the platform's, through the backend).
    available: Property(bool) = .init(false),
    /// At most this many readings a second (0: as they come).
    data_rate: Property(i32) = .init(0),
    reading_changed: Callback(fn () void) = .{},

    gpa: Allocator = undefined,
    tracker: ChangeTracker(bool) = undefined,
    /// Sets the element's reading properties.
    apply: *const fn (*Sensor, [3]f32) void,
    /// When the last reading was taken (ms).
    last: ?u64 = null,

    fn init(self: *Sensor, gpa: Allocator) void {
        self.gpa = gpa;
        self.available.set(hasSensor(self.kind));
        gpa_used = gpa;
        elements.append(gpa, self) catch {};
        self.tracker.init(gpa, self, activeNow, activeChanged);
    }

    fn deinit(self: *Sensor) void {
        for (elements.items, 0..) |e, i| if (e == self) {
            _ = elements.orderedRemove(i);
            break;
        };
        refresh();
        cleanUp(self.gpa);
        self.tracker.deinit();
        self.item.deinit();
        self.active.deinit();
        self.available.deinit();
        self.data_rate.deinit();
    }

    fn activeNow(self: *Sensor) bool {
        return self.active.get();
    }

    fn activeChanged(self: *Sensor, on: bool) void {
        if (on) self.last = null;
        refresh();
    }

    fn take(self: *Sensor, v: [3]f32, now: u64) void {
        if (!self.active.getUntracked()) return;
        const rate = self.data_rate.getUntracked();
        if (rate > 0) if (self.last) |l| {
            if (now -| l < @divTrunc(1000, @as(u64, @intCast(rate)))) return;
        };
        self.last = now;
        self.apply(self, v);
        self.reading_changed.call(.{});
    }
};

fn vtableNamed(comptime name: []const u8) *const item_mod.ItemVTable {
    return &struct {
        const v: item_mod.ItemVTable = .{ .name = name };
    }.v;
}

/// Acceleration, gravity included (`x`, `y`, `z` in m/s²): lying face up,
/// 0, 0, 9.81.
pub const Accelerometer = struct {
    sensor: Sensor = .{ .item = .init(vtableNamed("Accelerometer")), .kind = .accelerometer, .apply = apply },
    x: Property(f32) = .init(0),
    y: Property(f32) = .init(0),
    z: Property(f32) = .init(0),

    pub fn init(self: *Accelerometer, gpa: Allocator) void {
        self.* = .{};
        self.sensor.init(gpa);
    }

    pub fn deinit(self: *Accelerometer) void {
        self.sensor.deinit();
        inline for (.{ "x", "y", "z" }) |f| @field(self, f).deinit();
    }

    fn apply(s: *Sensor, v: [3]f32) void {
        const self: *Accelerometer = @fieldParentPtr("sensor", s);
        self.x.set(v[0]);
        self.y.set(v[1]);
        self.z.set(v[2]);
    }
};

/// How fast the device turns about each axis (`x`, `y`, `z` in degrees per
/// second).
pub const Gyroscope = struct {
    sensor: Sensor = .{ .item = .init(vtableNamed("Gyroscope")), .kind = .gyroscope, .apply = apply },
    x: Property(f32) = .init(0),
    y: Property(f32) = .init(0),
    z: Property(f32) = .init(0),

    pub fn init(self: *Gyroscope, gpa: Allocator) void {
        self.* = .{};
        self.sensor.init(gpa);
    }

    pub fn deinit(self: *Gyroscope) void {
        self.sensor.deinit();
        inline for (.{ "x", "y", "z" }) |f| @field(self, f).deinit();
    }

    fn apply(s: *Sensor, v: [3]f32) void {
        const self: *Gyroscope = @fieldParentPtr("sensor", s);
        self.x.set(v[0]);
        self.y.set(v[1]);
        self.z.set(v[2]);
    }
};

/// Where the device points: `azimuth` in degrees clockwise from magnetic
/// north (0 to 360), `calibration-level` from 0 to 1.
pub const Compass = struct {
    sensor: Sensor = .{ .item = .init(vtableNamed("Compass")), .kind = .compass, .apply = apply },
    azimuth: Property(f32) = .init(0),
    calibration_level: Property(f32) = .init(0),

    pub fn init(self: *Compass, gpa: Allocator) void {
        self.* = .{};
        self.sensor.init(gpa);
    }

    pub fn deinit(self: *Compass) void {
        self.sensor.deinit();
        self.azimuth.deinit();
        self.calibration_level.deinit();
    }

    fn apply(s: *Sensor, v: [3]f32) void {
        const self: *Compass = @fieldParentPtr("sensor", s);
        self.azimuth.set(@mod(v[0], 360));
        self.calibration_level.set(std.math.clamp(v[1], 0, 1));
    }
};

/// Which side of the device is up (`orientation`).
pub const OrientationSensor = struct {
    sensor: Sensor = .{ .item = .init(vtableNamed("OrientationSensor")), .kind = .orientation, .apply = apply },
    orientation: Property(Orientation) = .init(.unknown),

    pub fn init(self: *OrientationSensor, gpa: Allocator) void {
        self.* = .{};
        self.sensor.init(gpa);
        // Known already if another element keeps the accelerometer going.
        if (derived != .unknown and orientationDerived()) self.orientation.set(derived);
    }

    pub fn deinit(self: *OrientationSensor) void {
        self.sensor.deinit();
        self.orientation.deinit();
    }

    fn apply(s: *Sensor, v: [3]f32) void {
        const self: *OrientationSensor = @fieldParentPtr("sensor", s);
        const last: f32 = @floatFromInt(std.meta.fields(Orientation).len - 1);
        const i: u8 = @intFromFloat(std.math.clamp(@round(v[0]), 0, last));
        self.orientation.set(@enumFromInt(i));
    }
};

// ---- Tests ----

const testing = std.testing;
const runChangeHandlers = @import("properties.zig").runChangeHandlers;

const FakeSensors = struct {
    has: [kinds]bool = .{ true, true, false, false },
    started: [kinds]bool = @splat(false),
    sink: ?*const Provider.Sink = null,

    fn provider(self: *FakeSensors) Provider {
        return .{ .ctx = self, .vtable = &.{ .available = available, .start = start, .stop = stop } };
    }
    fn of(ctx: ?*anyopaque) *FakeSensors {
        return @ptrCast(@alignCast(ctx));
    }
    fn available(ctx: ?*anyopaque, kind: Kind) bool {
        return of(ctx).has[@intFromEnum(kind)];
    }
    fn start(ctx: ?*anyopaque, kind: Kind, s: *const Provider.Sink) Provider.Error!void {
        of(ctx).started[@intFromEnum(kind)] = true;
        of(ctx).sink = s;
    }
    fn stop(ctx: ?*anyopaque, kind: Kind) void {
        of(ctx).started[@intFromEnum(kind)] = false;
    }
    fn send(self: *FakeSensors, kind: Kind, v: [3]f32) void {
        self.sink.?.reading(self.sink.?.ctx, kind, v);
    }
};

test "sensors run while active and pass their readings on, as often as asked" {
    var fake: FakeSensors = .{};
    setProvider(fake.provider());
    defer setProvider(null);
    // The clock only goes forward: times from wherever it is.
    const t0 = time.now() + 1000;
    time.advanceTo(t0);

    var accel: Accelerometer = undefined;
    accel.init(testing.allocator);
    defer accel.deinit();
    var compass: Compass = undefined;
    compass.init(testing.allocator);
    defer compass.deinit();
    try testing.expect(accel.sensor.available.get());
    try testing.expect(!compass.sensor.available.get());
    try testing.expect(!fake.started[0]);

    const Counter = struct {
        n: usize = 0,
        fn bump(c: *@This()) void {
            c.n += 1;
        }
    };
    var changes: Counter = .{};
    accel.sensor.reading_changed.setHandler(&changes, Counter.bump);
    accel.sensor.active.set(true);
    runChangeHandlers();
    try testing.expect(fake.started[0] and busy());

    fake.send(.accelerometer, .{ 0.5, 9.7, 1 });
    update();
    try testing.expectEqual(@as(f32, 9.7), accel.y.get());
    try testing.expectEqual(@as(usize, 1), changes.n);
    // Nothing new: nothing to pass on.
    update();
    try testing.expectEqual(@as(usize, 1), changes.n);

    // Two a second: the next reading within half a second is skipped.
    accel.sensor.data_rate.set(2);
    time.advanceTo(t0 + 100);
    fake.send(.accelerometer, .{ 0, 0, 9.8 });
    update();
    try testing.expectEqual(@as(f32, 9.7), accel.y.get());
    time.advanceTo(t0 + 600);
    fake.send(.accelerometer, .{ 0, 0, 9.8 });
    update();
    try testing.expectEqual(@as(f32, 9.8), accel.z.get());
    try testing.expectEqual(@as(usize, 2), changes.n);

    accel.sensor.active.set(false);
    runChangeHandlers();
    try testing.expect(!fake.started[0] and !busy());
}

test "the orientation comes from the accelerometer, with some margin" {
    var fake: FakeSensors = .{};
    setProvider(fake.provider());
    defer setProvider(null);

    var o: OrientationSensor = undefined;
    o.init(testing.allocator);
    defer o.deinit();
    try testing.expect(o.sensor.available.get());
    o.sensor.active.set(true);
    runChangeHandlers();
    // The accelerometer runs for it.
    try testing.expect(fake.started[0] and !fake.started[3]);

    fake.send(.accelerometer, .{ 0.3, 9.6, 1.2 });
    update();
    try testing.expectEqual(Orientation.top_up, o.orientation.get());
    // Halfway between upright and lying down: still upright.
    fake.send(.accelerometer, .{ 0, 6.9, 6.9 });
    update();
    try testing.expectEqual(Orientation.top_up, o.orientation.get());
    fake.send(.accelerometer, .{ 0, 1, 9.7 });
    update();
    try testing.expectEqual(Orientation.face_up, o.orientation.get());
    // The right side up: gravity's pull felt along -x, so +x reads +g.
    fake.send(.accelerometer, .{ 9.7, 0.5, 0 });
    update();
    try testing.expectEqual(Orientation.right_up, o.orientation.get());
    fake.send(.accelerometer, .{ -9.7, 0.5, 0 });
    update();
    try testing.expectEqual(Orientation.left_up, o.orientation.get());
    // Falling: no change.
    fake.send(.accelerometer, .{ 0, 0, -1 });
    update();
    try testing.expectEqual(Orientation.left_up, o.orientation.get());

    o.sensor.active.set(false);
    runChangeHandlers();
    try testing.expect(!fake.started[0]);
}

test "a compass reading is kept within a turn" {
    var fake: FakeSensors = .{ .has = .{ false, false, true, false } };
    setProvider(fake.provider());
    defer setProvider(null);
    var c: Compass = undefined;
    c.init(testing.allocator);
    defer c.deinit();
    c.sensor.active.set(true);
    runChangeHandlers();
    fake.send(.compass, .{ -90, 1.5, 0 });
    update();
    try testing.expectEqual(@as(f32, 270), c.azimuth.get());
    try testing.expectEqual(@as(f32, 1), c.calibration_level.get());
}

test "without a provider, sensors are not available and nothing runs" {
    var g: Gyroscope = undefined;
    g.init(testing.allocator);
    defer g.deinit();
    g.sensor.active.set(true);
    runChangeHandlers();
    try testing.expect(!g.sensor.available.get());
    try testing.expect(!busy());
}
