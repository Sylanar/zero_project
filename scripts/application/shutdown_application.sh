#!/usr/bin/env bash
# Stop Elasticsearch before the eviction handler unmounts the data volume.
# Serializes concurrent Spot evictions via an S3 lock so a second node waits
# until the first rejoins, or until the lock is eviction_lock_wait_seconds old.
set -euo pipefail

ENV_FILE="/opt/zero/node.env"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

MOUNT_POINT="${MOUNT_POINT:-/data}"
PID_FILE="${MOUNT_POINT}/elasticsearch/elasticsearch.pid"
ES_HOME="${MOUNT_POINT}/elasticsearch"
CA_CERT="${ES_HOME}/config/certs/ca.crt"
LOCK_WAIT_SECONDS="${EVICTION_LOCK_WAIT_SECONDS:-60}"
EXPECTED_NODES="${ES_EXPECTED_NODES:-}"
# Leave time for SIGTERM wait (30s) + umount + terminate inside the ~120s warning.
SHUTDOWN_BUDGET_SECONDS=40
SCRIPT_DIR="/opt/zero"

log_eviction() {
  if [[ -x "${SCRIPT_DIR}/log_eviction_event.sh" ]]; then
    "${SCRIPT_DIR}/log_eviction_event.sh" "$@" || true
  fi
}

if [[ -z "${INSTANCE_ID:-}" ]]; then
  TOKEN="$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
  if [[ -n "${TOKEN}" ]]; then
    INSTANCE_ID="$(curl -sfS -H "X-aws-ec2-metadata-token: ${TOKEN}" \
      "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null || true)"
  fi
fi
INSTANCE_ID="${INSTANCE_ID:-unknown}"
export INSTANCE_ID

