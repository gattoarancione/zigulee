// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Integration tests: items in a window, laid out, receiving input and
//! rendering with dirty-region tracking.

const std = @import("std");
const testing = std.testing;
const core = @import("core.zig");
const items = core.items;
const Window = core.Window;
const Rect = core.Rect;
const Color = core.Color;
const Key = core.input.Key;
const DisplayList = core.rendering.DisplayList;

const gpa = testing.allocator;

fn expectRect(expected: Rect, item: *core.Item) !void {
    const g = item.geometry();
    try testing.expectApproxEqAbs(expected.x, g.x, 1e-3);
    try testing.expectApproxEqAbs(expected.y, g.y, 1e-3);
    try testing.expectApproxEqAbs(expected.width, g.width, 1e-3);
    try testing.expectApproxEqAbs(expected.height, g.height, 1e-3);
}

/// Window
/// └ VerticalLayout (padding 10, spacing 5)
///   ├ Text "Title"            (font 10: 30 x 12)
///   ├ HorizontalLayout (spacing 10)
///   │ ├ Rectangle "left"      (max width 50)
///   │ └ Rectangle "right"
///   └ Rectangle "footer"      (fixed height 20)
const Ui = struct {
    window: Window = undefined,
    column: items.BoxLayout = .vertical(),
    title: items.Text = .{},
    row: items.BoxLayout = .horizontal(),
    left: items.Rectangle = .{},
    left_constraints: core.LayoutConstraints = .{},
    right: items.Rectangle = .{},
    footer: items.Rectangle = .{},
    footer_constraints: core.LayoutConstraints = .{},

    fn create() !*Ui {
        const ui = try gpa.create(Ui);
        ui.* = .{};
        ui.window.init(gpa, .{ .width = 200, .height = 100 });
        ui.title.text.set("Title");
        ui.title.font_size.set(10);
        ui.left.background.set(.color(.rgb(0xff0000)));
        ui.left.item.constraints = &ui.left_constraints;
        ui.left_constraints.max_width.set(50);
        ui.right.background.set(.color(.rgb(0x00ff00)));
        ui.footer.item.constraints = &ui.footer_constraints;
        ui.footer_constraints.min_height.set(20);
        ui.footer_constraints.max_height.set(20);

        ui.window.rootItem().appendChild(&ui.column.item);
        ui.column.item.appendChildren(&.{ &ui.title.item, &ui.row.item, &ui.footer.item });
        ui.row.item.appendChildren(&.{ &ui.left.item, &ui.right.item });
        ui.column.setPadding(10);
        ui.column.spacing.set(5);
        ui.row.spacing.set(10);
        try ui.row.setup(gpa);
        try ui.column.setup(gpa);
        try ui.column.item.fillParent(gpa);
        return ui;
    }

    fn destroy(ui: *Ui) void {
        ui.window.deinit();
        ui.footer.deinit();
        ui.footer_constraints.deinit();
        ui.right.deinit();
        ui.left.deinit();
        ui.left_constraints.deinit();
        ui.row.deinit();
        ui.title.deinit();
        ui.column.deinit();
        gpa.destroy(ui);
    }
};

test "nested box layouts follow the window size" {
    const ui = try Ui.create();
    defer ui.destroy();

    // Height 100 - 20 padding - 10 spacing = 70: title 12, footer 20, row 38.
    try expectRect(.{ .x = 10, .y = 10, .width = 180, .height = 12 }, &ui.title.item);
    try expectRect(.{ .x = 10, .y = 27, .width = 180, .height = 38 }, &ui.row.item);
    try expectRect(.{ .x = 10, .y = 70, .width = 180, .height = 20 }, &ui.footer.item);
    try expectRect(.{ .x = 0, .y = 0, .width = 50, .height = 38 }, &ui.left.item);
    try expectRect(.{ .x = 60, .y = 0, .width = 120, .height = 38 }, &ui.right.item);
    try testing.expectEqual(core.Rect{ .x = 70, .y = 27, .width = 120, .height = 38 }, ui.right.item.absoluteGeometry());

    ui.window.setSize(.{ .width = 300, .height = 200 });
    try expectRect(.{ .x = 60, .y = 0, .width = 220, .height = 138 }, &ui.right.item);
    try expectRect(.{ .x = 10, .y = 170, .width = 280, .height = 20 }, &ui.footer.item);

    // Constraint changes propagate through both layouts.
    ui.title.font_size.set(20); // 24 tall
    try expectRect(.{ .x = 10, .y = 39, .width = 280, .height = 126 }, &ui.row.item);
}

test "layout constraints bubble up to the window content" {
    const ui = try Ui.create();
    defer ui.destroy();
    const h = ui.column.item.layoutInfo(.horizontal);
    // Title needs 30 wide; row needs 0 + 10 spacing; plus 20 padding.
    try testing.expectEqual(@as(f32, 50), h.min);
    const v = ui.column.item.layoutInfo(.vertical);
    try testing.expectEqual(@as(f32, 12 + 0 + 20 + 10 + 20), v.min);
    // The window root reports the merged constraints of its child layout.
    try testing.expectEqual(h.min, ui.window.rootItem().layoutInfo(.horizontal).min);
}

test "grid layout places cells with spans" {
    var window: Window = undefined;
    window.init(gpa, .{ .width = 210, .height = 100 });
    var grid: items.GridLayout = .{};
    var a: items.Rectangle = .{};
    var b: items.Rectangle = .{};
    var c: items.Rectangle = .{};
    defer {
        window.deinit();
        a.deinit();
        b.deinit();
        c.deinit();
        grid.deinit();
    }
    window.rootItem().appendChild(&grid.item);
    grid.item.appendChildren(&.{ &a.item, &b.item, &c.item });
    grid.spacing.set(10);
    try grid.setup(gpa, &.{ .{ .row = 0, .col = 0 }, .{ .row = 0, .col = 1 }, .{ .row = 1, .col = 0, .colspan = 2 } });
    try grid.item.fillParent(gpa);

    try expectRect(.{ .x = 0, .y = 0, .width = 100, .height = 45 }, &a.item);
    try expectRect(.{ .x = 110, .y = 0, .width = 100, .height = 45 }, &b.item);
    try expectRect(.{ .x = 0, .y = 55, .width = 210, .height = 45 }, &c.item);
}

