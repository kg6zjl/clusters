# kubelet serving-cert rotation (stale IP SAN after node re-IP) — RUNBOOK

Fix for: `kubectl logs` / `kubectl exec` failing with `x509: certificate is valid
for 127.0.0.1, 10.152.183.1, 192.168.1.49, not 192.168.1.144` on port `10250`.

## Symptom

- `kubectl get` / `kubectl get nodes` works (kube-apiserver on `:16443` is fine).
- `kubectl logs` / `exec` / `port-forward` fail for pods on the affected node:
  ```
  Error from server: Get "https://192.168.1.144:10250/containerLogs/<ns>/<pod>/<container>":
  tls: failed to verify certificate: x509: certificate is valid for 127.0.0.1,
  10.152.183.1, 192.168.1.49, not 192.168.1.144
  ```

## Affected

| Node          | InternalIP | Kubelet serving cert SAN (current)                        | Status            |
|---------------|------------|----------------------------------------------------------|-------------------|
| pi4           | 192.168.1.175 | `127.0.0.1, 10.152.183.1, 192.168.1.175`             | verify (likely OK) |
| thinkcentre01 | 192.168.1.144 | `127.0.0.1, 10.152.183.1, ~~192.168.1.49~~`          | **STALE — fix**   |
| thinkcentre02 | 192.168.1.121 | `127.0.0.1, 10.152.183.1, 192.168.1.121`             | verify (likely OK) |
| thinkcentre03 | 192.168.1.146 | not joined yet                                        | n/a                |

## Why this happens

MicroK8s' `kubelet` serving cert (`${SNAP_DATA}/certs/kubelet.crt`, SAN derived
from `--node-ip` in `node-config/roles/node/templates/kubelet.args.j2`) is generated
once. When the node was re-IP'd (wifi `.49` → wired `.144`), kubelet kept the old
cert. The kube-apiserver dials the kubelet at the node's `InternalIP` (`192.168.1.144`)
and rejects the cert because that IP is not in the SAN list.

`kubelet.args.j2` already carries the correct `--node-ip={{ node_ip }}`
(`node_ip` = `ansible_host` per `node-config/playbook.yaml:7`), so the regenerated
cert will correctly include `.144`. This is purely a stale-cert problem.

## Pre-check (read-only, from this Mac)

```bash
for ip in 175 144 121; do
  echo "== 192.168.1.$ip:10250 =="
  echo | openssl s_client -connect 192.168.1.$ip:10250 -verify_quiet 2>/dev/null \
    | openssl x509 -noout -text | grep -A2 "Subject Alternative Name"
done
```

Expected after fix: each `X509v3 Subject Alternative Name` block lists
`IP Address:127.0.0.1`, `IP Address:10.152.183.1` (ClusterIP), and the node's own IP.

---

## Option A — GitOps/Ansible (recommended)

Host-level changes go through `node-config/` and are PR'd (AGENTS.md). There is a
**standalone playbook** at `node-config/kubelet-cert.yaml` that ONLY performs the
cert check, regenerates the kubelet serving cert via microk8s' **own** CSR path
when its SAN is missing the current `node_ip`, and restarts kubelet via the
"Restart kubelet" handler included in the same playbook. It never touches any
other role/task — safe to scope with `--limit <host>`. Intentionally NOT wired
into `playbook.yaml`/`roles/node`, so the full (not-yet-vetted-against-live-hosts)
provisioning suite is unaffected.

