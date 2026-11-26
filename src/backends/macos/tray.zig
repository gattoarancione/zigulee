// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The system tray and notifications on macOS: tray icons are status
//! items on the right of the menu bar (NSStatusItem), notifications go to
//! the Notification Center (UserNotifications). Those need an application
//! bundle; a program run outside one has its notifications shown by
//! AppleScript instead (`display notification`), and clicks on them are
//! not reported.

const std = @import("std");
const zigulee = @import("zigulee");
const objc = @import("zigulee-apple").objc;
const menubar = @import("menubar.zig");
const tray = zigulee.core.tray;
const id = objc.id;
const SEL = objc.SEL;
const msg = objc.msg;
const class = objc.class;
const log = std.log.scoped(.zigulee);

pub const provider: tray.Provider = .{ .show = show, .remove = remove, .notify = notify };

// ---- Tray icons ----

const max_icons = 16;
/// Menu item tags: the icon's slot times this, plus the entry's id.
const tag_slot = 1 << 16;

const Slot = struct { key: usize, item: id };
var slots: [max_icons]?Slot = @splat(null);

var target: id = null;

/// The object status items and their menus send their actions to.
fn trayTarget() id {
    if (target) |t| return t;
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("NSObject"), "ZiguleeTrayTarget", 0);
    _ = objc.class_addMethod(cls, objc.sel("zigTrayClicked:"), @ptrCast(&clicked), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("zigTrayItem:"), @ptrCast(&chosen), "v@:@");
    objc.objc_registerClassPair(cls);
    target = msg(id, msg(id, cls, "alloc", .{}), "init", .{});
    return target;
}

fn clicked(_: id, _: SEL, sender: id) callconv(.c) void {
    for (slots) |s| if (s) |slot| if (msg(id, slot.item, "button", .{}) == sender) return tray.activate(slot.key);
}

fn chosen(_: id, _: SEL, sender: id) callconv(.c) void {
    const tag = msg(isize, sender, "tag", .{});
    if (tag < 0) return;
    const slot = slots[@intCast(@divTrunc(tag, tag_slot))] orelse return;
    tray.choose(slot.key, @intCast(@mod(tag, tag_slot)));
}

fn slotOf(key: usize) ?usize {
    for (slots, 0..) |s, i| if (s) |slot| if (slot.key == key) return i;
    return null;
}

fn show(_: ?*anyopaque, icon: *const tray.Icon) void {
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    const i = slotOf(icon.key) orelse blk: {
        const free = for (slots, 0..) |s, i| {
            if (s == null) break i;
        } else return;
        const bar = msg(id, class("NSStatusBar"), "systemStatusBar", .{});
        const item = msg(id, msg(id, bar, "statusItemWithLength:", .{@as(f64, -1)}), "retain", .{}); // as wide as needed
        slots[free] = .{ .key = icon.key, .item = item };
        break :blk free;
    };
    const item = slots[i].?.item;
    const button = msg(id, item, "button", .{});
    if (icon.image) |img| {
        msg(void, button, "setImage:", .{nsImage(img)});
        msg(void, button, "setTitle:", .{objc.nsString("")});
    } else {
        msg(void, button, "setImage:", .{@as(id, null)});
        msg(void, button, "setTitle:", .{objc.nsString(if (icon.tooltip.len > 0) icon.tooltip else "•")});
    }
    msg(void, button, "setToolTip:", .{objc.nsString(icon.tooltip)});
    if (icon.entries.len > 0) {
        msg(void, item, "setMenu:", .{menubar.menuOf(icon.entries, .{
            .target = trayTarget,
            .selector = "zigTrayItem:",
            .tag_base = @as(isize, @intCast(i)) * tag_slot,
        })});
    } else {
        msg(void, item, "setMenu:", .{@as(id, null)});
        msg(void, button, "setTarget:", .{trayTarget()});
        msg(void, button, "setAction:", .{objc.sel("zigTrayClicked:")});
    }
}

fn remove(_: ?*anyopaque, key: usize) void {
    const i = slotOf(key) orelse return;
    const item = slots[i].?.item;
    msg(void, msg(id, class("NSStatusBar"), "systemStatusBar", .{}), "removeStatusItem:", .{item});
    msg(void, item, "release", .{});
    slots[i] = null;
}

