// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Settings (the `Settings` element): properties kept from one run of the
//! application to the next. A component that inherits `Settings` has its
//! declared properties stored, under `category`, in an INI file:
//! `settings.ini` in the application's configuration folder
//! (`paths.Location.app_config`), or `file`; or, on Windows with `format`
//! `registry`, in the registry, under `HKEY_CURRENT_USER\Software\<app>`
//! (or `HKEY_CURRENT_USER\<file>`). Saved values replace the
//! defaults once the component and its users are set up (from the next
//! `runChangeHandlers`, so properties linked with `<=>` take them too);
//! changes are written a moment later, and when it is destroyed. Where
//! there are no files (the web, microcontrollers), they last as long as
//! the application.
//!
//! Other values are reached by key: the element's `value`, `setValue`,
//! `contains`, `remove`, `all_keys` and `child_groups`, or, from code, a
//! `Store`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const properties = @import("properties.zig");
const Property = properties.Property;
const item_mod = @import("item.zig");
const model = @import("model.zig");
const Timer = @import("timers.zig").Timer;
const Color = @import("graphics.zig").Color;
const paths = @import("paths.zig");
pub const registry = @import("registry.zig");

const log = std.log.scoped(.zigulee);

/// How long after a change it is written (changes in between are written
/// together).
pub const save_delay_ms = 300;

/// Where the values are kept.
pub const SettingsFormat = enum {
    /// An INI file, on every system.
    ini,
    /// The Windows registry: a key per group under `HKEY_CURRENT_USER`.
    /// An INI file elsewhere.
    registry,
};

/// Whether `registry` uses the registry here.
pub const has_registry = registry.supported;

/// A value read: a number (from the registry's DWORD and QWORD values) or
/// text.
pub const Value = union(enum) {
    number: i64,
    text: []const u8,
};

