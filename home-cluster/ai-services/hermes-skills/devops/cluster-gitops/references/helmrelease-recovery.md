# Recovering a stuck Flux HelmRelease

How a Helm install fails in this cluster, where Helm's real error is hidden, and the order to
unwind it. Written for charts that ship their CRDs as **templates**, which is the case that
makes a failed install destructive rather than harmless.

## Where the real error lives

- `kubectl get helmrelease <name> -n <ns> -o json` -> `.status.conditions[]`. The useful ones are
  `Released` (Helm's own message, including what it timed out waiting for) and `Remediated`
  (whether the cleanup path also failed). `Ready=False reason=StateError` with
  `unable to determine state for release with status 'uninstalling'` means the release record
  itself is unusable and Flux can only error-loop.
- Namespace events carry the untruncated Helm log under a `Last Helm logs:` block — that is where
  the per-resource failure text is, not in the condition message.
- `.status.failures` / `.status.installFailures` tell you whether Flux is still retrying at all,
  and `.status.history[]` shows what Helm actually did (`action`/`status`/`version`).

## The destructive path to know about

Flux's install remediation (default strategy) runs `helm uninstall` when an install fails. If the
chart's CRDs live in `templates/` (a single `templates/crds.yaml`, as Longhorn ships them) rather
than in the chart's `crds/` directory, `helm uninstall` **deletes the CRDs** and with them every CR
of that group. The chart's `pre-delete` hook job is slow and can time out too, leaving the release
stuck in `uninstalling`.

- After any partial uninstall: `kubectl get crd | grep -c <group>` — `0` means the CRDs went with it.
- `install.crds: Skip` only skips the chart's `crds/` directory; it does not protect template CRDs.
- The uninstall hook is chart-provided (`templates/uninstall-job.yaml`, `helm.sh/hook: pre-delete`),
  so its behaviour is not something this repo controls — only the timeout is.

## Recovery order

1. **PR the timeout first**, so a slow cold install cannot trip the path again:

   ```yaml
   spec:
     install:
       timeout: 15m
       remediation: {retries: 3}
     upgrade:
       timeout: 15m
       remediation: {retries: 3}
   ```

   Flux's default is 5m. A first install that has to pull manager, engine and CSI sidecar images
   onto small nodes can exceed it, and the install timeout is what triggers the destructive cleanup.

2. **Clear the imperative state** (user-run: it is deletes, so it cannot be expressed in git):

   ```bash
   kubectl -n <ns> delete job <chart>-uninstall --ignore-not-found
   kubectl -n <ns> delete pod --all
   kubectl -n <ns> delete secret sh.helm.release.v1.<release>.v1 --ignore-not-found
   ```

   The release secret is what pins the release at `uninstalling`. Deleting it makes Flux see
   `release not installed: no release in storage for object` and install from scratch. Deleting the
   pods is safe while the install never went Ready — confirm with `kubectl get pv | grep <driver>`
   that no volume was ever created.

3. **Trigger a reconcile without the flux CLI** — set the annotation the CLI itself sets:

   ```yaml
   metadata:
     annotations:
       reconcile.fluxcd.io/requestedAt: "<RFC3339 timestamp>"
   ```

   Put it in git so a merge triggers the retry, or edit the live object from a UI. Without it you
   wait out the HelmRelease `interval` (up to an hour).

4. **Verify** the record moved: `.status.history[]` should show
   `{'action': 'install', 'status': 'deployed'}` and the conditions `Released: True` /
   `InstallSucceeded`. A component that was crash-looping during the failure may need its pod cycled
   once before it stops reproducing the old error.

## Component follow-ups seen with this failure

- **A component that caches API discovery at startup wedges permanently** rather than retrying:
  a manager pod sitting at `1/N` with continuous readiness-probe failures and a log that stops at
  `Waiting for caches to sync` has no liveness probe to rescue it. Cycle the workload (for Longhorn:
  `kubectl -n longhorn-system rollout restart ds/longhorn-manager`) — a reinstall is unnecessary once
  the CRDs are established.
- **A one-shot deployer Deployment retries by crash-looping**, and its fatal message names whichever
  API call failed. Read it as "this call failed", not "this component is broken": a partially
  failing API path turns healthy components into convincing-looking component bugs. Rule out the
  API path (see `kubernetes-object-ownership`) before blaming the chart.
- **A chart can report `InstallSucceeded` while one of its member Deployments is still failing** if
  that Deployment is not part of the wait set — do not read the Helm status as cluster health; check
  the actual workloads too.
