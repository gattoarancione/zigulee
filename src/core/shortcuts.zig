// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Application shortcuts (`Shortcut { sequence: "Ctrl+S"; activated =>
//! { ... } }`): keys that run something wherever the focus is, once the
//! focused element did not take them (Ctrl+C in a text field copies).
//!
//! A sequence is modifiers and a key joined by `+`: `Ctrl`, `Shift`,
//! `Alt`, `Meta` (`Cmd`), then a character (`S`, `1`, `/`, `Plus` for `+`)
//! or a key's name (`Escape`, `Return`, `Tab`, `Backspace`, `Delete`,
//! `Space`, `Up`, `Down`, `Left`, `Right`, `Home`, `End`, `PageUp`,
//! `PageDown`). As in the menus, `Ctrl` is Command on macOS (`MacCtrl` is
//! its Control key).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const Callback = @import("callbacks.zig").Callback;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const input = @import("input.zig");
const Key = input.Key;

/// The shortcuts made (application-wide).
var registered: std.ArrayList(*Shortcut) = .empty;
var registry_gpa: ?Allocator = null;

pub const Shortcut = struct {
    item: Item = .init(&vtable),
    sequence: Property([]const u8) = .init(""),
    enabled: Property(bool) = .init(true),
    activated: Callback(fn () void) = .{},

    /// Initialize in place.
    pub fn init(self: *Shortcut, gpa: Allocator) void {
        self.* = .{};
        registry_gpa = gpa;
        registered.append(gpa, self) catch {};
    }

    pub fn deinit(self: *Shortcut) void {
        for (registered.items, 0..) |s, i| if (s == self) {
            _ = registered.orderedRemove(i);
            break;
        };
        if (registered.items.len == 0) if (registry_gpa) |gpa| {
            registered.deinit(gpa);
            registered = .empty;
        };
        self.item.deinit();
        self.sequence.deinit();
        self.enabled.deinit();
    }

    const vtable: item_mod.ItemVTable = .{ .name = "Shortcut" };
};

/// A key the focused element did not take: runs the latest enabled
/// shortcut it matches. Whether one did.
pub fn handle(event: input.KeyEvent) bool {
    var i = registered.items.len;
    while (i > 0) {
        i -= 1;
        const s = registered.items[i];
        if (!s.enabled.getUntracked()) continue;
        if (!matches(s.sequence.getUntracked(), event)) continue;
        s.activated.call(.{});
        return true;
    }
    return false;
}

/// Whether `event` is the key sequence `sequence` ("Ctrl+Shift+Z").
pub fn matches(sequence: []const u8, event: input.KeyEvent) bool {
    if (sequence.len == 0 or event.text.len == 0) return false;
    var want: input.Modifiers = .{};
    var key: []const u8 = "";
    var it = std.mem.splitScalar(u8, sequence, '+');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        // "Ctrl++": the key is '+'.
        if (part.len == 0) {
            key = "+";
            continue;
        }
        if (eqlNoCase(part, "Ctrl") or eqlNoCase(part, "Control")) {
            if (builtin.os.tag == .macos) want.meta = true else want.control = true;
        } else if (eqlNoCase(part, "MacCtrl")) {
            want.control = true;
        } else if (eqlNoCase(part, "Shift")) {
            want.shift = true;
        } else if (eqlNoCase(part, "Alt") or eqlNoCase(part, "Option")) {
            want.alt = true;
        } else if (eqlNoCase(part, "Meta") or eqlNoCase(part, "Cmd") or eqlNoCase(part, "Command") or eqlNoCase(part, "Super")) {
            want.meta = true;
        } else key = keyNamed(part) orelse return false;
    }
    if (key.len == 0) return false;
    const m = event.modifiers;
    if (m.control != want.control or m.alt != want.alt or m.meta != want.meta) return false;
    // Letters: the same with Shift as without (but Shift itself must match).
    if (key.len == 1 and std.ascii.isAlphabetic(key[0])) {
        return m.shift == want.shift and event.text.len == 1 and std.ascii.toLower(event.text[0]) == std.ascii.toLower(key[0]);
    }
    // Other characters may need Shift to type: only the named ones are
    // checked for it.
    if (std.mem.eql(u8, event.text, key)) return !want.shift or m.shift;
    return false;
}