/// Values by group and key, where `Settings` keeps them: an INI file
/// (a section per group), or on Windows the registry (a key per group).
/// Groups are paths with `/` (`"window/size"`); a key may reach into
/// groups too (`get(a, "window", "size/width")`). Changes to an INI file
/// are written by `sync`; the registry's at once. Values come back as
/// they were set: text as text, numbers in the registry as numbers.
pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    where: union(enum) {
        /// The file's lines; `path` null where there is none (they last
        /// as long as the store).
        ini: struct { path: ?[]const u8, doc: Ini, dirty: bool = false },
        /// The key under `HKEY_CURRENT_USER` (null in tests, unless given).
        registry: ?[]const u8,
    },

    /// Opens the values at `at`: a file, or with `registry` (on
    /// Windows) a key under `HKEY_CURRENT_USER`; "" for the application's
    /// (`settings.ini` in its configuration folder, or `Software\<app>`).
    /// In tests "" is a store of their own, in memory.
    pub fn open(gpa: Allocator, format: SettingsFormat, at: []const u8) Allocator.Error!Store {
        var s: Store = .{ .arena = .init(gpa), .where = undefined };
        errdefer s.arena.deinit();
        const a = s.arena.allocator();
        if (has_registry and format == .registry) {
            s.where = .{ .registry = if (at.len > 0)
                try a.dupe(u8, at)
            else if (builtin.is_test)
                null
            else
                try std.mem.concat(a, u8, &.{ "Software\\", paths.applicationName() }) };
            return s;
        }
        const path = try iniPath(a, at);
        const text = if (path) |p| readFile(a, p) orelse "" else "";
        s.where = .{ .ini = .{ .path = path, .doc = try Ini.parse(a, text) } };
        return s;
    }

    pub fn deinit(s: *Store) void {
        s.arena.deinit();
    }

    /// Where it is: the file, or the registry key; null if nowhere.
    pub fn location(s: *const Store) ?[]const u8 {
        return switch (s.where) {
            .ini => |i| i.path,
            .registry => |r| r,
        };
    }

    /// The value of `key` in `group`; null if there is none. Text is
    /// allocated with `a`.
    pub fn get(s: *Store, a: Allocator, group: []const u8, key: []const u8) ?Value {
        const at = place(a, group, key) catch return null;
        switch (s.where) {
            .ini => |*i| {
                const sec = i.doc.section(at.group) orelse return null;
                const raw = sec.value(at.name) orelse return null;
                return .{ .text = unescape(a, std.mem.trimStart(u8, raw, " \t")) catch return null };
            },
            .registry => |base| {
                if (!has_registry) unreachable;
                const k = registry.open(a, keyPath(a, base orelse return null, at.group) catch return null) orelse return null;
                defer k.close();
                return switch (k.get(a, at.name) orelse return null) {
                    .number => |n| .{ .number = n },
                    .text => |t| .{ .text = t },
                    .other => null,
                };
            },
        }
    }

    /// `get` as text: numbers in decimal.
    pub fn getText(s: *Store, a: Allocator, group: []const u8, key: []const u8) ?[]const u8 {
        return switch (s.get(a, group, key) orelse return null) {
            .text => |t| t,
            .number => |n| std.fmt.allocPrint(a, "{d}", .{n}) catch null,
        };
    }

    pub fn contains(s: *Store, group: []const u8, key: []const u8) bool {
        var arena: std.heap.ArenaAllocator = .init(s.arena.child_allocator);
        defer arena.deinit();
        return s.get(arena.allocator(), group, key) != null;
    }

    /// Sets `key` in `group` to `text` (a string in the registry).
    pub fn setText(s: *Store, group: []const u8, key: []const u8, text: []const u8) !void {
        switch (s.where) {
            .ini => {
                var out: std.Io.Writer.Allocating = .init(s.arena.allocator());
                try writeEscaped(&out.writer, text);
                try s.setIniLine(group, key, out.written());
            },
            .registry => try s.setRegistry(group, key, .{ .text = text }),
        }
    }

    /// Sets `key` in `group` to `n` (in the registry, a DWORD value if it
    /// fits, else a QWORD one).
    pub fn setInt(s: *Store, group: []const u8, key: []const u8, n: i64) !void {
        switch (s.where) {
            .ini => try s.setIniLine(group, key, try std.fmt.allocPrint(s.arena.allocator(), "{d}", .{n})),
            .registry => try s.setRegistry(group, key, .{ .number = n }),
        }
    }

    /// Sets `key` in `group` to `true` or `false` (in the registry, a
    /// DWORD value, 1 or 0).
    pub fn setBool(s: *Store, group: []const u8, key: []const u8, b: bool) !void {
        switch (s.where) {
            .ini => try s.setIniLine(group, key, if (b) "true" else "false"),
            .registry => try s.setRegistry(group, key, .{ .number = @intFromBool(b) }),
        }
    }

    fn setIniLine(s: *Store, group: []const u8, key: []const u8, value: []const u8) !void {
        const a = s.arena.allocator();
        const at = try place(a, group, key);
        if (at.name.len == 0) return error.InvalidKey;
        const sec = try s.where.ini.doc.sectionOrNew(a, at.group);
        try sec.set(a, at.name, try std.mem.concat(a, u8, &.{ at.name, "=", value }));
        s.where.ini.dirty = true;
    }

    fn setRegistry(s: *Store, group: []const u8, key: []const u8, v: Value) !void {
        if (!has_registry) unreachable;
        var arena: std.heap.ArenaAllocator = .init(s.arena.child_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const at = try place(a, group, key);
        if (at.name.len == 0) return error.InvalidKey;
        const k = try registry.create(a, try keyPath(a, s.where.registry orelse return, at.group));
        defer k.close();
        switch (v) {
            .text => |t| try k.setString(a, at.name, t),
            .number => |n| if (std.math.cast(i32, n)) |small|
                try k.setDword(a, at.name, @bitCast(small))
            else
                try k.setQword(a, at.name, @bitCast(n)),
        }
    }

    /// Removes `key` from `group`, and the group of that name with
    /// everything in it (`key` "": `group` itself; both "": everything).
    pub fn remove(s: *Store, group: []const u8, key: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(s.arena.child_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const at = try place(a, group, key);
        const full = try joinPath(a, at.group, at.name);
        switch (s.where) {
            .ini => |*i| {
                if (at.name.len > 0) if (i.doc.section(at.group)) |sec| {
                    if (sec.remove(at.name)) i.dirty = true;
                };
                if (i.doc.removeGroup(full)) i.dirty = true;
            },
            .registry => |base_or_null| {
                if (!has_registry) unreachable;
                const base = base_or_null orelse return;
                if (at.name.len > 0) if (registry.open(a, try keyPath(a, base, at.group))) |k| {
                    // `open` reads only: deleting needs a key opened for writing.
                    k.close();
                    const w = try registry.create(a, try keyPath(a, base, at.group));
                    defer w.close();
                    _ = w.deleteValue(a, at.name);
                };
                _ = registry.deleteTree(a, try keyPath(a, base, full));
            },
        }
    }

    /// The keys in `group` (not those in its groups), allocated with `a`.
    pub fn keys(s: *Store, a: Allocator, group: []const u8) Allocator.Error![]const []const u8 {
        const g = try place(a, group, "");
        switch (s.where) {
            .ini => |*i| {
                const sec = i.doc.section(g.group) orelse return &.{};
                var list: std.ArrayList([]const u8) = .empty;
                for (sec.lines.items) |l| if (l.key) |k| try list.append(a, try a.dupe(u8, k));
                return list.items;
            },
            .registry => |base| {
                if (!has_registry) unreachable;
                const k = registry.open(a, try keyPath(a, base orelse return &.{}, g.group)) orelse return &.{};
                defer k.close();
                return k.valueNames(a) catch |err| switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => &.{},
                };
            },
        }
    }

    /// The groups in `group` (its children only), allocated with `a`.
    pub fn groups(s: *Store, a: Allocator, group: []const u8) Allocator.Error![]const []const u8 {
        const g = try place(a, group, "");
        switch (s.where) {
            .ini => |*i| {
                var list: std.ArrayList([]const u8) = .empty;
                for (i.doc.sections.items[1..]) |sec| {
                    const rest = if (g.group.len == 0)
                        sec.name
                    else if (sec.name.len > g.group.len and std.mem.startsWith(u8, sec.name, g.group) and sec.name[g.group.len] == '/')
                        sec.name[g.group.len + 1 ..]
                    else
                        continue;
                    const child = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
                    if (child.len == 0) continue;
                    for (list.items) |c| {
                        if (std.mem.eql(u8, c, child)) break;
                    } else try list.append(a, try a.dupe(u8, child));
                }
                return list.items;
            },
            .registry => |base| {
                if (!has_registry) unreachable;
                const k = registry.open(a, try keyPath(a, base orelse return &.{}, g.group)) orelse return &.{};
                defer k.close();
                return k.subkeys(a) catch |err| switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => &.{},
                };
            },
        }
    }

    /// Writes the changes to an INI file (keeping what else it holds).
    pub fn sync(s: *Store) !void {
        switch (s.where) {
            .ini => |*i| {
                if (!i.dirty) return;
                const path = i.path orelse return;
                var arena: std.heap.ArenaAllocator = .init(s.arena.child_allocator);
                defer arena.deinit();
                try writeFile(arena.allocator(), path, try i.doc.write(arena.allocator()));
                i.dirty = false;
            },
            .registry => {},
        }
    }

    /// The INI file for `location`; null where there are no files (and
    /// in tests, unless it is given: they leave the user's alone).
    fn iniPath(a: Allocator, at: []const u8) Allocator.Error!?[]const u8 {
        if (!paths.has_files) return null;
        if (at.len > 0) return try a.dupe(u8, at);
        if (builtin.is_test) return null;
        const dir = try paths.get(a, .app_config);
        if (dir.len == 0) return null;
        return try std.fs.path.join(a, &.{ dir, "settings.ini" });
    }

    const Place = struct { group: []const u8, name: []const u8 };

    /// `key` in `group` as the group it is in and its name (`key` "":
    /// `group` itself, no name). `/` between groups, none at the ends
    /// (`\` taken for `/`).
    fn place(a: Allocator, group: []const u8, key: []const u8) Allocator.Error!Place {
        const full = try joinPath(a, group, key);
        std.mem.replaceScalar(u8, full, '\\', '/');
        if (key.len == 0) return .{ .group = full, .name = "" };
        const i = std.mem.lastIndexOfScalar(u8, full, '/') orelse return .{ .group = "", .name = full };
        return .{ .group = full[0..i], .name = full[i + 1 ..] };
    }

    fn joinPath(a: Allocator, group: []const u8, key: []const u8) Allocator.Error![]u8 {
        const g = std.mem.trim(u8, group, "/\\");
        const k = std.mem.trim(u8, key, "/\\");
        if (g.len == 0) return a.dupe(u8, k);
        if (k.len == 0) return a.dupe(u8, g);
        return std.mem.concat(a, u8, &.{ g, "/", k });
    }

    fn keyPath(a: Allocator, base: []const u8, group: []const u8) Allocator.Error![]const u8 {
        return joinPath(a, base, group);
    }
};

