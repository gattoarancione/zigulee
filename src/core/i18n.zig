// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! Translations (`@tr(...)` in `.zge`).
//!
//! Generated code asks `translate` for the template of a message in the
//! current language, then fills in its arguments with `format`. The
//! application chooses the language with `setTranslator`, typically with a
//! `Catalog` read from a gettext `.po` file; every `@tr` reads the current
//! translator as a property, so switching language updates the whole UI.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;

/// A message to translate, as written in the source.
pub const Message = struct {
    /// gettext's msgctxt: tells apart equal texts; empty if none.
    context: []const u8 = "",
    id: []const u8,
    /// The plural form in the source language, if the message has one.
    plural: ?[]const u8 = null,
    /// The count choosing the plural form.
    n: i64 = 0,
};

/// Finds translations: `translateFn` returns the template for a message,
/// or null to keep the source text.
pub const Translator = struct {
    ctx: ?*anyopaque = null,
    translateFn: *const fn (ctx: ?*anyopaque, m: Message) ?[]const u8,
};

var translator: ?Translator = null;
/// Changes with the translator: what `@tr` bindings depend on.
var generation: Property(u32) = .init(0);

/// Sets the translator (null: the source texts). Everything translated
/// is translated again.
pub fn setTranslator(t: ?Translator) void {
    translator = t;
    generation.set(generation.getUntracked() +% 1);
}

/// The template of `m` in the current language. Called from a binding,
/// it makes the binding depend on the current translator.
pub fn translate(m: Message) []const u8 {
    _ = generation.get();
    if (translator) |t| if (t.translateFn(t.ctx, m)) |s| return s;
    if (m.plural) |p| return if (m.n == 1) m.id else p;
    return m.id;
}

/// An argument of a translated message.
pub const Arg = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
};

/// Writes `template` with `{}` replaced by the next argument, `{0}`,
/// `{1}`... by the given one, `{n}` by `n`, and `{{`, `}}` by braces.
/// Missing arguments are left out.
pub fn format(w: *std.Io.Writer, template: []const u8, args: []const Arg, n: i64) std.Io.Writer.Error!void {
    var next: usize = 0;
    var i: usize = 0;
    while (i < template.len) {
        const ch = template[i];
        if (ch == '}' and i + 1 < template.len and template[i + 1] == '}') {
            try w.writeByte('}');
            i += 2;
            continue;
        }
        if (ch != '{') {
            try w.writeByte(ch);
            i += 1;
            continue;
        }
        if (i + 1 < template.len and template[i + 1] == '{') {
            try w.writeByte('{');
            i += 2;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, template, i, '}') orelse {
            try w.writeAll(template[i..]);
            return;
        };
        const inside = template[i + 1 .. close];
        i = close + 1;
        if (std.mem.eql(u8, inside, "n")) {
            try w.print("{d}", .{n});
        } else if (inside.len == 0) {
            if (next < args.len) try writeArg(w, args[next]);
            next += 1;
        } else if (std.fmt.parseInt(usize, inside, 10)) |k| {
            if (k < args.len) try writeArg(w, args[k]);
        } else |_| {
            // Not a placeholder: keep it.
            try w.writeAll(template[i - inside.len - 2 .. i]);
        }
    }
}

fn writeArg(w: *std.Io.Writer, a: Arg) std.Io.Writer.Error!void {
    switch (a) {
        .string => |s| try w.writeAll(s),
        .int => |v| try w.print("{d}", .{v}),
        .float => |v| try w.print("{d}", .{v}),
        .boolean => |v| try w.writeAll(if (v) "true" else "false"),
    }
}

// ---- gettext catalogs ----

