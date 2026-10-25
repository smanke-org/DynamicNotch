#!/bin/bash
# Installs the built app to /Applications, links the `notch` command, and launches it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/.build/app/DynamicNotch.app"
DEST="/Applications/DynamicNotch.app"

[ -d "$SRC" ] || { echo "Run ./build_app.sh first." >&2; exit 1; }

pkill -x DynamicNotch 2>/dev/null || true

if [ -d "$DEST" ]; then
  # Update in place, so the Automation and login-item approvals keep pointing at the same bundle.
  rsync -a --delete "$SRC/" "$DEST/"
else
  cp -R "$SRC" "$DEST"
fi

mkdir -p "$HOME/.local/bin"
ln -sf "$DEST/Contents/MacOS/notch" "$HOME/.local/bin/notch"

open "$DEST"
echo "Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist") and linked ~/.local/bin/notch"
