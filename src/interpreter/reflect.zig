// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Type-erased access to properties, callbacks and functions of the
//! built-in elements, generated at compile time from the element table the
//! compiler uses (compiler/types.zig), so the interpreter drives exactly the
//! fields the generated code would.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const items = core.items;
const Property = zigulee.Property;
const types = @import("../compiler/types.zig");
const Type = types.Type;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const toZig = value_mod.toZig;
const fromZig = value_mod.fromZig;

/// A binding computed by the interpreter.
pub const DynBinding = struct {
    ctx: *anyopaque,
    eval: *const fn (*anyopaque) Value,
    /// For state transitions: picks the animation when the value changes.
    choose: ?*const fn (*anyopaque) zigulee.Animation = null,
};

/// A `Property(T)` of any `T`, with the `.zge` type its values have.
pub const PropRef = struct {
    ptr: *anyopaque,
    vt: *const VTable,
    ty: Type,

    pub const VTable = struct {
        /// Identifies `T`, so links are only made between equal types.
        type_id: *const anyopaque,
        get: *const fn (*anyopaque, Type) Value,
        getUntracked: *const fn (*anyopaque, Type) Value,
        set: *const fn (*anyopaque, Value) void,
        setAnimated: *const fn (*anyopaque, Allocator, Value, zigulee.Animation) Allocator.Error!void,
        setBinding: *const fn (*anyopaque, Allocator, *DynBinding) Allocator.Error!void,
        setAnimatedBinding: *const fn (*anyopaque, Allocator, *DynBinding, zigulee.Animation) Allocator.Error!void,
        setChoosingBinding: *const fn (*anyopaque, Allocator, *DynBinding) Allocator.Error!void,
        linkTwoWay: *const fn (*anyopaque, *anyopaque) void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn of(comptime T: type, p: *Property(T), ty: Type) PropRef {
        return .{ .ptr = p, .vt = vtableFor(T), .ty = ty };
    }

    pub fn get(r: PropRef) Value {
        return r.vt.get(r.ptr, r.ty);
    }

    pub fn getUntracked(r: PropRef) Value {
        return r.vt.getUntracked(r.ptr, r.ty);
    }

    pub fn set(r: PropRef, v: Value) void {
        r.vt.set(r.ptr, v);
    }

    pub fn setAnimated(r: PropRef, gpa: Allocator, v: Value, anim: zigulee.Animation) Allocator.Error!void {
        return r.vt.setAnimated(r.ptr, gpa, v, anim);
    }

    pub fn setBinding(r: PropRef, gpa: Allocator, b: *DynBinding) Allocator.Error!void {
        return r.vt.setBinding(r.ptr, gpa, b);
    }

    pub fn setAnimatedBinding(r: PropRef, gpa: Allocator, b: *DynBinding, anim: zigulee.Animation) Allocator.Error!void {
        return r.vt.setAnimatedBinding(r.ptr, gpa, b, anim);
    }

    pub fn setChoosingBinding(r: PropRef, gpa: Allocator, b: *DynBinding) Allocator.Error!void {
        return r.vt.setChoosingBinding(r.ptr, gpa, b);
    }

    /// Makes `alias` share `target`'s value (`alias <=> target`). Returns
    /// false if their storage types differ.
    pub fn link(target: PropRef, alias: PropRef) bool {
        if (target.vt.type_id != alias.vt.type_id) return false;
        target.vt.linkTwoWay(target.ptr, alias.ptr);
        return true;
    }

    pub fn deinit(r: PropRef) void {
        r.vt.deinit(r.ptr);
    }
};

fn animatable(comptime T: type) bool {
    return T == i32 or T == f32 or T == i64 or T == zigulee.Color or T == zigulee.Brush;
}

/// A built-in element's list (`FileDialog`'s `selected-files`, a
/// `TreeState`'s `shown`), read as a model of values through its property
/// (which does not move).
fn ZigModelAdapter(comptime E: type) type {
    return struct {
        fn property(p: *anyopaque) *Property(zigulee.Model(E)) {
            return @ptrCast(@alignCast(p));
        }
        fn rowCount(p: *anyopaque) usize {
            return property(p).getUntracked().rowCount();
        }
        fn rowData(p: *anyopaque, row: usize) ?Value {
            const v = property(p).getUntracked().rowData(row) orelse return null;
            return switch (E) {
                []const u8 => .{ .string = v },
                i32 => .{ .int = v },
                bool => .{ .bool = v },
                f32 => .{ .length = v },
                zigulee.Color => .{ .color = v },
                else => unreachable,
            };
        }
        fn notify(p: *anyopaque) *core.ModelNotify {
            const m = property(p).getUntracked();
            return m.vtable.notify(m.ptr);
        }
        const vtable: zigulee.Model(Value).VTable = .{ .rowCount = rowCount, .rowData = rowData, .setRowData = null, .notify = notify };
    };
}

/// The element type of a built-in's list property, if it is one.
fn modelElement(comptime T: type) ?type {
    inline for (.{ []const u8, i32, bool, f32, zigulee.Color }) |E| if (T == zigulee.Model(E)) return E;
    return null;
}

/// A model of values (the interpreter's) as a model of `E`, for a built-in
/// element's list property (`TreeState`'s `levels`). Must not move.
pub fn ValueModelAdapter(comptime E: type) type {
    return struct {
        const Self = @This();
        inner: zigulee.Model(Value) = core.emptyModel(Value),

        pub fn model(self: *Self) zigulee.Model(E) {
            return .{ .ptr = self, .vtable = &vtable };
        }
        fn cast(p: *anyopaque) *Self {
            return @ptrCast(@alignCast(p));
        }
        fn rowCount(p: *anyopaque) usize {
            return cast(p).inner.rowCount();
        }
        fn rowData(p: *anyopaque, row: usize) ?E {
            return toZig(E, cast(p).inner.rowData(row) orelse return null);
        }
        fn notify(p: *anyopaque) *core.ModelNotify {
            const m = cast(p).inner;
            return m.vtable.notify(m.ptr);
        }
        const vtable: zigulee.Model(E).VTable = .{ .rowCount = rowCount, .rowData = rowData, .setRowData = null, .notify = notify };
    };
}

pub fn vtableFor(comptime T: type) *const PropRef.VTable {
    const P = Property(T);
    const S = struct {
        var id: u8 = 0;
        fn cast(p: *anyopaque) *P {
            return @ptrCast(@alignCast(p));
        }
        fn get(p: *anyopaque, ty: Type) Value {
            if (comptime modelElement(T)) |E| {
                _ = cast(p).get(); // depends on it
                return .{ .model = .{ .ptr = p, .vtable = &ZigModelAdapter(E).vtable } };
            }
            return fromZig(T, cast(p).get(), ty);
        }
        fn getUntracked(p: *anyopaque, ty: Type) Value {
            if (comptime modelElement(T)) |E| return .{ .model = .{ .ptr = p, .vtable = &ZigModelAdapter(E).vtable } };
            return fromZig(T, cast(p).getUntracked(), ty);
        }
        fn set(p: *anyopaque, v: Value) void {
            cast(p).set(toZig(T, v));
        }
        fn setAnimated(p: *anyopaque, gpa: Allocator, v: Value, anim: zigulee.Animation) Allocator.Error!void {
            if (comptime animatable(T)) return cast(p).setAnimated(gpa, toZig(T, v), anim);
            cast(p).set(toZig(T, v));
        }
        fn eval(b: *DynBinding) T {
            return toZig(T, b.eval(b.ctx));
        }
        fn choose(b: *DynBinding) zigulee.Animation {
            return if (b.choose) |c| c(b.ctx) else .{};
        }
        fn setBinding(p: *anyopaque, gpa: Allocator, b: *DynBinding) Allocator.Error!void {
            return cast(p).setBinding(gpa, b, eval);
        }
        fn setAnimatedBinding(p: *anyopaque, gpa: Allocator, b: *DynBinding, anim: zigulee.Animation) Allocator.Error!void {
            if (comptime animatable(T)) return cast(p).setAnimatedBinding(gpa, b, eval, anim);
            return cast(p).setBinding(gpa, b, eval);
        }
        fn setChoosingBinding(p: *anyopaque, gpa: Allocator, b: *DynBinding) Allocator.Error!void {
            if (comptime animatable(T)) return cast(p).setAnimatedBindingChoosing(gpa, b, eval, choose);
            return cast(p).setBinding(gpa, b, eval);
        }
        fn linkTwoWay(target: *anyopaque, alias: *anyopaque) void {
            cast(target).linkTwoWay(cast(alias));
        }
        fn deinit(p: *anyopaque) void {
            cast(p).deinit();
        }
        const vt: PropRef.VTable = .{
            .type_id = &id,
            .get = get,
            .getUntracked = getUntracked,
            .set = set,
            .setAnimated = setAnimated,
            .setBinding = setBinding,
            .setAnimatedBinding = setAnimatedBinding,
            .setChoosingBinding = setChoosingBinding,
            .linkTwoWay = linkTwoWay,
            .deinit = deinit,
        };
    };
    return &S.vt;
}

// ---- Storage of declared properties ----

/// The Zig type a declared property of `.zge` type `t` is stored as: the
/// same as the built-in properties it may be linked with.
fn StorageOf(comptime tag: std.meta.Tag(Type)) type {
    return switch (tag) {
        .int => i32,
        .float, .length => f32,
        .duration => i64,
        .bool => bool,
        .string => []const u8,
        .color => zigulee.Color,
        .brush => zigulee.Brush,
        .image => core.Image,
        .audio => core.Audio,
        .video => core.Video,
        .model3d => core.Model3D,
        .component => core.loader.Component,
        else => Value,
    };
}

/// The built-in enums, as Zig types.
const builtin_enums = .{
    .{ &types.text_horizontal_alignment, core.rendering.TextHorizontalAlignment },
    .{ &types.text_vertical_alignment, core.rendering.TextVerticalAlignment },
    .{ &types.text_wrap, core.rendering.TextWrap },
    .{ &types.font_size_mode, core.rendering.FontSizeMode },
    .{ &types.layout_alignment, core.layout.Alignment },
    .{ &types.image_fit, core.image.ImageFit },
    .{ &types.image_rendering, core.image.ImageRendering },
    .{ &types.event_result, core.input.EventResult },
    .{ &types.input_type, core.items.InputType },
    .{ &types.popup_close_policy, core.items.PopupClosePolicy },
    .{ &types.file_dialog_mode, core.items.FileDialogMode },
    .{ &types.http_method, core.items.HttpMethod },
    .{ &types.settings_format, core.items.SettingsFormat },
    .{ &types.swipe_direction, core.items.SwipeDirection },
    .{ &types.device_orientation, core.sensors.Orientation },
    .{ &types.position_error, core.location.Failure },
};

/// Allocates a property for a declared `var <t>`, holding `initial`.
pub fn newProperty(arena: Allocator, t: Type, initial: Value) Allocator.Error!PropRef {
    if (t == .enumeration) inline for (builtin_enums) |e| if (t.enumeration == e[0]) {
        const p = try arena.create(Property(e[1]));
        p.* = .init(toZig(e[1], initial));
        return PropRef.of(e[1], p, t);
    };
    switch (t) {
        inline else => |_, tag| {
            const T = StorageOf(tag);
            const p = try arena.create(Property(T));
            p.* = .init(toZig(T, initial));
            return PropRef.of(T, p, t);
        },
    }
}

// ---- Callbacks ----

/// A handler run by the interpreter.
pub const DynHandler = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, []const Value) Value,
};

