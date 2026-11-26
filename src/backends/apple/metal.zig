// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The GPU renderer on Metal: draws the batcher's frames
//! (src/renderers/gpu/batch.zig) with the same shading as the OpenGL
//! executor (shader.zig), here in Metal Shading Language, compiled when the
//! renderer is created. Frames are drawn into a texture that keeps the last
//! one (partial frames redraw only what changed), then copied to the
//! drawable of a CAMetalLayer.
//!
//! 3D scenes (`View3D`) are drawn here too, each into a texture of its own
//! (multisampled, with a depth buffer), shaded as raster3d.zig shades them
//! on the CPU; the frame then shows that texture as an image.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const batch = zigulee.gpu.batch;
const objc = @import("objc.zig");
const id = objc.id;
const msg = objc.msg;
const class = objc.class;
const nsString = objc.nsString;

const log = std.log.scoped(.zigulee_metal);

extern "c" fn MTLCreateSystemDefaultDevice() id;

const MTLOrigin = extern struct { x: usize = 0, y: usize = 0, z: usize = 0 };
const MTLSize = extern struct { width: usize, height: usize, depth: usize = 1 };
const MTLRegion = extern struct { origin: MTLOrigin = .{}, size: MTLSize };
const MTLClearColor = extern struct { red: f64 = 0, green: f64 = 0, blue: f64 = 0, alpha: f64 = 0 };
const MTLScissorRect = extern struct { x: usize, y: usize, width: usize, height: usize };

const pixel_bgra8 = 80; // MTLPixelFormatBGRA8Unorm
const pixel_rgba8 = 70;
const pixel_r8 = 10;
const usage_shader_read = 1;
const usage_render_target = 4;
const storage_private = 2;
const blend_one = 1;
const blend_one_minus_source_alpha = 5;
const load_load = 1;
const load_clear = 2;
const store_store = 1;
const primitive_triangle = 3;
const pixel_depth32 = 252;
const texture_2d_multisample = 4;
const store_multisample_resolve = 2;
const compare_less = 1;
const cull_none = 0;
const cull_back = 2;
const winding_counter_clockwise = 1;
const samples_3d = 4;
const primitive_triangle_strip = 4;
const index_uint32 = 1;

