# Falco - runtime detection wired into the existing alert path

Trivy answers "is there a known-bad package in this image"; it cannot answer "is a process doing
something it should not". This directory adds the runtime half: one Falco DaemonSet per node
(syscall behaviour) shipping events to falcosidekick, which posts them to Alertmanager.

## What runs

- `falco` DaemonSet (`falcosecurity/falco` 0.45.0, chart 9.2.0), driver `modern_ebpf`.
  Nodes run 5.15.0-191-generic (thinkcentre01/02) and 7.0.0-34-generic (thinkcentre03); the modern
  eBPF probe covers all three. `kind: auto` is deliberately not used: it can fall back to kmod, and
  there is no prebuilt module for 7.0.0. The probe still needs BTF on each node - `dmesg`/pod logs on
  the first reconcile are what confirms it, not this comment.
- `falcosidekick` 1 replica, image pinned to 2.35.0. The chart's default (2.32.0) does not set the
  `alertname` label on the Alertmanager payload - 2.33.0 added it
  (`outputs/alertmanager.go`: `Labels["alertname"] = falcopayload.Rule`) - and without it every Falco
  alert grouped under `alertname=""`: empty Discord/ntfy titles, the severity inhibit rule matching
  every Falco alert against every other one, and `unknown` in the alert-detector. No falcoctl init
  container and no artifact-follow sidecar: the container plugin (`libcontainer.so`) is bundled in the
  falco image (verified by listing the image layers of `falcosecurity/falco:0.45.0`), so nothing is
  downloaded at pod start and this namespace never talks to ghcr.io.
- The container plugin reads MicroK8s's CRI socket, which the chart's default socket list does not
  contain (`collectors.containerEngine.engines.cri.sockets`). Until 2026-09-30 it enriched nothing:
  in a 25-minute sample every one of 620 events had `k8s.ns.name`, `k8s.pod.name` and
  `container.image.repository` set to null, which is what made `k8s_containers` unable to exclude
  anything and left `container.privileged` unset, so `Launch Privileged Container` could not fire.

The `falco` namespace deliberately carries no `pod-security.kubernetes.io/enforce` label. Falco needs
a privileged container and hostPath mounts, and both violate the `baseline` level that namespaces
like `security-scanning` set - labelling this one `baseline` would block the security control itself.

## Alert path (reused, not rebuilt)

```
falco (DaemonSet, /etc/falco/rules.d) -> http://falco-falcosidekick:2801
  -> Alertmanager (http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093/api/v2/alerts)
       severity=critical -> ntfy (urgent) + Discord        [existing routes in monitoring/alertmanager-external-secret.yaml]
                         -> alert-detector CronJob -> hermes-webhook (wakes the agent)
       severity=warning  -> Discord                        (default receiver)
```

falcosidekick derives the `severity` label from the Falco event priority:

| Falco priority                            | severity  | where it lands                          |
|-------------------------------------------|-----------|-----------------------------------------|
| emergency / alert / critical              | critical  | ntfy + Discord + agent wake             |
| error / warning                           | warning   | Discord                                 |
| notice / informational / debug            | information | dropped by `minimumpriority: warning` |

`expireafter` is deliberately **not** set. Falcosidekick never sends `startsAt`, and Alertmanager
v0.34.1 (`api/v2/api.go:370-377`) sets `StartsAt = EndsAt` when an alert arrives with an end but no
start. With `expireafter: 300` every Falco alert therefore came out as
`starts_at = ends_at = evt.time + 300s` - measured on 8 of 8 alerts, e.g. Falco
`08:10:24.676` -> Alertmanager `startsAt`/`endsAt` `08:15:24.676` - i.e. a start stamp five minutes in
the future and an instantaneous window. Left unset, Alertmanager stamps `startsAt = now` and
`endsAt = now + resolve_timeout` (5m, `Timeout=true`), so an alert is fresh from receipt and still
resolves on its own. `dropeventdefaultpriority`/`dropeventthresholds` are overridden away from the
upstream defaults, which turn *any* dropped-syscall event into a critical alert; only a five-figure
drop count is critical here.

Each curated rule's `output:` is trimmed to the fields worth reading rather than copied from upstream.
Falcosidekick copies that whole line into *both* the `description` and `info` annotations and flattens
every referenced field into a label, and ntfy rejects a page over its size limit with 40041. Measured
against real events: the upstream miner output (369 chars) produced a 3412-byte webhook body, which
ntfy accepted; 733 chars produced 5632 bytes, which it rejected. The trimmed outputs are 103-203
chars, so a normal event's page body is ~1.8 KB. See the known gaps for the case that still does not
fit.

falcosidekick cannot post to the Hermes webhook directly: that route is HMAC-verified and
falcosidekick cannot sign a body. Alertmanager -> alert-detector is the only sender, so it stays the
single hop that reaches the agent.

## Rules: a curated starter set

`spec.values.customRules` in `helmrelease.yaml` (rendered to the `falco-rules` ConfigMap, mounted at
`/etc/falco/rules.d`) and `falco.rules_files` is set to exactly that directory, so the upstream
default ruleset shipped in the image at `/etc/falco/falco_rules.yaml` is never loaded.

