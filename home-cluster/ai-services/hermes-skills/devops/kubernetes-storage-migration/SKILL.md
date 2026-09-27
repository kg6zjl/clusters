---
name: kubernetes-storage-migration
description: "Stand up a CSI backend or migrate PVCs onto one."
category: devops
version: 1.0.0
author: Hermit
license: MIT
metadata:
  hermes:
    tags: [kubernetes, storage, pvc, csi, longhorn, migration]
    related_skills: [cluster-operations, kubernetes-object-ownership]
---

# Persistent storage: backends and PVC migration

## When to Use

Choosing or standing up a CSI backend, deciding whether a volume *should* move, or actually moving a
workload's PVC from one StorageClass to another (`microk8s-hostpath` → Longhorn, and the storage work
that follows it: retention volumes for logging, databases, config state).

## Rule 1 — `spec.storageClassName` is immutable; migration is a copy, not an edit

The procedure, in order:

1. Identify the volume and its consumer before touching anything:
   `kubectl get pvc <name> -n <ns> -o jsonpath='{.spec.storageClassName}{"\t"}{.spec.volumeName}{"\t"}{.status.capacity.storage}'`
   and grep the manifests for the `claimName` rather than assuming which workload mounts it.
2. Create the **new** PVC with the target class, same size or larger.
3. Scale the consumer to 0 (mandatory for databases and anything with a WAL — copying a live DB
   gives a corrupt volume that looks fine).
4. Copy with a pod that mounts both claims and preserves ownership (`rsync -aHAX` or `cp -a`), then
   check sizes on both sides.
5. Repoint the workload's `claimName` via PR, scale up, verify app health.
6. **Keep the old PVC until the app has run a full cycle** — it is the rollback. Delete it last.

### Do it in two PRs, with the copy committed as a Job

Read-only cluster access cannot `kubectl run` a mover pod, and a hand-run mover is drift anyway. Commit
the copy as a `Job` and let Flux apply it:

- **Stage 1** — new PVC + copy Job + consumer scaled to 0, in one commit. Nothing is repointed yet.
- **Stage 2** — repoint `claimName`, restore replicas, delete the migration file and its kustomization
  entry.

Repointing in stage 1 would let the app boot against a still-empty new volume before the copy finishes,
and because the manifests are reconciled continuously there is no ordering guarantee to save you.
Placement takes care of itself: the source hostPath PV's `nodeAffinity` pins the copy Job to the node
holding the data, which is also where the new volume attaches, so the Job needs no nodeSelector of its
own. Mounting both claims while the consumer still runs is physically fine (RWO is per-node, not
per-pod) — the scale-to-0 is about not copying a volume being written, not about contention.

Do **not** set `ttlSecondsAfterFinished` on a Job that lives in git: the Job deletes itself, Flux sees
it missing and recreates it, and the copy re-runs on a loop. Leave it `Completed` and remove the
manifest in stage 2.

**Acceptance test, and the only one that matters:** delete the migrated pod and confirm it comes back
on a *different* node and mounts. A volume still pinned by a `hostPath` PV has not been migrated,
whatever the class field says.

## Rule 2 — find out who owns the volume before promising a migration

Not every PVC is yours to move. Check the chart before committing to it: if the chart ships the volume
with no class/size value exposed (some operators hardcode their server's volume), there is no PR that
migrates it, and the honest answer is "not migratable by us". Use
`managedFields`/`meta.helm.sh/release-name` to establish the writer, and read the chart's values for a
storage knob rather than guessing one exists.

## Rule 3 — capacity maths from *free* space and replica count

Take the numbers from the cluster, not from the disk labels:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.capacity.cpu,MEM:.status.capacity.memory
kubectl get pvc -A --no-headers | awk '{print $1, $3, $4}'   # what state actually consumes
```

Replicas multiply everything: usable = free space across the eligible nodes, and each volume costs
`size × defaultReplicaCount` spread over them. State that ceiling when recommending replica counts;
"3 × 256GB nodes" is not 768GB of usable storage.

**Node selection:** `nodeSelector` cannot express "hostname not in (…)", so exclude hosts by a real
label (`kubernetes.io/arch: amd64` is how the ARM node gets kept out) — and then verify the placement
by counting where the backend's pods actually landed, not by reading the selector.

## Rule 4 — leave the default StorageClass alone until the very end

Installing a backend with `persistence.defaultClass: false` means nothing changes silently. Flipping
the default re-points every future PVC that omits `storageClassName`, which is a fleet-wide change
hiding in one annotation — make it the last deliberate step, after every consumer is migrated.

## Rule 5 — hybrid by data class, not one backend for everything

CSI-replicated storage is for **RWO state that must reschedule** (configs, databases, small caches).
Bulk media belongs on the NAS: replicating terabytes through the cluster's disks is not resilience,
it is a slow way to run out of space. Ask which class the volume is in before agreeing to move it.

## Rule 6 — "installed" is not "usable"; verify the driver, then a real PVC

A HelmRelease reporting `Ready=True InstallSucceeded` with healthy pods still provides **no** storage
if the CSI driver never deployed. Check the three things:

```bash
kubectl get csidriver driver.longhorn.io                      # the driver object exists
kubectl get ds -n longhorn-system longhorn-csi-plugin         # node plugin Ready on every node
kubectl get sc                                                # the class exists, and is not default yet
```

Then bind a throwaway PVC to the class before declaring anything migrated. "The chart is installed" and
"a volume can be provisioned" are different claims; only the second one matters to the user.

## Pitfalls

- **A timed-out install can delete the backend's CRDs.** Charts that ship CRDs as `templates/` (rather
  than a `crds/` dir) lose them when Flux's install remediation runs the chart's uninstall hook. The
  backend then wedges on `failed to list *v1beta2.Volume: the server could not find the requested
  resource` because those CRDs are gone, not because it is broken. Give cold multi-node installs a
  longer `install.timeout`/`upgrade.timeout` than the 5m default.
- **A controller with no liveness probe wedges on a cached "not found"** and never recovers: an
  informer that failed to resolve a type at startup keeps failing. Restart the pods; do not wait.
- **One-shot installers are all-or-nothing.** See `kubernetes-object-ownership` Rule 5 for the
  `(1-p)^N` arithmetic — an intermittent API fault blocks a fatal-on-first-error deployer completely.

## References

- `references/longhorn-microk8s.md` — Longhorn on MicroK8s: the kubelet root dir, install-timeout and
  CRD-deletion behaviour, node exclusion, and the verification checks.
