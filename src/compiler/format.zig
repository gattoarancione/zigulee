// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The `.zge` formatter (`zgec fmt`): canonical spacing and indentation.
//!
//! It works on tokens, so it keeps everything the author wrote: comments,
//! up to one blank line between statements, and line breaks inside long
//! expressions (continuation lines are indented one extra level). Blocks
//! written on one line (`Text { text: "hi"; }`) stay on one line; other
//! blocks get one statement per line, indented by four spaces.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("lexer.zig");
const Token = lexer.Token;
const Tag = lexer.Tag;

pub const Error = error{ OutOfMemory, InvalidSource };

const Kind = enum {
    /// `{ ... }` holding statements, members or elements.
    block,
    /// A block whose braces are on the same line.
    inline_block,
    /// A struct literal: `{ name: value, ... }`.
    struct_literal,
    paren,
    bracket,
    /// `states [ ... ]`: one state per line.
    bracket_block,
    /// `var <T>`.
    angle,
};

const Frame = struct {
    kind: Kind,
    /// Indentation level of the line the opening token is on.
    base: usize,
    /// Index of the matching closing token.
    close: usize,
    /// Per-statement state: a `for`/`if` header or a `when` (their `:` is
    /// spaced on both sides), and `?` waiting for their `:`.
    header: bool = false,
    pending_ternaries: u32 = 0,
    /// The fields of a `struct` or the values of an `enum`: one per line.
    list: bool = false,

    fn isBlock(f: Frame) bool {
        return f.kind == .block or f.kind == .bracket_block;
    }
};

/// Formats `source`. Returns `error.InvalidSource` for text that does not
/// tokenize or whose brackets do not match.
pub fn format(gpa: Allocator, source: []const u8) Error![]u8 {
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(gpa);
    var lx: lexer.Lexer = .init(source);
    while (true) {
        const t = lx.next();
        if (t.tag == .eof) break;
        if (t.tag == .invalid) return error.InvalidSource;
        try tokens.append(gpa, t);
    }
    const matches = try matchBrackets(gpa, source, tokens.items);
    defer gpa.free(matches);

    var f: Formatter = .{ .gpa = gpa, .source = source, .tokens = tokens.items, .matches = matches };
    defer f.frames.deinit(gpa);
    errdefer f.out.deinit(gpa);
    try f.run();
    return f.out.toOwnedSlice(gpa);
}

/// For each opening bracket, the index of its closing one (and vice versa).
fn matchBrackets(gpa: Allocator, source: []const u8, tokens: []const Token) Error![]usize {
    const matches = try gpa.alloc(usize, tokens.len);
    errdefer gpa.free(matches);
    @memset(matches, std.math.maxInt(usize));
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    var angle_open: ?usize = null;
    for (tokens, 0..) |t, i| {
        switch (t.tag) {
            .l_brace, .l_paren, .l_bracket => try stack.append(gpa, i),
            .r_brace, .r_paren, .r_bracket => {
                const open = stack.pop() orelse return error.InvalidSource;
                const expected: Tag = switch (t.tag) {
                    .r_brace => .l_brace,
                    .r_paren => .l_paren,
                    else => .l_bracket,
                };
                if (tokens[open].tag != expected) return error.InvalidSource;
                matches[open] = i;
                matches[i] = open;
            },
            // `var <T>` / `var <[T]>`, and the same after `var`
            // or `var in` (`out`, `in-out`, `private`).
            .less => if (i > 0 and (isWord(source, tokens[i - 1], "property") or isWord(source, tokens[i - 1], "var") or
                (i > 1 and isWord(source, tokens[i - 2], "var") and isModifier(source, tokens[i - 1]))))
            {
                angle_open = i;
            },
            .greater => if (angle_open) |open| {
                matches[open] = i;
                matches[i] = open;
                angle_open = null;
            },
            else => {},
        }
    }
    if (stack.items.len != 0) return error.InvalidSource;
    return matches;
}

fn isModifier(source: []const u8, t: Token) bool {
    return isWord(source, t, "in") or isWord(source, t, "out") or isWord(source, t, "in-out") or isWord(source, t, "private");
}

fn isWord(source: []const u8, t: Token, word: []const u8) bool {
    return t.tag == .identifier and std.mem.eql(u8, t.text(source), word);
}

