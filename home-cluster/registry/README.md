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
  -u system:serviceaccount:github-runners:registry-pusher \
  --password-stdin < /var/run/secrets/registry.zot/token
```

Granting another workload push rights is two edits: add its
`system:serviceaccount:<ns>:<name>` to `policies` in `configmap.yaml`, and give that pod the same
projected token volume (`audience: zot`).

## Deliberate constraints

- `anonymousPolicy` and a Docker-client quirk: when anonymous policies coexist with policies that
  require *basic* auth (htpasswd/LDAP/API keys), zot answers `401` on `GET /v2/` for the Docker
  client, which then fails even on anonymously readable repos (project-zot/zot#2928, #4173, won't be
  fixed). This config enables no basic-auth backend at all — bearer/OIDC only — so that path is not
  taken. Verify `curl -s -o /dev/null -w '%{http_code}' https://registry.kube.stevearnett.com/v2/`
  returns 200 after any change here; containerd and skopeo handle per-resource challenges natively
  and are unaffected either way.
- Egress is pinned to the two addresses the OIDC flow needs: the apiserver ClusterIP for the
  discovery document, and the node subnet on the nodeport that the discovery document names as
  `jwks_uri`. That host is **not stable** — two reads of the discovery document minutes apart
  returned `192.168.1.121` and `192.168.1.146` — which is why the policy allows the whole
  `192.168.1.0/24` rather than one address. If the apiserver ever publishes a `jwks_uri` outside
  that subnet or on another port, token verification breaks until `network-policy.yaml` follows it.
