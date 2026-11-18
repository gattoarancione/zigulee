// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! C bindings of compiled components (`zgec c`): a C header with a typed
//! API for each exported component and global of a `.zge` file (structs,
//! enums, properties, models, callbacks, public functions), and the Zig
//! code implementing it over the Zig module `zgec` generates. Built with
//! `zigulee.cLibrary`, a C program links the compiled interface: no
//! interpreter, no names looked up at run time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const codegen = @import("codegen.zig");
const types = @import("types.zig");
const Type = types.Type;
const Comp = codegen.Comp;

pub const Output = struct {
    header: []const u8,
    glue: []const u8,
};

const Writer = std.Io.Writer;

/// The bindings of the main file's exported components and globals.
/// `prefix` starts every C name (`app`: `app_contact`, `app_create`...).
pub fn generate(arena: Allocator, gen: *codegen.Generator, prefix: []const u8, header_name: []const u8, source_name: []const u8) Allocator.Error!Output {
    var b: Bindings = .{ .arena = arena, .prefix = try snake(arena, prefix) };
    var h: Writer.Allocating = .init(arena);
    var z: Writer.Allocating = .init(arena);
    b.generate(gen, &h.writer, &z.writer, header_name, source_name) catch return error.OutOfMemory;
    return .{ .header = h.written(), .glue = z.written() };
}

/// `ContactCard`, `contact-card` -> `contact_card`.
fn snake(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name, 0..) |c, i| {
        if (c == '-') {
            try out.append(arena, '_');
        } else if (std.ascii.isUpper(c)) {
            if (i > 0 and name[i - 1] != '-' and name[i - 1] != '_' and !std.ascii.isUpper(name[i - 1])) try out.append(arena, '_');
            try out.append(arena, std.ascii.toLower(c));
        } else try out.append(arena, c);
    }
    return out.items;
}

fn upper(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    const s = try snake(arena, name);
    const out = try arena.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return out;
}

