#!/usr/bin/env bash

APP_NAME="${APP_NAME:-BradfordCode}"
APP_NAME_LC="$( echo "${APP_NAME}" | awk '{print tolower($0)}' )"
ASSETS_REPOSITORY="${ASSETS_REPOSITORY:-bradford-tech/code}"
BINARY_NAME="${BINARY_NAME:-code}"
GH_REPO_PATH="${GH_REPO_PATH:-bradford-tech/code}"
ORG_NAME="${ORG_NAME:-bradford-tech}"
TUNNEL_APP_NAME="${TUNNEL_APP_NAME:-"${BINARY_NAME}-tunnel"}"

# --- Remote extension host (REH) naming contract --------------------------
#
# `patches/10-version-add-release.patch` makes the extension host report
# `vscode.version` as the upstream tag only — RELEASE_VERSION with its 4-digit
# build suffix stripped. jeanp413.open-remote-ssh expands `${version}` from
# that value and `${release}` from product.json's `release` field, so
# `${version}${release}` — concatenated with NO dot — reconstructs
# RELEASE_VERSION, which is exactly the GitHub release tag we publish under.
#
# These three helpers are the single source of truth. prepare_vscode.sh writes
# the template into product.json, prepare_assets.sh names the tarball, and the
# release job uploads it — all from here. dev/test-reh-naming.sh asserts they
# round-trip; run it after touching any of them.

reh_release_suffix() {
  local release_version="${1%-insider}"
  local ms_tag="${2}"
  echo "${release_version#"${ms_tag}"}"
}

reh_asset_name() {
  local platform="${1}" arch="${2}" release_version="${3}"
  echo "${APP_NAME_LC}-reh-${platform}-${arch}-${release_version}.tar.gz"
}

reh_url_template() {
  echo "https://github.com/${GH_REPO_PATH}/releases/download/\${version}\${release}/${APP_NAME_LC}-reh-\${os}-\${arch}-\${version}\${release}.tar.gz"
}

if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
  GLOBAL_DIRNAME="${GLOBAL_DIRNAME:-"${APP_NAME}"}-Insiders"
else
  GLOBAL_DIRNAME="${GLOBAL_DIRNAME:-"${APP_NAME}"}"
fi

# All common functions can be added to this file

apply_patch() {
  if [[ -z "$2" ]]; then
    echo applying patch: "$1";
  fi
  # grep '^+++' "$1"  | sed -e 's#+++ [ab]/#./vscode/#' | while read line; do shasum -a 256 "${line}"; done

  cp $1{,.bak}

  replace "s|!!APP_NAME!!|${APP_NAME}|g" "$1"
  replace "s|!!APP_NAME_LC!!|${APP_NAME_LC}|g" "$1"
  replace "s|!!ASSETS_REPOSITORY!!|${ASSETS_REPOSITORY}|g" "$1"
  replace "s|!!BINARY_NAME!!|${BINARY_NAME}|g" "$1"
  replace "s|!!GH_REPO_PATH!!|${GH_REPO_PATH}|g" "$1"
  replace "s|!!GLOBAL_DIRNAME!!|${GLOBAL_DIRNAME}|g" "$1"
  replace "s|!!ORG_NAME!!|${ORG_NAME}|g" "$1"
  replace "s|!!RELEASE_VERSION!!|${RELEASE_VERSION}|g" "$1"
  replace "s|!!TUNNEL_APP_NAME!!|${TUNNEL_APP_NAME}|g" "$1"

  if ! git apply --ignore-whitespace "$1"; then
    echo failed to apply patch "$1" >&2
    exit 1
  fi

  mv -f $1{.bak,}
}

exists() { type -t "$1" &> /dev/null; }

is_gnu_sed() {
  sed --version &> /dev/null
}

replace() {
  if is_gnu_sed; then
    sed -i -E "${1}" "${2}"
  else
    sed -i '' -E "${1}" "${2}"
  fi
}

if ! exists gsed; then
  if is_gnu_sed; then
    function gsed() {
      sed -i -E "$@"
    }
  else
    function gsed() {
      sed -i '' -E "$@"
    }
  fi
fi
