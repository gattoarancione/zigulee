// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Maps: `MapView` shows a slippy map of web tiles (Web Mercator, 256
//! pixels square, from a URL template: OpenStreetMap's by default), loaded
//! in the background, kept in memory and on disk (`StandardPaths`' cache,
//! a week), while lower zoom levels stand in for tiles still coming. On
//! screens of two pixels a point, it takes the next zoom level's tiles at
//! half their size (or a `{r}` template's `@2x` ones), staying sharp. It is
//! panned by dragging, zoomed by the wheel, pinching and double-clicking.
//!
//! `MapItem` children stand at a coordinate (markers: any elements in
//! them), `MapPolyline` children draw lines and outlines through
//! coordinates. On the web, tiles come through the browser (the server
//! must allow other sites' pages: OpenStreetMap's does). Without threads
//! elsewhere (microcontrollers) no tiles come from the network; `file://`
//! templates load anywhere there are files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const Callback = @import("callbacks.zig").Callback;
const model = @import("model.zig");
const Model = model.Model;
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Rect = geometry.Rect;
const Size = geometry.Size;
const graphics = @import("graphics.zig");
const Brush = graphics.Brush;
const Color = graphics.Color;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const ItemVTable = item_mod.ItemVTable;
const rendering = @import("rendering.zig");
const ItemRenderer = rendering.ItemRenderer;
const input = @import("input.zig");
const Window = @import("window.zig").Window;
const loader = @import("image_loader.zig");
const paths = @import("paths.zig");
const time = @import("time.zig");
const PinchArea = @import("gestures.zig").PinchArea;
const items = @import("items.zig");
const text_mod = @import("text/text.zig");

const log = std.log.scoped(.zigulee_map);

pub const tile_size = 256;
/// Web Mercator's limit: the map is square.
pub const max_latitude = 85.0511287798;
pub const osm_tiles = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";
pub const osm_attribution = "© OpenStreetMap contributors";

/// Tiles kept in memory per map (a quarter megabyte each).
const max_tiles = 160;
/// Tiles loading at once, in all.
const max_loading = 6;
/// A tile that failed is asked for again after this long (ms).
const retry_ms = 15_000;

// ---- Web Mercator ----

/// Where `latitude`, `longitude` are on the world, from 0 to 1 (west to
/// east, north to south).
pub fn project(latitude: f64, longitude: f64) [2]f64 {
    const lat = std.math.degreesToRadians(std.math.clamp(latitude, -max_latitude, max_latitude));
    const x = (longitude + 180) / 360;
    const y = (1 - @log(@tan(lat) + 1 / @cos(lat)) / std.math.pi) / 2;
    return .{ x, y };
}

/// The latitude and longitude at world position `x`, `y` (0 to 1).
pub fn unproject(x: f64, y: f64) [2]f64 {
    const n = std.math.pi * (1 - 2 * y);
    const lat = std.math.radiansToDegrees(std.math.atan(std.math.sinh(n)));
    return .{ lat, x * 360 - 180 };
}

// ---- The tiles ----

const TileKey = struct { z: u8, x: u32, y: u32 };

const Tile = struct {
    state: enum { loading, ready, failed },
    loaded: ?loader.Loaded = null,
    request: ?*loader.Request = null,
    /// The frame it was last drawn in.
    used: u32 = 0,
    failed_at: u64 = 0,
};

/// Requests in flight, in all maps.
var loading_count: usize = 0;
var maps: std.ArrayList(*MapView) = .empty;

/// `update` and `busy`, for the event loop: set by the first map, so that
/// programs without maps carry none of their code.
pub var service: ?struct { update: *const fn () void, busy: *const fn () bool } = null;

/// Starts the tiles maps asked for and takes in those that came. Call on
/// the UI thread once per event loop iteration.
pub fn update() void {
    for (maps.items) |m| m.poll();
}

/// Whether tiles are loading (the event loop keeps waking up for
/// `update`).
pub fn busy() bool {
    if (loading_count > 0) return true;
    for (maps.items) |m| if (m.wanted.items.len > 0) return true;
    return false;
}

