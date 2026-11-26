// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Charts (the `LineChart`, `BarChart` and `PieChart` elements): the
//! values of a model drawn as a line, bars or the slices of a pie, within
//! the element. The value under the pointer is `hovered_index`, and a
//! click on one calls `clicked`. Line and bar charts show the values from
//! `minimum` to `maximum`, or, if those are not set, a range rounded so
//! that `grid_lines` lines fall on round values (`shown_minimum` and
//! `shown_maximum` tell which, to label them). Labels, axes and legends
//! are elements around them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const properties = @import("properties.zig");
const Property = properties.Property;
const Callback = @import("callbacks.zig").Callback;
const model = @import("model.zig");
const Model = model.Model;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const ItemVTable = item_mod.ItemVTable;
const rendering = @import("rendering.zig");
const ItemRenderer = rendering.ItemRenderer;
const input = @import("input.zig");
const graphics = @import("graphics.zig");
const Color = graphics.Color;
const Brush = graphics.Brush;
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Rect = geometry.Rect;
const Window = @import("window.zig").Window;

/// The colors of bars and slices without colors of their own (Tableau 10).
pub const default_colors = [_]Color{
    .{ .r = 0x4e, .g = 0x79, .b = 0xa7, .a = 255 },
    .{ .r = 0xf2, .g = 0x8e, .b = 0x2b, .a = 255 },
    .{ .r = 0xe1, .g = 0x57, .b = 0x59, .a = 255 },
    .{ .r = 0x76, .g = 0xb7, .b = 0xb2, .a = 255 },
    .{ .r = 0x59, .g = 0xa1, .b = 0x4f, .a = 255 },
    .{ .r = 0xed, .g = 0xc9, .b = 0x48, .a = 255 },
    .{ .r = 0xb0, .g = 0x7a, .b = 0xa1, .a = 255 },
    .{ .r = 0xff, .g = 0x9d, .b = 0xa7, .a = 255 },
    .{ .r = 0x9c, .g = 0x75, .b = 0x5f, .a = 255 },
    .{ .r = 0xba, .g = 0xb0, .b = 0xac, .a = 255 },
};

const grid_default: Brush = .{ .solid = .{ .r = 0x80, .g = 0x80, .b = 0x80, .a = 0x40 } };

/// The color of value `i`: from `colors` (repeated), else the defaults.
fn colorAt(colors: Model(Color), i: usize) Color {
    const n = colors.rowCount();
    if (n > 0) return colors.rowData(i % n) orelse default_colors[0];
    return default_colors[i % default_colors.len];
}

fn parentOf(comptime T: type, i: *Item) *T {
    return @alignCast(@fieldParentPtr("item", i));
}

fn inside(i: *Item, p: Point) bool {
    return (Rect{ .width = i.width.get(), .height = i.height.get() }).contains(p);
}

fn valuesOf(values: Model(f32), buf: *std.ArrayList(f32), gpa: Allocator) []const f32 {
    buf.clearRetainingCapacity();
    const n = values.rowCount();
    buf.ensureTotalCapacity(gpa, n) catch return &.{};
    for (0..n) |i| {
        const v = values.rowData(i) orelse 0;
        buf.appendAssumeCapacity(if (std.math.isFinite(v)) v else 0);
    }
    return buf.items;
}

// ---- Ranges ----

/// The values shown from `lo` (at the bottom) to `hi` (at the top).
pub const Range = struct {
    lo: f32,
    hi: f32,

    /// Where `v` is, from `top` down `height`.
    fn y(r: Range, v: f32, top: f32, height: f32) f32 {
        return top + height - (v - r.lo) / (r.hi - r.lo) * height;
    }
};

/// `minimum` to `maximum` if set (`maximum` above `minimum`), else from
/// the values (and 0), rounded so that `lines` grid lines (5 if none)
/// split it into equal round steps.
pub fn resolveRange(values: []const f32, minimum: f32, maximum: f32, lines: i32) Range {
    if (maximum > minimum) return .{ .lo = minimum, .hi = maximum };
    var lo: f32 = 0;
    var hi: f32 = 0;
    for (values) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    if (hi == lo) hi = lo + 1;
    const n: f32 = @floatFromInt(if (lines > 0) lines else 5);
    var step = niceStep((hi - lo) / n);
    var start = @floor(lo / step) * step;
    // A bigger step until `n` of them reach the top.
    for (0..16) |_| {
        if (start + step * n >= hi - step * 1e-4) break;
        step = niceStep(step * 1.001);
        start = @floor(lo / step) * step;
    }
    return .{ .lo = start, .hi = start + step * n };
}

