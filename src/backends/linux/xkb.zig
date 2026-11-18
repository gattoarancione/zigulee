// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The keyboard, with libxkbcommon (loaded at run time: every Wayland
//! desktop has it, and most Linux systems): a keymap (the compositor's, or
//! one from layout names) turns key codes into keysyms and text, with the
//! layout's levels (Shift, AltGr), Caps Lock and the locale's compose
//! sequences (dead keys: ´ then e). Used by the Wayland and KMS backends.

const std = @import("std");
const c = std.c;

const log = std.log.scoped(.zigulee_xkb);

const Context = opaque {};
const Keymap = opaque {};
const State = opaque {};
const ComposeTable = opaque {};
const ComposeState = opaque {};

pub const RuleNames = extern struct {
    rules: ?[*:0]const u8 = null,
    model: ?[*:0]const u8 = null,
    layout: ?[*:0]const u8 = null,
    variant: ?[*:0]const u8 = null,
    options: ?[*:0]const u8 = null,
};

const Fns = struct {
    xkb_context_new: *const fn (flags: c_int) callconv(.c) ?*Context,
    xkb_context_unref: *const fn (*Context) callconv(.c) void,
    xkb_keymap_new_from_string: *const fn (*Context, [*:0]const u8, format: c_int, flags: c_int) callconv(.c) ?*Keymap,
    xkb_keymap_new_from_names: *const fn (*Context, *const RuleNames, flags: c_int) callconv(.c) ?*Keymap,
    xkb_keymap_unref: *const fn (*Keymap) callconv(.c) void,
    xkb_keymap_key_repeats: *const fn (*Keymap, key: u32) callconv(.c) c_int,
    xkb_state_new: *const fn (*Keymap) callconv(.c) ?*State,
    xkb_state_unref: *const fn (*State) callconv(.c) void,
    xkb_state_update_mask: *const fn (*State, u32, u32, u32, u32, u32, u32) callconv(.c) c_int,
    xkb_state_update_key: *const fn (*State, key: u32, direction: c_int) callconv(.c) c_int,
    xkb_state_key_get_one_sym: *const fn (*State, key: u32) callconv(.c) u32,
    xkb_state_key_get_utf8: *const fn (*State, key: u32, buf: [*]u8, size: usize) callconv(.c) c_int,
    xkb_state_mod_name_is_active: *const fn (*State, name: [*:0]const u8, kind: c_int) callconv(.c) c_int,
    xkb_keysym_to_utf8: *const fn (sym: u32, buf: [*]u8, size: usize) callconv(.c) c_int,
};

const ComposeFns = struct {
    xkb_compose_table_new_from_locale: *const fn (*Context, [*:0]const u8, flags: c_int) callconv(.c) ?*ComposeTable,
    xkb_compose_table_unref: *const fn (*ComposeTable) callconv(.c) void,
    xkb_compose_state_new: *const fn (*ComposeTable, flags: c_int) callconv(.c) ?*ComposeState,
    xkb_compose_state_unref: *const fn (*ComposeState) callconv(.c) void,
    xkb_compose_state_feed: *const fn (*ComposeState, sym: u32) callconv(.c) c_int,
    xkb_compose_state_get_status: *const fn (*ComposeState) callconv(.c) c_int,
    xkb_compose_state_get_utf8: *const fn (*ComposeState, buf: [*]u8, size: usize) callconv(.c) c_int,
    xkb_compose_state_reset: *const fn (*ComposeState) callconv(.c) void,
};

fn load(comptime T: type, lib: *anyopaque) ?T {
    var fns: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        @field(fns, f.name) = @ptrCast(@alignCast(c.dlsym(lib, f.name ++ "") orelse return null));
    }
    return fns;
}

const mods_effective = 1 << 3;
const compose_composing = 1;
const compose_composed = 2;
const compose_cancelled = 3;

/// What a key press produced.
pub const Key = struct {
    /// The keysym, without modifiers' effect on text (for special keys and
    /// shortcuts).
    sym: u32,
    /// The text it types (UTF-8), if any.
    text: []const u8,
};

