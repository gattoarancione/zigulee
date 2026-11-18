// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The C API (include/zigulee.h): the interpreter, a window to drive and
//! render, models, fonts and translations, behind opaque handles.
//! `zig build` installs it as `libzigulee` (static and shared) with the
//! header.

const std = @import("std");
const zigulee = @import("zigulee");
const core = zigulee.core;
const interp = @import("zigulee-interpreter");
const compiler = interp.compiler;
const Value = interp.Value;
const Type = compiler.types.Type;

/// The window part (the event loop, rendering, fonts...), shared with
/// compiled components' bindings.
pub const window_api = @import("zigulee-c-window");
const Status = window_api.Status;
const ok = window_api.ok;
const error_compile = window_api.error_compile;
const error_not_found = window_api.error_not_found;
const error_type = window_api.error_type;
const error_out_of_memory = window_api.error_out_of_memory;
const error_invalid = window_api.error_invalid;
const error_unsupported = window_api.error_unsupported;
const CString = window_api.CString;
const Host = window_api.Host;
const ValueStore = window_api.Store;

const Kind = struct {
    const void_ = 0;
    const int = 1;
    const float = 2;
    const length = 3;
    const duration = 4;
    const boolean = 5;
    const string = 6;
    const color = 7;
    const enumeration = 8;
    const model = 9;
    const structure = 10;
};

pub const CValue = extern struct {
    kind: i32 = Kind.void_,
    reserved: i32 = 0,
    as: extern union {
        i: i64,
        f: f64,
        b: bool,
        s: CString,
        color: u32,
        model: ?*CModel,
        structure: ?*CStruct,
    } = .{ .i = 0 },
};

comptime {
    // The layout the header promises.
    std.debug.assert(@sizeOf(CValue) == 8 + @max(8, @sizeOf(CString)));
}

export fn zigulee_int(v: i64) CValue {
    return .{ .kind = Kind.int, .as = .{ .i = v } };
}

export fn zigulee_float(v: f64) CValue {
    return .{ .kind = Kind.float, .as = .{ .f = v } };
}

export fn zigulee_bool(v: bool) CValue {
    return .{ .kind = Kind.boolean, .as = .{ .b = v } };
}

export fn zigulee_str(s: ?[*:0]const u8) CValue {
    return .{ .kind = Kind.string, .as = .{ .s = .of(if (s) |p| std.mem.span(p) else "") } };
}

export fn zigulee_color(rgba: u32) CValue {
    return .{ .kind = Kind.color, .as = .{ .color = rgba } };
}

// ---- Values ----

fn rgbaOf(c: zigulee.Color) u32 {
    return @as(u32, c.r) << 24 | @as(u32, c.g) << 16 | @as(u32, c.b) << 8 | c.a;
}

/// A value for C; its strings point into zigulee's memory, struct views
/// are made in `arena`.
fn toC(v: Value, arena: std.mem.Allocator) CValue {
    return switch (v) {
        .int => |x| .{ .kind = Kind.int, .as = .{ .i = x } },
        .float => |x| .{ .kind = Kind.float, .as = .{ .f = x } },
        .length => |x| .{ .kind = Kind.length, .as = .{ .f = x } },
        .duration => |x| .{ .kind = Kind.duration, .as = .{ .i = x } },
        .bool => |x| .{ .kind = Kind.boolean, .as = .{ .b = x } },
        .string => |str| .{ .kind = Kind.string, .as = .{ .s = .of(str) } },
        .color => |c| .{ .kind = Kind.color, .as = .{ .color = rgbaOf(c) } },
        .brush => |b| if (b == .solid) .{ .kind = Kind.color, .as = .{ .color = rgbaOf(b.solid) } } else .{},
        .enumeration => |e| .{ .kind = Kind.enumeration, .as = .{ .s = .of(e.def.values[e.index][0]) } },
        .structure => |st| blk: {
            const view = CStruct.view(arena, st) catch break :blk .{};
            break :blk .{ .kind = Kind.structure, .as = .{ .structure = view } };
        },
        else => .{},
    };
}

fn number(v: CValue) ?f64 {
    return switch (v.kind) {
        Kind.int, Kind.duration => @floatFromInt(v.as.i),
        Kind.float, Kind.length => v.as.f,
        else => null,
    };
}

