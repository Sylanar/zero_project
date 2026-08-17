#!/usr/bin/env bash
# One-time node bootstrap — unpack ES, write cluster/TLS/keystore config.
# Spot replacements remount the same volume; user_data skips this when
# certs already exist. Safe to re-run (managed yml block is replaced).
set -euo pipefail

ENV_FILE="/opt/zero/node.env"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

MOUNT_POINT="${MOUNT_POINT:-/data}"
ELASTICSEARCH_S3_URI="${ELASTICSEARCH_S3_URI:-}"
DISCOVERY_EC2_S3_URI="${DISCOVERY_EC2_S3_URI:-}"
NODE_NAME="${NODE_NAME:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-}"
ES_INITIAL_MASTER_NODES="${ES_INITIAL_MASTER_NODES:-}"
ES_DISCOVERY_AZS="${ES_DISCOVERY_AZS:-}"
ES_SECRETS_BACKEND="${ES_SECRETS_BACKEND:-secretsmanager}"
ES_BOOTSTRAP_SECRET_ARN="${ES_BOOTSTRAP_SECRET_ARN:-}"
ES_TLS_SECRET_ARN="${ES_TLS_SECRET_ARN:-}"
ES_BOOTSTRAP_S3_URI="${ES_BOOTSTRAP_S3_URI:-}"
ES_TLS_S3_URI="${ES_TLS_S3_URI:-}"
ES_NODE_NAME="${ES_NODE_NAME:-}"
ES_NODE_ROLES="${ES_NODE_ROLES:-}"

require() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    echo "init_application: ${name} is unset" >&2
    exit 1
  fi
}

require ELASTICSEARCH_S3_URI "${ELASTICSEARCH_S3_URI}"
require DISCOVERY_EC2_S3_URI "${DISCOVERY_EC2_S3_URI}"
require NODE_NAME "${NODE_NAME}"
require CLUSTER_NAME "${CLUSTER_NAME}"
require AWS_REGION "${AWS_REGION}"
require ES_INITIAL_MASTER_NODES "${ES_INITIAL_MASTER_NODES}"
require ES_DISCOVERY_AZS "${ES_DISCOVERY_AZS}"
require ES_NODE_NAME "${ES_NODE_NAME}"

if [[ "${ES_SECRETS_BACKEND}" == "s3" ]]; then
  require ES_BOOTSTRAP_S3_URI "${ES_BOOTSTRAP_S3_URI}"
  require ES_TLS_S3_URI "${ES_TLS_S3_URI}"
else
  require ES_BOOTSTRAP_SECRET_ARN "${ES_BOOTSTRAP_SECRET_ARN}"
  require ES_TLS_SECRET_ARN "${ES_TLS_SECRET_ARN}"
fi

retry() {
  local attempt=1
  local max=12
  until "$@"; do
    if [[ "${attempt}" -ge "${max}" ]]; then
      echo "init_application: failed after ${max} attempts: $*" >&2
      return 1
    fi
    echo "init_application: retry ${attempt}/${max}"
    attempt=$((attempt + 1))
    sleep 5
  done
}

# ES_NODE_NAME is the Terraform for_each key (node-00 or master-00).
ES_HOME="${MOUNT_POINT}/elasticsearch"
ES_YML="${ES_HOME}/config/elasticsearch.yml"
CERTS_DIR="${ES_HOME}/config/certs"

yaml_quoted_list() {
  local csv="$1"
  local out="["
  local first=1
  local item
  IFS=',' read -ra items <<< "${csv}"
  for item in "${items[@]}"; do
    if [[ "${first}" -eq 1 ]]; then
      first=0
    else
      out+=", "
    fi
    out+="\"${item}\""
  done
  out+="]"
  printf '%s' "${out}"
}

echo "init_application: first-time setup on ${MOUNT_POINT}"
echo "init_application: elasticsearch artifact ${ELASTICSEARCH_S3_URI}"
echo "init_application: elasticsearch node.name ${ES_NODE_NAME}"

mkdir -p "${ES_HOME}"
if [[ ! -x "${ES_HOME}/bin/elasticsearch" ]]; then
  TMP="$(mktemp)"
  aws s3 cp "${ELASTICSEARCH_S3_URI}" "${TMP}" --region "${AWS_REGION}"
  tar -xzf "${TMP}" -C "${ES_HOME}" --strip-components=1
  rm -f "${TMP}"
fi

if [[ ! -d "${ES_HOME}/plugins/discovery-ec2" ]]; then
  PLUGIN_ZIP="$(mktemp --suffix=.zip)"
  aws s3 cp "${DISCOVERY_EC2_S3_URI}" "${PLUGIN_ZIP}" --region "${AWS_REGION}"
  (
    cd "${ES_HOME}"
    ./bin/elasticsearch-plugin install --batch "file://${PLUGIN_ZIP}"
  )
  rm -f "${PLUGIN_ZIP}"
  echo "init_application: installed discovery-ec2"
