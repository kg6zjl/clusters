# registry

zot on `registry.kube.stevearnett.com`, backed by a Longhorn PVC.

## What is verified, and what is only designed

Read this before trusting the rest of the file.

- **Verified:** the registry serves and challenges correctly. An unauthenticated `GET /v2/` returns
  `401` with `WWW-Authenticate: Bearer realm="https://registry.kube.stevearnett.com/zot/auth/token",service="registry.kube.stevearnett.com"`.
- **Verified:** the rotator's RBAC is live in both namespaces, and the token mint itself works —
  `POST /api/v1/namespaces/registry/serviceaccounts/registry-pull/token` succeeds.
- **Not verified — no successful run has ever been observed.** Every rotator run so far failed, each on
  a different cause (all fixed; the causes are listed under "Observed behaviour"). No `registry-pull`
  Secret exists yet, no image has been pushed to this registry, and no image has been pulled from it by
  kubelet. Until a Job completes, the pull path is **designed, not working**.
- **Acceptance test:** run the rotator, confirm the Secret lands in the consumer namespace, then build
  one image into this registry and pull it from a pod that names the Secret. Everything below that
  describes the pull path holds only up to that first real pull.

## Auth

No static registry credential exists anywhere in this repo or in 1Password. Authentication is the
cluster's own OIDC workload identity:

- zot trusts the apiserver as an OIDC issuer (`https://kubernetes.default.svc`, the value of the
  cluster's `/.well-known/openid-configuration`).
- A workload presents a **projected ServiceAccount token with `audience: zot`** as its registry
  password. zot maps the token's `sub` claim to the identity
  `system:serviceaccount:<namespace>:<name>` and authorizes it through `accessControl`.
- Reads are **not** anonymous — bearer auth gates every request, pulls included. What governs reads is
  `defaultPolicy: ["read"]`, which covers *any* identity zot can authenticate. Any pod in this cluster
  can mint an `audience: zot` token for its own ServiceAccount with no RBAC at all, so **every workload
  in the cluster can read every repository here**. That is deliberate: images here are not secrets
  (kubectl, alpine, the runner image). It also means there is no per-repository confidentiality to
  lose, and no way to add any without a new repository block — if a confidential image is ever needed,
  it wants a separate registry, not a policy tweak.

Pushing from a runner pod:

```bash
docker login registry.kube.stevearnett.com \
  -u system:serviceaccount:github-runners:github-runner \
  --password-stdin < /var/run/secrets/registry.zot/token
```

Granting another workload push rights is two edits: add its
`system:serviceaccount:<ns>:<name>` to `policies` in `configmap.yaml`, and give that pod the same
projected token volume (`audience: zot`).

## Pulling: kubelet

kubelet is a node process: it cannot project a Pod token, so the only credential it can present is one
in an `imagePullSecret`. That is the one place intra-cluster OIDC does not reach by itself. Who puts
the credential there is the whole design question, and the answer needs no secret to sync:

- `pull-identity.yaml` — the `registry-pull` ServiceAccount, the identity kubelet presents.
- `pull-rotator.yaml` — a daily Job that mints a token for that ServiceAccount through the TokenRequest
  API (`audience: zot`) and writes it as a `kubernetes.io/dockerconfigjson` Secret into each consumer
  namespace. It rewrites the Secret on every run, which bounds how stale the delivered credential can
  be and turns an apiserver lifetime cap into a failed run instead of pulls that break weeks later.
  It asks for **7 days** and exits `FATAL` if the issued lifetime is under **36 hours**. Why not a year:
  a bound ServiceAccount token cannot be revoked on its own — only by deleting the ServiceAccount
  (breaking every consumer at once) or rotating the cluster's signing key — so its lifetime *is* the
  exposure window if a copy leaks.
- Consumers name the Secret in their pod spec: `imagePullSecrets: [{name: registry-pull}]`. **No
  consumer does yet** — nothing pulls from this registry so far, and naming a Secret that does not
  exist only makes kubelet log `FailedToRetrieveImagePullSecret` at every pod start. The reference
  belongs in the change that first builds an image here.

The Secret is deliberately absent from git. Flux owns any field it applies and would reset the token on
the next reconcile, so a runtime credential must not be a manifest — same reasoning as an ESO-synced
Secret.

Adding a consumer namespace is three edits: point its pods at the Secret, add the namespace to
`CONSUMER_NAMESPACES`, and grant the rotator a `registry-pull-secret` Role **in that namespace's own
component directory** — not in this one. This directory's kustomization sets `namespace: registry`, and
kustomize's namespace transformer rewrites every object it renders, so a Role written here for another
namespace silently lands in `registry` instead and the rotator gets a 403. Worked example:
`github-runners/registry-pull-secret-rbac.yaml`.

Rotating on demand, without waiting for the schedule:

```bash
kubectl -n registry create job --from=cronjob/registry-pull-rotator rotate
```

## Accepted risks

Stated here rather than in a file comment, so they are reviewable.

- **The rotator's ServiceAccount can create any Secret in `github-runners`,** not just `registry-pull`.
  RBAC does not apply `resourceNames` to `create` (`github-runners/registry-pull-secret-rbac.yaml`), so
  the grant is effectively `create` in that namespace. The alternative — declaring an empty Secret in
  git and granting only `get`/`update` — fights Flux's field ownership for a runtime credential, which
  is why this Job writes it. Mitigation available if it ever matters: pre-create the Secret outside
  Flux and drop the `create` verb.
- **The minted token's audience cannot be constrained by RBAC.** The Role names the ServiceAccount the
  rotator may mint for, but not the audience, so a compromised rotator pod could mint a token for
  `registry-pull` with any audience. The identity itself holds no Kubernetes RBAC, so the value of that
  is limited to zot (which checks `audiences: ["zot"]`) — but it is more than the Role's name suggests.
- **The pull token is not individually revocable.** See the lifetime note above; the kill switch is
  deleting and recreating the `registry-pull` ServiceAccount.
- **`defaultPolicy: ["read"]` is a cluster-wide read grant** to every authenticated workload. See Auth.
- **The runner's write policy is `**`** — read, create and update on every repository. Runners execute
  untrusted pull-request code, so a PR job can overwrite any tag here. Acceptable only while nothing
  else depends on these images; scope it to the repositories CI actually publishes before that changes.

## DNS

`registry.kube.stevearnett.com` is the only name, and where it points depends on who is asking.

- **In-cluster (pods, CI)**: CoreDNS rewrites the name to the Traefik Service
  (`traefik.traefik.svc.cluster.local`), so traffic goes ClusterIP → Traefik → zot. No MetalLB
  hairpin, and the target is a Service name, so the mapping cannot go stale.
- **Off-cluster (kubelet/containerd on a node, LAN clients)**: external-dns keeps the public record
  on the Traefik VIP and the node resolves through the LAN. Both paths meet at Traefik, which is the
  only thing this registry's NetworkPolicy admits.

kubelet is a node process, so it never uses CoreDNS — its pulls are expected to take the VIP path.
That is reasoning, not measurement: no kubelet pull has been observed yet, so the node-side claim is
untested. Whichever name it resolves, it authenticates with the `registry-pull` Secret above, because
it has no OIDC identity of its own to present.

## Observed behaviour, from the running registry

- **Anonymous repository access is impossible while bearer auth is enabled, in zot v2.1.21.** With an
  OIDC bearer authorizer configured, `AuthHandler()` installs `bearerAuth.Middleware()` instead of the
  anonymous-aware middleware, and that middleware ends *every* unauthenticated request at
  `401 + Bearer challenge` (`pkg/api/bearer_auth.go`, v2.1.21). The only unauthenticated bypasses it
  knows are the management route and an explicitly configured anonymous metrics policy.
  `anonymousPolicy` on `repositories` is read only by `AuthnMiddleware.tryAuthnHandlers`, which is never
  installed when bearer auth is on — so it is not just ineffective, it is dead config, and it has been
  removed from `configmap.yaml` rather than left as a trap that a future zot version could start
  honouring silently. An unreleased fix exists on zot `main` (a unified auth middleware that handles
  both), but there is no release newer than v2.1.21 to pin. The decision was to authenticate
  everywhere: workloads push with their projected token, kubelet pulls with the rotating Secret above.
- **The bearer `realm` has to be an absolute URL, and this config shipped one that was not.** zot
  answers a 401 with `WWW-Authenticate: Bearer realm=<realm>,service=...,scope=...` and docker and
  containerd fetch their token from `<realm>`. The vendor example's `realm: "zot"` — what this config
  copied — is a relative string no client can follow, so no client could ever authenticate, whatever
  credential it held. It is now the endpoint zot actually serves, `<namespace>/auth/token`
  (`TokenPath` in `pkg/api/constants/consts.go`), which accepts the credential as HTTP Basic with the
  token in the password field (`pkg/api/token_exchange.go`; both read at the pinned v2.1.21 tag). The
  `service` field was the vendor placeholder `zot-service` for the same reason — vendor guidance is
  that it name the host clients connect to, so it is now `registry.kube.stevearnett.com`. If a client
  ever reports it cannot find a token endpoint, look here first.
- **A config change only reaches zot through a pod restart.** zot reads `/etc/zot/config.json` once at
  start and never re-reads it, so this Deployment carries
  `configmap.reloader.stakater.com/reload: "zot-config"` and Stakater Reloader rolls it. Without that
  annotation a merged config change stops at the ConfigMap — measured: the realm fix was live in the
  ConfigMap while the running pod still advertised the old realm. Reloader reacts to *changes*, so a
  pod that started before the annotation existed is still stale; that is why the realm fix needed one
  manual restart even after the annotation merged.
- **`GET /v2/` returns `401` when unauthenticated, and that is correct.** With a bearer/OIDC
  authorizer configured, zot replies with the auth challenge; it is not an outage and it is not
  proof that anonymous access is broken. Consequences:
  - Do **not** use `/v2/` as a Kubernetes probe. It shipped that way once: readiness never passed,
    the pod stayed out of the Service endpoints (Traefik answered 503 for every request), and
    liveness killed the container on a loop. Both probes are `tcpSocket` for that reason.
  - Do not read a `401` on `/v2/` as a design failure either — containerd and skopeo treat it as a
    normal registry challenge and continue.
- **`/metrics` also answers `401`.** A ServiceMonitor scraping it fails permanently, so there is no
  ServiceMonitor here until it is decided how Prometheus authenticates (a token with `audience: zot`,
  or metrics left unauthenticated). Do not add one back without checking the endpoint first.
- **The rotator's Python client needed TLS strict mode off, and that is safe here.** The cluster CA
  carries no `keyUsage` extension, and Python 3.13's `ssl.create_default_context()` enables
  `VERIFY_X509_STRICT`, which rejects such a CA with an error that reads like "the apiserver is
  unreachable". `tls_context()` clears that one flag; chain, hostname and `CERT_REQUIRED` all remain,
  and the only trust anchor is the cluster CA mounted into the pod, so this cannot widen trust beyond
  the cluster's own issuer. Revisit if the CA is ever regenerated with a `keyUsage` extension.
- **Egress is pinned to the two addresses the OIDC flow needs, and one of them is broader than it
  should be.** The apiserver ClusterIP serves the discovery document, and the node subnet on the
  nodeport that the discovery document names as `jwks_uri` serves the keys. That host is **not
  stable** — two reads of the discovery document minutes apart returned `192.168.1.121` and
  `192.168.1.146` — which is why the policy allows the whole `192.168.1.0/24` rather than one address,
  and that is the widest hole this component opens in a default-deny cluster. Narrowing it means
  making the apiserver advertise an in-cluster `jwks_uri`
  (`--service-account-jwks-uri=https://kubernetes.default.svc/openid/v1/jwks`), after which the rule
  collapses to the service CIDR on 443 and the LAN rule can go. Until then, if the apiserver publishes
  a `jwks_uri` outside that subnet or on another port, token verification breaks until
  `network-policy.yaml` follows it.