/// Initialize in place with `init`.
pub const Settings = struct {
    item: item_mod.Item = .init(&vtable),
    /// The group its values are in: a section of the file, a key in the
    /// registry ("": the file's lines before any section, or the key
    /// itself). `/` separates groups in it.
    category: Property([]const u8) = .init(""),
    /// The file; empty for `settings.ini` in the application's
    /// configuration folder.
    file: Property([]const u8) = .init(""),
    /// Where they are kept. With `registry` on Windows, `file` is the key
    /// under `HKEY_CURRENT_USER` (`Software\<app>` if empty; `/`
    /// separates keys too), and each category a key in it.
    format: Property(SettingsFormat) = .init(.ini),
    /// The keys in `category` (theirs and others'), as last read or
    /// written.
    all_keys: Property(model.Model([]const u8)) = undefined,
    /// The groups in `category`, as last read or written.
    child_groups: Property(model.Model([]const u8)) = undefined,

    gpa: Allocator = undefined,
    entries: std.ArrayList(Entry) = .empty,
    /// Strings read from the file, which properties may show.
    strings: std.ArrayList([]u8) = .empty,
    start: properties.Deferred = .{},
    tracker: properties.ChangeTracker(u64) = undefined,
    tracking: bool = false,
    save_timer: Timer = .{},
    /// Its values as last read or written, to write only changes.
    last: []u8 = &.{},
    key_list: model.VecModel([]const u8) = undefined,
    group_list: model.VecModel([]const u8) = undefined,
    /// What `value` returned last.
    value_text: []u8 = &.{},

    /// The kinds of values it keeps.
    pub const Kind = enum { int, float, duration, bool, string, color };

    const Entry = struct {
        /// Lives as long as the element (the property's name).
        key: []const u8,
        kind: Kind,
        /// A `Property` of the kind's type.
        ptr: *anyopaque,
    };

    pub fn init(self: *Settings, gpa: Allocator) void {
        self.* = .{ .gpa = gpa, .key_list = .init(gpa), .group_list = .init(gpa) };
        self.all_keys = .init(self.key_list.model());
        self.child_groups = .init(self.group_list.model());
        self.start = .init(self, begin);
    }

    pub fn deinit(self: *Settings) void {
        self.start.cancel();
        if (self.save_timer.isRunning()) self.save();
        self.save_timer.deinit();
        if (self.tracking) self.tracker.deinit();
        for (self.strings.items) |s| self.gpa.free(s);
        self.strings.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.gpa.free(self.last);
        self.gpa.free(self.value_text);
        freeAll(self.gpa, &self.key_list);
        freeAll(self.gpa, &self.group_list);
        self.key_list.deinit();
        self.group_list.deinit();
        self.item.deinit();
        self.category.deinit();
        self.file.deinit();
        self.format.deinit();
        self.all_keys.deinit();
        self.child_groups.deinit();
    }

    /// The kind of a property's values, or null if they cannot be kept.
    pub fn kindOf(comptime T: type) ?Kind {
        return switch (T) {
            i32 => .int,
            f32 => .float,
            i64 => .duration,
            bool => .bool,
            []const u8 => .string,
            Color => .color,
            else => null,
        };
    }

    /// Keeps `p` under `key` (which must outlive the element): its saved
    /// value replaces the one it has from the next `runChangeHandlers`.
    pub fn add(self: *Settings, comptime T: type, key: []const u8, p: *Property(T)) Allocator.Error!void {
        const kind = comptime kindOf(T) orelse @compileError("Settings cannot keep a " ++ @typeName(T));
        try self.addKind(kind, key, p);
    }

    /// `add` for a property known by its kind.
    pub fn addKind(self: *Settings, kind: Kind, key: []const u8, p: *anyopaque) Allocator.Error!void {
        try self.entries.append(self.gpa, .{ .key = key, .kind = kind, .ptr = p });
        self.start.schedule();
    }

    /// Where its values are, opened.
    pub fn openStore(self: *Settings) Allocator.Error!Store {
        return Store.open(self.gpa, self.format.getUntracked(), self.file.getUntracked());
    }

    /// The value of `key` in `category` (`/` reaches into its groups) as
    /// text, "" if there is none; numbers in the registry in decimal. The
    /// text lasts until the next call.
    pub fn value(self: *Settings, key: []const u8) []const u8 {
        self.flush();
        var store = self.openStore() catch return "";
        defer store.deinit();
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const text = store.getText(arena.allocator(), self.category.getUntracked(), key) orelse "";
        const copy = self.gpa.dupe(u8, text) catch return "";
        self.gpa.free(self.value_text);
        self.value_text = copy;
        return copy;
    }

    /// Whether `key` has a value in `category`.
    pub fn contains(self: *Settings, key: []const u8) bool {
        self.flush();
        var store = self.openStore() catch return false;
        defer store.deinit();
        return store.contains(self.category.getUntracked(), key);
    }

    /// Sets `key` in `category` to `text`, at once (and a property it
    /// keeps under that key to it, if it is a value of its kind).
    pub fn setValue(self: *Settings, key: []const u8, text: []const u8) void {
        self.flush();
        for (self.entries.items) |e| if (std.mem.eql(u8, e.key, key)) self.setFrom(e, .{ .text = text });
        var store = self.openStore() catch return;
        defer store.deinit();
        store.setText(self.category.getUntracked(), key, text) catch |err|
            return log.warn("cannot set the setting '{s}': {t}", .{ key, err });
        self.finish(&store);
    }

    /// Removes `key` from `category`, and the group of that name with
    /// everything in it ("": everything in `category`). The properties it
    /// keeps stay as they are (and are written again when they change).
    pub fn remove(self: *Settings, key: []const u8) void {
        self.flush();
        var store = self.openStore() catch return;
        defer store.deinit();
        store.remove(self.category.getUntracked(), key) catch |err|
            return log.warn("cannot remove the setting '{s}': {t}", .{ key, err });
        self.finish(&store);
    }

    /// Writes changes waiting for the timer.
    fn flush(self: *Settings) void {
        if (self.save_timer.isRunning()) self.save();
    }

    /// Writes the store, then lists what it holds.
    fn finish(self: *Settings, store: *Store) void {
        store.sync() catch |err|
            log.warn("cannot write the settings to '{s}': {t}", .{ store.location() orelse "", err });
        self.refreshLists(store);
    }

    /// Reads the saved values into the properties, then watches them.
    fn begin(self: *Settings) void {
        if (self.tracking) {
            self.tracker.deinit();
            self.tracking = false;
        }
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var store = self.openStore() catch return;
        defer store.deinit();
        const category = self.category.getUntracked();
        for (self.entries.items) |e| if (store.get(a, category, e.key)) |v| self.setFrom(e, v);
        self.refreshLists(&store);
        self.gpa.free(self.last);
        self.last = self.serialize(self.gpa) catch &.{};
        self.tracker.init(self.gpa, self, hashValues, changed);
        self.tracking = true;
    }

    fn hashValues(self: *Settings) u64 {
        var h: std.hash.Wyhash = .init(0);
        for (self.entries.items) |e| switch (e.kind) {
            inline else => |k| {
                const v = prop(k, e).get();
                if (k == .string) h.update(v) else h.update(std.mem.asBytes(&v));
                h.update(&.{0});
            },
        };
        return h.final();
    }

    fn changed(self: *Settings, _: u64) void {
        self.save_timer.start(.single_shot, save_delay_ms, self, save);
    }

    /// Writes its values, if they changed (keeping what else is there).
    pub fn save(self: *Settings) void {
        self.save_timer.stop();
        const now = self.serialize(self.gpa) catch return;
        if (std.mem.eql(u8, now, self.last)) return self.gpa.free(now);
        self.gpa.free(self.last);
        self.last = now;
        var store = self.openStore() catch return;
        defer store.deinit();
        self.writeEntries(&store) catch |err|
            return log.warn("cannot write the settings to '{s}': {t}", .{ store.location() orelse "", err });
        self.finish(&store);
    }

    fn writeEntries(self: *Settings, store: *Store) !void {
        const category = self.category.getUntracked();
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        for (self.entries.items) |e| switch (e.kind) {
            .int => try store.setInt(category, e.key, prop(.int, e).getUntracked()),
            .duration => try store.setInt(category, e.key, prop(.duration, e).getUntracked()),
            .bool => try store.setBool(category, e.key, prop(.bool, e).getUntracked()),
            .string => try store.setText(category, e.key, prop(.string, e).getUntracked()),
            .float, .color => {
                var out: std.Io.Writer.Allocating = .init(arena.allocator());
                try writeValue(&out.writer, e);
                try store.setText(category, e.key, out.written());
            },
        };
    }

    /// Lists the keys and groups in `category` (if they changed).
    fn refreshLists(self: *Settings, store: *Store) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const category = self.category.getUntracked();
        replaceAll(self.gpa, &self.key_list, store.keys(a, category) catch return);
        replaceAll(self.gpa, &self.group_list, store.groups(a, category) catch return);
    }

    /// Its values, one line `key=value` each, in the order added.
    fn serialize(self: *Settings, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) w.writeByte('\n') catch return error.OutOfMemory;
            w.print("{s}=", .{e.key}) catch return error.OutOfMemory;
            switch (e.kind) {
                .string => writeEscaped(w, prop(.string, e).getUntracked()) catch return error.OutOfMemory,
                else => writeValue(w, e) catch return error.OutOfMemory,
            }
        }
        return out.toOwnedSlice();
    }

    /// Its value as text (strings as they are).
    fn writeValue(w: *std.Io.Writer, e: Entry) std.Io.Writer.Error!void {
        switch (e.kind) {
            .int => try w.print("{d}", .{prop(.int, e).getUntracked()}),
            .float => try w.print("{d}", .{prop(.float, e).getUntracked()}),
            .duration => try w.print("{d}", .{prop(.duration, e).getUntracked()}),
            .bool => try w.writeAll(if (prop(.bool, e).getUntracked()) "true" else "false"),
            .color => {
                const c = prop(.color, e).getUntracked();
                try w.print("#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b, c.a });
            },
            .string => try w.writeAll(prop(.string, e).getUntracked()),
        }
    }

    /// Sets `e`'s property from a value read (left as it is if that is
    /// not a value of its kind).
    fn setFrom(self: *Settings, e: Entry, v: Value) void {
        switch (v) {
            .number => |n| switch (e.kind) {
                .int => prop(.int, e).set(@truncate(n)),
                .duration => prop(.duration, e).set(n),
                .bool => prop(.bool, e).set(n != 0),
                .float => prop(.float, e).set(@floatFromInt(n)),
                .string => {
                    const s = std.fmt.allocPrint(self.gpa, "{d}", .{n}) catch return;
                    self.keepString(e, s);
                },
                .color => {},
            },
            .text => |text| switch (e.kind) {
                .int => prop(.int, e).set(std.fmt.parseInt(i32, text, 10) catch return),
                .float => prop(.float, e).set(std.fmt.parseFloat(f32, text) catch return),
                .duration => prop(.duration, e).set(std.fmt.parseInt(i64, text, 10) catch return),
                .bool => prop(.bool, e).set(if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1")) true else if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "0")) false else return),
                .color => {
                    if (text.len != 9 or text[0] != '#') return;
                    const c = std.fmt.parseInt(u32, text[1..], 16) catch return;
                    prop(.color, e).set(.{ .r = @truncate(c >> 24), .g = @truncate(c >> 16), .b = @truncate(c >> 8), .a = @truncate(c) });
                },
                .string => self.keepString(e, self.gpa.dupe(u8, text) catch return),
            },
        }
    }

    /// Sets `e`'s string property to `s` (owned from now on).
    fn keepString(self: *Settings, e: Entry, s: []u8) void {
        self.strings.append(self.gpa, s) catch return self.gpa.free(s);
        prop(.string, e).set(s);
    }

    fn Field(comptime k: Kind) type {
        return switch (k) {
            .int => i32,
            .float => f32,
            .duration => i64,
            .bool => bool,
            .string => []const u8,
            .color => Color,
        };
    }

    fn prop(comptime k: Kind, e: Entry) *Property(Field(k)) {
        return @ptrCast(@alignCast(e.ptr));
    }

    const vtable: item_mod.ItemVTable = .{ .name = "Settings" };
};

fn freeAll(gpa: Allocator, list: *model.VecModel([]const u8)) void {
    for (list.items.items) |s| gpa.free(s);
}

/// Sets `list` to copies of `names`, if they differ.
fn replaceAll(gpa: Allocator, list: *model.VecModel([]const u8), names: []const []const u8) void {
    if (names.len == list.items.items.len) {
        for (names, list.items.items) |n, o| {
            if (!std.mem.eql(u8, n, o)) break;
        } else return;
    }
    var copies: std.ArrayList([]const u8) = .empty;
    defer copies.deinit(gpa);
    for (names) |n| {
        const copy = gpa.dupe(u8, n) catch break;
        copies.append(gpa, copy) catch {
            gpa.free(copy);
            break;
        };
    }
    const old = gpa.dupe([]const u8, list.items.items) catch return for (copies.items) |c| gpa.free(c);
    defer {
        for (old) |s| gpa.free(s);
        gpa.free(old);
    }
    list.setAll(copies.items) catch {};
}

/// `text` as an INI value: backslashes and line breaks escaped.
fn writeEscaped(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |ch| switch (ch) {
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(ch),
    };
}

fn unescape(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\' or i + 1 == text.len) {
            try out.append(gpa, text[i]);
            continue;
        }
        i += 1;
        try out.append(gpa, switch (text[i]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => text[i],
        });
    }
    return out.toOwnedSlice(gpa);
}

