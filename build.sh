#!/usr/bin/env bash
# shellcheck disable=SC1091

set -ex

. version.sh

if [[ "${SHOULD_BUILD}" == "yes" ]]; then
  echo "MS_COMMIT=\"${MS_COMMIT}\""

  . prepare_vscode.sh

  cd vscode || { echo "'vscode' dir not found"; exit 1; }

  export NODE_OPTIONS="--max-old-space-size=8192"
  export VSCODE_PUBLISH_COUNTER=1

  npm run gulp vscode-min-prepack

  # remove win32 node modules
  rm -f .build/extensions/ms-vscode.js-debug/src/win32-app-container-tokens.*.node

  if [[ "${OS_NAME}" == "osx" ]]; then
    # generate Group Policy definitions
    npm run copy-policy-dto --prefix build
    node build/lib/policies/policyGenerator.ts build/lib/policies/policyData.jsonc darwin

    npm run gulp "vscode-darwin-${VSCODE_ARCH}-min-packing"

    find "../VSCode-darwin-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

    VSCODE_PLATFORM="darwin"
  else
    # The linux job builds the remote extension host only — no desktop client,
    # so no policy generation and no `vscode-linux-*-min-packing`.
    VSCODE_PLATFORM="linux"
  fi

  if [[ "${SHOULD_BUILD_REH}" == "yes" ]]; then
    npm run gulp minify-vscode-reh
    npm run gulp "vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"
  fi

  cd ..
fi
