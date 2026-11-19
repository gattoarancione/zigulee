# The `.zge` language

A `.zge` file describes user interfaces declaratively: elements in a tree,
their properties, and bindings that keep properties up to date. It is
compiled to Zig at build time (or interpreted by the viewer and the editor
preview). The language started from [Slint](https://slint.dev)'s and takes
from [QML](https://doc.qt.io/qt-6/qmlapplications.html) as well (anchors,
implicit sizes, `Canvas`, `var`), going its own way where neither fits. The
examples here are highlighted as Slint, the closest syntax a Markdown viewer
knows.

- [Components and elements](#components-and-elements)
- [Properties and bindings](#properties-and-bindings)
- [Types and values](#types-and-values)
- [Expressions](#expressions)
- [Callbacks, handlers and functions](#callbacks-handlers-and-functions)
- [Layouts](#layouts)
- [Repetition and conditions](#repetition-and-conditions)
- [States and animations](#states-and-animations)
- [Reacting to changes](#reacting-to-changes)
- [Structs and enums](#structs-and-enums)
- [Globals](#globals)
- [Files and imports](#files-and-imports)
- [Children of components](#children-of-components)
- [Popups](#popups)
- [Keyboard input](#keyboard-input)
- [Translations](#translations)
- [Accessibility](#accessibility)

## Components and elements

A component is a tree of elements. The root element comes after
`inherits`; the others are written inside it:

```slint
export component Greeting inherits Window {
    width: 240px;
    height: 80px;
    Rectangle {
        x: 10px;
        y: 10px;
        width: 220px;
        height: 60px;
        background: #e0e7ff;
        border-radius: 8px;
        Text { text: "Hello"; color: #3730a3; }
    }
}
```

A `Window`'s `width` and `height` are its size when it opens. How the
system shows it is in its properties too: `fullscreen`, `maximized`,
`minimized` and `always-on-top`. Setting one changes the window, and
when the user changes it (the title bar's buttons, a keyboard shortcut)
the property follows, so `maximized <=> root.big` keeps both in step. A
state the system cannot give (always on top on Wayland, or anything on
KMS, fbdev and the web) is not claimed.

```slint
export component Kiosk inherits Window {
    width: 320px;
    height: 200px;
    always-on-top: true;
    TouchArea { clicked => { root.fullscreen = !root.fullscreen; } }
}
```

On phones and tablets the system draws over the edges of the window (the
status bar, a notch, the home indicator, rounded corners) and the
on-screen keyboard over its bottom. `safe-area-top`, `-left`, `-bottom`
and `-right` say how far in from each edge the content is clear, and
`keyboard-height` how much the keyboard covers (all 0 on desktops):

```slint
import { TextEdit } from "std-widgets.zge";

export component Notes inherits Window {
    VerticalLayout {
        padding-top: root.safe-area-top;
        padding-bottom: max(root.safe-area-bottom, root.keyboard-height);
        TextEdit { }
    }
}
```

Elements are [built-in elements](reference/elements.md),
[standard widgets](reference/widgets.md), or other components. A component
can be used as an element once declared:

```slint
component Badge inherits Rectangle {
    var in <string> label;
    height: 24px;
    border-radius: 12px;
    background: #fde68a;
    Text { text: root.label; horizontal-alignment: center; vertical-alignment: center; }
}

export component App inherits Window {
    width: 200px;
    height: 100px;
    Badge { label: "new"; width: 60px; }
}
```

`export` makes a component visible to Zig and to other files. The
component that inherits `Window` is the one an application shows. One
that inherits such a component is a window too, the same one with its
own settings: its `width`, `height` and `title` are the window's, it sets
the other component's properties and handles its callbacks, and adds
properties of its own (the viewer and Zig show it as they would the
other one):

```slint
export component Counter inherits Window {
    width: 200px;
    height: 100px;
    title: "Counter";
    var in-out <int> count;
    Text { text: "\{root.count}"; }
}

export component BigCounter inherits Counter {
    width: 400px;
    title: "Big counter";
    count: 10;
}
```

An element can have an **id**, to refer to it from elsewhere:
`name := Element { ... }`. `root` is the component's root element, `self`
the current element and `parent` its parent:

```slint
export component Ids inherits Window {
    width: 200px;
    height: 100px;
    title-text := Text { text: "Title"; }
    Text { y: title-text.height; text: "below the title, " + self.width / 1px + "px wide"; }
    Rectangle { width: parent.width / 2; height: 4px; y: root.height - 4px; background: gray; }
}
```

Without explicit positions, elements are at 0,0, and elements without a
size fill their parent. Inside a [layout](#layouts), the layout positions
and sizes them.

Anchors, as in QML, tie an element's edges to its parent's or a
sibling's, and keep them there as they move and resize:

```slint
export component Panel inherits Window {
    width: 300px;
    height: 200px;
    sidebar := Rectangle {
        width: 80px;
        anchors.top: parent.top;
        anchors.bottom: parent.bottom;
        anchors.left: parent.left;
        anchors.margins: 8px;
    }
    Rectangle {
        anchors.left: sidebar.right;
        anchors.left-margin: 4px;
        anchors.right: parent.right;
        anchors.top: sidebar.top;
        height: 40px;
    }
    Text { text: "Centered"; anchors.center-in: parent; }
}
```

- **Edges:** `anchors.left`, `right` and `horizontal-center` take
  `parent.left`, `other.right`, `other.horizontal-center`...;
  `anchors.top`, `bottom` and `vertical-center` the vertical ones.
- **Sizes:** with `left` and `right` (or `top` and `bottom`) the
  element is stretched between them. With one side or the center, it keeps
  its `width` (or `height`), or, with none set, takes its natural size (a
  text's or a button's, as QML's implicit size; nothing for an empty
  `Rectangle`) rather than its parent's.
- **Shortcuts:** `anchors.fill: parent` (or a sibling's id) sets all four
  sides, `anchors.center-in: parent` both centers. Edges set as well take
  their place.
- **Gaps:** `anchors.margins` for all sides, or `left-margin`,
  `right-margin`, `top-margin`, `bottom-margin`;
  `horizontal-center-offset` and `vertical-center-offset` move a centered
  element.

Anchors are another way to write `x`, `y`, `width` and `height`, so an
element can't set both the anchors and the property they set. They don't
work in layouts, which place their children themselves.

Text too long for its element is cut at the edge; with
`overflow: elide` it ends with "…" instead (with `wrap: word-wrap`, the
last line that fits does, when more text follows). Or the text can shrink
to fit: with `font-size-mode: FontSizeMode.horizontal-fit` (the width),
`vertical-fit` (the height) or `fit` (both), it is shown at the largest
size up to `font-size` that fits, down to `minimum-font-size` (12px by
default). StyledText fits the same way, its headings, lists and tables
shrinking with it (it wraps to its width, so mostly its height counts).
`letter-spacing` adds pixels after each character (negative brings them
closer) on Text, TextInput and StyledText.

```zge
Text {
    text: root.title;
    font-size: 32px;
    font-size-mode: FontSizeMode.fit;
    minimum-font-size: 10px;
    letter-spacing: 1px;
}
```

On a microcontroller, `pub const zigulee_options = .{ .text_fitting = false };`
in the root file leaves fitting out, and Text's letter spacing.

`StyledText` shows rich text, written in a Markdown subset, wrapped to
its width (with `wrap: no-wrap`, lines break only where the text breaks
them, and are cut at the edge; `horizontal-alignment` and
`vertical-alignment` place it as a Text's, line by line, tables staying
at the left): `**bold**`, `*italic*`, `~~struck~~`, `` `code` ``, links
(`[the docs](https://…)`, which call `link-clicked(url)` when clicked),
images (`![a cat](cat.png)`), `#` headings, `-` bullets and `1.` numbered items (nested by indenting
two spaces), tables (`| a | b |` rows, with a `| --- | --- |` line under
the header row), and paragraphs with blank lines between them. A table's
columns are as wide as their widest cells, narrowed alike when the table
does not fit, their cells wrapping.

```slint
export component About inherits Window {
    width: 300px;
    height: 160px;
    StyledText {
        text: "# zigulee\nA **declarative** GUI for *Zig*; see [the docs](https://example.org).\n\n- fast\n- small";
        link-clicked(url) => { debug(url); }
    }
}
```

With `format: TextFormat.html`, `text` is HTML instead (as Qt's rich
text): paragraphs (`p`, `div`), `br`, `h1` to `h6`, lists (`ul`, `ol`,
`li`), `b`, `strong`, `i`, `em`, `s`, `del`, `u`, `code`, links
(`a href`), images (`img src`, with `width`, `height` and `alt`), tables
(`table`, `tr`, `th`, `td`) and entities; other tags are left out and
their text kept. Colors and fonts come from `font` (`color`, `face`,
`size`), `span`, `mark`, `big`, `small`, and `style` attributes on those
and on blocks: `color`, `background-color`, `font-family` (`monospace`
is `code-font-family`), `font-size` (`px`, `pt`, `em`, `%`, keywords;
pixel sizes shrink with the text when it is fitted), `font-weight`,
`font-style` and `text-decoration`. Paragraphs, headings, list items
and table cells take `align` or `text-align` (`left`, `center`, `right`,
`justify`) over the element's `horizontal-alignment`, and a `div` or
`center` passes its alignment and look to the blocks inside it. A
Markdown table's columns are aligned by the line under its header
(`:---`, `:---:`, `---:`).

`style-sheet` is CSS for the text, as Qt's default stylesheet: rules for
tags (`p`, `h1`, `td`...), classes (`.note`, `td.num`) and ids (`#top`),
comma lists of them, with the declarations above; the more specific
rule wins, then the later one, then an element's own `style`. HTML's
`style` elements add their rules. Markdown is styled as the HTML it
stands for: `p`, `h1` to `h6`, `li`, `td`, `th`, and inside them
`strong`, `em`, `del`, `code` and `a`. Selectors with descendants or
pseudo-classes are left out.

```slint
StyledText {
    style-sheet: "h2 { color: #059669 } strong { color: #dc2626 }";
    text: "## Notes
Some **bold** words.";
}
```

Images are loaded as an Image's `source-url` is (a path, `file://`,
`http://`, `https://`), in the background. Relative URLs are resolved
from `base-url` as a browser resolves a page's (`base-url: "assets/"`
finds `pic.png` in `assets`; a base without its last `/` is a file whose
directory counts), or from the working directory without one. Images
are shared with other elements showing them. They wrap as words, are
never wider than a line, and keep their proportions when only `width`
or `height` is given. Floated (`<img align=left>`, `float: right`), an
image sits at that side of the text and the lines beside it go round
it; tables start below it. Until
they come they take the size they ask for (or none), and if they cannot
be loaded their `alt` text shows instead. With `selectable: true`,
dragging over the text selects it (`selected-text`; a double click
selects a word, a triple click a paragraph, and dragging on goes by
words or paragraphs), Ctrl+C (Cmd+C on macOS) or `copy()` copies
it, and Ctrl+A or `select-all()` selects all of it; links are still
clicked.

```slint
export component Receipt inherits Window {
    width: 240px;
    height: 120px;
    StyledText {
        format: TextFormat.html;
        selectable: true;
        text: "<table><tr><th>Item</th><th>Price</th></tr><tr><td>Tea</td><td><span style='color: green'>2 &euro;</span></td></tr></table>";
    }
}
```

Right-to-left text (Hebrew, Arabic) shows in visual order, following the
Unicode bidirectional algorithm: mixed with left-to-right words and
numbers, each run reads in its own direction, and brackets are mirrored.
A paragraph's direction comes from its first strong letter; the caret and
selection follow the visual order. Text is shaped with the font's
OpenType tables: Arabic letters join, ligatures form (لا), and accents
and vowel marks sit on their letters. Fonts without these tables use the
Unicode presentation forms they have.

A `TouchArea` sets the pointer's shape over it with `mouse-cursor`
(`pointer`, `text`, `move`, `ew-resize`... the CSS cursor names); text
fields show an I-beam by themselves.

Besides `clicked`, a `TouchArea` has `double-clicked`: a second click
within `double-click-interval` (400 ms by default), close to the first,
calls it instead of `clicked`, as Qt's MouseArea does. `pointer-event(e)`
tells each press and release of any button and each move, with
`e.kind` (`PointerEventKind.down`, `up`, `move`, or `cancel` when another
element, a Flickable say, takes the drag), `e.button`
(`PointerEventButton.left`, `right`, `middle`) and `e.modifiers`:

```slint
export component Lamp inherits Window {
    width: 120px;
    height: 80px;
    var in-out <bool> on;
    var in-out <bool> held;
    TouchArea {
        double-clicked => { root.on = !root.on; }
        pointer-event(e) => {
            if e.kind == PointerEventKind.down && e.button == PointerEventButton.left { root.held = true; }
            if e.kind == PointerEventKind.up || e.kind == PointerEventKind.cancel { root.held = false; }
        }
    }
}
```

Comments are `// ...` and `/* ... */`. Names may contain dashes
(`border-radius`); in Zig they become underscores (`border_radius`).

## Properties and bindings

Elements have properties: `x`, `y`, `width`, `height`, `visible`,
`enabled` and `opacity` everywhere, and others depending on the element.
Components declare their own:

```slint
component Counter inherits Rectangle {
    var in <string> label;            // set by the user of the component
    var out <bool> big: count > 10;   // read by the user of the component
    var in-out <int> count: 0;        // both
    var <color> tint: #6366f1;        // private
    background: big ? tint : #a5b4fc;
}
```

`in`, `out`, `in-out` and private (no keyword) say who may set the
property: the user of the component, the component itself, or both.
Properties of an exported component are fields of its Zig struct.

A declaration is `var`, then who may set it (none: private), then its
type in angle brackets, its name, and a value or a `<=>` link if it has
one. For now a `var` needs its type.

Files written for older versions declare properties with `property`
(`in-out property <int> count: 0;`): the compiler now asks for `var`
there, and says what to write.

Every element can also be turned and stretched: `rotation` (degrees,
clockwise), `scale` (or `scale-x` and `scale-y`), around
`transform-origin-x` and `transform-origin-y` (by default its center).
The element and its children are drawn, and take clicks, where they show;
the layout keeps their place as it was. They can be animated:

```slint
Rectangle {
    rotation: open ? 90 : 0;
    scale: hovered ? 1.1 : 1;
    animate rotation, scale { duration: 150ms; }
}
```

An element can also be tilted in depth: `rotation-x` turns it about its
horizontal axis (positive: its top goes away) and `rotation-y` about its
vertical axis (positive: its right side goes away), both in degrees,
around its transform origin. The result is seen in perspective:
- **Perspective:** from its parent's `perspective`, the viewer's distance
  from the parent's plane, looking at the parent's center, as with CSS's
  `perspective` (1000px when the parent sets none). Smaller distances look
  deeper.
- **Children:** the element and its children are drawn flat into an image
  first, as with `blur`, then shown tilted. Animating a tilt only maps that
  image again, so a card flip is cheap.
- **Clicks:** they reach the element where it shows.
- **Back faces:** past 90 degrees you see the back of the element,
  mirrored. Hide the front and show a back turned 180 degrees itself to
  give a card two faces.

```slint
HorizontalLayout {
    perspective: 800px;
    card := Rectangle {
        rotation-y: flipped ? 180 : 0;
        animate rotation-y { duration: 500ms; easing: ease-in-out; }
    }
}
```

`examples/cards.zge` turns cards over and tilts a panel with sliders
(`zigulee-viewer examples/cards.zge`). The layout, accessibility bounds and
native views (`WebView`) ignore tilts, as they ignore `rotation`.

A `Rectangle` (and a component built on one, such as a `Button`) casts a
shadow with `drop-shadow-color`, moved by `drop-shadow-offset-x` and
`drop-shadow-offset-y`, and softened by `drop-shadow-blur` (as CSS's blur
radius; `0px` gives a hard edge). The shadow has the rectangle's rounded
corners, turns with it, and is drawn under it:

```slint
Rectangle {
    border-radius: 12px;
    background: white;
    drop-shadow-offset-y: 6px;
    drop-shadow-blur: 18px;
    drop-shadow-color: #0f172a50;
}
```

Any element can be blurred with `blur` (the standard deviation, as CSS's
`filter: blur()`): it and its children are drawn as one image, blurred,
which spreads about three times `blur` past them. And an element with
children that is faded (`opacity` below 1) fades with them as one: where
they overlap, only the top one shows, as it would unfaded. Both draw the
element into an image of its own first (in memory: a large blurred area
costs more to draw than the same area unblurred), which is kept while it
looks the same, so animating `opacity` or moving it is cheap:

```slint
Rectangle {
    background: #0ea5e9;
    blur: dimmed ? 6px : 0px;
    opacity: dimmed ? 0.6 : 1;
    animate blur, opacity { duration: 200ms; }
    Text { text: "Behind the dialog"; }
}
```

A `Rectangle` with `clip: true` clips its children to itself, its
corners rounded by its `border-radius`, turned with it when it is
rotated. Any element can instead be cut to a shape with
`clip-path`: SVG path data in its own coordinates (as a `Path`'s
`commands`, 0 to its width and height). It and its children show only
inside, smoothed along the edge. Built in a binding, the shape can follow
a value: a gauge showing a picture cut to a pie slice.

```slint
export component Gauge inherits Window {
    width: 100px;
    height: 100px;
    var in <float> level: 0.3; // of a turn, from 12 o'clock
    Rectangle {
        width: 100px;
        height: 100px;
        background: #f59e0b;
        clip-path: "M 50 50 L 50 0 A 50 50 0 " + (root.level > 0.5 ? "1" : "0") + " 1 "
            + (50 + 50 * sin(root.level * 360)) + " " + (50 - 50 * cos(root.level * 360)) + " Z";
    }
}
```

Or it can show through an image with `mask-image` (as QML's
`OpacityMask`): the image, stretched over the element, says how much of it
and its children shows, by its opacity: a picture faded out at its edges,
or cut to a logo's shape (an SVG drawing: where its shapes are).

```slint
Image {
    source: @image-url("photo.png");
    mask-image: @image-url("vignette.png");
}
```

The mask can also be another element, by its id, with `mask-source` (as
QML's `maskSource`): what it draws, at its opacity, is the mask. It is
drawn as if it were a child of the element it masks, placed by its `x`
and `y`, and even when it is not `visible` (it usually is not: it would
show too). `mask-inverted: true` shows the element where its mask does
not: a hole where the shape is.

```slint
export component Avatar inherits Window {
    width: 64px;
    height: 64px;
    Rectangle {
        background: @linear-gradient(90deg, #16a34a 0%, #fde047 100%);
        mask-source: disc;
        disc := Rectangle {
            visible: false;
            border-radius: 32px;
            background: black;
        }
    }
}
```

Clicks and touches follow the shapes: outside a `clip-path`, past a
rounded clip's corners, or where a mask image is less than half opaque
(more, inverted), they reach what is underneath. An element's mask does
not change where they land.

Those draw into an image as blur does: a turned clip, a `clip-path` or a
`mask-image` the whole element; a rounded clip only what reaches into its
corners (the rest is clipped as usual).

`prefer-rendering-cache: true` draws an element and its children into an
image that is kept while what they draw stays the same, and shown turned
as the element is. While it turns, or when something over it changes, it
is not drawn again: only its image is shown, turned. A turned element of
many pictures is then as fast to show as one picture. Its edges and text,
turned as an image, are a little softer, and the image takes memory (four
bytes a pixel): set it where it pays.

```slint
Rectangle {
    rotation: gear-angle;
    animate rotation { duration: 800ms; }
    prefer-rendering-cache: true;
    Image { source: @image-url("gears.png"); }
    Image { source: @image-url("lines.png"); }
}
```

On a microcontroller, `pub const zigulee_options = .{ .effects = false };`
in the root file leaves these out: `blur`, `clip-path`, `mask-image` and
`mask-source` and `prefer-rendering-cache` are then ignored, `clip` clips square (to its bounding box when rotated),
and `opacity` fades each thing the element and its children draw. Tilts need the same images:
without effects, tilted elements are drawn flat.

A **binding** gives a property an expression. It is reevaluated whenever a
property it reads changes, so `big` above always matches `count`.
Assigning a value in a handler (`count = 5;`) replaces the binding with
that value.

A **two-way link** (`<=>`) makes two properties share one value: setting
either sets both.

```slint
export component Mirror inherits Window {
    width: 200px;
    height: 80px;
    var in-out <string> name <=> input.text;
    input := TextInput { }
}
```

### Enabled

`enabled: false` turns an element off with everything inside it, as in
QML: they take no clicks, touches or keys (what is under them gets the
clicks), cannot take focus, and are read out as disabled. Reading an
element's `enabled` gives whether it is on there: false inside a disabled
layout, pane or group box even if it never set its own. Setting it sets
its own, so `enabled: true` cannot turn back on what a parent turned off.
The standard widgets grey themselves while disabled.

```slint
HorizontalLayout {
    enabled: root.signed-in;
    Button { text: "Send"; }      // off while not signed in
    Button { text: "Delete"; enabled: root.selected >= 0; }
}
```

A component that declares its own `enabled` hides the element's: setting
it does not turn off what is inside. Leave it out and read `root.enabled`.

## Types and values

| Type | Values | In Zig |
|---|---|---|
| `int` | `42`, `-1` | `i32` |
| `float` | `0.5`, `2`, `45deg` | `f32` |
| `bool` | `true`, `false` | `bool` |
| `string` | `"text"`, `"count: \{n}"` | `[]const u8` |
| `length` | `10px`, `50%` (of the parent; width and height only) | `f32` (logical pixels) |
| `duration` | `250ms`, `1.5s` | `i64` (milliseconds) |
| `color` | `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `red` | `zigulee.Color` |
| `brush` | a color, `@linear-gradient(...)`, `@radial-gradient(...)` | `zigulee.Brush` |
| `image` | `@image-url("icon.png")` | `zigulee.core.Image` |
| `audio` | `@audio-url("jump.wav")` | `zigulee.core.Audio` |
| `video` | `@video-url("intro.png")` | `zigulee.core.Video` |
| `[T]` | `[1, 2, 3]`: a model of rows of `T` | `zigulee.Model(T)` |
| `[[T]]` | a model of models (table rows) | `zigulee.Model(zigulee.Model(T))` |
| structs, enums | [declared in `.zge`](#structs-and-enums) | Zig structs and enums |

Strings take escapes (`\n`, `\t`, `\\`, `\"`, `\u{1F600}`) and
interpolations: `"\{expr}"` inserts the value of any expression.

Gradients fill whatever takes a brush (`background`, `color`,
`border-color`, ...), as CSS writes them:

```
Rectangle { background: @linear-gradient(90deg, #3b82f6, #a855f7 70%, white); }
Rectangle { background: @radial-gradient(circle, yellow, transparent); }
```

A linear gradient goes the way its angle points (0 up, 90 right; 180, down,
if no angle is given); a radial one from the center out to the farthest
corner. Each stop is a color, optionally followed by its position: a
percentage or a fraction (`0.7`). Stops without one are spread evenly
between those around them, the first at 0% and the last at 100%. Colors,
positions and the angle can be any expression (`count * 45deg`,
`root.accent`), and `animate background` blends gradients with the same
number of stops (up to 8).

Lengths need a unit: `width: 10;` is an error (`add a unit, like 10px`).
Dividing a length by `1px` gives a number, and a duration by a duration
gives their ratio. Ints convert to floats where
needed.

Images given with `@image-url` are PNG, GIF or SVG files, relative to the
`.zge` file and embedded in the program at build time (an animated one
shows its first frame, and an `AnimatedImage` plays it). An SVG image
is kept as shapes, drawn sharp at any size: an `Image` shows it at its
`width` and `height` (its natural size), fitted by `image-fit`, and
`colorize` paints it in one color (an icon in the text's color, say). Its
paths, rectangles, circles, ellipses, lines and polygons are read, in
groups, with their transforms, fills, strokes and opacity, and linear and
radial gradients (a radial one from its center: focal points are not
read). `use` places a copy of an element (or a `symbol`) at its `x` and
`y`; `clip-path`, `mask` (by its shapes' brightness) and `filter` (a
Gaussian blur, its other effects left out) apply to each shape on its own;
`text` shows its words on one line at its `x` and `y`, in the `Image`'s
font, at its `font-size`, bold with `font-weight`, placed by
`text-anchor` (a `tspan`'s own styles and positions are not read).
Patterns, markers and stylesheets are left out.

`image-fit` is `contain` by default; `fill` stretches the image over the
item, `cover` fills it keeping the image's shape (cutting the rest), and
`preserve` shows it at its natural size, centered. `tile` repeats it at its
natural size from the item's top left corner, a pattern or a texture;
`tile-horizontally` repeats it side by side, stretched to the item's
height, and `tile-vertically` one below the other, stretched to its width:

```
Rectangle {
    background: #1e293b;
    Image { source: @image-url("dots.png"); image-fit: tile; opacity: 0.3; }
}
```

An `Image` can also load its picture while the program runs:
`source-url` is a file's path (relative to the working directory, or a
`file://` URL) or an `http://` or `https://` URL. It is fetched and
decoded in the background, the UI going on meanwhile; `status` is
`ImageStatus.loading` until it is `ready` (and shown) or `error`, and
`progress` goes from 0 to 1 as it comes (it stays 0 while the server does
not say how big it is). `source-headers` are sent with it, each
`Name: value` (a token, say). Images showing the same URL (with the same
headers) share one load and one picture, and it is kept a while after they
all go (up to 32 MB of pictures no one shows), so a list's row scrolled
back shows its picture at once.

```slint
export component Picture inherits Window {
    width: 200px;
    height: 200px;
    var in <string> url: "https://example.org/cat.png";
    photo := Image { source-url: root.url; source-headers: ["Authorization: Bearer 123"]; }
    Text {
        visible: photo.status != ImageStatus.ready;
        text: photo.status == ImageStatus.error ? "No picture" : "Loading… \{round(photo.progress * 100)}%";
    }
}
```

With
`nine-slice(...)`, an image keeps its borders when stretched and only its
middle scales, for frames and bubbles drawn as pictures:
`@image-url("bubble.png", nine-slice(12))` keeps 12 pixels on every side;
`nine-slice(8 16)` 8 at the top and bottom, 16 at the sides;
`nine-slice(4 8 12 16)` top, right, bottom, left (as CSS's
`border-image-slice`). Sounds given with `@audio-url`
are WAV files (8, 16, 24 or 32-bit PCM, or 32-bit float; mono or stereo),
embedded the same way. Videos given with `@video-url` are embedded as they
are and decoded while playing; for large files, a `Video`'s `source-file`
reads one from disk instead.

## Expressions

- Arithmetic `+ - * /`, comparison `== != < <= > >=`, logic `&& || !`,
  and the conditional `cond ? a : b`. `+` also joins strings.
- Functions: `min`, `max`, `abs`, `round`, `floor`, `ceil`, `sqrt`,
  `sin` and `cos` (of degrees), `mod(a, b)`, `debug(...)`, which prints its arguments, and
  `json-get`, `json-number` and `json-count` (see
  [Network requests](#network-requests)), and `open-url` (see
  [Opening links](#opening-links)).
- Models: `model[i]` is a row, `model.length` the number of rows.
- Struct fields: `contact.name`; struct values: `{ name: "Ada", age: 36 }`.
- Enum values: `TextWrap.word-wrap`, or just `word-wrap` where the type is
  known.

## Callbacks, handlers and functions

A **callback** is an event a component reports. Its **handler** says what
to do, as statements:

```slint
component Stepper inherits Rectangle {
    var in-out <int> value;
    callback changed(int);
    callback format(int) -> string;
    format(v) => { return "\{v}"; }
    height: 32px;
    TouchArea {
        clicked => {
            value += 1;
            root.changed(value);
        }
    }
    Text { text: root.format(value); }
}
```

Statements are assignments (`=`, `+=`, `-=`, `*=`, `/=`), calls,
`if cond { ... } else { ... }`, `return`, local variables and loops.
Handlers can also be set from Zig (or by the user of the component, like
`clicked => { ... }` on a Button).

`let name = value;` declares a variable, of the value's type (or of one
given: `let x: float = 1;`), until the end of its block; it can be
assigned like a property. `while cond { ... }` repeats while `cond` holds;
`for item in model { ... }` goes over a model's rows (`for item[i] in model`
with their index), and `for i in n { ... }` counts from 0 to n - 1.
`break` leaves the loop, `continue` goes on with its next turn:

```slint
function summary(people: [Person]) -> string {
    let text = "";
    for p in people {
        if p.age < 18 { continue; }
        if text != "" { text += ", "; }
        text += p.name;
    }
    return text;
}
```

Handlers run on the UI thread: a loop that does not end stops the
interface.

A handler can also be added to another element's callback, without
replacing the one it has: `list.selected(i) => { ... }` on any element
(the target is an element's id, `root`, `parent` or a global), or several
in a `Connections` element, which runs them while `enabled`. The
callback's own handler runs first and gives its result; added ones run
after it, in order:

```slint
export global Bus {
    callback saved(string);
}

component Editor inherits Rectangle {
    callback changed(string);
    var in-out <bool> logging: true;
    var out <string> last;
    var out <int> saves;
    input := TextInput {
        edited => { root.changed(self.text); }
    }
    input.edited => { last = input.text; }
    Connections {
        target: Bus;
        enabled: root.logging;
        saved(name) => { saves += 1; }
    }
}
```

**Functions** compute values or run statements; `public` ones can be called
by the user of the component (and from Zig):

```slint
component Clock inherits Text {
    var in <int> minutes;
    text: two(minutes / 60) + ":" + two(mod(minutes, 60));
    function two(n: int) -> string {
        return n < 10 ? "0\{n}" : "\{n}";
    }
    public function reset() { minutes = 0; }
}
```

## Layouts

Layouts position and size their children:

- `HorizontalLayout` and `VerticalLayout` place them in a row or a column.
  `spacing` goes between children, `padding` (or `padding-left`, ...)
  around them, and `alignment` (`stretch`, `start`, `center`, `end`,
  `space-between`, `space-around`) says where extra space goes.
- `GridLayout` places them in cells: in `Row { ... }` elements, or by their
  `row` and `col` properties, spanning `rowspan` and `colspan` cells.

Children take constraints: `min-width`, `max-width`, `preferred-width` (and
the same for heights) and `horizontal-stretch`/`vertical-stretch`, how
extra space is shared. Text, images and widgets have sensible constraints of
their own, from their content. A fixed `width` or `height` inside a layout
fixes that size.

```slint
export component Form inherits Window {
    width: 300px;
    height: 120px;
    VerticalLayout {
        padding: 12px;
        spacing: 8px;
        HorizontalLayout {
            spacing: 8px;
            Text { text: "Name"; vertical-alignment: center; }
            Rectangle { background: #eee; horizontal-stretch: 1; }
        }
        GridLayout {
            spacing: 4px;
            Row {
                Rectangle { background: red; }
                Rectangle { background: green; }
            }
            Row {
                Rectangle { colspan: 2; background: blue; }
            }
        }
    }
}
```

`Flickable` scrolls content larger than itself (the `ScrollView` and
`ListView` widgets add scroll bars).

## Repetition and conditions

`for` repeats an element for each row of a model; `if` shows an element
while a condition holds:

```slint
export component Lists inherits Window {
    width: 200px;
    height: 200px;
    var in <[string]> names: ["Ada", "Grace", "Linus"];
    var in-out <bool> show-total;
    VerticalLayout {
        for name[i] in names : Text { text: "\{i + 1}. \{name}"; }
        for n in 3 : Rectangle { height: 4px; background: n == 0 ? red : gray; }
        if show-total : Text { text: "\{names.length} names"; }
    }
}
```

The model is a model property, an array (`[a, b]`), or an int (`for n in
3`: 0, 1, 2). The index (`[i]`) is optional. Repeated elements follow the
model: when rows are added, removed or changed (from Zig, with a
`VecModel`), only those rows' elements are created, destroyed or updated.
Inside layouts, repeated and conditional elements are laid out like the
layout's own children.

A model can be filtered, sorted and reversed where it is used, with a
function of a row (`row => ...`):

```slint
struct Person { name: string, age: int }

export component People inherits Window {
    width: 200px;
    height: 200px;
    var in <[Person]> people: [{ name: "Grace", age: 85 }, { name: "Ada", age: 36 }];
    var in-out <int> min-age: 18;
    VerticalLayout {
        for p in people.filter(p => p.age >= min-age).sort(p => p.name) : Text {
            text: "\{p.name} (\{p.age})";
        }
    }
}
```

`filter` keeps the rows its function says `true` for; `sort` orders them
by its function's value (a number, a bool, or a string, by its bytes),
keeping the order of equal ones; `reverse()` turns them around; `map`
makes a model of its function's values (`people.map(p => p.name)`, a
`[string]`). They
chain, and give a model like any other: it follows its source, and what
the function reads (`min-age` above), and tells repeaters which rows
changed.

## States and animations

`states` sets properties while a condition holds; `animate` makes changes
of a property gradual:

```slint
export component Toggle inherits Window {
    width: 120px;
    height: 60px;
    var in-out <bool> on;
    knob := Rectangle {
        width: 40px;
        height: 40px;
        y: 10px;
        x: 10px;
        border-radius: 20px;
        background: gray;
        animate x, background { duration: 200ms; easing: ease-out; }
    }
    states [
        active when on : {
            knob.x: 70px;
            knob.background: #22c55e;
        }
    ]
    TouchArea { clicked => { on = !on; } }
}
```

Animation settings: `duration`, `delay`, `easing` (`linear`, `ease`,
`ease-in`, `ease-out`, `ease-in-out`, `ease-in-quad`, `ease-out-quad`,
`ease-in-out-quad`, `ease-in-cubic`, `ease-out-cubic`, `ease-in-out-cubic`,
`ease-out-back`, `ease-out-elastic`, `ease-out-bounce` or
`cubic-bezier(a, b, c, d)`) and `iteration-count` (-1: forever).

A state can animate differently when it starts and ends:
`in { animate background { duration: 100ms; } }` and
`out { animate background { duration: 400ms; } }`.

A `Timer` element runs code repeatedly:
`Timer { interval: 1s; running: true; triggered => { ticks += 1; } }`.
`start()` and `stop()` set and clear `running`; `restart()` runs it from
now, the next `triggered` a whole interval away.

An `Audio` element plays a sound:
`jump := Audio { source: @audio-url("jump.wav"); voices: 3; }`, then
`jump.play();` in a handler. Set `playing` (or call `stop()`) to start and
stop it, `loop`, `volume`, `pan` and `speed` to change how it plays, and
`position` to seek; `finished` is called when it ends by itself. Sounds
rise over `fade-in` and fall over `fade-out` when stopped, and a new
`source` crossfades. They play through a mixer shared by the whole
program; where the platform has no audio output they stay silent. Sound
plays through the SDL3 backend and the native ones: CoreAudio on macOS,
WASAPI on Windows, PipeWire on Linux (not yet on the web or on
microcontrollers).

A `Video` element plays a video and shows it like an `Image`:
`Video { source: @video-url("intro.png"); playing: true; loop: true; }`. It
shows the first frame until it plays; `position` follows playback (setting
it seeks), `finished` is called at the end, and the soundtrack plays
through the mixer at `volume`. Animated PNG plays everywhere; other formats
(MP4, ...) where the platform decodes them: AVFoundation on macOS, Media
Foundation on Windows, GStreamer (and its plugins) on Linux.
`std-widgets.zge` has a `VideoPlayer`: a `Video` with controls (play and
pause, the time, a seek bar).

An `AnimatedImage` plays an animated GIF or PNG:
`AnimatedImage { source: @image-url("spinner.gif"); }`. It plays when
shown, as many times as the file says (usually forever), at `speed`;
`playing: false` holds the frame shown, `current-frame` follows it (and
setting it shows that frame), and `finished` is called after the last
play. Frames are decoded as they show, on the UI thread: no thread of its
own, and memory for the picture only.

`MenuBar` (with `MenuBarItem`s) is a row of menus in the window; on macOS
its menus go to the menu bar at the top of the screen instead, after the
application menu, with their shortcuts ("Ctrl+O" becomes ⌘O). `Menu`
opens a popup menu (a context menu: `open-at(x, y)` from a TouchArea's
`right-clicked`), `ToolTip` a hint, `Dialog` and `MessageDialog` modal
dialogs.

A menu's items are a list of `MenuItem`s; those right after one, a
`level` deeper, are its submenu, which opens beside it (when hovered or
clicked, or with the Right arrow). `activated` gives the index in the
whole list. On macOS the menu bar's menus nest the same way:

```slint
import { Menu } from "std-widgets.zge";

export component Editor inherits Window {
    width: 300px;
    height: 200px;
    menu := Menu {
        items: [
            { text: "Open…", shortcut: "Ctrl+O" },
            { text: "Export" },
            { text: "PNG", level: 1 },
            { text: "Vector", level: 1 },
            { text: "SVG", level: 2 },
            { text: "PDF", level: 2 },
            { separator: true },
            { text: "Quit", shortcut: "Ctrl+Q" },
        ];
        activated(i) => { /* 0: Open, 2: PNG, 4: SVG, ... */ }
    }
    TouchArea { right-clicked => { menu.open-at(self.mouse-x, self.mouse-y); } }
}
```

A `FileDialog` shows the platform's own file dialog:

```slint
component Opener inherits Window {
    images := FileDialog {
        title: "Open images";
        mode: open-files;   // or open-file, open-folder, save-file
        filter: "Images (*.png *.jpg);;All files (*)";
        accepted => { /* images.selected-file, images.selected-files */ }
    }
    TouchArea { clicked => { images.open(); } }
}
```

It answers with `accepted` (the files in `selected-file` and
`selected-files`) or `rejected`. The dialogs are macOS's panels, the
Windows shell's dialogs, and on Linux the desktop's (through the XDG
desktop portal), or SDL's with the SDL3 backend; where there are none (the
web, microcontrollers), the answer is `rejected`.

A component that inherits `Settings` keeps its properties from one run to
the next, and `StandardPaths` tells where the user's folders are:

```slint
component EditorSettings inherits Settings {
    category: "editor";
    var in-out <bool> wrap: true;
    var in-out <length> font-size: 14px;
    var in-out <string> last-folder;
}

component Editor inherits Window {
    var in-out <bool> wrap;
    paths := StandardPaths {}
    prefs := EditorSettings { wrap <=> root.wrap; }
    open := FileDialog {
        folder: prefs.last-folder != "" ? prefs.last-folder : paths.documents;
        accepted => { prefs.last-folder = open.selected-file; }
    }
}
```

The properties it declares (int, float, bool, string, length, duration,
color) are saved under `category` in `settings.ini`, in the application's
configuration folder (`app-config`: `~/Library/Application Support/<app>`
on macOS, `%APPDATA%\<app>` on Windows, `~/.config/<app>` on Linux), or in
the file given as `file`. The application is named by
`zigulee.setApplicationName` (else after its executable; the viewer names it
after the `.zge` file). Saved values replace the defaults once the
component and its users are set up, so properties linked with `<=>` take
them too; changes are written a moment later, and when it goes. Where
there are no files (the web, microcontrollers), they last as long as the
application.

`std-widgets.zge` has two kinds of `Audio` ready to use: `Sound` for effects
(4 voices, so a sound can play over itself) and `Music` (looping, fading
in over 500 ms and out over 1 s):

```slint
import { Sound, Music } from "std-widgets.zge";

component Game inherits Window {
    var in-out <bool> music-on: true;
    jump := Sound { source: @audio-url("jump.wav"); }
    Music { source: @audio-url("theme.wav"); playing: music-on; }
    TouchArea { clicked => { jump.play(); } }
}
```

### Animations started from code

`animate` follows a property's changes. To play a choreography instead,
started and stopped from code, use animation elements (not drawn):

- `PropertyAnimation` animates its `target` (a property: `box.x`) from
  `from` (else its value when it starts) to `to`, over `duration` with
  `easing`.
- `PauseAnimation` waits its `duration`.
- `SequentialAnimation` runs the animations in it one after the other;
  `ParallelAnimation` runs them together.

Each runs `loops` times (-1: forever). Start one with `start()` or
`running: true`; `stop()` leaves values where they are, `pause()` and
`resume()` hold and continue it, and `finished` is called at its end. In a
group, the group runs them.

```slint
export component Intro inherits Window {
    box := Rectangle { width: 40px; height: 40px; background: #e11d48; }
    intro := SequentialAnimation {
        PropertyAnimation { target: box.x; to: 200px; duration: 400ms; easing: spring(0.4); }
        PauseAnimation { duration: 100ms; }
        ParallelAnimation {
            PropertyAnimation { target: box.y; to: 80px; duration: 300ms; }
            PropertyAnimation { target: box.opacity; to: 0.5; duration: 300ms; }
        }
        finished => { box.background = #16a34a; }
    }
    TouchArea { clicked => { intro.start(); } }
}
```

`spring(bounce)` is an easing (for `animate` too) that settles like a
spring over the duration: `spring(0)` comes to rest without overshooting,
values up to 1 bounce more and more. A number moving with a spring keeps
its speed when its target changes on the way (as Qt's `SpringAnimation`):
a thumb following the pointer swings on, and turned back, it slows down
before it comes back, rather than starting over from rest (except in
builds for size, `ReleaseSmall`, as on microcontrollers).

## Reacting to changes

`changed name => { ... }` runs statements after a property changes
(batched: once per frame, however often it changed):

```slint
export component Watch inherits Window {
    width: 100px;
    height: 100px;
    var in-out <int> value;
    var out <int> changes;
    changed value => { changes += 1; }
}
```

## Structs and enums

```slint
struct Contact {
    name: string,
    age: int,
}

enum Mode { light, dark }

export component People inherits Window {
    width: 200px;
    height: 100px;
    var in-out <Mode> mode: Mode.light;
    var in <[Contact]> contacts: [{ name: "Ada", age: 36 }];
    VerticalLayout {
        for c in contacts : Text {
            text: "\{c.name} (\{c.age})";
            color: mode == dark ? white : black;
        }
    }
}
```

In Zig, they are types of the generated module (`ui.Contact`, `ui.Mode`).

## Globals

A `global` is a singleton: its properties, callbacks and functions are
shared by every component (in Zig: `ui.Name.instance`):

```slint
export global Theme {
    var in-out <bool> dark;
    var out <color> text: dark ? #f1f5f9 : #0f172a;
}

export component Themed inherits Window {
    width: 100px;
    height: 100px;
    background: Theme.dark ? #0f172a : #ffffff;
    Text { text: "Hello"; color: Theme.text; }
}
```

An `out` property of a global with a literal value (`32px`, `#fff`,
`true`) that the global never changes and nothing links to is a constant:
the code using it gets the value itself, with no binding to keep up to
date.

The standard widgets' colors and sizes are the globals `Palette` and
`Style`; `Palette.dark` switches them to dark mode. `Style`'s sizes are
constants: change them in the style's `style.zge`.

## Files and imports

```slint
import { Theme, Card } from "theme.zge";      // relative to this file
import { Button, Palette } from "std-widgets.zge";
export { Card } from "theme.zge";             // re-export
```

## Children of components

Children given to a component go where it marks `@children`:

```slint
component Card inherits Rectangle {
    var in <string> heading;
    border-width: 1px;
    border-color: #ccc;
    VerticalLayout {
        padding: 8px;
        Text { text: root.heading; font-weight: 700; }
        @children
    }
}

export component Cards inherits Window {
    width: 200px;
    height: 120px;
    Card {
        heading: "Today";
        Text { text: "Nothing planned"; }
    }
}
```

## Components as values

A component's name is also a value, of type `component`: a property can
hold one (`var in <component> delegate;`), and a `Loader` shows the
one its `source` names, created when it is chosen (and destroyed when
another one is, or when `active` is false). Its root fills the loader.

The loader's other bindings go to the instance's `in` (or `in-out`)
properties of the same name and type, now and whenever they change. Which
component it shows is only known while running, so a component without
such a property is not an error: the value is not passed, and a warning is
logged.

```slint
component Card inherits Rectangle {
    var in <string> label;
    var in <int> index;
    background: index == 0 ? #e0e7ff : #f1f5f9;
    Text { text: "\{index + 1}. \{label}"; }
}

component SmallRow inherits Text {
    var in <string> label;
    text: label;
}

component Rows inherits Rectangle {
    var in <component> delegate;
    var in <[string]> items;
    VerticalLayout {
        for item[i] in items : Loader {
            source: root.delegate;
            label: item;
            index: i;
            height: 24px;
        }
    }
}

export component App inherits Window {
    var in-out <bool> compact;
    Rows {
        delegate: compact ? SmallRow : Card;
        items: ["one", "two"];
    }
}
```

`loaded` says whether an instance is shown. Components are compared with
`==` (`kind == Card`).

## Pages

A `StackLayout` shows one of its children (`current-index`); a `SwipeView`
lays them side by side and moves between them with a horizontal drag (or
`current-index`, sliding), with a `PageIndicator` from std-widgets.zge to
show where it is; with `orientation: Orientation.vertical`, one above the
other, moved by dragging up and down. A `StackView` keeps pages of components on top of each
other: `push(Page)` slides one in, `pop()` slides it out.

```slint
import { Button, PageIndicator } from "std-widgets.zge";

component Details inherits Rectangle {
    background: #e0e7ff;
    Text { text: "Details"; }
}

component Home inherits Rectangle {
    Text { text: "Home"; }
}

export component App inherits Window {
    width: 300px;
    height: 300px;
    var in-out <int> page;
    VerticalLayout {
        swipe := SwipeView {
            current-index <=> root.page;
            Rectangle { background: #fef3c7; }
            Rectangle { background: #dcfce7; }
        }
        PageIndicator { count: swipe.count; current-index <=> root.page; }
        nav := StackView { initial-page: Home; }
        Button { text: "Details"; clicked => { nav.push(Details); } }
    }
}
```

A `FlowLayout` places its children at their preferred sizes, left to
right, wrapping into rows; in std-widgets.zge, a `GridView` is one in a
scroll view (a grid of cells), and a `ScrollBar` can stand on its own
(`position` and `size`, fractions of the whole).

A `ListView` (std-widgets.zge) lays out the rows of its `for` one under
another, all as tall as the first (or `row-height`), and keeps instances
only for the rows in view: scrolling hands the instances of the rows that
left to those that came in, so a list of a hundred thousand rows has a
dozen. An instance's own state (a text typed into it, a hover) goes with
it to its next row; what comes from the row's data is updated. With
`variable-row-height: true`, each row is as tall as it prefers (messages
wrapping over a line or several): rows are measured once they have been
in view, and those not yet seen are counted at the mean height, so the
scroll bar settles as the list is scrolled through. `sections`
names each row's section: a section starts, under its header, where the
name changes, and the header of the section at the top stays pinned
there. A `TableView` is the same with a header of `columns`: each of its
rows is a `TableRow`, whose children are the cells, one per column.

```slint
import { ListView, TableView } from "std-widgets.zge";

struct Contact { name: string, group: string }

export component Contacts inherits Window {
    width: 300px;
    height: 300px;
    var in <[Contact]> contacts: [{ name: "Ada", group: "A" }, { name: "Alan", group: "A" }, { name: "Barbara", group: "B" }];
    VerticalLayout {
        ListView {
            sections: root.contacts.map(c => c.group);
            for c in root.contacts : Text { height: 24px; text: c.name; }
        }
        TableView {
            columns: ["Name", "Group"];
            for c in root.contacts : TableRow {
                Text { text: c.name; }
                Text { text: c.group; }
            }
        }
    }
}
```

Both are made with `ListLayout`, which does the work: it is given the
scroll position and the height in view (`viewport-y`, `visible-height`)
and says where the section headers go (`section-names`, `section-ys`).

`StandardListView`, `StandardTableView` and `TreeView` select one item,
the current one, unless `selection-mode` says otherwise. With `extended`,
the user selects several as on desktops: a click selects one, a Ctrl- or
Cmd-click adds or removes one, a Shift-click (or Shift with the arrows)
selects a range, Ctrl+A or Cmd+A all. With `multiple`, each click (or
Space) adds or removes one, without keys held: the mode for touch
screens. `selected-items` (`selected-rows` for the table) lists them, in
order, and `selection-changed` says when they change; `select-all()`,
`clear-selection()` and `set-selected(i, on)` change them from code. A
TouchArea's `modifiers` are the keys held at the press, for clicks of
your own.

```slint
import { StandardListView } from "std-widgets.zge";

export component Files inherits Window {
    width: 240px;
    height: 200px;
    var out <int> picked: list.selected-items.length;
    list := StandardListView {
        selection-mode: extended;
        model: ["notes.txt", "photo.png", "song.ogg", "video.mp4"];
    }
}
```

In a `ListView`, `TableView` or `GridView` of your own rows, a `Selection`
keeps which are selected: its `count` rows, `selected` by row; `select(i)`,
`toggle(i)`, `extend-to(i)` (from the last selected or toggled to `i`),
`select-all()`, `clear()`.

```slint
import { GridView } from "std-widgets.zge";

export component Photos inherits Window {
    width: 300px;
    height: 200px;
    picked := Selection { count: 12; }
    GridView {
        for n[i] in 12 : Rectangle {
            width: 60px;
            height: 60px;
            background: picked.selected[i] ? #2563eb : #e2e8f0;
            TouchArea {
                clicked => {
                    if self.modifiers.shift { picked.extend-to(i); } else { picked.toggle(i); }
                }
            }
        }
    }
}
```

A `SplitView` puts its children side by side (or one above the other,
`vertical`) with a handle between each two that the pointer drags; each
pane keeps within its `min-width` and `max-width` (or heights), and at
first they share the room by their `preferred-width`s.

```slint
export component Editor inherits Window {
    width: 400px;
    height: 200px;
    SplitView {
        Rectangle { background: #f1f5f9; preferred-width: 120px; min-width: 80px; }
        Rectangle { background: #ffffff; preferred-width: 280px; }
    }
}
```

## Charts

`LineChart`, `BarChart` and `PieChart` draw a model of numbers within
their bounds; labels, axes and legends are elements around them:

```slint
export component Sales inherits Window {
    width: 320px;
    height: 200px;
    var in-out <int> picked: -1;
    Text {
        text: bars.hovered-index >= 0 ? "Week \{bars.hovered-index + 1}" : "Sales";
    }
    bars := BarChart {
        y: 24px;
        height: 120px;
        values: [12, 19, 15, 27, 22];
        grid-lines: 4;
        border-radius: 3px;
        clicked(i) => { root.picked = i; }
    }
    // A second series, on the bars' scale.
    LineChart {
        y: 24px;
        height: 120px;
        values: [14, 16, 18, 20, 22];
        minimum: bars.shown-minimum;
        maximum: bars.shown-maximum;
        point-size: 6px;
    }
    PieChart {
        x: 240px;
        y: 150px;
        width: 48px;
        height: 48px;
        values: [3, 2, 1];
        hole: 0.5;
    }
}
```

Line and bar charts show the values from `minimum` to `maximum`, or, when
those are not set, a range around the values and 0 rounded so that
`grid-lines` lines fall on round values; `shown-minimum` and
`shown-maximum` tell which, to label the lines. A line has a `color`, a
`line-width`, an area down to 0 (`fill`) and dots (`point-size`); bars and
slices take `colors` in turn (ten by default), and a pie with a `hole` is
a ring. The value under the pointer is `hovered-index` (-1 for none; hover
goes through to charts below, so stacked charts all see it), and a click on
one calls `clicked(index)`: a bar's place, a slice, or a line's point
within reach.

## Drawing from code

A `Canvas` draws what its `paint` handler says, as QML's Canvas and
HTML's `<canvas>` do, with functions of its own. Coordinates are
lengths in the canvas's own space; angles are degrees, clockwise.

```slint
export component Ring inherits Window {
    width: 160px;
    height: 160px;
    var in-out <float> level: 0.65;
    Canvas {
        paint => {
            self.line-width = 14px;
            self.stroke-style = #cbd5e1;
            self.begin-path();
            self.arc(80px, 80px, 50px, 0, 360, false);
            self.stroke();
            self.stroke-style = #2563eb;
            self.begin-path();
            self.arc(80px, 80px, 50px, -90, -90 + 360 * root.level, false);
            self.stroke();
            self.fill-style = #0f172a;
            self.font-size = 20px;
            self.text-align = TextHorizontalAlignment.center;
            self.fill-text(round(root.level * 100) + "%", 80px, 87px);
        }
    }
}
```

- **Paths:**
  - Start a path with `begin-path()`.
  - Build it with `move-to(x, y)`, `line-to(x, y)`,
    `quadratic-curve-to(cx, cy, x, y)` and
    `bezier-curve-to(c1x, c1y, c2x, c2y, x, y)`.
  - Add shapes with `arc(x, y, radius, start, end, anticlockwise)`
    (angles from 3 o'clock), `rect(x, y, w, h)`,
    `rounded-rect(x, y, w, h, radius)` and `ellipse(x, y, w, h)`.
    `close-path()` closes the current shape.
  - Then `fill()` the path in `fill-style`, `stroke()` it in `stroke-style`
    `line-width` wide, or `clip()` to it: what follows shows only inside,
    until `restore()`.
- **Rectangles:** `fill-rect`, `stroke-rect` and `clear-rect` take
  `x, y, w, h` and leave the current path alone. `clear-rect` only clears
  when it covers the whole canvas.
- **Text and images:** `fill-text(text, x, y)` draws text with its baseline
  at `y`, in `fill-style`, using `font-size`, `font-family` and
  `font-weight`. `text-align` puts `x` at its left, center or right.
  `draw-image(image, x, y, w, h)` draws an image stretched over that box.
- **Transforms:** `translate(x, y)`, `rotate(degrees)`, `scale(sx, sy)`
  and `reset-transform()` apply to the points and drawings that follow.
  `save()` and `restore()` keep and bring back the transform, the styles
  and the clip.
- **Fading:** `global-alpha` multiplies the opacity of what is then drawn.

The styles are properties of the canvas, so they can also be bound like
any other.

Each paint starts from an empty canvas. `paint` runs again before the next
frame:
- when the canvas is resized;
- when a property the handler read changes (`root.level` above), as a
  binding would;
- when `request-paint()` is called.

Properties the handler sets are no reason to paint again. What is drawn
is kept as paths, text and images, so every renderer draws it at full
resolution.

## Network requests

An `HttpRequest` asks a server over HTTP or HTTPS when `send()` is
called, and runs in the background; `json-get(text, path)`,
`json-number(text, path)` and `json-count(text, path)` read the JSON it
answers:

```slint
export component Repo inherits Window {
    var in-out <string> name: "ziglang/zig";
    req := HttpRequest {
        url: "https://api.github.com/repos/\{root.name}";
        headers: ["Accept: application/vnd.github+json"];
        failed => { debug(req.error); }
    }
    VerticalLayout {
        Text { text: json-get(req.response, "description"); }
        Text { text: "\{round(json-number(req.response, "stargazers_count"))} stars"; }
        TouchArea { clicked => { req.send(); } }
    }
}
```

A request goes to `url` with its `method` (`get`, `post`, `put`, `patch`,
`delete` or `head`), `headers` ("Name: value" each) and `body`. While it
runs, `loading` is true (`abort()` drops it, and another `send()` replaces
it). The answer is `status` and `response`, then `finished` (whatever the
status: a 404 is an answer); when there is none (no network, an unknown
host, a refused connection), `error` says why, then `failed`.

A JSON path is keys and indexes separated by dots: `items.0.name`, ""
for the whole text. `json-get` gives strings decoded, numbers as written,
`true` or `false`, and objects and arrays as JSON text, to read by path in
turn; `json-number` a number (0 if none); `json-count` how many values an
array has, or keys an object. Missing values are "" or 0. A list from
JSON:

```slint
export component Users inherits Window {
    req := HttpRequest { url: "https://example.com/users.json"; }
    VerticalLayout {
        for i in json-count(req.response, "users") : Text {
            text: json-get(req.response, "users.\{i}.name");
        }
    }
}
```

Requests run on threads; without them (the web, microcontrollers) they
fail. HTTPS checks servers' certificates against the system's.

## Opening links

`open-url(url)` hands a link to the system, which opens it with the
application for it: a web page in the browser, a `mailto:` link in the
mail program, a `file:` URL in the file's application. The URL needs a
scheme (`https:`, not just `example.com`). It returns whether the system
took the link; the application opens later.

```slint
export component About inherits Window {
    TouchArea {
        clicked => { open-url("https://ziglang.org"); }
    }
}
```

Each backend uses the platform's own way: SDL (the SDL3 backend),
NSWorkspace on macOS, UIApplication on iOS, the shell on Windows, the
desktop portal or `xdg-open` on X11 and Wayland, and a new tab on the web.
A browser may block the tab unless a click opened it. Links don't open on
KMS, fbdev or microcontrollers.

## 3D scenes

A `View3D` shows a 3D scene made of its children:

- **`Model`:** a shape. `mesh` is `cube`, `sphere` or `plane` (each 1
  unit across and centered; the plane faces +z). `size-x`, `size-y` and
  `size-z` stretch it. Its material is `color`, times `texture` (an image,
  repeated over the shape) if set, plus `metallic` (0 to 1) and
  `roughness` (0 shiny, 1 matte; 0.5 by default). Or it shows a model
  file: see below. A click on it calls `clicked`: the nearest model under
  the pointer gets it, and clicks that reach no model go on to what is
  below the view.
- **`PerspectiveCamera`:** where the scene is seen from, looking along its
  -z axis, with a vertical `field-of-view` (45 degrees by default). Without
  one, the scene is seen from 4 units in front of its middle.
- **`DirectionalLight`:** light from far away, like the sun, shining along
  its -z axis. **`PointLight`:** light from a point, half as bright `range`
  units away. Both have a `color` and a `brightness`. Without lights, the
  scene is lit from the upper left; `ambient` on the view lights
  everything evenly, times `ambient-brightness`.
- **`Node`:** a group that draws nothing. What it holds moves and turns
  with it, as do the nodes inside a `Model`.

Every node is placed with `position-x`, `position-y` and `position-z`, and
turned with `yaw` (about y), then `pitch` (about x), then `roll` (about z),
in degrees. Y points up and the camera looks along -z, as in OpenGL and Qt
Quick 3D. All of it can be bound and animated like any property:

```slint
View3D {
    background: #0f172a;
    Node {
        yaw: orbit;   // the camera goes round the middle
        PerspectiveCamera { position-y: 1.5; position-z: 5; pitch: -15; }
    }
    DirectionalLight { pitch: -45; yaw: -35; }
    Model {
        mesh: cube;
        color: #ef4444;
        yaw: spin;
        animate yaw { duration: 300ms; }
    }
}
```

A `Model` can show a glTF 2.0 model instead of a mesh: `source:
@model-url("ship.glb")` embeds the binary file (`.glb`) at build time, as
`@image-url` does an image. Its meshes are drawn in the file's own
materials (base color and its PNG texture, metallic and roughness),
placed by the file's nodes, then sized, placed and turned like any model.
`color` tints them. Animations, skins, morph targets, textures other than
PNG and data kept outside the `.glb` are not read.

`examples/scene.zge` spins a cube and a glTF model and moves the camera
around them; clicking the cube changes its color (`zigulee-viewer
examples/scene.zge`).

The scene is drawn into an image, then shown like any element, so it
clips, fades and tilts with the rest. The image is kept while the scene
doesn't change.
- **On the GPU** with Metal (macOS, native and SDL3 backends, and iOS),
  Direct3D 12 (the native Windows backend), OpenGL (SDL3 on Windows and
  Linux, the macOS backend's OpenGL option), Vulkan (SDL3's Vulkan
  option) and WebGL2 on the web: at the window's resolution, with
  multisampled edges.
- **On the CPU** with the native X11, Wayland, KMS and fbdev backends, which
  draw in software: at twice the view's size. Each frame shades every
  pixel, so this suits small scenes. A 610 x 268 view takes about 11 ms in
  a release build on a recent Mac, and continuous animation of a large
  view can drop frames on slower machines.

Both shade alike: the same scene looks the same either way.

## Web pages

A `WebView` shows a web page over its area: `url` loads a page, or `html`
shows HTML text (and takes over when set). `url` follows the page as the
user clicks links or the site redirects.

- **State:** `title`, `loading`, `can-go-back`, `can-go-forward`, and
  `error` when a page fails to load.
- **Actions:** `back()`, `forward()`, `reload()` and `stop()`.
- **Callbacks:** `finished` once a page has loaded, `failed` when it
  couldn't.
- **JavaScript:** `run-javascript(code)` runs code in the page. Its result
  arrives in `javascript-finished(result)` as text: strings as they are,
  other values as JSON. Errors go to `javascript-failed(error)`.
- **Cookies:** `set-cookie(url, cookie)` stores a cookie for `url`, written
  as a server's `Set-Cookie` header: `"session=abc; Path=/; Secure;
  HttpOnly"`. An app that signed in natively hands its session to the
  page this way, HttpOnly included, which the page's own JavaScript cannot
  set. Pages loaded after it wait until it is stored, so set it before
  `url`, even before the view shows. Not on the web: an `<iframe>` cannot
  be given an HttpOnly cookie (it logs a warning).

```slint
export component Help inherits Window {
    var in-out <string> heading;
    page := WebView {
        url: "https://ziglang.org/documentation/master/";
        finished => { page.run-javascript("document.querySelector('h1').textContent"); }
        javascript-finished(text) => { root.heading = text; }
    }
}
```

The page is a native view placed over the element, as with Qt WebView:
- It always shows above zigulee's content, popups included.
- It takes no rotation, opacity or effects, and scroll views don't clip
  it.
- It follows the element's position, size and visibility after each frame.
- Its title may arrive just after `finished`, so bind to `title` rather
  than reading it there.

Where it works:
- **macOS** (WKWebView), with the native and the SDL3 backends.
- **iOS** (WKWebView).
- **Windows** (WebView2), with the native and the SDL3 backends. It needs
  the WebView2 runtime, which Windows 11 includes and Windows 10 gets with
  Edge. An application can ship `WebView2Loader.dll` beside it, but
  doesn't have to. The browser's data (cookies, cache) goes in the
  application's cache folder.
- **Linux on X11** (WebKitGTK, GTK 3: webkit2gtk-4.1 or 4.0), with the
  native X11 and the SDL3 backends. WebKitGTK is loaded when the first
  web view is made, so applications don't depend on it: where it isn't
  installed, `available` is false. A click in the page gives it the
  keyboard, and a click on zigulee's content takes it back.
- **The web:** an `<iframe>`. The title, address, history and scripts are
  only available for pages from the app's own site and for `html`.

Elsewhere `available` is false and the element shows nothing: on Wayland
(a window there can't hold another program's view, so the native Wayland
backend and SDL3 on Wayland have none), KMS, fbdev and microcontrollers. It is
also false when the platform's engine is missing (WebView2 or WebKitGTK).

## Tray icons and notifications

A `SystemTrayIcon` puts an icon (its `icon` image) in the system tray: on the right of
macOS's menu bar, or in Windows' notification area. Its `PlatformMenuItem`
children are its menu, and an icon without a menu calls `activated` when
clicked. A `Notification` shows a desktop notification each time `send()`
is called, and calls `clicked` when the user clicks it. Both have an
`available` property that is false where the platform has no tray or no
notifications.

```slint
export component Sync inherits Window {
    var in-out <bool> paused;
    SystemTrayIcon {
        tooltip: root.paused ? "Sync (paused)" : "Sync";
        PlatformMenuItem {
            text: "Paused";
            checked: root.paused;
            activated => { root.paused = !root.paused; }
        }
        PlatformMenuItem {
            text: "Tell me";
            activated => { done.send(); }
        }
    }
    done := Notification {
        title: "Sync";
        body: "Everything is up to date.";
    }
}
```

Where it works:

- **macOS:** both. Notifications go to the Notification Center, which
  needs an app bundle. Outside a bundle (the viewer, `zig build run`)
  they are shown through AppleScript, and clicks are not reported. Without
  an `icon`, the tray icon shows its tooltip as text.
- **Windows:** both. Notifications appear as the tray icon's balloon,
  which Windows 10 and 11 show as notifications. With no tray icon, the
  first notification adds one with the application's icon, and it stays.
- **Linux:** notifications on every desktop with a notification service.
  Tray icons only with the SDL3 backend, where the desktop must support
  them; a click opens the menu, and an icon without a menu cannot be
  activated.
- **Elsewhere** (the web, iOS, KMS, fbdev, microcontrollers): neither. `send()`
  only writes the notification to the log.

## Camera and microphone

A `Camera` shows the camera's picture, like an `Image`, while it is
`active`. `take-picture()` keeps the frame on screen as `picture` and
calls `picture-taken`, and `save-picture(path)` writes that picture as a
PNG file.

A `Microphone` measures sound while it is `active`: `level` goes from 0
to 1, for a meter. `record()` keeps what it hears until `stop()` is
called. Then `recorded` holds the sound, which an `Audio` element can
play, and `save-recording(path)` writes it as a WAV file. While
recording, `duration` gives the length so far.

```slint
export component Memo inherits Window {
    mic := Microphone { active: true; }
    playback := Audio { source: mic.recorded; }
    VerticalLayout {
        cam := Camera { active: true; image-fit: cover; }
        Rectangle {
            height: 8px;
            Rectangle { x: 0; width: parent.width * mic.level; background: green; }
        }
        TouchArea {
            height: 40px;
            clicked => {
                if mic.recording { mic.stop(); playback.play(); } else { mic.record(); }
            }
        }
    }
}
```

The default camera and microphone are used. The device runs while any
element needs it. The first time, the platform may ask the user for
permission: macOS does, and a macOS app bundle must say why in its
`Info.plist` (`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`).
Both work with the SDL3 backend (macOS, Windows, Linux) and the native
macOS backend (AVFoundation). Elsewhere, `available` is false.

## Motion sensors

An `Accelerometer`, a `Gyroscope`, a `Compass` and an `OrientationSensor`
read the device's motion while they are `active`, and call
`reading-changed` at each reading:

- **`Accelerometer`:** `x`, `y` and `z` in m/s², gravity included. Lying
  face up it reads about 0, 0, 9.81.
- **`Gyroscope`:** how fast the device turns about `x`, `y` and `z`, in
  degrees a second (counterclockwise, looking down the axis).
- **`Compass`:** `azimuth` in degrees clockwise from magnetic north, and
  `calibration-level` from 0 to 1.
- **`OrientationSensor`:** which side is up, as `orientation`:
  `DeviceOrientation.top-up`, `top-down`, `left-up`, `right-up`,
  `face-up`, `face-down`, or `unknown` until known. Where the platform
  tells no orientation, it is worked out from the accelerometer.

The axes are the device's, held in its natural position: x to the right,
y up, z out of the screen. `data-rate` limits the readings to that many a
second (0, the default, takes them as they come), and `available` tells
whether the platform has the sensor.

```slint
export component Level inherits Window {
    width: 200px;
    height: 200px;
    accel := Accelerometer { active: true; data-rate: 30; }
    // The bubble goes up the slope.
    Rectangle {
        x: parent.width / 2 - 10px - accel.x * 8px;
        y: parent.height / 2 - 10px + accel.y * 8px;
        width: 20px;
        height: 20px;
        border-radius: 10px;
        background: #22c55e;
    }
}
```

In a browser (the wasm backend), readings come from the page's
`devicemotion` and `deviceorientation` events. Computers have the API
without the sensors, so `available` is true there but no readings
arrive. iOS asks the user first, at the next tap. In the ESP32-S3 board
example, the board's QMI8658 gives the accelerometer and the gyroscope.
The SDL3 and desktop backends have no sensors yet.

## Location

A `PositionSource` follows the device's position while it is `active`.
The first time, the platform asks the user. `valid` turns true with the
first fix, and `updated` is called at each one:

- `latitude` and `longitude` in degrees (WGS 84). They are floats, so
  they hold the position to about a meter.
- `accuracy`: the radius, in meters, the true position is likely within.
- `altitude` in meters above sea level, `speed` in m/s and `direction` in
  degrees clockwise from true north. Each has a flag (`altitude-valid`,
  `speed-valid`, `direction-valid`), since the platform may not know it.
- `timestamp`: when the fix was taken, as a duration since 1970 (UTC).

`minimum-interval` takes at most one fix that often (0, the default:
every one). `error` says why there is no position:
`PositionError.permission-denied`, `unavailable` or `timeout` (`none`
once a fix comes). `available` tells whether there is a location service.

```slint
export component Where inherits Window {
    width: 240px;
    height: 80px;
    here := PositionSource { active: true; minimum-interval: 5s; }
    Text {
        text: here.valid
            ? "\{round(here.latitude * 10000) / 10000}, \{round(here.longitude * 10000) / 10000} (±\{round(here.accuracy)} m)"
            : here.error == PositionError.permission-denied ? "Not allowed" : "Looking…";
    }
}
```

Browsers (the wasm backend) use `navigator.geolocation`, and ask the
user. The native macOS backend and the iOS backend use Core Location. An
app bundle must say why it wants the position in its `Info.plist`
(`NSLocationWhenInUseUsageDescription`), or the system refuses; for iOS
apps built with `iosApp`, set `location_usage`. Geocoding and maps are
not included: a tile map can be built from `HttpRequest` and `Image`.

## Maps

A `MapView` shows a map of web tiles centered on `latitude`, `longitude`
at `zoom` (0 shows the whole world in one 256-pixel tile, and each step
doubles the scale; fractional zooms are fine). Dragging pans it, and the
wheel, a pinch or a double click zoom it, unless `interactive` is false.
A click calls `clicked(latitude, longitude)`, and `zoom-in()` and
`zoom-out()` go a step.

Children are drawn over the map. A `MapItem` stands at its own
`latitude` and `longitude`: give it a size, and its children are what
shows there. `anchor-x` and `anchor-y` say which point of it sits on the
place (0.5, 0.5, the default, is its middle; 0.5, 1 its bottom middle,
for a pin). A `MapPolyline` draws a line through `coordinates`, given as
latitude, longitude pairs in one list; `closed` makes an outline, filled
with `fill`.

```slint
export component Trip inherits Window {
    width: 400px;
    height: 300px;
    MapView {
        latitude: 45.27;
        longitude: 8.44;
        zoom: 7;
        MapPolyline { coordinates: [45.4642, 9.19, 45.0703, 7.6869]; stroke: #dc2626; }
        MapItem {
            latitude: 45.4642;
            longitude: 9.19;
            width: 12px;
            height: 12px;
            Rectangle { border-radius: 6px; background: #2563eb; }
        }
    }
}
```

Tiles come from `tile-url`, a template whose `{z}`, `{x}` and `{y}` are
filled in. By default it is OpenStreetMap's, whose terms ask for the
`attribution` shown in the corner (keep it, or show it elsewhere) and an
application that says who it is: `user-agent` is the application's name
by default. For heavy use, take tiles from a provider meant for it. Tiles
load in the background, at most six at a time, and stay in memory and,
for a week, in the application's cache folder; while a tile is coming, a
lower zoom level's stands in. `file://` templates read tiles from disk.
On screens of two pixels a point (phones, Retina screens), the map takes
the next zoom level's tiles at half their size, so it stays sharp (its
labels smaller); a template with `{r}` (filled with `@2x` there) takes
the server's own tiles for such screens instead. `high-density: false`
turns that off. On the web, tiles come through the browser: the tile
server must allow other sites' pages to take them (OpenStreetMap's does),
and the browser says who asks. On microcontrollers no tiles come from the
network.

To follow the device, bind the map to a `PositionSource` (`latitude:
here.latitude;`): dragging the map then takes over from the binding.
examples/map.zge shows a pin dropped where you click, your position, and
zoom buttons.

## Popups

A `PopupWindow` is shown above everything with `show()`:

```slint
export component Menu inherits Window {
    width: 200px;
    height: 200px;
    TouchArea { clicked => { popup.show(); } }
    popup := PopupWindow {
        x: 20px;
        y: 20px;
        width: 120px;
        height: 60px;
        Rectangle { background: white; border-width: 1px; border-color: gray; }
        Text { text: "A popup"; }
    }
}
```

By default a click anywhere closes it (`close-policy`: `close-on-click`,
`close-on-click-outside` or `no-auto-close`).

## Drag and drop

A `DragArea` is dragged by the pointer: a press moved past a few pixels
drags its `kind` and `data` (strings). A `DropArea` takes the kind it
`accepts` (`""`: any): `contains-drag` while one is over it, with its
`drag-data` and the pointer at `drag-x`, `drag-y`, then `dropped(data)`.
The DragArea draws nothing: what shows the drag follows its `offset-x`
and `offset-y` while `dragging`. `finished(dropped)` says how it ended;
Escape cancels.

```slint
export component Board inherits Window {
    width: 300px;
    height: 120px;
    var out <string> placed;
    bin := DropArea {
        x: 180px;
        width: 100px;
        height: 100px;
        accepts: "card";
        dropped(data) => { root.placed = data; }
        Rectangle { background: bin.contains-drag ? #bbf7d0 : #e2e8f0; }
    }
    card := DragArea {
        width: 60px;
        height: 40px;
        kind: "card";
        data: "ace of hearts";
        Rectangle {
            x: card.offset-x;
            y: card.offset-y;
            background: card.dragging ? #2563eb : #1e3a8a;
        }
    }
}
```

Files and text dragged from other applications land on DropAreas too:
one that `accepts: "file"` takes files (`data` is their paths, one per
line), one that `accepts: "text"` takes text. They highlight while the
drag is over them like drags within the application (the kind is known
at the drop on some platforms: there, a DropArea for either highlights).
Every backend takes them: macOS, Windows, X11 (XDND), Wayland, SDL3, and
the web, where a page sees file names, not paths.

## Touch and gestures

A finger works as the mouse: buttons, lists and drags work with touch.
Two fingers over a `PinchArea` pinch and turn instead: while it is
`active`, `pinch-scale` (1 at the start) and `pinch-rotation` (degrees,
clockwise) follow them, about `center-x`, `center-y`; `started`,
`updated` and `finished` mark the gesture. A trackpad's pinch and rotation
(macOS; SDL's pinch) drive it too. A `SwipeArea` reports a quick drag
(of the mouse or a finger) with `swiped(direction)`: `SwipeDirection.left`,
`right`, `up` or `down`, once it went `distance` (40 px) mostly that way;
what is in it still gets clicks.

```slint
export component Photo inherits Window {
    width: 300px;
    height: 200px;
    var in-out <float> zoom: 1;
    var in-out <int> page;
    SwipeArea {
        swiped(direction) => {
            if direction == SwipeDirection.left { root.page += 1; }
            if direction == SwipeDirection.right { root.page -= 1; }
        }
    }
    pinch := PinchArea {
        finished => { root.zoom = root.zoom * self.pinch-scale; }
        Rectangle {
            width: 100px * root.zoom * (pinch.active ? pinch.pinch-scale : 1);
            height: 60px;
            background: #2563eb;
        }
    }
}
```

Fingers come from SDL3, Windows (touch screens), Wayland, the KMS and
fbdev backends (multi-touch screens) and the web; on X11, the server makes a touch screen
a pointer (no pinches).

### Noticing any input

The window's `input-activity` callback is called for every press, move,
release, wheel turn, finger, trackpad gesture and key, whichever element
takes it, and while an element is dragging: it watches without taking
anything. A screen that dims after a while without use restarts its timer
there:

```slint
export component Strip inherits Window {
    width: 480px;
    height: 128px;
    var in-out <bool> asleep;
    idle := Timer {
        interval: 60s;
        triggered => {
            root.asleep = true;
            idle.stop();
        }
    }
    input-activity => {
        root.asleep = false;
        idle.restart();
    }
}
```

From Zig, `window.pointer_observed` also gets each pointer event itself
(window coordinates), before it is dispatched.

## Keyboard input

A `FocusScope` receives key events when it has the focus (after a click in
it, Tab, or `focus()`). Its handlers get the event (`text`, `modifiers`,
`repeat`) and return `accept` or `reject`:

```slint
export component Keys inherits Window {
    width: 100px;
    height: 100px;
    var in-out <int> count;
    FocusScope {
        key-pressed(event) => {
            if event.text == Key.UpArrow { count += 1; return accept; }
            if event.text == "r" && event.modifiers.control { count = 0; return accept; }
            return reject;
        }
    }
}
```

`Key` names the special keys: `Backspace`, `Tab`, `Return`, `Escape`,
`Backtab`, `Delete`, `Space`, `UpArrow`, `DownArrow`, `LeftArrow`,
`RightArrow`, `Home`, `End`, `PageUp` and `PageDown`. Text fields
(`TextInput`, `LineEdit`, `TextEdit`) handle the keyboard themselves.


A `Shortcut` runs something wherever the focus is: `activated` when its
`sequence` is pressed and the focused element does not take the keys
(Ctrl+C in a text field copies there). A sequence is modifiers (`Ctrl`,
`Shift`, `Alt`, `Meta`) and a key (`S`, `Plus`, `Escape`, `Left`, ...);
`Ctrl` is Command on macOS. A menu bar item's `shortcut` is one too, with
the menu closed.

```slint
export component Editor inherits Window {
    var in-out <int> saved;
    Shortcut {
        sequence: "Ctrl+S";
        activated => { root.saved += 1; }
    }
}
```

### On-screen keyboard

On a touch screen without a physical keyboard (KMS, fbdev, microcontrollers),
`VirtualKeyboard` from std-widgets.zge types into the focused text field.
Put it at the bottom of the window's layout: it is open only while a
field that can be edited has the focus (or with `always-open`), and takes
no room otherwise. It has letters (Shift once for a capital, twice to
lock), two pages of digits and symbols, a Backspace that repeats when
held, space, Return, and a key that closes it by taking the focus away.

```slint
import { LineEdit, VirtualKeyboard } from "std-widgets.zge";

export component Kiosk inherits Window {
    VerticalLayout {
        LineEdit { placeholder-text: "Name"; }
        Rectangle { }
        VirtualKeyboard { key-height: 52px; }
    }
}
```

Another layout can be built on `KeyboardInput`, which `VirtualKeyboard`
uses: `active` while a field can be typed into (`multi-line` and
`password` tell what kind), `send(text)` to type a character or a key
(`Key.Backspace`, `Key.Return`, ...), and `dismiss()` to take the focus
away. Clicks on `TouchArea`s leave the focus in the field.

## Translations

Texts shown to users are marked with `@tr`, which translates them into the
current language (see [embedding](embedding.md#translations) for choosing
it):

```slint
export component Inbox inherits Window {
    width: 240px;
    height: 120px;
    var in <string> user: "Ada";
    var in <int> unread: 3;
    VerticalLayout {
        Text { text: @tr("Hello, {}!", user); }
        Text { text: @tr("{n} new message" | "{n} new messages" % unread); }
        Text { text: @tr("menu" => "Open"); }
    }
}
```

- `{}` takes the next argument, `{0}`, `{1}`... a given one (translations
  may need another order), and `{{`, `}}` are braces. The text itself is a
  plain string: values go in arguments, not in `\{...}`.
- `"singular" | "plural" % count` has plural forms, chosen by the count
  (`{n}` shows it). Languages with other plural rules have their own forms
  in their translation.
- `"context" => "text"` tells apart equal texts with different meanings.

Changing the language updates every translated text at once.
`zgec tr` collects the texts to translate (see [tooling](tooling.md#translations)).

## Accessibility

Screen readers (VoiceOver on macOS; Narrator, NVDA or JAWS on Windows;
Orca on Linux) read an interface from what its elements say about themselves. The standard
widgets do it already: a Button is a button with its text as label, a
CheckBox reports whether it is checked, a Slider its value and range, and
each can be used from the screen reader (press, toggle, increment...). Your own controls describe themselves with the
`accessible-` properties, and do what assistive technology asks in the
`accessible-action-` callbacks:

```slint
component Stars inherits Rectangle {
    var in-out <int> rating;
    accessible-role: slider;
    accessible-label: "Rating";
    accessible-value: "\{rating} of 5 stars";
    accessible-value-maximum: 5;
    accessible-action-increment => { rating = min(5, rating + 1); }
    accessible-action-decrement => { rating = max(0, rating - 1); }
    HorizontalLayout {
        for i in 5 : Text { text: i < rating ? "★" : "☆"; }
    }
}

export component Review inherits Window {
    width: 200px;
    height: 60px;
    Stars { rating: 3; }
}
```

A control's children are part of it: the stars here are not read out one
by one. Texts are read as they are; `accessible-role: none` hides an
element (its children stay visible to the screen reader). The
[reference](reference/elements.md) lists the properties and roles.

A list or table of your own lets the screen reader select its items: the
list says whether several can be selected (`accessible-multiselectable`),
each item whether it is (`accessible-checked`), and
`accessible-action-select` (only this one) and
`accessible-action-set-selected(on)` (add it or remove it) do it.
StandardListView, StandardTableView and TreeView do this already.
