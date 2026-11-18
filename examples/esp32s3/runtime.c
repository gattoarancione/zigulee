// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

/* What the generated C needs from a runtime that a 32-bit GCC target does
 * not have: 128-bit multiplication and division (Zig's u128, which zig.h
 * represents as two 64-bit halves without __int128), and newlib's errno
 * (its math functions set it). */

#define ZIG_TARGET_MAX_INT_ALIGNMENT 8
#include "zig.h"

int *__errno(void) {
    static int error;
    return &error;
}

/* 64 x 64 -> 128 bits. */
static void mul64(uint64_t a, uint64_t b, uint64_t *lo, uint64_t *hi) {
    uint64_t a0 = (uint32_t)a, a1 = a >> 32, b0 = (uint32_t)b, b1 = b >> 32;
    uint64_t p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
    uint64_t mid = (p00 >> 32) + (uint32_t)p01 + (uint32_t)p10;
    *lo = (mid << 32) | (uint32_t)p00;
    *hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
}

zig_i128 __multi3(zig_i128 a, zig_i128 b) {
    uint64_t lo, hi;
    mul64(a.lo, b.lo, &lo, &hi);
    hi += a.lo * (uint64_t)b.hi + (uint64_t)a.hi * b.lo;
    zig_i128 r;
    r.lo = lo;
    r.hi = (int64_t)hi;
    return r;
}

/* Unsigned 128-bit division, bit by bit; the remainder in *rem. */
static zig_u128 udivmod(zig_u128 n, zig_u128 d, zig_u128 *rem) {
    zig_u128 q = {0}, r = {0};
    if (d.hi == 0 && d.lo == 0) {
        *rem = r;
        return q;
    }
    for (int i = 127; i >= 0; i--) {
        r.hi = (r.hi << 1) | (r.lo >> 63);
        r.lo = (r.lo << 1) | ((i >= 64 ? n.hi >> (i - 64) : n.lo >> i) & 1);
        if (r.hi > d.hi || (r.hi == d.hi && r.lo >= d.lo)) {
            uint64_t borrow = r.lo < d.lo;
            r.lo -= d.lo;
            r.hi -= d.hi + borrow;
            if (i >= 64) q.hi |= (uint64_t)1 << (i - 64);
            else q.lo |= (uint64_t)1 << i;
        }
    }
    *rem = r;
    return q;
}

zig_u128 __udivti3(zig_u128 n, zig_u128 d) {
    zig_u128 r;
    return udivmod(n, d, &r);
}

zig_u128 __umodti3(zig_u128 n, zig_u128 d) {
    zig_u128 r;
    udivmod(n, d, &r);
    return r;
}

/* zig.h converts between f32 and 32-bit integers by calling compiler-rt's
 * routines, which libgcc implements in software; the ESP32-S3's FPU does
 * each in one instruction (trunc.s, utrunc.s, float.s, ufloat.s), which is
 * what GCC emits for these casts. They are on the renderer's hot path. */
int32_t __fixsfsi(float a) {
    return (int32_t)a;
}

uint32_t __fixunssfsi(float a) {
    return (uint32_t)a;
}

float __floatsisf(int32_t a) {
    return (float)a;
}

float __floatunsisf(uint32_t a) {
    return (float)a;
}

/* Zig's @min and @max on floats become fminf and fmaxf in the generated C;
 * newlib's classify both arguments first (__fpclassifyf), which made them
 * 40% of the renderer's time. The same results (a NaN gives the other
 * argument) with the FPU's comparisons. */
float fminf(float a, float b) {
    if (a != a) return b;
    if (b != b) return a;
    return a < b ? a : b;
}

float fmaxf(float a, float b) {
    if (a != a) return b;
    if (b != b) return a;
    return a > b ? a : b;
}
