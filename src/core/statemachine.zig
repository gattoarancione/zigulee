// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! State machines (the `StateMachine { ... }` element), with SCXML's
//! semantics: events processed one at a time to completion (those the
//! machine sends itself, from its own actions, before those from outside),
//! exit actions before a transition's actions before entry actions, delayed
//! transitions armed on entry and cancelled on exit.
//!
//! States nest: a state with states inside is active with one of them (a
//! parallel state with all of them, its regions), and its transitions apply
//! to them all (a child's own transitions first). An event selects, for
//! each active atomic state, the first enabled transition from it outwards;
//! transitions leaving the same states conflict, and the one from inside
//! the other's state (else the first) is kept. Their states are left
//! (innermost first, up to the innermost compound state around both the
//! source and the target), their actions run, the states down to their
//! targets are entered, then the targets' initial states (or their
//! history). Eventless transitions are then taken while their guards hold;
//! entering a final state raises `done` for the state around it (and for a
//! parallel state once all its regions are done).
//!
//! The compiler (or the interpreter) describes a machine with a constant
//! `Definition`, and gives `Hooks` into its component for what the source
//! says: guards, actions, entry and exit actions, delays.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const ChangeTracker = @import("properties.zig").ChangeTracker;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const ItemVTable = item_mod.ItemVTable;
const Timer = @import("timers.zig").Timer;

const log = std.log.scoped(.zigulee_machine);

/// An event's argument.
pub const Arg = union(enum) {
    boolean: bool,
    int: i32,
    float: f32,
    /// Owned by the sender, or by the queue once queued.
    string: []const u8,
};

pub const Definition = struct {
    /// Parents before their children (document order).
    states: []const State,
    events: []const []const u8 = &.{},
    /// The top-level state entered first.
    initial: u16 = 0,
    /// How many `after`s, all states together.
    afters: u16 = 0,
};

pub const History = enum { none, shallow, deep };

pub const State = struct {
    name: []const u8,
    /// Its path from the top (`ready/editing`), for `current`; the name if
    /// empty.
    path: []const u8 = "",
    parent: ?u16 = null,
    /// A compound state (with states inside, one active at a time): the
    /// one entered with it.
    initial: ?u16 = null,
    /// A parallel state: all the states inside it are active with it.
    parallel: bool = false,
    /// A final state: entering it raises `done` for the state around it.
    final: bool = false,
    /// Remembers which of its states (shallow) or atomic descendants
    /// (deep) were active when it was left, to resume them.
    history: History = .none,
    /// In document order: the first enabled one is taken.
    transitions: []const Transition = &.{},
};

pub const Trigger = union(enum) {
    event: u16,
    /// The `after` with this number.
    after: u16,
    /// The state with this number is done (its final state entered, or
    /// all its regions' final states).
    done: u16,
    /// Taken as soon as its guard holds.
    eventless,
};

pub const Transition = struct {
    trigger: Trigger,
    /// None: internal (no state left or entered).
    target: ?u16,
    /// Enters the target through its history.
    to_history: bool = false,
    /// Number of the transition in the whole machine, for the hooks.
    index: u16,
    guarded: bool = false,
};

/// What the source says, as code of the component.
pub const Hooks = struct {
    ctx: *anyopaque,
    guard: *const fn (ctx: *anyopaque, transition: u16, args: []const Arg) bool = noGuard,
    action: *const fn (ctx: *anyopaque, transition: u16, args: []const Arg) void = noAction,
    entered: *const fn (ctx: *anyopaque, state: u16) void = noState,
    exited: *const fn (ctx: *anyopaque, state: u16) void = noState,
    /// An `after`'s delay, in ms, read when its state is entered.
    delay: *const fn (ctx: *anyopaque, after: u16) i64 = noDelay,

    fn noGuard(_: *anyopaque, _: u16, _: []const Arg) bool {
        return true;
    }
    fn noAction(_: *anyopaque, _: u16, _: []const Arg) void {}
    fn noState(_: *anyopaque, _: u16) void {}
    fn noDelay(_: *anyopaque, _: u16) i64 {
        return 0;
    }
};

const max_args = 4;
const queue_len = 16;
/// Eventless transitions taken in a row before giving up (a loop).
const max_eventless = 100;

const Queued = struct {
    trigger: Trigger,
    args: [max_args]Arg = undefined,
    len: u8 = 0,
};

const Queue = struct {
    items: [queue_len]Queued = undefined,
    head: u8 = 0,
    len: u8 = 0,

    fn push(q: *Queue, e: Queued) bool {
        if (q.len == queue_len) return false;
        q.items[(q.head + q.len) % queue_len] = e;
        q.len += 1;
        return true;
    }

    fn pop(q: *Queue) ?Queued {
        if (q.len == 0) return null;
        const e = q.items[q.head];
        q.head = (q.head + 1) % queue_len;
        q.len -= 1;
        return e;
    }
};

/// The machine being stepped (its own actions send to its internal queue).
threadlocal var stepping: ?*StateMachine = null;

