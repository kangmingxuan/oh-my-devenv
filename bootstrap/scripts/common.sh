#!/usr/bin/env bash

# Decide against the destination descriptor before writing anything.
_log_rich() {
  [[ -t "$1" && -z "${NO_COLOR:-}" && -z "${CI:-}" && "${TERM:-}" != dumb ]]
}

_log_render() {
  local level="$1" message="$2" detail="${3:-}"
  local fd=1 indent='  ' plain='' rich='' style='' rich_mode=0
  local detail_style='' reset=$'\033[0m' esc=$'\033['

  case "$level" in
    phase)          indent=''; plain='==>'; rich='❯'; style='1;36' ;;
    done)           plain='[done]'; rich='✓ done'; style=2 ;;
    ok)             plain='[ok]'; rich='✓'; style=32; detail_style=2 ;;
    skip)           plain='[skip]'; rich='›'; style=2 ;;
    info)           plain='[info]'; rich='›' ;;
    missing)        fd=2; plain='[missing]'; rich='✗'; style=31 ;;
    warn)           fd=2; plain='[warn]'; rich='!'; style='1;33' ;;
    error)          fd=2; plain='[error]'; rich='✗'; style='1;31' ;;
    detail)         fd=2; indent='    ' ;;
    would)          plain='[would]'; rich='▸'; style=36 ;;
    next)           plain='[next]'; rich='next'; style=36 ;;
    summary)        indent=''; rich='✓'; style='1;32'; detail_style=2 ;;
    summary_failed) fd=2; indent=''; plain='[failed]'; rich='✗'; style='1;31'; detail_style=2 ;;
  esac

  if _log_rich "$fd"; then
    rich_mode=1
    if [[ -n "$style" ]]; then
      case "$level" in
        phase|done|error|summary|summary_failed)
          message="$esc${style}m$rich $message$reset"
          rich=''
          ;;
        *) rich="$esc${style}m$rich$reset" ;;
      esac
    fi
    plain="$rich"
  fi
  if [[ -n "$detail" ]]; then
    case "$level" in
      ok|missing)
        if (( rich_mode )); then
          message="$(printf '%-16s' "$message")"
        fi
        ;;
      summary|summary_failed) detail="($detail)" ;;
    esac
    if (( rich_mode )) && [[ -n "$detail_style" ]]; then
      detail="$esc${detail_style}m$detail$reset"
    fi
  fi
  printf '%s%s%s%s\n' "$indent" "${plain:+$plain }" "$message" "${detail:+ $detail}" >&"$fd"
}

log_phase() {
  log_phase_started=$SECONDS
  _log_render phase "$*"
}

log_phase_done() {
  local duration="${1:-$((SECONDS - log_phase_started))}"
  if (( duration >= 1 )); then
    _log_render 'done' "in ${duration}s"
  fi
  printf '\n'
}

log_ok()             { _log_render ok "$1" "${2:-}"; }
log_skip()           { _log_render skip "$*"; }
log_info()           { _log_render info "$*"; }
log_missing()        { _log_render missing "$1" "${2:-}"; }
log_warn()           { _log_render warn "$*"; }
log_would()          { _log_render would "$1" "$2"; }
log_next()           { _log_render next "$*"; }
log_summary()        { _log_render summary "$1" "${2:-}"; }
log_summary_failed() { _log_render summary_failed "$1" "${2:-}"; }

log_detail() {
  local line
  while IFS= read -r line; do
    _log_render detail "${line%$'\r'}"
  done <<<"$1"
}

log_error() {
  _log_render error "$1"
  shift
  local detail
  for detail in "$@"; do
    [[ -z "$detail" ]] || log_detail "$detail"
  done
  printf '\n' >&2
}

# Capture stdout on success. On failure return both streams through the
# substitution so the caller can render them under its diagnostic header.
capture_probe() {
  local error_file output status=0
  error_file="$(mktemp 2>&1)" || {
    status=$?
    printf '%s\n' "$error_file"
    return "$status"
  }
  output="$("$@" 2>"$error_file")" || status=$?
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  fi
  if (( status )) && [[ -s "$error_file" ]]; then
    printf '%s\n' "$(<"$error_file")"
  fi
  rm -f "$error_file"
  return "$status"
}

