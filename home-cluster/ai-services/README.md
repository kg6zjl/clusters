# Beast — GPU AI Box (llama.cpp + ComfyUI)

Bare-metal AI worker at **192.168.1.161** (`enp39s0`, hostname `beast`, Ubuntu, root
user `steve`). Runs llama.cpp (OpenAI-compatible router, port **11434**) and ComfyUI
(port **8080**) directly on a single **RTX 5070 Ti 16GB**, both managed by systemd.
Consumed by the cluster's `open-webui` and `comfy-local` services in `ai-services/`.

## Why bare-metal

The GPU box is intentionally *not* a pod. systemd units give stable, restart-safe
host control and let a 16GB card be shared between llama + ComfyUI with a VRAM
coordinator (see below), which in-cluster deployments cannot do as cleanly.

## Services (systemd, per-host)

| Unit | Purpose | Port |
|------|---------|------|
| `llama-server.service` | llama.cpp router: Qwen3 text + multimodal models | 11434 |
| `comfyui.service` | ComfyUI workflow backend | 8080 |
| `systemd-api.service` | Flask control API (start/stop/status/restart over sudo) | 5000 |
| `status-server.service` | Liveness endpoint for HA / monitoring | 8126 |
| `comfy-llama-sync.service` | Stops llama while ComfyUI render queue is busy | — |
| `comfy-unload.service` | Frees ComfyUI models when llama is up | — |

HTTP endpoints (`5000`, `8126`, `11434`) are reachable on `192.168.1.161` (LAN only,
no internet exposure).

## Models

gguf files live in `/home/steve/Models/Qwen3.8/` with presets defined in `models.ini`
(multimodal 27B quants attach `mmproj-Qwen3.8-27B-ABLITERATED-Q8_0`):

- `Qwen3-14B-abliterated-Q4_K_M` — text only (no mmproj exists for 14B)
- `Qwen3.8-27B-ABLITERATED-Q4_K_M` — multimodal (16.8 GB)
- `Qwen3.8-27B-ABLITERATED-Q3_K_M` — multimodal (13.5 GB, default pick for headroom)

llama runs in **router mode**:
`--models-dir /home/steve/Models/Qwen3.8 --models-preset .../models.ini -ngl 99 -c 8192 --sleep-idle-seconds 60`. Models load on demand. `/v1/models` lists all three.

## VRAM coordination

`comfy-llama-sync.service` polls `http://127.0.0.1:8080/queue` every 1s. While a
ComfyUI render is running/pending it **stops** `llama-server.service`; when drained it
starts it again. `comfy-unload.service` does the reverse: when llama is up and the
ComfyUI queue is idle it POSTs `/free` (`unload_models=true, free_memory=true`) so
ComfyUI releases VRAM back to llama. Renders always win.

Follow the same rule for manual changes: start ComfyUI on demand, don't keep it
resident with llama both loaded.

## Control & status API (systemd-api)

Flask app at `/opt/systemd-api/app.py` (runs as unprivileged `svcctl`, sudoers
whitelist in `/etc/sudoers.d/svcctl` — `systemctl start/stop/restart/status` only).

    GET/POST /systemd/<unit>/<command>   command ∈ start|stop|status|restart

Returns `200` always with `{ok, output, stderr, active}`; `active` is only meaningful
for `status` (`systemctl status` exits 0 when active, 3 when inactive).

Status aggregation for liveness (`/opt/comfy-llama-sync/status_server.py`):

    GET /    →  {"comfyui": "on"|"off", "llama": "on"|"off"}

via unprivileged `systemctl is-active` (port 8126).

## Home Assistant integration

`home-assistant/configmap.yaml` wires the box into HA (`hostNetwork` pod, so no
NetPol changes needed):

- `sensor.beast_comfyui_status` / `sensor.beast_llama_status` — REST sensors on :8126
- `switch.beast_comfyui` / `switch.beast_llama` — template switches calling start/stop
- `button.beast_comfyui_restart` / `button.beast_llama_restart` — restart buttons

Config changes to the HA configmap require an HA restart after Flux reconciles (the
init container copies `configuration.yaml` at pod start):
`kubectl rollout restart deployment/home-assistant -n home-assistant`.

## Changing host-side files

All `/etc`, `/opt`, unit, and `sudoers` edits are applied via a sudo script run on the
box (`ssh steve@192.168.1.161 "sudo bash /tmp/<script>.sh"`) — there is no passwordless
sudo. Host state is not under Flux; the cluster's Git repo only governs cluster
manifests and documents this box.

## Firewall allow-list (UFW)

beast runs **UFW** with an explicit source allow-list on the AI ports. When a cluster
node's IP changes, the allow-list MUST be updated or that node's pods (OpenWebUI,
hermes, etc.) lose access to beast — this is exactly what happened after thinkcentre01
was re-IP'd (`.49` → `.144`: models vanished from OpenWebUI until `.144` was allowed).

Current posture (fit to the cluster node IPs only — **not** the whole LAN):

| Cluster node      | InternalIP | Needs beast for                                    |
|-------------------|------------|----------------------------------------------------|
| pi4-microk8s      | 192.168.1.175 | (currently idle; keep allow-listed)             |
| thinkcentre01     | 192.168.1.144 | OpenWebUI + hermes (`:11434`), comfy ingress    |
| thinkcentre02     | 192.168.1.121 | Home Assistant sensors/switches (`:5000`,`:8126`) |
| thinkcentre03     | 192.168.1.146 | future voter, not yet joined                      |

Ports:
- `:11434` llama router and `:8080` ComfyUI — **node IPs only**.
- `:5000` systemd control API and `:8126` status — historically `Anywhere` (LAN).
  Harden to node IPs only (HA runs on `.121`, covered).

Pinned rules (`ssh steve@192.168.1.161`):

```bash
# AI ports — cluster node IPs only
for ip in 192.168.1.144 192.168.1.175 192.168.1.121 192.168.1.146; do
  sudo ufw allow from $ip to any port 8080,11434 proto tcp
  sudo ufw allow from $ip to any port 5000,8126 proto tcp
done

# When re-adding a node IP, remove the stale rule for its old IP first:
#   sudo ufw delete allow from 192.168.1.49 to any port 8080
#   sudo ufw delete allow from 192.168.1.49 to any port 11434

# Verify
sudo ufw status numbered
```

Upstream promise: keep `sudo ufw default deny incoming` so anything not explicitly
allow-listed is dropped; expose no AI port to `192.168.1.0/24`.

## Linking to the cluster

- The cluster's NetworkPolicy `ai-services-allow-egress`
  (`home-cluster/ai-services/network-policy.yaml`) already egresses to
  `192.168.1.161/32` on `:11434` + `:8080`, so pod→beast needs no NetPol change —
  the source allow-list on beast is the only gate.

## Health checks

    curl http://192.168.1.161:8126/                      # llama/comfy on|off
    curl http://192.168.1.161:5000/systemd/llama-server.service/status
    curl http://192.168.1.161:11434/v1/models            # loaded model list