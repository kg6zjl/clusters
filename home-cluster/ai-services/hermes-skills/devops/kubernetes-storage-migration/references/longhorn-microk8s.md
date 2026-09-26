# Longhorn on MicroK8s

## The kubelet root dir must be set explicitly

Longhorn's driver deployer auto-detects the kubelet root directory by inspecting process arguments for
k3s/rke2 — on MicroK8s there is nothing to find and it dies:

```
level=fatal msg="Error deploying driver: failed to start CSI driver: failed to get arg root-dir.
Need to specify \"--kubelet-root-dir\" in your Longhorn deployment yaml."
```

Its own log shows the failed hunt (`discover-proc-k3s-cmdline`… `Proc not found: k3s`). The chart value
is `csi.kubeletRootDir` (defaults to empty) and MicroK8s keeps kubelet state at
`/var/snap/microk8s/common/var/lib/kubelet`:

```yaml
values:
  csi:
    kubeletRootDir: /var/snap/microk8s/common/var/lib/kubelet
```

Confirm the path on a host with `grep -i root-dir /var/snap/microk8s/current/args/kubelet` instead of
trusting the default above. Without it no `driver.longhorn.io` CSIDriver is ever created and the
deployer crash-loops forever — the install looks healthy the whole time.

## Chart-template CRDs, install timeouts, and the wedge

Longhorn ships its CRDs inside the chart's templates, so a failed install whose remediation runs the
uninstall hook **deletes all 25 CRDs**. Symptoms afterwards: manager logs
`failed to list *v1beta2.Volume: the server could not find the requested resource`, `get crd | grep
longhorn` returns nothing, and a `longhorn-uninstall` job may be sitting around.

Recovery is: delete the `sh.helm.release.v1.longhorn.v1` secret and the uninstall job, reconcile, and
let Flux reinstall. Raise `spec.install.timeout`/`upgrade.timeout` well above the 5m default for the
cold install — it pulls manager, instance-manager, share-manager and CSI sidecars across every node.

A failed install can also be a *symptom*, not a cause: the manager wedges when any API call on its path
resolves to a 404 (a dead endpoint, or an apiserver not serving the group). Fix the API path first —
see `kubernetes-object-ownership` Rules 5-6.

## Node selection and placement

Use `kubernetes.io/arch: amd64` to keep ARM nodes out; a hostname `NotIn` cannot be expressed with a
`nodeSelector`. Verify by counting the managers' nodes afterwards. Also check the node's taints — a
`NoSchedule` taint on a decommissioning host makes the exclusion moot but changes the drain plan.

## Settings worth setting deliberately

- `persistence.defaultClass: false` — do not silently take over the default StorageClass.
- `persistence.defaultReplicaCount` — 2 on a 3-node cluster is a reasonable starting point; the
  footprint is size × replicas.
- `defaultSettings.defaultDataPath` — keep it on a path with real free space, and re-check free space
  per node before promising capacity.
- Leave the chart's NetworkPolicy templates **off**: they only implement k3s/rke2 ingress sources, so
  enabling them on MicroK8s emits rules that match nothing and misleadingly "succeed".
- `preUpgradeChecker.jobEnabled: false` for GitOps installs — the Job races reconciliation.

## Verification, in this order

1. `kubectl get csidriver driver.longhorn.io` exists.
2. `kubectl get ds longhorn-csi-plugin -n longhorn-system` Ready on every eligible node
   (plus `longhorn-manager`, `longhorn-ui`, `longhorn-driver-deployer` at 1/1).
3. Every node shows `Ready` + `Schedulable` with its Longhorn disk registered and free space.
4. The StorageClass exists and is **not** the default yet.
5. A throwaway PVC binds on that class — the only proof that provisioning works.
