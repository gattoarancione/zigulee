// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! End-to-end tests: `.zge` files compiled to Zig at build time.

const std = @import("std");
const testing = std.testing;
const zigulee = @import("zigulee");
const ui = @import("ui_features");

const gpa = testing.allocator;

fn click(app: *ui.App, x: f32, y: f32) void {
    const w = app.window();
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
}

test "properties, bindings and string interpolation" {
    const app = try ui.App.create(gpa);
    defer app.destroy();
    try testing.expectEqualStrings("Features", app.title.get());
    try testing.expectEqual(zigulee.core.Size{ .width = 300, .height = 200 }, app.window().size());
    try testing.expectEqual(@as(i32, 0), app.count.get());
    try testing.expectEqualStrings("Clicked 0 times", app.summary.get());

    app.count.set(1);
    try testing.expectEqualStrings("Clicked 1 time", app.summary.get());
    try testing.expectEqual(@as(f32, 0.25), app.ratio.get());
    // Two-way: `mirror` follows the text it is linked to.
    try testing.expectEqualStrings("Clicked 1 time", app.mirror.get());
    try testing.expectEqualStrings(app.summary.get(), app.echo.text.get());
}

test "layout of elements and sub-components" {
    const app = try ui.App.create(gpa);
    defer app.destroy();
    // VerticalLayout padding 8: the 120x32 button is centered horizontally.
    const button = app.button.rootItem().geometry();
    try testing.expectEqual(zigulee.core.Rect{ .x = 90, .y = 8, .width = 120, .height = 32 }, button);
    // The bar has a fixed height and fills the width.
    const bar = app.bar.item.geometry();
    try testing.expectEqual(@as(f32, 20), bar.height);
    try testing.expectEqual(@as(f32, 284), bar.width);
    // The label inside the button fills it.
    try testing.expectEqual(@as(f32, 120), app.button.label.item.width.get());
    // Percentages: half the window.
    try testing.expectEqual(@as(f32, 150), app.overlay.item.width.get());
    app.pad.set(20);
    try testing.expectEqual(@as(f32, 20), app.button.rootItem().y.get());
}

test "handlers, callbacks and conditions" {
    const app = try ui.App.create(gpa);
    defer app.destroy();
    var reset_called = false;
    _ = &reset_called;

    try testing.expectEqualStrings("none", app.status.text.get());
    click(app, 150, 24);
    try testing.expectEqual(@as(i32, 1), app.count.get());
    try testing.expectEqualStrings("few", app.status.text.get());
    click(app, 150, 24);
    click(app, 150, 24);
    try testing.expectEqualStrings("many", app.status.text.get());
    try testing.expect(app.bar.background.get().eql(.color(.rgb(0x00ff00))));

    try testing.expectEqual(@as(i32, 5), app.add.call(.{ 2, 3 }));
    app.reset.call(.{});
    try testing.expectEqual(@as(i32, 0), app.count.get());
    try testing.expectEqualStrings("reset", app.status.text.get());
    try testing.expect(app.bar.background.get().eql(.color(.rgb(0xff0000))));
}

test "visibility binding and output properties" {
    const app = try ui.App.create(gpa);
    defer app.destroy();
    try testing.expect(!app.overlay.item.visible.get());
    app.count.set(5);
    try testing.expect(app.overlay.item.visible.get());

    const w = app.window();
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 150, .y = 24 } } });
    try testing.expect(app.button.is_pressed.get());
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 150, .y = 24 } } });
    try testing.expect(!app.button.is_pressed.get());
}

test "animated property in a sub-component" {
    const t0 = zigulee.core.now();
    const app = try ui.App.create(gpa);
    defer app.destroy();
    const dark = zigulee.Brush.color(.rgb(0x222222));
    const light = zigulee.Brush.color(.rgb(0x444444));
    try testing.expect(app.button.root.background.get().eql(light));
    app.window().dispatchPointer(.{ .pressed = .{ .position = .{ .x = 150, .y = 24 } } });
    _ = app.button.root.background.get(); // starts the animation
    zigulee.updateTimersAndAnimations(t0 + 50);
    const mid = app.button.root.background.get();
    try testing.expect(!mid.eql(light) and !mid.eql(dark));
    zigulee.updateTimersAndAnimations(t0 + 100);
    try testing.expect(app.button.root.background.get().eql(dark));
}

test "renders" {
    const app = try ui.App.create(gpa);
    defer app.destroy();
    var pixels: [300 * 200]zigulee.core.Rgba8 = undefined;
    var r: zigulee.software.Renderer(zigulee.core.Rgba8) = .init(gpa);
    defer r.deinit();
    _ = try r.renderWindow(app.window(), .init(&pixels, 300, 200), .full);
    // The bar is red while count is 0; the button background is #444444.
    const bar = app.bar.item.absoluteGeometry();
    const by: usize = @intFromFloat(bar.y + bar.height / 2);
    try testing.expectEqual(zigulee.Color.rgb(0xff0000).premultiplied(), pixels[by * 300 + 150]);
    try testing.expectEqual(zigulee.Color.rgb(0x444444).premultiplied(), pixels[12 * 300 + 95]);
}

// ---- for / if ----

const dynamic = @import("ui_dynamic");

fn rowLabels(app: *dynamic.Lists, out: [][]const u8) usize {
    var n: usize = 0;
    var it = app.column.item.layoutChildren();
    while (it.next()) |item| {
        if (n == out.len) break;
        // Rows are Row instances: find their Text by walking the item tree.
        const text = item.first_child orelse continue;
        if (!std.mem.eql(u8, text.vtable.name, "Text")) continue;
        const t: *zigulee.items.Text = @fieldParentPtr("item", text);
        out[n] = t.text.get();
        n += 1;
    }
    return n;
}

test "for over a model property, with index, in a layout" {
    const app = try dynamic.Lists.create(gpa);
    defer app.destroy();
    var labels: [8][]const u8 = undefined;
    const n = rowLabels(app, &labels);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("1. alpha", labels[0]);
    try testing.expectEqualStrings("3. gamma", labels[2]);
    try testing.expectEqual(@as(i32, 3), app.name_count.get());
    try testing.expectEqualStrings("beta", app.second.get());

    // Rows are laid out one under another, 20px each.
    var it = app.column.item.layoutChildren();
    const first = it.next().?;
    const second = it.next().?;
    try testing.expectEqual(@as(f32, 20), first.height.get());
    try testing.expectEqual(@as(f32, 20), second.absolutePosition().y);

    // Clicking a row runs its handler with its own index and item.
    const w = app.window();
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 50, .y = 30 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 50, .y = 30 } } });
    try testing.expectEqual(@as(i32, 1), app.selected.get());
    try testing.expectEqualStrings("beta", app.last_picked.get());
}

test "replacing the model rebuilds the rows" {
    const app = try dynamic.Lists.create(gpa);
    defer app.destroy();
    var model: zigulee.VecModel([]const u8) = .init(gpa);
    defer model.deinit();
    try model.setAll(&.{ "one", "two" });
    app.names.set(model.model());
    zigulee.runChangeHandlers();
    var labels: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 2), rowLabels(app, &labels));
    try testing.expectEqualStrings("2. two", labels[1]);
    // Row changes in the model update rows in place.
    try model.push("three");
    model.setRowData(0, "uno");
    try testing.expectEqual(@as(usize, 3), rowLabels(app, &labels));
    try testing.expectEqualStrings("1. uno", labels[0]);
    try testing.expectEqual(@as(i32, 3), app.name_count.get());
    app.names.set(zigulee.core.emptyModel([]const u8));
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(usize, 0), rowLabels(app, &labels));
}

test "for over an int and nested loops" {
    const app = try dynamic.Lists.create(gpa);
    defer app.destroy();
    // 3 rows, 2 dot rows, 2 color bars.
    try testing.expectEqual(@as(usize, 7), app.column.item.layoutChildCount());
    app.dots.set(4);
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(usize, 9), app.column.item.layoutChildCount());

    // In dot row d = 1, cell c = 1 is red ((d + c) == 2), the others blue.
    var it = app.column.item.layoutChildren();
    for (0..4) |_| _ = it.next();
    const dot_row = it.next().?;
    var cells = dot_row.layoutChildren();
    var colors: [3]zigulee.Brush = undefined;
    for (&colors) |*c| {
        const cell: *zigulee.items.Rectangle = @fieldParentPtr("item", cells.next().?);
        c.* = cell.background.get();
    }
    try testing.expect(colors[0].eql(.color(.rgb(0x0000ff))));
    try testing.expect(colors[1].eql(.color(.rgb(0xff0000))));
    try testing.expect(colors[2].eql(.color(.rgb(0x0000ff))));
    // Three cells share the row's width.
    try testing.expectEqual(@as(f32, 200.0 / 3.0), dot_row.first_child.?.first_child.?.width.get());

    app.dots.set(0);
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(usize, 5), app.column.item.layoutChildCount());
}

test "if adds and removes its element" {
    const app = try dynamic.Lists.create(gpa);
    defer app.destroy();
    try testing.expectEqual(@as(usize, 7), app.column.item.layoutChildCount());
    app.show_footer.set(true);
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(usize, 8), app.column.item.layoutChildCount());
    var it = app.column.item.layoutChildren();
    var last: *zigulee.Item = undefined;
    while (it.next()) |item| last = item;
    const footer: *zigulee.items.Text = @fieldParentPtr("item", last);
    try testing.expectEqualStrings("3 names", footer.text.get());
    app.show_footer.set(false);
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(usize, 7), app.column.item.layoutChildCount());
}

// ---- structs, enums, states, changed, grid, flickable, input, timer, image ----

const language = @import("ui_language");

test "structs, enums and changed handlers" {
    const app = try language.Language.create(gpa);
    defer app.destroy();
    try testing.expectEqualStrings("Ada", app.first_name.get());
    try testing.expect(!app.is_dark.get());
    app.mode.set(.dark);
    try testing.expect(app.is_dark.get());
    try testing.expectEqual(@as(i32, 0), app.mode_changes.get()); // handlers run with change handlers
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(i32, 1), app.mode_changes.get());
    app.mode.set(.dark); // no change
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(i32, 1), app.mode_changes.get());

    // Struct models: rows show fields, rows update with the model.
    var people: zigulee.VecModel(language.Contact) = .init(gpa);
    defer people.deinit();
    try people.push(.{ .name = "Linus", .age = 55 });
    app.contacts.set(people.model());
    zigulee.runChangeHandlers();
    try testing.expectEqualStrings("Linus", app.first_name.get());
    var rows = app.column.item.layoutChildren();
    const row: *zigulee.items.Text = @fieldParentPtr("item", rows.next().?);
    try testing.expectEqualStrings("Linus (55)", row.text.get());
    try testing.expectEqual(@as(i32, 700), row.font_weight.get());
    try testing.expect((language.Contact{ .name = "a", .age = 1 }).eql(.{ .name = "a", .age = 1 }));
}

test "states override bindings while active" {
    const app = try language.Language.create(gpa);
    defer app.destroy();
    try testing.expect(app.box.background.get().eql(.color(.rgb(0xff0000))));
    try testing.expect(app.label.color.get().eql(.color(.rgb(0x000000))));
    app.mode.set(.dark);
    try testing.expect(app.box.background.get().eql(.color(.rgb(0x000000))));
    try testing.expect(app.label.color.get().eql(.color(.rgb(0xffffff))));
    app.mode.set(.light);
    try testing.expect(app.box.background.get().eql(.color(.rgb(0xff0000))));
}

test "grid layout with rows and spans" {
    const app = try language.Language.create(gpa);
    defer app.destroy();
    // 300 wide, spacing 4: two columns of 148; two rows of 23 in 50.
    try testing.expectEqual(zigulee.core.Rect{ .x = 0, .y = 0, .width = 148, .height = 23 }, app.box.item.geometry());
    try testing.expectEqual(zigulee.core.Rect{ .x = 152, .y = 0, .width = 148, .height = 23 }, app.second.item.geometry());
    try testing.expectEqual(zigulee.core.Rect{ .x = 0, .y = 27, .width = 300, .height = 23 }, app.wide.item.geometry());
}

test "flickable viewport follows its content" {
    const app = try language.Language.create(gpa);
    defer app.destroy();
    try testing.expectEqual(@as(f32, 60), app.list.item.height.get());
    try testing.expectEqual(@as(f32, 300), app.list.viewport.item.width.get());
    // Two 20px rows: the viewport is the flickable's height (60).
    try testing.expectEqual(@as(f32, 60), app.list.viewport.item.height.get());
    var people: zigulee.VecModel(language.Contact) = .init(gpa);
    defer people.deinit();
    for (0..5) |_| try people.push(.{ .name = "x", .age = 1 });
    app.contacts.set(people.model());
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(f32, 100), app.list.viewport.item.height.get());
}

test "text input, timer and image elements" {
    const t0 = zigulee.core.now();
    const app = try language.Language.create(gpa);
    defer app.destroy();
    const w = app.window();
    app.input.focus();
    w.dispatchKey(.pressed, .{ .text = "h" });
    w.dispatchKey(.pressed, .{ .text = "i" });
    try testing.expectEqualStrings("hi", app.typed.get());
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.@"return" });
    try testing.expectEqual(@as(i32, 1), app.submitted.get());

    app.ticking.set(true);
    zigulee.runChangeHandlers();
    zigulee.updateTimersAndAnimations(t0 + 100);
    zigulee.updateTimersAndAnimations(t0 + 200);
    try testing.expectEqual(@as(i32, 2), app.ticks.get());
    app.ticking.set(false);
    zigulee.runChangeHandlers();
    zigulee.updateTimersAndAnimations(t0 + 1000);
    try testing.expectEqual(@as(i32, 2), app.ticks.get());

    // No audio output in tests: the sound is there, but does not play.
    try testing.expectEqual(@as(i64, 10), app.chime_length.get());
    try testing.expectEqual(@as(u32, 8000), app.chime.source.get().sample_rate);
    app.chime.play();
    try testing.expect(!app.chime.playing.get());
    // Sound and Music: Audio with their own defaults.
    try testing.expectEqual(@as(i32, 4), app.ding.root.voices.get());
    try testing.expect(app.tune.root.loop.get());
    try testing.expectEqual(@as(i64, 500), app.tune.root.fade_in_ms.get());
    try testing.expectEqual(@as(i64, 2000), app.tune.root.fade_out_ms.get());

    // Durations scaled by floats (not truncated first), divided by ints.
    try testing.expectEqual(@as(i64, 1500), app.scaled.get());
    try testing.expectEqual(@as(i64, 1500), app.halved.get());
    try testing.expectEqual(@as(i64, 2000), app.slowed.get());

    // Video: the first frame shows, then it plays to the end.
    try testing.expectEqual(@as(i64, 300), app.clip_length.get());
    try waitFor(app, struct {
        fn f(a: *language.Language) bool {
            const frame = a.clip.image.source.get() orelse return false;
            return frame.width == 4 and frame.pixels[0].r == 255;
        }
    }.f);
    app.clip.play();
    try waitFor(app, struct {
        fn f(a: *language.Language) bool {
            return a.clips.get() == 1;
        }
    }.f);
    try testing.expectEqual(@as(u8, 255), app.clip.image.source.get().?.pixels[0].b);

    const img = app.picture.source.get().?;
    try testing.expectEqual(@as(u32, 2), img.width);
    try testing.expectEqual(zigulee.Color.rgb(0x00ff00).premultiplied(), img.pixel(1, 0));
    try testing.expectEqual(zigulee.core.Rgba8.transparent, img.pixel(1, 1));

    // The GIF plays: its first frame (red, top-left), then the next
    // (green, top-right) 100 ms later, the first one's area cleared.
    try testing.expectEqual(@as(i32, 4), app.spinner.frame_count.get());
    try testing.expect(app.spinner.playing.get());
    app.spinner.current_frame.set(0); // it played while the clip did
    zigulee.runChangeHandlers();
    var spin = app.spinner.image.source.get().?;
    try testing.expectEqual(@as(u32, 4), spin.width);
    try testing.expectEqual(zigulee.Color.rgb(0xef4444).premultiplied(), spin.pixel(0, 0));
    try testing.expectEqual(zigulee.core.Rgba8.transparent, spin.pixel(3, 0));
    const spun = zigulee.core.now();
    zigulee.updateTimersAndAnimations(spun + 100);
    zigulee.runChangeHandlers();
    spin = app.spinner.image.source.get().?;
    try testing.expectEqual(@as(i32, 1), app.spinner.current_frame.get());
    try testing.expectEqual(zigulee.core.Rgba8.transparent, spin.pixel(0, 0));
    try testing.expectEqual(zigulee.Color.rgb(0x22c55e).premultiplied(), spin.pixel(3, 0));
    // And a still Image of it shows its first frame.
    try testing.expect(app.spinner.source.get().?.animation.len > 0);

    // Nine-sliced: drawn stretched, its 2-pixel frame kept (the red
    // corners stay 2 pixels square).
    const panel = app.panel.source.get().?;
    try testing.expectEqual(zigulee.core.image.NineSlice{ .top = 2, .right = 2, .bottom = 2, .left = 2 }, panel.nine_slice.?);
    const win = app.window();
    const origin = app.panel.item.windowTransform().apply(.{});
    const g: zigulee.core.Rect = .{ .x = origin.x, .y = origin.y, .width = app.panel.item.width.get(), .height = app.panel.item.height.get() };
    const size = win.size();
    const pixels = try gpa.alloc(zigulee.core.Rgba8, @intFromFloat(size.width * size.height));
    defer gpa.free(pixels);
    @memset(pixels, .transparent);
    var r: zigulee.software.Renderer(zigulee.core.Rgba8) = .init(gpa);
    defer r.deinit();
    _ = try r.renderWindow(win, .init(pixels, @intFromFloat(size.width), @intFromFloat(size.height)), .full);
    const at = struct {
        fn f(p: []const zigulee.core.Rgba8, stride: f32, x: f32, y: f32) zigulee.core.Rgba8 {
            return p[@as(usize, @intFromFloat(y)) * @as(usize, @intFromFloat(stride)) + @as(usize, @intFromFloat(x))];
        }
    }.f;
    try testing.expectEqual(zigulee.Color.rgb(0xdc2626).premultiplied(), at(pixels, size.width, g.x + 1, g.y + 1)); // a corner
    try testing.expectEqual(zigulee.Color.rgb(0x1e293b).premultiplied(), at(pixels, size.width, g.x + g.width / 2, g.y + 1)); // the top edge
    try testing.expectEqual(zigulee.Color.rgb(0xe2e8f0).premultiplied(), at(pixels, size.width, g.x + g.width / 2, g.y + g.height / 2)); // the middle
}

