// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The platform's menu bar (macOS's, at the top of the screen): menus the
//! UI declares (`PlatformMenu` elements with `PlatformMenuItem`s, which
//! `MenuBarItem` in std-widgets.zge makes), shown by a backend's provider
//! (`setMenuBar`). Elsewhere the menus are in the window, and these
//! elements do nothing.
//!
//! `update` (from `updateTimersAndAnimations`) describes the menus again
//! and hands them to the provider when they changed (an item checked, a
//! menu added); a choice in the native menu comes back through `choose`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const Callback = @import("callbacks.zig").Callback;
const item_mod = @import("item.zig");
const Item = item_mod.Item;

/// An entry of a menu, as the provider shows it.
pub const Entry = struct {
    text: []const u8,
    /// "Ctrl+S": the provider maps it to the platform's (⌘S on macOS).
    shortcut: []const u8,
    checked: bool,
    enabled: bool,
    separator: bool,
    /// 0 for the menu's own entries; the entries right after one, a
    /// level deeper, are its submenu.
    level: u32 = 0,
    /// What `choose` takes when it is chosen.
    id: usize,
};

pub const Menu = struct {
    text: []const u8,
    entries: []const Entry,
};

/// A backend's menu bar.
pub const Provider = struct {
    ctx: ?*anyopaque = null,
    /// Shows `menus` (valid during the call) as the menu bar; none: the
    /// application's own menu only.
    set: *const fn (ctx: ?*anyopaque, menus: []const Menu) void,
};

var provider: ?Provider = null;
var gpa_used: ?Allocator = null;
/// The menus declared, in the order they were made.
var registered: std.ArrayList(*PlatformMenu) = .empty;
/// The items of the menus last shown (ids index it).
var shown_items: std.ArrayList(*PlatformMenuItem) = .empty;
var shown_hash: ?u64 = null;

pub fn setMenuBar(p: ?Provider) void {
    provider = p;
    shown_hash = null;
    // Menus made before the backend started learn it now.
    for (registered.items) |m| m.native.set(p != null);
}

/// Whether menus show in the platform's menu bar (not in the window).
pub fn hasNativeMenuBar() bool {
    return provider != null;
}

/// Describes the menus, and hands them to the provider if they changed.
/// Call on the UI thread once per event loop iteration.
pub fn update() void {
    const p = provider orelse return;
    const gpa = gpa_used orelse return;
    // A hash of everything shown first: most of the time, nothing changed.
    var h: std.hash.Wyhash = .init(0);
    for (registered.items) |m| {
        if (!m.shows()) continue;
        h.update(m.text.getUntracked());
        h.update("\x00");
        hashEntries(&h, &m.item);
    }
    const hash = h.final();
    if (shown_hash == hash) return;
    shown_hash = hash;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var menus: std.ArrayList(Menu) = .empty;
    shown_items.clearRetainingCapacity();
    for (registered.items) |m| {
        if (!m.shows()) continue;
        const entries = describeEntries(a, gpa, &m.item, &shown_items) catch return;
        menus.append(a, .{ .text = m.text.getUntracked(), .entries = entries }) catch return;
    }
    p.set(p.ctx, menus.items);
}

/// Hashes what `describeEntries` would make of `parent`'s entries.
pub fn hashEntries(h: *std.hash.Wyhash, parent: *Item) void {
    var it = parent.first_child;
    while (it) |c| : (it = c.next_sibling) {
        const e = PlatformMenuItem.of(c) orelse continue;
        h.update(e.text.getUntracked());
        h.update("\x00");
        h.update(e.shortcut.getUntracked());
        h.update(&.{ @intFromBool(e.checked.getUntracked()), @intFromBool(e.enabled.getUntracked()), @intFromBool(e.separator.getUntracked()), 0 });
        h.update(std.mem.asBytes(&e.level.getUntracked()));
        h.update(std.mem.asBytes(&e));
    }
    h.update("\x01");
}

/// The `PlatformMenuItem` children of `parent` as entries (allocated with
/// `a`), appended to `items`: an entry's id is its index there.
pub fn describeEntries(a: Allocator, gpa: Allocator, parent: *Item, items: *std.ArrayList(*PlatformMenuItem)) Allocator.Error![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var it = parent.first_child;
    while (it) |c| : (it = c.next_sibling) {
        const e = PlatformMenuItem.of(c) orelse continue;
        try items.append(gpa, e);
        try entries.append(a, .{
            .text = e.text.getUntracked(),
            .shortcut = e.shortcut.getUntracked(),
            .checked = e.checked.getUntracked(),
            .enabled = e.enabled.getUntracked(),
            .separator = e.separator.getUntracked(),
            .level = @intCast(@max(0, e.level.getUntracked())),
            .id = items.items.len - 1,
        });
    }
    return entries.items;
}

/// The entry `id` of the menus shown was chosen (by the provider, on the
/// UI thread).
pub fn choose(id: usize) void {
    if (id >= shown_items.items.len) return;
    const e = shown_items.items[id];
    if (!e.enabled.getUntracked() or e.separator.getUntracked()) return;
    e.activated.call(.{});
}

