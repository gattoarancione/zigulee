// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! SVG images as vector drawings: the shapes of an SVG file, each as path
//! data in the drawing's coordinates (its `viewBox`), with a fill and a
//! stroke, drawn by `Path`'s renderer at any size.
//!
//! Read: `path`, `rect` (with `rx`/`ry`), `circle`, `ellipse`, `line`,
//! `polyline`, `polygon`, in `g` groups; `transform` (`matrix`,
//! `translate`, `scale`, `rotate`, `skewX`, `skewY`); `fill`, `stroke`,
//! `stroke-width`, `opacity`, `fill-opacity`, `stroke-opacity` as
//! attributes or in `style`, inherited; colors as `#rgb`, `#rrggbb`,
//! `rgb()`, basic names, `currentColor` (black, or an Image's `colorize`);
//! linear and radial gradients (`x1`..`y2`, `cx`, `cy`, `r`,
//! `gradientUnits`, `gradientTransform`, `href`, stops with
//! `stop-color` and `stop-opacity`), radial ones from their center (no
//! focal point), padded, as ellipses square to the drawing; `use` (of any
//! element or a `symbol`, at its `x`, `y`); `clip-path` (a `clipPath` of
//! shapes, in user space), `mask` (a `mask`'s shapes, by their luminance)
//! and `filter` (its `feGaussianBlur`), each shape on its own (a group's
//! shapes clipped, masked and blurred one by one); `text` (with its
//! `tspan`s' text, at its `x`, `y`; `font-size`, `font-weight`,
//! `text-anchor`; in the font of the element showing it, not rotated).
//! Not read: other filters, patterns, markers, CSS stylesheets, text on a
//! path or positioned by character.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Rect = geometry.Rect;
const Affine = geometry.Affine;
const graphics = @import("graphics.zig");
const Color = graphics.Color;
const Brush = graphics.Brush;
const GradientStop = graphics.GradientStop;
const path = @import("path.zig");

pub const Shape = struct {
    /// SVG path data, absolute, in the drawing's coordinates (empty for
    /// text).
    commands: []const u8,
    fill: ?Paint = null,
    stroke: ?Paint = null,
    stroke_width: f32 = 1,
    /// Shown only inside this path data (the drawing's coordinates); empty:
    /// everywhere.
    clip: []const u8 = "",
    /// Shown as much as these shapes are bright (an SVG `mask`).
    mask: []const Shape = &.{},
    /// Blurred: the standard deviation, in the drawing's units.
    blur: f32 = 0,
    /// Text, in `fill`, instead of a path.
    text: ?Text = null,
};

pub const Text = struct {
    content: []const u8,
    /// Where its baseline starts (or is centered, or ends: `anchor`), in
    /// the drawing's coordinates.
    x: f32,
    y: f32,
    size: f32,
    anchor: Anchor = .start,
    bold: bool = false,

    pub const Anchor = enum { start, middle, end };
};

pub const Paint = union(enum) {
    color: Color,
    /// `currentColor`.
    current,
    /// A gradient, its geometry in fractions of the drawing's viewbox.
    gradient: Brush,
};

pub const Drawing = struct {
    /// The area drawn (the `viewBox`, else 0, 0, width, height).
    viewbox: Rect,
    /// Its size (`width`, `height`; else the viewBox's).
    width: f32,
    height: f32,
    shapes: []const Shape,
};

pub const Error = error{InvalidSvg} || Allocator.Error;

/// Whether `bytes` look like an SVG file.
pub fn isSvg(bytes: []const u8) bool {
    const head = bytes[0..@min(bytes.len, 1024)];
    return std.mem.indexOf(u8, head, "<svg") != null;
}

// ---- XML ----

const Attr = struct { name: []const u8, value: []const u8 };

