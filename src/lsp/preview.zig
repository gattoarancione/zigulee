// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The live preview inside the editor: the language server interprets the
//! document being edited (unsaved text included), renders it with the
//! software renderer and sends frames as PNG images; the editor sends input
//! back. There are no threads: each frame says when the next one is due
//! (animations, timers) and the editor asks for it then.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const interp = @import("zigulee-interpreter");
const compiler = interp.compiler;

const log = std.log.scoped(.zigulee_preview);

pub const Frame = struct {
    /// Logical size of the UI, and physical pixels per logical pixel.
    width: f32,
    height: f32,
    scale: f32,
    /// The changed areas, in physical pixels (none: nothing changed).
    patches: []const Patch = &.{},
    /// Milliseconds until the next frame is due (animations, timers).
    wakeMs: ?u32 = null,
    /// Compiler errors of the current text (the last good version keeps
    /// running).
    errors: ?[]const u8 = null,
    title: []const u8 = "",
    component: []const u8 = "",
    /// The pointer's shape, as a CSS cursor (the `.zge` names are CSS's).
    cursor: []const u8 = "default",
};

/// A changed area of the frame and its pixels as a PNG (base64).
pub const Patch = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    png: []const u8,
};

pub const Input = union(enum) {
    press: Pointer,
    release: Pointer,
    move: Pointer,
    wheel: struct { x: f32, y: f32, dx: f32, dy: f32 },
    exit,
    key: struct { text: []const u8, modifiers: core.input.Modifiers = .{}, released: bool = false },
    /// Only lets time pass.
    tick,

    pub const Pointer = struct { x: f32, y: f32, button: core.input.PointerButton = .left, modifiers: core.input.Modifiers = .{} };
};

/// The fonts previews use (`font-family: "Inter"` and `"JetBrains Mono"`).
const Fonts = struct {
    regular: zigulee.Font,
    bold: zigulee.Font,
    mono: zigulee.Font,

    fn load() !Fonts {
        return .{
            .regular = try .init(@embedFile("inter_regular")),
            .bold = try .init(@embedFile("inter_bold")),
            .mono = try .init(@embedFile("jetbrains_mono")),
        };
    }

    fn register(f: *const Fonts, w: *core.Window) Allocator.Error!void {
        w.default_font.set(&f.regular);
        try w.registerFont("Inter", 400, &f.regular);
        try w.registerFont("Inter", 700, &f.bold);
        try w.registerFont("JetBrains Mono", 400, &f.mono);
        // Box drawing, blocks and other symbols Inter lacks.
        try w.addFallbackFont(&f.mono);
    }
};

const PixelRect = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    fn isEmpty(r: PixelRect) bool {
        return r.x1 <= r.x0 or r.y1 <= r.y0;
    }

    fn join(a: PixelRect, b: PixelRect) PixelRect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
    }

    const empty: PixelRect = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
};

