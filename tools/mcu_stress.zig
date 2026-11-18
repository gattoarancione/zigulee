// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The MCU demo under stress, as on a device: 32-bit (wasm32, run by
//! Node.js), with the ESP32-S3 firmware's heap (examples/esp32s3/heap.zig)
//! over a fixed buffer of the firmware's size. Clicks, slider drags and
//! switches for many rounds, frames rendered in bands as the firmware does;
//! reports the heap in use, its peak, and any allocation that fails (its
//! size and the largest free block then: fragmentation).
//!
//!     zig build mcu-stress [-- heap-KB]

const std = @import("std");
const zigulee = @import("zigulee");
const ui = @import("thermostat_ui");
const interp = @import("zigulee-interpreter");
const Heap = @import("esp32s3_heap").Heap;

pub const panic = std.debug.no_panic;
pub const zigulee_options = .{ .opentype_shaping = false, .transforms = false, .effects = false, .text_fitting = false };

extern "env" fn log(ptr: [*]const u8, len: usize) void;
/// Milliseconds (performance.now()).
extern "env" fn now() f64;

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    log(text.ptr, text.len);
}

pub const std_options: std.Options = .{
    .logFn = struct {
        fn f(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}
    }.f,
};

var buffer: [8 * 1024 * 1024]u8 align(16) = undefined;
var band: [320 * 16]zigulee.software.Rgb565 = undefined;

fn flush(_: void, _: zigulee.software.Canvas(zigulee.software.Rgb565)) void {}

const Run = struct {
    window: *zigulee.core.Window,
    renderer: *zigulee.software.Renderer(zigulee.software.Rgb565),
    heap: *Heap,
    now: u64 = 0,
    full: bool = true,
    failures: u32 = 0,
    rendered: u32 = 0,

    fn frames(r: *Run, n: usize) void {
        for (0..n) |_| {
            r.now += 16;
            zigulee.updateTimersAndAnimations(r.now);
            zigulee.runChangeHandlers();
            if (r.full or r.window.redraw_requested or zigulee.hasActiveAnimations()) {
                _ = r.renderer.renderWindowInBands(r.window, if (r.full) .full else .partial, &band, 16, {}, flush) catch {
                    r.failures += 1;
                    if (r.failures <= 10) print("frame failed: {d} B asked, largest free block {d} B, {d} B in use", .{ r.heap.failed_len, r.heap.failed_largest, r.heap.used });
                    r.full = true;
                    continue;
                };
                r.full = false;
                r.rendered += 1;
            }
        }
    }

    fn tap(r: *Run, x: f32, y: f32) void {
        r.window.dispatchPointer(.{ .moved = .{ .position = .{ .x = x, .y = y } } });
        r.window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
        r.frames(3);
        r.window.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
        r.window.dispatchPointer(.exit);
        r.frames(30);
    }
};

/// Runs `rounds` rounds with a heap of `heap_kb` KB, with the UI compiled
/// (`interpreted` 0) or loaded from its source by the interpreter (1);
/// returns the number of frames that failed.
export fn zigulee_mcu_stress(heap_kb: u32, rounds: u32, interpreted: u32) u32 {
    var heap: Heap = .init(buffer[0 .. heap_kb * 1024]);
    const gpa = heap.allocator();
    const font: zigulee.Font = zigulee.Font.init(@embedFile("thermostat_font")) catch return 1;
    const t0 = now();
    const window = if (interpreted != 0) blk: {
        const loaded = interp.Program.load(gpa, "thermostat.zge", @embedFile("thermostat_source"), .{ .style = "minimal" }) catch |err| {
            print("loading failed: {t} ({d} B in use, {d} B asked)", .{ err, heap.used, heap.failed_len });
            return 1;
        };
        const prog = switch (loaded) {
            .program => |p| p,
            .errors => |text| {
                print("{s}", .{text});
                return 1;
            },
        };
        print("loaded: {d} B in use, peak {d} B", .{ heap.used, heap.peak });
        const inst = prog.create(prog.mainComponent().?) catch |err| {
            print("creating failed: {t} ({d} B in use, {d} B asked)", .{ err, heap.used, heap.failed_len });
            return 1;
        };
        break :blk inst.window().?;
    } else blk: {
        const app = ui.Thermostat.create(gpa) catch {
            print("could not create the UI", .{});
            return 1;
        };
        break :blk app.window();
    };
    window.default_font.set(&font);
    print("created in {d:.1} ms: {d} B in use, peak {d} B", .{ now() - t0, heap.used, heap.peak });
    var renderer: zigulee.software.Renderer(zigulee.software.Rgb565) = .init(gpa);
    var r: Run = .{ .window = window, .renderer = &renderer, .heap = &heap };
    const t1 = now();
    r.frames(1);
    print("first frame: {d:.2} ms", .{now() - t1});
    r.frames(1);
    const t2 = now();
    var frames_before = r.rendered;
    for (0..rounds) |round| {
        for (0..25) |_| r.tap(280, 64);
        for (0..45) |_| r.tap(40, 64);
        for (0..3) |_| {
            r.window.dispatchPointer(.{ .moved = .{ .position = .{ .x = 20, .y = 137 } } });
            r.window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 20, .y = 137 } } });
            var x: f32 = 20;
            while (x < 300) : (x += 4) {
                r.window.dispatchPointer(.{ .moved = .{ .position = .{ .x = x, .y = 137 } } });
                r.frames(1);
            }
            while (x > 20) : (x -= 4) {
                r.window.dispatchPointer(.{ .moved = .{ .position = .{ .x = x, .y = 137 } } });
                r.frames(1);
            }
            r.window.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = 137 } } });
            r.window.dispatchPointer(.exit);
            r.frames(30);
        }
        for (0..4) |_| {
            r.tap(60, 200);
            r.tap(220, 200);
        }
        for (0..25) |_| r.tap(280, 64);
        print("round {d}: {d} B in use, peak {d} B, largest free block {d} B, {d} failed frames", .{ round + 1, heap.used, heap.peak, heap.largestFree(), r.failures });
    }
    print("{d} frames in {d:.0} ms of work: {d:.3} ms a frame (events, bindings, layout, drawing)", .{ r.rendered - frames_before, now() - t2, (now() - t2) / @as(f64, @floatFromInt(r.rendered - frames_before)) });
    frames_before = 0;
    return r.failures;
}
