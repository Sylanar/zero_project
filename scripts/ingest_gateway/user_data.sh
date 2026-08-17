#!/usr/bin/env bash
# Ingest gateway: TCP 9200 passthrough to a live Elasticsearch data node.
set -euo pipefail

OPT_DIR="/opt/zero"
mkdir -p "$${OPT_DIR}"

echo "${ingest_proxy_b64}" | base64 -d > "$${OPT_DIR}/ingest_proxy.py"
chmod 0755 "$${OPT_DIR}/ingest_proxy.py"

cat > "$${OPT_DIR}/ingest.env" <<EOF
CLUSTER_NAME=${cluster_name}
AWS_REGION=${aws_region}
PREFERRED_AZ=${preferred_az}
EOF

dnf install -y socat

cat > /etc/systemd/system/ingest-proxy.service <<'UNIT'
[Unit]
Description=Elasticsearch ingest TCP proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/opt/zero/ingest.env
ExecStart=/usr/bin/python3 /opt/zero/ingest_proxy.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now ingest-proxy.service
