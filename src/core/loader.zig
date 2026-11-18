// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Components as values (the `component` type: `Settings`, a delegate
//! property) and the `Loader` element, which shows the component its
//! `source` names, created at run time.
//!
//! A component value is a `ComponentFactory`: generated code has one per
//! component (`Foo.factory`), the interpreter one per component it loads.
//! What a Loader passes to the instance (its other bindings) goes by name
//! through `set_input`, with the type's name: the component chosen is only
//! known at run time, so a mismatch is found then (and logged).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const ChangeTracker = @import("properties.zig").ChangeTracker;
const Callback = @import("callbacks.zig").Callback;
const item_mod = @import("item.zig");
const Item = item_mod.Item;

const log = std.log.scoped(.zigulee_loader);

/// Makes instances of a component.
pub const ComponentFactory = struct {
    /// The component's name (for messages).
    name: []const u8,
    ctx: ?*anyopaque = null,
    create: *const fn (ctx: ?*anyopaque, gpa: Allocator) Allocator.Error!*anyopaque,
    destroy: *const fn (ctx: ?*anyopaque, instance: *anyopaque) void,
    root: *const fn (ctx: ?*anyopaque, instance: *anyopaque) *Item,
    /// Sets the instance's input property `name` (`in` or `in-out`) to
    /// `value`, a `ty` (a `.zge` type's name); false if it has none of
    /// that name and type.
    set_input: *const fn (ctx: ?*anyopaque, instance: *anyopaque, name: []const u8, ty: []const u8, value: *const anyopaque) bool,
};

/// A component value (`component` in `.zge`); null: none.
pub const Component = ?*const ComponentFactory;

/// Shows an instance of the component `source` names, while `active`: its
/// root fills the loader (which has its size constraints, in a layout).
/// Another source replaces it; none, or `active: false`, leaves the loader
/// empty. `loaded` follows, and `loaded_changed` is called after each new
/// instance (whoever passes it inputs passes them again). Changes apply
/// when change handlers run. Initialize in place with `init`.
pub const Loader = struct {
    item: Item = .init(&vtable),
    source: Property(Component) = .init(null),
    active: Property(bool) = .init(true),
    /// An instance is shown.
    loaded: Property(bool) = .init(false),
    /// After an instance is created (and before it shows).
    created: Callback(fn () void) = .{},

    gpa: Allocator = undefined,
    instance: ?*anyopaque = null,
    shown: Component = null,
    tracker: ChangeTracker(Settings) = undefined,
    /// Names a mismatched input was logged for (once each).
    warned: u64 = 0,

    const Settings = struct { source: Component, active: bool };

    pub fn init(self: *Loader, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.tracker.init(gpa, self, settings, apply);
        apply(self, self.tracker.value);
    }

    pub fn deinit(self: *Loader) void {
        self.unload();
        self.tracker.deinit();
        self.item.deinit();
        self.source.deinit();
        self.active.deinit();
        self.loaded.deinit();
    }

    /// Passes `value` (a `ty`) to the instance's input `name`, if one is
    /// shown.
    pub fn setInput(self: *Loader, name: []const u8, ty: []const u8, value: *const anyopaque) void {
        const f = self.shown orelse return;
        const inst = self.instance orelse return;
        if (f.set_input(f.ctx, inst, name, ty, value)) return;
        // Logged once per name and component.
        const bit = @as(u64, 1) << @intCast(std.hash.Wyhash.hash(@intFromPtr(f), name) % 64);
        if (self.warned & bit != 0) return;
        self.warned |= bit;
        log.warn("'{s}' has no input property '{s}' of type {s}", .{ f.name, name, ty });
    }

    fn settings(self: *Loader) Settings {
        return .{ .source = self.source.get(), .active = self.active.get() };
    }

    fn apply(self: *Loader, s: Settings) void {
        const wanted: Component = if (s.active) s.source else null;
        if (wanted == self.shown and (wanted == null) == (self.instance == null)) return;
        self.unload();
        const f = wanted orelse return;
        const inst = f.create(f.ctx, self.gpa) catch {
            log.err("out of memory creating '{s}'", .{f.name});
            return;
        };
        const root = f.root(f.ctx, inst);
        root.fillParent(self.gpa) catch {
            f.destroy(f.ctx, inst);
            log.err("out of memory creating '{s}'", .{f.name});
            return;
        };
        self.instance = inst;
        self.shown = f;
        self.warned = 0;
        self.created.call(.{});
        self.item.appendChild(root);
        self.loaded.set(true);
    }

    fn unload(self: *Loader) void {
        const f = self.shown orelse return;
        if (self.instance) |inst| {
            const root = f.root(f.ctx, inst);
            if (root.parent == &self.item) root.removeFromParent();
            f.destroy(f.ctx, inst);
        }
        self.instance = null;
        self.shown = null;
        if (self.loaded.getUntracked()) self.loaded.set(false);
    }

    const vtable: item_mod.ItemVTable = .{ .name = "Loader" };
};

