---
name: cluster-operations
description: GitOps cluster management: PRs only, no kubectl writes.
category: devops
version: 1.0.0
author: Hermit
---

# Cluster Operations — GitOps-Compliant Cluster Management

**Use when:** Making any changes to the Kubernetes cluster, querying cluster state, or operating within the home-cluster environment.

## CRITICAL: Load Context Files First

**Before ANY cluster operation, you MUST read these files:**

1. **SOUL.md** (mounted at `/opt/data/SOUL.md`)
   - File path: `ai-services/hermes-soul-configmap.yaml`
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

## Quick Reference

```bash
/opt/data/.local/bin/kubectl cluster-info
kubectl get <resource> --all-namespaces
```

**Status:** Active — load AGENTS.md and SOUL.md before all cluster operations.
