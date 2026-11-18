// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The iOS backend's test (`zig build test-ios`): an app (Mac Catalyst on
//! a Mac) opening a window and driving it as UIKit does: touches, the
//! keyboard, the safe area, VoiceOver. Exits with 0 when all is well.

const std = @import("std");
const zigulee = @import("zigulee");
const ios = @import("zigulee-ios");
const ui = @import("ios_test_ui");
const objc = ios.objc;
const id = objc.id;
const msg = objc.msg;
const class = objc.class;

const log = std.log.scoped(.ios_test);

fn check(ok: bool, what: []const u8) !void {
    if (ok) return;
    log.err("failed: {s}", .{what});
    return error.TestFailed;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    try ios.init();
    defer ios.deinit();
    const app = try ui.IosTest.create(gpa);
    defer app.destroy();

    // Software rendering: the frame can be read back.
    const window = try ios.Window.create(gpa, app.window(), .{ .title = "zigulee test", .renderer = .software });
    defer window.destroy();
    for (0..20) |_| try window.step(10);
    const size = app.window().size();
    try check(size.width >= 200 and size.height >= 160, "the window has a size");
    try check(window.pixel_width == @as(u32, @intFromFloat(@round(size.width * window.scaleFactor()))), "the framebuffer is in pixels");
    const px = window.framebuffer[@as(usize, @intFromFloat(150 * window.scaleFactor())) * window.pixel_width + window.pixel_width - 4];
    try check(px.r == 0x33 and px.g == 0x66 and px.b == 0x99, "the background is drawn");

    // A tap on the button: a touch down and up, through the view.
    tap(window.view, 20, 20);
    try window.step(0);
    try check(app.clicks.get() == 1, "a tap clicks");

    // A tap on the field: the keyboard comes up (the view takes the
    // text), and typing reaches the field.
    tap(window.view, 20, 136);
    try window.step(0);
    try check(msg(bool, window.view, "isFirstResponder", .{}), "the view takes the keyboard");
    msg(void, window.view, "insertText:", .{objc.nsString("hé")});
    msg(void, window.view, "insertText:", .{objc.nsString("y")});
    msg(void, window.view, "deleteBackward", .{});
    try window.step(0);
    try check(std.mem.eql(u8, app.typed.get(), "hé"), "typing reaches the field");

    // The keyboard covering the bottom 100 points.
    const bounds = msg(objc.NSRect, window.view, "bounds", .{});
    const screen_space = msg(id, msg(id, window.ui_window, "screen", .{}), "coordinateSpace", .{});
    const covered = msg(objc.NSRect, window.view, "convertRect:toCoordinateSpace:", .{ objc.NSRect{ .origin = .{ .y = bounds.size.height - 100 }, .size = .{ .width = bounds.size.width, .height = 100 } }, screen_space });
    keyboardNotification(window.controller, "UIKeyboardWillChangeFrameNotification", covered);
    try check(@abs(app.window().keyboard_height.get() - 100) < 0.5, "the keyboard's height");
    keyboardNotification(window.controller, "UIKeyboardWillHideNotification", null);
    try check(app.window().keyboard_height.get() == 0, "the keyboard hidden");

    // A tap elsewhere: the field keeps the focus (as on other systems);
    // focus moving away puts the keyboard down.
    app.window().setFocusItem(null);
    try window.step(0);
    try check(!msg(bool, window.view, "isFirstResponder", .{}), "the keyboard goes down");
    try check(msg(bool, window.controller, "isFirstResponder", .{}), "hardware keys go to the controller");

    // Full screen: no status bar.
    app.window().fullscreen.set(true);
    try window.step(0);
    try check(msg(bool, window.controller, "prefersStatusBarHidden", .{}), "full screen hides the status bar");
    try check(app.window().fullscreen.get() and !app.window().maximized.get(), "the state is reported");

    // VoiceOver: the button, with its label.
    window.a11y.?.always = true;
    try window.a11y.?.update();
    const elements = msg(id, window.view, "accessibilityElements", .{});
    try check(elements != null and msg(usize, elements, "count", .{}) >= 1, "VoiceOver sees elements");
    const button = msg(id, elements, "objectAtIndex:", .{@as(usize, 0)});
    try check(std.mem.eql(u8, objc.utf8(msg(id, button, "accessibilityLabel", .{})), "Count"), "the button's label");
    try check(msg(u64, button, "accessibilityTraits", .{}) & 1 != 0, "the button's trait");
    try check(msg(bool, button, "accessibilityActivate", .{}) and app.clicks.get() == 2, "VoiceOver presses it");
    // A table's row: one element, read as its cells, selected when pressed.
    var row: id = null;
    for (0..msg(usize, elements, "count", .{})) |i| {
        const e = msg(id, elements, "objectAtIndex:", .{i});
        const label = msg(id, e, "accessibilityLabel", .{});
        if (label != null and std.mem.eql(u8, objc.utf8(label), "Grace, 1906")) row = e;
        if (label != null) try check(!std.mem.eql(u8, objc.utf8(label), "Grace"), "a row's cells are read with it");
    }
    try check(row != null, "a table's row read as its cells");
    try check(msg(u64, row, "accessibilityTraits", .{}) & (1 << 3) == 0, "the row not selected yet");
    try check(msg(bool, row, "accessibilityActivate", .{}), "VoiceOver selects the row");
    zigulee.runChangeHandlers();
    try window.a11y.?.update();
    try check(msg(u64, row, "accessibilityTraits", .{}) & (1 << 3) != 0, "the row selected");

    // Metal: a second window drawing with the GPU.
    const gpu = try ios.Window.create(gpa, app.window(), .{ .title = "zigulee test (Metal)", .renderer = .metal });
    for (0..5) |_| try gpu.step(10);
    try check(gpu.metal != null and gpu.pixel_width > 0, "Metal draws");
    gpu.destroy();
    try window.step(0);
    log.info("all passed", .{});
}

