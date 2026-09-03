# Build-fix playbook

The operating manual for fixing a broken BradfordCode build — written for the
`claude-build-fix.yml` CI loop, equally useful to a human. This file is
**tracked** precisely so the CI fix session has it; keep it current when a new
failure class or gotcha is discovered.

## What this repo is

A **build recipe**, not an editor source tree. Each build downloads upstream
Microsoft VS Code source at the commit pinned in `upstream/stable.json`,
applies `patches/*.patch` plus a `product.json` overlay plus a `src/stable/`
file overlay, then compiles and packages a macOS arm64 app (and a linux-x64
remote extension host). When upstream releases a new version, one or more
patches usually stop applying — that is the normal failure this playbook fixes.

## The three substitution mechanisms

1. **Token replacement** — patches contain literal placeholders
   (`!!APP_NAME!!`, `!!BINARY_NAME!!`, `!!GH_REPO_PATH!!`,
   `!!RELEASE_VERSION!!`). `apply_patch()` in `utils.sh` substitutes them into
   a temp copy before `git apply` and restores the original file afterwards.
   **A patch file must keep its `!!TOKEN!!` placeholders.** If you regenerate a
   patch, produce it from a tree where the tokens were applied RAW (no
   substitution) so `git diff` reproduces the tokens. If a patch ever contains
   a literal `BradfordCode` where `!!APP_NAME!!` should be, run
   `git checkout -- patches/` before anything else — committing it breaks the
   token mechanism for every future build.
2. **`product.json` overlay** — the repo-root `product.json` is jq-merged over
   upstream's in `prepare_vscode.sh`, which also sets many fields
   imperatively.
3. **`src/stable/` overlay** — files copied wholesale into `vscode/` before
   patching (icons, letterpress SVGs, `code.icns`).

## Patch ordering

`NN-area-description.patch`. `00-*` are mutually independent. In multi-digit
groups (`10-*`, `11-*`, `12-*`) index N depends on indices 0..N-1 of the same
group. `patches/osx/` applies after the top-level patches. Patches apply
**sequentially against one tree** — later patches legitimately depend on
earlier ones.

## Step 1 — Diagnose

```bash
gh run view <run-id> --log-failed
```

Historical failure classes, most→least common:

- **Patch apply rejections** after an upstream version bump (the `00-ext-github-*`
  pair is the most fragile; 1.133.0 broke four patches at once).
- **TypeScript errors in `compile-src`** from dangling references after our
  patches remove code upstream now uses.
- **`vscode-min-prepack` ASCII hygiene check** rejecting non-ASCII regex
  literals introduced by a patch.
- **Native module ABI mismatch** (`NODE_MODULE_VERSION`) after a Node version
  bump — check `.nvmrc` against upstream's `vscode/.nvmrc`.

**Check which job failed before assuming it's a patch problem.** `release`
failures look like build failures in the issue text but have nothing to do with
patches. If `build` and `build-reh` are green, skip straight to the release job's
log — see "Release-job failures" below.

## Release-job failures

The `release` job runs ~15 minutes after checkout, and **main moves under it**
(dependabot bumps action pins inside `.github/workflows/`). Anything that cuts a
branch from the run's own `GITHUB_SHA` is racing.

`GITHUB_TOKEN` is a GitHub App token with **no `workflows` permission**, and
there is no `workflows:` key for `permissions:` — it cannot be granted. So a push
is rejected whenever the pushed branch's workflow files differ from the default
branch's:

```
! [remote rejected] release/X -> release/X (refusing to allow a GitHub App to
  create or update workflow `.github/workflows/claude-build-fix.yml` without
  `workflows` permission)
```

The trap: GitHub compares the branch's workflow files **against the default
branch**, not the diff of the commits being pushed. A release commit touching
only `upstream/stable.json` + `latest.json` is still rejected, so the error names
a file the commit never touched and reads like a permissions bug rather than the
staleness bug it is. Cost run 33795347082 a full release after both builds had
already passed.

Fix pattern: `git fetch origin main` and cut the branch from `FETCH_HEAD`,
re-applying generated files on top — never from the checked-out SHA. Guarded by
`./dev/test-release-branch-race.sh`, which extracts and runs the real workflow
step, so it cannot drift from the step it guards.

