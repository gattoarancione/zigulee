// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! `zgec scxml`: SCXML documents converted, the output compiled.

const std = @import("std");
const testing = std.testing;
const compiler = @import("compiler.zig");
const scxml = compiler.scxml;

/// Converts `source`, compiles the output (it must have no errors), and
/// returns it with its warnings.
fn convertOk(arena: std.mem.Allocator, source: []const u8) !struct { text: []const u8, warnings: []const scxml.Warning } {
    const r = try scxml.convert(arena, "test.scxml", source);
    const z = switch (r) {
        .zge => |z| z,
        .errors => |e| {
            std.debug.print("conversion failed:\n{s}\n", .{e});
            return error.TestUnexpectedResult;
        },
    };
    switch (try compiler.compile(arena, "converted.zge", z.text, .{})) {
        .zig => {},
        .errors => |e| {
            std.debug.print("the converted file does not compile:\n{s}\n--- converted:\n{s}\n", .{ e, z.text });
            return error.TestUnexpectedResult;
        },
    }
    return .{ .text = z.text, .warnings = z.warnings };
}

fn expectHas(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("expected to find:\n  {s}\nin:\n{s}\n", .{ needle, text });
        return error.TestUnexpectedResult;
    }
}

fn expectWarning(warnings: []const scxml.Warning, needle: []const u8) !void {
    for (warnings) |w| if (std.mem.indexOf(u8, w.message, needle) != null) return;
    std.debug.print("expected a warning containing:\n  {s}\ngot:\n", .{needle});
    for (warnings) |w| std.debug.print("  {d}: {s}\n", .{ w.line, w.message });
    return error.TestUnexpectedResult;
}

test "SCXML: states, transitions, entry and exit actions, the data model" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try convertOk(arena.allocator(),
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" name="door lock" initial="locked" datamodel="ecmascript">
        \\  <datamodel>
        \\    <data id="tries" expr="0"/>
        \\    <data id="code" expr="'1234'"/>
        \\    <data id="open" expr="false"/>
        \\  </datamodel>
        \\  <state id="locked">
        \\    <onentry><assign location="open" expr="false"/></onentry>
        \\    <transition event="unlock" cond="tries &lt; 3" target="unlocked">
        \\      <log label="unlocked" expr="tries"/>
        \\    </transition>
        \\    <transition event="unlock wrong.code">
        \\      <assign location="tries" expr="tries + 1"/>
        \\      <if cond="tries === 3"><raise event="alarm"/><elseif cond="tries == 2"/><log label="last try"/><else/><log label="try again"/></if>
        \\    </transition>
        \\    <transition event="alarm" target="blocked"/>
        \\  </state>
        \\  <state id="unlocked">
        \\    <onentry><assign location="open" expr="true"/><assign location="tries" expr="0"/></onentry>
        \\    <onexit><log label="closing"/></onexit>
        \\    <transition event="lock" target="locked"/>
        \\  </state>
        \\  <final id="blocked"/>
        \\</scxml>
    );
    const t = r.text;
    try expectHas(t, "export global DoorLock {");
    try expectHas(t, "var in-out <int> tries: 0;");
    try expectHas(t, "var in-out <string> code: \"1234\";");
    try expectHas(t, "var in-out <bool> open: false;");
    try expectHas(t, "event unlock;");
    try expectHas(t, "event wrong_code;");
    try expectHas(t, "initial locked;");
    try expectHas(t, "on unlock when root.tries < 3 => unlocked {");
    try expectHas(t, "debug(\"unlocked\", root.tries);");
    // One transition per event.
    try expectHas(t, "on wrong_code {");
    try expectHas(t, "root.tries = root.tries + 1;");
    try expectHas(t, "if root.tries == 3 {");
    try expectHas(t, "machine.alarm();");
    try expectHas(t, "} else if root.tries == 2 {");
    try expectHas(t, "} else {");
    try expectHas(t, "exited => {");
    try expectHas(t, "final blocked;");
    try testing.expectEqual(@as(usize, 0), r.warnings.len);
}

