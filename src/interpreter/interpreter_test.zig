// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Runs `.zge` programs with the interpreter.

const std = @import("std");
const testing = std.testing;
const zigulee = @import("zigulee");
const interpreter = @import("interpreter.zig");
const Program = interpreter.Program;
const Value = interpreter.Value;

const gpa = testing.allocator;

fn load(source: []const u8) !*Program {
    return switch (try Program.load(gpa, "test.zge", source, .{})) {
        .program => |p| p,
        .errors => |e| {
            defer gpa.free(e);
            std.debug.print("errors:\n{s}\n", .{e});
            return error.TestUnexpectedResult;
        },
    };
}

test "a counter: properties, bindings, handlers, layout" {
    const prog = try load(
        \\component Button inherits Rectangle {
        \\    var in <string> text;
        \\    callback clicked();
        \\    width: 120px;
        \\    height: 32px;
        \\    background: touch.pressed ? #222 : #444;
        \\    label := Text { text: root.text; }
        \\    touch := TouchArea { clicked => { root.clicked(); } }
        \\}
        \\export component App inherits Window {
        \\    width: 300px;
        \\    height: 200px;
        \\    var in-out <int> count;
        \\    var out <string> summary: "Clicked \{count} time" + (count == 1 ? "" : "s");
        \\    var out <float> ratio: count / 4;
        \\    VerticalLayout {
        \\        padding: 8px;
        \\        b := Button { text: "+1"; clicked => { count += 1; } }
        \\    }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    const w = app.window().?;
    try testing.expectEqual(zigulee.core.Size{ .width = 300, .height = 200 }, w.size());
    try testing.expectEqualStrings("Clicked 0 times", app.property("summary").?.get().string);

    // The button is laid out (fixed size in a layout) and clickable.
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 150, .y = 24 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 150, .y = 24 } } });
    try testing.expectEqual(@as(i32, 1), app.property("count").?.get().int);
    try testing.expectEqualStrings("Clicked 1 time", app.property("summary").?.get().string);
    try testing.expectEqual(@as(f32, 0.25), app.property("ratio").?.get().float);
    app.property("count").?.set(.{ .int = 3 });
    try testing.expectEqualStrings("Clicked 3 times", app.property("summary").?.get().string);
}

test "anchors: edges to the parent and siblings, margins, fill and centering" {
    const prog = try load(
        \\export component App inherits Window {
        \\    width: 300px;
        \\    height: 200px;
        \\    var in-out <length> gap: 10px;
        \\    var out <string> side-at: "\{side.x / 1px} \{side.y / 1px} \{side.width / 1px} \{side.height / 1px}";
        \\    var out <string> next-at: "\{next.x / 1px} \{next.y / 1px} \{next.width / 1px} \{next.height / 1px}";
        \\    var out <string> corner-at: "\{corner.x / 1px} \{corner.y / 1px}";
        \\    var out <bool> label-centered: label.width > 10px && label.width < 100px && label.height < 50px
        \\        && abs(label.x + label.width / 2 - root.width / 2) < 0.01px && abs(label.y + label.height / 2 - root.height / 2) < 0.01px;
        \\    var out <string> middle-at: "\{middle.x / 1px} \{middle.y / 1px}";
        \\    var out <string> inner-at: "\{inner.x / 1px} \{inner.y / 1px} \{inner.width / 1px} \{inner.height / 1px}";
        \\    side := Rectangle {
        \\        width: 50px;
        \\        anchors.top: parent.top;
        \\        anchors.bottom: parent.bottom;
        \\        anchors.left: parent.left;
        \\        anchors.margins: root.gap;
        \\        anchors.bottom-margin: 20px;
        \\        inner := Rectangle { anchors.fill: parent; anchors.margins: 5px; }
        \\    }
        \\    next := Rectangle {
        \\        anchors.left: side.right;
        \\        anchors.left-margin: 4px;
        \\        anchors.right: parent.right;
        \\        anchors.top: side.top;
        \\        height: 30px;
        \\    }
        \\    corner := Rectangle {
        \\        width: 20px;
        \\        height: 10px;
        \\        anchors.right: parent.right;
        \\        anchors.bottom: parent.bottom;
        \\    }
        \\    middle := Rectangle {
        \\        width: 40px;
        \\        height: 20px;
        \\        anchors.center-in: parent;
        \\        anchors.vertical-center-offset: -10px;
        \\    }
        \\    label := Text { text: "Centered"; anchors.center-in: parent; }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    try testing.expectEqualStrings("10 10 50 170", app.property("side-at").?.get().string);
    try testing.expectEqualStrings("5 5 40 160", app.property("inner-at").?.get().string);
    try testing.expectEqualStrings("64 10 236 30", app.property("next-at").?.get().string);
    try testing.expectEqualStrings("280 190", app.property("corner-at").?.get().string);
    try testing.expectEqualStrings("130 80", app.property("middle-at").?.get().string);
    try testing.expect(app.property("label-centered").?.get().bool);

    // They follow what they are anchored to.
    app.property("gap").?.set(.{ .length = 0 });
    try testing.expectEqualStrings("0 0 50 180", app.property("side-at").?.get().string);
    try testing.expectEqualStrings("54 0 246 30", app.property("next-at").?.get().string);
    app.window().?.setSize(.{ .width = 400, .height = 100 });
    try testing.expectEqualStrings("380 90", app.property("corner-at").?.get().string);
    try testing.expectEqualStrings("180 30", app.property("middle-at").?.get().string);
    try testing.expect(app.property("label-centered").?.get().bool);
}

test "Canvas: paint runs, again when what it reads changes, not for what it sets" {
    const prog = try load(
        \\export component App inherits Window {
        \\    width: 100px;
        \\    height: 100px;
        \\    var in-out <int> runs;
        \\    var in-out <length> size: 10px;
        \\    c := Canvas {
        \\        paint => {
        \\            root.runs += 1;
        \\            self.begin-path();
        \\            self.arc(50px, 50px, root.size, 0, 360, false);
        \\            self.bezier-curve-to(1px, 2px, 3px, 4px, 5px, 6px);
        \\            self.fill-style = @linear-gradient(90deg, red, blue);
        \\            self.fill();
        \\            self.fill-text("x", 1px, 2px);
        \\        }
        \\    }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(i32, 1), app.property("runs").?.get().int);
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(i32, 1), app.property("runs").?.get().int);
    app.property("size").?.set(.{ .length = 20 });
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(i32, 2), app.property("runs").?.get().int);
    app.window().?.setSize(.{ .width = 120, .height = 100 });
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(i32, 3), app.property("runs").?.get().int);
}

