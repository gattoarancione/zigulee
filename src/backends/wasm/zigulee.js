// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

// zigulee in the browser: runs an app built with the zigulee-wasm backend in a
// <canvas>.
//
//   import { start } from "./zigulee.js";
//   await start({ wasm: fetch("app.wasm"), canvas: document.querySelector("canvas") });
//
// The canvas takes the keyboard focus when clicked. Its size follows the
// element's CSS size (set it with CSS), at the display's pixel density.
//
// Frames are drawn with WebGL2 when the browser has it (the GPU renderer),
// else with the software renderer; `renderer: "software"` or "webgl2"
// chooses.

/** Special keys, as zigulee's Key codes. */
const KEYS = {
  Backspace: "\b",
  Tab: "\t",
  Enter: "\n",
  Escape: "\x1b",
  Delete: "\x7f",
  ArrowUp: "",
  ArrowDown: "",
  ArrowLeft: "",
  ArrowRight: "",
  Home: "",
  End: "",
  PageUp: "",
  PageDown: "",
};

/** zigulee's MouseCursor values, as CSS cursors (same order). */
const CURSORS = [
  "default", "none", "help", "pointer", "progress", "wait", "crosshair", "text", "move", "not-allowed",
  "grab", "grabbing", "col-resize", "row-resize", "ew-resize", "ns-resize", "nesw-resize", "nwse-resize",
];

/**
 * @param {{
 *   wasm: BufferSource | Response | Promise<Response> | WebAssembly.Module,
 *   canvas: HTMLCanvasElement,
 *   renderer?: "auto" | "webgl2" | "software",
 *   env?: { requestFrame?: (cb: () => void) => void, setTimeout?: (cb: () => void, ms: number) => any,
 *           clearTimeout?: (id: any) => void, now?: () => number, pixelRatio?: () => number,
 *           copy?: (text: string) => void, openUrl?: (url: string) => boolean,
 *           sensorTarget?: EventTarget, geolocation?: Geolocation },
 * }} options
 */
