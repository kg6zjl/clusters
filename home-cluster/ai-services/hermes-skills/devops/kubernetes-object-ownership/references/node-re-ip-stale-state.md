# Node re-IP: stale-state checklist

A host that changes IP keeps stale state in several independent places. Fixing one does not
fix the others, and each has a different symptom — work them in this order.

Enumerate every reference in one pass before changing anything, then work the list:

```bash
grep -rn '<old-ip>' /var/snap/microk8s/current/args/ /var/snap/microk8s/current/certs/ \
  /var/snap/microk8s/current/var/ 2>/dev/null
```

Expect hits in the apiserver args (section 2), the serving-cert SANs (cosmetic — section 4), and the
containerd registry-mirror configs (section 6). Decide for each hit whether it is an **input** or
derived/cosmetic before touching anything.

## 1. kubelet serving cert SAN (`:10250`)

Symptom: `kubectl logs` / `exec` / `port-forward` fail for pods on that node with
`x509: certificate is valid for <old IP>, not <new IP>`, while `kubectl get` works fine.

Fix path: `node-config/kubelet-cert.yaml` (Ansible, PR'd, run per host with `--limit`).
Deleting the cert files and restarting is NOT sufficient — a plain delete+restart
regenerates a cert with only `DNS:<hostname>` and no IP SANs; the playbook's
CA-signed CSR path is required. `snap.microk8s.kubelet` does not exist on microk8s >= 1.31;
the unit is `snap.microk8s.daemon-kubelite`. Verify with:

```bash
echo | openssl s_client -connect <node-ip>:10250 -verify_quiet 2>/dev/null \
  | openssl x509 -noout -text | grep -A2 'Subject Alternative Name'
```

## 2. kube-apiserver args (`--advertise-address`)

This is what the control plane reports **about itself**, and it is what lands in the
`default/kubernetes` Endpoints object — the list is not derived from
`Node.status.addresses[InternalIP]`. So a re-IP'd control-plane host leaves a dead entry
behind and never gains its new address on its own.

Read it on the host (read-only, needs the user):

```bash
grep -E 'advertise-address|bind-address' /var/snap/microk8s/current/args/kube-apiserver
```

`node-config/` currently templates kubelet args (`roles/node/templates/kubelet.args.j2`)
but has **no apiserver-args template** — that is the gap that lets this survive an
otherwise PR'd re-IP. The `ansible_host` value in `node-config/inventory/hosts.yml` is the
intended address.

Consequence to expect while it is wrong: the `apiserver` Prometheus job scrapes one target
per listed address, so the dead entry is a permanently-down target and a permanent
`KubeAPIInstanceUnreachable` / `TargetDown`. That alert is accurate — leave it firing.

**Which host is advertising the wrong address:** the node whose InternalIP is *missing* from the
advertised list is the one announcing something else. Diff the list against `kubectl get nodes -o wide`.

**Prove it is in the datapath before recommending the restart** — a listed address that nothing routes
to is cosmetic:

```bash
# the path: N calls through the Service ClusterIP
for i in $(seq 1 30); do kubectl version --request-timeout=5s >/dev/null 2>&1 && echo ok; done | grep -c ok
# the backends: straight at each one, bypassing the Service (the in-cluster cert is accepted)
kubectl --server=https://<node-ip>:16443 version --request-timeout=5s
```

ClusterIP failures with zero direct failures = the path carries the dead address while every backend is
healthy. If deleting the entry does not stick, a live writer is re-asserting it — check the `apiserver-*`
leases in `kube-system` (`.spec.renewTime`): all renewed within seconds means every apiserver is alive,
so the address is a live component's *input*, not a stale lease to garbage-collect.

## 3. `default/kubernetes` Endpoints object

Derived, not authoritative. Manager is `kubelite` and it is written on membership events,
not on a loop (it does not tick every few seconds — sampling the resourceVersion tells you
this). Verify a fix landed with:

```bash
kubectl get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[*].ip}'
```

The new address appears only after the fixed component restarts or a membership event
occurs; if neither happens the object will not move on its own.

This object can also carry `endpointslice.kubernetes.io/skip-mirror: "true"`, in which case nothing
mirrors it and kube-proxy routes from the EndpointSlice instead. So a clean Endpoints object does not
prove routing is clean, and a dirty one does not prove it is broken — read the slice
(`discovery.k8s.io/endpointslices`) for the authoritative set. Expect an edited entry to reappear in
seconds while the advertising apiserver is still running.

## 4. apiserver serving cert SAN (`:16443`)

Cosmetic for TLS purposes (the live address is generally present too), but these lists
drift stale over time. Do not read them as evidence of the advertised address — see the
pitfall in SKILL.md.

## 5. Cluster membership: a control-plane host leaving

The API endpoint list is driven by membership, not by the Node object. Deleting the Node object (all
Headlamp offers) does not remove that host's apiserver from the round-robin, and the kubelet on the
host re-registers the Node anyway — the entry returns and nothing improves. Check whether the host is
control plane before planning anything:

```bash
kubectl get node <name> -o jsonpath='{.metadata.labels}' | grep -o microk8s-controlplane
```

Removal is a MicroK8s operation — on the host, and on a *surviving* control-plane node:

```bash
sudo microk8s leave                      # on the host leaving
sudo microk8s remove-node <name>         # on a survivor; --force if the host is already gone
```

Before draining, confirm nothing strands: PVs pinned to the host via `spec.nodeAffinity`, its taints,
and whether its pods are all DaemonSet-owned (`NoSchedule` taints usually mean nothing user-facing is
there). Then list what a restart there bounces — `kubectl get pods -A -o wide --field-selector
spec.nodeName=<host>` — and say it before recommending the restart; if this agent runs on that host, the
session can go quiet mid-reply, and the user should know that is expected rather than a failure. Expect the departed address to linger in the slice until its lease expires, so verify the
endpoint set and the `apiserver-*` lease count minutes later rather than the Node object.

**A live control-plane process can stop serving an API group.** Same version and OS as its peers, its
CRDs present in `get crd`, yet `get --raw /apis/<group>/<version>` returns `NotFound` on that endpoint
only. Everything routed there 404s intermittently and any fatal-on-first-error installer on the path
never completes. Restart that host's control plane to rebuild the CRD handlers, or remove the host from
the cluster — a node already queued for decommissioning is worth removing rather than repairing.

Leftovers to clean after any membership change: Alertmanager blackhole/inhibit routes added for that
host, per-address Prometheus scrape targets, node-pinned PVs, and the Node object if `remove-node`
leaves it behind.

## 6. containerd registry-mirror config (`args/certs.d/*/hosts.toml`)

Symptom: image pulls are slow or fail while every registry is fine — containerd tries a mirror address
that no longer exists before falling back to the real one.

These are one file per registry (`docker.io`, `ghcr.io`, `quay.io`, …) holding
`[host.'http://<old-ip>:<nodeport>']` blocks, so a re-IP leaves a dead hop in all of them. Before
repointing at the new address, check that something still serves that port — compare the port against
`kubectl get svc -A` and test it on the new address. A mirror that is gone entirely means **delete the
config**: repointing it just preserves a dead hop with a fresh IP in it.

## Generalisation

Any single address that appears in three places (a host config, a derived API object, and a
certificate) will be fixed inconsistently if you patch the derived object. Always ask which
one is the input.
