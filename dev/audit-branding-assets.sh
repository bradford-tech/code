#!/usr/bin/env bash
# Audit branding-relevant icon assets in src/stable/ and source PNGs in ~/Downloads.
# Outputs a table comparing format, dimensions, color profile, and transparency
# so we can pick replacements deliberately.
#
# Usage:  ./dev/audit-branding-assets.sh
# Output: stdout (also writes dev/audit-branding-assets.report.txt)

set -eo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

REPORT="dev/audit-branding-assets.report.txt"
: > "${REPORT}"

log() { echo "$@" | tee -a "${REPORT}"; }

inspect() {
  local path="$1"
  local label="$2"

  if [[ ! -f "${path}" ]]; then
    log "  ${label}: MISSING"
    return
  fi

  local fmt dims alpha colorspace bytes
  bytes=$(stat -f '%z' "${path}")

  case "${path,,}" in
    *.svg)
      fmt="svg"
      # Pull width/height/viewBox from first <svg ...> tag
      local svg_attrs
      svg_attrs=$(grep -oE '<svg[^>]*' "${path}" | head -1)
      dims="$(echo "${svg_attrs}" | grep -oE 'width="[^"]*"|height="[^"]*"|viewBox="[^"]*"' | tr '\n' ' ')"
      alpha="—"
      colorspace="—"
      ;;
    *.png)
      fmt="png"
      dims="$(sips -g pixelWidth -g pixelHeight "${path}" 2>/dev/null | awk '/pixelWidth|pixelHeight/ {print $1, $2}' | xargs)"
      alpha="$(sips -g hasAlpha "${path}" 2>/dev/null | awk '/hasAlpha/ {print $2}')"
      colorspace="$(sips -g space "${path}" 2>/dev/null | awk '/space/ {print $2}')"
      ;;
    *.icns)
      fmt="icns"
      dims="(multi-size; first layer extractable)"
      alpha="implicit"
      colorspace="—"
      ;;
    *.ico)
      fmt="ico"
      dims="(multi-size)"
      alpha="implicit"
      colorspace="—"
      ;;
    *)
      fmt="?"
      dims="?"
      alpha="?"
      colorspace="?"
      ;;
  esac

  log "  ${label}"
  log "    path:       ${path}"
  log "    format:     ${fmt} (${bytes} bytes)"
  log "    dimensions: ${dims}"
  log "    hasAlpha:   ${alpha}"
  log "    colorspace: ${colorspace}"
}

log "================================================================"
log "BradfordCode branding asset audit"
log "Generated: $(date)"
log "================================================================"
log ""
log "## Source PNGs (replacements you provided)"
log ""

for f in \
  "$HOME/Downloads/BradfordCode-icon.png" \
  "$HOME/Downloads/BradfordCode-icon-transparent.png" \
  "$HOME/Downloads/BradfordCode-icon-black-transparent.png" \
  "$HOME/Downloads/BradfordCode-icon-white-transparent.png"
do
  inspect "${f}" "$(basename "${f}")"
  log ""
done

log ""
log "## Targets in src/stable/src/vs/workbench/ (baked into app bundle)"
log ""

inspect "src/stable/src/vs/workbench/browser/media/code-icon.svg"            "code-icon.svg              (workbench logo, ~1024×1024)"
inspect "src/stable/src/vs/workbench/browser/parts/editor/media/letterpress-light.svg"   "letterpress-light.svg      (empty-editor, light theme, 40×40)"
inspect "src/stable/src/vs/workbench/browser/parts/editor/media/letterpress-dark.svg"    "letterpress-dark.svg       (empty-editor, dark theme, 40×40)"
inspect "src/stable/src/vs/workbench/browser/parts/editor/media/letterpress-hcLight.svg" "letterpress-hcLight.svg    (empty-editor, hc-light theme, 40×40)"
inspect "src/stable/src/vs/workbench/browser/parts/editor/media/letterpress-hcDark.svg"  "letterpress-hcDark.svg     (empty-editor, hc-dark theme, 40×40)"

log ""
log "## Targets in /Applications/BradfordCode.app (already-installed bundle)"
log ""

for path in \
  "/Applications/BradfordCode.app/Contents/Resources/app/out/vs/sessions/contrib/chat/browser/media/letterpress-sessions-light.svg" \
  "/Applications/BradfordCode.app/Contents/Resources/app/out/vs/sessions/contrib/chat/browser/media/letterpress-sessions-dark.svg"
do
  inspect "${path}" "$(basename "${path}")"
done

log ""
log "## Targets in src/stable/resources/server/ (REH server UI; not used in Phase 1)"
log ""

inspect "src/stable/resources/server/code-192.png" "code-192.png  (REH browser favicon, 192×192)"
inspect "src/stable/resources/server/code-512.png" "code-512.png  (REH dashboard logo, 512×512)"
inspect "src/stable/resources/server/favicon.ico"  "favicon.ico   (REH browser favicon)"

log ""
log "Report written to: ${REPORT}"
