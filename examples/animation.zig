// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Headless animation demo, equivalent to:
//!
//!     export component Slider {
//!         var <bool> right: false;
//!         var <length> x: right ? 40px : 0px;
//!         animate x { duration: 600ms; easing: ease-out-bounce; }
//!         Timer { interval: 800ms; running: true; triggered => { right = !right; } }
//!     }
//!
//! A simulated 30 fps event loop drives the clock and draws `x` as a bar.

const std = @import("std");
const zigulee = @import("zigulee");

const Slider = struct {
    gpa: std.mem.Allocator,
    right: zigulee.Property(bool) = .init(false),
    x: zigulee.Property(f32) = .init(0),
    timer: zigulee.Timer = .{},

    pub fn create(gpa: std.mem.Allocator) !*Slider {
        const self = try gpa.create(Slider);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa };
        try self.x.setAnimatedBinding(gpa, self, targetX, .{ .duration_ms = 600, .easing = .ease_out_bounce });
        self.timer.start(.repeated, 800, self, toggle);
        return self;
    }

    pub fn destroy(self: *Slider) void {
        self.timer.deinit();
        self.x.deinit();
        self.right.deinit();
        self.gpa.destroy(self);
    }

    fn targetX(self: *Slider) f32 {
        return if (self.right.get()) 40 else 0;
    }

    fn toggle(self: *Slider) void {
        self.right.set(!self.right.getUntracked());
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();

    const slider = try Slider.create(debug_allocator.allocator());
    defer slider.destroy();

    var now: u64 = 0;
    while (now <= 2000) : (now += 33) {
        zigulee.updateTimersAndAnimations(now);
        zigulee.runChangeHandlers();
        // "Render": a real backend would only redraw while animations run.
        const x: usize = @intFromFloat(@max(0, slider.x.get()));
        var bar: [64]u8 = @splat(' ');
        bar[@min(x, bar.len - 1)] = '#';
        std.debug.print("{d:>5} ms |{s}| {s}\n", .{
            now,
            bar[0..44],
            if (zigulee.hasActiveAnimations()) "animating" else "idle",
        });
    }
}
