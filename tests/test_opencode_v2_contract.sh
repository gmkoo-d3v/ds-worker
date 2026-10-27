#!/usr/bin/env bash
# Contract test against the REAL opencode binary — the one place the CLI shape
# ds-worker depends on is checked against what is installed, not a stub. Every
# other test fakes opencode, which is how the v1 -> v2 break went unnoticed.
#
#   bash tests/test_opencode_v2_contract.sh             # CLI shape only, no model call
#   DS_CONTRACT_LIVE=1 bash tests/test_opencode_v2_contract.sh   # + round trips to your model
#
# Skips (exit 0) when opencode is not installed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER="$ROOT/skills/worker"
command -v opencode >/dev/null || { printf 'opencode v2 contract: SKIP (opencode not on PATH)\n'; exit 0; }
TEST_ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/opencode-contract.XXXXXX")" && pwd)"
cleanup() {
  DS_STATE_DIR="$TEST_ROOT/state" "$WORKER/bin/ds-serve" stop >/dev/null 2>&1 || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; exit 1; }
printf '# opencode %s\n' "$(opencode --version 2>/dev/null | head -1)"

# ---- agent list --------------------------------------------------------------------
. "$WORKER/lib/opencode-cli.sh"
AGENTS="$(oc_agent_list)" || fail "debug agents" "'opencode debug agents' gave no JSON array in 3 tries"
BAD="$(printf '%s\n' "$AGENTS" | grep -Ev '^.+ \((primary|subagent|all)\)$' || true)"
[ -z "$BAD" ] || fail "debug agents" "rows not in name (mode) shape: $BAD"
for a in ds-explorer ds-reviewer ds-worker doc-critic; do
  printf '%s\n' "$AGENTS" | grep -q "^$a " || fail "debug agents" "persona $a not listed — run install.sh"
done
printf 'debug agents lists the personas as name (mode): PASS\n'

# ---- every run flag ds-worker emits exists ----------------------------------------------
# Collected from the source, so a flag added later is checked without editing this test.
EMITTED="$(grep -Eo '(RECOVERY_)?ARGS\+?=\([^)]*\)' "$WORKER/bin/ds-worker" \
  | grep -Eo -- '--[a-z][a-z-]*' | sort -u)"
[ -n "$EMITTED" ] || fail "run flags" "found no ARGS assignments in ds-worker"
HELP="$(opencode run --help 2>&1)"
for flag in $EMITTED; do
  printf '%s\n' "$HELP" | grep -Eq -- "(^|[ ,])${flag}( |,|$)" \
    || fail "run flags" "ds-worker passes $flag but 'opencode run --help' does not list it"
done
printf 'opencode run accepts every flag ds-worker emits (%s): PASS\n' "$(printf '%s' "$EMITTED" | tr '\n' ' ')"

# ---- the flags v2 removed stay out of ds-worker --------------------------------------
for flag in --dir --attach --variant; do
  printf '%s\n' "$EMITTED" | grep -qx -- "$flag" && fail "removed flags" "ds-worker still passes $flag to opencode run"
done
printf 'ds-worker passes none of the removed v1 run flags: PASS\n'

# ---- model catalog and endpoint -------------------------------------------------------
opencode models 2>/dev/null | grep -Eq '^[^/ ]+/[^ ]+$' || fail "models" "'opencode models' printed no provider/model rows"
. "$WORKER/lib/model-endpoint.sh"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.jsonc"
if [ -f "$CFG" ]; then
  ds_jsonc_to_json "$CFG" | jq -e . >/dev/null || fail "jsonc" "$CFG does not parse after comment stripping"
  printf 'opencode.jsonc parses after comment stripping: PASS\n'
fi
printf 'opencode models lists provider/model rows: PASS\n'

[ "${DS_CONTRACT_LIVE:-0}" = 1 ] || { printf 'live round trips: SKIP (set DS_CONTRACT_LIVE=1)\n'; exit 0; }

# ---- live: an unknown agent must fail, never fall back to the default agent ------------
RC=0
(cd "$TEST_ROOT" && perl -e 'alarm shift; exec @ARGV' 120 \
  opencode run --standalone --agent ds-contract-no-such-agent --format json -- "Reply with exactly: pong") \
  </dev/null >"$TEST_ROOT/unknown.out" 2>&1 || RC=$?
[ "$RC" -ne 0 ] || fail "unknown agent" "opencode ran an unknown agent with exit 0: $(head -c 400 "$TEST_ROOT/unknown.out")"
# 142 = our alarm fired: a hang is not a rejection.
[ "$RC" -ne 142 ] && grep -q 'Agent not found' "$TEST_ROOT/unknown.out" \
  || fail "unknown agent" "expected an 'Agent not found' error, got exit $RC: $(head -c 400 "$TEST_ROOT/unknown.out")"
