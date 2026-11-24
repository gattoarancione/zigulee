# zigulee — Roadmap to Qt Quick parity

What zigulee (`.zge`, the builtins and `std-widgets.zge`) lacks compared with
Qt Quick, QML and Qt Quick Controls (Qt 6), in the order to close the gaps:
what typical applications need first. The main roadmap is
[ROADMAP.md](ROADMAP.md).

Legend: ✅ done · 🟡 partial · ❌ missing.

---

## Where zigulee stands

### Widgets (Qt Quick Controls → `std-widgets.zge`)

| Qt Quick Controls | zigulee | |
|---|---|---|
| Button, CheckBox, Switch, Slider, SpinBox, ComboBox, TextField, TextArea, ProgressBar, BusyIndicator, TabBar, ScrollView, Tumbler | Button, CheckBox, Switch, Slider, SpinBox, ComboBox, LineEdit, TextEdit, ProgressIndicator, Spinner, TabWidget, ScrollView, Tumbler | ✅ |
| ListView | ListView (rows recycled, sections with a pinned header, rows all as tall or each its own height), StandardListView (no highlight animation) | ✅ |
| TableView, HorizontalHeaderView | TableView (TableRow cells, rows recycled, sorting header), StandardTableView (no column resizing) | ✅ |
| Calendar / MonthGrid | DatePicker | 🟡 |
| Popup | PopupWindow (no modal dimming, no enter/exit transitions) | 🟡 |
| MediaPlayer + VideoOutput / SoundEffect | Video, VideoPlayer, Audio, Sound, Music (playback only) | 🟡 |
| RadioButton, ButtonGroup | RadioButton, ButtonGroup (for a model of strings) | ✅ |
| RangeSlider, Dial | RangeSlider, Dial | ✅ |
| ScrollBar, ScrollIndicator (on their own) | ScrollBar (on its own too) | ✅ |
| ToolTip | ToolTip | ✅ |
| Menu, MenuBar, MenuItem, context menus | Menu, MenuBar (native on macOS), MenuBarItem, MenuItem, submenus | ✅ |
| ToolBar, ToolButton, ToolSeparator | ToolBar, ToolButton, ToolSeparator | ✅ |
| Dialog, DialogButtonBox | Dialog (buttons as labels, a default and a cancel one) | ✅ |
| MessageDialog | MessageDialog | ✅ |
| FileDialog, FolderDialog | FileDialog (open, open several, folder, save) | ✅ |
| ColorDialog, FontDialog | — | ❌ |
| Drawer | Drawer (any edge, pulled out by a drag from it) | ✅ |
| StackView, SwipeView, PageIndicator | StackView (push, pop, clear; slide), SwipeView, PageIndicator | ✅ |
| SplitView | SplitView | ✅ |
| GroupBox, Frame, Pane, Page, Label | GroupBox, Frame, Pane (Text for Label; no Page) | 🟡 |
| TreeView | TreeView (rows with depths; TreeState for custom ones) | ✅ |
| DelayButton, RoundButton, ItemDelegate family | — | ❌ |
| Styles: Basic, Fusion, Material, Universal, Imagine, native macOS/Windows | fluent (Windows 11), cupertino (macOS), material, minimal; `native` by target | ✅ |

### Elements (Qt Quick → builtins)

