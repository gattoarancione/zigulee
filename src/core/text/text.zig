// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Fonts and text layout.

pub const truetype = @import("truetype.zig");
pub const layout = @import("layout.zig");
/// Bidirectional text (right-to-left scripts).
pub const bidi = @import("bidi.zig");
/// Shaping: Arabic joining forms, ligatures, mark positioning.
pub const shape = @import("shape.zig");
/// OpenType layout tables (GSUB, GPOS, GDEF).
pub const opentype = @import("opentype.zig");
/// Pre-rendered fonts for microcontrollers.
pub const bitmap_font = @import("bitmap_font.zig");
/// In-memory test fonts, for tests that must not depend on font files.
pub const test_font = @import("test_font.zig");

pub const Font = truetype.Font;
pub const measure = layout.measure;

test {
    _ = @import("text_test.zig");
    _ = bitmap_font;
    _ = bidi;
    _ = shape;
    _ = opentype;
    _ = @import("shape_test.zig");
}
