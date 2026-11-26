// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Makes a pre-rendered font (src/core/text/bitmap_font.zig) from a
//! TrueType font, for microcontrollers:
//!
//!     zigulee-bitmap-font in.ttf -o out.zbf --sizes 13,16,40 [--chars 20-7e,2026] [--text "°€"]
//!
//! `--chars` takes hexadecimal code point ranges (default: printable ASCII
//! and "…"); `--text` adds the characters of a string. In build.zig,
//! `zigulee.bitmapFont` runs it.

const std = @import("std");
const zigulee = @import("zigulee");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var sizes: std.ArrayList(u16) = .empty;
    var chars: std.ArrayList(u21) = .empty;
    var ranges_given = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const value = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "-o")) {
            output = value;
            i += 1;
        } else if (std.mem.eql(u8, a, "--sizes")) {
            var it = std.mem.splitScalar(u8, value, ',');
            while (it.next()) |s| try sizes.append(arena, std.fmt.parseInt(u16, std.mem.trim(u8, s, " "), 10) catch return usage("bad size"));
            i += 1;
        } else if (std.mem.eql(u8, a, "--chars")) {
            ranges_given = true;
            try parseRanges(arena, value, &chars);
            i += 1;
        } else if (std.mem.eql(u8, a, "--text")) {
            var view = std.unicode.Utf8View.init(value) catch return usage("--text is not UTF-8");
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| try chars.append(arena, cp);
            i += 1;
        } else if (a.len > 0 and a[0] != '-') {
            input = a;
        } else return usage("unknown option");
    }
    const in_path = input orelse return usage("no input font");
    const out_path = output orelse return usage("no output (-o)");
    if (sizes.items.len == 0) return usage("no --sizes");
    if (!ranges_given) try parseRanges(arena, "20-7e,2026", &chars);

    // Sorted, without duplicates.
    std.mem.sort(u21, chars.items, {}, std.sort.asc(u21));
    var unique: std.ArrayList(u21) = .empty;
    for (chars.items) |cp| if (unique.items.len == 0 or unique.items[unique.items.len - 1] != cp) try unique.append(arena, cp);

    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(init.io, in_path, arena, .limited(64 << 20)) catch |err| {
        std.debug.print("zigulee-bitmap-font: cannot read {s}: {t}\n", .{ in_path, err });
        return 1;
    };
    const font: zigulee.Font = zigulee.Font.init(data) catch |err| {
        std.debug.print("zigulee-bitmap-font: {s}: {t}\n", .{ in_path, err });
        return 1;
    };
    var missing: usize = 0;
    for (unique.items) |cp| missing += @intFromBool(font.glyphIndex(cp) == 0);
    if (missing > 0) std.debug.print("zigulee-bitmap-font: {d} character(s) not in {s} (shown as the missing glyph)\n", .{ missing, in_path });
    const bytes = zigulee.software.makeBitmapFont(arena, &font, sizes.items, unique.items) catch |err| {
        std.debug.print("zigulee-bitmap-font: {t}\n", .{err});
        return 1;
    };
    try cwd.writeFile(init.io, .{ .sub_path = out_path, .data = bytes });
    return 0;
}

fn parseRanges(arena: std.mem.Allocator, spec: []const u8, out: *std.ArrayList(u21)) !void {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        const r = std.mem.trim(u8, raw, " ");
        if (r.len == 0) continue;
        const dash = std.mem.indexOfScalar(u8, r, '-');
        const first = try std.fmt.parseInt(u21, if (dash) |d| r[0..d] else r, 16);
        const last = if (dash) |d| try std.fmt.parseInt(u21, r[d + 1 ..], 16) else first;
        if (last < first or last - first > 0x10000) return error.BadRange;
        var cp = first;
        while (cp <= last) : (cp += 1) try out.append(arena, cp);
    }
}

fn usage(why: []const u8) u8 {
    std.debug.print("zigulee-bitmap-font: {s}\nusage: zigulee-bitmap-font in.ttf -o out.zbf --sizes 13,16 [--chars 20-7e,2026] [--text \"°€\"]\n", .{why});
    return 2;
}
