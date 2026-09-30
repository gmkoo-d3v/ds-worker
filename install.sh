#!/usr/bin/env bash
# Repository entry point for the portable worker installer.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$ROOT/skills/worker/install.sh" "$@"
for arg in "$@"; do [ "$arg" = --verify ] && exit 0; done
for skill_parent in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
  mkdir -p "$skill_parent"
  skill_target="$skill_parent/worker"
  if [ -e "$skill_target" ] && [ ! -L "$skill_target" ]; then
    printf 'install.sh: preserving existing skill directory: %s\n' "$skill_target" >&2
    continue
  fi
  ln -sfn "$ROOT/skills/worker" "$skill_target"
  printf 'skill link: %s\n' "$skill_target"
done
