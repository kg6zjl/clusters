---
name: trivy-operator-reports
description: Query and triage trivy-operator scan results (VulnerabilityReport, ConfigAuditReport, ExposedSecretReport, RBACAssessmentReport CRs) in this cluster. Use when the user mentions trivy, vulnerabilities, CVEs, security findings, or wants to see/fix what the security scanning found. All "address these findings" work starts here.
category: security
version: 1.0.0
author: Hermit
---

# Trivy Operator Reports (CR source of truth)

Trivy Operator writes every workload scan result to Custom Resources in etcd.
This is the full-fidelity layer. There are three layers for the same data:

| Layer | Where | Fidelity |
| --- | --- | --- |
| **CRs** (this skill) | `kubectl get ...` — full CVE list, fixed versions, checks | Full |
| **Prometheus metrics** | `trivy_image_vulnerabilities`, `trivy_image_exposedsecrets`, ... (retention 10d) | Aggregated counts |
| **Grafana** | `grafana.kube.stevearnett.com` > "Trivy Operator Dashboard" (uid `ycwPj724k`) | Visualization |

Findings are fixed from the CR data — the Grafana dashboard only shows what
lives in these reports.

## Report CRDs in `security-scanning`

- `vulnerabilityreports` / `clustervulnerabilityreports` — image CVEs
- `configauditreports` / `clusterconfigauditreports` — Kubernetes misconfig (policy checks)
- `exposedsecretreports` / `clustersbomreports` — leaked secrets in container images
- `rbacassessmentreports` / `clusterrbacassessmentreports` — RBAC least-privilege checks
- `sbomreports` — SBOM only (generated, not a findings list)

Disabled in this deployment (empty results / ignored): compliance reports
(`compliance.specs: []`) and infra assessment (`infraAssessmentScannerEnabled: false`).
Scans run `ignoreUnfixed: true`, so only CVEs with a fix available appear.

## Understanding report names and labels

Report name = `<kind>-<owner-name>-<container>` (truncated hash parts are fine).
Every report carries labels identifying the source workload:

```
trivy-operator.resource.kind      e.g. Deployment / ReplicaSet / CronJob
trivy-operator.resource.name      workload name
trivy-operator.resource.namespace
trivy-operator.container.name
```

`report.artifact` holds `repository`, `tag`, `digest`; `report.registry.server`
the registry. `report.labels` is NOT the workload — use the metadata labels.

## Golden rules

- **Read-only only.** Never `kubectl edit/apply/patch` a report or workload. Fixes go through Git → PR → Flux (image bumps, config patches, RBAC). A re-scan happens automatically when the workload spec or image changes (jobs run in `security-scanning` via the built-in trivy-server on port 4954; expect new reports within ~1–5 minutes of a deploy).
- `KUBECONFIG` may be a session temp file; export it from the environment or context as needed.
- Report field paths are flat under the `report` key (there is **no** `spec.report`) — this is the trivy-operator v2 API shape.

## Query recipes

All commands are read-only. `jq` is available on the runner/mac.

### 1. Totals by severity (mirrors the Grafana dashboard)

```bash
kubectl get vulnerabilityreports -A -o json | jq -r '
  .items[] | .report.summary |
  "\(.criticalCount) critical  \(.highCount) high  \(.mediumCount) medium  \(.lowCount) low  \(.unknownCount) unknown"
' | awk '{c+=$1;h+=$3;m+=$5} END {print "TOTAL critical="c" high="h" medium="m}'
```

Or aggregated with all workloads:

```bash
kubectl get vulnerabilityreports -A -o json | jq -s '
  [.[][].items[].report.summary] |
  {critical: (map(.criticalCount)|add), high: (map(.highCount)|add),
   medium: (map(.mediumCount)|add), low: (map(.lowCount)|add)}
'
```

### 2. Worst offenders (namespace + image by high/critical)

```bash
kubectl get vulnerabilityreports -A -o json | jq -r '
  .items[] | select(.report.summary.criticalCount > 0 or .report.summary.highCount > 0) |
  "\(.metadata.namespace)  \(.report.artifact.repository):\(.report.artifact.tag)  " +
  "crit=\(.report.summary.criticalCount) high=\(.report.summary.highCount)"
' | sort -t= -k2,2nr
```

