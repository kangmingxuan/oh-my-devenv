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

# When DOTFILES_FORCE_REINSTALL=1 the script skips the idempotency probe and
# reinstalls every tool.
force_reinstall="${DOTFILES_FORCE_REINSTALL:-0}"

tools=()
while IFS= read -r tool; do
  tools+=("$tool")
done < <(manifest_entries "$MANIFEST")

if [[ ${#tools[@]} -eq 0 ]]; then
  echo "No Go tools to install."
  exit 0
fi

# Every entry must pin an exact module version before anything is installed.
versions=()
for tool in "${tools[@]}"; do
  versions+=("$(go_tool_version "$tool")") || exit 1
done

installed_go_tool_version() {
  local binary="$1"
  local path=""

  path="$(command -v "$binary" 2>/dev/null || true)"

  if [[ -z "$path" ]]; then
    return 1
  fi

  go version -m "$path" 2>/dev/null \
    | awk '$1 == "mod" { print $3; exit }'
}

echo "==> Syncing Go tools from $MANIFEST"
echo "==> Using GOBIN=$GOBIN"

for index in "${!tools[@]}"; do
  tool="${tools[$index]}"
  binary="$(go_tool_binary_name "$tool")"
  requested_version="${versions[$index]}"

  current_version=""
  if [[ "$force_reinstall" != "1" ]]; then
    current_version="$(installed_go_tool_version "$binary" || true)"
  fi

  if [[ "$force_reinstall" != "1" && "$current_version" == "$requested_version" ]]; then
    echo "  == $tool (already at $current_version, skipping)"
    continue
  fi

  if [[ "$force_reinstall" == "1" ]]; then
    echo "  -> $tool (force reinstall)"
  else
    echo "  -> $tool"
  fi
  go install "$tool"
done

echo "==> Go tools synced."