/// `v` as a value of type `t`; strings are copied with `copy`.
fn fromC(v: CValue, t: Type, copy: ArenaCopy) error{ Type, OutOfMemory }!Value {
    return switch (t) {
        .int => .{ .int = if (v.kind == Kind.int) @intCast(std.math.clamp(v.as.i, std.math.minInt(i32), std.math.maxInt(i32))) else core.intFromFloat(i32, number(v) orelse return error.Type) },
        .float => .{ .float = @floatCast(number(v) orelse return error.Type) },
        .length => .{ .length = @floatCast(number(v) orelse return error.Type) },
        .duration => .{ .duration = if (v.kind == Kind.int or v.kind == Kind.duration) v.as.i else core.intFromFloat(i64, number(v) orelse return error.Type) },
        .bool => if (v.kind == Kind.boolean) .{ .bool = v.as.b } else error.Type,
        .string => if (v.kind == Kind.string) .{ .string = try copy.string(v.as.s.slice()) } else error.Type,
        .color => if (v.kind == Kind.color) .{ .color = .rgba(v.as.color) } else error.Type,
        .brush => if (v.kind == Kind.color) .{ .brush = .color(.rgba(v.as.color)) } else error.Type,
        .enumeration => |def| switch (v.kind) {
            Kind.enumeration, Kind.string => for (def.values, 0..) |pair, i| {
                if (std.mem.eql(u8, pair[0], v.as.s.slice())) break .{ .enumeration = .{ .def = def, .index = @intCast(i) } };
            } else error.Type,
            Kind.int => if (v.as.i >= 0 and v.as.i < def.values.len) .{ .enumeration = .{ .def = def, .index = @intCast(v.as.i) } } else error.Type,
            else => error.Type,
        },
        .model => |row| blk: {
            if (v.kind != Kind.model) return error.Type;
            const m = v.as.model orelse return error.Type;
            // The model's rows take the property's row type.
            try m.setRowType(row.*);
            break :blk .{ .model = m.model() };
        },
        .structure => |def| blk: {
            if (v.kind != Kind.structure) return error.Type;
            const st = v.as.structure orelse return error.Type;
            // Fields by name: unknown ones are errors, missing ones their
            // type's default.
            for (st.names.items) |n| {
                for (def.fields) |f| {
                    if (std.mem.eql(u8, f.name, n)) break;
                } else return error.Type;
            }
            const fields = try copy.arena.alloc(Value, def.fields.len);
            for (def.fields, fields) |f, *out| {
                out.* = if (st.find(f.name)) |i| try fromC(st.values.items[i], f.ty, copy) else try interp.defaultValue(f.ty, copy.arena);
            }
            break :blk .{ .structure = .{ .def = def, .fields = fields } };
        },
        else => error.Type,
    };
}

/// A value without a target type (model rows), strings copied.
fn fromCUntyped(v: CValue, copy: ArenaCopy) error{ Type, OutOfMemory }!Value {
    return switch (v.kind) {
        Kind.int => .{ .int = @intCast(std.math.clamp(v.as.i, std.math.minInt(i32), std.math.maxInt(i32))) },
        Kind.float => .{ .float = @floatCast(v.as.f) },
        Kind.length => .{ .length = @floatCast(v.as.f) },
        Kind.duration => .{ .duration = v.as.i },
        Kind.boolean => .{ .bool = v.as.b },
        Kind.string => .{ .string = try copy.string(v.as.s.slice()) },
        Kind.color => .{ .color = .rgba(v.as.color) },
        else => error.Type,
    };
}

fn statusOf(err: error{ Type, OutOfMemory }) Status {
    return switch (err) {
        error.Type => error_type,
        error.OutOfMemory => error_out_of_memory,
    };
}

/// The struct views of the last value handed to C (valid until the next
/// one).
fn freshViews(arena: *std.heap.ArenaAllocator) std.mem.Allocator {
    _ = arena.reset(.retain_capacity);
    return arena.allocator();
}

/// Copies strings into an arena.
const ArenaCopy = struct {
    arena: std.mem.Allocator,

    fn string(c: ArenaCopy, s: []const u8) error{OutOfMemory}![]const u8 {
        return c.arena.dupe(u8, s);
    }
};

// ---- Programs and instances ----

const Program = interp.Program;

pub const CProgram = struct {
    program: *Program,
    files: ?*CFiles = null,
};

export fn zigulee_program_load(file_name: [*:0]const u8, source: [*]const u8, source_len: usize, style: ?[*:0]const u8, out: *?*CProgram, errors: ?*?[*:0]u8) Status {
    return load(file_name, source, source_len, style, .none, out, errors);
}

pub const ReadFileFn = *const fn (user_data: ?*anyopaque, path: [*:0]const u8, buffer: ?[*]u8, capacity: usize) callconv(.c) usize;

const CFiles = struct {
    read_file: ReadFileFn,
    user_data: ?*anyopaque,

    fn read(ctx: ?*anyopaque, arena: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
        const self: *CFiles = @ptrCast(@alignCast(ctx.?));
        const z = try arena.dupeZ(u8, path);
        var buf = try arena.alloc(u8, 4096);
        var size = self.read_file(self.user_data, z.ptr, buf.ptr, buf.len);
        if (size == std.math.maxInt(usize)) return error.FileNotFound;
        if (size > buf.len) {
            buf = try arena.alloc(u8, size);
            size = self.read_file(self.user_data, z.ptr, buf.ptr, buf.len);
            if (size == std.math.maxInt(usize) or size > buf.len) return error.FileNotFound;
        }
        return buf[0..size];
    }
};

export fn zigulee_program_load_with_files(file_name: [*:0]const u8, source: [*]const u8, source_len: usize, style: ?[*:0]const u8, read_file: ReadFileFn, user_data: ?*anyopaque, out: *?*CProgram, errors: ?*?[*:0]u8) Status {
    // Images are read when first shown: the reader lives with the program.
    const files = window_api.gpa.create(CFiles) catch return error_out_of_memory;
    files.* = .{ .read_file = read_file, .user_data = user_data };
    const status = load(file_name, source, source_len, style, .{ .ctx = files, .readFn = CFiles.read }, out, errors);
    if (out.*) |p| p.files = files else window_api.gpa.destroy(files);
    return status;
}

