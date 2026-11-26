// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Fuzz target of the GPU renderer: random draw calls, drawn by the
//! software renderer and by the GPU renderer's frames run on the CPU
//! (reference.zig), must give the same pixels (within rounding, which adds
//! up a little over overlapping draw calls).

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/core.zig");
const Target = core.fuzz.Target;
const Input = core.fuzz.Input;
const Rgba8 = core.Rgba8;
const Command = core.rendering.DisplayList.Command;
const software = @import("../software/software.zig");
const batch = @import("batch.zig");
const reference = @import("reference.zig");

pub const targets = [_]Target{
    .{ .name = "gpu-frames", .run = gpuFrames, .corpus = &.{ "", "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10" } },
};

test "fuzz targets on their corpus" {
    inline for (targets) |t| try core.fuzz.runCorpus(t);
}

const width = 48;
const height = 40;

fn float(s: *Input, lo: f32, hi: f32) f32 {
    return lo + (hi - lo) * @as(f32, @floatFromInt(s.valueRangeAtMost(u16, 0, 1000))) / 1000;
}

fn rect(s: *Input) core.Rect {
    return .{ .x = float(s, -8, width), .y = float(s, -8, height), .width = float(s, 0, 40), .height = float(s, 0, 30) };
}

const stops_a = [_]core.GradientStop{ .{ .color = .rgba(0xff000080), .position = 0 }, .{ .color = .rgb(0x0000ff), .position = 1 } };
const stops_b = [_]core.GradientStop{ .{ .color = .rgb(0x00ff00), .position = 0.2 }, .{ .color = .rgba(0x00000000), .position = 0.5 }, .{ .color = .rgb(0xffffff), .position = 0.9 } };
const linear_a: core.LinearGradient = .{ .angle = 30, .stops = .init(&stops_a) };
const linear_b: core.LinearGradient = .{ .angle = 200, .stops = .init(&stops_b) };
const radial: core.RadialGradient = .{ .stops = .init(&stops_b) };
// As SVG drawings give them (on paths, over their paint box).
const line: core.LinearGradient = .{ .stops = .init(&stops_a), .line = .{ .{ 0.2, 0.1 }, .{ 0.7, 0.9 } } };
const ellipse: core.RadialGradient = .{ .stops = .init(&stops_b), .ellipse = .{ .center = .{ 0.4, 0.6 }, .radius = .{ 0.5, 0.3 } } };

fn svgBrush(s: *Input) core.Brush {
    return switch (s.valueRangeAtMost(u8, 0, 2)) {
        0 => .{ .linear_gradient = &line },
        1 => .{ .radial_gradient = &ellipse },
        else => brush(s),
    };
}

fn brush(s: *Input) core.Brush {
    return switch (s.valueRangeAtMost(u8, 0, 5)) {
        0 => .transparent,
        1 => .color(.rgb(0xe11d48)),
        2 => .color(.rgba(0x2563eb99)),
        3 => .{ .linear_gradient = &linear_a },
        4 => .{ .linear_gradient = &linear_b },
        else => .{ .radial_gradient = &radial },
    };
}

const paths = [_][]const u8{ "M 0 0 L 10 10 L 0 10 Z", "M 2 8 A 6 6 0 1 0 14 8 A 6 6 0 1 0 2 8", "M 1 1 L 9 1 M 1 5 L 9 5", "M 0 0 C 10 0 10 10 0 10" };