pub const StateMachine = struct {
    item: Item = .init(&vtable),
    /// Runs from when its component is made unless false; `start()` and
    /// `stop()` set it.
    running: Property(bool) = .init(true),
    /// The active atomic states' paths (`on/net/online, on/sync/idle`; ""
    /// when stopped).
    current: Property([]const u8) = .init(""),
    /// The first active atomic state, numbered among atomic states (the
    /// initial one before it runs, the last one once stopped): what `state`
    /// reads.
    last: Property(i32) = .init(0),
    /// Counts the changes of the active states (what `active()` follows).
    changes: Property(u32) = .init(0),

    gpa: Allocator = undefined,
    def: *const Definition = &empty,
    hooks: ?Hooks = null,
    afters: []After = &.{},
    /// Each state's number among atomic states (null: it has states).
    leaves: []?u16 = &.{},
    /// The active states.
    config: []bool = &.{},
    on: bool = false,
    /// Per state, the atomic state inside it last active (its number among
    /// atomic states): what a region's `state` reads.
    last_in: []i32 = &.{},
    /// Per state keeping a history: the states it recorded (its children,
    /// or its atomic descendants), and whether it has.
    recorded: []bool = &.{},
    has_recorded: []bool = &.{},
    /// Scratch: states to exit and to enter, transitions selected.
    exit_set: []bool = &.{},
    entry_set: []bool = &.{},
    selected: []Selected = &.{},
    kept: []Selected = &.{},
    finals: []u16 = &.{},
    /// `current` when several states are active (alternating, so a value
    /// set before is still readable while the next is built).
    current_buf: [2]std.ArrayList(u8) = .{ .empty, .empty },
    current_next: u1 = 0,
    internal: Queue = .{},
    external: Queue = .{},
    busy: bool = false,
    /// Eventless transitions gave up (a loop) until the next event.
    stuck: bool = false,
    tracker: ChangeTracker(bool) = undefined,
    tracking: bool = false,

    const empty: Definition = .{ .states = &.{} };

    const Selected = struct { t: Transition, source: u16 };

    const After = struct {
        machine: *StateMachine,
        index: u16,
        timer: Timer = .{},

        fn fire(a: *After) void {
            a.machine.send(.{ .after = a.index }, &.{});
        }
    };

    pub fn init(self: *StateMachine, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
    }

    pub fn deinit(self: *StateMachine) void {
        if (self.tracking) self.tracker.deinit();
        for (self.afters) |*a| a.timer.deinit();
        self.gpa.free(self.afters);
        inline for (.{ "leaves", "config", "last_in", "recorded", "has_recorded", "exit_set", "entry_set", "selected", "kept", "finals" }) |f| self.gpa.free(@field(self, f));
        for (&self.current_buf) |*b| b.deinit(self.gpa);
        inline for (.{ &self.internal, &self.external }) |q| while (q.pop()) |e| freeArgs(self.gpa, e);
        self.running.deinit();
        self.current.deinit();
        self.last.deinit();
        self.changes.deinit();
        self.item.deinit();
    }

    /// Gives it what it runs (once, when its component is made); it starts
    /// with `begin`.
    pub fn setup(self: *StateMachine, def: *const Definition, hooks: Hooks) Allocator.Error!void {
        self.def = def;
        self.hooks = hooks;
        const n = def.states.len;
        self.afters = try self.gpa.alloc(After, def.afters);
        for (self.afters, 0..) |*a, i| a.* = .{ .machine = self, .index = @intCast(i) };
        self.leaves = try self.gpa.alloc(?u16, n);
        var leaves: u16 = 0;
        for (def.states, self.leaves) |st, *l| {
            l.* = if (atomic(st)) leaves else null;
            if (atomic(st)) leaves += 1;
        }
        self.config = try self.gpa.alloc(bool, n);
        @memset(self.config, false);
        self.last_in = try self.gpa.alloc(i32, n);
        @memset(self.last_in, 0);
        self.recorded = try self.gpa.alloc(bool, n * n);
        @memset(self.recorded, false);
        self.has_recorded = try self.gpa.alloc(bool, n);
        @memset(self.has_recorded, false);
        self.exit_set = try self.gpa.alloc(bool, n);
        self.entry_set = try self.gpa.alloc(bool, n);
        self.selected = try self.gpa.alloc(Selected, n);
        self.kept = try self.gpa.alloc(Selected, n);
        self.finals = try self.gpa.alloc(u16, n);
        if (n == 0) return;
        // What `state` and the regions' states read before they ran: the
        // first atomic state each state would enter.
        for (0..n) |st| {
            @memset(self.entry_set, false);
            self.addDescendants(@intCast(st), false);
            for (self.entry_set, 0..) |in, a| if (in and atomic(def.states[a])) {
                self.last_in[st] = self.leaves[a].?;
                break;
            };
        }
        @memset(self.entry_set, false);
        self.addDescendants(def.initial, false);
        var first = true;
        for (self.entry_set, 0..) |in, s| if (in and atomic(def.states[s])) {
            if (first) self.last.set(self.leaves[s].?);
            first = false;
            self.noteLastIn(@intCast(s));
        };
    }

    fn atomic(st: State) bool {
        return st.initial == null and !st.parallel;
    }

    /// Starts it if `running`, and from then on follows `running` (once
    /// its component is made, its properties set).
    pub fn begin(self: *StateMachine) void {
        self.tracker.init(self.gpa, self, runningNow, runningChanged);
        self.tracking = true;
        if (self.tracker.value) self.enterInitial();
    }

    fn runningNow(self: *StateMachine) bool {
        return self.running.get();
    }

    fn runningChanged(self: *StateMachine, on: bool) void {
        if (on) self.enterInitial() else self.leave();
    }

    /// Enters the initial state (`start()` in `.zge`), unless running.
    pub fn start(self: *StateMachine) void {
        self.running.set(true);
        self.enterInitial();
    }

    /// Leaves the active states, their exit actions run (`stop()`).
    pub fn stop(self: *StateMachine) void {
        self.running.set(false);
        self.leave();
    }

    /// Whether state `s` is active (`active(name)`).
    pub fn isActive(self: *StateMachine, s: u16) bool {
        _ = self.changes.get();
        return self.config[s];
    }

    /// The atomic state inside `s` last active (its number among atomic
    /// states): a region's `state`.
    pub fn lastIn(self: *StateMachine, s: u16) i32 {
        _ = self.changes.get();
        return self.last_in[s];
    }

    /// Whether `a` is `s` or around it.
    fn isAncestorOrSelf(self: *const StateMachine, a: u16, s: u16) bool {
        var it: ?u16 = s;
        while (it) |x| : (it = self.def.states[x].parent) if (x == a) return true;
        return false;
    }

    /// Whether `s` is inside `around` (anything is inside the top, null).
    fn inside(self: *const StateMachine, s: u16, around: ?u16) bool {
        const d = around orelse return true;
        return s != d and self.isAncestorOrSelf(d, s);
    }

    /// Sends event `id` with `args` (`machine.name(args)`): processed now,
    /// or queued when sent while it processes another (its own actions'
    /// events first). Ignored while it is not running.
    pub fn sendEvent(self: *StateMachine, id: u16, args: []const Arg) void {
        self.send(.{ .event = id }, args);
    }

    fn send(self: *StateMachine, trigger: Trigger, args: []const Arg) void {
        if (!self.on) return;
        if (self.busy) {
            const internal = stepping == self;
            self.queue(if (internal) &self.internal else &self.external, trigger, args);
            return;
        }
        self.busy = true;
        const outer = stepping;
        stepping = self;
        defer {
            stepping = outer;
            self.busy = false;
        }
        self.stuck = false;
        _ = self.microFor(trigger, args);
        self.settle();
    }

    fn queue(self: *StateMachine, q: *Queue, trigger: Trigger, args: []const Arg) void {
        if (args.len > max_args) return log.err("an event with more than {d} arguments", .{max_args});
        var e: Queued = .{ .trigger = trigger, .len = @intCast(args.len) };
        for (args, 0..) |a, i| e.args[i] = switch (a) {
            .string => |str| .{ .string = self.gpa.dupe(u8, str) catch return log.err("out of memory queuing an event", .{}) },
            else => a,
        };
        if (!q.push(e)) {
            freeArgs(self.gpa, e);
            log.err("a state machine's event queue is full: an event dropped", .{});
        }
    }

    /// Takes eventless transitions while there are, then the internal
    /// events, then the external ones (each followed by eventless ones).
    fn settle(self: *StateMachine) void {
        var rounds: u32 = 0;
        while (self.on) {
            if (!self.stuck and self.microFor(.eventless, &.{})) {
                rounds += 1;
                if (rounds >= max_eventless) {
                    log.err("a state machine took {d} eventless transitions in a row: they wait for the next event", .{max_eventless});
                    self.stuck = true;
                }
                continue;
            }
            const e = self.internal.pop() orelse self.external.pop() orelse break;
            defer freeArgs(self.gpa, e);
            self.stuck = false;
            rounds = 0;
            _ = self.microFor(e.trigger, e.args[0..e.len]);
        }
    }

    /// Selects the transitions `trigger` enables and takes them; false if
    /// none.
    fn microFor(self: *StateMachine, trigger: Trigger, args: []const Arg) bool {
        if (!self.on) return false;
        const h = self.hooks.?;
        var n: usize = 0;
        for (self.def.states, 0..) |st, a| {
            if (!self.config[a] or !atomic(st)) continue;
            var it: ?u16 = @intCast(a);
            find: while (it) |s| : (it = self.def.states[s].parent) {
                for (self.def.states[s].transitions) |t| {
                    if (!std.meta.eql(t.trigger, trigger)) continue;
                    if (t.guarded and !h.guard(h.ctx, t.index, args)) continue;
                    for (self.selected[0..n]) |sel| if (sel.t.index == t.index) break :find;
                    self.selected[n] = .{ .t = t, .source = s };
                    n += 1;
                    break :find;
                }
            }
        }
        if (n == 0) return false;
        // Conflicts: transitions leaving the same states. One from inside
        // the other's state wins, else the first.
        var k: usize = 0;
        for (self.selected[0..n]) |t1| {
            var preempted = false;
            var j: usize = 0;
            while (j < k) {
                const t2 = self.kept[j];
                if (self.conflict(t1, t2)) {
                    if (self.inside(t1.source, t2.source)) {
                        std.mem.copyForwards(Selected, self.kept[j .. k - 1], self.kept[j + 1 .. k]);
                        k -= 1;
                        continue;
                    }
                    preempted = true;
                    break;
                }
                j += 1;
            }
            if (preempted) continue;
            self.kept[k] = t1;
            k += 1;
        }
        self.microstep(self.kept[0..k], args);
        return true;
    }

    /// The innermost compound state around both `sel`'s source and its
    /// target (null: the top); the states inside it are left.
    fn domain(self: *const StateMachine, sel: Selected) ?u16 {
        const target = sel.t.target.?;
        var it = self.def.states[sel.source].parent;
        while (it) |d| : (it = self.def.states[d].parent) {
            if (!self.def.states[d].parallel and d != target and self.isAncestorOrSelf(d, target)) return d;
        }
        return null;
    }

    fn conflict(self: *const StateMachine, a: Selected, b: Selected) bool {
        if (a.t.target == null or b.t.target == null) return false;
        const da = self.domain(a) orelse return true;
        const db = self.domain(b) orelse return true;
        return self.isAncestorOrSelf(da, db) or self.isAncestorOrSelf(db, da);
    }

    fn microstep(self: *StateMachine, list: []const Selected, args: []const Arg) void {
        const h = self.hooks.?;
        const states = self.def.states;
        // Leaving: the active states inside each domain, innermost first,
        // histories recorded first.
        @memset(self.exit_set, false);
        for (list) |sel| if (sel.t.target != null) {
            const d = self.domain(sel);
            for (self.config, 0..) |on, s| if (on and self.inside(@intCast(s), d)) {
                self.exit_set[s] = true;
            };
        };
        for (self.exit_set, 0..) |out, s| if (out and states[s].history != .none) self.record(@intCast(s));
        var s = states.len;
        while (s > 0) {
            s -= 1;
            if (!self.exit_set[s]) continue;
            for (states[s].transitions) |t| if (t.trigger == .after) self.afters[t.trigger.after].timer.stop();
            h.exited(h.ctx, @intCast(s));
            self.config[s] = false;
        }
        for (list) |sel| h.action(h.ctx, sel.t.index, args);
        // Entering: down to each target, then on down; parents first.
        @memset(self.entry_set, false);
        for (list) |sel| if (sel.t.target) |target| {
            self.addDescendants(target, sel.t.to_history);
            self.addAncestors(target, self.domain(sel));
        };
        self.enterSet();
    }

    /// Enters the states of `entry_set` not active yet, parents first, then
    /// raises `done` for the states their final states complete.
    fn enterSet(self: *StateMachine) void {
        const h = self.hooks.?;
        const states = self.def.states;
        var nf: usize = 0;
        for (self.entry_set, 0..) |in, i| {
            if (!in or self.config[i]) continue;
            const st: u16 = @intCast(i);
            self.config[i] = true;
            h.entered(h.ctx, st);
            for (states[i].transitions) |t| if (t.trigger == .after) {
                const a = &self.afters[t.trigger.after];
                a.timer.start(.single_shot, @intCast(@max(h.delay(h.ctx, a.index), 0)), a, After.fire);
            };
            if (states[i].final) {
                self.finals[nf] = st;
                nf += 1;
            }
        }
        for (self.finals[0..nf]) |f| {
            const p = states[f].parent orelse continue;
            self.queue(&self.internal, .{ .done = p }, &.{});
            const g = states[p].parent orelse continue;
            if (states[g].parallel and self.isDone(g)) self.queue(&self.internal, .{ .done = g }, &.{});
        }
        self.refresh();
    }

    /// Whether `s` is done: a compound state in a final state, a parallel
    /// state with all its regions done.
    fn isDone(self: *const StateMachine, s: u16) bool {
        const states = self.def.states;
        for (states, 0..) |c, i| {
            if (c.parent == null or c.parent.? != s) continue;
            if (states[s].parallel) {
                if (!self.isDone(@intCast(i))) return false;
            } else if (c.final and self.config[i]) return true;
        }
        return states[s].parallel;
    }

    fn record(self: *StateMachine, s: u16) void {
        const n = self.def.states.len;
        const slot = self.recorded[s * n .. (s + 1) * n];
        @memset(slot, false);
        const deep = self.def.states[s].history == .deep;
        for (self.config, 0..) |on, i| {
            if (!on) continue;
            const st = self.def.states[i];
            slot[i] = if (deep) atomic(st) and self.inside(@intCast(i), s) else st.parent != null and st.parent.? == s;
        }
        self.has_recorded[s] = true;
    }

    /// Adds `s` to the entry set, and below it: through its history when
    /// asked (and it has one), else its initial state, or all its regions.
    fn addDescendants(self: *StateMachine, s: u16, to_history: bool) void {
        const states = self.def.states;
        if (to_history and self.has_recorded[s]) {
            const n = states.len;
            for (self.recorded[s * n .. (s + 1) * n], 0..) |in, c| if (in) {
                self.addDescendants(@intCast(c), false);
                self.addAncestors(@intCast(c), s);
            };
            self.entry_set[s] = true;
            return;
        }
        self.entry_set[s] = true;
        if (states[s].parallel) {
            for (states, 0..) |c, i| if (c.parent != null and c.parent.? == s and !self.entersInside(@intCast(i)))
                self.addDescendants(@intCast(i), false);
        } else if (states[s].initial) |i| self.addDescendants(i, false);
    }

    /// Adds the states around `s` up to `until` (exclusive), and the other
    /// regions of the parallel ones among them.
    fn addAncestors(self: *StateMachine, s: u16, until: ?u16) void {
        const states = self.def.states;
        var it = states[s].parent;
        while (it) |a| : (it = states[a].parent) {
            if (until != null and a == until.?) break;
            self.entry_set[a] = true;
            if (states[a].parallel) for (states, 0..) |c, i| if (c.parent != null and c.parent.? == a and !self.entersInside(@intCast(i)))
                self.addDescendants(@intCast(i), false);
        }
    }

    /// Whether the entry set has `s` or a state inside it.
    fn entersInside(self: *const StateMachine, s: u16) bool {
        for (self.entry_set, 0..) |in, i| if (in and self.isAncestorOrSelf(s, @intCast(i))) return true;
        return false;
    }

    fn enterInitial(self: *StateMachine) void {
        if (self.on or self.def.states.len == 0 or self.busy) return;
        self.busy = true;
        const outer = stepping;
        stepping = self;
        defer {
            stepping = outer;
            self.busy = false;
        }
        self.on = true;
        self.stuck = false;
        @memset(self.entry_set, false);
        self.addDescendants(self.def.initial, false);
        self.enterSet();
        self.settle();
    }

    fn leave(self: *StateMachine) void {
        if (!self.on) return;
        const h = self.hooks.?;
        const states = self.def.states;
        for (self.config, 0..) |on, s| if (on and states[s].history != .none) self.record(@intCast(s));
        var s = states.len;
        while (s > 0) {
            s -= 1;
            if (!self.config[s]) continue;
            for (states[s].transitions) |t| if (t.trigger == .after) self.afters[t.trigger.after].timer.stop();
            h.exited(h.ctx, @intCast(s));
            self.config[s] = false;
        }
        self.on = false;
        inline for (.{ &self.internal, &self.external }) |q| while (q.pop()) |e| freeArgs(self.gpa, e);
        self.refresh();
    }

    fn noteLastIn(self: *StateMachine, atom: u16) void {
        const leaf = self.leaves[atom].?;
        var it: ?u16 = atom;
        while (it) |a| : (it = self.def.states[a].parent) self.last_in[a] = leaf;
    }

    /// What follows the active states: `state`, the regions' states,
    /// `current`, and what `active()` reads.
    fn refresh(self: *StateMachine) void {
        const states = self.def.states;
        var count: usize = 0;
        var only: u16 = 0;
        for (self.config, 0..) |on, s| if (on and atomic(states[s])) {
            if (count == 0) {
                self.last.set(self.leaves[s].?);
                only = @intCast(s);
            }
            count += 1;
            self.noteLastIn(@intCast(s));
        };
        if (count <= 1) {
            const st = states[only];
            self.current.set(if (count == 0) "" else if (st.path.len > 0) st.path else st.name);
        } else {
            const buf = &self.current_buf[self.current_next];
            self.current_next +%= 1;
            buf.clearRetainingCapacity();
            for (self.config, 0..) |on, s| if (on and atomic(states[s])) {
                if (buf.items.len > 0) buf.appendSlice(self.gpa, ", ") catch {};
                buf.appendSlice(self.gpa, if (states[s].path.len > 0) states[s].path else states[s].name) catch {};
            };
            self.current.set(buf.items);
        }
        self.changes.set(self.changes.getUntracked() +% 1);
    }

    fn freeArgs(gpa: Allocator, e: Queued) void {
        for (e.args[0..e.len]) |a| if (a == .string) gpa.free(a.string);
    }

    const vtable: ItemVTable = .{ .name = "StateMachine" };
};