const Formatter = struct {
    gpa: Allocator,
    source: []const u8,
    tokens: []const Token,
    matches: []const usize,
    out: std.ArrayList(u8) = .empty,
    /// Where the tokens written since the last whitespace start in `out`.
    run_start: usize = 0,
    frames: std.ArrayList(Frame) = .empty,
    /// The next token starts a statement (or member, or element).
    at_statement_start: bool = true,
    /// Indentation of the current output line.
    line_level: usize = 0,
    /// Top-level statement state (outside any bracket).
    top: Frame = .{ .kind = .block, .base = 0, .close = 0 },

    fn word(f: *const Formatter, t: Token, w: []const u8) bool {
        return isWord(f.source, t, w);
    }

    fn frame(f: *Formatter) *Frame {
        return if (f.frames.items.len > 0) &f.frames.items[f.frames.items.len - 1] else &f.top;
    }

    fn sameLine(f: *const Formatter, a: usize, b: usize) bool {
        return std.mem.indexOfScalar(u8, f.source[f.tokens[a].start..f.tokens[b].start], '\n') == null;
    }

    fn write(f: *Formatter, bytes: []const u8) Allocator.Error!void {
        try f.out.appendSlice(f.gpa, bytes);
    }

    fn newline(f: *Formatter, level: usize, blank: bool) Allocator.Error!void {
        // No trailing spaces.
        while (f.out.items.len > 0 and f.out.items[f.out.items.len - 1] == ' ') f.out.items.len -= 1;
        if (f.out.items.len == 0) {
            f.line_level = level;
            return;
        }
        try f.write("\n");
        if (blank) try f.write("\n");
        try f.out.appendNTimes(f.gpa, ' ', level * 4);
        f.line_level = level;
    }

    /// Indentation for token `i` when it starts a line.
    fn levelFor(f: *Formatter, i: usize) usize {
        const t = f.tokens[i];
        if (isClose(t.tag) or (t.tag == .greater and f.matches[i] != std.math.maxInt(usize))) {
            if (f.frames.items.len > 0) return f.frame().base;
        }
        const fr = f.frame().*;
        if (f.frames.items.len == 0) return if (f.at_statement_start) 0 else 1;
        if (fr.isBlock()) return fr.base + @as(usize, if (f.at_statement_start) 1 else 2);
        return fr.base + 1;
    }

    fn isClose(tag: Tag) bool {
        return tag == .r_brace or tag == .r_paren or tag == .r_bracket;
    }

    fn run(f: *Formatter) Error!void {
        for (f.tokens, 0..) |t, i| {
            const gap_start = if (i == 0) 0 else f.tokens[i - 1].end;
            try f.separate(i, f.source[gap_start..t.start]);
            if (f.out.items.len == 0 or std.ascii.isWhitespace(f.out.items[f.out.items.len - 1])) f.run_start = f.out.items.len;
            try f.write(t.text(f.source));
            f.at_statement_start = false;
            try f.after(i);
        }
        // Comments after the last token.
        const tail_start = if (f.tokens.len == 0) 0 else f.tokens[f.tokens.len - 1].end;
        _ = try f.comments(f.source[tail_start..], 0, f.tokens.len == 0);
        while (f.out.items.len > 0 and (f.out.items[f.out.items.len - 1] == ' ' or f.out.items[f.out.items.len - 1] == '\n')) f.out.items.len -= 1;
        if (f.out.items.len > 0) try f.write("\n");
    }

    /// Writes the comments in `gap` (the source between two tokens), each on
    /// its own line unless it followed code on the same line. Returns true
    /// if the last one is a block comment followed by code on its line.
    fn comments(f: *Formatter, gap: []const u8, level: usize, first_in_file: bool) Allocator.Error!bool {
        var i: usize = 0;
        var newlines: usize = if (first_in_file) 1 else 0;
        while (i < gap.len) {
            const ch = gap[i];
            if (ch == '\n') {
                newlines += 1;
                i += 1;
            } else if (ch == '/' and i + 1 < gap.len and (gap[i + 1] == '/' or gap[i + 1] == '*')) {
                const end = if (gap[i + 1] == '/')
                    std.mem.indexOfScalarPos(u8, gap, i, '\n') orelse gap.len
                else if (std.mem.indexOfPos(u8, gap, i + 2, "*/")) |e| e + 2 else gap.len;
                const text = std.mem.trimEnd(u8, gap[i..end], " \t\r");
                if (newlines == 0) {
                    if (f.out.items.len > 0) try f.write(" ");
                } else {
                    try f.newline(level, newlines > 1 and f.out.items.len > 0);
                }
                try f.write(text);
                newlines = 0;
                i = end;
                if (text[1] == '*' and std.mem.indexOfScalar(u8, gap[end..], '\n') == null) return true;
            } else i += 1;
        }
        return false;
    }

    fn hasComment(gap: []const u8) bool {
        return std.mem.indexOf(u8, gap, "//") != null or std.mem.indexOf(u8, gap, "/*") != null;
    }

    fn lastWrittenIsLineComment(f: *Formatter) bool {
        const line_start = if (std.mem.lastIndexOfScalar(u8, f.out.items, '\n')) |n| n + 1 else 0;
        const line = f.out.items[line_start..];
        // A `//` outside strings on the current output line.
        var in_string = false;
        var j: usize = 0;
        while (j < line.len) : (j += 1) {
            if (line[j] == '"' and (j == 0 or line[j - 1] != '\\')) in_string = !in_string;
            if (!in_string and line[j] == '/' and j + 1 < line.len and line[j + 1] == '/') return true;
        }
        return false;
    }

    /// Whitespace (and comments) before token `i`.
    fn separate(f: *Formatter, i: usize, gap: []const u8) Error!void {
        const t = f.tokens[i];
        const newlines = std.mem.count(u8, gap, "\n");
        if (i == 0) {
            if (try f.comments(gap, 0, true)) return f.write(" ");
            if (f.out.items.len > 0) try f.newline(0, blankBeforeLast(gap));
            return;
        }
        const level = f.levelFor(i);
        if (hasComment(gap) and try f.comments(gap, level, false)) return f.write(" ");
        const comment_forces = f.lastWrittenIsLineComment();

        const p = f.tokens[i - 1];
        const fr = f.frame().*;
        // Forced line breaks: statement boundaries in multi-line blocks.
        const closes_block = isClose(t.tag) and f.frames.items.len > 0 and fr.isBlock() and f.matches[i] != std.math.maxInt(usize);
        if (f.at_statement_start or closes_block) {
            const empty_block = closes_block and f.matches[i] == i - 1;
            if (empty_block and !comment_forces) return;
            if (p.tag == .r_brace and f.word(t, "else")) return f.write(" ");
            const blank = newlines > 1 and !closes_block and blankBeforeLast(gap);
            return f.newline(level, blank);
        }
        if (comment_forces) return f.newline(level, false);
        // Line breaks the author put inside a statement are kept.
        if (newlines > 0 and t.tag != .semicolon and t.tag != .comma and fr.kind != .inline_block)
            return f.newline(level, false);
        if (f.spaceBetween(i - 1, i) or f.wouldJoin(i - 1, i)) try f.write(" ");
    }

    /// Whether token `b` written right after the output (without a space)
    /// would lex as something else, joining what precedes it: `!` `=` as
    /// `!=`, `a` `-` `b` as `a-b`, `1` `.` `5` as `1.5`...
    fn wouldJoin(f: *const Formatter, a: usize, b: usize) bool {
        _ = a;
        // The tokens written since the last whitespace can join with `b`.
        const tail = f.out.items[@min(f.run_start, f.out.items.len)..];
        const t = f.tokens[b].text(f.source);
        var buf: [512]u8 = undefined;
        if (tail.len + t.len > buf.len) return true;
        @memcpy(buf[0..tail.len], tail);
        @memcpy(buf[tail.len..][0..t.len], t);
        var lx: lexer.Lexer = .init(buf[0 .. tail.len + t.len]);
        while (true) {
            const tok = lx.next();
            if (tok.tag == .eof or tok.start > tail.len) return true;
            if (tok.start == tail.len) return tok.end != tail.len + t.len or tok.tag != f.tokens[b].tag;
            if (tok.end > tail.len) return true; // a token spans the junction
        }
    }

    /// A blank line right before the token (after any comments).
    fn blankBeforeLast(gap: []const u8) bool {
        const tail = if (std.mem.lastIndexOf(u8, gap, "//")) |c|
            gap[(std.mem.indexOfScalarPos(u8, gap, c, '\n') orelse gap.len)..]
        else if (std.mem.lastIndexOf(u8, gap, "*/")) |c| gap[c + 2 ..] else gap;
        return std.mem.count(u8, tail, "\n") > 1;
    }

    fn isKeyword(f: *const Formatter, t: Token) bool {
        inline for (.{ "if", "for", "in", "return", "when", "states", "else", "from", "import", "export" }) |k| {
            if (f.word(t, k)) return true;
        }
        return false;
    }

    /// `p` ends an operand: an operator after it is binary.
    fn endsOperand(f: *const Formatter, p: Token) bool {
        return switch (p.tag) {
            .identifier => !f.isKeyword(p),
            .number, .string, .color, .r_paren, .r_bracket => true,
            .r_brace => true,
            else => false,
        };
    }

    fn isUnary(f: *const Formatter, i: usize) bool {
        const t = f.tokens[i];
        if (t.tag == .bang) return true;
        if (t.tag != .minus and t.tag != .plus) return false;
        return i == 0 or !f.endsOperand(f.tokens[i - 1]);
    }

    fn colonKind(f: *Formatter, i: usize) enum { binding, spaced } {
        _ = i;
        const fr = f.frame();
        if (fr.pending_ternaries > 0) return .spaced;
        if (fr.header and fr.isBlock()) return .spaced;
        return .binding;
    }

    fn spaceBetween(f: *Formatter, a: usize, b: usize) bool {
        const p = f.tokens[a];
        const t = f.tokens[b];
        const pk = f.matches[a] != std.math.maxInt(usize);
        const tk = f.matches[b] != std.math.maxInt(usize);
        // Angle brackets of `var <T>`.
        if (p.tag == .less and pk) return false;
        if (t.tag == .greater and tk) return false;
        if (t.tag == .less and tk) return true;
        if (p.tag == .greater and pk) return true;

        if (p.tag == .at or p.tag == .dot or t.tag == .dot) return false;
        if (t.tag == .semicolon or t.tag == .comma) return false;
        if (p.tag == .l_paren or t.tag == .r_paren) return false;
        if (p.tag == .l_bracket or t.tag == .r_bracket) return f.kindOf(a) == .bracket_block or (t.tag == .r_bracket and f.kindOf(b) == .bracket_block);
        if (t.tag == .l_paren) return !f.endsOperand(p) or f.isKeyword(p);
        if (t.tag == .l_bracket) return !(f.endsOperand(p) and p.tag != .r_brace) or f.isKeyword(p);
        if (p.tag == .l_brace) return f.matches[a] != b; // `{}` stays tight
        if (t.tag == .r_brace) return true;
        if (a > 0 and f.isUnary(a)) return false;
        if (t.tag == .colon) return f.colonKind(b) == .spaced;
        return true;
    }

    fn kindOf(f: *Formatter, bracket: usize) Kind {
        const open = if (isClose(f.tokens[bracket].tag)) f.matches[bracket] else bracket;
        for (f.frames.items) |fr| if (fr.close == f.matches[open]) return fr.kind;
        return .bracket;
    }

    /// Updates the bracket frames and statement state after token `i`.
    fn after(f: *Formatter, i: usize) Error!void {
        const t = f.tokens[i];
        const fr = f.frame();
        switch (t.tag) {
            .l_brace => {
                const close = f.matches[i];
                const p: ?Token = if (i > 0) f.tokens[i - 1] else null;
                const literal = if (p) |pt| switch (pt.tag) {
                    .l_paren, .comma, .equal, .l_bracket, .question, .plus_equal, .minus_equal => true,
                    .colon => f.colonKind(i - 1) == .binding,
                    // `import { A, B } from ...` lists names.
                    .identifier => f.word(pt, "return") or f.word(pt, "import") or f.word(pt, "export"),
                    else => false,
                } else false;
                const kind: Kind = if (literal) .struct_literal else if (f.sameLine(i, close)) .inline_block else .block;
                const list = i >= 2 and (f.word(f.tokens[i - 2], "struct") or f.word(f.tokens[i - 2], "enum"));
                try f.frames.append(f.gpa, .{ .kind = kind, .base = f.line_level, .close = close, .list = list });
                if (kind == .block) f.at_statement_start = true;
            },
            .l_bracket => {
                const close = f.matches[i];
                const block = i > 0 and f.word(f.tokens[i - 1], "states") and !f.sameLine(i, close);
                try f.frames.append(f.gpa, .{ .kind = if (block) .bracket_block else .bracket, .base = f.line_level, .close = close });
                if (block) f.at_statement_start = true;
            },
            .l_paren => try f.frames.append(f.gpa, .{ .kind = .paren, .base = f.line_level, .close = f.matches[i] }),
            .r_brace, .r_bracket, .r_paren => {
                const closed = f.frames.pop() orelse return error.InvalidSource;
                const outer = f.frame();
                // A block ends a statement of the enclosing block.
                const is_block = closed.kind == .block or closed.kind == .inline_block or closed.kind == .bracket_block;
                if (is_block and (outer.isBlock() or f.frames.items.len == 0)) {
                    f.at_statement_start = true;
                    outer.header = false;
                    outer.pending_ternaries = 0;
                }
            },
            .semicolon => {
                if (fr.isBlock()) f.at_statement_start = true;
                fr.header = false;
                fr.pending_ternaries = 0;
            },
            .comma => if (fr.isBlock() and fr.list) {
                f.at_statement_start = true;
            },
            .question => fr.pending_ternaries += 1,
            .colon => if (fr.pending_ternaries > 0) {
                fr.pending_ternaries -= 1;
            },
            .identifier => {
                // `@children` is a member of its own.
                if (i > 0 and f.tokens[i - 1].tag == .at and f.word(t, "children") and fr.isBlock()) {
                    f.at_statement_start = true;
                    return;
                }
                const first = i == 0 or f.statementStartsAt(i);
                if ((first and (f.word(t, "for") or f.word(t, "if"))) or f.word(t, "when")) fr.header = true;
            },
            else => {},
        }
    }

    /// Token `i` is the first of a statement in its block.
    fn statementStartsAt(f: *Formatter, i: usize) bool {
        const p = f.tokens[i - 1];
        return switch (p.tag) {
            .semicolon, .l_brace, .r_brace, .l_bracket => true,
            .comma => f.frame().isBlock() and f.frame().list,
            else => false,
        };
    }
};

