[![Build and Deploy](https://github.com/kg6zjl/clusters/actions/workflows/meshtastic-bot.yaml/badge.svg)](https://github.com/kg6zjl/clusters/actions/workflows/meshtastic-bot.yaml)
---
# Meshtastic Bot

A Python bot that responds to Meshtastic messages via MQTT.

## Commands

- `/online` - Count of nodes visible in last 24 hours
- `/trace` - Get hop count to your node
- `/channels` - List of channels and their codes
- `/help` - Show help

## Build and Push

```bash
# Build the image
podman build -t meshtastic-bot:latest .

# Tag for local registry
podman tag meshtastic-bot:latest registry.kube.stevearnett.com/meshtastic-bot:latest

# Push to registry
podman push registry.kube.stevearnett.com/meshtastic-bot:latest
```

## Configuration

Environment variables:
- `MQTT_ADDRESS` - MQTT broker address (default: mosquitto.mqtt.svc.cluster.local)
- `MQTT_PORT` - MQTT broker port (default: 1883)
- `MQTT_USERNAME` - MQTT username
- `MQTT_PASSWORD` - MQTT password
- `MQTT_TOPIC_PREFIX` - MQTT topic prefix (default: msh/US/bayarea)
- `MESHMONITOR_URL` - MeshMonitor API URL (default: http://meshmonitor.meshtastic.svc.cluster.local:3001)
- `BOT_NODE_NUM` - Bot's node number
- `BOT_NODE_ID` - Bot's node ID (hex)
