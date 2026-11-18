// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Instantiates the core for a bare-metal target so `zig build check-mcu`
//! actually analyzes and compiles it (generic code is only compiled when used).

const std = @import("std");
const zigulee = @import("zigulee");

var heap: [64 * 1024]u8 = undefined;

const State = struct {
    gpa: std.mem.Allocator,
    a: zigulee.Property(i32) = .init(1),
    b: zigulee.Property(i32) = .init(0),
    x: zigulee.Property(f32) = .init(0),
    on_tap: zigulee.Callback(fn (i32) void) = .{},
    timer: zigulee.Timer = .{},
    ticks: zigulee.ChangeTracker(u64) = undefined,
    ticks_seen: u32 = 0,
};

fn ticksValue(s: *State) u64 {
    return @intCast(s.a.get());
}

fn onTicks(s: *State, _: u64) void {
    s.ticks_seen += 1;
}

fn bump(s: *State, by: i32) void {
    s.a.set(s.a.get() + by);
}

fn twice(s: *State) i32 {
    return s.a.get() * 2;
}

fn startBounce(s: *State) void {
    s.x.setAnimated(s.gpa, 1, .{ .duration_ms = 300, .easing = .ease_out_bounce }) catch {};
}

export fn zigulee_mcu_check(by: i32, now_ms: u64) i32 {
    var fba: std.heap.FixedBufferAllocator = .init(&heap);
    var s: State = .{ .gpa = fba.allocator() };
    s.ticks.init(s.gpa, &s, ticksValue, onTicks);
    defer {
        s.ticks.deinit();
        s.timer.deinit();
        s.x.deinit();
        s.b.deinit();
        s.a.deinit();
    }
    s.b.setBinding(s.gpa, &s, twice) catch return -1;
    s.on_tap.setHandler(&s, bump);
    s.timer.start(.single_shot, 10, &s, startBounce);

    s.on_tap.call(.{by});
    zigulee.updateTimersAndAnimations(now_ms);
    zigulee.runChangeHandlers();
    return s.b.get() + @as(i32, @intFromFloat(s.x.get() * 100));
}

const Line = struct {
    pub const Context = void;
    text: zigulee.items.Text = .{},

    var pool: [4]Line = undefined;
    var used: usize = 0;

    pub fn create(_: std.mem.Allocator, _: void, _: usize, data: []const u8) std.mem.Allocator.Error!*Line {
        if (used == pool.len) return error.OutOfMemory;
        const self = &pool[used];
        used += 1;
        self.* = .{};
        self.text.text.set(data);
        return self;
    }

    pub fn update(self: *Line, _: usize, data: []const u8) void {
        self.text.text.set(data);
    }

    pub fn destroy(self: *Line) void {
        self.text.deinit();
    }

    pub fn rootItem(self: *Line) *zigulee.Item {
        return &self.text.item;
    }
};

const Screen = struct {
    window: zigulee.Window = undefined,
    flick: zigulee.items.Flickable = undefined,
    lines: zigulee.core.Repeater([]const u8, Line) = undefined,
    names: zigulee.VecModel([]const u8) = undefined,
    column: zigulee.items.BoxLayout = .vertical(),
    label: zigulee.items.Text = .{},
    button: zigulee.items.Rectangle = .{},
    touch: zigulee.items.TouchArea = .{},
};

var screen: Screen = .{};

/// Lays out a tiny screen, taps it and records the frame: returns the
/// number of draw commands, or -1 on allocation failure.
export fn zigulee_mcu_screen(tap_x: f32, tap_y: f32) i32 {
    var fba: std.heap.FixedBufferAllocator = .init(&heap);
    const gpa = fba.allocator();
    const s = &screen;
    s.* = .{};
    s.window.init(gpa, .{ .width = 240, .height = 135 });
    s.flick.init(gpa);
    s.names = .init(gpa);
    Line.used = 0;
    s.lines.init(gpa, {}) catch return -1;
    defer {
        s.window.deinit();
        s.lines.deinit();
        s.names.deinit();
        s.flick.deinit();
        s.touch.deinit();
        s.button.deinit();
        s.label.deinit();
        s.column.deinit();
    }
    s.window.rootItem().appendChild(&s.column.item);
    s.column.item.appendChildren(&.{ &s.label.item, &s.button.item, &s.flick.item });
    s.flick.content().appendChild(&s.lines.item);
    s.names.push("one") catch return -1;
    s.lines.setModel(s.names.model()) catch return -1;
    s.button.item.appendChild(&s.touch.item);
    s.label.text.set("Hello");
    // A real device would @embedFile its font; the test font keeps this
    // check free of font files.
    const font_bytes = zigulee.core.text.test_font.standard(gpa) catch return -1;
    const font = zigulee.core.Font.init(font_bytes) catch return -1;
    s.window.default_font.set(&font);
    s.button.background.set(.color(.rgb(0x2060ff)));
    s.column.setup(gpa) catch return -1;
    s.column.item.fillParent(gpa) catch return -1;
    s.touch.item.fillParent(gpa) catch return -1;

    s.window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = tap_x, .y = tap_y } } });
    s.button.border_radius.set(8);

    // Render line by line into an 8-line RGB565 band, as a display driver would.
    var renderer: zigulee.software.Renderer(zigulee.software.Rgb565) = .init(gpa);
    defer renderer.deinit();
    var flushed: i32 = 0;
    _ = renderer.renderWindowInBands(&s.window, .full, &band, band.len / 240, &flushed, flushBand) catch return -1;
    return flushed;
}

var band: [240 * 8]zigulee.software.Rgb565 = undefined;

extern fn display_write(x: i32, y: i32, w: u32, h: u32, pixels: [*]const zigulee.software.Rgb565) void;

fn flushBand(count: *i32, c: zigulee.software.Canvas(zigulee.software.Rgb565)) void {
    display_write(c.origin_x, c.origin_y, c.width, c.height, c.pixels.ptr);
    count.* += 1;
}

// Bare metal has no stderr: the firmware supplies logging and panics.
pub const std_options: std.Options = .{ .logFn = discardLog };

fn discardLog(
    comptime _: std.log.Level,
    comptime _: @EnumLiteral(),
    comptime _: []const u8,
    _: anytype,
) void {}

pub const panic = std.debug.FullPanic(hang);

fn hang(_: []const u8, _: ?usize) noreturn {
    while (true) {}
}
