#!/usr/bin/env bash
#
# Renders the social-preview assets (D-050) to PNG at exact pixel dimensions.
#
#   bash docs/design/social-preview/render.sh
#
# Writes straight into priv/static/images/og/. Only consensus-og.png is referenced by the
# app (it is `og:image` for every route, via ConsensusWeb.SocialPreview); the square and
# story sizes are marketing assets that nothing links to.
#
# The three .html files beside this script are transcribed from "Consensus - Social
# Preview.dc.html" in the linked Claude Design project (867b0685-278c-4ce4-ae2c-bce2135705af),
# one panel per file, with the Claude Design <x-dc>/<helmet> wrapper and the caption stripped.
# If the design file changes, re-transcribe the panel and re-run this — and if an aspect
# ratio changes, update the og:image:width/height pair in ConsensusWeb.SocialPreview, which
# is declared so Facebook and LinkedIn render the large card on first fetch.
#
# Requirements: Google Chrome (headless) and network access, because the pages pull
# Instrument Sans and DM Mono from Google Fonts. If the fonts fail to load the render
# silently falls back to a system sans and the type is wrong but the layout is not — check
# the output rather than trusting the exit code.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
OUT="$ROOT/priv/static/images/og"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

if [ ! -x "$CHROME" ]; then
  echo "Chrome not found at: $CHROME" >&2
  echo "Set CHROME=/path/to/chrome and re-run." >&2
  exit 1
fi

mkdir -p "$OUT"

# Inlined as a data URI rather than referenced as ./icon.svg: Chrome blocks file://
# subresource loads from a file:// page, so a relative <img src> renders as nothing.
# Read from the app's own icon so the two cannot drift.
ICON_URI="data:image/svg+xml;base64,$(base64 -i "$ROOT/priv/static/images/icon.svg" | tr -d '\n')"

render() {
  local src="$1" out="$2" w="$3" h="$4"
  local tmp="$DIR/.render.tmp.html"

  python3 - "$DIR/$src" "$tmp" "$ICON_URI" <<'PY'
import sys
src, dst, icon = sys.argv[1], sys.argv[2], sys.argv[3]
open(dst, "w").write(open(src).read().replace("__ICON__", icon))
PY

  "$CHROME" \
    --headless=new \
    --disable-gpu \
    --hide-scrollbars \
    --force-device-scale-factor=1 \
    --force-color-profile=srgb \
    --font-render-hinting=none \
    --window-size="$w,$h" \
    --virtual-time-budget=15000 \
    --screenshot="$OUT/$out" \
    "file://$tmp" 2>/dev/null

  rm -f "$tmp"
  echo "  $out  $(sips -g pixelWidth -g pixelHeight "$OUT/$out" | tail -2 | tr -s ' \n' ' ')"
}

echo "Rendering into $OUT"
render og-1200x630.html  consensus-og.png     1200 630
render og-1200x1200.html consensus-square.png 1200 1200
render og-1080x1920.html consensus-story.png  1080 1920
