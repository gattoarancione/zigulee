// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Opening links with the system (`open-url` in `.zge`): a web page in the
//! browser, `mailto:` in the mail program, a file in its application. A
//! backend sets how (`setOpener`); without one (KMS, microcontrollers),
//! nothing opens.

const std = @import("std");

const log = std.log.scoped(.zigulee);

pub const Opener = struct {
    ctx: ?*anyopaque = null,
    /// Hands `url` to the system; whether it took it (the browser opening
    /// may come later, or fail after).
    open: *const fn (ctx: ?*anyopaque, url: []const u8) bool,
};

var opener: ?Opener = null;

pub fn setOpener(o: ?Opener) void {
    opener = o;
}

/// Whether `url` starts with a scheme (`https:`, `mailto:`, `file:`):
/// letters, digits, `+`, `-` and `.`, from a letter, then a colon. A bare
/// "example.com" has none.
pub fn hasScheme(url: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    if (colon == 0 or !std.ascii.isAlphabetic(url[0])) return false;
    for (url[0..colon]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '-' or ch == '.')) return false;
    return true;
}

/// Opens `url` with the system; false if it was not taken (no scheme,
/// control characters, nothing to open it here).
pub fn openUrl(url: []const u8) bool {
    if (!hasScheme(url)) {
        log.warn("open-url: '{s}' is not a URL (it needs a scheme, like https:)", .{url});
        return false;
    }
    for (url) |ch| if (ch < 0x20 or ch == 0x7f) {
        log.warn("open-url: the URL has control characters", .{});
        return false;
    };
    const o = opener orelse {
        log.info("open-url: links cannot be opened here ({s})", .{url});
        return false;
    };
    const ok = o.open(o.ctx, url);
    if (!ok) log.info("open-url: the system did not open {s}", .{url});
    return ok;
}

// ---- Tests ----

const testing = std.testing;

test "URLs handed to the opener, others refused" {
    try testing.expect(hasScheme("https://example.com"));
    try testing.expect(hasScheme("mailto:a@b.c"));
    try testing.expect(hasScheme("x-app+v1.2:go"));
    try testing.expect(!hasScheme("example.com"));
    try testing.expect(!hasScheme(":nothing"));
    try testing.expect(!hasScheme("1abc:x"));
    try testing.expect(!hasScheme("a b:c"));

    try testing.expect(!openUrl("https://example.com")); // no opener
    const Fake = struct {
        var last: [64]u8 = undefined;
        var len: usize = 0;
        fn open(_: ?*anyopaque, url: []const u8) bool {
            @memcpy(last[0..url.len], url);
            len = url.len;
            return true;
        }
    };
    setOpener(.{ .open = Fake.open });
    defer setOpener(null);
    try testing.expect(openUrl("https://example.com/a?b=c"));
    try testing.expectEqualStrings("https://example.com/a?b=c", Fake.last[0..Fake.len]);
    try testing.expect(!openUrl("www.example.com"));
    try testing.expect(!openUrl("https://x\n.com"));
    try testing.expectEqualStrings("https://example.com/a?b=c", Fake.last[0..Fake.len]);
}
