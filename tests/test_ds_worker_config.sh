#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR="$ROOT/skills/worker/bin/ds-doctor"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ds-worker-config.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

CONFIG_DIR="$TEST_ROOT/config/ds-worker"
CONFIG="$CONFIG_DIR/config"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG" <<'EOF'
# Parsed, never sourced.
DS_TIMEOUT=111 # legacy
DS_IDLE_TIMEOUT = "22"
DS_MAX_RUNTIME=333
DS_SERVE=off
DS_STATE_DIR='~/state' # expands only for *DIR keys
DS_PROGRESS_INTERVAL=44
DS_AUTO_RECOVER_READONLY=0
DS_RECOVERY_IDLE_TIMEOUT=55
DS_RECOVERY_MAX_RUNTIME=66
DS_UNTRUSTED=$(touch SHOULD_NOT_RUN)
EOF

output="$(env -i HOME="$TEST_ROOT/home" PATH="/opt/homebrew/bin:/usr/bin:/bin" \
  XDG_CONFIG_HOME="$TEST_ROOT/config" DS_CONFIG="$CONFIG" \
  DS_TIMEOUT=777 DS_MAX_RUNTIME=888 DS_PROGRESS_INTERVAL=99 \
  "$DOCTOR" --config)"

printf '%s\n' "$output" | grep -Eq '^  DS_TIMEOUT[[:space:]]+777[[:space:]]+environment$' || {
  printf 'environment DS_TIMEOUT did not win\n%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -Eq '^  DS_IDLE_TIMEOUT[[:space:]]+22[[:space:]]+config file$' || {
  printf 'quoted config value was not parsed\n%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -Eq '^  DS_MAX_RUNTIME[[:space:]]+888[[:space:]]+environment$' || {
  printf 'environment DS_MAX_RUNTIME did not win\n%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -Eq '^  DS_PROGRESS_INTERVAL[[:space:]]+99[[:space:]]+environment$' || {
  printf 'environment progress interval did not win\n%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -Eq '^  DS_AUTO_RECOVER_READONLY[[:space:]]+0[[:space:]]+config file$' || {
  printf 'read-only recovery config was not reported\n%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -Fq "DS_STATE_DIR        $TEST_ROOT/home/state" || {
  printf 'tilde path was not expanded\n%s\n' "$output" >&2
  exit 1
}
[ ! -e "$TEST_ROOT/config/ds-worker/SHOULD_NOT_RUN" ] || {
  printf 'config file was executed\n' >&2
  exit 1
}

legacy_config="$TEST_ROOT/legacy-config"
printf '%s\n' 'DS_TIMEOUT=123' > "$legacy_config"
legacy_output="$(env -i HOME="$TEST_ROOT/home" PATH="/opt/homebrew/bin:/usr/bin:/bin" \
  DS_CONFIG="$legacy_config" "$DOCTOR" --config)"
printf '%s\n' "$legacy_output" | grep -Eq '^  DS_MAX_RUNTIME[[:space:]]+123[[:space:]]+config file \(DS_TIMEOUT\)$' || {
  printf 'legacy DS_TIMEOUT did not provide DS_MAX_RUNTIME\n%s\n' "$legacy_output" >&2
  exit 1
}

printf 'ds-worker config precedence: PASS\n'
