// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

/*
 * zigulee from C: loads examples/hello.zge, clicks its button three times and
 * saves the window as hello.ppm. `zig build run-c-hello` (from the
 * repository root, where the paths below are).
 *
 * A real application would show the pixels in its window instead, and pass
 * its input events and the time to zigulee.
 */
#include <stdio.h>
#include <stdlib.h>

#include "zigulee.h"

static char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    *len = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    char *data = malloc(*len);
    if (data && fread(data, 1, *len, f) != *len) {
        free(data);
        data = NULL;
    }
    fclose(f);
    return data;
}

static void click(zigulee_instance *app, float x, float y) {
    zigulee_pointer_event e = {.kind = ZIGULEE_POINTER_PRESSED, .button = ZIGULEE_BUTTON_LEFT, .x = x, .y = y};
    zigulee_window_pointer(app, &e);
    e.kind = ZIGULEE_POINTER_RELEASED;
    zigulee_window_pointer(app, &e);
}

int main(void) {
    size_t len = 0;
    char *source = read_file("examples/hello.zge", &len);
    if (!source) {
        fprintf(stderr, "run from the repository root\n");
        return 1;
    }
    zigulee_program *program = NULL;
    char *errors = NULL;
    if (zigulee_program_load("hello.zge", source, len, NULL, &program, &errors) != ZIGULEE_OK) {
        fprintf(stderr, "%s", errors ? errors : "cannot load hello.zge\n");
        zigulee_free_errors(errors);
        return 1;
    }
    free(source);
    zigulee_instance *app = NULL;
    zigulee_instance_create(program, NULL, &app);

    size_t font_len = 0;
    char *font_data = read_file("examples/fonts/inter/Inter-Regular.ttf", &font_len);
    zigulee_font *font = NULL;
    if (font_data && zigulee_font_load((const uint8_t *)font_data, font_len, &font) == ZIGULEE_OK)
        zigulee_window_set_default_font(app, font);
    free(font_data);

    // The "+1" button of hello.zge, three times.
    for (int i = 0; i < 3; i++) click(app, 180, 112);
    zigulee_value count;
    zigulee_get_property(app, "count", &count);
    printf("count = %lld\n", (long long)count.as.i);

    // Render at 2x, as on a Retina display, and save as PPM.
    float w, h;
    zigulee_window_size(app, &w, &h);
    uint32_t pw = (uint32_t)(w * 2), ph = (uint32_t)(h * 2);
    uint8_t *pixels = malloc((size_t)pw * ph * 4);
    zigulee_update(0);
    zigulee_window_render_rgba(app, pixels, pw, ph, pw, 2, true, NULL);
    FILE *out = fopen("hello.ppm", "wb");
    fprintf(out, "P6 %u %u 255\n", pw, ph);
    for (size_t i = 0; i < (size_t)pw * ph; i++) fwrite(&pixels[i * 4], 1, 3, out); // opaque: premultiplied = straight
    fclose(out);
    printf("wrote hello.ppm (%ux%u)\n", pw, ph);

    free(pixels);
    zigulee_instance_destroy(app);
    zigulee_font_destroy(font);
    zigulee_program_destroy(program);
    return 0;
}