const Tag = struct {
    name: []const u8,
    attrs: []const Attr,
    /// `<x/>`
    self_closing: bool,
    /// `</x>`
    closing: bool,

    fn get(t: Tag, name: []const u8) ?[]const u8 {
        for (t.attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }
};

const Xml = struct {
    src: []const u8,
    i: usize = 0,
    /// Where the last tag read starts (its `<`).
    start: usize = 0,
    attrs: std.ArrayList(Attr) = .empty,

    /// The next tag (text, comments and declarations skipped).
    fn next(x: *Xml, a: Allocator) Error!?Tag {
        while (true) {
            const lt = std.mem.indexOfScalarPos(u8, x.src, x.i, '<') orelse return null;
            x.start = lt;
            x.i = lt + 1;
            if (std.mem.startsWith(u8, x.src[x.i..], "!--")) {
                x.i = (std.mem.indexOfPos(u8, x.src, x.i, "-->") orelse return null) + 3;
                continue;
            }
            if (std.mem.startsWith(u8, x.src[x.i..], "![CDATA[")) {
                x.i = (std.mem.indexOfPos(u8, x.src, x.i, "]]>") orelse return null) + 3;
                continue;
            }
            if (x.i < x.src.len and (x.src[x.i] == '?' or x.src[x.i] == '!')) {
                x.i = (std.mem.indexOfScalarPos(u8, x.src, x.i, '>') orelse return null) + 1;
                continue;
            }
            return try x.tag(a);
        }
    }

    fn tag(x: *Xml, a: Allocator) Error!Tag {
        const closing = x.i < x.src.len and x.src[x.i] == '/';
        if (closing) x.i += 1;
        const name = x.word();
        x.attrs = .empty;
        while (true) {
            x.skipSpace();
            if (x.i >= x.src.len) return error.InvalidSvg;
            const c = x.src[x.i];
            if (c == '>') {
                x.i += 1;
                return .{ .name = name, .attrs = x.attrs.items, .self_closing = false, .closing = closing };
            }
            if (c == '/') {
                x.i += 1;
                x.skipSpace();
                if (x.i < x.src.len and x.src[x.i] == '>') x.i += 1;
                return .{ .name = name, .attrs = x.attrs.items, .self_closing = true, .closing = closing };
            }
            const attr = x.word();
            if (attr.len == 0) return error.InvalidSvg;
            x.skipSpace();
            if (x.i >= x.src.len or x.src[x.i] != '=') {
                try x.attrs.append(a, .{ .name = attr, .value = "" });
                continue;
            }
            x.i += 1;
            x.skipSpace();
            if (x.i >= x.src.len) return error.InvalidSvg;
            const q = x.src[x.i];
            if (q != '"' and q != '\'') return error.InvalidSvg;
            const end = std.mem.indexOfScalarPos(u8, x.src, x.i + 1, q) orelse return error.InvalidSvg;
            try x.attrs.append(a, .{ .name = attr, .value = try unescape(a, x.src[x.i + 1 .. end]) });
            x.i = end + 1;
        }
    }

    fn word(x: *Xml) []const u8 {
        const start = x.i;
        while (x.i < x.src.len) : (x.i += 1) switch (x.src[x.i]) {
            ' ', '\t', '\n', '\r', '>', '/', '=' => break,
            else => {},
        };
        return x.src[start..x.i];
    }

    fn skipSpace(x: *Xml) void {
        while (x.i < x.src.len and std.ascii.isWhitespace(x.src[x.i])) x.i += 1;
    }
};

fn unescape(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') if (std.mem.indexOfScalarPos(u8, s, i, ';')) |end| {
            const name = s[i + 1 .. end];
            const ch: ?u8 = if (std.mem.eql(u8, name, "amp")) '&' else if (std.mem.eql(u8, name, "lt")) '<' else if (std.mem.eql(u8, name, "gt")) '>' else if (std.mem.eql(u8, name, "quot")) '"' else if (std.mem.eql(u8, name, "apos")) '\'' else null;
            if (ch) |c| {
                try out.append(a, c);
                i = end + 1;
                continue;
            }
        };
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

// ---- Styles ----

/// A paint as styles give it: gradients take their shape's box and
/// transform when it is drawn.
const StylePaint = union(enum) {
    paint: Paint,
    gradient: *const GradientDef,
};

/// A coordinate of a gradient: a number, or a percentage.
const Coord = struct {
    value: f32,
    percent: bool = false,

    fn parse(v: []const u8) ?Coord {
        const n = parseLength(v) orelse return null;
        return if (std.mem.endsWith(u8, std.mem.trim(u8, v, " "), "%")) .{ .value = n / 100, .percent = true } else .{ .value = n };
    }
};

/// A `linearGradient` or `radialGradient` as written (null: from the one
/// it `href`s, else the default).
const GradientDef = struct {
    radial: bool,
    coords: [7]?Coord = @splat(null),
    user_space: ?bool = null,
    transform: ?Affine = null,
    stops: std.ArrayList(GradientStop) = .empty,
    href: ?[]const u8 = null,

    const names = [7][]const u8{ "x1", "y1", "x2", "y2", "cx", "cy", "r" };
    const defaults = [7]Coord{
        .{ .value = 0, .percent = true },   .{ .value = 0, .percent = true },
        .{ .value = 1, .percent = true },   .{ .value = 0, .percent = true },
        .{ .value = 0.5, .percent = true }, .{ .value = 0.5, .percent = true },
        .{ .value = 0.5, .percent = true },
    };
};

const Style = struct {
    fill: ?StylePaint = .{ .paint = .{ .color = .black } },
    stroke: ?StylePaint = null,
    stroke_width: f32 = 1,
    opacity: f32 = 1,
    fill_opacity: f32 = 1,
    stroke_opacity: f32 = 1,
    transform: Affine = .identity,
    hidden: bool = false,
    /// Not inherited, but a group's apply to what is in it.
    clip: []const u8 = "",
    mask: []const Shape = &.{},
    blur: f32 = 0,
    /// The element's own `clip-path`, `mask` and `filter` (ids), resolved
    /// with its transform.
    clip_id: ?[]const u8 = null,
    mask_id: ?[]const u8 = null,
    font_size: f32 = 16,
    bold: bool = false,
    anchor: Text.Anchor = .start,
};

const Reader = struct {
    a: Allocator,
    src: []const u8 = "",
    /// Gradients by id.
    gradients: std.StringHashMapUnmanaged(*GradientDef) = .empty,
    /// Where elements with an id start; filters' blurs by id.
    ids: std.StringHashMapUnmanaged(usize) = .empty,
    blurs: std.StringHashMapUnmanaged(f32) = .empty,
    /// The drawing's viewbox (gradients' fractions are of it).
    vb: Rect = .empty,
    /// How deep `use`, clip paths and masks are being read in each other
    /// (a limit against loops).
    depth: u8 = 0,
    /// Reading a clip path: shapes count however they are painted.
    geometry: bool = false,

    /// An element's own presentation attributes and `style` over `parent`'s.
    fn style(r: *Reader, t: Tag, parent: Style) Error!Style {
        var s = parent;
        // Opacity is not inherited: it multiplies down the tree.
        s.opacity = 1;
        s.clip_id = null;
        s.mask_id = null;
        for (t.attrs) |at| r.property(&s, at.name, at.value);
        if (t.get("style")) |css| {
            var decls = std.mem.splitScalar(u8, css, ';');
            while (decls.next()) |d| {
                const colon = std.mem.indexOfScalar(u8, d, ':') orelse continue;
                r.property(&s, std.mem.trim(u8, d[0..colon], " \t\n\r"), std.mem.trim(u8, d[colon + 1 ..], " \t\n\r"));
            }
        }
        s.opacity *= parent.opacity;
        if (t.get("transform")) |tr| s.transform = parent.transform.mul(parseTransform(tr));
        // In the user space of the element (its transform included).
        if (s.clip_id) |id| s.clip = try r.clipPath(id, s.transform);
        if (s.mask_id) |id| s.mask = try r.maskShapes(id, s.transform);
        return s;
    }

    /// A `clipPath`'s shapes as one path data, in the drawing's
    /// coordinates (`m`: from the user space it is used in).
    fn clipPath(r: *Reader, id: []const u8, m: Affine) Error![]const u8 {
        var shapes: std.ArrayList(Shape) = .empty;
        const was = r.geometry;
        r.geometry = true;
        defer r.geometry = was;
        try r.contentOf(id, "clipPath", m, &shapes);
        var out: std.ArrayList(u8) = .empty;
        for (shapes.items) |sh| {
            if (out.items.len > 0) try out.append(r.a, ' ');
            try out.appendSlice(r.a, sh.commands);
        }
        // Defined but empty: nothing shows (a point, not everywhere).
        if (out.items.len == 0) if (r.ids.get(id) != null) return "M 0 0 Z";
        return out.items;
    }

    fn maskShapes(r: *Reader, id: []const u8, m: Affine) Error![]const Shape {
        var shapes: std.ArrayList(Shape) = .empty;
        try r.contentOf(id, "mask", m, &shapes);
        return shapes.items;
    }

    /// The shapes in element `id` (a `kind`), read as if at a place where
    /// `m` maps user space to the drawing.
    fn contentOf(r: *Reader, id: []const u8, kind: []const u8, m: Affine, out: *std.ArrayList(Shape)) Error!void {
        const at = r.ids.get(id) orelse return;
        if (r.depth >= 8) return;
        r.depth += 1;
        defer r.depth -= 1;
        var x: Xml = .{ .src = r.src, .i = at };
        const t = (try x.next(r.a)) orelse return;
        if (!std.mem.eql(u8, t.name, kind) or t.self_closing) return;
        var base: Style = .{ .transform = m };
        if (t.get("transform")) |tr| base.transform = m.mul(parseTransform(tr));
        try r.children(&x, base, out);
    }

    /// The elements up to the end of the one being read.
    fn children(r: *Reader, x: *Xml, parent: Style, out: *std.ArrayList(Shape)) Error!void {
        while (try x.next(r.a)) |t| {
            if (t.closing) return;
            try r.element(x, t, parent, out);
        }
    }

    /// Skips what is in `t`, up to its end.
    fn skip(r: *Reader, x: *Xml, t: Tag) Error!void {
        if (t.self_closing or t.closing) return;
        var depth: usize = 1;
        while (try x.next(r.a)) |n| {
            if (n.closing) {
                depth -= 1;
                if (depth == 0) return;
            } else if (!n.self_closing) depth += 1;
        }
    }

    /// Element `t` (and what is in it) into `out`.
    fn element(r: *Reader, x: *Xml, t: Tag, parent: Style, out: *std.ArrayList(Shape)) Error!void {
        if (std.mem.eql(u8, t.name, "text")) return r.text(x, t, parent, out);
        if (isUnseen(t.name)) return r.skip(x, t);
        const s = try r.style(t, parent);
        if (std.mem.eql(u8, t.name, "use")) {
            try r.skip(x, t);
            if (s.hidden) return;
            const ref = t.get("href") orelse t.get("xlink:href") orelse return;
            const at = r.ids.get(std.mem.trimStart(u8, ref, "#")) orelse return;
            if (r.depth >= 8) return;
            r.depth += 1;
            defer r.depth -= 1;
            var placed = s;
            const dx = parseLength(t.get("x") orelse "0") orelse 0;
            const dy = parseLength(t.get("y") orelse "0") orelse 0;
            placed.transform = s.transform.mul(.translation(.{ .x = dx, .y = dy }));
            var sub: Xml = .{ .src = r.src, .i = at };
            const target = (try sub.next(r.a)) orelse return;
            // A symbol is drawn where it is used, as a group.
            if (std.mem.eql(u8, target.name, "symbol")) {
                if (target.self_closing) return;
                return r.children(&sub, try r.style(target, placed), out);
            }
            return r.element(&sub, target, placed, out);
        }
        if (s.hidden) return r.skip(x, t);
        var commands: std.ArrayList(path.Command) = .empty;
        if (try shapeOf(r.a, t, &commands)) try r.shape(t.name, s, commands.items, out);
        if (!t.self_closing) try r.children(x, s, out);
    }

    fn shape(r: *Reader, name: []const u8, s: Style, commands: []const path.Command, out: *std.ArrayList(Shape)) Error!void {
        const m = s.transform;
        const data = try pathData(r.a, commands, m);
        if (r.geometry) return out.append(r.a, .{ .commands = data, .fill = .{ .color = .black } });
        // Lines have no inside.
        const filled = !std.mem.eql(u8, name, "line") and !std.mem.eql(u8, name, "polyline");
        const fill = if (filled) try r.resolve(s.fill, commands, m, r.vb, s.opacity * s.fill_opacity) else null;
        const stroke = if (s.stroke_width > 0) try r.resolve(s.stroke, commands, m, r.vb, s.opacity * s.stroke_opacity) else null;
        if (fill == null and stroke == null) return;
        const scale = @sqrt(@abs(m.a * m.d - m.b * m.c));
        try out.append(r.a, .{
            .commands = data,
            .fill = fill,
            .stroke = stroke,
            // Scaled with the shape (by the transform's average scale).
            .stroke_width = s.stroke_width * scale,
            .clip = s.clip,
            .mask = s.mask,
            .blur = s.blur * scale,
        });
    }

    /// A `text` element: its text (its `tspan`s' too), on one line.
    fn text(r: *Reader, x: *Xml, t: Tag, parent: Style, out: *std.ArrayList(Shape)) Error!void {
        const s = try r.style(t, parent);
        var content: std.ArrayList(u8) = .empty;
        if (!t.self_closing) {
            var depth: usize = 1;
            while (depth > 0) {
                const lt = std.mem.indexOfScalarPos(u8, x.src, x.i, '<') orelse x.src.len;
                const raw = try unescape(r.a, x.src[x.i..lt]);
                for (raw) |c| {
                    const space = c == ' ' or c == '\n' or c == '\t' or c == '\r';
                    if (space) {
                        if (content.items.len > 0 and content.items[content.items.len - 1] != ' ') try content.append(r.a, ' ');
                    } else try content.append(r.a, c);
                }
                x.i = lt;
                const n = (try x.next(r.a)) orelse break;
                if (n.closing) depth -= 1 else if (!n.self_closing) depth += 1;
            }
        }
        if (s.hidden or r.geometry) return;
        const words = std.mem.trim(u8, content.items, " ");
        if (words.len == 0) return;
        var pos: [1]f32 = .{0};
        const x0: f32 = if (t.get("x")) |v| (if (numbers(v, &pos) > 0) pos[0] else 0) else 0;
        const y0: f32 = if (t.get("y")) |v| (if (numbers(v, &pos) > 0) pos[0] else 0) else 0;
        const m = s.transform;
        const at = m.apply(.{ .x = x0, .y = y0 });
        const scale = @sqrt(@abs(m.a * m.d - m.b * m.c));
        // A gradient spans about where the text is.
        const box = [_]path.Command{
            .{ .move_to = .{ .x = x0, .y = y0 - s.font_size } },
            .{ .line_to = .{ .x = x0 + s.font_size * 0.6 * @as(f32, @floatFromInt(words.len)), .y = y0 } },
        };
        const fill = try r.resolve(s.fill, &box, m, r.vb, s.opacity * s.fill_opacity) orelse return;
        try out.append(r.a, .{
            .commands = "",
            .fill = fill,
            .clip = s.clip,
            .mask = s.mask,
            .blur = s.blur * scale,
            .text = .{ .content = words, .x = at.x, .y = at.y, .size = s.font_size * scale, .anchor = s.anchor, .bold = s.bold },
        });
    }

    fn property(r: *Reader, s: *Style, name: []const u8, value: []const u8) void {
        const v = std.mem.trim(u8, value, " \t\n\r");
        if (std.mem.eql(u8, name, "fill")) {
            s.fill = r.paint(v) orelse s.fill;
        } else if (std.mem.eql(u8, name, "stroke")) {
            s.stroke = r.paint(v) orelse s.stroke;
        } else if (std.mem.eql(u8, name, "stroke-width")) {
            s.stroke_width = parseLength(v) orelse s.stroke_width;
        } else if (std.mem.eql(u8, name, "opacity")) {
            s.opacity = parseFraction(v) orelse s.opacity;
        } else if (std.mem.eql(u8, name, "fill-opacity")) {
            s.fill_opacity = parseFraction(v) orelse s.fill_opacity;
        } else if (std.mem.eql(u8, name, "stroke-opacity")) {
            s.stroke_opacity = parseFraction(v) orelse s.stroke_opacity;
        } else if (std.mem.eql(u8, name, "display")) {
            if (std.mem.eql(u8, v, "none")) s.hidden = true;
        } else if (std.mem.eql(u8, name, "visibility")) {
            s.hidden = std.mem.eql(u8, v, "hidden") or std.mem.eql(u8, v, "collapse");
        } else if (std.mem.eql(u8, name, "clip-path")) {
            s.clip_id = urlId(v);
        } else if (std.mem.eql(u8, name, "mask")) {
            s.mask_id = urlId(v);
        } else if (std.mem.eql(u8, name, "filter")) {
            s.blur = if (urlId(v)) |id| r.blurs.get(id) orelse 0 else 0;
        } else if (std.mem.eql(u8, name, "font-size")) {
            s.font_size = parseLength(v) orelse s.font_size;
        } else if (std.mem.eql(u8, name, "font-weight")) {
            const n = std.fmt.parseInt(u16, v, 10) catch 0;
            s.bold = std.mem.eql(u8, v, "bold") or std.mem.eql(u8, v, "bolder") or n >= 600;
        } else if (std.mem.eql(u8, name, "text-anchor")) {
            s.anchor = if (std.mem.eql(u8, v, "middle")) .middle else if (std.mem.eql(u8, v, "end")) .end else .start;
        }
    }

    /// A paint (`none` is a paint of nothing: `.{ .color = transparent }`
    /// is not used, the shape just has no fill); null if not understood.
    fn paint(r: *Reader, v: []const u8) ?StylePaint {
        if (std.mem.eql(u8, v, "none")) return .{ .paint = .{ .color = .transparent } };
        if (std.mem.eql(u8, v, "currentColor")) return .{ .paint = .current };
        if (std.mem.startsWith(u8, v, "url(")) {
            const end = std.mem.indexOfScalar(u8, v, ')') orelse return null;
            const id = std.mem.trim(u8, v[4..end], " #'\"");
            if (r.gradients.get(id)) |g| return .{ .gradient = g };
            // A fallback after the URL.
            return r.paint(std.mem.trim(u8, v[end + 1 ..], " "));
        }
        return .{ .paint = .{ .color = parseColor(v) orelse return null } };
    }

    /// The first pass: gradients with their stops, where elements with an
    /// id are, filters' blurs.
    fn readDefs(r: *Reader, src: []const u8) Error!void {
        var x: Xml = .{ .src = src };
        var current: ?*GradientDef = null;
        var filter: ?[]const u8 = null;
        while (try x.next(r.a)) |t| {
            if (!t.closing) if (t.get("id")) |id| try r.ids.put(r.a, id, x.start);
            if (std.mem.eql(u8, t.name, "filter")) {
                filter = if (t.closing or t.self_closing) null else t.get("id");
            } else if (std.mem.eql(u8, t.name, "feGaussianBlur")) if (filter) |f| {
                var dev: [2]f32 = undefined;
                if (numbers(t.get("stdDeviation") orelse "", &dev) > 0 and !r.blurs.contains(f)) try r.blurs.put(r.a, f, @max(0, dev[0]));
            };
            const radial = std.mem.eql(u8, t.name, "radialGradient");
            const gradient = radial or std.mem.eql(u8, t.name, "linearGradient");
            if (gradient and !t.closing) {
                const g = try r.a.create(GradientDef);
                g.* = .{ .radial = radial };
                for (GradientDef.names, &g.coords) |n, *c| if (t.get(n)) |v| {
                    c.* = Coord.parse(v);
                };
                if (t.get("gradientUnits")) |u| g.user_space = std.mem.eql(u8, u, "userSpaceOnUse");
                if (t.get("gradientTransform")) |tr| g.transform = parseTransform(tr);
                if (t.get("href") orelse t.get("xlink:href")) |ref| g.href = std.mem.trimStart(u8, ref, "#");
                if (t.get("id")) |id| try r.gradients.put(r.a, id, g);
                current = if (t.self_closing) null else g;
            } else if (gradient and t.closing) {
                current = null;
            } else if (std.mem.eql(u8, t.name, "stop")) if (current) |g| {
                var color: Color = .black;
                var opacity: f32 = 1;
                if (t.get("stop-color")) |c| color = parseColor(c) orelse color;
                if (t.get("stop-opacity")) |o| opacity = parseFraction(o) orelse opacity;
                if (t.get("style")) |css| {
                    var decls = std.mem.splitScalar(u8, css, ';');
                    while (decls.next()) |d| {
                        const colon = std.mem.indexOfScalar(u8, d, ':') orelse continue;
                        const n = std.mem.trim(u8, d[0..colon], " ");
                        const v = std.mem.trim(u8, d[colon + 1 ..], " ");
                        if (std.mem.eql(u8, n, "stop-color")) color = parseColor(v) orelse color;
                        if (std.mem.eql(u8, n, "stop-opacity")) opacity = parseFraction(v) orelse opacity;
                    }
                }
                const offset = std.math.clamp(parseFraction(t.get("offset") orelse "0") orelse 0, 0, 1);
                const last = if (g.stops.items.len > 0) g.stops.items[g.stops.items.len - 1].position else 0;
                try g.stops.append(r.a, .{ .color = withOpacity(color, opacity), .position = @max(offset, last) });
            };
        }
    }

    /// A shape's paint: a gradient over the shape (`commands`, mapped by
    /// `m` into the drawing, whose viewbox is `vb`), with `opacity`; null
    /// if nothing shows.
    fn resolve(r: *Reader, p: ?StylePaint, commands: []const path.Command, m: Affine, vb: Rect, opacity: f32) Error!?Paint {
        const sp = p orelse return null;
        const def = switch (sp) {
            .paint => |pp| return visible(pp, opacity),
            .gradient => |g| g,
        };
        if (opacity <= 0) return null;
        // What it does not say, from the gradients it refers to.
        var coords = def.coords;
        var user_space = def.user_space;
        var transform = def.transform;
        var stops = def.stops.items;
        var g = def;
        for (0..16) |_| {
            const next = r.gradients.get(g.href orelse break) orelse break;
            if (next == g) break;
            g = next;
            for (&coords, g.coords) |*c, o| if (c.* == null) {
                c.* = o;
            };
            if (user_space == null) user_space = g.user_space;
            if (transform == null) transform = g.transform;
            if (stops.len == 0) stops = g.stops.items;
        }
        if (stops.len == 0) return null;
        const own = try r.a.alloc(GradientStop, stops.len);
        for (own, stops) |*o, st| o.* = .{ .color = withOpacity(st.color, opacity), .position = st.position };
        if (stops.len == 1) return visible(.{ .color = stops[0].color }, opacity);
        const last: Paint = .{ .color = withOpacity(stops[stops.len - 1].color, opacity) };

        // Gradient coordinates to the drawing's, then to fractions of its
        // viewbox.
        var space = transform orelse Affine.identity;
        const in_user = user_space orelse false;
        if (!in_user) {
            var polylines: path.Polylines = .{};
            try path.flatten(r.a, commands, .{}, 0.1, &polylines);
            const box = polylines.bounds();
            // A box with no width or height has no fractions.
            if (box.width <= 0 or box.height <= 0) return null;
            space = Affine.translation(.{ .x = box.x, .y = box.y }).mul(.scaling(box.width, box.height)).mul(space);
        }
        if (vb.width <= 0 or vb.height <= 0) return null;
        const to_vb = Affine.scaling(1 / vb.width, 1 / vb.height).mul(.translation(.{ .x = -vb.x, .y = -vb.y }));
        const t = to_vb.mul(m).mul(space);
        // User space percentages are of the viewport (the radius, of its
        // diagonal / sqrt 2).
        var v: [7]f32 = undefined;
        for (&v, coords, GradientDef.defaults, 0..) |*o, c, d, i| {
            const coord = c orelse d;
            const of = if (!in_user or !coord.percent) 1 else switch (i) {
                0, 2, 4 => vb.width,
                1, 3, 5 => vb.height,
                else => @sqrt((vb.width * vb.width + vb.height * vb.height) / 2),
            };
            o.* = coord.value * of;
        }

        if (!def.radial) {
            // t = (q - p1) . d / |d|^2 at q = t^-1(u): a linear function of
            // u, its gradient `k` and its value `c0` at 0.
            const d = [2]f32{ v[2] - v[0], v[3] - v[1] };
            const dd = d[0] * d[0] + d[1] * d[1];
            const inv = t.inverse() orelse return last;
            if (dd == 0) return last;
            const k = [2]f32{ (inv.a * d[0] + inv.b * d[1]) / dd, (inv.c * d[0] + inv.d * d[1]) / dd };
            const c0 = ((inv.tx - v[0]) * d[0] + (inv.ty - v[1]) * d[1]) / dd;
            const kk = k[0] * k[0] + k[1] * k[1];
            if (kk == 0) return last;
            // The line from where it is 0 to where it is 1.
            const start = [2]f32{ -c0 * k[0] / kk, -c0 * k[1] / kk };
            const g_ = try r.a.create(graphics.LinearGradient);
            g_.* = .{ .stops = .init(own), .line = .{ start, .{ start[0] + k[0] / kk, start[1] + k[1] / kk } } };
            return .{ .gradient = .{ .linear_gradient = g_ } };
        }
        if (v[6] <= 0) return last;
        const center = t.apply(.{ .x = v[4], .y = v[5] });
        // The circle's extent across and down (exact without rotation, or
        // with a uniform scale).
        const g_ = try r.a.create(graphics.RadialGradient);
        g_.* = .{ .stops = .init(own), .ellipse = .{
            .center = .{ center.x, center.y },
            .radius = .{ v[6] * @sqrt(t.a * t.a + t.c * t.c), v[6] * @sqrt(t.b * t.b + t.d * t.d) },
        } };
        return .{ .gradient = .{ .radial_gradient = g_ } };
    }
};

fn withOpacity(c: Color, o: f32) Color {
    return c.withAlpha(@intFromFloat(@round(@as(f32, @floatFromInt(c.a)) * std.math.clamp(o, 0, 1))));
}

fn parseLength(v: []const u8) ?f32 {
    var end: usize = 0;
    while (end < v.len and (std.ascii.isDigit(v[end]) or v[end] == '.' or v[end] == '-' or v[end] == '+' or v[end] == 'e' or v[end] == 'E')) end += 1;
    return std.fmt.parseFloat(f32, v[0..end]) catch null;
}

fn parseFraction(v: []const u8) ?f32 {
    const n = parseLength(v) orelse return null;
    return if (std.mem.endsWith(u8, v, "%")) n / 100 else n;
}

const named_colors = [_]struct { []const u8, u24 }{
    .{ "black", 0x000000 },     .{ "white", 0xffffff },  .{ "red", 0xff0000 },     .{ "green", 0x008000 },
    .{ "blue", 0x0000ff },      .{ "yellow", 0xffff00 }, .{ "orange", 0xffa500 },  .{ "purple", 0x800080 },
    .{ "gray", 0x808080 },      .{ "grey", 0x808080 },   .{ "silver", 0xc0c0c0 },  .{ "maroon", 0x800000 },
    .{ "navy", 0x000080 },      .{ "teal", 0x008080 },   .{ "olive", 0x808000 },   .{ "lime", 0x00ff00 },
    .{ "aqua", 0x00ffff },      .{ "cyan", 0x00ffff },   .{ "fuchsia", 0xff00ff }, .{ "magenta", 0xff00ff },
    .{ "brown", 0xa52a2a },     .{ "pink", 0xffc0cb },   .{ "gold", 0xffd700 },    .{ "darkgray", 0xa9a9a9 },
    .{ "lightgray", 0xd3d3d3 },
};

pub fn parseColor(v: []const u8) ?Color {
    if (v.len == 0) return null;
    if (v[0] == '#') {
        const hex = v[1..];
        const n = std.fmt.parseInt(u32, hex, 16) catch return null;
        return switch (hex.len) {
            3 => .rgb(@intCast(((n >> 8) & 0xf) * 0x110000 + ((n >> 4) & 0xf) * 0x1100 + (n & 0xf) * 0x11)),
            6 => .rgb(@intCast(n)),
            8 => .rgba(n),
            else => null,
        };
    }
    if (std.mem.startsWith(u8, v, "rgb")) {
        const open = std.mem.indexOfScalar(u8, v, '(') orelse return null;
        const close = std.mem.indexOfScalar(u8, v, ')') orelse return null;
        var parts = std.mem.tokenizeAny(u8, v[open + 1 .. close], ", /");
        var ch: [4]f32 = .{ 0, 0, 0, 1 };
        var k: usize = 0;
        while (parts.next()) |p| : (k += 1) {
            if (k >= 4) break;
            const n = parseLength(p) orelse return null;
            ch[k] = if (std.mem.endsWith(u8, p, "%")) (if (k == 3) n / 100 else n * 2.55) else n;
        }
        if (k < 3) return null;
        const byte = struct {
            fn f(x: f32) u8 {
                return @intFromFloat(std.math.clamp(@round(x), 0, 255));
            }
        }.f;
        return .{ .r = byte(ch[0]), .g = byte(ch[1]), .b = byte(ch[2]), .a = byte(ch[3] * 255) };
    }
    for (named_colors) |nc| if (std.ascii.eqlIgnoreCase(v, nc[0])) return .rgb(nc[1]);
    if (std.ascii.eqlIgnoreCase(v, "transparent")) return .transparent;
    return null;
}

/// Numbers in a list (`1,2 3`), into `out`; how many.
fn numbers(s: []const u8, out: []f32) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, ", \t\n\r");
    while (it.next()) |tok| {
        if (n == out.len) break;
        out[n] = std.fmt.parseFloat(f32, tok) catch return n;
        n += 1;
    }
    return n;
}

