// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

//! The zigulee runtime core: reactive properties, callbacks, models,
//! animations, timers, the item tree, layout, input and windows.
//!
//! One event loop iteration, as a backend will drive it:
//!
//!     updateTimersAndAnimations(platform_now_ms);
//!     // ... dispatch input events ...
//!     runChangeHandlers();
//!     // ... render; keep requesting frames while hasActiveAnimations() ...
//!     // ... otherwise sleep until nextTimerDeadline() or the next event ...

const std = @import("std");
const properties = @import("properties.zig");
const callbacks = @import("callbacks.zig");
const model = @import("model.zig");
const animations = @import("animations.zig");
const timers = @import("timers.zig");
const time = @import("time.zig");
const geometry = @import("geometry.zig");
const graphics = @import("graphics.zig");
const layout_mod = @import("layout.zig");
const item_mod = @import("item.zig");
const items_mod = @import("items.zig");
const input_mod = @import("input.zig");
const rendering_mod = @import("rendering.zig");
const window_mod = @import("window.zig");
const repeater_mod = @import("repeater.zig");
const image_mod = @import("image.zig");
const png_mod = @import("png.zig");
const path_mod = @import("path.zig");
const text_mod = @import("text/text.zig");
const strings = @import("strings.zig");

pub const Property = properties.Property;
pub const PropertyTracker = properties.PropertyTracker;
pub const ChangeTracker = properties.ChangeTracker;
/// Called when a binding reads its own property (by default: a panic).
/// Tools that run user code set a handler that reports and goes on (the
/// read in the loop yields the property's previous value); null restores
/// the default.
pub fn setBindingLoopHandler(handler: ?*const fn () void) void {
    properties.binding_loop_handler = handler orelse properties.defaultBindingLoopHandler;
}
pub const runChangeHandlers = properties.runChangeHandlers;
pub const valuesEqual = properties.valuesEqual;

pub const Callback = callbacks.Callback;
pub const Connection = callbacks.Connection;

pub const Model = model.Model;
pub const ModelNotify = model.ModelNotify;
pub const ModelListener = model.ModelListener;
pub const VecModel = model.VecModel;
pub const SliceModel = model.SliceModel;
pub const DerivedModel = model.DerivedModel;
pub const sortByKeys = model.sortByKeys;
pub const CountModel = model.CountModel;
pub const ArrayModel = model.ArrayModel;
pub const emptyModel = model.emptyModel;

pub const Animation = animations.Animation;
pub const Easing = animations.Easing;
pub const Direction = animations.Direction;
pub const interpolate = animations.interpolate;

pub const Timer = timers.Timer;
pub const TimerMode = timers.Mode;
/// When the event loop must wake up next (a timer is due, or playing
/// sounds may have ended), or null if nothing is pending.
pub fn nextTimerDeadline() ?u64 {
    const t = timers.nextTimerDeadline();
    const notifications = tray.busy();
    const capturing = audio.capture.busy() or camera.busy() or sensors.busy() or location.busy() or
        if (map.service) |m| m.busy() else false;
    if (!audio.mixer().busy() and !dialogs.busy() and !notifications and !capturing) return t;
    // Voices that end, and dialogs answered from another thread, are
    // reported within this many milliseconds; clicks on notifications
    // within `tray.poll_ms`.
    const fast = audio.mixer().busy() or dialogs.busy() or capturing;
    const poll = time.now() +| @as(u64, if (fast) 20 else tray.poll_ms);
    return if (t) |d| @min(d, poll) else poll;
}

pub const now = time.now;
pub const hasActiveAnimations = time.hasActiveAnimations;

pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Rect = geometry.Rect;
pub const Affine = geometry.Affine;
pub const Projective = geometry.Projective;
pub const Region = geometry.Region;
pub const Color = graphics.Color;
pub const Brush = graphics.Brush;
pub const Rgba8 = graphics.Rgba8;
pub const GradientStop = graphics.GradientStop;
pub const GradientStops = graphics.GradientStops;
pub const LinearGradient = graphics.LinearGradient;
pub const RadialGradient = graphics.RadialGradient;
pub const GradientBuffer = graphics.GradientBuffer;
pub const placeStops = graphics.placeStops;
pub const placedStops = graphics.placedStops;
pub const unplaced = graphics.unplaced;

