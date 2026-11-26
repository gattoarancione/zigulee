// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! JSON read by path, for `json-get`, `json-number` and `json-count` in
//! `.zge`: a path is keys and indexes separated by dots (`items.0.name`;
//! "" for the whole). The text is read as far as needed each time, without
//! building a tree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Scanner = std.json.Scanner;

/// A value found.
pub const Found = union(enum) {
    /// Decoded.
    string: []const u8,
    /// As written.
    number: []const u8,
    boolean: bool,
    null,
    /// An object or an array, as written (to be read by path in turn).
    raw: []const u8,
};

/// Moves `sc` to the value at `path`; false if there is none.
fn locate(sc: *Scanner, a: Allocator, path: []const u8) !bool {
    if (path.len == 0) return true;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| {
        switch (try sc.peekNextTokenType()) {
            .object_begin => {
                _ = try sc.next();
                while (true) {
                    switch (try sc.nextAllocMax(a, .alloc_if_needed, 1 << 20)) {
                        .string, .allocated_string => |key| if (std.mem.eql(u8, key, part)) break,
                        else => return false, // the end of the object
                    }
                    try sc.skipValue();
                }
            },
            .array_begin => {
                const index = std.fmt.parseInt(usize, part, 10) catch return false;
                _ = try sc.next();
                for (0..index) |_| {
                    if (try sc.peekNextTokenType() == .array_end) return false;
                    try sc.skipValue();
                }
                if (try sc.peekNextTokenType() == .array_end) return false;
            },
            else => return false,
        }
    }
    return true;
}

/// The value at `path` in `text` (strings decoded with `a`); null if there
/// is none, or the text is not JSON.
pub fn find(a: Allocator, text: []const u8, path: []const u8) ?Found {
    var sc: Scanner = .initCompleteInput(a, text);
    defer sc.deinit();
    if (!(locate(&sc, a, path) catch return null)) return null;
    const ty = sc.peekNextTokenType() catch return null;
    return switch (ty) {
        .string => switch (sc.nextAllocMax(a, .alloc_if_needed, 16 << 20) catch return null) {
            .string, .allocated_string => |s| .{ .string = s },
            else => null,
        },
        .number => switch (sc.next() catch return null) {
            .number => |n| .{ .number = n },
            else => null,
        },
        .true => .{ .boolean = true },
        .false => .{ .boolean = false },
        .null => .null,
        .object_begin, .array_begin => {
            const start = sc.cursor;
            sc.skipValue() catch return null;
            return .{ .raw = std.mem.trim(u8, text[start..sc.cursor], " \t\r\n") };
        },
        else => null,
    };
}

/// `find` as text: a string, a number as written, true or false, an
/// object or array as JSON; "" for null or nothing. Written to `out`.
pub fn get(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8, path: []const u8) Allocator.Error!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const found = find(arena.allocator(), text, path) orelse return;
    try out.appendSlice(gpa, switch (found) {
        .string, .number, .raw => |s| s,
        .boolean => |b| if (b) "true" else "false",
        .null => "",
    });
}

/// The number at `path` (a number, or a string holding one; true is 1);
/// 0 otherwise.
pub fn number(text: []const u8, path: []const u8) f32 {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const found = find(fba.allocator(), text, path) orelse return 0;
    return switch (found) {
        .number, .string => |s| std.fmt.parseFloat(f32, std.mem.trim(u8, s, " ")) catch 0,
        .boolean => |b| if (b) 1 else 0,
        else => 0,
    };
}

/// How many values the array at `path` holds, or keys the object; 0 for
/// anything else.
pub fn count(text: []const u8, path: []const u8) i32 {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const a = fba.allocator();
    var sc: Scanner = .initCompleteInput(a, text);
    defer sc.deinit();
    if (!(locate(&sc, a, path) catch return 0)) return 0;
    const object = switch (sc.next() catch return 0) {
        .object_begin => true,
        .array_begin => false,
        else => return 0,
    };
    var n: i32 = 0;
    while (true) {
        const ty = sc.peekNextTokenType() catch return n;
        if (ty == .object_end or ty == .array_end) return n;
        // A key, then its value.
        if (object) _ = sc.next() catch return n;
        sc.skipValue() catch return n;
        n += 1;
    }
}

// ---- Tests ----

const testing = std.testing;

const doc =
    \\{ "name": "Ann é\n", "age": 41, "admin": true, "boss": null,
    \\  "items": [ { "id": 1, "tags": ["a", "b"] }, { "id": "7.5", "tags": [] } ],
    \\  "a.b": 1, "empty": {} }
;

fn expectGet(expected: []const u8, path: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try get(testing.allocator, &out, doc, path);
    try testing.expectEqualStrings(expected, out.items);
}

test "values by path: decoded strings, numbers as written, objects as JSON" {
    try expectGet("Ann é\n", "name");
    try expectGet("41", "age");
    try expectGet("true", "admin");
    try expectGet("", "boss");
    try expectGet("b", "items.0.tags.1");
    try expectGet("{ \"id\": \"7.5\", \"tags\": [] }", "items.1");
    try expectGet("", "items.2");
    try expectGet("", "items.x");
    try expectGet("", "nope.deeper");
    try expectGet("", "name.0");
    // Read again: a part read by path in turn.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try get(testing.allocator, &out, doc, "items.0");
    try testing.expectEqual(@as(f32, 1), number(out.items, "id"));
}

test "numbers and counts" {
    try testing.expectEqual(@as(f32, 41), number(doc, "age"));
    try testing.expectEqual(@as(f32, 7.5), number(doc, "items.1.id"));
    try testing.expectEqual(@as(f32, 1), number(doc, "admin"));
    try testing.expectEqual(@as(f32, 0), number(doc, "name"));
    try testing.expectEqual(@as(i32, 2), count(doc, "items"));
    try testing.expectEqual(@as(i32, 0), count(doc, "items.1.tags"));
    try testing.expectEqual(@as(i32, 7), count(doc, ""));
    try testing.expectEqual(@as(i32, 0), count(doc, "empty"));
    try testing.expectEqual(@as(i32, 0), count(doc, "age"));
    try testing.expectEqual(@as(i32, 0), count("not json", ""));
    try testing.expectEqual(@as(f32, 0), number("[1,", "0.5"));
}
