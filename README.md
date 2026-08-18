# superviser

A skill that keeps Claude/Codex in the **supervisor** seat and hands wide,
repetitive work to a DeepSeek worker running on OpenCode headless.

```
        ┌──────────────────────────┐
        │ Claude / Codex           │
        │ SUPERVISOR               │  decompose · decide · verify
        └────────────┬─────────────┘
                     │ ds-worker (Bash)
        ┌────────────▼─────────────┐
        │ opencode serve :4096     │  resident backend (no cold boot)
        │ (+ OmO Slim, optional)   │
        └────────────┬─────────────┘
                     │ opencode run --attach --agent --model
       ┌─────────────┼─────────────┐
       ▼             ▼             ▼
  ds-explorer   ds-worker    ds-reviewer
   read-only     can write    read-only
   flash         pro          pro
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
ds-worker explorer "Find the auth middleware: entry point and failure paths. file:line required."
ds-worker reviewer --file test.log "Rank the root-cause candidates for this failure."
ds-worker worker "checkToken at src/auth.ts:42 returns 500 for an expired token. Make it 401. Verify: npm test -- auth"
```

```bash
ds-serve start|status|stop    # resident backend (ds-worker starts it on demand)
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
| `DS_MODEL_EXPLORER` | `opencode-go/deepseek-v4-flash` |
| `DS_MODEL_WORKER` | `opencode-go/deepseek-v4-pro` |
| `DS_MODEL_REVIEWER` | `opencode-go/deepseek-v4-pro` |
| `DS_OPENCODE_HOST` / `DS_OPENCODE_PORT` | `127.0.0.1` / `4096` (scans upward if busy) |
| `DS_TIMEOUT` | `900` (seconds) |
| `DS_SERVE` | `auto` (`off` spawns a fresh process per call) |
| `DS_AUTO` | `1` (passes `--auto`) |
| `DS_STATE_DIR` | `~/.local/state/ds-worker` |

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
- Only `ds-worker` can write. Committing, pushing, PRs and dependency changes are
  forbidden in its prompt, and the supervisor does final verification itself.
- A writing role refuses to run when `--dir` is `$HOME` or `/`.
- The backend binds loopback. Any other bind is refused without
  `OPENCODE_SERVER_PASSWORD`.

## After editing an agent definition

```bash
./install.sh      # copies real files + clears the resident backend
```

Symlinked definitions appear in `opencode agent list` but are ignored at run time.
The resident backend restarts itself when the agent-file fingerprint changes.

## Run logs

`~/.local/state/ds-worker/runs/<timestamp>-<role>.ndjson` — the raw event stream
and stderr for every call.
