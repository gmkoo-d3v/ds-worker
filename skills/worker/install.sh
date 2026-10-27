#!/usr/bin/env bash
# install.sh — bootstrap the ds-worker 4-persona toolkit on macOS or Linux.
#
#   install.sh                      install everything (default)
#   install.sh --verify             read-only classification report, zero writes
#   install.sh --partial            keep going past conflicts, label them
#                                   skipped(conflict) instead of aborting
#   install.sh --replace-with-backup
#                                   resolve conflicts by first copying the
#                                   foreign file to <file>.bak.<timestamp>
#   install.sh --model <provider/model>
#                                   the model every role uses (DS_MODEL in
#                                   ~/.config/ds-worker/config); pick one that
#                                   `opencode models` lists — a local server or
#                                   a hosted API. Asked interactively when run
#                                   in a terminal with none configured.
#   install.sh --critic-model <provider/model>
#                                   the doc-critic model (DS_MODEL_CRITIC);
#                                   ideally a different model, for a
#                                   cross-model audit
#
# Ownership rules live in lib/ownership.sh: absent -> create, identical ->
# no-op, a file still matching its ledger hash -> overwrite, anything else ->
# conflict (listed, untouched, abort). This script never edits shell rc files,
# never edits opencode configuration, and never silently overwrites a file it
# did not install. The only setting it writes is DS_MODEL / DS_MODEL_CRITIC in
# its own config file. Provider auth stays manual: `opencode auth login`.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SELF_DIR/lib/ownership.sh" ] || {
  printf 'install.sh: lib/ownership.sh missing — incomplete checkout\n' >&2; exit 2; }
# shellcheck source=lib/ownership.sh
. "$SELF_DIR/lib/ownership.sh"
. "$SELF_DIR/lib/opencode-cli.sh"

SRC_BIN="$SELF_DIR/bin"
SRC_AGENTS="$SELF_DIR/agents"
SRC_CONFIG="$SELF_DIR/config.example"
BIN_DIR="$HOME/.local/bin"
AGENT_DIR="${OPENCODE_AGENT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/agent}"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/ds-worker/config"
LEDGER="$(own_ledger_path)"
COMMAND_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/command"
SKILL_DST="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skill/worker"
# STEP(command)/STEP(skill files): wired by plan todo 11. The command surface
# (/doc-review) and the skill footprint (SKILL.md, references/) install through
# the same ownership module — without this step a fresh machine would have the
# bin tools but no skill for opencode to load. Symlink-vs-copy decision for
# commands: COPY — symlink resolution for command files is undocumented
# behavior, and real files are the proven pattern (opencode ignores linked
# agent definitions; opencode-cli.md trap #2).

MODE="install"; PARTIAL=0; REPLACE=0; MODEL_ARG=""; CRITIC_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --verify)                MODE="verify" ;;
    --partial)               PARTIAL=1 ;;
    --replace-with-backup)   REPLACE=1 ;;
    --model)                 MODEL_ARG="${2:?--model needs provider/model}"; shift ;;
    --critic-model)          CRITIC_ARG="${2:?--critic-model needs provider/model}"; shift ;;
    -h|--help)
      sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 2 ;;
    *) printf 'install.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
valid_model_ref() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+/[^[:space:]]+$'; }
for m in "$MODEL_ARG" "$CRITIC_ARG"; do
  [ -z "$m" ] || valid_model_ref "$m" \
    || { printf 'install.sh: %s is not provider/model (as `opencode models` prints it)\n' "$m" >&2; exit 2; }
done

# Replace the last uncommented KEY= line of the config file, or append one.
set_config_key() {   # $1 = key, $2 = value
  local tmp
  tmp="$(mktemp "${CONFIG_FILE}.XXXXXX")"
  awk -v k="$1" -v v="$2" '
    { line[NR] = $0; if ($0 ~ "^[[:space:]]*" k "[[:space:]]*=") last = NR }
    END { for (i = 1; i <= NR; i++) print (i == last ? k "=" v : line[i]); if (!last) print k "=" v }
  ' "$CONFIG_FILE" >"$tmp"
  mv "$tmp" "$CONFIG_FILE"
}
config_value() {   # $1 = key; the last uncommented value in the config file
  [ -f "$CONFIG_FILE" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONFIG_FILE" | tail -1
}

# ── step 1: dependency preflight ───────────────────────────────────────────
missing=()
for tool in jq curl git perl; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  printf 'install.sh: missing required tools: %s\n' "${missing[*]}" >&2
  printf '  hint: Debian/Ubuntu  sudo apt-get install -y %s\n' "${missing[*]}" >&2
  printf '  hint: RHEL/Fedora    sudo dnf install -y %s\n' "${missing[*]}" >&2
  exit 2
fi
if command -v opencode >/dev/null 2>&1; then
  HAVE_OPENCODE=1
else
  HAVE_OPENCODE=0
  printf '\a' >&2
  printf '*** FILES-ONLY MODE *** opencode is not on PATH.\n' >&2
  printf '*** Files will be installed, but nothing can RUN until opencode is\n' >&2
  printf '*** installed and signed in (`opencode auth login`) — that stays manual.\n' >&2
fi

# ── step 2+3: classify every item before any write ─────────────────────────
# Statuses: ok | absent | updatable | link-drift | conflict
c_kind=(); c_name=(); c_src=(); c_dst=(); c_st=()
add() { c_kind+=("$1"); c_name+=("$2"); c_src+=("$3"); c_dst+=("$4"); c_st+=("$5"); }
cls_st() { # map an own_classify result onto the install status vocabulary
  case "$1" in identical) printf 'ok' ;; managed-updatable) printf 'updatable' ;; *) printf '%s' "$1" ;; esac
}

