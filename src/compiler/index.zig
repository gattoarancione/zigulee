// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! What names refer to, recorded while analyzing: for editor tooling
//! (hover, go to definition, references, rename, completion).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Span = @import("ast.zig").Span;

pub const Kind = enum {
    component,
    global,
    builtin_element,
    property,
    callback,
    function,
    id,
    structure,
    enumeration,
    /// A `StateMachine`'s.
    state,
    event,

    pub fn word(k: Kind) []const u8 {
        return switch (k) {
            .component => "component",
            .global => "global",
            .builtin_element => "element",
            .property => "property",
            .callback => "callback",
            .function => "function",
            .id => "id",
            .structure => "struct",
            .enumeration => "enum",
            .state => "state",
            .event => "event",
        };
    }
};

pub const Location = struct {
    /// Index into the diagnostics' files.
    file: u16,
    span: Span,
};

pub const Symbol = struct {
    kind: Kind,
    name: []const u8,
    /// Where it is declared (null for built-ins).
    decl: ?Location,
    /// One line describing it, like `var in-out <int> count`.
    detail: []const u8,
    /// The type of an id's element, for completion after `id.`.
    element_type: ?[]const u8 = null,
};

pub const Reference = struct {
    loc: Location,
    symbol: u32,
};

/// A name offered for completion.
pub const Member = struct {
    name: []const u8,
    kind: Kind,
    detail: []const u8,
    /// Key of its own members in `Index.members` (for element types, ids,
    /// globals and enums).
    target: ?[]const u8 = null,
};

pub const Index = struct {
    arena: Allocator,
    symbols: std.ArrayList(Symbol) = .empty,
    references: std.ArrayList(Reference) = .empty,
    /// Symbols by identity key.
    keys: std.StringHashMapUnmanaged(u32) = .empty,
    /// References already recorded, by file and start offset.
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Members of element types, globals and enums, by key: `comp:<zig
    /// name>`, `builtin:<name>`, `enum:<name>`. Components include the
    /// members of the element they inherit.
    members: std.StringHashMapUnmanaged([]const Member) = .empty,
    /// Names visible in each file (by file index): element types, globals,
    /// structs and enums.
    scopes: std.AutoHashMapUnmanaged(u16, []const Member) = .empty,
    /// Ids of each component (by `comp:<zig name>`), targeting their type.
    ids: std.StringHashMapUnmanaged([]const Member) = .empty,
    /// Names of the files (by file index), as given to the compiler.
    files: []const []const u8 = &.{},

    /// The symbol with identity `key`, created from `s` if new.
    pub fn symbol(ix: *Index, key: []const u8, s: Symbol) Allocator.Error!u32 {
        const gop = try ix.keys.getOrPut(ix.arena, key);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.key_ptr.* = try ix.arena.dupe(u8, key);
        try ix.symbols.append(ix.arena, s);
        gop.value_ptr.* = @intCast(ix.symbols.items.len - 1);
        return gop.value_ptr.*;
    }

    /// Records that the name at `loc` refers to `sym` (once per location).
    pub fn reference(ix: *Index, loc: Location, sym: u32) Allocator.Error!void {
        const key = (@as(u64, loc.file) << 32) | loc.span.start;
        const gop = try ix.seen.getOrPut(ix.arena, key);
        if (gop.found_existing) return;
        try ix.references.append(ix.arena, .{ .loc = loc, .symbol = sym });
    }

    /// The reference covering `offset` in `file`, if any.
    pub fn referenceAt(ix: *const Index, file: u16, offset: u32) ?Reference {
        for (ix.references.items) |r| {
            if (r.loc.file == file and r.loc.span.start <= offset and offset <= r.loc.span.end) return r;
        }
        return null;
    }

    /// Every reference to `sym` (including its declaration).
    pub fn referencesTo(ix: *const Index, gpa: Allocator, sym: u32) Allocator.Error![]Location {
        var out: std.ArrayList(Location) = .empty;
        for (ix.references.items) |r| if (r.symbol == sym) try out.append(gpa, r.loc);
        return out.toOwnedSlice(gpa);
    }
};