/// Advances the UI clock until `ok(app)` (a video's frames are decoded on
/// a thread of their own).
fn waitFor(app: *language.Language, comptime ok: fn (*language.Language) bool) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    for (0..2000) |_| {
        zigulee.updateTimersAndAnimations(zigulee.core.now() + 1);
        zigulee.runChangeHandlers();
        if (ok(app)) return;
        threaded.io().sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

// ---- the gallery example, driven like a user would ----

const gallery = @import("gallery_ui");

test "gallery: click, toggle, type, tabs, select, scroll" {
    const t0 = zigulee.core.now();
    const app = try gallery.Gallery.create(gpa);
    defer app.destroy();
    defer app.dark.set(false); // the palette is a global
    const w = app.window();
    zigulee.runChangeHandlers();
    const tap = struct {
        fn at(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
            zigulee.runChangeHandlers();
        }
    }.at;
    const center = struct {
        fn of(item: *zigulee.core.Item) zigulee.core.Point {
            const g = item.absoluteGeometry();
            return .{ .x = g.x + g.width / 2, .y = g.y + g.height / 2 };
        }
    }.of;

    const b = center(app.click.rootItem());
    tap(w, b.x, b.y);
    tap(w, b.x, b.y);
    try testing.expectEqual(@as(i32, 2), app.clicks.get());

    const s = app.dark_switch.rootItem().absoluteGeometry();
    tap(w, s.x + 10, s.y + s.height / 2);
    try testing.expect(app.dark.get());
    zigulee.updateTimersAndAnimations(t0 + 1000); // let the colors settle
    try testing.expect(w.root.background.get().eql(.color(.rgb(0x202020))));

    const f = center(app.field.rootItem());
    tap(w, f.x, f.y);
    for ([_][]const u8{ "z", "g", "e" }) |t| w.dispatchKey(.pressed, .{ .text = t });
    try testing.expectEqualStrings("zge", app.typed.get());

    // The Lists tab: the third row is "Cherry #3"; clicking selects it.
    app.tab.set(1);
    zigulee.runChangeHandlers();
    const l = app.list.rootItem().absoluteGeometry();
    tap(w, l.x + 50, l.y + 1 + 34 * 2 + 10);
    try testing.expectEqual(@as(?i32, 2), app.picked.selected_rows.get().rowData(0));
    // Wheel scrolling moves the rows up: 100px more is row 5, "Fig #6".
    w.dispatchPointer(.{ .wheel = .{ .position = .{ .x = l.x + 50, .y = l.y + 50 }, .delta = .{ .x = 0, .y = -100 } } });
    tap(w, l.x + 50, l.y + 1 + 34 * 2 + 10);
    try testing.expectEqual(@as(?i32, 5), app.picked.selected_rows.get().rowData(0));
    try testing.expectEqual(@as(i32, 1), app.picked_rows.get());
    // The controls page is hidden: its button does not get clicks.
    tap(w, b.x, b.y);
    try testing.expectEqual(@as(i32, 2), app.clicks.get());
}

// ---- imports and globals ----

const imports = @import("ui_imports");

test "imported components share a global" {
    const app = try imports.Imports.create(gpa);
    defer app.destroy();
    const theme = &imports.Theme.instance;
    theme.dark.set(false);
    try testing.expect(app.button.root.background.get().eql(.color(.rgb(0xeeeeee))));

    // Globals can be written from Zig, from .zge, or through a two-way link.
    theme.dark.set(true);
    try testing.expect(app.dark.get());
    try testing.expect(app.button.root.background.get().eql(.color(.rgb(0x333333))));
    try testing.expect(app.button.caption.color.get().eql(.color(.rgb(0xffffff))));
    app.dark.set(false);
    try testing.expect(!theme.dark.get());

    // A handler declared in the global runs for callbacks from anywhere.
    const before = theme.clicks.get();
    app.window().dispatchPointer(.{ .pressed = .{ .position = .{ .x = 10, .y = 10 } } });
    app.window().dispatchPointer(.{ .released = .{ .position = .{ .x = 10, .y = 10 } } });
    try testing.expectEqual(before + 1, theme.clicks.get());
    try testing.expectEqual(before + 1, app.clicks.get());
}

test "for and if in a grid flow into columns" {
    const app = try dynamic.Grid.create(gpa);
    defer app.destroy();
    // Three repeated cells, then the tail: four columns of 100.
    try testing.expectEqual(@as(f32, 300), app.tail.item.x.get());
    try testing.expectEqual(@as(f32, 100), app.tail.item.width.get());
    try testing.expectEqual(@as(f32, 0), app.below.item.x.get());
    try testing.expectEqual(@as(f32, 200), app.below.item.width.get()); // colspan 2

    app.cells.set(1);
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(f32, 200), app.tail.item.x.get()); // two columns now
    app.extra.set(true);
    zigulee.runChangeHandlers();
    // 1 cell, tail, extra: three columns of 400/3.
    try testing.expectApproxEqAbs(@as(f32, 400.0 / 3.0), app.tail.item.x.get(), 1e-3);
}

test "state transitions use the entered or left state's animation" {
    const t0 = zigulee.core.now();
    const app = try language.Language.create(gpa);
    defer app.destroy();
    const black = zigulee.Brush.color(.rgb(0x000000));
    const white = zigulee.Brush.color(.rgb(0xffffff));
    try testing.expect(app.fader.background.get().eql(white));

    app.mode.set(.dark); // enter: 100ms
    _ = app.fader.background.get();
    zigulee.updateTimersAndAnimations(t0 + 100);
    try testing.expect(app.fader.background.get().eql(black));

    app.mode.set(.light); // leave: 400ms
    _ = app.fader.background.get();
    zigulee.updateTimersAndAnimations(t0 + 200);
    const mid = app.fader.background.get();
    try testing.expect(!mid.eql(black) and !mid.eql(white));
    zigulee.updateTimersAndAnimations(t0 + 500);
    try testing.expect(app.fader.background.get().eql(white));
}

fn texts(item: *zigulee.Item, out: [][]const u8) usize {
    var n: usize = 0;
    var it = item.layoutChildren();
    while (it.next()) |child| : (n += 1) {
        const t: *zigulee.items.Text = @fieldParentPtr("item", child);
        out[n] = t.text.get();
    }
    return n;
}

test "array literals with changing elements update their rows" {
    const app = try dynamic.Arrays.create(gpa);
    defer app.destroy();
    var labels: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 5), texts(&app.column.item, &labels));
    try testing.expectEqualStrings("1:10", labels[1]);
    try testing.expectEqualStrings("x", labels[3]);
    try testing.expectEqual(@as(i32, 10), app.second.get());

    const first_row = app.column.item.layoutChildren().next_item.?;
    app.a.set(2);
    app.name.set("y");
    try testing.expectEqual(@as(i32, 20), app.second.get());
    zigulee.runChangeHandlers();
    _ = texts(&app.column.item, &labels);
    try testing.expectEqualStrings("0:2", labels[0]);
    try testing.expectEqualStrings("1:20", labels[1]);
    try testing.expectEqualStrings("2:7", labels[2]);
    try testing.expectEqualStrings("y", labels[3]);
    // Rows were updated in place, not recreated.
    try testing.expectEqual(first_row, app.column.item.layoutChildren().next_item.?);
}

test "standard widgets: buttons, toggles, slider, keyboard" {
    const wui = @import("ui_widgets");
    const app = try wui.Widgets.create(gpa);
    defer app.destroy();
    const w = app.window();
    const Key = zigulee.core.input.Key;
    const at = struct {
        fn click(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
        }
        fn center(item: *zigulee.core.Item) zigulee.core.Point {
            const g = item.geometry();
            const p = item.absolutePosition();
            return .{ .x = p.x + g.width / 2, .y = p.y + g.height / 2 };
        }
    };

    // Widgets have sensible sizes in a layout.
    try testing.expectEqual(@as(f32, 32), app.button.rootItem().height.get());
    try testing.expectEqual(@as(f32, 32), app.slider.rootItem().height.get());

    const button = at.center(app.button.rootItem());
    at.click(w, button.x, button.y);
    try testing.expectEqual(@as(i32, 1), app.clicks.get());
    // Disabled buttons ignore clicks.
    const disabled = at.center(app.disabled.rootItem());
    at.click(w, disabled.x, disabled.y);
    try testing.expectEqual(@as(i32, 1), app.clicks.get());

    const check = app.check.rootItem().absolutePosition();
    at.click(w, check.x + 10, check.y + 16);
    try testing.expect(app.agree.get());
    at.click(w, check.x + 10, check.y + 16);
    try testing.expect(!app.agree.get());

    // The switch is linked to the style's dark mode.
    const light_bg = w.root.background.get();
    const toggle = app.toggle.rootItem().absolutePosition();
    at.click(w, toggle.x + 20, toggle.y + 16);
    try testing.expect(app.dark.get());
    try testing.expect(!std.meta.eql(light_bg, w.root.background.get()));

    // Slider: the track runs from 10px to width - 10px.
    const slider = app.slider.rootItem();
    const sp = slider.absolutePosition();
    const track = slider.width.get() - 20;
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = sp.x + 10 + track * 0.5, .y = sp.y + 16 } } });
    zigulee.runChangeHandlers(); // the slider reacts to `pressed` in a `changed` handler
    try testing.expectEqual(@as(f32, 5), app.volume.get());
    // No step: any value in between.
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = sp.x + 10 + track * 0.72, .y = sp.y + 16 } } });
    try testing.expectApproxEqAbs(@as(f32, 7.2), app.volume.get(), 0.001);
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = sp.x + track + 100, .y = sp.y + 16 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = sp.x + track + 100, .y = sp.y + 16 } } });
    try testing.expectEqual(@as(f32, 10), app.volume.get());
    try testing.expectEqual(@as(i32, 3), app.changes.get());

    // Pressing the slider focused it: the arrow keys step it, by a
    // hundredth of the range without a step.
    try testing.expect(app.slider.has_focus.get());
    w.dispatchKey(.pressed, .{ .text = Key.left_arrow });
    try testing.expectApproxEqAbs(@as(f32, 9.9), app.volume.get(), 0.001);
    w.dispatchKey(.pressed, .{ .text = Key.home });
    try testing.expectEqual(@as(f32, 0), app.volume.get());
    w.dispatchKey(.pressed, .{ .text = Key.left_arrow });
    try testing.expectEqual(@as(f32, 0), app.volume.get());
    try testing.expectEqual(@as(i32, 5), app.changes.get());

    // Tab skips the disabled button and reaches the line edit.
    w.dispatchKey(.pressed, .{ .text = Key.tab });
    try testing.expect(app.name.has_focus.get());
    for ([_][]const u8{ "A", "d", "a" }) |t| w.dispatchKey(.pressed, .{ .text = t });
    try testing.expectEqualStrings("Ada", app.name_text.get());
    w.dispatchKey(.pressed, .{ .text = Key.@"return" });
    try testing.expectEqualStrings("Ada", app.submitted.get());
    // Text set by the app starts a new undo history.
    app.name_text.set("");
    w.dispatchKey(.pressed, .{ .text = "z", .modifiers = .{ .control = true } });
    try testing.expectEqualStrings("", app.name_text.get());

    // The text edit takes newlines.
    w.dispatchKey(.pressed, .{ .text = Key.tab });
    try testing.expect(app.notes.has_focus.get());
    w.dispatchKey(.pressed, .{ .text = Key.end, .modifiers = .{ .control = true } });
    w.dispatchKey(.pressed, .{ .text = Key.@"return" });
    w.dispatchKey(.pressed, .{ .text = "2" });
    try testing.expectEqualStrings("First line\n2", app.notes_text.get());

    // Tab wraps around to the first button; Return clicks it.
    w.dispatchKey(.pressed, .{ .text = Key.tab });
    try testing.expect(app.button.has_focus.get());
    w.dispatchKey(.pressed, .{ .text = Key.@"return" });
    try testing.expectEqual(@as(i32, 2), app.clicks.get());
    // Space toggles the check box.
    w.dispatchKey(.pressed, .{ .text = Key.tab });
    w.dispatchKey(.pressed, .{ .text = Key.space });
    try testing.expect(app.agree.get());
}

test "containers: @children, ListView, TabWidget, SpinBox" {
    const cui = @import("ui_containers");
    const app = try cui.Containers.create(gpa);
    defer app.destroy();
    const w = app.window();
    const Key = zigulee.core.input.Key;
    const H = struct {
        fn click(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
            zigulee.runChangeHandlers();
        }
        fn abs(item: *zigulee.core.Item) zigulee.core.Rect {
            const p = item.absolutePosition();
            const g = item.geometry();
            return .{ .x = p.x, .y = p.y, .width = g.width, .height = g.height };
        }
    };

    // The card's children are laid out under its heading, inside it.
    const card = H.abs(app.card.rootItem());
    const first = H.abs(&app.first.item);
    const second = H.abs(&app.second.item);
    try testing.expect(first.y > card.y + 4 and second.y > first.y);
    try testing.expect(second.y + second.height <= card.y + card.height);
    try testing.expectEqual(card.width - 8, first.width);

    // The list: 20 rows of 24px in 110px, scrolled by the wheel.
    try testing.expectEqual(@as(f32, 480), app.list_height.get());
    const list = H.abs(app.list.rootItem());
    w.dispatchPointer(.{ .wheel = .{ .position = .{ .x = list.x + 50, .y = list.y + 50 }, .delta = .{ .y = -60 } } });
    try testing.expectEqual(@as(f32, -60), app.list_scroll.get());
    // A click picks the row under the pointer.
    H.click(w, list.x + 50, list.y + 1 + 30);
    try testing.expectEqual(@as(i32, 3), app.picked.get()); // (30 + 60) / 24
    // Pressing at the bottom of the scroll bar scrolls to the end.
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = list.x + list.width - 4, .y = list.y + list.height - 3 } } });
    zigulee.runChangeHandlers();
    try testing.expectEqual(-(480 - (list.height - 2)), app.list_scroll.get());
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = list.x + list.width - 4, .y = list.y + list.height - 3 } } });

    // Tabs: clicking the first tab focuses the bar; the arrows switch.
    const tabs = H.abs(app.tabs.rootItem());
    H.click(w, tabs.x + 10, tabs.y + 18);
    try testing.expectEqual(@as(i32, 0), app.tab.get());
    w.dispatchKey(.pressed, .{ .text = Key.right_arrow });
    try testing.expectEqual(@as(i32, 1), app.tab.get());
    w.dispatchKey(.pressed, .{ .text = Key.right_arrow });
    w.dispatchKey(.pressed, .{ .text = Key.right_arrow });
    try testing.expectEqual(@as(i32, 2), app.tab.get());
    w.dispatchKey(.pressed, .{ .text = Key.left_arrow });
    try testing.expectEqual(@as(i32, 1), app.tab.get());

    // The spin box: its up button, then the keyboard, within 0..10.
    const spin = H.abs(app.spin.rootItem());
    try testing.expectEqual(@as(f32, 32), spin.height);
    H.click(w, spin.x + spin.width - 17, spin.y + 8);
    try testing.expectEqual(@as(i32, 6), app.amount.get());
    for (0..10) |_| w.dispatchKey(.pressed, .{ .text = Key.up_arrow });
    try testing.expectEqual(@as(i32, 10), app.amount.get());
    w.dispatchKey(.pressed, .{ .text = Key.home });
    try testing.expectEqual(@as(i32, 0), app.amount.get());
    H.click(w, spin.x + spin.width - 17, spin.y + spin.height - 8);
    try testing.expectEqual(@as(i32, 0), app.amount.get());

    // A disabled layout: the button in it reads as disabled and ignores
    // clicks, though its own `enabled` is still true.
    const inside = H.abs(app.inside.rootItem());
    const x = inside.x + inside.width / 2;
    const y = inside.y + inside.height / 2;
    H.click(w, x, y);
    try testing.expectEqual(@as(i32, 1), app.inside_clicks.get());
    try testing.expect(app.inside_enabled.get());
    app.panel_enabled.set(false);
    try testing.expect(!app.inside_enabled.get());
    try testing.expect(app.inside.rootItem().enabled.get());
    H.click(w, x, y);
    try testing.expectEqual(@as(i32, 1), app.inside_clicks.get());
    // Nor can it take focus.
    var it = app.inside.rootItem().first_child;
    while (it) |c| : (it = c.next_sibling) try testing.expect(!c.acceptsFocus());
    app.panel_enabled.set(true);
    try testing.expect(app.inside_enabled.get());
    H.click(w, x, y);
    try testing.expectEqual(@as(i32, 2), app.inside_clicks.get());
}

test "functions: declared, public, with arguments and results" {
    const lui = @import("ui_language");
    const app = try lui.Language.create(gpa);
    defer app.destroy();
    try testing.expectEqualStrings("doubled: 0", app.counter_label.get());
    app.press_counter.call(.{});
    try testing.expectEqual(@as(i32, 2), app.bumped.get());
    try testing.expectEqualStrings("doubled: 4", app.counter_label.get());
    // Public functions are methods of the generated struct.
    try testing.expectEqual(@as(i32, 5), app.counter.invoke_bump(3));
}

test "popups: ComboBox, StandardListView, DatePicker" {
    const pui = @import("ui_popups");
    const app = try pui.Popups.create(gpa);
    defer app.destroy();
    const w = app.window();
    const Key = zigulee.core.input.Key;
    const H = struct {
        fn click(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
            zigulee.runChangeHandlers();
        }
    };
    const combo = app.combo.rootItem().absolutePosition();
    try testing.expectEqualStrings("Banana", app.fruit_name.get());
    try testing.expect(!app.combo.popup.is_open.get());

    // Click: the list opens below; picking "Cherry" closes it.
    H.click(w, combo.x + 50, combo.y + 16);
    try testing.expect(app.combo.popup.is_open.get());
    // Rows of 32px from 4px into the popup, which is 2px below the box.
    const first_row_y = combo.y + 32 + 2 + 4 + 16;
    H.click(w, combo.x + 50, first_row_y + 2 * 32);
    try testing.expectEqualStrings("Cherry", app.fruit_name.get());
    try testing.expectEqual(@as(i32, 1), app.picks.get());
    try testing.expect(!app.combo.popup.is_open.get());

    // While open, a click outside closes it and does nothing else.
    H.click(w, combo.x + 50, combo.y + 16);
    try testing.expect(app.combo.popup.is_open.get());
    const list = app.list.rootItem().absolutePosition();
    H.click(w, 300, 500);
    try testing.expect(!app.combo.popup.is_open.get());
    try testing.expectEqual(@as(i32, -1), app.item.get());
    // Escape closes it too; the arrow keys change the choice when closed.
    H.click(w, combo.x + 50, combo.y + 16);
    w.dispatchKey(.pressed, .{ .text = Key.escape });
    try testing.expect(!app.combo.popup.is_open.get());
    w.dispatchKey(.pressed, .{ .text = Key.down_arrow });
    try testing.expectEqualStrings("Date", app.fruit_name.get());

    // The list: click an item, then the arrows.
    H.click(w, list.x + 40, list.y + 1 + 34 + 10);
    try testing.expectEqual(@as(i32, 1), app.item.get());
    w.dispatchKey(.pressed, .{ .text = Key.down_arrow });
    w.dispatchKey(.pressed, .{ .text = Key.down_arrow });
    w.dispatchKey(.pressed, .{ .text = Key.down_arrow });
    try testing.expectEqual(@as(i32, 4), app.item.get());
    // Kept in view: 120px show 3.5 rows; the fifth row is scrolled to.
    try testing.expect(app.list.root.viewport_y.get() < 0); // inherited from ScrollView

    // The calendar: 2026-10-14 is a Wednesday (Monday = 0).
    try testing.expectEqual(@as(i32, 2), app.weekday.get());
    try testing.expectEqual(@as(i32, 6), app.picker.invoke_weekday(2000, 1, 2)); // a Sunday
    try testing.expect(app.picker.invoke_is_leap(2024) and !app.picker.invoke_is_leap(1900) and app.picker.invoke_is_leap(2000));
    try testing.expectEqual(@as(i32, 29), app.picker.invoke_days_in(2024, 2));
    // Next month, then click the first day (November 1, 2026 is a Sunday:
    // the seventh cell).
    const picker = app.picker.rootItem().absolutePosition();
    const pw = app.picker.rootItem().width.get();
    H.click(w, picker.x + pw - 22, picker.y + 22);
    const cell = @min(pw / 7, (300 - 72) / 6);
    const left = picker.x + (pw - 7 * cell) / 2;
    H.click(w, left + 6 * cell + cell / 2, picker.y + 66 + cell / 2);
    try testing.expectEqual(@as(i32, 11), app.month.get());
    try testing.expectEqual(@as(i32, 1), app.day.get());
    try testing.expectEqual(@as(i32, 2026), app.year.get());
}

test "StandardTableView and models of models" {
    const tui = @import("ui_table");
    const app = try tui.Table.create(gpa);
    defer app.destroy();
    const w = app.window();
    // Models set from outside a component reach its `for`s when change
    // handlers run (the event loop does this before the first frame).
    zigulee.runChangeHandlers();
    const H = struct {
        fn click(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
            zigulee.runChangeHandlers();
        }
    };
    try testing.expectEqualStrings("Ada Lovelace", app.picked_name.get());
    // Nested arrays with changing cells.
    try testing.expectEqualStrings("Hedy", app.computed_first.get());
    app.extra.set("H.");
    try testing.expectEqualStrings("H.", app.computed_first.get());

    // Header clicks ask for sorting, then toggle the direction.
    H.click(w, 10 + 1 + 110 + 140 + 20, 10 + 16);
    try testing.expectEqual(@as(i32, 2), app.sorted_by.get());
    try testing.expect(app.sorted_up.get());
    H.click(w, 10 + 1 + 110 + 140 + 20, 10 + 16);
    try testing.expect(!app.sorted_up.get());
    H.click(w, 10 + 30, 10 + 16);
    try testing.expectEqual(@as(i32, 0), app.sorted_by.get());
    try testing.expect(app.sorted_up.get());

    // Rows: a click (rows start 34px down), then the arrows.
    H.click(w, 10 + 60, 10 + 34 + 2 * 32 + 10);
    try testing.expectEqual(@as(i32, 2), app.row.get());
    try testing.expectEqualStrings("Alan Turing", app.picked_name.get());
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.down_arrow });
    try testing.expectEqualStrings("Katherine Johnson", app.picked_name.get());
    try testing.expectEqual(@as(f32, 110), app.table.invoke_column_x(1));
}

// ---- the todo example ----

const todo_ui = @import("todo_ui");
const Todo = @import("todo_list").Todo;

