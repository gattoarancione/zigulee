// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! A small app for tests/wasm/test.mjs.

const zigulee = @import("zigulee");
const wasm = @import("zigulee-wasm");
const ui = @import("wasm_test_ui");

pub const std_options = wasm.std_options;
pub const panic = wasm.panic;

var app: *ui.App = undefined;
var font: zigulee.Font = undefined;

export fn zigulee_main() void {
    app = ui.App.create(wasm.allocator) catch @panic("out of memory");
    font = zigulee.Font.init(@embedFile("font")) catch @panic("bad font");
    app.window().default_font.set(&font);
    wasm.show(app.window());
}

export fn test_clicks() i32 {
    return app.clicks.get();
}

export fn test_typed_ptr() [*]const u8 {
    return app.typed.get().ptr;
}

export fn test_typed_len() usize {
    return app.typed.get().len;
}

export fn test_dropped_ptr() [*]const u8 {
    return app.dropped.get().ptr;
}

export fn test_dropped_len() usize {
    return app.dropped.get().len;
}

export fn test_page_title_len() usize {
    return app.page_title.get().len;
}

export fn test_js_ptr() [*]const u8 {
    return app.js.get().ptr;
}

export fn test_js_len() usize {
    return app.js.get().len;
}

export fn test_run_js() void {
    app.invoke_run_js();
}

export fn test_tilt() f32 {
    return app.tilt.get();
}

export fn test_way() u32 {
    return @intFromEnum(app.way.get());
}

export fn test_lat() f32 {
    return app.lat.get();
}

export fn test_why() u32 {
    return @intFromEnum(app.why.get());
}

export fn test_load_picture(found: bool) void {
    app.picture_url.set(if (found) "https://tiles.example/dot.png" else "https://tiles.example/missing.png");
}

export fn test_picture_width() f32 {
    return app.picture_width.get();
}

export fn test_picture_progress() f32 {
    return app.picture_progress.get();
}

export fn test_picture_failed() bool {
    return app.picture_failed.get();
}
