---
name: worker
description: Use when delegating work to a cheaper DeepSeek model via OpenCode headless - codebase exploration, repeated searches, implementation-candidate research, test log analysis, or tightly specified implementation. Establishes the supervisor role - you decompose, decide and verify; the ds-worker command executes. Triggers on "ds-worker", "delegate to DeepSeek", "supervisor mode", "hand the search off".
---

# worker

You are the **supervisor**. A DeepSeek worker is your hands, not your judgment.

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
ds-worker explorer "Find the auth middleware: entry point, where the token is verified, failure paths. file:line required."
ds-worker reviewer --file test.log "Rank the root-cause candidates for this failure."
ds-worker worker "checkToken at src/auth.ts:42 returns 500 for an expired token instead of 401. Make it 401. Verify: npm test -- auth"
```

Main options: `--dir` working directory · `--model` override · `--session <id>` continue
a session · `--file` attach a file · `--json` structured output · `--timeout <sec>`.
Full list: `ds-worker --help`. CLI facts: [references/opencode-cli.md](references/opencode-cli.md).

## Writing the instruction

A worker's output never exceeds the quality of its instruction. Every call:

1. **One goal, one sentence.** More than one goal means more than one call.
2. **State the boundary.** "This file only", "this function only", "touch nothing else".
3. **Give a completion test.** For `worker`, always include the verification command.
4. **Tell it to stop when unsure.** "If this is ambiguous, make no edits and return BLOCKED."
5. Include background only where it changes the result. Do not paste the whole conversation.

## Never treat the result as fact

DeepSeek output is a **claim**, not a fact. Required:

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
- Timeout (exit 124) → the task was too big. Split it and delegate again
- Full diagnostic: `ds-doctor`

If a worker fails the same task twice, **stop delegating and do it yourself.**
A third attempt is almost always waste.
