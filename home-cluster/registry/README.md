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
  request, pull included, needs a token — see "Observed behaviour" below.

Pushing from a runner pod:

```bash
docker login registry.kube.stevearnett.com \
  -u system:serviceaccount:github-runners:github-runner \
  --password-stdin < /var/run/secrets/registry.zot/token
```

Granting another workload push rights is two edits: add its
`system:serviceaccount:<ns>:<name>` to `policies` in `configmap.yaml`, and give that pod the same
projected token volume (`audience: zot`).

## DNS

`registry.kube.stevearnett.com` is the only name, and where it points depends on who is asking.

- **In-cluster (pods, CI)**: CoreDNS rewrites the name to the Traefik Service
  (`traefik.traefik.svc.cluster.local`), so traffic goes ClusterIP → Traefik → zot. No MetalLB
  hairpin, and the target is a Service name, so the mapping cannot go stale.
- **Off-cluster (kubelet/containerd on a node, LAN clients)**: external-dns keeps the public record
  on the Traefik VIP and the node resolves through the LAN. Both paths meet at Traefik, which is the
  only thing this registry's NetworkPolicy admits.

kubelet is a node process, so it never uses CoreDNS — its pulls always take the VIP path. That is
why a pull credential has to exist somewhere, however the in-cluster name resolves.

## Deliberate constraints

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
  no release newer than v2.1.21 to pin. Until a decision is made, nothing pulls from this registry.
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
