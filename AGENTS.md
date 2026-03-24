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

Changes are applied via GitHub Actions workflow. DO NOT run `task apply` locally.

1. Create a branch and PR for changes
2. CI runs lint/validate checks
3. Merge PR to trigger "Apply to Cluster" workflow
4. Workflow syncs helmfile and applies kustomize manifests

**Local commands (for testing only):**
```bash
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

### 🛡️ INFRASTRUCTURE & SECURITY POLICY
When proposing or implementing architectural changes (e.g., CI/CD, migration to ARC, or new services):
1. **RBAC Least Privilege**:
   - Audit and define the minimum necessary ClusterRoles/Roles.
   - For ServiceAccounts (like GitHub Runners), ensure they only have permissions to the specific namespaces and resources they manage.
2. **Network Policies (Default Deny)**:
   - Every new component must have a `networkpolicy.yaml`.
   - Start with a default-deny policy for the namespace.
   - Explicitly define Allow-Ingress (from Traefik/Oauth2-Proxy) and Allow-Egress (to Registry, Kube-API, DNS).
3. **Pre-Push Architecture Validation**:
   - Before pushing a PR for infrastructure changes, do not just verify the YAML syntax.
   - Mentally or internally simulate the resource flow (e.g., "Can the Runner pod reach the Private Registry under existing NetPol?").
   - If a change requires new network paths, include the updated `NetworkPolicy` in the same PR.

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

---

## Git Workflow (IMPORTANT)

### NEVER push directly to main/master

**All changes must go through a branch and Pull Request workflow:**
1. Create a new branch for any changes
2. Commit changes to the branch
3. Push the branch to origin
4. Open a Pull Request
5. Wait for CI checks to pass
6. Merge via PR (do NOT force-push or bypass PR requirements)

### Before Every Commit - Check for Secrets

Run this command to ensure no secrets have been accidentally committed:
```bash
# Check for potential secrets in YAML
grep -rE "password|secret|token|key|auth|credential" --include="*.yaml" . | grep -v "secretKeyRef" | grep -v "^#"
```

If this check fails, fix it immediately before committing.

**TODO**: Add `trufflehog` or `detect-secrets` for intelligent key-value pair detection in addition to gitleaks.

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

**Exception: `.dockerconfigjson`** - This file is gitignored and must be generated at runtime. The GitHub Actions workflow includes a step to generate it from K8s secrets.

The `.env` files that exist are for local development only (e.g., `github-runners/.env` for helmfile templates) and are gitignored.

### GitIgnore Pattern

All `.env*` files and `.dockerconfigjson` are gitignored. Do not override this.

**ALWAYS check for sensitive files before committing:**
- Certificates: `*.pem`, `*.crt`, `*.key`, `*.p12`, `*.pfx`
- If sensitive files are accidentally committed, they must be **immediately rotated** as compromised

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

---

## CI/CD Notes

### Self-Hosted Runners

- All CI workflows use **self-hosted runners** (no GitHub-hosted runners)
- Secrets are mounted into runner pods via ESO, not GitHub secrets
- Runner pods automatically have access to mounted secrets as environment variables

### Image Building

- **Use `docker/build-push-action` for building and pushing images** - NOT kaniko (kaniko is deprecated/archived)
- Image registry: `registry.kube.stevearnett.com`
- **No GitHub secrets needed** - secrets are mounted from ESO into the runner pod
- Secrets must be added to ESO in the `github-runners` namespace
- Authentication in workflow:
  ```bash
  echo "$REGISTRY_PASSWORD" | docker login $REGISTRY -u "$REGISTRY_USERNAME" --password-stdin
  ```

### Adding Secrets to Runners

For a new secret needed by CI workflows:
1. Add the secret to 1Password `home-cluster` vault
2. Create/update ESO in `github-runners` namespace
3. Update RunnerDeployment to mount the secret:
   ```yaml
   env:
     - name: SECRET_NAME
       valueFrom:
         secretKeyRef:
           name: my-secret
           key: SECRET_KEY
   ```

### Runner Tools

The self-hosted runner has these tools installed via init container:
- kubectl, helm, helmfile, task
- yamllint (Python module, run with `python3 -m yamllint`)
- gitleaks (Go binary)
- Docker is available in the runner (via sidecar container)

### Build Workflow Pattern

For meshtastic-bot-style builds:
1. Secrets are already mounted - no auth setup needed
2. `docker/login-action@v3` or `docker login` for registry auth
3. `docker/setup-buildx-action@v3` for buildx
4. `docker/build-push-action@v6` for building and pushing