/// The shaders: as shader.zig's GLSL (keep them in step).
const source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct Vertex { float2 pos; float2 uv; float4 rect; float4 shape; float4 clip; float4 color; float4 paint; float2 local; float2 pad; };
    \\struct Varyings {
    \\    float4 position [[position]];
    \\    float2 pos;
    \\    float2 uv;
    \\    float4 rect [[flat]];
    \\    float4 shape [[flat]];
    \\    float4 clip [[flat]];
    \\    float4 color [[flat]];
    \\    float4 paint [[flat]];
    \\    float2 local;
    \\};
    \\
    \\vertex Varyings vs(uint vid [[vertex_id]], const device Vertex* vertices [[buffer(0)]], constant float2& size [[buffer(1)]]) {
    \\    Vertex v = vertices[vid];
    \\    Varyings o;
    \\    o.position = float4(v.pos.x / size.x * 2.0 - 1.0, 1.0 - v.pos.y / size.y * 2.0, 0.0, 1.0);
    \\    o.pos = v.pos; o.uv = v.uv; o.rect = v.rect; o.shape = v.shape; o.clip = v.clip; o.color = v.color; o.paint = v.paint; o.local = v.local;
    \\    return o;
    \\}
    \\
    \\float roundedRect(float2 p, float4 r, float radius) {
    \\    float2 q = abs(p - (r.xy + r.zw * 0.5)) - (r.zw * 0.5 - radius);
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
    \\float shadowCoverage(float2 p, float4 r, float radius, float sigma) {
    \\    float d = roundedRect(p, r, radius);
    \\    if (sigma <= 0.0) return clamp(0.5 - d, 0.0, 1.0);
    \\    float k = 1.0 / (sigma * 1.4142135);
    \\    float across = (erfApprox((p.x - r.x) * k) - erfApprox((p.x - r.x - r.z) * k)) * 0.5;
    \\    float down = (erfApprox((p.y - r.y) * k) - erfApprox((p.y - r.y - r.w) * k)) * 0.5;
    \\    return max(0.0, min(across * down, 0.5 - 0.5 * erfApprox(d * k)));
    \\}
    \\
    \\fragment float4 fs(Varyings in [[stage_in]],
    \\                   texture2d<float> atlas [[texture(0)]],
    \\                   texture2d<float> gradients [[texture(1)]],
    \\                   texture2d<float> image [[texture(2)]],
    \\                   sampler smooth [[sampler(0)]],
    \\                   sampler image_sampler [[sampler(1)]]) {
    \\    float2 w = in.pos;
    \\    if (w.x < in.clip.x || w.y < in.clip.y || w.x >= in.clip.z || w.y >= in.clip.w) discard_fragment();
    \\    float2 p = in.local;
    \\    int kind = int(in.shape.w + 0.5);
    \\    if (kind == 3) return image.sample(image_sampler, in.uv) * in.color;
    \\    float coverage;
    \\    if (kind == 2 && in.shape.z > 0.5) {
    \\        float2 f = in.uv - 0.5;
    \\        float2 i0 = floor(f);
    \\        float2 t = f - i0;
    \\        uint2 a = uint2(clamp(i0, float2(0.0), float2(1023.0)));
    \\        uint2 b = uint2(clamp(i0 + 1.0, float2(0.0), float2(1023.0)));
    \\        coverage = mix(mix(atlas.read(a).r, atlas.read(uint2(b.x, a.y)).r, t.x), mix(atlas.read(uint2(a.x, b.y)).r, atlas.read(b).r, t.x), t.y);
    \\    } else if (kind == 2) {
    \\        coverage = atlas.read(uint2(in.uv)).r;
    \\    } else if (kind == 4) {
    \\        coverage = image.sample(image_sampler, in.uv).a;
    \\    } else if (kind == 5) {
    \\        coverage = shadowCoverage(p, in.rect, in.shape.x, in.shape.y);
    \\    } else {
    \\        float bw = in.shape.y;
    \\        float inside = 0.0;
    \\        if (bw > 0.0) inside = clamp(0.5 - roundedRect(p, float4(in.rect.xy + bw, in.rect.zw - 2.0 * bw), in.shape.z), 0.0, 1.0);
    \\        coverage = kind == 1 ? inside : clamp(0.5 - roundedRect(p, in.rect, in.shape.x), 0.0, 1.0) - inside;
    \\    }
    \\    float4 paint = in.color;
    \\    int paint_type = int(in.paint.x + 0.5);
    \\    if (paint_type != 0) {
    \\        float2 d = p - (in.rect.xy + in.rect.zw * 0.5);
    \\        float t;
    \\        if (paint_type == 1) {
    \\            t = dot(d, in.paint.zw) + 0.5;
    \\        } else {
    \\            t = length(d * in.paint.zw);
    \\        }
    \\        paint = gradients.sample(smooth, float2((clamp(t, 0.0, 1.0) * 255.0 + 0.5) / 256.0, in.paint.y)) * in.color;
    \\    }
    \\    return paint * coverage;
    \\}
    \\
    \\// Clears (no blending): the area a partial frame redraws.
    \\fragment float4 fs_clear(Varyings in [[stage_in]]) { return float4(0.0); }
    \\
;

/// 3D scenes' shaders: as raster3d.zig's `shade` (keep them in step).
const source_3d =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct V3 { packed_float3 pos; packed_float3 normal; float2 uv; };
    \\struct Inst { float4x4 world; float4x4 normal; float4 base; float4 params; };
    \\struct Light3 { float4 vec; float4 radiance; };
    \\struct Frame3 { float4x4 view_proj; float4 eye; float4 ambient; uint4 counts; Light3 lights[16]; };
    \\struct V3Out { float4 position [[position]]; float3 world; float3 normal; float2 uv; };
    \\
    \\vertex V3Out vs3(uint vid [[vertex_id]], const device V3* vertices [[buffer(0)]], constant Inst& inst [[buffer(1)]], constant Frame3& f [[buffer(2)]]) {
    \\    V3 v = vertices[vid];
    \\    float4 world = inst.world * float4(float3(v.pos), 1.0);
    \\    V3Out o;
    \\    o.position = f.view_proj * world;
    \\    o.world = world.xyz;
    \\    o.normal = (inst.normal * float4(float3(v.normal), 0.0)).xyz;
    \\    o.uv = v.uv;
    \\    return o;
    \\}
    \\
    \\fragment float4 fs3(V3Out in [[stage_in]], bool front [[front_facing]], constant Inst& inst [[buffer(1)]], constant Frame3& f [[buffer(2)]],
    \\                    texture2d<float> tex [[texture(0)]], sampler repeat [[sampler(0)]]) {
    \\    float3 base = inst.base.rgb;
    \\    float alpha = inst.base.a;
    \\    if (inst.params.z > 0.5) {
    \\        float4 t = tex.sample(repeat, in.uv);
    \\        float3 straight = t.a > 0.0 ? t.rgb / t.a : float3(0.0);
    \\        base *= straight * straight;
    \\        alpha *= t.a;
    \\    }
    \\    if (alpha <= 0.0) discard_fragment();
    \\    float3 n = normalize(in.normal);
    \\    if (!front) n = -n;
    \\    float3 v = normalize(f.eye.xyz - in.world);
    \\    float metallic = clamp(inst.params.x, 0.0, 1.0);
    \\    float rough = clamp(inst.params.y, 0.04, 1.0);
    \\    float alpha2 = (rough * rough) * (rough * rough);
    \\    float3 f0 = mix(float3(0.04), base, metallic);
    \\    float3 diffuse = base * (1.0 - metallic);
    \\    float nv = max(dot(n, v), 1e-4);
    \\    float k = (rough + 1.0) * (rough + 1.0) / 8.0;
    \\    float3 color = f.ambient.rgb * base;
    \\    for (uint i = 0; i < f.counts.x; i++) {
    \\        Light3 l = f.lights[i];
    \\        float3 to_light = l.vec.xyz;
    \\        float3 radiance = l.radiance.rgb;
    \\        if (l.vec.w > 0.5) {
    \\            float3 d = l.vec.xyz - in.world;
    \\            to_light = normalize(d);
    \\            radiance *= 1.0 / (1.0 + dot(d, d) / (l.radiance.w * l.radiance.w));
    \\        }
    \\        float nl = dot(n, to_light);
    \\        if (nl <= 0.0) continue;
    \\        float3 h = normalize(to_light + v);
    \\        float nh = max(dot(n, h), 0.0);
    \\        float vh = max(dot(v, h), 0.0);
    \\        float dd = nh * nh * (alpha2 - 1.0) + 1.0;
    \\        float distribution = alpha2 / (3.14159265 * dd * dd);
    \\        float geometry = (nv / (nv * (1.0 - k) + k)) * (nl / (nl * (1.0 - k) + k));
    \\        float3 fresnel = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
    \\        float3 specular = fresnel * (distribution * geometry / (4.0 * nv * nl));
    \\        color += (diffuse * (1.0 - fresnel) + specular * 3.14159265) * radiance * nl;
    \\    }
    \\    float a = clamp(alpha, 0.0, 1.0);
    \\    return float4(sqrt(clamp(color, 0.0, 1.0)) * a, a);
    \\}
;

const Inst3 = core.raster3d.GpuInstance;
const Frame3 = core.raster3d.GpuFrame;

pub const Error = error{ MetalUnavailable, ShaderFailed } || Allocator.Error;

pub const Renderer = struct {
    gpa: Allocator,
    batcher: batch.Batcher,
    device: id,
    queue: id,
    pipeline: id,
    clear_pipeline: id,
    smooth: id,
    sharp: id,
    atlas: id,
    gradients: id,
    blank: id,
    /// Frames are drawn here, then copied to the drawable: it keeps the
    /// last frame for partial ones.
    target: id = null,
    target_size: [2]u32 = .{ 0, 0 },
    target_valid: bool = false,
    images: std.ArrayList(ImageTexture) = .empty,
    frame_number: u64 = 0,
    /// 3D: the pipeline, depth test and samplers; meshes' buffers and
    /// scenes' textures, kept while used.
    pipeline_3d: id = null,
    depth_less: id = null,
    repeat: id = null,
    meshes: std.ArrayList(MeshBuffers) = .empty,
    scenes: std.ArrayList(SceneTexture) = .empty,

    const ImageTexture = struct { image: core.Image, texture: id, used: u64 };
    const MeshBuffers = struct { vertices_ptr: usize, len: usize, index_ptr: usize, vertices: id, indices: id, count: usize, used: u64 };
    const SceneTexture = struct { key: u64, width: u32, height: u32, color: id, depth: id, resolved: id, used: u64 };
    const keep_frames = 120;
    /// A cached image superseded by a newer version (see `Image.supersedes`):
    /// evicted at the next opportunity.
    const stale = std.math.maxInt(u64);

    pub fn init(gpa: Allocator) Error!Renderer {
        const pool = objc.objc_autoreleasePoolPush();
        defer objc.objc_autoreleasePoolPop(pool);
        const device = MTLCreateSystemDefaultDevice() orelse return error.MetalUnavailable;
        errdefer msg(void, device, "release", .{});
        var err: id = null;
        const library = msg(id, device, "newLibraryWithSource:options:error:", .{ nsString(source), @as(id, null), &err }) orelse {
            log.err("compiling the Metal shaders failed: {s}", .{objc.utf8(msg(id, err, "localizedDescription", .{}))});
            return error.ShaderFailed;
        };
        defer msg(void, library, "release", .{});
        const vs = msg(id, library, "newFunctionWithName:", .{nsString("vs")});
        defer msg(void, vs, "release", .{});
        const fs = msg(id, library, "newFunctionWithName:", .{nsString("fs")});
        defer msg(void, fs, "release", .{});
        const fs_clear = msg(id, library, "newFunctionWithName:", .{nsString("fs_clear")});
        defer msg(void, fs_clear, "release", .{});

        const pipeline = try makePipeline(device, vs, fs, true);
        errdefer msg(void, pipeline, "release", .{});
        const clear_pipeline = try makePipeline(device, vs, fs_clear, false);
        errdefer msg(void, clear_pipeline, "release", .{});

        var r: Renderer = .{
            .gpa = gpa,
            .batcher = try .init(gpa),
            .device = device,
            .queue = msg(id, device, "newCommandQueue", .{}),
            .pipeline = pipeline,
            .clear_pipeline = clear_pipeline,
            .smooth = sampler(device, true),
            .sharp = sampler(device, false),
            .atlas = null,
            .gradients = null,
            .blank = null,
        };
        r.atlas = r.texture(pixel_r8, batch.atlas_size, batch.atlas_size, usage_shader_read, null);
        r.gradients = r.texture(pixel_rgba8, batch.gradient_width, batch.gradient_rows, usage_shader_read, null);
        r.blank = r.texture(pixel_rgba8, 1, 1, usage_shader_read, null);
        replace(r.blank, 0, 0, 1, 1, &[4]u8{ 0, 0, 0, 0 }, 4);
        r.init3d() catch |e| log.info("no 3D on the GPU ({t}): scenes drawn on the CPU", .{e});
        r.batcher.gpu_scenes = r.pipeline_3d != null;
        return r;
    }

    fn init3d(r: *Renderer) Error!void {
        var err: id = null;
        const library = msg(id, r.device, "newLibraryWithSource:options:error:", .{ nsString(source_3d), @as(id, null), &err }) orelse {
            log.info("compiling the 3D shaders failed: {s}", .{objc.utf8(msg(id, err, "localizedDescription", .{}))});
            return error.ShaderFailed;
        };
        defer msg(void, library, "release", .{});
        const vs = msg(id, library, "newFunctionWithName:", .{nsString("vs3")});
        defer msg(void, vs, "release", .{});
        const fs = msg(id, library, "newFunctionWithName:", .{nsString("fs3")});
        defer msg(void, fs, "release", .{});
        const desc = msg(id, msg(id, class("MTLRenderPipelineDescriptor"), "alloc", .{}), "init", .{});
        defer msg(void, desc, "release", .{});
        msg(void, desc, "setVertexFunction:", .{vs});
        msg(void, desc, "setFragmentFunction:", .{fs});
        msg(void, desc, "setRasterSampleCount:", .{@as(usize, samples_3d)});
        msg(void, desc, "setDepthAttachmentPixelFormat:", .{@as(usize, pixel_depth32)});
        const color = msg(id, msg(id, desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(usize, 0)});
        msg(void, color, "setPixelFormat:", .{@as(usize, pixel_rgba8)});
        // Premultiplied alpha (see-through materials over what is behind).
        msg(void, color, "setBlendingEnabled:", .{true});
        msg(void, color, "setSourceRGBBlendFactor:", .{@as(usize, blend_one)});
        msg(void, color, "setSourceAlphaBlendFactor:", .{@as(usize, blend_one)});
        msg(void, color, "setDestinationRGBBlendFactor:", .{@as(usize, blend_one_minus_source_alpha)});
        msg(void, color, "setDestinationAlphaBlendFactor:", .{@as(usize, blend_one_minus_source_alpha)});
        r.pipeline_3d = msg(id, r.device, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err }) orelse {
            log.info("making the 3D pipeline failed: {s}", .{objc.utf8(msg(id, err, "localizedDescription", .{}))});
            return error.ShaderFailed;
        };
        const depth_desc = msg(id, msg(id, class("MTLDepthStencilDescriptor"), "alloc", .{}), "init", .{});
        defer msg(void, depth_desc, "release", .{});
        msg(void, depth_desc, "setDepthCompareFunction:", .{@as(usize, compare_less)});
        msg(void, depth_desc, "setDepthWriteEnabled:", .{true});
        r.depth_less = msg(id, r.device, "newDepthStencilStateWithDescriptor:", .{depth_desc});
        const sdesc = msg(id, msg(id, class("MTLSamplerDescriptor"), "alloc", .{}), "init", .{});
        defer msg(void, sdesc, "release", .{});
        msg(void, sdesc, "setMinFilter:", .{@as(usize, 1)});
        msg(void, sdesc, "setMagFilter:", .{@as(usize, 1)});
        msg(void, sdesc, "setSAddressMode:", .{@as(usize, 2)}); // repeat
        msg(void, sdesc, "setTAddressMode:", .{@as(usize, 2)});
        r.repeat = msg(id, r.device, "newSamplerStateWithDescriptor:", .{sdesc});
    }

    pub fn deinit(r: *Renderer) void {
        for (r.images.items) |it| msg(void, it.texture, "release", .{});
        r.images.deinit(r.gpa);
        for (r.meshes.items) |m| {
            msg(void, m.vertices, "release", .{});
            msg(void, m.indices, "release", .{});
        }
        r.meshes.deinit(r.gpa);
        for (r.scenes.items) |sc| for ([_]id{ sc.color, sc.depth, sc.resolved }) |o| msg(void, o, "release", .{});
        r.scenes.deinit(r.gpa);
        for ([_]id{ r.pipeline_3d, r.depth_less, r.repeat }) |o| if (o != null) msg(void, o, "release", .{});
        for ([_]id{ r.target, r.atlas, r.gradients, r.blank, r.smooth, r.sharp, r.pipeline, r.clear_pipeline, r.queue, r.device }) |o| {
            if (o != null) msg(void, o, "release", .{});
        }
        r.batcher.deinit();
    }

    pub fn setScaleFactor(r: *Renderer, scale: f32) void {
        r.batcher.scale_factor = scale;
    }

    /// Draws the window, `width` x `height` pixels (everything, or in
    /// `.partial` mode what changed), and presents it in `layer` (a
    /// CAMetalLayer whose drawable size is that; null: only drawn, see
    /// `readPixels`). Returns the area redrawn; when empty, nothing was
    /// drawn or presented.
    pub fn renderWindow(r: *Renderer, window: *core.Window, width: u32, height: u32, mode: core.RenderMode, layer: id) Allocator.Error!core.Region {
        const full = mode == .full or !r.target_valid or r.target_size[0] != width or r.target_size[1] != height;
        const frame = try r.batcher.build(window, width, height, if (full) .full else .partial);
        if (frame.region.isEmpty()) return .{};
        try r.draw(&frame, layer);
        return frame.region;
    }

    fn draw(r: *Renderer, frame: *const batch.Frame, layer: id) Allocator.Error!void {
        const pool = objc.objc_autoreleasePoolPush();
        defer objc.objc_autoreleasePoolPop(pool);
        r.frame_number += 1;
        r.ensureTarget(frame.width, frame.height);

        // Textures: what changed in the atlas, the gradients used.
        const d = frame.atlas_dirty;
        if (d[1] > d[0]) replace(r.atlas, 0, d[0], batch.atlas_size, d[1] - d[0], frame.atlas[d[0] * batch.atlas_size ..].ptr, batch.atlas_size);
        if (frame.gradient_count > 0) replace(r.gradients, 0, 0, batch.gradient_width, frame.gradient_count, frame.gradients.ptr, batch.gradient_width * 4);

        const commands = msg(id, r.queue, "commandBuffer", .{});
        // 3D scenes first, each into its texture (if it changed).
        var scene_textures: [16]?id = @splat(null);
        for (frame.scenes) |sd| {
            if (sd.image >= scene_textures.len) continue;
            scene_textures[sd.image] = try r.sceneTexture(commands, sd);
        }
        const pass = msg(id, class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
        const attachment = msg(id, msg(id, pass, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(usize, 0)});
        msg(void, attachment, "setTexture:", .{r.target});
        const clear_all = frame.full or !r.target_valid;
        msg(void, attachment, "setLoadAction:", .{@as(usize, if (clear_all) load_clear else load_load)});
        msg(void, attachment, "setStoreAction:", .{@as(usize, store_store)});
        msg(void, attachment, "setClearColor:", .{MTLClearColor{}});
        r.target_valid = true;
        const encoder = msg(id, commands, "renderCommandEncoderWithDescriptor:", .{pass});
        const size = [2]f32{ @floatFromInt(frame.width), @floatFromInt(frame.height) };
        msg(void, encoder, "setVertexBytes:length:atIndex:", .{ &size, @as(usize, 8), @as(usize, 1) });

        if (!clear_all) {
            // Clear the area being redrawn: a quad over the frame, cut to
            // each rectangle.
            const whole = [4]batch.Vertex{ corner(0, 0), corner(size[0], 0), corner(0, size[1]), corner(size[0], size[1]) };
            msg(void, encoder, "setRenderPipelineState:", .{r.clear_pipeline});
            msg(void, encoder, "setVertexBytes:length:atIndex:", .{ &whole, @as(usize, @sizeOf(@TypeOf(whole))), @as(usize, 0) });
            for (frame.region.slice()) |rect| {
                msg(void, encoder, "setScissorRect:", .{MTLScissorRect{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y), .width = @intFromFloat(rect.width), .height = @intFromFloat(rect.height) }});
                msg(void, encoder, "drawPrimitives:vertexStart:vertexCount:", .{ @as(usize, primitive_triangle_strip), @as(usize, 0), @as(usize, 4) });
            }
            msg(void, encoder, "setScissorRect:", .{MTLScissorRect{ .x = 0, .y = 0, .width = frame.width, .height = frame.height }});
        }

        if (frame.indices.len > 0) {
            const vertices = msg(id, r.device, "newBufferWithBytes:length:options:", .{ frame.vertices.ptr, frame.vertices.len * @sizeOf(batch.Vertex), @as(usize, 0) });
            defer msg(void, vertices, "release", .{});
            const indices = msg(id, r.device, "newBufferWithBytes:length:options:", .{ frame.indices.ptr, frame.indices.len * 4, @as(usize, 0) });
            defer msg(void, indices, "release", .{});
            msg(void, encoder, "setRenderPipelineState:", .{r.pipeline});
            msg(void, encoder, "setVertexBuffer:offset:atIndex:", .{ vertices, @as(usize, 0), @as(usize, 0) });
            msg(void, encoder, "setFragmentTexture:atIndex:", .{ r.atlas, @as(usize, 0) });
            msg(void, encoder, "setFragmentTexture:atIndex:", .{ r.gradients, @as(usize, 1) });
            msg(void, encoder, "setFragmentSamplerState:atIndex:", .{ r.smooth, @as(usize, 0) });
            for (frame.draws) |dr| {
                const image = if (dr.image) |i| blk: {
                    if (i < scene_textures.len) if (scene_textures[i]) |t| break :blk t;
                    // A scene not drawn here (too many in a frame): nothing.
                    for (frame.scenes) |sd| if (sd.image == i) break :blk r.blank;
                    break :blk try r.imageTexture(frame.images[i]);
                } else r.blank;
                msg(void, encoder, "setFragmentTexture:atIndex:", .{ image, @as(usize, 2) });
                msg(void, encoder, "setFragmentSamplerState:atIndex:", .{ if (dr.smooth) r.smooth else r.sharp, @as(usize, 1) });
                msg(void, encoder, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:", .{
                    @as(usize, primitive_triangle), @as(usize, dr.count), @as(usize, index_uint32), indices, @as(usize, dr.first) * 4,
                });
            }
        }
        msg(void, encoder, "endEncoding", .{});
        r.evictImages();
        r.evict3d();

        // The whole frame to the layer's next drawable.
        if (layer != null) if (msg(id, layer, "nextDrawable", .{})) |drawable| {
            const blit = msg(id, commands, "blitCommandEncoder", .{});
            msg(void, blit, "copyFromTexture:toTexture:", .{ r.target, msg(id, drawable, "texture", .{}) });
            msg(void, blit, "endEncoding", .{});
            msg(void, commands, "presentDrawable:", .{drawable});
        };
        msg(void, commands, "commit", .{});
    }

    /// The last frame's pixels (top row first), for tests. Waits for the
    /// GPU.
    pub fn readPixels(r: *Renderer, out: []core.Rgba8) void {
        const pool = objc.objc_autoreleasePoolPush();
        defer objc.objc_autoreleasePoolPop(pool);
        const w: usize = r.target_size[0];
        const h: usize = r.target_size[1];
        const buffer = msg(id, r.device, "newBufferWithLength:options:", .{ w * h * 4, @as(usize, 0) });
        defer msg(void, buffer, "release", .{});
        const commands = msg(id, r.queue, "commandBuffer", .{});
        const blit = msg(id, commands, "blitCommandEncoder", .{});
        msg(void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:", .{
            r.target, @as(usize, 0), @as(usize, 0), MTLOrigin{}, MTLSize{ .width = w, .height = h }, buffer, @as(usize, 0), w * 4, w * h * 4,
        });
        msg(void, blit, "endEncoding", .{});
        msg(void, commands, "commit", .{});
        msg(void, commands, "waitUntilCompleted", .{});
        const bytes: [*]const u8 = @ptrCast(msg(?*anyopaque, buffer, "contents", .{}).?);
        for (out[0 .. w * h], 0..) |*p, i| p.* = .{ .r = bytes[i * 4 + 2], .g = bytes[i * 4 + 1], .b = bytes[i * 4], .a = bytes[i * 4 + 3] };
    }

    fn ensureTarget(r: *Renderer, width: u32, height: u32) void {
        if (r.target != null and r.target_size[0] == width and r.target_size[1] == height) return;
        if (r.target != null) msg(void, r.target, "release", .{});
        r.target = r.texture(pixel_bgra8, width, height, usage_shader_read | usage_render_target, storage_private);
        r.target_size = .{ width, height };
        r.target_valid = false;
    }

    fn texture(r: *Renderer, format: usize, width: u32, height: u32, usage: usize, storage: ?usize) id {
        const desc = msg(id, class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ format, @as(usize, width), @as(usize, height), false });
        msg(void, desc, "setUsage:", .{usage});
        if (storage) |s| msg(void, desc, "setStorageMode:", .{s});
        return msg(id, r.device, "newTextureWithDescriptor:", .{desc});
    }

    fn imageTexture(r: *Renderer, img: core.Image) Allocator.Error!id {
        for (r.images.items) |*it| if (it.image.eql(img)) {
            it.used = r.frame_number;
            return it.texture;
        };
        try r.images.ensureUnusedCapacity(r.gpa, 1);
        const t = r.texture(pixel_rgba8, img.width, img.height, usage_shader_read, null);
        replace(t, 0, 0, img.width, img.height, img.pixels.ptr, img.width * 4);
        markSuperseded(r.images.items, img);
        r.images.appendAssumeCapacity(.{ .image = img, .texture = t, .used = r.frame_number });
        return t;
    }

    // ---- 3D ----

    /// The texture `sd`'s scene is drawn in: drawn now with `commands` if
    /// the scene or its size changed.
    fn sceneTexture(r: *Renderer, commands: id, sd: batch.SceneDraw) Allocator.Error!id {
        const scene = &sd.source.scene;
        const entry = for (r.scenes.items) |*it| {
            if (it.width == sd.width and it.height == sd.height and it.used != r.frame_number) break it;
        } else blk: {
            try r.scenes.ensureUnusedCapacity(r.gpa, 1);
            const color = r.multisampled(pixel_rgba8, sd.width, sd.height);
            const depth = r.multisampled(pixel_depth32, sd.width, sd.height);
            const resolved = r.texture(pixel_rgba8, sd.width, sd.height, usage_shader_read | usage_render_target, storage_private);
            r.scenes.appendAssumeCapacity(.{ .key = 0, .width = sd.width, .height = sd.height, .color = color, .depth = depth, .resolved = resolved, .used = 0 });
            break :blk &r.scenes.items[r.scenes.items.len - 1];
        };
        // The same scene, already drawn at that size: kept (looked for
        // first, so that the same entry is found again).
        for (r.scenes.items) |*it| if (it.key == sd.source.key and it.width == sd.width and it.height == sd.height) {
            it.used = r.frame_number;
            return it.resolved;
        };
        entry.used = r.frame_number;
        entry.key = sd.source.key;

        const pass = msg(id, class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
        const attachment = msg(id, msg(id, pass, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(usize, 0)});
        msg(void, attachment, "setTexture:", .{entry.color});
        msg(void, attachment, "setResolveTexture:", .{entry.resolved});
        msg(void, attachment, "setLoadAction:", .{@as(usize, load_clear)});
        msg(void, attachment, "setStoreAction:", .{@as(usize, store_multisample_resolve)});
        const bg = scene.background.premultiplied();
        msg(void, attachment, "setClearColor:", .{MTLClearColor{
            .red = @as(f64, @floatFromInt(bg.r)) / 255,
            .green = @as(f64, @floatFromInt(bg.g)) / 255,
            .blue = @as(f64, @floatFromInt(bg.b)) / 255,
            .alpha = @as(f64, @floatFromInt(bg.a)) / 255,
        }});
        const depth = msg(id, pass, "depthAttachment", .{});
        msg(void, depth, "setTexture:", .{entry.depth});
        msg(void, depth, "setLoadAction:", .{@as(usize, load_clear)});
        msg(void, depth, "setClearDepth:", .{@as(f64, 1)});
        const encoder = msg(id, commands, "renderCommandEncoderWithDescriptor:", .{pass});
        msg(void, encoder, "setRenderPipelineState:", .{r.pipeline_3d});
        msg(void, encoder, "setDepthStencilState:", .{r.depth_less});
        msg(void, encoder, "setFrontFacingWinding:", .{@as(usize, winding_counter_clockwise)});
        msg(void, encoder, "setFragmentSamplerState:atIndex:", .{ r.repeat, @as(usize, 0) });
        var f3 = core.raster3d.gpuFrame(scene, sd.width, sd.height);
        msg(void, encoder, "setVertexBytes:length:atIndex:", .{ &f3, @as(usize, @sizeOf(Frame3)), @as(usize, 2) });
        msg(void, encoder, "setFragmentBytes:length:atIndex:", .{ &f3, @as(usize, @sizeOf(Frame3)), @as(usize, 2) });
        for (scene.instances) |*inst| {
            const mb = try r.meshBuffers(inst.mesh);
            if (mb.count == 0) continue;
            var u = core.raster3d.gpuInstance(inst);
            msg(void, encoder, "setCullMode:", .{@as(usize, if (inst.mesh.two_sided) cull_none else cull_back)});
            msg(void, encoder, "setVertexBuffer:offset:atIndex:", .{ mb.vertices, @as(usize, 0), @as(usize, 0) });
            msg(void, encoder, "setVertexBytes:length:atIndex:", .{ &u, @as(usize, @sizeOf(Inst3)), @as(usize, 1) });
            msg(void, encoder, "setFragmentBytes:length:atIndex:", .{ &u, @as(usize, @sizeOf(Inst3)), @as(usize, 1) });
            const tex = if (inst.material.texture) |t| try r.imageTexture(t) else r.blank;
            msg(void, encoder, "setFragmentTexture:atIndex:", .{ tex, @as(usize, 0) });
            msg(void, encoder, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:", .{
                @as(usize, primitive_triangle), mb.count, @as(usize, index_uint32), mb.indices, @as(usize, 0),
            });
        }
        msg(void, encoder, "endEncoding", .{});
        return entry.resolved;
    }

    fn multisampled(r: *Renderer, format: usize, width: u32, height: u32) id {
        const desc = msg(id, class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ format, @as(usize, width), @as(usize, height), false });
        msg(void, desc, "setTextureType:", .{@as(usize, texture_2d_multisample)});
        msg(void, desc, "setSampleCount:", .{@as(usize, samples_3d)});
        msg(void, desc, "setUsage:", .{@as(usize, usage_render_target)});
        msg(void, desc, "setStorageMode:", .{@as(usize, storage_private)});
        return msg(id, r.device, "newTextureWithDescriptor:", .{desc});
    }

    /// `mesh`'s vertices (8 floats each: position, normal, texture
    /// coordinates) and indices in buffers, made the first time.
    fn meshBuffers(r: *Renderer, mesh: core.raster3d.Mesh) Allocator.Error!*MeshBuffers {
        for (r.meshes.items) |*m| if (m.vertices_ptr == @intFromPtr(mesh.vertices.ptr) and m.len == mesh.vertices.len and m.index_ptr == @intFromPtr(mesh.indices.ptr)) {
            m.used = r.frame_number;
            return m;
        };
        try r.meshes.ensureUnusedCapacity(r.gpa, 1);
        const packed_vertices = try r.gpa.alloc([8]f32, @max(1, mesh.vertices.len));
        defer r.gpa.free(packed_vertices);
        for (mesh.vertices, 0..) |v, i| packed_vertices[i] = .{ v.position[0], v.position[1], v.position[2], v.normal[0], v.normal[1], v.normal[2], v.uv[0], v.uv[1] };
        const indices = try r.gpa.alloc(u32, @max(1, mesh.indices.len));
        defer r.gpa.free(indices);
        @memcpy(indices[0..mesh.indices.len], mesh.indices);
        r.meshes.appendAssumeCapacity(.{
            .vertices_ptr = @intFromPtr(mesh.vertices.ptr),
            .len = mesh.vertices.len,
            .index_ptr = @intFromPtr(mesh.indices.ptr),
            .vertices = msg(id, r.device, "newBufferWithBytes:length:options:", .{ packed_vertices.ptr, packed_vertices.len * 32, @as(usize, 0) }),
            .indices = msg(id, r.device, "newBufferWithBytes:length:options:", .{ indices.ptr, indices.len * 4, @as(usize, 0) }),
            .count = mesh.indices.len - mesh.indices.len % 3,
            .used = r.frame_number,
        });
        return &r.meshes.items[r.meshes.items.len - 1];
    }

    /// Meshes and scenes not drawn for a while are let go.
    fn evict3d(r: *Renderer) void {
        var i: usize = 0;
        while (i < r.meshes.items.len) {
            const m = r.meshes.items[i];
            if (r.frame_number - m.used > keep_frames) {
                msg(void, m.vertices, "release", .{});
                msg(void, m.indices, "release", .{});
                _ = r.meshes.swapRemove(i);
            } else i += 1;
        }
        i = 0;
        while (i < r.scenes.items.len) {
            const sc = r.scenes.items[i];
            if (r.frame_number - sc.used > keep_frames) {
                for ([_]id{ sc.color, sc.depth, sc.resolved }) |o| msg(void, o, "release", .{});
                _ = r.scenes.swapRemove(i);
            } else i += 1;
        }
    }

    fn evictImages(r: *Renderer) void {
        var i: usize = 0;
        while (i < r.images.items.len) {
            const it = r.images.items[i];
            if (it.used == stale or r.frame_number - it.used > keep_frames) {
                msg(void, it.texture, "release", .{});
                _ = r.images.swapRemove(i);
            } else i += 1;
        }
    }
};

