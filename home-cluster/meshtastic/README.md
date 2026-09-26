# MeshMonitor - Meshtastic Radio Mesh Overview

Single instance of [MeshMonitor](https://meshmonitor.org) (`ghcr.io/yeraze/meshmonitor:4.16.0`)
running on the home cluster. It watches two physical Meshtastic radios over their TCP API
ports, persists their traffic, and ingests the Bay Area Mesh public MQTT broker
(`mqtt.bayme.sh`) for local viewing.

---

## Network Diagram

```
                        PUBLIC INTERNET (Bay Area Mesh)
                        ┌──────────────────────────────────────────┐
                        │  mqtt.bayme.sh:1883 (public broker)      │
                        │  creds: see 1Password home-cluster vault │
                        │  topics: msh/US/bayarea/#                │
                        └────────────────────┬─────────────────────┘
                                             │
                       MQTT-Listen           │  (subscribe_only)
                       (public downlink)     │
                        ┌────────────────────▼─────────────────────┐
                        │             MESH-MONITOR pod             │
                        │        (K8s, SQLite store + UI)          │
                        └───▲──────────────────────────▲───────────┘
                            │                          │
        TCP :4403           │                          │        TCP :4403
   (radio API link)         │                          │  (radio API link)
    ┌──────────────┐        │                          │    ┌──────────────┐
    │ SOLAR radio  │◄───────┘        WiFi RF           └───►│ BASE radio   │
    │ !6985b180    │          RF                              │ !69853fc8    │
    │ .43:4403     │◄═══════════════════════════════════════►│ .199:4403    │
    └──────────────┘        (mesh RF both ways)               └──────────────┘
            ▲                                                     ▲
            │ firmware MQTT                                       │ firmware MQTT
            └────────────┐                        ┌───────────────┘
                         ▼                        ▼
                 ┌──────────────────────────┐
                 │ LOCAL Mosquitto          │  mqtt.kube.stevearnett.com:1883
                 │ (MetalLB .240)           │  intra-net MQTT relay (radios ↔
                 └──────────────────────────┘  Node-RED, etc.). No bridge out.
```

---

## Physical Radios (the hardware)

Both are Heltec devices running firmware `2.7.26.54e0d8d`. MeshMonitor connects to them
outbound over their **TCP API port 4403** (it does NOT listen for incoming connections).

| Radio | Node ID | Position | IP | Notes |
|---|---|---|---|---|
| **HotPotato Solar** ☀️ | `!6985b180` | Solar powered, edge of the yard | `192.168.1.43:4403` | Stops transmitting RF when battery low; WiFi WAN link flaps. Daily reboot automation (14:00 UTC). |
| **HotPotato Base** 🥔 | `!69853fc8` | Office, wired | `192.168.1.199:4403` | Power-connected (battery 101%), stable. |

Both radios also have the **firmware MQTT module enabled** pointing at the local Mosquitto
(`mqtt.kube.stevearnett.com:1883`) for intra-net relay — Base has uplink, Solar has downlink.

---

## MeshMonitor Sources (virtual, stored in its SQLite DB)

A **source** is MeshMonitor's logical input/output channel. Traffic arrives tagged with a
source ID, which is why the UI shows "multiple sources" for the same radio.

| Source | Type | Purpose | Config |
|---|---|---|---|
| **Solar Node** | `meshtastic_tcp` | RF ingest from Solar radio | host `192.168.1.43:4403`, passive mode, virtual node on `:4405` |
| **Office Base** | `meshtastic_tcp` | RF ingest from Base radio | host `192.168.1.199:4403`, virtual node on `:4404` |
| **MQTT-Listen** | `mqtt_bridge` | Public **downlink** (works) | `subscribe_only`, `mqtt.bayme.sh:1883`, subscribes `msh/US/bayarea/#` |

**virtual node ports** (`4404`, `4405`): MeshMonitor re-serves each radio's live feed over a raw
Meshtastic TCP socket, so a phone app can connect to the cluster as if it were the physical
radio.

---

## How Traffic Flows

### 1. RF → MeshMonitor (ingest, WORKS)
Radio hears a packet on the mesh → forwards it over its TCP API link `:4403` → MeshMonitor
ingests it as a `meshtastic_tcp` source → stored in SQLite, shown in UI/messages.

### 2. Intra-net MQTT (WORKS)
Radios' firmware MQTT module publishes/receives on the **local Mosquitto**
(`mqtt.kube.stevearnett.com:1883`) for low-latency relay between the radios, Node-RED, and
other home services. This is **not** wired to the public internet.

### 3. Public downlink — bay area → here (WORKS)
`mqtt.bayme.sh` → **MQTT-Listen** (`subscribe_only`) subscribes to `msh/US/bayarea/#` and
ingests public mesh traffic into MeshMonitor. Supplies a minority of the nodes in the UI —
the majority arrive over RF via the two radios.

---

## Current Status

| Path | Status | Evidence |
|---|---|---|
| RF → MeshMonitor (Solar + Base TCP) | ✅ | messages/telemetry persist, `lastHeard` current |
| Public downlink (MQTT-Listen) | ✅ | ingest confirmed, latest messages recent |
| Intra-net MQTT (radios ↔ Mosquitto) | ✅ | radios connected as persistent MQTT clients |

---

## Operational Notes

- **One TCP client at a time.** Meshtastic firmware only allows a single TCP API
  connection per radio. If the Meshtastic phone app (or another client) is connected
  to a radio's `:4403` port, MeshMonitor will flap connect/disconnect and show the
  source as unstable. Disconnect the phone app and MeshMonitor will reconnect cleanly.

---

## Cluster Wiring (for reference)

- Namespace `meshtastic`; Deployment `meshmonitor` (env: `MQTT_ADDRESS=mosquitto.mqtt.svc.cluster.local`,
  `MQTT_TOPIC_PREFIX=msh/US/bayarea`)
- State in PVC `meshmonitor-data` → SQLite `/data/meshmonitor.db` (sources, messages, nodes).
- Backups: CronJob `meshmonitor-backup` (see `backup-cronjob.yaml`).
- Secrets: 1Password → ExternalSecret (`external-secrets.yaml`). **No credentials are
  stored in this file or any manifest** — the public Bay Area Mesh broker creds and all
  others come from the `home-cluster` 1Password vault via ESO.