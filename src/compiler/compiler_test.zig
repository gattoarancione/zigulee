// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const compiler = @import("compiler.zig");

/// In-memory files for imports: alternating path, contents.
const MemFiles = struct {
    files: []const [2][]const u8,

    fn read(ctx: ?*anyopaque, arena: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
        const self: *const MemFiles = @ptrCast(@alignCast(ctx.?));
        for (self.files) |f| if (std.mem.eql(u8, f[0], path)) return arena.dupe(u8, f[1]);
        return error.FileNotFound;
    }
};

var mem_files: MemFiles = .{ .files = &.{} };

fn compileErrors(source: []const u8) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    errdefer arena.deinit();
    const r = try compiler.compile(arena.allocator(), "t.zge", source, .{ .loader = .{ .ctx = &mem_files, .readFn = MemFiles.read } });
    const text = switch (r) {
        .errors => |e| try testing.allocator.dupe(u8, e),
        .zig => |z| {
            std.debug.print("unexpectedly compiled:\n{s}\n", .{z});
            return error.TestUnexpectedResult;
        },
    };
    arena.deinit();
    return text;
}

fn expectError(source: []const u8, expected: []const u8) !void {
    const text = try compileErrors(source);
    defer testing.allocator.free(text);
    if (std.mem.indexOf(u8, text, expected) == null) {
        std.debug.print("expected an error containing:\n  {s}\ngot:\n{s}\n", .{ expected, text });
        return error.TestUnexpectedResult;
    }
}

test "semantic errors" {
    try expectError("component A { foo: 1; }", "t.zge:1:15: error: 'Empty' has no property 'foo'");
    try expectError("component A inherits Rectangle { width: 10; }", "expected a length: add a unit, like 10px");
    try expectError("component A inherits Rectangle { background: 5px; }", "expected brush, found length");
    try expectError("component A { Blah {} }", "unknown element type 'Blah'");
    try expectError("component A { a := Rectangle {} a := Text {} }", "duplicate id 'a'");
    try expectError("component A { TouchArea { pressed: true; } }", "cannot set 'pressed': it is an output of the element");
    try expectError("component A { var in <int> n: 1px; }", "expected int, found length");
    try expectError("component A { var <wat> n; }", "unknown type 'wat'");
    try expectError("component A { HorizontalLayout { Rectangle { x: 5px; } } }", "'x' is set by the layout");
    try expectError("component A inherits Text { text: missing; }", "unknown name 'missing'");
    try expectError("component A { Path { Rectangle {} } }", "'Path' cannot have child elements");
    try expectError("component A { B {} } component B { A {} }", "contains itself");
    try expectError("component A inherits Rectangle { width: 50%; }", "percentages are only allowed for width and height");
    try expectError("component B { var out <int> o; } component A { B { o: 1; } }", "cannot set 'o': it is an output property");
    try expectError("component A inherits Text { text: \"\\{1 + true}\"; }", "cannot apply '+' to int and bool");
}

test "anchors: errors" {
    try expectError("component A inherits Rectangle { anchors.fill: parent; }", "a component's root element has nothing to anchor to");
    try expectError("component A { HorizontalLayout { Rectangle { anchors.left: parent.left; } } }", "anchors don't work in a HorizontalLayout");
    try expectError("component A { Rectangle { anchors.left: parent.top; } }", "anchors.left needs a left, right or horizontal-center edge");
    try expectError("component A { Rectangle { anchors.left: parent.middle; } }", "'middle' is not an edge");
    try expectError("component A { Rectangle { anchors.left: 5px; } }", "expected an edge, like parent.left");
    try expectError("component A { Rectangle { anchors.fill: parent.left; } }", "expected an element: parent or a sibling's id");
    try expectError("component A { a := Rectangle { Rectangle { anchors.left: a.right; } } }", "'a' is neither");
    try expectError("component A { a := Rectangle { anchors.left: a.right; } }", "can't be anchored to itself");
    try expectError("component A { Rectangle { x: 4px; anchors.left: parent.left; } }", "'x' is set by the element's anchors");
    try expectError("component A { Rectangle { anchors.left: parent.left; anchors.horizontal-center: parent.horizontal-center; } }", "can't go with anchors.left or anchors.right");
    try expectError("component A { Rectangle { anchors.middle: parent.left; } }", "unknown anchor 'anchors.middle'");
}

