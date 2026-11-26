// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Input from the kernel's event devices (/dev/input/event*): keyboards,
//! mice and touchscreens, read directly, and turned into zigulee's events
//! (`Input`). Keyboards are grabbed (the console under the application
//! does not see the keys). Used by the KMS and fbdev backends.

const std = @import("std");
const zigulee = @import("zigulee");
const core = zigulee.core;
const gestures = core.gestures;
const input = core.input;
const Key = input.Key;
const xkb = @import("zigulee-xkb");
const c = std.c;
const evdev = @This();

extern "c" fn ioctl(fd: c.fd_t, request: c_ulong, ...) c_int;

pub const ev_syn = 0;
pub const ev_key = 1;
pub const ev_rel = 2;
pub const ev_abs = 3;
pub const rel_x = 0;
pub const rel_y = 1;
pub const rel_hwheel = 6;
pub const rel_wheel = 8;
pub const abs_x = 0;
pub const abs_y = 1;
pub const abs_mt_slot = 0x2f;
pub const abs_mt_position_x = 0x35;
pub const abs_mt_tracking_id = 0x39;
pub const abs_mt_position_y = 0x36;
pub const btn_left = 0x110;
pub const btn_right = 0x111;
pub const btn_middle = 0x112;
pub const btn_touch = 0x14a;
pub const key_a = 30;

/// struct input_event: a time, then type, code and value.
pub const Event = extern struct {
    sec: isize,
    usec: isize,
    type: u16,
    code: u16,
    value: i32,
};

fn ior(nr: u8, size: usize) c_ulong {
    return (2 << 30) | (@as(c_ulong, size) << 16) | ('E' << 8) | nr;
}

pub const eviocgrab: c_ulong = (1 << 30) | (@sizeOf(c_int) << 16) | ('E' << 8) | 0x90;

fn eviocgbit(kind: u8, len: usize) c_ulong {
    return ior(0x20 + kind, len);
}

fn eviocgabs(axis: u8) c_ulong {
    return ior(0x40 + axis, 24); // struct input_absinfo
}

pub const Kind = enum { keyboard, mouse, touchscreen };

pub const Device = struct {
    fd: c.fd_t,
    kind: Kind,
    /// Touchscreens: the range of the X and Y axes.
    x_min: i32 = 0,
    x_max: i32 = 1,
    y_min: i32 = 0,
    y_max: i32 = 1,
};

fn hasBit(bits: []const u8, n: usize) bool {
    return n / 8 < bits.len and bits[n / 8] & (@as(u8, 1) << @intCast(n % 8)) != 0;
}

/// A touchscreen: positions, with BTN_TOUCH saying when a finger is down,
/// or fingers told apart by ABS_MT_TRACKING_ID (multi-touch controllers
/// such as Cypress's cyttsp5 send no BTN_TOUCH, ABS_X or ABS_Y).
fn isTouchscreen(axes: []const u8, keys: []const u8) bool {
    const mt = hasBit(axes, abs_mt_position_x) and hasBit(axes, abs_mt_position_y);
    if (mt and hasBit(axes, abs_mt_tracking_id)) return true;
    return (mt or hasBit(axes, abs_x)) and hasBit(keys, btn_touch);
}

/// What a device is, from the events it can send (null: none of ours).
pub fn classify(fd: c.fd_t) ?Device {
    var types: [4]u8 = @splat(0);
    if (ioctl(fd, eviocgbit(0, types.len), &types) < 0) return null;
    var keys: [96]u8 = @splat(0);
    if (hasBit(&types, ev_key)) _ = ioctl(fd, eviocgbit(ev_key, keys.len), &keys);
    if (hasBit(&types, ev_abs)) {
        var axes: [8]u8 = @splat(0);
        _ = ioctl(fd, eviocgbit(ev_abs, axes.len), &axes);
        const mt = hasBit(&axes, abs_mt_position_x);
        if (isTouchscreen(&axes, &keys)) {
            var d: Device = .{ .fd = fd, .kind = .touchscreen };
            var info: [6]i32 = undefined;
            if (ioctl(fd, eviocgabs(if (mt) abs_mt_position_x else abs_x), &info) == 0) {
                d.x_min = info[1];
                d.x_max = info[2];
            }
            if (ioctl(fd, eviocgabs(if (mt) abs_mt_position_y else abs_y), &info) == 0) {
                d.y_min = info[1];
                d.y_max = info[2];
            }
            return d;
        }
    }
    if (hasBit(&types, ev_rel)) {
        var rels: [2]u8 = @splat(0);
        _ = ioctl(fd, eviocgbit(ev_rel, rels.len), &rels);
        if (hasBit(&rels, rel_x) and hasBit(&keys, btn_left)) return .{ .fd = fd, .kind = .mouse };
    }
    if (hasBit(&keys, key_a)) return .{ .fd = fd, .kind = .keyboard };
    return null;
}

/// Opens the input devices there are (at most `out.len`).
pub fn openAll(out: []Device) usize {
    var n: usize = 0;
    var buf: [32]u8 = undefined;
    for (0..64) |i| {
        if (n == out.len) break;
        const path = std.fmt.bufPrintZ(&buf, "/dev/input/event{d}", .{i}) catch unreachable;
        const fd = c.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true });
        if (fd < 0) continue;
        const d = classify(fd) orelse {
            _ = c.close(fd);
            continue;
        };
        // Keys are ours only (not the console's too).
        if (d.kind == .keyboard) _ = ioctl(fd, eviocgrab, @as(c_int, 1));
        out[n] = d;
        n += 1;
    }
    return n;
}

