# Tooling

`zig build` installs the tools in `zig-out/bin`.

## zigulee-viewer

Shows a `.zge` file in a window without compiling Zig (it is interpreted),
and reloads it whenever the file or one it imports is saved. Errors show in
the window until they are fixed.

```sh
zigulee-viewer app.zge [--component Name] [--style fluent|material|minimal] [--tr it.po]
zigulee-viewer app.zge --screenshot out.png   # render once to a PNG and exit
zig build run-viewer -- app.zge             # from the zigulee repository
```

It shows the last exported component that inherits `Window`, or
`--component`; `--tr` shows it translated with a gettext catalog.

## zigulee-bitmap-font

Pre-renders a TrueType font for microcontrollers (see
[embedding](embedding.md#microcontrollers); `zigulee.bitmapFont` runs it from
build.zig):

```sh
zigulee-bitmap-font Inter-Regular.ttf -o inter.zbf --sizes 13,16,40 --chars 20-7e,2026 --text "°€"
```

## zgec

The compiler, which `uiModule` runs at build time:

```sh
zgec app.zge -o app.zig [--style=fluent|material|minimal]
```

and the formatter:

```sh
zgec fmt app.zge widgets/*.zge   # format in place
zgec fmt --check *.zge           # list unformatted files, fail if any
zgec fmt --stdin < in.zge        # format standard input to standard output
```

The formatter only changes whitespace: indentation, spacing, and line
breaks between statements. It keeps comments, blank lines (one at most)
and the line breaks you put inside long expressions.

## Translations

`zgec tr` writes the texts marked with `@tr` as a gettext template, with
where each is used, for translators to make `.po` files from (with
`msginit`, Poedit, or any gettext tool):

```sh
zgec tr ui/*.zge -o messages.pot      # the standard widgets' texts included
msginit -i messages.pot -l it -o it.po
msgmerge -U it.po messages.pot        # after the texts change
```

The texts of the standard widgets used (the DatePicker's month and day
names, with the context `DatePicker`) are included.

## zigulee-lsp and VS Code

`zigulee-lsp` is a language server (over stdio): errors as you type,
completion, hover, go to definition (also into the standard widgets), find
references and rename across the workspace, outline and formatting.

`editors/vscode` is a VS Code extension using it, with a live preview that
runs the file being edited, updates as you type, and lets you Alt+click an
element to jump to its source and edit its properties. See
[its README](../editors/vscode/README.md) to install it.

Other editors can run `zigulee-lsp` for `*.zge` files; its setting `style`
(initialization option) picks the widgets' style.

## Tests and checks (zigulee repository)

```sh
zig build test                    # unit, compiler, interpreter and golden-image tests
zig build test -Dupdate-golden    # accept new rendering output (review tests/golden!)
zig build docs                    # regenerate docs/reference from the sources
zig build fuzz -- [iterations] [target] [seed]
zig build bench [-- --check]      # benchmarks against their budgets
zig build mcu-size [-- --check]   # code size and RAM of the MCU demo
zig build check-mcu               # compile the core for a bare-metal Cortex-M4
```

`zig build test` also checks that `docs/reference` is up to date and that
the examples in these guides compile.

### Performance budgets

`zig build bench` (built ReleaseFast) measures the reactive core, the
gallery (re-evaluating bindings, layout, redrawing, full frames in RGBA
and RGB565), lists of 1000 rows, the compiler, the interpreter and memory
(per element of the gallery, per row of a list), and compares each with a
budget (`--check` fails when one is exceeded).
The budgets are for a desktop computer; the ROADMAP's targets are binding
re-evaluation in well under a millisecond and 60 fps software rendering on
a Raspberry Pi, several times slower.

`zig build mcu-size` measures a UI for a microcontroller,
[examples/mcu/thermostat.zge](../examples/mcu/thermostat.zge) in the
minimal style, as a device would run it (tools/mcu_demo.zig: a fixed
heap, RGB565 rendering in bands of 16 lines). Code size and static memory
come from a Cortex-M4 build; the heap is measured by running a wasm32
build (32-bit, like the Cortex-M4) with Node.js. The budget is 300 KB of
RAM, and 256 KB of flash for code and constants (fonts not included).

### Fuzzing

The fuzz targets (`src/*/fuzz_test.zig`) feed generated input to the
layout solver, the PNG decoder, the font reader, SVG path parsing, text
editing, the compiler, the formatter and the interpreter, and check what
must hold for any input. `zig build test` runs each on a small corpus;
`zig build fuzz` runs them on many random inputs:

```sh
zig build fuzz -- 20000              # every target, 20000 inputs each
zig build fuzz -- 100000 format      # one target
```

A failure prints the target and the seed of the failing input; the
printed command (`zig build fuzz -- 1 <target> <seed>`) repeats it. Zig's
own coverage-guided fuzzer (`zig build test --fuzz`) does not compile on
Zig 0.16.0 (a bug in the standard library's test runner); the targets are
ready for it once it does.
