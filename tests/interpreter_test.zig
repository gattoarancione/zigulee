// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The interpreter against the compiler: every window component of the
//! test `.zge` files (and the gallery) runs both compiled and interpreted;
//! after the same input, both must show the same pixels.

const std = @import("std");
const testing = std.testing;
const zigulee = @import("zigulee");
const core = zigulee.core;
const interp = @import("zigulee-interpreter");
const build_options = @import("build_options");

const gpa = testing.allocator;

const Files = struct {
    dir: []const u8,

    fn read(ctx: ?*anyopaque, arena: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
        const self: *Files = @ptrCast(@alignCast(ctx.?));
        const full = try std.fs.path.join(arena, &.{ self.dir, path });
        return std.Io.Dir.cwd().readFileAlloc(testing.io, full, arena, .limited(16 << 20));
    }
};

const Frame = struct {
    width: u32,
    height: u32,
    pixels: []core.Rgba8,

    fn render(window: *core.Window) !Frame {
        const size = window.size();
        const w: u32 = @intFromFloat(@ceil(size.width));
        const h: u32 = @intFromFloat(@ceil(size.height));
        const pixels = try gpa.alloc(core.Rgba8, @as(usize, w) * h);
        @memset(pixels, .transparent);
        var r: zigulee.software.Renderer(core.Rgba8) = .init(gpa);
        defer r.deinit();
        _ = try r.renderWindow(window, .init(pixels, w, h), .full);
        return .{ .width = w, .height = h, .pixels = pixels };
    }

    fn deinit(f: Frame) void {
        gpa.free(f.pixels);
    }

    fn differences(a: Frame, b: Frame) usize {
        if (a.width != b.width or a.height != b.height) return a.pixels.len;
        var n: usize = 0;
        for (a.pixels, b.pixels) |x, y| {
            if (!std.meta.eql(x, y)) n += 1;
        }
        return n;
    }
};

/// Simulated input, applied to both versions.
const Step = union(enum) {
    click: [2]f32,
    press: [2]f32,
    release: [2]f32,
    move: [2]f32,
    key: []const u8,
    wheel: [3]f32,
    wait_ms: u64,
};

fn apply(window: *core.Window, step: Step) void {
    switch (step) {
        .click => |p| {
            window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = p[0], .y = p[1] } } });
            window.dispatchPointer(.{ .released = .{ .position = .{ .x = p[0], .y = p[1] } } });
        },
        .press => |p| window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = p[0], .y = p[1] } } }),
        .release => |p| window.dispatchPointer(.{ .released = .{ .position = .{ .x = p[0], .y = p[1] } } }),
        .move => |p| window.dispatchPointer(.{ .moved = .{ .position = .{ .x = p[0], .y = p[1] } } }),
        .key => |text| window.dispatchKey(.pressed, .{ .text = text }),
        .wheel => |p| window.dispatchPointer(.{ .wheel = .{ .position = .{ .x = p[0], .y = p[1] }, .delta = .{ .y = p[2] } } }),
        .wait_ms => {},
    }
}

/// A walk over the window: clicks on a grid, typing, Tab, a drag and the
/// wheel, with time passing so animations settle.
fn script(size: core.Size, out: *std.ArrayList(Step)) !void {
    const n = 6;
    for (0..n) |i| for (0..n) |j| {
        const x = size.width * (@as(f32, @floatFromInt(j)) + 0.5) / n;
        const y = size.height * (@as(f32, @floatFromInt(i)) + 0.5) / n;
        try out.append(gpa, .{ .click = .{ x, y } });
        try out.append(gpa, .{ .wait_ms = 400 });
        if ((i * n + j) % 7 == 3) {
            for ([_][]const u8{ "a", "é", core.input.Key.backspace, "z", core.input.Key.@"return", core.input.Key.tab, " " }) |k| try out.append(gpa, .{ .key = k });
            try out.append(gpa, .{ .wait_ms = 400 });
        }
    };
    try out.append(gpa, .{ .press = .{ size.width * 0.5, size.height * 0.7 } });
    try out.append(gpa, .{ .move = .{ size.width * 0.6, size.height * 0.4 } });
    try out.append(gpa, .{ .move = .{ size.width * 0.8, size.height * 0.2 } });
    try out.append(gpa, .{ .release = .{ size.width * 0.8, size.height * 0.2 } });
    try out.append(gpa, .{ .wait_ms = 1000 });
    try out.append(gpa, .{ .wheel = .{ size.width * 0.5, size.height * 0.5, -60 } });
    try out.append(gpa, .{ .wait_ms = 1000 });
}

