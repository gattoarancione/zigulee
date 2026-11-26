// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! A `Set-Cookie` header's value read as a browser reads it (RFC 6265),
//! for web engines that take a cookie's parts rather than the header
//! (WebView2, WebKitGTK): `WebView.setCookie`.

const std = @import("std");

pub const SameSite = enum { unset, none, lax, strict };

/// Its parts, pointing into the header and the URL.
pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    /// Without a leading dot.
    domain: []const u8,
    /// Sent to `domain` only (no `Domain` attribute), not its subdomains.
    host_only: bool,
    path: []const u8,
    /// `Max-Age`: seconds from now (0 or less: expired). Wins over
    /// `expires`.
    max_age: ?i64 = null,
    /// `Expires`: seconds since 1970 (UTC).
    expires: ?i64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: SameSite = .unset,

    /// Whether it lasts only the session (neither Max-Age nor Expires).
    pub fn session(c: Cookie) bool {
        return c.max_age == null and c.expires == null;
    }

    /// When it expires, in seconds since 1970, given the time `now`; null
    /// for a session cookie.
    pub fn expiresAt(c: Cookie, now: i64) ?i64 {
        if (c.max_age) |s| return now +| s;
        return c.expires;
    }
};

/// `header` for a page at `url`, or null if it has no `name=value`, or
/// `url` no host.
pub fn parse(header: []const u8, url: []const u8) ?Cookie {
    var parts = std.mem.splitScalar(u8, header, ';');
    const pair = parts.first();
    const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
    const name = trim(pair[0..eq]);
    if (name.len == 0) return null;
    const host = hostOf(url) orelse return null;
    var c: Cookie = .{
        .name = name,
        .value = unquote(trim(pair[eq + 1 ..])),
        .domain = host,
        .host_only = true,
        .path = defaultPath(url),
    };
    while (parts.next()) |part| {
        const at = std.mem.indexOfScalar(u8, part, '=');
        const key = trim(if (at) |i| part[0..i] else part);
        const val = if (at) |i| trim(part[i + 1 ..]) else "";
        if (eqlIgnoreCase(key, "domain")) {
            const d = std.mem.trimStart(u8, val, ".");
            if (d.len > 0) {
                c.domain = d;
                c.host_only = false;
            }
        } else if (eqlIgnoreCase(key, "path")) {
            if (val.len > 0 and val[0] == '/') c.path = val;
        } else if (eqlIgnoreCase(key, "max-age")) {
            c.max_age = std.fmt.parseInt(i64, val, 10) catch c.max_age;
        } else if (eqlIgnoreCase(key, "expires")) {
            c.expires = parseDate(val) orelse c.expires;
        } else if (eqlIgnoreCase(key, "secure")) {
            c.secure = true;
        } else if (eqlIgnoreCase(key, "httponly")) {
            c.http_only = true;
        } else if (eqlIgnoreCase(key, "samesite")) {
            c.same_site = if (eqlIgnoreCase(val, "none")) .none else if (eqlIgnoreCase(val, "lax")) .lax else if (eqlIgnoreCase(val, "strict")) .strict else .unset;
        }
    }
    return c;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

fn unquote(s: []const u8) []const u8 {
    return if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s[1 .. s.len - 1] else s;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// `https://user@host:8080/path` -> `host`.
fn hostOf(url: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, url, "://") orelse return null) + 3;
    var rest = url[start..];
    rest = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |i| rest = rest[i + 1 ..];
    if (rest.len > 0 and rest[0] == '[') {
        // An IPv6 address, with its brackets.
        const end = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
        return rest[0 .. end + 1];
    }
    rest = rest[0 .. std.mem.indexOfScalar(u8, rest, ':') orelse rest.len];
    return if (rest.len > 0) rest else null;
}

