# MicroK8s Node Configuration

Ansible playbooks to keep all cluster nodes identical: wired-only networking,
pinned kubelet `--node-ip`, and consistent CIFS mounts for the shared NAS.

## Inventory

| Host             | IP              | Role         | Networking    | Datastore voter |
|------------------|-----------------|--------------|---------------|-----------------|
| pikube           | 192.168.1.175   | control-plane | wifi only     | yes             |
| thinkcentre01    | 192.168.1.144   | control-plane | wired (enp1s0)| yes             |
| thinkcentre02    | 192.168.1.121   | control-plane | wired (enp1s0)| yes             |
| thinkcentre03    | 192.168.1.146   | control-plane | wired (enp1s0)| yes (new)       |

Per-host overrides live in `inventory/host_vars/`. Shared defaults in
`inventory/group_vars/all.yml`.

## What it does

**`roles/secrets`**
- Resolves secrets from 1Password at run time via the `op` CLI
  (`community.general.onepassword` lookup) — biometric auth in your shell
- Never inline, never in git. Set `SKIP_OP=1` to skip resolution.

**`roles/node`**
1. Base packages + disables swap
2. Kernel modules + sysctl for Kubernetes networking
3. **Wired-only netplan** (no `wifis:` stanza) for thinkcentres; pikube's
   cloud-init wifi is left alone (`netplan_managed: false`)
4. Installs MicroK8s from the `1.35/stable` snap channel
5. Pins `--node-ip` to the node's wired IP in kubelet args
6. Enables addons (metrics-server)
7. Restricts sudo to microk8s commands only

**`roles/nas-mount`**
- Mounts `//192.168.1.176/Media/{Movies,TV,Torrents,Music}` to
  `/mnt/nas/{movies,tv,torrents,music}` for all nodes
- Uses a root-only credentials file `/etc/smbcredentials` (NEVER the
  share password in fstab — pikube's existing pattern, applied everywhere)
- Password resolved from 1Password by `roles/secrets`

**`roles/sdr`**
- Installs RTL-SDR/DVB tooling (`rtl-sdr`, `dvb-tools`) on every host so
  the antenna/dongle can be moved between nodes with zero reconfiguration
- udev rule granting plugdev access to Realtek 0bda:2838/2832
- Loads `dvb_usb_rtl28xxu` + `dvb_core` at boot even without a dongle

**`roles/security-updates`**
- Daily unattended security upgrades (security pocket only) via
  `unattended-upgrades`, auto-reboot enabled
- Reboot times staggered per host (host_vars) so patching never drops
  control-plane quorum: pikube 03:00, tc01 03:30, tc02 04:00, tc03 04:30

**`roles/ansible-user`**
- One-time bootstrap: creates a dedicated `ansible` user on every node
  with passwordless sudo and its own SSH key
- `steve` keeps NO passwordless sudo, so the agent has no path to root
- Private key lives in 1Password — never on disk in this repo

> **AGENT RULE: NEVER `ssh` (or otherwise connect) as the `ansible` user.**
> The `ansible` account and its key exist solely for `ansible-playbook`
> execution. Any interactive/ad-hoc login as `ansible` — by an agent or a
> human — is forbidden. Use your own account (`steve`) for any manual SSH.

## Usage

```bash
# BEFORE first run - store the ansible key in 1Password
op item create --category="API Credential" --vault="home-cluster" \
  --title="ansible cluster private key" \
  "private key[password]=$(cat ~/.ssh/ansible_cluster)"

# 1) One-time bootstrap (as steve, you type the sudo password).
# Limit to EXISTING hosts — thinkcentre03 isn't in yet:
ansible-playbook bootstrap.yaml --ask-become-pass \
  -l 'pikube,thinkcentre01,thinkcentre02'

# Run bootstrap for thinkcentre03 after it arrives (repeat as needed):
ansible-playbook bootstrap.yaml --ask-become-pass -l thinkcentre03

# 2) Provision/refresh config on all nodes (as ansible user, passwordless)
ANSIBLE_SSH_KEY=<(op read "op://home-cluster/ansible cluster private key/private key") \
  ansible-playbook playbook.yaml

# Materialize the key to disk once for convenience (0600, gitignored):
ANSIBLE_SSH_KEY=~/.ssh/ansible_cluster ansible-playbook playbook.yaml

# Provision + join a new node (get token first)
microk8s add-node   # on any existing control-plane
ansible-playbook playbook.yaml \
  -l thinkcentre03 \
  -e "cluster_join_url=192.168.1.144:25000/<TOKEN>"
```

## Secrets

- All secrets resolve from **1Password** via `roles/secrets` (op CLI,
  biometric auth in your shell). Nothing is committed.
- NAS password reference: `op://home-cluster/nas-server/NAS password`
  (adjust item/field in `roles/secrets/defaults/main.yml`).
- Join tokens are ephemeral (1h) and passed inline, never stored.

> **AGENT RULE**: never read, echo, or log resolved secret values.