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
chmod 0755 \
  "$${OPT_DIR}/init_application.sh" \
  "$${OPT_DIR}/startup_application.sh" \
  "$${OPT_DIR}/shutdown_application.sh" \
  "$${OPT_DIR}/handle_spot_eviction.sh"

cat > "$${OPT_DIR}/node.env" <<EOF
NODE_NAME=$${NODE_NAME}
MOUNT_POINT=$${MOUNT_POINT}
VOLUME_ID=$${VOLUME_ID}
ELASTICSEARCH_S3_URI=${elasticsearch_s3_uri}
CACHE_BUCKET=${cache_bucket}
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

# First-time bootstrap only: marker lives on the durable volume so Spot
# replacements skip init and only run startup.
INIT_MARKER="$${MOUNT_POINT}/.initialized"
if [[ ! -f "$${INIT_MARKER}" ]]; then
  "$${OPT_DIR}/init_application.sh"
  touch "$${INIT_MARKER}"
  echo "init_application.sh completed; wrote $${INIT_MARKER}"
else
  echo "Skipping init_application.sh (found $${INIT_MARKER})"
fi

"$${OPT_DIR}/startup_application.sh"
echo "startup_application.sh completed"
