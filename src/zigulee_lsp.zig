// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! `zigulee-lsp`: the `.zge` language server, speaking LSP on stdin/stdout.

const std = @import("std");
const Server = @import("lsp/server.zig").Server;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var in_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &in_buf);
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    var server: Server = .init(gpa, init.io, &stdout.interface);
    defer server.deinit();
    @import("zigulee-interpreter").warnOnBindingLoops();
    // The built-in widgets' sources go in the user's cache directory.
    const env = init.environ_map;
    const cache: ?[]const u8 = if (env.get("XDG_CACHE_HOME")) |x|
        try std.fs.path.join(init.arena.allocator(), &.{ x, "zigulee-lsp", "std" })
    else if (env.get("LOCALAPPDATA")) |l|
        try std.fs.path.join(init.arena.allocator(), &.{ l, "zigulee-lsp", "std" })
    else if (env.get("HOME")) |h|
        try std.fs.path.join(init.arena.allocator(), &.{ h, ".cache", "zigulee-lsp", "std" })
    else
        null;
    server.std_dir = cache;
    while (!server.exited) {
        const body = try Server.readMessage(gpa, &stdin.interface) orelse break;
        defer gpa.free(body);
        server.handle(body) catch |err| std.log.err("zigulee-lsp: {t}", .{err});
    }
    return server.exitCode();
}

test {
    _ = @import("lsp/server.zig");
    _ = @import("lsp/server_test.zig");
}
