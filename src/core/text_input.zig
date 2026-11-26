// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

//! `TextInput`: an editable text field, single-line or multi-line.
//!
//! Editing: typing, Backspace/Delete (by word with Ctrl/Alt), the arrow
//! keys (by word with Ctrl/Alt, to the line ends with Cmd), Home/End,
//! Up/Down/PageUp/PageDown in multi-line inputs, Shift to select,
//! Ctrl/Cmd+A/C/X/V/Z/Y (Shift+Ctrl/Cmd+Z redoes). Pointer: click to place
//! the caret, drag to select, double-click for words, triple-click for
//! lines; the wheel scrolls multi-line inputs. Input method composition
//! (pre-edit) text shows underlined at the caret.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Property = @import("properties.zig").Property;
const Callback = @import("callbacks.zig").Callback;
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Size = geometry.Size;
const Rect = geometry.Rect;
const graphics = @import("graphics.zig");
const Brush = graphics.Brush;
const Color = graphics.Color;
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const ItemVTable = item_mod.ItemVTable;
const layout = @import("layout.zig");
const LayoutInfo = layout.LayoutInfo;
const Orientation = layout.Orientation;
const input = @import("input.zig");
const Key = input.Key;
const rendering = @import("rendering.zig");
const ItemRenderer = rendering.ItemRenderer;
const Window = @import("window.zig").Window;
const time = @import("time.zig");
const Font = @import("text/text.zig").Font;
const text_layout = @import("text/layout.zig");
const text_edit = @import("text_edit.zig");
const TextLayout = text_edit.TextLayout;
const StringBuffer = @import("strings.zig").StringBuffer;
const Timer = @import("timers.zig").Timer;
const resolveFont = @import("items.zig").resolveFont;
const fallbackFonts = @import("items.zig").fallbackFonts;

/// What a text input shows.
pub const InputType = enum {
    text,
    /// Bullets instead of the characters; copying is disabled.
    password,
};

/// The text input with the keyboard focus, in any window (null: none), for
/// on-screen keyboards (`KeyboardInput`).
pub var focused_input: Property(?*TextInput) = .init(null);

