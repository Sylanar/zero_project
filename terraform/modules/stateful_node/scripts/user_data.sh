#!/usr/bin/env bash
set -euo pipefail

# Attach the durable data volume for this node by volume ID, mount it, then start the app.
# Volume identity is Terraform-managed; instance identity is ephemeral (ASG-of-1).

NODE_NAME="${node_name}"
DEVICE_NAME="${device_name}"
MOUNT_POINT="${mount_point}"
VOLUME_ID="${volume_id}"

OPT_DIR="/opt/zero"
mkdir -p "$${OPT_DIR}"

# Install lifecycle scripts shipped base64-encoded from Terraform (avoids template escaping issues).
echo "${init_application_b64}" | base64 -d > "$${OPT_DIR}/init_application.sh"
echo "${startup_application_b64}" | base64 -d > "$${OPT_DIR}/startup_application.sh"
echo "${shutdown_application_b64}" | base64 -d > "$${OPT_DIR}/shutdown_application.sh"
echo "${handle_spot_eviction_b64}" | base64 -d > "$${OPT_DIR}/handle_spot_eviction.sh"
echo "${log_eviction_event_b64}" | base64 -d > "$${OPT_DIR}/log_eviction_event.sh"
chmod 0755 \
  "$${OPT_DIR}/init_application.sh" \
  "$${OPT_DIR}/startup_application.sh" \
  "$${OPT_DIR}/shutdown_application.sh" \
  "$${OPT_DIR}/handle_spot_eviction.sh" \
  "$${OPT_DIR}/log_eviction_event.sh"

if [[ "${enable_imds_eviction}" == "true" ]]; then
  echo "${watch_spot_eviction_b64}" | base64 -d > "$${OPT_DIR}/watch_spot_eviction.sh"
  chmod 0755 "$${OPT_DIR}/watch_spot_eviction.sh"
  cat > /etc/systemd/system/zero-spot-eviction-watch.service <<'UNIT'
[Unit]
Description=Poll IMDS for Spot interruption and run graceful eviction
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/zero/watch_spot_eviction.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now zero-spot-eviction-watch.service
fi

cat > "$${OPT_DIR}/node.env" <<EOF
NODE_NAME=$${NODE_NAME}
MOUNT_POINT=$${MOUNT_POINT}
VOLUME_ID=$${VOLUME_ID}
ELASTICSEARCH_S3_URI=${elasticsearch_s3_uri}
DISCOVERY_EC2_S3_URI=${discovery_ec2_s3_uri}
CACHE_BUCKET=${cache_bucket}
CLUSTER_NAME=${cluster_name}
AWS_REGION=${aws_region}
ES_INITIAL_MASTER_NODES=${es_initial_master_nodes}
ES_DISCOVERY_AZS=${es_discovery_azs}
ES_SECRETS_BACKEND=${es_secrets_backend}
ES_BOOTSTRAP_SECRET_ARN=${es_bootstrap_secret_arn}
ES_TLS_SECRET_ARN=${es_tls_secret_arn}
ES_BOOTSTRAP_S3_URI=${es_bootstrap_s3_uri}
ES_TLS_S3_URI=${es_tls_s3_uri}
ES_NODE_NAME=${es_node_name}
ES_NODE_ROLES=${es_node_roles}
ES_EXPECTED_NODES=${es_expected_nodes}
EVICTION_LOCK_S3_KEY=${eviction_lock_s3_key}
EVICTION_LOCK_WAIT_SECONDS=${eviction_lock_wait_seconds}
EVICTION_LOG_S3_PREFIX=${eviction_log_s3_prefix}
EOF

TOKEN="$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")"
imds() {
  curl -sS -H "X-aws-ec2-metadata-token: $${TOKEN}" "http://169.254.169.254$${1}"
}

INSTANCE_ID="$(imds /latest/meta-data/instance-id)"
AZ="$(imds /latest/meta-data/placement/availability-zone)"
REGION="$(imds /latest/meta-data/placement/region)"

echo "Attaching volume $${VOLUME_ID} (node=$${NODE_NAME}) to $${INSTANCE_ID} in $${AZ}"

