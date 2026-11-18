# Proposal: `var`, untyped by default, typed when wanted

Status: phase 1 done (2026-11-18): `var` declares properties, its type
still needed; `property` is gone (the compiler says what to write). The
questions below are answered (2026-11-18). It answers the roadmap's
"`var`, `list<T>` of anything" (❌) and part of "JavaScript in handlers:
objects and array building" (🟡). The questions at the end need answers
before work starts.

## Syntax

```
var [in | out | in-out] [<type>] name [: expr | <=> target];
```

Everything after `var` is optional but the name; the modifiers come in a
fixed order (who may set it, then the type).

```slint
component Panel inherits Rectangle {
    var count;                        // private, untyped, null to start
    var title: "Hello";               // private, untyped, a string to start
    var in config;                    // set by the user of the component, anything
    var in-out <int> level: 3;        // exactly today's `in-out property <int> level: 3;`
    var out <bool> full: level > 9;   // exactly today's `out property`
    var in <[any]> rows;              // a list of anything
    var picked <=> list.current;      // untyped link: takes the other side's type
}
```

- `property` is gone (decided 2026-11-18): `var` is the only spelling.
  The compiler rejects `in-out property <int> x` and says to write
  `var in-out <int> x`.
- A new type, `any`, wherever a type can be written: `<any>`, `<[any]>`,
  function and callback parameters. Untyped parameters are `any`:
  `function f(a, b)`, `callback picked(any)`.
- Handler locals keep `let` (`let x = 1;` takes the value's type);
  `let x: any = 1;` is a local that can take any value later.

## What "untyped" means

Two possible meanings, at very different costs:

1. The start value's type: `var title: "Hello"` is a string, fixed at
   compile time. Free and checked early, but not JS: `title = 3` later is
   an error.
2. A dynamic value: `var title` holds whatever is assigned, checked while
   the program runs. What was asked for.

Decided (2026-11-18): dynamic as declared, but a var bound to a typed
property of an element takes that property's type, fixed at compile time.

```slint
component Panel inherits Rectangle {
    var size: 10px;          // bound below to width: a length, for good
    var label;               // only ever read by handlers: dynamic
    Rectangle { width: size; }
    clicked => { size = 20px; label = "hi"; label = 3; }   // `size = 3` is a compile error
}
```

- Bound means: the whole value of a typed property's binding
  (`width: size;`), or linked to it with `<=>` (`width <=> size;`,
  `var size <=> r.width;`). A var used inside a larger expression
  (`width: size * 2;`) is not bound by it: it stays dynamic there, and
  the result is checked when the program runs.
- From then on it is a typed property in all but spelling: its start
  value and every assignment are checked at compile time, it costs what a
  typed property costs, and its Zig field (if `in`, `out` or `in-out`) has
  that type.
- Bound to two different types (`width: v;` and `text: v;`): a compile
  error naming both places.
- Otherwise it stays dynamic. A private one only ever given one type is
  still stored as that type, as no one can tell (no cost, same
  behaviour); the LSP can hint "always an int: `<int>` makes it typed".
  An unbound `in`, `out` or `in-out` var stays dynamic: its Zig type is
  the component's public API and must not change behind the author's
  back.

## The dynamic value: `zigulee.Any`

The compiled code's counterpart of the interpreter's `Value`
(src/interpreter/value.zig, already tagged: the interpreter has most of
it).

- Holds: null, bool, number; values with units (length, duration, angle:
  `10px` stays a length); string, color, brush, image, audio, video; enum
  and struct values; lists and objects.
- Numbers: one number type, as JS (f64; f32 when built for a
  microcontroller).
- New: lists and objects. `[1, "two", {a: 3}]` is a list, `{ name: "Ada" }`
  with no known struct is an object (names to values). That also covers
  `list<T>` of anything and building objects and arrays in handlers.
- Shared by reference, as in JS, with reference counting (no garbage
  collector); strings counted the same way.
- Reactive:
  - An `any` property is an ordinary property: bindings, `changed`
    handlers and `<=>` work unchanged.
  - Changing an object's field or a list's items marks the object or list
    as changed, so whatever read it is evaluated again.
  - Lists work as models: `for row in rows` and ListView take them.
- Equality: by value for plain values, by reference for lists and objects
  (JS's `===`); change detection uses the same rule.

## Where untyped meets typed

An `any` going into a typed property (`width: foo;`) is checked while the
program runs:

- A matching value goes in: `10px` into a length, a whole number into an
  `int`, any number into a `float`.
- A mismatch is logged once, with the `.zge` file and line, and the
  property keeps its value. A plain `10` into a length is a mismatch, as
  `width: 10;` is a compile error today.
- No hidden conversions (no `"3" + 1`); strings are built by
  interpolation (`"\{n}"`), as today. JS's automatic conversions are the
  part of JS no one misses.

## What the existing features become

| Feature | With an untyped `var` |
|---|---|
| `in` / `out` / `in-out` / private | Unchanged, checked at compile time (they don't depend on the type) |
| `<=>` | untyped ↔ typed takes the typed side's type; untyped ↔ untyped stays dynamic |
| `changed name => {}` | Works as is |
| `animate` | Animates if the value is a number, length or color at that moment; else jumps |
| `Settings` | Saves plain values with their tag; lists and objects as JSON |
| Constant globals | Only typed vars or literals never assigned, as now |
| Exported components in Zig | Untyped `in`/`out` vars become `zigulee.Any` fields, with `get(i32)`-style readers and `Any.from(x)` |
| C API | An opaque handle, with readers and setters per kind |
| LSP | `foo.` completes what is known; hover shows `any`; type errors become warnings where they can be found |
| Microcontrollers | A build option, `zigulee_options.dynamic`, like `transforms`. Off: an untyped `var` is a compile error asking for a type, so the ESP32 size stays as it is |

## Work, in order

1. Syntax only: `var` with modifiers, still requiring a type; `property`
   dropped. Small: parser, formatter, LSP, docs. **Done 2026-11-18.**
2. `any` and the runtime value, with plain values only: types.zig, codegen,
   core; the interpreter mostly maps it onto `Value`.
3. Lists and objects: literals, field access, `push` / `remove` /
   `length`, `for` over them, their reactivity.
4. Types fixed by binding to a typed property (checked at compile time,
   with the two-types error), storing as one type when a private var only
   ever has one, and the LSP hints. Binding can come before phase 2: with
   it, many untyped vars never need the dynamic value.
5. The Zig and C API, `Settings` and `animate` for `any` values.

Phase 1 can ship on its own. Phases 2 and 3 are the large part: mostly
codegen and memory ownership.

## Questions to answer first

1. ~~Meaning~~: decided, dynamic until bound to a typed property (above).
2. ~~Start value~~: decided, `var x;` starts as `null`.
3. ~~Conversions~~: decided, strict as above.
4. ~~`property`~~: decided, dropped; `var` only.
5. Microcontrollers: dynamic values off there, as proposed (any other
   choice would not fit the ESP32).
