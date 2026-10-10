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

if ! command -v go >/dev/null 2>&1; then
  echo "ERROR: go not found in PATH" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"

setup_go_env

tools=()
while IFS= read -r tool; do
  tools+=("$tool")
done < <(manifest_entries "$MANIFEST")

if [[ ${#tools[@]} -eq 0 ]]; then
  echo "No Go tools to install."
  exit 0
fi

# Every entry must pin an exact module version before anything is installed.
for tool in "${tools[@]}"; do
  go_tool_version "$tool" >/dev/null
done

echo "==> Syncing Go tools from $MANIFEST"
echo "==> Using GOBIN=$GOBIN"

# The ecosystem hook runs this script only when its inputs change, so every
# tool is installed again. A Go upgrade must rebuild the tools, and the Go
# build cache keeps reinstalling an unchanged tool fast.
for tool in "${tools[@]}"; do
  echo "  -> $tool"
  go install "$tool"
done

echo "==> Go tools synced."
