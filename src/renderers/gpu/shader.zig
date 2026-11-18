// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The GPU renderer's shader (GLSL ES 3.00 / GLSL 3.30), and the same
//! fragment shading in Zig, which reference.zig uses to run frames on the
//! CPU: tests check the batcher's output against the software renderer
//! with it. Keep the two in step.

const std = @import("std");
const batch = @import("batch.zig");
const software = @import("../software/software.zig");
const core = @import("../../core/core.zig");
const Vertex = batch.Vertex;
const Frame = batch.Frame;

/// 3D scenes' vertex shader (gl.zig), after a `#version` line.
pub const vertex_3d =
    \\in vec3 a_position;
    \\in vec3 a_normal;
    \\in vec2 a_texcoord;
    \\uniform mat4 u_world;
    \\uniform mat4 u_normal;
    \\uniform mat4 u_view_proj;
    \\out vec3 v_world;
    \\out vec3 v_normal;
    \\out vec2 v_texcoord;
    \\void main() {
    \\    vec4 w = u_world * vec4(a_position, 1.0);
    \\    gl_Position = u_view_proj * w;
    \\    v_world = w.xyz;
    \\    v_normal = (u_normal * vec4(a_normal, 0.0)).xyz;
    \\    v_texcoord = a_texcoord;
    \\}
;

/// 3D scenes' fragment shader: as raster3d.zig's `shade` (keep them in
/// step, and with metal.zig's and d3d12.zig's). `u_lights` holds two
/// vectors a light: toward it or its position, then its radiance.
pub const fragment_3d =
    \\in vec3 v_world;
    \\in vec3 v_normal;
    \\in vec2 v_texcoord;
    \\uniform vec4 u_base;
    \\uniform vec4 u_params;
    \\uniform vec4 u_eye;
    \\uniform vec4 u_ambient;
    \\uniform int u_light_count;
    \\uniform vec4 u_lights[32];
    \\uniform sampler2D u_texture;
    \\out vec4 o_color;
    \\void main() {
    \\    vec3 b = u_base.rgb;
    \\    float alpha = u_base.a;
    \\    if (u_params.z > 0.5) {
    \\        vec4 t = texture(u_texture, v_texcoord);
    \\        vec3 straight = t.a > 0.0 ? t.rgb / t.a : vec3(0.0);
    \\        b *= straight * straight;
    \\        alpha *= t.a;
    \\    }
    \\    if (alpha <= 0.0) discard;
    \\    vec3 n = normalize(v_normal);
    \\    if (!gl_FrontFacing) n = -n;
    \\    vec3 v = normalize(u_eye.xyz - v_world);
    \\    float metallic = clamp(u_params.x, 0.0, 1.0);
    \\    float rough = clamp(u_params.y, 0.04, 1.0);
    \\    float alpha2 = (rough * rough) * (rough * rough);
    \\    vec3 f0 = mix(vec3(0.04), b, metallic);
    \\    vec3 diffuse = b * (1.0 - metallic);
    \\    float nv = max(dot(n, v), 1e-4);
    \\    float k = (rough + 1.0) * (rough + 1.0) / 8.0;
    \\    vec3 color = u_ambient.rgb * b;
    \\    for (int i = 0; i < u_light_count; i++) {
    \\        vec4 lv = u_lights[2 * i];
    \\        vec4 lr = u_lights[2 * i + 1];
    \\        vec3 to_light = lv.xyz;
    \\        vec3 radiance = lr.rgb;
    \\        if (lv.w > 0.5) {
    \\            vec3 d = lv.xyz - v_world;
    \\            to_light = normalize(d);
    \\            radiance *= 1.0 / (1.0 + dot(d, d) / (lr.w * lr.w));
    \\        }
    \\        float nl = dot(n, to_light);
    \\        if (nl <= 0.0) continue;
    \\        vec3 h = normalize(to_light + v);
    \\        float nh = max(dot(n, h), 0.0);
    \\        float vh = max(dot(v, h), 0.0);
    \\        float dd = nh * nh * (alpha2 - 1.0) + 1.0;
    \\        float distribution = alpha2 / (3.14159265 * dd * dd);
    \\        float geometry = (nv / (nv * (1.0 - k) + k)) * (nl / (nl * (1.0 - k) + k));
    \\        vec3 fresnel = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
    \\        vec3 specular = fresnel * (distribution * geometry / (4.0 * nv * nl));
    \\        color += (diffuse * (1.0 - fresnel) + specular * 3.14159265) * radiance * nl;
    \\    }
    \\    float a = clamp(alpha, 0.0, 1.0);
    \\    o_color = vec4(sqrt(clamp(color, 0.0, 1.0)) * a, a);
    \\}
