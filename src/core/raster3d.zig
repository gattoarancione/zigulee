// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! A small 3D renderer on the CPU, for `View3D`: triangle meshes seen by a
//! perspective camera, lit by directional and point lights with a
//! metallic-roughness material (as glTF's), drawn into an image with a
//! depth buffer. Pixels are shaded one by one (normals interpolated, the
//! texture sampled perspective-correctly), so it suits small scenes.
//!
//! Coordinates: y up, the camera looking along -z (as OpenGL's and Qt
//! Quick 3D's). Turns are in degrees: `yaw` about y, then `pitch` about x,
//! then `roll` about z, each counter-clockwise looking down its axis.

const std = @import("std");
const Allocator = std.mem.Allocator;
const graphics = @import("graphics.zig");
const Color = graphics.Color;
const Rgba8 = graphics.Rgba8;
const image = @import("image.zig");

pub const Vec3 = @Vector(3, f32);

fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn normalize(v: Vec3) Vec3 {
    const l = @sqrt(dot(v, v));
    return if (l > 0) v / @as(Vec3, @splat(l)) else v;
}

fn splat(f: f32) Vec3 {
    return @splat(f);
}

/// A transform of points (row-major; the last row is 0 0 0 1).
pub const Mat = struct {
    m: [3][4]f32 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 } },

    pub const identity: Mat = .{};

    pub fn translation(t: Vec3) Mat {
        return .{ .m = .{ .{ 1, 0, 0, t[0] }, .{ 0, 1, 0, t[1] }, .{ 0, 0, 1, t[2] } } };
    }

    pub fn scaling(s: Vec3) Mat {
        return .{ .m = .{ .{ s[0], 0, 0, 0 }, .{ 0, s[1], 0, 0 }, .{ 0, 0, s[2], 0 } } };
    }

    /// `yaw` about y, then `pitch` about x, then `roll` about z (degrees):
    /// R = Ry Rx Rz.
    pub fn rotation(pitch: f32, yaw: f32, roll: f32) Mat {
        const r = std.math.pi / 180.0;
        const cx = @cos(pitch * r);
        const sx = @sin(pitch * r);
        const cy = @cos(yaw * r);
        const sy = @sin(yaw * r);
        const cz = @cos(roll * r);
        const sz = @sin(roll * r);
        const ry: Mat = .{ .m = .{ .{ cy, 0, sy, 0 }, .{ 0, 1, 0, 0 }, .{ -sy, 0, cy, 0 } } };
        const rx: Mat = .{ .m = .{ .{ 1, 0, 0, 0 }, .{ 0, cx, -sx, 0 }, .{ 0, sx, cx, 0 } } };
        const rz: Mat = .{ .m = .{ .{ cz, -sz, 0, 0 }, .{ sz, cz, 0, 0 }, .{ 0, 0, 1, 0 } } };
        return ry.mul(rx).mul(rz);
    }

    /// Placed at `position`, turned, and sized by `size`.
    pub fn place(position: Vec3, pitch: f32, yaw: f32, roll: f32, size: Vec3) Mat {
        return translation(position).mul(rotation(pitch, yaw, roll)).mul(scaling(size));
    }

    /// `n` applied first, then `self`.
    pub fn mul(self: Mat, n: Mat) Mat {
        var out: Mat = undefined;
        for (0..3) |i| {
            for (0..4) |j| {
                var v: f32 = if (j == 3) self.m[i][3] else 0;
                for (0..3) |k| v += self.m[i][k] * n.m[k][j];
                out.m[i][j] = v;
            }
        }
        return out;
    }

    pub fn point(self: Mat, p: Vec3) Vec3 {
        return .{
            self.m[0][0] * p[0] + self.m[0][1] * p[1] + self.m[0][2] * p[2] + self.m[0][3],
            self.m[1][0] * p[0] + self.m[1][1] * p[1] + self.m[1][2] * p[2] + self.m[1][3],
            self.m[2][0] * p[0] + self.m[2][1] * p[1] + self.m[2][2] * p[2] + self.m[2][3],
        };
    }

    /// A direction (not moved).
    pub fn vector(self: Mat, v: Vec3) Vec3 {
        return .{
            self.m[0][0] * v[0] + self.m[0][1] * v[1] + self.m[0][2] * v[2],
            self.m[1][0] * v[0] + self.m[1][1] * v[1] + self.m[1][2] * v[2],
            self.m[2][0] * v[0] + self.m[2][1] * v[1] + self.m[2][2] * v[2],
        };
    }

    pub fn inverse(self: Mat) ?Mat {
        const a = self.m;
        const c00 = a[1][1] * a[2][2] - a[1][2] * a[2][1];
        const c01 = a[1][2] * a[2][0] - a[1][0] * a[2][2];
        const c02 = a[1][0] * a[2][1] - a[1][1] * a[2][0];
        const det = a[0][0] * c00 + a[0][1] * c01 + a[0][2] * c02;
        if (!(@abs(det) > 1e-12)) return null;
        const d = 1 / det;
        var out: Mat = .{ .m = .{
            .{ c00 * d, (a[0][2] * a[2][1] - a[0][1] * a[2][2]) * d, (a[0][1] * a[1][2] - a[0][2] * a[1][1]) * d, 0 },
            .{ c01 * d, (a[0][0] * a[2][2] - a[0][2] * a[2][0]) * d, (a[0][2] * a[1][0] - a[0][0] * a[1][2]) * d, 0 },
            .{ c02 * d, (a[0][1] * a[2][0] - a[0][0] * a[2][1]) * d, (a[0][0] * a[1][1] - a[0][1] * a[1][0]) * d, 0 },
        } };
        const t = out.vector(.{ a[0][3], a[1][3], a[2][3] });
        inline for (0..3) |i| out.m[i][3] = -t[i];
        return out;
    }

    /// For normals: the inverse transposed (its 3 x 3 part).
    pub fn normalMatrix(self: Mat) Mat {
        const inv = self.inverse() orelse return self;
        var out: Mat = .{};
        for (0..3) |i| for (0..3) |j| {
            out.m[i][j] = inv.m[j][i];
        };
        return out;
    }
};

