// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Standard paths (the `StandardPaths` element): the user's folders
//! (documents, pictures...), the temporary one, and the application's own
//! for configuration, data and caches, named after the application
//! (`setApplicationName`, else the executable's name). Where there are
//! no files (the web, microcontrollers), they are all empty.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const item_mod = @import("item.zig");

pub const has_files = builtin.os.tag != .freestanding and builtin.os.tag != .wasi;

pub const Location = enum {
    home,
    desktop,
    documents,
    downloads,
    pictures,
    music,
    videos,
    temp,
    /// The application's configuration (where `Settings` keeps its file).
    app_config,
    /// The application's data.
    app_data,
    /// The application's caches, which may be deleted.
    app_cache,
};

var app_name_buf: [128]u8 = undefined;
var app_name_len: usize = 0;

/// Names the application: its folders (`app_config`, ...) and settings
/// are found by it. Call it before making the UI. At most 128 bytes.
pub fn setApplicationName(name: []const u8) void {
    const n = @min(name.len, app_name_buf.len);
    @memcpy(app_name_buf[0..n], name[0..n]);
    app_name_len = n;
}

/// The application's name: as set, else the executable's (without
/// extension), else "zigulee".
pub fn applicationName() []const u8 {
    if (app_name_len == 0) setApplicationName(executableName());
    return app_name_buf[0..app_name_len];
}

fn executableName() []const u8 {
    if (!has_files) return "zigulee";
    const S = struct {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
    };
    var t: std.Io.Threaded = .init_single_threaded;
    const n = std.process.executablePath(t.io(), &S.buf) catch return "zigulee";
    var name = std.fs.path.basename(S.buf[0..n]);
    if (builtin.os.tag == .windows and std.ascii.endsWithIgnoreCase(name, ".exe")) name = name[0 .. name.len - 4];
    return if (name.len > 0) name else "zigulee";
}

/// Where `loc` is on this system (allocated with `gpa`); empty if it has
/// none.
pub fn get(gpa: Allocator, loc: Location) Allocator.Error![]u8 {
    if (!has_files) return gpa.dupe(u8, "");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const user_dirs: []const u8 = if (loc != .home and loc != .temp and !isAppLocation(loc) and platform() == .xdg) blk: {
        const config = (try xdgConfig(a, .{ .ctx = &a, .getFn = envGet })) orelse break :blk "";
        const path = try join(a, .xdg, &.{ config, "user-dirs.dirs" });
        var t: std.Io.Threaded = .init_single_threaded;
        break :blk std.Io.Dir.cwd().readFileAlloc(t.io(), path, a, .limited(64 << 10)) catch "";
    } else "";
    const found = try resolve(a, loc, platform(), applicationName(), .{ .ctx = &a, .getFn = envGet }, user_dirs);
    return gpa.dupe(u8, found);
}

fn isAppLocation(loc: Location) bool {
    return loc == .app_config or loc == .app_data or loc == .app_cache;
}

/// How a system lays out its folders.
pub const Platform = enum { macos, ios, windows, xdg, none };

fn platform() Platform {
    return switch (builtin.os.tag) {
        .macos => .macos,
        .ios, .tvos, .watchos, .visionos => .ios,
        .windows => .windows,
        .freestanding, .wasi, .emscripten => .none,
        else => .xdg,
    };
}

/// Environment variables, for `resolve`.
pub const Env = struct {
    ctx: *const anyopaque,
    getFn: *const fn (*const anyopaque, []const u8) ?[]const u8,

    /// The variable's value, if set and not empty.
    fn get(e: Env, name: []const u8) ?[]const u8 {
        const v = e.getFn(e.ctx, name) orelse return null;
        return if (v.len > 0) v else null;
    }
};

/// The process's environment (`ctx` is the arena copies go in).
fn envGet(ctx: *const anyopaque, name: []const u8) ?[]const u8 {
    const a: *const Allocator = @ptrCast(@alignCast(ctx));
    if (builtin.os.tag == .windows) {
        const e: std.process.Environ = .{ .block = .global };
        return e.getAlloc(a.*, name) catch null;
    }
    if (!builtin.link_libc) return null;
    const z = a.dupeZ(u8, name) catch return null;
    return std.mem.span(std.c.getenv(z) orelse return null);
}