pub const audio = @import("audio/audio.zig");
pub const video = @import("video/video.zig");
/// Web pages (`WebView`).
pub const webview = @import("webview.zig");
pub const cookie = @import("cookie.zig");
/// 3D scenes (`View3D`) and the renderer drawing them.
pub const view3d = @import("view3d.zig");
pub const raster3d = @import("raster3d.zig");
pub const gltf = @import("gltf.zig");
/// A 3D model embedded with `@model-url`.
pub const Model3D = view3d.Source;
/// Opening links with the system (`open-url`).
pub const links = @import("links.zig");
/// The camera (`Camera`).
pub const camera = @import("camera.zig");
/// Motion sensors (`Accelerometer`, `Gyroscope`, `Compass`,
/// `OrientationSensor`).
pub const sensors = @import("sensors.zig");
/// The device's position (`PositionSource`).
pub const location = @import("location.zig");
/// Maps (`MapView`, `MapItem`, `MapPolyline`).
pub const map = @import("map.zig");
pub const dialogs = @import("dialogs.zig");
/// Standard paths: the user's folders, the application's own.
pub const paths = @import("paths.zig");
/// Line, bar and pie charts.
pub const charts = @import("charts.zig");
pub const canvas = @import("canvas.zig");
/// HTTP requests (`HttpRequest`).
pub const http = @import("http.zig");
/// JSON read by path (`json-get` and the like).
pub const json = @import("json.zig");
/// What on-screen keyboards type with (`KeyboardInput`).
pub const keyboard_input = @import("keyboard_input.zig");
/// Properties kept from one run to the next (`Settings`).
pub const settings = @import("settings.zig");
pub const menus = @import("menus.zig");
/// The system tray and desktop notifications.
pub const tray = @import("tray.zig");
/// A video to play (the `video` type): embedded bytes or a file.
pub const Video = video.Source;
/// Sound to play (the `audio` type): a clip.
pub const Audio = audio.Clip;
pub const image = image_mod;
pub const Image = image_mod.Image;
pub const OwnedImage = image_mod.OwnedImage;
pub const png = png_mod;
pub const gif = @import("gif.zig");
pub const animated = @import("animated.zig");
pub const loader = @import("loader.zig");
pub const timeline = @import("timeline.zig");
pub const dnd = @import("dnd.zig");
pub const gestures = @import("gestures.zig");
pub const shortcuts = @import("shortcuts.zig");
pub const pages = @import("pages.zig");
pub const split = @import("split.zig");
pub const tree = @import("tree.zig");
pub const selection = @import("selection.zig");
pub const richtext = @import("richtext.zig");
pub const svg = @import("svg.zig");
pub const image_loader = @import("image_loader.zig");
pub const listlayout = @import("listlayout.zig");
pub const ComponentFactory = loader.ComponentFactory;
pub const path = path_mod;
pub const text = text_mod;
pub const text_edit = @import("text_edit.zig");
pub const Font = text_mod.Font;
pub const StringBuffer = strings.StringBuffer;
pub const Kept = @import("kept.zig").Kept;
/// `f` as an integer, rounded toward zero; saturating at the ends of `T`,
/// and 0 for NaN (where `@intFromFloat` would be illegal). Used for
/// conversions in `.zge` code (`round(x)`, durations), whose values are
/// arbitrary.
/// A duration divided by an int (in `.zge`): truncated, 0 for a division
/// by 0.
pub fn divDuration(a: i64, b: i64) i64 {
    return if (b == 0) 0 else @divTrunc(a, b);
}

pub fn intFromFloat(comptime T: type, f: anytype) T {
    if (std.math.isNan(f)) return 0;
    const lo: @TypeOf(f) = @floatFromInt(std.math.minInt(T));
    const hi: @TypeOf(f) = @floatFromInt(std.math.maxInt(T));
    if (f <= lo) return std.math.minInt(T);
    if (f >= hi) return std.math.maxInt(T);
    return @intFromFloat(f);
}

