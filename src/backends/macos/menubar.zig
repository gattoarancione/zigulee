// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The macOS menu bar: the menus the UI declares (`PlatformMenu`, which
//! `MenuBarItem` makes), after the application menu (Hide, Quit), in the
//! bar at the top of the screen. Shortcuts given as "Ctrl+S" are ⌘S.

const std = @import("std");
const zigulee = @import("zigulee");
const objc = @import("zigulee-apple").objc;
const menus = zigulee.core.menus;
const id = objc.id;
const SEL = objc.SEL;
const msg = objc.msg;
const class = objc.class;

pub const provider: menus.Provider = .{ .set = set };

const command = 1 << 20;
const shift = 1 << 17;
const control = 1 << 18;
const option = 1 << 19;

var target: id = null;

/// The object the items send their action to.
fn menuTarget() id {
    if (target) |t| return t;
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("NSObject"), "ZiguleeMenuTarget", 0);
    _ = objc.class_addMethod(cls, objc.sel("zigMenuItem:"), @ptrCast(&chosen), "v@:@");
    objc.objc_registerClassPair(cls);
    target = msg(id, msg(id, cls, "alloc", .{}), "init", .{});
    return target;
}

fn chosen(_: id, _: SEL, sender: id) callconv(.c) void {
    const tag = msg(isize, sender, "tag", .{});
    if (tag >= 0) menus.choose(@intCast(tag));
}

fn set(_: ?*anyopaque, list: []const menus.Menu) void {
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    const app = msg(id, class("NSApplication"), "sharedApplication", .{});
    const bar = newMenu("");
    msg(void, bar, "addItem:", .{applicationMenu()});
    for (list) |m| {
        const sub = newMenu(m.text);
        _ = fill(sub, m.entries, 0, 0, bar_action);
        const top = newItem(m.text, null, "");
        msg(void, top, "setSubmenu:", .{sub});
        msg(void, bar, "addItem:", .{top});
    }
    msg(void, app, "setMainMenu:", .{bar});
}

/// Where a chosen entry goes: `selector` of `target`, with the item (its
/// tag is the entry's id plus `tag_base`).
pub const Action = struct {
    target: *const fn () id,
    selector: [:0]const u8,
    tag_base: isize = 0,
};

const bar_action: Action = .{ .target = menuTarget, .selector = "zigMenuItem:" };

/// A menu of `entries`, with `action` (autoreleased).
pub fn menuOf(entries: []const menus.Entry, action: Action) id {
    const m = newMenu("");
    _ = fill(m, entries, 0, 0, action);
    return m;
}

/// Adds the entries of `level` from `entries[start..]` to `menu`, each
/// followed by deeper ones getting them as its submenu; returns where the
/// entries of `level` end.
fn fill(menu: id, entries: []const menus.Entry, start: usize, level: u32, action: Action) usize {
    var i = start;
    while (i < entries.len and entries[i].level >= level) {
        const e = entries[i];
        i += 1;
        if (e.level > level) continue; // too deep: no entry above it
        const it = entry(e, action);
        if (!e.separator and i < entries.len and entries[i].level > level) {
            const sub = newMenu(e.text);
            i = fill(sub, entries, i, level + 1, action);
            msg(void, it, "setSubmenu:", .{sub});
        }
        msg(void, menu, "addItem:", .{it});
    }
    return i;
}

fn newMenu(title: []const u8) id {
    const m = msg(id, msg(id, msg(id, class("NSMenu"), "alloc", .{}), "initWithTitle:", .{objc.nsString(title)}), "autorelease", .{});
    // Our `enabled`, not AppKit's guess.
    msg(void, m, "setAutoenablesItems:", .{false});
    return m;
}

