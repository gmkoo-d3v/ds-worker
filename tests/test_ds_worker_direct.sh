#!/usr/bin/env bash
# ds-worker direct — one chat completion, no OpenCode. A stub curl plays the
# GX10 endpoint and no opencode is on PATH at all, so these cases pin that
# direct mode survives without OpenCode and maps every endpoint answer:
#   200 + content -> CLEAN_RESULT, exit 0, files inlined into the request
#   200 + empty   -> FINAL_ARTIFACT_MISSING, exit 4
#   HTTP 404      -> FAILED, exit 1, the server's message surfaced
#   curl rc 28    -> MAX_RUNTIME, exit 124
# plus the refusals: OpenCode-only options, a binary --file, no endpoint.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DS_WORKER="$ROOT/skills/worker/bin/ds-worker"
TEST_ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ds-worker-direct.XXXXXX")" && pwd)"
FAKE_BIN="$TEST_ROOT/bin"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
mkdir -p "$FAKE_BIN" "$TEST_ROOT/state" "$TEST_ROOT/xdg"

fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; exit 1; }

# curl stub: GET /models names the loaded model; POST /chat/completions copies
# the request body to $DS_TEST_REQUEST and answers per DS_TEST_REPLY.
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
out="" body="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --data-binary) body="${2#@}"; shift 2 ;;
    -m|-w|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */models) printf '{"data":[{"id":"%s"}]}\n' "${DS_TEST_SERVED:-served-model}"; exit 0 ;;
esac
cp "$body" "$DS_TEST_REQUEST"
case "${DS_TEST_REPLY:?}" in
  ok)      printf '{"choices":[{"message":{"content":"\\n\\nverdict: fine"},"finish_reason":"stop"}],"usage":{"total_tokens":12}}' >"$out"; printf 200 ;;
  empty)   printf '{"choices":[{"message":{"content":""},"finish_reason":"length"}]}' >"$out"; printf 200 ;;
  missing) printf '{"error":{"message":"The model `nope` does not exist."}}' >"$out"; printf 404 ;;
  slow)    printf 'curl: (28) Operation timed out\n' >&2; printf 000; exit 28 ;;
esac
EOF
chmod +x "$FAKE_BIN/curl"
for tool in bash env dirname readlink jq perl grep sed cat head date mkdir rm cp find tr; do
  ln -s "$(command -v "$tool")" "$FAKE_BIN/$tool"
done

# PATH holds only the stubs and the tools linked above: no opencode anywhere.
export PATH="$FAKE_BIN"
export DS_CONFIG=/dev/null DS_STATE_DIR="$TEST_ROOT/state" XDG_CONFIG_HOME="$TEST_ROOT/xdg"
export DS_MODEL_ENDPOINT="http://gx10.invalid:8000/v1" DS_TEST_REQUEST="$TEST_ROOT/request.json"

direct() {   # $1 = case name, $2 = reply kind; rest = ds-worker direct args. Sets RC.
  local name="$1" reply="$2"; shift 2
  RC=0
  DS_TEST_REPLY="$reply" "$DS_WORKER" direct "$@" >"$TEST_ROOT/$name.out" 2>"$TEST_ROOT/$name.err" || RC=$?
}

# ---- success: autodetect, inlined file, trimmed text --------------------------------
printf 'line one\nline two\n' >"$TEST_ROOT/evidence.log"
direct ok ok --file "$TEST_ROOT/evidence.log" --json --quiet "rank the causes"
[ "$RC" -eq 0 ] || fail "ok" "exit $RC; $(cat "$TEST_ROOT/ok.err")"
jq -e '.outcome == "CLEAN_RESULT" and .text == "verdict: fine" and .wrapper_exit == 0
       and .model == "gx10/served-model" and .tokens.total_tokens == 12' "$TEST_ROOT/ok.out" >/dev/null \
  || fail "ok" "unexpected result: $(cat "$TEST_ROOT/ok.out")"
jq -e '.model == "served-model" and (.messages | length) == 2
       and (.messages[1].content | contains("rank the causes") and contains("line two")
            and contains("attached file: '"$TEST_ROOT"'/evidence.log"))' "$DS_TEST_REQUEST" >/dev/null \
  || fail "request" "prompt or file missing from the request: $(cat "$DS_TEST_REQUEST")"
printf 'direct succeeds without opencode, inlines files, follows the loaded model: PASS\n'

direct pinned ok --model gx10/pinned --quiet "x"
[ "$(cat "$TEST_ROOT/pinned.out")" = "verdict: fine" ] || fail "pinned" "text mode printed: $(cat "$TEST_ROOT/pinned.out")"
jq -e '.model == "pinned"' "$DS_TEST_REQUEST" >/dev/null || fail "pinned" "--model must bypass autodetect"
printf 'direct --model pins the model and text mode prints only the answer: PASS\n'

# ---- failures map to the wrapper's exit codes ----------------------------------------
direct empty empty --json --quiet "x"
[ "$RC" -eq 4 ] && jq -e '.outcome == "FINAL_ARTIFACT_MISSING" and .finish_reason == "length"' "$TEST_ROOT/empty.out" >/dev/null \
  || fail "empty" "exit $RC; $(cat "$TEST_ROOT/empty.out")"
direct missing missing --quiet "x"
[ "$RC" -eq 1 ] && grep -q 'does not exist' "$TEST_ROOT/missing.err" \
  || fail "missing" "exit $RC; stderr: $(cat "$TEST_ROOT/missing.err")"
direct slow slow --json --quiet --max-runtime 3 "x"
[ "$RC" -eq 124 ] && jq -e '.outcome == "MAX_RUNTIME"' "$TEST_ROOT/slow.out" >/dev/null \
  || fail "slow" "exit $RC; $(cat "$TEST_ROOT/slow.out")"
printf 'direct maps empty / HTTP error / timeout to exit 4 / 1 / 124: PASS\n'

# ---- refusals ---------------------------------------------------------------------
direct dir ok --dir "$TEST_ROOT" "x"
[ "$RC" -eq 2 ] && grep -q 'no tools' "$TEST_ROOT/dir.err" || fail "dir" "exit $RC; $(cat "$TEST_ROOT/dir.err")"
printf '\000\001binary' >"$TEST_ROOT/blob.bin"
direct blob ok --file "$TEST_ROOT/blob.bin" "x"
[ "$RC" -eq 2 ] && grep -q 'looks binary' "$TEST_ROOT/blob.err" || fail "binary" "exit $RC; $(cat "$TEST_ROOT/blob.err")"
DS_MODEL_ENDPOINT="" direct noend ok "x"
[ "$RC" -eq 2 ] && grep -q 'no endpoint' "$TEST_ROOT/noend.err" || fail "endpoint" "exit $RC; $(cat "$TEST_ROOT/noend.err")"
printf 'direct refuses OpenCode-only options, binary files and a missing endpoint: PASS\n'