pub fn close(d: Device) void {
    if (d.kind == .keyboard) _ = ioctl(d.fd, eviocgrab, @as(c_int, 0));
    _ = c.close(d.fd);
}

/// The events waiting on a device (into `buf`).
pub fn read(d: Device, buf: []Event) []Event {
    const n = c.read(d.fd, @ptrCast(buf.ptr), buf.len * @sizeOf(Event));
    if (n <= 0) return buf[0..0];
    return buf[0 .. @as(usize, @intCast(n)) / @sizeOf(Event)];
}

// ---- Touch area ----

/// The part of the screen a touch panel covers (screen pixels, before the
/// rotation), when it is not the whole screen: a panel over the top 128
/// rows of a 480x272 framebuffer is `480x128+0+0`. From
/// `ZIGULEE_TOUCH_AREA` (`WxH+X+Y`, or `WxH` at the top left).
pub fn touchAreaFromEnv() ?core.Rect {
    const v = c.getenv("ZIGULEE_TOUCH_AREA") orelse return null;
    return parseArea(std.mem.span(v));
}

pub fn parseArea(text: []const u8) ?core.Rect {
    var rest = std.mem.trim(u8, text, " ");
    var n: [4]f32 = .{ 0, 0, 0, 0 };
    for (&n, 0..) |*v, i| {
        if (i > 0) {
            if (rest.len == 0 and i == 2) break;
            const sep: u8 = if (i == 1) 'x' else '+';
            if (rest.len == 0 or rest[0] != sep) return null;
            rest = rest[1..];
        }
        const end = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
        if (end == 0) return null;
        v.* = @floatFromInt(std.fmt.parseInt(u32, rest[0..end], 10) catch return null);
        rest = rest[end..];
    }
    if (rest.len != 0 or n[0] == 0 or n[1] == 0) return null;
    return .{ .x = n[2], .y = n[3], .width = n[0], .height = n[1] };
}

// ---- Rotation ----

/// How far the picture is turned on the screen, clockwise: for panels
/// mounted turned (`ZIGULEE_ROTATION`, in degrees). The application draws
/// upright; the backend turns the picture as it copies it to the screen
/// (a 180° turn is the pixels in reverse order), and turns input back.
pub const Rotation = enum(u16) {
    none = 0,
    quarter = 90,
    half = 180,
    three_quarters = 270,

    /// From `ZIGULEE_ROTATION` (0, 90, 180 or 270; else none).
    pub fn fromEnv() Rotation {
        const v = c.getenv("ZIGULEE_ROTATION") orelse return .none;
        return parse(std.mem.span(v));
    }

    pub fn parse(text: []const u8) Rotation {
        const deg = std.fmt.parseInt(i32, std.mem.trim(u8, text, " "), 10) catch return .none;
        return switch (@mod(deg, 360)) {
            90 => .quarter,
            180 => .half,
            270 => .three_quarters,
            else => .none,
        };
    }

    /// Whether the picture's width is the screen's height.
    pub fn swaps(r: Rotation) bool {
        return r == .quarter or r == .three_quarters;
    }

    /// The picture's size for a screen of `w` x `h` (or the screen's for a
    /// picture's: the same).
    pub fn turnedSize(r: Rotation, w: u32, h: u32) [2]u32 {
        return if (r.swaps()) .{ h, w } else .{ w, h };
    }

    /// Where a pixel of the picture (`pw` x `ph`) goes on the screen. With
    /// `- 1` from the far edges: pixel centers map to pixel centers, and
    /// positions within 0 to size - 1 stay within it.
    pub fn toScreen(r: Rotation, p: core.Point, pw: f32, ph: f32) core.Point {
        return switch (r) {
            .none => p,
            .half => .{ .x = pw - 1 - p.x, .y = ph - 1 - p.y },
            .quarter => .{ .x = ph - 1 - p.y, .y = p.x },
            .three_quarters => .{ .x = p.y, .y = pw - 1 - p.x },
        };
    }

    /// Where a point of the screen (`sw` x `sh`) is in the picture.
    pub fn fromScreen(r: Rotation, p: core.Point, sw: f32, sh: f32) core.Point {
        return switch (r) {
            .none => p,
            .half => .{ .x = sw - 1 - p.x, .y = sh - 1 - p.y },
            .quarter => .{ .x = p.y, .y = sw - 1 - p.x },
            .three_quarters => .{ .x = sh - 1 - p.y, .y = p.x },
        };
    }

    /// A direction (a mouse's motion) on the screen, in the picture.
    pub fn vectorFromScreen(r: Rotation, v: core.Point) core.Point {
        return switch (r) {
            .none => v,
            .half => .{ .x = -v.x, .y = -v.y },
            .quarter => .{ .x = v.y, .y = -v.x },
            .three_quarters => .{ .x = -v.y, .y = v.x },
        };
    }

    /// A direction in the picture, on the screen.
    pub fn vectorToScreen(r: Rotation, v: core.Point) core.Point {
        return switch (r) {
            .none => v,
            .half => .{ .x = -v.x, .y = -v.y },
            .quarter => .{ .x = -v.y, .y = v.x },
            .three_quarters => .{ .x = v.y, .y = -v.x },
        };
    }

    /// The pixels of the screen a rectangle of the picture (`pw` x `ph`
    /// pixels) covers.
    pub fn rectToScreen(r: Rotation, rect: core.Rect, pw: f32, ph: f32) core.Rect {
        if (r == .none or rect.isEmpty()) return rect;
        // The far edges are pixel ends: as points, the last pixel's.
        const a = r.toScreen(.{ .x = rect.x, .y = rect.y }, pw, ph);
        const b = r.toScreen(.{ .x = rect.x + rect.width - 1, .y = rect.y + rect.height - 1 }, pw, ph);
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        return .{ .x = x0, .y = y0, .width = @max(a.x, b.x) - x0 + 1, .height = @max(a.y, b.y) - y0 + 1 };
    }

    /// Where row `y` of the screen (`sw` x `sh`) takes its pixels from in
    /// the picture: pixel x of the row is `src[base + x * step]`.
    pub fn row(r: Rotation, y: usize, sw: usize, sh: usize) struct { base: isize, step: isize } {
        const iy: isize = @intCast(y);
        const w: isize = @intCast(sw);
        const h: isize = @intCast(sh);
        return switch (r) {
            .none => .{ .base = iy * w, .step = 1 },
            .half => .{ .base = (h - 1 - iy) * w + (w - 1), .step = -1 },
            // The picture is sh wide, sw tall.
            .quarter => .{ .base = (w - 1) * h + iy, .step = -h },
            .three_quarters => .{ .base = h - 1 - iy, .step = h },
        };
    }
};

