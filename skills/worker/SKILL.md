---
name: worker
description: Use when delegating work to a configured worker model (a local model server or a hosted API) via OpenCode headless - codebase exploration, repeated searches, implementation-candidate research, test log analysis, or tightly specified implementation. Establishes the supervisor role - you decompose, decide and verify; the ds-worker command (ds = delegated subagent) executes. Triggers on "ds-worker", "delegate to the local model", "delegate to the worker", "supervisor mode", "hand the search off".
---

# worker

You are the **supervisor**. The worker — whatever model `DS_MODEL` names, local
or hosted — is your hands, not your judgment. *ds* = delegated subagent.

## You do this yourself (never delegate)

- **Task decomposition** — what happens, in what order
- **Decisions** — design, trade-offs, what to fix and what to leave
- **Final verification** — whether a change is actually correct
- Every exchange with the user

Never ask a worker "how should we do this?" Decide first, then hand over execution.

## You delegate this

| Work | role | Why |
|---|---|---|
| Codebase exploration | `explorer` | Wide reading. The conclusion stays yours |
| Repeated search | `explorer` | Same pattern N times — tedious and mechanical |
| Implementation candidates | `explorer` | Gathering options. Choosing is yours |
| Test log analysis | `reviewer` | Pulling signal out of long output |
| Tightly specified implementation | `worker` | Only what you have already designed |
| Document audit before delivery | `critic` | The doc-critic persona — cross-model judge on `DS_MODEL_CRITIC` |
| Judgment over material you hand it | `direct` | One chat completion straight to the model endpoint — no OpenCode, no tools |

**Never delegate**: vague tasks, implementation whose design is unsettled, changes
that are hard to undo, anything you will say to the user, commits, pushes, PRs.

## Invoking

```bash
ds-worker <role> [--dir <path>] "<instruction>"
ds-worker omo <agent> [--dir <path>] "<instruction>"
ds-worker direct [--file <path>]... "<instruction>"
```

```bash
ds-worker explorer "Find every call site of checkToken in src/ — list all of them, not a sample. file:line required."
ds-worker reviewer --file test.log "Rank the root-cause candidates for this failure, reading the log to its end."
ds-worker worker "checkToken at src/auth.ts:42 returns 500 for an expired token instead of 401. Make it 401. Verify: npm test -- auth"
ds-worker omo oracle "Review this design for failure modes."
ds-worker omo council "Debate whether to split the auth service."
ds-worker omo ds-explorer "Find every call site of checkToken in src/."
ds-worker omo ds-reviewer --file test.log "Rank the root-cause candidates."
ds-worker critic --file docs/plan/foo.md "Audit this document for factual drift before delivery."
ds-worker direct --file test.log "Rank the root-cause candidates for this failure."
```

`explorer` / `reviewer` / `worker` run on `DS_MODEL` (or their per-role
override). `critic` is the fourth persona: it dispatches the global `doc-critic`
agent (`~/.config/opencode/agent/doc-critic.md`) on `DS_MODEL_CRITIC` — a model
other than `DS_MODEL` is the point of the role; left empty, OpenCode's default
model answers. No autodetect and no fallback chain apply to it. Required final
artifact: a `VERDICT:` line. Pass the document with `--file` or an exact path in
the prompt; critic reads only what you hand it.

`direct` skips OpenCode entirely: it sends one OpenAI-style chat completion to
the model endpoint (`DS_MODEL_ENDPOINT`, else the provider's `baseURL` in
`opencode.jsonc`; an API key from the variable `DS_MODEL_API_KEY_ENV` names)
with the `--file` contents inlined, and follows a single-model server like the
other roles. The model has **no tools** — it cannot open a path
you only name, search, or edit — and there are no agent permissions or
sessions; `--dir`, `--session` and similar options are refused. Use it for
logs, diffs and documents you can hand over whole, and as the path that keeps
working when the OpenCode CLI changes. It has no report contract: any
non-empty answer is `CLEAN_RESULT`; an empty one exits 4, an HTTP or
connection error 1, `--max-runtime` 124. The request and raw reply are kept
under `$DS_STATE_DIR/runs/`.

