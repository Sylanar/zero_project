#!/usr/bin/env bash
# Poll IMDS for Spot interruption; run handle_spot_eviction.sh once.
# Used in environment=dev so we skip EventBridge + SSM endpoints.
set -euo pipefail

HANDLER="/opt/zero/handle_spot_eviction.sh"
STARTED_FLAG="/run/zero-spot-eviction.started"
POLL_SECONDS="${SPOT_EVICTION_POLL_SECONDS:-5}"

TOKEN=""
refresh_token() {
  TOKEN="$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")"
}

imds() {
  local path="$1"
  local code
  code="$(curl -sS -o /tmp/zero-imds.out -w "%{http_code}" \
    -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    "http://169.254.169.254${path}" || true)"
  if [[ "${code}" == "401" || "${code}" == "403" ]]; then
    refresh_token
    code="$(curl -sS -o /tmp/zero-imds.out -w "%{http_code}" \
      -H "X-aws-ec2-metadata-token: ${TOKEN}" \
      "http://169.254.169.254${path}" || true)"
  fi
  printf '%s' "${code}"
}

refresh_token

while true; do
  if [[ -f "${STARTED_FLAG}" ]]; then
    sleep "${POLL_SECONDS}"
    continue
  fi

  code="$(imds /latest/meta-data/spot/instance-action)"
  if [[ "${code}" == "200" ]]; then
    echo "watch_spot_eviction: Spot interruption notice present; starting handler"
    touch "${STARTED_FLAG}"
    if [[ -x "${HANDLER}" ]]; then
      "${HANDLER}" || true
    else
      echo "watch_spot_eviction: ${HANDLER} missing" >&2
    fi
  fi
  sleep "${POLL_SECONDS}"
done
