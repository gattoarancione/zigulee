// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Reactive properties: the dependency-tracking core of zigulee.
//!
//! A `Property(T)` holds a value and optionally a *binding*: a function that
//! computes the value from other properties. Dependencies are discovered at
//! runtime: every `get()` performed while a binding is being evaluated
//! registers an edge from the property read to that binding. When a property
//! changes, everything that depends on it is marked dirty (eagerly), and is
//! re-evaluated on the next read (lazily).
//!
//! Pinning rule: once a property or tracker takes part in the dependency graph
//! (it has a binding, was linked two-way, was read inside a binding, or a
//! tracker was evaluated) it must not move in memory, because graph edges
//! point at it. Components are heap-allocated for this reason.
//!
//! The graph is single-threaded: all access must happen on the UI thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const animations = @import("animations.zig");
const Animation = animations.Animation;
const time = @import("time.zig");

/// The dependent currently collecting dependencies, if any.
threadlocal var current: ?*Dependent = null;

/// Called when a binding (directly or indirectly) reads its own property.
/// If the handler returns, the read yields the property's stale value.
pub var binding_loop_handler: *const fn () void = defaultBindingLoopHandler;

/// Built for size (microcontrollers): what only saves work or smooths
/// motion is left out.
const small = @import("builtin").mode == .ReleaseSmall;

/// Whether a binding evaluated again to an equal value spares what reads
/// it. Left out of builds for size: any binding marked stale counts as
/// changed.
const cutoff = !small;

pub fn defaultBindingLoopHandler() void {
    @panic("zigulee: binding loop detected (a property's binding depends on itself)");
}

/// An edge in the dependency graph: `dependent` depends on `source`.
/// Owned (allocated and freed) by its dependent; linked into the source's
/// list of dependents.
const Edge = struct {
    dependent: *Dependent,
    source: ?*PropertyBase,
    prev: ?*Edge = null,
    next: ?*Edge = null,
    next_owned: ?*Edge = null,
};

/// Anything that can depend on properties: bindings, change trackers and
/// property trackers.
const Dependent = struct {
    gpa: Allocator,
    /// Edges registered during the last evaluation.
    edges: ?*Edge = null,
    /// Edges kept for reuse, so steady-state re-evaluation does not allocate.
    free_edges: ?*Edge = null,
    /// What to do when a dependency changes (a tag rather than a function
    /// pointer: it shares a word with the flags below).
    kind: Kind,
    /// Bindings: being evaluated (to detect loops).
    evaluating: bool = false,
    /// Bindings: the owner's cached value is stale.
    dirty: bool = false,
    /// Bindings, when `dirty`: a property it reads was set (else only
    /// bindings it reads may have changed: they are evaluated first, and it
    /// is only if one did).
    changed: bool = false,

    const Kind = enum(u8) { binding, property_tracker, change_tracker };

    /// A dependency changed (`stale`: a binding's value may have, which
    /// is known once it is evaluated again).
    fn notify(self: *Dependent, stale: bool) void {
        switch (self.kind) {
            .binding => Binding.notify(self, stale),
            .property_tracker => PropertyTracker.notify(self, stale),
            .change_tracker => {
                const core: *TrackerCore = @fieldParentPtr("dep", self);
                enqueue(&core.node);
            },
        }
    }

    fn register(self: *Dependent, source: *PropertyBase) void {
        if (source.dependents) |head| if (head.dependent == self) return;
        var it = self.edges;
        while (it) |e| : (it = e.next_owned) if (e.source == source) return;

        const edge = if (self.free_edges) |e| blk: {
            self.free_edges = e.next_owned;
            break :blk e;
        } else self.gpa.create(Edge) catch
            @panic("zigulee: out of memory while registering a property dependency");

        edge.* = .{
            .dependent = self,
            .source = source,
            .next = source.dependents,
            .next_owned = self.edges,
        };
        if (source.dependents) |head| head.prev = edge;
        source.dependents = edge;
        self.edges = edge;
    }

    /// Drops all dependencies, keeping the edges for reuse.
    fn clear(self: *Dependent) void {
        while (self.edges) |e| {
            self.edges = e.next_owned;
            if (e.source) |src| src.unlink(e);
            e.next_owned = self.free_edges;
            self.free_edges = e;
        }
    }

    fn deinit(self: *Dependent) void {
        self.clear();
        while (self.free_edges) |e| {
            self.free_edges = e.next_owned;
            self.gpa.destroy(e);
        }
    }

    /// Calls `f(args)` with this dependent collecting dependencies.
    fn evaluate(self: *Dependent, f: anytype, args: anytype) @TypeOf(@call(.auto, f, args)) {
        self.clear();
        const prev = current;
        current = self;
        defer current = prev;
        return @call(.auto, f, args);
    }
};

