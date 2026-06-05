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
# shellcheck disable=SC1091
source "$script_dir/go-env.sh"

# Honor mirror-mode overrides for GOPROXY before calling `go install`.
# A no-op in external mode; in internal mode, exports GOPROXY iff the
# user supplied DOTFILES_GOPROXY. See bootstrap/scripts/mirrors.sh.
dotfiles_apply_mirror_env

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

blocked_tools=()
for tool in "${tools[@]}"; do
  if [[ "$tool" == *"golangci-lint"* ]]; then
    blocked_tools+=("$tool")
  fi
done

if [[ ${#blocked_tools[@]} -gt 0 ]]; then
  echo "ERROR: golangci-lint must be managed by mise, not go install. Remove these entries from $MANIFEST:" >&2
  printf '  - %s\n' "${blocked_tools[@]}" >&2
  exit 1
fi

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

for tool in "${tools[@]}"; do
  binary="$(go_tool_binary_name "$tool")"
  requested_version="${tool##*@}"

  if [[ "$requested_version" == "$tool" ]]; then
    requested_version=""
  fi

  current_version=""
  if [[ "$force_reinstall" != "1" ]]; then
    current_version="$(installed_go_tool_version "$binary" || true)"
  fi

  # Skip when we know the exact version and it already matches. `@latest`
  # intentionally re-runs `go install` so upstream moves are picked up; `go
  # install` is cache-aware so this is cheap when nothing changed.
  if [[ "$force_reinstall" != "1" \
        && -n "$current_version" \
        && -n "$requested_version" \
        && "$requested_version" != "latest" \
        && "$current_version" == "$requested_version" ]]; then
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
