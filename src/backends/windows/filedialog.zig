// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! File dialogs with the Windows shell: IFileOpenDialog and
//! IFileSaveDialog, shown modally over the active window (the answer comes
//! before `show` returns). COM is the UI thread's (initialized by the
//! backend for UI Automation, or here).

const std = @import("std");
const zigulee = @import("zigulee");
const c = @import("win32_c");
const dialogs = zigulee.core.dialogs;

const log = std.log.scoped(.zigulee_windows);

pub const provider: dialogs.Provider = .{ .show = show };

fn guid(a: u32, b: u16, cc: u16, d: [8]u8) c.GUID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = cc, .Data4 = d };
}
// From shobjidl.h.
const clsid_open = guid(0xdc1c5a9c, 0xe88a, 0x4dde, .{ 0xa5, 0xa1, 0x60, 0xf8, 0x2a, 0x20, 0xae, 0xf7 });
const clsid_save = guid(0xc0b4e2f3, 0xba21, 0x4773, .{ 0x8d, 0xba, 0x33, 0x5e, 0xc9, 0x46, 0xeb, 0x8b });
const iid_open = guid(0xd57c7288, 0xd4ad, 0x4768, .{ 0xbe, 0x02, 0x9d, 0x96, 0x95, 0x32, 0xd9, 0x60 });
const iid_save = guid(0x84bccd23, 0x5fde, 0x4cdb, .{ 0xae, 0xa4, 0xaf, 0x64, 0xb8, 0x3d, 0x78, 0xab });
const iid_item = guid(0x43826d1e, 0xe718, 0x42ee, .{ 0xbc, 0x55, 0xa1, 0xe2, 0x61, 0xc3, 0x7b, 0xfe });

const fos_overwrite_prompt = 0x2;
const fos_pick_folders = 0x20;
const fos_force_file_system = 0x40;
const fos_allow_multiselect = 0x200;
const sigdn_file_sys_path: c_int = @bitCast(@as(u32, 0x80058000));

/// Releases a COM object (or nothing, given null).
fn release(obj: anytype) void {
    if (@typeInfo(@TypeOf(obj)) == .optional) {
        if (obj) |o| _ = o.*.lpVtbl.*.Release.?(o);
    } else _ = obj.*.lpVtbl.*.Release.?(obj);
}

fn show(_: ?*anyopaque, p: *dialogs.Pending) void {
    run(p) catch |err| {
        log.info("file dialog: {t}", .{err});
        p.finish(&.{});
    };
}

fn run(p: *dialogs.Pending) !void {
    const com = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    defer if (com >= 0) c.CoUninitialize();
    const r = p.request;
    const a = p.arena.allocator();
    const saving = r.mode == .save_file;

    // Both dialogs start as IFileDialog: the open one as its subtype.
    var dialog: ?*c.IFileDialog = null;
    if (c.CoCreateInstance(if (saving) &clsid_save else &clsid_open, null, c.CLSCTX_INPROC_SERVER, if (saving) &iid_save else &iid_open, @ptrCast(&dialog)) < 0) return error.NoDialog;
    defer release(dialog);
    const d = dialog.?;
    const vt = d.*.lpVtbl.*;

    var options: c.FILEOPENDIALOGOPTIONS = 0;
    _ = vt.GetOptions.?(d, &options);
    options |= fos_force_file_system;
    if (r.mode == .open_files) options |= fos_allow_multiselect;
    if (r.mode == .open_folder) options |= fos_pick_folders;
    if (saving) options |= fos_overwrite_prompt;
    _ = vt.SetOptions.?(d, options);
    if (r.title.len > 0) _ = vt.SetTitle.?(d, try wide(a, r.title));
    if (saving and r.file_name.len > 0) _ = vt.SetFileName.?(d, try wide(a, r.file_name));
    if (r.folder.len > 0) {
        var folder: ?*c.IShellItem = null;
        if (c.SHCreateItemFromParsingName(try wide(a, r.folder), null, &iid_item, @ptrCast(&folder)) >= 0) {
            _ = vt.SetFolder.?(d, folder);
            release(folder);
        }
    }
    if (r.mode != .open_folder and r.filters.len > 0) {
        // "Images" with "*.png;*.jpg".
        const specs = try a.alloc(c.COMDLG_FILTERSPEC, r.filters.len);
        for (specs, r.filters) |*s, f| s.* = .{
            .pszName = try wide(a, f.name),
            .pszSpec = try wide(a, try std.mem.join(a, ";", f.patterns)),
        };
        _ = vt.SetFileTypes.?(d, @intCast(specs.len), specs.ptr);
        if (saving) {
            // The extension added to a name typed without one.
            var buf: [8][]const u8 = undefined;
            const exts = r.filters[0].extensions(&buf);
            if (exts.len > 0) _ = vt.SetDefaultExtension.?(d, try wide(a, exts[0]));
        }
    }

    const hr = vt.Show.?(d, c.GetActiveWindow());
    if (hr < 0) return p.finish(&.{}); // cancelled (or failed)

    var paths: std.ArrayList([]const u8) = .empty;
    if (r.mode == .open_files) {
        const open: *c.IFileOpenDialog = @ptrCast(d);
        var items: ?*c.IShellItemArray = null;
        if (open.*.lpVtbl.*.GetResults.?(open, &items) < 0) return p.finish(&.{});
        defer release(items);
        var count: c.DWORD = 0;
        _ = items.?.*.lpVtbl.*.GetCount.?(items, &count);
        for (0..count) |i| {
            var item: ?*c.IShellItem = null;
            if (items.?.*.lpVtbl.*.GetItemAt.?(items, @intCast(i), &item) < 0) continue;
            defer release(item);
            if (try path(a, item.?)) |s| try paths.append(a, s);
        }
    } else {
        var item: ?*c.IShellItem = null;
        if (vt.GetResult.?(d, &item) < 0) return p.finish(&.{});
        defer release(item);
        if (try path(a, item.?)) |s| try paths.append(a, s);
    }
    p.finish(paths.items);
}

/// A shell item's file system path, in UTF-8.
fn path(a: std.mem.Allocator, item: *c.IShellItem) !?[]const u8 {
    var name: c.LPWSTR = null;
    if (item.*.lpVtbl.*.GetDisplayName.?(item, sigdn_file_sys_path, &name) < 0 or name == null) return null;
    defer c.CoTaskMemFree(name);
    const span = std.mem.span(@as([*:0]const u16, @ptrCast(name)));
    return try std.unicode.utf16LeToUtf8Alloc(a, span);
}

fn wide(a: std.mem.Allocator, s: []const u8) ![*:0]const u16 {
    return (try std.unicode.utf8ToUtf16LeAllocZ(a, s)).ptr;
}
