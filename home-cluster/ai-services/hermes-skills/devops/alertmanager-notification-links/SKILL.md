---
name: alertmanager-notification-links
description: "Alert notification link/template changes: verify before PR."
category: devops
version: 1.0.0
author: Hermit
---

# Alertmanager notification links & template changes

**Use when:** asked to add/fix links in alert notifications, change alert message formatting,
or touch `home-cluster/monitoring/alertmanager-external-secret.yaml`.

## Where it lives

- Receiver config: `home-cluster/monitoring/alertmanager-external-secret.yaml` — an
  **ExternalSecret whose `spec.target.template.data['alertmanager.yaml']` is an ESO Go template**.
  ESO renders it, then kube-prometheus-stack feeds it to Alertmanager (`configSecret: alertmanager-config`).
- The Discord webhook URL is ONLY referenced via ESO (`remoteRef: discord-alertmanager-webhook`).
  Never inline it.
- Prometheus alert `generatorURL`s come from `prometheusSpec.externalUrl` in
  `kube-prometheus-stack-helmrelease.yaml`. **Without it they are in-cluster DNS names**
  (`http://kube-prometheus-stack-prometheus.monitoring:9090/...`) that no browser can open.

## ESO escaping rule (the #1 way to break this file)

The file is a Go template evaluated by ESO, and its output is *another* Go template evaluated by
Alertmanager. Every Alertmanager directive must be emitted literally:

```
{{                      ->  {{ "{{" }}
}}                      ->  {{ "}}" }}
{{ .webhook_url }}      ->  leave alone (this one IS the ESO variable)
```

Do the substitution mechanically (placeholder tokens, not naive `.replace('{{', ...)`) — a naive
replace double-processes the text it just inserted. Round-trip check: un-escape and diff against
the raw template.

## Link options that actually work

- **Discord embed cannot link its title.** Upstream `notify/discord` builds an embed with only
  `title`, `description`, `color`. No embed URL field exists. Every link must be markdown inside
  `message`, which Discord does render as clickable.
- **Link to the alert:** `https://alerts.kube.stevearnett.com/#/alerts?filter=%7Balertname%3D%22NAME%22%7D`
  (the UI's own "Link" button uses all labels; a matcher set is `{k="v", k2="v2"}`,
  percent-encoded). Verified against the running UI.
- **Link to the resource (Headlamp):** `https://headlamp.kube.stevearnett.com/c/in-cluster/<pluralKind>/<namespace>/<name>`
  (`pods`, `deployments`, `daemonsets`, `statefulsets`, `services`; cluster-scoped ones like
  `/nodes/<name>` and `/namespaces/<name>` take no namespace). Cluster name is `in-cluster` — it is
  the kubeconfig **context** name from `headlamp/kubeconfig.yaml`. SPA deep links work on direct load.
- **Per-alert extras:** `{{ .GeneratorURL }}` (needs externalUrl) and `{{ .Annotations.runbook_url }}`
  (only present on rule sets that define it — the stock kube-prometheus-stack rules do, the custom
  rules in `prometheus-rules.yaml` do not).
- **Do NOT map the `job` label to a Headlamp Job link.** In Prometheus, `job` is the scrape job
  (`apiserver`, `kube-state-metrics`); the k8s Job label is `job_name`.

## Verify before pushing (a bad template silently kills all Discord alerts)

Alertmanager rejects a malformed config on reload and notifications stop — so render it locally first.

```bash
B=https://github.com/prometheus/alertmanager/releases/download/vX.Y.Z/alertmanager-X.Y.Z.linux-amd64.tar.gz
# match the version of the DEPLOYED image (read it from the alertmanager StatefulSet, not from git)
```

1. `amtool check-config alertmanager.yaml` — catches config + template parse errors.
2. Run the real binary against a local webhook sink and POST synthetic alerts to
   `/api/v2/alerts`, then read the captured payload and inspect the embed `description`:
   `alertmanager --config.file=... --storage.path=... --web.listen-address=127.0.0.1:9099`.
   Set `group_wait: 1s` in the test copy, and fire ONE ALERT PER LABEL SHAPE (pod / node /
   deployment / namespace-only) — a repeated alert with identical labels is not re-notified, so
   use distinct alertnames when re-testing.
3. Confirm the rendered secret content, not just the source: un-escape the ESO template, extract the
   `alertmanager.yaml` block, and run check-config on *that*.
4. `kubectl kustomize home-cluster/monitoring` for the manifest itself.

## Pitfall: building the file with scripts

`orig.index('  data:')` matches `      data:` inside `spec.target.template` — a substring match
silently duplicated half the file. Anchor on `'\n  data:\n'`.

## Silent alert loss: Discord 429 is treated as UNRECOVERABLE

Alertmanager's Discord notifier uses a bare `notify.Retrier`, so a 429 is *not* retried
(`notify retry canceled due to unrecoverable error ... unexpected status code 429`) — that
notification is dropped, not delayed. Check the real numbers with metrics, not the pod logs
(the log ring buffer lies about history):

```
# failure ratio per integration — the >1% self-alerts key off this
sum(rate(alertmanager_notifications_failed_total[6h])) by (integration)
  / sum(rate(alertmanager_notifications_total[6h])) by (integration)
sum(increase(alertmanager_notifications_failed_total[6h])) by (integration, reason)
```

`AlertmanagerFailedToSendAlerts` / `AlertmanagerClusterFailedToSendAlerts` firing means
alerts were lost, and those very alerts also go to the rate-limited webhook.
