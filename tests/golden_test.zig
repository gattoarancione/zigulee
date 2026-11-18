// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Golden-image tests for the software renderer. Scenes are built from
//! items in a window, rendered, and compared with PNGs in `tests/golden`.
//! Run `zig build test -Dupdate-golden` to accept new output (then review
//! the images). Mismatches are written to `tests/golden/failures`.

const std = @import("std");
const testing = std.testing;
const zigulee = @import("zigulee");
const build_options = @import("build_options");
const core = zigulee.core;
const items = core.items;
const software = zigulee.software;
const Rgba8 = core.Rgba8;
const Color = core.Color;
const Brush = core.Brush;

const gpa = testing.allocator;

const Frame = struct {
    width: u32,
    height: u32,
    pixels: []Rgba8,

    fn init(width: u32, height: u32) !Frame {
        const pixels = try gpa.alloc(Rgba8, @as(usize, width) * height);
        @memset(pixels, .transparent);
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    fn deinit(f: *Frame) void {
        gpa.free(f.pixels);
    }

    fn canvas(f: *Frame) software.Canvas(Rgba8) {
        return .init(f.pixels, f.width, f.height);
    }

    fn at(f: *const Frame, x: u32, y: u32) Rgba8 {
        return f.pixels[@as(usize, y) * f.width + x];
    }
};

fn render(window: *core.Window, mode: core.RenderMode, frame: *Frame) !void {
    try renderScaled(window, mode, frame, 1);
}

/// Renders with the software renderer and, for full frames, checks that the
/// GPU renderer's frame (run on the CPU) shows the same.
fn renderScaled(window: *core.Window, mode: core.RenderMode, frame: *Frame, scale: f32) !void {
    const before = try gpa.dupe(Rgba8, frame.pixels);
    defer gpa.free(before);
    var r: software.Renderer(Rgba8) = .init(gpa);
    defer r.deinit();
    r.scale_factor = scale;
    _ = try r.renderWindow(window, frame.canvas(), mode);
    if (mode == .full) try expectGpuMatches(window, frame, before, scale);
}

/// The GPU renderer's output (run on the CPU), over `before`, against the
/// software renderer's: rounding may differ, by 2 at most.
fn expectGpuMatches(window: *core.Window, frame: *const Frame, before: []Rgba8, scale: f32) !void {
    var batcher: zigulee.gpu.Batcher = try .init(gpa);
    defer batcher.deinit();
    batcher.scale_factor = scale;
    const gpu_frame = try batcher.build(window, frame.width, frame.height, .full);
    zigulee.gpu.reference.execute(&gpu_frame, before);
    var off: usize = 0;
    var worst: u8 = 0;
    for (frame.pixels, before) |e, a| {
        var d: u8 = 0;
        inline for (.{ "r", "g", "b", "a" }) |c| d = @max(d, @as(u8, @intCast(@abs(@as(i16, @field(e, c)) - @field(a, c)))));
        worst = @max(worst, d);
        if (d > 2) off += 1;
    }
    if (off > 0) {
        std.debug.print("GPU frame: {d} of {d} pixels differ by more than 2 (worst {d})\n", .{ off, frame.pixels.len, worst });
        const png = try core.png.encode(gpa, frame.width, frame.height, before);
        defer gpa.free(png);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = build_options.golden_dir ++ "/failures/gpu.png", .data = png });
        return error.GpuMismatch;
    }
}

fn expectGolden(name: []const u8, frame: *const Frame) !void {
    const io = testing.io;
    const dir = std.Io.Dir.cwd();
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ build_options.golden_dir, name });
    defer gpa.free(path);
    const actual = try core.png.encode(gpa, frame.width, frame.height, frame.pixels);
    defer gpa.free(actual);

    if (build_options.update_golden) {
        try dir.writeFile(io, .{ .sub_path = path, .data = actual });
        return;
    }
    const bytes = dir.readFileAlloc(io, path, gpa, .limited(64 << 20)) catch |err| {
        std.debug.print("golden image {s} missing ({t}); run `zig build test -Dupdate-golden`\n", .{ path, err });
        return error.GoldenMissing;
    };
    defer gpa.free(bytes);
    var expected = try core.png.decode(gpa, bytes);
    defer expected.deinit(gpa);

    var mismatches: usize = 0;
    if (expected.width == frame.width and expected.height == frame.height) {
        for (expected.pixels, frame.pixels) |e, a| {
            const close = @abs(@as(i16, e.r) - a.r) <= 1 and @abs(@as(i16, e.g) - a.g) <= 1 and
                @abs(@as(i16, e.b) - a.b) <= 1 and @abs(@as(i16, e.a) - a.a) <= 1;
            if (!close) mismatches += 1;
        }
    } else mismatches = frame.pixels.len;
    if (mismatches == 0) return;

    const failures = try std.fmt.allocPrint(gpa, "{s}/failures", .{build_options.golden_dir});
    defer gpa.free(failures);
    try dir.createDirPath(io, failures);
    const out = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ failures, name });
    defer gpa.free(out);
    try dir.writeFile(io, .{ .sub_path = out, .data = actual });
    std.debug.print("{s}: {d} pixels differ from the golden image; actual output written to {s}\n", .{ name, mismatches, out });
    return error.GoldenMismatch;
}

fn rect(r: *items.Rectangle, x: f32, y: f32, w: f32, h: f32) void {
    r.item.setGeometry(.{ .x = x, .y = y, .width = w, .height = h });
}

