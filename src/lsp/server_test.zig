// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Drives the language server with JSON-RPC messages.

const std = @import("std");
const testing = std.testing;
const server_mod = @import("server.zig");
const Server = server_mod.Server;

const gpa = testing.allocator;

const Client = struct {
    out: std.Io.Writer.Allocating,
    server: Server,
    arena: std.heap.ArenaAllocator,
    next_id: i64 = 1,

    fn init(c: *Client) void {
        c.out = .init(gpa);
        c.server = .init(gpa, testing.io, &c.out.writer);
        c.arena = .init(gpa);
    }

    fn deinit(c: *Client) void {
        c.server.deinit();
        c.out.deinit();
        c.arena.deinit();
    }

    /// Sends a message and returns the messages the server wrote.
    fn send(c: *Client, method: []const u8, params: anytype, is_request: bool) ![]std.json.Value {
        const a = c.arena.allocator();
        var body: std.Io.Writer.Allocating = .init(a);
        var js: std.json.Stringify = .{ .writer = &body.writer };
        try js.beginObject();
        try js.objectField("jsonrpc");
        try js.write("2.0");
        if (is_request) {
            try js.objectField("id");
            try js.write(c.next_id);
            c.next_id += 1;
        }
        try js.objectField("method");
        try js.write(method);
        try js.objectField("params");
        try js.write(params);
        try js.endObject();
        c.out.clearRetainingCapacity();
        try c.server.handle(body.written());
        // Split the output into messages.
        var reader: std.Io.Reader = .fixed(try a.dupe(u8, c.out.written()));
        var messages: std.ArrayList(std.json.Value) = .empty;
        while (try Server.readMessage(a, &reader)) |msg| {
            try messages.append(a, try std.json.parseFromSliceLeaky(std.json.Value, a, msg, .{}));
        }
        return messages.items;
    }

    fn request(c: *Client, method: []const u8, params: anytype) !std.json.Value {
        const msgs = try c.send(method, params, true);
        try testing.expectEqual(@as(usize, 1), msgs.len);
        return msgs[0].object.get("result") orelse {
            std.debug.print("error response: {f}\n", .{std.json.fmt(msgs[0], .{})});
            return error.TestUnexpectedResult;
        };
    }
};

const uri = "file:///tmp/zigulee%20lsp/app.zge";

fn pos(line: u32, character: u32) struct { textDocument: struct { uri: []const u8 }, position: struct { line: u32, character: u32 } } {
    return .{ .textDocument = .{ .uri = uri }, .position = .{ .line = line, .character = character } };
}

fn str(v: std.json.Value, path: []const []const u8) []const u8 {
    var x = v;
    for (path) |k| x = x.object.get(k).?;
    return x.string;
}

fn int(v: std.json.Value, path: []const []const u8) i64 {
    var x = v;
    for (path) |k| x = x.object.get(k).?;
    return x.integer;
}

const source =
    \\component Button inherits Rectangle {
    \\    var in <string> label;
    \\    callback clicked();
    \\    t := Text { text: root.label; }
    \\}
    \\export component App inherits Window {
    \\    b := Button { label: "x"; clicked => { debug(b.label); } }
    \\    Text { text: b.label; }
    \\}
    \\
;

