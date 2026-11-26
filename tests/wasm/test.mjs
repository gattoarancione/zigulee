// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

// Runs tests/wasm/app.zig through the browser glue (zigulee.js) in Node,
// with a fake canvas: `node test.mjs app.wasm zigulee.js` (zig build test).
import { readFileSync } from "node:fs";
import { deflateSync, crc32 } from "node:zlib";
import { pathToFileURL } from "node:url";

const [wasmPath, gluePath] = process.argv.slice(2);
const { start } = await import(pathToFileURL(gluePath).href);

let failures = 0;
function check(cond, what) {
  if (!cond) {
    console.error("failed: " + what);
    failures++;
  }
}

// What the browser would provide.
globalThis.ImageData = class {
  constructor(w, h) {
    this.width = w;
    this.height = h;
    this.data = new Uint8ClampedArray(w * h * 4);
  }
};
const listeners = {};
const keys = {}; // the hidden textarea's listeners
const textarea = {
  style: {},
  value: "",
  setAttribute() {},
  addEventListener(type, fn) {
    keys[type] = fn;
  },
  focus() {},
};
// A web view's iframe: its style, contents, and what the page would do.
const iframe = {
  style: {},
  srcdoc: "",
  load: null,
  addEventListener(type, fn) {
    if (type === "load") this.load = fn;
  },
  removeAttribute() {},
  remove() {},
  contentDocument: { title: "T" },
  contentWindow: { location: { href: "about:srcdoc" }, eval: (code) => eval(code) },
};
const document = {
  createElement: (tag) => (tag === "textarea" ? textarea : tag === "iframe" ? iframe : null),
  body: { appendChild() {} },
};
const drawn = [];
let shown = null; // the ImageData last drawn from
const canvas = {
  ownerDocument: document,
  parentNode: { appendChild() {} },
  offsetLeft: 0,
  offsetTop: 0,
  clientWidth: 200,
  clientHeight: 100,
  width: 0,
  height: 0,
  style: {},
  tabIndex: -1,
  addEventListener(type, fn) {
    listeners[type] = fn;
  },
  getContext(type) {
    if (type !== "2d") return null; // no WebGL2 here: the software renderer
    return {
      putImageData(image, dx, dy, x, y, w, h) {
        shown = image;
        drawn.push([x, y, w, h]);
      },
    };
  },
  getBoundingClientRect: () => ({ left: 0, top: 0 }),
  focus() {},
  setPointerCapture() {},
};
// The page's motion events: a browser with the API (and no iOS prompt).
globalThis.DeviceMotionEvent = class {};
const sensorEvents = {};
const sensorTarget = {
  addEventListener(type, fn) {
    sensorEvents[type] = fn;
  },
  removeEventListener(type, fn) {
    if (sensorEvents[type] === fn) delete sensorEvents[type];
  },
};
// Geolocation: watched, the callbacks kept to call by hand.
const geo = { watching: null, cleared: [] };
const geolocation = {
  watchPosition(ok, fail) {
    geo.watching = { ok, fail };
    return 7;
  },
  clearWatch(id) {
    geo.cleared.push(id);
  },
};
let clock = 1000;
const frames = [];
const timers = []; // [due, callback]
const copied = [];
const env = {
  requestFrame: (cb) => frames.push(cb),
  setTimeout: (cb, ms) => timers.push([clock + ms, cb]) - 1,
  clearTimeout: (id) => {
    if (timers[id]) timers[id][1] = null;
  },
  now: () => clock,
  pixelRatio: () => 2,
  copy: (text) => copied.push(text),
  sensorTarget,
  geolocation,
  fetch: fakeFetch,
};

