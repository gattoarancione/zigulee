// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

// The GPU renderer's fragment shader for Vulkan (as shader.zig's GLSL;
// keep them in step). Compiled to vulkan.frag.spv by `zig build
// vulkan-shaders`.
#version 450
layout(set = 0, binding = 0) uniform sampler2D u_atlas;
layout(set = 0, binding = 1) uniform sampler2D u_gradients;
layout(set = 0, binding = 2) uniform sampler2D u_image;
layout(location = 0) in vec2 v_pos;
layout(location = 1) in vec2 v_uv;
layout(location = 2) flat in vec4 v_rect;
layout(location = 3) flat in vec4 v_shape;
layout(location = 4) flat in vec4 v_clip;
layout(location = 5) flat in vec4 v_color;
layout(location = 6) flat in vec4 v_paint;
layout(location = 7) in vec2 v_local;
layout(location = 0) out vec4 o_color;

float roundedRect(vec2 p, vec4 r, float radius) {
    vec2 q = abs(p - (r.xy + r.zw * 0.5)) - (r.zw * 0.5 - radius);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

float erfApprox(float x) {
    float a = abs(x);
    float t = 1.0 + (0.278393 + (0.230389 + 0.078108 * a * a) * a) * a;
    t *= t;
    return sign(x) * (1.0 - 1.0 / (t * t));
}

float shadowCoverage(vec2 p, vec4 r, float radius, float sigma) {
    float d = roundedRect(p, r, radius);
    if (sigma <= 0.0) return clamp(0.5 - d, 0.0, 1.0);
    float k = 1.0 / (sigma * 1.4142135);
    float across = (erfApprox((p.x - r.x) * k) - erfApprox((p.x - r.x - r.z) * k)) * 0.5;
    float down = (erfApprox((p.y - r.y) * k) - erfApprox((p.y - r.y - r.w) * k)) * 0.5;
    return max(0.0, min(across * down, 0.5 - 0.5 * erfApprox(d * k)));
}

float atlasAt(vec2 t) {
    return texelFetch(u_atlas, ivec2(clamp(t, vec2(0.0), vec2(1023.0))), 0).r;
}

void main() {
    vec2 w = v_pos;
    if (w.x < v_clip.x || w.y < v_clip.y || w.x >= v_clip.z || w.y >= v_clip.w) discard;
    vec2 p = v_local;
    int kind = int(v_shape.w + 0.5);
    if (kind == 3) {
        o_color = texture(u_image, v_uv) * v_color;
        return;
    }
    float coverage;
    if (kind == 2 && v_shape.z > 0.5) {
        vec2 f = v_uv - 0.5;
        vec2 i0 = floor(f);
        vec2 t = f - i0;
        coverage = mix(mix(atlasAt(i0), atlasAt(i0 + vec2(1.0, 0.0)), t.x), mix(atlasAt(i0 + vec2(0.0, 1.0)), atlasAt(i0 + vec2(1.0, 1.0)), t.x), t.y);
    } else if (kind == 2) {
        coverage = texelFetch(u_atlas, ivec2(v_uv), 0).r;
    } else if (kind == 4) {
        coverage = texture(u_image, v_uv).a;
    } else if (kind == 5) {
        coverage = shadowCoverage(p, v_rect, v_shape.x, v_shape.y);
    } else {
        float bw = v_shape.y;
        float inside = 0.0;
        if (bw > 0.0) inside = clamp(0.5 - roundedRect(p, vec4(v_rect.xy + bw, v_rect.zw - 2.0 * bw), v_shape.z), 0.0, 1.0);
        coverage = kind == 1 ? inside : clamp(0.5 - roundedRect(p, v_rect, v_shape.x), 0.0, 1.0) - inside;
    }
    vec4 paint = v_color;
    int paint_type = int(v_paint.x + 0.5);
    if (paint_type != 0) {
        vec2 d = p - (v_rect.xy + v_rect.zw * 0.5);
        float t;
        if (paint_type == 1) {
            t = dot(d, v_paint.zw) + 0.5;
        } else {
            t = length(d * v_paint.zw);
        }
        paint = texture(u_gradients, vec2((clamp(t, 0.0, 1.0) * 255.0 + 0.5) / 256.0, v_paint.y)) * v_color;
    }
    o_color = paint * coverage;
}