/// The smallest of 1, 2, 2.5 and 5 times a power of ten that is at least
/// `raw`.
fn niceStep(raw: f32) f32 {
    if (!(raw > 0)) return 1;
    const mag = std.math.pow(f32, 10, @floor(std.math.log10(raw)));
    const f = raw / mag;
    const nice: f32 = if (f <= 1) 1 else if (f <= 2) 2 else if (f <= 2.5) 2.5 else if (f <= 5) 5 else 10;
    return nice * mag;
}

// ---- Path data ----

/// Path data an element draws, kept while display lists may use it (the
/// two last built), and built again only when what it shows changes.
const Paths = struct {
    bufs: [2]std.ArrayList(u8) = .{ .empty, .empty },
    /// Where each path ends in its buffer.
    ends: [2]std.ArrayList(u32) = .{ .empty, .empty },
    current: u1 = 0,
    key: u64 = 0,

    fn deinit(self: *Paths, gpa: Allocator) void {
        for (&self.bufs) |*b| b.deinit(gpa);
        for (&self.ends) |*e| e.deinit(gpa);
    }

    /// True if paths must be built for `key` (then `add` them).
    fn begin(self: *Paths, key: u64) bool {
        if (self.key == key) return false;
        self.key = key;
        self.current +%= 1;
        self.bufs[self.current].clearRetainingCapacity();
        self.ends[self.current].clearRetainingCapacity();
        return true;
    }

    fn print(self: *Paths, gpa: Allocator, comptime fmt: []const u8, args: anytype) void {
        self.bufs[self.current].print(gpa, fmt, args) catch {};
    }

    /// Ends the path written so far.
    fn end(self: *Paths, gpa: Allocator) void {
        self.ends[self.current].append(gpa, @intCast(self.bufs[self.current].items.len)) catch {};
    }

    /// Path `k`; empty if it was not built.
    fn get(self: *const Paths, k: usize) []const u8 {
        const ends = self.ends[self.current].items;
        if (k >= ends.len) return "";
        const start = if (k == 0) 0 else ends[k - 1];
        return self.bufs[self.current].items[start..ends[k]];
    }
};

/// Draws path data in the item's own coordinates.
fn drawPath(r: ItemRenderer, size: geometry.Size, commands: []const u8, fill: Brush, stroke: Brush, stroke_width: f32) void {
    if (commands.len == 0) return;
    r.drawPath(size, .{
        .commands = commands,
        .fill = fill,
        .stroke = stroke,
        .stroke_width = stroke_width,
        .viewbox = .{ .width = size.width, .height = size.height },
        .stretch = true,
        .inset_stroke = false,
    });
}

fn hashOf(h: *std.hash.Wyhash, v: anytype) void {
    h.update(std.mem.asBytes(&v));
}

/// Horizontal grid lines splitting `range` into `lines` steps.
fn gridPath(p: *Paths, gpa: Allocator, lines: i32, width: f32, top: f32, height: f32) void {
    if (lines <= 0) return;
    const n: usize = @intCast(lines);
    for (0..n + 1) |k| {
        const y = top + height * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        // On a pixel's middle, sharp at 1px.
        const ya = @floor(y) + 0.5;
        p.print(gpa, "M0 {d:.2}H{d:.2}", .{ @min(ya, top + height), width });
    }
}

/// The input every chart handles: hovering by index (`hover_at`, the
/// value hovered), clicks on one (`press_at`, the value a press there
/// takes; -1 lets the press through). Hovering lets the pointer through,
/// so that charts stacked over each other are all hovered.
fn pointer(event: input.PointerEvent, hover_at: i32, press_at: i32, hovered: *Property(i32), pressed: *i32, clicked: *Callback(fn (i32) void)) input.InputEventResult {
    switch (event) {
        .exit => {
            hovered.set(-1);
            return .ignored;
        },
        .moved => {
            hovered.set(hover_at);
            return .ignored;
        },
        .pressed => |p| {
            hovered.set(hover_at);
            if (p.button != .left or press_at < 0) return .ignored;
            pressed.* = press_at;
            return .grab;
        },
        .released => |p| {
            if (p.button != .left or pressed.* < 0) return .ignored;
            const was = pressed.*;
            pressed.* = -1;
            if (was == press_at) clicked.call(.{was});
            return .accepted;
        },
        .wheel => return .ignored,
    }
}

