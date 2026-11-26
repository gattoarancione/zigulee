// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

/* The C API used from C: run by `zig build test`. */
#include <stdio.h>
#include <string.h>

#include "zigulee.h"

static int failures = 0;

#define CHECK(cond)                                                    \
    do {                                                               \
        if (!(cond)) {                                                 \
            fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                \
        }                                                              \
    } while (0)

static bool str_eq(zigulee_string s, const char *expected) {
    return s.len == strlen(expected) && memcmp(s.ptr, expected, s.len) == 0;
}

static const char source[] =
    "import { Button } from \"std-widgets.zge\";\n"
    "export component App inherits Window {\n"
    "    width: 100px;\n"
    "    height: 60px;\n"
    "    background: #ff0000;\n"
    "    var in-out <int> count: 1;\n"
    "    var in-out <string> name: \"Ada\";\n"
    "    var in-out <length> size: 10px;\n"
    "    var in-out <bool> on;\n"
    "    var in-out <TextHorizontalAlignment> align: left;\n"
    "    var in <[string]> names;\n"
    "    var out <string> greeting: \"Hello, \\{name}!\";\n"
    "    var out <int> rows: names.length;\n"
    "    var out <string> translated: @tr(\"Hello\");\n"
    "    callback add(int, int) -> int;\n"
    "    callback said(string);\n"
    "    public function twice(x: int) -> int { return x * 2; }\n"
    "    TouchArea { clicked => { count += 1; root.said(name); } }\n"
    "}\n";

/* Files for zigulee_program_load_with_files: one import. */
static const char theme_source[] =
    "export global Theme { var out <string> greeting: \"from theme.zge\"; }\n";

static size_t read_file(void *user_data, const char *path, uint8_t *buffer, size_t capacity) {
    int *reads = user_data;
    (*reads)++;
    if (strcmp(path, "theme.zge") != 0) return SIZE_MAX;
    size_t len = strlen(theme_source);
    if (len <= capacity) memcpy(buffer, theme_source, len);
    return len;
}

static zigulee_value add(void *user_data, const zigulee_value *args, size_t n) {
    (void)user_data;
    if (n != 2) return zigulee_int(-1);
    return zigulee_int(args[0].as.i + args[1].as.i);
}

static char said_text[64];

static zigulee_value said(void *user_data, const zigulee_value *args, size_t n) {
    int *calls = user_data;
    (*calls)++;
    if (n == 1 && args[0].kind == ZIGULEE_STRING && args[0].as.s.len < sizeof said_text) {
        memcpy(said_text, args[0].as.s.ptr, args[0].as.s.len);
        said_text[args[0].as.s.len] = 0;
    }
    zigulee_value none = {0};
    return none;
}

