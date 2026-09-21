#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf 'Usage: %s <install|check|list> <linux|darwin> <manifest-path>\n' "${0##*/}" >&2
}

if [[ $# -ne 3 ]]; then
  usage
  exit 2
fi

action="$1"
platform="$2"
manifest="$3"

case "$action" in
  install | check | list) ;;
  *)
    usage
    exit 2
    ;;
esac

case "$platform" in
  linux | darwin) ;;
  *)
    usage
    exit 2
    ;;
esac

if [[ ! -f "$manifest" ]]; then
  printf 'ERROR: completion manifest not found: %s\n' "$manifest" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"

bash_completion_dir="$XDG_DATA_HOME/bash-completion/completions"
zsh_completion_dir="$XDG_DATA_HOME/zsh/site-functions"
bat_bash_completion_source="/usr/share/bash-completion/completions/batcat"
bat_zsh_completion_source="/usr/share/zsh/vendor-completions/_batcat"

# Commands from the manifest that list this platform, in manifest order.
completion_commands=()

load_completion_manifest() {
  local entries=""
  local entry=""
  local command_name=""
  local platforms=""
  local extra=""
  local platform_name=""
  local listed=0
  local -a platform_list=()
  local command_pattern='^[A-Za-z0-9][A-Za-z0-9_.+-]*$'
  local seen_commands=" "

  entries="$(manifest_entries "$manifest")" || exit 1

  while IFS= read -r entry; do
    if [[ -z "$entry" ]]; then
      continue
    fi

    read -r command_name platforms extra <<<"$entry"
    if [[ -z "$command_name" || -z "$platforms" || -n "$extra" ]]; then
      printf 'ERROR: completion manifest entry must be "<command> <platforms>": %s\n' "$entry" >&2
      exit 1
    fi
    if [[ ! "$command_name" =~ $command_pattern ]]; then
      printf 'ERROR: invalid completion command name in %s: %s\n' "$manifest" "$command_name" >&2
      exit 1
    fi
    if [[ "$seen_commands" == *" $command_name "* ]]; then
      printf 'ERROR: duplicate completion command in %s: %s\n' "$manifest" "$command_name" >&2
      exit 1
    fi
    seen_commands+="$command_name "

    listed=0
    IFS=, read -r -a platform_list <<<"$platforms"
    for platform_name in ${platform_list[@]+"${platform_list[@]}"}; do
      case "$platform_name" in
        linux | darwin) ;;
        *)
          printf 'ERROR: unsupported completion platform for %s in %s: %s\n' \
            "$command_name" "$manifest" "$platform_name" >&2
          exit 1
          ;;
      esac
      if [[ "$platform_name" == "$platform" ]]; then
        listed=1
      fi
    done

    if (( listed == 1 )); then
      completion_commands[${#completion_commands[@]}]="$command_name"
    fi
  done <<<"$entries"
}

# Print `<command>\t<shell>\t<target>` for every asset this platform manages.
# Linux receives Bash and Zsh assets; macOS receives Zsh assets only.
completion_entries() {
  local command_name=""

  for command_name in ${completion_commands[@]+"${completion_commands[@]}"}; do
    printf '%s\tzsh\t%s\n' "$command_name" "$zsh_completion_dir/_$command_name"
    if [[ "$platform" == linux ]]; then
      printf '%s\tbash\t%s\n' "$command_name" "$bash_completion_dir/$command_name.bash"
    fi
  done
}

completion_targets() {
  local command_name=""
  local shell_name=""
  local target=""

  while IFS=$'\t' read -r command_name shell_name target; do
    printf '%s\n' "$target"
  done < <(completion_entries)
}

# Command-specific generator adapters. The CLIs expose completion generation
# through different subcommands and flags, so this mapping stays in code.
generate_completion() {
  local command_name="$1"
  local shell_name="$2"

  case "$command_name" in
    uv)
      uv generate-shell-completion "$shell_name"
      ;;
    uvx)
      uvx --generate-shell-completion "$shell_name"
      ;;
    ruff)
      ruff generate-shell-completion "$shell_name"
      ;;
    mise | golangci-lint | dlv | chezmoi)
      "$command_name" completion "$shell_name"
      ;;
    *)
      printf 'ERROR: unsupported completion generator: %s\n' "$command_name" >&2
      return 1
      ;;
  esac
}