/// Basic shapes: fills, rounding, borders, alpha, opacity, AA edges.
const Shapes = struct {
    window: core.Window = undefined,
    font_bytes: []u8 = &.{},
    font: core.Font = undefined,
    label: items.Text = .{},
    solid: items.Rectangle = .{},
    rounded: items.Rectangle = .{},
    bordered: items.Rectangle = .{},
    circle: items.Rectangle = .{},
    under: items.Rectangle = .{},
    over: items.Rectangle = .{},
    faded: items.Rectangle = .{},
    faded_child: items.Rectangle = .{},
    fractional: items.Rectangle = .{},

    fn create() !*Shapes {
        const s = try gpa.create(Shapes);
        s.* = .{};
        s.font_bytes = try core.text.test_font.standard(gpa);
        s.font = try .init(s.font_bytes);
        s.window.init(gpa, .{ .width = 200, .height = 120 });
        s.window.default_font.set(&s.font);
        s.window.rootItem().appendChildren(&.{
            &s.solid.item, &s.rounded.item, &s.bordered.item, &s.circle.item,
            &s.under.item, &s.over.item,    &s.faded.item,    &s.fractional.item,
            &s.label.item,
        });
        s.label.item.setGeometry(.{ .x = 136.25, .y = 102, .width = 60, .height = 16 });
        s.label.text.set("AB Oi");
        s.label.font_size.set(14);
        rect(&s.solid, 10, 10, 40, 40);
        s.solid.background.set(.color(.rgb(0xe11d48)));
        rect(&s.rounded, 60, 10, 50, 40);
        s.rounded.background.set(.color(.rgb(0x2563eb)));
        s.rounded.border_radius.set(12);
        rect(&s.bordered, 120, 10, 70, 40);
        s.bordered.background.set(.color(.rgb(0xfde047)));
        s.bordered.border_color.set(.color(.rgb(0x111827)));
        s.bordered.border_width.set(3);
        s.bordered.border_radius.set(8);
        rect(&s.circle, 10, 60, 40, 40);
        s.circle.background.set(.color(.rgb(0x16a34a)));
        s.circle.border_radius.set(20);
        rect(&s.under, 60, 60, 40, 30);
        s.under.background.set(.color(.rgba(0x7c3aed80)));
        rect(&s.over, 80, 75, 40, 30);
        s.over.background.set(.color(.rgba(0xf9731680)));
        rect(&s.faded, 140, 60, 50, 40);
        s.faded.item.opacity.set(0.5);
        s.faded.background.set(.color(.rgb(0x0f172a)));
        s.faded.item.appendChild(&s.faded_child.item);
        rect(&s.faded_child, 10, 10, 30, 20);
        s.faded_child.background.set(.color(.rgb(0xf43f5e)));
        rect(&s.fractional, 10.5, 105.25, 120.5, 10);
        s.fractional.background.set(.color(.black));
        return s;
    }

    fn destroy(s: *Shapes) void {
        s.window.deinit();
        inline for (.{ "solid", "rounded", "bordered", "circle", "under", "over", "faded_child", "faded", "fractional", "label" }) |f|
            @field(s, f).deinit();
        gpa.free(s.font_bytes);
        gpa.destroy(s);
    }
};

test "golden: shapes" {
    const s = try Shapes.create();
    defer s.destroy();
    var frame: Frame = try .init(200, 120);
    defer frame.deinit();
    try render(&s.window, .full, &frame);
    // Spot checks independent of the golden file.
    try testing.expectEqual(Color.rgb(0xe11d48).premultiplied(), frame.at(30, 30));
    try testing.expectEqual(Color.white.premultiplied(), frame.at(60, 10)); // rounded corner cut off
    try testing.expectEqual(Color.rgb(0x111827).premultiplied(), frame.at(121, 30)); // border
    try expectGolden("shapes", &frame);
}

test "golden: gradients" {
    var window: core.Window = undefined;
    window.init(gpa, .{ .width = 200, .height = 100 });
    var a: items.Rectangle = .{};
    var b: items.Rectangle = .{};
    var c: items.Rectangle = .{};
    var d: items.Rectangle = .{};
    defer {
        window.deinit();
        a.deinit();
        b.deinit();
        c.deinit();
        d.deinit();
    }
    window.rootItem().appendChildren(&.{ &a.item, &b.item, &c.item, &d.item });
    rect(&a, 10, 10, 80, 35);
    a.background.set(.linear(90, &.{ .{ .color = .rgb(0xef4444), .position = 0 }, .{ .color = .rgb(0x3b82f6), .position = 1 } }));
    rect(&b, 110, 10, 80, 35);
    b.background.set(.linear(180, &.{
        .{ .color = .rgb(0xfacc15), .position = 0 },
        .{ .color = .rgb(0x22c55e), .position = 0.5 },
        .{ .color = .rgba(0x22c55e00), .position = 1 },
    }));
    rect(&c, 10, 55, 80, 40);
    c.background.set(.radial(&.{ .{ .color = .white, .position = 0 }, .{ .color = .rgb(0x7c3aed), .position = 1 } }));
    rect(&d, 110, 55, 80, 40);
    d.background.set(.linear(45, &.{ .{ .color = .rgb(0x0ea5e9), .position = 0 }, .{ .color = .rgb(0xec4899), .position = 1 } }));
    d.border_radius.set(10);
    d.border_width.set(2);
    d.border_color.set(.linear(0, &.{ .{ .color = .black, .position = 0 }, .{ .color = .white, .position = 1 } }));

    var frame: Frame = try .init(200, 100);
    defer frame.deinit();
    try render(&window, .full, &frame);
    // Left edge red, right edge blue.
    try testing.expect(frame.at(11, 25).r > 200 and frame.at(11, 25).b < 80);
    try testing.expect(frame.at(88, 25).b > 200 and frame.at(88, 25).r < 80);
    try expectGolden("gradients", &frame);
}

test "golden: paths" {
    var window: core.Window = undefined;
    window.init(gpa, .{ .width = 200, .height = 100 });
    var star: items.Path = .{};
    var heart: items.Path = .{};
    var ring: items.Path = .{};
    var zigzag: items.Path = .{};
    var wave: items.Path = .{};
    defer {
        window.deinit();
        star.deinit();
        heart.deinit();
        ring.deinit();
        zigzag.deinit();
        wave.deinit();
    }
    window.rootItem().appendChildren(&.{ &star.item, &heart.item, &ring.item, &zigzag.item, &wave.item });

    star.item.setGeometry(.{ .x = 5, .y = 5, .width = 50, .height = 50 });
    star.commands.set("M50 0 L61 35 L98 35 L68 57 L79 91 L50 70 L21 91 L32 57 L2 35 L39 35 Z");
    star.viewbox.set(.{ .width = 100, .height = 100 });
    star.fill.set(.color(.rgb(0xf59e0b)));
    star.stroke.set(.color(.rgb(0x92400e)));
    star.stroke_width.set(2);

    heart.item.setGeometry(.{ .x = 70, .y = 8, .width = 50, .height = 45 });
    heart.commands.set("M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z");
    heart.fill.set(.linear(180, &.{ .{ .color = .rgb(0xfb7185), .position = 0 }, .{ .color = .rgb(0xbe123c), .position = 1 } }));

    ring.item.setGeometry(.{ .x = 135, .y = 5, .width = 50, .height = 50 });
    ring.commands.set("M 25 5 A 20 20 0 1 1 24.99 5");
    ring.viewbox.set(.{ .width = 50, .height = 50 });
    ring.stroke.set(.color(.rgb(0x0d9488)));
    ring.stroke_width.set(6);

    zigzag.item.setGeometry(.{ .x = 10, .y = 65, .width = 80, .height = 30 });
    zigzag.commands.set("M0 30 L10 0 L20 30 L30 0 L40 30 L50 0 L60 30 L70 0 L80 30");
    zigzag.stroke.set(.color(.rgb(0x1e293b)));
    zigzag.stroke_width.set(3);

    wave.item.setGeometry(.{ .x = 105, .y = 65, .width = 90, .height = 30 });
    wave.commands.set("M0 15 Q 11 0 22 15 T 45 15 T 67 15 T 90 15");
    wave.stroke.set(.linear(90, &.{ .{ .color = .rgb(0x6366f1), .position = 0 }, .{ .color = .rgb(0xec4899), .position = 1 } }));
    wave.stroke_width.set(4);

    var frame: Frame = try .init(200, 100);
    defer frame.deinit();
    try render(&window, .full, &frame);
    try testing.expectEqual(Color.rgb(0xf59e0b).premultiplied(), frame.at(30, 30)); // star center
    try testing.expectEqual(Color.white.premultiplied(), frame.at(160, 30)); // ring center is empty
    try expectGolden("paths", &frame);
}

