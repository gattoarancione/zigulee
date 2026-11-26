// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The position with Core Location (macOS and iOS): a CLLocationManager,
//! created on the main thread (its delegate is called on the main run
//! loop, which the app's event loop runs), asking for permission when in
//! use the first time (an app bundle needs
//! `NSLocationWhenInUseUsageDescription` in its Info.plist; without one,
//! the system refuses).

const std = @import("std");
const zigulee = @import("zigulee");
const objc = @import("objc.zig");
const location = zigulee.core.location;
const id = objc.id;
const SEL = objc.SEL;
const msg = objc.msg;
const class = objc.class;

const log = std.log.scoped(.zigulee_apple);

extern const kCLLocationAccuracyBest: f64;

const Coordinate = extern struct { latitude: f64, longitude: f64 };

const authorization_not_determined = 0;
const authorization_restricted = 1;
const authorization_denied = 2;
const error_location_unknown = 0;
const error_denied = 1;

pub const provider: location.Provider = .{ .ctx = null, .vtable = &.{
    .available = available,
    .start = start,
    .stop = stop,
} };

var manager: id = null;
var sink: ?*const location.Provider.Sink = null;

fn available(_: ?*anyopaque) bool {
    return objc.objc_getClass("CLLocationManager") != null;
}

fn start(_: ?*anyopaque, s: *const location.Provider.Sink) location.Provider.Error!void {
    sink = s;
    if (manager == null) {
        manager = msg(id, msg(id, class("CLLocationManager"), "alloc", .{}), "init", .{});
        if (manager == null) return error.LocationUnavailable;
        msg(void, manager, "setDelegate:", .{delegate()});
        msg(void, manager, "setDesiredAccuracy:", .{kCLLocationAccuracyBest});
    }
    if (msg(i32, manager, "authorizationStatus", .{}) == authorization_not_determined)
        msg(void, manager, "requestWhenInUseAuthorization", .{});
    // Fixes come once allowed.
    msg(void, manager, "startUpdatingLocation", .{});
}

fn stop(_: ?*anyopaque) void {
    if (manager != null) msg(void, manager, "stopUpdatingLocation", .{});
    sink = null;
}

/// `-locationManager:didUpdateLocations:`: the newest fix (negative
/// accuracies, speeds and courses mean unknown).
fn didUpdate(_: id, _: SEL, _: id, locations: id) callconv(.c) void {
    const s = sink orelse return;
    const fix = msg(id, locations, "lastObject", .{});
    if (fix == null) return;
    const c = msg(Coordinate, fix, "coordinate", .{});
    const known = struct {
        fn f(v: f64, check: f64) f64 {
            return if (check < 0) std.math.nan(f64) else v;
        }
    }.f;
    const accuracy = msg(f64, fix, "horizontalAccuracy", .{});
    if (accuracy < 0) return; // not a valid fix
    const speed = msg(f64, fix, "speed", .{});
    const course = msg(f64, fix, "course", .{});
    const seconds = msg(f64, msg(id, fix, "timestamp", .{}), "timeIntervalSince1970", .{});
    s.position(s.ctx, .{
        .latitude = c.latitude,
        .longitude = c.longitude,
        .altitude = known(msg(f64, fix, "altitude", .{}), msg(f64, fix, "verticalAccuracy", .{})),
        .accuracy = accuracy,
        .speed = known(speed, speed),
        .direction = known(course, course),
        .timestamp = @intFromFloat(seconds * 1000),
    });
}

/// `-locationManager:didFailWithError:`. "Unknown for now" is not a
/// failure: Core Location goes on trying.
fn didFail(_: id, _: SEL, _: id, err: id) callconv(.c) void {
    const s = sink orelse return;
    const code = msg(isize, err, "code", .{});
    if (code == error_location_unknown) return;
    s.failed(s.ctx, if (code == error_denied) .permission_denied else .unavailable);
}

/// `-locationManagerDidChangeAuthorization:`: refused, or not allowed.
fn authorizationChanged(_: id, _: SEL, m: id) callconv(.c) void {
    const s = sink orelse return;
    const status = msg(i32, m, "authorizationStatus", .{});
    if (status == authorization_denied or status == authorization_restricted) {
        log.info("location: not allowed", .{});
        s.failed(s.ctx, .permission_denied);
    }
}

