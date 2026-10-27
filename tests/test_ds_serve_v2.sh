#!/usr/bin/env bash
# ds-serve against an OpenCode v2 server: password-protected, probed through
# an authenticated GET /api/info whose pid must be the process we started.
# A stub `opencode serve` records its argv and environment and idles; a stub
# curl checks the credential it gets on stdin (-K -) and reports a pid.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DS_SERVE="$ROOT/skills/worker/bin/ds-serve"
TEST_ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ds-serve-v2.XXXXXX")" && pwd)"
FAKE_BIN="$TEST_ROOT/bin"
STATE_DIR="$TEST_ROOT/state"

cleanup() {
  local pid
  for f in "$TEST_ROOT"/serve.*.pid; do
    [ -f "$f" ] && read -r pid <"$f" && kill "$pid" 2>/dev/null || true
  done
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
mkdir -p "$FAKE_BIN" "$STATE_DIR"

fail() { printf '%s: FAIL — %s\n' "$1" "$2" >&2; exit 1; }

cat > "$FAKE_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = serve ] || exit 0
n="$(find "$DS_TEST_ROOT" -name 'serve.*.pid' | wc -l | tr -d ' ')"
printf '%s\n' "$$" >"$DS_TEST_ROOT/serve.$n.pid"
printf '%s\n' "$@" >"$DS_TEST_ROOT/serve.$n.argv"
printf '%s\n' "${OPENCODE_SERVER_PASSWORD:-}" >"$DS_TEST_ROOT/serve.$n.env"
exec sleep 60
EOF
# Answers /api/info for the pid in serve.state when the -K credential matches
# the server's password; DS_TEST_REPORT_PID impersonates a different process.
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
cfg="$(cat)"
url="${*: -1}"
case "$url" in */api/info) ;; *) exit 22 ;; esac
read -r pid _ <"$DS_STATE_DIR/serve.state" || exit 7
n="$(find "$DS_TEST_ROOT" -name 'serve.*.pid' | wc -l | tr -d ' ')"
want="$(cat "$DS_TEST_ROOT/serve.$((n - 1)).env")"
# Unescape the quoted config value the way curl does (\" and \\).
got="$(printf '%s\n' "$cfg" | perl -ne 'print $1 =~ s/\\(.)/$1/gr if /^user = "(.*)"$/')"
[ "$got" = "opencode:$want" ] || exit 22
printf '{"version":"2.1.4","pid":%s}\n' "${DS_TEST_REPORT_PID:-$pid}"
EOF
chmod +x "$FAKE_BIN/opencode" "$FAKE_BIN/curl"

export PATH="$FAKE_BIN:$PATH" DS_STATE_DIR="$STATE_DIR" DS_TEST_ROOT="$TEST_ROOT" DS_CONFIG=/dev/null
export DS_OPENCODE_PORT=4796 DS_PORT_SCAN=5
unset OPENCODE_SERVER_PASSWORD
starts() { find "$TEST_ROOT" -name 'serve.*.pid' | wc -l | tr -d ' '; }

# ---- first start: generated 0600 password, handed over by env only ----------------
URL="$("$DS_SERVE" start 2>/dev/null)" || fail "start" "ds-serve start failed"
case "$URL" in http://127.0.0.1:47*) ;; *) fail "start" "unexpected url '$URL'" ;; esac
PW_FILE="$STATE_DIR/serve.password"
[ -f "$PW_FILE" ] || fail "password" "no $PW_FILE"
[ "$(stat -f %Lp "$PW_FILE" 2>/dev/null || stat -c %a "$PW_FILE")" = 600 ] || fail "password" "mode is not 600"
PW="$(cat "$PW_FILE")"
printf '%s' "$PW" | grep -Eqx '[0-9a-f]{48}' || fail "password" "not 48 hex chars"
[ "$(cat "$TEST_ROOT/serve.0.env")" = "$PW" ] || fail "password" "server did not get OPENCODE_SERVER_PASSWORD"
grep -qF "$PW" "$TEST_ROOT/serve.0.argv" && fail "password" "password appeared in the serve argv"
"$DS_SERVE" status >/dev/null 2>&1 || fail "status" "status should report up"
printf 'ds-serve start generates a 0600 password and passes it by env only: PASS\n'

# ---- reuse: the probe confirms the same pid ------------------------------------------
[ "$("$DS_SERVE" start 2>/dev/null)" = "$URL" ] && [ "$(starts)" = 1 ] \
  || fail "reuse" "second start did not reuse the running backend ($(starts) starts)"
[ "$("$DS_SERVE" url 2>/dev/null)" = "$URL" ] || fail "url" "url did not report the backend"
printf 'ds-serve reuses its own backend: PASS\n'

# ---- a server reporting another pid is not ours ---------------------------------------
DS_TEST_REPORT_PID=1 "$DS_SERVE" status >/dev/null 2>&1 && fail "foreign" "a pid mismatch must not count as ours"
printf 'ds-serve rejects a backend that reports a different pid: PASS\n'

# ---- a wrong password is not ours either; restart keeps the file ---------------------
printf 'wrong\n' >"$TEST_ROOT/serve.0.env"
"$DS_SERVE" status >/dev/null 2>&1 && fail "auth" "a backend that rejects our password must not count as ours"
"$DS_SERVE" start >/dev/null 2>&1 || fail "restart" "start after auth failure failed"
[ "$(starts)" = 2 ] || fail "restart" "expected a fresh backend, got $(starts) starts"
[ "$(cat "$PW_FILE")" = "$PW" ] || fail "restart" "restart must keep the password file"
printf 'ds-serve restarts a backend that rejects its password: PASS\n'

# ---- OPENCODE_SERVER_PASSWORD from the caller wins over the file ----------------------
"$DS_SERVE" stop >/dev/null 2>&1
"$DS_SERVE" status >/dev/null 2>&1 && fail "stop" "status should report down after stop"
OPENCODE_SERVER_PASSWORD='caller "pw"\x' "$DS_SERVE" start >/dev/null 2>&1 || fail "env pw" "start with caller password failed"
[ "$(cat "$TEST_ROOT/serve.2.env")" = 'caller "pw"\x' ] || fail "env pw" "server did not get the caller's password"
OPENCODE_SERVER_PASSWORD='caller "pw"\x' "$DS_SERVE" status >/dev/null 2>&1 \
  || fail "env pw" "a quoted caller password must still authenticate the probe"
"$DS_SERVE" stop >/dev/null 2>&1
printf 'ds-serve uses OPENCODE_SERVER_PASSWORD when the caller sets it: PASS\n'
