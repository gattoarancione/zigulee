// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! File dialogs through SDL: the platform's own (macOS panels, Windows
//! file dialogs, the Linux desktop portal or zenity). SDL answers
//! asynchronously, possibly from another thread; `Pending.finish` takes
//! that (the answer is handed over on the UI thread).

const std = @import("std");
const zigulee = @import("zigulee");
const c = @import("sdl3_c");
const dialogs = zigulee.core.dialogs;

const log = std.log.scoped(.zigulee_sdl3);

pub const provider: dialogs.Provider = .{ .show = show };

fn show(_: ?*anyopaque, p: *dialogs.Pending) void {
    const r = p.request;
    const a = p.arena.allocator();
    // SDL's filters ("png;jpg"), kept until the answer (in the request's
    // arena).
    const filters = a.alloc(c.SDL_DialogFileFilter, r.filters.len) catch return p.finish(&.{});
    var count: usize = 0;
    for (r.filters) |f| {
        var exts: [16][]const u8 = undefined;
        const list = f.extensions(&exts);
        const all = for (f.patterns) |pat| {
            if (std.mem.eql(u8, pat, "*") or std.mem.eql(u8, pat, "*.*")) break true;
        } else false;
        const pattern = if (all) "*" else std.mem.join(a, ";", list) catch return p.finish(&.{});
        if (pattern.len == 0) continue;
        filters[count] = .{
            .name = (a.dupeZ(u8, f.name) catch return p.finish(&.{})).ptr,
            .pattern = (a.dupeZ(u8, pattern) catch return p.finish(&.{})).ptr,
        };
        count += 1;
    }
    // Where it starts: the folder, and the name to save as.
    const location: ?[:0]const u8 = if (r.mode == .save_file and r.file_name.len > 0)
        (if (r.folder.len > 0) std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ r.folder, r.file_name }, 0) else a.dupeZ(u8, r.file_name)) catch null
    else if (r.folder.len > 0) a.dupeZ(u8, r.folder) catch null else null;

    const props = c.SDL_CreateProperties();
    if (props == 0) return p.finish(&.{});
    defer c.SDL_DestroyProperties(props);
    if (count > 0) {
        _ = c.SDL_SetPointerProperty(props, c.SDL_PROP_FILE_DIALOG_FILTERS_POINTER, filters.ptr);
        _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_FILE_DIALOG_NFILTERS_NUMBER, @intCast(count));
    }
    if (c.SDL_GetKeyboardFocus()) |window| _ = c.SDL_SetPointerProperty(props, c.SDL_PROP_FILE_DIALOG_WINDOW_POINTER, window);
    if (location) |l| _ = c.SDL_SetStringProperty(props, c.SDL_PROP_FILE_DIALOG_LOCATION_STRING, l.ptr);
    _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_FILE_DIALOG_MANY_BOOLEAN, r.mode == .open_files);
    if (r.title.len > 0) if (a.dupeZ(u8, r.title)) |t| {
        _ = c.SDL_SetStringProperty(props, c.SDL_PROP_FILE_DIALOG_TITLE_STRING, t.ptr);
    } else |_| {};
    const kind: c.SDL_FileDialogType = switch (r.mode) {
        .open_file, .open_files => c.SDL_FILEDIALOG_OPENFILE,
        .open_folder => c.SDL_FILEDIALOG_OPENFOLDER,
        .save_file => c.SDL_FILEDIALOG_SAVEFILE,
    };
    c.SDL_ShowFileDialogWithProperties(kind, answered, p, props);
}

/// SDL's answer (any thread): the files, none if cancelled, null on error.
fn answered(userdata: ?*anyopaque, list: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    const p: *dialogs.Pending = @ptrCast(@alignCast(userdata));
    if (list == null) {
        log.info("file dialog failed: {s}", .{std.mem.span(c.SDL_GetError())});
        return p.finish(&.{});
    }
    var files: [256][]const u8 = undefined;
    var n: usize = 0;
    while (list[n] != null and n < files.len) : (n += 1) files[n] = std.mem.span(list[n]);
    p.finish(files[0..n]);
}
