// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Rich text: `StyledText` shows a Markdown subset (or an HTML one),
//! wrapped to its width, its text selectable.
//!
//! Inline: `**bold**` (or `__bold__`), `*italic*` (or `_italic_`),
//! `~~struck~~`, `` `code` ``, `[links](url)`, `\` before a character
//! that would mark something. Blocks: paragraphs (blank lines between
//! them), `#` to `######` headings, `-`, `*` or `+` bullets and `1.`
//! numbered items (nested by indenting two spaces), tables (`| a | b |`
//! rows under a header and a `| --- | --- |` line), a line ending in two
//! spaces or `\` breaks there. Italics are slanted (no italic fonts);
//! bold is the family's weight 700.
//!
//! `![alt](url)` shows an image (see `StyledText`), wrapping as a word.
//!
//! HTML (`parseHtml`): `p`, `div`, `br`, `h1` to `h6`, `ul`, `ol`, `li`,
//! `b`, `strong`, `i`, `em`, `s`, `del`, `u`, `ins`, `code`, `tt`,
//! `a href`, `img src` (`width`, `height`, `alt`), `table`, `tr`, `th`,
//! `td`, `center`, `blockquote`, and entities; colors and fonts from
//! `font` (`color`, `face`, `size`), `span`, `mark`, `big`, `small`, and
//! CSS: `style` elements and attributes, and a stylesheet given
//! (`color`, `background-color`, `font-family`, `font-size`,
//! `font-weight`, `font-style`, `text-decoration`, `text-align`, `float`
//! and sizes for images), its rules for tags, classes and ids. Other tags
//! are left out, their text kept (not `script`'s). Markdown is styled by
//! a stylesheet as the HTML it stands for (`styleMarkdown`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const Callback = @import("callbacks.zig").Callback;
const geometry = @import("geometry.zig");
const Size = geometry.Size;
const Rect = geometry.Rect;
const Point = geometry.Point;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const ItemVTable = item_mod.ItemVTable;
const layout = @import("layout.zig");
const LayoutInfo = layout.LayoutInfo;
const Orientation = layout.Orientation;
const rendering = @import("rendering.zig");
const ItemRenderer = rendering.ItemRenderer;
const Brush = @import("graphics.zig").Brush;
const text_mod = @import("text/text.zig");
const Font = text_mod.Font;
const input = @import("input.zig");
const Window = @import("window.zig").Window;
const items = @import("items.zig");
const StringBuffer = @import("strings.zig").StringBuffer;
const text_edit = @import("text_edit.zig");
const time = @import("time.zig");
const Color = @import("graphics.zig").Color;
const image = @import("image.zig");
const image_loader = @import("image_loader.zig");
const parseColor = @import("svg.zig").parseColor;
const Timer = @import("timers.zig").Timer;

const log = std.log.scoped(.zigulee_richtext);

// ---- Markdown ----

pub const Run = struct {
    text: []const u8,
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    strike: bool = false,
    /// Index into `Doc.links`.
    link: ?u32 = null,
    /// A line break before it.
    newline: bool = false,
    underline: bool = false,
    /// From HTML: its color and background (else the element's), its
    /// font family (else the element's), and its size: in pixels (if not
    /// 0), else as a share of the block's.
    color: ?Color = null,
    background: ?Color = null,
    family: []const u8 = "",
    px: f32 = 0,
    scale: f32 = 1,
    /// An image (index into `Doc.images`), `text` its alternative text.
    image: ?u32 = null,
};

/// Where a block's lines go across: as `horizontal-alignment`, or
/// justified (each line but the last, and those ending in a break, as
/// wide as the box; spaces widened).
pub const Align = enum { left, center, right, justify };

/// An image in the text: where from, the size it is asked for (else its
/// own, kept in proportion), and the text shown if it cannot be.
pub const ImageRef = struct {
    url: []const u8,
    width: ?f32 = null,
    height: ?f32 = null,
    alt: []const u8 = "",
    /// Beside the text, at the left or right (HTML's `float` or `align`),
    /// the lines after it going round it.
    float: ?enum { left, right } = null,
};

pub const Block = struct {
    kind: Kind = .paragraph,
    /// Headings: 1 to 6.
    level: u8 = 0,
    /// List items: how deep (0: not nested).
    depth: u8 = 0,
    /// Numbered items: the number.
    number: u32 = 0,
    runs: []const Run = &.{},
    /// Tables: rows of cells (each its runs), the first row a header when
    /// `header`.
    rows: []const []const []const Run = &.{},
    header: bool = false,
    /// HTML's `align` or `text-align` (else the element's
    /// `horizontal-alignment`).
    alignment: ?Align = null,
    /// Tables: each cell's (rows of cells, as `rows`; Markdown's by
    /// column, from the line under the header).
    cell_alignments: []const []const ?Align = &.{},

    pub const Kind = enum { paragraph, heading, bullet, numbered, table };
};

/// What `StyledText.text` is written in.
pub const TextFormat = enum { markdown, html };

pub const Doc = struct {
    blocks: []const Block,
    links: []const []const u8,
    images: []const ImageRef = &.{},
    /// The text without its marks (for assistive technology).
    plain: []const u8,
};

const Line = struct { kind: Block.Kind, level: u8 = 0, depth: u8 = 0, number: u32 = 0, text: []const u8 };

/// What a source line starts: a heading, a list item, or more of the
/// paragraph (or item) before it.
fn classify(raw: []const u8) ?Line {
    var spaces: usize = 0;
    while (spaces < raw.len and raw[spaces] == ' ') spaces += 1;
    const s = raw[spaces..];
    if (s.len == 0) return null;
    var hashes: usize = 0;
    while (hashes < s.len and hashes < 7 and s[hashes] == '#') hashes += 1;
    if (hashes >= 1 and hashes <= 6 and (hashes == s.len or s[hashes] == ' '))
        return .{ .kind = .heading, .level = @intCast(hashes), .text = std.mem.trim(u8, s[hashes..], " #") };
    const depth: u8 = @intCast(@min(spaces / 2, 8));
    if (s.len >= 2 and (s[0] == '-' or s[0] == '*' or s[0] == '+') and s[1] == ' ')
        return .{ .kind = .bullet, .depth = depth, .text = s[2..] };
    var digits: usize = 0;
    while (digits < s.len and digits < 9 and std.ascii.isDigit(s[digits])) digits += 1;
    if (digits > 0 and digits + 1 < s.len and (s[digits] == '.' or s[digits] == ')') and s[digits + 1] == ' ')
        return .{ .kind = .numbered, .depth = depth, .number = std.fmt.parseInt(u32, s[0..digits], 10) catch 1, .text = s[digits + 2 ..] };
    return .{ .kind = .paragraph, .text = s };
}

/// Parses `src` (everything allocated with `a`, an arena).
pub fn parse(a: Allocator, src: []const u8) Allocator.Error!Doc {
    var blocks: std.ArrayList(Block) = .empty;
    var refs: Refs = .{};
    // The block being read: its first line, and its text so far (lines
    // joined; '\n' where a line breaks).
    var current: ?Line = null;
    var text: std.ArrayList(u8) = .empty;

    var all: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, src, '\n');
    while (split.next()) |l| try all.append(a, std.mem.trimEnd(u8, l, "\r"));
    var i: usize = 0;
    while (true) : (i += 1) {
        const next: ?[]const u8 = if (i < all.items.len) all.items[i] else null;
        const raw = next orelse "";
        // A table: a row, then a line of dashes under it.
        const table = next != null and isTableRow(raw) and i + 1 < all.items.len and isTableRule(all.items[i + 1]);
        const line = if (next == null or table) null else classify(raw);
        // Another block: a blank line, a heading, an item, a table, the end.
        const ends = next == null or line == null or line.?.kind != .paragraph or (current != null and current.?.kind == .heading);
        if (ends) if (current) |c| {
            const runs = try parseInline(a, text.items, &refs);
            try blocks.append(a, .{ .kind = c.kind, .level = c.level, .depth = c.depth, .number = c.number, .runs = runs });
            current = null;
            text = .empty;
        };
        if (next == null) break;
        if (table) {
            var rows: std.ArrayList([]const []const Run) = .empty;
            try rows.append(a, try tableCells(a, raw, &refs));
            const columns = try columnAligns(a, all.items[i + 1]);
            i += 2;
            while (i < all.items.len and isTableRow(all.items[i])) : (i += 1) try rows.append(a, try tableCells(a, all.items[i], &refs));
            i -= 1;
            // Each row's cells by their columns'.
            const aligns = try a.alloc([]const ?Align, rows.items.len);
            @memset(aligns, columns);
            try blocks.append(a, .{ .kind = .table, .rows = rows.items, .header = true, .cell_alignments = aligns });
            continue;
        }
        const l = line orelse continue;
        if (current == null) {
            current = l;
        } else if (text.items.len > 0 and text.items[text.items.len - 1] != '\n') try text.append(a, ' ');
        // Two spaces or a backslash at the end: a line break.
        var body = std.mem.trimStart(u8, l.text, " ");
        const hard = std.mem.endsWith(u8, body, "  ") or (std.mem.endsWith(u8, body, "\\") and !std.mem.endsWith(u8, body, "\\\\"));
        body = std.mem.trimEnd(u8, body, " ");
        if (hard and std.mem.endsWith(u8, body, "\\")) body = body[0 .. body.len - 1];
        try text.appendSlice(a, body);
        if (hard) try text.append(a, '\n');
    }
    return .{ .blocks = blocks.items, .links = refs.links.items, .images = refs.images.items, .plain = try plainText(a, blocks.items) };
}

/// The links and images met while reading.
const Refs = struct {
    links: std.ArrayList([]const u8) = .empty,
    images: std.ArrayList(ImageRef) = .empty,
};

/// The text of `blocks` without its marks: blocks on lines of their own,
/// a table's cells a tab apart.
fn plainText(a: Allocator, blocks: []const Block) Allocator.Error![]const u8 {
    var plain: std.ArrayList(u8) = .empty;
    for (blocks) |b| {
        if (plain.items.len > 0) try plain.append(a, '\n');
        if (b.kind == .table) {
            for (b.rows, 0..) |row, r| {
                if (r > 0) try plain.append(a, '\n');
                for (row, 0..) |cell, c| {
                    if (c > 0) try plain.append(a, '\t');
                    for (cell) |run| try plain.appendSlice(a, run.text);
                }
            }
            continue;
        }
        for (b.runs) |r| {
            if (r.newline) try plain.append(a, '\n');
            try plain.appendSlice(a, r.text);
        }
    }
    return plain.items;
}

/// Whether `line` has a `|` (not after `\`).
fn hasPipe(line: []const u8) bool {
    var k: usize = 0;
    while (k < line.len) : (k += 1) {
        if (line[k] == '\\') {
            k += 1;
            continue;
        }
        if (line[k] == '|') return true;
    }
    return false;
}

fn isTableRow(line: []const u8) bool {
    return std.mem.trim(u8, line, " ").len > 0 and hasPipe(line);
}

/// `| --- | :---: |`: dashes (and colons) between pipes.
fn isTableRule(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " ");
    if (std.mem.indexOfScalar(u8, t, '-') == null) return false;
    for (t) |c| if (c != '|' and c != '-' and c != ':' and c != ' ') return false;
    return std.mem.indexOfScalar(u8, t, '|') != null;
}

/// The alignments the line under a table's header gives its columns:
/// `:---` left, `:---:` center, `---:` right.
fn columnAligns(a: Allocator, line: []const u8) Allocator.Error![]const ?Align {
    var t = std.mem.trim(u8, line, " ");
    if (t.len > 0 and t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|') t = t[0 .. t.len - 1];
    var out: std.ArrayList(?Align) = .empty;
    var it = std.mem.splitScalar(u8, t, '|');
    while (it.next()) |cell| {
        const c = std.mem.trim(u8, cell, " ");
        const left = c.len > 0 and c[0] == ':';
        const right = c.len > 0 and c[c.len - 1] == ':';
        try out.append(a, if (left and right and c.len > 1) .center else if (right) .right else if (left) .left else null);
    }
    return out.items;
}

/// A table row's cells (between pipes; the outer ones optional).
fn tableCells(a: Allocator, line: []const u8, refs: *Refs) Allocator.Error![]const []const Run {
    var t = std.mem.trim(u8, line, " ");
    if (t.len > 0 and t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|' and !(t.len > 1 and t[t.len - 2] == '\\')) t = t[0 .. t.len - 1];
    var cells: std.ArrayList([]const Run) = .empty;
    var start: usize = 0;
    var k: usize = 0;
    while (k <= t.len) : (k += 1) {
        if (k < t.len and t[k] == '\\') {
            k += 1;
            continue;
        }
        if (k >= t.len or t[k] == '|') {
            const end = @min(k, t.len);
            try cells.append(a, try parseInline(a, std.mem.trim(u8, t[@min(start, end)..end], " "), refs));
            start = k + 1;
        }
    }
    return cells.items;
}

// ---- HTML ----

/// Reads an HTML subset (see the file's comment) into the same blocks as
/// Markdown.
pub fn parseHtml(a: Allocator, src: []const u8) Allocator.Error!Doc {
    return parseHtmlStyled(a, src, "");
}

/// `parseHtml`, with `sheet`'s rules (CSS) before the text's own `style`
/// elements'.
pub fn parseHtmlStyled(a: Allocator, src: []const u8, sheet: []const u8) Allocator.Error!Doc {
    var r: HtmlReader = .{ .a = a };
    try r.sheet.read(a, sheet);
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] != '<') {
            const end = std.mem.indexOfScalarPos(u8, src, i, '<') orelse src.len;
            if (r.skipping == null) {
                try r.addText(src[i..end]);
            } else if (std.mem.eql(u8, r.skipping.?, "style")) try r.style_text.appendSlice(a, src[i..end]);
            i = end;
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], "<!--")) {
            i = if (std.mem.indexOfPos(u8, src, i + 4, "-->")) |e| e + 3 else src.len;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, src, i, '>') orelse src.len;
        try r.tag(src[i + 1 .. end]);
        i = @min(end + 1, src.len);
    }
    try r.endBlock();
    try r.endTable();
    return .{ .blocks = r.blocks.items, .links = r.links.items, .images = r.images.items, .plain = try plainText(a, r.blocks.items) };
}

