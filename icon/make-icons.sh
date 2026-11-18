#!/bin/zsh
# Regenerates ../macos/Tide.icns, ../windows/Tide.ico and the tray frames ../windows/tray/tray*.png from tide.svg.
# Needs Google Chrome (to rasterize the SVG with a transparent background); the outputs are committed,
# so building Tide doesn't need this. Run it only after editing tide.svg.
set -e
DIR="${0:A:h}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x "$CHROME" ]] || { echo "Google Chrome not found at $CHROME"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Rasterize an SVG (with the given viewBox) to a 1024x1024 transparent PNG.
render() {  # <viewBox> <out.png>
  sed -E "s/viewBox=\"[^\"]*\"/viewBox=\"$1\"/" "$DIR/tide.svg" > "$TMP/in.svg"
  echo "<html><body style=\"margin:0;background:transparent\"><img src=\"in.svg\" width=1024 height=1024 style=\"display:block\"></body></html>" > "$TMP/in.html"
  "$CHROME" --headless --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --window-size=1024,1024 --screenshot="$2" "file://$TMP/in.html" >/dev/null 2>&1
}

# macOS: the artwork keeps Apple's 100px margin around the squircle (viewBox 0 0 1024 1024).
render "0 0 1024 1024" "$TMP/mac.png"
SET="$TMP/Tide.iconset"; mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/mac.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/mac.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$DIR/../macos/Tide.icns"

# Windows: crop the margin so the icon fills its square.
render "100 100 824 824" "$TMP/win.png"
python3 - "$TMP" "$DIR/../windows/Tide.ico" <<'PY'
import struct, subprocess, sys
tmp, out = sys.argv[1], sys.argv[2]
sizes = [16, 24, 32, 48, 64, 128, 256]
images = []
for s in sizes:
    p = f"{tmp}/ico{s}.png"
    subprocess.run(["sips", "-z", str(s), str(s), f"{tmp}/win.png", "--out", p], check=True, capture_output=True)
    images.append(open(p, "rb").read())
data = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
for s, png in zip(sizes, images):
    data += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(png), offset)
    offset += len(png)
open(out, "wb").write(data + b"".join(images))
PY

# Windows tray: one PNG per notification-area icon size (100%, 125%, 150%, 200%, 300% scaling), embedded in the exe.
mkdir -p "$DIR/../windows/tray"
for s in 16 20 24 32 48 64; do
  sips -z $s $s "$TMP/win.png" --out "$DIR/../windows/tray/tray$s.png" >/dev/null
done
echo "Wrote macos/Tide.icns, windows/Tide.ico and windows/tray/tray*.png"
