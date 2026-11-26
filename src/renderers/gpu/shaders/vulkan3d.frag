// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

// 3D scenes' fragment shader for Vulkan: as raster3d.zig's `shade` (keep
// them in step, and with shader.zig's `fragment_3d`). Compiled to
// vulkan3d.frag.spv by `zig build vulkan-shaders`. `frame.lights` holds
// two vectors a light: toward it or its position, then its radiance.
#version 450
layout(location = 0) in vec3 v_world;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec2 v_texcoord;
layout(push_constant) uniform Inst { mat4 world; vec4 base; vec4 params; } inst;
layout(set = 0, binding = 0, std140) uniform Frame { mat4 view_proj; vec4 eye; vec4 ambient; ivec4 counts; vec4 lights[32]; } frame;
layout(set = 1, binding = 0) uniform sampler2D u_texture;
layout(location = 0) out vec4 o_color;
void main() {
    vec3 b = inst.base.rgb;
    float alpha = inst.base.a;
    if (inst.params.z > 0.5) {
        vec4 t = texture(u_texture, v_texcoord);
        vec3 straight = t.a > 0.0 ? t.rgb / t.a : vec3(0.0);
        b *= straight * straight;
        alpha *= t.a;
    }
    if (alpha <= 0.0) discard;
    vec3 n = normalize(v_normal);
    if (!gl_FrontFacing) n = -n;
    vec3 v = normalize(frame.eye.xyz - v_world);
    float metallic = clamp(inst.params.x, 0.0, 1.0);
    float rough = clamp(inst.params.y, 0.04, 1.0);
    float alpha2 = (rough * rough) * (rough * rough);
    vec3 f0 = mix(vec3(0.04), b, metallic);
    vec3 diffuse = b * (1.0 - metallic);
    float nv = max(dot(n, v), 1e-4);
    float k = (rough + 1.0) * (rough + 1.0) / 8.0;
    vec3 color = frame.ambient.rgb * b;
    for (int i = 0; i < frame.counts.x; i++) {
        vec4 lv = frame.lights[2 * i];
        vec4 lr = frame.lights[2 * i + 1];
        vec3 to_light = lv.xyz;
        vec3 radiance = lr.rgb;
        if (lv.w > 0.5) {
            vec3 d = lv.xyz - v_world;
            to_light = normalize(d);
            radiance *= 1.0 / (1.0 + dot(d, d) / (lr.w * lr.w));
        }
        float nl = dot(n, to_light);
        if (nl <= 0.0) continue;
        vec3 h = normalize(to_light + v);
        float nh = max(dot(n, h), 0.0);
        float vh = max(dot(v, h), 0.0);
        float dd = nh * nh * (alpha2 - 1.0) + 1.0;
        float distribution = alpha2 / (3.14159265 * dd * dd);
        float geometry = (nv / (nv * (1.0 - k) + k)) * (nl / (nl * (1.0 - k) + k));
        vec3 fresnel = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
        vec3 specular = fresnel * (distribution * geometry / (4.0 * nv * nl));
        color += (diffuse * (1.0 - fresnel) + specular * 3.14159265) * radiance * nl;
    }
    float a = clamp(alpha, 0.0, 1.0);
    o_color = vec4(sqrt(clamp(color, 0.0, 1.0)) * a, a);
}
