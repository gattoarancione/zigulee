// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The MCU demo (examples/mcu/thermostat.zge) on the Waveshare
//! ESP32-S3-Touch-LCD-2, bare metal: rendered in bands of 16 lines
//! (RGB565), each sent to the display as it is drawn; a heap that reuses
//! freed memory (heap.zig); the touch panel as the pointer; each frame's
//! timing, the heap in use and the stack's depth on the USB serial port;
//! the motion sensor as zigulee's accelerometer and gyroscope, their
//! readings logged once a second.
//!
//!     zig build esp32s3-flash
//!
//! (see build.zig: Zig's C backend, then Espressif's GCC and esptool).

const std = @import("std");
const zigulee = @import("zigulee");
const ui = @import("thermostat_ui");
const board = @import("board.zig");
const Heap = @import("heap.zig").Heap;

extern fn zigulee_profile_start(period: u32) void;
extern fn zigulee_profile_stop() void;
extern fn zigulee_text_start() u32;
extern var zigulee_profile: [1024]u16;
extern fn zigulee_stack_untouched() u32;

/// At startup, profiles this many full frames and sends the hottest code
/// addresses on the serial port (0: off). Map them to functions with the
/// symbols of zig-out/esp32s3/thermostat.elf.
const profile_frames = 0;

/// Scripted input instead of the touch panel (taps, slider drags,
/// switches, over and over): the device tests itself.
const self_test = false;

/// The scripted input's pointer, at time `t` (ms): where, and whether
/// pressed (null: nothing touched).
fn script(t: u64) ?struct { zigulee.core.Point, bool } {
    const cycle = t % 20_000;
    if (cycle < 8_000) {
        // Taps: 120 ms down, 280 ms up; "+" then "-".
        const i = cycle / 400;
        if (cycle % 400 >= 120) return null;
        return .{ .{ .x = if (i < 10) 280 else 40, .y = 64 }, true };
    }
    if (cycle < 16_000) {
        // The slider, dragged across and back in 2 s.
        const u = (cycle - 8_000) % 2_000;
        if (u >= 1_900) return null;
        const f = @as(f32, @floatFromInt(if (u < 950) u else 1_900 - u)) / 950;
        return .{ .{ .x = 20 + f * 280, .y = 137 }, true };
    }
    // The switches.
    const k = (cycle - 16_000) / 500;
    if ((cycle - 16_000) % 500 >= 150) return null;
    return .{ .{ .x = if (k % 2 == 0) 60 else 220, .y = 200 }, true };
}

fn dumpProfile() void {
    var total: u32 = 0;
    for (zigulee_profile) |n| total += n;
    board.printf("profile: {d} samples\n", .{total});
    for (0..40) |_| {
        var best: usize = 0;
        for (zigulee_profile, 0..) |n, i| if (n > zigulee_profile[best]) {
            best = i;
        };
        if (zigulee_profile[best] == 0) break;
        board.printf("hot 0x{x} {d}\n", .{ zigulee_text_start() + best * 256, zigulee_profile[best] });
        zigulee_profile[best] = 0;
    }
}

pub const panic = std.debug.no_panic;

/// Log messages go to the USB serial port.
pub const std_options: std.Options = .{
    .logFn = struct {
        fn log(comptime level: std.log.Level, comptime _: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
            board.printf("[" ++ @tagName(level) ++ "] " ++ fmt ++ "\n", args);
        }
    }.log,
};

/// No OpenType shaping (25 KB of code): see tools/mcu_demo.zig.
pub const zigulee_options = .{ .opentype_shaping = false, .transforms = false, .effects = false, .text_fitting = false, .text_bounds = false };

const Rgb565 = zigulee.software.Rgb565;
const band_lines = 16;

/// The heap (the demo needs about 80 KB, 83 KB at its peaks, and room
/// for fragmentation: `zig build mcu-stress -- 88` still runs) and the
/// band: not loaded from the image (.zigulee_ram), only reserved.
var heap: [90 * 1024]u8 align(16) linksection(".zigulee_ram") = undefined;
const font_data = @embedFile("thermostat_font");
var band: [board.lcd_width * band_lines]Rgb565 linksection(".zigulee_ram") = undefined;

/// Time spent sending bands to the display, per frame.
var send_us: u64 = 0;

fn flush(_: void, canvas: zigulee.software.Canvas(Rgb565)) void {
    const start = board.micros();
    const pixels: []const u16 = @ptrCast(canvas.pixels[0 .. @as(usize, canvas.width) * canvas.height]);
    board.lcdDraw(@intCast(canvas.origin_x), @intCast(canvas.origin_y), canvas.width, canvas.height, pixels);
    send_us += board.micros() - start;
}

// ---- The motion sensor as zigulee's sensors ----

/// The chip's axes as the device's (x right and y up on the landscape
/// display, z out of it): for each, which chip axis and its sign. Checked
/// on the board: screen up, the chip's z reads -g; right side up, its x
/// reads -g (a half turn about y).
const imu_axes = [3]struct { usize, f32 }{ .{ 0, -1 }, .{ 1, 1 }, .{ 2, -1 } };

