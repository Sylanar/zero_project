#!/usr/bin/env bash
# Smoke-test Elasticsearch through the dev ingest gateway and print the
# connection details Filebeat/Logstash/curl need.
#
# Usage (from repo root or anywhere):
#   scripts/test_elasticsearch_connection.sh
#   scripts/test_elasticsearch_connection.sh --print-secrets
#
# Reads aws_profile / aws_region from terraform/terraform.tfvars when set.
# Override with AWS_PROFILE, AWS_REGION / AWS_DEFAULT_REGION.
#
# Why --resolve looks weird
# -------------------------
# The gateway is a TCP passthrough (socat), not TLS-terminating. You talk
# HTTPS to the Elastic IP, but the certificate the node presents is issued
# to a stable name like node-00, not to 51.x.x.x. curl checks the URL
# hostname against that cert, so the URL must be https://node-00:9200 while
# the TCP connection still goes to the EIP.
#
#   --resolve HOST:PORT:IP     map HOST:PORT -> IP          (3 fields)
#   --connect-to SRC:SP:DST:DP  rewrite SRC:SP -> DST:DP    (4 fields)
#
# The broken smoke test used --resolve with four fields (an extra :9200).
# That is --connect-to syntax; curl error 49 is "could not parse RESOLVE".
# Correct:  --resolve "node-00:9200:${EIP}"
# Same idea as scripts/on_node/cat_nodes, which maps node-00:9200 -> 127.0.0.1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"
TFVARS="${TF_DIR}/terraform.tfvars"
CA_FILE="${ROOT}/ca.crt"
PRINT_SECRETS=0

tfvar() {
  local key="$1"
  local line
  [[ -f "${TFVARS}" ]] || return 0
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${TFVARS}" | head -n1 || true)"
  [[ -n "${line}" ]] || return 0
  sed -E 's/^[^=]+=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' <<< "${line}" | tr -d '[:space:]'
}

usage() {
  sed -n '2,28p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-secrets)
      PRINT_SECRETS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

PROFILE="${AWS_PROFILE:-$(tfvar aws_profile)}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(tfvar aws_region)}}"

if [[ -z "${REGION}" ]]; then
  echo "test_elasticsearch_connection: need aws_region (terraform/terraform.tfvars or AWS_REGION)" >&2
  exit 1
fi

export AWS_DEFAULT_REGION="${REGION}"
if [[ -n "${PROFILE}" ]]; then
  export AWS_PROFILE="${PROFILE}"
fi

tf_raw() {
  terraform -chdir="${TF_DIR}" output -raw "$1" 2>/dev/null || true
}

EIP="$(tf_raw ingest_gateway_public_ip)"
if [[ -z "${EIP}" || "${EIP}" == "null" ]]; then
  echo "test_elasticsearch_connection: ingest_gateway_public_ip is empty." >&2
  echo "Set ingest_client_cidrs in terraform/terraform.tfvars and apply." >&2
  exit 1
fi

# Prefer Terraform state (no extra AWS call). Fall back to the cache bucket
# if elasticsearch_bootstrap_password has not been applied as an output yet.
PW="$(tf_raw elasticsearch_bootstrap_password)"
if [[ -z "${PW}" ]]; then
  BUCKET="$(tf_raw cache_bucket_id)"
  if [[ -z "${BUCKET}" ]]; then
    echo "test_elasticsearch_connection: cannot read bootstrap password from Terraform or S3" >&2
    exit 1
  fi
  PW="$(aws s3 cp "s3://${BUCKET}/secrets/elasticsearch/bootstrap-password" -)"
fi

CA_PEM="$(tf_raw elasticsearch_ca_cert)"
if [[ -n "${CA_PEM}" ]]; then
  printf '%s\n' "${CA_PEM}" > "${CA_FILE}"
else
  CA_URI="$(tf_raw elasticsearch_ca_s3_uri)"
  aws s3 cp "${CA_URI}" "${CA_FILE}"
fi

# Read the CN/SAN the node actually presents so we do not guess node-00 vs
# node-03 (both live in AZ[0]; the proxy picks one).
NODE_NAME="$(
  openssl s_client -connect "${EIP}:9200" -servername ingest </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
    | sed -n 's/.*CN=\([^,]*\).*/\1/p'
)"
if [[ -z "${NODE_NAME}" ]]; then
  echo "test_elasticsearch_connection: TLS handshake to ${EIP}:9200 failed." >&2
  echo "Check ingest_client_cidrs matches your current public IP, and that the gateway has finished booting." >&2
  exit 1
fi

echo "ingest gateway : ${EIP}"
echo "node cert CN   : ${NODE_NAME}"
echo "CA file        : ${CA_FILE}"
echo "curl           : curl --cacert ${CA_FILE} --resolve ${NODE_NAME}:9200:${EIP} -u elastic:*** https://${NODE_NAME}:9200"
if [[ "${PRINT_SECRETS}" -eq 1 ]]; then
  echo "elastic password: ${PW}"
fi
echo

# HOST:PORT:IP — three fields. Do not append another :9200.
curl -fsS --cacert "${CA_FILE}" \
  --resolve "${NODE_NAME}:9200:${EIP}" \
  -u "elastic:${PW}" \
  "https://${NODE_NAME}:9200/_cluster/health?pretty"
echo
curl -fsS --cacert "${CA_FILE}" \
  --resolve "${NODE_NAME}:9200:${EIP}" \
  -u "elastic:${PW}" \
  "https://${NODE_NAME}:9200/_cat/nodes?v"