fn compare(comptime ui: type, comptime file: []const u8, font: *const zigulee.Font) !void {
    const path = build_options.root ++ "/" ++ file;
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(16 << 20));
    defer gpa.free(source);
    var files: Files = .{ .dir = std.fs.path.dirname(path).? };
    const prog = switch (try interp.Program.load(gpa, path, source, .{ .loader = .{ .ctx = &files, .readFn = Files.read } })) {
        .program => |p| p,
        .errors => |e| {
            defer gpa.free(e);
            std.debug.print("{s}\n", .{e});
            return error.TestUnexpectedResult;
        },
    };
    defer prog.destroy();

    inline for (@typeInfo(ui).@"struct".decls) |d| {
        const T = @field(ui, d.name);
        if (@TypeOf(T) == type and @typeInfo(T) == .@"struct" and @hasDecl(T, "window") and @hasDecl(T, "create")) {
            try compareComponent(T, d.name, prog, font);
        }
    }
}

var compared: usize = 0;

fn compareComponent(comptime T: type, name: []const u8, prog: *interp.Program, font: *const zigulee.Font) !void {
    compared += 1;
    const compiled = try T.create(gpa);
    defer compiled.destroy();
    const comp = prog.component(name) orelse {
        std.debug.print("interpreter: no component {s}\n", .{name});
        return error.TestUnexpectedResult;
    };
    const interpreted = try prog.create(comp);
    defer interpreted.destroy();
    const cw = compiled.window();
    const iw = interpreted.window().?;
    cw.default_font.set(font);
    iw.default_font.set(font);
    for ([_]*core.Window{ cw, iw }) |w| try w.registerFont("Inter", 400, font);

    var steps: std.ArrayList(Step) = .empty;
    defer steps.deinit(gpa);
    try script(cw.size(), &steps);
    var now = core.now();
    for (steps.items, 0..) |step, i| {
        apply(cw, step);
        apply(iw, step);
        if (step == .wait_ms) {
            now += step.wait_ms;
            zigulee.updateTimersAndAnimations(now);
        }
        zigulee.runChangeHandlers();
        // Compare after each wait (and at the start).
        if (step != .wait_ms and i != 0) continue;
        const a = try Frame.render(cw);
        defer a.deinit();
        const b = try Frame.render(iw);
        defer b.deinit();
        const diff = a.differences(b);
        if (diff != 0) {
            std.debug.print("{s}: {d} pixels differ after step {d} ({any})\n", .{ name, diff, i, step });
            return error.TestUnexpectedResult;
        }
    }
}

fn loadFont() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, build_options.root ++ "/examples/fonts/inter/Inter-Regular.ttf", gpa, .limited(16 << 20));
}