/// A `Callback(fn (...) R)` of a built-in element.
pub const CallbackRef = struct {
    ptr: *anyopaque,
    setHandlerFn: *const fn (*anyopaque, *DynHandler) void,
    callFn: *const fn (*anyopaque, []const Value) Value,
    params: []const Type,
    ret: Type,

    pub fn setHandler(c: CallbackRef, h: *DynHandler) void {
        c.setHandlerFn(c.ptr, h);
    }

    pub fn call(c: CallbackRef, args: []const Value) Value {
        return c.callFn(c.ptr, args);
    }
};

/// `accessible-*` properties of an element (`types.accessible_props`).
pub fn accessibleProp(a: *zigulee.core.AccessibleProperties, name: []const u8) ?PropRef {
    inline for (types.accessible_props) |p| if (std.mem.eql(u8, p.name, name)) {
        const field = &@field(a, p.zig);
        return PropRef.of(@TypeOf(field.value), field, p.ty);
    };
    return null;
}

/// `drop-shadow-*` properties of a Rectangle (`types.shadow_props`).
pub fn shadowProp(d: *zigulee.items.DropShadow, name: []const u8) ?PropRef {
    inline for (types.shadow_props) |p| if (std.mem.eql(u8, p.name, name)) {
        const field = &@field(d, p.zig);
        return PropRef.of(@TypeOf(field.value), field, p.ty);
    };
    return null;
}