/// The translations of one language, read from a gettext `.po` file:
///
///     var it: zigulee.core.i18n.Catalog = try .parse(gpa, @embedFile("it.po"));
///     defer it.deinit();
///     zigulee.core.i18n.setTranslator(it.translator());
///
/// Fuzzy and untranslated entries are skipped (the source text shows).
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    /// By `context ++ "\x04" ++ id` (as in `.mo` files), or `id`.
    entries: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    /// From the header's Plural-Forms; null: `n != 1`.
    plural: ?*const PluralExpr = null,
    nplurals: usize = 2,

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
    }

    pub fn translator(self: *const Catalog) Translator {
        return .{ .ctx = @ptrCast(@constCast(self)), .translateFn = lookupErased };
    }

    fn lookupErased(ctx: ?*anyopaque, m: Message) ?[]const u8 {
        const self: *const Catalog = @ptrCast(@alignCast(ctx.?));
        return self.lookup(m);
    }

    pub fn lookup(self: *const Catalog, m: Message) ?[]const u8 {
        var key_buf: [512]u8 = undefined;
        const key = if (m.context.len == 0) m.id else std.fmt.bufPrint(&key_buf, "{s}\x04{s}", .{ m.context, m.id }) catch return null;
        const forms = self.entries.get(key) orelse return null;
        const index: usize = if (m.plural == null) 0 else self.pluralIndex(m.n);
        if (index >= forms.len or forms[index].len == 0) return null;
        return forms[index];
    }

    /// Which plural form `n` takes in this language.
    pub fn pluralIndex(self: *const Catalog, n: i64) usize {
        const v = if (self.plural) |p| p.eval(n) else @intFromBool(n != 1);
        return @intCast(std.math.clamp(v, 0, @as(i64, @intCast(self.nplurals)) - 1));
    }

    pub const ParseError = error{ OutOfMemory, InvalidPo };

    pub fn parse(gpa: Allocator, po: []const u8) ParseError!Catalog {
        var self: Catalog = .{ .arena = .init(gpa) };
        errdefer self.deinit();
        const a = self.arena.allocator();

        var entry: Entry = .{};
        var field: ?*std.ArrayList(u8) = null;
        var lines = std.mem.splitScalar(u8, po, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) {
                try self.finish(a, &entry);
                field = null;
                continue;
            }
            if (line[0] == '#') {
                // A comment starts a new entry; `#,` flags may mark it fuzzy.
                if (entry.started) try self.finish(a, &entry);
                if (std.mem.startsWith(u8, line, "#,") and std.mem.indexOf(u8, line, "fuzzy") != null) entry.fuzzy = true;
                field = null;
                continue;
            }
            if (line[0] == '"') {
                const f = field orelse return error.InvalidPo;
                try unquote(a, f, line);
                continue;
            }
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidPo;
            const keyword = line[0..space];
            const rest = std.mem.trim(u8, line[space..], " \t");
            if (std.mem.eql(u8, keyword, "msgctxt") or (std.mem.eql(u8, keyword, "msgid") and entry.has_msgstr)) {
                // The next entry starts (without a blank line).
                if (entry.has_msgstr) try self.finish(a, &entry);
            }
            entry.started = true;
            if (std.mem.eql(u8, keyword, "msgctxt")) {
                field = &entry.context;
                entry.has_context = true;
            } else if (std.mem.eql(u8, keyword, "msgid")) {
                field = &entry.id;
            } else if (std.mem.eql(u8, keyword, "msgid_plural")) {
                field = &entry.plural_id;
            } else if (std.mem.eql(u8, keyword, "msgstr")) {
                entry.has_msgstr = true;
                try entry.strs.append(a, .empty);
                field = &entry.strs.items[entry.strs.items.len - 1];
            } else if (std.mem.startsWith(u8, keyword, "msgstr[")) {
                entry.has_msgstr = true;
                const close = std.mem.indexOfScalar(u8, keyword, ']') orelse return error.InvalidPo;
                const k = std.fmt.parseInt(usize, keyword[7..close], 10) catch return error.InvalidPo;
                if (k > 16) return error.InvalidPo;
                while (entry.strs.items.len <= k) try entry.strs.append(a, .empty);
                field = &entry.strs.items[k];
            } else return error.InvalidPo;
            try unquote(a, field.?, rest);
        }
        try self.finish(a, &entry);
        return self;
    }

    const Entry = struct {
        started: bool = false,
        fuzzy: bool = false,
        has_context: bool = false,
        has_msgstr: bool = false,
        context: std.ArrayList(u8) = .empty,
        id: std.ArrayList(u8) = .empty,
        plural_id: std.ArrayList(u8) = .empty,
        strs: std.ArrayList(std.ArrayList(u8)) = .empty,
    };

    fn finish(self: *Catalog, a: Allocator, e: *Entry) ParseError!void {
        defer e.* = .{};
        if (!e.has_msgstr) return;
        if (e.id.items.len == 0 and !e.has_context) {
            // The header: the plural rule.
            if (e.strs.items.len > 0) try self.readHeader(a, e.strs.items[0].items);
            return;
        }
        if (e.fuzzy) return;
        const forms = try a.alloc([]const u8, e.strs.items.len);
        for (forms, e.strs.items) |*f, s| f.* = s.items;
        const key = if (e.has_context)
            try std.fmt.allocPrint(a, "{s}\x04{s}", .{ e.context.items, e.id.items })
        else
            e.id.items;
        try self.entries.put(a, key, forms);
    }

    fn readHeader(self: *Catalog, a: Allocator, header: []const u8) ParseError!void {
        var lines = std.mem.splitScalar(u8, header, '\n');
        while (lines.next()) |line| {
            const prefix = "Plural-Forms:";
            if (!std.ascii.startsWithIgnoreCase(line, prefix)) continue;
            const value = line[prefix.len..];
            if (std.mem.indexOf(u8, value, "nplurals=")) |i| {
                var j = i + "nplurals=".len;
                while (j < value.len and value[j] == ' ') j += 1;
                var k = j;
                while (k < value.len and std.ascii.isDigit(value[k])) k += 1;
                self.nplurals = std.fmt.parseInt(usize, value[j..k], 10) catch return error.InvalidPo;
                if (self.nplurals == 0) return error.InvalidPo;
            }
            if (std.mem.indexOf(u8, value, "plural=")) |i| {
                // `plural=` also matches inside `nplurals=`: take the last.
                const start = (std.mem.lastIndexOf(u8, value, "plural=") orelse i) + "plural=".len;
                var end = std.mem.indexOfScalarPos(u8, value, start, ';') orelse value.len;
                if (end < start) end = value.len;
                var p: PluralParser = .{ .src = value[start..end], .arena = a };
                const expr = p.parseTernary() catch return error.InvalidPo;
                p.skipSpace();
                if (p.pos != p.src.len) return error.InvalidPo;
                self.plural = expr;
            }
        }
    }
};

