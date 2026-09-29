# registry

zot on `registry.kube.stevearnett.com`, backed by a Longhorn PVC.

## Auth

No static registry credential exists anywhere in this repo or in 1Password. Authentication is the
cluster's own OIDC workload identity:

- zot trusts the apiserver as an OIDC issuer (`https://kubernetes.default.svc`, the value of the
  cluster's `/.well-known/openid-configuration`).
- A workload presents a **projected ServiceAccount token with `audience: zot`** as its registry
  password. zot maps the token's `sub` claim to the identity
  `system:serviceaccount:<namespace>:<name>` and authorizes it through `accessControl`.
- Reads are **not** anonymous, despite `anonymousPolicy: ["read"]` in the repository policy. Every
  request, pull included, needs a token — see "Observed behaviour" below. `defaultPolicy: ["read"]`
  is the policy that actually applies, and it covers any authenticated cluster identity.

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
  namespace. It runs daily and rewrites every time rather than once at the end of the token's life, so
  an apiserver lifetime cap cannot silently strand it; it also fails loudly if the issued token outlives
  its rotation window by less than 30 days.
- Consumers add `imagePullSecrets: [{name: registry-pull}]` to their pod spec and nothing else.

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

## DNS

`registry.kube.stevearnett.com` is the only name, and where it points depends on who is asking.

- **In-cluster (pods, CI)**: CoreDNS rewrites the name to the Traefik Service
  (`traefik.traefik.svc.cluster.local`), so traffic goes ClusterIP → Traefik → zot. No MetalLB
  hairpin, and the target is a Service name, so the mapping cannot go stale.
- **Off-cluster (kubelet/containerd on a node, LAN clients)**: external-dns keeps the public record
  on the Traefik VIP and the node resolves through the LAN. Both paths meet at Traefik, which is the
  only thing this registry's NetworkPolicy admits.

kubelet is a node process, so it never uses CoreDNS — its pulls always take the VIP path. Whichever
name it resolves, it authenticates with the `registry-pull` Secret above, because it has no OIDC
identity of its own to present.

## Observed behaviour, from the running registry

- **Anonymous repository access is impossible while bearer auth is enabled, in zot v2.1.21.** With an
  OIDC bearer authorizer configured, `AuthHandler()` installs `bearerAuth.Middleware()` instead of the
  anonymous-aware middleware, and that middleware ends *every* unauthenticated request at
  `401 + Bearer challenge` (`pkg/api/bearer_auth.go`, v2.1.21). The only unauthenticated bypasses it
  knows are the management route and an explicitly configured anonymous metrics policy. The
  `anonymousPolicy` on `repositories` is read only by `AuthnMiddleware.tryAuthnHandlers`, which is
  never installed when bearer auth is on. Measured: an anonymous manifest fetch returns **401**, not
  404 — i.e. a kubelet pull of an image from this registry will fail.
  An unreleased fix exists on zot `main` (a unified auth middleware that handles both), but there is
  no release newer than v2.1.21 to pin. The decision was to authenticate everywhere instead: workloads
  push with their projected token, and kubelet pulls with the rotating `registry-pull` Secret above.
  Nothing here depends on anonymous read, and nothing that does can be made to work.
- **The bearer `realm` has to be an absolute URL, and this config shipped one that was not.** zot
  answers a 401 with `WWW-Authenticate: Bearer realm=<realm>,service=...,scope=...` and docker and
  containerd fetch their token from `<realm>`. The vendor example's `realm: "zot"` — what this config
  copied — is a relative string no client can follow, so no client could ever authenticate, whatever
  credential it held. It is now the endpoint zot actually serves, `<namespace>/auth/token`
  (`TokenPath` in `pkg/api/constants`), which accepts the credential as HTTP Basic with the token in
  the password field (`pkg/api/token_exchange.go`, v2.1.21). If a client ever reports it cannot find a
  token endpoint, look here first.
- **A config change only reaches zot through a pod restart.** zot reads `/etc/zot/config.json` once at
  start and never re-reads it, so this Deployment carries
  `configmap.reloader.stakater.com/reload: "zot-config"` and Stakater Reloader rolls it. Without that
  annotation a merged config change stops at the ConfigMap — measured: the realm fix was live in the
  ConfigMap while the running pod still advertised the old realm. If a change appears to do nothing,
  check the pod's age before debugging the change.
- **`GET /v2/` returns `401` when unauthenticated, and that is correct.** With a bearer/OIDC
  authorizer configured, zot replies with the auth challenge; it is not an outage and it is not
  proof that anonymous access is broken. Consequences:
  - Do **not** use `/v2/` as a Kubernetes probe. It shipped that way once: readiness never passed,
    the pod stayed out of the Service endpoints (Traefik answered 503 for every request), and
    liveness killed the container on a loop. Both probes are `tcpSocket` for that reason.
  - Do not read a `401` on `/v2/` as a design failure either — containerd and skopeo treat it as a
    normal registry challenge and continue; the Docker CLI is the fussy client (see the quirk below).
- **`/metrics` also answers `401`.** A ServiceMonitor scraping it fails permanently, so there is no
  ServiceMonitor here until it is decided how Prometheus authenticates (a token with `audience: zot`,
  or metrics left unauthenticated). Do not add one back without checking the endpoint first.
- `anonymousPolicy: ["read"]` coexisting with authenticated policies is the config that trips the
  Docker-client quirk (project-zot/zot#2928, #4173, won't be fixed): the client then fails even on
  anonymously readable repos. This config enables no basic-auth backend at all — bearer/OIDC only —
  so that forcing code path (`CanAuthenticateWithBasicCredentials()`) is not taken.
- Egress is pinned to the two addresses the OIDC flow needs: the apiserver ClusterIP for the
  discovery document, and the node subnet on the nodeport that the discovery document names as
  `jwks_uri`. That host is **not stable** — two reads of the discovery document minutes apart
  returned `192.168.1.121` and `192.168.1.146` — which is why the policy allows the whole
  `192.168.1.0/24` rather than one address. If the apiserver ever publishes a `jwks_uri` outside
  that subnet or on another port, token verification breaks until `network-policy.yaml` follows it.