test "for and if errors" {
    try expectError("component A { for x in \"text\" : Rectangle {} }", "'for' needs a model or an int, found string");
    try expectError("component A { if 5 : Rectangle {} }", "expected bool, found int");
    try expectError("component A { for x in 3 : Rectangle { background: x; } }", "expected brush, found int");
    try expectError("component A { for x in 3 : Rectangle { var <int> p; } }", "properties can only be declared at the top of a component");
    try expectError("component A { var in <[wat]> m; }", "unknown type 'wat'");
    try expectError("component A inherits Text { var in <int> n; text: n[0]; }", "only models can be indexed, found int");
    try expectError("component A { Path { for x in 2 : Rectangle {} } }", "'Path' cannot have child elements");
    // Ids inside a template are local to it.
    try expectError("component A { for x in 2 : r := Rectangle {} Text { text: r.width; } }", "unknown name 'r'");
}

test "types, states, grids and images: errors" {
    try expectError("struct P { x: int } component A { var in <P> p: { y: 1 }; }", "P has no field 'y'");
    try expectError("struct P { x: int } component A { var in <P> p: { x: \"s\" }; }", "expected int, found string");
    try expectError("enum M { a, b } component A { var in <M> m: M.c; }", "M has no value 'c'");
    try expectError("enum M { a } enum M { b } component A {}", "'M' is already defined");
    try expectError("struct S { s: S } component A {}", "a struct cannot contain itself");
    try expectError("component A { var in <int> n: { x: 1 }; }", "expected int, found a struct");
    try expectError("component A inherits Rectangle { states [ s when 1 : { background: red; } ] }", "expected bool, found int");
    try expectError("component A inherits Rectangle { states [ s when true : { nope: red; } ] }", "'Rectangle' has no property 'nope'");
    try expectError("component A { GridLayout { Rectangle { row: 1px; } } }", "expected int, found length");
    try expectError("component A { var in <int> r; GridLayout { Rectangle { row: r; } } }", "'row' must be a constant");
    try expectError("component A { Image { source: @image-url(\"missing.png\"); } }", "cannot read image 'missing.png'");
    try expectError("component W inherits Window {} component A { Loader { source: W; } }", "'W' is a window: it cannot be shown in a Loader");
    try expectError("component A { Loader { source: 5; } }", "expected component, found int");
    try expectError("component A { Loader { Rectangle {} } }", "'Loader' cannot have child elements");
    try expectError("component A { Loader { loaded: true; } }", "loaded");
    try expectError("component A { var out <[int]> m: [1].filter(2); }", "filter takes a function of a row");
    try expectError("component A { var out <[int]> m: [1].reverse(1); }", "reverse takes nothing");
    try expectError("component A { var out <[int]> m: [1].map(x => x > 0 ? TextWrap.word-wrap : TextWrap.no-wrap); }", "a model of TextWrap cannot be made");
    try expectError("struct P { a: int } component A { var in <[P]> ps; var out <[P]> m: ps.sort(p => p); }", "rows are sorted by a number, a bool or a string, not a P");
    try expectError("component A { var out <int> m: x => x; }", "expected");
    try expectError("component A { var out <int> m: max(x => x, 1); }", "a function of a row goes in a model's filter or sort");
    try expectError("component A { var out <[int]> m: [1].filter(x => x); }", "expected bool, found int");
    try expectError("component A { PropertyAnimation { to: 1; } }", "PropertyAnimation needs a 'target'");
    try expectError("component A { r := Rectangle {} PropertyAnimation { target: r.x; } }", "PropertyAnimation needs 'to'");
    try expectError("component A { t := Text {} PropertyAnimation { target: t.text; to: \"x\"; } }", "a string cannot be animated");
    try expectError("component A { r := Rectangle {} PropertyAnimation { target: r; to: 1; } }", "a PropertyAnimation's target is a property");
    try expectError("component A { SequentialAnimation { Rectangle {} } }", "only animations go in a SequentialAnimation");
    try expectError("component A { r := Rectangle {} PropertyAnimation { target: r.x; to: 1px; easing: spring(); } }", "spring takes 1 number");
    try expectError("component A { Connections { clicked => { } } }", "Connections needs a 'target'");
    try expectError("component A { t := TouchArea { } Connections { target: t; tapped => { } } }", "'TouchArea' has no callback 'tapped'");
    try expectError("component A { Connections { target: 5; clicked => { } } }", "a connection's target is an element (its id, root, parent) or a global");
    try expectError("component A { t := TouchArea { } t.clicked: 1; }", "only handlers name another element's member");
    try expectError("component A { t := TouchArea { } t.pressed => { } }", "'pressed' is not a callback");
    try expectError("component A { t := TouchArea { } t.clicked => { return 1; } }", "this callback returns nothing");
    try expectError("component A { callback c(); c => { break; } }", "'break' outside a loop");
    try expectError("component A { callback c(int); c(n) => { n = 2; } }", "cannot assign to 'n': only properties and 'let' variables can be assigned");
    try expectError("component A { callback c(); c => { for k in 3 { k = 1; } } }", "cannot assign to 'k'");
    try expectError("component A { callback c(); c => { for k[i] in 3 { } } }", "a count has no index");
    try expectError("component A { callback c(); c => { for k in \"abc\" { } } }", "'for' goes over a model or a count, not a string");
    try expectError("component A { callback c(); c => { let x = 1; x = \"a\"; } }", "expected int, found string");
    try expectError("component A { callback c(); c => { if true { let total = 1; } total = 2; } }", "total");
    try expectError("component A { callback c(); c => { for k of 3 { } } }", "expected 'in'");
    try expectError("component A { Image { source: @image-url(\"x.png\", nine-slice(1 2 3)); } }", "nine-slice takes 1, 2 or 4 numbers");
    try expectError("component A { Image { source: @image-url(\"x.png\", nine-slice(1.5)); } }", "expected a whole number of pixels, found '1.5'");
    try expectError("component A { Image { source: @image-url(\"x.png\", slices(1)); } }", "expected 'nine-slice', found 'slices'");
    try expectError("component A { AnimatedImage { frame-count: 3; } }", "frame-count");
    try expectError("component A { Image { source: @image-urls(\"x\"); } }", "unknown '@image-urls' (expected @image-url, @audio-url, @video-url, @model-url, @linear-gradient, @radial-gradient or @tr)");
    try expectError("component A { Video { source: @video-url(\"missing.mp4\"); } }", "cannot read video 'missing.mp4'");
    try expectError("component A { View3D { Model { source: @model-url(\"missing.glb\"); } } }", "cannot read model 'missing.glb'");
    try expectError("component A { Video { Rectangle {} } }", "'Video' cannot have child elements");
    try expectError("component A { Video { duration: 1s; } }", "duration");
    try expectError("component A { Audio { source: @audio-url(\"missing.wav\"); } }", "cannot read audio 'missing.wav'");
    try expectError("component A { Audio { Rectangle {} } }", "'Audio' cannot have child elements");
    try expectError("component A { Audio { duration: 1s; } }", "duration");
    try expectError("component A { var <string> s: @tr(name); }", "expected the text to translate (a string), found name");
    try expectError("component A { var <int> x; var <string> s: @tr(\"a \\{x}\"); }", "the text to translate cannot contain \\{...}: use {} and pass the value after it");
    try expectError("component A { var <string> s: @tr(\"{n} a\" | \"{n} b\" % \"x\"); }", "the count must be an int, found string");
    try expectError("component A { var <string> s: @tr(\"{n} a\" | \"{n} b\"); }", "expected '%'");
    try expectError("component A { var <string> s: @tr(\"{}\", #fff); }", "a color cannot be shown in a string");
    try expectError("component A { changed nope => { } }", "'Empty' has no property 'nope'");
    try expectError("component A { TextInput { has-focus: true; } }", "cannot set 'has-focus': it is an output of the element");
    try expectError("component A { Timer { Rectangle {} } }", "'Timer' cannot have child elements");
}