test "todo example: add, toggle, remove and clear through the UI" {
    const app = try todo_ui.TodoApp.create(gpa);
    defer app.destroy();
    var todo: Todo = undefined;
    todo.init(gpa, app);
    defer todo.deinit();
    const w = app.window();
    zigulee.runChangeHandlers();
    const tap = struct {
        fn at(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
            zigulee.runChangeHandlers();
        }
    }.at;
    const Key = zigulee.core.input.Key;

    // Typing and Return add an item and clear the field.
    const f = app.input.rootItem().absoluteGeometry();
    tap(w, f.x + 20, f.y + f.height / 2);
    for ([_][]const u8{ "M", "i", "l", "k", Key.@"return", "E", "g", "g", "s", Key.@"return" }) |t| w.dispatchKey(.pressed, .{ .text = t });
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(usize, 2), todo.items.rowCount());
    try testing.expectEqualStrings("Eggs", todo.items.rowData(1).?.title);
    try testing.expectEqualStrings("", app.input.text.get());
    try testing.expectEqual(@as(i32, 2), app.remaining.get());

    // Rows are 44px high, below the field; the check box is on the left,
    // the Remove button on the right.
    const list = app.list.rootItem().absoluteGeometry();
    const row = struct {
        fn y(l: zigulee.core.Rect, i: f32) f32 {
            return l.y + 1 + 44 * i + 22;
        }
    }.y;
    tap(w, list.x + 20, row(list, 0));
    try testing.expect(todo.items.rowData(0).?.done);
    try testing.expectEqual(@as(i32, 1), app.remaining.get());

    tap(w, list.x + list.width - 40, row(list, 1));
    try testing.expectEqual(@as(usize, 1), todo.items.rowCount());
    try testing.expectEqualStrings("Milk", todo.items.rowData(0).?.title);

    const clear = app.clear.rootItem().absoluteGeometry();
    tap(w, clear.x + clear.width / 2, clear.y + clear.height / 2);
    try testing.expectEqual(@as(usize, 0), todo.items.rowCount());
}

// ---- translations ----

const i18n_ui = @import("ui_i18n");

test "translations: source texts, then a catalog, switching at run time" {
    const i18n = zigulee.core.i18n;
    i18n.setTranslator(null);
    const app = try i18n_ui.Translated.create(gpa);
    defer app.destroy();
    try testing.expectEqualStrings("Hello, Ada!", app.greeting.get());
    try testing.expectEqualStrings("1 file", app.files.get());
    app.count.set(3);
    try testing.expectEqualStrings("3 files", app.files.get());
    try testing.expectEqualStrings("Open", app.open.get());
    try testing.expectEqualStrings("3 before Ada", app.swapped.get());
    try testing.expectEqualStrings("Plain text", app.plain.get());

    var italian: i18n.Catalog = try .parse(gpa,
        \\msgid ""
        \\msgstr "Plural-Forms: nplurals=2; plural=(n != 1);\n"
        \\
        \\msgid "Hello, {}!"
        \\msgstr "Ciao, {}!"
        \\
        \\msgid "{n} file"
        \\msgid_plural "{n} files"
        \\msgstr[0] "{n} documento"
        \\msgstr[1] "{n} documenti"
        \\
        \\msgctxt "menu"
        \\msgid "Open"
        \\msgstr "Apri"
        \\
        \\msgid "{1} before {0}"
        \\msgstr "{0} dopo {1}"
        \\
    );
    defer italian.deinit();
    i18n.setTranslator(italian.translator());
    defer i18n.setTranslator(null);
    // Everything translated follows, without touching the component.
    try testing.expectEqualStrings("Ciao, Ada!", app.greeting.get());
    try testing.expectEqualStrings("3 documenti", app.files.get());
    try testing.expectEqualStrings("Apri", app.open.get());
    try testing.expectEqualStrings("Ada dopo 3", app.swapped.get());
    try testing.expectEqualStrings("Plain text", app.plain.get()); // not in the catalog
    app.count.set(1);
    app.name.set("Grace");
    try testing.expectEqualStrings("1 documento", app.files.get());
    try testing.expectEqualStrings("Ciao, Grace!", app.greeting.get());

    i18n.setTranslator(null);
    try testing.expectEqualStrings("Hello, Grace!", app.greeting.get());
}

// ---- accessibility ----

test "accessibility: the standard widgets describe themselves and take actions" {
    const a11y = zigulee.core.accessibility;
    const ui_w = @import("ui_widgets");
    const app = try ui_w.Widgets.create(gpa);
    defer app.destroy();
    const w = app.window();
    zigulee.runChangeHandlers();

    var tracker: a11y.Tracker = .init(gpa, w);
    defer tracker.deinit();
    var nodes = try tracker.update();
    const find = struct {
        fn by(list: []const a11y.Node, role: zigulee.core.AccessibleRole, label: []const u8) ?a11y.Node {
            for (list) |n| if (n.role == role and std.mem.eql(u8, n.label, label)) return n;
            return null;
        }
        fn count(list: []const a11y.Node, role: zigulee.core.AccessibleRole) usize {
            var k: usize = 0;
            for (list) |n| k += @intFromBool(n.role == role);
            return k;
        }
    };

    // Buttons, with their state; their text is not a node of its own.
    const button = find.by(nodes, .button, "Click").?;
    try testing.expect(button.enabled);
    try testing.expect(!find.by(nodes, .button, "Disabled").?.enabled);
    try testing.expect(find.by(nodes, .text, "Click") == null);
    try testing.expect(button.bounds.width > 0 and button.bounds.y >= 10);

    const check = find.by(nodes, .checkbox, "I agree").?;
    try testing.expect(check.checkable and !check.checked);
    try testing.expectEqual(@as(usize, 1), find.count(nodes, .switch_));
    const slider = find.by(nodes, .slider, "").?;
    try testing.expectEqualStrings("0", slider.value);
    try testing.expectEqual(@as(f32, 10), slider.value_maximum);
    try testing.expectEqual(@as(usize, 2), find.count(nodes, .text_input));
    for (nodes) |n| if (n.role == .text_input and n.placeholder_text.len > 0) {
        try testing.expectEqualStrings("Your name", n.placeholder_text);
    };
    // The LineEdit's placeholder is not read out twice.
    try testing.expect(find.by(nodes, .text, "Your name") == null);

    // Actions do what a click or a key would.
    try testing.expect(!tracker.isDirty());
    try testing.expect(a11y.perform(w, button.item, .default));
    try testing.expectEqual(@as(i32, 1), app.clicks.get());
    try testing.expect(a11y.perform(w, check.item, .default));
    try testing.expect(app.agree.get());
    // Without a step, by a hundredth of the range.
    try testing.expect(a11y.perform(w, slider.item, .increment));
    try testing.expect(a11y.perform(w, slider.item, .increment));
    try testing.expectApproxEqAbs(@as(f32, 0.2), app.volume.get(), 0.001);
    // Without a default action, the default is to focus it.
    try testing.expect(a11y.perform(w, slider.item, .default));
    try testing.expect(slider.item.contains(w.focus_item.?));
    _ = a11y.perform(w, find.by(nodes, .button, "Disabled").?.item, .default);
    try testing.expectEqual(@as(i32, 1), app.clicks.get()); // disabled
    // The snapshot follows.
    try testing.expect(tracker.isDirty());
    nodes = try tracker.update();
    try testing.expect(find.by(nodes, .checkbox, "I agree").?.checked);
    try testing.expectEqualStrings("0.2", find.by(nodes, .slider, "").?.value);
    try testing.expect(!tracker.isDirty());

    // Text fields: focus, value, and setting it.
    var field: ?a11y.Node = null;
    for (nodes) |n| if (n.role == .text_input and n.placeholder_text.len > 0) {
        field = n;
    };
    try testing.expect(a11y.perform(w, field.?.item, .focus));
    try testing.expect(a11y.setValue(field.?.item, "Ada"));
    try testing.expectEqualStrings("Ada", app.name_text.get());
    nodes = try tracker.update();
    for (nodes) |n| if (n.role == .text_input and n.placeholder_text.len > 0) {
        try testing.expect(n.focused);
        try testing.expectEqualStrings("Ada", n.value);
    };
}

// ---- the Patrisio example (a platformer in .zge) ----

const patrisio_ui = @import("patrisio_ui");

fn patrisioSteps(app: *patrisio_ui.PatrisioGame, n: usize) void {
    for (0..n) |_| {
        app.invoke_tick();
        zigulee.runChangeHandlers();
    }
}

test "patrisio: the keys start the game, waddle and jump" {
    const app = try patrisio_ui.PatrisioGame.create(gpa);
    defer app.destroy();
    const w = app.window();
    const Key = zigulee.core.input.Key;
    app.keys.focus();
    try testing.expectEqual(patrisio_ui.Phase.title, app.phase.get());
    w.dispatchKey(.pressed, .{ .text = Key.space });
    w.dispatchKey(.released, .{ .text = Key.space });
    try testing.expectEqual(patrisio_ui.Phase.playing, app.phase.get());
    try testing.expectEqual(@as(i32, 3), app.lives.get());

    // Right arrow held: he speeds up to a waddle, to the right.
    const x0 = app.px.get();
    w.dispatchKey(.pressed, .{ .text = Key.right_arrow });
    patrisioSteps(app, 30);
    try testing.expect(app.px.get() > x0 + 60);
    try testing.expectEqual(@as(f32, 4.6), app.vx.get());
    try testing.expectEqual(@as(f32, 1), app.facing.get());
    w.dispatchKey(.released, .{ .text = Key.right_arrow });
    patrisioSteps(app, 30);
    try testing.expectEqual(@as(f32, 0), app.vx.get());

    // Space: up, then back down on the ground; held, higher.
    const ground = app.py.get();
    w.dispatchKey(.pressed, .{ .text = Key.space });
    w.dispatchKey(.released, .{ .text = Key.space });
    var top = ground;
    for (0..60) |_| {
        patrisioSteps(app, 1);
        top = @min(top, app.py.get());
    }
    try testing.expect(app.on_ground.get());
    try testing.expectEqual(ground, app.py.get());
    w.dispatchKey(.pressed, .{ .text = Key.space });
    var high = ground;
    for (0..60) |_| {
        patrisioSteps(app, 1);
        high = @min(high, app.py.get());
    }
    w.dispatchKey(.released, .{ .text = Key.space });
    try testing.expect(ground - top > 50);
    try testing.expect(ground - high > ground - top + 20);
}

test "patrisio: blocks give fish, fish are taken, seals stomped, gaps fall" {
    const app = try patrisio_ui.PatrisioGame.create(gpa);
    defer app.destroy();
    app.invoke_start();
    const ground = app.py.get();

    // Under the first "?" block (x 380, bottom 300): a jump bumps it.
    app.px.set(383);
    app.camera.set(200);
    app.jump_wanted.set(8);
    app.jump_held.set(true);
    patrisioSteps(app, 50);
    try testing.expectEqual(@as(i32, 1), app.fish.get());
    try testing.expectEqual(@as(i32, 1), app.blocks_used.get());
    // A used block gives nothing more.
    app.jump_wanted.set(8);
    patrisioSteps(app, 50);
    try testing.expectEqual(@as(i32, 1), app.fish.get());
    try testing.expectEqual(ground, app.py.get());

    // Walking into a fish takes it (the first: x 300, at his height).
    app.px.set(260);
    app.camera.set(100);
    app.right.set(true);
    patrisioSteps(app, 12);
    app.right.set(false);
    try testing.expectEqual(@as(i32, 2), app.fish.get());
    try testing.expectEqual(@as(i32, 1), app.fish_taken.get());

    // Landing on a seal stomps it (and bounces him up).
    patrisioSteps(app, 30);
    app.frame.set(0); // the first seal back at x 700
    app.px.set(706);
    app.camera.set(500);
    app.py.set(ground - 80);
    app.vy.set(4);
    app.safe_until.set(1_000_000);
    var bounced = false;
    for (0..20) |_| {
        patrisioSteps(app, 1);
        if (app.vy.get() < 0) bounced = true;
        app.frame.set(0);
    }
    try testing.expect(bounced);
    try testing.expectEqual(@as(i32, 1), app.seals_down.get());
    try testing.expectEqual(@as(i32, 3), app.lives.get());

    // Walking into a gap (1200-1300): down, a life lost, back at the start.
    app.px.set(1180);
    app.py.set(ground);
    app.vy.set(0);
    app.camera.set(1000);
    app.right.set(true);
    for (0..200) |_| {
        patrisioSteps(app, 1);
        if (app.phase.get() == .ouch) break;
    }
    app.right.set(false);
    try testing.expectEqual(patrisio_ui.Phase.ouch, app.phase.get());
    try testing.expectEqual(@as(i32, 2), app.lives.get());
    patrisioSteps(app, 120);
    try testing.expectEqual(patrisio_ui.Phase.playing, app.phase.get());
    try testing.expectEqual(@as(f32, 80), app.px.get());
}

test "patrisio: home at the igloo; no lives left, game over" {
    const app = try patrisio_ui.PatrisioGame.create(gpa);
    defer app.destroy();
    app.invoke_start();
    app.px.set(6680);
    app.camera.set(6200);
    app.right.set(true);
    for (0..120) |_| {
        patrisioSteps(app, 1);
        if (app.phase.get() == .home) break;
    }
    try testing.expectEqual(patrisio_ui.Phase.home, app.phase.get());

    app.invoke_start();
    app.lives.set(1);
    app.py.set(500); // below the screen
    patrisioSteps(app, 2);
    try testing.expectEqual(patrisio_ui.Phase.ouch, app.phase.get());
    patrisioSteps(app, 120);
    try testing.expectEqual(patrisio_ui.Phase.game_over, app.phase.get());
}

test "patrisio: the GPU renderer's partial frames show what a full frame shows" {
    for ([_]f32{ 1, 2, 1.5 }) |scale| try patrisioGpuFrames(scale);
}

fn patrisioGpuFrames(scale: f32) !void {
    const app = try patrisio_ui.PatrisioGame.create(gpa);
    defer app.destroy();
    const w = app.window();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "examples/fonts/inter/Inter-Regular.ttf", gpa, .limited(16 << 20));
    defer gpa.free(bytes);
    const font: zigulee.Font = try .init(bytes);
    w.default_font.set(&font);
    try w.registerFont("Inter", 700, &font);
    const width: u32 = @intFromFloat(800 * scale);
    const height: u32 = @intFromFloat(450 * scale);
    var batcher: zigulee.gpu.Batcher = try .init(gpa);
    defer batcher.deinit();
    var software: zigulee.software.Renderer(zigulee.core.Rgba8) = .init(gpa);
    defer software.deinit();
    batcher.scale_factor = scale;
    software.scale_factor = scale;
    const gpu_pixels = try gpa.alloc(zigulee.core.Rgba8, width * height);
    defer gpa.free(gpu_pixels);
    const sw_pixels = try gpa.alloc(zigulee.core.Rgba8, width * height);
    defer gpa.free(sw_pixels);
    @memset(gpu_pixels, .transparent);

    app.invoke_start();
    app.right.set(true);
    var worst: usize = 0;
    var worst_frame: usize = 0;
    for (0..150) |f| {
        app.invoke_tick();
        zigulee.runChangeHandlers();
        const frame = try batcher.build(w, width, height, if (f == 0) .full else .partial);
        zigulee.gpu.reference.execute(&frame, gpu_pixels);
        @memset(sw_pixels, .transparent);
        _ = try software.renderWindow(w, .init(sw_pixels, width, height), .full);
        var off: usize = 0;
        for (gpu_pixels, sw_pixels) |a, b| {
            inline for (.{ "r", "g", "b", "a" }) |ch| {
                if (@abs(@as(i16, @field(a, ch)) - @field(b, ch)) > 8) {
                    off += 1;
                    break;
                }
            }
        }
        if (off > worst) {
            worst = off;
            worst_frame = f;
        }
    }
    if (worst > 0) std.debug.print("at {d}x, worst frame {d}: {d} pixels differ\n", .{ scale, worst_frame, worst });
    try testing.expectEqual(@as(usize, 0), worst);
}

// ---- the video example: a VideoPlayer ----

const video_demo = @import("video_ui");

test "video: the player plays the clip; a click on the picture pauses it" {
    const app = try video_demo.VideoDemo.create(gpa);
    defer app.destroy();
    const w = app.window();
    var threaded: std.Io.Threaded = .init_single_threaded;
    for (0..2000) |_| {
        zigulee.updateTimersAndAnimations(zigulee.core.now() + 1);
        zigulee.runChangeHandlers();
        if (app.player.video.image.source.get() != null) break;
        threaded.io().sleep(.fromMilliseconds(1), .awake) catch {};
    }
    // 48 frames of 40 ms, playing (the binding in video.zge).
    try testing.expectEqual(@as(i64, 1920), app.player.duration.get());
    try testing.expect(app.player.playing.get());
    try testing.expect(!app.player.paused.get());
    const frame = app.player.video.image.source.get().?;
    try testing.expectEqual(@as(u32, 320), frame.width);

    const g = app.player.rootItem().absoluteGeometry();
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = g.x + g.width / 2, .y = g.y + g.height / 3 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = g.x + g.width / 2, .y = g.y + g.height / 3 } } });
    zigulee.runChangeHandlers();
    try testing.expect(app.player.paused.get());
    try testing.expect(app.player.playing.get());
}

test "video: paused, a seek on the bar shows that frame; looping, the position stays within the clip" {
    const app = try video_demo.VideoDemo.create(gpa);
    defer app.destroy();
    const w = app.window();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const settle = struct {
        fn run(t: *std.Io.Threaded, ms: u64) void {
            for (0..ms) |_| {
                zigulee.updateTimersAndAnimations(zigulee.core.now() + 1);
                zigulee.runChangeHandlers();
                t.io().sleep(.fromMilliseconds(1), .awake) catch {};
            }
        }
    }.run;
    settle(&threaded, 100);
    try testing.expect(app.player.video.image.source.get() != null);

    // Looping: after more than one loop, the position is within the clip.
    settle(&threaded, 2500);
    try testing.expect(app.player.playing.get());
    try testing.expect(app.player.position.get() <= 1920);

    // Paused, a click at three quarters of the bar seeks there.
    app.player.paused.set(true);
    settle(&threaded, 20);
    const before = app.player.video.image.source.get().?;
    const g = app.player.seek.item.absoluteGeometry();
    const at: zigulee.core.Point = .{ .x = g.x + g.width * 0.75, .y = g.y + g.height / 2 };
    w.dispatchPointer(.{ .moved = .{ .position = at } });
    w.dispatchPointer(.{ .pressed = .{ .position = at } });
    settle(&threaded, 5);
    w.dispatchPointer(.{ .released = .{ .position = at } });
    settle(&threaded, 50);
    const pos = app.player.position.get();
    try testing.expect(pos > 1300 and pos < 1600);
    try testing.expect(app.player.paused.get());
    // Another frame shows: the one at the new position.
    try testing.expect(!app.player.video.image.source.get().?.eql(before));
}

test "gallery: tumblers turn by wheel, click, keys, drag and from code" {
    const app = try gallery.Gallery.create(gpa);
    defer app.destroy();
    const w = app.window();
    app.tab.set(3);
    var t = zigulee.core.now();
    const settle = struct {
        fn run(clock: *u64) void {
            for (0..40) |_| {
                clock.* += 10;
                zigulee.updateTimersAndAnimations(clock.*);
                zigulee.runChangeHandlers();
            }
        }
    };
    settle.run(&t);
    try testing.expectEqual(@as(i32, 7), app.hour.get());
    try testing.expectEqualStrings("07", app.hours.current_value.get());

    const g = app.hours.rootItem().absoluteGeometry();
    const mid: zigulee.core.Point = .{ .x = g.x + g.width / 2, .y = g.y + g.height / 2 };
    const row: f32 = g.height / 5;

    // The wheel: one item a step.
    w.dispatchPointer(.{ .wheel = .{ .position = mid, .delta = .{ .y = -3 } } });
    settle.run(&t);
    try testing.expectEqual(@as(i32, 8), app.hour.get());

    // A click on the item below the middle turns to it.
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = mid.x, .y = mid.y + row } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = mid.x, .y = mid.y + row } } });
    settle.run(&t);
    try testing.expectEqual(@as(i32, 9), app.hour.get());

    // Keys (the click gave it the focus).
    try testing.expect(app.hours.has_focus.get());
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.down_arrow });
    settle.run(&t);
    try testing.expectEqual(@as(i32, 10), app.hour.get());
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.home });
    settle.run(&t);
    try testing.expectEqual(@as(i32, 0), app.hour.get());

    // A drag up by two rows and a bit, released at rest: settles on 2.
    w.dispatchPointer(.{ .pressed = .{ .position = mid } });
    t += 10;
    zigulee.updateTimersAndAnimations(t);
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = mid.x, .y = mid.y - 2.3 * row } } });
    t += 300;
    zigulee.updateTimersAndAnimations(t);
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = mid.x, .y = mid.y - 2.3 * row } } });
    settle.run(&t);
    try testing.expectEqual(@as(i32, 2), app.hour.get());

    // From code, far: it turns all the way there.
    app.hour.set(20);
    settle.run(&t);
    try testing.expectEqual(@as(i32, 20), app.hour.get());
    try testing.expectEqualStrings("20", app.hours.current_value.get());
}

