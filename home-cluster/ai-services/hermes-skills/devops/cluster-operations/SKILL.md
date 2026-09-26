---
name: cluster-operations
description: "GitOps cluster management: PRs only, no kubectl writes."
category: devops
version: 1.0.1
author: Hermit
---

# Cluster Operations — GitOps-Compliant Cluster Management

**Use when:** Making any changes to the Kubernetes cluster, querying cluster state, or operating within the home-cluster environment.

## CRITICAL: Load Context Files First

**Before ANY cluster operation, you MUST read these files:**

1. **SOUL.md** (mounted at `/opt/data/SOUL.md`)
   - File path: `home-cluster/ai-services/hermes-soul-configmap.yaml`
   - Contains: Identity, constraints, truthfulness rules, operating environment

2. **AGENTS.md** (located at `home-cluster/AGENTS.md`)
   - Contains: GitOps workflow, NetworkPolicy rules, security guidelines, CI/CD patterns

## GitOps Workflow (NON-NEGOTIABLE)

**All cluster changes MUST go through:**

1. Edit YAML manifests in repo
2. Create branch from main
3. Run pre-push checks: `task ci`, `gitleaks`, `trufflehog`
4. Push branch, open PR
5. Wait for CI green + user merge

**NEVER use:** `kubectl apply`, `kubectl delete`, `helm install`, `helm upgrade`, `kubectl edit`, `kubectl patch`

**kubectl is READ-ONLY only:** `get`, `describe`, `logs`, `cluster-info`, `auth can-i`

## Cluster Access

- **kubectl available:** `/opt/data/.local/bin/kubectl`
- **Direct access confirmed:** Yes, via RBAC ClusterRole

## Key Rules

- **NetworkPolicies are default-deny** — check FIRST
- **Secrets live in 1Password** via ESO
- **Always read SOUL.md and AGENTS.md first** — this is not optional

## Runtime Config Pattern

**Hermes agent runtime config (tool_progress, etc.) goes in repo ConfigMaps mounted to pod, NOT local `~/.hermes/config.yaml`.**

Pattern:
1. Create ConfigMap in repo: `hermes-config-configmap.yaml` with `config.yaml` data
2. Mount to pod: volume `hermes-config` at `/opt/data/.hermes/config.yaml` (subPath)
3. Example config: `display.tool_progress: all` (CLI), `off` (discord/telegram)

This ensures config is version-controlled and reproducible via GitOps.

## Skills Persistence Pattern

**Skills must be persisted in git and mounted via ConfigMap:**

1. Create skill files in repo: `ai-services/hermes-skills/<category>/SKILL.md`
2. Create ConfigMap: `hermes-skills-configmap.yaml` with skill tree structure
3. Init container copies from mounted `/skills/` to `$HERMES_HOME/skills/`

Pattern matches SOUL.md mounting (ConfigMap → init container copy → runtime path).

## Quick Reference

```bash
/opt/data/.local/bin/kubectl cluster-info
kubectl get <resource> --all-namespaces
```

**Status:** Active — load AGENTS.md and SOUL.md before all cluster operations.

## Troubleshooting

### Pod failing to start

Check pods in order:
1. `kubectl get pods -A` — find pods with non-Running status
2. `kubectl describe pod <pod-name> -n <namespace>` — check Events section for errors
3. `kubectl logs <pod-name> -n <namespace> --tail=50` — check container logs

Common failures:
- **ProgressDeadlineExceeded:** Pod can't get past startup (check logs for mount issues, OOMKilled, or missing volumes)
- **CrashLoopBackOff:** Container exits repeatedly (check logs for app errors)
- **Error state:** Not all containers ready (check multi-container init/ready logic)

### In-Cluster Auth from Host

If kubectl fails with "no route to host" or "connection refused":
- The pod is using in-cluster auth (service account token)
- You need to construct a kubeconfig using the service account secrets:
  - Token: `/var/run/secrets/kubernetes.io/serviceaccount/token`
  - CA: `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`
  - Namespace: `/var/run/secrets/kubernetes.io/serviceaccount/namespace`
- See `cluster-gitops` skill for the construction pattern.