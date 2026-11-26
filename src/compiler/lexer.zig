// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Tokenizer for `.zge` source.
//!
//! Identifiers may contain dashes (`border-radius`, `in-out`) when the dash
//! is followed by a letter, so `a - b` and `x-1` are subtractions but
//! `in-out` is one name. Numbers carry their unit (`10px`, `200ms`, `50%`).
//! Strings are kept raw (escapes and `\{...}` interpolation are handled by
//! the parser).

const std = @import("std");

pub const Tag = enum {
    identifier,
    number,
    string,
    color,
    l_brace,
    r_brace,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    less,
    greater,
    less_equal,
    greater_equal,
    semicolon,
    colon,
    colon_equal,
    comma,
    dot,
    two_way,
    fat_arrow,
    arrow,
    equal,
    equal_equal,
    bang_equal,
    bang,
    and_and,
    or_or,
    question,
    plus,
    minus,
    star,
    slash,
    plus_equal,
    minus_equal,
    star_equal,
    slash_equal,
    at,
    /// `|` and `%`: only in `@tr("one" | "many" % n)`.
    pipe,
    percent,
    eof,
    invalid,

    pub fn describe(t: Tag) []const u8 {
        return switch (t) {
            .identifier => "a name",
            .number => "a number",
            .string => "a string",
            .color => "a color",
            .l_brace => "'{'",
            .r_brace => "'}'",
            .l_paren => "'('",
            .r_paren => "')'",
            .l_bracket => "'['",
            .r_bracket => "']'",
            .less => "'<'",
            .greater => "'>'",
            .less_equal => "'<='",
            .greater_equal => "'>='",
            .semicolon => "';'",
            .colon => "':'",
            .colon_equal => "':='",
            .comma => "','",
            .dot => "'.'",
            .two_way => "'<=>'",
            .fat_arrow => "'=>'",
            .arrow => "'->'",
            .equal => "'='",
            .equal_equal => "'=='",
            .bang_equal => "'!='",
            .bang => "'!'",
            .and_and => "'&&'",
            .or_or => "'||'",
            .question => "'?'",
            .plus => "'+'",
            .minus => "'-'",
            .star => "'*'",
            .slash => "'/'",
            .plus_equal => "'+='",
            .minus_equal => "'-='",
            .star_equal => "'*='",
            .slash_equal => "'/='",
            .at => "'@'",
            .pipe => "'|'",
            .percent => "'%'",
            .eof => "the end of the file",
            .invalid => "an invalid character",
        };
    }
};

pub const Token = struct {
    tag: Tag,
    start: u32,
    end: u32,

    pub fn text(t: Token, source: []const u8) []const u8 {
        return source[t.start..t.end];
    }
};

pub const Lexer = struct {
    source: []const u8,
    pos: u32 = 0,
    /// Tokenizing stops here (for re-lexing part of a source).
    end: u32,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source, .end = @intCast(source.len) };
    }

    /// Tokenizes `source[start..end]`, with offsets into all of `source`.
    pub fn initRange(source: []const u8, start: u32, end: u32) Lexer {
        return .{ .source = source, .pos = start, .end = end };
    }

    fn peekAt(l: *const Lexer, offset: u32) u8 {
        const i = l.pos + offset;
        return if (i < l.end) l.source[i] else 0;
    }

    fn skipTrivia(l: *Lexer) void {
        while (l.pos < l.end) {
            const ch = l.source[l.pos];
            if (std.ascii.isWhitespace(ch)) {
                l.pos += 1;
            } else if (ch == '/' and l.peekAt(1) == '/') {
                while (l.pos < l.end and l.source[l.pos] != '\n') l.pos += 1;
            } else if (ch == '/' and l.peekAt(1) == '*') {
                l.pos += 2;
                while (l.pos < l.end and !(l.source[l.pos] == '*' and l.peekAt(1) == '/')) l.pos += 1;
                l.pos = @min(l.pos + 2, l.end);
            } else break;
        }
    }

    pub fn next(l: *Lexer) Token {
        l.skipTrivia();
        const start = l.pos;
        if (l.pos >= l.end) return .{ .tag = .eof, .start = start, .end = start };
        const ch = l.source[l.pos];
        l.pos += 1;
        const tag: Tag = switch (ch) {
            'a'...'z', 'A'...'Z', '_' => blk: {
                while (l.pos < l.end) {
                    const c = l.source[l.pos];
                    if (std.ascii.isAlphanumeric(c) or c == '_') {
                        l.pos += 1;
                    } else if (c == '-' and (std.ascii.isAlphabetic(l.peekAt(1)) or l.peekAt(1) == '_')) {
                        l.pos += 1;
                    } else break;
                }
                break :blk .identifier;
            },
            '0'...'9' => blk: {
                while (std.ascii.isDigit(l.peekAt(0))) l.pos += 1;
                if (l.peekAt(0) == '.' and std.ascii.isDigit(l.peekAt(1))) {
                    l.pos += 1;
                    while (std.ascii.isDigit(l.peekAt(0))) l.pos += 1;
                }
                // Unit suffix: px, ms, s, %, deg, ...
                while (std.ascii.isAlphabetic(l.peekAt(0)) or l.peekAt(0) == '%') l.pos += 1;
                break :blk .number;
            },
            '"' => l.string(),
            '#' => blk: {
                while (std.ascii.isHex(l.peekAt(0))) l.pos += 1;
                break :blk .color;
            },
            '{' => .l_brace,
            '}' => .r_brace,
            '(' => .l_paren,
            ')' => .r_paren,
            '[' => .l_bracket,
            ']' => .r_bracket,
            ';' => .semicolon,
            ',' => .comma,
            '.' => .dot,
            '?' => .question,
            '@' => .at,
            ':' => if (l.match('=')) .colon_equal else .colon,
            '<' => if (l.peekAt(0) == '=' and l.peekAt(1) == '>') blk: {
                l.pos += 2;
                break :blk .two_way;
            } else if (l.match('=')) .less_equal else .less,
            '>' => if (l.match('=')) .greater_equal else .greater,
            '=' => if (l.match('>')) .fat_arrow else if (l.match('=')) .equal_equal else .equal,
            '!' => if (l.match('=')) .bang_equal else .bang,
            '&' => if (l.match('&')) .and_and else .invalid,
            '|' => if (l.match('|')) .or_or else .pipe,
            '%' => .percent,
            '+' => if (l.match('=')) .plus_equal else .plus,
            '-' => if (l.match('>')) .arrow else if (l.match('=')) .minus_equal else .minus,
            '*' => if (l.match('=')) .star_equal else .star,
            '/' => if (l.match('=')) .slash_equal else .slash,
            else => .invalid,
        };
        return .{ .tag = tag, .start = start, .end = l.pos };
    }

    fn match(l: *Lexer, ch: u8) bool {
        if (l.peekAt(0) != ch) return false;
        l.pos += 1;
        return true;
    }

    /// After the opening quote. Skips escapes, and `\{...}` interpolations
    /// (which may contain braces and strings).
    fn string(l: *Lexer) Tag {
        while (l.pos < l.end) {
            const ch = l.source[l.pos];
            l.pos += 1;
            switch (ch) {
                '"' => return .string,
                '\n' => return .invalid,
                '\\' => {
                    if (l.pos >= l.end) return .invalid;
                    const esc = l.source[l.pos];
                    l.pos += 1;
                    if (esc == '{') {
                        var depth: u32 = 1;
                        while (l.pos < l.end and depth > 0) {
                            const c = l.source[l.pos];
                            l.pos += 1;
                            switch (c) {
                                '{' => depth += 1,
                                '}' => depth -= 1,
                                '"' => _ = l.string(),
                                '\n' => return .invalid,
                                else => {},
                            }
                        }
                    }
                },
                else => {},
            }
        }
        return .invalid;
    }
};

