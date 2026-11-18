// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The MCU demo (examples/mcu/thermostat.zge) as it would run on a device:
//! a fixed heap, RGB565 rendering in bands of 16 lines, a tap on "+".
//! `zig build mcu-size` builds it for a Cortex-M4 (to measure code and
//! static memory) and for wasm32 (32-bit like the M4, run under Node.js to
//! measure the heap). See tools/mcu_size.zig.

const std = @import("std");
const builtin = @import("builtin");
const zigulee = @import("zigulee");
const ui = @import("thermostat_ui");

/// No messages or stack traces on a device: a panic stops.
pub const panic = std.debug.no_panic;

/// Bare metal has no standard error: a device sends log messages to its
/// own output (a UART, say), or drops them as here.
pub const std_options: std.Options = .{
    .logFn = struct {
        fn log(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}
    }.log,
};

/// No OpenType shaping (its code is 25 KB of flash): right-to-left text
/// still shows in order, Arabic with the font's presentation forms.
pub const zigulee_options = .{ .opentype_shaping = false, .transforms = false, .effects = false, .text_fitting = false };

const Rgb565 = zigulee.software.Rgb565;
const width = 320;
const band_lines = 16;

/// The heap the UI allocates from. Its size is an upper bound: the demo
/// measures what it actually uses.
var heap: [256 * 1024]u8 align(16) linksection(".zigulee_heap") = undefined;
/// Inter, pre-rendered at the sizes the UI uses (made at build time by
/// `zigulee.bitmapFont`): read in place from flash.
const font_data = @embedFile("thermostat_font");
/// One band of pixels, handed to the display driver when drawn.
var band: [width * band_lines]Rgb565 = undefined;

var flushed_lines: u32 = 0;

fn flush(_: void, canvas: zigulee.software.Canvas(Rgb565)) void {
    // A display driver would send canvas.pixels to the display here.
    flushed_lines += canvas.height;
}

/// Runs the demo; returns the heap's high-water mark in bytes.
fn run() !usize {
    var peak: Peak = .{ .fba = .init(&heap) };
    const gpa = peak.allocator();
    const font: zigulee.Font = try .init(font_data);

    const app = try ui.Thermostat.create(gpa);
    defer app.destroy();
    const window = app.window();
    window.default_font.set(&font);
    var renderer: zigulee.software.Renderer(Rgb565) = .init(gpa);
    defer renderer.deinit();

    zigulee.updateTimersAndAnimations(0);
    zigulee.runChangeHandlers();
    _ = try renderer.renderWindowInBands(window, .full, &band, band_lines, {}, flush);

    // Tap "+": the target goes up, the label and slider follow.
    window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 280, .y = 64 } } });
    window.dispatchPointer(.{ .released = .{ .position = .{ .x = 280, .y = 64 } } });
    zigulee.runChangeHandlers();
    zigulee.updateTimersAndAnimations(1000);
    _ = try renderer.renderWindowInBands(window, .partial, &band, band_lines, {}, flush);
    if (app.target.get() != 21.5) return error.TapMissed;
    return peak.max;
}

/// A fixed buffer allocator that remembers its high-water mark (freeing
/// the last allocation lowers its end).
const Peak = struct {
    fba: std.heap.FixedBufferAllocator,
    max: usize = 0,

    fn allocator(p: *Peak) std.mem.Allocator {
        return .{ .ptr = p, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn note(p: *Peak) void {
        p.max = @max(p.max, p.fba.end_index);
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ret: usize) ?[*]u8 {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        defer p.note();
        return p.fba.allocator().rawAlloc(len, a, ret);
    }

    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new: usize, ret: usize) bool {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        defer p.note();
        return p.fba.allocator().rawResize(m, a, new, ret);
    }

    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new: usize, ret: usize) ?[*]u8 {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        defer p.note();
        return p.fba.allocator().rawRemap(m, a, new, ret);
    }

    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ret: usize) void {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        p.fba.allocator().rawFree(m, a, ret);
    }
};

comptime {
    if (builtin.cpu.arch.isWasm()) {
        @export(&heapUsed, .{ .name = "zigulee_mcu_heap_used" });
    } else {
        @export(&start, .{ .name = "_start" });
    }
}

/// wasm32: the heap used, or 0 on failure.
fn heapUsed() callconv(.c) usize {
    return run() catch 0;
}

/// Cortex-M4: the reset handler.
fn start() callconv(.c) noreturn {
    _ = run() catch {};
    while (true) {}
}