/// The type-independent part of a property: two words, since every item
/// has many properties.
pub const PropertyBase = struct {
    dependents: ?*Edge = null,
    /// The binding, if any; or, tagged with 1, the property this one is the
    /// secondary side of in a two-way link (which never has a binding).
    link: usize = 0,

    fn binding(self: *const PropertyBase) ?*Binding {
        if (self.link & 1 != 0) return null;
        return @ptrFromInt(self.link);
    }

    fn setBindingPtr(self: *PropertyBase, b: ?*Binding) void {
        self.link = @intFromPtr(b);
    }

    fn aliasOf(self: *const PropertyBase) ?*PropertyBase {
        if (self.link & 1 == 0) return null;
        return @ptrFromInt(self.link & ~@as(usize, 1));
    }

    fn unlink(self: *PropertyBase, e: *Edge) void {
        if (e.prev) |p| p.next = e.next else self.dependents = e.next;
        if (e.next) |n| n.prev = e.prev;
        e.source = null;
        e.prev = null;
        e.next = null;
    }

    fn track(self: *PropertyBase) void {
        if (current) |d| d.register(self);
    }

    fn markDependentsDirty(self: *PropertyBase) void {
        self.notifyDependents(false);
    }

    fn notifyDependents(self: *PropertyBase, stale: bool) void {
        var it = self.dependents;
        while (it) |e| {
            const next = e.next;
            e.dependent.notify(stale);
            it = next;
        }
    }

    /// Marks the binding to be evaluated again: what reads it may change.
    fn markDirty(self: *PropertyBase) void {
        const b = self.binding() orelse return;
        b.dep.changed = true;
        self.markStale();
    }

    /// Marks the binding's cached value stale (if not yet): what reads it
    /// may have changed.
    fn markStale(self: *PropertyBase) void {
        const b = self.binding() orelse return;
        if (b.dep.dirty) return;
        b.dep.dirty = true;
        self.notifyDependents(true);
    }

    /// The binding was evaluated again to a different value: what was told
    /// it may change now knows it did.
    fn confirmChanged(self: *PropertyBase) void {
        var it = self.dependents;
        while (it) |e| : (it = e.next) {
            const d = e.dependent;
            switch (d.kind) {
                .property_tracker => PropertyTracker.confirm(d),
                .binding => if (d.dirty) {
                    d.changed = true;
                },
                .change_tracker => {},
            }
        }
    }

    /// Brings a stale binding's value up to date.
    fn refresh(self: *PropertyBase) void {
        if (!cutoff) return;
        const b = self.binding() orelse return;
        if (b.dep.dirty) b.vtable.refresh(self);
    }

    /// Detaches all dependents without notifying them.
    fn detachAll(self: *PropertyBase) void {
        while (self.dependents) |e| self.unlink(e);
    }

    fn removeBinding(self: *PropertyBase) void {
        const b = self.binding() orelse return;
        if (b.dep.evaluating) @panic("zigulee: a binding replaced or removed its own property's binding");
        self.setBindingPtr(null);
        b.destroy();
    }
};

