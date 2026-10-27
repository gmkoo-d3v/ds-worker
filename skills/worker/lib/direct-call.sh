# ds-worker direct — one chat completion against the model endpoint, no OpenCode.
#
#   ds-worker direct [--model <prov/mdl>] [--file <path>]... [--max-runtime <s>]
#                    [--json] [--quiet] "<prompt>"
#
# Text in, text out: the model gets the prompt and the attached files inline and
# has no tools, no permissions and no session. Use it for work that only needs
# judgment over supplied material (a log, a diff, a document). Anything that
# has to search or edit the repository still needs the OpenCode roles.
# Any OpenAI-compatible endpoint works: DS_MODEL_ENDPOINT, else the provider's
# baseURL in opencode.jsonc; an API key comes from the environment variable
# that DS_MODEL_API_KEY_ENV names.
#
# Sourced by ds-worker after its config and defaults are loaded; needs die,
# note and lib/model-endpoint.sh. It never calls opencode, so it keeps working
# when the OpenCode CLI changes.

DS_DIRECT_SYSTEM="You are a read-only analyst working for a supervisor. You have no tools: you cannot open files, run commands or browse. Everything you may rely on is in the user message, including any attached files. Quote file paths and lines exactly as given. If the material does not establish something, say so explicitly instead of guessing."

ds_direct_usage() {
  sed -n '2,13p' "$SELF_DIR/../lib/direct-call.sh" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

ds_direct_attachments() {   # $@ = file paths; prints them as labelled fenced blocks
  local f
  for f in "$@"; do
    printf '\n\n--- attached file: %s ---\n```\n' "$f"
    cat "$f"
    printf '\n```'
  done
}

ds_direct_main() {
  local model="$DS_MODEL_REVIEWER" explicit=0 out_mode=text quiet=0 prompt=""
  local max_runtime="$DS_MAX_RUNTIME" files=() f
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)       model="${2:?--model needs a value}"; explicit=1; shift 2 ;;
      --file)        files+=("${2:?--file needs a value}"); shift 2 ;;
      --max-runtime|--timeout) max_runtime="${2:?$1 needs a value}"; shift 2 ;;
      --json)        out_mode=json; shift ;;
      --quiet)       quiet=1; shift ;;
      -h|--help)     ds_direct_usage ;;
      --)            shift; prompt="$*"; break ;;
      -)             prompt="$(cat)"; shift ;;
      --dir|--variant|--session|--continue|--raw|--no-serve|--idle-timeout|--progress-interval|--recover-readonly|--no-recover-readonly)
                     die "direct: $1 does not apply — direct mode has no tools, no session and no OpenCode process" ;;
      -*)            die "direct: unknown option '$1'" ;;
      *)             prompt="${prompt:+$prompt }$1"; shift ;;
    esac
  done
  [ -n "$prompt" ] || die "no prompt given"
  [ -n "$model" ] || die "direct: no model configured: set DS_MODEL=<provider/model> in $DS_CONFIG, or pass --model"
  command -v curl >/dev/null || die "curl not found on PATH"
  command -v jq >/dev/null || die "jq not found on PATH"
  case "$max_runtime" in ''|*[!0-9]*|0) die "--max-runtime must be a positive integer (seconds)" ;; esac
  case "$model" in */*) ;; *) die "direct: model '$model' must be provider/model" ;; esac
  for f in "${files[@]:-}"; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || die "direct: --file $f does not exist"
    # An empty file passes; anything with a NUL byte is not text for a prompt.
    if [ -s "$f" ] && ! LC_ALL=C grep -Iq . "$f"; then
      die "direct: --file $f looks binary"
    fi
  done

  local provider="${model%%/*}" model_id="${model#*/}" endpoint detected
  endpoint="${DS_MODEL_ENDPOINT:-$(ds_provider_baseurl "$provider" || true)}"
  [ -n "$endpoint" ] \
    || die "direct: no endpoint — set DS_MODEL_ENDPOINT or a baseURL for provider '$provider' in opencode.jsonc"
  # Same rule as the OpenCode roles: --model is a deliberate pin, otherwise
  # follow a server that serves one model. No catalog check — no OpenCode here.
  if [ "$explicit" -eq 0 ] && [ "$DS_MODEL_AUTODETECT" = "1" ]; then
    if detected="$(ds_detect_served_model "$endpoint" "$model_id")" && [ -n "$detected" ] \
       && [ "$detected" != "$model_id" ]; then
      note "autodetect: $model is not loaded; $endpoint serves $detected — using $provider/$detected"
      model_id="$detected"; model="$provider/$detected"
    fi
  fi

  mkdir -p "$DS_STATE_DIR/runs"
  local stamp request raw user_msg http auth rc=0
  auth="$(ds_model_auth_config)" \
    || die "direct: DS_MODEL_API_KEY_ENV names '${DS_MODEL_API_KEY_ENV}', but that variable is unset or not a valid name"
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  request="$DS_STATE_DIR/runs/${stamp}-direct.request.json"
  raw="$DS_STATE_DIR/runs/${stamp}-direct.json"
  user_msg="[supervisor task | role=direct | no tools]

