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
