# Delegation playbook

## The one-line test

> **Work whose answer you already know** gets delegated.
> **Work where the answer must be found** stays with you.

A worker is strong at reading widely and repeating mechanical steps, and weak
exactly where judgment is required. Delegate judgment and you get a plausible
wrong answer back, then spend longer verifying it than doing it yourself.

## Choosing a role

### `explorer` — read-only, wide

Use it for:
- "Where is X?" in an unfamiliar codebase
- The same pattern searched across many directories
- Collecting library or implementation candidates (you pick)
- Call graphs, entry points, data flow maps

Do not use it for:
- A single file you could just open — you are faster
- Anything you already know the answer to — you only pay round-trip cost

The instruction must state: **what you are looking for**, **how far to look**,
**`file:line` required**.

### `reviewer` — read-only, deep

Use it for:
- Extracting failure signal from thousands of log lines
- Stack trace → ranked root-cause candidates
- Sweeping a large diff for risk

Do not use it for:
- Open questions like "is this code okay?" — you get flattery back
- Final approval — a reviewer has no authority to approve

The instruction must state: **the criteria**, and attach the log or diff (`--file`).

### `worker` — writing

Use it **only when all four are true**:
1. You have named the file and function to change
2. You have already decided how to change it
3. There is a command that decides completion
4. Being wrong is cheap to undo (a small uncommitted change)

If any one is false, do it yourself.

Instruction template:

```
<file:line> <function> currently <behavior>. Change it to <desired behavior>.

Scope: this function only. Do not touch other files, other functions, or formatting.
Verify: <command>
If this is ambiguous, make no edits and return BLOCKED.
```

### `critic` — cross-model document judge

The only persona not on the local engine: it runs the global `doc-critic` agent,
whose model binding comes from the agent config. Use it when a long-form document
(plan, report, task record) is about to be delivered and a second model's
independent read is the point — the global AGENTS.md policy already mandates one
such pass. Hand it the document with `--file` or exact paths; it reads only what
you give it, and any repo/log verification it wants comes back as numbered
`EVIDENCE REQUEST`s — those are `explorer`/`reviewer` work, then you bring the
answers back for the next verdict round. Its verdict is a gate to read, not
ground truth: you still decide.

Instruction template:

```
Audit <path> before delivery. Judge factual verifiability, internal
consistency, source-of-truth discipline, credential leaks, noise.
Issue numbered EVIDENCE REQUESTs for anything that needs repo verification.
```

## Parallelism

Independent pieces go at once.

```bash
ds-worker explorer --dir "$PWD" "map the auth paths" &
ds-worker explorer --dir "$PWD" "where the session store is implemented" &
wait
```

**Never** run two writing `worker`s against the same file — they overwrite each
other's edits. `explorer` and `reviewer` are read-only and safe in parallel.

## Reusing a session

A follow-up question is cheaper and sharper as a session continuation than as a
fresh call.

```bash
OUT=$(ds-worker explorer --json "map the auth paths")
SID=$(printf '%s' "$OUT" | jq -r .session)
ds-worker explorer --session "$SID" "now just the part that handles token expiry"
```

But a long session lets a worker harden its own earlier guesses into assumptions.
Past three or four round trips, reset to a new session.

## Cost sense

`.cost` in the `--json` output gives per-call cost. Frequent round trips mean you
are delegating work that reading it yourself would have finished. Notice that.

## When to stop

- Two failures on the same task → stop delegating, do it yourself
- Verification takes longer than delegation → that class of work was never delegable
- The worker keeps escaping scope → the instruction is unclear. Fix it or take over
