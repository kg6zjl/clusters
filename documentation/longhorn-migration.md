# Migrating existing PVCs from `microk8s-hostpath` to Longhorn

This runbook covers moving an **existing** PersistentVolumeClaim from the
`microk8s-hostpath` StorageClass (a `hostPath`-backed local volume, pinned to one
node) to the `longhorn` StorageClass (replicated block storage) so the workload
can reschedule to any node.

Longhorn itself is installed by `home-cluster/longhorn-system/` and reconciled by
Flux. **Nothing in this document is deployed by GitOps.**

> **Ownership / who runs the writes.** The commands marked **[OPERATOR]** below
> are *write* operations (`kubectl apply`/`delete`, `kubectl exec ... rsync`,
> scaling workloads). They are intentionally performed by a human / approved
> operator, **not** by the agent and **not** by Flux. GitOps covers the
> *manifests*; it does not and cannot cover the *contents* of dynamically
> provisioned volumes, nor per-app scaling during a data copy. Commands marked
> **[READ-ONLY]** are safe for anyone (including agents) to run for inspection.

---

## 0. Read this first: why you cannot just change the StorageClass

A PVC's `spec.storageClassName` is **immutable after creation**. The API server
rejects any attempt to edit it:

```
The PersistentVolumeClaim "jellyfin-cache" is invalid: spec: Forbidden:
field is immutable
```

Two further reasons a "retarget" is impossible even if it were allowed:

1. **The existing data lives on a specific node's disk.** A `microk8s-hostpath`
   PV is literally a directory on the host that the PV was created on. Changing
   the StorageClass does not move those bytes anywhere; the claim would point at
   programmatically-provisioned *new and empty* storage.
2. **The reclaim policy is `Delete`.** Releasing the old PVC deletes the
   underlying directory. The old volume is the only copy of the data until the
   new one is populated.

Therefore a StorageClass migration is always: **create a new PVC + copy the data
across + repoint the workload + keep the old PVC until verified.**

The new Longhorn StorageClass is named **`longhorn`** (created by the chart,
non-default because `persistence.defaultClass: false`).

### Access modes / scheduling caveats

* The default `longhorn` StorageClass is **`ReadWriteOnce`** and uses
  `volumeBindingMode: Immediate`. `Immediate` means the volume is provisioned as
  soon as the PVC is created (no first-consumer wait), which is *different* from
  the old `WaitForFirstConsumer` behaviour. This is fine for the copy workflow,
  but note a Longhorn RWO volume attaches to **one node at a time**; a helper pod
  reading the Longhorn volume and a pod writing it cannot run on two nodes
  simultaneously.
* RNAS/NFS: this runbook deliberately does **not** move NAS data. NAS/SMB mounts
  are external `hostPath`/NFS style mounts that must not be replicated; leave
  them as they are. (The SMB CSI driver in this cluster is not usable for new
  storage — see the PR notes.)

---

## 1. Prerequisites

```bash
# [READ-ONLY] Longhorn is Up and the CSI components are Running.
kubectl -n longhorn-system get pods
kubectl -n longhorn-system get storageclass longhorn
kubectl get storageclass
# microk8s-hostpath must still be marked "(default)"
```

Do **not** start until every `longhorn-manager` / `longhorn-csi-plugin` pod on
`thinkcentre01/02/03` is `Running`, and there is **no** Longhorn pod on
`pi4-microk8s` (it is excluded by node selector).

---

## 2. Classify every PVC before touching anything

```bash
# [READ-ONLY] Every PVC in the cluster, its class, capacity and consumer.
kubectl get pvc -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.storageClassName,SIZE:.spec.resources.requests.storage,VOLS:.spec.volumeName'

# [READ-ONLY] Which workloads reference a given PVC (example).
kubectl get pods -A -o json | jq -r '
  .items[] | select([.spec.volumes[]?.persistentVolumeClaim.claimName] | any(. == "jellyfin-cache"))
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

Sort each PVC into one of two buckets:

| Bucket | Examples | Risk | Data that matters? |
|---|---|---|---|
| **Config / state** | app databases, *arr app configs, Home Assistant config, Grafana/Prometheus data | High — losing it is data loss | Yes — must be copied and verified |
| **Cache / scratch** | `media/jellyfin-cache` (50Gi transcodes cache), thumbnail caches, ingest buffers | Low — regenerated on demand | **No — acceptable to lose.** Do *not* copy it; just recreate empty on Longhorn |

For **cache** volumes the whole procedure collapses to: create a new empty PVC on
`longhorn`, update the workload to reference it, delete the old PVC. No helper
pod, no copy, no verification of contents (only that the app boots).

---

## 3. Per-app migration procedure (config/state volumes)

Do **one application at a time**. Never batch a risky app with another risky app.

Notation: `$NS` namespace, `$APP` the workload/PVC name, `$OLD` the old PVC name
(usually `$APP`), `$NEW` the new PVC name (recommend `${APP}-longhorn`).

### 3.1 Record where the data currently is

```bash
# [READ-ONLY]
kubectl -n $NS get pvc $OLD -o wide
kubectl -n $NS get pvc $OLD -o jsonpath='{.spec.volumeName}{"\n"}'
kubectl get pv $(kubectl -n $NS get pvc $OLD -o jsonpath='{.spec.volumeName}') \
  -o jsonpath='{.spec.hostPath.path}{"\n"}'   # the directory on the node
