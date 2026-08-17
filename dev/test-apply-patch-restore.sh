#!/usr/bin/env bash
# Asserts apply_patch always restores the tokenized patch file, including when
# `git apply` fails.
#
# Why this matters: apply_patch rewrites !!TOKEN!! placeholders IN PLACE, keeping
# a .bak to restore afterwards. The restore used to sit after an `exit 1`, so a
# failed apply left the patch on disk with tokens already substituted. Anyone
# dry-applying patches to diagnose a break (the pattern documented in CLAUDE.md,
# and what the claude-build-fix loop is told to do) would silently corrupt every
# patch that failed — and committing that bakes literal values in, breaking the
# token mechanism for every other build.
#
# Runs in ~50ms; no build, no vscode/ checkout.
#
# Usage: ./dev/test-apply-patch-restore.sh

set -eo pipefail

cd "$( dirname "${BASH_SOURCE[0]}" )/.." || exit 1

REPO_ROOT="$( pwd )"
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

WORK="$( mktemp -d )"
trap 'rm -rf "${WORK}"' EXIT

# A git repo for git-apply to operate in.
git init -q "${WORK}/tree"
cd "${WORK}/tree"
git config user.email x@y; git config user.name x
printf 'original line\n' > file.txt
git add file.txt && git commit -q -m init

# --- Patch that APPLIES, carrying a token on an added line ----------------
cat > "${WORK}/good.patch" <<'EOF'
diff --git a/file.txt b/file.txt
--- a/file.txt
+++ b/file.txt
@@ -1 +1,2 @@
 original line
+built by !!APP_NAME!!
EOF

# --- Patch that FAILS: its context does not match ------------------------
cat > "${WORK}/bad.patch" <<'EOF'
diff --git a/file.txt b/file.txt
--- a/file.txt
+++ b/file.txt
@@ -1 +1,2 @@
 THIS CONTEXT DOES NOT MATCH
+built by !!APP_NAME!!
EOF

cp "${WORK}/good.patch" "${WORK}/good.orig"
cp "${WORK}/bad.patch" "${WORK}/bad.orig"

# shellcheck disable=SC1091
. "${REPO_ROOT}/utils.sh"

# --- Success path ---------------------------------------------------------
# apply_patch calls `exit` on failure, so run each in a subshell.
( apply_patch "${WORK}/good.patch" quiet ) >/dev/null 2>&1 || true
assert_eq "$( cat "${WORK}/good.orig" )" "$( cat "${WORK}/good.patch" )" \
  "successful apply leaves the patch file tokenized"
assert_eq "1" "$( grep -c '!!APP_NAME!!' "${WORK}/good.patch" )" \
  "successful apply preserves !!APP_NAME!!"

# The substitution must still have reached the working tree.
assert_eq "built by BradfordCode" "$( sed -n '2p' file.txt )" \
  "successful apply substitutes the token in the applied output"

# --- Failure path (the regression this test exists for) -------------------
( apply_patch "${WORK}/bad.patch" quiet ) >/dev/null 2>&1 || true
assert_eq "$( cat "${WORK}/bad.orig" )" "$( cat "${WORK}/bad.patch" )" \
  "FAILED apply still leaves the patch file tokenized"
assert_eq "1" "$( grep -c '!!APP_NAME!!' "${WORK}/bad.patch" )" \
  "FAILED apply preserves !!APP_NAME!! (not substituted in place)"

# No stray .bak should survive either path.
leftover="$( find "${WORK}" -name '*.patch.bak' | wc -l | tr -d ' ' )"
assert_eq "0" "${leftover}" "no .bak files left behind"

echo
if (( FAILURES > 0 )); then
  echo "${FAILURES} assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