test "imports and globals: errors" {
    mem_files = .{ .files = &.{
        .{ "lib.zge", "export component Shown {} component Hidden {} export global G { var in <int> a; var out <int> b; var <int> c; }" },
        .{ "bad.zge", "component {" },
        .{ "dir/inner.zge", "import { Shown } from \"../lib.zge\";" },
    } };
    defer mem_files = .{ .files = &.{} };
    try expectError("import { X } from \"missing.zge\"; component A {}", "cannot read 'missing.zge'");
    try expectError("import { Nope } from \"lib.zge\"; component A {}", "'Nope' is not defined in 'lib.zge'");
    try expectError("import { Hidden } from \"lib.zge\"; component A {}", "'Hidden' is not exported from 'lib.zge'");
    // Errors inside an imported file name that file.
    try expectError("import { X } from \"bad.zge\"; component A {}", "bad.zge:1:11: error: expected a name");
    try expectError("import { G } from \"lib.zge\"; component A inherits Text { text: G.c; }", "'c' is private to G");
    try expectError("import { G } from \"lib.zge\"; component A { go => { G.b = 1; } callback go(); }", "cannot assign to this property: it is an output property");
    try expectError("import { G } from \"lib.zge\"; component A { G {} }", "'G' is a global, not an element");
    try expectError("global G2 { Rectangle {} } component A {}", "a global cannot contain elements");
}