// ---- Meshes ----

pub const Vertex = struct { position: Vec3, normal: Vec3, uv: [2]f32 };

/// Triangles (indices into `vertices`, counter-clockwise from outside).
pub const Mesh = struct {
    vertices: []const Vertex,
    indices: []const u32,
    /// Seen from inside too (a plane): no back faces culled, and their
    /// normals turned toward the viewer.
    two_sided: bool = false,
};

/// A cube of side 1, centered.
pub const cube: Mesh = blk: {
    @setEvalBranchQuota(10_000);
    // Each face: its normal, and the axes along its u and v.
    const faces = [6][3]Vec3{
        .{ .{ 0, 0, 1 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } },
        .{ .{ 0, 0, -1 }, .{ -1, 0, 0 }, .{ 0, 1, 0 } },
        .{ .{ 1, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 1, 0 } },
        .{ .{ -1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 0 } },
        .{ .{ 0, 1, 0 }, .{ 1, 0, 0 }, .{ 0, 0, -1 } },
        .{ .{ 0, -1, 0 }, .{ 1, 0, 0 }, .{ 0, 0, 1 } },
    };
    var vertices: [24]Vertex = undefined;
    var indices: [36]u32 = undefined;
    for (faces, 0..) |f, i| {
        const corners = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        for (corners, 0..) |c, k| {
            const p = f[0] * splat(0.5) + f[1] * splat(c[0] - 0.5) + f[2] * splat(c[1] - 0.5);
            vertices[i * 4 + k] = .{ .position = p, .normal = f[0], .uv = .{ c[0], 1 - c[1] } };
        }
        const b: u32 = @intCast(i * 4);
        indices[i * 6 ..][0..6].* = .{ b, b + 1, b + 2, b, b + 2, b + 3 };
    }
    const v = vertices;
    const ix = indices;
    break :blk .{ .vertices = &v, .indices = &ix };
};

/// A square of side 1 in the x-y plane, centered, facing +z.
pub const plane: Mesh = .{
    .vertices = &.{
        .{ .position = .{ -0.5, -0.5, 0 }, .normal = .{ 0, 0, 1 }, .uv = .{ 0, 1 } },
        .{ .position = .{ 0.5, -0.5, 0 }, .normal = .{ 0, 0, 1 }, .uv = .{ 1, 1 } },
        .{ .position = .{ 0.5, 0.5, 0 }, .normal = .{ 0, 0, 1 }, .uv = .{ 1, 0 } },
        .{ .position = .{ -0.5, 0.5, 0 }, .normal = .{ 0, 0, 1 }, .uv = .{ 0, 0 } },
    },
    .indices = &.{ 0, 1, 2, 0, 2, 3 },
    .two_sided = true,
};

const sphere_slices = 32;
const sphere_stacks = 16;
var sphere_vertices: [(sphere_slices + 1) * (sphere_stacks + 1)]Vertex = undefined;
var sphere_indices: [sphere_slices * sphere_stacks * 6]u32 = undefined;
var sphere_made = false;

