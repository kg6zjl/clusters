#!/bin/bash
# skills-drift-check.sh — compare live pod skills (/opt/data/skills) against
# the git-managed skill tree on origin/main. Matching is by <skill-dir-name>
# + content hash, so it works across the old flat layout and the new
# <category>/<name> layout.
#
# Exit 0 and print OK when trees agree.
# Print DRIFT lines (and exit 1) when they don't.
set -euo pipefail

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

while read -r name; do
  echo "DRIFT missing-in-git: $name (created/edited locally, never PR'd)"
  drift=1
done < <(comm -13 "$TMP/git.names" "$TMP/local.names")

while read -r name; do
  echo "DRIFT missing-local: $name (in git, not on pod — check mount/restart)"
  drift=1
done < <(comm -23 "$TMP/git.names" "$TMP/local.names")

mods="$(join "$TMP/git.txt" "$TMP/local.txt" | awk '$2 != $3 {print "DRIFT modified: " $1 " (local != git)"}')"
if [ -n "$mods" ]; then
  echo "$mods"
  drift=1
fi

if [ "$drift" -eq 0 ]; then
  echo "OK: $(wc -l < "$TMP/local.txt") skills, pod and git in sync"
  exit 0
fi
exit 1
