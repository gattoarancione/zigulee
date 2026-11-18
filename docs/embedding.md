# Using zigulee from Zig

The Zig side of an application: the code generated from `.zge` files,
models, globals, fonts, event loops and rendering. See
[getting started](getting-started.md) for the build setup.

## The generated module

`uiModule` (or `uiModuleFromDependency`) compiles a `.zge` file to a Zig
module at build time. Each component becomes a struct:

```zig
const ui = @import("ui");

const app = try ui.App.create(gpa); // heap-allocated: it must not move
defer app.destroy();
```

`uiModule` takes the style of the standard widgets:

```zig
const ui = zigulee.uiModule(b, .{
    .source = b.path("ui/app.zge"),
    .zgec = zigulee_dep.artifact("zgec"),
    .zigulee = zigulee_dep.module("zigulee"),
    .target = target,
    .optimize = optimize,
    .style = "material", // fluent (the default), material, minimal, cupertino, or native (the target system's)
});
```

To read the generated code: `zgec app.zge -o app.zig`.

### Properties

Each declared property is a `zigulee.Property(T)` field, its name with
underscores for dashes:

```zig
app.count.set(5);
const n = app.count.get();
```

A property can also get a binding computed in Zig. It is reevaluated
whenever a property it read changes:

```zig
try app.label.setBinding(gpa, app, struct {
    fn f(a: *ui.App) []const u8 {
        return if (a.count.get() > 1) "many" else "one";
    }
}.f);
```

A binding evaluated again to the same value (a number, a flag, a size:
not a string or a brush, whose memory may be the same with new contents)
leaves what reads it alone: a label growing by a digit lays its row out
again, without redrawing every element the layout places where they were.
Builds for size (`ReleaseSmall`, microcontrollers) leave that comparison
out.

Strings are not copied: a string set from Zig must outlive its use (a
literal, or memory you keep). Gradients are referenced the same way:
`zigulee.Brush.linear(90, &.{ ... })` takes its stops at compile time, so
they live as long as the program; a gradient built at run time is set as
`.{ .linear_gradient = &gradient }`, with a `gradient` that outlives it.

### Callbacks and functions

Each callback is a `zigulee.Callback(fn (Args...) Ret)` field. Set its
handler, with a context pointer or without:

```zig
app.clicked.setHandler(app, struct {
    fn f(a: *ui.App) void {
        a.count.set(a.count.get() + 1);
    }
}.f);
app.add.setHandlerFn(struct {
    fn f(x: i32, y: i32) i32 {
        return x + y;
    }
}.f);
const sum = app.add.call(.{ 2, 3 });
```

A handler set from Zig replaces one written in `.zge`. Public functions are
methods named `invoke_` plus the function name: `public function
set-current-item(i: int)` is `app.invoke_set_current_item(2)`.

### Models

`[T]` properties take a `zigulee.Model(T)`. `VecModel` is a growable one;
the elements repeated by `for` follow its changes row by row:

```zig
var names: zigulee.VecModel([]const u8) = .init(gpa);
defer names.deinit();
try names.push("Ada");
try names.push("Grace");
app.names.set(names.model());

try names.push("Linus");          // adds one row of elements
names.setRowData(0, "Ada L.");    // updates one row
_ = names.remove(1);              // removes one
```

Rows of a struct declared in `.zge` use its generated type
(`zigulee.VecModel(ui.Contact)`). The todo example
([todo.zge](../examples/todo.zge), [todo_list.zig](../examples/todo_list.zig))
is a complete one: the UI asks for changes through callbacks, Zig updates
the model and owns its strings. Other models implement the `Model(T)`
interface (`rowCount`, `rowData`, `setRowData` and change notifications).

### Globals

Globals are singletons: `ui.Theme.instance` has their properties and
callbacks. A global exists while any component of the module does: it is
set up when the first one is created (with its allocator) and freed when
the last one is destroyed, so its values start over after that.

```zig
ui.Theme.instance.dark.set(true);
```

