// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Bidirectional text (Unicode's UAX #9): the levels of mixed left-to-right
//! and right-to-left text, and the order lines show their characters in.
//!
//! Implemented: paragraph direction from the first strong character (P2,
//! P3), the weak (W1–W7), neutral (N1, N2) and implicit (I1, I2) rules,
//! trailing whitespace (L1), reordering (L2) and mirrored brackets (L4).
//! Explicit embeddings, overrides and isolates (U+202A–202E, 2066–2069) are
//! ignored like formatting characters; bracket pairs (N0) are resolved as
//! plain neutrals.

const std = @import("std");

pub const Class = enum(u8) {
    /// Left-to-right.
    L,
    /// Right-to-left (Hebrew...).
    R,
    /// Right-to-left Arabic letters.
    AL,
    /// European digits, their separators and terminators.
    EN,
    ES,
    ET,
    /// Arabic digits.
    AN,
    /// Common separators (, . : /).
    CS,
    /// Combining marks.
    NSM,
    /// Formatting and control characters.
    BN,
    /// Paragraph and segment separators, whitespace, other neutrals.
    B,
    S,
    WS,
    ON,
};

const Range = struct { first: u21, last: u21, class: Class };

/// Code point ranges whose class is not L (the default), sorted.
const ranges = [_]Range{
    .{ .first = 0x00, .last = 0x08, .class = .BN },
    .{ .first = 0x09, .last = 0x09, .class = .S },
    .{ .first = 0x0a, .last = 0x0a, .class = .B },
    .{ .first = 0x0b, .last = 0x0b, .class = .S },
    .{ .first = 0x0c, .last = 0x0c, .class = .WS },
    .{ .first = 0x0d, .last = 0x0d, .class = .B },
    .{ .first = 0x0e, .last = 0x1b, .class = .BN },
    .{ .first = 0x1c, .last = 0x1e, .class = .B },
    .{ .first = 0x1f, .last = 0x1f, .class = .S },
    .{ .first = 0x20, .last = 0x20, .class = .WS },
    .{ .first = 0x21, .last = 0x22, .class = .ON },
    .{ .first = 0x23, .last = 0x25, .class = .ET },
    .{ .first = 0x26, .last = 0x2a, .class = .ON },
    .{ .first = 0x2b, .last = 0x2b, .class = .ES },
    .{ .first = 0x2c, .last = 0x2c, .class = .CS },
    .{ .first = 0x2d, .last = 0x2d, .class = .ES },
    .{ .first = 0x2e, .last = 0x2f, .class = .CS },
    .{ .first = 0x30, .last = 0x39, .class = .EN },
    .{ .first = 0x3a, .last = 0x3a, .class = .CS },
    .{ .first = 0x3b, .last = 0x40, .class = .ON },
    .{ .first = 0x5b, .last = 0x60, .class = .ON },
    .{ .first = 0x7b, .last = 0x7e, .class = .ON },
    .{ .first = 0x7f, .last = 0x84, .class = .BN },
    .{ .first = 0x85, .last = 0x85, .class = .B },
    .{ .first = 0x86, .last = 0x9f, .class = .BN },
    .{ .first = 0xa0, .last = 0xa0, .class = .CS },
    .{ .first = 0xa1, .last = 0xa1, .class = .ON },
    .{ .first = 0xa2, .last = 0xa5, .class = .ET },
    .{ .first = 0xa6, .last = 0xa9, .class = .ON },
    .{ .first = 0xab, .last = 0xac, .class = .ON },
    .{ .first = 0xad, .last = 0xad, .class = .BN },
    .{ .first = 0xae, .last = 0xaf, .class = .ON },
    .{ .first = 0xb0, .last = 0xb1, .class = .ET },
    .{ .first = 0xb2, .last = 0xb3, .class = .EN },
    .{ .first = 0xb4, .last = 0xb4, .class = .ON },
    .{ .first = 0xb6, .last = 0xb8, .class = .ON },
    .{ .first = 0xb9, .last = 0xb9, .class = .EN },
    .{ .first = 0xbb, .last = 0xbf, .class = .ON },
    .{ .first = 0xd7, .last = 0xd7, .class = .ON },
    .{ .first = 0xf7, .last = 0xf7, .class = .ON },
    .{ .first = 0x2b9, .last = 0x2ba, .class = .ON },
    .{ .first = 0x2c2, .last = 0x2cf, .class = .ON },
    .{ .first = 0x2d2, .last = 0x2df, .class = .ON },
    .{ .first = 0x2e5, .last = 0x2ed, .class = .ON },
    .{ .first = 0x2ef, .last = 0x2ff, .class = .ON },
    .{ .first = 0x300, .last = 0x36f, .class = .NSM },
    .{ .first = 0x374, .last = 0x375, .class = .ON },
    .{ .first = 0x37e, .last = 0x37e, .class = .ON },
    .{ .first = 0x384, .last = 0x385, .class = .ON },
    .{ .first = 0x387, .last = 0x387, .class = .ON },
    .{ .first = 0x483, .last = 0x489, .class = .NSM },
    .{ .first = 0x58a, .last = 0x58a, .class = .ON },
    .{ .first = 0x58d, .last = 0x58e, .class = .ON },
    .{ .first = 0x58f, .last = 0x58f, .class = .ET },
    .{ .first = 0x590, .last = 0x590, .class = .R },
    .{ .first = 0x591, .last = 0x5bd, .class = .NSM },
    .{ .first = 0x5be, .last = 0x5be, .class = .R },
    .{ .first = 0x5bf, .last = 0x5bf, .class = .NSM },
    .{ .first = 0x5c0, .last = 0x5c0, .class = .R },
    .{ .first = 0x5c1, .last = 0x5c2, .class = .NSM },
    .{ .first = 0x5c3, .last = 0x5c3, .class = .R },
    .{ .first = 0x5c4, .last = 0x5c5, .class = .NSM },
    .{ .first = 0x5c6, .last = 0x5c6, .class = .R },
    .{ .first = 0x5c7, .last = 0x5c7, .class = .NSM },
    .{ .first = 0x5c8, .last = 0x5ff, .class = .R },
    .{ .first = 0x600, .last = 0x605, .class = .AN },
    .{ .first = 0x606, .last = 0x607, .class = .ON },
    .{ .first = 0x608, .last = 0x608, .class = .AL },
    .{ .first = 0x609, .last = 0x60a, .class = .ET },
    .{ .first = 0x60b, .last = 0x60b, .class = .AL },
    .{ .first = 0x60c, .last = 0x60c, .class = .CS },
    .{ .first = 0x60d, .last = 0x60d, .class = .AL },
    .{ .first = 0x60e, .last = 0x60f, .class = .ON },
    .{ .first = 0x610, .last = 0x61a, .class = .NSM },
    .{ .first = 0x61b, .last = 0x64a, .class = .AL },
    .{ .first = 0x64b, .last = 0x65f, .class = .NSM },
    .{ .first = 0x660, .last = 0x669, .class = .AN },
    .{ .first = 0x66a, .last = 0x66a, .class = .ET },
    .{ .first = 0x66b, .last = 0x66c, .class = .AN },
    .{ .first = 0x66d, .last = 0x66f, .class = .AL },
    .{ .first = 0x670, .last = 0x670, .class = .NSM },
    .{ .first = 0x671, .last = 0x6d5, .class = .AL },
    .{ .first = 0x6d6, .last = 0x6dc, .class = .NSM },
    .{ .first = 0x6dd, .last = 0x6dd, .class = .AN },
    .{ .first = 0x6de, .last = 0x6de, .class = .ON },
    .{ .first = 0x6df, .last = 0x6e4, .class = .NSM },
    .{ .first = 0x6e5, .last = 0x6e6, .class = .AL },
    .{ .first = 0x6e7, .last = 0x6e8, .class = .NSM },
    .{ .first = 0x6e9, .last = 0x6e9, .class = .ON },
    .{ .first = 0x6ea, .last = 0x6ed, .class = .NSM },
    .{ .first = 0x6ee, .last = 0x6ef, .class = .AL },
    .{ .first = 0x6f0, .last = 0x6f9, .class = .EN },
    .{ .first = 0x6fa, .last = 0x710, .class = .AL },
    .{ .first = 0x711, .last = 0x711, .class = .NSM },
    .{ .first = 0x712, .last = 0x72f, .class = .AL },
    .{ .first = 0x730, .last = 0x74a, .class = .NSM },
    .{ .first = 0x74b, .last = 0x7a5, .class = .AL },
    .{ .first = 0x7a6, .last = 0x7b0, .class = .NSM },
    .{ .first = 0x7b1, .last = 0x7bf, .class = .AL },
    .{ .first = 0x7c0, .last = 0x7ea, .class = .R },
    .{ .first = 0x7eb, .last = 0x7f3, .class = .NSM },
    .{ .first = 0x7f4, .last = 0x7f5, .class = .R },
    .{ .first = 0x7f6, .last = 0x7f9, .class = .ON },
    .{ .first = 0x7fa, .last = 0x815, .class = .R },
    .{ .first = 0x816, .last = 0x82d, .class = .NSM },
    .{ .first = 0x82e, .last = 0x858, .class = .R },
    .{ .first = 0x859, .last = 0x85b, .class = .NSM },
    .{ .first = 0x85c, .last = 0x85f, .class = .R },
    .{ .first = 0x860, .last = 0x88f, .class = .AL },
    .{ .first = 0x890, .last = 0x891, .class = .AN },
    .{ .first = 0x892, .last = 0x897, .class = .AL },
    .{ .first = 0x898, .last = 0x89f, .class = .NSM },
    .{ .first = 0x8a0, .last = 0x8c9, .class = .AL },
    .{ .first = 0x8ca, .last = 0x8e1, .class = .NSM },
    .{ .first = 0x8e2, .last = 0x8e2, .class = .AN },
    .{ .first = 0x8e3, .last = 0x902, .class = .NSM },
    .{ .first = 0x93a, .last = 0x93a, .class = .NSM },
    .{ .first = 0x93c, .last = 0x93c, .class = .NSM },
    .{ .first = 0x941, .last = 0x948, .class = .NSM },
    .{ .first = 0x94d, .last = 0x94d, .class = .NSM },
    .{ .first = 0x951, .last = 0x957, .class = .NSM },
    .{ .first = 0x962, .last = 0x963, .class = .NSM },
    .{ .first = 0xe31, .last = 0xe31, .class = .NSM },
    .{ .first = 0xe34, .last = 0xe3a, .class = .NSM },
    .{ .first = 0xe3f, .last = 0xe3f, .class = .ET },
    .{ .first = 0xe47, .last = 0xe4e, .class = .NSM },
    .{ .first = 0x1680, .last = 0x1680, .class = .WS },
    .{ .first = 0x180e, .last = 0x180e, .class = .BN },
    .{ .first = 0x1ab0, .last = 0x1aff, .class = .NSM },
    .{ .first = 0x1dc0, .last = 0x1dff, .class = .NSM },
    .{ .first = 0x2000, .last = 0x200a, .class = .WS },
    .{ .first = 0x200b, .last = 0x200d, .class = .BN },
    .{ .first = 0x200f, .last = 0x200f, .class = .R }, // RLM (LRM is L)
    .{ .first = 0x2010, .last = 0x2027, .class = .ON },
    .{ .first = 0x2028, .last = 0x2028, .class = .WS },
    .{ .first = 0x2029, .last = 0x2029, .class = .B },
    .{ .first = 0x202a, .last = 0x202e, .class = .BN }, // embeddings, overrides: ignored
    .{ .first = 0x202f, .last = 0x202f, .class = .CS },
    .{ .first = 0x2030, .last = 0x2034, .class = .ET },
    .{ .first = 0x2035, .last = 0x2043, .class = .ON },
    .{ .first = 0x2044, .last = 0x2044, .class = .CS },
    .{ .first = 0x2045, .last = 0x205e, .class = .ON },
    .{ .first = 0x205f, .last = 0x205f, .class = .WS },
    .{ .first = 0x2060, .last = 0x206f, .class = .BN }, // isolates too: ignored
    .{ .first = 0x2070, .last = 0x2070, .class = .EN },
    .{ .first = 0x2074, .last = 0x2079, .class = .EN },
    .{ .first = 0x207a, .last = 0x207b, .class = .ES },
    .{ .first = 0x207c, .last = 0x207e, .class = .ON },
    .{ .first = 0x2080, .last = 0x2089, .class = .EN },
    .{ .first = 0x208a, .last = 0x208b, .class = .ES },
    .{ .first = 0x208c, .last = 0x208e, .class = .ON },
    .{ .first = 0x20a0, .last = 0x20cf, .class = .ET },
    .{ .first = 0x20d0, .last = 0x20f0, .class = .NSM },
    .{ .first = 0x2100, .last = 0x2101, .class = .ON },
    .{ .first = 0x2103, .last = 0x2103, .class = .ET },
    .{ .first = 0x2104, .last = 0x2106, .class = .ON },
    .{ .first = 0x2108, .last = 0x2109, .class = .ON },
    .{ .first = 0x2114, .last = 0x2114, .class = .ON },
    .{ .first = 0x2116, .last = 0x2118, .class = .ON },
    .{ .first = 0x211e, .last = 0x2123, .class = .ON },
    .{ .first = 0x2125, .last = 0x2125, .class = .ON },
    .{ .first = 0x2127, .last = 0x2127, .class = .ON },
    .{ .first = 0x2129, .last = 0x2129, .class = .ON },
    .{ .first = 0x212e, .last = 0x212e, .class = .ET },
    .{ .first = 0x2190, .last = 0x2211, .class = .ON },
    .{ .first = 0x2212, .last = 0x2212, .class = .ES },
    .{ .first = 0x2213, .last = 0x2213, .class = .ET },
    .{ .first = 0x2214, .last = 0x2335, .class = .ON },
    .{ .first = 0x237b, .last = 0x2394, .class = .ON },
    .{ .first = 0x2396, .last = 0x2487, .class = .ON },
    .{ .first = 0x2488, .last = 0x249b, .class = .EN },
    .{ .first = 0x24ea, .last = 0x26ab, .class = .ON },
    .{ .first = 0x26ad, .last = 0x27ff, .class = .ON },
    .{ .first = 0x2900, .last = 0x2b73, .class = .ON },
    .{ .first = 0x2e00, .last = 0x2e5d, .class = .ON },
    .{ .first = 0x3000, .last = 0x3000, .class = .WS },
    .{ .first = 0x3001, .last = 0x3004, .class = .ON },
    .{ .first = 0x3008, .last = 0x3020, .class = .ON },
    .{ .first = 0xfb1d, .last = 0xfb1d, .class = .R },
    .{ .first = 0xfb1e, .last = 0xfb1e, .class = .NSM },
    .{ .first = 0xfb1f, .last = 0xfb28, .class = .R },
    .{ .first = 0xfb29, .last = 0xfb29, .class = .ES },
    .{ .first = 0xfb2a, .last = 0xfb4f, .class = .R },
    .{ .first = 0xfb50, .last = 0xfd3d, .class = .AL },
    .{ .first = 0xfd3e, .last = 0xfd4f, .class = .ON },
    .{ .first = 0xfd50, .last = 0xfdcf, .class = .AL },
    .{ .first = 0xfdf0, .last = 0xfdfc, .class = .AL },
    .{ .first = 0xfdfd, .last = 0xfdff, .class = .ON },
    .{ .first = 0xfe00, .last = 0xfe0f, .class = .NSM },
    .{ .first = 0xfe10, .last = 0xfe19, .class = .ON },
    .{ .first = 0xfe20, .last = 0xfe2f, .class = .NSM },
    .{ .first = 0xfe30, .last = 0xfe4f, .class = .ON },
    .{ .first = 0xfe50, .last = 0xfe50, .class = .CS },
    .{ .first = 0xfe51, .last = 0xfe51, .class = .ON },
    .{ .first = 0xfe52, .last = 0xfe52, .class = .CS },
    .{ .first = 0xfe54, .last = 0xfe54, .class = .ON },
    .{ .first = 0xfe55, .last = 0xfe55, .class = .CS },
    .{ .first = 0xfe56, .last = 0xfe5e, .class = .ON },
    .{ .first = 0xfe5f, .last = 0xfe5f, .class = .ET },
    .{ .first = 0xfe60, .last = 0xfe61, .class = .ON },
    .{ .first = 0xfe62, .last = 0xfe63, .class = .ES },
    .{ .first = 0xfe64, .last = 0xfe68, .class = .ON },
    .{ .first = 0xfe69, .last = 0xfe6a, .class = .ET },
    .{ .first = 0xfe6b, .last = 0xfe6b, .class = .ON },
    .{ .first = 0xfe70, .last = 0xfefe, .class = .AL },
    .{ .first = 0xfeff, .last = 0xfeff, .class = .BN },
    .{ .first = 0xff01, .last = 0xff02, .class = .ON },
    .{ .first = 0xff03, .last = 0xff05, .class = .ET },
    .{ .first = 0xff06, .last = 0xff0a, .class = .ON },
    .{ .first = 0xff0b, .last = 0xff0b, .class = .ES },
    .{ .first = 0xff0c, .last = 0xff0c, .class = .CS },
    .{ .first = 0xff0d, .last = 0xff0d, .class = .ES },
    .{ .first = 0xff0e, .last = 0xff0f, .class = .CS },
    .{ .first = 0xff10, .last = 0xff19, .class = .EN },
    .{ .first = 0xff1a, .last = 0xff1a, .class = .CS },
    .{ .first = 0xff1b, .last = 0xff20, .class = .ON },
    .{ .first = 0xff3b, .last = 0xff40, .class = .ON },
    .{ .first = 0xff5b, .last = 0xff65, .class = .ON },
    .{ .first = 0xffe0, .last = 0xffe1, .class = .ET },
    .{ .first = 0xffe2, .last = 0xffe4, .class = .ON },
    .{ .first = 0xffe5, .last = 0xffe6, .class = .ET },
    .{ .first = 0xffe8, .last = 0xffee, .class = .ON },
    .{ .first = 0xfff9, .last = 0xfffd, .class = .ON },
    .{ .first = 0x10800, .last = 0x10cff, .class = .R },
    .{ .first = 0x10d00, .last = 0x10d23, .class = .AL },
    .{ .first = 0x10d24, .last = 0x10d27, .class = .NSM },
    .{ .first = 0x10d30, .last = 0x10d39, .class = .AN },
    .{ .first = 0x10d3a, .last = 0x10e5f, .class = .R },
    .{ .first = 0x10e60, .last = 0x10e7e, .class = .AN },
    .{ .first = 0x10e80, .last = 0x10f2f, .class = .R },
    .{ .first = 0x10f30, .last = 0x10f45, .class = .AL },
    .{ .first = 0x10f46, .last = 0x10f50, .class = .NSM },
    .{ .first = 0x10f51, .last = 0x10fff, .class = .R },
    .{ .first = 0x1d7ce, .last = 0x1d7ff, .class = .EN },
    .{ .first = 0x1e800, .last = 0x1edff, .class = .R },
    .{ .first = 0x1ee00, .last = 0x1eeff, .class = .AL },
    .{ .first = 0x1ef00, .last = 0x1efff, .class = .R },
    .{ .first = 0x1f000, .last = 0x1f0ff, .class = .ON },
    .{ .first = 0x1f300, .last = 0x1faff, .class = .ON }, // emoji and symbols
    .{ .first = 0xe0001, .last = 0xe007f, .class = .BN },
    .{ .first = 0xe0100, .last = 0xe01ef, .class = .NSM },
};

