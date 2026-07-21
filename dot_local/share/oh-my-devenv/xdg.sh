# shellcheck shell=bash
# Shared XDG_CONFIG_HOME resolution for managed Bash/Zsh and bootstrap scripts.
# This file is sourced by Bash and Zsh, so keep it portable between both.

oh_my_devenv_resolve_xdg_config_home() {
  case "${XDG_CONFIG_HOME:-}" in
    "")
      printf '%s\n' "$HOME/.config"
      ;;
    /*)
      printf '%s\n' "$XDG_CONFIG_HOME"
      ;;
    *)
      printf 'WARNING: ignoring relative XDG_CONFIG_HOME=%s; using %s/.config\n' \
        "$XDG_CONFIG_HOME" "$HOME" >&2
      printf '%s\n' "$HOME/.config"
      ;;
  esac
}

oh_my_devenv_setup_xdg_config_home() {
  XDG_CONFIG_HOME="$(oh_my_devenv_resolve_xdg_config_home)"
  export XDG_CONFIG_HOME
}

oh_my_devenv_source_env_file() {
  local env_file="$1"
  local expected_xdg_config_home="$XDG_CONFIG_HOME"

  if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    source "$env_file"
  fi

  if [[ "${XDG_CONFIG_HOME:-}" != "$expected_xdg_config_home" ]]; then
    XDG_CONFIG_HOME="$expected_xdg_config_home"
    export XDG_CONFIG_HOME
    printf 'ERROR: %s must not change XDG_CONFIG_HOME; export it before starting the shell or chezmoi\n' \
      "$env_file" >&2
    return 1
  fi
}
