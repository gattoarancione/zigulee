// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

/* The firmware's entry point, called by the ESP32-S3's ROM bootloader once
 * it has loaded the image into RAM (the image is all in internal SRAM: no
 * second-stage bootloader, no flash cache). It runs on the ROM's startup
 * stack, which goes on into the end of the image (`_stack_extension`).
 *
 * The few things C does here that the Zig C backend cannot: the
 * coprocessor and interrupt registers, and the cycle counter. */

#include <stdint.h>
#include <string.h>

extern char _bss_start[], _bss_end[], _stack_extension[];
extern void zigulee_firmware_main(void);

#define STACK_EXTENSION (28 * 1024)

/* Bytes of the stack's extension never used so far. */
uint32_t zigulee_stack_untouched(void) {
    uint32_t n = 0;
    while (n < STACK_EXTENSION && (uint8_t)_stack_extension[n] == 0xA5) n++;
    return n;
}

void _start(void) {
    /* No interrupts (everything is polled); the FPU on (zigulee uses f32). */
    uint32_t zero = 0, one = 1;
    __asm__ volatile("wsr %0, intenable\n rsync" ::"r"(zero));
    __asm__ volatile("wsr %0, cpenable\n rsync" ::"r"(one));
    memset(_bss_start, 0, (size_t)(_bss_end - _bss_start));
    /* The stack's extension filled with a pattern: what is left of it
     * later is how deep the stack never went. (The ROM's stack, above it,
     * is the one in use now.) */
    memset(_stack_extension, 0xA5, STACK_EXTENSION);
    zigulee_firmware_main();
    for (;;) {
    }
}

uint32_t zigulee_cycle_count(void) {
    uint32_t c;
    __asm__ volatile("rsr %0, ccount" : "=r"(c));
    return c;
}

/* A sampling profiler: the CPU's timer 0 (CCOMPARE0, interrupt 6, level 1)
 * interrupts every `period` cycles and counts the interrupted address
 * (EPC1) in 256-byte buckets of the code; through the ROM's interrupt
 * dispatcher (its vectors and table stay in place). */
extern char _text_start[], _text_end_iram[];
extern void _xtos_set_interrupt_handler_arg(int n, void (*f)(void *), void *arg);
extern unsigned _xtos_ints_on(unsigned mask);
extern unsigned _xtos_set_intlevel(int level);

#define PROFILE_BUCKETS 1024
uint16_t zigulee_profile[PROFILE_BUCKETS];
static uint32_t profile_period;

static void profile_tick(void *arg) {
    (void)arg;
    uint32_t pc, now;
    __asm__ volatile("rsr %0, epc1" : "=r"(pc));
    uint32_t i = (pc - (uint32_t)_text_start) >> 8;
    if (i < PROFILE_BUCKETS && zigulee_profile[i] != 0xffff) zigulee_profile[i]++;
    __asm__ volatile("rsr %0, ccount" : "=r"(now));
    now += profile_period;
    __asm__ volatile("wsr %0, ccompare0\n rsync" ::"r"(now));
}

void zigulee_profile_start(uint32_t period) {
    profile_period = period;
    memset(zigulee_profile, 0, sizeof zigulee_profile);
    _xtos_set_interrupt_handler_arg(6, profile_tick, 0);
    uint32_t now;
    __asm__ volatile("rsr %0, ccount" : "=r"(now));
    now += period;
    __asm__ volatile("wsr %0, ccompare0\n rsync" ::"r"(now));
    _xtos_ints_on(1 << 6);
    _xtos_set_intlevel(0);
}

void zigulee_profile_stop(void) {
    uint32_t zero = 0;
    __asm__ volatile("wsr %0, intenable\n rsync" ::"r"(zero));
}

uint32_t zigulee_text_start(void) {
    return (uint32_t)_text_start;
}
