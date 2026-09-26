---
name: kubernetes-object-ownership
description: "Find who writes a k8s object before trusting or fixing it."
category: devops
version: 1.0.0
author: Hermit
license: MIT
metadata:
  hermes:
    tags: [kubernetes, diagnostics, troubleshooting, gitops]
    related_skills: [monitoring-alerting, cluster-operations]
---

# Kubernetes object ownership & stale state

## When to Use

An object in this cluster holds wrong or stale data, or you are about to propose a fix for
one: an Endpoints address that points at nothing, a ConfigMap nothing reads, a Service that
will not resolve, a resource whose contents disagree with git. Also use it when an alert
has been firing forever and the question is whether the *alert* is wrong or the *cluster* is.

## Rule 1 — identify the writer before believing or touching anything

```bash
kubectl get <kind> <name> -n <ns> \
  -o jsonpath='{.metadata.managedFields[*].manager}{"\t"}{.metadata.managedFields[*].time}{"\n"}'
```

The manager is the writer's user agent. `kustomize-controller` / `helm-controller` means
Flux owns it, so git is the source of truth and a PR is the fix. A control-plane component
name means the object is **not in git at all** — no PR can correct it, and a hand edit is a
write (forbidden here) that would be overwritten anyway.

## Rule 2 — decide whether it is reconciled continuously or only on events

Sample `metadata.resourceVersion` (or the managedFields timestamp) twice, 20-30s apart.
Unchanged means event-driven, not a reconcile loop: the absence of churn is not evidence
that a bad value will self-correct, and "my fix is still there" proves nothing either.
State which of the two you observed before recommending a wait-and-see.

## Rule 3 — fix the input, not the object

When the writer is a control-plane component, find the value the writer *reads* and correct
that. Editing the derived object is always the wrong move, even when it looks faster.

## Rule 4 — read the real state from the API, not from an alert's wording

An alert's `description` is a summary, not evidence. For an "instance unreachable" class of
alert, pull the actual target list and its health before theorising:

```bash
curl -s 'https://prometheus.kube.stevearnett.com/api/v1/targets?state=active'
curl -s 'https://alerts.kube.stevearnett.com/api/v2/alerts?active=true'
```

Both are reachable from the Hermes pod without auth (the public IngressRoutes are not behind
oauth2-proxy; `kubectl services/proxy` is not permitted). Cross-check the object itself with
`kubectl get ... -o yaml` and compare against what the alert claims.

Corollary, and it matters: when the evidence says a component is genuinely broken, **do not
silence the alert** to tidy the channel. An alert that fires forever because a real address
is dead is working correctly; fix the source or say plainly that it stays firing.

## Rule 5 — prove the impact before fixing, and identify the owner from the payload

A wrong value that something is listed with is only worth fixing if something actually routes to it.
Measure which side is sick — the backends, or the path to them:

```bash
# the path: N calls through the Service ClusterIP
for i in $(seq 1 30); do kubectl version --request-timeout=5s >/dev/null 2>&1 && echo ok; done | grep -c ok

# the backends: straight at each one, bypassing the Service
kubectl --server=https://<node-ip>:16443 version --request-timeout=5s
```

ClusterIP failures with zero direct failures means the routing path carries a dead address and every
backend is healthy. Report the two numbers rather than the adjective "flaky" — they are what makes the
case. The in-cluster client cert is accepted by each node's apiserver, so direct calls need no extra
flags.

**Which host is it?** Diff the advertised list against `kubectl get nodes -o wide`. If the object
lists three addresses and one is not any node's InternalIP, the node whose address is *missing* from
the list is the one announcing something else.

**If deleting the entry does not stick, a live writer is re-asserting it.** Distinguish that from
garbage state with the identity leases, not by re-reading the object:

```bash
kubectl get leases -n kube-system -o json   # apiserver-* entries: compare .spec.renewTime
```

Leases all renewed within seconds means every apiserver is alive, so the address comes from a live
component's *input* (Rule 3) — not from a stale lease waiting to be collected. A deletion that survives
means the opposite: nothing is asserting it.

Two places where an object's shape does not prove its behaviour:

- The `default/kubernetes` Endpoints object can carry
  `endpointslice.kubernetes.io/skip-mirror: "true"`: nothing mirrors it and routing comes from the
  EndpointSlice. A clean-looking Endpoints object does not prove routing is clean, and a dirty one does
  not prove it is broken — read the slice (`discovery.k8s.io/endpointslices`) for the authoritative set.