/// A 4x4 test image: four 2x2 blocks (red, green, blue, translucent black).
fn checkerboard() !core.OwnedImage {
    var img: core.OwnedImage = try .init(gpa, 4, 4);
    const colors = [4]Color{ .rgb(0xef4444), .rgb(0x22c55e), .rgb(0x3b82f6), .rgba(0x00000080) };
    for (0..4) |y| for (0..4) |x| {
        img.pixels[y * 4 + x] = colors[(y / 2) * 2 + x / 2].premultiplied();
    };
    return img;
}

/// A 9x9 "button" frame: 3px dark border, light middle, for nine-slice.
fn buttonFrame() !core.OwnedImage {
    var img: core.OwnedImage = try .init(gpa, 9, 9);
    for (0..9) |y| for (0..9) |x| {
        const border = x < 3 or x >= 6 or y < 3 or y >= 6;
        img.pixels[y * 9 + x] = (if (border) Color.rgb(0x334155) else Color.rgb(0xe2e8f0)).premultiplied();
    };
    return img;
}

test "golden: images" {
    var board = try checkerboard();
    defer board.deinit(gpa);
    var frame_img = try buttonFrame();
    defer frame_img.deinit(gpa);

    var window: core.Window = undefined;
    window.init(gpa, .{ .width = 220, .height = 100 });
    var imgs: [6]items.Image = @splat(.{});
    defer {
        window.deinit();
        for (&imgs) |*i| i.deinit();
    }
    for (&imgs) |*i| window.rootItem().appendChild(&i.item);
    const setups = [_]struct { core.Rect, core.image.ImageFit, core.image.ImageRendering }{
        .{ .{ .x = 5, .y = 5, .width = 60, .height = 40 }, .fill, .smooth },
        .{ .{ .x = 75, .y = 5, .width = 60, .height = 40 }, .contain, .pixelated },
        .{ .{ .x = 145, .y = 5, .width = 60, .height = 40 }, .cover, .pixelated },
        .{ .{ .x = 5, .y = 55, .width = 40, .height = 40 }, .preserve, .pixelated },
    };
    for (setups, 0..) |setup, i| {
        imgs[i].item.setGeometry(setup[0]);
        imgs[i].source.set(board.image());
        imgs[i].image_fit.set(setup[1]);
        imgs[i].image_rendering.set(setup[2]);
    }
    imgs[4].item.setGeometry(.{ .x = 55, .y = 55, .width = 40, .height = 40 });
    imgs[4].source.set(board.image());
    imgs[4].image_fit.set(.fill);
    imgs[4].image_rendering.set(.pixelated);
    imgs[4].colorize.set(.color(.rgb(0x0ea5e9)));
    imgs[5].item.setGeometry(.{ .x = 105, .y = 55, .width = 110, .height = 40 });
    imgs[5].source.set(frame_img.image());
    imgs[5].image_rendering.set(.pixelated);
    imgs[5].nine_slice.set(.uniform(3));

    var frame: Frame = try .init(220, 100);
    defer frame.deinit();
    try render(&window, .full, &frame);
    // Nine-slice keeps a 3px border at any size.
    try testing.expectEqual(Color.rgb(0x334155).premultiplied(), frame.at(107, 75));
    try testing.expectEqual(Color.rgb(0xe2e8f0).premultiplied(), frame.at(109, 75));
    try testing.expectEqual(Color.rgb(0xe2e8f0).premultiplied(), frame.at(210, 75));
    try expectGolden("images", &frame);
}

test "golden: text" {
    const font_bytes = try core.text.test_font.standard(gpa);
    defer gpa.free(font_bytes);
    const font: core.Font = try .init(font_bytes);

    var window: core.Window = undefined;
    window.init(gpa, .{ .width = 220, .height = 120 });
    window.default_font.set(&font);
    var texts: [6]items.Text = @splat(.{});
    defer {
        window.deinit();
        for (&texts) |*t| t.deinit();
    }
    for (&texts) |*t| window.rootItem().appendChild(&t.item);

    // Plain, with kerning between A and B.
    texts[0].item.setGeometry(.{ .x = 5, .y = 5, .width = 120, .height = 24 });
    texts[0].text.set("AB OO C");
    texts[0].font_size.set(20);
    // Centered with a gradient.
    texts[1].item.setGeometry(.{ .x = 5, .y = 32, .width = 120, .height = 24 });
    texts[1].text.set("iBOi");
    texts[1].font_size.set(20);
    texts[1].horizontal_alignment.set(.center);
    texts[1].color.set(.linear(90, &.{ .{ .color = .rgb(0x2563eb), .position = 0 }, .{ .color = .rgb(0xdb2777), .position = 1 } }));
    // Word wrapping, right-aligned, vertically centered.
    texts[2].item.setGeometry(.{ .x = 130, .y = 5, .width = 85, .height = 80 });
    texts[2].text.set("OO BB AA OO iii");
    texts[2].font_size.set(16);
    texts[2].wrap.set(.word_wrap);
    texts[2].horizontal_alignment.set(.right);
    texts[2].vertical_alignment.set(.center);
    texts[2].color.set(.color(.rgb(0xdc2626)));
    // Large, bottom-aligned.
    texts[3].item.setGeometry(.{ .x = 5, .y = 60, .width = 100, .height = 55 });
    texts[3].text.set("BO");
    texts[3].font_size.set(40);
    texts[3].vertical_alignment.set(.bottom);
    texts[3].color.set(.color(.rgb(0x1d4ed8)));
    // Fractional position (subpixel glyph placement) and a missing glyph.
    texts[4].item.setGeometry(.{ .x = 110.3, .y = 90, .width = 100, .height = 14 });
    texts[4].text.set("AZA");
    texts[4].font_size.set(12);
    // Clipped to its own bounds.
    texts[5].item.setGeometry(.{ .x = 110, .y = 105, .width = 20, .height = 12 });
    texts[5].text.set("OOOO");
    texts[5].font_size.set(12);

    var frame: Frame = try .init(220, 120);
    defer frame.deinit();
    try render(&window, .full, &frame);
    try expectGolden("text", &frame);
    // The B of "AB" spans x 14..24 after kerning, y 11..21 above the
    // baseline at 21; its hole (x 17..21, y 11..17) stays empty.
    try testing.expectEqual(Color.white.premultiplied(), frame.at(19, 14));
    try testing.expectEqual(Color.black.premultiplied(), frame.at(15, 14));
    // Clipping: nothing drawn past the last text item's right edge.
    for (105..117) |y| try testing.expectEqual(Color.white.premultiplied(), frame.at(131, @intCast(y)));
}

