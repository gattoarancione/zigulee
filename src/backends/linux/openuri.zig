// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! `open-url` on Linux: the XDG desktop portal's `OpenURI` (the desktop's
//! choice of browser, also from a sandbox), else `xdg-open`. Local files
//! (`file:` URLs) go to `xdg-open` (the portal wants them as open files).
//! Used by the X11 and Wayland backends.

const std = @import("std");
const zigulee = @import("zigulee");
const dbus = @import("dbus.zig");

const log = std.log.scoped(.zigulee_portal);

pub const opener: zigulee.core.links.Opener = .{ .open = open };

fn open(_: ?*anyopaque, url: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(url, "file:") and portal(url)) return true;
    return xdgOpen(url);
}

/// The body of an `OpenURI` call: no parent window, `url`, no options.
fn openUriBody(w: *dbus.Writer, url: []const u8) void {
    w.string("");
    w.string(url);
    const options = w.beginArray('{');
    w.endArray(options);
}

fn portal(url: []const u8) bool {
    const gpa = std.heap.c_allocator;
    const address = dbus.sessionBusAddress() orelse return false;
    const conn = dbus.Connection.open(gpa, address) catch return false;
    defer conn.close();
    var w: dbus.Writer = .init(gpa);
    defer w.deinit();
    openUriBody(&w, url);
    const r = conn.callOk(.{
        .destination = "org.freedesktop.portal.Desktop",
        .path = "/org/freedesktop/portal/desktop",
        .interface = "org.freedesktop.portal.OpenURI",
        .member = "OpenURI",
    }, "ssa{sv}", w.finish() catch return false) catch |err| {
        log.info("no desktop portal to open links: {t}", .{err});
        return false;
    };
    r.deinit(gpa);
    return true;
}

extern "c" fn fork() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn _exit(status: c_int) noreturn;

/// Runs `xdg-open url` on its own (forked twice: nothing to wait for).
fn xdgOpen(url: []const u8) bool {
    const z = std.heap.c_allocator.dupeZ(u8, url) catch return false;
    defer std.heap.c_allocator.free(z);
    const argv = [_:null]?[*:0]const u8{ "xdg-open", z.ptr };
    const child = fork();
    if (child < 0) return false;
    if (child == 0) {
        if (fork() == 0) {
            _ = execvp("xdg-open", &argv);
            _exit(127);
        }
        _exit(0);
    }
    var status: c_int = 0;
    _ = waitpid(child, &status, 0);
    return status == 0;
}

test "an OpenURI call's body" {
    const testing = std.testing;
    var w: dbus.Writer = .init(testing.allocator);
    defer w.deinit();
    openUriBody(&w, "https://ziglang.org");
    const m: dbus.Message = .{ .type = .call, .signature = "ssa{sv}", .body = try w.finish() };
    var r = m.reader();
    try testing.expectEqualStrings("", try r.string());
    try testing.expectEqualStrings("https://ziglang.org", try r.string());
    const end = try r.array('{');
    try testing.expectEqual(r.pos, end);
}