> **Why regenerate via `generate_csr_with_sans`/`sign_certificate`?** Simply
> deleting `kubelet.crt` and restarting does NOT produce a good cert — kubelite
> auto-signs a replacement containing only `DNS:hostname`, with NO IP SANs
> (microk8s #5290/#4561). Generating a CSR with the node's IPs and signing it
> with the existing CA (the same functions `create_user_certificates` uses at
> install/join) yields a cert with `DNS:hostname, IP:<node ip>`.

```bash
# Check-only/safe: runs against one host, no full-suite side effects
ansible-playbook -i inventory/hosts.yml kubelet-cert.yaml --limit thinkcentre01

# Future node (touch nothing but the cert logic)
ansible-playbook -i inventory/hosts.yml kubelet-cert.yaml --limit thinkcentre03
```

Playbook logic (abridged — see the playbook for full snap-env exports):

```yaml
- name: Check kubelet serving cert SAN for current node IP
  ansible.builtin.shell:
    executable: /bin/bash   # `set -o pipefail` is bash, not dash (/bin/sh)
    cmd: |
      set -o pipefail
      CERT={{ kubelet_cert_dir }}/kubelet.crt
      if [ ! -f "$CERT" ]; then echo missing; exit 0; fi
      if openssl x509 -in "$CERT" -noout -text 2>/dev/null \
        | grep -q "IP Address:{{ node_ip }}"; then echo valid; else echo stale; fi
  register: kubelet_cert_san
  changed_when: false

- name: Regenerate kubelet serving cert (stale or missing)
  ansible.builtin.shell:
    executable: /bin/bash
    cmd: |
      set -o pipefail
      export SNAP={{ snap_path }}
      export SNAP_DATA={{ snap_data }}
      # ...REAL_PATH, SNAPCRAFT_ARCH_TRIPLET, SNAP_LIBRARY_PATH, SNAP_COMMON...
      source {{ microk8s_utils }}
      HOST=$("$SNAP/bin/hostname" | "$SNAP/usr/bin/tr" '[:upper:]' '[:lower:]')
      generate_csr_with_sans "/CN=system:node:${HOST}/O=system:nodes" \
        {{ kubelet_cert_dir }}/kubelet.key \
        | sign_certificate > {{ kubelet_cert_dir }}/kubelet.crt
      chmod 0644 {{ kubelet_cert_dir }}/kubelet.crt
      chmod 0600 {{ kubelet_cert_dir }}/kubelet.key
      openssl x509 -in {{ kubelet_cert_dir }}/kubelet.crt -noout -text \
        | grep -q "IP Address:{{ node_ip }}"
  when: kubelet_cert_san.stdout != "valid"
  changed_when: true
  notify: Restart kubelet

handlers:
  - name: Restart kubelet
    ansible.builtin.systemd_service:
      name: snap.microk8s.daemon-kubelite   # NOT snap.microk8s.kubelet
      state: restarted
```

Behavior per host (from the SAN verification above): `.144` reported **stale**
(cert listed `192.168.1.49`), regenerated via the CA-signed CSR path and restarted
— now `DNS:thinkcentre01, IP Address:192.168.1.144`. `.175` and `.121` already
include their node IP → reported `valid`, nothing changes. `thinkcentre03` (not
yet joined) → `missing`, no-op.

---

## Option B — manual one-time fix (emergency, run by user with sudo)

Not the GitOps path; only for a quick unblock. **Never SSH as the `ansible` user.**

On thinkcentre01, as your `steve` account:

```bash
# 1. Drain the node so pods leave cleanly (kubelet will briefly restart)
kubectl drain thinkcentre01 --ignore-daemonsets --delete-emptydir-data

# 2. Stop microk8s, remove the stale kubelet cert set, start again
sudo microk8s stop
sudo rm -f /var/snap/microk8s/current/certs/kubelet.crt \
          /var/snap/microk8s/current/certs/kubelet.key \
          /var/snap/microk8s/current/certs/kubelet.csr
sudo microk8s start

# 3. Re-enable scheduling
kubectl uncordon thinkcentre01
```

Watch for the node to come back Ready:

```bash
kubectl get nodes -w
```

---

## Post-verification

```bash
# 1. SAN now contains the right IP (see Pre-check command above)
echo | openssl s_client -connect 192.168.1.144:10250 -verify_quiet 2>/dev/null \
  | openssl x509 -noout -text | grep -A2 "Subject Alternative Name"

# 2. logs/exec work end-to-end
kubectl logs -n ai-services deploy/hermes-agent --tail=5
kubectl exec -n ai-services deploy/hermes-agent -- ls /opt 2>/dev/null || true

# 3. Node healthy
kubectl get nodes

# 4. No stuck pods
kubectl get pods -A | grep -Ev "Running|Completed" || true
```

## Rollback

On the affected node: `sudo microk8s stop && sudo microk8s start`. The kubelet will
re-issue a serving cert — **but via kubelite's auto-self-sign, so expect it to come
back WITHOUT the node IP SAN** (see Gotchas below). To roll back to a proper cert,
re-run `node-config/kubelet-cert.yaml` for that host, which regenerates via the
CA-signed CSR path.

## Gotchas

- **`microk8s refresh-certs` does NOT cover the kubelet cert** — it only handles the
  CA / apiserver certs (ref: canonical/microk8s#5290). Do not rely on it here.
- **Known upstream bug** (microk8s #5290, #4561): on some versions / nodes added with
  older snap revisions, a deleted-and-auto-regenerated kubelet cert comes back
  **without any IP SANs** (`cannot validate certificate for 192.168.1.144 because it
  doesn't contain any IP SANs`, or earlier `certificate is valid for 127.0.0.1,
  10.152.183.1, 192.168.1.49, not 192.168.1.144`). Deleting the cert files is NOT
  sufficient — the playbook's `generate_csr_with_sans`/`sign_certificate` path is
  required. Confirmed on thinkcentre01: a plain delete+restart regenerated a cert
  with only `DNS:thinkcentre01`; the playbook's CSR path produced
  `DNS:thinkcentre01, IP Address:192.168.1.144`.
- **`snap.microk8s.kubelet` does not exist on microk8s ≥1.31** — kubelet runs inside
  the `snap.microk8s.daemon-kubelite` unit. Use `systemctl restart
  snap.microk8s.daemon-kubelite` (or `snapctl restart microk8s.daemon-kubelite`).
- **`utils.sh` functions need the snap env exported** when run outside the snap
  wrapper: `SNAP`, `SNAP_DATA`, `REAL_PATH`, `SNAPCRAFT_ARCH_TRIPLET`,
  `SNAP_LIBRARY_PATH`, `SNAP_COMMON`. The playbook exports these; bare `source
  /snap/microk8s/current/actions/common/utils.sh` in an ssh shell fails with
  `REAL_PATH: unbound variable` etc.
- `api server` port `16443` and the traefik LB `192.168.1.241` are **not** affected —
  this is kubelet speak (`10250`) only.
- The dqlite datastore membership is a separate concern, tracked in
  `dqlite-ghost-cleanup-plan.md`.