fn unregister(m: *PlatformMenu) void {
    for (registered.items, 0..) |r, i| if (r == m) {
        _ = registered.orderedRemove(i);
        break;
    };
    // Its items go: the menus are described again at the next update.
    shown_items.clearRetainingCapacity();
    shown_hash = null;
    if (registered.items.len == 0) {
        registered.deinit(m.gpa);
        shown_items.deinit(m.gpa);
        registered = .empty;
        shown_items = .empty;
        gpa_used = null;
        if (provider) |p| p.set(p.ctx, &.{});
    }
}

// ---- The elements ----

/// A menu of the platform's menu bar (`PlatformMenu`): its `text`, and its
/// `PlatformMenuItem` children. Not drawn. Initialize in place with `init`.
pub const PlatformMenu = struct {
    item: Item = .init(&vtable),
    text: Property([]const u8) = .init(""),
    /// The menu bar is the platform's (the window need not show one).
    native: Property(bool) = .init(false),
    gpa: Allocator = undefined,

    pub fn init(self: *PlatformMenu, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.native.set(hasNativeMenuBar());
        gpa_used = gpa;
        registered.append(gpa, self) catch {};
        shown_hash = null;
    }

    pub fn deinit(self: *PlatformMenu) void {
        unregister(self);
        self.item.deinit();
        self.text.deinit();
        self.native.deinit();
    }

    /// A menu with a title (one without is only asking whether the bar is
    /// native).
    fn shows(self: *PlatformMenu) bool {
        return self.text.getUntracked().len > 0;
    }

    const vtable: item_mod.ItemVTable = .{ .name = "PlatformMenu" };
};

/// An entry of a `PlatformMenu`. Not drawn.
pub const PlatformMenuItem = struct {
    item: Item = .init(&vtable),
    text: Property([]const u8) = .init(""),
    shortcut: Property([]const u8) = .init(""),
    checked: Property(bool) = .init(false),
    enabled: Property(bool) = .init(true),
    separator: Property(bool) = .init(false),
    /// Nesting: the entries right after it, a level deeper, are its
    /// submenu.
    level: Property(i32) = .init(0),
    activated: Callback(fn () void) = .{},

    pub fn deinit(self: *PlatformMenuItem) void {
        @import("tray.zig").forgetEntry(self);
        // Not chosen any more (it may be in the menus last shown).
        for (shown_items.items) |*e| if (e.* == self) {
            shown_items.clearRetainingCapacity();
            shown_hash = null;
            break;
        };
        self.item.deinit();
        self.text.deinit();
        self.shortcut.deinit();
        self.checked.deinit();
        self.enabled.deinit();
        self.separator.deinit();
        self.level.deinit();
    }

    pub fn of(i: *Item) ?*PlatformMenuItem {
        if (i.vtable != &vtable) return null;
        return @alignCast(@fieldParentPtr("item", i));
    }

    const vtable: item_mod.ItemVTable = .{ .name = "PlatformMenuItem" };
};

// ---- Tests ----

const testing = std.testing;

const Shown = struct {
    calls: usize = 0,
    menus: usize = 0,
    first: [64]u8 = undefined,
    first_len: usize = 0,
    checked: bool = false,
    fn provider(self: *Shown) Provider {
        return .{ .ctx = self, .set = set };
    }
    fn set(ctx: ?*anyopaque, menus: []const Menu) void {
        const self: *Shown = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.menus = menus.len;
        if (menus.len > 0 and menus[0].entries.len > 0) {
            const t = menus[0].entries[0].text;
            @memcpy(self.first[0..t.len], t);
            self.first_len = t.len;
            self.checked = menus[0].entries[0].checked;
        }
    }
};

test "menus declared are shown, again when they change, and chosen" {
    var shown: Shown = .{};
    setMenuBar(shown.provider());
    defer setMenuBar(null);
    var menu: PlatformMenu = undefined;
    menu.init(testing.allocator);
    defer menu.deinit();
    try testing.expect(menu.native.get());
    menu.text.set("View");
    var dark: PlatformMenuItem = .{};
    defer dark.deinit();
    dark.text.set("Dark mode");
    menu.item.appendChild(&dark.item);
    var chosen: usize = 0;
    dark.activated.setHandler(&chosen, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);

    update();
    try testing.expectEqual(@as(usize, 1), shown.calls);
    try testing.expectEqual(@as(usize, 1), shown.menus);
    try testing.expectEqualStrings("Dark mode", shown.first[0..shown.first_len]);
    update(); // nothing changed
    try testing.expectEqual(@as(usize, 1), shown.calls);
    dark.checked.set(true);
    update();
    try testing.expectEqual(@as(usize, 2), shown.calls);
    try testing.expect(shown.checked);

    choose(0);
    try testing.expectEqual(@as(usize, 1), chosen);
    dark.enabled.set(false);
    choose(0);
    try testing.expectEqual(@as(usize, 1), chosen);
}
