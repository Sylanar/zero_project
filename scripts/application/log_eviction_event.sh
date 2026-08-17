#!/usr/bin/env bash
# Best-effort eviction audit event → S3. Always exits 0 so callers are unaffected.
# Usage: log_eviction_event.sh <event> [key=value ...]
set +e

ENV_FILE="/opt/zero/node.env"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

EVENT="${1:-}"
if [[ -z "${EVENT}" || -z "${CACHE_BUCKET:-}" || -z "${AWS_REGION:-}" ]]; then
  exit 0
fi
shift

PREFIX="${EVICTION_LOG_S3_PREFIX:-logs/eviction}"
NODE="${ES_NODE_NAME:-unknown}"
TOKEN="$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)"
if [[ -n "${TOKEN}" ]]; then
  if [[ -z "${INSTANCE_ID:-}" ]]; then
    INSTANCE_ID="$(curl -sfS -H "X-aws-ec2-metadata-token: ${TOKEN}" \
      "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null)"
  fi
  if [[ -z "${SPOT_ACTION:-}" ]]; then
    SPOT_ACTION="$(curl -sfS -H "X-aws-ec2-metadata-token: ${TOKEN}" \
      "http://169.254.169.254/latest/meta-data/spot/instance-action" 2>/dev/null)"
  fi
fi
INSTANCE_ID="${INSTANCE_ID:-unknown}"

AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SAFE_AT="$(date -u +%Y%m%dT%H%M%SZ)"
KEY="${PREFIX}/${NODE}/${SAFE_AT}-${INSTANCE_ID}-${EVENT}.json"

TMP="$(mktemp)"
EVENT="${EVENT}" AT="${AT}" INSTANCE_ID="${INSTANCE_ID}" \
ES_NODE_NAME="${NODE}" CLUSTER_NAME="${CLUSTER_NAME:-}" \
SPOT_ACTION="${SPOT_ACTION:-}" \
python3 - "${@}" > "${TMP}" <<'PY'
import json, os, sys

payload = {
    "event": os.environ["EVENT"],
    "at": os.environ["AT"],
    "es_node_name": os.environ.get("ES_NODE_NAME", ""),
    "instance_id": os.environ.get("INSTANCE_ID", ""),
    "cluster": os.environ.get("CLUSTER_NAME", ""),
}
spot = os.environ.get("SPOT_ACTION") or ""
if spot:
    try:
        payload["spot_instance_action"] = json.loads(spot)
    except json.JSONDecodeError:
        payload["spot_instance_action_raw"] = spot
for arg in sys.argv[1:]:
    key, _, value = arg.partition("=")
    if key:
        payload[key] = value
print(json.dumps(payload, separators=(",", ":")))
PY

aws s3api put-object \
  --region "${AWS_REGION}" \
  --bucket "${CACHE_BUCKET}" \
  --key "${KEY}" \
  --body "${TMP}" \
  --content-type application/json >/dev/null 2>&1
STATUS=$?
rm -f "${TMP}"
if [[ "${STATUS}" -eq 0 ]]; then
  echo "log_eviction_event: ${EVENT} s3://${CACHE_BUCKET}/${KEY}"
fi
exit 0
