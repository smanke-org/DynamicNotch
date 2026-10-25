#!/bin/bash
# Assembles and signs DynamicNotch.app (with the `notch` command inside it): Developer ID,
# hardened runtime, not sandboxed (it serves a socket in Application Support and controls
# Music and Spotify). For a build without a Developer ID, use ./build.sh.
#
#   ./build_app.sh [signing identity]
set -euo pipefail

APP_NAME="DynamicNotch"
BUNDLE_ID="com.smanke.DynamicNotch"
ROOT="$(cd "$(dirname "$0")" && pwd)"

IDENTITY="${1:-}"
BUILD_PATH="$ROOT/.build"
ENTITLEMENTS="$ROOT/Resources/DynamicNotch.entitlements"
BUILD="$ROOT/.build/app"
APP="$BUILD/$APP_NAME.app"
SWIFT_ARGS=(-c release --arch arm64 --arch x86_64 --build-path "$BUILD_PATH")

# Ask SwiftPM where it puts the binaries rather than assuming: the location has moved
# between toolchains, and a hardcoded path once packaged a days-old binary inside a
# freshly versioned bundle. The products are deleted first and must be newer than a
# marker made before the build, so a build that didn't link can't be packaged.
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
rm -f "$BIN_DIR/$APP_NAME" "$BIN_DIR/notch"
MARKER="$(mktemp)"
trap 'rm -f "$MARKER"' EXIT

echo "==> Building universal binaries"
swift build "${SWIFT_ARGS[@]}"

for product in "$APP_NAME" notch; do
  if [ ! -x "$BIN_DIR/$product" ] || [ ! "$BIN_DIR/$product" -nt "$MARKER" ]; then
    echo "No freshly built $BIN_DIR/$product — refusing to package." >&2
    exit 1
  fi
done
echo "    using $BIN_DIR"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$BIN_DIR/notch" "$APP/Contents/MacOS/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

echo "==> Resolving signing identity"
if [ -z "$IDENTITY" ]; then
  FOUND=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
  if [ -z "$FOUND" ]; then
    echo "No Developer ID Application identity found in the keychain. Use ./build.sh for an unsigned build." >&2
    exit 1
  fi
  IDENTITY=$(echo "$FOUND" | sed -E 's/.*"(.*)"$/\1/')
fi
echo "    $IDENTITY"

echo "==> Signing"
# The command-line tool first: notarization wants every executable signed with the
# hardened runtime and a secure timestamp, and the bundle's signature seals it.
codesign --force --options runtime --timestamp \
  --identifier "$BUNDLE_ID.notch" \
  --sign "$IDENTITY" \
  "$APP/Contents/MacOS/notch"
# Keep the .entitlements files free of XML comments: plutil accepts them, but codesign's
# AMFI parser rejects the file ("syntax error near line 5").
codesign --force --options runtime --timestamp \
  --identifier "$BUNDLE_ID" \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" \
  "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"

echo
echo "Built $APP ($VERSION)"
