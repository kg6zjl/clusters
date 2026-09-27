# Hermes Cron Watchdog Pattern (no_agent jobs)

For "run a check daily, only speak up when something is broken" tasks (skills drift, endpoint health, pod status). No LLM turn per tick — the script IS the job.

## Setup

1. Canonical check script lives in the clusters repo (`ai-services/scripts/`), reviewed via PR like any manifest.
2. `cronjob_manage` `script` param accepts ONLY a filename relative to `/opt/data/scripts/` (absolute paths are rejected). Put a thin wrapper there that execs the git version:
   ```bash
   #!/bin/bash
   exec bash /opt/data/workspace/clusters/home-cluster/ai-services/scripts/<check>.sh "$@"
   ```
   Git stays the source of truth; the wrapper is one line of PVC glue.
3. Create the job:
   - `no_agent: true` — stdout delivered verbatim, no model call
   - `deliver: origin` (or explicit `discord:<chat_id>`)
   - `failure_deliver: origin` so engine errors still surface

## The script's output/exit contract (critical)

- **Healthy → print NOTHING.** Empty stdout sends no message — this is the silent watchdog.
- **Drift/broken → print the alert, but EXIT 0.** Non-zero exit is treated as *job failure* and delivers an error alert instead of the message text. Encode state in output, never in exit code.
- Output must be deterministic if you later switch the job to `monitor:` mode (change-detector gates agent runs on identical output) — no timestamps.
- Cap list output (e.g. `head -15` + `... (N total)`) so it fits a Discord message; put the user-facing reminder sentence in the output itself — with no_agent there is no agent to add one.
- `set -euo pipefail` + `head` = SIGPIPE trap (141); guard pipelines feeding capped lists.

## Example in production

`skills-drift-check` (daily 09:00 UTC): diffs `/opt/data/skills/**/SKILL.md` vs `origin/main` `ai-services/hermes-skills/**` by skill-name + sha256 (layout-agnostic during the flat→category migration), reports missing-in-git / missing-from-pod / modified, silent when synced. Cron definitions live in the Hermes job store on the PVC — they survive pod restarts but not PVC loss; recreation is one `cronjob_manage` call.