/// The URL's path up to its last `/` (`/a/b` -> `/a`), or `/`.
fn defaultPath(url: []const u8) []const u8 {
    const start = (std.mem.indexOf(u8, url, "://") orelse return "/") + 3;
    const rest = url[start..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
    var path = rest[slash..];
    path = path[0 .. std.mem.indexOfAny(u8, path, "?#") orelse path.len];
    const last = std.mem.lastIndexOfScalar(u8, path, '/').?;
    return if (last == 0) "/" else path[0..last];
}

/// A cookie date (`Wed, 21 Oct 2026 07:28:00 GMT`, also with dashes or a
/// two-digit year), as seconds since 1970; null if it is not one.
pub fn parseDate(text: []const u8) ?i64 {
    var day: ?u32 = null;
    var month: ?u32 = null;
    var year: ?i64 = null;
    var time: ?[3]u32 = null;
    var tokens = std.mem.tokenizeAny(u8, text, " ,-\t");
    while (tokens.next()) |t| {
        if (time == null and std.mem.indexOfScalar(u8, t, ':') != null) {
            var hms: [3]u32 = .{ 0, 0, 0 };
            var fields = std.mem.splitScalar(u8, t, ':');
            var n: usize = 0;
            while (fields.next()) |f| : (n += 1) {
                if (n >= 3) return null;
                hms[n] = std.fmt.parseInt(u32, f, 10) catch return null;
            }
            if (n < 2) return null;
            time = hms;
        } else if (month == null and t.len >= 3 and std.ascii.isAlphabetic(t[0])) {
            const names = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
            for (names, 1..) |m, i| if (std.ascii.eqlIgnoreCase(t[0..3], m)) {
                month = @intCast(i);
            };
        } else if (std.ascii.isDigit(t[0])) {
            const v = std.fmt.parseInt(u32, t, 10) catch continue;
            if (day == null and t.len <= 2) {
                day = v;
            } else if (year == null) {
                year = if (t.len <= 2) (if (v < 70) 2000 + @as(i64, v) else 1900 + @as(i64, v)) else v;
            }
        }
    }
    const d = day orelse return null;
    const m = month orelse return null;
    const y = year orelse return null;
    const hms = time orelse return null;
    if (d < 1 or d > 31 or hms[0] > 23 or hms[1] > 59 or hms[2] > 60) return null;
    return daysFromCivil(y, m, d) * 86400 + hms[0] * 3600 + hms[1] * 60 + hms[2];
}

/// Days since 1970-01-01 of a date (Howard Hinnant's algorithm).
fn daysFromCivil(year: i64, month: u32, day: u32) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = (month + 9) % 12;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const testing = std.testing;

test "a session cookie, HttpOnly and Secure, for the URL's host" {
    const c = parse("session=abc123; Path=/; Secure; HttpOnly", "https://app.example.com/account/settings").?;
    try testing.expectEqualStrings("session", c.name);
    try testing.expectEqualStrings("abc123", c.value);
    try testing.expectEqualStrings("app.example.com", c.domain);
    try testing.expect(c.host_only and c.secure and c.http_only and c.session());
    try testing.expectEqualStrings("/", c.path);
    try testing.expectEqual(SameSite.unset, c.same_site);
}

test "attributes: domain, path, max-age, expires, same-site, case and spaces" {
    const c = parse(" id = \"x y\" ;domain=.Example.com; path=/api; MAX-AGE=3600; expires=Wed, 21 Oct 2026 07:28:00 GMT; SameSite=Lax", "http://u:p@www.example.com:8080/a/b?q=1").?;
    try testing.expectEqualStrings("id", c.name);
    try testing.expectEqualStrings("x y", c.value);
    try testing.expectEqualStrings("Example.com", c.domain);
    try testing.expect(!c.host_only and !c.secure and !c.http_only);
    try testing.expectEqualStrings("/api", c.path);
    try testing.expectEqual(@as(?i64, 3600), c.max_age);
    try testing.expectEqual(@as(?i64, 1792567680), c.expires);
    try testing.expectEqual(@as(?i64, 1000 + 3600), c.expiresAt(1000)); // Max-Age wins
    try testing.expectEqual(SameSite.lax, c.same_site);

    // The default path: the URL's up to its last slash.
    try testing.expectEqualStrings("/a", parse("k=v", "https://h.org/a/b?x=/y").?.path);
    try testing.expectEqualStrings("/", parse("k=v", "https://h.org").?.path);
    try testing.expectEqualStrings("[::1]", parse("k=v", "http://[::1]:80/").?.domain);
    // Not a cookie, or no host.
    try testing.expect(parse("", "https://h.org/") == null);
    try testing.expect(parse("novalue", "https://h.org/") == null);
    try testing.expect(parse("=v", "https://h.org/") == null);
    try testing.expect(parse("k=v", "not a url") == null);
}

test "cookie dates" {
    try testing.expectEqual(@as(?i64, 0), parseDate("Thu, 01 Jan 1970 00:00:00 GMT"));
    try testing.expectEqual(@as(?i64, 1792567680), parseDate("Wed, 21-Oct-2026 07:28:00 GMT"));
    try testing.expectEqual(@as(?i64, 1792567680), parseDate("Wednesday, 21-Oct-26 07:28:00 GMT"));
    try testing.expectEqual(@as(?i64, 951782400), parseDate("Tue, 29 Feb 2000 00:00:00 GMT"));
    try testing.expect(parseDate("tomorrow") == null);
    try testing.expect(parseDate("Wed, 32 Oct 2026 07:28:00 GMT") == null);
}