fn load(file_name: [*:0]const u8, source: [*]const u8, source_len: usize, style: ?[*:0]const u8, loader: compiler.Loader, out: *?*CProgram, errors: ?*?[*:0]u8) Status {
    out.* = null;
    if (errors) |e| e.* = null;
    var options: compiler.Options = .{ .loader = loader };
    if (style) |s| {
        const name = std.mem.span(s);
        if (!compiler.std_widgets.isStyle(name)) return error_invalid;
        options.style = name;
    }
    const result = Program.load(window_api.gpa, std.mem.span(file_name), source[0..source_len], options) catch return error_out_of_memory;
    switch (result) {
        .errors => |text| {
            defer window_api.gpa.free(text);
            if (errors) |e| e.* = (window_api.gpa.dupeZ(u8, text) catch return error_out_of_memory).ptr;
            return error_compile;
        },
        .program => |p| {
            const c = window_api.gpa.create(CProgram) catch {
                p.destroy();
                return error_out_of_memory;
            };
            c.* = .{ .program = p };
            out.* = c;
            return ok;
        },
    }
}

export fn zigulee_free_errors(errors: ?[*:0]u8) void {
    const e = errors orelse return;
    window_api.gpa.free(std.mem.span(e)[0 .. std.mem.len(e) + 1]);
}

export fn zigulee_program_destroy(program: ?*CProgram) void {
    const p = program orelse return;
    p.program.destroy();
    if (p.files) |f| window_api.gpa.destroy(f);
    window_api.gpa.destroy(p);
}

const Instance = interp.Instance;

pub const CInstance = struct {
    /// What C sees (`zigulee_instance *`): the window part's.
    host: Host,
    instance: *Instance,
    /// Copies of the strings (and struct fields) set on each property.
    strings: std.StringHashMapUnmanaged(*ValueStore) = .empty,
    handlers: std.ArrayList(*CHandler) = .empty,
    /// Results of functions (valid until the next call).
    results: std.heap.ArenaAllocator,
    /// Struct views of property values (valid until the next get).
    views: std.heap.ArenaAllocator,

    /// The interpreted instance behind a handle (null for a compiled
    /// component's).
    fn of(host: *Host) ?*CInstance {
        if (host.kind != .interpreted) return null;
        return @fieldParentPtr("host", host);
    }

    fn stringsFor(self: *CInstance, name: []const u8) error{OutOfMemory}!*ValueStore {
        const gop = try self.strings.getOrPut(window_api.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = window_api.gpa.dupe(u8, name) catch |err| {
                _ = self.strings.remove(name);
                return err;
            };
            gop.value_ptr.* = try window_api.gpa.create(ValueStore);
            gop.value_ptr.*.* = .init();
        }
        return gop.value_ptr.*;
    }
};

export fn zigulee_instance_create(program: *CProgram, component: ?[*:0]const u8, out: *?*Host) Status {
    out.* = null;
    const prog = program.program;
    const comp = if (component) |name| prog.component(std.mem.span(name)) else prog.mainComponent();
    const inst = prog.create(comp orelse return error_not_found) catch return error_out_of_memory;
    const c = window_api.gpa.create(CInstance) catch {
        inst.destroy();
        return error_out_of_memory;
    };
    c.* = .{ .host = .{ .window = inst.window(), .kind = .interpreted }, .instance = inst, .results = .init(window_api.gpa), .views = .init(window_api.gpa) };
    core.runChangeHandlers();
    out.* = &c.host;
    return ok;
}

export fn zigulee_instance_destroy(instance: ?*Host) void {
    const c = CInstance.of(instance orelse return) orelse return;
    c.host.deinit();
    c.instance.destroy();
    c.results.deinit();
    c.views.deinit();
    var it = c.strings.iterator();
    while (it.next()) |e| {
        e.value_ptr.*.deinit();
        window_api.gpa.destroy(e.value_ptr.*);
        window_api.gpa.free(e.key_ptr.*);
    }
    c.strings.deinit(window_api.gpa);
    for (c.handlers.items) |h| {
        h.result.deinit();
        window_api.gpa.destroy(h);
    }
    c.handlers.deinit(window_api.gpa);
    window_api.gpa.destroy(c);
}

export fn zigulee_get_property(host: *Host, name: [*:0]const u8, out: *CValue) Status {
    const instance = CInstance.of(host) orelse return error_not_found;
    const p = instance.instance.property(std.mem.span(name)) orelse return error_not_found;
    out.* = toC(p.get(), freshViews(&instance.views));
    return ok;
}

export fn zigulee_set_property(host: *Host, name: [*:0]const u8, value: *const CValue) Status {
    const instance = CInstance.of(host) orelse return error_not_found;
    const n = std.mem.span(name);
    const p = instance.instance.property(n) orelse return error_not_found;
    const strings = instance.stringsFor(n) catch return error_out_of_memory;
    const v = fromC(value.*, p.ty, .{ .arena = strings.next() }) catch |err| return statusOf(err);
    p.set(v);
    return ok;
}