/// A clickable button: Rectangle > TouchArea, plus a FocusScope.
const Buttons = struct {
    window: Window = undefined,
    back: items.Rectangle = .{},
    front: items.Rectangle = .{},
    back_touch: items.TouchArea = .{},
    front_touch: items.TouchArea = .{},
    clips: items.Rectangle = .{},
    hidden_touch: items.TouchArea = .{},
    back_clicks: usize = 0,
    front_clicks: usize = 0,
    hidden_clicks: usize = 0,

    fn create() !*Buttons {
        const s = try gpa.create(Buttons);
        s.* = .{};
        s.window.init(gpa, .{ .width = 200, .height = 200 });
        const root = s.window.rootItem();
        // back: (0,0 100x100); front overlaps it at (50,50 100x100).
        root.appendChildren(&.{ &s.back.item, &s.front.item, &s.clips.item });
        s.back.item.setGeometry(.{ .width = 100, .height = 100 });
        s.front.item.setGeometry(.{ .x = 50, .y = 50, .width = 100, .height = 100 });
        s.back.item.appendChild(&s.back_touch.item);
        s.front.item.appendChild(&s.front_touch.item);
        try s.back_touch.item.fillParent(gpa);
        try s.front_touch.item.fillParent(gpa);
        // A clipping rect at (150,0 20x20) with a child sticking out of it.
        s.clips.item.setGeometry(.{ .x = 150, .y = 0, .width = 20, .height = 20 });
        s.clips.clip.set(true);
        s.clips.item.appendChild(&s.hidden_touch.item);
        s.hidden_touch.item.setGeometry(.{ .x = 0, .y = 0, .width = 50, .height = 50 });

        s.back_touch.clicked.setHandler(s, struct {
            fn f(b: *Buttons) void {
                b.back_clicks += 1;
            }
        }.f);
        s.front_touch.clicked.setHandler(s, struct {
            fn f(b: *Buttons) void {
                b.front_clicks += 1;
            }
        }.f);
        s.hidden_touch.clicked.setHandler(s, struct {
            fn f(b: *Buttons) void {
                b.hidden_clicks += 1;
            }
        }.f);
        return s;
    }

    fn destroy(s: *Buttons) void {
        s.window.deinit();
        s.hidden_touch.deinit();
        s.clips.deinit();
        s.front_touch.deinit();
        s.back_touch.deinit();
        s.front.deinit();
        s.back.deinit();
        gpa.destroy(s);
    }

    fn click(s: *Buttons, x: f32, y: f32) void {
        s.window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
        s.window.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
    }
};

test "clicks go to the topmost touch area" {
    const s = try Buttons.create();
    defer s.destroy();
    s.click(75, 75); // overlap: front wins
    s.click(25, 25);
    s.click(190, 190); // nothing there
    try testing.expectEqual(@as(usize, 1), s.front_clicks);
    try testing.expectEqual(@as(usize, 1), s.back_clicks);
}

test "press grabs the pointer; releasing outside does not click" {
    const s = try Buttons.create();
    defer s.destroy();
    s.window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 10, .y = 10 } } });
    try testing.expect(s.back_touch.pressed.get());
    s.window.dispatchPointer(.{ .moved = .{ .position = .{ .x = 190, .y = 190 } } });
    try testing.expect(s.back_touch.pressed.get()); // still grabbed
    try testing.expect(!s.back_touch.has_hover.get());
    try testing.expectEqual(@as(f32, 190), s.back_touch.mouse_x.get());
    s.window.dispatchPointer(.{ .released = .{ .position = .{ .x = 190, .y = 190 } } });
    try testing.expect(!s.back_touch.pressed.get());
    try testing.expectEqual(@as(usize, 0), s.back_clicks);
    try testing.expectEqual(@as(?*core.Item, null), s.window.grabber);
}

test "hover enters and exits" {
    const s = try Buttons.create();
    defer s.destroy();
    s.window.dispatchPointer(.{ .moved = .{ .position = .{ .x = 10, .y = 10 } } });
    try testing.expect(s.back_touch.has_hover.get());
    s.window.dispatchPointer(.{ .moved = .{ .position = .{ .x = 75, .y = 75 } } });
    try testing.expect(!s.back_touch.has_hover.get()); // covered by front
    try testing.expect(s.front_touch.has_hover.get());
    s.window.dispatchPointer(.exit);
    try testing.expect(!s.front_touch.has_hover.get());
}

test "clipping parents block input outside their bounds" {
    const s = try Buttons.create();
    defer s.destroy();
    s.click(160, 10); // inside the clip
    s.click(160, 40); // inside the child, outside the clip
    try testing.expectEqual(@as(usize, 1), s.hidden_clicks);
}

test "removing a grabbing item releases the grab" {
    const s = try Buttons.create();
    defer s.destroy();
    s.window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 10, .y = 10 } } });
    try testing.expectEqual(&s.back_touch.item, s.window.grabber.?);
    s.back.item.removeFromParent();
    try testing.expectEqual(@as(?*core.Item, null), s.window.grabber);
    s.window.dispatchPointer(.{ .released = .{ .position = .{ .x = 10, .y = 10 } } });
    try testing.expectEqual(@as(usize, 0), s.back_clicks);
}

const Form = struct {
    window: Window = undefined,
    first: items.FocusScope = .{},
    second: items.FocusScope = .{},
    disabled: items.FocusScope = .{},
    inner: items.FocusScope = .{},
    typed: [8]u8 = undefined,
    typed_len: usize = 0,
    escapes: usize = 0,

    fn create() !*Form {
        const f = try gpa.create(Form);
        f.* = .{};
        f.window.init(gpa, .{ .width = 100, .height = 100 });
        // first, second (containing inner), disabled
        f.window.rootItem().appendChildren(&.{ &f.first.item, &f.second.item, &f.disabled.item });
        f.second.item.appendChild(&f.inner.item);
        f.disabled.item.enabled.set(false);
        f.first.item.setGeometry(.{ .width = 50, .height = 50 });
        // `inner` handles letters; `second` handles Escape bubbling up from it.
        f.inner.key_pressed.setHandler(f, struct {
            fn h(form: *Form, e: core.input.KeyEvent) core.input.EventResult {
                if (e.text.len != 1 or !std.ascii.isAlphabetic(e.text[0])) return .reject;
                form.typed[form.typed_len] = e.text[0];
                form.typed_len += 1;
                return .accept;
            }
        }.h);
        f.second.key_pressed.setHandler(f, struct {
            fn h(form: *Form, e: core.input.KeyEvent) core.input.EventResult {
                if (!std.mem.eql(u8, e.text, Key.escape)) return .reject;
                form.escapes += 1;
                return .accept;
            }
        }.h);
        return f;
    }

    fn destroy(f: *Form) void {
        f.window.deinit();
        f.inner.deinit();
        f.disabled.deinit();
        f.second.deinit();
        f.first.deinit();
        gpa.destroy(f);
    }

    fn press(f: *Form, text: []const u8, shift: bool) void {
        f.window.dispatchKey(.pressed, .{ .text = text, .modifiers = .{ .shift = shift } });
    }
};

test "tab navigation skips disabled scopes and wraps" {
    const f = try Form.create();
    defer f.destroy();
    f.press(Key.tab, false);
    try testing.expect(f.first.has_focus.get());
    f.press(Key.tab, false);
    try testing.expect(f.second.has_focus.get());
    try testing.expect(!f.first.has_focus.get());
    f.press(Key.tab, false);
    try testing.expect(f.inner.has_focus.get());
    f.press(Key.tab, false); // disabled is skipped
    try testing.expect(f.first.has_focus.get());
    f.press(Key.tab, true); // shift+tab wraps backwards
    try testing.expect(f.inner.has_focus.get());
}

test "key events bubble from the focused item to its ancestors" {
    const f = try Form.create();
    defer f.destroy();
    f.inner.focus();
    f.press("a", false);
    f.press(Key.escape, false); // rejected by inner, accepted by second
    f.press("1", false); // rejected by both
    f.press("b", false);
    try testing.expectEqualStrings("ab", f.typed[0..f.typed_len]);
    try testing.expectEqual(@as(usize, 1), f.escapes);
}