fn readFile(a: Allocator, path: []const u8) ?[]const u8 {
    if (!paths.has_files) return null;
    var t: std.Io.Threaded = .init_single_threaded;
    return std.Io.Dir.cwd().readFileAlloc(t.io(), path, a, .limited(1 << 20)) catch null;
}

/// Writes `data` to `path` whole: into a file beside it, then renamed
/// (its folder made if needed). Does nothing where there are no files.
pub fn writeFile(a: Allocator, path: []const u8, data: []const u8) !void {
    if (!paths.has_files) return;
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
    const tmp = try std.mem.concat(a, u8, &.{ path, ".new" });
    defer a.free(tmp);
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = data });
    try cwd.rename(tmp, cwd, path, io);
}

/// An INI file's lines by section, kept as written (comments too).
const Ini = struct {
    /// The first is the lines before any `[section]`.
    sections: std.ArrayList(Section) = .empty,

    const Line = struct {
        /// For `key=value` lines.
        key: ?[]const u8,
        text: []const u8,
    };

    const Section = struct {
        name: []const u8,
        lines: std.ArrayList(Line) = .empty,

        fn value(s: *const Section, key: []const u8) ?[]const u8 {
            for (s.lines.items) |l| if (l.key) |k| if (std.mem.eql(u8, k, key))
                return l.text[std.mem.indexOfScalar(u8, l.text, '=').? + 1 ..];
            return null;
        }

        /// Removes the line of `key`; false if there is none.
        fn remove(s: *Section, key: []const u8) bool {
            for (s.lines.items, 0..) |l, i| if (l.key) |k| if (std.mem.eql(u8, k, key)) {
                _ = s.lines.orderedRemove(i);
                return true;
            };
            return false;
        }

        /// Sets the line of `key` to `line` (`key=value`).
        fn set(s: *Section, a: Allocator, key: []const u8, line: []const u8) Allocator.Error!void {
            for (s.lines.items) |*l| if (l.key) |k| if (std.mem.eql(u8, k, key)) {
                l.text = line;
                return;
            };
            // After its last value (before trailing blank lines).
            var at = s.lines.items.len;
            while (at > 0 and s.lines.items[at - 1].key == null and s.lines.items[at - 1].text.len == 0) at -= 1;
            try s.lines.insert(a, at, .{ .key = key, .text = line });
        }
    };

    fn parse(a: Allocator, text: []const u8) Allocator.Error!Ini {
        var ini: Ini = .{};
        try ini.sections.append(a, .{ .name = "" });
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            if (lines.peek() == null and raw.len == 0) break; // the final newline
            const l = std.mem.trimEnd(u8, raw, "\r");
            const t = std.mem.trim(u8, l, " \t");
            if (t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']') {
                try ini.sections.append(a, .{ .name = t[1 .. t.len - 1] });
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, l, '=');
            const comment = t.len > 0 and (t[0] == '#' or t[0] == ';');
            const key = if (eq != null and !comment) std.mem.trim(u8, l[0..eq.?], " \t") else null;
            const sec = &ini.sections.items[ini.sections.items.len - 1];
            try sec.lines.append(a, .{ .key = key, .text = l });
        }
        return ini;
    }

    /// Removes the section `name` and those in it ("": every value).
    fn removeGroup(ini: *Ini, name: []const u8) bool {
        var removed = false;
        if (name.len == 0) {
            const top = &ini.sections.items[0];
            var i: usize = 0;
            while (i < top.lines.items.len) {
                if (top.lines.items[i].key != null) {
                    _ = top.lines.orderedRemove(i);
                    removed = true;
                } else i += 1;
            }
        }
        var i: usize = 1;
        while (i < ini.sections.items.len) {
            const n = ini.sections.items[i].name;
            if (name.len == 0 or std.mem.eql(u8, n, name) or (n.len > name.len and std.mem.startsWith(u8, n, name) and n[name.len] == '/')) {
                _ = ini.sections.orderedRemove(i);
                removed = true;
            } else i += 1;
        }
        return removed;
    }

    fn section(ini: *Ini, name: []const u8) ?*Section {
        for (ini.sections.items) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    fn sectionOrNew(ini: *Ini, a: Allocator, name: []const u8) Allocator.Error!*Section {
        if (ini.section(name)) |s| return s;
        try ini.sections.append(a, .{ .name = name });
        return &ini.sections.items[ini.sections.items.len - 1];
    }

    fn write(ini: *const Ini, a: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (ini.sections.items, 0..) |s, i| {
            if (i > 0) {
                if (out.items.len > 0 and !std.mem.endsWith(u8, out.items, "\n\n")) try out.append(a, '\n');
                try out.print(a, "[{s}]\n", .{s.name});
            }
            for (s.lines.items) |l| {
                try out.appendSlice(a, l.text);
                try out.append(a, '\n');
            }
        }
        return out.items;
    }
};