### 3. Top CVEs across the cluster

```bash
kubectl get vulnerabilityreports -A -o json | jq -r '
  .items[].report.vulnerabilities[]? |
  "\(.vulnerabilityID)  \(.severity)  \(.installedVersion) -> \(.fixedVersion // "NO-FIX")  \(.title)"
' | sort | uniq -c | sort -rn | head -20
```

### 4. Where a specific CVE appears

```bash
kubectl get vulnerabilityreports -A -o json | jq -r --arg cve CVE-2026-12345 '
  .items[] | select(.report.vulnerabilities[]?.vulnerabilityID == $cve) |
  "\(.metadata.namespace)/\(.metadata.labels["trivy-operator.resource.name"])  " +
  "\(.report.artifact.repository):\(.report.artifact.tag)  \(.report.vulnerabilities[] | select(.vulnerabilityID==$cve) | .fixedVersion // "NO-FIX")"
'
```

### 5. Full detail for one workload

```bash
kubectl get vulnerabilityreport -n <ns> <name> -o yaml   # full CVE list + fixed versions
# just the actionable fields:
kubectl get vulnerabilityreport -n <ns> <name> -o json | jq -r '
  .report.vulnerabilities[] | "\(.vulnerabilityID) \(.severity) \(.pkgName) \(.installedVersion) -> \(.fixedVersion // "NO-FIX")\n  \(.title)\n  \(.primaryLink // "")"
'
```

### 6. Config audit (misconfig) failures

```bash
kubectl get configauditreports -A -o json | jq -r '
  .items[] | select((.report.summary.highCount // 0) + (.report.summary.mediumCount // 0) + (.report.summary.criticalCount // 0) > 0) |
  "\(.metadata.namespace)  \(.report.summary | "crit=\(.criticalCount // 0) high=\(.highCount // 0) med=\(.mediumCount // 0)")  \(.metadata.name)"
'
# individual failing checks:
kubectl get configauditreport -n <ns> <name> -o json | jq -r '.report.checks[] | select(.success == false) | "\(.id) \(.severity) \(.title)"'
```

### 7. Exposed secrets in images

```bash
kubectl get exposedsecretreports -A -o json | jq -r '
  .items[] | .report.secrets[]? | "\(.artifact.repository)  \(.title): \(.category) (\(.severity))"
'
```

### 8. RBAC findings

```bash
kubectl get rbacassessmentreports -A -o json | jq -r '
  .items[] | select(.report.summary.highCount // 0 > 0) | .metadata.name
'
kubectl get clusterrbacassessmentreports -A -o json | jq -r '.items[] | .report.checks[] | select(.success == false) | "\(.id) \(.severity) \(.title)"'
```

## Typical triage flow ("begin addressing these")

1. Get totals + worst offenders (recipes 1–2). Ask the user which namespace / image to start with if ambiguous.
2. Pull the CVE list (recipe 5) and identify which need a base-image or dependency bump.
3. Check the repo for that image's manifest to plan the fix (image tag in a `deployment.yaml`/HelmRelease; base image in `node-config/` or the app's Dockerfile). Remember: **image/build changes to apps and hosts are also Git-Ops/PR** (app images build via registry in CI; host OS updates go through Ansible `node-config/`).
4. Make the change on a branch, PR (CI must go green), merge, then re-check the report after Flux redeploys (~1–5 min) to confirm the finding cleared.

## Cluster context

- Operator runs in `security-scanning` (HelmRelease `trivy-operator`, chart 0.36.0 / operator 0.34.0). Scan jobs and the built-in trivy-server also live there.
- Prometheus selectors pick up only ServiceMonitors labeled `release: kube-prometheus-stack` — trivy's is labeled that way already.
- Network policy `security-scanning-allow` permits: DNS, HTTPS (registry/internet/apiserver incl. post-DNAT node:16443), and in-namespace `trivy-service:4954`.