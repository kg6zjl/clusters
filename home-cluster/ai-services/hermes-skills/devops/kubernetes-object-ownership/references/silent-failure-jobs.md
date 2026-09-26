# Backup and one-shot Jobs: how they fail, and how they lie

## "Never worked" and "regressed" are different diagnoses

```bash
kubectl get cronjob <name> -n <ns> -o jsonpath='{.status.lastSuccessfulTime}'
kubectl get jobs -n <ns> --no-headers        # and count the successful ones
```

An empty `lastSuccessfulTime`, plus no successful Job objects while `successfulJobsHistoryLimit` is
greater than 0, means the job has **never** succeeded — not that tonight's run broke. Say which one it
is; they send you to different places.

Logs are frequently unavailable and that is by design: `podReplacementPolicy: TerminatingOrFailed`
deletes replacement pods as they fail, and Job events expire after about an hour. Reconstruct from the
Job's `.status.conditions` (`BackoffLimitExceeded` counts retries that each died fast), the pod spec in
git, and what those commands would actually have done. Report that logs are gone instead of
paraphrasing what they would have said.

Fast repeated failures are a clue: a six-retries-in-six-minutes pattern points at something failing
immediately (a missing file, a denied API call) rather than a slow or flaky dependency.

## The secret a job mounts may never have held data

A kustomize `secretGenerator` entry with no `literals`, no `files` and no `envs` renders as a Secret
with **zero data keys**, and Flux applies exactly that on every reconcile. The job then

```sh
smbclient //host/share -U "$(cat /creds/username)%$(cat /creds/password)"   # -> -U %
```

fails forever, and because the failure is an authentication error it reads like bad credentials.

Prove it from the repository rather than from the live object — reading Secrets in another namespace
is denied to the Hermes service account, and rightly so. Search the repo for the secret's name: if the
only two hits are the generator and the consumer, nothing has ever populated it and no amount of
rerunning will help.

The fix is an `ExternalSecret` (values live in 1Password, only paths in git). **Find a sibling workload
that already does the same thing successfully and copy its wiring** — the same NAS written by another
backup job is the pattern to mirror; inventing a credential path is how you get a second silent
failure. A generator's reflector annotations naming a namespace that does not exist are the tell that
the whole block is remnant drift; drop it with the generator.

## Mount the secret; do not shell out to `kubectl get secret`

Mounting needs **no pod RBAC** — the kubelet reads the Secret under node authorization — and renewals
propagate on their own without the job re-reading anything. Shelling out requires a ServiceAccount with
a Role, and a job that sets no `serviceAccountName` runs as `default`, which in most namespaces cannot
read Secrets. Mounting removes a permission, a credential lifetime problem and an API-server dependency
at once.

## `set -euo pipefail` decides whether a failure is loud or silent

The shape to hunt for is an assignment whose pipeline ends in something that succeeds on empty input:

```sh
CERT=$(kubectl get secret ... | base64 -d)   # Forbidden -> empty string -> pipeline exit 0
echo "$CERT" > /certs/fullchain.pem          # zero-byte file; the job exits 0 and "succeeds"
```

That is a backup which overwrites good data with empty data and reports success — strictly worse than
failing. Every fetch-and-upload job wants: `set -euo pipefail`; assert the value is non-empty; sanity
check the content (`grep -q 'BEGIN CERTIFICATE'`); and in the uploader, refuse to push empty files.
Say this in the PR: the point is that the job must fail loudly rather than no-op quietly.

## Verify a job fix with the field that records reality

A completed Job object proves an execution finished, not that it did anything. Confirm
`.status.lastSuccessfulTime` populates, then check the artefact on the far side (the uploaded file
matches its source byte for byte). When you cannot re-run the job yourself — read-only cluster access,
or a scheduled CronJob — hand the user the exact trigger (run-now from the UI, or the next tick) and
the log command, and label the fix as unverified until that lands.
