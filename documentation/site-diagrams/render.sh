#!/usr/bin/env bash
# Render every .mmd in /src to .svg in /out. Both are bind-mounted by the caller.
#
#   docker run --rm \
#     -v "$PWD/documentation/site-diagrams/src:/src:ro" \
#     -v "$PWD/site/assets/img:/out" \
#     registry.kube.stevearnett.com/site/mermaid-renderer:latest
#
# Strict on purpose. A partial render is worse than no render, because a half-updated set of
# diagrams still looks committed and still deploys: so any single failure, and a source directory
# that is empty or missing, exits non-zero rather than reporting what it managed to do.
set -euo pipefail

SRC="${SRC_DIR:-/src}"
OUT="${OUT_DIR:-/out}"
CONFIG="${MERMAID_CONFIG:-/etc/mermaid/mermaid.config.json}"
PUPPETEER="${PUPPETEER_CONFIG:-/etc/mermaid/puppeteer.config.json}"

if [ ! -d "$SRC" ]; then
  echo "render: source directory $SRC does not exist" >&2
  exit 1
fi

shopt -s nullglob
sources=("$SRC"/*.mmd)
shopt -u nullglob

if [ "${#sources[@]}" -eq 0 ]; then
  echo "render: no .mmd files in $SRC - refusing to write an empty output set" >&2
  exit 1
fi

mkdir -p "$OUT"

failed=0
for src in "${sources[@]}"; do
  name="$(basename "$src" .mmd)"
  dest="$OUT/$name.svg"
  echo "render: $name.mmd -> $name.svg"
  # --puppeteerConfigFile is not optional here: this container runs as root, and Chromium refuses to
  # start as root without --no-sandbox. See the comment in puppeteer.config.json for why that is the
  # right trade for an image that only ever renders in-repo sources.
  if ! mmdc \
        --input "$src" \
        --output "$dest" \
        --configFile "$CONFIG" \
        --puppeteerConfigFile "$PUPPETEER" \
        --outputFormat svg \
        --quiet; then
    echo "render: FAILED on $name.mmd" >&2
    failed=1
    continue
  fi
  # Mermaid emits an SVG sized in pixels with an inline background colour, a max-width
  # constraint, and every themed CSS rule scoped to a generated id. Left alone, the diagram would
  # render at its natural size, scroll the page on a phone, paint its own background over the
  # page's, and ignore mermaid.config.json entirely. Normalising here means a diagram is styled
  # by assets/style.css like everything else and scales with its container.
  node /usr/local/bin/normalize-svg.js "$dest"

  # A bare "%%" line in a source is a Mermaid comment the parser does not recognise as one: it
  # becomes a visible node with "%%" printed in it, sitting in the middle of the diagram. The
  # render still succeeds and the file still looks like a diagram, so nothing else catches it --
  # seven of these shipped at once before this check existed. A "%%" line with text after it is a
  # real comment and is fine; only the empty one is a node.
  if grep -q 'flowchart-%%' "$dest"; then
    echo "render: $name.mmd drew a stray '%%' node - put text after a '%%' line, or delete it" >&2
    failed=1
    continue
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "render: one or more diagrams failed - the output set is incomplete, do not commit it" >&2
  exit 1
fi

echo "render: ${#sources[@]} diagram(s) written to $OUT"
