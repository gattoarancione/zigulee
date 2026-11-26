// Copyright (c) 2026 Claudio Russo (gattoarancione)
// SPDX-License-Identifier: MIT

// Starts zigulee-lsp for .zge files, and shows its live preview.

const fs = require("fs");
const os = require("os");
const path = require("path");
const vscode = require("vscode");
const { LanguageClient } = require("vscode-languageclient/node");

let client;
let preview; // { panel, uri, scale, component }

function activate(context) {
  startClient(context);
  context.subscriptions.push(
    vscode.commands.registerCommand("zigulee.showPreview", () => showPreview(context)),
    vscode.window.onDidChangeTextEditorSelection(onSelectionChanged),
    vscode.workspace.onDidChangeConfiguration(async (e) => {
      if (!e.affectsConfiguration("zigulee")) return;
      if (client) await client.stop();
      startClient(context);
    }),
    { dispose: () => client && client.stop() },
  );
}

/** Where zigulee-lsp is: the setting, the copy bundled by install.sh, a
 * `zig-out/bin` in an open folder, or the PATH. Returns the command and
 * the places that were tried. */
function findServer(context) {
  const exe = process.platform === "win32" ? "zigulee-lsp.exe" : "zigulee-lsp";
  const configured = (vscode.workspace.getConfiguration("zigulee").get("serverPath") || "").trim();
  if (configured) return { command: configured.replace(/^~(?=$|[\\/])/, os.homedir()), tried: [configured] };
  const candidates = [path.join(context.extensionPath, "bin", exe)];
  for (const folder of vscode.workspace.workspaceFolders || []) {
    candidates.push(path.join(folder.uri.fsPath, "zig-out", "bin", exe));
  }
  for (const candidate of candidates) {
    if (!fs.existsSync(candidate)) continue;
    // Packaged files may lose their executable bit.
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
    } catch {
      try {
        fs.chmodSync(candidate, 0o755);
      } catch {}
    }
    return { command: candidate, tried: candidates };
  }
  return { command: exe, tried: [...candidates, `${exe} on the PATH`] };
}

function startClient(context) {
  const config = vscode.workspace.getConfiguration("zigulee");
  const { command, tried } = findServer(context);
  client = new LanguageClient(
    "zigulee",
    "zigulee",
    { run: { command }, debug: { command } },
    {
      documentSelector: [{ scheme: "file", language: "zge" }],
      initializationOptions: { style: config.get("style") },
    },
  );
  client.start().then(
    () => {
      client.onNotification("zigulee/previewFrame", (frame) => post({ type: "frame", frame }));
      client.onNotification("zigulee/previewSelection", (selection) => post({ type: "selection", selection }));
      // A restarted server: start the preview again.
      if (preview) startPreview();
    },
    async (err) => {
      const choice = await vscode.window.showErrorMessage(
        `zigulee: could not start the language server (${err.message}). Looked for: ${tried.join(", ")}. ` +
          "Run editors/vscode/install.sh (it bundles the server), or set zigulee.serverPath to the full path of zig-out/bin/zigulee-lsp.",
        "Open Settings",
      );
      if (choice === "Open Settings") vscode.commands.executeCommand("workbench.action.openSettings", "zigulee.serverPath");
    },
  );
}

function post(msg) {
  if (preview) preview.panel.webview.postMessage(msg);
}

function showPreview(context) {
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document.languageId !== "zge") {
    vscode.window.showInformationMessage("zigulee: open a .zge file to preview it.");
    return;
  }
  const uri = editor.document.uri.toString();
  if (preview) {
    preview.uri = uri;
    preview.component = null;
    preview.panel.reveal(vscode.ViewColumn.Beside, true);
    startPreview();
    return;
  }
  const panel = vscode.window.createWebviewPanel("ziguleePreview", "zigulee Preview", { viewColumn: vscode.ViewColumn.Beside, preserveFocus: true }, {
    enableScripts: true,
    retainContextWhenHidden: true,
    localResourceRoots: [vscode.Uri.joinPath(context.extensionUri, "media")],
  });
  preview = { panel, uri, scale: 1, component: null };
  panel.webview.html = previewHtml(panel.webview, context.extensionUri);
  panel.onDidDispose(() => {
    preview = undefined;
    if (client) client.sendNotification("zigulee/previewClose", {});
  });
  panel.webview.onDidReceiveMessage((msg) => onWebviewMessage(msg));
}

async function startPreview() {
  if (!preview || !client) return;
  const result = await client.sendRequest("zigulee/preview", { uri: preview.uri, component: preview.component, scale: preview.scale });
  if (!preview || !result) return;
  preview.panel.title = `Preview: ${result.component || vscode.Uri.parse(preview.uri).path.split("/").pop()}`;
  post({ type: "started", components: result.components, component: result.component });
}

