// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

/* A compiled component from C: the typed header zgec generates, linked
 * against its library (no interpreter). Run by `zig build test`. */
#include <stdio.h>
#include <string.h>

#include "people.h"

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

static zigulee_string str(const char *s) {
    zigulee_string out = {s, strlen(s)};
    return out;
}

static int clicks = 0;
static void on_clicked(void *user_data) {
    (void)user_data;
    clicks++;
}

static char described[64];
static zigulee_string on_describe(void *user_data, people_contact c, int32_t extra) {
    (void)user_data;
    snprintf(described, sizeof described, "%.*s is %d+%d", (int)c.name.len, c.name.ptr, (int)c.age, (int)extra);
    return str(described);
}

int main(void) {
    people *app = people_create();
    CHECK(app != NULL);

    /* Plain values. */
    CHECK(people_get_count(app) == 1);
    people_set_count(app, 5);
    CHECK(people_get_count(app) == 5);
    CHECK(people_set_name(app, str("Grace")) == ZIGULEE_OK);
    CHECK(str_eq(people_get_greeting(app), "Hello, Grace!"));
    CHECK(people_get_size(app) == 10.0f);
    CHECK(people_get_mode(app) == PEOPLE_MODE_LIGHT);

    /* Structs, nested. */
    people_contact p = people_get_person(app);
    CHECK(str_eq(p.name, "Ada") && p.age == 36 && str_eq(p.home.city, "London"));
    char name[] = "Linus";
    people_contact linus = {str(name), 54, {str("Portland")}};
    CHECK(people_set_person(app, &linus) == ZIGULEE_OK);
    name[0] = 'X'; /* copied: zigulee does not see this */
    p = people_get_person(app);
    CHECK(str_eq(p.name, "Linus") && p.age == 54 && str_eq(p.home.city, "Portland"));
    name[0] = 'L';

    /* Models. */
    people_contact rows[2] = {linus, {str("Edsger"), 72, {str("Austin")}}};
    CHECK(people_set_people(app, rows, 2) == ZIGULEE_OK);
    CHECK(people_get_total(app) == 2);
    CHECK(people_people_count(app) == 2);
    CHECK(str_eq(people_people_row(app, 1).name, "Edsger"));
    CHECK(people_people_row(app, 9).age == 0);
    CHECK(people_set_people(app, rows, 1) == ZIGULEE_OK);
    CHECK(people_get_total(app) == 1);

    /* Callbacks: handlers in C, invoked from C. */
    people_on_clicked(app, on_clicked, NULL);
    people_clicked(app);
    people_clicked(app);
    CHECK(clicks == 2);
    people_on_describe(app, on_describe, NULL);
    CHECK(str_eq(people_describe(app, linus, 1), "Linus is 54+1"));
    people_on_clicked(app, NULL, NULL);
    people_clicked(app);
    CHECK(clicks == 2);

    /* Public functions. */
    CHECK(str_eq(people_shout(app, str("hey")), "hey!"));
    people_contact older = people_older(app, linus);
    CHECK(older.age == 55 && str_eq(older.home.city, "Portland"));

    /* A global. */
    CHECK(people_theme_get_accent() == 0x336699ffu);

    /* The window: zigulee.h's functions, on the instance. */
    zigulee_instance *window = people_instance(app);
    float w = 0, h = 0;
    zigulee_window_size(window, &w, &h);
    CHECK(w == 120 && h == 80);
    uint8_t pixels[120 * 80 * 4];
    CHECK(zigulee_window_render_rgba(window, pixels, 120, 80, 120, 1, true, NULL) == ZIGULEE_OK);
    CHECK(pixels[0] == 0x33 && pixels[1] == 0x66 && pixels[2] == 0x99);
    people_theme_set_accent(0xff0000ffu);
    people_set_mode(app, PEOPLE_MODE_LIGHT);
    CHECK(zigulee_window_render_rgba(window, pixels, 120, 80, 120, 1, false, NULL) == ZIGULEE_OK);
    CHECK(pixels[0] == 0xff && pixels[1] == 0x00);
    people_set_mode(app, PEOPLE_MODE_DARK);
    CHECK(zigulee_window_render_rgba(window, pixels, 120, 80, 120, 1, false, NULL) == ZIGULEE_OK);
    CHECK(pixels[0] == 0x00 && pixels[3] == 0xff);

    people_destroy(app);
    if (failures) fprintf(stderr, "%d check(s) failed\n", failures);
    return failures ? 1 : 0;
}
