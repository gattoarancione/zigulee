// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The `.zge` interpreter: runs a program without compiling Zig.
//!
//! A program is checked by the compiler first (so it has no errors), then
//! instances are built from the compiler's analysis: the same elements,
//! bindings, animations, states and handlers the generated code would set
//! up, in the same order, on real runtime items. Expressions and handlers
//! are evaluated from the syntax tree with values that carry their `.zge`
//! type, following the generated code's rules.
//!
//! Strings and structs computed by bindings live in per-binding stores of
//! two alternating arenas, like the generated code's string buffers: a
//! property can still compare its previous value with the new one.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const items = core.items;
const compiler = @import("../compiler/compiler.zig");
const ast = compiler.ast;
const types = compiler.types;
const Type = types.Type;
const codegen = compiler.codegen;
const Generator = codegen.Generator;
const Comp = codegen.Comp;
const Elem = codegen.Elem;
const value_mod = @import("value.zig");
pub const Value = value_mod.Value;
const reflect = @import("reflect.zig");
const PropRef = reflect.PropRef;
const models = @import("models.zig");

const log = std.log.scoped(.zigulee_interpreter);

pub const Error = Allocator.Error;

// ---- Programs ----

pub const Program = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    gen: *Generator,
    globals: std.AutoArrayHashMapUnmanaged(*Comp, *Instance) = .empty,
    images: std.StringHashMapUnmanaged(core.Image) = .empty,
    audios: std.StringHashMapUnmanaged(core.Audio) = .empty,
    videos: std.StringHashMapUnmanaged([]const u8) = .empty,
    models: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Components used as values (`Loader { source: Card; }`).
    factories: std.AutoHashMapUnmanaged(*Comp, *ComponentValue) = .empty,
    /// The handler on top of each callback (by its address): connections
    /// chain onto it.
    handler_tops: std.AutoHashMapUnmanaged(*const anyopaque, *HandlerCtx) = .empty,

    pub const LoadResult = union(enum) {
        program: *Program,
        /// Compiler errors, rendered (allocated with the `gpa` given to
        /// `load`).
        errors: []u8,
    };

    /// Checks `source` and prepares it for running. The loader in
    /// `options` must stay valid while the program is used (images are
    /// read when instances are created).
    pub fn load(gpa: Allocator, file_name: []const u8, source: []const u8, options: compiler.Options) Error!LoadResult {
        const prog = try gpa.create(Program);
        prog.* = .{ .gpa = gpa, .arena = .init(gpa), .gen = undefined };
        var ok = false;
        defer if (!ok) {
            prog.arena.deinit();
            gpa.destroy(prog);
        };
        const a = prog.arena.allocator();
        const diags = try a.create(compiler.Diagnostics);
        diags.* = .{ .arena = a };
        const src = try a.dupe(u8, source);
        const name = try a.dupe(u8, file_name);
        _ = try diags.addFile(name, src);
        var parser: compiler.Parser = .init(a, src, diags);
        const doc = try a.create(ast.Document);
        doc.* = parser.parseDocument() catch |err| switch (err) {
            error.ParseError => return .{ .errors = try renderErrors(gpa, diags) },
            else => |e| return e,
        };
        const gen = try a.create(Generator);
        gen.* = .init(a, diags, doc);
        gen.loader = options.loader;
        gen.style = options.style;
        _ = gen.generate(name) catch |err| switch (err) {
            error.CompileError => return .{ .errors = try renderErrors(gpa, diags) },
            else => |e| return e,
        };
        prog.gen = gen;
        ok = true;
        return .{ .program = prog };
    }

    fn renderErrors(gpa: Allocator, diags: *const compiler.Diagnostics) Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        diags.render(&out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    /// Destroys the globals; instances must be destroyed first.
    pub fn destroy(prog: *Program) void {
        var i = prog.globals.count();
        while (i > 0) {
            i -= 1;
            prog.globals.values()[i].destroy();
        }
        prog.globals.deinit(prog.gpa);
        prog.factories.deinit(prog.gpa);
        prog.handler_tops.deinit(prog.gpa);
        prog.images.deinit(prog.gpa);
        prog.audios.deinit(prog.gpa);
        prog.videos.deinit(prog.gpa);
        prog.models.deinit(prog.gpa);
        const gpa = prog.gpa;
        prog.arena.deinit();
        gpa.destroy(prog);
    }

    /// The exported components of the main file, in order.
    pub fn exportedComponents(prog: *Program, out: *std.ArrayList(*Comp), gpa: Allocator) Error!void {
        for (prog.gen.comps.values()) |c| {
            if (c.file == 0 and c.ast.exported and !c.is_global and c.template == .none) try out.append(gpa, c);
        }
    }

    /// The component to show: the last exported window of the main file,
    /// else its last exported component.
    pub fn mainComponent(prog: *Program) ?*Comp {
        var last: ?*Comp = null;
        var last_window: ?*Comp = null;
        for (prog.gen.comps.values()) |c| {
            if (c.file != 0 or !c.ast.exported or c.is_global or c.template != .none) continue;
            last = c;
            if (c.showsWindow()) last_window = c;
        }
        return last_window orelse last;
    }

    pub fn component(prog: *Program, name: []const u8) ?*Comp {
        const c = prog.gen.compIn(0, name) orelse return null;
        return if (c.is_global) null else c;
    }

    /// Creates an instance of `comp` (a component of this program).
    pub fn create(prog: *Program, comp: *Comp) Error!*Instance {
        return Instance.create(prog, comp, null, .none);
    }

    /// The shared instance of a global, created on first use.
    pub fn global(prog: *Program, comp: *Comp) Error!*Instance {
        if (prog.globals.get(comp)) |g| return g;
        const inst = try prog.gpa.create(Instance);
        errdefer prog.gpa.destroy(inst);
        // Registered before it is set up: globals may refer to each other.
        try prog.globals.put(prog.gpa, comp, inst);
        try inst.init(prog, comp, null, .none);
        return inst;
    }

    /// `comp` as a value: a factory of its instances.
    fn factory(prog: *Program, comp: *Comp) Error!*const core.ComponentFactory {
        if (prog.factories.get(comp)) |f| return &f.factory;
        const f = try prog.arena.allocator().create(ComponentValue);
        f.* = .{ .prog = prog, .comp = comp, .factory = .{
            .name = comp.name,
            .ctx = f,
            .create = ComponentValue.create,
            .destroy = ComponentValue.destroy,
            .root = ComponentValue.root,
            .set_input = ComponentValue.setInput,
        } };
        try prog.factories.put(prog.gpa, comp, f);
        return &f.factory;
    }

    /// The global named `name` in the main file.
    pub fn globalNamed(prog: *Program, name: []const u8) Error!?*Instance {
        const c = prog.gen.compIn(0, name) orelse return null;
        if (!c.is_global) return null;
        return try prog.global(c);
    }

    fn image(prog: *Program, dir: []const u8, path: []const u8) core.Image {
        const a = prog.arena.allocator();
        const full = if (dir.len == 0) path else std.fmt.allocPrint(a, "{s}/{s}", .{ dir, path }) catch return value_mod.empty_image;
        if (prog.images.get(full)) |img| return img;
        const bytes = prog.gen.readFile(full) catch |err| {
            log.err("cannot read image '{s}': {t}", .{ full, err });
            return value_mod.empty_image;
        };
        if (core.svg.isSvg(bytes)) {
            const d = a.create(core.svg.Drawing) catch return value_mod.empty_image;
            d.* = core.svg.parse(a, bytes) catch |err| {
                log.err("cannot read the SVG image '{s}': {t}", .{ full, err });
                return value_mod.empty_image;
            };
            const view: core.Image = .{ .width = @intFromFloat(@ceil(d.width)), .height = @intFromFloat(@ceil(d.height)), .pixels = &.{}, .vector = d };
            prog.images.put(prog.gpa, full, view) catch {};
            return view;
        }
        const img = Generator.decodeImage(a, bytes) catch |err| {
            log.err("cannot decode image '{s}': {t}", .{ full, err });
            return value_mod.empty_image;
        };
        const view: core.Image = .{ .width = img.width, .height = img.height, .pixels = img.pixels, .animation = if (core.animated.isAnimated(a, bytes)) bytes else "", .is_opaque = core.image.allOpaque(img.pixels) };
        prog.images.put(prog.gpa, full, view) catch {};
        return view;
    }

    /// The sound in WAV file `path` (relative to `dir`); its bytes stay in
    /// the program's arena.
    fn audio(prog: *Program, dir: []const u8, path: []const u8) core.Audio {
        const a = prog.arena.allocator();
        const full = if (dir.len == 0) path else std.fmt.allocPrint(a, "{s}/{s}", .{ dir, path }) catch return .empty;
        if (prog.audios.get(full)) |clip| return clip;
        const bytes = prog.gen.readFile(full) catch |err| {
            log.err("cannot read audio '{s}': {t}", .{ full, err });
            return .empty;
        };
        const clip = core.audio.wav.decode(bytes) catch |err| {
            log.err("cannot decode audio '{s}': {t}", .{ full, err });
            return .empty;
        };
        prog.audios.put(prog.gpa, full, clip) catch {};
        return clip;
    }

    /// The video file `path` (relative to `dir`), as it is; its bytes
    /// stay in the program's arena.
    fn video(prog: *Program, dir: []const u8, path: []const u8) core.Video {
        const a = prog.arena.allocator();
        const full = if (dir.len == 0) path else std.fmt.allocPrint(a, "{s}/{s}", .{ dir, path }) catch return .none;
        if (prog.videos.get(full)) |bytes| return .{ .bytes = bytes };
        const bytes = prog.gen.readFile(full) catch |err| {
            log.err("cannot read video '{s}': {t}", .{ full, err });
            return .none;
        };
        prog.videos.put(prog.gpa, full, bytes) catch {};
        return .{ .bytes = bytes };
    }

    fn model(prog: *Program, dir: []const u8, path: []const u8) core.Model3D {
        const a = prog.arena.allocator();
        const full = if (dir.len == 0) path else std.fmt.allocPrint(a, "{s}/{s}", .{ dir, path }) catch return .none;
        if (prog.models.get(full)) |bytes| return .{ .bytes = bytes };
        const bytes = prog.gen.readFile(full) catch |err| {
            log.err("cannot read model '{s}': {t}", .{ full, err });
            return .none;
        };
        prog.models.put(prog.gpa, full, bytes) catch {};
        return .{ .bytes = bytes };
    }
};

// ---- Value stores ----

