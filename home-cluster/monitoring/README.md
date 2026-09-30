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
