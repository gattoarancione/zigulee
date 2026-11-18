// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The system tray and desktop notifications: icons the UI declares
//! (`SystemTrayIcon`, its menu `PlatformMenuItem` children) and
//! notifications it sends (`Notification`), shown by a backend's provider
//! (`setProvider`): the right of macOS's menu bar and its Notification
//! Center, Windows' notification area and its notifications, and the
//! desktop's notifications on Linux. Without one, icons are not shown and
//! notifications are dropped (`available` tells).
//!
//! `update` (from `updateTimersAndAnimations`) describes the icons again
//! and hands them to the provider when they changed; clicks come back
//! through `activate`, `choose` and `notificationClicked`, on the UI
//! thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const Callback = @import("callbacks.zig").Callback;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const Image = @import("image.zig").Image;
const menus = @import("menus.zig");
const time = @import("time.zig");
const PlatformMenuItem = menus.PlatformMenuItem;

const log = std.log.scoped(.zigulee);

/// A tray icon, as the provider shows it.
pub const Icon = struct {
    /// The same from one call to the next for the same icon.
    key: usize,
    /// Shown when the pointer is over it (and, on macOS, as the icon's
    /// title when there is no image).
    tooltip: []const u8,
    image: ?Image,
    /// Its menu (none: a click activates it).
    entries: []const menus.Entry,
};

/// A notification, as the provider shows it.
pub const Notice = struct {
    /// What `notificationClicked` takes.
    id: u32,
    title: []const u8,
    body: []const u8,
};

pub const Provider = struct {
    ctx: ?*anyopaque = null,
    /// Shows `icon` (valid during the call), or updates it if its key is
    /// shown already. Null: there is no tray.
    show: ?*const fn (ctx: ?*anyopaque, icon: *const Icon) void = null,
    /// Takes the icon with `key` away.
    remove: ?*const fn (ctx: ?*anyopaque, key: usize) void = null,
    /// Shows a notification (valid during the call). Null: there are no
    /// notifications.
    notify: ?*const fn (ctx: ?*anyopaque, notice: *const Notice) void = null,
    /// Reads what came (clicks on notifications), on the UI thread, at
    /// each update: for a while after a notification, at least every
    /// `poll_ms` (see `busy`).
    poll: ?*const fn (ctx: ?*anyopaque) void = null,
};

/// How often `Provider.poll` is called while notifications may be
/// clicked, and for how long after the last one.
pub const poll_ms = 250;
pub const poll_for_ms = 5 * 60 * 1000;

var provider: Provider = .{};
var icons: std.ArrayList(*SystemTrayIcon) = .empty;
var notifications: std.ArrayList(*Notification) = .empty;
/// Notifications sent and who sent them, newest last (the oldest are
/// forgotten: a click on them does nothing).
var sent: std.ArrayList(Sent) = .empty;
var next_id: u32 = 1;
/// When the last notification was sent (0: none yet).
var last_sent_ms: u64 = 0;
var gpa_used: ?Allocator = null;

const Sent = struct { id: u32, by: *Notification };
const max_sent = 64;

pub fn setProvider(p: ?Provider) void {
    for (icons.items) |icon| if (icon.shown_hash != null) {
        if (provider.remove) |remove| remove(provider.ctx, icon.key());
        icon.shown_hash = null;
    };
    provider = p orelse .{};
    // Elements made before the backend started learn it now.
    for (icons.items) |icon| icon.available.set(hasTray());
    for (notifications.items) |n| n.available.set(hasNotifications());
}

pub fn hasTray() bool {
    return provider.show != null;
}

pub fn hasNotifications() bool {
    return provider.notify != null;
}

/// Shows the icons that changed. Call on the UI thread once per event
/// loop iteration.
pub fn update() void {
    if (provider.poll) |poll| poll(provider.ctx);
    const show = provider.show orelse return;
    const gpa = gpa_used orelse return;
    for (icons.items) |icon| {
        if (!icon.item.visible.getUntracked()) {
            if (icon.shown_hash != null) {
                if (provider.remove) |remove| remove(provider.ctx, icon.key());
                icon.shown_hash = null;
            }
            continue;
        }
        var h: std.hash.Wyhash = .init(0);
        h.update(icon.tooltip.getUntracked());
        if (icon.icon.getUntracked()) |img| {
            h.update(std.mem.asBytes(&img.width));
            h.update(std.mem.asBytes(&img.height));
            h.update(std.mem.asBytes(&img.pixels.ptr));
            h.update(std.mem.asBytes(&img.version));
        }
        menus.hashEntries(&h, &icon.item);
        const hash = h.final();
        if (icon.shown_hash == hash) continue;
        icon.shown_hash = hash;

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        icon.entries.clearRetainingCapacity();
        const entries = menus.describeEntries(arena.allocator(), gpa, &icon.item, &icon.entries) catch continue;
        const img = icon.icon.getUntracked();
        show(provider.ctx, &.{
            .key = icon.key(),
            .tooltip = icon.tooltip.getUntracked(),
            .image = if (img) |i| (if (i.width > 0 and i.pixels.len > 0) i else null) else null,
            .entries = entries,
        });
    }
}

