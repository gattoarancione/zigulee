// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The Waveshare ESP32-S3-Touch-LCD-2, bare metal: watchdogs, the CPU
//! clock, GPIO, the USB serial port (for text out), the ST7789 display on
//! SPI2 (240x320), the CST816D touch panel and the QMI8658 motion sensor
//! on I2C.
//!
//! Registers and values from Espressif's ESP-IDF headers
//! (components/soc/esp32s3/register/soc); the pins from the board's
//! LovyanGFX setup (display: SCLK 39, MOSI 38, DC 42, CS 45, backlight 1;
//! touch: SDA 48, SCL 47, address 0x15; the motion sensor on the same bus,
//! at 0x6B or 0x6A).

const std = @import("std");

extern fn zigulee_cycle_count() u32;
extern fn ets_delay_us(us: u32) void;
extern fn ets_update_cpu_frequency(mhz: u32) void;

fn reg(addr: u32) *volatile u32 {
    return @ptrFromInt(addr);
}

fn write(addr: u32, v: u32) void {
    reg(addr).* = v;
}

fn read(addr: u32) u32 {
    return reg(addr).*;
}

fn set(addr: u32, bits: u32) void {
    reg(addr).* |= bits;
}

fn clear(addr: u32, bits: u32) void {
    reg(addr).* &= ~bits;
}

// ---- Clocks, watchdogs, time ----

const system = 0x600C0000;
const rtc_cntl = 0x60008000;
const timg0 = 0x6001F000;
const timg1 = 0x60020000;
const wdt_key = 0x50D83AA1;
const swd_key = 0x8F1D312A;

/// The CPU's clock (MHz), for the cycle counter.
pub var cpu_mhz: u32 = 40;

/// Turns off the watchdogs (the ROM leaves the RTC and timer group ones
/// running) and runs the CPU at 160 MHz.
pub fn init() void {
    write(rtc_cntl + 0xB0, wdt_key);
    write(rtc_cntl + 0x98, 0); // RTC watchdog off
    write(rtc_cntl + 0xB0, 0);
    write(rtc_cntl + 0xB8, swd_key);
    set(rtc_cntl + 0xB4, 1 << 31); // super watchdog: fed by the hardware
    write(rtc_cntl + 0xB8, 0);
    for ([_]u32{ timg0, timg1 }) |t| {
        write(t + 0x64, wdt_key);
        write(t + 0x48, 0);
        write(t + 0x64, 0);
    }
    // The CPU from the 40 MHz crystal (as the ROM leaves it) to the PLL:
    // 160 MHz (CPUPERIOD_SEL 1 with the PLL at 480 MHz) needs no change of
    // the core voltage (240 MHz would).
    const per = read(system + 0x10);
    if (per & (1 << 2) != 0) {
        write(system + 0x10, (per & ~@as(u32, 3)) | 1);
        const sysclk = read(system + 0x60);
        write(system + 0x60, (sysclk & ~@as(u32, 3 << 10)) | (1 << 10)); // SOC_CLK_SEL: PLL
        cpu_mhz = 160;
    }
    ets_update_cpu_frequency(cpu_mhz);
}

/// What `init` found (for the log).
pub fn clockRegisters() [2]u32 {
    return .{ read(system + 0x60), read(system + 0x10) };
}

var last_cycles: u32 = 0;
var cycles_high: u64 = 0;

/// Microseconds since boot (the cycle counter, extended past its wraps:
/// call at least every 17 s at 240 MHz).
pub fn micros() u64 {
    const now = zigulee_cycle_count();
    if (now < last_cycles) cycles_high += 1 << 32;
    last_cycles = now;
    return (cycles_high | now) / cpu_mhz;
}

pub fn millis() u64 {
    return micros() / 1000;
}

pub fn delayMs(ms: u32) void {
    ets_delay_us(ms * 1000);
}

// ---- GPIO ----

const gpio = 0x60004000;
const io_mux = 0x60009000;

