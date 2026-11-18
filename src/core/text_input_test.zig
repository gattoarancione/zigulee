// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Editing tests for `TextInput`. Without a font, metrics are approximate:
//! at font size 10 every character is 6px wide and lines are 12px tall.

const std = @import("std");
const testing = std.testing;
const core = @import("core.zig");
const items = core.items;
const Window = core.Window;
const Key = core.input.Key;
const Modifiers = core.input.Modifiers;

const gpa = testing.allocator;

const Fixture = struct {
    window: Window,
    field: items.TextInput,

    /// A 200x40 window filled by a field with font size 10.
    fn init(f: *Fixture, width: f32, height: f32) !void {
        f.window.init(gpa, .{ .width = width, .height = height });
        f.field.init(gpa);
        f.window.rootItem().appendChild(&f.field.item);
        try f.field.item.fillParent(gpa);
        f.field.font_size.set(10);
        f.window.setFocusItem(&f.field.item);
    }

    fn deinit(f: *Fixture) void {
        f.window.deinit();
        f.field.deinit();
    }

    fn key(f: *Fixture, text: []const u8, modifiers: Modifiers) void {
        f.window.dispatchKey(.pressed, .{ .text = text, .modifiers = modifiers });
    }

    fn typeText(f: *Fixture, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            f.key(text[i .. i + n], .{});
            i += n;
        }
    }

    fn expectSelection(f: *Fixture, anchor: usize, cursor: usize) !void {
        try testing.expectEqual(anchor, f.field.anchor());
        try testing.expectEqual(cursor, f.field.cursor());
    }

    fn press(f: *Fixture, x: f32, y: f32) void {
        f.window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
    }

    fn release(f: *Fixture, x: f32, y: f32) void {
        f.window.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
    }
};

const shift: Modifiers = .{ .shift = true };
const ctrl: Modifiers = .{ .control = true };
const ctrl_shift: Modifiers = .{ .control = true, .shift = true };

test "caret movement, selection and replacing it" {
    var f: Fixture = undefined;
    try f.init(200, 40);
    defer f.deinit();
    f.typeText("hello wörld");
    try testing.expectEqualStrings("hello wörld", f.field.text.get());
    try f.expectSelection(12, 12);

    f.key(Key.left_arrow, .{});
    f.key(Key.left_arrow, .{});
    f.key(Key.left_arrow, .{}); // before "r", after the two-byte "ö"
    try f.expectSelection(9, 9);
    f.key(Key.left_arrow, ctrl_shift); // select "wö"
    try f.expectSelection(9, 6);
    try testing.expectEqualStrings("wö", f.field.selectedText());
    f.typeText("X");
    try testing.expectEqualStrings("hello Xrld", f.field.text.get());
    try f.expectSelection(7, 7);

    // Left/Right without Shift collapse a selection to its side.
    f.key(Key.home, .{});
    f.key(Key.right_arrow, ctrl_shift);
    try f.expectSelection(0, 5);
    f.key(Key.right_arrow, .{});
    try f.expectSelection(5, 5);
    f.key(Key.end, shift);
    try testing.expectEqualStrings(" Xrld", f.field.selectedText());
    f.key(Key.backspace, .{});
    try testing.expectEqualStrings("hello", f.field.text.get());

    // Word deletion.
    f.typeText(" big world");
    f.key(Key.backspace, ctrl);
    try testing.expectEqualStrings("hello big ", f.field.text.get());
    f.key(Key.home, .{});
    f.key(Key.delete, ctrl);
    try testing.expectEqualStrings(" big ", f.field.text.get());
    f.key(Key.delete, .{});
    try testing.expectEqualStrings("big ", f.field.text.get());
}

