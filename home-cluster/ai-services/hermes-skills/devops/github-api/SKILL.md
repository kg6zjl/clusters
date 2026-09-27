---
name: github-api
description: "GitHub API workflows: PRs, issues, auth patterns."
category: devops
version: 1.0.0
author: Hermit
---

# GitHub API Operations

**Use when:** Creating PRs, checking status, or interacting with GitHub when gh CLI isn't authenticated or available.

## CRITICAL: Token Location

**Token path:** `/etc/hermes/github-token` (root-owned, mounted secret)

**Authentication:** Use `curl -H "Authorization: Bearer <token>"` with the token contents.

## Workflow: PR Creation via API

**When you need to create a PR:**

1. **Commit and push** your branch
2. **Use GitHub API** to create the PR. Put the payload in a JSON file and send it with `-d @file` — never an inline `-d '{...}'` and never a heredoc inside `$(...)`: long bodies with quotes/backticks wedge the command substitution until the tool kills the cell, leaving the POST result UNKNOWN.

```bash
curl -sS -m 25 -X POST -H "Authorization: Bearer $(cat /etc/hermes/github-token)" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/{owner}/{repo}/pulls -d @/opt/data/tmp/pr.json
```

3. **Parse response** for `number` + `html_url` to share with user.

**Idempotent recovery after a hung/timed-out create call** — never blind-rePOST; a GET decides first:
`GET /pulls?state=all&head=<owner>:<branch>` → `[]` means the write never landed and one re-POST is safe; non-empty means the PR already exists (possibly even merged) — link it instead of duplicating.

**Reading CI:** `GET /repos/<o>/<r>/commits/<sha>/check-runs` returns every job's `status`/`conclusion` (incl. `skipped`) even when `actions/runs?head_sha=` lists nothing; each check-run's `annotations_url` separates your lint warnings from pre-existing repo-wide ones.

## Pitfalls where the failure is GitHub's, not yours

**`gh pr edit` dies on a Projects-classic GraphQL error** (`Projects (classic) is being deprecated…`) and leaves the body silently UNCHANGED. Verify with a re-GET rather than assuming. Update the body over REST instead, building the payload from a file so long bodies with quotes/backticks can't wedge the call:

```bash
# 1. payload file: {"body": "<contents of the markdown file>"} via mk_json.py-style helper
# 2. then PATCH
curl -sS -X PATCH -H "Authorization: Bearer $(cat /etc/hermes/github-token)" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/{owner}/{repo}/pulls/{n} -d @/opt/data/tmp/pr_body.json
```

**`gh pr merge` says "N of N required status checks are expected" while `mergeable` is `MERGEABLE`** — read `mergeStateStatus`: `BEHIND` means the base branch moved after the PR opened (often by your own earlier merge) and branch protection wants the head current. The checks themselves are fine; don't chase them. Rebasing would need a force-push, which the approval scanner blocks outright, so let GitHub update the branch instead — no history rewrite, no force-push:

```bash
curl -sS -X PUT -H "Authorization: Bearer $(cat /etc/hermes/github-token)" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/{owner}/{repo}/pulls/{n}/update-branch \
  -d @/opt/data/tmp/update_branch.json      # {"expected_head_sha": "<FULL 40-char sha>"}
```

`expected_head_sha` must be the **full** 40-character SHA — a short one returns `422 expected head sha didn't match current head ref`. Read it from `GET /repos/{o}/{r}/pulls/{n}` → `.head.sha` (truncating it is the easy mistake, since every other command in this skill prints abbreviated SHAs). Afterwards `mergeStateStatus` returns to `CLEAN` and the merge goes through.

**Committing on a stale branch is rejected by the pre-commit hook** (`branch ... does not contain the latest origin/main`). When the branch already has commits, rebase. When it has **none yet** — purely behind — `git merge --ff-only origin/main` fixes it with no history rewrite, and the hook then passes.

## Prefer gh CLI by full path

`gh` is already authenticated in this pod but is not on PATH — call `/opt/data/.local/bin/gh`. `gh pr create`, `gh pr list --state open --json number,title,url`, and `gh pr checks <N>` are single fast commands; use them before reaching for raw curl, and never wait on `gh auth login` prompts or ask the user for credentials.

**Push when the git credential helper is broken** (username prompts / `credential-store!` errors): embed the mounted token in the remote URL for a one-off push and redact it from output:
```bash
git push https://x-access-token:$(cat /etc/hermes/github-token)@github.com/kg6zjl/clusters.git <branch> \
  2>&1 | sed 's/x-access-token:[^@]*@/x-access-token:REDACTED@/g'
```
Use curl + `Authorization: Bearer $(cat /etc/hermes/github-token)` only when gh itself fails.

## Pitfall: Don't pretend to lack cluster access

You have RBAC ClusterRole. Don't ask permission for read-only kubectl commands.
Use direct access for `get/describe/logs/cluster-info/auth can-i`.

## Quick Reference

```bash
# List PRs
curl -s -H "Authorization: Bearer $(cat /etc/hermes/github-token)" \
  "https://api.github.com/repos/kg6zjl/clusters/pulls?state=open"

# Check PR status
curl -s -H "Authorization: Bearer $(cat /etc/hermes/github-token)" \
  "https://api.github.com/repos/kg6zjl/clusters/pulls/545"
```

---

**Status:** Active — use GitHub API when token is mounted.