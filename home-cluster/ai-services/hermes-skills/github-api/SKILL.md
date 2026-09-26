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
2. **Use GitHub API** to create PR (faster than gh CLI when token is mounted):

```bash
curl -s -H "Authorization: Bearer $(cat /etc/hermes/github-token)" \
  -X POST \
  -d '{"title": "...", "body": "...", "head": "owner:branch", "base": "base-branch"}' \
  "https://api.github.com/repos/{owner}/{repo}/pulls"
```

3. **Parse response** for `html_url` to share with user

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