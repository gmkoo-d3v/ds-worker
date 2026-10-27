# OpenCode v2 CLI adapter, shared by ds-worker, ds-doctor, sync-agents and install.sh.
#
# v2 removed `opencode agent list` (it now prints help and exits 0, so a grep on
# it silently finds nothing), `run --dir`, `run --attach` and `run --variant`.
# Every call into the v2 CLI that differs from v1 goes through this file, so the
# next CLI change has one place to land. tests/test_opencode_v2_contract.sh
# checks these against the real binary.

# Prints one `name (mode)` line per visible agent — the v1 `agent list` shape
# the callers already parse. `opencode debug agents` emits a JSON array and has
# been seen to return `[]` or a truncated document on a cold start, so a reply
# only counts once it parses as a non-empty array. Returns 1 after 3 tries.
oc_agent_list() {
  local tmp attempt
  tmp="$(mktemp "${TMPDIR:-/tmp}/oc-agents.XXXXXX")" || return 1
  for attempt in 1 2 3; do
    if opencode debug agents >"$tmp" 2>/dev/null \
       && jq -e 'type == "array" and length > 0' "$tmp" >/dev/null 2>&1; then
      jq -r '.[] | select(.hidden != true) | "\(.name) (\(.mode))"' "$tmp"
      rm -f "$tmp"
      return 0
    fi
    [ "$attempt" -lt 3 ] && sleep 1
  done
  rm -f "$tmp"
  return 1
}

# v2 folds the reasoning variant into the model reference: provider/model#variant.
# $1 = model (may be empty: an OMO preset picks it), $2 = variant (may be empty).
oc_model_ref() {
  if [ -n "$2" ] && [ -n "$1" ]; then
    printf '%s#%s' "$1" "$2"
  else
    printf '%s' "$1"
  fi
}

# v2 `run` has no --dir: the agent works in the process's cwd. Meant to be the
# command handed to ds_run_with_watchdog, which runs it in a background
# subshell, so the cd and exec never touch the caller.
oc_in_dir() {
  cd "$1" || exit 1
  shift
  exec "$@"
}
