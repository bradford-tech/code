#!/usr/bin/env bash
# Regression test for the release-branch/workflow-permission race that took
# run 33795347082 down after both builds had already passed.
#
# The cron build takes ~15 min. If main moves during it (dependabot's
# action-pin bumps land in .github/workflows/), a release branch cut from the
# run's own checked-out SHA carries workflow files that differ from the default
# branch. GITHUB_TOKEN is a GitHub App token with no `workflows` permission
# (there is no such key for `permissions:`, so it cannot be granted), and
# GitHub refuses the push:
#
#   ! [remote rejected] release/X -> release/X (refusing to allow a GitHub App
#     to create or update workflow `.github/workflows/claude-build-fix.yml`
#     without `workflows` permission)
#
# GitHub compares the pushed branch's workflow files against the default
# branch's — NOT the diff of the new commit — which is why a commit touching
# only upstream/stable.json + latest.json is still rejected. This harness
# asserts on exactly that comparison.
#
# It extracts and runs the REAL "Create release branch and push" step out of
# .github/workflows/cron-build-and-release.yml, so it cannot drift from the
# workflow it guards.
#
# Usage: ./dev/test-release-branch-race.sh
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflow="$repo_root/.github/workflows/cron-build-and-release.yml"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- extract the step's `run:` body verbatim ---------------------------------
extract_step() {
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
    const i = lines.findIndex(l => l.includes("name: Create release branch and push"));
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
  ' "$1"
}
extract_step "$workflow" > "$work/step.sh"
bash -n "$work/step.sh" || { echo "FAIL: extracted step is not valid bash"; exit 1; }

# --- build a fake origin whose main advances mid-build -----------------------
git init --quiet --bare "$work/origin.git" --initial-branch=main
git clone --quiet "$work/origin.git" "$work/seed" 2>/dev/null
(
  cd "$work/seed"
  git config user.email t@t; git config user.name t
  mkdir -p .github/workflows versions/stable/darwin-arm64 upstream
  echo "uses: some/action@v1" > .github/workflows/claude-build-fix.yml
  echo '{"tag":"1.135.0","commit":"old"}' > upstream/stable.json
  echo '{"name":"1.135.0"}' > versions/stable/darwin-arm64/latest.json
  git add -A && git commit --quiet -m "base"
  git push --quiet origin main
)

# The runner checks out main here, then builds for ~15 minutes.
git clone --quiet "$work/origin.git" "$work/runner"
run_sha=$(git -C "$work/runner" rev-parse HEAD)

# Mid-build, dependabot's action-pin bump merges to main.
(
  cd "$work/seed"
  echo "uses: some/action@v2" > .github/workflows/claude-build-fix.yml
  git commit --quiet -am "chore(deps): bump some/action"
  git push --quiet origin main
)

# Post-build state: the two release files regenerated in the working tree by
# the preceding workflow steps, HEAD still at the stale run SHA.
cd "$work/runner"
git config user.email t@t; git config user.name t
git checkout --quiet -B main "$run_sha"
echo '{"tag":"1.136.0","commit":"520fb30"}' > upstream/stable.json
echo '{"name":"1.136.05923"}' > versions/stable/darwin-arm64/latest.json
mkdir -p assets && echo binary > assets/BradfordCode.dmg   # untracked build output

export RELEASE_VERSION=1.136.05923 MS_TAG=1.136.0
export GITHUB_OUTPUT="$work/github_output"
: > "$GITHUB_OUTPUT"

bash "$work/step.sh"

fail=0
pass() { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

git fetch --quiet --no-tags origin main
branch=release/1.136.05923

# 1. The condition GitHub actually rejects on.
drift=$(git diff --name-only FETCH_HEAD.."$branch" -- .github/workflows/)
[ -z "$drift" ] && pass "workflow files identical to main -> push allowed" \
  || bad "branch still drifts workflow files -> push would be rejected: $drift"

# 2. The release commit must still carry both files.
changed=$(git diff --name-only FETCH_HEAD.."$branch" | sort | tr '\n' ' ')
[ "$changed" = "upstream/stable.json versions/stable/darwin-arm64/latest.json " ] \
  && pass "release commit changes exactly the two release files" \
  || bad "expected exactly the two release files, got [$changed]"

# 3. ...with the regenerated content, not the pre-reset content.
if grep -q 520fb30 upstream/stable.json && grep -q 1.136.05923 versions/stable/darwin-arm64/latest.json; then
  pass "regenerated release-file contents survived the branch cut"
else
  bad "regenerated release files were lost"
fi

# 4. Descends from current main, so the auto-release PR merges cleanly and the
#    `gh release create --target` tag doesn't advertise a stale tree.
git merge-base --is-ancestor FETCH_HEAD "$branch" \
  && pass "release branch descends from current origin/main" \
  || bad "release branch is not a descendant of current main"

# 5. The branch cut must not destroy untracked build artifacts.
[ -f assets/BradfordCode.dmg ] && pass "untracked assets/ survived the branch cut" \
  || bad "assets/ was destroyed — the Release upload would fail"

# 6. The step still reports its branch to later steps.
grep -qx "branch=$branch" "$GITHUB_OUTPUT" \
  && pass "step emitted branch=$branch to \$GITHUB_OUTPUT" \
  || bad "missing branch= in \$GITHUB_OUTPUT: $(cat "$GITHUB_OUTPUT")"

exit "$fail"