fn makePipeline(device: id, vs: id, fs: id, blend: bool) Error!id {
    const desc = msg(id, msg(id, class("MTLRenderPipelineDescriptor"), "alloc", .{}), "init", .{});
    defer msg(void, desc, "release", .{});
    msg(void, desc, "setVertexFunction:", .{vs});
    msg(void, desc, "setFragmentFunction:", .{fs});
    const color = msg(id, msg(id, desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(usize, 0)});
    msg(void, color, "setPixelFormat:", .{@as(usize, pixel_bgra8)});
    if (blend) {
        // Premultiplied alpha.
        msg(void, color, "setBlendingEnabled:", .{true});
        msg(void, color, "setSourceRGBBlendFactor:", .{@as(usize, blend_one)});
        msg(void, color, "setSourceAlphaBlendFactor:", .{@as(usize, blend_one)});
        msg(void, color, "setDestinationRGBBlendFactor:", .{@as(usize, blend_one_minus_source_alpha)});
        msg(void, color, "setDestinationAlphaBlendFactor:", .{@as(usize, blend_one_minus_source_alpha)});
    }
    var err: id = null;
    return msg(id, device, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err }) orelse {
        log.err("making the Metal pipeline failed: {s}", .{objc.utf8(msg(id, err, "localizedDescription", .{}))});
        return error.ShaderFailed;
    };
}

