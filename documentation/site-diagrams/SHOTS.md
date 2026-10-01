# Screenshots

Three figures on the site are placeholders waiting for a real screenshot. Each one has a
**placeholder box** on the page right now — a dashed amber outline reading `Screenshot pending` — so
it is obvious at a glance which ones are outstanding, and the page cannot quietly ship with empty
boxes that read as design.

**Nothing here is finished until these are dropped in.** See *Turning a placeholder into a figure* at
the bottom.

---

## Read this before you screenshot anything

The repository is public, so the site is public. A screenshot of a real cluster UI leaks in ways a
grep of the HTML will never catch: node names in an axis label, a cluster name in a dropdown, a
hostname in a browser tab, a namespace in a sidebar. **Treat every screenshot as a document about to
be published to the internet**, not as a screenshot of your own dashboard.

Redact with a real tool, before saving, not in an image editor afterwards:

| Do | Don't |
| --- | --- |
| Blur or box out a value in the capture tool | Paste a redaction over it later |
| Use a throwaway window or a private window | Capture your whole desktop |
| Crop to the one panel that matters | Leave the browser chrome and tabs in |
| Check the file for embedded text afterwards | Assume it is fine because it looks fine |

Then run the same check that guards the prose, over the whole directory including images:

```bash
grep -rEn "([0-9]{1,3}\.){3}[0-9]{1,3}|@[a-z0-9.-]+\.[a-z]{2,}|[a-z0-9.-]+\.(com|net|org|io|local)" site/ \
  | grep -v "^\S*:[0-9]*:.*\(example\|schema\|w3\.org\|github\|docs\)"
```

That catches text in files, **not** pixels in a PNG. Cropping and blurring are what catch pixels.
If a value cannot be redacted without making the screenshot useless, the shot is not worth taking —
leave the placeholder and say why in the caption.

### The rule that decides borderline cases

Product names are fine. Category words are fine. Anything that describes **this network** rather than
**the mechanism** stays out: addresses, hostnames, domains, ports, usernames, node names, namespace
names, cluster names, and every credential value.

So "Prometheus", "Alertmanager", "Grafana" and "a node called `thinkcentre01`" are respectively fine,
fine, fine, and not.

---

## 1. The node dashboard

- **Page:** [`monitoring.html`](monitoring.html), in *Dashboards*
- **Save as:** `site/assets/img/shots/node-dashboard.png`
- **What it is:** the Grafana node dashboard — the one built in answer to "why does this node look
  unstable", and the single most-referenced object on the site.

**Frame:** the whole dashboard, full width, so the four questions read top to bottom:

- pressure stall (CPU / memory / IO)
- per-disk latency plotted **with** throughput — this is the panel the page argues for, and it is the
  reason the shot exists. If it is too wide to include legibly, crop to that panel and say so in the
  caption.
- memory, swap, and kernel kill counts
- reboot annotations

**Redact:** node names in the legend and on any axis; the time range is fine to keep; Grafana's user
name and the URL bar out of frame.

**Why it earns its place:** it is the visual proof of the site's most useful measurement opinion —
that latency alone is meaningless without throughput next to it. A reader who sees the paired panel
understands the argument faster than the prose makes it.

---

## 2. A firing alert in the channel

- **Page:** [`alerting.html`](alerting.html), in *What I've decided is not an alert*
- **Save as:** `site/assets/img/shots/alert-channel.png`
- **What it is:** a real rolled-up Alertmanager notification in the alerts channel.

**Frame:** the message and enough of the channel around it to prove the channel is the record — a
notification above and below, so "grouped, one message per problem, with history" is visible rather
than asserted.

**Redact:** every hostname, every workload name, every node name, and the server name in the header.
The severity, the alert name, the structure of the message and the presence of a link to the graph are
all the point — keep those.

**Why it earns its place:** it is the 1am artifact, and the page's whole argument is about whether that
artifact is worth reading. It has to be legible on a phone.

> Pick an alert that is *currently firing but benign* if you can. Do not stage a scary one to make the
> screenshot look good, and do not use the agent's own wake as the subject — the page argues that
> path is deliberately narrow, and a screenshot of it firing would contradict that.

---

## 3. A pull request opened by the agent

- **Page:** [`workflow.html`](workflow.html), in *Who may merge what*
- **Save as:** `site/assets/img/shots/agent-pr.png`
- **What it is:** a real pull request the agent opened, showing the checks and the merge control.

**Frame:** the pull request header — title, **author**, checks, and the merge button. The author is the
entire point; make sure it is legible.

**Redact:** the repository owner and name, the branch name if it contains a machine name, and any
path in the diff that exposes a network detail. Check every **comment** in the thread, not just the
description — the agent posts its reasoning there, and that reasoning quotes the output it read.

**Why it earns its place:** it is the one screenshot that shows a *different identity* authoring a
change, which is the claim `workflow.html` makes most forcefully. If the author and the reviewer look
the same in the shot, the figure proves nothing and should not ship.

---

## Optional, if you have time

Not required, and the pages read fine without them. Add one only if it is easy.

- **A Kyverno policy test failing in CI** — `guardrails.html`. The `Kyverno policy tests` check with a
  red result is more convincing than any amount of prose about refusing a widened role. Save as
  `shots/kyverno-test.png`.
- **The Flux UI** — `stack.html`. Shows that the reconciler is a thing you can look at. Lower value
  than the three above, and it is the single most likely screenshot to leak a domain in its URL bar.

---

## Turning a placeholder into a figure

1. Save the capture at `site/assets/img/shots/<name>.png`.
2. Export at **2× and no larger than 1600px wide.** The page is dark; a 3× phone screenshot is a 4000px
   file that costs every reader the bandwidth to show at 900px.
3. In the page, replace the whole `<figure class="shot">` block — the placeholder `<div>` and its three
   spans — with a real `<img>`. Keep the `<figcaption>`; it is written to stand on its own.
4. Give the `<img>` a real `alt`. Write it as a description of the picture, not a caption: someone
   using a screen reader gets the alt and skips the figure, so it has to stand alone. Every diagram on
   the site has one written that way — copy the register.
5. Run the sanitisation grep above, then open the file and look at it.

To find them all:

```bash
grep -rn "shot-pending" site/*.html
```

---

## Why no diagram screenshots

Every diagram on the site is a Mermaid source file rendered to SVG by a pinned image, so they are
text, they are reviewed as diffs, and they cannot drift out of sync with the prose. See
[the diagram README](README.md). Do not screenshot a diagram — edit the `.mmd` and re-render:

```bash
cd documentation/site-diagrams && task diagrams
```