/// Where `loc` is on `os`, from the environment `env` and, on XDG
/// systems, the contents of `user-dirs.dirs`; "" if nowhere.
pub fn resolve(a: Allocator, loc: Location, os: Platform, app: []const u8, env: Env, user_dirs: []const u8) Allocator.Error![]const u8 {
    if (os == .none) return "";
    if (loc == .temp) return switch (os) {
        .windows => env.get("TEMP") orelse env.get("TMP") orelse "",
        else => trimSeparator(env.get("TMPDIR") orelse "/tmp"),
    };
    const home = (if (os == .windows) env.get("USERPROFILE") else env.get("HOME")) orelse return "";
    switch (os) {
        .macos, .ios => {
            const sub: []const u8 = switch (loc) {
                .home => return home,
                .app_config, .app_data => return join(a, os, &.{ home, "Library/Application Support", app }),
                .app_cache => return join(a, os, &.{ home, "Library/Caches", app }),
                .documents => "Documents",
                // An iOS app sees its own folders only.
                else => if (os == .ios) return "" else switch (loc) {
                    .desktop => "Desktop",
                    .downloads => "Downloads",
                    .pictures => "Pictures",
                    .music => "Music",
                    .videos => "Movies",
                    else => unreachable,
                },
            };
            return join(a, os, &.{ home, sub });
        },
        .windows => return switch (loc) {
            .home => home,
            .app_config, .app_data => join(a, os, &.{ env.get("APPDATA") orelse return "", app }),
            .app_cache => join(a, os, &.{ env.get("LOCALAPPDATA") orelse return "", app, "cache" }),
            .desktop => join(a, os, &.{ home, "Desktop" }),
            .documents => join(a, os, &.{ home, "Documents" }),
            .downloads => join(a, os, &.{ home, "Downloads" }),
            .pictures => join(a, os, &.{ home, "Pictures" }),
            .music => join(a, os, &.{ home, "Music" }),
            .videos => join(a, os, &.{ home, "Videos" }),
            .temp => unreachable,
        },
        .xdg => {
            const user_dir: struct { []const u8, []const u8 } = switch (loc) {
                .home => return home,
                .app_config => return join(a, os, &.{ (try xdgConfig(a, env)).?, app }),
                .app_data => return join(a, os, &.{ env.get("XDG_DATA_HOME") orelse try join(a, os, &.{ home, ".local/share" }), app }),
                .app_cache => return join(a, os, &.{ env.get("XDG_CACHE_HOME") orelse try join(a, os, &.{ home, ".cache" }), app }),
                .desktop => .{ "XDG_DESKTOP_DIR", "Desktop" },
                .documents => .{ "XDG_DOCUMENTS_DIR", "Documents" },
                .downloads => .{ "XDG_DOWNLOAD_DIR", "Downloads" },
                .pictures => .{ "XDG_PICTURES_DIR", "Pictures" },
                .music => .{ "XDG_MUSIC_DIR", "Music" },
                .videos => .{ "XDG_VIDEOS_DIR", "Videos" },
                .temp => unreachable,
            };
            if (try userDir(a, user_dirs, user_dir[0], home)) |d| return d;
            return join(a, os, &.{ home, user_dir[1] });
        },
        .none => unreachable,
    }
}

/// `$XDG_CONFIG_HOME`, else `~/.config`; null without a home.
fn xdgConfig(a: Allocator, env: Env) Allocator.Error!?[]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |c| return c;
    return try join(a, .xdg, &.{ env.get("HOME") orelse return null, ".config" });
}

/// `name` in `user-dirs.dirs` (lines like `XDG_MUSIC_DIR="$HOME/Music"`).
fn userDir(a: Allocator, user_dirs: []const u8, name: []const u8, home: []const u8) Allocator.Error!?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, user_dirs, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, l, name) or l.len <= name.len or l[name.len] != '=') continue;
        const v = std.mem.trim(u8, l[name.len + 1 ..], "\"");
        if (std.mem.startsWith(u8, v, "$HOME")) return try std.mem.concat(a, u8, &.{ home, v["$HOME".len..] });
        if (std.mem.startsWith(u8, v, "/")) return v;
    }
    return null;
}

fn trimSeparator(p: []const u8) []const u8 {
    return if (p.len > 1 and p[p.len - 1] == '/') p[0 .. p.len - 1] else p;
}

/// `parts` joined by `os`'s separator.
fn join(a: Allocator, os: Platform, parts: []const []const u8) Allocator.Error![]const u8 {
    const sep: []const u8 = if (os == .windows) "\\" else "/";
    var out: std.ArrayList(u8) = .empty;
    for (parts, 0..) |p, i| {
        if (i > 0 and !(out.items.len > 0 and out.items[out.items.len - 1] == sep[0])) try out.appendSlice(a, sep);
        // Within a part, `/` is the separator too.
        for (p) |ch| try out.append(a, if (os == .windows and ch == '/') '\\' else ch);
    }
    return out.items;
}

// ---- The StandardPaths element ----

/// The standard paths as properties (the `StandardPaths` element).
/// Initialize in place with `init`.
pub const StandardPaths = struct {
    item: item_mod.Item = .init(&vtable),
    home: Property([]const u8) = .init(""),
    desktop: Property([]const u8) = .init(""),
    documents: Property([]const u8) = .init(""),
    downloads: Property([]const u8) = .init(""),
    pictures: Property([]const u8) = .init(""),
    music: Property([]const u8) = .init(""),
    videos: Property([]const u8) = .init(""),
    temp: Property([]const u8) = .init(""),
    app_config: Property([]const u8) = .init(""),
    app_data: Property([]const u8) = .init(""),
    app_cache: Property([]const u8) = .init(""),
    gpa: Allocator = undefined,
    owned: [@typeInfo(Location).@"enum".fields.len][]u8 = @splat(&.{}),

    pub fn init(self: *StandardPaths, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        inline for (@typeInfo(Location).@"enum".fields, 0..) |f, i| {
            self.owned[i] = get(gpa, @enumFromInt(f.value)) catch &.{};
            @field(self, f.name).set(self.owned[i]);
        }
    }

    pub fn deinit(self: *StandardPaths) void {
        self.item.deinit();
        inline for (@typeInfo(Location).@"enum".fields, 0..) |f, i| {
            @field(self, f.name).deinit();
            self.gpa.free(self.owned[i]);
        }
    }

    const vtable: item_mod.ItemVTable = .{ .name = "StandardPaths" };
};

