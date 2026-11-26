// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The C API's window part (include/zigulee.h): the event loop, windows
//! and input, rendering (software and OpenGL), fonts and translations.
//! They work on a `Host` (what a `zigulee_instance *` points to): a window,
//! made by the interpreter (src/c_api.zig) or by a compiled component's
//! bindings (`zgec c`), without needing the interpreter.

const std = @import("std");
const zigulee = @import("zigulee");
const core = zigulee.core;

/// All the library's memory (a leak-checking allocator in tests).
pub var gpa: std.mem.Allocator = std.heap.smp_allocator;

pub const Status = i32;
pub const ok: Status = 0;
pub const error_compile: Status = 1;
pub const error_not_found: Status = 2;
pub const error_type: Status = 3;
pub const error_out_of_memory: Status = 4;
pub const error_invalid: Status = 5;
pub const error_unsupported: Status = 6;

pub const abi_version: u32 = 1;

/// `zigulee_string`.
pub const CString = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    pub fn of(s: []const u8) CString {
        return .{ .ptr = s.ptr, .len = s.len };
    }

    pub fn slice(s: CString) []const u8 {
        const p = s.ptr orelse return "";
        return p[0..s.len];
    }
};

pub const Rect = extern struct { x: i32, y: i32, width: i32, height: i32 };

pub const PointerEvent = extern struct {
    kind: i32,
    button: i32,
    x: f32,
    y: f32,
    delta_x: f32,
    delta_y: f32,
    modifiers: u32,
    reserved: i32,
};

comptime {
    // The layouts the header promises.
    std.debug.assert(@sizeOf(CString) == 2 * @sizeOf(usize));
    std.debug.assert(@sizeOf(PointerEvent) == 32);
    std.debug.assert(@sizeOf(Rect) == 16);
}

/// What a `zigulee_instance *` points to: a window to drive and render.
pub const Host = struct {
    /// Null for an interpreted component that is not a window (window
    /// functions then do nothing).
    window: ?*core.Window,
    kind: Kind,
    renderer: ?zigulee.software.Renderer(core.Rgba8) = null,

    pub const Kind = enum { interpreted, compiled };

    pub fn deinit(self: *Host) void {
        if (self.renderer) |*r| r.deinit();
    }
};

/// Memory for values set from C (their strings, struct fields): what one
/// use allocates stays valid until the second-next use (the value replaced
/// may still be read while the new one propagates).
pub const Store = struct {
    arenas: [2]std.heap.ArenaAllocator,
    current: u1 = 0,

    pub fn init() Store {
        return .{ .arenas = .{ .init(gpa), .init(gpa) } };
    }

    pub fn deinit(self: *Store) void {
        for (&self.arenas) |*a| a.deinit();
    }

    /// The memory for the next value.
    pub fn next(self: *Store) std.mem.Allocator {
        self.current +%= 1;
        _ = self.arenas[self.current].reset(.retain_capacity);
        return self.arenas[self.current].allocator();
    }
};

pub export fn zigulee_abi_version() u32 {
    return abi_version;
}

// ---- The event loop ----

pub export fn zigulee_update(now_ms: u64) void {
    core.updateTimersAndAnimations(now_ms);
    core.runChangeHandlers();
}

pub export fn zigulee_has_active_animations() bool {
    return core.hasActiveAnimations();
}

pub export fn zigulee_next_timer_deadline(out_ms: *u64) bool {
    out_ms.* = core.nextTimerDeadline() orelse return false;
    return true;
}

pub export fn zigulee_window_set_size(instance: *Host, width: f32, height: f32) void {
    const w = instance.window orelse return;
    w.setSize(.{ .width = width, .height = height });
}

pub export fn zigulee_window_size(instance: *Host, width: ?*f32, height: ?*f32) void {
    const w = instance.window orelse return;
    const s = w.size();
    if (width) |p| p.* = s.width;
    if (height) |p| p.* = s.height;
}