fn loadFont(rel: []const u8) ![]u8 {
    const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ build_options.fonts_dir, rel });
    defer gpa.free(p);
    return std.Io.Dir.cwd().readFileAlloc(testing.io, p, gpa, .limited(16 << 20));
}

test "bundled Inter kerns through GPOS" {
    const bytes = try loadFont("inter/Inter-Regular.ttf");
    defer gpa.free(bytes);
    const font: core.Font = try .init(bytes);
    try testing.expect(font.kern == null); // no legacy table: GPOS only
    try testing.expect(font.gpos_kern != null);
    const g = struct {
        fn of(f: *const core.Font, c: u21) u16 {
            return f.glyphIndex(c);
        }
    }.of;
    try testing.expect(font.kerning(g(&font, 'A'), g(&font, 'V')) < 0);
    try testing.expect(font.kerning(g(&font, 'T'), g(&font, 'o')) < 0);
    try testing.expectEqual(@as(i16, 0), font.kerning(g(&font, 'l'), g(&font, 'l')));
    // Kerned text is narrower than the sum of its advances.
    const kerned = core.text.measure(&font, "AVATAR", 32, null).width;
    var plain: f32 = 0;
    for ("AVATAR") |c| plain += @as(f32, @floatFromInt(font.advanceWidth(g(&font, c)))) * font.scale(32);
    try testing.expect(kerned < plain - 5);
}

test "golden: bundled fonts" {
    const inter_bytes = try loadFont("inter/Inter-Regular.ttf");
    defer gpa.free(inter_bytes);
    const bold_bytes = try loadFont("inter/Inter-Bold.ttf");
    defer gpa.free(bold_bytes);
    const mono_bytes = try loadFont("jetbrains-mono/JetBrainsMono-Regular.ttf");
    defer gpa.free(mono_bytes);
    const inter: core.Font = try .init(inter_bytes);
    const bold: core.Font = try .init(bold_bytes);
    const mono: core.Font = try .init(mono_bytes);

    var window: core.Window = undefined;
    window.init(gpa, .{ .width = 260, .height = 130 });
    window.default_font.set(&inter);
    var texts: [5]items.Text = @splat(.{});
    defer {
        window.deinit();
        for (&texts) |*t| t.deinit();
    }
    for (&texts) |*t| window.rootItem().appendChild(&t.item);
    const lines = [_]struct { []const u8, ?*const core.Font, f32 }{
        .{ "AVATAR Tower WAVE", &bold, 22 },
        .{ "The quick brown fox jumps over the lazy dog.", null, 11 },
        .{ "Kerning: To Wa Yo LT AV", null, 16 },
        .{ "const x = try zigulee(); // mono", &mono, 12 },
        .{ "Small text at 9px: 0123456789", null, 9 },
    };
    var y: f32 = 6;
    for (lines, &texts) |line, *t| {
        t.text.set(line[0]);
        t.font.set(line[1]);
        t.font_size.set(line[2]);
        t.color.set(.color(.rgb(0x0f172a)));
        t.item.setGeometry(.{ .x = 8, .y = y, .width = 244, .height = line[2] * 1.4 });
        y += line[2] * 1.4 + 4;
    }

    var frame: Frame = try .init(260, 130);
    defer frame.deinit();
    try render(&window, .full, &frame);
    try expectGolden("bundled_fonts", &frame);
}

test "golden: elided text and fallback fonts" {
    const inter_bytes = try loadFont("inter/Inter-Regular.ttf");
    defer gpa.free(inter_bytes);
    const mono_bytes = try loadFont("jetbrains-mono/JetBrainsMono-Regular.ttf");
    defer gpa.free(mono_bytes);
    const inter: core.Font = try .init(inter_bytes);
    const mono: core.Font = try .init(mono_bytes);
    // Inter has no box drawing or block characters; JetBrains Mono does.
    try testing.expectEqual(@as(u16, 0), inter.glyphIndex(0x2588));

    var window: core.Window = undefined;
    window.init(gpa, .{ .width = 220, .height = 150 });
    window.default_font.set(&inter);
    try window.addFallbackFont(&mono);
    var texts: [5]items.Text = @splat(.{});
    defer {
        window.deinit();
        for (&texts) |*t| t.deinit();
    }
    for (&texts) |*t| {
        window.rootItem().appendChild(&t.item);
        t.color.set(.color(.rgb(0x0f172a)));
        t.font_size.set(13);
    }
    // One line elided, left and right aligned; one that fits stays whole.
    texts[0].text.set("A label far too long for its box");
    texts[0].overflow.set(.elide);
    texts[0].item.setGeometry(.{ .x = 8, .y = 6, .width = 140, .height = 18 });
    texts[1].text.set("Right aligned, also too long");
    texts[1].overflow.set(.elide);
    texts[1].horizontal_alignment.set(.right);
    texts[1].item.setGeometry(.{ .x = 8, .y = 26, .width = 140, .height = 18 });
    texts[2].text.set("Fits");
    texts[2].overflow.set(.elide);
    texts[2].item.setGeometry(.{ .x = 8, .y = 46, .width = 140, .height = 18 });
    // Wrapped: the lines that fit, the last one ending with the ellipsis.
    texts[3].text.set("Wrapped text elides its last visible line when more text follows it in the paragraph.");
    texts[3].wrap.set(.word_wrap);
    texts[3].overflow.set(.elide);
    texts[3].item.setGeometry(.{ .x = 8, .y = 66, .width = 204, .height = 36 });
    // Characters from the fallback font, in the middle of Inter text.
    texts[4].text.set("Progress \u{2588}\u{2588}\u{2588}\u{2591}\u{2591} 60% \u{250C}\u{2500}\u{2510}");
    texts[4].item.setGeometry(.{ .x = 8, .y = 110, .width = 204, .height = 20 });

    // The elided text can shrink to its ellipsis; the one that fits keeps
    // its width as minimum otherwise.
    try testing.expect(texts[0].item.layoutInfo(.horizontal).min < 20);
    texts[2].overflow.set(.clip);
    try testing.expect(texts[2].item.layoutInfo(.horizontal).min > 20);
    texts[2].overflow.set(.elide);

    var frame: Frame = try .init(220, 150);
    defer frame.deinit();
    try render(&window, .full, &frame);
    try expectGolden("elide_fallback", &frame);
}