// ---- Input (independent of the display: tested without one) ----

/// Turns event devices' events into zigulee's, for a window of `width` x
/// `height` logical pixels.
pub const Input = struct {
    ui: *core.Window,
    scale: f32 = 1,
    width: f32,
    height: f32,
    /// The picture's turn on the screen: touches and motion turned back.
    rotation: Rotation = .none,
    /// The part of the screen the touch panel covers (screen pixels,
    /// before the rotation; null: all of it).
    touch_area: ?core.Rect = null,
    keyboard: ?xkb.Keyboard = null,
    /// The pointer (logical pixels), and what changed since the last
    /// SYN_REPORT.
    position: core.Point = .{},
    /// A single-touch screen's position on the screen (logical pixels),
    /// before the rotation.
    touch_at: core.Point = .{},
    moved: bool = false,
    touching: bool = false,
    touch_changed: bool = false,
    /// A multi-touch screen (slots: Linux's protocol B): each finger by
    /// its slot, to the core (the first one works as the mouse).
    mt: bool = false,
    slot: usize = 0,
    slots: [10]Slot = @splat(.{}),
    /// Modifiers (without libxkbcommon: kept here).
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    meta: bool = false,
    altgr: bool = false,
    /// Set by Ctrl+Alt+Backspace.
    quit: bool = false,
    /// Set when the pointer moved (the cursor follows).
    cursor_moved: bool = false,

    /// Logical pixels scrolled per wheel notch.
    const wheel_step = 40;

    fn mods(in: *const Input) input.Modifiers {
        if (in.keyboard) |*k| {
            var kk = k.*;
            return .{ .shift = kk.modifierActive("Shift"), .control = kk.modifierActive("Control"), .alt = kk.modifierActive("Mod1"), .meta = kk.modifierActive("Mod4") };
        }
        return .{ .shift = in.shift, .control = in.control, .alt = in.alt, .meta = in.meta };
    }

    pub fn handle(in: *Input, device: evdev.Device, events: []const evdev.Event) void {
        for (events) |e| switch (device.kind) {
            .keyboard => if (e.type == evdev.ev_key) in.key(e.code, e.value),
            .mouse => in.mouse(e),
            .touchscreen => in.touch(device, e),
        };
    }

    fn mouse(in: *Input, e: evdev.Event) void {
        switch (e.type) {
            evdev.ev_rel => switch (e.code) {
                evdev.rel_x, evdev.rel_y => {
                    const v: f32 = @as(f32, @floatFromInt(e.value)) / in.scale;
                    const d = in.rotation.vectorFromScreen(if (e.code == evdev.rel_x) .{ .x = v } else .{ .y = v });
                    in.position.x = std.math.clamp(in.position.x + d.x, 0, in.width - 1);
                    in.position.y = std.math.clamp(in.position.y + d.y, 0, in.height - 1);
                    in.moved = true;
                },
                evdev.rel_wheel => in.ui.dispatchPointer(.{ .wheel = .{ .position = in.position, .delta = .{ .x = 0, .y = @as(f32, @floatFromInt(e.value)) * wheel_step } } }),
                evdev.rel_hwheel => in.ui.dispatchPointer(.{ .wheel = .{ .position = in.position, .delta = .{ .x = -@as(f32, @floatFromInt(e.value)) * wheel_step, .y = 0 } } }),
                else => {},
            },
            evdev.ev_key => {
                in.flushMove();
                const button: input.PointerButton = switch (e.code) {
                    evdev.btn_left => .left,
                    evdev.btn_right => .right,
                    evdev.btn_middle => .middle,
                    else => .other,
                };
                if (e.value == 1) {
                    in.ui.dispatchPointer(.{ .pressed = .{ .position = in.position, .button = button, .modifiers = in.mods() } });
                } else if (e.value == 0) in.ui.dispatchPointer(.{ .released = .{ .position = in.position, .button = button } });
            },
            evdev.ev_syn => in.flushMove(),
            else => {},
        }
    }

    fn flushMove(in: *Input) void {
        if (!in.moved) return;
        in.moved = false;
        in.cursor_moved = true;
        in.ui.dispatchPointer(.{ .moved = .{ .position = in.position } });
    }

    const Slot = struct { id: i32 = -1, at: core.Point = .{}, on_screen: core.Point = .{}, started: bool = false, ended: bool = false, moved: bool = false };

    /// The screen's size (logical pixels): the window's, turned.
    fn screenSize(in: *const Input) core.Size {
        return if (in.rotation.swaps()) .{ .width = in.height, .height = in.width } else .{ .width = in.width, .height = in.height };
    }

    /// Where on the screen (logical pixels) a touch panel's reading lies:
    /// its range spread over the touch area.
    fn onScreen(in: *const Input, d: evdev.Device, x: ?i32, y: ?i32, at: core.Point) core.Point {
        const s = in.screenSize();
        const a: core.Rect = if (in.touch_area) |r|
            .{ .x = r.x / in.scale, .y = r.y / in.scale, .width = r.width / in.scale, .height = r.height / in.scale }
        else
            .{ .width = s.width, .height = s.height };
        return .{
            .x = if (x) |v| a.x + mapAxis(v, d.x_min, d.x_max, a.width) else at.x,
            .y = if (y) |v| a.y + mapAxis(v, d.y_min, d.y_max, a.height) else at.y,
        };
    }

    /// A point of the screen, in the window.
    fn unturned(in: *const Input, p: core.Point) core.Point {
        const s = in.screenSize();
        return in.rotation.fromScreen(p, s.width, s.height);
    }

    fn touch(in: *Input, d: evdev.Device, e: evdev.Event) void {
        if (e.type == evdev.ev_abs and (e.code == evdev.abs_mt_slot or e.code == evdev.abs_mt_tracking_id)) in.mt = true;
        if (in.mt) return in.multiTouch(d, e);
        switch (e.type) {
            evdev.ev_abs => switch (e.code) {
                evdev.abs_x, evdev.abs_mt_position_x => {
                    in.touch_at = in.onScreen(d, e.value, null, in.touch_at);
                    in.position = in.unturned(in.touch_at);
                    in.moved = true;
                },
                evdev.abs_y, evdev.abs_mt_position_y => {
                    in.touch_at = in.onScreen(d, null, e.value, in.touch_at);
                    in.position = in.unturned(in.touch_at);
                    in.moved = true;
                },
                else => {},
            },
            evdev.ev_key => if (e.code == evdev.btn_touch) {
                in.touching = e.value != 0;
                in.touch_changed = true;
            },
            evdev.ev_syn => {
                // A finger down: the press where it is; up: the release.
                if (in.touch_changed and in.touching) {
                    in.moved = false;
                    in.ui.dispatchPointer(.{ .moved = .{ .position = in.position } });
                    in.ui.dispatchPointer(.{ .pressed = .{ .position = in.position } });
                } else if (in.touch_changed) {
                    in.ui.dispatchPointer(.{ .released = .{ .position = in.position } });
                    in.ui.dispatchPointer(.exit);
                } else if (in.touching) in.flushMove();
                in.touch_changed = false;
                in.moved = false;
            },
            else => {},
        }
    }

    fn multiTouch(in: *Input, d: evdev.Device, e: evdev.Event) void {
        const s = &in.slots[in.slot];
        switch (e.type) {
            evdev.ev_abs => switch (e.code) {
                evdev.abs_mt_slot => in.slot = @intCast(std.math.clamp(e.value, 0, in.slots.len - 1)),
                evdev.abs_mt_tracking_id => if (e.value < 0) {
                    if (s.id >= 0) s.ended = true;
                } else {
                    s.id = e.value;
                    s.started = true;
                },
                evdev.abs_mt_position_x => {
                    s.on_screen = in.onScreen(d, e.value, null, s.on_screen);
                    s.at = in.unturned(s.on_screen);
                    s.moved = true;
                },
                evdev.abs_mt_position_y => {
                    s.on_screen = in.onScreen(d, null, e.value, s.on_screen);
                    s.at = in.unturned(s.on_screen);
                    s.moved = true;
                },
                else => {},
            },
            evdev.ev_syn => for (&in.slots) |*f| {
                if (f.id < 0) continue;
                const id: u64 = @intCast(f.id);
                if (f.started) {
                    gestures.dispatchTouch(in.ui, id, .down, f.at);
                } else if (f.ended) {
                    gestures.dispatchTouch(in.ui, id, .up, f.at);
                    f.id = -1;
                } else if (f.moved) gestures.dispatchTouch(in.ui, id, .moved, f.at);
                f.started = false;
                f.ended = false;
                f.moved = false;
            },
            else => {},
        }
    }

    fn mapAxis(v: i32, min: i32, max: i32, size: f32) f32 {
        if (max <= min) return 0;
        const t = @as(f32, @floatFromInt(v - min)) / @as(f32, @floatFromInt(max - min));
        return std.math.clamp(t, 0, 1) * (size - 1);
    }

    /// A key: pressed (1), released (0) or repeated by the kernel (2).
    pub fn key(in: *Input, code: u16, value: i32) void {
        const pressed = value != 0;
        const repeat = value == 2;
        const kind: input.KeyEventKind = if (pressed) .pressed else .released;
        var sym: u32 = 0;
        var text: []const u8 = "";
        var buf: [4]u8 = undefined;
        if (in.keyboard) |*k| {
            if (pressed) {
                const r = k.press(code);
                sym = r.sym;
                text = r.text;
            } else sym = k.keysym(code);
            if (!repeat) k.updateKey(code, pressed);
            in.altgr = k.modifierActive("Mod5");
        } else {
            switch (code) {
                42, 54 => in.shift = pressed,
                29, 97 => in.control = pressed,
                56 => in.alt = pressed,
                100 => in.altgr = pressed,
                125, 126 => in.meta = pressed,
                else => {},
            }
            sym = usKeysym(code);
            if (us(code, in.shift)) |ch| {
                buf[0] = ch;
                text = buf[0..1];
            }
        }
        const m = in.mods();
        // The way out (the keyboard is grabbed).
        if (pressed and m.control and m.alt and (sym == 0xff08 or code == 14)) {
            in.quit = true;
            return;
        }
        if (specialKey(sym, m)) |t| return in.ui.dispatchKey(kind, .{ .text = t, .modifiers = m, .repeat = repeat });
        if (m.control and !in.altgr) {
            const base = if (in.keyboard == null) (us(code, false) orelse 0) else sym;
            if (base > 0 and base < 0x80 and std.ascii.isAlphanumeric(@intCast(base)))
                return in.ui.dispatchKey(kind, .{ .text = ascii[std.ascii.toLower(@intCast(base))..][0..1], .modifiers = m, .repeat = repeat });
        }
        if (!pressed or text.len == 0 or text[0] < 0x20 or text[0] == 0x7f) return;
        in.ui.dispatchKey(.pressed, .{ .text = text, .repeat = repeat });
        in.ui.dispatchKey(.released, .{ .text = text });
    }
};