${prompt}"
  [ "${#files[@]}" -gt 0 ] && user_msg="$user_msg$(ds_direct_attachments "${files[@]}")"
  jq -n --arg model "$model_id" --arg system "$DS_DIRECT_SYSTEM" --arg user "$user_msg" '
    {model: $model, stream: false,
     messages: [{role: "system", content: $system}, {role: "user", content: $user}]}' >"$request"

  [ "$quiet" -eq 1 ] || note "direct model=$model endpoint=$endpoint raw_log=$raw"
  http="$(printf '%s' "$auth" | curl -sS -m "$max_runtime" -o "$raw" -w '%{http_code}' -K - \
    -H 'Content-Type: application/json' --data-binary @"$request" \
    "${endpoint%/}/chat/completions" 2>"$raw.stderr")" || rc=$?
  [ -f "$raw" ] || : >"$raw"

  local result wrapper_exit
  result="$(jq -R -s --arg model "$model" --arg endpoint "$endpoint" --arg dir "$PWD" \
    --arg raw "$raw" --arg request "$request" --arg http "${http:-000}" \
    --argjson rc "$rc" --argjson max_runtime "$max_runtime" \
    --arg curl_err "$(head -c 500 "$raw.stderr" 2>/dev/null)" '
    (fromjson? // null) as $body
    | ($body.choices[0].message.content // "" | sub("^\\s+"; "") | sub("\\s+$"; "")) as $text
    | {
        role: "direct", agent: null, dispatch: "direct",
        model: $model, endpoint: $endpoint, dir: $dir,
        exit: $rc, http_status: ($http | tonumber? // 0),
        text: $text,
        finish_reason: ($body.choices[0].finish_reason // null),
        tokens: ($body.usage // null),
        error: (if $rc != 0 then $curl_err
                elif ($http | startswith("2")) | not then (($body.error.message // $body.detail // .) | tostring | .[0:500])
                else null end),
        max_runtime: $max_runtime,
        raw_log: $raw, request_log: $request, tools: [], tool_count: 0
      }
    | .outcome = (if .exit == 28 then "MAX_RUNTIME"
                  elif .exit != 0 or (.http_status < 200 or .http_status >= 300) then "FAILED"
                  elif .text == "" then "FINAL_ARTIFACT_MISSING"
                  else "CLEAN_RESULT" end)
    | .status = ({"CLEAN_RESULT": "completed", "FINAL_ARTIFACT_MISSING": "completed_missing_final_artifact",
                  "MAX_RUNTIME": "timed_out_unknown"}[.outcome] // "failed")
    | .wrapper_exit = ({"CLEAN_RESULT": 0, "FINAL_ARTIFACT_MISSING": 4, "MAX_RUNTIME": 124}[.outcome] // 1)
    ' <"$raw")"
  rm -f "$raw.stderr"
  wrapper_exit="$(jq -r '.wrapper_exit' <<<"$result")"

  if [ "$out_mode" = json ]; then
    printf '%s\n' "$result"
  elif [ "$wrapper_exit" -eq 0 ]; then
    jq -r '.text' <<<"$result"
  else
    note "no text output: $(jq -r '.error // .finish_reason // "empty reply"' <<<"$result")"
  fi
  if [ "$quiet" -eq 0 ]; then
    jq -r '"--\nrole=direct model=\(.model) status=\(.status) outcome=\(.outcome) " +
      "http=\(.http_status) tokens=\(.tokens.total_tokens // "-") wrapper_exit=\(.wrapper_exit) raw_log=\(.raw_log)"' \
      <<<"$result" >&2
  fi
  exit "$wrapper_exit"
}
