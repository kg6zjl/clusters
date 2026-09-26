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