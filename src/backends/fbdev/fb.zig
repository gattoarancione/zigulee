// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The Linux framebuffer device (/dev/fb*): its mode and pixel format read
//! with ioctls, its memory mapped and written as the format says (RGB565,
//! RGB888, XRGB8888, ...). Two pages when the driver can pan between them
//! (the virtual screen made twice as tall), else one, drawn in place. A
//! cursor drawn in software, as the framebuffer has no other. The text
//! console is put in graphics mode while the screen is ours (it would
//! draw over it).

const std = @import("std");
const builtin = @import("builtin");
const zigulee = @import("zigulee");
pub const Rotation = @import("zigulee-evdev").Rotation;
const core = zigulee.core;
const Rgba8 = core.Rgba8;
const c = std.c;
/// `mmap` with a 64-bit offset, as `std.c` declares it: on 32-bit glibc
/// `mmap` takes a 32-bit one and `mmap64` the 64-bit (as `std.posix` picks).
const mmap = if (std.posix.lfs64_abi) c.mmap64 else c.mmap;

const log = std.log.scoped(.zigulee_fbdev);

extern "c" fn ioctl(fd: c.fd_t, request: c_ulong, ...) c_int;

pub const Error = error{ NoDevice, UnsupportedFormat, OutOfMemory };

/// An ioctl, retried when interrupted; whether it worked.
fn call(fd: c.fd_t, request: c_ulong, arg: anytype) bool {
    while (true) {
        const r = ioctl(fd, request, arg);
        if (r == 0) return true;
        if (std.posix.errno(r) != .INTR and std.posix.errno(r) != .AGAIN) return false;
    }
}

pub const ioc = struct {
    pub const get_vscreeninfo = 0x4600;
    pub const put_vscreeninfo = 0x4601;
    pub const get_fscreeninfo = 0x4602;
    pub const pan_display = 0x4606;
};

/// Where a colour channel is in a pixel.
pub const Bitfield = extern struct {
    offset: u32 = 0,
    length: u32 = 0,
    msb_right: u32 = 0,
};

/// struct fb_var_screeninfo: the mode.
pub const VarScreenInfo = extern struct {
    xres: u32 = 0,
    yres: u32 = 0,
    xres_virtual: u32 = 0,
    yres_virtual: u32 = 0,
    xoffset: u32 = 0,
    yoffset: u32 = 0,
    bits_per_pixel: u32 = 0,
    grayscale: u32 = 0,
    red: Bitfield = .{},
    green: Bitfield = .{},
    blue: Bitfield = .{},
    transp: Bitfield = .{},
    nonstd: u32 = 0,
    activate: u32 = 0,
    /// Millimetres.
    height: u32 = 0,
    width: u32 = 0,
    accel_flags: u32 = 0,
    pixclock: u32 = 0,
    left_margin: u32 = 0,
    right_margin: u32 = 0,
    upper_margin: u32 = 0,
    lower_margin: u32 = 0,
    hsync_len: u32 = 0,
    vsync_len: u32 = 0,
    sync: u32 = 0,
    vmode: u32 = 0,
    rotate: u32 = 0,
    colorspace: u32 = 0,
    reserved: [4]u32 = @splat(0),
};

/// struct fb_fix_screeninfo: the memory.
pub const FixScreenInfo = extern struct {
    id: [16]u8 = @splat(0),
    smem_start: c_ulong = 0,
    smem_len: u32 = 0,
    type: u32 = 0,
    type_aux: u32 = 0,
    visual: u32 = 0,
    xpanstep: u16 = 0,
    ypanstep: u16 = 0,
    ywrapstep: u16 = 0,
    line_length: u32 = 0,
    mmio_start: c_ulong = 0,
    mmio_len: u32 = 0,
    accel: u32 = 0,
    capabilities: u16 = 0,
    reserved: [2]u16 = @splat(0),
};

const type_packed_pixels = 0;
const visual_truecolor = 2;
const visual_directcolor = 4;