;

/// The vertex shader, after a `#version` line.
pub const vertex =
    \\in vec2 a_pos;
    \\in vec2 a_uv;
    \\in vec4 a_rect;
    \\in vec4 a_shape;
    \\in vec4 a_clip;
    \\in vec4 a_color;
    \\in vec4 a_paint;
    \\in vec2 a_local;
    \\uniform vec2 u_size;
    \\out vec2 v_pos;
    \\out vec2 v_uv;
    \\flat out vec4 v_rect;
    \\flat out vec4 v_shape;
    \\flat out vec4 v_clip;
    \\flat out vec4 v_color;
    \\flat out vec4 v_paint;
    \\out vec2 v_local;
    \\void main() {
    \\    v_pos = a_pos;
    \\    v_local = a_local;
    \\    v_uv = a_uv;
    \\    v_rect = a_rect;
    \\    v_shape = a_shape;
    \\    v_clip = a_clip;
    \\    v_color = a_color;
    \\    v_paint = a_paint;
    \\    gl_Position = vec4(a_pos.x / u_size.x * 2.0 - 1.0, 1.0 - a_pos.y / u_size.y * 2.0, 0.0, 1.0);
    \\}
    \\
;

/// The fragment shader, after a `#version` line (and precisions).
pub const fragment =
    \\uniform sampler2D u_atlas;
    \\uniform sampler2D u_gradients;
    \\uniform sampler2D u_image;
    \\in vec2 v_pos;
    \\in vec2 v_uv;
    \\flat in vec4 v_rect;
    \\flat in vec4 v_shape;
    \\flat in vec4 v_clip;
    \\flat in vec4 v_color;
    \\flat in vec4 v_paint;
    \\in vec2 v_local;
    \\out vec4 o_color;
    \\
    \\float roundedRect(vec2 p, vec4 r, float radius) {
    \\    vec2 q = abs(p - (r.xy + r.zw * 0.5)) - (r.zw * 0.5 - radius);
    \\    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    \\}
    \\
    \\float erfApprox(float x) {
    \\    float a = abs(x);
    \\    float t = 1.0 + (0.278393 + (0.230389 + 0.078108 * a * a) * a) * a;
    \\    t *= t;
    \\    return sign(x) * (1.0 - 1.0 / (t * t));
    \\}
    \\
    \\float shadowCoverage(vec2 p, vec4 r, float radius, float sigma) {
    \\    float d = roundedRect(p, r, radius);
    \\    if (sigma <= 0.0) return clamp(0.5 - d, 0.0, 1.0);
    \\    float k = 1.0 / (sigma * 1.4142135);
    \\    float across = (erfApprox((p.x - r.x) * k) - erfApprox((p.x - r.x - r.z) * k)) * 0.5;
    \\    float down = (erfApprox((p.y - r.y) * k) - erfApprox((p.y - r.y - r.w) * k)) * 0.5;
    \\    return max(0.0, min(across * down, 0.5 - 0.5 * erfApprox(d * k)));
    \\}
    \\
    \\float atlasAt(vec2 t) {
    \\    return texelFetch(u_atlas, ivec2(clamp(t, vec2(0.0), vec2(1023.0))), 0).r;
    \\}
    \\
    \\void main() {
    \\    vec2 w = v_pos;
    \\    if (w.x < v_clip.x || w.y < v_clip.y || w.x >= v_clip.z || w.y >= v_clip.w) discard;
    \\    vec2 p = v_local;
    \\    int kind = int(v_shape.w + 0.5);
    \\    if (kind == 3) {
    \\        o_color = texture(u_image, v_uv) * v_color;
    \\        return;
    \\    }
    \\    float coverage;
    \\    if (kind == 2 && v_shape.z > 0.5) {
    \\        vec2 f = v_uv - 0.5;
    \\        vec2 i0 = floor(f);
    \\        vec2 t = f - i0;
    \\        coverage = mix(mix(atlasAt(i0), atlasAt(i0 + vec2(1.0, 0.0)), t.x), mix(atlasAt(i0 + vec2(0.0, 1.0)), atlasAt(i0 + vec2(1.0, 1.0)), t.x), t.y);
    \\    } else if (kind == 2) {
    \\        coverage = texelFetch(u_atlas, ivec2(v_uv), 0).r;
    \\    } else if (kind == 4) {
    \\        coverage = texture(u_image, v_uv).a;
    \\    } else if (kind == 5) {
    \\        coverage = shadowCoverage(p, v_rect, v_shape.x, v_shape.y);
    \\    } else {
    \\        float bw = v_shape.y;
    \\        float inside = 0.0;
    \\        if (bw > 0.0) inside = clamp(0.5 - roundedRect(p, vec4(v_rect.xy + bw, v_rect.zw - 2.0 * bw), v_shape.z), 0.0, 1.0);
    \\        coverage = kind == 1 ? inside : clamp(0.5 - roundedRect(p, v_rect, v_shape.x), 0.0, 1.0) - inside;
    \\    }
    \\    vec4 paint = v_color;
    \\    int paint_type = int(v_paint.x + 0.5);
    \\    if (paint_type != 0) {
    \\        vec2 d = p - (v_rect.xy + v_rect.zw * 0.5);
    \\        float t;
    \\        if (paint_type == 1) {
    \\            t = dot(d, v_paint.zw) + 0.5;
    \\        } else {
    \\            t = length(d * v_paint.zw);
    \\        }
    \\        paint = texture(u_gradients, vec2((clamp(t, 0.0, 1.0) * 255.0 + 0.5) / 256.0, v_paint.y)) * v_color;
    \\    }
    \\    o_color = paint * coverage;
    \\}
    \\