**Fixing this class means editing a workflow file, which the fix-loop's own
`claude[bot]` token may likewise be unable to push.** If the push is rejected,
say so in the PR/issue and hand it to a human rather than routing the change
somewhere else — a shell script called *from* the workflow still requires editing
the workflow.

## Step 2 — Enumerate every broken patch

```bash
./dev/dry-apply-patches.sh                 # against the staged vscode/ tree
./dev/dry-apply-patches.sh --commit <sha>  # roll the tree forward first
./dev/dry-apply-patches.sh --verbose       # full rejection text
```

`prepare_vscode.sh` halts at the *first* rejection, so a failing build log
names exactly one patch even when several are broken. Dry-apply continues past
failures and names them all. **Never** hand-roll a loop that stops at the first
failure, and **never** `git apply --check` each patch against a pristine tree —
later patches depend on earlier ones and will report false breaks.

## Step 3 — Fix, then verify BEFORE pushing

```bash
CI_BUILD=yes ./dev/ci-verify.sh --commit <target-sha>   # prepare + npm ci + compile
CI_BUILD=yes ./dev/ci-verify.sh --full ...              # adds vscode-min-prepack (minify + ASCII check)
./dev/ci-verify.sh --skip-prepare                       # re-run compile only (fast inner loop)
```

Patches *applying* is necessary, not sufficient — the compile runs after, and a
type-level mistake never shows up in a dry-apply. The efficient inner loop:

1. Prototype the fix by editing `vscode/` directly; `--skip-prepare` re-runs
   the (incremental) compile in minutes.
2. When it compiles, regenerate the patch from the tree's diff (tokens intact).
3. Run one full `ci-verify.sh` from a clean tree to prove the regenerated
   patch reproduces the fix.

State the verification tier you actually reached in the PR body ("compile
passed", "full prepack passed", or "could not verify: <why>"). Never imply a
verified fix without a passing run.

## Regenerated-patch checklist

- **Deletions survive?** `git apply --reject` cannot delete a file whose
  content drifted and emits **no** `.rej` for it — the deletion silently
  vanishes from a regenerated patch. Compare `deleted file mode` counts old vs
  new.
- **No dangling imports** of modules the patch deletes.
- **New upstream files** importing something we remove? Grep the removed
  package across `src/` (1.133.0 added three files importing the removed
  `@github/copilot-sdk`).
- **Local type aliases still match usage.** An alias standing in for a removed
  SDK type goes stale silently: 1.133.0's `getPermissionDisplay` grew from
  reading one field to nine, and the inherited `{ kind: ... }` alias applied
  cleanly then failed the build with ten TS2339s. Grep every property access
  against the alias.

## Pin consistency

A PR-triggered build always builds the version pinned in
`upstream/stable.json` — not the version your patches target. If the fix is
for a newer upstream tag, the fix PR **must also bump `upstream/stable.json`**
(both `tag` and `commit`), or the PR build clones the old tree and fails
instantly. This exact miss cost an attempt on 1.134.0.

**The commit hash must be the git tag's, not the update API's.** Microsoft's
update API and git tag can name different commits for the same version
(1.134.0: API `110a328`, tag `474a349` after a re-tag), and `get_repo.sh`
silently builds the git-authoritative hash. Always resolve the pin with:

```bash
git ls-remote https://github.com/microsoft/vscode.git "refs/tags/<tag>"
```

Symptom of getting this wrong: dry-apply and ci-verify green on the staged
tree, while CI rejects the same patches with "patch does not apply" in
seconds — you are verifying a commit CI never builds. If CI failures make no
sense against your local tree, compare `git rev-parse HEAD` in `vscode/`
against the failing build log's "checkout" / get_repo output (it prints a
warning when it swaps hashes) before touching any patch.

## Warm start (CI loop)

Before touching anything: read the failure issue's thread (prior attempt
comments) and look for an existing fix PR:

```bash
gh pr list --search "Refs #<issue> in:body state:open" --json number,headRefName,author
```

If one exists and its author is `claude[bot]`, read its commits and comments,
then **push to its branch** (`git fetch origin && git switch <headRefName>`).
Duplicate PRs split the fix across orphan branches that can never merge.

## Loop contract

- One PR per issue. The PR body must contain `Refs #<issue>` on its own line —
  the cron's `report-pr-failure` job parses it to dispatch the next iteration.
- Never push to main. Never force-push. Never merge.
- When the PR's build goes green, the cron hands it to a human for review;
  when a release for the tag succeeds, the issue closes automatically.