/// Rotation and scale properties of an element (`scale` is both scales).
pub fn transformProps(t: *zigulee.core.ItemTransform, name: []const u8) ?Props {
    inline for (types.transform_props) |p| if (std.mem.eql(u8, p.name, name)) {
        var props: Props = .{};
        comptime var parts = std.mem.splitScalar(u8, p.zig, ',');
        inline while (comptime parts.next()) |part| {
            const field = &@field(t, part);
            props.refs[props.len] = PropRef.of(@TypeOf(field.value), field, p.ty);
            props.len += 1;
        }
        return props;
    };
    return null;
}

/// `accessible-action-*` callbacks of an element.
pub fn accessibleCallback(a: *zigulee.core.AccessibleProperties, name: []const u8) ?CallbackRef {
    inline for (types.accessible_callbacks) |cb| if (std.mem.eql(u8, cb.name, name)) {
        const field = &@field(a, cb.zig);
        return callbackRef(@TypeOf(field.*), field, cb);
    };
    return null;
}

fn callbackRef(comptime CB: type, ptr: *CB, comptime decl: types.Callback) CallbackRef {
    const Args = CB.Args;
    const fields = std.meta.fields(Args);
    const Ret = @typeInfo(@TypeOf(CB.call)).@"fn".return_type.?;
    const S = struct {
        fn cast(p: *anyopaque) *CB {
            return @ptrCast(@alignCast(p));
        }
        fn trampoline(h: *DynHandler, args: Args) Ret {
            var values: [fields.len]Value = undefined;
            inline for (fields, 0..) |f, i| values[i] = fromZig(f.type, args[i], decl.params[i]);
            const r = h.run(h.ctx, &values);
            if (Ret == void) return;
            return toZig(Ret, r);
        }
        fn call(p: *anyopaque, values: []const Value) Value {
            var args: Args = undefined;
            inline for (fields, 0..) |f, i| args[i] = toZig(f.type, values[i]);
            const r = cast(p).call(args);
            if (Ret == void) return .void;
            return fromZig(Ret, r, decl.ret);
        }
    };
    return .{ .ptr = ptr, .setHandlerFn = setHandlerErased(CB, S.trampoline), .callFn = S.call, .params = decl.params, .ret = decl.ret };
}

