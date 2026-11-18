// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Timers (the `Timer { interval: ...; triggered => { ... } }` construct).
//!
//! Timers are driven by the UI clock: the event loop advances it and fires
//! due timers through `updateTimersAndAnimations(now_ms)`, and sleeps until
//! `nextTimerDeadline()` when idle. A running timer must not move in memory.

const std = @import("std");
const time = @import("time.zig");
const Callback = @import("callbacks.zig").Callback;

pub const Mode = enum { single_shot, repeated };

pub const Timer = struct {
    mode: Mode = .single_shot,
    interval_ms: u64 = 0,
    deadline: u64 = 0,
    callback: Callback(fn () void) = .{},
    queue: Queue = .none,
    next: ?*Timer = null,

    const Queue = enum { none, active, due };

    /// Starts (or restarts) the timer: `f(ctx)` is called `interval_ms` from
    /// now, and then every `interval_ms` if `mode` is `.repeated`.
    pub fn start(self: *Timer, mode: Mode, interval_ms: u64, ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) void {
        self.stop();
        self.mode = mode;
        self.interval_ms = interval_ms;
        self.callback.setHandler(ctx, f);
        self.schedule();
    }

    /// Restarts a previously started timer with its current settings.
    pub fn restart(self: *Timer) void {
        if (!self.callback.hasHandler()) return;
        self.stop();
        self.schedule();
    }

    /// Changes the interval, rescheduling the timer if it is running.
    pub fn setInterval(self: *Timer, interval_ms: u64) void {
        self.interval_ms = interval_ms;
        if (self.isRunning()) self.restart();
    }

    pub fn stop(self: *Timer) void {
        switch (self.queue) {
            .none => return,
            .active => remove(&active_head, self),
            .due => remove(&due_head, self),
        }
        self.queue = .none;
        self.next = null;
    }

    pub fn isRunning(self: *const Timer) bool {
        return self.queue != .none;
    }

    pub fn deinit(self: *Timer) void {
        self.stop();
        self.* = undefined;
    }

    fn schedule(self: *Timer) void {
        self.deadline = time.now() +| self.interval_ms;
        insertActive(self);
    }
};

/// Running timers, sorted by deadline (ties keep insertion order).
threadlocal var active_head: ?*Timer = null;
/// Timers being fired by the current `updateTimers` call.
threadlocal var due_head: ?*Timer = null;

fn insertActive(t: *Timer) void {
    var link: *?*Timer = &active_head;
    while (link.*) |cur| : (link = &cur.next) {
        if (cur.deadline > t.deadline) break;
    }
    t.next = link.*;
    link.* = t;
    t.queue = .active;
}

fn remove(head: *?*Timer, t: *Timer) void {
    var link: *?*Timer = head;
    while (link.*) |cur| : (link = &cur.next) {
        if (cur == t) {
            link.* = t.next;
            return;
        }
    }
}

/// Fires every timer whose deadline is at or before the current clock.
/// Each timer fires at most once per call; a repeated timer that fell behind
/// skips missed intervals instead of firing in a burst. Callbacks may start,
/// stop or restart any timer, including their own.
pub fn updateTimers() void {
    const now = time.now();

    // Move the due prefix of the active list to the due list first, so
    // timers (re)started by callbacks wait for the next call.
    var tail: ?*Timer = null;
    while (active_head) |t| {
        if (t.deadline > now) break;
        active_head = t.next;
        t.next = null;
        t.queue = .due;
        if (tail) |tl| tl.next = t else due_head = t;
        tail = t;
    }

    while (due_head) |t| {
        due_head = t.next;
        t.next = null;
        t.queue = .none;
        if (t.mode == .repeated) {
            const next = t.deadline +| t.interval_ms;
            t.deadline = if (next > now) next else now +| t.interval_ms;
            insertActive(t);
        }
        t.callback.call(.{});
    }
}

/// When the next timer is due, or null if no timer is running.
pub fn nextTimerDeadline() ?u64 {
    return if (active_head) |t| t.deadline else null;
}

const testing = std.testing;

const Log = struct {
    fired: usize = 0,
    fn hit(self: *Log) void {
        self.fired += 1;
    }
};

fn advance(by: u64) void {
    time.advanceTo(time.now() + by);
    updateTimers();
}

test "single-shot timer fires once" {
    var log: Log = .{};
    var t: Timer = .{};
    defer t.deinit();
    t.start(.single_shot, 100, &log, Log.hit);
    try testing.expectEqual(time.now() + 100, nextTimerDeadline().?);

    advance(99);
    try testing.expectEqual(@as(usize, 0), log.fired);
    advance(1);
    try testing.expectEqual(@as(usize, 1), log.fired);
    try testing.expect(!t.isRunning());
    advance(1000);
    try testing.expectEqual(@as(usize, 1), log.fired);
    try testing.expectEqual(@as(?u64, null), nextTimerDeadline());
}

test "repeated timer skips missed intervals instead of bursting" {
    var log: Log = .{};
    var t: Timer = .{};
    defer t.deinit();
    t.start(.repeated, 10, &log, Log.hit);
    advance(10);
    advance(10);
    try testing.expectEqual(@as(usize, 2), log.fired);
    advance(55); // five intervals late: fires once
    try testing.expectEqual(@as(usize, 3), log.fired);
    try testing.expectEqual(time.now() + 10, nextTimerDeadline().?);
    t.stop();
    advance(100);
    try testing.expectEqual(@as(usize, 3), log.fired);
}

test "timers fire in deadline order and can stop each other" {
    const Pair = struct {
        order: [4]u8 = undefined,
        len: usize = 0,
        a: Timer = .{},
        b: Timer = .{},
        fn fireA(self: *@This()) void {
            self.order[self.len] = 'a';
            self.len += 1;
        }
        fn fireB(self: *@This()) void {
            self.order[self.len] = 'b';
            self.len += 1;
            self.a.stop(); // a is due in the same update but must not fire
        }
    };
    var p: Pair = .{};
    defer {
        p.a.deinit();
        p.b.deinit();
    }
    p.a.start(.single_shot, 20, &p, Pair.fireA);
    p.b.start(.single_shot, 10, &p, Pair.fireB);
    advance(30);
    try testing.expectEqualStrings("b", p.order[0..p.len]);
}

test "a timer restarted from its own callback waits for the next update" {
    const Self = struct {
        t: Timer = .{},
        fired: usize = 0,
        fn fire(self: *@This()) void {
            self.fired += 1;
            self.t.setInterval(0);
            self.t.restart();
        }
    };
    var s: Self = .{};
    defer s.t.deinit();
    s.t.start(.single_shot, 5, &s, Self.fire);
    advance(5);
    try testing.expectEqual(@as(usize, 1), s.fired);
    try testing.expect(s.t.isRunning());
    advance(0);
    try testing.expectEqual(@as(usize, 2), s.fired);
}