pub const Keyboard = struct {
    fns: Fns,
    compose_fns: ?ComposeFns,
    context: *Context,
    keymap: ?*Keymap = null,
    state: ?*State = null,
    compose_table: ?*ComposeTable = null,
    compose: ?*ComposeState = null,
    buf: [64]u8 = undefined,

    /// Null if libxkbcommon is not there.
    pub fn init() ?Keyboard {
        const lib = c.dlopen("libxkbcommon.so.0", .{ .LAZY = true }) orelse {
            log.info("libxkbcommon not found: no keyboard input", .{});
            return null;
        };
        const fns = load(Fns, lib) orelse return null;
        const context = fns.xkb_context_new(0) orelse return null;
        var k: Keyboard = .{ .fns = fns, .compose_fns = load(ComposeFns, lib), .context = context };
        // Compose sequences of the user's locale.
        if (k.compose_fns) |cf| {
            const locale = for ([_][*:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
                if (c.getenv(name)) |v| if (v[0] != 0) break v;
            } else "C";
            if (cf.xkb_compose_table_new_from_locale(context, locale, 0)) |table| {
                k.compose_table = table;
                k.compose = cf.xkb_compose_state_new(table, 0);
            }
        }
        return k;
    }

    pub fn deinit(k: *Keyboard) void {
        k.dropKeymap();
        if (k.compose_fns) |cf| {
            if (k.compose) |s| cf.xkb_compose_state_unref(s);
            if (k.compose_table) |t| cf.xkb_compose_table_unref(t);
        }
        k.fns.xkb_context_unref(k.context);
    }

    fn dropKeymap(k: *Keyboard) void {
        if (k.state) |s| k.fns.xkb_state_unref(s);
        if (k.keymap) |m| k.fns.xkb_keymap_unref(m);
        k.state = null;
        k.keymap = null;
    }

    /// The compositor's keymap (text, XKB v1 format).
    pub fn setKeymap(k: *Keyboard, text: [*:0]const u8) void {
        k.dropKeymap();
        k.keymap = k.fns.xkb_keymap_new_from_string(k.context, text, 1, 0) orelse {
            log.warn("could not read the keymap", .{});
            return;
        };
        k.state = k.fns.xkb_state_new(k.keymap.?);
    }

    /// A keymap from layout names (null ones: the `XKB_DEFAULT_*`
    /// environment variables, else the system's default).
    pub fn setKeymapNames(k: *Keyboard, names: RuleNames) bool {
        k.dropKeymap();
        k.keymap = k.fns.xkb_keymap_new_from_names(k.context, &names, 0) orelse return false;
        k.state = k.fns.xkb_state_new(k.keymap.?);
        return k.state != null;
    }

    /// A key went down or up (evdev code): the modifiers' state follows
    /// (when there is no compositor to tell it).
    pub fn updateKey(k: *Keyboard, evdev_code: u32, pressed: bool) void {
        if (k.state) |s| _ = k.fns.xkb_state_update_key(s, evdev_code + 8, @intFromBool(pressed));
    }

    pub fn updateModifiers(k: *Keyboard, depressed: u32, latched: u32, locked: u32, group: u32) void {
        if (k.state) |s| _ = k.fns.xkb_state_update_mask(s, depressed, latched, locked, 0, 0, group);
    }

    pub fn modifierActive(k: *Keyboard, name: [*:0]const u8) bool {
        const s = k.state orelse return false;
        return k.fns.xkb_state_mod_name_is_active(s, name, mods_effective) > 0;
    }

    pub fn repeats(k: *Keyboard, evdev_code: u32) bool {
        const m = k.keymap orelse return false;
        return k.fns.xkb_keymap_key_repeats(m, evdev_code + 8) != 0;
    }

    /// A key pressed (evdev code): its keysym and text, through compose
    /// sequences (a dead key alone types nothing).
    pub fn press(k: *Keyboard, evdev_code: u32) Key {
        const s = k.state orelse return .{ .sym = 0, .text = "" };
        const code = evdev_code + 8;
        const sym = k.fns.xkb_state_key_get_one_sym(s, code);
        if (k.compose) |cs| {
            const cf = k.compose_fns.?;
            if (cf.xkb_compose_state_feed(cs, sym) == 1) { // accepted
                switch (cf.xkb_compose_state_get_status(cs)) {
                    compose_composing => return .{ .sym = sym, .text = "" },
                    compose_composed => {
                        const n = cf.xkb_compose_state_get_utf8(cs, &k.buf, k.buf.len);
                        cf.xkb_compose_state_reset(cs);
                        return .{ .sym = sym, .text = k.buf[0..@intCast(@max(0, @min(n, k.buf.len - 1)))] };
                    },
                    compose_cancelled => {
                        cf.xkb_compose_state_reset(cs);
                        return .{ .sym = sym, .text = "" };
                    },
                    else => {},
                }
            }
        }
        const n = k.fns.xkb_state_key_get_utf8(s, code, &k.buf, k.buf.len);
        return .{ .sym = sym, .text = k.buf[0..@intCast(@max(0, @min(n, k.buf.len - 1)))] };
    }

    /// The keysym of a key, without composing (releases, shortcuts).
    pub fn keysym(k: *Keyboard, evdev_code: u32) u32 {
        const s = k.state orelse return 0;
        return k.fns.xkb_state_key_get_one_sym(s, evdev_code + 8);
    }
};