/// `Callback.setHandler` passes the handler's arguments separately, so the
/// trampoline is wrapped to take them as a tuple.
fn setHandlerErased(comptime CB: type, comptime trampoline: anytype) *const fn (*anyopaque, *DynHandler) void {
    const Args = CB.Args;
    const n = std.meta.fields(Args).len;
    const Ret = @typeInfo(@TypeOf(CB.call)).@"fn".return_type.?;
    return struct {
        fn set(p: *anyopaque, h: *DynHandler) void {
            const cb: *CB = @ptrCast(@alignCast(p));
            switch (n) {
                0 => cb.setHandler(h, struct {
                    fn f(x: *DynHandler) Ret {
                        return trampoline(x, .{});
                    }
                }.f),
                1 => cb.setHandler(h, struct {
                    fn f(x: *DynHandler, a: std.meta.fields(Args)[0].type) Ret {
                        return trampoline(x, .{a});
                    }
                }.f),
                2 => cb.setHandler(h, struct {
                    fn f(x: *DynHandler, a: std.meta.fields(Args)[0].type, b: std.meta.fields(Args)[1].type) Ret {
                        return trampoline(x, .{ a, b });
                    }
                }.f),
                else => @compileError("callbacks with more than two arguments"),
            }
        }
    }.set;
}

// ---- Built-in elements ----