lock_body() {
  printf '{"owner":"%s","instance_id":"%s","acquired_at":"%s"}\n' \
    "${ES_NODE_NAME}" "${INSTANCE_ID}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# Conditional PutObject is the acquire: If-None-Match * succeeds only if absent.
try_create_lock() {
  local tmp
  tmp="$(mktemp)"
  lock_body > "${tmp}"
  if aws s3api put-object \
    --region "${AWS_REGION}" \
    --bucket "${CACHE_BUCKET}" \
    --key "${EVICTION_LOCK_S3_KEY}" \
    --body "${tmp}" \
    --content-type application/json \
    --if-none-match "*" >/dev/null 2>&1; then
    rm -f "${tmp}"
    echo "shutdown_application: acquired eviction lock"
    log_eviction lock_acquired
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

# Steal only if the current ETag still matches (two waiters cannot both steal).
try_steal_lock() {
  local etag="$1"
  local tmp
  tmp="$(mktemp)"
  lock_body > "${tmp}"
  if aws s3api put-object \
    --region "${AWS_REGION}" \
    --bucket "${CACHE_BUCKET}" \
    --key "${EVICTION_LOCK_S3_KEY}" \
    --body "${tmp}" \
    --content-type application/json \
    --if-match "${etag}" >/dev/null 2>&1; then
    rm -f "${tmp}"
    echo "shutdown_application: stole eviction lock"
    log_eviction lock_stolen
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

# Prints "AGE_SECONDS\nETAG" or fails if the object is missing.
lock_age_and_etag() {
  aws s3api head-object \
    --region "${AWS_REGION}" \
    --bucket "${CACHE_BUCKET}" \
    --key "${EVICTION_LOCK_S3_KEY}" \
    --output json 2>/dev/null | python3 -c '
import json, sys
from datetime import datetime, timezone

doc = json.load(sys.stdin)
raw = doc["LastModified"]
if isinstance(raw, (int, float)):
    epoch = int(raw)
else:
    text = str(raw).replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        dt = datetime.strptime(str(raw), "%a, %d %b %Y %H:%M:%S %Z").replace(tzinfo=timezone.utc)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    epoch = int(dt.timestamp())
age = max(0, int(datetime.now(timezone.utc).timestamp()) - epoch)
print(age)
print(doc["ETag"])
'
}

spot_remaining_seconds() {
  local token raw
  token="$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
  if [[ -z "${token}" ]]; then
    echo "9999"
    return 0
  fi
  raw="$(curl -sfS -H "X-aws-ec2-metadata-token: ${token}" \
    "http://169.254.169.254/latest/meta-data/spot/instance-action" 2>/dev/null || true)"
  if [[ -z "${raw}" ]]; then
    echo "9999"
    return 0
  fi
  python3 -c '
import json, sys
from datetime import datetime, timezone
doc = json.loads(sys.argv[1])
deadline = datetime.fromisoformat(doc["time"].replace("Z", "+00:00"))
print(int((deadline - datetime.now(timezone.utc)).total_seconds()))
' "${raw}" 2>/dev/null || echo "9999"
}

es_node_count() {
  local pw="$1"
  if [[ -z "${pw}" || ! -f "${CA_CERT}" || -z "${ES_NODE_NAME:-}" ]]; then
    return 1
  fi
  curl -sfS --cacert "${CA_CERT}" \
    --resolve "${ES_NODE_NAME}:9200:127.0.0.1" \
    -u "elastic:${pw}" \
    "https://${ES_NODE_NAME}:9200/_cluster/health" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["number_of_nodes"])'
}

# Wait until we own the lock. Do not treat a still-full cluster as "first node
# is back" — that is the starting state. Only count recovery after a deficit.
wait_for_eviction_turn() {
  if [[ -z "${CACHE_BUCKET:-}" || -z "${EVICTION_LOCK_S3_KEY:-}" || -z "${AWS_REGION:-}" || -z "${ES_NODE_NAME:-}" ]]; then
    echo "shutdown_application: eviction lock env unset; shutting down without lock" >&2
    return 0
  fi

  local pw="" remaining age etag nodes age_etag
  local saw_deficit=0
  local started_at now
  local logged_lock_detected=0
  started_at="$(date -u +%s)"

  if [[ "${ES_SECRETS_BACKEND:-secretsmanager}" == "s3" && -n "${ES_BOOTSTRAP_S3_URI:-}" ]]; then
    pw="$(aws s3 cp "${ES_BOOTSTRAP_S3_URI}" - --region "${AWS_REGION}" 2>/dev/null || true)"
  elif [[ -n "${ES_BOOTSTRAP_SECRET_ARN:-}" ]]; then
    pw="$(aws secretsmanager get-secret-value \
      --region "${AWS_REGION}" \
      --secret-id "${ES_BOOTSTRAP_SECRET_ARN}" \
      --query SecretString \
      --output text 2>/dev/null || true)"
  fi

  while true; do
    if try_create_lock; then
      return 0
    fi

    remaining="$(spot_remaining_seconds)"
    if [[ "${remaining}" -le "${SHUTDOWN_BUDGET_SECONDS}" ]]; then
      echo "shutdown_application: spot deadline ${remaining}s left; shutting down"
      age_etag="$(lock_age_and_etag || true)"
      etag="$(printf '%s\n' "${age_etag}" | sed -n '2p')"
      if [[ -n "${etag}" ]]; then
        try_steal_lock "${etag}" || true
      fi
      return 0
    fi

    age_etag="$(lock_age_and_etag || true)"
    age="$(printf '%s\n' "${age_etag}" | sed -n '1p')"
    etag="$(printf '%s\n' "${age_etag}" | sed -n '2p')"
    age="${age:-0}"
    now="$(date -u +%s)"

    if [[ -n "${etag}" && "${logged_lock_detected}" -eq 0 ]]; then
      log_eviction lock_detected lock_age="${age}"
      logged_lock_detected=1
    fi

    # Create failed and there is no object: S3/IAM is broken. Do not wait forever.
    if [[ -z "${etag}" && $((now - started_at)) -ge "${LOCK_WAIT_SECONDS}" ]]; then
      echo "shutdown_application: no lock after ${LOCK_WAIT_SECONDS}s; shutting down without it" >&2
      return 0
    fi

    if [[ -n "${etag}" && "${age}" -ge "${LOCK_WAIT_SECONDS}" ]]; then
      echo "shutdown_application: lock age ${age}s >= ${LOCK_WAIT_SECONDS}s"
      if try_steal_lock "${etag}"; then
        return 0
      fi
    fi

    if [[ -n "${EXPECTED_NODES}" && -n "${pw}" ]]; then
      nodes="$(es_node_count "${pw}" || echo "")"
      if [[ -n "${nodes}" && "${nodes}" -lt "${EXPECTED_NODES}" ]]; then
        saw_deficit=1
      fi
      if [[ "${saw_deficit}" -eq 1 && -n "${nodes}" && "${nodes}" -ge "${EXPECTED_NODES}" ]]; then
        echo "shutdown_application: cluster restored to ${nodes} nodes"
        if try_create_lock; then
          return 0
        fi
      fi
    fi

    echo "shutdown_application: waiting for eviction turn (lock_age=${age}s remaining=${remaining}s)"
    sleep 5
  done
}

wait_for_eviction_turn

log_eviction shutdown_started

if [[ ! -f "${PID_FILE}" ]]; then
  echo "shutdown_application: no pid file; nothing to stop"
  exit 0
fi

PID="$(cat "${PID_FILE}")"
if ! kill -0 "${PID}" 2>/dev/null; then
  rm -f "${PID_FILE}"
  echo "shutdown_application: stale pid file removed"
  exit 0
fi

kill -TERM "${PID}"
for _ in $(seq 1 30); do
  if ! kill -0 "${PID}" 2>/dev/null; then
    rm -f "${PID_FILE}"
    echo "shutdown_application: elasticsearch stopped"
    exit 0
  fi
  sleep 1
done

echo "shutdown_application: elasticsearch did not stop in time" >&2
exit 1
