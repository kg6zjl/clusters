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

**A `%%` comment line must have text on it.** A bare `%%` line — the obvious way to leave a blank
line inside a comment block — is not a comment to Mermaid 11.x. It parses as a *node*, and the
diagram renders with a small box labelled `%%` sitting in the middle of it. The render succeeds, so
nothing warns you: seven diagrams shipped with one of these before `render.sh` started checking. Use
an empty line to separate paragraphs instead, and if you do use `%%`, put words after it.

```
%% this is a comment and is stripped
%%
%% this is a node, and you will see it
```

**The diagram declaration must be the first line.** Mermaid 11.x collapses newlines when a file opens
with a `%%` comment block and then fails with a parse error that points at line 1. Put the
explanatory `%%` comments *after* the `flowchart` line.

**Keep diagrams under about 1300px wide.** Below that labels are large enough to read; above it,
shrunk to fit the figure, a 15px label lands under 11px and is hard to read. Narrow is safe —
`normalize-svg.js` caps each diagram at its natural width, so a narrow one renders at full size with
15px labels rather than being stretched. Wide is the problem. Check the width after rendering:

```bash
grep -o 'viewBox="[^"]*"' site/assets/img/<name>.svg
```

Read that as a ceiling rather than a target. On ELK the widest diagram here is 836px, so there is
room to add boxes again — which is exactly the temptation that turned an overview into an inventory.
If a diagram needs to grow past the ceiling, the fix is splitting it into two figures, not another
pass on the labels.

To narrow a diagram, use `direction LR` inside a subgraph to pack a group into one row, and `~~~`
between subgraphs to force them to stack vertically instead of sitting side by side. `~~~` is what
keeps `src/guardrails.mmd` from fanning out sideways.

One trap worth knowing: **do not point an edge at a specific node inside a wide subgraph.** Aiming an
arrow at a box in the middle of a row once made a diagram 450px wider than the same arrow aimed at
the first box — Mermaid routes the edge around the whole group. Same diagram, same meaning, 30% more
width.

`src/patching.mmd` is the live example: it aims its lane arrows at `reboot` and `pins`, the last node
in each lane, rather than at the subgraph. A subgraph-to-node edge is drawn from the bottom edge of the
box, so it reads as though the box itself were the thing carrying the change into review.

## Colour

`mermaid.config.json` sets the theme — background, ink, accent, fonts — to match
`site/assets/style.css`. Colour that carries *meaning* is a `classDef` in the `.mmd` instead, and
there are only five, used the same way in every diagram:

| class | fill | stroke | means |
|---|---|---|---|
| `ok` | `#17251d` | `#4f8f6a` | the path that works: merged, applied, delivered |
| `bad` | `#261a1a` | `#bb6552` | the path that fails, or the edge that must never exist |
| `warn` | `#262013` | `#a98a3c` | expected, but worth noticing: a page, a restart |
| `control` | `#121820` | `#71b7ff` | a gate that decides whether anything downstream happens |
| `store` | `#121820` | `#6b7885` | a datastore, or an inventory row |

They are matte on purpose: mid-tone borders on the dark background rather than saturated fills, so
a diagram with five colours in it still reads as one drawing. All text sits above 12:1 contrast on
its fill and every border above 4.5:1 on the page background, which is why the fills are dark rather
than coloured — a light fill would drag the label contrast down with it.

Colour is not decoration, so do not add a classDef because a diagram feels flat. Every diagram here
that uses colour is using it to say one of those five things. `src/guardrails.mmd` is deliberately
all one colour: colouring five controls differently would imply a ranking between them, which is the
opposite of what that figure argues.

To colour an **edge** rather than a node, `linkStyle N` takes an index into the *rendered* link
order — not the order the arrows appear in the file, which is the mistake to expect. Reordering
arrows above a `linkStyle` will recolour the wrong edge silently. There are three coloured edges in
here; after re-rendering, check `git diff` on the SVG and confirm the colour is still on the edge you
meant. `loop.mmd` has the notes.

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
- **blue border** (`classDef control`) — a control that decides whether an arrow is allowed
- **green border** (`classDef ok`) — the step where something actually changes
- **red border or arrow** (`classDef bad`) — a step that fails, or an edge that must never exist
- **amber border or arrow** (`classDef warn`) — expected, and worth noticing rather than paging

The same five classes mean the same thing in all seven diagrams. See **Colour** above for the values
and the reasoning; the short version is that a reader should not have to open the source to know
whether a colour is decoration.

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

## The layout engine is ELK, and that is a pinned decision

`mermaid.config.json` sets `"layout": "elk"`. Mermaid's default is `dagre`, and the difference is not
cosmetic: on a map with edges crossing between groups, `dagre` laid a representative 25-node cluster
diagram out at 2218px wide and ELK laid the identical source out at 1278px. Dagre is fine on the small
single-purpose diagrams here and genuinely bad at anything dense, which is why the width ceiling above
used to be hit by the overview diagram rather than by anything else.

ELK is **bundled inside the `mermaid` package** rather than installed as a separate dependency, so
there is nothing extra in the `Dockerfile` to fetch — but that makes "does this build have ELK" a
property of the `mermaid` pin and nothing else. `mermaid-cli` depends on `mermaid@^11.0.2` and does not
constrain it, so pinning only the CLI left the renderer floating to whatever the newest 11.x happened
to be. If `mermaid` floated to a version without bundled ELK, every diagram would silently fall back to
dagre and redraw at a different size — a diff nobody could explain, which is the failure mode this
whole directory is built to avoid.

Two consequences worth knowing before the next bump:

- **`linkStyle N` indexes the *rendered* link order**, so an engine change can move a colour onto the
  wrong edge. `src/loop.mmd` carries three coloured edges and the note in it saying which edge each
  index must land on; after any re-render, confirm it, because `git diff` on the SVG shows the
  colour but not which arrow moved.
- **Widths change on an engine switch.** Re-copy the `width`/`height` into each `<img>`; `task check`
  will fail until you do, which is the intended way to find out.

## The render is reproducible, and that is the point

Same source plus same pin gives a byte-identical SVG — verified, not assumed. Two things make it
true, and both are easy to break by accident:

- **The Mermaid version is pinned, and pinned separately from the CLI.** A diagram that re-renders
  differently after an upstream release is worse than no build step, because the committed SVG stops
  matching its own source and the staleness check starts crying wolf until someone learns to ignore it.
  `MERMAID_CLI_VERSION` alone does not achieve this — the CLI accepts any `11.x` of mermaid — so
  `MERMAID_VERSION` is pinned alongside it, and that is also what pins the layout engine.
- **The generated id is re-keyed per file.** Mermaid stamps the literal `my-svg` on every diagram it
  renders, and scopes all of its themed CSS to that id. Left alone, a diagram on a page with another
  diagram on it inherits the wrong rules. `normalize-svg.js` replaces the token everywhere it
  appears — selector, root id, and the marker ids that `url()` resolves through — and then refuses to
  write a file whose themed rules have gone dead. It cost a whole commit to find that one; the
  assertions at the bottom of that file are the reason it will not cost another.

If `task diagrams` produces a diff you did not expect, the pin moved. Check `git diff` on the SVGs
before you assume it is harmless.
