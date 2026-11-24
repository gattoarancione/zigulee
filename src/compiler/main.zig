// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! `zgec`: compiles a `.zge` file to Zig.
//!
//!     zgec input.zge -o output.zig [--dep-file=output.d] [--style=fluent]
//!     zgec fmt [--check] [--stdin] files...
//!     zgec tr [-o messages.pot] files...
//!     zgec c input.zge --prefix=app --header=app.h --glue=app_c.zig [--style=...]
//!     zgec scxml machine.scxml [-o machine.zge]
//!
//! `zgec c` writes C bindings of the compiled components (c_bindings.zig):
//! a header, and Zig code implementing it over the module `zgec` makes.
//!
//! `zgec scxml` converts an SCXML state chart to a `.zge` global holding
//! the equivalent `StateMachine` (scxml.zig), to `-o` or standard output;
//! what it cannot convert it says, and leaves as comments.
//!
//! The dependency file lists the files the input uses (images), so build
//! systems recompile when they change.

const std = @import("std");
const compiler = @import("compiler.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 1 and std.mem.eql(u8, args[1], "fmt")) return formatFiles(init, arena, args[2..]);
    if (args.len > 1 and std.mem.eql(u8, args[1], "tr")) return extractTranslations(init, arena, args[2..]);
    if (args.len > 1 and std.mem.eql(u8, args[1], "c")) return cBindings(init, arena, args[2..]);
    if (args.len > 1 and std.mem.eql(u8, args[1], "scxml")) return convertScxml(init, arena, args[2..]);
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var dep_file: ?[]const u8 = null;
    var style: []const u8 = compiler.std_widgets.default_style;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            i += 1;
            output = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--dep-file=")) {
            dep_file = args[i]["--dep-file=".len..];
        } else if (std.mem.startsWith(u8, args[i], "--style=")) {
            style = args[i]["--style=".len..];
            if (!compiler.std_widgets.isStyle(style)) {
                std.debug.print("zgec: unknown style '{s}'\n", .{style});
                return 2;
            }
        } else input = args[i];
    }
    const in_path = input orelse {
        std.debug.print("usage: zgec input.zge -o output.zig [--style=fluent|material|minimal|cupertino|native] [--dep-file=output.d]\n       zgec fmt [--check] [--stdin] files...\n       zgec tr [-o messages.pot] files...\n       zgec scxml machine.scxml [-o machine.zge]\n", .{});
        return 2;
    };
    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(init.io, in_path, arena, .limited(16 << 20)) catch |err| {
        std.debug.print("zgec: cannot read {s}: {t}\n", .{ in_path, err });
        return 1;
    };
    var files: Files = .{ .io = init.io, .dir = std.fs.path.dirname(in_path) orelse "." };
    const loader: compiler.Loader = .{ .ctx = &files, .readFn = Files.read };
    switch (try compiler.compile(arena, in_path, source, .{ .loader = loader, .style = style })) {
        .errors => |text| {
            std.debug.print("{s}", .{text});
            return 1;
        },
        .zig => |zig| {
            if (dep_file) |dep_path| {
                var dep: std.Io.Writer.Allocating = .init(arena);
                try dep.writer.print("{s}: {s}", .{ output orelse "-", in_path });
                for (files.used.items) |f| try dep.writer.print(" {s}", .{f});
                try dep.writer.writeByte('\n');
                try cwd.writeFile(init.io, .{ .sub_path = dep_path, .data = dep.written() });
            }
            if (output) |out_path| {
                try cwd.writeFile(init.io, .{ .sub_path = out_path, .data = zig });
            } else {
                var buf: [4096]u8 = undefined;
                var stdout = std.Io.File.stdout().writer(init.io, &buf);
                try stdout.interface.writeAll(zig);
                try stdout.interface.flush();
            }
            return 0;
        },
    }
}

/// Reads files relative to the input's directory, remembering them for the
/// dependency file.
const Files = struct {
    io: std.Io,
    dir: []const u8,
    used: std.ArrayList([]const u8) = .empty,

    fn read(ctx: ?*anyopaque, arena: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
        const self: *Files = @ptrCast(@alignCast(ctx.?));
        const full = try std.fs.path.join(arena, &.{ self.dir, path });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, full, arena, .limited(64 << 20));
        try self.used.append(arena, full);
        return bytes;
    }
};

/// `zgec fmt`: formats files in place, or with `--check` lists the files
/// that are not formatted (and fails). `--stdin` formats standard input to
/// standard output.
fn formatFiles(init: std.process.Init, arena: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    var check = false;
    var stdin = false;
    var paths: std.ArrayList([]const u8) = .empty;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, a, "--stdin")) {
            stdin = true;
        } else try paths.append(arena, a);
    }
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    const out = &stdout.interface;
    if (stdin) {
        var in_buf: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().reader(init.io, &in_buf);
        const source = try reader.interface.allocRemaining(arena, .limited(16 << 20));
        const formatted = compiler.format(arena, source) catch {
            std.debug.print("zgec fmt: cannot format the input (unbalanced brackets or invalid characters)\n", .{});
            return 1;
        };
        try out.writeAll(formatted);
        try out.flush();
        return 0;
    }
    if (paths.items.len == 0) {
        std.debug.print("usage: zgec fmt [--check] [--stdin] files...\n", .{});
        return 2;
    }
    const cwd = std.Io.Dir.cwd();
    var status: u8 = 0;
    for (paths.items) |path| {
        const source = cwd.readFileAlloc(init.io, path, arena, .limited(16 << 20)) catch |err| {
            std.debug.print("zgec fmt: cannot read {s}: {t}\n", .{ path, err });
            status = 1;
            continue;
        };
        const formatted = compiler.format(arena, source) catch {
            std.debug.print("zgec fmt: cannot format {s} (unbalanced brackets or invalid characters)\n", .{path});
            status = 1;
            continue;
        };
        if (std.mem.eql(u8, source, formatted)) continue;
        if (check) {
            try out.print("{s}\n", .{path});
            status = 1;
        } else {
            try cwd.writeFile(init.io, .{ .sub_path = path, .data = formatted });
            try out.print("{s}\n", .{path});
        }
    }
    try out.flush();
    return status;
}

