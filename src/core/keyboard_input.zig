// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! `KeyboardInput`: what an on-screen keyboard (`VirtualKeyboard` in the
//! standard widgets) needs: whether a text input can be typed into, and a
//! way to type into it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const item_mod = @import("item.zig");
const input = @import("input.zig");
const text_input = @import("text_input.zig");
const TextInput = text_input.TextInput;

pub const KeyboardInput = struct {
    item: item_mod.Item = .init(&vtable),
    /// A text input that can be edited has the keyboard focus.
    active: Property(bool) = .init(false),
    /// That input takes several lines (Return starts a new one).
    multi_line: Property(bool) = .init(false),
    /// That input is a password.
    password: Property(bool) = .init(false),

    pub fn init(self: *KeyboardInput, gpa: Allocator) void {
        self.* = .{};
        self.active.setBinding(gpa, self, isActive) catch {};
        self.multi_line.setBinding(gpa, self, isMultiLine) catch {};
        self.password.setBinding(gpa, self, isPassword) catch {};
    }

    pub fn deinit(self: *KeyboardInput) void {
        self.item.deinit();
        self.active.deinit();
        self.multi_line.deinit();
        self.password.deinit();
    }

    /// The input typed into, if it can be.
    fn target() ?*TextInput {
        const t = text_input.focused_input.get() orelse return null;
        if (!t.enabled.get() or t.read_only.get()) return null;
        return t;
    }

    fn isActive(_: *KeyboardInput) bool {
        return target() != null;
    }

    fn isMultiLine(_: *KeyboardInput) bool {
        const t = target() orelse return false;
        return !t.single_line.get();
    }

    fn isPassword(_: *KeyboardInput) bool {
        const t = target() orelse return false;
        return t.input_type.get() == .password;
    }

    /// Types `text` (a character, or a key such as `Key.Backspace`) into the
    /// focused text input, as a key pressed and released in its window.
    pub fn send(_: *KeyboardInput, text: []const u8) void {
        const t = target() orelse return;
        const w = t.item.window() orelse return;
        w.dispatchKey(.pressed, .{ .text = text });
        w.dispatchKey(.released, .{ .text = text });
    }

    /// Takes the focus away from the text input (the keyboard closes).
    pub fn dismiss(_: *KeyboardInput) void {
        const t = text_input.focused_input.get() orelse return;
        const w = t.item.window() orelse return;
        if (w.focus_item == &t.item) w.setFocusItem(null);
    }

    const vtable: item_mod.ItemVTable = .{ .name = "KeyboardInput" };
};

// ---- Tests ----

const testing = std.testing;
const Window = @import("window.zig").Window;

test "typing into the focused text input from an on-screen keyboard" {
    const gpa = testing.allocator;
    var field: TextInput = undefined;
    field.init(gpa);
    defer field.deinit();
    var window: Window = undefined;
    window.init(gpa, .{ .width = 200, .height = 100 });
    defer window.deinit();
    window.rootItem().appendChild(&field.item);
    var keys: KeyboardInput = undefined;
    keys.init(gpa);
    defer keys.deinit();

    try testing.expect(!keys.active.get());
    keys.send("x"); // nowhere to go
    field.focus();
    try testing.expect(keys.active.get());
    try testing.expect(!keys.multi_line.get());
    keys.send("h");
    keys.send("i");
    keys.send("!");
    keys.send(input.Key.backspace);
    try testing.expectEqualStrings("hi", field.text.get());

    field.read_only.set(true);
    try testing.expect(!keys.active.get());
    keys.send("x");
    try testing.expectEqualStrings("hi", field.text.get());
    field.read_only.set(false);
    field.single_line.set(false);
    try testing.expect(keys.multi_line.get());
    field.input_type.set(.password);
    try testing.expect(keys.password.get());

    keys.dismiss();
    try testing.expect(!keys.active.get());
    try testing.expect(window.focus_item == null);
}
