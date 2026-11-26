// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! A heap over a fixed buffer that reuses what is freed: first fit, with
//! freed blocks merged with free neighbors. (A bump allocator such as
//! std.heap.FixedBufferAllocator only takes back the last allocation: a UI
//! that runs for days, allocating as animations start and texts change,
//! runs out.) Tracks the bytes in use and their high-water mark.

const std = @import("std");
const Alignment = std.mem.Alignment;

/// Every block starts with its size; a block in use also has, right before
/// its memory, where it starts (alignment may leave a gap between them).
/// Two words: 8 bytes on a 32-bit device.
const unit = 2 * @sizeOf(usize);
const header = unit;

/// A free block: its size (bytes, header included) and the next free
/// block (by address; 0 for none).
const Free = extern struct { size: usize, next: usize };

pub const Heap = struct {
    start: usize,
    end: usize,
    /// The free blocks, by address.
    free_list: usize,
    used: usize = 0,
    peak: usize = 0,
    /// The last request that could not be met, and the largest free
    /// block then.
    failed_len: usize = 0,
    failed_largest: usize = 0,

    pub fn init(buf: []u8) Heap {
        const start = std.mem.alignForward(usize, @intFromPtr(buf.ptr), unit);
        const end = std.mem.alignBackward(usize, @intFromPtr(buf.ptr) + buf.len, unit);
        const first: *Free = @ptrFromInt(start);
        first.* = .{ .size = end - start, .next = 0 };
        return .{ .start = start, .end = end, .free_list = start };
    }

    pub fn allocator(h: *Heap) std.mem.Allocator {
        return .{ .ptr = h, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn freeAt(addr: usize) *Free {
        return @ptrFromInt(addr);
    }

    /// The block size (header and alignment gap included) for `len` bytes
    /// at `alignment` in a block starting at `block`.
    fn payloadAt(block: usize, alignment: Alignment) usize {
        return alignment.max(.fromByteUnits(unit)).forward(block + header);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const h: *Heap = @ptrCast(@alignCast(ctx));
        var prev: ?*Free = null;
        var addr = h.free_list;
        while (addr != 0) {
            const b = freeAt(addr);
            const payload = payloadAt(addr, alignment);
            const need = std.mem.alignForward(usize, payload + len, unit) - addr;
            if (need <= b.size) {
                // Split if what is left can hold a block.
                var size: usize = b.size;
                var next = b.next;
                if (b.size - need >= header + unit) {
                    const rest = addr + need;
                    freeAt(rest).* = .{ .size = b.size - need, .next = b.next };
                    next = rest;
                    size = need;
                }
                if (prev) |p| p.next = next else h.free_list = next;
                // In use: the size at the start, the start before the memory.
                @as(*usize, @ptrFromInt(addr)).* = size;
                @as(*usize, @ptrFromInt(payload - @sizeOf(usize))).* = addr;
                h.used += size;
                h.peak = @max(h.peak, h.used);
                return @ptrFromInt(payload);
            }
            prev = b;
            addr = b.next;
        }
        h.failed_len = len;
        h.failed_largest = h.largestFree();
        return null;
    }

    /// The largest free block (bytes, header included).
    pub fn largestFree(h: *const Heap) usize {
        var largest: usize = 0;
        var addr = h.free_list;
        while (addr != 0) : (addr = freeAt(addr).next) largest = @max(largest, freeAt(addr).size);
        return largest;
    }

    fn blockOf(memory: []u8) struct { usize, usize } {
        const addr = @as(*const usize, @ptrFromInt(@intFromPtr(memory.ptr) - @sizeOf(usize))).*;
        return .{ addr, @as(*const usize, @ptrFromInt(addr)).* };
    }

    fn resize(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
        // In place within the block.
        const addr, const size = blockOf(memory);
        return @intFromPtr(memory.ptr) + new_len <= addr + size;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ret)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
        const h: *Heap = @ptrCast(@alignCast(ctx));
        const addr, const size = blockOf(memory);
        h.used -= size;
        // Into the list by address, merged with the free neighbors.
        var prev: ?*Free = null;
        var next = h.free_list;
        while (next != 0 and next < addr) {
            prev = freeAt(next);
            next = freeAt(next).next;
        }
        const b = freeAt(addr);
        b.* = .{ .size = size, .next = next };
        if (next != 0 and addr + b.size == next) {
            b.size += freeAt(next).size;
            b.next = freeAt(next).next;
        }
        if (prev) |p| {
            if (@intFromPtr(p) + p.size == addr) {
                p.size += b.size;
                p.next = b.next;
            } else p.next = addr;
        } else h.free_list = addr;
    }
};

test "freed memory is reused, and merged" {
    var buf: [4096]u8 align(16) = undefined;
    var heap: Heap = .init(&buf);
    const gpa = heap.allocator();
    var blocks: [20][]u8 = undefined;
    for (0..1000) |round| {
        for (&blocks, 0..) |*b, i| b.* = try gpa.alloc(u8, 16 + (i * 7 + round) % 90);
        for (blocks, 0..) |b, i| @memset(b, @intCast(i));
        for (blocks, 0..) |b, i| for (b) |byte| try std.testing.expectEqual(@as(u8, @intCast(i)), byte);
        // Freed in a mixed order: holes, then neighbors merged.
        var i: usize = round % 20;
        for (0..20) |_| {
            gpa.free(blocks[i]);
            i = (i + 7) % 20;
        }
        try std.testing.expectEqual(@as(usize, 0), heap.used);
    }
    // All one block again: the largest allocation fits.
    const all = try gpa.alloc(u8, heap.end - heap.start - 2 * header);
    gpa.free(all);
    const aligned = try gpa.alignedAlloc(u8, .@"64", 100);
    try std.testing.expect(@intFromPtr(aligned.ptr) % 64 == 0);
    gpa.free(aligned);
    try std.testing.expectEqual(@as(usize, 0), heap.used);
}
