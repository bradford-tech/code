#!/usr/bin/env bash
# shellcheck disable=SC1091

set -e

APP_NAME_LC="$( echo "${APP_NAME}" | awk '{print tolower($0)}' )"

mkdir -p assets

. ./build/osx/prepare_assets.sh

VSCODE_PLATFORM="darwin"

./prepare_checksums.sh