// ---- Tests ----

const testing = std.testing;
const timers = @import("timers.zig");
const time = @import("time.zig");

test "INI: values by section, written back as they were with changes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "top=1\n\n[window]\n# where it was\nwidth = 640\nmaximized=false\n\n[other]\nkey=a=b\n";
    var ini = try Ini.parse(a, text);
    try testing.expectEqualStrings("1", ini.section("").?.value("top").?);
    try testing.expectEqualStrings(" 640", ini.section("window").?.value("width").?);
    try testing.expectEqualStrings("a=b", ini.section("other").?.value("key").?);
    try testing.expect(ini.section("nope") == null);
    try testing.expectEqualStrings(text, try ini.write(a));

    const w = ini.section("window").?;
    try w.set(a, "width", "width=800");
    try w.set(a, "height", "height=600");
    const new = try ini.sectionOrNew(a, "fresh");
    try new.set(a, "x", "x=1");
    try testing.expectEqualStrings(
        "top=1\n\n[window]\n# where it was\nwidth=800\nmaximized=false\nheight=600\n\n[other]\nkey=a=b\n\n[fresh]\nx=1\n",
        try ini.write(a),
    );
}

const TestValues = struct {
    count: Property(i32) = .init(3),
    zoom: Property(f32) = .init(1.5),
    dark: Property(bool) = .init(false),
    name: Property([]const u8) = .init("plain"),
    tint: Property(Color) = .init(.{ .r = 1, .g = 2, .b = 3, .a = 255 }),
    wait: Property(i64) = .init(250),

    fn deinit(v: *TestValues) void {
        inline for (@typeInfo(TestValues).@"struct".fields) |f| @field(v, f.name).deinit();
    }

    fn addTo(v: *TestValues, s: *Settings) !void {
        try s.add(i32, "count", &v.count);
        try s.add(f32, "zoom", &v.zoom);
        try s.add(bool, "dark", &v.dark);
        try s.add([]const u8, "name", &v.name);
        try s.add(Color, "tint", &v.tint);
        try s.add(i64, "wait", &v.wait);
    }
};