Rule text and its macros/lists are copied verbatim from `falcosecurity/rules` (`main`); `priority` is
overridden and one macro is overridden where marked, plus one extra tag `curated_home_cluster` so
these are greppable. Script that produced it: extract rule + transitive macro/list closure, emit
macros/lists then rules.

Two deliberate deviations from upstream text, both marked in the file:

`user_privileged_containers` (upstream: `never_true`) now lists the image repositories that
legitimately run privileged in this cluster - read from the running pods, not guessed: longhorn
(manager/engine/instance-manager/csi-registrar), calico (node/cni), the smb CSI driver, the runner's
`docker:dind` sidecar, gluetun, jellyfin, home-assistant (plus matter-server) and the adsb
ultrafeeder. Without it, `Launch Privileged Container` fires on every restart of ~15 pods that were
already privileged; with it, the rule fires only for a privileged container that is *new*, which is
the signal worth having. `busybox` is deliberately not listed even though two init containers use it
privileged: "privileged busybox" is exactly a shape an attacker would use.

`user_known_contact_k8s_api_server_activities` (upstream: `never_true`) lists the API clients that
exist to drive the API server here, as the list `known_k8s_api_clients` - matched on the image
repository, not the process name, because a shell inside one of those pods keeps the image while
`kubectl` as a name is exactly what the rule is for. It is not a hand-written roster: every entry is a
workload measured in the live cluster to hold an explicit RBAC binding granting object-level API
verbs - read from all 166 pods present on 2026-09-30 (138 running) and their ServiceAccount bindings:
longhorn's manager and CSI sidecars, the flux/kyverno/cert-manager/ESO/crossplane controllers,
traefik, metallb's frr-k8s, the ARC controller, zot, Grafana's `k8s-sidecar`, the prometheus
config-reloader, kube-state-metrics, alloy, the kube-prometheus-stack admission hook,
trivy-operator, headlamp and the agent. `k8s_containers` already excludes the whole `kube-system`
namespace, so no kube-system image needs an entry. Longhorn's data-path images (engine,
instance-manager, share-manager, livenessprobe, node-driver-registrar) are deliberately *not* listed:
they talk to `longhorn-backend` on `10.152.183.60` and to the kubelet, not to the API server, and none
of them appeared in the sweep. The `ingress-blackbox` reconciler Job is the one client matched on
namespace + pod name instead: it runs `docker.io/library/python`, and allow-listing that repository
would exempt every python container in the cluster from the rule - the same shape applies to any other
generic base image. Every entry is an infrastructure controller by construction, so what the rule
still reports is a container that is not one of them: in practice the application namespaces (media,
home-assistant, nodered, adsb, vpn, netalertx, meshtastic, speedtest, local-services, sso), which have
no business dialling the API server at all. An unlisted container still fires. See the known gaps for
both sweep windows and the argument that the rule should be dropped outright.

CRITICAL (2) - reserved for indicators that are essentially never legitimate:

| rule | why critical |
|---|---|
| Detect release_agent File Container Escapes | cgroup release_agent write from a container = escape |
| Detect crypto miners using the Stratum protocol | miner command line (stratum+tcp/ssl) |

WARNING (12) - Discord only, tuned by watching the first days:

| rule | source file |
|---|---|
| Terminal shell in container (`proc.tty != 0`) | falco_rules |
| Launch Privileged Container | falco-incubating |
| Contact K8S API Server From Container | falco_rules |
| Contact cloud metadata service from container | falco-incubating |
| Redirect STDOUT/STDIN to Network Connection in Container | falco_rules |
| Netcat Remote Code Execution in Container | falco_rules |
| Execution from /dev/shm | falco_rules |
| Fileless execution via memfd_create (upstream: CRITICAL, downgraded) | falco_rules |
| Linux Kernel Module Injection Detected | falco_rules |
| Read ssh information | falco-incubating |
| Find AWS Credentials | falco_rules |
| Search Private Keys or Passwords | falco_rules |

Deliberately excluded, with reasons rather than omissions:

