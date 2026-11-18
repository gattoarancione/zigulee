// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Kernel mode setting, through the DRM device's ioctls (no libdrm): find
//! a connected display, its preferred mode and a CRTC to drive it; create
//! "dumb" buffers (memory the CPU draws into) and show them, with page
//! flips at the display's refresh; a hardware cursor.

const std = @import("std");
const c = std.c;

const log = std.log.scoped(.zigulee_kms);

extern "c" fn ioctl(fd: c.fd_t, request: c_ulong, ...) c_int;

pub const Error = error{ NoDevice, NoDisplay, ModeSetFailed, OutOfMemory };

fn iowr(nr: u8, comptime T: type) c_ulong {
    return (3 << 30) | (@as(c_ulong, @sizeOf(T)) << 16) | ('d' << 8) | nr;
}

/// An ioctl, retried when interrupted; whether it worked.
pub fn call(fd: c.fd_t, request: c_ulong, arg: *anyopaque) bool {
    while (true) {
        const r = ioctl(fd, request, arg);
        if (r == 0) return true;
        if (std.posix.errno(r) != .INTR and std.posix.errno(r) != .AGAIN) return false;
    }
}

pub const CardRes = extern struct {
    fb_id_ptr: u64 = 0,
    crtc_id_ptr: u64 = 0,
    connector_id_ptr: u64 = 0,
    encoder_id_ptr: u64 = 0,
    count_fbs: u32 = 0,
    count_crtcs: u32 = 0,
    count_connectors: u32 = 0,
    count_encoders: u32 = 0,
    min_width: u32 = 0,
    max_width: u32 = 0,
    min_height: u32 = 0,
    max_height: u32 = 0,
};

pub const ModeInfo = extern struct {
    clock: u32,
    hdisplay: u16,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vdisplay: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    vscan: u16,
    vrefresh: u32,
    flags: u32,
    type: u32,
    name: [32]u8,
};

pub const Crtc = extern struct {
    set_connectors_ptr: u64 = 0,
    count_connectors: u32 = 0,
    crtc_id: u32 = 0,
    fb_id: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    gamma_size: u32 = 0,
    mode_valid: u32 = 0,
    mode: ModeInfo = std.mem.zeroes(ModeInfo),
};

pub const Cursor = extern struct {
    flags: u32,
    crtc_id: u32,
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    handle: u32 = 0,
};

pub const GetEncoder = extern struct {
    encoder_id: u32 = 0,
    encoder_type: u32 = 0,
    crtc_id: u32 = 0,
    possible_crtcs: u32 = 0,
    possible_clones: u32 = 0,
};

pub const GetConnector = extern struct {
    encoders_ptr: u64 = 0,
    modes_ptr: u64 = 0,
    props_ptr: u64 = 0,
    prop_values_ptr: u64 = 0,
    count_modes: u32 = 0,
    count_props: u32 = 0,
    count_encoders: u32 = 0,
    encoder_id: u32 = 0,
    connector_id: u32 = 0,
    connector_type: u32 = 0,
    connector_type_id: u32 = 0,
    connection: u32 = 0,
    mm_width: u32 = 0,
    mm_height: u32 = 0,
    subpixel: u32 = 0,
    pad: u32 = 0,
};

pub const FbCmd = extern struct {
    fb_id: u32 = 0,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
    depth: u32,
    handle: u32,
};

pub const PageFlip = extern struct {
    crtc_id: u32,
    fb_id: u32,
    flags: u32,
    reserved: u32 = 0,
    user_data: u64 = 0,
};

pub const CreateDumb = extern struct {
    height: u32,
    width: u32,
    bpp: u32,
    flags: u32 = 0,
    handle: u32 = 0,
    pitch: u32 = 0,
    size: u64 = 0,
};

pub const MapDumb = extern struct {
    handle: u32,
    pad: u32 = 0,
    offset: u64 = 0,
};

