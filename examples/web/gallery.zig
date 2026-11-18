// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The gallery in a browser: `zig build web`, then serve zig-out/web
//! (e.g. `python3 -m http.server -d zig-out/web`) and open it.

const std = @import("std");
const zigulee = @import("zigulee");
const wasm = @import("zigulee-wasm");
const ui = @import("gallery_ui");

pub const std_options = wasm.std_options;
pub const panic = wasm.panic;

var regular: zigulee.Font = undefined;
var bold: zigulee.Font = undefined;
var mono: zigulee.Font = undefined;

export fn zigulee_main() void {
    start() catch |err| std.log.err("cannot start: {t}", .{err});
}

fn start() !void {
    regular = try .init(@embedFile("inter_regular"));
    bold = try .init(@embedFile("inter_bold"));
    mono = try .init(@embedFile("jetbrains_mono"));
    const app = try ui.Gallery.create(wasm.allocator);
    const window = app.window();
    try window.registerFont("Inter", 400, &regular);
    try window.registerFont("Inter", 700, &bold);
    try window.registerFont("JetBrains Mono", 400, &mono);
    try window.addFallbackFont(&mono);
    wasm.show(window);
}
