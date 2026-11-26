// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Benchmarks with budgets: `zig build bench` (ReleaseFast).
//!
//!     zig build bench                 measure and compare with the budgets
//!     zig build bench -- --check      also fail if a budget is exceeded
//!     zig build bench -- <filter>     only the benchmarks whose name contains it
//!
//! On a board: `zig build bench-install -Dtarget=arm-linux-gnueabihf`
//! (say), then copy zig-out/bin/bench there and run it (`./bench
//! touchbar` for the frames of a small panel). The compiler and
//! interpreter benchmarks need examples/ in the directory it runs in, and
//! are skipped without it.
//!
//! The budgets are for a desktop computer (64-bit). The ROADMAP's targets:
//! re-evaluating bindings after a change in well under a millisecond, and
//! 60 fps software rendering on a Raspberry Pi, several times slower than a
//! desktop, so a full frame here must take a fraction of 16.7 ms. Other
//! budgets guard against regressions, with headroom over the measured
//! values. Memory is the heap in use, on 64-bit (see `zig build mcu-size`
//! for a 32-bit device). Times are the median of 7 batches; each batch
//! repeats the operation for at least 20 ms.

const std = @import("std");
const zigulee = @import("zigulee");
const core = zigulee.core;
const interp = @import("zigulee-interpreter");
const gallery = @import("gallery_ui");
const todo = @import("todo_ui");

/// fbdev's framebuffer code, where it builds (Linux, macOS).
pub const fb = if (@import("builtin").os.tag == .linux or @import("builtin").os.tag == .macos) @import("zigulee-fb") else struct {};

const font_bytes = @embedFile("inter_regular");
const gallery_source = @embedFile("gallery_source");
/// Reads the files the gallery uses (its images) from examples/: `zig
/// build bench` runs in the repository's root.
const example_files: interp.compiler.Loader = .{ .readFn = struct {
    fn read(_: ?*anyopaque, a: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
        const full = try std.fs.path.join(a, &.{ "examples", path });
        return std.Io.Dir.cwd().readFileAlloc(io, full, a, .limited(64 << 20));
    }
}.read };

var io: std.Io = undefined;

fn nowNs() i96 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

/// Nanoseconds per call of `f(ctx)`: the median of 7 batches.
fn measure(ctx: anytype, comptime f: fn (@TypeOf(ctx)) anyerror!void) !f64 {
    // Warm up, and find how many calls take at least 20 ms.
    var n: usize = 1;
    while (true) {
        const t0 = nowNs();
        for (0..n) |_| try f(ctx);
        const dt = nowNs() - t0;
        if (dt >= 20 * std.time.ns_per_ms) break;
        n *= 2;
    }
    var batches: [7]f64 = undefined;
    for (&batches) |*b| {
        const t0 = nowNs();
        for (0..n) |_| try f(ctx);
        b.* = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, @floatFromInt(n));
    }
    std.mem.sort(f64, &batches, {}, std.sort.asc(f64));
    return batches[3];
}

const Result = struct {
    name: []const u8,
    value: f64,
    budget: f64,
    unit: Unit,
};

const Unit = enum {
    ns,
    bytes,

    fn format(u: Unit, v: f64, buf: []u8) []const u8 {
        return switch (u) {
            .ns => if (v < 1000)
                std.fmt.bufPrint(buf, "{d:.0} ns", .{v}) catch ""
            else if (v < 1_000_000)
                std.fmt.bufPrint(buf, "{d:.1} us", .{v / 1000}) catch ""
            else
                std.fmt.bufPrint(buf, "{d:.2} ms", .{v / 1_000_000}) catch "",
            .bytes => if (v < 10 * 1024)
                std.fmt.bufPrint(buf, "{d:.0} B", .{v}) catch ""
            else
                std.fmt.bufPrint(buf, "{d:.1} KB", .{v / 1024}) catch "",
        };
    }
};

var results: std.ArrayList(Result) = .empty;
var filter: []const u8 = "";
var arena: std.mem.Allocator = undefined;

fn wanted(name: []const u8) bool {
    return std.mem.indexOf(u8, name, filter) != null;
}

fn record(name: []const u8, value: f64, budget: f64, unit: Unit) !void {
    try results.append(arena, .{ .name = name, .value = value, .budget = budget, .unit = unit });
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    std.debug.print("{s:<52} {s:>10}  (budget {s}){s}\n", .{ name, unit.format(value, &a), unit.format(budget, &b), if (value > budget) "  OVER BUDGET" else "" });
}

fn bench(name: []const u8, budget_ns: f64, ctx: anytype, comptime f: fn (@TypeOf(ctx)) anyerror!void) !void {
    if (!wanted(name)) return;
    try record(name, try measure(ctx, f), budget_ns, .ns);
}

const us = 1000.0;
const ms = 1_000_000.0;

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    arena = init.arena.allocator();
    const gpa = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(arena);
    var check = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--check")) check = true else filter = a;
    }
    const font: zigulee.Font = try .init(font_bytes);

    try properties(gpa);
    try galleryBenchmarks(gpa, &font);
    try touchbar(gpa, &font);
    try models(gpa, &font);
    try scene3d(gpa);
    try tooling(gpa);
    try memory(&font);
    try pxp();

    var over: usize = 0;
    for (results.items) |r| {
        if (r.value > r.budget) over += 1;
    }
    if (over > 0) {
        std.debug.print("\n{d} benchmark(s) over budget\n", .{over});
        if (check) return 1;
    }
    return 0;
}

// ---- The reactive core ----