const ascii: [128]u8 = blk: {
    var t: [128]u8 = undefined;
    for (&t, 0..) |*b, i| b.* = i;
    break :blk t;
};

/// zigulee's code for a special key, from its keysym.
fn specialKey(sym: u32, mods: input.Modifiers) ?[]const u8 {
    return switch (sym) {
        0xff08 => Key.backspace,
        0xff09 => if (mods.shift) Key.back_tab else Key.tab,
        0xfe20 => Key.back_tab,
        0xff0d, 0xff8d => Key.@"return",
        0xff1b => Key.escape,
        0xffff, 0xff9f => Key.delete,
        0xff51, 0xff96 => Key.left_arrow,
        0xff52, 0xff97 => Key.up_arrow,
        0xff53, 0xff98 => Key.right_arrow,
        0xff54, 0xff99 => Key.down_arrow,
        0xff50, 0xff95 => Key.home,
        0xff57, 0xff9c => Key.end,
        0xff55, 0xff9a => Key.page_up,
        0xff56, 0xff9b => Key.page_down,
        else => null,
    };
}

/// Without libxkbcommon: the keysyms of the special keys (evdev codes).
fn usKeysym(code: u16) u32 {
    return switch (code) {
        1 => 0xff1b,
        14 => 0xff08,
        15 => 0xff09,
        28, 96 => 0xff0d,
        102 => 0xff50,
        103 => 0xff52,
        104 => 0xff55,
        105 => 0xff51,
        106 => 0xff53,
        107 => 0xff57,
        108 => 0xff54,
        109 => 0xff56,
        111 => 0xffff,
        else => 0,
    };
}

