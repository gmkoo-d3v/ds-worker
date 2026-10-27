# OpenCode CLI — verified facts

Against `opencode v2.1.4` (2026-10-27). Everything below was **run locally and
observed**, not taken from documentation alone. Sections that still describe
`1.18.18` behavior say so.
Official docs: <https://opencode.ai/docs/cli/>, <https://opencode.ai/docs/agents/>

Every v2 call that differs from v1 goes through `lib/opencode-cli.sh`, and
`tests/test_opencode_v2_contract.sh` checks the shape against the installed
binary (`DS_CONTRACT_LIVE=1` adds round trips to your configured model).

The measurements were taken against a local model server on the LAN (a GX10
box running vLLM, one model loaded at a time); "the model server" below means
that machine.

## Headless execution

```bash
opencode run --standalone "investigate this"
```

Actual flags, from `opencode run --help` (v2.1.4):

| Flag | Meaning |
|---|---|
| `-m, --model <provider/model#variant>` | Model; the reasoning variant is a `#` suffix |
| `--agent <name>` | Agent |
| `--format default\|json` | `json` emits a **raw JSON event stream** |
| `--standalone` | Run with a private server instead of the background service |
| `--server <url>` | Connect to a server URL instead of the background service |
| `-s, --session <id>` / `-c, --continue` / `--fork` | Session continuation |
| `-f, --file <path>` | Attach a file (repeatable) |
| `--auto` | Auto-approve permissions that are not explicitly denied |
| `--title`, `--thinking` | Misc |

### What v2 removed, and what ds-worker does instead

| v1 | v2 | ds-worker |
|---|---|---|
| `opencode agent list` | prints help, **exits 0** — a grep on it finds nothing | `oc_agent_list` reads `opencode debug agents` (JSON array of `name`, `mode`, `hidden`, `permissions`) and prints `name (mode)` rows |
| `run --dir <path>` | unknown flag, prints help | the child is started inside `--dir` (`oc_in_dir`); v2 uses the process cwd |
| `run --attach <url>` | `--server <url>` | `--server` to the `ds-serve` backend with `DS_SERVE=auto`, else `--standalone` |
| `run --variant <name>` | `--model provider/model#variant` | `oc_model_ref` appends `#variant` |

Measured v2 behavior the wrapper relies on:

- **Default is a shared background service.** Run through it, the model server
  was unreachable (`provider.transport` · `EHOSTUNREACH`) while `curl` from the
  same shell reached it, and `--standalone` from the same shell worked. ds-worker
  always passes `--standalone`, which is also what `DS_SERVE=off` always meant.
- `opencode debug agents` has returned `[]` once and a truncated document once on
  back-to-back calls; `oc_agent_list` accepts only a non-empty array and retries
  up to 3 times.
- `--` before the prompt is still accepted, and `--session <id> --continue`
  resumes that exact session.
- `OPENCODE_CONFIG_CONTENT` still applies to a `--standalone` run (a tools-off
  override made the agent answer without tools). `opencode debug agents` and
  `opencode debug config` do not show it.
- Errors arrive as a `{"type":"error","error":{"type":...,"message":...}}` event
  with exit 1; ds-worker copies the messages into the result's `errors` array.

## Long-lived backend (v2)

`ds-serve` starts its own `opencode serve` and gives it a password through
`OPENCODE_SERVER_PASSWORD`: the caller's, or one generated into
`$DS_STATE_DIR/serve.password` (0600). It counts the backend as ours only when
an authenticated `GET /api/info` reports the pid it recorded. The credential
goes to curl on stdin (`-K -`). With `DS_SERVE=auto`, `ds-worker` runs
`--server <url>` and passes the password as `OPENCODE_PASSWORD`. Read-only
recovery always runs `--standalone`; a standalone run continues a session the
backend created, since both use OpenCode's database. The live part of
`tests/test_opencode_v2_contract.sh` covers all three.

What a v2 `opencode serve` does, measured on 2026-10-27 against a server
started from a normal shell on a spare port:

- **Password.** Without `OPENCODE_SERVER_PASSWORD` the server generates one and
  prints it on startup. With it set, that value is used and nothing is printed.
  Basic auth with username `opencode`; a wrong password or user gets `401`.
- **Which paths need auth.** `/api/*` and `/openapi.json` (124 paths) answer
  `401` without auth. Every other path, `/config` included, serves the web UI
  HTML with `200`, so a 200 there proves nothing.
- **Readiness and ownership probe.** `GET /api/info` with auth returns JSON with
  `version`, `pid` and `urls`. The `pid` matched the pid `nohup` reported, so
  the probe can check "ours" directly instead of only "something answers".
