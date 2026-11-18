# zigulee for VS Code

Support for zigulee's `.zge` files: syntax highlighting, and through
`zigulee-lsp`: errors as you type, completion, hover, go to definition (also
into the standard widgets), find references and rename across the
workspace, document outline, formatting and a live preview.

## Live preview

Run **zigulee: Show Live Preview** (the preview icon in the editor title
bar, or Cmd/Ctrl+K V) in a `.zge` file. The preview:

- runs the file as you type (unsaved changes included); if the text has
  errors they are shown above the last version that worked,
- is interactive: click, type, scroll,
- inspects: Alt+click an element (or turn on Inspect) to jump to its
  source and see its properties; edit a value and press Enter to apply it
  live, or Shift+Enter to also write it in the file (undoable),
- follows the editor: the element under the cursor is highlighted.

It previews the last exported component that inherits `Window` (pick
another one in the toolbar). Text uses the bundled Inter and JetBrains
Mono fonts.

## Setup

From the zigulee repository (needs Zig and Node.js):

```
editors/vscode/install.sh
```

It builds `zigulee-lsp` (ReleaseSafe), bundles it inside the extension,
packages `zigulee.vsix` and installs it with VS Code's `code` command. On
macOS `code` is only on the PATH after **Shell Command: Install 'code'
command in PATH** (Command Palette); otherwise the script uses the one
inside `/Applications/Visual Studio Code.app`. You can also install the
`.vsix` by hand: Extensions view, `...` menu, **Install from VSIX...**.
Then reload VS Code (**Developer: Reload Window**).

npm may warn that some packages' install scripts were not run; the
packaging does not need them. Run the script again after updating zigulee,
to rebuild the bundled server.

The extension uses, in order: `zigulee.serverPath` if set, the bundled
server, `zig-out/bin/zigulee-lsp` in an open folder, then `zigulee-lsp` on the
PATH (which VS Code started from the Dock may not have).

To work on the extension itself, run `npm install` in this directory, open
it in VS Code and press F5: an Extension Development Host starts with it.

## Settings

- `zigulee.serverPath`: the `zigulee-lsp` executable (default: empty, found
  automatically as above).
- `zigulee.style`: the style used for `std-widgets.zge` (default: `fluent`).
