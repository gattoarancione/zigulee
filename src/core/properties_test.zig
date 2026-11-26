// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const props = @import("properties.zig");
const Property = props.Property;
const PropertyTracker = props.PropertyTracker;
const ChangeTracker = props.ChangeTracker;

const gpa = testing.allocator;

test "constant property get/set" {
    var p: Property(i32) = .init(1);
    defer p.deinit();
    try testing.expectEqual(@as(i32, 1), p.get());
    p.set(42);
    try testing.expectEqual(@as(i32, 42), p.get());
}

test "setting an equal string keeps the new slice, without notifying" {
    // Found by fuzzing: the interpreter frees the previous slice.
    var p: Property([]const u8) = .init("abc");
    defer p.deinit();
    var dep: Property(usize) = .init(0);
    defer dep.deinit();
    var evaluations: usize = 0;
    const Ctx = struct { p: *Property([]const u8), n: *usize };
    try dep.setBinding(gpa, Ctx{ .p = &p, .n = &evaluations }, struct {
        fn f(c: Ctx) usize {
            c.n.* += 1;
            return c.p.get().len;
        }
    }.f);
    _ = dep.get();
    const other = try gpa.dupe(u8, "abc");
    defer gpa.free(other);
    p.set(other);
    try testing.expectEqual(other.ptr, p.get().ptr);
    _ = dep.get();
    try testing.expectEqual(@as(usize, 1), evaluations);
}

const Pair = struct {
    a: Property(i32) = .init(0),
    b: Property(i32) = .init(0),
    sum: Property(i32) = .init(0),
    evals: usize = 0,

    fn sumOf(self: *Pair) i32 {
        self.evals += 1;
        return self.a.get() + self.b.get();
    }

    fn deinit(self: *Pair) void {
        self.sum.deinit();
        self.a.deinit();
        self.b.deinit();
    }
};

test "binding tracks dependencies and evaluates lazily" {
    var s: Pair = .{};
    defer s.deinit();
    s.a.set(1);
    s.b.set(2);
    try s.sum.setBinding(gpa, &s, Pair.sumOf);

    try testing.expectEqual(@as(usize, 0), s.evals);
    try testing.expectEqual(@as(i32, 3), s.sum.get());
    try testing.expectEqual(@as(i32, 3), s.sum.get());
    try testing.expectEqual(@as(usize, 1), s.evals);

    s.a.set(10);
    try testing.expectEqual(@as(usize, 1), s.evals); // not evaluated until read
    try testing.expectEqual(@as(i32, 12), s.sum.get());
    try testing.expectEqual(@as(usize, 2), s.evals);

    s.b.set(2); // unchanged value: no invalidation
    try testing.expectEqual(@as(i32, 12), s.sum.get());
    try testing.expectEqual(@as(usize, 2), s.evals);
}

test "set removes the binding" {
    var s: Pair = .{};
    defer s.deinit();
    try s.sum.setBinding(gpa, &s, Pair.sumOf);
    try testing.expect(s.sum.hasBinding());
    s.sum.set(99);
    try testing.expect(!s.sum.hasBinding());
    s.a.set(5);
    try testing.expectEqual(@as(i32, 99), s.sum.get());
}

test "binding with captured struct context and zero-arg binding" {
    var a: Property(i32) = .init(3);
    defer a.deinit();
    var b: Property(i32) = .init(4);
    defer b.deinit();
    var product: Property(i32) = .init(0);
    defer product.deinit();
    var constant: Property(i32) = .init(0);
    defer constant.deinit();

    const Captures = struct { a: *Property(i32), b: *Property(i32) };
    try product.setBinding(gpa, Captures{ .a = &a, .b = &b }, struct {
        fn f(c: Captures) i32 {
            return c.a.get() * c.b.get();
        }
    }.f);
    try constant.setBinding(gpa, {}, struct {
        fn f() i32 {
            return 7;
        }
    }.f);

    try testing.expectEqual(@as(i32, 12), product.get());
    b.set(5);
    try testing.expectEqual(@as(i32, 15), product.get());
    try testing.expectEqual(@as(i32, 7), constant.get());
}

