// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Semantic analysis and Zig code generation for `.zge` documents.
//!
//! Every component becomes a Zig struct holding its properties, callbacks
//! and elements, with `create`/`destroy` (heap) and `init`/`deinit` (in
//! place) functions. Bindings become small functions installed with
//! `setBinding`; constant bindings become plain `set` calls.
//!
//! The body of a `for` or `if` becomes a *template*: a struct of its own,
//! instantiated at run time by a `Repeater` or `Conditional`. A template
//! reaches the component around it through its `_parent` pointer, so every
//! name can be resolved at compile time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Span = ast.Span;
const lexer = @import("lexer.zig");
const Tag = lexer.Tag;
const types = @import("types.zig");
const Type = types.Type;
const Builtin = types.Builtin;
const Diagnostics = @import("diagnostics.zig").Diagnostics;
const Loader = @import("compiler.zig").Loader;
const std_widgets = @import("std_widgets.zig");
const index_mod = @import("index.zig");
const Index = index_mod.Index;
// Through the zigulee module, so programs using both the compiler and the
// runtime (the interpreter) have one copy of it.
const png = @import("zigulee").core.png;
const zigulee_core = @import("zigulee").core;

pub const Error = error{CompileError} || Allocator.Error;

const Writer = std.Io.Writer;

// ---- Model ----

pub const Geometry = struct {
    x: bool = false,
    y: bool = false,
    width: bool = false,
    height: bool = false,

    pub fn any(g: Geometry) bool {
        return g.x or g.y or g.width or g.height;
    }

    fn mark(g: *Geometry, name: []const u8) void {
        if (std.mem.eql(u8, name, "x")) g.x = true;
        if (std.mem.eql(u8, name, "y")) g.y = true;
        if (std.mem.eql(u8, name, "width")) g.width = true;
        if (std.mem.eql(u8, name, "height")) g.height = true;
    }

    pub fn merge(a: Geometry, b: Geometry) Geometry {
        return .{ .x = a.x or b.x, .y = a.y or b.y, .width = a.width or b.width, .height = a.height or b.height };
    }
};

pub const PropDecl = struct {
    name: []const u8,
    zig: []const u8,
    ty: Type,
    visibility: ast.Visibility,
    decl: *const ast.PropertyDecl,
    /// For globals: whether the property never changes (see
    /// `Generator.globalConstant`), and its value as Zig code.
    constness: enum { unknown, variable, constant } = .unknown,
    constant_code: []const u8 = "",
};

pub const CallbackDecl = struct {
    name: []const u8,
    zig: []const u8,
    params: []const Type,
    ret: Type,
    span: Span,
};

pub const FunctionDecl = struct {
    name: []const u8,
    /// The generated method.
    method: []const u8,
    params: []const Type,
    ret: Type,
    public: bool,
    decl: *const ast.FunctionDecl,
};

/// Where a member is declared, for the index.
const Sym = union(enum) {
    none,
    /// `x`, `width`, `min-width`...: every element has them.
    common: []const u8,
    builtin: struct { b: *const Builtin, name: []const u8 },
    comp: struct { c: *Comp, name: []const u8 },
    /// A state or event of a `StateMachine`.
    machine: struct { el: *const Elem, kind: index_mod.Kind, name: []const u8 },
};

/// What kind of struct a `Comp` generates.
pub const Template = union(enum) {
    /// A component declared in the document.
    none,
    /// The body of a `for`.
    repeated: struct {
        node: *const ast.Repeated,
        /// Set when the enclosing component is generated.
        data_ty: Type = .int,
    },
    /// The body of an `if`.
    conditional: *const ast.Conditional,
};

pub const Comp = struct {
    ast: *const ast.Component,
    name: []const u8,
    /// Name of the generated struct: `name`, made unique if components of
    /// several files share it.
    zig: []const u8,
    /// The source file (diagnostics) and its directory (relative paths).
    file: u16 = 0,
    dir: []const u8 = "",
    is_global: bool = false,
    /// Failed: reported, and with no elements (`root` not set).
    state: enum { pending, analyzing, done, failed } = .pending,
    root: *Elem = undefined,
    /// Pre-order: the root first.
    elements: std.ArrayList(*Elem) = .empty,
    props: std.ArrayList(PropDecl) = .empty,
    callbacks: std.ArrayList(CallbackDecl) = .empty,
    functions: std.ArrayList(FunctionDecl) = .empty,
    ids: std.StringHashMapUnmanaged(*Elem) = .empty,
    is_window: bool = false,
    template: Template = .none,
    /// For templates: the component around it, and the repeater or
    /// conditional element there that instantiates it.
    outer: ?*Comp = null,
    host: ?*Elem = null,
    /// The element marked `@children`: children of the component's uses
    /// are added to it.
    children_target: ?*Elem = null,

    pub fn prop(c: *const Comp, name: []const u8) ?*const PropDecl {
        for (c.props.items) |*p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }

    pub fn callback(c: *const Comp, name: []const u8) ?*const CallbackDecl {
        for (c.callbacks.items) |*cb| if (std.mem.eql(u8, cb.name, name)) return cb;
        return null;
    }

    pub fn function(c: *const Comp, name: []const u8) ?*const FunctionDecl {
        for (c.functions.items) |*f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }

    /// Whether it is shown in a window: it inherits `Window`, or a
    /// component that is (`export component Big inherits App { ... }`).
    pub fn showsWindow(c: *const Comp) bool {
        var it = c;
        while (!it.is_window) switch (it.root.kind) {
            .component => |base| it = base,
            else => return false,
        };
        return true;
    }

    /// Inherits a component shown in a window (not `Window` itself): its
    /// window, title and size are that component's.
    pub fn inheritsWindow(c: *const Comp) bool {
        return !c.is_window and c.showsWindow();
    }

    /// Whether it inherits `Settings` (or a component that does): its
    /// declared properties are kept.
    pub fn keepsSettings(c: *const Comp) bool {
        if (c.template != .none) return false;
        var it = c;
        while (true) switch (it.root.kind) {
            .component => |base| it = base,
            .builtin => |b| return std.mem.eql(u8, b.name, "Settings"),
            else => return false,
        };
    }

    fn declares(c: *const Comp, name: []const u8) bool {
        return c.prop(name) != null or c.callback(name) != null or c.function(name) != null;
    }

    /// Geometry its own root element sets, which users must not override
    /// with defaults.
    pub fn rootGeometry(c: *const Comp) Geometry {
        var g = c.root.sets;
        if (c.root.kind == .component) g = g.merge(c.root.kind.component.rootGeometry());
        return g;
    }

    /// The outermost (declared) component.
    pub fn outermost(c: *Comp) *Comp {
        var it = c;
        while (it.outer) |o| it = o;
        return it;
    }
};

const Anim = struct { prop: []const u8, code: []const u8 };

pub const Elem = struct {
    ast: *const ast.Element,
    comp: *Comp,
    kind: union(enum) {
        builtin: *const Builtin,
        component: *Comp,
        /// A `for`: instantiates the template.
        repeater: *Comp,
        /// An `if`: instantiates the template.
        conditional: *Comp,
    },
    field: []const u8,
    parent: ?*Elem = null,
    children: std.ArrayList(*Elem) = .empty,
    /// Needs a `_c_<field>` LayoutConstraints.
    constraints: bool = false,
    /// Needs an `_a_<field>` AccessibleProperties.
    accessible: bool = false,
    /// Needs a `_t_<field>` ItemTransform.
    transform: bool = false,
    /// Needs a `_d_<field>` DropShadow (a Rectangle).
    shadow: bool = false,
    sets: Geometry = .{},
    animations: std.ArrayList(Anim) = .empty,
    /// In a GridLayout: the index of the `Row` it is in, if any.
    grid_row: ?u16 = null,
    /// Position in `comp.elements`.
    index: u32 = 0,
    /// A `StateMachine`'s states, events and transitions.
    machine: ?*Machine = null,

    pub fn animation(e: *const Elem, prop: []const u8) ?[]const u8 {
        for (e.animations.items) |a| if (std.mem.eql(u8, a.prop, prop)) return a.code;
        return null;
    }

    pub fn isDynamic(e: *const Elem) bool {
        return e.kind == .repeater or e.kind == .conditional;
    }

    /// The element around this one, crossing from a template's root to
    /// the element that holds its `for` or `if`.
    pub fn visualParent(e: *const Elem) ?*Elem {
        if (e.parent) |p| return p;
        const host = e.comp.host orelse return null;
        return host.parent;
    }

    /// Positioned by a layout (directly, or through a `for`/`if`, or as a
    /// child of a component whose `@children` is in a layout).
    pub fn inLayout(e: *const Elem) bool {
        const p = (e.visualParent() orelse return false).contentHost();
        return p.kind == .builtin and p.kind.builtin.layout;
    }

    /// The element children of this one are added to: itself, or for a
    /// component with `@children`, the element marked so.
    pub fn contentHost(e: *const Elem) *const Elem {
        if (e.kind == .component) if (e.kind.component.children_target) |t| return t.contentHost();
        return e;
    }
};

/// A `StateMachine`'s states, events and transitions, numbered as its
/// `zigulee.core.statemachine.Definition` numbers them.
pub const Machine = struct {
    events: std.ArrayList(Event) = .empty,
    /// Every state, parents before their children (document order).
    states: std.ArrayList(State) = .empty,
    /// The top-level state entered first.
    initial: u16 = 0,
    /// All states' transitions, in order: their numbers.
    transitions: std.ArrayList(Transition) = .empty,
    afters: u16 = 0,
    /// The enum of its atomic states (`state`).
    state_enum: *const types.Enum = undefined,
    regions: std.ArrayList(Region) = .empty,

    pub fn region(m: *const Machine, prop: []const u8) ?*const Region {
        for (m.regions.items) |*r| if (std.mem.eql(u8, r.prop, prop)) return r;
        return null;
    }

    pub fn isAtomic(st: State) bool {
        return st.initial == null and st.ast.kind != .parallel;
    }

    pub const Event = struct { name: []const u8, params: []const Type, decl: *const ast.EventDecl };
    pub const State = struct {
        ast: *const ast.MachineState,
        parent: ?u16 = null,
        /// A state with states inside: the one entered with it.
        initial: ?u16 = null,
        /// `ready.editing`: how it is named when its name alone is not
        /// enough.
        path: []const u8,
        /// Atomic states: their number among them (the enum's).
        leaf: ?u16 = null,
    };
    pub const Transition = struct {
        state: u16,
        ast: *const ast.MachineState.Transition,
        event: ?u16 = null,
        after: ?u16 = null,
        /// `on done.x`: x's number.
        done: ?u16 = null,
        eventless: bool = false,
        target: ?u16 = null,
        to_history: bool = false,
    };
    /// A state inside a parallel state: `<name>-state` reads its atomic
    /// state, a value of its own enum.
    pub const Region = struct {
        state: u16,
        prop: []const u8,
        state_enum: *const types.Enum,
        /// For each atomic state of the machine, its value in the region's
        /// enum (0 for those outside it).
        table: []const u16,
    };

    pub fn eventIndex(m: *const Machine, name: []const u8) ?u16 {
        for (m.events.items, 0..) |e, i| if (std.mem.eql(u8, e.name, name)) return @intCast(i);
        return null;
    }

    /// The state with this path (`ready.editing`).
    pub fn pathIndex(m: *const Machine, path: []const u8) ?u16 {
        for (m.states.items, 0..) |st, i| if (std.mem.eql(u8, st.path, path)) return @intCast(i);
        return null;
    }

    pub const Found = struct { state: u16, history: bool = false };
    pub const NotFound = union(enum) {
        /// No such state (the path's first `depth` parts were found).
        missing: usize,
        /// The name is several states'.
        ambiguous,
        /// `x.history` of a state keeping none.
        no_history,
    };

    /// The state `parts` names, seen from state `from` (null: from the
    /// top): a name, then names of states inside it, then maybe `history`.
    /// The name is looked for among the states around `from` first (inside
    /// its parent: one directly inside, else the one inside at any depth),
    /// then a level further out, and so on to the whole machine.
    pub fn find(m: *const Machine, parts: []const []const u8, from: ?u16) union(enum) { found: Found, not_found: NotFound } {
        var at: u16 = blk: {
            var scope: ?u16 = if (from) |f| m.states.items[f].parent else null;
            while (true) {
                var direct: ?u16 = null;
                var directs: usize = 0;
                var any: ?u16 = null;
                var count: usize = 0;
                for (m.states.items, 0..) |st, i| {
                    if (!std.mem.eql(u8, st.ast.name.name, parts[0])) continue;
                    if (!m.within(@intCast(i), scope)) continue;
                    count += 1;
                    any = @intCast(i);
                    if (st.parent == scope) {
                        directs += 1;
                        direct = @intCast(i);
                    }
                }
                if (directs == 1) break :blk direct.?;
                if (count == 1) break :blk any.?;
                if (count > 1) return .{ .not_found = .ambiguous };
                const sc = scope orelse return .{ .not_found = .{ .missing = 0 } };
                scope = m.states.items[sc].parent;
            }
        };
        for (parts[1..], 1..) |part, depth| {
            if (std.mem.eql(u8, part, "history") and depth == parts.len - 1) {
                if (m.states.items[at].ast.history == null) return .{ .not_found = .no_history };
                return .{ .found = .{ .state = at, .history = true } };
            }
            at = for (m.states.items, 0..) |st, i| {
                if (st.parent == at and std.mem.eql(u8, st.ast.name.name, part)) break @intCast(i);
            } else return .{ .not_found = .{ .missing = depth } };
        }
        return .{ .found = .{ .state = at } };
    }

    /// Whether `s` is inside `around` (anything is inside the top, null).
    pub fn within(m: *const Machine, s: u16, around: ?u16) bool {
        const a = around orelse return true;
        var it = m.states.items[s].parent;
        while (it) |p| : (it = m.states.items[p].parent) if (p == a) return true;
        return false;
    }

    /// The names of a state written as an expression: `a` or `a.b.c`.
    pub fn exprParts(arena: Allocator, e: *const ast.Expr) Allocator.Error!?[]const []const u8 {
        switch (e.kind) {
            .ident => |name| {
                const out = try arena.alloc([]const u8, 1);
                out[0] = name;
                return out;
            },
            .member => |mb| {
                const head = try exprParts(arena, mb.object) orelse return null;
                const out = try arena.alloc([]const u8, head.len + 1);
                @memcpy(out[0..head.len], head);
                out[head.len] = mb.name.name;
                return out;
            },
            else => return null,
        }
    }

    /// The `Arg` field an event argument of type `t` travels in.
    pub fn argField(t: Type) ?[]const u8 {
        return switch (t) {
            .bool => "boolean",
            .int, .enumeration => "int",
            .float, .length => "float",
            .string => "string",
            else => null,
        };
    }

    /// Members every machine has: events cannot take their names.
    pub const own_members = [_][]const u8{ "running", "current", "state", "active", "start", "stop" };
};

/// Where an element lives, relative to `self` of the struct being
/// generated: `prefix` is the path of the struct holding it.
const Loc = struct {
    prefix: []const u8,
    field: []const u8,
};

const PropRef = struct {
    /// Path(s) to the `Property` field relative to `self.` (several,
    /// comma-separated, for `padding`).
    path: []const u8,
    ty: Type,
    /// A `LayoutConstraints` field: `Property(?f32)`.
    constraint: bool = false,
    /// The field is a `Property(?T)`.
    optional: bool = false,
    /// Code reading the value, if not the property itself (constraints
    /// read as the element's computed layout size).
    read: ?[]const u8 = null,
    /// `read` is a constant (a global's property that never changes).
    constant: bool = false,
    /// For constraints: the element whose `LayoutConstraints` this writes
    /// (created only for elements whose constraints are written).
    owner: ?*Elem = null,
    sym: Sym = .none,
    read_only: bool = false,
    /// Why it is read-only, for the error message.
    read_only_reason: []const u8 = "",
    anim: ?[]const u8 = null,
};

const CallbackRef = struct {
    path: []const u8,
    params: []const Type,
    ret: Type,
    sym: Sym = .none,
};

/// A function to call: `{prefix}{method}(args)`.
const FunctionRef = struct {
    prefix: []const u8,
    method: []const u8,
    params: []const Type = &.{},
    ret: Type = .void,
    sym: Sym = .none,
};

const Member = union(enum) {
    property: PropRef,
    callback: CallbackRef,
    function: FunctionRef,

    fn sym(m: Member) Sym {
        return switch (m) {
            inline else => |v| v.sym,
        };
    }
};

// ---- Generator ----

/// A parsed `.zge` file: the main one or an import.
pub const DocEntry = struct {
    doc: *const ast.Document,
    file: u16,
    /// Directory of the file, relative to the main file's.
    dir: []const u8,
    /// Path relative to the main file's directory (for de-duplication).
    path: []const u8,
    /// The `docs` index of each import's file (null if it failed to load).
    targets: []?usize = &.{},
    /// Names visible in the file: its own definitions and its imports.
    scope: std.StringHashMapUnmanaged(Symbol) = .empty,
};

/// What a component, struct or enum name refers to.
pub const Symbol = union(enum) {
    comp: *Comp,
    structure: *types.StructDef,
    enumeration: *types.Enum,
};

