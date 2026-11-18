// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The system tray and notifications on Windows: tray icons in the
//! notification area (Shell_NotifyIcon), their menus popped up where they
//! were clicked, and notifications shown as an icon's balloon (Windows 10
//! and 11 show them as notifications). Without a tray icon, notifications
//! bring one up with the application's icon, and it stays.
//!
//! The icons' messages go to a hidden window of the UI thread, which the
//! backend's message loop (Win32's or SDL's) dispatches.

const std = @import("std");
const zigulee = @import("zigulee");
const c = @import("win32_c");
const tray = zigulee.core.tray;
const menus = zigulee.core.menus;

pub const provider: tray.Provider = .{ .show = show, .remove = remove, .notify = notify };

/// NOTIFYICONDATAW (declared here: its union does not translate well).
const NotifyIconData = extern struct {
    cbSize: u32 = @sizeOf(NotifyIconData),
    hWnd: c.HWND = null,
    uID: u32 = 0,
    uFlags: u32 = 0,
    uCallbackMessage: u32 = 0,
    hIcon: c.HICON = null,
    szTip: [128]u16 = @splat(0),
    dwState: u32 = 0,
    dwStateMask: u32 = 0,
    szInfo: [256]u16 = @splat(0),
    /// Or uTimeout.
    uVersion: u32 = 0,
    szInfoTitle: [64]u16 = @splat(0),
    dwInfoFlags: u32 = 0,
    guidItem: [16]u8 = @splat(0),
    hBalloonIcon: c.HICON = null,
};

/// With a parent that is not a window (HWND_MESSAGE, misaligned for c.HWND).
extern "user32" fn CreateWindowExW(ex_style: u32, class: [*:0]const u16, title: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?*anyopaque, menu: ?*anyopaque, instance: c.HINSTANCE, param: ?*anyopaque) callconv(.winapi) c.HWND;
extern "shell32" fn Shell_NotifyIconW(message: u32, data: *NotifyIconData) callconv(.winapi) c.BOOL;

const nim_add = 0;
const nim_modify = 1;
const nim_delete = 2;
const nim_setversion = 4;
const nif_message = 0x1;
const nif_icon = 0x2;
const nif_tip = 0x4;
const nif_info = 0x10;
const nif_showtip = 0x80;
const niif_info = 0x1;
const notifyicon_version_4 = 4;
const nin_select = 0x400;
const nin_keyselect = 0x401;
const nin_balloonuserclick = 0x405;
const wm_contextmenu = 0x7b;

/// What the icons send their events with.
const callback_message = c.WM_APP + 1;
/// The icon notifications bring up when there is no other.
const notice_key: usize = 0;

const max_icons = 16;

const Slot = struct {
    key: usize,
    /// The menu's entries (their texts in `arena`).
    entries: []menus.Entry = &.{},
    arena: std.heap.ArenaAllocator,
    /// Made from the icon's image (null: the application's icon).
    hicon: c.HICON = null,
    /// The notification its balloon shows.
    notice: u32 = 0,
};

var slots: [max_icons]?Slot = @splat(null);
var hwnd: c.HWND = null;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZiguleeTray");

/// The hidden window the icons talk to (made the first time).
fn window() c.HWND {
    if (hwnd != null) return hwnd;
    const instance = c.GetModuleHandleW(null);
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = windowProc;
    wc.hInstance = instance;
    wc.lpszClassName = class_name;
    _ = c.RegisterClassExW(&wc);
    // A message-only window (its parent HWND_MESSAGE).
    const message_only: *anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));
    hwnd = CreateWindowExW(0, class_name, class_name, 0, 0, 0, 0, 0, message_only, null, instance, null);
    return hwnd;
}

fn slotOf(key: usize) ?usize {
    for (slots, 0..) |s, i| if (s) |slot| if (slot.key == key) return i;
    return null;
}

fn data(i: usize) NotifyIconData {
    return .{ .hWnd = window(), .uID = @intCast(i + 1), .uFlags = nif_message, .uCallbackMessage = callback_message };
}