/// Appends the text of a quoted `.po` string, with escapes resolved.
fn unquote(a: Allocator, out: *std.ArrayList(u8), quoted: []const u8) Catalog.ParseError!void {
    if (quoted.len < 2 or quoted[0] != '"' or quoted[quoted.len - 1] != '"') return error.InvalidPo;
    const s = quoted[1 .. quoted.len - 1];
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try out.append(a, s[i]);
            continue;
        }
        i += 1;
        try out.append(a, switch (s[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            else => s[i],
        });
    }
}

/// A gettext plural rule (C syntax): `n`, integers, `( )`, `?:`, `||`,
/// `&&`, comparisons, `+ - * / %` and `!`.
pub const PluralExpr = union(enum) {
    n,
    int: i64,
    not: *const PluralExpr,
    binary: struct { op: Op, a: *const PluralExpr, b: *const PluralExpr },
    ternary: struct { cond: *const PluralExpr, then: *const PluralExpr, otherwise: *const PluralExpr },

    const Op = enum { @"or", @"and", eq, ne, lt, le, gt, ge, add, sub, mul, div, mod };

    pub fn eval(e: *const PluralExpr, n: i64) i64 {
        return switch (e.*) {
            .n => n,
            .int => |v| v,
            .not => |x| @intFromBool(x.eval(n) == 0),
            .ternary => |t| if (t.cond.eval(n) != 0) t.then.eval(n) else t.otherwise.eval(n),
            .binary => |b| blk: {
                const x = b.a.eval(n);
                const y = b.b.eval(n);
                break :blk switch (b.op) {
                    .@"or" => @intFromBool(x != 0 or y != 0),
                    .@"and" => @intFromBool(x != 0 and y != 0),
                    .eq => @intFromBool(x == y),
                    .ne => @intFromBool(x != y),
                    .lt => @intFromBool(x < y),
                    .le => @intFromBool(x <= y),
                    .gt => @intFromBool(x > y),
                    .ge => @intFromBool(x >= y),
                    .add => x +% y,
                    .sub => x -% y,
                    .mul => x *% y,
                    .div => if (y == 0) 0 else @divTrunc(x, y),
                    .mod => if (y == 0) 0 else @rem(x, y),
                };
            },
        };
    }
};

