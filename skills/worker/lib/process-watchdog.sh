#!/usr/bin/env bash
# Process watchdog shared by ds-worker.
#
# The child process writes OpenCode's NDJSON stream to a file. Any file write
# is activity, regardless of whether the event contains final answer text,
# reasoning text, or a tool event. The absolute max-runtime remains an
# independent safety cap. Progress reports expose counts only; raw event
# payloads stay in the protected state file and are never printed by the
# watchdog.

ds_file_signature() {
  local path="$1"
  [ -e "$path" ] || { printf '%s' missing; return 0; }
  case "$(uname -s)" in
    Darwin) stat -f '%z:%m' "$path" 2>/dev/null || printf '%s' unreadable ;;
    *)      stat -c '%s:%Y' "$path" 2>/dev/null || printf '%s' unreadable ;;
  esac
}

ds_terminate_child() {
  local pid="$1" i=0
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
}

# Set numeric, non-sensitive metrics from the current NDJSON stream. The
# helper is deliberately tolerant of a partially-written last line and of
# non-JSON warning lines emitted by OpenCode.
ds_update_ndjson_metrics() {
  local output_path="$1" metrics
  DS_WATCHDOG_EVENTS=0
  DS_WATCHDOG_TOOLS=0
  DS_WATCHDOG_TEXT_CHARS=0
  DS_WATCHDOG_FINISHES=0

  [ -s "$output_path" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  metrics="$(
    jq -R 'fromjson? // empty' <"$output_path" 2>/dev/null |
      jq -s -r '
        [
          length,
          (map(select(.type == "tool_use" or .type == "tool")) | length),
          (map(select(.type == "text") | (.part.text // "") | length) | add // 0),
          (map(select(.type == "step_finish")) | length)
        ] | @tsv
      ' 2>/dev/null || true
  )"
  [ -n "$metrics" ] || return 0
  IFS=$'\t' read -r DS_WATCHDOG_EVENTS DS_WATCHDOG_TOOLS \
    DS_WATCHDOG_TEXT_CHARS DS_WATCHDOG_FINISHES <<<"$metrics"
}

ds_report_progress() {
  local output_path="$1" elapsed_seconds="$2"
  ds_update_ndjson_metrics "$output_path"
  printf 'ds-worker: progress elapsed=%ss events=%s tools=%s text_chars=%s step_finishes=%s\n' \
    "$elapsed_seconds" "$DS_WATCHDOG_EVENTS" "$DS_WATCHDOG_TOOLS" \
    "$DS_WATCHDOG_TEXT_CHARS" "$DS_WATCHDOG_FINISHES" >&2
}

# Usage: ds_run_with_watchdog <idle-seconds> <max-seconds> <stdout-file>
#        <stderr-file> [progress-interval] <command> [args...]
#
# The optional progress interval is backward-compatible: when the fifth
# argument is not an integer it is treated as the command, as in the original
# four-argument form.
#
# Return 124 for either watchdog limit, matching the legacy ds-worker contract.
# DS_WATCHDOG_REASON is set to idle or max-runtime for the caller's diagnostics.
ds_run_with_watchdog() {
  local idle_seconds="$1" max_seconds="$2" output_path="$3" error_path="$4"
  local progress_interval=0
  case "${5:-}" in
    ''|*[!0-9]*) ;;
    *) progress_interval="$5"; shift ;;
  esac
  shift 4

  "$@" >"$output_path" 2>"$error_path" &
  local pid=$!
  local started_at="$(date +%s)"
  local last_activity="$started_at"
  local last_progress_report="$started_at"
  local previous_signature="$(ds_file_signature "$output_path")"
  local current_signature now rc=0
  DS_WATCHDOG_REASON=completed
  DS_WATCHDOG_EVENTS=0
  DS_WATCHDOG_TOOLS=0
  DS_WATCHDOG_TEXT_CHARS=0
  DS_WATCHDOG_FINISHES=0

  while kill -0 "$pid" 2>/dev/null; do
    current_signature="$(ds_file_signature "$output_path")"
    if [ "$current_signature" != "$previous_signature" ]; then
      previous_signature="$current_signature"
      last_activity="$(date +%s)"
    fi

    now="$(date +%s)"
    if [ "$progress_interval" -gt 0 ] && \
       [ $((now - last_progress_report)) -ge "$progress_interval" ]; then
      ds_report_progress "$output_path" "$((now - started_at))"
      last_progress_report="$now"
    fi
    if [ "$max_seconds" -gt 0 ] && [ $((now - started_at)) -ge "$max_seconds" ]; then
      DS_WATCHDOG_REASON=max-runtime
      ds_terminate_child "$pid"
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    if [ "$idle_seconds" -gt 0 ] && [ $((now - last_activity)) -ge "$idle_seconds" ]; then
      DS_WATCHDOG_REASON=idle
      ds_terminate_child "$pid"
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.2
  done

  wait "$pid" || rc=$?
  ds_update_ndjson_metrics "$output_path"
  return "$rc"
}