const HtmlReader = struct {
    a: Allocator,
    blocks: std.ArrayList(Block) = .empty,
    links: std.ArrayList([]const u8) = .empty,
    images: std.ArrayList(ImageRef) = .empty,
    /// The block being read, its runs, and the text of the run being read.
    block: Block = .{},
    runs: std.ArrayList(Run) = .empty,
    text: std.ArrayList(u8) = .empty,
    link: ?u32 = null,
    /// The style read (from tags, stylesheets and `style`), and those it
    /// replaced: until their tags close, or their block ends.
    look: Look = .{},
    looks: std.ArrayList(Saved) = .empty,
    sheet: StyleSheet = .{},
    /// A `style` element's text, until it closes.
    style_text: std.ArrayList(u8) = .empty,
    /// A `br` before the next text.
    newline: bool = false,
    /// The last thing written was a space (or nothing yet): spaces after it
    /// are left out.
    space: bool = true,
    lists: std.ArrayList(List) = .empty,
    /// The table being read: its rows, and the cells of the row (with
    /// their alignments).
    rows: ?std.ArrayList([]const []const Run) = null,
    cells: std.ArrayList([]const Run) = .empty,
    row_aligns: std.ArrayList([]const ?Align) = .empty,
    cell_aligns: std.ArrayList(?Align) = .empty,
    in_cell: bool = false,
    header: bool = false,
    /// In `script` or `style`, until it closes.
    skipping: ?[]const u8 = null,

    const List = struct { ordered: bool, count: u32 };
    /// What a look was pushed by: an inline tag, a block (until it ends),
    /// or something holding blocks (`div`, until it closes).
    const Kind = enum { inline_tag, block, container };
    const Saved = struct { look: Look, kind: Kind };

    fn addText(r: *HtmlReader, raw: []const u8) Allocator.Error!void {
        var k: usize = 0;
        while (k < raw.len) {
            if (raw[k] == '&') if (entity(raw[k..])) |e| {
                try r.text.appendSlice(r.a, e.text);
                r.space = false;
                k += e.len;
                continue;
            };
            const c = raw[k];
            k += 1;
            if (c == ' ' or c == '\n' or c == '\t' or c == '\r') {
                if (!r.space) try r.text.append(r.a, ' ');
                r.space = true;
                continue;
            }
            try r.text.append(r.a, c);
            r.space = false;
        }
    }

    /// Ends the run being read (its style changes, a break, the block's
    /// end).
    fn flush(r: *HtmlReader) Allocator.Error!void {
        if (r.text.items.len == 0) return;
        try r.runs.append(r.a, r.run(r.text.items));
        r.text = .empty;
        r.newline = false;
    }

    /// A run of `text` in the style read.
    fn run(r: *HtmlReader, text: []const u8) Run {
        return r.look.onto(.{ .text = text, .link = r.link, .newline = r.newline and r.runs.items.len > 0 });
    }

    /// Starts a look: the one read so far changed as `change` says.
    fn push(r: *HtmlReader, kind: Kind, change: Look.Change) Allocator.Error!void {
        try r.flush();
        try r.looks.append(r.a, .{ .look = r.look, .kind = kind });
        r.look.apply(change);
    }

    /// Back to the look before the latest tag of `kind` (if any is open).
    fn pop(r: *HtmlReader, kind: Kind) Allocator.Error!void {
        try r.flush();
        for (r.looks.items) |s| {
            if (s.kind == kind) break;
        } else return;
        while (r.looks.pop()) |saved| {
            r.look = saved.look;
            if (saved.kind == kind) return;
        }
    }

    /// A block ended: its look too.
    fn popBlock(r: *HtmlReader) void {
        while (r.looks.items.len > 0 and r.looks.items[r.looks.items.len - 1].kind == .block) r.look = r.looks.pop().?.look;
    }

    /// The runs read, their outer spaces left out.
    fn takeRuns(r: *HtmlReader) Allocator.Error![]const Run {
        try r.flush();
        r.newline = false;
        const runs = r.runs.items;
        r.runs = .empty;
        r.space = true;
        if (runs.len > 0) runs[runs.len - 1].text = std.mem.trimEnd(u8, runs[runs.len - 1].text, " ");
        return runs;
    }

    fn endBlock(r: *HtmlReader) Allocator.Error!void {
        if (r.rows != null) return r.endCell();
        const runs = try r.takeRuns();
        var b = r.block;
        // Its own alignment, or what holds it.
        b.alignment = r.look.text_align;
        r.popBlock();
        r.block = .{};
        if (runs.len == 0) return;
        b.runs = runs;
        try r.blocks.append(r.a, b);
    }

    fn endCell(r: *HtmlReader) Allocator.Error!void {
        if (!r.in_cell) return;
        r.in_cell = false;
        try r.cells.append(r.a, try r.takeRuns());
        try r.cell_aligns.append(r.a, r.look.text_align);
        r.popBlock();
    }

    fn endRow(r: *HtmlReader) Allocator.Error!void {
        try r.endCell();
        const rows = if (r.rows) |*rows| rows else return;
        if (r.cells.items.len > 0) {
            try rows.append(r.a, r.cells.items);
            try r.row_aligns.append(r.a, r.cell_aligns.items);
        }
        r.cells = .empty;
        r.cell_aligns = .empty;
    }

    fn endTable(r: *HtmlReader) Allocator.Error!void {
        try r.endRow();
        const rows = r.rows orelse return;
        r.rows = null;
        if (rows.items.len > 0) try r.blocks.append(r.a, .{ .kind = .table, .rows = rows.items, .header = r.header, .cell_alignments = r.row_aligns.items });
        r.row_aligns = .empty;
        r.header = false;
    }

    fn tag(r: *HtmlReader, body: []const u8) Allocator.Error!void {
        const closing = body.len > 0 and body[0] == '/';
        const rest = if (closing) body[1..] else body;
        var n: usize = 0;
        while (n < rest.len and std.ascii.isAlphanumeric(rest[n])) n += 1;
        var name_buf: [10]u8 = undefined;
        if (n == 0 or n > name_buf.len) return;
        const name = std.ascii.lowerString(&name_buf, rest[0..n]);
        const attrs = rest[n..];
        if (r.skipping) |s| {
            if (closing and std.mem.eql(u8, name, s)) {
                r.skipping = null;
                if (std.mem.eql(u8, s, "style")) {
                    try r.sheet.read(r.a, r.style_text.items);
                    r.style_text = .empty;
                }
            }
            return;
        }
        const eql = std.mem.eql;
        if (eql(u8, name, "script") or eql(u8, name, "style")) {
            if (!closing) r.skipping = if (eql(u8, name, "script")) "script" else "style";
        } else if (eql(u8, name, "div") or eql(u8, name, "center") or eql(u8, name, "blockquote")) {
            // Holds blocks: its look is theirs until it closes.
            try r.endBlock();
            if (closing) return r.pop(.container);
            var change = try r.changeFor(name, attrs);
            if (eql(u8, name, "center")) change.text_align = .center;
            try r.push(.container, change);
        } else if (eql(u8, name, "p")) {
            try r.endBlock();
            if (!closing) try r.push(.block, try r.changeFor(name, attrs));
        } else if (eql(u8, name, "br")) {
            try r.flush();
            r.newline = true;
            r.space = true;
        } else if (name.len == 2 and name[0] == 'h' and name[1] >= '1' and name[1] <= '6') {
            try r.endBlock();
            if (!closing) {
                r.block = .{ .kind = .heading, .level = name[1] - '0' };
                try r.push(.block, try r.changeFor(name, attrs));
            }
        } else if (eql(u8, name, "ul") or eql(u8, name, "ol")) {
            try r.endBlock();
            if (closing) {
                _ = r.lists.pop();
            } else try r.lists.append(r.a, .{ .ordered = name[0] == 'o', .count = 0 });
        } else if (eql(u8, name, "li")) {
            try r.endBlock();
            if (!closing) {
                const depth: u8 = @intCast(@min(r.lists.items.len -| 1, 8));
                if (r.lists.items.len > 0) {
                    const l = &r.lists.items[r.lists.items.len - 1];
                    l.count += 1;
                    r.block = if (l.ordered) .{ .kind = .numbered, .depth = depth, .number = l.count } else .{ .kind = .bullet, .depth = depth };
                } else r.block = .{ .kind = .bullet };
                try r.push(.block, try r.changeFor(name, attrs));
            }
        } else if (eql(u8, name, "table")) {
            if (closing) return r.endTable();
            try r.endBlock();
            try r.endTable();
            r.rows = .empty;
        } else if (eql(u8, name, "tr")) {
            try r.endRow();
        } else if (eql(u8, name, "td") or eql(u8, name, "th")) {
            if (r.rows == null) return;
            try r.endCell();
            if (closing) return;
            r.in_cell = true;
            if (name[1] == 'h' and r.rows.?.items.len == 0) r.header = true;
            try r.push(.block, try r.changeFor(name, attrs));
        } else if (eql(u8, name, "img")) {
            const src = attribute(attrs, "src") orelse return;
            try r.flush();
            const alt = try decode(r.a, attribute(attrs, "alt") orelse "");
            const css = (try r.changeFor(name, attrs)).css;
            const float_value = cssValue(css, "float") orelse attribute(attrs, "align") orelse "";
            try r.images.append(r.a, .{
                .url = try decode(r.a, src),
                .width = pixels(cssValue(css, "width")) orelse pixels(attribute(attrs, "width")),
                .height = pixels(cssValue(css, "height")) orelse pixels(attribute(attrs, "height")),
                .alt = alt,
                .float = if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, float_value, " "), "left"))
                    .left
                else if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, float_value, " "), "right"))
                    .right
                else
                    null,
            });
            var img = r.run(alt);
            img.image = @intCast(r.images.items.len - 1);
            try r.runs.append(r.a, img);
            r.newline = false;
            r.space = false;
        } else if (inlineTag(name)) {
            if (closing) {
                try r.pop(.inline_tag);
                if (eql(u8, name, "a")) r.link = null;
                return;
            }
            const change = try r.changeFor(name, attrs);
            try r.push(.inline_tag, change);
            if (eql(u8, name, "a")) {
                r.link = null;
                if (attribute(attrs, "href")) |href| {
                    try r.links.append(r.a, try decode(r.a, href));
                    r.link = @intCast(r.links.items.len - 1);
                }
            }
        }
    }

    fn changeFor(r: *HtmlReader, name: []const u8, attrs: []const u8) Allocator.Error!Look.Change {
        return tagChange(r.a, &r.sheet, name, attrs);
    }
};

/// What tag `name` with `attrs` changes: what the tag means, then the
/// stylesheet's rules for it, then its own `style`.
fn tagChange(a: Allocator, sheet: *const StyleSheet, name: []const u8, attrs: []const u8) Allocator.Error!Look.Change {
    var c: Look.Change = .{ .css = try sheet.css(a, name, attrs) };
    const eql = std.mem.eql;
    if (attribute(attrs, "align")) |v| c.text_align = textAlign(v);
    if (eql(u8, name, "b") or eql(u8, name, "strong")) {
        c.bold = true;
    } else if (eql(u8, name, "i") or eql(u8, name, "em")) {
        c.italic = true;
    } else if (eql(u8, name, "s") or eql(u8, name, "del") or eql(u8, name, "strike")) {
        c.strike = true;
    } else if (eql(u8, name, "u") or eql(u8, name, "ins")) {
        c.underline = true;
    } else if (eql(u8, name, "code") or eql(u8, name, "tt") or eql(u8, name, "kbd")) {
        c.code = true;
    } else if (eql(u8, name, "font")) {
        c.color = attribute(attrs, "color");
        c.face = attribute(attrs, "face");
        c.size = attribute(attrs, "size");
    } else if (eql(u8, name, "mark")) {
        c.background = .rgb(0xffff00);
    } else if (eql(u8, name, "big") or eql(u8, name, "small")) {
        c.scale = if (name[0] == 'b') 1.2 else 1.0 / 1.2;
    }
    return c;
}

/// Markdown's text styled by `sheet` as the HTML it stands for: `p`,
/// `h1` to `h6`, `li`, `td` and `th`, and in them `strong`, `em`, `del`,
/// `code` and `a`.
pub fn styleMarkdown(a: Allocator, doc: Doc, sheet_text: []const u8) Allocator.Error!Doc {
    var sheet: StyleSheet = .{};
    try sheet.read(a, sheet_text);
    if (sheet.rules.items.len == 0) return doc;
    const blocks = try a.dupe(Block, doc.blocks);
    for (blocks) |*b| {
        if (b.kind == .table) {
            const rows = try a.alloc([]const []const Run, b.rows.len);
            const aligns = try a.alloc([]const ?Align, b.rows.len);
            for (b.rows, 0..) |row, r| {
                const cells = try a.alloc([]const Run, row.len);
                const cell_aligns = try a.alloc(?Align, row.len);
                for (row, 0..) |cell, c| {
                    var look: Look = .{};
                    look.apply(try tagChange(a, &sheet, if (b.header and r == 0) "th" else "td", ""));
                    cells[c] = try styleRuns(a, &sheet, look, cell);
                    const column: ?Align = if (r < b.cell_alignments.len and c < b.cell_alignments[r].len) b.cell_alignments[r][c] else null;
                    cell_aligns[c] = look.text_align orelse column;
                }
                rows[r] = cells;
                aligns[r] = cell_aligns;
            }
            b.rows = rows;
            b.cell_alignments = aligns;
            continue;
        }
        var name_buf: [2]u8 = .{ 'h', '1' };
        const name: []const u8 = switch (b.kind) {
            .heading => blk: {
                name_buf[1] = '0' + @as(u8, @min(b.level, 6));
                break :blk &name_buf;
            },
            .bullet, .numbered => "li",
            else => "p",
        };
        var look: Look = .{};
        look.apply(try tagChange(a, &sheet, name, ""));
        b.alignment = look.text_align;
        b.runs = try styleRuns(a, &sheet, look, b.runs);
    }
    return .{ .blocks = blocks, .links = doc.links, .images = doc.images, .plain = doc.plain };
}

/// `runs` in `look`, with their own styles' tags' rules over it.
fn styleRuns(a: Allocator, sheet: *const StyleSheet, look: Look, runs: []const Run) Allocator.Error![]const Run {
    const out = try a.alloc(Run, runs.len);
    for (runs, out) |run, *o| {
        var l = look;
        if (run.link != null) l.apply(try tagChange(a, sheet, "a", ""));
        if (run.bold) l.apply(try tagChange(a, sheet, "strong", ""));
        if (run.italic) l.apply(try tagChange(a, sheet, "em", ""));
        if (run.strike) l.apply(try tagChange(a, sheet, "del", ""));
        if (run.code) l.apply(try tagChange(a, sheet, "code", ""));
        o.* = l.onto(run);
    }
    return out;
}

/// Tags styling the text inside them.
fn inlineTag(name: []const u8) bool {
    const tags = [_][]const u8{ "a", "b", "strong", "i", "em", "s", "del", "strike", "u", "ins", "code", "tt", "kbd", "span", "font", "mark", "big", "small" };
    for (tags) |t| if (std.mem.eql(u8, name, t)) return true;
    return false;
}