// ---- LineChart ----

/// The values as a line from left to right (an area under it with
/// `fill`, dots with `point_size`). Initialize in place with `init`.
pub const LineChart = struct {
    item: Item = .init(&vtable),
    values: Property(Model(f32)) = .init(model.emptyModel(f32)),
    minimum: Property(f32) = .init(0),
    maximum: Property(f32) = .init(0),
    color: Property(Brush) = .init(.{ .solid = default_colors[0] }),
    line_width: Property(f32) = .init(2),
    fill: Property(Brush) = .init(.transparent),
    point_size: Property(f32) = .init(0),
    grid_lines: Property(i32) = .init(0),
    grid_color: Property(Brush) = .init(grid_default),
    shown_minimum: Property(f32) = .init(0),
    shown_maximum: Property(f32) = .init(1),
    hovered_index: Property(i32) = .init(-1),
    clicked: Callback(fn (i32) void) = .{},

    gpa: Allocator = undefined,
    scratch: std.ArrayList(f32) = .empty,
    paths: Paths = .{},
    pressed: i32 = -1,

    pub fn init(self: *LineChart, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.shown_minimum.setBinding(gpa, self, shownMinimum) catch {};
        self.shown_maximum.setBinding(gpa, self, shownMaximum) catch {};
    }

    pub fn deinit(self: *LineChart) void {
        self.item.deinit();
        inline for (.{ "values", "minimum", "maximum", "color", "line_width", "fill", "point_size", "grid_lines", "grid_color", "shown_minimum", "shown_maximum", "hovered_index" }) |f| @field(self, f).deinit();
        self.scratch.deinit(self.gpa);
        self.paths.deinit(self.gpa);
    }

    fn range(self: *LineChart) Range {
        return resolveRange(valuesOf(self.values.get(), &self.scratch, self.gpa), self.minimum.get(), self.maximum.get(), self.grid_lines.get());
    }

    fn shownMinimum(self: *LineChart) f32 {
        return self.range().lo;
    }

    fn shownMaximum(self: *LineChart) f32 {
        return self.range().hi;
    }

    /// The area points are in: within the item, by half a line or dot.
    fn plot(self: *LineChart) Rect {
        const inset = @max(self.line_width.get(), self.point_size.get()) / 2;
        return .{ .x = inset, .y = inset, .width = @max(0, self.item.width.get() - 2 * inset), .height = @max(0, self.item.height.get() - 2 * inset) };
    }

    fn xAt(area: Rect, i: usize, n: usize) f32 {
        if (n < 2) return area.x + area.width / 2;
        return area.x + area.width * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1));
    }

    const vtable: ItemVTable = .{ .name = "LineChart", .render = render, .inputEvent = inputEvent };

    fn render(i: *Item, r: ItemRenderer) void {
        const self = parentOf(LineChart, i);
        const values = valuesOf(self.values.get(), &self.scratch, self.gpa);
        const rg = resolveRange(values, self.minimum.get(), self.maximum.get(), self.grid_lines.get());
        const size = i.size();
        const area = self.plot();
        const lines = self.grid_lines.get();
        const dot = self.point_size.get();
        var h: std.hash.Wyhash = .init(1);
        h.update(std.mem.sliceAsBytes(values));
        hashOf(&h, .{ rg.lo, rg.hi, size.width, size.height, area.x, lines, dot });
        if (self.paths.begin(h.final())) {
            const p = &self.paths;
            const gpa = self.gpa;
            gridPath(p, gpa, lines, size.width, area.y, area.height);
            p.end(gpa);
            if (values.len > 0) {
                // The area: down to 0 (or the nearest end of the range).
                const base = rg.y(std.math.clamp(0, rg.lo, rg.hi), area.y, area.height);
                p.print(gpa, "M{d:.2} {d:.2}", .{ xAt(area, 0, values.len), base });
                for (values, 0..) |v, k| p.print(gpa, "L{d:.2} {d:.2}", .{ xAt(area, k, values.len), rg.y(v, area.y, area.height) });
                p.print(gpa, "L{d:.2} {d:.2}Z", .{ xAt(area, values.len - 1, values.len), base });
            }
            p.end(gpa);
            for (values, 0..) |v, k| p.print(gpa, "{s}{d:.2} {d:.2}", .{ if (k == 0) "M" else "L", xAt(area, k, values.len), rg.y(v, area.y, area.height) });
            p.end(gpa);
            if (dot > 0) for (values, 0..) |v, k| {
                const rad = dot / 2;
                const x = xAt(area, k, values.len);
                const y = rg.y(v, area.y, area.height);
                p.print(gpa, "M{d:.2} {d:.2}a{d:.2} {d:.2} 0 1 0 {d:.2} 0a{d:.2} {d:.2} 0 1 0 {d:.2} 0Z", .{ x - rad, y, rad, rad, 2 * rad, rad, rad, -2 * rad });
            };
            p.end(gpa);
        }
        drawPath(r, size, self.paths.get(0), .transparent, self.grid_color.get(), 1);
        drawPath(r, size, self.paths.get(1), self.fill.get(), .transparent, 0);
        // A single value has no line: its dot shows it.
        if (values.len > 1) drawPath(r, size, self.paths.get(2), .transparent, self.color.get(), self.line_width.get());
        drawPath(r, size, self.paths.get(3), self.color.get(), .transparent, 0);
    }

    /// The value nearest to `p` from left to right; -1 outside.
    fn indexAt(self: *LineChart, p: Point) i32 {
        const n = self.values.get().rowCount();
        if (n == 0 or !inside(&self.item, p)) return -1;
        if (n == 1) return 0;
        const area = self.plot();
        const t = std.math.clamp((p.x - area.x) / @max(area.width, 1e-3), 0, 1);
        return @intFromFloat(@round(t * @as(f32, @floatFromInt(n - 1))));
    }

    /// The point within reach of `p` (a finger's width), for presses.
    fn pointAt(self: *LineChart, p: Point) i32 {
        const k = self.indexAt(p);
        if (k < 0) return -1;
        const values = valuesOf(self.values.get(), &self.scratch, self.gpa);
        const area = self.plot();
        const rg = resolveRange(values, self.minimum.get(), self.maximum.get(), self.grid_lines.get());
        const at: usize = @intCast(k);
        const dx = p.x - xAt(area, at, values.len);
        const dy = p.y - rg.y(values[at], area.y, area.height);
        const reach = @max(12, self.point_size.get());
        return if (dx * dx + dy * dy <= reach * reach) k else -1;
    }

    fn inputEvent(i: *Item, event: input.PointerEvent, _: *Window) input.InputEventResult {
        const self = parentOf(LineChart, i);
        const p = event.position() orelse return pointer(event, -1, -1, &self.hovered_index, &self.pressed, &self.clicked);
        return pointer(event, self.indexAt(p), self.pointAt(p), &self.hovered_index, &self.pressed, &self.clicked);
    }
};

