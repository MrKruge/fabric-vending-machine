#!/usr/bin/env bash
# merge-workspaces.sh must read only *.tfvars directly in the directory, never subdirectories like examples/.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/ws/examples"
printf 'workspaces = {\n  real_PROD = {\n    display_name = "Real"\n    environment  = "PROD"\n  }\n}\n' > "$work/ws/real.tfvars"
printf 'workspaces = {\n  ghost_PROD = {\n    display_name = "Ghost"\n    environment  = "PROD"\n  }\n}\n' > "$work/ws/examples/example-ghost.tfvars"
out="$(bash "$root/scripts/merge-workspaces.sh" "$work/ws")"
fail=0
echo "$out" | grep -q "real_PROD" && echo "ok   a real workspace file is merged" || { echo "FAIL a real workspace file is merged"; fail=1; }
echo "$out" | grep -q "ghost_PROD" && { echo "FAIL a file under examples/ was merged"; fail=1; } || echo "ok   files under examples/ are never merged"
exit $fail
