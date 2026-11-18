// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! glTF 2.0 models in their binary form (`.glb`), for `View3D`: the
//! default scene's nodes (their matrices, or translation, rotation and
//! scale), their meshes' triangles (positions, normals, the first texture
//! coordinates; normals computed where there are none) and the
//! metallic-roughness materials, with their base color textures when PNG.
//! Data in other files or in data URIs, sparse accessors, other primitive
//! modes, skins, morph targets and animations are not read.

const std = @import("std");
const Allocator = std.mem.Allocator;
const raster = @import("raster3d.zig");
const Mat = raster.Mat;
const Vec3 = raster.Vec3;
const graphics = @import("graphics.zig");
const Color = graphics.Color;
const png = @import("png.zig");
const image = @import("image.zig");

const log = std.log.scoped(.zigulee_gltf);

pub const Error = error{InvalidModel} || Allocator.Error;

/// A mesh of the model, where it is, in its material.
pub const Part = struct {
    mesh: raster.Mesh,
    /// From the mesh's coordinates to the model's.
    world: Mat,
    material: raster.Material,
};

/// A model read from a file: its parts (all in `arena`).
pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    parts: []const Part,

    pub fn deinit(self: *Model) void {
        self.arena.deinit();
    }
};

/// Reads a `.glb` file.
pub fn load(gpa: Allocator, bytes: []const u8) Error!Model {
    var model: Model = .{ .arena = .init(gpa), .parts = &.{} };
    errdefer model.arena.deinit();
    const a = model.arena.allocator();
    const chunks = try split(bytes);
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, chunks.json, .{}) catch return error.InvalidModel;
    if (root != .object) return error.InvalidModel;
    var reader: Reader = .{ .a = a, .root = root.object, .bin = chunks.bin };
    var parts: std.ArrayList(Part) = .empty;
    const nodes = reader.array("nodes");
    for (try reader.sceneRoots()) |n| try reader.node(&parts, nodes, n, .identity, 0);
    model.parts = parts.items;
    return model;
}

const Chunks = struct { json: []const u8, bin: []const u8 };

/// The JSON and binary chunks of a `.glb`.
fn split(bytes: []const u8) Error!Chunks {
    if (bytes.len < 20 or !std.mem.eql(u8, bytes[0..4], "glTF")) return error.InvalidModel;
    if (std.mem.readInt(u32, bytes[4..8], .little) != 2) return error.InvalidModel;
    const total = @min(bytes.len, std.mem.readInt(u32, bytes[8..12], .little));
    var out: Chunks = .{ .json = "", .bin = "" };
    var at: usize = 12;
    while (at + 8 <= total) {
        const len = std.mem.readInt(u32, bytes[at..][0..4], .little);
        const kind = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        at += 8;
        if (len > total - at) return error.InvalidModel;
        const data = bytes[at..][0..len];
        switch (kind) {
            0x4E4F534A => out.json = data, // JSON
            0x004E4942 => out.bin = data, // BIN
            else => {},
        }
        at += (len + 3) & ~@as(usize, 3);
    }
    if (out.json.len == 0) return error.InvalidModel;
    return out;
}

const Object = std.json.ObjectMap;
const Value = std.json.Value;