/// A pixel format: 2, 3 or 4 bytes, little-endian, each channel at its
/// offset (alpha, if there is one, opaque).
pub const Format = struct {
    bytes: u8,
    red: Bitfield,
    green: Bitfield,
    blue: Bitfield,
    alpha: Bitfield = .{},

    pub const xrgb8888: Format = .{ .bytes = 4, .red = .{ .offset = 16, .length = 8 }, .green = .{ .offset = 8, .length = 8 }, .blue = .{ .length = 8 } };
    pub const rgb565: Format = .{ .bytes = 2, .red = .{ .offset = 11, .length = 5 }, .green = .{ .offset = 5, .length = 6 }, .blue = .{ .length = 5 } };

    /// A 32-bit format of whole bytes: red, green and blue in bytes 2, 1
    /// and 0 (XRGB, ARGB) or 0, 1 and 2 (XBGR, ABGR), an alpha, if any,
    /// in byte 3 (written opaque). Rows of these are converted several
    /// pixels at once.
    pub fn words(f: Format) ?Words {
        if (f.bytes != 4 or f.red.length != 8 or f.green.length != 8 or f.blue.length != 8 or f.green.offset != 8) return null;
        const swap = if (f.red.offset == 16 and f.blue.offset == 0) true else if (f.red.offset == 0 and f.blue.offset == 16) false else return null;
        if (f.alpha.length != 0 and (f.alpha.length != 8 or f.alpha.offset != 24)) return null;
        return .{ .swap = swap, .alpha = if (f.alpha.length == 8) 0xff00_0000 else 0 };
    }

    pub const Words = struct {
        /// Red and blue the other way round from `Rgba8`'s bytes.
        swap: bool,
        /// What the alpha byte holds.
        alpha: u32,
    };

    /// The device's, if it is one of ours: packed true colour pixels of
    /// 16, 24 or 32 bits.
    pub fn of(v: VarScreenInfo, f: FixScreenInfo) ?Format {
        if (f.type != type_packed_pixels or (f.visual != visual_truecolor and f.visual != visual_directcolor)) return null;
        if (v.grayscale != 0) return null;
        if (v.bits_per_pixel != 16 and v.bits_per_pixel != 24 and v.bits_per_pixel != 32) return null;
        const format: Format = .{ .bytes = @intCast(v.bits_per_pixel / 8), .red = v.red, .green = v.green, .blue = v.blue, .alpha = v.transp };
        for ([_]Bitfield{ v.red, v.green, v.blue, v.transp }) |b| {
            if (b.length > 16 or b.offset + b.length > v.bits_per_pixel) return null;
        }
        if (v.red.length == 0 or v.green.length == 0 or v.blue.length == 0) return null;
        return format;
    }

    fn channel(b: Bitfield, value: u8) u32 {
        if (b.length == 0) return 0;
        const v: u32 = if (b.length >= 8) @as(u32, value) << @intCast(b.length - 8) else value >> @intCast(8 - b.length);
        return v << @intCast(b.offset);
    }

    pub fn pack(f: Format, p: Rgba8) u32 {
        const alpha: u32 = if (f.alpha.length == 0) 0 else ((@as(u32, 1) << @intCast(f.alpha.length)) - 1) << @intCast(f.alpha.offset);
        return channel(f.red, p.r) | channel(f.green, p.g) | channel(f.blue, p.b) | alpha;
    }

    fn store(f: Format, dst: []u8, v: u32) void {
        switch (f.bytes) {
            2 => std.mem.writeInt(u16, dst[0..2], @truncate(v), .little),
            3 => std.mem.writeInt(u24, dst[0..3], @truncate(v), .little),
            else => std.mem.writeInt(u32, dst[0..4], v, .little),
        }
    }
};

/// The arrow of the cursor: black, white inside (KMS shows it as its
/// hardware cursor, fbdev draws it).
pub const arrow = [_][]const u8{
    "X",
    "XX",
    "X.X",
    "X..X",
    "X...X",
    "X....X",
    "X.....X",
    "X......X",
    "X.......X",
    "X........X",
    "X.....XXXXX",
    "X..X..X",
    "X.XX..X",
    "XX  X..X",
    "X   X..X",
    "     X..X",
    "     X..X",
    "      XX",
};

const arrow_width = 11;

/// Pixels converted at once by `convertRow`.
const row_lanes = 8;
const vectors = std.simd.suggestVectorLength(u8) != null and @import("builtin").cpu.arch.endian() == .little;
/// 32-bit ARM with NEON: rows of 32-bit pixels converted in assembly.
const arm_neon = builtin.cpu.arch == .arm and std.Target.arm.featureSetHas(builtin.cpu.features, .neon);

/// Converts pixels x0.. of a screen row (`row`: its bytes) from the
/// picture, `row_lanes` at a time where the row takes them in order or in
/// reverse (upright, or turned 180°): loaded together, reversed if
/// needed, converted and stored together. Returns where it stopped (the
/// rest is left to do one by one). `alpha`: the alpha byte's bits of a
/// 32-bit format. (KMS's buffers too.)
pub fn convertRow(comptime format: enum { rgb565, xrgb, xbgr }, row: []u8, src: []const Rgba8, from: anytype, x0: usize, x1: usize, comptime alpha: u32) usize {
    if (!vectors or (from.step != 1 and from.step != -1)) return x0;
    // Each way its own loop: nothing decided pixel after pixel.
    return if (from.step == 1)
        convertRowIn(format, false, row, src, from, x0, x1, alpha)
    else
        convertRowIn(format, true, row, src, from, x0, x1, alpha);
}

