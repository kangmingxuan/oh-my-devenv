# shellcheck shell=bash
# Shared XDG directory resolution for managed Bash/Zsh and bootstrap scripts.
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

oh_my_devenv_resolve_xdg_data_home() {
  case "${XDG_DATA_HOME:-}" in
    "")
      printf '%s\n' "$HOME/.local/share"
      ;;
    /*)
      printf '%s\n' "$XDG_DATA_HOME"
      ;;
    *)
      printf 'WARNING: ignoring relative XDG_DATA_HOME=%s; using %s/.local/share\n' \
        "$XDG_DATA_HOME" "$HOME" >&2
      printf '%s\n' "$HOME/.local/share"
      ;;
  esac
}

oh_my_devenv_setup_xdg_data_home() {
  XDG_DATA_HOME="$(oh_my_devenv_resolve_xdg_data_home)"
  export XDG_DATA_HOME
}

oh_my_devenv_setup_xdg_dirs() {
  oh_my_devenv_setup_xdg_config_home
  oh_my_devenv_setup_xdg_data_home
}

oh_my_devenv_source_env_file() {
  local env_file="$1"
  local expected_xdg_config_home="$XDG_CONFIG_HOME"
  local expected_xdg_data_home="$XDG_DATA_HOME"

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

  if [[ "${XDG_DATA_HOME:-}" != "$expected_xdg_data_home" ]]; then
    XDG_DATA_HOME="$expected_xdg_data_home"
    export XDG_DATA_HOME
    printf 'ERROR: %s must not change XDG_DATA_HOME; export it before starting the shell or chezmoi\n' \
      "$env_file" >&2
    return 1
  fi
}