/// Gives a pin to the GPIO matrix: as an output of signal `signal` (256:
/// the pin's own output register), with input enabled if `input`.
fn routeOut(pin: u32, signal: u32, input: bool) void {
    // IO MUX: function 1 (GPIO), drive strength 2, input enable.
    write(io_mux + 4 + 4 * pin, (1 << 12) | (2 << 10) | (if (input) @as(u32, 1 << 9) else 0));
    write(gpio + 0x554 + 4 * pin, signal);
    if (pin < 32) write(gpio + 0x24, @as(u32, 1) << @intCast(pin)) else write(gpio + 0x30, @as(u32, 1) << @intCast(pin - 32));
}

fn pinHigh(pin: u32, high: bool) void {
    if (pin < 32) {
        write(gpio + if (high) @as(u32, 0x8) else 0xC, @as(u32, 1) << @intCast(pin));
    } else {
        write(gpio + if (high) @as(u32, 0x14) else 0x18, @as(u32, 1) << @intCast(pin - 32));
    }
}

// ---- The USB serial port (text out) ----

const usb_jtag = 0x60038000;

/// Writes text to the USB serial port (dropped if no one reads it: waits
/// at most 2 ms for room).
pub fn print(text: []const u8) void {
    for (text) |ch| {
        var waited: u32 = 0;
        while (read(usb_jtag + 4) & (1 << 1) == 0) : (waited += 1) {
            if (waited > 2000) return;
            ets_delay_us(1);
        }
        write(usb_jtag, ch);
        if (ch == '\n') write(usb_jtag + 4, 1); // flush the packet
    }
}

pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    print(std.fmt.bufPrint(&buf, fmt, args) catch "(too long)\n");
}

// ---- The display: ST7789 on SPI2 ----

/// Waits for bits of SPI2's command register to clear: at most 100 ms
/// (then says which wait it was, and goes on).
fn waitClear(bits: u32, what: []const u8) void {
    const start = zigulee_cycle_count();
    while (read(spi2) & bits != 0) {
        if (zigulee_cycle_count() -% start > cpu_mhz * 100_000) {
            printf("timeout: {s} (SPI command 0x{x})\n", .{ what, read(spi2) });
            return;
        }
    }
}

const spi2 = 0x60024000;
pub const lcd_width = 320; // landscape
pub const lcd_height = 240;
const pin_sclk = 39;
const pin_mosi = 38;
const pin_dc = 42;
const pin_cs = 45;
const pin_backlight = 1;

/// The display's SPI clock: 40 MHz, or 80 (above the ST7789's rated
/// 62.5 MHz, as many drivers run it; not checked on this board).
pub const spi_mhz = 40;

/// SPI2 as a master sending bytes (mode 0, from the 80 MHz PLL clock), its
/// clock and data on the display's pins.
fn spiInit() void {
    set(system + 0x18, 1 << 6); // SPI2 clock on
    clear(system + 0x20, 1 << 6); // out of reset
    write(spi2 + 0xE8, (1 << 0) | (1 << 1) | (1 << 2)); // clock gate: on, master, 80 MHz
    // The SPI clock: the 80 MHz source itself (CLK_EQU_SYSCLK), or divided
    // by 2 (N = 1, cycles - 1; H = 0; L = 1).
    write(spi2 + 0x0C, if (spi_mhz == 80) @as(u32, 1 << 31) else (1 << 12) | (0 << 6) | (1 << 0));
    write(spi2 + 0x10, (1 << 27) | (1 << 7) | (1 << 6)); // MOSI only, CS setup and hold
    write(spi2 + 0x08, 0);
    write(spi2 + 0x20, 1 << 0); // the hardware CS off: ours is a GPIO
    routeOut(pin_sclk, 101, false); // FSPICLK
    routeOut(pin_mosi, 103, false); // FSPID
    routeOut(pin_dc, 256, false);
    routeOut(pin_cs, 256, false);
    routeOut(pin_backlight, 256, false);
    pinHigh(pin_cs, true);
}

