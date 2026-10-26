#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  printf 'USAGE: %s [chezmoi-config-file]\n' "$0" >&2
  exit 2
fi
config_file="${1:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
scripts_dir="$script_dir"
manifests_dir="$repo_root/bootstrap/manifests"

# shellcheck disable=SC1091
source "$scripts_dir/common.sh"
install_error_trap "$0"

setup_go_env
export_tool_path "$GOBIN"

# Hooks use the running chezmoi binary; manual and CI callers use PATH.
chezmoi_bin="${CHEZMOI_EXECUTABLE:-chezmoi}"
if ! command -v "$chezmoi_bin" >/dev/null 2>&1; then
  printf 'ERROR: chezmoi is required to check the environment.\n' >&2
  exit 1
fi

chezmoi_config_args=()
if [[ -n "$config_file" ]]; then
  if [[ ! -f "$config_file" ]]; then
    printf "ERROR: chezmoi configuration is missing. Run 'chezmoi init' first.\n" >&2
    exit 1
  fi
  chezmoi_config_args=(--config="$config_file")
fi

# Resolve platform rules from the root templates and the persisted opt-in.
# Do not infer desktop selection from this shell's graphical session.
platform_facts="$(
  "$chezmoi_bin" ${chezmoi_config_args[@]+"${chezmoi_config_args[@]}"} --source="$repo_root" execute-template \
    '{{ if hasKey . "desktopBaseline" }}{{ includeTemplate "system-package-manager" . }}|{{ includeTemplate "desktop-platform-supported" . }}|{{ .desktopBaseline }}|{{ .chezmoi.os }}{{ end }}'
)"
if [[ -z "$platform_facts" ]]; then
  printf "ERROR: chezmoi configuration lacks desktopBaseline. Run 'chezmoi init' first.\n" >&2
  exit 1
fi
IFS='|' read -r package_manager desktop_platform_supported desktop_baseline platform <<<"$platform_facts"

log_step "🔎" "Running environment checks..."

errors=0
ghostty_bin=""

check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    log_check_ok "$1"
  else
    log_check_missing "$1"
    errors=$((errors + 1))
  fi
}

check_path() {
  local path="$1"
  local name="$2"

  if [[ -e "$path" ]]; then
    log_check_ok "$name"
  else
    log_check_missing "$name"
    errors=$((errors + 1))
  fi
}

# Every package declared in an apt manifest must be installed according to dpkg.
check_apt_packages() {
  local manifest="$1"
  local entries=""
  local package=""
  local status=""

  if ! entries="$(manifest_entries "$manifest")"; then
    errors=$((errors + 1))
    return 0
  fi

  while IFS= read -r package; do
    if [[ -z "$package" ]]; then
      continue
    fi
    status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
    if [[ "$status" == *"install ok installed"* ]]; then
      log_check_ok "$package"
    else
      log_check_missing "$package"
      errors=$((errors + 1))
    fi
  done <<<"$entries"
}

check_pacman_packages() {
  local manifest="$1" entries="" package=""
  if ! entries="$(manifest_entries "$manifest")"; then
    errors=$((errors + 1))
    return 0
  fi
  while read -r package; do
    [[ -n "$package" ]] || continue
    if pacman -Q "$package" >/dev/null 2>&1; then
      log_check_ok "$package"
    else
      log_check_missing "$package"
      errors=$((errors + 1))
    fi
  done <<<"$entries"
}

# Homebrew validates a Brewfile natively; presence is checked, upgrades are not.
check_brewfile() {
  local brewfile="$1"
  local brew_bin=""
  local output=""

  if ! brew_bin="$(brew_command)"; then
    errors=$((errors + 1))
    return 0
  fi

  if output="$("$brew_bin" bundle check --file="$brewfile" --no-upgrade --verbose 2>&1)"; then
    log_check_ok "${brewfile#"$manifests_dir/"}"
  else
    log_warning "Homebrew bundle is not satisfied: $brewfile"
    printf '%s\n' "$output" >&2
    errors=$((errors + 1))
  fi
}

# mise reports which tools its configuration declares but has not installed.
check_mise_toolchain() {
  local missing=""
  local tool=""
  local version=""

  if ! command -v mise >/dev/null 2>&1; then
    log_check_missing "mise"
    errors=$((errors + 1))
    return 0
  fi
  log_check_ok "mise"
  check_path "$XDG_CONFIG_HOME/mise/config.toml" "mise config"

  # Only stdout is parsed; mise warnings stay visible on stderr without being
  # mistaken for missing tools.
  if ! missing="$(mise ls --current --missing --no-header)"; then
    log_warning "mise could not inspect the configured toolchain"
    errors=$((errors + 1))
    return 0
  fi

  if [[ -n "$missing" ]]; then
    while read -r tool version _; do
      if [[ -n "$tool" ]]; then
        log_check_missing "$tool $version"
      fi
    done <<<"$missing"
    errors=$((errors + 1))
    return 0
  fi

  log_check_ok "mise toolchain"
}

