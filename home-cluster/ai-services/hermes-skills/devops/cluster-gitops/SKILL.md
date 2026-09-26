---
name: cluster-gitops
description: "GitOps cluster management: PRs only, no kubectl writes."
category: devops
version: 1.0.0
author: Hermit
---

# Cluster GitOps Workflow

All cluster changes MUST go through the Pull Request workflow. Direct kubectl writes are forbidden — your ClusterRole is read-only, and Flux owns the cluster.

## Core Principles

1. **GitOps is the source of truth** — all changes go through PRs on the kg6zjl/clusters repo
2. **Never kubectl apply** — your ClusterRole has NO write verbs. Flux owns the cluster. Any drift is reverted.
3. **NetworkPolicy-first** — default-deny cluster. If something doesn't work, check egress/ingress first.
4. **Security** — secrets live in 1Password via ESO. Never in Git, ConfigMaps, or plain env vars.

## Workflow

1. **Clone/checkout** the repo
   ```bash
   git clone https://github.com/kg6zjl/clusters.git
   cd clusters/home-cluster
   ```

2. **Pull main** before starting work
   ```bash
   git fetch origin && git pull origin main --ff-only
   ```
   **Pitfall:** Never start work without pulling main. Your branch must be rebased off main every single time.

3. **Create branch** from main
   ```bash
   git checkout -b <feature-name>
   ```

4. **Modify manifests** (deployment.yaml, kustomization.yaml, etc.)
   - Use `patch` for targeted edits
   - Use `write_file` for new files
   - Always `read_file` before editing existing files

5. **Run CI checks:**
   ```bash
   task ci                      # yamllint + kubectl kustomize
   gitleaks detect --source . --config .gitleaks.toml --no-banner
   trufflehog filesystem . result
   ```
   **Pitfall:** Fix findings BEFORE pushing.

6. **Push** to remote
   ```bash
   git push origin <feature-name>
   ```

7. **Create PR** with PR template
   ```bash
   gh pr create --title "<feature>" --body "<description>"
   ```
   **Pitfall:** If PR already exists, check first. Do not create duplicates.

8. **Wait for CI + review** — merge only when green

## Pre-commit Safety

Pre-commit hooks should check:
- Branch/rebase status before commit
- CI checks (task ci, gitleaks, trufflehog)

## Common Pitfalls

- ❌ `kubectl apply` — your ClusterRole has NO write verbs
- ❌ Committing secrets — use ESO from 1Password only
- ❌ Ignoring NetworkPolicy — default-deny blocks everything without explicit rules
- ❌ kubectl snowflakes — any drift is reverted by Flux
- ❌ Creating duplicate PRs — check existing PRs before creating new ones
- ❌ Modifying own deployment tools without approval — I cannot self-recover
- ❌ Force-pushing main branch — main is protected, requires PR workflow
- ❌ Cherry-pick conflicts — resolve merge conflicts in SOUL.md before continuing (keep HEAD version unless instructed otherwise)
- ❌ Git credential-store helper failures — if `gh auth setup-git` fails with "Device or resource busy", use token-based API instead
- ❌ Ignoring protected branch rules — main requires PR, no merge commits, 3 status checks required

## GitOps Enforcement

- **Always pull main** before starting work — rebase your branch off main every single time
- **Prefer what's on main** — use main as authoritative base for conflict resolution
- **Protected branches** — main cannot be force-pushed, requires PR with all CI checks passing (no merge commits, 3 status checks required)
- **Credential issues** — if `gh auth setup-git` fails with "Device or resource busy", use token-based API calls instead
- **ConfigMap mounts** — runtime config (e.g., tool_progress) goes in repo ConfigMaps mounted to pod, NOT in local `~/.hermes/config.yaml`
  - Pattern: `hermes-config` ConfigMap with `config.yaml` → mount to `/opt/data/.hermes/config.yaml`
  - Example: `display.tool_progress: all` for CLI platforms, `off` for discord/telegram

## Tools

- `kubectl` — read-only: get, describe, logs, events
- `gh` — PRs, issues, repo management
- `task ci` — pre-push validation
- `gitleaks` / `trufflehog` — secret scanning

## References

- SOUL.md: Defines agent persona and constraints
- AGENTS.md: GitOps workflow definition
- README.md: Cluster documentation

## Configuration

### Hermes Agent Config Mounts

All runtime config goes in repo ConfigMaps mounted to pod, NOT local `~/.hermes/config.yaml`.

**hermes-config ConfigMap:**
- Mount to `/opt/data/.hermes/config.yaml`
- Contains: `display.tool_progress` (all for CLI, off for discord/telegram)
- Pattern: `subPath: config.yaml` to expose just the file

**hermes-skills ConfigMap:**
- Mount to `/skills` or `$HERMES_HOME/skills/`
- Contains: Skill tree directory structure
- Pattern: Init container copies from git to mount path

### SR Principal Review Gate

**Before creating ANY PR, you must:**
1. Show the complete PR to Sr Principal for review
2. Wait for explicit approval
3. You are the gatekeeper — no PR goes out without this review

**Workflow:** Research → Implement → Sr Principal Review → User Review → PR

### Skills Verification

After merging skills ConfigMap PRs, verify:
1. ConfigMap exists: `kubectl get configmap hermes-skills -n ai-services`
2. Deployment has mount: `kubectl describe deployment hermes-agent -n ai-services`
3. Pod restarted: `kubectl get pods -n ai-services | grep hermes-agent`
4. Skills accessible: Check pod logs or exec into pod

### Git Credential Helper Fallbacks

If `gh auth setup-git` fails:
- Error: "Device or resource busy" → Use token-based API calls
- Error: Token path inaccessible → Use curl with `Authorization: Bearer {token}` header
- Error: gh CLI auth fails → Use `git push` with credential helper `helper=store`

**Token path:** `/etc/hermes/github-token` (ESO-managed from 1Password)

### In-Cluster Kubectl from Host

When running kubectl from the host but the pod uses in-cluster auth (service account token):

1. **Read service account secrets:**
   - Token: `/var/run/secrets/kubernetes.io/serviceaccount/token`
   - CA: `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`
   - Namespace: `/var/run/secrets/kubernetes.io/serviceaccount/namespace`

2. **Construct kubeconfig:**
   ```python
   import base64
   with open(token_path) as f: token = f.read().strip()
   with open(namespace_path) as f: namespace = f.read().strip()
   with open(ca_path, 'rb') as f: ca_b64 = base64.b64encode(f.read()).decode()
   
   kubeconfig = f"""apiVersion: v1
   clusters:
   - cluster:
       certificate-authority-data: {ca_b64}
       server: https://kubernetes.default.svc
     name: default
   contexts:
   - context:
       cluster: default
       user: default
     name: default
   current-context: default
   kind: Config
   users:
   - name: default
     user:
       token: {token}
   """
   with open("/tmp/kubeconfig", "w") as f: f.write(kubeconfig)
   ```

3. **Use with kubectl:** `kubectl get pods -A --kubeconfig /tmp/kubeconfig`

**Pitfall:** In-cluster auth only works inside pods. The host needs a constructed kubeconfig with the service account token.

---
**Hard invariant:** I will remain dead until a human revives me after a self-breaking deployment change.