/// Without libxkbcommon: a US layout's characters (evdev codes).
fn us(code: u16, shift: bool) ?u8 {
    const rows = [_]struct { u16, []const u8, []const u8 }{
        .{ 2, "1234567890-=", "!@#$%^&*()_+" },
        .{ 16, "qwertyuiop[]", "QWERTYUIOP{}" },
        .{ 30, "asdfghjkl;'`", "ASDFGHJKL:\"~" },
        .{ 43, "\\zxcvbnm,./", "|ZXCVBNM<>?" },
    };
    if (code == 57) return ' ';
    for (rows) |r| if (code >= r[0] and code < r[0] + r[1].len) {
        return (if (shift) r[2] else r[1])[code - r[0]];
    };
    return null;
}

test "ioctl numbers" {
    try std.testing.expectEqual(@as(c_ulong, 0x40044590), eviocgrab);
    try std.testing.expectEqual(@as(c_ulong, 0x80044520), eviocgbit(0, 4));
    try std.testing.expectEqual(@as(c_ulong, 0x80184575), eviocgabs(abs_mt_position_x));
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(isize) + 8), @sizeOf(Event));
}

const testing = std.testing;

/// A window for the backends' tests: a red button that turns blue when
/// clicked, and a focus scope keeping the text typed.
pub const TestUi = struct {
    ui: core.Window = undefined,
    button: core.items.Rectangle = .{},
    touch: core.items.TouchArea = .{},
    keys: core.items.FocusScope = .{},
    clicks: usize = 0,
    typed: [64]u8 = undefined,
    typed_len: usize = 0,

    pub fn init(t: *TestUi) !void {
        t.* = .{};
        t.ui.init(testing.allocator, .{ .width = 120, .height = 80 });
        t.ui.rootItem().appendChildren(&.{ &t.button.item, &t.keys.item });
        t.button.item.setGeometry(.{ .x = 10, .y = 10, .width = 50, .height = 30 });
        t.button.background.set(.color(.rgb(0xff0000)));
        t.button.item.appendChild(&t.touch.item);
        try t.touch.item.fillParent(testing.allocator);
        t.touch.clicked.setHandler(t, struct {
            fn f(self: *TestUi) void {
                self.clicks += 1;
                self.button.background.set(.color(.rgb(0x0000ff)));
            }
        }.f);
        t.keys.key_pressed.setHandler(t, struct {
            fn f(self: *TestUi, e: input.KeyEvent) input.EventResult {
                const n = @min(e.text.len, self.typed.len - self.typed_len);
                @memcpy(self.typed[self.typed_len..][0..n], e.text[0..n]);
                self.typed_len += n;
                return .accept;
            }
        }.f);
    }

    pub fn deinit(t: *TestUi) void {
        t.ui.deinit();
        t.keys.deinit();
        t.touch.deinit();
        t.button.deinit();
    }
};