test "gallery: the menu bar, a context menu and a tooltip" {
    const app = try gallery.Gallery.create(gpa);
    defer app.destroy();
    defer app.dark.set(false); // the palette is a global
    const w = app.window();
    var t = zigulee.core.now();
    const step = struct {
        fn run(clock: *u64, ms: u64) void {
            var left = ms;
            while (left > 0) : (left -= 10) {
                clock.* += 10;
                zigulee.updateTimersAndAnimations(clock.*);
                zigulee.runChangeHandlers();
            }
        }
    }.run;
    const center = struct {
        fn of(item: *zigulee.core.Item) zigulee.core.Point {
            const g = item.absoluteGeometry();
            return .{ .x = g.x + g.width / 2, .y = g.y + g.height / 2 };
        }
    }.of;
    const tap = struct {
        fn at(win: *zigulee.Window, p: zigulee.core.Point, button: zigulee.core.input.PointerButton) void {
            win.dispatchPointer(.{ .moved = .{ .position = p } });
            win.dispatchPointer(.{ .pressed = .{ .position = p, .button = button } });
            win.dispatchPointer(.{ .released = .{ .position = p, .button = button } });
            zigulee.runChangeHandlers();
        }
    }.at;
    step(&t, 20);

    // View > Lists: the menu opens under its title; a click picks an item
    // and closes it.
    tap(w, center(app.view_menu.rootItem()), .left);
    try testing.expect(app.view_menu.menu.root.is_open.get());
    const menu = app.view_menu.menu.rootItem().absoluteGeometry();
    try testing.expect(menu.y >= app.view_menu.rootItem().absoluteGeometry().y + 29);
    // Items: Dark mode (30), separator (9), Controls, Lists (30 each),
    // from 5 px in.
    tap(w, .{ .x = menu.x + 40, .y = menu.y + 5 + 30 + 9 + 30 + 15 }, .left);
    try testing.expect(!app.view_menu.menu.root.is_open.get());
    try testing.expectEqual(@as(i32, 1), app.tab.get());

    // A right click near the bottom-right corner: the context menu opens
    // there, inside the window; the keys pick "Dark mode".
    app.tab.set(3); // empty space on the Time tab
    step(&t, 20);
    const size = w.size();
    tap(w, .{ .x = size.width - 30, .y = size.height - 60 }, .right);
    try testing.expect(app.context.root.is_open.get());
    const ctx = app.context.rootItem().absoluteGeometry();
    try testing.expect(ctx.x + ctx.width <= size.width and ctx.y + ctx.height <= size.height);
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.down_arrow });
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.@"return" });
    zigulee.runChangeHandlers();
    try testing.expect(!app.context.root.is_open.get());
    try testing.expect(app.dark.get());
    // Its "Go to" submenu, with the keys: up to it (the last entry), into
    // it, down to Calendar.
    tap(w, .{ .x = size.width - 30, .y = size.height - 60 }, .right);
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.up_arrow });
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.right_arrow });
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.down_arrow });
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.down_arrow });
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.@"return" });
    zigulee.runChangeHandlers();
    try testing.expect(!app.context.root.is_open.get());
    try testing.expectEqual(@as(i32, 2), app.tab.get());

    // The tooltip: after resting on the button a while; it takes no input
    // (the click counts), and goes when the pointer leaves.
    app.tab.set(0);
    step(&t, 20);
    const b = center(app.click.rootItem());
    w.dispatchPointer(.{ .moved = .{ .position = b } });
    zigulee.runChangeHandlers();
    step(&t, 300);
    try testing.expect(!app.click_tip.root.is_open.get());
    step(&t, 500);
    try testing.expect(app.click_tip.root.is_open.get());
    tap(w, b, .left);
    try testing.expectEqual(@as(i32, 1), app.clicks.get());
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = 5, .y = size.height - 5 } } });
    zigulee.runChangeHandlers();
    step(&t, 20);
    try testing.expect(!app.click_tip.root.is_open.get());
}

test "gallery: dialogs are modal, keep the focus, take Escape and Return" {
    const app = try gallery.Gallery.create(gpa);
    defer app.destroy();
    const w = app.window();
    var t = zigulee.core.now();
    const step = struct {
        fn run(clock: *u64) void {
            for (0..3) |_| {
                clock.* += 10;
                zigulee.updateTimersAndAnimations(clock.*);
                zigulee.runChangeHandlers();
            }
        }
    }.run;
    const tap = struct {
        fn at(win: *zigulee.Window, p: zigulee.core.Point) void {
            win.dispatchPointer(.{ .moved = .{ .position = p } });
            win.dispatchPointer(.{ .pressed = .{ .position = p } });
            win.dispatchPointer(.{ .released = .{ .position = p } });
            zigulee.runChangeHandlers();
        }
    }.at;
    const center = struct {
        fn of(item: *zigulee.core.Item) zigulee.core.Point {
            const g = item.absoluteGeometry();
            return .{ .x = g.x + g.width / 2, .y = g.y + g.height / 2 };
        }
    }.of;
    step(&t);
    const click_me = center(app.click.rootItem());
    tap(w, click_me);
    tap(w, click_me);
    try testing.expectEqual(@as(i32, 2), app.clicks.get());

    // File > Reset clicks…: the dialog covers the window.
    tap(w, center(app.file_menu.rootItem()));
    const m = app.file_menu.menu.rootItem().absoluteGeometry();
    // Open images…, Save as… (30 each), a separator (9), Reset clicks….
    tap(w, .{ .x = m.x + 40, .y = m.y + 5 + 30 + 30 + 9 + 15 });
    step(&t);
    const dialog = &app.confirm_reset.root;
    try testing.expect(dialog.is_open.get());
    try testing.expectEqual(w.size(), app.confirm_reset.rootItem().size());

    // Modal: the button behind does not count the click.
    tap(w, click_me);
    try testing.expect(dialog.is_open.get());
    try testing.expectEqual(@as(i32, 2), app.clicks.get());

    // Tab goes round the dialog's buttons only.
    for (0..6) |_| {
        w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.tab });
        try testing.expect(w.focus_item != null);
        var it: ?*zigulee.core.Item = w.focus_item;
        var inside = false;
        while (it) |item| : (it = item.parent) {
            if (item == app.confirm_reset.rootItem()) inside = true;
        }
        try testing.expect(inside);
    }

    // Escape: cancelled, nothing changes.
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.escape });
    step(&t);
    try testing.expect(!dialog.is_open.get());
    try testing.expectEqual(@as(i32, 2), app.clicks.get());

    // Again, from the context menu: Return resets.
    const size = w.size();
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 10, .y = size.height - 40 }, .button = .right } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 10, .y = size.height - 40 }, .button = .right } });
    zigulee.runChangeHandlers();
    const c = app.context.rootItem().absoluteGeometry();
    tap(w, .{ .x = c.x + 40, .y = c.y + 5 + 30 + 9 + 15 });
    step(&t);
    try testing.expect(dialog.is_open.get());
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.@"return" });
    step(&t);
    try testing.expect(!dialog.is_open.get());
    try testing.expectEqual(@as(i32, 0), app.clicks.get());

    // Help > About…: a message; its OK closes it.
    tap(w, center(app.help_menu.rootItem()));
    const h = app.help_menu.menu.rootItem().absoluteGeometry();
    tap(w, .{ .x = h.x + 40, .y = h.y + 5 + 15 });
    step(&t);
    try testing.expect(app.about.root.root.is_open.get());
    const p = app.about.root.panel.item.absoluteGeometry();
    tap(w, .{ .x = p.x + p.width - 60, .y = p.y + p.height - 36 });
    step(&t);
    try testing.expect(!app.about.root.root.is_open.get());
}

/// File dialogs answered by the test.
const TestDialogs = struct {
    pending: ?*zigulee.core.dialogs.Pending = null,
    fn provider(self: *TestDialogs) zigulee.core.dialogs.Provider {
        return .{ .ctx = self, .show = show };
    }
    fn show(ctx: ?*anyopaque, p: *zigulee.core.dialogs.Pending) void {
        const self: *TestDialogs = @ptrCast(@alignCast(ctx));
        self.pending = p;
    }
};

test "gallery: File > Open images… lists the files chosen" {
    var dialogs: TestDialogs = .{};
    zigulee.core.dialogs.setFileDialogs(dialogs.provider());
    defer zigulee.core.dialogs.setFileDialogs(null);
    const app = try gallery.Gallery.create(gpa);
    defer app.destroy();
    const w = app.window();
    zigulee.runChangeHandlers();
    const g = app.file_menu.rootItem().absoluteGeometry();
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = g.x + 5, .y = g.y + 5 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = g.x + 5, .y = g.y + 5 } } });
    zigulee.runChangeHandlers();
    const m = app.file_menu.menu.rootItem().absoluteGeometry();
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = m.x + 40, .y = m.y + 20 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = m.x + 40, .y = m.y + 20 } } });
    zigulee.runChangeHandlers();
    const p = dialogs.pending.?;
    try testing.expectEqual(zigulee.core.dialogs.FileDialogMode.open_files, p.request.mode);
    try testing.expectEqualStrings("Open images", p.request.title);
    try testing.expectEqualStrings("Images", p.request.filters[0].name);
    p.finish(&.{ "/pictures/snow.png", "/pictures/ice.jpg" });
    zigulee.updateTimersAndAnimations(zigulee.core.now() + 1);
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(usize, 2), app.open_dialog.selected_files.get().rowCount());
    try testing.expectEqualStrings("/pictures/ice.jpg", app.open_dialog.selected_files.get().rowData(1).?);
}

test "rotation, scale and transform origin bindings" {
    const t0 = zigulee.core.now();
    const app = try ui.App.create(gpa);
    defer app.destroy();
    const t = app.tilted.item.transform.?;
    try testing.expectEqual(@as(f32, 0), t.rotation.get());
    try testing.expectEqual(@as(f32, 1.25), t.scale_x.get());
    try testing.expectEqual(@as(f32, 1), t.scale_y.get());
    try testing.expectEqual(@as(?f32, 0), t.origin_x.get());
    try testing.expectEqual(@as(?f32, null), t.origin_y.get());
    app.count.set(3);
    _ = t.rotation.get(); // starts the animation
    zigulee.updateTimersAndAnimations(t0 + 50);
    const mid = t.rotation.get();
    try testing.expect(mid > 0 and mid < 60);
    zigulee.updateTimersAndAnimations(t0 + 100);
    try testing.expectEqual(@as(f32, 60), t.rotation.get());
    // Turned about its left middle: its right end lands lower, to the right.
    const m = app.tilted.item.windowTransform();
    const end = m.apply(.{ .x = 60, .y = 8 });
    try testing.expectApproxEqAbs(@as(f32, 200 + 75 * 0.5), end.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 158 + 75 * @sqrt(3.0) / 2.0), end.y, 0.01);
}

test "drop shadows, on a rectangle and on a component's instance" {
    const app = try ui.App.create(gpa);
    defer app.destroy();
    const d = app.tilted.shadow.?;
    try testing.expectEqual(@as(f32, 3), d.offset_x.get());
    try testing.expectEqual(@as(f32, 6), d.blur.get());
    try testing.expect(std.meta.eql(zigulee.Color.rgba(0x00000080), d.color.get()));
    app.count.set(2);
    try testing.expect(std.meta.eql(zigulee.Color.rgba(0xff000080), d.color.get()));
    const b = app.button.root.shadow.?;
    try testing.expectEqual(@as(f32, 4), b.blur.get());
    try testing.expect(app.button.root.item.transform != null);
}

test "loops and local variables in functions and handlers" {
    const app = try language.Language.create(gpa);
    defer app.destroy();
    try testing.expectEqual(@as(i32, 1 + 3 + 5 + 7 + 9), app.odd_sum.get());
    try testing.expectEqualStrings("Ada (36), Grace (85)...", app.roll.get());
    var one: zigulee.core.SliceModel(language.Contact) = .init(&.{.{ .name = "Linus", .age = 29 }});
    defer one.deinit();
    app.contacts.set(one.model());
    try testing.expectEqualStrings("Linus (29)...", app.roll.get());
    app.grow.call(.{});
    try testing.expectEqual(@as(i32, 32), app.grown.get());
}

test "components as values: a Loader, its inputs, a delegate property" {
    const lui = @import("ui_loader");
    const app = try lui.Loaders.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    try testing.expect(app.page_loaded.get());
    try testing.expect(app.is_card.get());
    // The page is a Card, given its label.
    const card: *lui.Card = @ptrCast(@alignCast(app.page.instance.?));
    try testing.expectEqualStrings("page", card.label.get());
    app.heading.set("renamed");
    zigulee.runChangeHandlers();
    try testing.expectEqualStrings("renamed", card.label.get());

    // Rows made with the delegate, given each row and its index (each
    // Loader under the list, in order).
    var rows: usize = 0;
    var stack: [16]*zigulee.Item = undefined;
    var depth: usize = 1;
    stack[0] = app.rows.rootItem();
    var order: [8]*zigulee.items.Loader = undefined;
    while (depth > 0) {
        depth -= 1;
        const item = stack[depth];
        if (std.mem.eql(u8, item.vtable.name, "Loader")) {
            order[rows] = @fieldParentPtr("item", item);
            rows += 1;
            continue;
        }
        // Children pushed last first: popped in order.
        var kids: [8]*zigulee.Item = undefined;
        var n: usize = 0;
        var child = item.first_child;
        while (child) |c| : (child = c.next_sibling) {
            kids[n] = c;
            n += 1;
        }
        while (n > 0) {
            n -= 1;
            stack[depth] = kids[n];
            depth += 1;
        }
    }
    for (order[0..rows], 0..) |l, k| {
        const row: *lui.Card = @ptrCast(@alignCast(l.instance.?));
        try testing.expectEqual(@as(i32, @intCast(k)), row.index.get());
    }
    try testing.expectEqual(@as(usize, 3), rows);

    // Another component: the page and the rows are made again.
    app.plain.set(true);
    app.row_kind.set(&lui.Plain.factory);
    zigulee.runChangeHandlers();
    try testing.expect(!app.is_card.get());
    const plain: *lui.Plain = @ptrCast(@alignCast(app.page.instance.?));
    try testing.expectEqualStrings("renamed", plain.label.get());
    // Not active: nothing shown.
    app.showing.set(false);
    zigulee.runChangeHandlers();
    try testing.expect(!app.page_loaded.get());
    try testing.expect(app.page.item.first_child == null);
}

test "connections: handlers added to other elements' callbacks" {
    const cui = @import("ui_connections");
    const app = try cui.Conns.create(gpa);
    defer app.destroy();
    const w = app.window();
    const tap = struct {
        fn f(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
        }
    }.f;
    tap(w, 50, 50);
    // The counter's own handler gives the result; both connections ran.
    try testing.expectEqual(@as(i32, 10), app.counter.answered.get());
    try testing.expectEqual(@as(i32, 1), app.heard.get());
    try testing.expectEqual(@as(i32, 1), app.heard_all.get());
    tap(w, 50, 50);
    try testing.expectEqual(@as(i32, 2), app.heard.get());
    try testing.expectEqual(@as(i32, 3), app.heard_all.get());
    // Disabled: that one stops; the other goes on.
    app.listening.set(false);
    tap(w, 50, 50);
    try testing.expectEqual(@as(i32, 3), app.heard.get());
    try testing.expectEqual(@as(i32, 3), app.heard_all.get());
    // A global's callback: its handler, then the connection.
    tap(w, 150, 50);
    try testing.expectEqual(@as(i32, 5), app.pings.get());
    try testing.expectEqual(@as(i32, 5), cui.Bus.instance.last.get());
}

test "connections to a global come out with their component" {
    const cui = @import("ui_connections");
    // Connected first, so under the other one in the chain.
    const gone = try cui.Conns.create(gpa);
    const keep = try cui.Conns.create(gpa);
    defer keep.destroy();
    cui.Bus.instance.ping.call(.{2});
    try testing.expectEqual(@as(i32, 2), gone.pings.get());
    try testing.expectEqual(@as(i32, 2), keep.pings.get());
    gone.destroy();
    // Out of the middle of the chain: the global's handler and the other
    // app's connection still run.
    cui.Bus.instance.ping.call(.{7});
    try testing.expectEqual(@as(i32, 7), cui.Bus.instance.last.get());
    try testing.expectEqual(@as(i32, 9), keep.pings.get());
    // A global with only callbacks.
    cui.Signals.instance.idle.call(.{});
    try testing.expectEqual(@as(i32, 109), keep.pings.get());
}

test "animations started from code: a sequence, a pause, a parallel group" {
    const tui = @import("ui_timeline");
    const app = try tui.Timeline.create(gpa);
    defer app.destroy();
    var now = zigulee.core.now();
    const step = struct {
        fn f(t: *u64, ms: u64) void {
            t.* += ms;
            zigulee.updateTimersAndAnimations(t.*);
            zigulee.runChangeHandlers();
        }
    }.f;
    zigulee.runChangeHandlers();
    // The pulse runs by itself, forever.
    step(&now, 200);
    try testing.expect(app.pulse.node.running.get());
    try testing.expectApproxEqAbs(@as(f32, 0.6), app.dot.item.opacity.get(), 0.05);

    // Started by a click.
    app.window().dispatchPointer(.{ .pressed = .{ .position = .{ .x = 100, .y = 100 } } });
    app.window().dispatchPointer(.{ .released = .{ .position = .{ .x = 100, .y = 100 } } });
    try testing.expect(app.busy.get());
    step(&now, 150);
    const mid = app.box.item.x.get();
    try testing.expect(mid > 20 and mid < 140);
    step(&now, 200); // 350: in the pause, x done
    try testing.expectEqual(@as(f32, 120), app.box.item.x.get());
    try testing.expectEqual(@as(f32, 0), app.box.item.y.get());
    step(&now, 150); // 500: the group, halfway down
    try testing.expectApproxEqAbs(@as(f32, 30), app.box.item.y.get(), 3);
    step(&now, 300); // past the end
    try testing.expectEqual(@as(f32, 60), app.box.item.y.get());
    try testing.expect(app.box.background.get().eql(.color(.rgb(0x16a34a))));
    try testing.expect(!app.busy.get());
    try testing.expectEqual(@as(i32, 1), app.ends.get());
    try testing.expect(app.pulse.node.running.get());
}

test "sorted and filtered models follow their source and what they read" {
    const app = try language.Language.create(gpa);
    defer app.destroy();
    // Ada 36, Grace 85: those 40 and over, by name, reversed.
    try testing.expectEqualStrings("Grace;", app.elder_names.get());
    app.min_age.set(30);
    try testing.expectEqualStrings("Grace;Ada;", app.elder_names.get());
    var more: zigulee.core.SliceModel(language.Contact) = .init(&.{
        .{ .name = "Linus", .age = 55 },
        .{ .name = "Barbara", .age = 30 },
        .{ .name = "Edsger", .age = 20 },
    });
    defer more.deinit();
    app.contacts.set(more.model());
    try testing.expectEqualStrings("Linus;Barbara;", app.elder_names.get());

    const words = app.sorted_words.get();
    try testing.expectEqual(@as(usize, 3), words.rowCount());
    try testing.expectEqualStrings("apple", words.rowData(0).?);
    try testing.expectEqualStrings("fig", words.rowData(1).?);
    try testing.expectEqualStrings("pear", words.rowData(2).?);
}

test "drag and drop within the application" {
    const dui = @import("ui_dnd");
    const app = try dui.Dnd.create(gpa);
    defer app.destroy();
    const w = app.window();
    const at = struct {
        fn f(x: f32, y: f32) zigulee.core.Point {
            return .{ .x = x, .y = y };
        }
    }.f;
    w.dispatchPointer(.{ .pressed = .{ .position = at(100, 105) } });
    w.dispatchPointer(.{ .moved = .{ .position = at(140, 60) } });
    try testing.expect(app.card.dragging.get());
    w.dispatchPointer(.{ .moved = .{ .position = at(160, 30) } });
    try testing.expect(app.bin.contains_drag.get());
    try testing.expectEqual(@as(f32, 60), app.card.offset_x.get());
    w.dispatchPointer(.{ .released = .{ .position = at(160, 30) } });
    try testing.expectEqualStrings("ace", app.in_bin.get());
    try testing.expectEqual(@as(i32, 1), app.drops.get());
    try testing.expect(app.last_dropped.get());

    // Onto the area that takes files only: not dropped.
    w.dispatchPointer(.{ .pressed = .{ .position = at(100, 105) } });
    w.dispatchPointer(.{ .moved = .{ .position = at(40, 30) } });
    w.dispatchPointer(.{ .released = .{ .position = at(40, 30) } });
    try testing.expectEqual(@as(i32, 1), app.drops.get());
    try testing.expect(!app.last_dropped.get());
}

