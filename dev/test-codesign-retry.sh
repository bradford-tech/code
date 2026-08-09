#!/usr/bin/env bash
# Asserts build/osx/codesign-with-retry.sh retries transient Apple timestamp
# failures, fails fast on real signing errors, and gives up after the cap.
# Uses a stub command instead of a real codesign pass, so it runs in ~50ms and
# needs no certificate, no keychain and no build.
#
# Usage: ./dev/test-codesign-retry.sh

set -eo pipefail

cd "$( dirname "${BASH_SOURCE[0]}" )/.." || exit 1

RETRY="./build/osx/codesign-with-retry.sh"
FAILURES=0
WORK="$( mktemp -d )"
trap 'rm -rf "${WORK}"' EXIT

# Stub that fails its first `fail_times` invocations with `message`, then
# succeeds. Records one line per invocation so we can count attempts.
make_stub() {
  local path="$1" fail_times="$2" message="$3"
  cat > "${path}" <<EOF
#!/usr/bin/env bash
count_file="\$( dirname "\$0" )/count"
echo x >> "\${count_file}"
attempts=\$( wc -l < "\${count_file}" | tr -d ' ' )
if (( attempts <= ${fail_times} )); then
  echo "${message}" >&2
  exit 1
fi
echo "signing succeeded"
EOF
  chmod +x "${path}"
}

attempts_made() {
  wc -l < "${WORK}/count" | tr -d ' '
}

reset_case() {
  rm -rf "${WORK:?}"/*
}

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

TSA_ERROR="Electron Framework.framework: The timestamp service is not available."
REAL_ERROR="Electron Framework.framework: invalid entitlements"

# --- 1. Succeeds first time: no retry, no delay ---------------------------
reset_case
make_stub "${WORK}/stub" 0 "${TSA_ERROR}"
rc=0
SIGN_RETRY_DELAY=0 "${RETRY}" "${WORK}/stub" > /dev/null 2>&1 || rc=$?
assert_eq "0" "${rc}" "clean signing pass exits 0"
assert_eq "1" "$( attempts_made )" "clean signing pass runs the command exactly once"

# --- 2. Transient failure twice, then success -----------------------------
reset_case
make_stub "${WORK}/stub" 2 "${TSA_ERROR}"
rc=0
SIGN_RETRY_DELAY=0 "${RETRY}" "${WORK}/stub" > /dev/null 2>&1 || rc=$?
assert_eq "0" "${rc}" "recovers after two transient timestamp failures"
assert_eq "3" "$( attempts_made )" "retries until the timestamp service recovers"

# --- 3. Non-transient failure fails fast ----------------------------------
# The whole point of matching on the message: a real signing bug must not be
# retried, or genuine breakage hides behind minutes of backoff.
reset_case
make_stub "${WORK}/stub" 99 "${REAL_ERROR}"
rc=0
SIGN_RETRY_DELAY=0 "${RETRY}" "${WORK}/stub" > /dev/null 2>&1 || rc=$?
assert_eq "1" "${rc}" "non-transient signing error exits 1"
assert_eq "1" "$( attempts_made )" "non-transient signing error is NOT retried"

# --- 4. Persistent transient failure gives up at the cap ------------------
reset_case
make_stub "${WORK}/stub" 99 "${TSA_ERROR}"
rc=0
SIGN_MAX_ATTEMPTS=3 SIGN_RETRY_DELAY=0 "${RETRY}" "${WORK}/stub" > /dev/null 2>&1 || rc=$?
assert_eq "1" "${rc}" "persistent timestamp outage eventually exits 1"
assert_eq "3" "$( attempts_made )" "gives up after SIGN_MAX_ATTEMPTS attempts"

# --- 5. prepare_assets.sh actually routes signing through the wrapper -----
if grep -q 'codesign-with-retry.sh' build/osx/prepare_assets.sh; then
  echo "ok   - build/osx/prepare_assets.sh signs via codesign-with-retry.sh"
else
  echo "FAIL - build/osx/prepare_assets.sh does not use codesign-with-retry.sh"
  FAILURES=$(( FAILURES + 1 ))
fi

echo
if (( FAILURES > 0 )); then
  echo "${FAILURES} assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