for src in "$SRC_BIN"/*; do [ -e "$src" ] || continue
  name="$(basename "$src")"; dst="$BIN_DIR/$name"
  if [ -L "$dst" ] && [ ! -e "$dst" ]; then st="conflict"
  elif [ ! -e "$dst" ] && [ ! -L "$dst" ]; then st="absent"
  else st="$(cls_st "$(own_classify "$src" "$dst" "$LEDGER")")"
  fi
  add "bin" "$name" "$src" "$dst" "$st"
done
for src in "$SRC_AGENTS"/*.md; do [ -e "$src" ] || continue
  name="$(basename "$src")"; dst="$AGENT_DIR/$name"
  if [ -L "$dst" ] && [ ! -e "$dst" ]; then st="conflict"
  elif [ -L "$dst" ]; then st="link-drift"   # opencode ignores linked agents
  else st="$(cls_st "$(own_classify "$src" "$dst" "$LEDGER")")"
  fi
  add "agents" "$name" "$src" "$dst" "$st"
done
for src in "$SELF_DIR"/command/*.md; do [ -e "$src" ] || continue
  name="$(basename "$src")"; dst="$COMMAND_DIR/$name"
  if [ -L "$dst" ] && [ ! -e "$dst" ]; then st="conflict"
  elif [ -L "$dst" ]; then st="link-drift"
  else st="$(cls_st "$(own_classify "$src" "$dst" "$LEDGER")")"
  fi
  add "command" "$name" "$src" "$dst" "$st"
done
for src in "$SELF_DIR/SKILL.md" "$SELF_DIR"/references/*.md; do [ -e "$src" ] || continue
  rel="${src#"$SELF_DIR"/}"; dst="$SKILL_DST/$rel"
  if [ -L "$dst" ] && [ ! -e "$dst" ]; then st="conflict"
  else st="$(cls_st "$(own_classify "$src" "$dst" "$LEDGER")")"
  fi
  add "skill" "$rel" "$src" "$dst" "$st"
done
if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then st="ok"; else st="absent"; fi
add "config" "ds-worker" "$SRC_CONFIG" "$CONFIG_FILE" "$st"

# ── verify mode: report only, never write ──────────────────────────────────
if [ "$MODE" = "verify" ]; then
  bad=0
  for i in "${!c_kind[@]}"; do
    case "${c_st[$i]}" in
      ok)       word="ok" ;;
      absent)   word="missing"; bad=1 ;;
      updatable) word="updatable (installed version is behind the repo)"; bad=1 ;;
      link-drift) word="symlink (ignored by opencode at run time)"; bad=1 ;;
      conflict) word="CONFLICT (foreign file, not recorded as installed)"; bad=1 ;;
    esac
    printf 'VERIFY %s/%s: %s\n' "${c_kind[$i]}" "${c_name[$i]}" "$word"
  done
  if [ "$HAVE_OPENCODE" -eq 1 ]; then
    lines="$(oc_agent_list || true)"
    for a in ds-explorer ds-reviewer ds-worker doc-critic; do
      grep -q "^${a} " <<<"$lines" || { printf 'VERIFY agents/%s.md: not visible to opencode\n' "$a"; bad=1; }
    done
  else
    printf 'VERIFY runtime: not-verified (opencode absent — files-only mode)\n'
  fi
  if [ -n "${DS_MODEL:-$(config_value DS_MODEL)}" ]; then
    printf 'VERIFY model: DS_MODEL=%s\n' "${DS_MODEL:-$(config_value DS_MODEL)}"
  else
    printf 'VERIFY model: not configured (install.sh --model <provider/model>)\n'; bad=1
  fi
  printf 'VERIFY ledger: %s\n' "$LEDGER"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) printf 'WARN %s is not on PATH — add it to your shell profile yourself.\n' "$BIN_DIR";;
  esac
  [ "$bad" -eq 0 ] && printf 'install.sh --verify: all components OK\n'
  exit "$bad"
fi

# ── install mode: conflicts decide the run before any write ────────────────
conflicts=0
for i in "${!c_st[@]}"; do [ "${c_st[$i]}" = "conflict" ] && conflicts=$((conflicts+1)); done
if [ "$conflicts" -gt 0 ] && [ "$PARTIAL" -eq 0 ] && [ "$REPLACE" -eq 0 ]; then
  for i in "${!c_st[@]}"; do
    [ "${c_st[$i]}" = "conflict" ] || continue
    printf 'CONFLICT %s/%s: %s exists, differs from the repo, and is not recorded as installed by this tool\n' \
      "${c_kind[$i]}" "${c_name[$i]}" "${c_dst[$i]}"
  done
  printf 'install.sh: %s conflict(s) — nothing was changed; resolve them, or re-run with --replace-with-backup (timestamped backup first) or --partial (skip and keep going)\n' "$conflicts" >&2
  exit 1
fi

summary=()
for i in "${!c_st[@]}"; do
  kind="${c_kind[$i]}"; name="${c_name[$i]}"; src="${c_src[$i]}"; dst="${c_dst[$i]}"; st="${c_st[$i]}"
  label=""
  case "$st" in
    ok) label="ok" ;;
    absent)
      mkdir -p "$(dirname "$dst")"
      if [ "$kind" = "bin" ]; then ln -s "$src" "$dst"; else cp "$src" "$dst"; fi
      own_record "$src" "$dst" "$LEDGER"; label="installed" ;;
    updatable)
      mkdir -p "$(dirname "$dst")"
      if [ "$kind" = "bin" ]; then rm -f "$dst"; ln -s "$src" "$dst"; else cp "$src" "$dst"; fi
      own_record "$src" "$dst" "$LEDGER"; label="installed" ;;
    link-drift)
      printf 'DRIFT %s/%s: live entry is a symlink — ignored by opencode at run time; replacing with a real file\n' "$kind" "$name"
      rm -f "$dst"; cp "$src" "$dst"
      own_record "$src" "$dst" "$LEDGER"; label="installed" ;;
    conflict)
      if [ "$REPLACE" -eq 1 ]; then
        backup="$(own_backup "$dst")" || backup=""
        [ -n "$backup" ] && printf 'BACKUP %s/%s: %s\n' "$kind" "$name" "$backup"
        rm -f "$dst"; mkdir -p "$(dirname "$dst")"
        if [ "$kind" = "bin" ]; then ln -s "$src" "$dst"; else cp "$src" "$dst"; fi
        own_record "$src" "$dst" "$LEDGER"; label="installed"
      elif [ "$PARTIAL" -eq 1 ]; then
        label="skipped(conflict)"
      fi ;;
  esac
  if [ -n "$label" ]; then
    comp="$kind/$name"
    if [ "$kind" = "config" ]; then comp="config"; fi
    summary+=("SUMMARY $comp: $label")
  fi
done

# ── model: the one setting a fresh install cannot guess ─────────────────────
if [ -z "$MODEL_ARG" ] && [ -z "$(config_value DS_MODEL)" ] && [ -t 0 ] && [ -t 1 ] \
   && [ "$HAVE_OPENCODE" -eq 1 ]; then
  printf 'No DS_MODEL configured. Models OpenCode can reach (first 20):\n'
  opencode models 2>/dev/null | head -20 | sed 's/^/  /'
  printf 'Model for every role, as provider/model (empty to skip): '
  read -r MODEL_ARG || MODEL_ARG=""
  [ -z "$MODEL_ARG" ] || valid_model_ref "$MODEL_ARG" \
    || { printf 'install.sh: %s is not provider/model; skipped\n' "$MODEL_ARG" >&2; MODEL_ARG=""; }
fi
for pair in "DS_MODEL=$MODEL_ARG" "DS_MODEL_CRITIC=$CRITIC_ARG"; do
  key="${pair%%=*}"; val="${pair#*=}"
  [ -n "$val" ] || continue
  set_config_key "$key" "$val"
  summary+=("SUMMARY config: $key=$val")
  if [ "$HAVE_OPENCODE" -eq 1 ] && ! opencode models 2>/dev/null | grep -qxF "$val"; then
    summary+=("WARN $key: $val is not in 'opencode models' — add the provider to opencode.jsonc or sign in (opencode auth login)")
  fi
done
[ -n "$(config_value DS_MODEL)" ] \
  || summary+=("WARN model: no DS_MODEL configured — ds-worker refuses to run until you set it (install.sh --model <provider/model>)")

# opencode visibility: what will actually load at session start.
if [ "$HAVE_OPENCODE" -eq 1 ]; then
  lines="$(oc_agent_list || true)"
  vis_ok=1
  for a in ds-explorer ds-reviewer ds-worker doc-critic; do
    grep -q "^${a} " <<<"$lines" || vis_ok=0
  done
  if [ "$vis_ok" -eq 1 ]; then summary+=("SUMMARY opencode: ok")
  else summary+=("SUMMARY opencode: not-verified (agents installed but not visible in 'opencode debug agents')"); fi
else
  summary+=("SUMMARY opencode: not-verified (files-only mode)")
fi

for line in "${summary[@]}"; do printf '%s\n' "$line"; done
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf 'WARN %s is not on PATH — the ds-* commands and sync-agents will not be found; add it to your shell profile yourself (this script never edits rc files).\n' "$BIN_DIR" >&2 ;;
esac
printf 'MANUAL STEP: provider auth and any provider-URL config stay with you —\n'
printf '  sign in with `opencode auth login`; see SKILL.md "When it fails".\n'
exit 0
