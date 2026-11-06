#!/usr/bin/env bash
# set-storage-format.sh — sets defaultDatasetStorageFormat on all vended Fabric workspaces
# via the Power BI REST API (api.powerbi.com/v1.0/myorg/groups/{id}), and optionally reports
# or updates dataset-level storage format (targetStorageMode) for each dataset in those workspaces.
#
# Storage format is read per-workspace from the terraform output "workspace_storage_formats"
# (a map of workspace_id → "Large" | "Small"). Set default_storage_format in the workspace
# tfvars entry to control the value; it defaults to "Large".
#
# In dry-run mode the script reads the current format from the API and shows a diff
# of current vs desired — no PATCH calls are made.
#
# Dataset-level storage format uses the API property targetStorageMode:
#   PremiumFiles = Large
#   Abf          = Small (Analysis Services Buffer — the default)
# Note: existing datasets are not retroactively changed when the workspace default changes.
# Use --datasets to also report/update dataset-level formats.
#
# Usage:
#   set-storage-format.sh <working_directory> [--dry-run] [--datasets]
#
# Required env vars:
#   TF_VAR_fabric_spn_client_id
#   TF_VAR_fabric_spn_client_secret
#   FABRIC_TENANT_ID  (the Azure AD / Entra tenant ID that hosts your Fabric tenant —
#                      same value as var.tenant_id in your tfvars)

set -euo pipefail

WORKING_DIR="${1:?Usage: $0 <working_directory> [--dry-run] [--datasets]}"
DRY_RUN=false
INCLUDE_DATASETS=false

for arg in "${@:2}"; do
  case "$arg" in
    --dry-run)  DRY_RUN=true ;;
    --datasets) INCLUDE_DATASETS=true ;;
  esac
done

if [[ "$DRY_RUN" == "true" ]]; then
  echo "==> DRY RUN — reads current format from API, no changes applied"
fi

# Maps API targetStorageMode values to human-readable labels
storage_mode_label() {
  case "$1" in
    PremiumFiles) echo "Large" ;;
    Abf)          echo "Small" ;;
    "")           echo "Small" ;;
    *)            echo "$1"    ;;
  esac
}

storage_mode_api_value() {
  case "$1" in
    Large) echo "PremiumFiles" ;;
    Small) echo "Abf" ;;
    *)     echo "$1" ;;
  esac
}

TENANT_ID="${FABRIC_TENANT_ID:?FABRIC_TENANT_ID env var is required}"
CLIENT_ID="${TF_VAR_fabric_spn_client_id:?TF_VAR_fabric_spn_client_id env var is required}"
CLIENT_SECRET="${TF_VAR_fabric_spn_client_secret:?TF_VAR_fabric_spn_client_secret env var is required}"

