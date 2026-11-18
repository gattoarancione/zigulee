// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The GPU renderer on Direct3D 12 (Windows): draws the batcher's frames
//! (src/renderers/gpu/batch.zig) with the same shading as the other
//! executors (shader.zig), here in HLSL, compiled when the renderer starts
//! (d3dcompiler_47, part of Windows). Frames are drawn into a texture that
//! keeps the last one (partial frames clear their area with
//! ClearRenderTargetView rectangles), then copied to a flip-model swapchain.
//!
//! 3D scenes (`View3D`) are drawn here too, each into a texture of its own
//! (4x multisampled, with a depth buffer, then resolved), shaded as
//! raster3d.zig shades them on the CPU; the frame shows that texture as an
//! image.
//!
//! The Direct3D and DXGI declarations come from the Windows SDK headers
//! that ship with Zig (translated: module "d3d12_c").

const std = @import("std");
const Allocator = std.mem.Allocator;
const zigulee = @import("zigulee");
const core = zigulee.core;
const batch = zigulee.gpu.batch;
const c = @import("d3d12_c");

const log = std.log.scoped(.zigulee_d3d12);

pub const Error = error{ D3d12Unavailable, D3d12Failed, ShaderFailed } || Allocator.Error;

fn guid(a: u32, b: u16, cc: u16, d: [8]u8) c.GUID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = cc, .Data4 = d };
}

// Interface IDs (from the headers' __CRT_UUID_DECL).
const iid_device = guid(0x189819f1, 0x1db6, 0x4b57, .{ 0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7 });
const iid_queue = guid(0x0ec870a6, 0x5d7e, 0x4c22, .{ 0x8c, 0xfc, 0x5b, 0xaa, 0xe0, 0x76, 0x16, 0xed });
const iid_allocator = guid(0x6102dee4, 0xaf59, 0x4b09, .{ 0xb9, 0x99, 0xb4, 0x4d, 0x73, 0xf0, 0x9b, 0x24 });
const iid_list = guid(0x5b160d0f, 0xac1b, 0x4185, .{ 0x8b, 0xa8, 0xb3, 0xae, 0x42, 0xa5, 0xa4, 0x55 });
const iid_fence = guid(0x0a753dcf, 0xc4d8, 0x4b91, .{ 0xad, 0xf6, 0xbe, 0x5a, 0x60, 0xd9, 0x5a, 0x76 });
const iid_resource = guid(0x696442be, 0xa72e, 0x4059, .{ 0xbc, 0x79, 0x5b, 0x5c, 0x98, 0x04, 0x0f, 0xad });
const iid_heap = guid(0x8efb471d, 0x616c, 0x4f49, .{ 0x90, 0xf7, 0x12, 0x7b, 0xb7, 0x63, 0xfa, 0x51 });
const iid_root_signature = guid(0xc54a6b66, 0x72df, 0x4ee8, .{ 0x8b, 0xe5, 0xa9, 0x46, 0xa1, 0x42, 0x92, 0x14 });
const iid_pipeline = guid(0x765a30f3, 0xf624, 0x4c6f, .{ 0xa8, 0x28, 0xac, 0xe9, 0x48, 0x62, 0x24, 0x45 });
const iid_factory4 = guid(0x1bc6ea02, 0xef36, 0x464f, .{ 0xbf, 0x0c, 0x21, 0xca, 0x39, 0xe5, 0x16, 0x8a });
const iid_swapchain3 = guid(0x94d99bdb, 0xf1f8, 0x4ab0, .{ 0xb2, 0x36, 0x7d, 0xa0, 0x17, 0x0e, 0xda, 0xb1 });

/// The shaders: as shader.zig's GLSL (keep them in step).
const hlsl =
    \\cbuffer Push : register(b0) { float2 size; float smooth_image; float unused; };
    \\struct VSIn {
    \\    float2 pos : POSITION; float2 uv : TEXCOORD0; float4 rect : TEXCOORD1; float4 shape : TEXCOORD2;
    \\    float4 clip : TEXCOORD3; float4 color : TEXCOORD4; float4 paint : TEXCOORD5; float2 local : TEXCOORD6;
    \\};
    \\struct PSIn {
    \\    float4 position : SV_Position; float2 pos : TEXCOORD0; float2 uv : TEXCOORD1;
    \\    nointerpolation float4 rect : TEXCOORD2; nointerpolation float4 shape : TEXCOORD3;
    \\    nointerpolation float4 clip : TEXCOORD4; nointerpolation float4 color : TEXCOORD5;
    \\    nointerpolation float4 paint : TEXCOORD6; float2 local : TEXCOORD7;
    \\};
    \\Texture2D atlas : register(t0);
    \\Texture2D gradients : register(t1);
    \\Texture2D image : register(t2);
    \\SamplerState linear_sampler : register(s0);
    \\SamplerState point_sampler : register(s1);
    \\
    \\PSIn vs(VSIn v) {
    \\    PSIn o;
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
    \\    if (sigma <= 0.0) return saturate(0.5 - d);
    \\    float k = 1.0 / (sigma * 1.4142135);
    \\    float across = (erfApprox((p.x - r.x) * k) - erfApprox((p.x - r.x - r.z) * k)) * 0.5;
    \\    float down = (erfApprox((p.y - r.y) * k) - erfApprox((p.y - r.y - r.w) * k)) * 0.5;
    \\    return max(0.0, min(across * down, 0.5 - 0.5 * erfApprox(d * k)));
    \\}
    \\
    \\float4 sampleImage(float2 uv) {
    \\    return smooth_image > 0.5 ? image.SampleLevel(linear_sampler, uv, 0) : image.SampleLevel(point_sampler, uv, 0);
    \\}
    \\
    \\float4 ps(PSIn i) : SV_Target {
    \\    float2 w = i.pos;
    \\    if (w.x < i.clip.x || w.y < i.clip.y || w.x >= i.clip.z || w.y >= i.clip.w) discard;
    \\    float2 p = i.local;
    \\    int kind = int(i.shape.w + 0.5);
    \\    if (kind == 3) return sampleImage(i.uv) * i.color;
    \\    float coverage;
    \\    if (kind == 2 && i.shape.z > 0.5) {
    \\        float2 f = i.uv - 0.5;
    \\        float2 i0 = floor(f);
    \\        float2 t = f - i0;
    \\        int2 a = int2(clamp(i0, 0.0, 1023.0));
    \\        int2 b = int2(clamp(i0 + 1.0, 0.0, 1023.0));
    \\        coverage = lerp(lerp(atlas.Load(int3(a, 0)).r, atlas.Load(int3(b.x, a.y, 0)).r, t.x), lerp(atlas.Load(int3(a.x, b.y, 0)).r, atlas.Load(int3(b, 0)).r, t.x), t.y);
    \\    } else if (kind == 2) {
    \\        coverage = atlas.Load(int3(int2(i.uv), 0)).r;
    \\    } else if (kind == 4) {
    \\        coverage = sampleImage(i.uv).a;
    \\    } else if (kind == 5) {
    \\        coverage = shadowCoverage(p, i.rect, i.shape.x, i.shape.y);
    \\    } else {
    \\        float bw = i.shape.y;
    \\        float inside = 0.0;
    \\        if (bw > 0.0) inside = saturate(0.5 - roundedRect(p, float4(i.rect.xy + bw, i.rect.zw - 2.0 * bw), i.shape.z));
    \\        coverage = kind == 1 ? inside : saturate(0.5 - roundedRect(p, i.rect, i.shape.x)) - inside;
    \\    }
    \\    float4 paint = i.color;
    \\    int paint_type = int(i.paint.x + 0.5);
    \\    if (paint_type != 0) {
    \\        float2 d = p - (i.rect.xy + i.rect.zw * 0.5);
    \\        float t;
    \\        if (paint_type == 1) {
    \\            t = dot(d, i.paint.zw) + 0.5;
    \\        } else {
    \\            t = length(d * i.paint.zw);
    \\        }
    \\        paint = gradients.SampleLevel(linear_sampler, float2((saturate(t) * 255.0 + 0.5) / 256.0, i.paint.y), 0) * i.color;
    \\    }
    \\    return paint * coverage;
    \\}
    \\
;