/// `template` with `{z}`, `{x}` and `{y}` filled in, and `{r}` with
/// `@2x` for `dense` screens (else nothing).
fn tileUrl(gpa: Allocator, template: []const u8, k: TileKey, dense: bool) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{' and i + 2 < template.len and template[i + 2] == '}') {
            const v: ?u32 = switch (template[i + 1]) {
                'z' => k.z,
                'x' => k.x,
                'y' => k.y,
                else => null,
            };
            if (v) |n| {
                try out.print(gpa, "{d}", .{n});
                i += 3;
                continue;
            }
            if (template[i + 1] == 'r') {
                if (dense) try out.appendSlice(gpa, "@2x");
                i += 3;
                continue;
            }
        }
        try out.append(gpa, template[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

// ---- MapView ----

/// A slippy map (see the file's comment). Initialize in place with
/// `init`.
pub const MapView = struct {
    item: Item = .init(&vtable),
    /// The coordinate in the middle.
    latitude: Property(f32) = .init(0),
    longitude: Property(f32) = .init(0),
    /// 0: the world in one tile; each step doubles the scale.
    zoom: Property(f32) = .init(2),
    minimum_zoom: Property(f32) = .init(0),
    maximum_zoom: Property(f32) = .init(19),
    /// Where tiles come from: `{z}`, `{x}` and `{y}` are filled in (empty:
    /// none).
    tile_url: Property([]const u8) = .init(osm_tiles),
    /// Shown in the bottom right corner (the tiles' terms usually ask for
    /// it; empty: nothing).
    attribution: Property([]const u8) = .init(osm_attribution),
    /// Said to tile servers (empty: the application's name and zigulee).
    user_agent: Property([]const u8) = .init(""),
    /// Dragging, the wheel, pinching and double-clicking move it.
    interactive: Property(bool) = .init(true),
    /// On screens of 1.5 pixels a point or more: the next zoom level's
    /// tiles at half their size (sharp, their labels smaller), or with a
    /// `{r}` in `tile_url`, the server's `@2x` ones.
    high_density: Property(bool) = .init(true),
    /// Under the tiles.
    background: Property(Brush) = .init(.color(.rgb(0xe8e4dc))),
    /// A click (not a drag): where, as latitude and longitude.
    clicked: Callback(fn (f32, f32) void) = .{},

    gpa: Allocator = undefined,
    /// Pinches (a child of its own, under the others).
    pinch: PinchArea = .{},
    pinch_zoom: f32 = 0,
    tiles: std.AutoHashMapUnmanaged(TileKey, Tile) = .empty,
    /// The template the tiles are from (and whether dense).
    tiles_from: u64 = 0,
    /// Tiles for a dense screen from a `{r}` template (`@2x`).
    retina: bool = false,
    /// Tiles to load, the last drawn view's, nearest the middle last.
    wanted: std.ArrayList(TileKey) = .empty,
    frame: u32 = 0,
    /// Bumped when tiles come (rendering depends on it).
    revision: Property(u32) = .init(0),
    /// (8-aligned: as GCC lays it out for the ESP32-S3, whose firmware
    /// is Zig's C.)
    drag: ?struct { from: Point, center: [2]f64 align(8), moved: bool } = null,
    last_click: ?struct { at: Point, ms: u64 } = null,

    const vtable: ItemVTable = .{
        .name = "MapView",
        .render = render,
        .inputEvent = inputEvent,
        .clipsChildren = clipsChildren,
    };

    pub fn init(self: *MapView, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        service = .{ .update = update, .busy = busy };
        maps.append(gpa, self) catch {};
        self.item.appendChild(&self.pinch.item);
        self.pinch.item.width.setBinding(gpa, self, mapWidth) catch {};
        self.pinch.item.height.setBinding(gpa, self, mapHeight) catch {};
        self.pinch.started.setHandler(self, pinchStarted);
        self.pinch.updated.setHandler(self, pinchUpdated);
    }

    pub fn deinit(self: *MapView) void {
        for (maps.items, 0..) |m, i| if (m == self) {
            _ = maps.orderedRemove(i);
            break;
        };
        if (maps.items.len == 0) {
            maps.deinit(self.gpa);
            maps = .empty;
        }
        self.clearTiles();
        self.tiles.deinit(self.gpa);
        self.wanted.deinit(self.gpa);
        self.pinch.deinit();
        self.item.deinit();
        inline for (.{ "latitude", "longitude", "zoom", "minimum_zoom", "maximum_zoom", "tile_url", "attribution", "user_agent", "interactive", "background", "revision" }) |f| @field(self, f).deinit();
    }

    fn mapWidth(self: *MapView) f32 {
        return self.item.width.get();
    }

    fn mapHeight(self: *MapView) f32 {
        return self.item.height.get();
    }

    fn clipsChildren(_: *Item) bool {
        return true;
    }

    fn clearTiles(self: *MapView) void {
        var it = self.tiles.valueIterator();
        while (it.next()) |t| self.dropTile(t);
        self.tiles.clearRetainingCapacity();
    }

    fn dropTile(_: *MapView, t: *Tile) void {
        if (t.request) |r| {
            r.cancel();
            loading_count -= 1;
        }
        if (t.loaded) |*l| l.deinit();
    }

    // ---- Where things are ----

    /// The zoom shown (within its limits).
    fn zoomShown(self: *MapView) f64 {
        const lo = @max(0, self.minimum_zoom.get());
        const hi = @max(lo, @min(22, self.maximum_zoom.get()));
        return std.math.clamp(self.zoom.get(), lo, hi);
    }

    /// The world's size in pixels at the zoom shown.
    fn worldSize(self: *MapView) f64 {
        return tile_size * @exp2(self.zoomShown());
    }

    /// The middle, in world pixels.
    fn centerPixels(self: *MapView) [2]f64 {
        const w = project(self.latitude.get(), self.longitude.get());
        const s = self.worldSize();
        return .{ w[0] * s, w[1] * s };
    }

    /// Where `latitude`, `longitude` show in the map (its coordinates):
    /// of the world's copies side by side, the one nearest the middle.
    pub fn pointAt(self: *MapView, latitude: f32, longitude: f32) Point {
        const s = self.worldSize();
        const c = self.centerPixels();
        const w = project(latitude, longitude);
        var dx = w[0] * s - c[0];
        dx -= @round(dx / s) * s;
        return .{
            .x = @floatCast(dx + self.item.width.get() / 2),
            .y = @floatCast(w[1] * s - c[1] + self.item.height.get() / 2),
        };
    }

    /// The latitude and longitude at `p` (the map's coordinates).
    pub fn coordinateAt(self: *MapView, p: Point) [2]f32 {
        const s = self.worldSize();
        const c = self.centerPixels();
        const x = (c[0] + p.x - self.item.width.getUntracked() / 2) / s;
        const y = (c[1] + p.y - self.item.height.getUntracked() / 2) / s;
        const ll = unproject(x - @floor(x), std.math.clamp(y, 0, 1));
        return .{ @floatCast(ll[0]), @floatCast(ll[1]) };
    }

    /// Centers the map on world pixel `c` (at the zoom shown).
    fn setCenterPixels(self: *MapView, c: [2]f64) void {
        const s = self.worldSize();
        const x = c[0] / s;
        const ll = unproject(x - @floor(x), std.math.clamp(c[1] / s, 0, 1));
        self.latitude.set(@floatCast(ll[0]));
        self.longitude.set(@floatCast(ll[1]));
    }

    /// Zooms to `z`, keeping what is at `p` (the map's coordinates) there.
    pub fn zoomAround(self: *MapView, z: f32, p: Point) void {
        const half: [2]f64 = .{ self.item.width.getUntracked() / 2, self.item.height.getUntracked() / 2 };
        const before = self.centerPixels();
        const s0 = self.worldSize();
        const at: [2]f64 = .{ (before[0] + p.x - half[0]) / s0, (before[1] + p.y - half[1]) / s0 };
        self.zoom.set(std.math.clamp(z, self.minimum_zoom.getUntracked(), self.maximum_zoom.getUntracked()));
        const s1 = self.worldSize();
        self.setCenterPixels(.{ at[0] * s1 - p.x + half[0], at[1] * s1 - p.y + half[1] });
    }

    pub fn zoomIn(self: *MapView) void {
        self.zoomAround(@round(self.zoom.getUntracked()) + 1, self.middle());
    }

    pub fn zoomOut(self: *MapView) void {
        self.zoomAround(@round(self.zoom.getUntracked()) - 1, self.middle());
    }

    fn middle(self: *MapView) Point {
        return .{ .x = self.item.width.getUntracked() / 2, .y = self.item.height.getUntracked() / 2 };
    }

    // ---- Drawing ----

    fn render(i: *Item, r: ItemRenderer) void {
        const self: *MapView = @alignCast(@fieldParentPtr("item", i));
        const size = i.size();
        _ = self.revision.get();
        r.drawRectangle(size, .{ .background = self.background.get() });
        self.frame +%= 1;
        self.drawTiles(r, size);
        self.drawAttribution(r, size);
    }

    fn drawTiles(self: *MapView, r: ItemRenderer, size: Size) void {
        const template = self.tile_url.get();
        const ratio = if (self.item.window()) |w| w.pixel_ratio.get() else 1;
        const dense = self.high_density.get() and ratio >= 1.5;
        const own_scale = std.mem.indexOf(u8, template, "{r}") != null;
        self.retina = dense and own_scale;
        const from = std.hash.Wyhash.hash(@intFromBool(self.retina), template);
        if (from != self.tiles_from) {
            self.clearTiles();
            self.tiles_from = from;
        }
        self.wanted.clearRetainingCapacity();
        if (template.len == 0 or size.width <= 0 or size.height <= 0) return;
        const z = self.zoomShown();
        // Dense, without tiles of their own for it: a level further in
        // (as far as there are levels).
        const deeper: f64 = if (dense and !own_scale) 1 else 0;
        const top_level = std.math.clamp(@round(self.maximum_zoom.get()), 0, 22);
        const level: u8 = @intFromFloat(std.math.clamp(@round(z + deeper), 0, @max(top_level, @round(z))));
        const count: i64 = @as(i64, 1) << @intCast(level);
        const scale = @exp2(z - @as(f64, @floatFromInt(level)));
        const step = tile_size * scale;
        const c = self.centerPixels();
        const left = c[0] - size.width / 2;
        const top = c[1] - size.height / 2;
        const x0: i64 = @intFromFloat(@floor(left / step));
        const x1: i64 = @intFromFloat(@floor((left + size.width) / step));
        const y0: i64 = @max(0, @as(i64, @intFromFloat(@floor(top / step))));
        const y1: i64 = @min(count - 1, @as(i64, @intFromFloat(@floor((top + size.height) / step))));
        if (x1 - x0 > 64 or y1 - y0 > 64) return;
        const mid: [2]f64 = .{ (left + size.width / 2) / step, (top + size.height / 2) / step };
        var ty = y0;
        while (ty <= y1) : (ty += 1) {
            var tx = x0;
            while (tx <= x1) : (tx += 1) {
                // Edges on whole pixels: no seams between tiles.
                const ax = @round(@as(f64, @floatFromInt(tx)) * step - left);
                const ay = @round(@as(f64, @floatFromInt(ty)) * step - top);
                const bx = @round(@as(f64, @floatFromInt(tx + 1)) * step - left);
                const by = @round(@as(f64, @floatFromInt(ty + 1)) * step - top);
                const rect: Rect = .{ .x = @floatCast(ax), .y = @floatCast(ay), .width = @floatCast(bx - ax), .height = @floatCast(by - ay) };
                const key: TileKey = .{ .z = level, .x = @intCast(@mod(tx, count)), .y = @intCast(ty) };
                if (self.readyTile(key)) |img| {
                    drawImageIn(r, rect, img);
                    continue;
                }
                self.want(key);
                self.drawStandIn(r, rect, key);
            }
        }
        // Nearest the middle last: loaded first.
        const Order = struct {
            mid: [2]f64,
            fn far(o: @This(), k: TileKey) f64 {
                const dx = @as(f64, @floatFromInt(k.x)) + 0.5 - o.mid[0];
                const dy = @as(f64, @floatFromInt(k.y)) + 0.5 - o.mid[1];
                return dx * dx + dy * dy;
            }
            fn lessThan(o: @This(), a: TileKey, b: TileKey) bool {
                return o.far(a) > o.far(b);
            }
        };
        std.mem.sort(TileKey, self.wanted.items, Order{ .mid = .{ @mod(mid[0], @as(f64, @floatFromInt(count))), mid[1] } }, Order.lessThan);
    }

    fn drawImageIn(r: ItemRenderer, rect: Rect, img: @import("image.zig").Image) void {
        r.save();
        defer r.restore();
        r.translate(.{ .x = rect.x, .y = rect.y });
        r.drawImage(.{ .width = rect.width, .height = rect.height }, .{ .image = img, .fit = .fill });
    }

    fn readyTile(self: *MapView, key: TileKey) ?@import("image.zig").Image {
        const t = self.tiles.getPtr(key) orelse return null;
        if (t.state != .ready) return null;
        t.used = self.frame;
        return t.loaded.?.image;
    }

    /// Asks for `key`'s tile (unless it is coming, or failed lately).
    fn want(self: *MapView, key: TileKey) void {
        if (self.tiles.getPtr(key)) |t| {
            t.used = self.frame;
            if (t.state == .loading) return;
            if (t.state == .failed and time.now() -| t.failed_at < retry_ms) return;
        }
        self.wanted.append(self.gpa, key) catch {};
    }

    /// A lower zoom level's tile, scaled, while `key`'s is coming.
    fn drawStandIn(self: *MapView, r: ItemRenderer, rect: Rect, key: TileKey) void {
        var up: u8 = 1;
        while (up <= 5 and up <= key.z) : (up += 1) {
            const parent: TileKey = .{ .z = key.z - up, .x = key.x >> @intCast(up), .y = key.y >> @intCast(up) };
            const img = self.readyTile(parent) orelse continue;
            const n: f32 = @floatFromInt(@as(u32, 1) << @intCast(up));
            const fx: f32 = @floatFromInt(key.x - (parent.x << @intCast(up)));
            const fy: f32 = @floatFromInt(key.y - (parent.y << @intCast(up)));
            r.save();
            defer r.restore();
            if (!r.clip(rect)) return;
            drawImageIn(r, .{ .x = rect.x - fx * rect.width, .y = rect.y - fy * rect.height, .width = rect.width * n, .height = rect.height * n }, img);
            return;
        }
    }

    fn drawAttribution(self: *MapView, r: ItemRenderer, size: Size) void {
        const text = self.attribution.get();
        if (text.len == 0) return;
        const font = items.resolveFont(&self.item, null, "", 400) orelse return;
        const font_size = 11;
        const m = text_mod.measure(font, text, font_size, null);
        const pad = 3;
        const box: Size = .{ .width = @ceil(m.width) + 2 * pad, .height = @ceil(m.height) + pad };
        r.save();
        defer r.restore();
        r.translate(.{ .x = size.width - box.width, .y = size.height - box.height });
        r.drawRectangle(box, .{ .background = .color(.rgba(0xffffffb0)) });
        r.translate(.{ .x = pad, .y = pad / 2 });
        r.drawText(.{ .width = box.width - 2 * pad, .height = box.height }, .{
            .text = text,
            .font = font,
            .color = .color(.rgb(0x333333)),
            .font_size = font_size,
            .fallbacks = items.fallbackFonts(&self.item),
        });
    }

    // ---- Loading ----

    fn userAgent(self: *MapView, buf: []u8) []const u8 {
        const ua = self.user_agent.getUntracked();
        if (ua.len > 0) return ua;
        const app = paths.applicationName();
        return std.fmt.bufPrint(buf, "{s} (zigulee MapView)", .{if (app.len > 0) app else "zigulee"}) catch "zigulee MapView";
    }

    fn cachePath(self: *MapView, url: []const u8) ?[]u8 {
        const dir = paths.get(self.gpa, .app_cache) catch return null;
        defer self.gpa.free(dir);
        if (dir.len == 0) return null;
        return std.fmt.allocPrint(self.gpa, "{s}/map-tiles/{x:0>16}", .{ dir, std.hash.Wyhash.hash(0, url) }) catch null;
    }

    /// Takes in tiles that came, starts those wanted.
    fn poll(self: *MapView) void {
        var came = false;
        var it = self.tiles.valueIterator();
        while (it.next()) |t| {
            const r = t.request orelse continue;
            const res = r.poll() orelse continue;
            r.cancel();
            t.request = null;
            loading_count -= 1;
            came = true;
            if (res) |l| {
                t.loaded = l;
                t.state = .ready;
            } else |err| {
                log.info("tile not loaded: {t}", .{err});
                t.state = .failed;
                t.failed_at = time.now();
            }
        }
        while (loading_count < max_loading) {
            const key = self.wanted.pop() orelse break;
            self.start(key);
        }
        if (came) {
            self.evict();
            self.revision.set(self.revision.getUntracked() +% 1);
        }
    }

    fn start(self: *MapView, key: TileKey) void {
        const url = tileUrl(self.gpa, self.tile_url.getUntracked(), key, self.retina) catch return;
        defer self.gpa.free(url);
        const cache = self.cachePath(url);
        defer if (cache) |c| self.gpa.free(c);
        var ua_buf: [256]u8 = undefined;
        const r = loader.Request.startWith(self.gpa, url, .{ .user_agent = self.userAgent(&ua_buf), .cache_path = cache }) catch return;
        const gop = self.tiles.getOrPut(self.gpa, key) catch {
            r.cancel();
            return;
        };
        if (gop.found_existing) self.dropTile(gop.value_ptr);
        gop.value_ptr.* = .{ .state = .loading, .request = r, .used = self.frame };
        loading_count += 1;
    }

    /// Keeps at most `max_tiles`: those drawn longest ago go.
    fn evict(self: *MapView) void {
        while (self.tiles.count() > max_tiles) {
            var oldest: ?TileKey = null;
            var age: u32 = 0;
            var it = self.tiles.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.state == .loading) continue;
                const a = self.frame -% e.value_ptr.used;
                if (oldest == null or a > age) {
                    oldest = e.key_ptr.*;
                    age = a;
                }
            }
            const k = oldest orelse return;
            if (age == 0) return; // all on screen
            self.dropTile(self.tiles.getPtr(k).?);
            _ = self.tiles.remove(k);
        }
    }

    // ---- Moving it ----

    fn inputEvent(i: *Item, event: input.PointerEvent, _: *Window) input.InputEventResult {
        const self: *MapView = @alignCast(@fieldParentPtr("item", i));
        if (!self.interactive.get()) return .ignored;
        switch (event) {
            .pressed => |e| {
                if (e.button != .left) return .ignored;
                self.drag = .{ .from = e.position, .center = self.centerPixels(), .moved = false };
                return .grab;
            },
            .moved => |e| {
                const d = &(self.drag orelse return .ignored);
                const dx = e.position.x - d.from.x;
                const dy = e.position.y - d.from.y;
                if (!d.moved and dx * dx + dy * dy < 16) return .grab;
                d.moved = true;
                self.setCenterPixels(.{ d.center[0] - dx, d.center[1] - dy });
                return .grab;
            },
            .released => |e| {
                const d = self.drag orelse return .ignored;
                self.drag = null;
                if (d.moved) return .accepted;
                const now = time.now();
                // A second click soon after, near the first: zoom in there.
                if (self.last_click) |c| if (now -| c.ms < 400 and @abs(c.at.x - e.position.x) < 8 and @abs(c.at.y - e.position.y) < 8) {
                    self.last_click = null;
                    self.zoomAround(@round(self.zoom.getUntracked()) + 1, e.position);
                    return .accepted;
                };
                self.last_click = .{ .at = e.position, .ms = now };
                const ll = self.coordinateAt(e.position);
                self.clicked.call(.{ ll[0], ll[1] });
                return .accepted;
            },
            .wheel => |w| {
                if (w.delta.y == 0) return .ignored;
                // About a step for a mouse wheel's notch.
                const steps = std.math.clamp(-w.delta.y / 100, -1, 1);
                self.zoomAround(self.zoom.getUntracked() + steps, w.position);
                return .accepted;
            },
            .exit => {
                return if (self.drag != null) .grab else .ignored;
            },
        }
    }

    fn pinchStarted(self: *MapView) void {
        self.pinch_zoom = self.zoom.getUntracked();
        self.drag = null;
    }

    fn pinchUpdated(self: *MapView) void {
        if (!self.interactive.getUntracked()) return;
        const s = self.pinch.scale.getUntracked();
        if (s <= 0) return;
        self.zoomAround(self.pinch_zoom + std.math.log2(s), .{ .x = self.pinch.center_x.getUntracked(), .y = self.pinch.center_y.getUntracked() });
    }
};

