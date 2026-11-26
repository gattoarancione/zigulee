// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

// Draws the web gallery with WebGL2 and with the software renderer in a
// headless Chromium-based browser, and checks they give the same pixels:
// `zig build test-webgl` (set ZIGULEE_BROWSER to the browser's executable if
// it is not found). Usage: node webgl.mjs gallery.wasm zigulee.js
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [wasmPath, gluePath] = process.argv.slice(2);
const browsers = [
  process.env.ZIGULEE_BROWSER,
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
  "/usr/bin/google-chrome",
].filter(Boolean);
const browser = browsers.find((b) => existsSync(b));
if (!browser) {
  console.error("no Chromium-based browser found: set ZIGULEE_BROWSER");
  process.exit(1);
}

const dir = mkdtempSync(join(tmpdir(), "zigulee-webgl-"));
const width = 460, height = 640;
// The page: two copies of the gallery, compared once both have drawn.
// Everything inline (no server needed).
const page = `<!doctype html><html><head><meta charset="utf-8">
<style>body{margin:0} canvas{display:block;width:${width}px;height:${height}px;float:left}</style></head>
<body><canvas id="a"></canvas><canvas id="b"></canvas><pre id="out">running</pre>
<script type="module">
const glue = ${JSON.stringify(readFileSync(gluePath, "utf8"))};
const { start } = await import(URL.createObjectURL(new Blob([glue], { type: "text/javascript" })));
const wasm = Uint8Array.from(atob("${readFileSync(wasmPath).toString("base64")}"), (c) => c.charCodeAt(0));
const out = document.getElementById("out");
try {
  // A frozen clock: animations (the spinner) look the same in both.
  const env = { pixelRatio: () => 1, now: () => 1000, requestFrame: () => {} , setTimeout: () => 0, clearTimeout: () => {} };
  const a = await start({ wasm, canvas: document.getElementById("a"), renderer: "webgl2", env });
  const b = await start({ wasm, canvas: document.getElementById("b"), renderer: "software", env });
  b.resize(); b.frame();
  a.resize(); a.frame();
  // Read back before the WebGL frame is composited.
  const copy = document.createElement("canvas");
  copy.width = ${width}; copy.height = ${height};
  const c2 = copy.getContext("2d");
  c2.drawImage(document.getElementById("a"), 0, 0);
  const ga = c2.getImageData(0, 0, ${width}, ${height}).data;
  const gb = document.getElementById("b").getContext("2d").getImageData(0, 0, ${width}, ${height}).data;
  let off = 0, worst = 0, ink = 0;
  for (let i = 0; i < ga.length; i += 4) {
    let d = 0;
    for (let k = 0; k < 4; k++) d = Math.max(d, Math.abs(ga[i + k] - gb[i + k]));
    worst = Math.max(worst, d);
    if (d > 3) off++;
    if (ga[i] < 128) ink++;
  }
  out.textContent = "RESULT " + JSON.stringify({ renderer: a.renderer, off, worst, ink });
} catch (e) { out.textContent = "ERROR " + e.stack; }
</script></body></html>`;
writeFileSync(join(dir, "test.html"), page);

const port = 9300 + Math.floor(Math.random() * 600);
const child = spawn(browser, [
  "--headless=new", `--user-data-dir=${join(dir, "profile")}`, `--remote-debugging-port=${port}`,
  "--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--no-first-run",
  "file://" + join(dir, "test.html"),
], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let text = "";
try {
  let target;
  for (let i = 0; i < 150 && !target; i++) {
    await sleep(200);
    try { target = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find((t) => t.type === "page"); } catch {}
  }
  if (!target) throw new Error("the browser did not start");
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r) => (ws.onopen = r));
  let id = 0;
  const pending = new Map();
  ws.onmessage = (m) => { const d = JSON.parse(m.data); pending.get(d.id)?.(d.result); };
  const call = (method, params = {}) => new Promise((r) => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
  for (let i = 0; i < 150; i++) {
    await sleep(200);
    const r = await call("Runtime.evaluate", { expression: "document.getElementById('out')?.textContent" });
    text = r?.result?.value ?? "";
    if (text.startsWith("RESULT") || text.startsWith("ERROR")) break;
  }
  await call("Browser.close").catch(() => {});
} finally {
  child.kill();
  await sleep(300);
  rmSync(dir, { recursive: true, force: true });
}
if (!text.startsWith("RESULT")) {
  console.error("webgl: " + (text || "no result"));
  process.exit(1);
}
const r = JSON.parse(text.slice(7));
if (r.renderer !== "webgl2" || r.off > 0 || r.ink < 1000) {
  console.error("webgl: " + JSON.stringify(r));
  process.exit(1);
}
console.log(`webgl: same pixels as the software renderer (within ${r.worst})`);