test "golden: pre-rendered (bitmap) fonts" {
    const inter_bytes = try loadFont("inter/Inter-Regular.ttf");
    defer gpa.free(inter_bytes);
    const inter: core.Font = try .init(inter_bytes);
    var chars: [95 + 1]u21 = undefined;
    for (chars[0..95], 0x20..) |*c, cp| c.* = @intCast(cp);
    chars[95] = 0x2026;
    const bitmap_bytes = try zigulee.software.makeBitmapFont(gpa, &inter, &.{ 13, 24 }, &chars);
    defer gpa.free(bitmap_bytes);
    const bitmap: core.Font = try .init(bitmap_bytes);
    try testing.expect(bitmap.bitmap != null);
    // Laid out exactly like the TrueType font: same advances and kerning.
    for ([_][]const u8{ "Hello, bitmap fonts!", "AVATAR Tower WAVE", "0123456789" }) |t| {
        try testing.expectEqual(core.text.measure(&inter, t, 13, null), core.text.measure(&bitmap, t, 13, null));
    }
    try testing.expectEqual(@as(u16, 0), bitmap.glyphIndex(0x4e2d)); // not included

    var window: core.Window = undefined;
    window.init(gpa, .{ .width = 240, .height = 90 });
    var texts: [3]items.Text = @splat(.{});
    defer {
        window.deinit();
        for (&texts) |*t| t.deinit();
    }
    const rows = [_]struct { []const u8, *const core.Font, f32, f32 }{
        .{ "Pre-rendered at 13 px", &bitmap, 13, 6 },
        .{ "Outlines at 13 px", &inter, 13, 26 },
        .{ "Bitmap 24 px \u{2026}", &bitmap, 24, 48 },
    };
    for (rows, &texts) |row, *t| {
        window.rootItem().appendChild(&t.item);
        t.text.set(row[0]);
        t.font.set(row[1]);
        t.font_size.set(row[2]);
        t.color.set(.color(.rgb(0x0f172a)));
        t.item.setGeometry(.{ .x = 8, .y = row[3], .width = 224, .height = row[2] * 1.4 });
    }
    var frame: Frame = try .init(240, 90);
    defer frame.deinit();
    try render(&window, .full, &frame);
    try expectGolden("bitmap_font", &frame);
}

test "partial redraw produces the same pixels as a full redraw" {
    const s = try Shapes.create();
    defer s.destroy();
    var incremental: Frame = try .init(200, 120);
    defer incremental.deinit();
    var r: software.Renderer(Rgba8) = .init(gpa);
    defer r.deinit();
    _ = try r.renderWindow(&s.window, incremental.canvas(), .partial);

    s.solid.item.x.set(25.5);
    s.rounded.background.set(.color(.rgb(0x9333ea)));
    s.circle.item.visible.set(false);
    s.faded.item.opacity.set(0.8);
    s.label.text.set("OB iA");
    const region = try r.renderWindow(&s.window, incremental.canvas(), .partial);
    try testing.expect(region.boundingBox().area() < 200 * 120);

    var fresh: Frame = try .init(200, 120);
    defer fresh.deinit();
    try render(&s.window, .full, &fresh);
    try testing.expectEqualSlices(Rgba8, fresh.pixels, incremental.pixels);
}

test "GPU partial frames: over the last frame, the same pixels as a full one" {
    const s = try Shapes.create();
    defer s.destroy();
    var batcher: zigulee.gpu.Batcher = try .init(gpa);
    defer batcher.deinit();
    var incremental: Frame = try .init(200, 120);
    defer incremental.deinit();
    const first = try batcher.build(&s.window, 200, 120, .partial);
    try testing.expect(first.region.boundingBox().area() == 200 * 120);
    const full_vertices = first.vertices.len;
    zigulee.gpu.reference.execute(&first, incremental.pixels);

    // Nothing changed: an empty frame.
    const idle = try batcher.build(&s.window, 200, 120, .partial);
    try testing.expect(idle.region.isEmpty() and idle.vertices.len == 0);

    s.solid.item.x.set(25.5);
    s.rounded.background.set(.color(.rgb(0x9333ea)));
    s.label.text.set("OB iA");
    const partial = try batcher.build(&s.window, 200, 120, .partial);
    try testing.expect(!partial.full and partial.region.boundingBox().area() < 200 * 120);
    try testing.expect(partial.vertices.len < full_vertices);
    zigulee.gpu.reference.execute(&partial, incremental.pixels);

    var fresh: Frame = try .init(200, 120);
    defer fresh.deinit();
    try render(&s.window, .full, &fresh);
    for (fresh.pixels, incremental.pixels) |e, a| {
        inline for (.{ "r", "g", "b", "a" }) |c| try testing.expect(@abs(@as(i16, @field(e, c)) - @field(a, c)) <= 2);
    }
}

test "band rendering produces the same pixels as a full framebuffer" {
    const s = try Shapes.create();
    defer s.destroy();
    var full: Frame = try .init(200, 120);
    defer full.deinit();
    try render(&s.window, .full, &full);

    var assembled: Frame = try .init(200, 120);
    defer assembled.deinit();
    var band: [200 * 7]Rgba8 = undefined;
    var r: software.Renderer(Rgba8) = .init(gpa);
    defer r.deinit();
    var bands: usize = 0;
    const Sink = struct {
        frame: *Frame,
        bands: *usize,
        fn flush(sink: @This(), c: software.Canvas(Rgba8)) void {
            sink.bands.* += 1;
            for (0..c.height) |row| {
                const y: usize = @intCast(c.origin_y + @as(i32, @intCast(row)));
                const x: usize = @intCast(c.origin_x);
                @memcpy(sink.frame.pixels[y * sink.frame.width + x ..][0..c.width], c.pixels[row * c.stride ..][0..c.width]);
            }
        }
    };
    _ = try r.renderWindowInBands(&s.window, .full, &band, 7, Sink{ .frame = &assembled, .bands = &bands }, Sink.flush);
    try testing.expectEqual(@as(usize, 18), bands); // ceil(120 / 7)
    try testing.expectEqualSlices(Rgba8, full.pixels, assembled.pixels);
}

