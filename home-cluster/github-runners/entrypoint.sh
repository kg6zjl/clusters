#!/bin/bash
# ARC entrypoint for the in-house runner image.
#
# Why this file exists at all: ghcr.io/actions/actions-runner ships the agent and its runtime but sets
# no ENTRYPOINT -- its config is `Cmd: ["/bin/bash"]`, `WorkingDir: /home/runner`, `User: runner`.
# ARC does not exec the agent itself. It sets RUNNER_* env vars on the pod and expects the image's
# entrypoint to turn them into config.sh + run.sh. With only the base image's CMD, the container
# started /bin/bash with no argument, read EOF on empty stdin and exited 0 in under a second. Every
# runner pod "succeeded", num_runners_registered stayed 0, and ARC churned replacements forever.
# summerwind/actions-runner avoids this by shipping entrypoint.sh + startup.sh; this reproduces that
# contract so the image can stay built FROM the first-party actions/* base.
#
# Differences from summerwind's startup.sh, each one because this image is not summerwind's:
#   - No "copy the agent in" step. summerwind copies from $RUNNER_ASSETS_DIR into an emptyDir at
#     /runner; here the agent is already unpacked in the image at /home/runner, owned by the runner
#     user, so config.sh and run.sh are run in place. Nothing is copied and nothing is chowned.
#   - No sudo. startup.sh does `sudo chown -R runner:docker $RUNNER_HOME` because /runner is an
#     emptyDir it has to take ownership of. We never write to /runner, so we do not need sudo, and
#     we should not assume it exists: the actions-runner base has no sudoers entry for runner.
#   - No /etc/environment replay. Docker ignores PAM, so system-wide vars never reach the process;
#     summerwind re-reads /etc/environment and re-execs through `env`. There is no /etc/environment
#     in this base image, and ARC passes everything the agent needs as explicit container env.
#   - No job hooks and no update-status file. Those point at /etc/arc/hooks/* and are only present in
#     summerwind's image; referencing them here would make the agent fail hook resolution at job start.
set -uo pipefail

# Where the agent lives in this image. Overridable so a job or a test harness can point at a copy.
RUNNER_HOME=${RUNNER_HOME:-/home/runner}

log() { printf '%s  ENTRYPOINT --- %s\n' "$(date '+%F %T')" "$*" >&2; }

# --- Validate ARC's contract. Every one of these is set by actions-runner-controller on the pod.
# Fail loudly and non-zero instead of letting the agent start unregistered: a pod that exits 0
# silently is exactly the failure mode that made the previous image look healthy.

if [[ -z ${RUNNER_NAME:-} ]]; then
  log "FATAL: RUNNER_NAME is not set (is this running under ARC?)"
  exit 1
fi

# Mirror summerwind's scope resolution: exactly one of org/repo/enterprise, with repo refining org.
if [[ -n ${RUNNER_ORG:-} && -n ${RUNNER_REPO:-} && -n ${RUNNER_ENTERPRISE:-} ]]; then
  ATTACH="${RUNNER_ORG}/${RUNNER_REPO}"
elif [[ -n ${RUNNER_ORG:-} ]]; then
  ATTACH="${RUNNER_ORG}"
elif [[ -n ${RUNNER_REPO:-} ]]; then
  ATTACH="${RUNNER_REPO}"
elif [[ -n ${RUNNER_ENTERPRISE:-} ]]; then
  ATTACH="enterprises/${RUNNER_ENTERPRISE}"
else
  log "FATAL: one of RUNNER_ORG, RUNNER_REPO or RUNNER_ENTERPRISE must be set"
  exit 1
fi

if [[ -z ${RUNNER_TOKEN:-} ]]; then
  log "FATAL: RUNNER_TOKEN is not set"
  exit 1
fi

# Guard the assumption this whole script rests on. If the base image ever moves the agent, fail with
# a message that says so, rather than "config.sh not found" from inside a retry loop.
if [[ ! -x ${RUNNER_HOME}/config.sh || ! -x ${RUNNER_HOME}/run.sh ]]; then
  log "FATAL: config.sh/run.sh not found under ${RUNNER_HOME} (base image layout changed?)"
  exit 1
