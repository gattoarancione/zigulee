// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! A small XML reader, enough for SCXML documents (`zgec scxml`): elements,
//! attributes, text (entities and CDATA decoded), comments, processing
//! instructions and a DOCTYPE skipped. Names lose their namespace prefix.
//! Everything lives in the arena given.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Node = struct {
    /// Without its namespace prefix.
    name: []const u8,
    attrs: []Attr = &.{},
    children: []*Node = &.{},
    /// The text directly inside it, joined.
    text: []const u8 = "",
    /// Where it starts (1-based).
    line: u32,

    pub fn attr(n: *const Node, name: []const u8) ?[]const u8 {
        for (n.attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }
};

pub const Error = error{ InvalidXml, OutOfMemory };

/// Where parsing failed, for the message.
pub const Failure = struct { line: u32 = 0, message: []const u8 = "" };

/// The document's root element.
pub fn parse(arena: Allocator, source: []const u8, failure: *Failure) Error!*Node {
    var p: Parser = .{ .arena = arena, .src = source, .failure = failure };
    p.skipProlog() catch |err| return p.fail(err);
    if (p.pos >= p.src.len or p.src[p.pos] != '<') return p.failWith("expected the root element");
    const root = try p.element();
    p.skipMisc() catch |err| return p.fail(err);
    if (p.pos < p.src.len) return p.failWith("text after the root element");
    return root;
}

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,
    failure: *Failure,

    fn line(p: *const Parser) u32 {
        return @intCast(1 + std.mem.count(u8, p.src[0..@min(p.pos, p.src.len)], "\n"));
    }

    fn failWith(p: *Parser, message: []const u8) Error {
        p.failure.* = .{ .line = p.line(), .message = message };
        return error.InvalidXml;
    }

    fn fail(p: *Parser, err: Error) Error {
        if (err == error.InvalidXml and p.failure.message.len == 0) return p.failWith("malformed XML");
        return err;
    }

    fn startsWith(p: *const Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.src[p.pos..], s);
    }

    fn skipSpace(p: *Parser) void {
        while (p.pos < p.src.len and std.ascii.isWhitespace(p.src[p.pos])) p.pos += 1;
    }

    /// Past `end` (searched from here).
    fn skipPast(p: *Parser, end: []const u8) Error!void {
        const at = std.mem.indexOfPos(u8, p.src, p.pos, end) orelse return p.failWith("unclosed comment, declaration or CDATA");
        p.pos = at + end.len;
    }

    /// Comments, processing instructions, a DOCTYPE and space.
    fn skipMisc(p: *Parser) Error!void {
        while (true) {
            p.skipSpace();
            if (p.startsWith("<!--")) {
                try p.skipPast("-->");
            } else if (p.startsWith("<?")) {
                try p.skipPast("?>");
            } else if (p.startsWith("<!DOCTYPE")) {
                // Up to its `>`, past an internal subset in brackets.
                var depth: usize = 0;
                while (p.pos < p.src.len) : (p.pos += 1) switch (p.src[p.pos]) {
                    '[' => depth += 1,
                    ']' => depth -|= 1,
                    '>' => if (depth == 0) break,
                    else => {},
                };
                p.pos += 1;
            } else return;
        }
    }

    fn skipProlog(p: *Parser) Error!void {
        // A byte order mark.
        if (p.startsWith("\xEF\xBB\xBF")) p.pos += 3;
        try p.skipMisc();
    }

    fn name(p: *Parser) Error![]const u8 {
        const start = p.pos;
        while (p.pos < p.src.len) : (p.pos += 1) {
            const c = p.src[p.pos];
            if (std.ascii.isWhitespace(c) or c == '=' or c == '>' or c == '/' or c == '<') break;
        }
        if (p.pos == start) return p.failWith("expected a name");
        return p.src[start..p.pos];
    }

    fn local(full: []const u8) []const u8 {
        return if (std.mem.lastIndexOfScalar(u8, full, ':')) |i| full[i + 1 ..] else full;
    }

    fn element(p: *Parser) Error!*Node {
        const node = try p.arena.create(Node);
        node.* = .{ .name = undefined, .line = p.line() };
        p.pos += 1; // `<`
        const full = try p.name();
        node.name = local(full);
        var attrs: std.ArrayList(Attr) = .empty;
        while (true) {
            p.skipSpace();
            if (p.pos >= p.src.len) return p.failWith("unclosed tag");
            if (p.startsWith("/>")) {
                p.pos += 2;
                node.attrs = attrs.items;
                return node;
            }
            if (p.src[p.pos] == '>') {
                p.pos += 1;
                break;
            }
            const attr_name = local(try p.name());
            p.skipSpace();
            if (p.pos >= p.src.len or p.src[p.pos] != '=') return p.failWith("expected '=' after an attribute name");
            p.pos += 1;
            p.skipSpace();
            if (p.pos >= p.src.len or (p.src[p.pos] != '"' and p.src[p.pos] != '\'')) return p.failWith("expected a quoted attribute value");
            const quote = p.src[p.pos];
            p.pos += 1;
            const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, quote) orelse return p.failWith("unclosed attribute value");
            const value = try p.decode(p.src[p.pos..end]);
            p.pos = end + 1;
            try attrs.append(p.arena, .{ .name = attr_name, .value = value });
        }
        node.attrs = attrs.items;
        var children: std.ArrayList(*Node) = .empty;
        var text: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.pos >= p.src.len) return p.failWith("unclosed element");
            if (p.startsWith("</")) {
                p.pos += 2;
                const close = local(try p.name());
                if (!std.mem.eql(u8, close, node.name)) return p.failWith("a closing tag does not match its opening tag");
                p.skipSpace();
                if (p.pos >= p.src.len or p.src[p.pos] != '>') return p.failWith("expected '>'");
                p.pos += 1;
                break;
            }
            if (p.startsWith("<!--")) {
                try p.skipPast("-->");
            } else if (p.startsWith("<![CDATA[")) {
                const start = p.pos + "<![CDATA[".len;
                try p.skipPast("]]>");
                try text.appendSlice(p.arena, p.src[start .. p.pos - 3]);
            } else if (p.startsWith("<?")) {
                try p.skipPast("?>");
            } else if (p.src[p.pos] == '<') {
                try children.append(p.arena, try p.element());
            } else {
                const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, '<') orelse p.src.len;
                try text.appendSlice(p.arena, try p.decode(p.src[p.pos..end]));
                p.pos = end;
            }
        }
        node.children = children.items;
        node.text = text.items;
        return node;
    }

    /// Entities replaced: the five predefined ones and character
    /// references.
    fn decode(p: *Parser, raw: []const u8) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] != '&') {
                try out.append(p.arena, raw[i]);
                i += 1;
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse return p.failWith("an entity without ';'");
            const ent = raw[i + 1 .. end];
            const named = [_]struct { []const u8, u8 }{ .{ "lt", '<' }, .{ "gt", '>' }, .{ "amp", '&' }, .{ "quot", '"' }, .{ "apos", '\'' } };
            const ch: ?u8 = for (named) |n| {
                if (std.mem.eql(u8, ent, n[0])) break n[1];
            } else null;
            if (ch) |c| {
                try out.append(p.arena, c);
            } else if (ent.len > 1 and ent[0] == '#') {
                const cp = (if (ent[1] == 'x' or ent[1] == 'X') std.fmt.parseInt(u21, ent[2..], 16) else std.fmt.parseInt(u21, ent[1..], 10)) catch return p.failWith("a bad character reference");
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return p.failWith("a bad character reference");
                try out.appendSlice(p.arena, buf[0..n]);
            } else return p.failWith("an unknown entity");
            i = end + 1;
        }
        return out.items;
    }
};