echo "==> Acquiring Power BI access token..."
TOKEN_RESPONSE=$(curl -sf -X POST \
  "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "client_secret=${CLIENT_SECRET}" \
  --data-urlencode "scope=https://analysis.windows.net/powerbi/api/.default")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')

if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
  echo "Error: failed to acquire access token" >&2
  echo "$TOKEN_RESPONSE" >&2
  exit 1
fi

echo "==> Reading terraform outputs..."

# In dry-run mode, prefer reading desired formats from the plan file so the output
# reflects the current configuration (including unapplied changes) rather than last state.
# In apply mode, read from state (which is freshly updated by terraform apply).
STORAGE_FORMATS="{}"

if [[ "$DRY_RUN" == "true" && -f "${WORKING_DIR}/plan.tfplan" ]]; then
  echo "    Reading desired formats from plan file..."
  PLAN_JSON=$(terraform -chdir="$WORKING_DIR" show -json plan.tfplan 2>/dev/null || echo "{}")
  STORAGE_FORMATS=$(echo "$PLAN_JSON" | jq '.planned_values.outputs.workspace_storage_formats.value // empty' 2>/dev/null || echo "{}")
fi

# Fall back to state (works for apply mode, or CI when plan file unavailable)
if [[ "$STORAGE_FORMATS" == "{}" || -z "$STORAGE_FORMATS" ]]; then
  STORAGE_FORMATS=$(terraform -chdir="$WORKING_DIR" output -json workspace_storage_formats 2>/dev/null || echo "{}")
fi

# Last resort: workspace_ids with default Large (state exists but output not yet stored)
if [[ "$STORAGE_FORMATS" == "{}" || -z "$STORAGE_FORMATS" ]]; then
  WS_IDS=$(terraform -chdir="$WORKING_DIR" output -json workspace_ids 2>/dev/null || echo "{}")
  if [[ "$WS_IDS" == "{}" || -z "$WS_IDS" ]]; then
    echo "==> No workspaces in state — nothing to do."
    exit 0
  fi
  echo "    Note: workspace_storage_formats not yet in state — assuming 'Large' for all workspaces."
  STORAGE_FORMATS=$(echo "$WS_IDS" | jq '[to_entries[] | {(.value): "Large"}] | add')
fi

ERRORS=0

if [[ "$DRY_RUN" == "true" ]]; then
  printf "\n%-40s  %-10s  %-10s  %s\n" "WORKSPACE ID" "CURRENT" "DESIRED" "ACTION"
  printf "%-40s  %-10s  %-10s  %s\n"   "------------" "-------" "-------" "------"
fi

while IFS=$'\t' read -r WS_ID DESIRED_FORMAT; do
  if [[ "$DESIRED_FORMAT" != "Large" && "$DESIRED_FORMAT" != "Small" ]]; then
    echo "  SKIP ${WS_ID} — unrecognised format '${DESIRED_FORMAT}', expected Large or Small" >&2
    ERRORS=$((ERRORS + 1))
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    RESPONSE=$(curl -sf \
      "https://api.powerbi.com/v1.0/myorg/groups/${WS_ID}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" || echo "{}")
    CURRENT_FORMAT=$(echo "$RESPONSE" | jq -r '.defaultDatasetStorageFormat // "Small"')

    if [[ "$CURRENT_FORMAT" == "$DESIRED_FORMAT" ]]; then
      ACTION="no change"
    else
      ACTION="<-- would update"
    fi
    printf "%-40s  %-10s  %-10s  %s\n" "$WS_ID" "$CURRENT_FORMAT" "$DESIRED_FORMAT" "$ACTION"
  else
    echo "==> ${WS_ID}  →  ${DESIRED_FORMAT}"
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH \
      "https://api.powerbi.com/v1.0/myorg/groups/${WS_ID}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"defaultDatasetStorageFormat\": \"${DESIRED_FORMAT}\"}")

    if [[ "$HTTP_STATUS" == "200" ]]; then
      echo "    OK"
    else
      echo "    FAILED (HTTP ${HTTP_STATUS})" >&2
      ERRORS=$((ERRORS + 1))
    fi
  fi

  # --- Dataset-level storage format ---
  if [[ "$INCLUDE_DATASETS" == "true" ]]; then
    DS_RESPONSE=$(curl -sf \
      "https://api.powerbi.com/v1.0/myorg/groups/${WS_ID}/datasets" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" || echo '{"value":[]}')

    if [[ "$DRY_RUN" == "true" ]]; then
      printf "\n  Datasets in workspace %s:\n" "$WS_ID"
      printf "  %-38s  %-40s  %-10s  %-10s  %s\n" "DATASET ID" "NAME" "CURRENT" "DESIRED" "ACTION"
      printf "  %-38s  %-40s  %-10s  %-10s  %s\n" "----------" "----" "-------" "-------" "------"

      while IFS=$'\t' read -r DS_ID DS_NAME DS_MODE; do
        CURRENT_LABEL=$(storage_mode_label "$DS_MODE")
        if [[ "$CURRENT_LABEL" == "$DESIRED_FORMAT" ]]; then
          DS_ACTION="no change"
        else
          DS_ACTION="<-- would update"
        fi
        printf "  %-38s  %-40s  %-10s  %-10s  %s\n" "$DS_ID" "$DS_NAME" "$CURRENT_LABEL" "$DESIRED_FORMAT" "$DS_ACTION"
      done < <(echo "$DS_RESPONSE" | jq -r '.value[] | [.id, .name, (.targetStorageMode // "")] | @tsv')
      echo ""
    else
      DESIRED_MODE=$(storage_mode_api_value "$DESIRED_FORMAT")
      while IFS=$'\t' read -r DS_ID DS_NAME DS_MODE; do
        CURRENT_LABEL=$(storage_mode_label "$DS_MODE")
        if [[ "$CURRENT_LABEL" == "$DESIRED_FORMAT" ]]; then
          echo "    dataset ${DS_NAME} — already ${DESIRED_FORMAT}, skipping"
          continue
        fi
        echo "    dataset ${DS_NAME}  →  ${DESIRED_FORMAT}"
        DS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH \
          "https://api.powerbi.com/v1.0/myorg/groups/${WS_ID}/datasets/${DS_ID}" \
          -H "Authorization: Bearer ${ACCESS_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "{\"targetStorageMode\": \"${DESIRED_MODE}\"}")
        if [[ "$DS_STATUS" == "200" ]]; then
          echo "      OK"
        else
          echo "      FAILED (HTTP ${DS_STATUS}) — dataset may require republish to change storage format" >&2
          ERRORS=$((ERRORS + 1))
        fi
      done < <(echo "$DS_RESPONSE" | jq -r '.value[] | [.id, .name, (.targetStorageMode // "")] | @tsv')
    fi
  fi

done < <(echo "$STORAGE_FORMATS" | jq -r 'to_entries[] | [.key, .value] | @tsv')

if [[ $ERRORS -gt 0 ]]; then
  echo "Error: ${ERRORS} workspace(s) failed to update." >&2
  exit 1
fi

echo ""
echo "==> Done."