fn eqlNoCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// A key's text, by its name or itself.
fn keyNamed(name: []const u8) ?[]const u8 {
    const names = .{
        .{ "Escape", Key.escape },      .{ "Esc", Key.escape },
        .{ "Return", Key.@"return" },   .{ "Enter", Key.@"return" },
        .{ "Tab", Key.tab },            .{ "Backspace", Key.backspace },
        .{ "Delete", Key.delete },      .{ "Del", Key.delete },
        .{ "Space", Key.space },        .{ "Up", Key.up_arrow },
        .{ "Down", Key.down_arrow },    .{ "Left", Key.left_arrow },
        .{ "Right", Key.right_arrow },  .{ "Home", Key.home },
        .{ "End", Key.end },            .{ "PageUp", Key.page_up },
        .{ "PageDown", Key.page_down }, .{ "Plus", "+" },
        .{ "Minus", "-" },
    };
    inline for (names) |n| if (eqlNoCase(name, n[0])) return n[1];
    // A single character (or code point).
    if (std.unicode.utf8ByteSequenceLength(name[0])) |len| {
        if (len == name.len) return name;
    } else |_| {}
    return null;
}

// ---- Tests ----

const testing = std.testing;
const core = @import("core.zig");

fn press(text: []const u8, m: input.Modifiers) input.KeyEvent {
    return .{ .text = text, .modifiers = m };
}

test "key sequences" {
    const primary: input.Modifiers = if (builtin.os.tag == .macos) .{ .meta = true } else .{ .control = true };
    var shifted = primary;
    shifted.shift = true;
    try testing.expect(matches("Ctrl+S", press("s", primary)));
    try testing.expect(matches("ctrl+s", press("s", primary)));
    try testing.expect(!matches("Ctrl+S", press("s", .{})));
    try testing.expect(!matches("Ctrl+S", press("s", shifted)));
    try testing.expect(matches("Ctrl+Shift+Z", press("Z", shifted)));
    try testing.expect(matches("Ctrl+Plus", press("+", primary)));
    try testing.expect(matches("Ctrl++", press("+", primary)));
    try testing.expect(matches("Escape", press(Key.escape, .{})));
    try testing.expect(matches("Alt+Left", press(Key.left_arrow, .{ .alt = true })));
    try testing.expect(!matches("Alt+Left", press(Key.left_arrow, .{})));
    try testing.expect(matches("Meta+Q", press("q", .{ .meta = true })));
    try testing.expect(!matches("Ctrl+Nope", press("n", primary)));
    try testing.expect(!matches("", press("s", primary)));
}

test "shortcuts run when the focused element does not take the key" {
    var w: core.Window = undefined;
    w.init(testing.allocator, .{ .width = 100, .height = 40 });
    defer w.deinit();
    var field: core.items.TextInput = undefined;
    field.init(testing.allocator);
    defer field.deinit();
    w.rootItem().appendChild(&field.item);
    field.item.setGeometry(.{ .width = 100, .height = 40 });
    var save: Shortcut = undefined;
    save.init(testing.allocator);
    defer save.deinit();
    var copy: Shortcut = undefined;
    copy.init(testing.allocator);
    defer copy.deinit();
    save.sequence.set("Ctrl+S");
    copy.sequence.set("Ctrl+C");
    var saves: usize = 0;
    var copies: usize = 0;
    const count = struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f;
    save.activated.setHandler(&saves, count);
    copy.activated.setHandler(&copies, count);
    const primary: input.Modifiers = if (builtin.os.tag == .macos) .{ .meta = true } else .{ .control = true };

    // Nothing focused: both run.
    w.dispatchKey(.pressed, press("s", primary));
    w.dispatchKey(.pressed, press("c", primary));
    try testing.expectEqual(@as(usize, 1), saves);
    try testing.expectEqual(@as(usize, 1), copies);
    // In a text field: Ctrl+C copies there; Ctrl+S is still the app's.
    w.setFocusItem(&field.item);
    w.dispatchKey(.pressed, press("c", primary));
    w.dispatchKey(.pressed, press("s", primary));
    try testing.expectEqual(@as(usize, 2), saves);
    try testing.expectEqual(@as(usize, 1), copies);
    // Disabled: not run.
    save.enabled.set(false);
    w.dispatchKey(.pressed, press("s", primary));
    try testing.expectEqual(@as(usize, 2), saves);
}
