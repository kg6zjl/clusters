# Alertmanager Config in Git — and Verifying It Took Effect

Monitoring config is a git-managed artifact here (via an ESO-templated ExternalSecret), so alerting
changes are PR-able like anything else. This file covers where that config lives, how to make alerts a
human can act on, and how to verify a merged change is actually live.

## The Alertmanager config is in git — check before claiming otherwise

- `monitoring/alertmanager-external-secret.yaml` is an ExternalSecret whose
  `spec.target.template.data['alertmanager.yaml']` holds the whole rendered config. Only the Discord
  webhook URL comes from 1Password (`remoteRef` + `{{ .webhook_url }}`).
- So routes, receivers, message templates and `inhibit_rules` are all PR-able with no secret handling.
  Never tell the user "that lives in a secret, I can't PR it" without reading the ExternalSecret first.
- ESO's template layer is itself a Go template, so **nested** Go templates are escaped: `{{ "{{" }}`
  emits a literal `{{`, `{{ "}}" }}` emits `}}`. Preserve that escaping when editing messages/titles.

## Making an alert worth reading

A template like `{{ .Labels.job }} [{{ .Labels.severity }}] {{ .Annotations.summary }}` renders as
`[none] Info-level alert inhibition.` for any alert with no `job` label — unreadable, and it arrives on
every repeat interval. Rules:

- Never lead a message with a label that may be absent. Guard every optional label:
  `{{ if .Labels.pod }} · pod={{ .Labels.pod }}{{ end }}`.
- Include: alertname (bold), severity, whichever of `namespace` / `pod` / `instance` / `job` exist,
  then `summary`, then `description`.
- End with one line of deep links (Alertmanager, Prometheus, Grafana, Headlamp). **Curl each host from
  inside the cluster first** — a dead link in a notification is worse than no link.
- Alertmanager normalizes matcher spacing when it dumps config (`node=~"x"`, never `node =~ "x"`).
  Verify against the normalized form or your check reports a false negative.

## severity="none" is not for a human channel

- kube-prometheus-stack ships `Watchdog` and `InfoInhibitor` with `severity="none"`; `InfoInhibitor`'s
  own annotation says it *should be routed to a null receiver*. Route `severity = "none"` to a receiver
  with no configs, or they repeat forever and train people to ignore the channel.
- `InfoInhibitor` is meaningless without the stock inhibit set: with no `inhibit_rules`, info-level
  alerts are never inhibited even though the rule exists to signal exactly that condition. Add
  critical→warning, critical→info, warning→info with `equal: ['namespace','alertname']`.

## Verify the whole chain, not the merge

1. Live rendered config: `GET http://<alertmanager-svc>:9093/api/v2/status` → `.config.original`.
   Reach it by ClusterIP from inside the cluster (`kubectl get svc -n <ns>`); port-forwarding is neither
   required nor always permitted.
2. Which rule produced an alert: `GET http://<prometheus-svc>:9090/api/v1/rules?type=alert` (search the
   JSON by name/summary), and `.../api/v1/alerts` for what is firing with which labels.
3. Propagation is a chain: **Flux applies the ExternalSecret → ESO re-renders the Secret →
   Alertmanager's config-reloader reloads with no pod restart.** A merge is followed by a window where
   the old config is still live. Re-read the live config before claiming the fix landed, and state which
   of "merged" or "live" you actually observed.

## Two YAML/template traps that break a config silently

- A receiver named `null` must be quoted (`name: "null"`, `receiver: "null"`); unquoted, YAML parses it
  as the null value and the receiver name comes out empty.
- Go templates in a nested-escaped document are easy to unbalance; count the braces.

## Validate before shipping

Simulate what ESO does, then parse the result — this catches escaping and structure bugs YAML lint
cannot see:

```python
import yaml
doc = yaml.safe_load(open("home-cluster/monitoring/alertmanager-external-secret.yaml"))
tpl = doc["spec"]["target"]["template"]["data"]["alertmanager.yaml"]
rendered = (tpl.replace('{{ "{{" }}', '{{').replace('{{ "}}" }}', '}}')
               .replace('{{ .webhook_url }}', 'REDACTED'))
cfg = yaml.safe_load(rendered)
names = {r["name"] for r in cfg["receivers"]}
assert all(r["receiver"] in names for r in cfg["route"]["routes"]), "route points at a missing receiver"
assert cfg.get("inhibit_rules"), "inhibit rules missing"
msg = cfg["receivers"][-1]["discord_configs"][0]["message"]
assert msg.count("{{") == msg.count("}}"), "unbalanced template braces"
```

Go template syntax itself cannot be fully validated locally — keep to `range` / `if` / `end` and plain
field lookups, and tell the user the first real notification is still worth eyeballing.

## Diagnostic discipline for alerts

Two different causes can produce an identical `[none] …` message (a `severity="none"` self-test alert
versus a missing label). Identify which alert actually fired — rule name, labels, annotations — before
proposing a fix. Report the mechanism plus the API evidence, not the symptom.