- **Client auth.** `run --server URL` with no credential exits 1 with
  `Server at URL requires a password; set OPENCODE_PASSWORD`.
  `OPENCODE_PASSWORD`, `OPENCODE_SERVER_PASSWORD`, and `user:pass@` in the URL
  all worked. Prefer the environment variable: argv is visible in `ps`.
- **Working directory.** A `--server` run works in the **client's** cwd: two
  clients in two directories each read their own `marker.txt` and reported
  their own path. Per-call `--dir` therefore works through a shared server.
- **Model server reachability.** A server started from our shell reached the model server, with
  tools. The EHOSTUNREACH seen earlier came from one `opencode service`
  process that had been started from another terminal app. Every run
  through it failed with EHOSTUNREACH. After `opencode service restart` from
  the shell these tests ran in, the new service process (same URL) read a
  file with tools and answered from the model server. So whether the managed service
  can reach the LAN depends on where it was last started. macOS
  local-network permission for the launching app is the likely cause; that
  part is not verified.
- **Managed service auth.** The managed service also answers `401` on
  `/api/info` without credentials, but `opencode run` and `opencode api`
  authenticate to it on their own; no variable was set.
- **Per-call config does not travel.** `OPENCODE_CONFIG_CONTENT` on the client
  did not reach the server: a tools-off override still let the agent read a
  file. The read-only recovery step must stay `--standalone`.
- **Agent edits are picked up late.** A new agent file was `Agent not found` on
  the call right after it was written; an edited one answered with the old
  definition right after the edit and with the new one 5 s later. No restart
  is needed, but there is a stale window of a few seconds (measured with a
  project-local `.opencode/agent/`).
- **stdin.** `run` reads a non-terminal stdin to EOF before it starts: with an
  open pipe on stdin it waited 21 s, exactly as long as the pipe stayed open.
  `oc_in_dir` runs the child with `</dev/null`.
- **Cost of `--standalone`.** "Reply with exactly: pong" took 3.2–3.7 s with
  `--standalone` vs 1.5–1.9 s through a running server (5 runs each). The same
  request by plain `curl` to the model server took 0.6 s.

What held on 1.18.18:

```bash
opencode serve --hostname 127.0.0.1 --port 4096
```

- **Health check**: `GET http://127.0.0.1:4096/config` → `200`, `application/json`
  (`/app` also returns 200 but serves the web UI HTML)
- Without `OPENCODE_SERVER_PASSWORD` the server warns that it is unsecured.
  `ds-serve` therefore refuses any bind other than loopback unless it is set.

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

The wrapper's four personas: `ds-explorer`, `ds-reviewer`, `ds-worker` (roles
`explorer`/`reviewer`/`worker`, local-model-pinned via `--model`) and
`doc-critic` (role `critic`, `mode: all` so `run --agent` accepts it, model bound
in its own frontmatter — the wrapper deliberately sends no `--model` for it, so
the cross-model binding survives; `DS_MODEL_CRITIC`/`--model` pin deliberately).
The persona md files are owned by `agents/` next to `bin/`; the live registry
under `~/.config/opencode/agent/` holds copies maintained by
`bin/sync-agents --install` (drift check: `sync-agents`).

Inspection commands: `opencode debug agents` (JSON), `opencode models`, `opencode auth list`.

## OMO Slim gateway

`ds-worker omo <agent> "..."` accepts only the following mapped agents:

| Gateway agent | OpenCode dispatch | Model source |
|---|---|---|
| `oracle` / `council` / `librarian` / `designer` / `fixer` | `orchestrator` (they are `mode: subagent` and cannot be passed to `run --agent` directly) | active OMO Slim preset; `--model` omitted by default; prompt requests `task(subagent_type='<agent>')` |
| `ds-explorer` | `ds-explorer` | existing ds-worker local model chain |
| `ds-reviewer` | `ds-reviewer` | existing ds-worker local model chain |

The wrapper rejects agents outside this allowlist before dispatch. OMO-configured
calls make one wrapper attempt so OMO Slim owns its configured seat/model
fallback; the wrapper must not blindly retry a full Council and duplicate
external calls. `council` asks the orchestrator to collect every configured
seat and synthesize; the other built-ins request their named subagent once.
Seeing `(subagent)` next to an OMO built-in in the agent list is the
expected mode — it is only invalid when such an agent is passed directly to
`opencode run --agent`; do not reinstall to change it. `fixer` may write files,
is refused for `--dir $HOME` or `/`, and does not carry the legacy worker
role's git-safety retry contract.

## Traps — every one of these was hit in testing

All six fail **silently**. No error; just a wrong result.

### 1. `mode: subagent` cannot be used with `run --agent`

```
! agent "ds-explorer" is a subagent, not a primary agent. Falling back to default agent
```

