// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The GPU renderer on Vulkan: draws the batcher's frames (batch.zig) with
//! the same shading as the OpenGL and Metal executors (shaders/vulkan.*,
//! compiled to SPIR-V and embedded). Frames are drawn into an image that
//! keeps the last one (partial frames clear and redraw only what changed),
//! then copied to a window's swapchain.
//!
//! 3D scenes (`View3D`) are drawn here too, each into an image of its own
//! (4x multisampled, with depth, resolved in the same render pass), shaded
//! as raster3d.zig shades them on the CPU (shaders/vulkan3d.*); the frame
//! shows that image as any other.
//!
//! The Vulkan library is loaded at run time (the loader, or MoltenVK on
//! macOS): nothing to link. Windows are reached through a surface made from
//! the platform's handles (`Surface`): a CAMetalLayer, a Win32 window, an
//! X11 or a Wayland window.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const core = @import("../../core/core.zig");
const batch = @import("batch.zig");

const log = std.log.scoped(.zigulee_vulkan);

const call: std.builtin.CallingConvention = if (builtin.os.tag == .windows and builtin.cpu.arch == .x86) .{ .x86_stdcall = .{} } else .c;

// ---- Vulkan's definitions (the parts used) ----

const Instance = ?*opaque {};
const PhysicalDevice = ?*opaque {};
const Device = ?*opaque {};
const Queue = ?*opaque {};
const CommandBuffer = ?*opaque {};
/// Non-dispatchable handles are 64-bit everywhere.
const Handle = u64;
const Result = i32;
const Bool32 = u32;
const Flags = u32;

const success: Result = 0;
const suboptimal: Result = 1000001003;
const out_of_date: Result = -1000001004;

const ST = struct {
    const application_info = 0;
    const instance_create_info = 1;
    const device_queue_create_info = 2;
    const device_create_info = 3;
    const submit_info = 4;
    const memory_allocate_info = 5;
    const fence_create_info = 8;
    const semaphore_create_info = 9;
    const buffer_create_info = 12;
    const image_create_info = 14;
    const image_view_create_info = 15;
    const shader_module_create_info = 16;
    const pipeline_shader_stage_create_info = 18;
    const pipeline_vertex_input_state_create_info = 19;
    const pipeline_input_assembly_state_create_info = 20;
    const pipeline_viewport_state_create_info = 22;
    const pipeline_rasterization_state_create_info = 23;
    const pipeline_multisample_state_create_info = 24;
    const pipeline_depth_stencil_state_create_info = 25;
    const pipeline_color_blend_state_create_info = 26;
    const pipeline_dynamic_state_create_info = 27;
    const graphics_pipeline_create_info = 28;
    const pipeline_layout_create_info = 30;
    const sampler_create_info = 31;
    const descriptor_set_layout_create_info = 32;
    const descriptor_pool_create_info = 33;
    const descriptor_set_allocate_info = 34;
    const write_descriptor_set = 35;
    const framebuffer_create_info = 37;
    const render_pass_create_info = 38;
    const command_pool_create_info = 39;
    const command_buffer_allocate_info = 40;
    const command_buffer_begin_info = 42;
    const render_pass_begin_info = 43;
    const image_memory_barrier = 45;
    const swapchain_create_info = 1000001000;
    const present_info = 1000001001;
    const xlib_surface_create_info = 1000004000;
    const wayland_surface_create_info = 1000006000;
    const win32_surface_create_info = 1000009000;
    const metal_surface_create_info = 1000217000;
};

const format_r8 = 9;
const format_rgba8 = 37;
const format_bgra8 = 44;
const format_rg32f = 103;
const format_rgb32f = 106;
const format_rgba32f = 109;
const format_d32 = 126;

const layout_undefined = 0;
const layout_color_attachment = 2;
const layout_depth_attachment = 3;
const layout_shader_read = 5;
const layout_transfer_src = 6;
const layout_transfer_dst = 7;
const layout_present = 1000001002;

const access_shader_read = 0x20;
const access_color_write = 0x100;
const access_color_read = 0x80;
const access_depth_read = 0x200;
const access_depth_write = 0x400;
const access_transfer_read = 0x800;
const access_transfer_write = 0x1000;
const access_host_read = 0x2000;

const stage_top = 0x1;
const stage_fragment = 0x80;
const stage_early_fragment = 0x100;
const stage_late_fragment = 0x200;
const stage_color_output = 0x400;
const stage_transfer = 0x1000;
const stage_bottom = 0x2000;
const stage_host = 0x4000;

const aspect_color = 1;
const aspect_depth = 2;
const queue_family_ignored = ~@as(u32, 0);
const subpass_external = ~@as(u32, 0);

const Extent2D = extern struct { width: u32, height: u32 };
const Extent3D = extern struct { width: u32, height: u32, depth: u32 = 1 };
const Offset2D = extern struct { x: i32 = 0, y: i32 = 0 };
const Offset3D = extern struct { x: i32 = 0, y: i32 = 0, z: i32 = 0 };
const Rect2D = extern struct { offset: Offset2D = .{}, extent: Extent2D };
const SubresourceRange = extern struct { aspect_mask: Flags = aspect_color, base_mip: u32 = 0, levels: u32 = 1, base_layer: u32 = 0, layers: u32 = 1 };
const SubresourceLayers = extern struct { aspect_mask: Flags = aspect_color, mip: u32 = 0, base_layer: u32 = 0, layers: u32 = 1 };
const ClearValue = extern struct { color: [4]f32 = .{ 0, 0, 0, 0 } };