test "language server: a session" {
    var c: Client = undefined;
    c.init();
    defer c.deinit();

    const init_result = try c.request("initialize", .{ .capabilities = .{ .general = .{ .positionEncodings = .{ "utf-16", "utf-8" } } } });
    try testing.expectEqualStrings("utf-8", str(init_result, &.{ "capabilities", "positionEncoding" }));
    _ = try c.send("initialized", .{}, false);

    // An error is reported where it is.
    var msgs = try c.send("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zge", .version = 1, .text = "component A inherits Rectangle { background: 1; }" } }, false);
    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expectEqualStrings("textDocument/publishDiagnostics", str(msgs[0], &.{"method"}));
    const diags = msgs[0].object.get("params").?.object.get("diagnostics").?.array.items;
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(@as(i64, 45), int(diags[0], &.{ "range", "start", "character" }));

    // Fixed: no diagnostics.
    msgs = try c.send("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = .{.{ .text = source }} }, false);
    try testing.expectEqual(@as(usize, 0), msgs[0].object.get("params").?.object.get("diagnostics").?.array.items.len);

    // Hover over `label` in `b.label` (line 7).
    const hover = try c.request("textDocument/hover", pos(7, 19));
    try testing.expectEqualStrings("```zge\nvar in <string> label (Button)\n```", str(hover, &.{ "contents", "value" }));

    // Its definition, on line 1.
    const def = try c.request("textDocument/definition", pos(7, 19));
    try testing.expectEqualStrings(uri, str(def, &.{"uri"}));
    try testing.expectEqual(@as(i64, 1), int(def, &.{ "range", "start", "line" }));
    try testing.expectEqual(@as(i64, 20), int(def, &.{ "range", "start", "character" }));

    // References, without and with the declaration.
    const refs = try c.request("textDocument/references", .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 7, .character = 19 }, .context = .{ .includeDeclaration = false } });
    try testing.expectEqual(@as(usize, 4), refs.array.items.len);

    // Rename `label` everywhere.
    const prep = try c.request("textDocument/prepareRename", pos(7, 19));
    try testing.expectEqualStrings("label", str(prep, &.{"placeholder"}));
    const edit = try c.request("textDocument/rename", .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 7, .character = 19 }, .newName = "caption" });
    try testing.expectEqual(@as(usize, 5), edit.object.get("changes").?.object.get(uri).?.array.items.len);
    // Built-in names cannot be renamed.
    try testing.expect((try c.request("textDocument/prepareRename", pos(3, 12))) == .null);

    // Formatting: the source is already formatted.
    const fmt = try c.request("textDocument/formatting", .{ .textDocument = .{ .uri = uri }, .options = .{ .tabSize = 4, .insertSpaces = true } });
    try testing.expectEqual(@as(usize, 0), fmt.array.items.len);

    // Outline.
    const symbols = try c.request("textDocument/documentSymbol", .{ .textDocument = .{ .uri = uri } });
    try testing.expectEqual(@as(usize, 2), symbols.array.items.len);
    try testing.expectEqualStrings("Button", str(symbols.array.items[0], &.{"name"}));
    const children = symbols.array.items[0].object.get("children").?.array.items;
    try testing.expectEqualStrings("label", str(children[0], &.{"name"}));
    try testing.expectEqualStrings("t", str(children[2], &.{"name"}));

    // Shutting down.
    try testing.expect((try c.request("shutdown", .{})) == .null);
    _ = try c.send("exit", .{}, false);
    try testing.expect(c.server.exited);
    try testing.expectEqual(@as(u8, 0), c.server.exitCode());
}

fn labels(items: std.json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items.array.items) |it| try out.append(testing.allocator, str(it, &.{"label"}));
    return out.toOwnedSlice(testing.allocator);
}

fn expectLabel(list: []const []const u8, label: []const u8) !void {
    for (list) |l| if (std.mem.eql(u8, l, label)) return;
    std.debug.print("missing completion '{s}'\n", .{label});
    return error.TestUnexpectedResult;
}

