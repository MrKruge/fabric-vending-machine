#!/usr/bin/env bash
# check-storage-format.sh — reports and optionally sets storage format at workspace
# and dataset level via the Power BI REST API. Designed for Azure Portal Cloud Shell
# where az CLI is already authenticated — no SPN credentials or Terraform required.
#
# Usage:
#   bash check-storage-format.sh <workspace_id> [--set-large] [--set-small]
#
# Examples:
#   bash check-storage-format.sh 00000000-0000-0000-0000-000000000000
#   bash check-storage-format.sh 00000000-0000-0000-0000-000000000000 --set-large

set -euo pipefail

WS_ID="${1:?Usage: $0 <workspace_id> [--set-large | --set-small]}"
DESIRED_FORMAT=""

for arg in "${@:2}"; do
  case "$arg" in
    --set-large) DESIRED_FORMAT="Large" ;;
    --set-small) DESIRED_FORMAT="Small" ;;
  esac
done

# Maps API targetStorageMode values to human-readable labels
storage_mode_label() {
  case "$1" in
    PremiumFiles) echo "Large" ;;
    Abf)          echo "Small" ;;
    "")           echo "Small" ;;
    *)            echo "$1"    ;;
  esac
}

echo "==> Acquiring Power BI access token via az CLI..."
TOKEN=$(az account get-access-token \
  --resource https://analysis.windows.net/powerbi/api \
  --query accessToken -o tsv)

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "Error: failed to acquire token — are you logged in to az CLI?" >&2
  exit 1
fi

# ── Workspace-level ──────────────────────────────────────────────────────────
echo ""
echo "==> Workspace: ${WS_ID}"

WS_RESPONSE=$(curl -sf \
  "https://api.powerbi.com/v1.0/myorg/groups/${WS_ID}" \
  -H "Authorization: Bearer ${TOKEN}" || echo "{}")

WS_NAME=$(echo "$WS_RESPONSE"    | jq -r '.name // "unknown"')
WS_FORMAT=$(echo "$WS_RESPONSE"  | jq -r '.defaultDatasetStorageFormat // "Small"')

printf "    Name:                    %s\n" "$WS_NAME"
printf "    Default dataset format:  %s\n" "$WS_FORMAT"

if [[ -n "$DESIRED_FORMAT" && "$WS_FORMAT" != "$DESIRED_FORMAT" ]]; then
  echo "    Setting workspace default to ${DESIRED_FORMAT}..."
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH \
    "https://api.powerbi.com/v1.0/myorg/groups/${WS_ID}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"defaultDatasetStorageFormat\": \"${DESIRED_FORMAT}\"}")
  if [[ "$HTTP_STATUS" == "200" ]]; then
    echo "    OK — workspace default updated to ${DESIRED_FORMAT}"
  else
    echo "    FAILED (HTTP ${HTTP_STATUS})" >&2
  fi
elif [[ -n "$DESIRED_FORMAT" ]]; then
  echo "    Already ${DESIRED_FORMAT} — no change needed"
fi

# ── Dataset-level ────────────────────────────────────────────────────────────
echo ""
echo "==> Datasets:"
printf "    %-40s  %-10s  %s\n" "NAME" "FORMAT" "ID"
printf "    %-40s  %-10s  %s\n" "----" "------" "--"

DS_RESPONSE=$(curl -sf \
  "https://api.powerbi.com/v1.0/myorg/groups/${WS_ID}/datasets" \
  -H "Authorization: Bearer ${TOKEN}" || echo '{"value":[]}')

ERRORS=0

while IFS=$'\t' read -r DS_ID DS_NAME DS_MODE; do
  CURRENT_LABEL=$(storage_mode_label "$DS_MODE")
  printf "    %-40s  %-10s  %s\n" "$DS_NAME" "$CURRENT_LABEL" "$DS_ID"

  if [[ -n "$DESIRED_FORMAT" && "$CURRENT_LABEL" != "$DESIRED_FORMAT" ]]; then
    case "$DESIRED_FORMAT" in
      Large) API_MODE="PremiumFiles" ;;
      Small) API_MODE="Abf" ;;
    esac
    DS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH \
      "https://api.powerbi.com/v1.0/myorg/groups/${WS_ID}/datasets/${DS_ID}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"targetStorageMode\": \"${API_MODE}\"}")
    if [[ "$DS_STATUS" == "200" ]]; then
      printf "      --> updated to %s\n" "$DESIRED_FORMAT"
    else
      printf "      --> FAILED (HTTP %s) — may require republish\n" "$DS_STATUS" >&2
      ERRORS=$((ERRORS + 1))
    fi
  fi
done < <(echo "$DS_RESPONSE" | jq -r '.value[] | [.id, .name, (.targetStorageMode // "")] | @tsv')

echo ""
if [[ $ERRORS -gt 0 ]]; then
  echo "==> Done with ${ERRORS} error(s)."
  exit 1
fi
echo "==> Done."
