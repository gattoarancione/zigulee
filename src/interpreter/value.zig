// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Values of the interpreter: what `.zge` expressions evaluate to, tagged
//! with their `.zge` type. The arithmetic and conversion rules are those of
//! the generated code (see compiler/codegen.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const types = @import("../compiler/types.zig");
const Type = types.Type;

pub const Value = union(enum) {
    void,
    int: i32,
    float: f32,
    length: f32,
    duration: i64,
    bool: bool,
    string: []const u8,
    color: zigulee.Color,
    brush: zigulee.Brush,
    image: core.Image,
    audio: core.Audio,
    video: core.Video,
    model3d: core.Model3D,
    component: core.loader.Component,
    easing: zigulee.Easing,
    enumeration: Enum,
    key_event: core.input.KeyEvent,
    pointer_event: core.input.TouchAreaEvent,
    modifiers: core.input.Modifiers,
    model: zigulee.Model(Value),
    structure: Struct,

    pub const Enum = struct {
        def: *const types.Enum,
        index: u32,

        pub fn zigTag(e: Enum) []const u8 {
            return e.def.values[e.index][1];
        }
    };

    pub const Struct = struct {
        def: *const types.StructDef,
        /// In the order of `def.fields`.
        fields: []const Value,
    };

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .void => true,
            .string => |s| std.mem.eql(u8, s, b.string),
            .brush => |br| br.eql(b.brush),
            .enumeration => |e| e.def == b.enumeration.def and e.index == b.enumeration.index,
            .model => |m| m.ptr == b.model.ptr and m.vtable == b.model.vtable,
            .structure => |s| blk: {
                if (s.def != b.structure.def) break :blk false;
                for (s.fields, b.structure.fields) |x, y| if (!x.eql(y)) break :blk false;
                break :blk true;
            },
            .key_event => |k| std.mem.eql(u8, k.text, b.key_event.text) and std.meta.eql(k.modifiers, b.key_event.modifiers) and k.repeat == b.key_event.repeat,
            .image => |img| img.eql(b.image),
            .audio => |clip| clip.eql(b.audio),
            .video => |v| v.eql(b.video),
            .model3d => |m| m.eql(b.model3d),
            inline else => |v, tag| std.meta.eql(v, @field(b, @tagName(tag))),
        };
    }

    /// The value as a number (int, float, length or duration), as f32.
    pub fn asFloat(v: Value) f32 {
        return switch (v) {
            .int => |i| @floatFromInt(i),
            .float, .length => |f| f,
            .duration => |d| @floatFromInt(d),
            else => 0,
        };
    }

    pub fn asBool(v: Value) bool {
        return v == .bool and v.bool;
    }

    pub fn isNumeric(v: Value) bool {
        return v == .int or v == .float or v == .length or v == .duration;
    }

    /// Copies strings and struct fields into `arena`.
    pub fn clone(v: Value, arena: Allocator) Allocator.Error!Value {
        return switch (v) {
            .string => |s| .{ .string = try arena.dupe(u8, s) },
            .key_event => |k| .{ .key_event = .{ .text = try arena.dupe(u8, k.text), .modifiers = k.modifiers, .repeat = k.repeat } },
            .brush => |b| switch (b) {
                .solid => v,
                .linear_gradient => |g| blk: {
                    const copy = try arena.create(zigulee.core.LinearGradient);
                    copy.* = g.*;
                    copy.stops = .init(try arena.dupe(zigulee.core.GradientStop, g.stops.items));
                    break :blk .{ .brush = .{ .linear_gradient = copy } };
                },
                .radial_gradient => |g| blk: {
                    const copy = try arena.create(zigulee.core.RadialGradient);
                    copy.* = g.*;
                    copy.stops = .init(try arena.dupe(zigulee.core.GradientStop, g.stops.items));
                    break :blk .{ .brush = .{ .radial_gradient = copy } };
                },
            },
            .structure => |s| blk: {
                const fields = try arena.alloc(Value, s.fields.len);
                for (fields, s.fields) |*d, f| d.* = try f.clone(arena);
                break :blk .{ .structure = .{ .def = s.def, .fields = fields } };
            },
            else => v,
        };
    }

    /// Writes the value as string interpolation shows it.
    pub fn format(v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (v) {
            .string => |s| try w.writeAll(s),
            .int => |i| try w.print("{d}", .{i}),
            .float, .length => |f| try w.print("{d}", .{f}),
            .duration => |d| try w.print("{d}", .{d}),
            .bool => |b| try w.print("{}", .{b}),
            .enumeration => |e| try w.writeAll(e.def.values[e.index][0]),
            else => try w.print("{any}", .{v}),
        }
    }
};

