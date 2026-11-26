// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The platform's file dialogs: open one or more files, a folder, or a
//! file to save. A backend provides them (`setFileDialogs`): the macOS,
//! Windows and Linux ones, and SDL's. The `FileDialog` element shows them.
//!
//! A dialog may answer later and from another thread (SDL's, the Linux
//! portal's): the answer is kept until `update` (on the UI thread, from
//! `updateTimersAndAnimations`) hands it over.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const ChangeTracker = @import("properties.zig").ChangeTracker;
const Callback = @import("callbacks.zig").Callback;
const model = @import("model.zig");
const item_mod = @import("item.zig");

const log = std.log.scoped(.zigulee_dialogs);

pub const FileDialogMode = enum { open_file, open_files, open_folder, save_file };

/// A choice of files by name: "Images" with "*.png" and "*.jpg".
pub const Filter = struct {
    name: []const u8,
    /// Glob patterns ("*.png", "*").
    patterns: []const []const u8,

    /// The extensions of its patterns ("png" for "*.png"); none for "*".
    pub fn extensions(f: Filter, buf: [][]const u8) [][]const u8 {
        var n: usize = 0;
        for (f.patterns) |p| {
            if (n == buf.len) break;
            if (std.mem.startsWith(u8, p, "*.") and p.len > 2 and std.mem.indexOfAny(u8, p[2..], "*?[") == null) {
                buf[n] = p[2..];
                n += 1;
            }
        }
        return buf[0..n];
    }
};

/// What to ask.
pub const Request = struct {
    mode: FileDialogMode = .open_file,
    title: []const u8 = "",
    filters: []const Filter = &.{},
    /// Where it starts (a folder), if not empty.
    folder: []const u8 = "",
    /// The name suggested when saving.
    file_name: []const u8 = "",
};

/// A dialog being shown: the provider answers it with `finish` (from any
/// thread), once.
pub const Pending = struct {
    gpa: Allocator,
    request: Request,
    /// The answer: the paths chosen (none: cancelled).
    files: std.ArrayList([]u8) = .empty,
    done: std.atomic.Value(bool) = .init(false),
    listener: Listener,
    next: ?*Pending = null,
    /// What the request's strings point into.
    arena: std.heap.ArenaAllocator,

    /// The answer: `files` chosen (copied), or none if cancelled.
    pub fn finish(p: *Pending, files: []const []const u8) void {
        for (files) |f| {
            const copy = p.gpa.dupe(u8, f) catch break;
            p.files.append(p.gpa, copy) catch {
                p.gpa.free(copy);
                break;
            };
        }
        p.done.store(true, .release);
    }

    fn destroy(p: *Pending) void {
        for (p.files.items) |f| p.gpa.free(f);
        p.files.deinit(p.gpa);
        p.arena.deinit();
        p.gpa.destroy(p);
    }
};

/// Told the answer, on the UI thread.
pub const Listener = struct {
    ctx: *anyopaque,
    /// `files` are valid during the call; none: cancelled.
    answered: *const fn (ctx: *anyopaque, files: []const []const u8) void,
};

/// A backend's file dialogs.
pub const Provider = struct {
    ctx: ?*anyopaque = null,
    /// Shows the dialog for `pending.request`; answers with
    /// `pending.finish`, now (a modal dialog) or later.
    show: *const fn (ctx: ?*anyopaque, pending: *Pending) void,
};

var provider: ?Provider = null;
/// Dialogs shown, not yet answered (or answered, not yet handed over).
var pendings: ?*Pending = null;

pub fn setFileDialogs(p: ?Provider) void {
    provider = p;
}

pub fn hasFileDialogs() bool {
    return provider != null;
}

/// Shows a file dialog; `listener` gets the answer (on the UI thread,
/// from `update`). Without file dialogs, the answer is "cancelled".
pub fn show(gpa: Allocator, request: Request, listener: Listener) Allocator.Error!void {
    const p = try gpa.create(Pending);
    p.* = .{ .gpa = gpa, .request = undefined, .listener = listener, .arena = .init(gpa) };
    errdefer p.destroy();
    // The request's own copy (the caller's strings can go).
    const a = p.arena.allocator();
    const filters = try a.alloc(Filter, request.filters.len);
    for (filters, request.filters) |*f, src| {
        const patterns = try a.alloc([]const u8, src.patterns.len);
        for (patterns, src.patterns) |*pat, s| pat.* = try a.dupe(u8, s);
        f.* = .{ .name = try a.dupe(u8, src.name), .patterns = patterns };
    }
    p.request = .{
        .mode = request.mode,
        .title = try a.dupe(u8, request.title),
        .filters = filters,
        .folder = try a.dupe(u8, request.folder),
        .file_name = try a.dupe(u8, request.file_name),
    };
    p.next = pendings;
    pendings = p;
    if (provider) |pr| {
        pr.show(pr.ctx, p);
    } else {
        log.info("no file dialogs on this platform", .{});
        p.finish(&.{});
    }
}