async function onWebviewMessage(msg) {
  if (!client) return;
  switch (msg.type) {
    case "ready":
      preview.scale = msg.scale;
      await startPreview();
      break;
    case "input":
      client.sendNotification("zigulee/previewInput", msg.input);
      break;
    case "component":
      preview.component = msg.name;
      await startPreview();
      break;
    case "inspect": {
      const result = await client.sendRequest("zigulee/previewInspect", { x: msg.x, y: msg.y });
      if (!result) return;
      post({ type: "selection", selection: result });
      if (result.selected && result.selected.uri) await reveal(result.selected);
      break;
    }
    case "setProperty": {
      const result = await client.sendRequest("zigulee/previewSetProperty", { name: msg.name, value: msg.value });
      if (!result) return;
      post({ type: "selection", selection: result });
      // Shift+Enter: write it in the file too (undoable in the editor).
      if (msg.persist && result.edit) {
        const edit = await client.protocol2CodeConverter.asWorkspaceEdit(result.edit);
        if (!(await vscode.workspace.applyEdit(edit))) vscode.window.showWarningMessage("zigulee: could not write the value in the file.");
      } else if (msg.persist && !result.error) {
        vscode.window.showInformationMessage("zigulee: this element is not in a file you can edit (a standard widget).");
      }
      break;
    }
  }
}

/** Shows an element's source in the editor next to the preview. */
async function reveal(element) {
  const doc = await vscode.workspace.openTextDocument(vscode.Uri.parse(element.uri));
  const start = new vscode.Position(element.range.start.line, element.range.start.character);
  const editor = await vscode.window.showTextDocument(doc, { viewColumn: vscode.ViewColumn.One, preserveFocus: true });
  revealing = true;
  editor.selection = new vscode.Selection(start, start);
  editor.revealRange(new vscode.Range(start, start), vscode.TextEditorRevealType.InCenterIfOutsideViewport);
}

let revealing = false;
let selectTimer;

/** The cursor in a .zge editor highlights its element in the preview. */
function onSelectionChanged(e) {
  if (!preview || !client || e.textEditor.document.languageId !== "zge") return;
  if (revealing) {
    revealing = false;
    return;
  }
  clearTimeout(selectTimer);
  const uri = e.textEditor.document.uri.toString();
  const pos = e.selections[0].active;
  selectTimer = setTimeout(() => {
    client.sendNotification("zigulee/previewSelect", { uri, position: { line: pos.line, character: pos.character } });
  }, 150);
}

function previewHtml(webview, extensionUri) {
  const script = webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, "media", "preview.js"));
  const nonce = Array.from({ length: 32 }, () => Math.floor(Math.random() * 36).toString(36)).join("");
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  body { margin: 0; padding: 0; font-family: var(--vscode-font-family); font-size: var(--vscode-font-size); color: var(--vscode-foreground); }
  #toolbar { display: flex; gap: 8px; align-items: center; padding: 6px 8px; border-bottom: 1px solid var(--vscode-panel-border); }
  #toolbar button, #toolbar select { background: var(--vscode-button-secondaryBackground); color: var(--vscode-button-secondaryForeground); border: none; padding: 3px 8px; border-radius: 2px; }
  #toolbar button.active { background: var(--vscode-button-background); color: var(--vscode-button-foreground); }
  #stage { padding: 12px; overflow: auto; }
  #canvas { display: block; outline: none; box-shadow: 0 0 0 1px var(--vscode-panel-border); }
  #errors { display: none; margin: 8px 12px; padding: 8px; white-space: pre-wrap; font-family: var(--vscode-editor-font-family); font-size: 12px; color: var(--vscode-errorForeground); background: var(--vscode-inputValidation-errorBackground); border: 1px solid var(--vscode-inputValidation-errorBorder); }
  #inspector { margin: 0 12px 12px; }
  #selected { font-weight: 600; margin: 8px 0 4px; }
  #prop-error { color: var(--vscode-errorForeground); min-height: 1em; }
  table { border-collapse: collapse; width: 100%; max-width: 480px; }
  td { padding: 2px 6px 2px 0; }
  td:first-child { white-space: nowrap; color: var(--vscode-descriptionForeground); }
  input { width: 100%; box-sizing: border-box; background: var(--vscode-input-background); color: var(--vscode-input-foreground); border: 1px solid var(--vscode-input-border, transparent); padding: 2px 4px; }
  input:disabled { opacity: 0.6; }
</style>
</head>
<body>
<div id="toolbar">
  <select id="components" style="display:none"></select>
  <button id="inspect" title="Click elements to inspect them (or Alt+click)">Inspect</button>
  <select id="zoom">
    <option value="0.5">50%</option>
    <option value="1" selected>100%</option>
    <option value="1.5">150%</option>
    <option value="2">200%</option>
  </select>
</div>
<pre id="errors"></pre>
<div id="stage"><canvas id="canvas" tabindex="0"></canvas></div>
<div id="inspector">
  <div id="selected">Alt+click an element to inspect it</div>
  <div id="prop-error"></div>
  <table><tbody id="props"></tbody></table>
</div>
<script nonce="${nonce}" src="${script}"></script>
</body>
</html>`;
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate, findServer };
