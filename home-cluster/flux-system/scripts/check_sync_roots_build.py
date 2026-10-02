"""Fail if any root Flux reconciles will not build.

The Validate job in .github/workflows/ci.yaml builds ./home-cluster, which is mostly
Flux's own bootstrap: flux-system, flux-system/syncs, adsb, and one patch file. Flux
reconciles each component separately from its own root, via the Kustomizations in
home-cluster/flux-system/syncs/. A broken overlay in one of those passes CI and then
surfaces as a failed reconcile instead - the reconcile is the first thing to notice.

So build every path those Kustomizations point at. The paths are read from the sync
files rather than hardcoded here, so a new component is covered the moment its
Kustomization lands and a renamed directory cannot be quietly dropped from the build.

Usage: check_sync_roots_build.py [repo_root] [kustomize_binary]
      (both default, for testing the failure path)
"""

import pathlib
import re
import subprocess
import sys

SYNC_DIR = "home-cluster/flux-system/syncs"
# MULTILINE matters here: `search(text, MULTILINE)` on a compiled pattern passes the
# flag as `pos`, not as flags, which silently starts the scan at an offset instead of
# matching every line.
PATH_RE = re.compile(r"^\s*path:\s*['\"]?(\./home-cluster/[^'\"\s]+)['\"]?\s*$", re.MULTILINE)
KIND_RE = re.compile(r"^kind:\s*Kustomization\s*$", re.MULTILINE)


def sync_paths(repo_root: pathlib.Path) -> list[str]:
    """Every ./home-cluster path a Kustomization in the sync dir points at.

    Reads all files in the sync dir rather than globbing *-kustomization.yaml, so a
    sync file named something else is still covered.
    """
    paths = set()
    for sync_file in sorted((repo_root / SYNC_DIR).glob("*.yaml")):
        if sync_file.name == "kustomization.yaml":
            continue
        for line in sync_file.read_text().splitlines():
            match = PATH_RE.match(line)
            if match:
                paths.add(match.group(1).removeprefix("./"))
    return sorted(paths)


def main() -> int:
    repo_root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    kustomize = sys.argv[2] if len(sys.argv) > 2 else "kustomize"

    paths = sync_paths(repo_root)
    if not paths:
        print(f"No sync paths found under {SYNC_DIR}/ - is the layout still this?", file=sys.stderr)
        return 1

    # A Kustomization with no path of its own inherits its source's path, which this
    # parser cannot resolve. Refuse to pass rather than quietly cover less than we
    # claim: a silently shortened list is the exact failure this script exists to catch.
    missing_path = []
    for sync_file in sorted((repo_root / SYNC_DIR).glob("*.yaml")):
        # The dir's own kustomization.yaml is the resource list, not a sync object, so
        # it has kind: Kustomization and no path by design. Skipping it here and in
        # sync_paths() is what keeps "kind says Kustomization" meaning "a sync".
        if sync_file.name == "kustomization.yaml":
            continue
        text = sync_file.read_text()
        if KIND_RE.search(text) and not PATH_RE.search(text):
            missing_path.append(sync_file.name)
    if missing_path:
        print("Sync files declaring a Kustomization but no local path:", file=sys.stderr)
        for name in missing_path:
            print(f"  {name}", file=sys.stderr)
        print("  These resolve at reconcile time and cannot be built here.", file=sys.stderr)
        return 1

    print(f"Building {len(paths)} Flux sync roots")
    failed = []
    for path in paths:
        root = repo_root / path
        result = subprocess.run(
            [kustomize, "build", "."],
            cwd=root,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"  FAIL {path}", file=sys.stderr)
            for line in (result.stderr or result.stdout).splitlines():
                print(f"    {line}", file=sys.stderr)
            failed.append(path)
        else:
            print(f"  ok   {path}")

    if failed:
        print(f"\n{len(failed)} of {len(paths)} sync roots do not build:", file=sys.stderr)
        for path in failed:
            print(f"  {path}", file=sys.stderr)
        return 1
    print(f"All {len(paths)} sync roots build")
    return 0


if __name__ == "__main__":
    sys.exit(main())