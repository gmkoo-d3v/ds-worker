#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
mkdir -p "$task_tmp/bin"
cat > "$task_tmp/bin/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = debug ]; then
  printf '[{"name":"doc-critic","mode":"all","hidden":false}]\n'
  exit 0
fi
printf '%s\n' "$@" >> "$TEST_ARGV"
printf 'run\n' >> "$TEST_RUNS"
jq -nc --arg text "$TEST_REPORT" '{type:"text",part:{text:$text}}'
EOF
chmod +x "$task_tmp/bin/opencode"
export PATH="$task_tmp/bin:$PATH"
export TEST_ARGV="$task_tmp/argv" TEST_RUNS="$task_tmp/runs"
export DS_CONFIG="$task_tmp/absent" DS_STATE_DIR="$task_tmp/state"
export DS_MODEL_RETRIES=3 DS_IDLE_TIMEOUT=0 DS_MAX_RUNTIME=10
export DS_SERVE=off DS_AUTO_RECOVER_READONLY=0
export TEST_REPORT='VERDICT: PASS'
bash "$ROOT/skills/worker/bin/ds-worker" critic --dir "$task_tmp" --json --quiet review > "$task_tmp/result"
jq -e '.agent == "doc-critic" and .model == null and .chain_length == 1 and .outcome == "CLEAN_RESULT"' "$task_tmp/result" >/dev/null
if grep -q '^--model$' "$TEST_ARGV"; then exit 1; fi
export DS_MODEL_CRITIC='test/cross-model'
bash "$ROOT/skills/worker/bin/ds-worker" critic --dir "$task_tmp" --json --quiet review > "$task_tmp/result"
jq -e '.model == "test/cross-model" and .chain_length == 1' "$task_tmp/result" >/dev/null
export TEST_REPORT='Mentioning VERDICT in prose is not a final report'
rc=0
bash "$ROOT/skills/worker/bin/ds-worker" critic --dir "$task_tmp" --json --quiet review > "$task_tmp/result" || rc=$?
[ "$rc" -eq 4 ]
jq -e '.outcome == "FINAL_ARTIFACT_MISSING" and .attempt_count == 1' "$task_tmp/result" >/dev/null
[ "$(wc -l < "$TEST_RUNS" | tr -d ' ')" -eq 3 ]
printf 'critic model ownership, single attempt, and verdict contract: PASS\n'