fn properties(gpa: std.mem.Allocator) !void {
    // A chain of bindings, each reading the previous property.
    const Chain = struct {
        props: [100]zigulee.Property(i32) = @splat(.init(0)),

        fn next(p: *zigulee.Property(i32)) i32 {
            return p.get() + 1;
        }

        fn run(self: *@This()) !void {
            self.props[0].set(self.props[0].get() + 1);
            std.mem.doNotOptimizeAway(self.props[99].get());
        }
    };
    const chain = try gpa.create(Chain);
    defer gpa.destroy(chain);
    chain.* = .{};
    for (1..100) |i| try chain.props[i].setBinding(gpa, &chain.props[i - 1], Chain.next);
    defer for (&chain.props) |*p| p.deinit();
    if (wanted("binding chain")) try record("binding chain: re-evaluation, per binding", try measure(chain, Chain.run) / 100, 100, .ns);

    // One property read by many bindings (a palette color, say).
    const Fan = struct {
        source: zigulee.Property(i32) = .init(0),
        readers: [200]zigulee.Property(i32) = @splat(.init(0)),

        fn read(p: *zigulee.Property(i32)) i32 {
            return p.get() * 2;
        }

        fn run(self: *@This()) !void {
            self.source.set(self.source.get() + 1);
            for (&self.readers) |*r| std.mem.doNotOptimizeAway(r.get());
        }
    };
    const fan = try gpa.create(Fan);
    defer gpa.destroy(fan);
    fan.* = .{};
    for (&fan.readers) |*r| try r.setBinding(gpa, &fan.source, Fan.read);
    defer {
        for (&fan.readers) |*r| r.deinit();
        fan.source.deinit();
    }
    if (wanted("fan-out")) try record("fan-out: 1 property read by 200 bindings, per binding", try measure(fan, Fan.run) / 200, 100, .ns);
}

// ---- A small panel's frame: images, labels, buttons ----

/// What a 480x272 touchbar draws (as an embedded device's, through fbdev):
/// a background picture, 16 icons with transparent edges, their labels and
/// translucent buttons behind them, every pixel redrawn.
const Touchbar = struct {
    dl: core.rendering.DisplayList,
    renderer: zigulee.software.Renderer(core.Rgba8),
    renderer565: zigulee.software.Renderer(zigulee.software.Rgb565),
    pixels: []core.Rgba8,
    pixels565: []zigulee.software.Rgb565,
    /// What `frame` draws: all of it, or one kind of draw call.
    commands: []const core.rendering.DisplayList.Command = &.{},
    copy: []core.Rgba8 = &.{},

    const w = 480;
    const h = 272;

    fn frame(t: *Touchbar) !void {
        const box: core.Rect = .{ .width = w, .height = h };
        try t.renderer.drawCommands(.init(t.pixels, w, h), t.commands, box);
        std.mem.doNotOptimizeAway(t.pixels[w * h / 2]);
    }

    fn frame565(t: *Touchbar) !void {
        const box: core.Rect = .{ .width = w, .height = h };
        try t.renderer565.drawCommands(.init(t.pixels565, w, h), t.commands, box);
        std.mem.doNotOptimizeAway(t.pixels565[w * h / 2]);
    }

    /// Where the glyphs of `commands` (texts) go, without drawing them.
    fn layout(t: *Touchbar) !void {
        const clip: zigulee.software.PixelRect = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h };
        var n: usize = 0;
        for (t.commands) |*c| try zigulee.software.placeGlyphs(&c.text, clip, &n, struct {
            fn f(count: *usize, _: *const zigulee.Font, _: u16, _: f32, _: i32) std.mem.Allocator.Error!void {
                count.* += 1;
            }
        }.f);
        std.mem.doNotOptimizeAway(n);
    }

    /// The memory's speed, for comparison: a frame copied as it is.
    fn memcpy(t: *Touchbar) !void {
        @memcpy(t.copy, t.pixels);
        std.mem.doNotOptimizeAway(t.copy[w * h / 2]);
    }
};

/// The rows blended at once (with the CPU's vector unit: NEON on a
/// board) against `blend`, pixel by pixel, on random rows: what is timed
/// draws the right pixels.
fn checkRows() !void {
    const sw = zigulee.software;
    const Rgba8 = core.Rgba8;
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    const Random = struct {
        fn pixel(rand: std.Random) Rgba8 {
            const a = switch (rand.int(u2)) {
                0 => 0,
                1 => 255,
                else => rand.int(u8),
            };
            return .{ .r = rand.uintAtMost(u8, a), .g = rand.uintAtMost(u8, a), .b = rand.uintAtMost(u8, a), .a = a };
        }
    };
    for (0..4000) |_| {
        var dst: [37]Rgba8 = undefined;
        var src: [37]Rgba8 = undefined;
        var coverage: [37]u8 = undefined;
        for (&dst, &src, &coverage) |*d, *c, *k| {
            d.* = Random.pixel(r);
            c.* = Random.pixel(r);
            k.* = if (r.boolean()) r.int(u8) else 0;
        }
        const color = Random.pixel(r);
        const opacity = if (r.boolean()) 255 else r.int(u8);
        var want = dst;
        var got = dst;
        for (&want, src) |*d, c| sw.blend(Rgba8, d, c.scale(opacity));
        sw.spans.blendRow(Rgba8, &got, &src, opacity);
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(&want), std.mem.sliceAsBytes(&got))) return error.RowsBlendedWrong;
        want = dst;
        got = dst;
        for (&want, coverage) |*d, k| if (k != 0) sw.blend(Rgba8, d, color.scale(k));
        sw.spans.blendCoverage(Rgba8, &got, color, &coverage);
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(&want), std.mem.sliceAsBytes(&got))) return error.CoverageBlendedWrong;
        want = dst;
        got = dst;
        for (&want) |*d| sw.blend(Rgba8, d, color);
        sw.spans.blendColor(Rgba8, &got, color);
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(&want), std.mem.sliceAsBytes(&got))) return error.ColorBlendedWrong;
    }
}