/// The map a map child is in (its parent, through repeaters and
/// conditionals, which stand where their parent is), if it is.
fn mapOf(i: *Item) ?*MapView {
    var p = i.parent orelse return null;
    while (p.vtable.flatten_in_layout) p = p.parent orelse return null;
    if (p.vtable != &MapView.vtable) return null;
    return @alignCast(@fieldParentPtr("item", p));
}

// ---- MapItem ----

/// Stands at `latitude`, `longitude` in its `MapView`, the point
/// `anchor-x`, `anchor-y` of it (fractions of its size; 0.5, 0.5 its
/// middle) on the coordinate. Its children are what shows there.
pub const MapItem = struct {
    item: Item = .init(&vtable),
    latitude: Property(f32) = .init(0),
    longitude: Property(f32) = .init(0),
    anchor_x: Property(f32) = .init(0.5),
    anchor_y: Property(f32) = .init(0.5),

    const vtable: ItemVTable = .{ .name = "MapItem" };

    pub fn init(self: *MapItem, gpa: Allocator) void {
        self.* = .{};
        self.item.x.setBinding(gpa, self, placeX) catch {};
        self.item.y.setBinding(gpa, self, placeY) catch {};
    }

    pub fn deinit(self: *MapItem) void {
        self.item.deinit();
        inline for (.{ "latitude", "longitude", "anchor_x", "anchor_y" }) |f| @field(self, f).deinit();
    }

    fn point(self: *MapItem) ?Point {
        const map = mapOf(&self.item) orelse return null;
        return map.pointAt(self.latitude.get(), self.longitude.get());
    }

    fn placeX(self: *MapItem) f32 {
        const p = self.point() orelse return 0;
        return p.x - self.anchor_x.get() * self.item.width.get();
    }

    fn placeY(self: *MapItem) f32 {
        const p = self.point() orelse return 0;
        return p.y - self.anchor_y.get() * self.item.height.get();
    }
};