pub const Preview = struct {
    gpa: Allocator,
    fonts: ?Fonts = null,
    io: std.Io,
    /// Where the document's files are read from (open documents first).
    loader: compiler.Loader,
    path: []u8,
    component: ?[]u8 = null,
    style: []const u8,
    scale: f32 = 1,
    program: ?*interp.Program = null,
    instance: ?*interp.Instance = null,
    errors: ?[]u8 = null,
    renderer: zigulee.software.Renderer(core.Rgba8),
    framebuffer: []core.Rgba8 = &.{},
    fb_width: u32 = 0,
    fb_height: u32 = 0,
    full: bool = true,
    selected: ?interp.ElementRef = null,
    /// Where the highlight was drawn in the last frame (physical pixels).
    last_highlight: ?PixelRect = null,
    /// Where the selection is in the source, to find it again after a
    /// reload.
    selected_source: ?struct { file: u16, offset: u32 } = null,

    pub fn create(gpa: Allocator, io: std.Io, loader: compiler.Loader, path: []const u8, style: []const u8) Allocator.Error!*Preview {
        const p = try gpa.create(Preview);
        p.* = .{ .gpa = gpa, .io = io, .loader = loader, .path = try gpa.dupe(u8, path), .style = style, .renderer = .init(gpa) };
        p.fonts = Fonts.load() catch |err| blk: {
            log.err("cannot load the bundled fonts: {t}", .{err});
            break :blk null;
        };
        return p;
    }

    pub fn destroy(p: *Preview) void {
        p.dropProgram();
        if (p.errors) |e| p.gpa.free(e);
        if (p.component) |c| p.gpa.free(c);
        p.renderer.deinit();
        p.gpa.free(p.framebuffer);
        p.gpa.free(p.path);
        p.gpa.destroy(p);
    }

    fn dropProgram(p: *Preview) void {
        p.selected = null;
        if (p.instance) |i| i.destroy();
        if (p.program) |prog| prog.destroy();
        p.instance = null;
        p.program = null;
    }

    pub fn setComponent(p: *Preview, name: ?[]const u8) Allocator.Error!void {
        if (p.component) |c| p.gpa.free(c);
        p.component = if (name) |n| try p.gpa.dupe(u8, n) else null;
    }

    /// Interprets `source` (the document's current text). On errors, the
    /// previous version keeps running and `errors` says what is wrong.
    pub fn load(p: *Preview, source: []const u8) Allocator.Error!void {
        if (p.errors) |e| p.gpa.free(e);
        p.errors = null;
        const loaded = try interp.Program.load(p.gpa, p.path, source, .{ .loader = p.loader, .style = p.style });
        const prog = switch (loaded) {
            .errors => |text| {
                p.errors = text;
                return;
            },
            .program => |prog| prog,
        };
        const comp = (if (p.component) |name| prog.component(name) else prog.mainComponent()) orelse {
            prog.destroy();
            p.errors = try std.fmt.allocPrint(p.gpa, "no component to preview: export a component that inherits Window", .{});
            return;
        };
        if (!comp.showsWindow()) {
            prog.destroy();
            p.errors = try std.fmt.allocPrint(p.gpa, "{s} does not inherit Window", .{comp.name});
            return;
        }
        const inst = prog.create(comp) catch |err| {
            prog.destroy();
            return err;
        };
        if (p.fonts) |*f| try f.register(inst.window().?);
        if (p.instance) |old| carryOver(old, inst);
        p.dropProgram();
        p.program = prog;
        p.instance = inst;
        p.full = true;
        // Find the selection again.
        if (p.selected_source) |src| p.selected = interp.Inspect.elementAtSource(inst, src.file, src.offset);
    }

    /// Keeps `in` and `in-out` property values across reloads (except
    /// strings, which belong to the old program).
    fn carryOver(old: *interp.Instance, new: *interp.Instance) void {
        if (!std.mem.eql(u8, old.comp.name, new.comp.name)) return;
        for (old.comp.props.items, 0..) |op, i| {
            if (op.visibility != .in and op.visibility != .in_out) continue;
            if (op.ty == .model or op.ty == .structure or op.ty == .enumeration) continue;
            for (new.comp.props.items, 0..) |np, j| if (std.mem.eql(u8, op.name, np.name)) {
                if (!op.ty.eql(np.ty) or (np.visibility != .in and np.visibility != .in_out)) break;
                const v = old.props[i].getUntracked();
                if (v != .string) new.props[j].set(v);
                break;
            };
        }
    }

    pub fn window(p: *Preview) ?*core.Window {
        const inst = p.instance orelse return null;
        return inst.window();
    }

    pub fn componentNames(p: *Preview, arena: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        const prog = p.program orelse return out.items;
        var comps: std.ArrayList(*compiler.codegen.Comp) = .empty;
        try prog.exportedComponents(&comps, arena);
        for (comps.items) |c| if (c.showsWindow()) try out.append(arena, c.name);
        return out.items;
    }

    pub fn handleInput(p: *Preview, input: Input) void {
        const w = p.window() orelse return;
        switch (input) {
            .press => |e| w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = e.x, .y = e.y }, .button = e.button, .modifiers = e.modifiers } }),
            .release => |e| w.dispatchPointer(.{ .released = .{ .position = .{ .x = e.x, .y = e.y }, .button = e.button } }),
            .move => |e| w.dispatchPointer(.{ .moved = .{ .position = .{ .x = e.x, .y = e.y } } }),
            .wheel => |e| w.dispatchPointer(.{ .wheel = .{ .position = .{ .x = e.x, .y = e.y }, .delta = .{ .x = e.dx, .y = e.dy } } }),
            .exit => w.dispatchPointer(.exit),
            .key => |k| w.dispatchKey(if (k.released) .released else .pressed, .{ .text = k.text, .modifiers = k.modifiers }),
            .tick => {},
        }
    }

    fn nowMs(p: *Preview) u64 {
        return @intCast(@max(0, std.Io.Clock.awake.now(p.io).toMilliseconds()));
    }

    /// Advances time, runs change handlers and renders what changed.
    /// `arena` holds the frame's data.
    pub fn frame(p: *Preview, arena: Allocator) Allocator.Error!Frame {
        const now = p.nowMs();
        zigulee.updateTimersAndAnimations(now);
        zigulee.runChangeHandlers();
        var f: Frame = .{ .width = 0, .height = 0, .scale = p.scale, .errors = p.errors };
        const inst = p.instance orelse return f;
        const w = inst.window().?;
        const size = w.size();
        f.width = size.width;
        f.height = size.height;
        f.title = inst.windowTitle().get();
        f.component = inst.comp.name;
        f.cursor = try arena.dupe(u8, @tagName(w.mouseCursor()));
        std.mem.replaceScalar(u8, @constCast(f.cursor), '_', '-');
        const pw: u32 = @intFromFloat(@max(1, @ceil(size.width * p.scale)));
        const ph: u32 = @intFromFloat(@max(1, @ceil(size.height * p.scale)));
        if (pw != p.fb_width or ph != p.fb_height) {
            p.gpa.free(p.framebuffer);
            p.framebuffer = &.{};
            p.framebuffer = try p.gpa.alloc(core.Rgba8, @as(usize, pw) * ph);
            p.fb_width = pw;
            p.fb_height = ph;
            p.full = true;
        }
        p.renderer.scale_factor = p.scale;
        const full = p.full;
        const region = try p.renderer.renderWindow(w, .init(p.framebuffer, pw, ph), if (full) .full else .partial);
        p.full = false;

        // The changed areas, plus where the highlight is and was (it is
        // drawn on the copies sent, not in the framebuffer).
        var areas: std.ArrayList(PixelRect) = .empty;
        if (full) {
            try areas.append(arena, .{ .x0 = 0, .y0 = 0, .x1 = pw, .y1 = ph });
        } else for (region.slice()) |r| {
            try areas.append(arena, .{
                .x0 = @intFromFloat(@max(0, @floor(r.x))),
                .y0 = @intFromFloat(@max(0, @floor(r.y))),
                .x1 = @intFromFloat(@min(@as(f32, @floatFromInt(pw)), @ceil(r.x + r.width))),
                .y1 = @intFromFloat(@min(@as(f32, @floatFromInt(ph)), @ceil(r.y + r.height))),
            });
        }
        const highlight: ?PixelRect = if (p.selected) |sel| highlightRect(sel.item(), p.scale, pw, ph) else null;
        if (!full and !std.meta.eql(highlight, p.last_highlight)) {
            if (p.last_highlight) |old| try areas.append(arena, old);
            if (highlight) |new| try areas.append(arena, new);
        }
        p.last_highlight = highlight;
        var patches: std.ArrayList(Patch) = .empty;
        for (areas.items) |area| {
            if (area.isEmpty()) continue;
            const cw = area.x1 - area.x0;
            const ch = area.y1 - area.y0;
            const crop = try arena.alloc(core.Rgba8, @as(usize, cw) * ch);
            for (0..ch) |row| {
                const src = p.framebuffer[(area.y0 + row) * pw + area.x0 ..][0..cw];
                @memcpy(crop[row * cw ..][0..cw], src);
            }
            if (highlight) |hr| drawHighlight(crop, area, hr, p.scale);
            const png = try core.png.encode(arena, cw, ch, crop);
            const encoder = std.base64.standard.Encoder;
            const b64 = try arena.alloc(u8, encoder.calcSize(png.len));
            try patches.append(arena, .{ .x = area.x0, .y = area.y0, .w = cw, .h = ch, .png = encoder.encode(b64, png) });
        }
        f.patches = patches.items;
        // When to come back.
        if (core.hasActiveAnimations()) {
            f.wakeMs = 16;
        } else if (core.nextTimerDeadline()) |deadline| {
            f.wakeMs = @intCast(@min(deadline -| p.nowMs(), 60_000));
        }
        return f;
    }

    /// The item's area in physical pixels, within the frame.
    fn highlightRect(item: *core.Item, scale: f32, pw: u32, ph: u32) PixelRect {
        const pos = item.absolutePosition();
        const size = item.size();
        const clamp = struct {
            fn f(v: f32, max: u32) u32 {
                return @intFromFloat(std.math.clamp(v, 0, @as(f32, @floatFromInt(max))));
            }
        }.f;
        return .{
            .x0 = clamp(@floor(pos.x * scale), pw),
            .y0 = clamp(@floor(pos.y * scale), ph),
            .x1 = clamp(@ceil((pos.x + size.width) * scale), pw),
            .y1 = clamp(@ceil((pos.y + size.height) * scale), ph),
        };
    }

    /// Draws a 2px outline around `hr`, and a light tint inside, on the
    /// part of the frame `pixels` holds (`area`).
    fn drawHighlight(pixels: []core.Rgba8, area: PixelRect, hr: PixelRect, scale: f32) void {
        const w = area.x1 - area.x0;
        const border: u32 = @intFromFloat(@max(1, @round(2 * scale)));
        const accent: core.Rgba8 = .{ .r = 0x37, .g = 0x94, .b = 0xff, .a = 0xff };
        var y = @max(hr.y0, area.y0);
        while (y < @min(hr.y1, area.y1)) : (y += 1) {
            var x = @max(hr.x0, area.x0);
            while (x < @min(hr.x1, area.x1)) : (x += 1) {
                const px = &pixels[(y - area.y0) * w + (x - area.x0)];
                const edge = x < hr.x0 + border or x + border >= hr.x1 or y < hr.y0 + border or y + border >= hr.y1;
                if (edge) {
                    px.* = accent;
                } else {
                    // 12% tint.
                    px.r = @intCast((@as(u32, px.r) * 225 + @as(u32, accent.r) * 31) / 256);
                    px.g = @intCast((@as(u32, px.g) * 225 + @as(u32, accent.g) * 31) / 256);
                    px.b = @intCast((@as(u32, px.b) * 225 + @as(u32, accent.b) * 31) / 256);
                }
            }
        }
    }

    pub fn select(p: *Preview, ref: ?interp.ElementRef) void {
        p.selected = ref;
        p.selected_source = if (ref) |r| .{ .file = r.source().file, .offset = r.source().span.start } else null;
    }

    /// The elements under a point, outermost first.
    pub fn elementsAt(p: *Preview, x: f32, y: f32, arena: Allocator) Allocator.Error![]interp.ElementRef {
        var out: std.ArrayList(interp.ElementRef) = .empty;
        const inst = p.instance orelse return out.items;
        try interp.Inspect.elementsAt(inst, .{ .x = x, .y = y }, arena, &out);
        return out.items;
    }

    pub fn elementAtSource(p: *Preview, file: u16, offset: u32) ?interp.ElementRef {
        const inst = p.instance orelse return null;
        return interp.Inspect.elementAtSource(inst, file, offset);
    }

    /// The source files of the program: names as given to the compiler,
    /// and their text.
    pub fn files(p: *Preview) []const compiler.File {
        const prog = p.program orelse return &.{};
        return prog.gen.diags.files.items;
    }
};
