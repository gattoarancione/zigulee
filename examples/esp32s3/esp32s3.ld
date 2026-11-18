/* Copyright (c) 2026 Claudio Russo */
/* SPDX-License-Identifier: MIT */

/* The firmware in the ESP32-S3's internal SRAM, loaded there by the ROM
 * bootloader (as a second-stage bootloader would be): code through the
 * instruction bus (0x403xxxxx), then constants and data through the data
 * bus (0x3fcxxxxx; the same memory, 0x6f0000 apart), up to where the ROM
 * keeps its own data (0x3fce9700). The ROM's startup stack is just above:
 * the stack grows from it into `_stack_extension`, the end of SRAM below
 * it, which the image leaves free. */

ENTRY(_start)

iram_dram_offset = 0x6f0000;
sram_start = 0x3fc88000;
sram_end = 0x3fce9700;
stack_extension = 28K; /* as STACK_EXTENSION in start.c (a full frame takes about 25K of the 36K in all) */

/* The ROM's functions used. */
ets_delay_us = 0x40000600;
ets_update_cpu_frequency = 0x40001a4c;
_xtos_ints_on = 0x40001bfc;
_xtos_set_interrupt_handler_arg = 0x40001c2c;
_xtos_set_intlevel = 0x40001c38;

SECTIONS
{
    .text (sram_start + iram_dram_offset) : ALIGN(4)
    {
        _text_start = .;
        *(.literal .text .literal.* .text.*)
    }
    _text_end = ADDR(.text) + SIZEOF(.text) - iram_dram_offset;

    .rodata ALIGN(_text_end, 16) : ALIGN(16)
    {
        *(.rodata .rodata.* .srodata .srodata.*)
    }
    .data : ALIGN(16)
    {
        *(.data .data.* .sdata .sdata.*)
    }
    .bss (NOLOAD) : ALIGN(16)
    {
        _bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(16);
        _bss_end = .;
    }
    /* Memory the firmware does not need zeroed (a heap, pixel buffers). */
    .noinit (NOLOAD) : ALIGN(16)
    {
        *(.zigulee_ram .zigulee_ram.*)
        . = ALIGN(16);
        _noinit_end = .;
    }
    /* Right below the ROM's stack, so that it can grow into it. */
    _stack_extension = sram_end - stack_extension;
    ASSERT(_noinit_end <= _stack_extension, "the firmware does not fit in internal SRAM")

    /DISCARD/ : { *(.xt.prop .xt.prop.* .xt.lit .xt.lit.* .comment .note.*) }
}