fn sampler(device: id, smooth: bool) id {
    const desc = msg(id, msg(id, class("MTLSamplerDescriptor"), "alloc", .{}), "init", .{});
    defer msg(void, desc, "release", .{});
    const filter: usize = if (smooth) 1 else 0; // linear, nearest
    msg(void, desc, "setMinFilter:", .{filter});
    msg(void, desc, "setMagFilter:", .{filter});
    msg(void, desc, "setSAddressMode:", .{@as(usize, 0)}); // clamp to edge
    msg(void, desc, "setTAddressMode:", .{@as(usize, 0)});
    return msg(id, device, "newSamplerStateWithDescriptor:", .{desc});
}

/// Writes pixels into a texture region.
fn replace(t: id, x: u32, y: u32, width: u32, height: u32, bytes: *const anyopaque, bytes_per_row: usize) void {
    const region: MTLRegion = .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = width, .height = height } };
    msg(void, t, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ region, @as(usize, 0), bytes, bytes_per_row });
}

/// A vertex of the clearing quad (only its position matters).
fn corner(x: f32, y: f32) batch.Vertex {
    return .{ .pos = .{ x, y }, .uv = .{ 0, 0 }, .rect = @splat(0), .shape = @splat(0), .clip = @splat(0), .color = @splat(0), .paint = @splat(0), .local = .{ x, y } };
}

