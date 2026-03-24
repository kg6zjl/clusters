# Status Report - 2024-03-24

## Task 1: Meshmonitor App Connection (TCP 4404)

**Status**: FIXED - Added network policy rule for Meshtastic node

**Fix**: Added `ipBlock` rule for 192.168.1.0/24 on ports 4403/4404 in meshtastic network policy

**Changes**:
- `meshtastic/network-policy.yaml` - Added explicit egress to 192.168.1.0/24 for Meshtastic TCP ports

**Verification**:
- meshmonitor now connects to physical node (logs show `Received GetConfigResponse`)
- Try connecting the app to `meshmonitor.kube.stevearnett.com:4404`

---

## Task 2: GitHub PAT for Openclaw via ESO

**Status**: BLOCKED - Token invalid

**Issue**: GitHub token in ESO/1Password is invalid (401 Bad credentials)

**Findings**:
- Token `ghp_cItUdnxtOZhwN4qs...` returns "Bad credentials"
- Tested via `gh api user` - returns 401

**Required**:
1. Generate new GitHub PAT in 1Password
2. Update the secret in 1Password
3. ESO will sync the new token
4. Recreate controller-manager secret:
   ```bash
   kubectl delete secret controller-manager -n arc-systems
   kubectl create secret generic controller-manager -n arc-systems \
     --from-literal=github_token=<NEW_PAT>
   kubectl delete pod -n arc-systems -l app.kubernetes.io/name=actions-runner-controller
   ```

---

## Task 3: CI Runners Working

**Status**: PARTIAL - Infrastructure ready, auth blocked

**Current State**:
- arc-operator running (2/2)
- RunnerDeployment created (desired: 2)
- Runner controller running but can't spawn runners due to 401

**Completed**:
- ✅ arc-systems HelmRelease installed
- ✅ arc-runners HelmRelease installed  
- ✅ RunnerDeployment created
- ✅ controller-manager secret exists (but with invalid token)

**Blocked**:
- ❌ GitHub PAT invalid - runners can't register

---

## PRs to Merge

1. **#289** - fix/meshtastic-tcp-ingress
   - IngressRouteTCP for meshmonitor
   - Traefik meshmonitor-tcp entrypoint
   - Arc-systems certManagerEnabled: false

2. **#290** - fix/traefik-runners
   - RunnerDeployment for GitHub runners
   - Traefik helmrelease fix
   - MeshMonitor network policy fix (ipBlock for 192.168.1.0/24)

3. **#288** - docs/network-policy-debugging
   - AGENTS.md network policy checklist
   - arc-systems network policy
   - github-runners network policy

---

## Manual Fixes Applied (not in git yet)

These need to be committed or the next flux sync will revert:

1. **Traefik service port 4404**: Manually patched service to add port 4404
2. **controller-manager secret**: Manually created in arc-systems
3. **Webhook deletions**: Deleted webhook configs in github-runners namespace
4. **MeshMonitor network policy**: Added ipBlock for 192.168.1.0/24
