#!/usr/bin/env bash

stdout_is_tty() {
  [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]
}

emoji_enabled() {
  stdout_is_tty && [[ "${NO_EMOJI:-0}" != "1" ]]
}

color_enabled() {
  stdout_is_tty && [[ "${NO_COLOR:-0}" != "1" ]]
}

logo_enabled() {
  stdout_is_tty && [[ "${NO_LOGO:-0}" != "1" ]]
}

terminal_columns() {
  local cols=""

  if [[ -n "${COLUMNS:-}" ]] && [[ "${COLUMNS}" =~ ^[0-9]+$ ]]; then
    cols="$COLUMNS"
  elif stdout_is_tty && command -v tput >/dev/null 2>&1; then
    cols="$(tput cols 2>/dev/null || true)"
  fi

  if [[ -z "$cols" ]] && stdout_is_tty && [[ -r /dev/tty ]]; then
    cols="$(stty size </dev/tty 2>/dev/null | awk '{print $2}')"
  fi

  if [[ "$cols" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$cols"
  else
    printf '120\n'
  fi
}

print_startup_banner() {
  local cols=120
  local subtitle='bootstrap your dev env at lightning speed'
  local line1=""
  local line2=""
  local line3=""
  local line4=""
  local line5=""
  local banner_width=0
  local subtitle_padding=0
  local wide_banner_width=72
  local magenta=""
  local dim=""
  local reset=""

  if ! logo_enabled; then
    return 0
  fi

  if color_enabled; then
    magenta='\033[38;5;205m'
    dim='\033[2m'
    reset='\033[0m'
  fi

  cols="$(terminal_columns)"

  if [[ "$cols" -ge $((wide_banner_width + 2)) ]]; then
    line1='   ____  __  __   __  _____  __   ____  _______    _________   ___    __'
    line2='  / __ \/ / / /  /  |/  /\ \/ /  / __ \/ ____/ |  / / ____/ | / / |  / /'
    line3=' / / / / /_/ /  / /|_/ /  \  /  / / / / __/  | | / / __/ /  |/ /| | / / '
    line4='/ /_/ / __  /  / /  / /   / /  / /_/ / /___  | |/ / /___/ /|  / | |/ /  '
    line5='\____/_/ /_/  /_/  /_/   /_/  /_____/_____/  |___/_____/_/ |_/  |___/   '
  else
    line1='  ___  _  _   __  ____   __  ___  _____   _____ _  ___   __'
    line2=' / _ \| || | |  \/  \ \ / / |   \| __\ \ / / __| \| \ \ / /'
    line3='| (_) | __ | | |\/| |\ V /  | |) | _| \ V /| _|| .` |\ V / '
    line4=' \___/|_||_| |_|  |_| |_|   |___/|___| \_/ |___|_|\_| \_/  '
  fi

  printf '%b%s%b\n' "$magenta" "$line1" "$reset"
  printf '%b%s%b\n' "$magenta" "$line2" "$reset"
  printf '%b%s%b\n' "$magenta" "$line3" "$reset"
  if [[ -n "$line4" ]]; then
    printf '%b%s%b\n' "$magenta" "$line4" "$reset"
  fi
  if [[ -n "$line5" ]]; then
    printf '%b%s%b\n' "$magenta" "$line5" "$reset"
  fi

  banner_width=${#line1}
  if [[ ${#line2} -gt $banner_width ]]; then
    banner_width=${#line2}
  fi
  if [[ ${#line3} -gt $banner_width ]]; then
    banner_width=${#line3}
  fi
  if [[ ${#line4} -gt $banner_width ]]; then
    banner_width=${#line4}
  fi
  if [[ ${#line5} -gt $banner_width ]]; then
    banner_width=${#line5}
  fi

  subtitle_padding=$((banner_width - ${#subtitle}))
  if [[ $subtitle_padding -lt 1 ]]; then
    subtitle_padding=1
  fi

  printf '%*s%b%s%b\n' "$subtitle_padding" '' "$dim" "$subtitle" "$reset"
  printf '\n'
}

log_step() {
  local icon="$1"
  shift

  if emoji_enabled && [[ -n "$icon" ]]; then
    printf '%s ==> %s\n' "$icon" "$*"
  else
    printf '==> %s\n' "$*"
  fi
}

log_info() {
  if emoji_enabled; then
    printf 'ℹ️  ==> %s\n' "$*"
  else
    printf 'INFO: %s\n' "$*"
  fi
}

log_check_ok() {
  local name="$1"

  if emoji_enabled; then
    printf '  ✅ %s\n' "$name"
  else
    printf '  OK %s\n' "$name"
  fi
}

log_check_missing() {
  local name="$1"

  if emoji_enabled; then
    printf '  ❌ %s not found\n' "$name" >&2
  else
    printf '  MISSING %s\n' "$name" >&2
  fi
}

log_warning() {
  if emoji_enabled; then
    printf '⚠️  ==> %s\n' "$*" >&2
  else
    printf 'WARNING: %s\n' "$*" >&2
  fi
}

require_sudo() {
  local purpose="${1:-perform privileged operations}"

  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    printf 'ERROR: sudo is required to %s\n' "$purpose" >&2
    return 1
  fi

  if ! sudo -v; then
    printf 'ERROR: failed to acquire sudo credentials to %s\n' "$purpose" >&2
    return 1
  fi
}

# Shared "what to try next" hints, printed to stderr. Used by both the
# bootstrap error trap and the final environment check so the guidance lives
# in one place instead of drifting across two copies.
print_diagnostic_hints() {
  local backup_root="${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi-first-run-backup"

  printf 'What to try next:\n' >&2
  printf '  1. Re-run with verbose output:\n' >&2
  printf '       chezmoi apply --verbose --debug\n' >&2
  printf '  2. If network calls failed, check connectivity to apt mirrors,\n' >&2
  printf '     Homebrew, get.chezmoi.io / mise.run, github.com, and your\n' >&2
  printf '     Go / PyPI proxies.\n' >&2
  printf '  3. If a single step repeatedly fails, run only that step:\n' >&2
  printf '       chezmoi apply --verbose <script-under-.chezmoiscripts>\n' >&2
  printf '  4. Your pre-bootstrap configs (if any) were backed up under:\n' >&2
  printf '       %s/\n' "$backup_root" >&2
  printf '  5. If this looks like a baseline bug, file an issue with the\n' >&2
  printf '     failing script / line / exit code.\n' >&2
}

_bootstrap_error_handler() {
  local exit_code="$1"
  local line_no="$2"
  local script="${3:-${BASH_SOURCE[1]:-unknown}}"

  printf '\n' >&2
  printf '================================================================\n' >&2
  printf 'Bootstrap step failed.\n' >&2
  printf '  script : %s\n' "$script" >&2
  printf '  line   : %s\n' "$line_no" >&2
  printf '  exit   : %s\n' "$exit_code" >&2
  printf '\n' >&2
  print_diagnostic_hints
  printf '================================================================\n' >&2
}

# Install a trap that reports the failing script, line, and exit code before
# bash exits. Intended to be called once per top-level bootstrap script.
install_error_trap() {
  local script="${1:-${BASH_SOURCE[1]:-unknown}}"

  trap '_bootstrap_error_handler "$?" "$LINENO" "'"$script"'"' ERR
}

manifest_entries() {
  local manifest="$1"

  if [[ ! -f "$manifest" ]]; then
    printf 'ERROR: %s not found\n' "$manifest" >&2
    return 1
  fi

  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$manifest"
}

go_tool_binary_name() {
  local tool="$1"

  tool="${tool%%[[:space:]]*}"
  tool="${tool%@*}"

  printf '%s\n' "${tool##*/}"
}

uv_tool_binary_name() {
  local tool="$1"

  tool="$(printf '%s\n' "$tool" | sed -E 's/[[:space:]].*$//; s/\[.*$//; s/(===|==|~=|!=|<=|>=|<|>|@).*$//')"

  printf '%s\n' "$tool"
}

common_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
common_repo_root="$(cd "$common_script_dir/../.." && pwd)"

# Resolve XDG_CONFIG_HOME before bootstrap reads any local configuration.
# shellcheck disable=SC1091
source "$common_repo_root/dot_local/share/oh-my-devenv/xdg.sh"
oh_my_devenv_setup_xdg_config_home
oh_my_devenv_source_shared_env

# shellcheck disable=SC1091
source "$common_script_dir/mirrors.sh"

unset common_script_dir common_repo_root
