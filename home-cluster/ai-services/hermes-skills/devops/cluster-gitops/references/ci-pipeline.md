# CI Pipeline on the Self-Hosted Runners

Depth for the "run CI checks" step of the GitOps workflow. Covers what actually gates a PR here,
how the runners are wired, and how to tell a real gate from a decorative one.

## What gates a PR

- Three required checks: `Lint`, `Validate`, `Secret Scan` (`.github/workflows/ci.yaml`).
  **Job names are part of branch protection** — renaming a job silently un-requires it. Keep the
  names stable or update the rules in the same change.
- The `paths:` filter means a PR touching only files outside the listed globs runs **no checks at all**.
- **Which workflow version runs is main's version, not your branch's.** A PR that changes the
  workflow is still gated by the old one, so a newly added gate proves nothing until it is merged.
  State that explicitly rather than implying the new gate passed.

## Runners: which ARC flavour, and how many slots

- Identify the controller before writing either autoscaling API — they are not interchangeable:
  summerwind ARC uses `actions.summerwind.dev` (`runnerdeployments`, `horizontalrunnerautoscalers`);
  the newer GitHub ARC uses `actions.github.com` (`AutoscalingRunnerSet`). Check the installed CRDs
  and the controller image, then use the matching object.
- Autoscale with `HorizontalRunnerAutoscaler`: `scaleTargetRef` at the RunnerDeployment,
  `minReplicas`/`maxReplicas`, `PercentageRunnersBusy` with scale up/down thresholds and factors,
  plus `scaleDownDelaySecondsAfterScaleOut` so it does not flap.
- **Count runner SLOTS per PR, not jobs per node.** N required checks = N concurrent runner slots;
  a fixed `replicas` below that makes the extra job sit in the queue.
- Diagnose with **queue time**, not job duration. Via the API:
  `GET /repos/<o>/<r>/actions/runs` → `created_at` vs `run_started_at` (queue) vs `updated_at` (total),
  and per-job detail from the run's `jobs_url`. A job that waits 80s to do 18s of work is a slot
  shortage, not a CPU shortage — check node request headroom before adding compute.
- Give runner pods explicit resource requests and a `topologySpreadConstraint` on
  `kubernetes.io/hostname`. With neither, the scheduler stacks every replica on whichever node
  is emptiest, and a scale-up can squeeze the nodes it lands on.

## Prefer pinned CLIs over container-based actions

- Before adopting a third-party action on self-hosted runners, check whether it is a **composite that
  shells out to `docker run`** (trufflehog's official action is). These runner pods have no docker
  daemon and no socket, so the step fails — and under `continue-on-error: true` it fails silently.
- Install security tooling in the runner **init container** instead: pin the version, verify the
  release checksum (`sha256sum -c --ignore-missing <checksums.txt>`), extract the binary to a shared
  path, and invoke the CLI from the job.
- Validate the exact CLI invocation locally against a real repo before shipping it, and confirm the
  tool exits non-zero on findings (`--fail`) — a scan that always exits 0 gates nothing.
- `--only-verified` performs outbound verification against provider APIs. If the runner namespace's
  egress is ever tightened, the scan silently stops catching live credentials. Note that coupling
  whenever egress rules are reviewed.

## A check that cannot fail is not a gate

Two independent ways to build a decorative gate, both seen in this repo:

1. `continue-on-error: true` on the scanning step swallows the finding.
2. A follow-up step whose condition can never be true — e.g. testing `git log main..HEAD` in a PR
   checkout where no local `main` ref exists: the command errors, output is empty, and the
   "nothing to scan" branch exits 0.

Before trusting a gate, make it fail on a throwaway branch, or at least read the failure path and
confirm the exit code the tool produces. **Report a decorative gate as a security finding**, with the
run conclusions that prove it, not as a style nit.

## Tools inside the runner container

Sharing tools between an init container and the main container requires **both containers to mount
the same `emptyDir`**. Writing into a volume the main container never mounts leaves the file
invisible. Corollaries, each of which has silently broken a job here:

- `pip install <pkg>` in an init container installs into the init container's own rootfs. Install
  with `--target /opt/tools/pylib` and set `PYTHONPATH` in the main container, or it cannot import it.
- A binary dropped into `/opt/tools/bin` is only found if the main container's `PATH` includes it —
  set `PATH` explicitly.
- When a job fails strangely, check the mounts before assuming the workflow logic is wrong. RBAC may
  block reading the runner CRs (`runnerdeployments`/`horizontalrunnerautoscalers` can be forbidden to
  an agent SA) — fall back to live pod specs and observed behaviour to verify what is mounted.

## Reading results without lying to yourself

- The cluster API intermittently refuses connections. A piped `| wc -l` / `| grep -c` over a failed
  call returns `0` or empty and looks like data. Retry in a loop that inspects stderr, and only
  report a number that came from a successful call.
- Verify a merge landed **by effect**, not by the merge button: the Flux Kustomization's
  `status.lastAppliedRevision` must equal the merge commit *and* the resource behaviour must change
  (replica counts, config content, pod restarts). Flux intervals as short as 1m mean "merged" and
  "live" are different states — say which one you observed.