test "loops and local variables" {
    const prog = try load(
        \\export component App inherits Window {
        \\    var in-out <[string]> names: ["a", "bb", "ccc"];
        \\    var out <string> joined;
        \\    var out <int> found: -1;
        \\    var out <float> halves;
        \\    callback run(string);
        \\    run(wanted) => {
        \\        let text = "";
        \\        for name[i] in names {
        \\            if name == wanted { found = i; break; }
        \\            text += name + "/";
        \\        }
        \\        joined = text;
        \\        let x: float = 1;
        \\        let n = 0;
        \\        while n < 3 { x = x / 2; n += 1; }
        \\        for k in n { if k == 1 { continue; } x += 0; }
        \\        halves = x;
        \\    }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    _ = app.invoke("run", &.{.{ .string = "ccc" }});
    try testing.expectEqualStrings("a/bb/", app.property("joined").?.get().string);
    try testing.expectEqual(@as(i32, 2), app.property("found").?.get().int);
    try testing.expectEqual(@as(f32, 0.125), app.property("halves").?.get().float);
}

test "components as values: a Loader shows one and passes it inputs" {
    const prog = try load(
        \\component Card inherits Rectangle {
        \\    var in <string> label;
        \\    var in <int> index;
        \\    var out <string> seen: label + index;
        \\}
        \\component Other inherits Rectangle { var in <string> label; }
        \\export component App inherits Window {
        \\    var in-out <bool> other;
        \\    var in-out <string> name: "a";
        \\    var in-out <component> kind: Card;
        \\    var out <bool> loaded: l.loaded;
        \\    var out <bool> is-card: kind == Card;
        \\    l := Loader { source: other ? Other : kind; label: name; index: 3; }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    zigulee.runChangeHandlers();
    try testing.expect(app.property("loaded").?.get().bool);
    try testing.expect(app.property("is-card").?.get().bool);
    const loader = app.window().?.rootItem().first_child.?;
    const card_root = loader.first_child orelse return error.TestUnexpectedResult;
    _ = card_root;
    // The instance's inputs.
    const l: *zigulee.items.Loader = @fieldParentPtr("item", loader);
    const card: *interpreter.Instance = @ptrCast(@alignCast(l.instance.?));
    try testing.expectEqualStrings("a3", card.property("seen").?.get().string);
    app.property("name").?.set(.{ .string = "b" });
    zigulee.runChangeHandlers();
    try testing.expectEqualStrings("b3", card.property("seen").?.get().string);
    app.property("other").?.set(.{ .bool = true });
    zigulee.runChangeHandlers();
    const other: *interpreter.Instance = @ptrCast(@alignCast(l.instance.?));
    try testing.expectEqualStrings("b", other.property("label").?.get().string);
}

test "connections: added to other elements' callbacks, and taken out" {
    const prog = try load(
        \\global Bus {
        \\    callback ping(int);
        \\    var out <int> last;
        \\    ping(n) => { last = n; }
        \\}
        \\component Counter inherits Rectangle {
        \\    callback bumped(int) -> int;
        \\    var out <int> answered;
        \\    public function bump(n: int) { answered = bumped(n); }
        \\}
        \\export component App inherits Window {
        \\    var in-out <bool> listening: true;
        \\    var out <int> heard;
        \\    var out <int> heard-all;
        \\    var out <int> pings;
        \\    callback bump(int);
        \\    bump(n) => { counter.bump(n); }
        \\    callback ping(int);
        \\    ping(n) => { Bus.ping(n); }
        \\    counter := Counter { bumped(n) => { return n * 10; } }
        \\    counter.bumped(n) => { heard = n; }
        \\    Connections { target: counter; enabled: root.listening; bumped(n) => { heard-all += n; } }
        \\    Connections { target: Bus; ping(n) => { pings += n; } }
        \\}
    );
    defer prog.destroy();
    const gone = try prog.create(prog.mainComponent().?);
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    _ = app.invoke("bump", &.{.{ .int = 2 }});
    try testing.expectEqual(@as(i32, 2), app.property("heard").?.get().int);
    try testing.expectEqual(@as(i32, 2), app.property("heard-all").?.get().int);
    app.property("listening").?.set(.{ .bool = false });
    _ = app.invoke("bump", &.{.{ .int = 3 }});
    try testing.expectEqual(@as(i32, 3), app.property("heard").?.get().int);
    try testing.expectEqual(@as(i32, 2), app.property("heard-all").?.get().int);

    // The global: its handler, then each app's connection.
    _ = app.invoke("ping", &.{.{ .int = 4 }});
    try testing.expectEqual(@as(i32, 4), app.property("pings").?.get().int);
    try testing.expectEqual(@as(i32, 4), gone.property("pings").?.get().int);
    gone.destroy(); // connected first: out of the middle of the chain
    _ = app.invoke("ping", &.{.{ .int = 1 }});
    try testing.expectEqual(@as(i32, 5), app.property("pings").?.get().int);
    const bus = (try prog.globalNamed("Bus")).?;
    try testing.expectEqual(@as(i32, 1), bus.property("last").?.get().int);
}

test "animations started, paused, resumed and stopped from code" {
    const prog = try load(
        \\export component App inherits Window {
        \\    var out <length> x: box.x;
        \\    var out <bool> running: slide.running;
        \\    callback go(string);
        \\    go(what) => {
        \\        if what == "start" { slide.start(); }
        \\        if what == "pause" { slide.pause(); }
        \\        if what == "resume" { slide.resume(); }
        \\        if what == "stop" { slide.stop(); }
        \\    }
        \\    box := Rectangle { width: 10px; height: 10px; }
        \\    slide := SequentialAnimation {
        \\        PropertyAnimation { target: box.x; from: 0px; to: 100px; duration: 100ms; }
        \\        PropertyAnimation { target: box.x; to: 0px; duration: 100ms; }
        \\    }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    var now = zigulee.core.now();
    const step = struct {
        fn f(t: *u64, ms: u64) void {
            t.* += ms;
            zigulee.updateTimersAndAnimations(t.*);
            zigulee.runChangeHandlers();
        }
    }.f;
    _ = app.invoke("go", &.{.{ .string = "start" }});
    step(&now, 50);
    try testing.expectApproxEqAbs(@as(f32, 50), app.property("x").?.get().length, 1);
    _ = app.invoke("go", &.{.{ .string = "pause" }});
    step(&now, 500);
    try testing.expectApproxEqAbs(@as(f32, 50), app.property("x").?.get().length, 1);
    _ = app.invoke("go", &.{.{ .string = "resume" }});
    step(&now, 100); // 150: on the way back, from 100
    try testing.expectApproxEqAbs(@as(f32, 50), app.property("x").?.get().length, 1);
    try testing.expect(app.property("running").?.get().bool);
    _ = app.invoke("go", &.{.{ .string = "stop" }});
    try testing.expect(!app.property("running").?.get().bool);
    step(&now, 100);
    try testing.expectApproxEqAbs(@as(f32, 50), app.property("x").?.get().length, 1);
}

test "models sorted, filtered and reversed" {
    const prog = try load(
        \\export component App inherits Window {
        \\    var in-out <[int]> numbers: [5, 3, 8, 1];
        \\    var in-out <int> over: 2;
        \\    var out <[int]> big: numbers.filter(n => n > over).sort(n => n);
        \\    var out <string> text;
        \\    callback run(int);
        \\    run(limit) => {
        \\        let cap = limit;
        \\        text = "";
        \\        for n in numbers.filter(n => n <= cap).reverse() { text += n + ","; }
        \\    }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    const big = app.property("big").?.get().model;
    try testing.expectEqual(@as(usize, 3), big.rowCount());
    try testing.expectEqual(@as(i32, 3), big.rowData(0).?.int);
    try testing.expectEqual(@as(i32, 8), big.rowData(2).?.int);
    app.property("over").?.set(.{ .int = 4 });
    const big2 = app.property("big").?.get().model;
    try testing.expectEqual(@as(usize, 2), big2.rowCount());
    try testing.expectEqual(@as(i32, 5), big2.rowData(0).?.int);
    _ = app.invoke("run", &.{.{ .int = 5 }});
    try testing.expectEqualStrings("1,3,5,", app.property("text").?.get().string);
}

test "shortcuts" {
    const prog = try load(
        \\export component App inherits Window {
        \\    var in-out <int> saves;
        \\    var in-out <bool> can-save: true;
        \\    Shortcut {
        \\        sequence: "Ctrl+Shift+S";
        \\        enabled: root.can-save;
        \\        activated => { root.saves += 1; }
        \\    }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    const w = app.window().?;
    var mods: zigulee.core.input.Modifiers = if (@import("builtin").os.tag == .macos) .{ .meta = true } else .{ .control = true };
    w.dispatchKey(.pressed, .{ .text = "S", .modifiers = mods });
    try testing.expectEqual(@as(i32, 0), app.property("saves").?.get().int); // no Shift
    mods.shift = true;
    w.dispatchKey(.pressed, .{ .text = "S", .modifiers = mods });
    try testing.expectEqual(@as(i32, 1), app.property("saves").?.get().int);
    app.property("can-save").?.set(.{ .bool = false });
    w.dispatchKey(.pressed, .{ .text = "S", .modifiers = mods });
    try testing.expectEqual(@as(i32, 1), app.property("saves").?.get().int);
}

test "a stack view: pages pushed by a function taking a component" {
    const prog = try load(
        \\component Home inherits Rectangle {}
        \\component Detail inherits Rectangle {}
        \\export component App inherits Window {
        \\    width: 100px;
        \\    height: 100px;
        \\    var out <int> depth: nav.depth;
        \\    callback open();
        \\    open => { nav.push(Detail); }
        \\    callback back();
        \\    back => { nav.pop(); }
        \\    nav := StackView { initial-page: Home; }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(i32, 1), app.property("depth").?.get().int);
    _ = app.invoke("open", &.{});
    try testing.expectEqual(@as(i32, 2), app.property("depth").?.get().int);
    var now = zigulee.core.now();
    now += 300;
    zigulee.updateTimersAndAnimations(now);
    _ = app.invoke("back", &.{});
    now += 300;
    zigulee.updateTimersAndAnimations(now);
    try testing.expectEqual(@as(i32, 1), app.property("depth").?.get().int);
}

test "load errors are reported, not run" {
    switch (try Program.load(gpa, "bad.zge", "export component A inherits Rectangle { background: 1; }", .{})) {
        .program => |p| {
            p.destroy();
            return error.TestUnexpectedResult;
        },
        .errors => |e| {
            defer gpa.free(e);
            try testing.expect(std.mem.indexOf(u8, e, "bad.zge:1:53: error") != null);
        },
    }
}

test "components, callbacks and models from the host" {
    const prog = try load(
        \\struct Item { name: string, done: bool }
        \\export component Panel inherits Rectangle {}
        \\export component Todo inherits Window {
        \\    var in <[Item]> todos: [{ name: "a", done: true }, { name: "b", done: false }];
        \\    var out <int> open: todos.length - (todos[0].done ? 1 : 0);
        \\    callback added(string) -> int;
        \\    callback add(string);
        \\    add(text) => { last = added(text); }
        \\    var in-out <int> last;
        \\    VerticalLayout {
        \\        for t in todos : Text { text: t.name; }
        \\    }
        \\}
    );
    defer prog.destroy();
    // The last exported window is the main component; others by name.
    try testing.expectEqualStrings("Todo", prog.mainComponent().?.name);
    try testing.expect(prog.component("Panel") != null);
    try testing.expect(prog.component("Nope") == null);

    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    try testing.expectEqual(@as(i32, 1), app.property("open").?.get().int);
    // A native handler for a declared callback.
    const H = struct {
        fn run(_: *anyopaque, args: []const Value) Value {
            return .{ .int = @intCast(args[0].string.len) };
        }
    };
    var dummy: u8 = 0;
    var handler: @import("reflect.zig").DynHandler = .{ .ctx = &dummy, .run = H.run };
    try testing.expect(app.onCallback("added", &handler));
    _ = app.invoke("add", &.{.{ .string = "four" }});
    try testing.expectEqual(@as(i32, 4), app.property("last").?.get().int);
}

test "inspection: elements at a point and in the source, properties" {
    const source =
        \\component Badge inherits Rectangle {
        \\    var in <string> label: "new";
        \\    background: red;
        \\    Text { width: 20px; text: root.label; }
        \\}
        \\export component App inherits Window {
        \\    width: 200px;
        \\    height: 100px;
        \\    var in-out <bool> on;
        \\    b := Badge { x: 10px; y: 10px; width: 50px; height: 20px; label: "hi"; }
        \\}
    ;
    const prog = try load(source);
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    const Inspect = interpreter.Inspect;

    var found: std.ArrayList(interpreter.ElementRef) = .empty;
    defer found.deinit(gpa);
    try Inspect.elementsAt(app, .{ .x = 20, .y = 15 }, gpa, &found);
    // The window, the badge (its use in App, then its root inside Badge)
    // and the Text inside it.
    try testing.expectEqual(@as(usize, 4), found.items.len);
    try testing.expectEqualStrings("Window", found.items[0].typeName());
    try testing.expectEqualStrings("b", found.items[1].id().?);
    try testing.expectEqualStrings("Rectangle", found.items[2].typeName());
    try testing.expectEqualStrings("Text", found.items[3].typeName());
    found.clearRetainingCapacity();
    // Where the Text does not cover: down to the badge.
    try Inspect.elementsAt(app, .{ .x = 58, .y = 28 }, gpa, &found);
    try testing.expectEqual(@as(usize, 3), found.items.len);
    try testing.expectEqualStrings("Rectangle", found.items[2].typeName());

    // From the source: the cursor in `b := Badge { ... }`.
    const offset: u32 = @intCast(std.mem.indexOf(u8, source, "label: \"hi\"").?);
    const at = Inspect.elementAtSource(app, 0, offset).?;
    try testing.expectEqualStrings("b", at.id().?);
    try testing.expectEqual(@as(f32, 50), at.item().width.get());

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const props = try Inspect.properties(at, arena.allocator());
    try testing.expectEqualStrings("label", props[0].name);
    try testing.expectEqualStrings("\"hi\"", props[0].value);
    var bg: ?interpreter.PropertyInfo = null;
    for (props) |p| if (std.mem.eql(u8, p.name, "background")) {
        bg = p;
    };
    try testing.expectEqualStrings("#ff0000ff", bg.?.value);

    // Setting values from text.
    try testing.expect((try Inspect.setProperty(at, "label", "\"set\"", arena.allocator())) == null);
    try testing.expectEqualStrings("\"set\"", (try Inspect.properties(at, arena.allocator()))[0].value);
    try testing.expect((try Inspect.setProperty(at, "width", "80px", arena.allocator())) == null);
    try testing.expectEqual(@as(f32, 80), at.item().width.get());
    try testing.expectEqualStrings("expected a length", (try Inspect.setProperty(at, "width", "\"wide\"", arena.allocator())).?);
    try testing.expectEqualStrings("no such property", (try Inspect.setProperty(at, "nope", "1", arena.allocator())).?);
}

test "an image loaded at run time" {
    const prog = try load(
        \\export component App inherits Window {
        \\    width: 100px;
        \\    height: 100px;
        \\    var in-out <string> url: "tests/ui/badge.svg";
        \\    var out <bool> ready: photo.status == ImageStatus.ready;
        \\    var out <bool> failed: photo.status == ImageStatus.error;
        \\    var out <length> natural: photo.preferred-width;
        \\    photo := Image { source-url: root.url; }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    for (0..1000) |_| {
        zigulee.updateTimersAndAnimations(zigulee.core.now() + 16);
        zigulee.runChangeHandlers();
        if (app.property("ready").?.get().bool or app.property("failed").?.get().bool) break;
        var t: std.Io.Threaded = .init_single_threaded;
        t.io().sleep(.fromMilliseconds(2), .awake) catch {};
    }
    try testing.expect(app.property("ready").?.get().bool);
    try testing.expectEqual(@as(f32, 32), app.property("natural").?.get().length);
}

test "window state from .zge" {
    const prog = try load(
        \\export component App inherits Window {
        \\    width: 100px;
        \\    height: 100px;
        \\    var in-out <bool> big;
        \\    always-on-top: true;
        \\    maximized <=> root.big;
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    const w = app.window().?;
    try testing.expect(w.always_on_top.get());
    app.property("big").?.set(.{ .bool = true });
    try testing.expect(w.maximized.get());
    w.maximized.set(false);
    try testing.expect(!app.property("big").?.get().bool);
}

test "safe area and keyboard from the backend" {
    const prog = try load(
        \\export component App inherits Window {
        \\    width: 100px;
        \\    height: 100px;
        \\    var out <length> clear: root.height - root.safe-area-top - max(root.safe-area-bottom, root.keyboard-height);
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    const w = app.window().?;
    w.safe_area_top.set(20);
    w.keyboard_height.set(30);
    try testing.expectEqual(@as(f32, 50), app.property("clear").?.get().length);
}

test "a selection: rows toggled and extended by Ctrl- and Shift-clicks" {
    const prog = try load(
        \\export component App inherits Window {
        \\    width: 100px;
        \\    height: 100px;
        \\    var out <int> count: picked.selected-rows.length;
        \\    var out <bool> third: picked.selected[2];
        \\    picked := Selection { count: 4; }
        \\    for n[i] in 4 : TouchArea {
        \\        y: i * 20px;
        \\        height: 20px;
        \\        clicked => {
        \\            if self.modifiers.shift {
        \\                picked.extend-to(i);
        \\            } else if self.modifiers.control {
        \\                picked.toggle(i);
        \\            } else {
        \\                picked.select(i);
        \\            }
        \\        }
        \\    }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    const w = app.window().?;
    const click = struct {
        fn f(win: *zigulee.Window, y: f32, mods: zigulee.core.input.Modifiers) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 50, .y = y }, .modifiers = mods } });
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = 50, .y = y } } });
            zigulee.runChangeHandlers();
        }
    }.f;
    click(w, 10, .{});
    click(w, 50, .{ .control = true });
    try testing.expectEqual(@as(i32, 2), app.property("count").?.get().int);
    try testing.expect(app.property("third").?.get().bool);
    click(w, 70, .{ .shift = true }); // from the third to the fourth
    try testing.expectEqual(@as(i32, 2), app.property("count").?.get().int);
    click(w, 30, .{});
    try testing.expectEqual(@as(i32, 1), app.property("count").?.get().int);
    try testing.expect(!app.property("third").?.get().bool);
}

test "a component inheriting a window component: shown, with its own title and size" {
    const prog = try load(
        \\export component Base inherits Window {
        \\    width: 200px;
        \\    height: 100px;
        \\    title: "Base";
        \\}
        \\export component Big inherits Base {
        \\    width: 300px;
        \\    title: "Big";
        \\}
    );
    defer prog.destroy();
    // The last window of the file: the one inheriting.
    const comp = prog.mainComponent().?;
    try testing.expectEqualStrings("Big", comp.name);
    try testing.expect(comp.showsWindow() and comp.inheritsWindow());
    const app = try prog.create(comp);
    defer app.destroy();
    zigulee.runChangeHandlers();
    const w = app.window().?;
    try testing.expectEqual(@as(f32, 300), w.size().width);
    try testing.expectEqual(@as(f32, 100), w.size().height);
    try testing.expectEqualStrings("Big", app.windowTitle().get());
}

test "settings: a component inheriting Settings keeps its properties" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "app.ini" });
    defer gpa.free(path);
    const source =
        \\component ViewSettings inherits Settings {
        \\    category: "view";
        \\    var in-out <int> count: 3;
        \\    var in-out <length> size: 10px;
        \\}
        \\component MoreSettings inherits ViewSettings {
        \\    var in-out <bool> dark;
        \\    var in-out <string> name: "plain";
        \\}
        \\export component App inherits Window {
        \\    var in <string> file;
        \\    var in-out <int> clicks;
        \\    store := MoreSettings { file: root.file; count <=> root.clicks; }
        \\    TouchArea { clicked => { root.clicks += 1; store.dark = true; store.name = "a\nb"; } }
        \\}
    ;
    const prog = try load(source);
    defer prog.destroy();
    {
        const app = try prog.create(prog.mainComponent().?);
        defer app.destroy();
        app.property("file").?.set(.{ .string = path });
        zigulee.runChangeHandlers();
        try testing.expectEqual(@as(i32, 0), app.property("clicks").?.get().int);
        const w = app.window().?;
        w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 10, .y = 10 } } });
        w.dispatchPointer(.{ .released = .{ .position = .{ .x = 10, .y = 10 } } });
        zigulee.runChangeHandlers();
        // Written when it goes, as the delay has not passed.
    }
    const text = try tmp.dir.readFileAlloc(testing.io, "app.ini", gpa, .unlimited);
    defer gpa.free(text);
    try testing.expectEqualStrings("[view]\ncount=1\nsize=10\ndark=true\nname=a\\nb\n", text);

    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    app.property("file").?.set(.{ .string = path });
    zigulee.runChangeHandlers();
    try testing.expectEqual(@as(i32, 1), app.property("clicks").?.get().int);
}

test "settings: only some types can be kept" {
    const r = try Program.load(gpa, "test.zge", "component S inherits Settings { var in-out <image> pic; }", .{});
    switch (r) {
        .program => |p| {
            p.destroy();
            return error.TestUnexpectedResult;
        },
        .errors => |e| {
            defer gpa.free(e);
            try testing.expect(std.mem.indexOf(u8, e, "Settings cannot keep a image property") != null);
        },
    }
}

test "http: a request sent, its JSON answer read by path" {
    if (!zigulee.core.http.threaded) return error.SkipZigTest;
    var server: zigulee.core.http.EchoServer = undefined;
    try server.start();
    defer server.stop();
    var buf: [64]u8 = undefined;
    const prog = try load(
        \\export component App inherits Window {
        \\    var in <string> base;
        \\    var in-out <string> outcome;
        \\    var out <string> token: json-get(req.response, "token");
        \\    var out <int> count: json-count(req.response, "items");
        \\    var out <float> pi: json-number("{\"pi\": 3.5}", "pi");
        \\    req := HttpRequest {
        \\        url: "\{root.base}/things";
        \\        method: put;
        \\        headers: ["X-Token: zge"];
        \\        finished => { root.outcome = json-get(req.response, "method") + " \{req.status}"; }
        \\        failed => { root.outcome = "failed"; }
        \\    }
        \\    TouchArea { clicked => { req.send(); } }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    app.property("base").?.set(.{ .string = server.url(&buf, "") });
    try testing.expectEqual(@as(f32, 3.5), app.property("pi").?.get().float);
    const w = app.window().?;
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 10, .y = 10 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 10, .y = 10 } } });
    zigulee.runChangeHandlers();
    var now = zigulee.core.now();
    for (0..2000) |_| {
        if (app.property("outcome").?.get().string.len > 0) break;
        now += 15;
        zigulee.updateTimersAndAnimations(now);
        zigulee.runChangeHandlers();
        testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
    }
    try testing.expectEqualStrings("PUT 200", app.property("outcome").?.get().string);
    try testing.expectEqualStrings("zge", app.property("token").?.get().string);
    try testing.expectEqual(@as(i32, 2), app.property("count").?.get().int);
}

test "KeyboardInput: typing into the focused text input" {
    const prog = try load(
        \\export component App inherits Window {
        \\    width: 200px;
        \\    height: 100px;
        \\    var out <string> typed: field.text;
        \\    var out <bool> active: keys.active;
        \\    field := TextInput { height: 50px; }
        \\    keys := KeyboardInput { }
        \\    TouchArea {
        \\        y: 50px;
        \\        height: 50px;
        \\        clicked => {
        \\            keys.send("o");
        \\            keys.send("k");
        \\            keys.send(Key.Backspace);
        \\        }
        \\    }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    const w = app.window().?;
    try testing.expect(!app.property("active").?.get().bool);
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 10, .y = 10 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 10, .y = 10 } } });
    zigulee.runChangeHandlers();
    try testing.expect(app.property("active").?.get().bool);
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 10, .y = 70 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 10, .y = 70 } } });
    zigulee.runChangeHandlers();
    try testing.expectEqualStrings("o", app.property("typed").?.get().string);
    try testing.expect(app.property("active").?.get().bool);
}

