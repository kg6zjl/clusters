"App Passwords" for Gmail SMTP are created/managed here: https://myaccount.google.com/apppasswords

# Suppressing an alert

A paging alert that cannot be fixed right now - no image bump exists, the upstream fix is
unreleased, the noise is real but the remediation is a project - is suppressed in git, never by
creating an Alertmanager silence over the API. A silence is a runtime object: anyone who can reach
Alertmanager can create one behind your back, it is invisible in a review, and it lifts itself on
expiry whether or not anyone looked at the underlying finding.

The declarative mechanism is an Alertmanager inhibit rule with a sentinel alert as its source,
because an inhibit rule only fires while a source alert is firing and there is nothing else in
this config that says "this class is expected". Two edits, one PR:

1. `suppression-sentinels.yaml` (group `suppressions`), add an entry with `expr: vector(1)`, the labels
   that identify the class, and the reason plus the re-check date in the description. `severity:
   none` is required - the existing route tree sends it to the `null` receiver, so the sentinel
   itself notifies nothing.
2. `alertmanager-external-secret.yaml`, `inhibit_rules`: add a rule with
   `source_matchers: ['alertname = "<the sentinel>"']`, `target_matchers: ['...']` for the real
   alert, and `equal:` on the label that scopes it.

Deleting both entries un-suppresses the class in a diff a reviewer reads.

What this buys over a silence, and what it costs:

- The suppressed alert keeps firing. It shows in Prometheus, on the dashboard and - as
  `inhibited` - in the Alertmanager UI, so a re-check is a matter of looking rather than of
  remembering that a silence existed.
- The `alert-detector` never wakes the agent for it: the detector polls
  `/api/v2/alerts?active=true&silenced=false&inhibited=false`, so inhibited alerts are excluded
  from the wake path (the rule, the metric and the ntfy/Discord routes are untouched).
- There is no expiry. Alertmanager has no time-boxed inhibit, and a Prometheus alerting rule
  fires on the presence of a series rather than its value, so no expression can make its own
  series disappear at a date. The re-check date lives in the sentinel's annotation; nothing will
  enforce it. If a suppression must not outlive a date, that date is the thing to review.

Known limits, stated rather than assumed: `equal` is a fixed label set, so one inhibit rule covers
one class (all values of that label); a second class needs its own sentinel and its own rule. A
class whose identity labels change - a renamed alertname, a re-labelled metric - silently stops
being inhibited, and the sentinel then inhibits nothing while still showing as firing, which is
the visible half of the failure.

# Grafana admin access

The admin credential is the 1Password item `grafana-admin-password` (fields `username` and
`password`), synced by ESO into the secret `grafana-admin-secret`. Grafana reads that secret via
`admin.existingSecret`, and both sidecars read the same keys for their reload calls. Nothing else is
authoritative: if the item and the secret ever disagree, the secret is stale and ESO has not
reconciled it.

**A rotation is two steps, because Grafana applies `admin_password` when it creates the admin user,
not when it starts against an existing database:**

1. Change the password in 1Password. ESO refreshes within `refreshInterval` and Reloader restarts
   Grafana (`reloader.stakater.com/auto`), so the container env and the sidecars get the new value.
2. Realign the stored credential. Without this, every sidecar reload is rejected and Grafana's
   brute-force protection keeps the admin user locked:

   ```bash
   kubectl -n monitoring exec deploy/kube-prometheus-stack-grafana -c grafana -- \
     grafana cli admin reset-admin-password --password-from-env
   ```

   `--password-from-env` uses the value already in the container (`GF_SECURITY_ADMIN_PASSWORD`), so it
   aligns the database with the secret instead of inventing a third password.

A mismatch looks like this in `kubectl -n monitoring logs … -c grafana`:

```
msg="Failed to authenticate request" client=auth.client.basic error="[password-auth.failed] invalid password"
path=/api/admin/provisioning/dashboards/reload remote_addr=[::1]
error="too many consecutive incorrect login attempts for user - login for user temporarily blocked"
```

A sidecar retrying with a wrong password once a minute re-arms that lock, so logins fail even with the
correct password and the lock looks random. Fix the credential, never the lockout — do not disable
brute-force protection to work around it.