const PluralParser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: Allocator,
    depth: u32 = 0,

    const Error = error{ OutOfMemory, Invalid };

    fn skipSpace(p: *PluralParser) void {
        while (p.pos < p.src.len and std.ascii.isWhitespace(p.src[p.pos])) p.pos += 1;
    }

    fn eat(p: *PluralParser, s: []const u8) bool {
        p.skipSpace();
        if (!std.mem.startsWith(u8, p.src[p.pos..], s)) return false;
        p.pos += s.len;
        return true;
    }

    fn make(p: *PluralParser, e: PluralExpr) Error!*const PluralExpr {
        const r = try p.arena.create(PluralExpr);
        r.* = e;
        return r;
    }

    fn parseTernary(p: *PluralParser) Error!*const PluralExpr {
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > 64) return error.Invalid;
        const cond = try p.parseBinary(0);
        if (!p.eat("?")) return cond;
        const then = try p.parseTernary();
        if (!p.eat(":")) return error.Invalid;
        const otherwise = try p.parseTernary();
        return p.make(.{ .ternary = .{ .cond = cond, .then = then, .otherwise = otherwise } });
    }

    const levels = [_][]const struct { []const u8, PluralExpr.Op }{
        &.{.{ "||", .@"or" }},
        &.{.{ "&&", .@"and" }},
        &.{ .{ "==", .eq }, .{ "!=", .ne } },
        &.{ .{ "<=", .le }, .{ ">=", .ge }, .{ "<", .lt }, .{ ">", .gt } },
        &.{ .{ "+", .add }, .{ "-", .sub } },
        &.{ .{ "*", .mul }, .{ "/", .div }, .{ "%", .mod } },
    };

    fn parseBinary(p: *PluralParser, level: usize) Error!*const PluralExpr {
        if (level == levels.len) return p.parseUnary();
        var lhs = try p.parseBinary(level + 1);
        outer: while (true) {
            for (levels[level]) |op| {
                if (p.eat(op[0])) {
                    const rhs = try p.parseBinary(level + 1);
                    lhs = try p.make(.{ .binary = .{ .op = op[1], .a = lhs, .b = rhs } });
                    continue :outer;
                }
            }
            return lhs;
        }
    }

    fn parseUnary(p: *PluralParser) Error!*const PluralExpr {
        if (p.eat("!")) return p.make(.{ .not = try p.parseUnary() });
        if (p.eat("(")) {
            const e = try p.parseTernary();
            if (!p.eat(")")) return error.Invalid;
            return e;
        }
        p.skipSpace();
        if (p.pos < p.src.len and p.src[p.pos] == 'n') {
            p.pos += 1;
            return p.make(.n);
        }
        const start = p.pos;
        while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;
        if (p.pos == start) return error.Invalid;
        const v = std.fmt.parseInt(i64, p.src[start..p.pos], 10) catch return error.Invalid;
        return p.make(.{ .int = v });
    }
};

