#!/usr/bin/env bash
# The persona files are provider-neutral and default-deny:
#   - no `model:` line (the model travels as --model from the config file)
#   - the first permission rule is `"*": deny` — OpenCode v2 starts every agent
#     from `"*": allow`, so a tool nobody named (the code-mode `execute` tool,
#     worktree_create, remote MCP servers) would otherwise be granted
#   - read-only personas never allow edit or bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS="$ROOT/skills/worker/agents"
fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; exit 1; }

frontmatter() { awk 'NR == 1 && /^---$/ { on = 1; next } on && /^---$/ { exit } on' "$1"; }
first_rule() {   # first non-comment line under `permission:`
  frontmatter "$1" | awk '/^permission:/ { p = 1; next } p && /^[[:space:]]*#/ { next } p { print; exit }'
}

for f in "$AGENTS"/*.md; do
  name="$(basename "$f" .md)"
  frontmatter "$f" | grep -q '^model:' && fail "$name" "has a model: line"
  [ "$(first_rule "$f" | tr -d '[:space:]')" = '"*":deny' ] \
    || fail "$name" "first permission rule is '$(first_rule "$f")', expected \"*\": deny"
done
printf 'every persona is model-free and starts with "*": deny: PASS\n'

for name in ds-explorer ds-reviewer doc-critic; do
  frontmatter "$AGENTS/$name.md" | grep -Eq '^[[:space:]]+(edit|bash):[[:space:]]*allow' \
    && fail "$name" "a read-only persona allows edit or bash"
done
printf 'read-only personas allow neither edit nor bash: PASS\n'
