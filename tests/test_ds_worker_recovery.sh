#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DS_WORKER="$ROOT/skills/worker/bin/ds-worker"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ds-worker-recovery.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"
STATE_DIR="$TEST_ROOT/state"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$STATE_DIR"

cat > "$FAKE_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "agent" ] && [ "${2:-}" = "list" ]; then
  printf 'ds-explorer (all)\n'
  exit 0
fi

[ "${1:-}" = "run" ] || exit 0

recovery=0
for arg in "$@"; do
  [ "$arg" = "--session" ] && recovery=1
done

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
export DS_STATE_DIR="$STATE_DIR"

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