fi

export ES_NODE_NAME AWS_REGION ES_SECRETS_BACKEND ES_TLS_SECRET_ARN ES_TLS_S3_URI CERTS_DIR
fetch_tls() {
  python3 - <<'PY'
import json, os, pathlib, subprocess, sys

region = os.environ["AWS_REGION"]
node = os.environ["ES_NODE_NAME"]
certs = pathlib.Path(os.environ["CERTS_DIR"])
backend = os.environ.get("ES_SECRETS_BACKEND", "secretsmanager")

if backend == "s3":
    uri = os.environ["ES_TLS_S3_URI"]
    raw = subprocess.check_output(
        ["aws", "s3", "cp", uri, "-", "--region", region],
        text=True,
    )
    payload = json.loads(raw)
else:
    secret_arn = os.environ["ES_TLS_SECRET_ARN"]
    raw = subprocess.check_output(
        [
            "aws", "secretsmanager", "get-secret-value",
            "--region", region,
            "--secret-id", secret_arn,
            "--output", "json",
        ],
        text=True,
    )
    payload = json.loads(json.loads(raw)["SecretString"])

if node not in payload["nodes"]:
    print(f"init_application: no TLS material for {node}", file=sys.stderr)
    sys.exit(1)

certs.mkdir(parents=True, exist_ok=True)
(certs / "ca.crt").write_text(payload["ca_cert"])
(certs / "node.crt").write_text(payload["nodes"][node]["cert"])
(certs / "node.key").write_text(payload["nodes"][node]["key"])
(certs / "node.key").chmod(0o600)
print(f"init_application: wrote TLS files for {node}")
PY
}
retry fetch_tls

MASTER_LIST="$(yaml_quoted_list "${ES_INITIAL_MASTER_NODES}")"
AZ_LIST="$(yaml_quoted_list "${ES_DISCOVERY_AZS}")"
ROLES_LINE=""
if [[ -n "${ES_NODE_ROLES}" ]]; then
  ROLES_LINE="node.roles: $(yaml_quoted_list "${ES_NODE_ROLES}")"
fi

# Replace the distro yml entirely. The first-boot sed left uncommented
# node.name/network.host; appending a second copy makes ES 8+ refuse to start.
cat > "${ES_YML}" <<EOF
cluster.name: ${CLUSTER_NAME}
node.name: ${ES_NODE_NAME}
${ROLES_LINE}
network.host: 0.0.0.0
transport.host: 0.0.0.0
network.publish_host: _ec2:privateIpv4_
node.store.allow_mmap: false

discovery.seed_providers: ec2
discovery.ec2.tag.Cluster: ${CLUSTER_NAME}
discovery.ec2.host_type: private_ip
discovery.ec2.endpoint: https://ec2.${AWS_REGION}.amazonaws.com
discovery.ec2.availability_zones: ${AZ_LIST}

cluster.initial_master_nodes: ${MASTER_LIST}

xpack.security.enabled: true
xpack.security.autoconfiguration.enabled: false
xpack.security.enrollment.enabled: false

xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: certificate
xpack.security.transport.ssl.client_authentication: required
xpack.security.transport.ssl.certificate_authorities: ["certs/ca.crt"]
xpack.security.transport.ssl.certificate: certs/node.crt
xpack.security.transport.ssl.key: certs/node.key

xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.certificate: certs/node.crt
xpack.security.http.ssl.key: certs/node.key
xpack.security.http.ssl.certificate_authorities: ["certs/ca.crt"]
EOF

chown -R ec2-user:ec2-user "${ES_HOME}"

(
  cd "${ES_HOME}"
  if [[ ! -f "${ES_HOME}/config/elasticsearch.keystore" ]]; then
    sudo -n -u ec2-user "${ES_HOME}/bin/elasticsearch-keystore" create -s
  fi

  BOOTSTRAP_PW=""
  for _ in $(seq 1 12); do
    if [[ "${ES_SECRETS_BACKEND}" == "s3" ]]; then
      if BOOTSTRAP_PW="$(aws s3 cp "${ES_BOOTSTRAP_S3_URI}" - --region "${AWS_REGION}")"; then
        break
      fi
    else
      if BOOTSTRAP_PW="$(aws secretsmanager get-secret-value \
        --region "${AWS_REGION}" \
        --secret-id "${ES_BOOTSTRAP_SECRET_ARN}" \
        --query SecretString \
        --output text)"; then
        break
      fi
    fi
    sleep 5
    BOOTSTRAP_PW=""
  done
  if [[ -z "${BOOTSTRAP_PW}" ]]; then
    echo "init_application: failed to read bootstrap password" >&2
    exit 1
  fi
  printf '%s' "${BOOTSTRAP_PW}" | sudo -n -u ec2-user "${ES_HOME}/bin/elasticsearch-keystore" add --force --stdin bootstrap.password
  unset BOOTSTRAP_PW
)

echo "init_application: elasticsearch ready at ${ES_HOME}"