pub const CallbackFn = *const fn (user_data: ?*anyopaque, args: [*]const CValue, arg_count: usize) callconv(.c) CValue;

const CHandler = struct {
    dyn: interp.DynHandler,
    func: CallbackFn,
    user_data: ?*anyopaque,
    ret: Type,
    /// Strings and struct fields of results.
    result: ValueStore,

    fn run(ctx: *anyopaque, args: []const Value) Value {
        const self: *CHandler = @ptrCast(@alignCast(ctx));
        // The arguments' struct views live during the call.
        var arena: std.heap.ArenaAllocator = .init(window_api.gpa);
        defer arena.deinit();
        var buf: [16]CValue = undefined;
        const n = @min(args.len, buf.len);
        for (args[0..n], buf[0..n]) |a, *b| b.* = toC(a, arena.allocator());
        const r = self.func(self.user_data, &buf, n);
        if (self.ret == .void) return .void;
        const copy: ArenaCopy = .{ .arena = self.result.next() };
        return fromC(r, self.ret, copy) catch
            (interp.defaultValue(self.ret, copy.arena) catch .void);
    }
};

export fn zigulee_set_callback(host: *Host, name: [*:0]const u8, func: CallbackFn, user_data: ?*anyopaque) Status {
    const instance = CInstance.of(host) orelse return error_not_found;
    const n = std.mem.span(name);
    const comp = instance.instance.comp;
    const decl = for (comp.callbacks.items) |cb| {
        if (std.mem.eql(u8, cb.name, n)) break cb;
    } else return error_not_found;
    const h = window_api.gpa.create(CHandler) catch return error_out_of_memory;
    h.* = .{ .dyn = .{ .ctx = h, .run = CHandler.run }, .func = func, .user_data = user_data, .ret = decl.ret, .result = .init() };
    instance.handlers.append(window_api.gpa, h) catch {
        window_api.gpa.destroy(h);
        return error_out_of_memory;
    };
    if (!instance.instance.onCallback(n, &h.dyn)) return error_not_found;
    return ok;
}

export fn zigulee_invoke(host: *Host, name: [*:0]const u8, args: ?[*]const CValue, arg_count: usize, result: ?*CValue) Status {
    const instance = CInstance.of(host) orelse return error_not_found;
    const n = std.mem.span(name);
    const comp = instance.instance.comp;
    const c_args: []const CValue = if (args) |a| a[0..arg_count] else &.{};
    var arena: std.heap.ArenaAllocator = .init(window_api.gpa);
    defer arena.deinit();
    const copy: ArenaCopy = .{ .arena = arena.allocator() };
    const params: []const Type = for (comp.callbacks.items) |cb| {
        if (std.mem.eql(u8, cb.name, n)) break cb.params;
    } else for (comp.functions.items) |f| {
        if (std.mem.eql(u8, f.name, n) and f.public) break f.params;
    } else return error_not_found;
    if (params.len != c_args.len) return error_type;
    const values = arena.allocator().alloc(Value, params.len) catch return error_out_of_memory;
    for (values, params, c_args) |*v, t, a| v.* = fromC(a, t, copy) catch |err| return statusOf(err);

    _ = instance.results.reset(.retain_capacity);
    const r = instance.instance.invoke(n, values) orelse
        instance.instance.call(n, values, instance.results.allocator()) orelse
        return error_not_found;
    core.runChangeHandlers();
    if (result) |out| out.* = toC(r, instance.results.allocator());
    return ok;
}

// ---- Structs ----