/// The Zig type of each built-in element.
fn ZigType(comptime name: []const u8) type {
    const table = .{
        .{ "Window", core.Window },
        .{ "Empty", items.Empty },
        .{ "Rectangle", items.Rectangle },
        .{ "Text", items.Text },
        .{ "TouchArea", items.TouchArea },
        .{ "FocusScope", items.FocusScope },
        .{ "Image", items.Image },
        .{ "Path", items.Path },
        .{ "TextInput", items.TextInput },
        .{ "Flickable", items.Flickable },
        .{ "StateMachine", core.statemachine.StateMachine },
        .{ "Timer", items.TimerElement },
        .{ "Audio", items.AudioElement },
        .{ "Video", items.VideoElement },
        .{ "AnimatedImage", items.AnimatedImageElement },
        .{ "Loader", items.Loader },
        .{ "Connections", items.Connections },
        .{ "DragArea", items.DragArea },
        .{ "DropArea", items.DropArea },
        .{ "PinchArea", items.PinchArea },
        .{ "Shortcut", items.Shortcut },
        .{ "StackLayout", items.StackLayout },
        .{ "SwipeView", items.SwipeView },
        .{ "StackView", items.StackView },
        .{ "SplitView", items.SplitView },
        .{ "FlowLayout", items.FlowLayout },
        .{ "ListLayout", items.ListLayout },
        .{ "TableRow", items.TableRow },
        .{ "StyledText", items.StyledText },
        .{ "TreeState", items.TreeState },
        .{ "Selection", items.Selection },
        .{ "SwipeArea", items.SwipeArea },
        .{ "PropertyAnimation", items.PropertyAnimation },
        .{ "PauseAnimation", items.PauseAnimation },
        .{ "SequentialAnimation", items.SequentialAnimation },
        .{ "ParallelAnimation", items.ParallelAnimation },
        .{ "FileDialog", items.FileDialogElement },
        .{ "Settings", items.Settings },
        .{ "HttpRequest", items.HttpRequest },
        .{ "LineChart", items.LineChart },
        .{ "BarChart", items.BarChart },
        .{ "PieChart", items.PieChart },
        .{ "StandardPaths", items.StandardPaths },
        .{ "KeyboardInput", items.KeyboardInput },
        .{ "PlatformMenu", items.PlatformMenu },
        .{ "SystemTrayIcon", items.SystemTrayIcon },
        .{ "Microphone", items.Microphone },
        .{ "Camera", items.Camera },
        .{ "Accelerometer", items.Accelerometer },
        .{ "Gyroscope", items.Gyroscope },
        .{ "Compass", items.Compass },
        .{ "OrientationSensor", items.OrientationSensor },
        .{ "PositionSource", items.PositionSource },
        .{ "MapView", items.MapView },
        .{ "Canvas", items.Canvas },
        .{ "MapItem", items.MapItem },
        .{ "MapPolyline", items.MapPolyline },
        .{ "WebView", items.WebView },
        .{ "View3D", items.View3D },
        .{ "Model", items.SceneModel },
        .{ "Node", items.SceneNode },
        .{ "PerspectiveCamera", items.PerspectiveCamera },
        .{ "DirectionalLight", items.DirectionalLight },
        .{ "PointLight", items.PointLight },
        .{ "Notification", items.Notification },
        .{ "PlatformMenuItem", items.PlatformMenuItem },
        .{ "PopupWindow", items.PopupWindow },
        .{ "GridLayout", items.GridLayout },
        .{ "HorizontalLayout", items.BoxLayout },
        .{ "VerticalLayout", items.BoxLayout },
    };
    @setEvalBranchQuota(10_000);
    inline for (table) |e| if (comptime std.mem.eql(u8, e[0], name)) return e[1];
    @compileError("no Zig type for built-in element " ++ name);
}

fn FieldType(comptime T: type, comptime path: []const u8) type {
    if (comptime std.mem.indexOfScalar(u8, path, '.')) |dot| return FieldType(@FieldType(T, path[0..dot]), path[dot + 1 ..]);
    return @FieldType(T, path);
}

fn fieldPtr(comptime T: type, ptr: *T, comptime path: []const u8) *FieldType(T, path) {
    if (comptime std.mem.indexOfScalar(u8, path, '.')) |dot| return fieldPtr(@FieldType(T, path[0..dot]), &@field(ptr, path[0..dot]), path[dot + 1 ..]);
    return &@field(ptr, path);
}

/// An item's `enabled`: set as its own, read as its parents leave it
/// (`Item.isEnabled`).
fn enabledRef(item: *core.Item) PropRef {
    const S = struct {
        fn owner(p: *anyopaque) *core.Item {
            const prop: *Property(bool) = @ptrCast(@alignCast(p));
            return @fieldParentPtr("enabled", prop);
        }
        fn get(p: *anyopaque, _: Type) Value {
            return .{ .bool = owner(p).isEnabled() };
        }
        fn getUntracked(p: *anyopaque, _: Type) Value {
            return .{ .bool = owner(p).isEnabledUntracked() };
        }
        const vtable: PropRef.VTable = blk: {
            var v = vtableFor(bool).*;
            v.get = get;
            v.getUntracked = getUntracked;
            break :blk v;
        };
    };
    return .{ .ptr = &item.enabled, .vt = &S.vtable, .ty = .bool };
}