// ---- Tests ----

const testing = std.testing;
const time = @import("time.zig");
const timers = @import("timers.zig");

/// A fetch: idle -start-> loading -done(ok)-> ready or failed, 50 ms
/// without an answer -> failed; `log` records what ran.
const Fetch = struct {
    machine: StateMachine = undefined,
    log: std.ArrayList(u8) = .empty,
    timeout_ms: i64 = 50,
    /// Sent from the entry action of `ready`.
    chain: bool = false,

    const idle = 0;
    const loading = 1;
    const ready = 2;
    const failed = 3;
    const ev_start = 0;
    const ev_done = 1;
    const ev_ping = 2;

    const def: Definition = .{
        .states = &.{
            .{ .name = "idle", .transitions = &.{.{ .trigger = .{ .event = ev_start }, .target = loading, .index = 0 }} },
            .{ .name = "loading", .transitions = &.{
                .{ .trigger = .{ .event = ev_done }, .target = ready, .index = 1, .guarded = true },
                .{ .trigger = .{ .event = ev_done }, .target = failed, .index = 2 },
                .{ .trigger = .{ .after = 0 }, .target = failed, .index = 3 },
            } },
            .{ .name = "ready", .transitions = &.{
                .{ .trigger = .{ .event = ev_ping }, .target = null, .index = 4 },
                .{ .trigger = .{ .event = ev_start }, .target = loading, .index = 5 },
            } },
            .{ .name = "failed", .transitions = &.{.{ .trigger = .{ .event = ev_start }, .target = loading, .index = 6 }} },
        },
        .events = &.{ "start", "done", "ping" },
        .afters = 1,
    };

    fn init(f: *Fetch) !void {
        f.* = .{};
        f.machine.init(testing.allocator);
        try f.machine.setup(&def, .{ .ctx = f, .guard = guard, .action = action, .entered = entered, .exited = exited, .delay = delay });
    }

    fn deinit(f: *Fetch) void {
        f.machine.deinit();
        f.log.deinit(testing.allocator);
    }

    fn of(ctx: *anyopaque) *Fetch {
        return @ptrCast(@alignCast(ctx));
    }

    fn note(f: *Fetch, comptime fmt: []const u8, args: anytype) void {
        f.log.print(testing.allocator, fmt, args) catch {};
    }

    fn guard(ctx: *anyopaque, t: u16, args: []const Arg) bool {
        _ = ctx;
        return t == 1 and args[0].boolean;
    }

    fn action(ctx: *anyopaque, t: u16, args: []const Arg) void {
        const f = of(ctx);
        f.note("t{d} ", .{t});
        // An action sending to its own machine: queued, after this step.
        if (t == 4 and args.len == 1) {
            f.note("[{s}] ", .{args[0].string});
            f.machine.sendEvent(ev_start, &.{});
            f.note("sent ", .{});
        }
    }

    fn entered(ctx: *anyopaque, s: u16) void {
        const f = of(ctx);
        f.note("+{s} ", .{def.states[s].name});
        if (s == ready and f.chain) {
            f.chain = false;
            f.machine.sendEvent(ev_ping, &.{.{ .string = "from entry" }});
        }
    }

    fn exited(ctx: *anyopaque, s: u16) void {
        of(ctx).note("-{s} ", .{def.states[s].name});
    }

    fn delay(ctx: *anyopaque, _: u16) i64 {
        return of(ctx).timeout_ms;
    }
};