// The network: a 2 x 1 PNG, sent in two pieces; nothing else there.
function pngBytes() {
  const chunk = (type, data) => {
    const out = Buffer.alloc(12 + data.length);
    out.writeUInt32BE(data.length, 0);
    out.write(type, 4, "latin1");
    data.copy(out, 8);
    out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
    return out;
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(2, 0);
  header.writeUInt32BE(1, 4);
  header[8] = 8; // bits
  header[9] = 6; // RGBA
  const raw = Buffer.from([0, 255, 0, 0, 255, 0, 0, 255, 255]);
  return new Uint8Array(Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]));
}
const fetches = [];
async function fakeFetch(url, init) {
  fetches.push([url, init.headers.get("x-token")]);
  if (!url.endsWith("/dot.png")) return { ok: false, status: 404 };
  const png = pngBytes();
  const parts = [png.subarray(0, 10), png.subarray(10)];
  return {
    ok: true,
    status: 200,
    headers: { get: (name) => (name.toLowerCase() === "content-length" ? String(png.length) : null) },
    body: {
      getReader() {
        let i = 0;
        return { read: async () => (i < parts.length ? { done: false, value: parts[i++] } : { done: true }) };
      },
    },
  };
}
/** Lets the pending fetches finish, running frames and timers meanwhile. */
async function settle() {
  for (let i = 0; i < 20; i++) {
    await new Promise((resolve) => setTimeout(resolve, 0));
    clock += 20;
    run();
  }
}
/** Runs the frames asked for, and the timers due by now. */
function run() {
  for (let i = 0; i < 100; i++) {
    if (frames.length > 0) {
      clock += 16; // frames come at the display's rate
      frames.shift()();
      continue;
    }
    const due = timers.find((t) => t[1] && t[0] <= clock);
    if (!due) break;
    const cb = due[1];
    due[1] = null;
    cb();
  }
}
const noMods = { shiftKey: false, ctrlKey: false, altKey: false, metaKey: false };
function pointer(type, x, y) {
  listeners[type]({ clientX: x, clientY: y, button: 0, pointerId: 1, ...noMods });
}
/** Typing: keydown, then the textarea's input event (unless handled). */
function type(text, mods = {}) {
  for (const key of text) {
    let handled = false;
    const e = { key, repeat: false, preventDefault: () => (handled = true), ...noMods, ...mods };
    keys.keydown(e);
    if (!handled) keys.input({ data: key, isComposing: false });
    keys.keyup(e);
  }
}

const app = await start({ wasm: readFileSync(wasmPath), canvas, env });
const z = app.instance.exports;
run();

// The first frame: everything, at twice the resolution.
check(canvas.width === 400 && canvas.height === 200, `canvas ${canvas.width}x${canvas.height}`);
check(drawn.length > 0 && drawn[0][2] === 400 && drawn[0][3] === 200, "a full first frame");
const px = (x, y) => Array.from(shown.data.subarray((y * 400 + x) * 4, (y * 400 + x) * 4 + 4));
check(px(390, 190).join() === [0x33, 0x66, 0x99, 255].join(), "the background color, got " + px(390, 190));

// A click on the button.
pointer("pointerdown", 100, 24);
pointer("pointerup", 100, 24);
run();
check(z.test_clicks() === 1, "clicks: " + z.test_clicks());

// A finger's tap clicks it too (the first finger works as the mouse), and
// the canvas keeps fingers from the page.
const finger = (type) => listeners[type]({ clientX: 100, clientY: 24, button: 0, pointerId: 9, pointerType: "touch", ...noMods });
finger("pointerdown");
finger("pointerup");
run();
check(z.test_clicks() === 2, "clicks after a tap: " + z.test_clicks());
check(canvas.style.touchAction === "none", "touch-action: " + canvas.style.touchAction);

// Typing into the field, with its cursor.
pointer("pointermove", 100, 64);
check(canvas.style.cursor === "text", "I-beam over the field, got " + canvas.style.cursor);
pointer("pointerdown", 100, 64);
pointer("pointerup", 100, 64);
type("hé!");
keys.keydown({ key: "Backspace", repeat: false, preventDefault() {}, ...noMods });
run();
const typed = new TextDecoder().decode(new Uint8Array(z.memory.buffer, z.test_typed_ptr(), z.test_typed_len()));
check(typed === "hé", "typed: " + JSON.stringify(typed));

// Copying goes to the browser's clipboard; pasting types the text.
type("a", { ctrlKey: true });
type("c", { ctrlKey: true });
check(copied.join() === "hé", "copied: " + JSON.stringify(copied));
keys.paste({ clipboardData: { getData: () => " ok" }, preventDefault() {} });
run();
const pasted = new TextDecoder().decode(new Uint8Array(z.memory.buffer, z.test_typed_ptr(), z.test_typed_len()));
check(pasted === " ok", "after pasting over the selection: " + JSON.stringify(pasted));