kubectl -n $NS get pvc $OLD -o jsonpath='{.status.used}{"\n"}' 2>/dev/null
```

Note the node the PV lives on — it is the node the old workload must stay pinned
to until the copy is done.

### 3.2 Scale the workload to zero

```bash
# [READ-ONLY] Identify the workload owner.
kubectl -n $NS get deploy,statefulset,daemonset -o wide | grep -i $APP

# [OPERATOR] Stop the app so nothing writes during the copy.
#   Helm-managed apps: scale via a git change (replicaCount) OR temporarily,
#   accept that the next Flux reconcile will scale it back.
kubectl -n $NS scale deployment/$APP --replicas=0
# if Helm-managed by Flux, ALSO suspend reconciliation of that HelmRelease so
# it does not fight you during the window:
kubectl -n $NS get helmrelease
# (suspend is a write; prefer doing the copy fast within one reconcile window,
#  or patch the app's chart values in git and let Flux scale it down cleanly.)

# [READ-ONLY] Confirm nothing still has the volume mounted.
kubectl -n $NS get pods
```

### 3.3 Copy the data out of the old volume (throwaway pod)

Run a short-lived helper pod that mounts the **old** PVC and copies it to a
PVC-free location you can then push into the new claim. Simplest reliable
pattern: a single pod that mounts **both** the old PVC and the new Longhorn PVC
and does one `rsync`, then exits. That avoids needing any intermediate storage.

**Create the new PVC first** (same namespace, same size or larger):

```yaml
# $NEW.yaml  (this one file is the only manifest you write by hand; it is
# temporary and is NOT committed — dynamically provisioned content is not
# GitOps-tracked)
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jellyfin-cache-longhorn
  namespace: media
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 50Gi
```

```bash
# [OPERATOR] Create the destination claim and wait for it to bind.
kubectl -n $NS apply -f $NEW.yaml
kubectl -n $NS get pvc $NEW -w      # wait for STATUS=Bound
```

Now the copier pod (old -> new):

```yaml
# copier.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pvc-copier
  namespace: media
spec:
  restartPolicy: Never
  containers:
    - name: rsync
      image: alpine:3.20
      command: ["/bin/sh", "-c"]
      args:
        - apk add --no-cache rsync &&
          rsync -aHAX --numeric-ids --delete /old/ /new/ &&
          echo COPY_DONE
      volumeMounts:
        - { name: old, mountPath: /old }
        - { name: new, mountPath: /new }
  volumes:
    - name: old
      persistentVolumeClaim: { claimName: jellyfin-cache }
    - name: new
      persistentVolumeClaim: { claimName: jellyfin-cache-longhorn }
