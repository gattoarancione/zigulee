// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

/* Included before the generated C (-include): float min and max inline.
 * zig.h implements @min and @max on floats with fminf and fmaxf; defined
 * here as static inline (zig.h's later extern declarations then refer to
 * these), GCC inlines them as FPU comparisons instead of calling newlib's,
 * which classify both arguments first. Same results: a NaN gives the
 * other argument. */
static inline __attribute__((always_inline)) float fminf(float a, float b) {
    if (a != a) return b;
    if (b != b) return a;
    return a < b ? a : b;
}

static inline __attribute__((always_inline)) float fmaxf(float a, float b) {
    if (a != a) return b;
    if (b != b) return a;
    return a > b ? a : b;
}
