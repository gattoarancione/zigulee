// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Storage for computed strings (`"Count: \{n}"`), used by generated code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const i18n = @import("i18n.zig");

/// Formats strings into one of two alternating buffers, so the previous
/// result stays intact while the next one is written: a property can still
/// compare its old value with the new one.
pub const StringBuffer = struct {
    buffers: [2]std.ArrayList(u8) = .{ .empty, .empty },
    current: u1 = 0,

    pub fn deinit(self: *StringBuffer, gpa: Allocator) void {
        for (&self.buffers) |*b| b.deinit(gpa);
    }

    /// Returns the formatted string, valid until the second-next call.
    /// Returns "" if out of memory.
    pub fn format(self: *StringBuffer, gpa: Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
        self.current +%= 1;
        const b = &self.buffers[self.current];
        b.clearRetainingCapacity();
        b.print(gpa, fmt, args) catch return "";
        return b.items;
    }

    /// A translated template (`i18n.translate`) with its arguments filled
    /// in (`i18n.format`), with the same lifetime as `format`'s result.
    pub fn formatTranslated(self: *StringBuffer, gpa: Allocator, template: []const u8, args: []const i18n.Arg, n: i64) []const u8 {
        self.current +%= 1;
        const b = &self.buffers[self.current];
        b.clearRetainingCapacity();
        var out: std.Io.Writer.Allocating = .fromArrayList(gpa, b);
        defer b.* = out.toArrayList();
        i18n.format(&out.writer, template, args, n) catch return "";
        return out.written();
    }

    /// The value at `path` in JSON `text` (`json.get`), with the same
    /// lifetime as `format`'s result.
    pub fn json(self: *StringBuffer, gpa: Allocator, text: []const u8, path: []const u8) []const u8 {
        self.current +%= 1;
        const b = &self.buffers[self.current];
        b.clearRetainingCapacity();
        @import("json.zig").get(gpa, b, text, path) catch return "";
        return b.items;
    }

    /// `s` repeated `n` times, with the same lifetime as `format`'s result.
    pub fn repeat(self: *StringBuffer, gpa: Allocator, s: []const u8, n: usize) []const u8 {
        self.current +%= 1;
        const b = &self.buffers[self.current];
        b.clearRetainingCapacity();
        b.ensureTotalCapacity(gpa, s.len * n) catch return "";
        for (0..n) |_| b.appendSliceAssumeCapacity(s);
        return b.items;
    }
};

test "alternating buffers keep the previous result" {
    var s: StringBuffer = .{};
    defer s.deinit(std.testing.allocator);
    const a = s.format(std.testing.allocator, "n={d}", .{1});
    const b = s.format(std.testing.allocator, "n={d}", .{2});
    try std.testing.expectEqualStrings("n=1", a);
    try std.testing.expectEqualStrings("n=2", b);
}