fn newItem(title: []const u8, action: SEL, key: []const u8) id {
    return msg(id, msg(id, msg(id, class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{ objc.nsString(title), action, objc.nsString(key) }), "autorelease", .{});
}

/// The application menu: Hide, Hide Others, Show All, Quit.
fn applicationMenu() id {
    const name = objc.utf8(msg(id, msg(id, class("NSProcessInfo"), "processInfo", .{}), "processName", .{}));
    const sub = newMenu(name);
    msg(void, sub, "setAutoenablesItems:", .{true});
    var buf: [256]u8 = undefined;
    msg(void, sub, "addItem:", .{newItem(std.fmt.bufPrint(&buf, "Hide {s}", .{name}) catch "Hide", objc.sel("hide:"), "h")});
    const others = newItem("Hide Others", objc.sel("hideOtherApplications:"), "h");
    msg(void, others, "setKeyEquivalentModifierMask:", .{@as(usize, command | option)});
    msg(void, sub, "addItem:", .{others});
    msg(void, sub, "addItem:", .{newItem("Show All", objc.sel("unhideAllApplications:"), "")});
    msg(void, sub, "addItem:", .{msg(id, class("NSMenuItem"), "separatorItem", .{})});
    msg(void, sub, "addItem:", .{newItem(std.fmt.bufPrint(&buf, "Quit {s}", .{name}) catch "Quit", objc.sel("terminate:"), "q")});
    const top = newItem(name, null, "");
    msg(void, top, "setSubmenu:", .{sub});
    return top;
}

fn entry(e: menus.Entry, action: Action) id {
    if (e.separator) return msg(id, class("NSMenuItem"), "separatorItem", .{});
    const key = shortcut(e.shortcut);
    const it = newItem(e.text, objc.sel(action.selector), key.key);
    msg(void, it, "setTarget:", .{action.target()});
    msg(void, it, "setTag:", .{action.tag_base + @as(isize, @intCast(e.id))});
    msg(void, it, "setEnabled:", .{e.enabled});
    msg(void, it, "setState:", .{@as(isize, if (e.checked) 1 else 0)});
    if (key.key.len > 0) msg(void, it, "setKeyEquivalentModifierMask:", .{key.modifiers});
    return it;
}

const Key = struct { key: []const u8 = "", modifiers: usize = 0 };

/// "Ctrl+Shift+S" as a key equivalent: "s" with ⌘⇧ ("Ctrl" and "Cmd" are
/// ⌘, the platform's command key; "Meta" is ⌃).
pub fn shortcut(text: []const u8) Key {
    if (text.len == 0) return .{};
    var k: Key = .{};
    var parts = std.mem.splitScalar(u8, text, '+');
    while (parts.next()) |raw| {
        const p = std.mem.trim(u8, raw, " ");
        if (parts.peek() == null) {
            k.key = keyName(p) orelse return .{};
        } else if (std.ascii.eqlIgnoreCase(p, "ctrl") or std.ascii.eqlIgnoreCase(p, "cmd") or std.ascii.eqlIgnoreCase(p, "command")) {
            k.modifiers |= command;
        } else if (std.ascii.eqlIgnoreCase(p, "shift")) {
            k.modifiers |= shift;
        } else if (std.ascii.eqlIgnoreCase(p, "alt") or std.ascii.eqlIgnoreCase(p, "option")) {
            k.modifiers |= option;
        } else if (std.ascii.eqlIgnoreCase(p, "meta")) {
            k.modifiers |= control;
        } else return .{};
    }
    return k;
}

/// The key equivalent string of a key name ("S" → "s", "Delete").
fn keyName(name: []const u8) ?[]const u8 {
    const lower = "abcdefghijklmnopqrstuvwxyz";
    if (name.len == 1) {
        if (std.ascii.isUpper(name[0])) return lower[name[0] - 'A' ..][0..1];
        return name;
    }
    const named = .{
        .{ "Delete", "\x7f" }, .{ "Backspace", "\x08" }, .{ "Return", "\r" },   .{ "Enter", "\r" },
        .{ "Tab", "\t" },      .{ "Esc", "\x1b" },       .{ "Escape", "\x1b" }, .{ "Space", " " },
    };
    inline for (named) |n| if (std.ascii.eqlIgnoreCase(name, n[0])) return n[1];
    return null;
}

test "shortcuts as key equivalents" {
    const t = std.testing;
    const s = shortcut("Ctrl+Shift+S");
    try t.expectEqualStrings("s", s.key);
    try t.expectEqual(@as(usize, command | shift), s.modifiers);
    try t.expectEqualStrings("o", shortcut("Ctrl+O").key);
    try t.expectEqual(@as(usize, command | option), shortcut("Cmd+Alt+H").modifiers);
    try t.expectEqualStrings("\x7f", shortcut("Ctrl+Delete").key);
    try t.expectEqualStrings("", shortcut("Ctrl+Hyper+X").key);
}

test "the menus in the menu bar, and a choice from them" {
    var menu: menus.PlatformMenu = undefined;
    menus.setMenuBar(provider);
    defer menus.setMenuBar(null);
    menu.init(std.testing.allocator);
    defer menu.deinit();
    menu.text.set("View");
    var dark: menus.PlatformMenuItem = .{};
    defer dark.deinit();
    dark.text.set("Dark mode");
    dark.shortcut.set("Ctrl+D");
    dark.checked.set(true);
    menu.item.appendChild(&dark.item);
    var chose: usize = 0;
    dark.activated.setHandler(&chose, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);
    menus.update();

    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    const bar = msg(id, msg(id, class("NSApplication"), "sharedApplication", .{}), "mainMenu", .{});
    try std.testing.expectEqual(@as(isize, 2), msg(isize, bar, "numberOfItems", .{})); // the application's, View
    const view = msg(id, msg(id, bar, "itemAtIndex:", .{@as(isize, 1)}), "submenu", .{});
    try std.testing.expectEqualStrings("View", objc.utf8(msg(id, view, "title", .{})));
    const item = msg(id, view, "itemAtIndex:", .{@as(isize, 0)});
    try std.testing.expectEqualStrings("Dark mode", objc.utf8(msg(id, item, "title", .{})));
    try std.testing.expectEqualStrings("d", objc.utf8(msg(id, item, "keyEquivalent", .{})));
    try std.testing.expectEqual(@as(isize, 1), msg(isize, item, "state", .{}));
    // Chosen as AppKit would: the target's action with the item.
    _ = msg(bool, msg(id, class("NSApplication"), "sharedApplication", .{}), "sendAction:to:from:", .{ objc.sel("zigMenuItem:"), msg(id, item, "target", .{}), item });
    try std.testing.expectEqual(@as(usize, 1), chose);
}

test "entries a level deeper are a submenu" {
    var menu: menus.PlatformMenu = undefined;
    menus.setMenuBar(provider);
    defer menus.setMenuBar(null);
    menu.init(std.testing.allocator);
    defer menu.deinit();
    menu.text.set("File");
    // Export (PNG, Vector (SVG)), Quit.
    var entries: [5]menus.PlatformMenuItem = @splat(.{});
    defer for (&entries) |*e| e.deinit();
    for (&entries, [_][]const u8{ "Export", "PNG", "Vector", "SVG", "Quit" }, [_]i32{ 0, 1, 1, 2, 0 }) |*e, text, level| {
        e.text.set(text);
        e.level.set(level);
        menu.item.appendChild(&e.item);
    }
    var chose: usize = 0;
    entries[3].activated.setHandler(&chose, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);
    menus.update();

    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    const bar = msg(id, msg(id, class("NSApplication"), "sharedApplication", .{}), "mainMenu", .{});
    const file = msg(id, msg(id, bar, "itemAtIndex:", .{@as(isize, 1)}), "submenu", .{});
    try std.testing.expectEqual(@as(isize, 2), msg(isize, file, "numberOfItems", .{})); // Export, Quit
    const export_menu = msg(id, msg(id, file, "itemAtIndex:", .{@as(isize, 0)}), "submenu", .{});
    try std.testing.expect(export_menu != null);
    try std.testing.expectEqual(@as(isize, 2), msg(isize, export_menu, "numberOfItems", .{})); // PNG, Vector
    const vector = msg(id, msg(id, export_menu, "itemAtIndex:", .{@as(isize, 1)}), "submenu", .{});
    const svg = msg(id, vector, "itemAtIndex:", .{@as(isize, 0)});
    try std.testing.expectEqualStrings("SVG", objc.utf8(msg(id, svg, "title", .{})));
    try std.testing.expectEqualStrings("Quit", objc.utf8(msg(id, msg(id, file, "itemAtIndex:", .{@as(isize, 1)}), "title", .{})));
    _ = msg(bool, msg(id, class("NSApplication"), "sharedApplication", .{}), "sendAction:to:from:", .{ objc.sel("zigMenuItem:"), msg(id, svg, "target", .{}), svg });
    try std.testing.expectEqual(@as(usize, 1), chose);
}
