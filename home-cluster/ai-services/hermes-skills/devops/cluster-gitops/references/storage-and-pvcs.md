# Storage and PVCs — Inventory, Choice, Relocation

Depth for any request about where cluster data lives, why a pod cannot move to another node, or
adding/backing/relocating storage. Answer from the inventory below, never from assumptions about
what is installed.

## Inventory first

```bash
kubectl get sc                                  # names, provisioners, which is default
kubectl get pv -o custom-columns=...            # group PVs by storageClassName
kubectl get pvc -A                              # sum .spec.resources.requests.storage for real footprint
kubectl get deploy,ds -A | grep -i csi          # which CSI drivers actually run
```

- **A driver installed is not storage available.** A CSI controller + node DaemonSet with **no
  StorageClass naming that provisioner** can provision nothing. Check for the StorageClass, not just
  the driver — a driver can sit unused for months and mislead everyone into thinking shared storage
  exists.
- Check the driver's node DaemonSet health (ready/desired, any Pending pod) *before* designing on it.
  A half-rolled-out node plugin hangs mounts later, and it surfaces first as
  `DaemonSetRolloutStuck` / `PodNotReady` alerts about a component nobody associates with storage.
- Group PVs by provisioner. If they are all a `hostpath`-class SC, **every PVC is pinned to one node**
  (local PV + nodeAffinity) — that is the real answer to "why can't this pod reschedule", and the
  reason a candidate must be checked rather than promised.
- Three distinct states, and the first two are commonly mistaken for the third: driver installed,
  StorageClass exists, CSI driver actually **deployed**. The provisioner's own `StorageClass` can
  appear while no `CSIDriver` object or node-plugin DaemonSet is ever created — a deployer Deployment
  that crashes before it finishes deploying the driver leaves exactly that: an SC that provisions
  nothing. Check all three before promising storage:
  `kubectl get csidriver <name>.csi.k8s.io` and `kubectl get ds <name>-csi-plugin`.

## Measure capacity — do not take a stated disk size

Stated sizes are nominal; free space and CPU architecture are what decide. node-exporter has the facts
(query Prometheus in-cluster):

```
node_filesystem_size_bytes{mountpoint="/"} / 1024^3     # nominal per node
node_filesystem_avail_bytes{mountpoint="/"}             # what is actually free
node_uname_info                                          # machine= reveals aarch64 nodes
node_filesystem_size_bytes > 20*1024^3                    # discover node-level CIFS/NFS mounts
```

- Replicated-storage capacity: usable ≈ sum(free on *eligible* nodes) ÷ replica count, then subtract
  10–20% rebuild headroom. A node with a handful of GB RAM or a non-amd64 arch is not an eligible
  replica host for an amd64-oriented CSI stack — exclude it explicitly with a node selector and say so.
- Total requested PV storage tells you the actual footprint. Tens of GB means capacity is almost never
  the constraint; **placement skew and failure domains** are. Answer the question that was asked
  ("does it fit") and then name the constraint that actually bites.

## Matching storage to workload

- **Replicated block** (Longhorn and similar) → stateful RWO: databases, app state/config, anything that
  must follow a pod to another node. Before calling a prerequisite a blocker, check the node
  provisioning role for it (e.g. `open-iscsi`, `nfs-common`) — if automation already installs what the
  stack requires, say that instead of asking the user to go install it.
- **NAS over SMB/NFS** → bulk media, backups, RWX app data. Cheaper than replicating bulk data, and it
  keeps a separate failure domain from cluster-local disks.
- **Never place SQLite or another database on a network filesystem** (SMB/NFS): file-locking semantics
  can corrupt it. Also weigh that a NAS-backed PVC makes the NAS a hard scheduling/every-boot
  dependency — say that trade-off out loud.
- Bulk data already on a NAS mounted at the node level (`hostPath: /mnt/nas/...`) is effectively
  portable **if that mount exists on every node** — confirm with the node-exporter mount list before
  describing those pods as node-pinned.

## A probe from a blocked pod testifies about nothing

This cluster is default-deny. A curl/TCP probe from a pod whose own egress rules do not cover the
remote target returns timeout/closed, which is evidence about **your** NetworkPolicy, not the target.
Read the namespace's egress rules first (and recall that `namespaceSelector`-only rules do not cover
bare LAN IPs). Report a network target unreachable only after a pod *permitted* to reach it has
actually failed.

## Relocating existing PVCs — procedure

- Changing a `storageClassName` does not move data — it only affects **new** volumes. There is no
  in-place migration; and `spec.storageClassName` is immutable on a bound PVC. A migration is:
  scale down → copy → new PVC → point the workload at it → verify.
- **Check who declares the PVC before promising the migration.** Open the manifest that owns the
  volume. If the PVC comes from a Helm chart's StatefulSet `volumeClaimTemplates` (a chart-managed
  `<template>-<statefulset>-<ordinal>` claim) and the chart exposes no storageClass/PVC-size knob,
  the volume is **not ours to migrate** — there is no `claimName` in our manifests to swap, and
  patching the chart's object is drift. Read the chart's `values.yaml` to confirm which knobs exist
  before recommending that workload as a migration candidate; a cache volume that looks like the
  easiest first target can be the one that is impossible.
