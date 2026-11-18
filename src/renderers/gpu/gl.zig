// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Draws the GPU renderer's frames (batch.zig) with OpenGL 3.3 core or
//! OpenGL ES 3.0 (WebGL2 on the web). The functions come from a loader
//! (`SDL_GL_GetProcAddress`, `eglGetProcAddress`...); the context must be
//! current when calling in.
//!
//! 3D scenes (`View3D`) are drawn here too, each into a texture of its own
//! (4x multisampled renderbuffers with depth, resolved by a blit), shaded
//! as raster3d.zig shades them on the CPU, and upside down: OpenGL's rows
//! go bottom up, so the frame shows it as any uploaded image.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const core = @import("../../core/core.zig");
const batch = @import("batch.zig");
const shader = @import("shader.zig");

const log = std.log.scoped(.zigulee_gl);

const apientry: std.builtin.CallingConvention = if (builtin.os.tag == .windows and builtin.cpu.arch == .x86) .{ .x86_stdcall = .{} } else .c;

const GLenum = u32;
const GLuint = u32;
const GLint = i32;
const GLsizei = i32;

// The constants used.
pub const TRIANGLES = 0x0004;
pub const UNSIGNED_BYTE = 0x1401;
pub const UNSIGNED_INT = 0x1405;
pub const FLOAT = 0x1406;
pub const TEXTURE_2D = 0x0DE1;
pub const TEXTURE0 = 0x84C0;
pub const RED = 0x1903;
pub const R8 = 0x8229;
pub const RGBA = 0x1908;
pub const RGBA8 = 0x8058;
pub const TEXTURE_MIN_FILTER = 0x2801;
pub const TEXTURE_MAG_FILTER = 0x2800;
pub const TEXTURE_WRAP_S = 0x2802;
pub const TEXTURE_WRAP_T = 0x2803;
pub const NEAREST = 0x2600;
pub const LINEAR = 0x2601;
pub const CLAMP_TO_EDGE = 0x812F;
pub const ARRAY_BUFFER = 0x8892;
pub const ELEMENT_ARRAY_BUFFER = 0x8893;
pub const STREAM_DRAW = 0x88E0;
pub const VERTEX_SHADER = 0x8B31;
pub const FRAGMENT_SHADER = 0x8B30;
pub const COMPILE_STATUS = 0x8B81;
pub const LINK_STATUS = 0x8B82;
pub const COLOR_BUFFER_BIT = 0x4000;
pub const BLEND = 0x0BE2;
pub const ONE = 1;
pub const ONE_MINUS_SRC_ALPHA = 0x0303;
pub const DEPTH_TEST = 0x0B71;
pub const CULL_FACE = 0x0B44;
pub const SCISSOR_TEST = 0x0C11;
pub const UNPACK_ALIGNMENT = 0x0CF5;
pub const PACK_ALIGNMENT = 0x0D05;
pub const VERSION = 0x1F02;
pub const FRAMEBUFFER = 0x8D40;
pub const READ_FRAMEBUFFER = 0x8CA8;
pub const DRAW_FRAMEBUFFER = 0x8CA9;
pub const COLOR_ATTACHMENT0 = 0x8CE0;
pub const FRAMEBUFFER_COMPLETE = 0x8CD5;
pub const RENDERBUFFER = 0x8D41;
pub const DEPTH_COMPONENT24 = 0x81A6;
pub const DEPTH_ATTACHMENT = 0x8D00;
pub const DEPTH_BUFFER_BIT = 0x0100;
pub const STATIC_DRAW = 0x88E4;
pub const REPEAT = 0x2901;
pub const CW = 0x0900;
pub const CCW = 0x0901;