/// Sends up to 64 bytes in one transaction (the data buffer's size).
fn spiSend(bytes: []const u8) void {
    var words: [16]u32 = @splat(0);
    @memcpy(std.mem.sliceAsBytes(&words)[0..bytes.len], bytes);
    for (words[0 .. (bytes.len + 3) / 4], 0..) |w, i| write(spi2 + 0x98 + 4 * @as(u32, @intCast(i)), w);
    write(spi2 + 0x1C, @intCast(bytes.len * 8 - 1));
    write(spi2 + 0x00, 1 << 23); // apply the configuration
    waitClear(1 << 23, "spi update");
    write(spi2 + 0x00, 1 << 24); // go
    waitClear(1 << 24, "spi transfer");
}

fn spiWrite(bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 64) spiSend(bytes[i..@min(bytes.len, i + 64)]);
}

fn command(cmd: u8, args: []const u8) void {
    pinHigh(pin_cs, false);
    pinHigh(pin_dc, false);
    spiSend(&.{cmd});
    if (args.len > 0) {
        pinHigh(pin_dc, true);
        spiWrite(args);
    }
    if (!selected) pinHigh(pin_cs, true);
}

/// The display stays selected once initialized.
var selected = false;

/// Turns the display on: 16-bit colors, landscape, inverted (as this
/// panel needs), the backlight on.
pub fn lcdInit() void {
    spiInit();
    command(0x01, &.{}); // software reset
    delayMs(150);
    command(0x11, &.{}); // sleep out
    delayMs(120);
    command(0x3A, &.{0x55}); // 16 bits per pixel
    command(0x36, &.{0x60}); // landscape (row/column exchange, column order)
    command(0x21, &.{}); // inversion on
    command(0x13, &.{}); // normal mode
    command(0x29, &.{}); // display on
    delayMs(20);
    pinHigh(pin_backlight, true);
    // The display is the only device on the bus: selected from now on.
    pinHigh(pin_cs, false);
}

/// Sends pixels (RGB565, as zigulee stores them) to a rectangle.
pub fn lcdDraw(x: u32, y: u32, w: u32, h: u32, pixels: []const u16) void {
    const x1 = x + w - 1;
    const y1 = y + h - 1;
    command(0x2A, &.{ @intCast(x >> 8), @truncate(x), @intCast(x1 >> 8), @truncate(x1) });
    command(0x2B, &.{ @intCast(y >> 8), @truncate(y), @intCast(y1 >> 8), @truncate(y1) });
    pinHigh(pin_cs, false);
    pinHigh(pin_dc, false);
    spiSend(&.{0x2C}); // memory write
    pinHigh(pin_dc, true);
    // Big-endian on the wire: 32 pixels per transaction.
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < pixels.len) {
        const n = @min(32, pixels.len - i);
        for (pixels[i..][0..n], 0..) |p, j| {
            buf[2 * j] = @intCast(p >> 8);
            buf[2 * j + 1] = @truncate(p);
        }
        spiSend(buf[0 .. 2 * n]);
        i += n;
    }
    if (!selected) pinHigh(pin_cs, true);
}

// ---- The touch panel: CST816D on I2C (GPIO, bit-banged) ----

const pin_sda = 48;
const pin_scl = 47;
const touch_address = 0x15;

/// A pin as an open-drain output with its pull-up, readable.
fn openDrain(pin: u32) void {
    // IO MUX: GPIO, drive 2, input enabled, pull-up.
    write(io_mux + 4 + 4 * pin, (1 << 12) | (2 << 10) | (1 << 9) | (1 << 8));
    write(gpio + 0x554 + 4 * pin, 256);
    set(gpio + 0x74 + 4 * pin, 1 << 2); // open drain
    pinHigh(pin, true);
    if (pin < 32) write(gpio + 0x24, @as(u32, 1) << @intCast(pin)) else write(gpio + 0x30, @as(u32, 1) << @intCast(pin - 32));
}

