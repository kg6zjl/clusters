---
name: git-auth-without-gh
description: Git operations without GitHub CLI credential setup
category: software-development
version: 1.0.0
author: Hermit
---

# Git Auth Without GitHub CLI

**Use when:** You need to perform git operations (push, pull, PRs) but `gh auth setup-git` is blocked or unavailable.

## Problem

`gh auth setup-git` fails with:
- `Device or resource busy` on `/opt/data/.gitconfig`
- Token file inaccessible via `gh` CLI credential helper
- GitHub PAT stored in ESO (not directly accessible)

## Solution

Use **REST API with token env var** or **git credential store** instead of `gh` CLI.

### Option 1: REST API with Bearer Token

```bash
# Read token from env var (from ESO)
TOKEN=$GITHUB_TOKEN

# Make API call
curl -s -X GET "https://api.github.com/repos/kg6zjl/clusters/pulls"   -H "Authorization: Bearer $TOKEN"   -H "Accept: application/vnd.github.v3+json"
```

**Advantages:**
- No git config changes needed
- Works with ESO-injected tokens
- Bypasses credential helper issues

### Option 2: Git Credential Store

```bash
# Configure git to use credential store
git config --global credential.helper store

# Git will prompt for credentials once, then cache them
git push origin main
```

**Advantages:**
- Works with existing git workflows
- No API calls needed for clone/push

### Option 3: Use the mounted credential helper (already configured)

This repo's Hermes mounts a git credential helper at `/opt/data/git-credential-helper`
and points `credential."https://github.com".helper` at it in `/opt/data/.gitconfig`.
Plain `git push` works with no extra setup:

```bash
git push origin main
```

Avoid persisting tokens to files or injecting them via `GIT_ASKPASS` (a program
path, not `echo` output) — copy/paste of that pattern has broken pushes before.
The token stays in `$GITHUB_TOKEN` from ESO.

## Pre-commit Checklist

Before pushing to the cluster repo:

1. **Pull main first**
   ```bash
   git fetch origin
   git checkout main
   git pull origin main --ff-only
   git checkout -b <new-branch>
   ```

2. **Check for secrets**
   ```bash
   grep -rE "password|secret|token|key|auth|credential" --include="*.yaml" . | grep -v "secretKeyRef" | grep -v "^#"
   ```

3. **Run CI checks**
   ```bash
   task ci
   gitleaks --source . --report-path /tmp/gitleaks.json
   trufflehog /opt/data/workspace/clusters/home-cluster/
   ```

4. **Verify your branch contains current main** (a REST API push skips the
   local pre-push staleness hook, so check ancestry explicitly before creating
   the PR):
   ```bash
   git fetch origin
   git merge-base --is-ancestor origin/main HEAD && echo "fresh" || \
     { echo "STALE — rebase onto origin/main first"; exit 1; }
   ```

5. **Push to branch**
   ```bash
   git push origin <new-branch>
   ```

6. **Create PR via API**
   ```bash
   curl -s -X POST "https://api.github.com/repos/kg6zjl/clusters/pulls"      -H "Authorization: Bearer $GITHUB_TOKEN"      -H "Accept: application/vnd.github.v3+json"      -d '{
       "title": "feat: add <description>",
       "body": "Fixes issue...",
       "head": "<branch-name>",
       "base": "main"
     }'
   ```

## Cluster GitOps Workflow

**Non-negotiable:**
1. Edit YAML manifests
2. Create branch from main
3. Run pre-push checks: `task ci`, `gitleaks`, `trufflehog`
4. Push branch, open PR
5. Wait for CI green + user merge

**NEVER:**
- `kubectl apply`, `kubectl delete`, `helm install`, `helm upgrade`
- Commit secrets to git
- Force-push to main

## Environment Variables

```bash
# From ESO (1Password)
GITHUB_TOKEN    # GitHub PAT, injected via ESO
REGISTRY_USER   # Docker registry username
REGISTRY_PASS   # Docker registry password
```

## Quick Reference

```bash
# Check PR status
curl -s "https://api.github.com/repos/kg6zjl/clusters/pulls/547"   -H "Authorization: Bearer $GITHUB_TOKEN"   | jq '.state, .title, .mergeable'

# Create PR via API
curl -s -X POST "https://api.github.com/repos/kg6zjl/clusters/pulls"   -H "Authorization: Bearer $GITHUB_TOKEN"   -H "Accept: application/vnd.github.v3+json"   -d '{
    "title": "feat: add skills ConfigMap",
    "body": "Add hermes-skills ConfigMap and mount",
    "head": "feat/add-skills",
    "base": "main"
  }'
```

**Status:** Active — use REST API when `gh auth setup-git` fails.
