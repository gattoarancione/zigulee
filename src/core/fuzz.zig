// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Fuzz targets and their input. A target is a function of an allocator and
//! an `Input`; `zig build test` runs each on its corpus through
//! `std.testing.fuzz`, `zig build fuzz` (tools/fuzz.zig) on random inputs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Smith = std.testing.Smith;

pub const Target = struct {
    name: []const u8,
    run: *const fn (Allocator, *Input) anyerror!void,
    /// Inputs for `std.testing.fuzz` (in its encoding).
    corpus: []const []const u8 = &.{},
};

/// Runs a target on its corpus (as a test).
pub fn runCorpus(comptime t: Target) !void {
    try std.testing.fuzz({}, struct {
        fn run(_: void, s: *Smith) anyerror!void {
            var in: Input = .{ .smith = s };
            return t.run(std.testing.allocator, &in);
        }
    }.run, .{ .corpus = t.corpus });
}

/// Where a target's values come from: the std fuzzer (or a corpus entry),
/// or a pseudo random generator. (Random bytes are not good input for the
/// fuzzer's encoding: most values read from them are out of range and
/// become the minimum.)
pub const Input = union(enum) {
    smith: *Smith,
    random: Random,

    pub const Random = struct {
        rng: std.Random.DefaultPrng,
        /// Chance of `eos`, in 1/256: some runs are short, some long.
        eos_chance: u8,

        pub fn init(seed: u64) Random {
            var rng: std.Random.DefaultPrng = .init(seed);
            const eos_chance = ([_]u8{ 128, 32, 8, 2 })[rng.random().uintLessThan(u8, 4)];
            return .{ .rng = rng, .eos_chance = eos_chance };
        }
    };

    fn rand(in: *Input) std.Random {
        return in.random.rng.random();
    }

    pub fn value(in: *Input, comptime T: type) T {
        return switch (in.*) {
            .smith => |s| s.value(T),
            .random => switch (@typeInfo(T)) {
                .bool => in.rand().boolean(),
                .@"enum" => in.rand().enumValue(T),
                .int => in.rand().int(T),
                else => @compileError("unsupported type " ++ @typeName(T)),
            },
        };
    }

    pub fn valueRangeAtMost(in: *Input, comptime T: type, at_least: T, at_most: T) T {
        return switch (in.*) {
            .smith => |s| s.valueRangeAtMost(T, at_least, at_most),
            .random => r: {
                const r = in.rand();
                // The bounds are often interesting: pick them a bit more.
                break :r switch (r.uintLessThan(u8, 16)) {
                    0 => at_least,
                    1 => at_most,
                    else => r.intRangeAtMost(T, at_least, at_most),
                };
            },
        };
    }

    /// An index into something of length `len` (> 0).
    pub fn index(in: *Input, len: usize) usize {
        return switch (in.*) {
            .smith => |s| s.index(len),
            .random => in.rand().uintLessThan(usize, len),
        };
    }

    pub fn boolWeighted(in: *Input, false_weight: u64, true_weight: u64) bool {
        return switch (in.*) {
            .smith => |s| s.boolWeighted(false_weight, true_weight),
            .random => in.rand().uintLessThan(u64, false_weight + true_weight) >= false_weight,
        };
    }

    /// Whether to stop generating.
    pub fn eos(in: *Input) bool {
        return switch (in.*) {
            .smith => |s| s.eos(),
            .random => |r| in.rand().int(u8) < r.eos_chance,
        };
    }

    pub fn bytes(in: *Input, out: []u8) void {
        switch (in.*) {
            .smith => |s| s.bytes(out),
            .random => {
                const r = in.rand();
                // Plain bytes, or mostly text with some UTF-8 pieces.
                if (r.boolean()) return r.bytes(out);
                const pieces = [_][]const u8{ "a", "b", " ", "\n", "é", "\u{301}", "\u{1F44D}", "\u{200D}", "\xff", "\xc3", "-", "0", "\t" };
                var i: usize = 0;
                while (i < out.len) {
                    const p = pieces[r.uintLessThan(usize, pieces.len)];
                    const n = @min(p.len, out.len - i);
                    @memcpy(out[i..][0..n], p[0..n]);
                    i += n;
                }
            },
        }
    }

    /// Fills the start of `buf` and returns its length.
    pub fn slice(in: *Input, buf: []u8) u32 {
        const n: u32 = switch (in.*) {
            .smith => |s| return s.slice(buf),
            .random => n: {
                const r = in.rand();
                const max: u32 = @intCast(buf.len);
                break :n if (r.boolean()) r.uintAtMost(u32, @min(max, 16)) else r.uintAtMost(u32, max);
            },
        };
        in.bytes(buf[0..n]);
        return n;
    }
};