// ---- BarChart ----

/// The values as bars side by side, up from 0 (down if negative).
/// Initialize in place with `init`.
pub const BarChart = struct {
    item: Item = .init(&vtable),
    values: Property(Model(f32)) = .init(model.emptyModel(f32)),
    colors: Property(Model(Color)) = .init(model.emptyModel(Color)),
    minimum: Property(f32) = .init(0),
    maximum: Property(f32) = .init(0),
    /// The part of each bar's place left empty, between bars.
    spacing: Property(f32) = .init(0.25),
    border_radius: Property(f32) = .init(0),
    grid_lines: Property(i32) = .init(0),
    grid_color: Property(Brush) = .init(grid_default),
    shown_minimum: Property(f32) = .init(0),
    shown_maximum: Property(f32) = .init(1),
    hovered_index: Property(i32) = .init(-1),
    clicked: Callback(fn (i32) void) = .{},

    gpa: Allocator = undefined,
    scratch: std.ArrayList(f32) = .empty,
    paths: Paths = .{},
    pressed: i32 = -1,

    pub fn init(self: *BarChart, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.shown_minimum.setBinding(gpa, self, shownMinimum) catch {};
        self.shown_maximum.setBinding(gpa, self, shownMaximum) catch {};
    }

    pub fn deinit(self: *BarChart) void {
        self.item.deinit();
        inline for (.{ "values", "colors", "minimum", "maximum", "spacing", "border_radius", "grid_lines", "grid_color", "shown_minimum", "shown_maximum", "hovered_index" }) |f| @field(self, f).deinit();
        self.scratch.deinit(self.gpa);
        self.paths.deinit(self.gpa);
    }

    fn range(self: *BarChart) Range {
        return resolveRange(valuesOf(self.values.get(), &self.scratch, self.gpa), self.minimum.get(), self.maximum.get(), self.grid_lines.get());
    }

    fn shownMinimum(self: *BarChart) f32 {
        return self.range().lo;
    }

    fn shownMaximum(self: *BarChart) f32 {
        return self.range().hi;
    }

    const vtable: ItemVTable = .{ .name = "BarChart", .render = render, .inputEvent = inputEvent };

    fn render(i: *Item, r: ItemRenderer) void {
        const self = parentOf(BarChart, i);
        const values = valuesOf(self.values.get(), &self.scratch, self.gpa);
        const rg = resolveRange(values, self.minimum.get(), self.maximum.get(), self.grid_lines.get());
        const size = i.size();
        const lines = self.grid_lines.get();
        var h: std.hash.Wyhash = .init(2);
        hashOf(&h, .{ size.width, size.height, lines });
        if (self.paths.begin(h.final())) {
            gridPath(&self.paths, self.gpa, lines, size.width, 0, size.height);
            self.paths.end(self.gpa);
        }
        drawPath(r, size, self.paths.get(0), .transparent, self.grid_color.get(), 1);
        if (values.len == 0) return;
        const colors = self.colors.get();
        const slot = size.width / @as(f32, @floatFromInt(values.len));
        const gap = slot * std.math.clamp(self.spacing.get(), 0, 0.95);
        const zero = rg.y(std.math.clamp(0, rg.lo, rg.hi), 0, size.height);
        const radius = self.border_radius.get();
        for (values, 0..) |v, k| {
            const y = std.math.clamp(rg.y(v, 0, size.height), 0, size.height);
            const top = @min(y, zero);
            const height = @abs(zero - y);
            if (height <= 0) continue;
            const width = slot - gap;
            r.save();
            r.translate(.{ .x = slot * @as(f32, @floatFromInt(k)) + gap / 2, .y = top });
            r.drawRectangle(.{ .width = width, .height = height }, .{
                .background = .{ .solid = colorAt(colors, k) },
                .border_radius = @min(radius, width / 2, height / 2),
            });
            r.restore();
        }
    }

    /// The bar whose place `p` is in; -1 outside.
    fn indexAt(self: *BarChart, p: Point) i32 {
        const n = self.values.get().rowCount();
        if (n == 0 or !inside(&self.item, p)) return -1;
        const slot = self.item.width.get() / @as(f32, @floatFromInt(n));
        const k: usize = @intFromFloat(@max(0, @floor(p.x / slot)));
        return @intCast(@min(k, n - 1));
    }

    fn inputEvent(i: *Item, event: input.PointerEvent, _: *Window) input.InputEventResult {
        const self = parentOf(BarChart, i);
        const at = if (event.position()) |p| self.indexAt(p) else -1;
        return pointer(event, at, at, &self.hovered_index, &self.pressed, &self.clicked);
    }
};