test "a component in error: what uses it fails with it, the error said once" {
    // Inherited, and used (it has no elements).
    try expectError("component A inherits Nope {} component B inherits A {} export component C inherits Window { B {} A {} }", "unknown element type 'Nope'");
    // Wrong anchors in an imported file: that file still read, its
    // components known to the files importing it, the error said once.
    mem_files = .{ .files = &.{
        .{ "w.zge", "export component Centered inherits Text { anchors.horizontal-center: parent.left; } export component Pic inherits Image {}" },
        .{ "a.zge", "import { Centered, Pic } from \"w.zge\"; export component A inherits Rectangle { Centered {} Pic {} }" },
    } };
    defer mem_files = .{ .files = &.{} };
    const text = try compileErrors("import { Centered, Pic } from \"w.zge\"; import { A } from \"a.zge\"; export component B inherits Window { A {} Centered {} Pic {} }");
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "error:"));
    try testing.expect(std.mem.indexOf(u8, text, "w.zge:1:43: error: a component's root element has nothing to anchor to") != null);
}

test "multiple errors are reported together" {
    const text = try compileErrors("component A inherits Rectangle { background: 1; border-width: red; }");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "1:46") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1:63") != null);
}

fn compileOk(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    return switch (try compiler.compile(arena, "t.zge", source, .{ .loader = .{ .ctx = &mem_files, .readFn = MemFiles.read } })) {
        .zig => |z| z,
        .errors => |e| {
            std.debug.print("unexpected errors:\n{s}\n", .{e});
            return error.TestUnexpectedResult;
        },
    };
}

test "var declarations; property, the old spelling, says what to write" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = try compileOk(arena.allocator(), "export component A inherits Window { var in-out <int> count: 3; var out <bool> full: count > 9; var <[string]> rows; var in <length> in; Rectangle { width: in; } }");
    // Its modifiers checked.
    try expectError("component B { var out <int> o; } component A { B { o: 1; } }", "cannot set 'o': it is an output property");
    // Untyped vars come later.
    try expectError("component A { var count: 3; }", "a var needs its type for now");
    try expectError("component A { var in count; }", "a var needs its type for now");
    try expectError("component A { in-out property <int> count; }", "properties are declared with `var` now: `var in-out <type> name`");
    try expectError("component A { property <int> count; }", "properties are declared with `var` now: `var <type> name`");
    try expectError("component A { private property <int> count; }", "properties are declared with `var` now: `var <type> name`");
}

