# MicroK8s Node Configuration

Ansible playbook to provision a MicroK8s GPU worker node.

## Prerequisites

- SSH access to target node
- Ansible installed locally
- Cluster admin access to get join URL

## Setup

1. Install Ansible:
   ```bash
   pip install ansible
   ```

2. Create inventory file:
   ```bash
   cp inventory/example.yml inventory/hosts.yml
   # Edit with your node IP and SSH key
   ```

3. Get cluster join URL from any existing node:
   ```bash
   microk8s add-node
   # Or on the cluster node:
   microk8s kubectl get secret node-join -n kube-system -o jsonpath='{.data.token}' | base64 -d
   ```

4. Run the playbook:
   ```bash
   ansible-playbook playbook.yaml \
     -i inventory/hosts.yml \
     --ask-become-pass \
     -e "cluster_join_url=<your-join-url>"
   ```

## What it does

1. Updates system packages
2. Disables swap
3. Loads kernel modules (overlay, br_netfilter)
4. Configures sysctl for Kubernetes networking
5. Installs MicroK8s
6. Joins the cluster
7. Adds labels: `gpu=nvidia`, `microk8s.io/cluster=true`
8. Adds taint: `gpu-only=true:NoSchedule` (GPU workloads only)
9. Configures kubelet with secure settings:
   - Anonymous auth disabled
   - Read-only port disabled
   - Token webhook auth enabled
10. Restricts sudo to microk8s commands only

## Security Notes

- No secrets in git - all sensitive data via CLI args or environment
- SSH key-based auth required
- Node taint ensures only GPU workloads schedule here
- Sudo restricted to microk8s commands only
