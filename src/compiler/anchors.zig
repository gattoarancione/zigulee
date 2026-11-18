// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! `anchors.*` bindings, as QML's: an element's edges tied to its parent's
//! or a sibling's. Rewritten after parsing into bindings of `x`, `y`,
//! `width` and `height`, so the rest of the compiler and the interpreter
//! never see them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Span = ast.Span;
const Diagnostics = @import("diagnostics.zig").Diagnostics;

pub const Error = error{ParseError} || Allocator.Error;

/// Where an element sits.
pub const Place = union(enum) {
    /// A component's root element: nothing to anchor to.
    root,
    /// A child of an element of this type, among siblings with these ids.
    child: struct { parent_type: []const u8, siblings: []const []const u8 },
};

const Edge = enum {
    left,
    right,
    horizontal_center,
    top,
    bottom,
    vertical_center,

    fn vertical(e: Edge) bool {
        return @intFromEnum(e) >= @intFromEnum(Edge.top);
    }

    /// The first six of `names`, in order.
    fn named(name: []const u8) ?Edge {
        for (names[0..6], 0..) |n, i| if (std.mem.eql(u8, name, n[0])) return @enumFromInt(i);
        return null;
    }
};

/// Another element's edge: `parent.left`, `other.bottom`.
const Target = struct { object: []const u8, edge: Edge, span: Span };

const Anchors = struct {
    edges: [6]?Target = @splat(null),
    /// left, right, top, bottom, then all four.
    margins: [5]?*ast.Expr = @splat(null),
    /// horizontal, vertical
    offsets: [2]?*ast.Expr = @splat(null),
    span: Span,
};

/// What can follow `anchors.`, with a description (for completion).
pub const names = [_][2][]const u8{
    .{ "left", "edge: parent.left, other.right..." },
    .{ "right", "edge" },
    .{ "horizontal-center", "edge" },
    .{ "top", "edge: parent.top, other.bottom..." },
    .{ "bottom", "edge" },
    .{ "vertical-center", "edge" },
    .{ "fill", "element: parent or a sibling" },
    .{ "center-in", "element: parent or a sibling" },
    .{ "margins", "length" },
    .{ "left-margin", "length" },
    .{ "right-margin", "length" },
    .{ "top-margin", "length" },
    .{ "bottom-margin", "length" },
    .{ "horizontal-center-offset", "length" },
    .{ "vertical-center-offset", "length" },
};

const layouts = [_][]const u8{ "HorizontalLayout", "VerticalLayout", "GridLayout", "Row" };

/// Replaces the `anchors.*` bindings among `elem`'s members by the
/// bindings they stand for. Wrong ones are reported and left out: the
/// document is still read, so what it declares stays known (no errors
/// about it in the files that import it).
pub fn resolve(arena: Allocator, diags: *Diagnostics, elem: *ast.Element, place: Place) Allocator.Error!void {
    rewrite(arena, diags, elem, place) catch |err| switch (err) {
        error.ParseError => {
            var kept: std.ArrayList(ast.Member) = .empty;
            for (elem.members) |m| {
                if (m != .binding or !std.mem.startsWith(u8, m.binding.name.name, "anchors.")) try kept.append(arena, m);
            }
            elem.members = kept.items;
        },
        else => |e| return e,
    };
}

