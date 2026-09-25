#!/usr/bin/env bash
set -euo pipefail

# Beast Prometheus exporter bootstrap — node_exporter (:9100) + nvidia_gpu_exporter (:9835)
# Run as:  ssh steve@192.168.1.161 "sudo bash /tmp/beast-exporters.sh"
# See ai-services/README.md "Monitoring the GPU box" for details.

NODE_EXPORTER_VERSION="1.8.2"
GPU_EXPORTER_VERSION="1.15.1"
NODE_IPS="192.168.1.144 192.168.1.175 192.168.1.121 192.168.1.146"
ARCH="linux-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"

echo "==> Installing node_exporter ${NODE_EXPORTER_VERSION}"
if ! command -v /usr/local/bin/node_exporter >/dev/null 2>&1; then
  curl -fsSLo /tmp/node_exporter.tar.gz \
    "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}.tar.gz"
  tar -xzf /tmp/node_exporter.tar.gz -C /tmp
  install -m 0755 "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}/node_exporter" /usr/local/bin/node_exporter
  rm -rf /tmp/node_exporter* /tmp/node_exporter.tar.gz
fi

cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=nobody
Group=nogroup
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "==> Installing nvidia_gpu_exporter ${GPU_EXPORTER_VERSION} (NVML)"
if ! command -v /usr/local/bin/nvidia_gpu_exporter >/dev/null 2>&1; then
  curl -fsSLo /tmp/gpu_exporter.tar.gz \
    "https://github.com/utkuozdemir/nvidia_gpu_exporter/releases/download/v${GPU_EXPORTER_VERSION}/nvidia_gpu_exporter-nvml_${GPU_EXPORTER_VERSION}_${ARCH}.tar.gz"
  tar -xzf /tmp/gpu_exporter.tar.gz -C /tmp
  install -m 0755 /tmp/nvidia_gpu_exporter /usr/local/bin/nvidia_gpu_exporter
  rm -rf /tmp/gpu_exporter.tar.gz /tmp/nvidia_gpu_exporter
fi

cat > /etc/systemd/system/nvidia_gpu_exporter.service <<'EOF'
[Unit]
Description=NVIDIA GPU Exporter (NVML)
After=network.target

[Service]
User=nobody
Group=nogroup
Type=simple
ExecStart=/usr/local/bin/nvidia_gpu_exporter --web.listen-address=:9835 --collect.backend=nvml
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter.service nvidia_gpu_exporter.service

echo "==> UFW: allow cluster node IPs to exporter ports"
for ip in ${NODE_IPS}; do
  sudo ufw allow from "${ip}" to any port 9100,9835 proto tcp
done

echo "==> Status"
systemctl status node_exporter.service --no-pager | head -5
systemctl status nvidia_gpu_exporter.service --no-pager | head -5
curl -s http://127.0.0.1:9100/metrics | head -3
curl -s http://127.0.0.1:9835/metrics | head -3
echo "DONE"