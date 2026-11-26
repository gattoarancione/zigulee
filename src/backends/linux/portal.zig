// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! File dialogs through the XDG desktop portal (Linux): the desktop's own
//! (GNOME's, KDE's, ...), over D-Bus. Each dialog asks from a thread of its
//! own: `FileChooser.OpenFile` or `SaveFile`, then the answer comes in a
//! `Request.Response` signal, handed over to the UI thread by
//! `Pending.finish`. Used by the X11 and Wayland backends.

const std = @import("std");
const zigulee = @import("zigulee");
const dbus = @import("dbus.zig");
const dialogs = zigulee.core.dialogs;

const log = std.log.scoped(.zigulee_portal);

pub const provider: dialogs.Provider = .{ .show = show };

fn show(_: ?*anyopaque, p: *dialogs.Pending) void {
    const t = std.Thread.spawn(.{}, run, .{p}) catch return p.finish(&.{});
    t.detach();
}

var tokens: std.atomic.Value(u32) = .init(0);

fn run(p: *dialogs.Pending) void {
    ask(p) catch |err| {
        log.info("no file dialog from the desktop portal: {t}", .{err});
        p.finish(&.{});
    };
}

fn ask(p: *dialogs.Pending) !void {
    const gpa = p.gpa;
    const address = dbus.sessionBusAddress() orelse return error.NoSessionBus;
    const conn = try dbus.Connection.open(gpa, address);
    defer conn.close();

    // The answer comes as a signal: listen before asking.
    {
        var w: dbus.Writer = .init(gpa);
        defer w.deinit();
        w.string("type='signal',interface='org.freedesktop.portal.Request',member='Response'");
        const r = try conn.callOk(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "AddMatch" }, "s", try w.finish());
        r.deinit(gpa);
    }

    const r = p.request;
    const saving = r.mode == .save_file;
    var w: dbus.Writer = .init(gpa);
    defer w.deinit();
    w.string(""); // no parent window
    w.string(if (r.title.len > 0) r.title else if (saving) "Save" else "Open");
    const options = w.beginArray('{');
    {
        var token_buf: [32]u8 = undefined;
        entry(&w, "handle_token", "s");
        w.string(std.fmt.bufPrint(&token_buf, "zigulee{d}", .{tokens.fetchAdd(1, .monotonic)}) catch unreachable);
        entry(&w, "modal", "b");
        w.boolean(true);
        if (r.mode == .open_files) {
            entry(&w, "multiple", "b");
            w.boolean(true);
        }
        if (r.mode == .open_folder) {
            entry(&w, "directory", "b");
            w.boolean(true);
        }
        if (r.filters.len > 0 and r.mode != .open_folder) {
            // [(name, [(0: a glob, pattern)])]
            entry(&w, "filters", "a(sa(us))");
            const filters = w.beginArray('(');
            for (r.filters) |f| {
                w.structure();
                w.string(f.name);
                const patterns = w.beginArray('(');
                for (f.patterns) |pat| {
                    w.structure();
                    w.uint32(0);
                    w.string(pat);
                }
                w.endArray(patterns);
            }
            w.endArray(filters);
        }
        if (saving and r.file_name.len > 0) {
            entry(&w, "current_name", "s");
            w.string(r.file_name);
        }
        if (r.folder.len > 0) {
            // A path as bytes, ending with 0.
            entry(&w, "current_folder", "ay");
            const bytes = w.beginArray('y');
            for (r.folder) |b| w.byte(b);
            w.byte(0);
            w.endArray(bytes);
        }
    }
    w.endArray(options);

    const reply = try conn.callOk(.{
        .destination = "org.freedesktop.portal.Desktop",
        .path = "/org/freedesktop/portal/desktop",
        .interface = "org.freedesktop.portal.FileChooser",
        .member = if (saving) "SaveFile" else "OpenFile",
    }, "ssa{sv}", try w.finish());
    defer reply.deinit(gpa);
    var rr = reply.message.reader();
    const handle = try gpa.dupe(u8, try rr.string());
    defer gpa.free(handle);

    // The answer, whenever the user gives it.
    while (true) {
        const m = try conn.next(1000) orelse continue;
        defer m.deinit(gpa);
        if (m.message.type != .signal or !std.mem.eql(u8, m.message.member, "Response") or !std.mem.eql(u8, m.message.path, handle)) continue;
        var files: std.ArrayList([]const u8) = .empty;
        defer {
            for (files.items) |f| gpa.free(f);
            files.deinit(gpa);
        }
        var body = m.message.reader();
        if (try body.uint32() == 0) try readUris(gpa, &body, &files);
        return p.finish(files.items);
    }
}

/// An entry of an `a{sv}`: its key and the variant's signature (the value
/// follows).
fn entry(w: *dbus.Writer, key: []const u8, sig: []const u8) void {
    w.structure();
    w.string(key);
    w.variant(sig);
}

/// The paths of the `uris` in the results (`a{sv}`).
fn readUris(gpa: std.mem.Allocator, r: *dbus.Reader, files: *std.ArrayList([]const u8)) !void {
    const end = try r.array('{');
    while (r.pos < end) {
        try r.structure();
        const key = try r.string();
        const sig = try r.signature();
        if (!std.mem.eql(u8, key, "uris") or !std.mem.eql(u8, sig, "as")) {
            try r.skip(sig);
            continue;
        }
        const uris_end = try r.array('s');
        while (r.pos < uris_end) {
            const uri = try r.string();
            if (try pathOfUri(gpa, uri)) |path| try files.append(gpa, path);
        }
    }
}

/// The path of a `file://` URI (percent-decoded), or null for another kind.
pub fn pathOfUri(gpa: std.mem.Allocator, uri: []const u8) !?[]u8 {
    var rest = std.mem.cutPrefix(u8, uri, "file://") orelse return null;
    // "file://host/path": the path from the first slash.
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[slash..] else return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < rest.len) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 ..][0..2], 16)) |b| {
                try out.append(gpa, b);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(gpa, rest[i]);
        i += 1;
    }
    return try out.toOwnedSlice(gpa);
}

test "file URIs to paths" {
    const t = std.testing;
    const a = (try pathOfUri(t.allocator, "file:///home/me/My%20Pictures/snow%2B1.png")).?;
    defer t.allocator.free(a);
    try t.expectEqualStrings("/home/me/My Pictures/snow+1.png", a);
    const b = (try pathOfUri(t.allocator, "file://localhost/tmp/x")).?;
    defer t.allocator.free(b);
    try t.expectEqualStrings("/tmp/x", b);
    try t.expectEqual(@as(?[]u8, null), try pathOfUri(t.allocator, "https://example.com/a"));
}
