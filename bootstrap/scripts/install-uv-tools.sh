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

if ! command -v uv >/dev/null 2>&1; then
  echo "ERROR: uv not found in PATH" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"

# Honor mirror-mode overrides for UV_INDEX_URL before calling `uv tool
# install`. A no-op in external mode; in internal mode, exports
# UV_INDEX_URL iff the user supplied DOTFILES_UV_INDEX_URL.
# See bootstrap/scripts/mirrors.sh.
dotfiles_apply_mirror_env

# When DOTFILES_FORCE_REINSTALL=1 the script skips the idempotency probe and
# reinstalls every tool. Useful for recovering from a partially broken tool
# directory.
force_reinstall="${DOTFILES_FORCE_REINSTALL:-0}"

tools=()
while IFS= read -r tool; do
  tools+=("$tool")
done < <(manifest_entries "$MANIFEST")

if [[ ${#tools[@]} -eq 0 ]]; then
  echo "No uv tools to install."
  exit 0
fi

echo "==> Syncing uv tools from $MANIFEST"

# Snapshot the current `uv tool list` once. Output format is stable as
# "<package> v<version>" lines followed by indented binary entries.
installed_snapshot=""
if installed_snapshot="$(uv tool list 2>/dev/null)"; then
  :
else
  installed_snapshot=""
fi

installed_version_for() {
  local name="$1"
  awk -v name="$name" '
    $0 ~ "^"name" v" {
      v=$2
      sub(/^v/, "", v)
      print v
      exit
    }
  ' <<<"$installed_snapshot"
}

requirement_version_spec() {
  local spec="$1"

  case "$spec" in
    *==*) printf '%s\n' "${spec##*==}" ;;
    *) printf '\n' ;;
  esac
}

for tool in "${tools[@]}"; do
  name="$(uv_tool_binary_name "$tool")"
  wanted="$(requirement_version_spec "$tool")"
  current=""

  if [[ -n "$installed_snapshot" ]]; then
    current="$(installed_version_for "$name")"
  fi

  if [[ "$force_reinstall" != "1" && -n "$current" && -n "$wanted" && "$current" == "$wanted" ]]; then
    echo "  == $tool (already at $current, skipping)"
    continue
  fi

  if [[ "$force_reinstall" == "1" ]]; then
    echo "  -> $tool (force reinstall)"
    uv tool install --reinstall "$tool"
  else
    echo "  -> $tool"
    uv tool install "$tool"
  fi
done

echo "==> uv tools synced."