/// `img` as an autoreleased NSImage as tall as the menu bar's icons.
fn nsImage(img: zigulee.core.Image) id {
    const rep = msg(id, msg(id, class("NSBitmapImageRep"), "alloc", .{}), "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:", .{
        @as(?*anyopaque, null), @as(isize, @intCast(img.width)),        @as(isize, @intCast(img.height)),
        @as(isize, 8),          @as(isize, 4),                          true,
        false,                  objc.nsString("NSDeviceRGBColorSpace"), @as(isize, @intCast(img.width * 4)),
        @as(isize, 32),
    });
    const data = msg([*]u8, rep, "bitmapData", .{});
    @memcpy(data[0 .. img.pixels.len * 4], std.mem.sliceAsBytes(img.pixels));
    const h: f64 = 18;
    const size: objc.NSSize = .{ .width = h * @as(f64, @floatFromInt(img.width)) / @as(f64, @floatFromInt(img.height)), .height = h };
    msg(void, rep, "setSize:", .{size});
    const image = msg(id, msg(id, msg(id, class("NSImage"), "alloc", .{}), "initWithSize:", .{size}), "autorelease", .{});
    msg(void, image, "addRepresentation:", .{rep});
    msg(void, rep, "release", .{});
    return image;
}

// ---- Notifications ----

const Block = objc.Block;

const options_badge_sound_alert = 1 | 2 | 4;
const present_list_banner_sound = (1 << 3) | (1 << 4) | (1 << 1);
const identifier_prefix = "zigulee-";

var center: id = null;
/// The first notification, posted once permission is given.
var first: std.atomic.Value(?*anyopaque) = .init(null);

/// The application has a bundle identifier (the notification center needs
/// one).
fn bundled() bool {
    const bundle = msg(id, class("NSBundle"), "mainBundle", .{});
    return msg(id, bundle, "bundleIdentifier", .{}) != null and class("UNUserNotificationCenter") != null;
}

fn notify(_: ?*anyopaque, notice: *const tray.Notice) void {
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    if (!bundled()) return appleScript(notice);
    const content = msg(id, msg(id, msg(id, class("UNMutableNotificationContent"), "alloc", .{}), "init", .{}), "autorelease", .{});
    msg(void, content, "setTitle:", .{objc.nsString(notice.title)});
    msg(void, content, "setBody:", .{objc.nsString(notice.body)});
    msg(void, content, "setSound:", .{msg(id, class("UNNotificationSound"), "defaultSound", .{})});
    var buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, identifier_prefix ++ "{d}", .{notice.id}) catch unreachable;
    const request = msg(id, class("UNNotificationRequest"), "requestWithIdentifier:content:trigger:", .{ objc.nsString(name), content, @as(id, null) });
    if (center == null) {
        // The first time: ask for permission, then post it.
        center = msg(id, msg(id, class("UNUserNotificationCenter"), "currentNotificationCenter", .{}), "retain", .{});
        msg(void, center, "setDelegate:", .{msg(id, msg(id, delegateClass(), "alloc", .{}), "init", .{})});
        first.store(msg(id, request, "retain", .{}), .release);
        msg(void, center, "requestAuthorizationWithOptions:completionHandler:", .{ @as(usize, options_badge_sound_alert), &authorized_block });
        return;
    }
    msg(void, center, "addNotificationRequest:withCompletionHandler:", .{ request, @as(?*anyopaque, null) });
}

var authorized_block: Block = .global(&authorized);

/// Permission given or refused (on another thread).
fn authorized(_: *Block, granted: bool, _: id) callconv(.c) void {
    const request = first.swap(null, .acq_rel) orelse return;
    if (granted) msg(void, center, "addNotificationRequest:withCompletionHandler:", .{ request, @as(?*anyopaque, null) });
    msg(void, request, "release", .{});
}

var delegate_class: id = null;

fn delegateClass() id {
    if (delegate_class) |c| return c;
    const cls = objc.objc_allocateClassPair(objc.objc_getClass("NSObject"), "ZiguleeNotificationDelegate", 0);
    _ = objc.class_addProtocol(cls, objc.objc_getProtocol("UNUserNotificationCenterDelegate"));
    _ = objc.class_addMethod(cls, objc.sel("userNotificationCenter:willPresentNotification:withCompletionHandler:"), @ptrCast(&willPresent), "v@:@@@?");
    _ = objc.class_addMethod(cls, objc.sel("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:"), @ptrCast(&didReceive), "v@:@@@?");
    objc.objc_registerClassPair(cls);
    delegate_class = cls;
    return cls;
}

/// Shown even while the application is in front.
fn willPresent(_: id, _: SEL, _: id, _: id, done: ?*Block) callconv(.c) void {
    Block.call(done, .{@as(usize, present_list_banner_sound)});
}