/// A sphere of diameter 1, centered (made the first time).
pub fn sphere() Mesh {
    if (!sphere_made) {
        for (0..sphere_stacks + 1) |j| {
            const v = @as(f32, @floatFromInt(j)) / sphere_stacks;
            const theta = v * std.math.pi;
            for (0..sphere_slices + 1) |i| {
                const u = @as(f32, @floatFromInt(i)) / sphere_slices;
                const phi = u * 2 * std.math.pi;
                const n: Vec3 = .{ @sin(theta) * @sin(phi), @cos(theta), @sin(theta) * @cos(phi) };
                sphere_vertices[j * (sphere_slices + 1) + i] = .{ .position = n * splat(0.5), .normal = n, .uv = .{ u, v } };
            }
        }
        var k: usize = 0;
        for (0..sphere_stacks) |j| for (0..sphere_slices) |i| {
            const a: u32 = @intCast(j * (sphere_slices + 1) + i);
            const b = a + sphere_slices + 1;
            sphere_indices[k..][0..6].* = .{ a, b, b + 1, a, b + 1, a + 1 };
            k += 6;
        };
        sphere_made = true;
    }
    return .{ .vertices = &sphere_vertices, .indices = &sphere_indices };
}

// ---- Scenes ----

pub const Material = struct {
    /// sRGB, and its alpha (only opaque surfaces are sorted right: drawn
    /// in order, nearer ones hide farther ones).
    base_color: Color = .rgb(0xffffff),
    metallic: f32 = 0,
    roughness: f32 = 0.5,
    /// Multiplies `base_color`, sampled at the mesh's texture coordinates
    /// (repeated).
    texture: ?image.Image = null,
};

pub const Instance = struct {
    mesh: Mesh,
    /// From the mesh's coordinates to the scene's.
    world: Mat,
    material: Material = .{},
};

pub const Camera = struct {
    /// From the camera's coordinates to the scene's.
    world: Mat = .translation(.{ 0, 0, 4 }),
    /// Vertical, in degrees.
    field_of_view: f32 = 45,
};

pub const Light = union(enum) {
    /// Shining along `direction` (in the scene).
    directional: struct { direction: Vec3, color: Color = .rgb(0xffffff), brightness: f32 = 1 },
    /// From `position`, half as bright `range` away.
    point: struct { position: Vec3, color: Color = .rgb(0xffffff), brightness: f32 = 1, range: f32 = 10 },
};

pub const Scene = struct {
    camera: Camera = .{},
    instances: []const Instance = &.{},
    lights: []const Light = &.{},
    /// Lights everything evenly (sRGB), times `ambient_brightness`.
    ambient: Color = .rgb(0x333333),
    ambient_brightness: f32 = 1,
    background: Color = .rgba(0x00000000),
};

/// A scene shown as an image (`ImageStyle.scene`): GPU renderers that draw
/// 3D draw `scene` themselves; others ask for its picture, drawn here on
/// the CPU then (and kept while the scene is the same).
pub const SceneSource = struct {
    scene: Scene,
    /// What the scene shows, hashed (not its size).
    key: u64,
    ctx: *anyopaque,
    pictureFn: *const fn (*anyopaque) ?image.Image,

    /// The scene drawn on the CPU (null without memory).
    pub fn picture(s: *const SceneSource) ?image.Image {
        return s.pictureFn(s.ctx);
    }
};

/// The pixels and depths of a picture `width` x `height`.
pub const Target = struct {
    width: u32,
    height: u32,
    pixels: []Rgba8,
    /// 1 / depth: larger is nearer, 0 nothing.
    depth: []f32,
};

/// Draws `scene` into `target`.
pub fn render(scene: *const Scene, target: Target) void {
    @memset(target.pixels, scene.background.premultiplied());
    @memset(target.depth, 0);
    const view = scene.camera.world.inverse() orelse return;
    const eye = scene.camera.world.point(.{ 0, 0, 0 });
    const w: f32 = @floatFromInt(target.width);
    const h: f32 = @floatFromInt(target.height);
    // Pixels per unit at depth 1.
    const focal = h / 2 / @tan(std.math.clamp(scene.camera.field_of_view, 1, 170) * std.math.pi / 360);
    var lights: [16]ShadeLight = undefined;
    var light_count: usize = 0;
    for (scene.lights) |l| {
        if (light_count == lights.len) break;
        lights[light_count] = ShadeLight.of(l);
        light_count += 1;
    }
    const ctx: Context = .{
        .target = target,
        .view = view,
        .focal = focal,
        .cx = w / 2,
        .cy = h / 2,
        .eye = eye,
        .lights = lights[0..light_count],
        .ambient = linear(scene.ambient) * splat(@max(0, scene.ambient_brightness)),
    };
    for (scene.instances) |*inst| drawInstance(&ctx, inst);
}

const near = 0.05;

const Context = struct {
    target: Target,
    view: Mat,
    focal: f32,
    cx: f32,
    cy: f32,
    eye: Vec3,
    lights: []const ShadeLight,
    ambient: Vec3,
};