pub const Generator = struct {
    arena: Allocator,
    diags: *Diagnostics,
    doc: *const ast.Document,
    docs: std.ArrayList(DocEntry) = .empty,
    comps: std.StringArrayHashMapUnmanaged(*Comp) = .empty,
    /// `for` and `if` bodies, outer ones first.
    templates: std.ArrayList(*Comp) = .empty,
    loader: Loader = .none,
    /// Keyed by Zig name (unique across files).
    structs: std.StringArrayHashMapUnmanaged(*types.StructDef) = .empty,
    enums: std.StringArrayHashMapUnmanaged(*types.Enum) = .empty,
    /// Zig names of generated declarations, to keep them unique.
    zig_names: std.StringHashMapUnmanaged(void) = .empty,
    /// Built-in `std-widgets.zge` style.
    style: []const u8 = "fluent",
    /// Filled while analyzing, if set (editor tooling).
    index: ?*Index = null,
    /// The type of each `let` (the interpreter converts assigned values to
    /// it).
    let_types: std.AutoHashMapUnmanaged(*const ast.Stmt, Type) = .empty,
    /// Numbers Zig names of locals.
    next_local: u32 = 0,

    pub fn init(arena: Allocator, diags: *Diagnostics, doc: *const ast.Document) Generator {
        return .{ .arena = arena, .diags = diags, .doc = doc };
    }

    /// Parses the files `entry` imports, recursively.
    fn loadImports(g: *Generator, entry_index: usize) Error!void {
        const imports = g.docs.items[entry_index].doc.imports;
        const targets = try g.arena.alloc(?usize, imports.len);
        @memset(targets, null);
        g.docs.items[entry_index].targets = targets;
        for (imports, targets) |imp, *target| {
            const entry = g.docs.items[entry_index];
            g.diags.current = entry.file;
            const path = if (std.mem.eql(u8, imp.path, std_widgets.import_name) and !std_widgets.isStd(entry.path))
                std_widgets.root
            else
                try joinPath(g.arena, entry.dir, imp.path);
            target.* = for (g.docs.items, 0..) |d, i| {
                if (std.mem.eql(u8, d.path, path)) break i;
            } else blk: {
                const source = g.readFile(path) catch |err| {
                    try g.diags.add(imp.path_span, "cannot read '{s}': {t}", .{ imp.path, err });
                    continue;
                };
                const file = try g.diags.addFile(path, source);
                g.diags.current = file;
                var parser: @import("parser.zig").Parser = .init(g.arena, source, g.diags);
                const doc = try g.arena.create(ast.Document);
                doc.* = parser.parseDocument() catch |err| switch (err) {
                    error.ParseError => continue,
                    else => |e| return e,
                };
                try g.docs.append(g.arena, .{ .doc = doc, .file = file, .dir = std.fs.path.dirnamePosix(path) orelse "", .path = path });
                const index = g.docs.items.len - 1;
                try g.loadImports(index);
                break :blk index;
            };
        }
    }

    /// Reads a file the document refers to: the standard widgets are built
    /// in, others come from the loader.
    pub fn readFile(g: *Generator, path: []const u8) ![]const u8 {
        if (std_widgets.isStd(path)) return std_widgets.read(g.style, path) orelse error.FileNotFound;
        return g.loader.read(g.arena, path);
    }

    /// Adds each file's imported names to its scope, checking that they
    /// exist and are exported.
    fn resolveImports(g: *Generator) Error!void {
        for (g.docs.items) |*entry| {
            g.diags.current = entry.file;
            for (entry.doc.imports, entry.targets) |imp, target| {
                const t = target orelse continue;
                for (imp.names) |name| {
                    const sym = g.exported(t, name.name, 0) catch |err| switch (err) {
                        error.NotDefined => {
                            try g.diags.add(name.span, "'{s}' is not defined in '{s}'", .{ name.name, imp.path });
                            continue;
                        },
                        error.NotExported => {
                            try g.diags.add(name.span, "'{s}' is not exported from '{s}'", .{ name.name, imp.path });
                            continue;
                        },
                    };
                    const gop = try entry.scope.getOrPut(g.arena, name.name);
                    if (gop.found_existing and !std.meta.eql(gop.value_ptr.*, sym)) {
                        try g.diags.add(name.span, "'{s}' is already defined", .{name.name});
                        continue;
                    }
                    gop.value_ptr.* = sym;
                }
            }
        }
    }

    /// What file `doc_index` exports as `name`: its own definitions and
    /// what it re-exports with `export { ... } from`.
    fn exported(g: *Generator, doc_index: usize, name: []const u8, depth: u8) error{ NotDefined, NotExported }!Symbol {
        const entry = &g.docs.items[doc_index];
        for (entry.doc.components) |c| if (std.mem.eql(u8, c.name.name, name)) {
            if (!c.exported and !c.is_global) return error.NotExported;
            return entry.scope.get(name) orelse error.NotDefined;
        };
        for (entry.doc.structs) |st| if (std.mem.eql(u8, st.name.name, name)) return entry.scope.get(name) orelse error.NotDefined;
        for (entry.doc.enums) |e| if (std.mem.eql(u8, e.name.name, name)) return entry.scope.get(name) orelse error.NotDefined;
        if (depth < 16) for (entry.doc.imports, entry.targets) |imp, target| {
            if (!imp.reexport) continue;
            for (imp.names) |n| if (std.mem.eql(u8, n.name, name))
                return g.exported(target orelse return error.NotDefined, name, depth + 1);
        };
        return error.NotDefined;
    }

    /// The scope of the file diagnostics currently refer to.
    fn currentScope(g: *Generator) *std.StringHashMapUnmanaged(Symbol) {
        for (g.docs.items) |*d| if (d.file == g.diags.current) return &d.scope;
        return &g.docs.items[0].scope;
    }

    /// A unique Zig declaration name for `name`. The main file's names
    /// are kept; clashing names from other files get a suffix.
    fn uniqueZig(g: *Generator, name: []const u8, file: u16) Allocator.Error![]const u8 {
        var candidate = name;
        var n: usize = 1;
        while (g.zig_names.contains(candidate) or (file != 0 and g.mainDefines(candidate))) : (n += 1)
            candidate = try g.print("{s}__{d}", .{ name, n });
        try g.zig_names.put(g.arena, candidate, {});
        return candidate;
    }

    fn mainDefines(g: *Generator, name: []const u8) bool {
        for (g.doc.components) |c| if (std.mem.eql(u8, c.name.name, name)) return true;
        for (g.doc.structs) |st| if (std.mem.eql(u8, st.name.name, name)) return true;
        for (g.doc.enums) |e| if (std.mem.eql(u8, e.name.name, name)) return true;
        return false;
    }

    /// Marks the root elements of components whose accessibility is set
    /// where they are used (`Button { accessible-label: ...; }`), so their
    /// `AccessibleProperties` exist when the component's code is generated.
    /// Elements of a component type that set accessibility, transform or
    /// shadow properties: the built-in element at the root of that
    /// component (its struct is generated first) gets their storage.
    fn markAccessibleUses(g: *Generator) void {
        for (g.comps.values()) |c| {
            g.diags.current = c.file;
            g.markAccessibleIn(&c.ast.root);
        }
    }

    fn markAccessibleIn(g: *Generator, e: *const ast.Element) void {
        const uses = setsStored(e);
        if (uses.accessible or uses.transform or uses.shadow) if (g.compFromName(e.type_name.name)) |sub| markStoredRoot(sub, uses);
        for (e.members) |m| switch (m) {
            .child => |child| g.markAccessibleIn(child),
            .repeated => |r| g.markAccessibleIn(r.element),
            .conditional => |cond| g.markAccessibleIn(cond.element),
            else => {},
        };
    }

    const Stored = struct { accessible: bool = false, transform: bool = false, shadow: bool = false };

    fn setsStored(e: *const ast.Element) Stored {
        var uses: Stored = .{};
        for (e.members) |m| {
            const name = switch (m) {
                .binding => |b| b.name.name,
                .two_way => |t| t.name.name,
                .handler => |h| h.name.name,
                else => continue,
            };
            if (std.mem.startsWith(u8, name, "accessible-")) uses.accessible = true;
            for (types.transform_props) |p| if (std.mem.eql(u8, p.name, name)) {
                uses.transform = true;
            };
            if (std.mem.startsWith(u8, name, "drop-shadow-")) uses.shadow = true;
        }
        return uses;
    }

    fn markStoredRoot(c: *Comp, uses: Stored) void {
        var comp = c;
        while (true) switch (comp.root.kind) {
            .builtin => |b| {
                if (uses.accessible) comp.root.accessible = true;
                if (uses.transform) comp.root.transform = true;
                if (uses.shadow and std.mem.eql(u8, b.name, "Rectangle")) comp.root.shadow = true;
                return;
            },
            .component => |sub| comp = sub,
            else => return,
        };
    }

    pub fn compFromName(g: *Generator, name: []const u8) ?*Comp {
        const sym = g.currentScope().get(name) orelse return null;
        return if (sym == .comp) sym.comp else null;
    }

    // ---- Index (editor tooling) ----

    fn here(g: *Generator, span: Span) index_mod.Location {
        return .{ .file = g.diags.current, .span = span };
    }

    fn noteComp(g: *Generator, span: Span, c: *Comp) Allocator.Error!void {
        const ix = g.index orelse return;
        const detail = if (c.is_global)
            try g.print("global {s}", .{c.name})
        else
            try g.print("{s}component {s} inherits {s}", .{ if (c.ast.exported) "export " else "", c.name, c.ast.root.type_name.name });
        const sym = try ix.symbol(try g.print("comp:{s}", .{c.zig}), .{
            .kind = if (c.is_global) .global else .component,
            .name = c.name,
            .decl = .{ .file = c.file, .span = c.ast.name.span },
            .detail = detail,
        });
        try ix.reference(g.here(span), sym);
    }

    fn noteBuiltin(g: *Generator, span: Span, b: *const Builtin) Allocator.Error!void {
        const ix = g.index orelse return;
        const sym = try ix.symbol(try g.print("elem:{s}", .{b.name}), .{
            .kind = .builtin_element,
            .name = b.name,
            .decl = null,
            .detail = try g.print("built-in element {s}", .{b.name}),
        });
        try ix.reference(g.here(span), sym);
    }

    fn noteId(g: *Generator, span: Span, c: *Comp, el: *Elem) Allocator.Error!void {
        const ix = g.index orelse return;
        const id = el.ast.id orelse return;
        const type_name = elementTypeName(el);
        const sym = try ix.symbol(try g.print("id:{s}:{s}", .{ c.zig, el.field }), .{
            .kind = .id,
            .name = id.name,
            .decl = .{ .file = c.outermost().file, .span = id.span },
            .detail = try g.print("{s} := {s}", .{ id.name, type_name }),
            .element_type = type_name,
        });
        try ix.reference(g.here(span), sym);
    }

    fn visibilityWord(v: ast.Visibility) []const u8 {
        return switch (v) {
            .private => "",
            .in => "in ",
            .out => "out ",
            .in_out => "in-out ",
        };
    }

    /// `(a: int, b: string) -> int`
    fn functionSignature(g: *Generator, f: *const FunctionDecl) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.append(g.arena, '(');
        for (f.decl.params, f.params, 0..) |param, t, i| try out.appendSlice(g.arena, try g.print("{s}{s}: {s}", .{ if (i > 0) ", " else "", param.name.name, t.name() }));
        try out.append(g.arena, ')');
        if (f.ret != .void) try out.appendSlice(g.arena, try g.print(" -> {s}", .{f.ret.name()}));
        return out.items;
    }

    fn callbackDetail(g: *Generator, name: []const u8, params: []const Type, ret: Type) Allocator.Error![]const u8 {
        return g.signatureDetail("callback", name, params, ret);
    }

    fn signatureDetail(g: *Generator, keyword: []const u8, name: []const u8, params: []const Type, ret: Type) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(g.arena, try g.print("{s} {s}(", .{ keyword, name }));
        for (params, 0..) |t, i| try out.appendSlice(g.arena, try g.print("{s}{s}", .{ if (i > 0) ", " else "", t.name() }));
        try out.append(g.arena, ')');
        if (ret != .void) try out.appendSlice(g.arena, try g.print(" -> {s}", .{ret.name()}));
        return out.items;
    }

    fn noteSym(g: *Generator, span: Span, sym: Sym) Allocator.Error!void {
        const ix = g.index orelse return;
        const id: u32 = switch (sym) {
            .none => return,
            .common => |name| blk: {
                for (types.accessible_callbacks) |cb| if (std.mem.eql(u8, cb.name, name)) {
                    break :blk try ix.symbol(try g.print("common:{s}", .{name}), .{
                        .kind = .callback,
                        .name = name,
                        .decl = null,
                        .detail = try g.print("{s} (every element)", .{try g.callbackDetail(cb.name, cb.params, cb.ret)}),
                    });
                };
                const ty = for (types.geometry_props ++ types.constraint_props ++ types.transform_props ++ types.shadow_props ++ types.accessible_props) |p| {
                    if (std.mem.eql(u8, p.name, name)) break p.ty;
                } else Type.length;
                break :blk try ix.symbol(try g.print("common:{s}", .{name}), .{
                    .kind = .property,
                    .name = name,
                    .decl = null,
                    .detail = try g.print("var <{s}> {s} ({s})", .{ ty.name(), name, if (std.mem.startsWith(u8, name, "drop-shadow-")) "Rectangle" else "every element" }),
                });
            },
            .builtin => |b| blk: {
                const detail = if (b.b.prop(b.name)) |p|
                    try g.print("var {s}<{s}> {s} ({s})", .{ if (p.read_only) "out " else "", p.ty.name(), p.name, b.b.name })
                else if (b.b.callback(b.name)) |cb|
                    try g.print("{s} ({s})", .{ try g.callbackDetail(cb.name, cb.params, cb.ret), b.b.name })
                else
                    try g.print("function {s}() ({s})", .{ b.name, b.b.name });
                const kind: index_mod.Kind = if (b.b.prop(b.name) != null) .property else if (b.b.callback(b.name) != null) .callback else .function;
                break :blk try ix.symbol(try g.print("builtin:{s}:{s}", .{ b.b.name, b.name }), .{ .kind = kind, .name = b.name, .decl = null, .detail = detail });
            },
            .comp => |cm| blk: {
                const c = cm.c;
                const key = try g.print("member:{s}:{s}", .{ c.zig, cm.name });
                if (c.prop(cm.name)) |p| break :blk try ix.symbol(key, .{
                    .kind = .property,
                    .name = p.name,
                    .decl = .{ .file = c.file, .span = p.decl.name.span },
                    .detail = try g.print("var {s}<{s}> {s} ({s})", .{ visibilityWord(p.visibility), p.ty.name(), p.name, c.name }),
                });
                if (c.function(cm.name)) |f| break :blk try ix.symbol(key, .{
                    .kind = .function,
                    .name = f.name,
                    .decl = .{ .file = c.file, .span = f.decl.name.span },
                    .detail = try g.print("{s}function {s}{s} ({s})", .{ if (f.public) "public " else "", f.name, try g.functionSignature(f), c.name }),
                });
                if (c.callback(cm.name)) |cb| break :blk try ix.symbol(key, .{
                    .kind = .callback,
                    .name = cb.name,
                    .decl = .{ .file = c.file, .span = cb.span },
                    .detail = try g.print("{s} ({s})", .{ try g.callbackDetail(cb.name, cb.params, cb.ret), c.name }),
                });
                return;
            },
            .machine => |ms| blk: {
                const el = ms.el;
                const m = el.machine orelse return;
                const owner = if (el.ast.id) |i| i.name else "StateMachine";
                const key = try g.print("machine:{s}:{s}:{t}:{s}", .{ el.comp.zig, el.field, ms.kind, ms.name });
                if (ms.kind == .state) {
                    const st = m.states.items[m.pathIndex(ms.name) orelse return];
                    break :blk try ix.symbol(key, .{ .kind = .state, .name = st.ast.name.name, .decl = .{ .file = el.comp.file, .span = st.ast.name.span }, .detail = try g.print("state {s} ({s})", .{ ms.name, owner }) });
                }
                const ev = m.events.items[m.eventIndex(ms.name) orelse return];
                var params: std.ArrayList(u8) = .empty;
                for (ev.params, 0..) |t, k| try g.appendFmt(&params, "{s}{s}", .{ if (k > 0) ", " else "", t.name() });
                break :blk try ix.symbol(key, .{ .kind = .event, .name = ms.name, .decl = .{ .file = el.comp.file, .span = ev.decl.name.span }, .detail = try g.print("event {s}({s}) ({s})", .{ ms.name, params.items, owner }) });
            },
        };
        try ix.reference(g.here(span), id);
    }

    /// Names in scope, members and ids, for completion.
    fn fillCompletions(g: *Generator, ix: *Index) Allocator.Error!void {
        const M = index_mod.Member;
        for (&types.builtins) |*b| {
            var list: std.ArrayList(M) = .empty;
            for (types.geometry_props ++ types.constraint_props ++ types.transform_props ++ types.accessible_props) |p| if (b.prop(p.name) == null)
                try list.append(g.arena, .{ .name = p.name, .kind = .property, .detail = try g.print("var <{s}> {s}", .{ p.ty.name(), p.name }) });
            if (std.mem.eql(u8, b.name, "Rectangle")) for (types.shadow_props) |p|
                try list.append(g.arena, .{ .name = p.name, .kind = .property, .detail = try g.print("var <{s}> {s}", .{ p.ty.name(), p.name }) });
            for (types.accessible_callbacks) |cb| try list.append(g.arena, .{ .name = cb.name, .kind = .callback, .detail = try g.callbackDetail(cb.name, cb.params, cb.ret) });
            for (b.props) |p| try list.append(g.arena, .{ .name = p.name, .kind = .property, .detail = try g.print("var {s}<{s}> {s}", .{ if (p.read_only) "out " else "", p.ty.name(), p.name }) });
            for (b.callbacks) |cb| try list.append(g.arena, .{ .name = cb.name, .kind = .callback, .detail = try g.callbackDetail(cb.name, cb.params, cb.ret) });
            for (b.functions) |f| try list.append(g.arena, .{ .name = f.name, .kind = .function, .detail = try g.signatureDetail("function", f.name, f.params, f.ret) });
            try ix.members.put(g.arena, try g.print("builtin:{s}", .{b.name}), list.items);
        }
        for (g.comps.values()) |c| {
            if (c.state != .done or c.template != .none) continue;
            const key = try g.print("comp:{s}", .{c.zig});
            _ = try g.compMembers(ix, c, 0);
            var ids: std.ArrayList(M) = .empty;
            var it = c.ids.iterator();
            while (it.next()) |e| {
                const el = e.value_ptr.*;
                const id = el.ast.id orelse continue;
                try ids.append(g.arena, .{ .name = id.name, .kind = .id, .detail = try g.print("{s} := {s}", .{ id.name, elementTypeName(el) }), .target = try typeKey(g, el) });
            }
            try ix.ids.put(g.arena, key, ids.items);
        }
        for (g.enums.values()) |e| {
            var list: std.ArrayList(M) = .empty;
            for (e.values) |v| try list.append(g.arena, .{ .name = v[0], .kind = .enumeration, .detail = try g.print("{s}.{s}", .{ e.name, v[0] }) });
            try ix.members.put(g.arena, try g.print("enum:{s}", .{e.zig}), list.items);
        }
        for (g.docs.items) |*d| {
            var list: std.ArrayList(M) = .empty;
            var it = d.scope.iterator();
            while (it.next()) |e| switch (e.value_ptr.*) {
                .comp => |c| try list.append(g.arena, .{
                    .name = e.key_ptr.*,
                    .kind = if (c.is_global) .global else .component,
                    .detail = if (c.is_global) try g.print("global {s}", .{c.name}) else try g.print("component {s} inherits {s}", .{ c.name, c.ast.root.type_name.name }),
                    .target = try g.print("comp:{s}", .{c.zig}),
                }),
                .structure => |st| try list.append(g.arena, .{ .name = e.key_ptr.*, .kind = .structure, .detail = try g.print("struct {s}", .{st.name}) }),
                .enumeration => |en| try list.append(g.arena, .{ .name = e.key_ptr.*, .kind = .enumeration, .detail = try g.print("enum {s}", .{en.name}), .target = try g.print("enum:{s}", .{en.zig}) }),
            };
            try ix.scopes.put(g.arena, d.file, list.items);
        }
        var names: std.ArrayList([]const u8) = .empty;
        for (g.diags.files.items) |f| try names.append(g.arena, f.name);
        ix.files = names.items;
    }

    /// A component's members for completion, with those it inherits.
    fn compMembers(g: *Generator, ix: *Index, c: *Comp, depth: u8) Allocator.Error![]const index_mod.Member {
        const key = try g.print("comp:{s}", .{c.zig});
        if (ix.members.get(key)) |m| return m;
        var list: std.ArrayList(index_mod.Member) = .empty;
        for (c.props.items) |p| try list.append(g.arena, .{ .name = p.name, .kind = .property, .detail = try g.print("var {s}<{s}> {s}", .{ visibilityWord(p.visibility), p.ty.name(), p.name }) });
        for (c.callbacks.items) |cb| try list.append(g.arena, .{ .name = cb.name, .kind = .callback, .detail = try g.callbackDetail(cb.name, cb.params, cb.ret) });
        for (c.functions.items) |*f| try list.append(g.arena, .{ .name = f.name, .kind = .function, .detail = try g.print("function {s}{s}", .{ f.name, try g.functionSignature(f) }) });
        // The root is the first element (none if analysis failed early).
        if (!c.is_global and c.elements.items.len > 0 and depth < 32) switch (c.elements.items[0].kind) {
            .builtin => |b| if (ix.members.get(try g.print("builtin:{s}", .{b.name}))) |m| try list.appendSlice(g.arena, m),
            .component => |base| try list.appendSlice(g.arena, try g.compMembers(ix, base, depth + 1)),
            else => {},
        };
        try ix.members.put(g.arena, key, list.items);
        return list.items;
    }

    fn typeKey(g: *Generator, el: *const Elem) Allocator.Error![]const u8 {
        return switch (el.kind) {
            .builtin => |b| g.print("builtin:{s}", .{b.name}),
            .component => |c| g.print("comp:{s}", .{c.zig}),
            .repeater, .conditional => "",
        };
    }

    fn fail(g: *Generator, span: Span, comptime fmt: []const u8, args: anytype) Error {
        try g.diags.add(span, fmt, args);
        return error.CompileError;
    }

    fn print(g: *Generator, comptime fmt: []const u8, args: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(g.arena, fmt, args);
    }

    /// The component named `name` in the scope of `file`.
    pub fn compIn(g: *Generator, file: u16, name: []const u8) ?*Comp {
        const saved = g.diags.current;
        defer g.diags.current = saved;
        g.diags.current = file;
        return g.compFromName(name);
    }

    /// The type named `name` in the scope of `file`.
    pub fn typeIn(g: *Generator, file: u16, name: []const u8) ?Type {
        const saved = g.diags.current;
        defer g.diags.current = saved;
        g.diags.current = file;
        return g.typeFromName(name);
    }

    /// Generates Zig source for the document, or returns CompileError with
    /// diagnostics recorded.
    pub fn generate(g: *Generator, file_name: []const u8) Error![]const u8 {
        try g.docs.append(g.arena, .{ .doc = g.doc, .file = 0, .dir = "", .path = "" });
        try g.loadImports(0);
        for (g.docs.items) |*entry| {
            g.diags.current = entry.file;
            try g.declareDocTypes(entry);
            for (entry.doc.components) |*c| {
                if (types.findBuiltin(c.name.name) != null) {
                    try g.diags.add(c.name.span, "'{s}' is the name of a built-in element", .{c.name.name});
                    continue;
                }
                const gop = try entry.scope.getOrPut(g.arena, c.name.name);
                if (gop.found_existing) {
                    try g.diags.add(c.name.span, "component '{s}' is defined twice", .{c.name.name});
                    continue;
                }
                const comp = try g.arena.create(Comp);
                const zig = try g.uniqueZig(c.name.name, entry.file);
                comp.* = .{ .ast = c, .name = c.name.name, .zig = zig, .file = entry.file, .dir = entry.dir, .is_global = c.is_global };
                gop.value_ptr.* = .{ .comp = comp };
                try g.comps.put(g.arena, zig, comp);
            }
        }
        try g.resolveImports();
        for (g.docs.items) |entry| {
            g.diags.current = entry.file;
            try g.resolveStructFields(entry.doc);
        }
        for (g.comps.values()) |c| g.analyze(c) catch {};
        if (g.index) |ix| try g.fillCompletions(ix);
        if (g.diags.hasErrors()) return error.CompileError;
        g.markAccessibleUses();

        var out: Writer.Allocating = .init(g.arena);
        const w = &out.writer;
        w.print(
            \\//! Generated by zgec from {s}. Do not edit.
            \\
            \\const std = @import("std");
            \\const zigulee = @import("zigulee");
            \\
        , .{file_name}) catch return error.OutOfMemory;
        try g.emitTypes(w);
        // Components before templates: a template's loop variable type is
        // found while generating the struct around it.
        for (g.comps.values()) |c| try g.emitOrSkip(w, c);
        var i: usize = 0;
        while (i < g.templates.items.len) : (i += 1) try g.emitOrSkip(w, g.templates.items[i]);
        if (g.diags.hasErrors()) return error.CompileError;
        return out.written();
    }

    fn emitOrSkip(g: *Generator, w: *Writer, c: *Comp) Allocator.Error!void {
        g.diags.current = c.outermost().file;
        g.emitComponent(w, c) catch |err| switch (err) {
            error.CompileError => {},
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    // ---- Declared types ----

    fn typeNameTaken(entry: *const DocEntry, name: []const u8) bool {
        return entry.scope.contains(name) or types.Type.fromName(name) != null or types.findBuiltin(name) != null;
    }

    fn declareDocTypes(g: *Generator, entry: *DocEntry) Error!void {
        const doc = entry.doc;
        for (doc.enums) |e| {
            if (typeNameTaken(entry, e.name.name)) {
                try g.diags.add(e.name.span, "'{s}' is already defined", .{e.name.name});
                continue;
            }
            var values: std.ArrayList([2][]const u8) = .empty;
            for (e.values) |v| try values.append(g.arena, .{ v.name, try zigName(g.arena, v.name) });
            if (values.items.len == 0) {
                try g.diags.add(e.name.span, "an enum needs at least one value", .{});
                continue;
            }
            const def = try g.arena.create(types.Enum);
            const zig = try g.uniqueZig(e.name.name, entry.file);
            def.* = .{ .name = e.name.name, .zig = try g.print("{f}", .{std.zig.fmtId(zig)}), .values = values.items };
            try g.enums.put(g.arena, zig, def);
            try entry.scope.put(g.arena, e.name.name, .{ .enumeration = def });
        }
        // Struct names first: fields may refer to other structs.
        for (doc.structs) |s| {
            if (typeNameTaken(entry, s.name.name)) {
                try g.diags.add(s.name.span, "'{s}' is already defined", .{s.name.name});
                continue;
            }
            const unique = try g.uniqueZig(s.name.name, entry.file);
            const zig = try g.print("{f}", .{std.zig.fmtId(unique)});
            const def = try g.arena.create(types.StructDef);
            def.* = .{
                .name = s.name.name,
                .zig = zig,
                .fields = &.{},
                .self_type = undefined,
                .model_zig = try g.print("zigulee.Model({s})", .{zig}),
                .model_name = try g.print("[{s}]", .{s.name.name}),
                .default_value = try g.print("{s}{{}}", .{zig}),
                .empty_model = try g.print("zigulee.core.emptyModel({s})", .{zig}),
            };
            def.self_type = .{ .structure = def };
            try g.structs.put(g.arena, unique, def);
            try entry.scope.put(g.arena, s.name.name, .{ .structure = def });
        }
    }

    fn resolveStructFields(g: *Generator, doc: *const ast.Document) Error!void {
        for (doc.structs) |s| {
            const sym = g.currentScope().get(s.name.name) orelse continue;
            if (sym != .structure) continue;
            const def = sym.structure;
            var fields: std.ArrayList(types.StructDef.Field) = .empty;
            for (s.fields) |f| {
                const ty = g.declType(f.type_name) catch continue;
                if (ty == .structure and ty.structure == def) {
                    try g.diags.add(f.type_name.span, "a struct cannot contain itself", .{});
                    continue;
                }
                try fields.append(g.arena, .{ .name = f.name.name, .zig = try zigName(g.arena, f.name.name), .ty = ty });
            }
            def.fields = fields.items;
        }
    }

    pub fn typeFromName(g: *Generator, name: []const u8) ?Type {
        if (g.currentScope().get(name)) |sym| switch (sym) {
            .structure => |st| return .{ .structure = st },
            .enumeration => |e| return .{ .enumeration = e },
            .comp => {},
        };
        return types.Type.fromName(name);
    }

    fn emitTypes(g: *Generator, w: *Writer) Allocator.Error!void {
        const W = struct {
            fn p(o: *Writer, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
                o.print(fmt, args) catch return error.OutOfMemory;
            }
        };
        for (g.enums.values()) |e| {
            try W.p(w, "\npub const {s} = enum {{", .{e.zig});
            for (e.values, 0..) |v, i| try W.p(w, "{s} {f}", .{ if (i > 0) "," else "", std.zig.fmtId(v[1]) });
            try W.p(w, " }};\n", .{});
        }
        for (g.structs.values()) |s| {
            try W.p(w, "\npub const {s} = struct {{\n    /// Copied whole by calls keeping it (`zigulee.core.Kept`).\n    pub const zge_struct = {{}};\n\n", .{s.zig});
            for (s.fields) |f| try W.p(w, "    {f}: {s} = {s},\n", .{ std.zig.fmtId(f.zig), f.ty.zig(), defaultValue(f.ty) });
            try W.p(w, "\n    pub fn eql(a: {s}, b: {s}) bool {{\n        return true", .{ s.zig, s.zig });
            for (s.fields) |f| {
                const id = try g.print("{f}", .{std.zig.fmtId(f.zig)});
                const cmp = switch (f.ty) {
                    .string => try g.print("std.mem.eql(u8, a.{s}, b.{s})", .{ id, id }),
                    .brush, .structure => try g.print("a.{s}.eql(b.{s})", .{ id, id }),
                    .color, .model, .image => try g.print("std.meta.eql(a.{s}, b.{s})", .{ id, id }),
                    .audio, .video, .model3d => try g.print("a.{s}.eql(b.{s})", .{ id, id }),
                    else => try g.print("a.{s} == b.{s}", .{ id, id }),
                };
                try W.p(w, " and\n            {s}", .{cmp});
            }
            try W.p(w, ";\n    }}\n}};\n", .{});
        }
    }

    // ---- Analysis: element trees, declarations ----

    fn analyze(g: *Generator, c: *Comp) Error!void {
        switch (c.state) {
            .done => return,
            // Reported already; what uses it fails too.
            .failed => return error.CompileError,
            .analyzing => return g.fail(c.ast.name.span, "component '{s}' contains itself", .{c.name}),
            .pending => {},
        }
        c.state = .analyzing;
        // Done, or (run after, on an error) failed.
        errdefer c.state = .failed;
        defer c.state = .done;
        const saved_file = g.diags.current;
        g.diags.current = c.file;
        defer g.diags.current = saved_file;
        try g.noteComp(c.ast.name.span, c);

        for (c.ast.root.members) |*m| switch (m.*) {
            .property => |*p| {
                const ty = try g.declType(p.type_name);
                if (c.declares(p.name.name)) {
                    try g.diags.add(p.name.span, "'{s}' is declared twice", .{p.name.name});
                    continue;
                }
                try c.props.append(g.arena, .{ .name = p.name.name, .zig = try zigName(g.arena, p.name.name), .ty = ty, .visibility = p.visibility, .decl = p });
                try g.noteSym(p.name.span, .{ .comp = .{ .c = c, .name = p.name.name } });
            },
            .callback => |*cb| {
                var params: std.ArrayList(Type) = .empty;
                for (cb.params) |t| try params.append(g.arena, g.typeFromName(t.name) orelse {
                    try g.diags.add(t.span, "unknown type '{s}'", .{t.name});
                    continue;
                });
                const ret = if (cb.ret) |r| g.typeFromName(r.name) orelse {
                    try g.diags.add(r.span, "unknown type '{s}'", .{r.name});
                    continue;
                } else Type.void;
                if (c.declares(cb.name.name)) {
                    try g.diags.add(cb.name.span, "'{s}' is declared twice", .{cb.name.name});
                    continue;
                }
                try c.callbacks.append(g.arena, .{ .name = cb.name.name, .zig = try zigName(g.arena, cb.name.name), .params = params.items, .ret = ret, .span = cb.name.span });
                try g.noteSym(cb.name.span, .{ .comp = .{ .c = c, .name = cb.name.name } });
            },
            .function => |*f| {
                var params: std.ArrayList(Type) = .empty;
                var ok = true;
                for (f.params) |param| {
                    const t = g.declType(param.type_name) catch {
                        ok = false;
                        continue;
                    };
                    try params.append(g.arena, t);
                }
                const ret: Type = if (f.ret) |r| g.declType(r) catch blk: {
                    ok = false;
                    break :blk .void;
                } else .void;
                if (!ok) continue;
                if (c.declares(f.name.name)) {
                    try g.diags.add(f.name.span, "'{s}' is declared twice", .{f.name.name});
                    continue;
                }
                try c.functions.append(g.arena, .{
                    .name = f.name.name,
                    // `invoke_` keeps methods apart from fields and the generated
                    // declarations (`init`, `create`, ...).
                    .method = try g.print("invoke_{s}", .{try zigName(g.arena, f.name.name)}),
                    .params = params.items,
                    .ret = ret,
                    .public = f.public,
                    .decl = f,
                });
                try g.noteSym(f.name.span, .{ .comp = .{ .c = c, .name = f.name.name } });
            },
            else => {},
        };

        c.root = try g.buildElement(c, &c.ast.root, null);
        c.is_window = c.root.kind == .builtin and c.root.kind.builtin.window;
        if (c.is_global) for (c.root.children.items) |ch| {
            if (ch.machine != null) continue;
            try g.diags.add(c.ast.name.span, "a global cannot contain elements (but state machines)", .{});
            break;
        };
        if (c.keepsSettings()) for (c.props.items) |p| if (!p.ty.keptBySettings())
            try g.diags.add(p.decl.name.span, "Settings cannot keep a {s} property", .{p.ty.name()});
        for (c.props.items) |p| g.checkFieldName(c, p.zig, p.decl.name.span) catch {};
        for (c.callbacks.items) |cb| g.checkFieldName(c, cb.zig, c.ast.name.span) catch {};
        for (c.functions.items) |f| {
            const zig = try zigName(g.arena, f.name);
            if (c.ids.get(zig) != null) try g.diags.add(f.decl.name.span, "'{s}' is both a function and an element id", .{f.name});
            // Its method must not collide with a field.
            if (c.ids.get(f.method) != null) try g.diags.add(f.decl.name.span, "the Zig method '{s}' of function '{s}' collides with an element id", .{ f.method, f.name });
            for (c.props.items) |p| if (std.mem.eql(u8, p.zig, f.method)) try g.diags.add(f.decl.name.span, "the Zig method '{s}' of function '{s}' collides with a property", .{ f.method, f.name });
            for (c.callbacks.items) |cb| if (std.mem.eql(u8, cb.zig, f.method)) try g.diags.add(f.decl.name.span, "the Zig method '{s}' of function '{s}' collides with a callback", .{ f.method, f.name });
        }
    }

    fn declType(g: *Generator, t: ast.TypeRef) Error!Type {
        const elem = g.typeFromName(t.name.name) orelse return g.fail(t.name.span, "unknown type '{s}'", .{t.name.name});
        if (!t.model) return elem;
        const rows = types.modelOf(elem) orelse return g.fail(t.span, "models of {s} are not supported", .{elem.name()});
        if (!t.nested) return rows;
        return types.modelOf(rows) orelse g.fail(t.span, "models of {s} are not supported", .{rows.name()});
    }

    fn checkFieldName(g: *Generator, c: *Comp, zig: []const u8, span: Span) Error!void {
        const reserved = [_][]const u8{ "root", "title", "Self", "Context", "create", "destroy", "init", "deinit", "update", "rootItem", "window" };
        for (reserved) |r| if (std.mem.eql(u8, zig, r)) return g.fail(span, "'{s}' is a reserved name", .{zig});
        if (c.ids.get(zig) != null) return g.fail(span, "'{s}' is both a property and an element id", .{zig});
    }

    fn buildElement(g: *Generator, c: *Comp, e: *const ast.Element, parent: ?*Elem) Error!*Elem {
        const elem = try g.arena.create(Elem);
        const field = if (parent == null)
            "root"
        else if (e.id) |id|
            try zigName(g.arena, id.name)
        else
            try g.print("_e{d}", .{c.elements.items.len});
        elem.* = .{ .ast = e, .comp = c, .kind = undefined, .field = field, .parent = parent };

        if (types.findBuiltin(e.type_name.name)) |b| {
            if (b.window and (parent != null or c.template != .none)) return g.fail(e.type_name.span, "a Window can only be the root of a component", .{});
            elem.kind = .{ .builtin = b };
            try g.noteBuiltin(e.type_name.span, b);
            if (std.mem.eql(u8, b.name, "StateMachine")) try g.analyzeMachine(c, elem);
        } else if (g.compFromName(e.type_name.name)) |sub| {
            if (sub.is_global) return g.fail(e.type_name.span, "'{s}' is a global, not an element", .{sub.name});
            try g.noteComp(e.type_name.span, sub);
            try g.analyze(sub);
            elem.kind = .{ .component = sub };
        } else {
            return g.fail(e.type_name.span, "unknown element type '{s}'", .{e.type_name.name});
        }
        elem.index = @intCast(c.elements.items.len);
        try c.elements.append(g.arena, elem);

        if (e.id) |id| try g.registerId(c, id, field, elem);

        var grid_rows: usize = 0;
        for (e.members) |*m| switch (m.*) {
            .binding => |b| elem.sets.mark(b.name.name),
            .child => |child| {
                try g.checkCanHaveChildren(elem, child.type_name.span);
                if (isGrid(elem) and std.mem.eql(u8, child.type_name.name, "Row")) {
                    // `Row { ... }`: its children are the grid's next row.
                    const row: u16 = @intCast(grid_rows);
                    grid_rows += 1;
                    for (child.members) |*rm| switch (rm.*) {
                        .child => |cell| {
                            const ch = g.buildElement(c, cell, elem) catch |err| switch (err) {
                                error.CompileError => continue,
                                else => return err,
                            };
                            ch.grid_row = row;
                            try elem.children.append(g.arena, ch);
                        },
                        .repeated => |*r| {
                            g.buildTemplate(c, elem, .{ .repeated = .{ .node = r } }, r.element, "for") catch |err| switch (err) {
                                error.CompileError => continue,
                                else => return err,
                            };
                            elem.children.items[elem.children.items.len - 1].grid_row = row;
                        },
                        .conditional => |*cond| {
                            g.buildTemplate(c, elem, .{ .conditional = cond }, cond.element, "if") catch |err| switch (err) {
                                error.CompileError => continue,
                                else => return err,
                            };
                            elem.children.items[elem.children.items.len - 1].grid_row = row;
                        },
                        else => try g.diags.add(child.span, "a Row can only contain elements", .{}),
                    };
                    continue;
                }
                const ch = g.buildElement(c, child, elem) catch |err| switch (err) {
                    error.CompileError => continue,
                    else => return err,
                };
                try elem.children.append(g.arena, ch);
            },
            .repeated => |*r| {
                try g.checkCanHaveChildren(elem, r.span);
                g.buildTemplate(c, elem, .{ .repeated = .{ .node = r } }, r.element, "for") catch |err| switch (err) {
                    error.CompileError => continue,
                    else => return err,
                };
            },
            .conditional => |*cond| {
                try g.checkCanHaveChildren(elem, cond.span);
                g.buildTemplate(c, elem, .{ .conditional = cond }, cond.element, "if") catch |err| switch (err) {
                    error.CompileError => continue,
                    else => return err,
                };
            },
            .children_placeholder => |span| {
                if (c.template != .none) {
                    try g.diags.add(span, "@children cannot be inside 'for' or 'if'", .{});
                } else if (c.children_target != null) {
                    try g.diags.add(span, "a component can have only one @children", .{});
                } else if (elem.kind == .builtin and !elem.kind.builtin.children) {
                    try g.diags.add(span, "'{s}' cannot have child elements", .{elem.kind.builtin.name});
                } else if (isGrid(elem)) {
                    try g.diags.add(span, "@children cannot be in a GridLayout yet", .{});
                } else c.children_target = elem;
            },
            .property => |p| if (parent != null or c.template != .none)
                try g.diags.add(p.span, "properties can only be declared at the top of a component", .{}),
            .callback => |cb| if (parent != null or c.template != .none)
                try g.diags.add(cb.span, "callbacks can only be declared at the top of a component", .{}),
            .function => |f| if (parent != null or c.template != .none)
                try g.diags.add(f.span, "functions can only be declared at the top of a component", .{}),
            else => {},
        };
        return elem;
    }

    /// A `StateMachine`'s events, states and transitions, checked and
    /// numbered; the enum of its atomic states declared.
    fn analyzeMachine(g: *Generator, c: *Comp, elem: *Elem) Error!void {
        const m = try g.arena.create(Machine);
        m.* = .{};
        elem.machine = m;
        errdefer elem.machine = null;
        var initial: ?ast.Ident = null;
        var top: std.ArrayList(*const ast.MachineState) = .empty;
        for (elem.ast.members) |*mem| switch (mem.*) {
            .event => |*e| {
                if (m.eventIndex(e.name.name) != null) {
                    try g.diags.add(e.name.span, "event '{s}' is declared twice", .{e.name.name});
                    continue;
                }
                const taken = for (Machine.own_members) |own| {
                    if (std.mem.eql(u8, own, e.name.name)) break true;
                } else false;
                if (taken) {
                    try g.diags.add(e.name.span, "'{s}' is a member of every StateMachine: an event cannot take its name", .{e.name.name});
                    continue;
                }
                var params: std.ArrayList(Type) = .empty;
                for (e.params) |t| {
                    const ty = g.typeFromName(t.name) orelse {
                        try g.diags.add(t.span, "unknown type '{s}'", .{t.name});
                        continue;
                    };
                    if (Machine.argField(ty) == null) {
                        try g.diags.add(t.span, "events cannot take a {s} yet (bool, int, float, length, string or an enum)", .{ty.name()});
                        continue;
                    }
                    try params.append(g.arena, ty);
                }
                if (e.params.len > 4) try g.diags.add(e.span, "an event takes 4 arguments at most", .{});
                try m.events.append(g.arena, .{ .name = e.name.name, .params = params.items, .decl = e });
                try g.noteSym(e.name.span, .{ .machine = .{ .el = elem, .kind = .event, .name = e.name.name } });
            },
            .machine_state => |*st| try top.append(g.arena, st),
            .initial => |i| {
                if (initial != null) try g.diags.add(i.span, "'initial' is given twice", .{});
                initial = i;
            },
            .property, .callback, .function => {},
            .binding, .two_way, .handler, .animate, .changed => {},
            else => try g.diags.add(elem.ast.type_name.span, "a StateMachine holds events and states, not elements", .{}),
        };
        if (top.items.len == 0) return g.fail(elem.ast.type_name.span, "a StateMachine needs at least one state", .{});

        // Every state, parents first; siblings' names told apart.
        try g.addMachineStates(elem, m, top.items, null);
        // Initial states: the one named, else the first.
        if (initial) |i| {
            m.initial = for (m.states.items, 0..) |st, k| {
                if (st.parent == null and std.mem.eql(u8, st.ast.name.name, i.name)) break @intCast(k);
            } else return g.fail(i.span, "no state '{s}' at the top of this machine", .{i.name});
            try g.noteSym(i.span, .{ .machine = .{ .el = elem, .kind = .state, .name = m.states.items[m.initial].path } });
        }
        for (m.states.items, 0..) |*st, k| {
            const children_first = for (m.states.items, 0..) |other, j| {
                if (other.parent != null and other.parent.? == k) break @as(?u16, @intCast(j));
            } else null;
            if (st.ast.kind == .parallel) {
                if (children_first == null) try g.diags.add(st.ast.name.span, "a parallel state needs states inside: its regions", .{});
                if (st.ast.initial) |i| try g.diags.add(i.span, "a parallel state's states are all entered: it has no 'initial'", .{});
                continue;
            }
            if (st.ast.initial) |i| {
                if (children_first == null) {
                    try g.diags.add(i.span, "'{s}' has no states inside for 'initial' to name", .{st.ast.name.name});
                    continue;
                }
                st.initial = for (m.states.items, 0..) |other, j| {
                    if (other.parent != null and other.parent.? == k and std.mem.eql(u8, other.ast.name.name, i.name)) break @intCast(j);
                } else {
                    try g.diags.add(i.span, "no state '{s}' inside '{s}'", .{ i.name, st.ast.name.name });
                    continue;
                };
                try g.noteSym(i.span, .{ .machine = .{ .el = elem, .kind = .state, .name = m.states.items[st.initial.?].path } });
            } else st.initial = children_first;
            if (st.ast.history) |h| if (st.initial == null)
                try g.diags.add(h.span, "only a state with states inside keeps a history", .{});
        }
        var leaves: u16 = 0;
        for (m.states.items) |*st| if (Machine.isAtomic(st.*)) {
            st.leaf = leaves;
            leaves += 1;
        };

        for (m.states.items, 0..) |st, si| for (st.ast.transitions) |*t| {
            var tr: Machine.Transition = .{ .state = @intCast(si), .ast = t };
            switch (t.trigger) {
                .event => |ev| {
                    const id = m.eventIndex(ev.name.name) orelse {
                        try g.diags.add(ev.name.span, "no event '{s}' in this machine", .{ev.name.name});
                        continue;
                    };
                    const want = m.events.items[id].params.len;
                    if (ev.params.len > want) {
                        try g.diags.add(ev.name.span, "'{s}' has {d} argument(s)", .{ ev.name.name, want });
                        continue;
                    }
                    tr.event = id;
                    try g.noteSym(ev.name.span, .{ .machine = .{ .el = elem, .kind = .event, .name = ev.name.name } });
                },
                .after => {
                    tr.after = m.afters;
                    m.afters += 1;
                },
                .done => |ref| {
                    const found = g.findState(elem, m, ref, @intCast(si)) catch continue;
                    if (found.history or Machine.isAtomic(m.states.items[found.state])) {
                        try g.diags.add(ref.span, "'{s}' has no states inside: it is never done", .{m.states.items[found.state].path});
                        continue;
                    }
                    tr.done = found.state;
                },
                .eventless => tr.eventless = true,
            }
            if (t.target) |target| {
                const found = g.findState(elem, m, target, @intCast(si)) catch continue;
                tr.target = found.state;
                tr.to_history = found.history;
            }
            try m.transitions.append(g.arena, tr);
        };

        // `<Id>State`, one value per atomic state: its name, or its path
        // (`ready-editing`) where atomic states share names.
        var name: std.ArrayList(u8) = .empty;
        var up = true;
        for (if (elem.ast.id) |id| id.name else "state-machine") |ch| {
            if (ch == '-' or ch == '_') {
                up = true;
                continue;
            }
            try name.append(g.arena, if (up) std.ascii.toUpper(ch) else ch);
            up = false;
        }
        try name.appendSlice(g.arena, "State");
        m.state_enum = try g.stateEnum(c, m, name.items, null);

        // Regions: `<name>-state` (its path, `a-b-state`, where regions
        // share names) and `<Id><Name>State`.
        for (m.states.items, 0..) |st, k| {
            const p = st.parent orelse continue;
            if (m.states.items[p].ast.kind != .parallel) continue;
            var shared = false;
            for (m.states.items) |other| {
                const op = other.parent orelse continue;
                if (other.ast != st.ast and m.states.items[op].ast.kind == .parallel and std.mem.eql(u8, other.ast.name.name, st.ast.name.name)) shared = true;
            }
            const label = if (shared) try std.mem.replaceOwned(u8, g.arena, st.path, ".", "-") else st.ast.name.name;
            const prop = try g.print("{s}-state", .{label});
            const clash = for (Machine.own_members) |own| {
                if (std.mem.eql(u8, own, prop)) break true;
            } else m.eventIndex(prop) != null;
            if (clash) {
                try g.diags.add(st.ast.name.span, "'{s}' would take the name of a member of this machine", .{prop});
                continue;
            }
            var enum_name: std.ArrayList(u8) = .empty;
            try enum_name.appendSlice(g.arena, name.items[0 .. name.items.len - "State".len]);
            up = true;
            for (label) |ch| {
                if (ch == '-' or ch == '_') {
                    up = true;
                    continue;
                }
                try enum_name.append(g.arena, if (up) std.ascii.toUpper(ch) else ch);
                up = false;
            }
            try enum_name.appendSlice(g.arena, "State");
            const def = try g.stateEnum(c, m, enum_name.items, @intCast(k));
            const table = try g.arena.alloc(u16, leaves);
            @memset(table, 0);
            var ordinal: u16 = 0;
            for (m.states.items, 0..) |other, j| if (other.leaf) |leaf| if (j != k and g.machineInside(m, @intCast(j), @intCast(k))) {
                table[leaf] = ordinal;
                ordinal += 1;
            };
            try m.regions.append(g.arena, .{ .state = @intCast(k), .prop = prop, .state_enum = def, .table = table });
        }
    }

    /// Whether state `s` is inside `around`.
    fn machineInside(g: *Generator, m: *const Machine, s: u16, around: u16) bool {
        _ = g;
        var it = m.states.items[s].parent;
        while (it) |p| : (it = m.states.items[p].parent) if (p == around) return true;
        return false;
    }

    /// An enum of the atomic states (inside `within`, or all): each named
    /// after its state, or its path with `-` where two share a name.
    fn stateEnum(g: *Generator, c: *Comp, m: *const Machine, name: []const u8, within: ?u16) Error!*const types.Enum {
        var values: std.ArrayList([2][]const u8) = .empty;
        for (m.states.items, 0..) |st, k| if (st.leaf != null) {
            if (within) |w| if (!g.machineInside(m, @intCast(k), w)) continue;
            var shared = false;
            for (m.states.items, 0..) |other, j| {
                if (other.leaf == null or other.ast == st.ast) continue;
                if (within) |w| if (!g.machineInside(m, @intCast(j), w)) continue;
                if (std.mem.eql(u8, other.ast.name.name, st.ast.name.name)) shared = true;
            }
            const value = if (shared) try std.mem.replaceOwned(u8, g.arena, st.path, ".", "-") else st.ast.name.name;
            try values.append(g.arena, .{ value, try zigName(g.arena, value) });
        };
        const def = try g.arena.create(types.Enum);
        const zig = try g.uniqueZig(name, c.file);
        def.* = .{ .name = name, .zig = try g.print("{f}", .{std.zig.fmtId(zig)}), .values = values.items };
        try g.enums.put(g.arena, zig, def);
        for (g.docs.items) |*d| if (d.file == c.file) {
            const gop = try d.scope.getOrPut(g.arena, name);
            if (!gop.found_existing) gop.value_ptr.* = .{ .enumeration = def };
        };
        return def;
    }

    /// Adds `list` (states of `parent`, or the top ones) and the states
    /// inside them, parents first.
    fn addMachineStates(g: *Generator, elem: *Elem, m: *Machine, list: []const *const ast.MachineState, parent: ?u16) Error!void {
        for (list, 0..) |st, i| {
            const twice = for (list[0..i]) |before| {
                if (std.mem.eql(u8, before.name.name, st.name.name)) break true;
            } else false;
            if (twice) {
                try g.diags.add(st.name.span, "state '{s}' is declared twice", .{st.name.name});
                continue;
            }
            if (std.mem.eql(u8, st.name.name, "history")) {
                try g.diags.add(st.name.span, "'history' cannot name a state: `x.history` enters x through its history", .{});
                continue;
            }
            const path = if (parent) |p| try g.print("{s}.{s}", .{ m.states.items[p].path, st.name.name }) else st.name.name;
            try m.states.append(g.arena, .{ .ast = st, .parent = parent, .path = path });
            const index: u16 = @intCast(m.states.items.len - 1);
            try g.noteSym(st.name.span, .{ .machine = .{ .el = elem, .kind = .state, .name = path } });
            var children: std.ArrayList(*const ast.MachineState) = .empty;
            for (st.children) |*child| try children.append(g.arena, child);
            try g.addMachineStates(elem, m, children.items, index);
        }
    }

    /// The state a target names, reported if none (or several).
    fn findState(g: *Generator, elem: *Elem, m: *const Machine, ref: ast.StateRef, from: ?u16) Error!Machine.Found {
        var parts: std.ArrayList([]const u8) = .empty;
        for (ref.parts) |p| try parts.append(g.arena, p.name);
        return g.findStateParts(elem, m, parts.items, ref.span, from);
    }

    fn findStateParts(g: *Generator, elem: *Elem, m: *const Machine, parts: []const []const u8, span: Span, from: ?u16) Error!Machine.Found {
        const written = try std.mem.join(g.arena, ".", parts);
        switch (m.find(parts, from)) {
            .found => |f| {
                try g.noteSym(span, .{ .machine = .{ .el = elem, .kind = .state, .name = m.states.items[f.state].path } });
                return f;
            },
            .not_found => |nf| switch (nf) {
                .missing => return g.fail(span, "no state '{s}' in this machine", .{written}),
                .ambiguous => {
                    var paths: std.ArrayList(u8) = .empty;
                    for (m.states.items) |st| if (std.mem.eql(u8, st.ast.name.name, parts[0]))
                        try g.appendFmt(&paths, "{s}{s}", .{ if (paths.items.len > 0) ", " else "", st.path });
                    return g.fail(span, "'{s}' names several states: write its path ({s})", .{ parts[0], paths.items });
                },
                .no_history => return g.fail(span, "'{s}' keeps no history: add `history;` to it", .{try std.mem.join(g.arena, ".", parts[0 .. parts.len - 1])}),
            },
        }
    }

    fn registerId(g: *Generator, c: *Comp, id: ast.Ident, field: []const u8, elem: *Elem) Error!void {
        if (std.mem.eql(u8, id.name, "root") or std.mem.eql(u8, id.name, "self") or std.mem.eql(u8, id.name, "parent"))
            return g.fail(id.span, "'{s}' cannot be used as an id", .{id.name});
        const gop = try c.ids.getOrPut(g.arena, field);
        if (gop.found_existing) return g.fail(id.span, "duplicate id '{s}'", .{id.name});
        gop.value_ptr.* = elem;
        try g.noteId(id.span, c, elem);
    }

    pub fn isGrid(el: *const Elem) bool {
        return el.kind == .builtin and std.mem.eql(u8, el.kind.builtin.name, "GridLayout");
    }

    const grid_cell_props = [_][]const u8{ "row", "col", "rowspan", "colspan" };

    /// The constant `row`, `col`, ... of a grid cell, if set.
    fn gridCellValue(g: *Generator, c: *Comp, el: *Elem, name: []const u8, fields: *Fields) Error!?u16 {
        for (el.ast.members) |m| if (m == .binding and std.mem.eql(u8, m.binding.name.name, name)) {
            var ctx = try g.context(c, el, fields);
            const v = try g.compileExpr(&ctx, m.binding.value, .int);
            if (!v.constant) return g.fail(m.binding.value.span, "'{s}' must be a constant", .{name});
            const n = std.fmt.parseInt(i32, v.code, 10) catch return g.fail(m.binding.value.span, "'{s}' must be a whole number", .{name});
            if (n < 0 or n > 1000) return g.fail(m.binding.value.span, "'{s}' must be between 0 and 1000", .{name});
            return @intCast(n);
        };
        return null;
    }

    /// `setup` call for a GridLayout: cells in rows (from `Row`) and
    /// columns, with explicit `row`/`col`/`rowspan`/`colspan` taking
    /// precedence.
    fn gridSetup(g: *Generator, c: *Comp, grid: *Elem, fields: *Fields) Error![]const u8 {
        // Rows come from `Row` (or `row`); columns not given explicitly are
        // resolved at run time, as `for` rows have a varying number of cells.
        var code: std.ArrayList(u8) = .empty;
        var last_row: u16 = 0;
        for (grid.children.items) |cell| {
            const explicit = !cell.isDynamic();
            const row = (if (explicit) try g.gridCellValue(c, cell, "row", fields) else null) orelse cell.grid_row orelse last_row;
            const col = if (explicit) try g.gridCellValue(c, cell, "col", fields) else null;
            const rowspan = (if (explicit) try g.gridCellValue(c, cell, "rowspan", fields) else null) orelse 1;
            const colspan = (if (explicit) try g.gridCellValue(c, cell, "colspan", fields) else null) orelse 1;
            last_row = row;
            const col_code = if (col) |v| try g.print("{d}", .{v}) else "null";
            try code.appendSlice(g.arena, try g.print(" .{{ .row = {d}, .col = {s}, .rowspan = {d}, .colspan = {d} }},", .{ row, col_code, rowspan, colspan }));
        }
        return g.print("try self.{s}.setup(gpa, &.{{{s} }});", .{ grid.field, code.items });
    }

    fn checkCanHaveChildren(g: *Generator, elem: *Elem, span: Span) Error!void {
        if (elem.kind == .builtin and !elem.kind.builtin.children)
            return g.fail(span, "'{s}' cannot have child elements", .{elem.kind.builtin.name});
    }

    /// Creates the host element (a Repeater or Conditional) and the
    /// template struct for a `for` or `if` body.
    fn buildTemplate(g: *Generator, c: *Comp, parent: *Elem, template: Template, body: *const ast.Element, kind: []const u8) Error!void {
        const n = g.templates.items.len;
        const t = try g.arena.create(Comp);
        t.* = .{
            .ast = c.ast,
            .name = try g.print("{s}_{s}{d}", .{ c.outermost().name, kind, n }),
            .zig = try g.print("{s}_{s}{d}", .{ c.outermost().zig, kind, n }),
            .state = .done,
            .template = template,
            .outer = c,
        };
        const host = try g.arena.create(Elem);
        host.* = .{
            .ast = body,
            .comp = c,
            .kind = if (template == .repeated) .{ .repeater = t } else .{ .conditional = t },
            .field = try g.print("_{s}{d}", .{ kind, n }),
            .parent = parent,
        };
        t.host = host;
        host.index = @intCast(c.elements.items.len);
        try c.elements.append(g.arena, host);
        try parent.children.append(g.arena, host);
        try g.templates.append(g.arena, t);
        t.root = try g.buildElement(t, body, null);
    }

    // ---- Locations ----

    /// How to reach `el` from the struct of `from`: `_parent.` per level.
    fn locFrom(g: *Generator, from: *const Comp, el: *const Elem) Allocator.Error!Loc {
        // A global's (state machine), through its accessor.
        if (el.comp.is_global and from != el.comp) return .{ .prefix = try g.print("_g_{s}().", .{try zigName(g.arena, el.comp.zig)}), .field = el.field };
        var prefix: std.ArrayList(u8) = .empty;
        var c: ?*const Comp = from;
        while (c) |it| : (c = it.outer) {
            if (it == el.comp) return .{ .prefix = prefix.items, .field = el.field };
            try prefix.appendSlice(g.arena, "_parent.");
        }
        unreachable; // elements are only reachable from inside their component
    }

    /// Accesses the element's `zigulee.Item` (as a place, for method calls).
    fn itemAccess(g: *Generator, from: *const Comp, el: *const Elem) Allocator.Error![]const u8 {
        const loc = try g.locFrom(from, el);
        return switch (el.kind) {
            .builtin => |b| g.print("self.{s}{s}.{s}", .{ loc.prefix, loc.field, b.item }),
            .component => g.print("self.{s}{s}.rootItem()", .{ loc.prefix, loc.field }),
            .repeater, .conditional => g.print("self.{s}{s}.item", .{ loc.prefix, loc.field }),
        };
    }

    /// Where the element's children go.
    fn containerAccess(g: *Generator, from: *const Comp, el: *const Elem) Allocator.Error![]const u8 {
        if (el.kind == .component and el.kind.component.children_target != null) {
            const loc = try g.locFrom(from, el);
            return g.print("self.{s}{s}.childrenContainer()", .{ loc.prefix, loc.field });
        }
        if (el.kind == .builtin) {
            const loc = try g.locFrom(from, el);
            const b = el.kind.builtin;
            return g.print("self.{s}{s}.{s}", .{ loc.prefix, loc.field, b.content orelse b.item });
        }
        return g.itemAccess(from, el);
    }

    /// Whether its item goes in the item tree: not for elements that are
    /// not drawn (Timer, Audio), nor components based on them.
    pub fn inTree(el: *const Elem) bool {
        return switch (el.kind) {
            .builtin => |b| b.in_tree,
            .component => |c| inTree(c.root),
            else => true,
        };
    }

    pub fn hasBinding(el: *const Elem, name: []const u8) bool {
        for (el.ast.members) |m| switch (m) {
            .binding => |b| if (std.mem.eql(u8, b.name.name, name)) return true,
            .two_way => |t| if (std.mem.eql(u8, t.name.name, name)) return true,
            else => {},
        };
        return false;
    }

    /// A `*zigulee.Item` for the element.
    fn itemPtr(g: *Generator, from: *const Comp, el: *const Elem) Allocator.Error![]const u8 {
        const loc = try g.locFrom(from, el);
        return switch (el.kind) {
            .builtin => |b| g.print("&self.{s}{s}.{s}", .{ loc.prefix, loc.field, b.item }),
            .component => g.print("self.{s}{s}.rootItem()", .{ loc.prefix, loc.field }),
            .repeater, .conditional => g.print("&self.{s}{s}.item", .{ loc.prefix, loc.field }),
        };
    }

    // ---- Member lookup ----

    /// Looks up `name` on an element. `c` is the component the element
    /// belongs to (`own` non-null) or a sub-component it is inside of
    /// (`own` null); `loc` says how to reach it.
    fn memberOf(g: *Generator, c: *Comp, elem: *const Elem, own: ?*Elem, loc: Loc, name: []const u8) Error!?Member {
        // Declared members of the component, on its root element.
        if (own != null and own.? == c.root) {
            const sym: Sym = .{ .comp = .{ .c = c, .name = name } };
            if (c.prop(name)) |p| return .{ .property = .{ .path = try g.print("{s}{s}", .{ loc.prefix, p.zig }), .ty = p.ty, .anim = c.root.animation(name), .sym = sym } };
            if (c.callback(name)) |cb| return .{ .callback = .{ .path = try g.print("{s}{s}", .{ loc.prefix, cb.zig }), .params = cb.params, .ret = cb.ret, .sym = sym } };
            if (c.function(name)) |f| return .{ .function = .{ .prefix = try g.print("self.{s}", .{loc.prefix}), .method = f.method, .params = f.params, .ret = f.ret, .sym = sym } };
        }
        const base = try g.print("{s}{s}", .{ loc.prefix, loc.field });
        const anim = if (own) |o| o.animation(name) else null;
        switch (elem.kind) {
            .builtin => |b| {
                // An element's own property of the same name (a sensor's
                // `x`) hides its position's.
                if (b.prop(name) == null) for (types.geometry_props) |p| if (std.mem.eql(u8, p.name, name))
                    return .{
                        .property = .{
                            .path = try g.print("{s}.{s}.{s}", .{ base, b.item, p.zig }),
                            .ty = p.ty,
                            .anim = anim,
                            .sym = .{ .common = p.name },
                            // Read as its parents leave it (disabled with them);
                            // set as its own.
                            .read = if (std.mem.eql(u8, p.name, "enabled")) try g.print("self.{s}.{s}.isEnabled()", .{ base, b.item }) else null,
                        },
                    };
                for (types.constraint_props) |p| if (std.mem.eql(u8, p.name, name)) {
                    const orientation = if (std.mem.endsWith(u8, p.zig, "width") or std.mem.startsWith(u8, p.zig, "horizontal")) "horizontal" else "vertical";
                    const field = if (std.mem.startsWith(u8, p.zig, "min")) "min" else if (std.mem.startsWith(u8, p.zig, "max")) "max" else if (std.mem.startsWith(u8, p.zig, "preferred")) "preferred" else "stretch";
                    return .{ .property = .{
                        .path = try g.print("{s}_c_{s}.{s}", .{ loc.prefix, loc.field, p.zig }),
                        .ty = p.ty,
                        .constraint = true,
                        .owner = own,
                        .optional = true,
                        .read = try g.print("self.{s}.{s}.layoutInfo(.{s}).{s}", .{ base, b.item, orientation, field }),
                        .sym = .{ .common = p.name },
                    } };
                };
                for (types.transform_props) |p| if (std.mem.eql(u8, p.name, name)) {
                    if (own) |o| o.transform = true;
                    var paths: std.ArrayList(u8) = .empty;
                    var it = std.mem.splitScalar(u8, p.zig, ',');
                    while (it.next()) |part| {
                        if (paths.items.len > 0) try paths.append(g.arena, ',');
                        try paths.appendSlice(g.arena, try g.print("{s}_t_{s}.{s}", .{ loc.prefix, loc.field, part }));
                    }
                    return .{ .property = .{ .path = paths.items, .ty = p.ty, .anim = anim, .optional = p.optional, .sym = .{ .common = p.name } } };
                };
                if (std.mem.eql(u8, b.name, "Rectangle")) for (types.shadow_props) |p| if (std.mem.eql(u8, p.name, name)) {
                    if (own) |o| o.shadow = true;
                    return .{ .property = .{ .path = try g.print("{s}_d_{s}.{s}", .{ loc.prefix, loc.field, p.zig }), .ty = p.ty, .anim = anim, .sym = .{ .common = p.name } } };
                };
                for (types.accessible_props) |p| if (std.mem.eql(u8, p.name, name)) {
                    if (own) |o| o.accessible = true;
                    return .{ .property = .{ .path = try g.print("{s}_a_{s}.{s}", .{ loc.prefix, loc.field, p.zig }), .ty = p.ty, .anim = anim, .sym = .{ .common = p.name } } };
                };
                for (types.accessible_callbacks) |cb| if (std.mem.eql(u8, cb.name, name)) {
                    if (own) |o| o.accessible = true;
                    return .{ .callback = .{ .path = try g.print("{s}_a_{s}.{s}", .{ loc.prefix, loc.field, cb.zig }), .params = cb.params, .ret = cb.ret, .sym = .{ .common = cb.name } } };
                };
                if (elem.machine) |m| {
                    if (m.eventIndex(name)) |i| return .{ .function = .{
                        .prefix = try g.print("self.{s}", .{loc.prefix}),
                        .method = try g.eventMethod(elem, name),
                        .params = m.events.items[i].params,
                        .sym = .{ .machine = .{ .el = elem, .kind = .event, .name = name } },
                    } };
                    if (std.mem.eql(u8, name, "state")) return .{ .property = .{
                        .path = try g.print("{s}.last", .{base}),
                        .ty = .{ .enumeration = m.state_enum },
                        .read = try g.print("@as({s}, @enumFromInt(self.{s}.last.get()))", .{ m.state_enum.zig, base }),
                        .read_only = true,
                        .read_only_reason = "the machine sets it",
                    } };
                    if (m.region(name)) |r| {
                        var table: std.ArrayList(u8) = .empty;
                        for (r.table, 0..) |v, k| try g.appendFmt(&table, "{s}{d}", .{ if (k > 0) ", " else "", v });
                        return .{ .property = .{
                            .path = try g.print("{s}.changes", .{base}),
                            .ty = .{ .enumeration = r.state_enum },
                            .read = try g.print("@as({s}, @enumFromInt(([_]u16{{ {s} }})[@intCast(self.{s}.lastIn({d}))]))", .{ r.state_enum.zig, table.items, base, r.state }),
                            .read_only = true,
                            .read_only_reason = "the machine sets it",
                        } };
                    }
                }
                if (b.prop(name)) |p| {
                    var path: []const u8 = undefined;
                    if (p.zig[0] == '@') {
                        path = try g.print("{s}{s}", .{ loc.prefix, p.zig[1..] });
                    } else {
                        var paths: std.ArrayList(u8) = .empty;
                        var it = std.mem.splitScalar(u8, p.zig, ',');
                        while (it.next()) |part| {
                            if (paths.items.len > 0) try paths.append(g.arena, ',');
                            try paths.appendSlice(g.arena, try g.print("{s}.{s}", .{ base, part }));
                        }
                        path = paths.items;
                    }
                    return .{ .property = .{ .path = path, .ty = p.ty, .read_only = p.read_only, .read_only_reason = "it is an output of the element", .anim = anim, .optional = p.optional, .sym = .{ .builtin = .{ .b = b, .name = p.name } } } };
                }
                if (b.callback(name)) |cb| return .{ .callback = .{ .path = try g.print("{s}.{s}", .{ base, cb.zig }), .params = cb.params, .ret = cb.ret, .sym = .{ .builtin = .{ .b = b, .name = cb.name } } } };
                if (b.function(name)) |f| return .{ .function = .{ .prefix = try g.print("self.{s}.", .{base}), .method = f.zig, .params = f.params, .ret = f.ret, .sym = .{ .builtin = .{ .b = b, .name = f.name } } } };
                return null;
            },
            .component => |sub| {
                if (sub.prop(name)) |p| {
                    if (p.visibility == .private) return null;
                    return .{ .property = .{
                        .path = try g.print("{s}.{s}", .{ base, p.zig }),
                        .ty = p.ty,
                        .read_only = p.visibility == .out,
                        .read_only_reason = "it is an output property",
                        .anim = anim,
                        .sym = .{ .comp = .{ .c = sub, .name = name } },
                    } };
                }
                if (sub.callback(name)) |cb| return .{ .callback = .{ .path = try g.print("{s}.{s}", .{ base, cb.zig }), .params = cb.params, .ret = cb.ret, .sym = .{ .comp = .{ .c = sub, .name = name } } } };
                if (sub.function(name)) |f| {
                    if (!f.public) return null;
                    return .{ .function = .{ .prefix = try g.print("self.{s}.", .{base}), .method = f.method, .params = f.params, .ret = f.ret, .sym = .{ .comp = .{ .c = sub, .name = name } } } };
                }
                const inner = try g.memberOf(sub, sub.root, null, .{ .prefix = try g.print("{s}.", .{base}), .field = "root" }, name) orelse return null;
                return switch (inner) {
                    .property => |pr| blk: {
                        var r = pr;
                        if (anim) |a| r.anim = a;
                        break :blk .{ .property = r };
                    },
                    else => inner,
                };
            },
            .repeater, .conditional => return null,
        }
    }

    /// `memberOf` for an element seen from the struct of `from`.
    /// `span` is where the name is written (null: not in the source).
    fn memberFrom(g: *Generator, from: *const Comp, el: *Elem, name: []const u8, span: ?Span) Error!?Member {
        const m = try g.memberOf(el.comp, el, el, try g.locFrom(from, el), name) orelse return null;
        if (span) |sp| try g.noteSym(sp, m.sym());
        return m;
    }

    // ---- Expressions ----

    const Local = struct {
        name: []const u8,
        zig: []const u8,
        ty: Type,
        /// A `let` (assignable).
        mutable: bool = false,
        /// A string `let`'s own buffer (`_s<n>`): assigned strings are
        /// copied into it, so it never borrows a buffer reused later.
        buffer: ?u32 = null,
    };

    const Ctx = struct {
        c: *Comp,
        /// Unqualified names resolve against this element (then the root).
        elem: *Elem,
        locals: []const Local = &.{},
        /// Code for 100% (in width/height bindings).
        percent_base: ?[]const u8 = null,
        /// Return type of the handler being compiled.
        ret: Type = .void,
        fields: *Fields,
        /// Loops around the statement being compiled.
        loops: u32 = 0,
    };

    /// Extra declarations created while compiling a struct.
    const Fields = struct {
        string_buffers: u32 = 0,
        functions: std.ArrayList(u8) = .empty,
        /// Container-level declarations (static models).
        statics: std.ArrayList(u8) = .empty,
        /// Instance fields needed by expressions, and their teardown.
        expr_fields: std.ArrayList(u8) = .empty,
        expr_deinit: std.ArrayList(u8) = .empty,
        /// Connections to other elements' callbacks: made at the end of
        /// `init` (after the handlers they add to), undone first in
        /// `deinit`.
        connects: std.ArrayList(u8) = .empty,
        disconnects: std.ArrayList(u8) = .empty,
        /// Properties driven by `states`, by path: their own bindings are
        /// folded into the state binding.
        state_props: std.StringArrayHashMapUnmanaged(StateProp) = .empty,
        next_fn: u32 = 0,
        next_static: u32 = 0,
    };

    const Value = struct {
        code: []const u8,
        ty: Type,
        constant: bool = false,
    };

    const StateProp = struct {
        ref: PropRef,
        /// The element the property belongs to, and the property name.
        elem: *Elem,
        name: []const u8,
        /// In state order.
        branches: std.ArrayList(Branch) = .empty,

        const Branch = struct {
            cond: []const u8,
            value: []const u8,
            /// Animations for entering and leaving this state, if any.
            enter: ?[]const u8 = null,
            leave: ?[]const u8 = null,
        };
    };

    const Ref = union(enum) {
        value: Value,
        element: *Elem,
        property: PropRef,
        callback: CallbackRef,
        function: FunctionRef,
        global: []const u8,
        /// An enum type name, for `Mode.dark`.
        enum_type: *const types.Enum,
        /// A global, for `Theme.dark`.
        global_comp: *Comp,
        /// `Key`, for `Key.UpArrow`.
        key_namespace,
    };

    /// A context for code in struct `c`: loop variables of every enclosing
    /// `for` are in scope.
    fn context(g: *Generator, c: *Comp, elem: *Elem, fields: *Fields) Allocator.Error!Ctx {
        var locals: std.ArrayList(Local) = .empty;
        var prefix: []const u8 = "";
        var it: ?*Comp = c;
        while (it) |t| : (it = t.outer) {
            if (t.template == .repeated) {
                const r = t.template.repeated;
                if (r.node.item) |item| try locals.append(g.arena, .{ .name = item.name, .zig = try g.print("self.{s}_data.get()", .{prefix}), .ty = r.data_ty });
                if (r.node.index) |index| try locals.append(g.arena, .{ .name = index.name, .zig = try g.print("self.{s}_index.get()", .{prefix}), .ty = .int });
            }
            prefix = try g.print("{s}_parent.", .{prefix});
        }
        return .{ .c = c, .elem = elem, .fields = fields, .locals = locals.items };
    }

    fn lookupName(g: *Generator, ctx: *Ctx, name: []const u8, span: Span) Error!Ref {
        // Innermost first: handler arguments, then loop variables.
        var i = ctx.locals.len;
        while (i > 0) {
            i -= 1;
            const l = ctx.locals[i];
            if (std.mem.eql(u8, l.name, name)) return .{ .value = .{ .code = l.zig, .ty = l.ty } };
        }
        if (std.mem.eql(u8, name, "true")) return .{ .value = .{ .code = "true", .ty = .bool, .constant = true } };
        if (std.mem.eql(u8, name, "false")) return .{ .value = .{ .code = "false", .ty = .bool, .constant = true } };
        if (std.mem.eql(u8, name, "self")) return .{ .element = ctx.elem };
        if (std.mem.eql(u8, name, "root")) return .{ .element = ctx.c.outermost().root };
        if (std.mem.eql(u8, name, "parent")) return .{ .element = ctx.elem.visualParent() orelse return g.fail(span, "the root element has no parent", .{}) };
        const zig = try zigName(g.arena, name);
        var scope: ?*Comp = ctx.c;
        while (scope) |s| : (scope = s.outer) {
            if (s.ids.get(zig)) |e| {
                try g.noteId(span, s, e);
                return .{ .element = e };
            }
        }
        for (types.global_functions) |f| if (std.mem.eql(u8, f, name)) return .{ .global = f };
        if (g.typeFromName(name)) |t| if (t == .enumeration) return .{ .enum_type = t.enumeration };
        if (g.compFromName(name)) |gc| if (gc.is_global and gc != ctx.c) {
            try g.noteComp(span, gc);
            return .{ .global_comp = gc };
        };
        // A component's name: the component as a value.
        if (g.compFromName(name)) |gc| if (!gc.is_global and gc.template == .none) {
            if (gc.showsWindow()) return g.fail(span, "'{s}' is a window: it cannot be shown in a Loader", .{name});
            try g.noteComp(span, gc);
            return .{ .value = .{ .code = try g.print("@as(zigulee.core.loader.Component, &{s}.factory)", .{gc.zig}), .ty = .component, .constant = true } };
        };
        if (try g.memberFrom(ctx.c, ctx.elem, name, span)) |m| return memberRef(m);
        // Then the declared members of each enclosing component.
        scope = ctx.c;
        while (scope) |s| : (scope = s.outer) {
            if (s.root == ctx.elem) continue;
            if (try g.memberFrom(ctx.c, s.root, name, span)) |m| return memberRef(m);
        }
        if (std.mem.eql(u8, name, "Key")) return .key_namespace;
        if (types.namedColor(name)) |rgba| return .{ .value = .{ .code = try g.print("zigulee.Color.rgba(0x{x:0>8})", .{rgba}), .ty = .color, .constant = true } };
        return g.fail(span, "unknown name '{s}'", .{name});
    }

    /// The value of a global's property that never changes, as Zig code:
    /// an output property initialized with a literal, which the global's
    /// own code never assigns and nothing links to (`<=>`). Code using it
    /// reads the value directly: no binding, no dependency (the `Style`
    /// sizes of the standard widgets, say).
    fn globalConstant(g: *Generator, gc: *Comp, p: *PropDecl) Error!?[]const u8 {
        switch (p.constness) {
            .constant => return p.constant_code,
            .variable => return null,
            .unknown => {},
        }
        p.constness = .variable;
        if (p.visibility != .out or p.decl.alias != null) return null;
        const value = p.decl.init orelse return null;
        if (assignsOrLinks(gc.ast.root.members, p.name)) return null;
        for (g.comps.values()) |c| if (linksTo(c.ast.root.members, gc.name, p.name)) return null;
        const code = try g.literalCode(value, p.ty) orelse return null;
        p.constness = .constant;
        p.constant_code = code;
        return code;
    }

    /// Zig code for a literal of type `t` (numbers, lengths, durations,
    /// colors, booleans and plain strings), or null.
    fn literalCode(g: *Generator, e: *const ast.Expr, t: Type) Error!?[]const u8 {
        switch (e.kind) {
            .number => |n| {
                const unit_ok = switch (t) {
                    .length => std.mem.eql(u8, n.unit, "px"),
                    .duration => std.mem.eql(u8, n.unit, "ms") or std.mem.eql(u8, n.unit, "s"),
                    .int => n.unit.len == 0 and n.is_int,
                    .float => n.unit.len == 0 or std.mem.eql(u8, n.unit, "deg"),
                    else => false,
                };
                if (!unit_ok) return null;
                return switch (t) {
                    .length, .float => try g.print("@as(f32, {d})", .{n.value}),
                    .int => try g.print("@as(i32, {d})", .{@as(i64, @intFromFloat(n.value))}),
                    .duration => try g.print("@as(i64, {d})", .{@as(i64, @intFromFloat(if (std.mem.eql(u8, n.unit, "s")) n.value * 1000 else n.value))}),
                    else => unreachable,
                };
            },
            .color => |c| return switch (t) {
                .color => try g.print("zigulee.Color.rgba(0x{x:0>8})", .{c}),
                .brush => try g.print("zigulee.Brush.color(zigulee.Color.rgba(0x{x:0>8}))", .{c}),
                else => null,
            },
            .ident => |name| {
                if (t == .bool and (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false"))) return name;
                return null;
            },
            .string => |parts| {
                if (t != .string or parts.len != 1 or parts[0] != .literal) return null;
                return try g.print("\"{f}\"", .{std.zig.fmtString(parts[0].literal)});
            },
            else => return null,
        }
    }

    fn memberRef(m: Member) Ref {
        return switch (m) {
            .property => |p| .{ .property = p },
            .callback => |cb| .{ .callback = cb },
            .function => |f| .{ .function = f },
        };
    }

    fn compileRef(g: *Generator, ctx: *Ctx, e: *const ast.Expr) Error!Ref {
        switch (e.kind) {
            .ident => |name| return g.lookupName(ctx, name, e.span),
            .member => |m| {
                const obj = try g.compileRef(ctx, m.object);
                switch (obj) {
                    .global_comp => |gc| {
                        const accessor = try g.print("_g_{s}()", .{try zigName(g.arena, gc.zig)});
                        try g.noteSym(m.name.span, .{ .comp = .{ .c = gc, .name = m.name.name } });
                        if (gc.prop(m.name.name)) |p| {
                            if (p.visibility == .private) return g.fail(m.name.span, "'{s}' is private to {s}", .{ m.name.name, gc.name });
                            const constant = try g.globalConstant(gc, @constCast(p)); // memoized in the (mutable) comp
                            return .{ .property = .{
                                .path = try g.print("{s}.{s}", .{ accessor, p.zig }),
                                .ty = p.ty,
                                .read_only = p.visibility == .out,
                                .read_only_reason = "it is an output property",
                                .anim = gc.root.animation(m.name.name),
                                .read = constant,
                                .constant = constant != null,
                            } };
                        }
                        if (gc.callback(m.name.name)) |cb|
                            return .{ .callback = .{ .path = try g.print("{s}.{s}", .{ accessor, cb.zig }), .params = cb.params, .ret = cb.ret } };
                        if (gc.function(m.name.name)) |f| {
                            if (!f.public) return g.fail(m.name.span, "'{s}' is private to {s}", .{ m.name.name, gc.name });
                            return .{ .function = .{ .prefix = try g.print("self.{s}.", .{accessor}), .method = f.method, .params = f.params, .ret = f.ret } };
                        }
                        if (gc.ids.get(try zigName(g.arena, m.name.name))) |el| if (el.machine != null) return .{ .element = el };
                        return g.fail(m.name.span, "{s} has no property or callback '{s}'", .{ gc.name, m.name.name });
                    },
                    .key_namespace => {
                        const key = types.keyName(m.name.name) orelse
                            return g.fail(m.name.span, "Key has no value '{s}'", .{m.name.name});
                        return .{ .value = .{ .code = try g.print("zigulee.core.input.Key.{f}", .{std.zig.fmtId(key)}), .ty = .string, .constant = true } };
                    },
                    .enum_type => |en| {
                        const tag = en.find(m.name.name) orelse
                            return g.fail(m.name.span, "{s} has no value '{s}'", .{ en.name, m.name.name });
                        return .{ .value = .{ .code = try g.print("{s}.{f}", .{ en.zig, std.zig.fmtId(tag) }), .ty = .{ .enumeration = en }, .constant = true } };
                    },
                    .element => |el| {
                        const member = try g.memberFrom(ctx.c, el, m.name.name, m.name.span) orelse
                            return g.fail(m.name.span, "'{s}' has no property or callback '{s}'", .{ elementTypeName(el), m.name.name });
                        return memberRef(member);
                    },
                    else => {
                        const v = try g.refToValue(obj, m.object.span);
                        if (v.ty == .model and std.mem.eql(u8, m.name.name, "length"))
                            return .{ .value = .{ .code = try g.print("@as(i32, @intCast(({s}).rowCount()))", .{v.code}), .ty = .int } };
                        // An image's size, in its pixels (0 for none).
                        if (v.ty == .image and (std.mem.eql(u8, m.name.name, "width") or std.mem.eql(u8, m.name.name, "height")))
                            return .{ .value = .{ .code = try g.print("@as(i32, @intCast(({s}).{s}))", .{ v.code, m.name.name }), .ty = .int } };
                        const f = v.ty.field(m.name.name) orelse
                            return g.fail(m.name.span, "{s} has no field '{s}'", .{ v.ty.name(), m.name.name });
                        return .{ .value = .{ .code = try g.print("{s}.{s}", .{ v.code, f[1] }), .ty = f[0] } };
                    },
                }
            },
            else => return .{ .value = try g.compileValue(ctx, e, null) },
        }
    }

    pub fn elementTypeName(el: *const Elem) []const u8 {
        return switch (el.kind) {
            .builtin => |b| b.name,
            .component => |c| c.name,
            .repeater => "for",
            .conditional => "if",
        };
    }

    fn refToValue(g: *Generator, r: Ref, span: Span) Error!Value {
        return switch (r) {
            .value => |v| v,
            .property => |p| .{
                .code = if (p.read) |read|
                    read
                else if (p.optional)
                    try g.print("(self.{s}.get() orelse {s})", .{ firstPath(p.path), defaultValue(p.ty) })
                else
                    try g.print("self.{s}.get()", .{firstPath(p.path)}),
                .ty = p.ty,
                .constant = p.constant,
            },
            .element => g.fail(span, "an element is not a value", .{}),
            .callback => g.fail(span, "a callback must be called: add '()'", .{}),
            .function, .global => g.fail(span, "a function must be called: add '()'", .{}),
            .enum_type => g.fail(span, "a type is not a value", .{}),
            .global_comp => g.fail(span, "a global is not a value", .{}),
            .key_namespace => g.fail(span, "'Key' is not a value: use a key, like Key.Return", .{}),
        };
    }

    fn firstPath(path: []const u8) []const u8 {
        return path[0 .. std.mem.indexOfScalar(u8, path, ',') orelse path.len];
    }

    /// Compiles an expression to a value of type `expected` (if given).
    fn compileExpr(g: *Generator, ctx: *Ctx, e: *const ast.Expr, expected: ?Type) Error!Value {
        const v = try g.compileValue(ctx, e, expected);
        if (expected) |t| return g.convert(v, t, e.span);
        return v;
    }

    fn compileValue(g: *Generator, ctx: *Ctx, e: *const ast.Expr, expected: ?Type) Error!Value {
        // Contextual names: enum values and easing curves.
        if (e.kind == .ident) {
            if (expected) |t| switch (t) {
                .enumeration => |en| if (en.find(e.kind.ident)) |tag|
                    return .{ .code = try g.print("{s}.{f}", .{ en.zig, std.zig.fmtId(tag) }), .ty = t, .constant = true },
                .easing => for (types.easing_names) |n| if (std.mem.eql(u8, n[0], e.kind.ident))
                    return .{ .code = try g.print("@as(zigulee.Easing, .{s})", .{n[1]}), .ty = .easing, .constant = true },
                else => {},
            };
        }
        switch (e.kind) {
            .number => |n| return g.number(ctx, n, e.span),
            .color => |c| return .{ .code = try g.print("zigulee.Color.rgba(0x{x:0>8})", .{c}), .ty = .color, .constant = true },
            .string => |parts| return g.string(ctx, parts),
            .ident, .member => return g.refToValue(try g.compileRef(ctx, e), e.span),
            .call => |c| return g.call(ctx, c.callee, c.args, e.span),
            .array => |items| return g.array(ctx, items, e.span, expected),
            .image_url => |url| return g.imageUrl(ctx, url, e.span),
            .audio_url => |path| return g.audioUrl(ctx, path, e.span),
            .video_url => |path| return g.videoUrl(ctx, path, e.span),
            .model_url => |path| return g.modelUrl(ctx, path, e.span),
            .tr => |t| return g.translated(ctx, t),
            .gradient => |gr| return g.gradient(ctx, gr),
            .struct_literal => |fields| return g.structLiteral(ctx, fields, e.span, expected),
            .lambda => return g.fail(e.span, "a function of a row goes in a model's filter or sort: items.filter(x => x > 0)", .{}),
            .index => |ix| {
                const m = try g.compileValue(ctx, ix.object, null);
                if (m.ty != .model) return g.fail(ix.object.span, "only models can be indexed, found {s}", .{m.ty.name()});
                const i = try g.compileExpr(ctx, ix.index, .int);
                const elem = m.ty.model.*;
                return .{ .code = try g.print("(({s}).rowData(@intCast(@max({s}, 0))) orelse {s})", .{ m.code, i.code, defaultValue(elem) }), .ty = elem };
            },
            .unary => |u| {
                const v = try g.compileValue(ctx, u.operand, null);
                switch (u.op) {
                    .bang => {
                        const b = try g.convert(v, .bool, u.operand.span);
                        return .{ .code = try g.print("!({s})", .{b.code}), .ty = .bool, .constant = b.constant };
                    },
                    .minus, .plus => {
                        if (!v.ty.isNumeric()) return g.fail(e.span, "cannot negate a {s}", .{v.ty.name()});
                        if (u.op == .plus) return v;
                        return .{ .code = try g.print("-({s})", .{v.code}), .ty = v.ty, .constant = v.constant };
                    },
                    else => unreachable,
                }
            },
            .binary => |b| return g.binary(ctx, b.op, b.lhs, b.rhs, e.span),
            .ternary => |t| {
                const cond = try g.compileExpr(ctx, t.cond, .bool);
                var then = try g.compileValue(ctx, t.then, expected);
                var otherwise = try g.compileValue(ctx, t.otherwise, expected);
                const ty = unify(then.ty, otherwise.ty) orelse
                    return g.fail(e.span, "the branches have different types: {s} and {s}", .{ then.ty.name(), otherwise.ty.name() });
                then = try g.convert(then, ty, t.then.span);
                otherwise = try g.convert(otherwise, ty, t.otherwise.span);
                // Literal branches are typed: a runtime `if` cannot yield
                // untyped integers.
                const then_code = if (then.constant and !cond.constant) try g.print("@as({s}, {s})", .{ ty.zig(), then.code }) else then.code;
                const else_code = if (otherwise.constant and !cond.constant) try g.print("@as({s}, {s})", .{ ty.zig(), otherwise.code }) else otherwise.code;
                return .{
                    .code = try g.print("(if ({s}) {s} else {s})", .{ cond.code, then_code, else_code }),
                    .ty = ty,
                    .constant = cond.constant and then.constant and otherwise.constant,
                };
            },
        }
    }

    /// `[a, b, c]`: a static, read-only model if the elements are constants,
    /// else an `ArrayModel` updated by the binding that reads it.
    fn array(g: *Generator, ctx: *Ctx, items: []const *ast.Expr, span: Span, expected: ?Type) Error!Value {
        var elem: ?Type = if (expected) |t| (if (t == .model) t.model.* else null) else null;
        var codes: std.ArrayList(u8) = .empty;
        var constant = true;
        for (items, 0..) |item, i| {
            const v = try g.compileExpr(ctx, item, elem);
            constant = constant and v.constant;
            if (elem == null) elem = v.ty;
            if (i > 0) try codes.appendSlice(g.arena, ", ");
            try codes.appendSlice(g.arena, v.code);
        }
        const elem_ty = elem orelse return g.fail(span, "the type of an empty array is unknown here", .{});
        const ty = types.modelOf(elem_ty) orelse return g.fail(span, "models of {s} are not supported", .{elem_ty.name()});
        if (!constant) {
            const n = ctx.fields.next_static;
            ctx.fields.next_static += 1;
            try g.appendFmt(&ctx.fields.expr_fields, "    _rows{d}: zigulee.core.ArrayModel({s}, {d}) = .{{}},\n", .{ n, elem_ty.zig(), items.len });
            try g.appendFmt(&ctx.fields.expr_deinit, "        self._rows{d}.deinit();\n", .{n});
            return .{ .code = try g.print("self._rows{d}.update(.{{ {s} }})", .{ n, codes.items }), .ty = ty };
        }
        const n = ctx.fields.next_static;
        ctx.fields.next_static += 1;
        try g.appendFmt(&ctx.fields.statics, "    var _array{d}: zigulee.core.SliceModel({s}) = .init(&.{{ {s} }});\n", .{ n, elem_ty.zig(), codes.items });
        return .{ .code = try g.print("_array{d}.model()", .{n}), .ty = ty, .constant = true };
    }

    /// `@image-url("x.png")`: decoded at compile time and embedded.
    fn imageUrl(g: *Generator, ctx: *Ctx, url: ast.ImageUrl, span: Span) Error!Value {
        const path = url.path;
        const bytes = g.readFile(try joinPath(g.arena, ctx.c.outermost().dir, path)) catch |err|
            return g.fail(span, "cannot read image '{s}': {t}", .{ path, err });
        if (zigulee_core.svg.isSvg(bytes)) return g.svgImage(ctx, url, bytes, span);
        const img = decodeImage(g.arena, bytes) catch |err|
            return g.fail(span, "cannot decode image '{s}': {t} (PNG, GIF and SVG are supported)", .{ path, err });
        const n = ctx.fields.next_static;
        ctx.fields.next_static += 1;
        const raw = std.mem.sliceAsBytes(img.pixels);
        try g.appendFmt(&ctx.fields.statics, "    const _image{d}_pixels = \"{f}\";\n", .{ n, std.zig.fmtString(raw) });
        // Animated: the file too, for AnimatedImage to play.
        var animation: []const u8 = "";
        if (zigulee_core.animated.isAnimated(g.arena, bytes)) {
            try g.appendFmt(&ctx.fields.statics, "    const _image{d}_file = \"{f}\";\n", .{ n, std.zig.fmtString(bytes) });
            animation = try g.print(", .animation = _image{d}_file", .{n});
        }
        return .{
            .code = try g.print("zigulee.core.Image{{ .width = {d}, .height = {d}, .pixels = std.mem.bytesAsSlice(zigulee.core.Rgba8, _image{d}_pixels){s}{s}{s} }}", .{ img.width, img.height, n, try g.nineSliceInit(url.nine_slice), animation, if (zigulee_core.image.allOpaque(img.pixels)) ", .is_opaque = true" else "" }),
            .ty = .image,
            .constant = true,
        };
    }

    /// An SVG file: its shapes embedded, drawn at the Image's size.
    fn svgImage(g: *Generator, ctx: *Ctx, url: ast.ImageUrl, bytes: []const u8, span: Span) Error!Value {
        const d = zigulee_core.svg.parse(g.arena, bytes) catch |err|
            return g.fail(span, "cannot read the SVG image '{s}': {t}", .{ url.path, err });
        const n = ctx.fields.next_static;
        ctx.fields.next_static += 1;
        var shapes: std.ArrayList(u8) = .empty;
        for (d.shapes) |s| try shapes.appendSlice(g.arena, try g.print("        {s},\n", .{try svgShape(g, s)}));
        const vb = d.viewbox;
        try g.appendFmt(&ctx.fields.statics, "    const _image{d}_shapes = [_]zigulee.core.svg.Shape{{\n{s}    }};\n    const _image{d}_drawing: zigulee.core.svg.Drawing = .{{ .viewbox = .{{ .x = {d}, .y = {d}, .width = {d}, .height = {d} }}, .width = {d}, .height = {d}, .shapes = &_image{d}_shapes }};\n", .{ n, shapes.items, n, vb.x, vb.y, vb.width, vb.height, d.width, d.height, n });
        return .{
            .code = try g.print("zigulee.core.Image{{ .width = {d}, .height = {d}, .pixels = &.{{}}, .vector = &_image{d}_drawing{s} }}", .{ @as(u32, @intFromFloat(@ceil(d.width))), @as(u32, @intFromFloat(@ceil(d.height))), n, try g.nineSliceInit(url.nine_slice) }),
            .ty = .image,
            .constant = true,
        };
    }

    /// A shape as a Zig literal (its mask's shapes in it).
    fn svgShape(g: *Generator, s: zigulee_core.svg.Shape) Allocator.Error![]const u8 {
        var extra: std.ArrayList(u8) = .empty;
        if (s.clip.len > 0) try g.appendFmt(&extra, ", .clip = \"{f}\"", .{std.zig.fmtString(s.clip)});
        if (s.blur > 0) try g.appendFmt(&extra, ", .blur = {d}", .{s.blur});
        if (s.mask.len > 0) {
            try extra.appendSlice(g.arena, ", .mask = &.{ ");
            for (s.mask) |m| try g.appendFmt(&extra, "{s}, ", .{try svgShape(g, m)});
            try extra.appendSlice(g.arena, "}");
        }
        if (s.text) |t| try g.appendFmt(&extra, ", .text = .{{ .content = \"{f}\", .x = {d}, .y = {d}, .size = {d}, .anchor = .{t}, .bold = {} }}", .{ std.zig.fmtString(t.content), t.x, t.y, t.size, t.anchor, t.bold });
        return g.print(".{{ .commands = \"{f}\", .fill = {s}, .stroke = {s}, .stroke_width = {d}{s} }}", .{ std.zig.fmtString(s.commands), try svgPaint(g, s.fill), try svgPaint(g, s.stroke), s.stroke_width, extra.items });
    }

    fn svgPaint(g: *Generator, p: ?zigulee_core.svg.Paint) Allocator.Error![]const u8 {
        const paint = p orelse return "null";
        return switch (paint) {
            .current => ".current",
            .color => |c| g.print(".{{ .color = zigulee.Color.rgba(0x{x:0>2}{x:0>2}{x:0>2}{x:0>2}) }}", .{ c.r, c.g, c.b, c.a }),
            .gradient => |b| {
                var stops: std.ArrayList(u8) = .empty;
                const items = switch (b) {
                    .solid => unreachable,
                    inline else => |gr| gr.stops.items,
                };
                for (items) |st| try g.appendFmt(&stops, ".{{ .color = zigulee.Color.rgba(0x{x:0>2}{x:0>2}{x:0>2}{x:0>2}), .position = {d} }}, ", .{ st.color.r, st.color.g, st.color.b, st.color.a, st.position });
                return switch (b) {
                    .solid => unreachable,
                    .linear_gradient => |gr| blk: {
                        const l = gr.line.?;
                        break :blk g.print(".{{ .gradient = .{{ .linear_gradient = &zigulee.core.LinearGradient{{ .stops = .init(&.{{ {s}}}), .line = .{{ .{{ {d}, {d} }}, .{{ {d}, {d} }} }} }} }} }}", .{ stops.items, l[0][0], l[0][1], l[1][0], l[1][1] });
                    },
                    .radial_gradient => |gr| blk: {
                        const e = gr.ellipse.?;
                        break :blk g.print(".{{ .gradient = .{{ .radial_gradient = &zigulee.core.RadialGradient{{ .stops = .init(&.{{ {s}}}), .ellipse = .{{ .center = .{{ {d}, {d} }}, .radius = .{{ {d}, {d} }} }} }} }} }}", .{ stops.items, e.center[0], e.center[1], e.radius[0], e.radius[1] });
                    },
                };
            },
        };
    }

    /// A PNG, or a GIF's first frame.
    pub fn decodeImage(gpa: Allocator, bytes: []const u8) !zigulee_core.image.OwnedImage {
        if (zigulee_core.gif.isGif(bytes)) return zigulee_core.animated.decodeGif(gpa, bytes);
        return png.decode(gpa, bytes);
    }

    fn nineSliceInit(g: *Generator, ns: ?[4]u32) Allocator.Error![]const u8 {
        const v = ns orelse return "";
        return g.print(", .nine_slice = .{{ .top = {d}, .right = {d}, .bottom = {d}, .left = {d} }}", .{ v[0], v[1], v[2], v[3] });
    }

    /// `@audio-url("x.wav")`: checked at compile time, and its samples
    /// embedded.
    fn audioUrl(g: *Generator, ctx: *Ctx, path: []const u8, span: Span) Error!Value {
        const bytes = g.readFile(try joinPath(g.arena, ctx.c.outermost().dir, path)) catch |err|
            return g.fail(span, "cannot read audio '{s}': {t}", .{ path, err });
        const clip = zigulee_core.audio.wav.decode(bytes) catch |err|
            return g.fail(span, "cannot decode audio '{s}': {t} (only WAV is supported)", .{ path, err });
        const n = ctx.fields.next_static;
        ctx.fields.next_static += 1;
        try g.appendFmt(&ctx.fields.statics, "    const _audio{d}_samples = \"{f}\";\n", .{ n, std.zig.fmtString(clip.data) });
        return .{
            .code = try g.print("zigulee.core.Audio{{ .format = .{t}, .channels = {d}, .sample_rate = {d}, .data = _audio{d}_samples }}", .{ clip.format, clip.channels, clip.sample_rate, n }),
            .ty = .audio,
            .constant = true,
        };
    }

    /// `@video-url("x.mp4")`: embedded as it is (decoded while playing).
    fn videoUrl(g: *Generator, ctx: *Ctx, path: []const u8, span: Span) Error!Value {
        const bytes = g.readFile(try joinPath(g.arena, ctx.c.outermost().dir, path)) catch |err|
            return g.fail(span, "cannot read video '{s}': {t}", .{ path, err });
        if (bytes.len == 0) return g.fail(span, "the video '{s}' is empty", .{path});
        const n = ctx.fields.next_static;
        ctx.fields.next_static += 1;
        try g.appendFmt(&ctx.fields.statics, "    const _video{d}_bytes = \"{f}\";\n", .{ n, std.zig.fmtString(bytes) });
        return .{ .code = try g.print("zigulee.core.Video{{ .bytes = _video{d}_bytes }}", .{n}), .ty = .video, .constant = true };
    }

    /// `@model-url("x.glb")`: embedded as it is (read when shown).
    fn modelUrl(g: *Generator, ctx: *Ctx, path: []const u8, span: Span) Error!Value {
        const bytes = g.readFile(try joinPath(g.arena, ctx.c.outermost().dir, path)) catch |err|
            return g.fail(span, "cannot read model '{s}': {t}", .{ path, err });
        if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "glTF")) return g.fail(span, "the model '{s}' is not a glTF binary file (.glb)", .{path});
        const n = ctx.fields.next_static;
        ctx.fields.next_static += 1;
        try g.appendFmt(&ctx.fields.statics, "    const _model{d}_bytes = \"{f}\";\n", .{ n, std.zig.fmtString(bytes) });
        return .{ .code = try g.print("zigulee.core.Model3D{{ .bytes = _model{d}_bytes }}", .{n}), .ty = .model3d, .constant = true };
    }

    /// `{ name: value, ... }` of the expected struct type.
    fn structLiteral(g: *Generator, ctx: *Ctx, fields: []const ast.FieldInit, span: Span, expected: ?Type) Error!Value {
        const t = expected orelse return g.fail(span, "the type of this struct is unknown here", .{});
        if (t != .structure) return g.fail(span, "expected {s}, found a struct", .{t.name()});
        const def = t.structure;
        var code: std.ArrayList(u8) = .empty;
        try code.appendSlice(g.arena, try g.print("{s}{{", .{def.zig}));
        var constant = true;
        for (fields) |f| {
            const field = t.field(f.name.name) orelse return g.fail(f.name.span, "{s} has no field '{s}'", .{ def.name, f.name.name });
            const v = try g.compileExpr(ctx, f.value, field[0]);
            constant = constant and v.constant;
            try code.appendSlice(g.arena, try g.print(" .{f} = {s},", .{ std.zig.fmtId(field[1]), v.code }));
        }
        try code.appendSlice(g.arena, " }");
        return .{ .code = code.items, .ty = t, .constant = constant };
    }

    /// The common type of two branches, or null.
    fn unify(a: Type, b: Type) ?Type {
        if (a.eql(b)) return a;
        if ((a == .int and b == .float) or (a == .float and b == .int)) return .float;
        if ((a == .color and b == .brush) or (a == .brush and b == .color)) return .brush;
        return null;
    }

    /// `@linear-gradient(...)` or `@radial-gradient(...)`: a static
    /// gradient if constant, else one made in a buffer field of the struct.
    fn gradient(g: *Generator, ctx: *Ctx, gr: ast.Gradient) Error!Value {
        var stops = gr.stops;
        var angle: Value = .{ .code = "@as(f32, 180)", .ty = .float, .constant = true };
        // The first argument is the angle if it is a number.
        var first: ?Value = null;
        if (stops[0].position == null) {
            const v = try g.compileValue(ctx, stops[0].color, null);
            if (gr.shape == .linear and stops.len > 1 and (v.ty == .int or v.ty == .float)) {
                angle = try g.convert(v, .float, stops[0].color.span);
                stops = stops[1..];
            } else first = v;
        }
        var code: std.ArrayList(u8) = .empty;
        var constant = angle.constant;
        for (stops, 0..) |s, i| {
            const color = try g.convert(if (i == 0 and first != null) first.? else try g.compileValue(ctx, s.color, .color), .color, s.color.span);
            const position: Value = if (s.position) |p| switch (p.kind) {
                .number => |n| if (std.mem.eql(u8, n.unit, "%"))
                    .{ .code = try g.print("@as(f32, {d})", .{n.value / 100}), .ty = .float, .constant = true }
                else
                    try g.compileExpr(ctx, p, .float),
                else => try g.compileExpr(ctx, p, .float),
            } else .{ .code = "zigulee.core.unplaced", .ty = .float, .constant = true };
            constant = constant and color.constant and position.constant;
            try g.appendFmt(&code, ".{{ .color = {s}, .position = {s} }}, ", .{ color.code, position.code });
        }
        const args = switch (gr.shape) {
            .linear => try g.print("{s}, ", .{angle.code}),
            .radial => "",
        };
        if (constant) return .{ .code = try g.print("zigulee.Brush.{t}({s}&zigulee.core.placedStops({d}, .{{ {s}}}))", .{ gr.shape, args, stops.len, code.items }), .ty = .brush, .constant = true };
        const n = ctx.fields.next_static;
        ctx.fields.next_static += 1;
        try g.appendFmt(&ctx.fields.expr_fields, "    _gradient{d}: zigulee.core.GradientBuffer({d}) = .{{}},\n", .{ n, stops.len });
        return .{ .code = try g.print("self._gradient{d}.{t}({s}.{{ {s}}})", .{ n, gr.shape, args, code.items }), .ty = .brush };
    }

    fn number(g: *Generator, ctx: *Ctx, n: anytype, span: Span) Error!Value {
        const lit = if (n.is_int) try g.print("{d}", .{@as(i64, @intFromFloat(n.value))}) else try g.print("{d}", .{n.value});
        if (n.unit.len == 0) return .{ .code = lit, .ty = if (n.is_int) .int else .float, .constant = true };
        if (std.mem.eql(u8, n.unit, "px")) return .{ .code = try g.print("@as(f32, {s})", .{lit}), .ty = .length, .constant = true };
        if (std.mem.eql(u8, n.unit, "ms")) return .{ .code = try g.print("@as(i64, {d})", .{@as(i64, @intFromFloat(n.value))}), .ty = .duration, .constant = true };
        if (std.mem.eql(u8, n.unit, "s")) return .{ .code = try g.print("@as(i64, {d})", .{@as(i64, @intFromFloat(n.value * 1000))}), .ty = .duration, .constant = true };
        if (std.mem.eql(u8, n.unit, "deg")) return .{ .code = try g.print("@as(f32, {d})", .{n.value}), .ty = .float, .constant = true };
        if (std.mem.eql(u8, n.unit, "%")) {
            const base = ctx.percent_base orelse return g.fail(span, "percentages are only allowed for width and height", .{});
            return .{ .code = try g.print("({s} * {d})", .{ base, n.value / 100 }), .ty = .length };
        }
        return g.fail(span, "unknown unit '{s}' (expected px, %, ms, s or deg)", .{n.unit});
    }

    fn string(g: *Generator, ctx: *Ctx, parts: []const ast.StringPart) Error!Value {
        if (parts.len == 1 and parts[0] == .literal)
            return .{ .code = try g.print("\"{f}\"", .{std.zig.fmtString(parts[0].literal)}), .ty = .string, .constant = true };
        var fmt: std.ArrayList(u8) = .empty;
        var args: std.ArrayList(u8) = .empty;
        for (parts) |part| switch (part) {
            .literal => |lit| for (lit) |ch| switch (ch) {
                '{' => try fmt.appendSlice(g.arena, "{{"),
                '}' => try fmt.appendSlice(g.arena, "}}"),
                else => try fmt.append(g.arena, ch),
            },
            .expr => |pe| {
                const v = try g.compileValue(ctx, pe, null);
                try fmt.appendSlice(g.arena, try g.formatSpec(v.ty, pe.span));
                if (args.items.len > 0) try args.appendSlice(g.arena, ", ");
                try args.appendSlice(g.arena, v.code);
            },
        };
        return g.formatString(ctx, fmt.items, args.items);
    }

    fn formatSpec(g: *Generator, ty: Type, span: Span) Error![]const u8 {
        return switch (ty) {
            .string => "{s}",
            .int, .float, .length, .duration => "{d}",
            .bool => "{}",
            else => g.fail(span, "a {s} cannot be shown in a string", .{ty.name()}),
        };
    }

    /// `@tr(...)`: the template in the current language, then its
    /// arguments filled in (into a buffer field) if it has placeholders.
    fn translated(g: *Generator, ctx: *Ctx, t: ast.Tr) Error!Value {
        var count: []const u8 = "0";
        if (t.count) |c| {
            const v = try g.compileValue(ctx, c, .int);
            if (v.ty != .int) return g.fail(c.span, "the count must be an int, found {s}", .{v.ty.name()});
            count = v.code;
        }
        const message = try g.print("zigulee.core.i18n.translate(.{{ .context = \"{f}\", .id = \"{f}\", .plural = {s}, .n = {s} }})", .{
            std.zig.fmtString(t.context),
            std.zig.fmtString(t.text),
            if (t.plural) |pl| try g.print("\"{f}\"", .{std.zig.fmtString(pl)}) else "null",
            count,
        });
        const braces = std.mem.indexOfAny(u8, t.text, "{}") != null or
            (if (t.plural) |pl| std.mem.indexOfAny(u8, pl, "{}") != null else false);
        if (t.args.len == 0 and !braces) return .{ .code = message, .ty = .string };

        var args: std.ArrayList(u8) = .empty;
        for (t.args) |a| {
            const v = try g.compileValue(ctx, a, null);
            const kind = switch (v.ty) {
                .string => "string",
                .int, .duration => "int",
                .float, .length => "float",
                .bool => "boolean",
                else => return g.fail(a.span, "a {s} cannot be shown in a string", .{v.ty.name()}),
            };
            try g.appendFmt(&args, ".{{ .{s} = {s} }}, ", .{ kind, v.code });
        }
        const n = ctx.fields.string_buffers;
        ctx.fields.string_buffers += 1;
        return .{
            .code = try g.print("self._s{d}.formatTranslated(self._gpa, {s}, &.{{ {s}}}, {s})", .{ n, message, args.items, count }),
            .ty = .string,
        };
    }

    /// A function's or callback's result, kept by this call: a string is
    /// copied into a buffer of the call's own, a struct or list into a
    /// `Kept` (the function makes them in memory of its own, rewritten by
    /// its next call, so several bindings calling it would show each
    /// other's results, or worse).
    fn ownValue(g: *Generator, ctx: *Ctx, v: Value) Error!Value {
        switch (v.ty) {
            .string => return g.formatString(ctx, "{s}", v.code),
            .structure, .model => {
                const n = ctx.fields.next_static;
                ctx.fields.next_static += 1;
                try g.appendFmt(&ctx.fields.expr_fields, "    _kept{d}: zigulee.core.Kept({s}) = .{{}},\n", .{ n, v.ty.zig() });
                try g.appendFmt(&ctx.fields.expr_deinit, "        self._kept{d}.deinit(self._gpa);\n", .{n});
                return .{ .code = try g.print("self._kept{d}.keep(self._gpa, {s})", .{ n, v.code }), .ty = v.ty };
            },
            else => return v,
        }
    }

    /// A string formatted into a buffer field of the struct.
    fn formatString(g: *Generator, ctx: *Ctx, fmt: []const u8, args: []const u8) Error!Value {
        const n = ctx.fields.string_buffers;
        ctx.fields.string_buffers += 1;
        return .{
            .code = try g.print("self._s{d}.format(self._gpa, \"{f}\", .{{ {s} }})", .{ n, std.zig.fmtString(fmt), args }),
            .ty = .string,
        };
    }

    fn convert(g: *Generator, v: Value, to: Type, span: Span) Error!Value {
        if (v.ty.eql(to)) return v;
        switch (to) {
            .float => if (v.ty == .int) return .{ .code = try g.print("@as(f32, @floatFromInt({s}))", .{v.code}), .ty = .float, .constant = v.constant },
            .length => if (v.ty == .int and v.constant and std.mem.eql(u8, v.code, "0")) return .{ .code = "@as(f32, 0)", .ty = .length, .constant = true },
            .brush => if (v.ty == .color) return .{ .code = try g.print("zigulee.Brush.color({s})", .{v.code}), .ty = .brush, .constant = v.constant },
            else => {},
        }
        if (to == .length and (v.ty == .int or v.ty == .float))
            return g.fail(span, "expected a length: add a unit, like 10px", .{});
        return g.fail(span, "expected {s}, found {s}", .{ to.name(), v.ty.name() });
    }

    fn binary(g: *Generator, ctx: *Ctx, op: Tag, lhs_e: *const ast.Expr, rhs_e: *const ast.Expr, span: Span) Error!Value {
        var lhs = try g.compileValue(ctx, lhs_e, null);
        // `mode == dark`: the right side may be a bare value of the left's enum.
        const rhs_hint: ?Type = if ((op == .equal_equal or op == .bang_equal) and lhs.ty == .enumeration) lhs.ty else null;
        var rhs = try g.compileValue(ctx, rhs_e, rhs_hint);
        const constant = lhs.constant and rhs.constant;
        switch (op) {
            .and_and, .or_or => {
                lhs = try g.convert(lhs, .bool, lhs_e.span);
                rhs = try g.convert(rhs, .bool, rhs_e.span);
                return .{ .code = try g.print("({s} {s} {s})", .{ lhs.code, if (op == .and_and) "and" else "or", rhs.code }), .ty = .bool, .constant = constant };
            },
            .equal_equal, .bang_equal => {
                const neg = if (op == .bang_equal) "!" else "";
                if (lhs.ty == .string and rhs.ty == .string)
                    return .{ .code = try g.print("{s}std.mem.eql(u8, {s}, {s})", .{ neg, lhs.code, rhs.code }), .ty = .bool, .constant = constant };
                const ty = unify(lhs.ty, rhs.ty) orelse
                    return g.fail(span, "cannot compare {s} with {s}", .{ lhs.ty.name(), rhs.ty.name() });
                lhs = try g.convert(lhs, ty, lhs_e.span);
                rhs = try g.convert(rhs, ty, rhs_e.span);
                const code = switch (ty) {
                    .color, .model => try g.print("{s}std.meta.eql({s}, {s})", .{ neg, lhs.code, rhs.code }),
                    .brush, .structure => try g.print("{s}({s}).eql({s})", .{ neg, lhs.code, rhs.code }),
                    else => try g.print("({s} {s} {s})", .{ lhs.code, if (op == .equal_equal) "==" else "!=", rhs.code }),
                };
                return .{ .code = code, .ty = .bool, .constant = constant };
            },
            .less, .less_equal, .greater, .greater_equal => {
                const ty = numericCommon(lhs.ty, rhs.ty) orelse
                    return g.fail(span, "cannot compare {s} with {s}", .{ lhs.ty.name(), rhs.ty.name() });
                lhs = try g.convert(lhs, ty, lhs_e.span);
                rhs = try g.convert(rhs, ty, rhs_e.span);
                const sym = switch (op) {
                    .less => "<",
                    .less_equal => "<=",
                    .greater => ">",
                    else => ">=",
                };
                return .{ .code = try g.print("({s} {s} {s})", .{ lhs.code, sym, rhs.code }), .ty = .bool, .constant = constant };
            },
            .plus, .minus, .star, .slash => {
                if (op == .plus and (lhs.ty == .string or rhs.ty == .string)) {
                    // Concatenation.
                    const fmt = try g.print("{s}{s}", .{ try g.formatSpec(lhs.ty, lhs_e.span), try g.formatSpec(rhs.ty, rhs_e.span) });
                    return g.formatString(ctx, fmt, try g.print("{s}, {s}", .{ lhs.code, rhs.code }));
                }
                const sym = switch (op) {
                    .plus => "+",
                    .minus => "-",
                    .star => "*",
                    else => "/",
                };
                const result = arithmeticType(op, lhs.ty, rhs.ty) orelse
                    return g.fail(span, "cannot apply '{s}' to {s} and {s}", .{ sym, lhs.ty.name(), rhs.ty.name() });
                // A duration scaled by a float: in floats, rounded to whole
                // milliseconds (`0.75 * 2s` is 1500ms, not 0 * 2s).
                if (result == .duration and (lhs.ty == .float or rhs.ty == .float)) {
                    const lf = if (lhs.ty == .duration) try g.print("@as(f64, @floatFromInt({s}))", .{lhs.code}) else try g.print("@as(f64, {s})", .{try g.numericAs(lhs, .float)});
                    const rf = if (rhs.ty == .duration) try g.print("@as(f64, @floatFromInt({s}))", .{rhs.code}) else try g.print("@as(f64, {s})", .{try g.numericAs(rhs, .float)});
                    return .{ .code = try g.print("zigulee.core.intFromFloat(i64, @round({s} {s} {s}))", .{ lf, sym, rf }), .ty = .duration, .constant = constant };
                }
                // A duration divided by an int: truncated, like the interpreter.
                if (result == .duration and op == .slash) {
                    return .{ .code = try g.print("zigulee.core.divDuration({s}, {s})", .{ try g.numericAs(lhs, .duration), try g.numericAs(rhs, .duration) }), .ty = .duration, .constant = constant };
                }
                // Compute in the result's representation (int / int divides as floats).
                const operand: Type = if (result == .int) .int else if (result == .duration) .duration else .float;
                const l = try g.numericAs(lhs, operand);
                const r = try g.numericAs(rhs, operand);
                return .{ .code = try g.print("({s} {s} {s})", .{ l, sym, r }), .ty = result, .constant = constant };
            },
            else => unreachable,
        }
    }

    /// The type both sides compare as.
    fn numericCommon(a: Type, b: Type) ?Type {
        if (a.eql(b) and a.isNumeric()) return a;
        if ((a == .int or a == .float) and (b == .int or b == .float)) return .float;
        return null;
    }

    fn arithmeticType(op: Tag, a: Type, b: Type) ?Type {
        const num = struct {
            fn is(t: Type) bool {
                return t == .int or t == .float;
            }
        }.is;
        switch (op) {
            .plus, .minus => {
                if (a.eql(b) and a.isNumeric()) return a;
                if (num(a) and num(b)) return .float;
            },
            .star => {
                if (a == .int and b == .int) return .int;
                if (num(a) and num(b)) return .float;
                if ((a == .length and num(b)) or (num(a) and b == .length)) return .length;
                if ((a == .duration and num(b)) or (num(a) and b == .duration)) return .duration;
            },
            .slash => {
                if (num(a) and num(b)) return .float;
                if (a == .length and num(b)) return .length;
                if (a == .length and b == .length) return .float;
                if (a == .duration and num(b)) return .duration;
                if (a == .duration and b == .duration) return .float;
            },
            else => {},
        }
        return null;
    }

    /// The value's code as `as` (int, float or duration representation).
    fn numericAs(g: *Generator, v: Value, as: Type) Allocator.Error![]const u8 {
        return switch (as) {
            .int => v.code,
            .duration => if (v.ty == .duration or v.ty == .int) v.code else try g.print("zigulee.core.intFromFloat(i64, {s})", .{v.code}),
            else => if (v.ty == .int or v.ty == .duration) try g.print("@as(f32, @floatFromInt({s}))", .{v.code}) else v.code,
        };
    }

    /// `model.map(row => value)`: a model of the values (of their type).
    fn mapModel(g: *Generator, ctx: *Ctx, src: Value, l: anytype, n: u32) Error!Value {
        const outer = ctx.locals;
        defer ctx.locals = outer;
        try g.addLocal(ctx, .{ .name = l.param.name, .zig = try g.print("row{d}", .{n}), .ty = src.ty.model.* });
        const v = try g.compileValue(ctx, l.body, null);
        switch (v.ty) {
            .int, .float, .length, .bool, .string, .color, .brush, .structure => {},
            else => return g.fail(l.body.span, "a model of {s} cannot be made: map to numbers, bools, strings, colors, brushes or structs", .{v.ty.name()}),
        }
        const elem = try g.arena.create(Type);
        elem.* = v.ty;
        const U = v.ty.zig();
        try g.appendFmt(&ctx.fields.expr_fields, "    _derived{d}: zigulee.core.DerivedModel({s}) = .{{}},\n", .{ n, U });
        try g.appendFmt(&ctx.fields.expr_deinit, "        self._derived{d}.deinit(self._gpa);\n", .{n});
        // Strings made in the loop share a buffer: each kept.
        const value = if (v.ty == .string) try g.print("(strings{d}.dupe(u8, {s}) catch \"\")", .{ n, v.code }) else v.code;
        var code: std.ArrayList(u8) = .empty;
        try g.appendFmt(&code, "blk{d}: {{ const src{d} = {s}; var rows{d}: std.ArrayList({s}) = .empty; defer rows{d}.deinit(self._gpa); ", .{ n, n, src.code, n, U, n });
        if (v.ty == .string) try g.appendFmt(&code, "const strings{d} = self._derived{d}.nextStrings(self._gpa); ", .{ n, n });
        try g.appendFmt(&code, "for (0..src{d}.rowCount()) |i| {{ const row{d} = src{d}.rowData(i) orelse continue; rows{d}.append(self._gpa, {s}) catch {{}}; }} ", .{ n, n, n, n, value });
        try g.appendFmt(&code, "break :blk{d} self._derived{d}.update(self._gpa, rows{d}.items); }}", .{ n, n, n });
        return .{ .code = code.items, .ty = .{ .model = elem } };
    }

    fn isModelOp(name: []const u8) bool {
        return std.mem.eql(u8, name, "filter") or std.mem.eql(u8, name, "sort") or std.mem.eql(u8, name, "reverse") or std.mem.eql(u8, name, "map");
    }

    /// A model computed from `src` at this site (a `DerivedModel` field,
    /// refilled at each evaluation: reading the rows and what the lambda
    /// reads makes its binding depend on them).
    fn modelOp(g: *Generator, ctx: *Ctx, src: Value, op: []const u8, args: []const *ast.Expr, span: Span) Error!Value {
        const row_ty = src.ty.model.*;
        const reverse = std.mem.eql(u8, op, "reverse");
        if (reverse and args.len != 0) return g.fail(span, "reverse takes nothing", .{});
        if (!reverse and (args.len != 1 or args[0].kind != .lambda))
            return g.fail(span, "{s} takes a function of a row: {s}(row => ...)", .{ op, op });
        const n = ctx.fields.next_static;
        ctx.fields.next_static += 1;
        const T = row_ty.zig();
        if (std.mem.eql(u8, op, "map")) return g.mapModel(ctx, src, args[0].kind.lambda, n);
        try g.appendFmt(&ctx.fields.expr_fields, "    _derived{d}: zigulee.core.DerivedModel({s}) = .{{}},\n", .{ n, T });
        try g.appendFmt(&ctx.fields.expr_deinit, "        self._derived{d}.deinit(self._gpa);\n", .{n});

        var lambda: ?Value = null;
        if (!reverse) {
            const l = args[0].kind.lambda;
            const outer = ctx.locals;
            defer ctx.locals = outer;
            try g.addLocal(ctx, .{ .name = l.param.name, .zig = try g.print("row{d}", .{n}), .ty = row_ty });
            lambda = if (std.mem.eql(u8, op, "filter")) try g.compileExpr(ctx, l.body, .bool) else try g.compileValue(ctx, l.body, null);
            if (std.mem.eql(u8, op, "sort")) switch (lambda.?.ty) {
                .int, .float, .length, .duration, .bool, .string => {},
                else => return g.fail(l.body.span, "rows are sorted by a number, a bool or a string, not a {s}", .{lambda.?.ty.name()}),
            };
        }
        var code: std.ArrayList(u8) = .empty;
        try g.appendFmt(&code, "blk{d}: {{ const src{d} = {s}; var rows{d}: std.ArrayList({s}) = .empty; defer rows{d}.deinit(self._gpa); ", .{ n, n, src.code, n, T, n });
        if (std.mem.eql(u8, op, "sort")) {
            const K = lambda.?.ty.zig();
            try g.appendFmt(&code, "var keys{d}: std.ArrayList({s}) = .empty; defer keys{d}.deinit(self._gpa); var arena{d}: std.heap.ArenaAllocator = .init(self._gpa); defer arena{d}.deinit(); ", .{ n, K, n, n, n });
            // Strings formatted in the loop share a buffer: each kept.
            const key = if (lambda.?.ty == .string) try g.print("(arena{d}.allocator().dupe(u8, {s}) catch \"\")", .{ n, lambda.?.code }) else lambda.?.code;
            try g.appendFmt(&code, "for (0..src{d}.rowCount()) |i| {{ const row{d} = src{d}.rowData(i) orelse continue; rows{d}.append(self._gpa, row{d}) catch {{}}; keys{d}.append(self._gpa, {s}) catch {{}}; }} ", .{ n, n, n, n, n, n, key });
            try g.appendFmt(&code, "if (keys{d}.items.len == rows{d}.items.len) zigulee.core.sortByKeys({s}, {s}, self._gpa, rows{d}.items, keys{d}.items); ", .{ n, n, T, K, n, n });
        } else if (reverse) {
            try g.appendFmt(&code, "for (0..src{d}.rowCount()) |i| {{ rows{d}.append(self._gpa, src{d}.rowData(i) orelse continue) catch {{}}; }} std.mem.reverse({s}, rows{d}.items); ", .{ n, n, n, T, n });
        } else {
            try g.appendFmt(&code, "for (0..src{d}.rowCount()) |i| {{ const row{d} = src{d}.rowData(i) orelse continue; if ({s}) rows{d}.append(self._gpa, row{d}) catch {{}}; }} ", .{ n, n, n, lambda.?.code, n, n });
        }
        try g.appendFmt(&code, "break :blk{d} self._derived{d}.update(self._gpa, rows{d}.items); }}", .{ n, n, n });
        return .{ .code = code.items, .ty = src.ty };
    }

    fn call(g: *Generator, ctx: *Ctx, callee: *const ast.Expr, args: []const *ast.Expr, span: Span) Error!Value {
        // `cubic-bezier(a, b, c, d)` as an easing.
        if (callee.kind == .ident and std.mem.eql(u8, callee.kind.ident, "cubic-bezier")) {
            if (args.len != 4) return g.fail(span, "cubic-bezier takes 4 numbers", .{});
            var code: std.ArrayList(u8) = .empty;
            try code.appendSlice(g.arena, "zigulee.Easing{ .cubic_bezier = .{ ");
            for (args, 0..) |a, i| {
                const v = try g.compileExpr(ctx, a, .float);
                if (i > 0) try code.appendSlice(g.arena, ", ");
                try code.appendSlice(g.arena, v.code);
            }
            try code.appendSlice(g.arena, " } }");
            return .{ .code = code.items, .ty = .easing, .constant = true };
        }
        // `model.filter(row => ...)`, `.sort(row => key)`, `.reverse()`.
        if (callee.kind == .member and isModelOp(callee.kind.member.name.name)) {
            const m = callee.kind.member;
            const obj = try g.compileRef(ctx, m.object);
            if (obj == .value or obj == .property) {
                const src = try g.refToValue(obj, m.object.span);
                if (src.ty == .model) return g.modelOp(ctx, src, m.name.name, args, span);
            }
        }
        // `spring(bounce)` as an easing.
        if (callee.kind == .ident and std.mem.eql(u8, callee.kind.ident, "spring")) {
            if (args.len != 1) return g.fail(span, "spring takes 1 number: its bounce, from 0 (none) to 1", .{});
            const v = try g.compileExpr(ctx, args[0], .float);
            return .{ .code = try g.print("zigulee.Easing{{ .spring = {s} }}", .{v.code}), .ty = .easing, .constant = v.constant };
        }
        // `machine.active(state)`: the state's name, not an expression.
        if (callee.kind == .member and std.mem.eql(u8, callee.kind.member.name.name, "active")) {
            const obj = try g.compileRef(ctx, callee.kind.member.object);
            if (obj == .element) if (obj.element.machine) |m| {
                const parts = (if (args.len == 1) try Machine.exprParts(g.arena, args[0]) else null) orelse
                    return g.fail(span, "active takes a state's name or path: active(name), active(a.b)", .{});
                const found = try g.findStateParts(obj.element, m, parts, args[0].span, null);
                if (found.history) return g.fail(args[0].span, "a history is not a state: active() takes the state", .{});
                const loc = try g.locFrom(ctx.c, obj.element);
                return .{ .code = try g.print("self.{s}{s}.isActive({d})", .{ loc.prefix, loc.field, found.state }), .ty = .bool };
            };
        }
        const ref = try g.compileRef(ctx, callee);
        switch (ref) {
            .callback => |cb| {
                if (args.len != cb.params.len) return g.fail(span, "expected {d} argument(s), found {d}", .{ cb.params.len, args.len });
                var code: std.ArrayList(u8) = .empty;
                for (args, cb.params, 0..) |a, t, i| {
                    const v = try g.compileExpr(ctx, a, t);
                    if (i > 0) try code.appendSlice(g.arena, ", ");
                    try code.appendSlice(g.arena, v.code);
                }
                return g.ownValue(ctx, .{ .code = try g.print("self.{s}.call(.{{ {s} }})", .{ cb.path, code.items }), .ty = cb.ret });
            },
            .function => |f| {
                if (args.len != f.params.len) return g.fail(span, "expected {d} argument(s), found {d}", .{ f.params.len, args.len });
                var code: std.ArrayList(u8) = .empty;
                for (args, f.params, 0..) |a, t, i| {
                    const v = try g.compileExpr(ctx, a, t);
                    if (i > 0) try code.appendSlice(g.arena, ", ");
                    try code.appendSlice(g.arena, v.code);
                }
                return g.ownValue(ctx, .{ .code = try g.print("{s}{s}({s})", .{ f.prefix, f.method, code.items }), .ty = f.ret });
            },
            .global => |name| return g.globalCall(ctx, name, args, span),
            else => return g.fail(callee.span, "this is not a callback or function", .{}),
        }
    }

    fn globalCall(g: *Generator, ctx: *Ctx, name: []const u8, args: []const *ast.Expr, span: Span) Error!Value {
        if (std.mem.eql(u8, name, "debug")) {
            var fmt: std.ArrayList(u8) = .empty;
            var list: std.ArrayList(u8) = .empty;
            for (args, 0..) |a, i| {
                const v = try g.compileValue(ctx, a, null);
                if (i > 0) {
                    try fmt.append(g.arena, ' ');
                    try list.appendSlice(g.arena, ", ");
                }
                try fmt.appendSlice(g.arena, switch (v.ty) {
                    .string => "{s}",
                    .int, .float, .length, .duration => "{d}",
                    else => "{any}",
                });
                try list.appendSlice(g.arena, v.code);
            }
            return .{ .code = try g.print("std.debug.print(\"{f}\\n\", .{{ {s} }})", .{ std.zig.fmtString(fmt.items), list.items }), .ty = .void };
        }
        if (std.mem.eql(u8, name, "open-url")) {
            if (args.len != 1) return g.fail(span, "'open-url' takes 1 argument: the URL", .{});
            const v = try g.compileValue(ctx, args[0], .string);
            if (v.ty != .string) return g.fail(args[0].span, "'open-url' needs a string, found {s}", .{v.ty.name()});
            return .{ .code = try g.print("zigulee.core.links.openUrl({s})", .{v.code}), .ty = .bool };
        }
        if (std.mem.startsWith(u8, name, "json-")) {
            if (args.len != 2) return g.fail(span, "'{s}' takes 2 arguments: the JSON text and a path", .{name});
            var parts: [2][]const u8 = undefined;
            for (args, &parts) |a, *part| {
                const v = try g.compileValue(ctx, a, .string);
                if (v.ty != .string) return g.fail(a.span, "'{s}' needs a string, found {s}", .{ name, v.ty.name() });
                part.* = v.code;
            }
            if (std.mem.eql(u8, name, "json-number")) return .{ .code = try g.print("zigulee.core.json.number({s}, {s})", .{ parts[0], parts[1] }), .ty = .float };
            if (std.mem.eql(u8, name, "json-count")) return .{ .code = try g.print("zigulee.core.json.count({s}, {s})", .{ parts[0], parts[1] }), .ty = .int };
            const n = ctx.fields.string_buffers;
            ctx.fields.string_buffers += 1;
            return .{ .code = try g.print("self._s{d}.json(self._gpa, {s}, {s})", .{ n, parts[0], parts[1] }), .ty = .string };
        }
        const unary = std.mem.eql(u8, name, "abs") or std.mem.eql(u8, name, "round") or std.mem.eql(u8, name, "floor") or
            std.mem.eql(u8, name, "ceil") or std.mem.eql(u8, name, "sqrt") or std.mem.eql(u8, name, "sin") or std.mem.eql(u8, name, "cos");
        if (args.len != @as(usize, if (unary) 1 else 2)) return g.fail(span, "'{s}' takes {d} argument(s)", .{ name, @as(usize, if (unary) 1 else 2) });
        const a = try g.compileValue(ctx, args[0], null);
        if (!a.ty.isNumeric()) return g.fail(args[0].span, "'{s}' needs a number, found {s}", .{ name, a.ty.name() });
        if (unary) {
            if (std.mem.eql(u8, name, "abs")) return .{ .code = try g.print("@abs({s})", .{a.code}), .ty = a.ty, .constant = a.constant };
            if (std.mem.eql(u8, name, "sqrt")) return .{ .code = try g.print("@sqrt({s})", .{try g.numericAs(a, .float)}), .ty = .float, .constant = a.constant };
            // Of degrees.
            if (std.mem.eql(u8, name, "sin") or std.mem.eql(u8, name, "cos"))
                return .{ .code = try g.print("@{s}(std.math.degreesToRadians({s}))", .{ name, try g.numericAs(a, .float) }), .ty = .float, .constant = a.constant };
            if (a.ty == .int) return a;
            // round / floor / ceil give integers.
            return .{ .code = try g.print("zigulee.core.intFromFloat(i32, @{s}({s}))", .{ name, try g.numericAs(a, .float) }), .ty = .int, .constant = a.constant };
        }
        const b = try g.compileValue(ctx, args[1], null);
        const ty = numericCommon(a.ty, b.ty) orelse return g.fail(span, "'{s}' needs two numbers of the same kind, found {s} and {s}", .{ name, a.ty.name(), b.ty.name() });
        const l = try g.convert(a, ty, args[0].span);
        const r = try g.convert(b, ty, args[1].span);
        const zig_fn = if (std.mem.eql(u8, name, "mod")) "@mod" else if (std.mem.eql(u8, name, "min")) "@min" else "@max";
        return .{ .code = try g.print("{s}({s}, {s})", .{ zig_fn, l.code, r.code }), .ty = ty, .constant = a.constant and b.constant };
    }

    // ---- Statements ----

    /// A block: its `let`s are in scope until its end.
    fn compileStmts(g: *Generator, ctx: *Ctx, stmts: []const ast.Stmt, w: *Writer, indent: usize) Error!void {
        const outer = ctx.locals;
        defer ctx.locals = outer;
        for (stmts) |*s| g.compileStmt(ctx, s, w, indent) catch |err| switch (err) {
            error.CompileError => continue,
            else => return err,
        };
    }

    fn addLocal(g: *Generator, ctx: *Ctx, local: Local) Allocator.Error!void {
        const list = try g.arena.alloc(Local, ctx.locals.len + 1);
        @memcpy(list[0..ctx.locals.len], ctx.locals);
        list[ctx.locals.len] = local;
        ctx.locals = list;
    }

    fn localName(g: *Generator, name: []const u8) Allocator.Error![]const u8 {
        const n = g.next_local;
        g.next_local += 1;
        return g.print("l{d}_{s}", .{ n, try zigName(g.arena, name) });
    }

    fn findLocal(ctx: *const Ctx, name: []const u8) ?Local {
        var i = ctx.locals.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, ctx.locals[i].name, name)) return ctx.locals[i];
        }
        return null;
    }

    /// The code that stores `value` in local `l`.
    fn localValue(g: *Generator, l: Local, value: []const u8) Allocator.Error![]const u8 {
        if (l.buffer) |n| return g.print("self._s{d}.format(self._gpa, \"{{s}}\", .{{{s}}})", .{ n, value });
        return value;
    }

    /// A loop body, with `consts` (name, Zig name, type, code) declared at
    /// the top of each turn (left out if unused).
    fn compileLoopBody(g: *Generator, ctx: *Ctx, body: []const ast.Stmt, consts: []const struct { ast.Ident, []const u8, Type, []const u8 }, w: *Writer, indent: usize) Error!void {
        const outer = ctx.locals;
        defer ctx.locals = outer;
        for (consts) |c| try g.addLocal(ctx, .{ .name = c[0].name, .zig = c[1], .ty = c[2] });
        ctx.loops += 1;
        defer ctx.loops -= 1;
        var inner: Writer.Allocating = .init(g.arena);
        try g.compileStmts(ctx, body, &inner.writer, indent);
        const text = inner.written();
        for (consts) |c| if (usesIdent(text, c[1])) try line(w, indent, "const {s}: {s} = {s};", .{ c[1], c[2].zig(), c[3] });
        w.writeAll(text) catch return error.OutOfMemory;
    }

    fn writeIndent(w: *Writer, indent: usize) Allocator.Error!void {
        w.splatByteAll(' ', indent * 4) catch return error.OutOfMemory;
    }

    fn line(w: *Writer, indent: usize, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try writeIndent(w, indent);
        w.print(fmt ++ "\n", args) catch return error.OutOfMemory;
    }

    fn compileStmt(g: *Generator, ctx: *Ctx, s: *const ast.Stmt, w: *Writer, indent: usize) Error!void {
        switch (s.kind) {
            .expr => |e| {
                const v = try g.compileValue(ctx, e, null);
                if (v.ty == .void) try line(w, indent, "{s};", .{v.code}) else try line(w, indent, "_ = {s};", .{v.code});
            },
            .assign => |a| {
                if (a.target.kind == .ident) if (findLocal(ctx, a.target.kind.ident)) |l| {
                    if (!l.mutable) return g.fail(a.target.span, "cannot assign to '{s}': only properties and 'let' variables can be assigned", .{l.name});
                    // `x += v` is `x = x + v` (strings too).
                    const op: Tag = switch (a.op) {
                        .equal => .equal,
                        .plus_equal => .plus,
                        .minus_equal => .minus,
                        .star_equal => .star,
                        else => .slash,
                    };
                    const sum: ast.Expr = .{ .kind = .{ .binary = .{ .op = op, .lhs = a.target, .rhs = a.value } }, .span = s.span };
                    const value = try g.compileExpr(ctx, if (a.op == .equal) a.value else &sum, l.ty);
                    try line(w, indent, "{s} = {s};", .{ l.zig, try g.localValue(l, value.code) });
                    return;
                };
                const ref = try g.compileRef(ctx, a.target);
                const p = switch (ref) {
                    .property => |p| p,
                    else => return g.fail(a.target.span, "only properties can be assigned", .{}),
                };
                if (p.read_only) return g.fail(a.target.span, "cannot assign to this property: {s}", .{p.read_only_reason});
                if (p.owner) |o| o.constraints = true;
                var value = try g.compileExpr(ctx, a.value, if (a.op == .equal) p.ty else null);
                if (a.op == .plus_equal and p.ty == .string) {
                    // `text += v` is `text = text + v`.
                    const sum: ast.Expr = .{ .kind = .{ .binary = .{ .op = .plus, .lhs = a.target, .rhs = a.value } }, .span = s.span };
                    value = try g.compileExpr(ctx, &sum, .string);
                } else if (a.op != .equal) {
                    const current = try g.refToValue(.{ .property = p }, a.target.span);
                    const op: Tag = switch (a.op) {
                        .plus_equal => .plus,
                        .minus_equal => .minus,
                        .star_equal => .star,
                        else => .slash,
                    };
                    const result = arithmeticType(op, current.ty, value.ty) orelse
                        return g.fail(s.span, "cannot apply {s} to {s} and {s}", .{ op.describe(), current.ty.name(), value.ty.name() });
                    const operand: Type = if (result == .int) .int else if (result == .duration) .duration else .float;
                    value = try g.convert(.{
                        .code = try g.print("({s} {s} {s})", .{ try g.numericAs(current, operand), op.describe()[1..2], try g.numericAs(value, operand) }),
                        .ty = result,
                    }, p.ty, s.span);
                }
                try writeSet(w, indent, p, value.code);
            },
            .@"if" => |i| {
                const cond = try g.compileExpr(ctx, i.cond, .bool);
                try line(w, indent, "if ({s}) {{", .{cond.code});
                try g.compileStmts(ctx, i.then, w, indent + 1);
                if (i.otherwise.len > 0) {
                    try line(w, indent, "}} else {{", .{});
                    try g.compileStmts(ctx, i.otherwise, w, indent + 1);
                }
                try line(w, indent, "}}", .{});
            },
            .let => |l| {
                var value = try g.compileExpr(ctx, l.value, null);
                if (l.type_name) |t| value = try g.convert(value, try g.declType(t), l.value.span);
                if (value.ty == .void) return g.fail(l.value.span, "'{s}' needs a value; this has none", .{l.name.name});
                try g.let_types.put(g.arena, s, value.ty);
                const local: Local = .{
                    .name = l.name.name,
                    .zig = try g.localName(l.name.name),
                    .ty = value.ty,
                    .mutable = true,
                    .buffer = if (value.ty == .string) blk: {
                        const n = ctx.fields.string_buffers;
                        ctx.fields.string_buffers += 1;
                        break :blk n;
                    } else null,
                };
                try line(w, indent, "var {s}: {s} = {s};", .{ local.zig, value.ty.zig(), try g.localValue(local, value.code) });
                try line(w, indent, "_ = &{s};", .{local.zig});
                try g.addLocal(ctx, local);
            },
            .@"while" => |wh| {
                const cond = try g.compileExpr(ctx, wh.cond, .bool);
                try line(w, indent, "while ({s}) {{", .{cond.code});
                try g.compileLoopBody(ctx, wh.body, &.{}, w, indent + 1);
                try line(w, indent, "}}", .{});
            },
            .@"for" => |f| {
                const over = try g.compileValue(ctx, f.over, null);
                const n = g.next_local;
                g.next_local += 1;
                const item = try g.localName(f.item.name);
                try line(w, indent, "{{", .{});
                switch (over.ty) {
                    .model => |elem| {
                        try line(w, indent + 1, "const over{d} = {s};", .{ n, over.code });
                        try line(w, indent + 1, "var row{d}: usize = 0;", .{n});
                        try line(w, indent + 1, "while (row{d} < over{d}.rowCount()) : (row{d} += 1) {{", .{ n, n, n });
                        if (f.index) |index| {
                            try g.compileLoopBody(ctx, f.body, &.{
                                .{ f.item, item, elem.*, try g.print("over{d}.rowData(row{d}) orelse {s}", .{ n, n, defaultValue(elem.*) }) },
                                .{ index, try g.localName(index.name), .int, try g.print("@intCast(row{d})", .{n}) },
                            }, w, indent + 2);
                        } else {
                            try g.compileLoopBody(ctx, f.body, &.{
                                .{ f.item, item, elem.*, try g.print("over{d}.rowData(row{d}) orelse {s}", .{ n, n, defaultValue(elem.*) }) },
                            }, w, indent + 2);
                        }
                    },
                    .int => {
                        if (f.index) |index| return g.fail(index.span, "a count has no index: 'for {s} in n' counts from 0 to n - 1", .{f.item.name});
                        try line(w, indent + 1, "const over{d}: i32 = {s};", .{ n, over.code });
                        try line(w, indent + 1, "var row{d}: i32 = 0;", .{n});
                        try line(w, indent + 1, "while (row{d} < over{d}) : (row{d} += 1) {{", .{ n, n, n });
                        try g.compileLoopBody(ctx, f.body, &.{.{ f.item, item, .int, try g.print("row{d}", .{n}) }}, w, indent + 2);
                    },
                    else => return g.fail(f.over.span, "'for' goes over a model or a count, not a {s}", .{over.ty.name()}),
                }
                try line(w, indent + 1, "}}", .{});
                try line(w, indent, "}}", .{});
            },
            .@"break", .@"continue" => {
                if (ctx.loops == 0) return g.fail(s.span, "'{s}' outside a loop", .{@tagName(s.kind)});
                try line(w, indent, "{s};", .{@tagName(s.kind)});
            },
            .@"return" => |value| {
                if (value) |v| {
                    if (ctx.ret == .void) return g.fail(v.span, "this callback returns nothing", .{});
                    const r = try g.compileExpr(ctx, v, ctx.ret);
                    try line(w, indent, "return {s};", .{r.code});
                } else {
                    if (ctx.ret != .void) return g.fail(s.span, "this callback must return a {s}", .{ctx.ret.name()});
                    try line(w, indent, "return;", .{});
                }
            },
        }
    }

    /// Writes `value` into the property (animated if it has an animation).
    fn writeSet(w: *Writer, indent: usize, p: PropRef, value: []const u8) Error!void {
        var it = std.mem.splitScalar(u8, p.path, ',');
        while (it.next()) |path| {
            if (p.optional) {
                try line(w, indent, "self.{s}.set(@as(?{s}, {s}));", .{ path, p.ty.zig(), value });
            } else if (p.anim) |anim| {
                try line(w, indent, "self.{s}.setAnimated(self._gpa, {s}, {s}) catch {{}};", .{ path, value, anim });
            } else {
                try line(w, indent, "self.{s}.set({s});", .{ path, value });
            }
        }
    }

    fn alwaysReturns(stmts: []const ast.Stmt) bool {
        if (stmts.len == 0) return false;
        const last = stmts[stmts.len - 1];
        return switch (last.kind) {
            .@"return" => true,
            .@"if" => |i| alwaysReturns(i.then) and alwaysReturns(i.otherwise),
            else => false,
        };
    }

    // ---- Struct emission ----

    fn emitComponent(g: *Generator, out: *Writer, c: *Comp) Error!void {
        var fields: Fields = .{};
        var init_w: Writer.Allocating = .init(g.arena);
        const iw = &init_w.writer;
        var deinit_w: Writer.Allocating = .init(g.arena);
        const dw = &deinit_w.writer;
        var extra_fields: Writer.Allocating = .init(g.arena);
        const fw = &extra_fields.writer;

        // Animations first: bindings and assignments depend on them.
        for (c.elements.items) |el| for (el.ast.members) |*m| switch (m.*) {
            .animate => |*a| {
                if (el.isDynamic()) continue;
                const code = g.animationCode(c, el, a, &fields) catch continue;
                for (a.properties) |p| try el.animations.append(g.arena, .{ .prop = p.name, .code = code });
            },
            .states => |st| for (st.states) |state| for (state.animations) |*a| {
                const code = g.animationCode(c, el, a, &fields) catch continue;
                for (a.properties) |p| try el.animations.append(g.arena, .{ .prop = p.name, .code = code });
            },
            else => {},
        };
        // States: collect, per property, the conditions and values.
        for (c.elements.items) |el| for (el.ast.members) |*m| if (m.* == .states) {
            g.collectStates(c, el, &m.states, &fields) catch |err| switch (err) {
                error.CompileError => {},
                else => return err,
            };
        };

        // In-place initialization of the window, sub-components and
        // repeaters/conditionals.
        if (c.is_window) {
            const size = try g.windowSize(c, &fields);
            try line(iw, 2, "self.root.init(gpa, .{{ .width = {s}, .height = {s} }});", .{ size[0], size[1] });
        }
        for (c.elements.items) |el| switch (el.kind) {
            .component => |sub| {
                try line(iw, 2, "try self.{s}.init(gpa);", .{el.field});
                if (el == c.root and c.inheritsWindow())
                    try line(iw, 2, "self.title = {s}self.{s}.title;", .{ if (sub.is_window) "&" else "", el.field });
            },
            .repeater, .conditional => try line(iw, 2, "try self.{s}.init(gpa, self);", .{el.field}),
            .builtin => |b| if (b.init_call) |init_call| try line(iw, 2, "self.{s}.{s};", .{ el.field, init_call }),
        };
        // Constraint hookups go after in-place initialization, which resets
        // the elements. (Constraint use is known once members are compiled,
        // so the lines are written into a placeholder filled in below.)
        const constraints_marker = "        //@constraints\n";
        iw.writeAll(constraints_marker) catch return error.OutOfMemory;

        // Element tree.
        for (c.elements.items) |el| {
            const parent = el.parent orelse continue;
            // Not drawn: out of the tree, unless in a group of its kind
            // (animations in a SequentialAnimation).
            if (!inTree(el) and inTree(parent)) continue;
            if (inTree(el) and !inTree(parent)) {
                g.diags.add(el.ast.type_name.span, "only animations go in a {s}", .{elementTypeName(parent)}) catch {};
                continue;
            }
            try line(iw, 2, "{s}.appendChild({s});", .{ try g.containerAccess(c, parent), try g.itemPtr(c, el) });
        }
        // Components with `@children` already laid out their own children.
        for (c.elements.items) |el| {
            if (el.kind != .component or el.kind.component.children_target == null or el.children.items.len == 0) continue;
            try line(iw, 2, "{s}.notifyChildrenChanged();", .{try g.containerAccess(c, el)});
        }

        // Properties: declared initializers and aliases, then element members.
        for (c.props.items) |*p| {
            if (p.decl.init) |init_expr| {
                const ref: PropRef = .{ .path = p.zig, .ty = p.ty, .anim = c.root.animation(p.name) };
                g.emitBinding(iw, c, c.root, ref, init_expr, &fields, null) catch {};
            }
            if (p.decl.alias) |target| g.emitAliasTo(iw, c, c.root, p.zig, p.ty, target, &fields) catch {};
        }
        if (c.keepsSettings()) for (c.props.items) |p| if (p.ty.keptBySettings())
            try line(iw, 2, "try self.settingsElement().add({s}, \"{s}\", &self.{s});", .{ p.ty.zig(), p.name, p.zig });
        for (c.elements.items) |el| {
            if (el.isDynamic()) {
                g.emitDynamic(iw, dw, fw, c, el, &fields) catch |err| switch (err) {
                    error.CompileError => {},
                    else => return err,
                };
            } else try g.emitMembers(iw, c, el, &fields);
        }

        try g.emitStates(iw, fw, c, &fields);
        try g.emitChanged(iw, dw, fw, c, &fields);
        for (c.elements.items) |el| if (el.machine != null) g.emitMachine(iw, c, el, &fields) catch |err| switch (err) {
            error.CompileError => {},
            else => return err,
        };
        for (c.functions.items) |*f| g.emitFunction(c, f, &fields) catch |err| switch (err) {
            error.CompileError => {},
            else => return err,
        };

        // A Flickable's viewport defaults to the size of its content.
        for (c.elements.items) |el| {
            if (el.kind != .builtin or !std.mem.eql(u8, el.kind.builtin.name, "Flickable")) continue;
            if (!hasBinding(el, "viewport-width")) {
                const name = try g.newFn(&fields, "b");
                try g.appendFmt(&fields.functions, "    fn {s}(self: *Self) f32 {{\n        return self.{s}.fittedViewportWidth();\n    }}\n\n", .{ name, el.field });
                try line(iw, 2, "try self.{s}.viewport.item.width.setBinding(gpa, self, {s});", .{ el.field, name });
            }
            if (!hasBinding(el, "viewport-height")) {
                const name = try g.newFn(&fields, "b");
                try g.appendFmt(&fields.functions, "    fn {s}(self: *Self) f32 {{\n        return self.{s}.fittedViewportHeight();\n    }}\n\n", .{ name, el.field });
                try line(iw, 2, "try self.{s}.viewport.item.height.setBinding(gpa, self, {s});", .{ el.field, name });
            }
        }

        // Default geometry: elements outside layouts fill their parent.
        for (c.elements.items) |el| {
            if (el.isDynamic() or el.inLayout() or !inTree(el)) continue;
            if (el == c.root and c.template == .none) continue; // positioned by whoever uses the component
            var sets = el.sets;
            if (el.kind == .component) sets = sets.merge(el.kind.component.rootGeometry());
            if (!sets.any()) {
                try line(iw, 2, "try {s}.fillParent(gpa);", .{try g.itemAccess(c, el)});
                continue;
            }
            inline for (.{ "width", "height" }) |dim| if (!@field(sets, dim)) {
                const name = try g.newFn(&fields, "b");
                const item = try g.itemAccess(c, el);
                try g.appendFmt(&fields.functions, "    fn {s}(self: *Self) f32 {{\n        const parent = {s}.parent orelse return 0;\n        return parent.{s}.get();\n    }}\n\n", .{ name, item, dim });
                try line(iw, 2, "try {s}.{s}.setBinding(gpa, self, {s});", .{ item, dim, name });
            };
        }

        // Layouts, children first.
        var i = c.elements.items.len;
        while (i > 0) {
            i -= 1;
            const el = c.elements.items[i];
            if (isGrid(el)) {
                try line(iw, 2, "{s}", .{try g.gridSetup(c, el, &fields)});
            } else if (el.kind == .builtin and el.kind.builtin.layout) try line(iw, 2, "try self.{s}.setup(gpa);", .{el.field});
        }

        // ---- Assemble the struct ----
        const W = struct {
            fn p(o: *Writer, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
                o.print(fmt, args) catch return error.OutOfMemory;
            }
        };
        // Globals are initialized before anything that may use them.
        // Components count as their users, and release them (in reverse
        // order) when destroyed; globals only initialize each other.
        var ensure: std.ArrayList(u8) = .empty;
        var release: std.ArrayList(u8) = .empty;
        for (g.comps.values()) |gc| if (gc.is_global and gc != c) {
            const id = std.zig.fmtId(gc.zig);
            if (c.is_global) {
                try g.appendFmt(&ensure, "        try {f}.ensureInit(backing);\n", .{id});
            } else {
                try g.appendFmt(&ensure, "        try {f}.acquire(gpa);\n", .{id});
                try release.insertSlice(g.arena, 0, try g.print("        {f}.release();\n", .{id}));
            }
        };
        if (c.is_global) {
            try g.assembleGlobal(out, c, &fields, ensure.items, try std.mem.concat(g.arena, u8, &.{ init_w.written(), fields.connects.items }), extra_fields.written());
            return;
        }
        const pub_kw = if (c.template == .none) "pub " else "";
        try W.p(out, "\n{s}const {f} = struct {{\n    const Self = @This();\n", .{ pub_kw, std.zig.fmtId(c.zig) });
        if (c.outer) |o| try W.p(out, "    pub const Context = *{f};\n", .{std.zig.fmtId(o.zig)});
        try W.p(out, "\n    _gpa: std.mem.Allocator,\n", .{});
        if (c.outer) |o| try W.p(out, "    _parent: *{f},\n", .{std.zig.fmtId(o.zig)});
        switch (c.template) {
            .repeated => |r| try W.p(out, "    _index: zigulee.Property(i32) = .init(0),\n    _data: zigulee.Property({s}) = .init({s}),\n", .{ r.data_ty.zig(), defaultValue(r.data_ty) }),
            else => {},
        }
        for (c.props.items) |p| try W.p(out, "    {s}: zigulee.Property({s}) = .init({s}),\n", .{ p.zig, p.ty.zig(), defaultValue(p.ty) });
        for (c.callbacks.items) |cb| {
            var params: std.ArrayList(u8) = .empty;
            for (cb.params, 0..) |t, k| {
                if (k > 0) try params.appendSlice(g.arena, ", ");
                try params.appendSlice(g.arena, t.zig());
            }
            try W.p(out, "    {s}: zigulee.Callback(fn ({s}) {s}) = .{{}},\n", .{ cb.zig, params.items, cb.ret.zig() });
        }
        if (c.is_window) try W.p(out, "    title: zigulee.Property([]const u8) = .init(\"\"),\n", .{});
        // The title of the window it inherits.
        if (c.inheritsWindow()) try W.p(out, "    title: *zigulee.Property([]const u8) = undefined,\n", .{});
        for (c.elements.items) |el| switch (el.kind) {
            .builtin => |b| try W.p(out, "    {s}: {s} = {s},\n", .{ el.field, b.zig_type, if (b.init_call != null) "undefined" else b.init }),
            .component => |sub| try W.p(out, "    {s}: {f} = undefined,\n", .{ el.field, std.zig.fmtId(sub.zig) }),
            .repeater => |t| try W.p(out, "    {s}: zigulee.core.Repeater({s}, {f}) = undefined,\n", .{ el.field, t.template.repeated.data_ty.zig(), std.zig.fmtId(t.zig) }),
            .conditional => |t| try W.p(out, "    {s}: zigulee.core.Conditional({f}) = undefined,\n", .{ el.field, std.zig.fmtId(t.zig) }),
        };
        try W.p(out, "{s}{s}", .{ extra_fields.written(), fields.expr_fields.items });
        const own_root_constraints = c.root.kind == .builtin and !c.is_window;
        for (c.elements.items) |el| if (el.kind == .builtin and (el.constraints or (el == c.root and own_root_constraints)))
            try W.p(out, "    _c_{s}: zigulee.core.LayoutConstraints = .{{}},\n", .{el.field});
        for (c.elements.items) |el| if (el.kind == .builtin and el.accessible)
            try W.p(out, "    _a_{s}: zigulee.core.AccessibleProperties = .{{}},\n", .{el.field});
        for (c.elements.items) |el| if (el.kind == .builtin and el.transform)
            try W.p(out, "    _t_{s}: zigulee.core.ItemTransform = .{{}},\n", .{el.field});
        for (c.elements.items) |el| if (el.kind == .builtin and el.shadow)
            try W.p(out, "    _d_{s}: zigulee.items.DropShadow = .{{}},\n", .{el.field});
        for (0..fields.string_buffers) |k| try W.p(out, "    _s{d}: zigulee.core.StringBuffer = .{{}},\n", .{k});
        if (fields.statics.items.len > 0) try W.p(out, "\n{s}", .{fields.statics.items});

        // Constructors.
        switch (c.template) {
            .none => try W.p(out,
                \\
                \\    pub fn create(gpa: std.mem.Allocator) std.mem.Allocator.Error!*Self {{
                \\        const self = try gpa.create(Self);
                \\        errdefer gpa.destroy(self);
                \\        try self.init(gpa);
                \\        return self;
                \\    }}
                \\
                \\    /// Initializes in place; the instance must not move afterwards.
                \\    pub fn init(self: *Self, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {{
                \\        self.* = .{{ ._gpa = gpa }};
                \\
            , .{}),
            .repeated => |r| try W.p(out,
                \\
                \\    pub fn create(gpa: std.mem.Allocator, parent: Context, index: usize, data: {s}) std.mem.Allocator.Error!*Self {{
                \\        const self = try gpa.create(Self);
                \\        errdefer gpa.destroy(self);
                \\        self.* = .{{ ._gpa = gpa, ._parent = parent, ._index = .init(@intCast(index)), ._data = .init(data) }};
                \\        try self.init(gpa);
                \\        return self;
                \\    }}
                \\
                \\    pub fn update(self: *Self, index: usize, data: {s}) void {{
                \\        self._index.set(@intCast(index));
                \\        self._data.set(data);
                \\    }}
                \\
                \\    fn init(self: *Self, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {{
                \\
            , .{ r.data_ty.zig(), r.data_ty.zig() }),
            .conditional => try W.p(out,
                \\
                \\    pub fn create(gpa: std.mem.Allocator, parent: Context) std.mem.Allocator.Error!*Self {{
                \\        const self = try gpa.create(Self);
                \\        errdefer gpa.destroy(self);
                \\        self.* = .{{ ._gpa = gpa, ._parent = parent }};
                \\        try self.init(gpa);
                \\        return self;
                \\    }}
                \\
                \\    fn init(self: *Self, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {{
                \\
            , .{}),
        }
        var hookups: std.ArrayList(u8) = .empty;
        for (c.elements.items) |el| if (el.kind == .builtin and (el.constraints or (el == c.root and own_root_constraints)))
            try g.appendFmt(&hookups, "        {s}.constraints = &self._c_{s};\n", .{ try g.itemAccess(c, el), el.field });
        for (c.elements.items) |el| if (el.kind == .builtin and el.accessible)
            try g.appendFmt(&hookups, "        {s}.accessible = &self._a_{s};\n", .{ try g.itemAccess(c, el), el.field });
        for (c.elements.items) |el| if (el.kind == .builtin and el.transform)
            try g.appendFmt(&hookups, "        {s}.transform = &self._t_{s};\n", .{ try g.itemAccess(c, el), el.field });
        for (c.elements.items) |el| if (el.kind == .builtin and el.shadow)
            try g.appendFmt(&hookups, "        self.{s}{s}.shadow = &self._d_{s};\n", .{ (try g.locFrom(c, el)).prefix, (try g.locFrom(c, el)).field, el.field });
        const init_code = try std.mem.concat(g.arena, u8, &.{ ensure.items, try std.mem.replaceOwned(u8, g.arena, init_w.written(), constraints_marker, hookups.items), fields.connects.items });
        // Templates' init has no `self.* = .{ ._gpa = gpa }` line.
        if (c.template != .none and !usesIdent(init_code, "gpa")) try W.p(out, "        _ = gpa;\n", .{});
        try W.p(out, "{s}    }}\n\n", .{init_code});

        try W.p(out,
            \\    pub fn destroy(self: *Self) void {{
            \\        const gpa = self._gpa;
            \\        self.deinit();
            \\        gpa.destroy(self);
            \\    }}
            \\
            \\
        , .{});

        // deinit: window, then elements children-first, then the rest.
        try W.p(out, "    {s}fn deinit(self: *Self) void {{\n{s}", .{ if (c.template == .none) "pub " else "", fields.disconnects.items });
        if (c.is_window) try W.p(out, "        self.root.deinit();\n", .{});
        try W.p(out, "{s}{s}", .{ deinit_w.written(), fields.expr_deinit.items });
        i = c.elements.items.len;
        while (i > 0) {
            i -= 1;
            const el = c.elements.items[i];
            if (el == c.root and c.is_window) continue;
            if (el.isDynamic()) continue; // in deinit_w, before the elements
            try W.p(out, "        self.{s}.deinit();\n", .{el.field});
        }
        for (c.elements.items) |el| if (el.kind == .builtin and (el.constraints or (el == c.root and own_root_constraints)))
            try W.p(out, "        self._c_{s}.deinit();\n", .{el.field});
        for (c.elements.items) |el| if (el.kind == .builtin and el.accessible)
            try W.p(out, "        self._a_{s}.deinit();\n", .{el.field});
        for (c.elements.items) |el| if (el.kind == .builtin and el.transform)
            try W.p(out, "        self._t_{s}.deinit();\n", .{el.field});
        for (c.elements.items) |el| if (el.kind == .builtin and el.shadow)
            try W.p(out, "        self._d_{s}.deinit();\n", .{el.field});
        for (0..fields.string_buffers) |k| try W.p(out, "        self._s{d}.deinit(self._gpa);\n", .{k});
        for (c.props.items) |p| try W.p(out, "        self.{s}.deinit();\n", .{p.zig});
        if (c.is_window) try W.p(out, "        self.title.deinit();\n", .{});
        if (c.template == .repeated) try W.p(out, "        self._index.deinit();\n        self._data.deinit();\n", .{});
        try W.p(out, "{s}    }}\n\n", .{release.items});

        try W.p(out, "    pub fn rootItem(self: *Self) *zigulee.Item {{\n        return {s};\n    }}\n\n", .{try g.itemPtr(c, c.root)});
        if (c.children_target) |t| {
            // A built-in element's container is a field (take its address);
            // a component's (its root item or its own `@children`) is
            // already a pointer.
            const amp = if (t.kind == .builtin) "&" else "";
            try W.p(out, "    /// Where children of the component's uses go (`@children`).\n    pub fn childrenContainer(self: *Self) *zigulee.Item {{\n        return {s}{s};\n    }}\n\n", .{ amp, try g.containerAccess(c, t) });
        }
        if (c.is_window) try W.p(out, "    pub fn window(self: *Self) *zigulee.Window {{\n        return &self.root;\n    }}\n\n", .{});
        if (c.inheritsWindow()) try W.p(out, "    pub fn window(self: *Self) *zigulee.Window {{\n        return self.{s}.window();\n    }}\n\n", .{c.root.field});
        if (c.keepsSettings()) try W.p(out, "    pub fn settingsElement(self: *Self) *zigulee.items.Settings {{\n        return {s}self.{s}{s};\n    }}\n\n", .{
            if (c.root.kind == .builtin) "&" else "",
            c.root.field,
            if (c.root.kind == .builtin) "" else ".settingsElement()",
        });
        if (c.template == .none and !c.showsWindow() and !c.is_global) try g.emitFactory(out, c);
        try W.p(out, "{s}{s}}};\n", .{ try g.globalAccessors(c), fields.functions.items });
    }

    fn printTo(o: *Writer, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        o.print(fmt, args) catch return error.OutOfMemory;
    }

    /// The component as a value (`Loader { source: Foo; }`): made, shown
    /// and given inputs (its `in` and `in-out` properties) by name.
    fn emitFactory(g: *Generator, out: *Writer, c: *const Comp) Error!void {
        try printTo(out,
            \\    pub const factory: zigulee.core.ComponentFactory = .{{ .name = "{s}", .create = _factoryCreate, .destroy = _factoryDestroy, .root = _factoryRoot, .set_input = _factorySetInput }};
            \\    fn _factoryCreate(_: ?*anyopaque, gpa: std.mem.Allocator) std.mem.Allocator.Error!*anyopaque {{
            \\        return try Self.create(gpa);
            \\    }}
            \\    fn _factoryDestroy(_: ?*anyopaque, p: *anyopaque) void {{
            \\        @as(*Self, @ptrCast(@alignCast(p))).destroy();
            \\    }}
            \\    fn _factoryRoot(_: ?*anyopaque, p: *anyopaque) *zigulee.Item {{
            \\        return @as(*Self, @ptrCast(@alignCast(p))).rootItem();
            \\    }}
            \\
        , .{c.name});
        var inputs: std.ArrayList(u8) = .empty;
        for (c.props.items) |p| {
            if (p.visibility != .in and p.visibility != .in_out) continue;
            try g.appendFmt(&inputs, "        if (std.mem.eql(u8, name, \"{s}\") and std.mem.eql(u8, ty, \"{s}\")) {{\n            self.{s}.set(@as(*const {s}, @ptrCast(@alignCast(value))).*);\n            return true;\n        }}\n", .{ p.name, p.ty.name(), p.zig, p.ty.zig() });
        }
        if (inputs.items.len == 0) {
            try printTo(out, "    fn _factorySetInput(_: ?*anyopaque, _: *anyopaque, _: []const u8, _: []const u8, _: *const anyopaque) bool {{\n        return false;\n    }}\n\n", .{});
        } else {
            try printTo(out, "    fn _factorySetInput(_: ?*anyopaque, p: *anyopaque, name: []const u8, ty: []const u8, value: *const anyopaque) bool {{\n        const self: *Self = @ptrCast(@alignCast(p));\n{s}        return false;\n    }}\n\n", .{inputs.items});
        }
    }

    /// `fn _g_Theme(_: *const Self) *Theme`: how code reaches each global.
    fn globalAccessors(g: *Generator, c: *const Comp) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (g.comps.values()) |gc| if (gc.is_global and gc != c) {
            const id = try g.print("{f}", .{std.zig.fmtId(gc.zig)});
            try g.appendFmt(&out, "    fn _g_{s}(_: *const Self) *{s} {{\n        return &{s}.instance;\n    }}\n\n", .{ try zigName(g.arena, gc.zig), id, id });
        };
        return out.items;
    }

    /// A global: one static instance whose bindings `ensureInit` installs
    /// (once, with memory that lives as long as the program: an arena over
    /// the allocator of the first component created).
    fn assembleGlobal(g: *Generator, out: *Writer, c: *Comp, fields: *Fields, ensure: []const u8, init_code_raw: []const u8, extra: []const u8) Error!void {
        const W = struct {
            fn p(o: *Writer, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
                o.print(fmt, args) catch return error.OutOfMemory;
            }
        };
        const init_code = try std.mem.replaceOwned(u8, g.arena, init_code_raw, "        //@constraints\n", "");
        try W.p(out,
            \\
            \\pub const {f} = struct {{
            \\    const Self = @This();
            \\
            \\    /// The shared instance. Components `acquire` it when created and
            \\    /// `release` it when destroyed: it exists while any component does.
            \\    pub var instance: Self = .{{}};
            \\    var users: usize = 0;
            \\    var initialized = false;
            \\    var arena: std.heap.ArenaAllocator = undefined;
            \\
            \\    _gpa: std.mem.Allocator = undefined,
            \\
        , .{std.zig.fmtId(c.zig)});
        for (c.props.items) |p| try W.p(out, "    {s}: zigulee.Property({s}) = .init({s}),\n", .{ p.zig, p.ty.zig(), defaultValue(p.ty) });
        for (c.callbacks.items) |cb| {
            var params: std.ArrayList(u8) = .empty;
            for (cb.params, 0..) |t, k| {
                if (k > 0) try params.appendSlice(g.arena, ", ");
                try params.appendSlice(g.arena, t.zig());
            }
            try W.p(out, "    {s}: zigulee.Callback(fn ({s}) {s}) = .{{}},\n", .{ cb.zig, params.items, cb.ret.zig() });
        }
        for (c.elements.items) |el| if (el.machine != null) try W.p(out, "    {s}: zigulee.core.statemachine.StateMachine = .{{}},\n", .{el.field});
        try W.p(out, "{s}{s}", .{ extra, fields.expr_fields.items });
        for (0..fields.string_buffers) |k| try W.p(out, "    _s{d}: zigulee.core.StringBuffer = .{{}},\n", .{k});
        if (fields.statics.items.len > 0) try W.p(out, "\n{s}", .{fields.statics.items});
        try W.p(out,
            \\
            \\    /// Called by components when created, with their allocator: the
            \\    /// global's memory comes from the first one's.
            \\    pub fn acquire(backing: std.mem.Allocator) std.mem.Allocator.Error!void {{
            \\        users += 1;
            \\        try ensureInit(backing);
            \\    }}
            \\
            \\    /// Initializes the global if it is not yet (globals using each
            \\    /// other initialize each other).
            \\    pub fn ensureInit(backing: std.mem.Allocator) std.mem.Allocator.Error!void {{
            \\        if (initialized) return;
            \\        initialized = true;
            \\        arena = .init(backing);
            \\        const gpa = arena.allocator();
            \\        const self = &instance;
            \\        self._gpa = gpa;
            \\
        , .{});
        try W.p(out, "{s}{s}    }}\n\n", .{ ensure, init_code });
        // The last user gone: unhook from other globals (deinit unlinks
        // both ways), free everything and start over.
        try W.p(out,
            \\    /// Called by components when destroyed.
            \\    pub fn release() void {{
            \\        users -= 1;
            \\        if (users > 0 or !initialized) return;
            \\        initialized = false;
            \\
        , .{});
        // `self` only when something is freed (a global of callbacks has
        // nothing).
        const machines = for (c.elements.items) |el| {
            if (el.machine != null) break true;
        } else false;
        if (fields.expr_deinit.items.len > 0 or fields.string_buffers > 0 or c.props.items.len > 0 or machines)
            try W.p(out, "        const self = &instance;\n", .{});
        for (c.elements.items) |el| if (el.machine != null) try W.p(out, "        self.{s}.deinit();\n", .{el.field});
        try W.p(out, "{s}", .{fields.expr_deinit.items});
        for (0..fields.string_buffers) |k| try W.p(out, "        self._s{d}.deinit(self._gpa);\n", .{k});
        for (c.props.items) |p| try W.p(out, "        self.{s}.deinit();\n", .{p.zig});
        try W.p(out, "        arena.deinit();\n        instance = .{{}};\n    }}\n\n", .{});
        try W.p(out, "{s}{s}}};\n", .{ try g.globalAccessors(c), fields.functions.items });
    }

    /// Wires a `for` or `if` element: its model or condition, and teardown.
    fn emitDynamic(g: *Generator, iw: *Writer, dw: *Writer, fw: *Writer, c: *Comp, el: *Elem, fields: *Fields) Error!void {
        const W = struct {
            fn p(o: *Writer, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
                o.print(fmt, args) catch return error.OutOfMemory;
            }
        };
        const parent = el.parent.?;
        var ctx = try g.context(c, parent, fields);
        switch (el.kind) {
            .repeater => |t| {
                const r = &t.template.repeated;
                const model = try g.compileValue(&ctx, r.node.model, null);
                const n = fields.next_fn;
                if (model.ty == .int) {
                    // `for i in n`: a CountModel resized as n changes.
                    r.data_ty = .int;
                    try W.p(fw, "    {s}_count: zigulee.core.CountModel = .{{}},\n    {s}_track: zigulee.ChangeTracker(i32) = undefined,\n", .{ el.field, el.field });
                    const eval = try g.newFn(fields, "b");
                    const handler = try g.newFn(fields, "h");
                    try g.appendFmt(&fields.functions, "    fn {s}(self: *Self) i32 {{\n{s}        return {s};\n    }}\n\n", .{ eval, if (usesIdent(model.code, "self")) "" else "        _ = self;\n", model.code });
                    try g.appendFmt(&fields.functions, "    fn {s}(self: *Self, n: i32) void {{\n        self.{s}_count.setCount(@intCast(@max(n, 0)));\n    }}\n\n", .{ handler, el.field });
                    try line(iw, 2, "self.{s}_track.init(gpa, self, {s}, {s});", .{ el.field, eval, handler });
                    try line(iw, 2, "self.{s}_count.setCount(@intCast(@max(self.{s}_track.value, 0)));", .{ el.field, el.field });
                    try line(iw, 2, "try self.{s}.setModel(self.{s}_count.model());", .{ el.field, el.field });
                    try W.p(dw, "        self.{s}_track.deinit();\n        self.{s}.deinit();\n        self.{s}_count.deinit();\n", .{ el.field, el.field, el.field });
                } else if (model.ty == .model) {
                    r.data_ty = model.ty.model.*;
                    try W.p(fw, "    {s}_track: zigulee.ChangeTracker({s}) = undefined,\n", .{ el.field, model.ty.zig() });
                    const eval = try g.newFn(fields, "b");
                    const handler = try g.newFn(fields, "h");
                    try g.appendFmt(&fields.functions, "    fn {s}(self: *Self) {s} {{\n{s}        return {s};\n    }}\n\n", .{ eval, model.ty.zig(), if (usesIdent(model.code, "self")) "" else "        _ = self;\n", model.code });
                    try g.appendFmt(&fields.functions, "    fn {s}(self: *Self, model: {s}) void {{\n        self.{s}.setModel(model) catch {{}};\n    }}\n\n", .{ handler, model.ty.zig(), el.field });
                    try line(iw, 2, "self.{s}_track.init(gpa, self, {s}, {s});", .{ el.field, eval, handler });
                    try line(iw, 2, "try self.{s}.setModel(self.{s}_track.value);", .{ el.field, el.field });
                    try W.p(dw, "        self.{s}_track.deinit();\n        self.{s}.deinit();\n", .{ el.field, el.field });
                } else {
                    return g.fail(r.node.model.span, "'for' needs a model or an int, found {s}", .{model.ty.name()});
                }
                _ = n;
            },
            .conditional => |t| {
                const cond = try g.compileExpr(&ctx, t.template.conditional.condition, .bool);
                if (cond.constant) {
                    try line(iw, 2, "self.{s}.condition.set({s});", .{ el.field, cond.code });
                } else {
                    const name = try g.newFn(fields, "b");
                    try g.appendFmt(&fields.functions, "    fn {s}(self: *Self) bool {{\n        return {s};\n    }}\n\n", .{ name, cond.code });
                    try line(iw, 2, "try self.{s}.condition.setBinding(gpa, self, {s});", .{ el.field, name });
                }
                try line(iw, 2, "try self.{s}.sync();", .{el.field});
                try W.p(dw, "        self.{s}.deinit();\n", .{el.field});
            },
            else => unreachable,
        }
    }

    fn appendFmt(g: *Generator, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try list.appendSlice(g.arena, try g.print(fmt, args));
    }

    fn newFn(g: *Generator, fields: *Fields, prefix: []const u8) Allocator.Error![]const u8 {
        const n = fields.next_fn;
        fields.next_fn += 1;
        return g.print("_{s}{d}", .{ prefix, n });
    }

    fn defaultValue(t: Type) []const u8 {
        return switch (t) {
            .int, .float, .length, .duration => "0",
            .bool => "false",
            .string => "\"\"",
            .color => "zigulee.Color.transparent",
            .brush => "zigulee.Brush.transparent",
            .image => "zigulee.core.Image{ .width = 0, .height = 0, .pixels = &.{} }",
            .audio => "zigulee.core.Audio.empty",
            .video => "zigulee.core.Video.none",
            .model3d => "zigulee.core.Model3D.none",
            .component => "null",
            .enumeration => "@enumFromInt(0)",
            .structure => |s| s.default_value,
            .model => Type.emptyModelZig(t),
            else => "undefined",
        };
    }

    /// The window's initial size from its constant `width` and `height`.
    fn windowSize(g: *Generator, c: *Comp, fields: *Fields) Error![2][]const u8 {
        var size = [2][]const u8{ "640", "480" };
        for (c.ast.root.members) |*m| if (m.* == .binding) {
            const b = m.binding;
            const index: usize = if (std.mem.eql(u8, b.name.name, "width")) 0 else if (std.mem.eql(u8, b.name.name, "height")) 1 else continue;
            var ctx = try g.context(c, c.root, fields);
            const v = g.compileExpr(&ctx, b.value, .length) catch continue;
            if (!v.constant) {
                try g.diags.add(b.value.span, "the window size must be a constant for now", .{});
                continue;
            }
            size[index] = v.code;
        };
        return size;
    }

    fn animationCode(g: *Generator, c: *Comp, el: *Elem, a: *const ast.Animate, fields: *Fields) Error![]const u8 {
        const code = try g.animationSettings(c, el, a, fields);
        for (a.properties) |p| {
            const member = try g.memberFrom(c, el, p.name, p.span) orelse
                return g.fail(p.span, "'{s}' has no property '{s}'", .{ elementTypeName(el), p.name });
            if (member != .property) return g.fail(p.span, "'{s}' is not a property", .{p.name});
        }
        return code;
    }

    /// `zigulee.Animation{ ... }` from an `animate` block's settings.
    fn animationSettings(g: *Generator, c: *Comp, el: *Elem, a: *const ast.Animate, fields: *Fields) Error![]const u8 {
        var ctx = try g.context(c, el, fields);
        var code: std.ArrayList(u8) = .empty;
        try code.appendSlice(g.arena, "zigulee.Animation{");
        for (a.settings) |s| {
            const n = s.name.name;
            const v, const field = if (std.mem.eql(u8, n, "duration"))
                .{ try g.compileExpr(&ctx, s.value, .duration), "duration_ms" }
            else if (std.mem.eql(u8, n, "delay"))
                .{ try g.compileExpr(&ctx, s.value, .duration), "delay_ms" }
            else if (std.mem.eql(u8, n, "easing"))
                .{ try g.compileExpr(&ctx, s.value, .easing), "easing" }
            else if (std.mem.eql(u8, n, "iteration-count"))
                .{ try g.compileExpr(&ctx, s.value, .int), "iterations" }
            else
                return g.fail(s.name.span, "unknown animation setting '{s}' (expected duration, delay, easing or iteration-count)", .{n});
            if (!v.constant) return g.fail(s.value.span, "animation settings must be constants", .{});
            const value = if (std.mem.eql(u8, field, "iterations"))
                try g.print("if ({s} < 0) null else @intCast({s})", .{ v.code, v.code })
            else if (std.mem.endsWith(u8, field, "_ms"))
                try g.print("@intCast({s})", .{v.code})
            else
                v.code;
            try code.appendSlice(g.arena, try g.print(" .{s} = {s},", .{ field, value }));
        }
        try code.appendSlice(g.arena, " }");
        return code.items;
    }

    fn emitMembers(g: *Generator, iw: *Writer, c: *Comp, el: *Elem, fields: *Fields) Error!void {
        // A Loader's bindings of no property of its own are its instance's
        // inputs.
        var inputs: std.ArrayList(ast.Binding) = .empty;
        const loader = el.kind == .builtin and std.mem.eql(u8, el.kind.builtin.name, "Loader");
        const connections = isConnections(el);
        const property_animation = el.kind == .builtin and std.mem.eql(u8, el.kind.builtin.name, "PropertyAnimation");
        if (property_animation) g.emitAnimationTarget(iw, c, el, fields) catch |err| switch (err) {
            error.CompileError => {},
            else => return err,
        };
        for (el.ast.members) |*m| {
            // Resolved with each handler.
            if (connections and m.* == .binding and std.mem.eql(u8, m.binding.name.name, "target")) continue;
            if (property_animation and m.* == .binding and isAnimationEnd(m.binding.name.name)) continue;
            if (m.* == .binding and std.mem.eql(u8, m.binding.name.name, "mask-source")) {
                g.emitMaskSource(iw, c, el, m.binding, fields) catch |err| switch (err) {
                    error.CompileError => {},
                    else => return err,
                };
                continue;
            }
            if (loader and m.* == .binding and (try g.memberFrom(c, el, m.binding.name.name, null)) == null) {
                try inputs.append(g.arena, m.binding);
                continue;
            }
            const result = switch (m.*) {
                .binding => |b| g.emitElementBinding(iw, c, el, b, fields),
                .two_way => |t| g.emitTwoWay(iw, c, el, t, fields),
                .handler => |*h| g.emitHandler(iw, c, el, h, fields),
                else => {},
            };
            result catch |err| switch (err) {
                error.CompileError => {},
                else => return err,
            };
        }
        if (inputs.items.len > 0) g.emitLoaderInputs(iw, c, el, inputs.items, fields) catch |err| switch (err) {
            error.CompileError => {},
            else => return err,
        };
    }

    /// `in`/`out` animations of a state, by property name.
    fn transitionCodes(g: *Generator, c: *Comp, el: *Elem, list: []const ast.Animate, fields: *Fields) Error!std.StringHashMapUnmanaged([]const u8) {
        var map: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (list) |*a| {
            const code = try g.animationSettings(c, el, a, fields);
            for (a.properties) |p| try map.put(g.arena, p.name, code);
        }
        return map;
    }

    fn collectStates(g: *Generator, c: *Comp, el: *Elem, st: *const ast.States, fields: *Fields) Error!void {
        for (st.states) |state| {
            var ctx = try g.context(c, el, fields);
            const cond = try g.compileExpr(&ctx, state.condition, .bool);
            const enter = try g.transitionCodes(c, el, state.enter, fields);
            const leave = try g.transitionCodes(c, el, state.leave, fields);
            for (state.assignments) |a| {
                // The target: `prop` on this element, or `id.prop`.
                var target_el = el;
                var name: []const u8 = undefined;
                var name_span = a.target.span;
                switch (a.target.kind) {
                    .ident => |n| name = n,
                    .member => |mb| {
                        const obj = try g.compileRef(&ctx, mb.object);
                        if (obj != .element) return g.fail(mb.object.span, "expected an element id", .{});
                        target_el = obj.element;
                        name = mb.name.name;
                        name_span = mb.name.span;
                    },
                    else => return g.fail(a.target.span, "expected a property name", .{}),
                }
                const member = try g.memberFrom(c, target_el, name, name_span) orelse
                    return g.fail(a.target.span, "'{s}' has no property '{s}'", .{ elementTypeName(target_el), name });
                if (member != .property) return g.fail(a.target.span, "'{s}' is not a property", .{name});
                const ref = member.property;
                if (ref.read_only or ref.constraint) return g.fail(a.target.span, "'{s}' cannot be set by a state", .{name});
                const value = try g.compileExpr(&ctx, a.value, ref.ty);
                const gop = try fields.state_props.getOrPut(g.arena, ref.path);
                if (!gop.found_existing) gop.value_ptr.* = .{ .ref = ref, .elem = target_el, .name = name };
                try gop.value_ptr.branches.append(g.arena, .{ .cond = cond.code, .value = value.code, .enter = enter.get(name), .leave = leave.get(name) });
            }
        }
    }

    /// One binding per state-driven property: the first active state's
    /// value, else the property's own binding, else its initial value.
    fn emitStates(g: *Generator, iw: *Writer, fw: *Writer, c: *Comp, fields: *Fields) Error!void {
        var it = fields.state_props.iterator();
        var n: usize = 0;
        while (it.next()) |entry| : (n += 1) {
            const sp = entry.value_ptr;
            var p = sp.ref;
            if (sp.elem.animation(sp.name)) |a| p.anim = a;
            const zig_ty = if (p.optional) try g.print("?{s}", .{p.ty.zig()}) else p.ty.zig();
            // The fallback.
            var base: []const u8 = undefined;
            const own = for (sp.elem.ast.members) |m| {
                if (m == .binding and std.mem.eql(u8, m.binding.name.name, sp.name)) break m.binding.value;
            } else null;
            if (own) |expr| {
                var ctx = try g.context(c, sp.elem, fields);
                base = (try g.compileExpr(&ctx, expr, p.ty)).code;
            } else {
                fw.print("    _state_base{d}: {s} = undefined,\n", .{ n, zig_ty }) catch return error.OutOfMemory;
                try line(iw, 2, "self._state_base{d} = self.{s}.get();", .{ n, firstPath(p.path) });
                base = try g.print("self._state_base{d}", .{n});
            }
            var code: std.ArrayList(u8) = .empty;
            var has_transitions = false;
            for (sp.branches.items) |b| {
                const value = if (p.optional) try g.print("@as({s}, {s})", .{ zig_ty, b.value }) else b.value;
                try code.appendSlice(g.arena, try g.print("if ({s}) {s} else ", .{ b.cond, value }));
                if (b.enter != null or b.leave != null) has_transitions = true;
            }
            try code.appendSlice(g.arena, base);
            const name = try g.newFn(fields, "b");
            try g.appendFmt(&fields.functions, "    fn {s}(self: *Self) {s} {{\n        return {s};\n    }}\n\n", .{ name, zig_ty, code.items });

            // With `in`/`out` animations, the animation depends on which
            // state is entered or left: remember the previous one.
            var chooser: ?[]const u8 = null;
            if (has_transitions) {
                var current: std.ArrayList(u8) = .empty;
                for (sp.branches.items, 0..) |b, k| try current.appendSlice(g.arena, try g.print("if ({s}) {d} else ", .{ b.cond, k }));
                try current.appendSlice(g.arena, "255");
                fw.print("    _state_prev{d}: u8 = 255,\n", .{n}) catch return error.OutOfMemory;
                try line(iw, 2, "self._state_prev{d} = {s};", .{ n, current.items });
                var enter_cases: std.ArrayList(u8) = .empty;
                var leave_cases: std.ArrayList(u8) = .empty;
                for (sp.branches.items, 0..) |b, k| {
                    if (b.enter) |a| try enter_cases.appendSlice(g.arena, try g.print("            {d} => return {s},\n", .{ k, a }));
                    if (b.leave) |a| try leave_cases.appendSlice(g.arena, try g.print("            {d} => return {s},\n", .{ k, a }));
                }
                const choose = try g.newFn(fields, "a");
                try g.appendFmt(&fields.functions,
                    \\    fn {s}(self: *Self) zigulee.Animation {{
                    \\        const current: u8 = {s};
                    \\        const previous = self._state_prev{d};
                    \\        self._state_prev{d} = current;
                    \\        if (current != previous) {{
                    \\            switch (current) {{
                    \\    {s}            else => {{}},
                    \\            }}
                    \\            switch (previous) {{
                    \\    {s}            else => {{}},
                    \\            }}
                    \\        }}
                    \\        return {s};
                    \\    }}
                    \\
                    \\
                , .{ choose, current.items, n, n, enter_cases.items, leave_cases.items, p.anim orelse "zigulee.Animation{}" });
                chooser = choose;
            }

            var paths = std.mem.splitScalar(u8, p.path, ',');
            while (paths.next()) |path| {
                if (chooser) |choose| {
                    try line(iw, 2, "try self.{s}.setAnimatedBindingChoosing(gpa, self, {s}, {s});", .{ path, name, choose });
                } else if (p.anim) |anim| {
                    try line(iw, 2, "try self.{s}.setAnimatedBinding(gpa, self, {s}, {s});", .{ path, name, anim });
                } else {
                    try line(iw, 2, "try self.{s}.setBinding(gpa, self, {s});", .{ path, name });
                }
            }
        }
    }

    /// `changed prop => { ... }`: a change tracker per handler.
    fn emitChanged(g: *Generator, iw: *Writer, dw: *Writer, fw: *Writer, c: *Comp, fields: *Fields) Error!void {
        var n: usize = 0;
        for (c.elements.items) |el| for (el.ast.members) |*m| if (m.* == .changed) {
            const ch = &m.changed;
            const member = (g.memberFrom(c, el, ch.name.name, ch.name.span) catch continue) orelse {
                try g.diags.add(ch.name.span, "'{s}' has no property '{s}'", .{ elementTypeName(el), ch.name.name });
                continue;
            };
            if (member != .property) {
                try g.diags.add(ch.name.span, "'{s}' is not a property", .{ch.name.name});
                continue;
            }
            const p = member.property;
            const value = try g.refToValue(.{ .property = p }, ch.name.span);
            var ctx = try g.context(c, el, fields);
            var body: Writer.Allocating = .init(g.arena);
            try g.compileStmts(&ctx, ch.body, &body.writer, 2);
            const text = body.written();
            const eval = try g.newFn(fields, "b");
            const handler = try g.newFn(fields, "h");
            try g.appendFmt(&fields.functions, "    fn {s}(self: *Self) {s} {{\n        return {s};\n    }}\n\n", .{ eval, p.ty.zig(), value.code });
            try g.appendFmt(&fields.functions, "    fn {s}(self: *Self, _: {s}) void {{\n{s}{s}    }}\n\n", .{ handler, p.ty.zig(), if (usesIdent(text, "self")) "" else "        _ = self;\n", text });
            fw.print("    _changed{d}: zigulee.ChangeTracker({s}) = undefined,\n", .{ n, p.ty.zig() }) catch return error.OutOfMemory;
            try line(iw, 2, "self._changed{d}.init(gpa, self, {s}, {s});", .{ n, eval, handler });
            dw.print("        self._changed{d}.deinit();\n", .{n}) catch return error.OutOfMemory;
            n += 1;
        };
    }

    /// Watches a Loader's inputs (`data: row;`) and passes them to its
    /// instance by name and type: when they change, and to each new
    /// instance.
    fn emitLoaderInputs(g: *Generator, iw: *Writer, c: *Comp, el: *Elem, inputs: []const ast.Binding, fields: *Fields) Error!void {
        var ctx = try g.context(c, el, fields);
        const n = fields.next_static;
        fields.next_static += 1;
        var decl: std.ArrayList(u8) = .empty;
        var values: std.ArrayList(u8) = .empty;
        var pushes: std.ArrayList(u8) = .empty;
        const loc = try g.locFrom(c, el);
        for (inputs, 0..) |b, k| {
            const v = try g.compileExpr(&ctx, b.value, null);
            if (v.ty == .void) return g.fail(b.value.span, "'{s}' needs a value; this has none", .{b.name.name});
            try g.appendFmt(&decl, " f{d}: {s},", .{ k, v.ty.zig() });
            try g.appendFmt(&values, " .f{d} = {s},", .{ k, v.code });
            try g.appendFmt(&pushes, "        self.{s}{s}.setInput(\"{s}\", \"{s}\", @ptrCast(&v.f{d}));\n", .{ loc.prefix, loc.field, b.name.name, v.ty.name(), k });
        }
        try g.appendFmt(&fields.statics, "    const _LoaderInputs{d} = struct {{{s} }};\n", .{ n, decl.items });
        try g.appendFmt(&fields.expr_fields, "    _inputs{d}: zigulee.ChangeTracker(_LoaderInputs{d}) = undefined,\n", .{ n, n });
        try g.appendFmt(&fields.expr_deinit, "        self._inputs{d}.deinit();\n", .{n});
        try g.appendFmt(&fields.functions, "    fn _inputs{d}Eval(self: *Self) _LoaderInputs{d} {{\n{s}        return .{{{s} }};\n    }}\n\n", .{ n, n, if (usesIdent(values.items, "self")) "" else "        _ = self;\n", values.items });
        try g.appendFmt(&fields.functions, "    fn _inputs{d}Push(self: *Self, v: _LoaderInputs{d}) void {{\n{s}    }}\n\n", .{ n, n, pushes.items });
        try g.appendFmt(&fields.functions, "    fn _inputs{d}Created(self: *Self) void {{\n        _inputs{d}Push(self, self._inputs{d}.value);\n    }}\n\n", .{ n, n, n });
        try line(iw, 2, "self._inputs{d}.init(gpa, self, _inputs{d}Eval, _inputs{d}Push);", .{ n, n, n });
        try line(iw, 2, "self.{s}{s}.created.setHandler(self, _inputs{d}Created);", .{ loc.prefix, loc.field, n });
        try line(iw, 2, "_inputs{d}Created(self);", .{n});
    }

    fn emitElementBinding(g: *Generator, iw: *Writer, c: *Comp, el: *Elem, b: ast.Binding, fields: *Fields) Error!void {
        const name = b.name.name;
        // Grid placement is resolved when the grid is set up.
        if (el.parent) |p| if (isGrid(p)) for (grid_cell_props) |gp| if (std.mem.eql(u8, gp, name)) return;
        if (el == c.root and c.is_window and (std.mem.eql(u8, name, "width") or std.mem.eql(u8, name, "height"))) return; // initial size
        const member = try g.memberFrom(c, el, name, b.name.span) orelse
            return g.fail(b.name.span, "'{s}' has no property '{s}'", .{ elementTypeName(el), name });
        const p = switch (member) {
            .property => |p| p,
            else => return g.fail(b.name.span, "'{s}' is a callback: use '{s} => {{ ... }}'", .{ name, name }),
        };
        if (p.read_only) return g.fail(b.name.span, "cannot set '{s}': {s}", .{ name, p.read_only_reason });
        // Folded into the state binding.
        if (fields.state_props.contains(p.path)) return;

        const is_size = std.mem.eql(u8, name, "width") or std.mem.eql(u8, name, "height");
        var percent_base: ?[]const u8 = null;
        if (is_size) if (el.visualParent()) |parent| {
            percent_base = try g.print("{s}.{s}.get()", .{ try g.itemAccess(c, parent), name });
        };

        if (el.inLayout() and (std.mem.eql(u8, name, "x") or std.mem.eql(u8, name, "y")))
            return g.fail(b.name.span, "'{s}' is set by the layout", .{name});

        // In a layout (or at a component's root, which may end up in one),
        // a fixed size is a constraint. (At the root of one inheriting a
        // window, it is the window's size.)
        const size_constraint = is_size and (el.inLayout() or (el == c.root and !c.showsWindow()));
        if (size_constraint) {
            const dim = if (std.mem.eql(u8, name, "width")) "width" else "height";
            inline for (.{ "min-", "max-", "preferred-" }) |prefix| {
                const cm = (try g.memberFrom(c, el, try g.print("{s}{s}", .{ prefix, dim }), null)).?;
                try g.emitBinding(iw, c, el, cm.property, b.value, fields, percent_base);
            }
            if (el.inLayout()) return;
        }
        try g.emitBinding(iw, c, el, p, b.value, fields, percent_base);
    }

    /// Sets a constant or installs a binding function.
    fn emitBinding(g: *Generator, iw: *Writer, c: *Comp, el: *Elem, p: PropRef, value: *const ast.Expr, fields: *Fields, percent_base: ?[]const u8) Error!void {
        if (p.owner) |o| o.constraints = true;
        var ctx = try g.context(c, el, fields);
        ctx.percent_base = percent_base;
        const v = try g.compileExpr(&ctx, value, p.ty);
        if (v.constant and p.anim == null) {
            try writeSet(iw, 2, p, v.code);
            return;
        }
        const ret_type = if (p.optional) try g.print("?{s}", .{p.ty.zig()}) else p.ty.zig();
        const name = try g.newFn(fields, "b");
        try g.appendFmt(&fields.functions, "    fn {s}(self: *Self) {s} {{\n", .{ name, ret_type });
        if (!usesIdent(v.code, "self")) try g.appendFmt(&fields.functions, "        _ = self;\n", .{});
        try g.appendFmt(&fields.functions, "        return {s};\n    }}\n\n", .{v.code});
        var it = std.mem.splitScalar(u8, p.path, ',');
        while (it.next()) |path| {
            if (p.anim) |anim| {
                try line(iw, 2, "try self.{s}.setAnimatedBinding(gpa, self, {s}, {s});", .{ path, name, anim });
            } else {
                try line(iw, 2, "try self.{s}.setBinding(gpa, self, {s});", .{ path, name });
            }
        }
    }

    fn emitTwoWay(g: *Generator, iw: *Writer, c: *Comp, el: *Elem, t: ast.TwoWay, fields: *Fields) Error!void {
        const member = try g.memberFrom(c, el, t.name.name, t.name.span) orelse
            return g.fail(t.name.span, "'{s}' has no property '{s}'", .{ elementTypeName(el), t.name.name });
        if (member != .property or member.property.constraint or std.mem.indexOfScalar(u8, member.property.path, ',') != null)
            return g.fail(t.name.span, "'{s}' cannot be linked", .{t.name.name});
        try g.emitAliasTo(iw, c, el, member.property.path, member.property.ty, t.target, fields);
    }

    fn emitAliasTo(g: *Generator, iw: *Writer, c: *Comp, el: *Elem, path: []const u8, ty: Type, target: *const ast.Expr, fields: *Fields) Error!void {
        var ctx = try g.context(c, el, fields);
        const ref = try g.compileRef(&ctx, target);
        const other = switch (ref) {
            .property => |p| p,
            else => return g.fail(target.span, "'<=>' needs a property", .{}),
        };
        if (other.constraint or std.mem.indexOfScalar(u8, other.path, ',') != null) return g.fail(target.span, "this property cannot be linked", .{});
        if (!other.ty.eql(ty)) return g.fail(target.span, "cannot link a {s} with a {s}", .{ ty.name(), other.ty.name() });
        // The target keeps its value; `path` becomes an alias of it.
        try line(iw, 2, "self.{s}.linkTwoWay(&self.{s});", .{ other.path, path });
    }

    /// `function name(a: T) -> R { ... }` as a method.
    fn emitFunction(g: *Generator, c: *Comp, f: *const FunctionDecl, fields: *Fields) Error!void {
        var ctx = try g.context(c, c.root, fields);
        var locals: std.ArrayList(Local) = .empty;
        try locals.appendSlice(g.arena, ctx.locals);
        var signature: std.ArrayList(u8) = .empty;
        var arg_names: std.ArrayList([]const u8) = .empty;
        for (f.decl.params, f.params) |param, t| {
            const zig = try g.print("arg_{s}", .{try zigName(g.arena, param.name.name)});
            try locals.append(g.arena, .{ .name = param.name.name, .zig = zig, .ty = t });
            try arg_names.append(g.arena, zig);
            try signature.appendSlice(g.arena, try g.print(", {s}: {s}", .{ zig, t.zig() }));
        }
        ctx.locals = locals.items;
        ctx.ret = f.ret;
        var body: Writer.Allocating = .init(g.arena);
        try g.compileStmts(&ctx, f.decl.body, &body.writer, 2);
        if (f.ret != .void and !alwaysReturns(f.decl.body)) try line(&body.writer, 2, "return {s};", .{defaultValue(f.ret)});
        const text = body.written();
        try g.appendFmt(&fields.functions, "    {s}fn {s}(self: *Self{s}) {s} {{\n", .{ if (f.public) "pub " else "", f.method, signature.items, f.ret.zig() });
        if (!usesIdent(text, "self")) try g.appendFmt(&fields.functions, "        _ = self;\n", .{});
        for (arg_names.items) |zig| if (!usesIdent(text, zig)) try g.appendFmt(&fields.functions, "        _ = {s};\n", .{zig});
        try g.appendFmt(&fields.functions, "{s}    }}\n\n", .{text});
    }

    /// `mask-source: shape;`: the element whose drawing masks this one,
    /// set once.
    fn emitMaskSource(g: *Generator, iw: *Writer, c: *Comp, el: *Elem, b: ast.Binding, fields: *Fields) Error!void {
        var ctx = try g.context(c, el, fields);
        const target = switch (try g.compileRef(&ctx, b.value)) {
            .element => |t| t,
            else => return g.fail(b.value.span, "a mask-source is an element (its id)", .{}),
        };
        if (target == el) return g.fail(b.value.span, "an element cannot be its own mask", .{});
        // Where its other mask properties are (it then has them).
        const member = (try g.memberFrom(c, el, "mask-inverted", b.name.span)) orelse
            return g.fail(b.name.span, "'{s}' has no mask", .{elementTypeName(el)});
        const path = member.property.path;
        const base = path[0 .. path.len - ".mask_inverted".len];
        try line(iw, 2, "self.{s}.mask_source = {s};", .{ base, try g.itemPtr(c, target) });
    }

    fn isAnimationEnd(name: []const u8) bool {
        return std.mem.eql(u8, name, "target") or std.mem.eql(u8, name, "from") or std.mem.eql(u8, name, "to");
    }

    /// A PropertyAnimation's `target: box.x; from: ...; to: ...;`: the
    /// values captured when it begins, and set between them.
    fn emitAnimationTarget(g: *Generator, iw: *Writer, c: *Comp, el: *Elem, fields: *Fields) Error!void {
        var target_expr: ?*const ast.Expr = null;
        var from_expr: ?*const ast.Expr = null;
        var to_expr: ?*const ast.Expr = null;
        for (el.ast.members) |m| if (m == .binding) {
            const b = m.binding;
            if (std.mem.eql(u8, b.name.name, "target")) target_expr = b.value;
            if (std.mem.eql(u8, b.name.name, "from")) from_expr = b.value;
            if (std.mem.eql(u8, b.name.name, "to")) to_expr = b.value;
        };
        const te = target_expr orelse return g.fail(el.ast.type_name.span, "PropertyAnimation needs a 'target': the property it animates (box.opacity)", .{});
        const te_to = to_expr orelse return g.fail(el.ast.type_name.span, "PropertyAnimation needs 'to': the value it animates to", .{});
        var ctx = try g.context(c, el, fields);
        const ref = try g.compileRef(&ctx, te);
        var p = switch (ref) {
            .property => |p| p,
            else => return g.fail(te.span, "a PropertyAnimation's target is a property (box.opacity)", .{}),
        };
        if (p.read_only) return g.fail(te.span, "cannot animate this property: {s}", .{p.read_only_reason});
        if (p.optional or p.constraint) return g.fail(te.span, "this property cannot be animated", .{});
        switch (p.ty) {
            .int, .float, .length, .duration, .color, .brush => {},
            else => return g.fail(te.span, "a {s} cannot be animated", .{p.ty.name()}),
        }
        // Set as is: not through the property's own `animate`.
        p.anim = null;
        const current = try g.refToValue(.{ .property = p }, te.span);
        const from = if (from_expr) |f| try g.compileExpr(&ctx, f, p.ty) else current;
        const to = try g.compileExpr(&ctx, te_to, p.ty);
        const n = fields.next_static;
        fields.next_static += 1;
        const zt = p.ty.zig();
        try g.appendFmt(&fields.expr_fields, "    _anim{d}_from: {s} = {s},\n    _anim{d}_to: {s} = {s},\n", .{ n, zt, defaultValue(p.ty), n, zt, defaultValue(p.ty) });
        try g.appendFmt(&fields.functions, "    fn _anim{d}Begin(self: *Self) void {{\n        self._anim{d}_from = {s};\n        self._anim{d}_to = {s};\n    }}\n\n", .{ n, n, from.code, n, to.code });
        var set: Writer.Allocating = .init(g.arena);
        try writeSet(&set.writer, 2, p, try g.print("zigulee.core.interpolate({s}, self._anim{d}_from, self._anim{d}_to, t)", .{ zt, n, n }));
        try g.appendFmt(&fields.functions, "    fn _anim{d}Apply(self: *Self, t: f32) void {{\n{s}    }}\n\n", .{ n, set.written() });
        const loc = try g.locFrom(c, el);
        try line(iw, 2, "self.{s}{s}.node.setTarget(self, _anim{d}Begin, _anim{d}Apply);", .{ loc.prefix, loc.field, n, n });
    }

    pub fn isConnections(el: *const Elem) bool {
        return el.kind == .builtin and std.mem.eql(u8, el.kind.builtin.name, "Connections");
    }

    /// `target.name => { }`, or a handler in `Connections { target: x; }`:
    /// added to the target's callback (a `zigulee.core.Connection`).
    fn emitConnection(g: *Generator, c: *Comp, el: *Elem, h: *const ast.Handler, fields: *Fields) Error!void {
        var ctx = try g.context(c, el, fields);
        const target_expr: *const ast.Expr = if (h.target) |t| try g.identExpr(t) else for (el.ast.members) |m| {
            if (m == .binding and std.mem.eql(u8, m.binding.name.name, "target")) break m.binding.value;
        } else return g.fail(el.ast.type_name.span, "Connections needs a 'target': the element whose callbacks it handles", .{});
        const target = try g.compileRef(&ctx, target_expr);
        const cb = switch (target) {
            .element => |t| blk: {
                const member = try g.memberFrom(c, t, h.name.name, h.name.span) orelse
                    return g.fail(h.name.span, "'{s}' has no callback '{s}'", .{ elementTypeName(t), h.name.name });
                if (member != .callback) return g.fail(h.name.span, "'{s}' is not a callback", .{h.name.name});
                break :blk member.callback;
            },
            .global_comp => |gc| blk: {
                const decl = gc.callback(h.name.name) orelse return g.fail(h.name.span, "{s} has no callback '{s}'", .{ gc.name, h.name.name });
                break :blk CallbackRef{ .path = try g.print("_g_{s}().{s}", .{ try zigName(g.arena, gc.zig), decl.zig }), .params = decl.params, .ret = decl.ret };
            },
            else => return g.fail(target_expr.span, "a connection's target is an element (its id, root, parent) or a global", .{}),
        };
        if (h.params.len > cb.params.len) return g.fail(h.span, "'{s}' has {d} argument(s)", .{ h.name.name, cb.params.len });

        var locals: std.ArrayList(Local) = .empty;
        try locals.appendSlice(g.arena, ctx.locals);
        var signature: std.ArrayList(u8) = .empty;
        var fn_params: std.ArrayList(u8) = .empty;
        var arg_names: std.ArrayList([]const u8) = .empty;
        for (cb.params, 0..) |t, k| {
            const arg_name = if (k < h.params.len) h.params[k].name else try g.print("unused{d}", .{k});
            const zig = try g.print("arg_{s}", .{try zigName(g.arena, arg_name)});
            if (k < h.params.len) try locals.append(g.arena, .{ .name = arg_name, .zig = zig, .ty = t });
            try arg_names.append(g.arena, zig);
            try signature.appendSlice(g.arena, try g.print(", {s}: {s}", .{ zig, t.zig() }));
            try fn_params.appendSlice(g.arena, try g.print("{s}{s}", .{ if (k > 0) ", " else "", t.zig() }));
        }
        ctx.locals = locals.items;
        // What it returns is the callback's own handler's.
        ctx.ret = .void;
        var body: Writer.Allocating = .init(g.arena);
        if (isConnections(el)) {
            const loc = try g.locFrom(c, el);
            try line(&body.writer, 2, "if (!self.{s}{s}.enabled.get()) return;", .{ loc.prefix, loc.field });
        }
        try g.compileStmts(&ctx, h.body, &body.writer, 2);

        const name = try g.newFn(fields, "h");
        const text = body.written();
        try g.appendFmt(&fields.functions, "    fn {s}(self: *Self{s}) void {{\n", .{ name, signature.items });
        if (!usesIdent(text, "self")) try g.appendFmt(&fields.functions, "        _ = self;\n", .{});
        for (arg_names.items) |zig| if (!usesIdent(text, zig)) try g.appendFmt(&fields.functions, "        _ = {s};\n", .{zig});
        try g.appendFmt(&fields.functions, "{s}    }}\n\n", .{text});
        const n = fields.next_static;
        fields.next_static += 1;
        try g.appendFmt(&fields.expr_fields, "    _conn{d}: zigulee.core.Connection(fn ({s}) {s}) = .{{}},\n", .{ n, fn_params.items, cb.ret.zig() });
        try g.appendFmt(&fields.connects, "        self._conn{d}.connect(&self.{s}, self, {s});\n", .{ n, firstPath(cb.path), name });
        try g.appendFmt(&fields.disconnects, "        self._conn{d}.disconnect();\n", .{n});
    }

    fn identExpr(g: *Generator, id: ast.Ident) Allocator.Error!*const ast.Expr {
        const e = try g.arena.create(ast.Expr);
        e.* = .{ .kind = .{ .ident = id.name }, .span = id.span };
        return e;
    }

    /// A `StateMachine`: its `Definition`, the hooks running what its
    /// source says (guards, actions, entry and exit actions, delays), a
    /// `send_<id>_<event>` method per event; set up in `init`, started at
    /// its end.
    fn emitMachine(g: *Generator, iw: *Writer, c: *Comp, el: *Elem, fields: *Fields) Error!void {
        const m = el.machine.?;
        const sm = "zigulee.core.statemachine";
        const name = try g.print("_m_{s}", .{el.field});

        // The definition.
        var def: std.ArrayList(u8) = .empty;
        try g.appendFmt(&def, "    const {s}_def: {s}.Definition = .{{\n        .states = &.{{\n", .{ name, sm });
        for (m.states.items, 0..) |st, si| {
            const slashed = try std.mem.replaceOwned(u8, g.arena, st.path, ".", "/");
            try g.appendFmt(&def, "            .{{ .name = \"{f}\", .path = \"{f}\"", .{ std.zig.fmtString(st.ast.name.name), std.zig.fmtString(slashed) });
            if (st.parent) |p| try g.appendFmt(&def, ", .parent = {d}", .{p});
            if (st.initial) |i| try g.appendFmt(&def, ", .initial = {d}", .{i});
            if (st.ast.history) |h| try g.appendFmt(&def, ", .history = .{s}", .{if (h.deep) "deep" else "shallow"});
            if (st.ast.kind == .parallel) try g.appendFmt(&def, ", .parallel = true", .{});
            if (st.ast.kind == .final) try g.appendFmt(&def, ", .final = true", .{});
            try g.appendFmt(&def, ", .transitions = &.{{", .{});
            var any = false;
            for (m.transitions.items, 0..) |t, ti| if (t.state == si) {
                any = true;
                const trigger = if (t.event) |e|
                    try g.print(".{{ .event = {d} }}", .{e})
                else if (t.after) |a|
                    try g.print(".{{ .after = {d} }}", .{a})
                else if (t.done) |d|
                    try g.print(".{{ .done = {d} }}", .{d})
                else
                    ".eventless";
                const target = if (t.target) |to| try g.print("{d}", .{to}) else "null";
                try g.appendFmt(&def, "\n                .{{ .trigger = {s}, .target = {s}, .to_history = {}, .index = {d}, .guarded = {} }},", .{ trigger, target, t.to_history, ti, t.ast.guard != null });
            };
            try g.appendFmt(&def, "{s}}} }},\n", .{if (any) "\n            " else ""});
        }
        try g.appendFmt(&def, "        }},\n        .events = &.{{", .{});
        for (m.events.items, 0..) |e, i| try g.appendFmt(&def, "{s}\"{f}\"", .{ if (i > 0) ", " else " ", std.zig.fmtString(e.name) });
        try g.appendFmt(&def, " }},\n        .initial = {d},\n        .afters = {d},\n    }};\n", .{ m.initial, m.afters });
        try fields.statics.appendSlice(g.arena, def.items);

        // Code written in a state: unqualified names are the machine's,
        // then the component's, as in a handler on it.
        const Prong = struct { key: usize, code: []const u8 };
        var guards: std.ArrayList(Prong) = .empty;
        var actions: std.ArrayList(Prong) = .empty;
        var entered: std.ArrayList(Prong) = .empty;
        var exited: std.ArrayList(Prong) = .empty;
        var delays: std.ArrayList(Prong) = .empty;
        var failed = false;
        for (m.transitions.items, 0..) |t, ti| {
            var ctx = try g.context(c, el, fields);
            // The event's arguments, by the names the transition gives them.
            var locals: std.ArrayList(Local) = .empty;
            try locals.appendSlice(g.arena, ctx.locals);
            var unpack: std.ArrayList(Local) = .empty;
            if (t.event) |e| for (t.ast.trigger.event.params, 0..) |param, k| {
                const ty = m.events.items[e].params[k];
                const zig = try g.print("arg_{s}", .{try zigName(g.arena, param.name)});
                const local: Local = .{ .name = param.name, .zig = try g.print("{s}{d}", .{ zig, k }), .ty = ty };
                try locals.append(g.arena, local);
                try unpack.append(g.arena, local);
            };
            ctx.locals = locals.items;
            if (t.ast.guard) |guard| {
                const v = g.compileExpr(&ctx, guard, .bool) catch {
                    failed = true;
                    continue;
                };
                try guards.append(g.arena, .{ .key = ti, .code = try g.unpackArgs(unpack.items, try g.print("return {s};", .{v.code})) });
            }
            if (t.ast.actions.len > 0) {
                var body: Writer.Allocating = .init(g.arena);
                g.compileStmts(&ctx, t.ast.actions, &body.writer, 4) catch {
                    failed = true;
                    continue;
                };
                try actions.append(g.arena, .{ .key = ti, .code = try g.unpackArgs(unpack.items, body.written()) });
            }
            if (t.after) |a| {
                var plain = try g.context(c, el, fields);
                const v = g.compileExpr(&plain, t.ast.trigger.after, .duration) catch {
                    failed = true;
                    continue;
                };
                try delays.append(g.arena, .{ .key = a, .code = try g.print("                return {s};\n", .{v.code}) });
            }
        }
        for (m.states.items, 0..) |st, si| for ([_]?[]ast.Stmt{ st.ast.entered, st.ast.exited }, [_]*std.ArrayList(Prong){ &entered, &exited }) |stmts, list| {
            var ctx = try g.context(c, el, fields);
            var body: Writer.Allocating = .init(g.arena);
            g.compileStmts(&ctx, stmts orelse continue, &body.writer, 4) catch {
                failed = true;
                continue;
            };
            try list.append(g.arena, .{ .key = si, .code = body.written() });
        };
        if (failed) return error.CompileError;

        // The hooks: a switch over the transition, state or `after`.
        const Hook = struct { field: []const u8, prongs: []const Prong, params: []const u8, ret: []const u8, default: []const u8, on: []const u8 };
        const args_param = try g.print("args: []const {s}.Arg", .{sm});
        const hooks = [_]Hook{
            .{ .field = "guard", .prongs = guards.items, .params = try g.print("t: u16, {s}", .{args_param}), .ret = "bool", .default = "return true", .on = "t" },
            .{ .field = "action", .prongs = actions.items, .params = try g.print("t: u16, {s}", .{args_param}), .ret = "void", .default = "{}", .on = "t" },
            .{ .field = "entered", .prongs = entered.items, .params = "s: u16", .ret = "void", .default = "{}", .on = "s" },
            .{ .field = "exited", .prongs = exited.items, .params = "s: u16", .ret = "void", .default = "{}", .on = "s" },
            .{ .field = "delay", .prongs = delays.items, .params = "a: u16", .ret = "i64", .default = "return 0", .on = "a" },
        };
        var setup: std.ArrayList(u8) = .empty;
        try g.appendFmt(&setup, "try self.{s}.setup(&{s}_def, .{{ .ctx = self", .{ el.field, name });
        for (hooks) |h| {
            if (h.prongs.len == 0) continue;
            var body: std.ArrayList(u8) = .empty;
            for (h.prongs) |pr| try g.appendFmt(&body, "            {d} => {{\n{s}            }},\n", .{ pr.key, pr.code });
            const fn_name = try g.print("{s}_{s}", .{ name, h.field });
            try g.appendFmt(&fields.functions, "    fn {s}(ctx: *anyopaque, {s}) {s} {{\n", .{ fn_name, h.params, h.ret });
            if (usesIdent(body.items, "self"))
                try g.appendFmt(&fields.functions, "        const self: *Self = @ptrCast(@alignCast(ctx));\n", .{})
            else
                try g.appendFmt(&fields.functions, "        _ = ctx;\n", .{});
            if (std.mem.indexOf(u8, h.params, "args") != null and !usesIdent(body.items, "args"))
                try g.appendFmt(&fields.functions, "        _ = args;\n", .{});
            try g.appendFmt(&fields.functions, "        switch ({s}) {{\n{s}            else => {s},\n        }}\n    }}\n\n", .{ h.on, body.items, h.default });
            try g.appendFmt(&setup, ", .{s} = {s}", .{ h.field, fn_name });
        }
        try line(iw, 2, "{s} }});", .{setup.items});

        // Sending an event: calling it (from `.zge`, or Zig).
        for (m.events.items, 0..) |e, i| {
            var sig: std.ArrayList(u8) = .empty;
            var packed_args: std.ArrayList(u8) = .empty;
            for (e.params, 0..) |t, k| {
                try g.appendFmt(&sig, ", a{d}: {s}", .{ k, t.zig() });
                const value = if (t == .enumeration) try g.print("@intFromEnum(a{d})", .{k}) else try g.print("a{d}", .{k});
                try g.appendFmt(&packed_args, "{s}.{{ .{s} = {s} }}", .{ if (k > 0) ", " else " ", Machine.argField(t).?, value });
            }
            try g.appendFmt(&fields.functions, "    /// Sends `{s}` to `{s}`.\n    pub fn {s}(self: *Self{s}) void {{\n        self.{s}.sendEvent({d}, &.{{{s}{s}}});\n    }}\n\n", .{
                e.name, if (el.ast.id) |id| id.name else el.field, try g.eventMethod(el, e.name), sig.items, el.field, i, packed_args.items, if (packed_args.items.len > 0) " " else "",
            });
        }
        // Started once everything is set up.
        try g.appendFmt(&fields.connects, "        self.{s}.begin();\n", .{el.field});
    }

    /// The method sending event `event` of machine `el`.
    fn eventMethod(g: *Generator, el: *const Elem, event: []const u8) Allocator.Error![]const u8 {
        return g.print("send_{s}_{s}", .{ el.field, try zigName(g.arena, event) });
    }

    /// `code` (a hook's prong) with the event's arguments it uses read
    /// from `args` first.
    fn unpackArgs(g: *Generator, locals: []const Local, code: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (locals, 0..) |l, k| {
            if (!usesIdent(code, l.zig)) continue;
            const field = Machine.argField(l.ty).?;
            const read = if (l.ty == .enumeration) try g.print("@enumFromInt(args[{d}].int)", .{k}) else try g.print("args[{d}].{s}", .{ k, field });
            try g.appendFmt(&out, "                const {s}: {s} = {s};\n", .{ l.zig, l.ty.zig(), read });
        }
        if (std.mem.startsWith(u8, code, "return ")) {
            try g.appendFmt(&out, "                {s}\n", .{code});
        } else try out.appendSlice(g.arena, code);
        return out.items;
    }

    fn emitHandler(g: *Generator, iw: *Writer, c: *Comp, el: *Elem, h: *const ast.Handler, fields: *Fields) Error!void {
        if (h.target != null or isConnections(el)) return g.emitConnection(c, el, h, fields);
        const member = try g.memberFrom(c, el, h.name.name, h.name.span) orelse
            return g.fail(h.name.span, "'{s}' has no callback '{s}'", .{ elementTypeName(el), h.name.name });
        const cb = switch (member) {
            .callback => |cb| cb,
            else => return g.fail(h.name.span, "'{s}' is not a callback", .{h.name.name}),
        };
        if (h.params.len > cb.params.len) return g.fail(h.span, "'{s}' has {d} argument(s)", .{ h.name.name, cb.params.len });
        var ctx = try g.context(c, el, fields);
        var locals: std.ArrayList(Local) = .empty;
        try locals.appendSlice(g.arena, ctx.locals);
        var signature: std.ArrayList(u8) = .empty;
        var arg_names: std.ArrayList([]const u8) = .empty;
        for (cb.params, 0..) |t, k| {
            const arg_name = if (k < h.params.len) h.params[k].name else try g.print("unused{d}", .{k});
            const zig = try g.print("arg_{s}", .{try zigName(g.arena, arg_name)});
            if (k < h.params.len) try locals.append(g.arena, .{ .name = arg_name, .zig = zig, .ty = t });
            try arg_names.append(g.arena, zig);
            try signature.appendSlice(g.arena, try g.print(", {s}: {s}", .{ zig, t.zig() }));
        }
        ctx.locals = locals.items;
        ctx.ret = cb.ret;
        var body: Writer.Allocating = .init(g.arena);
        try g.compileStmts(&ctx, h.body, &body.writer, 2);
        if (cb.ret != .void and !alwaysReturns(h.body)) try line(&body.writer, 2, "return {s};", .{defaultValue(cb.ret)});

        const name = try g.newFn(fields, "h");
        const text = body.written();
        try g.appendFmt(&fields.functions, "    fn {s}(self: *Self{s}) {s} {{\n", .{ name, signature.items, cb.ret.zig() });
        if (!usesIdent(text, "self")) try g.appendFmt(&fields.functions, "        _ = self;\n", .{});
        for (arg_names.items) |zig| if (!usesIdent(text, zig)) try g.appendFmt(&fields.functions, "        _ = {s};\n", .{zig});
        try g.appendFmt(&fields.functions, "{s}    }}\n\n", .{text});
        try line(iw, 2, "self.{s}.setHandler(self, {s});", .{ cb.path, name });
    }
};

/// Whether `ident` occurs in `code` as a whole identifier.
/// Whether a global's members assign `name` (in handlers, functions and
/// `changed` bodies), bind it, or link it two-way.
fn assignsOrLinks(members: []const ast.Member, name: []const u8) bool {
    for (members) |m| switch (m) {
        .binding => |b| if (std.mem.eql(u8, b.name.name, name)) return true,
        .two_way => |t| if (std.mem.eql(u8, t.name.name, name)) return true,
        .handler => |h| if (stmtsAssign(h.body, name)) return true,
        .function => |f| if (stmtsAssign(f.body, name)) return true,
        .changed => |c| if (stmtsAssign(c.body, name)) return true,
        .child => |el| if (assignsOrLinks(el.members, name)) return true,
        .machine_state => |st| {
            if (st.entered) |b| if (stmtsAssign(b, name)) return true;
            if (st.exited) |b| if (stmtsAssign(b, name)) return true;
            for (st.transitions) |t| if (stmtsAssign(t.actions, name)) return true;
        },
        else => {},
    };
    return false;
}

fn stmtsAssign(stmts: []const ast.Stmt, name: []const u8) bool {
    for (stmts) |st| switch (st.kind) {
        .assign => |a| if (targetNames(a.target, name)) return true,
        .@"if" => |i| if (stmtsAssign(i.then, name) or stmtsAssign(i.otherwise, name)) return true,
        .@"while" => |w| if (stmtsAssign(w.body, name)) return true,
        .@"for" => |f| if (stmtsAssign(f.body, name)) return true,
        else => {},
    };
    return false;
}

/// `name`, `root.name` or `self.name`.
fn targetNames(e: *const ast.Expr, name: []const u8) bool {
    return switch (e.kind) {
        .ident => |n| std.mem.eql(u8, n, name),
        .member => |m| std.mem.eql(u8, m.name.name, name) and m.object.kind == .ident and
            (std.mem.eql(u8, m.object.kind.ident, "root") or std.mem.eql(u8, m.object.kind.ident, "self")),
        else => false,
    };
}

/// Whether any two-way link in `members` (or the elements in them) is to
/// `global.name`.
fn linksTo(members: []const ast.Member, global: []const u8, name: []const u8) bool {
    for (members) |m| switch (m) {
        .two_way => |t| if (isMember(t.target, global, name)) return true,
        .property => |p| if (p.alias) |a| if (isMember(a, global, name)) return true,
        .child => |el| if (linksTo(el.members, global, name)) return true,
        .repeated => |r| if (linksTo(r.element.members, global, name)) return true,
        .conditional => |c| if (linksTo(c.element.members, global, name)) return true,
        else => {},
    };
    return false;
}

fn isMember(e: *const ast.Expr, object: []const u8, name: []const u8) bool {
    return switch (e.kind) {
        .member => |m| std.mem.eql(u8, m.name.name, name) and m.object.kind == .ident and std.mem.eql(u8, m.object.kind.ident, object),
        else => false,
    };
}

fn usesIdent(code: []const u8, ident: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, code, i, ident)) |pos| {
        const before_ok = pos == 0 or !isIdentChar(code[pos - 1]);
        const end = pos + ident.len;
        const after_ok = end >= code.len or !isIdentChar(code[end]);
        if (before_ok and after_ok) return true;
        i = pos + 1;
    }
    return false;
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// `border-radius` -> `border_radius`; Zig keywords and primitive type
/// names get a `_` after them (`resume` -> `resume_`, `i32` -> `i32_`).
pub fn zigName(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    const reserved = std.zig.Token.getKeyword(name) != null or std.zig.primitives.isPrimitive(name);
    const out = try arena.alloc(u8, name.len + @intFromBool(reserved));
    for (name, 0..) |ch, i| out[i] = if (ch == '-') '_' else ch;
    if (reserved) out[name.len] = '_';
    return out;
}

test zigName {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("border_radius", try zigName(a, "border-radius"));
    try std.testing.expectEqualStrings("resume_", try zigName(a, "resume"));
    try std.testing.expectEqualStrings("type_", try zigName(a, "type"));
    try std.testing.expectEqualStrings("i32_", try zigName(a, "i32"));
}

/// `path` from `dir` (`/` separators), with `.` and `..` worked out: a
/// file reached two ways is one file (one module, its globals once).
fn joinPath(arena: Allocator, dir: []const u8, path: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.resolvePosix(arena, &.{ dir, path });
}
