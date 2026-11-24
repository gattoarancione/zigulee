// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Syntax tree of a `.zge` document. All nodes live in the compiler's
//! arena; spans are byte offsets into the source.

const lexer = @import("lexer.zig");

pub const Span = struct {
    start: u32,
    end: u32,

    pub fn join(a: Span, b: Span) Span {
        return .{ .start = @min(a.start, b.start), .end = @max(a.end, b.end) };
    }
};

pub const Ident = struct {
    name: []const u8,
    span: Span,
};

pub const Document = struct {
    components: []Component,
    structs: []StructDecl,
    enums: []EnumDecl,
    imports: []Import,
};

/// `import { A, B } from "file.zge";`
pub const Import = struct {
    names: []Ident,
    /// Relative to the importing file.
    path: []const u8,
    path_span: Span,
    /// `export { A } from "path";`: also makes the names available to files
    /// importing this one.
    reexport: bool = false,
};

/// `struct Name { field: type, ... }`
pub const StructDecl = struct {
    name: Ident,
    fields: []FieldDecl,

    pub const FieldDecl = struct { name: Ident, type_name: TypeRef };
};

/// `enum Name { a, b, c }`
pub const EnumDecl = struct {
    name: Ident,
    values: []Ident,
};

pub const Component = struct {
    name: Ident,
    exported: bool,
    /// `global Name { ... }`: a single shared instance with properties
    /// and callbacks, no elements.
    is_global: bool = false,
    /// The root element: its type is the `inherits` base, its members are
    /// the component body.
    root: Element,
    span: Span,
};

pub const Element = struct {
    id: ?Ident,
    type_name: Ident,
    members: []Member,
    span: Span,
};

pub const Visibility = enum { private, in, out, in_out };

pub const Member = union(enum) {
    property: PropertyDecl,
    callback: CallbackDecl,
    binding: Binding,
    two_way: TwoWay,
    handler: Handler,
    child: *Element,
    animate: Animate,
    /// `for item[index] in model : Element { ... }`
    repeated: Repeated,
    /// `if condition : Element { ... }`
    conditional: Conditional,
    /// `states [ name when condition : { prop: value; } ... ]`
    states: States,
    /// `changed prop => { ... }`
    changed: Changed,
    /// `@children`: in a component, where the children of its uses go.
    children_placeholder: Span,
    function: FunctionDecl,
    /// In a `StateMachine`: `event name(types);`
    event: EventDecl,
    /// In a `StateMachine`: `initial name;`
    initial: Ident,
    /// In a `StateMachine`: `state name { ... }`
    machine_state: MachineState,
};

/// `event name(int, string);`: an event of a state machine, sent by calling
/// it.
pub const EventDecl = struct {
    name: Ident,
    params: []Ident,
    span: Span,
};

/// `state name { entered => { } exited => { } on ... after ... }`, with
/// states inside it too; `parallel name { ... }`, whose states are all
/// active together; `final name;`.
pub const MachineState = struct {
    kind: enum { state, parallel, final } = .state,
    name: Ident,
    entered: ?[]Stmt = null,
    exited: ?[]Stmt = null,
    transitions: []Transition,
    /// The states inside it, and `initial name;` (else its first one).
    children: []MachineState = &.{},
    initial: ?Ident = null,
    /// `history;` or `history deep;`.
    history: ?struct { deep: bool, span: Span } = null,
    span: Span,

    /// `on event(params) when guard => target { actions }`, or `after
    /// duration ...`; each part after the trigger optional.
    pub const Transition = struct {
        trigger: union(enum) {
            event: struct { name: Ident, params: []Ident },
            after: *Expr,
            /// `on done.x`: x reached its final state (all its regions,
            /// for a parallel state).
            done: StateRef,
            /// `when guard => ...`: taken as soon as the guard holds.
            eventless,
        },
        guard: ?*Expr,
        /// None: internal (no state left or entered).
        target: ?StateRef,
        actions: []Stmt,
        span: Span,
    };
};

/// A state named by its name or its path, `ready.editing`, or entered
/// through its history, `ready.history`.
pub const StateRef = struct {
    parts: []Ident,
    span: Span,
};

pub const States = struct {
    states: []State,
    span: Span,

    pub const State = struct {
        name: Ident,
        condition: *Expr,
        /// `prop: value;` or `id.prop: value;`
        assignments: []Assignment,
        /// `animate` directly in the state: used for any change.
        animations: []Animate,
        /// `in { animate ... }`: used when the state becomes active.
        enter: []Animate,
        /// `out { animate ... }`: used when the state stops being active.
        leave: []Animate,
    };

    pub const Assignment = struct { target: *Expr, value: *Expr };
};

pub const Changed = struct {
    name: Ident,
    body: []Stmt,
    span: Span,
};

pub const Repeated = struct {
    item: ?Ident,
    index: ?Ident,
    model: *Expr,
    element: *Element,
    span: Span,
};

pub const Conditional = struct {
    condition: *Expr,
    element: *Element,
    span: Span,
};

