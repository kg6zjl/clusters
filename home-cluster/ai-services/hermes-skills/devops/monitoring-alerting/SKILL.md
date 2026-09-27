---
name: monitoring-alerting
description: "Alerting stack: routing, notifiers, alert deep links."
category: devops
version: 1.0.1
author: Hermit
license: MIT
metadata:
  hermes:
    tags: [monitoring, alerting, prometheus, alertmanager, grafana]
    related_skills: [cluster-operations, gitops-cluster-management, dns]
---

# Monitoring & Alerting Stack

## When to Use

The request is about firing alerts, alert routing, notification content or formatting, the
Discord notification bot, Grafana/Prometheus dashboards, or anything in the `monitoring`
namespace. Also load the `cluster-operations` skill — every change here is still PR-only.

## Where the config lives

- `home-cluster/monitoring/` — kube-prometheus-stack HelmRelease, prometheus rules, IngressRoutes, per-service dashboards.
- **Alert routing and notification templates are NOT in a plain manifest.** They live in `monitoring/alertmanager-external-secret.yaml` as an **ESO `target.template`** — the whole `alertmanager.yaml` is a Go template inside `spec.target.template.data`. The rendered Secret is `alertmanager-config` in `monitoring`, wired to the Alertmanager StatefulSet via `alertmanagerSpec.configSecret` in `kube-prometheus-stack-helmrelease.yaml`.
- The Discord webhook URL is a 1Password item (`discord-alertmanager-webhook`) pulled in as `webhook_url` — never commit it, never print it.

**Pitfall — double templating:** because the file is an ESO template, every Alertmanager template expression must be escaped, otherwise ESO renders it server-side and Alertmanager receives garbage. Copy the escaping style already used in that file; do not write raw `{{ .Labels.x }}` there.

## Read-only inspection (what actually works)

Alerts and rules are reachable from the Hermes pod over the public hostnames — those IngressRoutes are **not** behind oauth2-proxy, so plain curl works:

```bash
curl -s 'https://alerts.kube.stevearnett.com/api/v2/alerts?active=true' | python3 -m json.tool
curl -s 'https://prometheus.kube.stevearnett.com/api/v1/rules?type=alert'
```

**Pitfall:** `kubectl get --raw .../services/http:<svc>:9093/proxy/...` is **Forbidden** — the Hermes ServiceAccount has no `services/proxy` permission. Do not burn calls on it; use the public API endpoints above. If curl fails instead, check the monitoring namespace NetworkPolicy — the Hermes namespace egress policy must allow it.

Get versions and labels from the running workloads, not from the chart:

