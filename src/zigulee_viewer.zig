// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! `zigulee-viewer`: shows a `.zge` file in a window, interpreted, and
//! reloads it when it (or a file it uses) changes.
//!
//!     zigulee-viewer app.zge [--component Name] [--style fluent]
//!                          [--screenshot out.png]
//!
//! Errors are shown in the window until the file is fixed. On reload, the
//! values of `in` and `in-out` properties carry over. With --screenshot,
//! renders the first frames, saves them as a PNG and exits.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
/// zigulee-sdl3, or zigulee-macos with `-Dbackend=macos`.
const backend = @import("zigulee-backend");
const interp = @import("zigulee-interpreter");
const compiler = interp.compiler;

const log = std.log.scoped(.zigulee_viewer);

const Options = struct {
    path: []const u8,
    component: ?[]const u8 = null,
    style: []const u8 = compiler.std_widgets.default_style,
    screenshot: ?[]const u8 = null,
    /// A gettext catalog to show the translated texts.
    translation: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options: Options = .{ .path = "" };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--component") and i + 1 < args.len) {
            i += 1;
            options.component = args[i];
        } else if (std.mem.eql(u8, a, "--style") and i + 1 < args.len) {
            i += 1;
            options.style = args[i];
        } else if (std.mem.eql(u8, a, "--screenshot") and i + 1 < args.len) {
            i += 1;
            options.screenshot = args[i];
        } else if (std.mem.eql(u8, a, "--tr") and i + 1 < args.len) {
            i += 1;
            options.translation = args[i];
        } else if (a.len > 0 and a[0] != '-') {
            options.path = a;
        } else {
            std.debug.print("zigulee-viewer: unknown option '{s}'\n", .{a});
            return 2;
        }
    }
    if (options.path.len == 0) {
        std.debug.print("usage: zigulee-viewer file.zge [--component Name] [--style fluent] [--tr messages.po] [--screenshot out.png]\n", .{});
        return 2;
    }
    if (!compiler.std_widgets.isStyle(options.style)) {
        std.debug.print("zigulee-viewer: unknown style '{s}'\n", .{options.style});
        return 2;
    }

    // Settings and the application's folders go by the file's name.
    zigulee.core.paths.setApplicationName(std.fs.path.stem(options.path));
    interp.warnOnBindingLoops();
    var catalog: ?zigulee.core.i18n.Catalog = null;
    defer if (catalog) |*c| c.deinit();
    if (options.translation) |path| {
        const po = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.arena.allocator(), .limited(16 << 20)) catch |err| {
            std.debug.print("zigulee-viewer: cannot read {s}: {t}\n", .{ path, err });
            return 1;
        };
        catalog = zigulee.core.i18n.Catalog.parse(gpa, po) catch |err| {
            std.debug.print("zigulee-viewer: {s} is not a valid .po file ({t})\n", .{ path, err });
            return 1;
        };
        zigulee.core.i18n.setTranslator(catalog.?.translator());
    }
    var fonts: Fonts = try .init();
    var viewer: Viewer = .{ .gpa = gpa, .io = init.io, .options = options, .fonts = &fonts };
    defer viewer.deinit();
    try viewer.reload();

    try backend.init();
    defer backend.deinit();
    const title = try gpa.dupeZ(u8, viewer.title());
    defer gpa.free(title);
    const window = try backend.Window.create(gpa, viewer.ui(), .{
        .title = title,
        // Screenshots come from the software renderer's framebuffer.
        .renderer = if (options.screenshot != null) .software else .auto,
    });
    defer window.destroy();
    viewer.window = window;

    if (options.screenshot) |path| {
        for (0..30) |_| try window.step(20);
        const png = try core.png.encode(gpa, window.pixel_width, window.pixel_height, window.framebuffer);
        defer gpa.free(png);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = png });
        return if (viewer.current == .errors) 1 else 0;
    }

    var last_check = backend.now();
    while (!window.closed) {
        try window.step(poll_ms);
        if (backend.now() -| last_check < poll_ms) continue;
        last_check = backend.now();
        if (viewer.changed()) try viewer.reload();
    }
    return 0;
}

/// How often files are checked for changes.
const poll_ms = 250;