const Chain = struct {
    src: Property(i32) = .init(1),
    left: Property(i32) = .init(0),
    right: Property(i32) = .init(0),
    top: Property(i32) = .init(0),
    top_evals: usize = 0,

    fn deinit(self: *Chain) void {
        self.top.deinit();
        self.left.deinit();
        self.right.deinit();
        self.src.deinit();
    }
};

test "diamond dependencies evaluate each binding once" {
    var c: Chain = .{};
    defer c.deinit();
    try c.left.setBinding(gpa, &c, struct {
        fn f(s: *Chain) i32 {
            return s.src.get() + 1;
        }
    }.f);
    try c.right.setBinding(gpa, &c, struct {
        fn f(s: *Chain) i32 {
            return s.src.get() * 2;
        }
    }.f);
    try c.top.setBinding(gpa, &c, struct {
        fn f(s: *Chain) i32 {
            s.top_evals += 1;
            return s.left.get() + s.right.get();
        }
    }.f);

    try testing.expectEqual(@as(i32, 4), c.top.get());
    c.src.set(5);
    try testing.expectEqual(@as(i32, 16), c.top.get());
    try testing.expectEqual(@as(usize, 2), c.top_evals);
}

const Cond = struct {
    flag: Property(bool) = .init(true),
    x: Property(i32) = .init(1),
    y: Property(i32) = .init(2),
    out: Property(i32) = .init(0),
    evals: usize = 0,

    fn eval(self: *Cond) i32 {
        self.evals += 1;
        return if (self.flag.get()) self.x.get() else self.y.get();
    }

    fn deinit(self: *Cond) void {
        self.out.deinit();
        self.flag.deinit();
        self.x.deinit();
        self.y.deinit();
    }
};

test "dynamic dependencies are re-collected on each evaluation" {
    var c: Cond = .{};
    defer c.deinit();
    try c.out.setBinding(gpa, &c, Cond.eval);
    try testing.expectEqual(@as(i32, 1), c.out.get());

    c.y.set(20); // not a dependency yet
    try testing.expectEqual(@as(i32, 1), c.out.get());
    try testing.expectEqual(@as(usize, 1), c.evals);

    c.flag.set(false);
    try testing.expectEqual(@as(i32, 20), c.out.get());
    c.x.set(100); // no longer a dependency
    try testing.expectEqual(@as(i32, 20), c.out.get());
    try testing.expectEqual(@as(usize, 2), c.evals);
}

var loops_detected: usize = 0;
fn countLoop() void {
    loops_detected += 1;
}

test "binding loops are reported" {
    const Loop = struct {
        a: Property(i32) = .init(1),
        b: Property(i32) = .init(2),
    };
    var l: Loop = .{};
    defer {
        l.a.deinit();
        l.b.deinit();
    }
    const saved = props.binding_loop_handler;
    props.binding_loop_handler = countLoop;
    defer props.binding_loop_handler = saved;
    loops_detected = 0;

    try l.a.setBinding(gpa, &l, struct {
        fn f(s: *Loop) i32 {
            return s.b.get() + 1;
        }
    }.f);
    try l.b.setBinding(gpa, &l, struct {
        fn f(s: *Loop) i32 {
            return s.a.get() + 1;
        }
    }.f);

    _ = l.a.get();
    try testing.expectEqual(@as(usize, 1), loops_detected);
}

test "string properties compare by content" {
    var p: Property([]const u8) = .init("hello");
    defer p.deinit();
    var len: Property(usize) = .init(0);
    defer len.deinit();
    var evals: usize = 0;
    const Ctx = struct { p: *Property([]const u8), evals: *usize };
    try len.setBinding(gpa, Ctx{ .p = &p, .evals = &evals }, struct {
        fn f(c: Ctx) usize {
            c.evals.* += 1;
            return c.p.get().len;
        }
    }.f);
    try testing.expectEqual(@as(usize, 5), len.get());
    var buf = "hello".*;
    p.set(&buf); // different pointer, same content
    try testing.expectEqual(@as(usize, 5), len.get());
    try testing.expectEqual(@as(usize, 1), evals);
}

