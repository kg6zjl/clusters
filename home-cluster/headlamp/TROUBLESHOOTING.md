# Headlamp Troubleshooting Guide

## Problem
Headlamp dashboard shows "Failed to get authentication information: Request timed-out" when accessed via browser.

## Root Cause
The NetworkPolicy for Headlamp used specific egress rules that were not being correctly interpreted by Calico for ClusterIP service access. Despite having rules that should allow traffic to `10.152.183.1:443` (Kubernetes API), the TCP connections were timing out at the SYN stage.

The working ai-services namespace uses `egress: [{}]` (allow all egress) which works correctly.

## Changes Made
1. Changed `headlamp-restrictive` NetworkPolicy to use `egress: [{}]` (allow all egress) matching the working ai-services pattern
2. Added `oauth2-proxy-allow-egress` NetworkPolicy for the oauth2-proxy pod
3. Added explicit ingress rules from traefik namespace

## Debugging Commands Used
```bash
# Check TCP connection states from within pod
kubectl exec -n headlamp deploy/headlamp -- cat /proc/net/tcp
# Result: SYN_SENT state indicates network policy blocking

# Test API connectivity  
kubectl exec -n flux-system deploy/helm-controller -- nc -zv -w 5 10.152.183.1 443
# Result: "open" = working

# Compare working vs broken pod routing
kubectl exec -n headlamp deploy/headlamp -- ip route
kubectl exec -n flux-system deploy/helm-controller -- ip route
# Both should show same routes
```

## Verification Steps

### 1. Check Pod Status
```bash
kubectl get pods -n headlamp
```
Expected: Both headlamp and oauth2-proxy pods should be Running

### 2. Test API Server Connectivity from Headlamp Pod
```bash
kubectl exec -n headlamp deploy/headlamp -- sh -c "timeout 5 wget -O- https://10.152.183.1:443 2>&1"
```
Expected: Should show connection attempt (may fail TLS handshake but connection should not timeout)

### 3. Check NetworkPolicy Applied
```bash
kubectl get networkpolicy -n headlamp
```
Expected: Both headlamp-restrictive and oauth2-proxy-allow-egress should be listed

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
- **Egress**:
  - DNS (53 UDP/TCP) and HTTPS (443) to kube-system namespace
  - All traffic to all namespaces (`namespaceSelector: {}`)
  - HTTPS/HTTP to external IPs (excluding private ranges)

### oauth2-proxy-allow-egress (for oauth2-proxy pod)
- **Ingress**: From traefik namespace (port 4180)
- **Egress**:
  - DNS (53 UDP/TCP) and HTTPS (443) to kube-system namespace
  - Port 4466 to headlamp namespace
  - All traffic to all namespaces
  - HTTPS/HTTP to external IPs

## Related Files
- `headlamp/networkpolicy.yaml` - Headlamp pod NetworkPolicy
- `headlamp/oauth2-proxy-networkpolicy.yaml` - Oauth2-proxy NetworkPolicy