/// Keeps values computed by one binding or statement: two arenas used in
/// turn, so the previous value stays valid while the new one is compared.
/// A component as a value: makes instances of it (for a Loader).
const ComponentValue = struct {
    factory: core.ComponentFactory,
    prog: *Program,
    comp: *Comp,

    fn of(ctx: ?*anyopaque) *ComponentValue {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn create(ctx: ?*anyopaque, _: Allocator) Allocator.Error!*anyopaque {
        const self = of(ctx);
        return try self.prog.create(self.comp);
    }

    fn destroy(_: ?*anyopaque, p: *anyopaque) void {
        @as(*Instance, @ptrCast(@alignCast(p))).destroy();
    }

    fn root(_: ?*anyopaque, p: *anyopaque) *core.Item {
        return @as(*Instance, @ptrCast(@alignCast(p))).rootItem();
    }

    /// Values come as `Value`s (`ty` "value"): converted to the
    /// property's type, if they fit it.
    fn setInput(_: ?*anyopaque, p: *anyopaque, name: []const u8, ty: []const u8, value: *const anyopaque) bool {
        if (!std.mem.eql(u8, ty, "value")) return false;
        const inst: *Instance = @ptrCast(@alignCast(p));
        for (inst.comp.props.items, 0..) |prop, i| {
            if (!std.mem.eql(u8, prop.name, name)) continue;
            if (prop.visibility != .in and prop.visibility != .in_out) return false;
            const v = value_mod.convert(@as(*const Value, @ptrCast(@alignCast(value))).*, prop.ty);
            if (!Inspect.valueFits(v, prop.ty)) return false;
            const store = inst.storeFor(&inst.props[i]) catch return false;
            inst.props[i].set(store.keep(v));
            return true;
        }
        return false;
    }
};

const Store = struct {
    arenas: [2]std.heap.ArenaAllocator,
    current: u1 = 0,

    fn init(gpa: Allocator) Store {
        return .{ .arenas = .{ .init(gpa), .init(gpa) } };
    }

    fn deinit(s: *Store) void {
        for (&s.arenas) |*a| a.deinit();
    }

    fn keep(s: *Store, v: Value) Value {
        switch (v) {
            .string, .structure, .key_event => {},
            .brush => |b| if (b == .solid) return v,
            else => return v,
        }
        s.current +%= 1;
        const a = &s.arenas[s.current];
        _ = a.reset(.retain_capacity);
        return v.clone(a.allocator()) catch {
            log.err("out of memory keeping a value", .{});
            return v;
        };
    }
};

// ---- Instances ----

const TemplateCtx = struct {
    outer: *Instance,
    template: *Comp,
};

/// A `for` body instance (the Repeater's instance type).
pub const RepeatedInstance = struct {
    inst: Instance,

    pub const Context = *TemplateCtx;

    pub fn create(gpa: Allocator, ctx: Context, index: usize, data: Value) Error!*RepeatedInstance {
        const self = try gpa.create(RepeatedInstance);
        errdefer gpa.destroy(self);
        try self.inst.init(ctx.outer.program, ctx.template, ctx.outer, .{ .repeated = .{ .index = index, .data = data } });
        return self;
    }

    pub fn update(self: *RepeatedInstance, index: usize, data: Value) void {
        self.inst.index.set(@intCast(index));
        self.inst.data.set(data);
    }

    pub fn destroy(self: *RepeatedInstance) void {
        const gpa = self.inst.gpa;
        self.inst.deinit();
        gpa.destroy(self);
    }

    pub fn rootItem(self: *RepeatedInstance) *core.Item {
        return self.inst.rootItem();
    }
};

/// An `if` body instance (the Conditional's instance type).
pub const ConditionalInstance = struct {
    inst: Instance,

    pub const Context = *TemplateCtx;

    pub fn create(gpa: Allocator, ctx: Context) Error!*ConditionalInstance {
        const self = try gpa.create(ConditionalInstance);
        errdefer gpa.destroy(self);
        try self.inst.init(ctx.outer.program, ctx.template, ctx.outer, .none);
        return self;
    }

    pub fn destroy(self: *ConditionalInstance) void {
        const gpa = self.inst.gpa;
        self.inst.deinit();
        gpa.destroy(self);
    }

    pub fn rootItem(self: *ConditionalInstance) *core.Item {
        return self.inst.rootItem();
    }
};

const RepeaterHost = core.Repeater(Value, RepeatedInstance);
const ConditionalHost = core.Conditional(ConditionalInstance);

const BuiltinObj = struct {
    ptr: *anyopaque,
    meta: *const reflect.BuiltinMeta,
    constraints: ?*core.LayoutConstraints,
    accessible: ?*core.AccessibleProperties = null,
    transform: ?*core.ItemTransform = null,
    shadow: ?*core.items.DropShadow = null,
};

/// The runtime object of an element.
const Obj = union(enum) {
    none,
    builtin: BuiltinObj,
    component: *Instance,
    repeater: *RepeaterHost,
    conditional: *ConditionalHost,
};

const CallbackSlot = struct {
    params: []const Type,
    ret: Type,
    handler: ?*HandlerCtx = null,
};

const TemplateArgs = union(enum) {
    none,
    repeated: struct { index: usize, data: Value },
};

pub const Instance = struct {
    program: *Program,
    comp: *Comp,
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    /// For `for`/`if` bodies: the instance holding the repeater or
    /// conditional.
    outer: ?*Instance,
    objs: []Obj = &.{},
    props: []PropRef = &.{},
    callbacks: []CallbackSlot = &.{},
    title: zigulee.Property([]const u8) = .init(""),
    index: zigulee.Property(i32) = .init(0),
    data: zigulee.Property(Value) = .init(.void),
    /// Things to tear down, in creation order.
    bindings: std.ArrayList(*BindingCtx) = .empty,
    handlers: std.ArrayList(*HandlerCtx) = .empty,
    /// Connections this instance made (`x.clicked => { }`, `Connections`),
    /// and those waiting for the end of setup.
    connections: std.ArrayList(*HandlerCtx) = .empty,
    pending_connections: std.ArrayList(struct { el: *Elem, h: *const ast.Handler }) = .empty,
    trackers: std.ArrayList(*TrackerCtx) = .empty,
    array_models: std.AutoArrayHashMapUnmanaged(*const ast.Expr, *models.ArrayModel) = .empty,
    stores: std.AutoHashMapUnmanaged(*const anyopaque, *Store) = .empty,
    /// Properties driven by `states`, by property pointer.
    state_props: std.AutoArrayHashMapUnmanaged(*anyopaque, *StateProp) = .empty,
    /// Whether `init` finished (for teardown after a failure).
    ready: bool = false,

    fn create(prog: *Program, comp: *Comp, outer: ?*Instance, args: TemplateArgs) Error!*Instance {
        const inst = try prog.gpa.create(Instance);
        errdefer prog.gpa.destroy(inst);
        try inst.init(prog, comp, outer, args);
        return inst;
    }

    pub fn destroy(self: *Instance) void {
        const gpa = self.gpa;
        self.deinit();
        gpa.destroy(self);
    }

    fn init(self: *Instance, prog: *Program, comp: *Comp, outer: ?*Instance, args: TemplateArgs) Error!void {
        self.* = .{ .program = prog, .comp = comp, .gpa = prog.gpa, .arena = .init(prog.gpa), .outer = outer };
        if (args == .repeated) {
            self.index = .init(@intCast(args.repeated.index));
            self.data = .init(args.repeated.data);
        }
        errdefer self.deinit();
        try self.setup();
        self.ready = true;
    }

    pub fn rootItem(self: *Instance) *core.Item {
        return self.itemOf(self.comp.root);
    }

    /// The window of a component that inherits `Window` (or a component
    /// that does).
    pub fn window(self: *Instance) ?*core.Window {
        if (self.comp.inheritsWindow()) return self.objs[self.comp.root.index].component.window();
        if (!self.comp.is_window) return null;
        const obj = self.objs[self.comp.root.index];
        return @ptrCast(@alignCast(obj.builtin.ptr));
    }

    /// The window's title: its own, or that of the window it inherits.
    pub fn windowTitle(self: *Instance) *zigulee.Property([]const u8) {
        if (self.comp.inheritsWindow()) return self.objs[self.comp.root.index].component.windowTitle();
        return &self.title;
    }

    /// The `Settings` element of a component that inherits it.
    pub fn settingsElement(self: *Instance) *items.Settings {
        return switch (self.objs[self.comp.root.index]) {
            .builtin => |b| @ptrCast(@alignCast(b.ptr)),
            .component => |sub| sub.settingsElement(),
            else => unreachable,
        };
    }

    /// A declared property, for the app (or the viewer) to read and set.
    pub fn property(self: *Instance, name: []const u8) ?PropRef {
        for (self.comp.props.items, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return self.props[i];
        return null;
    }

    /// Invokes a declared callback.
    pub fn invoke(self: *Instance, name: []const u8, args: []const Value) ?Value {
        for (self.comp.callbacks.items, 0..) |cb, i| if (std.mem.eql(u8, cb.name, name)) return self.callDeclared(i, args);
        return null;
    }

    /// Sets a native handler for a declared callback.
    pub fn onCallback(self: *Instance, name: []const u8, handler: *reflect.DynHandler) bool {
        for (self.comp.callbacks.items, 0..) |cb, i| if (std.mem.eql(u8, cb.name, name)) {
            const h = self.arena.allocator().create(HandlerCtx) catch return false;
            h.* = .{ .dyn = handler.*, .inst = self, .elem = self.comp.root, .handler = null, .params = self.callbacks[i].params, .ret = self.callbacks[i].ret, .store = .init(self.gpa) };
            self.handlers.append(self.gpa, h) catch return false;
            h.target = .{ .declared = .{ .inst = self, .index = i } };
            h.key = Instance.callbackKey(h.target.?);
            self.program.handler_tops.put(self.gpa, h.key.?, h) catch return false;
            self.callbacks[i].handler = h;
            return true;
        };
        return false;
    }

    fn deinit(self: *Instance) void {
        const c = self.comp;
        // As the generated code: the window first, then dynamic parts,
        // then the elements, children first.
        if (c.is_window and self.objs.len > 0 and self.objs[c.root.index] == .builtin) {
            const b = self.objs[c.root.index].builtin;
            b.meta.destroy(b.ptr, self.gpa);
            self.objs[c.root.index] = .none;
        }
        // Out of the callbacks they joined, latest first.
        var k = self.connections.items.len;
        while (k > 0) {
            k -= 1;
            self.connections.items[k].disconnect();
        }
        for (self.handlers.items) |h| if (h.key) |key| {
            if (self.program.handler_tops.get(key) == h) _ = self.program.handler_tops.remove(key);
        };
        for (self.trackers.items) |t| t.deinit();
        for (self.objs) |*o| switch (o.*) {
            .repeater => |r| {
                r.deinit();
                self.gpa.destroy(r);
                o.* = .none;
            },
            .conditional => |r| {
                r.deinit();
                self.gpa.destroy(r);
                o.* = .none;
            },
            else => {},
        };
        for (self.array_models.values()) |m| {
            m.deinit();
            self.gpa.destroy(m);
        }
        var i = self.objs.len;
        while (i > 0) {
            i -= 1;
            switch (self.objs[i]) {
                .builtin => |b| {
                    b.meta.destroy(b.ptr, self.gpa);
                    if (b.constraints) |cs| cs.deinit();
                    if (b.accessible) |acc| acc.deinit();
                    if (b.transform) |t| t.deinit();
                    if (b.shadow) |d| d.deinit();
                },
                .component => |sub| sub.destroy(),
                else => {},
            }
        }
        for (self.state_props.values()) |sp| sp.deinit();
        for (self.props) |p| p.deinit();
        self.title.deinit();
        self.index.deinit();
        self.data.deinit();
        for (self.bindings.items) |b| b.store.deinit();
        for (self.handlers.items) |h| h.store.deinit();
        var it = self.stores.valueIterator();
        while (it.next()) |s| s.*.deinit();
        self.bindings.deinit(self.gpa);
        self.handlers.deinit(self.gpa);
        self.connections.deinit(self.gpa);
        self.pending_connections.deinit(self.gpa);
        self.trackers.deinit(self.gpa);
        self.array_models.deinit(self.gpa);
        self.stores.deinit(self.gpa);
        self.state_props.deinit(self.gpa);
        self.arena.deinit();
    }

    // ---- Setup (in the generated code's order) ----

    fn setup(self: *Instance) Error!void {
        const c = self.comp;
        const a = self.arena.allocator();
        // Globals are set up before anything that may use them.
        for (self.program.gen.comps.values()) |gc| if (gc.is_global and gc != c) {
            _ = try self.program.global(gc);
        };

        self.props = try a.alloc(PropRef, c.props.items.len);
        for (c.props.items, self.props) |p, *r| r.* = try reflect.newProperty(a, p.ty, try value_mod.defaultValue(p.ty, a));
        self.callbacks = try a.alloc(CallbackSlot, c.callbacks.items.len);
        for (c.callbacks.items, self.callbacks) |cb, *slot| slot.* = .{ .params = cb.params, .ret = cb.ret };

        // Elements.
        self.objs = try a.alloc(Obj, c.elements.items.len);
        @memset(self.objs, .none);
        for (c.elements.items) |el| self.objs[el.index] = try self.createObj(el);

        // States are known before members: their properties' own bindings
        // are folded into the state binding.
        for (c.elements.items) |el| for (el.ast.members) |*m| if (m.* == .states) try self.collectStates(el, &m.states);

        // Tree.
        for (c.elements.items) |el| {
            const parent = el.parent orelse continue;
            if (!Generator.inTree(el) and Generator.inTree(parent)) continue;
            self.containerOf(parent).appendChild(self.itemOf(el));
        }
        // Components with `@children` already laid out their own children.
        for (c.elements.items) |el| {
            if (el.kind != .component or el.kind.component.children_target == null or el.children.items.len == 0) continue;
            self.containerOf(el).notifyChildrenChanged();
        }

        // Declared properties: initializers and aliases.
        for (c.props.items, 0..) |p, i| {
            const prop: Prop = .{ .refs = single(self.props[i]), .ty = p.ty, .anim = self.animationFor(c.root, p.name) };
            if (p.decl.init) |init_expr| try self.bind(c.root, prop, init_expr, null);
            if (p.decl.alias) |target| try self.alias(c.root, self.props[i], target);
        }
        if (c.keepsSettings()) {
            const s = self.settingsElement();
            for (c.props.items, self.props) |p, r| {
                const kind: items.Settings.Kind = switch (p.ty) {
                    .int => .int,
                    .float, .length => .float,
                    .duration => .duration,
                    .bool => .bool,
                    .string => .string,
                    .color => .color,
                    else => continue,
                };
                try s.addKind(kind, p.name, r.ptr);
            }
        }
        for (c.elements.items) |el| {
            if (el.isDynamic()) {
                try self.setupDynamic(el);
            } else try self.setupMembers(el);
        }
        try self.setupStates();
        try self.setupChanged();
        // Connections last: after the handlers they add to.
        for (self.pending_connections.items) |pc| try self.installConnection(pc.el, pc.h);
        self.pending_connections.clearRetainingCapacity();

        // A Flickable's viewport defaults to the size of its content.
        for (c.elements.items) |el| {
            if (el.kind != .builtin or !std.mem.eql(u8, el.kind.builtin.name, "Flickable")) continue;
            const f: *items.Flickable = @ptrCast(@alignCast(self.objs[el.index].builtin.ptr));
            if (!Generator.hasBinding(el, "viewport-width")) try f.viewport.item.width.setBinding(self.gpa, f, flickableWidth);
            if (!Generator.hasBinding(el, "viewport-height")) try f.viewport.item.height.setBinding(self.gpa, f, flickableHeight);
        }

        // Default geometry: elements outside layouts fill their parent.
        for (c.elements.items) |el| {
            if (el.isDynamic() or el.inLayout() or !Generator.inTree(el)) continue;
            if (el == c.root and c.template == .none) continue;
            var sets = el.sets;
            if (el.kind == .component) sets = sets.merge(el.kind.component.rootGeometry());
            const item = self.itemOf(el);
            if (!sets.any()) {
                try item.fillParent(self.gpa);
                continue;
            }
            if (!sets.width) try item.width.setBinding(self.gpa, item, parentWidth);
            if (!sets.height) try item.height.setBinding(self.gpa, item, parentHeight);
        }

        // Layouts, children first.
        var i = c.elements.items.len;
        while (i > 0) {
            i -= 1;
            const el = c.elements.items[i];
            if (Generator.isGrid(el)) {
                try self.setupGrid(el);
            } else if (el.kind == .builtin and el.kind.builtin.layout) {
                const ptr = self.objs[el.index].builtin.ptr;
                const name = el.kind.builtin.name;
                if (std.mem.eql(u8, name, "StackLayout")) {
                    try @as(*items.StackLayout, @ptrCast(@alignCast(ptr))).setup(self.gpa);
                } else if (std.mem.eql(u8, name, "SwipeView")) {
                    try @as(*items.SwipeView, @ptrCast(@alignCast(ptr))).setup(self.gpa);
                } else if (std.mem.eql(u8, name, "SplitView")) {
                    try @as(*items.SplitView, @ptrCast(@alignCast(ptr))).setup(self.gpa);
                } else if (std.mem.eql(u8, name, "FlowLayout")) {
                    try @as(*items.FlowLayout, @ptrCast(@alignCast(ptr))).setup(self.gpa);
                } else if (std.mem.eql(u8, name, "ListLayout")) {
                    try @as(*items.ListLayout, @ptrCast(@alignCast(ptr))).setup(self.gpa);
                } else if (std.mem.eql(u8, name, "TableRow")) {
                    try @as(*items.TableRow, @ptrCast(@alignCast(ptr))).setup(self.gpa);
                } else try @as(*items.BoxLayout, @ptrCast(@alignCast(ptr))).setup(self.gpa);
            }
        }
    }

    fn flickableWidth(f: *items.Flickable) f32 {
        return f.item.width.get();
    }

    fn flickableHeight(f: *items.Flickable) f32 {
        return f.fittedViewportHeight();
    }

    fn parentWidth(item: *core.Item) f32 {
        const parent = item.parent orelse return 0;
        return parent.width.get();
    }

    fn parentHeight(item: *core.Item) f32 {
        const parent = item.parent orelse return 0;
        return parent.height.get();
    }

    fn createObj(self: *Instance, el: *Elem) Error!Obj {
        const a = self.arena.allocator();
        switch (el.kind) {
            .builtin => |b| {
                const meta = reflect.metaOf(b);
                if (b.window) {
                    const ptr = try meta.create(self.gpa, self.windowSize());
                    return .{ .builtin = .{ .ptr = ptr, .meta = meta, .constraints = null } };
                }
                const ptr = try meta.create(self.gpa, .{});
                errdefer meta.destroy(ptr, self.gpa);
                const cs = try a.create(core.LayoutConstraints);
                cs.* = .{};
                meta.item(ptr).constraints = cs;
                // As in the generated code: only for elements that set them.
                const acc: ?*core.AccessibleProperties = if (el.accessible) blk: {
                    const p = try a.create(core.AccessibleProperties);
                    p.* = .{};
                    meta.item(ptr).accessible = p;
                    break :blk p;
                } else null;
                const xf: ?*core.ItemTransform = if (el.transform) blk: {
                    const t = try a.create(core.ItemTransform);
                    t.* = .{};
                    meta.item(ptr).transform = t;
                    break :blk t;
                } else null;
                const shadow: ?*core.items.DropShadow = if (el.shadow) blk: {
                    const d = try a.create(core.items.DropShadow);
                    d.* = .{};
                    @as(*core.items.Rectangle, @ptrCast(@alignCast(ptr))).shadow = d;
                    break :blk d;
                } else null;
                return .{ .builtin = .{ .ptr = ptr, .meta = meta, .constraints = cs, .accessible = acc, .transform = xf, .shadow = shadow } };
            },
            .component => |sub| return .{ .component = try Instance.create(self.program, sub, null, .none) },
            .repeater => |t| {
                const ctx = try a.create(TemplateCtx);
                ctx.* = .{ .outer = self, .template = t };
                const host = try self.gpa.create(RepeaterHost);
                errdefer self.gpa.destroy(host);
                try host.init(self.gpa, ctx);
                return .{ .repeater = host };
            },
            .conditional => |t| {
                const ctx = try a.create(TemplateCtx);
                ctx.* = .{ .outer = self, .template = t };
                const host = try self.gpa.create(ConditionalHost);
                errdefer self.gpa.destroy(host);
                try host.init(self.gpa, ctx);
                return .{ .conditional = host };
            },
        }
    }

    /// The window's initial size, from its `width` and `height`.
    fn windowSize(self: *Instance) core.Size {
        var size: core.Size = .{ .width = 640, .height = 480 };
        for (self.comp.ast.root.members) |m| if (m == .binding) {
            const b = m.binding;
            const v = self.evalSetup(self.comp.root, b.value, .length) orelse continue;
            if (std.mem.eql(u8, b.name.name, "width")) size.width = v.asFloat();
            if (std.mem.eql(u8, b.name.name, "height")) size.height = v.asFloat();
        };
        return size;
    }

    /// Evaluates an expression once (not as a binding).
    fn evalSetup(self: *Instance, el: *Elem, e: *const ast.Expr, expected: ?Type) ?Value {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        var env: Env = .{ .inst = self, .elem = el, .scratch = scratch.allocator() };
        const v = env.eval(e, expected) catch return null;
        // Only numbers, enums and the like are needed here.
        return switch (v) {
            .string, .structure, .key_event => null,
            else => v,
        };
    }

    fn setupGrid(self: *Instance, grid: *Elem) Error!void {
        var placements: std.ArrayList(items.GridLayout.Placement) = .empty;
        defer placements.deinit(self.gpa);
        var last_row: u16 = 0;
        for (grid.children.items) |cell| {
            const explicit = !cell.isDynamic();
            const row = (if (explicit) self.cellValue(cell, "row") else null) orelse cell.grid_row orelse last_row;
            const col = if (explicit) self.cellValue(cell, "col") else null;
            const rowspan = (if (explicit) self.cellValue(cell, "rowspan") else null) orelse 1;
            const colspan = (if (explicit) self.cellValue(cell, "colspan") else null) orelse 1;
            last_row = row;
            try placements.append(self.gpa, .{ .row = row, .col = col, .rowspan = rowspan, .colspan = colspan });
        }
        const g: *items.GridLayout = @ptrCast(@alignCast(self.objs[grid.index].builtin.ptr));
        try g.setup(self.gpa, placements.items);
    }

    fn cellValue(self: *Instance, cell: *Elem, name: []const u8) ?u16 {
        for (cell.ast.members) |m| if (m == .binding and std.mem.eql(u8, m.binding.name.name, name)) {
            const v = self.evalSetup(cell, m.binding.value, .int) orelse return null;
            return @intCast(std.math.clamp(v.int, 0, 1000));
        };
        return null;
    }

    fn setupMembers(self: *Instance, el: *Elem) Error!void {
        const loader = el.kind == .builtin and std.mem.eql(u8, el.kind.builtin.name, "Loader");
        var inputs: std.ArrayList(*TrackerCtx) = .empty;
        defer inputs.deinit(self.gpa);
        for (el.ast.members) |*m| switch (m.*) {
            .binding => |b| if (std.mem.eql(u8, b.name.name, "mask-source")) {
                self.maskSource(el, b);
            } else if (loader and (try self.memberOf(el, true, b.name.name)) == null) {
                // Passed to the instance it shows.
                const ctx = try self.arena.allocator().create(TrackerCtx);
                ctx.* = .{ .inst = self, .elem = el, .expr = b.value, .store = .init(self.gpa), .action = .{ .loader_input = .{ .loader = self.loaderOf(el), .name = b.name.name } } };
                try self.trackers.append(self.gpa, ctx);
                ctx.tracker.init(self.gpa, ctx, TrackerCtx.evaluate, TrackerCtx.changed);
                ctx.ready = true;
                try inputs.append(self.gpa, ctx);
            } else try self.elementBinding(el, b),
            .two_way => |t| {
                const p = (try self.memberOf(el, true, t.name.name)) orelse continue;
                if (p != .property) continue;
                try self.alias(el, p.property.refs.refs[0], t.target);
            },
            .handler => |*h| if (h.target == null and !Generator.isConnections(el))
                try self.installHandler(el, h)
            else
                try self.pending_connections.append(self.gpa, .{ .el = el, .h = h }),
            else => {},
        };
        if (inputs.items.len > 0) try self.loaderInputs(el, inputs.items);
        if (el.kind == .builtin and std.mem.eql(u8, el.kind.builtin.name, "PropertyAnimation")) try self.animationTarget(el);
    }

    /// `mask-source: shape;`: the element whose drawing masks `el`.
    fn maskSource(self: *Instance, el: *Elem, b: ast.Binding) void {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        var env: Env = .{ .inst = self, .elem = el, .scratch = scratch.allocator() };
        const ref = env.compileRef(b.value) catch return;
        if (ref != .element) return;
        const t = self.itemOf(el).transform orelse return;
        t.mask_source = ref.element.inst.itemOf(ref.element.elem);
    }

    /// A PropertyAnimation's `target`, `from` and `to`.
    fn animationTarget(self: *Instance, el: *Elem) Error!void {
        var target: ?*const ast.Expr = null;
        var from: ?*const ast.Expr = null;
        var to: ?*const ast.Expr = null;
        for (el.ast.members) |m| if (m == .binding) {
            const b = m.binding;
            if (std.mem.eql(u8, b.name.name, "target")) target = b.value;
            if (std.mem.eql(u8, b.name.name, "from")) from = b.value;
            if (std.mem.eql(u8, b.name.name, "to")) to = b.value;
        };
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        var env: Env = .{ .inst = self, .elem = el, .scratch = scratch.allocator() };
        const ref = env.compileRef(target orelse return) catch return;
        if (ref != .property) return;
        const t = try self.arena.allocator().create(AnimationTarget);
        t.* = .{ .inst = self, .elem = el, .prop = ref.property, .from = from, .to = to orelse return };
        const node: *core.timeline.Node = &@as(*core.items.PropertyAnimation, @ptrCast(@alignCast(self.objs[el.index].builtin.ptr))).node;
        node.setTarget(t, AnimationTarget.begin, AnimationTarget.apply);
    }

    /// A built-in's list property (a TreeState's `levels`): the model of
    /// values, seen as one of its rows' type (through an adapter; two,
    /// taken in turn, so that another model is another value of the
    /// property).
    fn builtinList(self: *Instance, el: *Elem, p: Prop, expr: *const ast.Expr) Error!void {
        const a = self.arena.allocator();
        const ptr = p.refs.refs[0].ptr;
        const input: ListInput = switch (p.ty.model.*) {
            .int => try ListInput.make(i32, a, ptr),
            .bool => try ListInput.make(bool, a, ptr),
            .string => try ListInput.make([]const u8, a, ptr),
            .length, .float => try ListInput.make(f32, a, ptr),
            .color => try ListInput.make(zigulee.Color, a, ptr),
            else => return,
        };
        const ctx = try a.create(TrackerCtx);
        ctx.* = .{ .inst = self, .elem = el, .expr = expr, .store = .init(self.gpa), .action = .{ .list_input = input } };
        try self.trackers.append(self.gpa, ctx);
        ctx.tracker.init(self.gpa, ctx, TrackerCtx.evaluate, TrackerCtx.changed);
        ctx.ready = true;
        ctx.changed(ctx.tracker.value);
    }

    fn loaderOf(self: *Instance, el: *Elem) *core.items.Loader {
        return @ptrCast(@alignCast(self.objs[el.index].builtin.ptr));
    }

    /// Passes a Loader's inputs to each instance it creates (and to the one
    /// shown, if any).
    fn loaderInputs(self: *Instance, el: *Elem, trackers: []const *TrackerCtx) Error!void {
        const all = try self.arena.allocator().dupe(*TrackerCtx, trackers);
        const h = try self.arena.allocator().create(LoaderCreated);
        h.* = .{ .trackers = all };
        const l = self.loaderOf(el);
        l.created.setHandler(h, LoaderCreated.push);
        h.push();
    }

    fn elementBinding(self: *Instance, el: *Elem, b: ast.Binding) Error!void {
        const c = self.comp;
        const name = b.name.name;
        if (el.parent) |p| if (Generator.isGrid(p)) for ([_][]const u8{ "row", "col", "rowspan", "colspan" }) |gp| {
            if (std.mem.eql(u8, gp, name)) return;
        };
        if (el == c.root and c.is_window and (std.mem.eql(u8, name, "width") or std.mem.eql(u8, name, "height"))) return;
        const member = (try self.memberOf(el, true, name)) orelse return;
        if (member != .property) return;
        const p = member.property;
        if (self.state_props.contains(p.refs.refs[0].ptr)) return;
        if (el.kind == .builtin and p.ty == .model) return self.builtinList(el, p, b.value);

        const is_size = std.mem.eql(u8, name, "width") or std.mem.eql(u8, name, "height");
        var percent: ?Percent = null;
        if (is_size) if (el.visualParent()) |parent| {
            const owner = if (el.parent != null) self else self.outer.?;
            percent = .{ .item = owner.itemOf(parent), .height = std.mem.eql(u8, name, "height") };
        };
        const size_constraint = is_size and (el.inLayout() or (el == c.root and !c.showsWindow()));
        if (size_constraint) {
            inline for (.{ "min-", "max-", "preferred-" }) |prefix| {
                var buf: [32]u8 = undefined;
                const cname = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, name }) catch unreachable;
                if (try self.memberOf(el, true, cname)) |cm| try self.bind(el, cm.property, b.value, percent);
            }
            if (el.inLayout()) return;
        }
        try self.bind(el, p, b.value, percent);
    }

    /// Sets a literal, or installs a binding (animated if the property has
    /// an animation).
    fn bind(self: *Instance, el: *Elem, p: Prop, expr: *const ast.Expr, percent: ?Percent) Error!void {
        if (p.anim == null and isLiteral(expr)) {
            if (self.evalSetup(el, expr, p.ty)) |v| {
                for (p.refs.slice()) |r| r.set(v);
                return;
            }
        }
        const ctx = try self.newBinding(el, .{ .expr = expr }, p.ty, percent);
        for (p.refs.slice()) |r| {
            if (p.anim) |anim| try r.setAnimatedBinding(self.gpa, &ctx.dyn, anim) else try r.setBinding(self.gpa, &ctx.dyn);
        }
    }

    fn newBinding(self: *Instance, el: *Elem, source: BindingCtx.Source, ty: Type, percent: ?Percent) Error!*BindingCtx {
        const ctx = try self.arena.allocator().create(BindingCtx);
        ctx.* = .{ .dyn = .{ .ctx = ctx, .eval = BindingCtx.eval }, .inst = self, .elem = el, .source = source, .ty = ty, .percent = percent, .store = .init(self.gpa) };
        try self.bindings.append(self.gpa, ctx);
        return ctx;
    }

    /// `alias <=> target`: the target keeps its value.
    fn alias(self: *Instance, el: *Elem, alias_ref: PropRef, target: *const ast.Expr) Error!void {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        var env: Env = .{ .inst = self, .elem = el, .scratch = scratch.allocator() };
        const ref = env.compileRef(target) catch return;
        if (ref != .property) return;
        if (!ref.property.refs.refs[0].link(alias_ref)) log.err("cannot link properties of different types", .{});
    }

    fn installHandler(self: *Instance, el: *Elem, h: *const ast.Handler) Error!void {
        const member = (try self.memberOf(el, true, h.name.name)) orelse return;
        if (member != .callback) return;
        const params, const ret = switch (member.callback) {
            .declared => |d| .{ d.inst.callbacks[d.index].params, d.inst.callbacks[d.index].ret },
            .builtin => |b| .{ b.params, b.ret },
        };
        const ctx = try self.arena.allocator().create(HandlerCtx);
        ctx.* = .{ .dyn = .{ .ctx = ctx, .run = HandlerCtx.run }, .inst = self, .elem = el, .handler = h, .params = params, .ret = ret, .store = .init(self.gpa) };
        try self.handlers.append(self.gpa, ctx);
        ctx.target = member.callback;
        ctx.key = callbackKey(member.callback);
        // A handler replaces what the callback had (connections too).
        try self.program.handler_tops.put(self.gpa, ctx.key.?, ctx);
        switch (member.callback) {
            .declared => |d| d.inst.callbacks[d.index].handler = ctx,
            .builtin => |b| b.setHandler(&ctx.dyn),
        }
    }

    fn callbackKey(cb: CallbackTarget) *const anyopaque {
        return switch (cb) {
            .declared => |d| @ptrCast(&d.inst.callbacks[d.index]),
            .builtin => |b| b.ptr,
        };
    }

    /// `target.name => { }`, or a handler in `Connections { target: x; }`:
    /// chained onto the target's callback.
    fn installConnection(self: *Instance, el: *Elem, h: *const ast.Handler) Error!void {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        var env: Env = .{ .inst = self, .elem = el, .scratch = scratch.allocator() };
        var ident: ast.Expr = undefined;
        const target_expr: *const ast.Expr = if (h.target) |t| blk: {
            ident = .{ .kind = .{ .ident = t.name }, .span = t.span };
            break :blk &ident;
        } else for (el.ast.members) |m| {
            if (m == .binding and std.mem.eql(u8, m.binding.name.name, "target")) break m.binding.value;
        } else return;
        const target = env.compileRef(target_expr) catch return;
        const member = switch (target) {
            .element => |t| try t.inst.memberOf(t.elem, true, h.name.name),
            .global => |g| try g.memberOf(g.comp.root, true, h.name.name),
            else => null,
        } orelse return;
        if (member != .callback) return;
        const params, const ret = switch (member.callback) {
            .declared => |d| .{ d.inst.callbacks[d.index].params, d.inst.callbacks[d.index].ret },
            .builtin => |b| .{ b.params, b.ret },
        };
        const key = callbackKey(member.callback);
        const ctx = try self.arena.allocator().create(HandlerCtx);
        ctx.* = .{
            .dyn = .{ .ctx = ctx, .run = HandlerCtx.runConnection },
            .inst = self,
            .elem = el,
            .handler = h,
            .params = params,
            .ret = ret,
            .store = .init(self.gpa),
            .target = member.callback,
            .key = key,
            .connection = .{
                .prev = self.program.handler_tops.get(key),
                .enabled = if (Generator.isConnections(el)) @ptrCast(@alignCast(self.objs[el.index].builtin.ptr)) else null,
            },
        };
        try self.handlers.append(self.gpa, ctx);
        try self.connections.append(self.gpa, ctx);
        try self.program.handler_tops.put(self.gpa, key, ctx);
        ctx.install(ctx);
    }

    fn setupDynamic(self: *Instance, el: *Elem) Error!void {
        const parent = el.parent.?;
        switch (el.kind) {
            .repeater => |t| {
                const host = self.objs[el.index].repeater;
                const ctx = try self.arena.allocator().create(TrackerCtx);
                ctx.* = .{ .inst = self, .elem = parent, .expr = t.template.repeated.node.model, .store = .init(self.gpa), .action = .{ .repeater = host } };
                try self.trackers.append(self.gpa, ctx);
                ctx.tracker.init(self.gpa, ctx, TrackerCtx.evaluate, TrackerCtx.changed);
                ctx.ready = true;
                try ctx.applyModel(ctx.tracker.value);
            },
            .conditional => |t| {
                const host = self.objs[el.index].conditional;
                const cond = t.template.conditional.condition;
                if (isLiteral(cond)) {
                    if (self.evalSetup(parent, cond, .bool)) |v| host.condition.set(v.asBool());
                } else {
                    const ctx = try self.newBinding(parent, .{ .expr = cond }, .bool, null);
                    try PropRef.of(bool, &host.condition, .bool).setBinding(self.gpa, &ctx.dyn);
                }
                try host.sync();
            },
            else => unreachable,
        }
    }

    // ---- States ----

    fn collectStates(self: *Instance, el: *Elem, st: *const ast.States) Error!void {
        const a = self.arena.allocator();
        for (st.states, 0..) |*state, state_index| {
            _ = state_index;
            for (state.assignments) |asg| {
                var target_el = el;
                var target_inst = self;
                var name: []const u8 = undefined;
                switch (asg.target.kind) {
                    .ident => |n| name = n,
                    .member => |mb| {
                        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
                        defer scratch.deinit();
                        var env: Env = .{ .inst = self, .elem = el, .scratch = scratch.allocator() };
                        const obj = env.compileRef(mb.object) catch continue;
                        if (obj != .element) continue;
                        target_el = obj.element.elem;
                        target_inst = obj.element.inst;
                        name = mb.name.name;
                    },
                    else => continue,
                }
                const member = (try target_inst.memberOf(target_el, true, name)) orelse continue;
                if (member != .property) continue;
                const p = member.property;
                const gop = try self.state_props.getOrPut(self.gpa, p.refs.refs[0].ptr);
                if (!gop.found_existing) {
                    const sp = try a.create(StateProp);
                    sp.* = .{ .prop = p, .elem = target_el, .inst = target_inst, .name = name, .store = .init(self.gpa) };
                    gop.value_ptr.* = sp;
                }
                try gop.value_ptr.*.branches.append(a, .{
                    .cond = state.condition,
                    .value = asg.value,
                    .elem = el,
                    .inst = self,
                    .enter = transition(state.enter, name),
                    .leave = transition(state.leave, name),
                });
            }
        }
    }

    fn transition(list: []const ast.Animate, name: []const u8) ?*const ast.Animate {
        for (list) |*an| for (an.properties) |p| if (std.mem.eql(u8, p.name, name)) return an;
        return null;
    }

    fn setupStates(self: *Instance) Error!void {
        for (self.state_props.values()) |sp| {
            var p = sp.prop;
            if (sp.inst.animationFor(sp.elem, sp.name)) |an| p.anim = an;
            // The fallback: the property's own binding, else its value now.
            for (sp.elem.ast.members) |m| if (m == .binding and std.mem.eql(u8, m.binding.name.name, sp.name)) {
                sp.base_expr = m.binding.value;
            };
            if (sp.base_expr == null) sp.base_value = sp.store.keep(p.refs.refs[0].getUntracked());
            var transitions = false;
            for (sp.branches.items) |b| transitions = transitions or b.enter != null or b.leave != null;
            const ctx = try self.newBinding(sp.elem, .{ .state = sp }, p.ty, null);
            ctx.inst = sp.inst;
            if (transitions) {
                sp.prev = sp.current(self);
                ctx.dyn.choose = BindingCtx.choose;
                for (p.refs.slice()) |r| try r.setChoosingBinding(self.gpa, &ctx.dyn);
            } else if (p.anim) |an| {
                for (p.refs.slice()) |r| try r.setAnimatedBinding(self.gpa, &ctx.dyn, an);
            } else {
                for (p.refs.slice()) |r| try r.setBinding(self.gpa, &ctx.dyn);
            }
        }
    }

    // ---- changed ----

    fn setupChanged(self: *Instance) Error!void {
        for (self.comp.elements.items) |el| for (el.ast.members) |*m| if (m.* == .changed) {
            const member = (try self.memberOf(el, true, m.changed.name.name)) orelse continue;
            if (member != .property) continue;
            const ctx = try self.arena.allocator().create(TrackerCtx);
            ctx.* = .{ .inst = self, .elem = el, .expr = null, .store = .init(self.gpa), .action = .{ .changed = .{ .prop = member.property, .body = m.changed.body } } };
            try self.trackers.append(self.gpa, ctx);
            ctx.tracker.init(self.gpa, ctx, TrackerCtx.evaluate, TrackerCtx.changed);
            ctx.ready = true;
        };
    }

    // ---- Animations ----

    /// The animation of property `name` on `el` (its `animate` blocks and
    /// those in its states, first match), if any.
    fn animationFor(self: *Instance, el: *Elem, name: []const u8) ?zigulee.Animation {
        for (el.ast.members) |*m| switch (m.*) {
            .animate => |*an| for (an.properties) |p| if (std.mem.eql(u8, p.name, name)) return self.animationSettings(el, an),
            .states => |st| for (st.states) |state| for (state.animations) |*an| for (an.properties) |p| {
                if (std.mem.eql(u8, p.name, name)) return self.animationSettings(el, an);
            },
            else => {},
        };
        return null;
    }

    fn animationSettings(self: *Instance, el: *Elem, an: *const ast.Animate) zigulee.Animation {
        var anim: zigulee.Animation = .{};
        for (an.settings) |s| {
            const n = s.name.name;
            if (std.mem.eql(u8, n, "duration")) {
                if (self.evalSetup(el, s.value, .duration)) |v| anim.duration_ms = @intCast(@max(0, v.duration));
            } else if (std.mem.eql(u8, n, "delay")) {
                if (self.evalSetup(el, s.value, .duration)) |v| anim.delay_ms = @intCast(@max(0, v.duration));
            } else if (std.mem.eql(u8, n, "easing")) {
                if (self.evalSetup(el, s.value, .easing)) |v| anim.easing = v.easing;
            } else if (std.mem.eql(u8, n, "iteration-count")) {
                if (self.evalSetup(el, s.value, .int)) |v| anim.iterations = if (v.int < 0) null else @intCast(v.int);
            }
        }
        return anim;
    }

    // ---- Elements ----

    /// The instance holding elements of `comp` (this one or an outer one).
    fn instanceFor(self: *Instance, comp: *Comp) *Instance {
        var it: ?*Instance = self;
        while (it) |inst| : (it = inst.outer) if (inst.comp == comp) return inst;
        unreachable;
    }

    fn outermost(self: *Instance) *Instance {
        var it = self;
        while (it.outer) |o| it = o;
        return it;
    }

    fn itemOf(self: *Instance, el: *const Elem) *core.Item {
        return switch (self.objs[el.index]) {
            .builtin => |b| b.meta.item(b.ptr),
            .component => |sub| sub.rootItem(),
            .repeater => |r| &r.item,
            .conditional => |r| &r.item,
            .none => unreachable,
        };
    }

    fn containerOf(self: *Instance, el: *const Elem) *core.Item {
        return switch (self.objs[el.index]) {
            .builtin => |b| b.meta.content(b.ptr),
            .component => |sub| if (sub.comp.children_target) |t| sub.containerOf(t) else self.itemOf(el),
            else => self.itemOf(el),
        };
    }

    // ---- Members ----

    /// Looks up `name` on element `el` of this instance (`own`: its own
    /// declared members count when `el` is the root), like `memberOf` in
    /// the generated code.
    fn memberOf(self: *Instance, el: *Elem, own: bool, name: []const u8) Error!?Ref {
        const c = self.comp;
        if (own and el == c.root) {
            for (c.props.items, 0..) |p, i| if (std.mem.eql(u8, p.name, name))
                return .{ .property = .{ .refs = single(self.props[i]), .ty = p.ty, .anim = self.animationFor(c.root, name) } };
            for (c.callbacks.items, 0..) |cb, i| if (std.mem.eql(u8, cb.name, name))
                return .{ .callback = .{ .declared = .{ .inst = self, .index = i } } };
            for (c.functions.items, 0..) |f, i| if (std.mem.eql(u8, f.name, name))
                return .{ .comp_function = .{ .inst = self, .index = i } };
        }
        const anim = if (own) self.animationFor(el, name) else null;
        switch (self.objs[el.index]) {
            .builtin => |b| {
                if (b.meta.props(b.ptr, name)) |props| {
                    if (props.component_field) |field| {
                        if (std.mem.eql(u8, field, "title")) return .{ .property = .{ .refs = single(PropRef.of([]const u8, &self.title, .string)), .ty = .string } };
                        return null;
                    }
                    const decl = b.meta.decl.prop(name);
                    return .{ .property = .{
                        .refs = props,
                        .ty = props.refs[0].ty,
                        .anim = anim,
                        .optional = if (decl) |d| d.optional else false,
                    } };
                }
                for (types.constraint_props) |cp| if (std.mem.eql(u8, cp.name, name)) {
                    const cs = b.constraints orelse return null;
                    const field = constraintField(cs, cp.zig) orelse return null;
                    const orientation: core.layout.Orientation = if (std.mem.endsWith(u8, cp.zig, "width") or std.mem.startsWith(u8, cp.zig, "horizontal")) .horizontal else .vertical;
                    const which: ConstraintRead.Field = if (std.mem.startsWith(u8, cp.zig, "min")) .min else if (std.mem.startsWith(u8, cp.zig, "max")) .max else if (std.mem.startsWith(u8, cp.zig, "preferred")) .preferred else .stretch;
                    return .{ .property = .{
                        .refs = single(PropRef.of(?f32, field, cp.ty)),
                        .ty = cp.ty,
                        .optional = true,
                        .read = .{ .item = b.meta.item(b.ptr), .orientation = orientation, .field = which },
                    } };
                };
                if (b.transform) |t| {
                    if (reflect.transformProps(t, name)) |props| return .{ .property = .{ .refs = props, .ty = props.refs[0].ty, .anim = anim, .optional = std.mem.startsWith(u8, name, "transform-origin") } };
                }
                if (b.shadow) |d| {
                    if (reflect.shadowProp(d, name)) |r| return .{ .property = .{ .refs = single(r), .ty = r.ty, .anim = anim } };
                }
                if (b.accessible) |acc| {
                    if (reflect.accessibleProp(acc, name)) |r| return .{ .property = .{ .refs = single(r), .ty = r.ty, .anim = anim } };
                    if (reflect.accessibleCallback(acc, name)) |cb| return .{ .callback = .{ .builtin = cb } };
                }
                if (b.meta.callback(b.ptr, name)) |cb| return .{ .callback = .{ .builtin = cb } };
                if (b.meta.decl.function(name) != null) return .{ .function = .{ .obj = b, .name = name } };
                return null;
            },
            .component => |sub| {
                for (sub.comp.props.items, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) {
                    if (p.visibility == .private) return null;
                    return .{ .property = .{ .refs = single(sub.props[i]), .ty = p.ty, .anim = anim } };
                };
                for (sub.comp.callbacks.items, 0..) |cb, i| if (std.mem.eql(u8, cb.name, name))
                    return .{ .callback = .{ .declared = .{ .inst = sub, .index = i } } };
                for (sub.comp.functions.items, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) {
                    if (!f.public) return null;
                    return .{ .comp_function = .{ .inst = sub, .index = i } };
                };
                var inner = (try sub.memberOf(sub.comp.root, false, name)) orelse return null;
                if (inner == .property) if (anim) |an| {
                    inner.property.anim = an;
                };
                return inner;
            },
            else => return null,
        }
    }

    fn constraintField(cs: *core.LayoutConstraints, zig_name: []const u8) ?*zigulee.Property(?f32) {
        inline for (std.meta.fields(core.LayoutConstraints)) |f| if (std.mem.eql(u8, f.name, zig_name)) return &@field(cs, f.name);
        return null;
    }

    /// Runs a declared function; the result is copied into `out`.
    fn callFunction(self: *Instance, index: usize, args: []const Value, out: Allocator) EvalError!Value {
        const f = self.comp.functions.items[index];
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const locals = try a.alloc(Local, f.decl.params.len);
        for (locals, f.decl.params, args) |*l, param, v| l.* = .{ .name = param.name.name, .value = v };
        var env: Env = .{ .inst = self, .elem = self.comp.root, .locals = locals, .ret = f.ret, .scratch = a };
        const result = (try env.exec(f.decl.body)) orelse try value_mod.defaultValue(f.ret, a);
        return result.clone(out);
    }

    /// Calls a declared function from the host (`function` in the component).
    pub fn call(self: *Instance, name: []const u8, args: []const Value, out: Allocator) ?Value {
        for (self.comp.functions.items, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return self.callFunction(i, args, out) catch null;
        return null;
    }

    fn callDeclared(self: *Instance, index: usize, args: []const Value) Value {
        const slot = self.callbacks[index];
        const h = slot.handler orelse return value_mod.defaultValue(slot.ret, self.arena.allocator()) catch .void;
        return h.dyn.run(h.dyn.ctx, args);
    }

    /// A store for values written by statement `site`.
    fn storeFor(self: *Instance, site: *const anyopaque) Error!*Store {
        const gop = try self.stores.getOrPut(self.gpa, site);
        if (!gop.found_existing) {
            const s = try self.arena.allocator().create(Store);
            s.* = .init(self.gpa);
            gop.value_ptr.* = s;
        }
        return gop.value_ptr.*;
    }

    fn arrayModel(self: *Instance, e: *const ast.Expr) Error!*models.ArrayModel {
        const gop = try self.array_models.getOrPut(self.gpa, e);
        if (!gop.found_existing) {
            const m = try self.gpa.create(models.ArrayModel);
            m.* = .init(self.gpa);
            gop.value_ptr.* = m;
        }
        return gop.value_ptr.*;
    }
};

// ---- Inspection (editor preview) ----

/// An element of a running instance.
pub const ElementRef = struct {
    inst: *Instance,
    elem: *Elem,

    pub fn item(r: ElementRef) *core.Item {
        return r.inst.itemOf(r.elem);
    }

    /// The source file (as given to the compiler) and span of the element.
    pub fn source(r: ElementRef) struct { file: u16, span: ast.Span } {
        return .{ .file = r.elem.comp.outermost().file, .span = r.elem.ast.span };
    }

    pub fn typeName(r: ElementRef) []const u8 {
        return r.elem.ast.type_name.name;
    }

    pub fn id(r: ElementRef) ?[]const u8 {
        return if (r.elem.ast.id) |i| i.name else null;
    }
};

pub const PropertyInfo = struct {
    name: []const u8,
    /// The `.zge` type name.
    type_name: []const u8,
    /// The current value, written as `.zge` (empty if it cannot be shown).
    value: []const u8,
    /// Whether `setProperty` accepts a value for it.
    editable: bool,
};

/// Calls `f(ctx, inst)` for `root` and every instance inside it.
fn visitInstances(root: *Instance, ctx: anytype, comptime f: fn (@TypeOf(ctx), *Instance) bool) bool {
    if (f(ctx, root)) return true;
    for (root.objs) |o| switch (o) {
        .component => |sub| if (visitInstances(sub, ctx, f)) return true,
        .repeater => |r| for (r.instances.items) |ri| {
            if (visitInstances(&ri.inst, ctx, f)) return true;
        },
        .conditional => |c| if (c.instance) |ci| if (visitInstances(&ci.inst, ctx, f)) return true,
        else => {},
    };
    return false;
}

/// The deepest visible item under `p` (in `item`'s parent's coordinates).
fn deepestItemAt(item: *core.Item, p: core.Point) ?*core.Item {
    if (!item.visible.get()) return null;
    const g = item.geometry();
    const local: core.Point = .{ .x = p.x - g.x, .y = p.y - g.y };
    const inside = local.x >= 0 and local.y >= 0 and local.x < g.width and local.y < g.height;
    if (!inside and item.clipsChildren()) return null;
    var children = item.childrenReversed();
    while (children.next()) |c| if (deepestItemAt(c, local)) |hit| return hit;
    return if (inside) item else null;
}

pub const Inspect = struct {
    /// The elements under window point `p`, outermost first: those of
    /// every item from the window down to the deepest one under the point
    /// (for a component, its use comes before the elements inside it).
    pub fn elementsAt(root: *Instance, p: core.Point, gpa: Allocator, out: *std.ArrayList(ElementRef)) Error!void {
        const window = root.window() orelse return;
        const deepest = deepestItemAt(&window.root.item, p) orelse return;
        // Items from the deepest up; their elements are prepended in groups.
        var item: ?*core.Item = deepest;
        while (item) |it| : (item = it.parent) {
            const Search = struct {
                target: *core.Item,
                gpa: Allocator,
                group: std.ArrayList(ElementRef) = .empty,
                failed: bool = false,
                fn visit(s: *@This(), inst: *Instance) bool {
                    for (inst.comp.elements.items) |el| {
                        if (el.isDynamic() or inst.objs[el.index] == .none) continue;
                        if (!Generator.inTree(el)) continue;
                        if (inst.itemOf(el) == s.target) s.group.append(s.gpa, .{ .inst = inst, .elem = el }) catch {
                            s.failed = true;
                        };
                    }
                    return false;
                }
            };
            var search: Search = .{ .target = it, .gpa = gpa };
            defer search.group.deinit(gpa);
            _ = visitInstances(root, &search, Search.visit);
            if (search.failed) return error.OutOfMemory;
            try out.insertSlice(gpa, 0, search.group.items);
        }
    }

    /// The innermost element whose source contains `offset` in `file`
    /// (its first instance).
    pub fn elementAtSource(root: *Instance, file: u16, offset: u32) ?ElementRef {
        const Search = struct {
            file: u16,
            offset: u32,
            best: ?ElementRef = null,
            fn visit(s: *@This(), inst: *Instance) bool {
                for (inst.comp.elements.items) |el| {
                    if (el.isDynamic() or inst.objs[el.index] == .none) continue;
                    if (el.comp.outermost().file != s.file) continue;
                    const span = el.ast.span;
                    if (s.offset < span.start or s.offset > span.end) continue;
                    if (s.best) |b| if (span.end - span.start >= b.elem.ast.span.end - b.elem.ast.span.start) continue;
                    s.best = .{ .inst = inst, .elem = el };
                }
                return false;
            }
        };
        var search: Search = .{ .file = file, .offset = offset };
        _ = visitInstances(root, &search, Search.visit);
        return search.best;
    }

    /// The properties of an element: the declared ones of a component (or
    /// of the instance, for its root), then the built-in ones.
    pub fn properties(ref: ElementRef, arena: Allocator) Error![]PropertyInfo {
        var out: std.ArrayList(PropertyInfo) = .empty;
        const inst = ref.inst;
        const el = ref.elem;
        if (el == inst.comp.root) for (inst.comp.props.items, 0..) |p, i| {
            try out.append(arena, try info(arena, p.name, p.ty, inst.props[i]));
        };
        switch (inst.objs[el.index]) {
            .component => |sub| for (sub.comp.props.items, 0..) |p, i| {
                if (p.visibility == .private) continue;
                try out.append(arena, try info(arena, p.name, p.ty, sub.props[i]));
            },
            else => {},
        }
        // Built-in properties of the element (for a component, of its root).
        var target = ref;
        while (target.inst.objs[target.elem.index] == .component) {
            const sub = target.inst.objs[target.elem.index].component;
            target = .{ .inst = sub, .elem = sub.comp.root };
        }
        if (target.inst.objs[target.elem.index] == .builtin) {
            const b = target.inst.objs[target.elem.index].builtin;
            for (types.geometry_props) |g| if (b.meta.decl.prop(g.name) == null) if (b.meta.props(b.ptr, g.name)) |ps| {
                try out.append(arena, try info(arena, g.name, g.ty, ps.refs[0]));
            };
            for (b.meta.decl.props) |p| {
                const ps = b.meta.props(b.ptr, p.name) orelse continue;
                if (ps.component_field != null or ps.len == 0) continue;
                var pi = try info(arena, p.name, p.ty, ps.refs[0]);
                if (p.read_only) pi.editable = false;
                try out.append(arena, pi);
            }
        }
        return out.items;
    }

    fn info(arena: Allocator, name: []const u8, ty: Type, r: PropRef) Error!PropertyInfo {
        const v = r.getUntracked();
        var text: std.Io.Writer.Allocating = .init(arena);
        const editable = writeValue(&text.writer, v) catch return error.OutOfMemory;
        return .{ .name = name, .type_name = ty.name(), .value = text.written(), .editable = editable };
    }

    /// Writes `v` as `.zge` source; false if it cannot be written (models,
    /// images...).
    fn writeValue(w: *std.Io.Writer, v: Value) std.Io.Writer.Error!bool {
        switch (v) {
            .int => |i| try w.print("{d}", .{i}),
            .float => |f| try w.print("{d}", .{f}),
            .length => |f| try w.print("{d}px", .{f}),
            .duration => |d| try w.print("{d}ms", .{d}),
            .bool => |b| try w.print("{}", .{b}),
            .string => |s| try w.print("\"{f}\"", .{std.zig.fmtString(s)}),
            .color => |c| try w.print("#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b, c.a }),
            .brush => |b| switch (b) {
                .solid => |c| try w.print("#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b, c.a }),
                else => return false,
            },
            .enumeration => |e| try w.writeAll(e.def.values[e.index][0]),
            else => return false,
        }
        return true;
    }

    /// Sets property `name` of the element to the `.zge` expression `text`
    /// (replacing its binding). Returns an error message, or null.
    pub fn setProperty(ref: ElementRef, name: []const u8, text: []const u8, arena: Allocator) Error!?[]const u8 {
        // As written on the element: its own declared members if it is the
        // root, else those of the component it uses, then built-ins.
        const member = (try ref.inst.memberOf(ref.elem, true, name)) orelse return "no such property";
        if (member != .property) return "not a property";
        const p = member.property;
        if (p.read != null) return "a layout constraint cannot be set here";
        var diags: compiler.Diagnostics = .{ .arena = arena };
        _ = try diags.addFile("value", text);
        var parser: compiler.Parser = .init(arena, text, &diags);
        const expr = parser.parseExpr() catch return "not a valid value";
        if (parser.tok.tag != .eof) return "not a valid value";
        var env: Env = .{ .inst = ref.inst, .elem = ref.elem, .scratch = arena };
        const v = env.eval(expr, p.ty) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Runtime, error.Break, error.Continue => return "cannot evaluate this value",
        };
        const kept = (try ref.inst.storeFor(ref.elem)).keep(v);
        if (!valueFits(kept, p.ty)) return try std.fmt.allocPrint(arena, "expected a {s}", .{p.ty.name()});
        for (p.refs.slice()) |r| r.set(kept);
        return null;
    }

    fn valueFits(v: Value, t: Type) bool {
        return switch (t) {
            .int => v == .int,
            .float => v == .float or v == .int,
            .length => v == .length,
            .duration => v == .duration,
            .bool => v == .bool,
            .string => v == .string,
            .color => v == .color,
            .brush => v == .brush or v == .color,
            .enumeration => |e| v == .enumeration and v.enumeration.def == e,
            else => false,
        };
    }
};

fn single(r: PropRef) reflect.Props {
    var p: reflect.Props = .{};
    p.refs[0] = r;
    p.len = 1;
    return p;
}

/// A literal: set once instead of bound.
fn isLiteral(e: *const ast.Expr) bool {
    return switch (e.kind) {
        .number => |n| !std.mem.eql(u8, n.unit, "%"),
        .color => true,
        .string => |parts| parts.len == 1 and parts[0] == .literal,
        .unary => |u| isLiteral(u.operand),
        else => false,
    };
}

// ---- Bindings, handlers, trackers ----

const Percent = struct {
    item: *core.Item,
    height: bool,
};

const BindingCtx = struct {
    dyn: reflect.DynBinding,
    inst: *Instance,
    elem: *Elem,
    source: Source,
    ty: Type,
    percent: ?Percent,
    store: Store,

    const Source = union(enum) {
        expr: *const ast.Expr,
        state: *StateProp,
    };

    fn eval(p: *anyopaque) Value {
        const self: *BindingCtx = @ptrCast(@alignCast(p));
        var scratch: std.heap.ArenaAllocator = .init(self.inst.gpa);
        defer scratch.deinit();
        var env: Env = .{ .inst = self.inst, .elem = self.elem, .percent = self.percent, .scratch = scratch.allocator() };
        const v = switch (self.source) {
            .expr => |e| env.eval(e, self.ty),
            .state => |sp| sp.evaluate(&env),
        } catch |err| {
            log.err("binding failed: {t}", .{err});
            return self.store.keep(value_mod.defaultValue(self.ty, scratch.allocator()) catch .void);
        };
        return self.store.keep(v);
    }

    fn choose(p: *anyopaque) zigulee.Animation {
        const self: *BindingCtx = @ptrCast(@alignCast(p));
        return self.source.state.choose(self.inst);
    }
};

const StateProp = struct {
    prop: Prop,
    elem: *Elem,
    inst: *Instance,
    name: []const u8,
    branches: std.ArrayList(Branch) = .empty,
    base_expr: ?*const ast.Expr = null,
    base_value: Value = .void,
    store: Store,
    prev: u8 = 255,

    const Branch = struct {
        cond: *const ast.Expr,
        value: *const ast.Expr,
        /// The element whose `states` this is, and its instance (conditions
        /// see its scope).
        elem: *Elem,
        inst: *Instance,
        enter: ?*const ast.Animate,
        leave: ?*const ast.Animate,
    };

    fn deinit(sp: *StateProp) void {
        sp.store.deinit();
    }

    fn evaluate(sp: *StateProp, env: *Env) EvalError!Value {
        for (sp.branches.items) |b| {
            var cenv = env.*;
            cenv.inst = b.inst;
            cenv.elem = b.elem;
            if ((try cenv.eval(b.cond, .bool)).asBool()) return cenv.eval(b.value, sp.prop.ty);
        }
        if (sp.base_expr) |e| return env.eval(e, sp.prop.ty);
        return sp.base_value;
    }

    /// The index of the active state (255: none).
    fn current(sp: *StateProp, inst: *Instance) u8 {
        var scratch: std.heap.ArenaAllocator = .init(inst.gpa);
        defer scratch.deinit();
        for (sp.branches.items, 0..) |b, k| {
            var env: Env = .{ .inst = b.inst, .elem = b.elem, .scratch = scratch.allocator() };
            const v = env.eval(b.cond, .bool) catch continue;
            if (v.asBool()) return @intCast(k);
        }
        return 255;
    }

    fn choose(sp: *StateProp, inst: *Instance) zigulee.Animation {
        const now = sp.current(inst);
        const previous = sp.prev;
        sp.prev = now;
        const base = sp.prop.anim orelse zigulee.Animation{};
        if (now == previous) return base;
        if (now != 255) if (sp.branches.items[now].enter) |an| return sp.branches.items[now].inst.animationSettings(sp.branches.items[now].elem, an);
        if (previous != 255) if (sp.branches.items[previous].leave) |an| return sp.branches.items[previous].inst.animationSettings(sp.branches.items[previous].elem, an);
        return base;
    }
};

const HandlerCtx = struct {
    dyn: reflect.DynHandler,
    inst: *Instance,
    elem: *Elem,
    /// Null for native handlers (`Instance.onCallback`).
    handler: ?*const ast.Handler,
    params: []const Type,
    ret: Type,
    store: Store,
    /// The callback it handles, and its address (for `handler_tops`).
    target: ?CallbackTarget = null,
    key: ?*const anyopaque = null,
    /// A connection: what it chains onto.
    connection: ?struct {
        prev: ?*HandlerCtx,
        enabled: ?*core.items.Connections,
    } = null,

    /// Makes `top` the callback's handler (or none).
    fn install(self: *HandlerCtx, top: ?*HandlerCtx) void {
        switch (self.target.?) {
            .declared => |d| d.inst.callbacks[d.index].handler = top,
            .builtin => |b| b.setHandler(if (top) |t| &t.dyn else &none_dyn),
        }
    }

    var none_dyn: reflect.DynHandler = .{ .ctx = undefined, .run = runNone };
    fn runNone(_: *anyopaque, _: []const Value) Value {
        return .void;
    }

    /// Takes a connection out of its callback's chain.
    fn disconnect(self: *HandlerCtx) void {
        const tops = &self.inst.program.handler_tops;
        const key = self.key orelse return;
        const prev = self.connection.?.prev;
        const top = tops.get(key) orelse return;
        if (top == self) {
            self.install(prev);
            if (prev) |p| tops.put(self.inst.gpa, key, p) catch {} else _ = tops.remove(key);
            return;
        }
        var node = top;
        while (node.connection) |*c| {
            if (c.prev == self) {
                c.prev = prev;
                return;
            }
            node = c.prev orelse return;
        }
    }

    /// What it chains onto, then its own statements (while enabled).
    fn runConnection(p: *anyopaque, args: []const Value) Value {
        const self: *HandlerCtx = @ptrCast(@alignCast(p));
        const c = self.connection.?;
        const result = if (c.prev) |prev| prev.dyn.run(prev.dyn.ctx, args) else (value_mod.defaultValue(self.ret, self.inst.arena.allocator()) catch .void);
        if (c.enabled) |e| if (!e.enabled.get()) return result;
        _ = run(p, args);
        return result;
    }

    fn run(p: *anyopaque, args: []const Value) Value {
        const self: *HandlerCtx = @ptrCast(@alignCast(p));
        const h = self.handler.?;
        var scratch: std.heap.ArenaAllocator = .init(self.inst.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        var locals: std.ArrayList(Local) = .empty;
        for (h.params, 0..) |param, i| {
            if (i >= args.len) break;
            locals.append(a, .{ .name = param.name, .value = args[i] }) catch break;
        }
        var env: Env = .{ .inst = self.inst, .elem = self.elem, .locals = locals.items, .ret = if (self.connection != null) .void else self.ret, .scratch = a };
        const result = env.exec(h.body) catch |err| {
            log.err("handler '{s}' failed: {t}", .{ h.name.name, err });
            return value_mod.defaultValue(self.ret, a) catch .void;
        };
        const v = result orelse (value_mod.defaultValue(self.ret, a) catch .void);
        return self.store.keep(v);
    }
};

/// What a PropertyAnimation animates: values captured when it begins, set
/// between them.
const AnimationTarget = struct {
    inst: *Instance,
    elem: *Elem,
    prop: Prop,
    from: ?*const ast.Expr,
    to: *const ast.Expr,
    a: Value = .void,
    b: Value = .void,

    fn begin(self: *AnimationTarget) void {
        var scratch: std.heap.ArenaAllocator = .init(self.inst.gpa);
        defer scratch.deinit();
        var env: Env = .{ .inst = self.inst, .elem = self.elem, .scratch = scratch.allocator() };
        const ty = self.prop.ty;
        self.a = if (self.from) |f| (env.eval(f, ty) catch .void) else value_mod.convert(self.prop.refs.refs[0].get(), ty);
        self.b = env.eval(self.to, ty) catch .void;
    }

    fn apply(self: *AnimationTarget, t: f32) void {
        const a = self.a;
        const b = self.b;
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return;
        const v: Value = switch (a) {
            .int => |x| .{ .int = core.interpolate(i32, x, b.int, t) },
            .float => |x| .{ .float = core.interpolate(f32, x, b.float, t) },
            .length => |x| .{ .length = core.interpolate(f32, x, b.length, t) },
            .duration => |x| .{ .duration = core.interpolate(i64, x, b.duration, t) },
            .color => |x| .{ .color = core.interpolate(zigulee.Color, x, b.color, t) },
            .brush => |x| .{ .brush = core.interpolate(zigulee.Brush, x, b.brush, t) },
            else => return,
        };
        for (self.prop.refs.slice()) |r| r.set(v);
    }
};

/// Passes a Loader's inputs again, to a new instance.
const LoaderCreated = struct {
    trackers: []const *TrackerCtx,

    fn push(self: *LoaderCreated) void {
        for (self.trackers) |t| {
            const li = t.action.loader_input;
            li.loader.setInput(li.name, "value", @ptrCast(&t.tracker.value));
        }
    }
};

const TrackerCtx = struct {
    tracker: zigulee.ChangeTracker(Value) = undefined,
    inst: *Instance,
    elem: *Elem,
    /// What is watched: an expression (`for` models) or a property.
    expr: ?*const ast.Expr,
    store: Store,
    action: Action,
    ready: bool = false,
    /// For `for i in n`.
    count: ?*models.CountModel = null,

    const Action = union(enum) {
        repeater: *RepeaterHost,
        loader_input: struct { loader: *core.items.Loader, name: []const u8 },
        list_input: ListInput,
        changed: struct { prop: Prop, body: []const ast.Stmt },
    };

    fn deinit(self: *TrackerCtx) void {
        if (self.ready) self.tracker.deinit();
        if (self.count) |c| {
            c.deinit();
            self.inst.gpa.destroy(c);
        }
        self.store.deinit();
    }

    fn evaluate(self: *TrackerCtx) Value {
        switch (self.action) {
            .changed => |ch| return self.store.keep(ch.prop.refs.refs[0].get()),
            .repeater, .loader_input, .list_input => {
                var scratch: std.heap.ArenaAllocator = .init(self.inst.gpa);
                defer scratch.deinit();
                var env: Env = .{ .inst = self.inst, .elem = self.elem, .scratch = scratch.allocator() };
                const v = env.eval(self.expr.?, null) catch return .{ .int = 0 };
                return self.store.keep(v);
            },
        }
    }

    fn changed(self: *TrackerCtx, v: Value) void {
        switch (self.action) {
            .repeater => self.applyModel(v) catch log.err("out of memory updating a repeater", .{}),
            .loader_input => |li| li.loader.setInput(li.name, "value", @ptrCast(&v)),
            .list_input => |li| if (v == .model) li.apply(li.ptr, v.model),
            .changed => |ch| {
                var scratch: std.heap.ArenaAllocator = .init(self.inst.gpa);
                defer scratch.deinit();
                var env: Env = .{ .inst = self.inst, .elem = self.elem, .scratch = scratch.allocator() };
                _ = env.exec(ch.body) catch |err| log.err("changed handler failed: {t}", .{err});
            },
        }
    }

    /// `for x in model` / `for i in n`.
    fn applyModel(self: *TrackerCtx, v: Value) Error!void {
        const host = self.action.repeater;
        switch (v) {
            .int => |n| {
                const first = self.count == null;
                if (first) {
                    const c = try self.inst.gpa.create(models.CountModel);
                    c.* = .{};
                    self.count = c;
                }
                self.count.?.setCount(@intCast(@max(n, 0)));
                if (first) try host.setModel(self.count.?.model());
            },
            .model => |m| try host.setModel(m),
            else => {},
        }
    }
};

/// A built-in's list property, set from models of values.
const ListInput = struct {
    ptr: *anyopaque,
    apply: *const fn (*anyopaque, zigulee.Model(Value)) void,

    fn make(comptime E: type, a: Allocator, prop: *anyopaque) Allocator.Error!ListInput {
        const S = struct {
            prop: *core.Property(zigulee.Model(E)),
            adapters: [2]reflect.ValueModelAdapter(E) = .{ .{}, .{} },
            next: u1 = 0,

            fn apply(p: *anyopaque, m: zigulee.Model(Value)) void {
                const self: *@This() = @ptrCast(@alignCast(p));
                const adapter = &self.adapters[self.next];
                self.next +%= 1;
                adapter.inner = m;
                self.prop.set(adapter.model());
            }
        };
        const s = try a.create(S);
        s.* = .{ .prop = @ptrCast(@alignCast(prop)) };
        return .{ .ptr = s, .apply = S.apply };
    }
};

// ---- References ----

const Prop = struct {
    refs: reflect.Props,
    ty: Type,
    anim: ?zigulee.Animation = null,
    /// A `Property(?T)`.
    optional: bool = false,
    /// Reading a layout constraint gives the computed layout size.
    read: ?ConstraintRead = null,
};

const ConstraintRead = struct {
    item: *core.Item,
    orientation: core.layout.Orientation,
    field: Field,

    const Field = enum { min, max, preferred, stretch };

    fn value(r: ConstraintRead) f32 {
        const info = r.item.layoutInfo(r.orientation);
        return switch (r.field) {
            .min => info.min,
            .max => info.max,
            .preferred => info.preferred,
            .stretch => info.stretch,
        };
    }
};

const CallbackTarget = union(enum) {
    declared: struct { inst: *Instance, index: usize },
    builtin: reflect.CallbackRef,
};

const Ref = union(enum) {
    value: Value,
    element: struct { inst: *Instance, elem: *Elem },
    property: Prop,
    callback: CallbackTarget,
    function: struct { obj: BuiltinObj, name: []const u8 },
    /// `function name(...)` declared in a component.
    comp_function: struct { inst: *Instance, index: usize },
    global_fn: []const u8,
    enum_type: *const types.Enum,
    global: *Instance,
    key_namespace,
};

const Local = struct { name: []const u8, value: Value };

/// `Break` and `Continue` leave a loop's body (only loops catch them: the
/// compiler checks they are in one).
const EvalError = Allocator.Error || error{ Runtime, Break, Continue };

/// A `let` variable, or a statement loop's variable.
const Var = struct { name: []const u8, value: Value, ty: Type };

// ---- Evaluation ----

const Env = struct {
    inst: *Instance,
    /// Unqualified names resolve against this element (then the roots).
    elem: *Elem,
    locals: []const Local = &.{},
    percent: ?Percent = null,
    ret: Type = .void,
    scratch: Allocator,
    /// `let`s and loop variables in scope, innermost last.
    vars: std.ArrayList(Var) = .empty,

    fn fail(env: *Env, comptime fmt: []const u8, args: anytype) EvalError {
        _ = env;
        log.err(fmt, args);
        return error.Runtime;
    }

    fn eval(env: *Env, e: *const ast.Expr, expected: ?Type) EvalError!Value {
        const v = try env.evalValue(e, expected);
        if (expected) |t| return value_mod.convert(v, t);
        return v;
    }

    fn file(env: *Env) u16 {
        return env.inst.comp.outermost().file;
    }

    fn evalValue(env: *Env, e: *const ast.Expr, expected: ?Type) EvalError!Value {
        // Contextual names: enum values and easing curves.
        if (e.kind == .ident) if (expected) |t| switch (t) {
            .enumeration => |en| for (en.values, 0..) |v, i| if (std.mem.eql(u8, v[0], e.kind.ident))
                return .{ .enumeration = .{ .def = en, .index = @intCast(i) } },
            .easing => for (types.easing_names) |n| if (std.mem.eql(u8, n[0], e.kind.ident)) {
                inline for (std.meta.fields(zigulee.Easing)) |f| if (f.type == void and std.mem.eql(u8, f.name, n[1]))
                    return .{ .easing = @unionInit(zigulee.Easing, f.name, {}) };
            },
            else => {},
        };
        switch (e.kind) {
            .number => |n| return env.number(n),
            .color => |c| return .{ .color = .rgba(c) },
            .string => |parts| return env.string(parts),
            .tr => |t| return env.translated(t),
            .gradient => |gr| return env.gradient(gr),
            .ident, .member => return env.refToValue(try env.compileRef(e)),
            .call => |c| return env.call(c.callee, c.args, expected),
            .array => |list| return env.array(e, list, expected),
            .image_url => |url| {
                var img = env.inst.program.image(env.inst.comp.outermost().dir, url.path);
                if (url.nine_slice) |v| img.nine_slice = .{ .top = v[0], .right = v[1], .bottom = v[2], .left = v[3] };
                return .{ .image = img };
            },
            .audio_url => |path| return .{ .audio = env.inst.program.audio(env.inst.comp.outermost().dir, path) },
            .video_url => |path| return .{ .video = env.inst.program.video(env.inst.comp.outermost().dir, path) },
            .model_url => |path| return .{ .model3d = env.inst.program.model(env.inst.comp.outermost().dir, path) },
            .lambda => return env.fail("a function of a row goes in a model's filter or sort", .{}),
            .struct_literal => |fields| {
                const t = expected orelse return env.fail("the type of a struct literal is unknown", .{});
                if (t != .structure) return env.fail("a struct literal where {s} is expected", .{t.name()});
                const def = t.structure;
                const values = try env.scratch.alloc(Value, def.fields.len);
                for (values, def.fields) |*v, f| v.* = try value_mod.defaultValue(f.ty, env.scratch);
                for (fields) |f| for (def.fields, 0..) |df, i| if (std.mem.eql(u8, df.name, f.name.name)) {
                    values[i] = try env.eval(f.value, df.ty);
                };
                return .{ .structure = .{ .def = def, .fields = values } };
            },
            .index => |ix| {
                const m = try env.evalValue(ix.object, null);
                if (m != .model) return env.fail("only models can be indexed", .{});
                const i = try env.eval(ix.index, .int);
                if (m.model.rowData(@intCast(@max(i.int, 0)))) |row| return row;
                return if (expected) |t| value_mod.defaultValue(t, env.scratch) else .{ .int = 0 };
            },
            .unary => |u| {
                const v = try env.evalValue(u.operand, null);
                return switch (u.op) {
                    .bang => .{ .bool = !v.asBool() },
                    .plus => v,
                    .minus => switch (v) {
                        .int => |x| .{ .int = -%x },
                        .float => |x| .{ .float = -x },
                        .length => |x| .{ .length = -x },
                        .duration => |x| .{ .duration = -x },
                        else => env.fail("cannot negate this value", .{}),
                    },
                    else => env.fail("unknown operator", .{}),
                };
            },
            .binary => |b| return env.binary(b.op, b.lhs, b.rhs),
            .ternary => |t| {
                const cond = try env.eval(t.cond, .bool);
                return env.evalValue(if (cond.asBool()) t.then else t.otherwise, expected);
            },
        }
    }

    fn number(env: *Env, n: anytype) EvalError!Value {
        if (n.unit.len == 0) return if (n.is_int) .{ .int = @intFromFloat(n.value) } else .{ .float = @floatCast(n.value) };
        if (std.mem.eql(u8, n.unit, "px")) return .{ .length = @floatCast(n.value) };
        if (std.mem.eql(u8, n.unit, "ms")) return .{ .duration = @intFromFloat(n.value) };
        if (std.mem.eql(u8, n.unit, "s")) return .{ .duration = @intFromFloat(n.value * 1000) };
        if (std.mem.eql(u8, n.unit, "deg")) return .{ .float = @floatCast(n.value) };
        if (std.mem.eql(u8, n.unit, "%")) {
            const p = env.percent orelse return env.fail("a percentage outside width or height", .{});
            const base = if (p.height) p.item.height.get() else p.item.width.get();
            return .{ .length = base * @as(f32, @floatCast(n.value / 100)) };
        }
        return env.fail("unknown unit '{s}'", .{n.unit});
    }

    /// A gradient in scratch memory (bindings and assignments keep a copy).
    fn gradient(env: *Env, gr: ast.Gradient) EvalError!Value {
        var stops = gr.stops;
        var angle: f32 = 180;
        // The first argument is the angle if it is a number.
        var first: ?Value = null;
        if (stops[0].position == null) {
            const v = try env.evalValue(stops[0].color, null);
            if (gr.shape == .linear and stops.len > 1 and (v == .int or v == .float)) {
                angle = value_mod.convert(v, .float).float;
                stops = stops[1..];
            } else first = v;
        }
        const out = try env.scratch.alloc(core.GradientStop, stops.len);
        for (out, stops, 0..) |*o, s, i| {
            const color = if (i == 0 and first != null) first.? else try env.eval(s.color, .color);
            if (color != .color) return env.fail("a gradient's stops are colors", .{});
            const position: f32 = if (s.position) |p| switch (p.kind) {
                .number => |n| if (std.mem.eql(u8, n.unit, "%")) @floatCast(n.value / 100) else (try env.eval(p, .float)).float,
                else => (try env.eval(p, .float)).float,
            } else core.unplaced;
            o.* = .{ .color = color.color, .position = position };
        }
        core.placeStops(out);
        switch (gr.shape) {
            .linear => {
                const g = try env.scratch.create(core.LinearGradient);
                g.* = .{ .angle = angle, .stops = .init(out) };
                return .{ .brush = .{ .linear_gradient = g } };
            },
            .radial => {
                const g = try env.scratch.create(core.RadialGradient);
                g.* = .{ .stops = .init(out) };
                return .{ .brush = .{ .radial_gradient = g } };
            },
        }
    }

    fn string(env: *Env, parts: []const ast.StringPart) EvalError!Value {
        if (parts.len == 1 and parts[0] == .literal) return .{ .string = parts[0].literal };
        var out: std.Io.Writer.Allocating = .init(env.scratch);
        for (parts) |part| switch (part) {
            .literal => |lit| out.writer.writeAll(lit) catch return error.OutOfMemory,
            .expr => |pe| (try env.evalValue(pe, null)).format(&out.writer) catch return error.OutOfMemory,
        };
        return .{ .string = out.written() };
    }

    /// `@tr(...)`, as the generated code does it (the analysis checked it).
    fn translated(env: *Env, t: ast.Tr) EvalError!Value {
        const n: i64 = if (t.count) |c| (try env.eval(c, .int)).int else 0;
        const template = core.i18n.translate(.{ .context = t.context, .id = t.text, .plural = t.plural, .n = n });
        const args = try env.scratch.alloc(core.i18n.Arg, t.args.len);
        for (args, t.args) |*arg, a| {
            var text: std.Io.Writer.Allocating = .init(env.scratch);
            (try env.evalValue(a, null)).format(&text.writer) catch return error.OutOfMemory;
            arg.* = .{ .string = text.written() };
        }
        var out: std.Io.Writer.Allocating = .init(env.scratch);
        core.i18n.format(&out.writer, template, args, n) catch return error.OutOfMemory;
        return .{ .string = out.written() };
    }

    fn array(env: *Env, e: *const ast.Expr, list: []const *ast.Expr, expected: ?Type) EvalError!Value {
        const elem: ?Type = if (expected) |t| (if (t == .model) t.model.* else null) else null;
        const values = try env.scratch.alloc(Value, list.len);
        for (values, list) |*v, item| v.* = try env.eval(item, elem);
        const m = try env.inst.arrayModel(e);
        return .{ .model = try m.update(values) };
    }

    fn binary(env: *Env, op: compiler.lexer.Tag, lhs_e: *const ast.Expr, rhs_e: *const ast.Expr) EvalError!Value {
        const lhs = try env.evalValue(lhs_e, null);
        switch (op) {
            .and_and => return .{ .bool = lhs.asBool() and (try env.eval(rhs_e, .bool)).asBool() },
            .or_or => return .{ .bool = lhs.asBool() or (try env.eval(rhs_e, .bool)).asBool() },
            else => {},
        }
        // `mode == dark`: the right side may be a bare value of the left's enum.
        const hint: ?Type = if ((op == .equal_equal or op == .bang_equal) and lhs == .enumeration) .{ .enumeration = lhs.enumeration.def } else null;
        const rhs = try env.evalValue(rhs_e, hint);
        switch (op) {
            .equal_equal => return .{ .bool = value_mod.equal(lhs, rhs) },
            .bang_equal => return .{ .bool = !value_mod.equal(lhs, rhs) },
            .less => return .{ .bool = value_mod.compare(lhs, rhs) == .lt },
            .less_equal => return .{ .bool = value_mod.compare(lhs, rhs) != .gt },
            .greater => return .{ .bool = value_mod.compare(lhs, rhs) == .gt },
            .greater_equal => return .{ .bool = value_mod.compare(lhs, rhs) != .lt },
            .plus, .minus, .star, .slash => {
                if (op == .plus and (lhs == .string or rhs == .string)) {
                    var out: std.Io.Writer.Allocating = .init(env.scratch);
                    lhs.format(&out.writer) catch return error.OutOfMemory;
                    rhs.format(&out.writer) catch return error.OutOfMemory;
                    return .{ .string = out.written() };
                }
                const sym: u8 = switch (op) {
                    .plus => '+',
                    .minus => '-',
                    .star => '*',
                    else => '/',
                };
                return value_mod.arithmetic(sym, lhs, rhs) catch env.fail("invalid operands for '{c}'", .{sym});
            },
            else => return env.fail("unknown operator", .{}),
        }
    }

    /// `model.filter(row => ...)`, `.sort(row => key)`, `.reverse()`: the
    /// rows of a model kept at this site (`site`).
    fn modelOp(env: *Env, site: *const ast.Expr, src: zigulee.Model(Value), op: []const u8, args: []const *ast.Expr) EvalError!Value {
        var rows: std.ArrayList(Value) = .empty;
        var keys: std.ArrayList(Value) = .empty;
        const lambda = if (args.len == 1 and args[0].kind == .lambda) args[0].kind.lambda else null;
        var i: usize = 0;
        while (i < src.rowCount()) : (i += 1) {
            const row = src.rowData(i) orelse continue;
            if (lambda) |l| {
                const outer = env.vars.items.len;
                defer env.vars.shrinkRetainingCapacity(outer);
                try env.vars.append(env.scratch, .{ .name = l.param.name, .value = row, .ty = .void });
                const v = try env.evalValue(l.body, null);
                if (std.mem.eql(u8, op, "filter")) {
                    if (v.asBool()) try rows.append(env.scratch, row);
                    continue;
                }
                if (std.mem.eql(u8, op, "map")) {
                    try rows.append(env.scratch, try env.own(v));
                    continue;
                }
                try keys.append(env.scratch, try env.own(v));
            }
            try rows.append(env.scratch, row);
        }
        if (std.mem.eql(u8, op, "reverse")) std.mem.reverse(Value, rows.items);
        if (std.mem.eql(u8, op, "sort") and keys.items.len == rows.items.len) {
            const order = try env.scratch.alloc(usize, rows.items.len);
            for (order, 0..) |*o, k| o.* = k;
            std.sort.block(usize, order, keys.items, struct {
                fn less(k: []const Value, a: usize, b: usize) bool {
                    if (k[a] == .bool and k[b] == .bool) return !k[a].bool and k[b].bool;
                    if (k[a] == .string and k[b] == .string) return std.mem.order(u8, k[a].string, k[b].string) == .lt;
                    return value_mod.compare(k[a], k[b]) == .lt;
                }
            }.less);
            const copy = try env.scratch.dupe(Value, rows.items);
            for (rows.items, order) |*r, o| r.* = copy[o];
        }
        const m = try env.inst.arrayModel(site);
        return .{ .model = try m.update(rows.items) };
    }

    fn call(env: *Env, callee: *const ast.Expr, args: []const *ast.Expr, expected: ?Type) EvalError!Value {
        _ = expected;
        if (callee.kind == .ident and std.mem.eql(u8, callee.kind.ident, "cubic-bezier")) {
            var c: [4]f32 = .{ 0, 0, 1, 1 };
            for (args[0..@min(args.len, 4)], 0..) |arg, i| c[i] = (try env.eval(arg, .float)).asFloat();
            return .{ .easing = .{ .cubic_bezier = c } };
        }
        if (callee.kind == .member) {
            const m = callee.kind.member;
            const name = m.name.name;
            if (std.mem.eql(u8, name, "filter") or std.mem.eql(u8, name, "sort") or std.mem.eql(u8, name, "reverse") or std.mem.eql(u8, name, "map")) {
                const obj = env.evalValue(m.object, null) catch null;
                if (obj) |o| if (o == .model) return env.modelOp(callee, o.model, name, args);
            }
        }
        if (callee.kind == .ident and std.mem.eql(u8, callee.kind.ident, "spring")) {
            const bounce = if (args.len > 0) (try env.eval(args[0], .float)).asFloat() else 0;
            return .{ .easing = .{ .spring = bounce } };
        }
        const ref = try env.compileRef(callee);
        switch (ref) {
            .callback => |cb| {
                const params = switch (cb) {
                    .declared => |d| d.inst.callbacks[d.index].params,
                    .builtin => |b| b.params,
                };
                const values = try env.scratch.alloc(Value, params.len);
                for (values, params, 0..) |*v, t, i| v.* = if (i < args.len) try env.eval(args[i], t) else try value_mod.defaultValue(t, env.scratch);
                return switch (cb) {
                    .declared => |d| d.inst.callDeclared(d.index, values),
                    .builtin => |b| b.call(values),
                };
            },
            .function => |f| {
                const params = if (f.obj.meta.decl.function(f.name)) |decl| decl.params else &.{};
                const values = try env.scratch.alloc(Value, params.len);
                for (values, params, 0..) |*v, t, i| v.* = if (i < args.len) try env.eval(args[i], t) else try value_mod.defaultValue(t, env.scratch);
                _ = f.obj.meta.function(f.obj.ptr, f.name, values);
                return .void;
            },
            .comp_function => |cf| {
                const decl = cf.inst.comp.functions.items[cf.index];
                const values = try env.scratch.alloc(Value, decl.params.len);
                for (values, decl.params, 0..) |*v, t, i| v.* = if (i < args.len) try env.eval(args[i], t) else try value_mod.defaultValue(t, env.scratch);
                return cf.inst.callFunction(cf.index, values, env.scratch);
            },
            .global_fn => |name| return env.globalCall(name, args),
            else => return env.fail("not a callback or function", .{}),
        }
    }

    fn globalCall(env: *Env, name: []const u8, args: []const *ast.Expr) EvalError!Value {
        if (std.mem.eql(u8, name, "debug")) {
            var out: std.Io.Writer.Allocating = .init(env.scratch);
            for (args, 0..) |a, i| {
                if (i > 0) out.writer.writeByte(' ') catch return error.OutOfMemory;
                (try env.evalValue(a, null)).format(&out.writer) catch return error.OutOfMemory;
            }
            // No standard error without an OS: the application's log (a
            // device sends it to its serial port, say).
            if (builtin.os.tag == .freestanding) std.log.info("{s}", .{out.written()}) else std.debug.print("{s}\n", .{out.written()});
            return .void;
        }
        if (std.mem.eql(u8, name, "open-url")) {
            if (args.len != 1) return env.fail("'open-url' takes 1 argument: the URL", .{});
            const url = try env.evalValue(args[0], .string);
            return .{ .bool = core.links.openUrl(if (url == .string) url.string else "") };
        }
        if (std.mem.startsWith(u8, name, "json-")) {
            if (args.len != 2) return env.fail("'{s}' takes 2 arguments: the JSON text and a path", .{name});
            const text = try env.evalValue(args[0], .string);
            const path = try env.evalValue(args[1], .string);
            const t = if (text == .string) text.string else "";
            const p = if (path == .string) path.string else "";
            if (std.mem.eql(u8, name, "json-number")) return .{ .float = core.json.number(t, p) };
            if (std.mem.eql(u8, name, "json-count")) return .{ .int = core.json.count(t, p) };
            var out: std.ArrayList(u8) = .empty;
            core.json.get(env.scratch, &out, t, p) catch return error.OutOfMemory;
            return .{ .string = out.items };
        }
        if (args.len == 0) return env.fail("'{s}' needs arguments", .{name});
        const a = try env.evalValue(args[0], null);
        if (std.mem.eql(u8, name, "abs")) return switch (a) {
            .int => |x| .{ .int = @intCast(@abs(x)) },
            .float => |x| .{ .float = @abs(x) },
            .length => |x| .{ .length = @abs(x) },
            .duration => |x| .{ .duration = @intCast(@abs(x)) },
            else => a,
        };
        if (std.mem.eql(u8, name, "sqrt")) return .{ .float = @sqrt(a.asFloat()) };
        if (std.mem.eql(u8, name, "sin")) return .{ .float = @sin(std.math.degreesToRadians(a.asFloat())) };
        if (std.mem.eql(u8, name, "cos")) return .{ .float = @cos(std.math.degreesToRadians(a.asFloat())) };
        inline for (.{ "round", "floor", "ceil" }) |f| if (std.mem.eql(u8, name, f)) {
            if (a == .int) return a;
            return .{ .int = core.intFromFloat(i32, @field(std.math, if (std.mem.eql(u8, f, "round")) "round" else f)(a.asFloat())) };
        };
        if (args.len < 2) return env.fail("'{s}' needs two arguments", .{name});
        const b = try env.evalValue(args[1], null);
        // Two numbers of the same kind, or ints and floats as floats.
        const same = std.meta.activeTag(a) == std.meta.activeTag(b);
        if (same and a == .int) {
            const x = a.int;
            const y = b.int;
            if (std.mem.eql(u8, name, "min")) return .{ .int = @min(x, y) };
            if (std.mem.eql(u8, name, "max")) return .{ .int = @max(x, y) };
            return .{ .int = if (y == 0) 0 else @mod(x, y) };
        }
        if (same and a == .duration) {
            const x = a.duration;
            const y = b.duration;
            if (std.mem.eql(u8, name, "min")) return .{ .duration = @min(x, y) };
            if (std.mem.eql(u8, name, "max")) return .{ .duration = @max(x, y) };
            return .{ .duration = if (y == 0) 0 else @mod(x, y) };
        }
        const x = a.asFloat();
        const y = b.asFloat();
        const r = if (std.mem.eql(u8, name, "min")) @min(x, y) else if (std.mem.eql(u8, name, "max")) @max(x, y) else if (y == 0) 0 else @mod(x, y);
        return if (same and a == .length) .{ .length = r } else .{ .float = r };
    }

    // ---- Names ----

    fn lookupName(env: *Env, name: []const u8) EvalError!Ref {
        if (env.findVar(name)) |v| return .{ .value = v.value };
        // Innermost first: handler arguments, then loop variables.
        var i = env.locals.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, env.locals[i].name, name)) return .{ .value = env.locals[i].value };
        }
        var it: ?*Instance = env.inst;
        while (it) |inst| : (it = inst.outer) {
            if (inst.comp.template == .repeated) {
                const r = inst.comp.template.repeated.node;
                if (r.item) |item| if (std.mem.eql(u8, item.name, name)) return .{ .value = inst.data.get() };
                if (r.index) |index| if (std.mem.eql(u8, index.name, name)) return .{ .value = .{ .int = inst.index.get() } };
            }
        }
        if (std.mem.eql(u8, name, "true")) return .{ .value = .{ .bool = true } };
        if (std.mem.eql(u8, name, "false")) return .{ .value = .{ .bool = false } };
        if (std.mem.eql(u8, name, "self")) return .{ .element = .{ .inst = env.inst, .elem = env.elem } };
        if (std.mem.eql(u8, name, "root")) {
            const top = env.inst.outermost();
            return .{ .element = .{ .inst = top, .elem = top.comp.root } };
        }
        if (std.mem.eql(u8, name, "parent")) {
            const p = env.elem.visualParent() orelse return env.fail("the root element has no parent", .{});
            return .{ .element = .{ .inst = env.inst.instanceFor(p.comp), .elem = p } };
        }
        const zig = try codegen.zigName(env.scratch, name);
        it = env.inst;
        while (it) |inst| : (it = inst.outer) {
            if (inst.comp.ids.get(zig)) |e| return .{ .element = .{ .inst = inst, .elem = e } };
        }
        for (types.global_functions) |f| if (std.mem.eql(u8, f, name)) return .{ .global_fn = f };
        const gen = env.inst.program.gen;
        if (gen.typeIn(env.file(), name)) |t| if (t == .enumeration) return .{ .enum_type = t.enumeration };
        if (gen.compIn(env.file(), name)) |gc| if (gc.is_global and gc != env.inst.comp) return .{ .global = try env.inst.program.global(gc) };
        if (gen.compIn(env.file(), name)) |gc| if (!gc.is_global and gc.template == .none and !gc.showsWindow())
            return .{ .value = .{ .component = try env.inst.program.factory(gc) } };
        if (try env.inst.memberOf(env.elem, true, name)) |m| return m;
        // Then the declared members of each enclosing component.
        it = env.inst;
        while (it) |inst| : (it = inst.outer) {
            if (inst.comp.root == env.elem) continue;
            if (try inst.memberOf(inst.comp.root, true, name)) |m| return m;
        }
        if (std.mem.eql(u8, name, "Key")) return .key_namespace;
        if (types.namedColor(name)) |rgba| return .{ .value = .{ .color = .rgba(rgba) } };
        return env.fail("unknown name '{s}'", .{name});
    }

    fn compileRef(env: *Env, e: *const ast.Expr) EvalError!Ref {
        switch (e.kind) {
            .ident => |name| return env.lookupName(name),
            .member => |m| {
                const obj = try env.compileRef(m.object);
                const name = m.name.name;
                switch (obj) {
                    .global => |g| {
                        if (try g.memberOf(g.comp.root, true, name)) |r| return r;
                        return env.fail("no member '{s}'", .{name});
                    },
                    .key_namespace => {
                        inline for (types.key_names) |k| if (std.mem.eql(u8, k[0], name)) return .{ .value = .{ .string = @field(core.input.Key, k[1]) } };
                        return env.fail("unknown key '{s}'", .{name});
                    },
                    .enum_type => |en| {
                        for (en.values, 0..) |v, i| if (std.mem.eql(u8, v[0], name)) return .{ .value = .{ .enumeration = .{ .def = en, .index = @intCast(i) } } };
                        return env.fail("no value '{s}'", .{name});
                    },
                    .element => |el| {
                        if (try el.inst.memberOf(el.elem, true, name)) |r| return r;
                        return env.fail("no member '{s}'", .{name});
                    },
                    else => {
                        const v = try env.refToValue(obj);
                        switch (v) {
                            .model => |model| if (std.mem.eql(u8, name, "length")) return .{ .value = .{ .int = @intCast(model.rowCount()) } },
                            .image => |img| {
                                if (std.mem.eql(u8, name, "width")) return .{ .value = .{ .int = @intCast(img.width) } };
                                if (std.mem.eql(u8, name, "height")) return .{ .value = .{ .int = @intCast(img.height) } };
                            },
                            .key_event => |k| {
                                if (std.mem.eql(u8, name, "text")) return .{ .value = .{ .string = k.text } };
                                if (std.mem.eql(u8, name, "modifiers")) return .{ .value = .{ .modifiers = k.modifiers } };
                                if (std.mem.eql(u8, name, "repeat")) return .{ .value = .{ .bool = k.repeat } };
                            },
                            .pointer_event => |p| {
                                if (std.mem.eql(u8, name, "kind")) return .{ .value = .{ .enumeration = .{ .def = &types.pointer_event_kind, .index = value_mod.enumIndex(&types.pointer_event_kind, @tagName(p.kind)) } } };
                                if (std.mem.eql(u8, name, "button")) return .{ .value = .{ .enumeration = .{ .def = &types.pointer_event_button, .index = value_mod.enumIndex(&types.pointer_event_button, @tagName(p.button)) } } };
                                if (std.mem.eql(u8, name, "modifiers")) return .{ .value = .{ .modifiers = p.modifiers } };
                            },
                            .modifiers => |mods| inline for (.{ "shift", "control", "alt", "meta" }) |f| if (std.mem.eql(u8, name, f)) return .{ .value = .{ .bool = @field(mods, f) } },
                            .structure => |s| for (s.def.fields, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return .{ .value = s.fields[i] },
                            else => {},
                        }
                        return env.fail("no field '{s}'", .{name});
                    },
                }
            },
            else => return .{ .value = try env.evalValue(e, null) },
        }
    }

    fn refToValue(env: *Env, r: Ref) EvalError!Value {
        return switch (r) {
            .value => |v| v,
            .property => |p| if (p.read) |read| .{ .length = read.value() } else p.refs.refs[0].get(),
            else => env.fail("not a value", .{}),
        };
    }

    // ---- Statements ----

    /// Runs statements; returns the value of a `return` (`.void` for a
    /// bare one), or null if none ran.
    fn exec(env: *Env, stmts: []const ast.Stmt) EvalError!?Value {
        // A block: its `let`s go at its end.
        const outer = env.vars.items.len;
        defer env.vars.shrinkRetainingCapacity(outer);
        for (stmts) |*s| {
            if (try env.execOne(s)) |r| return r;
        }
        return null;
    }

    fn findVar(env: *Env, name: []const u8) ?*Var {
        var i = env.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, env.vars.items[i].name, name)) return &env.vars.items[i];
        }
        return null;
    }

    /// A value a variable keeps: strings copied (a property's may change).
    fn own(env: *Env, v: Value) EvalError!Value {
        return if (v == .string) .{ .string = try env.scratch.dupe(u8, v.string) } else v;
    }

    /// Runs a loop's body once; true to leave the loop.
    fn turn(env: *Env, body: []const ast.Stmt, ret: *?Value) EvalError!bool {
        ret.* = env.exec(body) catch |err| switch (err) {
            error.Break => return true,
            error.Continue => return false,
            else => |e| return e,
        };
        return ret.* != null;
    }

    fn execOne(env: *Env, s: *const ast.Stmt) EvalError!?Value {
        switch (s.kind) {
            .expr => |e| _ = env.evalValue(e, null) catch |err| switch (err) {
                error.Runtime => {},
                else => |x| return x,
            },
            .assign => |a| {
                if (a.target.kind == .ident) if (env.findVar(a.target.kind.ident)) |v| {
                    const op: @TypeOf(a.op) = switch (a.op) {
                        .plus_equal => .plus,
                        .minus_equal => .minus,
                        .star_equal => .star,
                        else => .slash,
                    };
                    const value = if (a.op == .equal) try env.eval(a.value, v.ty) else value_mod.convert(try env.binary(op, a.target, a.value), v.ty);
                    v.value = try env.own(value);
                    return null;
                };
                const ref = try env.compileRef(a.target);
                if (ref != .property) return env.fail("only properties can be assigned", .{});
                const p = ref.property;
                var v = try env.eval(a.value, if (a.op == .equal) p.ty else null);
                if (a.op == .plus_equal and p.ty == .string) {
                    v = try env.binary(.plus, a.target, a.value);
                } else if (a.op != .equal) {
                    const current = try env.refToValue(ref);
                    const sym: u8 = switch (a.op) {
                        .plus_equal => '+',
                        .minus_equal => '-',
                        .star_equal => '*',
                        else => '/',
                    };
                    v = value_mod.convert(value_mod.arithmetic(sym, current, v) catch return env.fail("invalid operands for '{c}='", .{sym}), p.ty);
                }
                const kept = (try env.inst.storeFor(s)).keep(v);
                for (p.refs.slice()) |r| {
                    if (p.optional) {
                        r.set(kept);
                    } else if (p.anim) |anim| {
                        try r.setAnimated(env.inst.gpa, kept, anim);
                    } else r.set(kept);
                }
            },
            .@"if" => |i| {
                const cond = try env.eval(i.cond, .bool);
                return env.exec(if (cond.asBool()) i.then else i.otherwise);
            },
            .@"return" => |value| {
                if (value) |v| return try env.eval(v, env.ret);
                return .void;
            },
            .let => |l| {
                const ty = env.inst.program.gen.let_types.get(s) orelse return env.fail("the type of '{s}' is unknown", .{l.name.name});
                const v = try env.own(try env.eval(l.value, ty));
                try env.vars.append(env.scratch, .{ .name = l.name.name, .value = v, .ty = ty });
            },
            .@"while" => |w| {
                var ret: ?Value = null;
                while ((try env.eval(w.cond, .bool)).asBool()) {
                    if (try env.turn(w.body, &ret)) break;
                }
                return ret;
            },
            .@"for" => |f| {
                const over = try env.evalValue(f.over, null);
                const outer = env.vars.items.len;
                defer env.vars.shrinkRetainingCapacity(outer);
                var ret: ?Value = null;
                switch (over) {
                    .model => |m| {
                        var i: usize = 0;
                        while (i < m.rowCount()) : (i += 1) {
                            env.vars.shrinkRetainingCapacity(outer);
                            const row = m.rowData(i) orelse continue;
                            try env.vars.append(env.scratch, .{ .name = f.item.name, .value = row, .ty = .void });
                            if (f.index) |index| try env.vars.append(env.scratch, .{ .name = index.name, .value = .{ .int = @intCast(i) }, .ty = .int });
                            if (try env.turn(f.body, &ret)) break;
                        }
                    },
                    .int => |n| {
                        var i: i32 = 0;
                        while (i < n) : (i += 1) {
                            env.vars.shrinkRetainingCapacity(outer);
                            try env.vars.append(env.scratch, .{ .name = f.item.name, .value = .{ .int = i }, .ty = .int });
                            if (try env.turn(f.body, &ret)) break;
                        }
                    },
                    else => return env.fail("'for' goes over a model or a count", .{}),
                }
                return ret;
            },
            .@"break" => return error.Break,
            .@"continue" => return error.Continue,
        }
        return null;
    }
};
