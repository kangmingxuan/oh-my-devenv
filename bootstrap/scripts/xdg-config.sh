#!/usr/bin/env bash
set -euo pipefail

action="${1:-}"
config_file="${2:-}"

if [[ $# -gt 2 ]]; then
  printf 'USAGE: %s <apply|diff|managed|status> [chezmoi-config-file]\n' "$0" >&2
  exit 1
fi

case "$action" in
  apply | diff | managed | status) ;;
  *)
    printf 'USAGE: %s <apply|diff|managed|status> [chezmoi-config-file]\n' "$0" >&2
    exit 1
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

# shellcheck disable=SC1091
source "$script_dir/common.sh"

if ! command -v chezmoi >/dev/null 2>&1; then
  printf 'ERROR: chezmoi is required to manage XDG configuration\n' >&2
  exit 1
fi

xdg_source="$repo_root/xdg_config"

if [[ ! -d "$xdg_source" ]]; then
  printf 'ERROR: XDG chezmoi source not found: %s\n' "$xdg_source" >&2
  exit 1
fi

if [[ "$action" == "apply" ]]; then
  if [[ -e "$XDG_CONFIG_HOME" && ! -d "$XDG_CONFIG_HOME" ]]; then
    printf 'ERROR: XDG_CONFIG_HOME is not a directory: %s\n' "$XDG_CONFIG_HOME" >&2
    exit 1
  fi

  if [[ ! -d "$XDG_CONFIG_HOME" ]]; then
    mkdir -p "$XDG_CONFIG_HOME"
    chmod 700 "$XDG_CONFIG_HOME"
  fi
fi

chezmoi_config_args=()
if [[ -n "$config_file" ]]; then
  chezmoi_config_args=(--config="$config_file")
fi

desktop_platform_supported="$(
  chezmoi "${chezmoi_config_args[@]}" --source="$repo_root" execute-template \
    '{{ includeTemplate "desktop-platform-supported" . }}'
)"

if [[ "$desktop_platform_supported" == "true" ]]; then
  override_data='{"desktopPlatformSupported":true}'
else
  override_data='{"desktopPlatformSupported":false}'
fi

xdg_chezmoi=(
  chezmoi
  "${chezmoi_config_args[@]}"
  --source="$xdg_source"
  --destination="$XDG_CONFIG_HOME"
  --override-data="$override_data"
)

case "$action" in
  apply)
    "${xdg_chezmoi[@]}" apply
    ;;
  diff)
    "${xdg_chezmoi[@]}" diff
    ;;
  managed)
    "${xdg_chezmoi[@]}" managed \
      --include=files,symlinks \
      --path-style=absolute
    ;;
  status)
    "${xdg_chezmoi[@]}" status --path-style=absolute
    ;;
esac
