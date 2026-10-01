# The public site

Static HTML and CSS, published as it sits. **No framework, no build step, no dependencies** — nothing
to install, nothing to pin, and nothing that breaks because an upstream theme moved.

Dark only, by request. One stylesheet, one accent, system fonts.

```
site/
  index.html        why this exists, what the agent has done, what it costs, what's still broken
  guardrails.html   permissions, secrets, networking, admission, disposable state
  monitoring.html   what's measured and why that list is short
  alerting.html     the pipeline, the receivers, and what's not an alert
  workflow.html     how a change actually reaches the cluster
  assets/style.css  one stylesheet, dark only
  .nojekyll         serve the files as-is; no Jekyll processing
```

It was thirteen pages. It's five, because the reader came for four things: what holds this together,
what it watches, how it tells you, and how a change gets in. Anything that didn't serve one of those
became a section on a page that did.

## Deploying

`.github/workflows/pages.yaml` uploads `site/` as a Pages artifact and deploys it **on pushes to
`main` only**. A pull request cannot trigger a publish.

**One-time repository setting (a human, not the agent):** *Settings → Pages → Build and deployment →
Source* must be **GitHub Actions**. The API cannot set that from an agent's token, and until it is set
the deploy job fails with a clear error.

## Editing

Edit a page directly. Keep the `<nav class="topnav">` block identical across pages (it is the only
duplicated markup — run the nav check in the verification recipe rather than trusting your eyes) and
keep each footer's prev/next links in step with the nav order.

The voice is the point, and it's easy to lose: plain English, first person, short sentences, no hype.
If a sentence only warms up or hedges, cut it. Say what broke and what it cost.

## This directory is public — sanitize before you push

The repository is public, so the site is public, and it's the one artifact here written *for*
strangers. Scan `site/` for anything describing the network rather than the mechanism:

```bash
grep -rEn "([0-9]{1,3}\.){3}[0-9]{1,3}|@[a-z0-9.-]+\.[a-z]{2,}|[a-z0-9.-]+\.(com|net|org|io|local)" site/ \
  | grep -v "^\S*:[0-9]*:.*\(example\|schema\|w3\.org\|github\|docs\)" | head
```

Expected to be clean. Addresses, hostnames, domains, ports, usernames, emails and secret values stay
out; describe the category ("the API server is a host process", "a shared file share on a NAS")
instead. Product names are fine — public OSS or public services.

The same rule applies to the site's own history: a leak removed in a later commit is still public in
the earlier one, so treat a leak here as a credential-rotation event, not a typo.