/// The picture copied to 32-bit screens (rows at once: NEON on a board),
/// upright and turned, against each pixel packed on its own.
fn checkCopy(pages: []u8) !void {
    const w = 61;
    const h = 7;
    var picture: [w * h]core.Rgba8 = undefined;
    var prng: std.Random.DefaultPrng = .init(11);
    for (&picture) |*p| p.* = .{ .r = prng.random().int(u8), .g = prng.random().int(u8), .b = prng.random().int(u8), .a = prng.random().int(u8) };
    const byte: fb.Bitfield = .{ .length = 8 };
    const formats = [_]fb.Format{
        fb.Format.xrgb8888,
        .{ .bytes = 4, .red = .{ .offset = 16, .length = 8 }, .green = .{ .offset = 8, .length = 8 }, .blue = byte, .alpha = .{ .offset = 24, .length = 8 } },
        .{ .bytes = 4, .red = byte, .green = .{ .offset = 8, .length = 8 }, .blue = .{ .offset = 16, .length = 8 } },
        .{ .bytes = 4, .red = byte, .green = .{ .offset = 8, .length = 8 }, .blue = .{ .offset = 16, .length = 8 }, .alpha = .{ .offset = 24, .length = 8 } },
    };
    for (formats) |f| for ([_]fb.Rotation{ .none, .half }) |rotation| {
        var screen: fb.Screen = .inMemory(pages[0 .. w * h * 4], w, h, f, 1);
        screen.rotation = rotation;
        _ = screen.present(&picture, &.{.{ .width = w, .height = h }});
        for (0..h) |y| {
            const from = rotation.row(y, w, h);
            for (0..w) |x| {
                const want = f.pack(picture[@intCast(from.base + @as(isize, @intCast(x)) * from.step)]);
                if (std.mem.readInt(u32, pages[(y * w + x) * 4 ..][0..4], .little) != want) return error.CopiedWrong;
            }
        }
    };
}

// ---- The i.MX PXP (`zigulee bench pxp` only: it uses the device) ----

const v4l2 = @import("v4l2.zig");