test "prefer-rendering-cache: on any element, kept in its transform" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const zig = try compileOk(arena.allocator(), "export component A inherits Window { var in <float> angle; Rectangle { rotation: angle; prefer-rendering-cache: true; Image {} } }");
    try testing.expect(std.mem.indexOf(u8, zig, "prefer_rendering_cache") != null);
    try expectError("component A { Rectangle { prefer-rendering-cache: 1px; } }", "expected bool, found length");
}

test "each file has its own names; re-exports" {
    mem_files = .{ .files = &.{
        .{ "a.zge", "component Box inherits Rectangle { background: red; } export component A { Box {} }" },
        .{ "b.zge", "component Box inherits Rectangle { background: blue; } export component B { Box {} } export struct P { x: int }" },
        .{ "all.zge", "export { A } from \"a.zge\"; export { B, P } from \"b.zge\"; import { A } from \"a.zge\"; export component C { A {} }" },
    } };
    defer mem_files = .{ .files = &.{} };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Three components named Box: the main file keeps the name, the others
    // get distinct Zig names.
    const zig = try compileOk(arena.allocator(), "import { A, B, C, P } from \"all.zge\"; component Box {} export component Main { A {} B {} C {} Box {} var <P> p; }");
    try testing.expect(std.mem.indexOf(u8, zig, "const Box = struct") != null);
    try testing.expect(std.mem.indexOf(u8, zig, "const Box__1 = struct") != null);
    try testing.expect(std.mem.indexOf(u8, zig, "const Box__2 = struct") != null);
    // Imported names are not re-exported unless asked.
    try expectError("import { Box } from \"a.zge\"; component M {}", "'Box' is not exported from 'a.zge'");
    try expectError("import { C } from \"b.zge\"; component M {}", "'C' is not defined in 'b.zge'");
    // A local definition and an import cannot share a name.
    try expectError("import { A } from \"a.zge\"; component A {}", "'A' is already defined");
    // Names from another file are not visible without an import.
    try expectError("import { A } from \"a.zge\"; component M { Box {} }", "unknown element type 'Box'");
}

test "standard widgets and Key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = try compileOk(arena.allocator(),
        \\import { Button, Slider, Palette } from "std-widgets.zge";
        \\export component M inherits Window {
        \\    background: Palette.background;
        \\    FocusScope { key-pressed(e) => { return e.text == Key.Escape ? accept : reject; } }
        \\    Button { text: "ok"; }
        \\    Slider {}
        \\}
    );
    try expectError("import { Nope } from \"std-widgets.zge\"; component M {}", "'Nope' is not defined in 'std-widgets.zge'");
    try expectError("component M inherits Text { text: Key.Nope; }", "Key has no value 'Nope'");
    try expectError("component M inherits Text { text: Key; }", "'Key' is not a value");
}

