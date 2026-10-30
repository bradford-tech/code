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

# Stubs: `git ls-remote` answers with STUB_TAG_COMMIT for any tag (nothing
# when it is empty, as git does for a missing tag; exit 128 when
# STUB_GIT_FAIL is set, as for a network failure); `gh release list` prints
# STUB_RELEASES one per line. Every call is logged.
mkdir -p "${work}/bin"
cat > "${work}/bin/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "${STUB_LOG}"
if [[ "$1" == "ls-remote" ]]; then
  [[ -n "${STUB_GIT_FAIL}" ]] && { echo "fatal: unable to access (stub)" >&2; exit 128; }
  [[ -n "${STUB_TAG_COMMIT}" ]] && printf '%s\t%s\n' "${STUB_TAG_COMMIT}" "${@: -1}"
  exit 0
fi
echo "unexpected git call: $*" >&2; exit 1
EOF
cat > "${work}/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${STUB_LOG}"
case "$1 $2" in
  "release list") [[ -n "${STUB_RELEASES}" ]] && printf '%s\n' "${STUB_RELEASES}"; exit 0 ;;
esac
echo "unexpected gh call: $*" >&2; exit 1
EOF
chmod +x "${work}/bin/git" "${work}/bin/gh"

# The pin is always 1.144.0 @ c0ffee. Upstream-latest and what the git tag
# resolves to are per-case knobs.
#   run_step <event> <force_build> <releases> [upstream_tag] [tag_commit]
# Sets OUT_needs_build / OUT_ms_tag / OUT_ms_commit. The step is run under
# `bash -e`, which is what Actions uses for a `run:` with no `shell:` key
# (pipefail is NOT on there). With EXPECT_FAIL=1 a non-zero exit is the pass.
run_step() {
  local event="$1" force="$2" releases="$3" upstream_tag="${4:-1.144.0}" tag_commit="${5-c0ffee}"
  : > "${work}/out"
  : > "${work}/log"
  if ( cd "${repo_root}" && \
    PATH="${work}/bin:${PATH}" \
    STUB_LOG="${work}/log" STUB_RELEASES="${releases}" STUB_TAG_COMMIT="${tag_commit}" \
    STUB_GIT_FAIL="${STUB_GIT_FAIL:-}" \
    GITHUB_OUTPUT="${work}/out" GH_TOKEN="stub" \
    EVENT_NAME="${event}" FORCE_BUILD="${force}" \
    CURRENT_TAG="1.144.0" CURRENT_COMMIT="c0ffee" \
    UPSTREAM_TAG="${upstream_tag}" UPSTREAM_COMMIT="${tag_commit}" \
    bash -e "${work}/step.sh" > "${work}/stdout" 2>&1 ); then
    if [[ -n "${EXPECT_FAIL:-}" ]]; then
      echo "FAIL - step should have exited non-zero (event=${event})"; cat "${work}/stdout"
      FAILURES=$(( FAILURES + 1 ))
    fi
  else
    if [[ -z "${EXPECT_FAIL:-}" ]]; then
      echo "FAIL - step exited non-zero for event=${event}"; cat "${work}/stdout"
      FAILURES=$(( FAILURES + 1 ))
    fi
  fi
  OUT_needs_build=$( sed -n 's/^needs_build=//p' "${work}/out" )
  OUT_ms_tag=$( sed -n 's/^ms_tag=//p' "${work}/out" )
  OUT_ms_commit=$( sed -n 's/^ms_commit=//p' "${work}/out" )
}

assert_reason_names() {
  if grep -q -- "$1" "${work}/stdout"; then
    echo "ok   - ${2}"
  else
    echo "FAIL - ${2}"; sed 's/^/         /' "${work}/stdout"
    FAILURES=$(( FAILURES + 1 ))
  fi
}

