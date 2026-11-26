// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

/*
 * zigulee: the C API.
 *
 * Runs user interfaces written in .zge from C (and any language with a C
 * FFI). The .zge source is loaded at run time (interpreted), so no Zig is
 * needed to build the application; properties, callbacks and functions are
 * reached by name with typed values. The application drives the event
 * loop: it passes input and the time, and renders the window into a pixel
 * buffer it shows.
 *
 * Stability: functions are only added, never changed or removed, within an
 * ABI version (ZIGULEE_ABI_VERSION, checked with zigulee_abi_version()).
 * Structs and enums keep their layout and values; enums are int32_t.
 *
 * Threads: everything runs on one thread (the UI thread).
 *
 * Strings passed to zigulee are copied when kept. Strings zigulee returns
 * (zigulee_string) stay valid until the next call into zigulee unless said
 * otherwise; copy them to keep them.
 */
#ifndef ZIGULEE_H
#define ZIGULEE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ZIGULEE_ABI_VERSION 1

/* ---- Basics ---- */

typedef int32_t zigulee_status;
#define ZIGULEE_OK 0
/* The source has errors (see the errors returned with it). */
#define ZIGULEE_ERROR_COMPILE 1
/* No such component, property, callback or function. */
#define ZIGULEE_ERROR_NOT_FOUND 2
/* A value of the wrong type. */
#define ZIGULEE_ERROR_TYPE 3
#define ZIGULEE_ERROR_OUT_OF_MEMORY 4
/* Invalid input (a malformed .po file, a font that cannot be read...). */
#define ZIGULEE_ERROR_INVALID 5
/* Not supported here (e.g. OpenGL without the functions or shaders it
 * needs). */
#define ZIGULEE_ERROR_UNSUPPORTED 6

/* The ABI version the library implements. */
uint32_t zigulee_abi_version(void);

/* UTF-8 text with a length (not necessarily NUL-terminated). */
typedef struct zigulee_string {
    const char *ptr;
    size_t len;
} zigulee_string;

typedef struct zigulee_program zigulee_program;
typedef struct zigulee_instance zigulee_instance;
typedef struct zigulee_model zigulee_model;
typedef struct zigulee_font zigulee_font;
typedef struct zigulee_translations zigulee_translations;
typedef struct zigulee_struct zigulee_struct;

/* ---- Values ---- */

typedef int32_t zigulee_value_kind;
#define ZIGULEE_VOID 0
#define ZIGULEE_INT 1      /* as.i */
#define ZIGULEE_FLOAT 2    /* as.f */
#define ZIGULEE_LENGTH 3   /* as.f, logical pixels */
#define ZIGULEE_DURATION 4 /* as.i, milliseconds */
#define ZIGULEE_BOOL 5     /* as.b */
#define ZIGULEE_STRING 6   /* as.s */
#define ZIGULEE_COLOR 7    /* as.color, 0xRRGGBBAA (also for brushes) */
#define ZIGULEE_ENUM 8     /* as.s, the value's .zge name ("center") */
#define ZIGULEE_MODEL 9    /* as.model, rows for `for` (setting only) */
#define ZIGULEE_STRUCT 10  /* as.structure, a struct declared in .zge */

typedef struct zigulee_value {
    zigulee_value_kind kind;
    int32_t reserved;
    union {
        int64_t i;
        double f;
        bool b;
        zigulee_string s;
        uint32_t color;
        zigulee_model *model;
        zigulee_struct *structure;
    } as;
} zigulee_value;

/* Values are converted to the property's type where it makes sense (an
 * int to a float or a length, a float to an int); anything else is
 * ZIGULEE_ERROR_TYPE. */
zigulee_value zigulee_int(int64_t v);
zigulee_value zigulee_float(double v);
zigulee_value zigulee_bool(bool v);
zigulee_value zigulee_str(const char *nul_terminated);
zigulee_value zigulee_color(uint32_t rgba);

/* ---- Structs ---- */