pub fn parseTransform(s: []const u8) Affine {
    var m: Affine = .identity;
    var i: usize = 0;
    while (i < s.len) {
        const open = std.mem.indexOfScalarPos(u8, s, i, '(') orelse break;
        const close = std.mem.indexOfScalarPos(u8, s, open, ')') orelse break;
        const name = std.mem.trim(u8, s[i..open], " ,\t\n\r");
        var v: [6]f32 = undefined;
        const n = numbers(s[open + 1 .. close], &v);
        const t: Affine = if (std.mem.eql(u8, name, "matrix") and n == 6)
            .{ .a = v[0], .b = v[1], .c = v[2], .d = v[3], .tx = v[4], .ty = v[5] }
        else if (std.mem.eql(u8, name, "translate") and n >= 1)
            .translation(.{ .x = v[0], .y = if (n >= 2) v[1] else 0 })
        else if (std.mem.eql(u8, name, "scale") and n >= 1)
            .scaling(v[0], if (n >= 2) v[1] else v[0])
        else if (std.mem.eql(u8, name, "rotate") and n >= 1)
            (if (n >= 3) Affine.translation(.{ .x = v[1], .y = v[2] }).mul(Affine.rotation(v[0])).mul(.translation(.{ .x = -v[1], .y = -v[2] })) else Affine.rotation(v[0]))
        else if (std.mem.eql(u8, name, "skewX") and n >= 1)
            .{ .c = @tan(v[0] * std.math.pi / 180) }
        else if (std.mem.eql(u8, name, "skewY") and n >= 1)
            .{ .b = @tan(v[0] * std.math.pi / 180) }
        else
            .identity;
        m = m.mul(t);
        i = close + 1;
    }
    return m;
}