## Persona files and sync

The personas carry no `model:` line: the model comes from the config file and
travels as `--model`, so one set of persona files works with any provider. See
[portability](references/portability.md).

All four persona definitions are owned by this skill's `agents/` folder — the
supervisor's management point. OpenCode loads copies from
`~/.config/opencode/agent/`; the link is a copy, because symlinked agent files
are ignored at run time. After editing any persona file run

```bash
sync-agents --install     # skill/agents/*.md -> the live registry
sync-agents               # drift check only (exit 1 on difference)
```

`sync-agents --backfill` reverses the direction (adopt a newer live file once).
Every persona's permissions start with `"*": deny`: OpenCode v2 grants any tool
nobody named (the code-mode `execute` tool among them), so the personas allow
back only what each role needs. Keep that line first when you edit them.

Main options: `--dir` working directory · `--model` override · `--session <id>` continue
a session · `--file` attach a file · `--json` structured output · `--idle-timeout <sec>`
stream inactivity · `--max-runtime <sec>` absolute cap · `--progress-interval <sec>`
progress diagnostics (`--timeout` is the legacy max-runtime alias).
Full list: `ds-worker --help`. CLI facts: [references/opencode-cli.md](references/opencode-cli.md).

Defaults (models per role, stream idle timeout, max runtime, backend) live in
`~/.config/ds-worker/config`.
`ds-doctor --config` prints what is in effect and where each value came from.
An environment variable still wins for a single call:

```bash
DS_MODEL_REVIEWER=<provider/model> ds-worker reviewer --file test.log "..."
```

With no `DS_MODEL` the local roles refuse to run and say how to set it
(`install.sh --model <provider/model>`).

A local server that serves one model at a time makes a pinned name stale when
another is loaded, so ds-worker asks the endpoint which models it serves and
follows it only when that is one model (a single entry, or aliases sharing one
`root`; a configured alias is kept). It redirects only to a model present
in the provider's catalog in `opencode.jsonc`; otherwise — and always for a
hosted API listing many — it keeps the configured pin and says why. Set
`DS_MODEL_AUTODETECT=0` to disable.

