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

2. **Sync main** before starting work — and re-sync right before pushing
   ```bash
   git fetch origin
   git rev-parse HEAD origin/main     # the two shas must diverge only by your own commits
   ```
   **Pitfall:** Never start work from a cached checkout. A stale tree is how a branch silently
   carries someone else's commits, and how you end up asserting "that is not in git" about
   something that IS on main. Re-sync and re-read before making any claim about main.

3. **Create the branch with an explicit base — never from whatever you happen to be standing on**
   ```bash
   git checkout -B <feature-name> origin/main
   ```
   **Pitfall:** `git checkout -b <name>` inherits the CURRENT branch as its base. Do that while
   you are on another feature branch and your PR drags that branch's commits (and unrelated files)
   into its diff. Always name the base. One branch = one concern = one PR.

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

6. **Push** to remote, then re-verify the base
   ```bash
   git push https://x-access-token:$(cat /etc/hermes/github-token)@github.com/kg6zjl/clusters.git <feature-name>
   git fetch origin && git rev-parse HEAD origin/main
   ```
   **Pitfall:** Rebase onto `origin/main` if it moved while you were working.

   **Rewriting your own UNMERGED branch is legitimate** when it was cut from the wrong base — do it
   with an explicit lease, never a bare `-f`:
   ```bash
   SHA=$(git ls-remote origin <branch> | cut -f1)
   git push --force-with-lease=<branch>:$SHA <remote-url> <branch>
   ```
   Plain `--force-with-lease` can fail with `stale info` even when nothing moved remotely: pushing
   via an explicit URL never creates the local remote-tracking ref the lease compares against, so
   it has nothing to check. Pass the sha from `ls-remote` explicitly. Tell the user a branch was
   rewritten and why — it is a fact they need, not something to bury.

   **Never push to a branch that was already merged** — its remote ref is usually deleted. Cut a
   fresh branch off `origin/main` and `git cherry-pick <sha>` the commit over.