# Wait until the volume is available (previous instance may still be detaching).
for _ in $(seq 1 60); do
  STATE="$(aws ec2 describe-volumes \
    --region "$${REGION}" \
    --volume-ids "$${VOLUME_ID}" \
    --query 'Volumes[0].State' \
    --output text)"
  if [[ "$${STATE}" == "available" ]]; then
    break
  fi
  if [[ "$${STATE}" == "in-use" ]]; then
    ATTACHED_TO="$(aws ec2 describe-volumes \
      --region "$${REGION}" \
      --volume-ids "$${VOLUME_ID}" \
      --query 'Volumes[0].Attachments[0].InstanceId' \
      --output text)"
    if [[ "$${ATTACHED_TO}" == "$${INSTANCE_ID}" ]]; then
      break
    fi
  fi
  sleep 5
done

STATE="$(aws ec2 describe-volumes \
  --region "$${REGION}" \
  --volume-ids "$${VOLUME_ID}" \
  --query 'Volumes[0].State' \
  --output text)"

if [[ "$${STATE}" == "available" ]]; then
  aws ec2 attach-volume \
    --region "$${REGION}" \
    --volume-id "$${VOLUME_ID}" \
    --instance-id "$${INSTANCE_ID}" \
    --device "$${DEVICE_NAME}"
fi

# Nitro maps EBS to nvme; resolve by volume id (strip vol- prefix).
VOL_SHORT="$${VOLUME_ID#vol-}"
BY_ID=""
for _ in $(seq 1 60); do
  if [[ -e "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol$${VOL_SHORT}" ]]; then
    BY_ID="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol$${VOL_SHORT}"
    break
  fi
  if [[ -e "$${DEVICE_NAME}" ]]; then
    BY_ID="$${DEVICE_NAME}"
    break
  fi
  sleep 2
done

if [[ -z "$${BY_ID}" ]]; then
  echo "Timed out waiting for device for $${VOLUME_ID}" >&2
  exit 1
fi

# Format only on first use (empty volume has no filesystem).
if ! blkid "$${BY_ID}" >/dev/null 2>&1; then
  mkfs.xfs "$${BY_ID}"
fi

mkdir -p "$${MOUNT_POINT}"
if ! mountpoint -q "$${MOUNT_POINT}"; then
  mount "$${BY_ID}" "$${MOUNT_POINT}"
fi

UUID="$(blkid -s UUID -o value "$${BY_ID}")"
if ! grep -q "UUID=$${UUID}" /etc/fstab; then
  echo "UUID=$${UUID} $${MOUNT_POINT} xfs defaults,nofail 0 2" >> /etc/fstab
fi

echo "Mounted $${VOLUME_ID} at $${MOUNT_POINT}"

# First-time bootstrap: marker lives on the durable volume so Spot
# replacements skip init. Re-run if TLS files or discovery-ec2 are missing,
# or if the distro yml still has duplicate keys from the old append-based init.
INIT_MARKER="$${MOUNT_POINT}/.initialized"
ES_CA="$${MOUNT_POINT}/elasticsearch/config/certs/ca.crt"
ES_YML="$${MOUNT_POINT}/elasticsearch/config/elasticsearch.yml"
ES_EC2_PLUGIN="$${MOUNT_POINT}/elasticsearch/plugins/discovery-ec2"
NODE_NAME_COUNT=0
if [[ -f "$${ES_YML}" ]]; then
  NODE_NAME_COUNT="$(grep -cE '^[[:space:]]*node\.name:' "$${ES_YML}" || true)"
fi
if [[ ! -f "$${INIT_MARKER}" || ! -f "$${ES_CA}" || ! -d "$${ES_EC2_PLUGIN}" || "$${NODE_NAME_COUNT}" -gt 1 ]]; then
  "$${OPT_DIR}/init_application.sh"
  touch "$${INIT_MARKER}"
  echo "init_application.sh completed; wrote $${INIT_MARKER}"
else
  echo "Skipping init_application.sh (found $${INIT_MARKER}, $${ES_CA}, and discovery-ec2)"
fi

"$${OPT_DIR}/startup_application.sh"
echo "startup_application.sh completed"
