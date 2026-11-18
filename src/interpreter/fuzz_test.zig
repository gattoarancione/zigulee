// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Fuzz target of the interpreter: generated programs, well-typed most of
//! the time, so they compile and run (created, drawn, clicked, animated).
//! (See core/fuzz.zig.)

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const zigulee = @import("zigulee");
const core = zigulee.core;
const interpreter = @import("interpreter.zig");
const fuzz = core.fuzz;
const Target = fuzz.Target;
const Input = fuzz.Input;

pub const targets = [_]Target{
    .{ .name = "interpret", .run = interpret, .corpus = &.{ "", "\x01\x01\x01\x01\x01\x01", "\x02\x05\x03\x01\x04\x00\x06\x02" } },
};

test "fuzz targets on their corpus" {
    inline for (targets) |t| try fuzz.runCorpus(t);
}

const Gen = struct {
    gpa: Allocator,
    s: *Input,
    out: std.ArrayList(u8) = .empty,
    depth: u8 = 0,

    fn w(g: *Gen, text: []const u8) !void {
        try g.out.appendSlice(g.gpa, text);
    }

    fn pick(g: *Gen, comptime n: u8) u8 {
        return g.s.valueRangeAtMost(u8, 0, n - 1);
    }

    /// Small expressions stay small: deeper ones become literals.
    fn leaf(g: *Gen) bool {
        return g.depth > 3 or g.s.boolWeighted(2, 1);
    }

    fn int(g: *Gen) anyerror!void {
        if (g.leaf()) return g.w(([_][]const u8{ "0", "1", "3", "i0", "-2", "i0" })[g.pick(6)]);
        g.depth += 1;
        defer g.depth -= 1;
        switch (g.pick(6)) {
            0 => {
                try g.int();
                try g.w(" + ");
                try g.int();
            },
            1 => {
                try g.w("(");
                try g.int();
                try g.w(" * ");
                try g.int();
                try g.w(")");
            },
            2 => {
                try g.w("(");
                try g.boolean();
                try g.w(" ? ");
                try g.int();
                try g.w(" : ");
                try g.int();
                try g.w(")");
            },
            3 => {
                try g.w("max(");
                try g.int();
                try g.w(", ");
                try g.int();
                try g.w(")");
            },
            4 => {
                try g.w("mod(");
                try g.int();
                try g.w(", 3)");
            },
            else => {
                try g.w("round(");
                try g.int();
                try g.w(" / 2)");
            },
        }
    }

    fn boolean(g: *Gen) anyerror!void {
        if (g.leaf()) return g.w(([_][]const u8{ "true", "false", "b0", "!b0" })[g.pick(4)]);
        g.depth += 1;
        defer g.depth -= 1;
        switch (g.pick(4)) {
            0 => {
                try g.int();
                try g.w(" > ");
                try g.int();
            },
            1 => {
                try g.boolean();
                try g.w(" && ");
                try g.boolean();
            },
            2 => {
                try g.string();
                try g.w(" == \"a\"");
            },
            else => {
                try g.w("!(");
                try g.boolean();
                try g.w(")");
            },
        }
    }

    fn string(g: *Gen) anyerror!void {
        if (g.leaf()) return g.w(([_][]const u8{ "\"a\"", "\"\"", "s0", "\"é😀\"" })[g.pick(4)]);
        g.depth += 1;
        defer g.depth -= 1;
        switch (g.pick(4)) {
            0 => {
                try g.w("\"n=\\{");
                try g.int();
                try g.w("}\"");
            },
            3 => {
                try g.w("@tr(\"{n} item {}\" | \"{n} items {}\" % ");
                try g.int();
                try g.w(", ");
                try g.string();
                try g.w(")");
            },
            1 => {
                try g.string();
                try g.w(" + ");
                try g.string();
            },
            else => {
                try g.w("(");
                try g.boolean();
                try g.w(" ? ");
                try g.string();
                try g.w(" : ");
                try g.string();
                try g.w(")");
            },
        }
    }

    fn length(g: *Gen) anyerror!void {
        if (g.leaf()) return g.w(([_][]const u8{ "10px", "0px", "l0", "parent.width / 2", "33%" })[g.pick(5)]);
        g.depth += 1;
        defer g.depth -= 1;
        switch (g.pick(3)) {
            0 => {
                try g.length();
                try g.w(" + ");
                try g.length();
            },
            1 => {
                try g.length();
                try g.w(" * ");
                try g.int();
            },
            else => {
                try g.w("max(0px, ");
                try g.length();
                try g.w(")");
            },
        }
    }

    fn color(g: *Gen) !void {
        if (g.s.value(bool)) return g.w(([_][]const u8{ "#ff0000", "#00ff0080", "blue", "transparent" })[g.pick(4)]);
        try g.w("(");
        try g.boolean();
        try g.w(" ? #112233 : #445566)");
    }

    fn statements(g: *Gen) anyerror!void {
        const n = g.pick(3);
        for (0..n) |_| switch (g.pick(5)) {
            0 => {
                try g.w(" i0 += ");
                try g.int();
                try g.w(";");
            },
            1 => try g.w(" b0 = !b0;"),
            2 => {
                try g.w(" s0 = ");
                try g.string();
                try g.w(";");
            },
            3 => {
                try g.w(" l0 = ");
                try g.length();
                try g.w(";");
            },
            else => if (g.depth < 3) {
                g.depth += 1;
                defer g.depth -= 1;
                try g.w(" if ");
                try g.boolean();
                try g.w(" {");
                try g.statements();
                try g.w(" } else {");
                try g.statements();
                try g.w(" }");
            },
        };
    }

    fn element(g: *Gen) anyerror!void {
        g.depth += 1;
        defer g.depth -= 1;
        const kind = if (g.depth > 3) 0 else g.pick(7);
        switch (kind) {
            0 => {
                try g.w("Text { text: ");
                try g.string();
                try g.w("; color: ");
                try g.color();
                try g.w("; }");
            },
            1 => {
                try g.w("Rectangle { background: ");
                try g.color();
                try g.w("; width: ");
                try g.length();
                try g.w("; height: ");
                try g.length();
                try g.w("; ");
                if (g.s.value(bool)) try g.w("animate background, width { duration: 100ms; } ");
                if (g.s.value(bool)) {
                    try g.w("states [ on when ");
                    try g.boolean();
                    try g.w(" : { background: ");
                    try g.color();
                    try g.w("; } ] ");
                }
                try g.children();
                try g.w(" }");
            },
            2 => {
                try g.w("TouchArea { clicked => {");
                try g.statements();
                try g.w(" } }");
            },
            3, 4 => {
                try g.w(if (kind == 3) "VerticalLayout { spacing: " else "HorizontalLayout { padding: ");
                try g.length();
                try g.w("; ");
                try g.children();
                try g.w(" }");
            },
            5 => {
                try g.w("for v[k] in max(0, min(");
                try g.int();
                try g.w(", 4)) : Rectangle { height: 5px; background: k == v ? red : blue; ");
                try g.children();
                try g.w(" }");
            },
            else => {
                try g.w("if ");
                try g.boolean();
                try g.w(" : Text { text: ");
                try g.string();
                try g.w("; }");
            },
        }
    }

    fn children(g: *Gen) anyerror!void {
        const n = g.pick(3);
        for (0..n) |_| {
            try g.w(" ");
            try g.element();
        }
    }

    fn program(g: *Gen) !void {
        try g.w("export component F inherits Window {\n    width: 200px;\n    height: 150px;\n");
        try g.w("    var in-out <int> i0: ");
        try g.int();
        try g.w(";\n    var in-out <bool> b0: ");
        try g.boolean();
        try g.w(";\n    var in-out <string> s0: ");
        try g.string();
        try g.w(";\n    var in-out <length> l0: ");
        try g.length();
        try g.w(";\n    callback go();\n    go => {");
        try g.statements();
        try g.w(" }\n    changed i0 => { b0 = !b0; }\n    ");
        try g.children();
        try g.w("\n}\n");
    }
};