const Binding = struct {
    dep: Dependent,
    owner: *PropertyBase,
    vtable: *const VTable,

    const VTable = struct {
        evaluate: *const fn (*Binding, out: *anyopaque) void,
        destroy: *const fn (*Binding) void,
        /// Updates the owner's value (`Property(T).update`; not without
        /// `cutoff`).
        refresh: if (cutoff) *const fn (*PropertyBase) void else void,
    };

    fn notify(d: *Dependent, stale: bool) void {
        const self: *Binding = @fieldParentPtr("dep", d);
        if (!stale or !cutoff) d.changed = true;
        self.owner.markStale();
    }

    /// Whether it must be evaluated: dirty, and a property it reads was set
    /// or a binding it reads changed (those are brought up to date to find
    /// out).
    fn due(b: *Binding) bool {
        if (b.dep.evaluating) {
            binding_loop_handler();
            return false;
        }
        if (!b.dep.dirty) return false;
        if (cutoff and !b.dep.changed) {
            b.dep.evaluating = true;
            var it = b.dep.edges;
            while (it) |e| : (it = e.next_owned) {
                if (b.dep.changed) break;
                if (e.source) |src| src.refresh();
            }
            b.dep.evaluating = false;
            if (!b.dep.changed) {
                b.dep.dirty = false;
                return false;
            }
        }
        b.dep.dirty = false;
        b.dep.changed = false;
        return true;
    }

    fn destroy(self: *Binding) void {
        self.dep.deinit();
        self.vtable.destroy(self);
    }
};

/// The context parameter type of `f`, or `void` if `f` takes no parameters.
fn ContextOf(comptime F: type) type {
    const params = @typeInfo(F).@"fn".params;
    return if (params.len == 0) void else params[0].type.?;
}

fn ReturnOf(comptime F: type) type {
    return @typeInfo(F).@"fn".return_type.?;
}

inline fn callWithContext(comptime f: anytype, ctx: ContextOf(@TypeOf(f))) ReturnOf(@TypeOf(f)) {
    return if (@typeInfo(@TypeOf(f)).@"fn".params.len == 0) f() else f(ctx);
}

/// Value equality used to decide whether a set actually changed a property.
/// Structs, unions and enums may provide `pub fn eql(a, b) bool`; `[]const u8`
/// compares by content; everything else uses `std.meta.eql`.
/// Whether equal values of `T` are the same in every way: no pointers to
/// memory whose contents may change, and not empty (a `void` binding works
/// by its side effects, a layout's solving).
fn comparable(comptime T: type) bool {
    comptime {
        if (!cutoff) return false;
        if (@sizeOf(T) == 0) return false;
        switch (@typeInfo(T)) {
            .pointer, .@"opaque", .@"fn" => return false,
            .optional => |o| return comparable(o.child),
            .array => |a| return comparable(a.child),
            .@"struct" => |s| {
                for (s.fields) |f| if (!comparable(f.type)) return false;
                return true;
            },
            .@"union" => |u| {
                for (u.fields) |f| if (!comparable(f.type)) return false;
                return true;
            },
            else => return true,
        }
    }
}

pub fn valuesEqual(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => if (@hasDecl(T, "eql")) return a.eql(b),
        .pointer => |p| if (p.size == .slice and p.child == u8) return std.mem.eql(u8, a, b),
        else => {},
    }
    return std.meta.eql(a, b);
}

fn hasBlend(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union" => @hasDecl(T, "Blend"),
        else => false,
    };
}

/// Storage a type declares to animate (`T.Blend`), or nothing.
fn Blend(comptime T: type) type {
    return if (hasBlend(T)) T.Blend else struct {};
}