const ShadeLight = struct {
    /// Toward the light (directional), or its position.
    vec: Vec3,
    point: bool,
    radiance: Vec3,
    range: f32,

    fn of(l: Light) ShadeLight {
        return switch (l) {
            .directional => |d| .{ .vec = -normalize(d.direction), .point = false, .radiance = linear(d.color) * splat(d.brightness), .range = 0 },
            .point => |p| .{ .vec = p.position, .point = true, .radiance = linear(p.color) * splat(p.brightness), .range = @max(p.range, 1e-3) },
        };
    }
};

/// A corner as the rasterizer sees it: in the camera's coordinates, and
/// what is interpolated.
const Corner = struct {
    view: Vec3,
    world: Vec3,
    normal: Vec3,
    uv: [2]f32,

    fn lerp(a: Corner, b: Corner, t: f32) Corner {
        const s = splat(t);
        return .{
            .view = a.view + (b.view - a.view) * s,
            .world = a.world + (b.world - a.world) * s,
            .normal = a.normal + (b.normal - a.normal) * s,
            .uv = .{ a.uv[0] + (b.uv[0] - a.uv[0]) * t, a.uv[1] + (b.uv[1] - a.uv[1]) * t },
        };
    }
};

fn drawInstance(ctx: *const Context, inst: *const Instance) void {
    const nm = inst.world.normalMatrix();
    const mesh = inst.mesh;
    var i: usize = 0;
    while (i + 2 < mesh.indices.len) : (i += 3) {
        var tri: [3]Corner = undefined;
        for (0..3) |k| {
            const v = mesh.vertices[mesh.indices[i + k]];
            const world = inst.world.point(v.position);
            tri[k] = .{ .view = ctx.view.point(world), .world = world, .normal = nm.vector(v.normal), .uv = v.uv };
        }
        // In front of the camera only: cut at the near plane (z = -near).
        var poly: [4]Corner = undefined;
        var n: usize = 0;
        for (0..3) |k| {
            const a = tri[k];
            const b = tri[(k + 1) % 3];
            const a_in = a.view[2] <= -near;
            const b_in = b.view[2] <= -near;
            if (a_in) {
                poly[n] = a;
                n += 1;
            }
            if (a_in != b_in) {
                poly[n] = a.lerp(b, (-near - a.view[2]) / (b.view[2] - a.view[2]));
                n += 1;
            }
        }
        if (n < 3) continue;
        for (1..n - 1) |k| triangle(ctx, inst, .{ poly[0], poly[k], poly[k + 1] });
    }
}

/// On the screen: x, y and 1 / depth.
fn project(ctx: *const Context, v: Vec3) Vec3 {
    const inv = 1 / -v[2];
    return .{ ctx.cx + v[0] * ctx.focal * inv, ctx.cy - v[1] * ctx.focal * inv, inv };
}

fn triangle(ctx: *const Context, inst: *const Instance, c: [3]Corner) void {
    var s: [3]Vec3 = undefined;
    for (0..3) |k| s[k] = project(ctx, c[k].view);
    const edge = struct {
        fn f(a: Vec3, b: Vec3, px: f32, py: f32) f32 {
            return (b[0] - a[0]) * (py - a[1]) - (b[1] - a[1]) * (px - a[0]);
        }
    }.f;
    var area = edge(s[0], s[1], s[2][0], s[2][1]);
    if (area == 0) return;
    // Counter-clockwise from outside is clockwise on the screen (y down):
    // a positive area faces away.
    const back = area > 0;
    if (back and !inst.mesh.two_sided) return;
    var order = [3]usize{ 0, 1, 2 };
    if (area < 0) {
        order = .{ 0, 2, 1 };
        area = -area;
    }
    const p = [3]Vec3{ s[order[0]], s[order[1]], s[order[2]] };
    const v = [3]Corner{ c[order[0]], c[order[1]], c[order[2]] };
    var owns: [3]bool = undefined;
    for (0..3) |k| {
        const a = p[(k + 1) % 3];
        const b = p[(k + 2) % 3];
        owns[k] = (b[1] - a[1]) > 0 or ((b[1] - a[1]) == 0 and (b[0] - a[0]) < 0);
    }
    const t = ctx.target;
    const fw: f32 = @floatFromInt(t.width);
    const fh: f32 = @floatFromInt(t.height);
    const x0: u32 = @intFromFloat(std.math.clamp(@floor(@min(p[0][0], @min(p[1][0], p[2][0]))), 0, fw));
    const x1: u32 = @intFromFloat(std.math.clamp(@ceil(@max(p[0][0], @max(p[1][0], p[2][0]))), 0, fw));
    const y0: u32 = @intFromFloat(std.math.clamp(@floor(@min(p[0][1], @min(p[1][1], p[2][1]))), 0, fh));
    const y1: u32 = @intFromFloat(std.math.clamp(@ceil(@max(p[0][1], @max(p[1][1], p[2][1]))), 0, fh));
    const m = inst.material;
    const base = linear(m.base_color);
    const alpha = @as(f32, @floatFromInt(m.base_color.a)) / 255;
    var y = y0;
    while (y < y1) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        var x = x0;
        while (x < x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            var b: [3]f32 = undefined;
            var inside = true;
            for (0..3) |k| {
                b[k] = edge(p[(k + 1) % 3], p[(k + 2) % 3], px, py);
                if (b[k] < 0 or (b[k] == 0 and !owns[k])) inside = false;
            }
            if (!inside) continue;
            // Perspective-correct weights: each over its depth.
            const pw = [3]f32{ b[0] * p[0][2], b[1] * p[1][2], b[2] * p[2][2] };
            const sum = pw[0] + pw[1] + pw[2];
            const inv_depth = sum / area;
            const at = y * t.width + x;
            if (inv_depth <= t.depth[at]) continue;
            const wgt = [3]f32{ pw[0] / sum, pw[1] / sum, pw[2] / sum };
            const world = v[0].world * splat(wgt[0]) + v[1].world * splat(wgt[1]) + v[2].world * splat(wgt[2]);
            var normal = normalize(v[0].normal * splat(wgt[0]) + v[1].normal * splat(wgt[1]) + v[2].normal * splat(wgt[2]));
            const to_eye = normalize(ctx.eye - world);
            if (back) normal = -normal;
            var color = base;
            var a = alpha;
            if (m.texture) |tex| {
                const uv = [2]f32{
                    v[0].uv[0] * wgt[0] + v[1].uv[0] * wgt[1] + v[2].uv[0] * wgt[2],
                    v[0].uv[1] * wgt[0] + v[1].uv[1] * wgt[1] + v[2].uv[1] * wgt[2],
                };
                const texel = sample(tex, uv);
                color *= texel[0..3].*;
                a *= texel[3];
            }
            if (a <= 0) continue;
            t.depth[at] = inv_depth;
            const lit = shade(ctx, color, m.metallic, m.roughness, world, normal, to_eye);
            const out = encode(lit, a);
            t.pixels[at] = if (a >= 1) out else over(out, t.pixels[at]);
        }
    }
}