test "scale factor renders at physical resolution" {
    const s = try Shapes.create();
    defer s.destroy();
    var frame: Frame = try .init(400, 240);
    defer frame.deinit();
    var r: software.Renderer(Rgba8) = .init(gpa);
    defer r.deinit();
    r.scale_factor = 2;
    const region = try r.renderWindow(&s.window, frame.canvas(), .full);
    try testing.expectEqual(core.Rect{ .width = 400, .height = 240 }, region.boundingBox());
    // The 40x40 square at (10, 10) covers (20..100, 20..100).
    try testing.expectEqual(Color.rgb(0xe11d48).premultiplied(), frame.at(20, 20));
    try testing.expectEqual(Color.rgb(0xe11d48).premultiplied(), frame.at(99, 99));
    try testing.expectEqual(Color.white.premultiplied(), frame.at(19, 50));
    // Border of the bordered rectangle: 3 logical = 6 physical pixels.
    try testing.expectEqual(Color.rgb(0x111827).premultiplied(), frame.at(240 + 5, 60));
    try expectGolden("shapes_2x", &frame);
    const blank = try gpa.alloc(Rgba8, frame.pixels.len);
    defer gpa.free(blank);
    @memset(blank, .transparent);
    try expectGpuMatches(&s.window, &frame, blank, 2);
}

test "rgb565 rendering" {
    const s = try Shapes.create();
    defer s.destroy();
    var pixels: [200 * 120]software.Rgb565 = undefined;
    var r: software.Renderer(software.Rgb565) = .init(gpa);
    defer r.deinit();
    _ = try r.renderWindow(&s.window, .init(&pixels, 200, 120), .full);
    try testing.expectEqual(software.Rgb565.fromRgb8(0xe1, 0x1d, 0x48), pixels[30 * 200 + 30]);
    try testing.expectEqual(software.Rgb565.fromRgb8(0xff, 0xff, 0xff), pixels[0]);
}

/// The standard widgets of `ui` (tests/ui/widgets.zge built with one style)
/// in light and dark mode.
fn widgetsGolden(comptime ui: type, comptime name: []const u8) !void {
    const inter_bytes = try loadFont("inter/Inter-Regular.ttf");
    defer gpa.free(inter_bytes);
    const inter: core.Font = try .init(inter_bytes);

    const app = try ui.Widgets.create(gpa);
    defer app.destroy();
    defer app.dark.set(false); // the palette is a global
    app.window().default_font.set(&inter);
    app.agree.set(true);
    app.volume.set(3);
    app.name_text.set("Ada Lovelace");
    app.window().focusNext(); // the first button shows its focus ring

    var frame: Frame = try .init(300, 360);
    defer frame.deinit();
    try render(app.window(), .full, &frame);
    try expectGolden(name ++ "_light", &frame);

    // Colors animate: render once to start the animations, then again
    // when they are done.
    app.dark.set(true);
    try render(app.window(), .full, &frame);
    zigulee.updateTimersAndAnimations(core.now() + 1000);
    try render(app.window(), .full, &frame);
    try expectGolden(name ++ "_dark", &frame);
}

test "golden: standard widgets, light and dark" {
    try widgetsGolden(@import("ui_widgets"), "std_widgets");
}

test "golden: standard widgets, material style" {
    try widgetsGolden(@import("ui_widgets_material"), "std_widgets_material");
}

test "golden: standard widgets, minimal style" {
    try widgetsGolden(@import("ui_widgets_minimal"), "std_widgets_minimal");
}

test "golden: standard widgets, cupertino style" {
    try widgetsGolden(@import("ui_widgets_cupertino"), "std_widgets_cupertino");
}

test "golden: text editing" {
    const inter_bytes = try loadFont("inter/Inter-Regular.ttf");
    defer gpa.free(inter_bytes);
    const inter: core.Font = try .init(inter_bytes);

    var window: core.Window = undefined;
    window.init(gpa, .{ .width = 220, .height = 130 });
    window.default_font.set(&inter);
    var single: items.TextInput = undefined;
    single.init(gpa);
    var multi: items.TextInput = undefined;
    multi.init(gpa);
    defer {
        window.deinit();
        single.deinit();
        multi.deinit();
    }
    window.rootItem().appendChildren(&.{ &single.item, &multi.item });
    single.item.setGeometry(.{ .x = 10, .y = 8, .width = 200, .height = 24 });
    multi.item.setGeometry(.{ .x = 10, .y = 44, .width = 200, .height = 80 });

    // A selection across a word.
    single.text.set("Select some words");
    single.setSelection(7, 11);
    // Wrapped text with the caret in the middle of an input method
    // composition (underlined).
    multi.single_line.set(false);
    multi.wrap.set(.word_wrap);
    multi.text.set("Multi-line text wraps at word boundaries.\nSecond paragraph");
    multi.setSelection(17, 17);
    window.setFocusItem(&multi.item);
    window.dispatchPreedit("ime", 2);

    var frame: Frame = try .init(220, 130);
    defer frame.deinit();
    try render(&window, .full, &frame);
    try expectGolden("text_editing", &frame);
}

/// Effects: a blurred card with a child, a group of overlapping squares
/// faded as one, a blurred and faded one.
const Effects = struct {
    window: core.Window = undefined,
    card: items.Rectangle = .{},
    dot: items.Rectangle = .{},
    card_fx: core.ItemTransform = .{},
    group: items.Rectangle = .{},
    a: items.Rectangle = .{},
    b: items.Rectangle = .{},
    soft: items.Rectangle = .{},
    soft_fx: core.ItemTransform = .{},

    fn create() !*Effects {
        const e = try gpa.create(Effects);
        e.* = .{};
        e.window.init(gpa, .{ .width = 260, .height = 100 });
        e.window.rootItem().appendChildren(&.{ &e.card.item, &e.group.item, &e.soft.item });
        rect(&e.card, 10, 10, 80, 80);
        e.card.background.set(.color(.rgb(0x2563eb)));
        e.card.item.transform = &e.card_fx;
        e.card_fx.blur.set(4);
        e.card.item.appendChild(&e.dot.item);
        rect(&e.dot, 10, 10, 20, 20);
        e.dot.background.set(.color(.rgb(0xfde047)));
        // No background of its own: only its children, faded as one.
        rect(&e.group, 110, 10, 50, 50);
        e.group.item.opacity.set(0.5);
        e.group.item.appendChildren(&.{ &e.a.item, &e.b.item });
        rect(&e.a, 0, 0, 30, 30);
        e.a.background.set(.color(.rgb(0xe11d48)));
        rect(&e.b, 15, 15, 30, 30);
        e.b.background.set(.color(.rgb(0x16a34a)));
        rect(&e.soft, 200, 20, 30, 50);
        e.soft.background.set(.color(.rgb(0x111827)));
        e.soft.item.opacity.set(0.6);
        e.soft.item.transform = &e.soft_fx;
        e.soft_fx.blur.set(2);
        return e;
    }

    fn destroy(e: *Effects) void {
        e.window.deinit();
        inline for (.{ "dot", "card", "a", "b", "group", "soft" }) |f| @field(e, f).deinit();
        e.card_fx.deinit();
        e.soft_fx.deinit();
        gpa.destroy(e);
    }
};

