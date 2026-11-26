// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! 3D scenes (`View3D`): `Model`s (built-in meshes: a cube, a sphere, a
//! plane) seen by a `PerspectiveCamera`, lit by `DirectionalLight`s and
//! `PointLight`s, drawn by raster3d.zig into an image the element shows
//! like any other. Nodes placed in a `Node` or a `Model` move with it.
//!
//! The scene is read while the view draws, so a change to any of its
//! nodes' properties redraws it. Renderers that draw 3D (Metal) draw it
//! themselves, at the window's resolution; for the others it is drawn on
//! the CPU at twice the element's size (smoothed when shown smaller),
//! when they ask for its picture. Either is kept while the scene is the
//! same.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const Callback = @import("callbacks.zig").Callback;
const input = @import("input.zig");
const Window = @import("window.zig").Window;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const ItemVTable = item_mod.ItemVTable;
const ItemRenderer = @import("rendering.zig").ItemRenderer;
const graphics = @import("graphics.zig");
const Color = graphics.Color;
const Rgba8 = graphics.Rgba8;
const image = @import("image.zig");
const raster = @import("raster3d.zig");
const gltf = @import("gltf.zig");
const Mat = raster.Mat;
const Vec3 = raster.Vec3;

const log = std.log.scoped(.zigulee_view3d);

fn parentOf(comptime T: type, i: *Item) *T {
    return @alignCast(@fieldParentPtr("item", i));
}

/// Where a node is and how it is turned (degrees: `yaw` about y, then
/// `pitch` about x, then `roll` about z), in its parent's coordinates.
const Placement = struct {
    position_x: Property(f32) = .init(0),
    position_y: Property(f32) = .init(0),
    position_z: Property(f32) = .init(0),
    pitch: Property(f32) = .init(0),
    yaw: Property(f32) = .init(0),
    roll: Property(f32) = .init(0),

    fn deinit(self: *Placement) void {
        inline for (@typeInfo(Placement).@"struct".fields) |f| @field(self, f.name).deinit();
    }

    fn position(self: *Placement) Vec3 {
        return .{ self.position_x.get(), self.position_y.get(), self.position_z.get() };
    }

    fn matrix(self: *Placement, size: Vec3) Mat {
        return Mat.place(self.position(), self.pitch.get(), self.yaw.get(), self.roll.get(), size);
    }
};

/// A group in the scene, drawing nothing: what it holds moves and turns
/// with it.
pub const SceneNode = struct {
    item: Item = .init(&vtable),
    placement: Placement = .{},

    pub fn deinit(self: *SceneNode) void {
        self.item.deinit();
        self.placement.deinit();
    }

    const vtable: ItemVTable = .{ .name = "Node" };
};

/// A built-in mesh.
pub const Mesh = enum { cube, sphere, plane };

/// A model file embedded with `@model-url` (glTF 2.0, binary: `.glb`).
pub const Source = struct {
    bytes: []const u8 = "",

    pub const none: Source = .{};

    pub fn isNone(s: Source) bool {
        return s.bytes.len == 0;
    }

    pub fn eql(a: Source, b: Source) bool {
        return a.bytes.ptr == b.bytes.ptr and a.bytes.len == b.bytes.len;
    }
};

