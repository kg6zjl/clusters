# The public site

Static HTML and CSS. **No framework, no build step, no dependencies** — `site/` is published as it
sits in this directory, so there is nothing to install, nothing to version-pin, and nothing that can
break because an upstream theme moved.

```
site/
  index.html            the model: reach without authority
  limits.html           read-only RBAC, no secret access, credential scope
  network.html          default-deny, the API-server trap, egress paths
  state.html            disposable pod, worktree discipline, the self-repair trap
  skills.html           the agent's knowledge, versioned in git
  workflow.html         the PR loop, and the mechanics that waste an afternoon
  secrets.html          vault to workload, one path, no copies
  paging.html           two receivers, no single point of silence
  runners.html          CI as a cluster citizen, and its outstanding hole
  interesting.html      patterns worth stealing
  proud.html            what held up, and what has not
  checklist.html        build your own, in order
  assets/style.css      one stylesheet, both colour schemes
  .nojekyll             serve the files as-is; no Jekyll processing
```

## Deploying

`.github/workflows/pages.yaml` uploads `site/` as a Pages artifact and deploys it **on pushes to
`main` only**. A pull request cannot trigger a publish.

**One-time repository setting (a human, not the agent):** *Settings → Pages → Build and deployment →
Source* must be **GitHub Actions**. The API cannot set it from an agent's token, and until it is set
the deploy job fails with a clear error. After that, the first merge touching `site/**` publishes and
the job prints the URL.

## Editing

Py edit any page directly. Keep the shared `<nav class="topnav">` block identical across pages (it is
the only duplicated markup) and the "previous / next" links in each footer in step with the nav
order.

## This directory is public — sanitize before you push

The repository is public, so the site is public, and it is the one artifact here that is written
*for* strangers. Before pushing, scan `site/` for anything that describes the network rather than the
mechanism:

```bash
grep -rEn "([0-9]{1,3}\.){3}[0-9]{1,3}|@[a-z0-9.-]+\.[a-z]{2,}|[a-z0-9.-]+\.(com|net|org|io|local)" site/ \
  | grep -v "^\S*:[0-9]*:.*\(example\|schema\|w3\.org\|github\|docs\)" | head
```

Expected to be clean. Addresses, hostnames, domains, ports, usernames, emails and secret values stay
out; describe the category ("the API server is a host process", "a shared file share on a NAS")
instead. Product names are fine — they are public OSS or public services.

The same rule applies to the site's own history: a leak removed in a later commit is still public in
the earlier one, so treat a leak here as a credential-rotation event, not a typo.