test "a touch area's pointer events and double clicks" {
    const gui = @import("ui_gestures");
    const app = try gui.Gestures.create(gpa);
    defer app.destroy();
    const w = app.window();
    const at: zigulee.core.Point = .{ .x = 100, .y = 50 };
    // Two clicks: a tap, then a double tap instead; a third starts again.
    for (0..3) |_| {
        w.dispatchPointer(.{ .pressed = .{ .position = at } });
        w.dispatchPointer(.{ .released = .{ .position = at } });
    }
    try testing.expectEqual(@as(i32, 2), app.taps.get());
    try testing.expectEqual(@as(i32, 1), app.double_taps.get());
    // Too far apart: no double tap.
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 150, .y = 50 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 150, .y = 50 } } });
    try testing.expectEqual(@as(i32, 3), app.taps.get());
    try testing.expectEqual(@as(i32, 1), app.double_taps.get());
    try testing.expectEqualStrings("dudududu", app.events.get());
    // The right button; a move over it; a drag the swipe area takes.
    app.events.set("");
    w.dispatchPointer(.{ .pressed = .{ .position = at, .button = .right } });
    w.dispatchPointer(.{ .released = .{ .position = at, .button = .right } });
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = 101, .y = 50 } } });
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 40, .y = 50 } } });
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = 140, .y = 52 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 140, .y = 52 } } });
    try testing.expectEqualStrings("right", app.last_swipe.get());
    try testing.expectEqualStrings("dRuRmdc", app.events.get());
}

test "swipes and pinches, with fingers" {
    const gui = @import("ui_gestures");
    const app = try gui.Gestures.create(gpa);
    defer app.destroy();
    const w = app.window();
    const touch = zigulee.core.gestures.dispatchTouch;
    // A tap goes through the swipe area.
    touch(w, 1, .down, .{ .x = 100, .y = 50 });
    touch(w, 1, .up, .{ .x = 100, .y = 50 });
    try testing.expectEqual(@as(i32, 1), app.taps.get());
    // A swipe right.
    touch(w, 2, .down, .{ .x = 40, .y = 50 });
    touch(w, 2, .moved, .{ .x = 80, .y = 52 });
    try testing.expect(app.swipe.swiping.get());
    touch(w, 2, .moved, .{ .x = 140, .y = 55 });
    touch(w, 2, .up, .{ .x = 140, .y = 55 });
    try testing.expectEqualStrings("right", app.last_swipe.get());
    try testing.expectEqual(@as(i32, 1), app.taps.get());
    // Two fingers spread three times as far: zoomed by 3.
    touch(w, 3, .down, .{ .x = 90, .y = 120 });
    touch(w, 4, .down, .{ .x = 110, .y = 120 });
    touch(w, 4, .moved, .{ .x = 150, .y = 120 });
    try testing.expect(app.pinch.active.get());
    touch(w, 4, .up, .{ .x = 150, .y = 120 });
    touch(w, 3, .up, .{ .x = 90, .y = 120 });
    try testing.expectApproxEqAbs(@as(f32, 3), app.zoom.get(), 0.01);
    // Each finger's every step was activity.
    try testing.expectEqual(@as(i32, 11), app.activity.get());
    // A second after the last finger, asleep; a touch wakes it.
    zigulee.runChangeHandlers();
    const now = zigulee.core.now();
    zigulee.updateTimersAndAnimations(now + 900);
    try testing.expect(!app.asleep.get());
    zigulee.updateTimersAndAnimations(now + 1100);
    zigulee.runChangeHandlers();
    try testing.expect(app.asleep.get());
    try testing.expect(!app.idle.running.get());
    touch(w, 5, .down, .{ .x = 100, .y = 50 });
    try testing.expect(!app.asleep.get());
    touch(w, 5, .up, .{ .x = 100, .y = 50 });
}

test "menu bar shortcuts work with the menus closed" {
    const app = try gallery.Gallery.create(gpa);
    defer app.destroy();
    defer app.dark.set(false); // the palette is a global
    const primary: zigulee.core.input.Modifiers = if (@import("builtin").os.tag == .macos) .{ .meta = true } else .{ .control = true };
    const w = app.window();
    try testing.expect(!app.dark.get());
    // The menus' items (and their shortcuts) are made by repeaters, when
    // change handlers first run (in an app, before any key).
    zigulee.runChangeHandlers();
    w.dispatchKey(.pressed, .{ .text = "d", .modifiers = primary });
    try testing.expect(app.dark.get());
    w.dispatchKey(.pressed, .{ .text = "d", .modifiers = primary });
    try testing.expect(!app.dark.get());
    // A disabled item's shortcut does nothing ("Reset clicks…" without
    // clicks).
    try testing.expectEqual(@as(i32, 0), app.clicks.get());
    w.dispatchKey(.pressed, .{ .text = "r", .modifiers = primary });
    zigulee.runChangeHandlers();
    try testing.expect(!app.confirm_reset.root.is_open.get());
}

test "radio buttons, a button group, containers and a tool bar" {
    const mui = @import("ui_widgets2");
    const app = try mui.MoreWidgets.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    const w = app.window();
    const clickOn = struct {
        fn f(win: *zigulee.Window, item: *zigulee.Item) void {
            const p = item.windowTransform().apply(.{ .x = item.width.get() / 2, .y = item.height.get() / 2 });
            win.dispatchPointer(.{ .pressed = .{ .position = p } });
            win.dispatchPointer(.{ .released = .{ .position = p } });
        }
    }.f;
    // Tool buttons: a click, and a checkable one.
    clickOn(w, app.save.rootItem());
    try testing.expectEqual(@as(i32, 1), app.saves.get());
    clickOn(w, app.bold_button.rootItem());
    try testing.expect(app.bold.get());
    clickOn(w, app.bold_button.rootItem());
    try testing.expect(!app.bold.get());
    // Radio buttons: checked by a click, not unchecked by another.
    try testing.expect(app.align_left.checked.get());
    clickOn(w, app.align_right.rootItem());
    try testing.expect(!app.left.get());
    try testing.expect(app.align_right.checked.get());
    try testing.expect(!app.align_left.checked.get());
    clickOn(w, app.align_right.rootItem());
    try testing.expect(app.align_right.checked.get());
    // And back: the bindings of `checked` are still there.
    clickOn(w, app.align_left.rootItem());
    try testing.expect(app.left.get());
    try testing.expect(app.align_left.checked.get());
    try testing.expect(!app.align_right.checked.get());
    clickOn(w, app.align_right.rootItem());
    try testing.expect(!app.align_left.checked.get());
    // The group: Medium checked; Large chosen from code.
    try testing.expectEqual(@as(i32, 1), app.size.get());
    app.sizes.invoke_choose(2);
    try testing.expectEqual(@as(i32, 2), app.size.get());
    try testing.expectEqualStrings("Large", app.chosen_size.get());
    // The arrow keys: back up to Small, and no further.
    w.setFocusItem(app.sizes.rootItem());
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.up_arrow });
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.up_arrow });
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.up_arrow });
    try testing.expectEqual(@as(i32, 0), app.size.get());
    try testing.expectEqualStrings("Small", app.chosen_size.get());
    // A row: its two buttons side by side, and only those.
    const count = struct {
        fn radios(item: *zigulee.Item) usize {
            var n: usize = if (std.mem.indexOf(u8, item.vtable.name, "Empty") != null and item.accessible != null and item.accessible.?.role.get() == .radio_button) 1 else 0;
            var it = item.first_child;
            while (it) |c| : (it = c.next_sibling) {
                if (c.visible.get()) n += radios(c);
            }
            return n;
        }
    }.radios;
    try testing.expectEqual(@as(usize, 2), count(app.row.rootItem()));
    // Clicked one after another, one checked at a time.
    const nth = struct {
        fn radio(item: *zigulee.Item, n: *usize) ?*zigulee.Item {
            if (std.mem.indexOf(u8, item.vtable.name, "Empty") != null and item.accessible != null and item.accessible.?.role.get() == .radio_button) {
                if (n.* == 0) return item;
                n.* -= 1;
            }
            var it = item.first_child;
            while (it) |c| : (it = c.next_sibling) {
                if (c.visible.get()) if (radio(c, n)) |r| return r;
            }
            return null;
        }
    }.radio;
    for ([_]usize{ 1, 2, 0, 1, 2 }) |want| {
        var n = want;
        clickOn(w, nth(app.sizes.rootItem(), &n).?);
        zigulee.runChangeHandlers();
        try testing.expectEqual(@as(i32, @intCast(want)), app.size.get());
        for (0..3) |i| {
            var k = i;
            try testing.expectEqual(i == want, nth(app.sizes.rootItem(), &k).?.accessible.?.checked.get());
        }
    }
}

test "pages: a stack layout, a swipe view and its dots, a stack view" {
    const pui = @import("ui_pages");
    const app = try pui.Pages.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    var now = zigulee.core.now();
    const step = struct {
        fn f(t: *u64, ms: u64) void {
            t.* += ms;
            zigulee.updateTimersAndAnimations(t.*);
            zigulee.runChangeHandlers();
        }
    }.f;
    // The stack layout: one child shown.
    try testing.expectEqual(@as(i32, 2), app.stack.count.get());
    app.tab.set(1);
    try testing.expectEqual(@as(i32, 1), app.stack.current_index.get());

    // The swipe view follows its index, and the dots follow it.
    try testing.expectEqual(@as(i32, 3), app.swipe.count.get());
    app.page.set(2);
    zigulee.runChangeHandlers(); // the slide starts
    step(&now, 300);
    try testing.expectEqual(@as(f32, 2), app.swipe.position.get());
    try testing.expectEqual(@as(i32, 2), app.dots.current_index.get());

    // The vertical one: its pages one above the other, moved by dragging
    // up and down (not sideways); a tap still reaches the page.
    const v = &app.vswipe.item;
    const top = v.windowTransform().apply(.{});
    const w = app.window();
    const drag = struct {
        fn f(win: *zigulee.Window, from: zigulee.core.Point, to: zigulee.core.Point) void {
            win.dispatchPointer(.{ .pressed = .{ .position = from } });
            win.dispatchPointer(.{ .moved = .{ .position = .{ .x = (from.x + to.x) / 2, .y = (from.y + to.y) / 2 } } });
            win.dispatchPointer(.{ .moved = .{ .position = to } });
            win.dispatchPointer(.{ .released = .{ .position = to } });
        }
    }.f;
    const middle: zigulee.core.Point = .{ .x = top.x + 120, .y = top.y + 30 };
    var pages = v.layoutChildren();
    _ = pages.next();
    const second = pages.next().?;
    try testing.expectEqual(@as(f32, 60), second.y.get());
    try testing.expectEqual(@as(f32, 0), second.x.get());
    // Sideways: not the view's; the page's touch area clicks.
    drag(w, middle, .{ .x = middle.x + 60, .y = middle.y });
    try testing.expectEqual(@as(i32, 0), app.vswipe.current_index.get());
    try testing.expectEqual(@as(i32, 1), app.taps.get());
    w.dispatchPointer(.{ .pressed = .{ .position = middle } });
    w.dispatchPointer(.{ .released = .{ .position = middle } });
    try testing.expectEqual(@as(i32, 2), app.taps.get());
    // A third of a page up: the next one, and no click.
    drag(w, middle, .{ .x = middle.x, .y = middle.y - 20 });
    try testing.expectEqual(@as(i32, 1), app.vswipe.current_index.get());
    try testing.expectEqual(@as(i32, 2), app.taps.get());
    zigulee.runChangeHandlers(); // the slide starts
    step(&now, 300);
    try testing.expectEqual(@as(f32, 1), app.vswipe.position.get());
    try testing.expectEqual(@as(f32, 0), second.y.get());
    drag(w, middle, .{ .x = middle.x, .y = middle.y + 20 });
    try testing.expectEqual(@as(i32, 0), app.vswipe.current_index.get());

    // The stack view: pushed and popped by the buttons' handlers.
    try testing.expectEqual(@as(i32, 1), app.nav.depth.get());
    app.nav.push(&pui.Detail.factory);
    try testing.expectEqual(@as(i32, 2), app.nav.depth.get());
    step(&now, 300);
    try testing.expect(!app.nav.busy.get());
    app.nav.pop();
    step(&now, 300);
    try testing.expectEqual(@as(i32, 1), app.nav.depth.get());
}

test "a split view's handle, a range slider's thumbs, a dial" {
    const sui = @import("ui_split");
    const app = try sui.Split.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    const w = app.window();
    const drag = struct {
        fn f(win: *zigulee.Window, from: zigulee.core.Point, to: zigulee.core.Point) void {
            win.dispatchPointer(.{ .pressed = .{ .position = from } });
            win.dispatchPointer(.{ .moved = .{ .position = .{ .x = (from.x + to.x) / 2, .y = (from.y + to.y) / 2 } } });
            win.dispatchPointer(.{ .moved = .{ .position = to } });
            win.dispatchPointer(.{ .released = .{ .position = to } });
        }
    }.f;
    // The panes share 294 px 1:2; the handle (98-104) dragged 40 px right.
    try testing.expectApproxEqAbs(@as(f32, 98), app.left.item.width.get(), 0.01);
    drag(w, .{ .x = 101, .y = 60 }, .{ .x = 141, .y = 60 });
    try testing.expectApproxEqAbs(@as(f32, 138), app.left.item.width.get(), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 156), app.right.item.width.get(), 0.01);
    // The right pane keeps its minimum (60).
    drag(w, .{ .x = 141, .y = 60 }, .{ .x = 290, .y = 60 });
    try testing.expectApproxEqAbs(@as(f32, 60), app.right.item.width.get(), 0.01);

    // The range: the first thumb dragged to 0, the second past it stops
    // at the first.
    const range_y = app.range.rootItem().windowTransform().apply(.{}).y + 10;
    const thumb = struct {
        fn x(r: *zigulee.Item, v: f32) f32 {
            const span = r.width.get() - 20; // the fluent thumb: 20 px
            return r.windowTransform().apply(.{}).x + 10 + span * v / 100;
        }
    }.x;
    const r = app.range.rootItem();
    drag(w, .{ .x = thumb(r, 20), .y = range_y }, .{ .x = thumb(r, 0), .y = range_y });
    try testing.expectEqual(@as(f32, 0), app.low.get());
    drag(w, .{ .x = thumb(r, 60), .y = range_y }, .{ .x = thumb(r, 10) - 30, .y = range_y });
    try testing.expectEqual(@as(f32, 0), app.high.get());
    try testing.expect(app.high.get() >= app.low.get());

    // The dial: 50 px up adds a quarter of the range.
    const d = app.dial.rootItem();
    const c = d.windowTransform().apply(.{ .x = d.width.get() / 2, .y = d.height.get() / 2 });
    drag(w, c, .{ .x = c.x, .y = c.y - 50 });
    try testing.expectEqual(@as(f32, 75), app.level.get());
}

test "a tree view: expanded by its arrows, a row made current, the keys" {
    const tui = @import("ui_tree");
    const app = try tui.Tree.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    const w = app.window();
    const tap = struct {
        fn f(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
            zigulee.runChangeHandlers();
        }
    }.f;
    const shown = struct {
        fn n(t: *tui.Tree) usize {
            return t.tree.state.shown.get().rowCount();
        }
    }.n;
    // Collapsed: Fruit and Vegetables.
    try testing.expectEqual(@as(usize, 2), shown(app));
    // Fruit's arrow (rows of 30 px): Apple and Pear show.
    tap(w, 12, 15);
    try testing.expectEqual(@as(usize, 4), shown(app));
    try testing.expectEqual(@as(i32, -1), app.current.get());
    // Apple's text: current.
    tap(w, 80, 45);
    try testing.expectEqual(@as(i32, 1), app.current.get());
    try testing.expectEqual(@as(i32, 1), app.changes.get());

    const key = struct {
        fn f(win: *zigulee.Window, k: []const u8) void {
            win.dispatchKey(.pressed, .{ .text = k });
            zigulee.runChangeHandlers();
        }
    }.f;
    const Key = zigulee.core.input.Key;
    key(w, Key.down_arrow); // Pear
    try testing.expectEqual(@as(i32, 2), app.current.get());
    key(w, Key.right_arrow); // expanded
    try testing.expectEqual(@as(usize, 5), shown(app));
    key(w, Key.right_arrow); // to its child
    try testing.expectEqual(@as(i32, 3), app.current.get());
    key(w, Key.left_arrow); // back to the parent
    try testing.expectEqual(@as(i32, 2), app.current.get());
    key(w, Key.left_arrow); // collapsed
    try testing.expectEqual(@as(usize, 4), shown(app));
    key(w, Key.space); // toggled open again
    try testing.expectEqual(@as(usize, 5), shown(app));
    app.tree.invoke_collapse_all();
    try testing.expectEqual(@as(usize, 2), shown(app));
}

test "a drawer slides in, and out on a click outside, a choice, or Escape" {
    const dui = @import("ui_drawer");
    const app = try dui.Drawers.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    const w = app.window();
    var now = zigulee.core.now();
    const step = struct {
        fn f(t: *u64, ms: u64) void {
            zigulee.runChangeHandlers();
            t.* += ms;
            zigulee.updateTimersAndAnimations(t.*);
            zigulee.runChangeHandlers();
        }
    }.f;
    const tap = struct {
        fn f(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
        }
    }.f;
    tap(w, 245, 165); // "Menu"
    try testing.expect(app.menu.root.is_open.get());
    step(&now, 120);
    try testing.expect(app.menu.panel.item.x.get() < 0); // sliding in
    step(&now, 200);
    try testing.expectEqual(@as(f32, 0), app.menu.panel.item.x.get());
    try testing.expectEqual(@as(f32, 160), app.menu.panel.item.width.get());

    // A click on the dimmed window: it slides out, then closes.
    tap(w, 250, 50);
    step(&now, 120);
    try testing.expect(app.menu.root.is_open.get());
    step(&now, 200);
    try testing.expect(!app.menu.root.is_open.get());
    try testing.expectEqual(@as(i32, 1), app.gone.get());

    // A choice in it.
    tap(w, 245, 165);
    step(&now, 300);
    tap(w, 60, 30); // "Pick"
    step(&now, 300);
    try testing.expectEqual(@as(i32, 1), app.picks.get());
    try testing.expect(!app.menu.root.is_open.get());
    try testing.expectEqual(@as(i32, 2), app.gone.get());

    // Escape.
    tap(w, 245, 165);
    step(&now, 300);
    w.dispatchKey(.pressed, .{ .text = zigulee.core.input.Key.escape });
    step(&now, 10);
    try testing.expect(!app.menu.root.is_open.get());
    try testing.expectEqual(@as(i32, 3), app.gone.get());
}

test "a drawer pulled out of its edge: past half way it opens, short of it slides back, flicked it opens" {
    const dui = @import("ui_drawer");
    const app = try dui.Drawers.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    const w = app.window();
    var now = zigulee.core.now();
    const step = struct {
        fn f(t: *u64, ms: u64) void {
            zigulee.runChangeHandlers();
            t.* += ms;
            zigulee.updateTimersAndAnimations(t.*);
            zigulee.runChangeHandlers();
        }
    }.f;
    const P = struct {
        fn press(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
        }
        fn move(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .moved = .{ .position = .{ .x = x, .y = y } } });
        }
        fn release(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
        }
    };
    const panel = &app.menu.panel.item;

    // A tap at the edge, or a drag along it: nothing.
    P.press(w, 5, 100);
    P.release(w, 5, 100);
    P.press(w, 5, 100);
    P.move(w, 7, 140);
    P.move(w, 40, 160);
    P.release(w, 40, 160);
    try testing.expect(!app.menu.root.is_open.get());

    // Pulled 95 of its 160 px: it follows, then opens.
    P.press(w, 5, 100);
    P.move(w, 20, 100);
    try testing.expect(app.menu.root.is_open.get());
    P.move(w, 100, 100);
    try testing.expectApproxEqAbs(@as(f32, 95 - 160), panel.x.get(), 0.5);
    P.release(w, 100, 100);
    step(&now, 300);
    try testing.expectEqual(@as(f32, 0), panel.x.get());
    try testing.expect(app.menu.root.is_open.get());
    app.menu.invoke_dismiss();
    step(&now, 300);
    try testing.expect(!app.menu.root.is_open.get());
    try testing.expectEqual(@as(i32, 1), app.gone.get());

    // Pulled 35 px: back in, closed.
    P.press(w, 5, 100);
    P.move(w, 40, 100);
    P.release(w, 40, 100);
    step(&now, 300);
    try testing.expect(!app.menu.root.is_open.get());
    try testing.expectEqual(@as(i32, 2), app.gone.get());

    // Flicked: 55 px in 32 ms, it opens.
    P.press(w, 5, 100);
    P.move(w, 30, 100);
    step(&now, 16);
    P.move(w, 45, 100);
    step(&now, 16);
    P.move(w, 60, 100);
    P.release(w, 60, 100);
    step(&now, 300);
    try testing.expect(app.menu.root.is_open.get());
    try testing.expectEqual(@as(f32, 0), panel.x.get());
}