const Fonts = struct {
    regular: zigulee.Font,
    bold: zigulee.Font,
    mono: zigulee.Font,

    fn init() !Fonts {
        return .{
            .regular = try .init(@embedFile("inter_regular")),
            .bold = try .init(@embedFile("inter_bold")),
            .mono = try .init(@embedFile("jetbrains_mono")),
        };
    }

    fn register(f: *const Fonts, w: *core.Window) !void {
        w.default_font.set(&f.regular);
        try w.registerFont("Inter", 400, &f.regular);
        try w.registerFont("Inter", 700, &f.bold);
        try w.registerFont("JetBrains Mono", 400, &f.mono);
        // Box drawing, blocks and other symbols Inter lacks.
        try w.addFallbackFont(&f.mono);
    }
};

/// Reads files relative to the main file, remembering them to watch.
const Files = struct {
    gpa: Allocator,
    io: std.Io,
    dir: []const u8,
    used: std.ArrayList(Watched) = .empty,

    const Watched = struct { path: []u8, mtime: i96 };

    fn deinit(f: *Files) void {
        for (f.used.items) |w| f.gpa.free(w.path);
        f.used.deinit(f.gpa);
    }

    fn read(ctx: ?*anyopaque, arena: Allocator, path: []const u8) anyerror![]const u8 {
        const self: *Files = @ptrCast(@alignCast(ctx.?));
        const full = try std.fs.path.join(arena, &.{ self.dir, path });
        try self.watch(full);
        return std.Io.Dir.cwd().readFileAlloc(self.io, full, arena, .limited(64 << 20));
    }

    fn watch(self: *Files, path: []const u8) !void {
        for (self.used.items) |w| if (std.mem.eql(u8, w.path, path)) return;
        try self.used.append(self.gpa, .{ .path = try self.gpa.dupe(u8, path), .mtime = mtimeOf(self.io, path) });
    }

    fn changed(self: *Files) bool {
        for (self.used.items) |w| if (mtimeOf(self.io, w.path) != w.mtime) return true;
        return false;
    }
};

fn mtimeOf(io: std.Io, path: []const u8) i96 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return st.mtime.nanoseconds;
}

/// Compiler errors, shown in the window.
const ErrorView = struct {
    window: core.Window = undefined,
    header: core.items.Text = .{},
    text: core.items.Text = .{},

    fn init(self: *ErrorView, gpa: Allocator, fonts: *const Fonts, size: core.Size, message: []const u8) !void {
        self.* = .{};
        self.window.init(gpa, size);
        try fonts.register(&self.window);
        self.window.root.background.set(.color(.rgb(0x1e1e1e)));
        self.window.rootItem().appendChildren(&.{ &self.header.item, &self.text.item });
        self.header.text.set("Errors (fix the file to reload):");
        self.header.font_weight.set(700);
        self.header.font_size.set(15);
        self.header.color.set(.color(.rgb(0xf48771)));
        self.header.item.setGeometry(.{ .x = 16, .y = 12, .width = size.width - 32, .height = 24 });
        self.text.text.set(message);
        self.text.font.set(&fonts.mono);
        self.text.font_size.set(12);
        self.text.wrap.set(.word_wrap);
        self.text.color.set(.color(.rgb(0xd4d4d4)));
        self.text.item.setGeometry(.{ .x = 16, .y = 44, .width = size.width - 32, .height = size.height - 56 });
    }

    fn deinit(self: *ErrorView) void {
        self.window.deinit();
        self.header.deinit();
        self.text.deinit();
    }
};