export async function start(options) {
  const { canvas } = options;
  const env = {
    requestFrame: (cb) => requestAnimationFrame(cb),
    setTimeout: (cb, ms) => setTimeout(cb, ms),
    clearTimeout: (id) => clearTimeout(id),
    now: () => performance.now(),
    pixelRatio: () => globalThis.devicePixelRatio || 1,
    copy: (text) => navigator.clipboard?.writeText(text),
    fetch: (url, init) => globalThis.fetch(url, init),
    // A new tab, unconnected to this page. With "noopener" the browser
    // gives no window back, so whether it opened (a pop-up blocker may
    // refuse it outside a click) cannot be told: taken.
    openUrl: (url) => {
      globalThis.open?.(url, "_blank", "noopener,noreferrer");
      return true;
    },
    ...options.env,
  };
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  /** The web views' iframes, by number. */
  const frames = new Map();
  // Readings and fixes show at the next frame.
  const soon = () => {
    if (!frameRequested) {
      frameRequested = true;
      env.requestFrame(frame);
    }
  };
  const sensors = motionSensors(env.sensorTarget ?? globalThis, (kind, x, y, z) => {
    instance.exports.zigulee_wasm_sensor(kind, x, y, z);
    soon();
  });
  const geolocation = env.geolocation ?? globalThis.navigator?.geolocation ?? null;
  let watch = null;
  /** @type {WebAssembly.Instance} */
  let instance;
  const memory = () => new Uint8Array(instance.exports.memory.buffer);
  /** @type {WebGL2RenderingContext | null} */
  let gl = null;
  const imports = {
    zigulee_gl: webGl(() => gl, () => instance),
    env: {
      zigulee_js_log(level, ptr, len) {
        const text = decoder.decode(memory().subarray(ptr, ptr + len));
        (level === 0 ? console.error : level === 1 ? console.warn : console.log)(text);
      },
      zigulee_js_copy(ptr, len) {
        env.copy(decoder.decode(memory().subarray(ptr, ptr + len)));
      },
      // Motion sensors (zigulee's sensors.Kind: 0 accelerometer, 1
      // gyroscope, 2 compass; the orientation zigulee works out itself).
      zigulee_js_sensor_available: (kind) => (sensors.available(kind) ? 1 : 0),
      zigulee_js_sensor_start: (kind) => sensors.start(kind),
      zigulee_js_sensor_stop: (kind) => sensors.stop(kind),
      // The position: geolocation's watch (the browser asks the user).
      zigulee_js_location_available: () => (geolocation ? 1 : 0),
      zigulee_js_location_start() {
        if (!geolocation || watch !== null) return;
        watch = geolocation.watchPosition(
          (p) => {
            const c = p.coords;
            const known = (v) => (v === null || v === undefined || Number.isNaN(v) ? NaN : v);
            instance.exports.zigulee_wasm_position(c.latitude, c.longitude, known(c.altitude), known(c.accuracy), known(c.speed), known(c.heading), p.timestamp);
            soon();
          },
          (e) => {
            instance.exports.zigulee_wasm_position_error(e.code);
            soon();
          },
          { enableHighAccuracy: true },
        );
      },
      zigulee_js_location_stop() {
        if (watch === null) return;
        geolocation.clearWatch(watch);
        watch = null;
      },
      zigulee_js_open_url(ptr, len) {
        return env.openUrl(decoder.decode(memory().subarray(ptr, ptr + len))) ? 1 : 0;
      },
      // Images from the network ("url\nName: value..."): the body read as
      // it comes (its progress told), then handed over with the status (0:
      // no answer, a server not allowing other sites' pages included).
      zigulee_js_fetch(id, ptr, len) {
        const [url, ...lines] = decoder.decode(memory().subarray(ptr, ptr + len)).split("\n");
        const headers = new Headers();
        for (const line of lines) {
          const colon = line.indexOf(":");
          if (colon > 0) try { headers.append(line.slice(0, colon).trim(), line.slice(colon + 1).trim()); } catch {}
        }
        const z = () => instance.exports;
        const done = (bytes, status) => {
          const n = bytes ? bytes.length : 0;
          const p = n > 0 ? z().zigulee_wasm_alloc(n) : 0;
          if (n > 0) memory().set(bytes, p);
          z().zigulee_wasm_fetched(id, p, n, status);
          if (n > 0) z().zigulee_wasm_free(p, n);
          schedule();
        };
        (async () => {
          let response;
          try {
            response = await env.fetch(url, { headers });
          } catch {
            return done(null, 0);
          }
          if (!response.ok) return done(null, response.status || 404);
          try {
            const total = Number(response.headers?.get("content-length")) || 0;
            const reader = response.body?.getReader?.();
            if (!reader) return done(new Uint8Array(await response.arrayBuffer()), response.status);
            const chunks = [];
            let received = 0;
            for (;;) {
              const { done: end, value } = await reader.read();
              if (end) break;
              chunks.push(value);
              received += value.length;
              z().zigulee_wasm_fetch_progress(id, received, total);
            }
            const bytes = new Uint8Array(received);
            let at = 0;
            for (const c of chunks) {
              bytes.set(c, at);
              at += c.length;
            }
            done(bytes, response.status);
          } catch {
            done(null, 0);
          }
        })();
      },
      // Web views: iframes placed over the canvas (in the page's
      // coordinates, so they scroll with it). Pages from other sites
      // cannot be read: no title, address, history or scripts there.
      zigulee_js_webview_create(view) {
        const doc = canvas.ownerDocument;
        const frame = doc?.createElement("iframe");
        if (!frame || !doc.body) return 0;
        frame.style.cssText = "position:absolute;border:0;display:none;z-index:1";
        frame.addEventListener("load", () => {
          if (!frames.has(view)) return;
          let title = "", url = "";
          try {
            title = frame.contentDocument?.title ?? "";
            url = frame.contentWindow.location.href;
            if (url === "about:srcdoc") url = "";
          } catch {}
          withString(title + "\n" + url, (p, l) => instance.exports.zigulee_wasm_webview_loaded(view, p, l, false));
        });
        doc.body.appendChild(frame);
        frames.set(view, frame);
        return 1;
      },
      zigulee_js_webview_destroy(view) {
        frames.get(view)?.remove();
        frames.delete(view);
      },
      zigulee_js_webview_place(view, x, y, w, h, visible) {
        const frame = frames.get(view);
        if (!frame) return;
        const r = canvas.getBoundingClientRect();
        Object.assign(frame.style, {
          left: `${r.left + (globalThis.scrollX ?? 0) + x}px`,
          top: `${r.top + (globalThis.scrollY ?? 0) + y}px`,
          width: `${w}px`,
          height: `${h}px`,
          display: visible ? "block" : "none",
        });
      },
      zigulee_js_webview_load(view, ptr, len, html) {
        const frame = frames.get(view);
        if (!frame) return;
        const text = decoder.decode(memory().subarray(ptr, ptr + len));
        if (html) {
          frame.srcdoc = text;
        } else {
          frame.removeAttribute("srcdoc");
          frame.src = text;
        }
      },
      zigulee_js_webview_command(view, command) {
        const frame = frames.get(view);
        if (!frame) return;
        try {
          if (command === 0) frame.contentWindow.history.back();
          else if (command === 1) frame.contentWindow.history.forward();
          else if (command === 2) frame.contentWindow.location.reload();
          else frame.contentWindow.stop();
        } catch {
          if (command === 2) frame.src = frame.src;
        }
      },
      zigulee_js_webview_run(view, ptr, len) {
        const frame = frames.get(view);
        const code = decoder.decode(memory().subarray(ptr, ptr + len));
        let text, failed = false;
        try {
          const result = frame.contentWindow.eval(code);
          text = typeof result === "string" ? result : (JSON.stringify(result) ?? "");
        } catch (e) {
          text = String(e);
          failed = true;
        }
        withString(text, (p, l) => instance.exports.zigulee_wasm_webview_result(view, p, l, failed));
      },
    },
  };
  let source = await options.wasm;
  if (source && typeof source.arrayBuffer === "function") source = await source.arrayBuffer();
  const result = await WebAssembly.instantiate(source, imports);
  instance = result.instance ?? result;
  const z = instance.exports;
  z.zigulee_main();

  // WebGL2 if wanted and available (a canvas has one kind of context).
  if (options.renderer !== "software") {
    gl = canvas.getContext("webgl2", { alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false });
    if (gl && !z.zigulee_wasm_use_gl()) throw new Error("zigulee: the WebGL2 shaders did not compile");
    if (!gl && options.renderer === "webgl2") throw new Error("zigulee: WebGL2 is not available");
  }
  const ctx = gl ? null : canvas.getContext("2d");
  let image = null;

  // ---- Frames: only when something needs drawing ----

  let frameRequested = false;
  let timer = null;
  function schedule() {
    if (timer !== null) {
      env.clearTimeout(timer);
      timer = null;
    }
    const wake = z.zigulee_wasm_next_wake(env.now());
    if (wake === 0) {
      if (!frameRequested) {
        frameRequested = true;
        env.requestFrame(frame);
      }
    } else if (wake > 0) {
      timer = env.setTimeout(() => {
        timer = null;
        frame();
      }, wake);
    }
  }
  function frame() {
    frameRequested = false;
    if (z.zigulee_wasm_frame(env.now()) && !gl) {
      const w = z.zigulee_wasm_pixel_width();
      const h = z.zigulee_wasm_pixel_height();
      const [x, y, dw, dh] = new Int32Array(z.memory.buffer, z.zigulee_wasm_dirty(), 4);
      const pixels = new Uint8ClampedArray(z.memory.buffer, z.zigulee_wasm_pixels(), w * h * 4);
      if (!image || image.width !== w || image.height !== h) image = new ImageData(w, h);
      // Copy the changed rows (the wasm memory may move: copy now).
      for (let row = y; row < y + dh; row++) {
        const start = (row * w + x) * 4;
        image.data.set(pixels.subarray(start, start + dw * 4), start);
      }
      ctx.putImageData(image, 0, 0, x, y, dw, dh);
    }
    updateCursor();
    schedule();
  }

  // ---- Size ----

  function resize() {
    const ratio = env.pixelRatio();
    const width = canvas.clientWidth || canvas.width;
    const height = canvas.clientHeight || canvas.height;
    z.zigulee_wasm_resize(width, height, ratio);
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    image = null;
    schedule();
  }
  if (typeof ResizeObserver !== "undefined") new ResizeObserver(resize).observe(canvas);
  resize();

  // ---- Input ----

  let lastCursor = -1;
  function updateCursor() {
    const c = z.zigulee_wasm_cursor();
    if (c !== lastCursor) {
      lastCursor = c;
      canvas.style.cursor = CURSORS[c] ?? "default";
    }
  }
  /** @param {{ shiftKey: boolean, ctrlKey: boolean, altKey: boolean, metaKey: boolean }} e */
  const mods = (e) => (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0);
  function position(e) {
    const r = canvas.getBoundingClientRect();
    return [e.clientX - r.left, e.clientY - r.top];
  }
  function pointer(kind, e, dx = 0, dy = 0) {
    const [x, y] = position(e);
    z.zigulee_wasm_pointer(kind, x, y, e.button ?? 0, mods(e), dx, dy);
    updateCursor();
    schedule();
  }
  function withString(text, fn) {
    const bytes = encoder.encode(text);
    const ptr = z.zigulee_wasm_alloc(bytes.length);
    memory().set(bytes, ptr);
    fn(ptr, bytes.length);
    z.zigulee_wasm_free(ptr, bytes.length);
  }
  function key(pressed, text, e) {
    withString(text, (ptr, len) => z.zigulee_wasm_key(pressed, ptr, len, mods(e), !!e.repeat));
    schedule();
  }

  canvas.tabIndex = 0;
  // Fingers are zigulee's (pinches, swipes), not the page's to pan or zoom.
  canvas.style.touchAction = "none";
  function touch(phase, e) {
    const [x, y] = position(e);
    z.zigulee_wasm_touch(e.pointerId, phase, x, y);
    updateCursor();
    schedule();
  }
  canvas.addEventListener("pointerdown", (e) => {
    keyboard.focus();
    canvas.setPointerCapture?.(e.pointerId);
    if (e.pointerType === "touch") touch(0, e);
    else pointer(0, e);
  });
  canvas.addEventListener("pointerup", (e) => (e.pointerType === "touch" ? touch(2, e) : pointer(1, e)));
  canvas.addEventListener("pointermove", (e) => (e.pointerType === "touch" ? touch(1, e) : pointer(2, e)));
  canvas.addEventListener("pointercancel", (e) => {
    if (e.pointerType === "touch") touch(3, e);
  });
  canvas.addEventListener("pointerleave", (e) => {
    if (e.pointerType !== "touch") pointer(4, e);
  });
  // Drops from the page or the desktop: text, or files (their names: a
  // page sees no paths).
  canvas.addEventListener("dragover", (e) => {
    const types = [...(e.dataTransfer?.types ?? [])];
    const kinds = (types.includes("Files") ? 1 : 0) | (types.includes("text/plain") ? 2 : 0);
    const [x, y] = position(e);
    if (kinds && z.zigulee_wasm_drag(kinds, x, y)) {
      e.preventDefault();
      e.dataTransfer.dropEffect = "copy";
    }
    schedule();
  });
  canvas.addEventListener("dragleave", () => {
    z.zigulee_wasm_drag_leave();
    schedule();
  });
  canvas.addEventListener("drop", (e) => {
    e.preventDefault();
    const [x, y] = position(e);
    const files = [...(e.dataTransfer?.files ?? [])].map((f) => f.name);
    const text = e.dataTransfer?.getData("text/plain");
    if (files.length) withString(files.join("\n"), (ptr, len) => z.zigulee_wasm_drop(0, ptr, len, x, y));
    else if (text) withString(text, (ptr, len) => z.zigulee_wasm_drop(1, ptr, len, x, y));
    else z.zigulee_wasm_drag_leave();
    schedule();
  });
  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    // Scrolling down reveals content below: negative y in zigulee.
    const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? canvas.clientHeight : 1;
    pointer(3, e, -e.deltaX * unit, -e.deltaY * unit);
  }, { passive: false });

  // ---- Keyboard ----
  //
  // Input methods (composing Chinese, Japanese, accents...) only work in
  // editable elements: a hidden textarea takes the keyboard, kept at the
  // text caret so the candidate window shows there. Special keys and
  // shortcuts go to zigulee from keydown; text comes from input events, text
  // being composed from composition events. Without a document (tests), the
  // canvas takes the keys itself.
  const doc = canvas.ownerDocument ?? globalThis.document;
  const textarea = doc?.createElement?.("textarea");
  const keyboard = textarea ?? canvas;
  if (textarea) {
    Object.assign(textarea.style, {
      position: "absolute", opacity: "0", width: "1px", height: "1em", padding: "0", border: "0",
      resize: "none", overflow: "hidden", pointerEvents: "none", left: "0px", top: "0px",
    });
    textarea.setAttribute?.("autocomplete", "off");
    textarea.setAttribute?.("autocapitalize", "off");
    textarea.setAttribute?.("aria-hidden", "true");
    (canvas.parentNode ?? doc.body)?.appendChild(textarea);
  }
  let composing = false;
  function placeTextarea() {
    if (!textarea) return;
    const ptr = z.zigulee_wasm_ime_rect();
    if (!ptr) return;
    const [x, y, , h] = new Float32Array(z.memory.buffer, ptr, 4);
    textarea.style.left = canvas.offsetLeft + x + "px";
    textarea.style.top = canvas.offsetTop + y + "px";
    textarea.style.height = h + "px";
  }
  function preedit(text) {
    withString(text, (ptr, len) => z.zigulee_wasm_preedit(ptr, len, len));
    schedule();
  }
  keyboard.addEventListener("keydown", (e) => {
    if (composing || e.isComposing) return;
    const special = KEYS[e.key];
    const shortcut = (e.ctrlKey || e.metaKey) && e.key.length === 1;
    // Pasting comes as a paste (or input) event, with the text.
    if (shortcut && e.key.toLowerCase() === "v") return;
    if (special !== undefined) {
      key(true, special, e);
    } else if (shortcut) {
      key(true, e.key.toLowerCase(), e);
    } else if (!textarea && [...e.key].length === 1) {
      key(true, e.key, e); // no input events without the textarea
    } else return;
    e.preventDefault();
    placeTextarea();
  });
  keyboard.addEventListener("keyup", (e) => {
    const special = KEYS[e.key];
    if (special !== undefined) key(false, special, e);
  });
  function typed(text) {
    key(true, text, noMods);
    key(false, text, noMods);
    placeTextarea();
  }
  const noMods = { shiftKey: false, ctrlKey: false, altKey: false, metaKey: false };
  keyboard.addEventListener("input", (e) => {
    if (composing || e.isComposing) return;
    if (e.data) typed(e.data);
    if (textarea) textarea.value = "";
  });
  keyboard.addEventListener("compositionstart", () => {
    composing = true;
    placeTextarea();
  });
  keyboard.addEventListener("compositionupdate", (e) => preedit(e.data ?? ""));
  keyboard.addEventListener("compositionend", (e) => {
    composing = false;
    preedit("");
    if (e.data) typed(e.data);
    if (textarea) textarea.value = "";
  });
  keyboard.addEventListener("paste", (e) => {
    const text = e.clipboardData?.getData("text/plain");
    if (text) {
      typed(text);
      e.preventDefault();
    }
  });

  schedule();
  return { instance, frame, resize, renderer: gl ? "webgl2" : "software" };
}