test "a grid view of cells, a flow layout, a scroll bar on its own" {
    const gui = @import("ui_grid");
    const app = try gui.Grid.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    const w = app.window();
    // Ten cells of 60 x 50, 8 px apart in 238 px: three a row, four rows.
    try testing.expectEqual(@as(f32, 8 + 4 * 58), app.grid.root.viewport_height.get());
    try testing.expect(app.grid.root.viewport_height.get() > app.grid.root.visible_height.get());
    // A click on the fifth cell (second row, middle).
    const tap = struct {
        fn f(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
        }
    }.f;
    tap(w, 1 + 8 + 68 + 30, 1 + 8 + 58 + 25);
    try testing.expectEqual(@as(i32, 4), app.picked.get());

    // The flow: as many as fit in its width per row.
    try testing.expect(app.flow.item.layoutInfo(.vertical).preferred > 20);

    // The scroll bar: its track clicked at the bottom, to the end.
    const bar = app.bar.rootItem();
    const at = bar.windowTransform().apply(.{ .x = bar.width.get() / 2, .y = bar.height.get() - 1 });
    tap(w, at.x, at.y);
    zigulee.runChangeHandlers();
    try testing.expectApproxEqAbs(@as(f32, 0.6), app.scroll.get(), 0.001);
}

test "long lists: sections, rows recycled, a table of cells" {
    const gui = @import("ui_lists");
    const app = try gui.Lists.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    const w = app.window();
    const tap = struct {
        fn f(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
        }
    }.f;

    // A thousand rows of 20 px, a few with instances.
    const numbers = &app.numbers;
    try testing.expectEqual(@as(i32, 1000), numbers.count.get());
    try testing.expectEqual(@as(f32, 20000), numbers.root.viewport_height.get());
    const shown = numbers.list.item.layoutChildCount();
    try testing.expect(shown >= 4 and shown <= 6);
    // Scrolled to row 500: the same instances, showing it.
    numbers.root.viewport_y.set(-500 * 20);
    zigulee.runChangeHandlers();
    try testing.expectEqual(shown, numbers.list.item.layoutChildCount());
    const top = numbers.root.rootItem().windowTransform().apply(.{ .x = 50, .y = 10 });
    tap(w, top.x, top.y);
    try testing.expectEqual(@as(i32, 500), app.picked.get());

    // Sections: A (three), B (two), ... under 28 px headers.
    const people = &app.people;
    try testing.expectEqualStrings("A", people.current_section.get());
    try testing.expectEqual(@as(f32, 10 * 24 + 5 * 28), people.root.viewport_height.get());
    people.root.viewport_y.set(-(3 * 24 + 28 + 28 + 1));
    zigulee.runChangeHandlers();
    try testing.expectEqualStrings("B", people.current_section.get());

    // The table: cells in their columns.
    const table = app.table.rootItem();
    const born = table.windowTransform().apply(.{ .x = 1 + 120 + 70 + 40, .y = 34 + 1 + 32 + 16 });
    tap(w, born.x, born.y);
    try testing.expectEqualStrings("1912", app.cell.get());
    const name = table.windowTransform().apply(.{ .x = 20, .y = 34 + 1 + 16 });
    tap(w, name.x, name.y);
    try testing.expectEqualStrings("Ada", app.cell.get());
    try testing.expectEqual(@as(i32, 10), app.table.row_count.get());
}

test "rich text: markdown laid out, a link clicked" {
    const gui = @import("ui_richtext");
    const app = try gui.Rich.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    const w = app.window();
    const notes = &app.notes;
    // A heading, a paragraph, four items and two numbered: many lines.
    try testing.expect(app.text_height.get() > 8 * 13);
    try testing.expectEqual(app.text_height.get(), notes.item.height.get());
    // The link's first word, clicked.
    const l = notes.layoutAt(notes.item.width.get()).?;
    const link = for (l.fragments) |f| {
        if (f.run.link != null) break f.rect;
    } else return error.TestUnexpectedResult;
    const at = notes.item.windowTransform().apply(.{ .x = link.x + link.width / 2, .y = link.y + link.height / 2 });
    w.dispatchPointer(.{ .pressed = .{ .position = at } });
    w.dispatchPointer(.{ .released = .{ .position = at } });
    try testing.expectEqualStrings("https://example.org/docs", app.opened.get());
    try testing.expectEqualStrings("Notes\nSome bold, italic, old and code; see the docs for more.\nfirst\nsecond, which is long enough to wrap onto the next line\nnested\none\ntwo", notes.item.accessibleLabel());

    // The HTML: a heading and a table of three rows; selected, its cells a
    // tab apart.
    app.prices.selectAll();
    try testing.expectEqualStrings("Prices\nItem\tPrice\nTea\t2 \u{20ac}\nCake\t3 & up", app.picked.get());
    const t = app.prices.layoutAt(app.prices.item.width.get()).?;
    try testing.expect(t.rules.len > 0);
}

test "svg images: shapes embedded, drawn at their size" {
    const gui = @import("ui_svg");
    const app = try gui.Svg.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    // The file's own size, 32 x 32 (its viewBox is 64 x 64).
    try testing.expectEqual(@as(f32, 32), app.natural.get());
    const img = app.icon.source.get().?;
    const d = img.vector.?;
    try testing.expectEqual(@as(f32, 64), d.viewbox.width);
    // The badge, the circle, the check, the triangle; the gradient, down
    // the badge (2 to 62 of 64).
    try testing.expectEqual(@as(usize, 4), d.shapes.len);
    const sky = d.shapes[0].fill.?.gradient.linear_gradient;
    try testing.expectEqual(zigulee.Color.rgb(0x3b82f6), sky.stops.items[0].color);
    try testing.expectApproxEqAbs(@as(f32, 2.0 / 64.0), sky.line.?[0][1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 62.0 / 64.0), sky.line.?[1][1], 1e-5);
    try testing.expectEqual(zigulee.core.svg.Paint.current, d.shapes[2].stroke.?);
}

test "images loaded at run time, in the background" {
    const gui = @import("ui_remote");
    const app = try gui.Remote.create(gpa);
    defer app.destroy();
    const wait = struct {
        /// Runs the loop until the image is no longer loading.
        fn f(a: anytype) !void {
            for (0..1000) |_| {
                zigulee.updateTimersAndAnimations(zigulee.core.now() + 16);
                zigulee.runChangeHandlers();
                if (a.state.get() != .loading and a.state.get() != .none) return;
                var t: std.Io.Threaded = .init_single_threaded;
                t.io().sleep(.fromMilliseconds(2), .awake) catch {};
            }
            return error.Timeout;
        }
    }.f;
    try wait(app);
    try testing.expect(app.shown.get());
    try testing.expectEqual(@as(f32, 2), app.natural.get());
    try testing.expectEqual(@as(u32, 2), app.photo.source.get().?.width);
    try testing.expectEqual(@as(f32, 1), app.progress.get());
    // Another Image of it: the same image at once, not loaded again.
    app.twice.set(true);
    zigulee.runChangeHandlers();
    try testing.expectEqual(zigulee.core.image.ImageStatus.ready, app.copy.status.get());
    try testing.expectEqual(app.photo.source.get().?.pixels.ptr, app.copy.source.get().?.pixels.ptr);
    app.twice.set(false);
    zigulee.runChangeHandlers();
    // An SVG instead.
    app.url.set("tests/ui/badge.svg");
    zigulee.runChangeHandlers();
    try wait(app);
    try testing.expectEqual(@as(f32, 32), app.natural.get());
    try testing.expect(app.photo.source.get().?.vector != null);
    // Nothing there: the image goes, the status says so.
    app.url.set("tests/ui/nothing.png");
    zigulee.runChangeHandlers();
    try wait(app);
    try testing.expectEqual(zigulee.core.image.ImageStatus.failed, app.state.get());
    try testing.expect(app.photo.source.get() == null);
    // No URL: nothing.
    app.url.set("");
    zigulee.runChangeHandlers();
    try testing.expectEqual(zigulee.core.image.ImageStatus.none, app.state.get());
}

test "window state from .zge: always on top, maximized both ways, fullscreen" {
    const gui = @import("ui_winstate");
    const app = try gui.Kiosk.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    const w = app.window();
    try testing.expect(w.always_on_top.get());
    try testing.expect(!w.maximized.get());
    app.big.set(true);
    try testing.expect(w.maximized.get());
    // The backend reports the user restoring it: the property follows.
    w.maximized.set(false);
    try testing.expect(!app.big.get());
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 10, .y = 10 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 10, .y = 10 } } });
    try testing.expect(w.fullscreen.get());
    // A phone's backend reports the safe area and the keyboard.
    try testing.expectEqual(@as(f32, 100), app.clear_height.get());
    w.safe_area_top.set(20);
    w.safe_area_bottom.set(10);
    try testing.expectEqual(@as(f32, 70), app.clear_height.get());
    w.keyboard_height.set(50);
    try testing.expectEqual(@as(f32, 30), app.clear_height.get());
}

test "several items selected: a list, a table, a tree, a grid of cells" {
    const sui = @import("ui_selection");
    const app = try sui.Selections.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    const w = app.window();
    const Mods = zigulee.core.input.Modifiers;
    const tap = struct {
        fn f(win: *zigulee.Window, x: f32, y: f32, mods: Mods) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y }, .modifiers = mods } });
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
            zigulee.runChangeHandlers();
        }
    }.f;
    const key = struct {
        fn f(win: *zigulee.Window, k: []const u8, mods: Mods) void {
            win.dispatchKey(.pressed, .{ .text = k, .modifiers = mods });
            zigulee.runChangeHandlers();
        }
    }.f;
    const rows = struct {
        fn of(m: zigulee.Model(i32), buf: []i32) []i32 {
            for (0..m.rowCount()) |i| buf[i] = m.rowData(i).?;
            return buf[0..m.rowCount()];
        }
    }.of;
    const Key = zigulee.core.input.Key;
    const ctrl: Mods = .{ .control = true };
    var buf: [8]i32 = undefined;

    // The list: a click, a Ctrl-click, a Shift-click.
    tap(w, 50, 17, .{}); // Ada
    try testing.expectEqualSlices(i32, &.{0}, rows(app.list.selected_items.get(), &buf));
    tap(w, 50, 17 + 2 * 34, ctrl); // and Linus
    try testing.expectEqualSlices(i32, &.{ 0, 2 }, rows(app.list.selected_items.get(), &buf));
    tap(w, 50, 17 + 4 * 34, .{ .shift = true }); // Linus to Barbara
    try testing.expectEqualSlices(i32, &.{ 2, 3, 4 }, rows(app.list.selected_items.get(), &buf));
    try testing.expectEqual(@as(i32, 4), app.list.current_item.get());
    try testing.expectEqual(@as(i32, 3), app.list_changes.get());
    tap(w, 50, 17 + 2 * 34, ctrl); // Linus out
    try testing.expectEqualSlices(i32, &.{ 3, 4 }, rows(app.list.selected_items.get(), &buf));
    // The keys: Shift+Up extends from the last toggled (Linus, current);
    // Ctrl+A; Up alone.
    key(w, Key.up_arrow, .{ .shift = true });
    try testing.expectEqualSlices(i32, &.{ 1, 2 }, rows(app.list.selected_items.get(), &buf));
    key(w, "a", ctrl);
    try testing.expectEqual(@as(i32, 5), app.list_count.get());
    key(w, Key.up_arrow, .{});
    try testing.expectEqualSlices(i32, &.{0}, rows(app.list.selected_items.get(), &buf));
    app.list.invoke_clear_selection();
    try testing.expectEqual(@as(i32, 0), app.list_count.get());

    // The table: each click adds or removes a row.
    tap(w, 300, 34 + 16, .{});
    tap(w, 300, 34 + 16 + 2 * 32, .{});
    try testing.expectEqualSlices(i32, &.{ 0, 2 }, rows(app.table.selected_rows.get(), &buf));
    tap(w, 300, 34 + 16, .{});
    try testing.expectEqualSlices(i32, &.{2}, rows(app.table.selected_rows.get(), &buf));
    // Space adds the current one; the arrows only move it.
    key(w, Key.down_arrow, .{});
    key(w, Key.space, .{});
    try testing.expectEqualSlices(i32, &.{ 1, 2 }, rows(app.table.selected_rows.get(), &buf));

    // The tree: a range of the rows shown, past the collapsed Fruit.
    tap(w, 80, 200 + 15, .{}); // Fruit
    tap(w, 80, 200 + 45, .{ .shift = true }); // to Vegetables
    try testing.expectEqualSlices(i32, &.{ 0, 3 }, rows(app.tree.selected_items.get(), &buf));
    try testing.expect(app.tree.sel.selected.get().rowData(3).?);
    app.tree.invoke_select_all();
    try testing.expectEqual(@as(i32, 5), app.tree_count.get());

    // The grid: cells toggled, then a range.
    tap(w, 226, 226, .{});
    tap(w, 226 + 44, 226, .{});
    try testing.expectEqual(@as(i32, 2), app.grid_count.get());
    tap(w, 226 + 44, 226, .{});
    tap(w, 226 + 3 * 44, 226, .{ .shift = true }); // from the second to the fourth
    try testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, rows(app.picked.selected_rows.get(), &buf));
}

test "accessibility: a StandardTableView's headers, rows and cells" {
    const a11y = zigulee.core.accessibility;
    const tui = @import("ui_table");
    const app = try tui.Table.create(gpa);
    defer app.destroy();
    const w = app.window();
    zigulee.runChangeHandlers();
    var tracker: a11y.Tracker = .init(gpa, w);
    defer tracker.deinit();
    var nodes = try tracker.update();
    const find = struct {
        fn by(list: []const a11y.Node, role: zigulee.core.AccessibleRole, label: []const u8) ?u32 {
            for (list, 0..) |n, i| if (n.role == role and std.mem.eql(u8, n.label, label)) return @intCast(i);
            return null;
        }
        fn rows(list: []const a11y.Node) [8]?u32 {
            var out: [8]?u32 = @splat(null);
            var k: usize = 0;
            for (list, 0..) |n, i| if (n.role == .table_row and k < out.len) {
                out[k] = @intCast(i);
                k += 1;
            };
            return out;
        }
    };

    // A table, its headers in it.
    const table = find.by(nodes, .table, "").?;
    const born = find.by(nodes, .column_header, "Born").?;
    try testing.expectEqual(@as(?u32, table), nodes[born].parent);
    try testing.expectEqualStrings("", nodes[born].value);
    // The rows in it, each with its cells (the current row selected).
    const first = find.rows(nodes)[0].?;
    try testing.expectEqual(@as(?u32, table), nodes[first].parent);
    try testing.expect(nodes[first].checked);
    try testing.expectEqual(@as(?u32, first), nodes[find.by(nodes, .table_cell, "Lovelace").?].parent);
    try testing.expect(find.by(nodes, .text, "Lovelace") == null);

    // A header pressed sorts; a row pressed is selected.
    try testing.expect(a11y.perform(w, nodes[born].item, .default));
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(i32, 2), app.sorted_by.get());
    nodes = try tracker.update();
    try testing.expectEqualStrings("sorted ascending", nodes[find.by(nodes, .column_header, "Born").?].value);
    const third = find.rows(nodes)[2].?;
    try testing.expect(a11y.perform(w, nodes[third].item, .default));
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(i32, 2), app.row.get());
    nodes = try tracker.update();
    try testing.expect(nodes[find.rows(nodes)[2].?].checked);
    try testing.expect(!nodes[find.rows(nodes)[0].?].checked);
}

test "accessibility: items selected by assistive technology" {
    const a11y = zigulee.core.accessibility;
    const sui = @import("ui_selection");
    const app = try sui.Selections.create(gpa);
    defer app.destroy();
    const w = app.window();
    zigulee.runChangeHandlers();
    var tracker: a11y.Tracker = .init(gpa, w);
    defer tracker.deinit();
    const nodes = try tracker.update();
    const find = struct {
        fn by(list: []const a11y.Node, role: zigulee.core.AccessibleRole, label: []const u8) a11y.Node {
            for (list) |n| if (n.role == role and std.mem.eql(u8, n.label, label)) return n;
            unreachable;
        }
        fn rows(list: []const a11y.Node) [3]*zigulee.Item {
            var out: [3]*zigulee.Item = undefined;
            var k: usize = 0;
            for (list) |n| if (n.role == .table_row and k < 3) {
                out[k] = n.item;
                k += 1;
            };
            return out;
        }
    };
    var buf: [8]i32 = undefined;
    const selected = struct {
        fn of(m: zigulee.Model(i32), b: []i32) []i32 {
            for (0..m.rowCount()) |i| b[i] = m.rowData(i).?;
            return b[0..m.rowCount()];
        }
    }.of;

    // The list (extended): several selectable; select one, add, remove.
    for (nodes) |n| if (n.role == .list or n.role == .table) try testing.expect(n.multiselectable);
    try testing.expect(a11y.perform(w, find.by(nodes, .list_item, "Grace").item, .select));
    try testing.expect(a11y.setSelected(find.by(nodes, .list_item, "Alan").item, true));
    try testing.expectEqualSlices(i32, &.{ 1, 3 }, selected(app.list.selected_items.get(), &buf));
    try testing.expect(a11y.setSelected(find.by(nodes, .list_item, "Grace").item, false));
    try testing.expectEqualSlices(i32, &.{3}, selected(app.list.selected_items.get(), &buf));
    try testing.expect(a11y.perform(w, find.by(nodes, .list_item, "Ada").item, .select));
    try testing.expectEqualSlices(i32, &.{0}, selected(app.list.selected_items.get(), &buf));
    try testing.expectEqual(@as(i32, 0), app.list.current_item.get());

    // The table (multiple): select replaces, where a press would add.
    const rows = find.rows(nodes);
    try testing.expect(a11y.setSelected(rows[0], true));
    try testing.expect(a11y.setSelected(rows[2], true));
    try testing.expectEqualSlices(i32, &.{ 0, 2 }, selected(app.table.selected_rows.get(), &buf));
    try testing.expect(a11y.perform(w, rows[1], .select));
    try testing.expectEqualSlices(i32, &.{1}, selected(app.table.selected_rows.get(), &buf));
}

test "a component inheriting a window component is a window" {
    const wui = @import("ui_inherit_window");
    const app = try wui.Big.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    const w = app.window();
    // Its size and title, over the inherited ones.
    try testing.expectEqual(@as(f32, 300), w.size().width);
    try testing.expectEqual(@as(f32, 100), w.size().height);
    try testing.expectEqualStrings("Big", app.title.get());
    try testing.expectEqualStrings("2 clicks", app.label.get());
    // The inherited content works, and calls its handler.
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 20, .y = 20 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 20, .y = 20 } } });
    zigulee.runChangeHandlers();
    try testing.expectEqualStrings("3 clicks", app.label.get());
    try testing.expectEqual(@as(i32, 1), app.bumps.get());
}

test "submenus: opened by hovering and the keys, beside their entry" {
    const sui = @import("ui_submenus");
    const app = try sui.Submenus.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    const w = app.window();
    const Key = zigulee.core.input.Key;
    const P = zigulee.core.Point;
    const move = struct {
        fn f(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .moved = .{ .position = .{ .x = x, .y = y } } });
            zigulee.runChangeHandlers();
        }
    }.f;
    const tap = struct {
        fn f(win: *zigulee.Window, p: P) void {
            win.dispatchPointer(.{ .pressed = .{ .position = p } });
            win.dispatchPointer(.{ .released = .{ .position = p } });
            zigulee.runChangeHandlers();
        }
    }.f;
    const key = struct {
        fn f(win: *zigulee.Window, k: []const u8) void {
            win.dispatchKey(.pressed, .{ .text = k });
            zigulee.runChangeHandlers();
        }
    }.f;
    const open = &app.menu.root.is_open;

    // At (10, 10): rows of 30 from 15. Hovering Export opens its submenu
    // to the right, its first row level with Export.
    app.menu.invoke_open_at(10, 10);
    zigulee.runChangeHandlers();
    move(w, 100, 10 + 5 + 30 + 15);
    // A click on PNG, in the submenu (past the menu's own bounds).
    tap(w, .{ .x = 10 + 216 + 100, .y = 10 + 30 + 5 + 15 });
    try testing.expectEqual(@as(i32, 2), app.chosen.get());
    try testing.expect(!open.get());

    // The keys: down to Export, into it, past the disabled JPEG, into
    // Vector, down to PDF, back out (Left), in again and choose.
    app.menu.invoke_open_at(10, 10);
    zigulee.runChangeHandlers();
    key(w, Key.down_arrow);
    key(w, Key.down_arrow);
    key(w, Key.right_arrow); // PNG
    key(w, Key.down_arrow); // Vector
    key(w, Key.down_arrow); // still Vector: JPEG is disabled
    key(w, Key.right_arrow); // SVG
    key(w, Key.down_arrow); // PDF
    key(w, Key.left_arrow); // Vector, its submenu closed
    key(w, Key.@"return"); // in again: SVG
    key(w, Key.down_arrow);
    key(w, Key.@"return");
    try testing.expectEqual(@as(i32, 5), app.chosen.get());

    // Near the right edge: the menu is kept in the window and its submenu
    // opens on the left. Hovering Open (no submenu) closes it again.
    app.menu.invoke_open_at(580, 10);
    zigulee.runChangeHandlers();
    const menu_x = app.menu.rootItem().absoluteGeometry().x;
    try testing.expectEqual(@as(f32, 600 - 220), menu_x);
    move(w, menu_x + 100, 10 + 5 + 30 + 15);
    tap(w, .{ .x = menu_x - 216 + 100, .y = 10 + 30 + 5 + 30 + 15 }); // Vector: opens its own
    try testing.expect(open.get());
    try testing.expectEqual(@as(i32, 5), app.chosen.get());
    // A click outside them all closes the menu.
    tap(w, .{ .x = 500, .y = 280 });
    try testing.expect(!open.get());
}