- A CRD error is ambiguous **three** ways: "the CRD is missing", "the CRD exists but is not
  `Established`", and "this particular apiserver is not serving the group" all surface as
  `the server could not find the requested resource`. The CRD's own `.status.conditions` separates the
  first two (`apiextensions.k8s.io/customresourcedefinitions` read). For the third, test the raw group
  path against each backend instead of reasoning about the CRD:

  ```bash
  kubectl --server=https://<node-ip>:16443 get --raw /apis/<group>/<version>   # APIResourceList
  kubectl --server=https://<node-ip>:16443 api-resources --api-group=<group>
  ```

  A backend that returns `NotFound` for the raw path while the same cluster lists **every** CRD of that
  group is divergent, not empty: the objects exist in etcd and that one process has stopped serving
  them. Same kubelet version and OS as its peers does not rule it out.

**Interpreting the failure rate — do the arithmetic before calling it flaky.** A process that exits
fatally on its first error (driver deployer, Helm install/upgrade, init Job, one-shot controller) needs
*every* call to succeed, so its success probability is `(1-p)^N` for N calls at failure rate p. At
p = 0.25 that is 1.7% over 10 calls and 0.03% over 20: a quarter of calls failing means such a process
can essentially never finish. That is a hard blocker, not an annoyance, and widening a timeout does not
change it. Fatal-versus-retrying decides which it is — read the log line (`level=fatal`) rather than
assuming.

## Rule 6 — attribute by isolation, not by plausibility

Two independent faults on the same path (a dead address *and* a backend that answers wrongly) produce
one symptom, and the first one you find is not automatically the cause. Before stating a causal claim:

1. Re-run the **exact failing operation** after each single fix and report the new error text. An
   install that moves from a 404 on the CRD to `fatal: failed to get arg root-dir` proves the first
   fault was real *and* that a second one was hiding behind it.
2. When the failing operation is intermittent, isolate it per backend (Rule 5) instead of arguing from
   plausibility. A fault that reproduces 8/8 against one endpoint and 0/8 against the others is proven;
   "it fits the symptom" is not.
3. Correct your own claim out loud when the test contradicts it, and put the correction where the
   claim was recorded (the ticket, the PR description) so the wrong version does not keep circulating.
4. Never upgrade a prediction into a stated cause because the user is waiting.

## Rule 7 — separate observed fact from the one step you could not verify

Host-side values (snap args, cert files, systemd state) are not readable from the Hermes
pod. Give the user the exact read-only command and the output you expect, and label the
conclusion as unverified from inside the cluster — never present a plausible value as the
confirmed cause. This is the difference between a diagnosis and a guess.

## Rule 8 — jobs fail, and jobs lie silently

When the alert is `KubeJobFailed`, establish first whether the job *ever* worked: an empty
`.status.lastSuccessfulTime` with no successful Job objects means **never**, which is a different
investigation from a regression. Expect no logs — failed pods are commonly deleted by
`podReplacementPolicy`, and events expire within the hour — so treat the stored pod spec in git as
the evidence and say plainly that logs are unavailable.

Two failure shapes to check on every backup job, because one looks like an unrelated auth error and
the other looks like success:

- a secret produced by a kustomize `secretGenerator` carrying **no data** (no `literals`, `files` or
  `envs`) — it renders empty and Flux applies it on every reconcile, so the job's `cat /creds/...`
  fails forever;
- a shell pipeline ending in a command that succeeds on empty input (`CERT=$(kubectl get secret … |
  base64 -d)`), which writes zero-byte files and exits 0 — overwriting good data with empty data while
  reporting success.

Both are fixed at the input, not the job: an ESO `ExternalSecret` copied from a sibling job that
already works, `set -euo pipefail`, and explicit non-empty/content checks. See
`references/silent-failure-jobs.md`.

## Pitfall — a stale certificate SAN is not evidence of a stale configuration value

Serving-cert SAN lists in this cluster accumulate historical IPs and are regenerated ad hoc,
so a cert containing an address the host no longer has does not prove any config still
points there. Check the actual input (the args file, the writer's source) instead.

## References

- `references/node-re-ip-stale-state.md` — the checklist for a host that changed IP: what
  goes stale, in what order to check it, and where each value actually lives.
- `references/silent-failure-jobs.md` — backup/one-shot Jobs: proving "never worked", empty
generated secrets, mounting secrets instead of shelling out to kubectl, and loud-failure hardening.
