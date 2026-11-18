// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Fuzz driver: runs the fuzz targets (src/core/fuzz.zig) on random
//! inputs.
//!
//!     zig build fuzz -- [iterations] [target-filter] [seed]
//!
//! `zig build test --fuzz` would do this with coverage guidance, but it
//! does not compile on Zig 0.16.0 (a type error in the std test runner), so
//! this driver feeds the targets from a pseudo random generator: run `i`
//! uses `seed + i`. On a failure (error, leak or panic) it prints the
//! target and the seed of the run, which `zig build fuzz -- 1 target seed`
//! repeats.

const std = @import("std");
const zigulee = @import("zigulee");
const interp = @import("zigulee-interpreter");
const fuzz = zigulee.core.fuzz;
const Target = fuzz.Target;

const targets = zigulee.core.fuzz_targets.targets ++
    zigulee.gpu.fuzz_targets.targets ++
    interp.compiler.fuzz_targets.targets ++
    interp.fuzz_targets.targets;

/// Generated programs make the runtime warn (change handlers that keep
/// triggering each other, ...): only errors are interesting.
pub const std_options: std.Options = .{ .log_level = .err };

/// What is running, for the panic handler.
var current: ?*const Target = null;
var current_seed: ?u64 = null;

pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, ret_addr: ?usize) noreturn {
        if (current) |t| report(t, current_seed, "panic");
        std.debug.defaultPanic(msg, ret_addr);
    }
}.f);

fn report(t: *const Target, seed: ?u64, what: []const u8) void {
    if (seed) |s|
        std.debug.print("\n{s} in target '{s}', seed 0x{x}: zig build fuzz -- 1 {s} 0x{x}\n", .{ what, t.name, s, t.name, s })
    else
        std.debug.print("\n{s} in target '{s}' on its corpus\n", .{ what, t.name });
}

/// Runs one input with a leak-checking allocator.
fn runOne(t: *const Target, in: *fuzz.Input) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const result = t.run(debug_allocator.allocator(), in);
    if (debug_allocator.deinit() == .leak) return error.Leak;
    return result;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const iterations = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 2000;
    const filter = if (args.len > 2) args[2] else "";
    const seed = if (args.len > 3)
        try std.fmt.parseInt(u64, args[3], 0)
    else
        @as(u64, @truncate(@as(u96, @bitCast(std.Io.Clock.real.now(init.io).toNanoseconds()))));
    std.debug.print("seed 0x{x}\n", .{seed});
    var failures: usize = 0;
    for (&targets) |*t| {
        if (std.mem.indexOf(u8, t.name, filter) == null) continue;
        std.debug.print("{s}: ", .{t.name});
        current = t;
        defer current = null;
        const ok = run: {
            current_seed = null;
            for (t.corpus) |entry| {
                var smith: std.testing.Smith = .{ .in = entry };
                var in: fuzz.Input = .{ .smith = &smith };
                runOne(t, &in) catch |err| {
                    report(t, null, @errorName(err));
                    break :run false;
                };
            }
            for (0..iterations) |i| {
                const s = seed +% i;
                current_seed = s;
                var in: fuzz.Input = .{ .random = .init(s) };
                runOne(t, &in) catch |err| {
                    report(t, s, @errorName(err));
                    if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace);
                    break :run false;
                };
            }
            break :run true;
        };
        if (ok) std.debug.print("ok\n", .{}) else failures += 1;
    }
    if (failures > 0) {
        std.debug.print("{d} target(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