// ---- MapPolyline ----

/// A line through `coordinates` in its `MapView` (latitude, longitude,
/// latitude, longitude...), in `stroke` `stroke-width` wide; `closed`, an
/// outline, filled with `fill`.
pub const MapPolyline = struct {
    item: Item = .init(&vtable),
    coordinates: Property(Model(f32)) = .init(model.emptyModel(f32)),
    stroke: Property(Brush) = .init(.color(.rgb(0x2563eb))),
    stroke_width: Property(f32) = .init(3),
    fill: Property(Brush) = .init(.transparent),
    closed: Property(bool) = .init(false),

    gpa: Allocator = undefined,
    path: std.ArrayList(u8) = .empty,
    path_key: u64 = 0,

    const vtable: ItemVTable = .{ .name = "MapPolyline", .render = render };

    pub fn init(self: *MapPolyline, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        // Over the whole map.
        self.item.width.setBinding(gpa, self, mapWidth) catch {};
        self.item.height.setBinding(gpa, self, mapHeight) catch {};
    }

    pub fn deinit(self: *MapPolyline) void {
        self.item.deinit();
        inline for (.{ "coordinates", "stroke", "stroke_width", "fill", "closed" }) |f| @field(self, f).deinit();
        self.path.deinit(self.gpa);
    }

    fn mapWidth(self: *MapPolyline) f32 {
        const m = mapOf(&self.item) orelse return 0;
        return m.item.width.get();
    }

    fn mapHeight(self: *MapPolyline) f32 {
        const m = mapOf(&self.item) orelse return 0;
        return m.item.height.get();
    }

    fn render(i: *Item, r: ItemRenderer) void {
        const self: *MapPolyline = @alignCast(@fieldParentPtr("item", i));
        const map = mapOf(i) orelse return;
        const coords = self.coordinates.get();
        const n = coords.rowCount() / 2;
        if (n < 2) return;
        const closed = self.closed.get();
        // Rebuilt when the line or the view changes.
        var h: std.hash.Wyhash = .init(2);
        for (0..2 * n) |k| {
            const v: f32 = coords.rowData(k) orelse 0;
            h.update(std.mem.asBytes(&v));
        }
        const view = [_]f32{ map.latitude.get(), map.longitude.get(), map.zoom.get(), i.width.get(), i.height.get() };
        h.update(std.mem.asBytes(&view));
        h.update(&.{@intFromBool(closed)});
        const key = h.final();
        if (key != self.path_key) {
            self.path_key = key;
            self.path.clearRetainingCapacity();
            for (0..n) |k| {
                const p = map.pointAt(coords.rowData(2 * k) orelse 0, coords.rowData(2 * k + 1) orelse 0);
                self.path.print(self.gpa, "{s}{d:.2} {d:.2}", .{ if (k == 0) "M" else "L", p.x, p.y }) catch {};
            }
            if (closed) self.path.append(self.gpa, 'Z') catch {};
        }
        const size = i.size();
        r.drawPath(size, .{
            .commands = self.path.items,
            .fill = if (closed) self.fill.get() else .transparent,
            .stroke = self.stroke.get(),
            .stroke_width = self.stroke_width.get(),
            .viewbox = .{ .width = size.width, .height = size.height },
            .stretch = true,
            .inset_stroke = false,
        });
    }
};

