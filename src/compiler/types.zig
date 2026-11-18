// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! Types of the `.zge` language and the built-in elements.

const std = @import("std");

pub const Enum = struct {
    name: []const u8,
    zig: []const u8,
    /// `.zge` name and Zig tag of each value.
    values: []const [2][]const u8,

    pub fn find(e: *const Enum, name: []const u8) ?[]const u8 {
        for (e.values) |v| if (std.mem.eql(u8, v[0], name)) return v[1];
        return null;
    }
};

pub const Type = union(enum) {
    void,
    int,
    float,
    bool,
    string,
    /// Logical pixels (`px`).
    length,
    /// Milliseconds (`ms`, `s`); only in animation settings for now.
    duration,
    color,
    brush,
    image,
    /// Sound to play (`@audio-url`).
    audio,
    /// A video to play (`@video-url`).
    video,
    /// A 3D model (`@model-url`): a glTF file.
    model3d,
    /// A component (its name as a value; `Loader` shows it).
    component,
    easing,
    enumeration: *const Enum,
    key_event,
    /// A TouchArea's `pointer-event` argument.
    pointer_event,
    modifiers,
    /// A model of rows (`[string]`): `zigulee.Model(T)`; points at the row
    /// type.
    model: *const Type,
    /// A struct declared in `.zge`.
    structure: *const StructDef,

    pub fn eql(a: Type, b: Type) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .enumeration => |e| e == b.enumeration,
            .model => |m| m.eql(b.model.*),
            .structure => |s| s == b.structure,
            else => true,
        };
    }

    pub fn zig(t: Type) []const u8 {
        return switch (t) {
            .void => "void",
            .int => "i32",
            .float, .length => "f32",
            .bool => "bool",
            .string => "[]const u8",
            .duration => "i64",
            .color => "zigulee.Color",
            .brush => "zigulee.Brush",
            .image => "zigulee.core.Image",
            .audio => "zigulee.core.Audio",
            .video => "zigulee.core.Video",
            .model3d => "zigulee.core.Model3D",
            .component => "zigulee.core.loader.Component",
            .easing => "zigulee.Easing",
            .enumeration => |e| e.zig,
            .key_event => "zigulee.core.input.KeyEvent",
            .pointer_event => "zigulee.core.input.TouchAreaEvent",
            .modifiers => "zigulee.core.input.Modifiers",
            .structure => |s| s.zig,
            .model => |m| modelZig(m.*),
        };
    }

    /// `zigulee.Model(...)` with rows of `row`.
    fn modelZig(row: Type) []const u8 {
        return switch (row) {
            inline .int, .float, .length, .bool, .string, .color, .brush => |_, tag| "zigulee.Model(" ++ comptime primitiveZig(tag) ++ ")",
            .structure => |s| s.model_zig,
            .model => |inner| switch (inner.*) {
                inline .int, .float, .length, .bool, .string, .color, .brush => |_, tag| "zigulee.Model(zigulee.Model(" ++ comptime primitiveZig(tag) ++ "))",
                else => unreachable,
            },
            else => unreachable,
        };
    }

    /// Zig code for an empty model of `t` (a model type).
    pub fn emptyModelZig(t: Type) []const u8 {
        return switch (t.model.*) {
            inline .int, .float, .length, .bool, .string, .color, .brush => |_, tag| "zigulee.core.emptyModel(" ++ comptime primitiveZig(tag) ++ ")",
            .structure => |s| s.empty_model,
            .model => |inner| switch (inner.*) {
                inline .int, .float, .length, .bool, .string, .color, .brush => |_, tag| "zigulee.core.emptyModel(zigulee.Model(" ++ comptime primitiveZig(tag) ++ "))",
                else => "undefined",
            },
            else => "undefined",
        };
    }

    pub fn name(t: Type) []const u8 {
        return switch (t) {
            .enumeration => |e| e.name,
            .structure => |s| s.name,
            .model => |m| switch (m.*) {
                inline .int, .float, .bool, .string, .length, .color, .brush => |_, tag| "[" ++ @tagName(tag) ++ "]",
                .structure => |s| s.model_name,
                .model => |inner| switch (inner.*) {
                    inline .int, .float, .bool, .string, .length, .color, .brush => |_, tag| "[[" ++ @tagName(tag) ++ "]]",
                    else => "[[?]]",
                },
                else => "[?]",
            },
            .key_event => "KeyEvent",
            .pointer_event => "PointerEvent",
            .modifiers => "KeyboardModifiers",
            else => @tagName(t),
        };
    }

    /// Whether `Settings` can keep properties of this type.
    pub fn keptBySettings(t: Type) bool {
        return switch (t) {
            .int, .float, .length, .duration, .bool, .string, .color => true,
            else => false,
        };
    }

    pub fn isNumeric(t: Type) bool {
        return t == .int or t == .float or t == .length or t == .duration;
    }

    /// Types usable in `var <T>` declarations.
    pub fn fromName(n: []const u8) ?Type {
        const table = .{
            .{ "int", Type.int },
            .{ "float", Type.float },
            .{ "bool", Type.bool },
            .{ "string", Type.string },
            .{ "length", Type.length },
            .{ "duration", Type.duration },
            .{ "color", Type.color },
            .{ "brush", Type.brush },
            .{ "image", Type.image },
            .{ "audio", Type.audio },
            .{ "video", Type.video },
            .{ "model3d", Type.model3d },
            .{ "component", Type.component },
        };
        inline for (table) |entry| if (std.mem.eql(u8, n, entry[0])) return entry[1];
        for (enums) |e| {
            if (std.mem.eql(u8, n, e.name)) return .{ .enumeration = e };
        }
        return null;
    }

    /// A field of a struct-typed value.
    pub fn field(t: Type, n: []const u8) ?struct { Type, []const u8 } {
        switch (t) {
            .structure => |s| for (s.fields) |f| {
                if (std.mem.eql(u8, f.name, n)) return .{ f.ty, f.zig };
            },
            .key_event => {
                if (std.mem.eql(u8, n, "text")) return .{ .string, "text" };
                if (std.mem.eql(u8, n, "modifiers")) return .{ .modifiers, "modifiers" };
                if (std.mem.eql(u8, n, "repeat")) return .{ .bool, "repeat" };
            },
            .pointer_event => {
                if (std.mem.eql(u8, n, "kind")) return .{ .{ .enumeration = &pointer_event_kind }, "kind" };
                if (std.mem.eql(u8, n, "button")) return .{ .{ .enumeration = &pointer_event_button }, "button" };
                if (std.mem.eql(u8, n, "modifiers")) return .{ .modifiers, "modifiers" };
            },
            .modifiers => inline for (.{ "shift", "control", "alt", "meta" }) |m| {
                if (std.mem.eql(u8, n, m)) return .{ .bool, m };
            },
            else => {},
        }
        return null;
    }
};

/// A struct declared in `.zge`.
pub const StructDef = struct {
    name: []const u8,
    zig: []const u8,
    fields: []const Field,
    /// `Type{ .structure = this }`, so models can point at it.
    self_type: Type,
    model_zig: []const u8,
    model_name: []const u8,
    /// Zig code for a default value and for an empty model of it.
    default_value: []const u8,
    empty_model: []const u8,

    pub const Field = struct { name: []const u8, zig: []const u8, ty: Type };
};

fn primitiveZig(comptime tag: std.meta.Tag(Type)) []const u8 {
    return switch (tag) {
        .int => "i32",
        .float, .length => "f32",
        .bool => "bool",
        .string => "[]const u8",
        .color => "zigulee.Color",
        .brush => "zigulee.Brush",
        else => unreachable,
    };
}

/// Static row types, for models to point at.
const rows = struct {
    const int: Type = .int;
    const float: Type = .float;
    const @"bool": Type = .bool;
    const string: Type = .string;
    const length: Type = .length;
    const color: Type = .color;
    const brush: Type = .brush;
};

/// Models of those (rows of `[[string]]`).
const model_rows = struct {
    const int: Type = .{ .model = &rows.int };
    const float: Type = .{ .model = &rows.float };
    const @"bool": Type = .{ .model = &rows.bool };
    const string: Type = .{ .model = &rows.string };
    const length: Type = .{ .model = &rows.length };
    const color: Type = .{ .model = &rows.color };
    const brush: Type = .{ .model = &rows.brush };
};

/// The model type with rows of `t`, if models of `t` are supported: basic
/// types, structs, and models of basic types (`[[string]]`).
pub fn modelOf(t: Type) ?Type {
    return switch (t) {
        inline .int, .float, .bool, .string, .length, .color, .brush => |_, tag| .{ .model = &@field(rows, @tagName(tag)) },
        .structure => |s| .{ .model = &s.self_type },
        .model => |inner| switch (inner.*) {
            inline .int, .float, .bool, .string, .length, .color, .brush => |_, tag| .{ .model = &@field(model_rows, @tagName(tag)) },
            else => null,
        },
        else => null,
    };
}

/// The built-in enumerations.
pub const enums = [_]*const Enum{ &text_horizontal_alignment, &text_vertical_alignment, &text_wrap, &layout_alignment, &event_result, &orientation, &pointer_event_kind, &pointer_event_button, &image_fit, &image_rendering, &image_status, &device_orientation, &position_error, &input_type, &popup_close_policy, &accessible_role, &mouse_cursor, &text_overflow, &font_size_mode, &file_dialog_mode, &swipe_direction, &text_format, &selection_mode, &http_method };

pub const selection_mode: Enum = .{
    .name = "SelectionMode",
    .zig = "zigulee.core.selection.SelectionMode",
    .values = &.{ .{ "single", "single" }, .{ "extended", "extended" }, .{ "multiple", "multiple" } },
};

pub const text_format: Enum = .{
    .name = "TextFormat",
    .zig = "zigulee.core.richtext.TextFormat",
    .values = &.{ .{ "markdown", "markdown" }, .{ "html", "html" } },
};

pub const swipe_direction: Enum = .{
    .name = "SwipeDirection",
    .zig = "zigulee.core.gestures.SwipeDirection",
    .values = &.{ .{ "left", "left" }, .{ "right", "right" }, .{ "up", "up" }, .{ "down", "down" } },
};

pub const http_method: Enum = .{
    .name = "HttpMethod",
    .zig = "zigulee.core.http.Method",
    .values = &.{ .{ "get", "get" }, .{ "post", "post" }, .{ "put", "put" }, .{ "patch", "patch" }, .{ "delete", "delete" }, .{ "head", "head" } },
};

pub const file_dialog_mode: Enum = .{
    .name = "FileDialogMode",
    .zig = "zigulee.core.dialogs.FileDialogMode",
    .values = &.{ .{ "open-file", "open_file" }, .{ "open-files", "open_files" }, .{ "open-folder", "open_folder" }, .{ "save-file", "save_file" } },
};

pub const text_overflow: Enum = .{
    .name = "TextOverflow",
    .zig = "zigulee.core.rendering.TextOverflow",
    .values = &.{ .{ "clip", "clip" }, .{ "elide", "elide" } },
};

pub const font_size_mode: Enum = .{
    .name = "FontSizeMode",
    .zig = "zigulee.core.rendering.FontSizeMode",
    .values = &.{ .{ "fixed", "fixed" }, .{ "horizontal-fit", "horizontal_fit" }, .{ "vertical-fit", "vertical_fit" }, .{ "fit", "fit" } },
};

pub const mouse_cursor: Enum = .{
    .name = "MouseCursor",
    .zig = "zigulee.core.input.MouseCursor",
    .values = &.{
        .{ "default", "default" },         .{ "none", "none" },               .{ "help", "help" },
        .{ "pointer", "pointer" },         .{ "progress", "progress" },       .{ "wait", "wait" },
        .{ "crosshair", "crosshair" },     .{ "text", "text" },               .{ "move", "move" },
        .{ "not-allowed", "not_allowed" }, .{ "grab", "grab" },               .{ "grabbing", "grabbing" },
        .{ "col-resize", "col_resize" },   .{ "row-resize", "row_resize" },   .{ "ew-resize", "ew_resize" },
        .{ "ns-resize", "ns_resize" },     .{ "nesw-resize", "nesw_resize" }, .{ "nwse-resize", "nwse_resize" },
    },
};

pub const accessible_role: Enum = .{
    .name = "AccessibleRole",
    .zig = "zigulee.core.AccessibleRole",
    .values = &.{
        .{ "none", "none" },                             .{ "button", "button" },               .{ "checkbox", "checkbox" },   .{ "radio-button", "radio_button" },
        .{ "combobox", "combobox" },                     .{ "list", "list" },                   .{ "list-item", "list_item" }, .{ "slider", "slider" },
        .{ "spinbox", "spinbox" },                       .{ "switch", "switch_" },              .{ "tab", "tab" },             .{ "tab-list", "tab_list" },
        .{ "tab-panel", "tab_panel" },                   .{ "table", "table" },                 .{ "text", "text" },           .{ "text-input", "text_input" },
        .{ "progress-indicator", "progress_indicator" }, .{ "image", "image" },                 .{ "group", "group" },         .{ "table-row", "table_row" },
        .{ "table-cell", "table_cell" },                 .{ "column-header", "column_header" },
    },
};

pub const text_horizontal_alignment: Enum = .{
    .name = "TextHorizontalAlignment",
    .zig = "zigulee.core.rendering.TextHorizontalAlignment",
    .values = &.{ .{ "left", "left" }, .{ "center", "center" }, .{ "right", "right" } },
};
pub const text_vertical_alignment: Enum = .{
    .name = "TextVerticalAlignment",
    .zig = "zigulee.core.rendering.TextVerticalAlignment",
    .values = &.{ .{ "top", "top" }, .{ "center", "center" }, .{ "bottom", "bottom" } },
};
pub const text_wrap: Enum = .{
    .name = "TextWrap",
    .zig = "zigulee.core.rendering.TextWrap",
    .values = &.{ .{ "no-wrap", "no_wrap" }, .{ "word-wrap", "word_wrap" } },
};
pub const layout_alignment: Enum = .{
    .name = "LayoutAlignment",
    .zig = "zigulee.core.layout.Alignment",
    .values = &.{
        .{ "stretch", "stretch" }, .{ "start", "start" },                 .{ "end", "end" },
        .{ "center", "center" },   .{ "space-between", "space_between" }, .{ "space-around", "space_around" },
    },
};
pub const image_fit: Enum = .{
    .name = "ImageFit",
    .zig = "zigulee.core.image.ImageFit",
    .values = &.{ .{ "fill", "fill" }, .{ "contain", "contain" }, .{ "cover", "cover" }, .{ "preserve", "preserve" }, .{ "tile", "tile" }, .{ "tile-horizontally", "tile_horizontally" }, .{ "tile-vertically", "tile_vertically" } },
};
pub const image_status: Enum = .{
    .name = "ImageStatus",
    .zig = "zigulee.core.image.ImageStatus",
    .values = &.{ .{ "none", "none" }, .{ "loading", "loading" }, .{ "ready", "ready" }, .{ "error", "failed" } },
};
/// What every sensor element has (`zigulee.core.sensors.Sensor`).
const sensor_props = [_]Prop{
    .{ .name = "active", .ty = .bool, .zig = "sensor.active" },
    .{ .name = "available", .ty = .bool, .zig = "sensor.available", .read_only = true },
    .{ .name = "data-rate", .ty = .int, .zig = "sensor.data_rate" },
};