// ---- Tests ----

const testing = std.testing;

fn expectFormat(input: []const u8, expected: []const u8) !void {
    const out = try format(testing.allocator, input);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
    // Formatting is idempotent.
    const again = try format(testing.allocator, out);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(out, again);
}

test "indentation, spacing and statements" {
    try expectFormat(
        \\export component  App inherits Window{
        \\var in-out <int>count:0;
        \\  callback clicked( int,string )->int;
        \\VerticalLayout{padding:8px;spacing : 4px;
        \\Text{text:"Count: \{count}";color:count>3?red:blue;}
        \\b:=Button{clicked=>{count+=1;if count>10{count=0;}
        \\else{debug(-count);}}}
        \\}
        \\}
    ,
        \\export component App inherits Window {
        \\    var in-out <int> count: 0;
        \\    callback clicked(int, string) -> int;
        \\    VerticalLayout {
        \\        padding: 8px;
        \\        spacing: 4px;
        \\        Text { text: "Count: \{count}"; color: count > 3 ? red : blue; }
        \\        b := Button {
        \\            clicked => {
        \\                count += 1;
        \\                if count > 10 { count = 0; } else { debug(-count); }
        \\            }
        \\        }
        \\    }
        \\}
        \\
    );
}

test "var declarations: their type kept together" {
    try expectFormat(
        \\component A{
        \\var<int>count:0;
        \\  var in-out<[string]>rows;
        \\var out <bool>full:count>9;}
    ,
        \\component A {
        \\    var <int> count: 0;
        \\    var in-out <[string]> rows;
        \\    var out <bool> full: count > 9;
        \\}
        \\
    );
}