```

> **Scheduling gotcha:** with a Longhorn RWO volume bound `Immediate`, the volume
> attaches to whichever node the pod lands on. The **old hostPath** volume can
> only be served on the node that holds its directory. So pin the copier to that
> node:
>
> ```bash
> # add to the pod spec:
> #   nodeSelector:
> #     kubernetes.io/hostname: thinkcentre02
> # [READ-ONLY] find the node holding the old PV:
> kubectl get pv $(kubectl -n $NS get pvc $OLD -o jsonpath='{.spec.volumeName}') \
>   -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}{"\n"}'
> ```

```bash
# [OPERATOR]
kubectl -n $NS apply -f copier.yaml
# [READ-ONLY] watch the copy
kubectl -n $NS logs -f pvc-copier
# expect: COPY_DONE
kubectl -n $NS get pod pvc-copier -o jsonpath='{.status.phase}{"\n"}'   # Succeeded
```

### 3.4 Sanity-check the copy

```bash
# [READ-ONLY] Compare sizes of the top level of both trees via a second helper,
# or simply re-run rsync with --dry-run to prove zero differences:
#   rsync -aHAX --numeric-ids --dry-run /old/ /new/ | tail -1
# A clean run prints no file names.
```

### 3.5 Repoint the workload at the new claim (via git)

**Manifest change (committed):** update the workload's volume reference from
`jellyfin-cache` to `jellyfin-cache-longhorn` (and its Deployment/HelmRelease
volume definition + the PVC manifest itself if it is declared in git, e.g.
`home-cluster/media/jellyfin-cache-pvc.yaml`).

```bash
# [READ-ONLY] after the PR merges and Flux reconciles:
kubectl -n $NS get pods -l app.kubernetes.io/instance=$APP -o wide
kubectl -n $NS describe pod <pod> | grep -A2 Volumes
```

If the old app was scaled to zero **by a git change**, revert that change in the
same PR as the PVC repoint so Flux brings it back at the right replica count.

### 3.6 Verify

```bash
# [READ-ONLY] Longhorn volume is attached, healthy, 2 replicas, on the right nodes.
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n longhorn-system get replicas.longhorn.io -o wide | grep <vol-name>
# [READ-ONLY] app is functioning
kubectl -n $NS get pods -o wide          # Running on an allowed node
kubectl -n $NS logs deploy/$APP --tail=50
```

Success criteria: **`robustness: healthy`, 2/2 replicas Running on
thinkcentre01/02/03, no replicas on `pi4-microk8s`**, and the app serves its data
(read a real record from the UI — do not trust "pod started" alone for a DB).

### 3.7 Clean up — only after the app has been verified

```bash
# [OPERATOR] Keep the old PVC for at least a few days / one backup cycle.
# When you are confident:
kubectl -n $NS delete pvc $OLD
# the old hostPath directory is removed by the Delete reclaim policy
kubectl -n $NS delete pod pvc-copier --ignore-not-found
```

Also delete the old PVC declaration from git if it was committed
(e.g. remove the entry from the namespace `kustomization.yaml`).

---

## 4. Batching: risky vs safe apps

| Wave | Apps | Why |
|---|---|---|
| **0 — cache first** | `media/jellyfin-cache` and any other cache/scratch PVC | Zero data at risk; validates the whole Longhorn path (SC binds, pod schedules, volume attaches) with no downside |
| **1 — low-stakes state** | apps whose only volume is a config dir that is re-creatable by hand (e.g. most *arr apps) | Can be redone from scratch if the copy fails |
| **2 — held state, batch carefully** | Home Assistant config, Grafana, Prometheus TSDB | Losing these hurts. One app per maintenance window. Export/`sqlite3 .backup` first where possible |
| **3 — databases** | PostgreSQL/MySQL-backed apps | Do one at a time, quiesce writes, and take a logical dump (`pg_dump`) *in addition to* the file-level rsync |

Rules of thumb:

* **One risky app at a time**, always.
* Never migrate a PVC that is also a backup target or an NFS/SMB mount.
* Do the migration when you can watch it end to end; leave at least one
  verified-good node outside the wave.
* Do not let a cache migration and a config migration share a window — a
  Longhorn problem is much easier to reason about in isolation.

---

## 5. Rollback

Every step above is reversible **until 3.7** (deleting the old PVC). Rollback is
purely a git + scale operation; there is no Longhorn state to unwind.

1. **Workload still points at the old PVC / copy incomplete:** nothing to do —
   scale the app back up (git) and the old `microk8s-hostpath` PVC is untouched
   and still the source of truth.
2. **Workload already repointed and something is wrong:**
   * Revert the manifest PR that changed `claimName` back to the old PVC name.
   * Scale the workload to zero, let Flux reconcile the revert, scale up.
   * The old PVC still exists (it is only deleted in step 3.7), so this is a
     clean, lossless rollback.
3. **New Longhorn volume is broken but the old PVC is already deleted:** restore
   from your app-level backup/logical dump (this is exactly why step 3.7 is
   delayed and why wave-3 databases get a logical dump).
4. **Longhorn itself is misbehaving cluster-wide:** the Longhorn install can be
   reverted by reverting this PR — Flux prunes the HelmRelease and the
   `longhorn-system` namespace resources. Existing `microk8s-hostpath` PVCs are
   unaffected because the default StorageClass was never changed
   (`persistence.defaultClass: false`).

**Hard rule: never delete the old PVC in the same PR or the same day as the
repoint.** The old volume is the rollback path.

---

## 6. Quick command reference

```bash
# inventory
kubectl get pvc -A -o wide
kubectl get sc
kubectl -n longhorn-system get pods
kubectl -n longhorn-system get volumes.longhorn.io,replicas.longhorn.io
kubectl -n longhorn-system get nodes.longhorn.io -o wide   # disk usage per node

# watch a migration
kubectl -n media get pvc -w
kubectl -n media logs -f pvc-copier
kubectl -n media get pods -o wide
```
