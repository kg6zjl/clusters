#!/usr/bin/env node
// Normalise a Mermaid-rendered SVG so the page's stylesheet owns its presentation.
//
// Mermaid writes three things into the root <svg> element that fight the site: an inline
// background-color, a pixel width/height pair, and a max-width cap. Left in place the diagram
// paints its own background over the page, refuses to shrink below its natural size on a narrow
// screen, and stops being responsive. Stripping them is the whole job of this file, and it is a
// separate step rather than an inline sed because it has to parse the root element's attributes
// rather than pattern-match text that may also appear inside a label.
//
// The viewBox is preserved verbatim -- it is the only thing that carries the diagram's aspect
// ratio, and losing it is how a diagram ends up stretched.

const fs = require('fs');
const path = require('path');

const target = process.argv[2];
if (!target) {
  console.error('normalize-svg: no file given');
  process.exit(2);
}

let svg;
try {
  svg = fs.readFileSync(target, 'utf8');
} catch (err) {
  console.error(`normalize-svg: cannot read ${target}: ${err.message}`);
  process.exit(1);
}

// Fail rather than write a mangled file. A silent pass here would commit a diagram that renders
// at zero height, which is exactly the class of bug this whole exercise is trying to avoid.
if (!svg.includes('<svg') || !svg.includes('viewBox')) {
  console.error(`normalize-svg: ${path.basename(target)} has no <svg> root or no viewBox - refusing to touch it`);
  process.exit(1);
}

// Re-key Mermaid's generated id, which is the literal "my-svg" for every diagram it renders.
//
// This has to happen before the root tag is rebuilt, and it has to be a blanket replacement of the
// token rather than a rule about "#my-svg": the token appears as a CSS selector scope (#my-svg .node),
// as the root element's own id, and inside marker ids that url() references resolve through
// (id="my-svg_flowchart-v2-pointEnd"). Replacing only the selector prefix leaves the root un-keyed --
// which silently kills every themed rule, because they are all scoped to that id -- and leaves two
// diagrams on one page sharing marker ids, so the second one's arrows resolve to the first one's
// marker element.
const unique = `d${path.basename(target).replace(/[^a-z0-9]/gi, '')}`;
const rekeyed = svg.replace(/my-svg/g, unique);

// Replace the root element's opening tag wholesale. Anchored to the first <svg so a label that
// happens to contain the literal string "<svg" cannot be rewritten. The id is carried across on
// purpose: it is what the themed <style> block above is scoped to.
const viewBox = rekeyed.match(/viewBox="([^"]+)"/)[1];
const naturalWidth = Math.round(Number(viewBox.split(/\s+/)[2]));
if (!Number.isFinite(naturalWidth) || naturalWidth <= 0) {
  console.error(`normalize-svg: ${path.basename(target)} has an unparseable viewBox width - refusing to touch it`);
  process.exit(1);
}

// width="100%" capped by max-width at the natural size is the combination that behaves: a wide
// diagram scales down to fit its container and stays legible, and a narrow one renders at its
// natural size instead of being blown up two-and-a-half times and reading as a poster.
const normalized = rekeyed.replace(/<svg\b[^>]*>/, [
  '<svg xmlns="http://www.w3.org/2000/svg"',
  'xmlns:xlink="http://www.w3.org/1999/xlink"',
  `id="${unique}"`,
  `viewBox="${viewBox}"`,
  'width="100%"',
  `style="max-width:${naturalWidth}px"`,
  'preserveAspectRatio="xMidYMin meet"',
  'role="img"',
  'class="diagram"',
  '>',
].join(' '));

// A diagram whose theme did not survive normalisation is a silent failure: it renders, it looks
// plausible, and it ignores the theme. Assert the scope the stylesheet depends on is still there.
if (!normalized.includes(`id="${unique}"`)) {
  console.error(`normalize-svg: ${path.basename(target)} lost its id - the themed CSS would never apply`);
  process.exit(1);
}
const scoped = (normalized.match(new RegExp(`#${unique}\\b`, 'g')) || []).length;
if (scoped === 0) {
  console.error(`normalize-svg: ${path.basename(target)} has no CSS scoped to #${unique} - refusing to write it`);
  process.exit(1);
}

fs.writeFileSync(target, normalized);
console.log(`normalize-svg: ${path.basename(target)} ok (id=${unique}, viewBox="${viewBox}", capped at ${naturalWidth}px, ${scoped} themed rules live)`);