test "open-url: links handed to the system's opener" {
    const Fake = struct {
        var len: usize = 0;
        fn open(_: ?*anyopaque, url: []const u8) bool {
            len = url.len;
            return true;
        }
    };
    zigulee.core.links.setOpener(.{ .open = Fake.open });
    defer zigulee.core.links.setOpener(null);
    const prog = try load(
        \\export component App inherits Window {
        \\    var in-out <bool> opened;
        \\    TouchArea {
        \\        clicked => {
        \\            open-url("https://ziglang.org");
        \\            root.opened = open-url("nope");
        \\        }
        \\    }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    app.property("opened").?.set(.{ .bool = true });
    const w = app.window().?;
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 10, .y = 10 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 10, .y = 10 } } });
    try testing.expectEqual(@as(usize, 19), Fake.len);
    try testing.expect(!app.property("opened").?.get().bool);
}

test "state machines: events, guards, entry and exit actions, after, its own events; one in a global" {
    const prog = try load(
        \\export global Session {
        \\    var out <string> user;
        \\    machine := StateMachine {
        \\        event sign-in(string);
        \\        state out { on sign-in(name) => in { user = name; } }
        \\        state in { after 100ms => out { user = ""; } }
        \\    }
        \\}
        \\enum Why { none, refused }
        \\export component App inherits Window {
        \\    var out <string> log;
        \\    var out <Why> why;
        \\    var out <bool> busy: m.active(loading);
        \\    var out <bool> signed: Session.machine.active(in);
        \\    m := StateMachine {
        \\        event go;
        \\        event done(bool, Why);
        \\        event ping(int);
        \\        state idle {
        \\            exited => { log += "-idle "; }
        \\            on go => loading { log += "go "; }
        \\        }
        \\        state loading {
        \\            entered => { log += "+loading "; }
        \\            on done(ok, w) when ok => ready;
        \\            on done(ok, w) => idle { why = w; }
        \\            after 50ms => idle;
        \\        }
        \\        state ready {
        \\            entered => { m.ping(7); log += "+ready "; }
        \\            on ping(n) { log += "ping\{n} "; }
        \\        }
        \\    }
        \\    public function go() { m.go(); }
        \\    public function done(ok: bool) { m.done(ok, Why.refused); }
        \\    public function ready() -> bool { return m.state == ready; }
        \\    public function sign-in() { Session.machine.sign-in("ada"); }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    var t = zigulee.core.now();

    _ = app.call("go", &.{}, gpa);
    try testing.expectEqualStrings("-idle go +loading ", app.property("log").?.get().string);
    try testing.expect(app.property("busy").?.get().bool);
    _ = app.call("done", &.{.{ .bool = false }}, gpa);
    try testing.expectEqualStrings("refused", app.property("why").?.get().enumeration.def.values[app.property("why").?.get().enumeration.index][0]);
    try testing.expect(!app.property("busy").?.get().bool);
    // After 50 ms in `loading`: back to idle.
    _ = app.call("go", &.{}, gpa);
    t += 60;
    zigulee.updateTimersAndAnimations(t);
    try testing.expect(!app.property("busy").?.get().bool);
    // Its own event, after the entry action.
    _ = app.call("go", &.{}, gpa);
    app.property("log").?.set(.{ .string = "" });
    _ = app.call("done", &.{.{ .bool = true }}, gpa);
    try testing.expectEqualStrings("+ready ping7 ", app.property("log").?.get().string);
    try testing.expect(app.call("ready", &.{}, gpa).?.bool);

    // The global's.
    try testing.expect(!app.property("signed").?.get().bool);
    _ = app.call("sign-in", &.{}, gpa);
    try testing.expect(app.property("signed").?.get().bool);
    const session = (try prog.globalNamed("Session")).?;
    try testing.expectEqualStrings("ada", session.property("user").?.get().string);
    t += 150;
    zigulee.updateTimersAndAnimations(t);
    try testing.expect(!app.property("signed").?.get().bool);
    try testing.expectEqualStrings("", session.property("user").?.get().string);
}

test "state machines with states inside states: the parent's transitions, history, paths in active()" {
    const prog = try load(
        \\export component App inherits Window {
        \\    var out <string> log;
        \\    var out <bool> editing: m.active(doc.edit);
        \\    var out <bool> in-doc: m.active(doc);
        \\    m := StateMachine {
        \\        event open;
        \\        event close;
        \\        event edit;
        \\        event save;
        \\        state home { on open => doc.history; }
        \\        state doc {
        \\            history;
        \\            entered => { log += "+doc "; }
        \\            exited => { log += "-doc "; }
        \\            on close => home;
        \\            after 1s => home;
        \\            state view {
        \\                exited => { log += "-view "; }
        \\                on edit => edit;
        \\            }
        \\            state edit {
        \\                entered => { log += "+edit "; }
        \\                on save => view;
        \\            }
        \\        }
        \\    }
        \\    public function send(what: string) {
        \\        if what == "open" { m.open(); }
        \\        if what == "close" { m.close(); }
        \\        if what == "edit" { m.edit(); }
        \\        if what == "save" { m.save(); }
        \\    }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    var t = zigulee.core.now();
    const send = struct {
        fn f(a: *interpreter.Instance, what: []const u8) void {
            _ = a.call("send", &.{.{ .string = what }}, gpa);
        }
    }.f;

    send(app, "open");
    try testing.expect(app.property("in-doc").?.get().bool and !app.property("editing").?.get().bool);
    send(app, "edit");
    try testing.expect(app.property("editing").?.get().bool);
    try testing.expectEqualStrings("+doc -view +edit ", app.property("log").?.get().string);
    // Closed from inside, opened back where it was.
    send(app, "close");
    try testing.expect(!app.property("in-doc").?.get().bool);
    send(app, "open");
    try testing.expect(app.property("editing").?.get().bool);
    try testing.expectEqualStrings("+doc -view +edit -doc +doc +edit ", app.property("log").?.get().string);
    // The parent's after.
    t += 1100;
    zigulee.updateTimersAndAnimations(t);
    try testing.expect(!app.property("in-doc").?.get().bool);
}

test "state machines: parallel regions, final states and done, eventless transitions" {
    const prog = try load(
        \\export component App inherits Window {
        \\    var in-out <bool> go;
        \\    var out <string> log;
        \\    var out <bool> both: m.active(lamp.on) && m.active(fan.on);
        \\    m := StateMachine {
        \\        event switch;
        \\        event stop-fan;
        \\        event poke;
        \\        state wait { when go => run; }
        \\        parallel run {
        \\            on done.run => over { log += "over "; }
        \\            state lamp {
        \\                state off { on switch => on; }
        \\                state on { on switch => out; }
        \\                final out;
        \\            }
        \\            state fan {
        \\                on done.fan { log += "fan-done "; }
        \\                state on { on stop-fan => out; }
        \\                final out;
        \\            }
        \\        }
        \\        final over;
        \\    }
        \\    public function send(what: string) {
        \\        if what == "switch" { m.switch(); }
        \\        if what == "stop-fan" { m.stop-fan(); }
        \\        if what == "poke" { m.poke(); }
        \\    }
        \\    public function lamp() -> bool { return m.lamp-state == on; }
        \\}
    );
    defer prog.destroy();
    const app = try prog.create(prog.mainComponent().?);
    defer app.destroy();
    const send = struct {
        fn f(a: *interpreter.Instance, what: []const u8) void {
            _ = a.call("send", &.{.{ .string = what }}, gpa);
        }
    }.f;

    app.property("go").?.set(.{ .bool = true });
    send(app, "poke");
    try testing.expect(!app.property("both").?.get().bool);
    send(app, "switch");
    try testing.expect(app.property("both").?.get().bool);
    try testing.expect(app.call("lamp", &.{}, gpa).?.bool);
    send(app, "stop-fan");
    try testing.expectEqualStrings("fan-done ", app.property("log").?.get().string);
    send(app, "switch");
    try testing.expectEqualStrings("fan-done over ", app.property("log").?.get().string);
}

// ---- SCXML converted and run (`zgec scxml`) ----

const scxml = @import("../compiler/scxml.zig");

/// `doc` converted, with `harness` (a component using the global) after
/// it, loaded; it must convert without warnings when `quiet`.
fn loadScxml(doc: []const u8, harness: []const u8, quiet: bool) !*Program {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const z = switch (try scxml.convert(arena.allocator(), "test.scxml", doc)) {
        .zge => |z| z,
        .errors => |e| {
            std.debug.print("{s}\n", .{e});
            return error.TestUnexpectedResult;
        },
    };
    if (quiet and z.warnings.len > 0) {
        for (z.warnings) |w| std.debug.print("warning: {d}: {s}\n", .{ w.line, w.message });
        return error.TestUnexpectedResult;
    }
    const source = try std.mem.concat(arena.allocator(), u8, &.{ z.text, "\n", harness });
    return switch (try Program.load(gpa, "converted.zge", source, .{})) {
        .program => |p| p,
        .errors => |e| {
            defer gpa.free(e);
            std.debug.print("{s}\n--- source:\n{s}\n", .{ e, source });
            return error.TestUnexpectedResult;
        },
    };
}

/// The harness of the conformance tests: where the machine is, and a
/// function sending `name` (the events listed).
fn harnessFor(comptime events: []const []const u8) []const u8 {
    comptime var sends: []const u8 = "";
    inline for (events) |e| sends = sends ++ "        if name == \"" ++ e ++ "\" { Test.machine." ++ e ++ "(); }\n";
    return "export component Harness inherits Window {\n    var out <string> at: Test.machine.current;\n    public function send(name: string) {\n" ++ sends ++ "    }\n}\n";
}

/// Runs a conformance test: converted, started, `events` sent in order;
/// it must end in its final state `pass`.
fn expectPass(doc: []const u8, comptime events: []const []const u8) !void {
    const prog = try loadScxml(doc, comptime harnessFor(events), false);
    defer prog.destroy();
    const app = try prog.create(prog.component("Harness").?);
    defer app.destroy();
    inline for (events) |e| _ = app.call("send", &.{.{ .string = e }}, gpa);
    const at = app.property("at").?.get().string;
    if (!std.mem.eql(u8, at, "pass")) {
        std.debug.print("ended in '{s}', not 'pass'\n", .{at});
        return error.TestUnexpectedResult;
    }
}

test "SCXML conformance: the first enabled transition in document order; a child's before its parent's" {
    try expectPass(
        \\<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" name="test">
        \\  <state id="s0">
        \\    <transition event="e" target="fail"/>
        \\    <state id="s01">
        \\      <transition event="e" cond="false" target="fail"/>
        \\      <transition event="e" target="s02"/>
        \\      <transition event="e" target="fail"/>
        \\    </state>
        \\    <state id="s02">
        \\      <transition cond="true" target="pass"/>
        \\      <transition target="fail"/>
        \\    </state>
        \\  </state>
        \\  <final id="pass"/>
        \\  <final id="fail"/>
        \\</scxml>
    , &.{"e"});
}

test "SCXML conformance: raised events in order, before the next external one" {
    try expectPass(
        \\<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" name="test">
        \\  <state id="s0">
        \\    <onentry><raise event="e1"/><raise event="e2"/></onentry>
        \\    <transition event="e1" target="s1"/>
        \\    <transition event="ext" target="fail"/>
        \\  </state>
        \\  <state id="s1">
        \\    <transition event="e2" target="s2"/>
        \\    <transition event="ext" target="fail"/>
        \\  </state>
        \\  <state id="s2">
        \\    <onentry><raise event="e3"/></onentry>
        \\    <transition event="ext" target="fail"/>
        \\    <transition event="e3" target="s3"/>
        \\  </state>
        \\  <state id="s3"><transition event="ext" target="pass"/></state>
        \\  <final id="pass"/>
        \\  <final id="fail"/>
        \\</scxml>
    , &.{"ext"});
}

test "SCXML conformance: done.state of a compound state, and of a parallel state once all its regions are" {
    try expectPass(
        \\<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" name="test">
        \\  <state id="s0">
        \\    <transition event="done.state.s0" target="p"/>
        \\    <state id="s01"><transition event="go" target="s0final"/></state>
        \\    <final id="s0final"/>
        \\  </state>
        \\  <parallel id="p">
        \\    <transition event="done.state.p" target="pass"/>
        \\    <state id="r1">
        \\      <state id="r1a"><transition event="a" target="r1end"/></state>
        \\      <final id="r1end"/>
        \\    </state>
        \\    <state id="r2">
        \\      <state id="r2a"><transition event="b" target="r2end"/></state>
        \\      <final id="r2end"/>
        \\    </state>
        \\  </parallel>
        \\  <final id="pass"/>
        \\</scxml>
    , &.{ "go", "a", "b" });
}

test "SCXML conformance: shallow history resumes the last active state" {
    try expectPass(
        \\<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" name="test">
        \\  <state id="s0" initial="s01">
        \\    <history id="h0"><transition target="s01"/></history>
        \\    <transition event="leave" target="out"/>
        \\    <state id="s01"><transition event="next" target="s02"/></state>
        \\    <state id="s02"><transition event="check" target="pass"/></state>
        \\  </state>
        \\  <state id="out"><transition event="back" target="h0"/></state>
        \\  <final id="pass"/>
        \\</scxml>
    , &.{ "next", "leave", "back", "check" });
}

test "SCXML conformance: In() and the data model, assign and if/elseif/else" {
    try expectPass(
        \\<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" name="test" initial="p">
        \\  <datamodel><data id="x" expr="1"/></datamodel>
        \\  <parallel id="p">
        \\    <state id="a">
        \\      <state id="a1">
        \\        <transition event="t" cond="In('b1')" target="a2">
        \\          <assign location="x" expr="x * 10"/>
        \\        </transition>
        \\      </state>
        \\      <state id="a2">
        \\        <onentry>
        \\          <if cond="x === 1"><assign location="x" expr="-1"/>
        \\          <elseif cond="x == 10"/><assign location="x" expr="x + 5"/>
        \\          <else/><assign location="x" expr="-2"/></if>
        \\        </onentry>
        \\        <transition cond="x == 15 &amp;&amp; !In('a1')" target="pass"/>
        \\      </state>
        \\    </state>
        \\    <state id="b"><state id="b1"/></state>
        \\  </parallel>
        \\  <final id="pass"/>
        \\</scxml>
    , &.{"t"});
}

test "SCXML: a delayed send, an after of its state" {
    // A timeout: sent after 1 s, unless left before.
    {
        const prog = try loadScxml(
            \\<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" name="test">
            \\  <state id="wait">
            \\    <onentry><send event="timeout" delay="1s"/></onentry>
            \\    <transition event="timeout" target="pass"/>
            \\  </state>
            \\  <final id="pass"/>
            \\</scxml>
        , comptime harnessFor(&.{}), false);
        defer prog.destroy();
        const app = try prog.create(prog.component("Harness").?);
        defer app.destroy();
        var t = zigulee.core.now();
        t += 500;
        zigulee.updateTimersAndAnimations(t);
        try testing.expectEqualStrings("wait", app.property("at").?.get().string);
        t += 600;
        zigulee.updateTimersAndAnimations(t);
        try testing.expectEqualStrings("pass", app.property("at").?.get().string);
    }
}