test "a state machine: entered, guarded transitions, exit before actions before entry" {
    var f: Fetch = undefined;
    try f.init();
    defer f.deinit();
    // Not running before `begin`: events ignored.
    f.machine.sendEvent(Fetch.ev_start, &.{});
    try testing.expect(!f.machine.on);
    f.machine.begin();
    try testing.expectEqualStrings("idle", f.machine.current.get());
    f.machine.sendEvent(Fetch.ev_start, &.{});
    try testing.expect(f.machine.isActive(Fetch.loading));
    // The guard fails: the next transition for `done`.
    f.machine.sendEvent(Fetch.ev_done, &.{.{ .boolean = false }});
    try testing.expectEqualStrings("failed", f.machine.current.get());
    f.machine.sendEvent(Fetch.ev_start, &.{});
    f.machine.sendEvent(Fetch.ev_done, &.{.{ .boolean = true }});
    try testing.expectEqualStrings("ready", f.machine.current.get());
    // No transition for it here: nothing happens.
    f.machine.sendEvent(Fetch.ev_done, &.{.{ .boolean = true }});
    try testing.expectEqualStrings("+idle -idle t0 +loading -loading t2 +failed -failed t6 +loading -loading t1 +ready ", f.log.items);
}

test "a state machine: its own events queued after the step, internal ones before external ones" {
    var f: Fetch = undefined;
    try f.init();
    defer f.deinit();
    f.machine.begin();
    f.machine.sendEvent(Fetch.ev_start, &.{});
    f.chain = true;
    f.log.clearRetainingCapacity();
    // Entering `ready` sends `ping` (internal: handled before returning);
    // its action, internal, sends `start`, queued after it.
    f.machine.sendEvent(Fetch.ev_done, &.{.{ .boolean = true }});
    try testing.expectEqualStrings("-loading t1 +ready t4 [from entry] sent -ready t5 +loading ", f.log.items);
    try testing.expectEqualStrings("loading", f.machine.current.get());
}

