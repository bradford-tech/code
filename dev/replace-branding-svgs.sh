#!/usr/bin/env bash
# Replace SVGs in src/stable/ with BradfordCode-branded ones,
# rewriting outer width/height to match each target's expected display dimensions
# while preserving the viewBox so content scales proportionally.
#
# Also regenerates icons/stable/code.icns from BradfordCode-icon.svg and installs
# it into src/stable/resources/darwin/code.icns.
#
# Usage: ./dev/replace-branding-svgs.sh

set -eo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SRC="$HOME/Downloads"

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "ERROR: required source missing: $1" >&2
    exit 1
  fi
}

require_file "$SRC/BradfordCode-icon.svg"
require_file "$SRC/BradfordCode-icon-transparent.svg"
require_file "$SRC/BradfordCode-icon-black-transparent.svg"
require_file "$SRC/BradfordCode-icon-white-transparent.svg"

# Rewrite the FIRST occurrence of width="..." and height="..." in the file.
# Since these appear inside the outer <svg> tag (and no other tag precedes the
# root in a well-formed SVG), this updates only the outer dimensions and leaves
# the viewBox + interior elements untouched.
rewrite_dims() {
  local src="$1" dst="$2" w="$3" h="$4"
  mkdir -p "$(dirname "$dst")"
  perl -0777 -pe 's/width="\d+(?:\.\d+)?"/width="'"$w"'"/; s/height="\d+(?:\.\d+)?"/height="'"$h"'"/' "$src" > "$dst"
  echo "  wrote $dst (${w}x${h})"
}

echo "=== Replacing branding SVGs ==="

# Workbench logo (~1024x1024 — used in title bar, branded backgrounds)
rewrite_dims "$SRC/BradfordCode-icon-transparent.svg" \
  src/stable/src/vs/workbench/browser/media/code-icon.svg \
  1024 1024

# Empty-editor letterpress (40x40, four theme variants)
rewrite_dims "$SRC/BradfordCode-icon-black-transparent.svg" \
  src/stable/src/vs/workbench/browser/parts/editor/media/letterpress-light.svg \
  40 40
rewrite_dims "$SRC/BradfordCode-icon-white-transparent.svg" \
  src/stable/src/vs/workbench/browser/parts/editor/media/letterpress-dark.svg \
  40 40
rewrite_dims "$SRC/BradfordCode-icon-black-transparent.svg" \
  src/stable/src/vs/workbench/browser/parts/editor/media/letterpress-hcLight.svg \
  40 40
rewrite_dims "$SRC/BradfordCode-icon-white-transparent.svg" \
  src/stable/src/vs/workbench/browser/parts/editor/media/letterpress-hcDark.svg \
  40 40

# Chat-sessions letterpress (128x128) — new overlay paths since upstream VSCode
# ships these directly without an override.
rewrite_dims "$SRC/BradfordCode-icon-black-transparent.svg" \
  src/stable/src/vs/sessions/contrib/chat/browser/media/letterpress-sessions-light.svg \
  128 128
rewrite_dims "$SRC/BradfordCode-icon-white-transparent.svg" \
  src/stable/src/vs/sessions/contrib/chat/browser/media/letterpress-sessions-dark.svg \
  128 128

echo ""
echo "=== Regenerating macOS app icon (.icns) from BradfordCode-icon.svg ==="

# Render the filled-background variant to a 1024x1024 PNG, then run the existing
# iconset → icns pipeline.
magick "$SRC/BradfordCode-icon.svg" -resize 1024x1024 -background none -strip icons/source/logo-1024.png
sips -g pixelWidth -g pixelHeight icons/source/logo-1024.png | grep -E 'pixelWidth|pixelHeight'

./icons/build_icons.sh --install

echo ""
echo "=== Done ==="
echo "Replaced branding SVGs:"
find src/stable/src -type f -name "*.svg" | sort
echo ""
echo "Regenerated app icon: src/stable/resources/darwin/code.icns"
shasum -a 256 src/stable/resources/darwin/code.icns
