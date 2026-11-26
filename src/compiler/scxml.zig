// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! SCXML to `.zge` (`zgec scxml machine.scxml`): a W3C state chart as a
//! `StateMachine` in a `global` (its data model the global's properties),
//! for machines designed with SCXML tools.
//!
//! One to one: `<state>`, `<parallel>`, `<final>`, `<initial>`,
//! `<history>` (its parent keeps a history, targets name `parent.history`),
//! `<transition event cond target>` (one per event; `done.state.x` is
//! `done.x`; without an event, eventless), `<onentry>`, `<onexit>`,
//! `<raise>`, `<send>` to the machine itself (a delay in `<onentry>` becomes
//! an `after` of the state), `<cancel>` of such a send in `<onexit>` (an
//! `after` is cancelled by itself), `<assign>`, `<log>`, `<if>`. Conditions
//! and values written in a small ECMAScript subset are translated:
//! literals, data names (as `root.name`: the machine's own members would
//! hide them), operators, `In('state')`. Anything else is left
//! as a comment for the author to finish, with a warning; the output still
//! compiles.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const Node = xml.Node;

pub const Warning = struct { line: u32, message: []const u8 };

pub const Result = union(enum) {
    zge: struct { text: []const u8, warnings: []const Warning },
    /// The document could not be read: why, with its line.
    errors: []const u8,
};