const testing = std.testing;

fn formatted(template: []const u8, args: []const Arg, n: i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try format(&out.writer, template, args, n);
    return out.toOwnedSlice();
}

test "templates take arguments in order, by position, and the count" {
    const s = try formatted("{} has {1} {{items}}: {0}, n={n}, {x}", &.{ .{ .string = "Ada" }, .{ .int = 3 } }, 7);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("Ada has 3 {items}: Ada, n=7, {x}", s);
}

test "without a translator, the source text and English plurals" {
    setTranslator(null);
    try testing.expectEqualStrings("Hello", translate(.{ .id = "Hello" }));
    try testing.expectEqualStrings("{n} file", translate(.{ .id = "{n} file", .plural = "{n} files", .n = 1 }));
    try testing.expectEqualStrings("{n} files", translate(.{ .id = "{n} file", .plural = "{n} files", .n = 0 }));
}

test "catalogs from .po files, with contexts, plurals and fuzzy entries" {
    const po =
        \\# A comment
        \\msgid ""
        \\msgstr ""
        \\"Content-Type: text/plain; charset=UTF-8\n"
        \\"Plural-Forms: nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);\n"
        \\
        \\msgid "Hello"
        \\msgstr "Witaj"
        \\
        \\msgctxt "menu"
        \\msgid "Open"
        \\msgstr "Otwórz"
        \\
        \\msgid "{n} file"
        \\msgid_plural "{n} files"
        \\msgstr[0] "{n} plik"
        \\msgstr[1] "{n} pliki"
        \\msgstr[2] "{n} plików"
        \\
        \\#, fuzzy
        \\msgid "Close"
        \\msgstr "Zamknij?"
        \\
        \\msgid "Multi"
        \\msgstr ""
        \\"line\n"
        \\"text \"quoted\""
        \\
    ;
    var cat: Catalog = try .parse(testing.allocator, po);
    defer cat.deinit();
    try testing.expectEqualStrings("Witaj", cat.lookup(.{ .id = "Hello" }).?);
    try testing.expectEqualStrings("Otwórz", cat.lookup(.{ .context = "menu", .id = "Open" }).?);
    try testing.expect(cat.lookup(.{ .id = "Open" }) == null);
    try testing.expect(cat.lookup(.{ .id = "Close" }) == null); // fuzzy
    try testing.expectEqualStrings("line\ntext \"quoted\"", cat.lookup(.{ .id = "Multi" }).?);
    const plural = struct {
        fn of(c: *const Catalog, n: i64) []const u8 {
            return c.lookup(.{ .id = "{n} file", .plural = "{n} files", .n = n }).?;
        }
    }.of;
    try testing.expectEqualStrings("{n} plik", plural(&cat, 1));
    try testing.expectEqualStrings("{n} pliki", plural(&cat, 3));
    try testing.expectEqualStrings("{n} plików", plural(&cat, 5));
    try testing.expectEqualStrings("{n} plików", plural(&cat, 12));
    try testing.expectEqualStrings("{n} pliki", plural(&cat, 22));

    setTranslator(cat.translator());
    defer setTranslator(null);
    try testing.expectEqualStrings("Witaj", translate(.{ .id = "Hello" }));
    try testing.expectEqualStrings("Untranslated", translate(.{ .id = "Untranslated" }));
}

test "invalid catalogs are rejected" {
    try testing.expectError(error.InvalidPo, Catalog.parse(testing.allocator, "msgid \"a\"\nmsgstr \"b"));
    try testing.expectError(error.InvalidPo, Catalog.parse(testing.allocator, "bogus line"));
    try testing.expectError(error.InvalidPo, Catalog.parse(testing.allocator, "msgid \"\"\nmsgstr \"Plural-Forms: nplurals=2; plural=(n;\\n\"\n"));
}
