#!/usr/bin/env bash
# Local build orchestrator for BradfordCode.
# Sources .env.local + get_repo.sh in this shell so their exports propagate, then runs build.sh.
# Usage:  ./dev/local-build.sh
# Requires: .env.local present at repo root; Node version per .nvmrc active.

set -eo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ ! -f .env.local ]]; then
  echo "ERROR: .env.local not found. Copy from .env.local.template and fill in." >&2
  exit 1
fi

# shellcheck disable=SC1091
source .env.local

# get_repo.sh sets+exports MS_TAG, MS_COMMIT, RELEASE_VERSION; must be sourced (not invoked) for these to propagate.
# shellcheck disable=SC1091
source ./get_repo.sh

./build.sh
