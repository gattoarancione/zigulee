# renderers

- `software/`: the software renderer, the reference (golden-image tests)
  and the one for microcontrollers.
- `gpu/`: the GPU renderer (OpenGL 3.3 / OpenGL ES 3.0). `batch.zig` turns
  display lists into quads for one shader (no GPU needed), `gl.zig` draws
  them, `reference.zig` runs them on the CPU so tests check them against
  the software renderer.

Phase 3 in ROADMAP.md.
