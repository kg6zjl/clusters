---
name: apiserver-endpoint-hygiene
description: "Use when in-cluster API calls fail randomly (404 on CRDs, no route to host) or a controller cannot find resources that exist. One bad apiserver endpoint poisons a fraction of all in-cluster traffic."
category: devops
version: 1.0.0
author: Hermit
---

# Broken API Endpoints — One Bad Backend Poisons Everything

**Use when:** an in-cluster client gets `no route to host`, `could not find the requested resource`, or `the server doesn't have a resource type X` even though the CRD exists; or a controller/Job/CSI deployer fails in a way that looks random.

## The mechanism

Pods resolve `kubernetes.default.svc` to the ClusterIP, and kube-proxy round-robins **every request** across all endpoints backing the `kubernetes` Service. Those endpoints come from the apiserver **identity leases** (`kube-system/apiserver-*`), not from the Node list. So one wrong IP in that set corrupts a fixed fraction of *all* in-cluster API traffic — measured here at 20-35%.

Two different failure signatures, from two different causes:

| Signature | Cause |
|---|---|
| `no route to host`, connection refused | the endpoint address is dead/not routable (stale `--advertise-address`) |
| `could not find the requested resource` / `doesn't have a resource type X` while the CRD clearly exists | an apiserver process that is **not serving that API group** — its discovery/CRD handlers are broken or stale. Listing may fail while a named get succeeds |

Do not treat the second as "the CRD is missing". Check the CRDs exist, then check *which endpoint* is answering.

## Why it is fatal, not flaky

- A **one-shot** process (Helm-driven driver deployer, init container, backup job) exits on its first error. Success probability across N calls is `(1-p)^N`: at p=0.25 that is 1.7% at 10 calls and **0.03% at 20**. It will never finish, and crash-looping only re-rolls the dice. Raising a chart's install timeout changes nothing — the timeout is the trigger, never the cause.
- A **long-lived informer** can instead cache the bad lookup result and wedge permanently. Without a liveness probe it never restarts, so it never re-runs discovery. A readiness probe failing hundreds of times with no liveness probe is a wedge.

## Diagnose (read-only)

```bash
# authoritative: this is what kube-proxy programs
kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes -o json \
  | python3 -c "import json,sys; [print([a for ep in s['endpoints'] for a in ep['addresses']]) for s in json.load(sys.stdin)['items']]"
kubectl get endpoints kubernetes -n default -o yaml | grep 'ip:'
kubectl get leases -n kube-system | grep apiserver        # include-this-endpoint source
kubectl get nodes -o wide                                  # compare the two sets
```

**The tell:** the endpoint list and the node list differ by one address. A node missing from the endpoints with an address nobody recognises standing in its place = that node advertises a wrong address.

Then probe each endpoint in isolation and classify the error. This is the decisive test, and it needs no node access:

```bash
for ip in 192.168.1.121 192.168.1.144 192.168.1.146 192.168.1.175; do
  ok=0; bad=0
  for i in $(seq 8); do
    kubectl --server="https://$ip:16443" get --raw /apis/<group>/<version> >/dev/null 2>&1 && ok=$((ok+1)) || bad=$((bad+1))
  done
  echo "$ip  ok=$ok bad=$bad"
done
```

Also compare cluster-IP vs direct: N/30 through the ClusterIP with 0 failures direct-to-node isolates the fault to the round-robin, not the apiservers themselves.

## Fixes (operator, node-side)

**Stale advertised address** (MicroK8s):
```bash
sudo grep -rn "<dead-ip>" /var/snap/microk8s/current/args/ /var/snap/microk8s/current/certs/ /var/snap/microk8s/current/var/
sudo cp -a /var/snap/microk8s/current/args/kube-apiserver{,.bak}
sudo sed -i 's/^--advertise-address=<dead-ip>$/--advertise-address=<live-ip>/' /var/snap/microk8s/current/args/kube-apiserver
sudo snap restart microk8s          # that node only; dqlite quorum survives one node
```
Cert SANs (`certs/csr.conf`) usually carry the old IP too — **leave them**. They are cosmetic unless something connects to the old address, and "fixing" them means a cluster-wide cert rotation.

**Removing a node:** deleting the Node object is not removal. The kubelet re-registers it and the apiserver's endpoint entry persists. Required:
```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data   # check for nodeAffinity-pinned PVs first
microk8s leave                          # on the node being removed
microk8s remove-node <node>             # on a surviving control-plane node (--force if it is already gone)
```
A node with a `NoSchedule` taint that only hosts DaemonSets and a stuck Pending pod drains for free. Removing it also clears DaemonSet pods that were stuck *because* they landed there.

## Verify

- EndpointSlice lists exactly the expected addresses (slice first — the legacy Endpoints object is a second view, and both must agree)
- a 30-call ClusterIP probe goes 30/30, **with a before-number** to compare against
- the corresponding alert (`KubeAPIInstanceUnreachable`, `TargetDown`) resolves and Prometheus reports 0 targets down
- a stale identity lease lingers after the fix (its renewals stop) and is garbage-collected; only the endpoint set matters

## Pitfalls

- Editing the Endpoints object by hand. The endpoint reconciler republishes from the leases within seconds — a manual fix reverts itself.
- Reading only the Endpoints object and not the EndpointSlice.
- Assuming a `Ready=True InstallSucceeded` HelmRelease means the workload works. It says nothing about whether the thing it deployed can talk to the API.
- Blaming a chart timeout for what is a fatal first API error inside the deployed process.