test "the index records what names refer to" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\component Button inherits Rectangle {
        \\    var in <string> label;
        \\    callback clicked(int);
        \\    background: red;
        \\    t := Text { text: root.label; }
        \\}
        \\export component App inherits Window {
        \\    b := Button { label: "x"; clicked(n) => { debug(b.label); } }
        \\    Text { text: b.label; }
        \\}
    ;
    var ix: compiler.Index = .{ .arena = a };
    _ = try compileOk2(a, source, &ix);
    const at = struct {
        fn f(s: []const u8, needle: []const u8, nth: usize) u32 {
            var from: usize = 0;
            var i: usize = 0;
            while (true) : (i += 1) {
                const pos = std.mem.indexOfPos(u8, s, from, needle).?;
                if (i == nth) return @intCast(pos);
                from = pos + 1;
            }
        }
    }.f;

    // `label` in `b.label` (the second use in App) is the declared property.
    const ref = ix.referenceAt(0, at(source, "label", 4) + 1).?;
    const sym = ix.symbols.items[ref.symbol];
    try testing.expectEqual(compiler.index.Kind.property, sym.kind);
    try testing.expectEqualStrings("var in <string> label (Button)", sym.detail);
    try testing.expectEqual(at(source, "label", 0), sym.decl.?.span.start);
    // Its declaration, the binding, `root.label` and two `b.label`.
    const refs = try ix.referencesTo(a, ref.symbol);
    try testing.expectEqual(@as(usize, 5), refs.len);

    // Element types, built-in members and ids.
    const button = ix.symbols.items[ix.referenceAt(0, at(source, "Button {", 0)).?.symbol];
    try testing.expectEqualStrings("component Button inherits Rectangle", button.detail);
    try testing.expectEqual(at(source, "Button", 0), button.decl.?.span.start);
    const bg = ix.symbols.items[ix.referenceAt(0, at(source, "background", 0)).?.symbol];
    try testing.expectEqualStrings("var <brush> background (Rectangle)", bg.detail);
    const id = ix.symbols.items[ix.referenceAt(0, at(source, "b.label", 0)).?.symbol];
    try testing.expectEqualStrings("b := Button", id.detail);
    const cb = ix.symbols.items[ix.referenceAt(0, at(source, "clicked(n)", 0)).?.symbol];
    try testing.expectEqualStrings("callback clicked(int) (Button)", cb.detail);

    // Completion data: Button's members include Rectangle's.
    const members = ix.members.get("comp:Button").?;
    var names: std.ArrayList([]const u8) = .empty;
    for (members) |m| try names.append(a, m.name);
    for ([_][]const u8{ "label", "clicked", "background", "width" }) |n| {
        for (names.items) |have| {
            if (std.mem.eql(u8, have, n)) break;
        } else return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("b", ix.ids.get("comp:App").?[0].name);
    try testing.expectEqualStrings("comp:Button", ix.ids.get("comp:App").?[0].target.?);
}

fn compileOk2(arena: std.mem.Allocator, source: []const u8, ix: *compiler.Index) ![]const u8 {
    return switch (try compiler.compile(arena, "t.zge", source, .{ .index = ix })) {
        .zig => |z| z,
        .errors => |e| {
            std.debug.print("unexpected errors:\n{s}\n", .{e});
            return error.TestUnexpectedResult;
        },
    };
}

test "@children" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // In a nested component, a plain component and a built-in element.
    _ = try compileOk(arena.allocator(),
        \\component Inner inherits Rectangle { }
        \\component Frame inherits Rectangle { Inner { @children } }
        \\component Outer inherits Rectangle { VerticalLayout { Frame { @children } } }
        \\export component App inherits Window { Outer { Text {} } Frame { Rectangle {} } }
    );
    try expectError("component A { Empty { @children } @children }", "a component can have only one @children");
    try expectError("component A { Image { @children } }", "'Image' cannot have child elements");
    try expectError("component A { for i in 3 : Empty { @children } }", "@children cannot be inside 'for' or 'if'");
    try expectError("component A { GridLayout { @children } }", "@children cannot be in a GridLayout yet");
}

test "functions: errors" {
    try expectError("component A { function f() {} function f() {} }", "'f' is declared twice");
    try expectError("component A { Rectangle { function f() {} } }", "functions can only be declared at the top of a component");
    try expectError("component B { function hidden() {} } component A { b := B {} go => { b.hidden(); } callback go(); }", "'B' has no property or callback 'hidden'");
    try expectError("component A { function f(x: int) -> int { return x; } callback go(); go => { f(); } }", "expected 1 argument(s), found 0");
    try expectError("component A { function f(x: nope) {} }", "unknown type 'nope'");
    try expectError("component A { function t() {} t := Text {} }", "'t' is both a function and an element id");
    try expectError("component A { var <int> invoke-t; function t() {} }", "the Zig method 'invoke_t' of function 't' collides with a property");
}

test "ternaries with literal branches compile to typed values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const zig = try compileOk(arena.allocator(), "export component A { var in-out <int> n; var in <bool> up; callback go(); go => { n += up ? 1 : -1; } }");
    try testing.expect(std.mem.indexOf(u8, zig, "@as(i32, 1) else @as(i32, -(1))") != null);
}
