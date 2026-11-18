// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! `Canvas`: 2D drawing from code, as QML's Canvas and HTML's. Its `paint`
//! handler calls drawing functions (`begin-path()`, `line-to(x, y)`,
//! `fill()`...), which are recorded and drawn by any renderer as paths,
//! text and images. `paint` runs again when the canvas is resized, when
//! what it read changes, and on `request-paint()`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const properties = @import("properties.zig");
const Property = properties.Property;
const Callback = @import("callbacks.zig").Callback;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const ItemVTable = item_mod.ItemVTable;
const rendering = @import("rendering.zig");
const ItemRenderer = rendering.ItemRenderer;
const graphics = @import("graphics.zig");
const Brush = graphics.Brush;
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Size = geometry.Size;
const Affine = geometry.Affine;
const image = @import("image.zig");
const items = @import("items.zig");
const text_mod = @import("text/text.zig");

pub const Canvas = struct {
    item: Item = .init(&vtable),
    /// How shapes are filled and stroked (and text filled) by the drawing
    /// functions that follow.
    fill_style: Property(Brush) = .init(.color(.black)),
    stroke_style: Property(Brush) = .init(.color(.black)),
    line_width: Property(f32) = .init(1),
    /// Multiplies the opacity of what is drawn.
    global_alpha: Property(f32) = .init(1),
    font_size: Property(f32) = .init(14),
    font_family: Property([]const u8) = .init(""),
    font_weight: Property(i32) = .init(400),
    /// Where `fill-text`'s x is: the text's left, center or right.
    text_align: Property(rendering.TextHorizontalAlignment) = .init(.left),
    paint: Callback(fn () void) = .{},

    gpa: Allocator = undefined,
    /// What the last `paint` drew.
    ops: std.ArrayList(Op) = .empty,
    arena: std.heap.ArenaAllocator = undefined,
    /// Changed after each paint: the item is drawn again.
    version: Property(u32) = .init(0),
    tracker: properties.PropertyTracker = undefined,
    repaint: properties.Deferred = undefined,
    painting: bool = false,

    // The drawing state while painting.
    transform: Affine = .{},
    saved: std.ArrayList(Saved) = .empty,
    /// The current path, in the item's coordinates (transformed as its
    /// points were added).
    path: std.ArrayList(u8) = .empty,
    /// The current point and the start of the subpath, in the canvas's
    /// coordinates as given (before the transform).
    current: ?Point = null,
    start: Point = .{},

    const Op = union(enum) {
        path: struct { commands: []const u8, fill: Brush, stroke: Brush, width: f32, alpha: f32 },
        text: TextOp,
        image: struct { image: image.Image, box: geometry.Rect, transform: Affine, alpha: f32 },
        clip: []const u8,
        save,
        restore,
    };

    const TextOp = struct {
        text: []const u8,
        at: Point,
        transform: Affine,
        size: f32,
        family: []const u8,
        weight: i32,
        alignment: rendering.TextHorizontalAlignment,
        color: Brush,
        alpha: f32,
    };

    const Saved = struct {
        transform: Affine,
        fill: Brush,
        stroke: Brush,
        line_width: f32,
        alpha: f32,
        font_size: f32,
        font_family: []const u8,
        font_weight: i32,
        text_align: rendering.TextHorizontalAlignment,
    };

    const vtable: ItemVTable = .{ .name = "Canvas", .render = render };

    pub fn init(self: *Canvas, gpa: Allocator) void {
        self.* = .{ .gpa = gpa, .arena = .init(gpa), .tracker = .init(gpa) };
        self.repaint = .init(self, runPaint);
        self.tracker.setDirtyListener(self, changed);
        self.repaint.schedule();
    }

    pub fn deinit(self: *Canvas) void {
        self.repaint.cancel();
        self.tracker.deinit();
        self.ops.deinit(self.gpa);
        self.saved.deinit(self.gpa);
        self.path.deinit(self.gpa);
        self.arena.deinit();
        self.item.deinit();
        inline for (.{ "fill_style", "stroke_style", "line_width", "global_alpha", "font_size", "font_family", "font_weight", "text_align", "version" }) |f|
            @field(self, f).deinit();
    }

    /// Runs `paint` again before the next frame.
    pub fn requestPaint(self: *Canvas) void {
        self.repaint.schedule();
    }

    fn changed(self: *Canvas) void {
        if (!self.painting) self.repaint.schedule();
    }

    fn runPaint(self: *Canvas) void {
        self.ops.clearRetainingCapacity();
        self.saved.clearRetainingCapacity();
        self.path.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.transform = .{};
        self.current = null;
        self.painting = true;
        self.tracker.evaluate(self, struct {
            fn f(c: *Canvas) void {
                // Drawn again at a new size.
                _ = c.item.width.get();
                _ = c.item.height.get();
                c.paint.call(.{});
            }
        }.f);
        self.painting = false;
        // What the handler set while reading it is no change to paint
        // again for.
        self.tracker.dirty = false;
        self.version.set(self.version.getUntracked() +% 1);
    }

    // ---- Paths ----

    pub fn beginPath(self: *Canvas) void {
        self.path.clearRetainingCapacity();
        self.current = null;
    }

    pub fn closePath(self: *Canvas) void {
        if (self.current == null) return;
        self.append("Z ", .{});
        self.current = self.start;
    }

    pub fn moveTo(self: *Canvas, x: f32, y: f32) void {
        self.point("M", .{ .x = x, .y = y });
        self.start = .{ .x = x, .y = y };
        self.current = self.start;
    }

    pub fn lineTo(self: *Canvas, x: f32, y: f32) void {
        if (self.current == null) return self.moveTo(x, y);
        self.point("L", .{ .x = x, .y = y });
        self.current = .{ .x = x, .y = y };
    }

    pub fn quadraticCurveTo(self: *Canvas, cx: f32, cy: f32, x: f32, y: f32) void {
        if (self.current == null) self.moveTo(cx, cy);
        const c = self.transform.apply(.{ .x = cx, .y = cy });
        const p = self.transform.apply(.{ .x = x, .y = y });
        self.append("Q {d} {d} {d} {d} ", .{ c.x, c.y, p.x, p.y });
        self.current = .{ .x = x, .y = y };
    }

    pub fn bezierCurveTo(self: *Canvas, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) void {
        if (self.current == null) self.moveTo(c1x, c1y);
        self.cubic(.{ .x = c1x, .y = c1y }, .{ .x = c2x, .y = c2y }, .{ .x = x, .y = y });
    }

    /// An arc of the circle at `x`, `y`, from `start` to `end` (degrees,
    /// clockwise from 3 o'clock), clockwise unless `anticlockwise`; joined
    /// to the current point by a line.
    pub fn arc(self: *Canvas, x: f32, y: f32, radius: f32, start: f32, end: f32, anticlockwise: bool) void {
        const r = @abs(radius);
        const a0 = std.math.degreesToRadians(start);
        var sweep = std.math.degreesToRadians(end - start);
        const turn = 2 * std.math.pi;
        // As HTML's: past a whole turn draws the circle; otherwise the
        // sweep goes the asked way round.
        if (!anticlockwise) {
            if (sweep >= turn) sweep = turn else sweep = @mod(sweep, turn);
        } else {
            if (sweep <= -turn) sweep = -turn else sweep = -@mod(-sweep, turn);
        }
        const first: Point = .{ .x = x + r * @cos(a0), .y = y + r * @sin(a0) };
        if (self.current == null) self.moveTo(first.x, first.y) else self.lineTo(first.x, first.y);
        const segments: usize = @intFromFloat(@max(1, @ceil(@abs(sweep) / (std.math.pi / 2.0) - 1e-4)));
        const step = sweep / @as(f32, @floatFromInt(segments));
        const k = 4.0 / 3.0 * @tan(step / 4);
        var a = a0;
        for (0..segments) |_| {
            const b = a + step;
            const p0: Point = .{ .x = x + r * @cos(a), .y = y + r * @sin(a) };
            const p3: Point = .{ .x = x + r * @cos(b), .y = y + r * @sin(b) };
            self.cubic(
                .{ .x = p0.x - k * r * @sin(a), .y = p0.y + k * r * @cos(a) },
                .{ .x = p3.x + k * r * @sin(b), .y = p3.y - k * r * @cos(b) },
                p3,
            );
            a = b;
        }
    }

    pub fn rect(self: *Canvas, x: f32, y: f32, w: f32, h: f32) void {
        self.moveTo(x, y);
        self.lineTo(x + w, y);
        self.lineTo(x + w, y + h);
        self.lineTo(x, y + h);
        self.closePath();
    }

    pub fn roundedRect(self: *Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32) void {
        const r = @min(@abs(radius), @min(@abs(w), @abs(h)) / 2);
        if (r == 0) return self.rect(x, y, w, h);
        self.moveTo(x + r, y);
        self.arc(x + w - r, y + r, r, -90, 0, false);
        self.arc(x + w - r, y + h - r, r, 0, 90, false);
        self.arc(x + r, y + h - r, r, 90, 180, false);
        self.arc(x + r, y + r, r, 180, 270, false);
        self.closePath();
    }

    /// The ellipse inside the box `x`, `y`, `w`, `h` (QML's).
    pub fn ellipse(self: *Canvas, x: f32, y: f32, w: f32, h: f32) void {
        const rx = w / 2;
        const ry = h / 2;
        const cx = x + rx;
        const cy = y + ry;
        const k = 4.0 / 3.0 * (std.math.sqrt2 - 1);
        self.moveTo(cx + rx, cy);
        self.cubic(.{ .x = cx + rx, .y = cy + k * ry }, .{ .x = cx + k * rx, .y = cy + ry }, .{ .x = cx, .y = cy + ry });
        self.cubic(.{ .x = cx - k * rx, .y = cy + ry }, .{ .x = cx - rx, .y = cy + k * ry }, .{ .x = cx - rx, .y = cy });
        self.cubic(.{ .x = cx - rx, .y = cy - k * ry }, .{ .x = cx - k * rx, .y = cy - ry }, .{ .x = cx, .y = cy - ry });
        self.cubic(.{ .x = cx + k * rx, .y = cy - ry }, .{ .x = cx + rx, .y = cy - k * ry }, .{ .x = cx + rx, .y = cy });
        self.closePath();
    }

    fn cubic(self: *Canvas, c1: Point, c2: Point, p: Point) void {
        const m = self.transform;
        const a = m.apply(c1);
        const b = m.apply(c2);
        const e = m.apply(p);
        self.append("C {d} {d} {d} {d} {d} {d} ", .{ a.x, a.y, b.x, b.y, e.x, e.y });
        self.current = p;
    }

    fn point(self: *Canvas, comptime cmd: []const u8, p: Point) void {
        const t = self.transform.apply(p);
        self.append(cmd ++ " {d} {d} ", .{ t.x, t.y });
    }

    fn append(self: *Canvas, comptime fmt: []const u8, args: anytype) void {
        self.path.print(self.gpa, fmt, args) catch {};
    }

    // ---- Drawing ----

    pub fn fill(self: *Canvas) void {
        self.drawPath(self.path.items, self.kept(self.fill_style.getUntracked()), .transparent);
    }

    pub fn stroke(self: *Canvas) void {
        self.drawPath(self.path.items, .transparent, self.kept(self.stroke_style.getUntracked()));
    }

    /// A copy of the brush for as long as what was drawn: a gradient set
    /// from code goes when the style changes.
    fn kept(self: *Canvas, brush: Brush) Brush {
        const a = self.arena.allocator();
        switch (brush) {
            .solid => return brush,
            inline .linear_gradient, .radial_gradient => |g, tag| {
                const copy = a.create(@TypeOf(g.*)) catch return .transparent;
                copy.* = g.*;
                copy.stops = .init(a.dupe(graphics.GradientStop, g.stops.slice()) catch return .transparent);
                return @unionInit(Brush, @tagName(tag), copy);
            },
        }
    }

    /// Shows only what is then drawn inside the current path, until
    /// `restore()`.
    pub fn clip(self: *Canvas) void {
        const commands = self.arena.allocator().dupe(u8, self.path.items) catch return;
        self.ops.append(self.gpa, .{ .clip = commands }) catch {};
    }

    pub fn fillRect(self: *Canvas, x: f32, y: f32, w: f32, h: f32) void {
        self.shapeOnly(x, y, w, h, true);
    }

    pub fn strokeRect(self: *Canvas, x: f32, y: f32, w: f32, h: f32) void {
        self.shapeOnly(x, y, w, h, false);
    }

    /// Erases what was drawn. Each paint starts from an empty canvas, so
    /// this only matters within one: a rectangle covering the whole canvas
    /// erases all drawn so far; a smaller one is not supported.
    pub fn clearRect(self: *Canvas, x: f32, y: f32, w: f32, h: f32) void {
        const m = self.transform;
        if (m.b != 0 or m.c != 0) return;
        const a = m.apply(.{ .x = x, .y = y });
        const b = m.apply(.{ .x = x + w, .y = y + h });
        const size = self.item.size();
        if (@min(a.x, b.x) <= 0 and @min(a.y, b.y) <= 0 and @max(a.x, b.x) >= size.width and @max(a.y, b.y) >= size.height)
            self.ops.clearRetainingCapacity();
    }

    /// A rectangle drawn alone, leaving the current path as it is.
    fn shapeOnly(self: *Canvas, x: f32, y: f32, w: f32, h: f32, filled: bool) void {
        const outer = self.path;
        const outer_current = self.current;
        const outer_start = self.start;
        self.path = .empty;
        defer {
            self.path.deinit(self.gpa);
            self.path = outer;
            self.current = outer_current;
            self.start = outer_start;
        }
        self.rect(x, y, w, h);
        if (filled) self.fill() else self.stroke();
    }

    fn drawPath(self: *Canvas, path: []const u8, fill_brush: Brush, stroke_brush: Brush) void {
        if (path.len == 0) return;
        const m = self.transform;
        // Lines get as thick as the transform makes them.
        const width = self.line_width.getUntracked() * @sqrt(@abs(m.a * m.d - m.b * m.c));
        const commands = self.arena.allocator().dupe(u8, path) catch return;
        self.ops.append(self.gpa, .{ .path = .{
            .commands = commands,
            .fill = fill_brush,
            .stroke = stroke_brush,
            .width = width,
            .alpha = self.global_alpha.getUntracked(),
        } }) catch {};
    }

    /// `text` on its baseline from `x`, `y` (or centered on, or ending at,
    /// `x`, with `text-align`), in `fill-style`.
    pub fn fillText(self: *Canvas, text: []const u8, x: f32, y: f32) void {
        const copy = self.arena.allocator().dupe(u8, text) catch return;
        const family = self.arena.allocator().dupe(u8, self.font_family.getUntracked()) catch return;
        self.ops.append(self.gpa, .{ .text = .{
            .text = copy,
            .at = .{ .x = x, .y = y },
            .transform = self.transform,
            .size = self.font_size.getUntracked(),
            .family = family,
            .weight = self.font_weight.getUntracked(),
            .alignment = self.text_align.getUntracked(),
            .color = self.kept(self.fill_style.getUntracked()),
            .alpha = self.global_alpha.getUntracked(),
        } }) catch {};
    }

    /// The image stretched over the box `x`, `y`, `w`, `h`.
    pub fn drawImage(self: *Canvas, img: image.Image, x: f32, y: f32, w: f32, h: f32) void {
        self.ops.append(self.gpa, .{ .image = .{
            .image = img,
            .box = .{ .x = x, .y = y, .width = w, .height = h },
            .transform = self.transform,
            .alpha = self.global_alpha.getUntracked(),
        } }) catch {};
    }

    // ---- State ----

    /// Keeps the transform, the styles and the clip, for `restore()`.
    pub fn save(self: *Canvas) void {
        self.saved.append(self.gpa, .{
            .transform = self.transform,
            .fill = self.kept(self.fill_style.getUntracked()),
            .stroke = self.kept(self.stroke_style.getUntracked()),
            .line_width = self.line_width.getUntracked(),
            .alpha = self.global_alpha.getUntracked(),
            .font_size = self.font_size.getUntracked(),
            .font_family = self.arena.allocator().dupe(u8, self.font_family.getUntracked()) catch "",
            .font_weight = self.font_weight.getUntracked(),
            .text_align = self.text_align.getUntracked(),
        }) catch return;
        self.ops.append(self.gpa, .save) catch {};
    }

    pub fn restore(self: *Canvas) void {
        const s = self.saved.pop() orelse return;
        self.transform = s.transform;
        self.fill_style.set(s.fill);
        self.stroke_style.set(s.stroke);
        self.line_width.set(s.line_width);
        self.global_alpha.set(s.alpha);
        self.font_size.set(s.font_size);
        self.font_family.set(s.font_family);
        self.font_weight.set(s.font_weight);
        self.text_align.set(s.text_align);
        self.ops.append(self.gpa, .restore) catch {};
    }

    pub fn translate(self: *Canvas, x: f32, y: f32) void {
        self.transform = self.transform.mul(.translation(.{ .x = x, .y = y }));
    }

    /// Clockwise, in degrees.
    pub fn rotate(self: *Canvas, degrees: f32) void {
        self.transform = self.transform.mul(.rotation(degrees));
    }

    pub fn scale(self: *Canvas, sx: f32, sy: f32) void {
        self.transform = self.transform.mul(.scaling(sx, sy));
    }

    pub fn resetTransform(self: *Canvas) void {
        self.transform = .{};
    }

    // ---- Rendering ----

    fn render(i: *Item, r: ItemRenderer) void {
        const self: *Canvas = @alignCast(@fieldParentPtr("item", i));
        _ = self.version.get();
        const size = i.size();
        if (self.ops.items.len == 0 or !(size.width > 0 and size.height > 0)) return;
        r.save();
        defer r.restore();
        if (!r.clip(.{ .width = size.width, .height = size.height })) return;
        // Restores left open by the handler are closed at the end.
        var open: usize = 0;
        defer for (0..open) |_| r.restore();
        for (self.ops.items) |op| switch (op) {
            .save => {
                r.save();
                open += 1;
            },
            .restore => if (open > 0) {
                r.restore();
                open -= 1;
            },
            .clip => |commands| r.clipPath(size, commands),
            .path => |p| {
                faded(r, p.alpha);
                defer if (p.alpha < 1) r.restore();
                const strokes = p.width > 0 and !p.stroke.isTransparent();
                if (p.fill.isTransparent() and !strokes) continue;
                r.drawPath(size, .{
                    .commands = p.commands,
                    .fill = p.fill,
                    .stroke = if (strokes) p.stroke else .transparent,
                    .stroke_width = p.width,
                    .viewbox = .{ .width = size.width, .height = size.height },
                    .stretch = true,
                    .inset_stroke = false,
                });
            },
            .text => |t| self.drawText(r, t),
            .image => |img| {
                r.save();
                defer r.restore();
                if (img.alpha < 1) r.applyOpacity(img.alpha);
                r.transform(img.transform);
                r.translate(.{ .x = img.box.x, .y = img.box.y });
                items.Image.drawPicture(i, img.image, .{ .width = img.box.width, .height = img.box.height }, r);
            },
        };
    }

    /// Saves and fades when `alpha` is below 1 (restored by the caller).
    fn faded(r: ItemRenderer, alpha: f32) void {
        if (alpha >= 1) return;
        r.save();
        r.applyOpacity(@max(alpha, 0));
    }

    fn drawText(self: *Canvas, r: ItemRenderer, t: TextOp) void {
        if (!(t.size > 0) or t.text.len == 0) return;
        const font = items.resolveFont(&self.item, null, t.family, t.weight) orelse return;
        const fallbacks = items.fallbackFonts(&self.item);
        const measured = text_mod.layout.measureMetrics(.initFallbacks(font, fallbacks, t.size), t.text, null);
        const ascent = @as(f32, @floatFromInt(font.ascender)) * font.scale(t.size);
        const left = switch (t.alignment) {
            .left => t.at.x,
            .center => t.at.x - measured.width / 2,
            .right => t.at.x - measured.width,
        };
        r.save();
        defer r.restore();
        if (t.alpha < 1) r.applyOpacity(@max(t.alpha, 0));
        r.transform(t.transform);
        r.translate(.{ .x = left, .y = t.at.y - ascent });
        r.drawText(.{ .width = measured.width + 2, .height = measured.height }, .{
            .text = t.text,
            .font = font,
            .color = t.color,
            .font_size = t.size,
            .fallbacks = fallbacks,
        });
    }
};

