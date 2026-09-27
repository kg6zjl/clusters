#!/usr/bin/env bash
#
# Bootstrap the GitHub App that the ARC controller authenticates with, and land its
# credentials in 1Password.
#
#   ./bootstrap-github-app.sh register      # step 1: create the App, store id + private key
#   ...install the App on kg6jwl/clusters in the browser...
#   ./bootstrap-github-app.sh installation  # step 2: discover the installation ID, store it
#
# Run this LOCALLY and run it yourself. It handles the App private key, which must never
# reach an agent transcript or git. The App definition is github-app-manifest.json, kept in
# git so the permissions this cluster grants are reviewable in a PR rather than clicked by hand.
#
# What it writes: 1Password item "github-runner-app" in the "home-cluster" vault, with custom
# fields app-id, installation-id and private-key -- the exact fields external-secrets.yaml reads.

set -euo pipefail

MANIFEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/github-app-manifest.json"
VAULT=home-cluster
ITEM=github-runner-app
REPO=kg6zjl/clusters
OWNER=kg6zjl
API=https://api.github.com

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
die() { printf '%s%s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s\n' "$GRN" "$RST" "$*"; }
note() { say "${DIM}$*${RST}"; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

KEY_TMP=""
cleanup() { [ -n "$KEY_TMP" ] && rm -f "$KEY_TMP"; }
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

# Write the three credential fields. 1Password has no stdin input for `item create`, so the
# PEM goes in as an argv value and is briefly visible in `ps` to other local users. Acceptable
# on a single-user Mac; on a shared host, paste the key into the item by hand instead.
write_item() {
  local app_id="$1" key_file="$2" installation_id="${3:-}"
  op item get "$ITEM" --vault "$VAULT" >/dev/null 2>&1 && {
    op item delete "$ITEM" --vault "$VAULT" >/dev/null || die "could not replace existing item '$ITEM'"
    say "Replaced the existing '$ITEM' item."
  }
  [ -n "$installation_id" ] || installation_id=$(printf 'pending')
  op item create --category=credential --title="$ITEM" --vault="$VAULT" \
    "app-id[text]=$app_id" \
    "installation-id[text]=$installation_id" \
    "private-key[text]=$(cat "$key_file")" >/dev/null \
    || die "failed to create the 1Password item '$ITEM'"
}

preflight() {
  need curl; need jq; need openssl; need gh; need op
  [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
  jq -e . "$MANIFEST" >/dev/null || die "$MANIFEST is not valid JSON"
  op whoami >/dev/null 2>&1 || die "1Password CLI is not signed in. Run: eval \$(op signin)"
  op vault list --format=json 2>/dev/null \
    | jq -e --arg v "$VAULT" 'map(select(.name == $v)) | length > 0' >/dev/null \
    || die "1Password vault '$VAULT' is not visible to this account"
}

# ---------------------------------------------------------------- step 1: register
cmd_register() {
  preflight
  local state page manifest_b64 code response app_id

  # GitHub will not create an App from a non-interactive API call: the manifest flow requires
  # a human to confirm creation. So drive a real browser at a throwaway local page that
  # auto-submits the pre-filled registration form.
  state=$(openssl rand -hex 16)
  manifest_b64=$(openssl base64 -A < "$MANIFEST")
  page="$(mktemp -t arc-app-register).html"
  cat > "$page" <<HTML
<!doctype html><meta charset="utf-8"><title>Register ARC GitHub App</title>
<body style="font:14px -apple-system;padding:2rem;max-width:40rem">
<h3>Registering the ARC GitHub App&hellip;</h3>
<p>Review the pre-filled permissions, then click <b>Create GitHub App</b>.
   Afterwards you will land on the repo page with a <code>?code=</code> parameter &mdash;
   come back to the terminal and paste that value.</p>
<form id="f" method="post" action="https://github.com/settings/apps/new?state=${state}">
  <input type="hidden" name="manifest" id="m">
</form>
<script>
  // base64 so the JSON needs no escaping and cannot contain a closing script tag
  document.getElementById("m").value = atob("${manifest_b64}");
  document.getElementById("f").submit();
</script>
HTML

  step "Opening the App registration form in your browser"
  note "Pre-filled from github-app-manifest.json. If it did not open: file://$page"
  open "$page" 2>/dev/null || xdg-open "$page" >/dev/null 2>&1 || true

  step "Waiting for the registration code"
  say "Paste the 'code' value from https://github.com/$REPO?code=..."
  printf 'code: '
  read -r code
  [ -n "$code" ] || die "no code entered"

  step "Exchanging the code for the App"
  # The manifest code is single-use and expires after an hour, so do not retry it blindly.
  response=$(curl -sS -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Authorization: Bearer $(gh auth token)" \
    "$API/app-manifests/$code/conversions") || true

  app_id=$(printf '%s' "$response" | jq -r '.id // empty')
  [ -n "$app_id" ] || die "conversion failed: $(printf '%s' "$response" | jq -r '.message // .')"

  KEY_TMP=$(mktemp); chmod 600 "$KEY_TMP"
  printf '%s' "$response" | jq -er '.pem' > "$KEY_TMP" || die "conversion response had no private key"
  say "App ID: $app_id"
  note "private key received and not printed"

  step "Creating the 1Password item"
  write_item "$app_id" "$KEY_TMP"

  say "${GRN}Created op://$VAULT/$ITEM with app-id and private-key.${RST}"
  step "Next: install the App, then finish"
  say "  1. https://github.com/settings/installations -> 'arc-runners' -> Configure"
  say "     Repository access: only ${GRN}$REPO${RST}"
  say "  2. $0 installation"
  say ""
  note "Until the App is installed, installation-id reads '${DIM}pending${RST}' and the"
  note "controller will crashloop on envconfig, not 401. That is expected at this stage."
}

# ------------------------------------------------------------- step 2: installation
cmd_installation() {
  preflight
  step "Reading the App credentials from 1Password"
  local app_id jwt installations count target selected repos covered forced="${2:-}"
  app_id=$(op read "op://$VAULT/$ITEM/app-id" 2>/dev/null) || die "item or field not found in 1Password"
  KEY_TMP=$(mktemp); chmod 600 "$KEY_TMP"
  op read "op://$VAULT/$ITEM/private-key" 2>/dev/null > "$KEY_TMP" || die "private-key field not found"
  say "App ID: $app_id"

  step "Asking GitHub which installations this App has"
  # Fail here rather than guess: a wrong installation-id is a 401 indistinguishable from a
  # bad key, and that ambiguity is expensive to debug later.
  jwt=$(app_jwt "$app_id" "$KEY_TMP")
  installations=$(curl -sS \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Authorization: Bearer $jwt" \
    "$API/app/installations") || die "could not authenticate as the App; is the private key valid?"

  printf '%s' "$installations" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || die "listing installations failed: $(printf '%s' "$installations" | jq -r '.message // .')"

  count=$(printf '%s' "$installations" | jq 'length')
  [ "${count:-0}" -gt 0 ] || die "the App has no installations yet. Install it on $REPO first:
  https://github.com/settings/installations"

  say "Found $count installation(s):"
  printf '%s' "$installations" \
    | jq -r '.[] | "  id=\(.id)  account=\(.account.login)  selection=\(.repository_selection)"'

  # An explicitly passed ID wins, but only after checking it really is one of this App's.
  if [ -n "$forced" ]; then
    printf '%s' "$installations" | jq -e --argjson i "$forced" 'map(select(.id == $i)) | length > 0' >/dev/null \
      || die "installation $forced does not belong to this App"
    target="$forced"
  else
    selected=$(printf '%s' "$installations" | jq -r --arg o "$OWNER" \
      '[.[] | select(.account.login == $o)] | length')
    [ "${selected:-0}" -gt 0 ] || die "no installation on account '$OWNER'; install the App on your user account"

    # Prefer an installation that covers everything, else fail loudly rather than pick blindly.
    target=$(printf '%s' "$installations" | jq -r --arg o "$OWNER" '
      [ .[] | select(.account.login == $o) ] as $c
      | ($c | map(select(.repository_selection == "all")) | .[0].id) // empty')
    if [ -z "$target" ]; then
      say ""
      say "More than one installation on $OWNER and none is 'all repositories'."
      say "Re-run with the installation you want:"
      say "  $0 installation <installation-id>"
      exit 1
    fi
  fi

  step "Confirming the installation covers $REPO"
  repos=$(curl -sS \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Authorization: Bearer $jwt" \
    "$API/app/installations/$target/repositories?per_page=100") || die "could not list installation repositories"

  covered=$(printf '%s' "$repos" | jq -r --arg r "$REPO" 'if (.repositories | map(.full_name) | index($r))
    then "exact" else "no" end')
  if [ "$covered" = "exact" ]; then
    say "${GRN}Installation $target lists $REPO.${RST}"
  else
    say "${YLW}WARNING: installation $target does not list $REPO.${RST}"
    say "Grant it access to $REPO and re-run, or the runners will 401."
  fi

  step "Storing installation-id in 1Password"
  op item edit "$ITEM" --vault "$VAULT" "installation-id[text]=$target" >/dev/null \
    || die "failed to write installation-id"

  say "${GRN}Stored installation-id=$target.${RST}"
  step "Done"
  say "All three keys now resolve. Merge the PR, Flux syncs, reloader restarts the"
  say "controller on its own when the Secret changes. No manual restart needed."
}

case "${1:-}" in
  register)     cmd_register ;;
  installation) cmd_installation "$@" ;;
  *) die "usage: $0 {register|installation [installation-id]}" ;;
esac
