#!/usr/bin/env bash
# shellcheck disable=SC1091

set -e

. ./utils.sh

mkdir -p assets

if [[ "${OS_NAME}" == "osx" ]]; then
  . ./build/osx/prepare_assets.sh

  VSCODE_PLATFORM="darwin"
else
  # The linux job produces the REH server only; there is no desktop client to
  # sign, notarize or wrap in a DMG.
  VSCODE_PLATFORM="linux"
fi

if [[ "${SHOULD_BUILD_REH}" == "yes" ]]; then
  REH_ASSET="$( reh_asset_name "${VSCODE_PLATFORM}" "${VSCODE_ARCH}" "${RELEASE_VERSION}" )"

  echo "Packaging REH: ${REH_ASSET}"

  # Tar from INSIDE the directory so entries are `./bin/code-server`. The
  # open-remote-ssh install script extracts with `--strip-components 1`, which
  # drops the leading `./` and lands the binary at `bin/code-server` — the path
  # it then executes as $SERVER_SCRIPT.
  cd "vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}" || {
    echo "'vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}' dir not found" >&2
    exit 1
  }
  tar czf "../assets/${REH_ASSET}" .
  cd ..
fi

./prepare_checksums.sh
