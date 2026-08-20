#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DS_SERVE="$ROOT/skills/worker/bin/ds-serve"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ds-serve-lock.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"
STATE_DIR="$TEST_ROOT/state"
COUNT_FILE="$TEST_ROOT/opencode.count"

cleanup() {
  if [ -f "$STATE_DIR/serve.state" ]; then
    read -r pid _ < "$STATE_DIR/serve.state" || true
    kill "$pid" 2>/dev/null || true
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$STATE_DIR"

cat > "$FAKE_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "serve" ]; then
  count_file="${DS_TEST_COUNT_FILE:?}"
  while ! mkdir "${count_file}.lock" 2>/dev/null; do sleep 0.01; done
  count=0
  [ -f "$count_file" ] && count="$(<"$count_file")"
  printf '%s\n' "$((count + 1))" > "$count_file"
  rmdir "${count_file}.lock"
  sleep 5
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN/opencode"

cat > "$FAKE_BIN/rm" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *serve.state*)
    touch "$DS_TEST_ROOT/rm.$PPID"
    for _ in $(seq 1 50); do
      [ "$(find "$DS_TEST_ROOT" -name 'rm.*' -type f | wc -l | tr -d ' ')" -ge 2 ] && break
      sleep 0.01
    done
    ;;
esac
/bin/rm "$@"
EOF
chmod +x "$FAKE_BIN/rm"

cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN/curl"

export PATH="$FAKE_BIN:$PATH"
export DS_STATE_DIR="$STATE_DIR"
export DS_OPENCODE_PORT=4596
export DS_PORT_SCAN=2
export DS_TEST_COUNT_FILE="$COUNT_FILE"
export DS_TEST_ROOT="$TEST_ROOT"

# Force both callers through the stale-state cold-start path.
printf '999999 http://127.0.0.1:4596 stale\n' > "$STATE_DIR/serve.state"
mkdir "$STATE_DIR/serve.lock"
printf '999999\n' > "$STATE_DIR/serve.lock/pid"

"$DS_SERVE" start >/dev/null &
first=$!
"$DS_SERVE" start >/dev/null &
second=$!
wait "$first"
wait "$second"

actual="$(<"$COUNT_FILE")"
[ "$actual" = "1" ] || {
  printf 'expected one backend start, got %s\n' "$actual" >&2
  exit 1
}

printf 'ds-serve concurrent start lock: PASS\n'
