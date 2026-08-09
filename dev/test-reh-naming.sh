#!/usr/bin/env bash
# Asserts the REH naming contract round-trips: the URL that
# jeanp413.open-remote-ssh builds from product.json must equal the URL of the
# asset that prepare_assets.sh uploads. Runs in ~50ms, needs no build.
#
# Usage: ./dev/test-reh-naming.sh

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

# --- reh_release_suffix ---------------------------------------------------
assert_eq "5296" "$( reh_release_suffix "1.132.05296" "1.132.0" )" \
  "release suffix for a .0 upstream tag"
assert_eq "5296" "$( reh_release_suffix "1.132.25296" "1.132.2" )" \
  "release suffix for a patch upstream tag"
assert_eq "5296" "$( reh_release_suffix "1.132.05296-insider" "1.132.0" )" \
  "release suffix strips the -insider marker"

# --- reh_asset_name -------------------------------------------------------
assert_eq "bradfordcode-reh-linux-x64-1.132.05296.tar.gz" \
  "$( reh_asset_name "linux" "x64" "1.132.05296" )" \
  "asset name for linux-x64"

# --- round-trip -----------------------------------------------------------
# Expand the template exactly the way the extension does: a global literal
# substitution of each ${...} token. See lib/extension.js, fetchRelease().
# The tokens are held in variables rather than written inline: a literal
# `\$\{version\}` inside ${var//pattern/repl} is a well-known bash escaping
# trap (the `}` terminates the expansion early on some shells).
expand_template() {
  local template="$1" version="$2" release="$3" os="$4" arch="$5"
  local t_version='${version}' t_release='${release}'
  local t_os='${os}' t_arch='${arch}'
  template="${template//"${t_version}"/"${version}"}"
  template="${template//"${t_release}"/"${release}"}"
  template="${template//"${t_os}"/"${os}"}"
  template="${template//"${t_arch}"/"${arch}"}"
  echo "${template}"
}

MS_TAG="1.132.0"
RELEASE_VERSION="1.132.05296"
SUFFIX="$( reh_release_suffix "${RELEASE_VERSION}" "${MS_TAG}" )"

# What the extension will actually request. ${version} is vscode.version,
# which patches/10-version-add-release.patch pins to MS_TAG.
RESOLVED="$( expand_template "$( reh_url_template )" "${MS_TAG}" "${SUFFIX}" "linux" "x64" )"

# What prepare_assets.sh + the release job actually publish.
PUBLISHED="https://github.com/${GH_REPO_PATH}/releases/download/${RELEASE_VERSION}/$( reh_asset_name "linux" "x64" "${RELEASE_VERSION}" )"

assert_eq "${PUBLISHED}" "${RESOLVED}" \
  "resolved download URL matches the published asset URL"

assert_eq "https://github.com/bradford-tech/code/releases/download/1.132.05296/bradfordcode-reh-linux-x64-1.132.05296.tar.gz" \
  "${RESOLVED}" \
  "resolved download URL is the expected literal"

# The template must reach product.json with its tokens UNEXPANDED.
if [[ "$( reh_url_template )" == *'${version}${release}'* ]]; then
  echo "ok   - template keeps \${version}\${release} literal and adjacent"
else
  echo "FAIL - template must contain a literal, dot-free \${version}\${release}"
  echo "         actual: $( reh_url_template )"
  FAILURES=$(( FAILURES + 1 ))
fi

echo
if (( FAILURES > 0 )); then
  echo "${FAILURES} assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