test "undo and redo" {
    var f: Fixture = undefined;
    try f.init(200, 40);
    defer f.deinit();
    f.typeText("abc");
    f.key(Key.left_arrow, .{}); // moving seals the typing step
    f.typeText("X");
    try testing.expectEqualStrings("abXc", f.field.text.get());
    f.key("z", ctrl);
    try testing.expectEqualStrings("abc", f.field.text.get());
    try f.expectSelection(2, 2);
    f.key("z", ctrl); // "abc" was one step
    try testing.expectEqualStrings("", f.field.text.get());
    f.key("z", ctrl); // nothing left
    f.key("z", ctrl_shift);
    try testing.expectEqualStrings("abc", f.field.text.get());
    f.key("y", ctrl);
    try testing.expectEqualStrings("abXc", f.field.text.get());

    // Backspaces merge too; undo restores the selection before them.
    f.key(Key.end, .{});
    f.key(Key.backspace, .{});
    f.key(Key.backspace, .{});
    try testing.expectEqualStrings("ab", f.field.text.get());
    f.key("z", ctrl);
    try testing.expectEqualStrings("abXc", f.field.text.get());
    try f.expectSelection(4, 4);

    // Text set from code starts a new history.
    f.field.text.set("from code");
    f.key("z", ctrl);
    try testing.expectEqualStrings("from code", f.field.text.get());
}

test "clipboard: copy, cut, paste" {
    var f: Fixture = undefined;
    try f.init(200, 40);
    defer f.deinit();
    f.typeText("one two");
    f.key("a", ctrl);
    try f.expectSelection(0, 7);
    f.key("c", ctrl);
    f.key(Key.end, .{});
    f.key("v", ctrl);
    try testing.expectEqualStrings("one twoone two", f.field.text.get());
    f.key(Key.left_arrow, ctrl_shift);
    f.key("x", ctrl);
    try testing.expectEqualStrings("one twoone ", f.field.text.get());
    const clip = f.window.clipboardText(gpa).?;
    defer gpa.free(clip);
    try testing.expectEqualStrings("two", clip);
    f.key("z", ctrl);
    try testing.expectEqualStrings("one twoone two", f.field.text.get());

    // A single-line input pastes multi-line text on one line.
    f.window.setClipboardText("a\r\nb");
    f.key("a", ctrl);
    f.key("v", ctrl);
    try testing.expectEqualStrings("a b", f.field.text.get());
}

test "read-only inputs select and copy but do not change" {
    var f: Fixture = undefined;
    try f.init(200, 40);
    defer f.deinit();
    f.field.text.set("fixed");
    f.field.read_only.set(true);
    f.typeText("x");
    f.key(Key.backspace, .{});
    f.key("a", ctrl);
    f.key("x", ctrl);
    f.key("c", ctrl);
    try testing.expectEqualStrings("fixed", f.field.text.get());
    const clip = f.window.clipboardText(gpa).?;
    defer gpa.free(clip);
    try testing.expectEqualStrings("fixed", clip);
}

test "pointer: click, drag, double and triple click" {
    const t0 = core.now();
    var f: Fixture = undefined;
    try f.init(200, 40);
    defer f.deinit();
    f.field.text.set("abc def ghi");
    f.window.setFocusItem(null);

    // A click focuses and places the caret at the nearest boundary.
    f.press(13, 20);
    try testing.expect(f.field.has_focus.get());
    try f.expectSelection(2, 2);
    f.window.dispatchPointer(.{ .moved = .{ .position = .{ .x = 31, .y = 20 } } });
    f.release(31, 20);
    try f.expectSelection(2, 5);

    // Double click: a word; dragging extends by words.
    core.updateTimersAndAnimations(t0 + 1000);
    f.press(27, 20);
    f.release(27, 20);
    f.press(27, 20);
    try f.expectSelection(4, 7);
    f.window.dispatchPointer(.{ .moved = .{ .position = .{ .x = 50, .y = 20 } } });
    try f.expectSelection(4, 11);
    f.release(50, 20);

    // Triple click: everything (single-line).
    core.updateTimersAndAnimations(t0 + 2000);
    f.press(5, 20);
    f.release(5, 20);
    f.press(5, 20);
    f.release(5, 20);
    f.press(5, 20);
    f.release(5, 20);
    try f.expectSelection(0, 11);
    // Too slow for a double click.
    core.updateTimersAndAnimations(t0 + 3000);
    f.press(5, 20);
    try f.expectSelection(1, 1);
}

