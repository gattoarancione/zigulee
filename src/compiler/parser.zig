// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Recursive-descent parser for `.zge` documents. Stops at the first
//! syntax error, which is recorded in the diagnostics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("lexer.zig");
const Tag = lexer.Tag;
const Token = lexer.Token;
const ast = @import("ast.zig");
const Span = ast.Span;
const Diagnostics = @import("diagnostics.zig").Diagnostics;
const anchors = @import("anchors.zig");

pub const Error = error{ParseError} || Allocator.Error;

pub const Parser = struct {
    arena: Allocator,
    source: []const u8,
    diags: *Diagnostics,
    lexer: lexer.Lexer,
    tok: Token,

    pub fn init(arena: Allocator, source: []const u8, diags: *Diagnostics) Parser {
        return initRange(arena, source, diags, 0, @intCast(source.len));
    }

    fn initRange(arena: Allocator, source: []const u8, diags: *Diagnostics, start: u32, end: u32) Parser {
        var l: lexer.Lexer = .initRange(source, start, end);
        const first = l.next();
        return .{ .arena = arena, .source = source, .diags = diags, .lexer = l, .tok = first };
    }

    // ---- Token helpers ----

    fn advance(p: *Parser) Token {
        const t = p.tok;
        p.tok = p.lexer.next();
        return t;
    }

    fn peekNext(p: *Parser) Token {
        var copy = p.lexer;
        return copy.next();
    }

    /// `nine-slice(a)`, `nine-slice(vertical horizontal)` or
    /// `nine-slice(top right bottom left)`: whole image pixels, as CSS's
    /// `border-image-slice`.
    fn parseNineSlice(p: *Parser) Error![4]u32 {
        const name = try p.ident();
        if (!std.mem.eql(u8, name.name, "nine-slice")) return p.fail(name.span, "expected 'nine-slice', found '{s}'", .{name.name});
        const open = try p.expect(.l_paren);
        var v: [4]u32 = undefined;
        var n: usize = 0;
        while (p.tok.tag == .number) {
            const t = p.advance();
            if (n == 4) return p.fail(spanOf(t), "nine-slice takes 1, 2 or 4 numbers", .{});
            v[n] = std.fmt.parseInt(u32, p.text(t), 10) catch return p.fail(spanOf(t), "expected a whole number of pixels, found '{s}'", .{p.text(t)});
            n += 1;
        }
        const close = try p.expect(.r_paren);
        return switch (n) {
            1 => .{ v[0], v[0], v[0], v[0] },
            2 => .{ v[0], v[1], v[0], v[1] },
            4 => v,
            else => p.fail(.{ .start = open.start, .end = close.end }, "nine-slice takes 1, 2 or 4 numbers", .{}),
        };
    }

    fn text(p: *const Parser, t: Token) []const u8 {
        return t.text(p.source);
    }

    fn isWord(p: *const Parser, word: []const u8) bool {
        return p.tok.tag == .identifier and std.mem.eql(u8, p.text(p.tok), word);
    }

    fn fail(p: *Parser, span: Span, comptime fmt: []const u8, args: anytype) Error {
        try p.diags.add(span, fmt, args);
        return error.ParseError;
    }

    fn spanOf(t: Token) Span {
        return .{ .start = t.start, .end = t.end };
    }

    fn expect(p: *Parser, tag: Tag) Error!Token {
        if (p.tok.tag != tag) return p.fail(spanOf(p.tok), "expected {s}, found {s}", .{ tag.describe(), p.describeCurrent() });
        return p.advance();
    }

    fn describeCurrent(p: *const Parser) []const u8 {
        if (p.tok.tag == .identifier) return p.text(p.tok);
        return p.tok.tag.describe();
    }

    fn ident(p: *Parser) Error!ast.Ident {
        const t = try p.expect(.identifier);
        return .{ .name = p.text(t), .span = spanOf(t) };
    }

    fn expectWord(p: *Parser, word: []const u8) Error!Token {
        if (!p.isWord(word)) return p.fail(spanOf(p.tok), "expected '{s}', found {s}", .{ word, p.describeCurrent() });
        return p.advance();
    }

    fn create(p: *Parser, value: anytype) Allocator.Error!*@TypeOf(value) {
        const ptr = try p.arena.create(@TypeOf(value));
        ptr.* = value;
        return ptr;
    }

    // ---- Document structure ----

    pub fn parseDocument(p: *Parser) Error!ast.Document {
        var components: std.ArrayList(ast.Component) = .empty;
        var structs: std.ArrayList(ast.StructDecl) = .empty;
        var enums: std.ArrayList(ast.EnumDecl) = .empty;
        var imports: std.ArrayList(ast.Import) = .empty;
        while (p.tok.tag != .eof) {
            if (p.isWord("import")) {
                try imports.append(p.arena, try p.parseImport());
                continue;
            }
            if (p.isWord("export") and p.peekNext().tag == .l_brace) {
                try imports.append(p.arena, try p.parseImport());
                continue;
            }
            // `export` is accepted (and ignored) on types too.
            var lookahead = p.tok;
            if (p.isWord("export")) lookahead = p.peekNext();
            const word = if (lookahead.tag == .identifier) p.text(lookahead) else "";
            if (std.mem.eql(u8, word, "struct")) {
                if (p.isWord("export")) _ = p.advance();
                try structs.append(p.arena, try p.parseStructDecl());
            } else if (std.mem.eql(u8, word, "enum")) {
                if (p.isWord("export")) _ = p.advance();
                try enums.append(p.arena, try p.parseEnumDecl());
            } else {
                try components.append(p.arena, try p.parseComponent());
            }
        }
        return .{ .components = components.items, .structs = structs.items, .enums = enums.items, .imports = imports.items };
    }

    /// `import { A, B } from "path";`, or `export { A, B } from "path";`
    /// to re-export them.
    fn parseImport(p: *Parser) Error!ast.Import {
        const reexport = p.isWord("export");
        _ = p.advance();
        _ = try p.expect(.l_brace);
        var names: std.ArrayList(ast.Ident) = .empty;
        while (p.tok.tag != .r_brace) {
            try names.append(p.arena, try p.ident());
            if (p.tok.tag != .comma) break;
            _ = p.advance();
        }
        _ = try p.expect(.r_brace);
        _ = try p.expectWord("from");
        const path_tok = try p.expect(.string);
        const parts = try p.stringParts(path_tok);
        if (parts.len != 1 or parts[0] != .literal) return p.fail(spanOf(path_tok), "the import path must be a plain string", .{});
        _ = try p.expect(.semicolon);
        return .{ .names = names.items, .path = parts[0].literal, .path_span = spanOf(path_tok), .reexport = reexport };
    }

    fn parseStructDecl(p: *Parser) Error!ast.StructDecl {
        _ = try p.expectWord("struct");
        const name = try p.ident();
        _ = try p.expect(.l_brace);
        var fields: std.ArrayList(ast.StructDecl.FieldDecl) = .empty;
        while (p.tok.tag != .r_brace) {
            const field = try p.ident();
            _ = try p.expect(.colon);
            try fields.append(p.arena, .{ .name = field, .type_name = try p.typeRef() });
            if (p.tok.tag != .comma) break;
            _ = p.advance();
        }
        _ = try p.expect(.r_brace);
        return .{ .name = name, .fields = fields.items };
    }

    fn parseEnumDecl(p: *Parser) Error!ast.EnumDecl {
        _ = try p.expectWord("enum");
        const name = try p.ident();
        _ = try p.expect(.l_brace);
        var values: std.ArrayList(ast.Ident) = .empty;
        while (p.tok.tag != .r_brace) {
            try values.append(p.arena, try p.ident());
            if (p.tok.tag != .comma) break;
            _ = p.advance();
        }
        _ = try p.expect(.r_brace);
        return .{ .name = name, .values = values.items };
    }

    fn parseComponent(p: *Parser) Error!ast.Component {
        const start = p.tok.start;
        const exported = p.isWord("export");
        if (exported) _ = p.advance();
        if (p.isWord("global")) {
            _ = p.advance();
            const name = try p.ident();
            var body = try p.parseElementBody(null, .{ .name = "Empty", .span = name.span });
            try anchors.resolve(p.arena, p.diags, &body, .root);
            return .{ .name = name, .exported = exported, .is_global = true, .root = body, .span = .{ .start = start, .end = body.span.end } };
        }
        if (!p.isWord("component")) return p.fail(spanOf(p.tok), "expected 'component', 'global', 'struct', 'enum' or 'import', found {s}", .{p.describeCurrent()});
        _ = p.advance();
        const name = try p.ident();
        var base: ast.Ident = .{ .name = "Empty", .span = name.span };
        if (p.isWord("inherits")) {
            _ = p.advance();
            base = try p.ident();
        }
        var body = try p.parseElementBody(null, base);
        try anchors.resolve(p.arena, p.diags, &body, .root);
        return .{ .name = name, .exported = exported, .root = body, .span = .{ .start = start, .end = body.span.end } };
    }

    /// `{ members }` after an element's type name.
    fn parseElementBody(p: *Parser, id: ?ast.Ident, type_name: ast.Ident) Error!ast.Element {
        const open = try p.expect(.l_brace);
        var members: std.ArrayList(ast.Member) = .empty;
        while (p.tok.tag != .r_brace) {
            if (p.tok.tag == .eof) return p.fail(spanOf(open), "unclosed '{{'", .{});
            try members.append(p.arena, try p.parseMember());
        }
        const close = p.advance();
        // Anchors need the siblings: rewritten once all are known.
        var ids: std.ArrayList([]const u8) = .empty;
        for (members.items) |m| if (m == .child) if (m.child.id) |i| try ids.append(p.arena, i.name);
        const place: anchors.Place = .{ .child = .{ .parent_type = type_name.name, .siblings = ids.items } };
        for (members.items) |m| switch (m) {
            .child => |c| try anchors.resolve(p.arena, p.diags, c, place),
            .repeated => |r| try anchors.resolve(p.arena, p.diags, r.element, place),
            .conditional => |c| try anchors.resolve(p.arena, p.diags, c.element, place),
            else => {},
        };
        const start = if (id) |i| i.span.start else type_name.span.start;
        return .{ .id = id, .type_name = type_name, .members = members.items, .span = .{ .start = start, .end = close.end } };
    }

    fn parseMember(p: *Parser) Error!ast.Member {
        if (p.tok.tag == .at and p.peekNext().tag == .identifier and std.mem.eql(u8, p.text(p.peekNext()), "children")) {
            const at = p.advance();
            const word = p.advance();
            if (p.tok.tag == .semicolon) _ = p.advance();
            return .{ .children_placeholder = .{ .start = at.start, .end = word.end } };
        }
        if (p.tok.tag != .identifier) return p.fail(spanOf(p.tok), "expected a property, callback or element, found {s}", .{p.describeCurrent()});
        const word = p.text(p.tok);
        const next = p.peekNext();

        // Declarations.
        if (std.mem.eql(u8, word, "var") and (next.tag == .identifier or next.tag == .less)) return .{ .property = try p.parseVarDecl() };
        // The old spelling: what to write instead.
        if (std.mem.eql(u8, word, "property") and next.tag == .less)
            return p.fail(spanOf(p.tok), "properties are declared with `var` now: `var <type> name`", .{});
        inline for (.{ "in", "out", "in-out", "private" }) |v| {
            if (std.mem.eql(u8, word, v) and next.tag == .identifier and std.mem.eql(u8, p.text(next), "property"))
                return p.fail(spanOf(p.tok), "properties are declared with `var` now: `var " ++ (if (std.mem.eql(u8, v, "private")) "" else v ++ " ") ++ "<type> name`", .{});
        }
        if (std.mem.eql(u8, word, "callback") and next.tag == .identifier) return .{ .callback = try p.parseCallbackDecl() };
        if ((std.mem.eql(u8, word, "public") or std.mem.eql(u8, word, "pure")) and next.tag == .identifier) {
            const after = p.text(next);
            if (std.mem.eql(u8, after, "function") or std.mem.eql(u8, after, "pure") or std.mem.eql(u8, after, "public"))
                return .{ .function = try p.parseFunctionDecl() };
        }
        if (std.mem.eql(u8, word, "function") and next.tag == .identifier) return .{ .function = try p.parseFunctionDecl() };
        if (std.mem.eql(u8, word, "for") and (next.tag == .identifier or next.tag == .l_bracket)) return .{ .repeated = try p.parseRepeated() };
        if (std.mem.eql(u8, word, "if") and next.tag != .colon and next.tag != .colon_equal and next.tag != .l_brace)
            return .{ .conditional = try p.parseConditional() };
        if (std.mem.eql(u8, word, "animate") and next.tag == .identifier) return .{ .animate = try p.parseAnimate() };
        if (std.mem.eql(u8, word, "states") and next.tag == .l_bracket) return .{ .states = try p.parseStates() };
        if (std.mem.eql(u8, word, "changed") and next.tag == .identifier) {
            const kw = p.advance();
            const name = try p.ident();
            _ = try p.expect(.fat_arrow);
            const body = try p.parseBlock();
            return .{ .changed = .{ .name = name, .body = body.stmts, .span = .{ .start = kw.start, .end = body.span.end } } };
        }

        var name = try p.ident();
        // `anchors.left: other.right;`
        if (std.mem.eql(u8, name.name, "anchors") and p.tok.tag == .dot) {
            _ = p.advance();
            const which = try p.ident();
            _ = try p.expect(.colon);
            const value = try p.parseExpr();
            _ = try p.expect(.semicolon);
            const full = try std.fmt.allocPrint(p.arena, "anchors.{s}", .{which.name});
            return .{ .binding = .{ .name = .{ .name = full, .span = name.span.join(which.span) }, .value = value } };
        }
        // `other.callback => { }`
        var handler_target: ?ast.Ident = null;
        if (p.tok.tag == .dot) {
            _ = p.advance();
            handler_target = name;
            name = try p.ident();
            if (p.tok.tag != .fat_arrow and p.tok.tag != .l_paren)
                return p.fail(spanOf(p.tok), "expected '=>' after '{s}.{s}': only handlers name another element's member", .{ handler_target.?.name, name.name });
        }
        switch (p.tok.tag) {
            .colon_equal => {
                _ = p.advance();
                const type_name = try p.ident();
                return .{ .child = try p.create(try p.parseElementBody(name, type_name)) };
            },
            .l_brace => return .{ .child = try p.create(try p.parseElementBody(null, name)) },
            .colon => {
                _ = p.advance();
                const value = try p.parseExpr();
                _ = try p.expect(.semicolon);
                return .{ .binding = .{ .name = name, .value = value } };
            },
            .two_way => {
                _ = p.advance();
                const target = try p.parseExpr();
                _ = try p.expect(.semicolon);
                return .{ .two_way = .{ .name = name, .target = target } };
            },
            .fat_arrow, .l_paren => {
                var params: std.ArrayList(ast.Ident) = .empty;
                if (p.tok.tag == .l_paren) {
                    _ = p.advance();
                    while (p.tok.tag != .r_paren) {
                        try params.append(p.arena, try p.ident());
                        if (p.tok.tag != .comma) break;
                        _ = p.advance();
                    }
                    _ = try p.expect(.r_paren);
                }
                _ = try p.expect(.fat_arrow);
                const body = try p.parseBlock();
                const start = if (handler_target) |t| t.span else name.span;
                return .{ .handler = .{ .target = handler_target, .name = name, .params = params.items, .body = body.stmts, .span = start.join(body.span) } };
            },
            else => return p.fail(spanOf(p.tok), "expected ':', ':=', '{{', '<=>' or '=>' after '{s}', found {s}", .{ name.name, p.describeCurrent() }),
        }
    }

    /// `states [ name when condition : { prop: value; animate ... } ... ]`
    fn parseStates(p: *Parser) Error!ast.States {
        const kw = try p.expectWord("states");
        _ = try p.expect(.l_bracket);
        var states: std.ArrayList(ast.States.State) = .empty;
        while (p.tok.tag != .r_bracket) {
            const name = try p.ident();
            _ = try p.expectWord("when");
            const condition = try p.parseExpr();
            _ = try p.expect(.colon);
            _ = try p.expect(.l_brace);
            var assignments: std.ArrayList(ast.States.Assignment) = .empty;
            var animations: std.ArrayList(ast.Animate) = .empty;
            var enter: std.ArrayList(ast.Animate) = .empty;
            var leave: std.ArrayList(ast.Animate) = .empty;
            while (p.tok.tag != .r_brace) {
                if (p.isWord("animate") and p.peekNext().tag == .identifier) {
                    try animations.append(p.arena, try p.parseAnimate());
                    continue;
                }
                if ((p.isWord("in") or p.isWord("out")) and p.peekNext().tag == .l_brace) {
                    const list = if (p.isWord("in")) &enter else &leave;
                    _ = p.advance();
                    _ = p.advance();
                    while (p.tok.tag != .r_brace) try list.append(p.arena, try p.parseAnimate());
                    _ = p.advance();
                    continue;
                }
                const target = try p.parsePostfix();
                _ = try p.expect(.colon);
                const value = try p.parseExpr();
                _ = try p.expect(.semicolon);
                try assignments.append(p.arena, .{ .target = target, .value = value });
            }
            _ = p.advance();
            try states.append(p.arena, .{ .name = name, .condition = condition, .assignments = assignments.items, .animations = animations.items, .enter = enter.items, .leave = leave.items });
        }
        const close = p.advance();
        return .{ .states = states.items, .span = .{ .start = kw.start, .end = close.end } };
    }

    /// `for item[index] in model : Element { ... }`
    fn parseRepeated(p: *Parser) Error!ast.Repeated {
        const kw = try p.expectWord("for");
        var item: ?ast.Ident = null;
        var index: ?ast.Ident = null;
        if (p.tok.tag == .identifier and !p.isWord("in")) item = try p.ident();
        if (p.tok.tag == .l_bracket) {
            _ = p.advance();
            index = try p.ident();
            _ = try p.expect(.r_bracket);
        }
        _ = try p.expectWord("in");
        const model = try p.parseExpr();
        _ = try p.expect(.colon);
        const element = try p.parseSubElement();
        return .{ .item = item, .index = index, .model = model, .element = element, .span = .{ .start = kw.start, .end = element.span.end } };
    }

    /// `if condition : Element { ... }`
    fn parseConditional(p: *Parser) Error!ast.Conditional {
        const kw = try p.expectWord("if");
        const condition = try p.parseExpr();
        _ = try p.expect(.colon);
        const element = try p.parseSubElement();
        return .{ .condition = condition, .element = element, .span = .{ .start = kw.start, .end = element.span.end } };
    }

    /// `Type { ... }` or `id := Type { ... }`.
    fn parseSubElement(p: *Parser) Error!*ast.Element {
        const first = try p.ident();
        if (p.tok.tag == .colon_equal) {
            _ = p.advance();
            const type_name = try p.ident();
            return p.create(try p.parseElementBody(first, type_name));
        }
        return p.create(try p.parseElementBody(null, first));
    }

    /// `var [in | out | in-out | private] <type> name [: expr | <=> expr];`
    /// (the type still needed).
    fn parseVarDecl(p: *Parser) Error!ast.PropertyDecl {
        const kw = try p.expectWord("var");
        var visibility: ast.Visibility = .private;
        // A modifier, unless it is the name (`var in;`).
        const after = p.peekNext().tag;
        if (after == .identifier or after == .less) {
            inline for (.{ .{ "in", .in }, .{ "out", .out }, .{ "in-out", .in_out }, .{ "private", .private } }) |v| {
                if (p.isWord(v[0])) {
                    _ = p.advance();
                    visibility = v[1];
                    break;
                }
            }
        }
        if (p.tok.tag != .less) return p.fail(spanOf(p.tok), "a var needs its type for now: `var <int> name`", .{});
        _ = p.advance();
        const type_name = try p.typeRef();
        _ = try p.expect(.greater);
        return p.parsePropertyRest(spanOf(kw), visibility, type_name);
    }

    /// A property declaration after its type: the name, its value or link.
    fn parsePropertyRest(p: *Parser, kw: Span, visibility: ast.Visibility, type_name: ast.TypeRef) Error!ast.PropertyDecl {
        const name = try p.ident();
        var decl: ast.PropertyDecl = .{ .visibility = visibility, .type_name = type_name, .name = name, .init = null, .alias = null, .span = kw.join(name.span) };
        switch (p.tok.tag) {
            .colon => {
                _ = p.advance();
                decl.init = try p.parseExpr();
            },
            .two_way => {
                _ = p.advance();
                decl.alias = try p.parseExpr();
            },
            else => {},
        }
        _ = try p.expect(.semicolon);
        return decl;
    }

    /// `name` or `[name]`.
    fn typeRef(p: *Parser) Error!ast.TypeRef {
        if (p.tok.tag == .l_bracket) {
            const open = p.advance();
            if (p.tok.tag == .l_bracket) {
                _ = p.advance();
                const name = try p.ident();
                _ = try p.expect(.r_bracket);
                const close = try p.expect(.r_bracket);
                return .{ .name = name, .model = true, .nested = true, .span = .{ .start = open.start, .end = close.end } };
            }
            const name = try p.ident();
            const close = try p.expect(.r_bracket);
            return .{ .name = name, .model = true, .span = .{ .start = open.start, .end = close.end } };
        }
        const name = try p.ident();
        return .{ .name = name, .model = false, .span = name.span };
    }

    fn parseCallbackDecl(p: *Parser) Error!ast.CallbackDecl {
        const kw = try p.expectWord("callback");
        const name = try p.ident();
        var params: std.ArrayList(ast.Ident) = .empty;
        if (p.tok.tag == .l_paren) {
            _ = p.advance();
            while (p.tok.tag != .r_paren) {
                try params.append(p.arena, try p.ident());
                if (p.tok.tag != .comma) break;
                _ = p.advance();
            }
            _ = try p.expect(.r_paren);
        }
        var ret: ?ast.Ident = null;
        if (p.tok.tag == .arrow) {
            _ = p.advance();
            ret = try p.ident();
        }
        const end = try p.expect(.semicolon);
        return .{ .name = name, .params = params.items, .ret = ret, .span = .{ .start = kw.start, .end = end.end } };
    }

    /// `[public] [pure] function name(a: T, ...) -> R { ... }`
    fn parseFunctionDecl(p: *Parser) Error!ast.FunctionDecl {
        const start = p.tok.start;
        var public = false;
        while (p.isWord("public") or p.isWord("pure")) {
            if (p.isWord("public")) public = true;
            _ = p.advance();
        }
        _ = try p.expectWord("function");
        const name = try p.ident();
        _ = try p.expect(.l_paren);
        var params: std.ArrayList(ast.FunctionDecl.Param) = .empty;
        while (p.tok.tag != .r_paren) {
            const param = try p.ident();
            _ = try p.expect(.colon);
            try params.append(p.arena, .{ .name = param, .type_name = try p.typeRef() });
            if (p.tok.tag != .comma) break;
            _ = p.advance();
        }
        _ = try p.expect(.r_paren);
        var ret: ?ast.TypeRef = null;
        if (p.tok.tag == .arrow) {
            _ = p.advance();
            ret = try p.typeRef();
        }
        const body = try p.parseBlock();
        return .{ .name = name, .params = params.items, .ret = ret, .body = body.stmts, .public = public, .span = .{ .start = start, .end = body.span.end } };
    }

    fn parseAnimate(p: *Parser) Error!ast.Animate {
        const kw = try p.expectWord("animate");
        var props: std.ArrayList(ast.Ident) = .empty;
        while (true) {
            try props.append(p.arena, try p.ident());
            if (p.tok.tag != .comma) break;
            _ = p.advance();
        }
        _ = try p.expect(.l_brace);
        var settings: std.ArrayList(ast.Animate.Setting) = .empty;
        while (p.tok.tag != .r_brace) {
            const name = try p.ident();
            _ = try p.expect(.colon);
            const value = try p.parseExpr();
            _ = try p.expect(.semicolon);
            try settings.append(p.arena, .{ .name = name, .value = value });
        }
        const close = p.advance();
        return .{ .properties = props.items, .settings = settings.items, .span = .{ .start = kw.start, .end = close.end } };
    }

    // ---- Statements ----

    const Block = struct { stmts: []ast.Stmt, span: Span };

    fn parseBlock(p: *Parser) Error!Block {
        const open = try p.expect(.l_brace);
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        while (p.tok.tag != .r_brace) {
            if (p.tok.tag == .eof) return p.fail(spanOf(open), "unclosed '{{'", .{});
            try stmts.append(p.arena, try p.parseStmt());
        }
        const close = p.advance();
        return .{ .stmts = stmts.items, .span = .{ .start = open.start, .end = close.end } };
    }

    fn parseStmt(p: *Parser) Error!ast.Stmt {
        const start = p.tok.start;
        if (p.isWord("if")) {
            _ = p.advance();
            const cond = try p.parseExpr();
            const then = try p.parseBlock();
            var otherwise: []ast.Stmt = &.{};
            var end = then.span.end;
            if (p.isWord("else")) {
                _ = p.advance();
                if (p.isWord("if")) {
                    const nested = try p.create(try p.parseStmt());
                    otherwise = nested[0..1];
                    end = nested.span.end;
                } else {
                    const b = try p.parseBlock();
                    otherwise = b.stmts;
                    end = b.span.end;
                }
            }
            return .{ .kind = .{ .@"if" = .{ .cond = cond, .then = then.stmts, .otherwise = otherwise } }, .span = .{ .start = start, .end = end } };
        }
        if (p.isWord("let")) {
            _ = p.advance();
            const name = try p.ident();
            var type_name: ?ast.TypeRef = null;
            if (p.tok.tag == .colon) {
                _ = p.advance();
                type_name = try p.typeRef();
            }
            _ = try p.expect(.equal);
            const value = try p.parseExpr();
            const semi = try p.expect(.semicolon);
            return .{ .kind = .{ .let = .{ .name = name, .type_name = type_name, .value = value } }, .span = .{ .start = start, .end = semi.end } };
        }
        if (p.isWord("while")) {
            _ = p.advance();
            const cond = try p.parseExpr();
            const body = try p.parseBlock();
            return .{ .kind = .{ .@"while" = .{ .cond = cond, .body = body.stmts } }, .span = .{ .start = start, .end = body.span.end } };
        }
        if (p.isWord("for")) {
            _ = p.advance();
            const item = try p.ident();
            var index: ?ast.Ident = null;
            if (p.tok.tag == .l_bracket) {
                _ = p.advance();
                index = try p.ident();
                _ = try p.expect(.r_bracket);
            }
            if (!p.isWord("in")) return p.fail(spanOf(p.tok), "expected 'in', found {s}", .{p.describeCurrent()});
            _ = p.advance();
            const over = try p.parseExpr();
            const body = try p.parseBlock();
            return .{ .kind = .{ .@"for" = .{ .item = item, .index = index, .over = over, .body = body.stmts } }, .span = .{ .start = start, .end = body.span.end } };
        }
        if (p.isWord("break") or p.isWord("continue")) {
            const word = p.advance();
            const semi = try p.expect(.semicolon);
            const kind: ast.Stmt.Kind = if (std.mem.eql(u8, p.text(word), "break")) .@"break" else .@"continue";
            return .{ .kind = kind, .span = .{ .start = start, .end = semi.end } };
        }
        if (p.isWord("return")) {
            _ = p.advance();
            var value: ?*ast.Expr = null;
            if (p.tok.tag != .semicolon) value = try p.parseExpr();
            const semi = try p.expect(.semicolon);
            return .{ .kind = .{ .@"return" = value }, .span = .{ .start = start, .end = semi.end } };
        }
        const target = try p.parseExpr();
        switch (p.tok.tag) {
            .equal, .plus_equal, .minus_equal, .star_equal, .slash_equal => {
                const op = p.advance().tag;
                const value = try p.parseExpr();
                const semi = try p.expect(.semicolon);
                return .{ .kind = .{ .assign = .{ .target = target, .op = op, .value = value } }, .span = .{ .start = start, .end = semi.end } };
            },
            else => {
                const semi = try p.expect(.semicolon);
                return .{ .kind = .{ .expr = target }, .span = .{ .start = start, .end = semi.end } };
            },
        }
    }

    // ---- Expressions ----

    pub fn parseExpr(p: *Parser) Error!*ast.Expr {
        const cond = try p.parseBinary(0);
        if (p.tok.tag != .question) return cond;
        _ = p.advance();
        const then = try p.parseExpr();
        _ = try p.expect(.colon);
        const otherwise = try p.parseExpr();
        return p.create(ast.Expr{ .kind = .{ .ternary = .{ .cond = cond, .then = then, .otherwise = otherwise } }, .span = cond.span.join(otherwise.span) });
    }

    fn precedence(tag: Tag) ?u8 {
        return switch (tag) {
            .or_or => 1,
            .and_and => 2,
            .equal_equal, .bang_equal => 3,
            .less, .less_equal, .greater, .greater_equal => 4,
            .plus, .minus => 5,
            .star, .slash => 6,
            else => null,
        };
    }

    fn parseBinary(p: *Parser, min: u8) Error!*ast.Expr {
        var lhs = try p.parseUnary();
        while (precedence(p.tok.tag)) |prec| {
            if (prec <= min) break;
            const op = p.advance().tag;
            const rhs = try p.parseBinary(prec);
            lhs = try p.create(ast.Expr{ .kind = .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } }, .span = lhs.span.join(rhs.span) });
        }
        return lhs;
    }

    fn parseUnary(p: *Parser) Error!*ast.Expr {
        if (p.tok.tag == .bang or p.tok.tag == .minus or p.tok.tag == .plus) {
            const op = p.advance();
            const operand = try p.parseUnary();
            return p.create(ast.Expr{ .kind = .{ .unary = .{ .op = op.tag, .operand = operand } }, .span = spanOf(op).join(operand.span) });
        }
        return p.parsePostfix();
    }

    fn parsePostfix(p: *Parser) Error!*ast.Expr {
        var e = try p.parsePrimary();
        while (true) switch (p.tok.tag) {
            .dot => {
                _ = p.advance();
                const name = try p.ident();
                e = try p.create(ast.Expr{ .kind = .{ .member = .{ .object = e, .name = name } }, .span = e.span.join(name.span) });
            },
            .l_bracket => {
                _ = p.advance();
                const index = try p.parseExpr();
                const close = try p.expect(.r_bracket);
                e = try p.create(ast.Expr{ .kind = .{ .index = .{ .object = e, .index = index } }, .span = e.span.join(spanOf(close)) });
            },
            .l_paren => {
                _ = p.advance();
                var args: std.ArrayList(*ast.Expr) = .empty;
                while (p.tok.tag != .r_paren) {
                    if (p.tok.tag == .identifier and p.peekNext().tag == .fat_arrow) {
                        // `row => expression`
                        const param = try p.ident();
                        _ = p.advance();
                        const body = try p.parseExpr();
                        try args.append(p.arena, try p.create(ast.Expr{ .kind = .{ .lambda = .{ .param = param, .body = body } }, .span = param.span.join(body.span) }));
                    } else try args.append(p.arena, try p.parseExpr());
                    if (p.tok.tag != .comma) break;
                    _ = p.advance();
                }
                const close = try p.expect(.r_paren);
                e = try p.create(ast.Expr{ .kind = .{ .call = .{ .callee = e, .args = args.items } }, .span = e.span.join(spanOf(close)) });
            },
            else => return e,
        };
    }

    fn parsePrimary(p: *Parser) Error!*ast.Expr {
        const t = p.tok;
        switch (t.tag) {
            .identifier => {
                _ = p.advance();
                return p.create(ast.Expr{ .kind = .{ .ident = p.text(t) }, .span = spanOf(t) });
            },
            .number => {
                _ = p.advance();
                return p.create(ast.Expr{ .kind = try p.number(t), .span = spanOf(t) });
            },
            .color => {
                _ = p.advance();
                return p.create(ast.Expr{ .kind = .{ .color = try p.color(t) }, .span = spanOf(t) });
            },
            .string => {
                _ = p.advance();
                return p.create(ast.Expr{ .kind = .{ .string = try p.stringParts(t) }, .span = spanOf(t) });
            },
            .l_paren => {
                _ = p.advance();
                const inner = try p.parseExpr();
                _ = try p.expect(.r_paren);
                return inner;
            },
            .l_brace => {
                // `{ name: value, ... }`
                _ = p.advance();
                var fields: std.ArrayList(ast.FieldInit) = .empty;
                while (p.tok.tag != .r_brace) {
                    const name = try p.ident();
                    _ = try p.expect(.colon);
                    try fields.append(p.arena, .{ .name = name, .value = try p.parseExpr() });
                    if (p.tok.tag != .comma) break;
                    _ = p.advance();
                }
                const close = try p.expect(.r_brace);
                return p.create(ast.Expr{ .kind = .{ .struct_literal = fields.items }, .span = .{ .start = t.start, .end = close.end } });
            },
            .at => {
                _ = p.advance();
                const name = try p.ident();
                if (std.mem.eql(u8, name.name, "tr")) return p.parseTr(t);
                if (std.mem.eql(u8, name.name, "linear-gradient")) return p.parseGradient(t, .linear);
                if (std.mem.eql(u8, name.name, "radial-gradient")) return p.parseGradient(t, .radial);
                const Url = enum { image, audio, video, model };
                const url: Url = if (std.mem.eql(u8, name.name, "image-url")) .image else if (std.mem.eql(u8, name.name, "audio-url")) .audio else if (std.mem.eql(u8, name.name, "video-url")) .video else if (std.mem.eql(u8, name.name, "model-url")) .model else return p.fail(name.span, "unknown '@{s}' (expected @image-url, @audio-url, @video-url, @model-url, @linear-gradient, @radial-gradient or @tr)", .{name.name});
                _ = try p.expect(.l_paren);
                const path_tok = try p.expect(.string);
                const parts = try p.stringParts(path_tok);
                if (parts.len != 1 or parts[0] != .literal) return p.fail(spanOf(path_tok), "the {t} path must be a plain string", .{url});
                var nine_slice: ?[4]u32 = null;
                if (url == .image and p.tok.tag == .comma) {
                    _ = p.advance();
                    nine_slice = try p.parseNineSlice();
                }
                const close = try p.expect(.r_paren);
                const kind: ast.Expr.Kind = switch (url) {
                    .image => .{ .image_url = .{ .path = parts[0].literal, .nine_slice = nine_slice } },
                    .audio => .{ .audio_url = parts[0].literal },
                    .video => .{ .video_url = parts[0].literal },
                    .model => .{ .model_url = parts[0].literal },
                };
                return p.create(ast.Expr{ .kind = kind, .span = .{ .start = t.start, .end = close.end } });
            },
            .l_bracket => {
                _ = p.advance();
                var items: std.ArrayList(*ast.Expr) = .empty;
                while (p.tok.tag != .r_bracket) {
                    try items.append(p.arena, try p.parseExpr());
                    if (p.tok.tag != .comma) break;
                    _ = p.advance();
                }
                const close = try p.expect(.r_bracket);
                return p.create(ast.Expr{ .kind = .{ .array = items.items }, .span = .{ .start = t.start, .end = close.end } });
            },
            else => return p.fail(spanOf(t), "expected an expression, found {s}", .{p.describeCurrent()}),
        }
    }

    /// After `@linear-gradient` or `@radial-gradient`: `(angle, color
    /// position, ...)`, the angle optional; `circle, ` allowed (and ignored)
    /// first in a radial one, as CSS writes it.
    fn parseGradient(p: *Parser, at: Token, shape: @FieldType(ast.Gradient, "shape")) Error!*ast.Expr {
        _ = try p.expect(.l_paren);
        if (shape == .radial and p.isWord("circle") and p.peekNext().tag == .comma) {
            _ = p.advance();
            _ = p.advance();
        }
        var stops: std.ArrayList(ast.Gradient.Stop) = .empty;
        while (true) {
            const stop_color = try p.parseExpr();
            const position = if (p.tok.tag != .comma and p.tok.tag != .r_paren) try p.parseExpr() else null;
            try stops.append(p.arena, .{ .color = stop_color, .position = position });
            if (p.tok.tag != .comma) break;
            _ = p.advance();
            if (p.tok.tag == .r_paren) break;
        }
        const close = try p.expect(.r_paren);
        return p.create(ast.Expr{ .kind = .{ .gradient = .{ .shape = shape, .stops = stops.items } }, .span = .{ .start = at.start, .end = close.end } });
    }

    /// After `@tr`: `("ctx" => "text" | "plural" % count, args...)`.
    fn parseTr(p: *Parser, at: Token) Error!*ast.Expr {
        _ = try p.expect(.l_paren);
        var tr: ast.Tr = .{ .context = "", .text = undefined, .plural = null, .count = null, .args = &.{} };
        tr.text = try p.plainString("the text to translate");
        if (p.tok.tag == .fat_arrow) {
            _ = p.advance();
            tr.context = tr.text;
            tr.text = try p.plainString("the text to translate");
        }
        if (p.tok.tag == .pipe) {
            _ = p.advance();
            tr.plural = try p.plainString("the plural form");
            _ = try p.expect(.percent);
            tr.count = try p.parseUnary();
        }
        var args: std.ArrayList(*ast.Expr) = .empty;
        while (p.tok.tag == .comma) {
            _ = p.advance();
            if (p.tok.tag == .r_paren) break;
            try args.append(p.arena, try p.parseExpr());
        }
        tr.args = args.items;
        const close = try p.expect(.r_paren);
        return p.create(ast.Expr{ .kind = .{ .tr = tr }, .span = .{ .start = at.start, .end = close.end } });
    }

    /// A string without interpolation (`\{...}`), as its text.
    fn plainString(p: *Parser, what: []const u8) Error![]const u8 {
        if (p.tok.tag != .string) return p.fail(spanOf(p.tok), "expected {s} (a string), found {s}", .{ what, p.describeCurrent() });
        const t = p.advance();
        const parts = try p.stringParts(t);
        if (parts.len == 0) return "";
        if (parts.len != 1 or parts[0] != .literal) return p.fail(spanOf(t), "{s} cannot contain \\{{...}}: use {{}} and pass the value after it", .{what});
        return parts[0].literal;
    }

    fn number(p: *Parser, t: Token) Error!ast.Expr.Kind {
        const s = p.text(t);
        var digits_end: usize = 0;
        while (digits_end < s.len and (std.ascii.isDigit(s[digits_end]) or s[digits_end] == '.')) digits_end += 1;
        const value = std.fmt.parseFloat(f64, s[0..digits_end]) catch return p.fail(spanOf(t), "invalid number '{s}'", .{s});
        return .{ .number = .{ .value = value, .is_int = std.mem.indexOfScalar(u8, s[0..digits_end], '.') == null, .unit = s[digits_end..] } };
    }

    fn color(p: *Parser, t: Token) Error!u32 {
        const hex = p.text(t)[1..];
        const v = std.fmt.parseInt(u32, hex, 16) catch return p.fail(spanOf(t), "invalid color '#{s}'", .{hex});
        return switch (hex.len) {
            3 => expand4((v << 4) | 0xf),
            4 => expand4(v),
            6 => (v << 8) | 0xff,
            8 => v,
            else => p.fail(spanOf(t), "a color has 3, 4, 6 or 8 hex digits: '#{s}'", .{hex}),
        };
    }

    /// `#rgba` to `0xrrggbbaa`.
    fn expand4(v: u32) u32 {
        var out: u32 = 0;
        var i: u5 = 0;
        while (i < 4) : (i += 1) {
            const nibble = (v >> (12 - @as(u5, i) * 4)) & 0xf;
            out = (out << 8) | (nibble * 0x11);
        }
        return out;
    }

    /// Splits a string literal into text (escapes resolved) and `\{...}`
    /// expressions.
    fn stringParts(p: *Parser, t: Token) Error![]ast.StringPart {
        var parts: std.ArrayList(ast.StringPart) = .empty;
        var buf: std.ArrayList(u8) = .empty;
        var i: u32 = t.start + 1;
        const end = t.end - 1;
        while (i < end) {
            const ch = p.source[i];
            if (ch != '\\') {
                try buf.append(p.arena, ch);
                i += 1;
                continue;
            }
            const esc = p.source[i + 1];
            switch (esc) {
                'n' => try buf.append(p.arena, '\n'),
                't' => try buf.append(p.arena, '\t'),
                '\\', '"', '\'' => try buf.append(p.arena, esc),
                'u' => {
                    // \u{XXXX}
                    if (p.source[i + 2] != '{') return p.fail(.{ .start = i, .end = i + 2 }, "expected '{{' after \\u", .{});
                    const close = std.mem.indexOfScalarPos(u8, p.source[0..end], i + 3, '}') orelse
                        return p.fail(.{ .start = i, .end = end }, "unclosed \\u{{...}}", .{});
                    const cp = std.fmt.parseInt(u21, p.source[i + 3 .. close], 16) catch
                        return p.fail(.{ .start = i, .end = @intCast(close + 1) }, "invalid code point", .{});
                    var utf8: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &utf8) catch
                        return p.fail(.{ .start = i, .end = @intCast(close + 1) }, "invalid code point", .{});
                    try buf.appendSlice(p.arena, utf8[0..n]);
                    i = @intCast(close + 1);
                    continue;
                },
                '{' => {
                    if (buf.items.len > 0) {
                        try parts.append(p.arena, .{ .literal = buf.items });
                        buf = .empty;
                    }
                    // Find the matching brace (the lexer validated nesting).
                    var depth: u32 = 1;
                    var j = i + 2;
                    while (depth > 0) : (j += 1) {
                        switch (p.source[j]) {
                            '{' => depth += 1,
                            '}' => depth -= 1,
                            else => {},
                        }
                    }
                    var sub: Parser = .initRange(p.arena, p.source, p.diags, i + 2, j - 1);
                    const e = try sub.parseExpr();
                    if (sub.tok.tag != .eof) return sub.fail(spanOf(sub.tok), "expected '}}' to end the interpolation, found {s}", .{sub.describeCurrent()});
                    try parts.append(p.arena, .{ .expr = e });
                    i = j;
                    continue;
                },
                else => return p.fail(.{ .start = i, .end = i + 2 }, "unknown escape '\\{c}'", .{esc}),
            }
            i += 2;
        }
        if (buf.items.len > 0 or parts.items.len == 0) try parts.append(p.arena, .{ .literal = buf.items });
        return parts.items;
    }
};