// An input method: composed text shows in the field (not in its text)
// until committed; the textarea follows the caret.
keys.compositionstart({});
keys.compositionupdate({ data: "にほ" });
keys.keydown({ key: "Process", isComposing: true, repeat: false, preventDefault() {}, ...noMods });
keys.input({ data: "にほ", isComposing: true });
run();
const during = new TextDecoder().decode(new Uint8Array(z.memory.buffer, z.test_typed_ptr(), z.test_typed_len()));
check(during === " ok", "while composing: " + JSON.stringify(during));
keys.compositionend({ data: "日本" });
run();
const committed = new TextDecoder().decode(new Uint8Array(z.memory.buffer, z.test_typed_ptr(), z.test_typed_len()));
check(committed === " ok日本", "after composing: " + JSON.stringify(committed));
check(parseFloat(textarea.style.top) > 40 && parseFloat(textarea.style.left) > 10, `textarea at the caret: ${textarea.style.left}, ${textarea.style.top}`);

// Text dragged from the page over the drop area, then dropped.
let accepted = false;
const dataTransfer = { types: ["text/plain"], files: [], dropEffect: "none", getData: () => "dragged words" };
listeners.dragover({ dataTransfer, clientX: 170, clientY: 85, preventDefault() { accepted = true; } });
check(accepted && dataTransfer.dropEffect === "copy", "a text drag over the drop area is accepted");
accepted = false;
listeners.dragover({ dataTransfer, clientX: 20, clientY: 85, preventDefault() { accepted = true; } });
check(!accepted, "not where nothing takes it");
listeners.drop({ dataTransfer, clientX: 170, clientY: 85, preventDefault() {} });
run();
const dropped = new TextDecoder().decode(new Uint8Array(z.memory.buffer, z.test_dropped_ptr(), z.test_dropped_len()));
check(dropped === "dragged words", "dropped: " + JSON.stringify(dropped));

// Later frames redraw only what changed: hovering the button.
clock += 1000;
run();
const before = drawn.length;
pointer("pointermove", 100, 24);
run();
const last = drawn[drawn.length - 1];
check(drawn.length > before && last[2] < 400 && last[1] < 100, "a partial frame over the button: " + JSON.stringify(drawn.slice(before)));
check(canvas.style.cursor === "default", "default cursor over the button");

// The web view: an iframe placed over its element, showing its text; the
// page's title once loaded; JavaScript run in it.
check(iframe.style.left === "10px" && iframe.style.top === "60px" && iframe.style.width === "60px", "iframe placed: " + JSON.stringify(iframe.style));
check(iframe.style.display === "block", "iframe shown");
check(iframe.srcdoc === "<title>T</title>", "iframe text: " + iframe.srcdoc);
iframe.load();
run();
check(z.test_page_title_len() === 1, "page title length " + z.test_page_title_len());
z.test_run_js();
run();
const js = new TextDecoder().decode(new Uint8Array(z.memory.buffer, z.test_js_ptr(), z.test_js_len()));
check(js === "42", "JavaScript result: " + js);

// Motion: the accelerometer listens to devicemotion while active; the
// orientation comes from it.
check(typeof sensorEvents.devicemotion === "function", "listening to devicemotion");
check(sensorEvents.deviceorientation === undefined, "no compass wanted, none listened to");
sensorEvents.devicemotion({ accelerationIncludingGravity: { x: 0.2, y: 9.7, z: 0.8 }, rotationRate: null });
run();
check(Math.abs(z.test_tilt() - 9.7) < 1e-5, "accelerometer y: " + z.test_tilt());
check(z.test_way() === 1, "upright (top-up = 1), got " + z.test_way());
sensorEvents.devicemotion({ accelerationIncludingGravity: { x: 9.7, y: 0, z: 0.3 }, rotationRate: null });
run();
check(z.test_way() === 4, "right side up (right-up = 4), got " + z.test_way());

