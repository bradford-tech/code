#!/usr/bin/env bash
# Asserts that merging a PR which advances upstream/stable.json triggers a
# release build of the newly pinned version, and that merging the resulting
# auto-release PR (which touches the same file) does NOT. Runs in ~100ms, no
# build, no network.
#
# Background: a Claude fix PR for a broken upstream tag bumps the pin to that
# tag. Once it merges, the cron's "upstream advanced past the pin" test is
# false, so the fixed version never shipped without a manual
# `force_build: true` dispatch (1.144.0, PR #118). The workflow now also runs
# on `push` to main filtered to upstream/stable.json and treats that like
# force_build — guarded by "does a release already cover this tag", because
# merging the auto-release PR is itself such a push and would otherwise
# rebuild every release forever.
#
# Release tags are MS_TAG + a 4-digit day/hour suffix (1.144.0 -> 1.144.00725),
# so the guard must match on exact shape, not "starts with": 1.144.1 is a
# prefix of a hypothetical 1.144.10 release.
#
# Runs the REAL "Compare and decide" step out of the workflow against stubbed
# `gh` and `git`, so the test cannot drift from the step it guards.
#
# Usage: ./dev/test-release-on-pin-merge.sh

set -eo pipefail

cd "$( dirname "${BASH_SOURCE[0]}" )/.." || exit 1
repo_root=$( pwd )
WF=".github/workflows/cron-build-and-release.yml"

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

# --- find_release_for_tag -------------------------------------------------
releases=$'1.143.16401\n1.144.00725\n1.144.00801\n1.144.10234\n1.144.100300\n1.144.1\nv1.144.00725'

assert_eq "1.144.00725" "$( find_release_for_tag "1.144.0" <<< "${releases}" )" \
  "pin 1.144.0 finds its release (first match wins)"
assert_eq "1.144.10234" "$( find_release_for_tag "1.144.1" <<< "${releases}" )" \
  "pin 1.144.1 finds 1.144.10234, not 1.144.00725"
assert_eq "1.144.100300" "$( find_release_for_tag "1.144.10" <<< "${releases}" )" \
  "pin 1.144.10 finds 1.144.100300, not the 1.144.1 release"
assert_eq "" "$( find_release_for_tag "1.145.0" <<< "${releases}" )" \
  "unreleased pin finds nothing"
assert_eq "" "$( find_release_for_tag "1.144.0" <<< $'1x144x00725\n1.144.0\n1.144.0725\n1.144.0abcd' )" \
  "dots are literal and the suffix must be exactly 4 digits"
assert_eq "" "$( find_release_for_tag "1.144.0" <<< "" )" \
  "empty release list finds nothing and does not fail"

# --- workflow trigger -----------------------------------------------------
on_block="$( sed -n '/^on:/,/^permissions:/p' "${WF}" )"
push_block="$( sed -n '/^  push:/,/^  [a-z_]*:/p' <<< "${on_block}" )"
if grep -q "^      - main" <<< "${push_block}" || grep -q "branches: \[main\]" <<< "${push_block}"; then
  echo "ok   - workflow triggers on push to main"
else
  echo "FAIL - workflow must trigger on push to main"
  FAILURES=$(( FAILURES + 1 ))
fi
if grep -q "upstream/stable.json" <<< "${push_block}"; then
  echo "ok   - push trigger is filtered to upstream/stable.json"
else
  echo "FAIL - push trigger must be filtered to upstream/stable.json"
  FAILURES=$(( FAILURES + 1 ))
fi

# --- run the real "Compare and decide" step -------------------------------
work=$( mktemp -d )
trap 'rm -rf "${work}"' EXIT

node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
  const i = lines.findIndex(l => l.includes("name: Compare and decide"));
  if (i < 0) throw new Error("step not found");
  const j = lines.findIndex((l, k) => k > i && l.trim() === "run: |");
  if (j < 0) throw new Error("run block not found");
  const indent = lines[j].search(/\S/) + 2;
  const out = [];
  for (let k = j + 1; k < lines.length; k++) {
    if (lines[k].trim() === "") { out.push(""); continue; }
    if (lines[k].search(/\S/) < indent) break;
    out.push(lines[k].slice(indent));
  }
  process.stdout.write(out.join("\n"));
