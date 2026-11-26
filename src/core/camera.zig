// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! The camera: a backend's provider (`setProvider`) delivers frames, from
//! any thread, into a buffer; `update` (from `updateTimersAndAnimations`)
//! shows the newest one in the `Camera` elements, on the UI thread.
//!
//! The camera runs while a `Camera` is `active`, and stops when none is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const ChangeTracker = @import("properties.zig").ChangeTracker;
const Callback = @import("callbacks.zig").Callback;
const image_mod = @import("image.zig");
const Image = image_mod.Image;
const Rgba8 = @import("graphics.zig").Rgba8;
const ImageItem = @import("items.zig").Image;

const log = std.log.scoped(.zigulee);

/// A backend's camera (the default one).
pub const Provider = struct {
    ctx: ?*anyopaque,
    vtable: *const VTable,

    pub const Error = error{ CameraUnavailable, OutOfMemory };

    pub const VTable = struct {
        /// Starts delivering frames to `sink` (from any thread). It may
        /// take a while (the user is asked for permission).
        start: *const fn (ctx: ?*anyopaque, sink: *const Sink) Error!void,
        /// Stops; when it returns, `sink.frame` is not running and will
        /// not be called.
        stop: *const fn (ctx: ?*anyopaque) void,
        /// Called on the UI thread at each update while it runs (for
        /// backends that fetch frames there).
        poll: ?*const fn (ctx: ?*anyopaque) void = null,
    };

    pub const Sink = struct {
        ctx: ?*anyopaque,
        /// A frame: `pixels` (opaque, or premultiplied), row after row,
        /// `width` x `height`.
        frame: *const fn (ctx: ?*anyopaque, pixels: []const Rgba8, width: u32, height: u32) void,
    };
};

var provider: ?Provider = null;
var running = false;
const sink: Provider.Sink = .{ .ctx = null, .frame = sinkFrame };
var cameras: std.ArrayList(*Camera) = .empty;
var gpa_used: ?Allocator = null;

/// The newest frame delivered, guarded by `lock`.
var lock: std.atomic.Value(bool) = .init(false);
var incoming: std.ArrayList(Rgba8) = .empty;
var incoming_size: [2]u32 = .{ 0, 0 };
var fresh = false;
/// What the elements show.
var shown: std.ArrayList(Rgba8) = .empty;
var shown_size: [2]u32 = .{ 0, 0 };
/// Every image made here gets the next (renderers tell them apart by it).
var version: u32 = 0;

fn acquire() void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn release() void {
    lock.store(false, .release);
}

fn sinkFrame(_: ?*anyopaque, pixels: []const Rgba8, width: u32, height: u32) void {
    const gpa = gpa_used orelse return;
    if (pixels.len < @as(usize, width) * height) return;
    acquire();
    defer release();
    incoming.resize(gpa, @as(usize, width) * height) catch return;
    @memcpy(incoming.items, pixels[0..incoming.items.len]);
    incoming_size = .{ width, height };
    fresh = true;
}

fn nextVersion() u32 {
    version +%= 1;
    return version;
}

/// The camera to use (null: none); stops the current one.
pub fn setProvider(p: ?Provider) void {
    if (running) {
        provider.?.vtable.stop(provider.?.ctx);
        running = false;
    }
    provider = p;
    for (cameras.items) |c| c.available.set(p != null);
    refresh();
}

pub fn hasCamera() bool {
    return provider != null;
}

/// Whether the camera runs (the event loop keeps waking up for `update`).
pub fn busy() bool {
    return running;
}

/// Starts or stops the camera as the elements need.
fn refresh() void {
    const wanted = for (cameras.items) |c| {
        if (c.active.getUntracked()) break true;
    } else false;
    if (wanted == running) return;
    const p = provider orelse return;
    if (!wanted) {
        p.vtable.stop(p.ctx);
        running = false;
        for (cameras.items) |c| c.image.source.set(null);
        return;
    }
    acquire();
    fresh = false;
    release();
    p.vtable.start(p.ctx, &sink) catch |err| {
        log.info("no camera: {t}", .{err});
        return;
    };
    running = true;
}

/// Shows the newest frame. Call on the UI thread once per event loop
/// iteration.
pub fn update() void {
    if (!running) return;
    const p = provider orelse return;
    if (p.vtable.poll) |poll| poll(p.ctx);
    const gpa = gpa_used orelse return;
    acquire();
    if (!fresh) return release();
    fresh = false;
    shown.resize(gpa, incoming.items.len) catch return release();
    @memcpy(shown.items, incoming.items);
    shown_size = incoming_size;
    release();
    const img: Image = .{ .width = shown_size[0], .height = shown_size[1], .pixels = shown.items, .version = nextVersion() };
    for (cameras.items) |c| if (c.active.getUntracked()) c.image.source.set(img);
}

fn cleanUp(gpa: Allocator) void {
    if (cameras.items.len > 0) return;
    cameras.deinit(gpa);
    cameras = .empty;
    acquire();
    incoming.deinit(gpa);
    incoming = .empty;
    release();
    shown.deinit(gpa);
    shown = .empty;
}

// ---- The element ----

