// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The Windows registry under `HKEY_CURRENT_USER`: keys opened or made by
//! path (`\` or `/` between keys), their values read, written and deleted,
//! their subkeys and value names listed (where `Settings` keeps its values
//! with `format: registry`). Elsewhere (`supported` false) no key opens.
//! Strings are UTF-8; temporary conversions go in the allocator given.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Whether there is a registry here.
pub const supported = builtin.os.tag == .windows;

/// A value: numbers (DWORD values, signed; QWORD values), strings
/// (REG_SZ, REG_EXPAND_SZ, unexpanded), or something else (binary data,
/// string lists).
pub const Value = union(enum) {
    number: i64,
    text: []const u8,
    other,
};

pub const Error = error{ RegistryFailed, Unsupported, InvalidUtf8 } || Allocator.Error;

const hkey_current_user: usize = 0x80000001;
const key_read: u32 = 0x20019;
const key_all: u32 = 0x2001F; // KEY_READ | KEY_WRITE
const reg_sz: u32 = 1;
const reg_expand_sz: u32 = 2;
const reg_dword: u32 = 4;
const reg_qword: u32 = 11;
const error_no_more_items: i32 = 259;
const error_more_data: i32 = 234;
/// The longest key name, in UTF-16 units.
const max_key_name = 255;
/// The longest value name, in UTF-16 units.
const max_value_name = 16383;

// The predefined keys are not aligned pointers: keys are numbers here.
extern "advapi32" fn RegOpenKeyExW(key: usize, sub_key: [*:0]const u16, options: u32, sam: u32, result: *usize) callconv(.winapi) i32;
extern "advapi32" fn RegCreateKeyExW(key: usize, sub_key: [*:0]const u16, reserved: u32, class: ?[*:0]const u16, options: u32, sam: u32, security: ?*anyopaque, result: *usize, disposition: ?*u32) callconv(.winapi) i32;
extern "advapi32" fn RegQueryValueExW(key: usize, name: [*:0]const u16, reserved: ?*u32, kind: ?*u32, data: ?[*]u8, size: ?*u32) callconv(.winapi) i32;
extern "advapi32" fn RegSetValueExW(key: usize, name: [*:0]const u16, reserved: u32, kind: u32, data: [*]const u8, size: u32) callconv(.winapi) i32;
extern "advapi32" fn RegDeleteValueW(key: usize, name: [*:0]const u16) callconv(.winapi) i32;
extern "advapi32" fn RegDeleteTreeW(key: usize, sub_key: ?[*:0]const u16) callconv(.winapi) i32;
extern "advapi32" fn RegEnumKeyExW(key: usize, index: u32, name: [*]u16, name_len: *u32, reserved: ?*u32, class: ?[*]u16, class_len: ?*u32, last_write: ?*anyopaque) callconv(.winapi) i32;
extern "advapi32" fn RegEnumValueW(key: usize, index: u32, name: [*]u16, name_len: *u32, reserved: ?*u32, kind: ?*u32, data: ?[*]u8, data_len: ?*u32) callconv(.winapi) i32;
extern "advapi32" fn RegCloseKey(key: usize) callconv(.winapi) i32;

/// `path` with `\` between keys, in UTF-16.
fn widePath(a: Allocator, path: []const u8) error{ InvalidUtf8, OutOfMemory }![:0]u16 {
    const w = try std.unicode.utf8ToUtf16LeAllocZ(a, std.mem.trim(u8, path, "/\\"));
    std.mem.replaceScalar(u16, w, '/', '\\');
    return w;
}

/// `path` for reading; null if it is not there.
pub fn open(a: Allocator, path: []const u8) ?Key {
    if (!supported) return null;
    const w = widePath(a, path) catch return null;
    var h: usize = 0;
    if (RegOpenKeyExW(hkey_current_user, w, 0, key_read, &h) != 0) return null;
    return .{ .handle = h };
}

/// `path` for reading and writing, made (with the keys above it) if
/// needed.
pub fn create(a: Allocator, path: []const u8) Error!Key {
    if (!supported) return error.Unsupported;
    const w = try widePath(a, path);
    var h: usize = 0;
    if (RegCreateKeyExW(hkey_current_user, w, 0, null, 0, key_all, null, &h, null) != 0) return error.RegistryFailed;
    return .{ .handle = h };
}

/// Deletes `path` with everything in it; false if it could not (it was
/// not there, say).
pub fn deleteTree(a: Allocator, path: []const u8) bool {
    if (!supported) return false;
    const w = widePath(a, path) catch return false;
    if (w.len == 0) return false; // never HKEY_CURRENT_USER itself
    return RegDeleteTreeW(hkey_current_user, w) == 0;
}