const Imu = struct {
    on: [2]bool = .{ false, false },
    sink: ?*const zigulee.core.sensors.Provider.Sink = null,
    last_ms: u64 = 0,

    const Kind = zigulee.core.sensors.Kind;
    const Provider = zigulee.core.sensors.Provider;

    fn provider(self: *Imu) Provider {
        return .{ .ctx = self, .vtable = &.{ .available = available, .start = start, .stop = stop, .poll = poll } };
    }
    fn of(ctx: ?*anyopaque) *Imu {
        return @ptrCast(@alignCast(ctx));
    }
    fn available(_: ?*anyopaque, kind: Kind) bool {
        return kind == .accelerometer or kind == .gyroscope;
    }
    fn start(ctx: ?*anyopaque, kind: Kind, sink: *const Provider.Sink) Provider.Error!void {
        of(ctx).on[@intFromEnum(kind)] = true;
        of(ctx).sink = sink;
    }
    fn stop(ctx: ?*anyopaque, kind: Kind) void {
        of(ctx).on[@intFromEnum(kind)] = false;
    }
    /// Read on the UI loop, at most every 20 ms.
    fn poll(ctx: ?*anyopaque) void {
        const self = of(ctx);
        const now = board.millis();
        if (now - self.last_ms < 20) return;
        self.last_ms = now;
        const m = board.imuRead() orelse return;
        const s = self.sink orelse return;
        if (self.on[0]) s.reading(s.ctx, .accelerometer, mapped(m.accel));
        if (self.on[1]) s.reading(s.ctx, .gyroscope, mapped(m.gyro));
    }
    fn mapped(v: [3]f32) [3]f32 {
        var out: [3]f32 = undefined;
        for (&out, imu_axes) |*o, a| o.* = v[a[0]] * a[1];
        return out;
    }
};

var imu: Imu = .{};

export fn zigulee_firmware_main() void {
    board.init();
    board.lcdInit();
    board.touchInit();
    if (board.imuInit()) zigulee.core.sensors.setProvider(imu.provider());
    run() catch |err| board.printf("stopped: {t}\n", .{err});
}

fn run() !void {
    var memory: Heap = .init(&heap);
    const gpa = memory.allocator();
    const font: zigulee.Font = try .init(font_data);
    const app = try ui.Thermostat.create(gpa);
    const window = app.window();
    window.default_font.set(&font);
    var renderer: zigulee.software.Renderer(Rgb565) = .init(gpa);
    // The sensors, through zigulee's elements: logged once a second.
    var accel: zigulee.items.Accelerometer = undefined;
    accel.init(gpa);
    accel.sensor.active.set(true);
    var gyro: zigulee.items.Gyroscope = undefined;
    gyro.init(gpa);
    gyro.sensor.active.set(true);
    var logged_ms: u64 = 0;

    var frame: u32 = 0;
    var touching = false;
    var last_seen: u64 = 0;
    var last_touch: zigulee.core.Point = .{};
    var full = true;
    if (profile_frames > 0) {
        board.delayMs(1500); // time for the serial port to be opened
        zigulee_profile_start(board.cpu_mhz * 500); // every 0.5 ms
        const t0 = board.micros();
        for (0..profile_frames) |_| {
            _ = try renderer.renderWindowInBands(window, .full, &band, band_lines, {}, flush);
        }
        zigulee_profile_stop();
        board.printf("{d} full frames: {d} us each\n", .{ profile_frames, (board.micros() - t0) / profile_frames });
        dumpProfile();
    }
    while (true) {
        const now = board.millis();
        zigulee.updateTimersAndAnimations(now);
        // The touch panel, polled: a finger down is a press, moving it a
        // move, lifting it a release.
        const touch: ?board.Touch = if (self_test) blk: {
            const sp = script(now) orelse break :blk null;
            break :blk .{ .raw_x = 0, .raw_y = 0, .x = @intFromFloat(sp[0].x), .y = @intFromFloat(sp[0].y) };
        } else board.touchRead();
        if (touch != null) last_seen = now;
        if (touch) |t| {
            const p: zigulee.core.Point = .{ .x = @floatFromInt(t.x), .y = @floatFromInt(t.y) };
            if (!touching) {
                window.dispatchPointer(.{ .moved = .{ .position = p } });
                window.dispatchPointer(.{ .pressed = .{ .position = p } });
            } else window.dispatchPointer(.{ .moved = .{ .position = p } });
            touching = true;
            last_touch = p;
        } else if (touching and now - last_seen >= 30) {
            // Lifted (the panel may miss a finger for a reading or two).
            window.dispatchPointer(.{ .released = .{ .position = last_touch } });
            window.dispatchPointer(.exit);
            touching = false;
        }
        zigulee.runChangeHandlers();
        if (accel.sensor.available.get() and now - logged_ms >= 1000) {
            logged_ms = now;
            board.printf("motion: accel {d:.2} {d:.2} {d:.2} m/s2, gyro {d:.1} {d:.1} {d:.1} deg/s\n", .{ accel.x.get(), accel.y.get(), accel.z.get(), gyro.x.get(), gyro.y.get(), gyro.z.get() });
        }
        if (full or window.redraw_requested or zigulee.hasActiveAnimations()) {
            send_us = 0;
            const start = board.micros();
            const region = renderer.renderWindowInBands(window, if (full) .full else .partial, &band, band_lines, {}, flush) catch |err| {
                // Out of memory: this frame is lost, not the device.
                board.printf("frame {d}: {t} (heap {d} B in use; {d} B asked, largest free block {d} B)\n", .{ frame, err, memory.used, memory.failed_len, memory.failed_largest });
                full = true;
                continue;
            };
            const total = board.micros() - start;
            if (!region.isEmpty()) {
                const box = region.boundingBox();
                board.printf("frame {d} ({s}): {d} us = {d} drawing + {d} sending, {d}x{d} px; heap {d} B in use, peak {d} B; stack {d} B; target {d} tenths\n", .{
                    frame,                                          if (full) "full" else "partial",     total,       total - send_us, send_us,
                    @as(u32, @intFromFloat(box.width)),             @as(u32, @intFromFloat(box.height)), memory.used, memory.peak,     8 * 1024 + 28 * 1024 - zigulee_stack_untouched(),
                    @as(i32, @intFromFloat(app.target.get() * 10)),
                });
            }
            full = false;
            frame += 1;
        }
    }
}
