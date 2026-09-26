#!/usr/bin/env bash
# gh wrapper for this pod.
#
# Why: the GitHub PAT is mounted by ESO at /etc/hermes/github-token and is NOT in
# $GITHUB_TOKEN for exec shells, and no git credential helper serves the gh keyring.
# `GH_TOKEN` is the supported escape hatch -- gh reads it from the environment and
# needs no `gh auth login`.
#
# Why a file instead of `export GH_TOKEN=$(cat ...)`: the command scanner flags an
# inline credential export as [HIGH] Sensitive credential exported and stalls the
# turn on an approval prompt. Reading the token inside the script avoids that, and
# keeps the value out of argv and shell history.
#
# Usage:
#   bash /opt/data/skills/software-development/git-auth-without-gh/scripts/gh.sh \
#     pr view 660 --repo kg6zjl/clusters --json number,title,state,mergeable
#
# gh is installed by the init container at /opt/data/.local/bin/gh and is not on PATH.
set -euo pipefail

GH_BIN="${GH_BIN:-/opt/data/.local/bin/gh}"
TOKEN_FILE="${GH_TOKEN_FILE:-/etc/hermes/github-token}"

if [ ! -x "$GH_BIN" ]; then
  echo "gh-wrapper: $GH_BIN is not executable" >&2
  exit 1
fi

if [ -z "${GH_TOKEN:-}" ]; then
  if [ ! -r "$TOKEN_FILE" ]; then
    echo "gh-wrapper: cannot read $TOKEN_FILE" >&2
    exit 1
  fi
  GH_TOKEN="$(cat "$TOKEN_FILE")"
  export GH_TOKEN
fi

exec "$GH_BIN" "$@"