terminal_columns() {
  local cols="${COLUMNS:-}"
  if [[ ! "$cols" =~ ^[1-9][0-9]*$ ]]; then
    cols="$(tput cols 2>/dev/null || true)"
  fi
  if [[ ! "$cols" =~ ^[1-9][0-9]*$ ]]; then
    cols="$( { stty size </dev/tty; } 2>/dev/null | awk '{print $2}' || true)"
  fi
  if [[ "$cols" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "$cols"
  else
    printf '80\n'
  fi
}

_banner_width() {
  awk 'length > width { width = length } END { print width }' "$1"
}

print_startup_banner() {
  [[ -t 1 && "${NO_LOGO:-}" != 1 && -z "${CI:-}" ]] || return 0

  local art="$common_repo_root/bootstrap/assets/banner-wide.txt"
  local width cols line i ch span style r g b
  local colored=0 truecolor=0 dim='' reset=''
  local subtitle='bootstrap your dev env at lightning speed'

  width="$(_banner_width "$art")"
  cols="$(terminal_columns)"
  if (( cols < width + 2 )); then
    art="$common_repo_root/bootstrap/assets/banner-narrow.txt"
    width="$(_banner_width "$art")"
  fi
  span=$((width - 1))

  if _log_rich 1; then
    colored=1
    dim=$'\033[2m'
    reset=$'\033[0m'
    if [[ "${COLORTERM:-}" == truecolor || "${COLORTERM:-}" == 24bit || "${WT_SESSION+x}" == x ]]; then
      truecolor=1
    fi
  fi

  while IFS= read -r line; do
    if (( ! colored )); then
      printf '%s\n' "$line"
      continue
    fi
    for (( i=0; i<${#line}; i++ )); do
      ch="${line:i:1}"
      if [[ "$ch" == ' ' ]]; then
        printf ' '
        continue
      fi
      style=35
      if (( truecolor )); then
        r=$((255 - 80 * i / span))
        g=$((95 + 40 * i / span))
        b=$((175 + 80 * i / span))
        style="38;2;$r;$g;$b"
      fi
      printf '\033[%sm%s%s' "$style" "$ch" "$reset"
    done
    printf '\n'
  done <"$art"

  for line in "$subtitle" "$1"; do
    printf '%*s%s%s%s\n' "$((width - ${#line}))" '' "$dim" "$line" "$reset"
  done
  printf '\n'
}

require_sudo() {
  local purpose="${1:-perform privileged operations}"

  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    log_error "sudo is required to $purpose"
    return 1
  fi

  if ! sudo -v; then
    log_error "failed to acquire sudo credentials to $purpose"
    return 1
  fi
}

# Paths the bootstrap creates and owns. They depend on XDG_STATE_HOME and
# XDG_DATA_HOME, so call them after this file has loaded bootstrap.env.
first_run_backup_root() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi-first-run-backup"
}

maple_mono_font_dir() {
  printf '%s\n' "$XDG_DATA_HOME/fonts/maple-mono-nf-cn"
}

# The installer writes this marker into the font directory it owns.
maple_mono_font_marker() {
  printf '%s\n' "$(maple_mono_font_dir)/.oh-my-devenv-managed"
}

# Shared "what to try next" text for the error trap and the final check.
diagnostic_hints() {
  local backup_root=""

  backup_root="$(first_run_backup_root)"

  printf '%s\n' "What to try next:
1. Re-run with verbose output: chezmoi apply --verbose --debug
2. Check connectivity to your package mirrors, Homebrew, get.chezmoi.io, mise.run, github.com, and your Go / PyPI proxies.
3. If a step repeatedly fails, run it with chezmoi apply --verbose <script-under-.chezmoiscripts>.
4. Look for pre-bootstrap config backups under $backup_root/.
5. Report the failing script, line, and exit code when filing an issue."
}

_bootstrap_error_handler() {
  local exit_code="$1"
  local line_no="$2"
  local script="${3:-${BASH_SOURCE[1]:-unknown}}"

  log_error "Bootstrap step failed (exit $exit_code)." \
    "script: $script, line $line_no" "${4:-}" "$(diagnostic_hints)"
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
    log_error "$manifest not found"
    return 1
  fi

  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$manifest"
}

go_tool_binary_name() {
  local tool="$1"
  local name=""
  local major_suffix_pattern='^v([2-9]|[1-9][0-9]+)$'

  tool="${tool%%[[:space:]]*}"
  tool="${tool%@*}"
  name="${tool##*/}"
  if [[ "$tool" == */* && "$name" =~ $major_suffix_pattern ]]; then
    tool="${tool%/*}"
    name="${tool##*/}"
  fi

  printf '%s\n' "$name"
}

uv_tool_binary_name() {
  local tool="$1"

  tool="$(printf '%s\n' "$tool" | sed -E 's/[[:space:]].*$//; s/\[.*$//; s/(===|==|~=|!=|<=|>=|<|>|@).*$//')"

  printf '%s\n' "$tool"
}

# Set MISE_PYTHON and MISE_PYTHON_VERSION from global mise configuration.
# Resolve from / so project configuration cannot change ecosystem runtimes.
resolve_mise_python() {
  local output
  MISE_PYTHON=""
  MISE_PYTHON_VERSION=""

  if ! output="$(cd / 2>&1 && capture_probe mise which python)" || [[ -z "$output" ]]; then
    log_error "could not resolve the mise-selected Python with 'mise which python' from /" "$output"
    return 1
  fi
  MISE_PYTHON="$output"
  if ! output="$(capture_probe "$MISE_PYTHON" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"; then
    log_error "could not read the mise-selected Python version: $MISE_PYTHON" "$output"
    return 1
  fi
  # install-uv-tools.sh and check.sh consume this public output.
  # shellcheck disable=SC2034
  MISE_PYTHON_VERSION="$output"
}

# Succeed when <tool-dir>/<name> runs on both its recorded Python version and
# the expected mise-selected version. Otherwise print the problem and fail.
uv_tool_env_healthy() {
  local env_dir="$1/$2"
  local expected_version="$3"
  local built_on=""
  local running=""

  if ! running="$("$env_dir/bin/python" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null)"; then
    printf 'interpreter is missing\n'
    return 1
  fi

  built_on="$(sed -n 's/^version_info[[:space:]]*=[[:space:]]*//p' "$env_dir/pyvenv.cfg" 2>/dev/null | cut -d. -f1-3 || true)"
  if [[ "$built_on" != "$running" ]]; then
    printf 'built on Python %s but runs Python %s\n' "${built_on:-unknown}" "$running"
    return 1
  fi
  if [[ "$running" != "$expected_version" ]]; then
    printf 'runs Python %s but mise selects Python %s\n' "$running" "$expected_version"
    return 1
  fi
}

# Print the exact module version pinned by a go-tools.txt entry. Every entry
# must use `module@vX.Y.Z` (pre-release and pseudo-version suffixes allowed).
go_tool_version() {
  local tool="$1"
  local version=""
  local version_pattern='^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'

  tool="${tool%%[[:space:]]*}"
  version="${tool##*@}"

  if [[ "$version" == "$tool" || ! "$version" =~ $version_pattern ]]; then
    log_error "Go tool entry must pin an exact module version (module@vX.Y.Z): $1"
    return 1
  fi

  printf '%s\n' "$version"
}

# Go installs binaries into GOBIN, which defaults beneath GOPATH.
setup_go_env() {
  export GOPATH="${GOPATH:-$HOME/go}"
  export GOBIN="${GOBIN:-$GOPATH/bin}"
  mkdir -p "$GOBIN"
}

# Put user-local binaries, mise shims, Homebrew on macOS, and any extra
# directories ahead of PATH for hooks that run mise-managed tools. Directories
# need not exist yet.
export_tool_path() {
  local tool_path=""
  local extra_dir=""
  local brew_bin=""

  tool_path="$HOME/.local/bin:$(oh_my_devenv_mise_shims_dir)"
  if [[ "${OSTYPE:-}" == darwin* ]] && brew_bin="$(brew_command 2>/dev/null)"; then
    tool_path="$tool_path:$(dirname "$brew_bin")"
  fi
  for extra_dir in "$@"; do
    tool_path="$tool_path:$extra_dir"
  done
  PATH="$tool_path:$PATH"
  export PATH
}

# Resolve the Homebrew executable from PATH or its standard install prefixes.
brew_command() {
  if command -v brew >/dev/null 2>&1; then
    command -v brew
  elif [[ -x /opt/homebrew/bin/brew ]]; then
    printf '/opt/homebrew/bin/brew\n'
  elif [[ -x /usr/local/bin/brew ]]; then
    printf '/usr/local/bin/brew\n'
  else
    log_error "brew not found in PATH or common install locations"
    return 1
  fi
}

# Load the desktop font manifest into MAPLE_MONO_* variables and validate its
# schema. The manifest is a repository-owned file of fixed scalar assignments.
desktop_font_manifest_load() {
  local manifest="$1"
  local required_value=""
  local postscript_name=""
  local family_pattern='^[A-Za-z0-9][A-Za-z0-9 -]*$'
  local postscript_pattern='^[A-Za-z0-9-]+$'
  local sha256_pattern='^[0-9a-f]{64}$'

  if [[ ! -f "$manifest" ]]; then
    log_error "$manifest not found"
    return 1
  fi

  MAPLE_MONO_FAMILY=""
  MAPLE_MONO_POSTSCRIPT_NAMES=""
  # MAPLE_MONO_VERSION, MAPLE_MONO_ARCHIVE, and MAPLE_MONO_URL are public
  # outputs of this loader. This file only checks them for presence through
  # the ${!required_value} indirection below; install-maple-mono-font.sh reads
  # them after calling this function, so ShellCheck cannot see the consumers.
  # shellcheck disable=SC2034
  MAPLE_MONO_VERSION=""
  # shellcheck disable=SC2034
  MAPLE_MONO_ARCHIVE=""
  # shellcheck disable=SC2034
  MAPLE_MONO_URL=""
  MAPLE_MONO_SHA256=""
  # shellcheck disable=SC1090
  source "$manifest"

  for required_value in \
    MAPLE_MONO_FAMILY \
    MAPLE_MONO_POSTSCRIPT_NAMES \
    MAPLE_MONO_VERSION \
    MAPLE_MONO_ARCHIVE \
    MAPLE_MONO_URL \
    MAPLE_MONO_SHA256; do
    if [[ -z "${!required_value:-}" ]]; then
      log_error "$manifest does not define $required_value"
      return 1
    fi
  done

  if [[ ! "$MAPLE_MONO_FAMILY" =~ $family_pattern ]]; then
    log_error "MAPLE_MONO_FAMILY must contain only letters, digits, spaces, and hyphens: $MAPLE_MONO_FAMILY"
    return 1
  fi

  for postscript_name in $MAPLE_MONO_POSTSCRIPT_NAMES; do
    if [[ ! "$postscript_name" =~ $postscript_pattern ]]; then
      log_error "MAPLE_MONO_POSTSCRIPT_NAMES contains an invalid PostScript name: $postscript_name"
      return 1
    fi
  done

  if [[ ! "$MAPLE_MONO_SHA256" =~ $sha256_pattern ]]; then
    log_error "MAPLE_MONO_SHA256 is not a lowercase SHA-256 digest"
    return 1
  fi
}

common_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
common_repo_root="$(cd "$common_script_dir/../.." && pwd)"

# Resolve XDG directories before bootstrap reads any local configuration.
# shellcheck disable=SC1091
source "$common_repo_root/dot_local/share/oh-my-devenv/xdg.sh"
oh_my_devenv_setup_xdg_dirs
oh_my_devenv_source_env_file "$XDG_CONFIG_HOME/oh-my-devenv/bootstrap.env"

unset common_script_dir