test "clicking a focus scope focuses it" {
    const f = try Form.create();
    defer f.destroy();
    f.window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 10, .y = 10 } } });
    try testing.expectEqual(&f.first.item, f.window.focus_item.?);
}

test "partial rendering redraws an image whose pixels changed (a new version)" {
    var window: Window = undefined;
    window.init(gpa, .{ .width = 40, .height = 30 });
    defer window.deinit();
    var img: items.Image = .{};
    defer img.deinit();
    window.rootItem().appendChild(&img.item);
    img.item.setGeometry(.{ .x = 10, .y = 5, .width = 20, .height = 10 });
    var pixels: [2]core.Rgba8 = @splat(.{ .r = 255, .g = 0, .b = 0, .a = 255 });
    img.source.set(.{ .width = 2, .height = 1, .pixels = &pixels });
    var dl: DisplayList = .init(gpa, .{ .width = 40, .height = 30 });
    defer dl.deinit();
    _ = try window.render(dl.renderer(), .partial);

    // The same pixels, changed in place: a video's next frame.
    pixels[0] = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    img.source.set(.{ .width = 2, .height = 1, .pixels = &pixels, .version = 1 });
    dl.reset(.{ .width = 40, .height = 30 });
    const region = try window.render(dl.renderer(), .partial);
    try testing.expectEqual(Rect{ .x = 10, .y = 5, .width = 20, .height = 10 }, region.boundingBox());
}

test "partial rendering redraws only what changed" {
    const ui = try Ui.create();
    defer ui.destroy();
    var dl: DisplayList = .init(gpa, .{ .width = 200, .height = 100 });
    defer dl.deinit();

    var redraws: usize = 0;
    ui.window.on_redraw_request.setHandler(&redraws, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);

    // First frame: everything.
    var region = try ui.window.render(dl.renderer(), .partial);
    try testing.expectEqual(Rect{ .width = 200, .height = 100 }, region.boundingBox());
    // window background, title, left, right (footer is transparent)
    try testing.expectEqual(@as(usize, 4), dl.commands.items.len);
    try testing.expect(!ui.window.redraw_requested);

    // Nothing changed: nothing to draw.
    dl.reset(.{ .width = 200, .height = 100 });
    region = try ui.window.render(dl.renderer(), .partial);
    try testing.expect(region.isEmpty());
    try testing.expectEqual(@as(usize, 0), dl.commands.items.len);

    // A color change repaints exactly that rectangle.
    ui.right.background.set(.color(.rgb(0x0000ff)));
    try testing.expect(ui.window.redraw_requested);
    try testing.expectEqual(@as(usize, 1), redraws);
    dl.reset(.{ .width = 200, .height = 100 });
    region = try ui.window.render(dl.renderer(), .partial);
    try testing.expectEqual(@as(usize, 1), region.len);
    try testing.expectEqual(Rect{ .x = 70, .y = 27, .width = 120, .height = 38 }, region.rects[0]);
    // The window background and the changed rectangle intersect the region.
    try testing.expectEqual(@as(usize, 2), dl.commands.items.len);
    try testing.expectEqual(Color.rgb(0x0000ff), dl.commands.items[1].rectangle.style.background.solid);
}

test "moving and removing items dirties old and new bounds" {
    const s = try Buttons.create();
    defer s.destroy();
    s.back.background.set(.color(.black));
    var dl: DisplayList = .init(gpa, .{ .width = 200, .height = 200 });
    defer dl.deinit();
    _ = try s.window.render(dl.renderer(), .partial);

    s.back.item.x.set(10);
    var region = try s.window.render(dl.renderer(), .partial);
    // The rectangle and its touch area both moved: old (0..100) + new (10..110).
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 110, .height = 100 }, region.boundingBox());

    s.front.background.set(.color(.white));
    _ = try s.window.render(dl.renderer(), .partial);
    s.front.item.removeFromParent();
    region = try s.window.render(dl.renderer(), .partial);
    try testing.expectEqual(Rect{ .x = 50, .y = 50, .width = 100, .height = 100 }, region.boundingBox());

    // Full mode repaints everything regardless.
    region = try s.window.render(dl.renderer(), .full);
    try testing.expectEqual(Rect{ .width = 200, .height = 200 }, region.boundingBox());
}

test "animated property drives partial redraws" {
    const t0 = core.now();
    const s = try Buttons.create();
    defer s.destroy();
    s.back.background.set(.color(.black));
    var dl: DisplayList = .init(gpa, .{ .width = 200, .height = 200 });
    defer dl.deinit();
    _ = try s.window.render(dl.renderer(), .partial);

    try s.back.item.x.setAnimated(gpa, 40, .{ .duration_ms = 100 });
    core.updateTimersAndAnimations(t0 + 50);
    var region = try s.window.render(dl.renderer(), .partial);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 120, .height = 100 }, region.boundingBox());
    try testing.expect(core.hasActiveAnimations());

    core.updateTimersAndAnimations(t0 + 100);
    region = try s.window.render(dl.renderer(), .partial);
    try testing.expectEqual(Rect{ .x = 20, .y = 0, .width = 120, .height = 100 }, region.boundingBox());
    try testing.expect(!core.hasActiveAnimations());
}

test "invisible items are not drawn, hit or focused" {
    const s = try Buttons.create();
    defer s.destroy();
    s.front.background.set(.color(.black));
    s.front.item.visible.set(false);
    s.click(75, 75); // front is hidden: back gets it
    try testing.expectEqual(@as(usize, 0), s.front_clicks);
    try testing.expectEqual(@as(usize, 1), s.back_clicks);

    var dl: DisplayList = .init(gpa, .{ .width = 200, .height = 200 });
    defer dl.deinit();
    _ = try s.window.render(dl.renderer(), .full);
    for (dl.commands.items) |c| try testing.expect(!c.rectangle.style.background.eql(.color(.black)));

    var scope: items.FocusScope = .{};
    defer scope.deinit();
    s.front.item.appendChild(&scope.item);
    s.window.dispatchKey(.pressed, .{ .text = Key.tab });
    try testing.expectEqual(@as(?*core.Item, null), s.window.focus_item);
    s.front.item.visible.set(true);
    s.window.dispatchKey(.pressed, .{ .text = Key.tab });
    try testing.expectEqual(&scope.item, s.window.focus_item.?);
}

test "opacity: an element with children fades with them as one layer" {
    const s = try Buttons.create();
    defer s.destroy();
    var inner: items.Rectangle = .{};
    defer inner.deinit();
    s.front.item.appendChild(&inner.item);
    inner.item.setGeometry(.{ .width = 10, .height = 10 });
    inner.background.set(.color(.white));
    inner.item.opacity.set(0.5);
    s.front.item.opacity.set(0.5);
    s.front.background.set(.color(.black));

    var dl: DisplayList = .init(gpa, .{ .width = 200, .height = 200 });
    defer dl.deinit();
    _ = try s.window.render(dl.renderer(), .full);
    const cmds = dl.commands.items;
    // The front one, with its child: a layer, faded as a whole.
    const layer = cmds[cmds.len - 4].layer;
    try testing.expectEqual(@as(f32, 0.5), layer.opacity);
    try testing.expectEqual(@as(u32, 2), layer.style.count);
    try testing.expectEqual(@as(f32, 1), cmds[cmds.len - 3].rectangle.opacity); // front
    // Its child has no children: faded as it is drawn.
    try testing.expectEqual(@as(f32, 0.5), cmds[cmds.len - 2].rectangle.opacity);
    try testing.expect(cmds[cmds.len - 1] == .end_layer);
}