test "interpreted programs match the compiled ones" {
    const bytes = try loadFont();
    defer gpa.free(bytes);
    const font: zigulee.Font = try .init(bytes);
    try compare(@import("ui_features"), "tests/ui/features.zge", &font);
    try compare(@import("ui_dynamic"), "tests/ui/dynamic.zge", &font);
    try compare(@import("ui_language"), "tests/ui/language.zge", &font);
    try compare(@import("ui_imports"), "tests/ui/imports.zge", &font);
    try compare(@import("ui_widgets"), "tests/ui/widgets.zge", &font);
    try compare(@import("gallery_ui"), "examples/gallery.zge", &font);
    try compare(@import("ui_containers"), "tests/ui/containers.zge", &font);
    try compare(@import("ui_popups"), "tests/ui/popups.zge", &font);
    try compare(@import("ui_table"), "tests/ui/table.zge", &font);
    try compare(@import("todo_ui"), "examples/todo.zge", &font);
    try compare(@import("ui_i18n"), "tests/ui/i18n.zge", &font);
    try compare(@import("patrisio_ui"), "examples/patrisio.zge", &font);
    // Not examples/video.zge: its videos decode on threads, so which frame
    // shows after a wait depends on the machine (the interpreted and
    // compiled copies differ on slow ones, as on CI).
    try compare(@import("ui_loader"), "tests/ui/loader.zge", &font);
    try compare(@import("ui_connections"), "tests/ui/connections.zge", &font);
    try compare(@import("ui_timeline"), "tests/ui/timeline.zge", &font);
    try compare(@import("ui_dnd"), "tests/ui/dnd.zge", &font);
    try compare(@import("ui_gestures"), "tests/ui/gestures.zge", &font);
    try compare(@import("ui_widgets2"), "tests/ui/widgets2.zge", &font);
    try compare(@import("ui_pages"), "tests/ui/pages.zge", &font);
    try compare(@import("ui_split"), "tests/ui/split.zge", &font);
    try compare(@import("ui_tree"), "tests/ui/tree.zge", &font);
    try compare(@import("ui_selection"), "tests/ui/selection.zge", &font);
    try compare(@import("ui_inherit_window"), "tests/ui/inherit_window.zge", &font);
    try compare(@import("ui_submenus"), "tests/ui/submenus.zge", &font);
    try compare(@import("ui_drawer"), "tests/ui/drawer.zge", &font);
    try compare(@import("ui_grid"), "tests/ui/grid.zge", &font);
    try compare(@import("ui_lists"), "tests/ui/lists.zge", &font);
    try compare(@import("ui_richtext"), "tests/ui/richtext.zge", &font);
    try compare(@import("ui_svg"), "tests/ui/svg.zge", &font);
    try compare(@import("ui_charts"), "tests/ui/charts.zge", &font);
    try compare(@import("ui_view3d"), "tests/ui/view3d.zge", &font);
    try compare(@import("ui_map"), "tests/ui/map.zge", &font);
    try compare(@import("ui_clip"), "tests/ui/clip.zge", &font);
    try compare(@import("ui_mask"), "tests/ui/mask.zge", &font);
    try compare(@import("ui_masksource"), "tests/ui/masksource.zge", &font);
    try compare(@import("ui_varlist"), "tests/ui/varlist.zge", &font);
    try compare(@import("ui_svgfeatures"), "tests/ui/svgfeatures.zge", &font);
    try compare(@import("ui_strfn"), "tests/ui/strfn.zge", &font);
    try compare(@import("ui_textfit"), "tests/ui/textfit.zge", &font);
    try compare(@import("ui_scrollview"), "tests/ui/scrollview.zge", &font);
    try compare(@import("ui_machine"), "tests/ui/machine.zge", &font);
    try compare(@import("traffic_ui"), "examples/traffic.zge", &font);
    // Every window component of those files was compared.
    try testing.expectEqual(@as(usize, 46), compared);
}

