#!/bin/bash
# skills-drift-check.sh — compare live pod skills (/opt/data/skills) against
# the git-managed skill tree on origin/main. Matching is by <skill-dir-name>
# + content hash, so it works across the old flat layout and the new
# <category>/<name> layout.
#
# Exit 0 and print OK when trees agree.
# Print DRIFT lines (and exit 1) when they don't.
set -euo pipefail

SUMMARY_ONLY="${SUMMARY_ONLY:-0}"

REPO="${REPO:-/opt/data/workspace/clusters/home-cluster}"
SKILLS="${SKILLS:-/opt/data/skills}"

cd "$REPO"
git fetch -q origin main

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git ls-tree -r --name-only origin/main \
  | grep 'ai-services/hermes-skills/.*SKILL.md$' \
  | while read -r p; do
      name="$(basename "$(dirname "$p")")"
      hash="$(git show "origin/main:./$p" | sha256sum | cut -d' ' -f1)"
      printf '%s %s\n' "$name" "$hash"
    done | sort -u > "$TMP/git.txt"

find "$SKILLS" -path '*/.*' -prune -o -name SKILL.md -print \
  | while read -r f; do
      name="$(basename "$(dirname "$f")")"
      hash="$(sha256sum "$f" | cut -d' ' -f1)"
      printf '%s %s\n' "$name" "$hash"
    done | sort -u > "$TMP/local.txt"

cut -d' ' -f1 "$TMP/git.txt"   > "$TMP/git.names"
cut -d' ' -f1 "$TMP/local.txt" > "$TMP/local.names"

drift=0
mig="$(comm -13 "$TMP/git.names" "$TMP/local.names")"
ml="$(comm -23 "$TMP/git.names" "$TMP/local.names")"
mods="$(join "$TMP/git.txt" "$TMP/local.txt" | awk '$2 != $3 {print $1}')"

n_mig=$(echo "$mig" | grep -c . || true)
n_ml=$(echo "$ml" | grep -c . || true)
n_mod=$(echo "$mods" | grep -c . || true)

if [ "$n_mig" -gt 0 ]; then
  echo "DRIFT: $n_mig skill(s) exist in the pod but are NOT in git (never PR'd):"
  [ "$SUMMARY_ONLY" = "1" ] || echo "$mig" | sed 's/^/  - /'
  drift=1
fi
if [ "$n_ml" -gt 0 ]; then
  echo "DRIFT: $n_ml skill(s) in git but missing from pod (check mount/restart):"
  [ "$SUMMARY_ONLY" = "1" ] || echo "$ml" | sed 's/^/  - /'
  drift=1
fi
if [ "$n_mod" -gt 0 ]; then
  echo "DRIFT: $n_mod skill(s) modified locally vs git:"
  [ "$SUMMARY_ONLY" = "1" ] || echo "$mods" | sed 's/^/  - /'
  drift=1
fi

if [ "$drift" -eq 0 ]; then
  echo "OK: $(wc -l < "$TMP/local.txt") skills, pod and git in sync"
  exit 0
fi
exit 1