pub export fn zigulee_window_needs_redraw(instance: *Host) bool {
    const w = instance.window orelse return false;
    return w.redraw_requested or core.hasActiveAnimations();
}

fn modifiersOf(m: u32) core.input.Modifiers {
    return .{ .shift = m & 1 != 0, .control = m & 2 != 0, .alt = m & 4 != 0, .meta = m & 8 != 0 };
}

pub export fn zigulee_window_pointer(instance: *Host, event: *const PointerEvent) void {
    const w = instance.window orelse return;
    const p: core.Point = .{ .x = event.x, .y = event.y };
    const button: core.input.PointerButton = switch (event.button) {
        0 => .left,
        1 => .right,
        2 => .middle,
        else => .other,
    };
    w.dispatchPointer(switch (event.kind) {
        0 => .{ .pressed = .{ .position = p, .button = button, .modifiers = modifiersOf(event.modifiers) } },
        1 => .{ .released = .{ .position = p, .button = button } },
        2 => .{ .moved = .{ .position = p } },
        3 => .{ .wheel = .{ .position = p, .delta = .{ .x = event.delta_x, .y = event.delta_y } } },
        else => .exit,
    });
    core.runChangeHandlers();
}

pub export fn zigulee_window_key(instance: *Host, pressed: bool, text: [*:0]const u8, modifiers: u32, repeat: bool) void {
    const w = instance.window orelse return;
    w.dispatchKey(if (pressed) .pressed else .released, .{ .text = std.mem.span(text), .modifiers = modifiersOf(modifiers), .repeat = repeat });
    core.runChangeHandlers();
}

pub export fn zigulee_window_render_rgba(instance: *Host, pixels: [*]u8, width: u32, height: u32, stride: u32, scale: f32, full: bool, dirty: ?*Rect) Status {
    const w = instance.window orelse return error_not_found;
    if (stride < width) return error_invalid;
    const r = if (instance.renderer) |*r| r else blk: {
        instance.renderer = .init(gpa);
        break :blk &instance.renderer.?;
    };
    r.scale_factor = if (scale > 0) scale else 1;
    const len = @as(usize, stride) * height;
    const canvas: zigulee.software.Canvas(core.Rgba8) = .{ .pixels = @as([*]core.Rgba8, @ptrCast(pixels))[0..len], .width = width, .height = height, .stride = stride };
    const region = r.renderWindow(w, canvas, if (full) .full else .partial) catch return error_out_of_memory;
    if (dirty) |d| {
        const b = region.boundingBox();
        d.* = .{ .x = @intFromFloat(b.x), .y = @intFromFloat(b.y), .width = @intFromFloat(b.width), .height = @intFromFloat(b.height) };
    }
    return ok;
}

// ---- Rendering with OpenGL ----

pub const GlRenderer = zigulee.gpu.gl.Renderer;
pub const GetProc = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*const anyopaque;

pub export fn zigulee_gl_renderer_create(get_proc: GetProc, user_data: ?*anyopaque, out: *?*GlRenderer) Status {
    out.* = null;
    const Loader = struct { f: GetProc, data: ?*anyopaque };
    const functions = zigulee.gpu.gl.Functions.load(Loader{ .f = get_proc, .data = user_data }, struct {
        fn f(l: Loader, name: [*:0]const u8) ?*const anyopaque {
            return l.f(l.data, name);
        }
    }.f) catch return error_unsupported;
    const r = gpa.create(GlRenderer) catch return error_out_of_memory;
    r.* = GlRenderer.init(gpa, functions) catch |err| {
        gpa.destroy(r);
        return switch (err) {
            error.OutOfMemory => error_out_of_memory,
            else => error_unsupported,
        };
    };
    out.* = r;
    return ok;
}

pub export fn zigulee_gl_renderer_destroy(renderer: ?*GlRenderer) void {
    const r = renderer orelse return;
    r.deinit();
    gpa.destroy(r);
}

