# zigulee — Development Roadmap

A declarative application framework for Zig, in the spirit of Slint and QML.

What remains for parity with Qt Quick and QML, prioritized:
[ROADMAP-QT.md](ROADMAP-QT.md).

## Starting points

| Slint concept | zigulee equivalent |
|---|---|
| `.slint` DSL compiled to Rust/C++ | `.zge` DSL compiled to Zig source via a `build.zig` step |
| Reactive properties with lazy dependency tracking | `Property(T)` with intrusive dependency lists, no hidden allocations |
| Item tree + layout engine | Flat item tree + constraint-based layout solver |
| Renderers (software, FemtoVG, Skia) | Software renderer first, then a GPU renderer |
| Backends (winit, Qt, LinuxKMS, MCU) | Small backend interface: SDL3 first, then native, KMS, MCU |
| Interpreter + LSP + live preview | Interpreter sharing the compiler front-end, plus LSP |

Zig strengths to lean on: comptime for typed component APIs, explicit
allocators (embedded-friendly), the build system running the compiler as a
build step, and painless C interop (FreeType, HarfBuzz, platform APIs).

---

## Phase 0 — Foundations (2–3 weeks)

**Decisions**
- **Pinned Zig version: 0.16.0.** Upgrades are deliberate, in one commit.
- **External DSL**, not a comptime-only DSL: enables tooling, LSP and live
  preview. A comptime Zig builder API may be added later as a second front-end.
