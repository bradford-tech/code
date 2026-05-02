#!/usr/bin/env bash
# Build BradfordCode app icon (code.icns) from icons/source/logo-1024.png
# Output: icons/stable/code.icns and (when --install) src/stable/resources/darwin/code.icns

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_PNG="${SCRIPT_DIR}/source/logo-1024.png"
ICONSET_DIR="${SCRIPT_DIR}/stable/code.iconset"
ICNS_OUTPUT="${SCRIPT_DIR}/stable/code.icns"

if [[ ! -f "${SOURCE_PNG}" ]]; then
  echo "missing source: ${SOURCE_PNG}" >&2
  exit 1
fi

rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"

# Apple's iconset spec requires these specific filenames:
#   icon_16x16.png        (16×16 @1x)
#   icon_16x16@2x.png     (32×32 rendered as 16@2x)
#   icon_32x32.png        (32×32 @1x)
#   icon_32x32@2x.png     (64×64 rendered as 32@2x)
#   icon_128x128.png      (128×128 @1x)
#   icon_128x128@2x.png   (256×256 rendered as 128@2x)
#   icon_256x256.png      (256×256 @1x)
#   icon_256x256@2x.png   (512×512 rendered as 256@2x)
#   icon_512x512.png      (512×512 @1x)
#   icon_512x512@2x.png   (1024×1024 rendered as 512@2x)

generate() {
  local pixel_size="$1"
  local filename="$2"
  sips -z "${pixel_size}" "${pixel_size}" "${SOURCE_PNG}" --out "${ICONSET_DIR}/${filename}" >/dev/null
}

generate 16   icon_16x16.png
generate 32   icon_16x16@2x.png
generate 32   icon_32x32.png
generate 64   icon_32x32@2x.png
generate 128  icon_128x128.png
generate 256  icon_128x128@2x.png
generate 256  icon_256x256.png
generate 512  icon_256x256@2x.png
generate 512  icon_512x512.png
generate 1024 icon_512x512@2x.png

iconutil -c icns "${ICONSET_DIR}" -o "${ICNS_OUTPUT}"
rm -rf "${ICONSET_DIR}"

echo "built: ${ICNS_OUTPUT}"

if [[ "${1:-}" == "--install" ]]; then
  TARGET="${SCRIPT_DIR}/../src/stable/resources/darwin/code.icns"
  mkdir -p "$(dirname "${TARGET}")"
  cp "${ICNS_OUTPUT}" "${TARGET}"
  echo "installed: ${TARGET}"
fi