pub fn gpuFrames(gpa: Allocator, s: *Input) !void {
    const font_bytes = try core.text.test_font.standard(gpa);
    defer gpa.free(font_bytes);
    const font: core.Font = try .init(font_bytes);
    var checker: [16]Rgba8 = undefined;
    for (&checker, 0..) |*p, i| p.* = if (i % 3 == 0) core.Color.rgb(0x2563eb).premultiplied() else core.Color.rgba(0xfacc1580).premultiplied();
    const img: core.Image = .{ .width = 4, .height = 4, .pixels = &checker };

    var commands: [12]Command = undefined;
    const n = s.valueRangeAtMost(u8, 0, commands.len);
    for (commands[0..n]) |*cmd| {
        const r = rect(s);
        const clip = if (s.value(bool)) rect(s) else core.Rect{ .width = width, .height = height };
        const opacity = if (s.value(bool)) 1 else float(s, 0, 1);
        cmd.* = switch (s.valueRangeAtMost(u8, 0, 4)) {
            0 => .{ .rectangle = .{ .rect = r, .clip = clip, .opacity = opacity, .style = .{
                .background = brush(s),
                .border_color = brush(s),
                .border_width = float(s, 0, 6),
                .border_radius = float(s, 0, 15),
            } } },
            1 => .{ .text = .{ .rect = r, .clip = clip, .opacity = opacity, .style = .{
                .text = ([_][]const u8{ "AB", "Hi there\nO", "BOA BOA BOA", "" })[s.index(4)],
                .font = &font,
                .color = brush(s),
                .font_size = float(s, 4, 20),
                .wrap = if (s.value(bool)) .word_wrap else .no_wrap,
                .overflow = if (s.value(bool)) .elide else .clip,
                .horizontal_alignment = s.value(core.rendering.TextHorizontalAlignment),
            } } },
            2 => .{
                .image = .{
                    .rect = r,
                    .clip = clip,
                    .opacity = opacity,
                    .style = .{
                        .image = img,
                        .fit = s.value(core.image.ImageFit),
                        // Smooth only: with nearest sampling, a pixel center exactly
                        // between two texels takes either, by float rounding.
                        .rendering = .smooth,
                        .colorize = if (s.value(bool)) brush(s) else null,
                        .nine_slice = if (s.value(bool)) .{ .top = 1, .right = 1, .bottom = 2, .left = 1 } else null,
                    },
                },
            },
            3 => .{ .shadow = .{ .rect = r, .clip = clip, .opacity = opacity, .style = .{
                .color = if (s.value(bool)) .rgba(0x00000080) else .rgb(0x7c3aed),
                .blur = if (s.value(bool)) 0 else float(s, 0, 12),
                .border_radius = float(s, 0, 15),
            } } },
            else => if (s.value(bool)) .{ .path = .{ .rect = r, .clip = clip, .opacity = opacity, .style = .{
                .commands = paths[s.index(paths.len)],
                .fill = brush(s),
                .stroke = brush(s),
                .stroke_width = float(s, 0, 4),
            } } } else .{ .path = .{ .rect = r, .clip = clip, .opacity = opacity, .style = .{
                .commands = paths[s.index(paths.len)],
                .fill = svgBrush(s),
                .stroke = svgBrush(s),
                .stroke_width = float(s, 0, 4),
                .viewbox = .{ .x = -1, .y = 0, .width = 16, .height = 12 },
                .paint_box = .{ .x = -2, .y = -1, .width = 20, .height = 14 },
                .stretch = s.value(bool),
                .inset_stroke = false,
            } } },
        };
    }

    var expected: [width * height]Rgba8 = @splat(.transparent);
    var r: software.Renderer(Rgba8) = .init(gpa);
    defer r.deinit();
    try r.drawCommands(.init(&expected, width, height), commands[0..n], .{ .width = width, .height = height });

    var actual: [width * height]Rgba8 = @splat(.transparent);
    var b: batch.Batcher = try .init(gpa);
    defer b.deinit();
    const frame = try b.buildCommands(commands[0..n], width, height);
    reference.execute(&frame, &actual);

    for (expected, actual, 0..) |e, a, i| {
        inline for (.{ "r", "g", "b", "a" }) |c| {
            // Rounding differs a little per blend, and draw calls stack.
            if (@abs(@as(i16, @field(e, c)) - @field(a, c)) > 4) {
                std.debug.print("pixel {d},{d}: software {any}, GPU {any}\n", .{ i % width, i / width, e, a });
                for (commands[0..n]) |cmd| switch (cmd) {
                    .image => |c2| std.debug.print("image: rect {any} clip {any} opacity {d} fit {t} {t} colorize {any} nine {any}\n", .{ c2.rect, c2.clip, c2.opacity, c2.style.fit, c2.style.rendering, c2.style.colorize != null, c2.style.nine_slice != null }),
                    inline else => |c2| std.debug.print("{t}: rect {any} clip {any} opacity {d}\n", .{ cmd, c2.rect, c2.clip, c2.opacity }),
                };
                return error.Mismatch;
            }
        }
    }
}