- **Memory model:** component instances are heap-allocated once and never
  move. Properties hold pointers to each other, so address stability is
  mandatory (the equivalent of Slint's `Pin`).
- **Threading:** the UI runs on one thread; other threads post work via
  `invokeFromEventLoop`.

**Deliverables:** repository layout (`src/core`, `src/compiler`,
`src/renderers`, `src/backends`, `widgets/`, `tools/`), CI (Linux, macOS,
Windows, cross-compile to `thumb`), golden-image tests for rendering and
snapshot tests for the compiler.

## Phase 1 — Core runtime: the reactive layer (4–6 weeks)

Built and tested headless.

- `Property(T)`: value, optional binding (fn pointer + context), dirty flag,
  intrusive list of dependents.
- Dependency tracking via a thread-local "currently evaluating binding";
  each `get()` during evaluation registers a dependency. Lazy evaluation
  (re-evaluate on read when dirty).
- Two-way bindings (`<=>`).
- `ChangeTracker` for `changed prop => { … }` handlers.
- Typed callbacks: `Callback(Args, Ret)`.
- Models: `Model(T)` interface (`rowCount`, `rowData`, `setRowData`, change
  notifications) and `VecModel(T)`; these drive `for` repeaters.
- Animations and timers: an animation is a binding that depends on a global
  animation clock, marked dirty each frame.

**Exit criteria:** bindings fully tested (cycle detection with a clear error,
diamond dependencies, leak-free under `std.testing.allocator`).

## Phase 2 — Item tree, geometry, layout (4–5 weeks)

- Built-in items: `Rectangle`, `Text`, `Image`, `TouchArea`, `FocusScope`,
  `Flickable`, `Clip`, `Path`, `Window`.
- Flat item tree (parent/child/sibling indices) per component; items are plain
  structs of properties, vtables only for render/input behavior.
- Layouts: `HorizontalLayout`, `VerticalLayout`, `GridLayout` with
  min/max/preferred/stretch constraints. Layout results are properties.
- Input: pointer hit-testing (reverse tree walk), focus chain, grabs.
- Dirty-region tracking for partial redraws.

## Phase 3 — Rendering (6–10 weeks, overlaps Phase 2)

- **3a Software renderer (first):** RGB565/RGBA8888, AA rounded rects,
  borders, gradients, clipping, image blit, 9-slice. Line-by-line mode for MCUs
  without a framebuffer. Serves as the deterministic reference for
  golden-image tests.
- **3b Text:** start with `stb_truetype` + simple LTR layout; then FreeType +
  HarfBuzz, UAX #14 line breaking, bidi. Glyph atlas cache. Pre-rendered
  bitmap fonts for MCUs, generated at build time.
- **3c GPU renderer:** OpenGL ES 3 / WebGL2 FemtoVG-style path renderer first;
  Vulkan/Metal/D3D12 (wgpu-native or SDL3 GPU) later behind the same interface.

## Phase 4 — Platform backends (4–6 weeks, overlaps Phase 3)

Interface: `createWindow`, `runEventLoop`, `requestRedraw`, `clipboard`,
`setCursor`, `scaleFactor`, `postEvent`.

1. SDL3 — all desktops quickly.
2. Native — Win32, Cocoa (objc runtime), Wayland/X11 (smaller binaries, IME,
   accessibility).
3. LinuxKMS/DRM — embedded Linux without a compositor.
4. MCU — user-supplied `flush(region, pixels)` and touch hooks; no allocator in
   the hot path. STM32, RP2040/RP2350, ESP32.
5. WASM — canvas2d / WebGL.

## Phase 5 — The compiler (8–12 weeks)

Lexer → Parser (CST/AST with spans) → name resolution → type checking →
binding analysis → optimization passes → Zig codegen.

- **v1 language (frozen):** `component`, `inherits`, `var <T>` with
  `in`/`out`/`in-out`/`private`, `callback`, bindings, `<=>`, `states`,
  `transitions`, `animate`, `for`/`if`, `import`/`export`, `struct`, `enum`,
  `global`, builtin functions, units (`px`, `phx`, `%`, `ms`, colors).
- **Passes:** const folding, trivial binding inlining, unused property
  removal, item-tree flattening, resource embedding.
- **Codegen:** readable Zig; one struct per component with typed
  getters/setters and callback setters.
- **Build integration:**
  ```zig
  const ui = zigulee.compile(b, .{ .source = b.path("ui/app.zge") });
  exe.root_module.addImport("ui", ui);
  ```
- **Diagnostics:** precise spans, "did you mean", surfaced through the build.

Target experience:
```
// app.zge
export component App inherits Window {
    var in-out <int> counter: 0;
    callback clicked();
    VerticalLayout {
        Text { text: "Count: \{counter}"; }
        Button { text: "+1"; clicked => { root.clicked(); } }
    }
}
```

## Phase 6 — Widgets and styles (6–8 weeks)

Written in `.zge` itself: `Button`, `CheckBox`, `Switch`, `Slider`, `SpinBox`,
`LineEdit`, `TextEdit`, `ComboBox`, `ListView`, `StandardTableView`,
`ScrollView`, `TabWidget`, `ProgressIndicator`, `Spinner`, `DatePicker`.
Styles: fluent-like, material-like, minimal MCU style — selected at compile
time. Text editing: cursor, selection, undo, clipboard, IME pre-edit.

## Phase 7 — Tooling (6–10 weeks)

Interpreter (shares the compiler front-end), LSP (diagnostics, completion,
goto-def, hover, rename, format), VS Code extension first, live preview with
property inspection, `zigulee-fmt`, `zigulee-viewer`.

## Phase 8 — Production hardening (ongoing from ~month 9)

Accessibility (UIA / NSAccessibility / AT-SPI; item properties reserved from
Phase 2), i18n (`@tr()`, gettext, plurals, RTL), high DPI, performance
budgets (<300 KB RAM MCU demo, sub-ms binding re-eval, 60 fps software
rendering on a Raspberry Pi), parser/layout fuzzing, docs, examples, stable
C ABI.

---

## Milestones

| Milestone | Approx. | Demo |
|---|---|---|
| M1 "Reactive core" | Month 2 | Headless tests: bindings, animations, models |
| M2 "Pixels" | Month 4 | Hand-written item tree, software renderer, SDL3 window |
| M3 "Compiler MVP" | Month 6 | Counter app from a `.zge` file via `build.zig` |
| M4 "Usable" | Month 9 | Widget gallery, GPU renderer, HarfBuzz text, LSP diagnostics |
| M5 "Embedded" | Month 11 | Same app on RP2040 with line-by-line rendering |
| M6 "0.1 release" | Month 12–14 | Live preview, accessibility on one platform, docs |

Assumes 1–2 experienced full-time developers.

## Risks

1. **Zig churn** — pinned version, one compat module, nightly CI as early warning.
2. **Text is underestimated** — use HarfBuzz/FreeType, keep the MCU font path separate.
3. **Pinning vs. moves** — components are always heap-allocated; generated code never hands out components by value.
4. **Compiler scope creep** — v1 language frozen; `@children`, `popup`, `dialog` deferred until after M4.
5. **Accessibility retrofitted late** — reserve item properties early.

## Status

- [x] Phase 0: repository scaffold, build steps (`test`, `examples`,
  `check-mcu`), CI workflow, Zig pinned to 0.16.0
- [x] Phase 1: reactive core
  - [x] `Property(T)` with lazy bindings and runtime dependency tracking
  - [x] Binding loop detection (pluggable handler), diamond dependencies,
        dynamic dependencies, allocation-free steady-state re-evaluation
  - [x] Two-way bindings (`linkTwoWay`)
  - [x] `ChangeTracker(T)` + `runChangeHandlers()`
  - [x] `PropertyTracker` (for renderer invalidation)
  - [x] `Callback(fn (...) R)`
  - [x] `Model(T)` / `VecModel(T)` with `ModelListener` row notifications
  - [x] Animations: UI clock property, `Animation` (duration, delay, easing,
        iterations, direction), 15 easing curves incl. `cubic_bezier`,
        `setAnimated` / `setAnimatedBinding`, interpolation for floats, ints
        and structs, `hasActiveAnimations()` for frame scheduling
  - [x] Timers: single-shot/repeated, start/stop/restart from callbacks,
        no catch-up bursts, `nextTimerDeadline()` for idle sleeping
  - [x] `updateTimersAndAnimations(now_ms)` event-loop entry point
- Deferred from Phase 1:
  - Property names in binding-loop diagnostics (needs the compiler, Phase 5)
  - Animating colors/brushes (types arrive with the renderer, Phase 3)
  - Animated bindings re-run their function every frame while animating;
    split target tracking with a `PropertyTracker` if profiling shows a cost
- [x] Phase 2: item tree, geometry, layout, input
  - [x] Geometry (`Point`, `Size`, `Rect`) and `Region` (bounded dirty-rect set)
  - [x] `Color` / `Brush` (solid), animatable
  - [x] Pure layout solvers: box (stretch, min/max, shrink, 6 alignments,
        padding, spacing) and grid (spans, per-track constraints), plus
        `LayoutInfo` combination rules
  - [x] Intrusive item tree (`Item` header with geometry, `visible` and
        `opacity` properties and a vtable), explicit `LayoutConstraints`
  - [x] Built-in items: `Empty`, `Rectangle` (with `clip`), `Text`,
        `TouchArea`, `FocusScope`, `Flickable`, `BoxLayout`
        (horizontal/vertical), `GridLayout`
  - [x] `Repeater` (`for`, driven by `Model` row notifications) and
        `Conditional` (`if`); both flatten into box layouts
  - [x] `Window`: pointer dispatch (topmost first, clipping, visibility,
        grabs, hover/exit), input filters that can take over a child's grab
        (drag vs. click), key events bubbling to ancestors, focus,
        Tab/Shift+Tab
  - [x] Rendering interface (`ItemRenderer`, with opacity), recording
        `DisplayList`, `TextMeasurer` (monospace approximation until Phase 3)
  - [x] Partial rendering: per-item dependency tracking plus a hash of each
        item's draw calls, so only items whose pixels change are repainted;
        visibility/opacity/clip changes repaint descendants
  - [x] Accessibility reserved: roles on item types, `AccessibleProperties`
        overrides (role, label, description, value, checked, enabled)
- Deferred from Phase 2:
  - `Image` and `Path` (with the renderer, Phase 3)
  - Repeated rows inside `GridLayout`
  - `visible: false` items keep their space in layouts (as in Slint; use
    `if` to remove an item)
  - Group opacity is recorded per draw command; true layer compositing is a
    Phase 3 renderer decision
- [ ] Phase 3: rendering (in progress)
  - [x] 3a Software renderer (`src/renderers/software`): rasterizes the
        display list into `Rgba8` (premultiplied) or `Rgb565` buffers
    - [x] Anti-aliased rectangles: rounded corners, borders, alpha, opacity
    - [x] Brushes: linear and radial gradients (up to 8 stops), animatable
    - [x] Paths: SVG path data (all commands incl. arcs), exact-area fill
          (non-zero winding), round-joined strokes, viewbox or
          bounding-box mapping with uniform scaling
    - [x] Images: premultiplied RGBA, PNG decoding (all non-interlaced
          formats), fill/contain/cover/preserve, bilinear or pixelated,
          colorize, nine-slice; `Image` and `Path` items
    - [x] Full-framebuffer partial redraws and line-by-line band rendering
          (both verified pixel-exact against full renders)
    - [x] Golden-image tests (`tests/golden`, `-Dupdate-golden`), PNG encoder
  - [ ] 3b Text (in progress)
    - [x] TrueType reader in Zig (`src/core/text/truetype.zig`): `.ttf` and
          `.ttc`, cmap formats 4 and 12, hmtx metrics, `kern` table,
          simple and composite glyphs; bounds-checked against malformed
          fonts (truncation and corruption tests)
    - [x] Text layout: line breaking at newlines, word wrap at spaces
          (long words break), kerning, horizontal and vertical alignment;
          shared by measurement and rendering
    - [x] Glyph rasterization through the path filler, cached per size and
          quarter-pixel position; `Text.font` and `Window.default_font`
    - [x] In-memory test fonts (`core.text.test_font`) and a golden test
    - [x] GPOS kerning: the `kern` feature of the Latin/default script,
          pair adjustment formats 1 and 2, extension lookups, both coverage
          and class-definition formats; preferred over the `kern` table
    - [x] Bundled example fonts (`examples/fonts`: Inter, JetBrains Mono,
          OFL) and a golden test rendered with them
    - [x] Text eliding: `overflow: elide` on Text ("Long tex…", or "..."
          for fonts without "…"; wrapped text elides its last visible
          line), used by the list, table and combo box widgets; selection
          and editing metrics are in text_edit.zig (Phase 6)
    - [x] Font fallback: `Window.addFallbackFont`; characters a font lacks
          come from the fallback fonts (glyphs carry their font; no
          kerning across fonts); the viewer and preview fall back from
          Inter to JetBrains Mono; `zigulee_window_add_fallback_font`
    - [x] Pre-rendered bitmap fonts for MCUs: `zigulee.bitmapFont` (build
          time, tools/bitmap_font.zig) renders a TrueType font with
          zigulee's rasterizer at chosen sizes and characters into a compact
          file (bitmap_font.zig: code point ranges, advances and kerning in
          font units, 4-bit images per size) that `Font.init` opens in
          place; layout is identical to the TrueType font's. The MCU demo
          uses Inter at 13, 14, 16 and 40 px: 171.8 KB of flash with the
          font (budget 256 KB), 83.8 KB of RAM
    - [x] Right-to-left text: the Unicode bidirectional algorithm (UAX
          #9, core/text/bidi.zig: character classes, weak and neutral
          types, levels, reordering, mirrored brackets; explicit embeddings
          and isolates are ignored). Lines with right-to-left text are laid
          out in visual order (up to 256 characters per line; others take
          the old path unchanged); caret, hit testing, selection and eliding
          (the "…" on the left) follow it
    - [x] Shaping (core/text/shape.zig, opentype.zig) of lines with
          right-to-left text or combining marks: Arabic joining (types
          from ArabicShaping.txt; isol/init/medi/fina), GSUB single,
          multiple, ligature, contextual and chained contextual
          substitutions (ccmp, locl, rlig, calt, liga), GPOS single, pair,
          cursive, mark-to-base, mark-to-ligature, mark-to-mark and
          contextual positioning (kern, mark, mkmk, curs), lookup flags,
          GDEF classes and mark filtering sets. Fonts without Arabic forms
          use their presentation forms (lam-alef too); right-to-left marks
          a font does not place are centered on their base. Line breaking,
          eliding (re-shaped after the cut), carets (inside ligatures) and
          hit testing use the shaped glyphs. Tested with fonts built in
          memory and a `shaping` fuzz target; checked by eye with SF Arabic
          (GSUB/GPOS) and Geeza Pro (presentation forms). `zigulee_options =
          .{ .opentype_shaping = false }` leaves the OpenType code out (the
          MCU demo: 180.8 KB of flash, 198.3 KB with it). Not done:
          alternate and reverse chaining substitutions, Indic and other
          complex scripts' reordering, AAT `morx` tables, font variations
    - [x] Hinting and stem darkening (software.TextRendering, both on by
          default): light vertical hinting scales outlines so the x-height
          (OS/2, else the "x" glyph) falls on whole pixels, leaving
          horizontal metrics and layout as they were; stem darkening moves
          outline edges outwards by up to 0.3 px below 72 px (Pathfinder's
          macOS-like factors), along each corner's bisector, outwards for
          the font's winding (holes shrink). The same glyphs in the software
          renderer, the GPU atlas and pre-rendered fonts
    - The library ships no font; applications provide font files (e.g.
      with `@embedFile`). The bundled fonts are for examples and tests.
  - [x] 3c GPU renderer (src/renderers/gpu): OpenGL 3.3 core / OpenGL ES
        3.0, one shader and few draw calls per frame (a new one only when
        the image texture changes). Rounded rectangles and borders are
        shaded exactly (signed distance), gradients sampled from a texture
        row each, glyphs and path masks rasterized with the software
        renderer's code into a coverage atlas (cached; cleared when full),
        images uploaded once per image. Clips are per vertex. The batcher
        needs no GPU: every golden scene and a `gpu-frames` fuzz target run
        its frames on the CPU (reference.zig) against the software renderer
        (within 2 per channel, 4 for stacks of draw calls), and on macOS a
        test draws with real OpenGL (within 2). The SDL3 backend uses it by
        default (`.renderer = .auto`, falling back to software); the C API
        has `zigulee_window_render_gl`. A 920x1280 gallery frame costs 63 µs
        of CPU (4.8 ms in software). Not done: Vulkan/Metal/D3D12
  - [x] Metal (src/backends/macos/metal.zig): the batcher's frames with
        the same shading in Metal Shading Language (compiled when the
        renderer starts), a private target texture kept between frames
        (partial frames clear their area with a non-blending pipeline in
        scissor rects), blitted to a CAMetalLayer's drawable (sRGB, so
        colors are converted for wide-gamut displays). The default on macOS
        in both backends (Metal, else OpenGL, else software). Tested
        against the software renderer (full and partial frames, within 3)
        directly, in a native window and through SDL3; checked on screen.
        OpenGL windows on macOS are now sRGB too (they showed sRGB values
        unconverted on P3 displays)
  - [x] Vulkan (src/renderers/gpu/vulkan.zig): the batcher's frames with
        the same shading (shaders/vulkan.*, compiled to SPIR-V by `zig
        build vulkan-shaders` with glslc and checked in, so building needs
        no Vulkan SDK). The Vulkan library is loaded at run time (the
        loader, or MoltenVK on macOS; `ZIGULEE_VULKAN_LIBRARY`), definitions
        written in Zig (no headers). A target image kept between frames
        (partial frames clear their area with vkCmdClearAttachments),
        staging uploads, one frame in flight, then a blit to the swapchain
        of a surface made from the window's handles (CAMetalLayer, Win32,
        X11, Wayland). SDL3: `.renderer = .vulkan` (opt-in). Tested on
        MoltenVK against the software renderer (full and partial frames,
        within 2), through SDL3, and on screen; the Windows and Linux
        builds compile but have not run
  - [x] Direct3D 12 (src/backends/windows/d3d12.zig, module
        `zigulee-d3d12`): the declarations translated from the Windows SDK
        headers that ship with Zig (exact COM vtables, struct returns
        through their hidden pointer); HLSL compiled when the renderer
        starts (d3dcompiler_47, part of Windows); a target texture kept
        between frames (ClearRenderTargetView rectangles for partial
        frames), upload-heap staging with 256-byte row pitch, one frame in
        flight, a flip-model swapchain fed by CopyResource. SDL3:
        `.renderer = .d3d12` (opt-in). Tested on Windows in CI (`zig build
        test-d3d12`, on the runner's Microsoft Basic Render Driver): full
        and partial frames against the software renderer, within 3; builds
        for x86_64 and arm64 Windows
  - [x] Partial redraws on the GPU: frames are drawn into a texture that
        keeps the last one; a partial frame batches only what intersects
        the changed area, clears just that area (scissor) and draws over
        it, then the whole texture is blitted to the window (whose back
        buffer need not survive a swap). Nothing changed: no draw, no swap.
        SDL3, macOS and WebGL2 use it; the C API has
        `zigulee_window_render_gl_partial`. Checked on the CPU reference and
        with real OpenGL (SDL3 and macOS) against full frames. A click in
        the gallery: 156 µs of CPU with its partial frame, 207 µs with a
        full one
  - [x] WebGL2 in the wasm backend: the GPU renderer's OpenGL functions are
        wasm imports (`@extern`, module "zigulee_gl") that zigulee.js implements
        on the canvas's WebGL2 context (object tables, memory views);
        `renderer: "auto"` (WebGL2, else software). Tested in Node with a
        recording WebGL2 context (shaders, buffers and textures from wasm
        memory, draws), and `zig build test-webgl` draws the gallery in a
        headless Chromium-based browser with both renderers: within 1 of
        each other
  - Known limits: even-odd fill rule not supported; stroke joins are
    always round, no dashes; group opacity is applied per draw command;
    stroke rasterization cost grows with segment count x stroke area
- [ ] Phase 4: platform backends (in progress)
  - [x] HiDPI support in the software renderer (`scale_factor`: logical
        coordinates, physical pixels)
  - [x] SDL3 backend (`src/backends/sdl3`, module `zigulee-sdl3`): SDL built
        from source by the Zig package manager (castholm/SDL v0.5.4, a lazy
        dependency); window with a streaming texture as framebuffer,
        partial uploads of dirty rectangles, vsync-paced animation frames,
        an event loop that sleeps until the next event, timer or frame;
        mouse, wheel, keyboard and text input, resize and pixel-density
        changes, close requests
  - [x] Headless backend tests (SDL dummy video driver, pixels read back
        from SDL's renderer) and an interactive `gallery` example
  - [x] Milestone M2 "Pixels" reached
  - [x] Clipboard and input method composition (SDL's, see Phase 6)
  - [x] Mouse cursors: `mouse-cursor` on TouchArea (the CSS names), an
        I-beam over text fields, the grabber's cursor while dragging
        (`Window.mouseCursor`); SDL's system cursors, and the VS Code
        preview shows them too
  - [x] Multiple windows: events routed to their window, one `step` for
        all (`sdl3.step`, `sdl3.runAll`), each closing on its own
  - [x] Redrawing during live resize on macOS: an SDL event watch draws on
        the expose events SDL sends from inside the resize loop
  - [x] WebAssembly: the `zigulee-wasm` backend (src/backends/wasm) and its
        glue, zigulee.js: a `<canvas>` at the display's density, pointer,
        wheel, keyboard, paste and copy, cursors, frames only when needed
        (animations, timers, events), changed rectangles only. `zig build
        web` builds the gallery (1.4 MB with three fonts); tests/wasm runs
        an app through the real glue in Node with a fake canvas (pixels,
        clicks, UTF-8 typing, cursor, clipboard, partial frames)
  - [x] Input methods in the browser: a hidden textarea at the caret takes
        the keyboard; composition events become preedit text, input
        events typed text (tested in Node)
  - [x] Native macOS backend (src/backends/macos, module `zigulee-macos`):
        AppKit through the Objective-C runtime (objc.zig), no SDL: windows
        with a layer-backed view (software frames as its contents, only
        what changed redrawn) or an OpenGL 4.1 context (the GPU renderer),
        Retina, live resize, mouse, wheel and trackpad scrolling, cursors,
        keyboard through NSTextInputClient (input methods, dead keys),
        shortcuts, the system clipboard, VoiceOver, an application menu
        with Quit, several windows, the same interface as zigulee-sdl3.
        `-Dbackend=macos` builds the windowed examples and the viewer with
        it. Tested with hidden windows (pixels shown, clicks, typing,
        composition, resizing, closing, OpenGL against software); checked
        on screen by capturing the window. Title bars follow the window's
        color scheme (`Window.color_scheme`; by default from the background's
        brightness), here and in the SDL3 backend on macOS and Windows
  - [x] Native backends: Win32 (`zigulee-windows`: Direct3D 12 or
        software, IME, DPI awareness, UI Automation), X11 and Wayland
        (`zigulee-x11`, `zigulee-wayland`: their protocols spoken directly, no
        Xlib or libwayland; xkbcommon loaded at run time for Wayland's
        keyboard; AT-SPI), and KMS/DRM without a desktop (`zigulee-kms`:
        mode setting and evdev input, no libdrm). Each tested in CI on a
        real server or device (Windows, Xvfb, headless Weston, vkms)
  - [x] An MCU display driver: the Waveshare ESP32-S3-Touch-LCD-2
        (examples/esp32s3, `zig build esp32s3-flash`), bare metal: Zig's
        C backend (its LLVM has no Xtensa backend), then Espressif's GCC;
        the image runs from internal SRAM, loaded by the ROM bootloader.
        ST7789 on SPI at 40 MHz, a band sent as it is drawn; the CST816D
        touch panel on I2C. The thermostat demo: a full 320x240 frame in
        81 ms (40 drawing, 41 sending), a button's press highlight in
        3.6 ms, the temperature and slider in about 15 ms; heap 71 KB in
        use (73 KB peak), stack 24 KB; 149 KB of code, 89 KB of constants
        (font included). `zig build mcu-stress` runs the demo the same way
        (32-bit, the firmware's heap) through hundreds of clicks and drags.
        Found on the device:
        - float `@min`/`@max` were calls to newlib's slow `fminf`/`fmaxf`
          (now inline), zig.h's float/integer conversions software
          routines (now the FPU's), and the software renderer computed a
          rounded rectangle's distance for every pixel: whole-pixel spans
          inside a rectangle are now filled without it (a full frame's
          drawing 586 -> 40 ms on the device, same pixels; on the desktop
          the gallery's full frame 1.25 -> 0.22 ms, the dark mode toggle
          1.16 -> 0.28 ms)
        - the glyph cache copied pre-rendered glyphs out of the font into
          one growing block (11 KB here): with a heap that fragments, a
          frame eventually could not get it. Pre-rendered glyphs are now
          drawn from the font (heap 81 -> 71 KB)
        - a bump allocator only takes back the last allocation: the
          firmware's heap reuses freed memory (examples/esp32s3/heap.zig)
        - the text layout's stack frames (fixed arrays of 64 characters)
          take a frame to 24 KB of stack
        - not done: sending by DMA while the next band is drawn (it froze
          the display after a while), 80 MHz SPI, PSRAM for a bigger heap
        - compiled against interpreted `.zge` (`zig build mcu-stress --
          <heap-KB> <rounds> 1`: the same thermostat and input, 32-bit wasm
          under Node.js on an Apple Silicon Mac): startup 0.7 ms against
          13.8 ms, a frame 0.028 ms against 0.036 ms (layout and drawing
          are the same code), the heap 72 KB against 3.44 MB, of which
          3.3 MB is the compiled program kept after loading (the parsed
          std-widgets, the generator's state, the Zig source it writes).
          The interpreter does not fit this board's 390 KB of internal
          RAM; it would need PSRAM and code run from flash, or a much
          leaner loaded program
- [x] Phase 5: the `.zge` compiler
  - [x] Lexer (dashed names, units, colors, interpolated strings), parser
        with precise syntax errors, diagnostics with file:line:col and a
        source excerpt; several semantic errors reported per run
  - [x] Semantic analysis and Zig code generation: one struct per
        component (`create`/`destroy`, `init`/`deinit`, `rootItem`,
        `window`); constant bindings become `set`, others binding functions
  - [x] Language: `component` / `export component ... inherits` (built-ins,
        Window, other components), properties (`in`, `out`, `in-out`,
        private; int, float, bool, string, length, duration, color, brush,
        enums), callbacks with arguments and return values, bindings,
        `<=>`, handlers (`=`, `+=`..., `if`/`else`, `return`, calls,
        `debug()`), `animate`, ids, `root`/`self`/`parent`, string
        interpolation and concatenation, arithmetic with unit checking,
        `?:`, `min`/`max`/`abs`/`round`/`floor`/`ceil`/`sqrt`/`mod`,
        percentages for width/height, CSS color names
  - [x] Built-ins: Window, Empty, Rectangle, Text, TouchArea, FocusScope,
        Path, HorizontalLayout, VerticalLayout; default geometry (fill the
        parent outside layouts; fixed sizes become layout constraints)
  - [x] `zgec` CLI and `uiModule()` build integration (also for projects
        that depend on zigulee); end-to-end tests and the `hello` example
  - [x] `for item[index] in model : Element {}` and `if cond : Element {}`:
        each body compiles to a template struct instantiated by the runtime
        `Repeater` / `Conditional`; loop variables, nested loops and the
        enclosing component (through `_parent`) are in scope; models
        (`[T]` properties, `model.length`, `model[i]`), array literals as
        static models, and `for i in n` over a count
  - Runtime fix found along the way: a box layout with a non-stretch
    alignment can now grow beyond its children's maximum size
  - [x] `struct` and `enum` declarations: struct literals, field access,
        models of structs (`[Contact]`), `Mode.dark` or bare `dark` where
        the type is known (including the right side of `==`)
  - [x] `states [ name when cond : { prop: value; id.prop: value; } ]`,
        with `animate` inside states; `changed prop => { ... }`
  - [x] Built-ins: `Image` (`@image-url("x.png")`, decoded at build time
        and embedded; dependency file so edits rebuild), `Flickable`
        (viewport sized to its content by default), `GridLayout` with `Row`
        and `row`/`col`/`rowspan`/`colspan`, `TextInput`, `Timer`;
        `font-family` / `font-weight` (fonts registered with
        `Window.registerFont`); reading `preferred-height` and friends
        gives the computed layout size
  - [x] Milestone: the gallery example is written in `.zge`
        (examples/gallery.zge and widgets.zge: 195 lines instead of 540 lines
        of Zig) and
        tested by driving it with simulated input
  - [x] `global Name { ... }` singletons (properties, callbacks,
        handlers; read and written as `Name.prop` from any component) and
        `import { A, B } from "file.zge";` (paths relative to the importing
        file, recursive, only exported names; diagnostics name the right
        file). The gallery imports its widgets and `Palette` global from
        examples/widgets.zge
  - [x] `for`/`if` inside a `GridLayout` `Row` (generated cells take
        consecutive columns); array literals with non-constant elements
        (a fixed-size model updated row by row); state transitions with
        `in { animate ... }` / `out { animate ... }` per state
  - Moved to Phase 7: interpreter for live preview, LSP
- [x] Phase 6: widgets and styles
  - [x] `import { Button } from "std-widgets.zge";`: the widgets are `.zge`
        files embedded in `zgec` (src/widgets/<style>/), the style is chosen
        with `zgec --style=` / `UiOptions.style` (only "fluent" so far)
  - [x] Compiler support found along the way: each file has its own names
        (a user `Button` and the standard one can coexist; clashing Zig
        names get a suffix), `export { A } from "file.zge";` re-exports,
        `Key.Return` and friends for key handlers
  - [x] Fluent style: `Palette` global (light/dark), `Button` (`primary`,
        `enabled`), `CheckBox`, `Switch`, `Slider` (drag, click, arrow keys,
        Home/End, `step`), `ProgressIndicator`; keyboard focus rings;
        golden images in light and dark
  - [x] Text editing in `TextInput` (src/core/text_input.zig, logic in
        text_edit.zig): caret and selection by keyboard (characters, words,
        lines, Shift to extend) and pointer (drag, double-click words,
        triple-click lines), undo/redo with typing merged into one step,
        clipboard (`Window.clipboard`, SDL's in the backend), multi-line
        with word wrap and scrolling that follows the caret, read-only,
        input method pre-edit (SDL text editing events, candidate window
        placed at the caret). `.zge`: `single-line`, `wrap`, `read-only`,
        `cursor-position`, `anchor-position`, `select-all()`, `copy()`...
  - [x] `LineEdit` (placeholder text) and `TextEdit` widgets
  - [x] `@children` (where the children of a component's uses go, also
        inside layouts) and `[public] function name(a: T) -> R { ... }` in
        components (methods in generated code; public ones callable from
        outside); `PopupWindow` (`show()`/`close()`, `close-policy`; drawn
        above everything, gets input first, Escape closes it)
  - [x] `ScrollView` (scroll bars to drag or click), `ListView`,
        `StandardListView`, `TabWidget`, `SpinBox`, `Spinner`,
        indeterminate `ProgressIndicator`, `ComboBox`, `DatePicker` (a
        month calendar, its date maths written in `.zge` functions);
        `LineEdit`/`TextEdit` expose `select-all()`, `copy()`... functions
  - [x] Text editing: password input (`input-type: password`), Shift+click
        extends the selection (pointer presses carry modifiers), characters
        made of several code points (accents, emoji sequences, flags) move
        and delete as one
  - [x] Models of models (`[[string]]`, rows of basic types) and
        `StandardTableView` (headers asking the app to sort, current row)
  - [x] Styles: the widgets are shared (src/widgets/common/) and take
        their sizes from a `Style` global and their colors from `Palette`,
        per style (src/widgets/<style>/): fluent (unchanged, pixel for
        pixel), material-like (Material 3 colors and shapes) and minimal
        (square, black and white, no transparency: cheap on
        microcontrollers); golden images for each, light and dark
  - [x] The gallery is written with the standard widgets (tabs: controls,
        lists, calendar); `zig build run-gallery -Dstyle=material`
- [x] Phase 7: tooling
  - [x] Formatter: `zgec fmt [--check] [--stdin] files...` (token-based:
        keeps comments, blank lines and the author's line breaks inside
        expressions; one-line blocks stay on one line); every `.zge` file in
        the repository is formatted
  - [x] Symbol index filled during analysis (what each name refers to,
        members, ids and scopes) and `compiler.analyze` with structured
        diagnostics
  - [x] `zigulee-lsp`: diagnostics as you type (imports read from open
        documents or the disk), hover, go to definition (across files),
        find references, rename (within the files of one compilation),
        formatting, document symbols, completion that works while the code
        does not parse (members after `id.` / `root.` / `Key.`, element
        types and keywords at member starts); UTF-8 or UTF-16 positions
  - [x] VS Code extension (editors/vscode): TextMate grammar, language
        configuration, LSP client; `install.sh` bundles the server (checked
        on macOS, including the live preview)
  - [x] Interpreter (src/interpreter/): runs a checked program from the
        compiler's analysis, setting up the same elements, bindings,
        animations, states, `changed` handlers, `for`/`if` and globals as
        the generated code, on the real runtime items (comptime reflection
        over the built-in element table); values carry their `.zge` type
        and follow the generated code's rules. A differential test runs
        every window component of the test files and the gallery compiled
        and interpreted through the same input and requires identical
        pixels
  - [x] `zigulee-viewer file.zge`: interprets it in a window, reloads when
        it or a file it uses changes (in/in-out property values carry
        over), shows compiler errors in the window until fixed;
        `--component`, `--style`, `--screenshot`
  - [x] Live preview in the editor: zigulee-lsp interprets the document
        being edited (unsaved text, open imports), renders it with the
        software renderer and sends PNG frames (only the changed area) to a
        VS Code webview, which sends input back; no threads: frames say
        when the next is due (animations, timers). Edits re-run it keeping
        in/in-out values; errors show while the last good version keeps
        running. Inspection: Alt+click (or Inspect mode) selects an element,
        reveals its source and lists its properties, editable live; the
        editor cursor highlights its element in the preview
        (`zigulee/preview*` LSP extensions)
  - [x] Go to definition into the standard widgets (their sources are
        written to the user's cache directory, `~/.cache/zigulee-lsp/std/`)
  - [x] Find references and rename across the workspace: every `.zge` file
        in the workspace folders (not build or hidden directories) and the
        open documents, matched by where the symbol is declared
  - [x] Preview: only the changed areas are sent, as separate patches,
        also while an element is highlighted; Shift+Enter in the property
        panel writes the value into the source (replacing the binding's
        value, the declared initial value, or adding a binding) through the
        editor, so it can be undone
- [ ] Phase 8: production hardening (in progress)
  - [x] Fuzzing: targets for the layout solvers, PNG decoding, fonts, SVG
        paths, text boundaries, text editing, the compiler (bytes and
        token sequences), the formatter (keeps tokens, idempotent) and the
        interpreter (generated well-typed programs, run and clicked). They
        take an input that is either `std.testing.Smith` (corpus runs in
        `zig build test`; `--fuzz` once Zig 0.16's test runner compiles in
        that mode) or a seeded generator (`zig build fuzz`, tools/fuzz.zig,
        failures replayable from the printed seed). Found and fixed: the
        formatter joining `!` `=` into `!=` (and any such pair), a
        use-after-free when a property was set to an equal string (the
        property kept the old slice, which the interpreter then freed;
        `set`, `ChangeTracker` and `ArrayModel` now keep the new value), and
        binding loops aborting the preview and the viewer (they now warn)
  - [x] Documentation (docs/): getting started, the language, using
        zigulee from Zig, tooling; reference pages for the built-in elements
        and standard widgets generated from the sources (`zig build docs`).
        `zig build test` checks that the reference is up to date and that
        the guides' examples compile
  - [x] Performance budgets. `zig build bench` (tools/bench.zig,
        ReleaseFast) against budgets, `--check` to fail: on an Apple
        Silicon desktop, a binding re-evaluates in 16 ns, the gallery's
        dark mode toggle re-evaluates in 0.11 ms and redraws in 1.2 ms, a
        full 460x640 frame takes 1.2 ms (RGBA or RGB565; 4.7 ms at 2x), a
        changed row of a 1000-row list redraws in 0.7 ms, the compiler and
        the interpreter take under 1 ms for the gallery; the gallery used
        1.6 MB of heap (64-bit), a todo row 18 KB (before the optimizations
        below). `zig build mcu-size`
        (tools/mcu_demo.zig, tools/mcu_size.zig): examples/mcu/thermostat.zge
        built for a Cortex-M4 takes 139 KB of flash (code and constants,
        no font) and 99 KB of RAM (static memory, and the heap measured in a
        32-bit wasm32 build run with Node.js), within the 300 KB budget.
        Found on the way: generated globals allocated from
        `std.heap.page_allocator` (no such thing on a microcontroller, and
        outside the application's allocator); they now take the first
        component's allocator, and are freed with the last component (no
        more leaks reported in Debug builds). Bare-metal applications must
        provide `std_options.logFn` (documented)
  - [x] Optimizations the measurements pointed at:
        - properties are two words plus the value (`Property(f32)` 40 → 24
          bytes): the dirty flag lives in the binding, and the secondary
          side of a two-way link is a tagged pointer in the binding's slot
        - brushes reference their gradient (76 → 16 bytes, 8 on 32-bit);
          `Brush.linear`/`radial` take comptime stops (static), run-time
          gradients are referenced and must outlive the brush, like
          strings; animations blend gradients in storage they keep
          (`Brush.Blend`), and the 8-stop limit is gone (except for
          blending)
        - render trackers no longer depend on every ancestor's position
          (items take their parent's tracked position; a move re-evaluates
          the subtree): the gallery's dependency edges went from 21,300 to
          11,500
        - box layouts re-bind only children that are new or at a new index
        Result: the gallery's heap 1.6 MB → 1.05 MB, a todo row 17.8 → 14.3
        KB, the MCU demo's heap 88 → 71 KB (RAM 99 → 82 KB); the dark mode
        toggle 108 → 66 us, resize 226 → 118 us, a click and redraw
        279 → 165 us, adding and removing a row of a 1000-row list
        126 → 59 us. Budgets tightened accordingly
  - [x] Lighter components (a todo row 14.3 → 11.2 KB, the MCU demo's
        heap 71 → 63 KB, RAM 74 KB):
        - a global's `out` property with a literal value that nothing
          changes or links to is compiled as a constant: the widgets'
          bindings on `Style` sizes became plain values (a Button's
          bindings 25 → 14)
        - `LayoutConstraints` only for elements whose constraints are
          written (reading `label.preferred-width` does not need one)
        - bindings 80 → 64 bytes (one vtable pointer; the dependent's
          kind is a tag sharing a word with its flags) and callbacks 24 →
          16 bytes
  - [x] An MCU display driver to run the demo on hardware (above,
        Phase 4)
  - [ ] Raspberry Pi measurements
  - [x] Translations: `@tr("text {}", args)`, plurals (`@tr("{n} file" |
        "{n} files" % count)`), contexts (`@tr("menu" => "Open")`),
        positional arguments (`{0}`); in generated code and the
        interpreter. At run time (src/core/i18n.zig) a translator gives
        templates, and every `@tr` depends on it, so switching language
        updates the UI; gettext `.po` catalogs (contexts, plural forms with
        the header's C-like plural rule, fuzzy entries skipped). `zgec tr`
        writes the `.pot` template (with the standard widgets' texts that
        are used); `zigulee-viewer --tr it.po`; the DatePicker's names are
        translatable; the todo example has an Italian translation. Fuzzing
        found two more bugs: `round()`/`floor()`/`ceil()` of out-of-range
        values panicked (now saturating, `zigulee.core.intFromFloat`), and the
        formatter could join three tokens (`1 . 100ms` into `1.100ms`)
  - [x] Right-to-left text: bidi and Arabic shaping (Phase 3b)
  - [x] Accessibility: `accessible-role`, `-label`, `-description`,
        `-value` (with minimum, maximum, step), `-checkable`, `-checked`,
        `-enabled`, `-placeholder-text` on every element and
        `accessible-action-default`/`-increment`/`-decrement`/`-set-value`
        callbacks (an `AccessibleProperties` only for elements that set
        them, also when set where a component is used); the standard
        widgets describe themselves (Button, CheckBox, Switch, Slider,
        SpinBox, ProgressIndicator, Spinner, LineEdit, TextEdit, ComboBox,
        StandardListView, TabWidget). `zigulee.core.accessibility`: a snapshot
        of a window's accessible items (controls are leaves: a button's
        text is not another node; text fields report their text as value,
        never a password), a tracker that reports changes (focus included),
        and actions. macOS bridge (src/backends/macos, used by the SDL3
        backend): NSAccessibility elements made at run time through the
        Objective-C runtime, kept per item, with value, focus and layout
        notifications; tested in-process through AppKit's accessibility API.
        Works while VoiceOver runs (`ZIGULEE_ACCESSIBILITY=1` for
        Accessibility Inspector)
  - [ ] Accessibility on Windows (UIA) and Linux (AT-SPI); checked with
        VoiceOver by a person
  - [x] Stable C ABI (version 1): include/zigulee.h and libzigulee (static
        and shared, src/c_api.zig) over the interpreter: programs and
        instances behind opaque handles, typed values converted to the
        properties' types, callbacks as C function pointers with user data,
        invoking callbacks and public functions, models with row-level
        changes, input and time, rendering into an RGBA buffer (partial,
        HiDPI), fonts, translations. Tested from C (tests/c/api_test.c,
        built with -Werror) and from Zig with a leak-checking allocator;
        every declared function is exported; examples/c/hello.c
  - [x] C API: imports and images through a file-reading callback
        (`zigulee_program_load_with_files`, ABI 1, additive)
  - [x] C API: struct values (ABI 1, additive): `ZIGULEE_STRUCT` and
        `zigulee_struct` handles, built by field name and read as views;
        converted to the expected struct type field by field (defaults
        for missing fields, unknown names an error), nested, in model rows
        (typed by the first property a model is set on), callback
        arguments and results, function arguments and results. Tested from
        Zig (every allocation checked) and from C
  - [x] C API: compiled interfaces (`zgec c`, src/compiler/c_bindings.zig;
        `zigulee.cLibrary` in build.zig): a typed header per `.zge` file
        (handles per exported component, getters and setters by property
        direction, structs as C structs, enums as int32_t constants, models
        as row arrays, callback handlers and invokers, public functions,
        exported globals) and its Zig implementation over the generated
        module, built as a static library without the interpreter (about
        half the size). The C API's window part (src/c_api/window.zig) now
        stands on its own, so `zigulee_window_*` work on compiled components
        through `<component>_instance()`. Tested from C with -Werror
        (tests/c/compiled_test.c)