test "gallery: effects together, set finely, and reset" {
    const app = try gallery.Gallery.create(gpa);
    defer app.destroy();
    const w = app.window();
    app.tab.set(4);
    zigulee.runChangeHandlers();
    zigulee.updateTimersAndAnimations(zigulee.core.now() + 1000);
    zigulee.runChangeHandlers();
    const press = struct {
        fn on(win: *zigulee.Window, item: *zigulee.core.Item) void {
            const g = item.absoluteGeometry();
            const p: zigulee.core.Point = .{ .x = g.x + 10, .y = g.y + g.height / 2 };
            win.dispatchPointer(.{ .pressed = .{ .position = p } });
            win.dispatchPointer(.{ .released = .{ .position = p } });
            zigulee.runChangeHandlers();
        }
    }.on;
    // At first: turned, rounded, with a shadow, all on the subject.
    try testing.expect(app.fx_rotate.get() and app.fx_round.get() and app.fx_shadow.get());
    try testing.expectEqual(@as(f32, 12), app.subject.item.transform.?.rotation.get());
    // Blur too: four together.
    press(w, app.fx_blur_box.rootItem());
    try testing.expect(app.fx_blur.get() and app.fx_rotate.get());
    try testing.expectEqual(@as(f32, 3), app.subject.item.blurRadius());
    // Scale: its slider's middle is 1 (Sliders do not snap by default).
    press(w, app.fx_scale_box.rootItem());
    const g = app.fx_zoom_slider.rootItem().absoluteGeometry();
    const mid: zigulee.core.Point = .{ .x = g.x + g.width / 2, .y = g.y + g.height / 2 };
    w.dispatchPointer(.{ .pressed = .{ .position = mid } });
    zigulee.runChangeHandlers(); // the slider reacts to `pressed` in a `changed` handler
    w.dispatchPointer(.{ .released = .{ .position = mid } });
    zigulee.runChangeHandlers();
    try testing.expectApproxEqAbs(@as(f32, 1), app.fx_zoom.get(), 0.001);
    // Reset: back to how it started.
    press(w, app.fx_reset_button.rootItem());
    try testing.expect(!app.fx_blur.get() and !app.fx_scale.get());
    try testing.expectEqual(@as(f32, 1.2), app.fx_zoom.get());
    try testing.expect(app.fx_rotate.get() and app.fx_round.get() and app.fx_shadow.get());
}

const settings_ui = @import("ui_settings");

test "settings: kept in a file, read back by the next run; standard paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "app.ini" });
    defer gpa.free(path);
    {
        const app = try settings_ui.SettingsApp.create(gpa);
        defer app.destroy();
        app.file.set(path);
        zigulee.runChangeHandlers();
        // Nothing saved: the linked property keeps its value.
        try testing.expectEqual(@as(i32, 0), app.clicks.get());
        try testing.expectEqual(@as(i32, 0), app.store.root.count.get());
        const w = app.window();
        w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 50, .y = 25 } } });
        w.dispatchPointer(.{ .released = .{ .position = .{ .x = 50, .y = 25 } } });
        zigulee.runChangeHandlers();
        zigulee.updateTimersAndAnimations(zigulee.core.now() + zigulee.core.settings.save_delay_ms);
        const text = try tmp.dir.readFileAlloc(testing.io, "app.ini", gpa, .unlimited);
        defer gpa.free(text);
        try testing.expectEqualStrings("[view]\ncount=1\nname=plain\nsize=10\ntint=#336699ff\ndark=true\n", text);
        if (std.fs.path.isAbsolute(app.documents.get())) try testing.expectEqualStrings("Documents", std.fs.path.basename(app.documents.get()));
    }
    const app = try settings_ui.SettingsApp.create(gpa);
    defer app.destroy();
    app.file.set(path);
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(i32, 1), app.clicks.get());
    try testing.expect(app.store.dark.get());
    try testing.expectEqualStrings("plain", app.store.root.name.get());
}

test "gallery: charts hovered and clicked by index, with values from functions" {
    const app = try gallery.Gallery.create(gpa);
    defer app.destroy();
    const w = app.window();
    app.tab.set(5);
    zigulee.runChangeHandlers();
    zigulee.updateTimersAndAnimations(zigulee.core.now() + 1000);
    zigulee.runChangeHandlers();
    const bars = &app.bars;
    // Rounded to four steps of the grid: 0 to 80 for values up to 49.
    try testing.expectEqual(@as(f32, 0), bars.shown_minimum.get());
    try testing.expectEqual(@as(f32, 80), bars.shown_maximum.get());
    const g = bars.item.absoluteGeometry();
    const slot = g.width / 8;
    const third: zigulee.core.Point = .{ .x = g.x + slot * 2.5, .y = g.y + g.height - 4 };
    w.dispatchPointer(.{ .moved = .{ .position = third } });
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(i32, 2), bars.hovered_index.get());
    w.dispatchPointer(.{ .pressed = .{ .position = third } });
    w.dispatchPointer(.{ .released = .{ .position = third } });
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(i32, 2), app.chart_picked.get());
    // The pie: the slice under the pointer (a quarter turn in, the first).
    const pg = app.pie.item.absoluteGeometry();
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = pg.x + pg.width * 0.85, .y = pg.y + pg.height * 0.3 } } });
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(i32, 0), app.pie.hovered_index.get());
    // The next week: other values, the pick forgotten.
    const before = bars.values.get().rowData(0).?;
    const ng = app.chart_next.rootItem().absoluteGeometry();
    const at: zigulee.core.Point = .{ .x = ng.x + ng.width / 2, .y = ng.y + ng.height / 2 };
    w.dispatchPointer(.{ .pressed = .{ .position = at } });
    w.dispatchPointer(.{ .released = .{ .position = at } });
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(i32, -1), app.chart_picked.get());
    try testing.expect(bars.values.get().rowData(0).? != before);
}

const http_ui = @import("ui_http");

test "http: a request sent from .zge, its JSON answer read by path" {
    if (!zigulee.core.http.threaded) return error.SkipZigTest;
    var server: zigulee.core.http.EchoServer = undefined;
    try server.start();
    defer server.stop();
    var buf: [64]u8 = undefined;
    const app = try http_ui.HttpApp.create(gpa);
    defer app.destroy();
    app.base.set(server.url(&buf, ""));
    try testing.expectEqual(@as(f32, 3.5), app.pi.get());
    const w = app.window();
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 50, .y = 50 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 50, .y = 50 } } });
    zigulee.runChangeHandlers();
    try testing.expect(app.req.loading.get());
    var now = zigulee.core.now();
    for (0..2000) |_| {
        if (!app.req.loading.get()) break;
        now += 15;
        zigulee.updateTimersAndAnimations(now);
        zigulee.runChangeHandlers();
        testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
    }
    try testing.expectEqualStrings("ok 200", app.outcome.get());
    try testing.expectEqualStrings("POST", app.method.get());
    try testing.expectEqualStrings("zge", app.token.get());
    try testing.expectEqual(@as(i32, 2), app.count.get());
    try testing.expectEqual(@as(f32, 2), app.second.get());
}

test "an on-screen keyboard: open while a field has the focus, typing into it" {
    const kui = @import("ui_keyboard");
    const app = try kui.Keyboard.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    const w = app.window();
    var now = zigulee.core.now();
    const step = struct {
        fn f(t: *u64, ms: u64) void {
            zigulee.runChangeHandlers();
            t.* += ms;
            zigulee.updateTimersAndAnimations(t.*);
            zigulee.runChangeHandlers();
        }
    }.f;
    const tap = struct {
        fn f(win: *zigulee.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
            zigulee.runChangeHandlers();
        }
    }.f;
    try testing.expect(!app.open.get());
    try testing.expectEqual(@as(f32, 0), app.kb.root.item.height.get());
    tap(w, 200, 16); // the field
    try testing.expect(app.open.get());
    // Four rows of 44px keys, 6px apart: from y 94 to 300. Row 1 has ten
    // keys 33.4px wide; row 2 nine, half a key in; rows 3 and 4 wide keys.
    try testing.expectEqual(@as(f32, 206), app.kb.root.item.height.get());
    const row = [_]f32{ 122, 172, 222, 272 };
    tap(w, 31, row[2]); // Shift
    tap(w, 239, row[1]); // h
    tap(w, 298, row[0]); // i
    try testing.expectEqualStrings("Hi", app.typed.get());
    tap(w, 39, row[3]); // ?123
    tap(w, 23, row[0]); // 1
    tap(w, 31, row[2]); // =\<
    tap(w, 278, row[1]); // €
    tap(w, 39, row[3]); // ABC
    tap(w, 23, row[0]); // q
    try testing.expectEqualStrings("Hi1€q", app.typed.get());
    // Shift twice: capitals until a third.
    tap(w, 31, row[2]);
    tap(w, 31, row[2]);
    tap(w, 23, row[0]);
    tap(w, 23, row[0]);
    tap(w, 31, row[2]);
    tap(w, 23, row[0]);
    try testing.expectEqualStrings("Hi1€qQQq", app.typed.get());

    // Backspace, then held: it repeats, and the release adds nothing.
    tap(w, 369, row[2]);
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 369, .y = row[2] } } });
    step(&now, 300);
    try testing.expectEqualStrings("Hi1€qQQ", app.typed.get());
    step(&now, 160);
    try testing.expectEqualStrings("Hi1€qQ", app.typed.get());
    step(&now, 60);
    step(&now, 60);
    try testing.expectEqualStrings("Hi1€", app.typed.get());
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 369, .y = row[2] } } });
    step(&now, 200);
    try testing.expectEqualStrings("Hi1€", app.typed.get());

    tap(w, 170, row[3]); // space
    tap(w, 325, row[3]); // Return
    try testing.expectEqualStrings("Hi1€ ", app.typed.get());
    try testing.expectEqual(@as(i32, 1), app.accepted.get());
    // The key that closes it.
    tap(w, 382, row[3]);
    try testing.expect(!app.open.get());
    try testing.expect(w.focus_item == null);
}

test "a tray icon and its menu, a notification and a click on it, from .zge" {
    const Fake = struct {
        var key: usize = 0;
        var tooltip: [16]u8 = undefined;
        var tooltip_len: usize = 0;
        var checked = false;
        var notice: u32 = 0;
        var title: [16]u8 = undefined;
        var title_len: usize = 0;
        fn show(_: ?*anyopaque, icon: *const zigulee.core.tray.Icon) void {
            key = icon.key;
            @memcpy(tooltip[0..icon.tooltip.len], icon.tooltip);
            tooltip_len = icon.tooltip.len;
            checked = icon.entries[0].checked;
        }
        fn notify(_: ?*anyopaque, n: *const zigulee.core.tray.Notice) void {
            notice = n.id;
            @memcpy(title[0..n.title.len], n.title);
            title_len = n.title.len;
        }
    };
    const tray = zigulee.core.tray;
    tray.setProvider(.{ .show = Fake.show, .notify = Fake.notify });
    defer tray.setProvider(null);
    const tui = @import("ui_tray");
    const app = try tui.TrayApp.create(gpa);
    defer app.destroy();
    try testing.expect(app.tray_available.get());
    try testing.expect(app.notifications_available.get());
    tray.update();
    try testing.expectEqualStrings("Running", Fake.tooltip[0..Fake.tooltip_len]);
    try testing.expect(!Fake.checked);

    tray.choose(Fake.key, 0); // Paused
    try testing.expect(app.paused.get());
    tray.update();
    try testing.expectEqualStrings("Paused", Fake.tooltip[0..Fake.tooltip_len]);
    try testing.expect(Fake.checked);

    tray.choose(Fake.key, 1); // Notify
    try testing.expectEqualStrings("Paused", Fake.title[0..Fake.title_len]);
    tray.notificationClicked(Fake.notice);
    try testing.expectEqual(@as(i32, 1), app.clicked.get());
}