const testing = std.testing;

const Painter = struct {
    canvas: *Canvas,
    level: *Property(f32),
    runs: u32 = 0,

    fn paint(p: *Painter) void {
        p.runs += 1;
        const c = p.canvas;
        c.fill_style.set(.color(.rgb(0xff0000)));
        c.fillRect(0, 0, 10, 10);
        c.save();
        c.translate(20, 0);
        c.scale(2, 2);
        c.beginPath();
        c.moveTo(0, 0);
        c.lineTo(p.level.get(), 0);
        c.line_width.set(3);
        c.stroke();
        c.restore();
        c.fillText("hi", 5, 30);
    }
};

test "paint is recorded: paths transformed, styles kept, state restored" {
    var level: Property(f32) = .init(5);
    defer level.deinit();
    var c: Canvas = undefined;
    c.init(testing.allocator);
    defer c.deinit();
    c.item.width.set(100);
    c.item.height.set(50);
    var p: Painter = .{ .canvas = &c, .level = &level };
    c.paint.setHandler(&p, Painter.paint);
    properties.runChangeHandlers();
    try testing.expectEqual(@as(u32, 1), p.runs);

    const ops = c.ops.items;
    try testing.expectEqual(@as(usize, 5), ops.len);
    try testing.expectEqualStrings("M 0 0 L 10 0 L 10 10 L 0 10 Z ", ops[0].path.commands);
    try testing.expect(ops[0].path.fill.eql(.color(.rgb(0xff0000))));
    try testing.expect(ops[1] == .save);
    // Moved and doubled: the line, and its width.
    try testing.expectEqualStrings("M 20 0 L 30 0 ", ops[2].path.commands);
    try testing.expectEqual(@as(f32, 6), ops[2].path.width);
    try testing.expect(ops[3] == .restore);
    try testing.expectEqualStrings("hi", ops[4].text.text);
    try testing.expectEqual(Affine{}, ops[4].text.transform);
    // `restore` put the line width back.
    try testing.expectEqual(@as(f32, 1), c.line_width.get());

    // Painted again when what it read changes, or the size, or on request.
    level.set(8);
    properties.runChangeHandlers();
    try testing.expectEqual(@as(u32, 2), p.runs);
    try testing.expectEqualStrings("M 20 0 L 36 0 ", c.ops.items[2].path.commands);
    c.item.width.set(120);
    properties.runChangeHandlers();
    try testing.expectEqual(@as(u32, 3), p.runs);
    c.requestPaint();
    properties.runChangeHandlers();
    try testing.expectEqual(@as(u32, 4), p.runs);
    // Styles it set itself are no reason to paint again.
    properties.runChangeHandlers();
    try testing.expectEqual(@as(u32, 4), p.runs);
}

