---
name: gitops-cluster-management
description: "GitOps cluster management: PRs only, no kubectl writes."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [gitops, flux, clusters, helm, kubectl, git, pr-workflow]
    category: devops
---

# GitOps Cluster Management

**Use when:** Managing Kubernetes clusters via GitOps (Flux CD).

Manage Kubernetes clusters via GitOps (Flux CD) only. All cluster changes must be PRs on the GitOps repo. NEVER use `kubectl apply` or `kubectl edit` directly.

## Workflow (ALWAYS follow this order)

1. **Read SOUL.md first** — `/opt/data/SOUL.md` (hermes-agent pod) or `/opt/data/workspace/clusters/home-cluster/ai-services/hermes-soul-configmap.yaml`. Defines agent identity, constraints, and persona.

2. **Read AGENTS.md first** — `/opt/data/workspace/clusters/home-cluster/AGENTS.md`. Defines GitOps workflow, branch strategy, and safety gates.

3. **Sync main** — `git fetch origin && git checkout -B main origin/main`. Local `main` routinely accumulates junk commits and diverges, so a plain `git pull` dies with "Not possible to fast-forward"; `-B` hard-resets it onto the remote. Your branch must start from current `origin/main` every single time.

4. **Create feature branch** — `git checkout -b feat/<short-description>` from the freshly synced main.

5. **Modify manifests** — Edit YAML files in the GitOps repo. NEVER edit cluster resources directly.

6. **Run pre-commit checks** — `python3 -m yamllint -c yamllint.yaml <changed files>` (or full `task ci`) plus gitleaks. Lint every file you generated: hand-written ConfigMap YAML routinely lands block-scalar syntax errors (`key.md: |data:`) and duplicated sections, and CI stalls on it.

7. **Stage & commit** — `git add -A`, `git commit -m "<conventional commit>"`.

8. **Push to origin** — `git push origin feat/<short-description>`. If the credential helper misbehaves (`'credential-store!' is not a git command`, username prompts), push with the token embedded from the mounted secret instead of debugging the helper: `git push https://x-access-token:$(cat /etc/hermes/github-token)@github.com/kg6zjl/clusters.git <branch>` — pipe output through `sed 's/x-access-token:[^@]*@/x-access-token:REDACTED@/g'` so the token never lands in output or logs.

9. **Create PR** — `gh` is not on PATH; use `/opt/data/.local/bin/gh pr create --title "<feat: ...>" --head feat/<branch> --base main`.

10. **Wait for CI** — Flux CI runs: manifests validation, secret scanning, Helm linting.

11. **Sr Principal review** — PR must be reviewed before merge. See SOUL.md for gatekeeping workflow.

12. **Merge** — User merges after Sr Principal review. NEVER merge your own changes.

## Hard Invariants

- **NEVER run `kubectl apply`** — Flux owns the cluster.
- **NEVER run `kubectl edit`** — Flux reconciliation will overwrite.
- **NEVER merge without Sr Principal review** — SOUL.md workflow.
- **ALWAYS pull main before starting work**.
- **ALWAYS use feature branches**.
- **ALWAYS run pre-commit checks**.
- **NEVER include secrets in manifests** — All secrets live in 1Password via ESO. This includes Discord webhook URLs: they count as PII and must never appear in git, ConfigMaps, or CronJob specs — reference the 1Password item and leave the wiring commented.
- **NEVER modify your own deployment configs** — hermes-agent.yaml, hermes-gitconfig.yaml require approval first.

## Tools

- `kubectl` (read-only): `get`, `list`, `describe` only.
- `gh` CLI: PR creation, issue management.
- `curl` + GitHub API: REST API calls when `gh` CLI cannot access token.
- `kubectl kustomize`: Validate manifests locally.

## Verification

- After each change, verify with `kubectl get <resource> -n <namespace>` (read-only only).
- Confirm PR status: `gh pr view <N> --web`.
- Check CI status: `gh pr checks <N>`.
- Verify Flux reconciliation: `kubectl get flux -n <namespace> -o yaml`.

## Pitfalls

- **Context compression** — Long tool call outputs may be truncated. Read file contents with `read_file` or `terminal` for full context.
- **Git credential helper** — The pod's git config carries a broken helper entry so pushes prompt for credentials, and `gh auth setup-git` fails because `/opt/data/.gitconfig` is a busy mounted file. Don't burn time repairing it — use the embedded-token push from step 8. `gh` itself works fine when called by full path.
- **NetworkPolicies** — Default-deny cluster. If something can't reach the API server, suspect NetworkPolicy first.
- **ConfigMap mounting** — User configuration (e.g., `tool_progress`) must be mounted via ConfigMap from the repo, not local paths.
- **Self-modification** — I cannot self-recover from breaking my own deployment tools. Changes to my own git config/credential helpers require explicit approval first.
- **Status questions need ONE command** — "list open PRs" / "any failing pods?" must come back in seconds from a single `gh pr list --state open --json number,title,url` or `kubectl get pods -A`, not file-exploration loops or API spelunking; the user calls out slow answers on trivial queries.
- **When the user is mid-operation, reply before verifying.** If they are at a host console or on a phone and ask "what are the steps", the reply leads with the exact copy-pasteable commands plus the output to look for, and the verification happens after that lands (the paste-back is your evidence). Chaining several silent tool calls first reads as being ignored. Same in reverse: ask for the one read-only command you cannot run from inside the pod, and label the conclusion unverified until they paste its output.
- **Adding a manifest file is two edits, and the render check has a right root.** Every component directory (`home-cluster/<dir>`) is wired by an explicit `resources:` list in its own `kustomization.yaml`, synced per component (`flux-system/syncs/<dir>-kustomization.yaml`, `path: ./home-cluster/<dir>`). A new file that is not added to that list is never applied, and `kubectl kustomize` on the repo root renders nothing for it — validate with `kubectl kustomize home-cluster/<dir>` and confirm the new object (name, new fields) appears in the output before pushing. Check for the same trap when *removing* a file: the entry has to go too, or Flux reconciles a missing path.
- **No ad-hoc pods, ever.** `kubectl run`, `kubectl create job --from=cronjob/...` and "just exec into something" are not available and would be drift anyway. When a task needs a pod to do work — copying a volume, probing a network path, running a one-off migration — write it as a `Job` (or a temporary `Deployment`) in the PR, let Flux apply it, and delete the manifest in the follow-up PR. Say in the PR body who triggers it and what to look for, since the user may be the one who has to run it from the UI.
- **Rollout annotations** — a change under `spec.template.metadata.annotations` (e.g. `rollout.restartedAt`) restarts the pod when Flux merges it. State the restart impact in the PR body.


