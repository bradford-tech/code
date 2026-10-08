#!/usr/bin/env bash
# Regression test for the "Summarize Claude session" step in
# .github/workflows/claude-build-fix.yml, and for the settings that stop the
# failure it exists to expose.
#
# Issue #96: two fix attempts each rebased every broken patch, launched the
# 20-30 min ci-verify as a background task, ended the turn to wait for a
# completion notification that headless mode never delivers, and the job
# finished green with nothing pushed. The action hides the transcript, so
# nothing on the run page said what happened.
#
# This asserts, against the REAL step extracted from the workflow:
#   1. the outline shows assistant prose, tool names and commands;
#   2. tool RESULTS are never printed (that is where secrets would leak);
#   3. a run_in_background tool call raises a ::warning::;
#   4. a missing execution file is a warning, not a failure;
# and, against the settings file the action loads:
#   5. CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 and BASH_MAX_TIMEOUT_MS are set.
#
# Usage: ./dev/test-fix-run-summary.sh   (~50ms, no build)
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflow="$repo_root/.github/workflows/claude-build-fix.yml"
settings="$repo_root/.github/claude-code-settings.json"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- extract the step's `run:` body verbatim ---------------------------------
extract_step() {
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
    const i = lines.findIndex(l => l.includes("name: Summarize Claude session"));
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
bash -n "$work/step.sh" || fail "extracted step is not valid bash"

# --- fixture: the shape the action writes (a JSON array of SDK messages) -----
# Mirrors the issue #96 session: prose, a foreground command, the background
# ci-verify launch, a tool result carrying something secret-shaped, and the
# success result the SDK returned when the turn ended.
cat > "$work/execution.json" <<'EOF'
[
  {"type":"system","subtype":"init","model":"claude-opus-5-5"},
  {"type":"assistant","message":{"content":[
    {"type":"text","text":"All six patches rebased.\nNow the contracted verification, in the background:"},
    {"type":"tool_use","name":"Bash","input":{"command":"./dev/dry-apply-patches.sh --commit abc\n","description":"Dry-apply"}}
  ]}},
  {"type":"user","message":{"content":[
    {"type":"tool_result","content":"SUPERSECRETTOKEN-DO-NOT-PRINT\nAll patches apply cleanly."}
  ]}},
  {"type":"assistant","message":{"content":[
    {"type":"tool_use","name":"Bash","input":{"command":"CI_BUILD=yes ./dev/ci-verify.sh --commit abc > /tmp/ci-verify.log 2>&1","run_in_background":true,"timeout":5400000}},
    {"type":"tool_use","name":"Read","input":{"file_path":"/work/docs/build-fix.md"}}
  ]}},
  {"type":"result","subtype":"success","is_error":false,"num_turns":71,"duration_ms":398733}
]
EOF

# --- 1-3: outline content, no tool results, background warning ---------------
out=$(cd "$work" && EXECUTION_FILE="$work/execution.json" bash ./step.sh) || fail "step exited non-zero on a valid execution file"

grep -q -- '-- All six patches rebased. Now the contracted verification' <<<"$out" \
  || fail "assistant prose missing or newlines not flattened"
grep -q '^\[Bash\] ./dev/dry-apply-patches.sh --commit abc' <<<"$out" \
  || fail "Bash tool call with its command missing from outline"
grep -q '^\[Bash\] CI_BUILD=yes ./dev/ci-verify.sh' <<<"$out" \
  || fail "background ci-verify call missing from outline"
grep -q '^\[Read\] /work/docs/build-fix.md' <<<"$out" \
  || fail "non-Bash tool call (file_path) missing from outline"
grep -q '^== result: subtype=success is_error=false turns=71 duration_ms=398733' <<<"$out" \
  || fail "result summary line missing"
grep -q 'SUPERSECRETTOKEN' <<<"$out" \
  && fail "tool RESULT content leaked into the outline"
grep -q '^::warning::Claude started 1 background task(s)' <<<"$out" \
  || fail "no ::warning:: for a run_in_background tool call"

# --- 3b: no warning when nothing was backgrounded ----------------------------
jq 'map(if .type == "assistant" then
         .message.content |= map(del(.input.run_in_background)) else . end)' \
  "$work/execution.json" > "$work/foreground.json"
out_fg=$(cd "$work" && EXECUTION_FILE="$work/foreground.json" bash ./step.sh) || fail "step failed on foreground-only fixture"
grep -q 'background task' <<<"$out_fg" \
  && fail "background warning fired with no run_in_background call"

# --- 4: missing execution file is a warning, not a failure -------------------
out_missing=$(cd "$work" && EXECUTION_FILE="" bash ./step.sh) || fail "step must exit 0 when no execution file is recorded"
grep -q '^::warning::No Claude execution file' <<<"$out_missing" \
  || fail "missing execution file did not produce a ::warning::"

# --- 5: the kill switch and the raised foreground ceiling are in settings ----
[ "$(jq -r '.env.CLAUDE_CODE_DISABLE_BACKGROUND_TASKS // empty' "$settings")" = "1" ] \
  || fail "settings file must set CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 (issue #96)"
max_ms=$(jq -r '.env.BASH_MAX_TIMEOUT_MS // empty' "$settings")
[ -n "$max_ms" ] && [ "$max_ms" -ge 1800000 ] \
  || fail "settings file must raise BASH_MAX_TIMEOUT_MS to at least 30 min so ci-verify can finish in the foreground (got '${max_ms:-unset}')"

echo "PASS: fix-run summary step prints a redacted outline, warns on background tasks, and settings disable them"