// ---- Shapes ----

/// An element's shape as path commands (in its own coordinates), or null.
fn shapeOf(a: Allocator, t: Tag, out: *std.ArrayList(path.Command)) Error!bool {
    const num = struct {
        fn f(tag: Tag, name: []const u8) f32 {
            return parseLength(tag.get(name) orelse return 0) orelse 0;
        }
    }.f;
    const name = t.name;
    if (std.mem.eql(u8, name, "path")) {
        path.parse(a, t.get("d") orelse return false, out) catch |err| switch (err) {
            // What was read before the error is drawn (as browsers do).
            error.InvalidPath => {},
            error.OutOfMemory => return error.OutOfMemory,
        };
        return out.items.len > 0;
    }
    if (std.mem.eql(u8, name, "rect")) {
        const x = num(t, "x");
        const y = num(t, "y");
        const w = num(t, "width");
        const h = num(t, "height");
        if (w <= 0 or h <= 0) return false;
        var rx = num(t, "rx");
        var ry = num(t, "ry");
        if (t.get("rx") == null) rx = ry;
        if (t.get("ry") == null) ry = rx;
        rx = @min(rx, w / 2);
        ry = @min(ry, h / 2);
        if (rx <= 0 or ry <= 0) {
            try out.appendSlice(a, &.{ .{ .move_to = .{ .x = x, .y = y } }, .{ .line_to = .{ .x = x + w, .y = y } }, .{ .line_to = .{ .x = x + w, .y = y + h } }, .{ .line_to = .{ .x = x, .y = y + h } }, .close });
            return true;
        }
        // Corners as quarter ellipses (cubic, k = 0.5523).
        const kx = rx * 0.5523;
        const ky = ry * 0.5523;
        try out.appendSlice(a, &.{
            .{ .move_to = .{ .x = x + rx, .y = y } },
            .{ .line_to = .{ .x = x + w - rx, .y = y } },
            .{ .cubic_to = .{ .c1 = .{ .x = x + w - rx + kx, .y = y }, .c2 = .{ .x = x + w, .y = y + ry - ky }, .p = .{ .x = x + w, .y = y + ry } } },
            .{ .line_to = .{ .x = x + w, .y = y + h - ry } },
            .{ .cubic_to = .{ .c1 = .{ .x = x + w, .y = y + h - ry + ky }, .c2 = .{ .x = x + w - rx + kx, .y = y + h }, .p = .{ .x = x + w - rx, .y = y + h } } },
            .{ .line_to = .{ .x = x + rx, .y = y + h } },
            .{ .cubic_to = .{ .c1 = .{ .x = x + rx - kx, .y = y + h }, .c2 = .{ .x = x, .y = y + h - ry + ky }, .p = .{ .x = x, .y = y + h - ry } } },
            .{ .line_to = .{ .x = x, .y = y + ry } },
            .{ .cubic_to = .{ .c1 = .{ .x = x, .y = y + ry - ky }, .c2 = .{ .x = x + rx - kx, .y = y }, .p = .{ .x = x + rx, .y = y } } },
            .close,
        });
        return true;
    }
    if (std.mem.eql(u8, name, "circle") or std.mem.eql(u8, name, "ellipse")) {
        const cx = num(t, "cx");
        const cy = num(t, "cy");
        const circle = std.mem.eql(u8, name, "circle");
        const rx = if (circle) num(t, "r") else num(t, "rx");
        const ry = if (circle) rx else num(t, "ry");
        if (rx <= 0 or ry <= 0) return false;
        const kx = rx * 0.5523;
        const ky = ry * 0.5523;
        try out.appendSlice(a, &.{
            .{ .move_to = .{ .x = cx + rx, .y = cy } },
            .{ .cubic_to = .{ .c1 = .{ .x = cx + rx, .y = cy + ky }, .c2 = .{ .x = cx + kx, .y = cy + ry }, .p = .{ .x = cx, .y = cy + ry } } },
            .{ .cubic_to = .{ .c1 = .{ .x = cx - kx, .y = cy + ry }, .c2 = .{ .x = cx - rx, .y = cy + ky }, .p = .{ .x = cx - rx, .y = cy } } },
            .{ .cubic_to = .{ .c1 = .{ .x = cx - rx, .y = cy - ky }, .c2 = .{ .x = cx - kx, .y = cy - ry }, .p = .{ .x = cx, .y = cy - ry } } },
            .{ .cubic_to = .{ .c1 = .{ .x = cx + kx, .y = cy - ry }, .c2 = .{ .x = cx + rx, .y = cy - ky }, .p = .{ .x = cx + rx, .y = cy } } },
            .close,
        });
        return true;
    }
    if (std.mem.eql(u8, name, "line")) {
        try out.appendSlice(a, &.{ .{ .move_to = .{ .x = num(t, "x1"), .y = num(t, "y1") } }, .{ .line_to = .{ .x = num(t, "x2"), .y = num(t, "y2") } } });
        return true;
    }
    if (std.mem.eql(u8, name, "polyline") or std.mem.eql(u8, name, "polygon")) {
        var v: [2]f32 = undefined;
        var it = std.mem.tokenizeAny(u8, t.get("points") orelse return false, ", \t\n\r");
        var first = true;
        while (it.next()) |tok| {
            v[0] = std.fmt.parseFloat(f32, tok) catch break;
            const tok2 = it.next() orelse break;
            v[1] = std.fmt.parseFloat(f32, tok2) catch break;
            const p: Point = .{ .x = v[0], .y = v[1] };
            try out.append(a, if (first) .{ .move_to = p } else .{ .line_to = p });
            first = false;
        }
        if (first) return false;
        if (std.mem.eql(u8, name, "polygon")) try out.append(a, .close);
        return true;
    }
    return false;
}

