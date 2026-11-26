// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The `.zge` compiler: source text in, Zig source (or diagnostics) out.

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Diagnostics = @import("diagnostics.zig").Diagnostics;
pub const Parser = @import("parser.zig").Parser;
pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const types = @import("types.zig");
pub const anchors = @import("anchors.zig");
pub const codegen = @import("codegen.zig");
const Generator = @import("codegen.zig").Generator;
pub const std_widgets = @import("std_widgets.zig");
pub const format = @import("format.zig").format;
pub const index = @import("index.zig");
pub const Index = index.Index;
pub const tr_extract = @import("tr_extract.zig");
pub const scxml = @import("scxml.zig");
pub const xml = @import("xml.zig");
/// Fuzz targets, for tools/fuzz.zig.
pub const fuzz_targets = @import("fuzz_test.zig");

/// Reads files the document refers to (images), relative to the .zge file.
pub const Loader = struct {
    ctx: ?*anyopaque = null,
    readFn: *const fn (ctx: ?*anyopaque, arena: Allocator, path: []const u8) anyerror![]const u8,

    pub fn read(l: Loader, arena: Allocator, path: []const u8) anyerror![]const u8 {
        return l.readFn(l.ctx, arena, path);
    }

    /// For sources that use no files.
    pub const none: Loader = .{ .readFn = struct {
        fn f(_: ?*anyopaque, _: Allocator, _: []const u8) anyerror![]const u8 {
            return error.FileNotFound;
        }
    }.f };
};

pub const Result = union(enum) {
    /// Generated Zig source.
    zig: []const u8,
    /// Rendered error messages.
    errors: []const u8,
};

pub const Options = struct {
    loader: Loader = .none,
    /// Filled with what names refer to (editor tooling).
    index: ?*Index = null,
    /// Style of the built-in `std-widgets.zge` (see `std_widgets.styles`).
    style: []const u8 = std_widgets.default_style,
};

/// Compiles `source`. Everything is allocated in `arena`.
pub fn compile(arena: Allocator, file_name: []const u8, source: []const u8, options: Options) Allocator.Error!Result {
    var diags: Diagnostics = .{ .arena = arena };
    _ = try diags.addFile(file_name, source);
    var parser: Parser = .init(arena, source, &diags);
    const doc = parser.parseDocument() catch |err| switch (err) {
        error.ParseError => return .{ .errors = try render(arena, &diags) },
        else => |e| return e,
    };
    var gen: Generator = .init(arena, &diags, &doc);
    gen.loader = options.loader;
    gen.style = options.style;
    gen.index = options.index;
    const zig = gen.generate(file_name) catch |err| switch (err) {
        error.CompileError => return .{ .errors = try render(arena, &diags) },
        else => |e| return e,
    };
    return .{ .zig = zig };
}

pub const c_bindings = @import("c_bindings.zig");

pub const CResult = union(enum) {
    bindings: c_bindings.Output,
    errors: []const u8,
};

/// The C bindings of `source`'s compiled components (see c_bindings.zig);
/// names start with `prefix`.
pub fn cBindings(arena: Allocator, file_name: []const u8, source: []const u8, options: Options, prefix: []const u8, header_name: []const u8) Allocator.Error!CResult {
    var diags: Diagnostics = .{ .arena = arena };
    _ = try diags.addFile(file_name, source);
    var parser: Parser = .init(arena, source, &diags);
    const doc = parser.parseDocument() catch |err| switch (err) {
        error.ParseError => return .{ .errors = try render(arena, &diags) },
        else => |e| return e,
    };
    var gen: Generator = .init(arena, &diags, &doc);
    gen.loader = options.loader;
    gen.style = options.style;
    _ = gen.generate(file_name) catch |err| switch (err) {
        error.CompileError => return .{ .errors = try render(arena, &diags) },
        else => |e| return e,
    };
    return .{ .bindings = try c_bindings.generate(arena, &gen, prefix, header_name, std.fs.path.basename(file_name)) };
}

pub const Diagnostic = @import("diagnostics.zig").Diagnostic;
pub const File = @import("diagnostics.zig").File;
pub const location = @import("diagnostics.zig").location;

/// Diagnostics with locations, for editor tooling.
pub const Analysis = struct {
    diagnostics: []const Diagnostic,
    /// The files diagnostics refer to; the main file is first.
    files: []const File,
    /// False if the main file has syntax errors (nothing else was checked).
    parsed: bool,
};

/// Checks `source` like `compile`, without generating code (and filling
/// `options.index`).
pub fn analyze(arena: Allocator, file_name: []const u8, source: []const u8, options: Options) Allocator.Error!Analysis {
    var diags: Diagnostics = .{ .arena = arena };
    _ = try diags.addFile(file_name, source);
    var parser: Parser = .init(arena, source, &diags);
    const doc = parser.parseDocument() catch |err| switch (err) {
        error.ParseError => return .{ .diagnostics = diags.list.items, .files = diags.files.items, .parsed = false },
        else => |e| return e,
    };
    var gen: Generator = .init(arena, &diags, &doc);
    gen.loader = options.loader;
    gen.style = options.style;
    gen.index = options.index;
    _ = gen.generate(file_name) catch |err| switch (err) {
        error.CompileError => {},
        else => |e| return e,
    };
    return .{ .diagnostics = diags.list.items, .files = diags.files.items, .parsed = true };
}

fn render(arena: Allocator, diags: *const Diagnostics) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    diags.render(&out.writer) catch return error.OutOfMemory;
    return out.written();
}

test {
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("diagnostics.zig");
    _ = @import("compiler_test.zig");
    _ = @import("std_widgets.zig");
    _ = @import("format.zig");
    _ = @import("xml.zig");
    _ = @import("scxml_test.zig");
    _ = tr_extract;
    _ = @import("fuzz_test.zig");
}