/// An in-flight (or finished) animation between two values.
fn AnimationState(comptime T: type) type {
    return struct {
        from: T,
        to: T,
        start_ms: u64,
        anim: Animation,

        /// Where values that need storage to blend (brushes) are blended.
        blend: Blend(T) = .{},
        /// A number moving with a spring: the speed it started with
        /// (values per second), which carries it on.
        velocity: f32 = 0,

        /// Keeps a spring's speed (not built for size: it starts over from
        /// rest there).
        const is_float = !small and @typeInfo(T) == .float;

        /// The value at `now_ms`. While the animation runs, this makes the
        /// binding being evaluated depend on the UI clock.
        fn sample(self: *@This(), now_ms: u64) T {
            const p = animations.progress(self.anim, self.start_ms, now_ms);
            if (!p.finished) time.track();
            if (comptime hasBlend(T)) return self.blend.interpolate(self.from, self.to, p.t);
            return self.at(p);
        }

        fn at(self: *const @This(), p: animations.Progress) T {
            const v = animations.interpolate(T, self.from, self.to, p.t);
            if (comptime !is_float) return v;
            if (p.finished or self.velocity == 0 or self.anim.easing != .spring) return v;
            const duration_s = @as(f32, @floatFromInt(self.anim.duration_ms)) / 1000;
            return v + @as(T, @floatCast(self.velocity * duration_s * animations.springCarry(self.anim.easing.spring, p.raw)));
        }

        /// How fast a number moves at `now_ms` (values per second).
        fn speed(self: *const @This(), now_ms: u64) f32 {
            if (comptime !is_float) return 0;
            const step = 4;
            if (now_ms < step) return 0;
            const p = animations.progress(self.anim, self.start_ms, now_ms);
            if (p.finished) return 0;
            const before = animations.progress(self.anim, self.start_ms, now_ms - step);
            return @floatCast((self.at(p) - self.at(before)) * (1000.0 / @as(f32, step)));
        }

        /// Starts over from the current value towards `to`; a number moving
        /// towards a spring's target keeps its speed.
        fn retarget(self: *@This(), now_ms: u64, to: T, anim: Animation) void {
            const v = if (is_float and anim.easing == .spring) self.speed(now_ms) else 0;
            var from = self.sample(now_ms);
            if (comptime hasBlend(T)) from = self.blend.keep(from);
            self.from = from;
            self.to = to;
            self.start_ms = now_ms;
            self.anim = anim;
            self.velocity = v;
        }
    };
}

