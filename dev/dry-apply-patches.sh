#!/usr/bin/env bash
# Dry-applies every patch in CI order and reports EVERY one that fails.
#
# Why this exists: prepare_vscode.sh halts on the first rejection, so a failing
# build log only ever names one broken patch. After an upstream bump several are
# usually broken at once (1.133.0 broke four; 1.124.0 broke two). Fixing them one
# per CI round trip cannot converge inside the claude-build-fix attempt cap, and
# each partial fix looks "done" until the next build reveals the next break.
#
# This applies patches sequentially against a real tree — matching CI semantics,
# where later patches see earlier patches' changes — but continues past failures
# so one run enumerates the whole set. `--check`-ing each patch against a
# pristine tree instead would report false breaks for patches that legitimately
# depend on an earlier one.
#
# Usage:
#   ./dev/dry-apply-patches.sh                 # against the pinned commit
#   ./dev/dry-apply-patches.sh --commit <sha>  # roll vscode/ forward first
#   ./dev/dry-apply-patches.sh --verbose       # show each rejection in full
#
# Exits 0 when every patch applies, 1 when any fails (so CI/agents can gate).
# Leaves vscode/ patched; re-run with a clean tree for repeatable results.

set -eo pipefail

cd "$( dirname "${BASH_SOURCE[0]}" )/.." || exit 1

COMMIT=""
VERBOSE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit) COMMIT="$2"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

: "${OS_NAME:=osx}"
: "${VSCODE_QUALITY:=stable}"

# shellcheck disable=SC1091
. utils.sh

if [[ ! -d vscode ]]; then
  echo "vscode/ not found. Clone it first:" >&2
  echo "  commit=\$(jq -r '.commit' upstream/stable.json)" >&2
  echo "  git clone --filter=blob:none --no-checkout https://github.com/microsoft/vscode.git vscode" >&2
  echo "  ( cd vscode && git fetch --depth 1 origin \"\$commit\" && git checkout FETCH_HEAD )" >&2
  exit 2
fi

# Clean FIRST, then roll forward. The tree is almost always dirty when this
# script runs — it leaves patches applied, and any earlier diagnosis does too —
# and `git checkout` refuses to move with local modifications ("Please commit
# your changes or stash them"). Cleaning after the checkout, as this did
# originally, meant --commit failed exactly when you needed it most: on the
# second run.
( cd vscode && git reset --hard -q HEAD && git clean -fdxq )

if [[ -n "${COMMIT}" ]]; then
  if ! printf '%s' "${COMMIT}" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "--commit must be a 40-char hex SHA: '${COMMIT}'" >&2
    exit 2
  fi
  echo "Rolling vscode/ to ${COMMIT}"
  ( cd vscode && git fetch --depth 1 origin "${COMMIT}" -q && git checkout -q --detach FETCH_HEAD )
  ( cd vscode && git reset --hard -q HEAD && git clean -fdxq )
fi

echo "Tree at: $( cd vscode && git rev-parse HEAD )"
echo

# Same order prepare_vscode.sh uses. Keep in sync with its patch loop.
collect_patches() {
  local f
  for f in patches/*.patch; do [[ -f "$f" ]] && echo "$f"; done
  if [[ "${VSCODE_QUALITY}" == "insider" ]]; then
    for f in patches/insider/*.patch; do [[ -f "$f" ]] && echo "$f"; done
  fi
  if [[ -d "patches/${OS_NAME}/" ]]; then
    for f in "patches/${OS_NAME}/"*.patch; do [[ -f "$f" ]] && echo "$f"; done
  fi
  for f in patches/user/*.patch; do [[ -f "$f" ]] && echo "$f"; done
}

BROKEN=()
while IFS= read -r patch; do
  # Subshell: apply_patch calls `exit 1` on failure, which would end this script.
  # utils.sh restores the tokenized patch file on both paths, so a failure here
  # does not mutate patches/ (dev/test-apply-patch-restore.sh locks that down).
  if err="$( cd vscode && apply_patch "../${patch}" quiet 2>&1 )"; then
    printf '  ok      %s\n' "$( basename "${patch}" )"
  else
    printf '  BROKEN  %s\n' "$( basename "${patch}" )"
    BROKEN+=( "${patch}" )
    if (( VERBOSE )); then
      printf '%s\n' "${err}" | sed 's/^/            /'
    else
      printf '%s\n' "${err}" | grep -E '^error' | head -3 | sed 's/^/            /' || true
    fi
  fi
done < <( collect_patches )

echo
if (( ${#BROKEN[@]} == 0 )); then
  echo "All patches apply cleanly."
  exit 0
fi

echo "${#BROKEN[@]} patch(es) need rebasing against this commit:"
for p in "${BROKEN[@]}"; do echo "  ${p}"; done
echo
echo "Rebase ALL of them before pushing — prepare_vscode.sh halts at the first,"
echo "so fixing one at a time hides the rest until the next build."
exit 1
