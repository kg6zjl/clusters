#!/usr/bin/env bash
#
# Store the ARC controller's GitHub App credentials in 1Password.
#
# This script does not create the App. GitHub will not create one from a non-interactive API
# call, and the first private key has to be generated in the browser, because
# POST /app/{id}/private_keys authenticates with a JWT signed by an existing key -- so there
# is no key available to sign the very first request with. Create the App by hand, then run
# this to put its credentials in 1Password without the key passing through git or a transcript.
#
# Browser steps, in this order:
#   1. https://github.com/settings/apps/new
#      Name: arc-runners-home-cluster.  Any homepage and webhook URL will do.
#      Repository permissions -- exactly what github-app-manifest.json declares:
#        Administration: Read and write
#        Actions:         Read
#      Then "Create GitHub App". On its settings page, note the App ID at the bottom of the
#      page and "Generate private key"; save the .pem.
#   2. "Install App" -> install on kg6zjl only -> configure for kg6zjl/clusters only
#
# Then:
#   ./bootstrap-github-app.sh adopt <app-id> <path-to-private-key.pem>
#
# The installation ID is not needed as an argument: the script derives it from the App's own
# JWT, and refuses to write anything unless that installation really covers kg6zjl/clusters.
#
# What it writes: 1Password item "github-runner-app" in the "home-cluster" vault, with custom
# fields app-id, installation-id and private-key -- the exact fields external-secrets.yaml reads.
# All three are written in one shot, so the ExternalSecret never resolves a half-populated item
# and the controller never crashloops on a placeholder installation ID.

set -euo pipefail