/// The i.MX's 2D engine, as the touchbar's frame would use it: what the
/// driver offers, and how long it takes to turn a 480x272 RGBA picture
/// into an XRGB8888 screen's pixels, turned 180°, between its own buffers
/// (the screen is not touched). Checked against the CPU's.
fn pxp() !void {
    if (!std.mem.eql(u8, filter, "pxp")) return;
    if (@import("builtin").os.tag != .linux) {
        std.debug.print("pxp: Linux only\n", .{});
        return;
    }
    const c = std.c;
    // `mmap64` on glibc: its `mmap` takes a 32-bit offset on 32-bit targets.
    const mmap = if (std.posix.lfs64_abi) c.mmap64 else c.mmap;
    const say = std.debug.print;
    // The device: the video node whose driver is imx-pxp.
    var fd: c.fd_t = -1;
    var cap: v4l2.Capability = undefined;
    for (0..64) |i| {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "/dev/video{d}", .{i});
        const f = c.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        if (f < 0) continue;
        if (v4l2.call(f, v4l2.querycap, &cap) == null and std.mem.indexOf(u8, v4l2.text(&cap.driver), "pxp") != null) {
            fd = f;
            say("pxp: {s}: driver {s}, card {s}, driver version {d}.{d}.{d}, capabilities 0x{x}\n", .{ path, v4l2.text(&cap.driver), v4l2.text(&cap.card), cap.version >> 16, (cap.version >> 8) & 0xff, cap.version & 0xff, cap.device_caps });
            break;
        }
        _ = c.close(f);
    }
    if (fd < 0) {
        say("pxp: no device whose driver is imx-pxp among /dev/video*\n", .{});
        return;
    }
    defer _ = c.close(fd);

    // Its formats, each way.
    var src_formats: [64]u32 = undefined;
    var dst_formats: [64]u32 = undefined;
    var counts: [2]usize = .{ 0, 0 };
    for ([_]u32{ v4l2.output, v4l2.capture }, 0..) |t, k| {
        say("pxp: {s} formats:", .{if (t == v4l2.output) "source (output)" else "destination (capture)"});
        var i: u32 = 0;
        while (i < 64) : (i += 1) {
            var d: v4l2.FmtDesc = .{ .index = i, .type = t };
            if (v4l2.call(fd, v4l2.enum_fmt, &d) != null) break;
            (if (k == 0) &src_formats else &dst_formats)[i] = d.pixelformat;
            counts[k] = i + 1;
            const cc: [4]u8 = @bitCast(d.pixelformat);
            say(" {s}", .{&cc});
        }
        say("\n", .{});
    }
    for ([_]struct { u32, []const u8 }{ .{ v4l2.cid_hflip, "hflip" }, .{ v4l2.cid_vflip, "vflip" }, .{ v4l2.cid_rotate, "rotate" }, .{ v4l2.cid_alpha_component, "alpha" } }) |ctl| {
        var q: v4l2.QueryCtrl = .{ .id = ctl[0] };
        if (v4l2.call(fd, v4l2.queryctrl, &q)) |e| {
            say("pxp: control {s}: none ({t})\n", .{ ctl[1], e });
        } else say("pxp: control {s}: {d} to {d}, step {d}\n", .{ ctl[1], q.minimum, q.maximum, q.step });
    }

    // The renderer's pixels in, the screen's out.
    const w = Touchbar.w;
    const h = Touchbar.h;
    const src_format = for ([_]u32{ v4l2.rgba32, v4l2.rgbx32 }) |f| {
        if (std.mem.indexOfScalar(u32, src_formats[0..counts[0]], f) != null) break f;
    } else {
        say("pxp: takes neither RGBA32 nor RGBX32 (the renderer's bytes): stopped\n", .{});
        return;
    };
    if (std.mem.indexOfScalar(u32, dst_formats[0..counts[1]], v4l2.xbgr32) == null) {
        say("pxp: does not write XBGR32 (an XRGB8888 screen's bytes): stopped\n", .{});
        return;
    }
    for ([_]struct { u32, u32 }{ .{ v4l2.output, src_format }, .{ v4l2.capture, v4l2.xbgr32 } }) |tf| {
        var f: v4l2.Format = .{ .type = tf[0], .fmt = .{ .raw = @splat(0) } };
        f.fmt.pix = std.mem.zeroes(v4l2.PixFormat);
        f.fmt.pix.width = w;
        f.fmt.pix.height = h;
        f.fmt.pix.pixelformat = tf[1];
        f.fmt.pix.field = v4l2.field_none;
        f.fmt.pix.bytesperline = w * 4;
        if (v4l2.call(fd, v4l2.s_fmt, &f)) |e| {
            say("pxp: setting the {s} format failed ({t}): stopped\n", .{ if (tf[0] == v4l2.output) "source" else "destination", e });
            return;
        }
        const cc: [4]u8 = @bitCast(f.fmt.pix.pixelformat);
        say("pxp: {s}: {d}x{d} {s}, {d} bytes a row, {d} bytes\n", .{ if (tf[0] == v4l2.output) "source" else "destination", f.fmt.pix.width, f.fmt.pix.height, &cc, f.fmt.pix.bytesperline, f.fmt.pix.sizeimage });
        if (f.fmt.pix.width != w or f.fmt.pix.height != h or f.fmt.pix.bytesperline != w * 4) {
            say("pxp: not the size asked for: stopped\n", .{});
            return;
        }
    }

    // One buffer each way, the driver's (mapped here).
    var maps: [2][]align(std.heap.page_size_min) u8 = undefined;
    for ([_]u32{ v4l2.output, v4l2.capture }, 0..) |t, k| {
        var rb: v4l2.RequestBuffers = .{ .count = 1, .type = t, .memory = v4l2.memory_mmap };
        if (v4l2.call(fd, v4l2.reqbufs, &rb)) |e| {
            say("pxp: no buffers ({t}): stopped\n", .{e});
            return;
        }
        if (k == 0) say("pxp: buffers can be: {s}{s}{s}(0x{x}; 0: an older kernel, not said)\n", .{
            if (rb.capabilities & 1 != 0) "the driver's (mmap) " else "",
            if (rb.capabilities & 2 != 0) "the program's memory (userptr) " else "",
            if (rb.capabilities & 4 != 0) "shared (dmabuf) " else "",
            rb.capabilities,
        });
        var b: v4l2.Buffer = .{ .index = 0, .type = t, .memory = v4l2.memory_mmap };
        if (v4l2.call(fd, v4l2.querybuf, &b)) |e| {
            say("pxp: querybuf failed ({t}): stopped\n", .{e});
            return;
        }
        const m = mmap(null, b.length, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, @intCast(b.m));
        if (m == c.MAP_FAILED) {
            say("pxp: mmap failed: stopped\n", .{});
            return;
        }
        maps[k] = @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(m)))[0..b.length];
    }
    defer for (maps) |m| {
        _ = c.munmap(m.ptr, m.len);
    };

    // A picture, as the renderer leaves it (opaque).
    const picture = try arena.alloc(core.Rgba8, w * h);
    for (picture, 0..) |*p, i| p.* = .{ .r = @truncate(i *% 7), .g = @truncate(i / w), .b = @truncate(i % w), .a = 255 };
    const Run = struct {
        fd: c.fd_t,
        src: []u8,
        dst: []u8,
        picture: []const core.Rgba8,
        sum: u32 = 0,

        /// The picture into the PXP's source buffer.
        fn fill(r: *@This()) !void {
            @memcpy(r.src[0 .. w * h * 4], std.mem.sliceAsBytes(r.picture));
            std.mem.doNotOptimizeAway(r.src[1000]);
        }

        /// Reading the source buffer back (as drawing into it would):
        /// slow if the CPU does not cache it.
        fn read(r: *@This()) !void {
            var s: u32 = 0;
            for (std.mem.bytesAsSlice(u32, r.src[0 .. w * h * 4])) |x| s +%= x;
            r.sum = s;
            std.mem.doNotOptimizeAway(r.sum);
        }

        /// One conversion, waited for.
        fn convert(r: *@This()) !void {
            var out: v4l2.Buffer = .{ .index = 0, .type = v4l2.output, .memory = v4l2.memory_mmap, .bytesused = w * h * 4, .field = v4l2.field_none };
            var in: v4l2.Buffer = .{ .index = 0, .type = v4l2.capture, .memory = v4l2.memory_mmap };
            if (v4l2.call(r.fd, v4l2.qbuf, &out)) |_| return error.QueueFailed;
            if (v4l2.call(r.fd, v4l2.qbuf, &in)) |_| return error.QueueFailed;
            if (v4l2.call(r.fd, v4l2.dqbuf, &in)) |_| return error.ConvertFailed;
            if (v4l2.call(r.fd, v4l2.dqbuf, &out)) |_| return error.ConvertFailed;
        }
    };
    var run: Run = .{ .fd = fd, .src = maps[0], .dst = maps[1], .picture = picture };
    try run.fill();

    var on: c_int = @intCast(v4l2.output);
    var on_cap: c_int = @intCast(v4l2.capture);
    if (v4l2.call(fd, v4l2.streamon, &on)) |e| {
        say("pxp: streamon failed ({t}): stopped\n", .{e});
        return;
    }
    defer _ = v4l2.call(fd, v4l2.streamoff, &on);
    if (v4l2.call(fd, v4l2.streamon, &on_cap)) |e| {
        say("pxp: streamon failed ({t}): stopped\n", .{e});
        return;
    }
    defer _ = v4l2.call(fd, v4l2.streamoff, &on_cap);

    // Upright and turned 180° (both flips), each checked pixel by pixel.
    for ([_]bool{ false, true }) |turned| {
        var flips = true;
        for ([_]u32{ v4l2.cid_hflip, v4l2.cid_vflip }) |id| {
            var ctl: v4l2.Control = .{ .id = id, .value = @intFromBool(turned) };
            if (v4l2.call(fd, v4l2.s_ctrl, &ctl) != null) flips = false;
        }
        if (turned and !flips) {
            say("pxp: no flips: cannot turn the picture\n", .{});
            break;
        }
        run.convert() catch |err| {
            say("pxp: conversion failed ({t}): stopped\n", .{err});
            return;
        };
        var wrong: usize = 0;
        var first: ?[2]usize = null;
        for (0..h) |y| for (0..w) |x| {
            const p = picture[if (turned) (h - 1 - y) * w + (w - 1 - x) else y * w + x];
            const q = run.dst[(y * w + x) * 4 ..][0..3];
            if (q[0] != p.b or q[1] != p.g or q[2] != p.r) {
                wrong += 1;
                if (first == null) first = .{ x, y };
            }
        };
        if (first) |at| {
            const q = run.dst[(at[1] * w + at[0]) * 4 ..][0..4];
            say("pxp: {s}: {d} pixels differ from the CPU's; first at {d},{d}: {any}\n", .{ if (turned) "turned" else "upright", wrong, at[0], at[1], q.* });
        } else say("pxp: {s}: every pixel as the CPU converts it\n", .{if (turned) "turned" else "upright"});
        try bench(if (turned) "pxp: 480x272 RGBA to XRGB8888, turned 180" else "pxp: 480x272 RGBA to XRGB8888", 500 * us, &run, Run.convert);
    }
    try bench("pxp: the picture copied into its source buffer", 500 * us, &run, Run.fill);
    try bench("pxp: its source buffer read by the CPU", 500 * us, &run, Run.read);
}

