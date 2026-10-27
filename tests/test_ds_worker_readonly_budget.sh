#!/usr/bin/env bash
# Read-only exploration-budget notice.
#
# The initial prompt of a READ-ONLY run (legacy explorer/reviewer and the omo
# ds-explorer/ds-reviewer aliases) must carry one advisory budget notice,
# appended after the envelope. Writing `worker`, the OMO-configured built-ins,
# and the read-only recovery prompt must not carry it. The notice is guidance
# only — the wrapper neither counts nor enforces steps — so the assertion is
# purely about the prompt bytes the fake opencode receives.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DS_WORKER="$ROOT/skills/worker/bin/ds-worker"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ds-worker-budget.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"
STATE_DIR="$TEST_ROOT/state"
ARGV_DIR="$TEST_ROOT/argv"

NOTICE='Read-only budget notice: Treat any configured agentic-step limit as a safety ceiling, not a target or a tool-call quota. Prioritize the highest-value evidence. Near the ceiling, stop initiating new searches and emit the required report with explicit evidence gaps; never end with tools only.'

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$STATE_DIR" "$ARGV_DIR"

# Fake OpenCode: `run` records every argv entry (the prompt is the last one) to
# $DS_TEST_ARGV_DIR/<n>.argv. With DS_TEST_RECOVERY_EMPTY=1 the --session
# (recovery) call emits no text, so the wrapper keeps the initial prompt as the
# reported text and the recovery argv is still recorded.
cat > "$FAKE_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# v2 `opencode debug agents` emits a JSON array; write the rows as `name (mode)`.
v2_agents() { jq -Rn '[inputs | capture("^(?<name>.+) \\((?<mode>[a-z]+)\\)$") + {hidden: false}]'; }

case "${1:-}" in
  debug)
    [ "${2:-}" = "agents" ] || exit 0
    {
      printf 'ds-explorer (all)\n'
      printf 'ds-reviewer (all)\n'
      printf 'ds-worker (all)\n'
      printf 'oracle (subagent)\n'
      printf 'council (subagent)\n'
      printf 'librarian (subagent)\n'
      printf 'designer (subagent)\n'
      printf 'fixer (subagent)\n'
      printf 'orchestrator (primary)\n'
    } | v2_agents
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
if [ "${1:-}" = "agent" ] && [ "${2:-}" = "list" ]; then
  printf 'ds-explorer (all)\n'
  printf 'ds-reviewer (all)\n'
  printf 'ds-worker (all)\n'
  printf 'orchestrator (primary)\n'
  exit 0
fi
[ "${1:-}" = "run" ] || exit 0
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

recovery=0
for arg in "$@"; do
  [ "$arg" = "--session" ] && recovery=1
done
if [ "$recovery" -eq 1 ] && [ "${DS_TEST_RECOVERY_EMPTY:-0}" = "1" ]; then
  printf '{"type":"step_start","sessionID":"ses-recovery","part":{}}\n'
  exit 0
fi
if [ "${DS_TEST_INITIAL_EMPTY:-0}" = "1" ]; then
  printf '{"type":"step_start","sessionID":"ses-budget","part":{}}\n'
  printf '{"type":"tool_use","sessionID":"ses-budget","part":{"tool":"read"}}\n'
  printf '{"type":"text","sessionID":"ses-budget","part":{"text":"partial evidence"}}\n'
  exit 0
fi

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
printf '{"type":"text","sessionID":"ses-budget","part":{"text":"%s"}}\n' "$report"
exit 0
EOF
chmod +x "$FAKE_BIN/opencode"

export PATH="$FAKE_BIN:$PATH"
export DS_TEST_ARGV_DIR="$ARGV_DIR"
export DS_STATE_DIR="$STATE_DIR"
export DS_CONFIG="$TEST_ROOT/no-such-config"
export DS_SERVE=off
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

