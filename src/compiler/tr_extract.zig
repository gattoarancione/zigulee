// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! `zgec tr`: collects the `@tr(...)` messages of `.zge` files into a
//! gettext template (`.pot`), from which translators make `.po` files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Parser = @import("parser.zig").Parser;
const Diagnostics = @import("diagnostics.zig").Diagnostics;
const std_widgets = @import("std_widgets.zig");

pub const File = struct { name: []const u8, source: []const u8 };

const Message = struct {
    tr: ast.Tr,
    /// `file:line` of each use.
    refs: std.ArrayList([]const u8) = .empty,
};

pub const Result = union(enum) {
    pot: []const u8,
    /// Parse errors, rendered.
    errors: []const u8,
};

/// The template for the messages of `files`, in the order they first
/// appear; a message used several times lists every place. The messages of
/// the standard widgets the files import (the DatePicker's month names...)
/// come last.
pub fn extract(arena: Allocator, files: []const File) Allocator.Error!Result {
    var messages: std.ArrayList(Message) = .empty;
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    var all: std.ArrayList(File) = .empty;
    try all.appendSlice(arena, files);
    // Standard widget files to read, by path (`@std/datepicker.zge`).
    var std_files: std.StringArrayHashMapUnmanaged(void) = .empty;
    var i: usize = 0;
    while (i < all.items.len) : (i += 1) {
        const f = all.items[i];
        var diags: Diagnostics = .{ .arena = arena };
        _ = try diags.addFile(f.name, f.source);
        var parser: Parser = .init(arena, f.source, &diags);
        const doc = parser.parseDocument() catch |err| switch (err) {
            error.ParseError => {
                var out: std.Io.Writer.Allocating = .init(arena);
                diags.render(&out.writer) catch return error.OutOfMemory;
                return .{ .errors = out.written() };
            },
            else => |e| return e,
        };
        var c: Collector = .{ .arena = arena, .file = f, .messages = &messages, .index = &index };
        for (doc.components) |comp| try c.element(&comp.root);
        const in_std = i >= files.len;
        for (doc.imports) |imp| {
            if (std.mem.eql(u8, imp.path, std_widgets.import_name)) {
                // The files that define the imported widgets.
                for (imp.names) |n| if (try stdFileOf(arena, n.name)) |path| try std_files.put(arena, path, {});
            } else if (in_std) {
                // Files the widget uses (ScrollView for ListView...).
                try std_files.put(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ std_widgets.dir, imp.path }), {});
            }
        }
        // After the user's files (and as they appear): the widgets' files.
        if (i == all.items.len - 1) for (std_files.keys()) |path| {
            for (all.items) |seen| {
                if (std.mem.eql(u8, seen.name, path)) break;
            } else {
                const source = std_widgets.read(std_widgets.default_style, path) orelse continue;
                try all.append(arena, .{ .name = path, .source = source });
            }
        };
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll(
        \\# Messages to translate, extracted by `zgec tr`.
        \\msgid ""
        \\msgstr ""
        \\"Content-Type: text/plain; charset=UTF-8\n"
        \\
    ) catch return error.OutOfMemory;
    for (messages.items) |m| write(w, m) catch return error.OutOfMemory;
    return .{ .pot = out.written() };
}

/// The standard widget file that defines `name`, from the re-exports of
/// `std-widgets.zge`.
fn stdFileOf(arena: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
    const index_source = std_widgets.read(std_widgets.default_style, std_widgets.root) orelse return null;
    var diags: Diagnostics = .{ .arena = arena };
    _ = try diags.addFile(std_widgets.root, index_source);
    var parser: Parser = .init(arena, index_source, &diags);
    const doc = parser.parseDocument() catch return null;
    for (doc.imports) |imp| for (imp.names) |n| {
        if (std.mem.eql(u8, n.name, name)) return try std.fmt.allocPrint(arena, "{s}/{s}", .{ std_widgets.dir, imp.path });
    };
    return null;
}

fn write(w: *std.Io.Writer, m: Message) std.Io.Writer.Error!void {
    try w.writeAll("\n#:");
    for (m.refs.items) |r| try w.print(" {s}", .{r});
    try w.writeAll("\n");
    if (m.tr.context.len > 0) try w.print("msgctxt {f}\n", .{quoted(m.tr.context)});
    try w.print("msgid {f}\n", .{quoted(m.tr.text)});
    if (m.tr.plural) |p| {
        try w.print("msgid_plural {f}\nmsgstr[0] \"\"\nmsgstr[1] \"\"\n", .{quoted(p)});
    } else try w.writeAll("msgstr \"\"\n");
}

fn quoted(s: []const u8) std.fmt.Alt([]const u8, formatQuoted) {
    return .{ .data = s };
}

