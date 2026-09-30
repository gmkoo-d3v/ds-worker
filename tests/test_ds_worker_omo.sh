#!/usr/bin/env bash
# ds-worker omo <agent> — the OMO gateway.
#
# OpenCode built-in agents (oracle, council, librarian, designer, fixer) get
# their model from the active OmO Slim preset, so the gateway must dispatch them
# WITHOUT --model. In a real `opencode agent list` those built-ins are
# `(subagent)` and only `orchestrator` is `(primary)`, so `opencode run --agent
# <subagent>` cannot reach them: the gateway must dispatch every OMO built-in
# through `orchestrator` with a task(subagent_type='<name>') instruction.
# The DS roles (ds-explorer, ds-reviewer) keep their configured local model
# and must still receive --model. An unsupported agent must fail validation
# before any opencode run happens.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DS_WORKER="$ROOT/skills/worker/bin/ds-worker"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ds-worker-omo.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"
STATE_DIR="$TEST_ROOT/state"
ARGV_DIR="$TEST_ROOT/argv"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$STATE_DIR" "$ARGV_DIR"

# Fake OpenCode:
#   `agent list`   mirrors the verified real agent modes: the OMO built-ins are
#                  (subagent), orchestrator is (primary), the DS agents are (all)
#   `models`       exposes the test local model used by the DS roles
#   `run`          records argv + prompt to $DS_TEST_ARGV_DIR/<n>.argv, then
#                  replays a final report fixture (role-appropriate markers so
#                  the wrapper's final-artifact check is satisfied)
cat > "$FAKE_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  agent)
    [ "${2:-}" = "list" ] || exit 0
    printf 'council (subagent)\n'
    printf 'designer (subagent)\n'
    printf 'ds-explorer (all)\n'
    printf 'ds-reviewer (all)\n'
    printf 'ds-worker (all)\n'
    printf 'fixer (subagent)\n'
    printf 'librarian (subagent)\n'
    printf 'oracle (subagent)\n'
    printf 'orchestrator (primary)\n'
    exit 0
    ;;
  models)
    printf 'test/local-model\n'
    exit 0
    ;;
  run) ;;
  *) exit 0 ;;
esac

argv_dir="${DS_TEST_ARGV_DIR:?}"
n=0
[ -f "$argv_dir/.count" ] && n="$(<"$argv_dir/.count")"
n=$((n + 1))
printf '%s\n' "$n" > "$argv_dir/.count"
: > "$argv_dir/$n.argv"
for a in "$@"; do printf '%s\n' "$a" >> "$argv_dir/$n.argv"; done

agent=""
prev=""
for arg in "$@"; do
  [ "$prev" = "--agent" ] && agent="$arg"
  prev="$arg"
done

case "$agent" in
  ds-explorer)
    report='### SUMMARY\nok\n\n### FINDINGS\nnone\n\n### SEARCH COVERAGE\nnone\n\n### GAPS\nnone'
    ;;
  ds-reviewer)
    report='### VERDICT\nok\n\n### LITERAL EVIDENCE\nnone\n\n### ROOT CAUSE CANDIDATES\nnone\n\n### INSUFFICIENT\nnone'
    ;;
  *)
    report='### STATUS\nDONE\n\n### CHANGES\nnone\n\n### VERIFICATION\nran fake\n\n### NOT DONE\nnone\n\n### RISKS\nnone'
    ;;
esac
printf '{"type":"text","part":{"text":"%s"}}\n' "$report"
exit 0
EOF
chmod +x "$FAKE_BIN/opencode"

export PATH="$FAKE_BIN:$PATH"
export DS_TEST_ARGV_DIR="$ARGV_DIR"
export DS_STATE_DIR="$STATE_DIR"
export DS_CONFIG="$TEST_ROOT/no-such-config"
# The default gateway must stay away from the shared backend; this deliberately
# leaves DS_SERVE unset so the production default is covered.
export DS_MODEL_AUTODETECT=0
export DS_MODEL_ENDPOINT="http://stub.invalid:8000/v1"
export DS_MODEL_EXPLORER="test/local-model"
export DS_MODEL_REVIEWER="test/local-model"
export DS_MODEL_WORKER="test/local-model"
export DS_MODEL_RETRIES=1
export DS_IDLE_TIMEOUT=0
export DS_MAX_RUNTIME=30