test "a state machine: after, armed on entry, cancelled on exit; stopped and started" {
    const t0 = time.now();
    var f: Fetch = undefined;
    try f.init();
    defer f.deinit();
    f.machine.begin();
    f.machine.sendEvent(Fetch.ev_start, &.{});
    time.advanceTo(t0 + 30);
    timers.updateTimers();
    try testing.expectEqualStrings("loading", f.machine.current.get());
    time.advanceTo(t0 + 60);
    timers.updateTimers();
    try testing.expectEqualStrings("failed", f.machine.current.get());
    // Left before it was due: cancelled.
    f.machine.sendEvent(Fetch.ev_start, &.{});
    f.machine.sendEvent(Fetch.ev_done, &.{.{ .boolean = true }});
    time.advanceTo(t0 + 200);
    timers.updateTimers();
    try testing.expectEqualStrings("ready", f.machine.current.get());

    f.log.clearRetainingCapacity();
    f.machine.stop();
    try testing.expect(!f.machine.on);
    try testing.expectEqual(@as(i32, Fetch.ready), f.machine.last.get());
    try testing.expectEqualStrings("", f.machine.current.get());
    f.machine.sendEvent(Fetch.ev_start, &.{});
    f.machine.start();
    try testing.expectEqualStrings("-ready +idle ", f.log.items);
}