test "arcs as curves; shapes; clearing the whole canvas" {
    var c: Canvas = undefined;
    c.init(testing.allocator);
    defer c.deinit();
    c.repaint.cancel();
    c.item.width.set(100);
    c.item.height.set(100);

    // A quarter: one curve, from 3 to 6 o'clock.
    c.arc(50, 50, 10, 0, 90, false);
    var it = std.mem.tokenizeScalar(u8, c.path.items, ' ');
    try testing.expectEqualStrings("M", it.next().?);
    try testing.expectEqualStrings("60", it.next().?);
    try testing.expectEqualStrings("50", it.next().?);
    try testing.expectEqualStrings("C", it.next().?);
    for (0..4) |_| _ = it.next();
    try testing.expectApproxEqAbs(@as(f32, 50), try std.fmt.parseFloat(f32, it.next().?), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 60), try std.fmt.parseFloat(f32, it.next().?), 1e-4);
    try testing.expect(it.next() == null);
    // A whole circle: four; anticlockwise the other way round.
    c.beginPath();
    c.arc(50, 50, 10, 0, 360, false);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, c.path.items, "C"));
    c.beginPath();
    c.arc(50, 50, 10, 0, 90, true);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, c.path.items, "C"));
    // An ellipse and a rounded rectangle close their paths.
    c.beginPath();
    c.ellipse(0, 0, 20, 10);
    try testing.expect(std.mem.endsWith(u8, c.path.items, "Z "));
    c.beginPath();
    c.roundedRect(0, 0, 20, 10, 4);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, c.path.items, "C"));

    // fill-rect leaves the current path alone.
    const before = c.path.items.len;
    c.fillRect(0, 0, 5, 5);
    try testing.expectEqual(before, c.path.items.len);
    try testing.expectEqual(@as(usize, 1), c.ops.items.len);
    // A part is not cleared; all of it is.
    c.clearRect(0, 0, 50, 50);
    try testing.expectEqual(@as(usize, 1), c.ops.items.len);
    c.clearRect(-1, -1, 200, 200);
    try testing.expectEqual(@as(usize, 0), c.ops.items.len);
}

test "gradients are kept while drawn" {
    var c: Canvas = undefined;
    c.init(testing.allocator);
    defer c.deinit();
    c.repaint.cancel();
    var stops = [_]graphics.GradientStop{ .{ .color = .rgb(0xff0000), .position = 0 }, .{ .color = .rgb(0x0000ff), .position = 1 } };
    var g: graphics.LinearGradient = .{ .angle = 90, .stops = .init(&stops) };
    c.fill_style.set(.{ .linear_gradient = &g });
    c.fillRect(0, 0, 5, 5);
    stops[0].color = .rgb(0x00ff00);
    const kept = c.ops.items[0].path.fill.linear_gradient;
    try testing.expect(kept != &g);
    try testing.expectEqual(graphics.Color.rgb(0xff0000), kept.stops.slice()[0].color);
}
