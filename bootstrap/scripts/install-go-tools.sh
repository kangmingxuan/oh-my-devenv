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

# Resolve from / so project configuration and stale PATH entries cannot select Go.
if ! go_executable="$(cd / 2>&1 && capture_probe mise which go)" ||
  [[ "$go_executable" != /* || ! -x "$go_executable" ]]; then
  log_error "could not resolve the mise-selected Go with 'mise which go' from /" "$go_executable"
  exit 1
fi

setup_go_env

tools=()
while IFS= read -r tool; do
  tools+=("$tool")
done < <(manifest_entries "$MANIFEST")

if [[ ${#tools[@]} -eq 0 ]]; then
  log_skip "No Go tools to install."
  exit 0
fi

# Every entry must pin an exact module version before anything is installed.
for tool in "${tools[@]}"; do
  go_tool_version "$tool" >/dev/null
done

log_info "Syncing Go tools from $MANIFEST"
log_info "Using GOBIN=$GOBIN"

# Let the resolved executable derive GOROOT from its own toolchain.
unset GOROOT

# The ecosystem hook runs this script only when its inputs change, so every
# tool is installed again. A Go upgrade must rebuild the tools, and the Go
# build cache keeps reinstalling an unchanged tool fast.
for tool in "${tools[@]}"; do
  log_info "Installing $tool"
  "$go_executable" install "$tool"
done

log_ok Go "Tools synced."