test "long text scrolls to keep the caret visible" {
    var f: Fixture = undefined;
    try f.init(60, 20);
    defer f.deinit();
    f.typeText("0123456789abcdef"); // 96px wide in a 60px field
    try testing.expect(f.field.scroll_x.get() > 36);
    f.key(Key.home, .{});
    try testing.expectEqual(@as(f32, 0), f.field.scroll_x.get());
    // Clicks account for the scrolling.
    f.key(Key.end, .{});
    const scrolled = f.field.scroll_x.get();
    f.press(1, 10);
    f.release(1, 10);
    try testing.expectEqual(@as(usize, @intFromFloat(@round((scrolled + 1) / 6))), f.field.cursor());
}

test "multi-line: newlines, up and down, wrapping, wheel" {
    var f: Fixture = undefined;
    try f.init(60, 30);
    defer f.deinit();
    f.field.single_line.set(false);
    var accepted: usize = 0;
    f.field.accepted.setHandler(&accepted, struct {
        fn count(n: *usize) void {
            n.* += 1;
        }
    }.count);
    f.typeText("abcd");
    f.key(Key.@"return", .{});
    f.typeText("e");
    f.key(Key.@"return", .{});
    f.typeText("fghi");
    try testing.expectEqualStrings("abcd\ne\nfghi", f.field.text.get());
    try testing.expectEqual(@as(usize, 0), accepted);

    // Up keeps the column across a short line.
    f.key(Key.up_arrow, .{});
    try f.expectSelection(6, 6); // end of "e"
    f.key(Key.up_arrow, .{});
    try f.expectSelection(4, 4); // back in column 4
    f.key(Key.down_arrow, shift);
    f.key(Key.down_arrow, shift);
    try f.expectSelection(4, 11);
    f.key(Key.home, .{});
    try f.expectSelection(7, 7);
    f.key(Key.end, ctrl_shift);
    try f.expectSelection(7, 11);

    // Three 12px lines in a 30px field: scrolled to show the caret.
    try testing.expectEqual(@as(f32, 6), f.field.scroll_y.get());
    f.window.dispatchPointer(.{ .wheel = .{ .position = .{ .x = 5, .y = 5 }, .delta = .{ .y = 40 } } });
    try testing.expectEqual(@as(f32, 0), f.field.scroll_y.get());

    // Unwrapped lines wider than the field scroll sideways: 72px + the
    // caret in 60px.
    f.field.text.set("abcdefghijkl");
    f.field.setSelection(0, 0);
    f.field.scroll_x.set(0);
    f.window.dispatchPointer(.{ .wheel = .{ .position = .{ .x = 5, .y = 5 }, .delta = .{ .x = -40 } } });
    try testing.expectEqual(@as(f32, 13.5), f.field.scroll_x.get());
    f.window.dispatchPointer(.{ .wheel = .{ .position = .{ .x = 5, .y = 5 }, .delta = .{ .x = 5 } } });
    try testing.expectEqual(@as(f32, 8.5), f.field.scroll_x.get());

    // Word wrap: "aaa bbb" in 30px wraps after the space.
    f.field.wrap.set(.word_wrap);
    f.field.item.width.set(30);
    f.field.text.set("aaa bbb");
    f.field.setSelection(0, 0);
    f.key(Key.down_arrow, .{});
    try f.expectSelection(4, 4);
    f.key(Key.end, .{});
    try f.expectSelection(7, 7);
    // The field is as tall as its wrapped text.
    try testing.expectEqual(@as(f32, 24), f.field.item.layoutInfo(.vertical).preferred);
}

