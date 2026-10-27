# The model endpoint (an OpenAI-compatible /v1 base URL): where it is, how to
# authenticate, and which model it is serving.
# Shared by ds-worker (autodetect and the direct role) and ds-doctor.
# Reads files only and never calls opencode, so it keeps working when the
# OpenCode CLI changes underneath us.

# opencode.jsonc allows // and /* */ comments and trailing commas; jq accepts
# neither. Strip them outside string literals, so "http://host/v1" survives.
ds_jsonc_to_json() {   # $1 = path; prints plain JSON
  perl -0777 -pe '
    s{("(?:\\.|[^"\\])*")|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : ""}gse;
    s{("(?:\\.|[^"\\])*")|,(\s*[\]\}])}{defined $1 ? $1 : $2}gse;
  ' "$1"
}

ds_provider_baseurl() {   # $1 = provider name; reads opencode.jsonc, the one home of the URL
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.jsonc"
  [ -f "$cfg" ] || return 1
  ds_jsonc_to_json "$cfg" | jq -r --arg p "$1" '.provider[$p].options.baseURL // empty' 2>/dev/null
}

# curl config lines for the endpoint's API key, read from the environment
# variable DS_MODEL_API_KEY_ENV names. Fed to curl on stdin (-K -) so the key
# never reaches argv. Prints nothing when no key is configured.
ds_model_auth_config() {
  local var="${DS_MODEL_API_KEY_ENV:-}" key
  [ -n "$var" ] || return 0
  case "$var" in *[!A-Za-z0-9_]*|[0-9]*) return 1 ;; esac
  key="${!var:-}"
  [ -n "$key" ] || return 1
  key="${key//\\/\\\\}"; key="${key//\"/\\\"}"
  printf 'header = "Authorization: Bearer %s"\n' "$key"
}

# Which model id to use on an endpoint that serves ONE model — the case
# autodetect exists for. One model means a single entry, or several entries
# that are aliases of the same weights (vLLM's --served-model-name lists each
# alias with the same `root`). Echoes the configured id when it is one of those
# names, else the first. Returns 1 when the endpoint gives no usable list, 2
# when DS_MODEL_API_KEY_ENV names a variable that is unset (nothing is sent),
# and 3 when it serves several distinct models (a hosted API): keep the pin.
ds_detect_served_model() {   # $1 = baseURL ending in /v1, $2 = configured id
  local body auth verdict
  auth="$(ds_model_auth_config)" || return 2
  body="$(printf '%s' "$auth" | curl -sS -m "${DS_MODEL_DETECT_TIMEOUT:-5}" -K - "${1%/}/models" 2>/dev/null)" || return 1
  [ -n "$body" ] || return 1
  verdict="$(jq -r --arg want "${2:-}" '
    .data as $d
    | ($d | map(.root) | unique) as $roots
    | if ($d | length) == 0 then "none"
      elif ($d | length) == 1 or (($roots | length) == 1 and $roots[0] != null)
      then "one " + (if any($d[]; .id == $want) then $want else $d[0].id end)
      else "several" end' <<<"$body" 2>/dev/null)" || return 1
  case "$verdict" in
    "one "*) printf '%s\n' "${verdict#one }" ;;
    several) return 3 ;;
    *)       return 1 ;;
  esac
}