/// A type in a declaration: `int`, or `[string]` for a model.
pub const TypeRef = struct {
    name: Ident,
    model: bool,
    /// `[[name]]`: a model of models.
    nested: bool = false,
    span: Span,
};

pub const PropertyDecl = struct {
    visibility: Visibility,
    type_name: TypeRef,
    name: Ident,
    init: ?*Expr,
    /// `var <T> name <=> other;`
    alias: ?*Expr,
    span: Span,
};

pub const CallbackDecl = struct {
    name: Ident,
    params: []Ident,
    ret: ?Ident,
    span: Span,
};

/// `[public] function name(a: int, b: string) -> int { ... }`
pub const FunctionDecl = struct {
    name: Ident,
    params: []Param,
    ret: ?TypeRef,
    body: []Stmt,
    public: bool,
    span: Span,

    pub const Param = struct { name: Ident, type_name: TypeRef };
};

pub const Binding = struct {
    name: Ident,
    value: *Expr,
};

pub const TwoWay = struct {
    name: Ident,
    target: *Expr,
};

pub const Handler = struct {
    /// `target.name => { }`: a handler for another element's callback.
    target: ?Ident = null,
    name: Ident,
    params: []Ident,
    body: []Stmt,
    span: Span,
};

pub const Animate = struct {
    properties: []Ident,
    settings: []Setting,
    span: Span,

    pub const Setting = struct { name: Ident, value: *Expr };
};

pub const StringPart = union(enum) {
    literal: []const u8,
    expr: *Expr,
};

pub const ImageUrl = struct {
    path: []const u8,
    /// Borders kept unscaled, in image pixels: top, right, bottom, left.
    nine_slice: ?[4]u32 = null,
};

/// `@linear-gradient(...)` or `@radial-gradient(...)`.
pub const Gradient = struct {
    shape: enum { linear, radial },
    /// The angle (a linear gradient's, in degrees) if the first argument
    /// is one rather than a stop: told by its type.
    stops: []Stop,

    /// `color` or `color position` (a fraction, or a percentage).
    pub const Stop = struct { color: *Expr, position: ?*Expr };
};

pub const Expr = struct {
    kind: Kind,
    span: Span,

    pub const Kind = union(enum) {
        number: struct { value: f64, is_int: bool, unit: []const u8 },
        string: []StringPart,
        color: u32,
        ident: []const u8,
        member: struct { object: *Expr, name: Ident },
        call: struct { callee: *Expr, args: []*Expr },
        unary: struct { op: lexer.Tag, operand: *Expr },
        binary: struct { op: lexer.Tag, lhs: *Expr, rhs: *Expr },
        ternary: struct { cond: *Expr, then: *Expr, otherwise: *Expr },
        /// `[a, b, c]`
        array: []*Expr,
        /// `model[i]`
        index: struct { object: *Expr, index: *Expr },
        /// `@image-url("path")`, relative to the .zge file, optionally with
        /// `nine-slice(top right bottom left)`.
        image_url: ImageUrl,
        /// `@audio-url("path")`, relative to the .zge file.
        audio_url: []const u8,
        /// `@video-url("path")`, relative to the .zge file.
        video_url: []const u8,
        /// `@model-url("path")`, relative to the .zge file.
        model_url: []const u8,
        /// `@tr("ctx" => "text {}" | "plural {n}" % count, args...)`.
        tr: Tr,
        /// `@linear-gradient(90deg, red, blue 80%)`, `@radial-gradient(...)`.
        gradient: Gradient,
        /// `{ name: value, ... }`
        struct_literal: []FieldInit,
        /// `row => expression`: an argument of a model's `filter` or
        /// `sort`.
        lambda: struct { param: Ident, body: *Expr },
    };
};

pub const FieldInit = struct { name: Ident, value: *Expr };

/// A translatable string. `{}` takes the next argument, `{0}`, `{1}`...
/// a given one, `{n}` the count; `{{` and `}}` are braces.
pub const Tr = struct {
    /// Disambiguates equal texts with different meanings (gettext's
    /// msgctxt); empty if none.
    context: []const u8,
    text: []const u8,
    /// The plural form (in the source language) and the count choosing it.
    plural: ?[]const u8,
    count: ?*Expr,
    args: []*Expr,
};

pub const Stmt = struct {
    kind: Kind,
    span: Span,

    pub const Kind = union(enum) {
        expr: *Expr,
        assign: struct { target: *Expr, op: lexer.Tag, value: *Expr },
        @"if": struct { cond: *Expr, then: []Stmt, otherwise: []Stmt },
        @"return": ?*Expr,
        /// `let name = value;` or `let name: type = value;`: a local
        /// variable, assignable, until the end of its block.
        let: struct { name: Ident, type_name: ?TypeRef, value: *Expr },
        @"while": struct { cond: *Expr, body: []Stmt },
        /// `for item in model { }`, `for item[index] in model { }`, or
        /// `for i in count { }` (0 to count - 1).
        @"for": struct { item: Ident, index: ?Ident, over: *Expr, body: []Stmt },
        @"break",
        @"continue",
    };
};