const Viewer = struct {
    gpa: Allocator,
    io: std.Io,
    options: Options,
    fonts: *const Fonts,
    window: ?*backend.Window = null,
    current: Current = .none,

    const Current = union(enum) {
        none,
        app: App,
        errors: struct { view: *ErrorView, message: []u8, files: *Files },
    };

    const App = struct {
        program: *interp.Program,
        instance: *interp.Instance,
        files: *Files,
    };

    fn deinit(v: *Viewer) void {
        v.drop(v.current);
        v.current = .none;
    }

    fn drop(v: *Viewer, c: Current) void {
        switch (c) {
            .none => {},
            .app => |app| {
                app.instance.destroy();
                app.program.destroy();
                app.files.deinit();
                v.gpa.destroy(app.files);
            },
            .errors => |e| {
                e.view.deinit();
                v.gpa.destroy(e.view);
                v.gpa.free(e.message);
                e.files.deinit();
                v.gpa.destroy(e.files);
            },
        }
    }

    fn ui(v: *Viewer) *core.Window {
        return switch (v.current) {
            .app => |app| app.instance.window().?,
            .errors => |e| &e.view.window,
            .none => unreachable,
        };
    }

    fn title(v: *Viewer) []const u8 {
        return switch (v.current) {
            .app => |app| if (app.instance.windowTitle().get().len > 0) app.instance.windowTitle().get() else app.instance.comp.name,
            else => "zigulee-viewer",
        };
    }

    fn changed(v: *Viewer) bool {
        return switch (v.current) {
            .app => |app| app.files.changed(),
            .errors => |e| e.files.changed(),
            .none => true,
        };
    }

    fn reload(v: *Viewer) !void {
        const start = backend.now();
        const files = try v.gpa.create(Files);
        files.* = .{ .gpa = v.gpa, .io = v.io, .dir = std.fs.path.dirname(v.options.path) orelse "." };
        var keep_files = false;
        defer if (!keep_files) {
            files.deinit();
            v.gpa.destroy(files);
        };
        try files.watch(v.options.path);
        const size: core.Size = if (v.window) |w| w.ui.size() else .{ .width = 640, .height = 480 };

        const next: Current = blk: {
            const source = std.Io.Dir.cwd().readFileAlloc(v.io, v.options.path, v.gpa, .limited(16 << 20)) catch |err| {
                break :blk try v.errorView(files, size, try std.fmt.allocPrint(v.gpa, "cannot read {s}: {t}", .{ v.options.path, err }));
            };
            defer v.gpa.free(source);
            const loaded = try interp.Program.load(v.gpa, v.options.path, source, .{
                .loader = .{ .ctx = files, .readFn = Files.read },
                .style = v.options.style,
            });
            switch (loaded) {
                .errors => |text| break :blk try v.errorView(files, size, text),
                .program => |prog| {
                    errdefer prog.destroy();
                    const comp = (if (v.options.component) |name| prog.component(name) else prog.mainComponent()) orelse {
                        prog.destroy();
                        break :blk try v.errorView(files, size, try std.fmt.allocPrint(v.gpa, "{s}: no component to show{s}{s}", .{
                            v.options.path,
                            if (v.options.component != null) " named " else " (export a component that inherits Window)",
                            v.options.component orelse "",
                        }));
                    };
                    if (!comp.showsWindow()) {
                        // The message first: the name goes with the program.
                        const message = try std.fmt.allocPrint(v.gpa, "{s} does not inherit Window", .{comp.name});
                        prog.destroy();
                        break :blk try v.errorView(files, size, message);
                    }
                    const inst = try prog.create(comp);
                    try v.fonts.register(inst.window().?);
                    break :blk .{ .app = .{ .program = prog, .instance = inst, .files = files } };
                },
            }
        };
        keep_files = true;
        if (v.current == .app and next == .app) carryOver(v.current.app.instance, next.app.instance);
        const old = v.current;
        v.current = next;
        if (v.window) |w| try w.setUi(v.ui());
        v.drop(old);
        switch (v.current) {
            .app => |app| log.info("loaded {s} ({s}) in {d} ms", .{ v.options.path, app.instance.comp.name, backend.now() - start }),
            .errors => |e| std.debug.print("{s}", .{e.message}),
            .none => {},
        }
    }

    fn errorView(v: *Viewer, files: *Files, size: core.Size, message: []u8) !Current {
        const view = try v.gpa.create(ErrorView);
        errdefer v.gpa.destroy(view);
        try view.init(v.gpa, v.fonts, size, message);
        return .{ .errors = .{ .view = view, .message = message, .files = files } };
    }

    /// Keeps the values of `in` and `in-out` properties across a reload.
    fn carryOver(old: *interp.Instance, new: *interp.Instance) void {
        for (old.comp.props.items, 0..) |p, i| {
            if (p.visibility != .in and p.visibility != .in_out) continue;
            if (p.ty == .model or p.ty == .structure) continue;
            for (new.comp.props.items, 0..) |q, j| if (std.mem.eql(u8, p.name, q.name)) {
                if (!p.ty.eql(q.ty) or (q.visibility != .in and q.visibility != .in_out)) break;
                const v = old.props[i].get();
                // Strings point into the old program: keep only the others.
                if (v == .string) break;
                new.props[j].set(v);
                break;
            };
        }
    }
};
