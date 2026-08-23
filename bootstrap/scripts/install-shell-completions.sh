#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf 'Usage: %s <install|check|list> <linux|darwin>\n' "${0##*/}" >&2
}

if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

action="$1"
platform="$2"

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

bash_completion_dir="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"
zsh_completion_dir="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions"
common_commands=(uv uvx golangci-lint dlv ruff chezmoi)
bat_bash_completion_source="/usr/share/bash-completion/completions/batcat"
bat_zsh_completion_source="/usr/share/zsh/vendor-completions/_batcat"

completion_entries() {
  local command_name=""

  for command_name in "${common_commands[@]}"; do
    printf 'generated\t%s\tzsh\t%s\n' "$command_name" "$zsh_completion_dir/_$command_name"
    if [[ "$platform" == linux ]]; then
      printf 'generated\t%s\tbash\t%s\n' "$command_name" "$bash_completion_dir/$command_name.bash"
    fi
  done

  if [[ "$platform" == linux ]]; then
    printf 'generated\tmise\tzsh\t%s\n' "$zsh_completion_dir/_mise"
    printf 'generated\tmise\tbash\t%s\n' "$bash_completion_dir/mise.bash"
    printf 'bat\tbat\tzsh\t%s\n' "$zsh_completion_dir/_bat"
    printf 'bat\tbat\tbash\t%s\n' "$bash_completion_dir/bat.bash"
  fi
}

completion_targets() {
  local entry_type=""
  local command_name=""
  local shell_name=""
  local target=""

  while IFS=$'\t' read -r entry_type command_name shell_name target; do
    printf '%s\n' "$target"
  done < <(completion_entries)
}

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

install_bat_completion() {
  local shell_name="$1"
  local target="$2"
  local source_file=""
  local target_dir=""
  local temporary=""

  case "$shell_name" in
    bash)
      source_file="$bat_bash_completion_source"
      ;;
    zsh)
      source_file="$bat_zsh_completion_source"
      ;;
  esac

  if [[ ! -r "$source_file" ]]; then
    printf 'ERROR: batcat %s completion is missing: %s\n' "$shell_name" "$source_file" >&2
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

install_all() {
  local entry_type=""
  local command_name=""
  local shell_name=""
  local target=""

  while IFS=$'\t' read -r entry_type command_name shell_name target; do
    case "$entry_type" in
      generated)
        install_generated_completion "$command_name" "$shell_name" "$target"
        ;;
      bat)
        install_bat_completion "$shell_name" "$target"
        ;;
    esac
  done < <(completion_entries)
}

check_all() {
  local target=""
  local errors=0

  while IFS= read -r target; do
    if [[ -s "$target" ]]; then
      printf '[ok] shell completion: %s\n' "$target"
    else
      printf '[missing] shell completion: %s\n' "$target" >&2
      errors=$((errors + 1))
    fi
  done < <(completion_targets)

  if [[ "$platform" == linux ]]; then
    for target in "$bat_bash_completion_source" "$bat_zsh_completion_source"; do
      if [[ ! -r "$target" ]]; then
        printf '[missing] package-owned batcat completion: %s\n' "$target" >&2
        errors=$((errors + 1))
      fi
    done
    if [[ -r "$bat_bash_completion_source" ]] \
      && ! grep -Eq '^_bat[[:space:]]*\(\)' "$bat_bash_completion_source"; then
      printf '[invalid] package-owned batcat Bash completion contract: %s\n' \
        "$bat_bash_completion_source" >&2
      errors=$((errors + 1))
    fi
    if [[ -r "$bat_zsh_completion_source" \
      && "$(head -n 1 "$bat_zsh_completion_source")" != "#compdef batcat" ]]; then
      printf '[invalid] package-owned batcat Zsh completion contract: %s\n' \
        "$bat_zsh_completion_source" >&2
      errors=$((errors + 1))
    fi
  fi

  (( errors == 0 ))
}

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