fn rewrite(arena: Allocator, diags: *Diagnostics, elem: *ast.Element, place: Place) Error!void {
    var found: ?Anchors = null;
    var kept: std.ArrayList(ast.Member) = .empty;
    for (elem.members) |m| {
        if (m != .binding or !std.mem.startsWith(u8, m.binding.name.name, "anchors.")) {
            try kept.append(arena, m);
            continue;
        }
        const b = m.binding;
        if (found == null) found = .{ .span = b.name.span };
        try read(diags, &found.?, b, elem.id, place);
    }
    const a = found orelse return;
    switch (place) {
        .root => return fail(diags, a.span, "a component's root element has nothing to anchor to", .{}),
        .child => |c| for (layouts) |l| if (std.mem.eql(u8, c.parent_type, l))
            return fail(diags, a.span, "anchors don't work in a {s}: it places its children itself", .{l}),
    }

    var g: Gen = .{ .arena = arena, .span = a.span };
    const e = a.edges;
    inline for (.{ false, true }) |vertical| {
        const o: usize = if (vertical) 3 else 0;
        const pos = if (vertical) "y" else "x";
        const size = if (vertical) "height" else "width";
        const start = e[o];
        const end = e[o + 1];
        const center = e[o + 2];
        const start_margin = a.margins[if (vertical) 2 else 0] orelse a.margins[4];
        const end_margin = a.margins[if (vertical) 3 else 1] orelse a.margins[4];
        if (center != null and (start != null or end != null))
            return fail(diags, center.?.span, "anchors.{s}-center can't go with anchors.{s} or anchors.{s}", .{
                if (vertical) "vertical" else "horizontal",
                if (vertical) "top" else "left",
                if (vertical) "bottom" else "right",
            });
        var at: ?*ast.Expr = null;
        var length: ?*ast.Expr = null;
        if (start) |s| {
            at = try g.plus(try g.edge(s), start_margin);
            if (end) |t| length = try g.minus(try g.minus(try g.edge(t), end_margin), try g.own(pos));
        } else if (end) |t| {
            at = try g.minus(try g.minus(try g.edge(t), end_margin), try g.own(size));
        } else if (center) |c| {
            at = try g.minus(try g.plus(try g.edge(c), a.offsets[@intFromBool(vertical)]), try g.half(try g.own(size)));
        }
        // Held by one side or its center, an element with no size of its
        // own takes its natural one (a text's), as in QML, not its
        // parent's.
        if (at != null and length == null and !hasBinding(elem, size))
            length = try g.own(if (vertical) "preferred-height" else "preferred-width");
        if (at) |value| {
            try check(diags, elem, pos);
            try kept.append(arena, .{ .binding = .{ .name = .{ .name = pos, .span = a.span }, .value = value } });
        }
        if (length) |value| {
            try check(diags, elem, size);
            try kept.append(arena, .{ .binding = .{ .name = .{ .name = size, .span = a.span }, .value = value } });
        }
    }
    elem.members = kept.items;
}

/// Records one `anchors.name: value;`.
fn read(diags: *Diagnostics, a: *Anchors, b: ast.Binding, own_id: ?ast.Ident, place: Place) Error!void {
    const name = b.name.name["anchors.".len..];
    if (Edge.named(name)) |edge| {
        const v = b.value;
        if (v.kind != .member or v.kind.member.object.kind != .ident)
            return fail(diags, v.span, "expected an edge, like parent.{s} or other.{s}", .{ name, name });
        const to = Edge.named(v.kind.member.name.name) orelse
            return fail(diags, v.kind.member.name.span, "'{s}' is not an edge: left, right, horizontal-center, top, bottom or vertical-center", .{v.kind.member.name.name});
        if (to.vertical() != edge.vertical())
            return fail(diags, v.span, "anchors.{s} needs a {s} edge", .{ name, if (edge.vertical()) "top, bottom or vertical-center" else "left, right or horizontal-center" });
        const object = v.kind.member.object.kind.ident;
        try checkTarget(diags, object, v.span, own_id, place);
        a.edges[@intFromEnum(edge)] = .{ .object = object, .edge = to, .span = v.span };
        return;
    }
    const fill = std.mem.eql(u8, name, "fill");
    if (fill or std.mem.eql(u8, name, "center-in")) {
        if (b.value.kind != .ident) return fail(diags, b.value.span, "expected an element: parent or a sibling's id", .{});
        const object = b.value.kind.ident;
        try checkTarget(diags, object, b.value.span, own_id, place);
        const edges: []const Edge = if (fill) &.{ .left, .right, .top, .bottom } else &.{ .horizontal_center, .vertical_center };
        for (edges) |edge| {
            if (a.edges[@intFromEnum(edge)] == null) a.edges[@intFromEnum(edge)] = .{ .object = object, .edge = edge, .span = b.value.span };
        }
        return;
    }
    const lengths = .{
        .{ "left-margin", &a.margins[0] },            .{ "right-margin", &a.margins[1] },
        .{ "top-margin", &a.margins[2] },             .{ "bottom-margin", &a.margins[3] },
        .{ "margins", &a.margins[4] },                .{ "horizontal-center-offset", &a.offsets[0] },
        .{ "vertical-center-offset", &a.offsets[1] },
    };
    inline for (lengths) |l| if (std.mem.eql(u8, name, l[0])) {
        l[1].* = b.value;
        return;
    };
    return fail(diags, b.name.span, "unknown anchor 'anchors.{s}'", .{name});
}