The standard widgets' colors and sizes are the globals `Palette` and
`Style`: `ui.Palette.instance.dark.set(true)` switches to dark mode.
`Style`'s sizes are constants compiled into the widgets (see the
[language guide](language.md#globals)): setting them from Zig has no
effect.

## Translations

Texts marked with `@tr` in `.zge` show in the language of the current
translator: by default the texts as written. Translations usually come
from gettext `.po` files (made by translators from the template that
`zgec tr` writes):

```zig
var italian: zigulee.core.i18n.Catalog = try .parse(gpa, @embedFile("it.po"));
defer italian.deinit();
zigulee.core.i18n.setTranslator(italian.translator()); // everything follows
// ...
zigulee.core.i18n.setTranslator(null); // back to the source texts
```

The catalog uses the plural rule of its header (`Plural-Forms`); fuzzy and
empty entries keep the source text. Other sources of translations
implement `zigulee.core.i18n.Translator`, a function from a message (context,
text, plural form, count) to its translation. The todo example has an
Italian translation: `zig build run-todo -- --lang it`.

## Fonts

zigulee does not ship fonts. Load TrueType files (`.ttf`, `.ttc`) and give
them to the window:

```zig
const regular: zigulee.Font = try .init(@embedFile("Inter-Regular.ttf"));
const bold: zigulee.Font = try .init(@embedFile("Inter-Bold.ttf"));
const window = app.window();
window.default_font.set(&regular);            // for Text without font-family
try window.registerFont("Inter", 400, &regular); // for font-family: "Inter"
try window.registerFont("Inter", 700, &bold);    // and font-weight: 700
```

Characters a font lacks (symbols, emoji, other scripts) can come from
fallback fonts, tried in the order added:

```zig
try window.addFallbackFont(&symbols);
```

## Showing a window (SDL3)

The `zigulee-sdl3` module shows a `zigulee.Window` on macOS, Windows and Linux,
with the system clipboard, input methods and high DPI displays:

```zig
const sdl3 = @import("zigulee-sdl3");

try sdl3.init();
defer sdl3.deinit();
const window = try sdl3.Window.create(gpa, app.window(), .{ .title = "App" });
defer window.destroy();
try window.run(); // returns when the window is closed
```

`window.step(max_wait_ms)` runs one iteration instead, for applications
with their own loop.

Several windows can be open at once: create each with
`sdl3.Window.create`; events go to the window they are for, and one
`sdl3.step` (or `window.step`) runs them all. `window.run()` returns when
that window is closed, `sdl3.runAll()` when all are.

The pointer takes the shape the interface asks for (`mouse-cursor` on a
TouchArea, an I-beam over text fields), and on macOS the window keeps
redrawing while it is being resized.

Windows draw with the GPU renderer: on Metal on macOS, else with OpenGL
when the system has OpenGL 3.3, and with the software renderer otherwise;
`.renderer = .metal`, `.vulkan`, `.d3d12` (Windows) or `.opengl` requires
that API (Vulkan is
loaded at run time: the system's library, or MoltenVK on macOS), and
`.renderer = .software` never uses the GPU. They all draw the same pixels
(within rounding). The software renderer is much faster in release builds
(`-Doptimize=ReleaseFast`).

The title bar is light or dark like the window: by default from the
brightness of its background (a dark theme gets a dark title bar), or as
set with `window.color_scheme` (`.light`, `.dark`, `.auto`). This works on
macOS and Windows.

## A native macOS window

The `zigulee-macos` module shows windows with AppKit directly, without SDL
(smaller binaries, nothing to download or build). It has the same
interface as `zigulee-sdl3`:

```zig
const macos = @import("zigulee-macos");

try macos.init();
defer macos.deinit();
const window = try macos.Window.create(gpa, app.window(), .{ .title = "App" });
defer window.destroy();
try window.run();
```

Typing goes through the system's text input, so input methods, dead keys
(´ then e) and the character palette work; VoiceOver sees the accessible
items; Cmd+Q (the application menu's Quit) closes the windows, ending
`run`. Windows draw with OpenGL when available (`.renderer`, as with
SDL3). Build the examples with it: `zig build run-gallery -Dbackend=macos`.

## On iOS: iPhone, iPad and Mac Catalyst

The `zigulee-ios` module shows windows with UIKit, with the same interface
as the other backends. UIKit owns the start of an iOS app, so the app's
`main` runs once UIKit has launched: the program's real `main` calls
`ios.start(init, app_main)`, and `zigulee.iosApp` in build.zig writes it,
with the bundle's Info.plist:

```zig
// build.zig
const options: zigulee.IosAppOptions = .{
    .name = "hello",
    .bundle_id = "org.example.hello",
    .app = app_module, // its `main` as on other systems, importing zigulee-ios
    .backend = zigulee_dep.module("zigulee-ios"),
    .target = target, // aarch64-ios, aarch64-ios-simulator or aarch64-maccatalyst
    .optimize = optimize,
};
const app = zigulee.iosApp(b, options);
b.getInstallStep().dependOn(app.install(b, options, "ios")); // zig-out/ios/hello.app
```

Windows fill the screen (on a Mac, a window sized to the component) and
draw with Metal, else with the software renderer. Fingers are touches: one
works as the mouse, two pinch a `PinchArea`; on iPad and Mac the pointer
hovers and trackpads and wheels scroll. The on-screen keyboard comes up
while a text field has the focus (text as typed: no autocorrection, and
no input method composition yet); hardware keyboards send their special
keys and shortcuts. The window's `safe-area-*` and `keyboard-height`
follow the system's bars and the keyboard, `fullscreen` hides the status
bar, the status bar and keyboard follow the color scheme, and VoiceOver
sees the accessible items.

`zig build ios -Dtarget=aarch64-ios-simulator` makes the windowed
examples' bundles in zig-out/ios (`-Dtarget=aarch64-ios` for devices:
`-Dios-identity` and `-Dios-profile` sign them with your certificate and
provisioning profile; without them they are signed ad hoc, enough for the
simulator and the Mac). Install one on a booted simulator with
`xcrun simctl install booted zig-out/ios/gallery.app`, then
`xcrun simctl launch booted dev.zigulee.examples.gallery`. On a Mac,
`zig build run-gallery -Dtarget=aarch64-maccatalyst` runs it through Mac
Catalyst, and `zig build test-ios` tests the backend that way.

## A native Windows window

The `zigulee-windows` module shows windows with Win32 directly, without SDL,
with the same interface (`windows.init()`, `windows.Window.create(...)`,
`window.run()`). Windows draw with Direct3D 12 when available, else with
the software renderer (`.renderer = .auto`, `.d3d12` or `.software`), and
follow the monitor's DPI. Input methods show composed text in place, with
their candidate window by the caret; screen readers see the accessible items
(UI Automation); the title bar follows the color scheme. Build the
examples with it: `zig build run-gallery -Dbackend=windows`.

## On a microcontroller: the ESP32-S3

examples/esp32s3 runs the MCU demo (examples/mcu/thermostat.zge) on the
Waveshare ESP32-S3-Touch-LCD-2 (2", 240x320 ST7789, CST816D touch), bare
metal: no ESP-IDF, no RTOS. Zig's LLVM has no Xtensa backend, so the
firmware goes through Zig's C backend, then Espressif's GCC; the image
lives in internal SRAM, loaded there by the chip's ROM bootloader.

```
zig build esp32s3          # zig-out/esp32s3/thermostat.bin
zig build esp32s3-flash    # writes it at 0 (-Desp-port=/dev/cu.usbmodem101)
```

It needs Espressif's crosstool-NG toolchain (`xtensa-esp-elf`, in
`-Dxtensa-toolchain`, default `~/esp/xtensa-esp-elf`) and esptool. Flashing
replaces the board's bootloader at 0: keep a copy of its flash first
(`esptool read-flash 0 0x1000000 backup.bin`) to put the factory firmware
back. The firmware prints each frame's timing on the USB serial port.

`board.zig` is the board support: watchdogs and the CPU clock (160 MHz),
GPIO, the display on SPI2, the touch panel on I2C, text on the USB serial
port. For another board, change the pins and the panel's initialization
there; `runtime.c` and `fast_math.h` give the generated C what a 32-bit
GCC target lacks (128-bit arithmetic) and keep float `@min`/`@max` and
conversions on the FPU. `heap.zig` is a heap over a fixed buffer that
reuses freed memory (a UI that runs for days needs one), and
`zig build mcu-stress` runs the demo with it, 32-bit, through hundreds of
clicks and drags, to size it (`-- <heap-KB> <rounds> 1` runs the same
`.zge` through the interpreter instead: it needs about 3.4 MB, against
72 KB compiled). The firmware needs about 24 KB of stack
(`esp32s3.ld` gives it 40 KB, and each frame's log line says how much it
used).

## A native Wayland window

The `zigulee-wayland` module shows windows on a Wayland compositor (Linux)
without SDL or libwayland: it speaks the protocol itself. Same interface
(`wayland.init()`, `wayland.Window.create(...)`, `window.run()`). Windows
draw with the software renderer into shared-memory buffers, paced by the
compositor, at the outputs' scale. The title bar is the compositor's where
it offers one; elsewhere (GNOME) a minimal one is drawn (drag to move,
double-click to maximize, a close button, resizing from the edges). The
keyboard uses libxkbcommon, loaded at run time: layouts, dead keys and
compose sequences, key repeat. The clipboard is the desktop's; screen
readers see the accessible items (AT-SPI). Build the examples with it:
`zig build run-gallery -Dbackend=wayland`.

## Full screen, without a desktop (KMS)

On embedded Linux (a kiosk, a device with a display), the `zigulee-kms`
module shows one window full screen, driving the display with kernel mode
setting and reading input from the kernel's event devices: no X server, no
compositor, no libdrm. Same interface (`kms.init()`,
`kms.Window.create(...)`, `window.run()`); the window takes the display's
preferred mode, divided by `ZIGULEE_SCALE` (default 1). It draws with the
software renderer and flips buffers at the display's refresh. Keyboards
use libxkbcommon when the system has it (`XKB_DEFAULT_LAYOUT`...), else a
US layout; mice get a hardware cursor; touchscreens act as a pointer.
Ctrl+Alt+Backspace closes the window. The display is the first card with a
connected screen, or `ZIGULEE_DRM_DEVICE`. The program needs the `video` and
`input` groups, and nothing else showing on the display. Build the examples
with it: `zig build run-gallery -Dbackend=kms`. Without a DRM display, the
window goes on the framebuffer device instead, if there is one (as below).

## Full screen on the framebuffer device (fbdev)

Some displays have no DRM driver: older kernels, vendor kernels, small SPI
panels driven by fbtft. The `zigulee-fbdev` module shows the window on the
framebuffer device (`/dev/fb0`, or `ZIGULEE_FB_DEVICE`), with the same
interface and the same input as KMS (`zigulee-evdev`, shared by both). It
draws with the software renderer and converts to the device's pixel format
(16, 24 or 32 bits of true colour: RGB565, RGB888, XRGB8888, BGR...; not
palettes or monochrome). When the driver can pan, it draws in a second
page and pans to it; otherwise it draws in place, which can tear. The
mouse cursor is drawn in software. The text console is put in graphics
mode meanwhile (the terminal the program runs on, else `/dev/tty0`), and
back in text mode at the end; if the program is killed, `kbd_mode` or a
reboot gives the console back. Where the kernel has a DRM driver for the
display, prefer KMS: it waits for the refresh and has a hardware cursor.
Build the examples with it: `zig build run-gallery -Dbackend=fbdev`.

### Displays mounted turned

A display mounted sideways or upside down is set with `ZIGULEE_ROTATION`
(or `Options.rotation`), the degrees the picture is turned clockwise: 90,
180 or 270. Both KMS and fbdev take it. The window is laid out and drawn
upright, at the turned size (a 480x800 panel turned 90 degrees gives an
800x480 window). It is turned only as it is copied to the screen, and
touches and mouse motion are turned back to match.

That is much cheaper than turning the content in `.zge` (`rotation: 180`
on the root element): there, the software renderer draws every pixel
through a transform, every frame. Turning while copying costs little: for
180 degrees, the pixels are copied in reverse order.

```sh
ZIGULEE_ROTATION=180 ./app
```

A touch panel that covers only part of the screen (a display showing the
top 128 rows of a 480x272 framebuffer) is set with `ZIGULEE_TOUCH_AREA`
(or `Options.touch_area`): the rectangle it covers, `WxH+X+Y` in screen
pixels before the rotation. The panel's range is spread over that
rectangle, then turned back over the whole screen. Upside down, those
128 rows show the window's rows 144 to 271, and touches land there.

```sh
ZIGULEE_ROTATION=180 ZIGULEE_TOUCH_AREA=480x128+0+0 ./app
```

## A native X11 window

The `zigulee-x11` module shows windows on an X server (Linux, BSDs; Wayland
desktops through XWayland) without SDL, Xlib or xcb: it speaks the X11
protocol itself. Same interface (`x11.init()`, `x11.Window.create(...)`,
`window.run()`). Windows draw with the software renderer and are scaled by
the desktop's `Xft.dpi`; keys follow the server's keyboard layout (Shift,
Caps Lock, AltGr), the clipboard is the desktop's, and screen readers see
the accessible items (AT-SPI). Input methods and dead keys are not
supported yet. Build the examples with it: `zig build run-gallery
-Dbackend=x11`.

## In a browser (WebAssembly)

The `zigulee-wasm` backend runs an app in a `<canvas>`. Build it for
`wasm32-freestanding` (`.entry = .disabled`, `.rdynamic = true`); create the
UI in an exported `zigulee_main`:

```zig
const wasm = @import("zigulee-wasm");
pub const std_options = wasm.std_options; // logs go to the console
pub const panic = wasm.panic;

export fn zigulee_main() void {
    const app = ui.App.create(wasm.allocator) catch return;
    app.window().default_font.set(&font);
    wasm.show(app.window());
}
```

and load it with the glue, `zigulee.js`:

```html
<canvas id="app" style="width: 460px; height: 640px"></canvas>
<script type="module">
  import { start } from "./zigulee.js";
  start({ wasm: fetch("app.wasm"), canvas: document.getElementById("app") });
</script>
```

The canvas follows its CSS size at the display's pixel density, takes the
keyboard when clicked (through a hidden text area, so input methods work:
composed text shows in the field, the candidate window at the caret),
shows the cursors the interface asks for, and copies to the browser's
clipboard (pasting types the text). Frames are
drawn only when something changes: with WebGL2 (the GPU renderer) where the
browser has it, else with the software renderer; `start({ ..., renderer:
"software" })` or `"webgl2"` chooses, and `start` returns which is used. `zig build web` builds the gallery this
way into `zig-out/web`: serve that directory (for example
`python3 -m http.server -d zig-out/web`) and open it.

## Your own event loop

Without a backend (another windowing library, a microcontroller, tests),
the application drives the window. The core never reads a clock: the loop
gives it the time.

```zig
const window = app.window();
window.setSize(.{ .width = 320, .height = 240 });

while (running) {
    zigulee.updateTimersAndAnimations(now_ms); // timers fire, animations advance
    // Input from the platform:
    window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 10, .y = 20 } } });
    window.dispatchKey(.pressed, .{ .text = "a" });
    zigulee.runChangeHandlers(); // `changed` handlers
    // Redraw what changed (see below), then wait: for the next frame while
    // zigulee.hasActiveAnimations(), else until zigulee.nextTimerDeadline() or
    // the next input event.
}
```

Everything runs on one thread. Work done on other threads must hand its
results to the UI thread (through your own queue) before touching
properties.

## Rendering

`zigulee.software.Renderer(P)` draws a window into a pixel buffer, `P` being
`zigulee.core.Rgba8` (premultiplied) or `zigulee.software.Rgb565`:

```zig
var renderer: zigulee.software.Renderer(zigulee.core.Rgba8) = .init(gpa);
defer renderer.deinit();
const pixels = try gpa.alloc(zigulee.core.Rgba8, width * height);
defer gpa.free(pixels);
// .partial redraws only what changed since the last call (the buffer must
// keep its contents); .full redraws everything.
const dirty = try renderer.renderWindow(app.window(), .init(pixels, width, height), .partial);
```

Glyphs are hinted lightly (the x-height on whole pixels) and their stems
darkened slightly at small sizes, for crisper, less washed-out small text;
`renderer.glyphs.options = .{ .hinting = false, .stem_darkening = false }`
draws the plain outlines (`batcher.glyphs.options` for the GPU renderer).

`dirty` is the region that changed, to send to the display. Devices without
a framebuffer render a few lines at a time with `renderWindowInBands`.
`zigulee.core.png.encode` saves pixels as a PNG (for screenshots and tests).

With an OpenGL 3.3 (core) or OpenGL ES 3.0 context of your own,
`zigulee.gpu.gl.Renderer` draws with the GPU instead (the context must be
current in every call):

```zig
const functions = try zigulee.gpu.gl.Functions.load({}, struct {
    fn f(_: void, name: [*:0]const u8) ?*const anyopaque {
        return @ptrCast(c.SDL_GL_GetProcAddress(name)); // or eglGetProcAddress...
    }
}.f);
var gl: zigulee.gpu.gl.Renderer = try .init(gpa, functions);
defer gl.deinit();
gl.setScaleFactor(2);
gl.framebuffer = 0; // the default framebuffer, or one of yours
// Each frame: what changed (.full the first time, or to redraw all of it).
const dirty = try gl.renderWindow(app.window(), width, height, .partial);
if (!dirty.isEmpty()) swapBuffers(); // nothing changed: nothing drawn
```

Frames are drawn into a texture that keeps the last one, so only what
changed is redrawn; the whole texture is then copied to the framebuffer.
The CPU only records and batches the draw calls (a 920x1280 frame of the gallery takes about 60 µs, against
about 5 ms drawn by the software renderer). Rectangles are shaded exactly
on the GPU, glyphs and path masks are rasterized once into a texture
atlas, images are uploaded once (images are compared by identity, as
`Image.eql`: change the pixels of a shown image by making a new one).

## Running `.zge` without compiling

The `zigulee-interpreter` module runs `.zge` source at run time, as the
viewer and the editor preview do. Values are dynamically typed
(`Value`):

```zig
const interp = @import("zigulee-interpreter");

const program = switch (try interp.Program.load(gpa, "app.zge", source, .{})) {
    .program => |p| p,
    .errors => |text| {
        std.debug.print("{s}", .{text});
        gpa.free(text);
        return;
    },
};
defer program.destroy();
const app = try program.create(program.mainComponent().?);
defer app.destroy();
app.property("count").?.set(.{ .int = 5 });
_ = app.invoke("reset", &.{});
const window = app.window().?; // show it like any zigulee.Window
```

## Microcontrollers

The core, the software renderer and generated code compile for bare-metal
targets (`zig build check-mcu`; `zig build mcu-size` builds a whole UI for
a Cortex-M4). There is no operating system, so the application provides
what the standard library would:

```zig
// Panics stop (no messages or stack traces).
pub const panic = std.debug.no_panic;

// zigulee logs warnings (e.g. change handlers that keep triggering each
// other): send them to a UART, or drop them.
pub const std_options: std.Options = .{
    .logFn = struct {
        fn log(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}
    }.log,
};
```

Allocate from a fixed buffer (`std.heap.FixedBufferAllocator`), and
render with `renderWindowInBands` into a small buffer of a few lines.

Shaping with fonts' OpenType tables (Arabic forms and ligatures, mark
positioning) is about 25 KB of code. Leave it out with, in the root file:

```zig
pub const zigulee_options = .{ .opentype_shaping = false };
```

Right-to-left text is still shown in order, and Arabic letters still
join, with the presentation forms the font maps (U+FB50–FDFF,
U+FE70–FEFF). Lines are shaped up to 64 characters on bare metal (256
elsewhere); longer ones are shown unshaped.

Rotating and scaling items (`rotation`, `scale`) is about 18 KB of code
with the software renderer. Leave it out with `.transforms = false` in
the same options: items are then drawn, and hit, where they are laid out.

TrueType fonts are large for flash. Pre-render the sizes and characters
the UI uses instead, at build time, and open the result like any font:

```zig
// build.zig
const font = zigulee.bitmapFont(b, .{
    .font = b.path("fonts/Inter-Regular.ttf"),
    .sizes = &.{ 13, 16, 40 },             // the font sizes the UI uses
    .chars = "20-7e,b0,2026",             // printable ASCII, °, …
    // For Arabic, add the letters and their presentation forms:
    // "600-6ff,fe70-fefc".
    .tool = zigulee_dep.artifact("zigulee-bitmap-font"),
});
exe.root_module.addAnonymousImport("ui_font", .{ .root_source_file = font });

// main.zig
const font: zigulee.Font = try .init(@embedFile("ui_font")); // read in place
```

Text is laid out exactly as with the TrueType font (same advances and
kerning); the glyphs are images, 4 bits per pixel. A size the font does
not have uses the nearest one's images.
[tools/mcu_demo.zig](../tools/mcu_demo.zig) is a complete example. There
is no display or touch driver yet (see the ROADMAP).

## Accessibility

On macOS, windows shown with `zigulee-sdl3` are visible to VoiceOver: each
accessible element (see the [language guide](language.md#accessibility))
is an NSAccessibility element, updated as the interface changes, and
VoiceOver can press, toggle, adjust and type into them. The bridge works
only while VoiceOver runs; set `ZIGULEE_ACCESSIBILITY=1` to inspect the tree
with Accessibility Inspector without it. Windows and Linux are not
supported yet.

Other backends read the same information with
`zigulee.core.accessibility`: a `Tracker` keeps a snapshot of a window's
accessible items (role, label, value, states, bounds, parent) and reports
when it changes; `perform` and `setValue` act on them.

## Binding loops

A binding that depends on itself (`width: self.width + 1px`) is a binding
loop. By default it panics with a message. Tools that run code being
edited set `zigulee.core.setBindingLoopHandler` to report it instead: the
read in the loop then gives the property's previous value.