test "visibility, opacity and clip changes repaint children outside the parent" {
    const s = try Buttons.create();
    defer s.destroy();
    // `clips` is 20x20 at (150,0); give it a visible 50x50 child that
    // sticks out of it.
    var spill: items.Rectangle = .{};
    defer spill.deinit();
    spill.background.set(.color(.black));
    spill.item.setGeometry(.{ .width = 50, .height = 50 });
    s.clips.item.appendChild(&spill.item);
    var dl: DisplayList = .init(gpa, .{ .width = 200, .height = 200 });
    defer dl.deinit();
    _ = try s.window.render(dl.renderer(), .partial);

    s.clips.clip.set(false);
    var region = try s.window.render(dl.renderer(), .partial);
    try testing.expectEqual(Rect{ .x = 150, .y = 0, .width = 50, .height = 50 }, region.boundingBox());

    s.clips.item.visible.set(false);
    region = try s.window.render(dl.renderer(), .partial);
    try testing.expectEqual(Rect{ .x = 150, .y = 0, .width = 50, .height = 50 }, region.boundingBox());

    s.clips.item.visible.set(true);
    s.clips.item.opacity.set(0.3);
    region = try s.window.render(dl.renderer(), .partial);
    try testing.expectEqual(Rect{ .x = 150, .y = 0, .width = 50, .height = 50 }, region.boundingBox());
}

test "accessibility of built-in items" {
    var text: items.Text = .{};
    defer text.deinit();
    text.text.set("Hello");
    try testing.expectEqual(core.AccessibleRole.text, text.item.accessibleRole());
    try testing.expectEqualStrings("Hello", text.item.accessibleLabel());
}

/// A 100x100 flickable over 100x300 content with a touch area filling it.
const Scroller = struct {
    window: Window = undefined,
    flick: items.Flickable = undefined,
    touch: items.TouchArea = .{},
    clicks: usize = 0,

    fn create() !*Scroller {
        const s = try gpa.create(Scroller);
        s.* = .{};
        s.window.init(gpa, .{ .width = 100, .height = 100 });
        s.flick.init(gpa);
        s.window.rootItem().appendChild(&s.flick.item);
        try s.flick.item.fillParent(gpa);
        s.flick.content().width.set(100);
        s.flick.content().height.set(300);
        s.flick.content().appendChild(&s.touch.item);
        try s.touch.item.fillParent(gpa);
        s.touch.clicked.setHandler(s, struct {
            fn f(sc: *Scroller) void {
                sc.clicks += 1;
            }
        }.f);
        return s;
    }

    fn destroy(s: *Scroller) void {
        s.window.deinit();
        s.touch.deinit();
        s.flick.deinit();
        gpa.destroy(s);
    }

    fn at(x: f32, y: f32) core.Point {
        return .{ .x = x, .y = y };
    }
};

test "flickable: a tap still clicks the content" {
    const s = try Scroller.create();
    defer s.destroy();
    s.window.dispatchPointer(.{ .pressed = .{ .position = Scroller.at(50, 50) } });
    s.window.dispatchPointer(.{ .moved = .{ .position = Scroller.at(52, 53) } }); // below threshold
    s.window.dispatchPointer(.{ .released = .{ .position = Scroller.at(52, 53) } });
    try testing.expectEqual(@as(usize, 1), s.clicks);
    try testing.expectEqual(core.Point{}, s.flick.viewportPosition());
}

test "flickable: dragging steals the press from the content and scrolls" {
    const t0 = core.now();
    const s = try Scroller.create();
    defer s.destroy();
    s.window.dispatchPointer(.{ .pressed = .{ .position = Scroller.at(50, 80) } });
    try testing.expect(s.touch.pressed.get());
    s.window.dispatchPointer(.{ .moved = .{ .position = Scroller.at(50, 50) } });
    try testing.expect(!s.touch.pressed.get()); // got `exit`
    try testing.expectEqual(&s.flick.item, s.window.grabber.?);
    try testing.expectEqual(core.Point{ .x = 0, .y = -30 }, s.flick.viewportPosition());
    // 380 px past the end (-200): pulled less and less, under the view's
    // 100 px (1 - 1 / (380 * 0.55 / 100 + 1) of them).
    s.window.dispatchPointer(.{ .moved = .{ .position = Scroller.at(50, -500) } });
    try testing.expectApproxEqAbs(@as(f32, -267.6), s.flick.viewportPosition().y, 0.1);
    core.updateTimersAndAnimations(t0 + 200);
    s.window.dispatchPointer(.{ .released = .{ .position = Scroller.at(50, -500) } });
    try testing.expectEqual(@as(usize, 0), s.clicks);
    try testing.expectEqual(@as(?*core.Item, null), s.window.grabber);
    // Let go: back to the end.
    core.updateTimersAndAnimations(t0 + 200 + items.Flickable.flick_duration_ms);
    try testing.expectEqual(core.Point{ .x = 0, .y = -200 }, s.flick.viewportPosition());

    // The content moved with the viewport: hit-testing follows it.
    try testing.expectEqual(@as(f32, -200), s.touch.item.absolutePosition().y);

    // Without overscroll: held at the end.
    s.flick.overscroll.set(false);
    s.window.dispatchPointer(.{ .pressed = .{ .position = Scroller.at(50, 80) } });
    s.window.dispatchPointer(.{ .moved = .{ .position = Scroller.at(50, 0) } });
    try testing.expectEqual(core.Point{ .x = 0, .y = -200 }, s.flick.viewportPosition());
    s.window.dispatchPointer(.{ .released = .{ .position = Scroller.at(50, 0) } });
}

test "the window sees every pointer event and input, a flickable's grabbed drag too" {
    const s = try Scroller.create();
    defer s.destroy();
    const Watch = struct {
        presses: usize = 0,
        moves: usize = 0,
        releases: usize = 0,
        activity: usize = 0,
        fn observed(w: *@This(), e: core.input.PointerEvent) void {
            switch (e) {
                .pressed => w.presses += 1,
                .moved => w.moves += 1,
                .released => w.releases += 1,
                else => {},
            }
        }
        fn active(w: *@This()) void {
            w.activity += 1;
        }
    };
    var watch: Watch = .{};
    s.window.pointer_observed.setHandler(&watch, Watch.observed);
    s.window.input_activity.setHandler(&watch, Watch.active);
    s.window.dispatchPointer(.{ .pressed = .{ .position = Scroller.at(50, 80) } });
    s.window.dispatchPointer(.{ .moved = .{ .position = Scroller.at(50, 50) } });
    s.window.dispatchPointer(.{ .moved = .{ .position = Scroller.at(50, 20) } });
    s.window.dispatchPointer(.{ .released = .{ .position = Scroller.at(50, 20) } });
    // Seen, and the flickable still scrolled.
    try testing.expectEqual(Watch{ .presses = 1, .moves = 2, .releases = 1, .activity = 4 }, watch);
    try testing.expectEqual(core.Point{ .x = 0, .y = -60 }, s.flick.viewportPosition());
    // Leaving the window is no activity; keys and fingers are.
    s.window.dispatchPointer(.exit);
    s.window.dispatchKey(.pressed, .{ .text = "a" });
    core.gestures.dispatchTouch(&s.window, 1, .down, Scroller.at(10, 10));
    core.gestures.dispatchTouch(&s.window, 2, .down, Scroller.at(20, 10));
    core.gestures.dispatchTouch(&s.window, 2, .up, Scroller.at(20, 10));
    core.gestures.dispatchTouch(&s.window, 1, .up, Scroller.at(10, 10));
    try testing.expectEqual(@as(usize, 4 + 1 + 4), watch.activity);
}