/// A reactive value of type `T`. See the module documentation for the
/// pinning rule.
pub fn Property(comptime T: type) type {
    return struct {
        const Self = @This();

        base: PropertyBase = .{},
        value: T,

        pub fn init(value: T) Self {
            return .{ .value = value };
        }

        pub fn deinit(self: *Self) void {
            self.base.removeBinding();
            self.base.detachAll();
            self.* = undefined;
        }

        fn root(self: *Self) *Self {
            var p = self;
            while (p.base.aliasOf()) |a| p = @alignCast(@fieldParentPtr("base", a));
            return p;
        }

        /// Brings the cached value up to date, evaluating the binding if dirty.
        fn update(r: *Self) void {
            const b = r.base.binding() orelse return;
            if (!b.due()) return;
            // A value of pointers may be the same memory with other
            // contents: always a change.
            const Old = comptime if (comparable(T)) T else void;
            const old: Old = if (comptime comparable(T)) r.value else {};
            {
                b.dep.evaluating = true;
                defer b.dep.evaluating = false;
                b.dep.evaluate(b.vtable.evaluate, .{ b, @as(*anyopaque, @ptrCast(&r.value)) });
            }
            if (comptime comparable(T)) {
                if (!valuesEqual(T, old, r.value)) r.base.confirmChanged();
            } else if (cutoff) r.base.confirmChanged();
        }

        fn refreshBase(base: *PropertyBase) void {
            const r: *Self = @alignCast(@fieldParentPtr("base", base));
            r.update();
        }

        /// Returns the current value, registering a dependency if called from
        /// inside a binding or tracker.
        pub fn get(self: *Self) T {
            const r = self.root();
            r.update();
            r.base.track();
            return r.value;
        }

        /// Returns the current value without registering a dependency.
        /// As `get`, but where the value is: valid until it changes.
        pub fn getPtr(self: *Self) *const T {
            const r = self.root();
            r.update();
            r.base.track();
            return &r.value;
        }

        pub fn getUntracked(self: *Self) T {
            const r = self.root();
            r.update();
            return r.value;
        }

        /// Sets a constant value, removing any binding.
        pub fn set(self: *Self, value: T) void {
            const r = self.root();
            r.base.removeBinding();
            // An equal value is stored too (without notifying): the caller
            // may free the previous one, which can be a different slice.
            const changed = !valuesEqual(T, r.value, value);
            r.value = value;
            if (changed) r.base.markDependentsDirty();
        }

        /// Replaces the value with a binding computed by `f(ctx)`.
        ///
        /// `f` takes zero parameters (pass `{}` as `ctx`) or one context
        /// parameter. `ctx` is coerced to that parameter's type and stored by
        /// value, so it can be a pointer or a small named struct of captures
        /// (anonymous `.{ ... }` literals do not coerce through `anytype`).
        pub fn setBinding(self: *Self, gpa: Allocator, ctx: anytype, comptime f: anytype) Allocator.Error!void {
            const Ctx = ContextOf(@TypeOf(f));
            const Impl = struct {
                binding: Binding,
                ctx: Ctx,

                fn evaluate(b: *Binding, out: *anyopaque) void {
                    const impl: *@This() = @alignCast(@fieldParentPtr("binding", b));
                    const dst: *T = @ptrCast(@alignCast(out));
                    dst.* = callWithContext(f, impl.ctx);
                }
            };
            return self.installBinding(gpa, Impl, .{ .binding = undefined, .ctx = ctx });
        }

        /// Animates from the current value to `value`. The animation starts
        /// at the current UI clock time (see `time.zig`); setting the value
        /// again mid-animation continues smoothly from the in-flight value.
        /// Like `set`, this replaces any binding.
        pub fn setAnimated(self: *Self, gpa: Allocator, value: T, anim: Animation) Allocator.Error!void {
            const r = self.root();
            if (anim.isInstant()) return r.set(value);
            const from = r.getUntracked();
            if (r.base.binding() == null and valuesEqual(T, from, value)) return r.set(value);

            const Impl = struct {
                binding: Binding,
                state: AnimationState(T),

                fn evaluate(b: *Binding, out: *anyopaque) void {
                    const impl: *@This() = @alignCast(@fieldParentPtr("binding", b));
                    const dst: *T = @ptrCast(@alignCast(out));
                    dst.* = impl.state.sample(time.now());
                }
            };
            // Animating already: on from where it is (a spring keeps its
            // speed).
            if (!small) if (r.base.binding()) |b| if (b.vtable == vtableOf(Impl)) {
                const impl: *Impl = @alignCast(@fieldParentPtr("binding", b));
                impl.state.retarget(time.now(), value, anim);
                r.base.markDirty();
                _ = r.getUntracked();
                return;
            };
            try r.installBinding(gpa, Impl, .{
                .binding = undefined,
                .state = .{ .from = from, .to = value, .start_ms = time.now(), .anim = anim },
            });
            // Evaluate now, so the animation registers with the clock (and
            // `hasActiveAnimations()` reports it) before anything reads it.
            _ = r.getUntracked();
        }

        /// Like `setBinding`, but whenever the binding's result changes the
        /// property animates from its current value to the new result. The
        /// initial value is not animated. Bindings are lazy, so an animation
        /// starts when the binding is next read after the change (normally
        /// the next frame), not at the instant the dependency changed.
        pub fn setAnimatedBinding(self: *Self, gpa: Allocator, ctx: anytype, comptime f: anytype, anim: Animation) Allocator.Error!void {
            return self.animatedBinding(gpa, ctx, f, anim, null);
        }

        /// Like `setAnimatedBinding`, but `choose(ctx)` picks the animation
        /// each time the result changes (state transitions with separate
        /// enter and leave animations).
        pub fn setAnimatedBindingChoosing(self: *Self, gpa: Allocator, ctx: anytype, comptime f: anytype, comptime choose: anytype) Allocator.Error!void {
            return self.animatedBinding(gpa, ctx, f, .{}, choose);
        }

        fn animatedBinding(self: *Self, gpa: Allocator, ctx: anytype, comptime f: anytype, anim: Animation, comptime choose: anytype) Allocator.Error!void {
            const Ctx = ContextOf(@TypeOf(f));
            const Impl = struct {
                binding: Binding,
                ctx: Ctx,
                anim: Animation,
                state: ?AnimationState(T) = null,

                fn evaluate(b: *Binding, out: *anyopaque) void {
                    const impl: *@This() = @alignCast(@fieldParentPtr("binding", b));
                    const dst: *T = @ptrCast(@alignCast(out));
                    // Re-runs `f` on every animation frame too; cheap for
                    // typical bindings and keeps the state machine simple.
                    const target = callWithContext(f, impl.ctx);
                    const now = time.now();
                    const st = if (impl.state) |*st| st else {
                        // Instant: the initial value must not keep the clock busy.
                        impl.state = .{ .from = target, .to = target, .start_ms = now, .anim = .{} };
                        dst.* = target;
                        return;
                    };
                    if (!valuesEqual(T, target, st.to))
                        st.retarget(now, target, if (@TypeOf(choose) == @TypeOf(null)) impl.anim else callWithContext(choose, impl.ctx));
                    dst.* = st.sample(now);
                }
            };
            return self.installBinding(gpa, Impl, .{ .binding = undefined, .ctx = ctx, .anim = anim });
        }

        /// The binding functions of `Impl` (one table per type: a binding
        /// can be told by it).
        fn vtableOf(comptime Impl: type) *const Binding.VTable {
            const Destroy = struct {
                fn destroy(b: *Binding) void {
                    const impl: *Impl = @alignCast(@fieldParentPtr("binding", b));
                    b.dep.gpa.destroy(impl);
                }
            };
            return &struct {
                const vtable: Binding.VTable = .{ .evaluate = Impl.evaluate, .destroy = Destroy.destroy, .refresh = if (cutoff) refreshBase else {} };
            }.vtable;
        }

        /// Heap-allocates `payload` (whose `binding` field is filled in here)
        /// and makes it this property's binding.
        fn installBinding(self: *Self, gpa: Allocator, comptime Impl: type, payload: Impl) Allocator.Error!void {
            const r = self.root();
            const impl = try gpa.create(Impl);
            impl.* = payload;
            impl.binding = .{
                .dep = .{ .gpa = gpa, .kind = .binding },
                .owner = &r.base,
                .vtable = vtableOf(Impl),
            };
            r.base.removeBinding();
            r.base.setBindingPtr(&impl.binding);
            r.base.markDirty();
        }

        pub fn hasBinding(self: *Self) bool {
            return self.root().base.binding() != null;
        }

        /// Notifies dependents that the value changed, e.g. after mutating
        /// it in place through `value`.
        pub fn notifyChanged(self: *Self) void {
            self.root().base.markDependentsDirty();
        }

        /// Links `other` to `self` two-way (`self <=> other`): afterwards both
        /// read and write the same storage. `self`'s value is kept; if only
        /// `other` has a binding, that binding moves over to `self`.
        /// Both properties must have the same lifetime.
        pub fn linkTwoWay(self: *Self, other: *Self) void {
            const r = self.root();
            const o = other.root();
            if (r == o) return;

            if (r.base.binding() == null) {
                if (o.base.binding()) |b| {
                    o.base.setBindingPtr(null);
                    b.owner = &r.base;
                    r.base.setBindingPtr(b);
                    b.dep.dirty = false;
                    r.base.markDirty();
                }
            }
            o.base.removeBinding();

            // Move other's dependents over; their value may have changed.
            while (o.base.dependents) |e| {
                const dependent = e.dependent;
                o.base.unlink(e);
                e.source = &r.base;
                e.next = r.base.dependents;
                if (r.base.dependents) |head| head.prev = e;
                r.base.dependents = e;
                dependent.notify(false);
            }
            o.base.link = @intFromPtr(&r.base) | 1;
        }
    };
}