comptime {
    @setEvalBranchQuota(10000);
    for (ranges[1..], ranges[0 .. ranges.len - 1]) |r, prev| {
        if (r.first <= prev.last or r.last < r.first) @compileError("bidi ranges must be sorted and disjoint");
    }
}

/// The bidirectional class of a code point.
pub fn class(cp: u21) Class {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const r = ranges[mid];
        if (cp < r.first) hi = mid else if (cp > r.last) lo = mid + 1 else return r.class;
    }
    return .L;
}

/// Whether text with `cp` may need reordering (a cheap test for the common
/// case of left-to-right text).
pub fn isRtlCodePoint(cp: u21) bool {
    if (cp < 0x590) return false;
    return switch (class(cp)) {
        .R, .AL, .AN => true,
        else => false,
    };
}

/// The mirrored glyph of a character shown right to left: `(` as `)`...
pub fn mirror(cp: u21) u21 {
    const pairs = [_][2]u21{
        .{ '(', ')' },       .{ '<', '>' },       .{ '[', ']' },       .{ '{', '}' },
        .{ 0xab, 0xbb },     .{ 0x2039, 0x203a }, .{ 0x2045, 0x2046 }, .{ 0x207d, 0x207e },
        .{ 0x208d, 0x208e }, .{ 0x2264, 0x2265 }, .{ 0x2208, 0x220b }, .{ 0x2282, 0x2283 },
        .{ 0x2286, 0x2287 }, .{ 0x2308, 0x2309 }, .{ 0x230a, 0x230b }, .{ 0x2329, 0x232a },
        .{ 0x27e8, 0x27e9 }, .{ 0x3008, 0x3009 }, .{ 0x300a, 0x300b }, .{ 0x300c, 0x300d },
        .{ 0x300e, 0x300f }, .{ 0x3010, 0x3011 }, .{ 0xff08, 0xff09 }, .{ 0xff3b, 0xff3d },
        .{ 0xff5b, 0xff5d },
    };
    for (pairs) |p| {
        if (cp == p[0]) return p[1];
        if (cp == p[1]) return p[0];
    }
    return cp;
}