test "settings: saved after a change, read back by the next run" {
    if (!paths.has_files) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var t: std.Io.Threaded = .init_single_threaded;
    const dir = try tmp.dir.realPathFileAlloc(t.io(), ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "sub", "app.ini" });
    defer testing.allocator.free(path);
    // Someone else's values in the file stay.
    try tmp.dir.createDirPath(t.io(), "sub");
    try tmp.dir.writeFile(t.io(), .{ .sub_path = "sub/app.ini", .data = "[other]\nkept=yes\n" });

    {
        var v: TestValues = .{};
        defer v.deinit();
        var s: Settings = undefined;
        s.init(testing.allocator);
        defer s.deinit();
        s.file.set(path);
        s.category.set("view");
        try v.addTo(&s);
        properties.runChangeHandlers();
        // Nothing saved yet: the defaults stay, and are not written.
        try testing.expectEqual(@as(i32, 3), v.count.get());
        try testing.expect(!s.save_timer.isRunning());

        v.count.set(7);
        v.zoom.set(0.25);
        v.dark.set(true);
        v.name.set("two\nlines \\ here");
        v.tint.set(.{ .r = 0xab, .g = 0xcd, .b = 0xef, .a = 0x80 });
        properties.runChangeHandlers();
        try testing.expect(s.save_timer.isRunning());
        time.advanceTo(time.now() + save_delay_ms);
        timers.updateTimers();
        try testing.expect(!s.save_timer.isRunning());
        const text = try tmp.dir.readFileAlloc(t.io(), "sub/app.ini", testing.allocator, .unlimited);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(
            "[other]\nkept=yes\n\n[view]\ncount=7\nzoom=0.25\ndark=true\nname=two\\nlines \\\\ here\ntint=#abcdef80\nwait=250\n",
            text,
        );
        // A change not written yet is written when it goes.
        v.count.set(8);
        properties.runChangeHandlers();
    }

    var v: TestValues = .{};
    defer v.deinit();
    var s: Settings = undefined;
    s.init(testing.allocator);
    defer s.deinit();
    s.file.set(path);
    s.category.set("view");
    try v.addTo(&s);
    properties.runChangeHandlers();
    try testing.expectEqual(@as(i32, 8), v.count.get());
    try testing.expectEqual(@as(f32, 0.25), v.zoom.get());
    try testing.expect(v.dark.get());
    try testing.expectEqualStrings("two\nlines \\ here", v.name.get());
    try testing.expectEqual(Color{ .r = 0xab, .g = 0xcd, .b = 0xef, .a = 0x80 }, v.tint.get());
    try testing.expectEqual(@as(i64, 250), v.wait.get());
    // Read, not changed: nothing to write.
    try testing.expect(!s.save_timer.isRunning());
}