// ---- PieChart ----

/// The values as slices of a circle, clockwise from the top, each its part
/// of their sum (negative values count as none); a ring with `hole` (the
/// part of the radius left empty). Initialize in place with `init`.
pub const PieChart = struct {
    item: Item = .init(&vtable),
    values: Property(Model(f32)) = .init(model.emptyModel(f32)),
    colors: Property(Model(Color)) = .init(model.emptyModel(Color)),
    hole: Property(f32) = .init(0),
    hovered_index: Property(i32) = .init(-1),
    clicked: Callback(fn (i32) void) = .{},

    gpa: Allocator = undefined,
    scratch: std.ArrayList(f32) = .empty,
    paths: Paths = .{},
    pressed: i32 = -1,

    pub fn init(self: *PieChart, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
    }

    pub fn deinit(self: *PieChart) void {
        self.item.deinit();
        inline for (.{ "values", "colors", "hole", "hovered_index" }) |f| @field(self, f).deinit();
        self.scratch.deinit(self.gpa);
        self.paths.deinit(self.gpa);
    }

    const Geometry = struct {
        center: Point,
        outer: f32,
        inner: f32,
        total: f32,
    };

    fn geometryOf(self: *PieChart, values: []const f32) Geometry {
        const w = self.item.width.get();
        const h = self.item.height.get();
        const outer = @min(w, h) / 2;
        var total: f32 = 0;
        for (values) |v| total += @max(v, 0);
        return .{ .center = .{ .x = w / 2, .y = h / 2 }, .outer = outer, .inner = outer * std.math.clamp(self.hole.get(), 0, 0.95), .total = total };
    }

    fn at(g: Geometry, radius: f32, angle: f32) Point {
        // Clockwise from the top.
        return .{ .x = g.center.x + radius * @sin(angle), .y = g.center.y - radius * @cos(angle) };
    }

    const vtable: ItemVTable = .{ .name = "PieChart", .render = render, .inputEvent = inputEvent };

    fn render(i: *Item, r: ItemRenderer) void {
        const self = parentOf(PieChart, i);
        const values = valuesOf(self.values.get(), &self.scratch, self.gpa);
        const g = self.geometryOf(values);
        if (g.total <= 0 or g.outer <= 0) return;
        const size = i.size();
        var h: std.hash.Wyhash = .init(3);
        h.update(std.mem.sliceAsBytes(values));
        hashOf(&h, .{ size.width, size.height, g.inner });
        if (self.paths.begin(h.final())) {
            const p = &self.paths;
            const gpa = self.gpa;
            var a0: f32 = 0;
            for (values) |v| {
                const sweep = @max(v, 0) / g.total * std.math.tau;
                defer a0 += sweep;
                if (sweep <= 0) {
                    p.end(gpa);
                    continue;
                }
                // A whole circle: two halves (an arc cannot end where it
                // starts).
                const halves: usize = if (sweep > std.math.pi * 1.999) 2 else 1;
                const step = sweep / @as(f32, @floatFromInt(halves));
                const large: u8 = if (step > std.math.pi) 1 else 0;
                const s = at(g, g.outer, a0);
                p.print(gpa, "M{d:.3} {d:.3}", .{ s.x, s.y });
                for (0..halves) |k| {
                    const e = at(g, g.outer, a0 + step * @as(f32, @floatFromInt(k + 1)));
                    p.print(gpa, "A{d:.3} {d:.3} 0 {d} 1 {d:.3} {d:.3}", .{ g.outer, g.outer, large, e.x, e.y });
                }
                if (g.inner > 0) {
                    const ie = at(g, g.inner, a0 + sweep);
                    p.print(gpa, "L{d:.3} {d:.3}", .{ ie.x, ie.y });
                    var k = halves;
                    while (k > 0) {
                        k -= 1;
                        const e = at(g, g.inner, a0 + step * @as(f32, @floatFromInt(k)));
                        p.print(gpa, "A{d:.3} {d:.3} 0 {d} 0 {d:.3} {d:.3}", .{ g.inner, g.inner, large, e.x, e.y });
                    }
                } else if (halves == 1) p.print(gpa, "L{d:.3} {d:.3}", .{ g.center.x, g.center.y });
                p.print(gpa, "Z", .{});
                p.end(gpa);
            }
        }
        const colors = self.colors.get();
        for (0..values.len) |k| drawPath(r, size, self.paths.get(k), .{ .solid = colorAt(colors, k) }, .transparent, 0);
    }

    /// The slice under `p`; -1 outside them.
    fn indexAt(self: *PieChart, p: Point) i32 {
        const values = valuesOf(self.values.get(), &self.scratch, self.gpa);
        const g = self.geometryOf(values);
        if (g.total <= 0) return -1;
        const dx = p.x - g.center.x;
        const dy = p.y - g.center.y;
        const d = @sqrt(dx * dx + dy * dy);
        if (d > g.outer or d < g.inner) return -1;
        var angle = std.math.atan2(dx, -dy);
        if (angle < 0) angle += std.math.tau;
        var a0: f32 = 0;
        for (values, 0..) |v, k| {
            a0 += @max(v, 0) / g.total * std.math.tau;
            if (angle < a0 and v > 0) return @intCast(k);
        }
        return @intCast(values.len - 1);
    }

    fn inputEvent(i: *Item, event: input.PointerEvent, _: *Window) input.InputEventResult {
        const self = parentOf(PieChart, i);
        const idx = if (event.position()) |p| self.indexAt(p) else -1;
        return pointer(event, idx, idx, &self.hovered_index, &self.pressed, &self.clicked);
    }
};

