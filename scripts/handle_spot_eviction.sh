#!/usr/bin/env bash
set -euo pipefail

# Graceful Spot eviction: stop app → unmount data volume → terminate instance.
# Invoked by SSM Run Command from the EventBridge interruption rule.

ENV_FILE="/opt/zero/node.env"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

MOUNT_POINT="${MOUNT_POINT:-/data}"
SCRIPT_DIR="/opt/zero"

echo "Starting Spot eviction handler (mount=${MOUNT_POINT})"

if [[ -x "${SCRIPT_DIR}/shutdown_application.sh" ]]; then
  "${SCRIPT_DIR}/shutdown_application.sh" || true
else
  echo "shutdown_application.sh missing; continuing" >&2
fi

sync

if mountpoint -q "${MOUNT_POINT}"; then
  umount "${MOUNT_POINT}"
  echo "Unmounted ${MOUNT_POINT}"
else
  echo "${MOUNT_POINT} not mounted; skipping umount"
fi

TOKEN="$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")"
imds() {
  curl -sS -H "X-aws-ec2-metadata-token: ${TOKEN}" "http://169.254.169.254${1}"
}

INSTANCE_ID="$(imds /latest/meta-data/instance-id)"
REGION="$(imds /latest/meta-data/placement/region)"

echo "Terminating ${INSTANCE_ID} in ${REGION}"
aws ec2 terminate-instances --region "${REGION}" --instance-ids "${INSTANCE_ID}"
