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

if ! command -v uv >/dev/null 2>&1; then
  log_error "uv not found in PATH"
  exit 1
fi

# When DOTFILES_FORCE_REINSTALL=1 the script skips the idempotency probe and
# rebuilds every installed tool. Useful for recovering from a partially broken
# tool directory.
force_reinstall="${DOTFILES_FORCE_REINSTALL:-0}"

tools=()
while IFS= read -r tool; do
  tools+=("$tool")
done < <(manifest_entries "$MANIFEST")

if [[ ${#tools[@]} -eq 0 ]]; then
  log_skip "No uv tools to install."
  exit 0
fi

if ! resolve_mise_python; then
  exit 1
fi

log_info "Syncing uv tools from $MANIFEST"

# Snapshot the current `uv tool list` once. Output format is stable as
# "<package> v<version>" lines followed by indented binary entries.
installed_snapshot="$(capture_probe uv tool list)" || {
  probe_status=$?
  log_error "could not list installed uv tools (exit $probe_status)." "$installed_snapshot"
  exit "$probe_status"
}

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

tool_dir="$(capture_probe uv tool dir)" || {
  probe_status=$?
  log_error "could not resolve the uv tool directory (exit $probe_status)." "$tool_dir"
  exit "$probe_status"
}

# `uv tool install --reinstall` keeps the environment's pyvenv.cfg, so an
# environment built on another Python must be removed and created again.
rebuild_tool() {
  uv tool uninstall "$1"
  uv tool install --python "$MISE_PYTHON" "$2"
}

for tool in "${tools[@]}"; do
  name="$(uv_tool_binary_name "$tool")"
  wanted="$(requirement_version_spec "$tool")"
  current=""

  if [[ -n "$installed_snapshot" ]]; then
    current="$(installed_version_for "$name")"
  fi

  if [[ -n "$current" ]]; then
    if [[ "$force_reinstall" == "1" ]]; then
      log_info "Installing $tool (force reinstall)"
      rebuild_tool "$name" "$tool"
      continue
    fi
    if ! problem="$(uv_tool_env_healthy "$tool_dir" "$name" "$MISE_PYTHON_VERSION")"; then
      log_info "Installing $tool (rebuilding: $problem)"
      rebuild_tool "$name" "$tool"
      continue
    fi
    if [[ -n "$wanted" && "$current" == "$wanted" ]]; then
      log_skip "$tool (already at $current, skipping)"
      continue
    fi
  fi

  log_info "Installing $tool"
  uv tool install --python "$MISE_PYTHON" "$tool"
done

log_ok uv "Tools synced."