- **Drop and execute new binary in container** - this cluster's whole job includes workloads that
  write and execute binaries (the agent's tooling, CI runner steps). `proc.is_exe_upper_layer` is
  true by design there, so the rule would be nothing but noise.
- **Network Connection outside Local Subnet** (upstream "unexpected outbound") - its scope list
  `namespace_scope_network_only_subnet` is empty upstream and the rule therefore cannot fire;
  populating it needs per-namespace profiling of this cluster's genuine egress. Contact with the
  cloud metadata service is included instead as a real, non-legitimate outbound signal.
- **Read sensitive file untrusted** / **Write below etc** - the rule bodies are small but drag in 42
  and 115 macros/lists of host exclusion logic, and both are host-wide rather than container-scoped.
- The rest of the upstream default set.

## Network policy

`network-policies.yaml` is default-deny plus two policies. falco: ingress only from the node LAN for
the kubelet probes, egress only to CoreDNS, to falcosidekick (pod and service ClusterIP), and to the
kube-apiserver (ClusterIP + node host ports, the container plugin resolves pod/namespace metadata).
falcosidekick: ingress only from falco pods and the kubelet, egress only to CoreDNS and Alertmanager
(namespace and ClusterIP - post- and pre-DNAT are both listed because either can be what the CNI
matches on).

## Verifying it, not just "pods Ready"

1. `kubectl -n falco logs daemonset/falco` - look for the driver choice and `Falco initialized`.
   A BTF problem appears here and nowhere else.
2. Confirm the load: the log names the rules file, and `falco` fails loudly on a bad rule.
3. Deliberate event, then check the consumer. Two options:
   - A real rule: `kubectl -n <ns> exec -it <pod> -- sh` spawns a shell with a TTY, which is
     `Terminal shell in container` (WARNING -> Discord). Needs a workload that has a shell and an
     operator allowed to exec; the agent's read-only RBAC cannot do it.
   - The paging path end to end: inject one alert into Alertmanager. This exercises routing, ntfy
     and the alert-detector wake, and it is the consumer that matters:
   ```
   curl -sS -X POST -H 'Content-Type: application/json' \
     -d '[{"labels":{"alertname":"FalcoPathCheck","severity":"critical"},"annotations":{"summary":"synthetic"}}]' \
     https://alerts.kube.stevearnett.com/api/v2/alerts
   ```
   A critical severity pages ntfy, so agree it with a human first. It auto-resolves after
   Alertmanager's 5m `resolve_timeout`.
4. `sum(rate(falco_...))` is not available: falco metrics are off (the chart's ServiceMonitor cannot
   select a chart-created Service - its selector expects a `type: falco-metrics` label the service
   template does not set). Watch the pods' CPU/memory by hand for the footprint claim.

## Known gaps / follow-ups

- **`Contact K8S API Server From Container` is still the firehose, and the allow-list now carries the
  cluster's whole API client set.** Swept twice on 2026-09-30. The first sweep (07:48Z-14:46Z, 1453
  events, all this rule) predates CRI enrichment, so `k8s.pod.name` and
  `container.image.repository` were null on everything before 08:50Z and no allow-list could match:
  headlamp 302, the agent's own `kubectl` 405, grafana's `k8s-sidecar` 228, kyverno 208, zot 56, the
  reconciler 253. The second sweep covered the widest window Loki holds (07:49Z-20:49Z, 1626 events)
  and confirms enrichment is the only cut that matters - after 08:50Z the sources were the
  reconciler's Jobs 252, longhorn's 1.13.0 rollout 176 (csi-provisioner 36, csi-resizer 18,
  csi-attacher 3, csi-snapshotter 3, longhorn-manager plus its csi-plugin and driver-deployer
  containers 134, post-upgrade Job 1), the kube-prometheus-stack admission hook 2 and one
  `kyverno-migrate-resources` Job 1. The longhorn burst is what prompted the expansion: 17 alerts were
  active at that moment, every one of them from `longhorn-system`. That list is now derived from RBAC
  rather than from incidents (every entry provably exists to drive the API server), so it should stop
  being a per-week drip - but it still depends on the plugin enriching
  `container.image.repository`, and the next legitimate API client needs an entry. The structural
  point is unchanged and stronger after the expansion: this cluster is default-deny, so "a container
  reached the API server" restates the NetworkPolicy egress inventory rather than adding anything to
  it - every client that *can* connect is one that was explicitly allowed to - and what the rule still
  reports is a container that is not an infrastructure controller. On this evidence the rule should
  probably be dropped from the curated set and the API-access question left to the NetworkPolicies;
  that decision wants a full day of enriched data, and the 20:49Z sweep is the widest window available
  so far.
- **A pathological command line still cannot be paged.** Falco has no truncation operator, so a
  critical rule whose `output:` carries `%proc.cmdline` can be pushed over ntfy's size limit by a long
  command line - an attacker with a padded cmdline silences their own page. Projected from the same
  measurements: a 1304-char output gives a 9268-byte body, well over the limit. Dropping
  `command=%proc.cmdline` from the two CRITICAL rule outputs is the lever if this ever fires in
  practice; keeping it is a deliberate trade for the evidence.
- **The container plugin enrichment is not yet proven.** The socket path is real (spegel mounts the
  same host path) and the plugin resolves configured sockets as `/host` + that path, but whether
  `k8s.ns.name`/`k8s.pod.name`/`container.image.repository` actually populate - and therefore whether
  `Launch Privileged Container` can fire - is only verifiable after the next reconcile, from a
  `kubectl -n falco logs ds/falco | grep k8s_ns_name` on a fresh event.
- The four upstream rules that detect a *privileged* or *hostPath* pod at admission time
  (`Launch Privileged Container` is `container_started`-based, i.e. runtime) need the k8saudit
  plugin, which needs an API-server audit webhook - a node-level change via `node-config/` (Ansible).
  Admission-time enforcement is Kyverno's job; this ticket is behaviour.
- Driver is privileged (chart default). `driver.modernEbpf.leastPrivileged: true` is the next step,
  but it changes which capabilities the probe needs and has to be verified per kernel before it is
  claimed to work.
