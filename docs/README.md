# zigulee documentation

- [Getting started](getting-started.md): a first app, from `zig init` to a
  window.
- [The `.zge` language](language.md): components, properties, bindings,
  layouts, `for` and `if`, states, animations, globals.
- [Using zigulee from Zig](embedding.md): the generated code, models, fonts,
  event loops, rendering, the interpreter.
- [Tooling](tooling.md): the viewer, the compiler and formatter, the
  language server and VS Code extension, tests and fuzzing.
- [The C API](c-api.md): `libzigulee` and `zigulee.h`, for C and other
  languages.

Reference (generated from the sources by `zig build docs`):

- [Built-in elements](reference/elements.md)
- [Standard widgets](reference/widgets.md)

Examples are in [`examples/`](../examples): `zig build run-hello`,
`zig build run-gallery`, `zig build run-todo` (a list model owned by Zig,
with its logic tested headless in `tests/ui_test.zig`),
`zig build run-patrisio` (a platformer written entirely in `.zge`: a
`Timer` runs the game, recursive functions find collisions, `Sound` and
`Music` play its effects and tune), `zig build run-video` (a
`VideoPlayer`; `-- movie.mp4` plays a file), and the
others listed in the [README](../README.md#build).