/// A shape in the scene: a `mesh` sized by `size-*` (each 1 by default),
/// in a material: `color` (and `texture`, which multiplies it), how
/// metallic and rough it is. With a `source` (a glTF model), its meshes
/// in their own materials instead, tinted by `color`. A click on it calls
/// `clicked`. Initialize in place with `init`.
pub const SceneModel = struct {
    item: Item = .init(&vtable),
    placement: Placement = .{},
    mesh: Property(Mesh) = .init(.cube),
    source: Property(Source) = .init(.none),
    size_x: Property(f32) = .init(1),
    size_y: Property(f32) = .init(1),
    size_z: Property(f32) = .init(1),
    color: Property(Color) = .init(.rgb(0xffffff)),
    metallic: Property(f32) = .init(0),
    roughness: Property(f32) = .init(0.5),
    texture: Property(?image.Image) = .init(null),
    clicked: Callback(fn () void) = .{},

    gpa: ?Allocator = null,
    /// `source` read (once for each source).
    loaded: ?gltf.Model = null,
    loaded_from: Source = .none,

    pub fn init(self: *SceneModel, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
    }

    pub fn deinit(self: *SceneModel) void {
        self.item.deinit();
        self.placement.deinit();
        inline for (.{ "mesh", "source", "size_x", "size_y", "size_z", "color", "metallic", "roughness", "texture" }) |f| @field(self, f).deinit();
        if (self.loaded) |*m| m.deinit();
    }

    /// The parts of `source`, read the first time; none if it cannot be.
    fn parts(self: *SceneModel, source: Source) []const gltf.Part {
        if (!source.eql(self.loaded_from)) {
            if (self.loaded) |*m| m.deinit();
            self.loaded = null;
            self.loaded_from = source;
            const gpa = self.gpa orelse return &.{};
            self.loaded = gltf.load(gpa, source.bytes) catch |err| blk: {
                log.info("cannot read the model: {t}", .{err});
                break :blk null;
            };
        }
        return if (self.loaded) |m| m.parts else &.{};
    }

    const vtable: ItemVTable = .{ .name = "Model" };
};

/// Where the scene is seen from: looking along its -z axis, with a
/// vertical `field_of_view` (degrees). By default 4 units back from the
/// middle of the scene.
pub const PerspectiveCamera = struct {
    item: Item = .init(&vtable),
    placement: Placement = .{ .position_z = .init(4) },
    field_of_view: Property(f32) = .init(45),

    pub fn deinit(self: *PerspectiveCamera) void {
        self.item.deinit();
        self.placement.deinit();
        self.field_of_view.deinit();
    }

    const vtable: ItemVTable = .{ .name = "PerspectiveCamera" };
};

/// Light from far away (the sun), shining along its -z axis (turned with
/// `pitch` and `yaw`).
pub const DirectionalLight = struct {
    item: Item = .init(&vtable),
    placement: Placement = .{},
    color: Property(Color) = .init(.rgb(0xffffff)),
    brightness: Property(f32) = .init(1),

    pub fn deinit(self: *DirectionalLight) void {
        self.item.deinit();
        self.placement.deinit();
        self.color.deinit();
        self.brightness.deinit();
    }

    const vtable: ItemVTable = .{ .name = "DirectionalLight" };
};

/// Light from a point (a bulb), half as bright `range` units away.
pub const PointLight = struct {
    item: Item = .init(&vtable),
    placement: Placement = .{},
    color: Property(Color) = .init(.rgb(0xffffff)),
    brightness: Property(f32) = .init(1),
    range: Property(f32) = .init(10),

    pub fn deinit(self: *PointLight) void {
        self.item.deinit();
        self.placement.deinit();
        inline for (.{ "color", "brightness", "range" }) |f| @field(self, f).deinit();
    }

    const vtable: ItemVTable = .{ .name = "PointLight" };
};

/// Each picture drawn is a new version: GPU renderers keep textures by the
/// pixels' address and version.
var versions: u32 = 1;