# ---- 1. read-only roles carry exactly one notice, appended after the envelope --
for spec in \
  "direct_explorer|explorer|ds-explorer" \
  "direct_reviewer|reviewer|ds-reviewer" \
  "omo_explorer|omo ds-explorer|ds-explorer" \
  "omo_reviewer|omo ds-reviewer|ds-reviewer"; do
  IFS='|' read -r name role agent <<<"$spec"
  rm -f "$ARGV_DIR"/*.argv "$ARGV_DIR/.count"
  prompt="PROMPT-$name"
  set -- $role
  set +e
  "$DS_WORKER" "$@" --no-serve --dir "$TEST_ROOT" --json --quiet "$prompt" \
    >"$TEST_ROOT/$name.out" 2>"$TEST_ROOT/$name.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "$name" "expected exit 0, got $rc; stderr: $(cat "$TEST_ROOT/$name.err")"

  argv_files=( "$ARGV_DIR"/*.argv )
  [ "${#argv_files[@]}" -eq 1 ] \
    || fail "$name" "expected exactly one opencode run, got ${#argv_files[@]}"
  argv="$(cat "${argv_files[0]}")"

  case "$argv" in
    *$'\n--agent\n'"$agent"$'\n'*) ;;
    *) fail "$name" "expected --agent $agent; argv was:
$argv" ;;
  esac

  # The prompt is the last argv entry, after the `--` terminator, and it
  # contains embedded newlines — so assert on the recorded argv blob rather than
  # on a single line. The wrapper appends the notice to the envelope, so the
  # recorded run must end with "<envelope text>\n\n<notice>".
  count=0
  rest="$argv"
  while [ "$rest" != "${rest#*"$NOTICE"}" ]; do
    count=$((count + 1))
    rest="${rest#*"$NOTICE"}"
  done
  [ "$count" -eq 1 ] \
    || fail "$name" "expected exactly one budget notice in the prompt, found $count"

  # The recorded run must end with the notice (the file's trailing newline is
  # the argv-entry separator, stripped by command substitution).
  [ "$argv" = "${argv%"$NOTICE"}$NOTICE" ] \
    || fail "$name" "the prompt argument must end with the budget notice"

  # Byte-preserved user prompt, and the notice appended after the envelope text.
  case "$argv" in
    *$'\n--\n[supervisor task | role='*) ;;
    *) fail "$name" "envelope must follow the -- terminator; argv was:
$argv" ;;
  esac
  case "$argv" in
    *"$prompt"*) ;;
    *) fail "$name" "user prompt must be byte-preserved; argv was:
$argv" ;;
  esac
  case "$argv" in
    *"say so explicitly rather than filling the gap with a plausible guess."$'\n\n'"$NOTICE"*) ;;
    *) fail "$name" "notice must be appended after the existing envelope text; argv was:
$argv" ;;
  esac
  printf 'ds-worker %s prompt carries exactly one budget notice after the envelope: PASS\n' "$role"
done

# ---- 2. writing worker and OMO-configured built-ins carry no notice ------------
for spec in \
  "worker|worker" \
  "omo_oracle|omo oracle" \
  "omo_council|omo council" \
  "omo_librarian|omo librarian" \
  "omo_designer|omo designer" \
  "omo_fixer|omo fixer"; do
  IFS='|' read -r name role <<<"$spec"
  rm -f "$ARGV_DIR"/*.argv "$ARGV_DIR/.count"
  set -- $role
  set +e
  "$DS_WORKER" "$@" --no-serve --dir "$TEST_ROOT" --json --quiet "PROMPT-$name" \
    >"$TEST_ROOT/$name.out" 2>"$TEST_ROOT/$name.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "$name" "expected exit 0, got $rc; stderr: $(cat "$TEST_ROOT/$name.err")"

  argv_files=( "$ARGV_DIR"/*.argv )
  [ "${#argv_files[@]}" -eq 1 ] \
    || fail "$name" "expected exactly one opencode run, got ${#argv_files[@]}"
  case "$(cat "${argv_files[0]}")" in
    *"budget notice"*) fail "$name" "must not receive the read-only budget notice" ;;
  esac
  case "$(cat "${argv_files[0]}")" in
    *"$NOTICE"*) fail "$name" "must not receive the read-only budget notice" ;;
  esac
  printf 'ds-worker %s prompt carries no budget notice: PASS\n' "$role"
done

# ---- 2b. the same roles DO carry the notice when recovery is disabled ----------
# Proves the exclusion above is about the OMO-configured dispatch and the writing
# role, not about the agent: with DS_AUTO_RECOVER_READONLY=0 the read-only roles
# still get exactly one notice.
for spec in \
  "no_recover_explorer|explorer|ds-explorer" \
  "no_recover_reviewer|reviewer|ds-reviewer" \
  "no_recover_omo_explorer|omo ds-explorer|ds-explorer" \
  "no_recover_omo_reviewer|omo ds-reviewer|ds-reviewer"; do
  IFS='|' read -r name role agent <<<"$spec"
  rm -f "$ARGV_DIR"/*.argv "$ARGV_DIR/.count"
  set -- $role
  set +e
  DS_AUTO_RECOVER_READONLY=0 "$DS_WORKER" "$@" --no-serve --dir "$TEST_ROOT" \
    --json --quiet "PROMPT-$name" >"$TEST_ROOT/$name.out" 2>"$TEST_ROOT/$name.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "$name" "expected exit 0, got $rc; stderr: $(cat "$TEST_ROOT/$name.err")"
  argv_files=( "$ARGV_DIR"/*.argv )
  [ "${#argv_files[@]}" -eq 1 ] \
    || fail "$name" "expected exactly one opencode run, got ${#argv_files[@]}"
  argv="$(cat "${argv_files[0]}")"
  case "$argv" in
    *$'\n--agent\n'"$agent"$'\n'*) ;;
    *) fail "$name" "expected --agent $agent" ;;
  esac
  count=0
  rest="$argv"
  while [ "$rest" != "${rest#*"$NOTICE"}" ]; do
    count=$((count + 1))
    rest="${rest#*"$NOTICE"}"
  done
  [ "$count" -eq 1 ] \
    || fail "$name" "expected exactly one budget notice, found $count"
  printf 'ds-worker %s prompt still carries the notice with recovery disabled: PASS\n' "$role"
done

# ---- 3. recovery prompt is the existing template, with no notice ---------------
rm -f "$ARGV_DIR"/*.argv "$ARGV_DIR/.count"
set +e
DS_TEST_INITIAL_EMPTY=1 "$DS_WORKER" explorer --no-serve --dir "$TEST_ROOT" \
  --json --quiet "PROMPT-recovery" >"$TEST_ROOT/recovery.out" 2>"$TEST_ROOT/recovery.err"
rc=$?
set -e
# The recovery fixture emits no report, so the wrapper must report the failed
# recovery with exit 4 while still having made exactly one continuation call.
[ "$rc" -eq 4 ] \
  || fail "recovery prompt" "expected exit 4 (recovery produced no report), got $rc; stderr: $(cat "$TEST_ROOT/recovery.err")"
jq -e '.recovery_attempted and (.recovered | not)' "$TEST_ROOT/recovery.out" >/dev/null \
  || fail "recovery prompt" "expected a recovery attempt; got: $(cat "$TEST_ROOT/recovery.out")"

argv_files=( "$ARGV_DIR"/*.argv )
[ "${#argv_files[@]}" -eq 2 ] \
  || fail "recovery prompt" "expected an initial and a recovery run, got ${#argv_files[@]}"

initial_argv="$(cat "${argv_files[0]}")"
recovery_argv="$(cat "${argv_files[1]}")"
case "$initial_argv" in
  *$'\n--session\n'*) fail "recovery prompt" "first run must not pass --session" ;;
esac
case "$recovery_argv" in
  *$'\n--session\n'*) ;;
  *) fail "recovery prompt" "second run must continue the same session (--session)" ;;
esac
case "$recovery_argv" in
  *$'\n--continue\n'*) ;;
  *) fail "recovery prompt" "second run must explicitly mark session continuation (--continue)" ;;
esac

recovery_prompt="${recovery_argv##*$'\n'}"
expected_recovery='Your previous read-only explorer run ended before emitting the required final report. Do not use tools or perform more searches. Using only the work already completed in this session, emit the required explorer report now in the exact required format. If evidence is incomplete, say so explicitly in the required gap section. Do not claim verification without evidence.'
[ "$recovery_prompt" = "$expected_recovery" ] \
  || fail "recovery prompt" "recovery prompt must stay exactly the existing template, got: $recovery_prompt"
case "$recovery_prompt" in
  *"budget notice"*) fail "recovery prompt" "recovery prompt must not carry the budget notice" ;;
esac
printf 'ds-worker read-only recovery prompt is unchanged and carries no budget notice: PASS\n'