/// Whether the event loop should wake up (every `poll_ms`) to have the
/// provider poll: for a while after a notification was sent.
pub fn busy() bool {
    if (provider.poll == null or last_sent_ms == 0) return false;
    return time.now() -| last_sent_ms < poll_for_ms;
}

fn find(key: usize) ?*SystemTrayIcon {
    for (icons.items) |icon| if (icon.key() == key) return icon;
    return null;
}

/// The icon `key` was clicked (one without a menu).
pub fn activate(key: usize) void {
    const icon = find(key) orelse return;
    icon.activated.call(.{});
}

/// The entry `id` of the menu of icon `key` was chosen.
pub fn choose(key: usize, id: usize) void {
    const icon = find(key) orelse return;
    if (id >= icon.entries.items.len) return;
    const e = icon.entries.items[id];
    if (!e.enabled.getUntracked() or e.separator.getUntracked()) return;
    e.activated.call(.{});
}

/// The notification `id` was clicked.
pub fn notificationClicked(id: u32) void {
    for (sent.items) |s| if (s.id == id) return s.by.clicked.call(.{});
}

/// `e` is going: no icon's menu chooses it any more.
pub fn forgetEntry(e: *PlatformMenuItem) void {
    for (icons.items) |icon| for (icon.entries.items) |x| if (x == e) {
        icon.entries.clearRetainingCapacity();
        icon.shown_hash = null;
        break;
    };
}

fn cleanUp() void {
    if (icons.items.len > 0 or notifications.items.len > 0) return;
    const gpa = gpa_used orelse return;
    icons.deinit(gpa);
    notifications.deinit(gpa);
    sent.deinit(gpa);
    icons = .empty;
    notifications = .empty;
    sent = .empty;
    gpa_used = null;
}

// ---- The elements ----

/// An icon in the system tray (`SystemTrayIcon`): its `icon` and
/// `tooltip`, shown while its item is `visible`; its menu is its `PlatformMenuItem`
/// children, and without one a click calls `activated`. Not drawn.
/// Initialize in place with `init`.
pub const SystemTrayIcon = struct {
    item: Item = .init(&vtable),
    icon: Property(?Image) = .init(null),
    tooltip: Property([]const u8) = .init(""),
    /// The platform has a tray (the icon is shown).
    available: Property(bool) = .init(false),
    activated: Callback(fn () void) = .{},
    gpa: Allocator = undefined,
    shown_hash: ?u64 = null,
    /// The entries of the menu last shown (ids index it).
    entries: std.ArrayList(*PlatformMenuItem) = .empty,

    pub fn init(self: *SystemTrayIcon, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.available.set(hasTray());
        gpa_used = gpa;
        icons.append(gpa, self) catch {};
    }

    pub fn deinit(self: *SystemTrayIcon) void {
        if (self.shown_hash != null) if (provider.remove) |remove| remove(provider.ctx, self.key());
        for (icons.items, 0..) |x, i| if (x == self) {
            _ = icons.orderedRemove(i);
            break;
        };
        cleanUp();
        self.entries.deinit(self.gpa);
        self.item.deinit();
        self.icon.deinit();
        self.tooltip.deinit();
        self.available.deinit();
    }

    fn key(self: *SystemTrayIcon) usize {
        return @intFromPtr(self);
    }

    const vtable: item_mod.ItemVTable = .{ .name = "SystemTrayIcon" };
};

/// A desktop notification (`Notification`): `send()` shows its `title`
/// and `body`; a click on it calls `clicked`. Not drawn. Initialize in
/// place with `init`.
pub const Notification = struct {
    item: Item = .init(&vtable),
    title: Property([]const u8) = .init(""),
    body: Property([]const u8) = .init(""),
    /// The platform shows notifications.
    available: Property(bool) = .init(false),
    clicked: Callback(fn () void) = .{},
    gpa: Allocator = undefined,

    pub fn init(self: *Notification, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.available.set(hasNotifications());
        gpa_used = gpa;
        notifications.append(gpa, self) catch {};
    }

    pub fn deinit(self: *Notification) void {
        var i: usize = 0;
        while (i < sent.items.len) {
            if (sent.items[i].by == self) _ = sent.orderedRemove(i) else i += 1;
        }
        for (notifications.items, 0..) |x, j| if (x == self) {
            _ = notifications.orderedRemove(j);
            break;
        };
        cleanUp();
        self.item.deinit();
        self.title.deinit();
        self.body.deinit();
        self.available.deinit();
    }

    /// Shows the notification (another one, if it was shown already).
    pub fn send(self: *Notification) void {
        const notify = provider.notify orelse {
            log.info("notification (not shown here): {s}: {s}", .{ self.title.get(), self.body.get() });
            return;
        };
        const id = next_id;
        next_id +%= 1;
        if (next_id == 0) next_id = 1;
        if (sent.items.len == max_sent) _ = sent.orderedRemove(0);
        sent.append(self.gpa, .{ .id = id, .by = self }) catch {};
        last_sent_ms = @max(1, time.now());
        notify(provider.ctx, &.{ .id = id, .title = self.title.get(), .body = self.body.get() });
    }

    const vtable: item_mod.ItemVTable = .{ .name = "Notification" };
};