// ---- Tests ----

const testing = std.testing;

test "ranges: as set, or from the values rounded to the grid's steps" {
    try testing.expectEqual(Range{ .lo = -1, .hi = 3 }, resolveRange(&.{ 5, 6 }, -1, 3, 4));
    try testing.expectEqual(Range{ .lo = 0, .hi = 40 }, resolveRange(&.{ 12, 37, 3 }, 0, 0, 4));
    try testing.expectEqual(Range{ .lo = 0, .hi = 1 }, resolveRange(&.{}, 0, 0, 0));
    // Below 0 too: equal round steps through 0.
    const r = resolveRange(&.{ -3, 37 }, 0, 0, 4);
    const step = (r.hi - r.lo) / 4;
    try testing.expect(r.lo <= -3 and r.hi >= 37);
    try testing.expectEqual(@round(step), step);
    try testing.expectEqual(@round(r.lo / step), r.lo / step);
    try testing.expectEqual(@as(f32, 0.25), niceStep(0.23));
    try testing.expectEqual(@as(f32, 500), niceStep(321));
}

test "a pie's slices, under the pointer" {
    var sm: model.SliceModel(f32) = .init(&.{ 1, 1, 2 });
    defer sm.deinit();
    var pie: PieChart = undefined;
    pie.init(testing.allocator);
    defer pie.deinit();
    pie.item.width.set(100);
    pie.item.height.set(100);
    pie.values.set(sm.model());
    // Clockwise from the top: a quarter, a quarter, a half.
    try testing.expectEqual(@as(i32, 0), pie.indexAt(.{ .x = 80, .y = 30 }));
    try testing.expectEqual(@as(i32, 1), pie.indexAt(.{ .x = 80, .y = 70 }));
    try testing.expectEqual(@as(i32, 2), pie.indexAt(.{ .x = 20, .y = 50 }));
    try testing.expectEqual(@as(i32, -1), pie.indexAt(.{ .x = 2, .y = 2 }));
    pie.hole.set(0.5);
    try testing.expectEqual(@as(i32, -1), pie.indexAt(.{ .x = 52, .y = 52 }));
}