test "flickable: wheel scrolls and clamps" {
    const s = try Scroller.create();
    defer s.destroy();
    s.window.dispatchPointer(.{ .wheel = .{ .position = Scroller.at(50, 50), .delta = Scroller.at(0, -120) } });
    try testing.expectEqual(core.Point{ .x = 0, .y = -120 }, s.flick.viewportPosition());
    s.window.dispatchPointer(.{ .wheel = .{ .position = Scroller.at(50, 50), .delta = Scroller.at(0, 500) } });
    try testing.expectEqual(core.Point{}, s.flick.viewportPosition());
}

test "flickable: with snap-y, a drag settles on a row, and the wheel moves by rows" {
    const t0 = core.now();
    const s = try Scroller.create();
    defer s.destroy();
    s.flick.snap_y.set(40);
    // Dragged 70 up, then rested: settles on -80 (the nearest row).
    s.window.dispatchPointer(.{ .pressed = .{ .position = Scroller.at(50, 90) } });
    s.window.dispatchPointer(.{ .moved = .{ .position = Scroller.at(50, 20) } });
    core.updateTimersAndAnimations(t0 + 500);
    s.window.dispatchPointer(.{ .released = .{ .position = Scroller.at(50, 20) } });
    core.updateTimersAndAnimations(t0 + 500 + items.Flickable.snap_duration_ms);
    try testing.expectEqual(@as(f32, -80), s.flick.viewportPosition().y);

    // Two quick wheel steps: two rows, even mid-animation.
    s.window.dispatchPointer(.{ .wheel = .{ .position = Scroller.at(50, 50), .delta = Scroller.at(0, -3) } });
    core.updateTimersAndAnimations(t0 + 800);
    s.window.dispatchPointer(.{ .wheel = .{ .position = Scroller.at(50, 50), .delta = Scroller.at(0, -3) } });
    core.updateTimersAndAnimations(t0 + 800 + items.Flickable.snap_duration_ms);
    try testing.expectEqual(@as(f32, -160), s.flick.viewportPosition().y);
    // Clamped at the end of the content (200: 300 - 100).
    s.window.dispatchPointer(.{ .wheel = .{ .position = Scroller.at(50, 50), .delta = Scroller.at(0, -3) } });
    s.window.dispatchPointer(.{ .wheel = .{ .position = Scroller.at(50, 50), .delta = Scroller.at(0, -3) } });
    core.updateTimersAndAnimations(t0 + 2000);
    try testing.expectEqual(@as(f32, -200), s.flick.viewportPosition().y);
}

test "flickable: releasing while moving flicks, a press stops it" {
    const t0 = core.now();
    const s = try Scroller.create();
    defer s.destroy();
    var flicks: usize = 0;
    s.flick.flicked.setHandler(&flicks, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);

    s.window.dispatchPointer(.{ .pressed = .{ .position = Scroller.at(50, 90) } });
    core.updateTimersAndAnimations(t0 + 10);
    s.window.dispatchPointer(.{ .moved = .{ .position = Scroller.at(50, 70) } });
    core.updateTimersAndAnimations(t0 + 20);
    s.window.dispatchPointer(.{ .moved = .{ .position = Scroller.at(50, 60) } }); // 1 px/ms upwards
    s.window.dispatchPointer(.{ .released = .{ .position = Scroller.at(50, 60) } });
    try testing.expectEqual(@as(usize, 1), flicks);
    try testing.expectEqual(@as(f32, -30), s.flick.viewportPosition().y);

    // Aimed 300 px further, past the end (-200): it overshoots the end.
    core.updateTimersAndAnimations(t0 + 20 + Scrolled.half);
    const mid = s.flick.viewportPosition().y;
    try testing.expect(mid < -200 and mid > -250);
    // A new press stops the flick where it is.
    s.window.dispatchPointer(.{ .pressed = .{ .position = Scroller.at(50, 50) } });
    core.updateTimersAndAnimations(t0 + 20 + 2 * items.Flickable.flick_duration_ms);
    try testing.expectEqual(mid, s.flick.viewportPosition().y);
    try testing.expect(!core.hasActiveAnimations());
    // Let go: back to the end.
    s.window.dispatchPointer(.{ .released = .{ .position = Scroller.at(50, 50) } });
    core.updateTimersAndAnimations(t0 + 20 + 3 * items.Flickable.flick_duration_ms);
    try testing.expectEqual(@as(f32, -200), s.flick.viewportPosition().y);

    // A shorter flick, not reaching the end: no overshoot.
    s.flick.setViewportPosition(.{});
    const t1 = t0 + 20 + 4 * items.Flickable.flick_duration_ms;
    core.updateTimersAndAnimations(t1);
    s.window.dispatchPointer(.{ .pressed = .{ .position = Scroller.at(50, 90) } });
    core.updateTimersAndAnimations(t1 + 10);
    s.window.dispatchPointer(.{ .moved = .{ .position = Scroller.at(50, 80) } });
    core.updateTimersAndAnimations(t1 + 100);
    s.window.dispatchPointer(.{ .moved = .{ .position = Scroller.at(50, 70) } }); // 0.11 px/ms
    s.window.dispatchPointer(.{ .released = .{ .position = Scroller.at(50, 70) } });
    var lowest: f32 = 0;
    var t = t1 + 100;
    while (t <= t1 + 100 + items.Flickable.flick_duration_ms) : (t += 10) {
        core.updateTimersAndAnimations(t);
        lowest = @min(lowest, s.flick.viewportPosition().y);
    }
    core.updateTimersAndAnimations(t1 + 100 + items.Flickable.flick_duration_ms);
    // 20 px dragged, about 33 more flicked, never past where it stops.
    const end = s.flick.viewportPosition().y;
    try testing.expect(end < -40 and end > -200);
    try testing.expectEqual(end, lowest);
}

const Scrolled = struct {
    const half = items.Flickable.flick_duration_ms / 2;
};

test "changes that do not alter pixels do not repaint" {
    const s = try Buttons.create();
    defer s.destroy();
    s.back.background.set(.color(.black));
    var dl: DisplayList = .init(gpa, .{ .width = 200, .height = 200 });
    defer dl.deinit();
    _ = try s.window.render(dl.renderer(), .partial);

    // Set to the same color through a new binding: a dependency changed,
    // the drawing did not.
    try s.back.background.setBinding(gpa, {}, struct {
        fn f() core.Brush {
            return .color(.black);
        }
    }.f);
    var region = try s.window.render(dl.renderer(), .partial);
    try testing.expect(region.isEmpty());

    // Touch areas draw nothing: hovering one repaints nothing.
    s.window.dispatchPointer(.{ .moved = .{ .position = .{ .x = 10, .y = 10 } } });
    try testing.expect(s.back_touch.has_hover.get());
    region = try s.window.render(dl.renderer(), .partial);
    try testing.expect(region.isEmpty());
}