7. **Create the PR** with the PR template
   ```bash
   gh pr create --title "<feature>" --body "<description>"
   ```
   **Pitfall:** If a PR already exists for this branch, check first — do not create duplicates. If
   `gh` is unreliable for edits (it has silently no-op'd), retitle/rewrite the body through the REST
   API (`PATCH /repos/<owner>/<repo>/pulls/<n>`) and read it back.

8. **Read the PR back before calling it done**
   ```bash
   gh pr view <n> --json files --jq '.files[].path'
   # or GET /repos/<owner>/<repo>/pulls/<n>/files
   ```
   **Pitfall:** The file list is the only reliable check that the branch base was right and that no
   unrelated change rode along. Verify it, and verify the required-check conclusions for the exact head
   sha, before reporting the PR as ready.

9. **Wait for CI + review** — merge only when green. Only merge on explicit user instruction; the
   user is the gatekeeper.

   **Pitfall:** Which workflow version runs your check is not necessarily the one you are adding.
   A PR that changes the CI workflow is still gated by main's workflow, so a newly added gate proves
   nothing until it is merged. Say that out loud instead of implying the new gate just passed.

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
- ❌ `git checkout -b` while standing on another feature branch — it inherits that branch as its base; use `git checkout -B <name> origin/main`
- ❌ Force-pushing a branch that was merged or deleted — its ref is gone; cut a fresh branch off main and cherry-pick
- ❌ Claiming a file/route/rule "is not in git" from a stale worktree — `git fetch` and read it out of `origin/main` first
- ❌ Reporting a count or result from a command whose stderr you discarded — `... 2>/dev/null | wc -l` converts a transient API failure into a confident `0`. Check exit status and stderr; retry before reporting a number
- ❌ Assuming a documented procedure still exists — verify it against live state before relying on it in a recovery plan (AGENTS.md has described backup CronJobs and runner tools that were not actually deployed; `kubectl get cronjob -A` is the check)
- ❌ Treating PVC-resident state (kanban.db, cron store) as protected — it survives pod reloads but is not in git and may have no backup at all
- ❌ Assuming a green check means the thing works — a required check that has never been observed failing is not a gate (see `references/ci-pipeline.md`)
- ❌ Treating an installed CSI driver as available storage, or a probe from a NetworkPolicy-blocked pod as evidence about the remote target (see `references/storage-and-pvcs.md`)
- ❌ Reading a "gateway shutdown/restore" notice as a crash — in this setup it is normally Flux rolling my OWN pod (the ConfigMap reloader annotation). Check pod age and the Kustomization's `lastAppliedRevision` and report it as a deployment, not a failure
- ❌ Shipping a Helm value you did not verify exists in that chart — **unknown keys are silently ignored**, so an unverified value list means the intent (default class, replica count, node exclusion) may never have been applied. Pin the version from the live repo index, download the chart tarball, and read its `values.yaml`/templates before writing the HelmRelease
- ❌ Validating a component change with `kubectl kustomize home-cluster` alone — the top-level build here does **not** include the per-namespace components (Flux syncs are per-component under `flux-system/syncs/`), so the changed rule is simply absent from that output. Validate the component path (`kubectl kustomize home-cluster/<namespace>`) and confirm which Flux Kustomization owns it; an empty grep from the wrong build root looks like a missing change
- ❌ Treating a newly installed component's CRDs as unreadable — expanding the read-only ClusterRole (`get`/`list`/`watch` for a new API group) is pre-authorized when a component is added; open the PR without asking. Do **not** self-merge it: approving my own permissions is the user's gate, not mine
- ❌ Trusting a delegated subagent's summary as evidence — a child's report is a self-report. Read the PR's file list and diff from the branch, and re-derive its factual claims (chart versions, value keys, command output) from the upstream artifact yourself before repeating them to the user
- ❌ Treating a failed Helm install as harmless — Flux's install remediation runs the chart's `helm uninstall`, and when the chart ships its CRDs as templates (not in a `crds/` directory) that **deletes the CRDs** and every CR of that group, then leaves the release stuck in `uninstalling` (`Ready=False reason=StateError`). Give any chart whose first install pulls large images an explicit `install.timeout`, and check `kubectl get crd | grep <group>` after any partial uninstall (see `references/helmrelease-recovery.md`)
- ❌ Reading a HelmRelease's `Ready` condition as the diagnosis — Helm's actual error (the resource it timed out waiting for) is in the `Released`/`Remediated` conditions and in the namespace events' `Last Helm logs:` block. A component crash-looping at the same time is often that failure's symptom, not its own bug, so read both before proposing a fix to either
- ❌ Blaming a component for intermittent failures before testing the API path — probe each apiserver endpoint directly (`kubectl --server=https://<node-ip>:16443`) with the **exact failing call**, not just a liveness check. One dead or divergent endpoint in the ClusterIP round-robin makes a fraction of *all* in-cluster calls fail, and a one-shot process (Helm install, CSI driver deployer, migration job) that exits fatally on its first error can never survive it — survival is `(1-p)^N`. Proposing a retry or a longer timeout for that is not a fix (see `references/api-endpoint-flakiness.md`)
- ❌ Trusting the legacy `default/kubernetes` Endpoints object as the API address set — it carries `endpointslice.kubernetes.io/skip-mirror` and is frequently stale. Read the **EndpointSlice**, and expect a *live* apiserver that advertises a dead address to republish it seconds after you delete the entry; the fix is the node's advertised address, not the object
- ❌ Asserting a cause without running the confirming test — state a suspected cause as a prediction with the check that settles it, run that check, and when it contradicts the claim, retract it *where the claim was already written* (a PR body, a ticket comment) rather than only in chat. A wrong causal claim left standing gets acted on

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

## Delegating PR Work to Subagents

Users ask for this ("spin up a couple of agents"). A subagent knows nothing of the session, so the
brief must carry every repo convention or the resulting PR is unusable:

1. Repo clone path, plus the hard rule: `git fetch origin` and branch from `origin/main`, one branch
   = one concern, never push to main, no bare force-push.
2. Push auth: the token file path and that `gh` cannot read it — push with the embedded-token URL,
   create/update PRs through the REST API.
3. Validation commands to actually run (`yamllint -c home-cluster/yamllint.yaml`, `kubectl kustomize
   home-cluster/<component>`) and the requirement to report exit status, not just a claim.
4. Constraints: kubectl read-only, no secrets in git (ESO only), never touch the existing manifests
   outside the stated scope, and the exact file paths it may create or change.
5. Deliverable shape: PR URL, file list, verification output, and an explicit caveats field — the
   caveats are where the subagent surfaces a decision it had to make for you (e.g. a selector it could
   not express as instructed).

Then verify as parent: read the PR's file list and diff, and re-derive any factual claim it made
(chart version, value keys, cluster facts) from the source yourself. Children also must not be asked to
apply anything to the cluster — they inherit read-only RBAC and the GitOps model.

## Filing Tickets for Work You Are Not Doing Now

When the user asks for "a ticket" for an ops/security finding, file it on the Hermes kanban — do not
invent a tracker or bury it in chat:

```bash
hermes kanban list                     # check the board first (board: default)
hermes kanban create "<title>" --body-file /path/body.md --created-by hermit
hermes kanban show <task-id>           # read it back to confirm the body landed
```

- The `kanban_*` *tools* exist only for dispatcher-spawned workers; from a normal session use the CLI
  (or `/kanban` in chat). Absence of the tools does not mean the board is unavailable.
- Write the body to a file and pass `--body-file` — multiline bodies with flag-like lines survive shell
  quoting that way.
- The body carries the **evidence and the decision the user must make**, not a restatement of the
  symptom: what was verified, what was not, the options with a recommendation, and any security caveat.
- Board state lives in `kanban.db` on the pod PVC — it survives reloads but is **not** in git and has no
  backup. Treat it as durable-but-unprotected.

### Handing work to the human (things no agent can execute)

- Assignment is **profile-scoped**: `hermes kanban assign <id> <profile>` takes a profile name, not a
  person. The board has no human identity, so write the owner into the body (`**Owner: <name>**`) rather
  than implying the assignee field means a person.
- Assigning a `ready` task gets it **auto-claimed by the live dispatcher** within seconds (status goes
  `running`). For work only a human can do — anything needing root on a node, or a write this cluster's
  RBAC forbids — create it, then immediately `hermes kanban reclaim <id>` and
  `hermes kanban block <id> "<why a human must do it>"` so no worker gets spawned to flail at it.
- Handoff shape: the commands **in order**, the expected output for each verification step, the safety
  note (what restarts, what survives), and why it matters. If the first command is a read that decides
  the rest of the fix, say so and ask for its output before anything else changes.
- The user often works from a phone through Headlamp and cannot run kubectl: give the UI click-path
  (e.g. *Network → Endpoints → `<ns>` → `<name>` → Edit*) and, where a trigger is needed, a git-side
  change that produces it (the annotation bump above) instead of a CLI-only instruction.

## References

- SOUL.md: Defines agent persona and constraints
- AGENTS.md: GitOps workflow definition
- README.md: Cluster documentation
- `references/ci-pipeline.md` — what CI really does here: required checks, self-hosted runner tool wiring, how a check ends up green while gating nothing, runner autoscaling
- `references/storage-and-pvcs.md` — storage inventory, driver-vs-StorageClass, measuring node capacity, replicated-block vs NAS choice, PVC relocation procedure (ownership check, helper pod, capacity multiplier, acceptance test), sizing a cache/DB volume from the upstream artifact, and orphaned PVs
- `references/alertmanager-config-in-git.md` — where the monitoring config actually lives (git, via an ESO template), alert quality, and verifying a merged config change is live
- `references/hermes-config-changes.md`, `references/cron-watchdog-pattern.md` — config-change and cron depth
- `references/helmrelease-recovery.md` — a failed Helm install: where Helm's real error is hidden, why a failed install can delete CRDs, and the exact recovery order
- `references/api-endpoint-flakiness.md` — intermittent API failures in a multi-apiserver cluster: per-endpoint isolation probes, where the authoritative address list (EndpointSlice + apiserver leases) lives, the divergent-apiserver signature, and why one bad endpoint stops a one-shot install
- An object in the cluster holding wrong or stale contents, or a permanently-firing "X is
  unreachable" alert: use the `kubernetes-object-ownership` skill (who writes it, is it reconciled,
  fix the input rather than the object, prove the impact before proposing the fix)

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