test "the traffic light example, interpreted as the viewer runs it: the button clicked, timers fired" {
    const path = build_options.root ++ "/examples/traffic.zge";
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1 << 20));
    defer gpa.free(source);
    const prog = switch (try interp.Program.load(gpa, path, source, .{})) {
        .program => |p| p,
        .errors => |e| {
            defer gpa.free(e);
            std.debug.print("{s}\n", .{e});
            return error.TestUnexpectedResult;
        },
    };
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    // Where the compiled one has its button: the same layout.
    const compiled = try @import("traffic_ui").Traffic.create(gpa);
    const button = compiled.touch.item.absoluteGeometry();
    compiled.destroy();

    // The clock starts later than the instance (a backend's first frame).
    var t = core.now() + 100_000;
    const step = struct {
        fn by(clock: *u64, ms: u64) void {
            clock.* += ms;
            zigulee.updateTimersAndAnimations(clock.*);
            zigulee.runChangeHandlers();
        }
    }.by;
    step(&t, 20);
    step(&t, 5000);
    const w = app.window().?;
    const mid: core.Point = .{ .x = button.x + button.width / 2, .y = button.y + button.height / 2 };
    w.dispatchPointer(.{ .pressed = .{ .position = mid } });
    w.dispatchPointer(.{ .released = .{ .position = mid } });
    step(&t, 20);
    try testing.expect(app.property("requested").?.get().bool);
    // Yellow, red, clearance, walk.
    step(&t, 1000);
    step(&t, 1000);
    try testing.expectEqual(@as(i32, 1), app.property("crossings").?.get().int);
    // Walk, hurry, red and yellow: green again.
    step(&t, 4000);
    step(&t, 2000);
    step(&t, 1000);
    try testing.expect(!app.property("requested").?.get().bool);
}

test "the microwave of the SCXML specification, converted (examples/scxml/microwave.scxml) and run" {
    const path = build_options.root ++ "/examples/scxml/microwave.scxml";
    const doc = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1 << 20));
    defer gpa.free(doc);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const z = switch (try interp.compiler.scxml.convert(arena.allocator(), path, doc)) {
        .zge => |z| z,
        .errors => |e| {
            std.debug.print("{s}\n", .{e});
            return error.TestUnexpectedResult;
        },
    };
    // Nothing left out.
    for (z.warnings) |w| std.debug.print("warning: {d}: {s}\n", .{ w.line, w.message });
    try testing.expectEqual(@as(usize, 0), z.warnings.len);
    const source = try std.mem.concat(arena.allocator(), u8, &.{
        z.text,
        \\
        \\export component Harness inherits Window {
        \\    var out <string> at: Microwave.machine.current;
        \\    var out <int> ticks: Microwave.timer;
        \\    public function send(name: string) {
        \\        if name == "on" { Microwave.machine.turn_on(); }
        \\        if name == "time" { Microwave.machine.time(); }
        \\        if name == "open" { Microwave.machine.door_open(); }
        \\        if name == "close" { Microwave.machine.door_close(); }
        \\    }
        \\}
    });
    const prog = switch (try interp.Program.load(gpa, "microwave.zge", source, .{})) {
        .program => |p| p,
        .errors => |e| {
            defer gpa.free(e);
            std.debug.print("{s}\n", .{e});
            return error.TestUnexpectedResult;
        },
    };
    defer prog.destroy();
    const app = try prog.create(prog.component("Harness").?);
    defer app.destroy();
    const send = struct {
        fn f(a: *interp.Instance, what: []const u8) void {
            _ = a.call("send", &.{.{ .string = what }}, gpa);
        }
    }.f;
    try testing.expectEqualStrings("oven/engine/off, oven/door/closed", app.property("at").?.get().string);
    // On with the door closed: cooking at once (eventless, In('closed')).
    send(app, "on");
    try testing.expectEqualStrings("oven/engine/on/cooking, oven/door/closed", app.property("at").?.get().string);
    send(app, "time");
    send(app, "time");
    // The door opened: idle, the time kept.
    send(app, "open");
    try testing.expectEqualStrings("oven/engine/on/idle, oven/door/open", app.property("at").?.get().string);
    send(app, "time");
    try testing.expectEqual(@as(i32, 2), app.property("ticks").?.get().int);
    send(app, "close");
    // Done after 5 ticks: off, the timer back to 0.
    for (0..3) |_| send(app, "time");
    try testing.expectEqualStrings("oven/engine/off, oven/door/closed", app.property("at").?.get().string);
    try testing.expectEqual(@as(i32, 0), app.property("ticks").?.get().int);
}
