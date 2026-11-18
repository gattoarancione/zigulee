// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

// 3D scenes' vertex shader for Vulkan (as shader.zig's `vertex_3d`; keep
// them in step). Compiled to vulkan3d.vert.spv by `zig build
// vulkan-shaders`. The normal matrix is worked out here: push constants
// have room for the world matrix and the material only.
#version 450
layout(location = 0) in vec3 a_position;
layout(location = 1) in vec3 a_normal;
layout(location = 2) in vec2 a_texcoord;
layout(push_constant) uniform Inst { mat4 world; vec4 base; vec4 params; } inst;
layout(set = 0, binding = 0, std140) uniform Frame { mat4 view_proj; vec4 eye; vec4 ambient; ivec4 counts; vec4 lights[32]; } frame;
layout(location = 0) out vec3 v_world;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec2 v_texcoord;
void main() {
    vec4 w = inst.world * vec4(a_position, 1.0);
    gl_Position = frame.view_proj * w;
    v_world = w.xyz;
    v_normal = transpose(inverse(mat3(inst.world))) * a_normal;
    v_texcoord = a_texcoord;
}
