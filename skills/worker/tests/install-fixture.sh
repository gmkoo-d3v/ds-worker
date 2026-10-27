#!/usr/bin/env bash
# tests/install-fixture.sh — QA harness for install.sh + the ownership ledger.
#
# Everything runs inside a throwaway $HOME built by mktemp -d: the real HOME,
# ~/.config/opencode, ~/.local/bin and ~/.config/ds-worker are never touched.
# `opencode` is a PATH shim so no scenario can reach a model or the network.
#
# Scenarios (one PASS/FAIL line each, exit 0 only if every line is PASS):
#   1  fresh-install            first install exits 0 and lands every artifact
#   2  verify-clean             install.sh --verify agrees the tree is healthy
#   3  idempotent-rerun         second install changes zero files (find -newer)
#   4  sabotage-divergent-agent divergent agent file -> abort, nothing touched
#   5  sabotage-bin-squat      real file squatting a bin symlink -> abort
#   6  sabotage-dangling-link  dangling symlink in the agent dir -> abort
#   7  replace-with-backup     --replace-with-backup resolves the conflict
#   8  partial-mode            --partial skips the conflict, installs the rest
#   9  config-no-overwrite     an existing host config is never overwritten
#   10 sync-agents-conflict    sync-agents refuses a divergent file, then syncs
#   11 model-settings          --model/--critic-model replace their line in
#                              place; an invalid --model changes nothing
#
# Style: plain bash asserts, no colors; failure dumps the captured output.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