// ---- Tests ----

const testing = std.testing;
const DisplayList = rendering.DisplayList;
const png = @import("png.zig");

test "Web Mercator both ways" {
    const mid = project(0, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.5), mid[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), mid[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), project(max_latitude, -180)[1], 1e-9);
    const milan = project(45.4642, 9.19);
    const back = unproject(milan[0], milan[1]);
    try testing.expectApproxEqAbs(@as(f64, 45.4642), back[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 9.19), back[1], 1e-9);
    const url = try tileUrl(testing.allocator, "https://t/{z}/{x}/{y}{r}.png?k={key}", .{ .z = 3, .x = 5, .y = 2 }, false);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://t/3/5/2.png?k={key}", url);
    const dense = try tileUrl(testing.allocator, "https://t/{z}/{x}/{y}{r}.png", .{ .z = 3, .x = 5, .y = 2 }, true);
    defer testing.allocator.free(dense);
    try testing.expectEqualStrings("https://t/3/5/2@2x.png", dense);
}

/// Tiles in a folder: zoom 0's one, zoom 1's four, each its own color.
const TestTiles = struct {
    tmp: testing.TmpDir,
    template: []u8,

    const colors = [_]u32{ 0x808080, 0xff0000, 0x00ff00, 0x0000ff, 0xffff00 };

    fn color(z: u8, x: u32, y: u32) graphics.Rgba8 {
        const i = if (z == 0) 0 else 1 + y * 2 + x;
        return Color.rgb(@intCast(colors[i])).premultiplied();
    }

    fn init() !TestTiles {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var px: [tile_size * tile_size]graphics.Rgba8 = undefined;
        for ([_]TileKey{ .{ .z = 0, .x = 0, .y = 0 }, .{ .z = 1, .x = 0, .y = 0 }, .{ .z = 1, .x = 1, .y = 0 }, .{ .z = 1, .x = 0, .y = 1 }, .{ .z = 1, .x = 1, .y = 1 } }) |k| {
            @memset(&px, color(k.z, k.x, k.y));
            const bytes = try png.encode(testing.allocator, tile_size, tile_size, &px);
            defer testing.allocator.free(bytes);
            var name: [32]u8 = undefined;
            try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&name, "{d}-{d}-{d}.png", .{ k.z, k.x, k.y }), .data = bytes });
            // And as a server's tiles for dense screens (`{r}`).
            try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&name, "{d}-{d}-{d}@2x.png", .{ k.z, k.x, k.y }), .data = bytes });
        }
        const template = try std.fmt.allocPrint(testing.allocator, "file://.zig-cache/tmp/{s}/{{z}}-{{x}}-{{y}}.png", .{tmp.sub_path});
        return .{ .tmp = tmp, .template = template };
    }

    fn deinit(self: *TestTiles) void {
        testing.allocator.free(self.template);
        self.tmp.cleanup();
    }
};