pub const device_orientation: Enum = .{
    .name = "DeviceOrientation",
    .zig = "zigulee.core.sensors.Orientation",
    .values = &.{ .{ "unknown", "unknown" }, .{ "top-up", "top_up" }, .{ "top-down", "top_down" }, .{ "left-up", "left_up" }, .{ "right-up", "right_up" }, .{ "face-up", "face_up" }, .{ "face-down", "face_down" } },
};
pub const position_error: Enum = .{
    .name = "PositionError",
    .zig = "zigulee.core.location.Failure",
    .values = &.{ .{ "none", "none" }, .{ "permission-denied", "permission_denied" }, .{ "unavailable", "unavailable" }, .{ "timeout", "timeout" } },
};
pub const mesh: Enum = .{
    .name = "Mesh",
    .zig = "zigulee.core.view3d.Mesh",
    .values = &.{ .{ "cube", "cube" }, .{ "sphere", "sphere" }, .{ "plane", "plane" } },
};
pub const image_rendering: Enum = .{
    .name = "ImageRendering",
    .zig = "zigulee.core.image.ImageRendering",
    .values = &.{ .{ "smooth", "smooth" }, .{ "pixelated", "pixelated" } },
};
pub const input_type: Enum = .{
    .name = "InputType",
    .zig = "zigulee.items.InputType",
    .values = &.{ .{ "text", "text" }, .{ "password", "password" } },
};
pub const popup_close_policy: Enum = .{
    .name = "PopupClosePolicy",
    .zig = "zigulee.items.PopupClosePolicy",
    .values = &.{ .{ "close-on-click", "close_on_click" }, .{ "close-on-click-outside", "close_on_click_outside" }, .{ "no-auto-close", "no_auto_close" } },
};
pub const orientation: Enum = .{
    .name = "Orientation",
    .zig = "zigulee.core.Orientation",
    .values = &.{ .{ "horizontal", "horizontal" }, .{ "vertical", "vertical" } },
};

pub const pointer_event_kind: Enum = .{
    .name = "PointerEventKind",
    .zig = "zigulee.core.input.TouchAreaEvent.Kind",
    .values = &.{ .{ "cancel", "cancel" }, .{ "down", "down" }, .{ "up", "up" }, .{ "move", "move" } },
};

pub const pointer_event_button: Enum = .{
    .name = "PointerEventButton",
    .zig = "zigulee.core.input.PointerButton",
    .values = &.{ .{ "other", "other" }, .{ "left", "left" }, .{ "right", "right" }, .{ "middle", "middle" } },
};

pub const event_result: Enum = .{
    .name = "EventResult",
    .zig = "zigulee.core.input.EventResult",
    .values = &.{ .{ "accept", "accept" }, .{ "reject", "reject" } },
};

pub const easing_names = [_][2][]const u8{
    .{ "linear", "linear" },                     .{ "ease", "ease" },                           .{ "ease-in", "ease_in" },
    .{ "ease-out", "ease_out" },                 .{ "ease-in-out", "ease_in_out" },             .{ "ease-in-quad", "ease_in_quad" },
    .{ "ease-out-quad", "ease_out_quad" },       .{ "ease-in-out-quad", "ease_in_out_quad" },   .{ "ease-in-cubic", "ease_in_cubic" },
    .{ "ease-out-cubic", "ease_out_cubic" },     .{ "ease-in-out-cubic", "ease_in_out_cubic" }, .{ "ease-out-back", "ease_out_back" },
    .{ "ease-out-elastic", "ease_out_elastic" }, .{ "ease-out-bounce", "ease_out_bounce" },
};

// ---- Built-in elements ----

pub const Prop = struct {
    name: []const u8,
    ty: Type,
    /// Field path(s) relative to the element value; several comma-separated
    /// paths are all written (`padding`). A leading `@` means a field of the
    /// component instead.
    zig: []const u8,
    read_only: bool = false,
    /// The field is a `Property(?T)`.
    optional: bool = false,
};

pub const Callback = struct {
    name: []const u8,
    zig: []const u8,
    params: []const Type = &.{},
    ret: Type = .void,
};

pub const Function = struct {
    name: []const u8,
    /// Method called on the element value.
    zig: []const u8,
    params: []const Type = &.{},
};

pub const Builtin = struct {
    name: []const u8,
    /// What it is, for the reference documentation (tools/docgen.zig).
    doc: []const u8 = "",
    zig_type: []const u8,
    /// Field initializer.
    init: []const u8 = ".{}",
    /// Path from the element value to its `zigulee.Item`.
    item: []const u8 = "item",
    /// Path to the item children are added to (default: `item`).
    content: ?[]const u8 = null,
    /// In-place initialization call, if the element needs one.
    init_call: ?[]const u8 = null,
    /// Part of the item tree (false for non-visual elements like Timer).
    in_tree: bool = true,
    props: []const Prop = &.{},
    callbacks: []const Callback = &.{},
    functions: []const Function = &.{},
    layout: bool = false,
    window: bool = false,
    /// Accepts child elements.
    children: bool = true,

    pub fn prop(b: *const Builtin, n: []const u8) ?*const Prop {
        for (b.props) |*p| if (std.mem.eql(u8, p.name, n)) return p;
        return null;
    }

    pub fn callback(b: *const Builtin, n: []const u8) ?*const Callback {
        for (b.callbacks) |*c| if (std.mem.eql(u8, c.name, n)) return c;
        return null;
    }

    pub fn function(b: *const Builtin, n: []const u8) ?*const Function {
        for (b.functions) |*f| if (std.mem.eql(u8, f.name, n)) return f;
        return null;
    }
};

/// Properties every element has (relative to its item).
pub const geometry_props = [_]Prop{
    .{ .name = "x", .ty = .length, .zig = "x" },
    .{ .name = "y", .ty = .length, .zig = "y" },
    .{ .name = "width", .ty = .length, .zig = "width" },
    .{ .name = "height", .ty = .length, .zig = "height" },
    .{ .name = "visible", .ty = .bool, .zig = "visible" },
    .{ .name = "opacity", .ty = .float, .zig = "opacity" },
};

/// Layout constraint properties (stored in a `LayoutConstraints`).
pub const constraint_props = [_]Prop{
    .{ .name = "min-width", .ty = .length, .zig = "min_width" },
    .{ .name = "max-width", .ty = .length, .zig = "max_width" },
    .{ .name = "preferred-width", .ty = .length, .zig = "preferred_width" },
    .{ .name = "min-height", .ty = .length, .zig = "min_height" },
    .{ .name = "max-height", .ty = .length, .zig = "max_height" },
    .{ .name = "preferred-height", .ty = .length, .zig = "preferred_height" },
    .{ .name = "horizontal-stretch", .ty = .float, .zig = "horizontal_stretch" },
    .{ .name = "vertical-stretch", .ty = .float, .zig = "vertical_stretch" },
};

/// Rotation, scale, blur, clip path and mask every element has (stored in an
/// `ItemTransform`, created for elements that use them). They do not
/// change the layout.
pub const transform_props = [_]Prop{
    .{ .name = "rotation", .ty = .float, .zig = "rotation" },
    .{ .name = "scale", .ty = .float, .zig = "scale_x,scale_y" },
    .{ .name = "scale-x", .ty = .float, .zig = "scale_x" },
    .{ .name = "scale-y", .ty = .float, .zig = "scale_y" },
    .{ .name = "transform-origin-x", .ty = .length, .zig = "origin_x", .optional = true },
    .{ .name = "transform-origin-y", .ty = .length, .zig = "origin_y", .optional = true },
    .{ .name = "blur", .ty = .length, .zig = "blur" },
    .{ .name = "rotation-x", .ty = .float, .zig = "rotation_x" },
    .{ .name = "rotation-y", .ty = .float, .zig = "rotation_y" },
    .{ .name = "perspective", .ty = .length, .zig = "perspective" },
    .{ .name = "clip-path", .ty = .string, .zig = "clip_path" },
    .{ .name = "mask-image", .ty = .image, .zig = "mask_image", .optional = true },
    .{ .name = "mask-inverted", .ty = .bool, .zig = "mask_inverted" },
    .{ .name = "prefer-rendering-cache", .ty = .bool, .zig = "prefer_rendering_cache" },
};

/// A Rectangle's shadow (stored in a `DropShadow`, created for rectangles
/// that use it).
pub const shadow_props = [_]Prop{
    .{ .name = "drop-shadow-offset-x", .ty = .length, .zig = "offset_x" },
    .{ .name = "drop-shadow-offset-y", .ty = .length, .zig = "offset_y" },
    .{ .name = "drop-shadow-blur", .ty = .length, .zig = "blur" },
    .{ .name = "drop-shadow-color", .ty = .color, .zig = "color" },
};

/// Accessibility properties every element has (stored in an
/// `AccessibleProperties`, created for elements that set them).
pub const accessible_props = [_]Prop{
    .{ .name = "accessible-role", .ty = .{ .enumeration = &accessible_role }, .zig = "role" },
    .{ .name = "accessible-label", .ty = .string, .zig = "label" },
    .{ .name = "accessible-description", .ty = .string, .zig = "description" },
    .{ .name = "accessible-value", .ty = .string, .zig = "value" },
    .{ .name = "accessible-value-minimum", .ty = .float, .zig = "value_minimum" },
    .{ .name = "accessible-value-maximum", .ty = .float, .zig = "value_maximum" },
    .{ .name = "accessible-value-step", .ty = .float, .zig = "value_step" },
    .{ .name = "accessible-checkable", .ty = .bool, .zig = "checkable" },
    .{ .name = "accessible-checked", .ty = .bool, .zig = "checked" },
    .{ .name = "accessible-enabled", .ty = .bool, .zig = "enabled" },
    .{ .name = "accessible-placeholder-text", .ty = .string, .zig = "placeholder_text" },
    .{ .name = "accessible-multiselectable", .ty = .bool, .zig = "multiselectable" },
};

/// What assistive technology can ask an element to do.
pub const accessible_callbacks = [_]Callback{
    .{ .name = "accessible-action-default", .zig = "action_default" },
    .{ .name = "accessible-action-increment", .zig = "action_increment" },
    .{ .name = "accessible-action-decrement", .zig = "action_decrement" },
    .{ .name = "accessible-action-set-value", .zig = "action_set_value", .params = &.{.string} },
    .{ .name = "accessible-action-select", .zig = "action_select" },
    .{ .name = "accessible-action-set-selected", .zig = "action_set_selected", .params = &.{.bool} },
};

const grid_props = [_]Prop{
    .{ .name = "spacing", .ty = .length, .zig = "spacing" },
    .{ .name = "padding", .ty = .length, .zig = "padding_left,padding_right,padding_top,padding_bottom" },
    .{ .name = "padding-left", .ty = .length, .zig = "padding_left" },
    .{ .name = "padding-right", .ty = .length, .zig = "padding_right" },
    .{ .name = "padding-top", .ty = .length, .zig = "padding_top" },
    .{ .name = "padding-bottom", .ty = .length, .zig = "padding_bottom" },
};

const layout_props = [_]Prop{
    .{ .name = "spacing", .ty = .length, .zig = "spacing" },
    .{ .name = "padding", .ty = .length, .zig = "padding_left,padding_right,padding_top,padding_bottom" },
    .{ .name = "padding-left", .ty = .length, .zig = "padding_left" },
    .{ .name = "padding-right", .ty = .length, .zig = "padding_right" },
    .{ .name = "padding-top", .ty = .length, .zig = "padding_top" },
    .{ .name = "padding-bottom", .ty = .length, .zig = "padding_bottom" },
    .{ .name = "alignment", .ty = .{ .enumeration = &layout_alignment }, .zig = "alignment" },
};