;

// ---- The fragment shader in Zig ----

const Vec4 = [4]f32;

fn roundedRect(px: f32, py: f32, r: [4]f32, radius: f32) f32 {
    const qx = @abs(px - (r[0] + r[2] * 0.5)) - (r[2] * 0.5 - radius);
    const qy = @abs(py - (r[1] + r[3] * 0.5)) - (r[3] * 0.5 - radius);
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - radius;
}

fn scale4(v: Vec4, k: f32) Vec4 {
    return .{ v[0] * k, v[1] * k, v[2] * k, v[3] * k };
}

fn mul4(a: Vec4, b: Vec4) Vec4 {
    return .{ a[0] * b[0], a[1] * b[1], a[2] * b[2], a[3] * b[3] };
}

/// GL_LINEAR sampling with clamping to the edges, of RGBA texels.
fn linear(texels: []const u8, width: u32, height: u32, u: f32, v: f32) Vec4 {
    const fx = std.math.clamp(u * @as(f32, @floatFromInt(width)) - 0.5, 0, @as(f32, @floatFromInt(width - 1)));
    const fy = std.math.clamp(v * @as(f32, @floatFromInt(height)) - 0.5, 0, @as(f32, @floatFromInt(height - 1)));
    const x0: u32 = @intFromFloat(@floor(fx));
    const y0: u32 = @intFromFloat(@floor(fy));
    const x1 = @min(x0 + 1, width - 1);
    const y1 = @min(y0 + 1, height - 1);
    const tx = fx - @floor(fx);
    const ty = fy - @floor(fy);
    var out: Vec4 = .{ 0, 0, 0, 0 };
    const taps = [4]struct { u32, u32, f32 }{ .{ x0, y0, (1 - tx) * (1 - ty) }, .{ x1, y0, tx * (1 - ty) }, .{ x0, y1, (1 - tx) * ty }, .{ x1, y1, tx * ty } };
    for (taps) |t| {
        const i = (@as(usize, t[1]) * width + t[0]) * 4;
        for (0..4) |c| out[c] += @as(f32, @floatFromInt(texels[i + c])) / 255 * t[2];
    }
    return out;
}

/// Coverage between atlas texels (`uv` in texels), for rotated or scaled
/// glyphs: the four around, weighted (texel fetches, as the GPU shaders).
fn atlasLinear(atlas: []const u8, u: f32, v: f32) f32 {
    const fx = u - 0.5;
    const fy = v - 0.5;
    const x0 = @floor(fx);
    const y0 = @floor(fy);
    const tx = fx - x0;
    const ty = fy - y0;
    const max: f32 = batch.atlas_size - 1;
    const at = struct {
        fn f(a: []const u8, x: f32, y: f32, m: f32) f32 {
            const xi: usize = @intFromFloat(std.math.clamp(x, 0, m));
            const yi: usize = @intFromFloat(std.math.clamp(y, 0, m));
            return @as(f32, @floatFromInt(a[yi * batch.atlas_size + xi])) / 255;
        }
    }.f;
    const top = at(atlas, x0, y0, max) * (1 - tx) + at(atlas, x0 + 1, y0, max) * tx;
    const bottom = at(atlas, x0, y0 + 1, max) * (1 - tx) + at(atlas, x0 + 1, y0 + 1, max) * tx;
    return top * (1 - ty) + bottom * ty;
}