// ---- Tests ----

const testing = std.testing;

test "Metal draws what the software renderer draws, also partially" {
    var r = Renderer.init(testing.allocator) catch return error.SkipZigTest;
    defer r.deinit();

    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 120, .height = 80 });
    defer ui.deinit();
    var card: core.items.Rectangle = .{};
    defer card.deinit();
    var button: core.items.Rectangle = .{};
    defer button.deinit();
    var shadow: core.items.DropShadow = .{};
    defer shadow.deinit();
    var icon: core.items.Path = .{};
    defer icon.deinit();
    var checker: [16]core.Rgba8 = undefined;
    for (&checker, 0..) |*p, i| p.* = if ((i % 4 + i / 4) % 2 == 0) core.Color.rgb(0x2563eb).premultiplied() else core.Color.rgba(0xfacc1580).premultiplied();
    var smooth: core.items.Image = .{};
    defer smooth.deinit();
    var sharp: core.items.Image = .{};
    defer sharp.deinit();
    ui.rootItem().appendChildren(&.{ &card.item, &button.item, &icon.item, &smooth.item, &sharp.item });
    card.item.setGeometry(.{ .x = 64, .y = 8, .width = 50, .height = 40 });
    card.border_radius.set(9);
    card.border_width.set(2.5);
    card.border_color.set(.color(.rgb(0x111827)));
    card.shadow = &shadow;
    shadow.offset_x.set(-3);
    shadow.offset_y.set(4);
    shadow.blur.set(6);
    shadow.color.set(.rgba(0x00000070));
    card.background.set(.linear(45, &.{ .{ .color = .rgb(0xf59e0b), .position = 0 }, .{ .color = .rgb(0x7c3aed), .position = 1 } }));
    button.item.setGeometry(.{ .x = 10, .y = 10, .width = 40, .height = 24 });
    button.background.set(.color(.rgb(0xff0000)));
    icon.item.setGeometry(.{ .x = 12, .y = 46, .width = 30, .height = 30 });
    icon.commands.set("M 2 15 L 12 25 L 28 4");
    // An ellipse, as SVG drawings' gradients are.
    const ellipse: core.RadialGradient = .{ .stops = .init(&.{ .{ .color = .rgb(0x059669), .position = 0 }, .{ .color = .rgb(0x1d4ed8), .position = 1 } }), .ellipse = .{ .center = .{ 0.3, 0.6 }, .radius = .{ 0.8, 0.4 } } };
    icon.stroke.set(.{ .radial_gradient = &ellipse });
    icon.stroke_width.set(3);
    smooth.source.set(.{ .width = 4, .height = 4, .pixels = &checker });
    smooth.item.setGeometry(.{ .x = 64, .y = 52, .width = 24, .height = 24 });
    sharp.source.set(.{ .width = 4, .height = 4, .pixels = &checker });
    sharp.image_rendering.set(.pixelated);
    sharp.item.setGeometry(.{ .x = 92, .y = 52, .width = 24, .height = 24 });

    const scale = 2;
    const w = 240;
    const h = 160;
    r.setScaleFactor(scale);
    var drawn: [w * h]core.Rgba8 = undefined;
    var expected: [w * h]core.Rgba8 = undefined;
    var software: zigulee.software.Renderer(core.Rgba8) = .init(testing.allocator);
    defer software.deinit();
    software.scale_factor = scale;

    for (0..2) |round| {
        if (round == 1) button.background.set(.color(.rgb(0x00aa55)));
        const region = try r.renderWindow(&ui, w, h, if (round == 0) .full else .partial, null);
        if (round == 1) try testing.expect(region.boundingBox().area() < w * h / 2);
        r.readPixels(&drawn);
        @memset(&expected, .transparent);
        _ = try software.renderWindow(&ui, .init(&expected, w, h), .full);
        var off: usize = 0;
        for (expected, drawn) |e, a| {
            inline for (.{ "r", "g", "b", "a" }) |c| {
                if (@abs(@as(i16, @field(e, c)) - @field(a, c)) > 3) off += 1;
            }
        }
        try testing.expectEqual(@as(usize, 0), off);
    }
    try testing.expect((try r.renderWindow(&ui, w, h, .partial, null)).isEmpty());
}

