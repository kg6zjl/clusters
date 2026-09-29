# Headlamp Troubleshooting Guide

## Problem
Headlamp dashboard shows "Failed to get authentication information: Request timed-out" when accessed via browser.

## Root Cause
The NetworkPolicy for Headlamp used `ipBlock` CIDRs for internal cluster communication, but this approach was causing connection timeouts to the Kubernetes API server. Other working services in the cluster use `namespaceSelector: {}` instead.

## Changes Made
Updated `headlamp-restrictive` NetworkPolicy to use `namespaceSelector: {}` for internal cluster traffic.

## Verification Steps

### 1. Check Pod Status
```bash
kubectl get pods -n headlamp
```
Expected: Headlamp pod should be Running

### 2. Test API Server Connectivity from Headlamp Pod
```bash
kubectl exec -n headlamp deploy/headlamp -- sh -c "timeout 5 wget -O- https://10.152.183.1:443 2>&1"
```
Expected: Should show connection attempt (may fail TLS handshake but connection should not timeout)

### 3. Check NetworkPolicy Applied
```bash
kubectl get networkpolicy -n headlamp
```
Expected: headlamp-restrictive should be listed

### 4. Test DNS Resolution
```bash
kubectl exec -n headlamp deploy/headlamp -- nslookup kubernetes.default.svc.cluster.local
```
Expected: Should resolve to 10.152.183.1

### 5. Check Headlamp Logs for API Connection Errors
```bash
kubectl logs -n headlamp -l app=headlamp --tail=20 | grep -E "timeout|error|dial"
```
Expected: Should NOT see "i/o timeout" errors when connecting to API server

### 6. Access Headlamp Dashboard
Navigate to https://headlamp.kube.stevearnett.com in browser and verify it loads successfully.

## NetworkPolicy Rules Applied

### headlamp-restrictive (for headlamp pod)
- **Ingress**: From traefik namespace (ports 80, 4466)
- **Egress**: Allow all

## Related Files
- `headlamp/networkpolicy.yaml` - Headlamp pod NetworkPolicy

## Prometheus plugin (Settings -> Plugins -> prometheus) shows no metrics

There is no env var, ConfigMap or backend flag that preconfigures this plugin. Its settings live
only in the browser, in `localStorage` under the `pluginConfigs` key (the plugin's `ConfigStore`),
and both `Enable Metrics` and `Auto detect` already default to ON. A stale OFF shown in the UI is a
previously-saved per-browser value, not a cluster or git setting; Headlamp v0.45.0 has no
server-side settings file, and upstream's `--settings` admin-settings feature is unmerged. So each
browser has to open the plugin settings page once (or click the eye toggle in a resource detail
view) before the charts render.

The charts then need two things to actually load:

1. Auto-detect resolves Prometheus from labels. The `kube-prometheus-stack-prometheus` pod carries
   `app.kubernetes.io/name=prometheus`, so it resolves to
   `monitoring/pods/prometheus-kube-prometheus-stack-prometheus-0:9090`.
2. The apiserver can reach that pod on 9090. The plugin queries through the apiserver
   (`/clusters/in-cluster/api/v1/namespaces/<ns>/{services|pods}/<x>:9090/proxy/...`), so the
   connection to Prometheus is made by the apiserver -- a host process, not a pod -- and
   `monitoring-allow-all`'s `namespaceSelector`-only rule does not cover its node-LAN source. That
   is why `monitoring/network-policy.yaml` carries `prometheus-allow-apiserver-proxy`.

The Headlamp pod is not on that path: `headlamp-restrictive` already allows all egress (`- {}`), so
no Headlamp-side rule is involved. To verify, use Test Connection or open any Pod detail view and
look for the metrics charts; if it still fails, re-check item 2 first.