fn ev(kind: u16, code: u16, value: i32) evdev.Event {
    return .{ .sec = 0, .usec = 0, .type = kind, .code = code, .value = value };
}

const syn = ev(evdev.ev_syn, 0, 0);

fn typeKeys(in: *Input, codes: []const struct { u16, i32 }) void {
    for (codes) |k| in.key(k[0], k[1]);
}

test "touchscreens: with BTN_TOUCH, or multi-touch by tracking id alone" {
    const Bits = struct {
        fn of(comptime n: usize, set: []const usize) [n]u8 {
            var b: [n]u8 = @splat(0);
            for (set) |i| b[i / 8] |= @as(u8, 1) << @intCast(i % 8);
            return b;
        }
    };
    const no_keys = Bits.of(96, &.{});
    const touch_key = Bits.of(96, &.{btn_touch});
    // A single-touch panel.
    try testing.expect(isTouchscreen(&Bits.of(8, &.{ abs_x, abs_y }), &touch_key));
    // A multi-touch one with BTN_TOUCH.
    try testing.expect(isTouchscreen(&Bits.of(8, &.{ abs_mt_slot, abs_mt_position_x, abs_mt_position_y }), &touch_key));
    // cyttsp5_mt: slots and tracking ids, no BTN_TOUCH, no ABS_X/ABS_Y.
    try testing.expect(isTouchscreen(&Bits.of(8, &.{ abs_mt_slot, abs_mt_position_x, abs_mt_position_y, abs_mt_tracking_id }), &no_keys));
    // Not touchscreens: positions with no way to tell a touch (a tablet
    // or joystick's axes).
    try testing.expect(!isTouchscreen(&Bits.of(8, &.{ abs_x, abs_y }), &no_keys));
    try testing.expect(!isTouchscreen(&Bits.of(8, &.{ abs_mt_position_x, abs_mt_position_y }), &no_keys));
}

test "rotation: points, rectangles and rows of pixels, turned and back" {
    const pw = 6;
    const ph = 4;
    for ([_]Rotation{ .none, .quarter, .half, .three_quarters }) |r| {
        const sw, const sh = r.turnedSize(pw, ph);
        // Each pixel of the picture goes to one of the screen, and back.
        for (0..ph) |y| for (0..pw) |x| {
            const p: core.Point = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
            const on = r.toScreen(p, pw, ph);
            try testing.expect(on.x >= 0 and on.x < @as(f32, @floatFromInt(sw)) and on.y >= 0 and on.y < @as(f32, @floatFromInt(sh)));
            try testing.expectEqual(p, r.fromScreen(on, @floatFromInt(sw), @floatFromInt(sh)));
            // The screen's rows take that pixel from there.
            const from = r.row(@intFromFloat(on.y), sw, sh);
            try testing.expectEqual(@as(isize, @intCast(y * pw + x)), from.base + @as(isize, @intFromFloat(on.x)) * from.step);
            // A pixel's rectangle is that pixel's.
            try testing.expectEqual(core.Rect{ .x = on.x, .y = on.y, .width = 1, .height = 1 }, r.rectToScreen(.{ .x = p.x, .y = p.y, .width = 1, .height = 1 }, pw, ph));
        };
        // Directions turn as points do.
        const a = r.toScreen(.{ .x = 1, .y = 1 }, pw, ph);
        const b = r.toScreen(.{ .x = 3, .y = 2 }, pw, ph);
        try testing.expectEqual(core.Point{ .x = b.x - a.x, .y = b.y - a.y }, r.vectorToScreen(.{ .x = 2, .y = 1 }));
        try testing.expectEqual(core.Point{ .x = 2, .y = 1 }, r.vectorFromScreen(.{ .x = b.x - a.x, .y = b.y - a.y }));
    }
    // A rectangle: the pixels it covers, turned.
    try testing.expectEqual(core.Rect{ .x = 3, .y = 1, .width = 2, .height = 3 }, Rotation.half.rectToScreen(.{ .x = 1, .y = 0, .width = 2, .height = 3 }, pw, ph));
    try testing.expectEqual(core.Rect{ .x = 1, .y = 1, .width = 3, .height = 2 }, Rotation.quarter.rectToScreen(.{ .x = 1, .y = 0, .width = 2, .height = 3 }, pw, ph));
    try testing.expectEqual(Rotation.half, Rotation.parse("180"));
    try testing.expectEqual(Rotation.three_quarters, Rotation.parse("-90"));
    try testing.expectEqual(Rotation.none, Rotation.parse("45"));
}

