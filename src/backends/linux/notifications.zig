// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Desktop notifications on Linux: `org.freedesktop.Notifications` on the
//! session bus (GNOME's, KDE's, dunst, mako, ...). A notification has a
//! default action, so a click on it comes back as an `ActionInvoked`
//! signal, read by `poll` on the UI thread. Used by the X11, Wayland and
//! SDL3 backends.

const std = @import("std");
const zigulee = @import("zigulee");
const dbus = @import("dbus.zig");
const tray = zigulee.core.tray;

const log = std.log.scoped(.zigulee);

pub const provider: tray.Provider = .{ .notify = notify, .poll = poll };

const service: dbus.Connection.Target = .{
    .destination = "org.freedesktop.Notifications",
    .path = "/org/freedesktop/Notifications",
    .interface = "org.freedesktop.Notifications",
    .member = "Notify",
};

const gpa = std.heap.c_allocator;
var conn: ?*dbus.Connection = null;
var failed = false;

/// The desktop's ids of the notifications sent and ours, newest last.
var ids: [32]struct { desktop: u32, ours: u32 } = undefined;
var ids_len: usize = 0;

fn connection() ?*dbus.Connection {
    if (conn) |c| return c;
    if (failed) return null;
    failed = true; // until it works
    const address = dbus.sessionBusAddress() orelse {
        log.info("no notifications: no session bus", .{});
        return null;
    };
    const c = dbus.Connection.open(gpa, address) catch |err| {
        log.info("no notifications: {t}", .{err});
        return null;
    };
    // Clicks on them.
    var w: dbus.Writer = .init(gpa);
    defer w.deinit();
    w.string("type='signal',interface='org.freedesktop.Notifications',member='ActionInvoked'");
    const match = c.callOk(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "AddMatch" }, "s", w.finish() catch "") catch |err| {
        log.info("no notifications: {t}", .{err});
        c.close();
        return null;
    };
    match.deinit(gpa);
    failed = false;
    conn = c;
    return c;
}

/// The body of a `Notify` call.
fn notifyBody(w: *dbus.Writer, notice: *const tray.Notice) void {
    w.string(zigulee.core.paths.applicationName());
    w.uint32(0); // replaces none
    w.string(""); // icon
    w.string(notice.title);
    w.string(notice.body);
    const actions = w.beginArray('s');
    w.string("default");
    w.string("Open");
    w.endArray(actions);
    const hints = w.beginArray('{');
    w.endArray(hints);
    w.int32(-1); // the desktop's timeout
}

fn notify(_: ?*anyopaque, notice: *const tray.Notice) void {
    const c = connection() orelse return;
    var w: dbus.Writer = .init(gpa);
    defer w.deinit();
    notifyBody(&w, notice);
    const r = c.callOk(service, "susssasa{sv}i", w.finish() catch return) catch |err| {
        log.warn("cannot show a notification: {t}", .{err});
        return;
    };
    defer r.deinit(gpa);
    var body = r.message.reader();
    const desktop = body.uint32() catch return;
    if (ids_len == ids.len) {
        std.mem.copyForwards(@TypeOf(ids[0]), ids[0 .. ids.len - 1], ids[1..]);
        ids_len -= 1;
    }
    ids[ids_len] = .{ .desktop = desktop, .ours = notice.id };
    ids_len += 1;
}

fn poll(_: ?*anyopaque) void {
    const c = conn orelse return;
    while (c.next(0) catch null) |r| {
        defer r.deinit(gpa);
        const m = r.message;
        if (m.type != .signal or !std.mem.eql(u8, m.member, "ActionInvoked")) continue;
        var body = m.reader();
        const desktop = body.uint32() catch continue;
        for (ids[0..ids_len]) |x| if (x.desktop == desktop) tray.notificationClicked(x.ours);
    }
}

// ---- Tests ----

const testing = std.testing;

test "a notification's Notify call" {
    var w: dbus.Writer = .init(testing.allocator);
    defer w.deinit();
    notifyBody(&w, &.{ .id = 3, .title = "Done", .body = "All synced" });
    const bytes = try w.finish();
    const m: dbus.Message = .{ .type = .call, .signature = "susssasa{sv}i", .body = bytes };
    var r = m.reader();
    _ = try r.string();
    try testing.expectEqual(@as(u32, 0), try r.uint32());
    try testing.expectEqualStrings("", try r.string());
    try testing.expectEqualStrings("Done", try r.string());
    try testing.expectEqualStrings("All synced", try r.string());
    _ = try r.array('s');
    try testing.expectEqualStrings("default", try r.string());
    try testing.expectEqualStrings("Open", try r.string());
    const hints_end = try r.array('{');
    try testing.expectEqual(r.pos, hints_end); // no hints
    try testing.expectEqual(@as(i32, -1), try r.int32());
}

test "notifications through a desktop's notification service, and a click" {
    const address = dbus.sessionBusAddress() orelse return error.SkipZigTest;
    // A notification service: it answers Notify with 77, then says it was
    // clicked.
    const desktop = try dbus.Connection.open(testing.allocator, address);
    defer desktop.close();
    var w: dbus.Writer = .init(testing.allocator);
    defer w.deinit();
    w.string("org.freedesktop.Notifications");
    w.uint32(4); // do not queue
    const owned = try desktop.callOk(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "RequestName" }, "su", try w.finish());
    owned.deinit(testing.allocator);

    const Service = struct {
        fn run(d: *dbus.Connection) void {
            for (0..500) |_| {
                const r = (d.next(10) catch return) orelse continue;
                defer r.deinit(testing.allocator);
                if (r.message.type != .call or !std.mem.eql(u8, r.message.member, "Notify")) continue;
                var out: dbus.Writer = .init(testing.allocator);
                defer out.deinit();
                out.uint32(77);
                d.reply(&r.message, "u", out.finish() catch return) catch return;
                var sig: dbus.Writer = .init(testing.allocator);
                defer sig.deinit();
                sig.uint32(77);
                sig.string("default");
                _ = d.send(.{ .type = .signal, .path = service.path, .interface = service.interface, .member = "ActionInvoked", .signature = "us", .body = sig.finish() catch return }) catch return;
                return;
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Service.run, .{desktop});

    var n: tray.Notification = undefined;
    n.init(testing.allocator);
    defer n.deinit();
    tray.setProvider(provider);
    defer tray.setProvider(null);
    var clicks: usize = 0;
    n.clicked.setHandler(&clicks, struct {
        fn f(k: *usize) void {
            k.* += 1;
        }
    }.f);
    n.title.set("Done");
    n.send();
    t.join();
    for (0..200) |_| {
        tray.update();
        if (clicks > 0) break;
        testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    try testing.expectEqual(@as(usize, 1), clicks);
}