test "comments, blank lines and continuation lines" {
    try expectFormat(
        \\// File comment.
        \\
        \\
        \\component A inherits Rectangle {   // trailing
        \\    /* block */ var in <bool> dark;
        \\
        \\
        \\    // About the background.
        \\    background: dark ? #000
        \\      : #fff;
        \\    Empty {}
        \\    Empty {
        \\    }
        \\}
        \\// The end.
    ,
        \\// File comment.
        \\
        \\component A inherits Rectangle { // trailing
        \\    /* block */ var in <bool> dark;
        \\
        \\    // About the background.
        \\    background: dark ? #000
        \\        : #fff;
        \\    Empty {}
        \\    Empty {}
        \\}
        \\// The end.
        \\
    );
}

test "for, if, states, structs, arrays and imports" {
    try expectFormat(
        \\import {A,B} from "lib.zge";
        \\struct P {x:int,y:string}
        \\enum Mode {light,dark}
        \\component C {
        \\var <[P]> ps:[{x:1,y:"a"},{x:2,y:"b"}];
        \\var <[int]> ns:[1,2,3];
        \\for p[i]in ps:Text{text:p.y+ns[i];}
        \\if ns.length>0:Text{}
        \\states[
        \\big when ns.length>2:{width:10px;}
        \\]
        \\Image{source:@image-url("x.png");}
        \\Image{source:@image-url("x.png",nine-slice(2 4));}
        \\Rectangle{background:@linear-gradient(90deg,red,blue 50%);border-color:@radial-gradient(circle,red,blue);}
        \\callback c();
        \\c=>{let t=0;while t<3{t+=1;if t==2{continue;}}for n[i] in ns{t+=n*i;break;}}
        \\b.clicked(x)=>{t=x;}
        \\Connections{target:b;clicked=>{}}
        \\var <[int]> big:ns.filter(n=>n>1).sort(n=>-n).reverse();
        \\}
    ,
        \\import { A, B } from "lib.zge";
        \\struct P { x: int, y: string }
        \\enum Mode { light, dark }
        \\component C {
        \\    var <[P]> ps: [{ x: 1, y: "a" }, { x: 2, y: "b" }];
        \\    var <[int]> ns: [1, 2, 3];
        \\    for p[i] in ps : Text { text: p.y + ns[i]; }
        \\    if ns.length > 0 : Text {}
        \\    states [
        \\        big when ns.length > 2 : { width: 10px; }
        \\    ]
        \\    Image { source: @image-url("x.png"); }
        \\    Image { source: @image-url("x.png", nine-slice(2 4)); }
        \\    Rectangle { background: @linear-gradient(90deg, red, blue 50%); border-color: @radial-gradient(circle, red, blue); }
        \\    callback c();
        \\    c => { let t = 0; while t < 3 { t += 1; if t == 2 { continue; } } for n[i] in ns { t += n * i; break; } }
        \\    b.clicked(x) => { t = x; }
        \\    Connections { target: b; clicked => {} }
        \\    var <[int]> big: ns.filter(n => n > 1).sort(n => -n).reverse();
        \\}
        \\
    );
}