REAL_HOME="$HOME"
WORK="$(mktemp -d)"
case "$WORK" in
  /tmp/*|/var/tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) ;;
  *) printf 'install-fixture: mktemp landed outside /tmp (%s) — aborting\n' "$WORK" >&2; exit 2 ;;
esac
HOME_FIX="$WORK/home"
SHIM="$WORK/shim"
OUT="$WORK/out"
MARKER="$WORK/marker"
SNAP_A="$WORK/snap_a"
SNAP_B="$WORK/snap_b"
cleanup() { [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# ── isolated environment ────────────────────────────────────────────────────
mkdir -p "$HOME_FIX" "$SHIM"
export HOME="$HOME_FIX"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_DATA_HOME="$HOME/.local/share"
unset DS_STATE_DIR OPENCODE_AGENT_DIR

BIN_DIR="$HOME/.local/bin"
AGENT_DIR="$XDG_CONFIG_HOME/opencode/agent"
CONFIG_FILE="$XDG_CONFIG_HOME/ds-worker/config"
LEDGER="$XDG_STATE_HOME/ds-worker/installed.sha256"

# opencode shim: answers v2 `debug agents` from the 4 personas, nothing else.
# Never execs a model, never touches the network.
cat >"$SHIM/opencode" <<'SHIM'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "debug agents")
    printf '%s\n' '[{"name":"ds-explorer","mode":"primary"},{"name":"ds-reviewer","mode":"primary"},' \
      '{"name":"ds-worker","mode":"primary"},{"name":"doc-critic","mode":"primary"}]' ;;
esac
exit 0
SHIM
chmod +x "$SHIM/opencode"
export PATH="$SHIM:$PATH"

# install.sh's dependency preflight needs these from the real PATH.
for tool in jq curl git perl; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'install-fixture: required tool %s missing from PATH — cannot run\n' "$tool" >&2
    exit 2
  }
done

FAILED=0
S_FAIL=""
pass()  { printf 'PASS %s\n' "$1"; }
sfail() { S_FAIL="$S_FAIL$1; "; }
finish() {
  local name="$1"
  if [ -z "$S_FAIL" ]; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s — %s\n' "$name" "${S_FAIL% }"
    printf '     ---- captured output ----\n'
    sed 's/^/     | /' "$OUT" 2>/dev/null || printf '     | (no output)\n'
    FAILED=1
  fi
  S_FAIL=""
}

run_install() { RC=0; "$REPO_DIR/install.sh" "$@" >"$OUT" 2>&1 || RC=$?; }
run_sync()    { RC=0; "$REPO_DIR/bin/sync-agents" "$@" >"$OUT" 2>&1 || RC=$?; }

snapshot() { # snapshot <file> — content of every regular file + every symlink
  {
    find "$HOME_FIX" -type l ! -name '*.bak.*' | LC_ALL=C sort |
      while IFS= read -r l; do printf 'L %s -> %s\n' "$l" "$(readlink "$l")"; done
    find "$HOME_FIX" -type f ! -name '*.bak.*' | LC_ALL=C sort |
      while IFS= read -r f; do printf 'F %s %s\n' "$f" "$(shasum -a 256 <"$f" | cut -d" " -f1)"; done
  }
}
backups_count() { find "$HOME_FIX" -name '*.bak.*' | wc -l; }

restore_agent() { cp "$REPO_DIR/agents/$1" "$AGENT_DIR/$1"; }
relink_bin()    { rm -f "$BIN_DIR/$1"; ln -s "$REPO_DIR/bin/$1" "$BIN_DIR/$1"; }
is_identical()  { [ -f "$1" ] && cmp -s "$1" "$2"; }

printf '# install-fixture: repo=%s\n#                      fixture HOME=%s\n' \
  "$REPO_DIR" "$HOME_FIX"
[ "$HOME" = "$REAL_HOME" ] && { printf 'install-fixture: HOME redirect failed — aborting\n' >&2; exit 2; }

BIN_TOOLS="ds-doctor ds-serve ds-worker ds-worker-rr sync-agents"
AGENT_FILES="doc-critic.md ds-explorer.md ds-reviewer.md ds-worker.md"

# ── 1. fresh-install ────────────────────────────────────────────────────────
run_install --model local/test-model
[ "$RC" -eq 0 ] || sfail "exit $RC (expected 0)"
for t in $BIN_TOOLS; do
  [ -L "$BIN_DIR/$t" ] || sfail "bin/$t not a symlink"
  [ "$(readlink "$BIN_DIR/$t")" = "$REPO_DIR/bin/$t" ] ||
    sfail "bin/$t symlink does not resolve into the repo"
done
for a in $AGENT_FILES; do
  is_identical "$AGENT_DIR/$a" "$REPO_DIR/agents/$a" || sfail "agents/$a missing or altered"
done
[ -f "$CONFIG_FILE" ] || sfail "config not created"
[ -f "$LEDGER" ] || sfail "ledger not written"
grep -q "SUMMARY" "$OUT" || sfail "no SUMMARY lines"
[ "$(grep -c '^DS_MODEL=' "$CONFIG_FILE")" = 1 ] && grep -qx 'DS_MODEL=local/test-model' "$CONFIG_FILE" \
  || sfail "--model did not write exactly one DS_MODEL=local/test-model line"
finish "fresh-install"

# ── 2. verify-clean ─────────────────────────────────────────────────────────
run_install --verify
[ "$RC" -eq 0 ] || sfail "exit $RC (expected 0)"
grep -qi "conflict" "$OUT" && sfail "--verify reported a conflict on a clean tree"
finish "verify-clean"

# ── 3. idempotent-rerun ─────────────────────────────────────────────────────
sleep 1.2
touch "$MARKER"
sleep 1.2
run_install
[ "$RC" -eq 0 ] || sfail "second install exit $RC"
CHANGED="$(find "$HOME_FIX" -newer "$MARKER" | wc -l)"
[ "$CHANGED" -eq 0 ] || sfail "$CHANGED file(s) changed on rerun: $(find "$HOME_FIX" -newer "$MARKER" | sed -n 1,3p | tr '\n' ' ')"
[ "$(backups_count)" -eq 0 ] || sfail "backup files accumulated on a clean rerun"
finish "idempotent-rerun"

# ── 4. sabotage-divergent-agent ─────────────────────────────────────────────
printf '\n<!-- locally edited, do not lose -->\n' >>"$AGENT_DIR/ds-worker.md"
snapshot >"$SNAP_A"
run_install
[ "$RC" -ne 0 ] || sfail "exit 0 — a divergent foreign file was silently accepted"
grep -q "CONFLICT" "$OUT" || sfail "no CONFLICT line in the abort report"
grep -q "ds-worker.md" "$OUT" || sfail "the conflict report does not name ds-worker.md"
[ "$(grep -c "CONFLICT" "$OUT")" -eq 1 ] || sfail "conflict list not limited to the divergent file"
snapshot >"$SNAP_B"
cmp -s "$SNAP_A" "$SNAP_B" || sfail "the aborted run touched files"
finish "sabotage-divergent-agent"
restore_agent ds-worker.md

# ── 5. sabotage-bin-squat ───────────────────────────────────────────────────
rm -f "$BIN_DIR/ds-worker"
printf '#!/usr/bin/env bash\necho "squatter"\n' >"$BIN_DIR/ds-worker"
chmod +x "$BIN_DIR/ds-worker"
snapshot >"$SNAP_A"
run_install
[ "$RC" -ne 0 ] || sfail "exit 0 — a foreign real file squatting a bin path was accepted"
grep -q "CONFLICT" "$OUT" || sfail "no CONFLICT line for the squatted bin path"
grep -q "ds-worker" "$OUT" || sfail "the conflict report does not name ds-worker"
snapshot >"$SNAP_B"
cmp -s "$SNAP_A" "$SNAP_B" || sfail "the aborted run touched other files"
finish "sabotage-bin-squat"
rm -f "$BIN_DIR/ds-worker"
relink_bin ds-worker

# ── 6. sabotage-dangling-link ───────────────────────────────────────────────
rm -f "$AGENT_DIR/doc-critic.md"
ln -s "$WORK/does-not-exist.md" "$AGENT_DIR/doc-critic.md"
snapshot >"$SNAP_A"
run_install
[ "$RC" -ne 0 ] || sfail "exit 0 — a dangling symlink was accepted"
grep -q "CONFLICT" "$OUT" || sfail "no CONFLICT line for the dangling symlink"
grep -q "doc-critic" "$OUT" || sfail "the conflict report does not name doc-critic"
snapshot >"$SNAP_B"
cmp -s "$SNAP_A" "$SNAP_B" || sfail "the aborted run touched other files"
finish "sabotage-dangling-link"
rm -f "$AGENT_DIR/doc-critic.md"
restore_agent doc-critic.md

# ── 7. replace-with-backup ──────────────────────────────────────────────────
BAK_BEFORE="$(backups_count)"
printf '\n<!-- overwritten by mistake -->\n' >>"$AGENT_DIR/ds-explorer.md"
cp "$AGENT_DIR/ds-explorer.md" "$WORK/ds-explorer.sabotaged"
run_install --replace-with-backup
[ "$RC" -eq 0 ] || sfail "exit $RC (expected 0)"
BAK_NOW="$(backups_count)"
[ "$BAK_NOW" -gt "$BAK_BEFORE" ] || sfail "no timestamped backup was created"
[ "$(find "$HOME_FIX" -name 'ds-explorer.md.bak.*' | wc -l)" -eq 1 ] ||
  sfail "expected exactly one backup for the conflicting agent file"
cmp -s "$AGENT_DIR/ds-explorer.md.bak."* "$WORK/ds-explorer.sabotaged" ||
  sfail "the backup does not hold the pre-replace content"
is_identical "$AGENT_DIR/ds-explorer.md" "$REPO_DIR/agents/ds-explorer.md" ||
  sfail "the conflicting file was not replaced with the repo version"
RC_VERIFY=$("$REPO_DIR/install.sh" --verify >/dev/null 2>&1; printf '%s' "$?")
[ "$RC_VERIFY" -eq 0 ] || sfail "--verify still reports problems after the replace"
finish "replace-with-backup"

# ── 8. partial-mode ─────────────────────────────────────────────────────────
rm -f "$BIN_DIR/ds-serve"
printf 'not the tool\n' >"$BIN_DIR/ds-serve"
run_install --partial
[ "$RC" -eq 0 ] || sfail "exit $RC (expected 0 with --partial)"
grep -q "skipped(conflict)" "$OUT" || sfail "no skipped(conflict) label in the summary"
grep -E "^SUMMARY bin/ds-serve: skipped\(conflict\)$" "$OUT" >/dev/null ||
  sfail "bin/ds-serve is not labelled skipped(conflict)"
[ "$(shasum -a 256 <"$BIN_DIR/ds-serve" | cut -d" " -f1)" = "$(printf 'not the tool\n' | shasum -a 256 | cut -d" " -f1)" ] ||
  sfail "--partial overwrote the conflicting file instead of skipping it"
is_identical "$BIN_DIR/ds-doctor" "$REPO_DIR/bin/ds-doctor" ||
  sfail "another bin tool was not left/kept installed"
finish "partial-mode"
rm -f "$BIN_DIR/ds-serve"
relink_bin ds-serve

# ── 9. config-no-overwrite ──────────────────────────────────────────────────
printf '\nDS_MODEL_CRITIC = host-owned-value\n' >>"$CONFIG_FILE"
cp "$CONFIG_FILE" "$WORK/config.before"
run_install
[ "$RC" -eq 0 ] || sfail "exit $RC (expected 0)"
cmp -s "$CONFIG_FILE" "$WORK/config.before" || sfail "the host config file was overwritten"
grep -E "^SUMMARY config: ok$" "$OUT" >/dev/null || sfail "config label is not ok"
finish "config-no-overwrite"

# ── 10. sync-agents-conflict ────────────────────────────────────────────────
BAK_BEFORE="$(backups_count)"
printf '\n<!-- edited in the live registry -->\n' >>"$AGENT_DIR/ds-reviewer.md"
snapshot >"$SNAP_A"
run_sync --install
[ "$RC" -ne 0 ] || sfail "sync-agents --install accepted a divergent live file"
grep -q "CONFLICT" "$OUT" || sfail "sync-agents did not report CONFLICT"
grep -q "ds-reviewer" "$OUT" || sfail "the conflict report does not name ds-reviewer"
snapshot >"$SNAP_B"
cmp -s "$SNAP_A" "$SNAP_B" || sfail "the aborted install touched files"
restore_agent ds-reviewer.md
run_sync
[ "$RC" -eq 0 ] || sfail "sync-agents check after restore exit $RC"
grep -q "in sync" "$OUT" || sfail "sync-agents check does not report 'in sync'"
[ "$(backups_count)" -eq "$BAK_BEFORE" ] || sfail "backups accumulated during scenario 10"
finish "sync-agents-conflict"

# ── 11. model-settings ──────────────────────────────────────────────────────
# --model / --critic-model replace their one line; the rest of the file stays.
printf 'DS_IDLE_TIMEOUT=77\n' >>"$CONFIG_FILE"
run_install --model local/other-model --critic-model local/judge-model
[ "$RC" -eq 0 ] || sfail "exit $RC (expected 0)"
[ "$(grep -c '^DS_MODEL=' "$CONFIG_FILE")" = 1 ] && grep -qx 'DS_MODEL=local/other-model' "$CONFIG_FILE" \
  || sfail "DS_MODEL was not replaced in place"
grep -qx 'DS_MODEL_CRITIC=local/judge-model' "$CONFIG_FILE" || sfail "DS_MODEL_CRITIC not written"
grep -qx 'DS_IDLE_TIMEOUT=77' "$CONFIG_FILE" || sfail "an unrelated setting was lost"
CFG_BEFORE="$(shasum -a 256 <"$CONFIG_FILE")"
run_install --model not-a-model-ref
[ "$RC" -eq 2 ] || sfail "invalid --model exit $RC (expected 2)"
[ "$(shasum -a 256 <"$CONFIG_FILE")" = "$CFG_BEFORE" ] || sfail "invalid --model changed the config"
finish "model-settings"

if [ "$FAILED" -eq 0 ]; then
  printf '# install-fixture: ALL SCENARIOS PASS\n'
  exit 0
else
  printf '# install-fixture: FAILURES PRESENT\n' >&2
  exit 1
fi
