#!/usr/bin/env bash
# Install the 'worker' skill: OpenCode agents, PATH shims, Claude/Codex skill links.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$ROOT/skills/worker"
AGENT_DST="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/agent"
BIN_DST="${DS_BIN_DIR:-$HOME/.local/bin}"
SKILL_NAME="worker"
SKILL_LINK_DIRS=("$HOME/.claude/skills" "$HOME/.codex/skills")

ok()   { printf '  ok    %s\n' "$1"; }
warn() { printf '  warn  %s\n' "$1" >&2; }
die()  { printf 'install: %s\n' "$1" >&2; exit 1; }

command -v opencode >/dev/null || die "opencode not found on PATH — https://opencode.ai/docs/"
command -v jq >/dev/null       || die "jq not found on PATH"

# NOTE: these must be real files. OpenCode lists symlinked agents in
# `opencode agent list` but does NOT apply their prompt or permissions at run
# time — the run silently uses the default agent instead. Verified on 1.18.18.
# Re-run this script after editing an agent definition.
echo "==> OpenCode agents -> $AGENT_DST  (copied, not symlinked)"
mkdir -p "$AGENT_DST"
for f in "$SKILL_DIR"/agents/*.md; do
  rm -f "$AGENT_DST/$(basename "$f")"
  cp "$f" "$AGENT_DST/$(basename "$f")"
  ok "$(basename "$f")"
done

echo "==> commands -> $BIN_DST"
mkdir -p "$BIN_DST"
for f in "$SKILL_DIR"/bin/*; do
  [ -x "$f" ] || continue
  ln -sfn "$f" "$BIN_DST/$(basename "$f")"
  ok "$(basename "$f")"
done
case ":$PATH:" in
  *":$BIN_DST:"*) ;;
  *) warn "$BIN_DST is not on PATH — add: export PATH=\"$BIN_DST:\$PATH\"" ;;
esac

echo "==> skill links"
for d in "${SKILL_LINK_DIRS[@]}"; do
  if [ -d "$d" ] || mkdir -p "$d" 2>/dev/null; then
    rm -rf "$d/ds-supervisor"          # previous name, if present
    ln -sfn "$SKILL_DIR" "$d/$SKILL_NAME"
    ok "$d/$SKILL_NAME"
  else
    warn "could not create $d — skipped"
  fi
done

CONFIG_DST="${XDG_CONFIG_HOME:-$HOME/.config}/ds-worker/config"
echo "==> config -> $CONFIG_DST"
# Per-user, deliberately NOT inside the skill: the skill directory is a git repo
# shared between accounts by symlink, so a settings file there could not be
# written by every account that uses it, and would dirty the working tree.
mkdir -p "$(dirname "$CONFIG_DST")"
if [ -f "$CONFIG_DST" ]; then
  ok "kept existing config"
else
  cp "$SKILL_DIR/config.example" "$CONFIG_DST"
  ok "created from config.example (all settings commented out)"
fi

echo "==> backend"
# A live backend caches the agent registry it booted with; drop ours so the next
# ds-worker call boots with what we just installed.
"$SKILL_DIR/bin/ds-serve" stop >/dev/null 2>&1 && ok "stopped stale backend" || ok "no backend running"

echo "==> verify"
"$SKILL_DIR/bin/ds-doctor" || true

cat <<'NEXT'

Next:
  ds-serve start                      # warm the shared backend (optional)
  ds-worker explorer "map this repo"  # smoke test
  ds-doctor --config                  # what is in effect, and where it came from
NEXT