test "bars and line points under the pointer; the range shown" {
    var sm: model.SliceModel(f32) = .init(&.{ 3, 9, 4, 7 });
    defer sm.deinit();
    var bars: BarChart = undefined;
    bars.init(testing.allocator);
    defer bars.deinit();
    bars.item.width.set(200);
    bars.item.height.set(100);
    bars.values.set(sm.model());
    try testing.expectEqual(@as(i32, 1), bars.indexAt(.{ .x = 60, .y = 10 }));
    try testing.expectEqual(@as(i32, 3), bars.indexAt(.{ .x = 199, .y = 10 }));
    bars.grid_lines.set(2);
    try testing.expectEqual(@as(f32, 0), bars.shown_minimum.get());
    try testing.expectEqual(@as(f32, 10), bars.shown_maximum.get());

    var line: LineChart = undefined;
    line.init(testing.allocator);
    defer line.deinit();
    line.item.width.set(302);
    line.item.height.set(100);
    line.values.set(sm.model());
    // Points at 1, 101, 201 and 301 (inset by half the line).
    try testing.expectEqual(@as(i32, 1), line.indexAt(.{ .x = 120, .y = 50 }));
    try testing.expectEqual(@as(i32, 2), line.indexAt(.{ .x = 160, .y = 50 }));
    // Presses take a point only within reach: 9 is at y = 1 + 98 * 0.1.
    try testing.expectEqual(@as(i32, 1), line.pointAt(.{ .x = 103, .y = 14 }));
    try testing.expectEqual(@as(i32, -1), line.pointAt(.{ .x = 101, .y = 60 }));
}
