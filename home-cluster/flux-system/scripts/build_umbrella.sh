#!/bin/sh
# Build every root in the repo from the umbrella, with whichever kustomize is available.
#
# Shared by CI and by pre-commit so the two cannot drift: a local gate that builds a
# different set than the runner would let a break through to the runner, which is the
# waste this is meant to remove.
#
# Usage: build_umbrella.sh [kustomize_binary]
#        (defaults to `kustomize`, falling back to `kubectl kustomize`)
#
# Why the umbrella and not a list of directories: home-cluster/kustomization.yaml lists
# every component directory, so this one build covers all 42 roots Flux reconciles plus
# Flux's own bootstrap. It also catches cross-component collisions that per-root builds
# miss - two directories declaring the same ClusterRole or NetworkPolicy name error here
# rather than fighting over SSA field ownership in the cluster.
#
# On failure kustomize's own message goes to stderr and names the offending directory, so
# it is printed rather than discarded.

set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)/home-cluster"
bin="${1:-}"

if [ -z "$bin" ]; then
	if command -v kustomize >/dev/null 2>&1; then
		bin=kustomize
	elif command -v kubectl >/dev/null 2>&1; then
		# Embedded in kubectl, so the pin follows whatever kubectl the runner has.
		bin="kubectl kustomize"
	else
		echo "build_umbrella: no kustomize and no kubectl on PATH" >&2
		exit 1
	fi
fi

if ! (cd "$root" && $bin build . >/dev/null); then
	echo "build_umbrella: FAILED - the directory named above did not build" >&2
	exit 1
fi

echo "build_umbrella: OK ($(basename "$root"), all component roots)"