pub const ioc = struct {
    pub const set_master: c_ulong = ('d' << 8) | 0x1e;
    pub const drop_master: c_ulong = ('d' << 8) | 0x1f;
    pub const get_resources = iowr(0xA0, CardRes);
    pub const get_crtc = iowr(0xA1, Crtc);
    pub const set_crtc = iowr(0xA2, Crtc);
    pub const cursor = iowr(0xA3, Cursor);
    pub const get_encoder = iowr(0xA6, GetEncoder);
    pub const get_connector = iowr(0xA7, GetConnector);
    pub const add_fb = iowr(0xAE, FbCmd);
    pub const rm_fb = iowr(0xAF, u32);
    pub const page_flip = iowr(0xB0, PageFlip);
    pub const create_dumb = iowr(0xB2, CreateDumb);
    pub const map_dumb = iowr(0xB3, MapDumb);
    pub const destroy_dumb = iowr(0xB4, u32);
};

pub const page_flip_event = 1;
const event_flip_complete = 2;
const mode_type_preferred = 1 << 3;

/// A display to drive: a connected connector, its mode and a CRTC.
pub const Output = struct {
    connector: u32,
    crtc: u32,
    mode: ModeInfo,
    mm_width: u32,
    mm_height: u32,
};

/// Opens the DRM device: `ZIGULEE_DRM_DEVICE`, else the first card with a
/// connected display. Returns the device and its display.
pub fn open() Error!struct { c.fd_t, Output } {
    if (c.getenv("ZIGULEE_DRM_DEVICE")) |path| {
        const fd = c.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        if (fd < 0) return error.NoDevice;
        errdefer _ = c.close(fd);
        return .{ fd, try findOutput(fd) };
    }
    var buf: [32]u8 = undefined;
    for (0..8) |i| {
        const path = std.fmt.bufPrintZ(&buf, "/dev/dri/card{d}", .{i}) catch unreachable;
        const fd = c.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        if (fd < 0) continue;
        if (findOutput(fd)) |output| return .{ fd, output } else |_| _ = c.close(fd);
    }
    return error.NoDevice;
}

/// The first connected connector, with its preferred mode and a CRTC its
/// encoders can use.
fn findOutput(fd: c.fd_t) Error!Output {
    var res: CardRes = .{};
    if (!call(fd, ioc.get_resources, &res)) return error.NoDisplay;
    var crtcs: [16]u32 = undefined;
    var connectors: [16]u32 = undefined;
    var encoders: [16]u32 = undefined;
    res.count_fbs = 0;
    res.count_crtcs = @min(res.count_crtcs, crtcs.len);
    res.count_connectors = @min(res.count_connectors, connectors.len);
    res.count_encoders = @min(res.count_encoders, encoders.len);
    res.crtc_id_ptr = @intFromPtr(&crtcs);
    res.connector_id_ptr = @intFromPtr(&connectors);
    res.encoder_id_ptr = @intFromPtr(&encoders);
    if (!call(fd, ioc.get_resources, &res)) return error.NoDisplay;

    for (connectors[0..res.count_connectors]) |id| {
        // Counts first, then the lists.
        var conn: GetConnector = .{ .connector_id = id };
        if (!call(fd, ioc.get_connector, &conn)) continue;
        if (conn.connection != 1 or conn.count_modes == 0) continue;
        var modes: [64]ModeInfo = undefined;
        var conn_encoders: [16]u32 = undefined;
        conn.count_modes = @min(conn.count_modes, modes.len);
        conn.count_encoders = @min(conn.count_encoders, conn_encoders.len);
        conn.count_props = 0;
        conn.modes_ptr = @intFromPtr(&modes);
        conn.encoders_ptr = @intFromPtr(&conn_encoders);
        if (!call(fd, ioc.get_connector, &conn) or conn.count_modes == 0) continue;
        var mode = modes[0];
        for (modes[0..conn.count_modes]) |m| if (m.type & mode_type_preferred != 0) {
            mode = m;
            break;
        };
        // The CRTC driving it now, else one an encoder can use.
        var crtc: u32 = 0;
        if (conn.encoder_id != 0) {
            var enc: GetEncoder = .{ .encoder_id = conn.encoder_id };
            if (call(fd, ioc.get_encoder, &enc)) crtc = enc.crtc_id;
        }
        if (crtc == 0) for (conn_encoders[0..conn.count_encoders]) |eid| {
            var enc: GetEncoder = .{ .encoder_id = eid };
            if (!call(fd, ioc.get_encoder, &enc)) continue;
            for (crtcs[0..res.count_crtcs], 0..) |cid, i| if (enc.possible_crtcs & (@as(u32, 1) << @intCast(i)) != 0) {
                crtc = cid;
                break;
            };
            if (crtc != 0) break;
        };
        if (crtc == 0) continue;
        return .{ .connector = id, .crtc = crtc, .mode = mode, .mm_width = conn.mm_width, .mm_height = conn.mm_height };
    }
    return error.NoDisplay;
}

