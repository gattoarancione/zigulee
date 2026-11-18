// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Settings (the `Settings` element): properties kept from one run of the
//! application to the next. A component that inherits `Settings` has its
//! declared properties stored, under `category`, in an INI file:
//! `settings.ini` in the application's configuration folder
//! (`paths.Location.app_config`), or `file`. Saved values replace the
//! defaults once the component and its users are set up (from the next
//! `runChangeHandlers`, so properties linked with `<=>` take them too);
//! changes are written a moment later, and when it is destroyed. Where
//! there are no files (the web, microcontrollers), they last as long as
//! the application.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const properties = @import("properties.zig");
const Property = properties.Property;
const item_mod = @import("item.zig");
const Timer = @import("timers.zig").Timer;
const Color = @import("graphics.zig").Color;
const paths = @import("paths.zig");

const log = std.log.scoped(.zigulee);

/// How long after a change it is written (changes in between are written
/// together).
pub const save_delay_ms = 300;

/// Initialize in place with `init`.
pub const Settings = struct {
    item: item_mod.Item = .init(&vtable),
    /// The section of the file its values are in ("": before any).
    category: Property([]const u8) = .init(""),
    /// The file; empty for `settings.ini` in the application's
    /// configuration folder.
    file: Property([]const u8) = .init(""),

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
        self.* = .{ .gpa = gpa };
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
        self.item.deinit();
        self.category.deinit();
        self.file.deinit();
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

    /// Reads the saved values into the properties, then watches them.
    fn begin(self: *Settings) void {
        if (self.tracking) {
            self.tracker.deinit();
            self.tracking = false;
        }
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (self.filePath(a)) |path| if (readFile(a, path)) |text| {
            var ini = Ini.parse(a, text) catch return;
            if (ini.section(self.category.getUntracked())) |sec| for (self.entries.items) |e| {
                if (sec.value(e.key)) |v| self.setFromText(e, v);
            };
        };
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

    /// Writes its values, if they changed, into the file (keeping what
    /// else it holds).
    pub fn save(self: *Settings) void {
        self.save_timer.stop();
        const now = self.serialize(self.gpa) catch return;
        if (std.mem.eql(u8, now, self.last)) return self.gpa.free(now);
        self.gpa.free(self.last);
        self.last = now;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const path = self.filePath(a) orelse return;
        var ini = Ini.parse(a, readFile(a, path) orelse "") catch return;
        const sec = ini.sectionOrNew(a, self.category.getUntracked()) catch return;
        var lines = std.mem.splitScalar(u8, now, '\n');
        for (self.entries.items) |e| {
            const l = lines.next() orelse break;
            sec.set(a, e.key, l) catch return;
        }
        writeFile(a, path, ini.write(a) catch return) catch |err|
            log.warn("cannot write the settings to '{s}': {t}", .{ path, err });
    }

    /// Its values, one line `key=value` each, in the order added.
    fn serialize(self: *Settings, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) w.writeByte('\n') catch return error.OutOfMemory;
            w.print("{s}=", .{e.key}) catch return error.OutOfMemory;
            writeValue(w, e) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice();
    }

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
            .string => for (prop(.string, e).getUntracked()) |ch| switch (ch) {
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => try w.writeByte(ch),
            },
        }
    }

    /// Sets `e`'s property from its saved text (left as it is if that is
    /// not a value of its kind).
    fn setFromText(self: *Settings, e: Entry, text: []const u8) void {
        switch (e.kind) {
            .int => prop(.int, e).set(std.fmt.parseInt(i32, text, 10) catch return),
            .float => prop(.float, e).set(std.fmt.parseFloat(f32, text) catch return),
            .duration => prop(.duration, e).set(std.fmt.parseInt(i64, text, 10) catch return),
            .bool => prop(.bool, e).set(if (std.mem.eql(u8, text, "true")) true else if (std.mem.eql(u8, text, "false")) false else return),
            .color => {
                if (text.len != 9 or text[0] != '#') return;
                const v = std.fmt.parseInt(u32, text[1..], 16) catch return;
                prop(.color, e).set(.{ .r = @truncate(v >> 24), .g = @truncate(v >> 16), .b = @truncate(v >> 8), .a = @truncate(v) });
            },
            .string => {
                const s = unescape(self.gpa, text) catch return;
                self.strings.append(self.gpa, s) catch return self.gpa.free(s);
                prop(.string, e).set(s);
            },
        }
    }

    fn Value(comptime k: Kind) type {
        return switch (k) {
            .int => i32,
            .float => f32,
            .duration => i64,
            .bool => bool,
            .string => []const u8,
            .color => Color,
        };
    }

    fn prop(comptime k: Kind, e: Entry) *Property(Value(k)) {
        return @ptrCast(@alignCast(e.ptr));
    }

    /// Where its file is; null where there are no files (and in tests,
    /// unless it is given: they leave the user's alone).
    fn filePath(self: *Settings, a: Allocator) ?[]const u8 {
        if (!paths.has_files) return null;
        const file = self.file.getUntracked();
        if (file.len > 0) return file;
        if (builtin.is_test) return null;
        const dir = paths.get(a, .app_config) catch return null;
        if (dir.len == 0) return null;
        return std.fs.path.join(a, &.{ dir, "settings.ini" }) catch null;
    }

    const vtable: item_mod.ItemVTable = .{ .name = "Settings" };
};

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
