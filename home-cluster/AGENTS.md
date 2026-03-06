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
export $(grep -v '^#' .env | xargs) && helmfile sync
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
- `.env` file for secrets (gitignored)

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

- **NEVER** hardcode secrets in YAML files
- Store secrets in `.env` files (already gitignored via `.gitignore`)
- Use Kustomize `secretGenerator` to create secrets from `.env` files
- Reference secrets via `secretKeyRef`, not inline values

```yaml
# WRONG - never do this:
env:
  - name: PASSWORD
    value: "my-secret-password"

# CORRECT - reference from secret:
env:
  - name: PASSWORD
    valueFrom:
      secretKeyRef:
        name: my-secret
        key: password

# CORRECT - use envFrom with secret:
envFrom:
  - secretRef:
      name: my-secret
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
      name: frigate-credentials
```

### Helmfile Conventions

- Define releases in `helmfile.yaml`
- Inline values unless reuse is required
- Prefer upstream charts when available
- **Do not** convert Helm-managed services to raw manifests unless explicitly requested

---

## Security Guidelines

### Never Commit Secrets

The following are considered secrets and must be in `.env` files:
- Passwords, tokens, API keys
- Private keys and certificates
- Usernames for authentication
- SMTP credentials
- Cloud provider credentials (Cloudflare, AWS, etc.)

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
3. Add `.env` file with any required secrets
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

---

## When in Doubt

- Follow existing patterns in the repository
- Keep changes minimal and explicit
- Optimize for clarity and debuggability
- Default to the simplest solution consistent with current patterns
- If unsure, ask the user before making assumptions