/// `commands` mapped by `m`, as path data.
fn pathData(a: Allocator, commands: []const path.Command, m: Affine) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    const P = struct {
        fn p(wr: *std.Io.Writer, mm: Affine, pt: Point) void {
            const q = mm.apply(pt);
            wr.print(" {d} {d}", .{ round(q.x), round(q.y) }) catch {};
        }
        fn round(x: f32) f32 {
            return @round(x * 1000) / 1000;
        }
    };
    for (commands) |c| switch (c) {
        .move_to => |pt| {
            w.writeAll("M") catch return error.OutOfMemory;
            P.p(w, m, pt);
        },
        .line_to => |pt| {
            w.writeAll("L") catch return error.OutOfMemory;
            P.p(w, m, pt);
        },
        .quad_to => |q| {
            w.writeAll("Q") catch return error.OutOfMemory;
            P.p(w, m, q.c);
            P.p(w, m, q.p);
        },
        .cubic_to => |q| {
            w.writeAll("C") catch return error.OutOfMemory;
            P.p(w, m, q.c1);
            P.p(w, m, q.c2);
            P.p(w, m, q.p);
        },
        .close => w.writeAll("Z") catch return error.OutOfMemory,
    };
    return out.written();
}

/// Reads an SVG file (everything allocated with `a`, an arena).
pub fn parse(a: Allocator, src: []const u8) Error!Drawing {
    var r: Reader = .{ .a = a, .src = src };
    try r.readDefs(src);
    var x: Xml = .{ .src = src };
    var shapes: std.ArrayList(Shape) = .empty;
    while (try x.next(a)) |t| {
        if (t.closing or !std.mem.eql(u8, t.name, "svg")) continue;
        var d = rootOf(t);
        r.vb = d.viewbox;
        if (!t.self_closing) try r.children(&x, try r.style(t, .{}), &shapes);
        d.shapes = shapes.items;
        return d;
    }
    return error.InvalidSvg;
}