/// The OpenGL functions used, loaded by name.
pub const Functions = struct {
    glGetString: *const fn (GLenum) callconv(apientry) ?[*:0]const u8,
    glGetError: *const fn () callconv(apientry) GLenum,
    glCreateShader: *const fn (GLenum) callconv(apientry) GLuint,
    glShaderSource: *const fn (GLuint, GLsizei, [*]const [*]const u8, ?[*]const GLint) callconv(apientry) void,
    glCompileShader: *const fn (GLuint) callconv(apientry) void,
    glGetShaderiv: *const fn (GLuint, GLenum, *GLint) callconv(apientry) void,
    glGetShaderInfoLog: *const fn (GLuint, GLsizei, ?*GLsizei, [*]u8) callconv(apientry) void,
    glDeleteShader: *const fn (GLuint) callconv(apientry) void,
    glCreateProgram: *const fn () callconv(apientry) GLuint,
    glAttachShader: *const fn (GLuint, GLuint) callconv(apientry) void,
    glBindAttribLocation: *const fn (GLuint, GLuint, [*:0]const u8) callconv(apientry) void,
    glLinkProgram: *const fn (GLuint) callconv(apientry) void,
    glGetProgramiv: *const fn (GLuint, GLenum, *GLint) callconv(apientry) void,
    glGetProgramInfoLog: *const fn (GLuint, GLsizei, ?*GLsizei, [*]u8) callconv(apientry) void,
    glDeleteProgram: *const fn (GLuint) callconv(apientry) void,
    glUseProgram: *const fn (GLuint) callconv(apientry) void,
    glGetUniformLocation: *const fn (GLuint, [*:0]const u8) callconv(apientry) GLint,
    glUniform1i: *const fn (GLint, GLint) callconv(apientry) void,
    glUniform2f: *const fn (GLint, f32, f32) callconv(apientry) void,
    glGenVertexArrays: *const fn (GLsizei, [*]GLuint) callconv(apientry) void,
    glDeleteVertexArrays: *const fn (GLsizei, [*]const GLuint) callconv(apientry) void,
    glBindVertexArray: *const fn (GLuint) callconv(apientry) void,
    glGenBuffers: *const fn (GLsizei, [*]GLuint) callconv(apientry) void,
    glDeleteBuffers: *const fn (GLsizei, [*]const GLuint) callconv(apientry) void,
    glBindBuffer: *const fn (GLenum, GLuint) callconv(apientry) void,
    glBufferData: *const fn (GLenum, isize, ?*const anyopaque, GLenum) callconv(apientry) void,
    glEnableVertexAttribArray: *const fn (GLuint) callconv(apientry) void,
    glVertexAttribPointer: *const fn (GLuint, GLint, GLenum, u8, GLsizei, ?*const anyopaque) callconv(apientry) void,
    glGenTextures: *const fn (GLsizei, [*]GLuint) callconv(apientry) void,
    glDeleteTextures: *const fn (GLsizei, [*]const GLuint) callconv(apientry) void,
    glBindTexture: *const fn (GLenum, GLuint) callconv(apientry) void,
    glActiveTexture: *const fn (GLenum) callconv(apientry) void,
    glTexImage2D: *const fn (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, ?*const anyopaque) callconv(apientry) void,
    glTexSubImage2D: *const fn (GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, ?*const anyopaque) callconv(apientry) void,
    glTexParameteri: *const fn (GLenum, GLenum, GLint) callconv(apientry) void,
    glPixelStorei: *const fn (GLenum, GLint) callconv(apientry) void,
    glViewport: *const fn (GLint, GLint, GLsizei, GLsizei) callconv(apientry) void,
    glClearColor: *const fn (f32, f32, f32, f32) callconv(apientry) void,
    glClear: *const fn (u32) callconv(apientry) void,
    glEnable: *const fn (GLenum) callconv(apientry) void,
    glDisable: *const fn (GLenum) callconv(apientry) void,
    glBlendFunc: *const fn (GLenum, GLenum) callconv(apientry) void,
    glDrawElements: *const fn (GLenum, GLsizei, GLenum, ?*const anyopaque) callconv(apientry) void,
    glReadPixels: *const fn (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, ?*anyopaque) callconv(apientry) void,
    glBindFramebuffer: *const fn (GLenum, GLuint) callconv(apientry) void,
    glGenFramebuffers: *const fn (GLsizei, [*]GLuint) callconv(apientry) void,
    glDeleteFramebuffers: *const fn (GLsizei, [*]const GLuint) callconv(apientry) void,
    glFramebufferTexture2D: *const fn (GLenum, GLenum, GLenum, GLuint, GLint) callconv(apientry) void,
    glCheckFramebufferStatus: *const fn (GLenum) callconv(apientry) GLenum,
    glBlitFramebuffer: *const fn (GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, u32, GLenum) callconv(apientry) void,
    glScissor: *const fn (GLint, GLint, GLsizei, GLsizei) callconv(apientry) void,
    // For 3D scenes.
    glUniform4fv: *const fn (GLint, GLsizei, [*]const f32) callconv(apientry) void,
    glUniformMatrix4fv: *const fn (GLint, GLsizei, u8, [*]const f32) callconv(apientry) void,
    glFrontFace: *const fn (GLenum) callconv(apientry) void,
    glGenRenderbuffers: *const fn (GLsizei, [*]GLuint) callconv(apientry) void,
    glDeleteRenderbuffers: *const fn (GLsizei, [*]const GLuint) callconv(apientry) void,
    glBindRenderbuffer: *const fn (GLenum, GLuint) callconv(apientry) void,
    glRenderbufferStorageMultisample: *const fn (GLenum, GLsizei, GLenum, GLsizei, GLsizei) callconv(apientry) void,
    glFramebufferRenderbuffer: *const fn (GLenum, GLenum, GLenum, GLuint) callconv(apientry) void,

    /// Loads the functions with `getProc` (null for a missing function).
    pub fn load(ctx: anytype, comptime getProc: fn (@TypeOf(ctx), [*:0]const u8) ?*const anyopaque) error{MissingGlFunction}!Functions {
        var f: Functions = undefined;
        inline for (@typeInfo(Functions).@"struct".fields) |field| {
            const p = getProc(ctx, field.name) orelse {
                log.info("OpenGL function {s} not found", .{field.name});
                return error.MissingGlFunction;
            };
            @field(f, field.name) = @ptrCast(@alignCast(p));
        }
        return f;
    }
};

pub const Error = error{ MissingGlFunction, ShaderFailed } || Allocator.Error;

