#!/usr/bin/env bash
# One-time node bootstrap — runs only when the durable data volume has no
# .initialized marker (first mount of an empty/new volume).
# Spot replacements remount the same volume and skip this script.
set -euo pipefail

ENV_FILE="/opt/zero/node.env"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

MOUNT_POINT="${MOUNT_POINT:-/data}"
ELASTICSEARCH_S3_URI="${ELASTICSEARCH_S3_URI:-}"
NODE_NAME="${NODE_NAME:-}"

if [[ -z "${ELASTICSEARCH_S3_URI}" ]]; then
  echo "init_application: ELASTICSEARCH_S3_URI is unset" >&2
  exit 1
fi

if [[ -z "${NODE_NAME}" ]]; then
  echo "init_application: NODE_NAME is unset" >&2
  exit 1
fi

# NODE_NAME is "${cluster_name}-node-XX"; Elasticsearch wants node-XX.
ES_NODE_NAME="node-${NODE_NAME##*-}"
ES_HOME="${MOUNT_POINT}/elasticsearch"
ES_YML="${ES_HOME}/config/elasticsearch.yml"

echo "init_application: first-time setup on ${MOUNT_POINT}"
echo "init_application: elasticsearch artifact ${ELASTICSEARCH_S3_URI}"
echo "init_application: elasticsearch node.name ${ES_NODE_NAME}"

mkdir -p "${ES_HOME}"
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

aws s3 cp "${ELASTICSEARCH_S3_URI}" "${TMP}"
tar -xzf "${TMP}" -C "${ES_HOME}" --strip-components=1

sed -i \
  -e "s/^[[:space:]]*#*[[:space:]]*node\.name:.*/node.name: ${ES_NODE_NAME}/" \
  -e 's/^[[:space:]]*#*[[:space:]]*network\.host:.*/network.host: 0.0.0.0/' \
  "${ES_YML}"

grep -qE '^[[:space:]]*transport\.host:' "${ES_YML}" \
  || echo 'transport.host: 0.0.0.0' >> "${ES_YML}"

grep -qE '^[[:space:]]*node\.store\.allow_mmap:' "${ES_YML}" \
  || echo 'node.store.allow_mmap: false' >> "${ES_YML}"

chown -R ec2-user:ec2-user "${ES_HOME}"

echo "init_application: elasticsearch ready at ${ES_HOME}"
