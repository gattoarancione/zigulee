# Proposal: from UI toolkit to app toolkit

Status: an idea, not started (2026-11-18). The questions at the end need
answers before work starts.

## Why

zigulee already goes past drawing: globals, bindings, timers, models,
`Settings`, HTTP requests, camera, video, audio, maps, a web view, tray,
file dialogs, translations, 3D. Apps still write their own I/O in Zig and
wire it to properties by hand: a dashboard decoding CAN frames into a
global's properties, an update flow driven from Zig. A shared way to
expose services to `.zge` would remove that glue, and let an app ship
its own services the same way.

## Principles

- `.zge` stays declarative: state, wiring, reactions. Logic stays in Zig.
- Services are optional modules: a compiled app pays (code, RAM) only for
  what it uses. That holds already for the built-in elements: Zig only
  compiles what the generated program refers to, so the ESP32 does not
  pay for `Video` or `HttpRequest`. It must keep holding: the ESP32 build
  must not grow. The interpreter is the exception: it can only run the
  modules it was linked with, so it carries every one it supports.
- Every module works the same compiled and interpreted, and the LSP knows
  it.
- Every module can be faked from Zig, so a UI can be tested without the
  hardware behind it (a CAN bus, a camera).

## What exists already

- **HTTP:** `HttpRequest` (`url`, `method`, `headers`, `body`; `send()`,
  `abort()`; `status`, `response`, `loading`, `error`; `finished`,
  `failed`).
- **Navigation:** `StackView`, `SwipeView`, `Popup`, `Window`. A back
  stack is a UI element, not a service: it belongs with those.
- **The asynchronous shape:** `HttpRequest`'s is the rule for every
  service: `loading` while it works, `error` when it fails, `finished` and
  `failed` callbacks, `abort()` to cancel. No new names (`busy`).

## Native declarations

Today the built-in elements are one table in the compiler
(`src/compiler/types.zig`), which the interpreter and the LSP read too.
That fits zigulee's own modules but not an app's: a CAN service with DBC
files belongs to the app that needs it, and an app cannot add to that
table.

A service is instead declared in a `.zge` file, and implemented by a Zig
type the declaration names:

```slint
// std-can.zge
export native component CanSignal "zigulee_can.Signal" {
    in property <string> name;
    out property <float> value;
    out property <duration> timestamp;
    out property <bool> loading;
    out property <string> error;
}
```

```slint
import { CanSignal } from "std-can.zge";

export component Dashboard inherits Window {
    speed := CanSignal { name: "VehicleSpeed"; }
    Text { text: "\{round(speed.value)} km/h"; }
}
```

- The compiler and the LSP read it like any `.zge` file: types are
  checked, completion and go to definition work, nothing is added to the
  compiler. `std-widgets.zge` is imported the same way already.
- The compiled program refers to the Zig type: a module not used costs
  nothing.
- The interpreter runs the modules linked into it, and reports a clear
  error for one that is not.
- An app declares its own services in its own `.zge` files, implemented
  in its own Zig code, without changing zigulee.

The only new language is `native`: the rest is library code.

## First modules, in order

1. **`native` declarations**, with a small test module.
2. **CAN signals from a DBC file:** `CanSignal { name: "VehicleSpeed"; }`
   with `value` and `timestamp`. The first real module on the
   mechanism, shipped outside the core: the proof that an app's service
   works the same way. Linux SocketCAN first; the ESP32's CAN controller
   (TWAI) is a later, separate backend.
3. **Files and structured storage:** what `Settings` cannot do (lists,
   records, size), stated as such.

Later: serial ports, websockets, packaging and updates.

## Open questions

- The declaration's syntax: the Zig type after the name, as above, or an
  annotation.
- Models: how a native service exposes one (a list of CAN frames, files
  in a folder).
- Where a module's Zig code lives and how an app links it: a package of
  its own, or a build option of zigulee.
- How a service is faked in tests: a Zig interface the test replaces, or
  properties set from the test.
