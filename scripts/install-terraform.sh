#!/usr/bin/env bash
# Installs a pinned Terraform release onto the agent and verifies its checksum.
# Usage: install-terraform.sh <version> [install-dir]
set -euo pipefail

version="${1:?usage: install-terraform.sh <version> [install-dir]}"
dest="${2:-$HOME/.local/bin}"

case "$(uname -m)" in
  x86_64)        arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

base="https://releases.hashicorp.com/terraform/${version}"
zip="terraform_${version}_linux_${arch}.zip"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/$zip" "$base/$zip"
curl -fsSL -o "$tmp/SHA256SUMS" "$base/terraform_${version}_SHA256SUMS"
(cd "$tmp" && grep " $zip\$" SHA256SUMS | sha256sum -c -)

mkdir -p "$dest"
unzip -qo "$tmp/$zip" terraform -d "$dest"
echo "$dest" >> "${GITHUB_PATH:-/dev/null}" 2>/dev/null || true
echo "##vso[task.prependpath]$dest"
"$dest/terraform" version