test "aligned text: carets, clicks, up and down, and drawing agree" {
    var f: Fixture = undefined;
    try f.init(100, 40);
    defer f.deinit();
    // "abc", 18px, at the right: up to the caret's room (98.5).
    f.field.horizontal_alignment.set(.right);
    f.typeText("abc");
    var dl: core.rendering.DisplayList = .init(gpa, .{ .width = 100, .height = 40 });
    defer dl.deinit();
    _ = try f.window.render(dl.renderer(), .full);
    var drawn = false;
    for (dl.commands.items) |c| if (c == .text) {
        drawn = true;
        try testing.expectEqual(core.rendering.TextHorizontalAlignment.right, c.text.style.horizontal_alignment);
        try testing.expectApproxEqAbs(@as(f32, 98.5), c.text.rect.width, 1e-3);
        try testing.expectApproxEqAbs(@as(f32, 0), c.text.rect.x, 1e-3);
    };
    try testing.expect(drawn);
    // "b" from 86.5 to 92.5: a click past its middle is after it.
    f.press(90, 20);
    f.release(90, 20);
    try f.expectSelection(2, 2);
    f.press(85, 20);
    f.release(85, 20);
    try f.expectSelection(1, 1);

    // Multi-line, centered: up keeps the caret's place across lines.
    f.field.single_line.set(false);
    f.field.horizontal_alignment.set(.center);
    f.field.text.set("abcdef\nab");
    f.field.setSelection(10, 10); // after "ab" (from 43.25): at 55.25
    f.key(Key.up_arrow, .{});
    try f.expectSelection(4, 4); // "abcdef" from 31.25: after "abcd"

    // Wider than the field: aligned in the text, which scrolls.
    f.field.single_line.set(true);
    f.field.text.set("abcdefghijklmnopqrstuvwxyz");
    f.field.setSelection(0, 0);
    try testing.expectEqual(@as(usize, 0), f.field.cursor());
    f.press(1, 20);
    f.release(1, 20);
    try f.expectSelection(0, 0);
}

test "input method composition" {
    var f: Fixture = undefined;
    try f.init(200, 40);
    defer f.deinit();
    f.typeText("ab");
    f.key(Key.left_arrow, .{});
    f.window.dispatchPreedit("ka", 2);
    try testing.expectEqualStrings("ka", f.field.preedit.get());
    try testing.expectEqualStrings("ab", f.field.text.get()); // not committed yet
    // The window knows where the caret is, past the composition.
    try testing.expectEqual(@as(f32, 18), f.window.ime_cursor_rect.?.x);
    // Committing: the backend sends the text, then ends composing.
    f.typeText("か");
    f.window.dispatchPreedit("", 0);
    try testing.expectEqualStrings("aかb", f.field.text.get());
    try testing.expectEqualStrings("", f.field.preedit.get());
    f.window.setFocusItem(null);
    try testing.expectEqual(@as(?core.Rect, null), f.window.ime_cursor_rect);
}

test "password: bullets, positions, no copying, one word" {
    const t0 = core.now();
    var f: Fixture = undefined;
    try f.init(200, 40);
    defer f.deinit();
    f.field.input_type.set(.password);
    f.typeText("héllo"); // 6 bytes, 5 characters: 5 bullets of 6px
    try testing.expectEqualStrings("héllo", f.field.text.get());
    // Clicks map through the bullets: after the second character is byte 3.
    f.press(13, 20);
    f.release(13, 20);
    try f.expectSelection(3, 3);
    // Shift+click extends the selection.
    f.window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 25, .y = 20 }, .modifiers = .{ .shift = true } } });
    f.release(25, 20);
    try f.expectSelection(3, 5);
    // Nothing is copied or cut.
    f.window.setClipboardText("before");
    f.key("c", ctrl);
    f.key("x", ctrl);
    const clip = f.window.clipboardText(gpa).?;
    defer gpa.free(clip);
    try testing.expectEqualStrings("before", clip);
    try testing.expectEqualStrings("héllo", f.field.text.get());
    // Word moves and double clicks treat the password as one word.
    f.key(Key.end, .{});
    f.key(Key.left_arrow, ctrl);
    try f.expectSelection(0, 0);
    core.updateTimersAndAnimations(t0 + 2000);
    f.press(13, 20);
    f.release(13, 20);
    f.press(13, 20);
    f.release(13, 20);
    try f.expectSelection(0, 6);
    f.key(Key.backspace, ctrl);
    try testing.expectEqualStrings("", f.field.text.get());
}