fi

# Normalise the trailing slash before concatenating, as summerwind does.
GITHUB_URL=${GITHUB_URL:-https://github.com/}
[[ ${GITHUB_URL} != */ ]] && GITHUB_URL="${GITHUB_URL}/"

log "registering '${RUNNER_NAME}' against ${GITHUB_URL}${ATTACH}"

cd "${RUNNER_HOME}" || { log "FATAL: cannot cd to ${RUNNER_HOME}"; exit 1; }

config_args=(--unattended --replace --name "${RUNNER_NAME}" --url "${GITHUB_URL}${ATTACH}" --token "${RUNNER_TOKEN}")

[[ -n ${RUNNER_LABELS:-} ]] && config_args+=(--labels "${RUNNER_LABELS}")

# summerwind only passes --runnergroup when there is no repo scope, because a repo-scoped runner is
# already pinned to that repo's default group and the flag would override the operator's choice.
if [[ -z ${RUNNER_REPO:-} && -n ${RUNNER_GROUP:-} ]]; then
  config_args+=(--runnergroup "${RUNNER_GROUP}")
fi

# ARC mounts an emptyDir at RUNNER_WORKDIR (default /runner/_work, mode 1777 by kubelet default) and
# points --work at it, so job checkouts never touch the image layer. If ARC did not set one, fall
# back to a directory under RUNNER_HOME rather than letting config.sh pick a default we do not own.
if [[ -n ${RUNNER_WORKDIR:-} ]]; then
  config_args+=(--work "${RUNNER_WORKDIR}")
else
  log "WARNING: RUNNER_WORKDIR unset, using ${RUNNER_HOME}/_work"
  mkdir -p "${RUNNER_HOME}/_work"
  config_args+=(--work "${RUNNER_HOME}/_work")
fi

# --ephemeral is what makes the runner take exactly one job and then exit, which is the whole model
# here. It is mutually exclusive with the `once` feature flag, so honour that like summerwind does.
if [[ ${RUNNER_EPHEMERAL:-false} == true && ${RUNNER_FEATURE_FLAG_ONCE:-false} != true ]]; then
  config_args+=(--ephemeral)
fi
if [[ ${DISABLE_RUNNER_UPDATE:-false} == true ]]; then
  config_args+=(--disableupdate)
fi

# Retry registration: the first attempt can lose a race with the token or hit a transient 5xx.
# Ten attempts at 1s matches summerwind. config.sh always runs before .runner is trusted -- testing
# for the file first would let a stale .runner left in the image layer skip registration entirely,
# which is exactly the silent-failure mode that made the previous image look healthy.
# On exhaustion the pod exits non-zero so ARC replaces it: better than a pod that lingers
# registered-but-not-running, which is what the last attempt did for hours.
for attempt in {1..10}; do
  if ./config.sh "${config_args[@]}" && [[ -f .runner ]]; then
    break
  fi
  log "config.sh failed (attempt ${attempt}/10)"
  sleep 1
done

if [[ ! -f .runner ]]; then
  log "FATAL: could not configure runner after 10 attempts"
  exit 2
fi
log "runner configured (agentId $(python3 -c 'import json;print(json.load(open(".runner"))["agentId"])' 2>/dev/null || echo '?'))"

# Do not let ARC's registration env leak into the job environment. run.sh re-reads these, and a live
# RUNNER_TOKEN in every job step is both wrong and a credential leak. summerwind unsets the same set.
unset RUNNER_NAME RUNNER_REPO RUNNER_TOKEN RUNNER_ORG RUNNER_ENTERPRISE RUNNER_LABELS RUNNER_GROUP RUNNER_WORKDIR

# Replace this shell so the agent is PID 1. kubelet then signals the agent directly on pod delete,
# and an ephemeral runner that finishes its job exits the container cleanly instead of being reaped.
# The base image sets RUNNER_MANUALLY_TRAP_SIG=1, which is what makes the agent install its own
# SIGTERM handler and deregister rather than being killed mid-job.
exec ./run.sh