/// CSS rules from `style` elements (or `StyledText.style-sheet`): their
/// selectors (`p`, `.note`, `#top`, `td.num`, `*`, comma lists; others,
/// such as descendants, are left out) and declarations.
const StyleSheet = struct {
    rules: std.ArrayList(CssRule) = .empty,

    const CssRule = struct {
        tag: []const u8,
        id: []const u8,
        classes: []const []const u8,
        css: []const u8,
        /// Ids count most, then classes, then tags; then the later rule.
        specificity: u32,
        order: u32,
    };

    fn read(s: *StyleSheet, a: Allocator, text: []const u8) Allocator.Error!void {
        // Without comments.
        var src: std.ArrayList(u8) = .empty;
        var k: usize = 0;
        while (k < text.len) {
            if (std.mem.startsWith(u8, text[k..], "/*")) {
                k = if (std.mem.indexOfPos(u8, text, k + 2, "*/")) |e| e + 2 else text.len;
                continue;
            }
            try src.append(a, text[k]);
            k += 1;
        }
        const t = src.items;
        k = 0;
        while (k < t.len) {
            const open = std.mem.indexOfScalarPos(u8, t, k, '{') orelse break;
            const selectors = std.mem.trim(u8, t[k..open], " \t\n\r");
            // The block's end (at-rules nest theirs: left out).
            var depth: usize = 0;
            var close = open;
            while (close < t.len) : (close += 1) {
                if (t[close] == '{') depth += 1;
                if (t[close] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            const body = t[open + 1 .. @min(close, t.len)];
            k = close + 1;
            if (selectors.len == 0 or selectors[0] == '@') continue;
            var list = std.mem.splitScalar(u8, selectors, ',');
            while (list.next()) |sel| if (try parseSelector(a, std.mem.trim(u8, sel, " \t\n\r"))) |rule| {
                var r = rule;
                r.css = body;
                r.order = @intCast(s.rules.items.len);
                try s.rules.append(a, r);
            };
        }
    }

    /// `tag`, `.class`, `#id` together; null for other selectors.
    fn parseSelector(a: Allocator, sel: []const u8) Allocator.Error!?CssRule {
        if (sel.len == 0) return null;
        var rule: CssRule = .{ .tag = "", .id = "", .classes = &.{}, .css = "", .specificity = 0, .order = 0 };
        var classes: std.ArrayList([]const u8) = .empty;
        var k: usize = 0;
        const name = struct {
            fn end(s: []const u8, from: usize) usize {
                var e = from;
                while (e < s.len and (std.ascii.isAlphanumeric(s[e]) or s[e] == '-' or s[e] == '_')) e += 1;
                return e;
            }
        }.end;
        if (sel[0] == '*') {
            k = 1;
        } else if (std.ascii.isAlphabetic(sel[0])) {
            k = name(sel, 0);
            rule.tag = try std.ascii.allocLowerString(a, sel[0..k]);
            rule.specificity += 1;
        }
        while (k < sel.len) {
            const c = sel[k];
            if (c != '.' and c != '#') return null;
            const e = name(sel, k + 1);
            if (e == k + 1) return null;
            if (c == '.') {
                try classes.append(a, sel[k + 1 .. e]);
                rule.specificity += 100;
            } else {
                rule.id = sel[k + 1 .. e];
                rule.specificity += 10000;
            }
            k = e;
        }
        rule.classes = classes.items;
        return rule;
    }

    /// The declarations for tag `name` with `attrs`: the rules matching
    /// it, the most specific last, then its `style`.
    fn css(s: *const StyleSheet, a: Allocator, name: []const u8, attrs: []const u8) Allocator.Error![]const u8 {
        const own = attribute(attrs, "style") orelse "";
        if (s.rules.items.len == 0) return own;
        const id = attribute(attrs, "id") orelse "";
        const class_list = attribute(attrs, "class") orelse "";
        var matched: std.ArrayList(*const CssRule) = .empty;
        for (s.rules.items) |*rule| {
            if (rule.tag.len > 0 and !std.mem.eql(u8, rule.tag, name)) continue;
            if (rule.id.len > 0 and !std.mem.eql(u8, rule.id, id)) continue;
            const all = for (rule.classes) |want| {
                var it = std.mem.tokenizeAny(u8, class_list, " \t\n\r");
                while (it.next()) |have| {
                    if (std.mem.eql(u8, have, want)) break;
                } else break false;
            } else true;
            if (all) try matched.append(a, rule);
        }
        if (matched.items.len == 0) return own;
        std.mem.sort(*const CssRule, matched.items, {}, struct {
            fn less(_: void, x: *const CssRule, y: *const CssRule) bool {
                return if (x.specificity != y.specificity) x.specificity < y.specificity else x.order < y.order;
            }
        }.less);
        var out: std.ArrayList(u8) = .empty;
        for (matched.items) |rule| {
            try out.appendSlice(a, rule.css);
            try out.append(a, ';');
        }
        try out.appendSlice(a, own);
        return out.items;
    }
};

/// Colors and fonts set by HTML (null: as around it).
const Look = struct {
    color: ?Color = null,
    background: ?Color = null,
    family: []const u8 = "",
    code: bool = false,
    /// In pixels if not 0, else a share of the block's size.
    px: f32 = 0,
    scale: f32 = 1,
    bold: ?bool = null,
    italic: ?bool = null,
    underline: ?bool = null,
    strike: ?bool = null,
    /// Of the blocks it is on (inherited, as CSS's).
    text_align: ?Align = null,

    /// What a tag changes: what it means (`b`: bold), `font`'s
    /// attributes, `align`, then CSS.
    const Change = struct {
        css: []const u8 = "",
        color: ?[]const u8 = null,
        face: ?[]const u8 = null,
        size: ?[]const u8 = null,
        background: ?Color = null,
        scale: f32 = 1,
        bold: ?bool = null,
        italic: ?bool = null,
        strike: ?bool = null,
        underline: ?bool = null,
        code: bool = false,
        text_align: ?Align = null,
    };

    /// `run` in this look.
    fn onto(l: Look, run: Run) Run {
        var r = run;
        r.bold = l.bold orelse false;
        r.italic = l.italic orelse false;
        r.code = l.code;
        r.strike = l.strike orelse false;
        r.underline = l.underline orelse false;
        r.color = l.color;
        r.background = l.background;
        r.family = l.family;
        r.px = l.px;
        r.scale = l.scale;
        return r;
    }

    fn apply(l: *Look, c: Change) void {
        inline for (.{ "bold", "italic", "strike", "underline", "text_align" }) |f|
            if (@field(c, f)) |v| {
                @field(l, f) = v;
            };
        if (c.code) l.code = true;
        if (c.background) |b| l.background = b;
        if (c.scale != 1) l.resize(c.scale);
        if (c.color) |v| if (parseColor(std.mem.trim(u8, v, " "))) |col| {
            l.color = col;
        };
        if (c.face) |v| l.setFamily(v);
        if (c.size) |v| l.fontSize(v);
        var decls = std.mem.splitScalar(u8, c.css, ';');
        while (decls.next()) |d| {
            const colon = std.mem.indexOfScalar(u8, d, ':') orelse continue;
            l.property(std.mem.trim(u8, d[0..colon], " \t\n\r"), std.mem.trim(u8, d[colon + 1 ..], " \t\n\r"));
        }
    }

    fn property(l: *Look, name: []const u8, value: []const u8) void {
        const is = std.ascii.eqlIgnoreCase;
        const v = std.mem.trimEnd(u8, if (std.ascii.indexOfIgnoreCase(value, "!important")) |k| value[0..k] else value, " ");
        if (is(name, "color")) {
            if (parseColor(v)) |c| l.color = c;
        } else if (is(name, "background-color") or is(name, "background")) {
            if (parseColor(v)) |c| l.background = c;
        } else if (is(name, "font-family")) {
            l.setFamily(v);
        } else if (is(name, "font-size")) {
            l.cssSize(v);
        } else if (is(name, "font-weight")) {
            const n = std.fmt.parseInt(u16, v, 10) catch 0;
            if (is(v, "bold") or is(v, "bolder") or n >= 600) l.bold = true else if (is(v, "normal") or is(v, "lighter") or n > 0) l.bold = false;
        } else if (is(name, "text-align")) {
            if (textAlign(v)) |al| l.text_align = al;
        } else if (is(name, "font-style")) {
            l.italic = is(v, "italic") or is(v, "oblique");
        } else if (is(name, "text-decoration") or is(name, "text-decoration-line")) {
            if (std.ascii.indexOfIgnoreCase(v, "none") != null) {
                l.underline = false;
                l.strike = false;
            }
            if (std.ascii.indexOfIgnoreCase(v, "underline") != null) l.underline = true;
            if (std.ascii.indexOfIgnoreCase(v, "line-through") != null) l.strike = true;
        }
    }

    /// The first family of a list; `monospace` is the code font.
    fn setFamily(l: *Look, list: []const u8) void {
        var parts = std.mem.splitScalar(u8, list, ',');
        const first = std.mem.trim(u8, parts.first(), " \t\"'");
        if (first.len == 0) return;
        if (std.ascii.eqlIgnoreCase(first, "monospace")) {
            l.code = true;
            l.family = "";
        } else {
            l.code = false;
            l.family = first;
        }
    }

    /// Sizes larger or smaller by `k`.
    fn resize(l: *Look, k: f32) void {
        if (l.px > 0) l.px *= k else l.scale *= k;
    }

    /// `font`'s `size`: 1 to 7 (3 the text's own), or `+n`, `-n` from 3.
    fn fontSize(l: *Look, v: []const u8) void {
        const t = std.mem.trim(u8, v, " ");
        if (t.len == 0) return;
        const n = std.fmt.parseInt(i32, t, 10) catch return;
        const k = std.math.clamp(if (t[0] == '+' or t[0] == '-') 3 + n else n, 1, 7);
        const scales = [_]f32{ 0.63, 0.82, 1, 1.13, 1.5, 2, 3 };
        l.px = 0;
        l.scale = scales[@intCast(k - 1)];
    }

    /// CSS's `font-size`: px, pt, em, %, or a keyword.
    fn cssSize(l: *Look, v: []const u8) void {
        const keywords = [_]struct { []const u8, f32 }{
            .{ "xx-small", 0.6 }, .{ "x-small", 0.75 }, .{ "small", 0.89 }, .{ "medium", 1 },
            .{ "large", 1.2 },    .{ "x-large", 1.5 },  .{ "xx-large", 2 }, .{ "xxx-large", 3 },
        };
        for (keywords) |kw| if (std.ascii.eqlIgnoreCase(v, kw[0])) {
            l.px = 0;
            l.scale = kw[1];
            return;
        };
        if (std.ascii.eqlIgnoreCase(v, "larger")) return l.resize(1.2);
        if (std.ascii.eqlIgnoreCase(v, "smaller")) return l.resize(1.0 / 1.2);
        var units: usize = v.len;
        while (units > 0 and (std.ascii.isAlphabetic(v[units - 1]) or v[units - 1] == '%')) units -= 1;
        const n = std.fmt.parseFloat(f32, std.mem.trim(u8, v[0..units], " ")) catch return;
        if (!(n > 0)) return;
        const unit = v[units..];
        if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "px")) {
            l.px = n;
        } else if (std.ascii.eqlIgnoreCase(unit, "pt")) {
            l.px = n * 4 / 3;
        } else if (std.ascii.eqlIgnoreCase(unit, "em") or std.ascii.eqlIgnoreCase(unit, "rem")) {
            l.resize(n);
        } else if (std.mem.eql(u8, unit, "%")) {
            l.resize(n / 100);
        }
    }
};

/// `left`, `center`, `right`, `justify` (`start` and `end` as left and
/// right).
fn textAlign(v: []const u8) ?Align {
    const t = std.mem.trim(u8, v, " ");
    const is = std.ascii.eqlIgnoreCase;
    if (is(t, "center") or is(t, "middle")) return .center;
    if (is(t, "right") or is(t, "end")) return .right;
    if (is(t, "left") or is(t, "start")) return .left;
    if (is(t, "justify")) return .justify;
    return null;
}

/// The value of `name` in a `style` attribute's declarations (the last).
fn cssValue(css: []const u8, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var decls = std.mem.splitScalar(u8, css, ';');
    while (decls.next()) |d| {
        const colon = std.mem.indexOfScalar(u8, d, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, d[0..colon], " \t\n\r"), name)) found = std.mem.trim(u8, d[colon + 1 ..], " \t\n\r");
    }
    return found;
}

/// `url` as seen from `base` (as a browser resolves a page's links): kept
/// if it has a scheme or is absolute; else after `base`'s last `/` (a
/// directory needs its `/`), or after its host when it starts with `/`.
pub fn resolveUrl(a: Allocator, base: []const u8, url: []const u8) Allocator.Error![]const u8 {
    if (base.len == 0 or hasScheme(url)) return url;
    if (url.len > 0 and url[0] == '/') {
        // From the host of a `scheme://host/...` base; a path stays.
        const sep = std.mem.indexOf(u8, base, "://") orelse return url;
        const host_end = std.mem.indexOfScalarPos(u8, base, sep + 3, '/') orelse base.len;
        return std.mem.concat(a, u8, &.{ base[0..host_end], url });
    }
    // A `scheme://host` base without a path: its root.
    if (std.mem.indexOf(u8, base, "://")) |sep| if (std.mem.indexOfScalarPos(u8, base, sep + 3, '/') == null)
        return std.mem.concat(a, u8, &.{ base, "/", url });
    const dir = if (std.mem.lastIndexOfScalar(u8, base, '/')) |k| base[0 .. k + 1] else "";
    return std.mem.concat(a, u8, &.{ dir, url });
}