test "a non-stretching layout grows beyond its fixed-size children" {
    var window: Window = undefined;
    window.init(gpa, .{ .width = 200, .height = 100 });
    var column: items.BoxLayout = .vertical();
    var row: items.BoxLayout = .horizontal();
    var dot: items.Rectangle = .{};
    var dot_size: core.LayoutConstraints = .{};
    defer {
        window.deinit();
        dot.deinit();
        dot_size.deinit();
        row.deinit();
        column.deinit();
    }
    window.rootItem().appendChild(&column.item);
    column.item.appendChild(&row.item);
    row.item.appendChild(&dot.item);
    dot.item.constraints = &dot_size;
    dot_size.setFixedSize(.{ .width = 10, .height = 10 });
    row.alignment.set(.start);
    try row.setup(gpa);
    try column.setup(gpa);
    try column.item.fillParent(gpa);
    // The row spans the column, and the dot sits at its start.
    try expectRect(.{ .x = 0, .y = 0, .width = 200, .height = 10 }, &row.item);
    try expectRect(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, &dot.item);
    // With stretch alignment the row is only as wide as its content.
    row.alignment.set(.stretch);
    try testing.expectEqual(@as(f32, 10), row.item.width.get());
}

test "text input: typing, backspace, enter, caret" {
    const t0 = core.now();
    var window: Window = undefined;
    window.init(gpa, .{ .width = 200, .height = 40 });
    var field: items.TextInput = undefined;
    field.init(gpa);
    var accepted: usize = 0;
    defer {
        window.deinit();
        field.deinit();
    }
    window.rootItem().appendChild(&field.item);
    try field.item.fillParent(gpa);
    field.accepted.setHandler(&accepted, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);

    // Typing does nothing until focused; a click focuses.
    window.dispatchKey(.pressed, .{ .text = "x" });
    try testing.expectEqualStrings("", field.text.get());
    window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 5, .y = 5 } } });
    try testing.expect(field.has_focus.get());
    for ([_][]const u8{ "h", "é", "!" }) |t| window.dispatchKey(.pressed, .{ .text = t });
    try testing.expectEqualStrings("hé!", field.text.get());
    window.dispatchKey(.pressed, .{ .text = Key.backspace });
    window.dispatchKey(.pressed, .{ .text = Key.backspace }); // a two-byte character
    try testing.expectEqualStrings("h", field.text.get());
    window.dispatchKey(.pressed, .{ .text = Key.left_arrow }); // not text
    window.dispatchKey(.pressed, .{ .text = "c", .modifiers = .{ .control = true } }); // a shortcut
    try testing.expectEqualStrings("h", field.text.get());
    window.dispatchKey(.pressed, .{ .text = Key.@"return" });
    try testing.expectEqual(@as(usize, 1), accepted);

    // The caret blinks while focused.
    try testing.expect(field.caret_on.get());
    core.updateTimersAndAnimations(t0 + items.TextInput.blink_ms + 1);
    try testing.expect(!field.caret_on.get());
    // Tab moves focus away (TextInput rejects it) and hides the caret.
    window.dispatchKey(.pressed, .{ .text = Key.escape });
    window.setFocusItem(null);
    try testing.expect(!field.has_focus.get());
    try testing.expectEqual(@as(?u64, null), core.nextTimerDeadline());

    // Setting the text from code works as for any property.
    field.text.set("set by code");
    try testing.expectEqualStrings("set by code", field.text.get());
}

test "timer element follows its running and interval properties" {
    const t0 = core.now();
    var timer: items.TimerElement = undefined;
    timer.init(gpa);
    defer timer.deinit();
    var fired: usize = 0;
    timer.triggered.setHandler(&fired, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);
    timer.interval_ms.set(100);
    core.runChangeHandlers(); // applies the new interval
    core.updateTimersAndAnimations(t0 + 100);
    try testing.expectEqual(@as(usize, 1), fired);
    timer.running.set(false);
    core.runChangeHandlers();
    core.updateTimersAndAnimations(t0 + 1000);
    try testing.expectEqual(@as(usize, 1), fired);
}

test "fonts are found by family and weight" {
    const bytes = try core.text.test_font.standard(gpa);
    defer gpa.free(bytes);
    const regular: core.Font = try .init(bytes);
    const bold: core.Font = try .init(bytes);
    const mono: core.Font = try .init(bytes);
    var window: Window = undefined;
    window.init(gpa, .{ .width = 10, .height = 10 });
    defer window.deinit();
    try window.registerFont("Inter", 400, &regular);
    try window.registerFont("Inter", 700, &bold);
    try window.registerFont("Mono", 400, &mono);
    try testing.expectEqual(&regular, window.default_font.get().?);
    try testing.expectEqual(&bold, window.findFont("", 600).?);
    try testing.expectEqual(&regular, window.findFont("inter", 300).?);
    try testing.expectEqual(&mono, window.findFont("Mono", 700).?);
    try testing.expectEqual(@as(?*const core.Font, null), window.findFont("Nope", 400));

    var label: items.Text = .{};
    defer label.deinit();
    window.rootItem().appendChild(&label.item);
    label.font_weight.set(700);
    var dl: DisplayList = .init(gpa, .{ .width = 10, .height = 10 });
    defer dl.deinit();
    label.text.set("A");
    label.item.setGeometry(.{ .width = 10, .height = 10 });
    _ = try window.render(dl.renderer(), .full);
    try testing.expectEqual(&bold, dl.commands.items[1].text.style.font.?);
}