/// The id in `url(#id)`.
fn urlId(v: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, v, "url(")) return null;
    const end = std.mem.indexOfScalar(u8, v, ')') orelse return null;
    return std.mem.trim(u8, v[4..end], " #'\"");
}

/// Elements whose content is not drawn where it is.
fn isUnseen(name: []const u8) bool {
    const unseen = [_][]const u8{ "defs", "clipPath", "mask", "pattern", "marker", "symbol", "linearGradient", "radialGradient", "text", "style", "title", "desc", "metadata", "filter", "foreignObject" };
    for (unseen) |u| if (std.mem.eql(u8, name, u)) return true;
    return false;
}

/// A paint with its opacity applied; null when nothing shows.
fn visible(p: ?Paint, opacity: f32) ?Paint {
    const paint = p orelse return null;
    return switch (paint) {
        .color => |c| if (c.a == 0 or opacity <= 0) null else .{ .color = withOpacity(c, opacity) },
        .current => if (opacity <= 0) null else .current,
        .gradient => paint,
    };
}

fn rootOf(t: Tag) Drawing {
    var vb: ?Rect = null;
    if (t.get("viewBox")) |v| {
        var n: [4]f32 = undefined;
        if (numbers(v, &n) == 4 and n[2] > 0 and n[3] > 0) vb = .{ .x = n[0], .y = n[1], .width = n[2], .height = n[3] };
    }
    // Percentages are of nothing here: the viewBox's size instead.
    const length = struct {
        fn f(s: ?[]const u8) ?f32 {
            const v = s orelse return null;
            if (std.mem.endsWith(u8, v, "%")) return null;
            const n = parseLength(v) orelse return null;
            return if (n > 0) n else null;
        }
    }.f;
    // (Kept to sizes an image can have.)
    const w = @min(length(t.get("width")) orelse if (vb) |v| v.width else 100, 65536);
    const h = @min(length(t.get("height")) orelse if (vb) |v| v.height else 100, 65536);
    return .{ .viewbox = vb orelse .{ .width = w, .height = h }, .width = w, .height = h, .shapes = &.{} };
}