/// Light leaving the surface toward the viewer (linear): ambient, then
/// each light's diffuse and specular parts (GGX, Smith, Schlick).
fn shade(ctx: *const Context, base: Vec3, metallic_: f32, roughness_: f32, world: Vec3, n: Vec3, v: Vec3) Vec3 {
    const metallic = std.math.clamp(metallic_, 0, 1);
    const rough = std.math.clamp(roughness_, 0.04, 1);
    const alpha2 = (rough * rough) * (rough * rough);
    const f0 = splat(0.04) * splat(1 - metallic) + base * splat(metallic);
    const diffuse = base * splat(1 - metallic);
    const nv = @max(dot(n, v), 1e-4);
    const k = (rough + 1) * (rough + 1) / 8;
    var out = ctx.ambient * base;
    for (ctx.lights) |l| {
        var to_light = l.vec;
        var radiance = l.radiance;
        if (l.point) {
            const d = l.vec - world;
            const dist2 = dot(d, d);
            to_light = normalize(d);
            radiance *= splat(1 / (1 + dist2 / (l.range * l.range)));
        }
        const nl = dot(n, to_light);
        if (nl <= 0) continue;
        const hv = normalize(to_light + v);
        const nh = @max(dot(n, hv), 0);
        const vh = @max(dot(v, hv), 0);
        const dd = nh * nh * (alpha2 - 1) + 1;
        const distribution = alpha2 / (std.math.pi * dd * dd);
        const geometry_ = (nv / (nv * (1 - k) + k)) * (nl / (nl * (1 - k) + k));
        const fresnel = f0 + (splat(1) - f0) * splat(std.math.pow(f32, 1 - vh, 5));
        const specular = fresnel * splat(distribution * geometry_ / (4 * nv * nl));
        // A white surface lit head-on by brightness 1 shows white.
        out += (diffuse * (splat(1) - fresnel) + specular * splat(std.math.pi)) * radiance * splat(nl);
    }
    return out;
}

/// An sRGB color as linear light (squared: close, and cheap).
fn linear(c: Color) Vec3 {
    const r = @as(f32, @floatFromInt(c.r)) / 255;
    const g = @as(f32, @floatFromInt(c.g)) / 255;
    const b = @as(f32, @floatFromInt(c.b)) / 255;
    return .{ r * r, g * g, b * b };
}

/// Linear light as a premultiplied sRGB pixel.
fn encode(c: Vec3, alpha: f32) Rgba8 {
    const a = std.math.clamp(alpha, 0, 1);
    const ch = struct {
        fn f(x: f32, k: f32) u8 {
            return @intFromFloat(@round(@sqrt(std.math.clamp(x, 0, 1)) * k * 255));
        }
    }.f;
    return .{ .r = ch(c[0], a), .g = ch(c[1], a), .b = ch(c[2], a), .a = @intFromFloat(@round(a * 255)) };
}

