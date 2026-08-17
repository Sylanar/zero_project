#!/usr/bin/env bash
# Terminate running cluster EC2 instances. Data EBS volumes are Terraform-managed
# and stay; each ASG-of-1 launches a replacement.
#
# Usage: scripts/terminate_instances.sh [-y]
# Reads aws_profile, aws_region, cluster_name from terraform/terraform.tfvars when present.
# Override with AWS_PROFILE, AWS_REGION / AWS_DEFAULT_REGION, CLUSTER_NAME.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFVARS="${ROOT}/terraform/terraform.tfvars"

tfvar() {
  local key="$1"
  local line
  [[ -f "${TFVARS}" ]] || return 0
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${TFVARS}" | head -n1 || true)"
  [[ -n "${line}" ]] || return 0
  sed -E 's/^[^=]+=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' <<< "${line}" | tr -d '[:space:]'
}

ASSUME_YES=0
if [[ "${1:-}" == "-y" ]]; then
  ASSUME_YES=1
fi

PROFILE="${AWS_PROFILE:-$(tfvar aws_profile)}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(tfvar aws_region)}}"
CLUSTER="${CLUSTER_NAME:-$(tfvar cluster_name)}"

if [[ -z "${REGION}" || -z "${CLUSTER}" ]]; then
  echo "terminate_instances: need region and cluster_name (terraform/terraform.tfvars or env)" >&2
  exit 1
fi

AWS=(aws --region "${REGION}")
if [[ -n "${PROFILE}" ]]; then
  AWS+=(--profile "${PROFILE}")
fi

mapfile -t INSTANCES < <("${AWS[@]}" ec2 describe-instances \
  --filters "Name=tag:Cluster,Values=${CLUSTER}" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text | tr '\t' '\n' | awk 'NF')

if [[ "${#INSTANCES[@]}" -eq 0 ]]; then
  echo "No running instances tagged Cluster=${CLUSTER} in ${REGION}"
  exit 0
fi

echo "Cluster ${CLUSTER} (${REGION}${PROFILE:+, profile ${PROFILE}}):"
"${AWS[@]}" ec2 describe-instances \
  --instance-ids "${INSTANCES[@]}" \
  --query 'Reservations[].Instances[].[InstanceId,Placement.AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
  --output table

if [[ "${ASSUME_YES}" -ne 1 ]]; then
  read -r -p "Terminate ${#INSTANCES[@]} instance(s)? [y/N] " reply
  if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
    echo "Aborted"
    exit 1
  fi
fi

"${AWS[@]}" ec2 terminate-instances --instance-ids "${INSTANCES[@]}"
echo "Terminate requested; ASGs will launch replacements."