test "golden: blur and layers" {
    const e = try Effects.create();
    defer e.destroy();
    var frame: Frame = try .init(260, 100);
    defer frame.deinit();
    try render(&e.window, .full, &frame);
    // Past the blur's reach (12) from the card's edges and the dot: its
    // color. Its blur shows outside it, fading.
    try testing.expectEqual(Color.rgb(0x2563eb).premultiplied(), frame.at(65, 65));
    const outside = frame.at(6, 50);
    try testing.expect(outside.r < 250 and outside.b > outside.r);
    try testing.expectEqual(Color.white.premultiplied(), frame.at(180, 95));
    // Where the faded squares overlap, only the green one shows, at half.
    const both = frame.at(110 + 22, 10 + 22);
    try testing.expect(@abs(@as(i16, both.r) - (0x16 + 255) / 2) <= 1);
    try testing.expect(@abs(@as(i16, both.g) - (0xa3 + 255) / 2) <= 1);
    try expectGolden("effects", &frame);
}

test "blur and layers: partial redraws and bands as a full frame" {
    const e = try Effects.create();
    defer e.destroy();
    var incremental: Frame = try .init(260, 100);
    defer incremental.deinit();
    var r: software.Renderer(Rgba8) = .init(gpa);
    defer r.deinit();
    _ = try r.renderWindow(&e.window, incremental.canvas(), .partial);
    // Inside the blurred card: what changes spreads as far as its blur.
    e.dot.item.x.set(30);
    e.b.background.set(.color(.rgb(0x7c3aed)));
    e.soft_fx.blur.set(3);
    const region = try r.renderWindow(&e.window, incremental.canvas(), .partial);
    try testing.expect(region.boundingBox().area() < 260 * 100);
    var fresh: Frame = try .init(260, 100);
    defer fresh.deinit();
    try render(&e.window, .full, &fresh);
    try testing.expectEqualSlices(Rgba8, fresh.pixels, incremental.pixels);

    var assembled: Frame = try .init(260, 100);
    defer assembled.deinit();
    var band: [260 * 9]Rgba8 = undefined;
    var banded: software.Renderer(Rgba8) = .init(gpa);
    defer banded.deinit();
    const Sink = struct {
        frame: *Frame,
        fn flush(sink: @This(), c: software.Canvas(Rgba8)) void {
            for (0..c.height) |row| {
                const y: usize = @intCast(c.origin_y + @as(i32, @intCast(row)));
                const x: usize = @intCast(c.origin_x);
                @memcpy(sink.frame.pixels[y * sink.frame.width + x ..][0..c.width], c.pixels[row * c.stride ..][0..c.width]);
            }
        }
    };
    _ = try banded.renderWindowInBands(&e.window, .full, &band, 9, Sink{ .frame = &assembled }, Sink.flush);
    try testing.expectEqualSlices(Rgba8, fresh.pixels, assembled.pixels);
}

test "blur and layers at a scale factor" {
    const e = try Effects.create();
    defer e.destroy();
    var frame: Frame = try .init(520, 200);
    defer frame.deinit();
    try renderScaled(&e.window, .full, &frame, 2);
    try testing.expectEqual(Color.rgb(0x2563eb).premultiplied(), frame.at(2 * 65, 2 * 65));
}

/// Clipping: a turned square clipping its child, a clip path cutting a
/// square and its child, a clip path inside a faded group, a blurred
/// square inside a clip path.
const Clipping = struct {
    window: core.Window = undefined,
    turned: items.Rectangle = .{},
    turned_fill: items.Rectangle = .{},
    turned_fx: core.ItemTransform = .{},
    cut: items.Rectangle = .{},
    cut_child: items.Rectangle = .{},
    cut_fx: core.ItemTransform = .{},
    faded: items.Rectangle = .{},
    faded_cut: items.Rectangle = .{},
    faded_fx: core.ItemTransform = .{},
    holder: items.Rectangle = .{},
    holder_fx: core.ItemTransform = .{},
    blurred: items.Rectangle = .{},
    blurred_fx: core.ItemTransform = .{},

    fn create() !*Clipping {
        const e = try gpa.create(Clipping);
        e.* = .{};
        e.window.init(gpa, .{ .width = 320, .height = 90 });
        e.window.rootItem().appendChildren(&.{ &e.turned.item, &e.cut.item, &e.faded.item, &e.holder.item });
        rect(&e.turned, 15, 15, 60, 60);
        e.turned.clip.set(true);
        e.turned.background.set(.color(.rgb(0xbfdbfe)));
        e.turned.item.transform = &e.turned_fx;
        e.turned_fx.rotation.set(30);
        e.turned.item.appendChild(&e.turned_fill.item);
        rect(&e.turned_fill, 30, -20, 60, 100);
        e.turned_fill.background.set(.color(.rgb(0xdc2626)));

        rect(&e.cut, 95, 10, 70, 70);
        e.cut.background.set(.color(.rgb(0x16a34a)));
        e.cut.item.transform = &e.cut_fx;
        e.cut_fx.clip_path.set("M 35 35 L 35 0 A 35 35 0 1 1 0 35 Z");
        e.cut.item.appendChild(&e.cut_child.item);
        rect(&e.cut_child, 0, 50, 70, 20);
        e.cut_child.background.set(.color(.rgb(0xfde047)));

        rect(&e.faded, 175, 10, 70, 70);
        e.faded.item.opacity.set(0.5);
        e.faded.item.appendChild(&e.faded_cut.item);
        rect(&e.faded_cut, 0, 0, 70, 70);
        e.faded_cut.background.set(.color(.rgb(0x7c3aed)));
        e.faded_cut.item.transform = &e.faded_fx;
        e.faded_fx.clip_path.set("M 0 0 L 70 35 L 0 70 Z");

        rect(&e.holder, 255, 10, 60, 70);
        e.holder.item.transform = &e.holder_fx;
        e.holder_fx.clip_path.set("M 0 0 L 60 0 L 60 70 Z");
        e.holder.item.appendChild(&e.blurred.item);
        rect(&e.blurred, 10, 10, 40, 50);
        e.blurred.background.set(.color(.rgb(0x111827)));
        e.blurred.item.transform = &e.blurred_fx;
        e.blurred_fx.blur.set(3);
        return e;
    }

    fn destroy(e: *Clipping) void {
        e.window.deinit();
        inline for (.{ "turned", "turned_fill", "cut", "cut_child", "faded", "faded_cut", "holder", "blurred" }) |f| @field(e, f).deinit();
        inline for (.{ "turned_fx", "cut_fx", "faded_fx", "holder_fx", "blurred_fx" }) |f| @field(e, f).deinit();
        gpa.destroy(e);
    }
};

test "golden: clipping, turned and by clip paths" {
    const e = try Clipping.create();
    defer e.destroy();
    var frame: Frame = try .init(320, 90);
    defer frame.deinit();
    try render(&e.window, .full, &frame);
    try expectGolden("clipping", &frame);
    // At a scale factor, the GPU's the same too.
    var scaled: Frame = try .init(640, 180);
    defer scaled.deinit();
    try renderScaled(&e.window, .full, &scaled, 2);
}