/// A touch UIKit would send: an object answering `locationInView:`.
fn fakeTouch(x: f64, y: f64) id {
    const Touch = struct {
        var cls: id = null;
        var at: objc.NSPoint = .{};
        fn location(_: id, _: objc.SEL, _: id) callconv(.c) objc.NSPoint {
            return at;
        }
    };
    if (Touch.cls == null) {
        Touch.cls = objc.objc_allocateClassPair(objc.objc_getClass("NSObject"), "ZiguleeTestTouch", 0);
        _ = objc.class_addMethod(Touch.cls, objc.sel("locationInView:"), @ptrCast(&Touch.location), "{CGPoint=dd}@:@");
        objc.objc_registerClassPair(Touch.cls);
    }
    Touch.at = .{ .x = x, .y = y };
    return msg(id, msg(id, msg(id, Touch.cls, "alloc", .{}), "init", .{}), "autorelease", .{});
}

fn tap(view: id, x: f64, y: f64) void {
    const touches = msg(id, class("NSSet"), "setWithObject:", .{fakeTouch(x, y)});
    msg(void, view, "touchesBegan:withEvent:", .{ touches, @as(id, null) });
    msg(void, view, "touchesEnded:withEvent:", .{ touches, @as(id, null) });
}

fn keyboardNotification(observer: id, name: [:0]const u8, frame: ?objc.NSRect) void {
    const info = msg(id, class("NSMutableDictionary"), "dictionary", .{});
    if (frame) |f| {
        const key = objc.nsString("UIKeyboardFrameEndUserInfoKey");
        msg(void, info, "setObject:forKey:", .{ msg(id, class("NSValue"), "valueWithCGRect:", .{f}), key });
    }
    const n = msg(id, class("NSNotification"), "notificationWithName:object:userInfo:", .{ objc.nsString(name), @as(id, null), info });
    msg(void, observer, "ziguleeKeyboard:", .{n});
}
