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
- Reads are anonymous (`anonymousPolicy: ["read"]`), so kubelet pulls need no credential at all.
  Pushes require an identity listed in the config's `policies`.

Pushing from a runner pod:

```bash
docker login registry.kube.stevearnett.com \
  -u system:serviceaccount:github-runners:github-runner \
  --password-stdin < /var/run/secrets/registry.zot/token
```

Granting another workload push rights is two edits: add its
`system:serviceaccount:<ns>:<name>` to `policies` in `configmap.yaml`, and give that pod the same
projected token volume (`audience: zot`).

## Deliberate constraints

## Observed behaviour, from the running registry

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
