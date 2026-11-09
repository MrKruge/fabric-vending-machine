#!/usr/bin/env bash
# Resume or suspend the Fabric capacity of one environment and wait until it has settled.
# The Fabric provider refuses to plan or apply workspaces against a paused capacity, so plan and
# apply always resume it first. Pausing afterwards is opt-in: `suspend` only acts when the
# environment's tfvars set capacity_auto_pause = true. Needs a logged-in `az` that can manage it.
# Name, resource group and subscription come from parameters/environments/<environment>.tfvars;
# an environment without a capacity_name, or a capacity that does not exist yet, is skipped.
#
# Usage: capacity.sh <environment> <resume|suspend>
set -uo pipefail

env_name="${1:?usage: capacity.sh <environment> <resume|suspend>}"
action="${2:?usage: capacity.sh <environment> <resume|suspend>}"
case "$action" in
  resume | suspend) ;;
  *) echo "action must be resume or suspend, got: $action" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_dir="${CAPACITY_ENV_DIR:-$root/parameters/environments}"
tfvars="$env_dir/$env_name.tfvars"
[ -f "$tfvars" ] || { echo "No such environment file: $tfvars" >&2; exit 2; }

name="$(bash "$root/scripts/tfvar.sh" "$tfvars" capacity_name)"
resource_group="$(bash "$root/scripts/tfvar.sh" "$tfvars" capacity_resource_group)"
subscription="$(bash "$root/scripts/tfvar.sh" "$tfvars" capacity_subscription_id)"

if [ -z "$name" ]; then
  echo "No capacity_name in $tfvars; nothing to $action."
  exit 0
fi

# Pausing after a run is opt-in: capacity_auto_pause = true in the environment's tfvars (a bool, not
# quoted). Without it the capacity keeps running, and billing, as it would without this pipeline.
auto_pause="$(grep -E '^[[:space:]]*capacity_auto_pause[[:space:]]*=' "$tfvars" | head -1 | sed -E 's/#.*//; s/.*=[[:space:]]*//; s/[[:space:]"]//g' || true)"
if [ "$action" = "suspend" ] && [ "$auto_pause" != "true" ]; then
  echo "capacity_auto_pause is not true in $env_name; leaving the capacity running."
  exit 0
fi

base="https://management.azure.com/subscriptions/$subscription/resourceGroups/$resource_group/providers/Microsoft.Fabric/capacities/$name"
api="api-version=2023-11-01"
settle_sleep="${CAPACITY_SETTLE_SLEEP:-30}"
active_sleep="${CAPACITY_ACTIVE_SLEEP:-10}"

state_of() { az rest --method get --url "$base?$api" --query properties.state -o tsv 2>/dev/null || true; }

state="$(state_of)"
if [ -z "$state" ]; then
  echo "Capacity $name does not exist yet; nothing to $action."
  exit 0
fi

if [ "$action" = "resume" ]; then
  # A pause or resume already in progress must finish first: Fabric rejects a resume while the
  # capacity is Pausing, and a pause can take many minutes.
  for _ in $(seq 1 40); do
    state="$(state_of)"
    case "$state" in
      Pausing | Resuming) echo "Waiting for the capacity to settle (now: $state)"; sleep "$settle_sleep" ;;
      *) break ;;
    esac
  done

  if [ "$state" != "Active" ]; then
    az rest --method post --url "$base/resume?$api" || { echo "Resume request failed." >&2; exit 1; }
  fi
  for _ in $(seq 1 60); do
    state="$(state_of)"
    [ "$state" = "Active" ] && break
    echo "Waiting for the capacity to become Active (now: $state)"
    sleep "$active_sleep"
  done
  echo "Capacity state: $state"
  [ "$state" = "Active" ]
else
  if [ "$state" = "Active" ]; then
    az rest --method post --url "$base/suspend?$api" || { echo "Suspend request failed." >&2; exit 1; }
    echo "Suspend requested."
  else
    echo "Capacity is $state; nothing to suspend."
  fi
fi