fn touchbar(gpa: std.mem.Allocator, font: *const zigulee.Font) !void {
    if (!wanted("touchbar")) return;
    checkRows() catch |err| {
        std.debug.print("touchbar: rows blended at once differ from pixel by pixel ({t})\n", .{err});
        return err;
    };
    // An opaque background, and a round icon fading out at its edges.
    const background = try gpa.alloc(core.Rgba8, Touchbar.w * Touchbar.h);
    defer gpa.free(background);
    for (background, 0..) |*p, i| p.* = .{ .r = @truncate(i % Touchbar.w), .g = @truncate(i / Touchbar.w), .b = 90, .a = 255 };
    const icon_size = 48;
    const icon = try gpa.alloc(core.Rgba8, icon_size * icon_size);
    defer gpa.free(icon);
    for (icon, 0..) |*p, i| {
        const dx = @as(f32, @floatFromInt(i % icon_size)) - 23.5;
        const dy = @as(f32, @floatFromInt(i / icon_size)) - 23.5;
        const a: u8 = @intFromFloat(std.math.clamp(24 - @sqrt(dx * dx + dy * dy), 0, 1) * 255);
        p.* = (core.Rgba8{ .r = 240, .g = 200, .b = 40, .a = 255 }).scale(a);
    }

    var t: Touchbar = .{
        .dl = .init(gpa, .{ .width = Touchbar.w, .height = Touchbar.h }),
        .renderer = .init(gpa),
        .renderer565 = .init(gpa),
        .pixels = try gpa.alloc(core.Rgba8, Touchbar.w * Touchbar.h),
        .pixels565 = try gpa.alloc(zigulee.software.Rgb565, Touchbar.w * Touchbar.h),
    };
    defer {
        gpa.free(t.pixels565);
        gpa.free(t.pixels);
        t.renderer565.deinit();
        t.renderer.deinit();
        t.dl.deinit();
    }
    const r = t.dl.renderer();
    // The window's fill (white, as by default), under the picture.
    r.drawRectangle(.{ .width = Touchbar.w, .height = Touchbar.h }, .{ .background = .{ .solid = core.Color.rgb(0xffffff) } });
    r.drawImage(.{ .width = Touchbar.w, .height = Touchbar.h }, .{ .image = .{ .width = Touchbar.w, .height = Touchbar.h, .pixels = background, .is_opaque = true } });
    const labels = [_][]const u8{ "Home", "Lights", "Climate", "Music", "Doors", "Camera", "Energy", "Settings" };
    for (0..2) |row| for (0..8) |col| {
        const at: core.Point = .{ .x = @floatFromInt(col * 60), .y = @floatFromInt(16 + row * 128) };
        r.save();
        r.translate(at);
        r.drawRectangle(.{ .width = 56, .height = 100 }, .{ .background = .{ .solid = core.Color.rgba(0xffffff40) }, .border_radius = 8 });
        r.translate(.{ .x = 4, .y = 8 });
        r.drawImage(.{ .width = icon_size, .height = icon_size }, .{ .image = .{ .width = icon_size, .height = icon_size, .pixels = icon } });
        r.translate(.{ .x = -4, .y = 60 });
        r.drawText(.{ .width = 56, .height = 20 }, .{ .text = labels[col], .font = font, .color = .{ .solid = core.Color.rgb(0xffffff) }, .font_size = 13, .horizontal_alignment = .center });
        r.restore();
    };
    const all = t.dl.commands.items;
    t.commands = all;
    try t.frame();
    try t.frame565();
    try bench("touchbar: full frame 480x272 RGBA", 500 * us, &t, Touchbar.frame);
    try bench("touchbar: full frame 480x272 RGB565", 500 * us, &t, Touchbar.frame565);

    // Its parts (RGBA), to see where the time goes.
    const Kind = std.meta.Tag(core.rendering.DisplayList.Command);
    // The first two commands are the window's fill and the picture.
    const parts = [_]struct { []const u8, Kind, bool }{
        .{ "touchbar: part: the fill and the picture (opaque)", .image, true },
        .{ "touchbar: part: 16 icons 48x48 (alpha)", .image, false },
        .{ "touchbar: part: 16 buttons (translucent, rounded)", .rectangle, false },
        .{ "touchbar: part: 16 labels (13px)", .text, false },
    };
    for (parts) |part| {
        var picked: std.ArrayList(core.rendering.DisplayList.Command) = .empty;
        for (all, 0..) |c, i| if ((i < 2) == part[2] and (part[2] or c == part[1])) try picked.append(arena, c);
        t.commands = picked.items;
        try bench(part[0], 500 * us, &t, Touchbar.frame);
    }
    // What the buttons and labels cost is made of: the corners, the layout.
    var square: std.ArrayList(core.rendering.DisplayList.Command) = .empty;
    for (all[2..]) |c| if (c == .rectangle) {
        var flat = c;
        flat.rectangle.style.border_radius = 0;
        try square.append(arena, flat);
    };
    t.commands = square.items;
    try bench("touchbar: part: 16 buttons, square corners", 500 * us, &t, Touchbar.frame);
    // Their top 16 rows only (57 KB), drawn 6 times: in the CPU's cache.
    // Per pixel as slow as above, the cost is in each row's work; much
    // faster, it is fetching each row from memory.
    var tops: std.ArrayList(core.rendering.DisplayList.Command) = .empty;
    for (0..6) |_| for (square.items) |c| {
        var top = c;
        top.rectangle.clip = top.rectangle.clip.intersection(.{ .x = top.rectangle.rect.x, .y = top.rectangle.rect.y, .width = top.rectangle.rect.width, .height = 16 });
        try tops.append(arena, top);
    };
    t.commands = tops.items;
    try bench("touchbar: their top 16 rows 6 times (in cache, 96 rows)", 500 * us, &t, Touchbar.frame);
    // The same blending in 272 long rows (the frame's): what the rows of
    // the buttons add to it.
    var veil = square.items[0];
    veil.rectangle.rect = .{ .width = Touchbar.w, .height = Touchbar.h };
    veil.rectangle.clip = veil.rectangle.rect;
    t.commands = &.{veil};
    try bench("touchbar: a translucent rectangle over the whole frame", 500 * us, &t, Touchbar.frame);
    // The same number of pixels blended, but the same 34 rows (64 KB)
    // eight times: in the CPU's cache. Close to the line above, the
    // blending is the cost; far below it, the memory.
    var strip = veil;
    strip.rectangle.clip = .{ .width = Touchbar.w, .height = Touchbar.h / 8 };
    const strips: [8]core.rendering.DisplayList.Command = @splat(strip);
    t.commands = &strips;
    try bench("touchbar: the same, 34 rows 8 times (in cache)", 500 * us, &t, Touchbar.frame);
    var texts: std.ArrayList(core.rendering.DisplayList.Command) = .empty;
    for (all) |c| if (c == .text) try texts.append(arena, c);
    t.commands = texts.items;
    try bench("touchbar: part: 16 labels laid out, not drawn", 500 * us, &t, Touchbar.layout);

    t.copy = try gpa.alloc(core.Rgba8, Touchbar.w * Touchbar.h);
    defer gpa.free(t.copy);
    try bench("touchbar: memcpy of a 480x272 RGBA frame", 500 * us, &t, Touchbar.memcpy);

    // Sending the frame to the screen (fbdev): converted to the screen's
    // pixels, turned with ZIGULEE_ROTATION.
    if (@hasDecl(fb, "Screen")) {
        const Fb = fb.Screen;
        const screen_memory = try gpa.alloc(u8, Touchbar.w * Touchbar.h * 4);
        defer gpa.free(screen_memory);
        checkCopy(screen_memory) catch |err| {
            std.debug.print("touchbar: the picture copied to the screen differs from pixel by pixel ({t})\n", .{err});
            return err;
        };
        const Send = struct {
            screen: Fb,
            frame: []const core.Rgba8,

            fn run(c: *@This()) !void {
                _ = c.screen.present(c.frame, &.{.{ .width = Touchbar.w, .height = Touchbar.h }});
                std.mem.doNotOptimizeAway(c.screen.memory[1000]);
            }

            /// As many pixels, the same 34 rows (64 KB in, 64 KB out)
            /// eight times: in the CPU's cache.
            fn cached(c: *@This()) !void {
                for (0..8) |_| _ = c.screen.present(c.frame, &.{.{ .width = Touchbar.w, .height = Touchbar.h / 8 }});
                std.mem.doNotOptimizeAway(c.screen.memory[1000]);
            }
        };
        const cases = [_]struct { []const u8, fb.Format, fb.Rotation }{
            .{ "touchbar: to a 16-bit screen (RGB565)", fb.Format.rgb565, .none },
            .{ "touchbar: to a 16-bit screen (RGB565), turned 180", fb.Format.rgb565, .half },
            .{ "touchbar: to a 32-bit screen (XRGB8888)", fb.Format.xrgb8888, .none },
            .{ "touchbar: to a 32-bit screen (XRGB8888), turned 180", fb.Format.xrgb8888, .half },
        };
        for (cases) |case| {
            var send: Send = .{ .screen = .inMemory(screen_memory, Touchbar.w, Touchbar.h, case[1], 1), .frame = t.pixels };
            send.screen.rotation = case[2];
            try bench(case[0], 500 * us, &send, Send.run);
            if (case[1].bytes == 4 and case[2] == .none) try bench("touchbar: the same, 34 rows 8 times (in cache)", 500 * us, &send, Send.cached);
        }
    }
}