const ApplicationInfo = extern struct { s_type: u32 = ST.application_info, next: ?*const anyopaque = null, app_name: ?[*:0]const u8, app_version: u32 = 0, engine_name: ?[*:0]const u8, engine_version: u32 = 0, api_version: u32 };
const InstanceCreateInfo = extern struct { s_type: u32 = ST.instance_create_info, next: ?*const anyopaque = null, flags: Flags = 0, app_info: ?*const ApplicationInfo, layer_count: u32 = 0, layers: ?[*]const [*:0]const u8 = null, extension_count: u32, extensions: ?[*]const [*:0]const u8 };
const ExtensionProperties = extern struct { name: [256]u8, spec_version: u32 };
const QueueFamilyProperties = extern struct { flags: Flags, count: u32, timestamp_bits: u32, granularity: Extent3D };
const MemoryType = extern struct { flags: Flags, heap: u32 };
const MemoryHeap = extern struct { size: u64, flags: Flags };
const MemoryProperties = extern struct { type_count: u32, types: [32]MemoryType, heap_count: u32, heaps: [16]MemoryHeap };
const DeviceQueueCreateInfo = extern struct { s_type: u32 = ST.device_queue_create_info, next: ?*const anyopaque = null, flags: Flags = 0, family: u32, count: u32, priorities: [*]const f32 };
const DeviceCreateInfo = extern struct { s_type: u32 = ST.device_create_info, next: ?*const anyopaque = null, flags: Flags = 0, queue_info_count: u32, queue_infos: [*]const DeviceQueueCreateInfo, layer_count: u32 = 0, layers: ?[*]const [*:0]const u8 = null, extension_count: u32, extensions: ?[*]const [*:0]const u8, features: ?*const anyopaque = null };
const CommandPoolCreateInfo = extern struct { s_type: u32 = ST.command_pool_create_info, next: ?*const anyopaque = null, flags: Flags, family: u32 };
const CommandBufferAllocateInfo = extern struct { s_type: u32 = ST.command_buffer_allocate_info, next: ?*const anyopaque = null, pool: Handle, level: u32 = 0, count: u32 };
const CommandBufferBeginInfo = extern struct { s_type: u32 = ST.command_buffer_begin_info, next: ?*const anyopaque = null, flags: Flags = 1, inheritance: ?*const anyopaque = null };
const SubmitInfo = extern struct { s_type: u32 = ST.submit_info, next: ?*const anyopaque = null, wait_count: u32 = 0, waits: ?[*]const Handle = null, wait_stages: ?[*]const Flags = null, buffer_count: u32, buffers: [*]const CommandBuffer, signal_count: u32 = 0, signals: ?[*]const Handle = null };
const FenceCreateInfo = extern struct { s_type: u32 = ST.fence_create_info, next: ?*const anyopaque = null, flags: Flags };
const SemaphoreCreateInfo = extern struct { s_type: u32 = ST.semaphore_create_info, next: ?*const anyopaque = null, flags: Flags = 0 };
const BufferCreateInfo = extern struct { s_type: u32 = ST.buffer_create_info, next: ?*const anyopaque = null, flags: Flags = 0, size: u64, usage: Flags, sharing: u32 = 0, family_count: u32 = 0, families: ?[*]const u32 = null };
const MemoryRequirements = extern struct { size: u64, alignment: u64, type_bits: u32 };
const MemoryAllocateInfo = extern struct { s_type: u32 = ST.memory_allocate_info, next: ?*const anyopaque = null, size: u64, type_index: u32 };
const ImageCreateInfo = extern struct { s_type: u32 = ST.image_create_info, next: ?*const anyopaque = null, flags: Flags = 0, image_type: u32 = 1, format: u32, extent: Extent3D, mips: u32 = 1, layers: u32 = 1, samples: u32 = 1, tiling: u32 = 0, usage: Flags, sharing: u32 = 0, family_count: u32 = 0, families: ?[*]const u32 = null, initial_layout: u32 = layout_undefined };
const ImageViewCreateInfo = extern struct { s_type: u32 = ST.image_view_create_info, next: ?*const anyopaque = null, flags: Flags = 0, image: Handle, view_type: u32 = 1, format: u32, components: [4]u32 = .{ 0, 0, 0, 0 }, range: SubresourceRange = .{} };
const SamplerCreateInfo = extern struct { s_type: u32 = ST.sampler_create_info, next: ?*const anyopaque = null, flags: Flags = 0, mag: u32, min: u32, mipmap: u32 = 0, u: u32 = 2, v: u32 = 2, w: u32 = 2, lod_bias: f32 = 0, anisotropy: Bool32 = 0, max_anisotropy: f32 = 1, compare: Bool32 = 0, compare_op: u32 = 0, min_lod: f32 = 0, max_lod: f32 = 0, border: u32 = 0, unnormalized: Bool32 = 0 };
const ImageMemoryBarrier = extern struct { s_type: u32 = ST.image_memory_barrier, next: ?*const anyopaque = null, src_access: Flags, dst_access: Flags, old_layout: u32, new_layout: u32, src_family: u32 = queue_family_ignored, dst_family: u32 = queue_family_ignored, image: Handle, range: SubresourceRange = .{} };
const BufferImageCopy = extern struct { offset: u64, row_length: u32 = 0, image_height: u32 = 0, subresource: SubresourceLayers = .{}, image_offset: Offset3D = .{}, image_extent: Extent3D };
const ImageBlit = extern struct { src: SubresourceLayers = .{}, src_offsets: [2]Offset3D, dst: SubresourceLayers = .{}, dst_offsets: [2]Offset3D };
const AttachmentDescription = extern struct { flags: Flags = 0, format: u32, samples: u32 = 1, load: u32, store: u32 = 0, stencil_load: u32 = 2, stencil_store: u32 = 1, initial_layout: u32, final_layout: u32 };
const AttachmentReference = extern struct { attachment: u32, layout: u32 };
const SubpassDescription = extern struct { flags: Flags = 0, bind_point: u32 = 0, input_count: u32 = 0, inputs: ?*const AttachmentReference = null, color_count: u32, colors: [*]const AttachmentReference, resolves: ?*const AttachmentReference = null, depth: ?*const AttachmentReference = null, preserve_count: u32 = 0, preserves: ?*const u32 = null };
const SubpassDependency = extern struct { src_subpass: u32, dst_subpass: u32, src_stages: Flags, dst_stages: Flags, src_access: Flags, dst_access: Flags, flags: Flags = 0 };
const RenderPassCreateInfo = extern struct { s_type: u32 = ST.render_pass_create_info, next: ?*const anyopaque = null, flags: Flags = 0, attachment_count: u32, attachments: [*]const AttachmentDescription, subpass_count: u32, subpasses: [*]const SubpassDescription, dependency_count: u32, dependencies: [*]const SubpassDependency };
const FramebufferCreateInfo = extern struct { s_type: u32 = ST.framebuffer_create_info, next: ?*const anyopaque = null, flags: Flags = 0, render_pass: Handle, attachment_count: u32, attachments: [*]const Handle, width: u32, height: u32, layers: u32 = 1 };
const RenderPassBeginInfo = extern struct { s_type: u32 = ST.render_pass_begin_info, next: ?*const anyopaque = null, render_pass: Handle, framebuffer: Handle, area: Rect2D, clear_count: u32, clears: ?[*]const ClearValue };
const ClearAttachment = extern struct { aspect: Flags = aspect_color, attachment: u32 = 0, value: ClearValue = .{} };
const ClearRect = extern struct { rect: Rect2D, base_layer: u32 = 0, layers: u32 = 1 };
const ShaderModuleCreateInfo = extern struct { s_type: u32 = ST.shader_module_create_info, next: ?*const anyopaque = null, flags: Flags = 0, size: usize, code: [*]const u32 };
const DescriptorSetLayoutBinding = extern struct { binding: u32, kind: u32 = 1, count: u32 = 1, stages: Flags = 0x10, immutable: ?*const Handle = null };
const DescriptorSetLayoutCreateInfo = extern struct { s_type: u32 = ST.descriptor_set_layout_create_info, next: ?*const anyopaque = null, flags: Flags = 0, count: u32, bindings: [*]const DescriptorSetLayoutBinding };
const PushConstantRange = extern struct { stages: Flags, offset: u32, size: u32 };
const PipelineLayoutCreateInfo = extern struct { s_type: u32 = ST.pipeline_layout_create_info, next: ?*const anyopaque = null, flags: Flags = 0, set_count: u32, sets: [*]const Handle, push_count: u32, pushes: [*]const PushConstantRange };
const ShaderStageCreateInfo = extern struct { s_type: u32 = ST.pipeline_shader_stage_create_info, next: ?*const anyopaque = null, flags: Flags = 0, stage: Flags, module: Handle, name: [*:0]const u8 = "main", specialization: ?*const anyopaque = null };
const VertexBinding = extern struct { binding: u32, stride: u32, rate: u32 = 0 };
const VertexAttribute = extern struct { location: u32, binding: u32 = 0, format: u32, offset: u32 };
const VertexInputState = extern struct { s_type: u32 = ST.pipeline_vertex_input_state_create_info, next: ?*const anyopaque = null, flags: Flags = 0, binding_count: u32, bindings: [*]const VertexBinding, attribute_count: u32, attributes: [*]const VertexAttribute };
const InputAssemblyState = extern struct { s_type: u32 = ST.pipeline_input_assembly_state_create_info, next: ?*const anyopaque = null, flags: Flags = 0, topology: u32 = 3, restart: Bool32 = 0 };
const ViewportState = extern struct { s_type: u32 = ST.pipeline_viewport_state_create_info, next: ?*const anyopaque = null, flags: Flags = 0, viewport_count: u32 = 1, viewports: ?*const anyopaque = null, scissor_count: u32 = 1, scissors: ?*const anyopaque = null };
const RasterizationState = extern struct { s_type: u32 = ST.pipeline_rasterization_state_create_info, next: ?*const anyopaque = null, flags: Flags = 0, depth_clamp: Bool32 = 0, discard: Bool32 = 0, polygon: u32 = 0, cull: Flags = 0, front: u32 = 0, depth_bias: Bool32 = 0, bias_constant: f32 = 0, bias_clamp: f32 = 0, bias_slope: f32 = 0, line_width: f32 = 1 };
const MultisampleState = extern struct { s_type: u32 = ST.pipeline_multisample_state_create_info, next: ?*const anyopaque = null, flags: Flags = 0, samples: u32 = 1, sample_shading: Bool32 = 0, min_sample_shading: f32 = 0, mask: ?*const u32 = null, alpha_to_coverage: Bool32 = 0, alpha_to_one: Bool32 = 0 };
const ColorBlendAttachment = extern struct { enable: Bool32, src_color: u32 = 1, dst_color: u32 = 7, color_op: u32 = 0, src_alpha: u32 = 1, dst_alpha: u32 = 7, alpha_op: u32 = 0, write_mask: Flags = 0xf };
const ColorBlendState = extern struct { s_type: u32 = ST.pipeline_color_blend_state_create_info, next: ?*const anyopaque = null, flags: Flags = 0, logic_enable: Bool32 = 0, logic_op: u32 = 0, count: u32 = 1, attachments: *const ColorBlendAttachment, constants: [4]f32 = .{ 0, 0, 0, 0 } };
const DynamicState = extern struct { s_type: u32 = ST.pipeline_dynamic_state_create_info, next: ?*const anyopaque = null, flags: Flags = 0, count: u32, states: [*]const u32 };
const GraphicsPipelineCreateInfo = extern struct {
    s_type: u32 = ST.graphics_pipeline_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    stage_count: u32,
    stages: [*]const ShaderStageCreateInfo,
    vertex_input: *const VertexInputState,
    input_assembly: *const InputAssemblyState,
    tessellation: ?*const anyopaque = null,
    viewport: *const ViewportState,
    rasterization: *const RasterizationState,
    multisample: *const MultisampleState,
    depth_stencil: ?*const anyopaque = null,
    color_blend: *const ColorBlendState,
    dynamic: *const DynamicState,
    layout: Handle,
    render_pass: Handle,
    subpass: u32 = 0,
    base: Handle = 0,
    base_index: i32 = -1,
};
const StencilOpState = extern struct { fail: u32 = 0, pass: u32 = 0, depth_fail: u32 = 0, compare: u32 = 7, compare_mask: u32 = 0, write_mask: u32 = 0, reference: u32 = 0 };
const DepthStencilState = extern struct { s_type: u32 = ST.pipeline_depth_stencil_state_create_info, next: ?*const anyopaque = null, flags: Flags = 0, depth_test: Bool32 = 1, depth_write: Bool32 = 1, compare: u32 = 1, depth_bounds: Bool32 = 0, stencil_test: Bool32 = 0, front: StencilOpState = .{}, back: StencilOpState = .{}, min_bounds: f32 = 0, max_bounds: f32 = 1 };
const DescriptorBufferInfo = extern struct { buffer: Handle, offset: u64 = 0, range: u64 };
const Viewport = extern struct { x: f32 = 0, y: f32 = 0, width: f32, height: f32, min_depth: f32 = 0, max_depth: f32 = 1 };
const DescriptorPoolSize = extern struct { kind: u32 = 1, count: u32 };
const DescriptorPoolCreateInfo = extern struct { s_type: u32 = ST.descriptor_pool_create_info, next: ?*const anyopaque = null, flags: Flags = 1, max_sets: u32, size_count: u32 = 1, sizes: [*]const DescriptorPoolSize };
const DescriptorSetAllocateInfo = extern struct { s_type: u32 = ST.descriptor_set_allocate_info, next: ?*const anyopaque = null, pool: Handle, count: u32 = 1, layouts: [*]const Handle };
const DescriptorImageInfo = extern struct { sampler: Handle, view: Handle, layout: u32 = layout_shader_read };
const WriteDescriptorSet = extern struct { s_type: u32 = ST.write_descriptor_set, next: ?*const anyopaque = null, set: Handle, binding: u32, element: u32 = 0, count: u32 = 1, kind: u32 = 1, images: ?*const DescriptorImageInfo, buffers: ?*const anyopaque = null, texel_views: ?*const anyopaque = null };
const SurfaceCapabilities = extern struct { min_images: u32, max_images: u32, current_extent: Extent2D, min_extent: Extent2D, max_extent: Extent2D, max_layers: u32, transforms: Flags, current_transform: Flags, composite_alpha: Flags, usage: Flags };
const SurfaceFormat = extern struct { format: u32, color_space: u32 };
const SwapchainCreateInfo = extern struct { s_type: u32 = ST.swapchain_create_info, next: ?*const anyopaque = null, flags: Flags = 0, surface: Handle, min_images: u32, format: u32, color_space: u32, extent: Extent2D, layers: u32 = 1, usage: Flags, sharing: u32 = 0, family_count: u32 = 0, families: ?[*]const u32 = null, transform: Flags, composite_alpha: Flags, present_mode: u32 = 2, clipped: Bool32 = 1, old: Handle };
const PresentInfo = extern struct { s_type: u32 = ST.present_info, next: ?*const anyopaque = null, wait_count: u32, waits: [*]const Handle, swapchain_count: u32 = 1, swapchains: [*]const Handle, indices: [*]const u32, results: ?*Result = null };
const MetalSurfaceCreateInfo = extern struct { s_type: u32 = ST.metal_surface_create_info, next: ?*const anyopaque = null, flags: Flags = 0, layer: ?*anyopaque };
const Win32SurfaceCreateInfo = extern struct { s_type: u32 = ST.win32_surface_create_info, next: ?*const anyopaque = null, flags: Flags = 0, hinstance: ?*anyopaque, hwnd: ?*anyopaque };
const XlibSurfaceCreateInfo = extern struct { s_type: u32 = ST.xlib_surface_create_info, next: ?*const anyopaque = null, flags: Flags = 0, display: ?*anyopaque, window: c_ulong };
const WaylandSurfaceCreateInfo = extern struct { s_type: u32 = ST.wayland_surface_create_info, next: ?*const anyopaque = null, flags: Flags = 0, display: ?*anyopaque, surface: ?*anyopaque };

