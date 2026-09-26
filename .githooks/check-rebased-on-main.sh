#!/bin/sh
# Fail a commit when the current branch does not already contain origin/main.
#
# Why: committing on a branch that is behind (or diverged from) upstream defers
# the pain to the end — the PR arrives stale, GitHub refuses to merge it, and
# any textual conflict only shows up once the work is buried under a large
# diff. Checking at commit time surfaces both as early and as cheaply as
# possible, with an explicit "rebase first" instruction.
#
# Design:
#   * Purely local. Compares HEAD against the already-fetched origin/main ref
#     and never touches the network, so it is fast and works offline/in CI.
#     (pre-push refreshes origin/main; this check trusts that ref.)
#   * Read-only. It never rebases, resets, stashes or otherwise touches the
#     working tree, index or branch — it only tells the developer what to run.
#   * Fails open. Whenever it cannot make an honest judgement — no base ref,
#     shallow clone, an in-progress rebase/merge/cherry-pick — it exits 0.
#     A broken guard must never block unrelated commits.
#
# Scope: only repos whose origin is kg6zjl/clusters, so a shared core.hooksPath
# cannot surprise other clones (matches .githooks/pre-push).

set -u

BASE_REF="${REBASE_CHECK_BASE_REF:-origin/main}"

# Scope to this repo.
remote_url="$(git remote get-url origin 2>/dev/null || echo '')"
case "$remote_url" in
	*kg6zjl/clusters*) ;;
	*) exit 0 ;;
esac

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
git rev-parse --verify HEAD >/dev/null 2>&1 || exit 0

# Never block commits on the base branch itself.
current="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo '')"
case "$current" in
	main|master|"${BASE_REF#origin/}") exit 0 ;;
esac

# An in-progress rebase/merge/cherry-pick is exactly the moment conflicts are
# being resolved — never block that.
gdir="$(git rev-parse --git-dir 2>/dev/null)" || exit 0
for state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
	[ -e "$gdir/$state" ] && exit 0
done

# Need a local base ref to compare against; absent -> cannot judge, stay quiet
# so this stays a silent no-op in unrelated clones/fresh repos.
git rev-parse --verify --quiet "$BASE_REF" >/dev/null 2>&1 || exit 0

# The branch contains BASE_REF when BASE_REF is an ancestor of HEAD.
if git merge-base --is-ancestor "$BASE_REF" HEAD 2>/dev/null; then
	exit 0
fi
# Not an ancestor can also mean "objects unavailable" (shallow clone). Only
# block when a merge-base is actually computable, i.e. genuinely behind/diverged.
if ! git merge-base "$BASE_REF" HEAD >/dev/null 2>&1; then
	echo "pre-commit: cannot compute merge-base with $BASE_REF (shallow clone?) — skipping rebase check" >&2
	exit 0
fi

hint=""
git merge-base --is-ancestor HEAD "$BASE_REF" 2>/dev/null && hint=" (no local commits yet — purely behind)"

echo "COMMIT BLOCKED: branch '$current' does not contain the latest $BASE_REF." >&2
echo "  '$current' is behind or diverged from $BASE_REF$hint." >&2
echo "" >&2
echo "  Committing on a stale branch defers the problem: the PR arrives stale," >&2
echo "  GitHub refuses to merge it, and conflicts only surface at the end." >&2
echo "  Rebase now, while the change is still small:" >&2
echo "" >&2
echo "    git fetch origin" >&2
echo "    git rebase $BASE_REF" >&2
echo "" >&2
echo "  Resolve any conflicts, then commit again." >&2
echo "  One-off bypass (not advised): git commit --no-verify" >&2
exit 1
