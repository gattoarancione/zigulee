// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The little of V4L2 the bench needs to try the i.MX PXP (the mainline
//! `imx-pxp` driver: a memory-to-memory device): its structures as the
//! kernel lays them out on this CPU, and their ioctls.

const std = @import("std");
const c = std.c;

extern "c" fn ioctl(fd: c.fd_t, request: c_ulong, ...) c_int;

/// An ioctl, retried when interrupted; the error number if it failed.
pub fn call(fd: c.fd_t, request: u32, arg: anytype) ?std.posix.E {
    while (true) {
        const r = ioctl(fd, request, arg);
        if (r == 0) return null;
        const e = std.posix.errno(r);
        if (e != .INTR) return e;
    }
}

pub const Capability = extern struct {
    driver: [16]u8,
    card: [32]u8,
    bus_info: [32]u8,
    version: u32,
    capabilities: u32,
    device_caps: u32,
    reserved: [3]u32,
};

pub const FmtDesc = extern struct {
    index: u32,
    type: u32,
    flags: u32 = 0,
    description: [32]u8 = @splat(0),
    pixelformat: u32 = 0,
    mbus_code: u32 = 0,
    reserved: [3]u32 = @splat(0),
};

pub const PixFormat = extern struct {
    width: u32,
    height: u32,
    pixelformat: u32,
    field: u32,
    bytesperline: u32,
    sizeimage: u32,
    colorspace: u32,
    priv: u32,
    flags: u32,
    ycbcr_enc: u32,
    quantization: u32,
    xfer_func: u32,
};

pub const Format = extern struct {
    type: u32,
    fmt: extern union {
        pix: PixFormat,
        raw: [200]u8,
        // The kernel's union holds pointers (v4l2_window): aligned as one.
        aligned: ?*anyopaque,
    },
};

pub const RequestBuffers = extern struct {
    count: u32,
    type: u32,
    memory: u32,
    capabilities: u32 = 0,
    flags: u8 = 0,
    reserved: [3]u8 = @splat(0),
};

pub const Timecode = extern struct {
    type: u32,
    flags: u32,
    frames: u8,
    seconds: u8,
    minutes: u8,
    hours: u8,
    userbits: [4]u8,
};

pub const Buffer = extern struct {
    index: u32,
    type: u32,
    bytesused: u32 = 0,
    flags: u32 = 0,
    field: u32 = 0,
    timestamp: extern struct { sec: c_long, usec: c_long } = .{ .sec = 0, .usec = 0 },
    timecode: Timecode = std.mem.zeroes(Timecode),
    sequence: u32 = 0,
    memory: u32,
    /// The offset to mmap (MMAP), or the address (USERPTR).
    m: usize = 0,
    length: u32 = 0,
    reserved2: u32 = 0,
    request_fd: i32 = 0,
};

pub const Control = extern struct { id: u32, value: i32 };

pub const QueryCtrl = extern struct {
    id: u32,
    type: u32 = 0,
    name: [32]u8 = @splat(0),
    minimum: i32 = 0,
    maximum: i32 = 0,
    step: i32 = 0,
    default_value: i32 = 0,
    flags: u32 = 0,
    reserved: [2]u32 = @splat(0),
};

const IOCTL = std.os.linux.IOCTL;
pub const querycap = IOCTL.IOR('V', 0, Capability);
pub const enum_fmt = IOCTL.IOWR('V', 2, FmtDesc);
pub const g_fmt = IOCTL.IOWR('V', 4, Format);
pub const s_fmt = IOCTL.IOWR('V', 5, Format);
pub const reqbufs = IOCTL.IOWR('V', 8, RequestBuffers);
pub const querybuf = IOCTL.IOWR('V', 9, Buffer);
pub const qbuf = IOCTL.IOWR('V', 15, Buffer);
pub const dqbuf = IOCTL.IOWR('V', 17, Buffer);
pub const streamon = IOCTL.IOW('V', 18, c_int);
pub const streamoff = IOCTL.IOW('V', 19, c_int);
pub const s_ctrl = IOCTL.IOWR('V', 28, Control);
pub const queryctrl = IOCTL.IOWR('V', 36, QueryCtrl);

pub const capture: u32 = 1;
pub const output: u32 = 2;
pub const memory_mmap: u32 = 1;
pub const memory_userptr: u32 = 2;
pub const field_none: u32 = 1;

pub const cid_hflip: u32 = 0x00980900 + 20;
pub const cid_vflip: u32 = 0x00980900 + 21;
pub const cid_rotate: u32 = 0x00980900 + 34;
pub const cid_alpha_component: u32 = 0x00980900 + 41;

/// A four-character code as V4L2 makes them.
pub fn fourcc(s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

/// Pixel formats by their bytes in memory.
/// R, G, B, A: the renderer's `Rgba8`.
pub const rgba32 = fourcc("AB24");
/// R, G, B, unused.
pub const rgbx32 = fourcc("XB24");
/// B, G, R, unused: an XRGB8888 screen.
pub const xbgr32 = fourcc("XR24");
/// B, G, R, A.
pub const abgr32 = fourcc("AR24");
pub const rgb565 = fourcc("RGBP");

/// A C string field up to its end.
pub fn text(bytes: []const u8) []const u8 {
    return bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
}

comptime {
    // As the kernel's (32-bit ARM: 68 bytes; 64-bit: 88).
    std.debug.assert(@sizeOf(Capability) == 104);
    std.debug.assert(@sizeOf(FmtDesc) == 64);
    std.debug.assert(@sizeOf(PixFormat) == 48);
    std.debug.assert(@sizeOf(Format) == if (@sizeOf(usize) == 8) 208 else 204);
    std.debug.assert(@sizeOf(RequestBuffers) == 20);
    std.debug.assert(@sizeOf(Buffer) == if (@sizeOf(usize) == 8) 88 else 68);
    std.debug.assert(@sizeOf(Control) == 8);
    std.debug.assert(@sizeOf(QueryCtrl) == 68);
}