fn over(top: Rgba8, below: Rgba8) Rgba8 {
    const inv: u16 = 255 - top.a;
    return .{
        .r = @intCast(@min(255, top.r + (@as(u16, below.r) * inv + 127) / 255)),
        .g = @intCast(@min(255, top.g + (@as(u16, below.g) * inv + 127) / 255)),
        .b = @intCast(@min(255, top.b + (@as(u16, below.b) * inv + 127) / 255)),
        .a = @intCast(@min(255, top.a + (@as(u16, below.a) * inv + 127) / 255)),
    };
}

/// The texture at `uv` (repeated, bilinear): linear color and alpha.
fn sample(tex: image.Image, uv: [2]f32) [4]f32 {
    if (tex.width == 0 or tex.height == 0 or tex.pixels.len < @as(usize, tex.width) * tex.height) return .{ 1, 1, 1, 1 };
    const fw: f32 = @floatFromInt(tex.width);
    const fh: f32 = @floatFromInt(tex.height);
    const x = (uv[0] - @floor(uv[0])) * fw - 0.5;
    const y = (uv[1] - @floor(uv[1])) * fh - 0.5;
    const x0 = @floor(x);
    const y0 = @floor(y);
    const tx = x - x0;
    const ty = y - y0;
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    const corners = [4][3]f32{ .{ 0, 0, (1 - tx) * (1 - ty) }, .{ 1, 0, tx * (1 - ty) }, .{ 0, 1, (1 - tx) * ty }, .{ 1, 1, tx * ty } };
    for (corners) |cn| {
        const ix: u32 = @intCast(@mod(@as(i64, @intFromFloat(x0 + cn[0])), tex.width));
        const iy: u32 = @intCast(@mod(@as(i64, @intFromFloat(y0 + cn[1])), tex.height));
        const px = tex.pixels[iy * tex.width + ix];
        const a = @as(f32, @floatFromInt(px.a)) / 255;
        // Premultiplied: back to straight color, then linear.
        const un = if (a > 0) 1 / (a * 255) else 0;
        const r = @as(f32, @floatFromInt(px.r)) * un;
        const g = @as(f32, @floatFromInt(px.g)) * un;
        const b = @as(f32, @floatFromInt(px.b)) * un;
        out[0] += r * r * cn[2];
        out[1] += g * g * cn[2];
        out[2] += b * b * cn[2];
        out[3] += a * cn[2];
    }
    return out;
}

// ---- For GPU renderers ----

/// An instance as GPU renderers' 3D shaders take it (column-major
/// matrices; see `gpuInstance`).
pub const GpuInstance = extern struct { world: [16]f32, normal: [16]f32, base: [4]f32, params: [4]f32 };
/// A light: toward it (directional, w 0) or its position (point, w 1),
/// and its linear radiance and range.
pub const GpuLight = extern struct { vec: [4]f32, radiance: [4]f32 };
/// A picture's camera and lights (see `gpuFrame`).
pub const GpuFrame = extern struct { view_proj: [16]f32, eye: [4]f32, ambient: [4]f32, counts: [4]u32, lights: [16]GpuLight };

/// `m` as a column-major 4 x 4 matrix.
fn columns(m: Mat) [16]f32 {
    var out: [16]f32 = @splat(0);
    for (0..3) |row| for (0..4) |col| {
        out[col * 4 + row] = m.m[row][col];
    };
    out[15] = 1;
    return out;
}

/// What GPU renderers' 3D shaders take for a picture `width` x `height` of
/// `scene`: the camera's view and projection (as `render` projects: the
/// same field of view and near plane; depth from 0 to 1), the eye, the
/// ambient light and the lights, all linear.
pub fn gpuFrame(scene: *const Scene, width: u32, height: u32) GpuFrame {
    var f: GpuFrame = std.mem.zeroes(GpuFrame);
    const view = scene.camera.world.inverse() orelse Mat.identity;
    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    const t = 1 / @tan(std.math.clamp(scene.camera.field_of_view, 1, 170) * std.math.pi / 360);
    const far = 1000.0;
    const proj = [16]f32{ t / aspect, 0, 0, 0, 0, t, 0, 0, 0, 0, far / (near - far), -1, 0, 0, near * far / (near - far), 0 };
    const v = columns(view);
    for (0..4) |col| for (0..4) |row| {
        var sum: f32 = 0;
        for (0..4) |k| sum += proj[k * 4 + row] * v[col * 4 + k];
        f.view_proj[col * 4 + row] = sum;
    };
    const eye = scene.camera.world.point(.{ 0, 0, 0 });
    f.eye = .{ eye[0], eye[1], eye[2], 1 };
    const amb = linear(scene.ambient);
    const ab = @max(0, scene.ambient_brightness);
    f.ambient = .{ amb[0] * ab, amb[1] * ab, amb[2] * ab, 1 };
    var n: u32 = 0;
    for (scene.lights) |l| {
        if (n == f.lights.len) break;
        f.lights[n] = switch (l) {
            .directional => |d| blk: {
                const len = @sqrt(d.direction[0] * d.direction[0] + d.direction[1] * d.direction[1] + d.direction[2] * d.direction[2]);
                const c = linear(d.color);
                const inv = if (len > 0) -1 / len else 0;
                break :blk .{ .vec = .{ d.direction[0] * inv, d.direction[1] * inv, d.direction[2] * inv, 0 }, .radiance = .{ c[0] * d.brightness, c[1] * d.brightness, c[2] * d.brightness, 0 } };
            },
            .point => |p| blk: {
                const c = linear(p.color);
                break :blk .{ .vec = .{ p.position[0], p.position[1], p.position[2], 1 }, .radiance = .{ c[0] * p.brightness, c[1] * p.brightness, c[2] * p.brightness, @max(p.range, 1e-3) } };
            },
        };
        n += 1;
    }
    f.counts = .{ n, 0, 0, 0 };
    return f;
}