/// Generated programs fail to compile cleanly, or run.
pub fn interpret(gpa: Allocator, s: *Input) !void {
    var g: Gen = .{ .gpa = gpa, .s = s };
    defer g.out.deinit(gpa);
    try g.program();
    const prog = switch (try interpreter.Program.load(gpa, "fuzz.zge", g.out.items, .{})) {
        .program => |p| p,
        .errors => |e| {
            gpa.free(e);
            return; // a generated type error: not interesting
        },
    };
    defer prog.destroy();
    // Generated bindings can depend on themselves: that must work too
    // (as in the preview, which warns).
    core.setBindingLoopHandler(struct {
        fn ignore() void {}
    }.ignore);
    defer core.setBindingLoopHandler(null);
    const inst = try prog.create(prog.mainComponent().?);
    defer inst.destroy();
    const w = inst.window().?;
    var dl: core.rendering.DisplayList = .init(gpa, .{ .width = 200, .height = 150 });
    defer dl.deinit();
    var now = core.now();
    for (0..4) |_| {
        const x: f32 = @floatFromInt(s.valueRangeAtMost(u8, 0, 199));
        const y: f32 = @floatFromInt(s.valueRangeAtMost(u8, 0, 149));
        w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
        w.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
        _ = inst.invoke("go", &.{});
        now += 60;
        zigulee.updateTimersAndAnimations(now);
        zigulee.runChangeHandlers();
        _ = try w.render(dl.renderer(), .full);
    }
}