test "settings: values that are not of their kind leave the default" {
    if (!paths.has_files) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var t: std.Io.Threaded = .init_single_threaded;
    try tmp.dir.writeFile(t.io(), .{ .sub_path = "bad.ini", .data = "count=many\ndark=yes\ntint=red\nzoom=2\n" });
    const dir = try tmp.dir.realPathFileAlloc(t.io(), ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "bad.ini" });
    defer testing.allocator.free(path);
    var v: TestValues = .{};
    defer v.deinit();
    var s: Settings = undefined;
    s.init(testing.allocator);
    defer s.deinit();
    s.file.set(path);
    try v.addTo(&s);
    properties.runChangeHandlers();
    try testing.expectEqual(@as(i32, 3), v.count.get());
    try testing.expect(!v.dark.get());
    try testing.expectEqual(@as(f32, 2), v.zoom.get());
}

test "settings store: keys and groups in an INI file, nested, removed" {
    if (!paths.has_files) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var t: std.Io.Threaded = .init_single_threaded;
    try tmp.dir.writeFile(t.io(), .{ .sub_path = "s.ini", .data = "top=1\n; a note\n[view]\nzoom = 2\n[view/window]\nwidth=640\n[view/window/frame]\nx=1\n[other]\nk=v\n" });
    const dir = try tmp.dir.realPathFileAlloc(t.io(), ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "s.ini" });
    defer testing.allocator.free(path);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s = try Store.open(testing.allocator, .ini, path);
    defer s.deinit();
    try testing.expectEqualStrings("2", s.getText(a, "view", "zoom").?);
    try testing.expectEqualStrings("640", s.getText(a, "view", "window/width").?);
    try testing.expectEqualStrings("640", s.getText(a, "", "view/window/width").?);
    try testing.expectEqualStrings("1", s.getText(a, "/", "top").?);
    try testing.expect(s.get(a, "view", "width") == null);
    try testing.expect(s.contains("view/window", "width"));
    try testing.expect(!s.contains("view", "nope"));

    try testing.expectEqualDeep(&[_][]const u8{"top"}, try s.keys(a, ""));
    try testing.expectEqualDeep(&[_][]const u8{"zoom"}, try s.keys(a, "view"));
    try testing.expectEqualDeep(&[_][]const u8{ "view", "other" }, try s.groups(a, ""));
    try testing.expectEqualDeep(&[_][]const u8{"window"}, try s.groups(a, "view"));
    try testing.expectEqualDeep(&[_][]const u8{"frame"}, try s.groups(a, "view/window"));
    try testing.expectEqual(@as(usize, 0), (try s.groups(a, "other")).len);

    try s.setText("view", "title", "a\nb");
    try s.setInt("view", "new/n", -4);
    try s.setBool("", "on", true);
    try testing.expectEqualStrings("a\nb", s.getText(a, "view", "title").?);
    try testing.expectEqualDeep(&[_][]const u8{ "window", "new" }, try s.groups(a, "view"));
    // A key and a group of that name.
    try s.remove("view", "window");
    try s.remove("", "other/k");
    try s.sync();
    const text = try tmp.dir.readFileAlloc(t.io(), "s.ini", a, .unlimited);
    try testing.expectEqualStrings("top=1\n; a note\non=true\n\n[view]\nzoom = 2\ntitle=a\\nb\n\n[other]\n\n[view/new]\nn=-4\n", text);

    // Everything in a group, then everything.
    try s.remove("view", "");
    try testing.expectEqualDeep(&[_][]const u8{"other"}, try s.groups(a, ""));
    try s.remove("", "");
    try testing.expectEqual(@as(usize, 0), (try s.keys(a, "")).len);
    try testing.expectEqual(@as(usize, 0), (try s.groups(a, "")).len);
}