/// The manager's delegate (it holds it weakly: kept here).
var delegate_object: id = null;

fn delegate() id {
    if (delegate_object) |d| return d;
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("NSObject"), "ZiguleeLocationDelegate", 0);
    if (objc.objc_getProtocol("CLLocationManagerDelegate")) |p| _ = objc.class_addProtocol(cls, p);
    for ([_]struct { [:0]const u8, *const anyopaque, [:0]const u8 }{
        .{ "locationManager:didUpdateLocations:", @ptrCast(&didUpdate), "v@:@@" },
        .{ "locationManager:didFailWithError:", @ptrCast(&didFail), "v@:@@" },
        .{ "locationManagerDidChangeAuthorization:", @ptrCast(&authorizationChanged), "v@:@" },
    }) |m| _ = objc.class_addMethod(cls, objc.sel(m[0]), @ptrCast(m[1]), m[2]);
    objc.objc_registerClassPair(cls);
    delegate_object = msg(id, msg(id, cls, "alloc", .{}), "init", .{});
    return delegate_object;
}

// ---- Tests ----

const testing = std.testing;

const Got = struct {
    fix: ?location.Position = null,
    why: ?location.Failure = null,

    fn position(ctx: ?*anyopaque, p: location.Position) void {
        const self: *Got = @ptrCast(@alignCast(ctx));
        self.fix = p;
    }
    fn failed(ctx: ?*anyopaque, why: location.Failure) void {
        const self: *Got = @ptrCast(@alignCast(ctx));
        self.why = why;
    }
};

test "Core Location's fixes and errors as zigulee's (no location asked for)" {
    if (!available(null)) return error.SkipZigTest;
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    var got: Got = .{};
    const s: location.Provider.Sink = .{ .ctx = &got, .position = Got.position, .failed = Got.failed };
    sink = &s;
    defer sink = null;
    _ = delegate();

    // A fix with no speed or course (negative: unknown), 2 s after 1970.
    const date = msg(id, class("NSDate"), "dateWithTimeIntervalSince1970:", .{@as(f64, 2)});
    const fix = msg(id, msg(id, class("CLLocation"), "alloc", .{}), "initWithCoordinate:altitude:horizontalAccuracy:verticalAccuracy:course:speed:timestamp:", .{
        Coordinate{ .latitude = 45.4642, .longitude = 9.19 }, @as(f64, 122), @as(f64, 8), @as(f64, 3), @as(f64, -1), @as(f64, -1), date,
    });
    const list = msg(id, class("NSArray"), "arrayWithObject:", .{fix});
    msg(void, delegate_object, "locationManager:didUpdateLocations:", .{ @as(id, null), list });
    const p = got.fix.?;
    try testing.expectEqual(@as(f64, 45.4642), p.latitude);
    try testing.expectEqual(@as(f64, 122), p.altitude);
    try testing.expectEqual(@as(f64, 8), p.accuracy);
    try testing.expect(std.math.isNan(p.speed) and std.math.isNan(p.direction));
    try testing.expectEqual(@as(i64, 2000), p.timestamp);

    // Refused: an error; unknown for now: none.
    const domain = msg(id, class("NSString"), "stringWithUTF8String:", .{@as([*:0]const u8, "kCLErrorDomain")});
    const unknown = msg(id, class("NSError"), "errorWithDomain:code:userInfo:", .{ domain, @as(isize, error_location_unknown), @as(id, null) });
    msg(void, delegate_object, "locationManager:didFailWithError:", .{ @as(id, null), unknown });
    try testing.expect(got.why == null);
    const denied = msg(id, class("NSError"), "errorWithDomain:code:userInfo:", .{ domain, @as(isize, error_denied), @as(id, null) });
    msg(void, delegate_object, "locationManager:didFailWithError:", .{ @as(id, null), denied });
    try testing.expectEqual(location.Failure.permission_denied, got.why.?);
}