/**
 * Motion sensors from the page's events: devicemotion for the
 * accelerometer and the gyroscope, deviceorientation for the compass.
 * Readings go to `send(kind, x, y, z)`. iOS asks the user first, which
 * must follow a tap: asked at the next one.
 * @param {EventTarget} target
 * @param {(kind: number, x: number, y: number, z: number) => void} send
 */
function motionSensors(target, send) {
  const on = [false, false, false];
  const listening = { motion: false, orientation: false };
  const motion = (e) => {
    const a = e.accelerationIncludingGravity;
    if (on[0] && a && a.x !== null) send(0, a.x, a.y, a.z);
    // Degrees a second about z (alpha), x (beta) and y (gamma).
    const r = e.rotationRate;
    if (on[1] && r && r.alpha !== null) send(1, r.beta, r.gamma, r.alpha);
  };
  const heading = (e) => {
    if (!on[2]) return;
    if (typeof e.webkitCompassHeading === "number") {
      // Safari: the heading, and its accuracy in degrees (-1: none).
      const accuracy = e.webkitCompassAccuracy ?? -1;
      send(2, e.webkitCompassHeading, accuracy >= 0 ? Math.max(0, 1 - accuracy / 90) : 0, 0);
    } else if (e.absolute && e.alpha !== null) {
      // Alpha turns counterclockwise from north.
      send(2, 360 - e.alpha, 1, 0);
    }
  };
  const orientationEvent = "ondeviceorientationabsolute" in target ? "deviceorientationabsolute" : "deviceorientation";
  let asked = false;
  function ask() {
    if (asked) return;
    asked = true;
    const classes = [globalThis.DeviceMotionEvent, globalThis.DeviceOrientationEvent].filter((c) => typeof c?.requestPermission === "function");
    if (classes.length === 0) return;
    const request = () => {
      target.removeEventListener("click", request);
      target.removeEventListener("touchend", request);
      for (const c of classes) c.requestPermission().catch(() => {});
    };
    target.addEventListener("click", request);
    target.addEventListener("touchend", request);
  }
  function listen(name, handler, want, key) {
    if (want === listening[key]) return;
    listening[key] = want;
    if (want) target.addEventListener(name, handler);
    else target.removeEventListener(name, handler);
  }
  function update() {
    listen("devicemotion", motion, on[0] || on[1], "motion");
    listen(orientationEvent, heading, on[2], "orientation");
  }
  return {
    available: (kind) =>
      kind <= 1 ? typeof globalThis.DeviceMotionEvent !== "undefined" : kind === 2 && typeof globalThis.DeviceOrientationEvent !== "undefined",
    start(kind) {
      if (kind > 2) return;
      on[kind] = true;
      ask();
      update();
    },
    stop(kind) {
      if (kind > 2) return;
      on[kind] = false;
      update();
    },
  };
}

