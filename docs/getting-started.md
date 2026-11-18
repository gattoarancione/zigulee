# Getting started

This guide makes a small app: a window with a counter, written in `.zge`
and run from Zig. It needs **Zig 0.16.0**.

## A new project

```sh
mkdir hello && cd hello
zig init --minimal
zig fetch --save git+https://github.com/<owner>/zigulee
```

## The UI

`ui/app.zge`:

```slint
import { Button, Palette } from "std-widgets.zge";

export component App inherits Window {
    title: "Hello";
    width: 320px;
    height: 200px;
    background: Palette.background;

    var in-out <int> count;
    callback reset();

    VerticalLayout {
        padding: 16px;
        spacing: 8px;
        Text {
            text: "Clicked \{count} times";
            color: Palette.foreground;
            horizontal-alignment: center;
        }
        Button { text: "+1"; primary: true; clicked => { count += 1; } }
        Button { text: "Reset"; clicked => { root.reset(); } }
    }
}
```

## The build

`build.zig`:

```zig
const std = @import("std");
const zigulee = @import("zigulee");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zigulee_dep = b.dependency("zigulee", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigulee", .module = zigulee_dep.module("zigulee") },
                .{ .name = "zigulee-sdl3", .module = zigulee_dep.module("zigulee-sdl3") },
                // Compiles ui/app.zge to Zig at build time.
                .{ .name = "ui", .module = zigulee.uiModuleFromDependency(b, zigulee_dep, b.path("ui/app.zge"), target, optimize) },
            },
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the app").dependOn(&run.step);
}
```

The first build fetches and compiles SDL (for the window), which takes a
while. On macOS it needs Xcode.

## The code

`src/main.zig`:

```zig
const std = @import("std");
const zigulee = @import("zigulee");
const sdl3 = @import("zigulee-sdl3");
const ui = @import("ui");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const app = try ui.App.create(gpa);
    defer app.destroy();

    // zigulee ships no font: bring your own TrueType file.
    const font: zigulee.Font = try .init(@embedFile("Inter-Regular.ttf"));
    app.window().default_font.set(&font);

    // Callbacks declared in .zge are implemented in Zig.
    app.reset.setHandler(app, struct {
        fn f(a: *ui.App) void {
            a.count.set(0);
        }
    }.f);

    try sdl3.init();
    defer sdl3.deinit();
    const window = try sdl3.Window.create(gpa, app.window(), .{ .title = "Hello" });
    defer window.destroy();
    try window.run(); // returns when the window is closed
}
```

Put a font next to `main.zig` (zigulee's repository has
[Inter](../examples/fonts/inter) in `examples/fonts`), then:

```sh
zig build run
```

## Next

- Iterate on the UI without rebuilding: `zigulee-viewer ui/app.zge` shows it
  and reloads it on every save, and the VS Code extension previews it as
  you type. See [tooling](tooling.md).
- The [language guide](language.md) covers everything `.zge` can do.
- [Embedding](embedding.md) covers the Zig side: properties, callbacks,
  models, globals, event loops and rendering without SDL.
- Reference: [built-in elements](reference/elements.md) and
  [standard widgets](reference/widgets.md).
