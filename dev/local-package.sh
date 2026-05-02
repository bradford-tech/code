#!/usr/bin/env bash
# Local sign + notarize + DMG for an already-built BradfordCode.app.
# Assumes ./build.sh has produced VSCode-darwin-arm64/BradfordCode.app already.
# Usage:  ./dev/local-package.sh

set -eo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ ! -d "VSCode-darwin-arm64/BradfordCode.app" ]]; then
  echo "ERROR: VSCode-darwin-arm64/BradfordCode.app not found. Run ./dev/local-build.sh first." >&2
  exit 1
fi

if [[ ! -f .env.local ]]; then
  echo "ERROR: .env.local not found. Copy from .env.local.template and fill in." >&2
  exit 1
fi

# shellcheck disable=SC1091
source .env.local

# Derive RELEASE_VERSION from the built app's Info.plist so the DMG filename
# matches the app's internal version. Avoids re-running get_repo.sh, which would
# re-derive a (possibly different) time-based version and fails on the existing
# git remote.
RELEASE_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - VSCode-darwin-arm64/BradfordCode.app/Contents/Info.plist)"
MS_TAG="$(jq -r '.tag' upstream/stable.json)"
MS_COMMIT="$(jq -r '.commit' upstream/stable.json)"
export RELEASE_VERSION MS_TAG MS_COMMIT

echo "RELEASE_VERSION=${RELEASE_VERSION} MS_TAG=${MS_TAG} MS_COMMIT=${MS_COMMIT}"

./prepare_assets.sh
