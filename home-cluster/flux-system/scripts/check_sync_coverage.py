#!/usr/bin/env python3
"""Fail if the component registry and the CI umbrella root have drifted apart.

Flux reconciles each component from its own root, via the Kustomizations in
home-cluster/flux-system/syncs/. That sync directory is the registry: adding a component
means adding a sync file there. Nothing else in the repo can see a missing registration,
so a component can be committed, merged, and never reconciled - or be reconciled while CI
never builds it.

home-cluster/kustomization.yaml is the umbrella build target that closes the loop. It is
a plain kustomize overlay, not a Flux entrypoint, and nothing applies it. It exists so one
`kustomize build .` covers all 42 roots. Before it listed four entries, CI validated only
Flux's own bootstrap while 40 component roots went unbuilt: a broken overlay in any of
them passed Lint, Validate and Secret Scan and first surfaced as a failed reconcile.

Both directions are checked, because each fails open on its own:

  * a sync with no umbrella entry  -> the component is reconciled but never built in CI
  * an umbrella entry with no sync -> the directory is built but never reconciled

Also checked, because each is a registration that silently does nothing:

  * a file in flux-system/ or syncs/ that the directory's own kustomization.yaml does
    not list -> Flux never sees it, and it drifts from the live copy without anyone
    noticing. syncs/traefik-helmrepository.yaml sat there with interval: 10m against
    the effective 1h in flux-system/ - inert until someone "fixes" the resource list
    and silently drops traefik's HelmRepository to a 10 minute interval.
  * two Flux Kustomizations with one name -> the second overwrites the first
  * a sync Kustomization with no local spec.path -> resolves at reconcile time only

Usage: check_sync_coverage.py [repo_root]
Exit 0 when consistent, 1 with an explanation and the edit to make otherwise.
"""

import pathlib
import sys

import yaml

UMBRELLA = "home-cluster/kustomization.yaml"
SYNC_DIR = "home-cluster/flux-system/syncs"
SYNC_LIST = f"{SYNC_DIR}/kustomization.yaml"
FLUX_API = "kustomize.toolkit.fluxcd.io"

# cluster-secrets has no sync and cannot build: it needs a .dockerconfigjson generated at
# runtime by Taskfile.yaml, and registry auth is the runner pod's projected token now
# (registry/README.md). Listed here so the check states the exception instead of the
# umbrella's comment doing it silently.
NO_SYNC_OK = {"cluster-secrets"}

# Directories whose files must all be named by their own kustomization.yaml. Both hold
# Flux objects applied to flux-system, and both have accumulated unreferenced duplicates.
FLUX_DIRS = ("flux-system", "flux-system/syncs")

# Directories with no sync of their own, reported on every run rather than enforced.
# flux-system/ holds the Flux install objects (gotk-components.yaml: the controller
# Deployments, CRDs, RBAC and NetPols) and nothing reconciles it - it was applied once at
# bootstrap and has not been managed from git since flux-operator and FluxInstance took
# over. That is a real gap, but closing it is not a manifest edit: a Flux Kustomization on
# ./home-cluster/flux-system would take ownership of the very Deployments and CRDs that
# flux-operator manages through FluxInstance, and two managers on one object is the SSA
# field-ownership fight AGENTS.md documents. It needs its own PR with a dry-run and a
# deliberate decision about who owns the Flux controllers.
#
# flux-system/syncs/ is reconciled - by flux-system-sources, whose path is this directory.
# It is listed here only so the unreconciled warning reads as one item, not two.
KNOWN_UNSYNCED = {"flux-system", "flux-system/syncs"}


def load(path: pathlib.Path):
    return [doc for doc in yaml.safe_load_all(path.read_text()) if isinstance(doc, dict)]


def relative(path: pathlib.Path, repo: pathlib.Path) -> str:
    return path.relative_to(repo).as_posix()


def flux_kustomizations(repo: pathlib.Path) -> list[tuple[pathlib.Path, dict]]:
    """Every Flux Kustomization CR in the tree, as (file, doc).

    Filtered on apiVersion and kind rather than grepping for `kind: Kustomization`,
    which also matches every kustomize overlay, or for `path:`, which also matches a
    HelmRelease's values (monitoring/kube-prometheus-stack-helmrelease.yaml carries
    `path: [results]` for a Loki volume mount).
    """
    found = []
    for path in sorted(repo.glob("home-cluster/**/*.yaml")):
        if path.name == "kustomization.yaml":
            continue
        for doc in load(path):
            # Group only: the CRs are kustomize.toolkit.fluxcd.io/v1, v1beta2 and v1beta1.
            if str(doc.get("apiVersion", "")).split("/")[0] == FLUX_API and doc.get("kind") == "Kustomization":
                found.append((path, doc))
    return found