/// Runs `update` until no tile is loading.
fn waitForTiles() !void {
    for (0..2000) |_| {
        update();
        if (loading_count == 0) {
            var none = true;
            for (maps.items) |m| if (m.wanted.items.len > 0) {
                none = false;
            };
            if (none) return;
        }
        var t: std.Io.Threaded = .init_single_threaded;
        t.io().sleep(.fromMilliseconds(2), .awake) catch {};
    }
    return error.Timeout;
}

/// The images drawn, in order.
fn imagesDrawn(dl: *const DisplayList, out: []rendering.DisplayList.Command.Draw(rendering.ImageStyle)) []rendering.DisplayList.Command.Draw(rendering.ImageStyle) {
    var n: usize = 0;
    for (dl.commands.items) |c| if (c == .image and n < out.len) {
        out[n] = c.image;
        n += 1;
    };
    return out[0..n];
}

test "a map draws its tiles, and lower zoom levels while they come" {
    if (!loader.threaded) return error.SkipZigTest;
    // Last: tiles cancelled while loading are freed by their workers.
    defer loader.waitForRequests();
    var tiles = try TestTiles.init();
    defer tiles.deinit();
    var w: Window = undefined;
    w.init(testing.allocator, .{ .width = 512, .height = 512 });
    defer w.deinit();
    var map: MapView = undefined;
    map.init(testing.allocator);
    defer map.deinit();
    w.rootItem().appendChild(&map.item);
    map.item.setGeometry(.{ .width = 512, .height = 512 });
    map.attribution.set("");
    map.zoom.set(1);
    map.tile_url.set(tiles.template);

    var dl: DisplayList = .init(testing.allocator, .{ .width = 512, .height = 512 });
    defer dl.deinit();
    _ = try w.render(dl.renderer(), .full);
    var buf: [16]rendering.DisplayList.Command.Draw(rendering.ImageStyle) = undefined;
    // Nothing yet; then the four tiles, each where it goes.
    try testing.expectEqual(@as(usize, 0), imagesDrawn(&dl, &buf).len);
    try testing.expect(busy());
    try waitForTiles();
    dl.reset(.{ .width = 512, .height = 512 });
    _ = try w.render(dl.renderer(), .full);
    const drawn = imagesDrawn(&dl, &buf);
    try testing.expectEqual(@as(usize, 4), drawn.len);
    for (drawn) |d| {
        const x: u32 = @intFromFloat(d.rect.x / 256);
        const y: u32 = @intFromFloat(d.rect.y / 256);
        try testing.expectEqual(@as(f32, 256), d.rect.width);
        try testing.expectEqual(TestTiles.color(1, x, y), d.style.image.pixels[0]);
    }

    // Zoom 2 has no tiles: zoom 1's stand in, twice as large, clipped to
    // each missing tile (the middle four of zoom 2's sixteen show).
    map.zoom.set(2);
    dl.reset(.{ .width = 512, .height = 512 });
    _ = try w.render(dl.renderer(), .full);
    try waitForTiles();
    dl.reset(.{ .width = 512, .height = 512 });
    _ = try w.render(dl.renderer(), .full);
    const stand_ins = imagesDrawn(&dl, &buf);
    try testing.expectEqual(@as(usize, 4), stand_ins.len);
    try testing.expectEqual(@as(f32, 512), stand_ins[0].rect.width);
    // The middle's top left tile (zoom 2's 1, 1) is zoom 1's 0, 0.
    for (stand_ins) |d| if (d.clip.x == 0 and d.clip.y == 0) {
        try testing.expectEqual(TestTiles.color(1, 0, 0), d.style.image.pixels[0]);
    };
}