/// A player: off, or on (playing, or in its menu: a list or a detail),
/// switched off by `power` from anywhere inside `on`, or 1 s after `on`
/// was entered; `on` resumes through its history.
const Player = struct {
    machine: StateMachine = undefined,
    log: std.ArrayList(u8) = .empty,

    const off = 0;
    const on = 1;
    const playing = 2;
    const menu = 3;
    const list = 4;
    const detail = 5;
    const ev_power = 0;
    const ev_pause = 1;
    const ev_back = 2;
    const ev_open = 3;

    fn def(comptime history: History) Definition {
        return .{
            .states = &.{
                .{ .name = "off", .transitions = &.{.{ .trigger = .{ .event = ev_power }, .target = on, .to_history = true, .index = 0 }} },
                .{ .name = "on", .initial = playing, .history = history, .transitions = &.{
                    .{ .trigger = .{ .event = ev_power }, .target = off, .index = 1 },
                    .{ .trigger = .{ .after = 0 }, .target = off, .index = 2 },
                } },
                .{ .name = "playing", .path = "on/playing", .parent = on, .transitions = &.{.{ .trigger = .{ .event = ev_pause }, .target = menu, .index = 3 }} },
                .{ .name = "menu", .path = "on/menu", .parent = on, .initial = list, .transitions = &.{.{ .trigger = .{ .event = ev_back }, .target = playing, .index = 4 }} },
                .{ .name = "list", .path = "on/menu/list", .parent = menu, .transitions = &.{.{ .trigger = .{ .event = ev_open }, .target = detail, .index = 5 }} },
                // Its own `back` before the menu's.
                .{ .name = "detail", .path = "on/menu/detail", .parent = menu, .transitions = &.{.{ .trigger = .{ .event = ev_back }, .target = list, .index = 6 }} },
            },
            .afters = 1,
        };
    }

    fn init(p: *Player, d: *const Definition) !void {
        p.* = .{};
        p.machine.init(testing.allocator);
        try p.machine.setup(d, .{ .ctx = p, .entered = entered, .exited = exited, .delay = delay });
    }

    fn deinit(p: *Player) void {
        p.machine.deinit();
        p.log.deinit(testing.allocator);
    }

    fn entered(ctx: *anyopaque, s: u16) void {
        const p: *Player = @ptrCast(@alignCast(ctx));
        p.log.print(testing.allocator, "+{s} ", .{p.machine.def.states[s].name}) catch {};
    }

    fn exited(ctx: *anyopaque, s: u16) void {
        const p: *Player = @ptrCast(@alignCast(ctx));
        p.log.print(testing.allocator, "-{s} ", .{p.machine.def.states[s].name}) catch {};
    }

    fn delay(_: *anyopaque, _: u16) i64 {
        return 1000;
    }

    fn send(p: *Player, ev: u16) []const u8 {
        p.log.clearRetainingCapacity();
        p.machine.sendEvent(ev, &.{});
        return p.log.items;
    }
};

