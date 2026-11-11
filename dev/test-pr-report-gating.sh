#!/usr/bin/env bash
# Locks down two things in .github/workflows/cron-build-and-release.yml that
# run 43045569211 (PR #134, 2026-11-11) showed were missing:
#
#   1. report-pr-failure / report-pr-success wait on build-reh, not just
#      build. Before: "Fix PR #134 built green" was posted at 15:21 while the
#      REH job was still running; it failed at 16:06 and nothing re-dispatched
#      the fix loop, because `failure()` only sees the jobs in `needs`.
#   2. The REH job's `Install build dependencies` step is bounded. Canonical's
#      DNS outage (actions/runner-images#15296) made apt walk its three-mirror
#      fallback list one ~40 s DNS timeout at a time for 56 minutes. The step
#      now wraps update + download in `timeout`, retries with backoff, and
#      runs the unpack/configure half once from the local cache.
#
# The apt assertions run the REAL step body extracted from the workflow
# against stub `sudo` / `timeout` / `apt-get` / `sleep` commands, so this
# needs no root, no network and no build.
#
# Usage: ./dev/test-pr-report-gating.sh   (~100ms, no build)
set -eo pipefail

cd "$( dirname "${BASH_SOURCE[0]}" )/.." || exit 1

WORKFLOW=".github/workflows/cron-build-and-release.yml"
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

assert_grep() {
  local pattern="$1" file="$2" what="$3"
  if grep -qE -- "${pattern}" "${file}"; then
    echo "ok   - ${what}"
  else
    echo "FAIL - ${what}"
    echo "         pattern not found: ${pattern}"
    FAILURES=$(( FAILURES + 1 ))
  fi
}

# Print the body of top-level job `$1` (from its `  name:` line to the next
# top-level job). Indentation-based, no YAML parser needed.
job_block() {
  node -e '
    const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n");
    const i = lines.findIndex(l => l === "  " + process.argv[2] + ":");
    if (i < 0) throw new Error("job not found: " + process.argv[2]);
    const out = [];
    for (let k = i + 1; k < lines.length; k++) {
      if (/^  [A-Za-z0-9_-]+:\s*$/.test(lines[k])) break;
      out.push(lines[k]);
    }
    process.stdout.write(out.join("\n"));
  ' "${WORKFLOW}" "$1"
}

# Print the `run: |` body of the step named `$1`, de-indented, plus the
# step's own `timeout-minutes:` (if any) on stderr-free side channel file.
step_run_body() {
  node -e '
    const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n");
    const i = lines.findIndex(l => l.trim() === "- name: " + process.argv[2]);
    if (i < 0) throw new Error("step not found: " + process.argv[2]);
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
  ' "${WORKFLOW}" "$1"
}

# --- 1. Both PR-report jobs depend on build-reh ----------------------------
for job in report-pr-failure report-pr-success; do
  job_block "${job}" > "${WORK}/${job}.yml"
  assert_grep '^    needs: \[.*\bbuild-reh\b.*\]' "${WORK}/${job}.yml" \
    "${job} lists build-reh in needs"
done
assert_grep "needs\['build-reh'\]\.result == 'success'" "${WORK}/report-pr-success.yml" \
  "report-pr-success requires build-reh to have succeeded"
assert_grep "needs\.build\.result == 'success'" "${WORK}/report-pr-success.yml" \
  "report-pr-success still requires build to have succeeded"

# --- 2. The apt step is bounded and retried --------------------------------
job_block "build-reh" > "${WORK}/build-reh.yml"
node -e '
  const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n");
  const i = lines.findIndex(l => l.trim() === "- name: Install build dependencies");
  if (i < 0) throw new Error("step not found");
  const out = [];
  for (let k = i + 1; k < lines.length && !/^\s*- name: /.test(lines[k]); k++) out.push(lines[k]);
  process.stdout.write(out.join("\n"));
' "${WORK}/build-reh.yml" > "${WORK}/apt-step.yml"
assert_grep '^\s+timeout-minutes: [0-9]+$' "${WORK}/apt-step.yml" \
  "Install build dependencies has a step-level timeout-minutes backstop"