/// A value of type `t` read from a Zig value of type `T` (a property's
/// storage).
pub fn fromZig(comptime T: type, x: T, t: Type) Value {
    return switch (T) {
        Value => x,
        i32 => .{ .int = x },
        f32 => if (t == .length) .{ .length = x } else .{ .float = x },
        i64 => .{ .duration = x },
        bool => .{ .bool = x },
        []const u8 => .{ .string = x },
        zigulee.Color => .{ .color = x },
        zigulee.Brush => .{ .brush = x },
        core.Image => .{ .image = x },
        core.Audio => .{ .audio = x },
        core.Video => .{ .video = x },
        core.Model3D => .{ .model3d = x },
        core.loader.Component => .{ .component = x },
        zigulee.Easing => .{ .easing = x },
        core.input.KeyEvent => .{ .key_event = x },
        core.input.TouchAreaEvent => .{ .pointer_event = x },
        core.input.Modifiers => .{ .modifiers = x },
        zigulee.Model(Value) => .{ .model = x },
        // Read through a property instead (reflect.zig's StringsAdapter).
        zigulee.Model([]const u8), zigulee.Model(i32), zigulee.Model(bool), zigulee.Model(zigulee.Color) => .{ .model = core.emptyModel(Value) },
        ?f32 => if (x) |f| fromZig(f32, f, t) else .{ .length = 0 },
        ?core.Image => if (x) |img| .{ .image = img } else .{ .image = empty_image },
        ?zigulee.Brush => if (x) |b| .{ .brush = b } else .{ .brush = .transparent },
        else => switch (@typeInfo(T)) {
            .@"enum" => .{ .enumeration = .{ .def = t.enumeration, .index = enumIndex(t.enumeration, @tagName(x)) } },
            else => @compileError("no value for " ++ @typeName(T)),
        },
    };
}

pub fn enumIndex(def: *const types.Enum, zig_tag: []const u8) u32 {
    for (def.values, 0..) |v, i| if (std.mem.eql(u8, v[1], zig_tag)) return @intCast(i);
    return 0;
}

/// `v` as a Zig value of type `T`, converting like the generated code
/// (ints to floats, colors to brushes, ...).
pub fn toZig(comptime T: type, v: Value) T {
    return switch (T) {
        Value => v,
        i32 => switch (v) {
            .int => |i| i,
            else => zigulee.core.intFromFloat(i32, v.asFloat()),
        },
        f32 => v.asFloat(),
        i64 => switch (v) {
            .duration => |d| d,
            .int => |i| i,
            else => zigulee.core.intFromFloat(i64, v.asFloat()),
        },
        bool => v.asBool(),
        []const u8 => if (v == .string) v.string else "",
        zigulee.Color => if (v == .color) v.color else .transparent,
        zigulee.Brush => switch (v) {
            .brush => |b| b,
            .color => |c| .color(c),
            else => .transparent,
        },
        core.Image => if (v == .image) v.image else empty_image,
        core.Audio => if (v == .audio) v.audio else .empty,
        core.Video => if (v == .video) v.video else .none,
        core.Model3D => if (v == .model3d) v.model3d else .none,
        core.loader.Component => if (v == .component) v.component else null,
        zigulee.Easing => if (v == .easing) v.easing else .linear,
        core.input.KeyEvent => if (v == .key_event) v.key_event else .{ .text = "" },
        core.input.TouchAreaEvent => if (v == .pointer_event) v.pointer_event else .{ .kind = .cancel },
        core.input.Modifiers => if (v == .modifiers) v.modifiers else .{},
        zigulee.Model(Value) => if (v == .model) v.model else core.emptyModel(Value),
        zigulee.Model([]const u8) => core.emptyModel([]const u8),
        // Set through an adapter instead (reflect.zig's ValueModelAdapter).
        zigulee.Model(i32) => core.emptyModel(i32),
        zigulee.Model(bool) => core.emptyModel(bool),
        zigulee.Model(f32) => core.emptyModel(f32),
        zigulee.Model(zigulee.Color) => core.emptyModel(zigulee.Color),
        ?f32 => v.asFloat(),
        ?core.Image => if (v == .image) v.image else null,
        ?zigulee.Brush => toZig(zigulee.Brush, v),
        else => switch (@typeInfo(T)) {
            .@"enum" => if (v == .enumeration) std.meta.stringToEnum(T, v.enumeration.zigTag()) orelse @enumFromInt(0) else @enumFromInt(0),
            else => @compileError("no conversion to " ++ @typeName(T)),
        },
    };
}

