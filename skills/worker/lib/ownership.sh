#!/usr/bin/env bash
# Ownership module shared by install.sh and sync-agents.
#
# The tool may only overwrite a file it can prove it installed: the ledger
# keeps one line per installed file, "<sha256-of-repo-file> TAB <abs-target>",
# at ${DS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ds-worker}/
# installed.sha256. Anything else on disk belongs to somebody else and is
# reported as a conflict instead of being merged or overwritten.
#
# Functions (all print to stdout, return 0 unless noted):
#   own_ledger_path                 absolute ledger path
#   own_classify <repo> <tgt> <led> -> absent|identical|managed-updatable|conflict
#   own_record <repo> <tgt> <led>   ledger entry AFTER a successful write
#   own_backup <path>               timestamped copy, prints the backup path
#
# Classification rules:
#   absent              nothing at the target path (a dangling symlink is NOT
#                       absent — it occupies the path but has no readable
#                       content, so it lands in conflict)
#   identical           target content already equals the repo file
#   managed-updatable   target still matches the hash recorded at install
#                       time, so overwriting it only delivers the repo update
#   conflict            exists, differs from the repo file, and is not
#                       recorded (or no longer matches its record)

own_ledger_path() {
  local base="${DS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ds-worker}"
  printf '%s/installed.sha256\n' "${base%/}"
}

own_abspath() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

own_hash() {
  local path="$1"
  [ -r "$path" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$path" | cut -d' ' -f1
  else
    shasum -a 256 -- "$path" | cut -d' ' -f1
  fi
}

own_classify() {
  local repo="$1" target="$2" ledger="$3" abs
  abs="$(own_abspath "$target")"
  if [ -L "$target" ] && [ ! -e "$target" ]; then
    printf 'conflict\n'; return 0        # dangling symlink occupies the path
  fi
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    printf 'absent\n'; return 0
  fi
  if [ -f "$target" ] && cmp -s -- "$repo" "$target"; then
    printf 'identical\n'; return 0
  fi
  local rec cur
  rec="$(awk -F'\t' -v p="$abs" '$2 == p { print $1; exit }' "$ledger" 2>/dev/null || true)"
  cur="$(own_hash "$target" 2>/dev/null || true)"
  if [ -n "$rec" ] && [ -n "$cur" ] && [ "$rec" = "$cur" ]; then
    printf 'managed-updatable\n'; return 0
  fi
  printf 'conflict\n'
}

# Record the repo hash for the target path AFTER the write succeeded. The
# rewrite is atomic (temp file in the ledger dir, then mv) so an interrupted
# run can never leave a half-written ledger.
own_record() {
  local repo="$1" target="$2" ledger="$3" abs h dir tmp
  abs="$(own_abspath "$target")"
  h="$(own_hash "$repo")" || return 1
  dir="$(dirname "$ledger")"
  mkdir -p -- "$dir"
  tmp="$(mktemp -- "$dir/installed.sha256.XXXXXX")"
  if [ -f "$ledger" ]; then
    awk -F'\t' -v p="$abs" '$2 != p' "$ledger" >"$tmp"
  fi
  printf '%s\t%s\n' "$h" "$abs" >>"$tmp"
  mv -- "$tmp" "$ledger"
}

own_backup() {
  local path="$1" backup
  backup="$path.bak.$(date +%Y%m%d-%H%M%S)"
  cp -p -- "$path" "$backup" || return 1
  printf '%s\n' "$backup"
}