pub const builtins = [_]Builtin{
    .{
        .name = "Window",
        .doc = "The root of a component shown in a window. Its `width` and `height` are the window's initial size; `title` is for the backend. `fullscreen`, `maximized`, `minimized` and `always-on-top` say how the system shows it: set them to change it, and they follow when the user does (from the title bar, say), for backends that can (not KMS or the web; Wayland has no always-on-top). On phones and tablets, `safe-area-top`, `-left`, `-bottom` and `-right` are how far in from each edge the content is clear of the system's bars, notches and rounded corners, and `keyboard-height` how much of the bottom the on-screen keyboard covers (0 elsewhere). `input-activity` is called for every press, move, release, wheel turn, finger and key, whichever element takes it (an element dragging included): an inactivity timeout restarts on it.",
        .zig_type = "zigulee.Window",
        .init = "undefined",
        .item = "root.item",
        .window = true,
        .props = &.{
            .{ .name = "background", .ty = .brush, .zig = "root.background" },
            .{ .name = "title", .ty = .string, .zig = "@title" },
            .{ .name = "fullscreen", .ty = .bool, .zig = "fullscreen" },
            .{ .name = "maximized", .ty = .bool, .zig = "maximized" },
            .{ .name = "minimized", .ty = .bool, .zig = "minimized" },
            .{ .name = "always-on-top", .ty = .bool, .zig = "always_on_top" },
            .{ .name = "safe-area-top", .ty = .length, .zig = "safe_area_top", .read_only = true },
            .{ .name = "safe-area-left", .ty = .length, .zig = "safe_area_left", .read_only = true },
            .{ .name = "safe-area-bottom", .ty = .length, .zig = "safe_area_bottom", .read_only = true },
            .{ .name = "safe-area-right", .ty = .length, .zig = "safe_area_right", .read_only = true },
            .{ .name = "keyboard-height", .ty = .length, .zig = "keyboard_height", .read_only = true },
        },
        .callbacks = &.{
            .{ .name = "input-activity", .zig = "input_activity" },
        },
    },
    .{ .name = "Empty", .doc = "An element that draws nothing: a container for positioning children.", .zig_type = "zigulee.items.Empty" },
    .{
        .name = "Rectangle",
        .doc = "A rectangle with an optional border and rounded corners. With `clip`, children are clipped to it (its corners rounded by `border-radius`, turned with it when rotated), and so is their input.",
        .zig_type = "zigulee.items.Rectangle",
        .props = &.{
            .{ .name = "background", .ty = .brush, .zig = "background" },
            .{ .name = "border-color", .ty = .brush, .zig = "border_color" },
            .{ .name = "border-width", .ty = .length, .zig = "border_width" },
            .{ .name = "border-radius", .ty = .length, .zig = "border_radius" },
            .{ .name = "clip", .ty = .bool, .zig = "clip" },
        },
    },
    .{
        .name = "Text",
        .doc = "A text. Without a `font-family`, it uses the window's default font. `wrap: word-wrap` breaks lines at the width. `letter-spacing` adds pixels after each character. With a `font-size-mode` other than `fixed`, the text is shown at the largest size up to `font-size` (down to `minimum-font-size`, 12px by default) that fits the element's width (`horizontal-fit`), height (`vertical-fit`) or both (`fit`).",
        .zig_type = "zigulee.items.Text",
        .props = &.{
            .{ .name = "text", .ty = .string, .zig = "text" },
            .{ .name = "color", .ty = .brush, .zig = "color" },
            .{ .name = "font-size", .ty = .length, .zig = "font_size" },
            .{ .name = "font-family", .ty = .string, .zig = "font_family" },
            .{ .name = "font-weight", .ty = .int, .zig = "font_weight" },
            .{ .name = "horizontal-alignment", .ty = .{ .enumeration = &text_horizontal_alignment }, .zig = "horizontal_alignment" },
            .{ .name = "vertical-alignment", .ty = .{ .enumeration = &text_vertical_alignment }, .zig = "vertical_alignment" },
            .{ .name = "wrap", .ty = .{ .enumeration = &text_wrap }, .zig = "wrap" },
            .{ .name = "overflow", .ty = .{ .enumeration = &text_overflow }, .zig = "overflow" },
            .{ .name = "letter-spacing", .ty = .length, .zig = "letter_spacing" },
            .{ .name = "font-size-mode", .ty = .{ .enumeration = &font_size_mode }, .zig = "font_size_mode" },
            .{ .name = "minimum-font-size", .ty = .length, .zig = "minimum_font_size" },
        },
    },
    .{
        .name = "StyledText",
        .doc = "Rich text: `text` in a Markdown subset, wrapped to the width and as tall as it needs (with `wrap: no-wrap`, lines break only where the text breaks them, cut at the edge). `horizontal-alignment` places each line across its width (tables stay at the left), `vertical-alignment` the text in its height. Inline: `**bold**`, `*italic*`, `~~struck~~`, `` `code` `` (on `code-background`, in `code-font-family`), `[links](url)` (in `link-color`; a click calls `link-clicked(url)`), `![images](url)`, `\\` before a mark to write it. Blocks: paragraphs (a blank line between them), `#` to `######` headings, `-` bullets and `1.` numbered items (nested by two spaces), tables (`| a | b |` rows, a `| --- | --- |` line under the header; their lines and header in `code-background`), a line ending in two spaces or `\\` breaks there. With `format: TextFormat.html`, an HTML subset instead: `p`, `div`, `br`, `h1` to `h6`, `ul`, `ol`, `li`, `b`, `strong`, `i`, `em`, `s`, `del`, `u`, `code`, `a href`, `img src` (`width`, `height`, `alt`), `table`, `tr`, `th`, `td`, entities; colors and fonts from `font` (`color`, `face`, `size`), `span`, `mark`, `big`, `small` and `style` attributes (`color`, `background-color`, `font-family`, `font-size`, `font-weight`, `font-style`, `text-decoration`). Blocks take `align` or `text-align` (`left`, `center`, `right`, `justify`) over `horizontal-alignment`, inherited from a `div` or `center` around them; table cells too (Markdown's columns by `:---:` and `---:` under the header). `style-sheet` is CSS for the text (rules for tags, `.classes`, `#ids`, before HTML's own `style` elements; Markdown styled as the HTML it stands for). Images floated (`align=left`, `float: right`) sit beside the text, the lines after them going round. Images load as Image's `source-url` (a path, `file://`, `http(s)://`; relative ones from `base-url`, as a page's address: a directory ends with `/`) in the background, wrapping as words, no wider than a line; their `alt` text shows if they cannot be loaded. Bold is the family's weight 700; italics are slanted. `letter-spacing` adds pixels after each character; with a `font-size-mode` other than `fixed`, it is shown at the largest size up to `font-size` (down to `minimum-font-size`, headings, lists and tables with it) that fits, as Text's. With `selectable`, dragging over it selects text (`selected-text`, on `selection-color`; a double click selects a word, a triple click a paragraph), and Ctrl+C (Cmd+C) or `copy()` copies it; Ctrl+A or `select-all()` selects all.",
        .zig_type = "zigulee.items.StyledText",
        .init_call = "init(gpa)",
        .children = false,
        .props = &.{
            .{ .name = "text", .ty = .string, .zig = "text" },
            .{ .name = "color", .ty = .brush, .zig = "color" },
            .{ .name = "link-color", .ty = .brush, .zig = "link_color" },
            .{ .name = "code-background", .ty = .brush, .zig = "code_background" },
            .{ .name = "font-size", .ty = .length, .zig = "font_size" },
            .{ .name = "font-family", .ty = .string, .zig = "font_family" },
            .{ .name = "font-weight", .ty = .int, .zig = "font_weight" },
            .{ .name = "code-font-family", .ty = .string, .zig = "code_font_family" },
            .{ .name = "base-url", .ty = .string, .zig = "base_url" },
            .{ .name = "style-sheet", .ty = .string, .zig = "style_sheet" },
            .{ .name = "letter-spacing", .ty = .length, .zig = "letter_spacing" },
            .{ .name = "font-size-mode", .ty = .{ .enumeration = &font_size_mode }, .zig = "font_size_mode" },
            .{ .name = "minimum-font-size", .ty = .length, .zig = "minimum_font_size" },
            .{ .name = "wrap", .ty = .{ .enumeration = &text_wrap }, .zig = "wrap" },
            .{ .name = "horizontal-alignment", .ty = .{ .enumeration = &text_horizontal_alignment }, .zig = "horizontal_alignment" },
            .{ .name = "vertical-alignment", .ty = .{ .enumeration = &text_vertical_alignment }, .zig = "vertical_alignment" },
            .{ .name = "format", .ty = .{ .enumeration = &text_format }, .zig = "format" },
            .{ .name = "selectable", .ty = .bool, .zig = "selectable" },
            .{ .name = "selection-color", .ty = .brush, .zig = "selection_color" },
            .{ .name = "selected-text", .ty = .string, .zig = "selected_text", .read_only = true },
        },
        .callbacks = &.{
            .{ .name = "link-clicked", .zig = "link_clicked", .params = &.{.string} },
        },
        .functions = &.{
            .{ .name = "copy", .zig = "copy" },
            .{ .name = "select-all", .zig = "selectAll" },
        },
    },
    .{
        .name = "StackLayout",
        .doc = "Shows one of its children: the one at `current-index` (the others are hidden: their visibility is the layout's), each filling it. It takes the largest of their sizes. `count` is how many there are.",
        .zig_type = "zigulee.items.StackLayout",
        .layout = true,
        .props = &.{
            .{ .name = "current-index", .ty = .int, .zig = "current_index" },
            .{ .name = "count", .ty = .int, .zig = "count", .read_only = true },
        },
    },
    .{
        .name = "SwipeView",
        .doc = "Its children side by side, each filling it, one shown: `current-index`; with `orientation: Orientation.vertical`, one above the other. A drag along them (mouse or finger) moves between them, settling on the nearest one (or the next, dragged a fifth of the way); setting `current-index` slides there. `count` is how many there are, `position` where it is (in pages). With `interactive: false`, only `current-index` moves it.",
        .zig_type = "zigulee.items.SwipeView",
        .init_call = "init(gpa)",
        .layout = true,
        .props = &.{
            .{ .name = "current-index", .ty = .int, .zig = "current_index" },
            .{ .name = "count", .ty = .int, .zig = "count", .read_only = true },
            .{ .name = "interactive", .ty = .bool, .zig = "interactive" },
            .{ .name = "position", .ty = .float, .zig = "position", .read_only = true },
            .{ .name = "orientation", .ty = .{ .enumeration = &orientation }, .zig = "orientation" },
        },
    },
    .{
        .name = "TreeState",
        .doc = "Which rows of a tree show: the rows in order, with their depths (`levels`: 0 for the top ones, a child's one more than its parent's, right after it). `shown` is the rows shown (their indices: those whose parents are all expanded), `expanded` and `has-children` say it by row. `toggle(row)`, `expand(row)`, `collapse(row)`, `expand-all()`, `collapse-all()`; new rows start expanded if `initially-expanded`. std-widgets.zge's TreeView is made with it. Not drawn.",
        .zig_type = "zigulee.items.TreeState",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &.{
            .{ .name = "levels", .ty = .{ .model = &rows.int }, .zig = "levels" },
            .{ .name = "initially-expanded", .ty = .bool, .zig = "initially_expanded" },
            .{ .name = "shown", .ty = .{ .model = &rows.int }, .zig = "shown", .read_only = true },
            .{ .name = "expanded", .ty = .{ .model = &rows.bool }, .zig = "expanded", .read_only = true },
            .{ .name = "has-children", .ty = .{ .model = &rows.bool }, .zig = "has_children", .read_only = true },
        },
        .functions = &.{
            .{ .name = "toggle", .zig = "toggle", .params = &.{.int} },
            .{ .name = "expand", .zig = "expand", .params = &.{.int} },
            .{ .name = "collapse", .zig = "collapse", .params = &.{.int} },
            .{ .name = "expand-all", .zig = "expandAll" },
            .{ .name = "collapse-all", .zig = "collapseAll" },
        },
    },
    .{
        .name = "Selection",
        .doc = "Which of `count` rows are selected, for views that let the user pick several: `selected` says it by row, `selected-rows` lists them. `select(row)` selects only that row (-1: none), `toggle(row)` adds or removes it, `extend-to(row)` selects the rows from the last one selected or toggled to `row` (Shift-click), in the order of `order` (the rows as shown, when not 0, 1, 2...); `set-selected(row, on)`, `select-all()`, `clear()`. `changed` is called when the selection changes. std-widgets.zge's StandardListView, StandardTableView and TreeView are made with it; use it in a ListView, TableView or GridView of your own rows. Not drawn.",
        .zig_type = "zigulee.items.Selection",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &.{
            .{ .name = "count", .ty = .int, .zig = "count" },
            .{ .name = "order", .ty = .{ .model = &rows.int }, .zig = "order" },
            .{ .name = "selected", .ty = .{ .model = &rows.bool }, .zig = "selected", .read_only = true },
            .{ .name = "selected-rows", .ty = .{ .model = &rows.int }, .zig = "selected_rows", .read_only = true },
        },
        .callbacks = &.{
            .{ .name = "changed", .zig = "changed" },
        },
        .functions = &.{
            .{ .name = "select", .zig = "select", .params = &.{.int} },
            .{ .name = "toggle", .zig = "toggle", .params = &.{.int} },
            .{ .name = "extend-to", .zig = "extendTo", .params = &.{.int} },
            .{ .name = "set-selected", .zig = "setSelected", .params = &.{ .int, .bool } },
            .{ .name = "select-all", .zig = "selectAll" },
            .{ .name = "clear", .zig = "clear" },
        },
    },
    .{
        .name = "FlowLayout",
        .doc = "Its children at their preferred sizes, left to right, wrapping to the next row where they do not fit; rows and children `spacing` apart, `padding` inside. Its height is what the rows take at its width.",
        .zig_type = "zigulee.items.FlowLayout",
        .layout = true,
        .props = &.{
            .{ .name = "spacing", .ty = .length, .zig = "spacing" },
            .{ .name = "padding", .ty = .length, .zig = "padding" },
        },
    },
    .{
        .name = "ListLayout",
        .doc = "The rows of the `for` in it, one under another, `spacing` apart, all as tall as `row-height` (0: the first row's preferred height) and as wide as it; with `variable-row-height`, each as tall as it prefers (rows not yet shown estimated at the mean of those that were). Only the rows within `visible-height` of `viewport-y` (a Flickable's) have instances, handed on to the rows coming into view as it scrolls (an instance's own state goes with it); without a `visible-height`, all rows. `sections` names each row's section: one starts where the name changes, under a `section-height` gap for its header; `section-names` and `section-ys` are the headers, `current-section` the section at the top of the view and `current-section-offset` where to pin its header (pushed up by the next). `column-widths` and `column-count` are the columns of its `TableRow`s. std-widgets.zge's ListView and TableView are made with it.",
        .zig_type = "zigulee.items.ListLayout",
        .init_call = "init(gpa)",
        .layout = true,
        .props = &.{
            .{ .name = "viewport-y", .ty = .length, .zig = "viewport_y" },
            .{ .name = "visible-height", .ty = .length, .zig = "visible_height" },
            .{ .name = "row-height", .ty = .length, .zig = "row_height" },
            .{ .name = "variable-row-height", .ty = .bool, .zig = "variable_row_height" },
            .{ .name = "spacing", .ty = .length, .zig = "spacing" },
            .{ .name = "sections", .ty = .{ .model = &rows.string }, .zig = "sections" },
            .{ .name = "section-height", .ty = .length, .zig = "section_height" },
            .{ .name = "column-widths", .ty = .{ .model = &rows.length }, .zig = "column_widths" },
            .{ .name = "column-count", .ty = .int, .zig = "column_count" },
            .{ .name = "row-count", .ty = .int, .zig = "row_count", .read_only = true },
            .{ .name = "current-section", .ty = .string, .zig = "current_section", .read_only = true },
            .{ .name = "current-section-offset", .ty = .length, .zig = "current_section_offset", .read_only = true },
            .{ .name = "section-names", .ty = .{ .model = &rows.string }, .zig = "section_names", .read_only = true },
            .{ .name = "section-ys", .ty = .{ .model = &rows.length }, .zig = "section_ys", .read_only = true },
        },
    },
    .{
        .name = "TableRow",
        .doc = "A row of a table (the body of a `for` in a ListLayout, or a TableView): its children are its cells, one per column of the list, in order, as tall as the row. Its preferred height is its tallest cell's.",
        .zig_type = "zigulee.items.TableRow",
        .layout = true,
    },
    .{
        .name = "SplitView",
        .doc = "Its children (panes) side by side, or one above the other with `vertical`, with a handle between each two that the pointer drags to share the room (each pane stays within its minimum and maximum size). At first they share it by their preferred sizes. `handle-width` is the room a handle takes, `handle-color` its line.",
        .zig_type = "zigulee.items.SplitView",
        .layout = true,
        .props = &.{
            .{ .name = "vertical", .ty = .bool, .zig = "vertical" },
            .{ .name = "handle-width", .ty = .length, .zig = "handle_width" },
            .{ .name = "handle-color", .ty = .brush, .zig = "handle_color" },
        },
    },
    .{
        .name = "StackView",
        .doc = "Pages on top of each other: `push(Page)` (a component) shows one on top, sliding in from the right; `pop()` takes it off, sliding out; `clear()` goes back to the first. `initial-page` is the first one; one always stays. `depth` is how many there are, `busy` whether one is sliding.",
        .zig_type = "zigulee.items.StackView",
        .init_call = "init(gpa)",
        .children = false,
        .props = &.{
            .{ .name = "initial-page", .ty = .component, .zig = "initial_page" },
            .{ .name = "depth", .ty = .int, .zig = "depth", .read_only = true },
            .{ .name = "busy", .ty = .bool, .zig = "busy", .read_only = true },
        },
        .functions = &.{
            .{ .name = "push", .zig = "push", .params = &.{.component} },
            .{ .name = "pop", .zig = "pop" },
            .{ .name = "clear", .zig = "clear" },
        },
    },
    .{
        .name = "Shortcut",
        .doc = "Keys that run something wherever the focus is: `activated` when `sequence` (\"Ctrl+S\", \"Ctrl+Shift+Z\", \"Alt+Left\", \"Escape\") is pressed and the focused element does not take it (Ctrl+C in a text field copies there). `Ctrl` is Command on macOS. Application-wide, while `enabled`. Menu bar items' shortcuts are made with it. Not drawn.",
        .zig_type = "zigulee.items.Shortcut",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &.{
            .{ .name = "sequence", .ty = .string, .zig = "sequence" },
            .{ .name = "enabled", .ty = .bool, .zig = "enabled" },
        },
        .callbacks = &.{.{ .name = "activated", .zig = "activated" }},
    },
    .{
        .name = "PinchArea",
        .doc = "Scaled and turned by two fingers (or a trackpad's pinch and rotation): while `active`, `pinch-scale` (1 at the start) and `pinch-rotation` (degrees, clockwise) follow the gesture, about `center-x`, `center-y`; `started`, `updated` and `finished` mark it. One finger still works as the mouse in it. Draws nothing.",
        .zig_type = "zigulee.items.PinchArea",
        .props = &.{
            .{ .name = "enabled", .ty = .bool, .zig = "enabled" },
            .{ .name = "active", .ty = .bool, .zig = "active", .read_only = true },
            .{ .name = "pinch-scale", .ty = .float, .zig = "scale", .read_only = true },
            .{ .name = "pinch-rotation", .ty = .float, .zig = "rotation", .read_only = true },
            .{ .name = "center-x", .ty = .length, .zig = "center_x", .read_only = true },
            .{ .name = "center-y", .ty = .length, .zig = "center_y", .read_only = true },
        },
        .callbacks = &.{
            .{ .name = "started", .zig = "started" },
            .{ .name = "updated", .zig = "updated" },
            .{ .name = "finished", .zig = "finished" },
        },
    },
    .{
        .name = "SwipeArea",
        .doc = "Reports a quick drag over it (the mouse or a finger): `swiped(direction)` once it went `distance` (40 px) mostly one way (`SwipeDirection.left`, `right`, `up`, `down`). While dragging, `swiping` and `offset-x`, `offset-y` follow it. A press that does not move goes to what is in it. Draws nothing.",
        .zig_type = "zigulee.items.SwipeArea",
        .props = &.{
            .{ .name = "enabled", .ty = .bool, .zig = "enabled" },
            .{ .name = "distance", .ty = .length, .zig = "distance" },
            .{ .name = "swiping", .ty = .bool, .zig = "swiping", .read_only = true },
            .{ .name = "offset-x", .ty = .length, .zig = "offset_x", .read_only = true },
            .{ .name = "offset-y", .ty = .length, .zig = "offset_y", .read_only = true },
        },
        .callbacks = &.{
            .{ .name = "swiped", .zig = "swiped", .params = &.{.{ .enumeration = &swipe_direction }} },
        },
    },
    .{
        .name = "DragArea",
        .doc = "Dragged by the pointer: a press moved past a few pixels starts dragging its `kind` and `data` (strings) to a DropArea that `accepts` the kind. It draws nothing: bind what shows the drag to `dragging` and `offset-x`, `offset-y` (the pointer since the press). `started` at the start, `finished(dropped)` at the end (`true` if dropped on a DropArea); `clicked` for a press released without dragging. Escape cancels.",
        .zig_type = "zigulee.items.DragArea",
        .props = &.{
            .{ .name = "enabled", .ty = .bool, .zig = "enabled" },
            .{ .name = "kind", .ty = .string, .zig = "kind" },
            .{ .name = "data", .ty = .string, .zig = "data" },
            .{ .name = "dragging", .ty = .bool, .zig = "dragging", .read_only = true },
            .{ .name = "offset-x", .ty = .length, .zig = "offset_x", .read_only = true },
            .{ .name = "offset-y", .ty = .length, .zig = "offset_y", .read_only = true },
        },
        .callbacks = &.{
            .{ .name = "started", .zig = "started" },
            .{ .name = "finished", .zig = "finished", .params = &.{.bool} },
            .{ .name = "clicked", .zig = "clicked" },
        },
    },
    .{
        .name = "DropArea",
        .doc = "Takes what a DragArea drops on it, of the kind it `accepts` (\"\": any): `contains-drag` while one is over it (its `drag-kind`, `drag-data`, and the pointer at `drag-x`, `drag-y`), `entered` and `exited`, then `dropped(data)`. The topmost one under the pointer takes it.",
        .zig_type = "zigulee.items.DropArea",
        .props = &.{
            .{ .name = "enabled", .ty = .bool, .zig = "enabled" },
            .{ .name = "accepts", .ty = .string, .zig = "accepts" },
            .{ .name = "contains-drag", .ty = .bool, .zig = "contains_drag", .read_only = true },
            .{ .name = "drag-kind", .ty = .string, .zig = "drag_kind", .read_only = true },
            .{ .name = "drag-data", .ty = .string, .zig = "drag_data", .read_only = true },
            .{ .name = "drag-x", .ty = .length, .zig = "drag_x", .read_only = true },
            .{ .name = "drag-y", .ty = .length, .zig = "drag_y", .read_only = true },
        },
        .callbacks = &.{
            .{ .name = "entered", .zig = "entered" },
            .{ .name = "exited", .zig = "exited" },
            .{ .name = "dropped", .zig = "dropped", .params = &.{.string} },
        },
    },
    .{
        .name = "TouchArea",
        .doc = "Reports pointer input in its area: `clicked` after a press and release inside it, `moved` while the pointer moves over it or is pressed, `right-clicked` after the right button (to open a context menu). A second click within `double-click-interval` (400 ms) of the first, close to it, calls `double-clicked` instead of `clicked` when that has a handler (as Qt's MouseArea). `pointer-event(event)` tells every press and release of any button (`event.kind`: `PointerEventKind.down`, `up`), move over it or while pressed (`move`), and a press taken away by another element dragging (`cancel`), with `event.button` (`PointerEventButton.left`, `right`, `middle`, `other`) and `event.modifiers`. `modifiers` are the keys held at the press (`modifiers.shift` for a Shift-click).",
        .zig_type = "zigulee.items.TouchArea",
        .props = &.{
            .{ .name = "enabled", .ty = .bool, .zig = "enabled" },
            .{ .name = "mouse-cursor", .ty = .{ .enumeration = &mouse_cursor }, .zig = "mouse_cursor" },
            .{ .name = "pressed", .ty = .bool, .zig = "pressed", .read_only = true },
            .{ .name = "has-hover", .ty = .bool, .zig = "has_hover", .read_only = true },
            .{ .name = "mouse-x", .ty = .length, .zig = "mouse_x", .read_only = true },
            .{ .name = "mouse-y", .ty = .length, .zig = "mouse_y", .read_only = true },
            .{ .name = "pressed-x", .ty = .length, .zig = "pressed_x", .read_only = true },
            .{ .name = "pressed-y", .ty = .length, .zig = "pressed_y", .read_only = true },
            .{ .name = "modifiers", .ty = .modifiers, .zig = "modifiers", .read_only = true },
            .{ .name = "double-click-interval", .ty = .duration, .zig = "double_click_interval_ms" },
        },
        .callbacks = &.{
            .{ .name = "clicked", .zig = "clicked" },
            .{ .name = "double-clicked", .zig = "double_clicked" },
            .{ .name = "moved", .zig = "moved" },
            .{ .name = "right-clicked", .zig = "right_clicked" },
            .{ .name = "pointer-event", .zig = "pointer_event", .params = &.{.pointer_event} },
        },
    },
    .{
        .name = "FocusScope",
        .doc = "Receives key events when it has the keyboard focus. Handlers return `accept` or `reject`; rejected keys go to the parent scopes.",
        .zig_type = "zigulee.items.FocusScope",
        .props = &.{
            .{ .name = "enabled", .ty = .bool, .zig = "enabled" },
            .{ .name = "has-focus", .ty = .bool, .zig = "has_focus", .read_only = true },
        },
        .callbacks = &.{
            .{ .name = "key-pressed", .zig = "key_pressed", .params = &.{.key_event}, .ret = .{ .enumeration = &event_result } },
            .{ .name = "key-released", .zig = "key_released", .params = &.{.key_event}, .ret = .{ .enumeration = &event_result } },
            .{ .name = "focus-changed", .zig = "focus_changed", .params = &.{.bool} },
        },
        .functions = &.{.{ .name = "focus", .zig = "focus" }},
    },
    .{
        .name = "Image",
        .doc = "Shows an image, usually `@image-url(\"file.png\")` (embedded at build time; PNG, GIF or SVG, an SVG drawn sharp at any size), or one loaded while the program runs from `source-url`: a file's path (or a `file://` URL) or an `http://` or `https://` URL, loaded in the background (with `source-headers`, each `Name: value`), `status` going from `loading` to `ready` (or `error`) and `progress` from 0 to 1 as it comes; Images showing the same URL share one load and one image, kept a while after they all go. `colorize` paints its shape in one color.",
        .zig_type = "zigulee.items.Image",
        .init_call = "init(gpa)",
        .children = false,
        .props = &.{
            .{ .name = "source", .ty = .image, .zig = "source", .optional = true },
            .{ .name = "source-url", .ty = .string, .zig = "source_url" },
            .{ .name = "source-headers", .ty = .{ .model = &rows.string }, .zig = "source_headers" },
            .{ .name = "progress", .ty = .float, .zig = "progress", .read_only = true },
            .{ .name = "status", .ty = .{ .enumeration = &image_status }, .zig = "status", .read_only = true },
            .{ .name = "image-fit", .ty = .{ .enumeration = &image_fit }, .zig = "image_fit" },
            .{ .name = "image-rendering", .ty = .{ .enumeration = &image_rendering }, .zig = "image_rendering" },
            .{ .name = "colorize", .ty = .brush, .zig = "colorize", .optional = true },
        },
    },
    .{
        .name = "Path",
        .doc = "Draws SVG path data (`commands`), scaled to the element's size, filled and/or stroked.",
        .zig_type = "zigulee.items.Path",
        .children = false,
        .props = &.{
            .{ .name = "commands", .ty = .string, .zig = "commands" },
            .{ .name = "fill", .ty = .brush, .zig = "fill" },
            .{ .name = "stroke", .ty = .brush, .zig = "stroke" },
            .{ .name = "stroke-width", .ty = .length, .zig = "stroke_width" },
        },
    },
    .{
        .name = "TextInput",
        .doc = "Editable text, without decoration (the LineEdit and TextEdit widgets add it): selection with mouse and keyboard, undo and redo, the clipboard and input methods.",
        .zig_type = "zigulee.items.TextInput",
        .init_call = "init(gpa)",
        .children = false,
        .props = &.{
            .{ .name = "text", .ty = .string, .zig = "text" },
            .{ .name = "color", .ty = .brush, .zig = "color" },
            .{ .name = "font-size", .ty = .length, .zig = "font_size" },
            .{ .name = "letter-spacing", .ty = .length, .zig = "letter_spacing" },
            .{ .name = "font-family", .ty = .string, .zig = "font_family" },
            .{ .name = "font-weight", .ty = .int, .zig = "font_weight" },
            .{ .name = "enabled", .ty = .bool, .zig = "enabled" },
            .{ .name = "has-focus", .ty = .bool, .zig = "has_focus", .read_only = true },
            .{ .name = "read-only", .ty = .bool, .zig = "read_only" },
            .{ .name = "input-type", .ty = .{ .enumeration = &input_type }, .zig = "input_type" },
            .{ .name = "single-line", .ty = .bool, .zig = "single_line" },
            .{ .name = "wrap", .ty = .{ .enumeration = &text_wrap }, .zig = "wrap" },
            .{ .name = "horizontal-alignment", .ty = .{ .enumeration = &text_horizontal_alignment }, .zig = "horizontal_alignment" },
            .{ .name = "cursor-position", .ty = .int, .zig = "cursor_position" },
            .{ .name = "anchor-position", .ty = .int, .zig = "anchor_position" },
            .{ .name = "selection-background-color", .ty = .brush, .zig = "selection_background_color" },
        },
        .callbacks = &.{
            .{ .name = "edited", .zig = "edited" },
            .{ .name = "accepted", .zig = "accepted" },
        },
        .functions = &.{
            .{ .name = "focus", .zig = "focus" },
            .{ .name = "select-all", .zig = "selectAll" },
            .{ .name = "clear-selection", .zig = "clearSelection" },
            .{ .name = "copy", .zig = "copy" },
            .{ .name = "cut", .zig = "cut" },
            .{ .name = "paste", .zig = "paste" },
            .{ .name = "undo", .zig = "undo" },
            .{ .name = "redo", .zig = "redo" },
        },
    },
    .{
        .name = "Flickable",
        .doc = "Scrolls its children (the viewport) by dragging or the mouse wheel. Taps still reach the children. With `snap-y`, scrolling settles on multiples of it, and the wheel moves by one.",
        .zig_type = "zigulee.items.Flickable",
        .init_call = "init(gpa)",
        .content = "viewport.item",
        .props = &.{
            .{ .name = "viewport-x", .ty = .length, .zig = "viewport.item.x" },
            .{ .name = "viewport-y", .ty = .length, .zig = "viewport.item.y" },
            .{ .name = "viewport-width", .ty = .length, .zig = "viewport.item.width" },
            .{ .name = "viewport-height", .ty = .length, .zig = "viewport.item.height" },
            .{ .name = "interactive", .ty = .bool, .zig = "interactive" },
            .{ .name = "snap-y", .ty = .length, .zig = "snap_y" },
        },
        .callbacks = &.{.{ .name = "flicked", .zig = "flicked" }},
    },
    .{
        .name = "Timer",
        .doc = "Calls `triggered` every `interval` while `running`. `start()` and `stop()` set and clear `running`; `restart()` runs it from now, the next `triggered` a whole `interval` away. Not drawn.",
        .zig_type = "zigulee.items.TimerElement",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &.{
            .{ .name = "interval", .ty = .duration, .zig = "interval_ms" },
            .{ .name = "running", .ty = .bool, .zig = "running" },
        },
        .callbacks = &.{.{ .name = "triggered", .zig = "triggered" }},
        .functions = &.{
            .{ .name = "start", .zig = "start" },
            .{ .name = "stop", .zig = "stop" },
            .{ .name = "restart", .zig = "restart" },
        },
    },
    .{
        .name = "Audio",
        .doc = "Plays `source` while `playing`: set it, or call `play()` and `stop()`. `play()` starts the sound again from the start; with `voices` above 1 it plays over the voices still playing, up to that many (the oldest is cut). Voices rise over `fade-in` and, when stopped, fall over `fade-out`; a new `source` fades in while the old one fades out. `position` follows playback, and setting it seeks. `finished` is called when playback ends by itself (never while `loop`ing). Silent where the platform has no audio output. Not drawn.",
        .zig_type = "zigulee.items.AudioElement",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &.{
            .{ .name = "source", .ty = .audio, .zig = "source" },
            .{ .name = "playing", .ty = .bool, .zig = "playing" },
            .{ .name = "paused", .ty = .bool, .zig = "paused" },
            .{ .name = "loop", .ty = .bool, .zig = "loop" },
            .{ .name = "volume", .ty = .float, .zig = "volume" },
            .{ .name = "pan", .ty = .float, .zig = "pan" },
            .{ .name = "speed", .ty = .float, .zig = "speed" },
            .{ .name = "voices", .ty = .int, .zig = "voices" },
            .{ .name = "fade-in", .ty = .duration, .zig = "fade_in_ms" },
            .{ .name = "fade-out", .ty = .duration, .zig = "fade_out_ms" },
            .{ .name = "position", .ty = .duration, .zig = "position_ms" },
            .{ .name = "duration", .ty = .duration, .zig = "duration_ms", .read_only = true },
        },
        .callbacks = &.{.{ .name = "finished", .zig = "finished" }},
        .functions = &.{
            .{ .name = "play", .zig = "play" },
            .{ .name = "stop", .zig = "stop" },
        },
    },
    .{
        .name = "Video",
        .doc = "Plays a video and shows it like an `Image` (`image-fit`; the video's size is its preferred size): `source` is embedded at build time (`@video-url(\"intro.png\")`), `source-file` is a file read while playing (and wins when set). Animated PNG plays everywhere; other formats (MP4, ...) where the platform decodes them. It shows the first frame until `playing` is set (or `play()` is called); `stop()` goes back to the start. `position` follows playback, and setting it seeks; `finished` is called when playback ends by itself, keeping the last frame. The soundtrack plays through the mixer at `volume`.",
        .zig_type = "zigulee.items.VideoElement",
        .item = "image.item",
        .init_call = "init(gpa)",
        .children = false,
        .props = &.{
            .{ .name = "source", .ty = .video, .zig = "source" },
            .{ .name = "source-file", .ty = .string, .zig = "source_file" },
            .{ .name = "playing", .ty = .bool, .zig = "playing" },
            .{ .name = "paused", .ty = .bool, .zig = "paused" },
            .{ .name = "loop", .ty = .bool, .zig = "loop" },
            .{ .name = "volume", .ty = .float, .zig = "volume" },
            .{ .name = "position", .ty = .duration, .zig = "position_ms" },
            .{ .name = "duration", .ty = .duration, .zig = "duration_ms", .read_only = true },
            .{ .name = "image-fit", .ty = .{ .enumeration = &image_fit }, .zig = "image.image_fit" },
            .{ .name = "image-rendering", .ty = .{ .enumeration = &image_rendering }, .zig = "image.image_rendering" },
        },
        .callbacks = &.{.{ .name = "finished", .zig = "finished" }},
        .functions = &.{
            .{ .name = "play", .zig = "play" },
            .{ .name = "stop", .zig = "stop" },
        },
    },
    .{
        .name = "View3D",
        .doc = "A 3D scene: its `Node`, `Model`, `PerspectiveCamera`, `DirectionalLight` and `PointLight` children, drawn over `background` (transparent by default) with `ambient` light everywhere, times `ambient-brightness` (1 by default). Y points up and the camera looks along -z. Without a camera it is seen from 4 units in front of the middle; without lights, lit from the upper left. Drawn on the CPU into an image (twice the element's size, smoothed), kept while the scene is the same: suited to small scenes. Other children are drawn over it as usual.",
        .zig_type = "zigulee.items.View3D",
        .init_call = "init(gpa)",
        .props = &.{
            .{ .name = "background", .ty = .color, .zig = "background" },
            .{ .name = "ambient", .ty = .color, .zig = "ambient" },
            .{ .name = "ambient-brightness", .ty = .float, .zig = "ambient_brightness" },
        },
    },
    .{
        .name = "Model",
        .doc = "A shape in a `View3D`: a `mesh` (`cube`, `sphere` or `plane`, each 1 unit across, centered; the plane facing +z), sized by `size-x`, `size-y` and `size-z`, at `position-x`, `position-y` and `position-z`, turned by `yaw` (about y), then `pitch` (about x), then `roll` (about z), in degrees. Its material: `color`, multiplied by `texture` if set, `metallic` (0 to 1) and `roughness` (0 shiny to 1 matte, 0.5 by default). With a `source` (`@model-url(\"ship.glb\")`, a glTF 2.0 binary file embedded at build time), it shows that model's meshes, sized and placed the same way, in the model's own materials tinted by `color`. A click on it (the nearest model under the pointer) calls `clicked`. Nodes inside a model move and turn with it (not sized with it).",
        .zig_type = "zigulee.items.SceneModel",
        .init_call = "init(gpa)",
        .props = &.{
            .{ .name = "position-x", .ty = .float, .zig = "placement.position_x" },
            .{ .name = "position-y", .ty = .float, .zig = "placement.position_y" },
            .{ .name = "position-z", .ty = .float, .zig = "placement.position_z" },
            .{ .name = "pitch", .ty = .float, .zig = "placement.pitch" },
            .{ .name = "yaw", .ty = .float, .zig = "placement.yaw" },
            .{ .name = "roll", .ty = .float, .zig = "placement.roll" },
            .{ .name = "mesh", .ty = .{ .enumeration = &mesh }, .zig = "mesh" },
            .{ .name = "source", .ty = .model3d, .zig = "source" },
            .{ .name = "size-x", .ty = .float, .zig = "size_x" },
            .{ .name = "size-y", .ty = .float, .zig = "size_y" },
            .{ .name = "size-z", .ty = .float, .zig = "size_z" },
            .{ .name = "color", .ty = .color, .zig = "color" },
            .{ .name = "metallic", .ty = .float, .zig = "metallic" },
            .{ .name = "roughness", .ty = .float, .zig = "roughness" },
            .{ .name = "texture", .ty = .image, .zig = "texture", .optional = true },
        },
        .callbacks = &.{.{ .name = "clicked", .zig = "clicked" }},
    },
    .{
        .name = "Node",
        .doc = "A group in a `View3D`, drawing nothing: the nodes inside it (models, cameras, lights, other nodes) move and turn with it. At `position-x`, `position-y` and `position-z`, turned by `yaw`, `pitch` and `roll` (degrees). A camera inside a turning node goes round what it looks at.",
        .zig_type = "zigulee.items.SceneNode",
        .props = &.{
            .{ .name = "position-x", .ty = .float, .zig = "placement.position_x" },
            .{ .name = "position-y", .ty = .float, .zig = "placement.position_y" },
            .{ .name = "position-z", .ty = .float, .zig = "placement.position_z" },
            .{ .name = "pitch", .ty = .float, .zig = "placement.pitch" },
            .{ .name = "yaw", .ty = .float, .zig = "placement.yaw" },
            .{ .name = "roll", .ty = .float, .zig = "placement.roll" },
        },
    },
    .{
        .name = "PerspectiveCamera",
        .doc = "Where a `View3D` is seen from: at `position-x`, `position-y` and `position-z` (0, 0, 4 by default), looking along its -z axis turned by `yaw`, `pitch` and `roll`, with a vertical `field-of-view` in degrees (45 by default). The first camera counts.",
        .zig_type = "zigulee.items.PerspectiveCamera",
        .children = false,
        .props = &.{
            .{ .name = "position-x", .ty = .float, .zig = "placement.position_x" },
            .{ .name = "position-y", .ty = .float, .zig = "placement.position_y" },
            .{ .name = "position-z", .ty = .float, .zig = "placement.position_z" },
            .{ .name = "pitch", .ty = .float, .zig = "placement.pitch" },
            .{ .name = "yaw", .ty = .float, .zig = "placement.yaw" },
            .{ .name = "roll", .ty = .float, .zig = "placement.roll" },
            .{ .name = "field-of-view", .ty = .float, .zig = "field_of_view" },
        },
    },
    .{
        .name = "DirectionalLight",
        .doc = "Light from far away in a `View3D`, as from the sun: shining along its -z axis turned by `yaw` and `pitch` (by default, away from the default camera), in `color`, times `brightness` (1 by default).",
        .zig_type = "zigulee.items.DirectionalLight",
        .children = false,
        .props = &.{
            .{ .name = "position-x", .ty = .float, .zig = "placement.position_x" },
            .{ .name = "position-y", .ty = .float, .zig = "placement.position_y" },
            .{ .name = "position-z", .ty = .float, .zig = "placement.position_z" },
            .{ .name = "pitch", .ty = .float, .zig = "placement.pitch" },
            .{ .name = "yaw", .ty = .float, .zig = "placement.yaw" },
            .{ .name = "roll", .ty = .float, .zig = "placement.roll" },
            .{ .name = "color", .ty = .color, .zig = "color" },
            .{ .name = "brightness", .ty = .float, .zig = "brightness" },
        },
    },
    .{
        .name = "PointLight",
        .doc = "Light from a point in a `View3D`, as from a bulb: at `position-x`, `position-y` and `position-z`, in `color`, times `brightness` (1 by default), half as bright `range` units away (10 by default).",
        .zig_type = "zigulee.items.PointLight",
        .children = false,
        .props = &.{
            .{ .name = "position-x", .ty = .float, .zig = "placement.position_x" },
            .{ .name = "position-y", .ty = .float, .zig = "placement.position_y" },
            .{ .name = "position-z", .ty = .float, .zig = "placement.position_z" },
            .{ .name = "pitch", .ty = .float, .zig = "placement.pitch" },
            .{ .name = "yaw", .ty = .float, .zig = "placement.yaw" },
            .{ .name = "roll", .ty = .float, .zig = "placement.roll" },
            .{ .name = "color", .ty = .color, .zig = "color" },
            .{ .name = "brightness", .ty = .float, .zig = "brightness" },
            .{ .name = "range", .ty = .float, .zig = "range" },
        },
    },
    .{
        .name = "WebView",
        .doc = "A web page: `url` loads (and follows the page's links and redirects), or `html` shows that text (and wins when set). `title`, `loading`, `can-go-back` and `can-go-forward` follow the page; `back()`, `forward()`, `reload()` and `stop()` act on it; `finished` is called when a page has loaded, `failed` when it could not (`error` says why). `run-javascript(code)` runs code in the page: `javascript-finished(result)` then, as text, or `javascript-failed(error)`. A native view placed over the element: it shows above everything (popups too), without rotation, opacity or effects, and is not clipped by scroll views. `available` tells whether the platform has web views: macOS and Windows (native and SDL3 backends; Windows needs the WebView2 runtime), Linux with X11 (native and SDL3 backends, with WebKitGTK installed), iOS and the web (an `<iframe>`, where other sites cannot be scripted or navigated); not on Wayland or KMS.",
        .zig_type = "zigulee.items.WebView",
        .init_call = "init(gpa)",
        .children = false,
        .props = &.{
            .{ .name = "url", .ty = .string, .zig = "url" },
            .{ .name = "html", .ty = .string, .zig = "html" },
            .{ .name = "title", .ty = .string, .zig = "title", .read_only = true },
            .{ .name = "loading", .ty = .bool, .zig = "loading", .read_only = true },
            .{ .name = "can-go-back", .ty = .bool, .zig = "can_go_back", .read_only = true },
            .{ .name = "can-go-forward", .ty = .bool, .zig = "can_go_forward", .read_only = true },
            .{ .name = "error", .ty = .string, .zig = "error_text", .read_only = true },
            .{ .name = "available", .ty = .bool, .zig = "available", .read_only = true },
        },
        .callbacks = &.{
            .{ .name = "finished", .zig = "finished" },
            .{ .name = "failed", .zig = "failed" },
            .{ .name = "javascript-finished", .zig = "javascript_finished", .params = &.{.string} },
            .{ .name = "javascript-failed", .zig = "javascript_failed", .params = &.{.string} },
        },
        .functions = &.{
            .{ .name = "back", .zig = "back" },
            .{ .name = "forward", .zig = "forward" },
            .{ .name = "reload", .zig = "reload" },
            .{ .name = "stop", .zig = "stop" },
            .{ .name = "run-javascript", .zig = "runJavascript", .params = &.{.string} },
        },
    },
    .{
        .name = "Camera",
        .doc = "The camera's picture, shown like an `Image` (`image-fit`) while `active` (the camera runs while one is; the first time, the platform may ask the user). `take-picture()` keeps the frame shown as `picture` (an image to show elsewhere) and calls `picture-taken`; `save-picture(path)` writes it as a PNG file. `available` tells whether there is a camera (with the SDL3 backend: macOS, Windows, Linux; with the native macOS one).",
        .zig_type = "zigulee.items.Camera",
        .item = "image.item",
        .init_call = "init(gpa)",
        .children = false,
        .props = &.{
            .{ .name = "active", .ty = .bool, .zig = "active" },
            .{ .name = "available", .ty = .bool, .zig = "available", .read_only = true },
            .{ .name = "picture", .ty = .image, .zig = "picture", .optional = true, .read_only = true },
            .{ .name = "image-fit", .ty = .{ .enumeration = &image_fit }, .zig = "image.image_fit" },
            .{ .name = "image-rendering", .ty = .{ .enumeration = &image_rendering }, .zig = "image.image_rendering" },
        },
        .callbacks = &.{.{ .name = "picture-taken", .zig = "picture_taken" }},
        .functions = &.{
            .{ .name = "take-picture", .zig = "takePicture" },
            .{ .name = "save-picture", .zig = "savePicture", .params = &.{.string} },
        },
    },
    .{
        .name = "Accelerometer",
        .doc = "The device's acceleration while `active`: `x`, `y` and `z` in m/s², gravity included (lying face up: 0, 0, 9.81), with x to the right, y up and z out of the screen, the device held upright. `reading-changed` is called at each reading, at most `data-rate` times a second (0, the default: as they come). `available` tells whether there is one (in browsers: the API, which computers have without the sensor). On iOS, the browser asks the user first, at the next tap. Not drawn.",
        .zig_type = "zigulee.items.Accelerometer",
        .item = "sensor.item",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &(sensor_props ++ [_]Prop{
            .{ .name = "x", .ty = .float, .zig = "x", .read_only = true },
            .{ .name = "y", .ty = .float, .zig = "y", .read_only = true },
            .{ .name = "z", .ty = .float, .zig = "z", .read_only = true },
        }),
        .callbacks = &.{.{ .name = "reading-changed", .zig = "sensor.reading_changed" }},
    },
    .{
        .name = "Gyroscope",
        .doc = "How fast the device turns while `active`: about `x`, `y` and `z` (the `Accelerometer`'s axes) in degrees a second, counterclockwise looking down the axis. `reading-changed`, `data-rate` and `available` as the `Accelerometer`'s. Not drawn.",
        .zig_type = "zigulee.items.Gyroscope",
        .item = "sensor.item",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &(sensor_props ++ [_]Prop{
            .{ .name = "x", .ty = .float, .zig = "x", .read_only = true },
            .{ .name = "y", .ty = .float, .zig = "y", .read_only = true },
            .{ .name = "z", .ty = .float, .zig = "z", .read_only = true },
        }),
        .callbacks = &.{.{ .name = "reading-changed", .zig = "sensor.reading_changed" }},
    },
    .{
        .name = "Compass",
        .doc = "Where the device points while `active`: `azimuth` in degrees clockwise from magnetic north (0 to 360), and `calibration-level` (0 to 1). `reading-changed`, `data-rate` and `available` as the `Accelerometer`'s. Not drawn.",
        .zig_type = "zigulee.items.Compass",
        .item = "sensor.item",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &(sensor_props ++ [_]Prop{
            .{ .name = "azimuth", .ty = .float, .zig = "azimuth", .read_only = true },
            .{ .name = "calibration-level", .ty = .float, .zig = "calibration_level", .read_only = true },
        }),
        .callbacks = &.{.{ .name = "reading-changed", .zig = "sensor.reading_changed" }},
    },
    .{
        .name = "OrientationSensor",
        .doc = "Which side of the device is up while `active`: `orientation` is `DeviceOrientation.top-up` (upright), `top-down`, `left-up`, `right-up`, `face-up`, `face-down`, or `unknown` until known. Worked out from the accelerometer where the platform tells no orientation itself. `reading-changed`, `data-rate` and `available` as the `Accelerometer`'s. Not drawn.",
        .zig_type = "zigulee.items.OrientationSensor",
        .item = "sensor.item",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &(sensor_props ++ [_]Prop{
            .{ .name = "orientation", .ty = .{ .enumeration = &device_orientation }, .zig = "orientation", .read_only = true },
        }),
        .callbacks = &.{.{ .name = "reading-changed", .zig = "sensor.reading_changed" }},
    },
    .{
        .name = "MapView",
        .doc = "A map of web tiles centered on `latitude`, `longitude` at `zoom` (0: the world in one tile; each step doubles the scale; within `minimum-zoom` and `maximum-zoom`, 0 and 19 by default), Web Mercator. Tiles come from `tile-url`, a template whose `{z}`, `{x}` and `{y}` are filled in (OpenStreetMap's by default; `file://` works too; empty: none), loaded in the background and kept in memory and for a week in the application's cache; lower zoom levels stand in while they come. On screens of 1.5 pixels a point or more (with `high-density`, the default), the next zoom level's tiles show at half their size, sharp, or with a `{r}` in the template (filled with `@2x`), the server's own. `attribution` shows in the bottom right corner (OpenStreetMap's by default: its terms ask for it), and `user-agent` is said to tile servers (by default the application's name, which OpenStreetMap's policy asks for). While `interactive` (the default), dragging pans, the wheel and pinching zoom, and a double click zooms in; a click calls `clicked(latitude, longitude)`. `zoom-in()` and `zoom-out()` go a step. `MapItem` and `MapPolyline` children stand at coordinates; other children are placed as usual, over the map. On the web, tiles come through the browser (the tile server must allow it, as OpenStreetMap's does); none from the network on microcontrollers.",
        .zig_type = "zigulee.items.MapView",
        .init_call = "init(gpa)",
        .props = &.{
            .{ .name = "latitude", .ty = .float, .zig = "latitude" },
            .{ .name = "longitude", .ty = .float, .zig = "longitude" },
            .{ .name = "zoom", .ty = .float, .zig = "zoom" },
            .{ .name = "minimum-zoom", .ty = .float, .zig = "minimum_zoom" },
            .{ .name = "maximum-zoom", .ty = .float, .zig = "maximum_zoom" },
            .{ .name = "tile-url", .ty = .string, .zig = "tile_url" },
            .{ .name = "attribution", .ty = .string, .zig = "attribution" },
            .{ .name = "user-agent", .ty = .string, .zig = "user_agent" },
            .{ .name = "interactive", .ty = .bool, .zig = "interactive" },
            .{ .name = "high-density", .ty = .bool, .zig = "high_density" },
            .{ .name = "background", .ty = .brush, .zig = "background" },
        },
        .callbacks = &.{.{ .name = "clicked", .zig = "clicked", .params = &.{ .float, .float } }},
        .functions = &.{
            .{ .name = "zoom-in", .zig = "zoomIn" },
            .{ .name = "zoom-out", .zig = "zoomOut" },
        },
    },
    .{
        .name = "MapItem",
        .doc = "In a `MapView`: stands at `latitude`, `longitude`, the point `anchor-x`, `anchor-y` of it (fractions of its size; 0.5, 0.5, the default, its middle; 0.5, 1 its bottom middle, for a pin) on the coordinate. Give it a size; its children are what shows there (a marker: any elements).",
        .zig_type = "zigulee.items.MapItem",
        .init_call = "init(gpa)",
        .props = &.{
            .{ .name = "latitude", .ty = .float, .zig = "latitude" },
            .{ .name = "longitude", .ty = .float, .zig = "longitude" },
            .{ .name = "anchor-x", .ty = .float, .zig = "anchor_x" },
            .{ .name = "anchor-y", .ty = .float, .zig = "anchor_y" },
        },
    },
    .{
        .name = "MapPolyline",
        .doc = "In a `MapView`: a line through `coordinates`, given as latitude, longitude, latitude, longitude... (`[45.46, 9.19, 45.07, 7.69]`), in `stroke` (blue by default), `stroke-width` wide (3px by default). `closed`, it goes back to the start: an outline, filled with `fill`.",
        .zig_type = "zigulee.items.MapPolyline",
        .init_call = "init(gpa)",
        .children = false,
        .props = &.{
            .{ .name = "coordinates", .ty = .{ .model = &rows.float }, .zig = "coordinates" },
            .{ .name = "stroke", .ty = .brush, .zig = "stroke" },
            .{ .name = "stroke-width", .ty = .length, .zig = "stroke_width" },
            .{ .name = "fill", .ty = .brush, .zig = "fill" },
            .{ .name = "closed", .ty = .bool, .zig = "closed" },
        },
    },
    .{
        .name = "PositionSource",
        .doc = "The device's position while `active` (the first time, the platform asks the user): `latitude` and `longitude` in degrees (WGS 84; as floats, to about a meter), `accuracy` in meters, `altitude` in meters above sea level, `speed` in m/s and `direction` in degrees clockwise from true north, each with its `-valid` flag where the platform may not know it, and `timestamp` (since 1970, UTC). `valid` turns true with the first fix, and `updated` is called at each one, at most every `minimum-interval` (0, the default: as they come). `error` tells why there is none (`PositionError.permission-denied`, `unavailable`, `timeout`). `available` tells whether there is a location service (in browsers: geolocation; on macOS: Core Location, with the native backend). Not drawn.",
        .zig_type = "zigulee.items.PositionSource",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &.{
            .{ .name = "active", .ty = .bool, .zig = "active" },
            .{ .name = "available", .ty = .bool, .zig = "available", .read_only = true },
            .{ .name = "minimum-interval", .ty = .duration, .zig = "minimum_interval" },
            .{ .name = "valid", .ty = .bool, .zig = "valid", .read_only = true },
            .{ .name = "latitude", .ty = .float, .zig = "latitude", .read_only = true },
            .{ .name = "longitude", .ty = .float, .zig = "longitude", .read_only = true },
            .{ .name = "accuracy", .ty = .float, .zig = "accuracy", .read_only = true },
            .{ .name = "altitude", .ty = .float, .zig = "altitude", .read_only = true },
            .{ .name = "altitude-valid", .ty = .bool, .zig = "altitude_valid", .read_only = true },
            .{ .name = "speed", .ty = .float, .zig = "speed", .read_only = true },
            .{ .name = "speed-valid", .ty = .bool, .zig = "speed_valid", .read_only = true },
            .{ .name = "direction", .ty = .float, .zig = "direction", .read_only = true },
            .{ .name = "direction-valid", .ty = .bool, .zig = "direction_valid", .read_only = true },
            .{ .name = "timestamp", .ty = .duration, .zig = "timestamp", .read_only = true },
            .{ .name = "error", .ty = .{ .enumeration = &position_error }, .zig = "error_", .read_only = true },
        },
        .callbacks = &.{.{ .name = "updated", .zig = "updated" }},
    },
    .{
        .name = "Microphone",
        .doc = "The microphone: while `active`, `level` follows how loud it is (0 to 1, falling off slowly), for a meter. `record()` keeps what it hears (it runs meanwhile, `active` or not; `recording`, `duration` so far) until `stop()`: then `recorded` is that sound, for an `Audio` element to play, and `finished` is called; `save-recording(path)` writes it as a WAV file. Recordings are mono, at most ten minutes. The first time, the platform may ask the user. `available` tells whether there is a microphone input (with the SDL3 backend: macOS, Windows, Linux; with the native macOS one). Not drawn.",
        .zig_type = "zigulee.items.Microphone",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &.{
            .{ .name = "active", .ty = .bool, .zig = "active" },
            .{ .name = "recording", .ty = .bool, .zig = "recording", .read_only = true },
            .{ .name = "level", .ty = .float, .zig = "level", .read_only = true },
            .{ .name = "duration", .ty = .duration, .zig = "duration_ms", .read_only = true },
            .{ .name = "recorded", .ty = .audio, .zig = "recorded", .read_only = true },
            .{ .name = "available", .ty = .bool, .zig = "available", .read_only = true },
        },
        .callbacks = &.{.{ .name = "finished", .zig = "finished" }},
        .functions = &.{
            .{ .name = "record", .zig = "record" },
            .{ .name = "stop", .zig = "stop" },
            .{ .name = "save-recording", .zig = "saveRecording", .params = &.{.string} },
        },
    },
    .{
        .name = "AnimatedImage",
        .doc = "Plays an animated image (`@image-url(\"spinner.gif\")`: a GIF or an animated PNG) and shows it like an `Image`. It plays when shown, as many times as the file says (usually forever), at `speed`; `playing: false` holds the frame shown. `current-frame` follows it, and setting it shows that frame; `frame-count` is how many there are. `finished` is called when it has played as many times as the file says, keeping the last frame. A still image shows as it is.",
        .zig_type = "zigulee.items.AnimatedImageElement",
        .item = "image.item",
        .init_call = "init(gpa)",
        .children = false,
        .props = &.{
            .{ .name = "source", .ty = .image, .zig = "source", .optional = true },
            .{ .name = "playing", .ty = .bool, .zig = "playing" },
            .{ .name = "speed", .ty = .float, .zig = "speed" },
            .{ .name = "current-frame", .ty = .int, .zig = "current_frame" },
            .{ .name = "frame-count", .ty = .int, .zig = "frame_count", .read_only = true },
            .{ .name = "image-fit", .ty = .{ .enumeration = &image_fit }, .zig = "image.image_fit" },
            .{ .name = "image-rendering", .ty = .{ .enumeration = &image_rendering }, .zig = "image.image_rendering" },
            .{ .name = "colorize", .ty = .brush, .zig = "image.colorize", .optional = true },
        },
        .callbacks = &.{.{ .name = "finished", .zig = "finished" }},
    },
    .{
        .name = "PropertyAnimation",
        .doc = "Animates `target` (a property: `box.opacity`) from `from` (else its value when it starts) to `to`, over `duration` with `easing`, `loops` times (-1: forever). `start()`, `stop()` (where it is), `pause()`, `resume()`, or set `running`; `finished` is called at its end. In a SequentialAnimation or ParallelAnimation, its group runs it. Not drawn.",
        .zig_type = "zigulee.items.PropertyAnimation",
        .item = "node.item",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &.{
            .{ .name = "duration", .ty = .duration, .zig = "node.duration_ms" },
            .{ .name = "easing", .ty = .easing, .zig = "node.easing" },
            .{ .name = "loops", .ty = .int, .zig = "node.loops" },
            .{ .name = "running", .ty = .bool, .zig = "node.running" },
            .{ .name = "paused", .ty = .bool, .zig = "node.paused" },
        },
        .callbacks = &.{.{ .name = "finished", .zig = "node.finished" }},
        .functions = &.{
            .{ .name = "start", .zig = "start" },
            .{ .name = "stop", .zig = "stop" },
            .{ .name = "pause", .zig = "pause" },
            .{ .name = "resume", .zig = "resumeAnimation" },
        },
    },
    .{
        .name = "PauseAnimation",
        .doc = "Waits `duration` in a SequentialAnimation. Not drawn.",
        .zig_type = "zigulee.items.PauseAnimation",
        .item = "node.item",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &.{
            .{ .name = "duration", .ty = .duration, .zig = "node.duration_ms" },
            .{ .name = "loops", .ty = .int, .zig = "node.loops" },
            .{ .name = "running", .ty = .bool, .zig = "node.running" },
            .{ .name = "paused", .ty = .bool, .zig = "node.paused" },
        },
        .callbacks = &.{.{ .name = "finished", .zig = "node.finished" }},
        .functions = &.{
            .{ .name = "start", .zig = "start" },
            .{ .name = "stop", .zig = "stop" },
            .{ .name = "pause", .zig = "pause" },
            .{ .name = "resume", .zig = "resumeAnimation" },
        },
    },
    .{
        .name = "SequentialAnimation",
        .doc = "Runs the animations in it one after the other, `loops` times (-1: forever). `start()`, `stop()`, `pause()`, `resume()`, or set `running`; `finished` is called at its end. Not drawn.",
        .zig_type = "zigulee.items.SequentialAnimation",
        .item = "node.item",
        .init_call = "init(gpa)",
        .in_tree = false,
        .props = &.{
            .{ .name = "loops", .ty = .int, .zig = "node.loops" },
            .{ .name = "running", .ty = .bool, .zig = "node.running" },
            .{ .name = "paused", .ty = .bool, .zig = "node.paused" },
        },
        .callbacks = &.{.{ .name = "finished", .zig = "node.finished" }},
        .functions = &.{
            .{ .name = "start", .zig = "start" },
            .{ .name = "stop", .zig = "stop" },
            .{ .name = "pause", .zig = "pause" },
            .{ .name = "resume", .zig = "resumeAnimation" },
        },
    },
    .{
        .name = "ParallelAnimation",
        .doc = "Runs the animations in it together (until the longest ends), `loops` times (-1: forever). `start()`, `stop()`, `pause()`, `resume()`, or set `running`; `finished` is called at its end. Not drawn.",
        .zig_type = "zigulee.items.ParallelAnimation",
        .item = "node.item",
        .init_call = "init(gpa)",
        .in_tree = false,
        .props = &.{
            .{ .name = "loops", .ty = .int, .zig = "node.loops" },
            .{ .name = "running", .ty = .bool, .zig = "node.running" },
            .{ .name = "paused", .ty = .bool, .zig = "node.paused" },
        },
        .callbacks = &.{.{ .name = "finished", .zig = "node.finished" }},
        .functions = &.{
            .{ .name = "start", .zig = "start" },
            .{ .name = "stop", .zig = "stop" },
            .{ .name = "pause", .zig = "pause" },
            .{ .name = "resume", .zig = "resumeAnimation" },
        },
    },
    .{
        .name = "Connections",
        .doc = "Handlers for another element's callbacks: `Connections { target: list; selected(i) => { ... } }`. They are added to the element's own handlers (which run first) and run while `enabled`. `target` is an element's id, `root`, `parent` or a global. A single one can also be written on any element: `list.selected(i) => { ... }`. Not drawn.",
        .zig_type = "zigulee.items.Connections",
        .children = false,
        .in_tree = false,
        .props = &.{
            .{ .name = "enabled", .ty = .bool, .zig = "enabled" },
        },
    },
    .{
        .name = "Loader",
        .doc = "Shows the component `source` names (a component's name, or a `component` property), created at run time, while `active`: its root fills the loader. Another source replaces it. The loader's other bindings are passed to the instance's input properties of the same name and type (`Loader { source: delegate; data: row; index: i; }`); a component without one is logged. `loaded` says whether an instance is shown.",
        .zig_type = "zigulee.items.Loader",
        .init_call = "init(gpa)",
        .children = false,
        .props = &.{
            .{ .name = "source", .ty = .component, .zig = "source" },
            .{ .name = "active", .ty = .bool, .zig = "active" },
            .{ .name = "loaded", .ty = .bool, .zig = "loaded", .read_only = true },
        },
    },
    .{
        .name = "FileDialog",
        .doc = "The platform's file dialog: `open()` shows it, to open a file (`mode: open-file`), several (`open-files`), a folder (`open-folder`) or a file to save (`save-file`). `filter` limits the files shown, as in Qt: `\"Images (*.png *.jpg);;All files (*)\"`. `folder` is where it starts, `file-name` the name suggested to save. The answer is `selected-file` (and all of them, `selected-files`), then `accepted`; or `rejected` if cancelled. Where there are no file dialogs (the web, microcontrollers), it is always rejected. Not drawn.",
        .zig_type = "zigulee.items.FileDialogElement",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &.{
            .{ .name = "mode", .ty = .{ .enumeration = &file_dialog_mode }, .zig = "mode" },
            .{ .name = "title", .ty = .string, .zig = "title" },
            .{ .name = "filter", .ty = .string, .zig = "filter" },
            .{ .name = "folder", .ty = .string, .zig = "folder" },
            .{ .name = "file-name", .ty = .string, .zig = "file_name" },
            .{ .name = "selected-file", .ty = .string, .zig = "selected_file", .read_only = true },
            .{ .name = "selected-files", .ty = .{ .model = &rows.string }, .zig = "selected_files", .read_only = true },
            .{ .name = "is-open", .ty = .bool, .zig = "is_open", .read_only = true },
        },
        .callbacks = &.{
            .{ .name = "accepted", .zig = "accepted" },
            .{ .name = "rejected", .zig = "rejected" },
        },
        .functions = &.{.{ .name = "open", .zig = "open" }},
    },
    .{
        .name = "HttpRequest",
        .doc = "A request over HTTP or HTTPS, made by `send()` (`abort()` drops it): to `url`, with `method` (`get`, `post`, `put`, `patch`, `delete`, `head`), `headers` (\"Name: value\" each) and a `body`. It runs in the background (`loading` meanwhile); the answer is `status` and `response`, then `finished` (whatever the status), or if there was none (no network, a bad address), `error` says why, then `failed`. `json-get`, `json-number` and `json-count` read JSON answers. Without threads (the web, microcontrollers), requests fail. Not drawn.",
        .zig_type = "zigulee.items.HttpRequest",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &.{
            .{ .name = "url", .ty = .string, .zig = "url" },
            .{ .name = "method", .ty = .{ .enumeration = &http_method }, .zig = "method" },
            .{ .name = "headers", .ty = .{ .model = &rows.string }, .zig = "headers" },
            .{ .name = "body", .ty = .string, .zig = "body" },
            .{ .name = "loading", .ty = .bool, .zig = "loading", .read_only = true },
            .{ .name = "status", .ty = .int, .zig = "status", .read_only = true },
            .{ .name = "response", .ty = .string, .zig = "response", .read_only = true },
            .{ .name = "error", .ty = .string, .zig = "error_text", .read_only = true },
        },
        .callbacks = &.{
            .{ .name = "finished", .zig = "finished" },
            .{ .name = "failed", .zig = "failed" },
        },
        .functions = &.{
            .{ .name = "send", .zig = "send" },
            .{ .name = "abort", .zig = "abort" },
        },
    },
    .{
        .name = "Canvas",
        .doc = "2D drawing from code, as QML's Canvas and HTML's: the `paint` handler calls the drawing functions, in the canvas's coordinates (lengths; angles in degrees, clockwise). Paths: `begin-path()`, `move-to(x, y)`, `line-to(x, y)`, `quadratic-curve-to(cx, cy, x, y)`, `bezier-curve-to(c1x, c1y, c2x, c2y, x, y)`, `arc(x, y, radius, start-angle, end-angle, anticlockwise)` (from 3 o'clock), `rect(x, y, w, h)`, `rounded-rect(x, y, w, h, radius)`, `ellipse(x, y, w, h)`, `close-path()`, then `fill()` (in `fill-style`), `stroke()` (in `stroke-style`, `line-width` wide) or `clip()`. Also `fill-rect`, `stroke-rect`, `clear-rect` (of the whole canvas), `fill-text(text, x, y)` (on its baseline, in `font-size`, `font-family`, `font-weight`, aligned by `text-align`), `draw-image(image, x, y, w, h)`; `translate(x, y)`, `rotate(degrees)`, `scale(sx, sy)`, `reset-transform()`; `save()` and `restore()` (the transform, the styles and the clip). `global-alpha` fades what follows. Each paint starts from an empty canvas; `paint` runs again when the canvas is resized, when a property it read changes, and on `request-paint()`.",
        .zig_type = "zigulee.items.Canvas",
        .init_call = "init(gpa)",
        .children = false,
        .props = &.{
            .{ .name = "fill-style", .ty = .brush, .zig = "fill_style" },
            .{ .name = "stroke-style", .ty = .brush, .zig = "stroke_style" },
            .{ .name = "line-width", .ty = .length, .zig = "line_width" },
            .{ .name = "global-alpha", .ty = .float, .zig = "global_alpha" },
            .{ .name = "font-size", .ty = .length, .zig = "font_size" },
            .{ .name = "font-family", .ty = .string, .zig = "font_family" },
            .{ .name = "font-weight", .ty = .int, .zig = "font_weight" },
            .{ .name = "text-align", .ty = .{ .enumeration = &text_horizontal_alignment }, .zig = "text_align" },
        },
        .callbacks = &.{.{ .name = "paint", .zig = "paint" }},
        .functions = &.{
            .{ .name = "request-paint", .zig = "requestPaint" },
            .{ .name = "begin-path", .zig = "beginPath" },
            .{ .name = "close-path", .zig = "closePath" },
            .{ .name = "move-to", .zig = "moveTo", .params = &.{ .length, .length } },
            .{ .name = "line-to", .zig = "lineTo", .params = &.{ .length, .length } },
            .{ .name = "quadratic-curve-to", .zig = "quadraticCurveTo", .params = &.{ .length, .length, .length, .length } },
            .{ .name = "bezier-curve-to", .zig = "bezierCurveTo", .params = &.{ .length, .length, .length, .length, .length, .length } },
            .{ .name = "arc", .zig = "arc", .params = &.{ .length, .length, .length, .float, .float, .bool } },
            .{ .name = "rect", .zig = "rect", .params = &.{ .length, .length, .length, .length } },
            .{ .name = "rounded-rect", .zig = "roundedRect", .params = &.{ .length, .length, .length, .length, .length } },
            .{ .name = "ellipse", .zig = "ellipse", .params = &.{ .length, .length, .length, .length } },
            .{ .name = "fill", .zig = "fill" },
            .{ .name = "stroke", .zig = "stroke" },
            .{ .name = "clip", .zig = "clip" },
            .{ .name = "fill-rect", .zig = "fillRect", .params = &.{ .length, .length, .length, .length } },
            .{ .name = "stroke-rect", .zig = "strokeRect", .params = &.{ .length, .length, .length, .length } },
            .{ .name = "clear-rect", .zig = "clearRect", .params = &.{ .length, .length, .length, .length } },
            .{ .name = "fill-text", .zig = "fillText", .params = &.{ .string, .length, .length } },
            .{ .name = "draw-image", .zig = "drawImage", .params = &.{ .image, .length, .length, .length, .length } },
            .{ .name = "save", .zig = "save" },
            .{ .name = "restore", .zig = "restore" },
            .{ .name = "translate", .zig = "translate", .params = &.{ .length, .length } },
            .{ .name = "rotate", .zig = "rotate", .params = &.{.float} },
            .{ .name = "scale", .zig = "scale", .params = &.{ .float, .float } },
            .{ .name = "reset-transform", .zig = "resetTransform" },
        },
    },
    .{
        .name = "LineChart",
        .doc = "The `values` as a line from left to right, within the element: `color` and `line-width`, an area down to 0 with `fill`, dots with `point-size`. It shows the values from `minimum` to `maximum`, or if those are not set, a range around the values and 0 rounded so that `grid-lines` lines (drawn in `grid-color`) fall on round values: `shown-minimum` and `shown-maximum` tell which, to label them. The point nearest the pointer is `hovered-index` (-1: none), and a click on it calls `clicked(index)`. Several charts with the same `minimum` and `maximum` stacked show several series.",
        .zig_type = "zigulee.items.LineChart",
        .init_call = "init(gpa)",
        .children = false,
        .props = &.{
            .{ .name = "values", .ty = .{ .model = &rows.float }, .zig = "values" },
            .{ .name = "minimum", .ty = .float, .zig = "minimum" },
            .{ .name = "maximum", .ty = .float, .zig = "maximum" },
            .{ .name = "color", .ty = .brush, .zig = "color" },
            .{ .name = "line-width", .ty = .length, .zig = "line_width" },
            .{ .name = "fill", .ty = .brush, .zig = "fill" },
            .{ .name = "point-size", .ty = .length, .zig = "point_size" },
            .{ .name = "grid-lines", .ty = .int, .zig = "grid_lines" },
            .{ .name = "grid-color", .ty = .brush, .zig = "grid_color" },
            .{ .name = "shown-minimum", .ty = .float, .zig = "shown_minimum", .read_only = true },
            .{ .name = "shown-maximum", .ty = .float, .zig = "shown_maximum", .read_only = true },
            .{ .name = "hovered-index", .ty = .int, .zig = "hovered_index", .read_only = true },
        },
        .callbacks = &.{.{ .name = "clicked", .zig = "clicked", .params = &.{.int} }},
    },
    .{
        .name = "BarChart",
        .doc = "The `values` as bars side by side, up from 0 (down if negative), within the element: in `colors` (repeated; ten colors by default), `spacing` the part of each bar's place left between them, with rounded corners (`border-radius`). The range shown, grid lines, `hovered-index` and `clicked(index)` are as in `LineChart`.",
        .zig_type = "zigulee.items.BarChart",
        .init_call = "init(gpa)",
        .children = false,
        .props = &.{
            .{ .name = "values", .ty = .{ .model = &rows.float }, .zig = "values" },
            .{ .name = "colors", .ty = .{ .model = &rows.color }, .zig = "colors" },
            .{ .name = "minimum", .ty = .float, .zig = "minimum" },
            .{ .name = "maximum", .ty = .float, .zig = "maximum" },
            .{ .name = "spacing", .ty = .float, .zig = "spacing" },
            .{ .name = "border-radius", .ty = .length, .zig = "border_radius" },
            .{ .name = "grid-lines", .ty = .int, .zig = "grid_lines" },
            .{ .name = "grid-color", .ty = .brush, .zig = "grid_color" },
            .{ .name = "shown-minimum", .ty = .float, .zig = "shown_minimum", .read_only = true },
            .{ .name = "shown-maximum", .ty = .float, .zig = "shown_maximum", .read_only = true },
            .{ .name = "hovered-index", .ty = .int, .zig = "hovered_index", .read_only = true },
        },
        .callbacks = &.{.{ .name = "clicked", .zig = "clicked", .params = &.{.int} }},
    },
    .{
        .name = "PieChart",
        .doc = "The `values` as slices of a circle, clockwise from the top, each its part of their sum (negative values count as none), in `colors` (repeated; ten colors by default); a ring with `hole`, the part of the radius left empty (0 to 0.95). The slice under the pointer is `hovered-index` (-1: none), and a click on it calls `clicked(index)`.",
        .zig_type = "zigulee.items.PieChart",
        .init_call = "init(gpa)",
        .children = false,
        .props = &.{
            .{ .name = "values", .ty = .{ .model = &rows.float }, .zig = "values" },
            .{ .name = "colors", .ty = .{ .model = &rows.color }, .zig = "colors" },
            .{ .name = "hole", .ty = .float, .zig = "hole" },
            .{ .name = "hovered-index", .ty = .int, .zig = "hovered_index", .read_only = true },
        },
        .callbacks = &.{.{ .name = "clicked", .zig = "clicked", .params = &.{.int} }},
    },
    .{
        .name = "KeyboardInput",
        .doc = "What an on-screen keyboard needs (`VirtualKeyboard` is one): `active` while a text input that can be edited has the keyboard focus (`multi-line` and `password` tell what kind), `send(text)` types a character or a key (`Key.Backspace`, `Key.Return`, ...) into it, and `dismiss()` takes its focus away. Clicks on the keyboard leave the focus where it is. Not drawn.",
        .zig_type = "zigulee.items.KeyboardInput",
        .init_call = "init(gpa)",
        .children = false,
        .props = &.{
            .{ .name = "active", .ty = .bool, .zig = "active", .read_only = true },
            .{ .name = "multi-line", .ty = .bool, .zig = "multi_line", .read_only = true },
            .{ .name = "password", .ty = .bool, .zig = "password", .read_only = true },
        },
        .functions = &.{
            .{ .name = "send", .zig = "send", .params = &.{.string} },
            .{ .name = "dismiss", .zig = "dismiss" },
        },
    },
    .{
        .name = "Settings",
        .doc = "Properties kept from one run of the application to the next: a component that inherits `Settings` has its declared properties (int, float, bool, string, length, duration, color) saved, under `category`, in `settings.ini` in the application's configuration folder (`StandardPaths`' `app-config`), or in `file`. Saved values replace the defaults once the component and its users are set up, so properties linked to them with `<=>` take them too. Changes are written a moment later, and when it goes. Where there are no files (the web, microcontrollers), they last as long as the application. Not drawn.",
        .zig_type = "zigulee.items.Settings",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &.{
            .{ .name = "category", .ty = .string, .zig = "category" },
            .{ .name = "file", .ty = .string, .zig = "file" },
        },
    },
    .{
        .name = "StandardPaths",
        .doc = "Where things go on this system: the user's `home`, `desktop`, `documents`, `downloads`, `pictures`, `music` and `videos` folders, `temp`, and the application's own folders for configuration (`app-config`), data (`app-data`) and caches (`app-cache`), named after the application (`zigulee.core.paths.setApplicationName`, else the executable's name). Empty where there is none (an iOS app has no desktop; the web and microcontrollers have no files). Not drawn.",
        .zig_type = "zigulee.items.StandardPaths",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &.{
            .{ .name = "home", .ty = .string, .zig = "home", .read_only = true },
            .{ .name = "desktop", .ty = .string, .zig = "desktop", .read_only = true },
            .{ .name = "documents", .ty = .string, .zig = "documents", .read_only = true },
            .{ .name = "downloads", .ty = .string, .zig = "downloads", .read_only = true },
            .{ .name = "pictures", .ty = .string, .zig = "pictures", .read_only = true },
            .{ .name = "music", .ty = .string, .zig = "music", .read_only = true },
            .{ .name = "videos", .ty = .string, .zig = "videos", .read_only = true },
            .{ .name = "temp", .ty = .string, .zig = "temp", .read_only = true },
            .{ .name = "app-config", .ty = .string, .zig = "app_config", .read_only = true },
            .{ .name = "app-data", .ty = .string, .zig = "app_data", .read_only = true },
            .{ .name = "app-cache", .ty = .string, .zig = "app_cache", .read_only = true },
        },
    },
    .{
        .name = "SystemTrayIcon",
        .doc = "An icon in the system tray (on the right of macOS's menu bar, in Windows' notification area), shown while `visible`: its `icon` (macOS shows `tooltip` as its title when there is none) and `tooltip`. Its `PlatformMenuItem` children are its menu, opened by a click; without any, a click calls `activated`. `available` tells whether the platform has a tray (not on Linux yet, the web, mobile or microcontrollers). Not drawn.",
        .zig_type = "zigulee.items.SystemTrayIcon",
        .init_call = "init(gpa)",
        .props = &.{
            .{ .name = "icon", .ty = .image, .zig = "icon", .optional = true },
            .{ .name = "tooltip", .ty = .string, .zig = "tooltip" },
            .{ .name = "available", .ty = .bool, .zig = "available", .read_only = true },
        },
        .callbacks = &.{.{ .name = "activated", .zig = "activated" }},
    },
    .{
        .name = "Notification",
        .doc = "A desktop notification: `send()` shows `title` and `body` (each call another one), and a click on it calls `clicked`. `available` tells whether the platform shows them (macOS, from an application bundle; Windows; Linux desktops); elsewhere `send()` only logs. Not drawn.",
        .zig_type = "zigulee.items.Notification",
        .init_call = "init(gpa)",
        .children = false,
        .in_tree = false,
        .props = &.{
            .{ .name = "title", .ty = .string, .zig = "title" },
            .{ .name = "body", .ty = .string, .zig = "body" },
            .{ .name = "available", .ty = .bool, .zig = "available", .read_only = true },
        },
        .callbacks = &.{.{ .name = "clicked", .zig = "clicked" }},
        .functions = &.{.{ .name = "send", .zig = "send" }},
    },
    .{
        .name = "PlatformMenu",
        .doc = "A menu of the platform's menu bar (macOS's, at the top of the screen), with `PlatformMenuItem` children; `native` tells whether there is one (elsewhere it does nothing, and menus belong in the window). `MenuBarItem` makes one. Not drawn.",
        .zig_type = "zigulee.items.PlatformMenu",
        .init_call = "init(gpa)",
        .props = &.{
            .{ .name = "text", .ty = .string, .zig = "text" },
            .{ .name = "native", .ty = .bool, .zig = "native", .read_only = true },
        },
    },
    .{
        .name = "PlatformMenuItem",
        .doc = "An entry of a `PlatformMenu`: `text`, a `shortcut` (\"Ctrl+S\", ⌘S on macOS), `checked`, `enabled`, or a `separator` line; `activated` when chosen. `level` nests it: the entries right after one, a level deeper, are its submenu. Not drawn.",
        .zig_type = "zigulee.items.PlatformMenuItem",
        .children = false,
        .props = &.{
            .{ .name = "text", .ty = .string, .zig = "text" },
            .{ .name = "shortcut", .ty = .string, .zig = "shortcut" },
            .{ .name = "checked", .ty = .bool, .zig = "checked" },
            .{ .name = "enabled", .ty = .bool, .zig = "enabled" },
            .{ .name = "separator", .ty = .bool, .zig = "separator" },
            .{ .name = "level", .ty = .int, .zig = "level" },
        },
        .callbacks = &.{.{ .name = "activated", .zig = "activated" }},
    },
    .{
        .name = "PopupWindow",
        .doc = "Content shown above everything else with `show()`, at its position relative to its parent. Closed with `close()` or, depending on `close-policy`, a click (a click on what it shows past its bounds, a menu's submenu, is a click inside). `window-x` and `window-y` are where it was shown in the window, `window-width` and `window-height` the window's size then. While closed, with an `edge-margin` (0 by default: none), a drag the `open-swipe` way (`SwipeDirection.right` by default) begun that close to the window's opposite edge pulls it out: `edge-dragged(distance)` as it goes, `edge-released(distance, speed)` at the end (speed in pixels a second, that way); a press there that does not go that way goes to what is under it.",
        .zig_type = "zigulee.items.PopupWindow",
        .init_call = "init(gpa)",
        .props = &.{
            .{ .name = "close-policy", .ty = .{ .enumeration = &popup_close_policy }, .zig = "close_policy" },
            .{ .name = "is-open", .ty = .bool, .zig = "is_open", .read_only = true },
            .{ .name = "input-transparent", .ty = .bool, .zig = "input_transparent" },
            .{ .name = "fit-in-window", .ty = .bool, .zig = "fit_in_window" },
            .{ .name = "fill-window", .ty = .bool, .zig = "fill_window" },
            .{ .name = "window-x", .ty = .length, .zig = "window_x", .read_only = true },
            .{ .name = "window-y", .ty = .length, .zig = "window_y", .read_only = true },
            .{ .name = "window-width", .ty = .length, .zig = "window_width", .read_only = true },
            .{ .name = "window-height", .ty = .length, .zig = "window_height", .read_only = true },
            .{ .name = "open-swipe", .ty = .{ .enumeration = &swipe_direction }, .zig = "open_swipe" },
            .{ .name = "edge-margin", .ty = .length, .zig = "edge_margin" },
        },
        .callbacks = &.{
            .{ .name = "edge-dragged", .zig = "edge_dragged", .params = &.{.length} },
            .{ .name = "edge-released", .zig = "edge_released", .params = &.{ .length, .float } },
        },
        .functions = &.{
            .{ .name = "show", .zig = "show" },
            .{ .name = "close", .zig = "close" },
        },
    },
    .{ .name = "GridLayout", .doc = "Places its children in a grid: in `Row` elements, or by their `row` and `col` properties. Cells can take `rowspan` and `colspan`.", .zig_type = "zigulee.items.GridLayout", .layout = true, .props = &grid_props },
    .{ .name = "HorizontalLayout", .doc = "Places its children side by side, sized by their constraints and stretch factors.", .zig_type = "zigulee.items.BoxLayout", .init = ".horizontal()", .layout = true, .props = &layout_props },
    .{ .name = "VerticalLayout", .doc = "Places its children one below the other, sized by their constraints and stretch factors.", .zig_type = "zigulee.items.BoxLayout", .init = ".vertical()", .layout = true, .props = &layout_props },
};

