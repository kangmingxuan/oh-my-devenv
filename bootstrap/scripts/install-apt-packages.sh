#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${1:-}"

if [[ -z "$MANIFEST" ]]; then
  echo "USAGE: $0 <manifest-path>" >&2
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: $MANIFEST not found" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"

# Parse package list: strip comments and blank lines.
packages=()
while IFS= read -r package; do
  packages+=("$package")
done < <(manifest_entries "$MANIFEST")

if [[ ${#packages[@]} -eq 0 ]]; then
  echo "No packages to install."
  exit 0
fi

echo "==> Installing apt packages from $MANIFEST"

require_sudo "install apt packages"

sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"

echo "==> apt packages installed successfully."