fn checkTarget(diags: *Diagnostics, object: []const u8, span: Span, own_id: ?ast.Ident, place: Place) Error!void {
    if (std.mem.eql(u8, object, "parent")) return;
    if (own_id) |id| if (std.mem.eql(u8, id.name, object))
        return fail(diags, span, "an element can't be anchored to itself", .{});
    if (place == .child) for (place.child.siblings) |s| if (std.mem.eql(u8, s, object)) return;
    return fail(diags, span, "can only anchor to the parent or a sibling, and '{s}' is neither", .{object});
}

fn hasBinding(elem: *const ast.Element, name: []const u8) bool {
    for (elem.members) |m| if (m == .binding and std.mem.eql(u8, m.binding.name.name, name)) return true;
    return false;
}

/// Anchors and an explicit binding can't both set a property.
fn check(diags: *Diagnostics, elem: *const ast.Element, name: []const u8) Error!void {
    for (elem.members) |m| if (m == .binding and std.mem.eql(u8, m.binding.name.name, name))
        return fail(diags, m.binding.name.span, "'{s}' is set by the element's anchors", .{name});
}

fn fail(diags: *Diagnostics, span: Span, comptime fmt: []const u8, args: anytype) Error {
    try diags.add(span, fmt, args);
    return error.ParseError;
}

/// Builds the expressions, all pointing at the anchors in the source.
const Gen = struct {
    arena: Allocator,
    span: Span,

    fn expr(g: *Gen, kind: ast.Expr.Kind) Allocator.Error!*ast.Expr {
        const e = try g.arena.create(ast.Expr);
        e.* = .{ .kind = kind, .span = g.span };
        return e;
    }

    fn member(g: *Gen, object: []const u8, name: []const u8) Allocator.Error!*ast.Expr {
        return g.expr(.{ .member = .{ .object = try g.expr(.{ .ident = object }), .name = .{ .name = name, .span = g.span } } });
    }

    fn own(g: *Gen, name: []const u8) Allocator.Error!*ast.Expr {
        return g.member("self", name);
    }

    fn plus(g: *Gen, a: *ast.Expr, b: ?*ast.Expr) Allocator.Error!*ast.Expr {
        return g.expr(.{ .binary = .{ .op = .plus, .lhs = a, .rhs = b orelse return a } });
    }

    fn minus(g: *Gen, a: *ast.Expr, b: ?*ast.Expr) Allocator.Error!*ast.Expr {
        return g.expr(.{ .binary = .{ .op = .minus, .lhs = a, .rhs = b orelse return a } });
    }

    fn half(g: *Gen, a: *ast.Expr) Allocator.Error!*ast.Expr {
        const two = try g.expr(.{ .number = .{ .value = 2, .is_int = true, .unit = "" } });
        return g.expr(.{ .binary = .{ .op = .slash, .lhs = a, .rhs = two } });
    }

    /// The edge, in the coordinates of the anchored element's parent.
    fn edge(g: *Gen, t: Target) Allocator.Error!*ast.Expr {
        const size = if (t.edge.vertical()) "height" else "width";
        if (std.mem.eql(u8, t.object, "parent")) return switch (t.edge) {
            .left, .top => g.expr(.{ .number = .{ .value = 0, .is_int = true, .unit = "px" } }),
            .right, .bottom => g.member("parent", size),
            .horizontal_center, .vertical_center => g.half(try g.member("parent", size)),
        };
        const start = try g.member(t.object, if (t.edge.vertical()) "y" else "x");
        return switch (t.edge) {
            .left, .top => start,
            .right, .bottom => g.plus(start, try g.member(t.object, size)),
            .horizontal_center, .vertical_center => g.plus(start, try g.half(try g.member(t.object, size))),
        };
    }
};