/// Evaluates a function while recording which properties it reads, and
/// reports when any of them changes. Renderers use this to know when an item
/// must be repainted. Must not move after the first `evaluate`.
pub const PropertyTracker = struct {
    dep: Dependent,
    dirty: bool = true,
    /// A binding it reads may have changed: `isDirty` finds out.
    stale: bool = false,
    listener: ?Listener = null,

    const Listener = struct {
        ctx: *anyopaque,
        func: *const fn (*anyopaque) void,
    };

    pub fn init(gpa: Allocator) PropertyTracker {
        return .{ .dep = .{ .gpa = gpa, .kind = .property_tracker } };
    }

    pub fn deinit(self: *PropertyTracker) void {
        self.dep.deinit();
        self.* = undefined;
    }

    fn notify(d: *Dependent, stale: bool) void {
        const self: *PropertyTracker = @fieldParentPtr("dep", d);
        if (self.dirty) return;
        const was_stale = self.stale;
        if (stale and cutoff) self.stale = true else self.dirty = true;
        if (!was_stale) if (self.listener) |l| l.func(l.ctx);
    }

    fn confirm(d: *Dependent) void {
        const self: *PropertyTracker = @fieldParentPtr("dep", d);
        if (self.stale) self.dirty = true;
    }

    /// Calls `listener(ctx)` the first time a dependency changes after an
    /// evaluation. The listener must not modify the property graph.
    pub fn setDirtyListener(self: *PropertyTracker, ctx: anytype, comptime listener: fn (@TypeOf(ctx)) void) void {
        const Ctx = @TypeOf(ctx);
        const W = struct {
            fn call(p: *anyopaque) void {
                listener(@ptrCast(@alignCast(p)));
            }
        };
        comptime std.debug.assert(@typeInfo(Ctx) == .pointer);
        self.listener = .{ .ctx = @ptrCast(@constCast(ctx)), .func = W.call };
    }

    /// Whether what it read changed. Bindings it read that may have are
    /// evaluated again to find out (equal values are no change).
    pub fn isDirty(self: *PropertyTracker) bool {
        if (!cutoff or self.dirty or !self.stale) return self.dirty;
        var it = self.dep.edges;
        while (it) |e| : (it = e.next_owned) {
            if (self.dirty) break;
            if (e.source) |src| src.refresh();
        }
        self.stale = false;
        return self.dirty;
    }

    /// Evaluates `f(ctx)`, replacing the tracked dependencies with the
    /// properties it reads.
    pub fn evaluate(self: *PropertyTracker, ctx: anytype, comptime f: anytype) ReturnOf(@TypeOf(f)) {
        const Ctx = ContextOf(@TypeOf(f));
        const W = struct {
            fn call(c: Ctx) ReturnOf(@TypeOf(f)) {
                return callWithContext(f, c);
            }
        };
        self.dirty = false;
        self.stale = false;
        return self.dep.evaluate(W.call, .{@as(Ctx, ctx)});
    }
};