/// `zgec tr`: writes the `@tr` messages of the files as a gettext template
/// (to `-o`, or standard output).
fn extractTranslations(init: std.process.Init, arena: std.mem.Allocator, args: []const []const u8) !u8 {
    var output: ?[]const u8 = null;
    var files: std.ArrayList(compiler.tr_extract.File) = .empty;
    const cwd = std.Io.Dir.cwd();
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            i += 1;
            output = args[i];
            continue;
        }
        const source = cwd.readFileAlloc(init.io, args[i], arena, .limited(16 << 20)) catch |err| {
            std.debug.print("zgec tr: cannot read {s}: {t}\n", .{ args[i], err });
            return 1;
        };
        try files.append(arena, .{ .name = args[i], .source = source });
    }
    if (files.items.len == 0) {
        std.debug.print("usage: zgec tr [-o messages.pot] files...\n", .{});
        return 2;
    }
    switch (try compiler.tr_extract.extract(arena, files.items)) {
        .errors => |text| {
            std.debug.print("{s}", .{text});
            return 1;
        },
        .pot => |pot| {
            if (output) |path| {
                try cwd.writeFile(init.io, .{ .sub_path = path, .data = pot });
            } else {
                var buf: [4096]u8 = undefined;
                var stdout = std.Io.File.stdout().writer(init.io, &buf);
                try stdout.interface.writeAll(pot);
                try stdout.interface.flush();
            }
            return 0;
        },
    }
}

fn cBindings(init: std.process.Init, arena: std.mem.Allocator, args: []const []const u8) !u8 {
    var input: ?[]const u8 = null;
    var prefix: ?[]const u8 = null;
    var header: ?[]const u8 = null;
    var glue: ?[]const u8 = null;
    var style: []const u8 = compiler.std_widgets.default_style;
    for (args) |a| {
        if (std.mem.startsWith(u8, a, "--prefix=")) {
            prefix = a["--prefix=".len..];
        } else if (std.mem.startsWith(u8, a, "--header=")) {
            header = a["--header=".len..];
        } else if (std.mem.startsWith(u8, a, "--glue=")) {
            glue = a["--glue=".len..];
        } else if (std.mem.startsWith(u8, a, "--style=")) {
            style = a["--style=".len..];
        } else input = a;
    }
    const in_path = input orelse {
        std.debug.print("usage: zgec c input.zge --prefix=app --header=app.h --glue=app_c.zig [--style=fluent]\n", .{});
        return 2;
    };
    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(init.io, in_path, arena, .limited(16 << 20)) catch |err| {
        std.debug.print("zgec: cannot read {s}: {t}\n", .{ in_path, err });
        return 1;
    };
    var files: Files = .{ .io = init.io, .dir = std.fs.path.dirname(in_path) orelse "." };
    const loader: compiler.Loader = .{ .ctx = &files, .readFn = Files.read };
    const base = std.fs.path.stem(in_path);
    const header_path = header orelse try std.fmt.allocPrint(arena, "{s}.h", .{base});
    switch (try compiler.cBindings(arena, in_path, source, .{ .loader = loader, .style = style }, prefix orelse base, std.fs.path.basename(header_path))) {
        .errors => |text| {
            std.debug.print("{s}", .{text});
            return 1;
        },
        .bindings => |out| {
            try cwd.writeFile(init.io, .{ .sub_path = header_path, .data = out.header });
            try cwd.writeFile(init.io, .{ .sub_path = glue orelse try std.fmt.allocPrint(arena, "{s}_c.zig", .{base}), .data = out.glue });
            return 0;
        },
    }
}

/// `zgec scxml`: an SCXML document as a `.zge` global (to `-o`, or
/// standard output); warnings, with their lines, to standard error.
fn convertScxml(init: std.process.Init, arena: std.mem.Allocator, args: []const []const u8) !u8 {
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            i += 1;
            output = args[i];
        } else input = args[i];
    }
    const in_path = input orelse {
        std.debug.print("usage: zgec scxml machine.scxml [-o machine.zge]\n", .{});
        return 2;
    };
    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(init.io, in_path, arena, .limited(16 << 20)) catch |err| {
        std.debug.print("zgec scxml: cannot read {s}: {t}\n", .{ in_path, err });
        return 1;
    };
    switch (try compiler.scxml.convert(arena, in_path, source)) {
        .errors => |text| {
            std.debug.print("{s}", .{text});
            return 1;
        },
        .zge => |z| {
            for (z.warnings) |w| std.debug.print("{s}:{d}: warning: {s}\n", .{ in_path, w.line, w.message });
            if (output) |path| {
                try cwd.writeFile(init.io, .{ .sub_path = path, .data = z.text });
            } else {
                var buf: [4096]u8 = undefined;
                var stdout = std.Io.File.stdout().writer(init.io, &buf);
                try stdout.interface.writeAll(z.text);
                try stdout.interface.flush();
            }
            return 0;
        },
    }
}
