---
name: worker
description: Use when delegating work to the local GX10 DeepSeek/Qwen models via OpenCode headless - codebase exploration, repeated searches, implementation-candidate research, test log analysis, or tightly specified implementation. Establishes the supervisor role - you decompose, decide and verify; the ds-worker command executes. Triggers on "ds-worker", "delegate to DeepSeek", "delegate to Qwen", "supervisor mode", "hand the search off".
---

# worker

You are the **supervisor**. A GX10 worker (local DeepSeek, falling back to
local Qwen) is your hands, not your judgment.

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

**Never delegate**: vague tasks, implementation whose design is unsettled, changes
that are hard to undo, anything you will say to the user, commits, pushes, PRs.

## Invoking

```bash
ds-worker <role> [--dir <path>] "<instruction>"
```

```bash
ds-worker explorer "Find every call site of checkToken in src/ — list all of them, not a sample. file:line required."
ds-worker reviewer --file test.log "Rank the root-cause candidates for this failure, reading the log to its end."
ds-worker worker "checkToken at src/auth.ts:42 returns 500 for an expired token instead of 401. Make it 401. Verify: npm test -- auth"
```

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
DS_MODEL_REVIEWER=gx10/qwen3.8-27b ds-worker reviewer --file test.log "..."
```

The GX10 box serves one model at a time, so ds-worker asks the endpoint which
model is actually loaded and uses that — load Qwen instead of DeepSeek on
`:8000` and calls follow it with no config change. It redirects only to a model
present in the provider's catalog in `opencode.jsonc`; otherwise it keeps the
configured pin and says why. Set `DS_MODEL_AUTODETECT=0` to disable.

After ADDING a model to `opencode.jsonc`, restart the shared backend
(`ds-serve restart`). It reads the config once at startup, so a long-lived
backend keeps serving the old catalog and calls to the new model fail with
`UnknownError: Unexpected server error` — which looks like a model or network
fault but is a stale backend. `ds-doctor` compares them: its `serving now:` line
is the live endpoint, the `model` lines are what is configured.

Each role tries its resolved model up to `DS_MODEL_RETRIES` times (default 2),
then its fallback model up to `DS_MODEL_RETRIES` more times if one is set —
none is by default, so the call fails once those attempts are spent. `--model`
bypasses this chain and runs exactly that model once. For the writing
`worker` role, the chain only continues while `--dir` is a git working tree
confirmed unchanged since the chain started — see "Never treat the result as
fact" below for why a writing role does not retry blindly otherwise.

## Slow local reasoning models

OpenCode's provider options have two separate protections:

- `chunkTimeout` is the maximum gap between streamed SSE chunks. It is not a
  per-token timeout, and it must not watch only `delta.content`.
- `timeout` is the provider request's absolute wall-clock limit.

For a local provider (DeepSeek or Qwen), configure those options in OpenCode's
provider configuration, then restart the owned backend with `ds-serve restart`.
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

For `explorer` and `reviewer`, if a session id exists but the required final
report is missing, the wrapper makes at most one continuation request without
using tools or doing more searches. `recovered`, `initial_outcome`,
`initial_exit`, and `initial_timeout_reason` make that first attempt visible.
Set `DS_AUTO_RECOVER_READONLY=0` to disable it. Progress notices are numeric
stderr diagnostics only; they never print raw model output.

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

GX10 worker output (DeepSeek or Qwen, whichever answered) is a **claim**, not a
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

- `agent ... is not installed` / `mode=subagent` → run `install.sh`
- **exit 3 (`ran the UNRESTRICTED default agent`)** → the sandbox was not applied.
  Discard the result. Re-run `install.sh`, then delegate again
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