/// The functions used, looked up by name.
const Fns = struct {
    vkDestroyInstance: *const fn (Instance, ?*const anyopaque) callconv(call) void,
    vkEnumeratePhysicalDevices: *const fn (Instance, *u32, ?[*]PhysicalDevice) callconv(call) Result,
    vkGetPhysicalDeviceQueueFamilyProperties: *const fn (PhysicalDevice, *u32, ?[*]QueueFamilyProperties) callconv(call) void,
    vkGetPhysicalDeviceMemoryProperties: *const fn (PhysicalDevice, *MemoryProperties) callconv(call) void,
    vkEnumerateDeviceExtensionProperties: *const fn (PhysicalDevice, ?[*:0]const u8, *u32, ?[*]ExtensionProperties) callconv(call) Result,
    vkCreateDevice: *const fn (PhysicalDevice, *const DeviceCreateInfo, ?*const anyopaque, *Device) callconv(call) Result,
    vkDestroyDevice: *const fn (Device, ?*const anyopaque) callconv(call) void,
    vkGetDeviceQueue: *const fn (Device, u32, u32, *Queue) callconv(call) void,
    vkDeviceWaitIdle: *const fn (Device) callconv(call) Result,
    vkCreateCommandPool: *const fn (Device, *const CommandPoolCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkDestroyCommandPool: *const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkAllocateCommandBuffers: *const fn (Device, *const CommandBufferAllocateInfo, [*]CommandBuffer) callconv(call) Result,
    vkBeginCommandBuffer: *const fn (CommandBuffer, *const CommandBufferBeginInfo) callconv(call) Result,
    vkEndCommandBuffer: *const fn (CommandBuffer) callconv(call) Result,
    vkResetCommandBuffer: *const fn (CommandBuffer, Flags) callconv(call) Result,
    vkQueueSubmit: *const fn (Queue, u32, [*]const SubmitInfo, Handle) callconv(call) Result,
    vkCreateFence: *const fn (Device, *const FenceCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkDestroyFence: *const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkWaitForFences: *const fn (Device, u32, [*]const Handle, Bool32, u64) callconv(call) Result,
    vkResetFences: *const fn (Device, u32, [*]const Handle) callconv(call) Result,
    vkCreateSemaphore: *const fn (Device, *const SemaphoreCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkDestroySemaphore: *const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkCreateBuffer: *const fn (Device, *const BufferCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkDestroyBuffer: *const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkGetBufferMemoryRequirements: *const fn (Device, Handle, *MemoryRequirements) callconv(call) void,
    vkBindBufferMemory: *const fn (Device, Handle, Handle, u64) callconv(call) Result,
    vkAllocateMemory: *const fn (Device, *const MemoryAllocateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkFreeMemory: *const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkMapMemory: *const fn (Device, Handle, u64, u64, Flags, *?*anyopaque) callconv(call) Result,
    vkCreateImage: *const fn (Device, *const ImageCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkDestroyImage: *const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkGetImageMemoryRequirements: *const fn (Device, Handle, *MemoryRequirements) callconv(call) void,
    vkBindImageMemory: *const fn (Device, Handle, Handle, u64) callconv(call) Result,
    vkCreateImageView: *const fn (Device, *const ImageViewCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkDestroyImageView: *const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkCreateSampler: *const fn (Device, *const SamplerCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkDestroySampler: *const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkCreateRenderPass: *const fn (Device, *const RenderPassCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkDestroyRenderPass: *const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkCreateFramebuffer: *const fn (Device, *const FramebufferCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkDestroyFramebuffer: *const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkCreateShaderModule: *const fn (Device, *const ShaderModuleCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkDestroyShaderModule: *const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkCreateDescriptorSetLayout: *const fn (Device, *const DescriptorSetLayoutCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkDestroyDescriptorSetLayout: *const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkCreatePipelineLayout: *const fn (Device, *const PipelineLayoutCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkDestroyPipelineLayout: *const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkCreateGraphicsPipelines: *const fn (Device, Handle, u32, [*]const GraphicsPipelineCreateInfo, ?*const anyopaque, [*]Handle) callconv(call) Result,
    vkDestroyPipeline: *const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkCreateDescriptorPool: *const fn (Device, *const DescriptorPoolCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkDestroyDescriptorPool: *const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkAllocateDescriptorSets: *const fn (Device, *const DescriptorSetAllocateInfo, [*]Handle) callconv(call) Result,
    vkFreeDescriptorSets: *const fn (Device, Handle, u32, [*]const Handle) callconv(call) Result,
    vkUpdateDescriptorSets: *const fn (Device, u32, [*]const WriteDescriptorSet, u32, ?*const anyopaque) callconv(call) void,
    vkCmdPipelineBarrier: *const fn (CommandBuffer, Flags, Flags, Flags, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, [*]const ImageMemoryBarrier) callconv(call) void,
    vkCmdCopyBufferToImage: *const fn (CommandBuffer, Handle, Handle, u32, u32, [*]const BufferImageCopy) callconv(call) void,
    vkCmdCopyImageToBuffer: *const fn (CommandBuffer, Handle, u32, Handle, u32, [*]const BufferImageCopy) callconv(call) void,
    vkCmdBlitImage: *const fn (CommandBuffer, Handle, u32, Handle, u32, u32, [*]const ImageBlit, u32) callconv(call) void,
    vkCmdBeginRenderPass: *const fn (CommandBuffer, *const RenderPassBeginInfo, u32) callconv(call) void,
    vkCmdEndRenderPass: *const fn (CommandBuffer) callconv(call) void,
    vkCmdClearAttachments: *const fn (CommandBuffer, u32, [*]const ClearAttachment, u32, [*]const ClearRect) callconv(call) void,
    vkCmdBindPipeline: *const fn (CommandBuffer, u32, Handle) callconv(call) void,
    vkCmdBindDescriptorSets: *const fn (CommandBuffer, u32, Handle, u32, u32, [*]const Handle, u32, ?*const u32) callconv(call) void,
    vkCmdBindVertexBuffers: *const fn (CommandBuffer, u32, u32, [*]const Handle, [*]const u64) callconv(call) void,
    vkCmdBindIndexBuffer: *const fn (CommandBuffer, Handle, u64, u32) callconv(call) void,
    vkCmdPushConstants: *const fn (CommandBuffer, Handle, Flags, u32, u32, *const anyopaque) callconv(call) void,
    vkCmdSetViewport: *const fn (CommandBuffer, u32, u32, [*]const Viewport) callconv(call) void,
    vkCmdSetScissor: *const fn (CommandBuffer, u32, u32, [*]const Rect2D) callconv(call) void,
    vkCmdDrawIndexed: *const fn (CommandBuffer, u32, u32, u32, i32, u32) callconv(call) void,
    // Presenting (optional: null without the extensions).
    vkDestroySurfaceKHR: ?*const fn (Instance, Handle, ?*const anyopaque) callconv(call) void,
    vkGetPhysicalDeviceSurfaceSupportKHR: ?*const fn (PhysicalDevice, u32, Handle, *Bool32) callconv(call) Result,
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: ?*const fn (PhysicalDevice, Handle, *SurfaceCapabilities) callconv(call) Result,
    vkGetPhysicalDeviceSurfaceFormatsKHR: ?*const fn (PhysicalDevice, Handle, *u32, ?[*]SurfaceFormat) callconv(call) Result,
    vkCreateSwapchainKHR: ?*const fn (Device, *const SwapchainCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkDestroySwapchainKHR: ?*const fn (Device, Handle, ?*const anyopaque) callconv(call) void,
    vkGetSwapchainImagesKHR: ?*const fn (Device, Handle, *u32, ?[*]Handle) callconv(call) Result,
    vkAcquireNextImageKHR: ?*const fn (Device, Handle, u64, Handle, Handle, *u32) callconv(call) Result,
    vkQueuePresentKHR: ?*const fn (Queue, *const PresentInfo) callconv(call) Result,
    vkCreateMetalSurfaceEXT: ?*const fn (Instance, *const MetalSurfaceCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkCreateWin32SurfaceKHR: ?*const fn (Instance, *const Win32SurfaceCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkCreateXlibSurfaceKHR: ?*const fn (Instance, *const XlibSurfaceCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
    vkCreateWaylandSurfaceKHR: ?*const fn (Instance, *const WaylandSurfaceCreateInfo, ?*const anyopaque, *Handle) callconv(call) Result,
};

/// PFN_vkVoidFunction: any function, cast to its type.
const VoidFunction = *const fn () callconv(call) void;
const GetInstanceProcAddr = *const fn (Instance, [*:0]const u8) callconv(call) ?VoidFunction;
const CreateInstance = *const fn (*const InstanceCreateInfo, ?*const anyopaque, *Instance) callconv(call) Result;
const EnumerateInstanceExtensions = *const fn (?[*:0]const u8, *u32, ?[*]ExtensionProperties) callconv(call) Result;

const vert_spv align(4) = @embedFile("shaders/vulkan.vert.spv").*;
const frag_spv align(4) = @embedFile("shaders/vulkan.frag.spv").*;
const vert_3d_spv align(4) = @embedFile("shaders/vulkan3d.vert.spv").*;
const frag_3d_spv align(4) = @embedFile("shaders/vulkan3d.frag.spv").*;

/// An instance's push constants (vulkan3d.*): its world matrix, its
/// material's color and parameters (`raster3d.GpuInstance` less the normal
/// matrix, which the shader works out: 96 of the 128 bytes there are).
const Push3 = extern struct { world: [16]f32, base: [4]f32, params: [4]f32 };
/// Samples per pixel of 3D scenes (4 is always supported).
const samples_3d = 4;
const max_scenes = 16;

/// Where frames are shown: a window, by the platform's handles.
pub const Surface = union(enum) {
    /// Draw only (tests, screenshots): see `readPixels`.
    none,
    /// macOS: a CAMetalLayer (through MoltenVK).
    metal: ?*anyopaque,
    win32: struct { hinstance: ?*anyopaque, hwnd: ?*anyopaque },
    xlib: struct { display: ?*anyopaque, window: c_ulong },
    wayland: struct { display: ?*anyopaque, surface: ?*anyopaque },
};

pub const Error = error{ VulkanUnavailable, VulkanFailed, NoDevice } || Allocator.Error;

/// A dynamic library (std.DynLib, or the Windows API's).
const Library = if (builtin.os.tag == .windows) struct {
    handle: *anyopaque,

    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) i32;

    fn open(name: []const u8) !@This() {
        var buf: [512]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch return error.NameTooLong;
        return .{ .handle = LoadLibraryA(z.ptr) orelse return error.FileNotFound };
    }
    fn lookup(l: *@This(), comptime T: type, name: [:0]const u8) ?T {
        return @ptrCast(@alignCast(GetProcAddress(l.handle, name.ptr) orelse return null));
    }
    fn close(l: *@This()) void {
        _ = FreeLibrary(l.handle);
    }
} else std.DynLib;

/// The Vulkan library's names, tried in order (`ZIGULEE_VULKAN_LIBRARY`
/// first, if set).
const libraries: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{"vulkan-1.dll"},
    .macos => &.{ "libvulkan.1.dylib", "libMoltenVK.dylib", "/opt/homebrew/lib/libvulkan.1.dylib", "/opt/homebrew/lib/libMoltenVK.dylib", "/usr/local/lib/libvulkan.1.dylib", "/usr/local/lib/libMoltenVK.dylib" },
    else => &.{ "libvulkan.so.1", "libvulkan.so" },
};

fn check(result: Result, what: []const u8) Error!void {
    if (result == success) return;
    log.err("{s} failed ({d})", .{ what, result });
    return error.VulkanFailed;
}

const Buffer = struct {
    buffer: Handle = 0,
    memory: Handle = 0,
    size: u64 = 0,
    mapped: [*]u8 = undefined,
};

const Texture = struct {
    image: Handle = 0,
    memory: Handle = 0,
    view: Handle = 0,
    width: u32 = 0,
    height: u32 = 0,
    layout: u32 = layout_undefined,
};

pub const Renderer = struct {
    gpa: Allocator,
    batcher: batch.Batcher,
    lib: Library,
    vk: Fns,
    instance: Instance,
    physical: PhysicalDevice,
    device: Device = null,
    queue: Queue = null,
    family: u32 = 0,
    memory_properties: MemoryProperties = undefined,
    surface: Handle = 0,
    pool: Handle = 0,
    commands: CommandBuffer = null,
    fence: Handle = 0,
    acquired: Handle = 0,
    finished: Handle = 0,
    set_layout: Handle = 0,
    pipeline_layout: Handle = 0,
    descriptor_pool: Handle = 0,
    /// Render passes: clearing the target first, or keeping it (partial).
    pass_clear: Handle = 0,
    pass_load: Handle = 0,
    pipeline: Handle = 0,
    smooth: Handle = 0,
    sharp: Handle = 0,
    atlas: Texture = .{},
    gradients: Texture = .{},
    blank: ImageTexture = undefined,
    /// Frames are drawn here; it keeps the last one.
    target: Texture = .{},
    framebuffer: Handle = 0,
    target_valid: bool = false,
    vertices: Buffer = .{},
    indices: Buffer = .{},
    staging: Buffer = .{},
    readback: Buffer = .{},
    images: std.ArrayList(ImageTexture) = .empty,
    frame_number: u64 = 0,
    swapchain: Swapchain = .{},
    /// 3D: the render pass, pipelines (back faces culled, or not) and their
    /// layouts, a repeating sampler, a descriptor pool; meshes' buffers and
    /// scenes' images, kept while used.
    pass_3d: Handle = 0,
    frame_layout_3d: Handle = 0,
    texture_layout_3d: Handle = 0,
    pipeline_layout_3d: Handle = 0,
    pipeline_3d: Handle = 0,
    pipeline_3d_two_sided: Handle = 0,
    repeat: Handle = 0,
    pool_3d: Handle = 0,
    meshes: std.ArrayList(MeshBuffers) = .empty,
    scenes: std.ArrayList(SceneImage) = .empty,

    const ImageTexture = struct {
        image: core.Image,
        texture: Texture,
        /// Descriptor sets: atlas, gradients and this image, with linear or
        /// nearest sampling.
        sets: [2]Handle,
        used: u64,
        /// Its set as a 3D material's texture (made when first used so).
        set_3d: Handle = 0,
    };
    const MeshBuffers = struct { vertices_ptr: usize, len: usize, index_ptr: usize, vertices: Buffer, indices: Buffer, count: u32, used: u64 };
    const SceneImage = struct {
        key: u64,
        width: u32,
        height: u32,
        /// Multisampled color and depth, resolved into `resolved`.
        color: Texture,
        depth: Texture,
        resolved: Texture,
        framebuffer: Handle,
        /// The frame's constants, and their descriptor set.
        constants: Buffer,
        frame_set: Handle,
        /// The 2D sets showing `resolved` (as `ImageTexture.sets`).
        sets: [2]Handle,
        used: u64,
    };

    const Swapchain = struct {
        handle: Handle = 0,
        images: [8]Handle = undefined,
        count: u32 = 0,
        extent: Extent2D = .{ .width = 0, .height = 0 },
    };

    const keep_frames = 120;
    /// A cached image superseded by a newer version (see `Image.supersedes`):
    /// evicted at the next opportunity.
    const stale = std.math.maxInt(u64);

    /// Loads Vulkan and opens a device (one that can show frames on
    /// `surface`).
    pub fn init(gpa: Allocator, surface: Surface) Error!Renderer {
        var lib = openLibrary() orelse return error.VulkanUnavailable;
        errdefer lib.close();
        const gipa = lib.lookup(GetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return error.VulkanUnavailable;
        const create_instance: CreateInstance = @ptrCast(gipa(null, "vkCreateInstance") orelse return error.VulkanUnavailable);
        const enumerate: EnumerateInstanceExtensions = @ptrCast(gipa(null, "vkEnumerateInstanceExtensionProperties") orelse return error.VulkanUnavailable);

        // The extensions for the surface, and portability (MoltenVK through
        // a loader), when available.
        var available: [64]ExtensionProperties = undefined;
        var count: u32 = available.len;
        _ = enumerate(null, &count, &available);
        const wanted = [_][*:0]const u8{ "VK_KHR_surface", "VK_EXT_metal_surface", "VK_KHR_win32_surface", "VK_KHR_xlib_surface", "VK_KHR_wayland_surface", "VK_KHR_portability_enumeration" };
        var enabled: [wanted.len][*:0]const u8 = undefined;
        var n: u32 = 0;
        var portability = false;
        for (wanted) |w| if (has(available[0..@min(count, available.len)], w)) {
            enabled[n] = w;
            n += 1;
            portability = portability or std.mem.orderZ(u8, w, "VK_KHR_portability_enumeration") == .eq;
        };
        const app: ApplicationInfo = .{ .app_name = "zigulee", .engine_name = "zigulee", .api_version = (1 << 22) | (1 << 12) }; // 1.1
        var instance: Instance = null;
        const created = create_instance(&.{ .flags = if (portability) 1 else 0, .app_info = &app, .extension_count = n, .extensions = &enabled }, null, &instance);
        if (created != success) {
            // A loader without a driver (VK_ERROR_INCOMPATIBLE_DRIVER), say:
            // no Vulkan here, not an error.
            log.info("vkCreateInstance failed ({d}): Vulkan unavailable", .{created});
            return error.VulkanUnavailable;
        }

        var vk: Fns = undefined;
        inline for (@typeInfo(Fns).@"struct".fields) |f| {
            const p = gipa(instance, f.name);
            if (@typeInfo(f.type) == .optional) {
                @field(vk, f.name) = @ptrCast(p);
            } else {
                @field(vk, f.name) = @ptrCast(p orelse {
                    log.err("Vulkan function {s} missing", .{f.name});
                    const destroy: *const fn (Instance, ?*const anyopaque) callconv(call) void = @ptrCast(gipa(instance, "vkDestroyInstance").?);
                    destroy(instance, null);
                    return error.VulkanUnavailable;
                });
            }
        }
        var r: Renderer = .{ .gpa = gpa, .batcher = try .init(gpa), .lib = lib, .vk = vk, .instance = instance, .physical = null };
        errdefer r.deinit();
        try r.createSurface(surface);
        try r.openDevice();
        try r.createResources();
        return r;
    }

    fn openLibrary() ?Library {
        // The environment is only reachable through libc here.
        if (builtin.link_libc) if (std.c.getenv("ZIGULEE_VULKAN_LIBRARY")) |path| if (Library.open(std.mem.span(path))) |l| return l else |_| {};
        for (libraries) |name| if (Library.open(name)) |l| return l else |_| {};
        return null;
    }

    fn has(list: []const ExtensionProperties, name: [*:0]const u8) bool {
        for (list) |e| if (std.mem.orderZ(u8, @ptrCast(&e.name), name) == .eq) return true;
        return false;
    }

    fn createSurface(r: *Renderer, surface: Surface) Error!void {
        const vk = r.vk;
        switch (surface) {
            .none => {},
            .metal => |layer| try check((vk.vkCreateMetalSurfaceEXT orelse return error.VulkanUnavailable)(r.instance, &.{ .layer = layer }, null, &r.surface), "vkCreateMetalSurfaceEXT"),
            .win32 => |w| try check((vk.vkCreateWin32SurfaceKHR orelse return error.VulkanUnavailable)(r.instance, &.{ .hinstance = w.hinstance, .hwnd = w.hwnd }, null, &r.surface), "vkCreateWin32SurfaceKHR"),
            .xlib => |x| try check((vk.vkCreateXlibSurfaceKHR orelse return error.VulkanUnavailable)(r.instance, &.{ .display = x.display, .window = x.window }, null, &r.surface), "vkCreateXlibSurfaceKHR"),
            .wayland => |w| try check((vk.vkCreateWaylandSurfaceKHR orelse return error.VulkanUnavailable)(r.instance, &.{ .display = w.display, .surface = w.surface }, null, &r.surface), "vkCreateWaylandSurfaceKHR"),
        }
    }

    /// The first device with a graphics queue (that can present to the
    /// surface, if any).
    fn openDevice(r: *Renderer) Error!void {
        const vk = r.vk;
        var devices: [16]PhysicalDevice = undefined;
        var count: u32 = devices.len;
        _ = vk.vkEnumeratePhysicalDevices(r.instance, &count, &devices);
        found: for (devices[0..@min(count, devices.len)]) |pd| {
            var families: [16]QueueFamilyProperties = undefined;
            var fc: u32 = families.len;
            vk.vkGetPhysicalDeviceQueueFamilyProperties(pd, &fc, &families);
            for (families[0..@min(fc, families.len)], 0..) |f, i| {
                if (f.flags & 1 == 0) continue; // graphics
                if (r.surface != 0) {
                    var ok: Bool32 = 0;
                    _ = (vk.vkGetPhysicalDeviceSurfaceSupportKHR orelse continue)(pd, @intCast(i), r.surface, &ok);
                    if (ok == 0) continue;
                }
                r.physical = pd;
                r.family = @intCast(i);
                break :found;
            }
        } else return error.NoDevice;
        vk.vkGetPhysicalDeviceMemoryProperties(r.physical, &r.memory_properties);

        var available: [256]ExtensionProperties = undefined;
        var ec: u32 = available.len;
        _ = vk.vkEnumerateDeviceExtensionProperties(r.physical, null, &ec, &available);
        var extensions: [2][*:0]const u8 = undefined;
        var n: u32 = 0;
        for ([_][*:0]const u8{ "VK_KHR_swapchain", "VK_KHR_portability_subset" }) |e| if (has(available[0..@min(ec, available.len)], e)) {
            extensions[n] = e;
            n += 1;
        };
        const priority: f32 = 1;
        const queue_info: DeviceQueueCreateInfo = .{ .family = r.family, .count = 1, .priorities = @ptrCast(&priority) };
        try check(vk.vkCreateDevice(r.physical, &.{ .queue_info_count = 1, .queue_infos = @ptrCast(&queue_info), .extension_count = n, .extensions = &extensions }, null, &r.device), "vkCreateDevice");
        vk.vkGetDeviceQueue(r.device, r.family, 0, &r.queue);
    }

    fn createResources(r: *Renderer) Error!void {
        const vk = r.vk;
        const d = r.device;
        try check(vk.vkCreateCommandPool(d, &.{ .flags = 2, .family = r.family }, null, &r.pool), "vkCreateCommandPool");
        try check(vk.vkAllocateCommandBuffers(d, &.{ .pool = r.pool, .count = 1 }, @ptrCast(&r.commands)), "vkAllocateCommandBuffers");
        try check(vk.vkCreateFence(d, &.{ .flags = 1 }, null, &r.fence), "vkCreateFence");
        try check(vk.vkCreateSemaphore(d, &.{}, null, &r.acquired), "vkCreateSemaphore");
        try check(vk.vkCreateSemaphore(d, &.{}, null, &r.finished), "vkCreateSemaphore");

        const bindings = [_]DescriptorSetLayoutBinding{ .{ .binding = 0 }, .{ .binding = 1 }, .{ .binding = 2 } };
        try check(vk.vkCreateDescriptorSetLayout(d, &.{ .count = bindings.len, .bindings = &bindings }, null, &r.set_layout), "vkCreateDescriptorSetLayout");
        const push: PushConstantRange = .{ .stages = 1, .offset = 0, .size = 8 };
        try check(vk.vkCreatePipelineLayout(d, &.{ .set_count = 1, .sets = @ptrCast(&r.set_layout), .push_count = 1, .pushes = @ptrCast(&push) }, null, &r.pipeline_layout), "vkCreatePipelineLayout");
        const pool_size: DescriptorPoolSize = .{ .count = 3 * 512 };
        try check(vk.vkCreateDescriptorPool(d, &.{ .max_sets = 512, .sizes = @ptrCast(&pool_size) }, null, &r.descriptor_pool), "vkCreateDescriptorPool");

        r.pass_clear = try r.renderPass(1, layout_undefined);
        r.pass_load = try r.renderPass(0, layout_transfer_src);
        r.pipeline = try r.makePipeline();
        try check(vk.vkCreateSampler(d, &.{ .mag = 1, .min = 1 }, null, &r.smooth), "vkCreateSampler");
        try check(vk.vkCreateSampler(d, &.{ .mag = 0, .min = 0 }, null, &r.sharp), "vkCreateSampler");

        r.atlas = try r.texture(format_r8, batch.atlas_size, batch.atlas_size, 4 | 2);
        r.gradients = try r.texture(format_rgba8, batch.gradient_width, batch.gradient_rows, 4 | 2);
        const blank_pixels = [1]core.Rgba8{.transparent};
        r.blank = try r.makeImageTexture(.{ .width = 1, .height = 1, .pixels = &blank_pixels });
        r.create3d() catch |err| log.info("no 3D on the GPU ({t}): scenes drawn on the CPU", .{err});
        r.batcher.gpu_scenes = r.pipeline_3d != 0 and r.pipeline_3d_two_sided != 0;
        // The blank image, and the textures' first layouts.
        try check(vk.vkResetFences(d, 1, @ptrCast(&r.fence)), "vkResetFences");
        try r.begin();
        r.transition(&r.atlas, layout_shader_read, access_shader_read, stage_fragment);
        r.transition(&r.gradients, layout_shader_read, access_shader_read, stage_fragment);
        try r.uploadImage(&r.blank, 0);
        try r.submit(&.{}, &.{});
    }

    /// The 3D render pass, layouts and pipelines: per instance its push
    /// constants, the frame's uniform buffer (set 0), the material's texture
    /// (set 1).
    fn create3d(r: *Renderer) Error!void {
        const vk = r.vk;
        const d = r.device;
        // Multisampled color and depth, resolved into a sampled image.
        const attachments = [3]AttachmentDescription{
            .{ .format = format_rgba8, .samples = samples_3d, .load = 1, .store = 1, .initial_layout = layout_undefined, .final_layout = layout_color_attachment },
            .{ .format = format_d32, .samples = samples_3d, .load = 1, .store = 1, .initial_layout = layout_undefined, .final_layout = layout_depth_attachment },
            .{ .format = format_rgba8, .load = 2, .store = 0, .initial_layout = layout_undefined, .final_layout = layout_shader_read },
        };
        const color: AttachmentReference = .{ .attachment = 0, .layout = layout_color_attachment };
        const depth: AttachmentReference = .{ .attachment = 1, .layout = layout_depth_attachment };
        const resolve: AttachmentReference = .{ .attachment = 2, .layout = layout_color_attachment };
        const subpass: SubpassDescription = .{ .color_count = 1, .colors = @ptrCast(&color), .resolves = &resolve, .depth = &depth };
        const dependencies = [_]SubpassDependency{
            .{ .src_subpass = subpass_external, .dst_subpass = 0, .src_stages = stage_fragment | stage_color_output | stage_late_fragment, .dst_stages = stage_color_output | stage_early_fragment, .src_access = access_shader_read | access_color_write | access_depth_write, .dst_access = access_color_write | access_depth_read | access_depth_write },
            .{ .src_subpass = 0, .dst_subpass = subpass_external, .src_stages = stage_color_output, .dst_stages = stage_fragment, .src_access = access_color_write, .dst_access = access_shader_read },
        };
        try check(vk.vkCreateRenderPass(d, &.{ .attachment_count = attachments.len, .attachments = &attachments, .subpass_count = 1, .subpasses = @ptrCast(&subpass), .dependency_count = dependencies.len, .dependencies = &dependencies }, null, &r.pass_3d), "vkCreateRenderPass");

        const frame_binding: DescriptorSetLayoutBinding = .{ .binding = 0, .kind = 6, .stages = 1 | 0x10 }; // uniform buffer
        try check(vk.vkCreateDescriptorSetLayout(d, &.{ .count = 1, .bindings = @ptrCast(&frame_binding) }, null, &r.frame_layout_3d), "vkCreateDescriptorSetLayout");
        const texture_binding: DescriptorSetLayoutBinding = .{ .binding = 0 };
        try check(vk.vkCreateDescriptorSetLayout(d, &.{ .count = 1, .bindings = @ptrCast(&texture_binding) }, null, &r.texture_layout_3d), "vkCreateDescriptorSetLayout");
        const layouts = [2]Handle{ r.frame_layout_3d, r.texture_layout_3d };
        const push: PushConstantRange = .{ .stages = 1 | 0x10, .offset = 0, .size = @sizeOf(Push3) };
        try check(vk.vkCreatePipelineLayout(d, &.{ .set_count = layouts.len, .sets = &layouts, .push_count = 1, .pushes = @ptrCast(&push) }, null, &r.pipeline_layout_3d), "vkCreatePipelineLayout");
        const sizes = [2]DescriptorPoolSize{ .{ .kind = 6, .count = max_scenes }, .{ .kind = 1, .count = 512 } };
        try check(vk.vkCreateDescriptorPool(d, &.{ .max_sets = max_scenes + 512, .size_count = sizes.len, .sizes = &sizes }, null, &r.pool_3d), "vkCreateDescriptorPool");
        try check(vk.vkCreateSampler(d, &.{ .mag = 1, .min = 1, .u = 0, .v = 0, .w = 0 }, null, &r.repeat), "vkCreateSampler");

        var modules: [2]Handle = .{ 0, 0 };
        defer for (modules) |m| if (m != 0) vk.vkDestroyShaderModule(d, m, null);
        try check(vk.vkCreateShaderModule(d, &.{ .size = vert_3d_spv.len, .code = @ptrCast(&vert_3d_spv) }, null, &modules[0]), "vkCreateShaderModule");
        try check(vk.vkCreateShaderModule(d, &.{ .size = frag_3d_spv.len, .code = @ptrCast(&frag_3d_spv) }, null, &modules[1]), "vkCreateShaderModule");
        const stages = [_]ShaderStageCreateInfo{ .{ .stage = 1, .module = modules[0] }, .{ .stage = 0x10, .module = modules[1] } };
        const binding: VertexBinding = .{ .binding = 0, .stride = 32 };
        const attributes = [_]VertexAttribute{
            .{ .location = 0, .format = format_rgb32f, .offset = 0 },
            .{ .location = 1, .format = format_rgb32f, .offset = 12 },
            .{ .location = 2, .format = format_rg32f, .offset = 24 },
        };
        const vertex_input: VertexInputState = .{ .binding_count = 1, .bindings = @ptrCast(&binding), .attribute_count = attributes.len, .attributes = &attributes };
        const blend: ColorBlendAttachment = .{ .enable = 1 };
        const dynamic_states = [_]u32{ 0, 1 }; // viewport, scissor
        for ([_]bool{ false, true }) |two_sided| {
            // Counter-clockwise from outside is the front (as drawn: the
            // projection turns y down for Vulkan).
            const rasterization: RasterizationState = .{ .cull = if (two_sided) 0 else 2, .front = 0 };
            const info: GraphicsPipelineCreateInfo = .{
                .stage_count = stages.len,
                .stages = &stages,
                .vertex_input = &vertex_input,
                .input_assembly = &.{},
                .viewport = &.{},
                .rasterization = &rasterization,
                .multisample = &.{ .samples = samples_3d },
                .depth_stencil = &DepthStencilState{},
                .color_blend = &.{ .attachments = &blend },
                .dynamic = &.{ .count = dynamic_states.len, .states = &dynamic_states },
                .layout = r.pipeline_layout_3d,
                .render_pass = r.pass_3d,
            };
            const target = if (two_sided) &r.pipeline_3d_two_sided else &r.pipeline_3d;
            try check(vk.vkCreateGraphicsPipelines(d, 0, 1, @ptrCast(&info), null, @ptrCast(target)), "vkCreateGraphicsPipelines");
        }
    }

    fn renderPass(r: *Renderer, load: u32, initial: u32) Error!Handle {
        const attachment: AttachmentDescription = .{ .format = format_rgba8, .load = load, .initial_layout = initial, .final_layout = layout_transfer_src };
        const color: AttachmentReference = .{ .attachment = 0, .layout = layout_color_attachment };
        const subpass: SubpassDescription = .{ .color_count = 1, .colors = @ptrCast(&color) };
        const dependencies = [_]SubpassDependency{
            .{ .src_subpass = subpass_external, .dst_subpass = 0, .src_stages = stage_transfer | stage_color_output, .dst_stages = stage_color_output, .src_access = access_transfer_read | access_color_write, .dst_access = access_color_read | access_color_write },
            .{ .src_subpass = 0, .dst_subpass = subpass_external, .src_stages = stage_color_output, .dst_stages = stage_transfer, .src_access = access_color_write, .dst_access = access_transfer_read },
        };
        var pass: Handle = 0;
        try check(r.vk.vkCreateRenderPass(r.device, &.{ .attachment_count = 1, .attachments = @ptrCast(&attachment), .subpass_count = 1, .subpasses = @ptrCast(&subpass), .dependency_count = dependencies.len, .dependencies = &dependencies }, null, &pass), "vkCreateRenderPass");
        return pass;
    }

    fn makePipeline(r: *Renderer) Error!Handle {
        const vk = r.vk;
        var modules: [2]Handle = .{ 0, 0 };
        defer for (modules) |m| if (m != 0) vk.vkDestroyShaderModule(r.device, m, null);
        try check(vk.vkCreateShaderModule(r.device, &.{ .size = vert_spv.len, .code = @ptrCast(&vert_spv) }, null, &modules[0]), "vkCreateShaderModule");
        try check(vk.vkCreateShaderModule(r.device, &.{ .size = frag_spv.len, .code = @ptrCast(&frag_spv) }, null, &modules[1]), "vkCreateShaderModule");
        const stages = [_]ShaderStageCreateInfo{ .{ .stage = 1, .module = modules[0] }, .{ .stage = 0x10, .module = modules[1] } };
        const V = batch.Vertex;
        const binding: VertexBinding = .{ .binding = 0, .stride = @sizeOf(V) };
        const attributes = [_]VertexAttribute{
            .{ .location = 0, .format = format_rg32f, .offset = @offsetOf(V, "pos") },
            .{ .location = 1, .format = format_rg32f, .offset = @offsetOf(V, "uv") },
            .{ .location = 2, .format = format_rgba32f, .offset = @offsetOf(V, "rect") },
            .{ .location = 3, .format = format_rgba32f, .offset = @offsetOf(V, "shape") },
            .{ .location = 4, .format = format_rgba32f, .offset = @offsetOf(V, "clip") },
            .{ .location = 5, .format = format_rgba32f, .offset = @offsetOf(V, "color") },
            .{ .location = 6, .format = format_rgba32f, .offset = @offsetOf(V, "paint") },
            .{ .location = 7, .format = format_rg32f, .offset = @offsetOf(V, "local") },
        };
        const vertex_input: VertexInputState = .{ .binding_count = 1, .bindings = @ptrCast(&binding), .attribute_count = attributes.len, .attributes = &attributes };
        // Premultiplied alpha.
        const blend: ColorBlendAttachment = .{ .enable = 1 };
        const dynamic_states = [_]u32{ 0, 1 }; // viewport, scissor
        var pipeline: Handle = 0;
        const info: GraphicsPipelineCreateInfo = .{
            .stage_count = stages.len,
            .stages = &stages,
            .vertex_input = &vertex_input,
            .input_assembly = &.{},
            .viewport = &.{},
            .rasterization = &.{},
            .multisample = &.{},
            .color_blend = &.{ .attachments = &blend },
            .dynamic = &.{ .count = dynamic_states.len, .states = &dynamic_states },
            .layout = r.pipeline_layout,
            .render_pass = r.pass_clear,
        };
        try check(vk.vkCreateGraphicsPipelines(r.device, 0, 1, @ptrCast(&info), null, @ptrCast(&pipeline)), "vkCreateGraphicsPipelines");
        return pipeline;
    }

    pub fn deinit(r: *Renderer) void {
        const vk = r.vk;
        const d = r.device;
        if (d != null) {
            _ = vk.vkDeviceWaitIdle(d);
            for (r.images.items) |*it| r.destroyImageTexture(it);
            r.images.deinit(r.gpa);
            for (r.meshes.items) |*m| {
                r.destroyBuffer(&m.vertices);
                r.destroyBuffer(&m.indices);
            }
            r.meshes.deinit(r.gpa);
            for (r.scenes.items) |*sc| r.destroyScene(sc);
            r.scenes.deinit(r.gpa);
            if (r.pipeline_3d != 0) vk.vkDestroyPipeline(d, r.pipeline_3d, null);
            if (r.pipeline_3d_two_sided != 0) vk.vkDestroyPipeline(d, r.pipeline_3d_two_sided, null);
            if (r.pass_3d != 0) vk.vkDestroyRenderPass(d, r.pass_3d, null);
            if (r.pipeline_layout_3d != 0) vk.vkDestroyPipelineLayout(d, r.pipeline_layout_3d, null);
            if (r.frame_layout_3d != 0) vk.vkDestroyDescriptorSetLayout(d, r.frame_layout_3d, null);
            if (r.texture_layout_3d != 0) vk.vkDestroyDescriptorSetLayout(d, r.texture_layout_3d, null);
            if (r.repeat != 0) vk.vkDestroySampler(d, r.repeat, null);
            if (r.blank.texture.image != 0) r.destroyImageTexture(&r.blank);
            if (r.pool_3d != 0) vk.vkDestroyDescriptorPool(d, r.pool_3d, null);
            r.destroySwapchain();
            for ([_]*Texture{ &r.atlas, &r.gradients, &r.target }) |t| r.destroyTexture(t);
            for ([_]*Buffer{ &r.vertices, &r.indices, &r.staging, &r.readback }) |b| r.destroyBuffer(b);
            if (r.framebuffer != 0) vk.vkDestroyFramebuffer(d, r.framebuffer, null);
            vk.vkDestroySampler(d, r.smooth, null);
            vk.vkDestroySampler(d, r.sharp, null);
            vk.vkDestroyPipeline(d, r.pipeline, null);
            vk.vkDestroyRenderPass(d, r.pass_clear, null);
            vk.vkDestroyRenderPass(d, r.pass_load, null);
            vk.vkDestroyDescriptorPool(d, r.descriptor_pool, null);
            vk.vkDestroyPipelineLayout(d, r.pipeline_layout, null);
            vk.vkDestroyDescriptorSetLayout(d, r.set_layout, null);
            vk.vkDestroySemaphore(d, r.acquired, null);
            vk.vkDestroySemaphore(d, r.finished, null);
            vk.vkDestroyFence(d, r.fence, null);
            vk.vkDestroyCommandPool(d, r.pool, null);
            vk.vkDestroyDevice(d, null);
        }
        if (r.surface != 0) if (vk.vkDestroySurfaceKHR) |f| f(r.instance, r.surface, null);
        vk.vkDestroyInstance(r.instance, null);
        r.lib.close();
        r.batcher.deinit();
    }

    pub fn setScaleFactor(r: *Renderer, scale: f32) void {
        r.batcher.scale_factor = scale;
    }

    /// Draws the window, `width` x `height` pixels (everything, or in
    /// `.partial` mode what changed), and shows it on the surface (if
    /// any). Returns the area redrawn; when empty, nothing was drawn.
    pub fn renderWindow(r: *Renderer, window: *core.Window, width: u32, height: u32, mode: core.RenderMode) Error!core.Region {
        const full = mode == .full or !r.target_valid or r.target.width != width or r.target.height != height;
        const frame = try r.batcher.build(window, width, height, if (full) .full else .partial);
        if (frame.region.isEmpty()) return .{};
        try r.draw(&frame);
        return frame.region;
    }

    fn draw(r: *Renderer, frame: *const batch.Frame) Error!void {
        const vk = r.vk;
        r.frame_number += 1;
        // One frame at a time: the last one is done.
        try check(vk.vkWaitForFences(r.device, 1, @ptrCast(&r.fence), 1, std.math.maxInt(u64)), "vkWaitForFences");
        try r.ensureTarget(frame.width, frame.height);

        // The swapchain image to show the frame in.
        var image_index: ?u32 = null;
        if (r.surface != 0) image_index = try r.acquire(frame.width, frame.height);

        try check(vk.vkResetFences(r.device, 1, @ptrCast(&r.fence)), "vkResetFences");
        try r.begin();
        const cb = r.commands;

        // Uploads: what changed in the atlas, the gradients, new images.
        var upload: u64 = 0;
        const d = frame.atlas_dirty;
        const atlas_bytes: u64 = if (d[1] > d[0]) @as(u64, d[1] - d[0]) * batch.atlas_size else 0;
        const gradient_bytes: u64 = @as(u64, frame.gradient_count) * batch.gradient_width * 4;
        upload = atlas_bytes + gradient_bytes;
        for (frame.draws) |dr| if (dr.image) |i| if (!isScene(frame, i) and r.findImage(frame.images[i]) == null) {
            upload += @as(u64, frame.images[i].width) * frame.images[i].height * 4;
        };
        // 3D scenes' materials' textures too (scenes themselves are drawn
        // here).
        for (frame.scenes) |sd| for (sd.source.scene.instances) |inst| if (inst.material.texture) |t| if (r.findImage(t) == null) {
            upload += @as(u64, t.width) * t.height * 4;
        };
        try r.ensureBuffer(&r.staging, upload, 1); // transfer source
        var at: u64 = 0;
        if (atlas_bytes > 0) {
            @memcpy(r.staging.mapped[0..atlas_bytes], frame.atlas[d[0] * batch.atlas_size ..][0..atlas_bytes]);
            r.copyIn(&r.atlas, at, 0, d[0], batch.atlas_size, d[1] - d[0]);
            at += atlas_bytes;
        }
        if (gradient_bytes > 0) {
            @memcpy(r.staging.mapped[at..][0..gradient_bytes], frame.gradients[0..gradient_bytes]);
            r.copyIn(&r.gradients, at, 0, 0, batch.gradient_width, frame.gradient_count);
            at += gradient_bytes;
        }
        for (frame.draws) |dr| if (dr.image) |i| if (!isScene(frame, i) and r.findImage(frame.images[i]) == null) {
            try r.addImage(frame.images[i], &at);
        };
        for (frame.scenes) |sd| for (sd.source.scene.instances) |inst| if (inst.material.texture) |t| if (r.findImage(t) == null) {
            try r.addImage(t, &at);
        };

        // 3D scenes, each into its image (if it changed).
        var scene_sets: [16]?*[2]Handle = @splat(null);
        for (frame.scenes) |sd| {
            if (sd.image >= scene_sets.len) continue;
            scene_sets[sd.image] = try r.drawScene(sd);
        }

        // Vertices and indices.
        const vertex_bytes = frame.vertices.len * @sizeOf(batch.Vertex);
        const index_bytes = frame.indices.len * 4;
        try r.ensureBuffer(&r.vertices, vertex_bytes, 0x80);
        try r.ensureBuffer(&r.indices, index_bytes, 0x40);
        @memcpy(r.vertices.mapped[0..vertex_bytes], std.mem.sliceAsBytes(frame.vertices));
        @memcpy(r.indices.mapped[0..index_bytes], std.mem.sliceAsBytes(frame.indices));

        // The frame: over the last one (partial), clearing what it redraws.
        const clear_all = frame.full or !r.target_valid;
        const clear: ClearValue = .{};
        const area: Rect2D = .{ .extent = .{ .width = frame.width, .height = frame.height } };
        vk.vkCmdBeginRenderPass(cb, &.{ .render_pass = if (clear_all) r.pass_clear else r.pass_load, .framebuffer = r.framebuffer, .area = area, .clear_count = 1, .clears = @ptrCast(&clear) }, 0);
        r.target_valid = true;
        if (!clear_all) {
            var rects: [core.Region.capacity]ClearRect = undefined;
            for (frame.region.slice(), 0..) |rect, k| rects[k] = .{ .rect = .{
                .offset = .{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y) },
                .extent = .{ .width = @intFromFloat(rect.width), .height = @intFromFloat(rect.height) },
            } };
            const attachment: ClearAttachment = .{};
            vk.vkCmdClearAttachments(cb, 1, @ptrCast(&attachment), @intCast(frame.region.len), &rects);
        }
        if (frame.indices.len > 0) {
            vk.vkCmdBindPipeline(cb, 0, r.pipeline);
            const viewport: Viewport = .{ .width = @floatFromInt(frame.width), .height = @floatFromInt(frame.height) };
            vk.vkCmdSetViewport(cb, 0, 1, @ptrCast(&viewport));
            vk.vkCmdSetScissor(cb, 0, 1, @ptrCast(&area));
            const size = [2]f32{ viewport.width, viewport.height };
            vk.vkCmdPushConstants(cb, r.pipeline_layout, 1, 0, 8, &size);
            const offset: u64 = 0;
            vk.vkCmdBindVertexBuffers(cb, 0, 1, @ptrCast(&r.vertices.buffer), @ptrCast(&offset));
            vk.vkCmdBindIndexBuffer(cb, r.indices.buffer, 0, 1);
            for (frame.draws) |dr| {
                var sets = &r.blank.sets;
                if (dr.image) |i| {
                    if (isScene(frame, i)) {
                        // A scene not drawn (too many): nothing.
                        if (i < scene_sets.len) if (scene_sets[i]) |ss| {
                            sets = ss;
                        };
                    } else {
                        const it = r.findImage(frame.images[i]).?;
                        it.used = r.frame_number;
                        sets = &it.sets;
                    }
                } else r.blank.used = r.frame_number;
                vk.vkCmdBindDescriptorSets(cb, 0, r.pipeline_layout, 0, 1, @ptrCast(&sets[@intFromBool(!dr.smooth)]), 0, null);
                vk.vkCmdDrawIndexed(cb, dr.count, 1, dr.first, 0, 0);
            }
        }
        vk.vkCmdEndRenderPass(cb);
        r.target.layout = layout_transfer_src;

        // The whole frame to the swapchain image.
        if (image_index) |index| {
            const image = r.swapchain.images[index];
            r.barrier(image, layout_undefined, layout_transfer_dst, 0, access_transfer_write, stage_transfer, stage_transfer);
            const blit: ImageBlit = .{
                .src_offsets = .{ .{}, .{ .x = @intCast(frame.width), .y = @intCast(frame.height), .z = 1 } },
                .dst_offsets = .{ .{}, .{ .x = @intCast(r.swapchain.extent.width), .y = @intCast(r.swapchain.extent.height), .z = 1 } },
            };
            vk.vkCmdBlitImage(cb, r.target.image, layout_transfer_src, image, layout_transfer_dst, 1, @ptrCast(&blit), 0);
            r.barrier(image, layout_transfer_dst, layout_present, access_transfer_write, 0, stage_transfer, stage_bottom);
            try r.submit(&.{r.acquired}, &.{r.finished});
            const result = r.vk.vkQueuePresentKHR.?(r.queue, &.{ .wait_count = 1, .waits = @ptrCast(&r.finished), .swapchains = @ptrCast(&r.swapchain.handle), .indices = @ptrCast(&index) });
            // A resized window: a new swapchain next time.
            if (result == out_of_date or result == suboptimal) r.swapchain.extent = .{ .width = 0, .height = 0 } else try check(result, "vkQueuePresentKHR");
        } else try r.submit(&.{}, &.{});

        r.evictImages();
        r.evict3d();
    }

    fn isScene(frame: *const batch.Frame, image: u32) bool {
        for (frame.scenes) |sd| if (sd.image == image) return true;
        return false;
    }

    /// Uploads `img` as a texture (through the staging buffer at `at`).
    fn addImage(r: *Renderer, img: core.Image, at: *u64) Error!void {
        try r.images.ensureUnusedCapacity(r.gpa, 1);
        var it = try r.makeImageTexture(img);
        try r.uploadImage(&it, at.*);
        at.* += @as(u64, img.width) * img.height * 4;
        markSuperseded(r.images.items, img);
        r.images.appendAssumeCapacity(it);
    }

    // ---- 3D ----

    /// The 2D descriptor sets showing the image `sd`'s scene is drawn in:
    /// drawn now (with the frame's commands) if the scene or its size
    /// changed; null if no more scenes can be kept.
    fn drawScene(r: *Renderer, sd: batch.SceneDraw) Error!?*[2]Handle {
        const vk = r.vk;
        const d = r.device;
        for (r.scenes.items) |*it| if (it.key == sd.source.key and it.width == sd.width and it.height == sd.height) {
            it.used = r.frame_number;
            return &it.sets;
        };
        const entry = for (r.scenes.items) |*it| {
            if (it.width == sd.width and it.height == sd.height and it.used != r.frame_number) break it;
        } else blk: {
            if (r.scenes.items.len == max_scenes) return null;
            try r.scenes.ensureUnusedCapacity(r.gpa, 1);
            var sc: SceneImage = .{ .key = 0, .width = sd.width, .height = sd.height, .color = .{}, .depth = .{}, .resolved = .{}, .framebuffer = 0, .constants = .{}, .frame_set = 0, .sets = .{ 0, 0 }, .used = 0 };
            errdefer r.destroyScene(&sc);
            sc.color = try r.textureEx(format_rgba8, sd.width, sd.height, 0x10, samples_3d, aspect_color); // color attachment
            sc.depth = try r.textureEx(format_d32, sd.width, sd.height, 0x20, samples_3d, aspect_depth); // depth attachment
            sc.resolved = try r.textureEx(format_rgba8, sd.width, sd.height, 0x10 | 4, 1, aspect_color); // color attachment, sampled
            const views = [3]Handle{ sc.color.view, sc.depth.view, sc.resolved.view };
            try check(vk.vkCreateFramebuffer(d, &.{ .render_pass = r.pass_3d, .attachment_count = views.len, .attachments = &views, .width = sd.width, .height = sd.height }, null, &sc.framebuffer), "vkCreateFramebuffer");
            try r.ensureBuffer(&sc.constants, @sizeOf(core.raster3d.GpuFrame), 0x10); // uniform buffer
            try check(vk.vkAllocateDescriptorSets(d, &.{ .pool = r.pool_3d, .layouts = @ptrCast(&r.frame_layout_3d) }, @ptrCast(&sc.frame_set)), "vkAllocateDescriptorSets");
            const buffer_info: DescriptorBufferInfo = .{ .buffer = sc.constants.buffer, .range = @sizeOf(core.raster3d.GpuFrame) };
            const write: WriteDescriptorSet = .{ .set = sc.frame_set, .binding = 0, .kind = 6, .images = null, .buffers = &buffer_info };
            vk.vkUpdateDescriptorSets(d, 1, @ptrCast(&write), 0, null);
            sc.sets = try r.imageSets(sc.resolved.view);
            r.scenes.appendAssumeCapacity(sc);
            break :blk &r.scenes.items[r.scenes.items.len - 1];
        };
        entry.key = sd.source.key;
        entry.used = r.frame_number;
        const scene = &sd.source.scene;
        const cb = r.commands;

        var frame3 = core.raster3d.gpuFrame(scene, sd.width, sd.height);
        // Vulkan's y goes down: the projection turns it over (the picture
        // the right way up).
        for (0..4) |col| frame3.view_proj[col * 4 + 1] = -frame3.view_proj[col * 4 + 1];
        @memcpy(entry.constants.mapped[0..@sizeOf(core.raster3d.GpuFrame)], std.mem.asBytes(&frame3));
        // Textures used, with their 3D sets.
        for (scene.instances) |inst| if (inst.material.texture) |t| if (r.findImage(t)) |it| {
            try r.ensureSet3d(it);
        };
        try r.ensureSet3d(&r.blank);

        const bg = scene.background.premultiplied();
        const clears = [3]ClearValue{
            .{ .color = .{ @as(f32, @floatFromInt(bg.r)) / 255, @as(f32, @floatFromInt(bg.g)) / 255, @as(f32, @floatFromInt(bg.b)) / 255, @as(f32, @floatFromInt(bg.a)) / 255 } },
            .{ .color = .{ 1, 0, 0, 0 } }, // depth 1
            .{},
        };
        const area: Rect2D = .{ .extent = .{ .width = sd.width, .height = sd.height } };
        vk.vkCmdBeginRenderPass(cb, &.{ .render_pass = r.pass_3d, .framebuffer = entry.framebuffer, .area = area, .clear_count = clears.len, .clears = &clears }, 0);
        const viewport: Viewport = .{ .width = @floatFromInt(sd.width), .height = @floatFromInt(sd.height) };
        vk.vkCmdSetViewport(cb, 0, 1, @ptrCast(&viewport));
        vk.vkCmdSetScissor(cb, 0, 1, @ptrCast(&area));
        for (scene.instances) |*inst| {
            const mb = try r.meshBuffers(inst.mesh);
            if (mb.count == 0) continue;
            vk.vkCmdBindPipeline(cb, 0, if (inst.mesh.two_sided) r.pipeline_3d_two_sided else r.pipeline_3d);
            vk.vkCmdBindDescriptorSets(cb, 0, r.pipeline_layout_3d, 0, 1, @ptrCast(&entry.frame_set), 0, null);
            const it = if (inst.material.texture) |t| r.findImage(t) orelse &r.blank else &r.blank;
            it.used = r.frame_number;
            vk.vkCmdBindDescriptorSets(cb, 0, r.pipeline_layout_3d, 1, 1, @ptrCast(&it.set_3d), 0, null);
            const u = core.raster3d.gpuInstance(inst);
            const push: Push3 = .{ .world = u.world, .base = u.base, .params = u.params };
            vk.vkCmdPushConstants(cb, r.pipeline_layout_3d, 1 | 0x10, 0, @sizeOf(Push3), &push);
            const offset: u64 = 0;
            vk.vkCmdBindVertexBuffers(cb, 0, 1, @ptrCast(&mb.vertices.buffer), @ptrCast(&offset));
            vk.vkCmdBindIndexBuffer(cb, mb.indices.buffer, 0, 1);
            vk.vkCmdDrawIndexed(cb, mb.count, 1, 0, 0, 0);
        }
        vk.vkCmdEndRenderPass(cb);
        return &entry.sets;
    }

    /// The 2D sets (atlas, gradients, this image; linear and nearest)
    /// showing `view`.
    fn imageSets(r: *Renderer, view: Handle) Error![2]Handle {
        var sets: [2]Handle = .{ 0, 0 };
        const layouts = [2]Handle{ r.set_layout, r.set_layout };
        try check(r.vk.vkAllocateDescriptorSets(r.device, &.{ .pool = r.descriptor_pool, .count = 2, .layouts = &layouts }, &sets), "vkAllocateDescriptorSets");
        for (sets, [2]Handle{ r.smooth, r.sharp }) |set, image_sampler| {
            const infos = [3]DescriptorImageInfo{ .{ .sampler = r.sharp, .view = r.atlas.view }, .{ .sampler = r.smooth, .view = r.gradients.view }, .{ .sampler = image_sampler, .view = view } };
            var writes: [3]WriteDescriptorSet = undefined;
            for (&writes, &infos, 0..) |*w, *info, k| w.* = .{ .set = set, .binding = @intCast(k), .images = info };
            r.vk.vkUpdateDescriptorSets(r.device, writes.len, &writes, 0, null);
        }
        return sets;
    }

    /// `it`'s set as a 3D material's texture (repeated, smoothed).
    fn ensureSet3d(r: *Renderer, it: *ImageTexture) Error!void {
        if (it.set_3d != 0) return;
        try check(r.vk.vkAllocateDescriptorSets(r.device, &.{ .pool = r.pool_3d, .layouts = @ptrCast(&r.texture_layout_3d) }, @ptrCast(&it.set_3d)), "vkAllocateDescriptorSets");
        const info: DescriptorImageInfo = .{ .sampler = r.repeat, .view = it.texture.view };
        const write: WriteDescriptorSet = .{ .set = it.set_3d, .binding = 0, .images = &info };
        r.vk.vkUpdateDescriptorSets(r.device, 1, @ptrCast(&write), 0, null);
    }

    fn destroyScene(r: *Renderer, sc: *SceneImage) void {
        const vk = r.vk;
        if (sc.sets[0] != 0) _ = vk.vkFreeDescriptorSets(r.device, r.descriptor_pool, 2, &sc.sets);
        if (sc.frame_set != 0) _ = vk.vkFreeDescriptorSets(r.device, r.pool_3d, 1, @ptrCast(&sc.frame_set));
        if (sc.framebuffer != 0) vk.vkDestroyFramebuffer(r.device, sc.framebuffer, null);
        r.destroyBuffer(&sc.constants);
        for ([_]*Texture{ &sc.color, &sc.depth, &sc.resolved }) |t| r.destroyTexture(t);
    }

    /// `mesh`'s vertices (8 floats each: position, normal, texture
    /// coordinates) and indices in host-visible buffers, made the first
    /// time.
    fn meshBuffers(r: *Renderer, mesh: core.raster3d.Mesh) Error!*MeshBuffers {
        for (r.meshes.items) |*m| if (m.vertices_ptr == @intFromPtr(mesh.vertices.ptr) and m.len == mesh.vertices.len and m.index_ptr == @intFromPtr(mesh.indices.ptr)) {
            m.used = r.frame_number;
            return m;
        };
        try r.meshes.ensureUnusedCapacity(r.gpa, 1);
        var mb: MeshBuffers = .{ .vertices_ptr = @intFromPtr(mesh.vertices.ptr), .len = mesh.vertices.len, .index_ptr = @intFromPtr(mesh.indices.ptr), .vertices = .{}, .indices = .{}, .count = @intCast(mesh.indices.len - mesh.indices.len % 3), .used = r.frame_number };
        errdefer r.destroyBuffer(&mb.vertices);
        errdefer r.destroyBuffer(&mb.indices);
        try r.ensureBuffer(&mb.vertices, @max(1, mesh.vertices.len) * 32, 0x80); // vertex buffer
        try r.ensureBuffer(&mb.indices, @max(1, mesh.indices.len) * 4, 0x40); // index buffer
        const floats: [*][8]f32 = @ptrCast(@alignCast(mb.vertices.mapped));
        for (mesh.vertices, 0..) |v, i| floats[i] = .{ v.position[0], v.position[1], v.position[2], v.normal[0], v.normal[1], v.normal[2], v.uv[0], v.uv[1] };
        @memcpy(mb.indices.mapped[0 .. mesh.indices.len * 4], std.mem.sliceAsBytes(mesh.indices));
        r.meshes.appendAssumeCapacity(mb);
        return &r.meshes.items[r.meshes.items.len - 1];
    }

    /// Meshes and scenes not drawn for a while are let go.
    fn evict3d(r: *Renderer) void {
        var waited = false;
        var i: usize = 0;
        while (i < r.meshes.items.len) {
            const m = &r.meshes.items[i];
            if (r.frame_number - m.used > keep_frames) {
                if (!waited) _ = r.vk.vkDeviceWaitIdle(r.device);
                waited = true;
                r.destroyBuffer(&m.vertices);
                r.destroyBuffer(&m.indices);
                _ = r.meshes.swapRemove(i);
            } else i += 1;
        }
        i = 0;
        while (i < r.scenes.items.len) {
            if (r.frame_number - r.scenes.items[i].used > keep_frames) {
                if (!waited) _ = r.vk.vkDeviceWaitIdle(r.device);
                waited = true;
                r.destroyScene(&r.scenes.items[i]);
                _ = r.scenes.swapRemove(i);
            } else i += 1;
        }
    }

    /// The last frame's pixels (top row first), for tests and screenshots.
    pub fn readPixels(r: *Renderer, out: []core.Rgba8) Error!void {
        const vk = r.vk;
        const w = r.target.width;
        const h = r.target.height;
        try check(vk.vkWaitForFences(r.device, 1, @ptrCast(&r.fence), 1, std.math.maxInt(u64)), "vkWaitForFences");
        try r.ensureBuffer(&r.readback, @as(u64, w) * h * 4, 2); // transfer destination
        try check(vk.vkResetFences(r.device, 1, @ptrCast(&r.fence)), "vkResetFences");
        try r.begin();
        const region: BufferImageCopy = .{ .offset = 0, .image_extent = .{ .width = w, .height = h } };
        vk.vkCmdCopyImageToBuffer(r.commands, r.target.image, layout_transfer_src, r.readback.buffer, 1, @ptrCast(&region));
        try r.submit(&.{}, &.{});
        try check(vk.vkWaitForFences(r.device, 1, @ptrCast(&r.fence), 1, std.math.maxInt(u64)), "vkWaitForFences");
        @memcpy(std.mem.sliceAsBytes(out[0 .. @as(usize, w) * h]), r.readback.mapped[0 .. @as(usize, w) * h * 4]);
    }

    // ---- Commands ----

    fn begin(r: *Renderer) Error!void {
        try check(r.vk.vkResetCommandBuffer(r.commands, 0), "vkResetCommandBuffer");
        try check(r.vk.vkBeginCommandBuffer(r.commands, &.{}), "vkBeginCommandBuffer");
    }

    fn submit(r: *Renderer, waits: []const Handle, signals: []const Handle) Error!void {
        try check(r.vk.vkEndCommandBuffer(r.commands), "vkEndCommandBuffer");
        const stages = [_]Flags{stage_transfer};
        try check(r.vk.vkQueueSubmit(r.queue, 1, @ptrCast(&SubmitInfo{
            .wait_count = @intCast(waits.len),
            .waits = waits.ptr,
            .wait_stages = &stages,
            .buffer_count = 1,
            .buffers = @ptrCast(&r.commands),
            .signal_count = @intCast(signals.len),
            .signals = signals.ptr,
        }), r.fence), "vkQueueSubmit");
    }

    fn barrier(r: *Renderer, image: Handle, old: u32, new: u32, src_access: Flags, dst_access: Flags, src_stage: Flags, dst_stage: Flags) void {
        const b: ImageMemoryBarrier = .{ .src_access = src_access, .dst_access = dst_access, .old_layout = old, .new_layout = new, .image = image };
        r.vk.vkCmdPipelineBarrier(r.commands, src_stage, dst_stage, 0, 0, null, 0, null, 1, @ptrCast(&b));
    }

    fn transition(r: *Renderer, t: *Texture, new: u32, access: Flags, stage: Flags) void {
        const src_access: Flags = switch (t.layout) {
            layout_transfer_dst => access_transfer_write,
            layout_shader_read => access_shader_read,
            else => 0,
        };
        const src_stage: Flags = switch (t.layout) {
            layout_transfer_dst => stage_transfer,
            layout_shader_read => stage_fragment,
            else => stage_top,
        };
        r.barrier(t.image, t.layout, new, src_access, access, src_stage, stage);
        t.layout = new;
    }

    /// Copies staging bytes at `offset` into a region of a texture.
    fn copyIn(r: *Renderer, t: *Texture, offset: u64, x: u32, y: u32, width: u32, height: u32) void {
        r.transition(t, layout_transfer_dst, access_transfer_write, stage_transfer);
        const region: BufferImageCopy = .{ .offset = offset, .image_offset = .{ .x = @intCast(x), .y = @intCast(y) }, .image_extent = .{ .width = width, .height = height } };
        r.vk.vkCmdCopyBufferToImage(r.commands, r.staging.buffer, t.image, layout_transfer_dst, 1, @ptrCast(&region));
        r.transition(t, layout_shader_read, access_shader_read, stage_fragment);
    }

    // ---- Resources ----

    fn memoryType(r: *Renderer, bits: u32, flags: Flags) Error!u32 {
        const p = r.memory_properties;
        for (0..p.type_count) |i| {
            if (bits & (@as(u32, 1) << @intCast(i)) != 0 and p.types[i].flags & flags == flags) return @intCast(i);
        }
        log.err("no suitable Vulkan memory", .{});
        return error.VulkanFailed;
    }

    /// A host-visible buffer of at least `size` bytes, mapped.
    fn ensureBuffer(r: *Renderer, b: *Buffer, size: u64, usage: Flags) Error!void {
        if (b.size >= size and b.buffer != 0) return;
        r.destroyBuffer(b);
        const capacity = @max(size, 64 * 1024, b.size * 2);
        const vk = r.vk;
        try check(vk.vkCreateBuffer(r.device, &.{ .size = capacity, .usage = usage }, null, &b.buffer), "vkCreateBuffer");
        var req: MemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(r.device, b.buffer, &req);
        try check(vk.vkAllocateMemory(r.device, &.{ .size = req.size, .type_index = try r.memoryType(req.type_bits, 2 | 4) }, null, &b.memory), "vkAllocateMemory");
        try check(vk.vkBindBufferMemory(r.device, b.buffer, b.memory, 0), "vkBindBufferMemory");
        var mapped: ?*anyopaque = null;
        try check(vk.vkMapMemory(r.device, b.memory, 0, req.size, 0, &mapped), "vkMapMemory");
        b.mapped = @ptrCast(mapped.?);
        b.size = capacity;
    }

    fn destroyBuffer(r: *Renderer, b: *Buffer) void {
        if (b.buffer != 0) r.vk.vkDestroyBuffer(r.device, b.buffer, null);
        if (b.memory != 0) r.vk.vkFreeMemory(r.device, b.memory, null);
        b.* = .{};
    }

    fn texture(r: *Renderer, format: u32, width: u32, height: u32, usage: Flags) Error!Texture {
        return r.textureEx(format, width, height, usage, 1, aspect_color);
    }

    fn textureEx(r: *Renderer, format: u32, width: u32, height: u32, usage: Flags, samples: u32, aspect: Flags) Error!Texture {
        const vk = r.vk;
        var t: Texture = .{ .width = width, .height = height };
        errdefer r.destroyTexture(&t);
        try check(vk.vkCreateImage(r.device, &.{ .format = format, .extent = .{ .width = width, .height = height }, .samples = samples, .usage = usage }, null, &t.image), "vkCreateImage");
        var req: MemoryRequirements = undefined;
        vk.vkGetImageMemoryRequirements(r.device, t.image, &req);
        try check(vk.vkAllocateMemory(r.device, &.{ .size = req.size, .type_index = try r.memoryType(req.type_bits, 1) }, null, &t.memory), "vkAllocateMemory");
        try check(vk.vkBindImageMemory(r.device, t.image, t.memory, 0), "vkBindImageMemory");
        try check(vk.vkCreateImageView(r.device, &.{ .image = t.image, .format = format, .range = .{ .aspect_mask = aspect } }, null, &t.view), "vkCreateImageView");
        return t;
    }

    fn destroyTexture(r: *Renderer, t: *Texture) void {
        if (t.view != 0) r.vk.vkDestroyImageView(r.device, t.view, null);
        if (t.image != 0) r.vk.vkDestroyImage(r.device, t.image, null);
        if (t.memory != 0) r.vk.vkFreeMemory(r.device, t.memory, null);
        t.* = .{};
    }

    fn ensureTarget(r: *Renderer, width: u32, height: u32) Error!void {
        if (r.target.image != 0 and r.target.width == width and r.target.height == height) return;
        _ = r.vk.vkDeviceWaitIdle(r.device);
        if (r.framebuffer != 0) r.vk.vkDestroyFramebuffer(r.device, r.framebuffer, null);
        r.framebuffer = 0;
        r.destroyTexture(&r.target);
        r.target = try r.texture(format_rgba8, width, height, 0x10 | 1); // color attachment, transfer source
        try check(r.vk.vkCreateFramebuffer(r.device, &.{ .render_pass = r.pass_clear, .attachment_count = 1, .attachments = @ptrCast(&r.target.view), .width = width, .height = height }, null, &r.framebuffer), "vkCreateFramebuffer");
        r.target_valid = false;
    }

    /// An image's texture and descriptor sets (its pixels are uploaded by
    /// `uploadImage`).
    fn makeImageTexture(r: *Renderer, img: core.Image) Error!ImageTexture {
        var it: ImageTexture = .{ .image = img, .texture = try r.texture(format_rgba8, img.width, img.height, 4 | 2), .sets = .{ 0, 0 }, .used = r.frame_number };
        errdefer r.destroyTexture(&it.texture);
        const layouts = [2]Handle{ r.set_layout, r.set_layout };
        try check(r.vk.vkAllocateDescriptorSets(r.device, &.{ .pool = r.descriptor_pool, .count = 2, .layouts = &layouts }, &it.sets), "vkAllocateDescriptorSets");
        for (it.sets, [2]Handle{ r.smooth, r.sharp }) |set, image_sampler| {
            const infos = [3]DescriptorImageInfo{ .{ .sampler = r.sharp, .view = r.atlas.view }, .{ .sampler = r.smooth, .view = r.gradients.view }, .{ .sampler = image_sampler, .view = it.texture.view } };
            var writes: [3]WriteDescriptorSet = undefined;
            for (&writes, &infos, 0..) |*w, *info, k| w.* = .{ .set = set, .binding = @intCast(k), .images = info };
            r.vk.vkUpdateDescriptorSets(r.device, writes.len, &writes, 0, null);
        }
        return it;
    }

    fn uploadImage(r: *Renderer, it: *ImageTexture, offset: u64) Error!void {
        const bytes = @as(u64, it.image.width) * it.image.height * 4;
        try r.ensureBuffer(&r.staging, offset + bytes, 1);
        @memcpy(r.staging.mapped[offset..][0..bytes], std.mem.sliceAsBytes(it.image.pixels[0 .. @as(usize, it.image.width) * it.image.height]));
        r.copyIn(&it.texture, offset, 0, 0, it.image.width, it.image.height);
    }

    fn findImage(r: *Renderer, img: core.Image) ?*ImageTexture {
        for (r.images.items) |*it| if (it.image.eql(img)) return it;
        return null;
    }

    fn destroyImageTexture(r: *Renderer, it: *ImageTexture) void {
        _ = r.vk.vkFreeDescriptorSets(r.device, r.descriptor_pool, 2, &it.sets);
        if (it.set_3d != 0) _ = r.vk.vkFreeDescriptorSets(r.device, r.pool_3d, 1, @ptrCast(&it.set_3d));
        r.destroyTexture(&it.texture);
    }

    fn evictImages(r: *Renderer) void {
        var i: usize = 0;
        var waited = false;
        while (i < r.images.items.len) {
            const it = &r.images.items[i];
            if (it.used == stale or r.frame_number - it.used > keep_frames) {
                if (!waited) _ = r.vk.vkDeviceWaitIdle(r.device);
                waited = true;
                r.destroyImageTexture(it);
                _ = r.images.swapRemove(i);
            } else i += 1;
        }
    }

    // ---- Swapchain ----

    /// The next swapchain image, after making the swapchain if needed.
    fn acquire(r: *Renderer, width: u32, height: u32) Error!?u32 {
        for (0..2) |_| {
            var caps: SurfaceCapabilities = undefined;
            try check(r.vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR.?(r.physical, r.surface, &caps), "vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
            const extent: Extent2D = if (caps.current_extent.width == std.math.maxInt(u32)) .{ .width = width, .height = height } else caps.current_extent;
            if (extent.width == 0 or extent.height == 0) return null; // minimized
            if (r.swapchain.handle == 0 or r.swapchain.extent.width != extent.width or r.swapchain.extent.height != extent.height) try r.createSwapchain(caps, extent);
            var index: u32 = 0;
            const result = r.vk.vkAcquireNextImageKHR.?(r.device, r.swapchain.handle, std.math.maxInt(u64), r.acquired, 0, &index);
            if (result == success or result == suboptimal) return index;
            if (result != out_of_date) try check(result, "vkAcquireNextImageKHR");
            r.swapchain.extent = .{ .width = 0, .height = 0 };
        }
        return null;
    }

    fn createSwapchain(r: *Renderer, caps: SurfaceCapabilities, extent: Extent2D) Error!void {
        const vk = r.vk;
        _ = vk.vkDeviceWaitIdle(r.device);
        var formats: [32]SurfaceFormat = undefined;
        var count: u32 = formats.len;
        _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR.?(r.physical, r.surface, &count, &formats);
        if (count == 0) return error.VulkanFailed;
        // 8-bit sRGB values, shown as they are (no conversion in shaders).
        var format = formats[0];
        for (formats[0..@min(count, formats.len)]) |f| if ((f.format == format_bgra8 or f.format == format_rgba8) and f.color_space == 0) {
            format = f;
            break;
        };
        const alpha: Flags = if (caps.composite_alpha & 1 != 0) 1 else caps.composite_alpha & (~caps.composite_alpha + 1);
        const old = r.swapchain.handle;
        var handle: Handle = 0;
        try check(vk.vkCreateSwapchainKHR.?(r.device, &.{
            .surface = r.surface,
            .min_images = @max(caps.min_images, @min(2, if (caps.max_images == 0) 2 else caps.max_images)),
            .format = format.format,
            .color_space = format.color_space,
            .extent = extent,
            .usage = 2 | 0x10, // transfer destination (the blit), color attachment
            .transform = caps.current_transform,
            .composite_alpha = alpha,
            .old = old,
        }, null, &handle), "vkCreateSwapchainKHR");
        if (old != 0) vk.vkDestroySwapchainKHR.?(r.device, old, null);
        r.swapchain = .{ .handle = handle, .extent = extent };
        var n: u32 = r.swapchain.images.len;
        try check(vk.vkGetSwapchainImagesKHR.?(r.device, handle, &n, &r.swapchain.images), "vkGetSwapchainImagesKHR");
        r.swapchain.count = n;
    }

    fn destroySwapchain(r: *Renderer) void {
        if (r.swapchain.handle != 0) if (r.vk.vkDestroySwapchainKHR) |f| f(r.device, r.swapchain.handle, null);
        r.swapchain = .{};
    }
};

// ---- Tests ----

const testing = std.testing;
const software = @import("../software/software.zig");

test "Vulkan draws what the software renderer draws, also partially" {
    var r = Renderer.init(testing.allocator, .none) catch |err| {
        std.debug.print("Vulkan unavailable ({t}): skipped\n", .{err});
        return error.SkipZigTest;
    };
    defer r.deinit();

    var ui: core.Window = undefined;
    ui.init(testing.allocator, .{ .width = 120, .height = 80 });
    defer ui.deinit();
    var card: core.items.Rectangle = .{};
    defer card.deinit();
    var button: core.items.Rectangle = .{};
    defer button.deinit();
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

    const w = 240;
    const h = 160;
    r.setScaleFactor(2);
    var drawn: [w * h]core.Rgba8 = undefined;
    var expected: [w * h]core.Rgba8 = undefined;
    var sw: software.Renderer(core.Rgba8) = .init(testing.allocator);
    defer sw.deinit();
    sw.scale_factor = 2;
    for (0..2) |round| {
        if (round == 1) button.background.set(.color(.rgb(0x00aa55)));
        const region = try r.renderWindow(&ui, w, h, if (round == 0) .full else .partial);
        if (round == 1) try testing.expect(region.boundingBox().area() < w * h / 2);
        try r.readPixels(&drawn);
        @memset(&expected, .transparent);
        _ = try sw.renderWindow(&ui, .init(&expected, w, h), .full);
        var off: usize = 0;
        var worst: u16 = 0;
        for (expected, drawn) |e, a| {
            inline for (.{ "r", "g", "b", "a" }) |c| {
                const diff = @abs(@as(i16, @field(e, c)) - @field(a, c));
                worst = @max(worst, diff);
                if (diff > 3) off += 1;
            }
        }
        if (off > 0) std.debug.print("Vulkan: {d} channels differ by more than 3 (worst {d})\n", .{ off, worst });
        try testing.expectEqual(@as(usize, 0), off);
    }
    try testing.expect((try r.renderWindow(&ui, w, h, .partial)).isEmpty());
}

test "Vulkan draws a 3D scene as the CPU does, kept while it is the same" {
    var r = Renderer.init(testing.allocator, .none) catch |err| {
        std.debug.print("Vulkan unavailable ({t}): skipped\n", .{err});
        return error.SkipZigTest;
    };
    defer r.deinit();
    if (!r.batcher.gpu_scenes) {
        std.debug.print("no 3D pipeline on Vulkan: skipped\n", .{});
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
    var sw: software.Renderer(core.Rgba8) = .init(testing.allocator);
    defer sw.deinit();
    sw.scale_factor = 2;
    @memset(&expected, .transparent);
    _ = try sw.renderWindow(&ui, .init(&expected, w, h), .full);
    // The same but for edges (multisampled here, oversampled there) and
    // rounding: the right way up, its back faces culled.
    var off: usize = 0;
    for (expected, drawn) |e, a| {
        inline for (.{ "r", "g", "b", "a" }) |c| {
            if (@abs(@as(i16, @field(e, c)) - @field(a, c)) > 24) {
                off += 1;
                break;
            }
        }
    }
    if (off >= w * h / 50) std.debug.print("Vulkan: {d} of {d} pixels differ; at (46, 60): {any} on the CPU, {any} here\n", .{ off, w * h, expected[60 * w + 46], drawn[60 * w + 46] });
    try testing.expect(off < w * h / 50);
    try testing.expect(drawn[60 * w + 46].r > drawn[60 * w + 46].b + 60);
    try testing.expect(drawn[60 * w + 112].b > drawn[60 * w + 112].r + 60);

    // The same scene again: its image kept; changed: drawn again.
    const kept = r.scenes.items[0].resolved.image;
    _ = try r.renderWindow(&ui, w, h, .full);
    try testing.expectEqual(kept, r.scenes.items[0].resolved.image);
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