/// Copies `s` into `dst` as UTF-16, cut to fit with a terminating 0.
fn wide(dst: []u16, s: []const u8) void {
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(s) catch std.unicode.Utf8View.initUnchecked("")).iterator();
    while (it.nextCodepoint()) |cp| {
        var pair: [2]u16 = undefined;
        const len: usize = if (cp >= 0x10000) 2 else 1;
        if (n + len >= dst.len) break;
        if (len == 2) {
            const v = cp - 0x10000;
            pair = .{ @intCast(0xd800 + (v >> 10)), @intCast(0xdc00 + (v & 0x3ff)) };
        } else pair[0] = @intCast(cp);
        @memcpy(dst[n..][0..len], pair[0..len]);
        n += len;
    }
    dst[n] = 0;
}

/// Adds the icon in slot `i`, or updates it.
fn place(i: usize, tooltip: []const u8, added: bool) void {
    var d = data(i);
    d.uFlags |= nif_icon | nif_tip | nif_showtip;
    d.hIcon = slots[i].?.hicon orelse c.LoadIconW(null, @ptrFromInt(32512)); // IDI_APPLICATION
    wide(&d.szTip, tooltip);
    if (added) {
        _ = Shell_NotifyIconW(nim_modify, &d);
        return;
    }
    _ = Shell_NotifyIconW(nim_add, &d);
    d.uVersion = notifyicon_version_4;
    _ = Shell_NotifyIconW(nim_setversion, &d);
}

fn show(_: ?*anyopaque, icon: *const tray.Icon) void {
    const existing = slotOf(icon.key);
    const i = existing orelse for (slots, 0..) |s, i| {
        if (s == null) break i;
    } else return;
    if (existing == null) slots[i] = .{ .key = icon.key, .arena = .init(std.heap.page_allocator) };
    const slot = &slots[i].?;
    _ = slot.arena.reset(.retain_capacity);
    const a = slot.arena.allocator();
    slot.entries = a.dupe(menus.Entry, icon.entries) catch &.{};
    for (slot.entries) |*e| {
        e.text = a.dupe(u8, e.text) catch "";
        e.shortcut = a.dupe(u8, e.shortcut) catch "";
    }
    if (slot.hicon) |h| _ = c.DestroyIcon(h);
    slot.hicon = if (icon.image) |img| hIcon(img) else null;
    place(i, icon.tooltip, existing != null);
    // The icon notifications brought up is not needed any more.
    if (icon.key != notice_key) if (slotOf(notice_key)) |n| remove(null, slots[n].?.key);
}

fn remove(_: ?*anyopaque, key: usize) void {
    const i = slotOf(key) orelse return;
    var d = data(i);
    _ = Shell_NotifyIconW(nim_delete, &d);
    if (slots[i].?.hicon) |h| _ = c.DestroyIcon(h);
    slots[i].?.arena.deinit();
    slots[i] = null;
}

fn notify(_: ?*anyopaque, notice: *const tray.Notice) void {
    // On the first icon, or one brought up for it.
    const i = for (slots, 0..) |s, i| {
        if (s != null) break i;
    } else blk: {
        show(null, &.{ .key = notice_key, .tooltip = "", .image = null, .entries = &.{} });
        break :blk slotOf(notice_key) orelse return;
    };
    var d = data(i);
    d.uFlags |= nif_info;
    d.dwInfoFlags = niif_info;
    wide(&d.szInfoTitle, notice.title);
    wide(&d.szInfo, if (notice.body.len > 0) notice.body else " ");
    slots[i].?.notice = notice.id;
    _ = Shell_NotifyIconW(nim_modify, &d);
}

/// `img` as an icon (its pixels' alpha made straight, as icons have it).
fn hIcon(img: zigulee.core.Image) c.HICON {
    var bi = std.mem.zeroes(c.BITMAPV5HEADER);
    bi.bV5Size = @sizeOf(c.BITMAPV5HEADER);
    bi.bV5Width = @intCast(img.width);
    bi.bV5Height = -@as(i32, @intCast(img.height)); // top-down
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = c.BI_BITFIELDS;
    bi.bV5RedMask = 0x00ff0000;
    bi.bV5GreenMask = 0x0000ff00;
    bi.bV5BlueMask = 0x000000ff;
    bi.bV5AlphaMask = 0xff000000;
    var bits: ?*anyopaque = null;
    const dc = c.GetDC(null);
    defer _ = c.ReleaseDC(null, dc);
    const color = c.CreateDIBSection(dc, @ptrCast(&bi), c.DIB_RGB_COLORS, &bits, null, 0) orelse return null;
    defer _ = c.DeleteObject(color);
    const out: [*][4]u8 = @ptrCast(bits.?);
    for (img.pixels, 0..) |p, k| {
        const un = struct {
            fn f(v: u8, alpha: u8) u8 {
                return if (alpha == 0) 0 else @intCast(@min(255, (@as(u32, v) * 255 + alpha / 2) / alpha));
            }
        }.f;
        out[k] = .{ un(p.b, p.a), un(p.g, p.a), un(p.r, p.a), p.a };
    }
    const mask = c.CreateBitmap(@intCast(img.width), @intCast(img.height), 1, 1, null) orelse return null;
    defer _ = c.DeleteObject(mask);
    var info: c.ICONINFO = .{ .fIcon = c.TRUE, .xHotspot = 0, .yHotspot = 0, .hbmMask = mask, .hbmColor = color };
    return c.CreateIconIndirect(&info);
}