/// A dumb buffer, mapped, with a framebuffer to show it (XRGB8888).
pub const Buffer = struct {
    handle: u32 = 0,
    fb: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// In pixels (rows may be padded).
    stride: u32 = 0,
    memory: []align(std.heap.page_size_min) u8 = &.{},

    pub fn create(fd: c.fd_t, width: u32, height: u32) Error!Buffer {
        var dumb: CreateDumb = .{ .width = width, .height = height, .bpp = 32 };
        if (!call(fd, ioc.create_dumb, &dumb)) return error.OutOfMemory;
        var b: Buffer = .{ .handle = dumb.handle, .width = width, .height = height, .stride = dumb.pitch / 4 };
        errdefer b.destroy(fd);
        var cmd: FbCmd = .{ .width = width, .height = height, .pitch = dumb.pitch, .bpp = 32, .depth = 24, .handle = dumb.handle };
        if (!call(fd, ioc.add_fb, &cmd)) return error.ModeSetFailed;
        b.fb = cmd.fb_id;
        var map: MapDumb = .{ .handle = dumb.handle };
        if (!call(fd, ioc.map_dumb, &map)) return error.OutOfMemory;
        const size: usize = @intCast(dumb.size);
        const mem = c.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, @intCast(map.offset));
        if (mem == c.MAP_FAILED) return error.OutOfMemory;
        b.memory = @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(mem)))[0..size];
        @memset(b.memory, 0);
        return b;
    }

    pub fn destroy(b: *Buffer, fd: c.fd_t) void {
        if (b.memory.len > 0) _ = c.munmap(b.memory.ptr, b.memory.len);
        if (b.fb != 0) _ = call(fd, ioc.rm_fb, &b.fb);
        if (b.handle != 0) _ = call(fd, ioc.destroy_dumb, &b.handle);
        b.* = .{};
    }

    pub fn pixels(b: *Buffer) []u32 {
        return @alignCast(std.mem.bytesAsSlice(u32, b.memory));
    }
};

/// Reads the device's events; whether a page flip completed.
pub fn readEvents(fd: c.fd_t) bool {
    var buf: [1024]u8 align(8) = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return false;
    var flipped = false;
    var at: usize = 0;
    while (at + 8 <= @as(usize, @intCast(n))) {
        const kind = std.mem.readInt(u32, buf[at..][0..4], .little);
        const len = std.mem.readInt(u32, buf[at + 4 ..][0..4], .little);
        if (len < 8) break;
        if (kind == event_flip_complete) flipped = true;
        at += len;
    }
    return flipped;
}

test "ioctl numbers" {
    // As in the kernel's drm.h (64-bit).
    try std.testing.expectEqual(@as(c_ulong, 0xC04064A0), ioc.get_resources);
    try std.testing.expectEqual(@as(c_ulong, 0xC06864A1), ioc.get_crtc);
    try std.testing.expectEqual(@as(c_ulong, 0xC06864A2), ioc.set_crtc);
    try std.testing.expectEqual(@as(c_ulong, 0xC01C64A3), ioc.cursor);
    try std.testing.expectEqual(@as(c_ulong, 0xC01464A6), ioc.get_encoder);
    try std.testing.expectEqual(@as(c_ulong, 0xC05064A7), ioc.get_connector);
    try std.testing.expectEqual(@as(c_ulong, 0xC01C64AE), ioc.add_fb);
    try std.testing.expectEqual(@as(c_ulong, 0xC00464AF), ioc.rm_fb);
    try std.testing.expectEqual(@as(c_ulong, 0xC01864B0), ioc.page_flip);
    try std.testing.expectEqual(@as(c_ulong, 0xC02064B2), ioc.create_dumb);
    try std.testing.expectEqual(@as(c_ulong, 0xC01064B3), ioc.map_dumb);
    try std.testing.expectEqual(@as(c_ulong, 0xC00464B4), ioc.destroy_dumb);
}