// ---- The gallery: bindings, layout and rendering of a real UI ----

const GalleryCtx = struct {
    app: *gallery.Gallery,
    dl: core.rendering.DisplayList,
    renderer: zigulee.software.Renderer(core.Rgba8),
    renderer565: zigulee.software.Renderer(zigulee.software.Rgb565),
    pixels: []core.Rgba8,
    pixels2x: []core.Rgba8,
    pixels565: []zigulee.software.Rgb565,
    batcher: zigulee.gpu.Batcher,
    flip: bool = false,

    const w = 460;
    const h = 640;

    fn window(c: *GalleryCtx) *zigulee.Window {
        return c.app.window();
    }

    /// Re-evaluates what changed and records the draw calls of what must be
    /// redrawn, without drawing pixels.
    fn recordPartial(c: *GalleryCtx) !void {
        c.dl.reset(.{ .width = w, .height = h });
        _ = try c.window().render(c.dl.renderer(), .partial);
    }

    fn darkToggle(c: *GalleryCtx) !void {
        c.app.dark.set(!c.app.dark.get());
        zigulee.runChangeHandlers();
        try c.recordPartial();
    }

    fn darkToggleAndDraw(c: *GalleryCtx) !void {
        c.app.dark.set(!c.app.dark.get());
        zigulee.runChangeHandlers();
        _ = try c.renderer.renderWindow(c.window(), .init(c.pixels, w, h), .partial);
    }

    fn clickButton(c: *GalleryCtx) !void {
        const g = c.app.click.rootItem().absoluteGeometry();
        const p: core.Point = .{ .x = g.x + g.width / 2, .y = g.y + g.height / 2 };
        c.window().dispatchPointer(.{ .pressed = .{ .position = p } });
        c.window().dispatchPointer(.{ .released = .{ .position = p } });
        zigulee.runChangeHandlers();
        _ = try c.renderer.renderWindow(c.window(), .init(c.pixels, w, h), .partial);
    }

    fn resize(c: *GalleryCtx) !void {
        c.flip = !c.flip;
        c.window().setSize(.{ .width = if (c.flip) w - 40 else w, .height = h });
        try c.recordPartial();
    }

    fn fullFrame(c: *GalleryCtx) !void {
        _ = try c.renderer.renderWindow(c.window(), .init(c.pixels, w, h), .full);
    }

    fn fullFrame2x(c: *GalleryCtx) !void {
        _ = try c.renderer.renderWindow(c.window(), .init(c.pixels2x, w * 2, h * 2), .full);
    }

    fn fullFrame565(c: *GalleryCtx) !void {
        _ = try c.renderer565.renderWindow(c.window(), .init(c.pixels565, w, h), .full);
    }

    /// The CPU side of a GPU frame: everything recorded and batched.
    fn gpuFrame2x(c: *GalleryCtx) !void {
        const frame = try c.batcher.build(c.window(), w * 2, h * 2, .full);
        std.mem.doNotOptimizeAway(frame.vertices.len);
    }

    /// A click, then the GPU frame of what changed.
    fn gpuClick(c: *GalleryCtx) !void {
        const g = c.app.click.rootItem().absoluteGeometry();
        const p: core.Point = .{ .x = g.x + g.width / 2, .y = g.y + g.height / 2 };
        c.window().dispatchPointer(.{ .pressed = .{ .position = p } });
        c.window().dispatchPointer(.{ .released = .{ .position = p } });
        zigulee.runChangeHandlers();
        const frame = try c.batcher.build(c.window(), w * 2, h * 2, .partial);
        std.mem.doNotOptimizeAway(frame.vertices.len);
    }

    fn createDestroy(c: *GalleryCtx) !void {
        const app = try gallery.Gallery.create(c.renderer.gpa);
        zigulee.runChangeHandlers();
        app.destroy();
    }
};

