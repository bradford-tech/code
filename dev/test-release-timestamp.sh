#!/usr/bin/env bash
# Asserts the release job's latest.json timestamp survives every nanosecond
# value `date` can hand it.
#
# The original expression was:
#     timestamp_ms=$(($(date +%s) * 1000 + $(date +%N) / 1000000))
# `%N` is zero-padded to 9 digits, and bash reads a leading zero as octal. So
# roughly 8% of runs died with "value too great for base" (093499539 contains a
# 9), leaving timestamp_ms empty and jq rejecting `--argjson timestamp ""`; a
# further ~2% parsed silently WRONG (012345670 is valid octal, and decodes to a
# completely different number). It failed run 32079679658 after the builds had
# already succeeded. Being probabilistic, it cannot be caught by running once —
# hence a test that pins the pathological inputs.
#
# Extracts the real line from the workflow so this cannot drift from what CI
# runs. Uses bash explicitly: zsh does not apply octal parsing to leading zeros,
# so a zsh-based check would report a clean bill of health.
#
# Usage: ./dev/test-release-timestamp.sh

set -eo pipefail

cd "$( dirname "${BASH_SOURCE[0]}" )/.." || exit 1

WF=".github/workflows/cron-build-and-release.yml"
FAILURES=0
WORK="$( mktemp -d )"
trap 'rm -rf "${WORK}"' EXIT

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

# The line the release job actually uses to compute the timestamp.
TS_LINE="$( python3 - "${WF}" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for s in d['jobs']['release']['steps']:
    run = s.get('run', '')
    if 'latest.json' in run and 'timestamp' in run:
        for line in run.split('\n'):
            if 'timestamp_ms=' in line:
                print(line.strip())
                sys.exit(0)
sys.exit('could not find the timestamp line in the release job')
PY
)"

if [[ -z "${TS_LINE}" ]]; then
  echo "FAIL - could not extract the timestamp line from ${WF}"
  exit 1
fi
echo "expression under test: ${TS_LINE}"
echo

# Stub `date` so the pathological nanosecond values can be forced. Mirrors GNU
# date: %s epoch seconds, %N zero-padded nanoseconds, %s%3N epoch milliseconds.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/date" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  +%s)     echo "${STUB_EPOCH}" ;;
  +%N)     echo "${STUB_NANOS}" ;;
  +%s%3N)  echo "${STUB_EPOCH}${STUB_NANOS:0:3}" ;;
  *)       echo "unhandled date format: $1" >&2; exit 64 ;;
esac
EOF
chmod +x "${WORK}/bin/date"

# nanos, label, expected milliseconds
run_case() {
  local nanos="$1" label="$2" expected="$3" out
  out="$(
    PATH="${WORK}/bin:${PATH}" STUB_EPOCH=1787009387 STUB_NANOS="${nanos}" \
      bash -c "${TS_LINE}"'; printf "%s" "${timestamp_ms}"' 2>/dev/null || true
  )"
  assert_eq "${expected}" "${out}" "${label} (nanos=${nanos})"
}

# The value that actually broke run 32079679658.
run_case "093499539" "leading zero containing 9"    "1787009387093"
# Leading zero, all digits octal-legal: the silent-corruption case.
run_case "012345670" "leading zero, all octal-legal" "1787009387012"
# Leading zero containing 8.
run_case "087654321" "leading zero containing 8"     "1787009387087"
# All zeros — must not become empty.
run_case "000000000" "all zeros"                     "1787009387000"
# No leading zero: the case that always worked.
run_case "123456789" "no leading zero"               "1787009387123"

# Whatever it produces must be something jq will accept as a JSON number,
# which is where the original bug actually surfaced.
ts="$(
  PATH="${WORK}/bin:${PATH}" STUB_EPOCH=1787009387 STUB_NANOS=093499539 \
    bash -c "${TS_LINE}"'; printf "%s" "${timestamp_ms}"' 2>/dev/null || true
)"
if jq -n --argjson timestamp "${ts:-}" '{timestamp: $timestamp}' >/dev/null 2>&1; then
  echo "ok   - jq accepts the value via --argjson"
else
  echo "FAIL - jq rejects the value via --argjson (got '${ts}')"
  FAILURES=$(( FAILURES + 1 ))
fi

echo
if (( FAILURES > 0 )); then
  echo "${FAILURES} assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