test "a turned screen: touches and the mouse turned back" {
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    const screen: evdev.Device = .{ .fd = -1, .kind = .touchscreen, .x_min = 0, .x_max = 1000, .y_min = 0, .y_max = 1000 };
    const mouse: evdev.Device = .{ .fd = -1, .kind = .mouse };
    // Upside down: the panel's top left is the window's bottom right.
    var in: Input = .{ .ui = &t.ui, .width = 121, .height = 81, .rotation = .half };
    in.handle(screen, &.{ ev(evdev.ev_abs, evdev.abs_mt_position_x, 0), ev(evdev.ev_abs, evdev.abs_mt_position_y, 0), ev(evdev.ev_key, evdev.btn_touch, 1), syn });
    try testing.expectEqual(core.Point{ .x = 120, .y = 80 }, in.position);
    in.handle(screen, &.{ ev(evdev.ev_key, evdev.btn_touch, 0), syn });
    // Multi-touch fingers too: the button (at 10..60, 10..40 in the
    // window) tapped where the panel shows it, at its far corner.
    const clicks = t.clicks;
    in.handle(screen, &.{ ev(evdev.ev_abs, evdev.abs_mt_slot, 0), ev(evdev.ev_abs, evdev.abs_mt_tracking_id, 1), ev(evdev.ev_abs, evdev.abs_mt_position_x, 750), ev(evdev.ev_abs, evdev.abs_mt_position_y, 750), syn });
    try testing.expectEqual(core.Point{ .x = 30, .y = 20 }, in.slots[0].at);
    in.handle(screen, &.{ ev(evdev.ev_abs, evdev.abs_mt_tracking_id, -1), syn });
    try testing.expectEqual(clicks + 1, t.clicks);
    // The mouse: right on the panel is left in the window.
    in.position = .{ .x = 50, .y = 50 };
    in.handle(mouse, &.{ ev(evdev.ev_rel, evdev.rel_x, 10), ev(evdev.ev_rel, evdev.rel_y, 5), syn });
    try testing.expectEqual(core.Point{ .x = 40, .y = 45 }, in.position);

    // A quarter turn: the panel (81 wide, 121 tall) shows the window's
    // left edge along its top.
    var q: Input = .{ .ui = &t.ui, .width = 121, .height = 81, .rotation = .quarter };
    q.handle(screen, &.{ ev(evdev.ev_abs, evdev.abs_mt_position_x, 1000), ev(evdev.ev_abs, evdev.abs_mt_position_y, 0), ev(evdev.ev_key, evdev.btn_touch, 1), syn });
    try testing.expectEqual(core.Point{ .x = 0, .y = 0 }, q.position);
    q.handle(screen, &.{ ev(evdev.ev_key, evdev.btn_touch, 0), syn });
    q.position = .{ .x = 50, .y = 50 };
    q.handle(mouse, &.{ ev(evdev.ev_rel, evdev.rel_y, 10), syn });
    try testing.expectEqual(core.Point{ .x = 60, .y = 50 }, q.position);
}

test "a touch panel over part of the screen, turned" {
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    try testing.expectEqual(core.Rect{ .width = 480, .height = 128 }, parseArea("480x128+0+0").?);
    try testing.expectEqual(core.Rect{ .x = 4, .y = 2, .width = 480, .height = 128 }, parseArea(" 480x128+4+2").?);
    try testing.expectEqual(core.Rect{ .width = 480, .height = 128 }, parseArea("480x128").?);
    for ([_][]const u8{ "", "480", "480x", "x128", "480x128+0", "480x128+0+0+0", "0x128", "480x128-1+0" }) |bad|
        try testing.expectEqual(@as(?core.Rect, null), parseArea(bad));

    // A 480x272 framebuffer whose display and panel cover its top 128
    // rows, mounted upside down: those rows show the window's 144 to 271.
    const screen: evdev.Device = .{ .fd = -1, .kind = .touchscreen, .x_min = 0, .x_max = 1000, .y_min = 0, .y_max = 1000 };
    var in: Input = .{ .ui = &t.ui, .width = 480, .height = 272, .rotation = .half, .touch_area = .{ .width = 480, .height = 128 } };
    in.handle(screen, &.{ ev(evdev.ev_abs, evdev.abs_mt_slot, 0), ev(evdev.ev_abs, evdev.abs_mt_tracking_id, 1), ev(evdev.ev_abs, evdev.abs_mt_position_x, 0), ev(evdev.ev_abs, evdev.abs_mt_position_y, 0), syn });
    try testing.expectEqual(core.Point{ .x = 479, .y = 271 }, in.slots[0].at);
    in.handle(screen, &.{ ev(evdev.ev_abs, evdev.abs_mt_position_x, 1000), ev(evdev.ev_abs, evdev.abs_mt_position_y, 1000), syn });
    try testing.expectEqual(core.Point{ .x = 0, .y = 144 }, in.slots[0].at);
    in.handle(screen, &.{ ev(evdev.ev_abs, evdev.abs_mt_tracking_id, -1), syn });
    // Upright, at 2x: the area in screen pixels, the window's logical.
    var up: Input = .{ .ui = &t.ui, .scale = 2, .width = 240, .height = 136, .touch_area = .{ .x = 0, .y = 16, .width = 480, .height = 128 } };
    up.handle(screen, &.{ ev(evdev.ev_abs, evdev.abs_y, 1000), ev(evdev.ev_abs, evdev.abs_x, 0), ev(evdev.ev_key, evdev.btn_touch, 1), syn });
    try testing.expectEqual(core.Point{ .x = 0, .y = 8 + 63 }, up.position);
    up.handle(screen, &.{ ev(evdev.ev_key, evdev.btn_touch, 0), syn });
}

