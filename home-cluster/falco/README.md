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
- `falcosidekick` 1 replica. No falcoctl init container and no artifact-follow sidecar: the
  container plugin (`libcontainer.so`) is bundled in the falco image (verified by listing the image
  layers of `falcosecurity/falco:0.45.0`), so nothing is downloaded at pod start and this namespace
  never talks to ghcr.io.

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

`expireafter: 300` gives each event an `endsAt` - Falco events have no end, and without it every
alert would stay active in Alertmanager forever. `dropeventdefaultpriority`/`dropeventthresholds` are
overridden away from the upstream defaults, which turn *any* dropped-syscall event into a critical
alert; only a five-figure drop count is critical here.

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

One deliberate deviation from upstream text: `user_privileged_containers` (upstream: `never_true`)
now lists the image repositories that legitimately run privileged in this cluster - read from the
running pods, not guessed: longhorn (manager/engine/instance-manager/csi-registrar), calico
(node/cni), the smb CSI driver, the runner's `docker:dind` sidecar, gluetun, jellyfin,
home-assistant (plus matter-server) and the adsb ultrafeeder. Without it, `Launch Privileged
Container` fires on every restart of ~15 pods that were already privileged; with it, the rule fires
only for a privileged container that is *new*, which is the signal worth having. `busybox` is
deliberately not listed even though two init containers use it privileged: "privileged busybox"
is exactly a shape an attacker would use.

Second deviation, same shape: `user_known_contact_k8s_api_server_activities` (upstream:
`never_true`) now excludes Headlamp, on `proc.name = headlamp-server` or the image repository
`ghcr.io/headlamp-k8s/headlamp`. It is the admin UI and its apiserver connections are expected.
The process name is in the condition because the container plugin resolves nothing on MicroK8s -
every event carries `container.image.repository=null` and `k8s.ns.name=null` - so an image-only
match is inert. Every other container connecting to the apiserver still fires.

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

- The four upstream rules that detect a *privileged* or *hostPath* pod at admission time
  (`Launch Privileged Container` is `container_started`-based, i.e. runtime) need the k8saudit
  plugin, which needs an API-server audit webhook - a node-level change via `node-config/` (Ansible).
  Admission-time enforcement is Kyverno's job; this ticket is behaviour.
- Driver is privileged (chart default). `driver.modernEbpf.leastPrivileged: true` is the next step,
  but it changes which capabilities the probe needs and has to be verified per kernel before it is
  claimed to work.
- After the first days: tune WARNING rules that prove noisy rather than muting the channel.