VAULT=home-cluster
ITEM=github-runner-app
OWNER=kg6zjl
REPO=kg6zjl/clusters
API=https://api.github.com

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
die() { printf '%s%s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s\n' "$GRN" "$RST" "$*" >&2; }
note() { printf '%s\n' "${DIM}$*${RST}" >&2; }
# resolve_installation is called in a command substitution, so its diagnostics must go to
# stderr or they end up captured as the returned installation ID.
info() { printf '%s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

KEY_TMP=""
# Must return 0: an EXIT trap's status becomes the script's exit status, so a short-circuit
# here would make a successful run exit non-zero.
cleanup() { [ -n "$KEY_TMP" ] && rm -f "$KEY_TMP"; return 0; }
trap cleanup EXIT

# Mint a short-lived RS256 JWT so we can ask GitHub which installations exist for this App.
app_jwt() {
  local app_id="$1" key_file="$2" header payload now sig
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
  now=$(date +%s)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$now" "$((now + 540))" "$app_id" | b64url)
  sig=$(printf '%s' "$header.$payload" | openssl dgst -sha256 -sign "$key_file" | b64url)
  printf '%s.%s.%s' "$header" "$payload" "$sig"
}

# Resolve the installation that actually covers $REPO.
# Deliberately fails rather than guesses: a wrong installation-id produces a 401 that is
# indistinguishable from a bad private key, and that ambiguity is expensive to debug later.
resolve_installation() {
  local app_id="$1" key_file="$2" jwt installations count candidates target selection
  jwt=$(app_jwt "$app_id" "$key_file")
  # Separate transport failure from an auth failure: curl exiting non-zero means the request
  # never completed, which says nothing about the key.
  if ! installations=$(curl -sS \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Authorization: Bearer $jwt" \
      "$API/app/installations"); then
    die "could not reach $API -- network or TLS problem, not an auth problem"
  fi

  # A non-array body means GitHub returned an error object, almost always a rejected JWT.
  printf '%s' "$installations" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || die "GitHub rejected the request: $(printf '%s' "$installations" | jq -r '.message // .')
  Check that the app-id and the .pem belong to the same App."

  count=$(printf '%s' "$installations" | jq 'length')
  [ "${count:-0}" -gt 0 ] || die "the App has no installation yet. In GitHub settings, 'Install App'
  -> install it on $OWNER, then restrict it to $REPO only, and re-run this script."

  info "Installations visible to this App:"
  printf '%s' "$installations" \
    | jq -r '.[] | "  id=\(.id)  account=\(.account.login)  selection=\(.repository_selection)"' >&2

  candidates=$(printf '%s' "$installations" \
    | jq -r --arg o "$OWNER" '[.[] | select(.account.login == $o)] | length')
  [ "${candidates:-0}" -gt 0 ] || die "no installation on account '$OWNER'; install the App on your own account"

  # With a single installation on the account there is nothing to disambiguate. With several,
  # take the one scoped to all repositories; if none is, stop rather than pick arbitrarily.
  selection=$(printf '%s' "$installations" | jq -r --arg o "$OWNER" '
    [ .[] | select(.account.login == $o) ] as $c
    | ($c | map(select(.repository_selection == "all")) | .[0].id) // empty')
  if [ -n "$selection" ]; then target="$selection"; else
    count=$(printf '%s' "$installations" | jq -r --arg o "$OWNER" '[.[] | select(.account.login == $o)] | length')
    if [ "$count" -eq 1 ]; then
      target=$(printf '%s' "$installations" | jq -r --arg o "$OWNER" '[.[] | select(.account.login == $o)][0].id')
    else
      die "several installations on $OWNER and none is scoped to all repositories.
Pick one and re-run with:  $0 adopt <app-id> <pem> <installation-id>"
    fi
  fi

  # Definitive coverage check. Mint an installation token, then ask GitHub whether this App is
  # installed on this one repo. Better than listing the installation's repositories: it gives
  # an unambiguous yes/no for the repo that actually matters, and it exercises token minting,
  # which is the capability the controller depends on at runtime.
  local resp code body inst_token
  resp=$(curl -sS -w $'\n%{http_code}' -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Authorization: Bearer $jwt" \
    "$API/app/installations/$target/access_tokens") \
    || die "could not reach $API while minting an installation token (network or TLS problem)"
  code=${resp##*$'\n'}
  body=${resp%$'\n'*}
  case "$code" in
    200|201) inst_token=$(printf '%s' "$body" | jq -r '.token // empty') ;;
    403) die "GitHub refused to mint an installation token for $target (403).
The App needs Metadata: Read (granted automatically) -- check its permissions in settings." ;;
    *) die "minting an installation token returned HTTP $code:
$(printf '%s' "$body" | jq -r '.message // .' 2>/dev/null || printf '%s' "$body")" ;;
  esac
  [ -n "$inst_token" ] || die "no token in the access_tokens response:
$(printf '%s' "$body" | jq -r '.message // .' 2>/dev/null || printf '%s' "$body")"

  resp=$(curl -sS -w $'\n%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Authorization: Bearer $inst_token" \
    "$API/repos/$REPO/installation") \
    || die "could not reach $API while checking the installation on $REPO"
  code=${resp##*$'\n'}
  case "$code" in
    200) info "Confirmed: the App is installed on $REPO (installation $target)." ;;
    404) die "the App is NOT installed on $REPO.
https://github.com/settings/installations -> arc-runners-home-cluster -> Configure
add $REPO to the repository list, then re-run." ;;
    *) die "checking the installation on $REPO returned HTTP $code:
$(printf '%s' "${resp%$'\n'*}" | jq -r '.message // .' 2>/dev/null || printf '%s' "${resp%$'\n'*}")" ;;
  esac

  printf '%s' "$target"
}

preflight() {
  need curl; need jq; need openssl; need op
  op whoami >/dev/null 2>&1 || die "1Password CLI is not signed in. Run: eval \$(op signin)"
  op vault list --format=json 2>/dev/null \
    | jq -e --arg v "$VAULT" 'map(select(.name == $v)) | length > 0' >/dev/null \
    || die "1Password vault '$VAULT' is not visible to this account"
}

usage() { die "usage: $0 adopt <app-id> <private-key.pem> [installation-id]"; }

# 1Password has no stdin input for `item create`, so the PEM goes in as an argv value and is
# briefly visible in `ps` to other local users. Acceptable on a single-user Mac; on a shared
# host, paste the key into the item by hand instead.
write_item() {
  local app_id="$1" key_file="$2" installation_id="$3"
  if op item get "$ITEM" --vault "$VAULT" >/dev/null 2>&1; then
    say "Replacing the existing '$ITEM' item."
    op item delete "$ITEM" --vault "$VAULT" >/dev/null || die "could not remove the old item '$ITEM'"
  fi
  op item create --category=credential --title="$ITEM" --vault="$VAULT" \
    "app-id[text]=$app_id" \
    "installation-id[text]=$installation_id" \
    "private-key[text]=$(cat "$key_file")" >/dev/null \
    || die "failed to create the 1Password item '$ITEM'"
}

cmd_adopt() {
  local app_id="${1:-}" pem="${2:-}" forced="${3:-}"
  [ -n "$app_id" ] && [ -n "$pem" ] || usage
  preflight

  # AppID and AppInstallationID are int64 in the controller's config. A non-numeric value is a
  # startup crash rather than a 401, so reject it here where the message can be useful.
  printf '%s' "$app_id" | grep -Eq '^[0-9]+$' || die "app-id must be digits only, got '$app_id'"
  [ -f "$pem" ] || die "no such file: $pem"
  grep -q 'BEGIN .*PRIVATE KEY' "$pem" || die "$pem does not look like a PEM private key"

  KEY_TMP=$(mktemp); chmod 600 "$KEY_TMP"
  cat "$pem" > "$KEY_TMP"

  step "Checking the private key against App $app_id"
  # A quick authenticated call proves the key and ID agree before anything is written.
  local probe
  if ! probe=$(curl -sS -o /dev/null -w '%{http_code}' \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Authorization: Bearer $(app_jwt "$app_id" "$KEY_TMP")" \
      "$API/app"); then
    die "could not reach $API -- network or TLS problem, not an auth problem"
  fi
  case "$probe" in
    200) say "Key is valid for App $app_id." ;;
    401) die "GitHub rejected the key for App $app_id (401). Check the App ID and the .pem are from the same App." ;;
    403) die "GitHub refused the key for App $app_id (403). The App may be suspended or the id wrong." ;;
    *)   die "unexpected HTTP $probe from $API/app" ;;
  esac

  step "Resolving the installation for $REPO"
  local installation_id
  installation_id=$(resolve_installation "$app_id" "$KEY_TMP")
  if [ -n "$forced" ] && [ "$forced" != "$installation_id" ]; then
    die "you passed installation-id=$forced but the App's installation for $OWNER is $installation_id"
  fi

  step "Writing the 1Password item"
  write_item "$app_id" "$KEY_TMP" "$installation_id"
  say "${GRN}Created op://$VAULT/$ITEM with app-id, installation-id and private-key.${RST}"
  note "private key not printed"

  step "Done"
  say "Merge the PR. Flux syncs the ExternalSecret, and the reloader restarts the"
  say "controller on its own when the Secret changes -- no manual restart needed."
  say ""
  say "Verify with:"
  say "  kubectl get externalsecret -n github-runners"
  say "  kubectl logs -n github-runners -l app.kubernetes.io/name=actions-runner-controller \\"
  say "    --since=2m | grep -c '401 Bad credentials'    # expect 0"
}

case "${1:-}" in
  adopt) shift; cmd_adopt "$@" ;;
  *) usage ;;
esac
