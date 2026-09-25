---
name: github-status
description: Check GitHub's live status and unresolved incidents. Use instead of guessing or querying knowledge bases.
category: devops
version: 1.0.0
author: Hermit
---

# GitHub Status Check

**Use when:** Asked whether GitHub is down / having issues, why a GitHub API
call fails intermittently, or before blaming a workflow, push, or PR on
GitHub. **Never** fabricate status or "query a knowledge base" — poll the
real public status page.

## The status page

GitHub's public status page is a Statuspage instance:

- API base: `https://www.githubstatus.com/api/v2`
- `status.json` → overall status (indicator `none`/`minor`/`major`/`critical`)
- `incidents/unresolved.json` → active incidents
- Human page: https://www.githubstatus.com

## Run the poll script

The repo ships a poller (`jq` is available in the hermes runtime):

```bash
# point at your repo checkout
$HOME_DIR/scripts/github-status.sh          # text summary, exit 0 = OK
$HOME_DIR/scripts/github-status.sh --json   # machine-readable
```

If the script file is not present in the checkout, run the equivalent inline:

```bash
curl -fsS https://www.githubstatus.com/api/v2/status.json
curl -fsS https://www.githubstatus.com/api/v2/incidents/unresolved.json
```

## Interpreting the result

- `0` / "All Systems Operational" → GitHub is fine; look elsewhere for the
  failure (network, NetPol, your code). Do not blame GitHub.
- Non-zero with `[major]` or `[critical]` incidents → API/Web may be degraded;
  retry later and note it in the PR/issue.
- `minor` incidents rarely affect APIs — check the incident names.

## Notes

- Poll at most a few times with backoff; a single check is usually enough.
- The GitHub *status* and your own *registry/runner health* are different
  things — don't conflate them.

**Status:** Active — always truth from the real API, never a guess.