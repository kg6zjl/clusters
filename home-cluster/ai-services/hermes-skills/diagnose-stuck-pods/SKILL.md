---
name: diagnose-stuck-pods
description: Use when a bound pod sits Pending on a Ready node.
---

# Stuck pod / DaemonSet triage

Symptom signature of a **stuck kubelet** (not a scheduling problem):
- Pod `phase: Pending`, condition `PodScheduled=True`, but **no** `Initialized` condition, no containerStatuses, no IP, no events.
- Node `Ready=True` and Lease `RenewTime` fresh (lease renewal is a separate goroutine from pod sync — Ready does NOT prove pod sync works).
- Smoking gun: recurring `FailedMount ... failed to fetch token: pods "X" not found` events from `source: kubelet/<node>` for a pod that no longer exists in the API. Kubelet missed the DELETE → its pod watch is wedged → new bound pods never get picked up either.
- Corroboration: other pods on that node have old `kubernetes.io/config.seen` timestamps; only pods present before the wedge survive.

Not the cause (check anyway, costs one command):
- Taints/tolerations: DS pods usually carry `tolerations: [op=Exists]` — they place on tainted nodes by design.
- NetworkPolicies: hostNetwork DS pods (CSI node plugins) don't need CNI.
- NodeSelector/affinity mismatch: `kubectl get pod -o json` shows the matchFields on metadata.name.

Fix is node-level, outside GitOps/kubectl: restart the kubelet on that node (MicroK8s: `sudo snap restart microk8s.daemon-kubelite`). On restart kubelet relists from API: ghost-pod retries stop, stuck pods sync. kubectl here is read-only — hand the human the exact command + evidence.

Gotchas in this environment:
- `kubectl get --raw /api/v1/nodes/<n>/proxy/pods` is Forbidden for the hermes-agent SA (nodes/proxy). Correct RBAC; don't fight it, use event sources instead.
- API is flaky from the hermes pod (~1 in 4 calls fail with `no route to host` to the ClusterIP) — wrap kubectl in a retry loop before concluding anything.
- kube-state-metrics "Job failed to complete" alerts: find culprit via `kubectl get jobs -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,FAILED:.status.failed,COND:.status.conditions[*].type`; failed pods are often already GC'd (no logs) — check the job's `.status.conditions` reason (BackoffLimitExceeded vs PodFailurePolicy), then verify NetworkPolicy egress isn't the cause before blaming the app.
