// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! `zig build mcu-size`: the memory and code size of the MCU demo
//! (tools/mcu_demo.zig, examples/mcu/thermostat.zge), against the budget.
//!
//!     mcu_size <cortex-m4.elf> <demo.wasm> <node or ""> [--check]
//!
//! Code and static memory come from the sections of the Cortex-M4 build.
//! The heap is measured by running the wasm32 build (32-bit, like the M4)
//! under Node.js; without Node, it is left out.

const std = @import("std");
const elf = std.elf;

/// The ROADMAP's budget: the whole UI in less than 300 KB of RAM.
const ram_budget = 300 * 1024;
/// Code and constant data, the pre-rendered font included.
const flash_budget = 256 * 1024;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) {
        std.debug.print("usage: mcu_size <elf> <wasm> <node or \"\"> [--check]\n", .{});
        return 2;
    }
    const check = args.len > 4 and std.mem.eql(u8, args[4], "--check");
    const cwd = std.Io.Dir.cwd();

    // Sections of the Cortex-M4 build.
    const bytes = try cwd.readFileAlloc(init.io, args[1], arena, .unlimited);
    var reader: std.Io.Reader = .fixed(bytes);
    const header = try elf.Header.read(&reader);
    var shstrtab: []const u8 = "";
    {
        var it = header.iterateSectionHeadersBuffer(bytes);
        var i: usize = 0;
        while (try it.next()) |sh| : (i += 1) {
            if (i == header.shstrndx) shstrtab = bytes[@intCast(sh.sh_offset)..][0..@intCast(sh.sh_size)];
        }
    }
    var flash: u64 = 0;
    var static_ram: u64 = 0;
    var heap_capacity: u64 = 0;
    std.debug.print("Cortex-M4 build (ReleaseSmall), sections:\n", .{});
    var it = header.iterateSectionHeadersBuffer(bytes);
    while (try it.next()) |sh| {
        if (sh.sh_flags & elf.SHF_ALLOC == 0 or sh.sh_size == 0) continue;
        const name = std.mem.sliceTo(shstrtab[sh.sh_name..], 0);
        std.debug.print("  {s:<20} {d:>8} B\n", .{ name, sh.sh_size });
        if (std.mem.eql(u8, name, ".zigulee_heap")) {
            heap_capacity = sh.sh_size;
            continue;
        }
        const writable = sh.sh_flags & elf.SHF_WRITE != 0;
        if (sh.sh_type != elf.SHT_NOBITS) flash += sh.sh_size;
        if (writable) static_ram += sh.sh_size;
    }

    // The heap, from the 32-bit wasm build.
    var heap: ?u64 = null;
    if (args[3].len > 0) {
        const script =
            \\const fs = require("fs");
            \\WebAssembly.instantiate(fs.readFileSync(process.argv[1]), {}).then((m) => {
            \\  console.log(m.instance.exports.zigulee_mcu_heap_used() >>> 0);
            \\});
        ;
        const result = try std.process.run(arena, init.io, .{ .argv = &.{ args[3], "-e", script, args[2] } });
        const text = std.mem.trim(u8, result.stdout, " \n\r");
        const used = std.fmt.parseInt(u64, text, 10) catch {
            std.debug.print("running the wasm32 build failed:\n{s}{s}\n", .{ result.stdout, result.stderr });
            return 1;
        };
        if (used == 0) {
            std.debug.print("the demo failed (out of memory, or the tap missed its button)\n", .{});
            return 1;
        }
        heap = used;
    }

    std.debug.print("\n", .{});
    var over = false;
    over = report("flash: code, constants and font", flash, flash_budget) or over;
    std.debug.print("  {s:<40} {d:>8.1} KB  (of a {d} KB arena)\n", .{ "heap: used by the UI (32-bit)", kb(heap orelse 0), heap_capacity / 1024 });
    if (heap) |h| {
        over = report("RAM: static + heap used", static_ram + h, ram_budget) or over;
    } else {
        std.debug.print("  RAM: static {d:.1} KB; the heap needs Node.js (not found)\n", .{kb(static_ram)});
    }
    return if (over and check) 1 else 0;
}

fn kb(n: u64) f64 {
    return @as(f64, @floatFromInt(n)) / 1024;
}

fn report(name: []const u8, value: u64, budget: u64) bool {
    const over = value > budget;
    std.debug.print("  {s:<40} {d:>8.1} KB  (budget {d} KB){s}\n", .{ name, kb(value), budget / 1024, if (over) "  OVER BUDGET" else "" });
    return over;
}
