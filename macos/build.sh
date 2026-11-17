#!/bin/zsh
# Builds Tide.app, signs it, and installs it to /Applications (quitting a running copy first).
#   macos/build.sh               build, install and open
#   macos/build.sh --no-install  build only (macos/build/Tide.app)
set -e
DIR="${0:A:h}"
BUNDLE_ID="io.ruiying.Tide"
APP="$DIR/build/Tide.app"
DEST="/Applications/Tide.app"

echo "Compiling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$DIR"/Sources/*.swift -o "$APP/Contents/MacOS/Tide"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR/Tide.icns" "$APP/Contents/Resources/Tide.icns"

# Sign with a stable identity so the Accessibility grant and Keychain access survive rebuilds
# (an ad-hoc signature changes every build, and macOS then drops the grant).
IDENTITY=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -1)
if [[ -n "$IDENTITY" ]]; then
  codesign --force --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$APP"
  echo "Signed with $IDENTITY"
else
  codesign --force --identifier "$BUNDLE_ID" --sign - "$APP"
  echo "No Apple Development certificate found; ad-hoc signed (re-grant Accessibility after each rebuild)."
fi

[[ "$1" == "--no-install" ]] && { echo "Built $APP"; exit 0; }

# Quit a running copy; it restores the display if it is dimmed.
if pgrep -xq Tide; then
  echo "Quitting running Tide…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..40}; do pgrep -xq Tide || break; sleep 0.25; done
fi

rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed $DEST"
echo "Log: ~/Library/Logs/Tide/tide.log"