test "language server: completion" {
    var c: Client = undefined;
    c.init();
    defer c.deinit();
    _ = try c.request("initialize", .{ .capabilities = .{} });
    _ = try c.send("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zge", .version = 1, .text = source } }, false);

    // Typing `b.` in a handler: the document no longer parses, the last
    // analysis is used.
    const typing = comptime source[0 .. std.mem.indexOf(u8, source, "debug(b.label)").? + "debug(b.".len] ++ "\n}\n}\n";
    _ = try c.send("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = .{.{ .text = typing }} }, false);
    const after_dot = try c.request("textDocument/completion", pos(6, 52));
    const members = try labels(after_dot);
    defer testing.allocator.free(members);
    try expectLabel(members, "label");
    try expectLabel(members, "clicked");
    try expectLabel(members, "background"); // from Rectangle

    // At the start of a member in App: properties, elements, keywords.
    const at_start = comptime source[0..std.mem.indexOf(u8, source, "    Text { text: b.label").?] ++ "    \n}\n";
    _ = try c.send("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = 3 }, .contentChanges = .{.{ .text = at_start }} }, false);
    const start_items = try labels(try c.request("textDocument/completion", pos(7, 4)));
    defer testing.allocator.free(start_items);
    try expectLabel(start_items, "title"); // Window's
    try expectLabel(start_items, "Button");
    try expectLabel(start_items, "Rectangle");
    try expectLabel(start_items, "var in-out");

    // `Key.` in a handler.
    const ctx = try server_mod.completionContext(c.arena.allocator(), "component A { FocusScope { key-pressed(e) => { if e.text == Key.", 64);
    try testing.expectEqualStrings("Key", ctx.object.?);
    try testing.expect(ctx.in_code);

    // `anchors.` at the start of a member.
    const actx = try server_mod.completionContext(c.arena.allocator(), "component A { Rectangle { anchors.", 34);
    try testing.expectEqualStrings("anchors", actx.object.?);
    var anchor_items: std.ArrayList(Server.Item) = .empty;
    try server_mod.collectCompletions(c.arena.allocator(), null, actx, &anchor_items);
    try testing.expectEqualStrings("left", anchor_items.items[0].label);
    try testing.expectEqual(@as(usize, 15), anchor_items.items.len);
}

test "positions in UTF-16 and UTF-8, URIs" {
    const text = "aé😀b\nx";
    try testing.expectEqual(Server.Position{ .line = 0, .character = 4 }, Server.positionOf(.utf16, text, 7)); // before b
    try testing.expectEqual(Server.Position{ .line = 0, .character = 7 }, Server.positionOf(.utf8, text, 7));
    try testing.expectEqual(@as(u32, 7), Server.offsetOf(.utf16, text, .{ .line = 0, .character = 4 }));
    try testing.expectEqual(@as(u32, 9), Server.offsetOf(.utf16, text, .{ .line = 1, .character = 0 }));
    try testing.expectEqual(@as(u32, 8), Server.offsetOf(.utf8, text, .{ .line = 0, .character = 99 })); // clamped

    const win = try server_mod.uriToPath(gpa, "file:///C:/x/y.zge");
    defer gpa.free(win);
    // On Windows, paths are spelled as std.fs.path spells them.
    if (@import("builtin").os.tag == .windows) {
        try testing.expectEqualStrings("C:\\x\\y.zge", win);
        return;
    }
    try testing.expectEqualStrings("C:/x/y.zge", win);
    const path = try server_mod.uriToPath(gpa, "file:///tmp/a%20b/c.zge");
    defer gpa.free(path);
    try testing.expectEqualStrings("/tmp/a b/c.zge", path);
    const back = try server_mod.pathToUri(gpa, path);
    defer gpa.free(back);
    try testing.expectEqualStrings("file:///tmp/a%20b/c.zge", back);
}

const preview_source =
    \\export component App inherits Window {
    \\    width: 100px;
    \\    height: 60px;
    \\    var in-out <int> count;
    \\    background: count > 0 ? #00ff00 : #ff0000;
    \\    b := Rectangle {
    \\        x: 10px;
    \\        y: 10px;
    \\        width: 30px;
    \\        height: 20px;
    \\        background: blue;
    \\        TouchArea { clicked => { count += 1; } }
    \\    }
    \\}
    \\
;

/// The preview frame among the messages.
fn frameOf(msgs: []const std.json.Value) ?std.json.Value {
    for (msgs) |m| if (m.object.get("method")) |method| if (std.mem.eql(u8, method.string, "zigulee/previewFrame")) return m.object.get("params").?;
    return null;
}

/// The pixel at physical (x, y) of the window, from the frame's patch that
/// covers it.
fn framePixel(frame: std.json.Value, abs_x: u32, abs_y: u32) ![4]u8 {
    const patch = for (frame.object.get("patches").?.array.items) |p| {
        const px: u32 = @intCast(int(p, &.{"x"}));
        const py: u32 = @intCast(int(p, &.{"y"}));
        if (abs_x >= px and abs_y >= py and abs_x < px + @as(u32, @intCast(int(p, &.{"w"}))) and abs_y < py + @as(u32, @intCast(int(p, &.{"h"})))) break p;
    } else return error.NotInFrame;
    const x = abs_x - @as(u32, @intCast(int(patch, &.{"x"})));
    const y = abs_y - @as(u32, @intCast(int(patch, &.{"y"})));
    const b64 = patch.object.get("png").?.string;
    const decoder = std.base64.standard.Decoder;
    const bytes = try gpa.alloc(u8, try decoder.calcSizeForSlice(b64));
    defer gpa.free(bytes);
    try decoder.decode(bytes, b64);
    var img = try @import("zigulee").core.png.decode(gpa, bytes);
    defer img.deinit(gpa);
    const p = img.pixels[y * img.width + x];
    return .{ p.r, p.g, p.b, p.a };
}

test "live preview: frames, input, editing, inspection" {
    var c: Client = undefined;
    c.init();
    defer c.deinit();
    _ = try c.request("initialize", .{ .capabilities = .{} });
    _ = try c.send("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zge", .version = 1, .text = preview_source } }, false);

    // Starting the preview answers with the components, then sends a full
    // frame at the requested scale.
    var msgs = try c.send("zigulee/preview", .{ .uri = uri, .scale = 2 }, true);
    try testing.expectEqualStrings("App", str(msgs[0].object.get("result").?, &.{"component"}));
    var frame = frameOf(msgs).?;
    const first = frame.object.get("patches").?.array.items[0];
    try testing.expectEqual(@as(i64, 200), int(first, &.{"w"}));
    try testing.expectEqual(@as(i64, 120), int(first, &.{"h"}));
    try testing.expectEqual([4]u8{ 0xff, 0, 0, 0xff }, try framePixel(frame, 2, 2)); // red
    try testing.expectEqual([4]u8{ 0, 0, 0xff, 0xff }, try framePixel(frame, 30, 30)); // the blue rectangle

    // A click on the rectangle: the background turns green.
    _ = try c.send("zigulee/previewInput", .{ .type = "press", .x = 20, .y = 15 }, false);
    msgs = try c.send("zigulee/previewInput", .{ .type = "release", .x = 20, .y = 15 }, false);
    frame = frameOf(msgs).?;
    try testing.expect(frame.object.get("patches").?.array.items.len > 0);

    // Editing the document re-runs the preview, keeping `count`.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, preview_source);
    const at = std.mem.indexOf(u8, text.items, "blue").?;
    try text.replaceRange(gpa, at, 4, "white");
    msgs = try c.send("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = .{.{ .text = text.items }} }, false);
    frame = frameOf(msgs).?;
    try testing.expectEqual([4]u8{ 0, 0xff, 0, 0xff }, try framePixel(frame, 2, 2)); // still green: count kept
    try testing.expectEqual([4]u8{ 0xff, 0xff, 0xff, 0xff }, try framePixel(frame, 30, 30));

    // Errors: reported, and the last good version keeps running.
    msgs = try c.send("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = 3 }, .contentChanges = .{.{ .text = "export component App inherits Window { background: 1; }" }} }, false);
    frame = frameOf(msgs).?;
    try testing.expect(std.mem.indexOf(u8, str(frame, &.{"errors"}), "error:") != null);
    _ = try c.send("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = 4 }, .contentChanges = .{.{ .text = text.items }} }, false);

    // Alt+click inspection: the rectangle, its location and properties.
    msgs = try c.send("zigulee/previewInspect", .{ .x = 20, .y = 15 }, true);
    try testing.expect(frameOf(msgs) != null); // with the highlight
    const inspected = msgs[0].object.get("result").?;
    try testing.expectEqualStrings("b := Rectangle", str(inspected, &.{ "selected", "label" }));
    try testing.expectEqual(@as(i64, 5), int(inspected, &.{ "selected", "range", "start", "line" }));
    var bg_value: []const u8 = "";
    for (inspected.object.get("properties").?.array.items) |p| {
        if (std.mem.eql(u8, str(p, &.{"name"}), "background")) bg_value = str(p, &.{"value"});
    }
    try testing.expectEqualStrings("#ffffffff", bg_value);

    // Setting a property live.
    msgs = try c.send("zigulee/previewSetProperty", .{ .name = "background", .value = "#000000" }, true);
    try testing.expect(msgs[0].object.get("result").?.object.get("error").? == .null);
    frame = frameOf(msgs).?;
    // Inside the rectangle (the highlight tints it a little).
    const px = try framePixel(frame, 40, 30);
    try testing.expect(px[0] < 0x20 and px[1] < 0x30);
    // The response carries the edit that writes it into the source: the
    // binding's value is replaced.
    const edit = msgs[0].object.get("result").?.object.get("edit").?;
    const changes = edit.object.get("changes").?.object.get(uri).?.array.items;
    try testing.expectEqualStrings("#000000", str(changes[0], &.{"newText"}));
    try testing.expectEqual(@as(i64, 10), int(changes[0], &.{ "range", "start", "line" }));
    try testing.expectEqual(@as(i64, 20), int(changes[0], &.{ "range", "start", "character" }));
    // A property without a binding gets one, on a new line.
    msgs = try c.send("zigulee/previewSetProperty", .{ .name = "opacity", .value = "0.5" }, true);
    const added = msgs[0].object.get("result").?.object.get("edit").?.object.get("changes").?.object.get(uri).?.array.items[0];
    try testing.expectEqualStrings("\n        opacity: 0.5;", str(added, &.{"newText"}));
    try testing.expectEqual(@as(i64, 5), int(added, &.{ "range", "start", "line" }));
    msgs = try c.send("zigulee/previewSetProperty", .{ .name = "width", .value = "\"wide\"" }, true);
    try testing.expectEqualStrings("expected a length", str(msgs[0].object.get("result").?, &.{"error"}));

    // The editor cursor selects the element under it.
    msgs = try c.send("zigulee/previewSelect", .{ .uri = uri, .position = .{ .line = 11, .character = 10 } }, false);
    var selection: ?std.json.Value = null;
    for (msgs) |m| if (m.object.get("method")) |method| if (std.mem.eql(u8, method.string, "zigulee/previewSelection")) {
        selection = m.object.get("params").?;
    };
    try testing.expectEqualStrings("TouchArea", str(selection.?, &.{ "selected", "label" }));

    _ = try c.send("zigulee/previewClose", .{}, false);
    try testing.expect(c.server.preview == null);
}

/// A workspace in a temporary directory: its absolute path.
fn tmpWorkspace(tmp: *std.testing.TmpDir, a: std.mem.Allocator) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    return a.dupe(u8, buf[0..n]);
}

test "go to definition into the standard widgets" {
    var c: Client = undefined;
    c.init();
    defer c.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = c.arena.allocator();
    const root = try tmpWorkspace(&tmp, a);
    c.server.std_dir = try std.fs.path.join(a, &.{ root, "std-cache" });
    _ = try c.request("initialize", .{ .capabilities = .{} });

    const app_uri = try server_mod.pathToUri(a, try std.fs.path.join(a, &.{ root, "app.zge" }));
    const text =
        \\import { Button } from "std-widgets.zge";
        \\export component App inherits Window { Button { text: "ok"; } }
        \\
    ;
    _ = try c.send("textDocument/didOpen", .{ .textDocument = .{ .uri = app_uri, .languageId = "zge", .version = 1, .text = text } }, false);
    const def = try c.request("textDocument/definition", .{ .textDocument = .{ .uri = app_uri }, .position = .{ .line = 1, .character = 42 } });
    const target = str(def, &.{"uri"});
    try testing.expect(std.mem.endsWith(u8, target, "/std-cache/fluent/button.zge"));
    // The file exists, with the widget's source, and the range points at
    // `Button` in `export component Button`.
    const path = try server_mod.uriToPath(a, target);
    const widget = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, widget, "export component Button") != null);
    const line: usize = @intCast(int(def, &.{ "range", "start", "line" }));
    var lines = std.mem.splitScalar(u8, widget, '\n');
    for (0..line) |_| _ = lines.next();
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "component Button") != null);
    // Built-in names cannot be renamed.
    try testing.expect((try c.request("textDocument/prepareRename", .{ .textDocument = .{ .uri = app_uri }, .position = .{ .line = 1, .character = 42 } })) == .null);
}

