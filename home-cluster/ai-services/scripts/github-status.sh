#!/usr/bin/env bash
# Poll GitHub's public status page (Statuspage API) for active incidents.
#
# Usage:
#   github-status.sh [--json]
#
# Exit codes:
#   0  GitHub operating normally, no unresolved incidents
#   1  One or more unresolved incidents are active
#   2  Status API unreachable / parse error
set -euo pipefail

API="${GITHUB_STATUS_API:-https://www.githubstatus.com/api/v2}"
TIMEOUT="${GITHUB_STATUS_TIMEOUT:-15}"
MODE="${1:-}"

curl_api() {
  curl -fsS --max-time "$TIMEOUT" "$API/$1" 2>/dev/null || return 1
}

status_json="$(curl_api status.json || true)"
incidents_json="$(curl_api incidents/unresolved.json || true)"

if [ -z "$status_json" ] || [ -z "$incidents_json" ]; then
  echo "ERROR: unable to reach GitHub status API at $API" >&2
  exit 2
fi

if [ "$MODE" = "--json" ]; then
  printf '%s\n%s\n' "$status_json" "$incidents_json" | jq -s '{status: .[0].status, incidents: .[1].incidents}'
  exit 0
fi

jq -r '"Overall status: \(.status.description)"' <<<"$status_json"
jq -r '"API:            \(.status.indicator)"' <<<"$status_json"

count="$(jq '.incidents | length' <<<"$incidents_json")"

if [ "$count" -eq 0 ]; then
  echo "Incidents:      none — all GitHub systems reported operational"
  exit 0
fi

echo "$count unresolved incident(s):"
jq -r '.incidents[] | "  - [\(.impact)] \(.name)  (\(.status))  since \(.created_at)"' <<<"$incidents_json"
echo "Details: $API/incidents"
exit 1