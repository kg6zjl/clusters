---
name: kanban-ticket-management
version: 1.0.0
author: Hermit
license: MIT
description: Use when asked for a kanban ticket or to track cluster work.
metadata:
  hermes:
    tags: [kanban, hermes-cli, work-tracking]
    related_skills: [cluster-operations, gitops-cluster-management]
---

# Hermes Kanban Work Tickets

## When to Use

The user asks for a "kanban ticket" (or to track/block/complete cluster work items). This
cluster's durable board is the Hermes kanban SQLite DB (`/opt/data/kanban.db`), **not** GitHub
issues. There is no kanban agent tool — `tool_search` finds nothing; it is CLI-only.

## Commands

```bash
export HOME=/opt/data        # hermes state resolves under $HOME; wrong HOME = wrong/empty board
/opt/hermes/bin/hermes kanban list                 # also: show <id>, comment, block, complete, link
/opt/hermes/bin/hermes kanban create "<Title>" \
  --body-file /opt/data/tmp/<ticket>.md --priority <int>
```

`hermes` is NOT on PATH — always the absolute binary path, always with `HOME=/opt/data` exported.

- Title = outcome, not activity: "Fix X — <why it matters>".
- `--priority` is an INT, smaller = more urgent. Existing board convention: 1 = act now, 2–3 = normal, 0 = backlog. Passing `high` fails.
- Long bodies go through `--body-file` (shell quoting mangles inline bodies with backticks/quotes).

## Ticket body structure (user expects actionable, not narrative)

1. **Impact** — what is broken for whom.
2. **Verified evidence** — the actual commands/output facts you confirmed this session.
3. **Suspects, ranked, explicitly labelled unverified** — with the mechanism for each.
4. **Next actions** — exact copy-pasteable commands, including catch-it-live steps for scheduled jobs whose failed pods were already GC'd.
5. **Cross-links** — related task IDs read from `kanban list` output (never from memory) and PR numbers.

Never put secret values in bodies or comments — the DB is plaintext on a shared pod filesystem.

## Reuse before creating

The user often asks for a ticket that already exists. Search the board first and report the existing ID
instead of filing a duplicate:

```bash
HOME=/opt/data /opt/hermes/bin/hermes kanban list | grep -i <topic>
```

`list` shows state, owner and title for every task, which answers "do we already have one of these?"
directly.

## Assignment, and why most tickets stay unassigned

Assigning a task hands it to the dispatcher, which auto-claims and starts working it — and an assignee
here is a profile, not a person. Therefore:

- Do **not** assign work that needs a human at a console (root on a host, a decision only the user can
  make). Leave it unassigned: unassigned tasks sit `ready` and idle, which is exactly right for work the
  user will do themselves.
- If a human-only task already got claimed, `hermes kanban reclaim <id>` then `hermes kanban block <id>`
  to keep it out of the work queue, and say in the body that it is human-only.
- "Assign it to me" means the user owns it: record that in the body rather than inventing an assignee
  (there is usually no human account on the board to point at).

## Pitfalls

- Before creating a ticket for a request, `git log --oneline origin/main -15` — parallel sessions merge fixes constantly here, and half the work may already have shipped (write "done, do not redo" into the body instead of a stale action item).
- `kanban create` rejects unknown flag values hard (e.g. priority) and prints full usage; read the error, don't retry variants blindly.
- State plainly which parts of a body you verified with commands this session and which are unverified
  inferences, or the next reader treats a guess as established fact.
- When a later test contradicts a claim already written into a ticket, **comment the correction onto
  that ticket**. The board is the durable record a future session reads; a wrong cause left standing
  gets repeated as if it were still true.
- `hermes kanban complete <id>` **refuses an empty completion** (`completion blocked: ... has no result or summary evidence`). Pass `--result "<what was verified>"` — put the measurable facts in it (what changed, what the probe/endpoint list showed afterwards), not "done". That gate is the point: a closure with no evidence is not a record.
- Retiring your own duplicate is a different act from closing the work: complete the duplicate with a `--result` naming the canonical ticket, and put the evidence as a comment on the canonical one.
- Notify wiring is per-task: `hermes kanban notify-subscribe` binds a task to a chat — offer it when the user wants status pings.