pub const empty_image: core.Image = .{ .width = 0, .height = 0, .pixels = &.{} };

/// The value a property of type `t` starts with.
pub fn defaultValue(t: Type, arena: Allocator) Allocator.Error!Value {
    return switch (t) {
        .void => .void,
        .int => .{ .int = 0 },
        .float => .{ .float = 0 },
        .length => .{ .length = 0 },
        .duration => .{ .duration = 0 },
        .bool => .{ .bool = false },
        .string => .{ .string = "" },
        .color => .{ .color = .transparent },
        .brush => .{ .brush = .transparent },
        .image => .{ .image = empty_image },
        .audio => .{ .audio = .empty },
        .video => .{ .video = .none },
        .model3d => .{ .model3d = .none },
        .component => .{ .component = null },
        .easing => .{ .easing = .linear },
        .enumeration => |e| .{ .enumeration = .{ .def = e, .index = 0 } },
        .key_event => .{ .key_event = .{ .text = "" } },
        .pointer_event => .{ .pointer_event = .{ .kind = .cancel } },
        .modifiers => .{ .modifiers = .{} },
        .model => .{ .model = core.emptyModel(Value) },
        .structure => |s| blk: {
            const fields = try arena.alloc(Value, s.fields.len);
            for (fields, s.fields) |*v, f| v.* = try defaultValue(f.ty, arena);
            break :blk .{ .structure = .{ .def = s, .fields = fields } };
        },
    };
}

/// `v` as type `to`, like `convert` in the generated code (the program was
/// checked, so only valid conversions happen).
pub fn convert(v: Value, to: Type) Value {
    return switch (to) {
        .float => if (v == .int) .{ .float = @floatFromInt(v.int) } else v,
        .length => switch (v) {
            .int => |i| .{ .length = @floatFromInt(i) },
            .float => |f| .{ .length = f },
            else => v,
        },
        .brush => if (v == .color) .{ .brush = .color(v.color) } else v,
        else => v,
    };
}

pub const ArithmeticError = error{InvalidOperands};