/* A struct value: fields by their .zge name. Made with zigulee_struct_create
 * (yours: destroy it), or handed out by zigulee (zigulee's: read-only, valid
 * until the next call that returns a value, as strings).
 *
 * Set on a property, passed as an argument or returned from a callback,
 * a struct is copied and converted to the struct type expected, field by
 * field: fields not given take their default, an unknown field name is
 * ZIGULEE_ERROR_TYPE. Fields may be structs too. */
zigulee_struct *zigulee_struct_create(void);
/* Does nothing for structs zigulee handed out. */
void zigulee_struct_destroy(zigulee_struct *s);
/* Sets (or adds) a field; the value is copied. ZIGULEE_ERROR_INVALID on a
 * struct zigulee handed out. */
zigulee_status zigulee_struct_set(zigulee_struct *s, const char *field, const zigulee_value *value);
/* ZIGULEE_ERROR_NOT_FOUND if there is no such field. */
zigulee_status zigulee_struct_get(const zigulee_struct *s, const char *field, zigulee_value *out);
/* The fields in order (a declared struct's: its declaration's order). */
size_t zigulee_struct_field_count(const zigulee_struct *s);
zigulee_string zigulee_struct_field_name(const zigulee_struct *s, size_t index);
zigulee_status zigulee_struct_field_value(const zigulee_struct *s, size_t index, zigulee_value *out);
/* `s` as a value (still yours). */
zigulee_value zigulee_struct_value(zigulee_struct *s);

/* ---- Programs and instances ---- */

/* Loads .zge source (`file_name` is for messages). Imports other than
 * std-widgets.zge and images need zigulee_program_load_with_files.
 * `style` is the standard widgets' style ("fluent", "material",
 * "minimal"), or NULL for the default. On ZIGULEE_ERROR_COMPILE, `*errors`
 * (if not NULL) receives the messages, freed with zigulee_free_errors. */
zigulee_status zigulee_program_load(const char *file_name, const char *source, size_t source_len, const char *style,
                                zigulee_program **out, char **errors);
void zigulee_free_errors(char *errors);

/* Reads a file the source uses (an imported .zge file, an @image-url
 * image), `path` being relative to the loaded file's directory: copies its
 * contents into `buffer` if they fit in `capacity` bytes, and returns their
 * size either way (zigulee calls again with a large enough buffer), or
 * SIZE_MAX if there is no such file. */
typedef size_t (*zigulee_read_file_fn)(void *user_data, const char *path, uint8_t *buffer, size_t capacity);

/* zigulee_program_load, with imports and images read through `read_file`
 * (images when first shown: `read_file` and `user_data` must stay valid
 * while the program lives). */
zigulee_status zigulee_program_load_with_files(const char *file_name, const char *source, size_t source_len,
                                           const char *style, zigulee_read_file_fn read_file, void *user_data,
                                           zigulee_program **out, char **errors);
void zigulee_program_destroy(zigulee_program *program);

/* Creates an instance of `component` (NULL: the last exported component
 * that inherits Window). Instances must be destroyed before their
 * program. */
zigulee_status zigulee_instance_create(zigulee_program *program, const char *component, zigulee_instance **out);
void zigulee_instance_destroy(zigulee_instance *instance);

/* Declared properties (`in`, `out`, `in-out`), by their .zge name. */
zigulee_status zigulee_get_property(zigulee_instance *instance, const char *name, zigulee_value *out);
zigulee_status zigulee_set_property(zigulee_instance *instance, const char *name, const zigulee_value *value);

/* A handler for a declared callback. `args` are valid during the call; the
 * result is copied. */
typedef zigulee_value (*zigulee_callback_fn)(void *user_data, const zigulee_value *args, size_t arg_count);
zigulee_status zigulee_set_callback(zigulee_instance *instance, const char *name, zigulee_callback_fn fn, void *user_data);

/* Calls a declared callback, or a public function. `result` may be NULL. */
zigulee_status zigulee_invoke(zigulee_instance *instance, const char *name, const zigulee_value *args, size_t arg_count,
                          zigulee_value *result);

/* ---- Models: rows for `[T]` properties ---- */

/* A model must outlive the properties it is set on. Its rows are
 * converted to the row type of the first property it is set on (struct
 * rows by field name, as zigulee_set_property); setting it on a property
 * of another row type is ZIGULEE_ERROR_TYPE. */