/// The paragraph level (0: left to right, 1: right to left) of `text`,
/// from its first strong character (P2, P3).
pub fn paragraphLevel(text: []const u8) u8 {
    var i: usize = 0;
    while (i < text.len) {
        const d = decode(text, i);
        i += d.len;
        switch (class(d.cp)) {
            .L => return 0,
            .R, .AL => return 1,
            .B => return 0,
            else => {},
        }
    }
    return 0;
}

fn decode(text: []const u8, i: usize) struct { cp: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return .{ .cp = 0xfffd, .len = 1 };
    if (i + len > text.len) return .{ .cp = 0xfffd, .len = 1 };
    const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return .{ .cp = 0xfffd, .len = 1 };
    return .{ .cp = cp, .len = len };
}

/// Resolves the embedding level of each character of a paragraph: `classes`
/// holds the characters' classes (one per character), and receives working
/// values; `levels` (same length) receives the levels.
pub fn resolve(classes: []Class, base: u8, levels: []u8) void {
    std.debug.assert(levels.len == classes.len);
    const n = classes.len;
    const embedding: Class = if (base % 2 == 1) .R else .L;
    // X9: formatting characters take no part (they get their neighbors'
    // levels at the end).
    // W1: marks take the type of what precedes them.
    var prev: Class = embedding;
    for (classes) |*c| {
        if (c.* == .BN) continue;
        if (c.* == .NSM) c.* = prev;
        prev = c.*;
    }
    // W2: European digits after Arabic letters are Arabic digits.
    var strong: Class = embedding;
    for (classes) |*c| switch (c.*) {
        .L, .R, .AL => strong = c.*,
        .EN => if (strong == .AL) {
            c.* = .AN;
        },
        else => {},
    };
    // W3: Arabic letters are right to left.
    for (classes) |*c| if (c.* == .AL) {
        c.* = .R;
    };
    // W4: one separator between two digits of the same kind joins them.
    for (classes, 0..) |*c, i| {
        if (i == 0 or i + 1 >= n) continue;
        const before = prevNonBn(classes, i);
        const after = nextNonBn(classes, i);
        if (c.* == .ES and before == .EN and after == .EN) c.* = .EN;
        if (c.* == .CS and before == after and (before == .EN or before == .AN)) c.* = before.?;
    }
    // W5: terminators next to European digits are European digits.
    var i: usize = 0;
    while (i < n) {
        if (classes[i] != .ET) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < n and (classes[end] == .ET or classes[end] == .BN)) end += 1;
        const touches = (i > 0 and prevNonBn(classes, i) == .EN) or (end < n and classes[end] == .EN);
        if (touches) {
            for (classes[i..end]) |*c| {
                if (c.* == .ET) c.* = .EN;
            }
        }
        i = end;
    }
    // W6: other separators and terminators are neutral.
    for (classes) |*c| switch (c.*) {
        .ES, .ET, .CS => c.* = .ON,
        else => {},
    };
    // W7: European digits after left-to-right text are left to right.
    strong = embedding;
    for (classes) |*c| switch (c.*) {
        .L, .R => strong = c.*,
        .EN => if (strong == .L) {
            c.* = .L;
        },
        else => {},
    };
    // N1, N2: neutrals between characters of the same direction take it,
    // others the embedding direction.
    i = 0;
    while (i < n) {
        if (!isNeutral(classes[i])) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < n and (isNeutral(classes[end]) or classes[end] == .BN)) end += 1;
        const before: Class = if (i == 0) embedding else strongDir(prevNonBn(classes, i) orelse embedding);
        const after: Class = if (end >= n) embedding else strongDir(classes[end]);
        const resolved = if (before == after) before else embedding;
        for (classes[i..end]) |*c| {
            if (c.* != .BN) c.* = resolved;
        }
        i = end;
    }
    // I1, I2: levels.
    for (classes, levels) |c, *l| {
        l.* = base;
        if (base % 2 == 0) {
            switch (c) {
                .R => l.* = base + 1,
                .AN, .EN => l.* = base + 2,
                else => {},
            }
        } else switch (c) {
            .L, .EN, .AN => l.* = base + 1,
            else => {},
        }
    }
    // Formatting characters: the level of what precedes them.
    var last: u8 = base;
    for (classes, levels) |c, *l| {
        if (c == .BN) l.* = last else last = l.*;
    }
}

