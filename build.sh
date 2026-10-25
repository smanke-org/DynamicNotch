#!/bin/bash
# Builds build/DynamicNotch.app (with the `notch` CLI inside it).
#   ./build.sh            release build
#   ./build.sh --install  also copy to ~/Applications and link ~/.local/bin/notch
set -euo pipefail
cd "$(dirname "$0")"

# Fall back to the Command Line Tools if Xcode's toolchain isn't usable (e.g. license not accepted).
if ! swift --version >/dev/null 2>&1 && [ -d /Library/Developer/CommandLineTools ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP=build/DynamicNotch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/"
cp "$BIN/DynamicNotch" "$BIN/notch" "$APP/Contents/MacOS/"
codesign --force --sign - "$APP/Contents/MacOS/notch"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/DynamicNotch.app"
  osascript -e 'tell application id "dev.dynamicnotch.DynamicNotch" to quit' >/dev/null 2>&1 || true
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  ln -sf "$DEST/Contents/MacOS/notch" "$HOME/.local/bin/notch"
  open "$DEST"
  echo "Installed $DEST and linked ~/.local/bin/notch"
fi