/// Initialize in place with `init`.
pub const TextInput = struct {
    item: Item = .init(&vtable),
    gpa: Allocator,
    text: Property([]const u8) = .init(""),
    font: Property(?*const Font) = .init(null),
    font_family: Property([]const u8) = .init(""),
    font_weight: Property(i32) = .init(400),
    color: Property(Brush) = .init(.color(.black)),
    font_size: Property(f32) = .init(14),
    /// Pixels added after each character.
    letter_spacing: Property(f32) = .init(0),
    has_focus: Property(bool) = .init(false),
    /// Text can be selected and copied but not changed.
    read_only: Property(bool) = .init(false),
    input_type: Property(InputType) = .init(.text),
    /// False: Return inserts a newline and the text scrolls vertically.
    single_line: Property(bool) = .init(true),
    /// Word wrapping, for multi-line inputs.
    wrap: Property(rendering.TextWrap) = .init(.no_wrap),
    /// Where lines sit across it (each, in multi-line inputs).
    horizontal_alignment: Property(rendering.TextHorizontalAlignment) = .init(.left),
    /// Byte offsets of the caret and the other end of the selection.
    cursor_position: Property(i32) = .init(0),
    anchor_position: Property(i32) = .init(0),
    selection_background_color: Property(Brush) = .init(.color(.rgba(0x3a96dd66))),
    /// Called after each change made by the user.
    edited: Callback(fn () void) = .{},
    /// Called when Return is pressed in a single-line input.
    accepted: Callback(fn () void) = .{},

    caret_on: Property(bool) = .init(false),
    /// Input method composition text, shown at the caret.
    preedit: Property([]const u8) = .init(""),
    preedit_cursor: usize = 0,
    /// How far the text is scrolled to keep the caret visible.
    scroll_x: Property(f32) = .init(0),
    scroll_y: Property(f32) = .init(0),

    buffer: StringBuffer = .{},
    preedit_buffer: StringBuffer = .{},
    display_buffer: StringBuffer = .{},
    mask_buffer: StringBuffer = .{},
    history: text_edit.History = .{},
    /// What this input last set `text` to: other changes reset the history.
    own_text: []const u8 = "",
    /// Kept while moving up and down, so the caret returns to its column.
    preferred_x: ?f32 = null,
    drag: ?Unit = null,
    /// The word or line selected by the click that started a drag.
    drag_origin: text_edit.Range = .{ .start = 0, .end = 0 },
    last_click_ms: u64 = 0,
    last_click_position: Point = .{},
    clicks: u8 = 0,
    blink: Timer = .{},

    pub const blink_ms = 530;
    /// Clicks closer than this (in time and pixels) count as one multi-click.
    pub const multi_click_ms = 500;
    const multi_click_distance = 4;

    const Unit = enum { char, word, line };

    pub fn init(self: *TextInput, gpa: Allocator) void {
        self.* = .{ .gpa = gpa };
    }

    pub fn deinit(self: *TextInput) void {
        if (focused_input.getUntracked() == self) focused_input.set(null);
        self.blink.deinit();
        self.item.deinit();
        inline for (.{ "text", "font", "font_family", "font_weight", "color", "font_size", "letter_spacing", "has_focus", "read_only", "single_line", "wrap", "horizontal_alignment", "cursor_position", "anchor_position", "selection_background_color", "caret_on", "preedit", "scroll_x", "scroll_y", "input_type" }) |f|
            @field(self, f).deinit();
        self.buffer.deinit(self.gpa);
        self.preedit_buffer.deinit(self.gpa);
        self.display_buffer.deinit(self.gpa);
        self.mask_buffer.deinit(self.gpa);
        self.history.deinit(self.gpa);
    }

    pub fn focus(self: *TextInput) void {
        if (self.item.window()) |w| w.setFocusItem(&self.item);
    }

    // ---- Selection ----

    pub fn cursor(self: *TextInput) usize {
        return text_edit.clampOffset(self.text.get(), @intCast(@max(0, self.cursor_position.get())));
    }

    pub fn anchor(self: *TextInput) usize {
        return text_edit.clampOffset(self.text.get(), @intCast(@max(0, self.anchor_position.get())));
    }

    pub fn selection(self: *TextInput) text_edit.Range {
        const c = self.cursor();
        const a = self.anchor();
        return .{ .start = @min(c, a), .end = @max(c, a) };
    }

    pub fn selectedText(self: *TextInput) []const u8 {
        const s = self.selection();
        return self.text.get()[s.start..s.end];
    }

    pub fn setSelection(self: *TextInput, anchor_offset: usize, cursor_offset: usize) void {
        self.anchor_position.set(@intCast(anchor_offset));
        self.cursor_position.set(@intCast(cursor_offset));
        self.caretMoved();
    }

    pub fn selectAll(self: *TextInput) void {
        self.preferred_x = null;
        self.setSelection(0, self.text.get().len);
    }

    pub fn clearSelection(self: *TextInput) void {
        const c = self.cursor();
        self.setSelection(c, c);
    }

    fn moveTo(self: *TextInput, offset: usize, extend: bool) void {
        self.preferred_x = null;
        self.setSelection(if (extend) self.anchor() else offset, offset);
    }

    fn caretMoved(self: *TextInput) void {
        self.history.seal();
        self.showCaret();
        self.ensureCaretVisible();
    }

    fn showCaret(self: *TextInput) void {
        self.caret_on.set(true);
        self.blink.restart();
    }

    // ---- Editing ----

    /// Replaces the selection with `inserted` (as if typed), unless the
    /// input is read-only.
    pub fn insert(self: *TextInput, inserted: []const u8) void {
        self.replaceSelection(inserted, .other);
    }

    fn replaceSelection(self: *TextInput, inserted: []const u8, kind: text_edit.History.Kind) void {
        const s = self.selection();
        self.replace(s.start, s.end, inserted, kind);
    }

    fn replace(self: *TextInput, start: usize, end: usize, inserted: []const u8, kind: text_edit.History.Kind) void {
        if (self.read_only.get()) return;
        self.checkHistory();
        const text = self.text.get();
        const removed = text[start..end];
        if (std.mem.eql(u8, removed, inserted)) return;
        self.history.record(self.gpa, start, removed, inserted, self.cursor(), self.anchor(), kind) catch self.history.clear(self.gpa);
        self.setText(self.buffer.format(self.gpa, "{s}{s}{s}", .{ text[0..start], inserted, text[end..] }));
        const c = start + inserted.len;
        self.anchor_position.set(@intCast(c));
        self.cursor_position.set(@intCast(c));
        self.preferred_x = null;
        self.afterEdit();
    }

    fn setText(self: *TextInput, text: []const u8) void {
        self.text.set(text);
        self.own_text = self.text.get();
    }

    /// Forgets the history if `text` was changed by someone else.
    fn checkHistory(self: *TextInput) void {
        const t = self.text.get();
        if (t.ptr != self.own_text.ptr or t.len != self.own_text.len) self.history.clear(self.gpa);
    }

    fn afterEdit(self: *TextInput) void {
        self.showCaret();
        self.ensureCaretVisible();
        self.edited.call(.{});
    }

    pub fn undo(self: *TextInput) void {
        if (self.read_only.get()) return;
        self.checkHistory();
        const e = self.history.peekUndo() orelse return;
        const text = self.text.get();
        if (e.pos + e.inserted.items.len > text.len) return self.history.clear(self.gpa);
        self.setText(self.buffer.format(self.gpa, "{s}{s}{s}", .{ text[0..e.pos], e.removed.items, text[e.pos + e.inserted.items.len ..] }));
        self.anchor_position.set(@intCast(e.anchor));
        self.cursor_position.set(@intCast(e.cursor));
        self.history.undone(self.gpa) catch self.history.clear(self.gpa);
        self.preferred_x = null;
        self.afterEdit();
    }

    pub fn redo(self: *TextInput) void {
        if (self.read_only.get()) return;
        self.checkHistory();
        const e = self.history.peekRedo() orelse return;
        const text = self.text.get();
        if (e.pos + e.removed.items.len > text.len) return self.history.clear(self.gpa);
        self.setText(self.buffer.format(self.gpa, "{s}{s}{s}", .{ text[0..e.pos], e.inserted.items, text[e.pos + e.removed.items.len ..] }));
        const c = e.pos + e.inserted.items.len;
        self.anchor_position.set(@intCast(c));
        self.cursor_position.set(@intCast(c));
        self.history.redone(self.gpa) catch self.history.clear(self.gpa);
        self.preferred_x = null;
        self.afterEdit();
    }

    pub fn copy(self: *TextInput) void {
        if (self.masked()) return;
        const s = self.selectedText();
        if (s.len == 0) return;
        if (self.item.window()) |w| w.setClipboardText(s);
    }

    pub fn cut(self: *TextInput) void {
        if (self.read_only.get() or self.masked()) return;
        self.copy();
        self.replaceSelection("", .other);
    }

    pub fn paste(self: *TextInput) void {
        if (self.read_only.get()) return;
        const w = self.item.window() orelse return;
        const text = w.clipboardText(self.gpa) orelse return;
        defer self.gpa.free(text);
        // Single-line inputs get the text on one line; no carriage returns.
        var len: usize = 0;
        for (text) |b| {
            if (b == '\r') continue;
            text[len] = if (b == '\n' and self.single_line.get()) ' ' else b;
            len += 1;
        }
        self.replaceSelection(text[0..len], .other);
    }

    fn drawSpan(r: ItemRenderer, span: [2]f32, y: f32, height: f32, background: Brush) void {
        r.save();
        r.translate(.{ .x = span[0], .y = y });
        r.drawRectangle(.{ .width = span[1] - span[0], .height = height }, .{ .background = background });
        r.restore();
    }

    // ---- Layout and geometry ----

    fn resolvedFont(self: *TextInput) ?*const Font {
        return resolveFont(&self.item, self.font.get(), self.font_family.get(), self.font_weight.get());
    }

    fn wraps(self: *TextInput) bool {
        return !self.single_line.get() and self.wrap.get() == .word_wrap;
    }

    fn layoutOf(self: *TextInput, text: []const u8) TextLayout {
        return self.layoutAligned(text, true);
    }

    /// Laid out, its lines placed in the field if `placed` (else only
    /// broken where they will be: what the field's size follows from,
    /// without depending on it).
    fn layoutAligned(self: *TextInput, text: []const u8, placed: bool) TextLayout {
        var l: TextLayout = .{
            .metrics = text_layout.Metrics.initFallbacks(self.resolvedFont(), fallbackFonts(&self.item), self.font_size.get()).withSpacing(self.letter_spacing.get()),
            .text = text,
            .max_width = if (self.wraps()) self.item.width.get() else null,
            .alignment = self.horizontal_alignment.get(),
        };
        // Aligned in the field, with room for the caret at a line's end
        // (wrapped there too), or in the text when that is wider (it
        // scrolls).
        if (l.alignment != .left and (placed or l.max_width != null)) {
            const room = @max(0, self.item.width.get() - caret_width);
            if (l.max_width != null) l.max_width = room;
            if (placed) l.box_width = @max(room, l.size().width);
        }
        return l;
    }

    fn masked(self: *TextInput) bool {
        return self.input_type.get() == .password;
    }

    const bullet = "\u{2022}";

    /// The text as shown, before composition: bullets for passwords.
    fn shownText(self: *TextInput) []const u8 {
        const text = self.text.get();
        if (!self.masked()) return text;
        const n = std.unicode.utf8CountCodepoints(text) catch text.len;
        return self.mask_buffer.repeat(self.gpa, bullet, n);
    }

    /// An offset in the text as an offset in the shown text.
    fn toShown(self: *TextInput, offset: usize) usize {
        if (!self.masked()) return offset;
        const text = self.text.get();
        return (std.unicode.utf8CountCodepoints(text[0..@min(offset, text.len)]) catch offset) * bullet.len;
    }

    /// An offset in the shown text as an offset in the text.
    fn fromShown(self: *TextInput, offset: usize) usize {
        if (!self.masked()) return offset;
        const text = self.text.get();
        var i: usize = 0;
        var n: usize = 0;
        while (i < text.len and n < offset / bullet.len) : (n += 1) i = text_edit.nextCodePoint(text, i);
        return i;
    }

    /// The text shown: with the composition text at the caret.
    fn displayed(self: *TextInput) struct { text: []const u8, cursor: usize } {
        const text = self.shownText();
        const pre = self.preedit.get();
        const c = self.toShown(self.cursor());
        if (pre.len == 0) return .{ .text = text, .cursor = c };
        return .{
            .text = self.display_buffer.format(self.gpa, "{s}{s}{s}", .{ text[0..c], pre, text[c..] }),
            .cursor = c + self.preedit_cursor,
        };
    }

    /// Where the text's top-left corner is drawn, in item coordinates.
    fn textOrigin(self: *TextInput, l: TextLayout) Point {
        const size = self.item.size();
        const content = l.size();
        const max_x = @max(0, content.width + caret_width - size.width);
        const x = -std.math.clamp(self.scroll_x.get(), 0, max_x);
        if (self.single_line.get()) return .{ .x = x, .y = (size.height - l.lineHeight()) / 2 };
        const max_y = @max(0, content.height - size.height);
        return .{ .x = if (self.wraps()) 0 else x, .y = -std.math.clamp(self.scroll_y.get(), 0, max_y) };
    }

    const caret_width = 1.5;

    /// Scrolls so the caret is inside the item, and tells the window where
    /// it is (for input methods).
    fn ensureCaretVisible(self: *TextInput) void {
        const d = self.displayed();
        const l = self.layoutOf(d.text);
        const caret = l.caret(d.cursor);
        const size = self.item.size();
        const lh = l.lineHeight();
        var sx = self.scroll_x.get();
        if (caret.x + caret_width - sx > size.width) sx = caret.x + caret_width - size.width;
        if (caret.x < sx) sx = caret.x;
        self.scroll_x.set(@max(0, sx));
        if (!self.single_line.get()) {
            var sy = self.scroll_y.get();
            if (caret.y + lh - sy > size.height) sy = caret.y + lh - size.height;
            if (caret.y < sy) sy = caret.y;
            self.scroll_y.set(@max(0, sy));
        }
        if (self.item.window()) |w| if (w.focus_item == &self.item) {
            const at = self.item.absolutePosition().add(self.textOrigin(l)).add(caret);
            w.setImeCursorRect(.{ .x = at.x, .y = at.y, .width = caret_width, .height = lh });
        };
    }

    fn offsetAtPoint(self: *TextInput, p: Point) usize {
        const l = self.layoutOf(self.shownText());
        return self.fromShown(l.offsetAt(p.sub(self.textOrigin(l))));
    }

    /// The offset `lines` lines above (negative) or below the caret.
    fn verticalOffset(self: *TextInput, lines: i32) usize {
        const text = self.text.get();
        const l = self.layoutOf(text);
        const c = self.cursor();
        const x = self.preferred_x orelse l.caret(c).x;
        const info = l.lineOf(c);
        const target = @as(i64, @intCast(info.index)) + lines;
        if (target < 0) return 0;
        const line = l.lineAt(@intCast(target));
        if (line.index < target) return text.len;
        return l.offsetInLine(line.line, x);
    }

    fn moveVertically(self: *TextInput, lines: i32, extend: bool) void {
        const l = self.layoutOf(self.text.get());
        const x = self.preferred_x orelse l.caret(self.cursor()).x;
        const offset = self.verticalOffset(lines);
        self.setSelection(if (extend) self.anchor() else offset, offset);
        self.preferred_x = x;
    }

    fn visibleLines(self: *TextInput) i32 {
        const lh = self.layoutOf("").lineHeight();
        return @max(1, @as(i32, @intFromFloat(@floor(self.item.height.get() / lh))));
    }

    // ---- Item interface ----

    const vtable: ItemVTable = .{
        .name = "TextInput",
        .render = render,
        .layoutInfo = layoutInfo,
        .inputEvent = inputEvent,
        .keyEvent = keyEvent,
        .focusEvent = focusEvent,
        .preeditEvent = preeditEvent,
        .acceptsFocus = acceptsFocus,
        .accessible_role = .text_input,
        .accessibleValue = accessibleValue,
        .mouseCursor = mouseCursor,
    };

    /// An I-beam over text that can be selected.
    fn mouseCursor(i: *Item) input.MouseCursor {
        return if (i.isEnabled()) .text else .default;
    }

    fn parent(i: *Item) *TextInput {
        return @alignCast(@fieldParentPtr("item", i));
    }

    /// The text is the field's value (its label says what it is for); a
    /// password is not read out.
    fn accessibleValue(i: *Item) []const u8 {
        const self = parent(i);
        if (self.input_type.get() == .password) return "";
        return self.text.get();
    }

    fn layoutInfo(i: *Item, orientation: Orientation) LayoutInfo {
        const self = parent(i);
        const l = self.layoutAligned(self.shownText(), false);
        return switch (orientation) {
            .horizontal => blk: {
                const unwrapped: TextLayout = .{ .metrics = l.metrics, .text = l.text };
                break :blk .{ .min = 0, .preferred = unwrapped.size().width + caret_width, .stretch = 1 };
            },
            .vertical => blk: {
                const lh = l.lineHeight();
                if (self.single_line.get()) break :blk .{ .min = lh, .preferred = lh, .stretch = 0 };
                break :blk .{ .min = lh, .preferred = @max(lh, l.size().height), .stretch = 1 };
            },
        };
    }

    fn acceptsFocus(i: *Item) bool {
        return i.isEnabled();
    }

    fn inputEvent(i: *Item, event: input.PointerEvent, w: *Window) input.InputEventResult {
        const self = parent(i);
        switch (event) {
            .pressed => |p| {
                if (!acceptsFocus(i)) return .ignored;
                w.setFocusItem(i);
                if (p.button != .left) return .accepted;
                const now = time.now();
                const near = @abs(p.position.x - self.last_click_position.x) <= multi_click_distance and
                    @abs(p.position.y - self.last_click_position.y) <= multi_click_distance;
                self.clicks = if (self.clicks > 0 and near and now -| self.last_click_ms <= multi_click_ms) @min(self.clicks + 1, 3) else 1;
                self.last_click_ms = now;
                self.last_click_position = p.position;
                const offset = self.offsetAtPoint(p.position);
                const text = self.text.get();
                switch (self.clicks) {
                    1 => {
                        self.drag = .char;
                        // Shift+click extends the selection.
                        self.moveTo(offset, p.modifiers.shift);
                    },
                    2 => if (self.masked()) {
                        // Word boundaries of a password are not revealed.
                        self.drag = .line;
                        self.drag_origin = .{ .start = 0, .end = text.len };
                        self.setSelection(0, text.len);
                    } else {
                        self.drag = .word;
                        self.drag_origin = text_edit.wordAt(text, offset);
                        self.setSelection(self.drag_origin.start, self.drag_origin.end);
                    },
                    else => {
                        self.drag = .line;
                        self.drag_origin = if (self.single_line.get()) .{ .start = 0, .end = text.len } else text_edit.paragraphAt(text, offset);
                        self.setSelection(self.drag_origin.start, self.drag_origin.end);
                    },
                }
                return .grab;
            },
            .moved => |m| {
                const unit = self.drag orelse return .ignored;
                const offset = self.offsetAtPoint(m.position);
                const text = self.text.get();
                switch (unit) {
                    .char => self.setSelection(self.anchor(), offset),
                    .word, .line => {
                        const r = if (unit == .word) text_edit.wordAt(text, offset) else text_edit.paragraphAt(text, offset);
                        if (offset < self.drag_origin.start)
                            self.setSelection(self.drag_origin.end, r.start)
                        else
                            self.setSelection(self.drag_origin.start, @max(r.end, self.drag_origin.end));
                    },
                }
                return .grab;
            },
            .released => {
                if (self.drag == null) return .ignored;
                self.drag = null;
                return .accepted;
            },
            .wheel => |wh| {
                if (self.single_line.get()) return .ignored;
                const l = self.layoutOf(self.shownText());
                const content = l.size();
                const max_y = @max(0, content.height - i.height.get());
                const old = std.math.clamp(self.scroll_y.get(), 0, max_y);
                const new = std.math.clamp(old - wh.delta.y, 0, max_y);
                // Unwrapped lines scroll sideways too.
                const max_x = if (self.wraps()) 0 else @max(0, content.width + caret_width - i.width.get());
                const old_x = std.math.clamp(self.scroll_x.get(), 0, max_x);
                const new_x = std.math.clamp(old_x - wh.delta.x, 0, max_x);
                if (new == old and new_x == old_x) return .ignored;
                self.scroll_y.set(new);
                self.scroll_x.set(new_x);
                return .accepted;
            },
            .exit => return .ignored,
        }
    }

    fn focusEvent(i: *Item, event: input.FocusEvent, w: *Window) void {
        const self = parent(i);
        const focused = event == .focus_in;
        self.has_focus.set(focused);
        self.caret_on.set(focused);
        self.history.seal();
        if (focused) {
            self.blink.start(.repeated, blink_ms, self, toggleCaret);
            self.ensureCaretVisible();
            focused_input.set(self);
        } else {
            if (focused_input.getUntracked() == self) focused_input.set(null);
            self.blink.stop();
            self.preedit.set("");
            w.setImeCursorRect(null);
        }
    }

    fn toggleCaret(self: *TextInput) void {
        self.caret_on.set(!self.caret_on.getUntracked());
    }

    fn preeditEvent(i: *Item, text: []const u8, cursor_offset: usize, _: *Window) void {
        const self = parent(i);
        if (self.read_only.get()) return;
        // Composition replaces the selection.
        if (text.len > 0 and self.selection().start != self.selection().end) self.replaceSelection("", .other);
        self.preedit.set(self.preedit_buffer.format(self.gpa, "{s}", .{text}));
        self.preedit_cursor = cursor_offset;
        self.showCaret();
        self.ensureCaretVisible();
    }

    fn eql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    fn keyEvent(i: *Item, kind: input.KeyEventKind, event: input.KeyEvent, _: *Window) input.EventResult {
        const self = parent(i);
        if (kind != .pressed or !self.item.isEnabled()) return .reject;
        const text = event.text;
        const m = event.modifiers;
        const shift = m.shift;
        const content = self.text.get();
        const c = self.cursor();
        const sel = self.selection();
        const multi = !self.single_line.get();
        // Ctrl or Alt: by word. Cmd (macOS): to the line ends. A password
        // is one word.
        const by_word = (m.control or m.alt) and !self.masked();
        if ((m.control or m.alt) and self.masked() and (eql(text, Key.left_arrow) or eql(text, Key.right_arrow) or eql(text, Key.backspace) or eql(text, Key.delete))) {
            const left = eql(text, Key.left_arrow) or eql(text, Key.backspace);
            if (eql(text, Key.left_arrow) or eql(text, Key.right_arrow)) {
                self.moveTo(if (left) 0 else content.len, shift);
            } else if (sel.start != sel.end) {
                self.replaceSelection("", .other);
            } else if (left) {
                self.replace(0, c, "", .other);
            } else self.replace(c, content.len, "", .other);
            return .accept;
        }

        if (eql(text, Key.left_arrow)) {
            const to = if (m.meta) self.layoutOf(content).lineOf(c).line.start else if (by_word) text_edit.prevWordStart(content, c) else if (!shift and sel.start != sel.end) sel.start else text_edit.prevChar(content, c);
            self.moveTo(to, shift);
        } else if (eql(text, Key.right_arrow)) {
            const to = if (m.meta) self.layoutOf(content).lineOf(c).line.end else if (by_word) text_edit.nextWordEnd(content, c) else if (!shift and sel.start != sel.end) sel.end else text_edit.nextChar(content, c);
            self.moveTo(to, shift);
        } else if (eql(text, Key.up_arrow)) {
            if (!multi or m.meta) self.moveTo(0, shift) else self.moveVertically(-1, shift);
        } else if (eql(text, Key.down_arrow)) {
            if (!multi or m.meta) self.moveTo(content.len, shift) else self.moveVertically(1, shift);
        } else if (eql(text, Key.page_up) and multi) {
            self.moveVertically(-self.visibleLines(), shift);
        } else if (eql(text, Key.page_down) and multi) {
            self.moveVertically(self.visibleLines(), shift);
        } else if (eql(text, Key.home)) {
            self.moveTo(if (m.control or !multi) 0 else self.layoutOf(content).lineOf(c).line.start, shift);
        } else if (eql(text, Key.end)) {
            self.moveTo(if (m.control or !multi) content.len else self.layoutOf(content).lineOf(c).line.end, shift);
        } else if (eql(text, Key.backspace)) {
            if (sel.start != sel.end) {
                self.replaceSelection("", .other);
            } else {
                const from = if (m.meta) self.layoutOf(content).lineOf(c).line.start else if (by_word) text_edit.prevWordStart(content, c) else text_edit.prevChar(content, c);
                self.replace(from, c, "", .backspace);
            }
        } else if (eql(text, Key.delete)) {
            if (sel.start != sel.end) {
                self.replaceSelection("", .other);
            } else {
                const to = if (by_word) text_edit.nextWordEnd(content, c) else text_edit.nextChar(content, c);
                self.replace(c, to, "", .delete);
            }
        } else if (eql(text, Key.@"return")) {
            if (!multi) {
                self.accepted.call(.{});
            } else {
                self.replaceSelection("\n", .other);
            }
        } else if ((m.control or m.meta) and text.len == 1) {
            switch (std.ascii.toLower(text[0])) {
                'a' => self.selectAll(),
                'c' => self.copy(),
                'x' => self.cut(),
                'v' => self.paste(),
                'z' => if (shift) self.redo() else self.undo(),
                'y' => self.redo(),
                else => return .reject,
            }
        } else {
            // Tab, Escape, other shortcuts and special keys are not text.
            if (m.control or m.meta or text.len == 0 or text[0] < 0x20 or text[0] == 0x7f) return .reject;
            const cp = text_layout.decode(text, 0).cp;
            if (cp >= 0xf700 and cp <= 0xf8ff) return .reject;
            if (self.read_only.get()) return .reject;
            self.replaceSelection(text, .typing);
        }
        return .accept;
    }

    fn render(i: *Item, r: ItemRenderer) void {
        const self = parent(i);
        const size = i.size();
        const d = self.displayed();
        const l = self.layoutOf(d.text);
        const lh = l.lineHeight();
        const origin = self.textOrigin(l);
        const content = l.size();
        const color = self.color.get();
        const focused = self.has_focus.get();

        r.save();
        defer r.restore();
        if (!r.clip(.{ .width = size.width, .height = size.height })) return;
        r.translate(origin);

        // Selection (hidden while composing).
        const raw_sel = self.selection();
        const sel: text_edit.Range = .{ .start = self.toShown(raw_sel.start), .end = self.toShown(raw_sel.end) };
        if (sel.start != sel.end and self.preedit.get().len == 0) {
            const background = self.selection_background_color.get();
            var it: text_layout.LineIterator = .initMetrics(l.metrics, d.text, l.max_width);
            var line = it.next();
            var y: f32 = 0;
            while (line) |ln| : (y += lh) {
                const next = it.next();
                const line_end = if (next) |n| n.start else d.text.len;
                line = next;
                if (sel.end < ln.start or sel.start > line_end) continue;
                if (sel.start == line_end and next != null) continue;
                // The selected glyphs, merged where adjacent (right-to-left
                // text can split a selection into several pieces).
                var span: ?[2]f32 = null;
                var glyphs: text_layout.GlyphIterator = .initMetrics(l.metrics, d.text, ln);
                const left = l.lineLeft(ln);
                while (glyphs.next()) |g| {
                    const selected = g.byte >= sel.start and g.byte < sel.end;
                    if (selected) {
                        const x = left + g.x;
                        if (span) |*sp| if (@abs(sp[1] - x) < 0.01) {
                            sp[1] = x + g.advance;
                            continue;
                        };
                        if (span) |sp| drawSpan(r, sp, y, lh, background);
                        span = .{ x, x + g.advance };
                    }
                }
                if (span) |sp| drawSpan(r, sp, y, lh, background);
                // Selections going past the line end show the line break.
                if (sel.end > ln.end) drawSpan(r, .{ left + ln.width, left + ln.width + 0.3 * self.font_size.get() }, y, lh, background);
            }
        }

        const aligned = l.alignment != .left;
        r.drawText(.{ .width = if (aligned) l.box_width else if (self.wraps()) size.width else content.width + caret_width, .height = content.height }, .{
            .text = d.text,
            .font = self.resolvedFont(),
            .color = color,
            .font_size = self.font_size.get(),
            .letter_spacing = self.letter_spacing.get(),
            .wrap = if (self.wraps()) .word_wrap else .no_wrap,
            .horizontal_alignment = l.alignment,
            .fallbacks = fallbackFonts(&self.item),
        });

        // Composition text is underlined.
        const pre = self.preedit.get();
        if (pre.len > 0) {
            const start = self.toShown(self.cursor());
            const a = l.caret(start);
            const b = l.caret(start + pre.len);
            if (a.y == b.y) {
                r.save();
                r.translate(.{ .x = a.x, .y = a.y + lh - 1 });
                r.drawRectangle(.{ .width = b.x - a.x, .height = 1 }, .{ .background = color });
                r.restore();
            }
        }

        if (focused and self.caret_on.get()) {
            const caret = l.caret(d.cursor);
            r.translate(caret);
            r.drawRectangle(.{ .width = caret_width, .height = lh }, .{ .background = color });
        }
    }
};