/// Pops up the menu of slot `i` at (x, y); the entry chosen, if one was.
fn popUp(i: usize, x: i32, y: i32) ?usize {
    const entries = slots[i].?.entries;
    const menu = c.CreatePopupMenu() orelse return null;
    defer _ = c.DestroyMenu(menu);
    _ = fill(menu, entries, 0, 0);
    // So that the menu closes when clicked away from.
    _ = c.SetForegroundWindow(window());
    const chosen = c.TrackPopupMenu(menu, c.TPM_RETURNCMD | c.TPM_NONOTIFY | c.TPM_RIGHTBUTTON, x, y, 0, window(), null);
    _ = c.PostMessageW(window(), c.WM_NULL, 0, 0);
    return if (chosen > 0) @intCast(chosen - 1) else null;
}

/// Adds the entries of `level` from `entries[start..]` to `menu`, deeper
/// ones as submenus; returns where the entries of `level` end.
fn fill(menu: c.HMENU, entries: []const menus.Entry, start: usize, level: u32) usize {
    var i = start;
    while (i < entries.len and entries[i].level >= level) {
        const e = entries[i];
        i += 1;
        if (e.level > level) continue;
        if (e.separator) {
            _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
            continue;
        }
        var text: [256]u16 = undefined;
        var label: [300]u8 = undefined;
        wide(&text, if (e.shortcut.len > 0) std.fmt.bufPrint(&label, "{s}\t{s}", .{ e.text, e.shortcut }) catch e.text else e.text);
        var flags: c.UINT = c.MF_STRING;
        if (e.checked) flags |= c.MF_CHECKED;
        if (!e.enabled) flags |= c.MF_GRAYED;
        if (i < entries.len and entries[i].level > level) {
            const sub = c.CreatePopupMenu() orelse continue;
            i = fill(sub, entries, i, level + 1);
            _ = c.AppendMenuW(menu, flags | c.MF_POPUP, @intFromPtr(sub), &text);
        } else _ = c.AppendMenuW(menu, flags, e.id + 1, &text);
    }
    return i;
}

fn windowProc(h: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (message != callback_message) return c.DefWindowProcW(h, message, wparam, lparam);
    const l: usize = @bitCast(lparam);
    const event = l & 0xffff;
    const uid = (l >> 16) & 0xffff;
    if (uid == 0 or uid > max_icons) return 0;
    const i = uid - 1;
    const slot = slots[i] orelse return 0;
    switch (event) {
        nin_select, nin_keyselect, wm_contextmenu => {
            if (slot.key == notice_key) return 0;
            if (slot.entries.len == 0) {
                if (event != wm_contextmenu) tray.activate(slot.key);
                return 0;
            }
            // Where it was clicked (screen coordinates, in wparam).
            const x: i16 = @bitCast(@as(u16, @truncate(wparam)));
            const y: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            if (popUp(i, x, y)) |id| tray.choose(slot.key, id);
        },
        nin_balloonuserclick => if (slot.notice != 0) tray.notificationClicked(slot.notice),
        else => {},
    }
    return 0;
}

/// Takes every icon away (when the backend stops).
pub fn removeAll() void {
    for (slots) |s| if (s) |slot| remove(null, slot.key);
}

test "text for the shell: UTF-16, cut to fit" {
    var buf: [6]u16 = undefined;
    wide(&buf, "héllo wörld");
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("héllo"), buf[0..5]);
    try std.testing.expectEqual(@as(u16, 0), buf[5]);
    // A surrogate pair, then no room for the "b".
    var emoji: [4]u16 = undefined;
    wide(&emoji, "a😀b");
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0xd83d, 0xde00, 0 }, &emoji);
}