zigulee_model *zigulee_model_create(void);
void zigulee_model_destroy(zigulee_model *model);
size_t zigulee_model_count(const zigulee_model *model);
zigulee_status zigulee_model_push(zigulee_model *model, const zigulee_value *value);
zigulee_status zigulee_model_insert(zigulee_model *model, size_t row, const zigulee_value *value);
zigulee_status zigulee_model_set(zigulee_model *model, size_t row, const zigulee_value *value);
zigulee_status zigulee_model_remove(zigulee_model *model, size_t row);
zigulee_status zigulee_model_get(const zigulee_model *model, size_t row, zigulee_value *out);

/* ---- The event loop ---- */

/* Advances the clock (milliseconds, any origin), fires due timers and
 * runs `changed` handlers. Call once per loop iteration. */
void zigulee_update(uint64_t now_ms);
/* Whether animations run (keep rendering frames). */
bool zigulee_has_active_animations(void);
/* The next timer's deadline, if any (sleep until then otherwise). */
bool zigulee_next_timer_deadline(uint64_t *out_ms);

void zigulee_window_set_size(zigulee_instance *instance, float width, float height);
void zigulee_window_size(zigulee_instance *instance, float *width, float *height);
/* Whether something changed since the last render. */
bool zigulee_window_needs_redraw(zigulee_instance *instance);

typedef int32_t zigulee_pointer_kind;
#define ZIGULEE_POINTER_PRESSED 0
#define ZIGULEE_POINTER_RELEASED 1
#define ZIGULEE_POINTER_MOVED 2
#define ZIGULEE_POINTER_WHEEL 3 /* delta_x, delta_y in logical pixels */
#define ZIGULEE_POINTER_EXIT 4

typedef int32_t zigulee_button;
#define ZIGULEE_BUTTON_LEFT 0
#define ZIGULEE_BUTTON_RIGHT 1
#define ZIGULEE_BUTTON_MIDDLE 2

typedef uint32_t zigulee_modifiers;
#define ZIGULEE_MOD_SHIFT 1u
#define ZIGULEE_MOD_CONTROL 2u
#define ZIGULEE_MOD_ALT 4u
#define ZIGULEE_MOD_META 8u

typedef struct zigulee_pointer_event {
    zigulee_pointer_kind kind;
    zigulee_button button;
    float x, y;             /* window coordinates, logical pixels */
    float delta_x, delta_y; /* wheel */
    zigulee_modifiers modifiers;
    int32_t reserved;
} zigulee_pointer_event;

void zigulee_window_pointer(zigulee_instance *instance, const zigulee_pointer_event *event);

/* Special keys, as the `text` of key events. */
#define ZIGULEE_KEY_BACKSPACE "\x08"
#define ZIGULEE_KEY_TAB "\t"
#define ZIGULEE_KEY_RETURN "\n"
#define ZIGULEE_KEY_ESCAPE "\x1b"
#define ZIGULEE_KEY_BACKTAB "\x19"
#define ZIGULEE_KEY_DELETE "\x7f"
#define ZIGULEE_KEY_UP "\xef\x9c\x80"
#define ZIGULEE_KEY_DOWN "\xef\x9c\x81"
#define ZIGULEE_KEY_LEFT "\xef\x9c\x82"
#define ZIGULEE_KEY_RIGHT "\xef\x9c\x83"
#define ZIGULEE_KEY_HOME "\xef\x9c\xa9"
#define ZIGULEE_KEY_END "\xef\x9c\xab"
#define ZIGULEE_KEY_PAGE_UP "\xef\x9c\xac"
#define ZIGULEE_KEY_PAGE_DOWN "\xef\x9c\xad"

/* A key press or release: `text` is what the key types (UTF-8) or a
 * ZIGULEE_KEY_ code. */
void zigulee_window_key(zigulee_instance *instance, bool pressed, const char *text, zigulee_modifiers modifiers, bool repeat);

typedef struct zigulee_rect {
    int32_t x, y, width, height;
} zigulee_rect;