resolve_ghostty_bin() {
  local candidate=""

  if command -v ghostty >/dev/null 2>&1; then
    command -v ghostty
    return 0
  fi

  for candidate in \
    "/Applications/Ghostty.app/Contents/MacOS/ghostty" \
    "$HOME/Applications/Ghostty.app/Contents/MacOS/ghostty"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

check_ghostty_config() {
  local executable="$1"

  if [[ -z "$executable" ]]; then
    log_check_missing "ghostty"
    errors=$((errors + 1))
    return 0
  fi

  log_check_ok "ghostty"
  if "$executable" +validate-config >/dev/null 2>&1; then
    log_check_ok "ghostty config"
  else
    log_warning "Ghostty could not load the managed configuration."
    errors=$((errors + 1))
  fi
}

# Linux: verify the declared faces are available. Ghostty selects its font in
# its own configuration; the system monospace preference belongs to the user.
check_desktop_font_fontconfig() {
  local installed_names=""
  local postscript_name=""

  if ! command -v fc-list >/dev/null 2>&1; then
    log_check_missing "fontconfig"
    errors=$((errors + 1))
    return 0
  fi

  installed_names="$(fc-list -f '%{postscriptname}\n' ":family=$MAPLE_MONO_FAMILY")"
  for postscript_name in $MAPLE_MONO_POSTSCRIPT_NAMES; do
    if ! grep -Fxq "$postscript_name" <<<"$installed_names"; then
      log_check_missing "$postscript_name"
      errors=$((errors + 1))
      return 0
    fi
  done

  log_check_ok "$MAPLE_MONO_FAMILY"
}

# macOS: the Homebrew cask installs one file per declared face in the user font directory.
check_desktop_font_macos() {
  local font_dir="$HOME/Library/Fonts"
  local postscript_name=""

  for postscript_name in $MAPLE_MONO_POSTSCRIPT_NAMES; do
    if [[ ! -f "$font_dir/$postscript_name.ttf" ]]; then
      log_check_missing "$postscript_name.ttf"
      errors=$((errors + 1))
      return 0
    fi
  done

  log_check_ok "$MAPLE_MONO_FAMILY"
}

check_manifest_cmds() {
  local manifest="$1"
  local command_name_parser="$2"
  local entries=""
  local tool_spec=""
  local command_name=""

  if ! entries="$(manifest_entries "$manifest")"; then
    errors=$((errors + 1))
    return 0
  fi

  while IFS= read -r tool_spec; do
    if [[ -z "$tool_spec" ]]; then
      continue
    fi
    command_name="$($command_name_parser "$tool_spec")"

    if [[ -z "$command_name" ]]; then
      log_warning "Skipping invalid manifest entry in $manifest: $tool_spec"
      errors=$((errors + 1))
      continue
    fi

    check_cmd "$command_name"
  done <<<"$entries"
}

# An installed uv tool must still run on the Python its environment was built on.
check_uv_tool_envs() {
  local manifest="$1"
  local entries=""
  local tool_dir=""
  local tool_spec=""
  local name=""
  local problem=""

  if ! entries="$(manifest_entries "$manifest")" || ! tool_dir="$(uv tool dir 2>/dev/null)"; then
    errors=$((errors + 1))
    return 0
  fi

  while IFS= read -r tool_spec; do
    [[ -n "$tool_spec" ]] || continue
    name="$(uv_tool_binary_name "$tool_spec")"
    # check_manifest_cmds reports a tool that is not installed.
    [[ -d "$tool_dir/$name" ]] || continue
    if ! problem="$(uv_tool_env_healthy "$tool_dir" "$name")"; then
      log_warning "uv tool $name: $problem. Run \`bash $scripts_dir/install-uv-tools.sh $manifest\` to rebuild it."
      errors=$((errors + 1))
    fi
  done <<<"$entries"
}

check_oh_my_zsh_plugins() {
  local manifest="$1"
  local zsh_custom_dir="$2"
  local entries=""
  local plugin_entry=""
  local plugin_repo=""
  local plugin_path=""
  local extra_field=""

  if ! entries="$(manifest_entries "$manifest")"; then
    errors=$((errors + 1))
    return 0
  fi

  while IFS= read -r plugin_entry; do
    if [[ -z "$plugin_entry" ]]; then
      continue
    fi
    read -r plugin_repo plugin_path extra_field <<<"$plugin_entry"

    if [[ -z "$plugin_repo" || -z "$plugin_path" || -n "$extra_field" ]]; then
      log_warning "Skipping invalid oh-my-zsh plugin entry in $manifest: $plugin_entry"
      errors=$((errors + 1))
      continue
    fi

    check_path "$zsh_custom_dir/$plugin_path" "${plugin_path##*/}"
  done <<<"$entries"
}

# System packages
case "$package_manager" in
  pacman) check_pacman_packages "$manifests_dir/system/pacman-packages.txt" ;;
  apt) check_apt_packages "$manifests_dir/system/apt-packages.txt" ;;
  brew) check_brewfile "$manifests_dir/system/Brewfile" ;;
  *)
    log_warning "Unsupported system package manager: $package_manager"
    errors=$((errors + 1))
    ;;