fn nearest(texels: []const u8, width: u32, height: u32, u: f32, v: f32) Vec4 {
    const x: usize = @intFromFloat(std.math.clamp(@floor(u * @as(f32, @floatFromInt(width))), 0, @as(f32, @floatFromInt(width - 1))));
    const y: usize = @intFromFloat(std.math.clamp(@floor(v * @as(f32, @floatFromInt(height))), 0, @as(f32, @floatFromInt(height - 1))));
    const i = (y * width + x) * 4;
    var out: Vec4 = undefined;
    for (0..4) |c| out[c] = @as(f32, @floatFromInt(texels[i + c])) / 255;
    return out;
}

/// The premultiplied color of the pixel centered at `p`, of a quad whose
/// attributes are `v` (with `uv` interpolated); null if discarded.
pub fn shade(frame: *const Frame, draw: batch.Draw, v: *const Vertex, window: [2]f32, p: [2]f32, uv: [2]f32) ?Vec4 {
    if (window[0] < v.clip[0] or window[1] < v.clip[1] or window[0] >= v.clip[2] or window[1] >= v.clip[3]) return null;
    const kind: u8 = @intFromFloat(v.shape[3] + 0.5);
    const img: ?core.Image = if (draw.image) |i| frame.images[i] else null;
    const imageSample = struct {
        fn f(im: core.Image, d: batch.Draw, u: f32, w: f32) Vec4 {
            const texels = std.mem.sliceAsBytes(im.pixels);
            return if (d.smooth) linear(texels, im.width, im.height, u, w) else nearest(texels, im.width, im.height, u, w);
        }
    }.f;
    if (kind == 3) return mul4(imageSample(img.?, draw, uv[0], uv[1]), v.color);
    var coverage: f32 = undefined;
    if (kind == 2 and v.shape[2] > 0.5) {
        coverage = atlasLinear(frame.atlas, uv[0], uv[1]);
    } else if (kind == 2) {
        const x: usize = @intFromFloat(@floor(uv[0]));
        const y: usize = @intFromFloat(@floor(uv[1]));
        coverage = @as(f32, @floatFromInt(frame.atlas[y * batch.atlas_size + x])) / 255;
    } else if (kind == 4) {
        coverage = imageSample(img.?, draw, uv[0], uv[1])[3];
    } else if (kind == 5) {
        coverage = software.shadowCoverage(p[0], p[1], .{ .x = v.rect[0], .y = v.rect[1], .width = v.rect[2], .height = v.rect[3] }, v.shape[0], v.shape[1]);
    } else {
        const bw = v.shape[1];
        var inside: f32 = 0;
        if (bw > 0) inside = std.math.clamp(0.5 - roundedRect(p[0], p[1], .{ v.rect[0] + bw, v.rect[1] + bw, v.rect[2] - 2 * bw, v.rect[3] - 2 * bw }, v.shape[2]), 0, 1);
        coverage = if (kind == 1) inside else std.math.clamp(0.5 - roundedRect(p[0], p[1], v.rect, v.shape[0]), 0, 1) - inside;
    }
    var paint = v.color;
    const t_kind: u8 = @intFromFloat(v.paint[0] + 0.5);
    if (t_kind != 0) {
        const dx = p[0] - (v.rect[0] + v.rect[2] * 0.5);
        const dy = p[1] - (v.rect[1] + v.rect[3] * 0.5);
        var t: f32 = undefined;
        if (t_kind == 1) {
            t = dx * v.paint[2] + dy * v.paint[3] + 0.5;
        } else {
            const rx = dx * v.paint[2];
            const ry = dy * v.paint[3];
            t = @sqrt(rx * rx + ry * ry);
        }
        const u = (std.math.clamp(t, 0, 1) * 255 + 0.5) / 256;
        paint = mul4(linear(frame.gradients, batch.gradient_width, batch.gradient_rows, u, v.paint[1]), v.color);
    }
    return scale4(paint, coverage);
}
