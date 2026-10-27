# The GX10 model endpoint: where it is and which model it is serving.
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

ds_detect_served_model() {   # $1 = baseURL ending in /v1; echoes the loaded model id
  local body
  body="$(curl -sS -m "${DS_MODEL_DETECT_TIMEOUT:-5}" "${1%/}/models" 2>/dev/null)" || return 1
  [ -n "$body" ] || return 1
  jq -er '.data[0].id // empty' <<<"$body" 2>/dev/null
}