int main(void) {
    CHECK(zigulee_abi_version() == ZIGULEE_ABI_VERSION);
    CHECK(sizeof(zigulee_value) == 8 + 2 * sizeof(size_t));
    CHECK(sizeof(zigulee_pointer_event) == 32);

    /* Errors come back as text. */
    zigulee_program *bad = NULL;
    char *errors = NULL;
    const char bad_source[] = "export component A { width: 10; }";
    CHECK(zigulee_program_load("bad.zge", bad_source, strlen(bad_source), NULL, &bad, &errors) == ZIGULEE_ERROR_COMPILE);
    CHECK(bad == NULL && errors != NULL && strstr(errors, "add a unit") != NULL);
    zigulee_free_errors(errors);

    zigulee_program *program = NULL;
    CHECK(zigulee_program_load("app.zge", source, strlen(source), "fluent", &program, NULL) == ZIGULEE_OK);
    if (!program) return 1;
    zigulee_instance *app = NULL;
    CHECK(zigulee_instance_create(program, NULL, &app) == ZIGULEE_OK);
    CHECK(zigulee_instance_create(program, "Nope", &(zigulee_instance *){NULL}) == ZIGULEE_ERROR_NOT_FOUND);
    if (!app) return 1;

    /* Properties, converted to their types. */
    zigulee_value v;
    CHECK(zigulee_get_property(app, "count", &v) == ZIGULEE_OK && v.kind == ZIGULEE_INT && v.as.i == 1);
    v = zigulee_float(2.75);
    CHECK(zigulee_set_property(app, "count", &v) == ZIGULEE_OK);
    CHECK(zigulee_get_property(app, "count", &v) == ZIGULEE_OK && v.as.i == 2);
    v = zigulee_str("Grace");
    CHECK(zigulee_set_property(app, "name", &v) == ZIGULEE_OK);
    CHECK(zigulee_get_property(app, "greeting", &v) == ZIGULEE_OK && v.kind == ZIGULEE_STRING && str_eq(v.as.s, "Hello, Grace!"));
    v = zigulee_int(3);
    CHECK(zigulee_set_property(app, "name", &v) == ZIGULEE_ERROR_TYPE);
    CHECK(zigulee_set_property(app, "nope", &v) == ZIGULEE_ERROR_NOT_FOUND);
    CHECK(zigulee_get_property(app, "size", &v) == ZIGULEE_OK && v.kind == ZIGULEE_LENGTH && v.as.f == 10);
    v = zigulee_bool(true);
    CHECK(zigulee_set_property(app, "on", &v) == ZIGULEE_OK);
    CHECK(zigulee_get_property(app, "on", &v) == ZIGULEE_OK && v.kind == ZIGULEE_BOOL && v.as.b);
    v = zigulee_str("center");
    v.kind = ZIGULEE_ENUM;
    CHECK(zigulee_set_property(app, "align", &v) == ZIGULEE_OK);
    CHECK(zigulee_get_property(app, "align", &v) == ZIGULEE_OK && v.kind == ZIGULEE_ENUM && str_eq(v.as.s, "center"));

    /* Models. */
    zigulee_model *names = zigulee_model_create();
    v = zigulee_str("a");
    CHECK(zigulee_model_push(names, &v) == ZIGULEE_OK);
    v = zigulee_str("b");
    CHECK(zigulee_model_push(names, &v) == ZIGULEE_OK);
    zigulee_value m = {.kind = ZIGULEE_MODEL, .as.model = names};
    CHECK(zigulee_set_property(app, "names", &m) == ZIGULEE_OK);
    CHECK(zigulee_get_property(app, "rows", &v) == ZIGULEE_OK && v.as.i == 2);
    CHECK(zigulee_model_remove(names, 0) == ZIGULEE_OK);
    CHECK(zigulee_get_property(app, "rows", &v) == ZIGULEE_OK && v.as.i == 1);
    CHECK(zigulee_model_get(names, 0, &v) == ZIGULEE_OK && str_eq(v.as.s, "b"));
    CHECK(zigulee_model_remove(names, 5) == ZIGULEE_ERROR_NOT_FOUND);

    /* Callbacks implemented in C, and invoked from C. */
    CHECK(zigulee_set_callback(app, "add", add, NULL) == ZIGULEE_OK);
    zigulee_value args[2] = {zigulee_int(2), zigulee_int(3)};
    zigulee_value result;
    CHECK(zigulee_invoke(app, "add", args, 2, &result) == ZIGULEE_OK && result.as.i == 5);
    CHECK(zigulee_invoke(app, "add", args, 1, &result) == ZIGULEE_ERROR_TYPE);
    zigulee_value x = zigulee_int(21);
    CHECK(zigulee_invoke(app, "twice", &x, 1, &result) == ZIGULEE_OK && result.as.i == 42);
    int said_calls = 0;
    CHECK(zigulee_set_callback(app, "said", said, &said_calls) == ZIGULEE_OK);

    /* Input: a click on the TouchArea runs its handler. */
    zigulee_update(1000);
    zigulee_pointer_event e = {.kind = ZIGULEE_POINTER_PRESSED, .button = ZIGULEE_BUTTON_LEFT, .x = 50, .y = 30};
    zigulee_window_pointer(app, &e);
    e.kind = ZIGULEE_POINTER_RELEASED;
    zigulee_window_pointer(app, &e);
    CHECK(zigulee_get_property(app, "count", &v) == ZIGULEE_OK && v.as.i == 3);
    CHECK(said_calls == 1 && strcmp(said_text, "Grace") == 0);
    zigulee_window_key(app, true, ZIGULEE_KEY_TAB, 0, false);

    /* Rendering: the red background, premultiplied RGBA. */
    float w = 0, h = 0;
    zigulee_window_size(app, &w, &h);
    CHECK(w == 100 && h == 60);
    static uint8_t pixels[100 * 60 * 4];
    zigulee_rect dirty;
    CHECK(zigulee_window_needs_redraw(app));
    CHECK(zigulee_window_render_rgba(app, pixels, 100, 60, 100, 1, true, &dirty) == ZIGULEE_OK);
    CHECK(pixels[0] == 255 && pixels[1] == 0 && pixels[2] == 0 && pixels[3] == 255);
    CHECK(dirty.width == 100 && dirty.height == 60);
    CHECK(!zigulee_window_needs_redraw(app));

    /* Translations. */
    const char po[] = "msgid \"Hello\"\nmsgstr \"Ciao\"\n";
    zigulee_translations *it = NULL;
    CHECK(zigulee_translations_load_po(po, strlen(po), &it) == ZIGULEE_OK);
    zigulee_set_translations(it);
    CHECK(zigulee_get_property(app, "translated", &v) == ZIGULEE_OK && str_eq(v.as.s, "Ciao"));
    zigulee_set_translations(NULL);
    CHECK(zigulee_get_property(app, "translated", &v) == ZIGULEE_OK && str_eq(v.as.s, "Hello"));
    zigulee_translations_destroy(it);
    CHECK(zigulee_translations_load_po("bogus", 5, &it) == ZIGULEE_ERROR_INVALID);

    /* Fonts: invalid data is rejected. */
    zigulee_font *font = NULL;
    CHECK(zigulee_font_load((const uint8_t *)"nope", 4, &font) == ZIGULEE_ERROR_INVALID && font == NULL);

    /* Imports, read through a callback. */
    const char importing[] =
        "import { Theme } from \"theme.zge\";\n"
        "export component B inherits Window { var out <string> text: Theme.greeting; }\n";
    int reads = 0;
    zigulee_program *with_files = NULL;
    CHECK(zigulee_program_load_with_files("b.zge", importing, strlen(importing), NULL, read_file, &reads, &with_files, NULL) == ZIGULEE_OK);
    CHECK(reads >= 1);
    if (with_files) {
        zigulee_instance *b = NULL;
        CHECK(zigulee_instance_create(with_files, NULL, &b) == ZIGULEE_OK);
        CHECK(zigulee_get_property(b, "text", &v) == ZIGULEE_OK && str_eq(v.as.s, "from theme.zge"));
        zigulee_instance_destroy(b);
        zigulee_program_destroy(with_files);
    }
    const char missing[] = "import { X } from \"nope.zge\";\nexport component C inherits Window { }\n";
    errors = NULL;
    CHECK(zigulee_program_load_with_files("c.zge", missing, strlen(missing), NULL, read_file, &reads, &with_files, &errors) == ZIGULEE_ERROR_COMPILE);
    CHECK(errors && strstr(errors, "nope.zge") != NULL);
    zigulee_free_errors(errors);

    /* Struct values: built by field name, read back as views. */
    const char people_source[] =
        "struct Contact { name: string, age: int, }\n"
        "export component People inherits Window {\n"
        "    var in-out <Contact> person;\n"
        "    var in <[Contact]> people;\n"
        "    var out <string> summary: \"\\{person.name} \\{person.age} \\{people.length}\";\n"
        "}\n";
    zigulee_program *people_program = NULL;
    CHECK(zigulee_program_load("people.zge", people_source, strlen(people_source), NULL, &people_program, NULL) == ZIGULEE_OK);
    zigulee_instance *people = NULL;
    CHECK(people_program && zigulee_instance_create(people_program, NULL, &people) == ZIGULEE_OK);
    if (people) {
        zigulee_struct *ada = zigulee_struct_create();
        zigulee_value field = zigulee_str("Ada");
        CHECK(zigulee_struct_set(ada, "name", &field) == ZIGULEE_OK);
        field = zigulee_int(36);
        CHECK(zigulee_struct_set(ada, "age", &field) == ZIGULEE_OK);
        zigulee_value value = zigulee_struct_value(ada);
        CHECK(zigulee_set_property(people, "person", &value) == ZIGULEE_OK);
        zigulee_model *rows = zigulee_model_create();
        CHECK(zigulee_model_push(rows, &value) == ZIGULEE_OK);
        zigulee_value model_value = {.kind = ZIGULEE_MODEL, .as.model = rows};
        CHECK(zigulee_set_property(people, "people", &model_value) == ZIGULEE_OK);
        zigulee_struct_destroy(ada);
        CHECK(zigulee_get_property(people, "summary", &v) == ZIGULEE_OK && str_eq(v.as.s, "Ada 36 1"));
        CHECK(zigulee_get_property(people, "person", &v) == ZIGULEE_OK && v.kind == ZIGULEE_STRUCT);
        CHECK(zigulee_struct_field_count(v.as.structure) == 2);
        CHECK(str_eq(zigulee_struct_field_name(v.as.structure, 0), "name"));
        CHECK(zigulee_struct_field_value(v.as.structure, 1, &field) == ZIGULEE_OK && field.kind == ZIGULEE_INT && field.as.i == 36);
        zigulee_instance_destroy(people);
        zigulee_model_destroy(rows);
    }
    zigulee_program_destroy(people_program);

    zigulee_instance_destroy(app);
    zigulee_model_destroy(names);
    zigulee_program_destroy(program);
    if (failures) fprintf(stderr, "%d check(s) failed\n", failures);
    return failures ? 1 : 0;
}