```bash
kubectl get sts -n monitoring -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

## "Mute host X forever" — silence or void-route? Decide by lifespan

- Temporary (days — e.g. a host pending decommission): an AM silence via UI/API. Zero config change, auto-expires; it is not GitOps and dies with the AM storage, which is fine for the short window.
- Must survive rebuilds: a declarative **void receiver** (a receiver entry with no integrations) behind sub-routes with `continue: false`, matched on every shape the host appears as: `node` / `kubernetes_node` / `hostname` = node name, plus `instance` regex on its LAN IP. This is the GitOps answer to "forever" — the AM API refuses a truly permanent silence (endsAt must be future).
- A void route MUST carry its expiry in the PR body: the decommission PR deletes the route, else the mute outlives the host and silently swallows anything reusing those label values.
- Label matchers cannot catch alerts without host labels (cluster-scoped Job/DaemonSet rules) — no mute mechanism, silence included, will cover those; say so and point at the underlying fix.
- **Removing a void route is part of the fix, not housekeeping.** The fix that removes the cause is the PR that deletes the route — one PR can carry both (the host leaving *and* its mute). Check the routed alerts have actually **resolved** first (`curl -s 'https://alerts.kube.stevearnett.com/api/v2/alerts?active=true'`); taking a mute down while the noise still fires just restores the spam. After deleting, confirm every surviving route still names a receiver that exists in `receivers` — a route pointing at a deleted receiver makes Alertmanager reject the entire config, which stops every notification, not just that one.
- Never fork upstream PrometheusRules to exclude a node — that inherits maintenance on every chart rule change.

## Changing alert routing or notification content

PR only, same as every other change. Before proposing a change, read `alertmanager-external-secret.yaml` end to end — routing tree, inhibit rules, and receivers all live in that one file, and a fix that ignores the `severity = "none"` → null route or the inhibit set will regress the noisy-alert problem those rules exist to solve.

## Answering "can the notification link to X?"

Do not answer from intuition — the answer depends on the notifier's wire format. Verify in this order:

1. **Find the current links in the config.** If a link row already appears in the message, it is a hardcoded literal inside the receiver's `message` template, not generated per alert.
2. **Check the notifier's embed fields for the deployed version** — read the notifier source for that release, e.g. `https://raw.githubusercontent.com/prometheus/alertmanager/main/notify/discord/discord.go`. For the Discord receiver the embed carries only `Title`, `Description`, `Color`: there is **no embed `url`**, so the card/title can never be clickable — links must be markdown inside the `message` body (Discord renders those).
3. **Check the per-alert data really exists** via the live alert API: `generatorURL` and `annotations.runbook_url` are present on almost every alert.
4. **Check the link target is browser-reachable.** `generatorURL` is built from Prometheus' own URL, which by default is the **in-cluster service DNS name** (`http://kube-prometheus-stack-prometheus.monitoring:9090/graph?...`) and is dead for a human. Fix is `externalUrl: https://prometheus.kube.stevearnett.com` under `prometheusSpec` in the HelmRelease. Any per-alert `generatorURL` link is broken until that is set.
5. **Alertmanager deep links work, but the matcher must be brace-and-quote wrapped.** The UI builds `#/alerts?filter=` from a matcher *set*, and its parser requires the braces and the JSON-quoted value — a bare `filter=alertname%3DTargetDown` parses to nothing and silently shows an unfiltered list. The verified shape is:
   `https://alerts.kube.stevearnett.com/#/alerts?filter=%7Balertname%3D%22<Alertname>%22%7D`
   Take the format from the source, not from memory: the alert list's own link button is `ui/app/src/Views/AlertList/AlertView.elm`, and it serialises through `Utils/Filter.elm` (`stringifyMatcher` = `key + operator + Encode.string value`, `stringifyFilter` wraps the comma-joined list in `{...}`). Confirm the *deployed* UI still parses the param by grepping the live bundle — the UI is a SPA, so curl of the HTML proves nothing:
   ```bash
   curl -s https://alerts.kube.stevearnett.com/ | grep -o 'src="[^"]*"'      # find the asset
   curl -s https://alerts.kube.stevearnett.com/assets/<bundle>.js | grep -o '#/alerts?filter='
   ```
   The JS served by the running instance is the authoritative answer for that version — do not cite docs or memory for it.
6. **Headlamp per-resource deep links are verified for this cluster** — `/c/in-cluster/<pluralKind>/<namespace>/<name>` (`pods`, `deployments`, `daemonsets`, `statefulsets`, `services`), with `namespaces/:name` and `nodes/:name` for cluster-scoped kinds. The cluster segment is the kubeconfig **context** name (`in-cluster`), not a display name — read it from `headlamp/kubeconfig.yaml`. Derive the route list from the running UI's own bundle (`grep -o 'path:"/[^"]*"'`) and then confirm by *loading* one deep link in a browser and checking the object actually renders: the SPA server returns `index.html` for any path, so an HTTP 200 proves nothing. Run that same two-step check before promising Grafana links, and do not guess a URL shape for any other SPA.

Only after 4 and 5 are settled is "yes, and here is the diff" an honest answer; otherwise state which half is blocked.

See `references/alert-notification-recipe.md` for the working receiver snippet, the exact edit that wires per-alert links, the ESO escaping mechanics, and the local end-to-end verification recipe (run the real notifier against a webhook sink before opening the PR).