test "SCXML: compound, parallel, history, done, eventless, delayed sends, In()" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try convertOk(arena.allocator(),
        \\<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        \\  <datamodel><data id="ready" expr="false"/></datamodel>
        \\  <state id="boot">
        \\    <transition cond="ready" target="work"/>
        \\  </state>
        \\  <parallel id="work">
        \\    <transition event="done.state.work" target="end"/>
        \\    <state id="net">
        \\      <initial><transition target="offline"/></initial>
        \\      <state id="offline">
        \\        <onentry><send event="retry" delay="1.5s" id="t1"/></onentry>
        \\        <onexit><cancel sendid="t1"/></onexit>
        \\        <transition event="retry" target="offline"/>
        \\        <transition event="up" target="online"/>
        \\      </state>
        \\      <final id="online"/>
        \\    </state>
        \\    <state id="ui" initial="list">
        \\      <history id="ui-back" type="deep"><transition target="list"/></history>
        \\      <state id="list"><transition event="open" cond="In('online')" target="detail"/></state>
        \\      <state id="detail"><transition event="back" target="list"/></state>
        \\      <final id="ui-done"/>
        \\      <transition event="quit" target="ui-done"/>
        \\    </state>
        \\  </parallel>
        \\  <state id="away"><transition event="return" target="ui-back"/></state>
        \\  <final id="end"/>
        \\</scxml>
    );
    const t = r.text;
    try expectHas(t, "export global Test {");
    try expectHas(t, "when root.ready => work;");
    try expectHas(t, "parallel work {");
    try expectHas(t, "on done.work => end;");
    try expectHas(t, "initial offline;");
    try expectHas(t, "after 1500ms {");
    try expectHas(t, "machine.retry();");
    try expectHas(t, "history deep;");
    try expectHas(t, "on open when machine.active(online) => detail;");
    try expectHas(t, "on return => ui.history;");
    // The cancel in onexit is the `after`'s own: nothing said about it.
    for (r.warnings) |w| try testing.expect(std.mem.indexOf(u8, w.message, "cancel") == null);
    try expectWarning(r.warnings, "delayed sends become `after`s of their state");
}

test "SCXML: what is not converted is said, and left as comments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try convertOk(arena.allocator(),
        \\<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a b">
        \\  <datamodel><data id="n" expr="Math.random()"/></datamodel>
        \\  <state id="a">
        \\    <invoke type="http://www.w3.org/TR/scxml/" src="child.scxml"/>
        \\    <onentry>
        \\      <script>n = 3;</script>
        \\      <send event="ping" target="#_parent"/>
        \\    </onentry>
        \\    <transition event="go" cond="_event.data.ok" target="b"/>
        \\    <transition event="*" target="b"/>
        \\    <transition event="go" target="b c"/>
        \\    <transition event="go" target="nowhere"/>
        \\  </state>
        \\  <state id="b"/>
        \\  <state id="c"/>
        \\</scxml>
    );
    const t = r.text;
    try expectHas(t, "// SCXML <script> not converted.");
    try expectHas(t, "// SCXML <send event=\"ping\" target=\"#_parent\"> not converted.");
    try expectHas(t, "// SCXML cond not converted: _event.data.ok");
    try expectHas(t, "on go when false => b;");
    try expectWarning(r.warnings, "several initial states ('a b')");
    try expectWarning(r.warnings, "not a literal, 'n' is an int starting at 0");
    try expectWarning(r.warnings, "<invoke> is not converted");
    try expectWarning(r.warnings, "event '*' is not converted");
    try expectWarning(r.warnings, "several targets ('b c')");
    try expectWarning(r.warnings, "no state 'nowhere'");
    // Their lines.
    for (r.warnings) |w| if (std.mem.indexOf(u8, w.message, "<invoke>") != null) try testing.expectEqual(@as(u32, 4), w.line);
}

test "SCXML: names made valid, unique; reading errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try convertOk(arena.allocator(),
        \\<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        \\  <state id="1st.state"><transition event="stop" target="history"/></state>
        \\  <state id="history"/>
        \\</scxml>
    );
    try expectHas(r.text, "state s_1st_state {");
    try expectHas(r.text, "event stop-event;");
    try expectHas(r.text, "on stop-event => history-n2;");

    const bad = try scxml.convert(arena.allocator(), "bad.scxml", "<scxml>\n<state id='a'>\n</scxml>");
    try testing.expect(bad == .errors);
    try expectHas(bad.errors, "bad.scxml:3: error: a closing tag does not match its opening tag");
    const not_scxml = try scxml.convert(arena.allocator(), "x.scxml", "<html/>");
    try expectHas(not_scxml.errors, "expected <scxml>, found <html>");
}
