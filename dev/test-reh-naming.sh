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

# --- prepare_vscode.sh wiring ---------------------------------------------
# Both channel branches must set `release` and `serverDownloadUrlTemplate`.
for field in "release" "serverDownloadUrlTemplate"; do
  count="$( grep -c "setpath \"product\" \"${field}\"" prepare_vscode.sh || true )"
  assert_eq "2" "${count}" \
    "prepare_vscode.sh sets product.${field} in both channel branches"
done

# utils.sh defines the reh_* helpers, so it must be sourced BEFORE the
# product.json block that calls them — it used to be sourced further down,
# next to the patch loop, where the helpers would not yet exist.
# `|| true` on both: grep exits 1 when there is no match, and `set -o pipefail`
# would otherwise abort this script before the assertion could report.
utils_line="$( grep -n '^\. \.\./utils\.sh' prepare_vscode.sh | head -1 | cut -d: -f1 || true )"
tmpl_line="$( grep -n 'reh_url_template' prepare_vscode.sh | head -1 | cut -d: -f1 || true )"
if [[ -n "${utils_line}" && -n "${tmpl_line}" ]] && (( utils_line < tmpl_line )); then
  echo "ok   - prepare_vscode.sh sources utils.sh before calling reh_* helpers"
else
  echo "FAIL - utils.sh must be sourced before the reh_* helpers are called"
  echo "         . ../utils.sh at line ${utils_line:-<none>}, reh_url_template at line ${tmpl_line:-<none>}"
  FAILURES=$(( FAILURES + 1 ))
fi

# --- build.sh REH target --------------------------------------------------
if grep -q 'vscode-reh-\${VSCODE_PLATFORM}-\${VSCODE_ARCH}-min-ci' build.sh; then
  echo "ok   - build.sh invokes the REH gulp target"
else
  echo "FAIL - build.sh has no REH gulp target"
  FAILURES=$(( FAILURES + 1 ))
fi

if grep -q 'if \[\[ "\${OS_NAME}" == "osx" \]\]; then' build.sh; then
  echo "ok   - build.sh gates the darwin client steps on OS_NAME"
else
  echo "FAIL - build.sh does not gate the darwin client steps on OS_NAME"
  FAILURES=$(( FAILURES + 1 ))
fi

# --- prepare_assets.sh packaging ------------------------------------------
if grep -q 'reh_asset_name' prepare_assets.sh; then
  echo "ok   - prepare_assets.sh names the tarball via reh_asset_name"
else
  echo "FAIL - prepare_assets.sh does not use reh_asset_name"
  FAILURES=$(( FAILURES + 1 ))
fi

# The tarball MUST be created from inside the build dir (trailing ` .`), so
# that `tar --strip-components 1` on the remote yields bin/code-server.
if grep -q 'tar czf "../assets/${REH_ASSET}" \.' prepare_assets.sh; then
  echo "ok   - REH tarball is created from inside the build directory"
else
  echo "FAIL - REH tarball must be created from inside the build directory"
  FAILURES=$(( FAILURES + 1 ))
fi

# --- CI wiring ------------------------------------------------------------
WF=".github/workflows/cron-build-and-release.yml"

if grep -q '^  build-reh:' "${WF}"; then
  echo "ok   - workflow defines the build-reh job"
else
  echo "FAIL - workflow has no build-reh job"
  FAILURES=$(( FAILURES + 1 ))
fi

# The macOS client job must keep REH off.
if grep -q 'SHOULD_BUILD_REH: "no"' "${WF}"; then
  echo "ok   - macOS client job still has SHOULD_BUILD_REH: no"
else
  echo "FAIL - macOS client job must keep SHOULD_BUILD_REH: no"
  FAILURES=$(( FAILURES + 1 ))
fi

if grep -q "needs\['build-reh'\]" "${WF}"; then
  echo "ok   - release job gates on build-reh"
else
  echo "FAIL - release job does not gate on build-reh"
  FAILURES=$(( FAILURES + 1 ))
fi

# Scoped to the `gh release create` invocation specifically — a bare grep of
# the whole file would match the build-reh job's own references and pass even
# with the release job left unwired.
if sed -n '/gh release create/,/^$/p' "${WF}" \
     | grep -q 'assets/bradfordcode-reh-linux-x64-\${RELEASE_VERSION}.tar.gz"'; then
  echo "ok   - gh release create uploads the REH tarball"
else
  echo "FAIL - gh release create does not upload the REH tarball"
  FAILURES=$(( FAILURES + 1 ))
fi

if sed -n '/gh release create/,/^$/p' "${WF}" \
     | grep -q 'assets/bradfordcode-reh-linux-x64-\${RELEASE_VERSION}.tar.gz.sha256"'; then
  echo "ok   - gh release create uploads the REH SHA-256 sidecar"
else
  echo "FAIL - gh release create does not upload the REH SHA-256 sidecar"
  FAILURES=$(( FAILURES + 1 ))
fi

echo
if (( FAILURES > 0 )); then
  echo "${FAILURES} assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
