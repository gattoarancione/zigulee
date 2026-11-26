// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! File dialogs with AppKit: NSOpenPanel and NSSavePanel, shown modally
//! (`runModal`: the answer comes before `show` returns).

const std = @import("std");
const zigulee = @import("zigulee");
const objc = @import("zigulee-apple").objc;
const dialogs = zigulee.core.dialogs;
const id = objc.id;
const msg = objc.msg;
const class = objc.class;

pub const provider: dialogs.Provider = .{ .show = show };

const modal_ok = 1;

fn show(_: ?*anyopaque, p: *dialogs.Pending) void {
    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);
    const r = p.request;
    const saving = r.mode == .save_file;
    const panel = if (saving) msg(id, class("NSSavePanel"), "savePanel", .{}) else msg(id, class("NSOpenPanel"), "openPanel", .{});
    if (panel == null) return p.finish(&.{});
    if (!saving) {
        msg(void, panel, "setCanChooseFiles:", .{r.mode != .open_folder});
        msg(void, panel, "setCanChooseDirectories:", .{r.mode == .open_folder});
        msg(void, panel, "setAllowsMultipleSelection:", .{r.mode == .open_files});
    }
    if (r.title.len > 0) {
        msg(void, panel, "setTitle:", .{objc.nsString(r.title)});
        msg(void, panel, "setMessage:", .{objc.nsString(r.title)});
    }
    if (r.folder.len > 0) msg(void, panel, "setDirectoryURL:", .{msg(id, class("NSURL"), "fileURLWithPath:", .{objc.nsString(r.folder)})});
    if (saving and r.file_name.len > 0) msg(void, panel, "setNameFieldStringValue:", .{objc.nsString(r.file_name)});
    if (r.mode != .open_folder) allowTypes(panel, r.filters);

    msg(void, msg(id, class("NSApplication"), "sharedApplication", .{}), "activateIgnoringOtherApps:", .{true});
    if (msg(isize, panel, "runModal", .{}) != modal_ok) return p.finish(&.{});

    var paths: [256][]const u8 = undefined;
    var n: usize = 0;
    if (saving) {
        const url = msg(id, panel, "URL", .{});
        if (url != null) {
            paths[0] = objc.utf8(msg(id, url, "path", .{}));
            n = 1;
        }
    } else {
        const urls = msg(id, panel, "URLs", .{});
        const count = msg(usize, urls, "count", .{});
        while (n < count and n < paths.len) : (n += 1) {
            paths[n] = objc.utf8(msg(id, msg(id, urls, "objectAtIndex:", .{n}), "path", .{}));
        }
    }
    p.finish(paths[0..n]);
}

/// Only files with the filters' extensions (all of them: the panel has no
/// choice of filter), unless one of them takes any file.
fn allowTypes(panel: id, filters: []const dialogs.Filter) void {
    if (filters.len == 0) return;
    const ut = class("UTType");
    if (ut == null) return; // before macOS 11
    const types = msg(id, class("NSMutableArray"), "array", .{});
    for (filters) |f| {
        for (f.patterns) |pat| if (std.mem.eql(u8, pat, "*") or std.mem.eql(u8, pat, "*.*")) return;
        var buf: [32][]const u8 = undefined;
        for (f.extensions(&buf)) |ext| {
            const t = msg(id, ut, "typeWithFilenameExtension:", .{objc.nsString(ext)});
            if (t != null) msg(void, types, "addObject:", .{t});
        }
    }
    if (msg(usize, types, "count", .{}) > 0) msg(void, panel, "setAllowedContentTypes:", .{types});
}