/// The camera's picture (`Camera`), shown like an `Image` while `active`.
/// `take-picture()` keeps the frame shown as `picture` and calls
/// `picture-taken`. Initialize in place with `init`.
pub const Camera = struct {
    image: ImageItem = .{},
    active: Property(bool) = .init(false),
    /// There is a camera (the platform's, through the backend).
    available: Property(bool) = .init(false),
    /// The last picture taken.
    picture: Property(?Image) = .init(null),
    picture_taken: Callback(fn () void) = .{},

    gpa: Allocator = undefined,
    tracker: ChangeTracker(bool) = undefined,
    /// What `picture` shows.
    owned: []Rgba8 = &.{},

    pub fn init(self: *Camera, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.available.set(hasCamera());
        gpa_used = gpa;
        cameras.append(gpa, self) catch {};
        self.tracker.init(gpa, self, activeNow, activeChanged);
    }

    pub fn deinit(self: *Camera) void {
        for (cameras.items, 0..) |c, i| if (c == self) {
            _ = cameras.orderedRemove(i);
            break;
        };
        refresh();
        cleanUp(self.gpa);
        self.tracker.deinit();
        self.gpa.free(self.owned);
        self.image.deinit();
        self.active.deinit();
        self.available.deinit();
        self.picture.deinit();
    }

    fn activeNow(self: *Camera) bool {
        return self.active.get();
    }

    fn activeChanged(self: *Camera, on: bool) void {
        refresh();
        if (!on) {
            self.image.source.set(null);
        } else if (running and shown.items.len > 0) {
            // Another camera element shows it already: the same frame.
            self.image.source.set(.{ .width = shown_size[0], .height = shown_size[1], .pixels = shown.items, .version = version });
        }
    }

    /// Keeps the frame shown as `picture` (nothing if none is).
    pub fn takePicture(self: *Camera) void {
        const frame = self.image.source.getUntracked() orelse return;
        const pixels = self.gpa.dupe(Rgba8, frame.pixels) catch return;
        self.gpa.free(self.owned);
        self.owned = pixels;
        self.picture.set(.{ .width = frame.width, .height = frame.height, .pixels = pixels, .version = nextVersion() });
        self.picture_taken.call(.{});
    }

    /// Writes the last picture to `path` as a PNG file.
    pub fn savePicture(self: *Camera, path: []const u8) void {
        const pic = self.picture.getUntracked() orelse return;
        const bytes = @import("png.zig").encode(self.gpa, pic.width, pic.height, pic.pixels) catch return;
        defer self.gpa.free(bytes);
        @import("settings.zig").writeFile(self.gpa, path, bytes) catch |err|
            log.warn("cannot save the picture to '{s}': {t}", .{ path, err });
    }
};

// ---- Tests ----

const testing = std.testing;
const runChangeHandlers = @import("properties.zig").runChangeHandlers;

const FakeCamera = struct {
    started: bool = false,
    sink: ?*const Provider.Sink = null,
    polls: usize = 0,

    fn provider(self: *FakeCamera) Provider {
        return .{ .ctx = self, .vtable = &.{ .start = start, .stop = stop, .poll = poll } };
    }
    fn of(ctx: ?*anyopaque) *FakeCamera {
        return @ptrCast(@alignCast(ctx));
    }
    fn start(ctx: ?*anyopaque, s: *const Provider.Sink) Provider.Error!void {
        of(ctx).started = true;
        of(ctx).sink = s;
    }
    fn stop(ctx: ?*anyopaque) void {
        of(ctx).started = false;
        of(ctx).sink = null;
    }
    fn poll(ctx: ?*anyopaque) void {
        of(ctx).polls += 1;
    }
    fn show(self: *FakeCamera, color: Rgba8) void {
        const pixels: [6]Rgba8 = @splat(color);
        self.sink.?.frame(self.sink.?.ctx, &pixels, 3, 2);
    }
};

test "a camera: frames shown while active, a picture taken" {
    var fake: FakeCamera = .{};
    var cam: Camera = undefined;
    cam.init(testing.allocator);
    defer cam.deinit();
    try testing.expect(!cam.available.get());
    setProvider(fake.provider());
    defer setProvider(null);
    try testing.expect(cam.available.get());

    cam.active.set(true);
    runChangeHandlers();
    try testing.expect(fake.started);
    update(); // nothing yet
    try testing.expect(cam.image.source.get() == null);
    try testing.expectEqual(@as(usize, 1), fake.polls);
    fake.show(.{ .r = 255, .a = 255 });
    update();
    const first = cam.image.source.get().?;
    try testing.expectEqual(@as(u32, 3), first.width);
    try testing.expectEqual(@as(u8, 255), first.pixels[0].r);

    var taken: usize = 0;
    cam.picture_taken.setHandler(&taken, struct {
        fn f(n: *usize) void {
            n.* += 1;
        }
    }.f);
    cam.takePicture();
    try testing.expectEqual(@as(usize, 1), taken);
    fake.show(.{ .b = 255, .a = 255 });
    update();
    const second = cam.image.source.get().?;
    try testing.expectEqual(@as(u8, 255), second.pixels[0].b);
    try testing.expect(second.version != first.version);
    // The picture kept the red frame.
    try testing.expectEqual(@as(u8, 255), cam.picture.get().?.pixels[0].r);

    cam.active.set(false);
    runChangeHandlers();
    try testing.expect(!fake.started);
    try testing.expect(cam.image.source.get() == null);
}