/// A 3D scene: its `Node`, `Model`, `PerspectiveCamera`,
/// `DirectionalLight` and `PointLight` children, over `background` (transparent by default),
/// with `ambient` light everywhere (times `ambient_brightness`). Without a camera, it is seen from
/// (0, 0, 4); without lights, lit from the upper left. Other children are
/// drawn over it, as usual. Initialize in place with `init`.
pub const View3D = struct {
    item: Item = .init(&vtable),
    background: Property(Color) = .init(.rgba(0x00000000)),
    ambient: Property(Color) = .init(.rgb(0x333333)),
    ambient_brightness: Property(f32) = .init(1),

    gpa: Allocator = undefined,
    instances: std.ArrayList(raster.Instance) = .empty,
    /// The model each instance is (of).
    owners: std.ArrayList(*SceneModel) = .empty,
    lights: std.ArrayList(raster.Light) = .empty,
    /// The camera of the last picture (for clicks).
    camera: raster.Camera = .{},
    /// The model a press went to.
    pressed: ?*SceneModel = null,
    pixels: []Rgba8 = &.{},
    depth: []f32 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// What the picture shows (0: nothing yet), and its size.
    drawn: u64 = 0,
    version: u32 = 0,
    /// The scene as last read, for the renderer.
    source: raster.SceneSource = undefined,
    want_width: u32 = 0,
    want_height: u32 = 0,

    pub fn init(self: *View3D, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
    }

    pub fn deinit(self: *View3D) void {
        self.item.deinit();
        self.background.deinit();
        self.ambient.deinit();
        self.ambient_brightness.deinit();
        self.instances.deinit(self.gpa);
        self.owners.deinit(self.gpa);
        self.lights.deinit(self.gpa);
        self.gpa.free(self.pixels);
        self.gpa.free(self.depth);
    }

    /// Pixels per logical pixel the picture has.
    const oversampling = 2;
    const max_side = 2048;

    const vtable: ItemVTable = .{ .name = "View3D", .render = render, .inputEvent = inputEvent };

    /// The model at `p` (in the view's coordinates), as last drawn.
    pub fn modelAt(self: *View3D, p: @import("geometry.zig").Point) ?*SceneModel {
        const size = self.item.size();
        const scene: raster.Scene = .{ .camera = self.camera, .instances = self.instances.items };
        const k = raster.pick(&scene, size.width, size.height, p.x, p.y) orelse return null;
        return self.owners.items[k];
    }

    /// A click on a model (pressed and released on it) calls its
    /// `clicked`; elsewhere, clicks go on to what is below.
    fn inputEvent(i: *Item, event: input.PointerEvent, _: *Window) input.InputEventResult {
        const self = parentOf(View3D, i);
        switch (event) {
            .pressed => |e| {
                if (e.button != .left) return .ignored;
                self.pressed = self.modelAt(e.position) orelse return .ignored;
                return .grab;
            },
            .released => |e| {
                const was = self.pressed orelse return .ignored;
                self.pressed = null;
                if (e.button == .left and self.modelAt(e.position) == was) was.clicked.call(.{});
                return .accepted;
            },
            .exit => {
                self.pressed = null;
                return .ignored;
            },
            else => return .ignored,
        }
    }

    fn render(i: *Item, r: ItemRenderer) void {
        const self = parentOf(View3D, i);
        const size = i.size();
        if (size.width <= 0 or size.height <= 0) return;
        const w: u32 = @intFromFloat(@min(max_side, @ceil(size.width * oversampling)));
        const h: u32 = @intFromFloat(@min(max_side, @ceil(size.height * oversampling)));
        var scene: raster.Scene = .{ .background = self.background.get(), .ambient = self.ambient.get(), .ambient_brightness = self.ambient_brightness.get() };
        self.instances.clearRetainingCapacity();
        self.owners.clearRetainingCapacity();
        self.lights.clearRetainingCapacity();
        var camera: ?raster.Camera = null;
        self.collect(i, .identity, &camera) catch return;
        scene.camera = camera orelse .{};
        self.camera = scene.camera;
        if (self.lights.items.len == 0) self.lights.append(self.gpa, .{ .directional = .{ .direction = .{ 0.4, -0.6, -1 } } }) catch return;
        scene.instances = self.instances.items;
        scene.lights = self.lights.items;

        const key = hashScene(&scene);
        self.source = .{ .scene = scene, .key = key, .ctx = self, .pictureFn = picture };
        self.want_width = w;
        self.want_height = h;
        // Stands for the picture (drawn when asked for): its version
        // follows the scene and its size.
        const shown = if (self.drawn == key and self.width == w and self.height == h) self.pixels else &.{};
        var hasher: std.hash.Wyhash = .init(key);
        hasher.update(std.mem.asBytes(&[_]u32{ w, h }));
        r.drawImage(size, .{
            .image = .{ .width = w, .height = h, .pixels = shown, .version = @truncate(hasher.final()) },
            .fit = .fill,
            .rendering = .smooth,
            .scene = &self.source,
        });
    }

    /// The scene drawn on the CPU (for renderers that do not draw 3D).
    fn picture(ctx: *anyopaque) ?image.Image {
        const self: *View3D = @ptrCast(@alignCast(ctx));
        const w = self.want_width;
        const h = self.want_height;
        if (w == 0 or h == 0) return null;
        if (self.source.key != self.drawn or w != self.width or h != self.height) {
            if (w != self.width or h != self.height) {
                const n = @as(usize, w) * h;
                const pixels = self.gpa.alloc(Rgba8, n) catch return null;
                const depth = self.gpa.alloc(f32, n) catch {
                    self.gpa.free(pixels);
                    return null;
                };
                self.gpa.free(self.pixels);
                self.gpa.free(self.depth);
                self.pixels = pixels;
                self.depth = depth;
                self.width = w;
                self.height = h;
            }
            raster.render(&self.source.scene, .{ .width = w, .height = h, .pixels = self.pixels, .depth = self.depth });
            self.drawn = self.source.key;
            self.version = versions;
            versions +%= 1;
        }
        return .{ .width = w, .height = h, .pixels = self.pixels, .version = self.version };
    }

    /// The scene's nodes under `parent` (placed by `world`).
    fn collect(self: *View3D, parent: *Item, world: Mat, camera: *?raster.Camera) Allocator.Error!void {
        var children = parent.children();
        while (children.next()) |c| {
            if (c.vtable == &SceneNode.vtable) {
                const n = parentOf(SceneNode, c);
                if (!c.visible.get()) continue;
                try self.collect(c, world.mul(n.placement.matrix(.{ 1, 1, 1 })), camera);
            } else if (c.vtable == &SceneModel.vtable) {
                const m = parentOf(SceneModel, c);
                if (!c.visible.get()) continue;
                const placed = world.mul(m.placement.matrix(.{ 1, 1, 1 }));
                const sized = placed.mul(.scaling(.{ m.size_x.get(), m.size_y.get(), m.size_z.get() }));
                const source = m.source.get();
                if (!source.isNone()) {
                    const tint = m.color.get();
                    for (m.parts(source)) |part| {
                        var material = part.material;
                        material.base_color = multiply(material.base_color, tint);
                        try self.instances.append(self.gpa, .{ .mesh = part.mesh, .world = sized.mul(part.world), .material = material });
                        try self.owners.append(self.gpa, m);
                    }
                } else {
                    const mesh = switch (m.mesh.get()) {
                        .cube => raster.cube,
                        .sphere => raster.sphere(),
                        .plane => raster.plane,
                    };
                    try self.instances.append(self.gpa, .{
                        .mesh = mesh,
                        .world = sized,
                        .material = .{ .base_color = m.color.get(), .metallic = m.metallic.get(), .roughness = m.roughness.get(), .texture = m.texture.get() },
                    });
                    try self.owners.append(self.gpa, m);
                }
                // Its children move with it (not sized with it).
                try self.collect(c, placed, camera);
            } else if (c.vtable == &PerspectiveCamera.vtable) {
                const cam = parentOf(PerspectiveCamera, c);
                if (camera.* == null) camera.* = .{ .world = world.mul(cam.placement.matrix(.{ 1, 1, 1 })), .field_of_view = cam.field_of_view.get() };
            } else if (c.vtable == &DirectionalLight.vtable) {
                const l = parentOf(DirectionalLight, c);
                if (!c.visible.get()) continue;
                const dir = world.mul(l.placement.matrix(.{ 1, 1, 1 })).vector(.{ 0, 0, -1 });
                try self.lights.append(self.gpa, .{ .directional = .{ .direction = dir, .color = l.color.get(), .brightness = l.brightness.get() } });
            } else if (c.vtable == &PointLight.vtable) {
                const l = parentOf(PointLight, c);
                if (!c.visible.get()) continue;
                try self.lights.append(self.gpa, .{ .point = .{ .position = world.point(l.placement.position()), .color = l.color.get(), .brightness = l.brightness.get(), .range = l.range.get() } });
            }
        }
    }

    fn multiply(a: Color, b: Color) Color {
        const ch = struct {
            fn f(x: u8, y: u8) u8 {
                return @intCast((@as(u16, x) * y + 127) / 255);
            }
        }.f;
        return .{ .r = ch(a.r, b.r), .g = ch(a.g, b.g), .b = ch(a.b, b.b), .a = ch(a.a, b.a) };
    }

    fn hashScene(scene: *const raster.Scene) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        hasher.update(std.mem.asBytes(&scene.camera));
        hasher.update(std.mem.asBytes(&[_]Color{ scene.ambient, scene.background }));
        hasher.update(std.mem.asBytes(&scene.ambient_brightness));
        for (scene.instances) |inst| {
            hasher.update(std.mem.asBytes(&@intFromPtr(inst.mesh.vertices.ptr)));
            hasher.update(std.mem.asBytes(&inst.world));
            const m = inst.material;
            hasher.update(std.mem.asBytes(&[_]f32{ m.metallic, m.roughness }));
            hasher.update(std.mem.asBytes(&m.base_color));
            if (m.texture) |t| {
                hasher.update(std.mem.asBytes(&[_]usize{ @intFromPtr(t.pixels.ptr), t.pixels.len, t.width, t.version }));
            }
        }
        // Field by field: a Vec3's fourth lane, a union's tail past its
        // smaller field and the padding after its tag are undefined.
        for (scene.lights) |l| switch (l) {
            .directional => |d| {
                hasher.update(std.mem.asBytes(&[_]f32{ 0, d.direction[0], d.direction[1], d.direction[2], d.brightness }));
                hasher.update(std.mem.asBytes(&d.color));
            },
            .point => |p| {
                hasher.update(std.mem.asBytes(&[_]f32{ 1, p.position[0], p.position[1], p.position[2], p.brightness, p.range }));
                hasher.update(std.mem.asBytes(&p.color));
            },
        };
        // Never 0 (nothing drawn).
        return hasher.final() | 1;
    }
};