test "two-way binding shares storage" {
    var a: Property(i32) = .init(1);
    defer a.deinit();
    var b: Property(i32) = .init(2);
    defer b.deinit();
    var doubled: Property(i32) = .init(0);
    defer doubled.deinit();
    try doubled.setBinding(gpa, &b, struct {
        fn f(p: *Property(i32)) i32 {
            return p.get() * 2;
        }
    }.f);
    try testing.expectEqual(@as(i32, 4), doubled.get());

    a.linkTwoWay(&b);
    try testing.expectEqual(@as(i32, 1), b.get());
    try testing.expectEqual(@as(i32, 2), doubled.get());

    b.set(7);
    try testing.expectEqual(@as(i32, 7), a.get());
    try testing.expectEqual(@as(i32, 14), doubled.get());

    a.set(8);
    try testing.expectEqual(@as(i32, 8), b.get());
    try testing.expectEqual(@as(i32, 16), doubled.get());
}

test "two-way link adopts the other side's binding" {
    var src: Property(i32) = .init(3);
    defer src.deinit();
    var a: Property(i32) = .init(0);
    defer a.deinit();
    var b: Property(i32) = .init(0);
    defer b.deinit();
    try b.setBinding(gpa, &src, struct {
        fn f(p: *Property(i32)) i32 {
            return p.get() + 100;
        }
    }.f);
    a.linkTwoWay(&b);
    try testing.expectEqual(@as(i32, 103), a.get());
    src.set(4);
    try testing.expectEqual(@as(i32, 104), a.get());
    try testing.expectEqual(@as(i32, 104), b.get());
}

test "property tracker reports dirtiness once per evaluation" {
    var p: Property(i32) = .init(1);
    defer p.deinit();
    var tracker: PropertyTracker = .init(gpa);
    defer tracker.deinit();

    var notified: usize = 0;
    tracker.setDirtyListener(&notified, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);

    try testing.expect(tracker.isDirty());
    const v = tracker.evaluate(&p, struct {
        fn f(prop: *Property(i32)) i32 {
            return prop.get();
        }
    }.f);
    try testing.expectEqual(@as(i32, 1), v);
    try testing.expect(!tracker.isDirty());

    p.set(2);
    p.set(3);
    try testing.expect(tracker.isDirty());
    try testing.expectEqual(@as(usize, 1), notified);
}

/// `source` read through two bindings (`half`, then `twice`), counting
/// evaluations; a tracker reads `twice`.
const Cutoff = struct {
    source: Property(i32) = .init(4),
    half: Property(i32) = .init(0),
    twice: Property(i32) = .init(0),
    evaluations: usize = 0,
    tracker: PropertyTracker = undefined,

    fn init(c: *Cutoff) !void {
        c.* = .{ .tracker = .init(gpa) };
        try c.half.setBinding(gpa, c, struct {
            fn f(s: *Cutoff) i32 {
                return @divTrunc(s.source.get(), 2);
            }
        }.f);
        try c.twice.setBinding(gpa, c, struct {
            fn f(s: *Cutoff) i32 {
                s.evaluations += 1;
                return s.half.get() * 2;
            }
        }.f);
        _ = c.tracker.evaluate(c, struct {
            fn f(s: *Cutoff) i32 {
                return s.twice.get();
            }
        }.f);
    }

    fn deinit(c: *Cutoff) void {
        c.tracker.deinit();
        c.twice.deinit();
        c.half.deinit();
        c.source.deinit();
    }
};

test "a binding evaluated again to an equal value changes nothing that reads it" {
    var c: Cutoff = undefined;
    try c.init();
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.evaluations);
    // 4 / 2 and 5 / 2 are both 2: `twice` is not evaluated again, and the
    // tracker finds nothing changed.
    c.source.set(5);
    try testing.expect(!c.tracker.isDirty());
    try testing.expectEqual(@as(i32, 4), c.twice.get());
    try testing.expectEqual(@as(usize, 1), c.evaluations);
    // 6 / 2 is 3: both are.
    c.source.set(6);
    try testing.expect(c.tracker.isDirty());
    try testing.expectEqual(@as(i32, 6), c.twice.get());
    try testing.expectEqual(@as(usize, 2), c.evaluations);
}

