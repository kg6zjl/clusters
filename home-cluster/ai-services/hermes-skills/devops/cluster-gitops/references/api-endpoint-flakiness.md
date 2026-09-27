# API Endpoint Health — Intermittent Failures in a Multi-Apiserver Cluster

Depth for the failure class where *some* cluster API calls work and others do not, and for any
component that crash-loops or a one-shot process (Helm install, driver deployer, migration job) that
never finishes for no obvious reason. MicroK8s runs an apiserver per control-plane node behind one
ClusterIP, so a single bad endpoint poisons a fraction of all in-cluster traffic — including traffic
you are not looking at.

## Symptom → suspect this before anything else

- `connect: no route to host` against the API ClusterIP, intermittently (some calls succeed).
- Intermittent `the server could not find the requested resource` / `doesn't have a resource type`
  for a CRD you can prove exists.
- A DaemonSet/Deployment that is alive but never Ready, or a one-shot Job that fails at a different
  point each run.
- Alerts naming an API instance you do not recognise (`KubeAPIInstanceUnreachable`, flapping
  `KubeAggregatedAPIDown`).

A dead or divergent endpoint is **not** an auth problem and **not** a NetworkPolicy problem. Do not
start by rebuilding kubeconfigs or reading netpols.

## Probe, in this order

1. **Measure the rate** (proves it is path-dependent, not a one-off):
   ```bash
   ok=0; for i in $(seq 1 30); do kubectl version --request-timeout=5s >/dev/null 2>&1 && ok=$((ok+1)); done; echo "$ok/30"
   ```
2. **Isolate per endpoint** — bypass the ClusterIP and hit each apiserver directly:
   ```bash
   kubectl --server=https://<node-ip>:16443 version --request-timeout=8s
   ```
   If direct calls to every node are clean and only the ClusterIP fails, the datapath is routing to
   an address that should not be in the list. This single test separates "the cluster is broken"
   from "one endpoint is broken".
3. **Run the *exact failing call* against each endpoint.** This is the decisive test — do not stop at
   liveness:
   ```bash
   for ip in <nic> <nic2> <nic3>; do kubectl --server=https://$ip:16443 get <resource> -n <ns> -o name; done
   ```
   A healthy apiserver serving the group answers all attempts; a divergent one answers *none*.
4. **Confirm divergence at the raw path** when one endpoint misbehaves:
   ```bash
   kubectl --server=https://<bad-ip>:16443 get --raw /apis/<group>/<version>
   kubectl --server=https://<good-ip>:16443 get --raw /apis/<group>/<version>
   ```
   A `NotFound` on one and an `APIResourceList` on the other, while `get crd` on the bad one still
   lists that group's CRDs, means the CRDs exist in etcd but that apiserver process is not serving
   the group. It is that node's problem, not a missing CRD and not your manifest.

## Where the real address list lives

- Read the **EndpointSlice** for the `kubernetes` service in `default`, not the legacy v1 Endpoints
  object. The legacy object carries `endpointslice.kubernetes.io/skip-mirror` and can be a stale
  artifact that nothing updates, so a clean-looking edit there proves nothing.
- The slice's addresses come from **apiserver identity leases** (`apiserver-<hash>` in `kube-system`),
  one per live apiserver. All leases renewing within seconds means every address is backed by a
  *live* apiserver — including one advertising an address that no longer exists on the network.
- Consequence: **deleting a bad address from the Endpoints object does not stick.** The reconciler
  republishes whatever a live apiserver advertises, within seconds. Fix the apiserver's advertised
  address, or remove that node from the cluster; do not fight the object.
- Verify fixes against the slice and the lease count (4 addresses → 3), not against the Endpoints
  object, and re-run the rate probe — expect 0 failures.

## Why one bad endpoint stops a whole install

A one-shot process that exits fatally on its **first** error cannot survive a per-call failure rate.
Survival is `(1-p)^N` for N calls: at a 1/3 failure rate that is ~1.7% at 10 calls and ~0.03% at 20.
Helm installs, CSI driver deployers and migration jobs are exactly this shape, so "just retry it" and
"raise the timeout" are not fixes — the endpoint is. Say this explicitly when someone proposes waiting
it out, and prefer a generous install timeout only as defence against genuinely slow image pulls.

The same arithmetic explains a component whose logs show a *different* fatal error each restart: the
runs are not failing for different reasons, they are each dying at the first call that loses the
lottery.

## Fixes (all node-level; file them for the human)

- Stale advertised address on a control-plane node (e.g. an address from an earlier network):
  ```bash
  sudo grep -rn "<dead-ip>" /var/snap/microk8s/current/args/ /var/snap/microk8s/current/certs/
  # then correct --advertise-address and: sudo snap restart microk8s
  ```
  One node at a time; the remaining control-plane nodes keep quorum. Ask for the grep output before
  anything else changes — if the address is not in that file it is derived elsewhere and the fix moves.
- A node already slated for decommission that serves divergent state: drain and remove it
  (`kubectl drain ... --ignore-daemonsets --delete-emptydir-data`, then `microk8s remove-node <node>`).
  Check what actually runs there first — DaemonSet pods and already-Pending pods mean the drain is
  nearly free, and removing it also clears the alerts about its stuck DaemonSet pods.
- Cleaning up the alert for a known-dead instance is a **mitigation, not a fix**: route it to a null
  receiver scoped to the exact instance so the noise stops, and leave a note in the config to delete
  that route when the node is actually removed.

## Reading the state you need (RBAC)

Reading the authoritative endpoint set and CRD status needs read-only access that a
workload-scoped role often lacks:

- `discovery.k8s.io/endpointslices` — the authoritative address list per Service.
- `apiextensions.k8s.io/customresourcedefinitions` — distinguishes "CRD missing" from "CRD exists but
  is not `Established`"; both produce the identical failed-list error.

Both are `get/list/watch` only and are pre-authorized as a normal read-only RBAC PR when a new
component or diagnosis needs them. Do not ask the user to run kubectl for something you can be
granted read access to.

## Do not confuse this with NetworkPolicy

`no route to host` (EHOSTUNREACH) is a routing/ARP failure to a dead address. A NetworkPolicy block
presents as timeout or connection refusal from a pod whose egress rules do not cover the target. If
the failure is intermittent and the address set contains something that should not be there, it is
this file's class, not netpol.
