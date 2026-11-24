// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Long lists: `ListLayout` lays out the rows of the `for` in it one under
//! another, all as tall as the first (or each as tall as it is), and keeps
//! instances only for those in view (`viewport-y`, `visible-height`): scrolling hands the instances of
//! the rows that left to the rows that came in, nothing is created or
//! destroyed. Rows can be in sections, each under a header. `TableRow`
//! puts its children in the layout's columns.

const std = @import("std");
const Allocator = std.mem.Allocator;
const properties = @import("properties.zig");
const Property = properties.Property;
const ChangeTracker = properties.ChangeTracker;
const geometry = @import("geometry.zig");
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const ItemVTable = item_mod.ItemVTable;
const layout = @import("layout.zig");
const LayoutInfo = layout.LayoutInfo;
const Orientation = layout.Orientation;
const model = @import("model.zig");
const Model = model.Model;
const DerivedModel = model.DerivedModel;
const ringRow = @import("repeater.zig").ringRow;

const log = std.log.scoped(.zigulee_list);

fn Ref(comptime L: type) type {
    return struct { layout: *L, index: u32 };
}

/// The rows of the `for` in it, one under another, `spacing` apart, each
/// as tall as `row-height` (0: the first row's preferred height) and as
/// wide as the layout. With `variable_row_height`, each as tall as it
/// prefers instead: measured once it has had an instance, the rows not
/// yet seen estimated at the mean of those that were. Only the rows within `visible-height` of
/// `viewport-y` (a Flickable's) have instances, recycled as it scrolls
/// (an instance's own state, a text typed in it, moves with it to its
/// next row); without a `visible-height`, all of them.
///
/// `sections` names each row's section: a section starts where the name
/// changes, under a `section-height` gap for its header. `section-names`
/// and `section-ys` are the headers to draw, `current-section` the one of
/// the first row in view and `current-section-offset` where to draw it
/// pinned at the top (pushed up by the next one). Put the children, then
/// call `setup`. Initialize in place with `init`.
pub const ListLayout = struct {
    item: Item = .init(&vtable),
    viewport_y: Property(f32) = .init(0),
    visible_height: Property(f32) = .init(-1),
    row_height: Property(f32) = .init(0),
    variable_row_height: Property(bool) = .init(false),
    spacing: Property(f32) = .init(0),
    sections: Property(Model([]const u8)) = .init(model.emptyModel([]const u8)),
    section_height: Property(f32) = .init(0),
    /// For `TableRow`s: the columns' widths; the layout's width shared
    /// equally between `column-count` columns unless there is one for each.
    column_widths: Property(Model(f32)) = .init(model.emptyModel(f32)),
    column_count: Property(i32) = .init(0),
    row_count: Property(i32) = .init(0),
    current_section: Property([]const u8) = .init(""),
    current_section_offset: Property(f32) = .init(0),
    section_names: Property(Model([]const u8)) = .init(model.emptyModel([]const u8)),
    section_ys: Property(Model(f32)) = .init(model.emptyModel(f32)),

    gpa: ?Allocator = null,
    ready: bool = false,
    /// Rows or instances came or went.
    version: Property(u32) = .init(0),
    /// The rows with instances: the first, and how many (`packWindow`).
    window: Property(u64) = .init(0),
    window_tracker: ChangeTracker(u64) = undefined,
    sections_tracker: ChangeTracker(u64) = undefined,
    /// The rows starting a section, and the sections read.
    starts: std.ArrayList(usize) = .empty,
    sections_read: Property(u32) = .init(0),
    names: DerivedModel([]const u8) = .{},
    ys: DerivedModel(f32) = .{},
    /// With variable heights: each row's measured height (negative: not
    /// yet), where each row starts (heights summed, the not yet measured
    /// at the mean of the others; one more for the end), and when they
    /// were last changed.
    heights: std.ArrayList(f32) = .empty,
    tops: std.ArrayList(f32) = .empty,
    /// The measured heights' mean (null: none measured).
    mean: ?f32 = null,
    heights_read: Property(u32) = .init(0),
    heights_tracker: ChangeTracker(u64) = undefined,

    /// Initialize in place.
    pub fn init(self: *ListLayout, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
        self.section_names.set(self.names.update(gpa, &.{}));
        self.section_ys.setBinding(gpa, self, headerYs) catch log.err("out of memory setting up a list", .{});
        self.current_section.setBinding(gpa, self, currentSection) catch log.err("out of memory setting up a list", .{});
        self.current_section_offset.setBinding(gpa, self, currentSectionOffset) catch log.err("out of memory setting up a list", .{});
        self.sections_tracker.init(gpa, self, sectionsHash, sectionsChanged);
        self.readSections();
        self.window_tracker.init(gpa, self, wantedWindow, windowChanged);
        self.heights_tracker.init(gpa, self, measuredHash, measure);
    }

    pub fn deinit(self: *ListLayout) void {
        const gpa = self.gpa.?;
        self.window_tracker.deinit();
        self.sections_tracker.deinit();
        self.heights_tracker.deinit();
        self.heights.deinit(gpa);
        self.tops.deinit(gpa);
        self.starts.deinit(gpa);
        self.names.deinit(gpa);
        self.ys.deinit(gpa);
        self.item.deinit();
        inline for (.{ "viewport_y", "visible_height", "row_height", "variable_row_height", "heights_read", "spacing", "sections", "section_height", "column_widths", "column_count", "row_count", "current_section", "current_section_offset", "section_names", "section_ys", "version", "window", "sections_read" }) |f|
            @field(self, f).deinit();
    }

    /// Lays out the children, from now on as they come and go (until then,
    /// a `for` in it has no rows: its properties may not all be set).
    pub fn setup(self: *ListLayout, gpa: Allocator) Allocator.Error!void {
        if (!self.ready) {
            self.ready = true;
            self.syncWindow();
        }
        self.row_count.set(@intCast(self.rowCount()));
        var children = self.item.layoutChildren();
        var i: u32 = 0;
        while (children.next()) |c| : (i += 1) {
            const r: Ref(ListLayout) = .{ .layout = self, .index = i };
            try c.x.setBinding(gpa, r, childX);
            try c.y.setBinding(gpa, r, childY);
            try c.width.setBinding(gpa, r, childWidth);
            try c.height.setBinding(gpa, r, childHeight);
            if (c.vtable == &TableRow.vtable) {
                const row: *TableRow = @fieldParentPtr("item", c);
                row.list.set(self);
            }
        }
    }

    /// The rows to show now, not once change handlers run (the first row
    /// measured, the rows the model has).
    fn syncWindow(self: *ListLayout) void {
        const w = self.wantedWindow();
        self.window_tracker.value = w;
        self.windowChanged(w);
    }

    /// The `for` whose rows these are.
    fn repeater(self: *ListLayout) ?*Item {
        var c = self.item.first_child;
        while (c) |child| : (c = child.next_sibling) if (child.vtable.showRows != null) return child;
        return null;
    }

    fn rowCount(self: *ListLayout) usize {
        const r = self.repeater() orelse return 0;
        return r.vtable.modelRowCount.?(r);
    }

    /// `row-height`, or the first row's preferred height (0 before there
    /// is one).
    fn rowHeight(self: *ListLayout) f32 {
        const h = self.row_height.get();
        if (h > 0) return h;
        var children = self.item.layoutChildren();
        const first = children.next() orelse return 0;
        return first.layoutInfo(.vertical).preferredBounded();
    }

    /// The headers above row `row` and itself (the sections starting at or
    /// before it).
    fn headersUpTo(self: *ListLayout, row: usize) usize {
        _ = self.sections_read.get();
        const s = self.starts.items;
        var lo: usize = 0;
        var hi: usize = s.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (s[mid] <= row) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn rowY(self: *ListLayout, row: usize, rh: f32) f32 {
        const headers = @as(f32, @floatFromInt(self.headersUpTo(row))) * self.section_height.get();
        if (self.variable_row_height.get()) {
            const above = self.rowsAbove(row, rh);
            return above + @as(f32, @floatFromInt(row)) * self.spacing.get() + headers;
        }
        const stride = rh + self.spacing.get();
        return @as(f32, @floatFromInt(row)) * stride + headers;
    }

    /// With variable heights: the heights of the rows above `row` summed
    /// (`rh`: the estimate when none is measured).
    fn rowsAbove(self: *ListLayout, row: usize, rh: f32) f32 {
        _ = self.heights_read.get();
        self.updateTops(rh);
        if (self.tops.items.len == 0) return @as(f32, @floatFromInt(row)) * rh;
        const last = self.tops.items.len - 1;
        if (row <= last) return self.tops.items[row];
        return self.tops.items[last] + @as(f32, @floatFromInt(row - last)) * self.estimate(rh);
    }

    /// Row `row`'s height (`rh`: all rows', unless they vary).
    fn heightOf(self: *ListLayout, row: usize, rh: f32) f32 {
        if (!self.variable_row_height.get()) return rh;
        _ = self.heights_read.get();
        if (row < self.heights.items.len and self.heights.items[row] >= 0) return self.heights.items[row];
        return self.estimate(rh);
    }

    /// The height of a row not yet measured: the mean of those that were
    /// (`rh` if none).
    fn estimate(self: *ListLayout, rh: f32) f32 {
        return self.mean orelse rh;
    }

    /// Sums the heights into `tops`, for the rows the model has.
    fn updateTops(self: *ListLayout, rh: f32) void {
        const n = self.rowCount();
        if (self.tops.items.len == n + 1) return;
        const gpa = self.gpa.?;
        self.tops.resize(gpa, n + 1) catch return self.tops.clearRetainingCapacity();
        const guess = self.estimate(rh);
        var y: f32 = 0;
        for (0..n) |i| {
            self.tops.items[i] = y;
            y += if (i < self.heights.items.len and self.heights.items[i] >= 0) self.heights.items[i] else guess;
        }
        self.tops.items[n] = y;
    }

    /// The rows with instances and their preferred heights (read, and
    /// depended on), with variable heights.
    fn measuredHash(self: *ListLayout) u64 {
        if (!self.variable_row_height.get()) return 0;
        const win = unpackWindow(self.window.get());
        var h: std.hash.Wyhash = .init(0);
        var children = self.item.layoutChildren();
        var i: usize = 0;
        while (children.next()) |c| : (i += 1) {
            const row = ringRow(win.first, win.count, i);
            const ph = c.layoutInfo(.vertical).preferredBounded();
            h.update(std.mem.asBytes(&row));
            h.update(std.mem.asBytes(&ph));
        }
        return h.final();
    }

    /// Keeps the heights of the rows with instances.
    fn measure(self: *ListLayout, _: u64) void {
        if (!self.variable_row_height.getUntracked()) return;
        const gpa = self.gpa.?;
        const win = unpackWindow(self.window.getUntracked());
        const n = self.rowCount();
        if (self.heights.items.len < n) {
            const old = self.heights.items.len;
            self.heights.resize(gpa, n) catch return log.err("out of memory measuring a list", .{});
            @memset(self.heights.items[old..], -1);
        }
        var children = self.item.layoutChildren();
        var i: usize = 0;
        while (children.next()) |c| : (i += 1) {
            const row = ringRow(win.first, win.count, i);
            if (row >= n) continue;
            self.heights.items[row] = c.layoutInfo(.vertical).preferredBounded();
        }
        var sum: f32 = 0;
        var count: usize = 0;
        for (self.heights.items) |h| if (h >= 0) {
            sum += h;
            count += 1;
        };
        self.mean = if (count == 0) null else sum / @as(f32, @floatFromInt(count));
        // Summed again when next read.
        self.tops.clearRetainingCapacity();
        self.heights_read.set(self.heights_read.getUntracked() +% 1);
    }

    /// The last row starting at or above `y` (of `n`).
    fn rowAt(self: *ListLayout, y: f32, n: usize, rh: f32) usize {
        if (n == 0) return 0;
        var lo: usize = 0;
        var hi: usize = n - 1;
        while (lo < hi) {
            const mid = (lo + hi + 1) / 2;
            if (self.rowY(mid, rh) <= y) lo = mid else hi = mid - 1;
        }
        return lo;
    }

    fn contentHeight(self: *ListLayout) f32 {
        _ = self.version.get();
        const n = self.rowCount();
        if (n == 0) return 0;
        const rh = self.rowHeight();
        return self.rowY(n - 1, rh) + self.heightOf(n - 1, rh);
    }

    fn packWindow(first: usize, count: usize) u64 {
        return @as(u64, @intCast(first)) << 32 | @as(u32, @intCast(count));
    }

    fn unpackWindow(w: u64) struct { first: usize, count: usize } {
        return .{ .first = @intCast(w >> 32), .count = @intCast(w & 0xffff_ffff) };
    }

    /// The rows to have instances: as many as fit in view (and one more,
    /// so their number stays the same as it scrolls), from the first in
    /// view.
    fn wantedWindow(self: *ListLayout) u64 {
        _ = self.version.get();
        const n = self.rowCount();
        const visible = self.visible_height.get();
        if (visible < 0) return packWindow(0, n);
        const rh = self.rowHeight();
        // One to measure.
        if (rh <= 0) return packWindow(0, @min(n, 1));
        const top = @max(0, -self.viewport_y.get());
        if (self.variable_row_height.get()) {
            // From the first in view to the first past it, and one more.
            const from = self.rowAt(top, n, rh);
            var to = from;
            while (to < n and self.rowY(to, rh) < top + visible) to += 1;
            const count = @min(n, to - from + 1);
            return packWindow(@min(from, n - count), count);
        }
        const stride = rh + self.spacing.get();
        const fit: usize = @intFromFloat(@ceil(@max(visible, 0) / @max(stride, 1)));
        const count = @min(n, fit + 1);
        const first = @min(self.rowAt(top, n, rh), n - count);
        return packWindow(first, count);
    }

    fn windowChanged(self: *ListLayout, w: u64) void {
        if (!self.ready) return;
        self.window.set(w);
        const r = self.repeater() orelse return;
        const win = unpackWindow(w);
        r.vtable.showRows.?(r, win.first, win.count);
    }

    /// The row child `index` shows.
    fn rowOf(self: *ListLayout, index: u32) usize {
        const win = unpackWindow(self.window.get());
        return ringRow(win.first, win.count, index);
    }

    fn childX(_: Ref(ListLayout)) f32 {
        return 0;
    }
    fn childY(r: Ref(ListLayout)) f32 {
        const self = r.layout;
        return self.rowY(self.rowOf(r.index), self.rowHeight());
    }
    /// The layout's (not through where the row is: a row whose height
    /// follows its width, wrapped text, is measured without going round).
    fn childWidth(r: Ref(ListLayout)) f32 {
        return r.layout.item.width.get();
    }
    fn childHeight(r: Ref(ListLayout)) f32 {
        const self = r.layout;
        return self.heightOf(self.rowOf(r.index), self.rowHeight());
    }

    /// The names, read (and depended on).
    fn sectionsHash(self: *ListLayout) u64 {
        const m = self.sections.get();
        var h: std.hash.Wyhash = .init(0);
        const n = m.rowCount();
        h.update(std.mem.asBytes(&n));
        for (0..n) |i| {
            const s = m.rowData(i) orelse "";
            h.update(s);
            h.update(&.{0});
        }
        return h.final();
    }

    fn sectionsChanged(self: *ListLayout, _: u64) void {
        self.readSections();
    }

    fn readSections(self: *ListLayout) void {
        const gpa = self.gpa.?;
        const m = self.sections.getUntracked();
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        self.starts.clearRetainingCapacity();
        const strings = self.names.nextStrings(gpa);
        var prev: ?[]const u8 = null;
        for (0..m.rowCount()) |i| {
            const s = m.rowData(i) orelse "";
            if (prev != null and std.mem.eql(u8, prev.?, s)) continue;
            const copy = strings.dupe(u8, s) catch return log.err("out of memory reading sections", .{});
            self.starts.append(gpa, i) catch return log.err("out of memory reading sections", .{});
            names.append(gpa, copy) catch return log.err("out of memory reading sections", .{});
            prev = copy;
        }
        _ = self.names.update(gpa, names.items);
        self.sections_read.set(self.sections_read.getUntracked() +% 1);
    }

    /// The headers' positions (above their first rows).
    fn headerYs(self: *ListLayout) Model(f32) {
        const gpa = self.gpa.?;
        _ = self.version.get();
        const rh = self.rowHeight();
        const sh = self.section_height.get();
        var ys: std.ArrayList(f32) = .empty;
        defer ys.deinit(gpa);
        _ = self.sections_read.get();
        for (self.starts.items) |s| ys.append(gpa, self.rowY(s, rh) - sh) catch break;
        return self.ys.update(gpa, ys.items);
    }

    /// The section of the first row in view.
    fn currentSection(self: *ListLayout) []const u8 {
        const k = self.currentSectionIndex() orelse return "";
        _ = self.section_names.get();
        return self.names.rows.items[k];
    }

    fn currentSectionIndex(self: *ListLayout) ?usize {
        _ = self.version.get();
        const n = self.rowCount();
        if (n == 0) return null;
        const k = self.headersUpTo(self.rowAt(@max(0, -self.viewport_y.get()), n, self.rowHeight()));
        return if (k == 0) null else k - 1;
    }

    /// Up from the top of the view as the next section's header comes
    /// within a header's height of it.
    fn currentSectionOffset(self: *ListLayout) f32 {
        const k = self.currentSectionIndex() orelse return 0;
        if (k + 1 >= self.starts.items.len) return 0;
        const sh = self.section_height.get();
        const next = self.rowY(self.starts.items[k + 1], self.rowHeight()) - sh;
        return @min(0, next - @max(0, -self.viewport_y.get()) - sh);
    }

    /// Across: the first row's (or the columns'). Down: all the rows.
    fn layoutInfo(i: *Item, o: Orientation) LayoutInfo {
        const self: *ListLayout = @alignCast(@fieldParentPtr("item", i));
        if (o == .horizontal) {
            var info: LayoutInfo = .{};
            var children = self.item.layoutChildren();
            if (children.next()) |c| info = c.layoutInfo(.horizontal);
            info.max = std.math.inf(f32);
            const widths = self.column_widths.get();
            const n: usize = @intCast(@max(0, self.column_count.get()));
            if (n > 0 and widths.rowCount() == n) {
                var total: f32 = 0;
                for (0..n) |c| total += widths.rowData(c) orelse 0;
                info.min = @max(info.min, total);
                info.preferred = @max(info.preferred, total);
            }
            return info;
        }
        const h = self.contentHeight();
        return .{ .min = h, .preferred = h, .max = std.math.inf(f32) };
    }

    /// Column `c`'s left and width, for `TableRow`s.
    pub fn column(self: *ListLayout, c: usize) struct { x: f32, width: f32 } {
        const n: usize = @intCast(@max(0, self.column_count.get()));
        const widths = self.column_widths.get();
        if (n > 0 and widths.rowCount() == n) {
            var x: f32 = 0;
            for (0..c) |k| x += widths.rowData(k) orelse 0;
            return .{ .x = x, .width = if (c < n) widths.rowData(c) orelse 0 else 0 };
        }
        const w = self.item.width.get() / @as(f32, @floatFromInt(@max(n, 1)));
        return .{ .x = w * @as(f32, @floatFromInt(c)), .width = if (c < @max(n, 1)) w else 0 };
    }

    fn childrenChanged(i: *Item) void {
        const self: *ListLayout = @alignCast(@fieldParentPtr("item", i));
        self.version.set(self.version.getUntracked() +% 1);
        if (!self.ready) return;
        self.setup(self.gpa.?) catch log.err("out of memory laying out a list", .{});
        if (self.wantedWindow() != self.window.getUntracked()) self.syncWindow();
    }

    /// Where scrolling settles (`ItemVTable.snapPosition`): down, at the
    /// rows' tops (with sections, just under the pinned header, so a
    /// section's first row shows its own); across, at the columns' left
    /// edges, when they have widths.
    fn snapPosition(i: *Item, o: Orientation, at: f32, dir: i2) ?f32 {
        const self: *ListLayout = @alignCast(@fieldParentPtr("item", i));
        if (o == .horizontal) {
            const n: usize = @intCast(@max(0, self.column_count.get()));
            const widths = self.column_widths.get();
            if (n == 0 or widths.rowCount() != n) return null;
            var best: ?f32 = null;
            var x: f32 = 0;
            for (0..n) |c| {
                best = layout.nearerSnap(best, x, at, dir);
                x += widths.rowData(c) orelse 0;
            }
            return best;
        }
        _ = self.version.get();
        const n = self.rowCount();
        if (n == 0) return null;
        const rh = self.rowHeight();
        _ = self.sections_read.get();
        const lift: f32 = if (self.starts.items.len > 0) self.section_height.get() else 0;
        // Row `r`'s top is at or above `at`, row `r + 1`'s below it.
        const r = self.rowAt(at + lift, n, rh);
        var best: ?f32 = null;
        var row = if (r > 0) r - 1 else 0;
        while (row <= @min(n - 1, r + 2)) : (row += 1) best = layout.nearerSnap(best, @max(0, self.rowY(row, rh) - lift), at, dir);
        return best;
    }

    const vtable: ItemVTable = .{ .name = "ListLayout", .layoutInfo = layoutInfo, .childrenChanged = childrenChanged, .snapPosition = snapPosition, .is_layout = true, .shows_rows = true };
};

/// A row of a table: its children are its cells, in the columns of the
/// `ListLayout` it is a row of (one each, in order), as tall as the row.
/// Its preferred height is its tallest cell's.
pub const TableRow = struct {
    item: Item = .init(&vtable),
    /// Set by the list it is in.
    list: Property(?*ListLayout) = .init(null),
    gpa: ?Allocator = null,

    pub fn deinit(self: *TableRow) void {
        self.item.deinit();
        self.list.deinit();
    }

    pub fn setup(self: *TableRow, gpa: Allocator) Allocator.Error!void {
        self.gpa = gpa;
        var children = self.item.layoutChildren();
        var i: u32 = 0;
        while (children.next()) |c| : (i += 1) {
            const r: Ref(TableRow) = .{ .layout = self, .index = i };
            try c.x.setBinding(gpa, r, cellX);
            c.y.set(0);
            try c.width.setBinding(gpa, r, cellWidth);
            try c.height.setBinding(gpa, r, cellHeight);
        }
    }

    fn cellX(r: Ref(TableRow)) f32 {
        const list = r.layout.list.get() orelse return 0;
        return list.column(r.index).x;
    }
    fn cellWidth(r: Ref(TableRow)) f32 {
        const list = r.layout.list.get() orelse return 0;
        return list.column(r.index).width;
    }
    fn cellHeight(r: Ref(TableRow)) f32 {
        return r.layout.item.height.get();
    }

    fn layoutInfo(i: *Item, o: Orientation) LayoutInfo {
        const self: *TableRow = @fieldParentPtr("item", i);
        var info: LayoutInfo = .{};
        if (o == .vertical) {
            var children = self.item.layoutChildren();
            while (children.next()) |c| info.preferred = @max(info.preferred, c.layoutInfo(.vertical).preferredBounded());
        }
        return info;
    }

    fn childrenChanged(i: *Item) void {
        const self: *TableRow = @fieldParentPtr("item", i);
        if (self.gpa) |gpa| self.setup(gpa) catch log.err("out of memory laying out a table row", .{});
    }

    const vtable: ItemVTable = .{ .name = "TableRow", .layoutInfo = layoutInfo, .childrenChanged = childrenChanged, .is_layout = true };
};

// ---- Tests ----

const testing = std.testing;
const core = @import("core.zig");

const TestRow = struct {
    rect: core.items.Rectangle = .{},
    constraints: core.LayoutConstraints = .{},
    gpa: Allocator,
    row: usize,
    value: i32,

    pub const Context = *usize;
    pub fn create(gpa: Allocator, created: *usize, row: usize, value: i32) Allocator.Error!*TestRow {
        const self = try gpa.create(TestRow);
        self.* = .{ .gpa = gpa, .row = row, .value = value };
        self.rect.item.constraints = &self.constraints;
        self.constraints.preferred_height.set(20);
        created.* += 1;
        return self;
    }
    pub fn update(self: *TestRow, row: usize, value: i32) void {
        self.row = row;
        self.value = value;
    }
    pub fn destroy(self: *TestRow) void {
        self.rect.deinit();
        self.constraints.deinit();
        self.gpa.destroy(self);
    }
    pub fn rootItem(self: *TestRow) *Item {
        return &self.rect.item;
    }
};

test "a list layout keeps instances for the rows in view, recycled as it scrolls" {
    var list: ListLayout = undefined;
    list.init(testing.allocator);
    defer list.deinit();
    var created: usize = 0;
    var rep: core.Repeater(i32, TestRow) = undefined;
    try rep.init(testing.allocator, &created);
    defer rep.deinit();
    list.item.appendChild(&rep.item);
    var values: [1000]i32 = undefined;
    for (&values, 0..) |*v, i| v.* = @intCast(i * 10);
    var m: core.SliceModel(i32) = .init(&values);
    defer m.deinit();
    try rep.setModel(m.model());
    // Nothing until laid out.
    try testing.expectEqual(@as(usize, 0), rep.count());
    list.visible_height.set(100);
    list.item.setGeometry(.{ .width = 80, .height = 100 });
    try list.setup(testing.allocator);
    core.runChangeHandlers();
    // 20 px rows: five fit, and one more.
    try testing.expectEqual(@as(usize, 6), rep.count());
    try testing.expectEqual(@as(i32, 1000), list.row_count.get());
    try testing.expectEqual(@as(f32, 20000), list.item.layoutInfo(.vertical).preferred);
    try testing.expectEqual(@as(f32, 40), rep.instance(2).rect.item.y.get());
    try testing.expectEqual(@as(f32, 80), rep.instance(2).rect.item.width.get());
    // Scrolled down 3 rows and a bit: rows 3 to 8, no new instances.
    const before = created;
    list.viewport_y.set(-65);
    core.runChangeHandlers();
    try testing.expectEqual(before, created);
    try testing.expectEqual(@as(usize, 6), rep.count());
    // Row 6 went into the instance of row 0.
    try testing.expectEqual(@as(usize, 6), rep.instance(0).row);
    try testing.expectEqual(@as(i32, 60), rep.instance(0).value);
    try testing.expectEqual(@as(f32, 120), rep.instance(0).rect.item.y.get());
    try testing.expectEqual(@as(usize, 3), rep.instance(3).row);
    // To the end: the last six rows.
    list.viewport_y.set(-100000);
    core.runChangeHandlers();
    try testing.expectEqual(before, created);
    var rows: [6]usize = undefined;
    for (&rows, 0..) |*r, i| r.* = rep.instance(i).row;
    std.mem.sort(usize, &rows, {}, std.sort.asc(usize));
    try testing.expectEqualSlices(usize, &.{ 994, 995, 996, 997, 998, 999 }, &rows);
    // Taller: more instances.
    list.visible_height.set(200);
    core.runChangeHandlers();
    try testing.expectEqual(@as(usize, 11), rep.count());
}

test "a list layout's sections" {
    var list: ListLayout = undefined;
    list.init(testing.allocator);
    defer list.deinit();
    var created: usize = 0;
    var rep: core.Repeater(i32, TestRow) = undefined;
    try rep.init(testing.allocator, &created);
    defer rep.deinit();
    list.item.appendChild(&rep.item);
    var m: core.SliceModel(i32) = .init(&.{ 1, 2, 3, 4, 5, 6 });
    defer m.deinit();
    try rep.setModel(m.model());
    var sections: core.SliceModel([]const u8) = .init(&.{ "A", "A", "A", "B", "B", "C" });
    defer sections.deinit();
    list.sections.set(sections.model());
    list.section_height.set(10);
    list.visible_height.set(50);
    list.item.setGeometry(.{ .width = 80, .height = 50 });
    try list.setup(testing.allocator);
    core.runChangeHandlers();
    // A at 0, rows 0-2 at 10, 30, 50; B at 70, rows 3-4 at 80, 100; C at
    // 120, row 5 at 130.
    try testing.expectEqual(@as(f32, 150), list.item.layoutInfo(.vertical).preferred);
    const ys = list.section_ys.get();
    try testing.expectEqual(@as(usize, 3), ys.rowCount());
    try testing.expectEqual(@as(?f32, 70), ys.rowData(1));
    try testing.expectEqualStrings("B", list.section_names.get().rowData(1).?);
    try testing.expectEqualStrings("A", list.current_section.get());
    try testing.expectEqual(@as(f32, 0), list.current_section_offset.get());
    // B's header 5 px from the top: A's pushed up by 5.
    list.viewport_y.set(-65);
    try testing.expectEqualStrings("A", list.current_section.get());
    try testing.expectEqual(@as(f32, -5), list.current_section_offset.get());
    list.viewport_y.set(-85);
    try testing.expectEqualStrings("B", list.current_section.get());
    core.runChangeHandlers();
    try testing.expectEqual(@as(f32, 80), rep.instance(3 % rep.count()).rect.item.y.get());
}

test "table rows put their cells in the list's columns" {
    var list: ListLayout = undefined;
    list.init(testing.allocator);
    defer list.deinit();
    var row: TableRow = .{};
    defer row.deinit();
    var cells: [3]core.items.Rectangle = @splat(.{});
    defer for (&cells) |*c| c.deinit();
    for (&cells) |*c| row.item.appendChild(&c.item);
    try row.setup(testing.allocator);
    list.item.appendChild(&row.item);
    list.column_count.set(3);
    list.item.setGeometry(.{ .width = 300, .height = 100 });
    try list.setup(testing.allocator);
    try testing.expectEqual(@as(f32, 200), cells[2].item.x.get());
    try testing.expectEqual(@as(f32, 100), cells[1].item.width.get());
    var widths: core.SliceModel(f32) = .init(&.{ 50, 120, 30 });
    defer widths.deinit();
    list.column_widths.set(widths.model());
    try testing.expectEqual(@as(f32, 170), cells[2].item.x.get());
    try testing.expectEqual(@as(f32, 120), cells[1].item.width.get());
    try testing.expectEqual(@as(f32, 200), list.item.layoutInfo(.horizontal).preferred);
}