' "${WF}" > "${work}/step.sh"
bash -n "${work}/step.sh" || { echo "FAIL - extracted step is not valid bash"; exit 1; }

# Stubs: `git ls-remote` answers with STUB_TAG_COMMIT for any tag; `gh release
# list` prints STUB_RELEASES one per line; `gh pr list` finds nothing. Every
# call is logged so the test can assert the guard is consulted only on push.
mkdir -p "${work}/bin"
cat > "${work}/bin/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "${STUB_LOG}"
if [[ "$1" == "ls-remote" ]]; then
  printf '%s\t%s\n' "${STUB_TAG_COMMIT}" "${@: -1}"
  exit 0
fi
echo "unexpected git call: $*" >&2; exit 1
EOF
cat > "${work}/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${STUB_LOG}"
case "$1 $2" in
  "release list") [[ -n "${STUB_RELEASES}" ]] && printf '%s\n' "${STUB_RELEASES}"; exit 0 ;;
  "pr list") exit 0 ;;
esac
echo "unexpected gh call: $*" >&2; exit 1
EOF
chmod +x "${work}/bin/git" "${work}/bin/gh"

# run_step <event> <force_build> <releases> ; sets OUT_needs_build / OUT_ms_tag
run_step() {
  local event="$1" force="$2" releases="$3"
  : > "${work}/out"
  : > "${work}/log"
  ( cd "${repo_root}" && \
    PATH="${work}/bin:${PATH}" \
    STUB_LOG="${work}/log" STUB_RELEASES="${releases}" STUB_TAG_COMMIT="c0ffee" \
    GITHUB_OUTPUT="${work}/out" GH_TOKEN="stub" \
    EVENT_NAME="${event}" FORCE_BUILD="${force}" \
    CURRENT_TAG="1.144.0" CURRENT_COMMIT="c0ffee" \
    UPSTREAM_TAG="1.144.0" UPSTREAM_COMMIT="c0ffee" \
    bash -e "${work}/step.sh" > "${work}/stdout" 2>&1 ) || {
      echo "FAIL - step exited non-zero for event=${event}"; cat "${work}/stdout"
      FAILURES=$(( FAILURES + 1 )); return
    }
  OUT_needs_build=$( sed -n 's/^needs_build=//p' "${work}/out" )
  OUT_ms_tag=$( sed -n 's/^ms_tag=//p' "${work}/out" )
}

# 1. Fix PR merged: pin advanced to 1.144.0, no release for it yet -> build it.
run_step push "" $'1.143.16401\n1.143.06112'
assert_eq "true" "${OUT_needs_build}" "push with unreleased pin builds"
assert_eq "1.144.0" "${OUT_ms_tag}" "push builds the PINNED tag"

# 2. Auto-release PR merged: a release already covers the pin -> skip.
run_step push "" $'1.144.00725\n1.143.16401'
assert_eq "false" "${OUT_needs_build}" "push with an already-released pin skips (no rebuild loop)"
if grep -q "1.144.00725" "${work}/stdout"; then
  echo "ok   - skip reason names the existing release"
else
  echo "FAIL - skip reason should name the existing release"; cat "${work}/stdout"
  FAILURES=$(( FAILURES + 1 ))
fi

# 3. Only a neighbouring tag's release exists -> still build.
run_step push "" $'1.144.10234'
assert_eq "true" "${OUT_needs_build}" "push ignores releases of other tags (1.144.1 is not 1.144.0)"

# 4. Cron with upstream == pin is unchanged: skip, and never consult releases.
run_step schedule "" $'1.144.00725'
assert_eq "false" "${OUT_needs_build}" "cron with upstream matching the pin still skips"
if grep -q "gh release list" "${work}/log"; then
  echo "FAIL - cron should not query releases"; FAILURES=$(( FAILURES + 1 ))
else
  echo "ok   - cron does not query releases"
fi

# 5. force_build stays explicit: builds even when a release exists.
run_step workflow_dispatch true $'1.144.00725'
assert_eq "true" "${OUT_needs_build}" "force_build builds even when a release already exists"

echo
if (( FAILURES > 0 )); then
  echo "${FAILURES} assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