test "input from event devices: a mouse, a touchscreen, a keyboard" {
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    var in: Input = .{ .ui = &t.ui, .width = 120, .height = 80 };
    const mouse: evdev.Device = .{ .fd = -1, .kind = .mouse };
    const screen: evdev.Device = .{ .fd = -1, .kind = .touchscreen, .x_min = 0, .x_max = 1000, .y_min = 0, .y_max = 1000 };
    const keyboard: evdev.Device = .{ .fd = -1, .kind = .keyboard };

    // The mouse moves the pointer (relative, clamped), and clicks.
    in.handle(mouse, &.{ ev(evdev.ev_rel, evdev.rel_x, 30), ev(evdev.ev_rel, evdev.rel_y, 20), syn });
    try testing.expectEqual(core.Point{ .x = 30, .y = 20 }, in.position);
    in.handle(mouse, &.{ ev(evdev.ev_key, evdev.btn_left, 1), syn, ev(evdev.ev_key, evdev.btn_left, 0), syn });
    core.runChangeHandlers();
    try testing.expectEqual(@as(usize, 1), t.clicks);
    in.handle(mouse, &.{ ev(evdev.ev_rel, evdev.rel_x, -500), syn });
    try testing.expectEqual(@as(f32, 0), in.position.x);

    // A finger: a press where it touches (the axes scaled to the window).
    in.handle(screen, &.{ ev(evdev.ev_abs, evdev.abs_mt_position_x, 250), ev(evdev.ev_abs, evdev.abs_mt_position_y, 250), ev(evdev.ev_key, evdev.btn_touch, 1), syn });
    try testing.expectApproxEqAbs(@as(f32, 29.75), in.position.x, 0.01);
    in.handle(screen, &.{ ev(evdev.ev_key, evdev.btn_touch, 0), syn });
    try testing.expectEqual(@as(usize, 2), t.clicks);

    // Keys, with the built-in US layout: text with Shift, special keys,
    // Ctrl+C, and the kernel's repeats.
    t.keys.focus();
    typeKeys(&in, &.{ .{ 35, 1 }, .{ 35, 0 }, .{ 42, 1 }, .{ 30, 1 }, .{ 30, 0 }, .{ 42, 0 }, .{ 28, 1 }, .{ 105, 1 }, .{ 105, 2 }, .{ 29, 1 }, .{ 46, 1 }, .{ 29, 0 } });
    try testing.expectEqualStrings("hA" ++ Key.@"return" ++ Key.left_arrow ++ Key.left_arrow ++ "c", t.typed[0..t.typed_len]);
    _ = keyboard;

    // With libxkbcommon, if there is one: the same through a US keymap.
    if (xkb.Keyboard.init()) |k| {
        var kb = k;
        if (kb.setKeymapNames(.{ .layout = "us" })) {
            in.keyboard = kb;
            defer {
                in.keyboard.?.deinit();
                in.keyboard = null;
            }
            t.typed_len = 0;
            typeKeys(&in, &.{ .{ 35, 1 }, .{ 35, 0 }, .{ 42, 1 }, .{ 30, 1 }, .{ 30, 0 }, .{ 42, 0 }, .{ 28, 1 }, .{ 29, 1 }, .{ 46, 1 }, .{ 46, 0 }, .{ 29, 0 } });
            try testing.expectEqualStrings("hA" ++ Key.@"return" ++ "c", t.typed[0..t.typed_len]);
        } else kb.deinit();
    }

    // Ctrl+Alt+Backspace: the way out.
    typeKeys(&in, &.{ .{ 29, 1 }, .{ 56, 1 }, .{ 14, 1 } });
    try testing.expect(in.quit);
}

test "a multi-touch screen: fingers by slot, the first one as the mouse, two pinching" {
    var t: TestUi = undefined;
    try t.init();
    defer t.deinit();
    var pinch: core.items.PinchArea = .{};
    defer pinch.deinit();
    t.ui.rootItem().appendChild(&pinch.item);
    pinch.item.setGeometry(.{ .y = 50, .width = 120, .height = 30 });
    var in: Input = .{ .ui = &t.ui, .width = 121, .height = 81 };
    const screen: evdev.Device = .{ .fd = -1, .kind = .touchscreen, .x_min = 0, .x_max = 120, .y_min = 0, .y_max = 80 };
    // A tap on the button (at 30, 20).
    in.handle(screen, &.{ ev(evdev.ev_abs, evdev.abs_mt_slot, 0), ev(evdev.ev_abs, evdev.abs_mt_tracking_id, 5), ev(evdev.ev_abs, evdev.abs_mt_position_x, 30), ev(evdev.ev_abs, evdev.abs_mt_position_y, 20), syn });
    in.handle(screen, &.{ ev(evdev.ev_abs, evdev.abs_mt_tracking_id, -1), syn });
    try testing.expectEqual(@as(usize, 1), t.clicks);
    // Two fingers in the pinch area, then one moves away.
    in.handle(screen, &.{ ev(evdev.ev_abs, evdev.abs_mt_slot, 0), ev(evdev.ev_abs, evdev.abs_mt_tracking_id, 6), ev(evdev.ev_abs, evdev.abs_mt_position_x, 50), ev(evdev.ev_abs, evdev.abs_mt_position_y, 65), syn });
    in.handle(screen, &.{ ev(evdev.ev_abs, evdev.abs_mt_slot, 1), ev(evdev.ev_abs, evdev.abs_mt_tracking_id, 7), ev(evdev.ev_abs, evdev.abs_mt_position_x, 70), ev(evdev.ev_abs, evdev.abs_mt_position_y, 65), syn });
    try testing.expect(pinch.active.get());
    in.handle(screen, &.{ ev(evdev.ev_abs, evdev.abs_mt_position_x, 90), syn });
    try testing.expectApproxEqAbs(@as(f32, 2), pinch.scale.get(), 0.01);
    in.handle(screen, &.{ ev(evdev.ev_abs, evdev.abs_mt_tracking_id, -1), ev(evdev.ev_abs, evdev.abs_mt_slot, 0), ev(evdev.ev_abs, evdev.abs_mt_tracking_id, -1), syn });
    try testing.expect(!pinch.active.get());
}
