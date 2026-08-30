#!/usr/bin/env bash
# ds-worker picks the model that is actually loaded on the endpoint.
# The GX10 box serves one model at a time, so a configured primary goes stale
# the moment a different one is loaded; these cover the four resolution paths.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DS_WORKER="$ROOT/skills/worker/bin/ds-worker"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ds-worker-autodetect.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
mkdir -p "$FAKE_BIN" "$TEST_ROOT/state"

# `curl` stub: serves whatever DS_TEST_SERVED names, or fails when it is empty.
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
[ -n "${DS_TEST_SERVED:-}" ] || exit 7
printf '{"object":"list","data":[{"id":"%s","object":"model"}]}\n' "$DS_TEST_SERVED"
EOF

# `opencode` stub: a catalog of two models, and a run that echoes its --model.
cat > "$FAKE_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  models) printf 'gx10/deepseek-v4-flash-exl3-cross\ngx10/qwen3.8-27b\n'; exit 0 ;;
  agent)  printf 'ds-explorer (all)\nds-worker (all)\n'; exit 0 ;;
  run)    ;;
  *)      exit 0 ;;
esac
model="" prev=""
for arg in "$@"; do
  [ "$prev" = "--model" ] && model="$arg"
  prev="$arg"
done
printf '{"type":"text","part":{"text":"### SUMMARY\\nused %s\\n\\n### FINDINGS\\nnone\\n\\n### SEARCH COVERAGE\\nnone\\n\\n### GAPS\\nnone"}}\n' "$model"
EOF
chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/opencode"

run_case() {   # $1 = served model id ("" = endpoint down); rest = extra ds-worker args
  local served="$1"; shift
  PATH="$FAKE_BIN:$PATH" \
  DS_TEST_SERVED="$served" \
  DS_CONFIG=/dev/null \
  DS_STATE_DIR="$TEST_ROOT/state" \
  DS_SERVE=off \
  DS_MODEL_ENDPOINT="http://stub.invalid:8000/v1" \
  DS_MODEL_EXPLORER="gx10/deepseek-v4-flash-exl3-cross" \
  DS_MODEL_EXPLORER_FALLBACK="" \
  DS_MODEL_RETRIES=1 \
  DS_IDLE_TIMEOUT=0 \
  "$DS_WORKER" explorer --dir "$TEST_ROOT" "$@" "probe" 2>&1 </dev/null || true
}

fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; exit 1; }

# 1. A different model is loaded → ds-worker follows it.
out="$(run_case "qwen3.8-27b")"
grep -q 'used gx10/qwen3.8-27b' <<<"$out" \
  || fail "follows the loaded model" "expected the run to use gx10/qwen3.8-27b; got: $out"
echo "ds-worker autodetect follows the loaded model: PASS"

# 2. The configured model is the loaded one → left alone, no noise.
out="$(run_case "deepseek-v4-flash-exl3-cross")"
grep -q 'used gx10/deepseek-v4-flash-exl3-cross' <<<"$out" \
  || fail "keeps a matching model" "expected gx10/deepseek-v4-flash-exl3-cross; got: $out"
grep -q 'autodetect:' <<<"$out" \
  && fail "keeps a matching model" "should not narrate when nothing changed; got: $out"
echo "ds-worker autodetect stays quiet when already correct: PASS"

# 3. Endpoint unreachable → keep the configured model, say why.
out="$(run_case "")"
grep -q 'used gx10/deepseek-v4-flash-exl3-cross' <<<"$out" \
  || fail "endpoint down" "expected the configured model; got: $out"
grep -q 'autodetect: .*unreachable' <<<"$out" \
  || fail "endpoint down" "expected an unreachable note; got: $out"
echo "ds-worker autodetect falls back to config when the endpoint is down: PASS"

# 4. Loaded model is absent from the catalog → cannot be routed, so keep and warn.
out="$(run_case "some-unlisted-model")"
grep -q 'used gx10/deepseek-v4-flash-exl3-cross' <<<"$out" \
  || fail "uncatalogued model" "expected the configured model; got: $out"
grep -q "absent from the 'gx10' catalog" <<<"$out" \
  || fail "uncatalogued model" "expected a catalog warning; got: $out"
echo "ds-worker autodetect warns on a model missing from opencode.jsonc: PASS"

# 5. --model pins a choice on purpose; autodetect must not override it.
out="$(run_case "qwen3.8-27b" --model gx10/deepseek-v4-flash-exl3-cross)"
grep -q 'used gx10/deepseek-v4-flash-exl3-cross' <<<"$out" \
  || fail "--model wins" "expected --model to win over autodetect; got: $out"
echo "ds-worker autodetect defers to an explicit --model: PASS"