// ---- Tests ----

const testing = std.testing;
const DisplayList = @import("rendering.zig").DisplayList;

test "a 3D view: its scene drawn as an image, kept while the same, redrawn when a node changes" {
    const gpa = testing.allocator;
    var window: Window = undefined;
    window.init(gpa, .{ .width = 40, .height = 30 });
    defer window.deinit();
    var view: View3D = undefined;
    view.init(gpa);
    defer view.deinit();
    var cube: SceneModel = .{};
    defer cube.deinit();
    var light: PointLight = .{};
    defer light.deinit();
    window.rootItem().appendChild(&view.item);
    view.item.appendChildren(&.{ &cube.item, &light.item });
    view.item.width.set(40);
    view.item.height.set(30);
    cube.color.set(.rgb(0xff0000));
    light.placement.position_z.set(3);

    var list: DisplayList = .init(gpa, .fromOriginSize(.{}, window.size()));
    defer list.deinit();
    _ = try window.render(list.renderer(), .full);
    // The scene, its picture drawn when asked for: twice the size, red in
    // the middle.
    const pictureOf = struct {
        fn f(l: *const DisplayList) ?image.Image {
            for (l.commands.items) |c| if (c == .image) {
                if (c.image.style.scene) |sc| return sc.picture();
            };
            return null;
        }
    }.f;
    try testing.expectEqual(@as(u32, 0), view.width);
    const img = pictureOf(&list).?;
    try testing.expectEqual(@as(u32, 80), img.width);
    try testing.expectEqual(@as(u32, 60), img.height);
    const mid = img.pixels[30 * 80 + 40];
    try testing.expect(mid.r > mid.g + 100 and mid.a == 255);
    try testing.expectEqual(@as(u8, 0), img.pixels[0].a);
    const first = view.version;

    // Nothing changed: the same picture.
    list.reset(.fromOriginSize(.{}, window.size()));
    _ = try window.render(list.renderer(), .full);
    _ = pictureOf(&list);
    try testing.expectEqual(first, view.version);

    // A node changed: redrawn (the cube turned green).
    cube.color.set(.rgb(0x00ff00));
    list.reset(.fromOriginSize(.{}, window.size()));
    const region = try window.render(list.renderer(), .partial);
    try testing.expect(!region.isEmpty());
    _ = pictureOf(&list);
    try testing.expect(view.version != first);
    try testing.expect(view.pixels[30 * 80 + 40].g > view.pixels[30 * 80 + 40].r + 100);

    // Moved away: smaller, the middle's edge now the background.
    cube.placement.position_z.set(-30);
    list.reset(.fromOriginSize(.{}, window.size()));
    _ = try window.render(list.renderer(), .partial);
    _ = pictureOf(&list);
    try testing.expectEqual(@as(u8, 0), view.pixels[30 * 80 + 52].a);
    try testing.expect(view.pixels[30 * 80 + 40].a == 255);
}