test "an equal value read elsewhere first still tells a tracker whether it changed" {
    var c: Cutoff = undefined;
    try c.init();
    defer c.deinit();
    // Evaluated by another reader before the tracker asks.
    c.source.set(8);
    try testing.expectEqual(@as(i32, 8), c.twice.get());
    try testing.expect(c.tracker.isDirty());
    _ = c.tracker.evaluate(&c, struct {
        fn f(s: *Cutoff) i32 {
            return s.twice.get();
        }
    }.f);
    c.source.set(9);
    try testing.expectEqual(@as(i32, 8), c.twice.get());
    try testing.expect(!c.tracker.isDirty());
}

test "strings and empty values always count as changed" {
    var source: Property(i32) = .init(1);
    defer source.deinit();
    var text: Property([]const u8) = .init("");
    defer text.deinit();
    var solved: Property(void) = .init({});
    defer solved.deinit();
    // A buffer formatted again in place: the same slice, other contents.
    const Ctx = struct { source: *Property(i32), buf: *[8]u8 };
    var buf: [8]u8 = undefined;
    try text.setBinding(gpa, Ctx{ .source = &source, .buf = &buf }, struct {
        fn f(c: Ctx) []const u8 {
            return std.fmt.bufPrint(c.buf, "{d}", .{c.source.get()}) catch "";
        }
    }.f);
    try solved.setBinding(gpa, &source, struct {
        fn f(s: *Property(i32)) void {
            _ = s.get();
        }
    }.f);
    var trackers: [2]PropertyTracker = .{ .init(gpa), .init(gpa) };
    defer for (&trackers) |*t| t.deinit();
    _ = trackers[0].evaluate(&text, struct {
        fn f(t: *Property([]const u8)) usize {
            return t.get().len;
        }
    }.f);
    _ = trackers[1].evaluate(&solved, struct {
        fn f(t: *Property(void)) void {
            t.get();
        }
    }.f);
    source.set(2);
    try testing.expect(trackers[0].isDirty());
    try testing.expect(trackers[1].isDirty());
}

const Watched = struct {
    count: Property(i32) = .init(0),
    tracker: ChangeTracker(i32) = undefined,
    seen: [8]i32 = undefined,
    seen_len: usize = 0,

    fn eval(self: *Watched) i32 {
        return self.count.get();
    }
    fn onChange(self: *Watched, v: i32) void {
        self.seen[self.seen_len] = v;
        self.seen_len += 1;
    }
};

test "change tracker runs handlers only for real changes" {
    var w: Watched = .{};
    w.tracker.init(gpa, &w, Watched.eval, Watched.onChange);
    defer {
        w.tracker.deinit();
        w.count.deinit();
    }

    props.runChangeHandlers();
    try testing.expectEqual(@as(usize, 0), w.seen_len);

    w.count.set(1);
    w.count.set(2); // coalesced: handler sees the latest value only
    props.runChangeHandlers();
    w.count.set(5);
    w.count.set(2); // changed and changed back: no handler call
    props.runChangeHandlers();

    try testing.expectEqualSlices(i32, &.{2}, w.seen[0..w.seen_len]);
}

test "deinit of a queued change tracker removes it from the queue" {
    var w: Watched = .{};
    w.tracker.init(gpa, &w, Watched.eval, Watched.onChange);
    w.count.set(3);
    w.tracker.deinit();
    w.count.deinit();
    props.runChangeHandlers();
    try testing.expectEqual(@as(usize, 0), w.seen_len);
}

test "destroying a dependency detaches it from its dependents" {
    var a: Property(i32) = .init(1);
    var out: Property(i32) = .init(0);
    defer out.deinit();
    try out.setBinding(gpa, &a, struct {
        fn f(p: *Property(i32)) i32 {
            return p.get();
        }
    }.f);
    try testing.expectEqual(@as(i32, 1), out.get());
    a.deinit();
    out.set(0); // destroys the binding, whose edge was detached
}

test "steady-state re-evaluation does not allocate" {
    var failing = std.testing.FailingAllocator.init(gpa, .{});
    const alloc = failing.allocator();
    var s: Pair = .{};
    defer s.deinit();
    try s.sum.setBinding(alloc, &s, Pair.sumOf);
    _ = s.sum.get();
    const allocations = failing.allocations;
    for (0..100) |i| {
        s.a.set(@intCast(i));
        _ = s.sum.get();
    }
    try testing.expectEqual(allocations, failing.allocations);
}
