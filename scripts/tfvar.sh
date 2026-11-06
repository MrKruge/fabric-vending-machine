#!/usr/bin/env bash
# Prints the quoted string value of a simple `key = "value"` line in a tfvars file.
# Usage: tfvar.sh <file> <key>
set -euo pipefail
file="${1:?usage: tfvar.sh <file> <key>}"
key="${2:?usage: tfvar.sh <file> <key>}"
awk -F'"' -v k="$key" '$0 ~ "^[[:space:]]*"k"[[:space:]]*=" { print $2; exit }' "$file"