test "Text: letter spacing, and the font size fitted to its box" {
    const bytes = try core.text.test_font.standard(gpa);
    defer gpa.free(bytes);
    const font: core.Font = try .init(bytes);
    var window: Window = undefined;
    window.init(gpa, .{ .width = 100, .height = 100 });
    defer window.deinit();
    window.default_font.set(&font);
    var label: items.Text = .{};
    defer label.deinit();
    window.rootItem().appendChild(&label.item);
    // "OOOO": 2.2 em wide, 1 em tall.
    label.text.set("OOOO");
    label.font_size.set(20);
    label.minimum_font_size.set(6);
    label.item.setGeometry(.{ .width = 22, .height = 30 });
    try testing.expectEqual(@as(f32, 20), label.fittedFontSize());
    label.font_size_mode.set(.horizontal_fit);
    try testing.expectEqual(@as(f32, 10), label.fittedFontSize());
    label.font_size_mode.set(.vertical_fit);
    try testing.expectEqual(@as(f32, 20), label.fittedFontSize());
    label.item.setGeometry(.{ .width = 22, .height = 15 });
    try testing.expectEqual(@as(f32, 15), label.fittedFontSize());
    label.font_size_mode.set(.fit);
    try testing.expectEqual(@as(f32, 10), label.fittedFontSize());
    // In half pixels.
    label.item.setGeometry(.{ .width = 22, .height = 7.7 });
    try testing.expectEqual(@as(f32, 7.5), label.fittedFontSize());
    // Nothing fits: the smallest.
    label.minimum_font_size.set(12);
    try testing.expectEqual(@as(f32, 12), label.fittedFontSize());
    label.minimum_font_size.set(6);
    // Wrapped text fits its width by wrapping: only the height counts.
    label.text.set("OO OO");
    label.wrap.set(.word_wrap);
    label.item.setGeometry(.{ .width = 22, .height = 30 });
    try testing.expectEqual(@as(f32, 15), label.fittedFontSize()); // two lines
    label.wrap.set(.no_wrap);
    label.text.set("OOOO");

    // Spacing counts in fitting: 4 × (0.55 s + 2) ≤ 22.
    label.font_size_mode.set(.horizontal_fit);
    label.letter_spacing.set(2);
    try testing.expectEqual(@as(f32, 6), label.fittedFontSize());
    // A layout may make it as narrow as its smallest size.
    try testing.expectApproxEqAbs(@as(f32, 4 * (0.55 * 6 + 2)), label.item.layoutInfo(.horizontal).min, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 4 * (0.55 * 20 + 2)), label.item.layoutInfo(.horizontal).preferred, 1e-3);

    // Drawn at the fitted size, spaced.
    var dl: DisplayList = .init(gpa, .{ .width = 100, .height = 100 });
    defer dl.deinit();
    _ = try window.render(dl.renderer(), .full);
    try testing.expectEqual(@as(f32, 6), dl.commands.items[1].text.style.font_size);
    try testing.expectEqual(@as(f32, 2), dl.commands.items[1].text.style.letter_spacing);

    // Text fields and rich text are spaced too.
    var field: items.TextInput = undefined;
    field.init(gpa);
    defer field.deinit();
    var rich: items.StyledText = undefined;
    rich.init(gpa);
    defer rich.deinit();
    window.rootItem().appendChildren(&.{ &field.item, &rich.item });
    field.text.set("AB");
    field.font_size.set(10);
    rich.text.set("AB");
    rich.font_size.set(10);
    const field_width = field.item.layoutInfo(.horizontal).preferred;
    const rich_width = rich.item.layoutInfo(.horizontal).preferred;
    field.letter_spacing.set(3);
    rich.letter_spacing.set(3);
    try testing.expectApproxEqAbs(field_width + 6, field.item.layoutInfo(.horizontal).preferred, 1e-3);
    try testing.expectApproxEqAbs(rich_width + 6, rich.item.layoutInfo(.horizontal).preferred, 1e-3);
}

test "StyledText not wrapped: lines only where the text breaks them, cut at the edge" {
    const bytes = try core.text.test_font.standard(gpa);
    defer gpa.free(bytes);
    const font: core.Font = try .init(bytes);
    var window: Window = undefined;
    window.init(gpa, .{ .width = 200, .height = 200 });
    defer window.deinit();
    window.default_font.set(&font);
    var rich: items.StyledText = undefined;
    rich.init(gpa);
    defer rich.deinit();
    window.rootItem().appendChild(&rich.item);
    rich.text.set("OO OO OO OO\n\nOO");
    rich.font_size.set(10);
    rich.item.setGeometry(.{ .width = 30, .height = 100 });
    const wrapped = rich.item.layoutInfo(.vertical).preferred;
    try testing.expectEqual(@as(f32, 0), rich.item.layoutInfo(.horizontal).min);

    rich.wrap.set(.no_wrap);
    const v = rich.item.layoutInfo(.vertical).preferred;
    try testing.expect(v < wrapped);
    // As wide as its longest line, which it needs.
    const h = rich.item.layoutInfo(.horizontal);
    try testing.expect(h.preferred > 30);
    try testing.expectEqual(h.preferred, h.min);
    try testing.expectApproxEqAbs(h.preferred, rich.layoutAt(null).?.size.width, 1e-3);

    // Clipped to the element.
    var dl: DisplayList = .init(gpa, .{ .width = 200, .height = 200 });
    defer dl.deinit();
    _ = try window.render(dl.renderer(), .full);
    var cut = false;
    for (dl.commands.items) |c| if (c == .text) {
        cut = cut or c.text.clip.width <= 30.001;
    };
    try testing.expect(cut);
}

test "StyledText aligned: each line across its width, the text in its height" {
    const bytes = try core.text.test_font.standard(gpa);
    defer gpa.free(bytes);
    const font: core.Font = try .init(bytes);
    var window: Window = undefined;
    window.init(gpa, .{ .width = 200, .height = 200 });
    defer window.deinit();
    window.default_font.set(&font);
    var rich: items.StyledText = undefined;
    rich.init(gpa);
    defer rich.deinit();
    window.rootItem().appendChild(&rich.item);
    // At 10px: "OO" 11px, "OOOO" 22px.
    rich.text.set("OO\n\n- OOOO");
    rich.font_size.set(10);
    rich.item.setGeometry(.{ .width = 100, .height = 100 });
    const left = rich.layoutAt(100).?;
    const indent = left.fragments[2].rect.x; // after the bullet
    const bullet = left.fragments[1].rect.x;
    rich.horizontal_alignment.set(.center);
    var l = rich.layoutAt(100).?;
    try testing.expectApproxEqAbs(@as(f32, 44.5), l.fragments[0].rect.x, 1e-3);
    // The list item in what is right of its indent, its bullet with it.
    try testing.expectApproxEqAbs(indent + (100 - indent - 22) / 2, l.fragments[2].rect.x, 1e-3);
    try testing.expectApproxEqAbs(l.fragments[2].rect.x - indent + bullet, l.fragments[1].rect.x, 1e-3);
    rich.horizontal_alignment.set(.right);
    l = rich.layoutAt(100).?;
    try testing.expectApproxEqAbs(@as(f32, 89), l.fragments[0].rect.x, 1e-3);

    // Unwrapped: the lines to the widest, the text across the element;
    // and to the bottom. Clicks find the text where it is drawn.
    rich.wrap.set(.no_wrap);
    rich.horizontal_alignment.set(.center);
    rich.vertical_alignment.set(.bottom);
    rich.text.set("[OO](a)\n\nOOOO");
    l = rich.layoutAt(null).?;
    const dx = (100 - l.size.width) / 2;
    const dy = 100 - l.size.height;
    const link = l.fragments[0].rect;
    try testing.expectApproxEqAbs((l.size.width - 11) / 2, link.x, 1e-3);
    try testing.expectEqual(@as(?u32, 0), rich.linkAt(.{ .x = link.x + dx + 3, .y = link.y + dy + 3 }));
    try testing.expectEqual(@as(?u32, null), rich.linkAt(.{ .x = link.x + 3, .y = link.y + 3 }));
    var dl: DisplayList = .init(gpa, .{ .width = 200, .height = 200 });
    defer dl.deinit();
    _ = try window.render(dl.renderer(), .full);
    for (dl.commands.items) |c| if (c == .text) {
        try testing.expectApproxEqAbs(link.x + dx, c.text.rect.x, 1e-3);
        try testing.expectApproxEqAbs(link.y + dy, c.text.rect.y, 1e-3);
        break;
    };
}