fn galleryBenchmarks(gpa: std.mem.Allocator, font: *const zigulee.Font) !void {
    var c: GalleryCtx = .{
        .app = try gallery.Gallery.create(gpa),
        .dl = .init(gpa, .{ .width = GalleryCtx.w, .height = GalleryCtx.h }),
        .renderer = .init(gpa),
        .renderer565 = .init(gpa),
        .pixels = try gpa.alloc(core.Rgba8, GalleryCtx.w * GalleryCtx.h),
        .pixels2x = try gpa.alloc(core.Rgba8, GalleryCtx.w * GalleryCtx.h * 4),
        .pixels565 = try gpa.alloc(zigulee.software.Rgb565, GalleryCtx.w * GalleryCtx.h),
        .batcher = try .init(gpa),
    };
    defer {
        c.batcher.deinit();
        gpa.free(c.pixels565);
        gpa.free(c.pixels2x);
        gpa.free(c.pixels);
        c.renderer565.deinit();
        c.renderer.deinit();
        c.dl.deinit();
        c.app.dark.set(false);
        c.app.destroy();
    }
    c.window().default_font.set(font);
    try c.window().registerFont("Inter", 400, font);
    zigulee.runChangeHandlers();
    try c.fullFrame();

    try bench("gallery: dark mode toggle (bindings, no drawing)", 1 * ms, &c, GalleryCtx.darkToggle);
    try bench("gallery: resize (layout, no drawing)", 1 * ms, &c, GalleryCtx.resize);
    c.window().setSize(.{ .width = GalleryCtx.w, .height = GalleryCtx.h });
    try bench("gallery: click a button, redraw what changed", 1 * ms, &c, GalleryCtx.clickButton);
    try bench("gallery: dark mode toggle, redraw", 4 * ms, &c, GalleryCtx.darkToggleAndDraw);
    try bench("gallery: full frame 460x640 RGBA", 3 * ms, &c, GalleryCtx.fullFrame);
    c.renderer.scale_factor = 2;
    try bench("gallery: full frame 920x1280 RGBA (2x)", 10 * ms, &c, GalleryCtx.fullFrame2x);
    c.renderer.scale_factor = 1;
    try bench("gallery: full frame 460x640 RGB565", 3 * ms, &c, GalleryCtx.fullFrame565);
    c.batcher.scale_factor = 2;
    try bench("gallery: GPU frame 920x1280 (2x), CPU side", 1 * ms, &c, GalleryCtx.gpuFrame2x);
    try bench("gallery: click a button, partial GPU frame (CPU side)", 200 * us, &c, GalleryCtx.gpuClick);
    try bench("gallery: create and destroy", 1 * ms, &c, GalleryCtx.createDestroy);
}

// ---- Models: rows created, updated and removed ----

const ListCtx = struct {
    app: *todo.TodoApp,
    items: zigulee.VecModel(todo.TodoItem),
    dl: core.rendering.DisplayList,
    i: usize = 0,

    fn addRemove(c: *ListCtx) !void {
        try c.items.push(.{ .title = "One more", .done = false });
        _ = c.items.remove(c.items.rowCount() - 1);
    }

    fn update(c: *ListCtx) !void {
        c.i = (c.i + 1) % 1000;
        var row = c.items.rowData(c.i).?;
        row.done = !row.done;
        c.items.setRowData(c.i, row);
        c.dl.reset(.{ .width = 400, .height = 480 });
        _ = try c.app.window().render(c.dl.renderer(), .partial);
    }
};

fn models(gpa: std.mem.Allocator, font: *const zigulee.Font) !void {
    var c: ListCtx = .{ .app = try todo.TodoApp.create(gpa), .items = .init(gpa), .dl = .init(gpa, .{ .width = 400, .height = 480 }) };
    defer {
        c.dl.deinit();
        c.app.destroy();
        c.items.deinit();
    }
    c.app.window().default_font.set(font);
    c.app.items.set(c.items.model());
    for (0..1000) |_| try c.items.push(.{ .title = "A todo item", .done = false });
    zigulee.runChangeHandlers();
    _ = try c.app.window().render(c.dl.renderer(), .full);
    try bench("list of 1000 rows: add and remove a row", 100 * us, &c, ListCtx.addRemove);
    try bench("list of 1000 rows: change a row, redraw", 1 * ms, &c, ListCtx.update);
}

// ---- 3D ----