fail() {
  printf '%s: FAIL — %s\n' "$1" "$2" >&2
  exit 1
}

# HOME is isolated inside the test temp directory for every ds-worker call, so a
# dangerous-directory guard can be exercised against "$HOME" without ever
# touching the real home directory. $TEST_ROOT stays macOS-canonical so the
# wrapper's `cd; pwd` resolution matches the $HOME string it compares against.
TEST_ROOT_REAL="$(cd "$TEST_ROOT" && pwd -P)"
export HOME="$TEST_ROOT_REAL/home"
mkdir -p "$HOME"

# Records every argv file created by `case_run` as one newline-separated blob.
ARGV=""
case_run() {   # $1 = case name; rest = ds-worker args (last arg is the prompt)
  local name="$1"; shift
  rm -f "$ARGV_DIR"/*.argv "$ARGV_DIR/.count"
  local out="$TEST_ROOT/$name.out" rc=0
  set +e
  "$DS_WORKER" "$@" >"$out" 2>"$TEST_ROOT/$name.err"
  rc=$?
  set -e
  printf '%s_rc=%s\n' "$name" "$rc" >> "$TEST_ROOT/rcs"
  ARGV=""
  local f
  for f in "$ARGV_DIR"/*.argv; do
    [ -e "$f" ] || continue
    ARGV="${ARGV}$(printf '\n')$(cat "$f")"
  done
  [ -n "$ARGV" ] || ARGV="<no opencode run recorded>"
}

run_count() {   # number of argv files recorded by the last case_run
  local n=0 f
  for f in "$ARGV_DIR"/*.argv; do
    [ -e "$f" ] || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}

: > "$TEST_ROOT/rcs"

# ---- 1. oracle: OMO subagent routed through orchestrator, no --model ----------
case_run oracle omo oracle --no-serve --dir "$TEST_ROOT" --json --quiet "review"

[ "$(grep '^oracle_rc=' "$TEST_ROOT/rcs" | cut -d= -f2)" = "0" ] \
  || fail "oracle dispatch" "expected exit 0, got: $(cat "$TEST_ROOT/rcs") / stderr: $(cat "$TEST_ROOT/oracle.err")"
[ "$(run_count)" -eq 1 ] \
  || fail "oracle dispatch" "expected exactly one opencode run, argv log was:$ARGV"
case "$ARGV" in
  *$'\n--agent\norchestrator\n'*) ;;
  *) fail "oracle dispatch" "expected --agent orchestrator, argv was:$ARGV" ;;
esac
case "$ARGV" in
  *$'\n--agent\noracle\n'*) fail "oracle dispatch" "must never pass --agent oracle (mode=subagent) to opencode run; argv was:$ARGV" ;;
esac
case "$ARGV" in
  *$'\n--model\n'*) fail "oracle dispatch" "must omit --model so the OMO Slim preset chooses the model; argv was:$ARGV" ;;
esac
case "$ARGV" in
  *"task(subagent_type='oracle')"*) ;;
  *) fail "oracle dispatch" "prompt must instruct task(subagent_type='oracle'); argv was:$ARGV" ;;
esac
jq -e '.role == "omo" and .agent == "orchestrator" and .dispatch == "omo-configured"
       and (.model == null) and .outcome == "CLEAN_RESULT" and .exit == 0' \
  "$TEST_ROOT/oracle.out" >/dev/null \
  || fail "oracle dispatch" "JSON must identify OMO-configured dispatch; got: $(cat "$TEST_ROOT/oracle.out")"
printf 'ds-worker omo oracle dispatches orchestrator with a task(subagent_type='"'"'oracle'"'"') instruction: PASS\n'

# ---- 2. council: routes through orchestrator, no --model, task() instruction --
case_run council omo council --no-serve --dir "$TEST_ROOT" --json --quiet "debate"

[ "$(grep '^council_rc=' "$TEST_ROOT/rcs" | cut -d= -f2)" = "0" ] \
  || fail "council dispatch" "expected exit 0, got: $(cat "$TEST_ROOT/rcs") / stderr: $(cat "$TEST_ROOT/council.err")"
[ "$(run_count)" -eq 1 ] \
  || fail "council dispatch" "expected exactly one opencode run, argv log was:$ARGV"
case "$ARGV" in
  *$'\n--agent\norchestrator\n'*) ;;
  *) fail "council dispatch" "expected --agent orchestrator, argv was:$ARGV" ;;
esac
case "$ARGV" in
  *$'\n--model\n'*) fail "council dispatch" "must omit --model so the OMO Slim preset chooses the model; argv was:$ARGV" ;;
esac
case "$ARGV" in
  *"task(subagent_type='council')"*) ;;
  *) fail "council dispatch" "prompt must instruct task(subagent_type='council'); argv was:$ARGV" ;;
esac
jq -e '.role == "omo" and .agent == "orchestrator" and .dispatch == "omo-configured"
       and (.model == null) and .outcome == "CLEAN_RESULT" and .exit == 0' \
  "$TEST_ROOT/council.out" >/dev/null \
  || fail "council dispatch" "JSON must identify OMO-configured dispatch; got: $(cat "$TEST_ROOT/council.out")"
printf "ds-worker omo council dispatches orchestrator with a task(subagent_type='council') instruction: PASS\n"

# ---- 2a. librarian: same orchestrator routing, single-seat instruction --------
case_run librarian omo librarian --no-serve --dir "$TEST_ROOT" --json --quiet "research"

[ "$(grep '^librarian_rc=' "$TEST_ROOT/rcs" | cut -d= -f2)" = "0" ] \
  || fail "librarian dispatch" "expected exit 0, got: $(cat "$TEST_ROOT/rcs") / stderr: $(cat "$TEST_ROOT/librarian.err")"
[ "$(run_count)" -eq 1 ] \
  || fail "librarian dispatch" "expected exactly one opencode run, argv log was:$ARGV"
case "$ARGV" in
  *$'\n--agent\norchestrator\n'*) ;;
  *) fail "librarian dispatch" "expected --agent orchestrator, argv was:$ARGV" ;;
esac
case "$ARGV" in
  *$'\n--agent\nlibrarian\n'*) fail "librarian dispatch" "must never pass --agent librarian (mode=subagent) to opencode run; argv was:$ARGV" ;;
esac
case "$ARGV" in
  *$'\n--model\n'*) fail "librarian dispatch" "must omit --model so the OMO Slim preset chooses the model; argv was:$ARGV" ;;
esac
case "$ARGV" in
  *"task(subagent_type='librarian')"*) ;;
  *) fail "librarian dispatch" "prompt must instruct task(subagent_type='librarian'); argv was:$ARGV" ;;
esac
jq -e '.role == "omo" and .agent == "orchestrator" and .dispatch == "omo-configured"
       and (.model == null) and .outcome == "CLEAN_RESULT" and .exit == 0' \
  "$TEST_ROOT/librarian.out" >/dev/null \
  || fail "librarian dispatch" "JSON must identify OMO-configured dispatch; got: $(cat "$TEST_ROOT/librarian.out")"
printf 'ds-worker omo librarian dispatches orchestrator with a task(subagent_type='"'"'librarian'"'"') instruction: PASS\n'

# ---- 2b. designer: same orchestrator routing, single-seat instruction ---------
case_run designer omo designer --no-serve --dir "$TEST_ROOT" --json --quiet "design"

[ "$(grep '^designer_rc=' "$TEST_ROOT/rcs" | cut -d= -f2)" = "0" ] \
  || fail "designer dispatch" "expected exit 0, got: $(cat "$TEST_ROOT/rcs") / stderr: $(cat "$TEST_ROOT/designer.err")"
[ "$(run_count)" -eq 1 ] \
  || fail "designer dispatch" "expected exactly one opencode run, argv log was:$ARGV"
case "$ARGV" in
  *$'\n--agent\norchestrator\n'*) ;;
  *) fail "designer dispatch" "expected --agent orchestrator, argv was:$ARGV" ;;
esac
case "$ARGV" in
  *$'\n--agent\ndesigner\n'*) fail "designer dispatch" "must never pass --agent designer (mode=subagent) to opencode run; argv was:$ARGV" ;;
esac
case "$ARGV" in
  *$'\n--model\n'*) fail "designer dispatch" "must omit --model so the OMO Slim preset chooses the model; argv was:$ARGV" ;;
esac
case "$ARGV" in
  *"task(subagent_type='designer')"*) ;;
  *) fail "designer dispatch" "prompt must instruct task(subagent_type='designer'); argv was:$ARGV" ;;
esac
jq -e '.role == "omo" and .agent == "orchestrator" and .dispatch == "omo-configured"
       and (.model == null) and .outcome == "CLEAN_RESULT" and .exit == 0' \
  "$TEST_ROOT/designer.out" >/dev/null \
  || fail "designer dispatch" "JSON must identify OMO-configured dispatch; got: $(cat "$TEST_ROOT/designer.out")"
printf 'ds-worker omo designer dispatches orchestrator with a task(subagent_type='"'"'designer'"'"') instruction: PASS\n'

# ---- 2c. fixer: same orchestrator routing, single-seat instruction ------------
case_run fixer omo fixer --no-serve --dir "$TEST_ROOT" --json --quiet "repair"

[ "$(grep '^fixer_rc=' "$TEST_ROOT/rcs" | cut -d= -f2)" = "0" ] \
  || fail "fixer dispatch" "expected exit 0, got: $(cat "$TEST_ROOT/rcs") / stderr: $(cat "$TEST_ROOT/fixer.err")"
[ "$(run_count)" -eq 1 ] \
  || fail "fixer dispatch" "expected exactly one opencode run, argv log was:$ARGV"
case "$ARGV" in
  *$'\n--agent\norchestrator\n'*) ;;
  *) fail "fixer dispatch" "expected --agent orchestrator, argv was:$ARGV" ;;
esac
case "$ARGV" in
  *$'\n--agent\nfixer\n'*) fail "fixer dispatch" "must never pass --agent fixer (mode=subagent) to opencode run; argv was:$ARGV" ;;
esac
case "$ARGV" in
  *$'\n--model\n'*) fail "fixer dispatch" "must omit --model so the OMO Slim preset chooses the model; argv was:$ARGV" ;;
esac
case "$ARGV" in
  *"task(subagent_type='fixer')"*) ;;
  *) fail "fixer dispatch" "prompt must instruct task(subagent_type='fixer'); argv was:$ARGV" ;;
esac
jq -e '.role == "omo" and .agent == "orchestrator" and .dispatch == "omo-configured"
       and (.model == null) and .outcome == "CLEAN_RESULT" and .exit == 0' \
  "$TEST_ROOT/fixer.out" >/dev/null \
  || fail "fixer dispatch" "JSON must identify OMO-configured dispatch; got: $(cat "$TEST_ROOT/fixer.out")"
printf 'ds-worker omo fixer dispatches orchestrator with a task(subagent_type='"'"'fixer'"'"') instruction: PASS\n'

# ---- 2d. fixer is treated as writing: --dir $HOME rejected before any run ------
case_run fixer_home omo fixer --no-serve --dir "$HOME" --json --quiet "repair"

fixer_home_rc="$(grep '^fixer_home_rc=' "$TEST_ROOT/rcs" | cut -d= -f2)"
[ "$fixer_home_rc" -ne 0 ] \
  || fail "fixer dangerous dir" "expected a non-zero exit for --dir \$HOME, got 0; out: $(cat "$TEST_ROOT/fixer_home.out")"
[ "$(run_count)" -eq 0 ] \
  || fail "fixer dangerous dir" "must fail before the fake opencode run; argv was:$ARGV"
grep -qi 'refus' "$TEST_ROOT/fixer_home.err" \
  || fail "fixer dangerous dir" "stderr should be a clear refusal; got: $(cat "$TEST_ROOT/fixer_home.err")"
printf 'ds-worker omo fixer refuses --dir $HOME before dispatch: PASS\n'

# ---- 3. ds-explorer through the gateway keeps the configured local model ------
case_run explorer omo ds-explorer --no-serve --dir "$TEST_ROOT" --json --quiet "map"

[ "$(grep '^explorer_rc=' "$TEST_ROOT/rcs" | cut -d= -f2)" = "0" ] \
  || fail "ds-explorer via omo" "expected exit 0, got: $(cat "$TEST_ROOT/rcs") / stderr: $(cat "$TEST_ROOT/explorer.err")"
[ "$(run_count)" -eq 1 ] \
  || fail "ds-explorer via omo" "expected exactly one opencode run, argv log was:$ARGV"
case "$ARGV" in
  *$'\n--agent\nds-explorer\n'*) ;;
  *) fail "ds-explorer via omo" "expected --agent ds-explorer, argv was:$ARGV" ;;
esac
case "$ARGV" in
  *$'\n--model\ntest/local-model\n'*) ;;
  *) fail "ds-explorer via omo" "expected --model test/local-model, argv was:$ARGV" ;;
esac
jq -e '.role == "omo" and .agent == "ds-explorer" and .model == "test/local-model"
       and .outcome == "CLEAN_RESULT" and .exit == 0' \
  "$TEST_ROOT/explorer.out" >/dev/null \
  || fail "ds-explorer via omo" "JSON must record the DS explorer role with its model; got: $(cat "$TEST_ROOT/explorer.out")"
printf 'ds-worker omo ds-explorer uses the DS explorer agent with the configured model: PASS\n'

# ---- 4. ds-reviewer through the gateway keeps the configured local model ------
case_run reviewer omo ds-reviewer --no-serve --dir "$TEST_ROOT" --json --quiet "audit"

[ "$(grep '^reviewer_rc=' "$TEST_ROOT/rcs" | cut -d= -f2)" = "0" ] \
  || fail "ds-reviewer via omo" "expected exit 0, got: $(cat "$TEST_ROOT/rcs") / stderr: $(cat "$TEST_ROOT/reviewer.err")"
[ "$(run_count)" -eq 1 ] \
  || fail "ds-reviewer via omo" "expected exactly one opencode run, argv log was:$ARGV"
case "$ARGV" in
  *$'\n--agent\nds-reviewer\n'*) ;;
  *) fail "ds-reviewer via omo" "expected --agent ds-reviewer, argv was:$ARGV" ;;
esac
case "$ARGV" in
  *$'\n--model\ntest/local-model\n'*) ;;
  *) fail "ds-reviewer via omo" "expected --model test/local-model, argv was:$ARGV" ;;
esac
jq -e '.role == "omo" and .agent == "ds-reviewer" and .model == "test/local-model"
       and .outcome == "CLEAN_RESULT" and .exit == 0' \
  "$TEST_ROOT/reviewer.out" >/dev/null \
  || fail "ds-reviewer via omo" "JSON must record the DS reviewer role with its model; got: $(cat "$TEST_ROOT/reviewer.out")"
printf 'ds-worker omo ds-reviewer uses the DS reviewer agent with the configured model: PASS\n'

# ---- 5. unsupported gateway agent fails before any opencode run ---------------
case_run unsupported omo not-an-omo-agent --no-serve --dir "$TEST_ROOT" --json --quiet "whatever"

unsupported_rc="$(grep '^unsupported_rc=' "$TEST_ROOT/rcs" | cut -d= -f2)"
[ "$unsupported_rc" -ne 0 ] \
  || fail "unsupported agent" "expected a non-zero exit, got 0; out: $(cat "$TEST_ROOT/unsupported.out")"
[ "$(run_count)" -eq 0 ] \
  || fail "unsupported agent" "must fail before the fake opencode run; argv was:$ARGV"
grep -qi 'omo' "$TEST_ROOT/unsupported.err" \
  || fail "unsupported agent" "stderr should name the omo gateway; got: $(cat "$TEST_ROOT/unsupported.err")"
grep -qi 'unsupported\|unknown\|expected' "$TEST_ROOT/unsupported.err" \
  || fail "unsupported agent" "stderr should be a clear validation error; got: $(cat "$TEST_ROOT/unsupported.err")"
printf 'ds-worker omo rejects an unsupported agent before dispatch: PASS\n'