/// A struct value: fields by name. Made with `zigulee_struct_create` (the
/// caller's), or a view of a value zigulee returns (zigulee's: read-only).
pub const CStruct = struct {
    /// Null for views (their memory is the arena they were made in).
    own: ?*std.heap.ArenaAllocator = null,
    names: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList(CValue) = .empty,

    fn find(st: *const CStruct, name: []const u8) ?usize {
        for (st.names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
        return null;
    }

    /// A view of a struct value, in `arena`.
    fn view(arena: std.mem.Allocator, v: Value.Struct) error{OutOfMemory}!*CStruct {
        const st = try arena.create(CStruct);
        st.* = .{};
        try st.names.ensureTotalCapacity(arena, v.fields.len);
        try st.values.ensureTotalCapacity(arena, v.fields.len);
        for (v.def.fields, v.fields) |f, x| {
            st.names.appendAssumeCapacity(f.name);
            st.values.appendAssumeCapacity(toC(x, arena));
        }
        return st;
    }
};

/// A copy of `v` in `arena` (its strings and structs too).
fn copyC(v: CValue, arena: std.mem.Allocator) error{OutOfMemory}!CValue {
    var out = v;
    switch (v.kind) {
        Kind.string, Kind.enumeration => out.as.s = .of(try arena.dupe(u8, v.as.s.slice())),
        Kind.structure => if (v.as.structure) |src| {
            const st = try arena.create(CStruct);
            st.* = .{};
            for (src.names.items, src.values.items) |n, x| {
                try st.names.append(arena, try arena.dupe(u8, n));
                try st.values.append(arena, try copyC(x, arena));
            }
            out.as.structure = st;
        },
        else => {},
    }
    return out;
}

export fn zigulee_struct_create() ?*CStruct {
    const arena = window_api.gpa.create(std.heap.ArenaAllocator) catch return null;
    arena.* = .init(window_api.gpa);
    const st = arena.allocator().create(CStruct) catch {
        arena.deinit();
        window_api.gpa.destroy(arena);
        return null;
    };
    st.* = .{ .own = arena };
    return st;
}

export fn zigulee_struct_destroy(st: ?*CStruct) void {
    const s = st orelse return;
    const arena = s.own orelse return; // a view: zigulee's
    arena.deinit();
    window_api.gpa.destroy(arena);
}

export fn zigulee_struct_set(st: *CStruct, field: [*:0]const u8, value: *const CValue) Status {
    const arena = (st.own orelse return error_invalid).allocator();
    const name = std.mem.span(field);
    const v = copyC(value.*, arena) catch return error_out_of_memory;
    if (st.find(name)) |i| {
        st.values.items[i] = v;
        return ok;
    }
    const owned = arena.dupe(u8, name) catch return error_out_of_memory;
    st.names.append(arena, owned) catch return error_out_of_memory;
    st.values.append(arena, v) catch return error_out_of_memory;
    return ok;
}

export fn zigulee_struct_get(st: *const CStruct, field: [*:0]const u8, out: *CValue) Status {
    const i = st.find(std.mem.span(field)) orelse return error_not_found;
    out.* = st.values.items[i];
    return ok;
}

export fn zigulee_struct_field_count(st: *const CStruct) usize {
    return st.names.items.len;
}

export fn zigulee_struct_field_name(st: *const CStruct, index: usize) CString {
    if (index >= st.names.items.len) return .{};
    return .of(st.names.items[index]);
}

export fn zigulee_struct_field_value(st: *const CStruct, index: usize, out: *CValue) Status {
    if (index >= st.values.items.len) return error_not_found;
    out.* = st.values.items[index];
    return ok;
}

export fn zigulee_struct_value(st: *CStruct) CValue {
    return .{ .kind = Kind.structure, .as = .{ .structure = st } };
}

// ---- Models ----

pub const CModel = struct {
    rows: std.ArrayList(Row) = .empty,
    notify: core.ModelNotify = .{},
    /// The row type, once the model is set on a `[T]` property.
    row_type: ?Type = null,
    /// Struct views of rows read (valid until the next read).
    views: std.heap.ArenaAllocator,

    /// A row: as given (copied), and as a value of the row type.
    const Row = struct { given: CValue, value: Value, arena: std.heap.ArenaAllocator };

    fn model(self: *CModel) zigulee.Model(Value) {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: zigulee.Model(Value).VTable = .{
        .rowCount = rowCount,
        .rowData = rowData,
        .setRowData = null,
        .notify = getNotify,
    };

    fn cast(p: *anyopaque) *CModel {
        return @ptrCast(@alignCast(p));
    }

    fn rowCount(p: *anyopaque) usize {
        return cast(p).rows.items.len;
    }

    fn rowData(p: *anyopaque, row: usize) ?Value {
        const self = cast(p);
        return if (row < self.rows.items.len) self.rows.items[row].value else null;
    }

    fn getNotify(p: *anyopaque) *core.ModelNotify {
        return &cast(p).notify;
    }

    fn newRow(self: *const CModel, v: CValue) error{ Type, OutOfMemory }!Row {
        var arena: std.heap.ArenaAllocator = .init(window_api.gpa);
        errdefer arena.deinit();
        const copy: ArenaCopy = .{ .arena = arena.allocator() };
        const given = try copyC(v, copy.arena);
        // Before the row type is known, structs wait as they were given.
        const value = if (self.row_type) |t| try fromC(given, t, copy) else if (given.kind == Kind.structure) Value.void else try fromCUntyped(given, copy);
        return .{ .given = given, .value = value, .arena = arena };
    }

    /// Converts the rows to the row type of the property the model is set
    /// on (the same for every property it is set on).
    fn setRowType(self: *CModel, t: Type) error{ Type, OutOfMemory }!void {
        if (self.row_type) |old| return if (old.eql(t)) {} else error.Type;
        const values = try window_api.gpa.alloc(Value, self.rows.items.len);
        defer window_api.gpa.free(values);
        for (self.rows.items, values) |*r, *v| v.* = try fromC(r.given, t, .{ .arena = r.arena.allocator() });
        for (self.rows.items, values) |*r, v| r.value = v;
        self.row_type = t;
    }
};

export fn zigulee_model_create() ?*CModel {
    const m = window_api.gpa.create(CModel) catch return null;
    m.* = .{ .views = .init(window_api.gpa) };
    return m;
}

export fn zigulee_model_destroy(model: ?*CModel) void {
    const m = model orelse return;
    m.notify.deinit();
    m.views.deinit();
    for (m.rows.items) |*r| r.arena.deinit();
    m.rows.deinit(window_api.gpa);
    window_api.gpa.destroy(m);
}

export fn zigulee_model_count(model: *const CModel) usize {
    return model.rows.items.len;
}

export fn zigulee_model_push(model: *CModel, value: *const CValue) Status {
    return zigulee_model_insert(model, model.rows.items.len, value);
}

export fn zigulee_model_insert(model: *CModel, row: usize, value: *const CValue) Status {
    if (row > model.rows.items.len) return error_not_found;
    var r = model.newRow(value.*) catch |err| return statusOf(err);
    model.rows.insert(window_api.gpa, row, r) catch {
        r.arena.deinit();
        return error_out_of_memory;
    };
    model.notify.rowsAdded(row, 1);
    return ok;
}

export fn zigulee_model_set(model: *CModel, row: usize, value: *const CValue) Status {
    if (row >= model.rows.items.len) return error_not_found;
    const r = model.newRow(value.*) catch |err| return statusOf(err);
    var old = model.rows.items[row];
    model.rows.items[row] = r;
    model.notify.rowChanged(row);
    old.arena.deinit();
    return ok;
}

export fn zigulee_model_remove(model: *CModel, row: usize) Status {
    if (row >= model.rows.items.len) return error_not_found;
    var old = model.rows.orderedRemove(row);
    model.notify.rowsRemoved(row, 1);
    old.arena.deinit();
    return ok;
}

export fn zigulee_model_get(model: *CModel, row: usize, out: *CValue) Status {
    if (row >= model.rows.items.len) return error_not_found;
    out.* = toC(model.rows.items[row].value, freshViews(&model.views));
    return ok;
}

test "the C API, with every allocation checked" {
    window_api.gpa = std.testing.allocator;
    defer window_api.gpa = std.heap.smp_allocator;
    const testing = std.testing;
    const source =
        \\export component App inherits Window {
        \\    width: 40px;
        \\    height: 30px;
        \\    var in-out <string> name: "Ada";
        \\    var in <[string]> names;
        \\    var out <string> greeting: @tr("Hello, {}!", name);
        \\    var out <int> rows: names.length;
        \\    callback echo(string) -> string;
        \\    public function shout(s: string) -> string { return s + "!"; }
        \\}
    ;
    var errors: ?[*:0]u8 = null;
    var program: ?*CProgram = null;
    try testing.expectEqual(error_compile, zigulee_program_load("bad.zge", "component", 9, null, &program, &errors));
    zigulee_free_errors(errors);
    try testing.expectEqual(ok, zigulee_program_load("app.zge", source, source.len, null, &program, null));
    defer zigulee_program_destroy(program);
    var app: ?*Host = null;
    try testing.expectEqual(ok, zigulee_instance_create(program.?, null, &app));
    defer zigulee_instance_destroy(app);
    for (0..3) |i| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrintZ(&name_buf, "Name {d}", .{i});
        try testing.expectEqual(ok, zigulee_set_property(app.?, "name", &zigulee_str(name)));
    }
    var v: CValue = undefined;
    try testing.expectEqual(ok, zigulee_get_property(app.?, "greeting", &v));
    try testing.expectEqualStrings("Hello, Name 2!", v.as.s.slice());

    const model = zigulee_model_create().?;
    defer zigulee_model_destroy(model);
    try testing.expectEqual(ok, zigulee_model_push(model, &zigulee_str("a")));
    try testing.expectEqual(ok, zigulee_model_set(model, 0, &zigulee_str("b")));
    const mv: CValue = .{ .kind = Kind.model, .as = .{ .model = model } };
    try testing.expectEqual(ok, zigulee_set_property(app.?, "names", &mv));
    try testing.expectEqual(ok, zigulee_get_property(app.?, "rows", &v));
    try testing.expectEqual(@as(i64, 1), v.as.i);

    try testing.expectEqual(ok, zigulee_set_callback(app.?, "echo", struct {
        fn f(_: ?*anyopaque, args: [*]const CValue, n: usize) callconv(.c) CValue {
            return if (n == 1) args[0] else .{};
        }
    }.f, null));
    var r: CValue = undefined;
    try testing.expectEqual(ok, zigulee_invoke(app.?, "echo", &.{zigulee_str("hi")}, 1, &r));
    try testing.expectEqualStrings("hi", r.as.s.slice());
    try testing.expectEqual(ok, zigulee_invoke(app.?, "shout", &.{zigulee_str("hey")}, 1, &r));
    try testing.expectEqualStrings("hey!", r.as.s.slice());

    var pixels: [40 * 30 * 4]u8 = undefined;
    try testing.expectEqual(ok, window_api.zigulee_window_render_rgba(app.?, &pixels, 40, 30, 40, 1, true, null));
    var po: ?*window_api.CTranslations = null;
    const text = "msgid \"Hello, {}!\"\nmsgstr \"Ciao, {}!\"\n";
    try testing.expectEqual(ok, window_api.zigulee_translations_load_po(text, text.len, &po));
    defer window_api.zigulee_translations_destroy(po);
    window_api.zigulee_set_translations(po);
    defer window_api.zigulee_set_translations(null);
    try testing.expectEqual(ok, zigulee_get_property(app.?, "greeting", &v));
    try testing.expectEqualStrings("Ciao, Name 2!", v.as.s.slice());
}

test "the C API: struct values, nested, in models, callbacks and functions" {
    window_api.gpa = std.testing.allocator;
    defer window_api.gpa = std.heap.smp_allocator;
    const testing = std.testing;
    const source =
        \\struct Address { city: string, }
        \\struct Contact { name: string, age: int, home: Address, }
        \\export component App inherits Window {
        \\    var in-out <Contact> person: { name: "Ada", age: 36, home: { city: "London" } };
        \\    var in <[Contact]> people;
        \\    var out <string> summary: "\{person.name} \{person.age} \{person.home.city}";
        \\    var out <int> count: people.length;
        \\    callback describe(Contact) -> string;
        \\    callback make(string) -> Contact;
        \\    public function older(c: Contact) -> Contact { return { name: c.name, age: c.age + 1, home: c.home }; }
        \\}
    ;
    var program: ?*CProgram = null;
    var errors: ?[*:0]u8 = null;
    const loaded = zigulee_program_load("app.zge", source, source.len, null, &program, &errors);
    if (errors) |e| std.debug.print("{s}\n", .{e});
    zigulee_free_errors(errors);
    try testing.expectEqual(ok, loaded);
    defer zigulee_program_destroy(program);
    var app: ?*Host = null;
    try testing.expectEqual(ok, zigulee_instance_create(program.?, null, &app));
    defer zigulee_instance_destroy(app);
    const text = struct {
        fn of(v: CValue) []const u8 {
            return v.as.s.slice();
        }
    }.of;

    // Reading: a view, fields in declaration order, nested structs.
    var v: CValue = undefined;
    try testing.expectEqual(ok, zigulee_get_property(app.?, "person", &v));
    try testing.expectEqual(@as(i32, Kind.structure), v.kind);
    const person = v.as.structure.?;
    try testing.expectEqual(@as(usize, 3), zigulee_struct_field_count(person));
    try testing.expectEqualStrings("age", zigulee_struct_field_name(person, 1).slice());
    var f: CValue = undefined;
    try testing.expectEqual(ok, zigulee_struct_get(person, "name", &f));
    try testing.expectEqualStrings("Ada", text(f));
    try testing.expectEqual(ok, zigulee_struct_get(person, "home", &f));
    var city: CValue = undefined;
    try testing.expectEqual(ok, zigulee_struct_get(f.as.structure.?, "city", &city));
    try testing.expectEqualStrings("London", text(city));
    try testing.expectEqual(error_not_found, zigulee_struct_get(person, "nope", &f));
    try testing.expectEqual(error_invalid, zigulee_struct_set(person, "age", &zigulee_int(1)));
    zigulee_struct_destroy(person); // a view: nothing happens

    // Writing: by field name; missing fields take their default.
    const grace = zigulee_struct_create().?;
    defer zigulee_struct_destroy(grace);
    try testing.expectEqual(ok, zigulee_struct_set(grace, "name", &zigulee_str("Grace")));
    try testing.expectEqual(ok, zigulee_struct_set(grace, "age", &zigulee_int(85)));
    const home = zigulee_struct_create().?;
    try testing.expectEqual(ok, zigulee_struct_set(home, "city", &zigulee_str("Arlington")));
    try testing.expectEqual(ok, zigulee_struct_set(grace, "home", &zigulee_struct_value(home)));
    zigulee_struct_destroy(home); // copied
    try testing.expectEqual(ok, zigulee_set_property(app.?, "person", &zigulee_struct_value(grace)));
    try testing.expectEqual(ok, zigulee_get_property(app.?, "summary", &v));
    try testing.expectEqualStrings("Grace 85 Arlington", text(v));
    const partial = zigulee_struct_create().?;
    defer zigulee_struct_destroy(partial);
    try testing.expectEqual(ok, zigulee_struct_set(partial, "name", &zigulee_str("Linus")));
    try testing.expectEqual(ok, zigulee_set_property(app.?, "person", &zigulee_struct_value(partial)));
    try testing.expectEqual(ok, zigulee_get_property(app.?, "summary", &v));
    try testing.expectEqualStrings("Linus 0 ", text(v));
    // A misspelled field is an error, not ignored.
    try testing.expectEqual(ok, zigulee_struct_set(partial, "nmae", &zigulee_str("x")));
    try testing.expectEqual(error_type, zigulee_set_property(app.?, "person", &zigulee_struct_value(partial)));
    try testing.expectEqual(error_type, zigulee_set_property(app.?, "person", &zigulee_int(3)));

    // Models of structs: rows typed once the model is set.
    const model = zigulee_model_create().?;
    defer zigulee_model_destroy(model);
    try testing.expectEqual(ok, zigulee_model_push(model, &zigulee_struct_value(grace)));
    try testing.expectEqual(ok, zigulee_set_property(app.?, "people", &.{ .kind = Kind.model, .as = .{ .model = model } }));
    try testing.expectEqual(ok, zigulee_model_push(model, &zigulee_struct_value(grace)));
    try testing.expectEqual(ok, zigulee_get_property(app.?, "count", &v));
    try testing.expectEqual(@as(i64, 2), v.as.i);
    try testing.expectEqual(ok, zigulee_model_get(model, 1, &v));
    try testing.expectEqual(ok, zigulee_struct_get(v.as.structure.?, "age", &f));
    try testing.expectEqual(@as(i64, 85), f.as.i);
    // Rows must be of the row type now.
    try testing.expectEqual(error_type, zigulee_model_push(model, &zigulee_int(1)));

    // Callbacks: struct arguments are views; struct results are copied.
    const Handlers = struct {
        var made: ?*CStruct = null;
        fn describe(_: ?*anyopaque, args: [*]const CValue, n: usize) callconv(.c) CValue {
            std.debug.assert(n == 1);
            var name: CValue = undefined;
            _ = zigulee_struct_get(args[0].as.structure.?, "name", &name);
            return name;
        }
        fn make(_: ?*anyopaque, args: [*]const CValue, _: usize) callconv(.c) CValue {
            _ = zigulee_struct_set(made.?, "name", &args[0]);
            return zigulee_struct_value(made.?);
        }
    };
    try testing.expectEqual(ok, zigulee_set_callback(app.?, "describe", Handlers.describe, null));
    try testing.expectEqual(ok, zigulee_set_callback(app.?, "make", Handlers.make, null));
    Handlers.made = zigulee_struct_create();
    defer zigulee_struct_destroy(Handlers.made);
    try testing.expectEqual(ok, zigulee_invoke(app.?, "describe", &.{zigulee_struct_value(grace)}, 1, &v));
    try testing.expectEqualStrings("Grace", text(v));
    try testing.expectEqual(ok, zigulee_invoke(app.?, "make", &.{zigulee_str("Edsger")}, 1, &v));
    try testing.expectEqual(ok, zigulee_struct_get(v.as.structure.?, "name", &f));
    try testing.expectEqualStrings("Edsger", text(f));

    // Functions: a struct in, a struct out.
    try testing.expectEqual(ok, zigulee_invoke(app.?, "older", &.{zigulee_struct_value(grace)}, 1, &v));
    try testing.expectEqual(ok, zigulee_struct_get(v.as.structure.?, "age", &f));
    try testing.expectEqual(@as(i64, 86), f.as.i);
    try testing.expectEqual(ok, zigulee_struct_get(v.as.structure.?, "home", &f));
    try testing.expectEqual(ok, zigulee_struct_get(f.as.structure.?, "city", &city));
    try testing.expectEqualStrings("Arlington", text(city));
}

test "the C API: OpenGL without its functions is unsupported" {
    const testing = std.testing;
    var out: ?*window_api.GlRenderer = null;
    const none = struct {
        fn f(_: ?*anyopaque, _: [*:0]const u8) callconv(.c) ?*const anyopaque {
            return null;
        }
    }.f;
    try testing.expectEqual(error_unsupported, window_api.zigulee_gl_renderer_create(none, null, &out));
    try testing.expect(out == null);
    window_api.zigulee_gl_renderer_destroy(null);
}

test "the C API: imports and images through a file reader" {
    window_api.gpa = std.testing.allocator;
    defer window_api.gpa = std.heap.smp_allocator;
    const testing = std.testing;
    var red: [4]core.Rgba8 = @splat(.{ .r = 255, .g = 0, .b = 0, .a = 255 });
    const png = try core.png.encode(testing.allocator, 2, 2, &red);
    defer testing.allocator.free(png);
    const Files = struct {
        var png_bytes: []const u8 = "";
        fn read(_: ?*anyopaque, path: [*:0]const u8, buffer: ?[*]u8, capacity: usize) callconv(.c) usize {
            const p = std.mem.span(path);
            const data: []const u8 = if (std.mem.eql(u8, p, "parts/box.zge"))
                "export component Box inherits Rectangle { Image { source: @image-url(\"dot.png\"); width: 100%; height: 100%; } }"
            else if (std.mem.eql(u8, p, "parts/dot.png"))
                png_bytes
            else
                return std.math.maxInt(usize);
            if (data.len <= capacity) @memcpy(buffer.?[0..data.len], data);
            return data.len;
        }
    };
    Files.png_bytes = png;
    const source =
        \\import { Box } from "parts/box.zge";
        \\export component App inherits Window {
        \\    width: 20px;
        \\    height: 20px;
        \\    Box { }
        \\}
    ;
    var program: ?*CProgram = null;
    try testing.expectEqual(ok, zigulee_program_load_with_files("app.zge", source, source.len, null, Files.read, null, &program, null));
    defer zigulee_program_destroy(program);
    var app: ?*Host = null;
    try testing.expectEqual(ok, zigulee_instance_create(program.?, null, &app));
    defer zigulee_instance_destroy(app);
    var pixels: [20 * 20 * 4]u8 = undefined;
    try testing.expectEqual(ok, window_api.zigulee_window_render_rgba(app.?, &pixels, 20, 20, 20, 1, true, null));
    // The image (relative to box.zge, in parts/) fills the window.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, pixels[(10 * 20 + 10) * 4 ..][0..4]);
}