Every OpenCode role is started inside `--dir` (OpenCode v2 has no `run --dir`;
a v2 server uses the client's cwd). By default each call runs
`opencode run --standalone`, a private server per call. With `DS_SERVE=auto`
it runs `--server` against the backend `ds-serve` owns. That saves about 1.7 s
of startup per call (3.4 s vs 1.7 s for a minimal call), which matters only for
many short calls. The backend is password-protected: `ds-serve` keeps the
password in `$DS_STATE_DIR/serve.password` (0600) unless
`OPENCODE_SERVER_PASSWORD` is set, and ds-worker passes it as
`OPENCODE_PASSWORD`, never on argv. Read-only recovery always runs
`--standalone`, because its tools-off override cannot reach a running server.
v2's own managed `opencode service` is not used. Whether it can reach a LAN model
box depends on where it was last started. See
[references/opencode-cli.md](references/opencode-cli.md).

Each role tries its resolved model up to `DS_MODEL_RETRIES` times (default 2),
then its fallback model up to `DS_MODEL_RETRIES` more times if one is set —
none is by default, so the call fails once those attempts are spent. `--model`
bypasses this chain and runs exactly that model once. For the writing
`worker` role, the chain only continues while `--dir` is a git working tree
confirmed unchanged since the chain started — see "Never treat the result as
fact" below for why a writing role does not retry blindly otherwise.

The `omo` gateway has a strict allowlist: `oracle`, `council`, `librarian`,
`designer`, `fixer`, `ds-explorer`, and `ds-reviewer`. OMO built-ins run without
`--model` by default, so the active OMO Slim preset chooses its model, variants,
seat arrays, and external providers. The wrapper performs one OMO attempt and
does not blindly retry a full Council. The five built-ins (`oracle`, `council`,
`librarian`, `designer`, `fixer`) are OpenCode subagents, so each runs through
the primary `orchestrator` with `task(subagent_type='<agent>')`: `council`
collects every configured seat and synthesizes, the others request their named
subagent once. A `(subagent)` mode in `opencode debug agents` is expected for
these built-ins and is only a problem if you pass such an agent directly to
`opencode run --agent`; do not reinstall to "fix" it. The `ds-explorer`
and `ds-reviewer` gateway aliases retain the local DS model and final-report
contracts. `omo fixer` may edit files but does not receive the legacy writing
worker's git-safety contract (it is still refused for `--dir $HOME` or `/`).

## Slow local reasoning models

OpenCode's provider options have two separate protections:

- `chunkTimeout` is the maximum gap between streamed SSE chunks. It is not a
  per-token timeout, and it must not watch only `delta.content`.
- `timeout` is the provider request's absolute wall-clock limit.

For a local provider, configure those options in OpenCode's
provider configuration.
The worker wrapper adds a second boundary:

- `--idle-timeout` resets on every OpenCode NDJSON output write, including
  reasoning-only and tool events; it does not depend on `part.text`.
- `--max-runtime` remains an independent safety cap. A stream that is active
  forever must still terminate.
- In `--json` output, exit 124 is exposed as `status: "timed_out_unknown"`
  with `timeout_reason: "idle"` or `"max-runtime"`.

Do not estimate token throughput from NDJSON/SSE chunk counts. Speculative
decoding can put multiple accepted tokens in one chunk. Use final
`usage.completion_tokens` for completed-run statistics and a provider/server
metric for live throughput when one is available.

## Result and recovery contract

With `--json`, the wrapper emits one structured object and keeps the raw event
stream plus stderr under `DS_STATE_DIR/runs/`. `outcome` is one of:

- `CLEAN_RESULT` — the process exited successfully and the role's required
  final report sections were present.
- `FINAL_ARTIFACT_MISSING` — the process exited successfully but its required
  final report was absent; the wrapper exits `4` unless read-only recovery
  succeeds.
- `TOOL_ONLY_NO_FINAL_ARTIFACT` — a timeout occurred after tool events but
  before the required final report.
- `IDLE_TIMEOUT` — no NDJSON write occurred within `DS_IDLE_TIMEOUT`.
- `MAX_RUNTIME` — the absolute `DS_MAX_RUNTIME` cap fired.
- `AMBIGUOUS_PARTIAL`, `FAILED`, or `TIMEOUT` — other incomplete outcomes.

Exit `124` means `timed_out_unknown`; it does not prove that the task was too
large or that no edits happened. Inspect the saved logs and `git diff` before
continuing. The writing `worker` role's own primary/fallback chain (above)
retries only while `--dir` is confirmed unchanged since the chain started;
once you (the supervisor) have the result back, never re-invoke a writing
role yourself without first checking `git diff`/`git status` — see "When it
fails" below.

For `explorer`, `reviewer` (including the `ds-explorer` and `ds-reviewer`
gateway aliases) and `critic`, if a session id exists but the required final report is
missing, the wrapper owns **one** read-only recovery continuation on the same
session. That continuation disables tools and model thinking and reports only the
evidence the session already produced — it never searches again. `recovered`,
`initial_outcome`, `initial_exit`, and `initial_timeout_reason` make that first
attempt visible. Set `DS_AUTO_RECOVER_READONLY=0` to disable it. Progress
notices are numeric stderr diagnostics only; they never print raw model output.

The initial read-only prompt also carries an advisory budget notice: treat any
configured agentic-step limit as a safety ceiling, not a target or a tool-call
quota, prioritize the highest-value evidence, and near the ceiling stop
initiating new searches and emit the required report with explicit evidence
gaps. The notice is guidance in the prompt only — the wrapper does not count or
enforce tool calls, and `steps` is not a tool-call quota. Explicit gaps are the
required way to end a read-only run that ran out of budget.

JSON results include `agent` and `dispatch`. OMO-configured calls use
`dispatch: "omo-configured"`, report `agent: "orchestrator"` (the OMO subagents
are reached through it via `task(subagent_type=...)`), and report `model: null`
when the preset selected the model; explicit `--model` reports the pinned model.

## Writing the instruction

A worker's output never exceeds the quality of its instruction. Every call:

1. **One goal, one sentence.** More than one goal means more than one call.
2. **State the boundary.** "This file only", "this function only", "touch nothing else".
3. **Give a completion test.** For `worker`, always include the verification command.
4. **Tell it to stop when unsure.** "If this is ambiguous, make no edits and return BLOCKED."
5. **State the exhaustion constraint explicitly for any enumeration.** A local
   model defaults to a representative sample, not a full listing. Say how many
   or how far: "all 12 call sites, not a sample", "every match in this file",
   "to the end of the file, not just the first screen", "list all N, do not
   summarize after the first few". No explicit bound = expect a partial answer.
6. Include background only where it changes the result. Do not paste the whole conversation.

## Never treat the result as fact

Worker output (whichever model answered) is a **claim**, not a
fact. Required:

- Every `file:line` from `explorer` — **read it yourself before quoting it.** Line
  numbers can be invented.
- If a `worker`'s `VERIFICATION` block has no command output, **it is unverified.**
  Even with output, for anything that matters **run the command yourself.**
- A `reviewer`'s diagnosis is a hypothesis. Run its discriminating test before adopting it.
- If a worker says it edited something, **check the real extent with `git diff`.**
  Scope creep is common.

**Before any change that matters, verify it yourself. No exceptions.** Procedure:
[references/verification.md](references/verification.md).

## How a task runs

1. Decompose, and decide per piece whether it is delegable → [references/delegation-playbook.md](references/delegation-playbook.md)
2. Fire independent pieces in parallel (never two writing `worker`s on the same file)
3. **Verify** what comes back
4. Base the next decision only on what you verified
5. When reporting to the user, **say which parts you verified and which are worker claims**

## When it fails

- `agent ... is not installed` / `mode=subagent` → run `sync-agents --install` (or `install.sh`)
- `could not read the agent list` → `opencode debug agents` gave no JSON array
  three times. Check `opencode --version` and run
  `bash tests/test_opencode_v2_contract.sh` from the skill's repository: a
  failing line names the CLI change. Meanwhile `ds-worker direct` still works
  for material you can hand over.
- `provider.transport` / `EHOSTUNREACH` in the result's `errors` → the OpenCode
  process cannot reach the model server. Compare with
  `ds-doctor` (it curls the endpoint) from the same shell.
- **exit 3 (`ran the UNRESTRICTED default agent`)** → the sandbox was not applied.
  Discard the result. Re-run `sync-agents --install`, then delegate again
- `bin/ds-worker-rr` → rotates `--model` over `DS_RR_MODELS` (space-separated,
  environment or config file); fewer than two = plain `ds-worker`. It honors
  `DS_STATE_DIR`/`XDG_STATE_HOME` for its rotation counter.
- `no model configured` → set `DS_MODEL=<provider/model>` in
  `~/.config/ds-worker/config` (`install.sh --model` does it); `opencode models`
  lists what OpenCode can reach.
- `no text output` → the run may have finished and been billed while the event
  stream dropped the final message. **The work is usually still in the session.**
  Recover it — this costs almost nothing, since the model answers from context:

  ```bash
  ds-worker <role> --session <id> "Repeat your previous final report verbatim."
  ```

  The session id is printed in the footer of every call. If that comes back empty
  too, inspect the raw stream with `--raw` or the log in
  `~/.local/state/ds-worker/runs/`
- Timeout (exit 124) → classify the result as `timed_out_unknown`, not
  automatically as "the task was too big". Preserve the raw stream and stderr,
  inspect the session and `git diff`/`git status`, then decide whether a
  continuation is safe. Never automatically retry a writing task: a timeout
  can occur after partial file changes.
- Full diagnostic: `ds-doctor`

If a worker fails the same task twice, **stop delegating and do it yourself.**
A third attempt is almost always waste.