test "a state machine with states inside states: entered down to an atomic one, the parent's transitions, exits up to the common ancestor" {
    const d = Player.def(.none);
    var p: Player = undefined;
    try p.init(&d);
    defer p.deinit();
    // The initial `off` is atomic; its leaf number (0) is `last`.
    try testing.expectEqual(@as(i32, 0), p.machine.last.get());
    p.machine.begin();
    // On: down through the initial states.
    try testing.expectEqualStrings("-off +on +playing ", p.send(Player.ev_power));
    try testing.expectEqualStrings("on/playing", p.machine.current.get());
    try testing.expect(p.machine.isActive(Player.on) and p.machine.isActive(Player.playing) and !p.machine.isActive(Player.menu));
    // Into a sibling: `on` stays.
    try testing.expectEqualStrings("-playing +menu +list ", p.send(Player.ev_pause));
    try testing.expectEqualStrings("-list +detail ", p.send(Player.ev_open));
    try testing.expectEqualStrings("on/menu/detail", p.machine.current.get());
    // `detail`'s own `back` first; then, in `list`, the menu's.
    try testing.expectEqualStrings("-detail +list ", p.send(Player.ev_back));
    try testing.expectEqualStrings("-list -menu +playing ", p.send(Player.ev_back));
    // `power` from inside `on`: all of it left, innermost first.
    _ = p.send(Player.ev_pause);
    try testing.expectEqualStrings("-list -menu -on +off ", p.send(Player.ev_power));
    try testing.expect(!p.machine.isActive(Player.on));
    // `last` numbers atomic states: off 0, playing 1, list 2, detail 3.
    _ = p.send(Player.ev_power);
    try testing.expectEqual(@as(i32, 1), p.machine.last.get());
}

test "a state machine: history, shallow and deep; an after of a parent kept while its children change" {
    const t0 = time.now();
    // Shallow: back to the menu, at its initial list.
    {
        const d = Player.def(.shallow);
        var p: Player = undefined;
        try p.init(&d);
        defer p.deinit();
        p.machine.begin();
        _ = p.send(Player.ev_power);
        _ = p.send(Player.ev_pause);
        _ = p.send(Player.ev_open);
        _ = p.send(Player.ev_power);
        try testing.expectEqualStrings("-off +on +menu +list ", p.send(Player.ev_power));
    }
    // Deep: back to the detail.
    {
        const d = Player.def(.deep);
        var p: Player = undefined;
        try p.init(&d);
        defer p.deinit();
        p.machine.begin();
        _ = p.send(Player.ev_power);
        _ = p.send(Player.ev_pause);
        _ = p.send(Player.ev_open);
        _ = p.send(Player.ev_power);
        try testing.expectEqualStrings("-off +on +menu +detail ", p.send(Player.ev_power));
        try testing.expectEqualStrings("on/menu/detail", p.machine.current.get());

        // `on`'s 1 s runs from when it was entered, whatever its children do.
        time.advanceTo(t0 + 600);
        timers.updateTimers();
        _ = p.send(Player.ev_back);
        _ = p.send(Player.ev_back);
        time.advanceTo(t0 + 900);
        timers.updateTimers();
        try testing.expectEqualStrings("on/playing", p.machine.current.get());
        p.log.clearRetainingCapacity();
        time.advanceTo(t0 + 1100);
        timers.updateTimers();
        try testing.expectEqualStrings("-playing -on +off ", p.log.items);
    }
}