fn isNeutral(c: Class) bool {
    return switch (c) {
        .B, .S, .WS, .ON => true,
        else => false,
    };
}

/// For neutrals: European and Arabic digits count as right to left.
fn strongDir(c: Class) Class {
    return switch (c) {
        .L => .L,
        else => .R,
    };
}

fn prevNonBn(classes: []const Class, i: usize) ?Class {
    var j = i;
    while (j > 0) {
        j -= 1;
        if (classes[j] != .BN) return classes[j];
    }
    return null;
}

fn nextNonBn(classes: []const Class, i: usize) ?Class {
    var j = i + 1;
    while (j < classes.len) : (j += 1) {
        if (classes[j] != .BN) return classes[j];
    }
    return null;
}

/// L1 for one line: whitespace (and formatting characters) at its end, and
/// before segment separators, goes back to the paragraph level.
/// `original` are the characters' classes before resolution.
pub fn resetTrailing(original: []const Class, levels: []u8, base: u8) void {
    var j = levels.len;
    while (j > 0) {
        j -= 1;
        switch (original[j]) {
            .WS, .BN, .S, .B => levels[j] = base,
            else => break,
        }
    }
    for (original, 0..) |c, k| {
        if (c != .S and c != .B) continue;
        levels[k] = base;
        var m = k;
        while (m > 0) {
            m -= 1;
            if (original[m] != .WS and original[m] != .BN) break;
            levels[m] = base;
        }
    }
}