pub export fn zigulee_window_render_gl(instance: *Host, renderer: *GlRenderer, framebuffer: u32, width: u32, height: u32, scale: f32) Status {
    const w = instance.window orelse return error_not_found;
    if (width == 0 or height == 0) return error_invalid;
    renderer.framebuffer = framebuffer;
    renderer.setScaleFactor(if (scale > 0) scale else 1);
    _ = renderer.renderWindow(w, width, height, .full) catch return error_out_of_memory;
    return ok;
}

pub export fn zigulee_window_render_gl_partial(instance: *Host, renderer: *GlRenderer, framebuffer: u32, width: u32, height: u32, scale: f32, full: bool, dirty: ?*Rect) Status {
    const w = instance.window orelse return error_not_found;
    if (width == 0 or height == 0) return error_invalid;
    renderer.framebuffer = framebuffer;
    renderer.setScaleFactor(if (scale > 0) scale else 1);
    const region = renderer.renderWindow(w, width, height, if (full) .full else .partial) catch return error_out_of_memory;
    if (dirty) |d| {
        const b = region.boundingBox();
        d.* = .{ .x = @intFromFloat(b.x), .y = @intFromFloat(b.y), .width = @intFromFloat(b.width), .height = @intFromFloat(b.height) };
    }
    return ok;
}

// ---- Fonts ----

pub const CFont = struct {
    data: []u8,
    font: zigulee.Font,
};

pub export fn zigulee_font_load(data: [*]const u8, len: usize, out: *?*CFont) Status {
    out.* = null;
    const f = gpa.create(CFont) catch return error_out_of_memory;
    f.data = gpa.dupe(u8, data[0..len]) catch {
        gpa.destroy(f);
        return error_out_of_memory;
    };
    f.font = zigulee.Font.init(f.data) catch {
        gpa.free(f.data);
        gpa.destroy(f);
        return error_invalid;
    };
    out.* = f;
    return ok;
}

pub export fn zigulee_font_destroy(font: ?*CFont) void {
    const f = font orelse return;
    gpa.free(f.data);
    gpa.destroy(f);
}

pub export fn zigulee_window_set_default_font(instance: *Host, font: ?*CFont) void {
    const w = instance.window orelse return;
    w.default_font.set(if (font) |f| &f.font else null);
}

pub export fn zigulee_window_register_font(instance: *Host, family: [*:0]const u8, weight: i32, font: *CFont) Status {
    const w = instance.window orelse return error_not_found;
    w.registerFont(std.mem.span(family), @intCast(std.math.clamp(weight, 1, 1000)), &font.font) catch return error_out_of_memory;
    return ok;
}

pub export fn zigulee_window_add_fallback_font(instance: *Host, font: *CFont) Status {
    const w = instance.window orelse return error_not_found;
    w.addFallbackFont(&font.font) catch return error_out_of_memory;
    return ok;
}

// ---- Translations ----

pub const CTranslations = struct {
    catalog: core.i18n.Catalog,
};

pub export fn zigulee_translations_load_po(data: [*]const u8, len: usize, out: *?*CTranslations) Status {
    out.* = null;
    const t = gpa.create(CTranslations) catch return error_out_of_memory;
    t.catalog = core.i18n.Catalog.parse(gpa, data[0..len]) catch |err| {
        gpa.destroy(t);
        return if (err == error.OutOfMemory) error_out_of_memory else error_invalid;
    };
    out.* = t;
    return ok;
}

pub export fn zigulee_translations_destroy(translations: ?*CTranslations) void {
    const t = translations orelse return;
    t.catalog.deinit();
    gpa.destroy(t);
}

pub export fn zigulee_set_translations(translations: ?*CTranslations) void {
    core.i18n.setTranslator(if (translations) |t| t.catalog.translator() else null);
    core.runChangeHandlers();
}