fn convertRowIn(comptime format: anytype, comptime reversed: bool, row: []u8, src: []const Rgba8, from: anytype, x0: usize, x1: usize, comptime alpha: u32) usize {
    const n = row_lanes;
    const V = @Vector(4 * n, u8);
    const reverse = comptime blk: {
        var m: [4 * n]i32 = undefined;
        for (&m, 0..) |*e, j| e.* = (n - 1 - j / 4) * 4 + j % 4;
        break :blk m;
    };
    var x = x0;
    if (arm_neon and format != .rgb565) {
        // 16 pixels at a time, taken apart by channel (`vld4`), turned by
        // reversing each, red and blue swapped for XRGB, the alpha byte
        // set, put back together (`vst4`). LLVM's own moves the bytes one
        // by one.
        const swap = if (format == .xrgb)
            \\vswp d16, d18
            \\vswp d20, d22
            \\
        else
            "";
        const turn = if (reversed)
            \\vrev64.8 d16, d16
            \\vrev64.8 d17, d17
            \\vrev64.8 d18, d18
            \\vrev64.8 d20, d20
            \\vrev64.8 d21, d21
            \\vrev64.8 d22, d22
            \\
        else
            "";
        const a = if (alpha != 0) "#255" else "#0";
        while (x + 16 <= x1) : (x += 16) {
            const lo = if (reversed) pixelIndex(from, x + 7) else pixelIndex(from, x);
            const hi = if (reversed) pixelIndex(from, x + 15) else pixelIndex(from, x + 8);
            asm volatile ("vld4.8 {d16, d17, d18, d19}, [%[lo]]\n" ++
                    "vld4.8 {d20, d21, d22, d23}, [%[hi]]\n" ++ turn ++ swap ++
                    "vmov.i8 d19, " ++ a ++ "\n" ++
                    "vmov.i8 d23, " ++ a ++ "\n" ++
                    "vst4.8 {d16, d17, d18, d19}, [%[d0]]\n" ++
                    "vst4.8 {d20, d21, d22, d23}, [%[d1]]"
                :
                : [lo] "r" (src[lo..][0..8].ptr),
                  [hi] "r" (src[hi..][0..8].ptr),
                  [d0] "r" (row[x * 4 ..][0..64].ptr),
                  [d1] "r" (row[x * 4 + 32 ..][0..32].ptr),
                : .{ .d16 = true, .d17 = true, .d18 = true, .d19 = true, .d20 = true, .d21 = true, .d22 = true, .d23 = true, .memory = true });
        }
    }
    while (x + n <= x1) : (x += n) {
        // The n source pixels, in the row's order.
        const first: usize = if (reversed) pixelIndex(from, x + n - 1) else pixelIndex(from, x);
        const p: V = @bitCast(src[first..][0..n].*);
        switch (format) {
            .rgb565 => {
                // Each pixel as a word (red in its low byte): the top
                // bits of each channel moved to their place.
                const W = @Vector(n, u32);
                const w: W = @bitCast(if (reversed) @shuffle(u8, p, undefined, reverse) else p);
                const out = ((w & @as(W, @splat(0xf8))) << @splat(8)) | ((w >> @splat(5)) & @as(W, @splat(0x7e0))) | ((w >> @splat(19)) & @as(W, @splat(0x1f)));
                const narrow: @Vector(n, u16) = @truncate(out);
                row[x * 2 ..][0 .. 2 * n].* = @bitCast(narrow);
            },
            .xrgb, .xbgr => {
                // The alphas cleared, the bytes put in place (blue first
                // for XRGB), an opaque alpha added if the format has one.
                const swap = format == .xrgb;
                const mask = comptime blk: {
                    var m: [4 * n]i32 = undefined;
                    for (0..n) |i| {
                        m[4 * i] = 4 * i + if (swap) 2 else 0;
                        m[4 * i + 1] = 4 * i + 1;
                        m[4 * i + 2] = 4 * i + if (swap) 0 else 2;
                        m[4 * i + 3] = 4 * i + 3;
                    }
                    break :blk m;
                };
                const pixels = if (reversed) @shuffle(u8, p, undefined, reverse) else p;
                const rgb = pixels & @as(V, @bitCast(@as([n]u32, @splat(0x00ff_ffff))));
                var out = if (swap) @shuffle(u8, rgb, undefined, mask) else rgb;
                if (alpha != 0) out |= @as(V, @bitCast(@as([n]u32, @splat(alpha))));
                row[x * 4 ..][0 .. 4 * n].* = @bitCast(out);
            },
        }
    }
    return x;
}

/// Pixel x of a row of the screen in the picture (`Rotation.row`).
inline fn pixelIndex(from: anytype, x: usize) usize {
    return @intCast(from.base + @as(isize, @intCast(x)) * from.step);
}

/// Pixel rectangles (ends excluded).
const Box = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    fn of(r: core.Rect, width: u32, height: u32) Box {
        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);
        return .{
            .x0 = @intFromFloat(std.math.clamp(@floor(r.x), 0, w)),
            .y0 = @intFromFloat(std.math.clamp(@floor(r.y), 0, h)),
            .x1 = @intFromFloat(std.math.clamp(@ceil(r.x + r.width), 0, w)),
            .y1 = @intFromFloat(std.math.clamp(@ceil(r.y + r.height), 0, h)),
        };
    }
};

