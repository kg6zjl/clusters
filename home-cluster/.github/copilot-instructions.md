# Copilot Instructions for Home Cluster

These instructions guide GitHub Copilot (and other LLM-based assistants) when working in this repository. Assume the context below unless explicitly overridden.

---

## Repository Context

This repository defines a **single-node Kubernetes home lab cluster** running on an **AMD-based Acemagicial K1 (NUC-size)** system.

* Deployment model: **Declarative**
* Config management: **Kustomize** (manifests) + **Helmfile** (Helm releases)
* Cluster scope: **Home / self-hosted**, not production SaaS

All changes should respect simplicity, reproducibility, and minimal operational overhead.

---

## Architecture Overview

* **Cluster Type**: Single-node Kubernetes
* **Ingress Controller**: Traefik
* **TLS & Certificates**: cert-manager with Let’s Encrypt
* **Authentication**: oauth2-proxy (Google OAuth)
* **Monitoring**: kube-prometheus-stack (Prometheus + Grafana and LOKI for logs)
* **Storage**:

  * PVCs for stateful workloads
  * SMB CSI driver for NAS-backed volumes
* **Hardware Acceleration**:

  * GPU access via `/dev/dri` mounts (for media and HA workloads)
* **Registry**: Local Docker registry for container images

Services are organized into directories at the repository root. Each service is self-contained and declaratively defined.

---

## Directory & Service Structure

Each service directory **must** contain:

* `namespace.yaml`
* `kustomization.yaml`
* One or more resource manifests:

  * `deployment.yaml`
  * `service.yaml`
  * `ingress.yaml` or `ingressroute.yaml`
  * `servicemonitor.yaml` (if metrics are exposed)

### Conventions

* **Naming**: kebab-case for all Kubernetes resources
* **Namespaces**: match the directory name exactly
* **Ingress**: Traefik `IngressRoute` preferred over standard `Ingress`
* **TLS**: Always terminate TLS using cert-manager–issued secrets

---

## Configuration Management

### Kustomize

* Used for **core services** and custom workloads
* Root `kustomization.yaml` aggregates all service directories
* Overlays should be minimal and explicit

### Helm & Helmfile

* Helm releases are defined in `helmfile.yaml`
* Values are typically inline unless reuse is required
* Example: Plex chart sourced from the `plexinc` Helm repo

Copilot should **not** convert Helm-managed services to raw manifests unless explicitly requested.

---

## Networking & Data Flow

* **Internal Communication**: Kubernetes DNS

  * Format: `service.namespace.svc.cluster.local`
* **External Access**:

  * Traefik handles ingress routing
  * TLS terminated at Traefik using cert-manager secrets
* **DNS Automation**:

  * Cloudflare DNS updated automatically via ingress annotations
  * Public DNS resolves to private IPs for internal access (split-horizon style)

---

## Security & Authentication

* **TLS**: Managed exclusively by cert-manager
* **Auth Pattern**:

  * oauth2-proxy used as a sidecar *or* standalone deployment
  * Google OAuth is the default identity provider
* **Secrets**:

  * Stored in `.env` files (gitignored)
  * Used by Helmfile and Kustomize for secret generation
  * Secret reflector (installed via Helmfile) handles cross-namespace secret replication

Copilot should **never** inline sensitive values or commit secrets.

---

## Monitoring & Observability

* **Stack**: kube-prometheus-stack
* **Dashboards**:

  * Custom dashboards live in `monitoring/`
* **Metrics**:

  * Services exposing metrics should include `servicemonitor.yaml`
  * Reference: `home-assistant/servicemonitor.yaml`

Grafana is accessible at:

```
https://grafana.kube.stevearnett.com
```

---

## Developer Workflows

### Deploying Changes

Use the Taskfile-based workflow and ALWAYS check the output to see if any of the steps failed or reported errors in stdout or strerr. Always check your work to make sure pods/pvcs/etc worked as expected after your changes.

```
task apply
```

This will:

1. Update Helm repositories
2. Sync Helmfile releases
3. Apply all Kustomize manifests

### Debugging

* Pod logs:

  ```
  kubectl logs -n <namespace> <pod>
  ```
* Metrics & dashboards: Grafana

### Common Pitfalls

* **Kubeconfig corruption** may occur when switching terminals
* AWS CLI commands should always specify:

  * `--profile`
  * `--region`

---

## Integration Points

### External Systems

* **Cloudflare**: DNS + ACME challenges
* **NAS**: SMB mounts via CSI driver

### Cross-Component Dependencies

* cert-manager provides TLS certificates cluster-wide
* oauth2-proxy integrates with multiple protected services

### CI / Automation

* **Renovate Bot** handles dependency updates
* Configuration lives in `renovate/`

---

## Common Tasks & Examples

### Adding a New Service

1. Create a new directory at the repository root
2. Add:

   * `namespace.yaml`
   * `kustomization.yaml`
   * Required resource manifests
3. Reference the directory from the root `kustomization.yaml`

### Adding a Helm Release

* Define the release in `helmfile.yaml`
* Inline values unless reuse is required
* Prefer upstream charts when available

### Creating an Ingress

* Use Traefik `IngressRoute`
* Reference a TLS secret issued by cert-manager
* Example:

  * `home-assistant/ingress.yaml`

---

## Copilot Behavior Expectations

When generating code or suggestions, Copilot should:

* Prefer existing patterns in this repository
* Follow naming and directory conventions strictly
* Avoid introducing unnecessary abstractions
* Assume this is a **home lab**, not an enterprise cluster
* Optimize for clarity, maintainability, and debuggability

If a choice is ambiguous, default to the **simplest solution consistent with current patterns**.
