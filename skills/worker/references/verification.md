# Verification protocol

DeepSeek output is a **claim**. It becomes fact only once you confirm it.

## Promotion rules

| What the worker said | What you do |
|---|---|
| `X is at src/a.ts:42` | Open that line. Required before quoting it |
| `Searched for Y, not found` | Run the same pattern once yourself |
| `Tests pass` (no output) | **Unverified.** Run the command |
| `Tests pass` (with output) | For anything that matters, run it again yourself |
| `Fixed A` | Check the real extent with `git diff` |
| `Root cause is Z` | Run the discriminating test yourself |

## Verifying explorer output

Open the line before you quote it. Skip this and you hand the user a line number
that does not exist.

```bash
sed -n '38,50p' src/auth.ts
```

Read `SEARCH COVERAGE` and note **what was not looked at**. If a skipped directory
could overturn the conclusion, check that first.

Be suspicious of an empty `GAPS` section attached to a very clean conclusion.
Honest exploration usually leaves loose ends.

## Verifying worker output

**Keep this order. Do not skip step 1.**

1. **Check the extent of the change** — scope before correctness

   ```bash
   git diff --stat
   git diff
   ```

   Revert anything outside the scope you specified and keep the rest.

2. **Re-run the verification command** — do not trust the pasted output

   ```bash
   npm test -- auth
   ```

3. **Read `NOT DONE` and `RISKS`** — that is the real remaining work

4. **`STATUS: BLOCKED` is a success** — it stopped instead of guessing. Resolve the
   ambiguity and delegate again, or take it over

## Verifying reviewer output

Run each candidate's `Discriminating test` yourself. An untested hypothesis is not
adopted. If every candidate says "none found" under `Contradicts`, the reviewer did
not look for counter-evidence.

## Changes that are hard to undo

These never go to a worker. You do them:

- Commits, pushes, PRs, tags
- Migrations, schema changes
- Adding or bumping dependencies
- Config files, CI, secrets
- Deleting files, bulk renames

## Reporting to the user

Say, in words, which is which.

> The auth middleware is at `src/auth/middleware.ts:88` (confirmed directly).
> The explorer also reported a verification path in `src/session/store.ts`, which
> I have not checked yet.

"The worker says it passed" does not mean it passed. Do not write it that way.
If you did not verify, say you did not verify.