step_run_body "Install build dependencies" > "${WORK}/step.sh"
bash -n "${WORK}/step.sh" || { echo "FAIL - extracted apt step is not valid bash"; FAILURES=$(( FAILURES + 1 )); }
assert_grep 'timeout [0-9]+ apt-get update' "${WORK}/step.sh" \
  "apt-get update runs under timeout"
# (that the download phase also runs under timeout is asserted behaviourally
# in 2a below — the stub records whether `timeout` wrapped each call)

# Stubs: `sudo` and `timeout` exec their argument vector (timeout also marks
# the environment so apt-get can record whether it ran under one); `apt-get`
# logs every call and fails `FAIL_UPDATES` times on `update`; `sleep` logs
# the requested delay instead of sleeping.
BIN="${WORK}/bin"
mkdir -p "${BIN}"
cat > "${BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat > "${BIN}/timeout" <<'EOF'
#!/usr/bin/env bash
shift
UNDER_TIMEOUT=1 exec "$@"
EOF
cat > "${BIN}/apt-get" <<'EOF'
#!/usr/bin/env bash
log="${STUB_LOG:?}"
echo "timeout=${UNDER_TIMEOUT:-0} $*" >> "${log}"
if [[ "$1" == update ]]; then
  n=$( grep -c ' update$' "${log}" )
  if (( n <= ${FAIL_UPDATES:-0} )); then
    echo "Temporary failure resolving 'archive.ubuntu.com'" >&2
    exit 100
  fi
fi
exit 0
EOF
cat > "${BIN}/sleep" <<'EOF'
#!/usr/bin/env bash
echo "sleep $1" >> "${STUB_LOG:?}"
EOF
chmod +x "${BIN}"/*

run_step() {
  # $1 = how many `apt-get update` calls fail before succeeding
  rm -f "${WORK}/stub.log"
  : > "${WORK}/stub.log"
  local rc=0
  (
    cd "${WORK}" \
    && PATH="${BIN}:${PATH}" STUB_LOG="${WORK}/stub.log" FAIL_UPDATES="$1" \
       APT_MAX_ATTEMPTS=3 APT_RETRY_DELAY=30 \
       bash -e ./step.sh > "${WORK}/out.log" 2>&1
  ) || rc=$?
  echo "${rc}"
}
count() { grep -cE -- "$1" "${WORK}/stub.log" || true; }

# 2a. Healthy mirrors: one update, one download, one install, no sleep.
rc=$( run_step 0 )
assert_eq "0" "${rc}" "healthy apt run exits 0"
assert_eq "1" "$( count ' update$' )" "healthy run calls apt-get update once"
assert_eq "1" "$( count 'timeout=1 install .*--download-only' )" "healthy run downloads once, under timeout"
assert_eq "1" "$( count 'timeout=0 install -y --no-install-recommends build-essential' )" \
  "healthy run installs once from cache, NOT under timeout (dpkg must never be interrupted)"
assert_eq "0" "$( count '^sleep' )" "healthy run never sleeps"

# 2b. Two failed fetches, then recovery: backoff 30 s then 60 s, install once.
rc=$( run_step 2 )
assert_eq "0" "${rc}" "recovers after two failed fetch attempts"
assert_eq "3" "$( count ' update$' )" "retries apt-get update until it succeeds"
assert_eq "sleep 30,sleep 60" "$( grep '^sleep' "${WORK}/stub.log" | paste -sd, - )" \
  "backs off 30 s then 60 s between attempts"
assert_eq "1" "$( count 'timeout=0 install -y' )" "installs exactly once after recovery"
assert_grep '::warning::apt fetch attempt 1/3 failed' "${WORK}/out.log" \
  "each failed attempt is surfaced as a ::warning::"

# 2c. Outage outlasts the cap: give up with a clear error, never run dpkg.
rc=$( run_step 99 )
assert_eq "1" "${rc}" "persistent mirror outage exits 1"
assert_eq "3" "$( count ' update$' )" "gives up after APT_MAX_ATTEMPTS fetch attempts"
assert_eq "0" "$( count 'timeout=0 install -y' )" "never runs the install phase when nothing was fetched"
assert_grep '::error::apt could not fetch build dependencies after 3 attempts' "${WORK}/out.log" \
  "final failure names the attempt cap and the likely cause"

echo
if (( FAILURES > 0 )); then
  echo "${FAILURES} assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