/// Stops telling `ctx` (its element goes); the dialog may still be open.
pub fn forget(ctx: *anyopaque) void {
    var it = pendings;
    while (it) |p| : (it = p.next) if (p.listener.ctx == ctx) {
        p.listener = .{ .ctx = p, .answered = ignore };
    };
}

fn ignore(_: *anyopaque, _: []const []const u8) void {}

/// Hands over the answers. Call on the UI thread once per event loop
/// iteration (`updateTimersAndAnimations` does).
pub fn update() void {
    var link: *?*Pending = &pendings;
    while (link.*) |p| {
        if (!p.done.load(.acquire)) {
            link = &p.next;
            continue;
        }
        link.* = p.next;
        const files = p.files.items;
        p.listener.answered(p.listener.ctx, @ptrCast(files));
        p.destroy();
    }
}

/// Whether a dialog is waiting for an answer (the event loop keeps waking
/// up for `update` while one is).
pub fn busy() bool {
    return pendings != null;
}

/// Filters in the form "Images (*.png *.jpg);;All files (*)": each a name
/// and its patterns in parentheses (a filter without them is its own
/// pattern). Strings point into `text`.
pub fn parseFilters(gpa: Allocator, text: []const u8) Allocator.Error![]Filter {
    var out: std.ArrayList(Filter) = .empty;
    errdefer {
        for (out.items) |f| gpa.free(f.patterns);
        out.deinit(gpa);
    }
    var parts = std.mem.splitSequence(u8, text, ";;");
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        if (part.len == 0) continue;
        var name = part;
        var list = part;
        if (std.mem.lastIndexOfScalar(u8, part, '(')) |open| if (std.mem.endsWith(u8, part, ")")) {
            name = std.mem.trim(u8, part[0..open], " ");
            list = part[open + 1 .. part.len - 1];
        };
        var patterns: std.ArrayList([]const u8) = .empty;
        errdefer patterns.deinit(gpa);
        var it = std.mem.tokenizeAny(u8, list, " ;");
        while (it.next()) |pat| try patterns.append(gpa, pat);
        try out.append(gpa, .{ .name = if (name.len > 0) name else list, .patterns = try patterns.toOwnedSlice(gpa) });
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeFilters(gpa: Allocator, filters: []Filter) void {
    for (filters) |f| gpa.free(f.patterns);
    gpa.free(filters);
}

// ---- The FileDialog element ----

/// Shows the platform's file dialog with `open()` (the `FileDialog`
/// element). The chosen files are `selected_files` (and the first,
/// `selected_file`); `accepted` or `rejected` tells the answer.
/// Initialize in place with `init`.
pub const FileDialogElement = struct {
    item: item_mod.Item = .init(&vtable),
    mode: Property(FileDialogMode) = .init(.open_file),
    title: Property([]const u8) = .init(""),
    /// "Images (*.png *.jpg);;All files (*)".
    filter: Property([]const u8) = .init(""),
    folder: Property([]const u8) = .init(""),
    file_name: Property([]const u8) = .init(""),
    selected_file: Property([]const u8) = .init(""),
    selected_files: Property(model.Model([]const u8)) = undefined,
    is_open: Property(bool) = .init(false),
    accepted: Callback(fn () void) = .{},
    rejected: Callback(fn () void) = .{},

    gpa: Allocator = undefined,
    files: model.VecModel([]const u8) = undefined,

    pub fn init(self: *FileDialogElement, gpa: Allocator) void {
        self.* = .{ .gpa = gpa, .files = .init(gpa) };
        self.selected_files = .init(self.files.model());
    }

    pub fn deinit(self: *FileDialogElement) void {
        forget(self);
        self.clearFiles();
        self.files.deinit();
        self.item.deinit();
        self.mode.deinit();
        self.title.deinit();
        self.filter.deinit();
        self.folder.deinit();
        self.file_name.deinit();
        self.selected_file.deinit();
        self.selected_files.deinit();
        self.is_open.deinit();
    }

    /// Shows the dialog (if it is not showing).
    pub fn open(self: *FileDialogElement) void {
        if (self.is_open.getUntracked()) return;
        const filters = parseFilters(self.gpa, self.filter.getUntracked()) catch &.{};
        defer if (filters.len > 0) freeFilters(self.gpa, @constCast(filters));
        self.is_open.set(true);
        show(self.gpa, .{
            .mode = self.mode.getUntracked(),
            .title = self.title.getUntracked(),
            .filters = filters,
            .folder = self.folder.getUntracked(),
            .file_name = self.file_name.getUntracked(),
        }, .{ .ctx = self, .answered = answered }) catch {
            self.is_open.set(false);
        };
    }

    fn clearFiles(self: *FileDialogElement) void {
        for (self.files.items.items) |f| self.gpa.free(f);
        self.files.items.clearRetainingCapacity();
    }

    fn answered(ctx: *anyopaque, files: []const []const u8) void {
        const self: *FileDialogElement = @ptrCast(@alignCast(ctx));
        self.is_open.set(false);
        if (files.len == 0) return self.rejected.call(.{});
        // The new selection replaces the old one (in one change).
        var copies: std.ArrayList([]const u8) = .empty;
        defer copies.deinit(self.gpa);
        for (files) |f| {
            const copy = self.gpa.dupe(u8, f) catch break;
            copies.append(self.gpa, copy) catch {
                self.gpa.free(copy);
                break;
            };
        }
        const old = self.gpa.dupe([]const u8, self.files.items.items) catch &.{};
        defer {
            for (old) |f| self.gpa.free(f);
            self.gpa.free(old);
        }
        self.files.setAll(copies.items) catch {};
        self.selected_file.set(if (self.files.items.items.len > 0) self.files.items.items[0] else "");
        self.accepted.call(.{});
    }

    const vtable: item_mod.ItemVTable = .{ .name = "FileDialog" };
};

// ---- Tests ----

const testing = std.testing;

test "filters in Qt's form" {
    const f = try parseFilters(testing.allocator, "Images (*.png *.jpg);;Text files (*.txt) ;; *.zig");
    defer freeFilters(testing.allocator, f);
    try testing.expectEqual(@as(usize, 3), f.len);
    try testing.expectEqualStrings("Images", f[0].name);
    try testing.expectEqualStrings("*.jpg", f[0].patterns[1]);
    try testing.expectEqualStrings("Text files", f[1].name);
    try testing.expectEqualStrings("*.zig", f[2].name);
    var buf: [4][]const u8 = undefined;
    try testing.expectEqualStrings("png", f[0].extensions(&buf)[0]);
}

/// A provider that answers later, like a portal.
const Later = struct {
    pending: ?*Pending = null,
    fn provider(self: *Later) Provider {
        return .{ .ctx = self, .show = showIt };
    }
    fn showIt(ctx: ?*anyopaque, p: *Pending) void {
        const self: *Later = @ptrCast(@alignCast(ctx));
        self.pending = p;
    }
};

test "the FileDialog element: shown, answered later, accepted or rejected" {
    var later: Later = .{};
    setFileDialogs(later.provider());
    defer setFileDialogs(null);
    var el: FileDialogElement = undefined;
    el.init(testing.allocator);
    defer el.deinit();
    var answers: [2]usize = .{ 0, 0 };
    el.accepted.setHandler(&answers, struct {
        fn f(a: *[2]usize) void {
            a[0] += 1;
        }
    }.f);
    el.rejected.setHandler(&answers, struct {
        fn f(a: *[2]usize) void {
            a[1] += 1;
        }
    }.f);
    el.mode.set(.open_files);
    el.filter.set("Images (*.png *.jpg)");
    el.open();
    try testing.expect(el.is_open.get());
    const p = later.pending.?;
    try testing.expectEqual(FileDialogMode.open_files, p.request.mode);
    try testing.expectEqualStrings("*.png", p.request.filters[0].patterns[0]);
    try testing.expect(busy());
    update(); // not answered yet
    try testing.expect(el.is_open.get());

    p.finish(&.{ "/tmp/a.png", "/tmp/b.jpg" });
    update();
    try testing.expect(!busy());
    try testing.expect(!el.is_open.get());
    try testing.expectEqual(@as(usize, 1), answers[0]);
    try testing.expectEqualStrings("/tmp/a.png", el.selected_file.get());
    try testing.expectEqual(@as(usize, 2), el.selected_files.get().rowCount());
    try testing.expectEqualStrings("/tmp/b.jpg", el.selected_files.get().rowData(1).?);

    // Cancelled: the selection stays.
    el.open();
    later.pending.?.finish(&.{});
    update();
    try testing.expectEqual(@as(usize, 1), answers[1]);
    try testing.expectEqualStrings("/tmp/a.png", el.selected_file.get());
}

test "without file dialogs, the answer is cancelled" {
    setFileDialogs(null);
    var el: FileDialogElement = undefined;
    el.init(testing.allocator);
    defer el.deinit();
    var rejected: usize = 0;
    el.rejected.setHandler(&rejected, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);
    el.open();
    update();
    try testing.expectEqual(@as(usize, 1), rejected);
}
