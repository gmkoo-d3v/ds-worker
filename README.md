# worker

A skill that keeps Claude or Codex in the **supervisor** seat and hands wide,
repetitive work to a model you choose — a local model server or any hosted API
OpenCode can reach — running as sandboxed OpenCode agents. The command is
`ds-worker`; *ds* stands for **delegated subagent**.

```
        ┌──────────────────────────┐
        │ Claude / Codex           │
        │ SUPERVISOR               │  decompose · decide · verify
        └────────────┬─────────────┘
                     │ ds-worker (Bash)
        ┌────────────▼─────────────┐
        │ opencode run --standalone│  OpenCode v2: private server per call
        │   (or --server: ds-serve)│  DS_SERVE=auto, password-protected
        │ (+ OmO Slim, optional)   │
        └────────────┬─────────────┘
                     │ --agent --model $DS_MODEL
       ┌─────────────┼─────────────┐
       ▼             ▼             ▼
  ds-explorer   ds-worker    ds-reviewer
   read-only     can write    read-only
                     │
                     ▼
              omo <agent> gateway          ds-worker direct
              OMO Slim preset / Council    one chat completion, no OpenCode
```

The supervisor decomposes the task, decides, and verifies everything that comes
back; the worker reads, searches and edits within a sandbox. Results are claims
until the supervisor checks them — see
[`references/verification.md`](skills/worker/references/verification.md).

## Requirements

- [OpenCode](https://opencode.ai) v2 (`tests/test_opencode_v2_contract.sh`
  checks the CLI shape this toolkit depends on), plus `jq`, `curl`, `perl`, `git`
- A model OpenCode can reach, listed by `opencode models`:
  - **Local**: any OpenAI-compatible server (vLLM, llama.cpp, Ollama,
    LM Studio, …) added as a provider in `~/.config/opencode/opencode.jsonc`
  - **Hosted**: any provider you signed in to with `opencode auth login`

## Install

```bash
./install.sh --model <provider/model>              # e.g. the name `opencode models` prints
./install.sh --model <provider/model> --critic-model <another/model>
```

Run in a terminal without `--model`, it lists your models and asks.

- Four OpenCode personas (`ds-explorer`, `ds-reviewer`, `ds-worker`,
  `doc-critic`) → `~/.config/opencode/agent/`
- `ds-worker` / `ds-serve` / `ds-doctor` / `ds-worker-rr` / `sync-agents` → `~/.local/bin/`
- `/doc-review` command → `~/.config/opencode/command/`
- Skill → `~/.claude/skills/worker` · `~/.codex/skills/worker`
- `DS_MODEL` (and `DS_MODEL_CRITIC`) → `~/.config/ds-worker/config`; the
  installer never edits OpenCode's own configuration

```bash
ds-doctor      # diagnostics: tools, credentials, model, agents, endpoint
```

## Usage

```bash
ds-worker explorer "Find every call site of checkToken in src/ — list all of them, not a sample. file:line required."
ds-worker reviewer --file test.log "Rank the root-cause candidates for this failure, reading the log to its end."
ds-worker worker "checkToken at src/auth.ts:42 returns 500 for an expired token. Make it 401. Verify: npm test -- auth"
ds-worker critic --file docs/plan/foo.md "Audit the supplied document before delivery."
ds-worker direct --file test.log "Rank the root-cause candidates."   # no OpenCode, no tools
ds-worker omo oracle "Review this design for failure modes."         # needs OMO Slim
sync-agents                 # check persona registry drift
sync-agents --install       # install managed persona updates
```

`direct` sends one chat completion straight to the model's OpenAI-compatible
endpoint with the files inlined. It needs only `curl` and `jq`, so it keeps
working when the OpenCode CLI changes; the model has no tools, so hand it
everything it needs. For a hosted API, set `DS_MODEL_API_KEY_ENV` to the name
of the environment variable that holds the key.

```bash
ds-serve start|status|stop    # resident v2 backend; password in ~/.local/state/ds-worker/serve.password (0600)
```

```bash
bash tests/test_opencode_v2_contract.sh                    # CLI shape vs. the installed opencode
DS_CONTRACT_LIVE=1 bash tests/test_opencode_v2_contract.sh # + real round trips to your model
for t in tests/test_*.sh; do bash "$t"; done               # unit tests (stubbed opencode)
```

## Configuration

`~/.config/ds-worker/config` — created by `install.sh` from
[`config.example`](skills/worker/config.example). Precedence is
**environment > config file > built-in default**, so the file sets your normal
preference and an environment variable still overrides a single call.

```bash
ds-doctor --config        # every setting, its value, and where that value came from
```

