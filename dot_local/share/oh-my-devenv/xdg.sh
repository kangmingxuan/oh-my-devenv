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

oh_my_devenv_source_shared_env() {
  local expected_xdg_config_home="$XDG_CONFIG_HOME"
  local shared_env="$expected_xdg_config_home/oh-my-devenv/env.sh"

  if [[ -f "$shared_env" ]]; then
    # shellcheck disable=SC1090
    source "$shared_env"
  fi

  if [[ "${XDG_CONFIG_HOME:-}" != "$expected_xdg_config_home" ]]; then
    XDG_CONFIG_HOME="$expected_xdg_config_home"
    export XDG_CONFIG_HOME
    printf 'ERROR: %s must not change XDG_CONFIG_HOME; export it before starting the shell or chezmoi\n' \
      "$shared_env" >&2
    return 1
  fi
}