test "a map moves under the pointer, and places its markers and lines" {
    var w: Window = undefined;
    w.init(testing.allocator, .{ .width = 400, .height = 200 });
    defer w.deinit();
    var map: MapView = undefined;
    map.init(testing.allocator);
    defer map.deinit();
    var pin: MapItem = undefined;
    pin.init(testing.allocator);
    defer pin.deinit();
    var line: MapPolyline = undefined;
    line.init(testing.allocator);
    defer line.deinit();
    w.rootItem().appendChild(&map.item);
    map.item.appendChildren(&.{ &line.item, &pin.item });
    map.item.setGeometry(.{ .width = 400, .height = 200 });
    map.tile_url.set("");
    map.zoom.set(1);

    // A pin's bottom middle on 0, 90: a quarter of the 512-pixel world
    // right of the middle.
    pin.item.width.set(10);
    pin.item.height.set(20);
    pin.anchor_y.set(1);
    pin.longitude.set(90);
    try testing.expectEqual(@as(f32, 200 + 128 - 5), pin.item.x.get());
    try testing.expectEqual(@as(f32, 100 - 20), pin.item.y.get());
    // Over the date line: the copy nearest the middle.
    pin.longitude.set(-170);
    map.longitude.set(170);
    try testing.expectApproxEqAbs(@as(f32, 200.0 + 512.0 * 20.0 / 360.0 - 5.0), pin.item.x.get(), 1e-3);
    map.longitude.set(0);

    // Dragged 64 pixels left: 45 degrees east in the middle.
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = 200, .y = 100 } } });
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 200, .y = 100 } } });
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = 136, .y = 100 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 136, .y = 100 } } });
    try testing.expectApproxEqAbs(@as(f32, 45), map.longitude.get(), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), map.latitude.get(), 1e-3);

    // A click: where it was.
    const Clicks = struct {
        at: [2]f32 = .{ 0, 0 },
        n: usize = 0,
        fn f(self: *@This(), lat: f32, lon: f32) void {
            self.at = .{ lat, lon };
            self.n += 1;
        }
    };
    var clicks: Clicks = .{};
    map.clicked.setHandler(&clicks, Clicks.f);
    time.advanceTo(time.now() + 1000);
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 264, .y = 100 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 264, .y = 100 } } });
    try testing.expectEqual(@as(usize, 1), clicks.n);
    try testing.expectApproxEqAbs(@as(f32, 90), clicks.at[1], 1e-3);

    // The wheel zooms in about the pointer: what was under it stays.
    const under = map.coordinateAt(.{ .x = 300, .y = 40 });
    w.dispatchPointer(.{ .wheel = .{ .position = .{ .x = 300, .y = 40 }, .delta = .{ .x = 0, .y = -100 } } });
    try testing.expectApproxEqAbs(@as(f32, 2), map.zoom.get(), 1e-6);
    const still = map.coordinateAt(.{ .x = 300, .y = 40 });
    try testing.expectApproxEqAbs(under[0], still[0], 1e-3);
    try testing.expectApproxEqAbs(under[1], still[1], 1e-3);

    // A line over the whole map, through the points where they show.
    var coords = @import("model.zig").ArrayModel(f32, 4){};
    defer coords.deinit();
    line.coordinates.set(coords.update(.{ 0, 45, 0, 90 }));
    try testing.expectEqual(@as(f32, 400), line.item.width.get());
    var dl: DisplayList = .init(testing.allocator, .{ .width = 400, .height = 200 });
    defer dl.deinit();
    _ = try w.render(dl.renderer(), .full);
    const p0 = map.pointAt(0, 45);
    const p1 = map.pointAt(0, 90);
    var expect_buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expect_buf, "M{d:.2} {d:.2}L{d:.2} {d:.2}", .{ p0.x, p0.y, p1.x, p1.y });
    var found = false;
    for (dl.commands.items) |c| if (c == .path) {
        try testing.expectEqualStrings(expected, c.path.style.commands);
        found = true;
    };
    try testing.expect(found);
}

