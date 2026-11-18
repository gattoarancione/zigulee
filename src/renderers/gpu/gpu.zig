// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The GPU renderer: draws windows with OpenGL 3.3 or OpenGL ES 3.0
//! (WebGL2-compatible), with the same results as the software renderer.
//!
//! batch.zig turns a window's display list into quads and textures (no GPU
//! needed); gl.zig draws them. reference.zig runs frames on the CPU, for
//! tests.

pub const batch = @import("batch.zig");
pub const shader = @import("shader.zig");
pub const reference = @import("reference.zig");
pub const gl = @import("gl.zig");
/// The GPU renderer on Vulkan.
pub const vulkan = @import("vulkan.zig");
pub const fuzz_targets = @import("fuzz_test.zig");

pub const Batcher = batch.Batcher;
pub const Frame = batch.Frame;

test {
    _ = batch;
    _ = shader;
    _ = reference;
    _ = gl;
    _ = vulkan;
    _ = fuzz_targets;
}