/// `scheme:` before any `/` (`https:`, `file:`, `data:`; not `C:\`).
fn hasScheme(url: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    if (colon < 2) return false;
    for (url[0..colon]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    return true;
}

/// An HTML length in pixels (`120`, `120px`).
fn pixels(v: ?[]const u8) ?f32 {
    const t = std.mem.trimEnd(u8, std.mem.trim(u8, v orelse return null, " "), "px");
    const n = std.fmt.parseFloat(f32, t) catch return null;
    return if (n > 0) n else null;
}

/// The value of attribute `name` in a tag's attributes, if there.
fn attribute(attrs: []const u8, name: []const u8) ?[]const u8 {
    var k: usize = 0;
    while (k < attrs.len) {
        while (k < attrs.len and (attrs[k] == ' ' or attrs[k] == '\n' or attrs[k] == '\t' or attrs[k] == '/')) k += 1;
        const start = k;
        while (k < attrs.len and attrs[k] != '=' and attrs[k] != ' ' and attrs[k] != '/') k += 1;
        const key = attrs[start..k];
        if (k >= attrs.len or attrs[k] != '=') {
            if (k == start) k += 1;
            continue;
        }
        k += 1;
        var value: []const u8 = "";
        if (k < attrs.len and (attrs[k] == '"' or attrs[k] == '\'')) {
            const q = attrs[k];
            const end = std.mem.indexOfScalarPos(u8, attrs, k + 1, q) orelse attrs.len;
            value = attrs[k + 1 .. end];
            k = @min(end + 1, attrs.len);
        } else {
            const vs = k;
            while (k < attrs.len and attrs[k] != ' ') k += 1;
            value = attrs[vs..k];
        }
        if (std.ascii.eqlIgnoreCase(key, name)) return value;
    }
    return null;
}

/// An entity at the start of `s` (`&amp;`, `&#38;`, `&#x26;`): its text
/// (valid until the next call) and length.
fn entity(s: []const u8) ?struct { text: []const u8, len: usize } {
    const semi = std.mem.indexOfScalar(u8, s[0..@min(s.len, 12)], ';') orelse return null;
    const name = s[1..semi];
    const named = [_]struct { []const u8, []const u8 }{
        .{ "amp", "&" },           .{ "lt", "<" },        .{ "gt", ">" },           .{ "quot", "\"" },
        .{ "apos", "'" },          .{ "nbsp", "\u{a0}" }, .{ "mdash", "\u{2014}" }, .{ "ndash", "\u{2013}" },
        .{ "hellip", "\u{2026}" }, .{ "copy", "\u{a9}" }, .{ "laquo", "\u{ab}" },   .{ "raquo", "\u{bb}" },
        .{ "euro", "\u{20ac}" },
    };
    for (named) |e| if (std.mem.eql(u8, name, e[0])) return .{ .text = e[1], .len = semi + 1 };
    if (name.len < 2 or name[0] != '#') return null;
    const hex = name[1] == 'x' or name[1] == 'X';
    const cp = std.fmt.parseInt(u21, name[if (hex) 2 else 1..], if (hex) 16 else 10) catch return null;
    const len = std.unicode.utf8Encode(cp, &entity_buf) catch return null;
    return .{ .text = entity_buf[0..len], .len = semi + 1 };
}

threadlocal var entity_buf: [4]u8 = undefined;

/// `s` with its entities replaced.
fn decode(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return a.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    var k: usize = 0;
    while (k < s.len) {
        if (s[k] == '&') if (entity(s[k..])) |e| {
            try out.appendSlice(a, e.text);
            k += e.len;
            continue;
        };
        try out.append(a, s[k]);
        k += 1;
    }
    return out.items;
}

fn isPunctuation(c: u8) bool {
    return std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ';
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// A block's text into runs of the same style.
fn parseInline(a: Allocator, s: []const u8, refs: *Refs) Allocator.Error![]const Run {
    var runs: std.ArrayList(Run) = .empty;
    var buf: std.ArrayList(u8) = .empty;
    var style: Run = .{ .text = "" };
    // Where the current link's label ends (its `]`), and after its `)`.
    var link_end: ?struct { close: usize, resume_at: usize } = null;
    var newline = false;

    const Flush = struct {
        fn f(al: Allocator, rs: *std.ArrayList(Run), b: *std.ArrayList(u8), st: Run, nl: *bool) Allocator.Error!void {
            if (b.items.len == 0 and !nl.*) return;
            var r = st;
            r.text = try b.toOwnedSlice(al);
            r.newline = nl.*;
            nl.* = false;
            try rs.append(al, r);
        }
    };

    var i: usize = 0;
    while (i < s.len) {
        if (link_end) |le| if (i == le.close) {
            try Flush.f(a, &runs, &buf, style, &newline);
            style.link = null;
            i = le.resume_at;
            link_end = null;
            continue;
        };
        const c = s[i];
        switch (c) {
            '\n' => {
                try Flush.f(a, &runs, &buf, style, &newline);
                newline = true;
                i += 1;
                continue;
            },
            '\\' => if (i + 1 < s.len and isPunctuation(s[i + 1])) {
                try buf.append(a, s[i + 1]);
                i += 2;
                continue;
            },
            '`' => if (std.mem.indexOfScalarPos(u8, s, i + 1, '`')) |end| {
                try Flush.f(a, &runs, &buf, style, &newline);
                try buf.appendSlice(a, s[i + 1 .. end]);
                var code = style;
                code.code = true;
                try Flush.f(a, &runs, &buf, code, &newline);
                i = end + 1;
                continue;
            },
            '~' => if (i + 1 < s.len and s[i + 1] == '~') {
                try Flush.f(a, &runs, &buf, style, &newline);
                style.strike = !style.strike;
                i += 2;
                continue;
            },
            '*', '_' => {
                const double = i + 1 < s.len and s[i + 1] == c;
                const n: usize = if (double) 2 else 1;
                const before: u8 = if (i > 0) s[i - 1] else ' ';
                const after: u8 = if (i + n < s.len) s[i + n] else ' ';
                // `_` inside a word (snake_case) is just a character.
                const marks = c == '*' or !isWordChar(before) or !isWordChar(after);
                // Opening: followed by text; closing: after it.
                const opens = after != ' ';
                const closes = before != ' ';
                if (marks and (if (double) (style.bold and closes) or (!style.bold and opens) else (style.italic and closes) or (!style.italic and opens))) {
                    try Flush.f(a, &runs, &buf, style, &newline);
                    if (double) style.bold = !style.bold else style.italic = !style.italic;
                    i += n;
                    continue;
                }
            },
            // `![alt](url)`: an image, in the style around it.
            '!' => if (i + 1 < s.len and s[i + 1] == '[') if (linkAt(s, i + 1)) |l| {
                try Flush.f(a, &runs, &buf, style, &newline);
                const alt = try a.dupe(u8, s[i + 2 .. l.close]);
                try refs.images.append(a, .{ .url = try a.dupe(u8, l.url), .alt = alt });
                var img = style;
                img.text = alt;
                img.image = @intCast(refs.images.items.len - 1);
                img.newline = newline;
                newline = false;
                try runs.append(a, img);
                i = l.resume_at;
                continue;
            },
            '[' => if (link_end == null) if (linkAt(s, i)) |l| {
                try Flush.f(a, &runs, &buf, style, &newline);
                try refs.links.append(a, try a.dupe(u8, l.url));
                style.link = @intCast(refs.links.items.len - 1);
                link_end = .{ .close = l.close, .resume_at = l.resume_at };
                i += 1;
                continue;
            },
            else => {},
        }
        try buf.append(a, c);
        i += 1;
    }
    try Flush.f(a, &runs, &buf, style, &newline);
    return runs.items;
}

/// `[label](url)` at `i`: where the label ends, its URL, and what follows.
fn linkAt(s: []const u8, i: usize) ?struct { close: usize, url: []const u8, resume_at: usize } {
    var depth: usize = 0;
    var j = i + 1;
    while (j < s.len) : (j += 1) switch (s[j]) {
        '\\' => j += 1,
        '[' => depth += 1,
        ']' => if (depth == 0) break else {
            depth -= 1;
        },
        else => {},
    };
    if (j + 1 >= s.len or s[j + 1] != '(') return null;
    const end = std.mem.indexOfScalarPos(u8, s, j + 2, ')') orelse return null;
    return .{ .close = j, .url = std.mem.trim(u8, s[j + 2 .. end], " "), .resume_at = end + 1 };
}

// ---- Layout ----

/// A piece of text placed: one style, on one line.
pub const Fragment = struct {
    rect: Rect,
    text: []const u8,
    font: ?*const Font,
    font_size: f32,
    run: Run,
    /// List markers ("•", "2.").
    marker: bool = false,
    /// An image (index into `Doc.images`) filling `rect`.
    image: ?u32 = null,
    /// The block it is in, and in a table, the row and the cell (from 1).
    block: u32 = 0,
    row: u32 = 0,
    cell: u32 = 0,

    /// Text that can be selected (not a marker or an image).
    fn textual(f: Fragment) bool {
        return !f.marker and f.image == null;
    }
};

/// A table's lines and its header's shade.
pub const Rule = struct { rect: Rect, shade: bool = false };

const Fonts = struct {
    regular: ?*const Font,
    bold: ?*const Font,
    code: ?*const Font,
    /// For runs of a family of their own: whose fonts, and the weight.
    item: ?*Item = null,
    weight: i32 = 400,
    /// Runs sized in pixels: times this (the size shown over `font-size`).
    px_scale: f32 = 1,

    /// A run's font size in a block of `size`.
    fn sizeOf(f: Fonts, run: Run, size: f32) f32 {
        return if (run.px > 0) run.px * f.px_scale else size * run.scale;
    }
};

/// Sizes text: with a font, or the window's measurer.
const Measure = struct {
    fallbacks: []const *const Font,
    measurer: rendering.TextMeasurer,
    /// Letter spacing.
    spacing: f32 = 0,
    /// The text's images, and how far each has loaded.
    images: []const ImageRef = &.{},
    shown: []const Shown = &.{},

    fn size(m: Measure, font: ?*const Font, font_size: f32, s: []const u8) Size {
        if (font) |f| return text_mod.layout.measureMetrics(text_mod.layout.Metrics.initFallbacks(f, m.fallbacks, font_size).withSpacing(m.spacing), s, null);
        return m.measurer.measure(s, font_size, null);
    }

    /// Image `k`'s size, no wider than `room`: the size asked for, or its
    /// own (kept in proportion with one asked for); none yet while it
    /// loads, unless asked for. Null if it cannot be shown (its
    /// alternative text is, instead).
    fn picture(m: Measure, k: u32, room: ?f32) ?Size {
        if (k >= m.images.len) return null;
        const ref = m.images[k];
        const shown: Shown = if (k < m.shown.len) m.shown[k] else .failed;
        var s: Size = switch (shown) {
            .failed => return null,
            .loading => if (ref.width != null and ref.height != null) .{ .width = ref.width.?, .height = ref.height.? } else return .{},
            .ready => |img| natural: {
                const w: f32 = @floatFromInt(img.width);
                const h: f32 = @floatFromInt(img.height);
                if (ref.width) |rw| break :natural .{ .width = rw, .height = ref.height orelse if (w > 0) h * rw / w else 0 };
                if (ref.height) |rh| break :natural .{ .width = if (h > 0) w * rh / h else 0, .height = rh };
                break :natural .{ .width = w, .height = h };
            },
        };
        if (room) |r| if (s.width > r and r > 0) {
            s.height *= r / s.width;
            s.width = r;
        };
        return s;
    }
};

/// How an image of the text has loaded.
pub const Shown = union(enum) { loading, ready: image.Image, failed };

const heading_scale = [_]f32{ 1, 1.6, 1.35, 1.15, 1.05, 1, 1 };

const Arranged = struct { fragments: []Fragment, rules: []Rule, size: Size, lines: []LineSpan = &.{} };

/// A line of text: its fragments, where it ends, the right edge it may
/// reach (null: the box's; less beside a float), its block's alignment,
/// and whether it is a paragraph's last (or ends in a break: not
/// justified).
const LineSpan = struct {
    start: usize,
    end: usize,
    right: f32,
    limit: ?f32 = null,
    alignment: ?Align = null,
    last: bool = false,
};

/// Moves `r`'s lines (not tables) to `alignment` in `width` (its widest
/// line's if null), or their blocks' own.
fn alignLines(r: Arranged, width: ?f32, alignment: rendering.TextHorizontalAlignment) void {
    const own: Align = switch (alignment) {
        .left => .left,
        .center => .center,
        .right => .right,
    };
    for (r.lines) |line| alignLine(r.fragments, line, line.limit orelse width orelse r.size.width, line.alignment orelse own, width != null);
}

/// Moves `line`'s fragments to `alignment` with its right edge at `box`;
/// `wrapped`: justified lines are widened (else left).
fn alignLine(fragments: []Fragment, line: LineSpan, box: f32, alignment: Align, wrapped: bool) void {
    const frags = fragments[line.start..line.end];
    const free = box - line.right;
    switch (alignment) {
        .left => {},
        .center, .right => {
            const dx = free * @as(f32, if (alignment == .center) 0.5 else 1);
            for (frags) |*f| f.rect.x += dx;
        },
        .justify => {
            if (line.last or !wrapped or free <= 0) return;
            // The space after each word widened alike (words are
            // fragments of their own in justified blocks).
            var gaps: usize = 0;
            for (frags[1..], 0..) |f, k| gaps += @intFromBool(gapBefore(frags[k], f));
            if (gaps == 0) return;
            const each = free / @as(f32, @floatFromInt(gaps));
            var dx: f32 = 0;
            for (frags[1..], 0..) |*f, k| {
                if (gapBefore(frags[k], f.*)) dx += each;
                f.rect.x += dx;
            }
        },
    }
}

/// Whether a justified line widens the space between `prev` and `f`.
fn gapBefore(prev: Fragment, f: Fragment) bool {
    return !prev.marker and f.textual() and (prev.image != null or std.mem.endsWith(u8, prev.text, " "));
}

fn fontFor(fonts: Fonts, run: Run) ?*const Font {
    if (run.family.len > 0 and !run.code) if (fonts.item) |i|
        return items.resolveFont(i, null, run.family, if (run.bold) @max(fonts.weight, 700) else fonts.weight);
    return if (run.code) fonts.code else if (run.bold) fonts.bold else fonts.regular;
}

/// Images floated beside the text, which lines go round.
const Floats = struct {
    placed: std.ArrayList(Fragment) = .empty,
    /// Between a float and the text beside it.
    gap: f32,

    /// The room a line at `y` has: from `x0` (and `max`) less the floats
    /// beside it.
    fn bounds(fl: *const Floats, y: f32, x0: f32, max: ?f32) struct { x0: f32, max: ?f32 } {
        var left = x0;
        var right = max;
        for (fl.placed.items) |f| {
            if (y < f.rect.y or y >= f.rect.y + f.rect.height) continue;
            if (f.rect.x <= x0 and (right == null or f.rect.x + f.rect.width < right.?)) {
                left = @max(left, f.rect.x + f.rect.width + fl.gap);
            } else if (right) |r| right = @min(r, f.rect.x - fl.gap);
        }
        return .{ .x0 = left, .max = right };
    }

    /// Where the first float beside `y` ends (null: none is).
    fn below(fl: *const Floats, y: f32) ?f32 {
        var next: ?f32 = null;
        for (fl.placed.items) |f| {
            const bottom = f.rect.y + f.rect.height;
            if (y >= f.rect.y and y < bottom) next = if (next) |n| @min(n, bottom) else bottom;
        }
        return next;
    }

    /// Below every float.
    fn clear(fl: *const Floats, y: f32) f32 {
        var out = y;
        for (fl.placed.items) |f| out = @max(out, f.rect.y + f.rect.height);
        return out;
    }
};

/// Lays `doc` out `width` wide (no wrapping if null): its fragments and a
/// table's lines (allocated with `a`), and the size they take.
fn arrange(a: Allocator, doc: Doc, width: ?f32, base: f32, fonts: Fonts, m: Measure) Allocator.Error!Arranged {
    var out: std.ArrayList(Fragment) = .empty;
    var rules: std.ArrayList(Rule) = .empty;
    var lines: std.ArrayList(LineSpan) = .empty;
    var floats: Floats = .{ .gap = base * 0.5 };
    var y: f32 = 0;
    var widest: f32 = 0;
    for (doc.blocks, 0..) |b, bi| {
        const size = base * heading_scale[@min(b.level, 6)];
        const in_list = b.kind == .bullet or b.kind == .numbered;
        if (bi > 0) {
            const prev = doc.blocks[bi - 1];
            const prev_list = prev.kind == .bullet or prev.kind == .numbered;
            y += if (in_list and prev_list) base * 0.25 else base * 0.6;
        }
        const first = out.items.len;
        defer for (out.items[first..]) |*f| {
            f.block = @intCast(bi);
        };
        if (b.kind == .table) {
            // Below the floats.
            const t = try arrangeTable(a, &out, &rules, b, floats.clear(y), width, base, fonts, m);
            y = t.bottom;
            widest = @max(widest, t.width);
            continue;
        }
        const indent: f32 = if (in_list) @as(f32, @floatFromInt(b.depth + 1)) * base * 1.5 else 0;
        const first_line = lines.items.len;
        var w: LineWriter = .{
            .a = a,
            .out = &out,
            .m = m,
            .left = indent,
            .right = width,
            .x0 = indent,
            .x = indent,
            .y = y,
            .max = width,
            .line_start = out.items.len,
            .lines = &lines,
            .floats = if (width != null) &floats else null,
            .split = b.alignment == .justify and width != null,
        };
        w.startLine();
        if (in_list) {
            const marker: []const u8 = if (b.kind == .bullet)
                (if (b.depth % 2 == 0) "•" else "◦")
            else
                try std.fmt.allocPrint(a, "{d}.", .{b.number});
            const ms = m.size(fonts.regular, size, marker);
            // On the first line, before its indent (and floats).
            try out.append(a, .{
                .rect = .{ .x = w.x0 - base * 0.4 - ms.width, .y = y, .width = ms.width, .height = ms.height },
                .text = marker,
                .font = fonts.regular,
                .font_size = size,
                .run = .{ .text = marker },
                .marker = true,
            });
        }
        for (b.runs) |r| {
            var run = r;
            if (b.kind == .heading) run.bold = true;
            try w.put(run, fonts, size);
        }
        try w.endLine();
        for (lines.items[first_line..]) |*l| l.alignment = b.alignment;
        if (lines.items.len > first_line) lines.items[lines.items.len - 1].last = true;
        // An empty block still takes a line.
        if (w.y == y) w.y += m.size(fonts.regular, size, " ").height;
        y = w.y;
        widest = @max(widest, w.widest);
    }
    for (floats.placed.items) |f| widest = @max(widest, f.rect.x + f.rect.width);
    y = floats.clear(y);
    try out.appendSlice(a, floats.placed.items);
    return .{ .fragments = out.items, .rules = rules.items, .size = .{ .width = widest, .height = y }, .lines = lines.items };
}

/// A table at `top`: each column as wide as its widest cell, all of them
/// narrowed alike to fit `width` (their cells wrapping), lines between the
/// cells and the header shaded; cells aligned as they say.
fn arrangeTable(a: Allocator, out: *std.ArrayList(Fragment), rules: *std.ArrayList(Rule), b: Block, top: f32, width: ?f32, base: f32, fonts: Fonts, m: Measure) Allocator.Error!struct { bottom: f32, width: f32 } {
    const pad = base * 0.4;
    var cols: usize = 0;
    for (b.rows) |row| cols = @max(cols, row.len);
    if (cols == 0) return .{ .bottom = top, .width = 0 };
    const widths = try a.alloc(f32, cols);
    @memset(widths, 2 * pad);
    for (b.rows, 0..) |row, r| for (row, 0..) |cell, c| {
        var w: f32 = 0;
        for (cell) |run| {
            var rr = run;
            if (b.header and r == 0) rr.bold = true;
            const text_width = m.size(fontFor(fonts, rr), fonts.sizeOf(rr, base), rr.text).width;
            w += if (rr.image) |k| if (m.picture(k, null)) |p| p.width else text_width else text_width;
        }
        widths[c] = @max(widths[c], w + 2 * pad);
    };
    var total: f32 = 0;
    for (widths) |w| total += w;
    // Too wide: each column gives up the same share of what it has over
    // a narrowest width.
    const narrowest = 2 * pad + base;
    const least = narrowest * @as(f32, @floatFromInt(cols));
    if (width) |avail| if (total > avail and avail > least) {
        const k = (avail - least) / (total - least);
        total = 0;
        for (widths) |*w| {
            w.* = narrowest + @max(0, w.* - narrowest) * k;
            total += w.*;
        }
    };
    const line = m.size(fonts.regular, base, " ").height;
    var cell_lines: std.ArrayList(LineSpan) = .empty;
    var y = top;
    for (b.rows, 0..) |row, r| {
        var x: f32 = 0;
        var bottom = y + line + 2 * pad;
        for (0..cols) |c| {
            const start = out.items.len;
            const alignment: Align = if (r < b.cell_alignments.len and c < b.cell_alignments[r].len) b.cell_alignments[r][c] orelse .left else .left;
            cell_lines.clearRetainingCapacity();
            // A little leeway: words measured one by one add up a hair
            // differently.
            const inner = x + widths[c] - pad;
            var w: LineWriter = .{
                .a = a,
                .out = out,
                .m = m,
                .left = x + pad,
                .right = if (width != null) inner + 0.5 else null,
                .x0 = x + pad,
                .x = x + pad,
                .y = y + pad,
                .max = if (width != null) inner + 0.5 else null,
                .line_start = start,
                .lines = &cell_lines,
                .split = alignment == .justify,
            };
            if (c < row.len) for (row[c]) |run| {
                var rr = run;
                if (b.header and r == 0) rr.bold = true;
                try w.put(rr, fonts, base);
            };
            try w.endLine();
            if (cell_lines.items.len > 0) cell_lines.items[cell_lines.items.len - 1].last = true;
            for (cell_lines.items) |l| alignLine(out.items, l, inner, alignment, true);
            for (out.items[start..]) |*f| {
                f.row = @intCast(r);
                f.cell = @intCast(c + 1);
            }
            bottom = @max(bottom, w.y + pad);
            x += widths[c];
        }
        if (b.header and r == 0) try rules.append(a, .{ .rect = .{ .x = 0, .y = y, .width = total, .height = bottom - y }, .shade = true });
        try rules.append(a, .{ .rect = .{ .x = 0, .y = y, .width = total, .height = 1 } });
        y = bottom;
    }
    try rules.append(a, .{ .rect = .{ .x = 0, .y = y - 1, .width = total, .height = 1 } });
    var x: f32 = 0;
    for (0..cols + 1) |c| {
        try rules.append(a, .{ .rect = .{ .x = @min(x, total - 1), .y = top, .width = 1, .height = y - top } });
        if (c < cols) x += widths[c];
    }
    return .{ .bottom = y, .width = total };
}

/// Fills lines with words, wrapping at `max`, round floated images.
const LineWriter = struct {
    a: Allocator,
    out: *std.ArrayList(Fragment),
    m: Measure,
    /// Where lines start and end without floats.
    left: f32,
    right: ?f32,
    /// The line being filled: where it starts and may end, and how far it
    /// is filled.
    x0: f32,
    x: f32,
    y: f32,
    max: ?f32,
    /// The fragments of the line being filled start here.
    line_start: usize,
    widest: f32 = 0,
    /// The lines filled, for aligning.
    lines: ?*std.ArrayList(LineSpan) = null,
    /// Floated images (null: not floated, as in tables and unwrapped
    /// text), and those met on a line with text already, placed under it.
    floats: ?*Floats = null,
    pending: std.ArrayList(Fragment) = .empty,
    /// Each word a fragment of its own (to be justified).
    split: bool = false,
    /// The line ends in a break (not justified).
    hard: bool = false,

    /// A run of a block of `size`: its words, or its image (its text if
    /// the image cannot be shown).
    fn put(w: *LineWriter, run: Run, fonts: Fonts, size: f32) Allocator.Error!void {
        if (run.newline) {
            w.hard = true;
            try w.endLine();
        }
        if (run.image) |k| {
            const float = if (k < w.m.images.len) w.m.images[k].float else null;
            if (float != null) if (w.floats) |fl| {
                const room = w.right.? - w.left;
                const p = w.m.picture(k, room) orelse return w.add(run, fontFor(fonts, run), fonts.sizeOf(run, size));
                const frag: Fragment = .{ .rect = .{ .x = if (float == .left) 0 else 1, .y = 0, .width = p.width, .height = p.height }, .text = run.text[0..0], .font = null, .font_size = size, .run = run, .image = k };
                // At this line if it has nothing yet, else under it.
                if (w.out.items.len > w.line_start and w.x > w.x0) {
                    try w.pending.append(w.a, frag);
                } else {
                    try w.placeFloat(fl, frag);
                    w.startLine();
                }
                return;
            };
            if (w.m.picture(k, if (w.max) |max| max - w.x0 else null)) |p| {
                if (w.max) |max| if (w.x + p.width > max) {
                    if (w.x > w.x0) try w.endLine() else if (w.moveDown()) return w.put(run, fonts, size);
                };
                // After the line's last fragment (its spaces included).
                const from = w.lineEnd();
                try w.out.append(w.a, .{ .rect = .{ .x = from, .y = w.y, .width = p.width, .height = p.height }, .text = run.text[0..0], .font = null, .font_size = size, .run = run, .image = k });
                w.x = from + p.width;
                return;
            }
        }
        try w.add(run, fontFor(fonts, run), fonts.sizeOf(run, size));
    }

    /// Puts float `f` (its `rect.x` 0: left, 1: right) at the first `y`
    /// from this line's where it has room.
    fn placeFloat(w: *LineWriter, fl: *Floats, f: Fragment) Allocator.Error!void {
        var frag = f;
        var y = w.y;
        while (true) {
            const b = fl.bounds(y, w.left, w.right);
            if (b.max.? - b.x0 >= frag.rect.width) {
                frag.rect.x = if (frag.rect.x == 0) b.x0 else b.max.? - frag.rect.width;
                break;
            }
            y = fl.below(y) orelse {
                frag.rect.x = if (frag.rect.x == 0) b.x0 else b.max.? - frag.rect.width;
                break;
            };
        }
        frag.rect.y = y;
        try fl.placed.append(w.a, frag);
    }

    /// The line's room, beside the floats at its top.
    fn startLine(w: *LineWriter) void {
        if (w.floats) |fl| {
            const b = fl.bounds(w.y, w.left, w.right);
            w.x0 = b.x0;
            w.max = b.max;
        }
        w.x = w.x0;
    }

    /// An empty line too narrow beside a float: below it instead; whether
    /// it moved.
    fn moveDown(w: *LineWriter) bool {
        const fl = w.floats orelse return false;
        const y = fl.below(w.y) orelse return false;
        // Not past the list marker or what the line already has.
        for (w.out.items[w.line_start..]) |f| if (!f.marker) return false;
        for (w.out.items[w.line_start..]) |*f| f.rect.y = y;
        w.y = y;
        w.startLine();
        return true;
    }

    /// Where the line's last fragment ends (its start if it has none).
    fn lineEnd(w: *LineWriter) f32 {
        if (w.out.items.len > w.line_start) {
            const last = w.out.items[w.out.items.len - 1];
            if (!last.marker) return last.rect.x + last.rect.width;
        }
        return w.x0;
    }

    fn add(w: *LineWriter, run: Run, font: ?*const Font, size: f32) Allocator.Error!void {
        // Words, each with the spaces after it.
        var i: usize = 0;
        var piece_start: usize = 0;
        while (i < run.text.len) {
            var end = i;
            while (end < run.text.len and run.text[end] != ' ') end += 1;
            while (end < run.text.len and run.text[end] == ' ') end += 1;
            const word = std.mem.trimEnd(u8, run.text[i..end], " ");
            const ww = w.m.size(font, size, word).width;
            if (w.max) |max| if (w.x + ww > max) {
                if (w.x > w.x0) {
                    // What fits goes on this line; the rest starts the next.
                    try w.place(run, run.text[piece_start..i], font, size);
                    try w.endLine();
                    piece_start = i;
                    continue;
                } else if (word.len > 0 and w.moveDown()) continue;
            };
            w.x += w.m.size(font, size, run.text[i..end]).width;
            i = end;
            if (w.split) {
                try w.place(run, run.text[piece_start..i], font, size);
                piece_start = i;
            }
        }
        try w.place(run, run.text[piece_start..], font, size);
    }

    /// Puts `s` (of `run`) where the line's previous fragment ends.
    fn place(w: *LineWriter, run: Run, s: []const u8, font: ?*const Font, size: f32) Allocator.Error!void {
        const from = w.lineEnd();
        // Lines do not start with spaces.
        const t = if (from == w.x0) std.mem.trimStart(u8, s, " ") else s;
        if (t.len == 0) {
            w.x = from;
            return;
        }
        const sz = w.m.size(font, size, t);
        try w.out.append(w.a, .{ .rect = .{ .x = from, .y = w.y, .width = sz.width, .height = sz.height }, .text = t, .font = font, .font_size = size, .run = run });
        w.x = from + sz.width;
    }

    /// Aligns the line's fragments at the bottom (near enough to the
    /// baseline for one size) and moves down, placing the floats met.
    fn endLine(w: *LineWriter) Allocator.Error!void {
        const hard = w.hard;
        w.hard = false;
        const line = w.out.items[w.line_start..];
        if (line.len > 0) {
            // The spaces it ends with take no room (nor underline).
            const last = &line[line.len - 1];
            const trimmed = std.mem.trimEnd(u8, last.text, " ");
            if (trimmed.len < last.text.len and trimmed.len > 0 and last.textual()) {
                last.text = trimmed;
                last.rect.width = w.m.size(last.font, last.font_size, trimmed).width;
            }
            var height: f32 = 0;
            var right: f32 = 0;
            for (line) |f| {
                height = @max(height, f.rect.height);
                right = @max(right, f.rect.x + f.rect.width);
            }
            for (line) |*f| f.rect.y = w.y + height - f.rect.height;
            if (w.lines) |l| try l.append(w.a, .{
                .start = w.line_start,
                .end = w.out.items.len,
                .right = right,
                // Narrowed by a float.
                .limit = if (w.max != null and w.right != null and w.max.? < w.right.?) w.max else null,
                .last = hard,
            });
            w.widest = @max(w.widest, right);
            w.y += height;
            w.line_start = w.out.items.len;
        }
        if (w.floats) |fl| {
            for (w.pending.items) |f| try w.placeFloat(fl, f);
            w.pending.clearRetainingCapacity();
        }
        w.startLine();
    }
};

// ---- The element ----

/// Markdown text (or HTML, see the file's comment), wrapped to its width;
/// as tall as it needs at that width. Clicking a link calls
/// `link-clicked(url)`. `selectable`: dragged over, its text is selected
/// (`selected-text`; a double click selects a word, a triple click a
/// paragraph), copied with Ctrl+C (Cmd+C), all of it with Ctrl+A. Its
/// images are loaded as Image's `source-url` (a path, `file://`,
/// `http(s)://`), in the background, shared with others showing them.
/// Initialize in place with `init`.
pub const StyledText = struct {
    item: Item = .init(&vtable),
    text: Property([]const u8) = .init(""),
    format: Property(TextFormat) = .init(.markdown),
    selectable: Property(bool) = .init(false),
    selection_color: Property(Brush) = .init(.color(.rgba(0x3b82f659))),
    selected_text: Property([]const u8) = .init(""),
    color: Property(Brush) = .init(.color(.black)),
    link_color: Property(Brush) = .init(.color(.rgb(0x2563eb))),
    /// Behind `code`.
    code_background: Property(Brush) = .init(.color(.rgba(0x80808026))),
    font_size: Property(f32) = .init(14),
    font_family: Property([]const u8) = .init(""),
    font_weight: Property(i32) = .init(400),
    /// Pixels added after each character.
    letter_spacing: Property(f32) = .init(0),
    /// Lines broken at the width, or only where the text breaks them
    /// (cut at the edge).
    wrap: Property(rendering.TextWrap) = .init(.word_wrap),
    /// Where lines sit across its width (tables stay at the left), and the
    /// text in its height.
    horizontal_alignment: Property(rendering.TextHorizontalAlignment) = .init(.left),
    vertical_alignment: Property(rendering.TextVerticalAlignment) = .init(.top),
    /// Smaller than `font_size` (headings, lists and tables with it) when
    /// the text would not fit the item.
    font_size_mode: items.Fitting(rendering.FontSizeMode) = if (items.text_fitting) .init(.fixed) else {},
    /// How small fitting may make it.
    minimum_font_size: items.Fitting(f32) = if (items.text_fitting) .init(12) else {},
    /// For `code` (a registered family; else the text's font).
    code_font_family: Property([]const u8) = .init(""),
    /// What relative image URLs are relative to, as a page's address (a
    /// directory ends with `/`); else the working directory.
    base_url: Property([]const u8) = .init(""),
    /// CSS for the text (before HTML's own `style` elements): rules for
    /// tags, `.classes` and `#ids`; Markdown is styled as the HTML it
    /// stands for.
    style_sheet: Property([]const u8) = .init(""),
    link_clicked: Callback(fn ([]const u8) void) = .{},

    gpa: Allocator = undefined,
    /// The parsed text, and its layout at one width.
    parsed: ?Parsed = null,
    laid_out: ?LaidOut = null,
    /// The link under the pointer, and the one pressed.
    hovered_link: ?u32 = null,
    pressed_link: ?u32 = null,
    /// Where the selection starts and ends: addresses in the parsed text
    /// (the same however it is laid out), and whether it is being dragged.
    anchor: ?usize = null,
    caret: ?usize = null,
    selecting: bool = false,
    selected_buffer: StringBuffer = .{},
    /// Changed with the selection: what is drawn depends on it.
    selection_version: Property(u32) = .init(0),
    /// The size fitted last, and what it was fitted to.
    fitted: struct { key: u64 = 0, size: f32 = 0 } = .{},
    /// The text's images (`Doc.images`): their loads, shared with others
    /// showing them, and how far each has come.
    loads: std.ArrayList(?*image_loader.Shared) = .empty,
    shown: std.ArrayList(Shown) = .empty,
    /// Changed as images come: the layout depends on them.
    images_version: Property(u32) = .init(0),
    /// Checks on the images while they load.
    image_timer: Timer = .{},
    /// Clicks in a row (a double click selects words, a triple click
    /// paragraphs, dragged on by the same), and what the first selected.
    clicks: u8 = 0,
    last_click_ms: u64 = 0,
    last_click_position: Point = .{},
    unit: Unit = .char,
    unit_origin: [2]usize = .{ 0, 0 },

    const Unit = enum { char, word, paragraph };
    const multi_click_ms = @import("text_input.zig").TextInput.multi_click_ms;
    const multi_click_distance = 4;

    const Parsed = struct { arena: std.heap.ArenaAllocator, source: []const u8, format: TextFormat, base: []const u8, sheet: []const u8, doc: Doc };
    const LaidOut = struct { arena: std.heap.ArenaAllocator, key: u64, fragments: []Fragment, rules: []Rule, size: Size };
    /// A place in the laid out text: a fragment, and a byte in it.
    const Pos = struct { frag: u32, off: u32 };

    pub fn init(self: *StyledText, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
    }

    pub fn deinit(self: *StyledText) void {
        self.image_timer.deinit();
        self.releaseImages();
        self.loads.deinit(self.gpa);
        self.shown.deinit(self.gpa);
        self.images_version.deinit();
        if (self.parsed) |*p| p.arena.deinit();
        if (self.laid_out) |*l| l.arena.deinit();
        self.selected_buffer.deinit(self.gpa);
        self.item.deinit();
        if (items.text_fitting) {
            self.font_size_mode.deinit();
            self.minimum_font_size.deinit();
        }
        inline for (.{ "text", "format", "selectable", "selection_color", "selected_text", "selection_version", "color", "link_color", "code_background", "font_size", "font_family", "font_weight", "letter_spacing", "wrap", "horizontal_alignment", "vertical_alignment", "code_font_family", "base_url", "style_sheet" }) |f|
            @field(self, f).deinit();
    }

    /// The parsed text (parsed again when it changes).
    pub fn doc(self: *StyledText) ?Doc {
        const src = self.text.get();
        const format = self.format.get();
        const base = self.base_url.get();
        const sheet = self.style_sheet.get();
        if (self.parsed) |p| if (p.format == format and std.mem.eql(u8, p.source, src) and std.mem.eql(u8, p.base, base) and std.mem.eql(u8, p.sheet, sheet)) return p.doc;
        if (self.parsed) |*p| p.arena.deinit();
        self.parsed = null;
        self.laid_out_key_reset();
        // Another text: the selection was in the one before.
        self.anchor = null;
        self.caret = null;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        const a = arena.allocator();
        const source = a.dupe(u8, src) catch return self.failed(&arena);
        // Its rules are slices of it.
        const sheet_copy = a.dupe(u8, sheet) catch return self.failed(&arena);
        const d = (switch (format) {
            .markdown => if (parse(a, source)) |md| styleMarkdown(a, md, sheet_copy) else |err| err,
            .html => parseHtmlStyled(a, source, sheet_copy),
        }) catch return self.failed(&arena);
        const base_copy = a.dupe(u8, base) catch return self.failed(&arena);
        self.parsed = .{ .arena = arena, .source = source, .format = format, .base = base_copy, .sheet = sheet_copy, .doc = d };
        self.loadImages(d);
        return d;
    }

    /// Starts loading `d`'s images (those shown already are there at
    /// once), letting go of the text's before.
    fn loadImages(self: *StyledText, d: Doc) void {
        self.image_timer.stop();
        // Taken before the old ones are let go: the same images are not
        // loaded again.
        var old = self.loads;
        defer {
            for (old.items) |e| if (e) |x| image_loader.release(x);
            old.deinit(self.gpa);
        }
        self.loads = .empty;
        self.shown.clearRetainingCapacity();
        const p = &self.parsed.?;
        for (d.images) |ref| {
            const url = resolveUrl(p.arena.allocator(), p.base, ref.url) catch "";
            const e: ?*image_loader.Shared = if (url.len == 0) null else image_loader.acquire(url, .{}) catch null;
            self.loads.append(self.gpa, e) catch {
                if (e) |x| image_loader.release(x);
                break;
            };
            self.shown.append(self.gpa, if (e == null) .failed else .loading) catch {
                _ = self.loads.pop();
                if (e) |x| image_loader.release(x);
                break;
            };
        }
        if (self.pollImages().waiting) self.image_timer.start(.repeated, 15, self, imagesPolled);
    }

    /// Takes the images that came (or failed): whether some did, and
    /// whether some are still loading.
    fn pollImages(self: *StyledText) struct { changed: bool, waiting: bool } {
        var waiting = false;
        var changed = false;
        for (self.loads.items, self.shown.items, 0..) |e, *shown, k| {
            if (shown.* != .loading) continue;
            const result = (e orelse continue).poll() orelse {
                waiting = true;
                continue;
            };
            changed = true;
            shown.* = if (result) |img| .{ .ready = img } else |err| failed: {
                log.warn("cannot load the image '{s}': {t}", .{ if (self.parsed) |p| p.doc.images[k].url else "", err });
                break :failed .failed;
            };
        }
        return .{ .changed = changed, .waiting = waiting };
    }

    fn imagesPolled(self: *StyledText) void {
        const r = self.pollImages();
        if (!r.waiting) self.image_timer.stop();
        if (r.changed) self.images_version.set(self.images_version.getUntracked() +% 1);
    }

    fn releaseImages(self: *StyledText) void {
        for (self.loads.items) |e| if (e) |x| image_loader.release(x);
        self.loads.clearRetainingCapacity();
        self.shown.clearRetainingCapacity();
    }

    fn laid_out_key_reset(self: *StyledText) void {
        if (self.laid_out) |*l| l.arena.deinit();
        self.laid_out = null;
    }

    fn failed(_: *StyledText, arena: *std.heap.ArenaAllocator) ?Doc {
        arena.deinit();
        log.err("out of memory reading rich text", .{});
        return null;
    }

    fn fonts(self: *StyledText) Fonts {
        const family = self.font_family.get();
        const weight = self.font_weight.get();
        const code_family = self.code_font_family.get();
        return .{
            .regular = items.resolveFont(&self.item, null, family, weight),
            .bold = items.resolveFont(&self.item, null, family, @max(weight, 700)),
            .code = items.resolveFont(&self.item, null, if (code_family.len > 0) code_family else family, weight),
            .item = &self.item,
            .weight = weight,
        };
    }

    /// Its fonts shown at `size` (pixel sizes from HTML scaled with it).
    fn fontsAt(self: *StyledText, size: f32) Fonts {
        var f = self.fonts();
        const own = self.font_size.get();
        f.px_scale = if (own > 0) size / own else 1;
        return f;
    }

    fn measure(self: *StyledText) Measure {
        // The layout follows the images as they come.
        _ = self.images_version.get();
        return .{
            .fallbacks = items.fallbackFonts(&self.item),
            .measurer = if (self.item.window()) |w| w.text_measurer else .approximate,
            .spacing = self.letter_spacing.get(),
            .images = if (self.parsed) |p| p.doc.images else &.{},
            .shown = self.shown.items,
        };
    }

    /// The width lines break at (null: not wrapped).
    fn wrapWidth(self: *StyledText) ?f32 {
        return if (self.wrap.get() == .word_wrap) self.item.width.get() else null;
    }

    fn mode(self: *StyledText) rendering.FontSizeMode {
        return if (items.text_fitting) self.font_size_mode.get() else .fixed;
    }

    /// The size it is shown at: `font_size`, or with a `font_size_mode`,
    /// the largest (in half pixels, down to `minimum_font_size`) whose text
    /// fits the item (wrapped to the width, mostly its height counts).
    pub fn fittedFontSize(self: *StyledText) f32 {
        const size = self.font_size.get();
        const fit_mode = self.mode();
        if (!items.text_fitting or fit_mode == .fixed) return size;
        const smallest = @min(size, self.minimum_font_size.get());
        const width = self.item.width.get();
        const height = self.item.height.get();
        var h: std.hash.Wyhash = .init(0);
        h.update(self.text.get());
        h.update(std.mem.asBytes(&[_]f32{ size, smallest, width, height, self.letter_spacing.get() }));
        h.update(&.{ @intFromEnum(fit_mode), @intFromEnum(self.format.get()), @intFromEnum(self.wrap.get()) });
        h.update(std.mem.asBytes(&self.images_version.get()));
        const f = self.fonts();
        inline for (.{ f.regular, f.bold, f.code }) |font| h.update(std.mem.asBytes(&@intFromPtr(font)));
        const key = h.final();
        if (self.fitted.key == key) return self.fitted.size;
        var fitted = size;
        if (!self.fits(size, fit_mode)) {
            // Sizes `smallest + k / 2`: the largest k that fits (0 if none).
            var lo: u32 = 0;
            var hi: u32 = @intFromFloat(@max(0, @ceil((size - smallest) * 2)));
            while (lo + 1 < hi) {
                const mid = (lo + hi) / 2;
                if (self.fits(smallest + @as(f32, @floatFromInt(mid)) / 2, fit_mode)) lo = mid else hi = mid;
            }
            fitted = smallest + @as(f32, @floatFromInt(lo)) / 2;
        }
        self.fitted = .{ .key = key, .size = fitted };
        return fitted;
    }

    fn fits(self: *StyledText, size: f32, fit_mode: rendering.FontSizeMode) bool {
        const width = self.item.width.get();
        const s = self.sizeAt(self.wrapWidth(), size) orelse return true;
        // A little room for rounding.
        const wide = s.width <= width + 0.01;
        const tall = s.height <= self.item.height.get() + 0.01;
        return switch (fit_mode) {
            .fixed => true,
            .horizontal_fit => wide,
            .vertical_fit => tall,
            .fit => wide and tall,
        };
    }

    /// The size of the text laid out `width` wide at `size` (not kept).
    fn sizeAt(self: *StyledText, width: ?f32, size: f32) ?Size {
        const d = self.doc() orelse return null;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const r = arrange(arena.allocator(), d, width, size, self.fontsAt(size), self.measure()) catch return null;
        return r.size;
    }

    /// Laid out `width` wide (null: unwrapped) at the size shown; kept
    /// until something changes.
    pub fn layoutAt(self: *StyledText, width: ?f32) ?LaidOut {
        const d = self.doc() orelse return null;
        const size = self.fittedFontSize();
        const f = self.fontsAt(size);
        var h: std.hash.Wyhash = .init(0);
        h.update(std.mem.asBytes(&self.images_version.get()));
        const wkey: f32 = width orelse -1;
        h.update(std.mem.asBytes(&wkey));
        h.update(std.mem.asBytes(&size));
        h.update(std.mem.asBytes(&self.letter_spacing.get()));
        const alignment = self.horizontal_alignment.get();
        h.update(&.{@intFromEnum(alignment)});
        inline for (.{ f.regular, f.bold, f.code }) |font| h.update(std.mem.asBytes(&@intFromPtr(font)));
        const key = h.final();
        if (self.laid_out) |l| if (l.key == key) return l;
        self.laid_out_key_reset();
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        const r = arrange(arena.allocator(), d, width, size, f, self.measure()) catch {
            arena.deinit();
            log.err("out of memory laying out rich text", .{});
            return null;
        };
        alignLines(r, width, alignment);
        self.laid_out = .{ .arena = arena, .key = key, .fragments = r.fragments, .rules = r.rules, .size = r.size };
        return self.laid_out;
    }

    fn layoutInfo(i: *Item, o: Orientation) LayoutInfo {
        const self: *StyledText = @alignCast(@fieldParentPtr("item", i));
        const fit_mode = self.mode();
        if (items.text_fitting and fit_mode != .fixed) {
            // At its own size (the fitted one follows from the layout's),
            // and as small as fitting makes it.
            const size = self.font_size.get();
            const smallest = @min(size, self.minimum_font_size.get());
            if (o == .horizontal) {
                const w = if (self.sizeAt(null, size)) |s| s.width else 0;
                // Unwrapped, as narrow as at its smallest size.
                const narrowest = if (fit_mode == .vertical_fit) w else if (self.sizeAt(null, smallest)) |s| s.width else w;
                return .{ .min = if (self.wrap.get() == .word_wrap) 0 else narrowest, .preferred = w, .stretch = 1 };
            }
            const width = self.wrapWidth();
            const h = if (self.sizeAt(width, size)) |s| s.height else 0;
            const min = if (fit_mode == .horizontal_fit) h else if (self.sizeAt(width, smallest)) |s| s.height else h;
            return .{ .min = min, .preferred = h, .stretch = 0 };
        }
        if (o == .horizontal) {
            const w = if (self.layoutAt(null)) |l| l.size.width else 0;
            // Unwrapped text needs its width, as a Text's does.
            return .{ .min = if (self.wrap.get() == .word_wrap) 0 else w, .preferred = w, .stretch = 1 };
        }
        const h = if (self.layoutAt(self.wrapWidth())) |l| l.size.height else 0;
        return .{ .min = h, .preferred = h, .stretch = 0 };
    }

    /// Where the laid out text is placed in the item: unwrapped text
    /// aligned across its width (its lines were, to the widest), and the
    /// text in its height.
    fn origin(self: *StyledText, l: LaidOut) Point {
        const across: f32 = switch (self.horizontal_alignment.get()) {
            .left => 0,
            .center => 0.5,
            .right => 1,
        };
        const down: f32 = switch (self.vertical_alignment.get()) {
            .top => 0,
            .center => 0.5,
            .bottom => 1,
        };
        return .{
            .x = if (self.wrap.get() == .no_wrap and across > 0) (self.item.width.get() - l.size.width) * across else 0,
            .y = if (down > 0) (self.item.height.get() - l.size.height) * down else 0,
        };
    }

    fn render(i: *Item, r: ItemRenderer) void {
        const self: *StyledText = @alignCast(@fieldParentPtr("item", i));
        const l = self.layoutAt(self.wrapWidth()) orelse return;
        // Unwrapped lines are cut at the edge.
        const cut = self.wrap.get() == .no_wrap;
        const at = self.origin(l);
        const moved = at.x != 0 or at.y != 0;
        if (cut or moved) r.save();
        defer if (cut or moved) r.restore();
        if (cut and !r.clip(.{ .width = i.width.get(), .height = i.height.get() })) return;
        if (moved) r.translate(at);
        const color = self.color.get();
        const link_color = self.link_color.get();
        const code_bg = self.code_background.get();
        const fallbacks = items.fallbackFonts(i);
        for (l.rules) |rule| fillRect(r, rule.rect, code_bg, 0);
        _ = self.selection_version.get();
        if (self.range(l)) |sel| {
            const brush = self.selection_color.get();
            const m = self.measure();
            for (l.fragments[sel[0].frag .. sel[1].frag + 1], sel[0].frag..) |f, k| {
                if (!f.textual()) continue;
                const from: usize = if (k == sel[0].frag) sel[0].off else 0;
                const to: usize = if (k == sel[1].frag) sel[1].off else f.text.len;
                if (to <= from) continue;
                const x0 = m.size(f.font, f.font_size, f.text[0..from]).width;
                const x1 = m.size(f.font, f.font_size, f.text[0..to]).width;
                fillRect(r, .{ .x = f.rect.x + x0, .y = f.rect.y, .width = x1 - x0, .height = f.rect.height }, brush, 0);
            }
        }
        for (l.fragments) |f| {
            const box = f.rect;
            if (f.image) |k| {
                if (k < self.shown.items.len) if (self.shown.items[k] == .ready) {
                    r.save();
                    r.translate(.{ .x = box.x, .y = box.y });
                    items.Image.drawPicture(i, self.shown.items[k].ready, .{ .width = box.width, .height = box.height }, r);
                    r.restore();
                };
                continue;
            }
            // HTML's colors over the element's.
            const brush: Brush = if (f.run.color) |c| .color(c) else if (f.run.link != null) link_color else color;
            if (f.run.background) |c| fillRect(r, box, .color(c), 0);
            if (f.run.code) fillRect(r, .{ .x = box.x - 2, .y = box.y, .width = box.width + 4, .height = box.height }, code_bg, 3);
            r.save();
            r.translate(.{ .x = box.x, .y = box.y });
            // Slanted about the baseline (near 4/5 down).
            if (f.run.italic) r.transform(.{ .c = -0.2, .tx = 0.2 * 0.8 * box.height });
            r.drawText(.{ .width = box.width + 2, .height = box.height }, .{
                .text = f.text,
                .font = f.font,
                .color = brush,
                .font_size = f.font_size,
                .fallbacks = fallbacks,
                .letter_spacing = self.letter_spacing.get(),
            });
            r.restore();
            const thickness = @max(1, f.font_size / 14);
            if (f.run.link != null or f.run.underline) fillRect(r, .{ .x = box.x, .y = box.y + box.height * 0.88, .width = box.width, .height = thickness }, brush, 0);
            if (f.run.strike) fillRect(r, .{ .x = box.x, .y = box.y + box.height * 0.55, .width = box.width, .height = thickness }, brush, 0);
        }
    }

    fn fillRect(r: ItemRenderer, box: Rect, brush: Brush, radius: f32) void {
        r.save();
        r.translate(.{ .x = box.x, .y = box.y });
        r.drawRectangle(.{ .width = box.width, .height = box.height }, .{ .background = brush, .border_radius = radius });
        r.restore();
    }

    /// Where `p` is in the text: the nearest line's fragment under it (or
    /// nearest), and the character boundary nearest it there.
    fn hit(self: *StyledText, at: Point) ?usize {
        const l = self.layoutAt(self.wrapWidth()) orelse return null;
        const p = at.sub(self.origin(l));
        var best_dy = std.math.inf(f32);
        for (l.fragments) |f| {
            if (!f.textual()) continue;
            best_dy = @min(best_dy, verticalGap(f.rect, p.y));
        }
        var best: ?Fragment = null;
        var best_dx = std.math.inf(f32);
        for (l.fragments) |f| {
            if (!f.textual() or verticalGap(f.rect, p.y) != best_dy) continue;
            const dx = if (p.x < f.rect.x) f.rect.x - p.x else if (p.x > f.rect.x + f.rect.width) p.x - f.rect.x - f.rect.width else 0;
            if (dx < best_dx) {
                best_dx = dx;
                best = f;
            }
        }
        const f = best orelse return null;
        const base = @intFromPtr(f.text.ptr);
        if (p.x <= f.rect.x) return base;
        const m = self.measure();
        var prev: usize = 0;
        var prev_x: f32 = 0;
        var k: usize = 0;
        while (k < f.text.len) {
            k += std.unicode.utf8ByteSequenceLength(f.text[k]) catch 1;
            k = @min(k, f.text.len);
            const x = m.size(f.font, f.font_size, f.text[0..k]).width;
            if (f.rect.x + x >= p.x) return base + if (p.x - f.rect.x - prev_x < x - (p.x - f.rect.x)) prev else k;
            prev = k;
            prev_x = x;
        }
        return base + f.text.len;
    }

    fn verticalGap(r: Rect, y: f32) f32 {
        if (y < r.y) return r.y - y;
        if (y >= r.y + r.height) return y - (r.y + r.height) + 0.001;
        return 0;
    }

    /// Where address `at` is in the laid out text.
    fn locate(l: LaidOut, at: usize) ?Pos {
        for (l.fragments, 0..) |f, k| {
            if (!f.textual()) continue;
            const start = @intFromPtr(f.text.ptr);
            if (at >= start and at <= start + f.text.len) return .{ .frag = @intCast(k), .off = @intCast(at - start) };
        }
        return null;
    }

    /// The selection, start before end; null if there is none.
    fn range(self: *StyledText, l: LaidOut) ?[2]Pos {
        const a = locate(l, self.anchor orelse return null) orelse return null;
        const b = locate(l, self.caret orelse return null) orelse return null;
        const a_first = a.frag < b.frag or (a.frag == b.frag and a.off <= b.off);
        const sel: [2]Pos = if (a_first) .{ a, b } else .{ b, a };
        if (sel[0].frag == sel[1].frag and sel[0].off == sel[1].off) return null;
        return sel;
    }

    /// Whether address `a` comes before `b` in the laid out text.
    fn before(l: LaidOut, a: usize, b: usize) bool {
        const pa = locate(l, a) orelse return false;
        const pb = locate(l, b) orelse return false;
        return pa.frag < pb.frag or (pa.frag == pb.frag and pa.off < pb.off);
    }

    /// The word (or run of spaces or punctuation) at address `at`, going
    /// on through the fragments beside it in other styles: its start and
    /// end addresses.
    fn wordAround(l: LaidOut, at: usize) ?[2]usize {
        const pos = locate(l, at) orelse return null;
        const f = l.fragments[pos.frag];
        if (f.text.len == 0) return .{ at, at };
        const w = text_edit.wordAt(f.text, pos.off);
        const base = @intFromPtr(f.text.ptr);
        var out: [2]usize = .{ base + w.start, base + w.end };
        if (text_edit.classAt(f.text, w.start) != .word) return out;
        // Back, then on, while the word touches the next fragment's.
        var k = pos.frag;
        var start = w.start;
        while (start == 0 and k > 0) {
            const p = l.fragments[k - 1];
            if (!joined(p, l.fragments[k]) or p.text.len == 0 or text_edit.classAt(p.text, text_edit.prevChar(p.text, p.text.len)) != .word) break;
            start = text_edit.wordAt(p.text, p.text.len).start;
            out[0] = @intFromPtr(p.text.ptr) + start;
            k -= 1;
        }
        k = pos.frag;
        var end_at_edge = w.end == f.text.len;
        while (end_at_edge and k + 1 < l.fragments.len) {
            const n = l.fragments[k + 1];
            if (!joined(l.fragments[k], n) or n.text.len == 0 or text_edit.classAt(n.text, 0) != .word) break;
            const e = text_edit.wordAt(n.text, 0).end;
            out[1] = @intFromPtr(n.text.ptr) + e;
            end_at_edge = e == n.text.len;
            k += 1;
        }
        return out;
    }

    /// Fragments one after the other on a line, with nothing between.
    fn joined(a: Fragment, b: Fragment) bool {
        return a.textual() and b.textual() and a.block == b.block and a.row == b.row and a.cell == b.cell and
            @abs(a.rect.x + a.rect.width - b.rect.x) < 0.01 and @abs(a.rect.y + a.rect.height - b.rect.y - b.rect.height) < 0.01;
    }

    /// The paragraph (block, or table cell) at address `at`: its start and
    /// end addresses.
    fn paragraphAround(l: LaidOut, at: usize) ?[2]usize {
        const pos = locate(l, at) orelse return null;
        const f = l.fragments[pos.frag];
        var lo: ?usize = null;
        var hi: usize = 0;
        for (l.fragments, 0..) |g, k| {
            if (!g.textual() or g.block != f.block or g.row != f.row or g.cell != f.cell) continue;
            if (lo == null) lo = k;
            hi = k;
        }
        const a = l.fragments[lo.?];
        const b = l.fragments[hi];
        return .{ @intFromPtr(a.text.ptr), @intFromPtr(b.text.ptr) + b.text.len };
    }

    /// Selects from the start of the click's unit (word, paragraph) to the
    /// end of the one at `at`, either way.
    fn selectUnits(self: *StyledText, at: usize) void {
        const l = self.layoutAt(self.wrapWidth()) orelse return;
        const r = (if (self.unit == .word) wordAround(l, at) else paragraphAround(l, at)) orelse return;
        const o = self.unit_origin;
        if (before(l, r[0], o[0])) {
            self.anchor = o[1];
            self.caret = r[0];
        } else {
            self.anchor = o[0];
            self.caret = if (before(l, r[1], o[1])) o[1] else r[1];
        }
    }

    /// The selected text into `selected-text`: blocks and table rows on
    /// lines of their own, cells a tab apart, wrapped lines joined.
    fn updateSelected(self: *StyledText) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        if (self.layoutAt(self.wrapWidth())) |l| if (self.range(l)) |sel| {
            var prev: ?Fragment = null;
            for (l.fragments[sel[0].frag .. sel[1].frag + 1], sel[0].frag..) |f, k| {
                if (!f.textual()) continue;
                const from: usize = if (k == sel[0].frag) sel[0].off else 0;
                const to: usize = if (k == sel[1].frag) sel[1].off else f.text.len;
                if (prev) |p| {
                    const sep: []const u8 = if (p.block != f.block or p.row != f.row)
                        "\n"
                    else if (p.cell != f.cell)
                        "\t"
                    else if (p.rect.y != f.rect.y)
                        (if (f.run.newline and f.text.ptr == f.run.text.ptr) "\n" else if (std.mem.endsWith(u8, p.text, " ")) "" else " ")
                    else
                        "";
                    out.appendSlice(self.gpa, sep) catch return;
                }
                if (to > from) out.appendSlice(self.gpa, f.text[from..to]) catch return;
                prev = f;
            }
        };
        self.selected_text.set(self.selected_buffer.format(self.gpa, "{s}", .{out.items}));
    }

    /// Selects all its text.
    pub fn selectAll(self: *StyledText) void {
        const l = self.layoutAt(self.wrapWidth()) orelse return;
        var first: ?Fragment = null;
        var last: ?Fragment = null;
        for (l.fragments) |f| {
            if (!f.textual()) continue;
            if (first == null) first = f;
            last = f;
        }
        self.anchor = @intFromPtr((first orelse return).text.ptr);
        self.caret = @intFromPtr(last.?.text.ptr) + last.?.text.len;
        self.updateSelected();
        self.selection_version.set(self.selection_version.getUntracked() +% 1);
    }

    /// Copies the selected text to the clipboard.
    pub fn copy(self: *StyledText) void {
        const s = self.selected_text.get();
        if (s.len == 0) return;
        if (self.item.window()) |w| w.setClipboardText(s);
    }

    /// The link at `p`, if any.
    pub fn linkAt(self: *StyledText, at: Point) ?u32 {
        const l = self.layoutAt(self.wrapWidth()) orelse return null;
        const p = at.sub(self.origin(l));
        for (l.fragments) |f| if (f.run.link) |k| if (f.rect.contains(p)) return k;
        return null;
    }

    fn inputEvent(i: *Item, event: input.PointerEvent, w: *Window) input.InputEventResult {
        const self: *StyledText = @alignCast(@fieldParentPtr("item", i));
        const at = if (event.position()) |p| self.linkAt(p) else null;
        switch (event) {
            .exit => {
                self.hovered_link = null;
                return .ignored;
            },
            .moved => |m| {
                self.hovered_link = at;
                if (self.selecting) {
                    if (self.hit(m.position)) |spot| {
                        if (self.unit == .char) self.caret = spot else self.selectUnits(spot);
                    }
                    self.updateSelected();
                    self.selection_version.set(self.selection_version.getUntracked() +% 1);
                    return .grab;
                }
                return if (self.pressed_link != null) .grab else if (at != null or self.selectable.get()) .accepted else .ignored;
            },
            .pressed => |p| {
                if (p.button != .left) return .ignored;
                if (at != null) {
                    self.pressed_link = at;
                    return .grab;
                }
                if (!self.selectable.get()) return .ignored;
                // A selection from here (a click alone: none); a double
                // click selects the word, a triple one the paragraph.
                w.setFocusItem(i);
                const now = time.now();
                const near = @abs(p.position.x - self.last_click_position.x) <= multi_click_distance and
                    @abs(p.position.y - self.last_click_position.y) <= multi_click_distance;
                self.clicks = if (self.clicks > 0 and near and now -| self.last_click_ms <= multi_click_ms) @min(self.clicks + 1, 3) else 1;
                self.last_click_ms = now;
                self.last_click_position = p.position;
                const spot = self.hit(p.position);
                self.unit = switch (self.clicks) {
                    1 => .char,
                    2 => .word,
                    else => .paragraph,
                };
                self.anchor = spot;
                self.caret = spot;
                if (self.unit != .char) if (spot) |a| if (self.layoutAt(self.wrapWidth())) |l| {
                    if (if (self.unit == .word) wordAround(l, a) else paragraphAround(l, a)) |r| {
                        self.unit_origin = r;
                        self.anchor = r[0];
                        self.caret = r[1];
                    } else self.unit = .char;
                };
                self.selecting = true;
                self.updateSelected();
                self.selection_version.set(self.selection_version.getUntracked() +% 1);
                return .grab;
            },
            .released => {
                if (self.selecting) {
                    self.selecting = false;
                    return .accepted;
                }
                const pressed = self.pressed_link orelse return .ignored;
                self.pressed_link = null;
                if (at == pressed) {
                    const d = self.doc() orelse return .accepted;
                    self.link_clicked.call(.{d.links[pressed]});
                }
                return .accepted;
            },
            .wheel => return .ignored,
        }
    }

    fn mouseCursor(i: *Item) input.MouseCursor {
        const self: *StyledText = @alignCast(@fieldParentPtr("item", i));
        return if (self.hovered_link != null) .pointer else if (self.selectable.get()) .text else .default;
    }

    fn acceptsFocus(i: *Item) bool {
        const self: *StyledText = @alignCast(@fieldParentPtr("item", i));
        return self.selectable.get();
    }

    /// Ctrl+C (Cmd+C) copies, Ctrl+A (Cmd+A) selects all.
    fn keyEvent(i: *Item, kind: input.KeyEventKind, event: input.KeyEvent, _: *Window) input.EventResult {
        const self: *StyledText = @alignCast(@fieldParentPtr("item", i));
        if (kind != .pressed or !self.selectable.get()) return .reject;
        const m = event.modifiers;
        if (!(m.control or m.meta) or event.text.len != 1) return .reject;
        switch (std.ascii.toLower(event.text[0])) {
            'c' => self.copy(),
            'a' => self.selectAll(),
            else => return .reject,
        }
        return .accept;
    }

    fn accessibleLabel(i: *Item) []const u8 {
        const self: *StyledText = @alignCast(@fieldParentPtr("item", i));
        return if (self.doc()) |d| d.plain else "";
    }

    const vtable: ItemVTable = .{
        .name = "StyledText",
        .render = render,
        .layoutInfo = layoutInfo,
        .inputEvent = inputEvent,
        .keyEvent = keyEvent,
        .acceptsFocus = acceptsFocus,
        .mouseCursor = mouseCursor,
        .accessible_role = .text,
        .accessibleLabel = accessibleLabel,
    };
};

// ---- Tests ----

const testing = std.testing;

test "markdown: inline styles and links" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = try parse(arena.allocator(), "Some **bold** and *italic*, `a*b`, ~~gone~~,\nsnake_case and [a **link**](https://x.org) \\*not\\*.");
    try testing.expectEqual(@as(usize, 1), d.blocks.len);
    const runs = d.blocks[0].runs;
    try testing.expectEqualStrings("Some ", runs[0].text);
    try testing.expectEqualStrings("bold", runs[1].text);
    try testing.expect(runs[1].bold and !runs[2].bold);
    try testing.expectEqualStrings("italic", runs[3].text);
    try testing.expect(runs[3].italic);
    try testing.expectEqualStrings("a*b", runs[5].text);
    try testing.expect(runs[5].code);
    try testing.expect(runs[7].strike);
    try testing.expectEqualStrings(", snake_case and ", runs[8].text);
    try testing.expectEqualStrings("a ", runs[9].text);
    try testing.expectEqual(@as(?u32, 0), runs[9].link);
    try testing.expect(runs[10].bold and runs[10].link != null);
    try testing.expectEqualStrings(" *not*.", runs[11].text);
    try testing.expect(runs[11].link == null);
    try testing.expectEqualStrings("https://x.org", d.links[0]);
    try testing.expectEqualStrings("Some bold and italic, a*b, gone, snake_case and a link *not*.", d.plain);
}

