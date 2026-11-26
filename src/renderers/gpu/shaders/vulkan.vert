// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

// The GPU renderer's vertex shader for Vulkan (as shader.zig's GLSL; keep
// them in step). Compiled to vulkan.vert.spv by `zig build vulkan-shaders`.
#version 450
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_rect;
layout(location = 3) in vec4 a_shape;
layout(location = 4) in vec4 a_clip;
layout(location = 5) in vec4 a_color;
layout(location = 6) in vec4 a_paint;
layout(location = 7) in vec2 a_local;
layout(push_constant) uniform Push { vec2 size; } push;
layout(location = 0) out vec2 v_pos;
layout(location = 1) out vec2 v_uv;
layout(location = 2) flat out vec4 v_rect;
layout(location = 3) flat out vec4 v_shape;
layout(location = 4) flat out vec4 v_clip;
layout(location = 5) flat out vec4 v_color;
layout(location = 6) flat out vec4 v_paint;
layout(location = 7) out vec2 v_local;
void main() {
    v_pos = a_pos;
    v_uv = a_uv;
    v_rect = a_rect;
    v_shape = a_shape;
    v_clip = a_clip;
    v_color = a_color;
    v_paint = a_paint;
    v_local = a_local;
    // Vulkan's y goes down.
    gl_Position = vec4(a_pos.x / push.size.x * 2.0 - 1.0, a_pos.y / push.size.y * 2.0 - 1.0, 0.0, 1.0);
}