fn pinRead(pin: u32) bool {
    return if (pin < 32) read(gpio + 0x3C) & (@as(u32, 1) << @intCast(pin)) != 0 else read(gpio + 0x40) & (@as(u32, 1) << @intCast(pin - 32)) != 0;
}

/// Half a period of the I2C clock (about 100 kHz).
fn i2cDelay() void {
    ets_delay_us(4);
}

fn sclHigh() void {
    pinHigh(pin_scl, true);
    // The device may hold the clock low (clock stretching): at most 1 ms.
    var waited: u32 = 0;
    while (!pinRead(pin_scl) and waited < 1000) : (waited += 1) ets_delay_us(1);
}

fn i2cStart() void {
    pinHigh(pin_sda, true);
    sclHigh();
    i2cDelay();
    pinHigh(pin_sda, false);
    i2cDelay();
    pinHigh(pin_scl, false);
}

fn i2cStop() void {
    pinHigh(pin_sda, false);
    i2cDelay();
    sclHigh();
    i2cDelay();
    pinHigh(pin_sda, true);
    i2cDelay();
}

/// Sends a byte; whether the device acknowledged it.
fn i2cWrite(byte: u8) bool {
    var b = byte;
    for (0..8) |_| {
        pinHigh(pin_sda, b & 0x80 != 0);
        b <<= 1;
        i2cDelay();
        sclHigh();
        i2cDelay();
        pinHigh(pin_scl, false);
    }
    pinHigh(pin_sda, true);
    i2cDelay();
    sclHigh();
    const ack = !pinRead(pin_sda);
    i2cDelay();
    pinHigh(pin_scl, false);
    return ack;
}

fn i2cRead(ack: bool) u8 {
    var b: u8 = 0;
    pinHigh(pin_sda, true);
    for (0..8) |_| {
        i2cDelay();
        sclHigh();
        b = (b << 1) | @intFromBool(pinRead(pin_sda));
        i2cDelay();
        pinHigh(pin_scl, false);
    }
    pinHigh(pin_sda, !ack);
    i2cDelay();
    sclHigh();
    i2cDelay();
    pinHigh(pin_scl, false);
    pinHigh(pin_sda, true);
    return b;
}

/// Reads `out.len` bytes from register `register` of the device; false if
/// it does not answer.
fn i2cReadRegisters(address: u8, register: u8, out: []u8) bool {
    i2cStart();
    defer i2cStop();
    if (!i2cWrite(address << 1)) return false;
    if (!i2cWrite(register)) return false;
    i2cStart(); // repeated start
    if (!i2cWrite((address << 1) | 1)) return false;
    for (out, 0..) |*b, i| b.* = i2cRead(i + 1 < out.len);
    return true;
}

/// Writes one register of the device; false if it does not answer.
fn i2cWriteRegister(address: u8, register: u8, value: u8) bool {
    i2cStart();
    defer i2cStop();
    return i2cWrite(address << 1) and i2cWrite(register) and i2cWrite(value);
}

/// Touch panel reads that failed (in all, and in a row).
pub var touch_failures: u32 = 0;
pub var touch_recoveries: u32 = 0;
var failures_in_a_row: u32 = 0;

/// Frees the bus if the device holds the data line low (in the middle of
/// a byte it thinks it is sending): clock until it lets go, then a stop.
fn i2cRecover() void {
    pinHigh(pin_sda, true);
    for (0..9) |_| {
        if (pinRead(pin_sda)) break;
        pinHigh(pin_scl, false);
        i2cDelay();
        sclHigh();
        i2cDelay();
    }
    i2cStop();
}

/// The panel's settings: no standby after a few idle seconds
/// (DisAutoSleep), else it stops answering until it is woken by a touch or
/// reset.
fn touchSetup() bool {
    return i2cWriteRegister(touch_address, 0xFE, 0x01);
}

pub fn touchInit() void {
    openDrain(pin_sda);
    openDrain(pin_scl);
    i2cRecover(); // a known state
    // (Right after power-up it does not answer yet.)
    for (0..10) |_| {
        delayMs(20);
        if (touchSetup()) break;
    } else print("touch panel: no answer\n");
}