/// Masks: a card clipping round (only its corners masked), turned too; an
/// image's opacity masking an element and its child; a blurred child in a
/// rounded clip (its one image shown in pieces).
const Masks = struct {
    window: core.Window = undefined,
    card: items.Rectangle = .{},
    card_fill: items.Rectangle = .{},
    card_bar: items.Rectangle = .{},
    turned: items.Rectangle = .{},
    turned_fill: items.Rectangle = .{},
    turned_fx: core.ItemTransform = .{},
    masked: items.Rectangle = .{},
    masked_child: items.Rectangle = .{},
    masked_fx: core.ItemTransform = .{},
    mask: [16 * 16]Rgba8 = undefined,
    frame: items.Rectangle = .{},
    blurred: items.Rectangle = .{},
    blurred_fx: core.ItemTransform = .{},

    fn create() !*Masks {
        const e = try gpa.create(Masks);
        e.* = .{};
        e.window.init(gpa, .{ .width = 320, .height = 90 });
        e.window.rootItem().appendChildren(&.{ &e.card.item, &e.turned.item, &e.masked.item, &e.frame.item });
        rect(&e.card, 10, 10, 70, 70);
        e.card.clip.set(true);
        e.card.border_radius.set(18);
        e.card.item.appendChildren(&.{ &e.card_fill.item, &e.card_bar.item });
        rect(&e.card_fill, -10, -10, 90, 90);
        e.card_fill.background.set(.color(.rgb(0xdc2626)));
        rect(&e.card_bar, 0, 52, 70, 18);
        e.card_bar.background.set(.color(.rgb(0x1d4ed8)));

        rect(&e.turned, 100, 15, 60, 60);
        e.turned.clip.set(true);
        e.turned.border_radius.set(16);
        e.turned.background.set(.color(.rgb(0xbfdbfe)));
        e.turned.item.transform = &e.turned_fx;
        e.turned_fx.rotation.set(20);
        e.turned.item.appendChild(&e.turned_fill.item);
        rect(&e.turned_fill, 30, -20, 60, 100);
        e.turned_fill.background.set(.color(.rgb(0x16a34a)));

        // A disc fading out from the middle.
        for (0..16) |y| for (0..16) |x| {
            const dx = @as(f32, @floatFromInt(x)) - 7.5;
            const dy = @as(f32, @floatFromInt(y)) - 7.5;
            const a: u8 = @intFromFloat(std.math.clamp(255 - @sqrt(dx * dx + dy * dy) * 32, 0, 255));
            e.mask[y * 16 + x] = .{ .r = a, .g = a, .b = a, .a = a };
        };
        rect(&e.masked, 180, 10, 60, 70);
        e.masked.background.set(.color(.rgb(0x7c3aed)));
        e.masked.item.transform = &e.masked_fx;
        e.masked_fx.mask_image.set(.{ .width = 16, .height = 16, .pixels = &e.mask });
        e.masked.item.appendChild(&e.masked_child.item);
        rect(&e.masked_child, 0, 0, 30, 70);
        e.masked_child.background.set(.color(.rgb(0xfde047)));

        rect(&e.frame, 255, 10, 60, 70);
        e.frame.clip.set(true);
        e.frame.border_radius.set(22);
        e.frame.background.set(.color(.rgb(0xe5e7eb)));
        e.frame.item.appendChild(&e.blurred.item);
        rect(&e.blurred, 5, 5, 50, 60);
        e.blurred.background.set(.color(.rgb(0x111827)));
        e.blurred.item.transform = &e.blurred_fx;
        e.blurred_fx.blur.set(4);
        return e;
    }

    fn destroy(e: *Masks) void {
        e.window.deinit();
        inline for (.{ "card", "card_fill", "card_bar", "turned", "turned_fill", "masked", "masked_child", "frame", "blurred" }) |f| @field(e, f).deinit();
        inline for (.{ "turned_fx", "masked_fx", "blurred_fx" }) |f| @field(e, f).deinit();
        gpa.destroy(e);
    }
};

test "golden: masks, rounded clips and images" {
    const e = try Masks.create();
    defer e.destroy();
    var frame: Frame = try .init(320, 90);
    defer frame.deinit();
    try render(&e.window, .full, &frame);
    try expectGolden("masks", &frame);
    // At scale factors (the corners' pieces meeting between pixels too),
    // the GPU's the same.
    inline for (.{ 2, 1.5 }) |scale| {
        var scaled: Frame = try .init(@intFromFloat(320 * scale), @intFromFloat(90 * scale));
        defer scaled.deinit();
        try renderScaled(&e.window, .full, &scaled, scale);
    }
}

test "golden: a mask drawn by an element, inverted too: the GPU's the same" {
    var window: core.Window = undefined;
    window.init(gpa, .{ .width = 120, .height = 60 });
    defer window.deinit();
    var shown: items.Rectangle = .{};
    var disc: items.Rectangle = .{};
    var holed: items.Rectangle = .{};
    var hole: items.Rectangle = .{};
    var shown_fx: core.ItemTransform = .{};
    var holed_fx: core.ItemTransform = .{};
    defer {
        inline for (.{ &shown, &disc, &holed, &hole }) |r| r.deinit();
        shown_fx.deinit();
        holed_fx.deinit();
    }
    window.rootItem().appendChildren(&.{ &shown.item, &holed.item });
    rect(&shown, 5, 5, 50, 50);
    shown.background.set(.linear(90, &.{ .{ .color = .rgb(0x16a34a), .position = 0 }, .{ .color = .rgb(0xfde047), .position = 1 } }));
    shown.item.transform = &shown_fx;
    shown_fx.mask_source = &disc.item;
    shown.item.appendChild(&disc.item);
    disc.item.visible.set(false);
    rect(&disc, 5, 5, 40, 40);
    disc.border_radius.set(20);
    disc.background.set(.color(.rgba(0x000000c0)));

    rect(&holed, 65, 5, 50, 50);
    holed.background.set(.color(.rgb(0x2563eb)));
    holed.item.transform = &holed_fx;
    holed_fx.mask_source = &hole.item;
    holed_fx.mask_inverted.set(true);
    holed_fx.rotation.set(15);
    rect(&hole, 15, 15, 20, 20);
    hole.border_radius.set(4);
    hole.background.set(.color(.rgb(0x000000)));

    var frame: Frame = try .init(120, 60);
    defer frame.deinit();
    try render(&window, .full, &frame);
    var scaled: Frame = try .init(240, 120);
    defer scaled.deinit();
    try renderScaled(&window, .full, &scaled, 2);
}