// ---- Tests ----

const testing = std.testing;
const core = @import("core.zig");

/// A component of a Rectangle with an input `label` (string) and `n`
/// (int), as generated code makes them.
const Card = struct {
    rect: core.items.Rectangle = .{},
    label: Property([]const u8) = .init(""),
    n: Property(i32) = .init(0),
    gpa: Allocator,

    var alive: usize = 0;
    var made: usize = 0;

    const factory: ComponentFactory = .{ .name = "Card", .create = create, .destroy = destroy, .root = root, .set_input = setInput };

    fn create(_: ?*anyopaque, gpa: Allocator) Allocator.Error!*anyopaque {
        const self = try gpa.create(Card);
        self.* = .{ .gpa = gpa };
        alive += 1;
        made += 1;
        return self;
    }
    fn destroy(_: ?*anyopaque, p: *anyopaque) void {
        const self: *Card = @ptrCast(@alignCast(p));
        self.rect.deinit();
        self.label.deinit();
        self.n.deinit();
        alive -= 1;
        self.gpa.destroy(self);
    }
    fn root(_: ?*anyopaque, p: *anyopaque) *Item {
        const self: *Card = @ptrCast(@alignCast(p));
        return &self.rect.item;
    }
    fn setInput(_: ?*anyopaque, p: *anyopaque, name: []const u8, ty: []const u8, value: *const anyopaque) bool {
        const self: *Card = @ptrCast(@alignCast(p));
        if (std.mem.eql(u8, name, "label") and std.mem.eql(u8, ty, "string")) {
            self.label.set(@as(*const []const u8, @ptrCast(@alignCast(value))).*);
            return true;
        }
        if (std.mem.eql(u8, name, "n") and std.mem.eql(u8, ty, "int")) {
            self.n.set(@as(*const i32, @ptrCast(@alignCast(value))).*);
            return true;
        }
        return false;
    }
};

const Other = struct {
    const factory: ComponentFactory = .{ .name = "Other", .create = Card.create, .destroy = Card.destroy, .root = Card.root, .set_input = none };
    fn none(_: ?*anyopaque, _: *anyopaque, _: []const u8, _: []const u8, _: *const anyopaque) bool {
        return false;
    }
};

test "a loader shows the component its source names, sized to it, and replaces it" {
    var l: Loader = undefined;
    l.init(testing.allocator);
    defer l.deinit();
    l.item.setGeometry(.{ .width = 80, .height = 30 });
    try testing.expect(!l.loaded.get());

    l.source.set(&Card.factory);
    core.runChangeHandlers();
    try testing.expect(l.loaded.get());
    try testing.expectEqual(@as(usize, 1), Card.alive);
    const card: *Card = @ptrCast(@alignCast(l.instance.?));
    try testing.expectEqual(@as(f32, 80), card.rect.item.width.get());
    try testing.expectEqual(&l.item, card.rect.item.parent.?);

    const label: []const u8 = "hello";
    l.setInput("label", "string", @ptrCast(&label));
    try testing.expectEqualStrings("hello", card.label.get());
    const wrong: f32 = 1;
    l.setInput("n", "float", @ptrCast(&wrong)); // logged, not set
    try testing.expectEqual(@as(i32, 0), card.n.get());

    const made_before = Card.made;
    l.source.set(&Other.factory);
    core.runChangeHandlers();
    try testing.expectEqual(@as(usize, 1), Card.alive); // the old one went
    // Another instance (perhaps where the old one was).
    try testing.expectEqual(made_before + 1, Card.made);

    l.active.set(false);
    core.runChangeHandlers();
    try testing.expect(!l.loaded.get());
    try testing.expectEqual(@as(usize, 0), Card.alive);
    try testing.expect(l.item.first_child == null);
}