/// Booting until `ready`, then working: a network region (offline, then
/// online, final) and a sync region (idle, syncing, synced, final), side
/// by side; done once both are, then finished.
const Boot = struct {
    machine: StateMachine = undefined,
    log: std.ArrayList(u8) = .empty,
    ready: bool = false,

    const boot = 0;
    const work = 1;
    const net = 2;
    const offline = 3;
    const online = 4;
    const sync = 5;
    const idle = 6;
    const syncing = 7;
    const synced = 8;
    const finished = 9;
    const ev_connect = 0;
    const ev_finish = 1;
    const ev_boom = 2;
    const ev_poke = 3;

    const def: Definition = .{
        .states = &.{
            .{ .name = "boot", .transitions = &.{.{ .trigger = .eventless, .target = work, .index = 0, .guarded = true }} },
            .{ .name = "work", .parallel = true, .transitions = &.{.{ .trigger = .{ .done = work }, .target = finished, .index = 1 }} },
            .{ .name = "net", .path = "work/net", .parent = work, .initial = offline, .transitions = &.{.{ .trigger = .{ .done = net }, .target = null, .index = 2 }} },
            .{ .name = "offline", .path = "work/net/offline", .parent = net, .transitions = &.{
                .{ .trigger = .{ .event = ev_connect }, .target = online, .index = 3 },
                .{ .trigger = .{ .event = ev_boom }, .target = online, .index = 4 },
            } },
            .{ .name = "online", .path = "work/net/online", .parent = net, .final = true },
            .{ .name = "sync", .path = "work/sync", .parent = work, .initial = idle },
            .{
                .name = "idle",
                .path = "work/sync/idle",
                .parent = sync,
                .transitions = &.{
                    .{ .trigger = .{ .event = ev_connect }, .target = syncing, .index = 5 },
                    // Leaves everything: conflicts with `offline`'s, which comes first.
                    .{ .trigger = .{ .event = ev_boom }, .target = boot, .index = 6 },
                },
            },
            .{ .name = "syncing", .path = "work/sync/syncing", .parent = sync, .transitions = &.{.{ .trigger = .{ .event = ev_finish }, .target = synced, .index = 7 }} },
            .{ .name = "synced", .path = "work/sync/synced", .parent = sync, .final = true },
            .{ .name = "finished", .final = true },
        },
    };

    fn init(b: *Boot) !void {
        b.* = .{};
        b.machine.init(testing.allocator);
        try b.machine.setup(&def, .{ .ctx = b, .guard = guard, .action = action, .entered = entered, .exited = exited });
    }

    fn deinit(b: *Boot) void {
        b.machine.deinit();
        b.log.deinit(testing.allocator);
    }

    fn of(ctx: *anyopaque) *Boot {
        return @ptrCast(@alignCast(ctx));
    }

    fn guard(ctx: *anyopaque, _: u16, _: []const Arg) bool {
        return of(ctx).ready;
    }

    fn action(ctx: *anyopaque, t: u16, _: []const Arg) void {
        of(ctx).log.print(testing.allocator, "t{d} ", .{t}) catch {};
    }

    fn entered(ctx: *anyopaque, s: u16) void {
        of(ctx).log.print(testing.allocator, "+{s} ", .{def.states[s].name}) catch {};
    }

    fn exited(ctx: *anyopaque, s: u16) void {
        of(ctx).log.print(testing.allocator, "-{s} ", .{def.states[s].name}) catch {};
    }

    fn send(b: *Boot, ev: u16) []const u8 {
        b.log.clearRetainingCapacity();
        b.machine.sendEvent(ev, &.{});
        return b.log.items;
    }
};

test "a state machine: eventless transitions, parallel regions entered together, an event taken in each" {
    var b: Boot = undefined;
    try b.init();
    defer b.deinit();
    // The regions' first atomic states before it runs: offline, idle.
    try testing.expectEqual(@as(i32, 0), b.machine.last.get());
    try testing.expectEqual(@as(i32, 1), b.machine.lastIn(Boot.net));
    try testing.expectEqual(@as(i32, 3), b.machine.lastIn(Boot.sync));
    b.machine.begin();
    // Its guard false: it stays; checked again after the next event.
    try testing.expectEqualStrings("boot", b.machine.current.get());
    b.ready = true;
    try testing.expectEqualStrings("-boot t0 +work +net +offline +sync +idle ", b.send(Boot.ev_poke));
    try testing.expectEqualStrings("work/net/offline, work/sync/idle", b.machine.current.get());
    try testing.expect(b.machine.isActive(Boot.work) and b.machine.isActive(Boot.offline) and b.machine.isActive(Boot.idle));
    // One event, a transition in each region.
    try testing.expectEqualStrings("-idle -offline t3 t5 +online +syncing t2 ", b.send(Boot.ev_connect));
    try testing.expectEqual(@as(i32, 2), b.machine.lastIn(Boot.net));
    try testing.expectEqual(@as(i32, 4), b.machine.lastIn(Boot.sync));
    // The sync region done too: the parallel state is, and it finishes.
    try testing.expectEqualStrings("-syncing t7 +synced -synced -sync -online -net -work t1 +finished ", b.send(Boot.ev_finish));
    try testing.expectEqualStrings("finished", b.machine.current.get());
}

test "a state machine: conflicting transitions in parallel regions, the first kept" {
    var b: Boot = undefined;
    try b.init();
    defer b.deinit();
    b.ready = true;
    b.machine.begin();
    try testing.expectEqualStrings("work/net/offline, work/sync/idle", b.machine.current.get());
    // `idle`'s would leave all of `work`, `offline`'s only inside `net`:
    // they conflict, and `offline`'s comes first.
    try testing.expectEqualStrings("-offline t4 +online t2 ", b.send(Boot.ev_boom));
    try testing.expectEqualStrings("work/net/online, work/sync/idle", b.machine.current.get());
}
