# site/

The public GitHub Pages site for this home cluster.

- **Static, hand-written HTML/CSS.** No framework, no build step, no dependencies to
  audit or keep current. `index.html` plus `assets/style.css`.
- **Deployed by workflow, not by hand.** `.github/workflows/pages.yaml` uploads this
  directory as a Pages artifact on every push to `main` that touches `site/`.
- **Deliberately abstract.** This repository is public, so the site carries no
  addresses, no hostnames, no domain names, no ports, no credentials and no personal
  data. Topology is described in words ("three nodes", "a shared file share on a NAS").

## One-time setup (repo admin)

Set **Settings → Pages → Build and deployment → Source** to **GitHub Actions**. The
deploy workflow cannot create the Pages site itself; it only publishes to a site that
already exists. After that, the first push to `main` touching `site/` goes live, and
the workflow's URL appears on the job summary.

## Previewing locally

Open `site/index.html` in a browser, or serve the directory:

```
python3 -m http.server -d site
```

(the port is whatever the local server prints — nothing here binds a fixed port).
