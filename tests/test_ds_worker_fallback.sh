#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DS_WORKER="$ROOT/skills/worker/bin/ds-worker"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ds-worker-fallback.XXXXXX")"
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
  printf 'ds-worker (all)\n'
  exit 0
fi

[ "${1:-}" = "run" ] || exit 0

model="" dir=""
prev=""
for arg in "$@"; do
  case "$prev" in
    --model) model="$arg" ;;
    --dir)   dir="$arg" ;;
  esac
  prev="$arg"
done

case "${DS_TEST_SCENARIO:?}" in
  primary_succeeds)
    printf '%s\n' '{"type":"text","part":{"text":"### SUMMARY\nok\n\n### FINDINGS\nnone\n\n### SEARCH COVERAGE\nnone\n\n### GAPS\nnone"}}'
    exit 0
    ;;
  fallback_needed)
    case "$model" in
      */primary-model)
        printf '%s\n' '{"type":"text","part":{"text":"no report yet"}}'
        exit 1
        ;;
      */fallback-model)
        printf '%s\n' '{"type":"text","part":{"text":"### SUMMARY\nfallback ok\n\n### FINDINGS\nnone\n\n### SEARCH COVERAGE\nnone\n\n### GAPS\nnone"}}'
        exit 0
        ;;
      *)
        printf 'unexpected model %s\n' "$model" >&2
        exit 2
        ;;
    esac
    ;;
  worker_dirty)
    : > "$dir/partial-edit.txt"
    printf '%s\n' '{"type":"text","part":{"text":"no report yet"}}'
    exit 1
    ;;
  worker_not_git)
    printf '%s\n' '{"type":"text","part":{"text":"no report yet"}}'
    exit 1
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
export DS_CONFIG="$TEST_ROOT/no-such-config"
export DS_MODEL_EXPLORER="test/primary-model"
export DS_MODEL_EXPLORER_FALLBACK="test/fallback-model"
export DS_MODEL_WORKER="test/primary-model"
export DS_MODEL_WORKER_FALLBACK="test/fallback-model"
export DS_MODEL_RETRIES=2

# ---- primary succeeds: no fallback, single attempt ---------------------------
succeeds_output="$TEST_ROOT/succeeds.out"
set +e
DS_TEST_SCENARIO=primary_succeeds "$DS_WORKER" explorer --no-serve --dir "$TEST_ROOT" \
  --idle-timeout 3 --max-runtime 8 --json --quiet "report" >"$succeeds_output"
succeeds_rc=$?
set -e

[ "$succeeds_rc" -eq 0 ] || {
  printf 'expected primary success to exit 0, got %s\n' "$succeeds_rc" >&2
  cat "$succeeds_output" >&2
  exit 1
}
jq -e '.attempt_count == 1 and .chain_length == 4 and .fallback_used == false and .outcome == "CLEAN_RESULT" and .model == "test/primary-model"' \
  "$succeeds_output" >/dev/null || {
  printf 'expected a single primary attempt with no fallback\n' >&2
  cat "$succeeds_output" >&2
  exit 1
}
printf 'ds-worker fallback chain not needed: PASS\n'

# ---- primary exhausts DS_MODEL_RETRIES, fallback succeeds --------------------
fallback_output="$TEST_ROOT/fallback.out"
set +e
DS_TEST_SCENARIO=fallback_needed "$DS_WORKER" explorer --no-serve --dir "$TEST_ROOT" \
  --idle-timeout 3 --max-runtime 8 --json --quiet "report" >"$fallback_output"
fallback_rc=$?
set -e

[ "$fallback_rc" -eq 0 ] || {
  printf 'expected fallback recovery to exit 0, got %s\n' "$fallback_rc" >&2
  cat "$fallback_output" >&2
  exit 1
}
jq -e '.attempt_count == 3 and .chain_length == 4 and .fallback_used == true and .outcome == "CLEAN_RESULT" and .model == "test/fallback-model" and (.attempts | length) == 3 and .attempts[0].model == "test/primary-model" and .attempts[2].model == "test/fallback-model"' \
  "$fallback_output" >/dev/null || {
  printf 'expected two failed primary attempts then a successful fallback attempt\n' >&2
  cat "$fallback_output" >&2
  exit 1
}
printf 'ds-worker fallback chain used: PASS\n'

# ---- --model bypasses the chain entirely --------------------------------------
explicit_output="$TEST_ROOT/explicit.out"
set +e
DS_TEST_SCENARIO=fallback_needed "$DS_WORKER" explorer --no-serve --dir "$TEST_ROOT" \
  --model test/primary-model --idle-timeout 3 --max-runtime 8 --json --quiet "report" >"$explicit_output"
explicit_rc=$?
set -e

[ "$explicit_rc" -ne 0 ] || {
  printf 'expected explicit --model to fail without a fallback attempt\n' >&2
  cat "$explicit_output" >&2
  exit 1
}
jq -e '.attempt_count == 1 and .chain_length == 1 and .fallback_used == false' "$explicit_output" >/dev/null || {
  printf 'expected --model to run a single attempt with no chain\n' >&2
  cat "$explicit_output" >&2
  exit 1
}
printf 'ds-worker --model bypasses fallback chain: PASS\n'

# ---- writing worker role: a partial edit stops the chain immediately ---------
WORKER_DIR="$TEST_ROOT/worker-repo"
mkdir -p "$WORKER_DIR"
git -C "$WORKER_DIR" init -q

dirty_output="$TEST_ROOT/dirty.out"
set +e
DS_TEST_SCENARIO=worker_dirty "$DS_WORKER" worker --no-serve --dir "$WORKER_DIR" \
  --idle-timeout 3 --max-runtime 8 --json --quiet "edit" >"$dirty_output"
dirty_rc=$?
set -e

[ "$dirty_rc" -ne 0 ] || {
  printf 'expected the dirty-tree scenario to fail\n' >&2
  cat "$dirty_output" >&2
  exit 1
}
[ -f "$WORKER_DIR/partial-edit.txt" ] || {
  printf 'expected the fake edit to actually land in --dir\n' >&2
  exit 1
}
jq -e '.attempt_count == 1 and .chain_length == 4 and .fallback_used == false and (.chain_stop_reason | contains("uncommitted changes"))' \
  "$dirty_output" >/dev/null || {
  printf 'expected the chain to stop after one attempt once files changed\n' >&2
  cat "$dirty_output" >&2
  exit 1
}
printf 'ds-worker worker-role safety guard (dirty tree): PASS\n'

# ---- writing worker role: a non-git --dir cannot be confirmed, so it also stops
NOT_GIT_DIR="$TEST_ROOT/worker-plain"
mkdir -p "$NOT_GIT_DIR"

notgit_output="$TEST_ROOT/notgit.out"
set +e
DS_TEST_SCENARIO=worker_not_git "$DS_WORKER" worker --no-serve --dir "$NOT_GIT_DIR" \
  --idle-timeout 3 --max-runtime 8 --json --quiet "edit" >"$notgit_output"
notgit_rc=$?
set -e

[ "$notgit_rc" -ne 0 ] || {
  printf 'expected the non-git scenario to fail\n' >&2
  cat "$notgit_output" >&2
  exit 1
}
jq -e '.attempt_count == 1 and .fallback_used == false and (.chain_stop_reason | contains("git working tree"))' \
  "$notgit_output" >/dev/null || {
  printf 'expected the chain to stop after one attempt in a non-git --dir\n' >&2
  cat "$notgit_output" >&2
  exit 1
}
printf 'ds-worker worker-role safety guard (non-git dir): PASS\n'