fn propRefAt(comptime T: type, ptr: *T, comptime path: []const u8, ty: Type) PropRef {
    const P = FieldType(T, path);
    const V = @FieldType(P, "value");
    return PropRef.of(V, fieldPtr(T, ptr, path), ty);
}

/// Up to four properties written together (`padding` sets four).
pub const Props = struct {
    refs: [4]PropRef = undefined,
    len: u8 = 0,
    /// A field of the component (`@title`), not of the element.
    component_field: ?[]const u8 = null,

    pub fn slice(p: *const Props) []const PropRef {
        return p.refs[0..p.len];
    }
};

pub const BuiltinMeta = struct {
    decl: *const types.Builtin,
    /// Allocates and initializes the element (`size` is for windows).
    create: *const fn (Allocator, core.Size) Allocator.Error!*anyopaque,
    destroy: *const fn (*anyopaque, Allocator) void,
    item: *const fn (*anyopaque) *core.Item,
    /// Where children go.
    content: *const fn (*anyopaque) *core.Item,
    /// Properties by `.zge` name (element-specific and geometry; not
    /// layout constraints).
    props: *const fn (*anyopaque, []const u8) ?Props,
    callback: *const fn (*anyopaque, []const u8) ?CallbackRef,
    /// Calls a function (`focus()`, `push(page)`) with its arguments;
    /// false if there is none by that name.
    function: *const fn (*anyopaque, []const u8, []const Value) bool,
};

fn metaFor(comptime b: *const types.Builtin) BuiltinMeta {
    const T = ZigType(b.name);
    const S = struct {
        fn cast(p: *anyopaque) *T {
            return @ptrCast(@alignCast(p));
        }
        fn create(gpa: Allocator, size: core.Size) Allocator.Error!*anyopaque {
            const p = try gpa.create(T);
            if (T == core.Window) {
                p.init(gpa, size);
            } else if (comptime std.mem.eql(u8, b.init, ".horizontal()")) {
                p.* = .horizontal();
            } else if (comptime std.mem.eql(u8, b.init, ".vertical()")) {
                p.* = .vertical();
            } else if (b.init_call != null) {
                p.init(gpa);
            } else {
                p.* = .{};
            }
            return p;
        }
        fn destroy(p: *anyopaque, gpa: Allocator) void {
            cast(p).deinit();
            gpa.destroy(cast(p));
        }
        fn item(p: *anyopaque) *core.Item {
            return fieldPtr(T, cast(p), b.item);
        }
        fn content(p: *anyopaque) *core.Item {
            return fieldPtr(T, cast(p), b.content orelse b.item);
        }
        fn props(p: *anyopaque, name: []const u8) ?Props {
            @setEvalBranchQuota(10_000);
            var out: Props = .{};
            inline for (types.geometry_props) |g| if (comptime b.prop(g.name) == null) if (std.mem.eql(u8, g.name, name)) {
                out.refs[0] = if (comptime std.mem.eql(u8, g.name, "enabled"))
                    enabledRef(fieldPtr(T, cast(p), b.item))
                else
                    propRefAt(T, cast(p), b.item ++ "." ++ g.zig, g.ty);
                out.len = 1;
                return out;
            };
            inline for (b.props) |prop| if (std.mem.eql(u8, prop.name, name)) {
                if (prop.zig[0] == '@') {
                    out.component_field = prop.zig[1..];
                    return out;
                }
                comptime var it = std.mem.splitScalar(u8, prop.zig, ',');
                inline while (comptime it.next()) |path| {
                    // Left out of this build (`zigulee_options`).
                    if (comptime FieldType(T, path) == void) return null;
                    out.refs[out.len] = propRefAt(T, cast(p), path, prop.ty);
                    out.len += 1;
                }
                return out;
            };
            return null;
        }
        fn callback(p: *anyopaque, name: []const u8) ?CallbackRef {
            inline for (b.callbacks) |cb| if (std.mem.eql(u8, cb.name, name)) {
                const CB = FieldType(T, cb.zig);
                return callbackRef(CB, fieldPtr(T, cast(p), cb.zig), cb);
            };
            return null;
        }
        fn function(p: *anyopaque, name: []const u8, values: []const Value) bool {
            inline for (b.functions) |f| if (std.mem.eql(u8, f.name, name)) {
                const func = @field(T, f.zig);
                var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
                args[0] = cast(p);
                inline for (1..args.len) |i| {
                    args[i] = toZig(@TypeOf(args[i]), if (i - 1 < values.len) values[i - 1] else .void);
                }
                @call(.auto, func, args);
                return true;
            };
            return false;
        }
    };
    return .{
        .decl = b,
        .create = S.create,
        .destroy = S.destroy,
        .item = S.item,
        .content = S.content,
        .props = S.props,
        .callback = S.callback,
        .function = S.function,
    };
}

