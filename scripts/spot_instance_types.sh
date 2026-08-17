#!/usr/bin/env bash
# Rank Spot instance types by recent Linux/UNIX Spot price and print an HCL
# spot_instance_types list for terraform.tfvars.
#
# Usage:
#   scripts/spot_instance_types.sh
#   scripts/spot_instance_types.sh --top 5 --vcpus 2 --memory-gib 8
#
# Reads aws_profile / aws_region from terraform/terraform.tfvars when present.
# Override with AWS_PROFILE, AWS_REGION / AWS_DEFAULT_REGION.
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

TOP=5
VCPUS=2
MEMORY_GIB=8
ARCH=arm64
HOURS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --top)
      TOP="${2:?}"
      shift 2
      ;;
    --vcpus)
      VCPUS="${2:?}"
      shift 2
      ;;
    --memory-gib)
      MEMORY_GIB="${2:?}"
      shift 2
      ;;
    --arch)
      ARCH="${2:?}"
      shift 2
      ;;
    --hours)
      HOURS="${2:?}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

PROFILE="${AWS_PROFILE:-$(tfvar aws_profile)}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(tfvar aws_region)}}"

if [[ -z "${REGION}" ]]; then
  echo "spot_instance_types: need aws_region (terraform/terraform.tfvars or AWS_REGION)" >&2
  exit 1
fi

AWS=(aws --region "${REGION}")
if [[ -n "${PROFILE}" ]]; then
  AWS+=(--profile "${PROFILE}")
fi

START_TIME="$(date -u -d "${HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-"${HOURS}"H +%Y-%m-%dT%H:%M:%SZ)"

MEMORY_MIB=$((MEMORY_GIB * 1024))

echo "Region=${REGION} arch=${ARCH} vCPUs=${VCPUS} memory>=${MEMORY_GIB}GiB top=${TOP}" >&2
echo "Fetching matching instance types..." >&2

TYPES_JSON="$("${AWS[@]}" ec2 describe-instance-types \
  --filters \
    "Name=processor-info.supported-architecture,Values=${ARCH}" \
    "Name=vcpu-info.default-vcpus,Values=${VCPUS}" \
    "Name=bare-metal,Values=false" \
  --query 'InstanceTypes[].[InstanceType,MemoryInfo.SizeInMiB]' \
  --output json)"

CANDIDATES="$(TYPES_JSON="${TYPES_JSON}" MEMORY_MIB="${MEMORY_MIB}" python3 - <<'PY'
import json, os
rows = json.loads(os.environ["TYPES_JSON"])
need = int(os.environ["MEMORY_MIB"])
types = sorted({t for t, mib in rows if int(mib) >= need})
print("\n".join(types))
PY
)"

if [[ -z "${CANDIDATES}" ]]; then
  echo "No instance types matched." >&2
  exit 1
fi

mapfile -t TYPE_ARR <<< "${CANDIDATES}"
echo "Matched ${#TYPE_ARR[@]} types; fetching Spot prices (last ${HOURS}h)..." >&2

# describe-spot-price-history accepts multiple --instance-types; chunk to stay safe.
SPOT_JSON="[]"
CHUNK=20
for ((i = 0; i < ${#TYPE_ARR[@]}; i += CHUNK)); do
  CHUNK_TYPES=("${TYPE_ARR[@]:i:CHUNK}")
  PART="$("${AWS[@]}" ec2 describe-spot-price-history \
    --instance-types "${CHUNK_TYPES[@]}" \
    --product-descriptions "Linux/UNIX" \
    --start-time "${START_TIME}" \
    --output json)"
  SPOT_JSON="$(SPOT_JSON="${SPOT_JSON}" PART="${PART}" python3 - <<'PY'
import json, os
a = json.loads(os.environ["SPOT_JSON"])
b = json.loads(os.environ["PART"]).get("SpotPriceHistory", [])
print(json.dumps(a + b))
PY
)"
done

RESULT="$(SPOT_JSON="${SPOT_JSON}" TOP="${TOP}" python3 - <<'PY'
import json, os, statistics
from collections import defaultdict

history = json.loads(os.environ["SPOT_JSON"])
top_n = int(os.environ["TOP"])

# Latest price per (type, az), then mean across AZs for a region score.
latest = {}
for row in history:
    key = (row["InstanceType"], row["AvailabilityZone"])
    ts = row["Timestamp"]
    if key not in latest or ts > latest[key][0]:
        latest[key] = (ts, float(row["SpotPrice"]))

by_type = defaultdict(list)
for (itype, _az), (_ts, price) in latest.items():
    by_type[itype].append(price)

ranked = []
for itype, prices in by_type.items():
    ranked.append((statistics.mean(prices), min(prices), max(prices), itype, len(prices)))
ranked.sort(key=lambda x: x[0])
ranked = ranked[:top_n]

if not ranked:
    raise SystemExit("No Spot price samples returned for matched types.")

print("RANKED")
for mean_p, min_p, max_p, itype, naz in ranked:
    print(f"{itype}\t{mean_p:.6f}\t{min_p:.6f}\t{max_p:.6f}\t{naz}")

print("HCL")
print("spot_instance_types = [")
for i, (_mean, _min, _max, itype, _naz) in enumerate(ranked):
    comma = "," if i < len(ranked) - 1 else ""
    print(f'  "{itype}"{comma}')
print("]")
PY
)"

echo "${RESULT}" | awk 'BEGIN{p=0} /^RANKED$/{p=1; next} /^HCL$/{p=0; next} p' | column -t -s $'\t' >&2
echo >&2
echo "${RESULT}" | awk 'BEGIN{p=0} /^HCL$/{p=1; next} p'
echo >&2
echo "# Cheapest-first by mean latest Spot price across AZs (Linux/UNIX)." >&2
echo "# Paste into terraform/terraform.tfvars. With capacity-optimized-prioritized, order = preference." >&2