// ---- Tests ----

const testing = std.testing;

test "svg: shapes, styles, groups and transforms" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = try parse(arena.allocator(),
        \\<?xml version="1.0"?>
        \\<!-- an icon -->
        \\<svg xmlns="http://www.w3.org/2000/svg" width="48" height="24" viewBox="0 0 24 12">
        \\  <defs><linearGradient id="g"><stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="blue"/></linearGradient>
        \\    <rect id="hidden" width="5" height="5"/></defs>
        \\  <rect x="1" y="1" width="4" height="2" fill="#0f0"/>
        \\  <g fill="none" stroke="rgb(0, 0, 255)" stroke-width="2" transform="translate(10 0)">
        \\    <circle cx="2" cy="2" r="1"/>
        \\    <line x1="0" y1="0" x2="3" y2="0" transform="scale(2)" style="stroke: currentColor; stroke-opacity: 0.5"/>
        \\  </g>
        \\  <path d="M0 0 h4 v4 z" fill="url(#g)" opacity="0.5"/>
        \\  <polygon points="0,0 1,0 1,1" fill="none"/>
        \\</svg>
    );
    try testing.expectEqual(@as(f32, 48), d.width);
    try testing.expectEqual(@as(f32, 24), d.viewbox.width);
    try testing.expectEqual(@as(usize, 4), d.shapes.len);
    // The rect: green, no stroke.
    try testing.expectEqualStrings("M 1 1L 5 1L 5 3L 1 3Z", d.shapes[0].commands);
    try testing.expectEqual(Paint{ .color = .rgb(0x00ff00) }, d.shapes[0].fill.?);
    try testing.expect(d.shapes[0].stroke == null);
    // The circle: moved 10 right, stroked only.
    try testing.expect(std.mem.startsWith(u8, d.shapes[1].commands, "M 13 2C"));
    try testing.expect(d.shapes[1].fill == null);
    try testing.expectEqual(Paint{ .color = .rgb(0x0000ff) }, d.shapes[1].stroke.?);
    // The line: scaled 2, its stroke too; current color, half there.
    try testing.expectEqualStrings("M 10 0L 16 0", d.shapes[2].commands);
    try testing.expectEqual(@as(f32, 4), d.shapes[2].stroke_width);
    try testing.expectEqual(Paint.current, d.shapes[2].stroke.?);
    // The path: the gradient across its box (0 to 4 of the viewbox's 24),
    // half opaque.
    const g = d.shapes[3].fill.?.gradient.linear_gradient;
    try testing.expectEqual(Color.rgba(0xff000080), g.stops.items[0].color);
    try testing.expectEqual(Color.rgba(0x0000ff80), g.stops.items[1].color);
    try expectPoint(.{ 0, 0 }, g.line.?[0]);
    try expectPoint(.{ 4.0 / 24.0, 0 }, g.line.?[1]);
}

fn expectPoint(want: [2]f32, got: [2]f32) !void {
    try testing.expectApproxEqAbs(want[0], got[0], 1e-5);
    try testing.expectApproxEqAbs(want[1], got[1], 1e-5);
}