test "settings: values by key beside the properties, keys and groups listed" {
    if (!paths.has_files) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var t: std.Io.Threaded = .init_single_threaded;
    try tmp.dir.writeFile(t.io(), .{ .sub_path = "app.ini", .data = "[view]\nrecent=a.txt\n[view/columns]\nname=120\n" });
    const dir = try tmp.dir.realPathFileAlloc(t.io(), ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "app.ini" });
    defer testing.allocator.free(path);

    var v: TestValues = .{};
    defer v.deinit();
    var s: Settings = undefined;
    s.init(testing.allocator);
    defer s.deinit();
    s.file.set(path);
    s.category.set("view");
    try s.add(i32, "count", &v.count);
    properties.runChangeHandlers();

    try testing.expectEqualStrings("a.txt", s.value("recent"));
    try testing.expectEqualStrings("120", s.value("columns/name"));
    try testing.expectEqualStrings("", s.value("nope"));
    try testing.expect(s.contains("recent"));
    try testing.expect(!s.contains("count"));
    try testing.expectEqual(@as(usize, 1), s.all_keys.get().rowCount());
    try testing.expectEqualStrings("columns", s.child_groups.get().rowData(0).?);

    // A change waiting for the timer is written before a value is read.
    v.count.set(5);
    properties.runChangeHandlers();
    try testing.expectEqualStrings("5", s.value("count"));
    try testing.expectEqual(@as(usize, 2), s.all_keys.get().rowCount());

    // Setting a kept property's key sets the property.
    s.setValue("count", "9");
    try testing.expectEqual(@as(i32, 9), v.count.get());
    s.setValue("columns/size", "80");
    s.setValue("recent", "b.txt");
    s.remove("columns/name");
    properties.runChangeHandlers();
    try testing.expect(!s.save_timer.isRunning() or blk: {
        s.save();
        break :blk true;
    });
    const text = try tmp.dir.readFileAlloc(t.io(), "app.ini", testing.allocator, .unlimited);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("[view]\nrecent=b.txt\ncount=9\n\n[view/columns]\nsize=80\n", text);

    s.remove("columns");
    try testing.expectEqual(@as(usize, 0), s.child_groups.get().rowCount());
    s.remove("");
    try testing.expectEqual(@as(usize, 0), s.all_keys.get().rowCount());
    try testing.expectEqual(@as(i32, 9), v.count.get());
}

test "settings: kept in the registry on Windows, read back by the next run" {
    if (!has_registry) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = "Software\\zigulee-test-settings";
    _ = registry.deleteTree(a, key);
    defer _ = registry.deleteTree(a, key);

    {
        var v: TestValues = .{};
        defer v.deinit();
        var s: Settings = undefined;
        s.init(testing.allocator);
        defer s.deinit();
        s.format.set(.registry);
        s.file.set("Software/zigulee-test-settings");
        s.category.set("view");
        try v.addTo(&s);
        properties.runChangeHandlers();
        try testing.expectEqual(@as(i32, 3), v.count.get());

        v.count.set(-7);
        v.zoom.set(0.25);
        v.dark.set(true);
        v.name.set("two\nlines \\ hère");
        v.tint.set(.{ .r = 0xab, .g = 0xcd, .b = 0xef, .a = 0x80 });
        v.wait.set(1 << 40);
        properties.runChangeHandlers();
        s.save();
        s.setValue("columns/name", "120");

        const k = registry.open(a, key ++ "\\view").?;
        defer k.close();
        try testing.expectEqual(@as(i64, -7), k.get(a, "count").?.number);
        try testing.expectEqual(@as(i64, 1), k.get(a, "dark").?.number);
        try testing.expectEqual(@as(i64, 1 << 40), k.get(a, "wait").?.number);
        try testing.expectEqualStrings("#abcdef80", k.get(a, "tint").?.text);
        try testing.expectEqual(@as(usize, 6), s.all_keys.get().rowCount());
        try testing.expectEqualStrings("columns", s.child_groups.get().rowData(0).?);
        try testing.expectEqualStrings("-7", s.value("count"));
        try testing.expectEqualStrings("120", s.value("columns/name"));
        s.remove("columns");
        try testing.expectEqual(@as(usize, 0), s.child_groups.get().rowCount());
        s.remove("zoom");
        try testing.expect(!s.contains("zoom"));
        s.setValue("zoom", "0.25");
    }

    var v: TestValues = .{};
    defer v.deinit();
    var s: Settings = undefined;
    s.init(testing.allocator);
    defer s.deinit();
    s.format.set(.registry);
    s.file.set(key);
    s.category.set("view");
    try v.addTo(&s);
    properties.runChangeHandlers();
    try testing.expectEqual(@as(i32, -7), v.count.get());
    try testing.expectEqual(@as(f32, 0.25), v.zoom.get());
    try testing.expect(v.dark.get());
    try testing.expectEqualStrings("two\nlines \\ hère", v.name.get());
    try testing.expectEqual(Color{ .r = 0xab, .g = 0xcd, .b = 0xef, .a = 0x80 }, v.tint.get());
    try testing.expectEqual(@as(i64, 1 << 40), v.wait.get());
    try testing.expect(!s.save_timer.isRunning());
}

test {
    _ = registry;
}
