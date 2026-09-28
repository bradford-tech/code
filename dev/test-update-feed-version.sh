#!/usr/bin/env bash
# Asserts the auto-update feed advertises a `productVersion` the patched
# updater will actually rank ABOVE an installed build. Runs in ~50ms, no build.
#
# Background: patches/11-update-use-github-release.patch compares the feed's
# `productVersion` against the running app's `product.version` (RELEASE_VERSION,
# e.g. 1.139.06401 -> normalized 1.139.6401). The release workflow used to write
# the bare upstream tag (1.139.1) into `productVersion`, so 6401 > 1 and every
# release that only bumped the upstream patch level was reported as "no
# updates available". VSCodium's feed writes the 4-part form 1.139.16443.0,
# which the updater strips back to 1.139.16443 before comparing.
#
# Usage: ./dev/test-update-feed-version.sh

set -eo pipefail

cd "$( dirname "${BASH_SOURCE[0]}" )/.." || exit 1

# shellcheck disable=SC1091
. utils.sh

FAILURES=0

assert_eq() {
  local expected="$1" actual="$2" what="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "ok   - ${what}"
  else
    echo "FAIL - ${what}"
    echo "         expected: ${expected}"
    echo "         actual:   ${actual}"
    FAILURES=$(( FAILURES + 1 ))
  fi
}

# Mirror of the updater's normalization in
# src/vs/platform/update/electron-main/abstractUpdateService.ts (as patched).
# A 4-part fetched version drops its last component; a 3-part one just loses
# leading zeros on the third component. The installed version always takes the
# leading-zero path.
normalize_fetched() {
  local v="$1"
  if [[ "${v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    echo "${v}" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+(-[A-Za-z0-9_]+)?/\1\2/'
  else
    echo "${v}" | sed -E 's/^([0-9]+\.[0-9]+\.)0+([0-9]+)(-[A-Za-z0-9_]+)?/\1\2\3/'
  fi
}

normalize_current() {
  echo "$1" | sed -E 's/^([0-9]+\.[0-9]+\.)0+([0-9]+)(-[A-Za-z0-9_]+)?/\1\2\3/'
}

# Dotted-numeric compare like the updater's compareVersions(): prints -1/0/1.
# Like the original, anything from the first '-' on (e.g. "-insider") is
# dropped before splitting on '.'.
compare_versions() {
  local -a a b
  IFS='.' read -r -a a <<< "${1%%-*}"
  IFS='.' read -r -a b <<< "${2%%-*}"
  local i n=${#a[@]}
  (( ${#b[@]} > n )) && n=${#b[@]}
  for (( i = 0; i < n; i++ )); do
    local x="${a[i]:-0}" y="${b[i]:-0}"
    if (( 10#$x != 10#$y )); then
      (( 10#$x < 10#$y )) && echo -1 || echo 1
      return
    fi
  done
  echo 0
}

# --- update_feed_product_version -----------------------------------------
assert_eq "1.139.16443.0" "$( update_feed_product_version "1.139.16443" )" \
  "4-part form for a patch-level upstream tag"
assert_eq "1.139.6401.0" "$( update_feed_product_version "1.139.06401" )" \
  "leading zero on the build component is dropped"
assert_eq "1.139.6401.0-insider" "$( update_feed_product_version "1.139.06401-insider" )" \
  "insider marker is preserved after the 4th component"

# --- the updater must rank the feed above the installed build --------------
# The exact pair that failed in the wild: installed 1.139.06401, feed 1.139.16443.
installed="$( normalize_current "1.139.06401" )"
fetched="$( normalize_fetched "$( update_feed_product_version "1.139.16443" )" )"
assert_eq "1.139.6401" "${installed}" "installed 1.139.06401 normalizes to 1.139.6401"
assert_eq "1.139.16443" "${fetched}" "feed productVersion normalizes to 1.139.16443"
assert_eq "-1" "$( compare_versions "${installed}" "${fetched}" )" \
  "installed 1.139.06401 ranks BELOW feed 1.139.16443 (update offered)"

# And the regression: the bare upstream tag ranks below the installed build.
assert_eq "1" "$( compare_versions "${installed}" "$( normalize_fetched "1.139.1" )" )" \
  "bare upstream tag 1.139.1 ranks below the installed build (the old bug)"

# Same version on both sides must not loop on itself.
assert_eq "0" "$( compare_versions "$( normalize_current "1.139.16443" )" "${fetched}" )" \
  "feed equals the installed build once updated (no re-offer)"

# The prerelease marker is ignored by the compare, as in the original.
assert_eq "-1" "$( compare_versions "1.139.6401-insider" "1.139.16443-insider" )" \
  "compare ignores the -insider marker"

# --- committed feed -------------------------------------------------------
FEED="versions/stable/darwin-arm64/latest.json"
feed_name="$( jq -r '.name' "${FEED}" )"
feed_pv="$( jq -r '.productVersion' "${FEED}" )"
assert_eq "$( update_feed_product_version "${feed_name}" )" "${feed_pv}" \
  "committed ${FEED} productVersion matches its name (${feed_name})"

# --- CI wiring ------------------------------------------------------------
WF=".github/workflows/cron-build-and-release.yml"
step="$( sed -n '/- name: Write versions\/stable\/darwin-arm64\/latest.json/,/^      - name:/p' "${WF}" )"

if grep -q -- '--arg productVersion "\$MS_TAG"' <<< "${step}"; then
  echo "FAIL - workflow writes the bare upstream tag into productVersion"
  FAILURES=$(( FAILURES + 1 ))
else
  echo "ok   - workflow does not write \$MS_TAG into productVersion"
fi

# Grep the code, not the step's own comment, which names the helper too.
code="$( grep -v '^[[:space:]]*#' <<< "${step}" )"

if grep -q 'product_version=\$( update_feed_product_version "\${RELEASE_VERSION}" )' <<< "${code}"; then
  echo "ok   - workflow derives productVersion via update_feed_product_version"
else
  echo "FAIL - workflow must derive productVersion via update_feed_product_version"
  FAILURES=$(( FAILURES + 1 ))
fi

# Pin what jq actually consumes, not only what it must not consume: a partial
# revert to "${MS_TAG}" or any other expression would slip past the negative
# assertion above.
if grep -q -- '--arg productVersion "\$product_version"' <<< "${code}"; then
  echo "ok   - jq reads productVersion from the helper's output"
else
  echo "FAIL - jq must read productVersion from \$product_version"
  FAILURES=$(( FAILURES + 1 ))
fi

if grep -q '^[[:space:]]*\. utils\.sh' <<< "${step}"; then
  echo "ok   - workflow step sources utils.sh"
else
  echo "FAIL - workflow step must source utils.sh to get the helper"
  FAILURES=$(( FAILURES + 1 ))
fi

echo
if (( FAILURES > 0 )); then
  echo "${FAILURES} assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
