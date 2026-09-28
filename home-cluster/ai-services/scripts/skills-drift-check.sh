#!/bin/bash
# skills-drift-check.sh — compare the live agent skill tree (/opt/data/skills) against
# kg6zjl/skills, which is the source of truth (seed PR #1 migrated the tree out of the
# clusters ConfigMap). Compares EVERY tracked file, not just SKILL.md: reference and
# script files went unnoticed under the old SKILL.md-only hash.
#
# Image-bundled skills are deliberately absent from the repo, so pod-only files are
# reported only when the skill is NOT listed in /opt/data/skills/.bundled_manifest.
#
# Exit 0 always (cron no_agent delivery treats nonzero as job failure; drift state is
# carried in the text). Prints OK when in sync, DRIFT lines otherwise.
set -euo pipefail

SUMMARY_ONLY="${SUMMARY_ONLY:-0}"
SKILLS="${SKILLS:-/opt/data/skills}"
REPO_URL="${REPO_URL:-https://github.com/kg6zjl/skills.git}"
BUNDLED="${BUNDLED:-$SKILLS/.bundled_manifest}"
CLONE="${CLONE:-/opt/data/skills-verify}"

if [ -d "$CLONE/.git" ]; then
  fetch_ok=1
  git -C "$CLONE" fetch -q origin main || fetch_ok=0
else
  fetch_ok=1
  mkdir -p "$(dirname "$CLONE")"
  git clone -q "$REPO_URL" "$CLONE" || fetch_ok=0
fi
if [ "$fetch_ok" -ne 1 ] || ! git -C "$CLONE" checkout -q origin/main 2>/dev/null; then
  echo "ERROR: cannot read $REPO_URL (clone or fetch failed) - drift is UNKNOWN, not clean."
  echo "  Needs https credentials for the private repo (git credential helper) and egress to github.com:443."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Repo side: every file under skills/, keyed by <cat>/<skill>/<rest>
( cd "$CLONE/skills" && git ls-files ) | while read -r p; do
    printf '%s %s\n' "$p" "$(sha256sum "$CLONE/skills/$p" | cut -d' ' -f1)"
  done | sort > "$TMP/repo.txt"

# Pod side: the same shape, so the two are directly comparable.
( cd "$SKILLS" && find . -type f ! -path './.*' ! -name '*.pyc' -print ) \
  | sed 's|^\./||' | while read -r p; do
      printf '%s %s\n' "$p" "$(sha256sum "$SKILLS/$p" | cut -d' ' -f1)"
    done | sort > "$TMP/pod.txt"

cut -d' ' -f1 "$TMP/repo.txt" > "$TMP/repo.names"
cut -d' ' -f1 "$TMP/pod.txt"  > "$TMP/pod.names"

drift=0

# In the repo, missing from the pod => the mount/checkout or the last restart is incomplete.
missing="$(comm -23 "$TMP/repo.names" "$TMP/pod.names")"
n_missing=$(printf '%s' "$missing" | grep -c . || true)
if [ "$n_missing" -gt 0 ]; then
  echo "DRIFT: $n_missing file(s) in kg6zjl/skills but missing from the pod (mount/restart):"
  [ "$SUMMARY_ONLY" = "1" ] || printf '%s\n' "$missing" | head -15 | sed 's/^/  - /'
  drift=1
fi

# Modified in the pod vs the repo.
mods="$(join "$TMP/repo.txt" "$TMP/pod.txt" | awk '$2 != $3 {print $1}')"
n_mods=$(printf '%s' "$mods" | grep -c . || true)
if [ "$n_mods" -gt 0 ]; then
  echo "DRIFT: $n_mods file(s) modified in the pod vs kg6zjl/skills:"
  [ "$SUMMARY_ONLY" = "1" ] || printf '%s\n' "$mods" | head -15 | sed 's/^/  - /'
  drift=1
fi

# In the pod but not the repo — ours only; image-bundled skills are expected absent.
extra="$(comm -13 "$TMP/repo.names" "$TMP/pod.names" \
  | awk -F/ '{print $1}' | sort -u | while read -r s; do
      grep -q "^$s:" "$BUNDLED" 2>/dev/null || echo "$s"
    done)"
n_extra=$(printf '%s' "$extra" | grep -c . || true)
if [ "$n_extra" -gt 0 ]; then
  echo "DRIFT: $n_extra skill(s) exist only in the pod (never PR'd to kg6zjl/skills):"
  [ "$SUMMARY_ONLY" = "1" ] || printf '%s\n' "$extra" | head -15 | sed 's/^/  - /'
  drift=1
fi

if [ "$drift" -eq 0 ]; then
  echo "OK: pod skill tree matches kg6zjl/skills."
else
  echo ""
  echo "Reminder: open a PR against kg6zjl/skills (branch + PR, never push main). The pod tree is delivered from that repo at pod start, so runtime edits are reset on the next restart - git is the only durable copy."
fi
exit 0
