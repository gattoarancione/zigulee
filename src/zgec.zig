// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Root of the `zgec` compiler module (it lives at `src/` so the compiler
//! can reuse runtime code such as the PNG decoder).

pub const compiler = @import("compiler/compiler.zig");
pub const main = @import("compiler/main.zig").main;

test {
    _ = compiler;
}