test "XML: elements, attributes, text, entities, CDATA, comments; namespaces dropped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var failure: Failure = .{};
    const doc = try parse(arena.allocator(),
        \\<?xml version="1.0"?>
        \\<!-- a machine -->
        \\<!DOCTYPE scxml [ <!ENTITY x "y"> ]>
        \\<scxml xmlns="http://www.w3.org/2005/07/scxml" version='1.0' initial="a">
        \\  <state id="a"><transition event="go" cond="x &lt; 3 &amp;&amp; y" target="b"/></state>
        \\  <conf:state id="b">text &#65;&#x42; <![CDATA[<raw>]]></conf:state>
        \\</scxml>
    , &failure);
    try std.testing.expectEqualStrings("scxml", doc.name);
    try std.testing.expectEqualStrings("a", doc.attr("initial").?);
    try std.testing.expectEqual(@as(usize, 2), doc.children.len);
    try std.testing.expectEqualStrings("x < 3 && y", doc.children[0].children[0].attr("cond").?);
    try std.testing.expectEqualStrings("state", doc.children[1].name);
    try std.testing.expectEqualStrings("text AB <raw>", doc.children[1].text);
    try std.testing.expectEqual(@as(u32, 6), doc.children[1].line);

    try std.testing.expectError(error.InvalidXml, parse(arena.allocator(), "<a><b></a>", &failure));
    try std.testing.expectEqualStrings("a closing tag does not match its opening tag", failure.message);
    try std.testing.expectError(error.InvalidXml, parse(arena.allocator(), "<a x=1/>", &failure));
}
