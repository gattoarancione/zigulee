// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Tray icons through SDL (used on Linux, where SDL shows them with the
//! desktop's StatusNotifierItem support; macOS and Windows have their
//! own). SDL reports no clicks on the icon itself: a click opens its menu,
//! and an icon without one cannot be activated.

const std = @import("std");
const zigulee = @import("zigulee");
const c = @import("sdl3_c");
const tray = zigulee.core.tray;
const menus = zigulee.core.menus;

const log = std.log.scoped(.zigulee_sdl3);

/// Tray icons only; `notify` and `poll` come from elsewhere.
pub const icons: tray.Provider = .{ .show = show, .remove = remove };

const max_icons = 16;
/// Entry callbacks' user data: the slot times this, plus the entry's id.
const tag_slot = 1 << 16;

const Slot = struct { key: usize, tray: *c.SDL_Tray };
var slots: [max_icons]?Slot = @splat(null);
var warned = false;

fn slotOf(key: usize) ?usize {
    for (slots, 0..) |s, i| if (s) |slot| if (slot.key == key) return i;
    return null;
}

fn show(_: ?*anyopaque, icon: *const tray.Icon) void {
    var tip_buf: [256]u8 = undefined;
    const tip = std.fmt.bufPrintZ(&tip_buf, "{s}", .{icon.tooltip}) catch "";
    const surface = if (icon.image) |img| sdlSurface(img) else null;
    defer if (surface) |s| c.SDL_DestroySurface(s);
    const i = slotOf(icon.key) orelse blk: {
        const free = for (slots, 0..) |s, i| {
            if (s == null) break i;
        } else return;
        const t = c.SDL_CreateTray(surface, tip.ptr) orelse {
            if (!warned) log.info("no tray icon: {s}", .{c.SDL_GetError()});
            warned = true;
            return;
        };
        slots[free] = .{ .key = icon.key, .tray = t };
        break :blk free;
    };
    const t = slots[i].?.tray;
    c.SDL_SetTrayIcon(t, surface);
    c.SDL_SetTrayTooltip(t, tip.ptr);
    // The menu, made again.
    const menu = c.SDL_GetTrayMenu(t) orelse c.SDL_CreateTrayMenu(t) orelse return;
    clear(menu);
    _ = fill(menu, icon.entries, 0, 0, i);
}

/// Removes every entry of `menu`.
fn clear(menu: *c.SDL_TrayMenu) void {
    while (true) {
        var n: c_int = 0;
        const list = c.SDL_GetTrayEntries(menu, &n);
        if (list == null or n == 0) return;
        c.SDL_RemoveTrayEntry(@constCast(list[0]));
    }
}

fn fill(menu: *c.SDL_TrayMenu, entries: []const menus.Entry, start: usize, level: u32, slot: usize) usize {
    var i = start;
    while (i < entries.len and entries[i].level >= level) {
        const e = entries[i];
        i += 1;
        if (e.level > level) continue;
        if (e.separator) {
            _ = c.SDL_InsertTrayEntryAt(menu, -1, null, c.SDL_TRAYENTRY_BUTTON);
            continue;
        }
        var buf: [256]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "{s}", .{e.text}) catch "";
        const sub = i < entries.len and entries[i].level > level;
        var flags: c.SDL_TrayEntryFlags = if (sub) c.SDL_TRAYENTRY_SUBMENU else if (e.checked) c.SDL_TRAYENTRY_CHECKBOX else c.SDL_TRAYENTRY_BUTTON;
        if (e.checked and !sub) flags |= c.SDL_TRAYENTRY_CHECKED;
        if (!e.enabled) flags |= c.SDL_TRAYENTRY_DISABLED;
        const entry = c.SDL_InsertTrayEntryAt(menu, -1, label.ptr, flags) orelse continue;
        if (sub) {
            const submenu = c.SDL_CreateTraySubmenu(entry) orelse continue;
            i = fill(submenu, entries, i, level + 1, slot);
        } else c.SDL_SetTrayEntryCallback(entry, chosen, @ptrFromInt(slot * tag_slot + e.id + 1));
    }
    return i;
}

fn chosen(userdata: ?*anyopaque, _: ?*c.SDL_TrayEntry) callconv(.c) void {
    const tag = @intFromPtr(userdata) - 1;
    const slot = slots[tag / tag_slot] orelse return;
    tray.choose(slot.key, tag % tag_slot);
}

fn remove(_: ?*anyopaque, key: usize) void {
    const i = slotOf(key) orelse return;
    c.SDL_DestroyTray(slots[i].?.tray);
    slots[i] = null;
}

/// `img` as an SDL surface (straight alpha, as SDL has it).
fn sdlSurface(img: zigulee.core.Image) ?*c.SDL_Surface {
    const s = c.SDL_CreateSurface(@intCast(img.width), @intCast(img.height), c.SDL_PIXELFORMAT_RGBA32) orelse return null;
    const pitch: usize = @intCast(s.*.pitch);
    const out: [*]u8 = @ptrCast(s.*.pixels.?);
    for (0..img.height) |y| for (0..img.width) |x| {
        const p = img.pixels[y * img.width + x];
        const un = struct {
            fn f(v: u8, alpha: u8) u8 {
                return if (alpha == 0) 0 else @intCast(@min(255, (@as(u32, v) * 255 + alpha / 2) / alpha));
            }
        }.f;
        out[y * pitch + x * 4 ..][0..4].* = .{ un(p.r, p.a), un(p.g, p.a), un(p.b, p.a), p.a };
    };
    return s;
}