(1.18.18) One warning line on stderr, then it runs **the unrestricted default agent**. The
prompt and the permissions both vanish. Combined with `--auto`, that is an
unrestricted agent running unattended.
→ Every agent in this skill is `mode: all`. OMO's built-ins are the exception:
they legitimately ship as `mode: subagent`, which is fine because
`ds-worker omo` never passes them to `run --agent` — it dispatches the primary
`orchestrator` and requests them via `task(subagent_type=...)`.

### 2. Symlinked agent files are ignored at run time

They show up perfectly well in the agent list. But neither the prompt nor
the permissions apply to an actual run. The file must be a real copy.
→ `install.sh` uses `cp`. Do not change it to `ln -s`.

### 3. An unknown agent name is not an error

(1.18.18) `--agent no-such-agent-xyz` simply runs the default agent. A typo
silently removes the sandbox. v2.1.4 fails instead (`Agent not found`, exit 1);
the contract test's live part pins that.
→ `ds-worker` checks the agent list before the call, and after the call greps stderr
for `Falling back to default agent`, **failing hard with exit 3**.

### 4. A running backend caches the agent registry it booted with

Editing an agent definition changes nothing until the server restarts. And if that
cached definition was `mode: subagent`, trap 1 fires.
→ `ds-serve` records a fingerprint of the agent files in its state and restarts
automatically when it changes.

### 5. `--file` is an array option and swallows the prompt after it (1.18.18)

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

### 7. MCP tools are outside the native permission model entirely

`bash: deny` does not stop `serena_execute_shell_command`, and `edit: deny` does
not stop `serena_replace_symbol_body`. An MCP server declared in `opencode.jsonc`
injects its tools into **every** agent, and the native permission keys do not
reach them.

`permission` accepts arbitrary tool-name keys, wildcards included, and a specific
key beats the wildcard — both confirmed in the resolved output of
`opencode agent list` (v2: the `permissions` array in `opencode debug agents`). So each agent default-denies the namespace and allows back
a named read-only set:

```yaml
  "serena_*": deny
  "serena_find_symbol": allow
  ...
```

Anything the MCP server adds later is denied by default rather than silently
granted.

**Residual limitation, not fixed here:** an MCP server runs as its own process
under its own user, so its file reads are bound by *that* user's permissions and
its own project scope — not by this agent's `external_directory: deny`, and not by
the file permissions of whoever runs opencode. Narrowing that belongs in the MCP
server's configuration, not in an agent definition.

### The guarantee that does hold

With `mode: all`, a real file, and `permission: {bash: deny}`, passing `--auto`
still does not let bash run (measured: `NO_BASH`, zero tool calls).
**`--auto` cannot override `deny`.** But if any of traps 1–4 applies, the agent
itself never took effect, and this guarantee disappears with it.

## Models (catalog vs. actually loaded)

A local server often serves ONE model at a time behind a single provider. The
provider's model list in `opencode.jsonc` is a catalog, not what is live.
ds-worker resolves the live one itself when the server serves one model —
one entry, or aliases sharing a `root` (see
`DS_MODEL_AUTODETECT`); to check by hand:
`curl -s http://<model-host>:<port>/v1/models`

Adding an entry here is not enough on its own: `opencode serve` snapshots the
config at startup, so run `ds-serve restart` afterwards. Against a stale backend
the new model fails as `UnknownError: Unexpected server error`, with nothing in
the stream to say the model is simply unknown to it. Confirm what a backend
actually knows with `opencode models` against it, or (v1) its `/config`.

A local provider entry in `opencode.jsonc` looks like this (any
OpenAI-compatible server; the id `local` is yours to choose):

```jsonc
{
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "http://<model-host>:8000/v1" },
      "models": { "your-model": {} }
    }
  }
}
```

`opencode models` then lists `local/your-model`, which is what `DS_MODEL` takes.

Provider config (baseURL, timeouts) lives in `~/.config/opencode/opencode.jsonc`
under the provider used by the selected model. Check the resolved provider with
`opencode models` and `opencode debug config`. For a slow local
reasoning model, the relevant options are:

```jsonc
{
  "provider": {
    "<local-provider-id>": {
      "options": {
        "chunkTimeout": 60000,
        "timeout": 1800000
      }
    }
  }
}
```

`chunkTimeout` is the maximum gap between streamed response chunks, not a
per-token timer. `timeout` is the provider request's absolute wall-clock cap.
After changing either option, restart the backend owned by this skill:
`ds-serve restart`.

## OmO Slim (optional)

This skill works without it. Together, it lets you assign a model per agent.

```bash
bunx oh-my-opencode-slim@latest install --preset=opencode-go
```

Config: `~/.config/opencode/oh-my-opencode-slim.json`.