test "a click on a model: its clicked called, the nearest one under the pointer" {
    const gpa = testing.allocator;
    var window: Window = undefined;
    window.init(gpa, .{ .width = 100, .height = 100 });
    defer window.deinit();
    var view: View3D = undefined;
    view.init(gpa);
    defer view.deinit();
    var back: SceneModel = .{};
    defer back.deinit();
    var front: SceneModel = .{};
    defer front.deinit();
    window.rootItem().appendChild(&view.item);
    view.item.appendChildren(&.{ &back.item, &front.item });
    view.item.width.set(100);
    view.item.height.set(100);
    front.mesh.set(.sphere);
    front.placement.position_z.set(1.5);
    front.size_x.set(0.3);
    front.size_y.set(0.3);
    front.size_z.set(0.3);

    var list: DisplayList = .init(gpa, .fromOriginSize(.{}, window.size()));
    defer list.deinit();
    _ = try window.render(list.renderer(), .full);
    const Count = struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    };
    var backs: usize = 0;
    var fronts: usize = 0;
    back.clicked.setHandler(&backs, Count.f);
    front.clicked.setHandler(&fronts, Count.f);
    const click = struct {
        fn at(w: *Window, x: f32, y: f32) void {
            w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            w.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
        }
    }.at;
    click(&window, 50, 50);
    try testing.expectEqual(@as(usize, 1), fronts);
    try testing.expectEqual(@as(usize, 0), backs);
    click(&window, 50, 40);
    try testing.expectEqual(@as(usize, 1), backs);
    // Nothing there: nobody's.
    click(&window, 3, 3);
    try testing.expectEqual(@as(usize, 1), backs);
    try testing.expectEqual(@as(usize, 1), fronts);
    // Pressed on one, released on another: not a click.
    window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 50, .y = 50 } } });
    window.dispatchPointer(.{ .released = .{ .position = .{ .x = 50, .y = 40 } } });
    try testing.expectEqual(@as(usize, 1), fronts);
    try testing.expectEqual(@as(usize, 1), backs);
}
