// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Compiler error messages with source locations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Span = @import("ast.zig").Span;

pub const Diagnostic = struct {
    span: Span,
    message: []const u8,
    /// Index into `Diagnostics.files`.
    file: u16,
};

pub const File = struct {
    name: []const u8,
    source: []const u8,
};

pub const Diagnostics = struct {
    arena: Allocator,
    list: std.ArrayList(Diagnostic) = .empty,
    /// The source files spans refer to (the main file and its imports).
    files: std.ArrayList(File) = .empty,
    /// The file new diagnostics are about.
    current: u16 = 0,

    pub fn addFile(d: *Diagnostics, name: []const u8, source: []const u8) Allocator.Error!u16 {
        try d.files.append(d.arena, .{ .name = name, .source = source });
        return @intCast(d.files.items.len - 1);
    }

    pub fn add(d: *Diagnostics, span: Span, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const message = try std.fmt.allocPrint(d.arena, fmt, args);
        try d.list.append(d.arena, .{ .span = span, .message = message, .file = d.current });
    }

    pub fn hasErrors(d: *const Diagnostics) bool {
        return d.list.items.len > 0;
    }

    /// Writes `file:line:col: error: message`, the source line and a marker
    /// under the span, for each diagnostic.
    pub fn render(d: *const Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (d.list.items) |diag| {
            const f = d.files.items[diag.file];
            const file = f.name;
            const source = f.source;
            const loc = location(source, diag.span.start);
            try w.print("{s}:{d}:{d}: error: {s}\n", .{ file, loc.line, loc.column, diag.message });
            const line = source[loc.line_start..loc.line_end];
            try w.print("    {s}\n    ", .{line});
            for (line[0 .. loc.column - 1]) |ch| try w.writeByte(if (ch == '\t') '\t' else ' ');
            const end = @min(diag.span.end, loc.line_end);
            const width = @max(1, end -| diag.span.start);
            try w.writeByte('^');
            for (1..width) |_| try w.writeByte('~');
            try w.writeByte('\n');
        }
    }
};

pub const Location = struct {
    line: u32,
    column: u32,
    line_start: u32,
    line_end: u32,
};

pub fn location(source: []const u8, offset: u32) Location {
    var line: u32 = 1;
    var line_start: u32 = 0;
    for (source[0..@min(offset, source.len)], 0..) |ch, i| {
        if (ch == '\n') {
            line += 1;
            line_start = @intCast(i + 1);
        }
    }
    var line_end = line_start;
    while (line_end < source.len and source[line_end] != '\n') line_end += 1;
    return .{ .line = line, .column = offset - line_start + 1, .line_start = line_start, .line_end = line_end };
}

test "render points at the span" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostics = .{ .arena = arena.allocator() };
    const source = "a\n  bad thing\n";
    _ = try d.addFile("x.zge", source);
    try d.add(.{ .start = 4, .end = 7 }, "unknown name '{s}'", .{"bad"});
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try d.render(&out.writer);
    try std.testing.expectEqualStrings(
        \\x.zge:2:3: error: unknown name 'bad'
        \\      bad thing
        \\      ^~~
        \\
    , out.written());
}