/// Converts the SCXML document `source`; `file_name` names the global
/// when the document has no `name`.
pub fn convert(arena: Allocator, file_name: []const u8, source: []const u8) Allocator.Error!Result {
    var failure: xml.Failure = .{};
    const root = xml.parse(arena, source, &failure) catch |err| switch (err) {
        error.InvalidXml => return .{ .errors = try std.fmt.allocPrint(arena, "{s}:{d}: error: {s}\n", .{ file_name, failure.line, failure.message }) },
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (!std.mem.eql(u8, root.name, "scxml")) return .{ .errors = try std.fmt.allocPrint(arena, "{s}:{d}: error: expected <scxml>, found <{s}>\n", .{ file_name, root.line, root.name }) };
    var c: Conv = .{ .arena = arena };
    try c.collect(root, null);
    const raw = try c.emit(root, file_name);
    // Canonical spacing (the raw text is valid, only roughly indented).
    const text = @import("format.zig").format(arena, raw) catch raw;
    return .{ .zge = .{ .text = text, .warnings = c.warnings.items } };
}

/// The name of the machine in the global.
const machine = "machine";

const Conv = struct {
    arena: Allocator,
    warnings: std.ArrayList(Warning) = .empty,
    /// SCXML ids of states (and histories: `parent.history`) to `.zge`.
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    used: std.StringHashMapUnmanaged(void) = .empty,
    /// State nodes, to tell their kinds and parents.
    nodes: std.StringHashMapUnmanaged(*const Node) = .empty,
    parents: std.AutoHashMapUnmanaged(*const Node, *const Node) = .empty,
    /// Per state node: its name, and its history (from a `<history>`
    /// inside it).
    node_names: std.AutoHashMapUnmanaged(*const Node, []const u8) = .empty,
    histories: std.AutoHashMapUnmanaged(*const Node, bool) = .empty,
    events: std.ArrayList([]const u8) = .empty,
    data: std.ArrayList(Data) = .empty,
    data_names: std.StringHashMapUnmanaged([]const u8) = .empty,
    next_auto: u32 = 1,
    noted_send: bool = false,
    noted_after: bool = false,

    const Data = struct { name: []const u8, ty: []const u8, init: ?[]const u8 };

    fn warn(c: *Conv, line: u32, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try c.warnings.append(c.arena, .{ .line = line, .message = try std.fmt.allocPrint(c.arena, fmt, args) });
    }

    fn isState(n: *const Node) bool {
        return std.mem.eql(u8, n.name, "state") or std.mem.eql(u8, n.name, "parallel") or std.mem.eql(u8, n.name, "final");
    }

    /// `raw` as a `.zge` name: other characters as `_`, a letter first,
    /// not one taken already (`-2`, `-3`... after it).
    fn identifier(c: *Conv, raw: []const u8, prefix: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        if (raw.len == 0 or !(std.ascii.isAlphabetic(raw[0]) or raw[0] == '_')) try out.appendSlice(c.arena, prefix);
        for (raw, 0..) |ch, i| {
            const next_ok = i + 1 < raw.len and (std.ascii.isAlphabetic(raw[i + 1]) or raw[i + 1] == '_');
            try out.append(c.arena, if (std.ascii.isAlphanumeric(ch) or ch == '_' or (ch == '-' and next_ok and out.items.len > 0)) ch else '_');
        }
        return out.items;
    }

    fn unique(c: *Conv, base: []const u8) Allocator.Error![]const u8 {
        var name = base;
        var k: u32 = 2;
        while (c.used.contains(name) or isReserved(name)) : (k += 1) name = try std.fmt.allocPrint(c.arena, "{s}-n{d}", .{ base, k });
        try c.used.put(c.arena, name, {});
        return name;
    }

    fn isReserved(name: []const u8) bool {
        return std.mem.eql(u8, name, "history");
    }

    /// Names the states (and histories), hoists the data model.
    fn collect(c: *Conv, n: *const Node, parent: ?*const Node) Allocator.Error!void {
        if (parent) |p| try c.parents.put(c.arena, n, p);
        if (isState(n)) {
            const id = n.attr("id");
            const name = try c.unique(if (id) |i| try c.identifier(i, "s_") else try std.fmt.allocPrint(c.arena, "state-n{d}", .{c.next_auto}));
            if (id == null) c.next_auto += 1;
            if (id) |i| {
                try c.names.put(c.arena, i, name);
                try c.nodes.put(c.arena, i, n);
            }
            try c.node_names.put(c.arena, n, name);
        } else if (std.mem.eql(u8, n.name, "history")) {
            const p = parent orelse return;
            if (c.histories.contains(p)) {
                try c.warn(n.line, "a second <history> in a state: only the first is kept", .{});
            } else {
                const deep = if (n.attr("type")) |t| std.mem.eql(u8, t, "deep") else false;
                try c.histories.put(c.arena, p, deep);
            }
            if (n.attr("id")) |i| try c.names.put(c.arena, i, try std.fmt.allocPrint(c.arena, "{s}.history", .{c.node_names.get(p) orelse "?"}));
        } else if (std.mem.eql(u8, n.name, "data")) {
            try c.addData(n);
        }
        for (n.children) |ch| try c.collect(ch, n);
    }

    fn addData(c: *Conv, n: *const Node) Allocator.Error!void {
        const id = n.attr("id") orelse return c.warn(n.line, "a <data> without an id: left out", .{});
        const name = try c.unique(try c.identifier(id, "d_"));
        try c.data_names.put(c.arena, id, name);
        if (n.attr("src") != null) try c.warn(n.line, "<data src>: not loaded, '{s}' starts empty", .{id});
        const value = n.attr("expr") orelse blk: {
            const t = std.mem.trim(u8, n.text, " \t\r\n");
            break :blk if (t.len > 0) t else null;
        };
        var ty: []const u8 = "int";
        var init: ?[]const u8 = null;
        if (value) |e| {
            const t = std.mem.trim(u8, e, " \t\r\n");
            if (std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "false")) {
                ty = "bool";
                init = t;
            } else if (t.len >= 2 and (t[0] == '\'' or t[0] == '"') and t[t.len - 1] == t[0]) {
                ty = "string";
                init = try c.quote(t[1 .. t.len - 1]);
            } else if (std.fmt.parseInt(i32, t, 10)) |_| {
                init = t;
            } else |_| if (std.fmt.parseFloat(f32, t)) |_| {
                ty = "float";
                init = t;
            } else |_| {
                try c.warn(n.line, "<data id=\"{s}\" expr=\"{s}\">: not a literal, '{s}' is an int starting at 0", .{ id, t, id });
            }
        } else try c.warn(n.line, "<data id=\"{s}\"> has no value: its type is guessed (int)", .{id});
        try c.data.append(c.arena, .{ .name = name, .ty = ty, .init = init });
    }

    /// `s` as a `.zge` string literal.
    fn quote(c: *Conv, s: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.append(c.arena, '"');
        for (s) |ch| switch (ch) {
            '"' => try out.appendSlice(c.arena, "\\\""),
            '\\' => try out.appendSlice(c.arena, "\\\\"),
            '\n' => try out.appendSlice(c.arena, "\\n"),
            else => try out.append(c.arena, ch),
        };
        try out.append(c.arena, '"');
        return out.items;
    }

    /// An SCXML event name as a declared `.zge` event.
    fn event(c: *Conv, raw: []const u8) Allocator.Error![]const u8 {
        var name = try c.identifier(raw, "e_");
        const own = [_][]const u8{ "running", "current", "state", "active", "start", "stop" };
        for (own) |o| if (std.mem.eql(u8, o, name)) {
            name = try std.fmt.allocPrint(c.arena, "{s}-event", .{name});
        };
        for (c.events.items) |e| if (std.mem.eql(u8, e, name)) return e;
        try c.events.append(c.arena, name);
        return name;
    }

    /// A target state's `.zge` name (or `parent.history`).
    fn target(c: *Conv, n: *const Node, id: []const u8) Allocator.Error!?[]const u8 {
        return c.names.get(id) orelse {
            try c.warn(n.line, "no state '{s}': the transition is left out", .{id});
            return null;
        };
    }

    // ---- Expressions ----

    /// An ECMAScript expression in `.zge`, or null when it uses more than
    /// literals, data names, operators and `In('state')`.
    fn expr(c: *Conv, js: []const u8) Allocator.Error!?[]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < js.len) {
            const ch = js[i];
            if (std.ascii.isWhitespace(ch)) {
                i += 1;
                continue;
            }
            if (out.items.len > 0 and out.items[out.items.len - 1] != '(' and ch != ')') try out.append(c.arena, ' ');
            if (std.ascii.isDigit(ch)) {
                const start = i;
                while (i < js.len and (std.ascii.isDigit(js[i]) or js[i] == '.')) i += 1;
                try out.appendSlice(c.arena, js[start..i]);
            } else if (ch == '\'' or ch == '"') {
                const end = std.mem.indexOfScalarPos(u8, js, i + 1, ch) orelse return null;
                try out.appendSlice(c.arena, try c.quote(js[i + 1 .. end]));
                i = end + 1;
            } else if (std.ascii.isAlphabetic(ch) or ch == '_' or ch == '$') {
                const start = i;
                while (i < js.len and (std.ascii.isAlphanumeric(js[i]) or js[i] == '_' or js[i] == '$')) i += 1;
                const word = js[start..i];
                if (std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "false")) {
                    try out.appendSlice(c.arena, word);
                } else if (std.mem.eql(u8, word, "In")) {
                    // `In('state')`.
                    var j = i;
                    while (j < js.len and std.ascii.isWhitespace(js[j])) j += 1;
                    if (j >= js.len or js[j] != '(') return null;
                    j += 1;
                    while (j < js.len and std.ascii.isWhitespace(js[j])) j += 1;
                    if (j >= js.len or (js[j] != '\'' and js[j] != '"')) return null;
                    const end = std.mem.indexOfScalarPos(u8, js, j + 1, js[j]) orelse return null;
                    const state = c.names.get(js[j + 1 .. end]) orelse return null;
                    if (std.mem.endsWith(u8, state, ".history")) return null;
                    j = end + 1;
                    while (j < js.len and std.ascii.isWhitespace(js[j])) j += 1;
                    if (j >= js.len or js[j] != ')') return null;
                    try out.print(c.arena, "{s}.active({s})", .{ machine, state });
                    i = j + 1;
                } else if (c.data_names.get(word)) |name| {
                    // Qualified: the machine's own members (`x`, `width`...)
                    // would hide the global's.
                    try out.print(c.arena, "root.{s}", .{name});
                } else return null;
            } else {
                const ops = [_]struct { []const u8, []const u8 }{
                    .{ "===", "==" }, .{ "!==", "!=" }, .{ "==", "==" }, .{ "!=", "!=" }, .{ "<=", "<=" }, .{ ">=", ">=" },
                    .{ "&&", "&&" },  .{ "||", "||" },  .{ "<", "<" },   .{ ">", ">" },   .{ "+", "+" },   .{ "-", "-" },
                    .{ "*", "*" },    .{ "/", "/" },    .{ "%", "%" },   .{ "!", "!" },   .{ "(", "(" },   .{ ")", ")" },
                };
                const op = for (ops) |o| {
                    if (std.mem.startsWith(u8, js[i..], o[0])) break o;
                } else return null;
                try out.appendSlice(c.arena, op[1]);
                i += op[0].len;
            }
        }
        if (out.items.len == 0) return null;
        return out.items;
    }

    /// `text` safe in a `//` comment (one line).
    fn oneLine(c: *Conv, text: []const u8) Allocator.Error![]const u8 {
        const out = try c.arena.dupe(u8, std.mem.trim(u8, text, " \t\r\n"));
        for (out) |*ch| if (ch.* == '\n' or ch.* == '\r') {
            ch.* = ' ';
        };
        return out;
    }

    // ---- Writing ----

    fn emit(c: *Conv, root: *const Node, file_name: []const u8) Allocator.Error![]const u8 {
        var body: std.ArrayList(u8) = .empty;
        // The machine first: it declares the events it uses.
        const initial = try c.initialOf(root);
        for (root.children) |ch| try c.emitChild(&body, ch, 2);

        var out: std.ArrayList(u8) = .empty;
        try out.print(c.arena, "// Converted from {s} by `zgec scxml`.\n\n", .{std.fs.path.basename(file_name)});
        const global = try c.globalName(root.attr("name") orelse std.fs.path.stem(file_name));
        try out.print(c.arena, "export global {s} {{\n", .{global});
        for (c.data.items) |d| {
            if (d.init) |v| try out.print(c.arena, "    var in-out <{s}> {s}: {s};\n", .{ d.ty, d.name, v }) else try out.print(c.arena, "    var in-out <{s}> {s};\n", .{ d.ty, d.name });
        }
        if (c.data.items.len > 0) try out.append(c.arena, '\n');
        try out.print(c.arena, "    {s} := StateMachine {{\n", .{machine});
        for (c.events.items) |e| try out.print(c.arena, "        event {s};\n", .{e});
        if (c.events.items.len > 0) try out.append(c.arena, '\n');
        if (initial) |i| try out.print(c.arena, "        initial {s};\n\n", .{i});
        try out.appendSlice(c.arena, body.items);
        try out.appendSlice(c.arena, "    }\n}\n");
        return out.items;
    }

    fn globalName(c: *Conv, raw: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var up = true;
        for (raw) |ch| {
            if (!std.ascii.isAlphanumeric(ch)) {
                up = true;
                continue;
            }
            if (out.items.len == 0 and std.ascii.isDigit(ch)) try out.append(c.arena, 'M');
            try out.append(c.arena, if (up) std.ascii.toUpper(ch) else ch);
            up = false;
        }
        if (out.items.len == 0) try out.appendSlice(c.arena, "Machine");
        return out.items;
    }

    /// The `initial` of a state (or the document): its attribute, or its
    /// `<initial>`'s transition; the state directly inside on the way to
    /// a deeper one.
    fn initialOf(c: *Conv, n: *const Node) Allocator.Error!?[]const u8 {
        var raw: ?[]const u8 = n.attr("initial");
        var line = n.line;
        for (n.children) |ch| if (std.mem.eql(u8, ch.name, "initial")) {
            line = ch.line;
            for (ch.children) |t| if (std.mem.eql(u8, t.name, "transition")) {
                raw = t.attr("target");
                if (t.children.len > 0) try c.warn(t.line, "the actions of an <initial>'s transition are left out", .{});
            };
        };
        const list = raw orelse return null;
        var ids = std.mem.tokenizeAny(u8, list, " \t\r\n");
        const first = ids.next() orelse return null;
        if (ids.next() != null) try c.warn(line, "several initial states ('{s}'): only the first is kept", .{list});
        var target_node = c.nodes.get(first) orelse {
            try c.warn(line, "no state '{s}' for 'initial'", .{first});
            return null;
        };
        // The state directly inside `n` on the way.
        var deeper = false;
        while (c.parents.get(target_node)) |p| {
            if (p == n) break;
            target_node = p;
            deeper = true;
        } else {
            try c.warn(line, "initial state '{s}' is not inside its state", .{first});
            return null;
        }
        if (deeper) try c.warn(line, "initial state '{s}' is not directly inside: '{s}' (on the way) is entered, then its own initial state", .{ first, c.node_names.get(target_node).? });
        return c.node_names.get(target_node);
    }

    fn indentBy(c: *Conv, out: *std.ArrayList(u8), level: usize) Allocator.Error!void {
        for (0..level) |_| try out.appendSlice(c.arena, "    ");
    }

    fn emitChild(c: *Conv, out: *std.ArrayList(u8), n: *const Node, level: usize) Allocator.Error!void {
        if (isState(n)) return c.emitState(out, n, level);
        const ignored = [_][]const u8{ "datamodel", "data", "initial", "history", "transition", "onentry", "onexit" };
        for (ignored) |i| if (std.mem.eql(u8, n.name, i)) return;
        try c.warn(n.line, "<{s}> is not converted", .{n.name});
        try c.indentBy(out, level);
        try out.print(c.arena, "// SCXML <{s}> not converted.\n", .{n.name});
    }

    fn emitState(c: *Conv, out: *std.ArrayList(u8), n: *const Node, level: usize) Allocator.Error!void {
        const name = c.node_names.get(n).?;
        const kind = n.name;
        var entry: std.ArrayList(u8) = .empty;
        var exit: std.ArrayList(u8) = .empty;
        var afters: std.ArrayList(u8) = .empty;
        for (n.children) |ch| {
            if (std.mem.eql(u8, ch.name, "onentry")) try c.emitBlock(&entry, ch.children, level + 2, .{ .afters = .{ .afters = &afters, .level = level + 1 } });
            if (std.mem.eql(u8, ch.name, "onexit")) try c.emitBlock(&exit, ch.children, level + 2, .exit);
            if (std.mem.eql(u8, ch.name, "donedata")) try c.warn(ch.line, "<donedata> is left out (done events carry no data)", .{});
            if (std.mem.eql(u8, ch.name, "invoke")) try c.warn(ch.line, "<invoke> is not converted", .{});
        }
        const has_children = for (n.children) |ch| {
            if (isState(ch)) break true;
        } else false;
        const has_transitions = for (n.children) |ch| {
            if (std.mem.eql(u8, ch.name, "transition")) break true;
        } else false;

        try c.indentBy(out, level);
        if (std.mem.eql(u8, kind, "final")) {
            if (has_children or has_transitions) try c.warn(n.line, "a <final> with states or transitions inside: they are left out", .{});
            if (entry.items.len == 0 and exit.items.len == 0) {
                try out.print(c.arena, "final {s};\n", .{name});
                return;
            }
            try out.print(c.arena, "final {s} {{\n", .{name});
        } else {
            try out.print(c.arena, "{s} {s} {{\n", .{ if (std.mem.eql(u8, kind, "parallel")) "parallel" else "state", name });
            const initial = if (std.mem.eql(u8, kind, "state") and has_children) try c.initialOf(n) else null;
            if (initial) |i| {
                try c.indentBy(out, level + 1);
                try out.print(c.arena, "initial {s};\n", .{i});
            }
            if (c.histories.get(n)) |deep| {
                try c.indentBy(out, level + 1);
                try out.print(c.arena, "history{s};\n", .{if (deep) " deep" else ""});
                // Without `initial`, the first state inside.
                const first = for (n.children) |ch| {
                    if (isState(ch)) break c.node_names.get(ch);
                } else null;
                try c.checkHistoryDefault(n, initial orelse first);
            }
        }
        if (entry.items.len > 0) {
            try c.indentBy(out, level + 1);
            try out.appendSlice(c.arena, "entered => {\n");
            try out.appendSlice(c.arena, entry.items);
            try c.indentBy(out, level + 1);
            try out.appendSlice(c.arena, "}\n");
        }
        if (exit.items.len > 0) {
            try c.indentBy(out, level + 1);
            try out.appendSlice(c.arena, "exited => {\n");
            try out.appendSlice(c.arena, exit.items);
            try c.indentBy(out, level + 1);
            try out.appendSlice(c.arena, "}\n");
        }
        try out.appendSlice(c.arena, afters.items);
        for (n.children) |ch| if (std.mem.eql(u8, ch.name, "transition")) try c.emitTransition(out, n, ch, level + 1);
        for (n.children) |ch| try c.emitChild(out, ch, level + 1);
        try c.indentBy(out, level);
        try out.appendSlice(c.arena, "}\n");
    }

    /// A history's default transition: its parent's initial state is
    /// entered instead, when it differs.
    fn checkHistoryDefault(c: *Conv, parent: *const Node, initial: ?[]const u8) Allocator.Error!void {
        for (parent.children) |h| if (std.mem.eql(u8, h.name, "history")) for (h.children) |t| if (std.mem.eql(u8, t.name, "transition")) {
            const to = t.attr("target") orelse continue;
            const named = if (c.nodes.get(to)) |tn| c.node_names.get(tn) else null;
            if (named == null or initial == null or !std.mem.eql(u8, named.?, initial.?))
                try c.warn(t.line, "a history's default transition (to '{s}'): its state's initial state is entered instead when there is no history", .{to});
            if (t.children.len > 0) try c.warn(t.line, "the actions of a history's default transition are left out", .{});
        };
    }

    fn emitTransition(c: *Conv, out: *std.ArrayList(u8), source: *const Node, t: *const Node, level: usize) Allocator.Error!void {
        // Its target.
        var target_name: ?[]const u8 = null;
        if (t.attr("target")) |list| {
            var ids = std.mem.tokenizeAny(u8, list, " \t\r\n");
            const first = ids.next();
            if (ids.next() != null) try c.warn(t.line, "several targets ('{s}'): only the first is kept", .{list});
            if (first) |id| {
                target_name = try c.target(t, id) orelse return;
                if (t.attr("type")) |ty| if (std.mem.eql(u8, ty, "internal")) if (c.nodes.get(id)) |tn| if (c.isInside(tn, source))
                    try c.warn(t.line, "an internal transition to a state inside its own: taken as an external one (its state is left and entered again)", .{});
            }
        }
        // Its guard.
        var guard: ?[]const u8 = null;
        var note: ?[]const u8 = null;
        if (t.attr("cond")) |cond| {
            guard = try c.expr(cond);
            if (guard == null) {
                try c.warn(t.line, "condition not converted: \"{s}\" (the transition is never taken)", .{try c.oneLine(cond)});
                guard = "false";
                note = try std.fmt.allocPrint(c.arena, "// SCXML cond not converted: {s}", .{try c.oneLine(cond)});
            }
        }
        // Its actions.
        var actions: std.ArrayList(u8) = .empty;
        try c.emitBlock(&actions, t.children, level + 1, .transition);
        // One per event (or one, eventless).
        var triggers: std.ArrayList([]const u8) = .empty;
        if (t.attr("event")) |list| {
            var it = std.mem.tokenizeAny(u8, list, " \t\r\n");
            while (it.next()) |e| {
                const ev = if (std.mem.endsWith(u8, e, ".*")) e[0 .. e.len - 2] else e;
                if (std.mem.eql(u8, ev, "*") or std.mem.startsWith(u8, ev, "error") or std.mem.startsWith(u8, ev, "done.invoke")) {
                    try c.warn(t.line, "event '{s}' is not converted (no wildcards, error or invoke events)", .{e});
                    continue;
                }
                if (std.mem.startsWith(u8, ev, "done.state.")) {
                    const id = ev["done.state.".len..];
                    const st = c.names.get(id) orelse {
                        try c.warn(t.line, "no state '{s}' for '{s}'", .{ id, e });
                        continue;
                    };
                    const tn = c.nodes.get(id).?;
                    const compound = for (tn.children) |ch| {
                        if (isState(ch)) break true;
                    } else false;
                    if (!compound) {
                        try c.warn(t.line, "'{s}' has no states inside: it is never done", .{id});
                        continue;
                    }
                    try triggers.append(c.arena, try std.fmt.allocPrint(c.arena, "on done.{s}", .{st}));
                    continue;
                }
                if (!std.mem.eql(u8, ev, e)) try c.warn(t.line, "event '{s}': matched as '{s}' exactly", .{ e, ev });
                try triggers.append(c.arena, try std.fmt.allocPrint(c.arena, "on {s}", .{try c.event(ev)}));
            }
            if (triggers.items.len == 0) return;
        } else {
            try triggers.append(c.arena, try std.fmt.allocPrint(c.arena, "when {s}", .{guard orelse "true"}));
            guard = null;
        }
        for (triggers.items) |trigger| {
            if (note) |n| {
                try c.indentBy(out, level);
                try out.print(c.arena, "{s}\n", .{n});
            }
            try c.indentBy(out, level);
            try out.appendSlice(c.arena, trigger);
            if (guard) |g| try out.print(c.arena, " when {s}", .{g});
            if (target_name) |to| try out.print(c.arena, " => {s}", .{to});
            if (actions.items.len > 0) {
                try out.appendSlice(c.arena, " {\n");
                try out.appendSlice(c.arena, actions.items);
                try c.indentBy(out, level);
                try out.appendSlice(c.arena, "}\n");
            } else if (target_name == null) {
                // Targetless with no actions: still a transition.
                try out.appendSlice(c.arena, " {}\n");
            } else try out.appendSlice(c.arena, ";\n");
        }
    }

    /// Whether `n` is inside `around`.
    fn isInside(c: *Conv, n: *const Node, around: *const Node) bool {
        var it = c.parents.get(n);
        while (it) |p| : (it = c.parents.get(p)) if (p == around) return true;
        return false;
    }

    const Where = union(enum) {
        /// In `<onentry>`: delayed sends become `after`s of the state,
        /// written at `level`.
        afters: struct { afters: *std.ArrayList(u8), level: usize },
        exit,
        transition,
    };

    /// Executable content as statements.
    fn emitBlock(c: *Conv, out: *std.ArrayList(u8), nodes: []const *Node, level: usize, where: Where) Allocator.Error!void {
        var i: usize = 0;
        while (i < nodes.len) : (i += 1) {
            const n = nodes[i];
            if (std.mem.eql(u8, n.name, "raise")) {
                const e = n.attr("event") orelse {
                    try c.warn(n.line, "a <raise> without an event: left out", .{});
                    continue;
                };
                try c.indentBy(out, level);
                try out.print(c.arena, "{s}.{s}();\n", .{ machine, try c.event(e) });
            } else if (std.mem.eql(u8, n.name, "send")) {
                try c.emitSend(out, n, level, where);
            } else if (std.mem.eql(u8, n.name, "cancel")) {
                // A send of this state's `after`s is cancelled as it is left.
                if (where != .exit) try c.warn(n.line, "<cancel> is left out (delayed sends, `after`s, are cancelled when their state is left)", .{});
            } else if (std.mem.eql(u8, n.name, "assign")) {
                const loc = n.attr("location") orelse "";
                const name = c.data_names.get(loc);
                const value = if (n.attr("expr")) |e| try c.expr(e) else null;
                if (name == null or value == null) {
                    try c.warn(n.line, "<assign location=\"{s}\"> not converted", .{loc});
                    try c.indentBy(out, level);
                    try out.print(c.arena, "// SCXML <assign location=\"{s}\" expr=\"{s}\"> not converted.\n", .{ try c.oneLine(loc), try c.oneLine(n.attr("expr") orelse "") });
                    continue;
                }
                try c.indentBy(out, level);
                try out.print(c.arena, "root.{s} = {s};\n", .{ name.?, value.? });
            } else if (std.mem.eql(u8, n.name, "log")) {
                const label = n.attr("label") orelse "";
                try c.indentBy(out, level);
                if (n.attr("expr")) |e| if (try c.expr(e)) |v| {
                    try out.print(c.arena, "debug({s}, {s});\n", .{ try c.quote(label), v });
                    continue;
                } else try c.warn(n.line, "<log expr=\"{s}\">: its value is left out", .{try c.oneLine(e)});
                try out.print(c.arena, "debug({s});\n", .{try c.quote(label)});
            } else if (std.mem.eql(u8, n.name, "if")) {
                try c.emitIf(out, n, level, where);
            } else {
                try c.warn(n.line, "<{s}> is not converted", .{n.name});
                try c.indentBy(out, level);
                try out.print(c.arena, "// SCXML <{s}> not converted.\n", .{n.name});
            }
        }
    }

    fn emitSend(c: *Conv, out: *std.ArrayList(u8), n: *const Node, level: usize, where: Where) Allocator.Error!void {
        const e = n.attr("event") orelse {
            try c.warn(n.line, "a <send> without an event (eventexpr, content): not converted", .{});
            try c.indentBy(out, level);
            try out.appendSlice(c.arena, "// SCXML <send> not converted.\n");
            return;
        };
        if (n.attr("target")) |t| if (!std.mem.eql(u8, t, "#_internal")) {
            try c.warn(n.line, "<send target=\"{s}\">: only sends to the machine itself are converted", .{t});
            try c.indentBy(out, level);
            try out.print(c.arena, "// SCXML <send event=\"{s}\" target=\"{s}\"> not converted.\n", .{ e, t });
            return;
        };
        if (n.attr("namelist") != null or n.children.len > 0) try c.warn(n.line, "the data of <send event=\"{s}\"> is left out (events carry no data)", .{e});
        if (n.attr("delayexpr") != null) try c.warn(n.line, "<send delayexpr>: sent at once", .{});
        const name = try c.event(e);
        const delay_ms = if (n.attr("delay")) |d| parseDelay(d) else 0;
        if (delay_ms == null) try c.warn(n.line, "<send delay=\"{s}\">: not a time, sent at once", .{n.attr("delay").?});
        if (delay_ms != null and delay_ms.? > 0) {
            switch (where) {
                .afters => |a| {
                    if (!c.noted_after) {
                        c.noted_after = true;
                        try c.warn(n.line, "delayed sends become `after`s of their state: left before the delay, the event is not sent", .{});
                    }
                    try c.indentBy(a.afters, a.level);
                    try a.afters.print(c.arena, "after {s} {{\n", .{try formatDelay(c.arena, delay_ms.?)});
                    try c.indentBy(a.afters, a.level + 1);
                    try a.afters.print(c.arena, "{s}.{s}();\n", .{ machine, name });
                    try c.indentBy(a.afters, a.level);
                    try a.afters.appendSlice(c.arena, "}\n");
                    return;
                },
                else => {
                    try c.warn(n.line, "a delayed <send> outside <onentry>: sent at once", .{});
                },
            }
        }
        if (!c.noted_send) {
            c.noted_send = true;
            try c.warn(n.line, "<send> to the machine itself is processed as <raise> is (before events from outside)", .{});
        }
        try c.indentBy(out, level);
        try out.print(c.arena, "{s}.{s}();\n", .{ machine, name });
    }

    fn emitIf(c: *Conv, out: *std.ArrayList(u8), n: *const Node, level: usize, where: Where) Allocator.Error!void {
        // Branches: the `if`'s, then each `<elseif>`'s and the `<else>`'s.
        var conds: std.ArrayList(?[]const u8) = .empty;
        var bodies: std.ArrayList(std.ArrayList(*Node)) = .empty;
        try conds.append(c.arena, n.attr("cond") orelse "");
        try bodies.append(c.arena, .empty);
        for (n.children) |ch| {
            if (std.mem.eql(u8, ch.name, "elseif")) {
                try conds.append(c.arena, ch.attr("cond") orelse "");
                try bodies.append(c.arena, .empty);
            } else if (std.mem.eql(u8, ch.name, "else")) {
                try conds.append(c.arena, null);
                try bodies.append(c.arena, .empty);
            } else try bodies.items[bodies.items.len - 1].append(c.arena, ch);
        }
        for (conds.items, bodies.items, 0..) |cond, body, k| {
            try c.indentBy(out, level);
            if (cond) |js| {
                const zge = try c.expr(js) orelse blk: {
                    try c.warn(n.line, "condition not converted: \"{s}\" (taken as false)", .{try c.oneLine(js)});
                    break :blk "false";
                };
                try out.print(c.arena, "{s}if {s} {{\n", .{ if (k > 0) "} else " else "", zge });
            } else try out.appendSlice(c.arena, "} else {\n");
            try c.emitBlock(out, body.items, level + 1, where);
        }
        try c.indentBy(out, level);
        try out.appendSlice(c.arena, "}\n");
    }
};

/// A CSS2 time (`2s`, `500ms`, `1.5s`) in ms, or null.
fn parseDelay(text: []const u8) ?u64 {
    const t = std.mem.trim(u8, text, " \t");
    const ms = std.mem.endsWith(u8, t, "ms");
    const digits = if (ms) t[0 .. t.len - 2] else if (std.mem.endsWith(u8, t, "s")) t[0 .. t.len - 1] else return null;
    const v = std.fmt.parseFloat(f64, digits) catch return null;
    if (v < 0) return null;
    return @intFromFloat(@round(if (ms) v else v * 1000));
}

fn formatDelay(arena: Allocator, ms: u64) Allocator.Error![]const u8 {
    if (ms % 1000 == 0) return std.fmt.allocPrint(arena, "{d}s", .{ms / 1000});
    return std.fmt.allocPrint(arena, "{d}ms", .{ms});
}
