// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Typed callbacks (the `callback name(args) -> ret;` construct).

const std = @import("std");

/// A callback slot with signature `Fn`, e.g. `Callback(fn (i32) bool)`.
/// Handlers receive a context pointer followed by `Fn`'s parameters.
pub fn Callback(comptime Fn: type) type {
    const info = @typeInfo(Fn).@"fn";
    const Ret = info.return_type.?;

    return struct {
        const Self = @This();
        pub const Args = std.meta.ArgsTuple(Fn);

        // Two words: no handler is a null `func` (not an optional struct,
        // which would need a third word for its tag).
        ctx: ?*anyopaque = null,
        func: ?*const fn (?*anyopaque, Args) Ret = null,

        /// Sets a handler `f(ctx, args...)`. `ctx` must be a pointer.
        pub fn setHandler(self: *Self, ctx: anytype, comptime f: anytype) void {
            const Ctx = @TypeOf(ctx);
            comptime std.debug.assert(@typeInfo(Ctx) == .pointer);
            const W = struct {
                fn call(p: ?*anyopaque, args: Args) Ret {
                    const c: Ctx = @ptrCast(@alignCast(p.?));
                    return @call(.auto, f, .{c} ++ args);
                }
            };
            self.* = .{ .ctx = @ptrCast(@constCast(ctx)), .func = W.call };
        }

        /// Sets a handler with no context: a plain function of type `Fn`.
        pub fn setHandlerFn(self: *Self, comptime f: Fn) void {
            const W = struct {
                fn call(_: ?*anyopaque, args: Args) Ret {
                    return @call(.auto, f, args);
                }
            };
            self.* = .{ .ctx = null, .func = W.call };
        }

        pub fn clearHandler(self: *Self) void {
            self.* = .{};
        }

        pub fn hasHandler(self: *const Self) bool {
            return self.func != null;
        }

        /// Invokes the handler. Without a handler, returns the zero value of
        /// the return type (like an unhandled Slint callback).
        pub fn call(self: *const Self, args: Args) Ret {
            if (self.func) |f| return f(self.ctx, args);
            if (Ret == void) return;
            return std.mem.zeroes(Ret);
        }
    };
}

/// A handler added to a `Callback(Fn)` without replacing the one it has
/// (`Connections` in `.zge`): when the callback is called, its handler
/// runs (and gives the result), then the connections, latest last.
/// Connections chain inside the callback; `disconnect` takes one out
/// wherever it is. Setting the callback's handler afterwards replaces the
/// chain.
pub fn Connection(comptime Fn: type) type {
    const info = @typeInfo(Fn).@"fn";
    const Ret = info.return_type.?;
    const Cb = Callback(Fn);

    return struct {
        const Self = @This();

        target: ?*Cb = null,
        /// What the callback had before.
        prev: Cb = .{},
        ctx: ?*anyopaque = null,
        func: ?*const fn (?*anyopaque, Cb.Args) void = null,

        /// Adds `f(ctx, args...)` to `cb`. `ctx` must be a pointer.
        pub fn connect(self: *Self, cb: *Cb, ctx: anytype, comptime f: anytype) void {
            const Ctx = @TypeOf(ctx);
            const W = struct {
                fn call(p: ?*anyopaque, args: Cb.Args) void {
                    const c: Ctx = @ptrCast(@alignCast(p.?));
                    @call(.auto, f, .{c} ++ args);
                }
            };
            self.disconnect();
            self.* = .{ .target = cb, .prev = cb.*, .ctx = @ptrCast(@constCast(ctx)), .func = W.call };
            cb.* = .{ .ctx = self, .func = run };
        }

        /// Takes this connection out of its callback's chain.
        pub fn disconnect(self: *Self) void {
            const cb = self.target orelse return;
            self.target = null;
            // The link pointing at this one: the callback itself, or a
            // connection after it.
            var link: *Cb = cb;
            while (link.func == run) {
                const node: *Self = @ptrCast(@alignCast(link.ctx.?));
                if (node == self) {
                    link.* = self.prev;
                    return;
                }
                link = &node.prev;
            }
            // Not in the chain any more (the handler was replaced).
        }

        fn run(p: ?*anyopaque, args: Cb.Args) Ret {
            const self: *Self = @ptrCast(@alignCast(p.?));
            const result = self.prev.call(args);
            if (self.func) |f| f(self.ctx, args);
            return result;
        }
    };
}

test "connections run after the handler, chained, and come out anywhere" {
    const Log = struct {
        buf: [8]u8 = undefined,
        n: usize = 0,
        fn mark(self: *@This(), c: u8) void {
            self.buf[self.n] = c;
            self.n += 1;
        }
        fn handler(self: *@This(), x: i32) i32 {
            self.mark('h');
            return x * 2;
        }
        fn a(self: *@This(), _: i32) void {
            self.mark('a');
        }
        fn b(self: *@This(), _: i32) void {
            self.mark('b');
        }
    };
    var log: Log = .{};
    var cb: Callback(fn (i32) i32) = .{};
    cb.setHandler(&log, Log.handler);
    var ca: Connection(fn (i32) i32) = .{};
    var cbb: Connection(fn (i32) i32) = .{};
    ca.connect(&cb, &log, Log.a);
    cbb.connect(&cb, &log, Log.b);
    try std.testing.expectEqual(@as(i32, 6), cb.call(.{3}));
    try std.testing.expectEqualStrings("hab", log.buf[0..log.n]);

    // The first one out (not the last connected): the others stay.
    ca.disconnect();
    log.n = 0;
    _ = cb.call(.{1});
    try std.testing.expectEqualStrings("hb", log.buf[0..log.n]);
    cbb.disconnect();
    log.n = 0;
    _ = cb.call(.{1});
    try std.testing.expectEqualStrings("h", log.buf[0..log.n]);

    // Without a handler: the zero value, and the connection runs.
    var bare: Callback(fn (i32) i32) = .{};
    ca.connect(&bare, &log, Log.a);
    log.n = 0;
    try std.testing.expectEqual(@as(i32, 0), bare.call(.{1}));
    try std.testing.expectEqualStrings("a", log.buf[0..log.n]);
    ca.disconnect();
    try std.testing.expect(!bare.hasHandler());
}

test "callback without handler returns zero value" {
    var cb: Callback(fn (i32) i32) = .{};
    try std.testing.expectEqual(@as(i32, 0), cb.call(.{5}));
    var v: Callback(fn () void) = .{};
    v.call(.{});
}

test "callback with context handler" {
    const Counter = struct {
        n: i32 = 0,
        fn add(self: *@This(), by: i32, times: i32) i32 {
            self.n += by * times;
            return self.n;
        }
    };
    var c: Counter = .{};
    var cb: Callback(fn (i32, i32) i32) = .{};
    cb.setHandler(&c, Counter.add);
    try std.testing.expectEqual(@as(i32, 6), cb.call(.{ 2, 3 }));
    try std.testing.expectEqual(@as(i32, 7), cb.call(.{ 1, 1 }));
    try std.testing.expectEqual(@as(i32, 7), c.n);
}

test "callback with plain function handler" {
    var cb: Callback(fn ([]const u8) usize) = .{};
    cb.setHandlerFn(struct {
        fn len(s: []const u8) usize {
            return s.len;
        }
    }.len);
    try std.testing.expectEqual(@as(usize, 5), cb.call(.{"hello"}));
    cb.clearHandler();
    try std.testing.expect(!cb.hasHandler());
}
