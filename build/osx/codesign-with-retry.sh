#!/usr/bin/env bash
# Runs the macOS signing pass, retrying when Apple's RFC-3161 timestamp
# authority is transiently unavailable.
#
# electron-osx-sign shells out to `codesign --timestamp` once per nested binary
# (~40 of them in BradfordCode.app), so a few seconds of downtime at Apple's
# timestamp service fails the entire build:
#
#   Electron Framework.framework: The timestamp service is not available.
#
# Retrying the whole pass is safe because every codesign call is made with
# --force, so re-signing a bundle that is already fully or partially signed
# simply replaces the existing signatures.
#
# A non-transient failure (bad entitlement, missing identity, malformed
# bundle) is NOT retried — it fails on the first attempt so real breakage
# surfaces immediately instead of being hidden behind minutes of backoff.
#
# Usage: build/osx/codesign-with-retry.sh <command> [args...]
# Env:   SIGN_MAX_ATTEMPTS (default 3), SIGN_RETRY_DELAY (default 30 seconds)

set -e

SIGN_MAX_ATTEMPTS="${SIGN_MAX_ATTEMPTS:-3}"
SIGN_RETRY_DELAY="${SIGN_RETRY_DELAY:-30}"

# Failures caused by Apple's infrastructure or the network rather than by what
# we are signing. Keep this list tight: anything matched here is retried, so an
# over-broad pattern would mask real signing bugs.
TRANSIENT_PATTERN='timestamp (service|server)|The network connection was lost|Connection refused|Operation timed out'

log_file="$( mktemp )"
trap 'rm -f "${log_file}"' EXIT

attempt=1

while true; do
  # Captured rather than piped to tee: this script runs without `pipefail`, so
  # a pipeline would report tee's exit status and every failure would look like
  # a success.
  if "$@" > "${log_file}" 2>&1; then
    cat "${log_file}"
    exit 0
  fi

  cat "${log_file}"

  if ! grep -qiE "${TRANSIENT_PATTERN}" "${log_file}"; then
    echo "+ signing failed for a non-transient reason; not retrying" >&2
    exit 1
  fi

  if (( attempt >= SIGN_MAX_ATTEMPTS )); then
    echo "+ signing still failing after ${SIGN_MAX_ATTEMPTS} attempt(s); giving up" >&2
    exit 1
  fi

  delay=$(( attempt * SIGN_RETRY_DELAY ))
  echo "+ transient signing failure (attempt ${attempt}/${SIGN_MAX_ATTEMPTS}); retrying in ${delay}s" >&2
  sleep "${delay}"
  attempt=$(( attempt + 1 ))
done
