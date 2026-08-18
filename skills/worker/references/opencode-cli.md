# OpenCode CLI — verified facts

Against `opencode 1.18.18`. Everything below was **run locally and observed**,
not taken from documentation alone.
Official docs: <https://opencode.ai/docs/cli/>, <https://opencode.ai/docs/agents/>

## Headless execution

```bash
opencode run "investigate this"
```

Actual flags, from `opencode run --help`:

| Flag | Meaning |
|---|---|
| `-m, --model <provider/model>` | Model |
| `--agent <name>` | Agent |
| `--dir <path>` | Working directory (path on the remote server when attaching) |
| `--format default\|json` | `json` emits a **raw JSON event stream** |
| `--attach <url>` | Attach to an already running server |
| `-s, --session <id>` / `-c, --continue` / `--fork` | Session continuation |
| `-f, --file <path>` | Attach files (array) |
| `--variant <name>` | Provider reasoning effort (`high`, `max`, `minimal`) |
| `--auto` | Auto-approve permissions that are not explicitly denied |
| `--pure` | Run without external plugins |
| `-p/--password`, `-u/--username` | Server basic auth |
| `--title`, `--share`, `--thinking`, `--print-logs`, `--log-level` | Misc |

## Long-lived backend

Spawning a fresh process per call pays MCP/plugin cold boot every time. The
official docs recommend a resident server for exactly this reason.

```bash
opencode serve --hostname 127.0.0.1 --port 4096
```

`serve` flags: `--port`, `--hostname`, `--mdns`, `--mdns-domain`, `--cors`.

- **Health check**: `GET http://127.0.0.1:4096/config` → `200`, `application/json`
  (`/app` also returns 200 but serves the web UI HTML)
- Without `OPENCODE_SERVER_PASSWORD` the server warns that it is unsecured.
  `ds-serve` therefore refuses any bind other than loopback unless it is set.

Attaching:

```bash
opencode run --attach http://127.0.0.1:4096 --dir "$PWD" \
  --agent ds-explorer --model opencode-go/deepseek-v4-flash -- "..."
```

## `--format json` output shape (measured)

NDJSON. **One event object per line.** Not a single JSON document.

```json
{"type":"step_start","timestamp":...,"sessionID":"ses_...","part":{...}}
{"type":"text","timestamp":...,"sessionID":"ses_...","part":{"type":"text","text":"PROBE_OK",...}}
{"type":"step_finish",...,"part":{"reason":"stop","tokens":{"total":7665,"input":7661,"output":4,...},"cost":0.00168806}}
```

- Event types: `step_start` · `text` · `tool_use` · `step_finish`
  (tool events are **`tool_use`**, not `tool`; the tool name is in `.part.tool`)
- Final answer = every `type=="text"` event's `.part.text`, concatenated in order
- Cost/tokens = `.part.cost`, `.part.tokens` on `type=="step_finish"`
- Session id = `.sessionID` on any event
- Non-JSON lines (warnings) can appear, so a parser must drop them with
  `fromjson? // empty` rather than fail

## Agent definitions

One markdown file per agent. **The filename is the agent id.**

Both `~/.config/opencode/agent/` and `~/.config/opencode/agents/` are recognized
(measured with probe files). This skill uses the singular `agent/`. Project-local
agents live in `.opencode/agent/`.

```yaml
---
description: required
mode: all            # primary | subagent | all
model: provider/model
temperature: 0.1
permission:
  edit: deny
  bash: deny
---
system prompt body
```

Permission keys: `read` `edit` `glob` `grep` `list` `bash` `task` `external_directory`
`todowrite` `webfetch` `websearch` `lsp` `skill` `question` `doom_loop`.

Inspection commands: `opencode agent list`, `opencode models`, `opencode auth list`.

## Traps — every one of these was hit in testing

All six fail **silently**. No error; just a wrong result.

### 1. `mode: subagent` cannot be used with `run --agent`

```
! agent "ds-explorer" is a subagent, not a primary agent. Falling back to default agent
```

One warning line on stderr, then it runs **the unrestricted default agent**. The
prompt and the permissions both vanish. Combined with `--auto`, that is an
unrestricted agent running unattended.
→ Every agent in this skill is `mode: all`.

### 2. Symlinked agent files are ignored at run time

They show up perfectly well in `opencode agent list`. But neither the prompt nor
the permissions apply to an actual run. The file must be a real copy.
→ `install.sh` uses `cp`. Do not change it to `ln -s`.

### 3. An unknown agent name is not an error

`--agent no-such-agent-xyz` simply runs the default agent. A typo silently removes
the sandbox.
→ `ds-worker` checks `agent list` before the call, and after the call greps stderr
for `Falling back to default agent`, **failing hard with exit 3**.

### 4. A running backend caches the agent registry it booted with

Editing an agent definition changes nothing until the server restarts. And if that
cached definition was `mode: subagent`, trap 1 fires.
→ `ds-serve` records a fingerprint of the agent files in its state and restarts
automatically when it changes.

### 5. `--file` is an array option and swallows the prompt after it

```
Error: File not found: [supervisor task | role=reviewer | cwd=...]   ← the prompt, read as a filename
```

→ Put `--` before the prompt: `opencode run ... --file x.log -- "prompt"`

### 6. `task` / `skill` are escape hatches around the permission boundary

An agent with `bash: deny` can still hold the `task` tool and delegate to a
subagent that has bash. During testing the explorer pointed this out about itself.
→ All three agents set `task: deny` and `skill: deny`. Decomposition is the
supervisor's job. With those denied, the explorer is left with `glob, grep, read,
todowrite` (measured).

### The guarantee that does hold

With `mode: all`, a real file, and `permission: {bash: deny}`, passing `--auto`
still does not let bash run (measured: `NO_BASH`, zero tool calls).
**`--auto` cannot override `deny`.** But if any of traps 1–4 applies, the agent
itself never took effect, and this guarantee disappears with it.

## DeepSeek models (actually available on this machine)

```
opencode/deepseek-v4-flash-free     # free tier
opencode-go/deepseek-v4-flash       # default explorer
opencode-go/deepseek-v4-pro         # default worker / reviewer
```

This changes. Check with `opencode models | grep deepseek`.

## OmO Slim (optional)

This skill works without it. Together, it lets you assign a model per agent.

```bash
bunx oh-my-opencode-slim@latest install --preset=opencode-go
```

Config: `~/.config/opencode/oh-my-opencode-slim.json`.