/// What GPU renderers' 3D shaders take for `inst`: its transforms (for
/// points and normals), its material's linear base color and alpha, and
/// metallic, roughness, whether it has a texture, whether it is two-sided.
pub fn gpuInstance(inst: *const Instance) GpuInstance {
    const m = inst.material;
    const c = linear(m.base_color);
    return .{
        .world = columns(inst.world),
        .normal = columns(inst.world.normalMatrix()),
        .base = .{ c[0], c[1], c[2], @as(f32, @floatFromInt(m.base_color.a)) / 255 },
        .params = .{ m.metallic, m.roughness, if (m.texture != null) 1 else 0, if (inst.mesh.two_sided) 1 else 0 },
    };
}

// ---- Picking ----

/// The instance seen at (`x`, `y`) in a picture `width` x `height` of
/// `scene` (the nearest one there), if any.
pub fn pick(scene: *const Scene, width: f32, height: f32, x: f32, y: f32) ?usize {
    if (width <= 0 or height <= 0) return null;
    const focal = height / 2 / @tan(std.math.clamp(scene.camera.field_of_view, 1, 170) * std.math.pi / 360);
    // The ray through the point, from the camera, in the scene.
    const origin = scene.camera.world.point(.{ 0, 0, 0 });
    const dir = scene.camera.world.vector(.{ (x - width / 2) / focal, -(y - height / 2) / focal, -1 });
    var best: ?usize = null;
    var nearest = std.math.inf(f32);
    for (scene.instances, 0..) |*inst, k| {
        // In the mesh's coordinates (the same distances along the ray).
        const inv = inst.world.inverse() orelse continue;
        const o = inv.point(origin);
        const d = inv.vector(dir);
        const mesh = inst.mesh;
        var i: usize = 0;
        while (i + 2 < mesh.indices.len) : (i += 3) {
            const t = hit(o, d, mesh.vertices[mesh.indices[i]].position, mesh.vertices[mesh.indices[i + 1]].position, mesh.vertices[mesh.indices[i + 2]].position) orelse continue;
            if (t < nearest) {
                nearest = t;
                best = k;
            }
        }
    }
    return best;
}

/// Where along `d` from `o` the ray meets triangle `a b c` (in front of
/// the camera), if it does (Möller and Trumbore).
fn hit(o: Vec3, d: Vec3, a: Vec3, b: Vec3, c: Vec3) ?f32 {
    const e1 = b - a;
    const e2 = c - a;
    const p = cross(d, e2);
    const det = dot(e1, p);
    if (@abs(det) < 1e-12) return null;
    const inv = 1 / det;
    const s = o - a;
    const u = dot(s, p) * inv;
    if (u < 0 or u > 1) return null;
    const q = cross(s, e1);
    const v = dot(d, q) * inv;
    if (v < 0 or u + v > 1) return null;
    const t = dot(e2, q) * inv;
    return if (t > near) t else null;
}

// ---- Tests ----

const testing = std.testing;

test "transforms: placed, turned, inverted" {
    const m = Mat.place(.{ 1, 2, 3 }, 0, 90, 0, .{ 2, 2, 2 });
    const p = m.point(.{ 1, 0, 0 });
    // Turned a quarter about y: +x goes to -z.
    try testing.expectApproxEqAbs(@as(f32, 1), p[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), p[2], 1e-5);
    const back = m.inverse().?.point(p);
    try testing.expectApproxEqAbs(@as(f32, 1), back[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), back[2], 1e-5);
    // Pitched up: looking along -z, then up.
    const up = Mat.rotation(90, 0, 0).vector(.{ 0, 0, -1 });
    try testing.expectApproxEqAbs(@as(f32, 1), up[1], 1e-5);
}

