# superviser

A skill that keeps Claude/Codex in the **supervisor** seat and hands wide,
repetitive work to a local GX10 worker (DeepSeek, falling back to Qwen)
running on OpenCode headless.

```
        ┌──────────────────────────┐
        │ Claude / Codex           │
        │ SUPERVISOR               │  decompose · decide · verify
        └────────────┬─────────────┘
                     │ ds-worker (Bash)
        ┌────────────▼─────────────┐
        │ opencode run (one-shot) │  no shared control port
        │ (+ OmO Slim, optional)  │
        └────────────┬────────────┘
                     │ --agent [--model]
       ┌─────────────┼─────────────┐
       ▼             ▼             ▼
  ds-explorer   ds-worker    ds-reviewer
   read-only     can write    read-only
   DeepSeek→Qwen DeepSeek→Qwen DeepSeek→Qwen
                     │
                     ▼
              omo <agent> gateway
              OMO Slim preset / Council
```

## Install

```bash
./install.sh
```

- Three OpenCode agents → `~/.config/opencode/agent/`
- `ds-worker` / `ds-serve` / `ds-doctor` → `~/.local/bin/`
- Skill → `~/.claude/skills/worker` · `~/.codex/skills/worker`

Requires `opencode`, `jq`, `curl`, and a completed `opencode auth login`.

```bash
ds-doctor      # diagnostics
```

## Usage

```bash
ds-worker explorer "Find every call site of checkToken in src/ — list all of them, not a sample. file:line required."
ds-worker reviewer --file test.log "Rank the root-cause candidates for this failure, reading the log to its end."
ds-worker worker "checkToken at src/auth.ts:42 returns 500 for an expired token. Make it 401. Verify: npm test -- auth"
ds-worker omo oracle "Review this design for failure modes."
ds-worker omo council "Debate whether to split the auth service."
ds-worker omo ds-explorer "Find every call site of checkToken in src/."
ds-worker omo ds-reviewer --file test.log "Rank the root-cause candidates."
```

```bash
ds-serve start|status|stop    # optional manual resident backend for TUI observation
```

## Configuration

`~/.config/ds-worker/config` — created by `install.sh` from
[`config.example`](skills/worker/config.example) with everything commented out.
Precedence is **environment > config file > built-in default**, so the file sets
your normal preference and an environment variable still overrides a single call.

```bash
ds-doctor --config        # every setting, its value, and where that value came from
```

It lives in your own config directory rather than beside the skill on purpose:
the skill directory is a git repo shared between accounts by symlink, so a
settings file there could not be written by every account that uses it, and every
edit would dirty the working tree.

The file is parsed, not sourced — unknown keys are reported with a line number
and ignored, and nothing in it is executed.

| Setting | Default |
|---|---|
| `DS_MODEL_EXPLORER` / `DS_MODEL_REVIEWER` / `DS_MODEL_WORKER` | `gx10-8000/deepseek-v4-flash-exl3-cross` (primary) |
| `DS_MODEL_EXPLORER_FALLBACK` / `DS_MODEL_REVIEWER_FALLBACK` / `DS_MODEL_WORKER_FALLBACK` | `gx10-8888/qwen3.8-27b` (fallback) |
| `DS_MODEL_RETRIES` | `2` (attempts per model before moving to the next) |
| `DS_IDLE_TIMEOUT` | `1200` seconds without an NDJSON write (`0` disables) |
| `DS_MAX_RUNTIME` | `3600` seconds |
| `DS_TIMEOUT` | `3600` seconds (legacy alias for `DS_MAX_RUNTIME`) |
| `DS_PROGRESS_INTERVAL` | `15` seconds (`0` disables progress notices) |
| `DS_AUTO_RECOVER_READONLY` | `1` (one recovery for explorer/reviewer) |
| `DS_RECOVERY_IDLE_TIMEOUT` / `DS_RECOVERY_MAX_RUNTIME` | `60` / `180` seconds |
| `DS_OPENCODE_HOST` / `DS_OPENCODE_PORT` | `127.0.0.1` / `4096` (scans upward if busy) |
| `DS_PORT_SCAN` | `20` (ports tried from `DS_OPENCODE_PORT`) |
| `DS_SERVE` | `off` (`auto` opts into a shared backend) |
| `DS_AUTO` | `1` (passes `--auto`) |
| `DS_STATE_DIR` | `~/.local/state/ds-worker` |

### Choosing a model per role

Each role has a primary and a fallback model, both local GX10 boxes by
default: DeepSeek (`:8000`) first, then Qwen (`:8888`) if DeepSeek fails.
`ds-worker` tries the primary up to `DS_MODEL_RETRIES` times, then the
fallback up to `DS_MODEL_RETRIES` times, stopping at the first success. You
can override either model per role independently in the config file, or skip
the whole chain for a single call with `--model <provider/model>` (runs
exactly that model once); the wrapper always records the model actually used
in its JSON result (`model`, `attempts`, `fallback_used`) and footer.

- `explorer` reads and searches only.
- `reviewer` diagnoses logs, diffs, and test output without changing files.
- `worker` performs a tightly specified edit and reports its verification.
  Because a timeout can land after a partial edit, `worker`'s chain only
  advances to the next attempt while `--dir` is a git working tree confirmed
  unchanged since the chain started — otherwise it stops immediately and
  hands the partial result back to the supervisor. See "Safety model" below.

The `omo` gateway accepts only `oracle`, `council`, `librarian`, `designer`,
`fixer`, `ds-explorer`, and `ds-reviewer`. OMO built-ins omit `--model`, so the
active `~/.config/opencode/oh-my-opencode-slim.json` preset selects the model,
including configured external seats. The five built-ins (`oracle`, `council`,
`librarian`, `designer`, `fixer`) are OpenCode subagents, so each dispatches the
primary `orchestrator` with `task(subagent_type='<agent>')` — `council` asks for
every configured seat and a synthesis, the others request their named subagent
once; the wrapper makes one attempt and leaves seat/model fallback to OMO Slim.
`ds-explorer` and `ds-reviewer` use the existing local model configuration and
report contracts.

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
- MCP tools bypass the native permission keys entirely, so each agent
  default-denies the MCP namespace (`"serena_*": deny`) and allows back a named
  read-only set. Without this, an MCP server declared in `opencode.jsonc` hands
  every agent a full shell regardless of `bash: deny`.
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

Symlinked definitions appear in `opencode agent list` but are ignored at run time.
The resident backend restarts itself when the agent-file fingerprint changes.

## Run logs

`~/.local/state/ds-worker/runs/<timestamp>-<role>.ndjson` — the raw event stream
and matching `.stderr` file for every call. A recovery, when attempted, gets
separate `-recovery.ndjson` and `-recovery.stderr` files.