# --- push: the pin just changed on main -------------------------------------
# 1. Fix PR merged: pin advanced to 1.144.0, no release for it yet -> build it.
run_step push "" $'1.143.16401\n1.143.06112'
assert_eq "true" "${OUT_needs_build}" "push with unreleased pin builds"
assert_eq "1.144.0" "${OUT_ms_tag}" "push builds the PINNED tag"

# 2. Auto-release PR merged: a release already covers the pin -> skip.
run_step push "" $'1.144.00725\n1.143.16401'
assert_eq "false" "${OUT_needs_build}" "push with an already-released pin skips (no rebuild loop)"
assert_reason_names "1.144.00725" "skip reason names the existing release"

# 3. Only a neighbouring tag's release exists -> still build.
run_step push "" $'1.144.10234'
assert_eq "true" "${OUT_needs_build}" "push ignores releases of other tags (1.144.1 is not 1.144.0)"

# --- schedule: the same guard answers "already built?" for the cron ---------
# 4. Upstream == pin and the pin is released: the steady state, skip.
run_step schedule "" $'1.144.00725'
assert_eq "false" "${OUT_needs_build}" "cron with upstream == pin and a release skips"

# 5. Upstream == pin but nothing released it (missed push event, failed
#    release build): the cron picks it up instead of waiting for upstream.
run_step schedule "" $'1.143.16401'
assert_eq "true" "${OUT_needs_build}" "cron with upstream == pin and NO release builds the pin"
assert_eq "1.144.0" "${OUT_ms_tag}" "...and targets the pin"

# 6. Upstream advanced, nothing released it -> build upstream at the git tag's
#    commit (the API hash is deliberately not trusted).
run_step schedule "" $'1.144.00725' "1.145.0" "tag5"
assert_eq "true" "${OUT_needs_build}" "cron with upstream advanced and no release builds"
assert_eq "1.145.0" "${OUT_ms_tag}" "...targets upstream-latest"
assert_eq "tag5" "${OUT_ms_commit}" "...at the git tag's commit"

# 7. Upstream advanced and already released (its auto-release PR is waiting
#    for a human, or was closed unmerged) -> skip. This used to be a search
#    for an OPEN auto-release PR by title, which rebuilt and re-published
#    daily once that PR was closed.
run_step schedule "" $'1.145.00800\n1.144.00725' "1.145.0" "tag5"
assert_eq "false" "${OUT_needs_build}" "cron with upstream advanced but already released skips"
assert_reason_names "1.145.00800" "skip reason names the existing release"

# 8. Update API announced a tag microsoft/vscode hasn't pushed yet -> skip
#    with that reason, never "no release yet; building the pin".
run_step schedule "" $'1.144.00725' "1.145.0" ""
assert_eq "false" "${OUT_needs_build}" "cron with an unpushed upstream tag skips"
assert_reason_names "hasn't pushed the tag yet" "skip reason says the tag is not pushed yet"

# 9. `git ls-remote` failing (network) must fail the step loudly, not read
#    as "tag absent". Under `bash -e` without pipefail, a `git | awk`
#    pipeline cannot do that.
EXPECT_FAIL=1 STUB_GIT_FAIL=1 run_step schedule "" "" "1.145.0" "tag5"
echo "ok   - git ls-remote failure fails the step (checked above)"

# --- explicit builds bypass the guard ---------------------------------------
# 10. force_build builds even when a release exists.
run_step workflow_dispatch true $'1.144.00725'
assert_eq "true" "${OUT_needs_build}" "force_build builds even when a release already exists"

# 11. A PR always verifies its pin, released or not.
run_step pull_request "" $'1.144.00725'
assert_eq "true" "${OUT_needs_build}" "pull_request builds even when a release already exists"

# --- one guard, not two -----------------------------------------------------
if grep -q 'in:title' "${work}/step.sh"; then
  echo "FAIL - step still searches open auto-release PRs by title; the release guard replaces that"
  FAILURES=$(( FAILURES + 1 ))
else
  echo "ok   - step does not duplicate the guard with an open-PR title search"
fi

echo
if (( FAILURES > 0 )); then
  echo "${FAILURES} assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