test "Metal draws an element tilted in depth as the software renderer does" {
    var r = Renderer.init(testing.allocator) catch return error.SkipZigTest;
    defer r.deinit();

    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 120, .height = 80 });
    defer ui.deinit();
    var card: core.items.Rectangle = .{};
    defer card.deinit();
    var stripe: core.items.Rectangle = .{};
    defer stripe.deinit();
    var tilt: core.ItemTransform = .{};
    defer tilt.deinit();
    ui.rootItem().appendChild(&card.item);
    card.item.appendChild(&stripe.item);
    card.item.setGeometry(.{ .x = 30, .y = 15, .width = 60, .height = 50 });
    card.border_radius.set(8);
    card.background.set(.color(.rgb(0x2563eb)));
    stripe.item.setGeometry(.{ .x = 0, .y = 20, .width = 60, .height = 10 });
    stripe.background.set(.color(.rgb(0xfacc15)));
    card.item.transform = &tilt;
    tilt.rotation_y.set(50);
    tilt.rotation_x.set(-20);

    const scale = 2;
    const w = 240;
    const h = 160;
    r.setScaleFactor(scale);
    var drawn: [w * h]core.Rgba8 = undefined;
    var expected: [w * h]core.Rgba8 = undefined;
    var software: zigulee.software.Renderer(core.Rgba8) = .init(testing.allocator);
    defer software.deinit();
    software.scale_factor = scale;
    _ = try r.renderWindow(&ui, w, h, .full, null);
    r.readPixels(&drawn);
    @memset(&expected, .transparent);
    _ = try software.renderWindow(&ui, .init(&expected, w, h), .full);
    // The same, but for a few pixels on edges (the GPU's own rounding).
    var off: usize = 0;
    var drawn_any: usize = 0;
    for (expected, drawn) |e, a| {
        if (a.b > 200 and a.r < 80) drawn_any += 1;
        inline for (.{ "r", "g", "b", "a" }) |c| {
            if (@abs(@as(i16, @field(e, c)) - @field(a, c)) > 24) {
                off += 1;
                break;
            }
        }
    }
    try testing.expect(drawn_any > 1000);
    try testing.expect(off < 40);
}

