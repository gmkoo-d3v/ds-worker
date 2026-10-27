#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DS_WORKER="$ROOT/skills/worker/bin/ds-worker"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ds-worker-recovery.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"
STATE_DIR="$TEST_ROOT/state"
ENV_CAPTURE_DIR="$TEST_ROOT/env"
ARGV_DIR="$TEST_ROOT/argv"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$STATE_DIR" "$ENV_CAPTURE_DIR" "$ARGV_DIR"

cat > "$FAKE_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# v2 `opencode debug agents` emits a JSON array; write the rows as `name (mode)`.
v2_agents() { jq -Rn '[inputs | capture("^(?<name>.+) \\((?<mode>[a-z]+)\\)$") + {hidden: false}]'; }

if [ "${1:-}" = "debug" ] && [ "${2:-}" = "agents" ]; then
  { printf 'ds-explorer (all)\n'; } | v2_agents
  exit 0
fi

[ "${1:-}" = "run" ] || exit 0

recovery=0
for arg in "$@"; do
  [ "$arg" = "--session" ] && recovery=1
done

capture="$DS_TEST_ENV_CAPTURE_DIR/initial"
argv_capture="$DS_TEST_ARGV_DIR/initial.argv"
if [ "$recovery" -eq 1 ]; then
  capture="$DS_TEST_ENV_CAPTURE_DIR/recovery"
  argv_capture="$DS_TEST_ARGV_DIR/recovery.argv"
fi
: >"$argv_capture"
for a in "$@"; do printf '%s\n' "$a" >>"$argv_capture"; done
if [ "${OPENCODE_CONFIG_CONTENT+x}" = x ]; then
  printf '%s' "$OPENCODE_CONFIG_CONTENT" >"$capture"
else
  : >"$capture"
fi

if [ "$recovery" -eq 1 ]; then
  printf '%s\n' '{"type":"step_start","sessionID":"ses-recovery","part":{}}'
  printf '%s\n' '{"type":"text","sessionID":"ses-recovery","part":{"text":"### SUMMARY\nrecovered report\n\n### FINDINGS\nnone\n\n### SEARCH COVERAGE\nnone\n\n### GAPS\nnone"}}'
  printf '%s\n' '{"type":"step_finish","sessionID":"ses-recovery","part":{"reason":"stop","tokens":{"total":8},"cost":0}}'
  exit 0
fi

case "${DS_TEST_SCENARIO:?}" in
  completed_missing)
    printf '%s\n' '{"type":"step_start","sessionID":"ses-recovery","part":{}}'
    printf '%s\n' '{"type":"tool_use","sessionID":"ses-recovery","part":{"tool":"read"}}'
    printf '%s\n' '{"type":"text","sessionID":"ses-recovery","part":{"text":"partial evidence"}}'
    ;;
  timeout_missing)
    printf '%s\n' '{"type":"step_start","sessionID":"ses-recovery","part":{}}'
    printf '%s\n' '{"type":"tool_use","sessionID":"ses-recovery","part":{"tool":"read"}}'
    trap 'exit 0' TERM INT
    while :; do sleep 1; done
    ;;
  *)
    printf 'unknown test scenario\n' >&2
    exit 2
    ;;
esac
EOF
chmod +x "$FAKE_BIN/opencode"

export PATH="$FAKE_BIN:$PATH"
# Not an autodetect test: never probe the real model endpoint from opencode.jsonc.
export DS_MODEL_AUTODETECT=0
export DS_STATE_DIR="$STATE_DIR"
export DS_TEST_ENV_CAPTURE_DIR="$ENV_CAPTURE_DIR"
export DS_TEST_ARGV_DIR="$ARGV_DIR"
unset OPENCODE_CONFIG_CONTENT

completed_output="$TEST_ROOT/completed.out"
set +e
DS_TEST_SCENARIO=completed_missing "$DS_WORKER" explorer --no-serve --dir "$TEST_ROOT" \
  --idle-timeout 3 --max-runtime 8 --json --quiet "report" >"$completed_output"
completed_rc=$?
set -e

[ "$completed_rc" -eq 0 ] || {
  printf 'expected completed read-only run to recover, got exit %s\n' "$completed_rc" >&2
  cat "$completed_output" >&2
  exit 1
}
jq -e '.recovery_attempted and .recovered and .initial_outcome == "FINAL_ARTIFACT_MISSING" and .outcome == "CLEAN_RESULT" and .initial_exit == 0 and .initial_timeout_reason == null and (.text | contains("recovered report"))' "$completed_output" >/dev/null || {
  printf 'expected completed-run recovery metadata\n' >&2
  cat "$completed_output" >&2
  exit 1
}
[ ! -s "$ENV_CAPTURE_DIR/initial" ] || {
  printf 'initial run unexpectedly received recovery-only OpenCode config\n' >&2
  exit 1
}
jq -e '.agent["ds-explorer"].tools["*"] == false and .agent["ds-explorer"].options.chat_template_kwargs.enable_thinking == false' "$ENV_CAPTURE_DIR/recovery" >/dev/null || {
  printf 'recovery run did not receive the tool-disabled, no-thinking config\n' >&2
  [ -f "$ENV_CAPTURE_DIR/recovery" ] && sed -n '1p' "$ENV_CAPTURE_DIR/recovery" >&2
  exit 1
}
printf 'ds-worker completed recovery: PASS\n'

timeout_output="$TEST_ROOT/timeout.out"
set +e
DS_TEST_SCENARIO=timeout_missing "$DS_WORKER" explorer --no-serve --dir "$TEST_ROOT" \
  --idle-timeout 1 --max-runtime 8 --json --quiet "report" >"$timeout_output"
timeout_rc=$?
set -e

[ "$timeout_rc" -eq 0 ] || {
  printf 'expected timed-out read-only run to recover, got exit %s\n' "$timeout_rc" >&2
  cat "$timeout_output" >&2
  exit 1
}
jq -e '.recovery_attempted and .recovered and .initial_outcome == "TOOL_ONLY_NO_FINAL_ARTIFACT" and .outcome == "CLEAN_RESULT" and .initial_exit == 124 and .initial_timeout_reason == "idle" and (.text | contains("recovered report"))' "$timeout_output" >/dev/null || {
  printf 'expected timeout recovery metadata\n' >&2
  cat "$timeout_output" >&2
  exit 1
}
printf 'ds-worker timeout recovery: PASS\n'