test "a microphone recording and a camera picture, from .zge, saved to files" {
    const Fakes = struct {
        var sink: ?*const zigulee.core.audio.Input.Sink = null;
        var frames: ?*const zigulee.core.camera.Provider.Sink = null;
        fn start(_: ?*anyopaque, s: *const zigulee.core.audio.Input.Sink) zigulee.core.audio.Input.Error!u32 {
            sink = s;
            return 1000;
        }
        fn stop(_: ?*anyopaque) void {
            sink = null;
        }
        fn camStart(_: ?*anyopaque, s: *const zigulee.core.camera.Provider.Sink) zigulee.core.camera.Provider.Error!void {
            frames = s;
        }
        fn camStop(_: ?*anyopaque) void {
            frames = null;
        }
    };
    zigulee.core.audio.setInput(.{ .ctx = null, .vtable = &.{ .start = Fakes.start, .stop = Fakes.stop } });
    defer zigulee.core.audio.setInput(null);
    zigulee.core.camera.setProvider(.{ .ctx = null, .vtable = &.{ .start = Fakes.camStart, .stop = Fakes.camStop } });
    defer zigulee.core.camera.setProvider(null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(dir);
    const cui = @import("ui_capture");
    const app = try cui.CaptureApp.create(gpa);
    defer app.destroy();
    app.folder.set(dir);
    zigulee.runChangeHandlers();
    try testing.expect(app.available.get());
    try testing.expect(Fakes.frames != null); // active: true

    app.invoke_listen(true);
    zigulee.runChangeHandlers();
    const loud: [100]f32 = @splat(0.5);
    Fakes.sink.?.write(null, &loud, 1);
    zigulee.core.audio.capture.update();
    try testing.expectApproxEqAbs(@as(f32, 0.5), app.level.get(), 0.001);
    app.invoke_record();
    Fakes.sink.?.write(null, &loud, 1);
    Fakes.sink.?.write(null, &loud, 1);
    zigulee.core.audio.capture.update();
    try testing.expectEqual(@as(i64, 200), app.length.get());
    app.invoke_stop_and_play();
    const sound = try tmp.dir.readFileAlloc(testing.io, "sound.wav", gpa, .unlimited);
    defer gpa.free(sound);
    try testing.expectEqual(@as(usize, 44 + 200 * 2), sound.len);

    const frame: [4]zigulee.core.Rgba8 = @splat(.{ .g = 255, .a = 255 });
    Fakes.frames.?.frame(null, &frame, 2, 2);
    zigulee.core.camera.update();
    app.invoke_snap();
    try testing.expectEqual(@as(i32, 1), app.taken.get());
    try testing.expect(app.has_picture.get());
    const png = try tmp.dir.readFileAlloc(testing.io, "picture.png", gpa, .unlimited);
    defer gpa.free(png);
    try testing.expect(std.mem.startsWith(u8, png, "\x89PNG"));
}

test "open-url from .zge: links handed to the system's opener" {
    const Fake = struct {
        var opened: usize = 0;
        var last: [64]u8 = undefined;
        var len: usize = 0;
        fn open(_: ?*anyopaque, url: []const u8) bool {
            opened += 1;
            @memcpy(last[0..url.len], url);
            len = url.len;
            return true;
        }
    };
    zigulee.core.links.setOpener(.{ .open = Fake.open });
    defer zigulee.core.links.setOpener(null);
    const lui = @import("ui_links");
    const app = try lui.LinksApp.create(gpa);
    defer app.destroy();
    app.invoke_visit();
    try testing.expectEqualStrings("https://ziglang.org", Fake.last[0..Fake.len]);
    app.invoke_try_bad();
    try testing.expect(!app.opened.get());
    try testing.expectEqual(@as(usize, 1), Fake.opened);
    app.invoke_try_good();
    try testing.expect(app.opened.get());
    try testing.expectEqualStrings("mailto:someone@example.com", Fake.last[0..Fake.len]);
}

test "a web view from .zge: placed, loading, following the page, JavaScript" {
    const wv = zigulee.core.webview;
    const Fake = struct {
        var token: u8 = 0;
        var rect: zigulee.core.Rect = .{};
        var loaded: [64]u8 = undefined;
        var loaded_len: usize = 0;
        var backs: usize = 0;
        fn create(_: ?*anyopaque, _: ?*anyopaque, _: *wv.WebView) ?*wv.Provider.Native {
            return &token;
        }
        fn destroy(_: ?*anyopaque, _: *wv.Provider.Native) void {}
        fn place(_: ?*anyopaque, _: *wv.Provider.Native, r: zigulee.core.Rect, _: bool) void {
            rect = r;
        }
        fn load(_: ?*anyopaque, _: *wv.Provider.Native, url: []const u8) void {
            @memcpy(loaded[0..url.len], url);
            loaded_len = url.len;
        }
        fn back(_: ?*anyopaque, _: *wv.Provider.Native) void {
            backs += 1;
        }
        fn noop(_: ?*anyopaque, _: *wv.Provider.Native) void {}
        fn run(_: ?*anyopaque, n: *wv.Provider.Native, _: []const u8) void {
            wv.reportJavaScript(n, "42", false);
        }
    };
    wv.setProvider(.{ .vtable = &.{
        .create = Fake.create,
        .destroy = Fake.destroy,
        .place = Fake.place,
        .load_url = Fake.load,
        .load_html = Fake.load,
        .back = Fake.back,
        .forward = Fake.noop,
        .reload = Fake.noop,
        .stop = Fake.noop,
        .run_javascript = Fake.run,
    } });
    defer wv.setProvider(null);
    const wui = @import("ui_webview");
    const app = try wui.WebApp.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    wv.update();
    try testing.expectEqualStrings("https://ziglang.org", Fake.loaded[0..Fake.loaded_len]);
    try testing.expectEqual(@as(f32, 10), Fake.rect.x);
    const n: *wv.Provider.Native = &Fake.token;
    wv.reportTitle(n, "Zig");
    wv.reportFinished(n, null);
    try testing.expectEqualStrings("Zig", app.page_title.get());
    wv.reportUrl(n, "https://ziglang.org/learn/");
    wv.reportHistory(n, true, false);
    zigulee.runChangeHandlers();
    try testing.expectEqualStrings("https://ziglang.org/learn/", app.address.get());
    try testing.expect(app.back.get());
    try testing.expectEqualStrings("https://ziglang.org", Fake.loaded[0..Fake.loaded_len]); // not loaded again
    app.invoke_previous();
    try testing.expectEqual(@as(usize, 1), Fake.backs);
    app.invoke_go("https://example.com");
    zigulee.runChangeHandlers();
    try testing.expectEqualStrings("https://example.com", Fake.loaded[0..Fake.loaded_len]);
    app.invoke_ask();
    try testing.expectEqualStrings("42", app.js.get());
    wv.reportFinished(n, "offline");
    try testing.expectEqual(@as(i32, 1), app.errors.get());
}

test "map items in a for stand on their places" {
    const gui = @import("ui_map");
    const app = try gui.Places.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    // The pins (in a repeater, in the map): their bottom middle on Milan
    // and Turin.
    const places = [_][2]f32{ .{ 45.4642, 9.19 }, .{ 45.0703, 7.6869 } };
    var found: usize = 0;
    var stack: [32]*zigulee.core.Item = undefined;
    var n: usize = 1;
    stack[0] = &app.map.item;
    while (n > 0) {
        n -= 1;
        const item = stack[n];
        var child = item.first_child;
        while (child) |c| : (child = c.next_sibling) {
            stack[n] = c;
            n += 1;
        }
        if (!std.mem.eql(u8, item.vtable.name, "MapItem")) continue;
        // In the map's coordinates (the repeater stands at its origin).
        const foot: zigulee.core.Point = .{ .x = item.x.get() + item.width.get() / 2, .y = item.y.get() + item.height.get() };
        const on_one = for (places) |p| {
            const at = app.map.pointAt(p[0], p[1]);
            if (@abs(at.x - foot.x) < 0.01 and @abs(at.y - foot.y) < 0.01) break true;
        } else false;
        try testing.expect(on_one);
        found += 1;
    }
    try testing.expectEqual(@as(usize, 2), found);
}

test "clip paths: a gauge's pie slice follows its value; a turned element clips turned" {
    const cui = @import("ui_clip");
    const app = try cui.Clip.create(gpa);
    defer app.destroy();
    const win = app.window();
    var pixels: [300 * 100]zigulee.core.Rgba8 = undefined;
    var r: zigulee.software.Renderer(zigulee.core.Rgba8) = .init(gpa);
    defer r.deinit();
    const Px = struct {
        pixels: []const zigulee.core.Rgba8,
        fn at(p: @This(), x: usize, y: usize) zigulee.core.Rgba8 {
            return p.pixels[y * 300 + x];
        }
        fn white(p: @This(), x: usize, y: usize) bool {
            const c = p.at(x, y);
            return c.r == 255 and c.g == 255 and c.b == 255;
        }
        fn red(p: @This(), x: usize, y: usize) bool {
            const c = p.at(x, y);
            return c.r > 200 and c.g < 60 and c.b < 60;
        }
    };
    const px: Px = .{ .pixels = &pixels };
    zigulee.runChangeHandlers();
    _ = try r.renderWindow(win, .init(&pixels, 300, 100), .full);
    // A quarter: the top right of the dial (centered at 50, 50), its red
    // child cut too; the rest, nothing.
    try testing.expect(!px.white(65, 35));
    try testing.expect(px.red(85, 45));
    try testing.expect(px.white(35, 35));
    try testing.expect(px.white(65, 65));
    try testing.expect(px.white(85, 65));
    // The picture, cut the same way.
    try testing.expect(!px.white(265, 35));
    try testing.expect(px.white(235, 65));
    // Turned 45 degrees: a diamond of red (centered at 150, 50).
    try testing.expect(px.red(150, 50));
    try testing.expect(px.red(150, 12));
    try testing.expect(px.white(125, 25));

    // Three quarters: all but the top left.
    app.value.set(0.75);
    zigulee.runChangeHandlers();
    var partial = pixels;
    _ = try r.renderWindow(win, .init(&partial, 300, 100), .partial);
    // As a full frame would draw it.
    _ = try r.renderWindow(win, .init(&pixels, 300, 100), .full);
    try testing.expectEqualSlices(zigulee.core.Rgba8, &pixels, &partial);
    try testing.expect(!px.white(35, 65));
    try testing.expect(px.red(85, 65));
    try testing.expect(px.white(35, 35));
}

test "masks: a card's rounded clip, an image's and an SVG drawing's opacity; clicks only where they show" {
    const mui = @import("ui_mask");
    const app = try mui.Mask.create(gpa);
    defer app.destroy();
    const win = app.window();
    var pixels: [400 * 100]zigulee.core.Rgba8 = undefined;
    var r: zigulee.software.Renderer(zigulee.core.Rgba8) = .init(gpa);
    defer r.deinit();
    const Px = struct {
        pixels: []const zigulee.core.Rgba8,
        fn white(p: @This(), x: usize, y: usize) bool {
            const c = p.pixels[y * 400 + x];
            return c.r == 255 and c.g == 255 and c.b == 255;
        }
        fn shown(p: @This(), x: usize, y: usize) bool {
            const c = p.pixels[y * 400 + x];
            return @as(u32, c.r) + c.g + c.b < 400;
        }
    };
    const px: Px = .{ .pixels = &pixels };
    const press = struct {
        fn at(w: *zigulee.Window, x: f32, y: f32) void {
            w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            w.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
        }
    }.at;
    zigulee.runChangeHandlers();
    _ = try r.renderWindow(win, .init(&pixels, 400, 100), .full);

    // The card's child, cut round at its corners (radius 20 about 30, 30).
    try testing.expect(px.white(11, 11));
    try testing.expect(px.white(14, 14));
    try testing.expect(px.shown(18, 18));
    try testing.expect(px.shown(11, 50));
    try testing.expect(px.shown(50, 11));
    try testing.expect(px.white(88, 88));
    // The image's opaque left, nothing on the right.
    try testing.expect(px.shown(115, 50));
    try testing.expect(px.white(185, 50));
    // The drawing's rounded square, not its corners.
    try testing.expect(px.shown(250, 50));
    try testing.expect(px.white(211, 11));

    // Clicks in the corner, the clear half, outside the slice: none.
    press(win, 13, 13);
    press(win, 180, 50);
    press(win, 380, 80);
    try testing.expectEqual(@as(i32, 0), app.card_clicks.get());
    try testing.expectEqual(@as(i32, 0), app.half_clicks.get());
    try testing.expectEqual(@as(i32, 0), app.slice_clicks.get());
    press(win, 50, 50);
    press(win, 120, 50);
    press(win, 320, 20);
    try testing.expectEqual(@as(i32, 1), app.card_clicks.get());
    try testing.expectEqual(@as(i32, 1), app.half_clicks.get());
    try testing.expectEqual(@as(i32, 1), app.slice_clicks.get());

    // Square again: the corner shows, redrawn as a full frame would.
    app.radius.set(0);
    zigulee.runChangeHandlers();
    var partial = pixels;
    _ = try r.renderWindow(win, .init(&partial, 400, 100), .partial);
    _ = try r.renderWindow(win, .init(&pixels, 400, 100), .full);
    try testing.expectEqualSlices(zigulee.core.Rgba8, &pixels, &partial);
    try testing.expect(px.shown(11, 11));
    press(win, 13, 13);
    try testing.expectEqual(@as(i32, 2), app.card_clicks.get());

    // Inverted: the image's clear right shows, its left not; clicks too.
    app.invert.set(true);
    zigulee.runChangeHandlers();
    _ = try r.renderWindow(win, .init(&pixels, 400, 100), .full);
    try testing.expect(px.white(115, 50));
    try testing.expect(px.shown(185, 50));
    press(win, 120, 50);
    try testing.expectEqual(@as(i32, 1), app.half_clicks.get());
    press(win, 180, 50);
    try testing.expectEqual(@as(i32, 2), app.half_clicks.get());
}

test "masks drawn by elements: a picture through a hidden circle, a hole where a square is" {
    const mui = @import("ui_masksource");
    const app = try mui.MaskSource.create(gpa);
    defer app.destroy();
    const win = app.window();
    var pixels: [200 * 100]zigulee.core.Rgba8 = undefined;
    var r: zigulee.software.Renderer(zigulee.core.Rgba8) = .init(gpa);
    defer r.deinit();
    const Px = struct {
        pixels: []const zigulee.core.Rgba8,
        fn white(p: @This(), x: usize, y: usize) bool {
            const c = p.pixels[y * 200 + x];
            return c.r == 255 and c.g == 255 and c.b == 255;
        }
    };
    const px: Px = .{ .pixels = &pixels };
    zigulee.runChangeHandlers();
    _ = try r.renderWindow(win, .init(&pixels, 200, 100), .full);
    // The green square through the disc (radius 30 about 50, 50); the disc
    // itself, hidden, not drawn.
    try testing.expect(!px.white(50, 50));
    try testing.expect(!px.white(50, 22));
    try testing.expect(px.white(12, 12));
    try testing.expect(px.white(85, 85));
    // The blue square but where the hidden square is (130 to 170).
    try testing.expect(!px.white(115, 15));
    try testing.expect(!px.white(185, 85));
    try testing.expect(px.white(150, 50));

    // A smaller disc: redrawn as a full frame would.
    app.size.set(20);
    zigulee.runChangeHandlers();
    var partial = pixels;
    _ = try r.renderWindow(win, .init(&partial, 200, 100), .partial);
    _ = try r.renderWindow(win, .init(&pixels, 200, 100), .full);
    try testing.expectEqualSlices(zigulee.core.Rgba8, &pixels, &partial);
    try testing.expect(!px.white(50, 50));
    try testing.expect(px.white(50, 30));
}

test "a list of rows as tall as each one is: measured as they show, the rest estimated" {
    const vui = @import("ui_varlist");
    const app = try vui.Messages.create(gpa);
    defer app.destroy();
    const w = app.window();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "examples/fonts/inter/Inter-Regular.ttf", gpa, .limited(16 << 20));
    defer gpa.free(bytes);
    const font: zigulee.Font = try .init(bytes);
    w.default_font.set(&font);
    for (0..3) |_| zigulee.runChangeHandlers();
    const list = &app.list.list;

    // The rows in view, by row: where they are and how tall.
    const Row = struct { y: f32, h: f32 };
    const rows = struct {
        fn get(l: *zigulee.items.ListLayout, out: *[10]?Row) void {
            out.* = @splat(null);
            var children = l.item.layoutChildren();
            while (children.next()) |c| {
                const t: *zigulee.items.Text = @fieldParentPtr("item", c);
                const text = t.text.get();
                const index: usize = for (vui_messages, 0..) |m, i| {
                    if (std.mem.eql(u8, m, text)) break i;
                } else continue;
                out[index] = .{ .y = c.y.get(), .h = c.height.get() };
            }
        }
        const vui_messages = [_][]const u8{ "Hi", "A longer message that wraps over several lines of the list", "Ok", "Short", "Another rather long one, two or three lines at this width", "Yes", "No", "Fine", "One more message that takes a few lines to show", "End" };
    };
    var seen: [10]?Row = undefined;
    rows.get(list, &seen);
    const hi = seen[0].?;
    const long = seen[1].?;
    try testing.expectEqual(@as(f32, 0), hi.y);
    try testing.expect(long.h > 1.8 * hi.h);
    try testing.expectApproxEqAbs(hi.h, long.y, 0.01);
    try testing.expectApproxEqAbs(long.y + long.h, seen[2].?.y, 0.01);

    // Scrolled to the end: every row measured once, the content their sum.
    var guard: usize = 0;
    while (guard < 20) : (guard += 1) {
        app.list.root.viewport_y.set(200 - app.content.get());
        for (0..3) |_| zigulee.runChangeHandlers();
    }
    rows.get(list, &seen);
    const end = seen[9].?;
    try testing.expectApproxEqAbs(app.content.get(), end.y + end.h, 0.01);
    var sum: f32 = 0;
    for (list.heights.items) |h| {
        try testing.expect(h > 0);
        sum += h;
    }
    try testing.expectApproxEqAbs(sum, app.content.get(), 0.01);
}

test "svg images: a clip path, a mask, uses of a definition, a blur and text" {
    const sui = @import("ui_svgfeatures");
    const app = try sui.SvgFeatures.create(gpa);
    defer app.destroy();
    const w = app.window();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "examples/fonts/inter/Inter-Regular.ttf", gpa, .limited(16 << 20));
    defer gpa.free(bytes);
    const font: zigulee.Font = try .init(bytes);
    w.default_font.set(&font);
    zigulee.runChangeHandlers();
    var pixels: [256 * 128]zigulee.core.Rgba8 = undefined;
    var r: zigulee.software.Renderer(zigulee.core.Rgba8) = .init(gpa);
    defer r.deinit();
    _ = try r.renderWindow(w, .init(&pixels, 256, 128), .full);
    const Px = struct {
        pixels: []const zigulee.core.Rgba8,
        fn at(p: @This(), x: usize, y: usize) zigulee.core.Rgba8 {
            return p.pixels[y * 256 + x];
        }
        fn white(p: @This(), x: usize, y: usize) bool {
            const c = p.at(x, y);
            return c.r == 255 and c.g == 255 and c.b == 255;
        }
    };
    const px: Px = .{ .pixels = &pixels };
    // The circle (twice its size), its right half clipped away.
    try testing.expect(px.at(40, 64).g > 120 and px.at(40, 64).r < 60);
    try testing.expect(px.white(90, 64));
    // The blue through the mask's white, not its black.
    try testing.expect(px.at(150, 100).b > 200 and px.at(150, 100).r < 80);
    try testing.expect(px.white(230, 100));
    // The definition used twice.
    try testing.expect(px.at(20, 110).r > 200 and px.at(20, 110).g < 80);
    try testing.expect(px.at(50, 110).r > 200 and px.at(50, 110).g < 80);
    // The square blurred: dark inside, its edge spread out.
    try testing.expect(px.at(96, 96).r < 60);
    try testing.expect(!px.white(78, 96) and px.at(78, 96).r > 60);
    // The text, around its middle at 128: dark pixels left and right of it.
    var left = false;
    var right = false;
    for (0..30) |y| for (0..256) |x| {
        const c = px.at(x, 10 + y);
        if (c.r < 60 and c.g < 60 and c.b < 60) {
            if (x < 128) left = true else right = true;
        }
    };
    try testing.expect(left and right);
}

test "a string-returning function called from several bindings: each keeps its own result" {
    const sui = @import("ui_strfn");
    const app = try sui.StrFn.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    try testing.expectEqualStrings("item 1 of 1", app.first.get());
    try testing.expectEqualStrings("item 2 of 1", app.second.get());
    try testing.expectEqualStrings("item 3 of 1", app.third.get());
    try testing.expectEqualStrings("item 4 of 1 / item 5 of 1", app.both.get());
    try testing.expectEqualStrings("#6", app.called.get());
    try testing.expectEqualStrings("#7", app.called_too.get());
    // The rows of the for, each its own.
    var rows_seen: [3][]const u8 = undefined;
    var n: usize = 0;
    var it: ?*zigulee.Item = app.window().rootItem();
    while (it) |i| : (it = i.nextInTree()) {
        if (!std.mem.eql(u8, i.vtable.name, "Text")) continue;
        const t: *zigulee.items.Text = @fieldParentPtr("item", i);
        if (std.mem.startsWith(u8, t.text.get(), "item 1") and t.text.get().len > "item 1 of 1".len and n < rows_seen.len) {
            rows_seen[n] = t.text.get();
            n += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("item 10 of 1", rows_seen[0]);
    try testing.expectEqualStrings("item 11 of 1", rows_seen[1]);
    try testing.expectEqualStrings("item 12 of 1", rows_seen[2]);
    // All again, after what they read changed.
    app.n.set(2);
    try testing.expectEqualStrings("item 1 of 2", app.first.get());
    try testing.expectEqualStrings("item 3 of 2", app.third.get());
    try testing.expectEqualStrings("item 4 of 2 / item 5 of 2", app.both.get());
    try testing.expectEqualStrings("item 2 of 2", app.second.get());

    // Structs of strings, and lists, each call its own.
    app.n.set(1);
    try testing.expectEqualStrings("p1/1", app.p1.get().name);
    try testing.expectEqualStrings("p2/1", app.p2.get().name);
    try testing.expectEqualStrings("p3/1", app.p3.get().name);
    try testing.expectEqualStrings("p1/1", app.p1.get().name);
    const l1 = app.l1.get();
    const l2 = app.l2.get();
    try testing.expect(l1.ptr != l2.ptr);
    try testing.expectEqualStrings("b1/1", l1.rowData(1).?);
    try testing.expectEqualStrings("b2/1", l2.rowData(1).?);
    const q1 = app.q1.get();
    const q2 = app.q2.get();
    try testing.expectEqualStrings("x1", q1.rowData(0).?.name);
    try testing.expectEqualStrings("p2/1", q2.rowData(1).?.name);
    try testing.expectEqualStrings("p1/1", q1.rowData(1).?.name);
    // What they read changed: each again, still their own.
    app.n.set(3);
    try testing.expectEqualStrings("b2/3", app.l2.get().rowData(1).?);
    try testing.expectEqualStrings("b1/3", app.l1.get().rowData(1).?);
    try testing.expectEqualStrings("p2/3", app.q2.get().rowData(1).?.name);
    try testing.expectEqualStrings("p1/3", app.q1.get().rowData(1).?.name);
    try testing.expectEqualStrings("p3/3", app.p3.get().name);
    try testing.expectEqualStrings("p1/3", app.p1.get().name);
}

test "letter spacing and text fitted to its box, from .zge" {
    const tui = @import("ui_textfit");
    const app = try tui.TextFit.create(gpa);
    defer app.destroy();
    const w = app.window();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "examples/fonts/inter/Inter-Regular.ttf", gpa, .limited(16 << 20));
    defer gpa.free(bytes);
    const font: zigulee.Font = try .init(bytes);
    w.default_font.set(&font);
    zigulee.runChangeHandlers();
    var fitted: ?*zigulee.items.Text = null;
    var spaced: ?*zigulee.items.Text = null;
    var it: ?*zigulee.Item = w.rootItem();
    while (it) |i| : (it = i.nextInTree()) {
        if (!std.mem.eql(u8, i.vtable.name, "Text")) continue;
        const t: *zigulee.items.Text = @fieldParentPtr("item", i);
        if (std.mem.eql(u8, t.text.get(), "Fitted text")) fitted = t;
        if (std.mem.eql(u8, t.text.get(), "Spaced")) spaced = t;
    }
    const f = fitted.?;
    const s = spaced.?;
    try testing.expectEqual(@as(f32, 2), s.letter_spacing.get());
    app.spacing.set(4);
    try testing.expectEqual(@as(f32, 4), s.letter_spacing.get());

    // 60 pixels wide: well under 40px, and the text fits at that size.
    const small = f.fittedFontSize();
    try testing.expect(small < 40 and small >= 8);
    try testing.expect(zigulee.core.text.measure(&font, "Fitted text", small, null).width <= 60);
    try testing.expect(zigulee.core.text.measure(&font, "Fitted text", small + 0.5, null).width > 60);
    // Room for it all: its own size.
    app.box_width.set(1000);
    try testing.expectEqual(@as(f32, 40), f.fittedFontSize());
}

test "anchors (compiled): edges, margins, fill, centering, following changes" {
    const aui = @import("ui_anchors");
    const app = try aui.Anchors.create(gpa);
    defer app.destroy();
    try testing.expectEqualStrings("10 10 50 170", app.side_at.get());
    try testing.expectEqualStrings("5 5 40 160", app.inner_at.get());
    try testing.expectEqualStrings("64 10 236 30", app.next_at.get());
    try testing.expectEqualStrings("280 190", app.corner_at.get());
    try testing.expectEqualStrings("130 80", app.middle_at.get());
    try testing.expect(app.label_centered.get());
    try testing.expect(app.ok_placed.get());
    app.gap.set(0);
    try testing.expectEqualStrings("0 0 50 180", app.side_at.get());
    try testing.expectEqualStrings("54 0 246 30", app.next_at.get());
    app.window().setSize(.{ .width = 400, .height = 100 });
    try testing.expectEqualStrings("380 90", app.corner_at.get());
    try testing.expectEqualStrings("180 30", app.middle_at.get());
    try testing.expect(app.label_centered.get());
    try testing.expect(app.ok_placed.get());
}

test "Canvas (compiled): paths, clips, transforms and fading; painted again on changes" {
    const cui = @import("ui_canvas");
    const app = try cui.Drawing.create(gpa);
    defer app.destroy();
    const win = app.window();
    var pixels: [200 * 100]zigulee.core.Rgba8 = undefined;
    var r: zigulee.software.Renderer(zigulee.core.Rgba8) = .init(gpa);
    defer r.deinit();
    const at = struct {
        fn f(p: []const zigulee.core.Rgba8, x: usize, y: usize) zigulee.core.Rgba8 {
            return p[y * 200 + x];
        }
    }.f;
    zigulee.runChangeHandlers();
    _ = try r.renderWindow(win, .init(&pixels, 200, 100), .full);
    // The bar: a quarter of the width.
    try testing.expectEqual(@as(u8, 0xdc), at(&pixels, 45, 10).r);
    try testing.expectEqual(@as(u8, 0xff), at(&pixels, 55, 10).g);
    // The disc's left half only.
    try testing.expectEqual(@as(u8, 0xa3), at(&pixels, 140, 60).g);
    try testing.expectEqual(@as(u8, 0xff), at(&pixels, 160, 60).r);
    // The square, turned: its corner points up, at about 40, 46; half blue.
    const mid = at(&pixels, 40, 50);
    try testing.expect(mid.b == 0xff and mid.r > 100 and mid.r < 156);
    try testing.expectEqual(@as(u8, 0xff), at(&pixels, 31, 51).r);

    // What it read changed: painted again.
    app.level.set(0.5);
    zigulee.runChangeHandlers();
    var partial = pixels;
    _ = try r.renderWindow(win, .init(&partial, 200, 100), .partial);
    _ = try r.renderWindow(win, .init(&pixels, 200, 100), .full);
    try testing.expectEqualSlices(zigulee.core.Rgba8, &pixels, &partial);
    try testing.expectEqual(@as(u8, 0xdc), at(&pixels, 95, 10).r);
    try testing.expectEqual(@as(u8, 0x26), at(&pixels, 95, 10).g);
}

test "a scroll view's scroll bars follow its content: grown, added, shown" {
    const sui = @import("ui_scrollview");
    const app = try sui.Scrolls.create(gpa);
    defer app.destroy();
    zigulee.runChangeHandlers();
    // 98 px seen (inside the border): two 30 px rows fit.
    const seen = app.grows.visible_height.get();
    try testing.expectEqual(@as(f32, 98), seen);
    try testing.expectEqual(seen, app.grows.viewport_height.get());
    app.rows.set(5);
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(f32, 150), app.grows.viewport_height.get());

    try testing.expectEqual(seen, app.comes.viewport_height.get());
    app.added.set(true);
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(f32, 300), app.comes.viewport_height.get());
    app.added.set(false);
    zigulee.runChangeHandlers();
    try testing.expectEqual(seen, app.comes.viewport_height.get());

    try testing.expectEqual(seen, app.shows.viewport_height.get());
    app.shown.set(true);
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(f32, 300), app.shows.viewport_height.get());
}