test "markdown: blocks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = try parse(arena.allocator(),
        \\# Title
        \\A paragraph
        \\on two lines.
        \\
        \\- one
        \\- two
        \\  - nested
        \\3. three
        \\Line one\
        \\line two
    );
    const kinds = [_]Block.Kind{ .heading, .paragraph, .bullet, .bullet, .bullet, .numbered };
    try testing.expectEqual(kinds.len, d.blocks.len);
    for (kinds, d.blocks) |k, b| try testing.expectEqual(k, b.kind);
    try testing.expectEqual(@as(u8, 1), d.blocks[0].level);
    try testing.expectEqualStrings("A paragraph on two lines.", d.blocks[1].runs[0].text);
    try testing.expectEqual(@as(u8, 1), d.blocks[4].depth);
    try testing.expectEqual(@as(u32, 3), d.blocks[5].number);
    // The item goes on with the lines after it; the hard break splits it.
    const runs = d.blocks[5].runs;
    try testing.expectEqualStrings("three Line one", runs[0].text);
    try testing.expect(runs[1].newline);
    try testing.expectEqualStrings("line two", runs[1].text);
}

test "styled text wraps, and its links are clicked" {
    const core = @import("core.zig");
    var w: core.Window = undefined;
    w.init(testing.allocator, .{ .width = 200, .height = 200 });
    defer w.deinit();
    var t: StyledText = undefined;
    t.init(testing.allocator);
    defer t.deinit();
    w.rootItem().appendChild(&t.item);
    // Approximate measuring: 0.6 em a character (6 px at 10 px), 12 px lines.
    t.font_size.set(10);
    t.text.set("aaaa bbbb [cccc](u1) dddd");
    try testing.expectEqual(@as(f32, 19 * 6), t.item.layoutInfo(.horizontal).preferred);
    t.item.setGeometry(.{ .width = 60, .height = 100 });
    // "aaaa bbbb " is 60 px: two words a line.
    try testing.expectEqual(@as(f32, 24), t.item.layoutInfo(.vertical).preferred);
    var url: []const u8 = "";
    t.link_clicked.setHandler(&url, struct {
        fn f(u: *[]const u8, s: []const u8) void {
            u.* = s;
        }
    }.f);
    // "cccc" starts the second line.
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 5, .y = 18 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 5, .y = 18 } } });
    try testing.expectEqualStrings("u1", url);
    // Not on the link: not taken.
    try testing.expect(t.linkAt(.{ .x = 40, .y = 18 }) == null);
    try testing.expectEqualStrings("aaaa bbbb cccc dddd", StyledText.accessibleLabel(&t.item));
}