fn formatQuoted(s: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

const Collector = struct {
    arena: Allocator,
    file: File,
    messages: *std.ArrayList(Message),
    index: *std.StringHashMapUnmanaged(usize),

    const Error = Allocator.Error;

    fn element(c: *Collector, e: *const ast.Element) Error!void {
        for (e.members) |m| switch (m) {
            .property => |p| {
                if (p.init) |x| try c.expr(x);
                if (p.alias) |x| try c.expr(x);
            },
            .binding => |b| try c.expr(b.value),
            .two_way => |t| try c.expr(t.target),
            .handler => |h| try c.stmts(h.body),
            .function => |f| try c.stmts(f.body),
            .changed => |ch| try c.stmts(ch.body),
            .child => |child| try c.element(child),
            .repeated => |r| {
                try c.expr(r.model);
                try c.element(r.element);
            },
            .conditional => |cond| {
                try c.expr(cond.condition);
                try c.element(cond.element);
            },
            .states => |st| for (st.states) |s| {
                try c.expr(s.condition);
                for (s.assignments) |a| try c.expr(a.value);
            },
            .machine_state => |*st| try c.machineState(st),
            .animate, .callback, .children_placeholder, .event, .initial => {},
        };
    }

    fn machineState(c: *Collector, st: *const ast.MachineState) Error!void {
        if (st.entered) |b| try c.stmts(b);
        if (st.exited) |b| try c.stmts(b);
        for (st.transitions) |t| {
            if (t.trigger == .after) try c.expr(t.trigger.after);
            if (t.guard) |g| try c.expr(g);
            try c.stmts(t.actions);
        }
        for (st.children) |*child| try c.machineState(child);
    }

    fn stmts(c: *Collector, list: []const ast.Stmt) Error!void {
        for (list) |s| switch (s.kind) {
            .expr => |e| try c.expr(e),
            .assign => |a| try c.expr(a.value),
            .@"if" => |i| {
                try c.expr(i.cond);
                try c.stmts(i.then);
                try c.stmts(i.otherwise);
            },
            .@"return" => |r| if (r) |e| try c.expr(e),
            .let => |l| try c.expr(l.value),
            .@"while" => |w| {
                try c.expr(w.cond);
                try c.stmts(w.body);
            },
            .@"for" => |f| {
                try c.expr(f.over);
                try c.stmts(f.body);
            },
            .@"break", .@"continue" => {},
        };
    }

    fn expr(c: *Collector, e: *const ast.Expr) Error!void {
        switch (e.kind) {
            .number, .color, .ident, .image_url, .audio_url, .video_url, .model_url => {},
            .string => |parts| for (parts) |p| switch (p) {
                .expr => |x| try c.expr(x),
                .literal => {},
            },
            .member => |m| try c.expr(m.object),
            .call => |call| {
                try c.expr(call.callee);
                for (call.args) |a| try c.expr(a);
            },
            .unary => |u| try c.expr(u.operand),
            .binary => |b| {
                try c.expr(b.lhs);
                try c.expr(b.rhs);
            },
            .ternary => |t| {
                try c.expr(t.cond);
                try c.expr(t.then);
                try c.expr(t.otherwise);
            },
            .array => |items| for (items) |x| try c.expr(x),
            .index => |ix| {
                try c.expr(ix.object);
                try c.expr(ix.index);
            },
            .struct_literal => |fields| for (fields) |f| try c.expr(f.value),
            .lambda => |l| try c.expr(l.body),
            .gradient => |gr| for (gr.stops) |s| {
                try c.expr(s.color);
                if (s.position) |x| try c.expr(x);
            },
            .tr => |t| {
                try c.add(t, e.span.start);
                if (t.count) |x| try c.expr(x);
                for (t.args) |x| try c.expr(x);
            },
        }
    }

    fn add(c: *Collector, t: ast.Tr, offset: u32) Error!void {
        const line = std.mem.count(u8, c.file.source[0..offset], "\n") + 1;
        const ref = try std.fmt.allocPrint(c.arena, "{s}:{d}", .{ c.file.name, line });
        const key = try std.fmt.allocPrint(c.arena, "{s}\x04{s}", .{ t.context, t.text });
        const gop = try c.index.getOrPut(c.arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = c.messages.items.len;
            try c.messages.append(c.arena, .{ .tr = t });
        }
        try c.messages.items[gop.value_ptr.*].refs.append(c.arena, ref);
    }
};

test "the standard widgets' messages come with them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try extract(arena.allocator(), &.{.{ .name = "app.zge", .source =
        \\import { DatePicker } from "std-widgets.zge";
        \\export component App { DatePicker { } }
    }});
    try std.testing.expect(std.mem.indexOf(u8, result.pot, "msgctxt \"DatePicker\"\nmsgid \"May\"") != null);

    // Only those of the widgets used.
    const none = try extract(arena.allocator(), &.{.{ .name = "app.zge", .source =
        \\import { Button } from "std-widgets.zge";
        \\export component App { Button { text: @tr("Go"); } }
    }});
    try std.testing.expect(std.mem.indexOf(u8, none.pot, "DatePicker") == null);
    try std.testing.expect(std.mem.indexOf(u8, none.pot, "msgid \"Go\"") != null);
}

test "messages in order, with contexts, plurals and every place they are used" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try extract(arena.allocator(), &.{
        .{ .name = "a.zge", .source =
        \\export component A {
        \\    var <int> n;
        \\    var <string> s: @tr("Hello, {}!", @tr("world"));
        \\    for i in n : Text { text: @tr("{n} file" | "{n} files" % n); }
        \\    TouchArea { clicked => { s = @tr("menu" => "Open"); } }
        \\}
        },
        .{ .name = "b.zge", .source =
        \\component B { var <string> t: @tr("Hello, {}!", "\"you\""); }
        },
    });
    try std.testing.expectEqualStrings(
        \\# Messages to translate, extracted by `zgec tr`.
        \\msgid ""
        \\msgstr ""
        \\"Content-Type: text/plain; charset=UTF-8\n"
        \\
        \\#: a.zge:3 b.zge:1
        \\msgid "Hello, {}!"
        \\msgstr ""
        \\
        \\#: a.zge:3
        \\msgid "world"
        \\msgstr ""
        \\
        \\#: a.zge:4
        \\msgid "{n} file"
        \\msgid_plural "{n} files"
        \\msgstr[0] ""
        \\msgstr[1] ""
        \\
        \\#: a.zge:5
        \\msgctxt "menu"
        \\msgid "Open"
        \\msgstr ""
        \\
    , result.pot);
}