test "StyledText images: loaded in the background, laid out and drawn; HTML colors drawn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const px = [_]core.Rgba8{.{ .r = 255, .a = 255 }} ** 8;
    const bytes = try core.png.encode(gpa, 4, 2, &px);
    defer gpa.free(bytes);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dot.png", .data = bytes });
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/", .{tmp.sub_path});
    defer gpa.free(dir);
    defer core.image_loader.clearCache();

    var window: Window = undefined;
    window.init(gpa, .{ .width = 200, .height = 200 });
    defer window.deinit();
    var rich: items.StyledText = undefined;
    rich.init(gpa);
    defer rich.deinit();
    window.rootItem().appendChild(&rich.item);
    rich.format.set(.html);
    rich.font_size.set(10);
    // Relative to `base-url`.
    rich.base_url.set(dir);
    rich.text.set("<p><span style='color: red; background: #00ff00'>ab</span> <img src='dot.png' height=10> <img src='no/such.png' alt='gone'></p>");
    rich.item.setGeometry(.{ .width = 200, .height = 100 });
    // Loading (on a thread): its height only, nothing to draw yet.
    _ = rich.layoutAt(200).?;
    const t0 = core.now();
    var waited: u64 = 0;
    while (rich.shown.items[0] == .loading or rich.shown.items[1] == .loading) : (waited += 5) {
        if (waited > 10_000) return error.TestUnexpectedResult;
        var t: std.Io.Threaded = .init_single_threaded;
        t.io().sleep(.fromMilliseconds(5), .awake) catch {};
        core.updateTimersAndAnimations(t0 + waited + 20);
    }
    try testing.expect(rich.shown.items[1] == .failed);
    // There: 4 by 2 at 10 high, after "ab " (in proportion).
    const l = rich.layoutAt(200).?;
    var pic: ?core.Rect = null;
    var gone = false;
    for (l.fragments) |f| {
        if (f.image != null) pic = f.rect;
        if (std.mem.eql(u8, f.text, "gone")) gone = true;
    }
    try testing.expectEqual(@as(f32, 20), pic.?.width);
    try testing.expectEqual(@as(f32, 10), pic.?.height);
    try testing.expect(gone);

    var dl: DisplayList = .init(gpa, .{ .width = 200, .height = 200 });
    defer dl.deinit();
    _ = try window.render(dl.renderer(), .full);
    var images: usize = 0;
    var red_text = false;
    var green_back = false;
    for (dl.commands.items) |c| switch (c) {
        .image => |im| {
            images += 1;
            try testing.expectEqual(pic.?.width, im.rect.width);
            try testing.expectEqual(@as(u32, 4), im.style.image.width);
        },
        .text => |tx| if (std.mem.eql(u8, tx.style.text, "ab")) {
            red_text = std.meta.eql(tx.style.color, core.Brush.color(.rgb(0xff0000)));
        },
        .rectangle => |r| if (std.meta.eql(r.style.background, core.Brush.color(.rgb(0x00ff00)))) {
            green_back = true;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), images);
    try testing.expect(red_text and green_back);
}

test "StyledText fitted to its box: headings and all, the largest size whose text fits" {
    const bytes = try core.text.test_font.standard(gpa);
    defer gpa.free(bytes);
    const font: core.Font = try .init(bytes);
    var window: Window = undefined;
    window.init(gpa, .{ .width = 200, .height = 200 });
    defer window.deinit();
    window.default_font.set(&font);
    var rich: items.StyledText = undefined;
    rich.init(gpa);
    defer rich.deinit();
    window.rootItem().appendChild(&rich.item);
    rich.text.set("# OO\n\nOO OO OO");
    rich.font_size.set(20);
    rich.minimum_font_size.set(4);
    rich.item.setGeometry(.{ .width = 60, .height = 200 });
    try testing.expectEqual(@as(f32, 20), rich.fittedFontSize());
    const full = rich.layoutAt(60).?.size.height;
    try testing.expect(full > 40);

    // Not as tall: smaller, until it fits, and not half a pixel larger.
    rich.font_size_mode.set(.vertical_fit);
    rich.item.setGeometry(.{ .width = 60, .height = 40 });
    const small = rich.fittedFontSize();
    try testing.expect(small < 20 and small >= 4);
    try testing.expect(rich.layoutAt(60).?.size.height <= 40);
    rich.font_size.set(small + 0.5);
    rich.font_size_mode.set(.fixed);
    try testing.expect(rich.layoutAt(60).?.size.height > 40);
    rich.font_size.set(20);
    rich.font_size_mode.set(.vertical_fit);
    // Drawn at it: the heading 1.6 times it.
    var dl: DisplayList = .init(gpa, .{ .width = 200, .height = 200 });
    defer dl.deinit();
    _ = try window.render(dl.renderer(), .full);
    var sizes: [2]f32 = undefined;
    var n: usize = 0;
    for (dl.commands.items) |c| if (c == .text and n < 2) {
        sizes[n] = c.text.style.font_size;
        n += 1;
    };
    try testing.expectApproxEqAbs(small * 1.6, sizes[0], 1e-3);
    try testing.expectEqual(small, sizes[1]);

    // A layout may make it as short as at its smallest size.
    const v = rich.item.layoutInfo(.vertical);
    try testing.expect(v.min < v.preferred);
    try testing.expectApproxEqAbs(full, v.preferred, 1e-3);
    // Room enough: its own size.
    rich.item.setGeometry(.{ .width = 60, .height = 200 });
    try testing.expectEqual(@as(f32, 20), rich.fittedFontSize());
}

test "the mouse cursor: the innermost item that sets one, the grabber while dragging" {
    var window: core.Window = undefined;
    window.init(gpa, .{ .width = 200, .height = 100 });
    defer window.deinit();
    var link: core.items.TouchArea = .{};
    defer link.deinit();
    var field: core.items.TextInput = undefined;
    field.init(gpa);
    defer field.deinit();
    window.rootItem().appendChildren(&.{ &link.item, &field.item });
    link.item.setGeometry(.{ .x = 0, .y = 0, .width = 100, .height = 100 });
    field.item.setGeometry(.{ .x = 100, .y = 0, .width = 100, .height = 100 });
    link.mouse_cursor.set(.pointer);
    const Cursor = core.input.MouseCursor;

    try testing.expectEqual(Cursor.default, window.mouseCursor());
    window.dispatchPointer(.{ .moved = .{ .position = .{ .x = 50, .y = 50 } } });
    try testing.expectEqual(Cursor.pointer, window.mouseCursor());
    window.dispatchPointer(.{ .moved = .{ .position = .{ .x = 150, .y = 50 } } });
    try testing.expectEqual(Cursor.text, window.mouseCursor()); // text fields: an I-beam

    // Dragging from the field keeps its cursor, wherever the pointer goes.
    window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 150, .y = 50 } } });
    window.dispatchPointer(.{ .moved = .{ .position = .{ .x = 50, .y = 50 } } });
    try testing.expectEqual(Cursor.text, window.mouseCursor());
    window.dispatchPointer(.{ .released = .{ .position = .{ .x = 50, .y = 50 } } });
    window.dispatchPointer(.{ .moved = .{ .position = .{ .x = 51, .y = 50 } } });
    try testing.expectEqual(Cursor.pointer, window.mouseCursor());

    // Disabled: the default; outside the window: the default.
    link.item.enabled.set(false);
    try testing.expectEqual(Cursor.default, window.mouseCursor());
    window.dispatchPointer(.exit);
    try testing.expectEqual(Cursor.default, window.mouseCursor());
}