pub fn findBuiltin(n: []const u8) ?*const Builtin {
    for (&builtins) |*b| if (std.mem.eql(u8, b.name, n)) return b;
    return null;
}

/// Global functions usable in expressions.
pub const global_functions = [_][]const u8{ "min", "max", "abs", "round", "floor", "ceil", "sqrt", "sin", "cos", "mod", "debug", "json-get", "json-number", "json-count", "open-url" };

/// `Key.Name` constants (the text of special keys) and their Zig names in
/// `zigulee.core.input.Key`.
pub const key_names = [_][2][]const u8{
    .{ "Backspace", "backspace" },  .{ "Tab", "tab" },                .{ "Return", "return" },
    .{ "Escape", "escape" },        .{ "Backtab", "back_tab" },       .{ "Delete", "delete" },
    .{ "Space", "space" },          .{ "UpArrow", "up_arrow" },       .{ "DownArrow", "down_arrow" },
    .{ "LeftArrow", "left_arrow" }, .{ "RightArrow", "right_arrow" }, .{ "Home", "home" },
    .{ "End", "end" },              .{ "PageUp", "page_up" },         .{ "PageDown", "page_down" },
};

pub fn keyName(n: []const u8) ?[]const u8 {
    for (key_names) |k| if (std.mem.eql(u8, k[0], n)) return k[1];
    return null;
}

/// CSS color names usable as values.
pub const named_colors = [_]struct { []const u8, u32 }{
    .{ "transparent", 0x00000000 }, .{ "black", 0x000000ff },  .{ "white", 0xffffffff },
    .{ "red", 0xff0000ff },         .{ "green", 0x008000ff },  .{ "blue", 0x0000ffff },
    .{ "yellow", 0xffff00ff },      .{ "orange", 0xffa500ff }, .{ "purple", 0x800080ff },
    .{ "pink", 0xffc0cbff },        .{ "cyan", 0x00ffffff },   .{ "magenta", 0xff00ffff },
    .{ "gray", 0x808080ff },        .{ "grey", 0x808080ff },   .{ "silver", 0xc0c0c0ff },
    .{ "maroon", 0x800000ff },      .{ "olive", 0x808000ff },  .{ "navy", 0x000080ff },
    .{ "teal", 0x008080ff },        .{ "lime", 0x00ff00ff },   .{ "aqua", 0x00ffffff },
    .{ "fuchsia", 0xff00ffff },
};

pub fn namedColor(n: []const u8) ?u32 {
    for (named_colors) |c| if (std.mem.eql(u8, c[0], n)) return c[1];
    return null;
}