/// The type-independent part of a change tracker: its dependencies and its
/// place in the queue (found from the dependent when notified).
const TrackerCore = struct {
    dep: Dependent,
    node: PendingNode,
};

/// Node in the queue of change trackers waiting for `runChangeHandlers`.
const PendingNode = struct {
    next: ?*PendingNode = null,
    queued: bool = false,
    runFn: *const fn (*PendingNode) void,
};

threadlocal var pending_head: ?*PendingNode = null;
threadlocal var pending_tail: ?*PendingNode = null;

fn enqueue(n: *PendingNode) void {
    if (n.queued) return;
    n.queued = true;
    n.next = null;
    if (pending_tail) |t| t.next = n else pending_head = n;
    pending_tail = n;
}

fn dequeue(n: *PendingNode) void {
    if (!n.queued) return;
    var prev: ?*PendingNode = null;
    var it = pending_head;
    while (it) |p| : ({
        prev = p;
        it = p.next;
    }) {
        if (p != n) continue;
        if (prev) |pr| pr.next = n.next else pending_head = n.next;
        if (pending_tail == n) pending_tail = prev;
        break;
    }
    n.queued = false;
    n.next = null;
}

/// Upper bound on handlers run by one `runChangeHandlers` call, to stop
/// handlers that keep re-triggering each other.
pub const max_change_handler_runs = 10_000;

/// Runs the handlers of every change tracker whose value changed. Called by
/// the event loop once per iteration; handlers may set properties, which can
/// queue further handlers within the same call.
pub fn runChangeHandlers() void {
    var budget: usize = max_change_handler_runs;
    while (pending_head) |n| {
        if (budget == 0) {
            std.log.scoped(.zigulee).warn("change handlers keep re-triggering each other; deferring the rest", .{});
            return;
        }
        budget -= 1;
        pending_head = n.next;
        if (pending_head == null) pending_tail = null;
        n.next = null;
        n.queued = false;
        n.runFn(n);
    }
}