/// `a op b` for + - * / on numbers, with the generated code's result types:
/// int op int is int (except /), int/float mixes give float, lengths and
/// durations scale by numbers.
pub fn arithmetic(op: u8, a: Value, b: Value) ArithmeticError!Value {
    const num = struct {
        fn is(v: Value) bool {
            return v == .int or v == .float;
        }
    }.is;
    const Result = enum { int, float, length, duration };
    const result: Result = switch (op) {
        '+', '-' => blk: {
            if (std.meta.activeTag(a) == std.meta.activeTag(b)) switch (a) {
                .int => break :blk .int,
                .float => break :blk .float,
                .length => break :blk .length,
                .duration => break :blk .duration,
                else => {},
            };
            if (num(a) and num(b)) break :blk .float;
            return error.InvalidOperands;
        },
        '*' => blk: {
            if (a == .int and b == .int) break :blk .int;
            if (num(a) and num(b)) break :blk .float;
            if ((a == .length and num(b)) or (num(a) and b == .length)) break :blk .length;
            if ((a == .duration and num(b)) or (num(a) and b == .duration)) break :blk .duration;
            return error.InvalidOperands;
        },
        '/' => blk: {
            if (num(a) and num(b)) break :blk .float;
            if (a == .length and num(b)) break :blk .length;
            if (a == .length and b == .length) break :blk .float;
            if (a == .duration and num(b)) break :blk .duration;
            if (a == .duration and b == .duration) break :blk .float;
            return error.InvalidOperands;
        },
        else => return error.InvalidOperands,
    };
    switch (result) {
        .int => {
            const x = a.int;
            const y = b.int;
            return .{ .int = switch (op) {
                '+' => x +% y,
                '-' => x -% y,
                else => x *% y,
            } };
        },
        .duration => {
            // Scaled by a float: in floats, rounded to whole milliseconds.
            if ((op == '*' or op == '/') and (a == .float or b == .float)) {
                const fx: f64 = a.asFloat();
                const fy: f64 = b.asFloat();
                return .{ .duration = zigulee.core.intFromFloat(i64, @round(if (op == '*') fx * fy else fx / fy)) };
            }
            const x: i64 = if (a == .duration) a.duration else if (a == .int) a.int else zigulee.core.intFromFloat(i64, a.asFloat());
            const y: i64 = if (b == .duration) b.duration else if (b == .int) b.int else zigulee.core.intFromFloat(i64, b.asFloat());
            return .{ .duration = switch (op) {
                '+' => x +% y,
                '-' => x -% y,
                '*' => x *% y,
                else => if (y == 0) 0 else @divTrunc(x, y),
            } };
        },
        .float, .length => {
            const x = a.asFloat();
            const y = b.asFloat();
            const r: f32 = switch (op) {
                '+' => x + y,
                '-' => x - y,
                '*' => x * y,
                else => x / y,
            };
            return if (result == .length) .{ .length = r } else .{ .float = r };
        },
    }
}

/// Ordering comparison of two numbers (after the int/float unification).
pub fn compare(a: Value, b: Value) std.math.Order {
    if (a == .int and b == .int) return std.math.order(a.int, b.int);
    if (a == .duration and b == .duration) return std.math.order(a.duration, b.duration);
    return std.math.order(a.asFloat(), b.asFloat());
}

/// Equality as `==` sees it: ints and floats compare as floats, colors
/// and brushes as brushes.
pub fn equal(a: Value, b: Value) bool {
    if ((a == .int and b == .float) or (a == .float and b == .int)) return a.asFloat() == b.asFloat();
    if (a == .color and b == .brush) return zigulee.Brush.color(a.color).eql(b.brush);
    if (a == .brush and b == .color) return a.brush.eql(.color(b.color));
    return a.eql(b);
}

const testing = std.testing;

test "arithmetic follows the generated code's types" {
    try testing.expectEqual(Value{ .int = 7 }, try arithmetic('+', .{ .int = 3 }, .{ .int = 4 }));
    try testing.expectEqual(Value{ .float = 1.5 }, try arithmetic('/', .{ .int = 3 }, .{ .int = 2 }));
    try testing.expectEqual(Value{ .length = 30 }, try arithmetic('*', .{ .length = 10 }, .{ .int = 3 }));
    try testing.expectEqual(Value{ .float = 0.5 }, try arithmetic('/', .{ .length = 5 }, .{ .length = 10 }));
    try testing.expectEqual(Value{ .duration = 300 }, try arithmetic('*', .{ .duration = 100 }, .{ .int = 3 }));
    try testing.expectError(error.InvalidOperands, arithmetic('+', .{ .length = 1 }, .{ .int = 1 }));
    try testing.expect(equal(.{ .int = 2 }, .{ .float = 2 }));
    try testing.expectEqual(std.math.Order.lt, compare(.{ .int = 1 }, .{ .float = 1.5 }));
}

test "conversions to and from Zig values" {
    const align_def = &types.text_horizontal_alignment;
    const v = fromZig(core.rendering.TextHorizontalAlignment, .center, .{ .enumeration = align_def });
    try testing.expectEqualStrings("center", v.enumeration.zigTag());
    try testing.expectEqual(core.rendering.TextHorizontalAlignment.center, toZig(core.rendering.TextHorizontalAlignment, v));
    try testing.expectEqual(@as(f32, 3), toZig(f32, .{ .int = 3 }));
    try testing.expect(toZig(zigulee.Brush, .{ .color = .white }).eql(.color(.white)));
    try testing.expectEqual(Value{ .length = 0 }, convert(.{ .int = 0 }, .length));
}
