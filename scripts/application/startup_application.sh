#!/usr/bin/env bash
# Start Elasticsearch as a daemon. Cluster/TLS/keystore setup lives in init.
set -euo pipefail

ENV_FILE="/opt/zero/node.env"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

MOUNT_POINT="${MOUNT_POINT:-/data}"
ES_HOME="${MOUNT_POINT}/elasticsearch"
PID_FILE="${ES_HOME}/elasticsearch.pid"
CA_CERT="${ES_HOME}/config/certs/ca.crt"
SCRIPT_DIR="/opt/zero"

log_eviction() {
  if [[ -x "${SCRIPT_DIR}/log_eviction_event.sh" ]]; then
    "${SCRIPT_DIR}/log_eviction_event.sh" "$@" || true
  fi
}

if [[ ! -x "${ES_HOME}/bin/elasticsearch" ]]; then
  echo "startup_application: ${ES_HOME}/bin/elasticsearch missing" >&2
  exit 1
fi

if [[ -f "${PID_FILE}" ]]; then
  OLD_PID="$(cat "${PID_FILE}")"
  if kill -0 "${OLD_PID}" 2>/dev/null; then
    echo "startup_application: elasticsearch already running (pid ${OLD_PID})"
  else
    rm -f "${PID_FILE}"
    sudo -n -u ec2-user bash -c "cd \"${ES_HOME}\" && ./bin/elasticsearch -d -p \"${PID_FILE}\""
    echo "startup_application: elasticsearch started"
  fi
else
  sudo -n -u ec2-user bash -c "cd \"${ES_HOME}\" && ./bin/elasticsearch -d -p \"${PID_FILE}\""
  echo "startup_application: elasticsearch started"
fi

es_bootstrap_password() {
  if [[ -z "${AWS_REGION:-}" ]]; then
    return 1
  fi
  if [[ "${ES_SECRETS_BACKEND:-secretsmanager}" == "s3" ]]; then
    if [[ -z "${ES_BOOTSTRAP_S3_URI:-}" ]]; then
      return 1
    fi
    aws s3 cp "${ES_BOOTSTRAP_S3_URI}" - --region "${AWS_REGION}"
    return
  fi
  if [[ -z "${ES_BOOTSTRAP_SECRET_ARN:-}" ]]; then
    return 1
  fi
  aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "${ES_BOOTSTRAP_SECRET_ARN}" \
    --query SecretString \
    --output text
}

# Do not drop the lock until this node is visible to the cluster. Releasing at
# process start would let a waiting peer leave before shards are available.
wait_until_joined() {
  local pw="$1"
  local i names
  if [[ -z "${pw}" || ! -f "${CA_CERT}" || -z "${ES_NODE_NAME:-}" ]]; then
    return 1
  fi
  for i in $(seq 1 24); do
    names="$(curl -sfS --cacert "${CA_CERT}" \
      --resolve "${ES_NODE_NAME}:9200:127.0.0.1" \
      -u "elastic:${pw}" \
      "https://${ES_NODE_NAME}:9200/_cat/nodes?h=name" 2>/dev/null || true)"
    if printf '%s\n' "${names}" | grep -qxF "${ES_NODE_NAME}"; then
      echo "startup_application: joined cluster as ${ES_NODE_NAME}"
      log_eviction joined
      return 0
    fi
    sleep 5
  done
  echo "startup_application: timed out waiting to join cluster" >&2
  log_eviction join_timeout
  return 1
}

# Drop the mutex only if this stable node name still owns it. A steal means a
# later eviction is in progress; deleting that lock would let a third node leave.
release_eviction_lock_if_owner() {
  if [[ -z "${CACHE_BUCKET:-}" || -z "${EVICTION_LOCK_S3_KEY:-}" || -z "${AWS_REGION:-}" || -z "${ES_NODE_NAME:-}" ]]; then
    return 0
  fi

  local tmp meta owner etag
  tmp="$(mktemp)"
  if ! meta="$(aws s3api get-object \
    --region "${AWS_REGION}" \
    --bucket "${CACHE_BUCKET}" \
    --key "${EVICTION_LOCK_S3_KEY}" \
    "${tmp}" 2>/dev/null)"; then
    rm -f "${tmp}"
    echo "startup_application: no eviction lock to release"
    return 0
  fi

  owner="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("owner",""))' < "${tmp}" 2>/dev/null || true)"
  etag="$(printf '%s\n' "${meta}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ETag"])' 2>/dev/null || true)"
  rm -f "${tmp}"

  if [[ "${owner}" != "${ES_NODE_NAME}" ]]; then
    echo "startup_application: eviction lock owned by ${owner:-unknown}; leaving in place"
    log_eviction lock_left_in_place owner="${owner:-unknown}"
    return 0
  fi
  if [[ -z "${etag}" ]]; then
    echo "startup_application: eviction lock etag missing; leaving in place" >&2
    log_eviction lock_left_in_place owner="${owner:-unknown}" reason=missing_etag
    return 0
  fi

  if aws s3api delete-object \
    --region "${AWS_REGION}" \
    --bucket "${CACHE_BUCKET}" \
    --key "${EVICTION_LOCK_S3_KEY}" \
    --if-match "${etag}" >/dev/null 2>&1; then
    echo "startup_application: released eviction lock"
    log_eviction lock_deleted
  else
    echo "startup_application: eviction lock changed before delete; leaving in place"
    log_eviction lock_left_in_place owner="${owner:-unknown}" reason=etag_changed
  fi
}

PW="$(es_bootstrap_password 2>/dev/null || true)"
if wait_until_joined "${PW}"; then
  release_eviction_lock_if_owner || true
else
  echo "startup_application: not releasing eviction lock (node has not joined)"
fi
