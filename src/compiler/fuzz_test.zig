// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Fuzz targets of the compiler and the formatter (see core/fuzz.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const fuzz = @import("zigulee").core.fuzz;
const Target = fuzz.Target;
const Input = fuzz.Input;
const compiler = @import("compiler.zig");
const lexer = @import("lexer.zig");

pub const targets = [_]Target{
    .{ .name = "compile-bytes", .run = compileBytes, .corpus = &corpus },
    .{ .name = "compile-tokens", .run = compileTokens, .corpus = &.{ "", "\x00\x01\x02\x03\x04\x05\x06\x07" } },
    .{ .name = "format", .run = formatting, .corpus = &corpus },
};

test "fuzz targets on their corpus" {
    inline for (targets) |t| try fuzz.runCorpus(t);
}

const corpus = [_][]const u8{
    "",
    "export component A inherits Window { width: 10px; Text { text: \"hi\"; } }",
    "component B inherits Rectangle { var in <int> n; callback c(int) -> int; c(x) => { return x + n; } }",
    "struct P { a: int, b: string } enum E { x, y } export component C { var <[P]> ps: [{ a: 1 }]; for p[i] in ps : Text { text: p.b + i; } }",
    "global G { var in-out <bool> on; } export component D { if G.on : Rectangle { states [ s when true : { width: 1px; } ] } }",
    "component E { VerticalLayout { @children } public function f(a: int) -> int { return a * 2; } }",
};

/// Compiling must not crash on any input (with an index, as the language
/// server does).
fn compileAny(gpa: Allocator, source: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ix: compiler.Index = .{ .arena = arena.allocator() };
    _ = try compiler.compile(arena.allocator(), "fuzz.zge", source, .{ .index = &ix });
    _ = try compiler.analyze(arena.allocator(), "fuzz.zge", source, .{ .index = &ix });
}

/// Compiling any bytes fails cleanly or succeeds.
pub fn compileBytes(gpa: Allocator, s: *Input) !void {
    var buf: [512]u8 = undefined;
    try compileAny(gpa, buf[0..s.slice(&buf)]);
}

/// Words of the language, to build token sequences that get past the
/// lexer into the parser and the analysis.
const vocabulary = [_][]const u8{
    "component", "Connections", "SequentialAnimation", "PropertyAnimation", "spring",         "filter",           "sort",       "reverse",    "DragArea",      "DropArea",   "PinchArea", "SwipeArea",   "Shortcut", "StackView", "SwipeView",  "StackLayout", "SplitView", "TreeState", "Selection", "FlowLayout", "ListLayout", "TableRow", "StyledText", "map",     "sequence", "target", "export", "inherits", "global", "struct", "enum",    "import",  "from",       "\"lib.zge\"",
    "Window",    "Rectangle",   "Text",                "TouchArea",         "VerticalLayout", "HorizontalLayout", "GridLayout", "Row",        "Flickable",     "TextInput",  "Timer",     "PopupWindow", "Path",     "Image",     "FocusScope", "property",    "var",       "in",        "out",       "in-out",     "private",    "callback", "function",   "public",  "return",   "if",     "else",   "for",      "states", "when",   "animate", "changed", "duration",   "easing",
    "root",      "self",        "parent",              "a",                 "b",              "x",                "width",      "height",     "text",          "background", "clicked",   "Key",         "int",      "float",     "bool",       "string",      "length",    "color",     "brush",     "<",          ">",          "{",        "}",          "(",       ")",        "[",      "]",      ";",        ":",      ":=",     "<=>",     "=>",      "->",         "=",
    "+=",        ",",           ".",                   "?",                 "+",              "-",                "*",          "/",          "==",            "!=",         "&&",        "||",          "!",        "@",         "children",   "image-url",   "1",         "2.5",       "10px",      "50%",        "100ms",      "\"s\"",    "\"\\{x}\"",  "#ff0000", "true",     "false",  "red",    "\n",       "// c\n", "@tr",    "|",       "%",       "\"{} {n}\"", "Audio",
    "audio-url", "Video",       "video-url",           "let",               "while",          "break",            "continue",   "nine-slice", "AnimatedImage", "Loader",     "source",    "component",
};

fn tokenSoup(gpa: Allocator, s: *Input, out: *std.ArrayList(u8)) !void {
    var n: usize = 0;
    while (!s.eos() and n < 80) : (n += 1) {
        try out.appendSlice(gpa, vocabulary[s.index(vocabulary.len)]);
        try out.append(gpa, ' ');
    }
}

/// Compiling sequences of language words fails cleanly or succeeds.
pub fn compileTokens(gpa: Allocator, s: *Input) !void {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try tokenSoup(gpa, s, &src);
    try compileAny(gpa, src.items);
}

/// The formatter only changes whitespace: same tokens (and comments), and
/// formatting again changes nothing.
fn checkFormat(gpa: Allocator, source: []const u8) !void {
    const out = compiler.format(gpa, source) catch |err| switch (err) {
        error.InvalidSource => return,
        else => |e| return e,
    };
    defer gpa.free(out);
    var a: lexer.Lexer = .init(source);
    var b: lexer.Lexer = .init(out);
    while (true) {
        const ta = a.next();
        const tb = b.next();
        try testing.expectEqual(ta.tag, tb.tag);
        try testing.expectEqualStrings(ta.text(source), tb.text(out));
        if (ta.tag == .eof) break;
    }
    const again = try compiler.format(gpa, out);
    defer gpa.free(again);
    try testing.expectEqualStrings(out, again);
}

pub fn formatting(gpa: Allocator, s: *Input) !void {
    if (s.value(bool)) {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try tokenSoup(gpa, s, &src);
        try checkFormat(gpa, src.items);
    } else {
        var buf: [256]u8 = undefined;
        try checkFormat(gpa, buf[0..s.slice(&buf)]);
    }
}