test "a lit cube in front of the camera: drawn, shaded by the light, hidden behind a nearer one" {
    const w = 64;
    const h = 64;
    var pixels: [w * h]Rgba8 = undefined;
    var depth: [w * h]f32 = undefined;
    const target: Target = .{ .width = w, .height = h, .pixels = &pixels, .depth = &depth };
    const red: Material = .{ .base_color = .rgb(0xff0000), .roughness = 1 };
    var scene: Scene = .{
        .instances = &.{.{ .mesh = cube, .world = .rotation(0, 30, 0), .material = red }},
        .lights = &.{.{ .directional = .{ .direction = .{ 0, 0, -1 } } }},
        .ambient = .rgb(0x000000),
    };
    render(&scene, target);
    // The middle: red; the corners: the background.
    const mid = pixels[32 * w + 32];
    try testing.expect(mid.r > 120 and mid.g < 60 and mid.a == 255);
    try testing.expectEqual(@as(u8, 0), pixels[0].a);
    // Turned left, its front face (on the right) faces the light more than
    // its side (on the left): brighter.
    const front = pixels[32 * w + 40];
    const side = pixels[32 * w + 24];
    try testing.expect(front.r > side.r + 20);

    // A green cube nearer, in front: it hides the red one.
    const green: Material = .{ .base_color = .rgb(0x00ff00), .roughness = 1 };
    scene.instances = &.{
        .{ .mesh = cube, .world = .rotation(0, 30, 0), .material = red },
        .{ .mesh = cube, .world = .place(.{ 0, 0, 1.5 }, 0, 0, 0, .{ 0.3, 0.3, 0.3 }), .material = green },
    };
    render(&scene, target);
    try testing.expect(pixels[32 * w + 32].g > 100 and pixels[32 * w + 32].r < 60);
    // And drawn first, too.
    scene.instances = &.{
        .{ .mesh = cube, .world = .place(.{ 0, 0, 1.5 }, 0, 0, 0, .{ 0.3, 0.3, 0.3 }), .material = green },
        .{ .mesh = cube, .world = .rotation(0, 30, 0), .material = red },
    };
    render(&scene, target);
    try testing.expect(pixels[32 * w + 32].g > 100 and pixels[32 * w + 32].r < 60);
}

test "a sphere's highlight, a plane seen from behind, the camera inside a cube" {
    const w = 64;
    const h = 64;
    var pixels: [w * h]Rgba8 = undefined;
    var depth: [w * h]f32 = undefined;
    const target: Target = .{ .width = w, .height = h, .pixels = &pixels, .depth = &depth };
    // A shiny sphere lit from the viewer: brightest in its middle.
    var scene: Scene = .{
        .instances = &.{.{ .mesh = sphere(), .world = .scaling(.{ 2, 2, 2 }), .material = .{ .base_color = .rgb(0x3366ff), .roughness = 0.2 } }},
        .lights = &.{.{ .point = .{ .position = .{ 0, 0, 4 }, .brightness = 2 } }},
    };
    render(&scene, target);
    const middle = pixels[32 * w + 32];
    const rim = pixels[32 * w + 10];
    try testing.expect(middle.r > rim.r and middle.b > rim.b);

    // A plane turned away still shows (both sides).
    scene.instances = &.{.{ .mesh = plane, .world = .rotation(0, 180, 0), .material = .{ .base_color = .rgb(0xffffff) } }};
    render(&scene, target);
    try testing.expect(pixels[32 * w + 32].a == 255);

    // The camera inside a cube: its faces behind the camera are cut, the
    // ones around show (from inside: culled as back faces).
    scene.instances = &.{.{ .mesh = cube, .world = .scaling(.{ 20, 20, 20 }) }};
    render(&scene, target);
    try testing.expectEqual(@as(u8, 0), pixels[32 * w + 32].a);
}

test "picking: the nearest instance under a point" {
    const scene: Scene = .{
        .instances = &.{
            .{ .mesh = cube, .world = .identity },
            .{ .mesh = sphere(), .world = .place(.{ 0, 0, 1.5 }, 0, 0, 0, .{ 0.3, 0.3, 0.3 }) },
            .{ .mesh = cube, .world = .translation(.{ 1.5, 0, 0 }) },
        },
    };
    // The middle: the small sphere in front of the cube.
    try testing.expectEqual(@as(?usize, 1), pick(&scene, 200, 200, 100, 100));
    // Beside it: the cube behind.
    try testing.expectEqual(@as(?usize, 0), pick(&scene, 200, 200, 100, 80));
    // To the right: the other cube; a corner: nothing.
    try testing.expectEqual(@as(?usize, 2), pick(&scene, 200, 200, 160, 100));
    try testing.expectEqual(@as(?usize, null), pick(&scene, 200, 200, 2, 2));
}
