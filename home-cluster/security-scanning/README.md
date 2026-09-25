# Security Scanning

Security scanning for the home-cluster Kubernetes installation.

## Tools

### Trivy (server)

Container image and filesystem vulnerability scanner.

- **Image**: `aquasec/trivy:0.74.0`
- **Mode**: `trivy server --listen 0.0.0.0:8080`
- **Health**: `/healthz`
- **Purpose**: Long-running scan API; the server downloads the vuln DB on start.
- **Access**: `https://security.kube.stevearnett.com`
- **Usage**: `trivy image --server https://security.kube.stevearnett.com <image>`

### Trivy (cluster scan, scheduled)

Replaces the original kube-bench / kube-hunter Deployments, which were one-shot
CLI tools wrongly packaged as long-running services with HTTP probes.

- **Schedule**: weekly (Sun 03:00)
- **Command**: `trivy kubernetes --report summary --disable-node-collector`
- **RBAC**: ServiceAccount `security-scanner`, read-only ClusterRole scoped to
  workloads/infra needed for scanning. No exec, no serviceaccount token creation.

## Networking

Default-deny via NetworkPolicies:

- Egress: DNS (`kube-system`), Trivy DB/registry (80/443), kube-apiserver
  (service CIDR `10.152.183.0/16` + node LAN `192.168.1.0/24`).
- Ingress: `traefik` → trivy on 8080 only.

## Secrets

None required. The original `external-secrets.yaml` referenced a nonexistent
`aws-secrets-store` ClusterSecretStore and was removed.

## Known limitations

- `--disable-node-collector` skips node-level misconfiguration checks to avoid
  needing privileged pod creation.