test "markdown: any input parses and lays out" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const r = prng.random();
    const alphabet = "ab *_~`[]()\\#-+1.\n  |:<>/&;";
    var buf: [64]u8 = undefined;
    for (0..2000) |_| {
        const n = r.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*c| c.* = if (r.uintLessThan(u8, 8) == 0) r.int(u8) else alphabet[r.uintLessThan(usize, alphabet.len)];
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const d = try parse(a, buf[0..n]);
        for (d.blocks) |b| for (b.runs) |run| if (run.link) |k| try testing.expect(k < d.links.len);
        _ = try arrange(a, d, 50, 10, .{ .regular = null, .bold = null, .code = null }, .{ .fallbacks = &.{}, .measurer = .approximate });
        const h = try parseHtml(a, buf[0..n]);
        _ = try arrange(a, h, 50, 10, .{ .regular = null, .bold = null, .code = null }, .{ .fallbacks = &.{}, .measurer = .approximate });
    }
}

test "markdown: tables" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = try parse(arena.allocator(),
        \\Before
        \\| Name | **Size** |
        \\| --- | ---: |
        \\| a.txt | 3 KB |
        \\b \| c | 12 |
        \\After
    );
    try testing.expectEqual(@as(usize, 3), d.blocks.len);
    const t = d.blocks[1];
    try testing.expectEqual(Block.Kind.table, t.kind);
    try testing.expect(t.header);
    try testing.expectEqual(@as(usize, 3), t.rows.len);
    try testing.expectEqualStrings("Size", t.rows[0][1][0].text);
    try testing.expect(t.rows[0][1][0].bold);
    try testing.expectEqualStrings("3 KB", t.rows[1][1][0].text);
    // An escaped pipe is text; the outer pipes are optional.
    try testing.expectEqualStrings("b | c", t.rows[2][0][0].text);
    try testing.expectEqualStrings("After", d.blocks[2].runs[0].text);
    try testing.expectEqualStrings("Before\nName\tSize\na.txt\t3 KB\nb | c\t12\nAfter", d.plain);
}