/* Renders the window into `pixels` (premultiplied RGBA, 8 bits per
 * channel, `stride` pixels per row; at least width x height). With
 * `full` false, only what changed since the last render into the same
 * buffer is redrawn (the buffer must keep its contents). `scale` is
 * physical pixels per logical pixel (1, or 2 on Retina displays). The
 * redrawn area goes to `*dirty` (if not NULL), in pixels. */
zigulee_status zigulee_window_render_rgba(zigulee_instance *instance, uint8_t *pixels, uint32_t width, uint32_t height,
                                      uint32_t stride, float scale, bool full, zigulee_rect *dirty);

/* ---- Rendering with OpenGL ---- */

/* Draws windows with the application's OpenGL 3.3 (core) or OpenGL ES 3.0
 * context, which must be current in every call. The pixels are those of
 * zigulee_window_render_rgba (premultiplied alpha: blend with
 * GL_ONE, GL_ONE_MINUS_SRC_ALPHA when compositing them). */
typedef struct zigulee_gl_renderer zigulee_gl_renderer;

/* Returns an OpenGL function by name (as SDL_GL_GetProcAddress,
 * eglGetProcAddress...), or NULL. */
typedef void *(*zigulee_gl_get_proc_fn)(void *user_data, const char *name);

/* ZIGULEE_ERROR_UNSUPPORTED if a function is missing or the shaders do not
 * compile. */
zigulee_status zigulee_gl_renderer_create(zigulee_gl_get_proc_fn get_proc, void *user_data, zigulee_gl_renderer **out);
/* Frees the renderer's OpenGL objects (its context must be current). */
void zigulee_gl_renderer_destroy(zigulee_gl_renderer *renderer);

/* Draws the whole window into OpenGL framebuffer `framebuffer` (0: the
 * default one), `width` x `height` pixels, clearing it first. `scale` is
 * physical pixels per logical pixel. The OpenGL state it sets (program,
 * buffers, textures, blending, viewport) is left as is. */
zigulee_status zigulee_window_render_gl(zigulee_instance *instance, zigulee_gl_renderer *renderer, uint32_t framebuffer,
                                    uint32_t width, uint32_t height, float scale);

/* As zigulee_window_render_gl, but with `full` false only what changed since
 * the last call is redrawn (the renderer keeps the last frame in a texture,
 * and still copies all of it to `framebuffer`). The redrawn area goes to
 * `*dirty` (if not NULL), in pixels: when it is empty, nothing was drawn,
 * so there is no need to swap buffers. */
zigulee_status zigulee_window_render_gl_partial(zigulee_instance *instance, zigulee_gl_renderer *renderer, uint32_t framebuffer,
                                            uint32_t width, uint32_t height, float scale, bool full, zigulee_rect *dirty);

/* ---- Fonts ---- */

/* A TrueType font (.ttf, .ttc) or a pre-rendered one (zigulee-bitmap-font);
 * the data is copied. A font must outlive the
 * instances using it. */
zigulee_status zigulee_font_load(const uint8_t *data, size_t len, zigulee_font **out);
void zigulee_font_destroy(zigulee_font *font);
/* The font of text without a `font-family`. */
void zigulee_window_set_default_font(zigulee_instance *instance, zigulee_font *font);
/* A font for `font-family: "family"` and `font-weight: weight`. */
zigulee_status zigulee_window_register_font(zigulee_instance *instance, const char *family, int32_t weight, zigulee_font *font);
/* A font for characters the others lack (symbols, other scripts), tried
 * in the order added. */
zigulee_status zigulee_window_add_fallback_font(zigulee_instance *instance, zigulee_font *font);

/* ---- Translations (@tr) ---- */

/* A gettext catalog (.po file); the data is copied. */
zigulee_status zigulee_translations_load_po(const char *data, size_t len, zigulee_translations **out);
void zigulee_translations_destroy(zigulee_translations *translations);
/* Translates every @tr from now on (NULL: the source texts). The catalog
 * must stay alive while set. */
void zigulee_set_translations(zigulee_translations *translations);

#ifdef __cplusplus
}
#endif

#endif /* ZIGULEE_H */