const testing = std.testing;

fn parse(arena: Allocator, source: []const u8, diags: *Diagnostics) Error!ast.Document {
    var p: Parser = .init(arena, source, diags);
    return p.parseDocument();
}

test "components, members and elements" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .{ .arena = arena.allocator() };
    const doc = try parse(arena.allocator(),
        \\component Button inherits Rectangle {
        \\    var in <string> text;
        \\    callback clicked();
        \\    callback add(int, int) -> int;
        \\    background: touch.pressed ? #333 : #555555ff;
        \\    touch := TouchArea { clicked => { root.clicked(); } }
        \\    animate background { duration: 150ms; easing: ease-out; }
        \\}
        \\export component App inherits Window {
        \\    var in-out <int> count: 0;
        \\    Button { text: "Count: \{count}"; clicked => { count += 1; } }
        \\    label <=> other.text;
        \\    add(a, b) => { return a + b; }
        \\}
    , &diags);
    try testing.expectEqual(@as(usize, 2), doc.components.len);
    const button = doc.components[0];
    try testing.expectEqualStrings("Button", button.name.name);
    try testing.expect(!button.exported);
    try testing.expectEqualStrings("Rectangle", button.root.type_name.name);
    const m = button.root.members;
    try testing.expectEqual(ast.Visibility.in, m[0].property.visibility);
    try testing.expectEqualStrings("string", m[0].property.type_name.name.name);
    try testing.expectEqual(@as(usize, 0), m[1].callback.params.len);
    try testing.expectEqualStrings("int", m[2].callback.ret.?.name);
    try testing.expect(m[3].binding.value.kind == .ternary);
    try testing.expectEqual(@as(u32, 0x333333ff), m[3].binding.value.kind.ternary.then.kind.color);
    try testing.expectEqualStrings("touch", m[4].child.id.?.name);
    try testing.expectEqualStrings("clicked", m[4].child.members[0].handler.name.name);
    try testing.expectEqualStrings("background", m[5].animate.properties[0].name);

    const app = doc.components[1];
    try testing.expect(app.exported);
    const am = app.root.members;
    try testing.expectEqual(ast.Visibility.in_out, am[0].property.visibility);
    const parts = am[1].child.members[0].binding.value.kind.string;
    try testing.expectEqualStrings("Count: ", parts[0].literal);
    try testing.expectEqualStrings("count", parts[1].expr.kind.ident);
    try testing.expectEqual(Tag.plus_equal, am[1].child.members[1].handler.body[0].kind.assign.op);
    try testing.expect(am[2] == .two_way);
    try testing.expectEqual(@as(usize, 2), am[3].handler.params.len);
}

