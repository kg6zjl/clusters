# Kyverno policy tests

Offline fixtures for the two ClusterPolicies in `../policies/`. `kyverno test`
evaluates policies against the fixtures with no cluster and no API server, so it
runs in CI (the `Kyverno policy tests` job in `.github/workflows/ci.yaml`).

## Run them

```bash
# Pinned to the chart's appVersion (kyverno 3.9.1 ships v1.19.1).
V=1.19.1
curl -sSfLO "https://github.com/kyverno/kyverno/releases/download/v${V}/kyverno-cli_v${V}_linux_x86_64.tar.gz"
curl -sSfLO "https://github.com/kyverno/kyverno/releases/download/v${V}/checksums.txt"
sha256sum -c --ignore-missing checksums.txt
tar -xzf "kyverno-cli_v${V}_linux_x86_64.tar.gz" kyverno

./kyverno test home-cluster/kyverno/tests --require-tests
./kyverno test home-cluster/kyverno/tests -f kyverno-test-nonagent.yaml --require-tests
```

`--require-tests` makes "the test files were not loaded" a failure instead of a
silent pass.

## What is covered

`kyverno-test.yaml` runs as
`system:serviceaccount:ai-services:hermes-agent` and asserts, per rule:

- `agent-clusterrole-readonly` / `agent-role-readonly`: a role under the
  `hermes-agent*` naming convention with a verb outside get/list/watch is
  **violated**; one that only reads is **not**.
- `agent-binding-readonly`: binding the ServiceAccount to `cluster-admin` or
  `edit`, or to any `Role` (whose verbs cannot be read offline), is **violated**;
  the real binding to `ClusterRole/hermes-agent` is **not**.
- `deny-agent-secret-write`: the agent writing a Secret is **violated**.

`kyverno-test-nonagent.yaml` re-runs the request-guard rule with
`userinfo/flux.yaml`: a different writer (`kustomize-controller`, which does apply
Secrets) must be **skipped**, proving the rule is scoped to the agent and would
not block ordinary writes if Kyverno were down or enforcing.

## What is NOT covered

`deny-agent-pod-exec` and `deny-agent-serviceaccount-token` have no fixture.
The CLI's test result schema simulates `CREATE`, `UPDATE` and `DELETE` admission
operations only; `pods/exec` arrives as `CONNECT` and `serviceaccounts/token` is
a subresource the fixture loader does not model, so neither can be exercised with
`kyverno test`. Do not add a passing fixture for them that does not actually run
the rule.
