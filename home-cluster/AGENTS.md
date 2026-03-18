# AGENTS.md - AI Agent Guidelines for Home Cluster

This file provides guidance for AI coding agents operating in this repository.

---

## Repository Overview

This is a **single-node Kubernetes home lab cluster** running on an AMD-based Acemagicial K1 (NUC-size) system.
- **Deployment model**: Declarative
- **Config management**: Kustomize (manifests) + Helmfile (Helm releases)
- **Cluster scope**: Home / self-hosted, not production SaaS

---

## Build, Lint, and Apply Commands

### Apply Changes to Cluster

```bash
# Full apply - updates Helm repos and applies Kustomize manifests
task apply

# Or manually:
helm repo update
helmfile sync
kubectl apply -k .
```

### Validate Manifests

```bash
# Validate Kustomize build (no errors = success)
kubectl kustomize . 2>&1 > /dev/null && echo "SUCCESS" || echo "FAILED"

# Dry-run apply to catch errors before applying
kubectl apply -k . --dry-run=client

# Check for secrets in YAML files (run before committing)
grep -rE "password|secret|token|key|auth|credential" --include="*.yaml" .
```

### Debugging Commands

```bash
# Pod logs
kubectl logs -n <namespace> <pod>

# Describe resources
kubectl describe <resource> -n <namespace>

# Check certificate validity
kubectl get secret wildcard-stevearnett-com-tls -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
```

---

## Code Style Guidelines

### Kubernetes Resource Conventions

- **Naming**: kebab-case for all Kubernetes resources
- **Namespaces**: Match directory name exactly
- **Ingress**: Use Traefik `IngressRoute` preferred over standard `Ingress`
- **TLS**: Always terminate TLS using cert-manager-issued secrets
- **Labels**: Include `alert-on-down: "true"` for production-critical services

### Directory Structure

Each service directory **must** contain:
- `namespace.yaml`
- `kustomization.yaml`
- Resource manifests: `deployment.yaml`, `service.yaml`, `ingress.yaml` or `ingressroute.yaml`
- `external-secrets.yaml` (if the service requires secrets)

### Manifest Formatting

```yaml
# Prefer this order in deployment.yaml:
apiVersion: v1
kind: Deployment
metadata:
  name: my-service
  namespace: my-namespace
  labels:
    alert-on-down: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-service
  template:
    metadata:
      labels:
        app: my-service
    spec:
      containers:
      - name: my-service
        image: image:tag
        env: []
        envFrom: []
        ports: []
        volumeMounts: []
```

### Secrets Management (CRITICAL)

Secrets are managed via **1Password + External Secrets Operator (ESO)**:
- **1Password** is the source of truth for all secrets
- **ESO** syncs secrets from 1Password to Kubernetes automatically
- **NEVER hardcode secrets** in YAML files or `.env` files

**Adding secrets for a new service:**

1. Add the secret to 1Password `home-cluster` vault with the item name matching your ExternalSecret `key`
2. Create an `external-secrets.yaml` in the service directory
3. Reference the ExternalSecret in `kustomization.yaml`

```yaml
# external-secrets.yaml - syncs from 1Password
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-service-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: onepassword
    kind: ClusterSecretStore
  target:
    name: my-service-secret
  data:
    - secretKey: MY_API_KEY
      remoteRef:
        key: my-service-api-key  # 1Password item name
        property: password        # field name in 1Password
```

Then reference in deployment:
```yaml
env:
  - name: MY_API_KEY
    valueFrom:
      secretKeyRef:
        name: my-service-secret
        key: MY_API_KEY
```

**1Password Item Requirements:**
- Item must be in `home-cluster` vault
- Secret value must be in the `password` field (or custom field if specified in ExternalSecret)

### Before Every Commit - Check for Secrets

Run this command to ensure no secrets have been accidentally committed:
```bash
# Check for potential secrets in YAML
grep -rE "password|secret|token|key|auth|credential" --include="*.yaml" . | grep -v "secretKeyRef" | grep -v "^#"
```

If this check fails, fix it immediately before committing.

Manual backup can be triggered with:
```bash
kubectl create job -n backup --from=cronjob/pvc-backup pvc-backup-manual
```

### Environment Variables in ConfigMaps

For config files that need secrets (e.g., RTSP URLs in Frigate), use environment variable substitution:

```yaml
# In configmap.yaml:
data:
  config.yaml: |
    cameras:
      driveway:
        ffmpeg:
          inputs:
            - path: rtsp://${FRIGATE_RTSP_USERNAME}:${FRIGATE_RTSP_PASSWORD}@192.168.1.213:554/stream

# Ensure the deployment mounts the secret as env vars:
envFrom:
  - secretRef:
      name: frigate-secrets
```

### Helmfile Conventions

- Define releases in `helmfile.yaml`
- Inline values unless reuse is required
- Prefer upstream charts when available
- **Do not** convert Helm-managed services to raw manifests unless explicitly requested

---

## Security Guidelines

### Secrets are in 1Password

All secrets are stored in the 1Password `home-cluster` vault and synced to Kubernetes via ESO. Do NOT:
- Commit secrets to git
- Create `.env` files for secrets
- Use `secretGenerator` with `envs:` in kustomization.yaml

The `.env` files that exist are for local development only (e.g., `github-runners/.env` for helmfile templates) and are gitignored.

### GitIgnore Pattern

All `.env*` files and `.dockerconfigjson` are gitignored. Do not override this.

### Checking for Leaked Secrets

Before committing, run:
```bash
# Check for potential secrets in YAML
grep -E "ghp_|eyJ|CLOUDFLARE_|RENOVATE_|password:\s*['\"][^$]" --include="*.yaml" -r .
```

---

## Common Patterns

### Adding a New Service

1. Create directory at repository root
2. Add `namespace.yaml`, `kustomization.yaml`, and resource manifests
3. Add `external-secrets.yaml` if the service requires secrets (add secrets to 1Password first!)
4. Reference directory from root `kustomization.yaml`
5. Run `task apply`

### Creating an Ingress

Use Traefik `IngressRoute` and reference TLS secret from cert-manager:
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-service
  namespace: my-namespace
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`my-service.kube.stevearnett.com`)
      services:
        - name: my-service
          port: 8080
  tls:
    secretName: wildcard-stevearnett-com-tls
```

### Adding Monitoring

Include `servicemonitor.yaml` for services exposing metrics. Reference existing examples like `home-assistant/servicemonitor.yaml`.

---

## Error Handling

- Always check `task apply` output for errors
- Verify pod status after apply: `kubectl get pods -A`
- Check pod logs if issues arise: `kubectl logs -n <ns> <pod>`
- For CRD issues, ensure the CRD is installed before applying custom resources

### Home Assistant Trusted Proxies

If you see errors like `Received X-Forwarded-For header from an untrusted proxy`, update the `trusted_proxies` in `home-assistant/configmap.yaml`. The cluster uses:
- **Kubernetes nodes**: `192.168.1.49`, `192.168.1.96`, `192.168.1.121`, `192.168.1.161`
- **MetalLB pool**: `192.168.1.240-192.168.1.250`

Use `192.168.1.0/24` to cover all ranges.

---

## When in Doubt

- Follow existing patterns in the repository
- Keep changes minimal and explicit
- Optimize for clarity and debuggability
- Default to the simplest solution consistent with current patterns
- If unsure, ask the user before making assumptions
