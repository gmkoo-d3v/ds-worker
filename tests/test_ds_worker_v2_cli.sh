#!/usr/bin/env bash
# ds-worker speaks the OpenCode v2 CLI. A stub opencode that, like v2, rejects
# the removed v1 flags (run --dir/--attach/--variant, `agent list`) records the
# argv and cwd of each run, so these cases pin:
#   - the run is started inside --dir, never with --dir
#   - a private --standalone server, never --attach (DS_SERVE is only a notice)
#   - --variant travels as --model provider/model#variant
#   - a relative --file is resolved against the caller's cwd
#   - the agent list comes from `debug agents`, retried past a cold-start `[]`
#   - opencode.jsonc with comments still yields the provider baseURL
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DS_WORKER="$ROOT/skills/worker/bin/ds-worker"
# cd+pwd: a TMPDIR with a trailing slash would otherwise leave a "//" in paths.
TEST_ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ds-worker-v2cli.XXXXXX")" && pwd)"
FAKE_BIN="$TEST_ROOT/bin"
WORK_DIR="$TEST_ROOT/work"
CALLER_DIR="$TEST_ROOT/caller"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
mkdir -p "$FAKE_BIN" "$WORK_DIR" "$CALLER_DIR" "$TEST_ROOT/state" "$TEST_ROOT/xdg/opencode"

fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; exit 1; }

cat > "$FAKE_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "debug agents")
    # The first call after DS_TEST_COLD is set answers like a cold service.
    if [ -n "${DS_TEST_COLD:-}" ] && [ ! -e "$DS_TEST_COLD" ]; then
      : >"$DS_TEST_COLD"; printf '[]\n'; exit 0
    fi
    printf '[{"name":"ds-explorer","mode":"all","hidden":false},{"name":"Title","mode":"primary","hidden":true}]\n'
    exit 0 ;;
  "agent list") printf 'DESCRIPTION\n  OpenCode command line interface\n'; exit 0 ;;
esac
[ "${1:-}" = run ] || exit 0
for arg in "$@"; do
  case "$arg" in
    --dir|--attach|--variant) printf 'Unrecognized flag: %s\n' "$arg" >&2; exit 1 ;;
  esac
done
n="$(find "$DS_TEST_ARGV_DIR" -name '*.argv' | wc -l | tr -d ' ')"
printf '%s\n' "$@" >"$DS_TEST_ARGV_DIR/$n.argv"
printf '%s\n' "$PWD" >"$DS_TEST_ARGV_DIR/$n.cwd"
printf '%s\n' '{"type":"text","sessionID":"ses-v2","part":{"text":"### SUMMARY\nok\n\n### FINDINGS\nnone\n\n### SEARCH COVERAGE\nnone\n\n### GAPS\nnone"}}'
EOF
chmod +x "$FAKE_BIN/opencode"

export PATH="$FAKE_BIN:$PATH"
export DS_CONFIG=/dev/null DS_STATE_DIR="$TEST_ROOT/state" DS_MODEL_AUTODETECT=0
export XDG_CONFIG_HOME="$TEST_ROOT/xdg"
unset DS_SERVE OPENCODE_CONFIG_CONTENT

run_case() {   # $1 = case name; rest = ds-worker args. Leaves argv in $TEST_ROOT/<case>/
  local name="$1"; shift
  export DS_TEST_ARGV_DIR="$TEST_ROOT/$name"
  mkdir -p "$DS_TEST_ARGV_DIR"
  (cd "$CALLER_DIR" && "$DS_WORKER" "$@") >"$TEST_ROOT/$name.out" 2>"$TEST_ROOT/$name.err" \
    || fail "$name" "exit $?; stderr: $(cat "$TEST_ROOT/$name.err")"
}

# ---- run argv and cwd -----------------------------------------------------------
printf 'attached\n' >"$CALLER_DIR/note.txt"
run_case basic explorer --dir "$WORK_DIR" --variant high --file note.txt --json --quiet "map"
ARGV="$(cat "$TEST_ROOT/basic/0.argv")"
[ "$(cat "$TEST_ROOT/basic/0.cwd")" = "$WORK_DIR" ] \
  || fail "cwd" "child ran in $(cat "$TEST_ROOT/basic/0.cwd"), expected $WORK_DIR"
printf '%s\n' "$ARGV" | grep -qx -- '--standalone' || fail "standalone" "argv lacks --standalone:
$ARGV"
printf '%s\n' "$ARGV" | grep -qx -- 'gx10/qwen3.8-flash-next#high' \
  || fail "variant" "expected --model gx10/qwen3.8-flash-next#high; argv:
$ARGV"
printf '%s\n' "$ARGV" | grep -qx -- "$CALLER_DIR/note.txt" \
  || fail "file" "relative --file was not resolved against the caller cwd; argv:
$ARGV"
jq -e '.outcome == "CLEAN_RESULT" and .errors == []' "$TEST_ROOT/basic.out" >/dev/null \
  || fail "result" "$(cat "$TEST_ROOT/basic.out")"
printf 'ds-worker runs inside --dir with --standalone, model#variant, absolute --file: PASS\n'

# ---- DS_SERVE is a notice, not --attach/--server ------------------------------------
DS_SERVE=auto run_case serve explorer --dir "$WORK_DIR" --json --quiet "map"
printf '%s\n' "$(cat "$TEST_ROOT/serve/0.argv")" | grep -qx -- '--standalone' \
  || fail "serve" "DS_SERVE=auto must still run --standalone"
grep -q 'not ported to the OpenCode v2 server' "$TEST_ROOT/serve.err" \
  || fail "serve" "expected a notice that DS_SERVE is ignored; stderr: $(cat "$TEST_ROOT/serve.err")"
printf 'DS_SERVE=auto falls back to --standalone with a notice: PASS\n'

# ---- agent list: cold-start [] is retried -------------------------------------------
DS_TEST_COLD="$TEST_ROOT/cold.flag" run_case cold explorer --dir "$WORK_DIR" --json --quiet "map"
[ -e "$TEST_ROOT/cold.flag" ] || fail "cold" "stub never served the cold-start []"
printf 'agent list retries past a cold-start []: PASS\n'

# ---- helper library: hidden agents are not listed --------------------------------------
. "$ROOT/skills/worker/lib/opencode-cli.sh"
LIST="$(oc_agent_list)"
[ "$LIST" = "ds-explorer (all)" ] || fail "oc_agent_list" "expected only the visible agent, got: $LIST"
printf 'oc_agent_list prints visible agents as name (mode): PASS\n'

# ---- opencode.jsonc with comments and trailing commas -------------------------------
cat >"$XDG_CONFIG_HOME/opencode/opencode.jsonc" <<'EOF'
{
  // the GX10 box
  "provider": {
    "gx10": { /* local vLLM */ "options": { "baseURL": "http://gx10.invalid:8000/v1", }, },
  },
}
EOF
. "$ROOT/skills/worker/lib/model-endpoint.sh"
URL="$(ds_provider_baseurl gx10)"
[ "$URL" = "http://gx10.invalid:8000/v1" ] || fail "jsonc" "expected the baseURL through comments, got '$URL'"
printf 'provider baseURL is read from commented opencode.jsonc: PASS\n'