const Reader = struct {
    a: Allocator,
    root: Object,
    bin: []const u8,

    fn array(r: *const Reader, key: []const u8) []const Value {
        return arrayIn(r.root, key);
    }

    /// The nodes the scene starts from: the default scene's, else those
    /// that are nobody's children.
    fn sceneRoots(r: *const Reader) Error![]const usize {
        var roots: std.ArrayList(usize) = .empty;
        const scenes = r.array("scenes");
        if (scenes.len > 0) {
            const index = @min(intIn(r.root, "scene") orelse 0, scenes.len - 1);
            if (scenes[index] == .object) for (arrayIn(scenes[index].object, "nodes")) |n| {
                if (int(n)) |i| try roots.append(r.a, i);
            };
            return roots.items;
        }
        const nodes = r.array("nodes");
        const child = try r.a.alloc(bool, nodes.len);
        @memset(child, false);
        for (nodes) |n| if (n == .object) for (arrayIn(n.object, "children")) |c| {
            if (int(c)) |i| if (i < nodes.len) {
                child[i] = true;
            };
        };
        for (child, 0..) |is_child, i| if (!is_child) try roots.append(r.a, i);
        return roots.items;
    }

    fn node(r: *Reader, parts: *std.ArrayList(Part), nodes: []const Value, index: usize, parent: Mat, depth: u32) Error!void {
        if (index >= nodes.len or depth > 64 or nodes[index] != .object) return;
        const n = nodes[index].object;
        const world = parent.mul(transformOf(n));
        if (intIn(n, "mesh")) |m| try r.mesh(parts, m, world);
        for (arrayIn(n, "children")) |c| if (int(c)) |i| try r.node(parts, nodes, i, world, depth + 1);
    }

    fn mesh(r: *Reader, parts: *std.ArrayList(Part), index: usize, world: Mat) Error!void {
        const meshes = r.array("meshes");
        if (index >= meshes.len or meshes[index] != .object) return;
        for (arrayIn(meshes[index].object, "primitives")) |p| {
            if (p != .object) continue;
            // Triangles only.
            if ((intIn(p.object, "mode") orelse 4) != 4) continue;
            const part = r.primitive(p.object) catch |err| switch (err) {
                error.InvalidModel => {
                    log.info("a mesh's part cannot be read: left out", .{});
                    continue;
                },
                else => |e| return e,
            };
            try parts.append(r.a, .{ .mesh = part.mesh, .world = world, .material = part.material });
        }
    }

    fn primitive(r: *Reader, p: Object) Error!struct { mesh: raster.Mesh, material: raster.Material } {
        const attributes = objectIn(p, "attributes") orelse return error.InvalidModel;
        const positions = try r.floats(intIn(attributes, "POSITION") orelse return error.InvalidModel, 3);
        const count = positions.len / 3;
        const normals = if (intIn(attributes, "NORMAL")) |i| try r.floats(i, 3) else null;
        const uvs = if (intIn(attributes, "TEXCOORD_0")) |i| try r.floats(i, 2) else null;
        if (normals) |ns| if (ns.len / 3 != count) return error.InvalidModel;
        if (uvs) |us| if (us.len / 2 != count) return error.InvalidModel;
        var indices: []u32 = if (intIn(p, "indices")) |i| try r.readIndices(i) else blk: {
            const seq = try r.a.alloc(u32, count);
            for (seq, 0..) |*s, k| s.* = @intCast(k);
            break :blk seq;
        };
        indices = indices[0 .. indices.len - indices.len % 3];
        for (indices) |i| if (i >= count) return error.InvalidModel;

        var vertices: []raster.Vertex = undefined;
        if (normals) |ns| {
            vertices = try r.a.alloc(raster.Vertex, count);
            for (vertices, 0..) |*v, k| v.* = .{
                .position = .{ positions[k * 3], positions[k * 3 + 1], positions[k * 3 + 2] },
                .normal = .{ ns[k * 3], ns[k * 3 + 1], ns[k * 3 + 2] },
                .uv = if (uvs) |us| .{ us[k * 2], us[k * 2 + 1] } else .{ 0, 0 },
            };
        } else {
            // Flat: each triangle's corners its own, with its normal.
            vertices = try r.a.alloc(raster.Vertex, indices.len);
            var t: usize = 0;
            while (t < indices.len) : (t += 3) {
                var ps: [3]Vec3 = undefined;
                for (0..3) |k| {
                    const i = indices[t + k];
                    ps[k] = .{ positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2] };
                }
                const e1 = ps[1] - ps[0];
                const e2 = ps[2] - ps[0];
                const nrm: Vec3 = .{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
                for (0..3) |k| {
                    const i = indices[t + k];
                    vertices[t + k] = .{ .position = ps[k], .normal = nrm, .uv = if (uvs) |us| .{ us[i * 2], us[i * 2 + 1] } else .{ 0, 0 } };
                }
            }
            for (indices, 0..) |*i, k| i.* = @intCast(k);
        }
        var material: raster.Material = .{ .metallic = 1, .roughness = 1 };
        var two_sided = false;
        if (intIn(p, "material")) |m| {
            const materials = r.array("materials");
            if (m < materials.len and materials[m] == .object) {
                const mo = materials[m].object;
                two_sided = boolIn(mo, "doubleSided");
                material = try r.materialOf(mo);
            }
        }
        return .{ .mesh = .{ .vertices = vertices, .indices = indices, .two_sided = two_sided }, .material = material };
    }

    fn materialOf(r: *Reader, m: Object) Error!raster.Material {
        var out: raster.Material = .{ .metallic = 1, .roughness = 1 };
        const pbr = objectIn(m, "pbrMetallicRoughness") orelse return out;
        const factor = arrayIn(pbr, "baseColorFactor");
        if (factor.len == 4) {
            // Linear in the file: as sRGB (the renderer squares it back).
            const ch = struct {
                fn f(v: Value) u8 {
                    return @intFromFloat(@round(@sqrt(std.math.clamp(number(v) orelse 1, 0, 1)) * 255));
                }
            }.f;
            out.base_color = .{ .r = ch(factor[0]), .g = ch(factor[1]), .b = ch(factor[2]), .a = @intFromFloat(@round(std.math.clamp(number(factor[3]) orelse 1, 0, 1) * 255)) };
        }
        if (pbr.get("metallicFactor")) |v| out.metallic = number(v) orelse 1;
        if (pbr.get("roughnessFactor")) |v| out.roughness = number(v) orelse 1;
        if (objectIn(pbr, "baseColorTexture")) |t| if (intIn(t, "index")) |i| {
            out.texture = r.texture(i);
        };
        return out;
    }

    /// Texture `index`'s image, if it is a PNG in the file.
    fn texture(r: *Reader, index: usize) ?image.Image {
        const textures = r.array("textures");
        if (index >= textures.len or textures[index] != .object) return null;
        const source = intIn(textures[index].object, "source") orelse return null;
        const images = r.array("images");
        if (source >= images.len or images[source] != .object) return null;
        const img = images[source].object;
        const view = intIn(img, "bufferView") orelse return null;
        const bytes = r.bufferView(view) catch return null;
        if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) {
            log.info("a texture is not a PNG: left out", .{});
            return null;
        }
        const decoded = png.decode(r.a, bytes) catch return null;
        return .{ .width = decoded.width, .height = decoded.height, .pixels = decoded.pixels };
    }

    /// The bytes of buffer view `index` (in the file's binary chunk).
    fn bufferView(r: *const Reader, index: usize) Error![]const u8 {
        const views = r.array("bufferViews");
        if (index >= views.len or views[index] != .object) return error.InvalidModel;
        const v = views[index].object;
        if ((intIn(v, "buffer") orelse 0) != 0) return error.InvalidModel;
        const offset = intIn(v, "byteOffset") orelse 0;
        const len = intIn(v, "byteLength") orelse return error.InvalidModel;
        if (offset > r.bin.len or len > r.bin.len - offset) return error.InvalidModel;
        return r.bin[offset..][0..len];
    }

    const Accessor = struct { data: []const u8, count: usize, components: usize, component_type: usize, stride: usize, normalized: bool };

    fn accessor(r: *const Reader, index: usize, components: usize) Error!Accessor {
        const accessors = r.array("accessors");
        if (index >= accessors.len or accessors[index] != .object) return error.InvalidModel;
        const acc = accessors[index].object;
        if (acc.get("sparse") != null) return error.InvalidModel;
        const view_index = intIn(acc, "bufferView") orelse return error.InvalidModel;
        const view = try r.bufferView(view_index);
        const count = intIn(acc, "count") orelse return error.InvalidModel;
        const component_type = intIn(acc, "componentType") orelse return error.InvalidModel;
        const size: usize = switch (component_type) {
            5120, 5121 => 1,
            5122, 5123 => 2,
            5125, 5126 => 4,
            else => return error.InvalidModel,
        };
        const views = r.array("bufferViews");
        const stride = intIn(views[view_index].object, "byteStride") orelse size * components;
        const offset = intIn(acc, "byteOffset") orelse 0;
        if (count == 0) return .{ .data = &.{}, .count = 0, .components = components, .component_type = component_type, .stride = stride, .normalized = false };
        const needed = offset + (count - 1) * stride + size * components;
        if (needed > view.len or stride < size * components) return error.InvalidModel;
        return .{ .data = view[offset..needed], .count = count, .components = components, .component_type = component_type, .stride = stride, .normalized = boolIn(acc, "normalized") };
    }

    /// Accessor `index` as floats (`components` per element).
    fn floats(r: *const Reader, index: usize, components: usize) Error![]f32 {
        const acc = try r.accessor(index, components);
        const out = try r.a.alloc(f32, acc.count * components);
        for (0..acc.count) |i| for (0..components) |k| {
            const at = acc.data[i * acc.stride ..];
            out[i * components + k] = switch (acc.component_type) {
                5126 => @bitCast(std.mem.readInt(u32, at[k * 4 ..][0..4], .little)),
                5121 => @as(f32, @floatFromInt(at[k])) / 255,
                5123 => @as(f32, @floatFromInt(std.mem.readInt(u16, at[k * 2 ..][0..2], .little))) / 65535,
                5120 => @max(-1, @as(f32, @floatFromInt(@as(i8, @bitCast(at[k])))) / 127),
                5122 => @max(-1, @as(f32, @floatFromInt(std.mem.readInt(i16, at[k * 2 ..][0..2], .little))) / 32767),
                else => return error.InvalidModel,
            };
        };
        return out;
    }

    fn readIndices(r: *const Reader, index: usize) Error![]u32 {
        const acc = try r.accessor(index, 1);
        const out = try r.a.alloc(u32, acc.count);
        for (out, 0..) |*o, i| {
            const at = acc.data[i * acc.stride ..];
            o.* = switch (acc.component_type) {
                5121 => at[0],
                5123 => std.mem.readInt(u16, at[0..2], .little),
                5125 => std.mem.readInt(u32, at[0..4], .little),
                else => return error.InvalidModel,
            };
        }
        return out;
    }
};