// ---- Tests ----

const testing = std.testing;

const TestEnv = struct {
    vars: []const [2][]const u8,

    fn env(self: *const TestEnv) Env {
        return .{ .ctx = self, .getFn = getVar };
    }

    fn getVar(ctx: *const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const TestEnv = @ptrCast(@alignCast(ctx));
        for (self.vars) |v| if (std.mem.eql(u8, v[0], name)) return v[1];
        return null;
    }
};

fn expectAt(expected: []const u8, loc: Location, os: Platform, env: *const TestEnv, user_dirs: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(expected, try resolve(arena.allocator(), loc, os, "notes", env.env(), user_dirs));
}

test "standard paths on macOS and iOS" {
    const env: TestEnv = .{ .vars = &.{ .{ "HOME", "/Users/ann" }, .{ "TMPDIR", "/var/folders/x/T/" } } };
    try expectAt("/Users/ann", .home, .macos, &env, "");
    try expectAt("/Users/ann/Documents", .documents, .macos, &env, "");
    try expectAt("/Users/ann/Movies", .videos, .macos, &env, "");
    try expectAt("/var/folders/x/T", .temp, .macos, &env, "");
    try expectAt("/Users/ann/Library/Application Support/notes", .app_config, .macos, &env, "");
    try expectAt("/Users/ann/Library/Caches/notes", .app_cache, .macos, &env, "");
    // An iOS app has its own documents, and no desktop.
    try expectAt("/Users/ann/Documents", .documents, .ios, &env, "");
    try expectAt("", .desktop, .ios, &env, "");
}

test "standard paths on Windows" {
    const env: TestEnv = .{ .vars = &.{
        .{ "USERPROFILE", "C:\\Users\\ann" },
        .{ "APPDATA", "C:\\Users\\ann\\AppData\\Roaming" },
        .{ "LOCALAPPDATA", "C:\\Users\\ann\\AppData\\Local" },
        .{ "TEMP", "C:\\Temp" },
    } };
    try expectAt("C:\\Users\\ann\\Pictures", .pictures, .windows, &env, "");
    try expectAt("C:\\Users\\ann\\AppData\\Roaming\\notes", .app_data, .windows, &env, "");
    try expectAt("C:\\Users\\ann\\AppData\\Local\\notes\\cache", .app_cache, .windows, &env, "");
    try expectAt("C:\\Temp", .temp, .windows, &env, "");
}

test "standard paths on XDG systems: variables, user-dirs.dirs, defaults" {
    const plain: TestEnv = .{ .vars = &.{.{ "HOME", "/home/ann" }} };
    try expectAt("/home/ann/.config/notes", .app_config, .xdg, &plain, "");
    try expectAt("/home/ann/.local/share/notes", .app_data, .xdg, &plain, "");
    try expectAt("/home/ann/.cache/notes", .app_cache, .xdg, &plain, "");
    try expectAt("/home/ann/Music", .music, .xdg, &plain, "");
    try expectAt("/tmp", .temp, .xdg, &plain, "");
    const set: TestEnv = .{ .vars = &.{ .{ "HOME", "/home/ann" }, .{ "XDG_CONFIG_HOME", "/cfg" }, .{ "XDG_CACHE_HOME", "" } } };
    try expectAt("/cfg/notes", .app_config, .xdg, &set, "");
    try expectAt("/home/ann/.cache/notes", .app_cache, .xdg, &set, ""); // empty is unset
    const dirs = "# written by xdg-user-dirs-update\nXDG_MUSIC_DIR=\"$HOME/Musica\"\nXDG_PICTURES_DIR=\"/data/pics\"\n";
    try expectAt("/home/ann/Musica", .music, .xdg, &plain, dirs);
    try expectAt("/data/pics", .pictures, .xdg, &plain, dirs);
    try expectAt("/home/ann/Documents", .documents, .xdg, &plain, dirs);
}

test "no home, no files: empty" {
    const none: TestEnv = .{ .vars = &.{} };
    try expectAt("", .documents, .xdg, &none, "");
    try expectAt("", .app_config, .macos, &none, "");
    const env: TestEnv = .{ .vars = &.{.{ "HOME", "/home/ann" }} };
    try expectAt("", .home, .none, &env, "");
}

test "the application's name: as set" {
    setApplicationName("notes");
    try testing.expectEqualStrings("notes", applicationName());
}
