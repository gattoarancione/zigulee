// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The Objective-C runtime, from Zig: sending messages, making classes at
//! run time, and the Foundation types used by the macOS backend.

const std = @import("std");
const builtin = @import("builtin");

pub const id = ?*anyopaque;
pub const SEL = ?*anyopaque;
pub const Class = ?*anyopaque;
pub const BOOL = bool;

pub extern "c" fn objc_getClass(name: [*:0]const u8) Class;
pub extern "c" fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;
pub extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
pub extern "c" fn objc_msgSend() void;
pub extern "c" fn objc_msgSend_stret() void;
pub extern "c" fn objc_msgSendSuper() void;
pub extern "c" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra: usize) Class;
pub extern "c" fn objc_registerClassPair(cls: Class) void;
pub extern "c" fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) BOOL;
pub extern "c" fn class_addIvar(cls: Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) BOOL;
pub extern "c" fn class_addProtocol(cls: Class, protocol: ?*anyopaque) BOOL;
pub extern "c" fn class_getInstanceVariable(cls: Class, name: [*:0]const u8) ?*anyopaque;
pub extern "c" fn ivar_getOffset(ivar: ?*anyopaque) isize;
pub extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
pub extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

pub const NSPoint = extern struct { x: f64 = 0, y: f64 = 0 };
pub const NSSize = extern struct { width: f64 = 0, height: f64 = 0 };
pub const NSRect = extern struct { origin: NSPoint = .{}, size: NSSize = .{} };
pub const NSRange = extern struct { location: usize = 0, length: usize = 0 };
/// NSNotFound.
pub const not_found: usize = @bitCast(@as(isize, std.math.maxInt(isize)));

pub fn sel(name: [:0]const u8) SEL {
    return sel_registerName(name.ptr);
}

pub fn class(name: [:0]const u8) id {
    return objc_getClass(name.ptr);
}

fn Send(comptime Ret: type, comptime Args: type) type {
    const fields = @typeInfo(Args).@"struct".fields;
    var params: [fields.len + 2]type = undefined;
    params[0] = id;
    params[1] = SEL;
    for (fields, 0..) |f, i| params[i + 2] = f.type;
    const attrs: [params.len]std.builtin.Type.Fn.Param.Attributes = @splat(.{});
    const final = params;
    return *const @Fn(&final, &attrs, Ret, .{ .@"callconv" = .c });
}

/// `[obj name:args...]`, returning `Ret`.
pub fn msg(comptime Ret: type, obj: anytype, name: [:0]const u8, args: anytype) Ret {
    const stret = builtin.cpu.arch == .x86_64 and @sizeOf(Ret) > 16;
    const target: *const anyopaque = if (stret) @ptrCast(&objc_msgSend_stret) else @ptrCast(&objc_msgSend);
    const f: Send(Ret, @TypeOf(args)) = @ptrCast(@alignCast(target));
    return @call(.auto, f, .{ @as(id, @ptrCast(obj)), sel(name) } ++ args);
}

/// `[super name:args...]` from a method of `cls` (the class `obj` is an
/// instance of, or of a subclass).
pub fn msgSuper(comptime Ret: type, obj: id, cls: Class, name: [:0]const u8, args: anytype) Ret {
    const Super = extern struct { receiver: id, super_class: Class };
    const superclass = msg(Class, cls, "superclass", .{});
    var s: Super = .{ .receiver = obj, .super_class = superclass };
    const f: Send(Ret, @TypeOf(args)) = @ptrCast(@alignCast(&objc_msgSendSuper));
    return @call(.auto, f, .{ @as(id, @ptrCast(&s)), sel(name) } ++ args);
}

/// An autoreleased NSString with `s`'s text.
pub fn nsString(s: []const u8) id {
    const str = msg(id, class("NSString"), "alloc", .{});
    const initialized = msg(id, str, "initWithBytes:length:encoding:", .{ s.ptr, s.len, @as(usize, 4) }); // UTF-8
    return msg(id, initialized, "autorelease", .{});
}

/// The UTF-8 text of an NSString (valid while the string is).
pub fn utf8(s: id) []const u8 {
    if (s == null) return "";
    const p = msg(?[*:0]const u8, s, "UTF8String", .{}) orelse return "";
    return std.mem.span(p);
}

/// A pointer-sized instance variable at `offset` in object `obj`.
pub fn ivarPtr(obj: id, offset: isize) *?*anyopaque {
    const base: [*]u8 = @ptrCast(obj.?);
    return @ptrCast(@alignCast(base + @as(usize, @intCast(offset))));
}

// ---- Blocks ----

extern const _NSConcreteGlobalBlock: anyopaque;

/// An Objective-C block: a global one made here (a function, no captured
/// variables), or one given to us to call.
pub const Block = extern struct {
    isa: ?*const anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const anyopaque,
    descriptor: *const Descriptor,

    const Descriptor = extern struct { reserved: c_ulong = 0, size: c_ulong = @sizeOf(Block) };
    const is_global = 1 << 28;
    const the_descriptor: Descriptor = .{};

    /// A block calling `invoke` (its first parameter is the block).
    pub fn global(invoke: *const anyopaque) Block {
        return .{ .isa = &_NSConcreteGlobalBlock, .flags = is_global, .reserved = 0, .invoke = invoke, .descriptor = &the_descriptor };
    }

    /// Calls a block given to us, with no argument or one word.
    pub fn call(b: ?*Block, args: anytype) void {
        const blk = b orelse return;
        const Fn = switch (@typeInfo(@TypeOf(args)).@"struct".fields.len) {
            0 => *const fn (*Block) callconv(.c) void,
            else => *const fn (*Block, usize) callconv(.c) void,
        };
        const f: Fn = @ptrCast(@alignCast(blk.invoke));
        @call(.auto, f, .{blk} ++ args);
    }
};

// ---- Dispatch ----

pub const dispatch_queue_t = ?*anyopaque;
extern var _dispatch_main_q: anyopaque;
pub extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) dispatch_queue_t;
pub extern "c" fn dispatch_release(obj: ?*anyopaque) void;
pub extern "c" fn dispatch_async_f(queue: dispatch_queue_t, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
pub extern "c" fn dispatch_sync_f(queue: dispatch_queue_t, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

/// The main thread's queue.
pub fn mainQueue() dispatch_queue_t {
    return &_dispatch_main_q;
}

test "messages, with any number of arguments" {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    const s = nsString("héllo");
    try std.testing.expectEqual(@as(usize, 5), msg(usize, s, "length", .{}));
    try std.testing.expectEqualStrings("héllo", utf8(s));
    const sub = msg(id, s, "substringWithRange:", .{NSRange{ .location = 1, .length = 2 }});
    try std.testing.expectEqualStrings("él", utf8(sub));
}