pub const Touch = struct {
    /// The panel's own coordinates (portrait: x 0..239, y 0..319).
    raw_x: u16,
    raw_y: u16,
    /// In the display's landscape coordinates.
    x: u16,
    y: u16,
};

/// Where a finger is, if one is (null: none, or the panel did not answer).
pub fn touchRead() ?Touch {
    // From register 1: gesture, finger count, X (high, low), Y (high, low).
    var regs: [6]u8 = undefined;
    if (!i2cReadRegisters(touch_address, 0x01, &regs)) {
        touch_failures += 1;
        failures_in_a_row += 1;
        // Not answering for a while: free the bus, set it up again.
        if (failures_in_a_row % 50 == 0) {
            touch_recoveries += 1;
            i2cRecover();
            _ = touchSetup();
        }
        return null;
    }
    failures_in_a_row = 0;
    // The finger count, and the event in X's top bits: 0 down, 1 lifted,
    // 2 in contact. Once lifted, the panel may go on reporting the last
    // point with a count of 1.
    const event = regs[2] >> 6;
    if (regs[1] == 0 or event == 1) return null;
    const rx: u16 = (@as(u16, regs[2] & 0x0F) << 8) | regs[3];
    const ry: u16 = (@as(u16, regs[4] & 0x0F) << 8) | regs[5];
    // The display is turned (row/column exchange, mirrored columns).
    return .{ .raw_x = rx, .raw_y = ry, .x = @min(lcd_width - 1, ry), .y = @intCast(lcd_height - 1 - @min(lcd_height - 1, rx)) };
}

// ---- The motion sensor: QMI8658 on the same I2C bus ----

/// Where it answered (0: it did not).
var imu_address: u8 = 0;

/// Looks for the QMI8658 (WHO_AM_I, register 0, reads 0x05) and starts
/// its accelerometer (±4 g) and gyroscope (±512 degrees a second), 125
/// readings a second each. Whether it is there. Call after `touchInit`
/// (which sets up the bus).
pub fn imuInit() bool {
    for ([_]u8{ 0x6B, 0x6A }) |address| {
        var who: [1]u8 = undefined;
        if (!i2cReadRegisters(address, 0x00, &who) or who[0] != 0x05) continue;
        // CTRL1: register addresses go up by themselves, little endian;
        // CTRL2, CTRL3: full scales and rates; CTRL7: both on.
        if (!i2cWriteRegister(address, 0x02, 0x40)) continue;
        if (!i2cWriteRegister(address, 0x03, 0x16)) continue;
        if (!i2cWriteRegister(address, 0x04, 0x56)) continue;
        if (!i2cWriteRegister(address, 0x08, 0x03)) continue;
        imu_address = address;
        printf("motion sensor at 0x{x}\n", .{address});
        return true;
    }
    print("motion sensor: no answer\n");
    return false;
}

pub const Motion = struct {
    /// m/s², gravity included, along the chip's axes.
    accel: [3]f32,
    /// Degrees a second about them.
    gyro: [3]f32,
};

/// The latest reading (null: no sensor, or it did not answer).
pub fn imuRead() ?Motion {
    if (imu_address == 0) return null;
    // AX_L (0x35) to GZ_H (0x40): six little-endian 16-bit values.
    var r: [12]u8 = undefined;
    if (!i2cReadRegisters(imu_address, 0x35, &r)) return null;
    var v: [6]f32 = undefined;
    for (&v, 0..) |*x, i| x.* = @floatFromInt(@as(i16, @bitCast(@as(u16, r[2 * i]) | (@as(u16, r[2 * i + 1]) << 8))));
    const g = 9.80665 / 8192.0; // ±4 g: 8192 a g
    const dps = 1.0 / 64.0; // ±512: 64 a degree a second
    return .{ .accel = .{ v[0] * g, v[1] * g, v[2] * g }, .gyro = .{ v[3] * dps, v[4] * dps, v[5] * dps } };
}