// ---- Tests ----

const testing = std.testing;

const Fake = struct {
    shown: usize = 0,
    removed: usize = 0,
    key: usize = 0,
    tooltip: [32]u8 = undefined,
    tooltip_len: usize = 0,
    entries: usize = 0,
    notices: usize = 0,
    last_id: u32 = 0,
    title: [32]u8 = undefined,
    title_len: usize = 0,

    fn provider(self: *Fake) Provider {
        return .{ .ctx = self, .show = show, .remove = remove, .notify = notify };
    }
    fn of(ctx: ?*anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }
    fn show(ctx: ?*anyopaque, icon: *const Icon) void {
        const self = of(ctx);
        self.shown += 1;
        self.key = icon.key;
        @memcpy(self.tooltip[0..icon.tooltip.len], icon.tooltip);
        self.tooltip_len = icon.tooltip.len;
        self.entries = icon.entries.len;
    }
    fn remove(ctx: ?*anyopaque, _: usize) void {
        of(ctx).removed += 1;
    }
    fn notify(ctx: ?*anyopaque, n: *const Notice) void {
        const self = of(ctx);
        self.notices += 1;
        self.last_id = n.id;
        @memcpy(self.title[0..n.title.len], n.title);
        self.title_len = n.title.len;
    }
};

fn count(n: *usize) void {
    n.* += 1;
}

test "a tray icon shown, again when it changes, hidden; its menu and clicks" {
    var icon: SystemTrayIcon = undefined;
    icon.init(testing.allocator);
    defer icon.deinit();
    try testing.expect(!icon.available.get());
    update(); // no tray: nothing happens

    var fake: Fake = .{};
    setProvider(fake.provider());
    defer setProvider(null);
    try testing.expect(icon.available.get());
    icon.tooltip.set("Sync");
    var quit: PlatformMenuItem = .{};
    defer quit.deinit();
    quit.text.set("Quit");
    icon.item.appendChild(&quit.item);
    var quits: usize = 0;
    quit.activated.setHandler(&quits, count);
    var clicks: usize = 0;
    icon.activated.setHandler(&clicks, count);

    update();
    try testing.expectEqual(@as(usize, 1), fake.shown);
    try testing.expectEqualStrings("Sync", fake.tooltip[0..fake.tooltip_len]);
    try testing.expectEqual(@as(usize, 1), fake.entries);
    update(); // nothing changed
    try testing.expectEqual(@as(usize, 1), fake.shown);
    icon.tooltip.set("Syncing");
    update();
    try testing.expectEqual(@as(usize, 2), fake.shown);

    choose(fake.key, 0);
    try testing.expectEqual(@as(usize, 1), quits);
    choose(fake.key, 5);
    choose(fake.key + 1, 0);
    activate(fake.key);
    try testing.expectEqual(@as(usize, 1), quits);
    try testing.expectEqual(@as(usize, 1), clicks);

    icon.item.visible.set(false);
    update();
    try testing.expectEqual(@as(usize, 1), fake.removed);
    icon.item.visible.set(true);
    update();
    try testing.expectEqual(@as(usize, 3), fake.shown);
}

test "notifications sent, and clicked" {
    var n: Notification = undefined;
    n.init(testing.allocator);
    defer n.deinit();
    n.title.set("Done");
    n.send(); // no provider: dropped
    var fake: Fake = .{};
    setProvider(fake.provider());
    defer setProvider(null);
    try testing.expect(n.available.get());
    var clicks: usize = 0;
    n.clicked.setHandler(&clicks, count);
    n.send();
    try testing.expectEqual(@as(usize, 1), fake.notices);
    try testing.expectEqualStrings("Done", fake.title[0..fake.title_len]);
    notificationClicked(fake.last_id);
    notificationClicked(fake.last_id + 100);
    try testing.expectEqual(@as(usize, 1), clicks);
}