// The position: watched while active; a refusal, then a fix.
check(geo.watching !== null, "geolocation watched");
geo.watching.fail({ code: 1 });
run();
check(z.test_why() === 1, "permission denied (1), got " + z.test_why());
geo.watching.ok({ coords: { latitude: 45.4642, longitude: 9.19, altitude: null, accuracy: 15, speed: null, heading: NaN }, timestamp: 1763000000000 });
run();
check(Math.abs(z.test_lat() - 45.4642) < 1e-4, "latitude: " + z.test_lat());
check(z.test_why() === 0, "no error once a fix came, got " + z.test_why());

// An image from the network: through the page's fetch, with its header,
// its progress followed; a missing one fails.
z.test_load_picture(1);
run();
await settle();
check(fetches.length === 1 && fetches[0][0] === "https://tiles.example/dot.png" && fetches[0][1] === "abc", "fetched with the header: " + JSON.stringify(fetches));
check(z.test_picture_width() === 2, "the picture's width: " + z.test_picture_width());
check(z.test_picture_progress() === 1, "the picture's progress: " + z.test_picture_progress());
z.test_load_picture(0);
run();
await settle();
check(z.test_picture_failed(), "a missing picture fails");

// ---- WebGL2: the GPU renderer's calls, on a fake context that records them ----

{
  const calls = [];
  const sources = [];
  let nextId = 1;
  const object = () => ({ id: nextId++ });
  const fake = new Proxy(
    {
      createShader: object,
      createProgram: object,
      createBuffer: object,
      createTexture: object,
      createVertexArray: object,
      createFramebuffer: object,
      checkFramebufferStatus: () => 0x8cd5, // complete
      getUniformLocation: (p, name) => ({ name }),
      shaderSource: (sh, text) => sources.push(text),
      getShaderParameter: () => true,
      getProgramParameter: () => true,
      getShaderInfoLog: () => "",
      getProgramInfoLog: () => "",
      getError: () => 0,
    },
    {
      get(target, name) {
        if (name in target) return target[name];
        return (...args) => calls.push([name, ...args]);
      },
    },
  );
  const glCanvas = { ...canvas, style: {}, getContext: (type) => (type === "webgl2" ? fake : null) };
  const app2 = await start({ wasm: readFileSync(wasmPath), canvas: glCanvas, env });
  run();
  check(app2.renderer === "webgl2", "renderer: " + app2.renderer);
  // The 2D program's two, and the 3D one's.
  check(sources.length === 4 && sources.every((s) => s.startsWith("#version 300 es")), "ES 3.00 shaders");
  const named = (n) => calls.filter((c) => c[0] === n);
  // The vertex and index buffers come from wasm memory: 112-byte vertices,
  // 4-byte indices, 6 per quad and 4 vertices.
  const uploads = named("bufferData").map((c) => [c[1], c[2].length]);
  const vertices = uploads.find((u) => u[0] === 0x8892);
  const indices = uploads.find((u) => u[0] === 0x8893);
  check(vertices && vertices[1] > 0 && vertices[1] % 112 === 0, "vertex bytes " + JSON.stringify(uploads));
  check(indices && indices[1] / 4 / 6 === vertices[1] / 112 / 4, "indices per quad");
  const draws = named("drawElements");
  check(draws.length > 0 && draws.reduce((n, d) => n + d[2], 0) === indices[1] / 4, "draws cover the indices");
  // The atlas (one byte a texel) and the glyphs written into it.
  check(named("texImage2D").some((c) => c[3] === 0x8229 && c[4] === 1024), "R8 atlas texture");
  check(named("texSubImage2D").some((c) => c[7] === 0x1903 && c[9].some((b) => b !== 0)), "glyphs uploaded to the atlas");
  check(named("viewport").at(-1).join() === ["viewport", 0, 0, 400, 200].join(), "viewport in device pixels");
  // Frames are drawn into a texture, then copied to the canvas.
  check(named("blitFramebuffer").length > 0 && named("blitFramebuffer").at(-1).slice(1, 9).join() === "0,0,400,200,0,0,400,200", "the frame copied to the canvas");
}

if (failures > 0) {
  console.error(`${failures} check(s) failed`);
  process.exit(1);
}
console.log("wasm: all checks passed");