test "svg: gradients" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = try parse(arena.allocator(),
        \\<svg viewBox="0 0 100 50">
        \\  <defs>
        \\    <linearGradient id="base"><stop offset="0" stop-color="red"/><stop offset="100%" stop-color="blue" stop-opacity="0.5"/></linearGradient>
        \\    <linearGradient id="u" href="#base" gradientUnits="userSpaceOnUse" x1="10" y1="0" x2="60" y2="0" gradientTransform="translate(10 0)"/>
        \\    <linearGradient id="flat" href="#base" x1="0.5" x2="0.5"/>
        \\  </defs>
        \\  <rect width="100" height="50" fill="url(#u)"/>
        \\  <rect x="20" y="10" width="40" height="20" fill="url(#r)"/>
        \\  <rect width="10" height="10" fill="url(#flat)"/>
        \\  <rect width="10" height="10" fill="url(#missing) green"/>
        \\  <rect width="10" height="10" transform="rotate(90)" stroke="url(#u)" fill="none"/>
        \\  <radialGradient id="r" xlink:href="#base" cx="0.25" gradientTransform="scale(2 1)"/>
        \\</svg>
    );
    try testing.expectEqual(@as(usize, 5), d.shapes.len);
    // In the drawing's coordinates, moved by its transform: 20 to 70.
    const u = d.shapes[0].fill.?.gradient.linear_gradient;
    try expectPoint(.{ 0.2, 0 }, u.line.?[0]);
    try expectPoint(.{ 0.7, 0 }, u.line.?[1]);
    try testing.expectEqual(@as(usize, 2), u.stops.items.len);
    // Read after it is used, its stops from the one it refers to; over
    // the rect's box, stretched twice as wide from it.
    const r = d.shapes[1].fill.?.gradient.radial_gradient;
    try expectPoint(.{ 0.4, 0.4 }, r.ellipse.?.center);
    try expectPoint(.{ 0.4, 0.2 }, r.ellipse.?.radius);
    try testing.expectEqual(Color.rgb(0xff0000), r.stops.items[0].color);
    // A line of no length: the last stop's color.
    try testing.expectEqual(Paint{ .color = .rgba(0x0000ff80) }, d.shapes[2].fill.?);
    try testing.expectEqual(Paint{ .color = .rgb(0x008000) }, d.shapes[3].fill.?);
    // Turned with the shape: from top to bottom.
    const turned = d.shapes[4].stroke.?.gradient.linear_gradient;
    try expectPoint(.{ 0, 0.4 }, turned.line.?[0]);
    try expectPoint(.{ 0, 1.4 }, turned.line.?[1]);
}

test "svg: colors and transforms parse" {
    try testing.expectEqual(Color.rgb(0xaabbcc), parseColor("#abc").?);
    try testing.expectEqual(Color.rgb(0x112233), parseColor("#112233").?);
    try testing.expectEqual(Color.rgb(0xff8000), parseColor("rgb(100%, 50.2%, 0)").?);
    try testing.expectEqual(Color.rgb(0x808080), parseColor("Gray").?);
    try testing.expect(parseColor("bogus") == null);
    const m = parseTransform("translate(10,20) rotate(90)");
    const p = m.apply(.{ .x = 1, .y = 0 });
    try testing.expectApproxEqAbs(@as(f32, 10), p.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 21), p.y, 1e-4);
}

test "svg: broken files are refused or read as far as they go" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidSvg, parse(a, "<html></html>"));
    try testing.expectError(error.InvalidSvg, parse(a, "<svg width=\"3"));
    const d = try parse(a, "<svg viewBox='0 0 10 10'><path d='M 0 0 L 5 5 L oops'/></svg>");
    try testing.expectEqualStrings("M 0 0L 5 5", d.shapes[0].commands);
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    const parts = [_][]const u8{ "<svg>", "<g transform='scale(2)'>", "</g>", "<rect width='3' height='4'/>", "<circle r='2'/>", "<path d='M0 0 L1 1'/>", "<", ">", "'", "=", "fill=", " ", "</svg>", "<!--", "-->", "x" };
    for (0..2000) |_| {
        var buf: std.ArrayList(u8) = .empty;
        for (0..r.uintLessThan(usize, 12)) |_| try buf.appendSlice(a, parts[r.uintLessThan(usize, parts.len)]);
        _ = parse(a, buf.items) catch {};
    }
}

test "svg: use, clip paths, masks, blurs and text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // tests/ui/features.svg
    const d = try parse(arena.allocator(),
        \\<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="128" height="64" viewBox="0 0 128 64">
        \\  <defs>
        \\    <rect id="dot" width="10" height="10" fill="#dc2626"/>
        \\    <clipPath id="half"><rect x="0" y="0" width="32" height="64"/></clipPath>
        \\    <mask id="fade">
        \\      <rect x="64" y="0" width="32" height="64" fill="white"/>
        \\      <rect x="96" y="0" width="32" height="64" fill="black"/>
        \\    </mask>
        \\    <filter id="soft"><feGaussianBlur stdDeviation="2"/></filter>
        \\  </defs>
        \\  <circle cx="32" cy="32" r="30" fill="#16a34a" clip-path="url(#half)"/>
        \\  <rect x="64" y="0" width="64" height="64" fill="#2563eb" mask="url(#fade)"/>
        \\  <use href="#dot" x="5" y="50"/>
        \\  <use xlink:href="#dot" x="20" y="50"/>
        \\  <rect x="40" y="40" width="16" height="16" fill="black" filter="url(#soft)"/>
        \\  <text x="64" y="20" font-size="12" text-anchor="middle" fill="#000">Hi <tspan font-weight="bold">there</tspan></text>
        \\</svg>
    );
    try testing.expectEqual(@as(usize, 6), d.shapes.len);
    const circle = d.shapes[0];
    try testing.expect(std.mem.startsWith(u8, circle.clip, "M 0 0"));
    const masked = d.shapes[1];
    try testing.expectEqual(@as(usize, 2), masked.mask.len);
    try testing.expectEqual(Color.white, masked.mask[0].fill.?.color);
    // The definition, where each use puts it.
    try testing.expect(std.mem.startsWith(u8, d.shapes[2].commands, "M 5 50"));
    try testing.expect(std.mem.startsWith(u8, d.shapes[3].commands, "M 20 50"));
    try testing.expectEqual(@as(f32, 2), d.shapes[4].blur);
    const t = d.shapes[5].text.?;
    try testing.expectEqualStrings("Hi there", t.content);
    try testing.expectEqual(Text.Anchor.middle, t.anchor);
    try testing.expectEqual(@as(f32, 64), t.x);
    try testing.expectEqual(@as(f32, 20), t.y);
    try testing.expectEqual(@as(f32, 12), t.size);
}

test "svg: use loops and missing references are harmless" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = try parse(arena.allocator(),
        \\<svg viewBox="0 0 10 10"><g id="a"><use href="#a"/><rect width="1" height="1"/></g>
        \\<use href="#nothing"/><rect width="2" height="2" clip-path="url(#none)" mask="url(#none)" filter="url(#none)"/></svg>
    );
    try testing.expect(d.shapes.len > 1);
    const last = d.shapes[d.shapes.len - 1];
    try testing.expectEqualStrings("", last.clip);
    try testing.expectEqual(@as(usize, 0), last.mask.len);
}