/// A node's transform: its `matrix` (column-major), or `translation`,
/// `rotation` (a quaternion: x, y, z, w) and `scale`.
fn transformOf(n: Object) Mat {
    const matrix = arrayIn(n, "matrix");
    if (matrix.len == 16) {
        var m: Mat = undefined;
        for (0..3) |row| for (0..4) |col| {
            m.m[row][col] = number(matrix[col * 4 + row]) orelse 0;
        };
        return m;
    }
    const t = vec3(arrayIn(n, "translation"), 0);
    const s = vec3(arrayIn(n, "scale"), 1);
    const q = arrayIn(n, "rotation");
    var rot: Mat = .identity;
    if (q.len == 4) {
        const x = number(q[0]) orelse 0;
        const y = number(q[1]) orelse 0;
        const z = number(q[2]) orelse 0;
        const w = number(q[3]) orelse 1;
        rot = .{ .m = .{
            .{ 1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), 0 },
            .{ 2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w), 0 },
            .{ 2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y), 0 },
        } };
    }
    return Mat.translation(t).mul(rot).mul(.scaling(s));
}

fn vec3(a: []const Value, default: f32) Vec3 {
    if (a.len != 3) return @splat(default);
    return .{ number(a[0]) orelse default, number(a[1]) orelse default, number(a[2]) orelse default };
}

