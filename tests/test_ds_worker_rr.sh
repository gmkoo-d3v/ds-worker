#!/usr/bin/env bash
# ds-worker-rr rotates --model over DS_RR_MODELS (environment, else the config
# file), passes through with fewer than two, and never overrides a --model the
# caller gave. A stub ds-worker on PATH records what it was called with.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RR="$ROOT/skills/worker/bin/ds-worker-rr"
TEST_ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ds-worker-rr.XXXXXX")" && pwd)"
FAKE_BIN="$TEST_ROOT/bin"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
mkdir -p "$FAKE_BIN" "$TEST_ROOT/state"

fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; exit 1; }

cat > "$FAKE_BIN/ds-worker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*"
EOF
chmod +x "$FAKE_BIN/ds-worker"
export PATH="$FAKE_BIN:$PATH" DS_STATE_DIR="$TEST_ROOT/state" DS_CONFIG="$TEST_ROOT/config"
unset DS_RR_MODELS
: >"$DS_CONFIG"

# ---- two models from the environment: alternate per call ----------------------------
got="$(DS_RR_MODELS='p/a p/b' "$RR" explorer "q"; DS_RR_MODELS='p/a p/b' "$RR" explorer "q"; DS_RR_MODELS='p/a p/b' "$RR" explorer "q")"
[ "$got" = "explorer --model p/a q
explorer --model p/b q
explorer --model p/a q" ] || fail "rotate" "unexpected calls:
$got"
printf 'ds-worker-rr alternates over DS_RR_MODELS: PASS\n'

# ---- the config file is read when the environment is empty -----------------------------
printf '# comment\nDS_RR_MODELS = "p/x p/y"\n' >"$DS_CONFIG"
[ "$("$RR" reviewer "q")" = "reviewer --model p/x q" ] || fail "config" "config file list not used"
printf 'ds-worker-rr reads DS_RR_MODELS from the config file: PASS\n'

# ---- fewer than two models, or a caller --model: pass straight through ------------------
: >"$DS_CONFIG"
[ "$(DS_RR_MODELS='p/only' "$RR" worker "q")" = "worker q" ] || fail "single" "one model must not inject --model"
[ "$("$RR" worker "q")" = "worker q" ] || fail "none" "no list must not inject --model"
[ "$(DS_RR_MODELS='p/a p/b' "$RR" worker --model p/mine "q")" = "worker --model p/mine q" ] \
  || fail "caller" "a caller --model must win"
printf 'ds-worker-rr passes through with fewer than two models or a caller --model: PASS\n'

# ---- the role names a counter file, so it must be a plain word -------------------------
RC=0; DS_RR_MODELS='p/a p/b' "$RR" "../../etc/x" "q" >/dev/null 2>"$TEST_ROOT/bad.err" || RC=$?
[ "$RC" -eq 2 ] && grep -q 'invalid role' "$TEST_ROOT/bad.err" && [ ! -e "$TEST_ROOT/etc" ] \
  || fail "role" "a role with path characters must be refused, got $RC"
printf 'ds-worker-rr refuses a role that is not a plain word: PASS\n'
