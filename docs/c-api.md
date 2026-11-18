# The C API

`libzigulee` runs `.zge` interfaces from C, and from any language that can
call C (C++, Rust, Go, Python's ctypes, ...). The `.zge` source is loaded
at run time, so building the application needs no Zig. The header,
[`include/zigulee.h`](../include/zigulee.h), documents every function.

```sh
zig build    # zig-out/include/zigulee.h, zig-out/lib/libzigulee.a and the shared library
cc app.c -I zig-out/include zig-out/lib/libzigulee.a -o app
```

## A first program

```c
#include <stdio.h>
#include <string.h>
#include "zigulee.h"

static zigulee_value on_add(void *user_data, const zigulee_value *args, size_t n) {
    (void)user_data;
    (void)n; // 2: add(int, int)
    return zigulee_int(args[0].as.i + args[1].as.i);
}

int main(void) {
    const char source[] =
        "export component App inherits Window {\n"
        "    width: 200px; height: 100px;\n"
        "    var in-out <string> name: \"Ada\";\n"
        "    callback add(int, int) -> int;\n"
        "    Text { text: \"Hello, \\{name}!\"; }\n"
        "}\n";
    zigulee_program *program;
    char *errors;
    if (zigulee_program_load("app.zge", source, strlen(source), NULL, &program, &errors) != ZIGULEE_OK) {
        fputs(errors, stderr);
        zigulee_free_errors(errors);
        return 1;
    }
    zigulee_instance *app;
    zigulee_instance_create(program, NULL, &app);

    zigulee_value name = zigulee_str("Grace");
    zigulee_set_property(app, "name", &name);
    zigulee_set_callback(app, "add", on_add, NULL);

    // ... the event loop, below ...

    zigulee_instance_destroy(app);
    zigulee_program_destroy(program);
}
```

Properties, callbacks and public functions are reached by their `.zge`
names, with `zigulee_value`s: tagged values (`ZIGULEE_INT`, `ZIGULEE_STRING`,
`ZIGULEE_COLOR`...) converted to the property's type where it makes sense.
`[T]` properties take a `zigulee_model`, whose rows the application adds,
changes and removes; the elements repeated by `for` follow.

## The event loop

The application owns the window: it shows the pixels zigulee renders and
passes the input and the time.

```c
for (;;) {
    zigulee_update(now_ms());                       // timers, animations, `changed`
    // for each event of your window system:
    zigulee_window_pointer(app, &(zigulee_pointer_event){ .kind = ZIGULEE_POINTER_PRESSED, .x = x, .y = y });
    zigulee_window_key(app, true, "a", 0, false);  // or ZIGULEE_KEY_RETURN...
    if (zigulee_window_needs_redraw(app)) {
        zigulee_rect dirty;
        zigulee_window_render_rgba(app, pixels, width, height, width, scale, false, &dirty);
        // upload the dirty rectangle of `pixels` (premultiplied RGBA)
    }
    // sleep: until the next frame while zigulee_has_active_animations(),
    // else until zigulee_next_timer_deadline() or the next event
}
```

With an OpenGL 3.3 or OpenGL ES 3.0 context of your own, the GPU draws
instead:

```c
zigulee_gl_renderer *gl;
zigulee_gl_renderer_create(get_proc, NULL, &gl); // e.g. wrapping SDL_GL_GetProcAddress
// each frame (context current): the whole window, then swap buffers
zigulee_window_render_gl(app, gl, 0, pixel_width, pixel_height, scale);
// or only what changed (swap only if dirty is not empty):
zigulee_rect dirty;
zigulee_window_render_gl_partial(app, gl, 0, pixel_width, pixel_height, scale, false, &dirty);
```

Text needs a font: `zigulee_font_load` a TrueType file and
`zigulee_window_set_default_font` (or `zigulee_window_register_font` for
`font-family`). Translations: `zigulee_translations_load_po` and
`zigulee_set_translations`.

[examples/c/hello.c](../examples/c/hello.c) loads `examples/hello.zge`,
clicks its button and saves the window as an image:
`zig build run-c-hello`.

## Struct values

Structs declared in `.zge` are `ZIGULEE_STRUCT` values: build one by field
name, set it, read values back as read-only views.

```c
// struct Contact { name: string, age: int, }
zigulee_struct *ada = zigulee_struct_create();
zigulee_value name = zigulee_str("Ada"), age = zigulee_int(36);
zigulee_struct_set(ada, "name", &name);
zigulee_struct_set(ada, "age", &age);
zigulee_value value = zigulee_struct_value(ada);
zigulee_set_property(app, "person", &value); // copied
zigulee_model_push(people, &value);          // rows of a [Contact] too
zigulee_struct_destroy(ada);

zigulee_value v;
zigulee_get_property(app, "person", &v);     // v.as.structure: zigulee's view
zigulee_value field;
zigulee_struct_get(v.as.structure, "age", &field);
```

Values are converted to the struct type expected, field by field: fields
not given take their default, a field name the struct does not have is
`ZIGULEE_ERROR_TYPE`. Fields may be structs, callbacks receive views and may
return structs (copied), functions take and return them. A model's rows
take the row type of the property it is first set on.

## Compiled interfaces

Instead of loading `.zge` at run time, a C program can link its
components compiled: `zigulee.cLibrary` in `build.zig` compiles the file to
a static library (zigulee's runtime and the compiled UI, no interpreter)
with a typed header.

```zig
// build.zig
const app = zigulee.cLibrary(b, .{
    .source = b.path("app.zge"),
    .name = "app", // C names start with app_; the header is app.h
    .zgec = zigulee_dep.artifact("zgec"),
    .zigulee = zigulee_dep.module("zigulee"),
    .c_window = zigulee_dep.module("zigulee-c-window"),
    .target = target,
    .optimize = optimize,
});
exe.root_module.linkLibrary(app.lib);
exe.root_module.addIncludePath(app.include_dir);
exe.root_module.addIncludePath(zigulee_dep.path("include"));
```

For each exported component the header has a handle with typed
functions; structs and enums become C structs and `int32_t` constants:

```c
#include "app.h"

app *ui = app_create();
app_set_count(ui, 5);                         // in, in-out properties
zigulee_string g = app_get_greeting(ui);        // any property
app_contact ada = {{"Ada", 3}, 36};
app_set_person(ui, &ada);                     // structs: copied
app_set_people(ui, rows, row_count);          // [T]: rows, copied
app_on_clicked(ui, on_clicked, user_data);    // callbacks: handlers...
app_clicked(ui);                              // ...and invoking them
zigulee_string s = app_shout(ui, (zigulee_string){"hi", 2}); // public functions
app_theme_set_accent(0xff0000ffu);            // exported globals
// Window, input and rendering: zigulee.h, on the component's instance.
zigulee_window_render_rgba(app_instance(ui), pixels, w, h, w, 1, true, NULL);
app_destroy(ui);
```

`zgec c app.zge --prefix=app` writes the same header and its Zig
implementation without the build helper. Types C cannot represent
(images, easing curves, key events, models of models) are left out, with a
comment in the header.

## Rules

- **Stability:** within `ZIGULEE_ABI_VERSION`, functions are only added;
  structs and constants keep their layout and values. Check
  `zigulee_abi_version()` at start.
- **Memory:** strings passed in are copied when kept. Strings zigulee
  returns are valid until the next call into zigulee. Models, fonts and
  translations must outlive what uses them; instances must be destroyed
  before their program.
- **Threads:** call zigulee from one thread only.
- **Files:** `zigulee_program_load` reads no files: imports other than
  `std-widgets.zge` and `@image-url` images need
  `zigulee_program_load_with_files`, whose callback reads them (paths are
  relative to the loaded file).