/// Draws windows into the current OpenGL framebuffer.
pub const Renderer = struct {
    gpa: Allocator,
    gl: Functions,
    batcher: batch.Batcher,
    program: GLuint = 0,
    vao: GLuint = 0,
    buffers: [2]GLuint = .{ 0, 0 },
    atlas: GLuint = 0,
    gradients: GLuint = 0,
    /// A transparent pixel, bound when no image is.
    blank: GLuint = 0,
    u_size: GLint = -1,
    images: std.ArrayList(ImageTexture) = .empty,
    frame_number: u64 = 0,
    /// The framebuffer drawn into (0: the window's).
    framebuffer: GLuint = 0,
    /// Frames are drawn into this texture (it keeps the last frame, so
    /// partial frames draw only what changed), then copied to
    /// `framebuffer`.
    target: GLuint = 0,
    target_fbo: GLuint = 0,
    target_size: [2]u32 = .{ 0, 0 },
    /// The target holds a complete frame.
    target_valid: bool = false,
    /// 3D: the program and its uniforms, its vertex array; meshes' buffers
    /// and scenes' textures, kept while used.
    program_3d: GLuint = 0,
    vao_3d: GLuint = 0,
    u3d: Uniforms3d = .{},
    meshes: std.ArrayList(MeshBuffers) = .empty,
    scenes: std.ArrayList(SceneTexture) = .empty,

    const ImageTexture = struct { image: core.Image, texture: GLuint, used: u64 };
    const Uniforms3d = struct {
        u_world: GLint = -1,
        u_normal: GLint = -1,
        u_view_proj: GLint = -1,
        u_base: GLint = -1,
        u_params: GLint = -1,
        u_eye: GLint = -1,
        u_ambient: GLint = -1,
        u_light_count: GLint = -1,
        u_lights: GLint = -1,
        u_texture: GLint = -1,
    };
    const MeshBuffers = struct { vertices_ptr: usize, len: usize, index_ptr: usize, buffers: [2]GLuint, count: usize, used: u64 };
    const SceneTexture = struct {
        key: u64,
        width: u32,
        height: u32,
        /// Multisampled color and depth, drawn into through `fbo`;
        /// resolved into `texture` through `resolve_fbo`.
        color: GLuint,
        depth: GLuint,
        fbo: GLuint,
        texture: GLuint,
        resolve_fbo: GLuint,
        used: u64,
    };
    const samples_3d = 4;
    /// Image textures unused for this many frames are deleted.
    const keep_frames = 120;
    /// A cached image superseded by a newer version (see `Image.supersedes`):
    /// evicted at the next opportunity.
    const stale = std.math.maxInt(u64);

    /// Creates the GPU resources. The context must be current.
    pub fn init(gpa: Allocator, gl: Functions) Error!Renderer {
        var r: Renderer = .{ .gpa = gpa, .gl = gl, .batcher = try .init(gpa) };
        errdefer r.batcher.deinit();
        const version = if (gl.glGetString(VERSION)) |v| std.mem.span(v) else "";
        const es = std.mem.startsWith(u8, version, "OpenGL ES");
        const header = if (es) "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n" else "#version 330 core\n";
        r.program = try r.compileProgram(header);
        errdefer gl.glDeleteProgram(r.program);
        gl.glUseProgram(r.program);
        r.u_size = gl.glGetUniformLocation(r.program, "u_size");
        gl.glUniform1i(gl.glGetUniformLocation(r.program, "u_atlas"), 0);
        gl.glUniform1i(gl.glGetUniformLocation(r.program, "u_gradients"), 1);
        gl.glUniform1i(gl.glGetUniformLocation(r.program, "u_image"), 2);

        gl.glGenVertexArrays(1, @ptrCast(&r.vao));
        gl.glBindVertexArray(r.vao);
        gl.glGenBuffers(2, &r.buffers);
        gl.glBindBuffer(ARRAY_BUFFER, r.buffers[0]);
        gl.glBindBuffer(ELEMENT_ARRAY_BUFFER, r.buffers[1]);
        const V = batch.Vertex;
        const attributes = [_]struct { u32, u32 }{
            .{ 2, @offsetOf(V, "pos") },
            .{ 2, @offsetOf(V, "uv") },
            .{ 4, @offsetOf(V, "rect") },
            .{ 4, @offsetOf(V, "shape") },
            .{ 4, @offsetOf(V, "clip") },
            .{ 4, @offsetOf(V, "color") },
            .{ 4, @offsetOf(V, "paint") },
            .{ 2, @offsetOf(V, "local") },
        };
        for (attributes, 0..) |a, i| {
            gl.glEnableVertexAttribArray(@intCast(i));
            gl.glVertexAttribPointer(@intCast(i), @intCast(a[0]), FLOAT, 0, @sizeOf(V), @ptrFromInt(a[1]));
        }

        gl.glPixelStorei(UNPACK_ALIGNMENT, 1);
        r.atlas = r.texture(R8, RED, batch.atlas_size, batch.atlas_size, null, false);
        r.gradients = r.texture(RGBA8, RGBA, batch.gradient_width, batch.gradient_rows, null, true);
        r.blank = r.texture(RGBA8, RGBA, 1, 1, &[4]u8{ 0, 0, 0, 0 }, false);
        r.init3d(header) catch |err| log.info("no 3D on the GPU ({t}): scenes drawn on the CPU", .{err});
        r.batcher.gpu_scenes = r.program_3d != 0;
        return r;
    }

    fn init3d(r: *Renderer, header: []const u8) Error!void {
        const gl = r.gl;
        const vs = try r.compileShader(VERTEX_SHADER, header, shader.vertex_3d);
        defer gl.glDeleteShader(vs);
        const fs = try r.compileShader(FRAGMENT_SHADER, header, shader.fragment_3d);
        defer gl.glDeleteShader(fs);
        const p = gl.glCreateProgram();
        gl.glAttachShader(p, vs);
        gl.glAttachShader(p, fs);
        for ([_][*:0]const u8{ "a_position", "a_normal", "a_texcoord" }, 0..) |name, i| gl.glBindAttribLocation(p, @intCast(i), name);
        gl.glLinkProgram(p);
        var ok: GLint = 0;
        gl.glGetProgramiv(p, LINK_STATUS, &ok);
        if (ok == 0) {
            gl.glDeleteProgram(p);
            return error.ShaderFailed;
        }
        r.program_3d = p;
        inline for (@typeInfo(Uniforms3d).@"struct".fields) |f| @field(r.u3d, f.name) = gl.glGetUniformLocation(p, f.name ++ "");
        gl.glUseProgram(p);
        gl.glUniform1i(r.u3d.u_texture, 0);
        gl.glUseProgram(r.program);
        gl.glGenVertexArrays(1, @ptrCast(&r.vao_3d));
        // The 2D program's vertex array stays the one bound.
        gl.glBindVertexArray(r.vao);
    }

    pub fn deinit(r: *Renderer) void {
        const gl = r.gl;
        for (r.images.items) |it| gl.glDeleteTextures(1, @ptrCast(&it.texture));
        r.images.deinit(r.gpa);
        for (r.meshes.items) |m| gl.glDeleteBuffers(2, &m.buffers);
        r.meshes.deinit(r.gpa);
        for (r.scenes.items) |*sc| r.deleteScene(sc);
        r.scenes.deinit(r.gpa);
        if (r.vao_3d != 0) gl.glDeleteVertexArrays(1, @ptrCast(&r.vao_3d));
        if (r.program_3d != 0) gl.glDeleteProgram(r.program_3d);
        const textures = [_]GLuint{ r.atlas, r.gradients, r.blank, r.target };
        gl.glDeleteTextures(textures.len, &textures);
        if (r.target_fbo != 0) gl.glDeleteFramebuffers(1, @ptrCast(&r.target_fbo));
        gl.glDeleteBuffers(2, &r.buffers);
        gl.glDeleteVertexArrays(1, @ptrCast(&r.vao));
        gl.glDeleteProgram(r.program);
        r.batcher.deinit();
    }

    pub fn setScaleFactor(r: *Renderer, scale: f32) void {
        r.batcher.scale_factor = scale;
    }

    /// Draws the window into the framebuffer, `width` x `height` physical
    /// pixels: everything, or in `.partial` mode only what changed since
    /// the last frame (the whole frame is still copied to the framebuffer,
    /// whose contents need not survive a buffer swap). Returns the area
    /// redrawn, in pixels: when empty, nothing was drawn (no need to swap
    /// buffers).
    pub fn renderWindow(r: *Renderer, window: *core.Window, width: u32, height: u32, mode: core.RenderMode) Allocator.Error!core.Region {
        // Without the last frame (first frame, new size): all of it.
        const full = mode == .full or !r.target_valid or r.target_size[0] != width or r.target_size[1] != height;
        const frame = try r.batcher.build(window, width, height, if (full) .full else .partial);
        if (frame.region.isEmpty()) return .{};
        try r.draw(&frame);
        return frame.region;
    }

    /// The texture frames are drawn into, `width` x `height`.
    fn ensureTarget(r: *Renderer, width: u32, height: u32) void {
        if (r.target_fbo != 0 and r.target_size[0] == width and r.target_size[1] == height) return;
        const gl = r.gl;
        if (r.target != 0) gl.glDeleteTextures(1, @ptrCast(&r.target));
        r.target = r.texture(RGBA8, RGBA, width, height, null, false);
        if (r.target_fbo == 0) gl.glGenFramebuffers(1, @ptrCast(&r.target_fbo));
        gl.glBindFramebuffer(FRAMEBUFFER, r.target_fbo);
        gl.glFramebufferTexture2D(FRAMEBUFFER, COLOR_ATTACHMENT0, TEXTURE_2D, r.target, 0);
        if (gl.glCheckFramebufferStatus(FRAMEBUFFER) != FRAMEBUFFER_COMPLETE) log.err("the frame texture cannot be drawn into", .{});
        r.target_size = .{ width, height };
        r.target_valid = false;
    }

    /// Draws a frame: into the frame texture (all of it, or over the
    /// previous frame for a partial one), then copied to `framebuffer`.
    pub fn draw(r: *Renderer, frame: *const batch.Frame) Allocator.Error!void {
        const gl = r.gl;
        r.frame_number += 1;
        // 3D scenes first, each into its texture (if it changed).
        var scene_textures: [16]GLuint = @splat(0);
        for (frame.scenes) |sd| {
            if (sd.image >= scene_textures.len) continue;
            scene_textures[sd.image] = try r.drawScene(sd);
        }
        r.ensureTarget(frame.width, frame.height);
        gl.glBindFramebuffer(FRAMEBUFFER, r.target_fbo);
        gl.glViewport(0, 0, @intCast(frame.width), @intCast(frame.height));
        gl.glClearColor(0, 0, 0, 0);
        if (frame.full or !r.target_valid) {
            gl.glDisable(SCISSOR_TEST);
            gl.glClear(COLOR_BUFFER_BIT);
        } else {
            // Only the area being redrawn (OpenGL's y goes up).
            gl.glEnable(SCISSOR_TEST);
            for (frame.region.slice()) |rect| {
                const y: i32 = @as(i32, @intCast(frame.height)) - @as(i32, @intFromFloat(rect.bottom()));
                gl.glScissor(@intFromFloat(rect.x), y, @intFromFloat(rect.width), @intFromFloat(rect.height));
                gl.glClear(COLOR_BUFFER_BIT);
            }
        }
        r.target_valid = true;
        gl.glDisable(DEPTH_TEST);
        gl.glDisable(CULL_FACE);
        gl.glDisable(SCISSOR_TEST);
        gl.glEnable(BLEND);
        gl.glBlendFunc(ONE, ONE_MINUS_SRC_ALPHA);
        gl.glUseProgram(r.program);
        gl.glUniform2f(r.u_size, @floatFromInt(frame.width), @floatFromInt(frame.height));
        gl.glPixelStorei(UNPACK_ALIGNMENT, 1);

        // Textures: what changed in the atlas, the gradients used.
        gl.glActiveTexture(TEXTURE0);
        gl.glBindTexture(TEXTURE_2D, r.atlas);
        const d = frame.atlas_dirty;
        if (d[1] > d[0]) gl.glTexSubImage2D(TEXTURE_2D, 0, 0, @intCast(d[0]), batch.atlas_size, @intCast(d[1] - d[0]), RED, UNSIGNED_BYTE, frame.atlas[d[0] * batch.atlas_size ..].ptr);
        gl.glActiveTexture(TEXTURE0 + 1);
        gl.glBindTexture(TEXTURE_2D, r.gradients);
        if (frame.gradient_count > 0) gl.glTexSubImage2D(TEXTURE_2D, 0, 0, 0, batch.gradient_width, @intCast(frame.gradient_count), RGBA, UNSIGNED_BYTE, frame.gradients.ptr);

        gl.glBindVertexArray(r.vao);
        gl.glBindBuffer(ARRAY_BUFFER, r.buffers[0]);
        gl.glBufferData(ARRAY_BUFFER, @intCast(frame.vertices.len * @sizeOf(batch.Vertex)), frame.vertices.ptr, STREAM_DRAW);
        gl.glBindBuffer(ELEMENT_ARRAY_BUFFER, r.buffers[1]);
        gl.glBufferData(ELEMENT_ARRAY_BUFFER, @intCast(frame.indices.len * 4), frame.indices.ptr, STREAM_DRAW);

        gl.glActiveTexture(TEXTURE0 + 2);
        for (frame.draws) |dr| {
            if (dr.image) |i| {
                const scene = for (frame.scenes) |sd| {
                    if (sd.image == i) break true;
                } else false;
                // A scene not drawn (too many in a frame): nothing.
                const t = if (scene) (if (i < scene_textures.len and scene_textures[i] != 0) scene_textures[i] else r.blank) else try r.imageTexture(frame.images[i]);
                gl.glBindTexture(TEXTURE_2D, t);
                const filter: GLint = if (dr.smooth) LINEAR else NEAREST;
                gl.glTexParameteri(TEXTURE_2D, TEXTURE_MIN_FILTER, filter);
                gl.glTexParameteri(TEXTURE_2D, TEXTURE_MAG_FILTER, filter);
            } else gl.glBindTexture(TEXTURE_2D, r.blank);
            gl.glDrawElements(TRIANGLES, @intCast(dr.count), UNSIGNED_INT, @ptrFromInt(@as(usize, dr.first) * 4));
        }
        r.evictImages();
        r.evict3d();

        // The whole frame to the framebuffer.
        const w: i32 = @intCast(frame.width);
        const h: i32 = @intCast(frame.height);
        gl.glBindFramebuffer(READ_FRAMEBUFFER, r.target_fbo);
        gl.glBindFramebuffer(DRAW_FRAMEBUFFER, r.framebuffer);
        gl.glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, COLOR_BUFFER_BIT, NEAREST);
        gl.glBindFramebuffer(FRAMEBUFFER, r.framebuffer);
    }

    /// Reads the framebuffer's pixels (top row first), for tests.
    pub fn readPixels(r: *Renderer, width: u32, height: u32, out: []core.Rgba8) void {
        const gl = r.gl;
        gl.glPixelStorei(PACK_ALIGNMENT, 1);
        gl.glReadPixels(0, 0, @intCast(width), @intCast(height), RGBA, UNSIGNED_BYTE, out.ptr);
        // OpenGL's rows go bottom up.
        for (0..height / 2) |y| {
            const a = out[y * width ..][0..width];
            const b = out[(height - 1 - y) * width ..][0..width];
            for (a, b) |*p, *q| std.mem.swap(core.Rgba8, p, q);
        }
    }

    fn texture(r: *Renderer, internal: GLenum, format: GLenum, width: u32, height: u32, data: ?*const anyopaque, smooth: bool) GLuint {
        const gl = r.gl;
        var t: GLuint = 0;
        gl.glGenTextures(1, @ptrCast(&t));
        gl.glBindTexture(TEXTURE_2D, t);
        const filter: GLint = if (smooth) LINEAR else NEAREST;
        gl.glTexParameteri(TEXTURE_2D, TEXTURE_MIN_FILTER, filter);
        gl.glTexParameteri(TEXTURE_2D, TEXTURE_MAG_FILTER, filter);
        gl.glTexParameteri(TEXTURE_2D, TEXTURE_WRAP_S, CLAMP_TO_EDGE);
        gl.glTexParameteri(TEXTURE_2D, TEXTURE_WRAP_T, CLAMP_TO_EDGE);
        gl.glTexImage2D(TEXTURE_2D, 0, @intCast(internal), @intCast(width), @intCast(height), 0, format, UNSIGNED_BYTE, data);
        return t;
    }

    /// The image's texture, uploaded the first time it is drawn.
    fn imageTexture(r: *Renderer, img: core.Image) Allocator.Error!GLuint {
        for (r.images.items) |*it| if (it.image.eql(img)) {
            it.used = r.frame_number;
            return it.texture;
        };
        try r.images.ensureUnusedCapacity(r.gpa, 1);
        const t = r.texture(RGBA8, RGBA, img.width, img.height, img.pixels.ptr, true);
        markSuperseded(r.images.items, img);
        r.images.appendAssumeCapacity(.{ .image = img, .texture = t, .used = r.frame_number });
        return t;
    }

    // ---- 3D ----

    /// The texture `sd`'s scene is drawn in: drawn now if the scene or its
    /// size changed.
    fn drawScene(r: *Renderer, sd: batch.SceneDraw) Allocator.Error!GLuint {
        const gl = r.gl;
        for (r.scenes.items) |*it| if (it.key == sd.source.key and it.width == sd.width and it.height == sd.height) {
            it.used = r.frame_number;
            return it.texture;
        };
        const entry = for (r.scenes.items) |*it| {
            if (it.width == sd.width and it.height == sd.height and it.used != r.frame_number) break it;
        } else blk: {
            try r.scenes.ensureUnusedCapacity(r.gpa, 1);
            var sc: SceneTexture = .{ .key = 0, .width = sd.width, .height = sd.height, .color = 0, .depth = 0, .fbo = 0, .texture = 0, .resolve_fbo = 0, .used = 0 };
            const w: GLsizei = @intCast(sd.width);
            const h: GLsizei = @intCast(sd.height);
            gl.glGenRenderbuffers(1, @ptrCast(&sc.color));
            gl.glBindRenderbuffer(RENDERBUFFER, sc.color);
            gl.glRenderbufferStorageMultisample(RENDERBUFFER, samples_3d, RGBA8, w, h);
            gl.glGenRenderbuffers(1, @ptrCast(&sc.depth));
            gl.glBindRenderbuffer(RENDERBUFFER, sc.depth);
            gl.glRenderbufferStorageMultisample(RENDERBUFFER, samples_3d, DEPTH_COMPONENT24, w, h);
            gl.glGenFramebuffers(1, @ptrCast(&sc.fbo));
            gl.glBindFramebuffer(FRAMEBUFFER, sc.fbo);
            gl.glFramebufferRenderbuffer(FRAMEBUFFER, COLOR_ATTACHMENT0, RENDERBUFFER, sc.color);
            gl.glFramebufferRenderbuffer(FRAMEBUFFER, DEPTH_ATTACHMENT, RENDERBUFFER, sc.depth);
            if (gl.glCheckFramebufferStatus(FRAMEBUFFER) != FRAMEBUFFER_COMPLETE) log.err("a 3D scene cannot be drawn into", .{});
            sc.texture = r.texture(RGBA8, RGBA, sd.width, sd.height, null, false);
            gl.glGenFramebuffers(1, @ptrCast(&sc.resolve_fbo));
            gl.glBindFramebuffer(FRAMEBUFFER, sc.resolve_fbo);
            gl.glFramebufferTexture2D(FRAMEBUFFER, COLOR_ATTACHMENT0, TEXTURE_2D, sc.texture, 0);
            r.scenes.appendAssumeCapacity(sc);
            break :blk &r.scenes.items[r.scenes.items.len - 1];
        };
        entry.key = sd.source.key;
        entry.used = r.frame_number;
        const scene = &sd.source.scene;
        const w: GLint = @intCast(sd.width);
        const h: GLint = @intCast(sd.height);

        gl.glBindFramebuffer(FRAMEBUFFER, entry.fbo);
        gl.glViewport(0, 0, w, h);
        gl.glDisable(SCISSOR_TEST);
        const bg = scene.background.premultiplied();
        gl.glClearColor(@as(f32, @floatFromInt(bg.r)) / 255, @as(f32, @floatFromInt(bg.g)) / 255, @as(f32, @floatFromInt(bg.b)) / 255, @as(f32, @floatFromInt(bg.a)) / 255);
        gl.glClear(COLOR_BUFFER_BIT | DEPTH_BUFFER_BIT);
        gl.glEnable(DEPTH_TEST);
        gl.glEnable(BLEND);
        gl.glBlendFunc(ONE, ONE_MINUS_SRC_ALPHA);
        // Drawn upside down: counter-clockwise from outside turns clockwise.
        gl.glFrontFace(CW);
        gl.glUseProgram(r.program_3d);
        var f3 = core.raster3d.gpuFrame(scene, sd.width, sd.height);
        // Upside down (OpenGL's rows go bottom up), and depth from -1 to 1:
        // y negated; z' = 2 z - w.
        for (0..4) |col| {
            f3.view_proj[col * 4 + 1] = -f3.view_proj[col * 4 + 1];
            f3.view_proj[col * 4 + 2] = 2 * f3.view_proj[col * 4 + 2] - f3.view_proj[col * 4 + 3];
        }
        gl.glUniformMatrix4fv(r.u3d.u_view_proj, 1, 0, &f3.view_proj);
        gl.glUniform4fv(r.u3d.u_eye, 1, &f3.eye);
        gl.glUniform4fv(r.u3d.u_ambient, 1, &f3.ambient);
        gl.glUniform1i(r.u3d.u_light_count, @intCast(f3.counts[0]));
        if (f3.counts[0] > 0) gl.glUniform4fv(r.u3d.u_lights, @intCast(f3.counts[0] * 2), @ptrCast(&f3.lights));
        gl.glBindVertexArray(r.vao_3d);
        gl.glActiveTexture(TEXTURE0);
        for (scene.instances) |*inst| {
            const mb = try r.meshBuffers(inst.mesh);
            if (mb.count == 0) continue;
            if (inst.mesh.two_sided) gl.glDisable(CULL_FACE) else gl.glEnable(CULL_FACE);
            const u = core.raster3d.gpuInstance(inst);
            gl.glUniformMatrix4fv(r.u3d.u_world, 1, 0, &u.world);
            gl.glUniformMatrix4fv(r.u3d.u_normal, 1, 0, &u.normal);
            gl.glUniform4fv(r.u3d.u_base, 1, &u.base);
            gl.glUniform4fv(r.u3d.u_params, 1, &u.params);
            const tex = if (inst.material.texture) |t| try r.imageTexture(t) else r.blank;
            gl.glBindTexture(TEXTURE_2D, tex);
            gl.glTexParameteri(TEXTURE_2D, TEXTURE_WRAP_S, REPEAT);
            gl.glTexParameteri(TEXTURE_2D, TEXTURE_WRAP_T, REPEAT);
            gl.glTexParameteri(TEXTURE_2D, TEXTURE_MIN_FILTER, LINEAR);
            gl.glTexParameteri(TEXTURE_2D, TEXTURE_MAG_FILTER, LINEAR);
            gl.glBindBuffer(ARRAY_BUFFER, mb.buffers[0]);
            gl.glBindBuffer(ELEMENT_ARRAY_BUFFER, mb.buffers[1]);
            for ([_]struct { u32, u32 }{ .{ 3, 0 }, .{ 3, 12 }, .{ 2, 24 } }, 0..) |a, i| {
                gl.glEnableVertexAttribArray(@intCast(i));
                gl.glVertexAttribPointer(@intCast(i), @intCast(a[0]), FLOAT, 0, 32, @ptrFromInt(a[1]));
            }
            gl.glDrawElements(TRIANGLES, @intCast(mb.count), UNSIGNED_INT, null);
            // Images are drawn clamped elsewhere.
            gl.glTexParameteri(TEXTURE_2D, TEXTURE_WRAP_S, CLAMP_TO_EDGE);
            gl.glTexParameteri(TEXTURE_2D, TEXTURE_WRAP_T, CLAMP_TO_EDGE);
        }
        gl.glFrontFace(CCW);
        gl.glDisable(CULL_FACE);
        gl.glDisable(DEPTH_TEST);
        // The samples resolved into the texture.
        gl.glBindFramebuffer(READ_FRAMEBUFFER, entry.fbo);
        gl.glBindFramebuffer(DRAW_FRAMEBUFFER, entry.resolve_fbo);
        gl.glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, COLOR_BUFFER_BIT, NEAREST);
        gl.glBindVertexArray(r.vao);
        return entry.texture;
    }

    fn deleteScene(r: *Renderer, sc: *SceneTexture) void {
        const gl = r.gl;
        const rbs = [_]GLuint{ sc.color, sc.depth };
        gl.glDeleteRenderbuffers(2, &rbs);
        const fbos = [_]GLuint{ sc.fbo, sc.resolve_fbo };
        gl.glDeleteFramebuffers(2, &fbos);
        gl.glDeleteTextures(1, @ptrCast(&sc.texture));
    }

    /// `mesh`'s vertices (8 floats each: position, normal, texture
    /// coordinates) and indices in buffers, made the first time.
    fn meshBuffers(r: *Renderer, mesh: core.raster3d.Mesh) Allocator.Error!*MeshBuffers {
        const gl = r.gl;
        for (r.meshes.items) |*m| if (m.vertices_ptr == @intFromPtr(mesh.vertices.ptr) and m.len == mesh.vertices.len and m.index_ptr == @intFromPtr(mesh.indices.ptr)) {
            m.used = r.frame_number;
            return m;
        };
        try r.meshes.ensureUnusedCapacity(r.gpa, 1);
        const packed_vertices = try r.gpa.alloc([8]f32, mesh.vertices.len);
        defer r.gpa.free(packed_vertices);
        for (mesh.vertices, 0..) |v, i| packed_vertices[i] = .{ v.position[0], v.position[1], v.position[2], v.normal[0], v.normal[1], v.normal[2], v.uv[0], v.uv[1] };
        var mb: MeshBuffers = .{ .vertices_ptr = @intFromPtr(mesh.vertices.ptr), .len = mesh.vertices.len, .index_ptr = @intFromPtr(mesh.indices.ptr), .buffers = .{ 0, 0 }, .count = mesh.indices.len - mesh.indices.len % 3, .used = r.frame_number };
        gl.glGenBuffers(2, &mb.buffers);
        gl.glBindVertexArray(r.vao_3d);
        gl.glBindBuffer(ARRAY_BUFFER, mb.buffers[0]);
        gl.glBufferData(ARRAY_BUFFER, @intCast(packed_vertices.len * 32), packed_vertices.ptr, STATIC_DRAW);
        gl.glBindBuffer(ELEMENT_ARRAY_BUFFER, mb.buffers[1]);
        gl.glBufferData(ELEMENT_ARRAY_BUFFER, @intCast(mesh.indices.len * 4), mesh.indices.ptr, STATIC_DRAW);
        r.meshes.appendAssumeCapacity(mb);
        return &r.meshes.items[r.meshes.items.len - 1];
    }

    /// Meshes and scenes not drawn for a while are let go.
    fn evict3d(r: *Renderer) void {
        var i: usize = 0;
        while (i < r.meshes.items.len) {
            const m = r.meshes.items[i];
            if (r.frame_number - m.used > keep_frames) {
                r.gl.glDeleteBuffers(2, &m.buffers);
                _ = r.meshes.swapRemove(i);
            } else i += 1;
        }
        i = 0;
        while (i < r.scenes.items.len) {
            if (r.frame_number - r.scenes.items[i].used > keep_frames) {
                r.deleteScene(&r.scenes.items[i]);
                _ = r.scenes.swapRemove(i);
            } else i += 1;
        }
    }

    fn evictImages(r: *Renderer) void {
        var i: usize = 0;
        while (i < r.images.items.len) {
            const it = r.images.items[i];
            if (it.used == stale or r.frame_number - it.used > keep_frames) {
                r.gl.glDeleteTextures(1, @ptrCast(&it.texture));
                _ = r.images.swapRemove(i);
            } else i += 1;
        }
    }

    fn compileProgram(r: *Renderer, header: []const u8) Error!GLuint {
        const gl = r.gl;
        const vs = try r.compileShader(VERTEX_SHADER, header, shader.vertex);
        defer gl.glDeleteShader(vs);
        const fs = try r.compileShader(FRAGMENT_SHADER, header, shader.fragment);
        defer gl.glDeleteShader(fs);
        const p = gl.glCreateProgram();
        gl.glAttachShader(p, vs);
        gl.glAttachShader(p, fs);
        for ([_][*:0]const u8{ "a_pos", "a_uv", "a_rect", "a_shape", "a_clip", "a_color", "a_paint", "a_local" }, 0..) |name, i| gl.glBindAttribLocation(p, @intCast(i), name);
        gl.glLinkProgram(p);
        var ok: GLint = 0;
        gl.glGetProgramiv(p, LINK_STATUS, &ok);
        if (ok == 0) {
            var buf: [2048]u8 = undefined;
            var len: GLsizei = 0;
            gl.glGetProgramInfoLog(p, buf.len, &len, &buf);
            log.err("linking the shaders failed: {s}", .{buf[0..@intCast(len)]});
            gl.glDeleteProgram(p);
            return error.ShaderFailed;
        }
        return p;
    }

    fn compileShader(r: *Renderer, kind: GLenum, header: []const u8, source: []const u8) Error!GLuint {
        const gl = r.gl;
        const s = gl.glCreateShader(kind);
        const parts = [_][*]const u8{ header.ptr, source.ptr };
        const lengths = [_]GLint{ @intCast(header.len), @intCast(source.len) };
        gl.glShaderSource(s, 2, &parts, &lengths);
        gl.glCompileShader(s);
        var ok: GLint = 0;
        gl.glGetShaderiv(s, COMPILE_STATUS, &ok);
        if (ok == 0) {
            var buf: [2048]u8 = undefined;
            var len: GLsizei = 0;
            gl.glGetShaderInfoLog(s, buf.len, &len, &buf);
            log.err("compiling a shader failed: {s}", .{buf[0..@intCast(len)]});
            gl.glDeleteShader(s);
            return error.ShaderFailed;
        }
        return s;
    }
};

/// Marks the cached copies of older versions of `img`'s pixels stale.
fn markSuperseded(items: anytype, img: core.Image) void {
    for (items) |*it| if (img.supersedes(it.image)) {
        it.used = std.math.maxInt(u64); // Renderer.stale
    };
}
