# Per-alert links in Alertmanager notifications — working recipe

Everything below goes in `home-cluster/monitoring/alertmanager-external-secret.yaml`,
inside `spec.target.template.data['alertmanager.yaml']`.

## Receiver shape

```yaml
- name: discord
  discord_configs:
    - webhook_url: '<eso-rendered webhook_url>'
      send_resolved: true
      title: '<.Status | toUpper>'
      message: |- <see below>
```

`title` and `message` are the only useful formatting knobs. The Discord notifier's embed
struct is `Title`, `Description`, `Color`, plus optional `content`, `username`,
`avatar_url`, `http_config`. There is no embed URL field, so the title/card can never be a
link — every link is markdown inside `message`.

## ESO escaping (double templating) — do this mechanically

The file is a Go template evaluated by ESO, and its *output* is another Go template
evaluated by Alertmanager. Every Alertmanager directive must be emitted literally:

```
{{    ->  {{ "{{" }}
}}    ->  {{ "}}" }}
```

`{{ .webhook_url }}` is the exception: it is ESO's own variable and stays raw.

When scripting the edit, do a **token pass**, never sequential `.replace()`:

```python
esc = raw.replace('{{', '\x01').replace('}}', '\x02')
esc = esc.replace('\x02', '{{ "}}" }}').replace('\x01', '{{ "{{" }}')
esc = esc.replace('{{ "{{" }} .webhook_url {{ "}}" }}', '{{ .webhook_url }}')
```

A naive replace double-processes the text it just inserted. Verify by un-escaping the
result and diffing it against the raw template — round-trip must be byte-identical.

**Pitfall when locating the block to replace:** `orig.index('  data:')` also matches
`      data:` inside `spec.target.template`, so a substring match duplicates half the file
silently. Anchor on `'\n  data:\n'`.

## Message template with per-alert links

Per alert, four rows; the static portal row stays last as a fallback:

```
ROW 1: **[<alertname>](https://alerts.kube.stevearnett.com/#/alerts?filter=%7Balertname%3D%22<alertname>%22%7D)** [<severity>]
       · ns=<namespace> · pod=<pod> · <instance> · job=<job>   (each guarded with `if`)
ROW 2: <annotations.summary>
ROW 3: <annotations.description>
ROW 4: [<Kind>](https://headlamp.kube.stevearnett.com/c/in-cluster/<pluralKind>/<namespace>/<name>)
       · [Prometheus](<generatorURL>) [ · [Runbook](<runbook_url>) when set ]
```

Row 4's Headlamp link is a single `if / else if / else if ... / end` chain over the
resource labels, longest-lived first: `pod` → `node` → `deployment` → `daemonset` →
`statefulset` → fall back to `namespace`. Put the ` · ` separator **inside** each branch so
the row does not start or end with a separator. Alertmanager has no way to define a named
template inline here, so this stays one very long line — that is expected; yamllint's
line-length is set to `warning` in `home-cluster/yamllint.yaml` for exactly this file.

**Do not map the `job` label to a Headlamp Job link.** In Prometheus, `job` is the *scrape*
job (`apiserver`, `kube-state-metrics`); the Kubernetes Job label is `job_name`. Mapping it
produces confidently wrong links.

## Prerequisite: make generatorURL reachable

Prometheus builds `generatorURL` from its own URL. Without `externalUrl` the alert API
returns `http://kube-prometheus-stack-prometheus.monitoring:9090/graph?...`, which no
browser can open. Add under `prometheusSpec` in `kube-prometheus-stack-helmrelease.yaml`:

```yaml
prometheusSpec:
  externalUrl: https://prometheus.kube.stevearnett.com
```

No path component, so Prometheus' route prefix stays `/`; the StatefulSet rolls once for
the new `--web.external-url` arg. The `#/alerts?filter=` links do not depend on this and
can ship alone.

## Verify locally before opening the PR

A malformed template makes Alertmanager reject the config on reload — which stops Discord
notifications entirely. Render it locally first.

1. Read the **deployed** notifier version from the StatefulSet, then download that exact
   release tarball (`alertmanager-<v>.linux-amd64.tar.gz` from the Grafana/Prometheus
   GitHub releases). The tarball contains both `alertmanager` and `amtool`.
2. `amtool check-config alertmanager.yaml` — catches config and template parse errors.
3. Run the real binary against a local webhook sink and fire synthetic alerts at
   `/api/v2/alerts`, then read the captured payload and inspect the embed `description`:
   `alertmanager --config.file=... --storage.path=... --web.listen-address=127.0.0.1:9099`.
   In the test copy only: set `group_wait: 1s`, and point `webhook_url` at the sink.
   **Fire one alert per label shape** (pod / node / deployment / daemonset /
   namespace-only) — an alert re-sent with identical labels is *not* re-notified, so use a
   distinct alertname per test or the branch you are testing silently never renders.
4. Verify what ESO will actually render, not just the source file: un-escape the template,
   extract the `alertmanager.yaml` block out of it, and run `amtool check-config` on that.
5. `kubectl kustomize home-cluster/monitoring` for the manifest itself.

## Facts verified against this cluster (re-verify if versions move)

- Alertmanager image `quay.io/prometheus/alertmanager:v0.34.1`; its UI is the Elm app
  (`ui/app/`), whose bundle contains the `#/alerts?filter=` parser.
- Alerts carry `annotations.runbook_url` for every alert from the upstream
  kube-prometheus-stack rule set; the custom rules in `monitoring/prometheus-rules.yaml`
  have only `summary` / `description`, so guard that link with `if`.
- `https://alerts.kube.stevearnett.com/api/v2/alerts?active=true` is reachable from the
  Hermes pod and needs no auth; `kubectl services/proxy` is not permitted.
- Headlamp deep links resolve against the live cluster name `in-cluster`; the SPA serves
  `index.html` for unknown paths, so only a browser check proves a route is right.