esac

# Runtimes and binary-distributed tools
check_mise_toolchain

# Ecosystem tools
check_manifest_cmds "$manifests_dir/ecosystem/go-tools.txt" go_tool_binary_name
check_manifest_cmds "$manifests_dir/ecosystem/uv-tools.txt" uv_tool_binary_name
check_uv_tool_envs "$manifests_dir/ecosystem/uv-tools.txt"

# Shell assets
oh_my_zsh_dir="$(oh_my_devenv_oh_my_zsh_dir)"
check_path "$oh_my_zsh_dir/oh-my-zsh.sh" "oh-my-zsh"
check_oh_my_zsh_plugins "$manifests_dir/shell/oh-my-zsh-plugins.txt" "$oh_my_zsh_dir/custom"
if ! bash "$scripts_dir/install-shell-completions.sh" check "$platform" "$manifests_dir/shell/completions.txt"; then
  errors=$((errors + 1))
fi

if [[ "$desktop_baseline" == "true" && "$desktop_platform_supported" == "true" ]]; then
  # Desktop baseline
  desktop_font_manifest_load "$manifests_dir/desktop/maple-mono-nf-cn.env"
  case "$package_manager" in
    brew) check_brewfile "$manifests_dir/desktop/Brewfile" ;;
    pacman) check_pacman_packages "$manifests_dir/desktop/pacman-packages.txt" ;;
    apt) check_apt_packages "$manifests_dir/desktop/apt-packages.txt" ;;
  esac
  check_path "$XDG_CONFIG_HOME/ghostty/config.ghostty" "ghostty config file"
  ghostty_bin="$(resolve_ghostty_bin || true)"
  check_ghostty_config "$ghostty_bin"
  if [[ "$platform" == "darwin" ]]; then
    check_desktop_font_macos
  else
    check_desktop_font_fontconfig
  fi
fi

if [[ $errors -gt 0 ]]; then
  log_warning "$errors required tool(s) or asset(s) are missing."
  print_diagnostic_hints
  exit 1
fi

log_step "🎉" "All checks passed."

log_info "Core tools in this environment:"
print_version_line() {
  local name="$1"
  local output=""
  local executable="$name"

  if [[ "$name" == "chezmoi" ]]; then
    executable="$chezmoi_bin"
  fi

  if [[ "$name" != "ghostty" ]] && ! command -v "$executable" >/dev/null 2>&1; then
    return 0
  fi

  case "$name" in
    chezmoi) output="$("$chezmoi_bin" --version 2>/dev/null | head -1 | awk '{print $3}' | tr -d ',')" ;;
    git)     output="$(git --version 2>/dev/null | awk '{print $3}')" ;;
    mise)    output="$(mise --version 2>/dev/null | awk '{print $1}')" ;;
    ghostty)
      [[ -n "$ghostty_bin" ]] || return 0
      output="$("$ghostty_bin" --version 2>/dev/null | head -1 | awk '{print $2}')"
      ;;
    *)       output="installed" ;;
  esac

  printf '    %-16s %s\n' "$name" "${output:-installed}"
}

# mise prints one `<tool> <version>` line per tool in its current configuration.
print_mise_toolchain() {
  local listing=""
  local tool=""
  local version=""

  listing="$(mise current 2>/dev/null)" || return 0
  while read -r tool version _; do
    if [[ -n "$tool" ]]; then
      printf '    %-16s %s\n' "$tool" "$version"
    fi
  done <<<"$listing"
}

print_version_line chezmoi
print_version_line git
print_version_line mise
print_mise_toolchain
if [[ "$desktop_baseline" == "true" && "$desktop_platform_supported" == "true" ]]; then
  print_version_line ghostty
fi