/// A frame of examples/scene.zge's scene, as `View3D` draws it there (a
/// 610 x 268 view, at twice its size).
fn scene3d(gpa: std.mem.Allocator) !void {
    const r = core.raster3d;
    const w = 1220;
    const h = 536;
    const Ctx = struct {
        scene: r.Scene,
        target: r.Target,
        fn frame(c: *@This()) !void {
            r.render(&c.scene, c.target);
        }
    };
    const pixels = try gpa.alloc(core.Rgba8, w * h);
    defer gpa.free(pixels);
    const depth = try gpa.alloc(f32, w * h);
    defer gpa.free(depth);
    var c: Ctx = .{
        .scene = .{
            .camera = .{ .world = r.Mat.rotation(0, 20, 0).mul(r.Mat.place(.{ 0, 1.6, 5 }, -17, 0, 0, .{ 1, 1, 1 })), .field_of_view = 40 },
            .instances = &.{
                .{ .mesh = r.plane, .world = r.Mat.place(.{ 0, -0.6, 0 }, -90, 0, 0, .{ 7, 7, 1 }) },
                .{ .mesh = r.cube, .world = r.Mat.place(.{ -0.9, 0, 0 }, 20, 40, 0, .{ 1, 1, 1 }) },
                .{ .mesh = r.sphere(), .world = r.Mat.place(.{ 0.9, 0, 0 }, 0, 0, 0, .{ 1, 1, 1 }), .material = .{ .metallic = 0.6, .roughness = 0.3 } },
            },
            .lights = &.{ .{ .directional = .{ .direction = .{ 0.4, -0.6, -1 } } }, .{ .point = .{ .position = .{ 2, 1.2, 2 } } } },
        },
        .target = .{ .width = w, .height = h, .pixels = pixels, .depth = depth },
    };
    try bench("3D: a scene frame on the CPU, 1220x536", 16 * ms, &c, Ctx.frame);
}

// ---- The compiler and the interpreter ----

fn tooling(gpa: std.mem.Allocator) !void {
    const Compile = struct {
        gpa: std.mem.Allocator,

        fn run(self: @This()) !void {
            var a: std.heap.ArenaAllocator = .init(self.gpa);
            defer a.deinit();
            const result = try interp.compiler.compile(a.allocator(), "gallery.zge", gallery_source, .{ .loader = example_files });
            if (result == .errors) return error.CompileError;
        }

        fn interpret(self: @This()) !void {
            const prog = switch (try interp.Program.load(self.gpa, "gallery.zge", gallery_source, .{ .loader = example_files })) {
                .program => |p| p,
                .errors => return error.CompileError,
            };
            defer prog.destroy();
            const inst = try prog.create(prog.mainComponent().?);
            zigulee.runChangeHandlers();
            inst.destroy();
        }
    };
    // The gallery's images are read from examples/ (missing on a board).
    std.Io.Dir.cwd().access(io, "examples/gallery.zge", .{}) catch {
        if (wanted("compiler") or wanted("interpreter")) std.debug.print("compiler, interpreter: skipped (no examples/ here)\n", .{});
        return;
    };
    try bench("compiler: gallery.zge to Zig", 50 * ms, Compile{ .gpa = gpa }, Compile.run);
    try bench("interpreter: load and create the gallery", 50 * ms, Compile{ .gpa = gpa }, Compile.interpret);
}

// ---- Memory ----

/// Counts the bytes in use and their peak.
const Counting = struct {
    child: std.mem.Allocator,
    in_use: usize = 0,
    peak: usize = 0,
    count: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn add(self: *Counting, n: usize) void {
        self.in_use += n;
        self.peak = @max(self.peak, self.in_use);
    }

    fn alloc(p: *anyopaque, len: usize, a: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(p));
        const r = self.child.rawAlloc(len, a, ret) orelse return null;
        self.add(len);
        self.count += 1;
        return r;
    }

    fn resize(p: *anyopaque, m: []u8, a: std.mem.Alignment, new: usize, ret: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(p));
        if (!self.child.rawResize(m, a, new, ret)) return false;
        self.in_use -= m.len;
        self.add(new);
        return true;
    }

    fn remap(p: *anyopaque, m: []u8, a: std.mem.Alignment, new: usize, ret: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(p));
        const r = self.child.rawRemap(m, a, new, ret) orelse return null;
        self.in_use -= m.len;
        self.add(new);
        return r;
    }

    fn free(p: *anyopaque, m: []u8, a: std.mem.Alignment, ret: usize) void {
        const self: *Counting = @ptrCast(@alignCast(p));
        self.child.rawFree(m, a, ret);
        self.in_use -= m.len;
    }
};

fn memory(font: *const zigulee.Font) !void {
    if (!wanted("memory")) return;
    var counting: Counting = .{ .child = std.heap.smp_allocator };
    const gpa = counting.allocator();

    // The gallery: every standard widget, three tabs.
    const app = try gallery.Gallery.create(gpa);
    app.window().default_font.set(font);
    zigulee.runChangeHandlers();
    var dl: core.rendering.DisplayList = .init(gpa, .{ .width = 460, .height = 640 });
    _ = try app.window().render(dl.renderer(), .full); // bindings evaluated
    // Per element: the gallery grows with every widget shown in it.
    var elements: usize = 0;
    var it: ?*zigulee.Item = app.window().rootItem();
    while (it) |i| : (it = i.nextInTree()) elements += 1;
    try record("memory: the gallery, per element (heap)", @as(f64, @floatFromInt(counting.in_use)) / @as(f64, @floatFromInt(elements)), 3 * 1024, .bytes);
    dl.deinit();
    app.destroy();

    // A repeated row: what each row of a list costs.
    const list = try todo.TodoApp.create(gpa);
    var items: zigulee.VecModel(todo.TodoItem) = .init(gpa);
    list.items.set(items.model());
    try items.push(.{ .title = "x", .done = false });
    zigulee.runChangeHandlers(); // the repeater follows the model from now on
    const before = counting.in_use;
    for (0..100) |_| try items.push(.{ .title = "x", .done = false });
    const per_row = @as(f64, @floatFromInt(counting.in_use - before)) / 100;
    try record("memory: one row of the todo list (heap)", per_row, 16 * 1024, .bytes);
    list.destroy();
    items.deinit();
}
