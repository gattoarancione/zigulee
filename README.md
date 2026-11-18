<p align="center">
  <img src="zigulee.png" alt="zigulee" width="420">
</p>

<p align="center"><strong>superfast declarative application framework</strong></p>

A declarative application framework for Zig, in the spirit of
[Slint](https://slint.dev) and [QML](https://doc.qt.io/qt-6/qmlapplications.html):
a markup language compiled to Zig at build time, a reactive property system,
and renderers that scale from desktop GPUs down to microcontrollers.

Requires **Zig 0.16.0**. **Documentation:** [docs/](docs/README.md),
starting with [getting started](docs/getting-started.md).

## Status

Pre-1.0: complete enough to build real applications, with APIs that may
still change. Continuous integration builds and tests it on Linux, macOS
and Windows.

| Platform | Backends | Rendering |
|---|---|---|
| macOS | AppKit (native), SDL3 | Metal, software |
| Windows | Win32 (native), SDL3 | Direct3D 12 (native), OpenGL or Vulkan (SDL3), software |
| Linux | X11, Wayland, KMS (no desktop), SDL3 | OpenGL or Vulkan (SDL3), software |
| iOS, iPadOS, Mac Catalyst | UIKit | Metal, software |
| Web | WebAssembly | WebGL, software |
| Microcontrollers | bare metal (ESP32-S3, Cortex-M) | software, line by line |

- **Language and tools:** the `.zge` compiler, a live viewer that reloads
  on save, a language server, a formatter, a VS Code extension with a live
  preview, and a C API.
- **Widgets:** about 45 standard widgets, from buttons, lists, tables and
  trees to menus, dialogs, date pickers, charts and a virtual keyboard, in
  four styles (Fluent, Cupertino, Material, minimal), light and dark.
- **Beyond widgets:** animations and states, perspective tilts, 3D scenes,
  translations, accessibility (VoiceOver, UI Automation, AT-SPI), audio
  and video playback, microphone and camera, HTTP and JSON, web views,
  drag and drop, file dialogs, settings, tray icons and notifications.
- **Next:** sensors, location, Android. See
  [ROADMAP.md](ROADMAP.md) and [ROADMAP-QT.md](ROADMAP-QT.md) (the gaps
  to Qt Quick).

## Layout

```
src/zigulee.zig        public API root
src/core/            runtime: properties, animations, timers, items, layout, input, windows
src/compiler/        the .zge compiler (zgec) and formatter
src/lsp/             the language server (zigulee-lsp)
src/interpreter/     the .zge interpreter (zigulee-viewer)
src/renderers/       the software renderer and the GPU one (OpenGL, Vulkan)
src/backends/        platform backends: SDL3, macOS, iOS, Windows, X11, Wayland, KMS, the web
src/widgets/         standard widgets in .zge (common/) and their styles
editors/vscode/      VS Code extension
tools/               build-time helpers, checks, the fuzz driver and docgen
docs/                documentation
examples/            runnable examples
```

## Build

```sh
zig build test          # unit and golden-image tests
zig build test -Dupdate-golden  # accept new rendering output (review tests/golden!)
zig build run-counter   # headless counter example
zig build run-animation # timer + bouncing animation, printed per frame
zig build run-layout    # layout, input and partial redraws, printed per frame
zig build run-list      # repeated rows in a Flickable: tap, drag, flick
zig build run-screenshot -- out.png [font.ttf]  # render a card UI to a PNG (bundled fonts by default)
zig build run-hello     # an app written in .zge (examples/hello.zge)
zig build run-gallery -Doptimize=ReleaseFast    # the gallery, written in .zge (examples/gallery.zge)
zig build run-todo      # a todo list: .zge UI, list model owned by Zig, Italian with -- --lang it
zig build run-patrisio  # a side-scrolling platformer written entirely in .zge, with sound (examples/patrisio.zge)
zig build run-video     # a VideoPlayer playing a clip, or a file: zig build run-video -- movie.mp4
zig build test-sdl3     # SDL3 backend tests (headless)
zig build check-mcu     # compile the core for a bare-metal Cortex-M4
zig build docs          # regenerate docs/reference from the sources
zig build fuzz -- 20000 # run the fuzz targets on random inputs
zig build bench         # benchmarks against their budgets (ReleaseFast)
zig build mcu-size      # code size and RAM of a UI on a Cortex-M4 (heap measured with Node.js)
zig build run-c-hello   # the C API (libzigulee, include/zigulee.h) from C
zig build web           # the gallery for the browser, in zig-out/web (serve it, e.g. python3 -m http.server -d zig-out/web)
zig build               # also installs zgec, zigulee-lsp, zigulee-viewer, libzigulee and zigulee.h in zig-out
```

## The reactive core

```zig
const zigulee = @import("zigulee");

const App = struct {
    width: zigulee.Property(f32) = .init(100),
    height: zigulee.Property(f32) = .init(50),
    area: zigulee.Property(f32) = .init(0),

    fn computeArea(self: *App) f32 {
        return self.width.get() * self.height.get();
    }
};

// Components are heap-allocated: properties must not move once bound.
const app = try gpa.create(App);
app.* = .{};
try app.area.setBinding(gpa, app, App.computeArea);
app.width.set(200); // area is marked dirty, recomputed on next get()
```

- **`Property(T)`**: dependencies are discovered at runtime. Changes mark
  dependents dirty right away, and bindings re-run on the next read. Binding
  loops are detected. Steady-state re-evaluation does not allocate.
- **`linkTwoWay`**: the `<=>` construct. Both properties share one storage.
- **`ChangeTracker(T)`**: the `changed prop => {}` construct. Its handlers run
  from `runChangeHandlers()`.
- **`PropertyTracker`**: tracks which properties a function reads and reports
  when any of them changes. Renderers will use this to decide what to repaint.
- **`Callback(fn (Args...) Ret)`**: typed callback slots.
- **`Model(T)` / `VecModel(T)`**: row data for `for` repeaters, with row-level
  change notifications.
- **`setAnimated` / `setAnimatedBinding`**: the `animate prop { ... }`
  construct. Animations read the UI clock as a property, so they re-evaluate
  every frame while running and stop costing anything once finished.
- **`Timer`**: single-shot or repeated, driven by the same clock.

The core never reads a platform clock (bare-metal targets have none). The
event loop advances it:

```zig
zigulee.updateTimersAndAnimations(now_ms); // advance clock, fire due timers
// ... dispatch input ...
zigulee.runChangeHandlers();
// ... render; keep requesting frames while zigulee.hasActiveAnimations(),
//     otherwise sleep until zigulee.nextTimerDeadline() or the next event ...
```

## Items, layout and windows

A window owns a tree of items. Each built-in item embeds an `Item` header
with geometry properties, and layouts work by putting bindings on their
children's geometry:

```zig
var window: zigulee.Window = undefined;
window.init(gpa, .{ .width = 160, .height = 100 });

var column: zigulee.items.BoxLayout = .vertical();
var label: zigulee.items.Text = .{};
var button: zigulee.items.Rectangle = .{};

window.rootItem().appendChild(&column.item);
column.item.appendChildren(&.{ &label.item, &button.item });
column.setPadding(10);
try column.setup(gpa);            // bind the children's geometry
try column.item.fillParent(gpa);  // the layout follows the window size

window.dispatchPointer(.{ .pressed = .{ .position = .{ .x = 80, .y = 70 } } });
const dirty = try window.render(renderer, .partial); // redraws only what changed
```

Rendering records each item's visual dependencies and a hash of what it drew.
The next `render` then repaints only the items whose pixels actually changed,
plus the areas that removed items leave behind.

`Repeater` (`for`) and `Conditional` (`if`) create and destroy component
instances from a `Model` or a condition. Inside a layout, their instances are
laid out as if they were the layout's own children. `Flickable` scrolls its
content: a tap still reaches the buttons inside it, while a drag takes over
the gesture and scrolls.

## Software rendering

`zigulee.software.Renderer(P)` turns a window into pixels, with `P` being
`Rgba8` (premultiplied) or `Rgb565`:

```zig
var renderer: zigulee.software.Renderer(zigulee.core.Rgba8) = .init(gpa);
defer renderer.deinit();
// A framebuffer that keeps its contents: only what changed is redrawn.
const dirty = try renderer.renderWindow(&window, .init(pixels, width, height), .partial);
```

Devices without a framebuffer render a few lines at a time with
`renderWindowInBands`, handing each finished band to the display driver. It
supports anti-aliased rounded rectangles and borders, linear and radial
gradients, SVG paths (fill and stroke), images (PNG decoding, fit modes,
nine-slice, colorize) and text.

## Text

Fonts are TrueType files (`.ttf` or `.ttc`), read directly in Zig with no C
libraries. The library does not ship a font; your application provides one.
The examples use the openly licensed fonts in [`examples/fonts`](examples/fonts):

```zig
const font = try zigulee.core.Font.init(@embedFile("Inter-Regular.ttf"));
window.default_font.set(&font);   // used by every Text without its own font
label.font.set(&font);            // or per item
```

Text supports newlines, word wrapping, kerning (from GPOS, or the legacy
`kern` table), light hinting and stem darkening for crisp small text,
fallback fonts, eliding, right-to-left text (the Unicode
bidirectional algorithm) with shaping from the font's OpenType tables
(Arabic joining forms, ligatures, mark positioning), and
horizontal and vertical alignment. Layout and rendering use the same font
metrics, so measured sizes match what is drawn. Without a font, text is
measured approximately and not drawn. `StyledText` shows rich text from a
Markdown subset (bold, italic, code, links, headings, lists).

## Windows (SDL3, or native on macOS)

The `zigulee-sdl3` module shows a `zigulee.Window` in a desktop window on macOS,
Windows and Linux. SDL is built from source by the Zig package manager on
first use; macOS builds need Xcode installed.

```zig
const sdl3 = @import("zigulee-sdl3");

try sdl3.init();
defer sdl3.deinit();
const window = try sdl3.Window.create(gpa, &ui_window, .{ .title = "Hello" });
defer window.destroy();
try window.run(); // returns when the window is closed
```

The event loop sleeps until there is something to do: an input event, the
next timer, or the next frame of a running animation (paced by vsync).
Windows draw with the GPU renderer (Metal on macOS, else OpenGL 3.3) where
available, else with
the software renderer, which redraws only what changed and uploads only
those pixels; both give the same pixels. The display scale (Retina, HiDPI)
is applied automatically. The software renderer is much faster in release
builds (`-Doptimize=ReleaseFast`).

On macOS, the `zigulee-macos` module does the same with AppKit directly, with
no SDL (same interface; `zig build run-gallery -Dbackend=macos` builds the
examples with it). On Windows, `zigulee-windows` does it with Win32 and
Direct3D 12 (`-Dbackend=windows`); on Linux, `zigulee-wayland` and `zigulee-x11` talk
to the compositor or the X server directly (`-Dbackend=wayland`, `x11`),
and `zigulee-kms` shows an app full screen with no desktop at all (embedded
Linux: `-Dbackend=kms`; `zigulee-fbdev`, `-Dbackend=fbdev`, on the
framebuffer device of displays without a DRM driver). On iPhone and iPad, `zigulee-ios` shows it with
UIKit (`zig build ios -Dtarget=aarch64-ios-simulator` makes the examples'
app bundles; `aarch64-maccatalyst` runs them on a Mac).

## The `.zge` language

UIs can be written declaratively, as in Slint or QML, and compiled to Zig at
build time:

```
component Button inherits Rectangle {
    var in <string> text;
    callback clicked();
    height: 40px;
    border-radius: 8px;
    background: touch.pressed ? #3730a3 : #6366f1;
    animate background { duration: 120ms; }
    Text { text: root.text; color: white; horizontal-alignment: center; vertical-alignment: center; }
    touch := TouchArea { clicked => { root.clicked(); } }
}

export component Hello inherits Window {
    width: 360px;
    height: 260px;
    var in-out <int> count: 0;
    var in <[string]> names: ["Ada", "Grace", "Linus"];
    VerticalLayout {
        padding: 24px;
        Text { text: "Count: \{count}"; }
        Button { text: "+1"; clicked => { count += 1; } }
        for name[i] in names : Text { text: "\{i + 1}. \{name}"; }
        if count >= 10 : Text { text: "Double digits!"; }
    }
}
```

In `build.zig`, `uiModule()` runs the compiler and gives you a module:

```zig
const ui = @import("zigulee").uiModuleFromDependency(b, zigulee_dep, b.path("app.zge"), target, optimize);
exe.root_module.addImport("ui", ui);
```

Each component becomes a Zig struct with its properties, callbacks and
elements as fields. Model properties take any `zigulee.Model`, such as a
`VecModel`, and rows follow its changes:

```zig
const app = try ui.Hello.create(gpa);
defer app.destroy();
app.count.set(5);
app.names.set(my_vec_model.model());
app.window().default_font.set(&font);
```

Errors point at the source:

```
app.zge:12:21: error: expected a length: add a unit, like 10px
        border-radius: 8;
                       ^
```

Beyond components, properties and bindings, the language has `for` and
`if`, `struct` and `enum` declarations, `states`, `changed` handlers,
`animate`, and the built-in elements Rectangle, Text, StyledText,
TextInput, Image (`@image-url(...)`: PNG, GIF or SVG, embedded at build
time; or `source-url`, a file or `http(s)://` URL loaded in the
background), Path, TouchArea, FocusScope, Flickable, Timer, and the
Horizontal, Vertical, Grid and Flow layouts.
Fonts are registered from Zig and chosen with `font-family` and
`font-weight`:

```zig
try app.window().registerFont("Inter", 400, &regular);
try app.window().registerFont("Inter", 700, &bold);
```

Components and globals can live in other files. A `global` is a singleton
whose properties every component can read and write:

```
// theme.zge
export global Theme {
    var in-out <bool> dark;
    var out <color> text: dark ? #f1f5f9 : #0f172a;
}

// app.zge
import { Theme } from "theme.zge";
export component App inherits Window {
    var in-out <bool> dark <=> Theme.dark;
    Text { text: "Hello"; color: Theme.text; }
}
```

Standard widgets are built in, written in `.zge` themselves:

```
import { Button, CheckBox, Slider, Palette } from "std-widgets.zge";

export component Preferences inherits Window {
    background: Palette.background;
    var in-out <bool> dark <=> Palette.dark;
    VerticalLayout {
        padding: 12px;
        spacing: 8px;
        CheckBox { text: "Dark mode"; checked <=> root.dark; }
        Slider { maximum: 10; changed(v) => { debug(v); } }
        Button { text: "Apply"; primary: true; }
    }
}
```

The standard widgets: Button, CheckBox, Switch, RadioButton (and
ButtonGroup), Slider, RangeSlider, Dial, SpinBox, ProgressIndicator,
Spinner, LineEdit (also for passwords), TextEdit, ComboBox, ScrollView,
ScrollBar, ListView (rows recycled, in sections), GridView,
StandardListView, TableView (rows of cells), StandardTableView,
TabWidget, DatePicker, Tumbler (a wheel picker), ToolTip, Menu (and
context menus), MenuBar, ToolBar (with ToolButton and ToolSeparator),
GroupBox, Frame, Pane, PageIndicator, TreeView, Drawer, Dialog,
MessageDialog, VirtualKeyboard (on-screen, for touch screens),
VideoPlayer, and Sound and Music. They come in four
styles, chosen at build time (`UiOptions.style`, `zgec --style=`):
`fluent` (Windows 11, the default), `cupertino` (macOS), `material`, and
`minimal` (flat and black and white, for small displays and
microcontrollers); `native` picks the target system's (cupertino on
Apple's, fluent elsewhere). Their colors are in the `Palette` global
(`Palette.dark` switches to dark mode) and their sizes in `Style`. Text
fields support selection with keyboard and mouse, undo/redo, the clipboard
and input methods.

Components can take children where they mark `@children`, and declare
functions:

```
component Card inherits Rectangle {
    var in <string> heading;
    VerticalLayout {
        Text { text: root.heading; }
        @children
    }
    public function flash() { background = yellow; }
}
```

`examples/gallery.zge` is a complete app made of the standard widgets
(`zig build run-gallery -Dstyle=material` for another style). See
ROADMAP.md (Phases 5 and 6) for the details.

## Editor support

`zigulee-viewer app.zge` (or `zig build run-viewer -- app.zge`) shows a
`.zge` file in a window without compiling Zig: it is interpreted, and
reloaded whenever you save it or a file it imports; errors show in the
window until fixed.

`zgec fmt file.zge` formats `.zge` files (`--check` lists unformatted
files, `--stdin` filters). `zigulee-lsp` is a language server: errors as you
type, completion, hover, go to definition, find references, rename, outline
and formatting. `editors/vscode` is a VS Code extension using it; see its
README; its live preview ("zigulee: Show Live Preview") runs the file you
are editing next to it, updates as you type, and lets you Alt+click an
element to jump to its source and edit its properties live. Other editors
can run `zigulee-lsp` (stdio) for `*.zge` files.

## License

MIT, see [LICENSE](LICENSE). The fonts in [`examples/fonts`](examples/fonts)
keep their own license, the SIL Open Font License.