test "rename and references across the workspace" {
    var c: Client = undefined;
    c.init();
    defer c.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = c.arena.allocator();
    const root = try tmpWorkspace(&tmp, a);
    // lib.zge declares Badge; app.zge (not open) and ui/screen.zge use it.
    const lib =
        \\export component Badge inherits Rectangle {
        \\    var in <string> label;
        \\    Text { text: root.label; }
        \\}
        \\
    ;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib.zge", .data = lib });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app.zge", .data =
        \\import { Badge } from "lib.zge";
        \\export component App inherits Window { Badge { label: "new"; } }
        \\
    });
    try tmp.dir.createDirPath(testing.io, "ui");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ui/screen.zge", .data =
        \\import { Badge } from "../lib.zge";
        \\export component Screen inherits Window { b := Badge { label: "x"; } Text { text: b.label; } }
        \\
    });
    // A build directory is not part of the workspace.
    try tmp.dir.createDirPath(testing.io, "zig-out");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zig-out/copy.zge", .data = "import { Badge } from \"../lib.zge\"; export component C { Badge { label: \"\"; } }" });

    _ = try c.request("initialize", .{ .capabilities = .{}, .workspaceFolders = .{.{ .uri = try server_mod.pathToUri(a, root), .name = "w" }} });
    const lib_uri = try server_mod.pathToUri(a, try std.fs.path.join(a, &.{ root, "lib.zge" }));
    _ = try c.send("textDocument/didOpen", .{ .textDocument = .{ .uri = lib_uri, .languageId = "zge", .version = 1, .text = lib } }, false);

    // `label` on line 1 of lib.zge.
    const at = .{ .textDocument = .{ .uri = lib_uri }, .position = .{ .line = 1, .character = 21 } };
    const refs = try c.request("textDocument/references", .{ .textDocument = .{ .uri = lib_uri }, .position = .{ .line = 1, .character = 21 }, .context = .{ .includeDeclaration = true } });
    // The declaration, root.label, app's binding, screen's binding and b.label.
    try testing.expectEqual(@as(usize, 5), refs.array.items.len);

    const edit = try c.request("textDocument/rename", .{ .textDocument = at.textDocument, .position = at.position, .newName = "caption" });
    const changes = edit.object.get("changes").?.object;
    try testing.expectEqual(@as(usize, 3), changes.count());
    var total: usize = 0;
    var it = changes.iterator();
    while (it.next()) |e| {
        try testing.expect(std.mem.indexOf(u8, e.key_ptr.*, "zig-out") == null);
        total += e.value_ptr.array.items.len;
    }
    try testing.expectEqual(@as(usize, 5), total);
    const screen_uri = try server_mod.pathToUri(a, try std.fs.path.join(a, &.{ root, "ui", "screen.zge" }));
    try testing.expectEqual(@as(usize, 2), changes.get(screen_uri).?.array.items.len);
}