fn number(v: Value) ?f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => null,
    };
}

fn int(v: Value) ?usize {
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

fn intIn(o: Object, key: []const u8) ?usize {
    return int(o.get(key) orelse return null);
}

fn boolIn(o: Object, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn arrayIn(o: Object, key: []const u8) []const Value {
    const v = o.get(key) orelse return &.{};
    return if (v == .array) v.array.items else &.{};
}

fn objectIn(o: Object, key: []const u8) ?Object {
    const v = o.get(key) orelse return null;
    return if (v == .object) v.object else null;
}

// ---- Tests ----

const testing = std.testing;

/// A `.glb` of `json` and `bin`.
pub fn testFile(a: Allocator, json: []const u8, bin: []const u8) ![]u8 {
    const jlen = (json.len + 3) & ~@as(usize, 3);
    const blen = (bin.len + 3) & ~@as(usize, 3);
    const total = 12 + 8 + jlen + (if (bin.len > 0) 8 + blen else 0);
    const out = try a.alloc(u8, total);
    @memcpy(out[0..4], "glTF");
    std.mem.writeInt(u32, out[4..8], 2, .little);
    std.mem.writeInt(u32, out[8..12], @intCast(total), .little);
    std.mem.writeInt(u32, out[12..16], @intCast(jlen), .little);
    std.mem.writeInt(u32, out[16..20], 0x4E4F534A, .little);
    @memset(out[20..][0..jlen], ' ');
    @memcpy(out[20..][0..json.len], json);
    if (bin.len > 0) {
        const at = 20 + jlen;
        std.mem.writeInt(u32, out[at..][0..4], @intCast(blen), .little);
        std.mem.writeInt(u32, out[at + 4 ..][0..4], 0x004E4942, .little);
        @memset(out[at + 8 ..][0..blen], 0);
        @memcpy(out[at + 8 ..][0..bin.len], bin);
    }
    return out;
}

test "a .glb: its nodes' meshes, placed, in their materials; flat normals where there are none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A triangle (three positions, then three u16 indices).
    var bin: [36 + 6]u8 = undefined;
    const pos = [9]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    for (pos, 0..) |f, i| std.mem.writeInt(u32, bin[i * 4 ..][0..4], @bitCast(f), .little);
    for ([3]u16{ 0, 1, 2 }, 0..) |v, i| std.mem.writeInt(u16, bin[36 + i * 2 ..][0..2], v, .little);
    const json =
        \\{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
        \\"nodes":[{"translation":[0,0,-1],"children":[1]},{"mesh":0,"scale":[2,2,2],"rotation":[0,0.7071068,0,0.7071068]}],
        \\"meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0}]}],
        \\"materials":[{"pbrMetallicRoughness":{"baseColorFactor":[1,0,0,1],"metallicFactor":0,"roughnessFactor":0.25},"doubleSided":true}],
        \\"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},{"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}],
        \\"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":6}],
        \\"buffers":[{"byteLength":42}]}
    ;
    const file = try testFile(a, json, &bin);
    var model = try load(testing.allocator, file);
    defer model.deinit();
    try testing.expectEqual(@as(usize, 1), model.parts.len);
    const part = model.parts[0];
    try testing.expectEqual(@as(usize, 3), part.mesh.indices.len);
    try testing.expect(part.mesh.two_sided);
    try testing.expectEqual(@as(u8, 255), part.material.base_color.r);
    try testing.expectEqual(@as(u8, 0), part.material.base_color.g);
    try testing.expectApproxEqAbs(@as(f32, 0.25), part.material.roughness, 1e-6);
    // Flat normal: +z in the mesh.
    try testing.expectApproxEqAbs(@as(f32, 1), part.mesh.vertices[0].normal[2], 1e-6);
    // (1, 0, 0) scaled twice, turned a quarter about y (+x to -z), moved
    // back 1: (0, 0, -3).
    const p = part.world.point(.{ 1, 0, 0 });
    try testing.expectApproxEqAbs(@as(f32, 0), p[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -3), p[2], 1e-4);

    // Not a .glb, or out of bounds: refused, not read past.
    try testing.expectError(error.InvalidModel, load(testing.allocator, "nope"));
    const short = try testFile(a, json, bin[0..20]);
    var none = try load(testing.allocator, short);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.parts.len);
}
