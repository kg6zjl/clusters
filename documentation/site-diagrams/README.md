# Diagrams

Every diagram on the site is a Mermaid source file in here, rendered to an SVG committed to
`site/assets/img/`. That means a diagram is text, it is reviewed as a diff, and it cannot quietly
drift out of sync with the paragraph next to it — which is the failure mode of every diagram I have
ever watched go stale.

The rendered SVGs are **committed, not built at publish time**. The site stays static HTML and CSS
with no build step and nothing to install: Pages uploads `site/` and publishes it as it sits. All of
this lives under `site/` only so the diagrams and their render are versioned next to the pages that
use them.

## Changing one

Edit the `.mmd` and re-render. Commit both the source and the SVG.

```bash
cd documentation/site-diagrams && task diagrams
```

That builds the renderer image and renders every source into `site/assets/img/`. To iterate on one
diagram without the container:

```bash
npx -y @mermaid-js/mermaid-cli@11 -i src/loop.mmd -o /tmp/loop.svg -c mermaid.config.json
```

## Adding one

1. Write `src/<name>.mmd`. Reference it from a page with the `<figure class="shot">` block below.
2. `task diagrams`.
3. Copy the rendered `width` and `height` from the SVG's `viewBox` into the `<img>` tags. They are in
   the SVG's `viewBox` attribute and in the render log; without them the page shifts as images load.

```html
<figure class="shot">
  <img src="assets/img/<name>.svg" alt="A description of the picture, standing on its own — someone
  using a screen reader skips the figure entirely." width="960" height="918" loading="lazy">
  <figcaption><strong>Title.</strong> What the reader should take from it.</figcaption>
</figure>
```

## Two rules that will waste an afternoon if you forget them

**The diagram declaration must be the first line.** Mermaid 11.x collapses newlines when a file opens
with a `%%` comment block and then fails with a parse error that points at line 1 and shows your
comment as a node. Put the explanatory `%%` comments *after* the `flowchart` line, where they work
fine.

**Keep diagrams about 1000–1300px wide.** Below that the labels are huge and it reads as a poster;
above it, shrunk to fit a phone, a 15px label lands at 9px and is unreadable. Check the width after
rendering:

```bash
grep -o 'viewBox="[^"]*"' site/assets/img/<name>.svg
```

To narrow a diagram, use `direction LR` inside a subgraph to pack a group into one row, and `~~~`
between subgraphs to force them to stack vertically instead of sitting side by side. Both are used in
`src/system.mmd`, which is the widest thing here and is still readable.

## The renderer image

`Dockerfile` here builds a pinned mermaid-cli on Debian with Chromium. It exists because the agent
runs in a pod with no internet egress and therefore cannot `npm install` anything at runtime — so
anything that needs to render has to arrive as an image.

```bash
task diagrams            # build and render locally
task diagrams:build      # just build, tagged for the cluster registry
task diagrams:push       # build and push, for the in-cluster agent to use
```

CI builds and pushes it to the cluster registry on any change here (`.github/workflows/diagrams.yaml`),
tagged by commit and never `:latest`, so the agent can render without reaching the internet. It is
kept out of the required checks on purpose, for the same reason the runner image build is: a publish
should be able to fail without blocking a pull request that has nothing to do with it.

## Layout conventions

Worth keeping, because a reader who learns the notation once should be able to read every diagram:

- **solid arrow** — can cause
- **dashed arrow** — can cause, and the tail cannot act back
- **doubled node border** (`classDef control`) — a control that decides whether an arrow is allowed

`mermaid.config.json` is what makes the output match the site: the same background, ink and accent
colours as `assets/style.css`, and monospace labels. If you change one, change both.

## Files

This directory is the tooling and the sources. It is deliberately **not** inside `site/`: Pages
publishes every file under `site/`, so anything placed there would ship to readers — and this
directory is full of the registry hostname. Only the rendered output goes in the site.

```
documentation/site-diagrams/
  Dockerfile              pinned mermaid-cli + Chromium
  mermaid.config.json     the site's theme, shared with site/assets/style.css
  puppeteer.config.json   Chromium flags - the container runs as root, so it needs --no-sandbox
  normalize-svg.js        strips Mermaid's inline sizing so the page's CSS owns it
  render.sh               renders every .mmd, and fails loudly rather than partially
  Taskfile.yaml           task diagrams, and the three checks over the site
  SHOTS.md                the screenshot shot list — what to capture and what to redact
  src/*.mmd               the diagrams themselves — the only files to edit by hand
```

Output, committed to the site:

```
site/assets/img/*.svg     the rendered diagrams the pages reference
```

## The render is reproducible, and that is the point

Same source plus same pin gives a byte-identical SVG — verified, not assumed. Two things make it
true, and both are easy to break by accident:

- **The Mermaid version is pinned.** A diagram that re-renders differently after an upstream release
  is worse than no build step, because the committed SVG stops matching its own source and the
  staleness check starts crying wolf until someone learns to ignore it.
- **The generated id is re-keyed per file.** Mermaid stamps the literal `my-svg` on every diagram it
  renders, and scopes all of its themed CSS to that id. Left alone, a diagram on a page with another
  diagram on it inherits the wrong rules. `normalize-svg.js` replaces the token everywhere it
  appears — selector, root id, and the marker ids that `url()` resolves through — and then refuses to
  write a file whose themed rules have gone dead. It cost a whole commit to find that one; the
  assertions at the bottom of that file are the reason it will not cost another.

If `task diagrams` produces a diff you did not expect, the pin moved. Check `git diff` on the SVGs
before you assume it is harmless.