install_generated_completion() {
  local command_name="$1"
  local shell_name="$2"
  local target="$3"
  local target_dir=""
  local temporary=""

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'ERROR: completion generator is not on PATH: %s\n' "$command_name" >&2
    return 1
  fi

  target_dir="$(dirname "$target")"
  mkdir -p "$target_dir"
  temporary="$(mktemp "$target.tmp.XXXXXX")"

  if ! generate_completion "$command_name" "$shell_name" >"$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  if [[ ! -s "$temporary" ]]; then
    printf 'ERROR: %s generated an empty %s completion\n' "$command_name" "$shell_name" >&2
    rm -f "$temporary"
    return 1
  fi

  chmod 0644 "$temporary"
  mv -f "$temporary" "$target"
}

bat_completion_source() {
  local shell_name="$1"

  case "$shell_name" in
    bash)
      printf '%s\n' "$bat_bash_completion_source"
      ;;
    zsh)
      printf '%s\n' "$bat_zsh_completion_source"
      ;;
  esac
}

# Verify the Debian package-owned batcat completion this wrapper depends on.
check_bat_completion_source() {
  local shell_name="$1"
  local source_file=""

  source_file="$(bat_completion_source "$shell_name")"

  if [[ ! -r "$source_file" ]]; then
    printf 'ERROR: package-owned batcat %s completion is missing: %s\n' "$shell_name" "$source_file" >&2
    return 1
  fi

  if [[ "$shell_name" == bash ]] && ! grep -Eq '^_bat[[:space:]]*\(\)' "$source_file"; then
    printf 'ERROR: unexpected batcat Bash completion contract: %s\n' "$source_file" >&2
    return 1
  fi
  if [[ "$shell_name" == zsh ]] && [[ "$(head -n 1 "$source_file")" != "#compdef batcat" ]]; then
    printf 'ERROR: unexpected batcat Zsh completion contract: %s\n' "$source_file" >&2
    return 1
  fi
}

install_bat_completion() {
  local shell_name="$1"
  local target="$2"
  local source_file=""
  local target_dir=""
  local temporary=""

  check_bat_completion_source "$shell_name" || return 1
  source_file="$(bat_completion_source "$shell_name")"

  target_dir="$(dirname "$target")"
  mkdir -p "$target_dir"
  temporary="$(mktemp "$target.tmp.XXXXXX")"

  if [[ "$shell_name" == bash ]]; then
    printf '# shellcheck disable=SC1091\nsource %q\ncomplete -F _bat bat\n' \
      "$source_file" >"$temporary"
  else
    printf '#compdef bat\n\nautoload -Uz _batcat\n_batcat "$@"\n' >"$temporary"
  fi

  chmod 0644 "$temporary"
  mv -f "$temporary" "$target"
}

install_completion() {
  local command_name="$1"
  local shell_name="$2"
  local target="$3"

  case "$command_name" in
    bat)
      install_bat_completion "$shell_name" "$target"
      ;;
    *)
      install_generated_completion "$command_name" "$shell_name" "$target"
      ;;
  esac
}

install_all() {
  local command_name=""
  local shell_name=""
  local target=""

  while IFS=$'\t' read -r command_name shell_name target; do
    install_completion "$command_name" "$shell_name" "$target"
  done < <(completion_entries)
}

check_all() {
  local command_name=""
  local shell_name=""
  local target=""
  local errors=0

  while IFS=$'\t' read -r command_name shell_name target; do
    if [[ -s "$target" ]]; then
      printf '[ok] shell completion: %s\n' "$target"
    else
      printf '[missing] shell completion: %s\n' "$target" >&2
      errors=$((errors + 1))
    fi

    if [[ "$command_name" == bat ]] && ! check_bat_completion_source "$shell_name"; then
      errors=$((errors + 1))
    fi
  done < <(completion_entries)

  (( errors == 0 ))
}

load_completion_manifest

case "$action" in
  install)
    install_all
    ;;
  check)
    check_all
    ;;
  list)
    completion_targets
    ;;
esac