const Bindings = struct {
    arena: Allocator,
    prefix: []const u8,
    structs: std.ArrayList(*const types.StructDef) = .empty,
    enums: std.ArrayList(*const types.Enum) = .empty,

    fn cName(b: *Bindings, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(b.arena, "{s}_{s}", .{ b.prefix, try snake(b.arena, name) });
    }

    /// Whether C can have a value of type `t`.
    fn supported(t: Type) bool {
        return switch (t) {
            .void, .int, .float, .length, .duration, .bool, .string, .color, .brush, .enumeration => true,
            .structure => true,
            else => false,
        };
    }

    /// Properties: also models of supported rows.
    fn supportedProperty(t: Type) bool {
        return switch (t) {
            .model => |row| supported(row.*) and row.* != .void,
            else => supported(t) and t != .void,
        };
    }

    /// Collects the structs and enums `t` uses (structs after those they
    /// contain).
    fn collect(b: *Bindings, t: Type) Allocator.Error!void {
        switch (t) {
            .enumeration => |e| {
                for (b.enums.items) |x| if (x == e) return;
                try b.enums.append(b.arena, e);
            },
            .structure => |s| {
                for (b.structs.items) |x| if (x == s) return;
                for (s.fields) |f| try b.collect(f.ty);
                try b.structs.append(b.arena, s);
            },
            .model => |row| try b.collect(row.*),
            else => {},
        }
    }

    /// The C type (header) of `t`.
    fn cType(b: *Bindings, t: Type) ![]const u8 {
        return switch (t) {
            .void => "void",
            .int => "int32_t",
            .float, .length => "float",
            .duration => "int64_t",
            .bool => "bool",
            .string => "zigulee_string",
            .color, .brush => "uint32_t",
            .enumeration => |e| b.cName(e.name),
            .structure => |s| b.cName(s.name),
            else => unreachable,
        };
    }

    /// The Zig type (glue) of `t`'s C side.
    fn zcType(b: *Bindings, t: Type) ![]const u8 {
        return switch (t) {
            .void => "void",
            .int => "i32",
            .float, .length => "f32",
            .duration => "i64",
            .bool => "bool",
            .string => "cw.CString",
            .color, .brush => "u32",
            .enumeration => "i32",
            .structure => |s| b.cName(s.name),
            else => unreachable,
        };
    }

    /// The Zig type of a value of `t` in the generated module.
    fn zigType(b: *Bindings, t: Type) ![]const u8 {
        return switch (t) {
            .void => "void",
            .int => "i32",
            .float, .length => "f32",
            .duration => "i64",
            .bool => "bool",
            .string => "[]const u8",
            .color => "zigulee.Color",
            .brush => "zigulee.Brush",
            .enumeration => |e| std.fmt.allocPrint(b.arena, "ui.{s}", .{e.zig}),
            .structure => |s| std.fmt.allocPrint(b.arena, "ui.{s}", .{s.zig}),
            else => unreachable,
        };
    }

    /// Zig code turning `expr` (a Zig value of `t`) into its C value.
    fn toC(b: *Bindings, t: Type, expr: []const u8) ![]const u8 {
        return switch (t) {
            .string => std.fmt.allocPrint(b.arena, "cw.CString.of({s})", .{expr}),
            .color => std.fmt.allocPrint(b.arena, "rgba({s})", .{expr}),
            .brush => std.fmt.allocPrint(b.arena, "brushRgba({s})", .{expr}),
            .enumeration => std.fmt.allocPrint(b.arena, "@as(i32, @intFromEnum({s}))", .{expr}),
            .structure => |s| std.fmt.allocPrint(b.arena, "{s}ToC({s})", .{ try b.cName(s.name), expr }),
            else => expr,
        };
    }

    /// Zig code turning `expr` (a C value of `t`) into a Zig value, copying
    /// strings with allocator `a` (`try` on allocation).
    fn fromC(b: *Bindings, t: Type, expr: []const u8, a: []const u8) ![]const u8 {
        return switch (t) {
            .string => std.fmt.allocPrint(b.arena, "(try {s}.dupe(u8, {s}.slice()))", .{ a, expr }),
            .color => std.fmt.allocPrint(b.arena, "zigulee.Color.rgba({s})", .{expr}),
            .brush => std.fmt.allocPrint(b.arena, "zigulee.Brush.color(zigulee.Color.rgba({s}))", .{expr}),
            .enumeration => |e| std.fmt.allocPrint(b.arena, "toEnum(ui.{s}, {s})", .{ e.zig, expr }),
            .structure => |s| std.fmt.allocPrint(b.arena, "(try {s}FromC({s}, {s}))", .{ try b.cName(s.name), expr, a }),
            else => expr,
        };
    }

    fn needsMemory(t: Type) bool {
        return switch (t) {
            .string, .structure, .model => true,
            else => false,
        };
    }

    fn generate(b: *Bindings, gen: *codegen.Generator, h: *Writer, z: *Writer, header_name: []const u8, source_name: []const u8) !void {
        var comps: std.ArrayList(*Comp) = .empty;
        var globals: std.ArrayList(*Comp) = .empty;
        for (gen.comps.values()) |c| {
            if (c.file != 0 or !c.ast.exported or c.template != .none) continue;
            if (c.is_global) try globals.append(b.arena, c) else try comps.append(b.arena, c);
        }
        for (comps.items) |c| try b.collectComp(c);
        for (globals.items) |c| try b.collectComp(c);

        const guard = try b.arena.dupe(u8, try upper(b.arena, header_name));
        for (guard) |*ch| if (!std.ascii.isAlphanumeric(ch.*)) {
            ch.* = '_';
        };
        try h.print(
            \\/* Generated by zgec from {s}: the C API of its compiled components. Do
            \\ * not edit.
            \\ *
            \\ * Strings and structs returned stay valid until the value changes (or,
            \\ * for function and callback results, until the next call); strings and
            \\ * structs passed in are copied. Window, input and rendering: the
            \\ * zigulee_window_* functions of zigulee.h, on <component>_instance(). */
            \\#ifndef {s}
            \\#define {s}
            \\
            \\#include "zigulee.h"
            \\
            \\#ifdef __cplusplus
            \\extern "C" {{
            \\#endif
            \\
        , .{ source_name, guard, guard });
        try z.print(
            \\//! Generated by zgec from {s}: C bindings of its compiled components
            \\//! ({s}). Do not edit.
            \\
            \\const std = @import("std");
            \\const zigulee = @import("zigulee");
            \\const cw = @import("zigulee-c-window");
            \\const ui = @import("ui");
            \\const Allocator = std.mem.Allocator;
            \\
            \\fn rgba(c: zigulee.Color) u32 {{
            \\    return @as(u32, c.r) << 24 | @as(u32, c.g) << 16 | @as(u32, c.b) << 8 | c.a;
            \\}}
            \\
            \\fn brushRgba(br: zigulee.Brush) u32 {{
            \\    return switch (br) {{
            \\        .solid => |c| rgba(c),
            \\        else => 0,
            \\    }};
            \\}}
            \\
            \\fn toEnum(comptime E: type, v: i32) E {{
            \\    const n = @typeInfo(E).@"enum".fields.len;
            \\    return @enumFromInt(@as(std.math.IntFittingRange(0, n - 1), @intCast(std.math.clamp(v, 0, n - 1))));
            \\}}
            \\
            \\
        , .{ source_name, header_name });

        // Enums: int32_t, with a constant per value.
        for (b.enums.items) |e| {
            const name = try b.cName(e.name);
            try h.print("typedef int32_t {s};\n", .{name});
            const up = try upper(b.arena, name);
            for (e.values, 0..) |v, i| try h.print("#define {s}_{s} {d}\n", .{ up, try upper(b.arena, v[0]), i });
            try h.writeAll("\n");
        }

        // Structs: C structs, converted field by field.
        for (b.structs.items) |s| {
            const name = try b.cName(s.name);
            try h.print("typedef struct {s} {{\n", .{name});
            try z.print("pub const {s} = extern struct {{\n", .{name});
            for (s.fields) |f| {
                if (!supported(f.ty)) {
                    try h.print("    /* {s}: not available in C */\n", .{f.name});
                    continue;
                }
                try h.print("    {s} {s};\n", .{ try b.cType(f.ty), try snake(b.arena, f.name) });
                try z.print("    {s}: {s},\n", .{ try snake(b.arena, f.name), try b.zcType(f.ty) });
            }
            try h.print("}} {s};\n\n", .{name});
            try z.writeAll("};\n\n");
            try z.print("fn {s}ToC(v: ui.{s}) {s} {{\n    return .{{\n", .{ name, s.zig, name });
            for (s.fields) |f| if (supported(f.ty)) {
                try z.print("        .{s} = {s},\n", .{ try snake(b.arena, f.name), try b.toC(f.ty, try std.fmt.allocPrint(b.arena, "v.{s}", .{f.zig})) });
            };
            try z.writeAll("    };\n}\n\n");
            var uses_memory = false;
            for (s.fields) |f| uses_memory = uses_memory or (supported(f.ty) and needsMemory(f.ty));
            try z.print("fn {s}FromC(v: {s}, a: Allocator) Allocator.Error!ui.{s} {{\n{s}    var out: ui.{s} = .{{}};\n", .{ name, name, s.zig, if (uses_memory) "" else "    _ = a;\n", s.zig });
            for (s.fields) |f| if (supported(f.ty)) {
                const src = try std.fmt.allocPrint(b.arena, "v.{s}", .{try snake(b.arena, f.name)});
                try z.print("    out.{s} = {s};\n", .{ f.zig, try b.fromC(f.ty, src, "a") });
            };
            try z.writeAll("    return out;\n}\n\n");
        }

        for (comps.items) |c| try b.component(c, h, z);
        for (globals.items) |c| try b.global(c, h, z);

        try h.writeAll(
            \\#ifdef __cplusplus
            \\}
            \\#endif
            \\
            \\#endif
            \\
        );
    }

    fn collectComp(b: *Bindings, c: *Comp) !void {
        for (c.props.items) |p| if (p.visibility != .private and supportedProperty(p.ty)) try b.collect(p.ty);
        for (c.callbacks.items) |cb| if (callbackSupported(cb.params, cb.ret)) {
            for (cb.params) |t| try b.collect(t);
            try b.collect(cb.ret);
        };
        for (c.functions.items) |f| if (f.public and callbackSupported(f.params, f.ret)) {
            for (f.params) |t| try b.collect(t);
            try b.collect(f.ret);
        };
    }

    fn callbackSupported(params: []const Type, ret: Type) bool {
        for (params) |t| if (!supported(t) or t == .void) return false;
        return supported(ret);
    }

    /// The handle's name: the prefix itself for the component it is named
    /// after (`app` for App in app.zge), else prefix_component.
    fn handleName(b: *Bindings, c: *const Comp) ![]const u8 {
        const s = try snake(b.arena, c.name);
        if (std.mem.eql(u8, s, b.prefix)) return b.prefix;
        return b.cName(c.name);
    }

    fn paramList(b: *Bindings, list: []const Type, comptime with_names: bool, zig: bool) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (list, 0..) |t, i| {
            const ty = if (zig) try b.zcType(t) else try b.cType(t);
            if (with_names) {
                if (zig) try out.print(b.arena, ", a{d}: {s}", .{ i, ty }) else try out.print(b.arena, ", {s} a{d}", .{ ty, i });
            } else try out.print(b.arena, ", {s}", .{ty});
        }
        return out.items;
    }

    fn component(b: *Bindings, c: *Comp, h: *Writer, z: *Writer) !void {
        const name = try b.handleName(c);
        const zt = try std.fmt.allocPrint(b.arena, "Handle_{s}", .{c.zig});

        // Memory for values set from C: one store per property, function and
        // callback that takes strings, structs or models.
        var stores: usize = 0;
        try h.print("/* ---- {s} ---- */\n\ntypedef struct {s} {s};\n\n", .{ c.name, name, name });
        try h.print(
            \\/* NULL if out of memory. */
            \\{s} *{s}_create(void);
            \\void {s}_destroy({s} *self);
            \\/* For zigulee_window_* (size, input, rendering): valid while `self` is. */
            \\zigulee_instance *{s}_instance({s} *self);
            \\
        , .{ name, name, name, name, name, name });

        var fields: Writer.Allocating = .init(b.arena);
        var fns: Writer.Allocating = .init(b.arena);
        const f = &fns.writer;

        for (c.props.items) |p| {
            if (p.visibility == .private) continue;
            const pn = try snake(b.arena, p.name);
            if (!supportedProperty(p.ty)) {
                try h.print("/* {s}: not available in C */\n", .{p.name});
                continue;
            }
            const settable = p.visibility == .in or p.visibility == .in_out;
            if (p.ty == .model) {
                const row = p.ty.model.*;
                const ct = try b.cType(row);
                try h.print(
                    \\/* {s}: rows (copied). */
                    \\zigulee_status {s}_set_{s}({s} *self, const {s} *rows, size_t count);
                    \\size_t {s}_{s}_count(const {s} *self);
                    \\/* A zeroed value past the last row. */
                    \\{s} {s}_{s}_row(const {s} *self, size_t row);
                    \\
                , .{ p.name, name, pn, name, ct, name, pn, name, ct, name, pn, name });
                const store = stores;
                stores += 1;
                try fields.writer.print("    rows_{s}: ?zigulee.VecModel({s}) = null,\n", .{ p.zig, try b.zigType(row) });
                try f.print(
                    \\export fn {s}_set_{s}(self: *{s}, rows: [*]const {s}, count: usize) cw.Status {{
                    \\    const a = self.stores[{d}].next();
                    \\    const values = convert: {{
                    \\        const out = a.alloc({s}, count) catch return cw.error_out_of_memory;
                    \\        for (rows[0..count], out) |r, *o| o.* = conv: {{
                    \\            break :conv {s};
                    \\        }};
                    \\        break :convert out;
                    \\    }};
                    \\    if (self.rows_{s} == null) {{
                    \\        self.rows_{s} = .init(cw.gpa);
                    \\        self.rows_{s}.?.setAll(values) catch return cw.error_out_of_memory;
                    \\        self.ui.{s}.set(self.rows_{s}.?.model());
                    \\    }} else self.rows_{s}.?.setAll(values) catch return cw.error_out_of_memory;
                    \\    return cw.ok;
                    \\}}
                    \\
                    \\export fn {s}_{s}_count(self: *const {s}) usize {{
                    \\    return self.ui.{s}.getUntracked().rowCount();
                    \\}}
                    \\
                    \\export fn {s}_{s}_row(self: *const {s}, row: usize) {s} {{
                    \\    const v = self.ui.{s}.getUntracked().rowData(row) orelse return std.mem.zeroes({s});
                    \\    return {s};
                    \\}}
                    \\
                    \\
                , .{
                    name,                                        pn,    zt,                try b.zcType(row), store,             try b.zigType(row),
                    try catchOom(b, try b.fromC(row, "r", "a")), p.zig, p.zig,             p.zig,             p.zig,             p.zig,
                    p.zig,                                       name,  pn,                zt,                p.zig,             name,
                    pn,                                          zt,    try b.zcType(row), p.zig,             try b.zcType(row), try b.toC(row, "v"),
                });
                continue;
            }
            const ct = try b.cType(p.ty);
            try h.print("{s} {s}_get_{s}(const {s} *self);\n", .{ ct, name, pn, name });
            try f.print("export fn {s}_get_{s}(self: *const {s}) {s} {{\n    return {s};\n}}\n\n", .{ name, pn, zt, try b.zcType(p.ty), try b.toC(p.ty, try std.fmt.allocPrint(b.arena, "self.ui.{s}.getUntracked()", .{p.zig})) });
            if (!settable) continue;
            if (needsMemory(p.ty)) {
                const store = stores;
                stores += 1;
                const by_ref = p.ty == .structure;
                try h.print("zigulee_status {s}_set_{s}({s} *self, {s}{s}value);\n", .{ name, pn, name, if (by_ref) "const " else "", if (by_ref) try std.fmt.allocPrint(b.arena, "{s} *", .{ct}) else try std.fmt.allocPrint(b.arena, "{s} ", .{ct}) });
                try f.print(
                    \\export fn {s}_set_{s}(self: *{s}, value: {s}{s}) cw.Status {{
                    \\    const a = self.stores[{d}].next();
                    \\    self.ui.{s}.set(conv: {{
                    \\        break :conv {s};
                    \\    }});
                    \\    return cw.ok;
                    \\}}
                    \\
                    \\
                , .{ name, pn, zt, if (by_ref) "*const " else "", try b.zcType(p.ty), store, p.zig, try catchOom(b, try b.fromC(p.ty, if (by_ref) "value.*" else "value", "a")) });
            } else {
                try h.print("void {s}_set_{s}({s} *self, {s} value);\n", .{ name, pn, name, ct });
                try f.print("export fn {s}_set_{s}(self: *{s}, value: {s}) void {{\n    self.ui.{s}.set({s});\n}}\n\n", .{ name, pn, zt, try b.zcType(p.ty), p.zig, try fromCNoAlloc(b, p.ty, "value") });
            }
        }

        // Callbacks: a handler from C, and invoking them.
        for (c.callbacks.items) |cb| {
            const cn = try snake(b.arena, cb.name);
            if (!callbackSupported(cb.params, cb.ret)) {
                try h.print("/* callback {s}: not available in C */\n", .{cb.name});
                continue;
            }
            const ret = try b.cType(cb.ret);
            try h.print("typedef {s} (*{s}_{s}_fn)(void *user_data{s});\n", .{ ret, name, cn, try b.paramList(cb.params, true, false) });
            try h.print("/* Sets (or, with NULL, removes) the handler. */\nvoid {s}_on_{s}({s} *self, {s}_{s}_fn handler, void *user_data);\n", .{ name, cn, name, name, cn });
            try h.print("{s} {s}_{s}({s} *self{s});\n", .{ ret, name, cn, name, try b.paramList(cb.params, true, false) });
            const store = stores;
            stores += 1;
            try fields.writer.print("    on_{s}: ?struct {{ f: *const fn (?*anyopaque{s}) callconv(.c) {s}, data: ?*anyopaque }} = null,\n", .{ cb.zig, try b.paramList(cb.params, false, true), try b.zcType(cb.ret) });
            // The handler, called by the component.
            var zig_params: std.ArrayList(u8) = .empty;
            var c_args: std.ArrayList(u8) = .empty;
            for (cb.params, 0..) |t, i| {
                try zig_params.print(b.arena, ", a{d}: {s}", .{ i, try b.zigType(t) });
                try c_args.print(b.arena, ", {s}", .{try b.toC(t, try std.fmt.allocPrint(b.arena, "a{d}", .{i}))});
            }
            const zr = try b.zigType(cb.ret);
            try f.print("fn handle_{s}_{s}(self: *{s}{s}) {s} {{\n    const h = self.on_{s}.?;\n", .{ c.zig, cb.zig, zt, zig_params.items, zr, cb.zig });
            if (cb.ret == .void) {
                try f.print("    h.f(h.data{s});\n}}\n\n", .{c_args.items});
            } else {
                try f.print("    const r = h.f(h.data{s});\n", .{c_args.items});
                if (needsMemory(cb.ret)) {
                    try f.print("    const a = self.stores[{d}].next();\n    return conv: {{\n        break :conv {s};\n    }};\n}}\n\n", .{ store, try catchDefault(b, cb.ret, try b.fromC(cb.ret, "r", "a")) });
                } else try f.print("    return {s};\n}}\n\n", .{try fromCNoAlloc(b, cb.ret, "r")});
            }
            try f.print(
                \\export fn {s}_on_{s}(self: *{s}, handler: ?*const fn (?*anyopaque{s}) callconv(.c) {s}, data: ?*anyopaque) void {{
                \\    if (handler) |hf| {{
                \\        self.on_{s} = .{{ .f = hf, .data = data }};
                \\        self.ui.{s}.setHandler(self, handle_{s}_{s});
                \\    }} else {{
                \\        self.on_{s} = null;
                \\        self.ui.{s}.clearHandler();
                \\    }}
                \\}}
                \\
                \\
            , .{ name, cn, zt, try b.paramList(cb.params, false, true), try b.zcType(cb.ret), cb.zig, cb.zig, c.zig, cb.zig, cb.zig, cb.zig });
            try b.invoker(f, name, cn, zt, cb.params, cb.ret, store, try std.fmt.allocPrint(b.arena, "self.ui.{s}.call(.{{", .{cb.zig}), "})");
        }

        // Public functions.
        for (c.functions.items) |func| {
            if (!func.public) continue;
            const fname = try snake(b.arena, func.name);
            if (!callbackSupported(func.params, func.ret)) {
                try h.print("/* function {s}: not available in C */\n", .{func.name});
                continue;
            }
            try h.print("{s} {s}_{s}({s} *self{s});\n", .{ try b.cType(func.ret), name, fname, name, try b.paramList(func.params, true, false) });
            const store = stores;
            stores += 1;
            try b.invoker(f, name, fname, zt, func.params, func.ret, store, try std.fmt.allocPrint(b.arena, "self.ui.{s}(", .{func.method}), ")");
        }
        try h.writeAll("\n");

        try z.print(
            \\const {s} = struct {{
            \\    host: cw.Host,
            \\    ui: *ui.{s},
            \\    stores: [{d}]cw.Store,
            \\{s}}};
            \\
            \\export fn {s}_create() ?*{s} {{
            \\    const self = cw.gpa.create({s}) catch return null;
            \\    const u = ui.{s}.create(cw.gpa) catch {{
            \\        cw.gpa.destroy(self);
            \\        return null;
            \\    }};
            \\    self.* = .{{ .host = .{{ .window = u.window(), .kind = .compiled }}, .ui = u, .stores = undefined }};
            \\    for (&self.stores) |*s| s.* = .init();
            \\    zigulee.runChangeHandlers();
            \\    return self;
            \\}}
            \\
            \\export fn {s}_destroy(self: ?*{s}) void {{
            \\    const s = self orelse return;
            \\    s.host.deinit();
            \\    s.ui.destroy();
            \\    inline for (@typeInfo({s}).@"struct".fields) |fld| {{
            \\        if (comptime std.mem.startsWith(u8, fld.name, "rows_")) {{
            \\            if (@field(s, fld.name)) |*m| m.deinit();
            \\        }}
            \\    }}
            \\    for (&s.stores) |*st| st.deinit();
            \\    cw.gpa.destroy(s);
            \\}}
            \\
            \\export fn {s}_instance(self: *{s}) *cw.Host {{
            \\    return &self.host;
            \\}}
            \\
            \\{s}
        , .{ zt, c.zig, stores, fields.written(), name, zt, zt, c.zig, name, zt, zt, name, zt, fns.written() });
    }

    /// `name_fname(self, args...)`: converts the arguments (strings and
    /// structs into store `store`), calls `call_open args call_close`, and
    /// returns the result for C.
    fn invoker(b: *Bindings, f: *Writer, name: []const u8, fname: []const u8, zt: []const u8, list: []const Type, ret: Type, store: usize, call_open: []const u8, call_close: []const u8) !void {
        try f.print("export fn {s}_{s}(self: *{s}{s}) {s} {{\n", .{ name, fname, zt, try b.paramList(list, true, true), try b.zcType(ret) });
        var any = false;
        for (list) |t| any = any or needsMemory(t);
        if (any) try f.print("    const a = self.stores[{d}].next();\n", .{store});
        var args: std.ArrayList(u8) = .empty;
        for (list, 0..) |t, i| {
            const arg = try std.fmt.allocPrint(b.arena, "a{d}", .{i});
            const conv = if (needsMemory(t)) try catchZero(b, ret, try b.fromC(t, arg, "a")) else try fromCNoAlloc(b, t, arg);
            try args.print(b.arena, "{s}{s}", .{ if (i > 0) ", " else "", conv });
        }
        if (ret == .void) {
            try f.print("    {s}{s}{s};\n", .{ call_open, args.items, call_close });
        } else {
            try f.print("    const r = {s}{s}{s};\n    zigulee.runChangeHandlers();\n    return {s};\n", .{ call_open, args.items, call_close, try b.toC(ret, "r") });
        }
        if (ret == .void) try f.writeAll("    zigulee.runChangeHandlers();\n");
        try f.writeAll("}\n\n");
    }

    fn global(b: *Bindings, c: *Comp, h: *Writer, z: *Writer) !void {
        const name = try b.cName(c.name);
        try h.print("/* ---- {s} (a global: there while a component exists) ---- */\n\n", .{c.name});
        var stores: usize = 0;
        var body: Writer.Allocating = .init(b.arena);
        const f = &body.writer;
        for (c.props.items) |p| {
            if (p.visibility == .private) continue;
            const pn = try snake(b.arena, p.name);
            if (!supported(p.ty) or p.ty == .void) {
                try h.print("/* {s}: not available in C */\n", .{p.name});
                continue;
            }
            const ct = try b.cType(p.ty);
            try h.print("{s} {s}_get_{s}(void);\n", .{ ct, name, pn });
            try f.print("export fn {s}_get_{s}() {s} {{\n    return {s};\n}}\n\n", .{ name, pn, try b.zcType(p.ty), try b.toC(p.ty, try std.fmt.allocPrint(b.arena, "ui.{s}.instance.{s}.getUntracked()", .{ c.zig, p.zig })) });
            if (p.visibility != .in and p.visibility != .in_out) continue;
            if (needsMemory(p.ty)) {
                const by_ref = p.ty == .structure;
                try h.print("zigulee_status {s}_set_{s}({s}{s}value);\n", .{ name, pn, if (by_ref) "const " else "", if (by_ref) try std.fmt.allocPrint(b.arena, "{s} *", .{ct}) else try std.fmt.allocPrint(b.arena, "{s} ", .{ct}) });
                try f.print(
                    \\export fn {s}_set_{s}(value: {s}{s}) cw.Status {{
                    \\    const a = {s}_stores[{d}].next();
                    \\    ui.{s}.instance.{s}.set(conv: {{
                    \\        break :conv {s};
                    \\    }});
                    \\    zigulee.runChangeHandlers();
                    \\    return cw.ok;
                    \\}}
                    \\
                    \\
                , .{ name, pn, if (by_ref) "*const " else "", try b.zcType(p.ty), name, stores, c.zig, p.zig, try catchOom(b, try b.fromC(p.ty, if (by_ref) "value.*" else "value", "a")) });
                stores += 1;
            } else {
                try h.print("void {s}_set_{s}({s} value);\n", .{ name, pn, ct });
                try f.print("export fn {s}_set_{s}(value: {s}) void {{\n    ui.{s}.instance.{s}.set({s});\n    zigulee.runChangeHandlers();\n}}\n\n", .{ name, pn, try b.zcType(p.ty), c.zig, p.zig, try fromCNoAlloc(b, p.ty, "value") });
            }
        }
        try h.writeAll("\n");
        // The global's stores live as long as the program.
        try z.print("var {s}_stores: [{d}]cw.Store = @splat(.{{ .arenas = .{{ .init(std.heap.page_allocator), .init(std.heap.page_allocator) }} }});\n\n{s}", .{ name, stores, body.written() });
    }
};