test "html: blocks, inline styles, lists, tables and entities" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = try parseHtml(arena.allocator(),
        \\<h2>Title</h2>
        \\<p>Some <b>bold</b> and <em>it</em>,
        \\   <a href="https://x.org/?a=1&amp;b=2">a link</a>.<br>Next line</p>
        \\<!-- not shown --><script>nor this</script>
        \\<ul><li>one</li><li>two<ol><li>a</li></ol></li></ul>
        \\<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2 &amp; 3&#33;</td></tr></table>
    );
    const kinds = [_]Block.Kind{ .heading, .paragraph, .bullet, .bullet, .numbered, .table };
    try testing.expectEqual(kinds.len, d.blocks.len);
    for (kinds, d.blocks) |k, b| try testing.expectEqual(k, b.kind);
    try testing.expectEqual(@as(u8, 2), d.blocks[0].level);
    const runs = d.blocks[1].runs;
    try testing.expectEqualStrings("Some ", runs[0].text);
    try testing.expect(runs[1].bold);
    try testing.expect(runs[3].italic);
    try testing.expectEqualStrings("a link", runs[5].text);
    try testing.expectEqualStrings("https://x.org/?a=1&b=2", d.links[runs[5].link.?]);
    try testing.expect(runs[7].newline);
    try testing.expectEqualStrings("Next line", runs[7].text);
    try testing.expectEqual(@as(u8, 1), d.blocks[4].depth);
    try testing.expectEqual(@as(u32, 1), d.blocks[4].number);
    const t = d.blocks[5];
    try testing.expect(t.header);
    try testing.expectEqualStrings("2 & 3!", t.rows[1][1][0].text);
}

test "html: colors and fonts from font, span, mark and style attributes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parseHtml(a,
        \\<p style="color: #102030">Blue <span style="background-color: yellow; font-size: 20px; font-weight: bold">big</span>
        \\<font color="red" face="'Mono', serif" size="+1">red</font> <u>under</u>
        \\<span style="text-decoration: line-through; font-style: italic; font-size: 150%">x</span>
        \\<mark>m</mark> <small style="font-family: monospace">s</small></p><p>plain</p>
    );
    const runs = d.blocks[0].runs;
    try testing.expectEqual(@as(usize, 12), runs.len);
    // The paragraph's color, under what is inside it.
    try testing.expectEqual(Color.rgb(0x102030), runs[0].color.?);
    try testing.expectEqualStrings("big", runs[1].text);
    try testing.expectEqual(Color.rgb(0xffff00), runs[1].background.?);
    try testing.expectEqual(@as(f32, 20), runs[1].px);
    try testing.expect(runs[1].bold);
    try testing.expectEqual(Color.rgb(0x102030), runs[2].color.?);
    try testing.expectEqual(@as(?Color, null), runs[2].background);
    try testing.expectEqualStrings("red", runs[3].text);
    try testing.expectEqual(Color.rgb(0xff0000), runs[3].color.?);
    try testing.expectEqualStrings("Mono", runs[3].family);
    try testing.expectEqual(@as(f32, 1.13), runs[3].scale);
    try testing.expect(runs[5].underline and !runs[4].underline);
    try testing.expect(runs[7].strike and runs[7].italic);
    try testing.expectEqual(@as(f32, 1.5), runs[7].scale);
    try testing.expectEqual(Color.rgb(0xffff00), runs[9].background.?);
    try testing.expect(runs[11].code);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 1.2), runs[11].scale, 1e-6);
    // The paragraph's look ends with it.
    try testing.expectEqual(@as(?Color, null), d.blocks[1].runs[0].color);

    // Sizes: pixels scaled as the text is (fitted), shares of the block's.
    var fonts: Fonts = .{ .regular = null, .bold = null, .code = null, .px_scale = 0.5 };
    const m: Measure = .{ .fallbacks = &.{}, .measurer = .approximate };
    const r = try arrange(a, d, null, 10, fonts, m);
    for (r.fragments) |f| {
        if (std.mem.eql(u8, f.text, "big")) try testing.expectEqual(@as(f32, 10), f.font_size);
        if (std.mem.eql(u8, f.text, "x")) try testing.expectEqual(@as(f32, 15), f.font_size);
    }
    fonts.px_scale = 1;
    // In a heading, shares of its size.
    const h = try parseHtml(a, "<h1><span style='font-size: 50%'>half</span></h1>");
    const hr = try arrange(a, h, null, 10, fonts, m);
    try testing.expectEqual(@as(f32, 10 * heading_scale[1] * 0.5), hr.fragments[0].font_size);
}