/// An open key: `close` it.
pub const Key = struct {
    handle: usize,

    pub fn close(k: Key) void {
        if (supported) _ = RegCloseKey(k.handle);
    }

    /// The value `name` ("" for the key's default value); null if it has
    /// none. Strings are allocated with `a`.
    pub fn get(k: Key, a: Allocator, name: []const u8) ?Value {
        if (!supported) return null;
        const wname = std.unicode.utf8ToUtf16LeAllocZ(a, name) catch return null;
        var kind: u32 = 0;
        var size: u32 = 0;
        if (RegQueryValueExW(k.handle, wname, null, &kind, null, &size) != 0) return null;
        const data = a.alignedAlloc(u8, .of(u16), size) catch return null;
        if (RegQueryValueExW(k.handle, wname, null, &kind, data.ptr, &size) != 0) return null;
        const bytes = data[0..@min(size, data.len)];
        return switch (kind) {
            reg_dword => if (bytes.len >= 4) .{ .number = @as(i32, @bitCast(std.mem.readInt(u32, bytes[0..4], .little))) } else .other,
            reg_qword => if (bytes.len >= 8) .{ .number = @bitCast(std.mem.readInt(u64, bytes[0..8], .little)) } else .other,
            reg_sz, reg_expand_sz => blk: {
                var units: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, bytes[0 .. bytes.len & ~@as(usize, 1)]));
                while (units.len > 0 and units[units.len - 1] == 0) units = units[0 .. units.len - 1];
                break :blk .{ .text = std.unicode.utf16LeToUtf8Alloc(a, units) catch return null };
            },
            else => .other,
        };
    }

    fn set(k: Key, a: Allocator, name: []const u8, kind: u32, data: []const u8) Error!void {
        if (!supported) return error.Unsupported;
        const wname = try std.unicode.utf8ToUtf16LeAllocZ(a, name);
        if (RegSetValueExW(k.handle, wname, 0, kind, data.ptr, @intCast(data.len)) != 0) return error.RegistryFailed;
    }

    /// A DWORD value.
    pub fn setDword(k: Key, a: Allocator, name: []const u8, v: u32) Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try k.set(a, name, reg_dword, &b);
    }

    /// A QWORD value.
    pub fn setQword(k: Key, a: Allocator, name: []const u8, v: u64) Error!void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try k.set(a, name, reg_qword, &b);
    }

    /// A string (REG_SZ) value.
    pub fn setString(k: Key, a: Allocator, name: []const u8, v: []const u8) Error!void {
        const w = try std.unicode.utf8ToUtf16LeAllocZ(a, v);
        // With its terminating zero.
        try k.set(a, name, reg_sz, std.mem.sliceAsBytes(w.ptr[0 .. w.len + 1]));
    }

    /// Deletes the value `name`; false if it was not there.
    pub fn deleteValue(k: Key, a: Allocator, name: []const u8) bool {
        if (!supported) return false;
        const wname = std.unicode.utf8ToUtf16LeAllocZ(a, name) catch return false;
        return RegDeleteValueW(k.handle, wname) == 0;
    }

    /// The names of its subkeys, allocated with `a`.
    pub fn subkeys(k: Key, a: Allocator) Error![]const []const u8 {
        if (!supported) return error.Unsupported;
        var names: std.ArrayList([]const u8) = .empty;
        var buf: [max_key_name + 1]u16 = undefined;
        var i: u32 = 0;
        while (true) : (i += 1) {
            var len: u32 = buf.len;
            const r = RegEnumKeyExW(k.handle, i, &buf, &len, null, null, null, null);
            if (r == error_no_more_items) break;
            if (r != 0) return error.RegistryFailed;
            try names.append(a, std.unicode.utf16LeToUtf8Alloc(a, buf[0..len]) catch return error.RegistryFailed);
        }
        return names.items;
    }

    /// The names of its values (not the default value's), allocated with
    /// `a`.
    pub fn valueNames(k: Key, a: Allocator) Error![]const []const u8 {
        if (!supported) return error.Unsupported;
        var names: std.ArrayList([]const u8) = .empty;
        const buf = try a.alloc(u16, max_value_name + 1);
        var i: u32 = 0;
        while (true) : (i += 1) {
            var len: u32 = @intCast(buf.len);
            const r = RegEnumValueW(k.handle, i, buf.ptr, &len, null, null, null, null);
            if (r == error_no_more_items) break;
            if (r != 0 and r != error_more_data) return error.RegistryFailed;
            if (len == 0) continue;
            try names.append(a, std.unicode.utf16LeToUtf8Alloc(a, buf[0..len]) catch return error.RegistryFailed);
        }
        return names.items;
    }
};

test "registry: keys made, values written, read, listed and deleted" {
    if (!supported) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = "Software/zigulee-test-registry";
    _ = deleteTree(a, root);
    defer _ = deleteTree(a, root);

    try std.testing.expect(open(a, root) == null);
    const k = try create(a, root ++ "/inner");
    try k.setDword(a, "n", @bitCast(@as(i32, -3)));
    try k.setQword(a, "big", 1 << 40);
    try k.setString(a, "s", "hé\nllo");
    k.close();
    (try create(a, root ++ "\\other")).close();

    const r = open(a, root).?;
    defer r.close();
    const subs = try r.subkeys(a);
    try std.testing.expectEqual(@as(usize, 2), subs.len);
    try std.testing.expectEqualStrings("inner", subs[0]);
    try std.testing.expectEqualStrings("other", subs[1]);

    const inner = open(a, root ++ "/inner").?;
    defer inner.close();
    try std.testing.expectEqual(@as(i64, -3), inner.get(a, "n").?.number);
    try std.testing.expectEqual(@as(i64, 1 << 40), inner.get(a, "big").?.number);
    try std.testing.expectEqualStrings("hé\nllo", inner.get(a, "s").?.text);
    try std.testing.expect(inner.get(a, "nope") == null);
    try std.testing.expectEqual(@as(usize, 3), (try inner.valueNames(a)).len);
    try std.testing.expect(inner.deleteValue(a, "n"));
    try std.testing.expect(!inner.deleteValue(a, "n"));
    try std.testing.expectEqual(@as(usize, 2), (try inner.valueNames(a)).len);
}