test "for, if, models and arrays" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .{ .arena = arena.allocator() };
    const doc = try parse(arena.allocator(),
        \\component A {
        \\    var in <[string]> names: ["a", "b"];
        \\    for name[i] in names : row := Text { text: name; }
        \\    for n in 3 : Rectangle {}
        \\    if names[0] == "a" : Text {}
        \\}
    , &diags);
    const m = doc.components[0].root.members;
    try testing.expect(m[0].property.type_name.model);
    try testing.expectEqual(@as(usize, 2), m[0].property.init.?.kind.array.len);
    try testing.expectEqualStrings("name", m[1].repeated.item.?.name);
    try testing.expectEqualStrings("i", m[1].repeated.index.?.name);
    try testing.expectEqualStrings("row", m[1].repeated.element.id.?.name);
    try testing.expectEqual(@as(?ast.Ident, null), m[2].repeated.index);
    try testing.expect(m[3].conditional.condition.kind.binary.lhs.kind == .index);
}

test "operator precedence and numbers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .{ .arena = arena.allocator() };
    var p: Parser = .init(arena.allocator(), "a + b * 2px > 3 && !c || d", &diags);
    const e = try p.parseExpr();
    // ((a + (b * 2px)) > 3 && !c) || d
    try testing.expectEqual(Tag.or_or, e.kind.binary.op);
    const and_ = e.kind.binary.lhs.kind.binary;
    try testing.expectEqual(Tag.and_and, and_.op);
    const gt = and_.lhs.kind.binary;
    try testing.expectEqual(Tag.greater, gt.op);
    const mul = gt.lhs.kind.binary.rhs.kind.binary;
    try testing.expectEqual(Tag.star, mul.op);
    try testing.expectEqualStrings("px", mul.rhs.kind.number.unit);
    try testing.expect(mul.rhs.kind.number.is_int);
}

test "syntax errors point at the problem" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: Diagnostics = .{ .arena = arena.allocator() };
    const source = "component A { width 10px; }";
    try testing.expectError(error.ParseError, parse(arena.allocator(), source, &diags));
    try testing.expectEqualStrings("expected ':', ':=', '{', '<=>' or '=>' after 'width', found a number", diags.list.items[0].message);
    try testing.expectEqual(@as(u32, 20), diags.list.items[0].span.start);

    diags.list.clearRetainingCapacity();
    try testing.expectError(error.ParseError, parse(arena.allocator(), "component A { t: \"x\\{1 +}\"; }", &diags));
    try testing.expectEqualStrings("expected an expression, found the end of the file", diags.list.items[0].message);
}