test intFromFloat {
    try std.testing.expectEqual(@as(i32, 3), intFromFloat(i32, @as(f32, 3.7)));
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), intFromFloat(i32, @as(f32, 1e20)));
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), intFromFloat(i32, -std.math.inf(f32)));
    try std.testing.expectEqual(@as(i64, 0), intFromFloat(i64, std.math.nan(f64)));
}

/// Translations: `@tr(...)`, `setTranslator`, gettext catalogs.
pub const i18n = @import("i18n.zig");

pub const layout = layout_mod;
pub const LayoutInfo = layout_mod.LayoutInfo;
pub const Orientation = layout_mod.Orientation;

pub const Item = item_mod.Item;
pub const ItemVTable = item_mod.ItemVTable;
pub const LayoutConstraints = item_mod.LayoutConstraints;
pub const items = items_mod;
pub const AccessibleRole = item_mod.AccessibleRole;
pub const AccessibleProperties = item_mod.AccessibleProperties;
pub const ItemTransform = item_mod.ItemTransform;
pub const transforms = item_mod.transforms;
pub const effects = item_mod.effects;
/// The accessibility tree, for platform bridges.
pub const accessibility = @import("accessibility.zig");
pub const Repeater = repeater_mod.Repeater;
pub const Conditional = repeater_mod.Conditional;

pub const input = input_mod;
pub const rendering = rendering_mod;
pub const Window = window_mod.Window;
pub const ColorScheme = window_mod.ColorScheme;
pub const WindowState = window_mod.WindowState;
pub const WindowStateSync = window_mod.WindowStateSync;
pub const RenderMode = window_mod.RenderMode;

/// Advances the UI clock to `now_ms` (which animations observe) and fires
/// due timers. Call once per event loop iteration, before handling events.
pub fn updateTimersAndAnimations(now_ms: u64) void {
    time.advanceTo(now_ms);
    timers.updateTimers();
    audio.mixer().update();
    audio.capture.update();
    camera.update();
    sensors.update();
    location.update();
    if (map.service) |m| m.update();
    webview.update();
    dialogs.update();
    menus.update();
    tray.update();
}

pub const fuzz = @import("fuzz.zig");
/// Fuzz targets, for tools/fuzz.zig.
pub const fuzz_targets = @import("fuzz_test.zig");

test {
    _ = properties;
    _ = callbacks;
    _ = model;
    _ = animations;
    _ = timers;
    _ = time;
    _ = geometry;
    _ = graphics;
    _ = layout_mod;
    _ = item_mod;
    _ = items_mod;
    _ = input_mod;
    _ = rendering_mod;
    _ = window_mod;
    _ = repeater_mod;
    _ = image_mod;
    _ = audio;
    _ = video;
    _ = camera;
    _ = sensors;
    _ = location;
    _ = map;
    _ = links;
    _ = webview;
    _ = cookie;
    _ = view3d;
    _ = raster3d;
    _ = gltf;
    _ = dialogs;
    _ = paths;
    _ = charts;
    _ = canvas;
    _ = http;
    _ = json;
    _ = keyboard_input;
    _ = settings;
    _ = menus;
    _ = tray;
    _ = png_mod;
    _ = gif;
    _ = animated;
    _ = loader;
    _ = timeline;
    _ = dnd;
    _ = gestures;
    _ = shortcuts;
    _ = pages;
    _ = split;
    _ = tree;
    _ = selection;
    _ = listlayout;
    _ = richtext;
    _ = @import("kept.zig");
    _ = svg;
    _ = image_loader;
    _ = path_mod;
    _ = text_mod;
    _ = strings;
    _ = text_edit;
    _ = @import("properties_test.zig");
    _ = @import("animations_test.zig");
    _ = @import("items_test.zig");
    _ = @import("repeater_test.zig");
    _ = @import("text_input_test.zig");
    _ = i18n;
    _ = accessibility;
    _ = @import("fuzz_test.zig");
}
