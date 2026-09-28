#!/usr/bin/env bash
set -euo pipefail

manifest="${1:-}"
if [[ -z "$manifest" || ! -f "$manifest" ]]; then
  printf 'USAGE: %s <existing-manifest-path>\n' "$0" >&2
  exit 1
fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"

entries="$(manifest_entries "$manifest")"
packages=()
while read -r package; do
  [[ -n "$package" ]] || continue
  [[ "$package" =~ ^[a-zA-Z0-9@_+.-]+$ && "$package" != -* ]] || {
    printf 'ERROR: invalid pacman package: %s\n' "$package" >&2
    exit 1
  }
  packages+=("$package")
done <<<"$entries"
(( ${#packages[@]} > 0 )) || exit 0

require_sudo "install pacman packages"
# Use the existing synchronized databases. Never refresh with -Sy alone:
# Arch requires a full system upgrade, which is a separate user action.
sudo pacman -S --needed --noconfirm -- "${packages[@]}"