/// Clicked: reported on the UI thread.
fn didReceive(_: id, _: SEL, _: id, response: id, done: ?*Block) callconv(.c) void {
    const request = msg(id, msg(id, response, "notification", .{}), "request", .{});
    const name = objc.utf8(msg(id, request, "identifier", .{}));
    if (std.mem.startsWith(u8, name, identifier_prefix)) {
        if (std.fmt.parseInt(u32, name[identifier_prefix.len..], 10)) |n| {
            objc.dispatch_async_f(objc.mainQueue(), @ptrFromInt(n), reportClick);
        } else |_| {}
    }
    Block.call(done, .{});
}

fn reportClick(ctx: ?*anyopaque) callconv(.c) void {
    tray.notificationClicked(@intCast(@intFromPtr(ctx)));
}

/// `display notification`, for programs outside a bundle.
fn appleScript(notice: *const tray.Notice) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.c_allocator);
    const a = std.heap.c_allocator;
    buf.appendSlice(a, "display notification ") catch return;
    quoted(&buf, notice.body) catch return;
    buf.appendSlice(a, " with title ") catch return;
    quoted(&buf, notice.title) catch return;
    const script = msg(id, msg(id, class("NSAppleScript"), "alloc", .{}), "initWithSource:", .{objc.nsString(buf.items)});
    var err: id = null;
    if (msg(id, script, "executeAndReturnError:", .{&err}) == null)
        log.warn("cannot show a notification: {s}", .{objc.utf8(msg(id, err, "description", .{}))});
    msg(void, script, "release", .{});
}

/// `s` as an AppleScript string.
fn quoted(buf: *std.ArrayList(u8), s: []const u8) !void {
    const a = std.heap.c_allocator;
    try buf.append(a, '"');
    for (s) |ch| {
        if (ch == '"' or ch == '\\') try buf.append(a, '\\');
        try buf.append(a, ch);
    }
    try buf.append(a, '"');
}

// ---- Tests ----

const testing = std.testing;

fn count(n: *usize) void {
    n.* += 1;
}

test "a status item for a tray icon: its title, tooltip and menu; clicks" {
    var icon: tray.SystemTrayIcon = undefined;
    icon.init(testing.allocator);
    defer icon.deinit();
    tray.setProvider(provider);
    defer tray.setProvider(null);
    icon.tooltip.set("Zigulee test");
    var clicks: usize = 0;
    icon.activated.setHandler(&clicks, count);
    tray.update();

    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    const i = slotOf(@intFromPtr(&icon)).?;
    const item = slots[i].?.item;
    const button = msg(id, item, "button", .{});
    try testing.expectEqualStrings("Zigulee test", objc.utf8(msg(id, button, "title", .{})));
    try testing.expectEqualStrings("Zigulee test", objc.utf8(msg(id, button, "toolTip", .{})));
    try testing.expect(msg(id, item, "menu", .{}) == null);
    const app = msg(id, class("NSApplication"), "sharedApplication", .{});
    _ = msg(bool, app, "sendAction:to:from:", .{ msg(SEL, button, "action", .{}), msg(id, button, "target", .{}), button });
    try testing.expectEqual(@as(usize, 1), clicks);

    // A menu, and an image.
    var quit: zigulee.core.menus.PlatformMenuItem = .{};
    defer quit.deinit();
    quit.text.set("Quit");
    icon.item.appendChild(&quit.item);
    var quits: usize = 0;
    quit.activated.setHandler(&quits, count);
    var pixels: [4]zigulee.core.Rgba8 = @splat(.{ .r = 255, .a = 255 });
    icon.icon.set(.{ .width = 2, .height = 2, .pixels = &pixels });
    tray.update();
    try testing.expectEqualStrings("", objc.utf8(msg(id, button, "title", .{})));
    try testing.expect(msg(id, button, "image", .{}) != null);
    const menu = msg(id, item, "menu", .{});
    try testing.expectEqual(@as(isize, 1), msg(isize, menu, "numberOfItems", .{}));
    const entry = msg(id, menu, "itemAtIndex:", .{@as(isize, 0)});
    try testing.expectEqualStrings("Quit", objc.utf8(msg(id, entry, "title", .{})));
    _ = msg(bool, app, "sendAction:to:from:", .{ objc.sel("zigTrayItem:"), msg(id, entry, "target", .{}), entry });
    try testing.expectEqual(@as(usize, 1), quits);

    icon.item.visible.set(false);
    tray.update();
    try testing.expect(slotOf(@intFromPtr(&icon)) == null);
}

test "AppleScript strings" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.c_allocator);
    try quoted(&buf, "say \"hi\" \\o/");
    try testing.expectEqualStrings("\"say \\\"hi\\\" \\\\o/\"", buf.items);
}