const metas = blk: {
    var list: [types.builtins.len]BuiltinMeta = undefined;
    for (&types.builtins, 0..) |*b, i| list[i] = metaFor(b);
    break :blk list;
};

pub fn metaOf(b: *const types.Builtin) *const BuiltinMeta {
    for (&metas) |*m| if (m.decl == b) return m;
    unreachable;
}

const testing = std.testing;

test "built-in properties, callbacks and functions by name" {
    const gpa = testing.allocator;
    const rect_meta = metaOf(types.findBuiltin("Rectangle").?);
    const rect = try rect_meta.create(gpa, .{});
    defer rect_meta.destroy(rect, gpa);
    const bg = rect_meta.props(rect, "background").?;
    bg.refs[0].set(.{ .color = .white });
    try testing.expect(bg.refs[0].get().brush.eql(.color(.white)));
    const x = rect_meta.props(rect, "x").?.refs[0];
    x.set(.{ .length = 12 });
    try testing.expectEqual(@as(f32, 12), rect_meta.item(rect).x.get());
    try testing.expect(rect_meta.props(rect, "nope") == null);

    const layout_meta = metaOf(types.findBuiltin("VerticalLayout").?);
    const layout = try layout_meta.create(gpa, .{});
    defer layout_meta.destroy(layout, gpa);
    try testing.expectEqual(@as(u8, 4), layout_meta.props(layout, "padding").?.len);
    const alignment = layout_meta.props(layout, "alignment").?.refs[0];
    try testing.expectEqualStrings("stretch", alignment.get().enumeration.def.values[alignment.get().enumeration.index][0]);

    // Callbacks with arguments and results, through dynamic handlers.
    const fs_meta = metaOf(types.findBuiltin("FocusScope").?);
    const fs = try fs_meta.create(gpa, .{});
    defer fs_meta.destroy(fs, gpa);
    const H = struct {
        seen: []const u8 = "",
        fn run(ctx: *anyopaque, args: []const Value) Value {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.seen = args[0].key_event.text;
            return .{ .enumeration = .{ .def = &types.event_result, .index = 0 } }; // accept
        }
    };
    var h: H = .{};
    var handler: DynHandler = .{ .ctx = &h, .run = H.run };
    const key_pressed = fs_meta.callback(fs, "key-pressed").?;
    key_pressed.setHandler(&handler);
    const r = key_pressed.call(&.{.{ .key_event = .{ .text = "q" } }});
    try testing.expectEqualStrings("q", h.seen);
    try testing.expectEqualStrings("accept", r.enumeration.zigTag());
    try testing.expect(fs_meta.function(fs, "focus", &.{}));
}

test "declared properties link with built-in ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gpa = testing.allocator;
    const text_meta = metaOf(types.findBuiltin("Text").?);
    const text = try text_meta.create(gpa, .{});
    defer text_meta.destroy(text, gpa);
    const declared = try newProperty(a, .string, .{ .string = "hi" });
    defer declared.deinit();
    const field = text_meta.props(text, "text").?.refs[0];
    try testing.expect(declared.link(field));
    try testing.expectEqualStrings("hi", field.get().string);
    field.set(.{ .string = "yo" });
    try testing.expectEqualStrings("yo", declared.get().string);
    // Different storage types do not link.
    const n = try newProperty(a, .int, .{ .int = 1 });
    defer n.deinit();
    try testing.expect(!n.link(field));
}
