#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ds-worker-install-path.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin"
ln -s "$ROOT/skills/worker/bin/ds-worker" "$TEST_ROOT/bin/ds-worker"

set +e
output="$(PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
  "$TEST_ROOT/bin/ds-worker" --help 2>&1)"
worker_rc=$?
set -e

[ "$worker_rc" -eq 2 ] || {
  printf 'expected installed symlink to reach usage, got exit %s\n' "$worker_rc" >&2
  printf '%s\n' "$output" >&2
  exit 1
}

if printf '%s\n' "$output" | grep -Fq 'process-watchdog.sh: No such file'; then
  printf 'installed symlink resolved watchdog library from the wrong directory\n' >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

printf '%s\n' "$output" | grep -Fq -- '--idle-timeout' || {
  printf 'installed symlink did not render worker usage\n' >&2
  printf '%s\n' "$output" >&2
  exit 1
}

printf 'ds-worker installed symlink path: PASS\n'
