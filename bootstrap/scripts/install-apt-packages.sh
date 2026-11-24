#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"

MANIFEST="${1:-}"

if [[ -z "$MANIFEST" ]]; then
  log_error "$0 <manifest-path>"
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  log_error "$MANIFEST not found"
  exit 1
fi

# Parse package list: strip comments and blank lines.
packages=()
while IFS= read -r package; do
  packages+=("$package")
done < <(manifest_entries "$MANIFEST")

if [[ ${#packages[@]} -eq 0 ]]; then
  log_skip "No packages to install."
  exit 0
fi

log_info "Installing apt packages from $MANIFEST"

require_sudo "install apt packages"

sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"

log_ok apt "Packages installed."