/**
 * The OpenGL ES 3.0 functions the GPU renderer calls (src/renderers/gpu/gl.zig),
 * on a WebGL2 context. WebGL objects are kept in a table: the wasm side sees
 * their indices (0 is none).
 * @param {() => WebGL2RenderingContext} context
 * @param {() => WebAssembly.Instance} instance
 */
export function webGl(context, instance) {
  const objects = [null];
  const add = (o) => (o ? objects.push(o) - 1 : 0);
  const get = (i) => objects[i] ?? null;
  const memory = () => instance().exports.memory.buffer;
  const bytes = (ptr, len) => new Uint8Array(memory(), ptr, len);
  const i32 = (ptr, n = 1) => new Int32Array(memory(), ptr, n);
  const u32 = (ptr, n = 1) => new Uint32Array(memory(), ptr, n);
  const f32 = (ptr, n = 1) => new Float32Array(memory(), ptr, n);
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const cstring = (ptr) => {
    const m = new Uint8Array(memory());
    let end = ptr;
    while (m[end] !== 0) end++;
    return decoder.decode(m.subarray(ptr, end));
  };
  const strings = new Map(); // glGetString results, kept in wasm memory
  const writeLog = (log, max, lenPtr, buf) => {
    const b = encoder.encode(log ?? "").subarray(0, Math.max(0, max - 1));
    bytes(buf, b.length + 1).set([...b, 0]);
    if (lenPtr) i32(lenPtr)[0] = b.length;
  };
  const gen = (n, ptr, make) => {
    const out = u32(ptr, n);
    for (let k = 0; k < n; k++) out[k] = add(make());
  };
  const del = (n, ptr, destroy) => {
    for (const id of u32(ptr, n)) {
      destroy(get(id));
      objects[id] = null;
    }
  };
  // Bytes per pixel of the formats used (RED, RGBA).
  const pixelBytes = (format) => (format === 0x1903 ? 1 : 4);
  const COMPILE_STATUS = 0x8b81, LINK_STATUS = 0x8b82, INFO_LOG_LENGTH = 0x8b84;
  return {
    glGetString(name) {
      if (!strings.has(name)) {
        const text = encoder.encode((name === 0x1f02 ? "OpenGL ES 3.0 WebGL2" : "zigulee WebGL2") + "\0");
        const ptr = instance().exports.zigulee_wasm_alloc(text.length);
        bytes(ptr, text.length).set(text);
        strings.set(name, ptr);
      }
      return strings.get(name);
    },
    glGetError: () => context().getError(),
    glCreateShader: (type) => add(context().createShader(type)),
    glShaderSource(shader, count, sources, lengths) {
      const ptrs = u32(sources, count);
      const lens = lengths ? i32(lengths, count) : null;
      let text = "";
      for (let k = 0; k < count; k++) text += lens ? decoder.decode(bytes(ptrs[k], lens[k])) : cstring(ptrs[k]);
      context().shaderSource(get(shader), text);
    },
    glCompileShader: (shader) => context().compileShader(get(shader)),
    glGetShaderiv(shader, pname, out) {
      const gl = context();
      i32(out)[0] = pname === INFO_LOG_LENGTH ? (gl.getShaderInfoLog(get(shader)) ?? "").length + 1 : Number(gl.getShaderParameter(get(shader), pname));
    },
    glGetShaderInfoLog: (shader, max, len, buf) => writeLog(context().getShaderInfoLog(get(shader)), max, len, buf),
    glDeleteShader(shader) {
      context().deleteShader(get(shader));
      objects[shader] = null;
    },
    glCreateProgram: () => add(context().createProgram()),
    glAttachShader: (program, shader) => context().attachShader(get(program), get(shader)),
    glBindAttribLocation: (program, index, name) => context().bindAttribLocation(get(program), index, cstring(name)),
    glLinkProgram: (program) => context().linkProgram(get(program)),
    glGetProgramiv(program, pname, out) {
      const gl = context();
      i32(out)[0] = pname === INFO_LOG_LENGTH ? (gl.getProgramInfoLog(get(program)) ?? "").length + 1 : Number(gl.getProgramParameter(get(program), pname));
    },
    glGetProgramInfoLog: (program, max, len, buf) => writeLog(context().getProgramInfoLog(get(program)), max, len, buf),
    glDeleteProgram(program) {
      context().deleteProgram(get(program));
      objects[program] = null;
    },
    glUseProgram: (program) => context().useProgram(get(program)),
    glGetUniformLocation(program, name) {
      const loc = context().getUniformLocation(get(program), cstring(name));
      return loc ? add(loc) : -1;
    },
    glUniform1i: (loc, v) => context().uniform1i(loc < 0 ? null : get(loc), v),
    glUniform2f: (loc, x, y) => context().uniform2f(loc < 0 ? null : get(loc), x, y),
    glGenVertexArrays: (n, ptr) => gen(n, ptr, () => context().createVertexArray()),
    glDeleteVertexArrays: (n, ptr) => del(n, ptr, (o) => context().deleteVertexArray(o)),
    glBindVertexArray: (vao) => context().bindVertexArray(get(vao)),
    glGenBuffers: (n, ptr) => gen(n, ptr, () => context().createBuffer()),
    glDeleteBuffers: (n, ptr) => del(n, ptr, (o) => context().deleteBuffer(o)),
    glBindBuffer: (target, buffer) => context().bindBuffer(target, get(buffer)),
    glBufferData(target, size, data, usage) {
      if (data) context().bufferData(target, bytes(data, size), usage);
      else context().bufferData(target, size, usage);
    },
    glEnableVertexAttribArray: (index) => context().enableVertexAttribArray(index),
    glVertexAttribPointer: (index, size, type, normalized, stride, offset) => context().vertexAttribPointer(index, size, type, !!normalized, stride, offset),
    glGenTextures: (n, ptr) => gen(n, ptr, () => context().createTexture()),
    glDeleteTextures: (n, ptr) => del(n, ptr, (o) => context().deleteTexture(o)),
    glBindTexture: (target, texture) => context().bindTexture(target, get(texture)),
    glActiveTexture: (unit) => context().activeTexture(unit),
    glTexImage2D(target, level, internal, w, h, border, format, type, data) {
      context().texImage2D(target, level, internal, w, h, border, format, type, data ? bytes(data, w * h * pixelBytes(format)) : null);
    },
    glTexSubImage2D(target, level, x, y, w, h, format, type, data) {
      context().texSubImage2D(target, level, x, y, w, h, format, type, bytes(data, w * h * pixelBytes(format)));
    },
    glTexParameteri: (target, pname, value) => context().texParameteri(target, pname, value),
    glPixelStorei: (pname, value) => context().pixelStorei(pname, value),
    glViewport: (x, y, w, h) => context().viewport(x, y, w, h),
    glClearColor: (r, g, b, a) => context().clearColor(r, g, b, a),
    glClear: (mask) => context().clear(mask),
    glEnable: (cap) => context().enable(cap),
    glDisable: (cap) => context().disable(cap),
    glBlendFunc: (src, dst) => context().blendFunc(src, dst),
    glDrawElements: (mode, count, type, offset) => context().drawElements(mode, count, type, offset),
    glReadPixels: (x, y, w, h, format, type, data) => context().readPixels(x, y, w, h, format, type, bytes(data, w * h * pixelBytes(format))),
    glBindFramebuffer: (target, fb) => context().bindFramebuffer(target, get(fb)),
    glGenFramebuffers: (n, ptr) => gen(n, ptr, () => context().createFramebuffer()),
    glDeleteFramebuffers: (n, ptr) => del(n, ptr, (o) => context().deleteFramebuffer(o)),
    glFramebufferTexture2D: (target, attachment, textarget, texture, level) => context().framebufferTexture2D(target, attachment, textarget, get(texture), level),
    glCheckFramebufferStatus: (target) => context().checkFramebufferStatus(target),
    glBlitFramebuffer: (x0, y0, x1, y1, dx0, dy0, dx1, dy1, mask, filter) => context().blitFramebuffer(x0, y0, x1, y1, dx0, dy0, dx1, dy1, mask, filter),
    glScissor: (x, y, w, h) => context().scissor(x, y, w, h),
    // For 3D scenes.
    glUniform4fv: (loc, count, ptr) => context().uniform4fv(loc < 0 ? null : get(loc), f32(ptr, count * 4)),
    glUniformMatrix4fv: (loc, count, transpose, ptr) => context().uniformMatrix4fv(loc < 0 ? null : get(loc), !!transpose, f32(ptr, count * 16)),
    glFrontFace: (mode) => context().frontFace(mode),
    glGenRenderbuffers: (n, ptr) => gen(n, ptr, () => context().createRenderbuffer()),
    glDeleteRenderbuffers: (n, ptr) => del(n, ptr, (o) => context().deleteRenderbuffer(o)),
    glBindRenderbuffer: (target, rb) => context().bindRenderbuffer(target, get(rb)),
    glRenderbufferStorageMultisample: (target, samples, format, w, h) => context().renderbufferStorageMultisample(target, samples, format, w, h),
    glFramebufferRenderbuffer: (target, attachment, rbtarget, rb) => context().framebufferRenderbuffer(target, attachment, rbtarget, get(rb)),
  };
}