test "Metal draws a 3D scene as the CPU does, kept while it is the same" {
    var r = Renderer.init(testing.allocator) catch return error.SkipZigTest;
    defer r.deinit();
    if (!r.batcher.gpu_scenes) return error.SkipZigTest;

    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 80, .height = 60 });
    defer ui.deinit();
    var view: core.items.View3D = undefined;
    view.init(testing.allocator);
    defer view.deinit();
    var cube: core.items.SceneModel = .{};
    defer cube.deinit();
    var ball: core.items.SceneModel = .{};
    defer ball.deinit();
    var light: core.items.PointLight = .{};
    defer light.deinit();
    ui.rootItem().appendChild(&view.item);
    view.item.appendChildren(&.{ &cube.item, &ball.item, &light.item });
    view.item.width.set(80);
    view.item.height.set(60);
    view.background.set(.rgb(0x101828));
    cube.color.set(.rgb(0xef4444));
    cube.placement.yaw.set(30);
    cube.placement.position_x.set(-0.7);
    ball.mesh.set(.sphere);
    ball.color.set(.rgb(0x3b82f6));
    ball.roughness.set(0.3);
    ball.placement.position_x.set(0.8);
    light.placement.position_x.set(1);
    light.placement.position_y.set(1);
    light.placement.position_z.set(3);

    const scale = 2;
    const w = 160;
    const h = 120;
    r.setScaleFactor(scale);
    var drawn: [w * h]core.Rgba8 = undefined;
    var expected: [w * h]core.Rgba8 = undefined;
    var software: zigulee.software.Renderer(core.Rgba8) = .init(testing.allocator);
    defer software.deinit();
    software.scale_factor = scale;
    _ = try r.renderWindow(&ui, w, h, .full, null);
    r.readPixels(&drawn);
    // Drawn on the GPU: no picture on the CPU.
    try testing.expectEqual(@as(u32, 0), view.width);
    @memset(&expected, .transparent);
    _ = try software.renderWindow(&ui, .init(&expected, w, h), .full);
    // The same but for edges (multisampled here, oversampled there) and
    // rounding.
    var off: usize = 0;
    for (expected, drawn) |e, a| {
        inline for (.{ "r", "g", "b", "a" }) |c| {
            if (@abs(@as(i16, @field(e, c)) - @field(a, c)) > 24) {
                off += 1;
                break;
            }
        }
    }
    try testing.expect(off < w * h / 50);
    // The cube's red and the ball's blue where they are.
    const at = struct {
        fn f(px: []const core.Rgba8, x: usize, y: usize) core.Rgba8 {
            return px[y * w + x];
        }
    }.f;
    try testing.expect(at(&drawn, 46, 60).r > at(&drawn, 46, 60).b + 60);
    try testing.expect(at(&drawn, 112, 60).b > at(&drawn, 112, 60).r + 60);

    // The same scene again: its texture kept; changed: drawn again.
    const kept = r.scenes.items[0].resolved;
    ui.root.item.width.set(80);
    _ = try r.renderWindow(&ui, w, h, .full, null);
    try testing.expectEqual(kept, r.scenes.items[0].resolved);
    try testing.expectEqual(@as(usize, 1), r.scenes.items.len);
    cube.color.set(.rgb(0x22c55e));
    _ = try r.renderWindow(&ui, w, h, .partial, null);
    r.readPixels(&drawn);
    try testing.expect(at(&drawn, 46, 60).g > at(&drawn, 46, 60).r + 60);
}

/// Marks the cached copies of older versions of `img`'s pixels stale.
fn markSuperseded(items: anytype, img: core.Image) void {
    for (items) |*it| if (img.supersedes(it.image)) {
        it.used = std.math.maxInt(u64); // Renderer.stale
    };
}
