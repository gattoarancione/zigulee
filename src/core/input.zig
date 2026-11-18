// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Input event types.

const geometry = @import("geometry.zig");
const Point = geometry.Point;

pub const PointerButton = enum { left, right, middle, other };

/// What a `TouchArea`'s `pointer_event` tells (`PointerEvent` in `.zge`):
/// a button pressed (`down`) or released (`up`) over it, the pointer
/// moving over it or while pressed (`move`), or a press taken from it
/// (`cancel`: another element took the drag).
pub const TouchAreaEvent = struct {
    kind: Kind,
    button: PointerButton = .left,
    /// The keys held at the press.
    modifiers: Modifiers = .{},

    pub const Kind = enum { down, up, move, cancel };
};

/// A pointer event. Positions are relative to the item receiving the event
/// (the window translates them while dispatching).
pub const PointerEvent = union(enum) {
    pressed: struct { position: Point, button: PointerButton = .left, modifiers: Modifiers = .{} },
    released: struct { position: Point, button: PointerButton = .left },
    moved: struct { position: Point },
    wheel: struct { position: Point, delta: Point },
    /// The pointer left the item (or the window).
    exit,

    pub fn position(self: PointerEvent) ?Point {
        return switch (self) {
            .pressed => |e| e.position,
            .released => |e| e.position,
            .moved => |e| e.position,
            .wheel => |e| e.position,
            .exit => null,
        };
    }

    /// The same event with its position moved by `-offset`.
    /// The same event at `p`.
    pub fn at(self: PointerEvent, p: Point) PointerEvent {
        var e = self;
        switch (e) {
            .pressed => |*x| x.position = p,
            .released => |*x| x.position = p,
            .moved => |*x| x.position = p,
            .wheel => |*x| x.position = p,
            .exit => {},
        }
        return e;
    }

    pub fn relativeTo(self: PointerEvent, offset: Point) PointerEvent {
        var e = self;
        switch (e) {
            .pressed => |*p| p.position = p.position.sub(offset),
            .released => |*p| p.position = p.position.sub(offset),
            .moved => |*p| p.position = p.position.sub(offset),
            .wheel => |*p| p.position = p.position.sub(offset),
            .exit => {},
        }
        return e;
    }
};

pub const InputEventResult = enum {
    /// Handled; stop propagation.
    accepted,
    /// Not handled; offer it to the items below.
    ignored,
    /// Handled, and send all further pointer events to this item until it
    /// returns something else (a drag or press in progress).
    grab,
};

/// What an item's `inputEventFilter` decides before its children see an
/// event.
pub const InputEventFilterResult = enum {
    /// Children first; if none handles it, the item itself.
    forward,
    /// Children only.
    forward_and_ignore,
    /// Like `forward`, and if a child grabs the pointer, keep filtering the
    /// grabbed events: returning `intercept` later steals the grab (the
    /// child receives `exit`).
    forward_and_intercept_grab,
    /// The item only; children do not see the event.
    intercept,
};

pub const Modifiers = packed struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    meta: bool = false,
};

pub const KeyEventKind = enum { pressed, released };

/// The pointer's shape over an item (`mouse-cursor`); the backend shows the
/// one the window asks for (`Window.mouseCursor`).
pub const MouseCursor = enum {
    default,
    none,
    help,
    pointer,
    progress,
    wait,
    crosshair,
    text,
    move,
    not_allowed,
    grab,
    grabbing,
    col_resize,
    row_resize,
    ew_resize,
    ns_resize,
    nesw_resize,
    nwse_resize,
};

/// A key event. `text` is UTF-8; special keys use the codes in `Key`.
pub const KeyEvent = struct {
    text: []const u8,
    modifiers: Modifiers = .{},
    repeat: bool = false,
};

/// `reject` is first so an unhandled callback (zero value) rejects.
pub const EventResult = enum { reject, accept };

pub const FocusEvent = enum { focus_in, focus_out };

/// Text of special keys (same private-use code points as Slint).
pub const Key = struct {
    pub const backspace = "\u{8}";
    pub const tab = "\t";
    pub const @"return" = "\n";
    pub const escape = "\u{1b}";
    pub const back_tab = "\u{19}";
    pub const delete = "\u{7f}";
    pub const space = " ";
    pub const up_arrow = "\u{F700}";
    pub const down_arrow = "\u{F701}";
    pub const left_arrow = "\u{F702}";
    pub const right_arrow = "\u{F703}";
    pub const home = "\u{F729}";
    pub const end = "\u{F72B}";
    pub const page_up = "\u{F72C}";
    pub const page_down = "\u{F72D}";
};