/// `try` in conversions becomes a `catch` returning ZIGULEE_ERROR_OUT_OF_MEMORY
/// (in a labeled block `conv`).
fn catchOom(b: *Bindings, code: []const u8) ![]const u8 {
    return replaceTry(b, code, "return cw.error_out_of_memory");
}

fn catchDefault(b: *Bindings, t: Type, code: []const u8) ![]const u8 {
    return replaceTry(b, code, try std.fmt.allocPrint(b.arena, "break :conv std.mem.zeroes({s})", .{try b.zigType(t)}));
}

fn catchZero(b: *Bindings, ret: Type, code: []const u8) ![]const u8 {
    return replaceTry(b, code, if (ret == .void) "return" else try std.fmt.allocPrint(b.arena, "return std.mem.zeroes({s})", .{try b.zcType(ret)}));
}

/// `(try x)` -> `(x catch <on_error>)`.
fn replaceTry(b: *Bindings, code: []const u8, on_error: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < code.len) {
        if (std.mem.startsWith(u8, code[i..], "(try ")) {
            // The matching parenthesis.
            var depth: usize = 0;
            var j = i;
            while (j < code.len) : (j += 1) {
                if (code[j] == '(') depth += 1;
                if (code[j] == ')') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            const inner = try replaceTry(b, code[i + 5 .. j], on_error);
            try out.print(b.arena, "({s} catch {s})", .{ inner, on_error });
            i = j + 1;
        } else {
            try out.append(b.arena, code[i]);
            i += 1;
        }
    }
    return out.items;
}

/// A conversion from C needing no memory (numbers, colors, enums).
fn fromCNoAlloc(b: *Bindings, t: Type, expr: []const u8) ![]const u8 {
    return b.fromC(t, expr, "undefined");
}