| Qt Quick | zigulee | |
|---|---|---|
| Item, Rectangle (gradients, borders, radius, clip), Text (wrap, elide), Image, MouseArea/TapHandler, FocusScope/Keys, Flickable, Timer, TextInput | Empty, Rectangle, Text (letter spacing, fitted to its box), Image, TouchArea, FocusScope, Flickable, Timer, TextInput | ✅ |
| Shape / ShapePath | Path (SVG path data) | ✅ |
| RowLayout, ColumnLayout, GridLayout | HorizontalLayout, VerticalLayout, GridLayout | ✅ |
| Repeater | `for` | ✅ |
| Loader | Loader (`source`, `active`, inputs by name) | ✅ |
| Window | Window (several with SDL; `fullscreen`, `maximized`, `minimized`, `always-on-top`, two-way) | ✅ |
| WheelHandler | Flickable's wheel, TouchArea scroll events | 🟡 |
| BorderImage | `@image-url("x.png", nine-slice(...))` | ✅ |
| PointHandler, DragHandler, PinchHandler (multi-touch) | PinchArea, SwipeArea, touches as the mouse (no PointHandler) | 🟡 |
| DragArea, DropArea, drag and drop (in the app, from the OS) | DragArea, DropArea; files and text dropped from other applications (no drags out to them) | 🟡 |
| Transforms: rotation, scale, Translate, Matrix4x4 | `rotation`, `scale`, `transform-origin-*`, `rotation-x`, `rotation-y` and the parent's `perspective` (no arbitrary matrices) | ✅ |
| Anchors | `anchors.left`, `right`, `top`, `bottom`, `horizontal-center`, `vertical-center`, `fill`, `center-in`, margins and offsets, to the parent or a sibling (no baseline) | ✅ |
| StackLayout | StackLayout | ✅ |
| Row, Column, Flow, Grid positioners | the layouts, FlowLayout | ✅ |
| GridView, PathView | GridView (no PathView) | 🟡 |
| Canvas (2D drawing from script) | `Canvas` with a `paint` handler: paths (lines, curves, arcs, rectangles, rounded rectangles, ellipses), fill, stroke, clip, text, images, transforms, save/restore, global alpha; painted again on resize, on changes to what it read, and on `request-paint()` (no line caps, joins or dashes, no pixel access, no partial `clear-rect`) | ✅ |
| ShaderEffect, MultiEffect (shadow, blur, colorize, mask) | Rectangle `drop-shadow-*`, `blur` on any element, Image `colorize`, opacity layers, `clip-path`, `mask-image` and `mask-source` (OpacityMask, from an image or an element, inverted too) on any element (no custom shaders) | 🟡 |
| AnimatedImage, AnimatedSprite | AnimatedImage (GIF, animated PNG); no sprite sheets | 🟡 |
| Rich text (HTML/Markdown subsets) | StyledText (Markdown or HTML subsets: bold, italic, strikethrough, underline, code, links, images, headings, lists, tables, colors, fonts and alignment from HTML and stylesheets, floating images; selectable, by words and paragraphs too) | ✅ |
| SVG images | `@image-url("x.svg")`: shapes, groups, transforms, fills, strokes, opacity, drawn as paths at any size, linear and radial gradients (no focal points), `use`, clip paths, masks, blur filters, text (one line, the Image's font) | 🟡 |
| Network images, asynchronous loading | Image `source-url` (files, `http(s)://`), loaded and decoded on a thread, `status` | ✅ |

### Language (QML → `.zge`)

| QML | `.zge` | |
|---|---|---|
| Properties, bindings, two-way, signals/handlers, functions, enums, value types, singletons, imports | `var` declarations, bindings, `<=>`, callbacks, functions, enums, structs, `global`, imports | ✅ |
| `onXChanged` | `changed x =>` (batched) | ✅ |
| Behavior, NumberAnimation, ColorAnimation | `animate` (duration, delay, easing, iterations) | ✅ |
| Translations (`qsTr`, plurals) | `@tr` with plurals | ✅ |
| States and Transitions | `states` with in/out animations (no state groups); `StateMachine` with SCXML semantics (events, guards, entry and exit actions, `after`; flat for now: nesting, history and parallel regions planned) | 🟡 |
| Attached properties (`Layout.*`, `Keys.*`) | plain properties (`row`, `col`, constraints) | 🟡 |
| ListModel, ObjectModel, proxy models | `[T]`, `Model(T)` from Zig, `filter`/`sort`/`reverse` in the language (no editable ListModel in `.zge`) | 🟡 |
| C++/Python integration (QObject) | Zig integration, C API | 🟡 different |
| SequentialAnimation, ParallelAnimation, SpringAnimation, SmoothedAnimation, scripted control | Sequential/Parallel/Property/PauseAnimation, start/stop/pause/resume, `spring()` easing (keeping its speed when retargeted, as SpringAnimation; no SmoothedAnimation) | 🟡 |
| JavaScript in handlers: loops, locals, arrays, objects | statements with `let`, `while`, `for`, `break`, `continue` (typed; no objects or array building) | 🟡 |
| `var`, `list<T>` of anything | typed only (a proposal: docs/proposals/var.md) | ❌ |
| Components as values (`Component`, delegates, `createObject`) | `component` type, component properties, Loader (no inline `Component {}` or `createObject`) | 🟡 |
| `Connections` | `Connections { target: x; }` and `x.callback => { }` | ✅ |

### Modules

| Qt | zigulee | |
|---|---|---|
| Multimedia playback | Audio/Video, mixer, platform decoders | ✅ |
| Accessibility | VoiceOver, UI Automation, AT-SPI | ✅ |
| Clipboard | ✅ | ✅ |
| Multimedia capture: microphone, camera, recording, device choice | `Microphone` (level, recording to an `audio` clip or a WAV file) and `Camera` (preview, pictures, PNG files), with the SDL3 backend (macOS, Windows, Linux) and the native macOS one (AVFoundation); the default devices only, no video recording; not with the native Windows and Linux backends yet | 🟡 |
| Qt Quick 3D | `View3D` with `Model` (cube, sphere, plane), `Node`, `PerspectiveCamera`, `DirectionalLight`, `PointLight`; metallic-roughness materials with a texture, glTF models (`.glb`), `clicked` on models (drawn by every GPU renderer; on the CPU with the native Linux backends, which draw in software); `rotation-x`, `rotation-y` and `perspective` on 2D elements | 🟡 |
| Qt Graphs / Charts | LineChart, BarChart, PieChart (one series each, stacked for more; hover and clicks by index; no axes or legends of their own, no animation) | 🟡 |
| WebView / WebEngine; `Qt.openUrlExternally` | `WebView` (WKWebView on macOS and iOS, WebView2 on Windows, WebKitGTK on Linux with X11, an `<iframe>` on the web; a native view above zigulee's content; not on Wayland or KMS), `open-url(url)` (SDL3, macOS, iOS, Windows, X11/Wayland, the web) | 🟡 |
| Location, Positioning; Map, MapView | `PositionSource` (the web, macOS and iOS); `MapView` (web tiles, OpenStreetMap's by default) with `MapItem` and `MapPolyline`; no geocoding, routing or vector tiles | 🟡 |
| Sensors | `Accelerometer`, `Gyroscope`, `Compass`, `OrientationSensor` (the web, the ESP32-S3 example; iOS, Linux and Windows waiting for CI) | 🟡 |
| Network (`XMLHttpRequest`, QNetwork) | `HttpRequest` (HTTP and HTTPS, any method, headers, body; in the background), `json-get`/`json-number`/`json-count`; images from URLs (not on the web or MCUs; no WebSockets, streaming or upload progress) | ✅ |
| Settings, StandardPaths | `Settings` (a component's properties kept in an INI file; in memory on the web and MCUs), `StandardPaths` | ✅ |
| System tray, notifications, global `Shortcut` | `Shortcut` (application-wide), `SystemTrayIcon` (icon, tooltip, menu, clicks: macOS, Windows, Linux with SDL3), `Notification` (title, body, clicks: macOS, Windows, Linux over D-Bus; outside an app bundle on macOS without clicks) | ✅ |
| Virtual keyboard | `VirtualKeyboard` in std-widgets (letters with Shift and Caps, two pages of symbols, repeating Backspace; one layout, English letters, no word prediction or other languages), `KeyboardInput` for other layouts | 🟡 |

### Platforms and tooling

| | Qt | zigulee |
|---|---|---|
| Desktop | Windows, macOS, Linux | ✅ Windows, macOS, Linux (X11, Wayland, KMS, fbdev), natively and through SDL3 |
| Web | WebAssembly | ✅ |
| Microcontrollers | Qt for MCUs (a separate product) | ✅ the same framework (ESP32-S3, Cortex-M) |
| Mobile | Android, iOS | 🟡 iOS (iPhone, iPad, Mac Catalyst); no Android |
| Native look | macOS and Windows styles | ❌ |
| Tooling | Qt Creator, Design Studio, qmllint, qmlformat, QML profiler | 🟡 LSP, formatter, live viewer, docs generator (no designer, linter, profiler) |

---

## Priorities

Each item is a step: built, tested, documented, in the gallery or an
example.

### P1 — Menus, dialogs, tooltips (what every desktop app needs)

- [x] **ToolTip**: text shown after hovering a while, above the element
      (kept in the window); input goes past it.
- [x] **Menu** (and context menus, from TouchArea's `right-clicked`): a
      popup list of items with text, shortcut hints, separators, check
      marks, disabled items, hover and keyboard navigation; opened at the
      pointer or under an element, kept in the window.
- [x] Submenus: a `MenuItem`'s `level` nests the items after it (as a
      TreeView's rows), opened beside their entry (hover, click, the arrow
      keys), on the side with room; nested menus in macOS's menu bar too.
- [x] **MenuBar** with **MenuBarItem**s: a row of menus in the window.
- [x] The native macOS menu bar: MenuBar's menus go to the bar at the top
      of the screen (after the application menu), with ⌘ shortcuts, check
      marks and disabled items kept up to date (PlatformMenu,
      PlatformMenuItem).
- [x] **Dialog**: a modal popup (the window dimmed and taking no input,
      Tab kept inside, Return for the default button, Escape for the cancel
      one) with a heading, content and a row of buttons; **MessageDialog**
      on top.
- [x] **FileDialog** (files, several files, a folder, a file to save):
      the platform's own (macOS NSOpen/SavePanel, Windows IFileDialog, Linux
      xdg-desktop-portal; SDL's on the SDL3 backend), through a backend
      interface like audio outputs and video decoders, with filters (Qt's
      `"Images (*.png *.jpg);;All files (*)"`), a start folder and a
      suggested name.

### P2 — Transforms and effects

- [x] `rotation`, `scale` (with a transform origin) on every element:
      rendering, hit testing, dirty regions, both renderers (the GPU
      backends sample glyphs bilinearly when turned). Optional on MCUs
      (`zigulee_options.transforms`, about 18 KB).
- [x] Drop shadows (`drop-shadow-offset-x/y`, `-blur`, `-color` on
      Rectangle and components built on one): a Gaussian-blurred rounded
      rectangle, computed per pixel (exact for square corners), in both
      renderers and all GPU backends; partial redraws cover the shadow.
- [x] A `blur` effect on any element's content, and opacity layers (an
      element and its children faded as one): layers in the display list,
      rasterized on the CPU into images (blurred by three box blurs) that
      every renderer draws, the GPU ones as textures; kept while their
      contents are the same. Partial redraws spread with the blur.
      Optional on MCUs (`zigulee_options.effects`).
- [x] Clipping to shapes: `clip: true` under a rotation clips to the
      turned rectangle and rounds its corners by `border-radius`;
      `clip-path` (SVG path data) cuts any element and its children, and
      `mask-image` shows them through an image's opacity (QML's
      OpacityMask; an SVG drawing's shapes), `mask-source` through an
      element's drawing, `mask-inverted` the other way; all as layers
      masked when rasterized, so every renderer shows the same, with no
      GPU shader of their own (a rounded clip only masks what reaches
      into its corners).
      Input follows the shapes (not an element's mask). `sin` and `cos` to
      build shapes in bindings.
- [x] BorderImage: `@image-url("x.png", nine-slice(...))` (1, 2 or 4
      borders, as CSS). AnimatedImage: GIF (a decoder of its own) and
      animated PNG, decoded frame by frame on the UI thread (`playing`,
      `speed`, `current-frame`, `frame-count`, `finished`); `@image-url`
      reads GIFs too. In the gallery's Effects tab.

### P3 — The language

- [x] Loops (`for x in model`, `for x[i] in model`, `for i in n`,
      `while`, `break`, `continue`) and local variables (`let`, typed or
      inferred, assignable, block-scoped) in handlers and functions,
      compiled and interpreted.
- [x] Components as values: the `component` type (a component's name as
      a value, `component` properties as delegates) and `Loader`, which
      creates the one its `source` names and passes it its other bindings
      by name (types checked at run time), compiled and interpreted.
- [x] `Connections`-like handlers for another element's callbacks:
      `target.callback => { }` and `Connections { target: x; enabled; }`,
      added to the callback's own handler (chained, taken out with their
      component, globals included), compiled and interpreted.
- [x] SequentialAnimation / ParallelAnimation, spring animations, animations
      started and stopped from code: PropertyAnimation (`target`, `from`,
      `to`), PauseAnimation, the two groups (`loops`, `running`, `paused`,
      `start()`, `stop()`, `pause()`, `resume()`, `finished`), and the
      `spring(bounce)` easing (also for `animate`), which keeps a number's
      speed when its target moves on the way (as Qt's SpringAnimation);
      compiled and interpreted.
- [x] Sorting and filtering models in the language: `model.filter(row =>
      cond)`, `.sort(row => key)` (numbers, bools, strings; stable),
      `.reverse()`, chained, following their source and what the function
      reads; compiled and interpreted.
- [x] Anchors, as QML's: `anchors.left` / `right` / `top` / `bottom` /
      `horizontal-center` / `vertical-center` to the parent's or a
      sibling's edges, `fill`, `center-in`, `margins` and each side's,
      center offsets; rewritten after parsing into `x`, `y`, `width` and
      `height` bindings (so compiled and interpreted alike), with errors
      for layouts, the root, other targets and clashing bindings;
      completion in the LSP. No baseline anchor.

### P4 — Input

- [x] Drag and drop within the application: DragArea (`kind`, `data`,
      `dragging`, `offset-x/y`, `started`, `finished(dropped)`, `clicked`)
      and DropArea (`accepts`, `contains-drag`, `drag-data`, `drag-x/y`,
      `entered`, `exited`, `dropped(data)`); Escape cancels; compiled and
      interpreted.
- [x] Drag and drop with the system, into the application: files (paths,
      one per line) and text dropped on DropAreas (`accepts: "file"` or
      `"text"`), hovering included, on macOS (NSDraggingDestination),
      Windows (OLE IDropTarget), X11 (XDND), Wayland (wl_data_device),
      SDL3 and the web (file names only). Not done: dragging out of the
      application to others.
- [x] Multi-touch gestures: touches (the first finger works as the
      mouse), PinchArea (two fingers or a trackpad: `pinch-scale`,
      `pinch-rotation`, center), SwipeArea (`swiped(direction)`, clicks
      still through); fingers from SDL3, Windows (WM_POINTER), Wayland
      (wl_touch), KMS (multi-touch slots) and the web; trackpad pinch and
      rotation on macOS and SDL3. Not done: X11 touches (XInput2).
- [x] Application shortcuts: `Shortcut { sequence: "Ctrl+S"; enabled;
      activated }`, after the focused element (Ctrl+C in a text field
      copies), `Ctrl` as Command on macOS; menu bar items' shortcuts work
      with the menus closed (the native macOS menu bar has its own).

### P5 — More widgets

- [x] RadioButton and ButtonGroup (radio buttons for a model's strings,
      `current-index`, arrow keys, vertical or horizontal).
- [x] StackView (`push(Page)`, `pop()`, `clear()`, sliding), SwipeView
      (dragged between pages, settling; `current-index`), PageIndicator,
      StackLayout; built-in functions take arguments.
- [x] SplitView (horizontal or vertical, handles dragged within the
      panes' minimums and maximums, shares kept when resized).
- [x] TreeView (rows with depths, expanded by arrows and keys; a current
      row), on TreeState (which rows show); `model.map(row => value)`.
- [x] RangeSlider, Dial.
- [x] ToolBar, ToolButton (text and/or icon, checkable), ToolSeparator.
- [x] GroupBox, Frame, Pane.
- [x] Drawer (from any edge, over the window dimmed; dismissed by a
      click outside, a swipe towards its edge, or Escape; pulled out by a
      drag from its edge, `interactive` and `drag-margin`, on
      PopupWindow's `open-swipe` and `edge-margin`).
- [x] ScrollBar on its own (`position`, `size`); GridView (cells wrapping
      in a ScrollView); FlowLayout.
- [x] ListView with delegate recycling (ListLayout: instances for the
      rows in view only, handed on as it scrolls) and sections (headers,
      the current one pinned); TableView with cell delegates (TableRow).
      Rows of different heights (`variable-row-height`: measured as they
      show, the rest estimated at their mean).

### P6 — Text and images

- [x] Rich text: StyledText, a Markdown subset (bold, italic, struck,
      code, links with `link-clicked`, headings, nested bullet and
      numbered lists, hard breaks, tables) or an HTML one (`format`);
      wrapped to its width or not (`wrap: no-wrap`, cut at the edge);
      `horizontal-alignment` line by line and `vertical-alignment` (as
      TextInput's, LineEdit's and TextEdit's `horizontal-alignment`);
      `selectable` (dragged, `selected-text`, Ctrl+C, Ctrl+A; double
      clicks select words, triple clicks paragraphs). Images
      (`![alt](url)`, `img src` with `width`, `height`, `alt`) loaded in
      the background as Image's `source-url`, wrapping as words, their
      `alt` text if they fail; colors and fonts from HTML (`font`,
      `span`, `mark`, `big`, `small`, `u`, and `style` on those and on
      blocks: color, background, family, size, weight, style,
      decoration); blocks' and cells' `align` and `text-align`
      (justified too), passed on by `div` and `center`, Markdown
      columns' `:---:`; `base-url` for relative image URLs (resolved as a
      browser does); images floated left or right, the text going round
      them; `style-sheet` and HTML's `style` elements (tags, classes,
      ids; Markdown styled as its HTML).
- [x] SVG images (`@image-url("x.svg")`): read at build time (or by the
      interpreter) into shapes drawn by the path renderer at the Image's
      size, fitted by `image-fit`, `colorize`d; linear and radial
      gradients (units, `gradientTransform`, `href`; radial ones as
      ellipses square to the drawing, without focal points); `use` and
      `symbol`, `clip-path`, `mask` (luminance), `filter` (Gaussian blur),
      each per shape; `text` on one line in the Image's font. Not done:
      other filter effects, `tspan` styles and positions, text on paths,
      patterns, markers, stylesheets.
- [x] Images loaded at run time: Image `source-url` (a path, `file://`,
      `http://` or `https://`), fetched and decoded (PNG, GIF, SVG) on a
      thread of its own, `status` (`loading`, `ready`, `error`),
      `progress`, `source-headers`; Images of the same URL share one load
      and picture, kept a while after (32 MB); `core.image_loader` for
      Zig.
- [x] Gradients in `.zge`: `@linear-gradient(angle, color position, ...)`
      and `@radial-gradient(circle, ...)` wherever a brush goes, as CSS
      writes them (stops without positions spread out); colors,
      positions and angle bound like any value (a buffer per gradient in
      generated code), blended when animated; `deg` for angles.
- [x] Tiled images: `image-fit: tile`, `tile-horizontally`,
      `tile-vertically` (as Qt's fill modes), for PNGs (a quad per tile
      shown on the GPU) and SVG drawings (up to 1024 tiles).
- [x] Letter spacing: `letter-spacing` on Text, TextInput and
      StyledText (Qt's `font.letterSpacing`), in measuring, wrapping,
      eliding, carets and selection (not inside joined scripts' cursive
      attachments, nor after marks).
- [x] Text fitted to its box: `font-size-mode` (`fixed`, `horizontal-fit`,
      `vertical-fit`, `fit`) with `minimum-font-size` (12px), as Qt's
      `fontSizeMode`: the largest size up to `font-size`, in half pixels,
      whose text fits (wrapped text by its height); a layout may shrink
      the element down to the text at its smallest size. On Text and
      StyledText (its headings, lists and tables shrinking with it).
      Microcontrollers can leave fitting, and Text's letter spacing, out
      (`zigulee_options.text_fitting = false`).

### P7 — Platforms and looks

- [x] iOS backend (`zigulee-ios`): UIKit on iPhone, iPad, the simulator
      and Mac Catalyst; the app's `main` started by UIKit (`ios.start`,
      written by `zigulee.iosApp` with the bundle's Info.plist and
      signing); Metal or software rendering; touches, pointer hover and
      trackpad scrolling, the on-screen keyboard (UIKeyInput) and
      hardware keys; the window's `safe-area-*` and `keyboard-height`;
      full screen hiding the status bar; VoiceOver; `zig build ios` and
      `test-ios` (through Mac Catalyst). Not done: input method
      composition (UITextInput), the system's dark mode, a menu bar on
      Mac, multiple scenes; not run on a simulator or a device yet.
- [ ] Android backend (needs the NDK and SDK).
- [x] Native-looking styles: `cupertino` (macOS: 13 px text, accent
      blue, white knobs, soft control shadows, focus glow; light and
      dark), fluent refined (Windows 11's darker bottom edge on
      controls), `native` choosing by the target; control and knob
      shadows, switch track and knob colors as style properties.
- [x] Window state from `.zge`: `fullscreen`, `maximized`, `minimized`,
      `always-on-top`, applied by the SDL3, macOS, Windows, X11 and
      Wayland backends and following the user's changes (Wayland: no
      always on top; KMS, web: not applicable).

### P8 — Modules

- [x] Audio input (microphone) through the mixer's `Input`; camera.
- [x] Settings (persisted properties), standard paths.
- [x] System tray, notifications.
- [x] Network requests (HTTP), with images and data from the network.
- [x] Charts (line, bar, pie) in `.zge`.
- [x] `Canvas`: QML's and HTML's 2D drawing from a `paint` handler,
      kept as paths (arcs as curves, points transformed as added),
      text and images, so every renderer draws it; styles as properties,
      `save`/`restore`, clip, `global-alpha`; painted again on resize,
      when what the handler read changes, and on `request-paint()`;
      compiled and interpreted.
- [x] Virtual keyboard (for KMS and microcontrollers).
- Web views, 3D, location and sensors: each only with a clear need. In
  order of value for effort:
  - **Web content**
    - [x] `open-url(url)`: opens a link in the system browser
          (NSWorkspace, ShellExecute, the desktop portal's OpenURI or
          xdg-open, `window.open` on the web, UIApplication on iOS). A
          small step that covers most "show a web page" needs.
    - [x] `WebView` (`url`, `html`, `loading`, `title`, `can-go-back`,
          `back()`/`forward()`/`reload()`, `load-finished`,
          `run-javascript(code)` with the result in a callback): a native
          view placed over the element, following its geometry and
          visibility. It always shows on top of zigulee's content, with no
          rotation, opacity or effects on it, as with Qt WebView. Start
          with macOS and iOS (WKWebView) and the web (an `<iframe>`);
          then Windows (WebView2, which needs its runtime and loader
          DLL); Linux (WebKitGTK, which brings GTK in) only on demand.
          The SDL3 backend reuses these through its native window
          handles. Never on KMS or microcontrollers. Done: macOS (native
          and SDL3) and iOS with WKWebView, the web with an `<iframe>`.
    - [x] `WebView` on Windows (WebView2): native and SDL3 backends; the
          installed runtime found from the registry (or WebView2Loader.dll),
          the COM interfaces declared without the SDK.
    - [x] `WebView` on Linux (WebKitGTK): X11, native and SDL3 backends;
          loaded at run time (GTK 3, webkit2gtk-4.1 or 4.0), each view a
          GTK window made a child of the zigulee window, GLib's loop run in
          the backend's. Not on Wayland, where one program's window
          cannot hold another's view (WPE WebKit drawn by zigulee would be
          the way there).
  - **3D**
    - [x] Perspective on 2D elements: `rotation-x`, `rotation-y` and
          the parent's `perspective` (card flips, tilted panels). In the
          GPU renderers, and in the software one by projective texture
          mapping. Done: a tilted element is a layer (drawn flat once,
          kept while it looks the same) mapped by a homography; the
          batcher cuts it into small cells, so every GPU backend draws it
          with its existing shader, and the software renderer shades
          those cells on the CPU. Clicks reach it where it shows;
          `cards.zge` example.
    - [x] A `View3D` element: `Model`s (a cube, sphere or plane), a
          perspective camera, directional and point lights, and materials
          (base color, metallic, roughness, a texture). Transforms are
          animated with the existing animations. Drawn into a texture
          that the scene composites like any other element. Done: `Node`
          groups too; drawn by a CPU rasterizer (raster3d.zig: depth
          buffer, per-pixel GGX shading) at twice the view's size, the
          image kept while the scene is the same; `scene.zge` example.
    - [x] glTF 2.0 meshes from `@model-url("x.glb")`: positions,
          normals, texture coordinates, indices, node transforms, and
          the metallic-roughness material with its base color texture.
          Done: gltf.zig reads `.glb` files (PNG textures; normals
          computed where missing); `ring.glb` in the scene example.
    - [x] 3D in the renderers: Metal and Direct3D 12 first, then WebGL
          or WebGPU for the web, plus a flat-shaded software fallback
          (small scenes only; none on microcontrollers). Done so far: the
          CPU fallback (per-pixel shading, not flat), and Metal: the
          batcher hands scenes to executors that draw 3D (`gpu_scenes`),
          others ask for the CPU picture; Metal draws each into a
          multisampled texture with a depth buffer, kept while the scene
          is the same. Direct3D 12 the same way (the native Windows
          backend), and OpenGL and WebGL2 (multisampled renderbuffers,
          resolved by a blit; drawn upside down), and Vulkan (one render
          pass resolving the samples; shaders/vulkan3d.*, checked in as
          SPIR-V).
    - [x] Picking: `clicked` on a `Model`. Done: a ray from the camera
          through the pointer, the nearest triangle hit (as last drawn);
          clicks that hit no model go on to what is below.
  - **Sensors** (most useful on mobile, the web and microcontrollers)
    - [x] `Accelerometer`, `Gyroscope`, `Compass` and
          `OrientationSensor` (`DeviceOrientation`: top-up, top-down,
          left-up, right-up, face-up, face-down). Each has `active`,
          `data-rate`, its readings, `reading-changed` and `available`,
          behind a provider in the core like the camera's; the
          orientation worked out from the accelerometer where the
          platform tells none.
    - [ ] iOS: CoreMotion, plus the orientation from UIKit.
    - [x] Web: `devicemotion` and `deviceorientation(absolute)` (iOS
          Safari asks the user first, at the next tap). Tested with the
          glue in Node; not yet on a phone.
    - [x] Microcontrollers: the ESP32-S3 example's QMI8658 (at 0x6B on
          the touch panel's I2C bus) as accelerometer and gyroscope,
          polled from the UI loop; run on the board, its axes checked
          (the chip's x and z point the other way from the display's).
    - [ ] Linux convertibles and tablets: iio-sensor-proxy over D-Bus
          (accelerometer orientation, ambient light).
    - [ ] Windows: the Sensor API. Desktop Macs have none to offer.
  - **Location**
    - [x] `PositionSource`: `active`, `valid`, `latitude`,
          `longitude`, `altitude`, `accuracy`, `speed`, `direction` (with
          `-valid` flags), `timestamp`, `updated`, `available`, `error`
          (`PositionError`) and `minimum-interval`, behind a provider in
          the core. The user is asked for permission.
    - [x] Web: `navigator.geolocation` (tested with the glue in Node).
    - [x] macOS and iOS: Core Location, shared in `zigulee-apple`
          (bundles need `NSLocationWhenInUseUsageDescription`:
          `iosApp`'s `location_usage`). Its conversions tested with real
          CLLocation objects; not yet run against the live service.
    - [ ] Linux: GeoClue2 over D-Bus. Windows: Windows.Devices.Geolocation
          (WinRT, the heaviest to reach from Zig). Waiting for CI.
    - [x] `MapView`: a slippy map of web tiles (Web Mercator, a URL
          template: OpenStreetMap's by default, with its attribution and
          an identifying user agent), six loading at a time, kept in
          memory (160) and on disk (a week); `latitude`, `longitude` and
          `zoom` (fractional), panned by dragging, zoomed by the wheel,
          pinching and double-clicking, `zoom-in()`, `zoom-out()`; lower
          zoom levels shown while tiles load. `MapItem` children placed
          at a coordinate (markers: any elements), `MapPolyline` for
          routes and outlines, `clicked(latitude, longitude)`; following
          a `PositionSource` by binding. Sharp on high-density screens
          (the next level's tiles, or a `{r}` template's `@2x`), tiles
          through the browser's fetch on the web (Image `source-url` too).
    - Not planned: geocoding, routing, offline map data and vector
      tiles (services and formats, not UI).
- [ ] Tooling: a linter, a profiler (binding and frame times), a visual
      designer on top of the live viewer.