printf 'opencode run rejects an unknown agent (exit %s): PASS\n' "$RC"

# ---- live: ds-worker through OpenCode, and direct without it -----------------------------
printf 'contract-marker-7\n' >"$TEST_ROOT/marker.txt"
"$WORKER/bin/ds-worker" explorer --dir "$TEST_ROOT" --max-runtime 300 --json --quiet \
  "Read marker.txt in the working directory and report its exact contents in FINDINGS." \
  >"$TEST_ROOT/explorer.json" || fail "ds-worker explorer" "exit $?; $(jq -c '{outcome, errors}' "$TEST_ROOT/explorer.json" 2>/dev/null)"
jq -e '.outcome == "CLEAN_RESULT" and (.text | contains("contract-marker-7"))' "$TEST_ROOT/explorer.json" >/dev/null \
  || fail "ds-worker explorer" "$(jq -c '{outcome, tools, errors, text: .text[0:300]}' "$TEST_ROOT/explorer.json")"
printf 'ds-worker explorer reads a file through opencode v2: PASS\n'
# The personas default-deny, so the v2 code-mode tool must not even be offered.
jq -e '(.tools | index("execute")) == null' "$TEST_ROOT/explorer.json" >/dev/null \
  || fail "default deny" "explorer used the execute tool: $(jq -c .tools "$TEST_ROOT/explorer.json")"
printf 'explorer never reaches the code-mode execute tool: PASS\n'

"$WORKER/bin/ds-worker" direct --file "$TEST_ROOT/marker.txt" --max-runtime 120 --json --quiet \
  "Reply with the exact contents of the attached file and nothing else." >"$TEST_ROOT/direct.json" \
  || fail "ds-worker direct" "exit $?; $(jq -c '{outcome, error}' "$TEST_ROOT/direct.json" 2>/dev/null)"
jq -e '.outcome == "CLEAN_RESULT" and (.text | contains("contract-marker-7"))' "$TEST_ROOT/direct.json" >/dev/null \
  || fail "ds-worker direct" "$(jq -c '{outcome, error, text}' "$TEST_ROOT/direct.json")"
printf 'ds-worker direct answers from the model endpoint: PASS\n'

# ---- live: the ds-serve backend (own state dir, stopped on exit) ---------------------
export DS_STATE_DIR="$TEST_ROOT/state"
DS_SERVE=auto "$WORKER/bin/ds-worker" explorer --dir "$TEST_ROOT" --max-runtime 300 --json --quiet \
  "Read marker.txt in the working directory and report its exact contents in FINDINGS." \
  >"$TEST_ROOT/served.json" || fail "DS_SERVE=auto" "exit $?; $(jq -c '{backend, outcome, errors}' "$TEST_ROOT/served.json" 2>/dev/null)"
jq -e '(.backend | startswith("http://")) and .outcome == "CLEAN_RESULT" and (.text | contains("contract-marker-7"))' \
  "$TEST_ROOT/served.json" >/dev/null \
  || fail "DS_SERVE=auto" "$(jq -c '{backend, outcome, errors, text: .text[0:300]}' "$TEST_ROOT/served.json")"
printf 'ds-worker DS_SERVE=auto runs through the password-protected ds-serve backend: PASS\n'

# Recovery continues a backend session from a private --standalone server.
SID="$(jq -r '.session' "$TEST_ROOT/served.json")"
(cd "$TEST_ROOT" && perl -e 'alarm shift; exec @ARGV' 180 opencode run --standalone --agent ds-explorer \
  --format json --session "$SID" --continue -- "Repeat the file contents you reported, nothing else.") \
  </dev/null >"$TEST_ROOT/cross.out" 2>&1 || fail "cross-backend session" "exit $?; $(head -c 300 "$TEST_ROOT/cross.out")"
[ "$(jq -r '.sessionID // empty' "$TEST_ROOT/cross.out" 2>/dev/null | sort -u)" = "$SID" ] \
  && jq -r 'select(.type=="text")|.part.text' "$TEST_ROOT/cross.out" | grep -q contract-marker-7 \
  || fail "cross-backend session" "standalone did not continue $SID: $(head -c 300 "$TEST_ROOT/cross.out")"
printf 'a --standalone run continues a session the backend created: PASS\n'

# A caller password with a quote and a backslash survives curl's -K quoting.
"$WORKER/bin/ds-serve" stop >/dev/null 2>&1
OPENCODE_SERVER_PASSWORD='q"uo\te' "$WORKER/bin/ds-serve" start >/dev/null 2>&1 \
  && OPENCODE_SERVER_PASSWORD='q"uo\te' "$WORKER/bin/ds-serve" status >/dev/null 2>&1 \
  || fail "quoted password" "ds-serve could not start or probe with a quoted caller password"
printf 'ds-serve probes a real server with a quoted caller password: PASS\n'
