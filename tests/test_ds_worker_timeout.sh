#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DS_WORKER="$ROOT/skills/worker/bin/ds-worker"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ds-worker-timeout.XXXXXX")"
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
# v2 `opencode debug agents` emits a JSON array; write the rows as `name (mode)`.
v2_agents() { jq -Rn '[inputs | capture("^(?<name>.+) \\((?<mode>[a-z]+)\\)$") + {hidden: false}]'; }

if [ "${1:-}" = "debug" ] && [ "${2:-}" = "agents" ]; then
  { printf 'ds-explorer (all)\n'; } | v2_agents
  exit 0
fi

[ "${1:-}" = "run" ] || exit 0

# This event has no final answer content. It must still count as activity.
printf '%s\n' '{"type":"reasoning","part":{"reasoning":"thinking"}}'

case "${DS_TEST_SCENARIO:?}" in
  activity)
    sleep 2
    printf '%s\n' '{"type":"tool_use","part":{"tool":"read"}}'
    sleep 2
    printf '%s\n' '{"type":"text","part":{"text":"### SUMMARY\nactivity survived\n\n### FINDINGS\nnone\n\n### SEARCH COVERAGE\nnone\n\n### GAPS\nnone"}}'
    ;;
  max_runtime)
    trap 'exit 0' TERM INT
    while :; do sleep 1; done
    ;;
  continuous)
    trap 'exit 0' TERM INT
    while :; do
      printf '%s\n' '{"type":"reasoning","part":{"reasoning":"still working"}}'
      sleep 0.2
    done
    ;;
  *)
    printf 'unknown test scenario\n' >&2
    exit 2
    ;;
esac
EOF
chmod +x "$FAKE_BIN/opencode"

export PATH="$FAKE_BIN:$PATH"
# Not an autodetect test: never probe the real GX10 endpoint from opencode.jsonc.
export DS_MODEL_AUTODETECT=0
export DS_STATE_DIR="$STATE_DIR"

activity_output="$TEST_ROOT/activity.out"
activity_error="$TEST_ROOT/activity.err"
set +e
DS_TEST_SCENARIO=activity "$DS_WORKER" explorer --no-serve --dir "$TEST_ROOT" \
  --idle-timeout 3 --max-runtime 8 --progress-interval 1 "watch" \
  >"$activity_output" 2>"$activity_error"
activity_rc=$?
set -e

[ "$activity_rc" -eq 0 ] || {
  printf 'expected reasoning/tool activity to keep the call alive, got exit %s\n' "$activity_rc" >&2
  sed -n '1,80p' "$activity_error" >&2
  exit 1
}
grep -Fqx '### SUMMARY' "$activity_output" || {
  printf 'expected final text after non-content events\n' >&2
  cat "$activity_output" >&2
  exit 1
}
grep -Eq 'ds-worker: progress elapsed=[0-9]+s events=[0-9]+ tools=[0-9]+ text_chars=[0-9]+ step_finishes=[0-9]+' "$activity_error" || {
  printf 'expected numeric progress diagnostics on stderr\n' >&2
  cat "$activity_error" >&2
  exit 1
}
printf 'ds-worker activity watchdog: PASS\n'

idle_output="$TEST_ROOT/idle.out"
idle_error="$TEST_ROOT/idle.err"
set +e
DS_TEST_SCENARIO=max_runtime "$DS_WORKER" explorer --no-serve --dir "$TEST_ROOT" \
  --idle-timeout 2 --max-runtime 8 --json --quiet "watch" \
  >"$idle_output" 2>"$idle_error"
idle_rc=$?
set -e

[ "$idle_rc" -eq 124 ] || {
  printf 'expected idle-timeout exit 124, got %s\n' "$idle_rc" >&2
  sed -n '1,80p' "$idle_error" >&2
  exit 1
}
jq -e '.exit == 124 and .status == "timed_out_unknown" and .timeout_reason == "idle"' "$idle_output" >/dev/null || {
  printf 'expected idle timeout metadata\n' >&2
  cat "$idle_output" >&2
  exit 1
}
printf 'ds-worker idle watchdog: PASS\n'

max_output="$TEST_ROOT/max.out"
max_error="$TEST_ROOT/max.err"
set +e
DS_TEST_SCENARIO=continuous "$DS_WORKER" explorer --no-serve --dir "$TEST_ROOT" \
  --idle-timeout 0 --timeout 2 --json --quiet "watch" \
  >"$max_output" 2>"$max_error"
max_rc=$?
set -e

[ "$max_rc" -eq 124 ] || {
  printf 'expected max-runtime exit 124, got %s\n' "$max_rc" >&2
  sed -n '1,80p' "$max_error" >&2
  exit 1
}
jq -e '.exit == 124 and .status == "timed_out_unknown" and .timeout_reason == "max-runtime" and .events >= 1' "$max_output" >/dev/null || {
  printf 'expected partial stream metadata after max-runtime timeout\n' >&2
  cat "$max_output" >&2
  exit 1
}
printf 'ds-worker max-runtime watchdog: PASS\n'