/// 3D scenes' shaders: as raster3d.zig's `shade` (keep them in step, and
/// with metal.zig's).
const hlsl_3d =
    \\cbuffer Inst : register(b0) { float4x4 world; float4x4 normal_matrix; float4 base; float4 params; };
    \\struct Light3 { float4 vec; float4 radiance; };
    \\cbuffer Frame3 : register(b1) { float4x4 view_proj; float4 eye; float4 ambient; uint4 counts; Light3 lights[16]; };
    \\Texture2D tex : register(t0);
    \\SamplerState repeat_sampler : register(s0);
    \\struct VSIn { float3 pos : POSITION; float3 normal : NORMAL; float2 uv : TEXCOORD0; };
    \\struct PSIn { float4 position : SV_Position; float3 world : TEXCOORD0; float3 normal : TEXCOORD1; float2 uv : TEXCOORD2; };
    \\
    \\PSIn vs3(VSIn v) {
    \\    PSIn o;
    \\    float4 w = mul(world, float4(v.pos, 1.0));
    \\    o.position = mul(view_proj, w);
    \\    o.world = w.xyz;
    \\    o.normal = mul(normal_matrix, float4(v.normal, 0.0)).xyz;
    \\    o.uv = v.uv;
    \\    return o;
    \\}
    \\
    \\float4 ps3(PSIn i, bool front : SV_IsFrontFace) : SV_Target {
    \\    float3 b = base.rgb;
    \\    float alpha = base.a;
    \\    if (params.z > 0.5) {
    \\        float4 t = tex.Sample(repeat_sampler, i.uv);
    \\        float3 straight = t.a > 0.0 ? t.rgb / t.a : float3(0.0, 0.0, 0.0);
    \\        b *= straight * straight;
    \\        alpha *= t.a;
    \\    }
    \\    if (alpha <= 0.0) discard;
    \\    float3 n = normalize(i.normal);
    \\    if (!front) n = -n;
    \\    float3 v = normalize(eye.xyz - i.world);
    \\    float metallic = saturate(params.x);
    \\    float rough = clamp(params.y, 0.04, 1.0);
    \\    float alpha2 = (rough * rough) * (rough * rough);
    \\    float3 f0 = lerp(float3(0.04, 0.04, 0.04), b, metallic);
    \\    float3 diffuse = b * (1.0 - metallic);
    \\    float nv = max(dot(n, v), 1e-4);
    \\    float k = (rough + 1.0) * (rough + 1.0) / 8.0;
    \\    float3 color = ambient.rgb * b;
    \\    for (uint l = 0; l < counts.x; l++) {
    \\        float3 to_light = lights[l].vec.xyz;
    \\        float3 radiance = lights[l].radiance.rgb;
    \\        if (lights[l].vec.w > 0.5) {
    \\            float3 d = lights[l].vec.xyz - i.world;
    \\            to_light = normalize(d);
    \\            radiance *= 1.0 / (1.0 + dot(d, d) / (lights[l].radiance.w * lights[l].radiance.w));
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
    \\    float a = saturate(alpha);
    \\    return float4(sqrt(saturate(color)) * a, a);
    \\}
;

const Inst3 = core.raster3d.GpuInstance;
const Frame3 = core.raster3d.GpuFrame;

/// Samples per pixel of 3D scenes (4 is always supported).
const samples_3d = 4;
/// Scenes kept at once (each has its targets' descriptors).
const max_scenes = 16;

const MeshBuffers = struct { vertices_ptr: usize, len: usize, index_ptr: usize, vertices: Buffer, indices: Buffer, count: u32, used: u64 };
const SceneTexture = struct {
    key: u64,
    width: u32,
    height: u32,
    color: ?*c.ID3D12Resource,
    depth: ?*c.ID3D12Resource,
    resolved: ?*c.ID3D12Resource,
    /// Its SRV slot, and its RTV and DSV indices.
    slot: u32,
    index: u32,
    used: u64,
};

fn check(hr: c.HRESULT, what: []const u8) Error!void {
    if (hr >= 0) return;
    log.err("{s} failed (0x{x})", .{ what, @as(u32, @bitCast(hr)) });
    return error.D3d12Failed;
}

/// Releases a COM object.
fn release(obj: anytype) void {
    if (obj) |o| _ = o.*.lpVtbl.*.Release.?(o);
}

/// Texture rows in upload and readback buffers are 256-byte aligned.
fn alignedPitch(bytes_per_row: u64) u64 {
    return std.mem.alignForward(u64, bytes_per_row, c.D3D12_TEXTURE_DATA_PITCH_ALIGNMENT);
}

const Buffer = struct {
    resource: ?*c.ID3D12Resource = null,
    size: u64 = 0,
    mapped: [*]u8 = undefined,
};

const ImageTexture = struct { image: core.Image, resource: ?*c.ID3D12Resource, slot: u32, used: u64 };

/// Shader-visible descriptor slots: the atlas and gradients (a table of
/// two), the blank image, then images.
const slot_atlas = 0;
const slot_blank = 2;
const max_descriptors = 1024;

pub const Renderer = struct {
    gpa: Allocator,
    batcher: batch.Batcher,
    factory: ?*c.IDXGIFactory4 = null,
    device: ?*c.ID3D12Device = null,
    queue: ?*c.ID3D12CommandQueue = null,
    allocator: ?*c.ID3D12CommandAllocator = null,
    list: ?*c.ID3D12GraphicsCommandList = null,
    fence: ?*c.ID3D12Fence = null,
    fence_value: u64 = 0,
    event: c.HANDLE = null,
    root_signature: ?*c.ID3D12RootSignature = null,
    pipeline: ?*c.ID3D12PipelineState = null,
    srv_heap: ?*c.ID3D12DescriptorHeap = null,
    rtv_heap: ?*c.ID3D12DescriptorHeap = null,
    srv_size: u32 = 0,
    atlas: ?*c.ID3D12Resource = null,
    gradients: ?*c.ID3D12Resource = null,
    blank: ?*c.ID3D12Resource = null,
    /// Frames are drawn here; it keeps the last one.
    target: ?*c.ID3D12Resource = null,
    target_size: [2]u32 = .{ 0, 0 },
    target_valid: bool = false,
    vertices: Buffer = .{},
    indices: Buffer = .{},
    staging: Buffer = .{},
    readback: Buffer = .{},
    images: std.ArrayList(ImageTexture) = .empty,
    free_slots: std.ArrayList(u32) = .empty,
    next_slot: u32 = slot_blank + 1,
    frame_number: u64 = 0,
    swapchain: ?*c.IDXGISwapChain3 = null,
    swapchain_size: [2]u32 = .{ 0, 0 },
    hwnd: c.HWND,
    /// 3D: the root signature and pipelines (back faces culled, or not),
    /// the targets' descriptors, meshes' buffers and scenes' textures.
    root_signature_3d: ?*c.ID3D12RootSignature = null,
    pipeline_3d: ?*c.ID3D12PipelineState = null,
    pipeline_3d_two_sided: ?*c.ID3D12PipelineState = null,
    rtv_heap_3d: ?*c.ID3D12DescriptorHeap = null,
    dsv_heap_3d: ?*c.ID3D12DescriptorHeap = null,
    constants: Buffer = .{},
    meshes: std.ArrayList(MeshBuffers) = .empty,
    scenes: std.ArrayList(SceneTexture) = .empty,

    const keep_frames = 120;
    /// A cached image superseded by a newer version (see `Image.supersedes`):
    /// evicted at the next opportunity.
    const stale = std.math.maxInt(u64);

    /// Opens the default adapter; frames are shown in `hwnd` (null: drawn
    /// only, see `readPixels`).
    pub fn init(gpa: Allocator, hwnd: c.HWND) Error!Renderer {
        var r: Renderer = .{ .gpa = gpa, .batcher = try .init(gpa), .hwnd = hwnd };
        errdefer r.deinit();
        try check(c.CreateDXGIFactory2(0, &iid_factory4, @ptrCast(&r.factory)), "CreateDXGIFactory2");
        if (c.D3D12CreateDevice(null, c.D3D_FEATURE_LEVEL_11_0, &iid_device, @ptrCast(&r.device)) < 0) return error.D3d12Unavailable;
        const dev = r.device.?;
        const vt = dev.*.lpVtbl.*;
        const queue_desc: c.D3D12_COMMAND_QUEUE_DESC = .{ .Type = c.D3D12_COMMAND_LIST_TYPE_DIRECT };
        try check(vt.CreateCommandQueue.?(dev, &queue_desc, &iid_queue, @ptrCast(&r.queue)), "CreateCommandQueue");
        try check(vt.CreateCommandAllocator.?(dev, c.D3D12_COMMAND_LIST_TYPE_DIRECT, &iid_allocator, @ptrCast(&r.allocator)), "CreateCommandAllocator");
        try check(vt.CreateCommandList.?(dev, 0, c.D3D12_COMMAND_LIST_TYPE_DIRECT, r.allocator, null, &iid_list, @ptrCast(&r.list)), "CreateCommandList");
        try check(r.list.?.*.lpVtbl.*.Close.?(r.list), "Close");
        try check(vt.CreateFence.?(dev, 0, c.D3D12_FENCE_FLAG_NONE, &iid_fence, @ptrCast(&r.fence)), "CreateFence");
        r.event = c.CreateEventW(null, 0, 0, null) orelse return error.D3d12Failed;

        const srv_desc: c.D3D12_DESCRIPTOR_HEAP_DESC = .{ .Type = c.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, .NumDescriptors = max_descriptors, .Flags = c.D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE };
        try check(vt.CreateDescriptorHeap.?(dev, &srv_desc, &iid_heap, @ptrCast(&r.srv_heap)), "CreateDescriptorHeap");
        const rtv_desc: c.D3D12_DESCRIPTOR_HEAP_DESC = .{ .Type = c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV, .NumDescriptors = 1 };
        try check(vt.CreateDescriptorHeap.?(dev, &rtv_desc, &iid_heap, @ptrCast(&r.rtv_heap)), "CreateDescriptorHeap");
        r.srv_size = vt.GetDescriptorHandleIncrementSize.?(dev, c.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);

        try r.makePipeline();
        r.atlas = try r.texture(c.DXGI_FORMAT_R8_UNORM, batch.atlas_size, batch.atlas_size, c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, 0);
        r.view(r.atlas.?, c.DXGI_FORMAT_R8_UNORM, slot_atlas);
        r.gradients = try r.texture(c.DXGI_FORMAT_R8G8B8A8_UNORM, batch.gradient_width, batch.gradient_rows, c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, 0);
        r.view(r.gradients.?, c.DXGI_FORMAT_R8G8B8A8_UNORM, slot_atlas + 1);
        r.blank = try r.texture(c.DXGI_FORMAT_R8G8B8A8_UNORM, 1, 1, c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, 0);
        r.view(r.blank.?, c.DXGI_FORMAT_R8G8B8A8_UNORM, slot_blank);
        r.make3d() catch |err| log.info("no 3D on the GPU ({t}): scenes drawn on the CPU", .{err});
        r.batcher.gpu_scenes = r.pipeline_3d != null and r.pipeline_3d_two_sided != null;
        return r;
    }

    pub fn deinit(r: *Renderer) void {
        if (r.queue != null and r.fence != null) r.waitIdle() catch {};
        for (r.images.items) |it| release(it.resource);
        r.images.deinit(r.gpa);
        for (r.meshes.items) |*m| {
            release(m.vertices.resource);
            release(m.indices.resource);
        }
        r.meshes.deinit(r.gpa);
        for (r.scenes.items) |sc| for ([_]?*c.ID3D12Resource{ sc.color, sc.depth, sc.resolved }) |o| release(o);
        r.scenes.deinit(r.gpa);
        release(r.constants.resource);
        release(r.dsv_heap_3d);
        release(r.rtv_heap_3d);
        release(r.pipeline_3d_two_sided);
        release(r.pipeline_3d);
        release(r.root_signature_3d);
        r.free_slots.deinit(r.gpa);
        for ([_]*Buffer{ &r.vertices, &r.indices, &r.staging, &r.readback }) |b| release(b.resource);
        release(r.swapchain);
        release(r.target);
        release(r.blank);
        release(r.gradients);
        release(r.atlas);
        release(r.rtv_heap);
        release(r.srv_heap);
        release(r.pipeline);
        release(r.root_signature);
        release(r.fence);
        release(r.list);
        release(r.allocator);
        release(r.queue);
        release(r.device);
        release(r.factory);
        if (r.event) |e| _ = c.CloseHandle(e);
        r.batcher.deinit();
    }

    pub fn setScaleFactor(r: *Renderer, scale: f32) void {
        r.batcher.scale_factor = scale;
    }

    fn makePipeline(r: *Renderer) Error!void {
        const dev = r.device.?;
        const vt = dev.*.lpVtbl.*;
        // Root signature: 4 constants (size, image sampling), the atlas and
        // gradients, the image; two static samplers (linear, point).
        const ranges = [2]c.D3D12_DESCRIPTOR_RANGE{
            .{ .RangeType = c.D3D12_DESCRIPTOR_RANGE_TYPE_SRV, .NumDescriptors = 2, .BaseShaderRegister = 0, .OffsetInDescriptorsFromTableStart = 0 },
            .{ .RangeType = c.D3D12_DESCRIPTOR_RANGE_TYPE_SRV, .NumDescriptors = 1, .BaseShaderRegister = 2, .OffsetInDescriptorsFromTableStart = 0 },
        };
        const params = [3]c.D3D12_ROOT_PARAMETER{
            .{ .ParameterType = c.D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS, .unnamed_0 = .{ .Constants = .{ .ShaderRegister = 0, .RegisterSpace = 0, .Num32BitValues = 4 } }, .ShaderVisibility = c.D3D12_SHADER_VISIBILITY_ALL },
            .{ .ParameterType = c.D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE, .unnamed_0 = .{ .DescriptorTable = .{ .NumDescriptorRanges = 1, .pDescriptorRanges = &ranges[0] } }, .ShaderVisibility = c.D3D12_SHADER_VISIBILITY_PIXEL },
            .{ .ParameterType = c.D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE, .unnamed_0 = .{ .DescriptorTable = .{ .NumDescriptorRanges = 1, .pDescriptorRanges = &ranges[1] } }, .ShaderVisibility = c.D3D12_SHADER_VISIBILITY_PIXEL },
        };
        const samplers = [2]c.D3D12_STATIC_SAMPLER_DESC{ staticSampler(c.D3D12_FILTER_MIN_MAG_MIP_LINEAR, 0), staticSampler(c.D3D12_FILTER_MIN_MAG_MIP_POINT, 1) };
        const rs_desc: c.D3D12_ROOT_SIGNATURE_DESC = .{
            .NumParameters = params.len,
            .pParameters = &params,
            .NumStaticSamplers = samplers.len,
            .pStaticSamplers = &samplers,
            .Flags = c.D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
        };
        var blob: [*c]c.ID3DBlob = null;
        var err_blob: [*c]c.ID3DBlob = null;
        defer release(@as(?*c.ID3DBlob, blob));
        defer release(@as(?*c.ID3DBlob, err_blob));
        if (c.D3D12SerializeRootSignature(&rs_desc, c.D3D_ROOT_SIGNATURE_VERSION_1, &blob, &err_blob) < 0) {
            log.err("the root signature: {s}", .{blobText(err_blob)});
            return error.D3d12Failed;
        }
        try check(vt.CreateRootSignature.?(dev, 0, blob.*.lpVtbl.*.GetBufferPointer.?(blob), blob.*.lpVtbl.*.GetBufferSize.?(blob), &iid_root_signature, @ptrCast(&r.root_signature)), "CreateRootSignature");

        const vs = try compile("vs", "vs_5_0");
        defer release(@as(?*c.ID3DBlob, vs));
        const ps = try compile("ps", "ps_5_0");
        defer release(@as(?*c.ID3DBlob, ps));
        const V = batch.Vertex;
        const elements = [_]c.D3D12_INPUT_ELEMENT_DESC{
            element("POSITION", 0, c.DXGI_FORMAT_R32G32_FLOAT, @offsetOf(V, "pos")),
            element("TEXCOORD", 0, c.DXGI_FORMAT_R32G32_FLOAT, @offsetOf(V, "uv")),
            element("TEXCOORD", 1, c.DXGI_FORMAT_R32G32B32A32_FLOAT, @offsetOf(V, "rect")),
            element("TEXCOORD", 2, c.DXGI_FORMAT_R32G32B32A32_FLOAT, @offsetOf(V, "shape")),
            element("TEXCOORD", 3, c.DXGI_FORMAT_R32G32B32A32_FLOAT, @offsetOf(V, "clip")),
            element("TEXCOORD", 4, c.DXGI_FORMAT_R32G32B32A32_FLOAT, @offsetOf(V, "color")),
            element("TEXCOORD", 5, c.DXGI_FORMAT_R32G32B32A32_FLOAT, @offsetOf(V, "paint")),
            element("TEXCOORD", 6, c.DXGI_FORMAT_R32G32_FLOAT, @offsetOf(V, "local")),
        };
        var desc: c.D3D12_GRAPHICS_PIPELINE_STATE_DESC = .{
            .pRootSignature = r.root_signature,
            .VS = .{ .pShaderBytecode = vs.*.lpVtbl.*.GetBufferPointer.?(vs), .BytecodeLength = vs.*.lpVtbl.*.GetBufferSize.?(vs) },
            .PS = .{ .pShaderBytecode = ps.*.lpVtbl.*.GetBufferPointer.?(ps), .BytecodeLength = ps.*.lpVtbl.*.GetBufferSize.?(ps) },
            .SampleMask = 0xffffffff,
            .RasterizerState = .{ .FillMode = c.D3D12_FILL_MODE_SOLID, .CullMode = c.D3D12_CULL_MODE_NONE, .DepthClipEnable = 1 },
            .InputLayout = .{ .pInputElementDescs = &elements, .NumElements = elements.len },
            .PrimitiveTopologyType = c.D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE,
            .NumRenderTargets = 1,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
        };
        desc.RTVFormats[0] = c.DXGI_FORMAT_R8G8B8A8_UNORM;
        // Premultiplied alpha.
        desc.BlendState.RenderTarget[0] = .{
            .BlendEnable = 1,
            .SrcBlend = c.D3D12_BLEND_ONE,
            .DestBlend = c.D3D12_BLEND_INV_SRC_ALPHA,
            .BlendOp = c.D3D12_BLEND_OP_ADD,
            .SrcBlendAlpha = c.D3D12_BLEND_ONE,
            .DestBlendAlpha = c.D3D12_BLEND_INV_SRC_ALPHA,
            .BlendOpAlpha = c.D3D12_BLEND_OP_ADD,
            .LogicOp = c.D3D12_LOGIC_OP_NOOP,
            .RenderTargetWriteMask = c.D3D12_COLOR_WRITE_ENABLE_ALL,
        };
        try check(vt.CreateGraphicsPipelineState.?(dev, &desc, &iid_pipeline, @ptrCast(&r.pipeline)), "CreateGraphicsPipelineState");
    }

    fn staticSampler(filter: c.D3D12_FILTER, register: u32) c.D3D12_STATIC_SAMPLER_DESC {
        return .{
            .Filter = filter,
            .AddressU = c.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
            .AddressV = c.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
            .AddressW = c.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
            .MaxAnisotropy = 1,
            .ComparisonFunc = c.D3D12_COMPARISON_FUNC_NEVER,
            .BorderColor = c.D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK,
            .MinLOD = 0,
            .MaxLOD = 0,
            .ShaderRegister = register,
            .ShaderVisibility = c.D3D12_SHADER_VISIBILITY_PIXEL,
        };
    }

    fn element(comptime semantic: [:0]const u8, index: u32, format: c.DXGI_FORMAT, offset: u32) c.D3D12_INPUT_ELEMENT_DESC {
        return .{ .SemanticName = semantic, .SemanticIndex = index, .Format = format, .InputSlot = 0, .AlignedByteOffset = offset, .InputSlotClass = c.D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA };
    }

    fn compile(entry: [*:0]const u8, target: [*:0]const u8) Error![*c]c.ID3DBlob {
        return compileSource(hlsl, entry, target);
    }

    fn compileSource(source: []const u8, entry: [*:0]const u8, target: [*:0]const u8) Error![*c]c.ID3DBlob {
        var code: [*c]c.ID3DBlob = null;
        var errors: [*c]c.ID3DBlob = null;
        defer release(@as(?*c.ID3DBlob, errors));
        if (c.D3DCompile(source.ptr, source.len, "zigulee", null, null, entry, target, c.D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errors) < 0) {
            log.err("compiling the shaders failed: {s}", .{blobText(errors)});
            return error.ShaderFailed;
        }
        return code;
    }

    fn blobText(blob: [*c]c.ID3DBlob) []const u8 {
        if (blob == null) return "";
        const p: [*]const u8 = @ptrCast(blob.*.lpVtbl.*.GetBufferPointer.?(blob));
        return p[0..blob.*.lpVtbl.*.GetBufferSize.?(blob)];
    }

    /// The 3D pipelines: per instance its 40 constants (b0), the frame's
    /// constant buffer (b1), the material's texture (t0); one sampler,
    /// repeating. Depth tested, multisampled.
    fn make3d(r: *Renderer) Error!void {
        const dev = r.device.?;
        const vt = dev.*.lpVtbl.*;
        const range: c.D3D12_DESCRIPTOR_RANGE = .{ .RangeType = c.D3D12_DESCRIPTOR_RANGE_TYPE_SRV, .NumDescriptors = 1, .BaseShaderRegister = 0, .OffsetInDescriptorsFromTableStart = 0 };
        const params = [3]c.D3D12_ROOT_PARAMETER{
            .{ .ParameterType = c.D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS, .unnamed_0 = .{ .Constants = .{ .ShaderRegister = 0, .RegisterSpace = 0, .Num32BitValues = @sizeOf(Inst3) / 4 } }, .ShaderVisibility = c.D3D12_SHADER_VISIBILITY_ALL },
            .{ .ParameterType = c.D3D12_ROOT_PARAMETER_TYPE_CBV, .unnamed_0 = .{ .Descriptor = .{ .ShaderRegister = 1, .RegisterSpace = 0 } }, .ShaderVisibility = c.D3D12_SHADER_VISIBILITY_ALL },
            .{ .ParameterType = c.D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE, .unnamed_0 = .{ .DescriptorTable = .{ .NumDescriptorRanges = 1, .pDescriptorRanges = &range } }, .ShaderVisibility = c.D3D12_SHADER_VISIBILITY_PIXEL },
        };
        var repeat = staticSampler(c.D3D12_FILTER_MIN_MAG_MIP_LINEAR, 0);
        repeat.AddressU = c.D3D12_TEXTURE_ADDRESS_MODE_WRAP;
        repeat.AddressV = c.D3D12_TEXTURE_ADDRESS_MODE_WRAP;
        const rs_desc: c.D3D12_ROOT_SIGNATURE_DESC = .{
            .NumParameters = params.len,
            .pParameters = &params,
            .NumStaticSamplers = 1,
            .pStaticSamplers = &repeat,
            .Flags = c.D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
        };
        var blob: [*c]c.ID3DBlob = null;
        var err_blob: [*c]c.ID3DBlob = null;
        defer release(@as(?*c.ID3DBlob, blob));
        defer release(@as(?*c.ID3DBlob, err_blob));
        if (c.D3D12SerializeRootSignature(&rs_desc, c.D3D_ROOT_SIGNATURE_VERSION_1, &blob, &err_blob) < 0) {
            log.info("the 3D root signature: {s}", .{blobText(err_blob)});
            return error.D3d12Failed;
        }
        try check(vt.CreateRootSignature.?(dev, 0, blob.*.lpVtbl.*.GetBufferPointer.?(blob), blob.*.lpVtbl.*.GetBufferSize.?(blob), &iid_root_signature, @ptrCast(&r.root_signature_3d)), "CreateRootSignature");

        const vs = try compileSource(hlsl_3d, "vs3", "vs_5_0");
        defer release(@as(?*c.ID3DBlob, vs));
        const ps = try compileSource(hlsl_3d, "ps3", "ps_5_0");
        defer release(@as(?*c.ID3DBlob, ps));
        const elements = [_]c.D3D12_INPUT_ELEMENT_DESC{
            element("POSITION", 0, c.DXGI_FORMAT_R32G32B32_FLOAT, 0),
            element("NORMAL", 0, c.DXGI_FORMAT_R32G32B32_FLOAT, 12),
            element("TEXCOORD", 0, c.DXGI_FORMAT_R32G32_FLOAT, 24),
        };
        for ([_]bool{ false, true }) |two_sided| {
            var desc: c.D3D12_GRAPHICS_PIPELINE_STATE_DESC = .{
                .pRootSignature = r.root_signature_3d,
                .VS = .{ .pShaderBytecode = vs.*.lpVtbl.*.GetBufferPointer.?(vs), .BytecodeLength = vs.*.lpVtbl.*.GetBufferSize.?(vs) },
                .PS = .{ .pShaderBytecode = ps.*.lpVtbl.*.GetBufferPointer.?(ps), .BytecodeLength = ps.*.lpVtbl.*.GetBufferSize.?(ps) },
                .SampleMask = 0xffffffff,
                // Counter-clockwise from outside is the front.
                .RasterizerState = .{ .FillMode = c.D3D12_FILL_MODE_SOLID, .CullMode = if (two_sided) c.D3D12_CULL_MODE_NONE else c.D3D12_CULL_MODE_BACK, .FrontCounterClockwise = 1, .DepthClipEnable = 1, .MultisampleEnable = 1 },
                .DepthStencilState = .{ .DepthEnable = 1, .DepthWriteMask = c.D3D12_DEPTH_WRITE_MASK_ALL, .DepthFunc = c.D3D12_COMPARISON_FUNC_LESS },
                .DSVFormat = c.DXGI_FORMAT_D32_FLOAT,
                .InputLayout = .{ .pInputElementDescs = &elements, .NumElements = elements.len },
                .PrimitiveTopologyType = c.D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE,
                .NumRenderTargets = 1,
                .SampleDesc = .{ .Count = samples_3d, .Quality = 0 },
            };
            desc.RTVFormats[0] = c.DXGI_FORMAT_R8G8B8A8_UNORM;
            desc.BlendState.RenderTarget[0] = .{
                .BlendEnable = 1,
                .SrcBlend = c.D3D12_BLEND_ONE,
                .DestBlend = c.D3D12_BLEND_INV_SRC_ALPHA,
                .BlendOp = c.D3D12_BLEND_OP_ADD,
                .SrcBlendAlpha = c.D3D12_BLEND_ONE,
                .DestBlendAlpha = c.D3D12_BLEND_INV_SRC_ALPHA,
                .BlendOpAlpha = c.D3D12_BLEND_OP_ADD,
                .LogicOp = c.D3D12_LOGIC_OP_NOOP,
                .RenderTargetWriteMask = c.D3D12_COLOR_WRITE_ENABLE_ALL,
            };
            const target = if (two_sided) &r.pipeline_3d_two_sided else &r.pipeline_3d;
            try check(vt.CreateGraphicsPipelineState.?(dev, &desc, &iid_pipeline, @ptrCast(target)), "CreateGraphicsPipelineState");
        }
        const rtv_desc: c.D3D12_DESCRIPTOR_HEAP_DESC = .{ .Type = c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV, .NumDescriptors = max_scenes };
        try check(vt.CreateDescriptorHeap.?(dev, &rtv_desc, &iid_heap, @ptrCast(&r.rtv_heap_3d)), "CreateDescriptorHeap");
        const dsv_desc: c.D3D12_DESCRIPTOR_HEAP_DESC = .{ .Type = c.D3D12_DESCRIPTOR_HEAP_TYPE_DSV, .NumDescriptors = max_scenes };
        try check(vt.CreateDescriptorHeap.?(dev, &dsv_desc, &iid_heap, @ptrCast(&r.dsv_heap_3d)), "CreateDescriptorHeap");
    }

    // ---- Resources ----

    fn heapProperties(kind: c.D3D12_HEAP_TYPE) c.D3D12_HEAP_PROPERTIES {
        return .{ .Type = kind, .CPUPageProperty = c.D3D12_CPU_PAGE_PROPERTY_UNKNOWN, .MemoryPoolPreference = c.D3D12_MEMORY_POOL_UNKNOWN, .CreationNodeMask = 1, .VisibleNodeMask = 1 };
    }

    fn texture(r: *Renderer, format: c.DXGI_FORMAT, width: u32, height: u32, state: c.D3D12_RESOURCE_STATES, flags: c.D3D12_RESOURCE_FLAGS) Error!?*c.ID3D12Resource {
        return r.textureSampled(format, width, height, state, flags, 1);
    }

    fn textureSampled(r: *Renderer, format: c.DXGI_FORMAT, width: u32, height: u32, state: c.D3D12_RESOURCE_STATES, flags: c.D3D12_RESOURCE_FLAGS, samples: u32) Error!?*c.ID3D12Resource {
        const dev = r.device.?;
        const props = heapProperties(c.D3D12_HEAP_TYPE_DEFAULT);
        const desc: c.D3D12_RESOURCE_DESC = .{
            .Dimension = c.D3D12_RESOURCE_DIMENSION_TEXTURE2D,
            .Width = width,
            .Height = height,
            .DepthOrArraySize = 1,
            .MipLevels = 1,
            .Format = format,
            .SampleDesc = .{ .Count = samples, .Quality = 0 },
            .Layout = c.D3D12_TEXTURE_LAYOUT_UNKNOWN,
            .Flags = flags,
        };
        var res: ?*c.ID3D12Resource = null;
        try check(dev.*.lpVtbl.*.CreateCommittedResource.?(dev, &props, c.D3D12_HEAP_FLAG_NONE, &desc, state, null, &iid_resource, @ptrCast(&res)), "CreateCommittedResource");
        return res;
    }

    /// A shader resource view of a texture in descriptor slot `slot`.
    fn view(r: *Renderer, res: *c.ID3D12Resource, format: c.DXGI_FORMAT, slot: u32) void {
        const dev = r.device.?;
        const desc: c.D3D12_SHADER_RESOURCE_VIEW_DESC = .{
            .Format = format,
            .ViewDimension = c.D3D12_SRV_DIMENSION_TEXTURE2D,
            .Shader4ComponentMapping = c.D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING,
            .unnamed_0 = .{ .Texture2D = .{ .MipLevels = 1 } },
        };
        dev.*.lpVtbl.*.CreateShaderResourceView.?(dev, res, &desc, r.cpuSlot(slot));
    }

    fn cpuSlot(r: *Renderer, slot: u32) c.D3D12_CPU_DESCRIPTOR_HANDLE {
        var start: c.D3D12_CPU_DESCRIPTOR_HANDLE = undefined;
        _ = r.srv_heap.?.*.lpVtbl.*.GetCPUDescriptorHandleForHeapStart.?(r.srv_heap, &start);
        start.ptr += @as(usize, slot) * r.srv_size;
        return start;
    }

    fn gpuSlot(r: *Renderer, slot: u32) c.D3D12_GPU_DESCRIPTOR_HANDLE {
        var start: c.D3D12_GPU_DESCRIPTOR_HANDLE = undefined;
        _ = r.srv_heap.?.*.lpVtbl.*.GetGPUDescriptorHandleForHeapStart.?(r.srv_heap, &start);
        start.ptr += @as(u64, slot) * r.srv_size;
        return start;
    }

    fn rtv(r: *Renderer) c.D3D12_CPU_DESCRIPTOR_HANDLE {
        var start: c.D3D12_CPU_DESCRIPTOR_HANDLE = undefined;
        _ = r.rtv_heap.?.*.lpVtbl.*.GetCPUDescriptorHandleForHeapStart.?(r.rtv_heap, &start);
        return start;
    }

    /// A mapped buffer of at least `size` bytes in a heap of `kind`.
    fn ensureBuffer(r: *Renderer, b: *Buffer, size: u64, kind: c.D3D12_HEAP_TYPE) Error!void {
        if (b.resource != null and b.size >= size) return;
        release(b.resource);
        b.* = .{};
        const capacity = @max(size, 64 * 1024);
        const dev = r.device.?;
        const props = heapProperties(kind);
        const desc: c.D3D12_RESOURCE_DESC = .{
            .Dimension = c.D3D12_RESOURCE_DIMENSION_BUFFER,
            .Width = capacity,
            .Height = 1,
            .DepthOrArraySize = 1,
            .MipLevels = 1,
            .Format = c.DXGI_FORMAT_UNKNOWN,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Layout = c.D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
        };
        const state: c.D3D12_RESOURCE_STATES = if (kind == c.D3D12_HEAP_TYPE_READBACK) c.D3D12_RESOURCE_STATE_COPY_DEST else c.D3D12_RESOURCE_STATE_GENERIC_READ;
        try check(dev.*.lpVtbl.*.CreateCommittedResource.?(dev, &props, c.D3D12_HEAP_FLAG_NONE, &desc, state, null, &iid_resource, @ptrCast(&b.resource)), "CreateCommittedResource");
        var mapped: ?*anyopaque = null;
        try check(b.resource.?.*.lpVtbl.*.Map.?(b.resource, 0, null, &mapped), "Map");
        b.mapped = @ptrCast(mapped.?);
        b.size = capacity;
    }

    fn barrier(r: *Renderer, res: ?*c.ID3D12Resource, before: c.D3D12_RESOURCE_STATES, after: c.D3D12_RESOURCE_STATES) void {
        const b: c.D3D12_RESOURCE_BARRIER = .{
            .Type = c.D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
            .unnamed_0 = .{ .Transition = .{ .pResource = res, .Subresource = c.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES, .StateBefore = before, .StateAfter = after } },
        };
        r.list.?.*.lpVtbl.*.ResourceBarrier.?(r.list, 1, &b);
    }

    /// Copies rows of pixels into a texture region, through the staging
    /// buffer at `offset` (512-byte aligned).
    fn upload(r: *Renderer, res: ?*c.ID3D12Resource, format: c.DXGI_FORMAT, bpp: u32, offset: u64, x: u32, y: u32, width: u32, height: u32, pixels: []const u8, stride: usize) void {
        const pitch = alignedPitch(@as(u64, width) * bpp);
        for (0..height) |row| @memcpy(r.staging.mapped[offset + row * pitch ..][0 .. width * bpp], pixels[row * stride ..][0 .. width * bpp]);
        r.barrier(res, c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, c.D3D12_RESOURCE_STATE_COPY_DEST);
        const dst: c.D3D12_TEXTURE_COPY_LOCATION = .{ .pResource = res, .Type = c.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX, .unnamed_0 = .{ .SubresourceIndex = 0 } };
        const src: c.D3D12_TEXTURE_COPY_LOCATION = .{ .pResource = r.staging.resource, .Type = c.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT, .unnamed_0 = .{ .PlacedFootprint = .{
            .Offset = offset,
            .Footprint = .{ .Format = format, .Width = width, .Height = height, .Depth = 1, .RowPitch = @intCast(pitch) },
        } } };
        r.list.?.*.lpVtbl.*.CopyTextureRegion.?(r.list, &dst, x, y, 0, &src, null);
        r.barrier(res, c.D3D12_RESOURCE_STATE_COPY_DEST, c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    }

    fn uploadSize(width: u32, height: u32, bpp: u32) u64 {
        return std.mem.alignForward(u64, alignedPitch(@as(u64, width) * bpp) * height, c.D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT);
    }

    fn ensureTarget(r: *Renderer, width: u32, height: u32) Error!void {
        if (r.target != null and r.target_size[0] == width and r.target_size[1] == height) return;
        try r.waitIdle();
        release(r.target);
        r.target = null;
        r.target = try r.texture(c.DXGI_FORMAT_R8G8B8A8_UNORM, width, height, c.D3D12_RESOURCE_STATE_COPY_SOURCE, c.D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
        const dev = r.device.?;
        dev.*.lpVtbl.*.CreateRenderTargetView.?(dev, r.target, null, r.rtv());
        r.target_size = .{ width, height };
        r.target_valid = false;
    }

    fn findImage(r: *Renderer, img: core.Image) ?*ImageTexture {
        for (r.images.items) |*it| if (it.image.eql(img)) return it;
        return null;
    }

    fn evictImages(r: *Renderer) Error!void {
        var i: usize = 0;
        while (i < r.images.items.len) {
            const it = r.images.items[i];
            if (it.used == stale or r.frame_number - it.used > keep_frames) {
                try r.waitIdle();
                release(it.resource);
                try r.free_slots.append(r.gpa, it.slot);
                _ = r.images.swapRemove(i);
            } else i += 1;
        }
    }

    // ---- Frames ----

    fn waitIdle(r: *Renderer) Error!void {
        r.fence_value += 1;
        try check(r.queue.?.*.lpVtbl.*.Signal.?(r.queue, r.fence, r.fence_value), "Signal");
        if (r.fence.?.*.lpVtbl.*.GetCompletedValue.?(r.fence) < r.fence_value) {
            try check(r.fence.?.*.lpVtbl.*.SetEventOnCompletion.?(r.fence, r.fence_value, r.event), "SetEventOnCompletion");
            _ = c.WaitForSingleObject(r.event, c.INFINITE);
        }
    }

    /// Draws the window, `width` x `height` pixels (everything, or in
    /// `.partial` mode what changed), and shows it in the window (if any).
    /// Returns the area redrawn; when empty, nothing was drawn.
    pub fn renderWindow(r: *Renderer, window: *core.Window, width: u32, height: u32, mode: core.RenderMode) Error!core.Region {
        const full = mode == .full or !r.target_valid or r.target_size[0] != width or r.target_size[1] != height;
        const frame = try r.batcher.build(window, width, height, if (full) .full else .partial);
        if (frame.region.isEmpty()) return .{};
        try r.draw(&frame);
        return frame.region;
    }

    fn draw(r: *Renderer, frame: *const batch.Frame) Error!void {
        r.frame_number += 1;
        try r.ensureTarget(frame.width, frame.height);
        if (r.hwnd != null) try r.ensureSwapchain(frame.width, frame.height);
        // One frame at a time: the last one is done.
        try r.waitIdle();
        try check(r.allocator.?.*.lpVtbl.*.Reset.?(r.allocator), "Reset");
        const list = r.list.?;
        const lv = list.*.lpVtbl.*;
        try check(lv.Reset.?(list, r.allocator, r.pipeline), "Reset");

        // Uploads: what changed in the atlas, the gradients, new images
        // (3D scenes' materials' too; scenes themselves are drawn here).
        const d = frame.atlas_dirty;
        var size: u64 = 0;
        if (d[1] > d[0]) size += uploadSize(batch.atlas_size, d[1] - d[0], 1);
        if (frame.gradient_count > 0) size += uploadSize(batch.gradient_width, frame.gradient_count, 4);
        for (frame.draws) |dr| if (dr.image) |i| if (!isScene(frame, i) and r.findImage(frame.images[i]) == null) {
            size += uploadSize(frame.images[i].width, frame.images[i].height, 4);
        };
        for (frame.scenes) |sd| for (sd.source.scene.instances) |inst| if (inst.material.texture) |t| if (r.findImage(t) == null) {
            size += uploadSize(t.width, t.height, 4);
        };
        try r.ensureBuffer(&r.staging, size, c.D3D12_HEAP_TYPE_UPLOAD);
        var at: u64 = 0;
        if (d[1] > d[0]) {
            r.upload(r.atlas, c.DXGI_FORMAT_R8_UNORM, 1, at, 0, d[0], batch.atlas_size, d[1] - d[0], frame.atlas[d[0] * batch.atlas_size ..], batch.atlas_size);
            at += uploadSize(batch.atlas_size, d[1] - d[0], 1);
        }
        if (frame.gradient_count > 0) {
            r.upload(r.gradients, c.DXGI_FORMAT_R8G8B8A8_UNORM, 4, at, 0, 0, batch.gradient_width, frame.gradient_count, frame.gradients, batch.gradient_width * 4);
            at += uploadSize(batch.gradient_width, frame.gradient_count, 4);
        }
        for (frame.draws) |dr| if (dr.image) |i| if (!isScene(frame, i) and r.findImage(frame.images[i]) == null) {
            try r.addImage(frame.images[i], &at);
        };
        for (frame.scenes) |sd| for (sd.source.scene.instances) |inst| if (inst.material.texture) |t| if (r.findImage(t) == null) {
            try r.addImage(t, &at);
        };

        // 3D scenes, each into its texture (if it changed).
        var scene_slots: [16]?u32 = @splat(null);
        if (frame.scenes.len > 0) {
            try r.ensureBuffer(&r.constants, frame.scenes.len * 1024, c.D3D12_HEAP_TYPE_UPLOAD);
            for (frame.scenes, 0..) |sd, k| {
                if (sd.image >= scene_slots.len) continue;
                scene_slots[sd.image] = try r.drawScene(sd, k * 1024);
            }
            lv.SetPipelineState.?(list, r.pipeline);
        }

        // Vertices and indices.
        const vertex_bytes = frame.vertices.len * @sizeOf(batch.Vertex);
        const index_bytes = frame.indices.len * 4;
        try r.ensureBuffer(&r.vertices, vertex_bytes, c.D3D12_HEAP_TYPE_UPLOAD);
        try r.ensureBuffer(&r.indices, index_bytes, c.D3D12_HEAP_TYPE_UPLOAD);
        @memcpy(r.vertices.mapped[0..vertex_bytes], std.mem.sliceAsBytes(frame.vertices));
        @memcpy(r.indices.mapped[0..index_bytes], std.mem.sliceAsBytes(frame.indices));

        // The frame: over the last one (partial), clearing what it redraws.
        r.barrier(r.target, c.D3D12_RESOURCE_STATE_COPY_SOURCE, c.D3D12_RESOURCE_STATE_RENDER_TARGET);
        const rtv_handle = r.rtv();
        const transparent = [4]f32{ 0, 0, 0, 0 };
        if (frame.full or !r.target_valid) {
            lv.ClearRenderTargetView.?(list, rtv_handle, &transparent, 0, null);
        } else {
            var rects: [core.Region.capacity]c.D3D12_RECT = undefined;
            for (frame.region.slice(), 0..) |rect, k| rects[k] = .{
                .left = @intFromFloat(rect.x),
                .top = @intFromFloat(rect.y),
                .right = @intFromFloat(rect.right()),
                .bottom = @intFromFloat(rect.bottom()),
            };
            lv.ClearRenderTargetView.?(list, rtv_handle, &transparent, @intCast(frame.region.len), &rects);
        }
        r.target_valid = true;
        if (frame.indices.len > 0) {
            lv.OMSetRenderTargets.?(list, 1, &rtv_handle, 0, null);
            const viewport: c.D3D12_VIEWPORT = .{ .TopLeftX = 0, .TopLeftY = 0, .Width = @floatFromInt(frame.width), .Height = @floatFromInt(frame.height), .MinDepth = 0, .MaxDepth = 1 };
            const scissor: c.D3D12_RECT = .{ .left = 0, .top = 0, .right = @intCast(frame.width), .bottom = @intCast(frame.height) };
            lv.RSSetViewports.?(list, 1, &viewport);
            lv.RSSetScissorRects.?(list, 1, &scissor);
            lv.SetGraphicsRootSignature.?(list, r.root_signature);
            var heaps = [1][*c]c.ID3D12DescriptorHeap{r.srv_heap};
            lv.SetDescriptorHeaps.?(list, 1, &heaps);
            lv.SetGraphicsRootDescriptorTable.?(list, 1, r.gpuSlot(slot_atlas));
            lv.IASetPrimitiveTopology.?(list, c.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            const vbv: c.D3D12_VERTEX_BUFFER_VIEW = .{
                .BufferLocation = r.vertices.resource.?.*.lpVtbl.*.GetGPUVirtualAddress.?(r.vertices.resource),
                .SizeInBytes = @intCast(vertex_bytes),
                .StrideInBytes = @sizeOf(batch.Vertex),
            };
            lv.IASetVertexBuffers.?(list, 0, 1, &vbv);
            const ibv: c.D3D12_INDEX_BUFFER_VIEW = .{
                .BufferLocation = r.indices.resource.?.*.lpVtbl.*.GetGPUVirtualAddress.?(r.indices.resource),
                .SizeInBytes = @intCast(index_bytes),
                .Format = c.DXGI_FORMAT_R32_UINT,
            };
            lv.IASetIndexBuffer.?(list, &ibv);
            for (frame.draws) |dr| {
                var slot: u32 = slot_blank;
                if (dr.image) |i| {
                    if (isScene(frame, i)) {
                        // A scene not drawn (too many): nothing.
                        if (i < scene_slots.len) if (scene_slots[i]) |sl| {
                            slot = sl;
                        };
                    } else {
                        const it = r.findImage(frame.images[i]).?;
                        it.used = r.frame_number;
                        slot = it.slot;
                    }
                }
                const constants = [4]f32{ @floatFromInt(frame.width), @floatFromInt(frame.height), if (dr.smooth) 1 else 0, 0 };
                lv.SetGraphicsRoot32BitConstants.?(list, 0, 4, &constants, 0);
                lv.SetGraphicsRootDescriptorTable.?(list, 2, r.gpuSlot(slot));
                lv.DrawIndexedInstanced.?(list, dr.count, 1, dr.first, 0, 0);
            }
        }
        r.barrier(r.target, c.D3D12_RESOURCE_STATE_RENDER_TARGET, c.D3D12_RESOURCE_STATE_COPY_SOURCE);

        // The whole frame to the swapchain's back buffer.
        var back: ?*c.ID3D12Resource = null;
        defer release(back);
        if (r.swapchain) |sc| {
            const index = sc.*.lpVtbl.*.GetCurrentBackBufferIndex.?(sc);
            try check(sc.*.lpVtbl.*.GetBuffer.?(sc, index, &iid_resource, @ptrCast(&back)), "GetBuffer");
            r.barrier(back, c.D3D12_RESOURCE_STATE_PRESENT, c.D3D12_RESOURCE_STATE_COPY_DEST);
            lv.CopyResource.?(list, back, r.target);
            r.barrier(back, c.D3D12_RESOURCE_STATE_COPY_DEST, c.D3D12_RESOURCE_STATE_PRESENT);
        }
        try check(lv.Close.?(list), "Close");
        var lists = [1][*c]c.ID3D12CommandList{@ptrCast(list)};
        r.queue.?.*.lpVtbl.*.ExecuteCommandLists.?(r.queue, 1, &lists);
        if (r.swapchain) |sc| try check(sc.*.lpVtbl.*.Present.?(sc, 1, 0), "Present");
        try r.evictImages();
        try r.evict3d();
    }

    fn isScene(frame: *const batch.Frame, image: u32) bool {
        for (frame.scenes) |sd| if (sd.image == image) return true;
        return false;
    }

    fn newSlot(r: *Renderer) Error!u32 {
        return r.free_slots.pop() orelse blk: {
            if (r.next_slot == max_descriptors) return error.D3d12Failed;
            r.next_slot += 1;
            break :blk r.next_slot - 1;
        };
    }

    /// Uploads `img` as a texture (through the staging buffer at `at`).
    fn addImage(r: *Renderer, img: core.Image, at: *u64) Error!void {
        const slot = try r.newSlot();
        const res = try r.texture(c.DXGI_FORMAT_R8G8B8A8_UNORM, img.width, img.height, c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, 0);
        r.view(res.?, c.DXGI_FORMAT_R8G8B8A8_UNORM, slot);
        r.upload(res, c.DXGI_FORMAT_R8G8B8A8_UNORM, 4, at.*, 0, 0, img.width, img.height, std.mem.sliceAsBytes(img.pixels), @as(usize, img.width) * 4);
        at.* += uploadSize(img.width, img.height, 4);
        markSuperseded(r.images.items, img);
        try r.images.append(r.gpa, .{ .image = img, .resource = res, .slot = slot, .used = r.frame_number });
    }

    // ---- 3D ----

    /// The SRV slot of the texture `sd`'s scene is drawn in: drawn now (its
    /// frame's constants at `constants_at` in `constants`) if the scene or
    /// its size changed; null if no more scenes can be kept.
    fn drawScene(r: *Renderer, sd: batch.SceneDraw, constants_at: u64) Error!?u32 {
        for (r.scenes.items) |*it| if (it.key == sd.source.key and it.width == sd.width and it.height == sd.height) {
            it.used = r.frame_number;
            return it.slot;
        };
        const entry = for (r.scenes.items) |*it| {
            if (it.width == sd.width and it.height == sd.height and it.used != r.frame_number) break it;
        } else blk: {
            if (r.scenes.items.len == max_scenes) return null;
            const dev = r.device.?;
            var index: u32 = 0;
            while (for (r.scenes.items) |it| {
                if (it.index == index) break true;
            } else false) index += 1;
            const color = try r.textureSampled(c.DXGI_FORMAT_R8G8B8A8_UNORM, sd.width, sd.height, c.D3D12_RESOURCE_STATE_RENDER_TARGET, c.D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, samples_3d);
            const depth = try r.textureSampled(c.DXGI_FORMAT_D32_FLOAT, sd.width, sd.height, c.D3D12_RESOURCE_STATE_DEPTH_WRITE, c.D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL, samples_3d);
            const resolved = try r.texture(c.DXGI_FORMAT_R8G8B8A8_UNORM, sd.width, sd.height, c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, 0);
            const slot = try r.newSlot();
            r.view(resolved.?, c.DXGI_FORMAT_R8G8B8A8_UNORM, slot);
            dev.*.lpVtbl.*.CreateRenderTargetView.?(dev, color, null, heapSlot(r.rtv_heap_3d, index, r.rtvSize()));
            dev.*.lpVtbl.*.CreateDepthStencilView.?(dev, depth, null, heapSlot(r.dsv_heap_3d, index, r.dsvSize()));
            try r.scenes.append(r.gpa, .{ .key = 0, .width = sd.width, .height = sd.height, .color = color, .depth = depth, .resolved = resolved, .slot = slot, .index = index, .used = 0 });
            break :blk &r.scenes.items[r.scenes.items.len - 1];
        };
        entry.key = sd.source.key;
        entry.used = r.frame_number;
        const scene = &sd.source.scene;
        const list = r.list.?;
        const lv = list.*.lpVtbl.*;

        const frame3 = core.raster3d.gpuFrame(scene, sd.width, sd.height);
        @memcpy(r.constants.mapped[constants_at..][0..@sizeOf(Frame3)], std.mem.asBytes(&frame3));
        const rtv_handle = heapSlot(r.rtv_heap_3d, entry.index, r.rtvSize());
        const dsv_handle = heapSlot(r.dsv_heap_3d, entry.index, r.dsvSize());
        const bg = scene.background.premultiplied();
        const clear = [4]f32{ @as(f32, @floatFromInt(bg.r)) / 255, @as(f32, @floatFromInt(bg.g)) / 255, @as(f32, @floatFromInt(bg.b)) / 255, @as(f32, @floatFromInt(bg.a)) / 255 };
        lv.ClearRenderTargetView.?(list, rtv_handle, &clear, 0, null);
        lv.ClearDepthStencilView.?(list, dsv_handle, c.D3D12_CLEAR_FLAG_DEPTH, 1, 0, 0, null);
        lv.OMSetRenderTargets.?(list, 1, &rtv_handle, 0, &dsv_handle);
        const viewport: c.D3D12_VIEWPORT = .{ .TopLeftX = 0, .TopLeftY = 0, .Width = @floatFromInt(sd.width), .Height = @floatFromInt(sd.height), .MinDepth = 0, .MaxDepth = 1 };
        const scissor: c.D3D12_RECT = .{ .left = 0, .top = 0, .right = @intCast(sd.width), .bottom = @intCast(sd.height) };
        lv.RSSetViewports.?(list, 1, &viewport);
        lv.RSSetScissorRects.?(list, 1, &scissor);
        lv.SetGraphicsRootSignature.?(list, r.root_signature_3d);
        var heaps = [1][*c]c.ID3D12DescriptorHeap{r.srv_heap};
        lv.SetDescriptorHeaps.?(list, 1, &heaps);
        lv.SetGraphicsRootConstantBufferView.?(list, 1, r.constants.resource.?.*.lpVtbl.*.GetGPUVirtualAddress.?(r.constants.resource) + constants_at);
        lv.IASetPrimitiveTopology.?(list, c.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        for (scene.instances) |*inst| {
            const mb = try r.meshBuffers(inst.mesh);
            if (mb.count == 0) continue;
            lv.SetPipelineState.?(list, if (inst.mesh.two_sided) r.pipeline_3d_two_sided else r.pipeline_3d);
            const u = core.raster3d.gpuInstance(inst);
            lv.SetGraphicsRoot32BitConstants.?(list, 0, @sizeOf(Inst3) / 4, &u, 0);
            var tex_slot: u32 = slot_blank;
            if (inst.material.texture) |t| if (r.findImage(t)) |it| {
                it.used = r.frame_number;
                tex_slot = it.slot;
            };
            lv.SetGraphicsRootDescriptorTable.?(list, 2, r.gpuSlot(tex_slot));
            const vbv: c.D3D12_VERTEX_BUFFER_VIEW = .{
                .BufferLocation = mb.vertices.resource.?.*.lpVtbl.*.GetGPUVirtualAddress.?(mb.vertices.resource),
                .SizeInBytes = @intCast(@max(1, inst.mesh.vertices.len) * 32),
                .StrideInBytes = 32,
            };
            lv.IASetVertexBuffers.?(list, 0, 1, &vbv);
            const ibv: c.D3D12_INDEX_BUFFER_VIEW = .{
                .BufferLocation = mb.indices.resource.?.*.lpVtbl.*.GetGPUVirtualAddress.?(mb.indices.resource),
                .SizeInBytes = mb.count * 4,
                .Format = c.DXGI_FORMAT_R32_UINT,
            };
            lv.IASetIndexBuffer.?(list, &ibv);
            lv.DrawIndexedInstanced.?(list, mb.count, 1, 0, 0, 0);
        }
        // The samples resolved into the texture the frame shows.
        r.barrier(entry.color, c.D3D12_RESOURCE_STATE_RENDER_TARGET, c.D3D12_RESOURCE_STATE_RESOLVE_SOURCE);
        r.barrier(entry.resolved, c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, c.D3D12_RESOURCE_STATE_RESOLVE_DEST);
        lv.ResolveSubresource.?(list, entry.resolved, 0, entry.color, 0, c.DXGI_FORMAT_R8G8B8A8_UNORM);
        r.barrier(entry.resolved, c.D3D12_RESOURCE_STATE_RESOLVE_DEST, c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        r.barrier(entry.color, c.D3D12_RESOURCE_STATE_RESOLVE_SOURCE, c.D3D12_RESOURCE_STATE_RENDER_TARGET);
        return entry.slot;
    }

    fn rtvSize(r: *Renderer) u32 {
        return r.device.?.*.lpVtbl.*.GetDescriptorHandleIncrementSize.?(r.device, c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    }

    fn dsvSize(r: *Renderer) u32 {
        return r.device.?.*.lpVtbl.*.GetDescriptorHandleIncrementSize.?(r.device, c.D3D12_DESCRIPTOR_HEAP_TYPE_DSV);
    }

    fn heapSlot(heap: ?*c.ID3D12DescriptorHeap, index: u32, increment: u32) c.D3D12_CPU_DESCRIPTOR_HANDLE {
        var start: c.D3D12_CPU_DESCRIPTOR_HANDLE = undefined;
        _ = heap.?.*.lpVtbl.*.GetCPUDescriptorHandleForHeapStart.?(heap, &start);
        start.ptr += @as(usize, index) * increment;
        return start;
    }

    /// `mesh`'s vertices (8 floats each: position, normal, texture
    /// coordinates) and indices in upload buffers, made the first time.
    fn meshBuffers(r: *Renderer, mesh: core.raster3d.Mesh) Error!*MeshBuffers {
        for (r.meshes.items) |*m| if (m.vertices_ptr == @intFromPtr(mesh.vertices.ptr) and m.len == mesh.vertices.len and m.index_ptr == @intFromPtr(mesh.indices.ptr)) {
            m.used = r.frame_number;
            return m;
        };
        var mb: MeshBuffers = .{ .vertices_ptr = @intFromPtr(mesh.vertices.ptr), .len = mesh.vertices.len, .index_ptr = @intFromPtr(mesh.indices.ptr), .vertices = .{}, .indices = .{}, .count = @intCast(mesh.indices.len - mesh.indices.len % 3), .used = r.frame_number };
        errdefer release(mb.vertices.resource);
        errdefer release(mb.indices.resource);
        try r.ensureBuffer(&mb.vertices, @max(1, mesh.vertices.len) * 32, c.D3D12_HEAP_TYPE_UPLOAD);
        try r.ensureBuffer(&mb.indices, @max(1, mesh.indices.len) * 4, c.D3D12_HEAP_TYPE_UPLOAD);
        const floats: [*][8]f32 = @ptrCast(@alignCast(mb.vertices.mapped));
        for (mesh.vertices, 0..) |v, i| floats[i] = .{ v.position[0], v.position[1], v.position[2], v.normal[0], v.normal[1], v.normal[2], v.uv[0], v.uv[1] };
        @memcpy(mb.indices.mapped[0 .. mesh.indices.len * 4], std.mem.sliceAsBytes(mesh.indices));
        try r.meshes.append(r.gpa, mb);
        return &r.meshes.items[r.meshes.items.len - 1];
    }

    /// Meshes and scenes not drawn for a while are let go.
    fn evict3d(r: *Renderer) Error!void {
        var i: usize = 0;
        while (i < r.meshes.items.len) {
            const m = r.meshes.items[i];
            if (r.frame_number - m.used > keep_frames) {
                try r.waitIdle();
                release(m.vertices.resource);
                release(m.indices.resource);
                _ = r.meshes.swapRemove(i);
            } else i += 1;
        }
        i = 0;
        while (i < r.scenes.items.len) {
            const sc = r.scenes.items[i];
            if (r.frame_number - sc.used > keep_frames) {
                try r.waitIdle();
                for ([_]?*c.ID3D12Resource{ sc.color, sc.depth, sc.resolved }) |o| release(o);
                try r.free_slots.append(r.gpa, sc.slot);
                _ = r.scenes.swapRemove(i);
            } else i += 1;
        }
    }

    /// A flip-model swapchain the size of the frame (same format as the
    /// target, so the frame is copied as it is).
    fn ensureSwapchain(r: *Renderer, width: u32, height: u32) Error!void {
        if (r.swapchain != null and r.swapchain_size[0] == width and r.swapchain_size[1] == height) return;
        try r.waitIdle();
        if (r.swapchain) |sc| {
            try check(sc.*.lpVtbl.*.ResizeBuffers.?(sc, 0, width, height, c.DXGI_FORMAT_UNKNOWN, 0), "ResizeBuffers");
        } else {
            const desc: c.DXGI_SWAP_CHAIN_DESC1 = .{
                .Width = width,
                .Height = height,
                .Format = c.DXGI_FORMAT_R8G8B8A8_UNORM,
                .SampleDesc = .{ .Count = 1, .Quality = 0 },
                .BufferUsage = c.DXGI_USAGE_RENDER_TARGET_OUTPUT,
                .BufferCount = 2,
                .Scaling = c.DXGI_SCALING_STRETCH,
                .SwapEffect = c.DXGI_SWAP_EFFECT_FLIP_DISCARD,
                .AlphaMode = c.DXGI_ALPHA_MODE_IGNORE,
            };
            var sc1: [*c]c.IDXGISwapChain1 = null;
            const f = r.factory.?;
            try check(f.*.lpVtbl.*.CreateSwapChainForHwnd.?(f, @ptrCast(r.queue), r.hwnd, &desc, null, null, &sc1), "CreateSwapChainForHwnd");
            defer release(@as(?*c.IDXGISwapChain1, sc1));
            try check(sc1.*.lpVtbl.*.QueryInterface.?(sc1, &iid_swapchain3, @ptrCast(&r.swapchain)), "QueryInterface");
        }
        r.swapchain_size = .{ width, height };
    }

    /// The last frame's pixels (top row first), for tests and screenshots.
    pub fn readPixels(r: *Renderer, out: []core.Rgba8) Error!void {
        const w = r.target_size[0];
        const h = r.target_size[1];
        const pitch = alignedPitch(@as(u64, w) * 4);
        try r.ensureBuffer(&r.readback, pitch * h, c.D3D12_HEAP_TYPE_READBACK);
        try r.waitIdle();
        try check(r.allocator.?.*.lpVtbl.*.Reset.?(r.allocator), "Reset");
        const list = r.list.?;
        try check(list.*.lpVtbl.*.Reset.?(list, r.allocator, null), "Reset");
        const src: c.D3D12_TEXTURE_COPY_LOCATION = .{ .pResource = r.target, .Type = c.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX, .unnamed_0 = .{ .SubresourceIndex = 0 } };
        const dst: c.D3D12_TEXTURE_COPY_LOCATION = .{ .pResource = r.readback.resource, .Type = c.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT, .unnamed_0 = .{ .PlacedFootprint = .{
            .Offset = 0,
            .Footprint = .{ .Format = c.DXGI_FORMAT_R8G8B8A8_UNORM, .Width = w, .Height = h, .Depth = 1, .RowPitch = @intCast(pitch) },
        } } };
        list.*.lpVtbl.*.CopyTextureRegion.?(list, &dst, 0, 0, 0, &src, null);
        try check(list.*.lpVtbl.*.Close.?(list), "Close");
        var lists = [1][*c]c.ID3D12CommandList{@ptrCast(list)};
        r.queue.?.*.lpVtbl.*.ExecuteCommandLists.?(r.queue, 1, &lists);
        try r.waitIdle();
        for (0..h) |row| @memcpy(std.mem.sliceAsBytes(out[row * w ..][0..w]), r.readback.mapped[row * pitch ..][0 .. @as(usize, w) * 4]);
    }
};

// ---- Tests (on Windows, with a GPU or WARP) ----

const testing = std.testing;

test "Direct3D 12 draws what the software renderer draws, also partially" {
    var r = Renderer.init(testing.allocator, null) catch return error.SkipZigTest;
    defer r.deinit();
    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 120, .height = 80 });
    defer ui.deinit();
    var card: core.items.Rectangle = .{};
    defer card.deinit();
    var button: core.items.Rectangle = .{};
    defer button.deinit();
    ui.rootItem().appendChildren(&.{ &card.item, &button.item });
    card.item.setGeometry(.{ .x = 64, .y = 8, .width = 50, .height = 40 });
    card.border_radius.set(9);
    card.border_width.set(2.5);
    card.border_color.set(.color(.rgb(0x111827)));
    card.background.set(.linear(45, &.{ .{ .color = .rgb(0xf59e0b), .position = 0 }, .{ .color = .rgb(0x7c3aed), .position = 1 } }));
    button.item.setGeometry(.{ .x = 10, .y = 10, .width = 40, .height = 24 });
    button.background.set(.color(.rgb(0xff0000)));
    const w = 240;
    const h = 160;
    r.setScaleFactor(2);
    var drawn: [w * h]core.Rgba8 = undefined;
    var expected: [w * h]core.Rgba8 = undefined;
    var software: zigulee.software.Renderer(core.Rgba8) = .init(testing.allocator);
    defer software.deinit();
    software.scale_factor = 2;
    for (0..2) |round| {
        if (round == 1) button.background.set(.color(.rgb(0x00aa55)));
        _ = try r.renderWindow(&ui, w, h, if (round == 0) .full else .partial);
        try r.readPixels(&drawn);
        @memset(&expected, .transparent);
        _ = try software.renderWindow(&ui, .init(&expected, w, h), .full);
        for (expected, drawn) |e, a| {
            inline for (.{ "r", "g", "b", "a" }) |ch| try testing.expect(@abs(@as(i16, @field(e, ch)) - @field(a, ch)) <= 3);
        }
    }
}

test "Direct3D 12 draws a 3D scene as the CPU does, kept while it is the same" {
    var r = Renderer.init(testing.allocator, null) catch return error.SkipZigTest;
    defer r.deinit();
    if (!r.batcher.gpu_scenes) {
        std.debug.print("no 3D pipeline on Direct3D 12: skipped\n", .{});
        return error.SkipZigTest;
    }
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

    const w = 160;
    const h = 120;
    r.setScaleFactor(2);
    var drawn: [w * h]core.Rgba8 = undefined;
    var expected: [w * h]core.Rgba8 = undefined;
    _ = try r.renderWindow(&ui, w, h, .full);
    try r.readPixels(&drawn);
    // Drawn on the GPU: no picture on the CPU.
    try testing.expectEqual(@as(u32, 0), view.width);
    var software: zigulee.software.Renderer(core.Rgba8) = .init(testing.allocator);
    defer software.deinit();
    software.scale_factor = 2;
    @memset(&expected, .transparent);
    _ = try software.renderWindow(&ui, .init(&expected, w, h), .full);
    // The same but for edges (multisampled here, oversampled there) and
    // rounding.
    var off: usize = 0;
    for (expected, drawn) |e, a| {
        inline for (.{ "r", "g", "b", "a" }) |ch| {
            if (@abs(@as(i16, @field(e, ch)) - @field(a, ch)) > 24) {
                off += 1;
                break;
            }
        }
    }
    if (off >= w * h / 50) std.debug.print("{d} of {d} pixels differ; at (46, 60): {any} on the CPU, {any} here\n", .{ off, w * h, expected[60 * w + 46], drawn[60 * w + 46] });
    try testing.expect(off < w * h / 50);
    try testing.expect(drawn[60 * w + 46].r > drawn[60 * w + 46].b + 60);
    try testing.expect(drawn[60 * w + 112].b > drawn[60 * w + 112].r + 60);

    // The same scene again: its texture kept; changed: drawn again.
    const kept = r.scenes.items[0].resolved;
    _ = try r.renderWindow(&ui, w, h, .full);
    try testing.expectEqual(kept, r.scenes.items[0].resolved);
    try testing.expectEqual(@as(usize, 1), r.scenes.items.len);
    cube.color.set(.rgb(0x22c55e));
    _ = try r.renderWindow(&ui, w, h, .partial);
    try r.readPixels(&drawn);
    try testing.expect(drawn[60 * w + 46].g > drawn[60 * w + 46].r + 60);
}

/// Marks the cached copies of older versions of `img`'s pixels stale.
fn markSuperseded(items: anytype, img: core.Image) void {
    for (items) |*it| if (img.supersedes(it.image)) {
        it.used = std.math.maxInt(u64); // Renderer.stale
    };
}