/// A function run once from the next `runChangeHandlers` after each
/// `schedule`: for work that must wait until a component and its users
/// are set up. Must not move while scheduled.
pub const Deferred = struct {
    node: PendingNode = .{ .runFn = run },
    ctx: *anyopaque = undefined,
    func: *const fn (*anyopaque) void = undefined,

    /// `f(ctx)` is what runs; `ctx` must be a pointer.
    pub fn init(ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) Deferred {
        comptime std.debug.assert(@typeInfo(@TypeOf(ctx)) == .pointer);
        const W = struct {
            fn call(p: *anyopaque) void {
                f(@ptrCast(@alignCast(p)));
            }
        };
        return .{ .ctx = @ptrCast(@constCast(ctx)), .func = W.call };
    }

    pub fn schedule(self: *Deferred) void {
        enqueue(&self.node);
    }

    pub fn cancel(self: *Deferred) void {
        dequeue(&self.node);
    }

    fn run(n: *PendingNode) void {
        const self: *Deferred = @fieldParentPtr("node", n);
        self.func(self.ctx);
    }
};

test "a deferred function runs once, from the next runChangeHandlers" {
    const Count = struct {
        n: u32 = 0,
        fn bump(c: *@This()) void {
            c.n += 1;
        }
    };
    var count: Count = .{};
    var d: Deferred = .init(&count, Count.bump);
    d.schedule();
    d.schedule();
    try std.testing.expectEqual(@as(u32, 0), count.n);
    runChangeHandlers();
    try std.testing.expectEqual(@as(u32, 1), count.n);
    runChangeHandlers();
    try std.testing.expectEqual(@as(u32, 1), count.n);
    d.schedule();
    d.cancel();
    runChangeHandlers();
    try std.testing.expectEqual(@as(u32, 1), count.n);
}

/// Watches a value computed from properties and calls a handler when it
/// changes (the `changed prop => { ... }` construct). Handlers run from
/// `runChangeHandlers`, not synchronously. Must not move after `init`.
pub fn ChangeTracker(comptime T: type) type {
    return struct {
        const Self = @This();

        core: TrackerCore,
        value: T,
        ctx: *anyopaque,
        evalFn: *const fn (*anyopaque) T,
        handlerFn: *const fn (*anyopaque, T) void,

        /// Initializes in place and evaluates `eval(ctx)` once to capture the
        /// initial value; `handler(ctx, new_value)` is not called for it.
        /// `ctx` must be a pointer.
        pub fn init(
            self: *Self,
            gpa: Allocator,
            ctx: anytype,
            comptime eval: fn (@TypeOf(ctx)) T,
            comptime handler: fn (@TypeOf(ctx), T) void,
        ) void {
            const Ctx = @TypeOf(ctx);
            comptime std.debug.assert(@typeInfo(Ctx) == .pointer);
            const W = struct {
                fn evalErased(p: *anyopaque) T {
                    return eval(@ptrCast(@alignCast(p)));
                }
                fn handlerErased(p: *anyopaque, v: T) void {
                    handler(@ptrCast(@alignCast(p)), v);
                }
            };
            self.* = .{
                .core = .{ .dep = .{ .gpa = gpa, .kind = .change_tracker }, .node = .{ .runFn = run } },
                .value = undefined,
                .ctx = @ptrCast(@constCast(ctx)),
                .evalFn = W.evalErased,
                .handlerFn = W.handlerErased,
            };
            self.value = self.core.dep.evaluate(self.evalFn, .{self.ctx});
        }

        pub fn deinit(self: *Self) void {
            dequeue(&self.core.node);
            self.core.dep.deinit();
            self.* = undefined;
        }

        fn run(n: *PendingNode) void {
            const core: *TrackerCore = @fieldParentPtr("node", n);
            const self: *Self = @alignCast(@fieldParentPtr("core", core));
            const new = self.core.dep.evaluate(self.evalFn, .{self.ctx});
            const changed = !valuesEqual(T, self.value, new);
            // Kept even when equal: the previous value may be freed.
            self.value = new;
            if (!changed) return;
            // The handler's reads must not become dependencies of the tracker.
            const prev = current;
            current = null;
            defer current = prev;
            self.handlerFn(self.ctx, new);
        }
    };
}
