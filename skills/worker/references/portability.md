# Portability matrix

Target: **macOS and Linux**, Bash 3.2 or newer. Provider URLs and credentials
stay in each host's OpenCode configuration and the model choice in its
`~/.config/ds-worker/config`, so the same checkout serves hosts that use
different providers.

| Feature | Where | Portability |
| --- | --- | --- |
| Bash >= 3.2 | runtime and installer | indexed arrays only; no Bash 4-only requirement |
| `/dev/tcp` | `bin/ds-serve` TCP checks | bash built-in, **not ksh/dash**; disabled in some hardened builds — if present, `ds-serve` still falls back to `curl` where used |
| `stat` | `lib/process-watchdog.sh` (stream activity) | Darwin uses `stat -f`; Linux uses `stat -c` |
| `mkdir` lock | `bin/ds-serve` | atomic directory creation on both platforms |
| `jq`, `curl`, `git`, `perl`, `opencode` | bin CLIs (`perl` strips comments from `opencode.jsonc`) | hard deps; `install.sh` preflight aborts (or files-only mode without `opencode`) |
| XDG state dir | `DS_STATE_DIR` default in every tool | `${DS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ds-worker}` — honor both layers |

## Optional: OMO Slim (the `omo` role)

`ds-worker omo <agent>` dispatches through OMO Slim's agent list. On hosts
**without** OMO Slim the script does not fail silently:

- `orchestrator` absent → deterministic fallback: the first `mode: primary`
  agent from `opencode debug agents` runs the task; the result JSON carries
  `dispatch: "omo-fallback-primary"` and a stderr note. Model ownership is
  therefore always honest in receipts.
- `council` / `designer` / `fixer` (and any named agent not in the list) →
  the run **refuses** with a message naming the missing agent. Installing the
  full preset is out of scope for this skill; do it on the host if wanted:
  `npx @omoo/workspace init`.
