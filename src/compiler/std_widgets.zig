// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The standard widgets, embedded in the compiler:
//! `import { Button } from "std-widgets.zge";`
//!
//! The widgets are in src/widgets/common/ (`std-widgets.zge` re-exports
//! them); each style's directory (src/widgets/<style>/) has its colors
//! (`palette.zge`) and sizes (`style.zge`). A style's files take precedence
//! over the common ones. Inside the compiler the files live under the
//! virtual directory `@std/`.

const std = @import("std");

/// What user code imports.
pub const import_name = "std-widgets.zge";
/// The virtual path of the style's `std-widgets.zge`.
pub const root = dir ++ "/" ++ import_name;
pub const dir = "@std";

pub const styles = [_][]const u8{ "fluent", "material", "minimal", "cupertino" };
pub const default_style = "fluent";

/// The style that looks like the system's on `os` (`native`): cupertino on
/// Apple's, fluent elsewhere.
pub fn nativeStyle(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .macos, .ios, .tvos, .visionos, .watchos => "cupertino",
        else => "fluent",
    };
}

/// `native` as the style of the system this runs on; others as they are.
pub fn resolve(style: []const u8) []const u8 {
    return if (std.mem.eql(u8, style, "native")) nativeStyle(@import("builtin").os.tag) else style;
}

const File = struct { style: []const u8, name: []const u8, source: []const u8 };

fn file(comptime style: []const u8, comptime name: []const u8) File {
    return .{ .style = style, .name = name, .source = @embedFile("../widgets/" ++ style ++ "/" ++ name) };
}

/// Each style has its colors and sizes; the widgets are shared.
const files = [_]File{
    file("fluent", "palette.zge"),
    file("fluent", "style.zge"),
    file("material", "palette.zge"),
    file("material", "style.zge"),
    file("minimal", "palette.zge"),
    file("minimal", "style.zge"),
    file("cupertino", "palette.zge"),
    file("cupertino", "style.zge"),
    file("common", "std-widgets.zge"),
    file("common", "button.zge"),
    file("common", "checkbox.zge"),
    file("common", "slider.zge"),
    file("common", "progress.zge"),
    file("common", "lineedit.zge"),
    file("common", "textedit.zge"),
    file("common", "scrollview.zge"),
    file("common", "tabwidget.zge"),
    file("common", "spinbox.zge"),
    file("common", "spinner.zge"),
    file("common", "combobox.zge"),
    file("common", "listview.zge"),
    file("common", "datepicker.zge"),
    file("common", "tableview.zge"),
    file("common", "audio.zge"),
    file("common", "videoplayer.zge"),
    file("common", "tumbler.zge"),
    file("common", "tooltip.zge"),
    file("common", "radiobutton.zge"),
    file("common", "containers.zge"),
    file("common", "toolbar.zge"),
    file("common", "pageindicator.zge"),
    file("common", "rangeslider.zge"),
    file("common", "treeview.zge"),
    file("common", "drawer.zge"),
    file("common", "virtualkeyboard.zge"),
    file("common", "menu.zge"),
    file("common", "dialog.zge"),
};

pub fn fileNames() []const []const u8 {
    const names = comptime blk: {
        var list: [files.len][]const u8 = undefined;
        for (files, 0..) |f, i| list[i] = f.name;
        break :blk list;
    };
    return &names;
}

pub fn isStd(path: []const u8) bool {
    return std.mem.startsWith(u8, path, dir ++ "/");
}

pub fn isStyle(style: []const u8) bool {
    if (std.mem.eql(u8, style, "native")) return true;
    for (styles) |s| if (std.mem.eql(u8, s, style)) return true;
    return false;
}

/// The source of `path` (under `@std/`) in `style`.
pub fn read(style: []const u8, path: []const u8) ?[]const u8 {
    const name = path[dir.len + 1 ..];
    for ([_][]const u8{ resolve(style), "common" }) |s| {
        for (files) |f| if (std.mem.eql(u8, f.style, s) and std.mem.eql(u8, f.name, name)) return f.source;
    }
    return null;
}

test "every style has the root file" {
    for (styles) |s| try std.testing.expect(read(s, root) != null);
    try std.testing.expect(read("native", root) != null);
}

test "every style defines what the others do" {
    // The widgets use any of them: a style lacking one fails to compile
    // them.
    const names = struct {
        fn of(src: []const u8, buf: *std.ArrayList([]const u8), a: std.mem.Allocator) !void {
            var lines = std.mem.splitScalar(u8, src, '\n');
            while (lines.next()) |l| {
                if (!std.mem.startsWith(u8, std.mem.trimStart(u8, l, " "), "var ")) continue;
                const at = std.mem.indexOfScalar(u8, l, '<') orelse continue;
                const gt = std.mem.indexOfScalarPos(u8, l, at, '>') orelse continue;
                const rest = std.mem.trim(u8, l[gt + 1 ..], " ");
                const end = std.mem.indexOfAny(u8, rest, ":;") orelse continue;
                try buf.append(a, std.mem.trim(u8, rest[0..end], " "));
            }
        }
    }.of;
    const a = std.testing.allocator;
    inline for (.{ "palette.zge", "style.zge" }) |file_name| {
        var reference: std.ArrayList([]const u8) = .empty;
        defer reference.deinit(a);
        try names(read(default_style, dir ++ "/" ++ file_name).?, &reference, a);
        for (styles) |s| {
            var these: std.ArrayList([]const u8) = .empty;
            defer these.deinit(a);
            try names(read(s, dir ++ "/" ++ file_name).?, &these, a);
            for (reference.items) |n| {
                var found = false;
                for (these.items) |m| found = found or std.mem.eql(u8, n, m);
                if (!found) std.debug.print("{s}/{s} lacks {s}\n", .{ s, file_name, n });
                try std.testing.expect(found);
            }
        }
    }
}