/// L2: `order[v]` is the index (in logical order) of the character shown at
/// visual position `v`.
pub fn reorder(levels: []const u8, order: []u16) void {
    std.debug.assert(order.len == levels.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    var highest: u8 = 0;
    var lowest_odd: u8 = 255;
    for (levels) |l| {
        highest = @max(highest, l);
        if (l % 2 == 1) lowest_odd = @min(lowest_odd, l);
    }
    if (lowest_odd == 255) return;
    var level = highest;
    while (level >= lowest_odd) : (level -= 1) {
        var i: usize = 0;
        while (i < order.len) {
            if (levels[order[i]] < level) {
                i += 1;
                continue;
            }
            var end = i;
            while (end < order.len and levels[order[end]] >= level) end += 1;
            std.mem.reverse(u16, order[i..end]);
            i = end;
        }
        if (level == 0) break;
    }
}

// ---- Tests ----

const testing = std.testing;

/// The visual order of a one-line string, as a string (letters stand for
/// themselves; Hebrew letters keep their code points).
fn visual(text: []const u8, buf: []u8) ![]const u8 {
    var cps: [64]u21 = undefined;
    var classes: [64]Class = undefined;
    var original: [64]Class = undefined;
    var n: usize = 0;
    var view = try std.unicode.Utf8View.init(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| : (n += 1) {
        cps[n] = cp;
        classes[n] = class(cp);
        original[n] = classes[n];
    }
    const base = paragraphLevel(text);
    var levels: [64]u8 = undefined;
    resolve(classes[0..n], base, levels[0..n]);
    resetTrailing(original[0..n], levels[0..n], base);
    var order: [64]u16 = undefined;
    reorder(levels[0..n], order[0..n]);
    var len: usize = 0;
    for (order[0..n]) |o| {
        const cp = if (levels[o] % 2 == 1) mirror(cps[o]) else cps[o];
        len += try std.unicode.utf8Encode(cp, buf[len..]);
    }
    return buf[0..len];
}

test "classes" {
    try testing.expectEqual(Class.L, class('a'));
    try testing.expectEqual(Class.EN, class('7'));
    try testing.expectEqual(Class.WS, class(' '));
    try testing.expectEqual(Class.R, class(0x5d0)); // alef
    try testing.expectEqual(Class.AL, class(0x627)); // Arabic alef
    try testing.expectEqual(Class.AN, class(0x663));
    try testing.expectEqual(Class.NSM, class(0x64e));
    try testing.expectEqual(Class.L, class(0x4e2d));
    try testing.expect(isRtlCodePoint(0x5d0) and !isRtlCodePoint('a') and !isRtlCodePoint(0x4e2d));
}

test "reordering mixed text" {
    var buf: [256]u8 = undefined;
    // Hebrew is shown right to left inside left-to-right text.
    try testing.expectEqualStrings("car \u{5d2}\u{5d1}\u{5d0} is", try visual("car \u{5d0}\u{5d1}\u{5d2} is", &buf));
    // A right-to-left paragraph: everything reads from the right; digits
    // keep their order.
    try testing.expectEqualStrings("123 \u{5d1}\u{5d0}", try visual("\u{5d0}\u{5d1} 123", &buf));
    // Left-to-right words inside right-to-left text keep their order.
    try testing.expectEqualStrings("\u{5d1} abc \u{5d0}", try visual("\u{5d0} abc \u{5d1}", &buf));
    // Brackets are mirrored in right-to-left runs.
    try testing.expectEqualStrings("(\u{5d1}\u{5d0})", try visual("(\u{5d0}\u{5d1})", &buf));
    // Arabic digits after Arabic letters, and a number with its separator.
    try testing.expectEqualStrings("1.5 \u{628}\u{627}", try visual("\u{627}\u{628} 1.5", &buf));
    // Plain left-to-right text is unchanged.
    try testing.expectEqualStrings("Hello, world 42!", try visual("Hello, world 42!", &buf));
    // Trailing whitespace stays at the paragraph's end (L1).
    // A left-to-right paragraph starting with a Latin letter.
    try testing.expectEqualStrings("x \u{5d1}\u{5d0}", try visual("x \u{5d0}\u{5d1}", &buf));
    // Trailing whitespace stays at the end of a right-to-left paragraph,
    // which is its left (L1).
    try testing.expectEqualStrings("  abc \u{5d1}\u{5d0}", try visual("\u{5d0}\u{5d1} abc  ", &buf));
}