- The copy itself: scale the workload to 0, then run a throwaway helper pod that mounts **both**
  claims at once — the old one (its PV's nodeAffinity lands the pod on the node holding the data) and
  the fresh target claim (the replicated volume attaches there). Then `tar -C /old -cf - . | tar -C
  /new -xf -`. Never copy a live database file: stop the writer first.
- Keep the old PVC after the switch. Rollback is just pointing `claimName` back; delete it only once
  the new one has soaked — and expect the leftover to become a `Released` PV (see below).
- **Replication multiplies the request.** A 50Gi volume at 2 replicas commits 100Gi across the
  cluster. Move real state; leave regenerable caches where they are, or shrink them first.
- Batch order: small config volumes first (tiny copies, quick verification), database-backed volumes
  last. Anything holding the agent's own state (kanban.db, the cron store) needs a deliberate,
  announced scale-to-zero of the agent — schedule it as its own change, never as batch filler.
- **Acceptance test that actually proves something:** after the migration, delete the pod and confirm
  the replacement lands on a *different* node. A pod that gets a replicated volume and still lands
  back on the same node has proven nothing about rescheduling.
- Endgame for chart-managed PVCs: they bind to whichever StorageClass is **default**, so the cluster
  only reaches "everything can reschedule" by eventually flipping the default class — which is
  exactly why a replicated-block install keeps `persistence.defaultClass: false` and leaves the old
  class default during the migration. Migrate what we own first, flip the default as a deliberate
  final step.
- A decommissioned node leaves **Released PVs** whose `nodeAffinity` still points at it. Check
  whenever a node leaves (`kubectl get pv -o jsonpath` filtered on the node affinity value) and
  reclaim them — they pin nothing but corrupt every later capacity inventory and backup review.
  Cleaning up dynamically provisioned leftovers is inherently an imperative one-off (deleting a PV is
  a cluster write that GitOps does not cover): file it as a ticket with the verified list and the
  exact command, for the user to execute.
- Confirm the backup situation separately: existence of a PVC, a backup CronJob referenced in docs,
  and an actual restore path are three different claims. See the PVC-resident-state pitfall in
  SKILL.md.

## Sizing a cache/DB volume — measure the artifact, never guess

A volume that only caches a downloadable artifact can be sized from the artifact itself. Layer blobs
support range requests, so the uncompressed size is readable from the tar header without downloading
the whole thing:

```bash
# manifest -> blob digest -> first 1KB of the layer -> gzip-decompress -> tar header
#   name  = header[0:100], size = int(header[124:136], 8)
```

- Trivy's server cache is the worked example: `trivy.db` ≈ **1.4 GB** and `trivy-java.db` ≈ **1.5 GB**
  *uncompressed* (the compressed layers are ~123 MB and ~972 MB — compressed size badly understates
  the on-disk need). Re-measure rather than trusting these numbers, then size accordingly.
- Budget **~2× the DB size transiently**: a DB refresh downloads the replacement alongside the
  existing file before swapping. A 2Gi volume cannot even hold `trivy.db` plus that headroom; the 5Gi
  the operator ships by default is the correct size, and "it's just a cache, make it small" is wrong.
- Shrinking a bound PVC is impossible anyway — only expansion, and only if the StorageClass allows it.
  A smaller size is a fresh volume, not a resize.

## Replicated-block install notes (Longhorn)

- Pin the chart version from the **live** repo index (`curl https://charts.longhorn.io/index.yaml`) and
  verify every value key against the downloaded chart tarball before the HelmRelease is written. A
  stale "latest" remembered from training is a real risk in both directions: the current stable may be
  newer than expected, and `longhornManager` / `longhornDriver` / `longhornUI` / `persistence` /
  `defaultSettings` / `preUpgradeChecker` are the actual top-level keys.
- `persistence.defaultClass: false` — the chart's default is **true**, which silently makes the
  replicated storage the default class and drags every new PVC (including chart-managed ones) onto it
  mid-migration. Set it false explicitly and make the flip a separate, deliberate change later.
- Node exclusion: the chart's templates expose **equality-based `nodeSelector` only** — `hostname NotIn
  (...)` is unexpressible. Exclude a non-amd64 node by `kubernetes.io/arch: amd64`, which also covers
  future arm nodes; note that instance-managers run on manager nodes, so this also keeps replicas off
  the excluded node.
- Capacity guards matter on small node disks: cap `storageOverProvisioningPercentage` and set
  `storageMinimalAvailablePercentage` explicitly, and keep the data path on `/` only after checking
  free space per node.
- **Do not enable the chart's own NetworkPolicies on MicroK8s.** Its netpol templates implement
  ingress sources for k3s/rke2 labels only, so they emit rules pointing at objects that do not exist
  here (the API-server-egress breakage class). Leaving them off is a deliberate, recorded exception to
  "every component gets a netpol" — say so in the PR so it is not re-litigated.
- Longhorn's default StorageClass binds `volumeBindingMode: Immediate` (vs the hostpath
  `WaitForFirstConsumer`). That is acceptable because Longhorn volumes are not node-bound and attach
  where the pod lands — but it does mean volumes are created before scheduling, so state the
  difference when writing migration instructions.
- Before reading Longhorn's own state (`nodes.longhorn.io`, volumes, replicas), check whether the
  read-only ClusterRole covers `longhorn.io` — if not, that is a pre-authorized RBAC PR, not a reason
  to ask the user to run kubectl.