test "images: in Markdown and HTML, laid out as words, their text if not shown" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try parse(a, "a ![a cat](cat.png) b [![logo](l.svg)](https://x.org)");
    try testing.expectEqual(@as(usize, 2), md.images.len);
    try testing.expectEqualStrings("cat.png", md.images[0].url);
    try testing.expectEqualStrings("a cat", md.images[0].alt);
    const runs = md.blocks[0].runs;
    try testing.expectEqual(@as(?u32, 0), runs[1].image);
    try testing.expectEqualStrings("a cat", runs[1].text);
    // An image in a link is clicked as the link.
    const logo = runs[runs.len - 1];
    try testing.expectEqual(@as(?u32, 1), logo.image);
    try testing.expectEqualStrings("https://x.org", md.links[logo.link.?]);
    try testing.expectEqualStrings("a a cat b logo", md.plain);

    const d = try parseHtml(a, "<p>xx <img src='q.png' width=30 alt='Q &amp; A'> yy</p>");
    try testing.expectEqualStrings("q.png", d.images[0].url);
    try testing.expectEqual(@as(?f32, 30), d.images[0].width);
    try testing.expectEqual(@as(?f32, null), d.images[0].height);
    try testing.expectEqualStrings("Q & A", d.images[0].alt);

    const fonts: Fonts = .{ .regular = null, .bold = null, .code = null };
    var m: Measure = .{ .fallbacks = &.{}, .measurer = .approximate, .images = d.images };
    const Pic = struct {
        fn of(r: Arranged) Fragment {
            for (r.fragments) |f| if (f.image != null) return f;
            unreachable;
        }
    };
    // Loading, its height not known: nothing yet.
    m.shown = &.{.loading};
    var r = try arrange(a, d, null, 10, fonts, m);
    try testing.expectEqual(@as(f32, 0), Pic.of(r).rect.width);
    // There: 30 wide, in proportion, after "xx " (6 px a character).
    const img: image.Image = .{ .width = 10, .height = 20, .pixels = &.{} };
    m.shown = &.{.{ .ready = img }};
    r = try arrange(a, d, null, 10, fonts, m);
    try testing.expectEqual(Rect{ .x = 18, .y = 0, .width = 30, .height = 60 }, Pic.of(r).rect);
    // The text after it on the same line, at its bottom.
    const yy = r.fragments[r.fragments.len - 1];
    try testing.expectApproxEqAbs(@as(f32, 48), yy.rect.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 60), yy.rect.y + yy.rect.height, 1e-3);
    // Wrapped as a word, and no wider than a line.
    r = try arrange(a, d, 24, 10, fonts, m);
    try testing.expectEqual(Rect{ .x = 0, .y = r.fragments[0].rect.height, .width = 24, .height = 48 }, Pic.of(r).rect);
    // Failed: its text instead.
    m.shown = &.{.failed};
    r = try arrange(a, d, null, 10, fonts, m);
    for (r.fragments) |f| try testing.expect(f.image == null);
    try testing.expectEqualStrings("Q & A", r.fragments[1].text);
}

test "html: blocks aligned by align and text-align, over the element's alignment" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parseHtml(a, "<p align=center>aa</p><h2 style='color: red; text-align: right'>bb</h2><p>cc</p><ul><li style='text-align:center'>dd</li></ul>");
    try testing.expectEqual(@as(?Align, .center), d.blocks[0].alignment);
    try testing.expectEqual(@as(?Align, .right), d.blocks[1].alignment);
    try testing.expectEqual(@as(?Align, null), d.blocks[2].alignment);
    try testing.expectEqual(@as(?Align, .center), d.blocks[3].alignment);

    const fonts: Fonts = .{ .regular = null, .bold = null, .code = null };
    const m: Measure = .{ .fallbacks = &.{}, .measurer = .approximate };
    // 6 px a character at 10 px (the heading bigger), 100 wide.
    const r = try arrange(a, d, 100, 10, fonts, m);
    alignLines(r, 100, .left);
    try testing.expectApproxEqAbs(@as(f32, 44), r.fragments[0].rect.x, 1e-3);
    const h = r.fragments[1].rect;
    try testing.expectApproxEqAbs(@as(f32, 100), h.x + h.width, 1e-3);
    try testing.expectEqual(@as(f32, 0), r.fragments[2].rect.x);
    // The item right of its indent, its bullet with it.
    const indent: f32 = 15;
    try testing.expectApproxEqAbs(indent + (100 - indent - 12) / 2.0, r.fragments[4].rect.x, 1e-3);
    try testing.expect(r.fragments[3].marker and r.fragments[3].rect.x > indent);
    // Unaligned blocks follow the element.
    const r2 = try arrange(a, d, 100, 10, fonts, m);
    alignLines(r2, 100, .right);
    try testing.expectApproxEqAbs(@as(f32, 88), r2.fragments[2].rect.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 44), r2.fragments[0].rect.x, 1e-3);
}

test "html: a div's alignment and look for the blocks in it; justified text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parseHtml(a, "<div align=center style='color: red'><p>aa</p><p style='text-align: justify'>bb</p>cc</div><p>dd</p><center>ee</center>");
    const want = [_]?Align{ .center, .justify, .center, null, .center };
    try testing.expectEqual(want.len, d.blocks.len);
    for (want, d.blocks) |w, b| try testing.expectEqual(w, b.alignment);
    try testing.expectEqual(Color.rgb(0xff0000), d.blocks[1].runs[0].color.?);
    try testing.expectEqual(@as(?Color, null), d.blocks[3].runs[0].color);

    // Justified: each line but the last as wide as the box, the spaces
    // widened alike (6 px a character at 10 px).
    const j = try parseHtml(a, "<p align=justify>aa bb cc dd ee ff gg</p>");
    const fonts: Fonts = .{ .regular = null, .bold = null, .code = null };
    const m: Measure = .{ .fallbacks = &.{}, .measurer = .approximate };
    const r = try arrange(a, j, 50, 10, fonts, m);
    alignLines(r, 50, .left);
    // "aa bb cc" (48 px) on the first line: its two gaps 1 px wider.
    const line1 = r.lines[0];
    try testing.expectEqual(@as(usize, 3), line1.end - line1.start);
    const last_word = r.fragments[line1.end - 1];
    try testing.expectApproxEqAbs(@as(f32, 50), last_word.rect.x + last_word.rect.width, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 18 + 1), r.fragments[line1.start + 1].rect.x, 1e-3);
    // The last line as it is.
    const last = r.lines[r.lines.len - 1];
    try testing.expect(last.last);
    try testing.expectEqual(@as(f32, 0), r.fragments[last.start].rect.x);
    const lf = r.fragments[last.end - 1];
    try testing.expect(lf.rect.x + lf.rect.width < 50);
}

test "stylesheets: tags, classes and ids, the most specific last, then style" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parseHtmlStyled(a,
        \\<style>
        \\  /* a comment */ p { color: blue; text-align: right }
        \\  .warn, #top { color: red } p.warn { font-weight: bold }
        \\  @media print { p { color: green } }
        \\  div p { color: green }
        \\</style>
        \\<p>a</p><p class="x warn">b</p><p id=top style="color: #010203">c</p><p class=warn><b class=warn>d</b> e</p>
    , "td { text-align: center } b { color: #00ff00 }");
    try testing.expectEqual(Color.rgb(0x0000ff), d.blocks[0].runs[0].color.?);
    try testing.expectEqual(@as(?Align, .right), d.blocks[0].alignment);
    try testing.expectEqual(Color.rgb(0xff0000), d.blocks[1].runs[0].color.?);
    try testing.expect(d.blocks[1].runs[0].bold);
    // Its own style last.
    try testing.expectEqual(Color.rgb(0x010203), d.blocks[2].runs[0].color.?);
    // The given sheet's `b`, under the text's `.warn`.
    try testing.expectEqual(Color.rgb(0xff0000), d.blocks[3].runs[0].color.?);

    // Markdown, styled as its HTML; its columns aligned by the line under
    // the header.
    const md = try styleMarkdown(a, try parse(a, "# T\n\nSome **bold** [x](u)\n\n| a | b | c |\n|:-:|--:|---|\n| 1 | 2 | 3 |"),
        \\h1 { color: red } strong { color: #00ff00 } a { color: blue } p { text-align: center } th { color: #010101 }
    );
    try testing.expectEqual(Color.rgb(0xff0000), md.blocks[0].runs[0].color.?);
    try testing.expectEqual(@as(?Align, .center), md.blocks[1].alignment);
    try testing.expectEqual(@as(?Color, null), md.blocks[1].runs[0].color);
    try testing.expectEqual(Color.rgb(0x00ff00), md.blocks[1].runs[1].color.?);
    try testing.expectEqual(Color.rgb(0x0000ff), md.blocks[1].runs[3].color.?);
    const t = md.blocks[2];
    try testing.expectEqual(Color.rgb(0x010101), t.rows[0][0][0].color.?);
    try testing.expectEqual(@as(?Color, null), t.rows[1][0][0].color);
    try testing.expectEqual(@as(?Align, .center), t.cell_alignments[1][0]);
    try testing.expectEqual(@as(?Align, .right), t.cell_alignments[1][1]);
    try testing.expectEqual(@as(?Align, null), t.cell_alignments[1][2]);
}

test "table cells aligned: Markdown's columns, HTML's cells" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fonts: Fonts = .{ .regular = null, .bold = null, .code = null };
    const m: Measure = .{ .fallbacks = &.{}, .measurer = .approximate };
    // Columns 4 px around the widest cell: "aaaa" 24 + 8 = 32 wide.
    const d = try parse(a, "| aaaa | bbbb |\n|:-:|-:|\n| c | d |");
    const r = try arrange(a, d, null, 10, fonts, m);
    try testing.expectApproxEqAbs(@as(f32, 4 + (24 - 6) / 2.0), r.fragments[2].rect.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 32 + 4 + 24 - 6), r.fragments[3].rect.x, 1e-3);
    const h = try parseHtml(a, "<table><tr><td>aaaa</td></tr><tr><td align=right>c</td></tr><tr><td style='text-align: center'>d</td></tr></table>");
    const hr = try arrange(a, h, null, 10, fonts, m);
    try testing.expectApproxEqAbs(@as(f32, 4 + 24 - 6), hr.fragments[1].rect.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 4 + 9), hr.fragments[2].rect.x, 1e-3);
}

test "floated images: the lines beside them go round, the rest below" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parseHtml(a, "<p><img src=l.png width=20 height=30 align=left>aa bb cc dd ee ff gg hh</p><p><img src=r.png width=20 height=20 style='float: right'>xx</p><table><tr><td>t</td></tr></table>");
    try testing.expectEqual(@as(?@TypeOf(d.images[0].float), .left), d.images[0].float);
    try testing.expectEqual(@as(?@TypeOf(d.images[1].float), .right), d.images[1].float);
    const fonts: Fonts = .{ .regular = null, .bold = null, .code = null };
    var m: Measure = .{ .fallbacks = &.{}, .measurer = .approximate, .images = d.images };
    m.shown = &.{ .loading, .loading };
    // 60 wide, 6 px a character at 10 px (12 px lines), 5 px between a
    // float and the text.
    const r = try arrange(a, d, 60, 10, fonts, m);
    var left: ?Fragment = null;
    var right: ?Fragment = null;
    for (r.fragments) |f| if (f.image) |k| {
        if (k == 0) left = f else right = f;
    };
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 20, .height = 30 }, left.?.rect);
    // Beside it: from 25, "aa bb " (36) wraps at 60.
    for (r.fragments) |f| {
        if (!f.textual()) continue;
        if (f.rect.y < 30) try testing.expectEqual(@as(f32, 25), f.rect.x) else if (f.block == 0) try testing.expectEqual(@as(f32, 0), f.rect.x);
    }
    // The right one at the right edge of the next paragraph's first line,
    // its text before it.
    try testing.expectEqual(@as(f32, 40), right.?.rect.x);
    // The table below every float.
    for (r.rules) |rule| try testing.expect(rule.rect.y >= right.?.rect.y + right.?.rect.height);
    try testing.expect(r.size.height >= right.?.rect.y + right.?.rect.height);
}

test "image URLs resolved from a base, as a browser does" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][3][]const u8{
        .{ "", "pic.png", "pic.png" },
        .{ "assets/", "pic.png", "assets/pic.png" },
        .{ "docs/page.html", "img/pic.png", "docs/img/pic.png" },
        .{ "/srv/app/", "pic.png", "/srv/app/pic.png" },
        .{ "assets/", "/abs/pic.png", "/abs/pic.png" },
        .{ "https://x.org/a/b.html", "pic.png", "https://x.org/a/pic.png" },
        .{ "https://x.org", "pic.png", "https://x.org/pic.png" },
        .{ "https://x.org/a/b.html", "/pic.png", "https://x.org/pic.png" },
        .{ "https://x.org/a/", "file:///tmp/p.png", "file:///tmp/p.png" },
        .{ "file:///srv/app/", "pic.png", "file:///srv/app/pic.png" },
        .{ "assets/", "C:/pics/p.png", "assets/C:/pics/p.png" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[2], try resolveUrl(a, c[0], c[1]));
}

test "tables lay out in columns, narrowed to fit, their cells wrapping" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parse(a, "| aa | bbbb |\n|-|-|\n| c | dd dd |");
    const fonts: Fonts = .{ .regular = null, .bold = null, .code = null };
    const m: Measure = .{ .fallbacks = &.{}, .measurer = .approximate };
    // 6 px a character at 10 px, 4 px around each cell: 20 and 38 wide.
    const wide = try arrange(a, d, null, 10, fonts, m);
    try testing.expectEqual(@as(f32, 20 + 38), wide.size.width);
    const dd = wide.fragments[3];
    try testing.expectEqualStrings("dd dd", dd.text);
    try testing.expectEqual(@as(f32, 20 + 4), dd.rect.x);
    try testing.expectEqual(@as(u32, 2), dd.cell);
    try testing.expectEqual(@as(u32, 1), dd.row);
    // 40 wide: the second column narrows, "dd dd" wraps.
    const narrow = try arrange(a, d, 40, 10, fonts, m);
    try testing.expect(narrow.size.width <= 40.5);
    var lines: usize = 0;
    for (narrow.fragments) |f| if (std.mem.startsWith(u8, f.text, "dd")) {
        lines += 1;
    };
    try testing.expectEqual(@as(usize, 2), lines);
    try testing.expect(narrow.size.height > wide.size.height);
}

test "styled text selected by dragging, copied with Ctrl+C" {
    const core = @import("core.zig");
    var w: core.Window = undefined;
    w.init(testing.allocator, .{ .width = 200, .height = 200 });
    defer w.deinit();
    var t: StyledText = undefined;
    t.init(testing.allocator);
    defer t.deinit();
    w.rootItem().appendChild(&t.item);
    t.font_size.set(10);
    t.selectable.set(true);
    t.text.set("aaaa bbbb cccc\n\nNext");
    t.item.setGeometry(.{ .width = 60, .height = 100 });
    // "aaaa bbbb " on the first line, "cccc" on the second (6 px a
    // character, 12 px lines), "Next" below a gap.
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 13, .y = 5 } } });
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = 13, .y = 17 } } });
    try testing.expectEqualStrings("aa bbbb cc", t.selected_text.get());
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = 100, .y = 90 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 100, .y = 90 } } });
    try testing.expectEqualStrings("aa bbbb cccc\nNext", t.selected_text.get());
    w.dispatchKey(.pressed, .{ .text = "c", .modifiers = .{ .control = true } });
    const copied = w.clipboardText(testing.allocator).?;
    defer testing.allocator.free(copied);
    try testing.expectEqualStrings("aa bbbb cccc\nNext", copied);
    // All of it; a click alone selects nothing.
    w.dispatchKey(.pressed, .{ .text = "a", .modifiers = .{ .control = true } });
    try testing.expectEqualStrings("aaaa bbbb cccc\nNext", t.selected_text.get());
    // (Away from the first click: not a double click.)
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 40, .y = 5 } } });
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 40, .y = 5 } } });
    try testing.expectEqualStrings("", t.selected_text.get());
    // A double click selects a word, dragged on by words; a triple click
    // the paragraph.
    const click = struct {
        fn f(win: *core.Window, x: f32, y: f32) void {
            win.dispatchPointer(.{ .pressed = .{ .position = .{ .x = x, .y = y } } });
            win.dispatchPointer(.{ .released = .{ .position = .{ .x = x, .y = y } } });
        }
    }.f;
    click(&w, 33, 5);
    w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 33, .y = 5 } } });
    try testing.expectEqualStrings("bbbb", t.selected_text.get());
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = 13, .y = 17 } } });
    try testing.expectEqualStrings("bbbb cccc", t.selected_text.get());
    w.dispatchPointer(.{ .moved = .{ .position = .{ .x = 3, .y = 5 } } });
    try testing.expectEqualStrings("aaaa bbbb", t.selected_text.get());
    w.dispatchPointer(.{ .released = .{ .position = .{ .x = 3, .y = 5 } } });
    click(&w, 33, 5);
    try testing.expectEqualStrings("aaaa bbbb cccc", t.selected_text.get());
}

test "styled text: a double click selects a word through its styles" {
    const core = @import("core.zig");
    var w: core.Window = undefined;
    w.init(testing.allocator, .{ .width = 200, .height = 200 });
    defer w.deinit();
    var t: StyledText = undefined;
    t.init(testing.allocator);
    defer t.deinit();
    w.rootItem().appendChild(&t.item);
    t.font_size.set(10);
    t.selectable.set(true);
    t.text.set("one t**w**o three");
    t.item.setGeometry(.{ .width = 200, .height = 100 });
    // "two" at 24 to 42 px, in three runs.
    for (0..2) |_| {
        w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 26, .y = 5 } } });
        w.dispatchPointer(.{ .released = .{ .position = .{ .x = 26, .y = 5 } } });
    }
    try testing.expectEqualStrings("two", t.selected_text.get());
    // Just after it (as in text fields): the word before.
    for (0..2) |_| {
        w.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 43, .y = 5 } } });
        w.dispatchPointer(.{ .released = .{ .position = .{ .x = 43, .y = 5 } } });
    }
    try testing.expectEqualStrings("two", t.selected_text.get());
}
