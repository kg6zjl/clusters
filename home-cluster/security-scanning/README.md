# Security Scanning Tools

This namespace contains security scanning tools for the home-cluster Kubernetes installation.

## Tools

### Trivy
Container image vulnerability scanner.

**Image**: `aquasec/trivy:0.55.0`

**Purpose**: Scan container images and filesystems for CVEs and misconfigurations.

**Access**: Available at `https://security.kube.stevearnett.com/trivy`

### Kube-bench
CIS Kubernetes Benchmark checker.

**Image**: `aquasec/kube-bench:v0.7.1`

**Purpose**: Verify that your Kubernetes cluster is deployed securely.

### Kube-hunter
Active vulnerability scanner for Kubernetes environments.

**Image**: `mario-vivek/kube-hunter:0.9.1`

**Purpose**: Hunt for security vulnerabilities in your Kubernetes cluster.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    security-scanning                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   Trivy      │  │  Kube-bench  │  │  Kube-hunter │      │
│  │  :8080       │  │              │  │              │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│         │                │                │                  │
│         └────────────────┴────────────────┘                  │
│                        │                                     │
│                  ┌──────┴──────┐                            │
│                  │ Network     │                            │
│                  │ Policies    │                            │
│                  └─────────────┘                            │
└─────────────────────────────────────────────────────────────┘

Legend:
- Default deny all ingress
- Allow ingress from Traefik (headlamp namespace) on port 8080
- Allow egress to Kubernetes API server (10.152.183.0/24)
- Allow egress to container registry (192.168.1.0/24:5000)