/// The screen: its memory mapped, one or two pages.
pub const Screen = struct {
    fd: c.fd_t = -1,
    width: u32,
    height: u32,
    /// Bytes per row.
    pitch: u32,
    format: Format,
    memory: []u8,
    /// Mapped from the device (else given, by tests).
    mapped: bool = false,
    /// Two: drawn in the one not shown, then panned to.
    pages: u32 = 1,
    /// The page on screen.
    shown: u32 = 0,
    /// Where the single page starts (the mode's offsets).
    origin: usize = 0,
    /// The mode before (restored at the end, if changed).
    saved: VarScreenInfo = .{},
    changed_mode: bool = false,
    /// What changed in each page since it was last brought up to date
    /// (a few rectangles, each copied on its own).
    stale: [2]core.Region = .{ .{}, .{} },
    /// The cursor's top left corner (pixels), if shown, and the size of
    /// its dots.
    cursor: ?core.Point = null,
    cursor_dot: u32 = 1,
    /// Panning failed after working: one page from then on.
    pan_failed: bool = false,
    /// How the picture given to `present` is turned on the screen (its
    /// size is the screen's, turned).
    rotation: Rotation = .none,

    /// Opens the device: `ZIGULEE_FB_DEVICE`, else /dev/fb0.
    pub fn open() Error!Screen {
        const path: [*:0]const u8 = if (c.getenv("ZIGULEE_FB_DEVICE")) |p| p else "/dev/fb0";
        const fd = c.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        if (fd < 0) return error.NoDevice;
        errdefer _ = c.close(fd);
        var v: VarScreenInfo = .{};
        var f: FixScreenInfo = .{};
        if (!call(fd, ioc.get_vscreeninfo, &v) or !call(fd, ioc.get_fscreeninfo, &f)) return error.NoDevice;
        const format = Format.of(v, f) orelse {
            log.err("{s}: unsupported pixel format ({d} bits per pixel, visual {d})", .{ path, v.bits_per_pixel, f.visual });
            return error.UnsupportedFormat;
        };
        var s: Screen = .{ .fd = fd, .width = v.xres, .height = v.yres, .pitch = f.line_length, .format = format, .memory = &.{}, .saved = v };
        // Two pages: the virtual screen twice as tall, if the memory holds
        // it and the driver pans.
        const page = @as(usize, f.line_length) * v.yres;
        if (f.ypanstep != 0 and f.smem_len >= 2 * page) {
            if (v.yres_virtual < 2 * v.yres) {
                var w = v;
                w.yres_virtual = 2 * v.yres;
                w.yoffset = 0;
                if (call(fd, ioc.put_vscreeninfo, &w)) {
                    s.changed_mode = true;
                    _ = call(fd, ioc.get_vscreeninfo, &v);
                    _ = call(fd, ioc.get_fscreeninfo, &f);
                }
            }
            var p = v;
            p.xoffset = 0;
            p.yoffset = 0;
            if (v.yres_virtual >= 2 * v.yres and f.smem_len >= 2 * @as(usize, f.line_length) * v.yres and f.line_length == s.pitch and call(fd, ioc.pan_display, &p)) s.pages = 2;
        }
        if (s.pages == 1) s.origin = @as(usize, v.yoffset) * f.line_length + @as(usize, v.xoffset) * format.bytes;
        if (s.origin + page > f.smem_len) return error.NoDevice;
        const mem = mmap(null, f.smem_len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (mem == c.MAP_FAILED) return error.OutOfMemory;
        s.memory = @as([*]u8, @ptrCast(mem))[0..f.smem_len];
        s.mapped = true;
        for (0..s.pages) |i| @memset(s.pageMemory(@intCast(i)), 0);
        log.info("{s}: {d}x{d}, {d} bits per pixel, {d} page(s)", .{ path, s.width, s.height, v.bits_per_pixel, s.pages });
        return s;
    }

    /// A screen in memory (tests).
    pub fn inMemory(memory: []u8, width: u32, height: u32, format: Format, pages: u32) Screen {
        return .{ .width = width, .height = height, .pitch = width * format.bytes, .format = format, .memory = memory, .pages = pages };
    }

    /// Gives the device back (its mode as it was).
    pub fn close(s: *Screen) void {
        if (s.fd >= 0) {
            if (s.changed_mode) {
                _ = call(s.fd, ioc.put_vscreeninfo, &s.saved);
            } else if (s.pages == 2) _ = call(s.fd, ioc.pan_display, &s.saved);
        }
        if (s.mapped) _ = c.munmap(@ptrCast(@alignCast(s.memory.ptr)), s.memory.len);
        if (s.fd >= 0) _ = c.close(s.fd);
        s.* = undefined;
    }

    /// A page's pixels.
    pub fn pageMemory(s: *const Screen, page: u32) []u8 {
        const size = @as(usize, s.pitch) * s.height;
        const start = if (s.pages == 2) page * size else s.origin;
        return s.memory[start..][0..size];
    }

    fn full(s: *const Screen) core.Rect {
        return .{ .width = @floatFromInt(s.width), .height = @floatFromInt(s.height) };
    }

    /// The size of the picture `present` takes.
    pub fn pictureSize(s: *const Screen) [2]u32 {
        return s.rotation.turnedSize(s.width, s.height);
    }

    fn cursorRect(s: *const Screen) core.Rect {
        const at = s.cursor orelse return .empty;
        const d: f32 = @floatFromInt(s.cursor_dot);
        // The arrow, turned with the picture, from its tip.
        const far = s.rotation.vectorToScreen(.{ .x = arrow_width * d - 1, .y = arrow.len * d - 1 });
        const x0 = @floor(at.x) + @min(0, far.x);
        const y0 = @floor(at.y) + @min(0, far.y);
        return .{ .x = x0, .y = y0, .width = @abs(far.x) + 1, .height = @abs(far.y) + 1 };
    }

    /// Marks a rectangle to be brought up to date on every page.
    pub fn invalidate(s: *Screen, r: core.Rect) void {
        for (&s.stale) |*st| st.add(r);
    }

    /// Moves the cursor (pixels; null: hidden). Shown at the next
    /// `present`.
    pub fn setCursor(s: *Screen, at: ?core.Point, dot: u32) void {
        if (std.meta.eql(at, s.cursor) and dot == s.cursor_dot) return;
        s.invalidate(s.cursorRect());
        s.cursor = at;
        s.cursor_dot = dot;
        s.invalidate(s.cursorRect());
    }

    /// Shows `src` (the picture: the screen's size, turned by `rotation`):
    /// what changed since the last time, and the `changed` rectangles (in
    /// the picture), each copied on its own. Whether anything was drawn.
    pub fn present(s: *Screen, src: []const Rgba8, changed: []const core.Rect) bool {
        for (changed) |r| {
            if (s.rotation == .none or r.isEmpty()) {
                s.invalidate(r);
                continue;
            }
            // In whole pixels of the picture, then turned.
            const x0 = @floor(r.x);
            const y0 = @floor(r.y);
            const whole: core.Rect = .{ .x = x0, .y = y0, .width = @ceil(r.x + r.width) - x0, .height = @ceil(r.y + r.height) - y0 };
            const size = s.pictureSize();
            s.invalidate(s.rotation.rectToScreen(whole, @floatFromInt(size[0]), @floatFromInt(size[1])));
        }
        const target: u32 = if (s.pages == 2) 1 - s.shown else s.shown;
        const stale = s.stale[target];
        if (stale.isEmpty()) return false;
        s.stale[target].clear();
        for (stale.slice()) |r| s.copy(target, src, Box.of(r, s.width, s.height));
        if (s.pages == 2) {
            if (s.fd >= 0) {
                var v = s.saved;
                v.xoffset = 0;
                v.yoffset = target * s.height;
                if (!call(s.fd, ioc.pan_display, &v)) {
                    // One page from now on: the one on screen.
                    log.warn("panning failed: drawing in place", .{});
                    s.pages = 1;
                    s.pan_failed = true;
                    s.origin = @as(usize, s.shown) * s.pitch * s.height;
                    s.stale[s.shown].add(s.full());
                    return s.present(src, &.{});
                }
            }
            s.shown = target;
        }
        return true;
    }

    /// Converts a box of `src` into a page, and draws the cursor over it.
    fn copy(s: *Screen, page: u32, src: []const Rgba8, b: Box) void {
        const mem = s.pageMemory(page);
        const f = s.format;
        for (b.y0..b.y1) |y| {
            const row = mem[y * s.pitch ..];
            // The picture's pixels for this row: in order, or (turned)
            // stepping back or across its rows.
            const from = s.rotation.row(y, s.width, s.height);
            switch (f.bytes) {
                // The usual formats, faster.
                4 => if (f.words()) |w| {
                    const done = switch (@as(u2, @intFromBool(w.swap)) << 1 | @intFromBool(w.alpha != 0)) {
                        0b10 => convertRow(.xrgb, row, src, from, b.x0, b.x1, 0),
                        0b11 => convertRow(.xrgb, row, src, from, b.x0, b.x1, 0xff00_0000),
                        0b00 => convertRow(.xbgr, row, src, from, b.x0, b.x1, 0),
                        0b01 => convertRow(.xbgr, row, src, from, b.x0, b.x1, 0xff00_0000),
                    };
                    for (done..b.x1) |x| {
                        const p = src[pixelIndex(from, x)];
                        const rgb: u32 = if (w.swap) @as(u32, p.r) << 16 | @as(u32, p.g) << 8 | p.b else @as(u32, p.b) << 16 | @as(u32, p.g) << 8 | p.r;
                        std.mem.writeInt(u32, row[x * 4 ..][0..4], rgb | w.alpha, .little);
                    }
                    continue;
                },
                2 => if (std.meta.eql(f, Format.rgb565)) {
                    const done = convertRow(.rgb565, row, src, from, b.x0, b.x1, 0);
                    for (done..b.x1) |x| {
                        const p = src[pixelIndex(from, x)];
                        std.mem.writeInt(u16, row[x * 2 ..][0..2], @as(u16, p.r >> 3) << 11 | @as(u16, p.g >> 2) << 5 | p.b >> 3, .little);
                    }
                    continue;
                },
                else => {},
            }
            for (b.x0..b.x1) |x| f.store(row[x * f.bytes ..], f.pack(src[pixelIndex(from, x)]));
        }
        // The cursor, where it overlaps.
        const at = s.cursor orelse return;
        const black = f.pack(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
        const white = f.pack(.{ .r = 255, .g = 255, .b = 255, .a = 255 });
        const cx: i64 = @intFromFloat(@floor(at.x));
        const cy: i64 = @intFromFloat(@floor(at.y));
        const d = s.cursor_dot;
        for (arrow, 0..) |line, ay| for (line, 0..) |dot, ax| {
            const color = switch (dot) {
                'X' => black,
                '.' => white,
                else => continue,
            };
            for (0..d) |dy| for (0..d) |dx| {
                // Turned with the picture, about its tip.
                const o = s.rotation.vectorToScreen(.{ .x = @floatFromInt(ax * d + dx), .y = @floatFromInt(ay * d + dy) });
                const px = cx + @as(i64, @intFromFloat(o.x));
                const py = cy + @as(i64, @intFromFloat(o.y));
                if (px < b.x0 or px >= b.x1 or py < b.y0 or py >= b.y1) continue;
                const ux: usize = @intCast(px);
                const uy: usize = @intCast(py);
                f.store(mem[uy * s.pitch + ux * f.bytes ..], color);
            };
        };
    }
};

/// The text console, in graphics mode while the screen is ours (else it
/// draws its text and cursor over it): the terminal the program runs on,
/// else /dev/tty0.
pub const Console = struct {
    fd: c.fd_t = -1,
    owned: bool = false,

    const kd_setmode = 0x4B3A;
    const kd_getmode = 0x4B3B;
    const kd_text = 0;
    const kd_graphics = 1;

    pub fn graphics() Console {
        if (toGraphics(0)) return .{ .fd = 0 };
        const fd = c.open("/dev/tty0", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        if (fd < 0) return .{};
        if (toGraphics(fd)) return .{ .fd = fd, .owned = true };
        _ = c.close(fd);
        return .{};
    }

    fn toGraphics(fd: c.fd_t) bool {
        var mode: c_int = -1;
        if (ioctl(fd, kd_getmode, &mode) != 0 or mode != kd_text) return false;
        return ioctl(fd, kd_setmode, @as(c_ulong, kd_graphics)) == 0;
    }

    pub fn restore(self: *Console) void {
        if (self.fd < 0) return;
        _ = ioctl(self.fd, kd_setmode, @as(c_ulong, kd_text));
        if (self.owned) _ = c.close(self.fd);
        self.* = .{};
    }
};

// ---- Tests ----

const testing = std.testing;

test "the kernel's structures" {
    try testing.expectEqual(@as(usize, 160), @sizeOf(VarScreenInfo));
    if (@sizeOf(c_ulong) == 8) try testing.expectEqual(@as(usize, 80), @sizeOf(FixScreenInfo));
    if (@sizeOf(c_ulong) == 4) try testing.expectEqual(@as(usize, 68), @sizeOf(FixScreenInfo));
}

test "pixel formats" {
    const p: Rgba8 = .{ .r = 0xff, .g = 0x80, .b = 0x10, .a = 0xff };
    try testing.expectEqual(@as(u32, 0xfc02), Format.rgb565.pack(p));
    try testing.expectEqual(@as(u32, 0xff8010), Format.xrgb8888.pack(p));
    // As the device says: BGR, 24 bits; ARGB with its alpha opaque.
    var v: VarScreenInfo = .{ .bits_per_pixel = 24, .red = .{ .length = 8 }, .green = .{ .offset = 8, .length = 8 }, .blue = .{ .offset = 16, .length = 8 } };
    const bgr = Format.of(v, .{ .visual = visual_truecolor }).?;
    try testing.expectEqual(@as(u32, 0x1080ff), bgr.pack(p));
    v = .{ .bits_per_pixel = 32, .red = .{ .offset = 16, .length = 8 }, .green = .{ .offset = 8, .length = 8 }, .blue = .{ .length = 8 }, .transp = .{ .offset = 24, .length = 8 } };
    try testing.expectEqual(@as(u32, 0xffff8010), Format.of(v, .{ .visual = visual_truecolor }).?.pack(p));
    // Not ours: palettes, monochrome.
    v.bits_per_pixel = 8;
    try testing.expectEqual(@as(?Format, null), Format.of(v, .{ .visual = visual_truecolor }));
    v.bits_per_pixel = 32;
    try testing.expectEqual(@as(?Format, null), Format.of(v, .{ .visual = 3 }));
    // Written little-endian, 3 bytes.
    var bytes: [3]u8 = undefined;
    bgr.store(&bytes, bgr.pack(p));
    try testing.expectEqualSlices(u8, &.{ 0xff, 0x80, 0x10 }, &bytes);
}

test "two pages: each brought up to date with what changed since it was shown" {
    const w = 8;
    const h = 4;
    var memory: [2 * w * h * 2]u8 = @splat(0);
    var s: Screen = .inMemory(&memory, w, h, .rgb565, 2);
    var src: [w * h]Rgba8 = @splat(.{ .r = 255, .g = 255, .b = 255, .a = 255 });
    const at = struct {
        fn f(sc: *Screen, page: u32, x: usize, y: usize) u16 {
            return std.mem.readInt(u16, sc.pageMemory(page)[y * sc.pitch + x * 2 ..][0..2], .little);
        }
    }.f;
    // The first frame: all of it, into page 1, shown.
    try testing.expect(s.present(&src, &.{s.full()}));
    try testing.expectEqual(@as(u32, 1), s.shown);
    try testing.expectEqual(@as(u16, 0xffff), at(&s, 1, 7, 3));
    try testing.expectEqual(@as(u16, 0), at(&s, 0, 7, 3));
    // A pixel changes: page 0 gets the first frame and the change.
    src[1 * w + 2] = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    try testing.expect(s.present(&src, &.{.{ .x = 2, .y = 1, .width = 1, .height = 1 }}));
    try testing.expectEqual(@as(u32, 0), s.shown);
    try testing.expectEqual(@as(u16, 0xffff), at(&s, 0, 7, 3));
    try testing.expectEqual(@as(u16, 0xf800), at(&s, 0, 2, 1));
    // Nothing more: page 1 still has the pixel to catch up on.
    try testing.expect(s.present(&src, &.{}));
    try testing.expectEqual(@as(u16, 0xf800), at(&s, 1, 2, 1));
    try testing.expect(!s.present(&src, &.{}));
}

test "changes far apart: each copied on its own, not what lies between" {
    const w = 16;
    const h = 4;
    var memory: [w * h * 4]u8 = @splat(0);
    var s: Screen = .inMemory(&memory, w, h, .xrgb8888, 1);
    s.rotation = .half;
    var picture: [w * h]Rgba8 = @splat(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
    try testing.expect(s.present(&picture, &.{s.full()}));
    // Changed everywhere, but said to be only at both ends of a row.
    @memset(&picture, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    try testing.expect(s.present(&picture, &.{ .{ .x = 0, .y = 1, .width = 2, .height = 1 }, .{ .x = 14, .y = 1, .width = 2, .height = 1 } }));
    const at = struct {
        fn f(sc: *Screen, x: usize, y: usize) u32 {
            return std.mem.readInt(u32, sc.memory[y * sc.pitch + x * 4 ..][0..4], .little);
        }
    }.f;
    // Upside down: the picture's row 1 is the screen's row 2, its ends swapped.
    for (0..w) |x| try testing.expectEqual(@as(u32, if (x < 2 or x >= 14) 0xff0000 else 0), at(&s, x, 2));
    try testing.expectEqual(@as(u32, 0), at(&s, 0, 1));
}

test "the cursor: drawn over the pixels, and gone when it moves" {
    const w = 32;
    const h = 32;
    var memory: [w * h * 4]u8 = @splat(0);
    var s: Screen = .inMemory(&memory, w, h, .xrgb8888, 1);
    const src: [w * h]Rgba8 = @splat(.{ .r = 0, .g = 0, .b = 255, .a = 255 });
    const at = struct {
        fn f(sc: *Screen, x: usize, y: usize) u32 {
            return std.mem.readInt(u32, sc.memory[y * sc.pitch + x * 4 ..][0..4], .little);
        }
    }.f;
    _ = s.present(&src, &.{s.full()});
    s.setCursor(.{ .x = 4, .y = 4 }, 1);
    try testing.expect(s.present(&src, &.{}));
    try testing.expectEqual(@as(u32, 0x000000), at(&s, 4, 4)); // its tip
    try testing.expectEqual(@as(u32, 0xffffff), at(&s, 5, 6)); // inside
    try testing.expectEqual(@as(u32, 0x0000ff), at(&s, 3, 4));
    s.setCursor(.{ .x = 20, .y = 4 }, 2);
    try testing.expect(s.present(&src, &.{}));
    try testing.expectEqual(@as(u32, 0x0000ff), at(&s, 4, 4));
    try testing.expectEqual(@as(u32, 0x000000), at(&s, 21, 5));
    // Clipped at the edges.
    s.setCursor(.{ .x = 30, .y = 30 }, 2);
    try testing.expect(s.present(&src, &.{}));
    try testing.expectEqual(@as(u32, 0x000000), at(&s, 31, 31));
    s.setCursor(null, 1);
    try testing.expect(s.present(&src, &.{}));
    try testing.expectEqual(@as(u32, 0x0000ff), at(&s, 31, 31));
}

test "a turned screen: the picture turned as it is copied, the cursor with it" {
    // The screen is 4 x 2; the picture, a quarter turn, 2 x 4.
    var memory: [4 * 2 * 4]u8 = @splat(0);
    const at = struct {
        fn f(sc: *Screen, x: usize, y: usize) u32 {
            return std.mem.readInt(u32, sc.memory[y * sc.pitch + x * 4 ..][0..4], .little);
        }
    }.f;
    var picture: [8]Rgba8 = undefined;
    for (&picture, 0..) |*p, i| p.* = .{ .r = @intCast(i), .g = 0, .b = 0, .a = 255 };

    var s: Screen = .inMemory(&memory, 4, 2, .xrgb8888, 1);
    s.rotation = .half;
    try testing.expectEqual([2]u32{ 4, 2 }, s.pictureSize());
    try testing.expect(s.present(&picture, &.{s.full()}));
    // Upside down: the picture's first pixel is the screen's last.
    try testing.expectEqual(@as(u32, 7) << 16, at(&s, 0, 0));
    try testing.expectEqual(@as(u32, 0), at(&s, 3, 1));
    // A change to the picture's pixel 1, 0: the screen's 2, 1 only.
    picture[1].g = 255;
    picture[6].g = 255; // changed too, but not said to be
    try testing.expect(s.present(&picture, &.{.{ .x = 1, .y = 0, .width = 1, .height = 1 }}));
    try testing.expectEqual(@as(u32, 1) << 16 | 0xff00, at(&s, 2, 1));
    try testing.expectEqual(@as(u32, 6) << 16, at(&s, 1, 0));

    s = .inMemory(&memory, 4, 2, .xrgb8888, 1);
    s.rotation = .quarter;
    try testing.expectEqual([2]u32{ 2, 4 }, s.pictureSize());
    picture = undefined;
    for (&picture, 0..) |*p, i| p.* = .{ .r = @intCast(i), .g = 0, .b = 0, .a = 255 };
    try testing.expect(s.present(&picture, &.{.{ .width = 2, .height = 4 }}));
    // Turned clockwise: the picture's top left at the screen's top right,
    // its bottom left (pixel 6) at the screen's top left.
    try testing.expectEqual(@as(u32, 0), at(&s, 3, 0));
    try testing.expectEqual(@as(u32, 6) << 16, at(&s, 0, 0));
    try testing.expectEqual(@as(u32, 1) << 16, at(&s, 3, 1));
}

test "a turned screen: the cursor turned about its tip" {
    const w = 32;
    const h = 32;
    var memory: [w * h * 4]u8 = @splat(0);
    var s: Screen = .inMemory(&memory, w, h, .xrgb8888, 1);
    s.rotation = .half;
    const src: [w * h]Rgba8 = @splat(.{ .r = 0, .g = 0, .b = 255, .a = 255 });
    const at = struct {
        fn f(sc: *Screen, x: usize, y: usize) u32 {
            return std.mem.readInt(u32, sc.memory[y * sc.pitch + x * 4 ..][0..4], .little);
        }
    }.f;
    _ = s.present(&src, &.{s.full()});
    s.setCursor(.{ .x = 20, .y = 20 }, 1);
    try testing.expect(s.present(&src, &.{}));
    try testing.expectEqual(@as(u32, 0x000000), at(&s, 20, 20)); // its tip
    try testing.expectEqual(@as(u32, 0xffffff), at(&s, 19, 18)); // inside, up and left
    try testing.expectEqual(@as(u32, 0x0000ff), at(&s, 21, 22)); // not down and right
    // Moved: where it was is the picture again.
    s.setCursor(.{ .x = 10, .y = 10 }, 1);
    try testing.expect(s.present(&src, &.{}));
    try testing.expectEqual(@as(u32, 0x0000ff), at(&s, 19, 18));
}

test "rows converted several pixels at once: the pixels converted one by one" {
    const w = 37;
    const h = 5;
    var prng: std.Random.DefaultPrng = .init(5);
    const r = prng.random();
    var picture: [w * h]Rgba8 = undefined;
    for (&picture) |*p| p.* = .{ .r = r.int(u8), .g = r.int(u8), .b = r.int(u8), .a = r.int(u8) };
    const argb: Format = .{ .bytes = 4, .red = .{ .offset = 16, .length = 8 }, .green = .{ .offset = 8, .length = 8 }, .blue = .{ .length = 8 }, .alpha = .{ .offset = 24, .length = 8 } };
    const xbgr: Format = .{ .bytes = 4, .red = .{ .length = 8 }, .green = .{ .offset = 8, .length = 8 }, .blue = .{ .offset = 16, .length = 8 } };
    var abgr = xbgr;
    abgr.alpha = .{ .offset = 24, .length = 8 };
    try testing.expect(argb.words() != null and xbgr.words() != null and abgr.words() != null);
    for ([_]Format{ .rgb565, .xrgb8888, argb, xbgr, abgr }) |f| for ([_]Rotation{ .none, .half, .quarter, .three_quarters }) |rotation| {
        const sw, const sh = rotation.turnedSize(w, h);
        var memory: [w * h * 4]u8 = @splat(0);
        var s: Screen = .inMemory(&memory, sw, sh, f, 1);
        s.rotation = rotation;
        try testing.expect(s.present(&picture, &.{.{ .width = w, .height = h }}));
        for (0..sh) |y| {
            const from = rotation.row(y, sw, sh);
            for (0..sw) |x| {
                const at = memory[y * s.pitch + x * f.bytes ..][0..f.bytes];
                const got: u32 = if (f.bytes == 2) std.mem.readInt(u16, at[0..2], .little) else std.mem.readInt(u32, at[0..4], .little);
                try testing.expectEqual(f.pack(picture[pixelIndex(from, x)]), got);
            }
        }
    };
}