const testing = std.testing;

fn expectTokens(source: []const u8, expected: []const struct { Tag, []const u8 }) !void {
    var l: Lexer = .init(source);
    for (expected) |e| {
        const t = l.next();
        try testing.expectEqual(e[0], t.tag);
        try testing.expectEqualStrings(e[1], t.text(source));
    }
    try testing.expectEqual(Tag.eof, l.next().tag);
}

test "names with dashes, numbers with units, colors" {
    try expectTokens("var in-out <length> border-radius: 10px;", &.{
        .{ .identifier, "var" },    .{ .identifier, "in-out" }, .{ .less, "<" },
        .{ .identifier, "length" }, .{ .greater, ">" },         .{ .identifier, "border-radius" },
        .{ .colon, ":" },           .{ .number, "10px" },       .{ .semicolon, ";" },
    });
    try expectTokens("x-1 a - b c-d 1.5 50% 200ms #ff00aa", &.{
        .{ .identifier, "x" },   .{ .minus, "-" },       .{ .number, "1" },
        .{ .identifier, "a" },   .{ .minus, "-" },       .{ .identifier, "b" },
        .{ .identifier, "c-d" }, .{ .number, "1.5" },    .{ .number, "50%" },
        .{ .number, "200ms" },   .{ .color, "#ff00aa" },
    });
}

test "operators and comments" {
    try expectTokens("a <=> b => c -> d := e == f != g <= h >= i && j || !k += -= *= /= // comment\n /* block */ ?", &.{
        .{ .identifier, "a" },  .{ .two_way, "<=>" },    .{ .identifier, "b" },  .{ .fat_arrow, "=>" },
        .{ .identifier, "c" },  .{ .arrow, "->" },       .{ .identifier, "d" },  .{ .colon_equal, ":=" },
        .{ .identifier, "e" },  .{ .equal_equal, "==" }, .{ .identifier, "f" },  .{ .bang_equal, "!=" },
        .{ .identifier, "g" },  .{ .less_equal, "<=" },  .{ .identifier, "h" },  .{ .greater_equal, ">=" },
        .{ .identifier, "i" },  .{ .and_and, "&&" },     .{ .identifier, "j" },  .{ .or_or, "||" },
        .{ .bang, "!" },        .{ .identifier, "k" },   .{ .plus_equal, "+=" }, .{ .minus_equal, "-=" },
        .{ .star_equal, "*=" }, .{ .slash_equal, "/=" }, .{ .question, "?" },
    });
}

test "strings with escapes and interpolation" {
    try expectTokens(
        \\"plain" "with \"quote\"" "count: \{a + b} items" "nested \{f("x}")}"
    , &.{
        .{ .string, "\"plain\"" },
        .{ .string, "\"with \\\"quote\\\"\"" },
        .{ .string, "\"count: \\{a + b} items\"" },
        .{ .string, "\"nested \\{f(\"x}\")}\"" },
    });
    var l: Lexer = .init("\"unterminated");
    try testing.expectEqual(Tag.invalid, l.next().tag);
}
