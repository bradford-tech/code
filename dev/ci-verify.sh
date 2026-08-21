#!/usr/bin/env bash
# Verifies a patch-set the way CI will, without the packaging stages:
# prepare_vscode.sh (src/stable overlay + product.json + patches + npm ci)
# followed by the TypeScript compile. Catches the two failure classes a
# dry-apply cannot: compile-src type errors and (with --full) the
# vscode-min-prepack minify/ASCII-hygiene stage.
#
# Usage:
#   CI_BUILD=yes ./dev/ci-verify.sh [--commit <sha>] [--tag <x.y.z>]
#   ./dev/ci-verify.sh --full            # vscode-min-prepack instead of compile
#   ./dev/ci-verify.sh --skip-prepare    # re-run compile only, tree as-is
#
# --skip-prepare is the fast inner loop: edit vscode/ directly, re-compile
# incrementally, and only regenerate the patch + full-verify once it passes.
#
# Exits 0 verified, 1 verification failed, 2 usage/setup error.
#
# Heap: macos-15 free runners have 7 GB RAM; the default 6 GB Node heap fits.
# Override with VERIFY_HEAP (MB) on bigger machines.

set -eo pipefail

cd "$( dirname "${BASH_SOURCE[0]}" )/.." || exit 2

COMMIT=""
TAG=""
FULL=0
SKIP_PREPARE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit) COMMIT="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --full) FULL=1; shift ;;
    --skip-prepare) SKIP_PREPARE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "${COMMIT}" ]] && ! printf '%s' "${COMMIT}" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "--commit must be a 40-char hex SHA: '${COMMIT}'" >&2
  exit 2
fi
if [[ -n "${TAG}" ]] && ! printf '%s' "${TAG}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "--tag must be semver-shaped: '${TAG}'" >&2
  exit 2
fi

if [[ ! -d vscode ]]; then
  echo "vscode/ not found. Clone it first:" >&2
  echo "  commit=\$(jq -r '.commit' upstream/stable.json)" >&2
  echo "  git clone --filter=blob:none --no-checkout https://github.com/microsoft/vscode.git vscode" >&2
  echo "  ( cd vscode && git fetch --depth 1 origin \"\$commit\" && git checkout FETCH_HEAD )" >&2
  exit 2
fi

# Same env contract as the cron build job; every var overridable from outside.
export APP_NAME="${APP_NAME:-BradfordCode}"
export OS_NAME="${OS_NAME:-osx}"
export VSCODE_ARCH="${VSCODE_ARCH:-arm64}"
export VSCODE_QUALITY="${VSCODE_QUALITY:-stable}"
export SHOULD_BUILD_REH="${SHOULD_BUILD_REH:-no}"
export DISABLE_UPDATE="${DISABLE_UPDATE:-no}"
export CI_BUILD="${CI_BUILD:-no}"

export MS_TAG="${TAG:-$( jq -r '.tag' upstream/stable.json )}"
export MS_COMMIT="${COMMIT:-$( jq -r '.commit' upstream/stable.json )}"
# Same formula as the cron check job; the [0-5]-day-digit shape version.sh
# expects falls out of `%-j` (day-of-year) * 24 capping under 8784.
TIME_PATCH=$( printf "%04d" $(( $(date +%-j) * 24 + $(date +%-H) )) )
export RELEASE_VERSION="${RELEASE_VERSION:-${MS_TAG}${TIME_PATCH}}"

echo "ci-verify: MS_TAG=${MS_TAG} MS_COMMIT=${MS_COMMIT} RELEASE_VERSION=${RELEASE_VERSION}"

if [[ "${SKIP_PREPARE}" == "0" ]]; then
  # Clean first — the tree is dirty after any prior prepare/dry-apply, and
  # `git checkout` refuses to move over local modifications.
  ( cd vscode && git reset --hard -q HEAD && git clean -fdxq )

  current=$( cd vscode && git rev-parse HEAD )
  if [[ "${current}" != "${MS_COMMIT}" ]]; then
    echo "Rolling vscode/ to ${MS_COMMIT}"
    ( cd vscode && git fetch --depth 1 origin "${MS_COMMIT}" -q && git checkout -q --detach FETCH_HEAD )
    ( cd vscode && git reset --hard -q HEAD && git clean -fdxq )
  fi

  echo "== prepare_vscode.sh (overlay + product.json + patches + npm ci) =="
  # Sourced, matching build.sh — it cds into vscode/ and returns here.
  # shellcheck disable=SC1091
  . prepare_vscode.sh
fi

echo "== compile =="
export NODE_OPTIONS="--max-old-space-size=${VERIFY_HEAP:-6144}"
rc=0
if [[ "${FULL}" == "1" ]]; then
  ( cd vscode && npm run gulp vscode-min-prepack ) || rc=$?
else
  ( cd vscode && npm run compile ) || rc=$?
fi

if [[ "${rc}" -eq 0 ]]; then
  echo "ci-verify: PASS ($( [[ "${FULL}" == "1" ]] && echo "vscode-min-prepack" || echo "compile" ), tag ${MS_TAG})"
else
  echo "ci-verify: FAIL ($( [[ "${FULL}" == "1" ]] && echo "vscode-min-prepack" || echo "compile" ) exited ${rc})" >&2
  exit 1
fi