test "multi-line struct declarations" {
    try expectFormat(
        \\struct Contact {
        \\name: string,
        \\  age: int,
        \\}
    ,
        \\struct Contact {
        \\    name: string,
        \\    age: int,
        \\}
        \\
    );
}

test "invalid source is rejected" {
    try testing.expectError(error.InvalidSource, format(testing.allocator, "component A { "));
    try testing.expectError(error.InvalidSource, format(testing.allocator, "component A ) "));
    try testing.expectError(error.InvalidSource, format(testing.allocator, "a & b"));
}

test "tokens are never joined into other tokens" {
    // Found by fuzzing: `! =` became `!=`, `1 . 100ms` became `1.100ms`.
    try expectFormat("x: ! = 1;\n", "x: ! = 1;\n");
    try expectFormat("x: a - -b;\n", "x: a - -b;\n");
    try expectFormat("x: 1 . 100ms;\n", "x: 1. 100ms;\n");
}

test "the standard widgets are formatted" {
    const std_widgets = @import("std_widgets.zig");
    for (std_widgets.styles) |style| for (std_widgets.fileNames()) |name| {
        const path = try std.fmt.allocPrint(testing.allocator, "@std/{s}", .{name});
        defer testing.allocator.free(path);
        const source = std_widgets.read(style, path) orelse continue;
        const out = try format(testing.allocator, source);
        defer testing.allocator.free(out);
        testing.expectEqualStrings(source, out) catch |err| {
            std.debug.print("{s}/{s} is not formatted\n", .{ style, name });
            return err;
        };
    };
}
