// Copyright (c) 2026 Claudio Russo
// SPDX-License-Identifier: MIT

// The live preview webview: draws frames from zigulee-lsp on a canvas and
// sends input back (through the extension).
// @ts-check
(function () {
  const vscode = acquireVsCodeApi();
  const canvas = /** @type {HTMLCanvasElement} */ (document.getElementById("canvas"));
  const ctx = canvas.getContext("2d");
  const errors = document.getElementById("errors");
  const components = /** @type {HTMLSelectElement} */ (document.getElementById("components"));
  const zoomSelect = /** @type {HTMLSelectElement} */ (document.getElementById("zoom"));
  const inspectButton = document.getElementById("inspect");
  const selectedLabel = document.getElementById("selected");
  const propsBody = document.getElementById("props");
  const propError = document.getElementById("prop-error");

  let zoom = 1;
  let logical = { width: 0, height: 0 };
  let inspecting = false;
  let tickTimer = undefined;
  // Frames are decoded asynchronously but drawn in order.
  let drawing = Promise.resolve();

  function scale() {
    return (window.devicePixelRatio || 1) * zoom;
  }

  /** @param {any} input */
  function send(input) {
    vscode.postMessage({ type: "input", input });
  }

  function point(e) {
    const r = canvas.getBoundingClientRect();
    return { x: (e.clientX - r.left) / zoom, y: (e.clientY - r.top) / zoom };
  }

  function mods(e) {
    return { shift: e.shiftKey, control: e.ctrlKey, alt: e.altKey, meta: e.metaKey };
  }

  // ---- Frames ----

  /** @param {any} f */
  function onFrame(f) {
    errors.textContent = f.errors || "";
    if (!inspecting) canvas.style.cursor = f.cursor || "default";
    errors.style.display = f.errors ? "block" : "none";
    if (f.width > 0 && (f.width !== logical.width || f.height !== logical.height || canvas.width !== Math.ceil(f.width * f.scale))) {
      logical = { width: f.width, height: f.height };
      canvas.width = Math.ceil(f.width * f.scale);
      canvas.height = Math.ceil(f.height * f.scale);
      canvas.style.width = f.width * zoom + "px";
      canvas.style.height = f.height * zoom + "px";
    }
    for (const patch of f.patches || []) {
      drawing = drawing.then(async () => {
        const bytes = Uint8Array.from(atob(patch.png), (c) => c.charCodeAt(0));
        const bitmap = await createImageBitmap(new Blob([bytes], { type: "image/png" }));
        ctx.drawImage(bitmap, patch.x, patch.y);
        bitmap.close();
      });
    }
    clearTimeout(tickTimer);
    if (f.wakeMs !== null && f.wakeMs !== undefined) {
      tickTimer = setTimeout(() => send({ type: "tick" }), Math.max(f.wakeMs, 8));
    }
  }

  // ---- Selection and properties ----

  /** @param {any} s */
  function onSelection(s) {
    propError.textContent = s.error || "";
    selectedLabel.textContent = s.selected ? s.selected.label : "Alt+click an element to inspect it";
    propsBody.innerHTML = "";
    for (const p of s.properties || []) {
      const row = document.createElement("tr");
      const name = document.createElement("td");
      name.textContent = p.name;
      name.title = p.type;
      const value = document.createElement("td");
      const input = document.createElement("input");
      input.value = p.value;
      input.disabled = !p.editable;
      input.title = p.editable ? "Enter: apply live · Shift+Enter: apply and write it in the file" : p.type;
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") vscode.postMessage({ type: "setProperty", name: p.name, value: input.value, persist: e.shiftKey });
        e.stopPropagation();
      });
      value.appendChild(input);
      row.append(name, value);
      propsBody.appendChild(row);
    }
  }

  // ---- Input ----

  canvas.addEventListener("mousedown", (e) => {
    canvas.focus();
    e.preventDefault();
    const p = point(e);
    if (inspecting || e.altKey) {
      vscode.postMessage({ type: "inspect", x: p.x, y: p.y });
      return;
    }
    send({ type: "press", x: p.x, y: p.y, button: e.button, ...mods(e) });
  });
  canvas.addEventListener("mouseup", (e) => {
    if (inspecting || e.altKey) return;
    const p = point(e);
    send({ type: "release", x: p.x, y: p.y, button: e.button });
  });
  canvas.addEventListener("mousemove", (e) => {
    const p = point(e);
    send({ type: "move", x: p.x, y: p.y });
  });
  canvas.addEventListener("mouseleave", () => send({ type: "exit" }));
  canvas.addEventListener(
    "wheel",
    (e) => {
      e.preventDefault();
      const p = point(e);
      // Scrolling up or left reveals content above or to the left.
      send({ type: "wheel", x: p.x, y: p.y, dx: -e.deltaX, dy: -e.deltaY });
    },
    { passive: false },
  );

  const keys = {
    ArrowLeft: "",
    ArrowRight: "",
    ArrowUp: "",
    ArrowDown: "",
    Home: "",
    End: "",
    PageUp: "",
    PageDown: "",
    Backspace: "\b",
    Tab: "\t",
    Enter: "\n",
    Escape: "\u001b",
    Delete: "\u007f",
  };

  function keyText(e) {
    if (keys[e.key]) return keys[e.key];
    if ([...e.key].length === 1) return e.ctrlKey || e.metaKey ? e.key.toLowerCase() : e.key;
    return null;
  }

  for (const kind of ["keydown", "keyup"]) {
    canvas.addEventListener(kind, (e) => {
      const text = keyText(e);
      if (text === null) return;
      e.preventDefault();
      send({ type: "key", text, released: kind === "keyup", ...mods(e) });
    });
  }

  // ---- Toolbar ----

  inspectButton.addEventListener("click", () => {
    inspecting = !inspecting;
    inspectButton.classList.toggle("active", inspecting);
    canvas.style.cursor = inspecting ? "crosshair" : "default";
  });
  zoomSelect.addEventListener("change", () => {
    zoom = Number(zoomSelect.value);
    canvas.style.width = logical.width * zoom + "px";
    canvas.style.height = logical.height * zoom + "px";
    send({ type: "scale", scale: scale() });
  });
  components.addEventListener("change", () => vscode.postMessage({ type: "component", name: components.value }));

  window.addEventListener("message", (event) => {
    const msg = event.data;
    if (msg.type === "frame") onFrame(msg.frame);
    else if (msg.type === "selection") onSelection(msg.selection);
    else if (msg.type === "started") {
      components.innerHTML = "";
      for (const name of msg.components || []) {
        const option = document.createElement("option");
        option.value = option.textContent = name;
        option.selected = name === msg.component;
        components.appendChild(option);
      }
      components.style.display = (msg.components || []).length > 1 ? "inline-block" : "none";
    }
  });

  vscode.postMessage({ type: "ready", scale: scale() });
})();
