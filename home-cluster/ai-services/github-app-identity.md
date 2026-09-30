# The agent's own GitHub identity

> **Status: landed.** Phase 1 proved the App path against the real API before anything depended
> on it: a verification CronJob minted an installation token from the Secret ESO syncs, then
> created and deleted a ref on each of `kg6zjl/clusters` and `kg6zjl/skills` — a real write, and
> not the `permissions` object in `GET /repos/{owner}/{repo}`, which reports `push=false
> pull=false` for an installation token regardless of its rights. Phase 2 switched the
> Deployment to the minted token, removed the PAT, and added `CODEOWNERS`.
>
> Two things worth knowing. The App's permission set is wider than the minimum described below:
> it holds read on roughly thirty scopes (webhooks, Actions variables, branch protection,
> registry, security alerts) because that capability is wanted, plus `pages: write`, knowingly
> beyond the original design. And merging, per GitHub's docs for "Merge a pull request", requires
> `Contents: write` — not `Pull requests: write` — so contents write must stay.

**Decision.** The Hermes agent authenticates to GitHub as a **GitHub App owned by @kg6zjl**,
installed on `kg6zjl/clusters` and `kg6zjl/skills` only. The owner's personal access token is
no longer mounted into the pod. Because the agent is now a distinct identity, the branch
protection and `CODEOWNERS` rules the owner sets are what gate changes to the agent's own
access -- the agent cannot approve or merge its own PRs, and the App is not an administrator,
so it cannot relax its own guardrails.

## Why, in one paragraph

`gh pr view 815` returned `mergedBy: {login: kg6zjl}`. The agent merged a PR as the owner.
That is not a bug in the agent; it is the consequence of sharing one credential. With one
identity, "require review by a human", `CODEOWNERS` and "no agent merges" are unenforceable,
because the reviewer and the author are the same account. A separate App makes the agent's
actions attributable and its authority bounded, and it is the only way the owner can be the
*code owner of the agent's access* rather than merely the operator of it.

## Shape

- **App permissions (least privilege):** Metadata: read (automatic), Contents: read & write
  (branches/commits), Pull requests: read & write (open/update/close PRs). Nothing else --
  no Administration, no Actions, no Workflows, no Org permissions. With no Administration the
  App cannot alter branch protection or `CODEOWNERS`; with no Workflows it cannot push commits
  that modify `.github/workflows/**` (see *Known limits* below).
- **Credential at rest:** the App private key + `app-id` + `installation-id` live in the
  `hermes-agent-github-app` item in the 1Password `home-cluster` vault. `ExternalSecret
  hermes-github-app` syncs them into a Secret; the key is mounted only into the minter
  containers (init + sidecar), never into the agent container.
- **Credential in flight:** a ConfigMap script (`hermes-github-token-minter`) mints a ~1h
  installation token and writes it to `/etc/hermes/github-token` in a shared `emptyDir`. The
  agent's existing tools (`gh.sh`, the git credential helper, `github-api`'s `open_pr.py`,
  raw `curl`) already read that path fresh on every call, so **no consumer changes**.
- **Refresh:** a `github-token-minter` sidecar re-mints at expiry minus 300s. A failed mint
  keeps serving the previous file and logs, rather than deleting a working credential.

Why a sidecar rather than a CronJob that writes a Secret: the file lives in an `emptyDir`
shared between two containers in one pod, so there is no cross-namespace Secret write, no
`serviceaccounts/token` RBAC, and no hourly Secret-refresh problem (a `subPath` mount of a
Secret does not refresh, which is exactly how a rotated token would silently go stale).
The sidecar's other property is the one that matters for security: **the durable private key
is never in the agent container's filesystem.** A compromise of the model-driven container
yields an installation token that expires within the hour, not a key that can mint new ones.

The minter uses only the Python standard library (RS256 is implemented in ~25 lines) so the
container is a plain `python:3.13-alpine` with no `pip install` and no dependency on an
`openssl` binary. The signature was verified against OpenSSL before shipping.

## Is declarative GitHub config a Crossplane use case here?

Yes for some of it, but not the parts this change needs -- and deliberately not for this
ticket. Evidence, from the installed provider (`provider-upjet-github:v0.20.0`, `INSTALLED
True / HEALTHY True`, 40 `*.github.m.upbound.io` CRDs present):

| Declarative? | Object | CRD |
| --- | --- | --- |
| **Yes** | Branch protection | `branchprotections.repo.github.m.upbound.io` (and `...v3s`) |
| **Yes** | Repo rulesets | `repositoryrulesets.repo.github.m.upbound.io` |
| **Yes** | Repo settings | `repositories.repo.github.m.upbound.io` |
| **Yes** | Actions secrets/variables, collaborators | `actionssecrets/actionsvariables`, `repositorycollaborators` |
| **No** | **App permissions** | no App resource exists; an App's permissions are changed by authenticating *as the App* (`PATCH /app`), which a repo-scoped provider credential cannot do |

So the honest answer is: Crossplane **can** declare branch protection, rulesets and repo
settings -- the CRDs are installed and reconciled today for the two `RepositoryWebhook`s in
`crossplane-system` -- but it **cannot** express "app perms", which is why this ticket's
identity half is a GitHub App plus 1Password, not a managed resource.

Recommendation for this ticket: **do not** put branch protection behind Crossplane. Three
reasons:

1. **It needs a wider credential than the one we are removing.** Managing branch protection
   requires `Administration: write`. Expressing it declaratively would reintroduce a
   repo-admin token into the cluster -- the exact broad credential this change exists to
   delete.
2. **The guardrail should not be owned by the thing it guards.** A managed
   `BranchProtection` is reconcilable by whoever holds the provider credential. If that
   credential is ever compromised or the provider is misconfigured, an attacker can *disable*
   branch protection declaratively. Keeping protection in GitHub's own UI keeps its authority
   out of the cluster's reach.
3. **Near-zero reconciliation benefit.** Branch protection is one object per repo that changes
   rarely; the value of a controller is in churny, multi-object, or drift-prone resources.

Where Crossplane *would* earn its place alongside this: repo settings or Actions
secret/variable inventory that genuinely churns, and `repositorycollaborators` for
membership. Those are reasonable follow-ups, each with its own credential decision.

## Known limits of this change

- **Workflow edits.** The App has no `Workflows: write`, so a PR of the agent's that modifies
  files under `.github/workflows/**` will be rejected at push time. If the agent must be able
  to change CI, add that permission to the App -- deliberately, and note that it lets the App
  change the very checks that gate it.
- **`GITHUB_TOKEN` env var removed.** The owner PAT was also injected as `GITHUB_TOKEN` via
  `envFrom` (a snapshot that could never be refreshed). It is removed from the ExternalSecret;
  anything that relied on the env var instead of the file must move to the file.
- **Ordering is not optional.** The Secret `hermes-github-app` is a required volume, so if the
  1Password item does not exist the new pod will not start. The human steps below must be done
  **before** the PR is merged.
