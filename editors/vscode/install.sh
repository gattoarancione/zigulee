#!/bin/sh
# Copyright (c) 2026 Claudio Russo (gattoarancione)
# SPDX-License-Identifier: MIT

# Builds the language server and the extension, with the server bundled
# inside, and installs it into VS Code (macOS and Linux).
set -e
cd "$(dirname "$0")"

# The server, built from this repository and copied into the extension.
(cd ../.. && zig build -Doptimize=ReleaseSafe)
mkdir -p bin
cp ../../zig-out/bin/zigulee-lsp bin/zigulee-lsp
chmod 755 bin/zigulee-lsp

npm install
npx vsce package --out zigulee.vsix
# The `code` command, or the one inside the app on macOS (where `code` is
# only on the PATH after "Shell Command: Install 'code' command in PATH").
CODE=$(command -v code || true)
if [ -z "$CODE" ] && [ -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ]; then
    CODE="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
fi
if [ -z "$CODE" ]; then
    echo "Could not find VS Code's 'code' command."
    echo "Install editors/vscode/zigulee.vsix from VS Code: Extensions view, '...' menu, 'Install from VSIX...'."
    exit 1
fi
"$CODE" --install-extension zigulee.vsix --force
echo "Installed. Reload VS Code (Developer: Reload Window) to use it."