test "on a dense screen, a map takes the next zoom level's tiles at half size, or a server's @2x ones" {
    if (!loader.threaded) return error.SkipZigTest;
    // Last: tiles cancelled while loading are freed by their workers.
    defer loader.waitForRequests();
    var tiles = try TestTiles.init();
    defer tiles.deinit();
    var w: Window = undefined;
    w.init(testing.allocator, .{ .width = 256, .height = 256 });
    defer w.deinit();
    var map: MapView = undefined;
    map.init(testing.allocator);
    defer map.deinit();
    w.rootItem().appendChild(&map.item);
    map.item.setGeometry(.{ .width = 256, .height = 256 });
    map.attribution.set("");
    map.zoom.set(0);
    map.tile_url.set(tiles.template);
    var dl: DisplayList = .init(testing.allocator, .{ .width = 256, .height = 256 });
    defer dl.deinit();
    var buf: [16]rendering.DisplayList.Command.Draw(rendering.ImageStyle) = undefined;

    // Drawn at twice the pixels: zoom 1's four tiles, 128 wide each.
    _ = try w.renderAt(dl.renderer(), .full, 2);
    try waitForTiles();
    dl.reset(.{ .width = 256, .height = 256 });
    _ = try w.renderAt(dl.renderer(), .full, 2);
    const drawn = imagesDrawn(&dl, &buf);
    try testing.expectEqual(@as(usize, 4), drawn.len);
    for (drawn) |d| {
        try testing.expectEqual(@as(f32, 128), d.rect.width);
        const x: u32 = @intFromFloat(d.rect.x / 128);
        const y: u32 = @intFromFloat(d.rect.y / 128);
        try testing.expectEqual(TestTiles.color(1, x, y), d.style.image.pixels[0]);
    }

    // A template of its own for dense screens: zoom 0's @2x tile.
    const own = try std.mem.replaceOwned(u8, testing.allocator, tiles.template, ".png", "{r}.png");
    defer testing.allocator.free(own);
    map.tile_url.set(own);
    dl.reset(.{ .width = 256, .height = 256 });
    _ = try w.renderAt(dl.renderer(), .full, 2);
    try waitForTiles();
    dl.reset(.{ .width = 256, .height = 256 });
    _ = try w.renderAt(dl.renderer(), .full, 2);
    const own_drawn = imagesDrawn(&dl, &buf);
    try testing.expectEqual(@as(usize, 1), own_drawn.len);
    try testing.expectEqual(@as(f32, 256), own_drawn[0].rect.width);
    try testing.expectEqual(TestTiles.color(0, 0, 0), own_drawn[0].style.image.pixels[0]);

    // Turned off: as on any screen.
    map.tile_url.set(tiles.template);
    map.high_density.set(false);
    dl.reset(.{ .width = 256, .height = 256 });
    _ = try w.renderAt(dl.renderer(), .full, 2);
    try waitForTiles();
    dl.reset(.{ .width = 256, .height = 256 });
    _ = try w.renderAt(dl.renderer(), .full, 2);
    try testing.expectEqual(@as(usize, 1), imagesDrawn(&dl, &buf).len);
}