It lives in your own config directory rather than beside the skill on purpose:
the skill directory is a git checkout that may be linked into several tools or
accounts, so a settings file there could not be written by every user of it,
and every edit would dirty the working tree.

The file is parsed, not sourced — unknown keys are reported with a line number
and ignored, and nothing in it is executed.

| Setting | Default |
|---|---|
| `DS_MODEL` | none — set by `install.sh --model`; every role uses it |
| `DS_MODEL_EXPLORER` / `DS_MODEL_REVIEWER` / `DS_MODEL_WORKER` | `DS_MODEL` |
| `DS_MODEL_EXPLORER_FALLBACK` / `DS_MODEL_REVIEWER_FALLBACK` / `DS_MODEL_WORKER_FALLBACK` | empty |
| `DS_MODEL_CRITIC` | empty (OpenCode's default model; pick one other than `DS_MODEL`) |
| `DS_MODEL_RETRIES` | `2` (attempts per model before moving to the next) |
| `DS_MODEL_ENDPOINT` | empty (the provider's `baseURL` in `opencode.jsonc`) |
| `DS_MODEL_AUTODETECT` | `1` (follow a server that serves one model) |
| `DS_MODEL_API_KEY_ENV` | empty (name of the variable holding an API key, for `direct`) |
| `DS_RR_MODELS` | empty (models `ds-worker-rr` rotates over) |
| `DS_IDLE_TIMEOUT` | `1200` seconds without an NDJSON write (`0` disables) |
| `DS_MAX_RUNTIME` | `3600` seconds |
| `DS_TIMEOUT` | `3600` seconds (legacy alias for `DS_MAX_RUNTIME`) |
| `DS_PROGRESS_INTERVAL` | `15` seconds (`0` disables progress notices) |
| `DS_AUTO_RECOVER_READONLY` | `1` (one recovery for explorer/reviewer) |
| `DS_RECOVERY_IDLE_TIMEOUT` / `DS_RECOVERY_MAX_RUNTIME` | `60` / `180` seconds |
| `DS_OPENCODE_HOST` / `DS_OPENCODE_PORT` | `127.0.0.1` / `4096` (scans upward if busy) |
| `DS_PORT_SCAN` | `20` (ports tried from `DS_OPENCODE_PORT`) |
| `DS_SERVE` | `off` (`auto` runs through the `ds-serve` backend; about 1.7 s less per call, recovery stays `--standalone`) |
| `DS_AUTO` | `1` (passes `--auto`) |
| `DS_STATE_DIR` | `~/.local/state/ds-worker` |

### Choosing models

Any model `opencode models` lists works; the toolkit has no built-in choice.
A small, fast model is usually enough for `explorer` and `reviewer`, whose
claims the supervisor verifies anyway; `worker` writes code, where a
plausible-but-wrong edit is the expensive failure, so it may deserve a stronger
one (`DS_MODEL_WORKER`). `critic` is a cross-model audit: give it a model other
than `DS_MODEL`.

`ds-worker` tries a role's model up to `DS_MODEL_RETRIES` times, then its
fallback up to `DS_MODEL_RETRIES` times, stopping at the first success.
`--model <provider/model>` skips the chain for one call. The JSON result
records the model actually used (`model`, `attempts`, `fallback_used`).

A local server that serves one model at a time makes a pinned name go stale
when you load another. Autodetect asks the endpoint which models it serves and
follows it only when that is one model — a single entry, or aliases of the same
weights (entries sharing one `root`, as vLLM lists `--served-model-name`
aliases) — and only to a model in the provider's catalog. A configured alias
is kept as is; a hosted API listing several models keeps its pin.

- `explorer` reads and searches only.
- `reviewer` diagnoses logs, diffs, and test output without changing files.
- `worker` performs a tightly specified edit and reports its verification.
  Because a timeout can land after a partial edit, `worker`'s chain only
  advances to the next attempt while `--dir` is a git working tree confirmed
  unchanged since the chain started — otherwise it stops immediately and
  hands the partial result back to the supervisor. See "Safety model" below.

The optional `omo` gateway (needs the OMO Slim OpenCode plugin) accepts only
`oracle`, `council`, `librarian`, `designer`, `fixer`, `ds-explorer`, and
`ds-reviewer`. OMO built-ins omit `--model`, so the active
OMO Slim preset selects the model, including configured external seats. The
five built-ins are OpenCode subagents, so each dispatches the primary
`orchestrator` with `task(subagent_type='<agent>')` — `council` asks for every
configured seat and a synthesis, the others request their named subagent once;
the wrapper makes one attempt and leaves seat/model fallback to OMO Slim.

For a slow local reasoning model, set the provider's `chunkTimeout` and absolute
`timeout` in OpenCode's provider configuration. `ds-worker` separately watches
NDJSON output activity and enforces `DS_MAX_RUNTIME`.

## Safety model

- `ds-explorer` and `ds-reviewer` declare `edit: deny`, `bash: deny`.
  `--auto` cannot override `deny` (measured: a bash request returns `NO_BASH`,
  zero tool calls).
- All three roles also set `task: deny` and `skill: deny`, closing the path where
  an agent spawns a subagent to escape its own permission boundary.
  Decomposition belongs to the supervisor.
- **That guarantee only holds while the agent actually applies.** OpenCode has
  several paths where it silently ignores an agent and falls back to the
  unrestricted default: a symlinked definition file, `mode: subagent`, a
  misspelled name, a stale cached backend. So `ds-worker` checks the agent before
  the call and, after it, greps stderr for `Falling back to default agent` and
  **fails hard with exit 3**.
  Details: [references/opencode-cli.md](skills/worker/references/opencode-cli.md), "Traps".
- Every persona starts its permissions with `"*": deny` and allows tools back
  by name. OpenCode v2 begins every agent from `"*": allow`, so without that
  line a tool nobody named is granted — measured: the code-mode `execute` tool,
  and through it `worktree_create`, `session_move` and remote MCP servers. With
  it, `execute` is not offered at all, and reads still work. `execute` did not
  reach shell or edit tools that were denied (they were absent inside it).
- MCP tools sit outside the native permission keys, so an MCP server declared
  in `opencode.jsonc` would otherwise hand every agent its tools — a shell
  included — regardless of `bash: deny`. The wildcard deny covers them; the
  personas allow back a named read-only set (`serena_find_symbol`, …).
- The legacy `ds-worker` role is the only role with the wrapper's documented
  writing contract. The OMO `fixer` gateway is explicitly potentially writable
  and does not inherit the legacy worker's git-safety guard; review its diff
  before accepting any result. Committing, pushing, PRs and dependency changes
  remain supervisor responsibilities.
- A writing role refuses to run when `--dir` is `$HOME` or `/`; `omo fixer` is
  treated as writing for this guard.
- The writing `worker` role's primary/fallback chain never advances past an
  attempt that may have edited files: it snapshots `git status --porcelain`
  in `--dir` before the chain starts and re-checks it after every failed
  attempt, stopping the chain the moment anything differs (or `--dir` is not
  a git working tree at all, since that can't be confirmed either way).
- The backend binds loopback. Any other bind is refused without
  `OPENCODE_SERVER_PASSWORD`.

## Result and timeout contract

`ds-worker --json` emits one structured result after the raw NDJSON stream is
saved under `DS_STATE_DIR`. The `outcome` field distinguishes `CLEAN_RESULT`,
`FINAL_ARTIFACT_MISSING`, `TOOL_ONLY_NO_FINAL_ARTIFACT`, `IDLE_TIMEOUT`,
`MAX_RUNTIME`, and other failures. Exit `124` is always uncertain work: inspect
`raw_log`, `stderr_log`, and the session before continuing. Beyond `ds-worker`'s
own git-guarded primary/fallback chain (see "Safety model"), the supervisor
should never re-invoke a writing role automatically.

JSON results also include `agent` and `dispatch`. An OMO-configured invocation
reports `dispatch: "omo-configured"`, `agent: "orchestrator"` (the subagents are
reached through it via `task(subagent_type=...)`), and `model: null` when the
active OMO Slim preset selected the model; the legacy DS paths continue to
report their model.

The wrapper's idle timer resets on every NDJSON write, including reasoning and
tool events, while `DS_MAX_RUNTIME` is an independent absolute cap. Numeric
progress notices go to stderr at `DS_PROGRESS_INTERVAL` and never include raw
model output.

If an explorer or reviewer has a session but no required final report, the
wrapper makes at most one read-only recovery request in that same session. A
successful recovery sets `recovered: true`; the original result remains visible
through `initial_outcome`, `initial_exit`, and `initial_timeout_reason`. Disable
this behavior with `DS_AUTO_RECOVER_READONLY=0`.

## After editing an agent definition

```bash
./install.sh      # copies real files
```

Symlinked definitions appear in `opencode debug agents` but are ignored at run time.
The resident backend restarts itself when the agent-file fingerprint changes.

## Run logs

`~/.local/state/ds-worker/runs/<timestamp>-<role>.ndjson` — the raw event stream
and matching `.stderr` file for every call. A recovery, when attempted, gets
separate `-recovery.ndjson` and `-recovery.stderr` files.