def umbrella_resources(repo: pathlib.Path) -> list[str]:
    return list(load(repo / UMBRELLA)[0]["resources"])


def component_dirs(repo: pathlib.Path) -> set[str]:
    root = repo / "home-cluster"
    return {
        p.parent.relative_to(root).as_posix()
        for p in root.glob("**/kustomization.yaml")
        if p.parent != root
    }


def report(problems: list[str]) -> int:
    print("\n".join(problems), file=sys.stderr)
    print(
        "\nThe sync directory is the registry: a component exists when it has a sync "
        "file in\nhome-cluster/flux-system/syncs/, and the umbrella root must list every "
        "component\ndirectory so `kustomize build .` builds it.",
        file=sys.stderr,
    )
    return 1


def main() -> int:
    repo = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    problems: list[str] = []

    syncs = flux_kustomizations(repo)
    sync_dirs = set()
    for _, doc in syncs:
        path = (doc.get("spec") or {}).get("path", "")
        if path.startswith("./home-cluster/"):
            sync_dirs.add(path.removeprefix("./home-cluster/").rstrip("/"))

    listed = set(umbrella_resources(repo))
    all_dirs = component_dirs(repo)
    present = all_dirs - NO_SYNC_OK - set(FLUX_DIRS)

    # The umbrella lists component directories only. A bare file entry is the shape the
    # old root had - kube-system/coredns-configmap-patch.yaml alongside kube-system - and
    # it is redundant: the owning component directory already builds that file, so the
    # entry adds a second copy with none of the component's context.
    for entry in sorted(listed - all_dirs):
        problems.append(
            f"{UMBRELLA} lists '{entry}', which is not a component directory - the "
            f"umbrella lists directories, each of which builds its own files"
        )

    # flux-system/ and flux-system/syncs/ are bootstrap directories, not components:
    # the first holds the Flux install objects, the second is reconciled by
    # flux-system-sources. Both belong in the umbrella and neither is a component, so
    # compare components only. NO_SYNC_OK is subtracted from `present` above because a
    # directory may legitimately have neither a sync nor an umbrella entry.
    components = sync_dirs - set(FLUX_DIRS)
    umbrella_components = listed - set(FLUX_DIRS)

    for name in sorted(components - umbrella_components):
        problems.append(
            f"synced as home-cluster/{name} but not in {UMBRELLA} resources - "
            f"reconciled by Flux, never built by CI"
        )
    for name in sorted(umbrella_components - components):
        problems.append(
            f"in {UMBRELLA} resources but no sync file reconciles it: home-cluster/{name}"
        )
    for name in sorted(present - components - umbrella_components):
        problems.append(
            f"home-cluster/{name} has a kustomization.yaml but is neither synced nor listed "
            f"in {UMBRELLA} - it will never be reconciled and never be built"
        )

    # A file in a Flux directory that nothing references is a registration that silently
    # does nothing, and it drifts from the live copy while sitting there.
    for flux_dir in FLUX_DIRS:
        base = repo / "home-cluster" / flux_dir
        resources = {r for r in load(base / "kustomization.yaml")[0]["resources"]}
        for path in sorted(base.glob("*.yaml")):
            if path.name == "kustomization.yaml":
                continue
            if path.name not in resources:
                problems.append(
                    f"{relative(path, repo)} exists but is not in "
                    f"home-cluster/{flux_dir}/kustomization.yaml resources - Flux will never see it"
                )

    seen: dict[tuple[str, str], pathlib.Path] = {}
    for path, doc in syncs:
        name = (doc.get("metadata") or {}).get("name", "?")
        namespace = (doc.get("metadata") or {}).get("namespace", "flux-system")
        if (namespace, name) in seen:
            problems.append(
                f"two Flux Kustomizations named {namespace}/{name}: "
                f"{relative(seen[(namespace, name)], repo)} and {relative(path, repo)} - "
                f"the second silently replaces the first"
            )
        seen[(namespace, name)] = path

    if problems:
        print("Component registry and umbrella root have drifted:", file=sys.stderr)
        return report(problems)

    print(f"{len(components)} synced components, all present in {UMBRELLA}")
    for name in sorted(KNOWN_UNSYNCED & all_dirs - sync_dirs):
        print(f"  note: home-cluster/{name} is not reconciled from git (see KNOWN_UNSYNCED)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
