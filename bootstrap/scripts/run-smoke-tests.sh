#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bootstrap_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$bootstrap_dir/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Smoke tests must not inherit machine-local bootstrap settings.
export XDG_CONFIG_HOME="$tmp_dir/xdg-config-home-empty"

# shellcheck disable=SC1091
source "$script_dir/common.sh"
# shellcheck disable=SC1091
source "$script_dir/local-overlays.sh"

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'ERROR: required command not found: %s\n' "$command_name" >&2
    exit 1
  fi
}

render_template() {
  local template_path="$1"
  local output_path="$2"

  # --override-data-file injects the same fields that `.chezmoi.toml.tmpl`
  # would populate after `chezmoi init`. Without it, templates that read
  # .name / .email explode on a fresh CI runner where `chezmoi init` has
  # never run. Values are fake-but-well-formed; real users supply their
  # own at init time.
  chezmoi --source="$repo_root" \
    --override-data-file "$tmp_data_file" \
    execute-template \
    --file "$repo_root/$template_path" >"$output_path"
}

# Render .chezmoi.toml.tmpl specifically. That template uses
# `promptStringOnce`, which is only wired up under `chezmoi init` (or
# `execute-template --init`). Using render_template() on it fails with
# `function "promptStringOnce" not defined`. This helper exists so smoke
# can exercise the init template (the `[status]` exclude and the rendered
# identity block) without hacking the general renderer.
render_chezmoi_toml_tmpl() {
  local output_path="$1"

  chezmoi execute-template --init \
    --source="$repo_root" \
    --override-data-file "$tmp_data_file" \
    --file "$repo_root/.chezmoi.toml.tmpl" >"$output_path"
}

syntax_check() {
  local shell_name="$1"
  local file_path="$2"

  "$shell_name" -n "$file_path"
}

shellcheck_rendered_bash() {
  local file_path="$1"

  shellcheck -s bash -e SC1091 "$file_path"
}

fail_test() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

assert_desktop_platform_support() {
  local override_data="$1"
  local expected="$2"
  local actual=""

  actual="$(
    chezmoi --source="$repo_root" \
      --override-data "$override_data" \
      execute-template '{{ includeTemplate "desktop-platform-supported" . }}'
  )"
  if [[ "$actual" != "$expected" ]]; then
    fail_test "desktop platform detection returned '$actual'; expected '$expected' for $override_data"
  fi
}

assert_file_contains() {
  local file_path="$1"
  local expected="$2"

  if ! grep -Fq -- "$expected" "$file_path"; then
    fail_test "$file_path is missing expected content: $expected"
  fi
}

assert_file_not_contains() {
  local file_path="$1"
  local unexpected="$2"

  if grep -Fq -- "$unexpected" "$file_path"; then
    fail_test "$file_path contains unexpected content: $unexpected"
  fi
}

assert_file_matches() {
  local file_path="$1"
  local pattern="$2"

  if ! grep -Eq -- "$pattern" "$file_path"; then
    fail_test "$file_path does not match expected pattern: $pattern"
  fi
}

# Run a command that must fail and keep its stderr for follow-up assertions.
expect_failure() {
  local error_file="$1"
  shift

  if "$@" >/dev/null 2>"$error_file"; then
    fail_test "command unexpectedly succeeded: $*"
  fi
}

# Override data for synthetic desktop renders. The font family always comes
# from the desktop manifest, matching what xdg-config.sh injects at apply time.
desktop_override_data() {
  local platform_supported="$1"
  local chezmoi_data="$2"

  printf '{"desktopBaseline":true,"desktopPlatformSupported":%s,"desktopFontFamily":"%s","chezmoi":%s}' \
    "$platform_supported" "$MAPLE_MONO_FAMILY" "$chezmoi_data"
}

# Rendered hooks must call the completion installer with the host platform
# and the shared manifest.
assert_completion_hook_call() {
  local file_path="$1"
  local action="$2"

  assert_file_matches "$file_path" \
    "install-shell-completions\\.sh\" $action '(linux|darwin)' \"\\\$manifests_dir/shell/completions\\.txt\""
}

# Run the completion installer against stubbed generators and a fixture data
# directory. Globals are assigned in the completion section below.
run_completion_installer() {
  local data_home="$1"
  shift

  PATH="$completion_stub_bin:/usr/bin:/bin" XDG_DATA_HOME="$data_home" \
    bash "$completion_installer" "$@"
}

assert_toml_section_contains() {
  local file_path="$1"
  local section_name="$2"
  local expected="$3"
  local section_header="[$section_name]"

  if ! awk -v section_header="$section_header" -v expected="$expected" '
    $0 == section_header { in_section = 1; next }
    /^\[[^]]+\]/ && in_section { exit }
    in_section && index($0, expected) { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$file_path"; then
    fail_test "$file_path section [$section_name] is missing expected content: $expected"
  fi
}

check_tool_manifest_parser() {
  local manifest="$1"
  local parser_name="$2"
  local entry=""
  local command_name=""

  while IFS= read -r entry; do
    command_name="$($parser_name "$entry")"

    if [[ -z "$command_name" ]]; then
      fail_test "Failed to derive a command name from $manifest entry: $entry"
    fi
  done < <(manifest_entries "$manifest")
}

check_oh_my_zsh_manifest_contract() {
  local manifest="$1"
  local rendered_zshrc="$2"
  local entry=""
  local plugin_repo=""
  local plugin_path=""
  local extra_field=""
  local plugin_name=""

  while IFS= read -r entry; do
    read -r plugin_repo plugin_path extra_field <<<"$entry"

    if [[ -z "$plugin_repo" || -z "$plugin_path" || -n "$extra_field" ]]; then
      fail_test "Invalid oh-my-zsh plugin entry in $manifest: $entry"
    fi

    plugin_name="${plugin_path##*/}"

    if [[ "$plugin_name" == "zsh-completions" ]]; then
      assert_file_contains "$rendered_zshrc" "$plugin_path/src"
      assert_file_not_contains "$rendered_zshrc" "    zsh-completions"
      continue
    fi

    assert_file_contains "$rendered_zshrc" "    $plugin_name"
  done < <(manifest_entries "$manifest")
}

require_command chezmoi
require_command shellcheck
require_command bash
require_command git
require_command zsh
require_command sh

desktop_platform_supported_data=false
if [[ "$(chezmoi --source="$repo_root" execute-template \
  '{{ includeTemplate "desktop-platform-supported" . }}')" == "true" ]]; then
  desktop_platform_supported_data=true
fi

# Stand-in chezmoi data for template rendering. Carries two concerns at
# once:
#   - `name` / `email` mirror the shape that `.chezmoi.toml.tmpl` produces
#     after `chezmoi init`, which normal templates (dot_gitconfig, shell
#     env, etc.) read via .name / .email.
#   - `gitName` / `gitEmail` and `desktopBaseline` short-circuit the init-only
#     prompt calls in `.chezmoi.toml.tmpl` so render_chezmoi_toml_tmpl can run
#     non-interactively. Desktop rendering stays enabled in smoke tests; the
#     real apply CI explicitly disables it because hosted runners are not
#     desktop workstations.
#   - `desktopFontFamily` is what xdg-config.sh injects from the desktop font
#     manifest; the managed Ghostty and Fontconfig templates require it.
desktop_font_manifest="$repo_root/bootstrap/manifests/desktop/maple-mono-nf-cn.env"
desktop_font_manifest_load "$desktop_font_manifest"
tmp_data_file="$tmp_dir/chezmoi-data.toml"
cat >"$tmp_data_file" <<EOF
name = "Smoke Tests"
email = "smoke@example.com"
gitName = "Smoke Tests"
gitEmail = "smoke@example.com"
desktopBaseline = true
desktopPlatformSupported = $desktop_platform_supported_data
desktopFontFamily = "$MAPLE_MONO_FAMILY"
EOF

# Synthetic chezmoi platform data for boundary renders.
darwin_chezmoi_data='{"os":"darwin","osRelease":null,"kernel":null}'
supported_linux_chezmoi_data='{"os":"linux","osRelease":{"id":"ubuntu","versionID":"26.04"},"kernel":{"osrelease":"linux"}}'
unsupported_linux_chezmoi_data='{"os":"linux","osRelease":{"id":"ubuntu","versionID":"24.04"},"kernel":{"osrelease":"linux"}}'

# Literal strings asserted against rendered templates.
shared_secrets_literal="$(local_overlay_location secrets)"
env_overlay_literal="$(local_overlay_location env)"
bootstrap_overlay_literal="$(local_overlay_location bootstrap_env)"
zsh_overlay_literal="$(local_overlay_location zshrc)"
bash_overlay_literal="$(local_overlay_location bashrc)"
gitconfig_overlay_literal="$(local_overlay_location gitconfig)"
ssh_overlay_literal="$(local_overlay_location ssh_config)"
ghostty_overlay_literal="$(local_overlay_location ghostty)"
gitconfig_include_path="$(local_overlay_resolve_location "$gitconfig_overlay_literal")"
gitconfig_include_literal="path = \"$gitconfig_include_path\""
ssh_include_literal="Include ~/${ssh_overlay_literal#\$HOME/}"
ghostty_include_literal="config-file = ?${ghostty_overlay_literal##*/}"
# shellcheck disable=SC2016
xdg_source_literal='source "$HOME/.local/share/oh-my-devenv/xdg.sh"'
# shellcheck disable=SC2016
xdg_apply_literal='bash "$scripts_dir/xdg-config.sh" apply "$config_file"'
# shellcheck disable=SC2016
xdg_persistent_state_literal='--persistent-state="$xdg_persistent_state"'

log_step "🧪" "Running local smoke tests..."

log_step "📂" "Checking XDG directory resolution..."
xdg_resolver="$repo_root/dot_local/share/oh-my-devenv/xdg.sh"
syntax_check bash "$xdg_resolver"
syntax_check zsh "$xdg_resolver"
shellcheck -s bash "$xdg_resolver"
# shellcheck disable=SC2016
resolve_xdg_command='source "$1"; oh_my_devenv_setup_xdg_config_home; printf "%s\n" "$XDG_CONFIG_HOME"'

default_xdg="$(env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/home" \
  bash -c "$resolve_xdg_command" \
  _ "$xdg_resolver")"
if [[ "$default_xdg" != "$tmp_dir/home/.config" ]]; then
  fail_test "unset XDG_CONFIG_HOME resolved to '$default_xdg'"
fi

empty_xdg="$(env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/home" XDG_CONFIG_HOME="" \
  bash -c "$resolve_xdg_command" \
  _ "$xdg_resolver")"
if [[ "$empty_xdg" != "$tmp_dir/home/.config" ]]; then
  fail_test "empty XDG_CONFIG_HOME resolved to '$empty_xdg'"
fi

custom_xdg="$(env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/home" \
  XDG_CONFIG_HOME="$tmp_dir/custom-config" \
  bash -c "$resolve_xdg_command" \
  _ "$xdg_resolver")"
if [[ "$custom_xdg" != "$tmp_dir/custom-config" ]]; then
  fail_test "absolute XDG_CONFIG_HOME resolved to '$custom_xdg'"
fi

relative_xdg="$(env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/home" \
  XDG_CONFIG_HOME="relative/config" \
  bash -c "$resolve_xdg_command" \
  _ "$xdg_resolver" 2>"$tmp_dir/relative-xdg.err")"
if [[ "$relative_xdg" != "$tmp_dir/home/.config" ]]; then
  fail_test "relative XDG_CONFIG_HOME resolved to '$relative_xdg'"
fi
assert_file_contains "$tmp_dir/relative-xdg.err" "ignoring relative XDG_CONFIG_HOME=relative/config"

# shellcheck disable=SC2016
resolve_xdg_data_command='source "$1"; oh_my_devenv_setup_xdg_data_home; printf "%s\n" "$XDG_DATA_HOME"'
default_xdg_data="$(env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/home" \
  bash -c "$resolve_xdg_data_command" _ "$xdg_resolver")"
if [[ "$default_xdg_data" != "$tmp_dir/home/.local/share" ]]; then
  fail_test "unset XDG_DATA_HOME resolved to '$default_xdg_data'"
fi
relative_xdg_data="$(env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/home" XDG_DATA_HOME="relative/data" \
  bash -c "$resolve_xdg_data_command" _ "$xdg_resolver" 2>"$tmp_dir/relative-xdg-data.err")"
if [[ "$relative_xdg_data" != "$tmp_dir/home/.local/share" ]]; then
  fail_test "relative XDG_DATA_HOME resolved to '$relative_xdg_data'"
fi
assert_file_contains "$tmp_dir/relative-xdg-data.err" "ignoring relative XDG_DATA_HOME=relative/data"

mkdir -p "$tmp_dir/env-boundary/oh-my-devenv"
printf '%s\n' 'export OH_MY_DEVENV_SMOKE_SHELL=loaded' >"$tmp_dir/env-boundary/oh-my-devenv/env.sh"
printf '%s\n' 'export OH_MY_DEVENV_SMOKE_BOOTSTRAP=loaded' >"$tmp_dir/env-boundary/oh-my-devenv/bootstrap.env"
# shellcheck disable=SC2016
source_env_command='source "$1"; oh_my_devenv_setup_xdg_dirs; oh_my_devenv_source_env_file "$XDG_CONFIG_HOME/oh-my-devenv/env.sh"; printf "%s:%s\n" "${OH_MY_DEVENV_SMOKE_SHELL:-unset}" "${OH_MY_DEVENV_SMOKE_BOOTSTRAP:-unset}"'
loaded_env="$(env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/home" XDG_CONFIG_HOME="$tmp_dir/env-boundary" \
  bash -c "$source_env_command" \
  _ "$xdg_resolver")"
if [[ "$loaded_env" != "loaded:unset" ]]; then
  fail_test "shell env consumer boundary returned '$loaded_env'"
fi

# shellcheck disable=SC2016
source_bootstrap_command='source "$1"; printf "%s:%s\n" "${OH_MY_DEVENV_SMOKE_SHELL:-unset}" "${OH_MY_DEVENV_SMOKE_BOOTSTRAP:-unset}"'
loaded_bootstrap="$(env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/home" XDG_CONFIG_HOME="$tmp_dir/env-boundary" \
  bash -c "$source_bootstrap_command" \
  _ "$repo_root/bootstrap/scripts/common.sh")"
if [[ "$loaded_bootstrap" != "unset:loaded" ]]; then
  fail_test "bootstrap env consumer boundary returned '$loaded_bootstrap'"
fi

for guarded_env_name in env.sh bootstrap.env; do
  guarded_env_root="$tmp_dir/$guarded_env_name-must-not-move-xdg"
  mkdir -p "$guarded_env_root/oh-my-devenv"
  printf '%s\n' 'unset XDG_CONFIG_HOME' >"$guarded_env_root/oh-my-devenv/$guarded_env_name"
  # shellcheck disable=SC2016
  source_moving_env_command='source "$1"; oh_my_devenv_setup_xdg_dirs; if oh_my_devenv_source_env_file "$XDG_CONFIG_HOME/oh-my-devenv/$2"; then exit 1; fi; printf "%s\n" "$XDG_CONFIG_HOME"'
  restored_xdg="$(XDG_CONFIG_HOME="$guarded_env_root" \
    bash -c "$source_moving_env_command" \
    _ "$xdg_resolver" "$guarded_env_name" 2>"$tmp_dir/$guarded_env_name-moved-xdg.err")"
  if [[ "$restored_xdg" != "$guarded_env_root" ]]; then
    fail_test "$guarded_env_name changed XDG_CONFIG_HOME to '$restored_xdg' despite the guard"
  fi
  assert_file_contains "$tmp_dir/$guarded_env_name-moved-xdg.err" "must not change XDG_CONFIG_HOME"
done

log_step "📝" "Rendering and checking shell templates..."
render_template dot_zshrc.tmpl "$tmp_dir/dot_zshrc"
syntax_check zsh "$tmp_dir/dot_zshrc"
assert_file_contains "$tmp_dir/dot_zshrc" "$shared_secrets_literal"
assert_file_contains "$tmp_dir/dot_zshrc" "$zsh_overlay_literal"
# shellcheck disable=SC2016
user_fpath_line="$(grep -nF 'fpath=("$XDG_DATA_HOME/zsh/site-functions" $fpath)' "$tmp_dir/dot_zshrc" | cut -d: -f1)"
fallback_fpath_line="$(grep -nF 'zsh-completions/src' "$tmp_dir/dot_zshrc" | cut -d: -f1)"
# shellcheck disable=SC2016
omz_source_line="$(grep -nF 'source "$ZSH/oh-my-zsh.sh"' "$tmp_dir/dot_zshrc" | cut -d: -f1)"
if [[ -z "$user_fpath_line" || -z "$fallback_fpath_line" || -z "$omz_source_line" \
  || "$user_fpath_line" -ge "$fallback_fpath_line" || "$fallback_fpath_line" -ge "$omz_source_line" ]]; then
  fail_test "Zsh completion fpath precedence must be user, system/oh-my-zsh, then zsh-completions fallback"
fi
synthetic_macos_zshrc="$tmp_dir/dot_zshrc.macos"
chezmoi --source="$repo_root" \
  --override-data '{"chezmoi":{"os":"darwin","osRelease":null,"kernel":null}}' \
  execute-template --file "$repo_root/dot_zshrc.tmpl" >"$synthetic_macos_zshrc"
syntax_check zsh "$synthetic_macos_zshrc"
# shellcheck disable=SC2016
assert_file_contains "$synthetic_macos_zshrc" 'fpath+=("$HOMEBREW_PREFIX/share/zsh/site-functions")'

render_template dot_zprofile.tmpl "$tmp_dir/dot_zprofile"
syntax_check zsh "$tmp_dir/dot_zprofile"

render_template dot_zsh/env.zsh.tmpl "$tmp_dir/env.zsh"
syntax_check zsh "$tmp_dir/env.zsh"
assert_file_contains "$tmp_dir/env.zsh" "$xdg_source_literal"
assert_file_contains "$tmp_dir/env.zsh" "oh_my_devenv_setup_xdg_dirs"
assert_file_contains "$tmp_dir/env.zsh" "oh_my_devenv_source_env_file"
assert_file_contains "$tmp_dir/env.zsh" "$env_overlay_literal"
assert_file_not_contains "$tmp_dir/env.zsh" "$bootstrap_overlay_literal"
assert_file_not_contains "$tmp_dir/env.zsh" "$shared_secrets_literal"
assert_file_not_contains "$tmp_dir/env.zsh" "$zsh_overlay_literal"

render_template dot_bashrc.tmpl "$tmp_dir/dot_bashrc"
syntax_check bash "$tmp_dir/dot_bashrc"
shellcheck_rendered_bash "$tmp_dir/dot_bashrc"
assert_file_contains "$tmp_dir/dot_bashrc" "$shared_secrets_literal"
assert_file_contains "$tmp_dir/dot_bashrc" "$bash_overlay_literal"

render_template dot_bash/env.bash.tmpl "$tmp_dir/env.bash"
syntax_check bash "$tmp_dir/env.bash"
shellcheck_rendered_bash "$tmp_dir/env.bash"
assert_file_contains "$tmp_dir/env.bash" "$xdg_source_literal"
assert_file_contains "$tmp_dir/env.bash" "oh_my_devenv_setup_xdg_dirs"
assert_file_contains "$tmp_dir/env.bash" "oh_my_devenv_source_env_file"
assert_file_contains "$tmp_dir/env.bash" "$env_overlay_literal"
assert_file_not_contains "$tmp_dir/env.bash" "$bootstrap_overlay_literal"
assert_file_not_contains "$tmp_dir/env.bash" "$shared_secrets_literal"
assert_file_not_contains "$tmp_dir/env.bash" "$bash_overlay_literal"

syntax_check sh "$repo_root/dot_profile"

render_template dot_gitconfig.tmpl "$tmp_dir/dot_gitconfig"
assert_file_contains "$tmp_dir/dot_gitconfig" "$gitconfig_include_literal"
# The managed gitconfig must stay host-neutral: no hard-coded URL rewrites, so
# the baseline carries no organization-specific Git routing.
assert_file_not_contains "$tmp_dir/dot_gitconfig" 'insteadOf'

render_template private_dot_ssh/private_config.tmpl "$tmp_dir/private_dot_ssh_config"
assert_file_contains "$tmp_dir/private_dot_ssh_config" "$ssh_include_literal"
assert_file_contains "$repo_root/bootstrap/scripts/common.sh" "oh_my_devenv_setup_xdg_dirs"
assert_file_contains "$repo_root/bootstrap/scripts/common.sh" "oh_my_devenv_source_env_file"
assert_file_contains "$repo_root/bootstrap/scripts/common.sh" "$bootstrap_overlay_literal"
assert_file_not_contains "$repo_root/bootstrap/scripts/common.sh" "$env_overlay_literal"
assert_file_not_contains "$repo_root/bootstrap/scripts/common.sh" "$shared_secrets_literal"

log_step "📜" "Rendering and checking chezmoi bootstrap scripts..."
render_template .chezmoiscripts/run_once_before_10-bootstrap.sh.tmpl "$tmp_dir/run_once_before_10-bootstrap.sh"
syntax_check bash "$tmp_dir/run_once_before_10-bootstrap.sh"
shellcheck_rendered_bash "$tmp_dir/run_once_before_10-bootstrap.sh"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "backup_existing_managed_configs()"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "chezmoi-first-run-backup"
# Every file the main source manages under HOME must be backed up before the
# first apply overwrites it. The nested XDG files are checked after the
# fixture apply below, once their inventory is known.
main_managed_relative="$(chezmoi --source="$repo_root" --override-data-file "$tmp_data_file" \
  managed --include=files,symlinks --path-style=relative)"
if [[ -z "$main_managed_relative" ]]; then
  fail_test "main chezmoi source manages no files"
fi
while IFS= read -r managed_relative; do
  assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "\"$managed_relative|\$HOME/$managed_relative\""
done <<<"$main_managed_relative"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "cp -Lp \"\$existing_path\" \"\$backup_path\""
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "install_error_trap"

render_template .chezmoiscripts/run_after_35-apply-xdg-config.sh.tmpl "$tmp_dir/run_after_35-apply-xdg-config.sh"
syntax_check bash "$tmp_dir/run_after_35-apply-xdg-config.sh"
shellcheck_rendered_bash "$tmp_dir/run_after_35-apply-xdg-config.sh"
assert_file_contains "$tmp_dir/run_after_35-apply-xdg-config.sh" "$xdg_apply_literal"
assert_file_contains "$repo_root/bootstrap/scripts/xdg-config.sh" "$xdg_persistent_state_literal"

render_template .chezmoiscripts/run_onchange_after_20-install-system-packages.sh.tmpl "$tmp_dir/run_onchange_after_20-install-system-packages.sh"
syntax_check bash "$tmp_dir/run_onchange_after_20-install-system-packages.sh"
shellcheck_rendered_bash "$tmp_dir/run_onchange_after_20-install-system-packages.sh"
assert_file_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "install_error_trap"
if grep -Fq "install-brew-packages.sh" "$tmp_dir/run_onchange_after_20-install-system-packages.sh"; then
  assert_file_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "\"\$manifests_dir/system/Brewfile\""
  assert_file_not_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "install-apt-packages.sh"
else
  assert_file_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "install-apt-packages.sh"
  assert_file_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "\"\$manifests_dir/system/apt-packages.txt\""
fi

render_template .chezmoiscripts/run_onchange_after_22-install-desktop-assets.sh.tmpl "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh"
syntax_check bash "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh"
shellcheck_rendered_bash "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh"
assert_file_contains "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh" "install_error_trap"
desktop_platform_supported=0
linux_fontconfig_alias_enabled=0
if grep -Fq "install-brew-packages.sh" "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh"; then
  desktop_platform_supported=1
  assert_file_contains "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh" 'manifests_dir/desktop/Brewfile'
elif grep -Fq "install-maple-mono-font.sh" "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh"; then
  desktop_platform_supported=1
  linux_fontconfig_alias_enabled=1
  assert_file_contains "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh" 'install-apt-packages.sh'
  assert_file_contains "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh" 'manifests_dir/desktop/apt-packages.txt'
  assert_file_contains "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh" 'manifests_dir/desktop/maple-mono-nf-cn.env'
else
  assert_file_contains "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh" "log_warning"
  assert_file_not_contains "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh" 'manifests_dir='
fi

unsupported_desktop_hook="$tmp_dir/run_onchange_after_22-install-desktop-assets.unsupported-linux.sh"
chezmoi --source="$repo_root" \
  --override-data "{\"desktopBaseline\":true,\"chezmoi\":$unsupported_linux_chezmoi_data}" \
  execute-template \
  --file "$repo_root/.chezmoiscripts/run_onchange_after_22-install-desktop-assets.sh.tmpl" \
  >"$unsupported_desktop_hook"
syntax_check bash "$unsupported_desktop_hook"
shellcheck_rendered_bash "$unsupported_desktop_hook"
# An unsupported platform must warn and must not reach any installer.
assert_file_contains "$unsupported_desktop_hook" "log_warning"
assert_file_not_contains "$unsupported_desktop_hook" 'manifests_dir='
# shellcheck disable=SC2016
assert_file_not_contains "$unsupported_desktop_hook" '$scripts_dir/install-'

render_template xdg_config/ghostty/config.ghostty.tmpl "$tmp_dir/config.ghostty"
if (( desktop_platform_supported == 1 )); then
  assert_file_contains "$tmp_dir/config.ghostty" "font-family = $MAPLE_MONO_FAMILY"
  assert_file_contains "$tmp_dir/config.ghostty" "$ghostty_include_literal"
elif [[ -s "$tmp_dir/config.ghostty" ]]; then
  fail_test "Ghostty config must render zero bytes on unsupported platforms"
fi

render_template \
  xdg_config/fontconfig/conf.d/99-oh-my-devenv-maple-mono-nf-cn.conf.tmpl \
  "$tmp_dir/99-oh-my-devenv-maple-mono-nf-cn.conf"
assert_file_contains "$tmp_dir/99-oh-my-devenv-maple-mono-nf-cn.conf" '<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">'
assert_file_contains "$tmp_dir/99-oh-my-devenv-maple-mono-nf-cn.conf" "<fontconfig>"
assert_file_contains "$tmp_dir/99-oh-my-devenv-maple-mono-nf-cn.conf" "</fontconfig>"
if (( linux_fontconfig_alias_enabled == 1 )); then
  assert_file_contains "$tmp_dir/99-oh-my-devenv-maple-mono-nf-cn.conf" '<edit name="family" mode="prepend" binding="strong">'
  assert_file_contains "$tmp_dir/99-oh-my-devenv-maple-mono-nf-cn.conf" "<string>$MAPLE_MONO_FAMILY</string>"
else
  assert_file_not_contains "$tmp_dir/99-oh-my-devenv-maple-mono-nf-cn.conf" 'binding="strong"'
  assert_file_not_contains "$tmp_dir/99-oh-my-devenv-maple-mono-nf-cn.conf" "$MAPLE_MONO_FAMILY"
fi

disabled_desktop_hook="$tmp_dir/run_onchange_after_22-install-desktop-assets.disabled"
disabled_ghostty_config="$tmp_dir/config.ghostty.disabled"
disabled_fontconfig_fragment="$tmp_dir/99-oh-my-devenv-maple-mono-nf-cn.disabled.conf"
chezmoi --source="$repo_root" \
  --override-data '{"desktopBaseline":false}' \
  execute-template \
  --file "$repo_root/.chezmoiscripts/run_onchange_after_22-install-desktop-assets.sh.tmpl" \
  >"$disabled_desktop_hook"
chezmoi --source="$repo_root" \
  --override-data '{"desktopBaseline":false}' \
  execute-template \
  --file "$repo_root/xdg_config/ghostty/config.ghostty.tmpl" \
  >"$disabled_ghostty_config"
chezmoi --source="$repo_root" \
  --override-data '{"desktopBaseline":false}' \
  execute-template \
  --file "$repo_root/xdg_config/fontconfig/conf.d/99-oh-my-devenv-maple-mono-nf-cn.conf.tmpl" \
  >"$disabled_fontconfig_fragment"
if [[ -s "$disabled_desktop_hook" || -s "$disabled_ghostty_config" ]]; then
  fail_test "desktop templates must render zero bytes when desktopBaseline is disabled"
fi
assert_file_contains "$disabled_fontconfig_fragment" "<fontconfig>"
assert_file_not_contains "$disabled_fontconfig_fragment" 'binding="strong"'
assert_file_not_contains "$disabled_fontconfig_fragment" "$MAPLE_MONO_FAMILY"

render_template .chezmoiscripts/run_onchange_after_25-install-shell-assets.sh.tmpl "$tmp_dir/run_onchange_after_25-install-shell-assets.sh"
syntax_check bash "$tmp_dir/run_onchange_after_25-install-shell-assets.sh"
shellcheck_rendered_bash "$tmp_dir/run_onchange_after_25-install-shell-assets.sh"
assert_file_contains "$tmp_dir/run_onchange_after_25-install-shell-assets.sh" "install_error_trap"

render_template .chezmoiscripts/run_onchange_after_30-install-mise.sh.tmpl "$tmp_dir/run_onchange_after_30-install-mise.sh"
syntax_check bash "$tmp_dir/run_onchange_after_30-install-mise.sh"
shellcheck_rendered_bash "$tmp_dir/run_onchange_after_30-install-mise.sh"
assert_file_contains "$tmp_dir/run_onchange_after_30-install-mise.sh" "install_error_trap"

render_template .chezmoiscripts/run_onchange_after_40-install-runtimes.sh.tmpl "$tmp_dir/run_onchange_after_40-install-runtimes.sh"
syntax_check bash "$tmp_dir/run_onchange_after_40-install-runtimes.sh"
shellcheck_rendered_bash "$tmp_dir/run_onchange_after_40-install-runtimes.sh"
assert_file_contains "$tmp_dir/run_onchange_after_40-install-runtimes.sh" "install_error_trap"
# Attestation switches must honor a caller-provided value; the default itself
# is configuration owned by the hook.
assert_file_matches "$tmp_dir/run_onchange_after_40-install-runtimes.sh" \
  '^export MISE_GITHUB_ATTESTATIONS="\$\{MISE_GITHUB_ATTESTATIONS:-'
assert_file_matches "$tmp_dir/run_onchange_after_40-install-runtimes.sh" \
  '^export MISE_AQUA_GITHUB_ATTESTATIONS="\$\{MISE_AQUA_GITHUB_ATTESTATIONS:-'
# shellcheck disable=SC2016
assert_file_matches "$tmp_dir/run_onchange_after_40-install-runtimes.sh" \
  '^export MISE_PYTHON_GITHUB_ATTESTATIONS="\$\{MISE_PYTHON_GITHUB_ATTESTATIONS:-\$MISE_GITHUB_ATTESTATIONS\}"'
assert_file_contains "$tmp_dir/run_onchange_after_40-install-runtimes.sh" "mise install --yes"

render_template .chezmoiscripts/run_onchange_after_50-sync-ecosystem-tools.sh.tmpl "$tmp_dir/run_onchange_after_50-sync-ecosystem-tools.sh"
syntax_check bash "$tmp_dir/run_onchange_after_50-sync-ecosystem-tools.sh"
shellcheck_rendered_bash "$tmp_dir/run_onchange_after_50-sync-ecosystem-tools.sh"
assert_file_contains "$tmp_dir/run_onchange_after_50-sync-ecosystem-tools.sh" "install_error_trap"

render_template .chezmoiscripts/run_onchange_after_55-install-shell-completions.sh.tmpl "$tmp_dir/run_onchange_after_55-install-shell-completions.sh"
syntax_check bash "$tmp_dir/run_onchange_after_55-install-shell-completions.sh"
shellcheck_rendered_bash "$tmp_dir/run_onchange_after_55-install-shell-completions.sh"
assert_completion_hook_call "$tmp_dir/run_onchange_after_55-install-shell-completions.sh" install

log_step "🧩" "Testing generated shell completion assets..."
completion_installer="$repo_root/bootstrap/scripts/install-shell-completions.sh"
completion_manifest="$repo_root/bootstrap/manifests/shell/completions.txt"
completion_stub_bin="$tmp_dir/completion-stub-bin"
completion_linux_data="$tmp_dir/completion-linux-data"
completion_macos_data="$tmp_dir/completion-macos-data"
mkdir -p "$completion_stub_bin"
cat >"$completion_stub_bin/completion-generator" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command_name="${0##*/}"
shell_name="${2:-}"
if [[ "${FAIL_COMPLETION_FOR:-}" == "$command_name" ]]; then
  exit 1
fi
if [[ "$shell_name" == zsh ]]; then
  printf '#compdef %s\n_arguments "*:value:((stub))"\n' "$command_name"
else
  function_name="${command_name//-/_}_completion"
  printf '%s() { COMPREPLY=(stub); }\ncomplete -F %s %s\n' \
    "$function_name" "$function_name" "$command_name"
fi
EOF
chmod +x "$completion_stub_bin/completion-generator"
# Stub every command the production manifest lists. A command without a
# generator adapter fails the install below, which is the documented contract.
production_completion_commands="$(manifest_entries "$completion_manifest" | awk '{ print $1 }')"
if [[ -z "$production_completion_commands" ]]; then
  fail_test "completion manifest declares no commands"
fi
while IFS= read -r completion_command; do
  ln -s completion-generator "$completion_stub_bin/$completion_command"
done <<<"$production_completion_commands"

# `list` names every asset a platform manages under XDG_DATA_HOME. Linux owns
# Bash and Zsh assets; macOS stays Zsh-only.
completion_list_data="$tmp_dir/completion-list-data"
for completion_platform in linux darwin; do
  completion_listing="$(run_completion_installer "$completion_list_data" \
    list "$completion_platform" "$completion_manifest")"
  if [[ -z "$completion_listing" ]]; then
    fail_test "completion manifest lists no commands for $completion_platform"
  fi
  while IFS= read -r completion_target; do
    case "$completion_target" in
      "$completion_list_data/zsh/site-functions/_"*) ;;
      "$completion_list_data/bash-completion/completions/"*.bash)
        [[ "$completion_platform" == linux ]] \
          || fail_test "macOS completion inventory must stay Zsh-only: $completion_target"
        ;;
      *) fail_test "unexpected completion target for $completion_platform: $completion_target" ;;
    esac
  done <<<"$completion_listing"
done

# The Linux inventory may wrap Debian package-owned batcat completions, so the
# production Linux install runs only where those files can exist.
if [[ "$(uname -s)" != Darwin ]]; then
  run_completion_installer "$completion_linux_data" install linux "$completion_manifest"
  run_completion_installer "$completion_linux_data" check linux "$completion_manifest"
  linux_completion_listing="$(run_completion_installer "$completion_linux_data" list linux "$completion_manifest")"
  while IFS= read -r completion_target; do
    [[ -s "$completion_target" ]] || fail_test "missing Linux completion asset: $completion_target"
  done <<<"$linux_completion_listing"
  if grep -Fxq bat <<<"$production_completion_commands"; then
    assert_file_contains "$completion_linux_data/bash-completion/completions/bat.bash" "complete -F _bat bat"
    assert_file_contains "$completion_linux_data/zsh/site-functions/_bat" "#compdef bat"
  fi
fi

run_completion_installer "$completion_macos_data" install darwin "$completion_manifest"
run_completion_installer "$completion_macos_data" check darwin "$completion_manifest"
macos_completion_listing="$(run_completion_installer "$completion_macos_data" list darwin "$completion_manifest" | sort)"
macos_installed_files="$(find "$completion_macos_data" -type f | sort)"
if [[ "$macos_installed_files" != "$macos_completion_listing" ]]; then
  fail_test "macOS completion install must create exactly the listed targets; got: $macos_installed_files"
fi
if run_completion_installer "$tmp_dir/completion-empty-data" check darwin "$completion_manifest" >/dev/null 2>&1; then
  fail_test "completion check must fail while the listed assets are missing"
fi

# A synthetic manifest exercises platform membership, adapters, and failure
# handling independently of the commands the baseline currently selects.
synthetic_completion_manifest="$tmp_dir/completions.synthetic.txt"
synthetic_completion_data="$tmp_dir/completion-synthetic-data"
cat >"$synthetic_completion_manifest" <<'EOF'
# command   platforms
uv          linux,darwin
ruff        linux
chezmoi     darwin
EOF
# Stub the synthetic commands from that manifest's own rows so this fixture
# stays independent of what the production manifest currently selects.
while IFS= read -r completion_command; do
  if [[ ! -e "$completion_stub_bin/$completion_command" ]]; then
    ln -s completion-generator "$completion_stub_bin/$completion_command"
  fi
done <<<"$(manifest_entries "$synthetic_completion_manifest" | awk '{ print $1 }')"
synthetic_darwin_listing="$(run_completion_installer "$synthetic_completion_data" list darwin "$synthetic_completion_manifest")"
expected_darwin_listing="$synthetic_completion_data/zsh/site-functions/_uv
$synthetic_completion_data/zsh/site-functions/_chezmoi"
if [[ "$synthetic_darwin_listing" != "$expected_darwin_listing" ]]; then
  fail_test "synthetic darwin completion inventory was: $synthetic_darwin_listing"
fi
synthetic_linux_listing="$(run_completion_installer "$synthetic_completion_data" list linux "$synthetic_completion_manifest")"
expected_linux_listing="$synthetic_completion_data/zsh/site-functions/_uv
$synthetic_completion_data/bash-completion/completions/uv.bash
$synthetic_completion_data/zsh/site-functions/_ruff
$synthetic_completion_data/bash-completion/completions/ruff.bash"
if [[ "$synthetic_linux_listing" != "$expected_linux_listing" ]]; then
  fail_test "synthetic linux completion inventory was: $synthetic_linux_listing"
fi

run_completion_installer "$synthetic_completion_data" install linux "$synthetic_completion_manifest"
run_completion_installer "$synthetic_completion_data" check linux "$synthetic_completion_manifest"
while IFS= read -r completion_target; do
  [[ -s "$completion_target" ]] || fail_test "missing synthetic completion asset: $completion_target"
done <<<"$synthetic_linux_listing"
if [[ -e "$synthetic_completion_data/zsh/site-functions/_chezmoi" ]]; then
  fail_test "linux completion install generated an asset the manifest reserves for darwin"
fi
if [[ "$(uname -s)" == Darwin ]]; then
  synthetic_completion_mode="$(stat -f '%Lp' "$synthetic_completion_data/zsh/site-functions/_uv")"
else
  synthetic_completion_mode="$(stat -c '%a' "$synthetic_completion_data/zsh/site-functions/_uv")"
fi
if [[ "$synthetic_completion_mode" != 644 ]]; then
  fail_test "generated completion assets must be installed with mode 0644 (got $synthetic_completion_mode)"
fi
bash -c 'source "$1"; complete -p ruff' \
  _ "$synthetic_completion_data/bash-completion/completions/ruff.bash" >/dev/null
zsh -fc 'fpath=("$1" ${fpath:#/usr/share/zsh/vendor-completions}); autoload -Uz compinit; compinit -D -i; [[ "${_comps[uv]}" == _uv ]]' \
  _ "$synthetic_completion_data/zsh/site-functions"

# A failing generator must not replace the previous valid asset or leave
# temporary files behind.
printf '%s\n' preserved >"$synthetic_completion_data/zsh/site-functions/_uv"
if PATH="$completion_stub_bin:/usr/bin:/bin" XDG_DATA_HOME="$synthetic_completion_data" FAIL_COMPLETION_FOR=uv \
  bash "$completion_installer" install darwin "$synthetic_completion_manifest" >/dev/null 2>&1; then
  fail_test "completion installation must fail when a generator fails"
fi
if [[ "$(<"$synthetic_completion_data/zsh/site-functions/_uv")" != preserved ]]; then
  fail_test "failed completion generation replaced the previous valid asset"
fi
if find "$synthetic_completion_data" -name '*.tmp.*' | grep -q .; then
  fail_test "failed completion generation left temporary files behind"
fi

# A failure inside the marker step happens after the generated temp exists and
# a second marked temp was created; the installer's EXIT trap must remove both
# and leave the previous asset alone. `tail` is stubbed to fail only for this
# run because the marker step uses it to copy the body after `#compdef`. The
# stub fails only for the expected `tail -n +2 <file>` call and prints a unique
# marker, so the assertions below prove the run actually reached that step; any
# other invocation is reported distinctly.
completion_failing_tail_bin="$tmp_dir/completion-failing-tail-bin"
completion_marker_failure_log="$tmp_dir/completion-marker-failure.log"
mkdir -p "$completion_failing_tail_bin"
cat >"$completion_failing_tail_bin/tail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -eq 3 && "$1" == "-n" && "$2" == "+2" ]]; then
  printf 'smoke-marker-copy-failure\n' >&2
  exit 1
fi
printf 'unexpected tail invocation in marker-failure fixture: %s\n' "$*" >&2
exit 2
EOF
chmod +x "$completion_failing_tail_bin/tail"
if PATH="$completion_failing_tail_bin:$completion_stub_bin:/usr/bin:/bin" XDG_DATA_HOME="$synthetic_completion_data" \
  bash "$completion_installer" install darwin "$synthetic_completion_manifest" >"$completion_marker_failure_log" 2>&1; then
  fail_test "completion installation must fail when the marker step fails"
fi
assert_file_not_contains "$completion_marker_failure_log" "unexpected tail invocation in marker-failure fixture"
assert_file_contains "$completion_marker_failure_log" "smoke-marker-copy-failure"
if [[ "$(<"$synthetic_completion_data/zsh/site-functions/_uv")" != preserved ]]; then
  fail_test "failed completion marker step replaced the previous valid asset"
fi
if find "$synthetic_completion_data" -name '*.tmp.*' | grep -q .; then
  fail_test "failed completion marker step left temporary files behind"
fi

# Argument and manifest validation.
completion_errors="$tmp_dir/completion.err"
expect_failure "$completion_errors" run_completion_installer "$synthetic_completion_data" install darwin
assert_file_contains "$completion_errors" "Usage:"
expect_failure "$completion_errors" run_completion_installer "$synthetic_completion_data" \
  install plan9 "$synthetic_completion_manifest"
assert_file_contains "$completion_errors" "Usage:"
expect_failure "$completion_errors" run_completion_installer "$synthetic_completion_data" \
  list darwin "$tmp_dir/missing-completions.txt"
assert_file_contains "$completion_errors" "completion manifest not found"
invalid_completion_manifest="$tmp_dir/completions.invalid.txt"
while IFS='|' read -r invalid_rows expected_error; do
  printf '%b\n' "$invalid_rows" >"$invalid_completion_manifest"
  expect_failure "$completion_errors" run_completion_installer "$synthetic_completion_data" \
    list linux "$invalid_completion_manifest"
  assert_file_contains "$completion_errors" "$expected_error"
done <<'EOF'
uv|must be "<command> <platforms>"
uv linux extra|must be "<command> <platforms>"
uv plan9|unsupported completion platform
uv linux\nuv darwin|duplicate completion command
/bin/uv linux|invalid completion command name
EOF
# A manifest command without a generator adapter lists fine but cannot install.
printf '%s\n' 'no-adapter linux' >"$invalid_completion_manifest"
ln -s completion-generator "$completion_stub_bin/no-adapter"
run_completion_installer "$synthetic_completion_data" list linux "$invalid_completion_manifest" >/dev/null
expect_failure "$completion_errors" run_completion_installer "$synthetic_completion_data" \
  install linux "$invalid_completion_manifest"
assert_file_contains "$completion_errors" "unsupported completion generator: no-adapter"

# Reconciliation: files this installer wrote for commands that later left the
# manifest or this platform are pruned only after every current entry installs,
# while unmarked files and symlinks in the same directories are left alone.
reconcile_completion_manifest="$tmp_dir/completions.reconcile.txt"
reconcile_completion_data="$tmp_dir/completion-reconcile-data"
reconcile_zsh_dir="$reconcile_completion_data/zsh/site-functions"
reconcile_bash_dir="$reconcile_completion_data/bash-completion/completions"
cat >"$reconcile_completion_manifest" <<'EOF'
uv          linux,darwin
ruff        linux,darwin
chezmoi     linux,darwin
EOF
while IFS= read -r completion_command; do
  if [[ ! -e "$completion_stub_bin/$completion_command" ]]; then
    ln -s completion-generator "$completion_stub_bin/$completion_command"
  fi
done <<<"$(manifest_entries "$reconcile_completion_manifest" | awk '{ print $1 }')"
run_completion_installer "$reconcile_completion_data" install linux "$reconcile_completion_manifest"
if [[ "$(head -n 1 "$reconcile_zsh_dir/_uv")" != "#compdef uv" ]]; then
  fail_test "ownership marker must not displace the #compdef line of generated Zsh completions"
fi
# Unrelated neighbors: an unmarked user file per directory, and a symlink to an
# owned-looking file the installer must neither follow nor delete.
printf '#compdef custom\n' >"$reconcile_zsh_dir/_custom"
printf 'complete -W stub custom\n' >"$reconcile_bash_dir/custom.bash"
cp "$reconcile_zsh_dir/_ruff" "$tmp_dir/completion-linked-owned"
ln -s "$tmp_dir/completion-linked-owned" "$reconcile_zsh_dir/_linked"

# ruff leaves the linux platform and chezmoi leaves the manifest entirely.
cat >"$reconcile_completion_manifest" <<'EOF'
uv          linux,darwin
ruff        darwin
EOF
reconcile_current_targets="$reconcile_zsh_dir/_uv
$reconcile_bash_dir/uv.bash"
reconcile_obsolete_targets="$reconcile_zsh_dir/_ruff
$reconcile_bash_dir/ruff.bash
$reconcile_zsh_dir/_chezmoi
$reconcile_bash_dir/chezmoi.bash"
expect_failure "$completion_errors" run_completion_installer "$reconcile_completion_data" \
  check linux "$reconcile_completion_manifest"
while IFS= read -r completion_target; do
  assert_file_contains "$completion_errors" "[stale] shell completion: $completion_target"
done <<<"$reconcile_obsolete_targets"
reconcile_listing="$(run_completion_installer "$reconcile_completion_data" \
  list linux "$reconcile_completion_manifest" | sort)"
expected_reconcile_listing="$(printf '%s\n%s\n' "$reconcile_current_targets" "$reconcile_obsolete_targets" | sort)"
if [[ "$reconcile_listing" != "$expected_reconcile_listing" ]]; then
  fail_test "completion list must include obsolete owned files before reinstall; got: $reconcile_listing"
fi
# A failing current entry must leave the obsolete files for the next attempt.
if PATH="$completion_stub_bin:/usr/bin:/bin" XDG_DATA_HOME="$reconcile_completion_data" FAIL_COMPLETION_FOR=uv \
  bash "$completion_installer" install linux "$reconcile_completion_manifest" >/dev/null 2>&1; then
  fail_test "completion installation must fail when a generator fails"
fi
while IFS= read -r completion_target; do
  [[ -f "$completion_target" ]] \
    || fail_test "failed completion install must not prune obsolete files: $completion_target"
done <<<"$reconcile_obsolete_targets"

run_completion_installer "$reconcile_completion_data" install linux "$reconcile_completion_manifest" >/dev/null
while IFS= read -r completion_target; do
  [[ ! -e "$completion_target" ]] \
    || fail_test "completion install must prune obsolete owned files: $completion_target"
done <<<"$reconcile_obsolete_targets"
for completion_target in "$reconcile_zsh_dir/_custom" "$reconcile_bash_dir/custom.bash"; do
  [[ -f "$completion_target" ]] \
    || fail_test "completion install must preserve unmarked files: $completion_target"
done
if [[ ! -L "$reconcile_zsh_dir/_linked" || ! -f "$tmp_dir/completion-linked-owned" ]]; then
  fail_test "completion install must neither remove nor follow symlinks in completion directories"
fi
run_completion_installer "$reconcile_completion_data" check linux "$reconcile_completion_manifest" >/dev/null
reconcile_listing="$(run_completion_installer "$reconcile_completion_data" \
  list linux "$reconcile_completion_manifest" | sort)"
if [[ "$reconcile_listing" != "$(sort <<<"$reconcile_current_targets")" ]]; then
  fail_test "completion list must converge on current targets after reconcile; got: $reconcile_listing"
fi

render_template .chezmoiscripts/run_onchange_after_60-check.sh.tmpl "$tmp_dir/run_onchange_after_60-check.sh"
syntax_check bash "$tmp_dir/run_onchange_after_60-check.sh"
shellcheck_rendered_bash "$tmp_dir/run_onchange_after_60-check.sh"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "install_error_trap"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "print_diagnostic_hints"
# The check consumes the native package and runtime inventories instead of a
# duplicated tool list.
# shellcheck disable=SC2016
if grep -Fq 'check_brewfile "$manifests_dir/system/Brewfile"' "$tmp_dir/run_onchange_after_60-check.sh"; then
  assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "brew_command"
  assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "bundle check --file="
else
  # shellcheck disable=SC2016
  assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" 'check_apt_packages "$manifests_dir/system/apt-packages.txt"'
  assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "dpkg-query"
fi
assert_file_matches "$tmp_dir/run_onchange_after_60-check.sh" '^check_mise_toolchain$'
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "mise ls --current --missing"
assert_completion_hook_call "$tmp_dir/run_onchange_after_60-check.sh" check
if (( desktop_platform_supported == 1 )); then
  # shellcheck disable=SC2016
  assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" 'desktop_font_manifest_load "$manifests_dir/desktop/maple-mono-nf-cn.env"'
  assert_file_matches "$tmp_dir/run_onchange_after_60-check.sh" '^check_desktop_font_(macos|fontconfig)$'
else
  assert_file_not_contains "$tmp_dir/run_onchange_after_60-check.sh" 'desktop_font_manifest_load "'
fi

log_step "🤖" "Verifying docs and repo-only files stay undeployed..."
managed_listing="$(chezmoi managed --source="$repo_root" --override-data-file "$tmp_data_file" --path-style=absolute)"
if grep -Fq "$HOME/xdg_config" <<<"$managed_listing"; then
  fail_test "main chezmoi source must not deploy the nested xdg_config source under HOME"
fi
if grep -Fq 'local-overlay-examples' <<<"$managed_listing"; then
  fail_test "chezmoi managed lists something under docs/local-overlay-examples/ (examples must stay undeployed)"
fi
if grep -Fq "$HOME/.github" <<<"$managed_listing"; then
  fail_test "chezmoi managed lists something under .github/ (repo-only collaboration files must stay undeployed)"
fi
undeployed_path="$HOME/CHANGELOG.md"
if grep -Fxq "$undeployed_path" <<<"$managed_listing"; then
  fail_test "chezmoi managed lists ${undeployed_path#"$HOME"/} (repo-only files must stay undeployed)"
fi
undeployed_path="$HOME/LICENSE"
if grep -Fxq "$undeployed_path" <<<"$managed_listing"; then
  fail_test "chezmoi managed lists ${undeployed_path#"$HOME"/} (repo-only files must stay undeployed)"
fi

log_step "📋" "Checking the local overlay inventory..."
overlay_manifest="$repo_root/bootstrap/manifests/local-overlays.tsv"
overlay_examples_dir="$repo_root/docs/local-overlay-examples"
overlay_docs="$overlay_examples_dir/README.md"

if ! local_overlay_load "$overlay_manifest"; then
  fail_test "local overlay inventory validation failed"
fi

if local_overlay_inventory "$tmp_dir/missing-local-overlays.tsv" >/dev/null 2>&1; then
  fail_test "missing local overlay inventory must fail validation"
fi
invalid_overlay_manifest="$tmp_dir/invalid-local-overlays.tsv"
printf '%s\n' $'broken\tbroken.example\t$HOME/.broken\tinvalid\ttest\ttest' >"$invalid_overlay_manifest"
if local_overlay_inventory "$invalid_overlay_manifest" >/dev/null 2>&1; then
  fail_test "invalid local overlay inventory must fail validation"
fi

duplicate_overlay_manifest="$tmp_dir/duplicate-local-overlays.tsv"
duplicate_overlay_errors="$tmp_dir/duplicate-local-overlays.err"
printf '%s\n' \
  $'first\tfirst.example\t$HOME/.first\texact\ttest\ttest' \
  $'second\tfirst.example\t$HOME/.second\texact\ttest\ttest' \
  $'third\tthird.example\t$HOME/.second\texact\ttest\ttest' \
  >"$duplicate_overlay_manifest"
if local_overlay_inventory "$duplicate_overlay_manifest" >/dev/null 2>"$duplicate_overlay_errors"; then
  fail_test "duplicate local overlay inventory must fail validation"
fi
assert_file_contains "$duplicate_overlay_errors" "duplicate local overlay example"
assert_file_contains "$duplicate_overlay_errors" "duplicate local overlay location"

trailing_xdg="$tmp_dir/trailing-xdg/"
trailing_env_path="${trailing_xdg%/}/oh-my-devenv/env.sh"
resolved_trailing_env="$(XDG_CONFIG_HOME="$trailing_xdg" local_overlay_resolve_location "$env_overlay_literal")"
if [[ "$resolved_trailing_env" != "$trailing_env_path" ]]; then
  fail_test "overlay resolution did not normalize a trailing XDG_CONFIG_HOME slash"
fi
if ! XDG_CONFIG_HOME="$trailing_xdg" local_overlay_matches_path "$trailing_env_path"; then
  fail_test "overlay matching failed with a trailing XDG_CONFIG_HOME slash"
fi

special_home="$tmp_dir/home[smoke]"
special_xdg="$tmp_dir/xdg[smoke]"
special_ssh_overlay="$special_home/.ssh/config.d/smoke.conf"
mkdir -p "$(dirname "$special_ssh_overlay")"
touch "$special_ssh_overlay"
if ! HOME="$special_home/" XDG_CONFIG_HOME="$special_xdg/" \
  local_overlay_matches_path "$special_ssh_overlay"; then
  fail_test "overlay matching treated HOME metacharacters as a glob"
fi
special_existing_overlays="$(HOME="$special_home/" XDG_CONFIG_HOME="$special_xdg/" \
  local_overlay_existing_paths)"
if ! grep -Fxq "$special_ssh_overlay" <<<"$special_existing_overlays"; then
  fail_test "overlay discovery treated HOME metacharacters as a glob"
fi

overlay_inventory_count=0
while IFS=$'\t' read -r -a overlay_fields; do
  overlay_id="${overlay_fields[0]}"
  overlay_example="${overlay_fields[1]}"
  overlay_location="${overlay_fields[2]}"
  overlay_consumers="${overlay_fields[4]}"
  overlay_lifecycle="${overlay_fields[5]}"
  overlay_inventory_count=$((overlay_inventory_count + 1))
  if [[ ! -f "$overlay_examples_dir/$overlay_example" ]]; then
    fail_test "overlay inventory example is missing: $overlay_example"
  fi
  overlay_doc_row="| \`$overlay_example\` | \`$overlay_location\` | $overlay_consumers | $overlay_lifecycle |"
  if [[ "$(grep -Fxc -- "$overlay_doc_row" "$overlay_docs")" != "1" ]]; then
    fail_test "overlay documentation row is missing or duplicated for $overlay_id"
  fi
done < <(local_overlay_inventory "$overlay_manifest")

# shellcheck disable=SC2016
overlay_doc_row_count="$(grep -Ec '^\| `[^`]+\.example` \|' "$overlay_docs")"
if [[ "$overlay_doc_row_count" != "$overlay_inventory_count" ]]; then
  fail_test "overlay documentation has $overlay_doc_row_count rows; inventory has $overlay_inventory_count"
fi

for overlay_example_path in "$overlay_examples_dir"/*.example; do
  overlay_example="$(basename "$overlay_example_path")"
  overlay_example_count="$(awk -F '\t' -v example="$overlay_example" '$0 !~ /^#/ && $2 == example { count++ } END { print count + 0 }' "$overlay_manifest")"
  if [[ "$overlay_example_count" != "1" ]]; then
    fail_test "overlay example must appear exactly once in inventory: $overlay_example"
  fi
done

git_config_example="$overlay_examples_dir/git-config.example"
git_hook_example="$overlay_examples_dir/git-pre-push.example"
mise_config_example="$overlay_examples_dir/mise-config.local.toml.example"
assert_file_contains "$git_config_example" '[hook "oh-my-devenv-identity-guard"]'
assert_file_contains "$git_config_example" "event = pre-push"
assert_file_contains "$git_config_example" "<absolute-xdg-config-home>/oh-my-devenv/git/hooks/pre-push"
# shellcheck disable=SC2016
assert_file_contains "$git_hook_example" '$XDG_CONFIG_HOME/oh-my-devenv/git/hooks/pre-push'
# shellcheck disable=SC2016
assert_file_contains "$mise_config_example" '$XDG_CONFIG_HOME/mise/config.local.toml'
# shellcheck disable=SC2016
assert_file_contains "$mise_config_example" '--path "${XDG_CONFIG_HOME:-$HOME/.config}/mise/config.local.toml"'
git config --file "$git_config_example" --list >/dev/null

log_step "📁" "Applying the nested XDG chezmoi source..."
xdg_test_home="$tmp_dir/xdg-config-home"
xdg_test_state="$tmp_dir/xdg-state-home"
xdg_test_config="$tmp_dir/xdg-chezmoi.toml"
cat >"$xdg_test_config" <<'EOF'
[data]
desktopBaseline = false
EOF
chezmoi --config="$xdg_test_config" --source="$repo_root" execute-template \
  --file "$repo_root/.chezmoiscripts/run_after_35-apply-xdg-config.sh.tmpl" \
  >"$tmp_dir/run_after_35-custom-xdg.sh"
XDG_CONFIG_HOME="$xdg_test_home" XDG_STATE_HOME="$xdg_test_state" \
  bash "$tmp_dir/run_after_35-custom-xdg.sh"
xdg_managed_listing="$(XDG_CONFIG_HOME="$xdg_test_home" XDG_STATE_HOME="$xdg_test_state" \
  bash "$repo_root/bootstrap/scripts/xdg-config.sh" managed "$xdg_test_config")"
if [[ -z "$xdg_managed_listing" ]]; then
  fail_test "nested XDG source manages no files"
fi
while IFS= read -r xdg_managed_path; do
  case "$xdg_managed_path" in
    "$xdg_test_home"/*) ;;
    *) fail_test "nested XDG source manages a path outside XDG_CONFIG_HOME: $xdg_managed_path" ;;
  esac
  xdg_managed_relative="${xdg_managed_path#"$xdg_test_home"/}"
  # The main source must not manage the same target, and the first-run backup
  # must cover it.
  if grep -Fxq "$HOME/.config/$xdg_managed_relative" <<<"$managed_listing"; then
    fail_test "main chezmoi source must not manage nested XDG target: $xdg_managed_relative"
  fi
  assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" \
    "\"xdg-config/$xdg_managed_relative|\$XDG_CONFIG_HOME/$xdg_managed_relative\""
done <<<"$xdg_managed_listing"
# Local overlays under XDG_CONFIG_HOME stay user-owned.
while IFS=$'\t' read -r -a overlay_fields; do
  [[ "${overlay_fields[3]}" == "exact" ]] || continue
  overlay_target="$(XDG_CONFIG_HOME="$xdg_test_home" local_overlay_resolve_location "${overlay_fields[2]}")"
  if grep -Fxq "$overlay_target" <<<"$xdg_managed_listing"; then
    fail_test "nested XDG source must not manage the local overlay ${overlay_fields[0]}"
  fi
done < <(local_overlay_inventory "$overlay_manifest")

# With the desktop baseline enabled, the desktop templates receive the font
# family from the manifest through xdg-config.sh.
xdg_desktop_home="$tmp_dir/xdg-desktop-config-home"
xdg_desktop_config="$tmp_dir/xdg-desktop-chezmoi.toml"
cat >"$xdg_desktop_config" <<'EOF'
[data]
desktopBaseline = true
EOF
XDG_CONFIG_HOME="$xdg_desktop_home" XDG_STATE_HOME="$tmp_dir/xdg-desktop-state-home" \
  bash "$repo_root/bootstrap/scripts/xdg-config.sh" apply "$xdg_desktop_config"
if [[ "$desktop_platform_supported_data" == true ]]; then
  assert_file_contains "$xdg_desktop_home/ghostty/config.ghostty" "font-family = $MAPLE_MONO_FAMILY"
elif [[ -s "$xdg_desktop_home/ghostty/config.ghostty" ]]; then
  fail_test "nested XDG apply wrote a Ghostty config on an unsupported desktop platform"
fi
if (( linux_fontconfig_alias_enabled == 1 )); then
  assert_file_contains "$xdg_desktop_home/fontconfig/conf.d/99-oh-my-devenv-maple-mono-nf-cn.conf" \
    "<string>$MAPLE_MONO_FAMILY</string>"
fi

xdg_status="$(XDG_CONFIG_HOME="$xdg_test_home" XDG_STATE_HOME="$xdg_test_state" \
  bash "$repo_root/bootstrap/scripts/xdg-config.sh" status "$xdg_test_config")"
if [[ -n "$xdg_status" ]]; then
  fail_test "nested XDG source is not clean after apply: $xdg_status"
fi

# uninstall.sh already relies on Bash 4 features (mapfile and associative
# arrays), so execute its dynamic preview where that existing requirement holds.
if (( BASH_VERSINFO[0] >= 4 )); then
  uninstall_data_home="$tmp_dir/uninstall-data-home"
  case "$(uname -s)" in
    Darwin) uninstall_completion_platform=darwin ;;
    *) uninstall_completion_platform=linux ;;
  esac
  # uninstall.sh derives completion candidates from the installer inventory.
  uninstall_completion_fixture="$(run_completion_installer "$uninstall_data_home" \
    list "$uninstall_completion_platform" "$completion_manifest" | sed -n '1p')"
  mkdir -p "$(dirname "$uninstall_completion_fixture")"
  touch "$uninstall_completion_fixture"
  uninstall_xdg_fixture="$(head -n 1 <<<"$xdg_managed_listing")"
  overlay_fixture_listing="$(
    export HOME="$tmp_dir/uninstall-home"
    export XDG_CONFIG_HOME="$xdg_test_home"
    while IFS=$'\t' read -r -a overlay_fields; do
      overlay_fixture="$(local_overlay_resolve_location "${overlay_fields[2]}")"
      if [[ "${overlay_fields[3]}" == "glob" ]]; then
        overlay_fixture="${overlay_fixture/\*/smoke}"
      fi
      mkdir -p "$(dirname "$overlay_fixture")"
      touch "$overlay_fixture"
      printf '%s\n' "$overlay_fixture"
    done < <(local_overlay_inventory "$overlay_manifest")
  )"
  uninstall_preview="$(HOME="$tmp_dir/uninstall-home" XDG_CONFIG_HOME="$xdg_test_home" XDG_DATA_HOME="$uninstall_data_home" \
    bash "$repo_root/bootstrap/scripts/uninstall.sh")"
  if ! grep -Fq "[would-remove] file: $uninstall_xdg_fixture" <<<"$uninstall_preview"; then
    fail_test "uninstall preview does not include the custom-XDG managed file $uninstall_xdg_fixture"
  fi
  while IFS= read -r overlay_fixture; do
    if ! grep -Fq "[would-skip] overlay-protected: $overlay_fixture" <<<"$uninstall_preview"; then
      fail_test "uninstall preview does not protect overlay: $overlay_fixture"
    fi
  done <<<"$overlay_fixture_listing"
  if grep -Fq "$tmp_dir/uninstall-home/.config/${uninstall_xdg_fixture#"$xdg_test_home"/}" <<<"$uninstall_preview"; then
    fail_test "uninstall preview fell back to HOME/.config instead of custom XDG_CONFIG_HOME"
  fi
  if ! grep -Fq "$tmp_dir/uninstall-home/.local/state/chezmoi/oh-my-devenv-xdg.boltdb" <<<"$uninstall_preview"; then
    fail_test "uninstall preview does not include the nested chezmoi state file"
  fi
  if ! grep -Fq "[would-remove] file: $uninstall_completion_fixture" <<<"$uninstall_preview"; then
    fail_test "uninstall preview does not include generated shell completion files"
  fi
fi

log_step "🧩" "Running manifest contract checks..."
# Brewfiles must hold only Homebrew bundle directives; the selected packages
# and casks are owned by the manifests themselves.
for brewfile in "$repo_root/bootstrap/manifests/system/Brewfile" "$repo_root/bootstrap/manifests/desktop/Brewfile"; do
  brewfile_entries="$(manifest_entries "$brewfile")"
  if [[ -z "$brewfile_entries" ]]; then
    fail_test "$brewfile declares no packages"
  fi
  if grep -Evq '^(tap|brew|cask|mas|vscode) "[^"]+"' <<<"$brewfile_entries"; then
    fail_test "$brewfile contains a line that is not a Homebrew bundle directive"
  fi
done
assert_desktop_platform_support "{\"chezmoi\":$darwin_chezmoi_data}" true
assert_desktop_platform_support "{\"chezmoi\":$supported_linux_chezmoi_data}" true
assert_desktop_platform_support "{\"chezmoi\":$unsupported_linux_chezmoi_data}" ''
assert_desktop_platform_support '{"chezmoi":{"os":"linux","osRelease":{"id":"ubuntu","versionID":"26.04"},"kernel":{"osrelease":"microsoft-standard-WSL2"}}}' ''
assert_desktop_platform_support '{"chezmoi":{"os":"linux","osRelease":{"id":"debian","versionID":"26.04"},"kernel":{"osrelease":"linux"}}}' ''
synthetic_fontconfig_template="$repo_root/xdg_config/fontconfig/conf.d/99-oh-my-devenv-maple-mono-nf-cn.conf.tmpl"
synthetic_supported_fontconfig="$tmp_dir/fontconfig-supported-linux.conf"
synthetic_unsupported_fontconfig="$tmp_dir/fontconfig-unsupported-linux.conf"
synthetic_macos_fontconfig="$tmp_dir/fontconfig-macos.conf"
chezmoi --source="$repo_root" \
  --override-data "$(desktop_override_data true "$supported_linux_chezmoi_data")" \
  execute-template --file "$synthetic_fontconfig_template" \
  >"$synthetic_supported_fontconfig"
chezmoi --source="$repo_root" \
  --override-data "$(desktop_override_data false "$unsupported_linux_chezmoi_data")" \
  execute-template --file "$synthetic_fontconfig_template" \
  >"$synthetic_unsupported_fontconfig"
chezmoi --source="$repo_root" \
  --override-data "$(desktop_override_data true "$darwin_chezmoi_data")" \
  execute-template --file "$synthetic_fontconfig_template" \
  >"$synthetic_macos_fontconfig"
assert_file_contains "$synthetic_supported_fontconfig" '<edit name="family" mode="prepend" binding="strong">'
assert_file_contains "$synthetic_supported_fontconfig" "<string>$MAPLE_MONO_FAMILY</string>"
assert_file_not_contains "$synthetic_unsupported_fontconfig" 'binding="strong"'
assert_file_not_contains "$synthetic_unsupported_fontconfig" "$MAPLE_MONO_FAMILY"
assert_file_not_contains "$synthetic_macos_fontconfig" 'binding="strong"'
assert_file_not_contains "$synthetic_macos_fontconfig" "$MAPLE_MONO_FAMILY"
synthetic_macos_ghostty="$tmp_dir/ghostty-macos.conf"
synthetic_linux_ghostty="$tmp_dir/ghostty-linux.conf"
chezmoi --source="$repo_root" \
  --override-data "$(desktop_override_data true "$darwin_chezmoi_data")" \
  execute-template --file "$repo_root/xdg_config/ghostty/config.ghostty.tmpl" \
  >"$synthetic_macos_ghostty"
chezmoi --source="$repo_root" \
  --override-data "$(desktop_override_data true "$supported_linux_chezmoi_data")" \
  execute-template --file "$repo_root/xdg_config/ghostty/config.ghostty.tmpl" \
  >"$synthetic_linux_ghostty"
# Both platforms share the manifest font and the local overlay hook; macOS-only
# options must never leak into the Linux render. The remaining preferences are
# owned by the template.
for synthetic_ghostty in "$synthetic_macos_ghostty" "$synthetic_linux_ghostty"; do
  assert_file_contains "$synthetic_ghostty" "font-family = $MAPLE_MONO_FAMILY"
  assert_file_contains "$synthetic_ghostty" "$ghostty_include_literal"
  if [[ "$(grep -Ec '^font-family = ' "$synthetic_ghostty")" != 1 ]]; then
    fail_test "$synthetic_ghostty must set font-family exactly once"
  fi
done
if grep -Eq '^macos-' "$synthetic_linux_ghostty"; then
  fail_test "Linux Ghostty render must not contain macOS-only options"
fi
check_tool_manifest_parser "$repo_root/bootstrap/manifests/ecosystem/go-tools.txt" go_tool_binary_name
check_tool_manifest_parser "$repo_root/bootstrap/manifests/ecosystem/uv-tools.txt" uv_tool_binary_name
# Every Go tool entry must pin an exact module version; the installer refuses
# anything else before running `go install`.
while IFS= read -r go_tool_entry; do
  go_tool_version "$go_tool_entry" >/dev/null \
    || fail_test "go-tools.txt entry is not pinned to an exact version: $go_tool_entry"
done < <(manifest_entries "$repo_root/bootstrap/manifests/ecosystem/go-tools.txt")
for valid_go_pin in \
  'example.com/tool/cmd/tool@v1.2.3' \
  'example.com/tool@v1.2.3-rc.1' \
  'example.com/tool@v0.0.0-20240101000000-abcdef123456'; do
  if [[ "$(go_tool_version "$valid_go_pin")" != "${valid_go_pin##*@}" ]]; then
    fail_test "go_tool_version rejected a valid pin: $valid_go_pin"
  fi
  if [[ "$(go_tool_binary_name "$valid_go_pin")" != tool ]]; then
    fail_test "go_tool_binary_name derived the wrong binary for $valid_go_pin"
  fi
done
go_pin_errors="$tmp_dir/go-pin.err"
for invalid_go_pin in 'example.com/tool@latest' 'example.com/tool' 'example.com/tool@v1.2' 'example.com/tool@1.2.3'; do
  expect_failure "$go_pin_errors" go_tool_version "$invalid_go_pin"
  assert_file_contains "$go_pin_errors" "must pin an exact module version"
done

# Every tool declared under [tools] pins a complete major.minor.patch version.
# The rendered TOML is parsed instead of pattern-matching source lines, so
# quoted and backend-prefixed tool keys stay valid.
render_template xdg_config/mise/config.toml.tmpl "$tmp_dir/mise-config.toml"
# shellcheck disable=SC2016
mise_tools_template='{{ range $tool, $version := (.chezmoi.stdin | fromToml).tools }}{{ $tool }}{{ "\t" }}{{ $version }}{{ "\n" }}{{ end }}'
mise_tool_entries="$(chezmoi --source="$repo_root" execute-template --with-stdin \
  "$mise_tools_template" <"$tmp_dir/mise-config.toml")" \
  || fail_test "mise config does not parse as TOML with a [tools] table"
if [[ -z "$mise_tool_entries" ]]; then
  fail_test "mise config declares no tools"
fi
if grep -Evq $'^[^\t]+\tv?[0-9]+\\.[0-9]+\\.[0-9]+$' <<<"$mise_tool_entries"; then
  fail_test "every mise tool must pin a complete major.minor.patch version"
fi
check_oh_my_zsh_manifest_contract "$repo_root/bootstrap/manifests/shell/oh-my-zsh-plugins.txt" "$tmp_dir/dot_zshrc"
# The desktop font manifest already passed schema validation while loading the
# smoke data; the loader must reject missing and malformed manifests.
font_manifest_errors="$tmp_dir/font-manifest.err"
# shellcheck disable=SC2016
font_manifest_load_command='source "$1"; desktop_font_manifest_load "$2"'
expect_failure "$font_manifest_errors" bash -c "$font_manifest_load_command" _ "$script_dir/common.sh" "$tmp_dir/missing-font.env"
assert_file_contains "$font_manifest_errors" "not found"
invalid_font_manifest="$tmp_dir/font-manifest.invalid.env"
while IFS='|' read -r invalid_assignment expected_error; do
  {
    sed -e "/^${invalid_assignment%%=*}=/d" "$desktop_font_manifest"
    printf '%s\n' "$invalid_assignment"
  } >"$invalid_font_manifest"
  expect_failure "$font_manifest_errors" bash -c "$font_manifest_load_command" _ "$script_dir/common.sh" "$invalid_font_manifest"
  assert_file_contains "$font_manifest_errors" "$expected_error"
done <<'EOF'
MAPLE_MONO_FAMILY=|does not define MAPLE_MONO_FAMILY
MAPLE_MONO_FAMILY="Bad; Family"|must contain only letters, digits, spaces, and hyphens
MAPLE_MONO_POSTSCRIPT_NAMES="Good-Face bad.face"|invalid PostScript name
MAPLE_MONO_SHA256=ABC|not a lowercase SHA-256 digest
EOF
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "check_manifest_cmds \"\$manifests_dir/ecosystem/go-tools.txt\" go_tool_binary_name"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "check_manifest_cmds \"\$manifests_dir/ecosystem/uv-tools.txt\" uv_tool_binary_name"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "check_oh_my_zsh_plugins \"\$manifests_dir/shell/oh-my-zsh-plugins.txt\" \"\${ZSH_CUSTOM:-\$HOME/.oh-my-zsh/custom}\""

log_step "🪞" "Verifying mirror-mode wiring..."
mirrors_sh="$repo_root/bootstrap/scripts/mirrors.sh"
mirrors_env="$repo_root/bootstrap/manifests/system/mirrors.env"

if [[ ! -f "$mirrors_sh" ]]; then
  fail_test "bootstrap/scripts/mirrors.sh is missing"
fi
if [[ ! -f "$mirrors_env" ]]; then
  fail_test "bootstrap/manifests/system/mirrors.env is missing"
fi

# Mirrors module must source cleanly under strict mode (no syntax error,
# no unbound variable at load time).
# shellcheck disable=SC2016
bash -c 'set -euo pipefail; source "$1"' _ "$repo_root/bootstrap/scripts/common.sh" ||
  fail_test "common.sh fails to source under set -euo pipefail (likely broken by mirrors.sh)"

# The manifest must parse as <ENV_VAR_NAME> <value> rows; the endpoints
# themselves are owned by the manifest.
mirror_entries="$(dotfiles_mirrors_entries "$mirrors_env")" || fail_test "mirrors.env failed schema validation"
if [[ -z "$mirror_entries" ]]; then
  fail_test "mirrors.env declares no mirror keys"
fi

# Mode resolution: unset mode + unset probe URL => external, no curl.
# We run inside env -i + a stub $PATH with no curl on it, so any accidental
# curl invocation would fail loudly rather than silently succeed.
mirror_stub_bin="$tmp_dir/mirror-stub-bin"
mkdir -p "$mirror_stub_bin"
# Intentionally create NO curl shim; resolve should never reach it.
# shellcheck disable=SC2016
resolved_unset="$(env -i PATH="$mirror_stub_bin:/usr/bin:/bin" HOME="$tmp_dir/fake-home" \
  bash -c 'source "$1"; dotfiles_resolve_mirror_mode' _ "$repo_root/bootstrap/scripts/common.sh" ||
  true)"
if [[ "$resolved_unset" != "external" ]]; then
  fail_test "dotfiles_resolve_mirror_mode with unset env should return 'external' (got '$resolved_unset')"
fi

# Mode resolution: MODE=auto + empty probe URL => external, still no curl.
# shellcheck disable=SC2016
resolved_auto_empty="$(env -i PATH="$mirror_stub_bin:/usr/bin:/bin" HOME="$tmp_dir/fake-home" \
  DOTFILES_MIRROR_MODE=auto DOTFILES_INTERNAL_PROBE_URL="" \
  bash -c 'source "$1"; dotfiles_resolve_mirror_mode' _ "$repo_root/bootstrap/scripts/common.sh" ||
  true)"
if [[ "$resolved_auto_empty" != "external" ]]; then
  fail_test "dotfiles_resolve_mirror_mode with MODE=auto + empty probe URL should return 'external' (got '$resolved_auto_empty')"
fi

# Byte-for-byte guarantee: external mode must not export a single var.
# We diff the exported env before/after apply in a subshell with a
# stable baseline; any new variable is a regression.
# shellcheck disable=SC2016
external_leak="$(env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/fake-home" \
  bash -c '
    set -euo pipefail
    source "$1"
    before="$(compgen -e | sort)"
    dotfiles_apply_mirror_env
    after="$(compgen -e | sort)"
    comm -13 <(printf "%s\n" "$before") <(printf "%s\n" "$after")
  ' _ "$repo_root/bootstrap/scripts/common.sh")"
if [[ -n "$external_leak" ]]; then
  fail_test "external mode exported unexpected vars: $external_leak"
fi

# Synthetic manifest: verbatim values export, placeholders stay inert until a
# DOTFILES_<KEY> override arrives, and keys that already carry the prefix are
# overridden directly.
synthetic_mirrors_env="$tmp_dir/mirrors.synthetic.env"
cat >"$synthetic_mirrors_env" <<'EOF'
# key value
SMOKE_VERBATIM        https://verbatim.smoke.example/
SMOKE_PLACEHOLDER     <placeholder-smoke>
DOTFILES_SMOKE_DIRECT <placeholder-smoke-direct>
EOF
# shellcheck disable=SC2016
mirror_probe_command='set -euo pipefail; source "$1"; dotfiles_apply_mirror_env "$2" 2>"$3"; printf "%s|%s|%s\n" "${SMOKE_VERBATIM:-<unset>}" "${SMOKE_PLACEHOLDER:-<unset>}" "${DOTFILES_SMOKE_DIRECT:-<unset>}"'
internal_defaults="$(env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/fake-home" DOTFILES_MIRROR_MODE=internal \
  bash -c "$mirror_probe_command" _ "$repo_root/bootstrap/scripts/common.sh" "$synthetic_mirrors_env" "$tmp_dir/internal-warn.err")"
if [[ "$internal_defaults" != "https://verbatim.smoke.example/|<unset>|<unset>" ]]; then
  fail_test "internal mode exported '$internal_defaults'; expected only the verbatim value"
fi
assert_file_contains "$tmp_dir/internal-warn.err" \
  "WARNING: internal mirror value for SMOKE_PLACEHOLDER is still <placeholder>; set DOTFILES_SMOKE_PLACEHOLDER"
assert_file_contains "$tmp_dir/internal-warn.err" \
  "WARNING: internal mirror value for DOTFILES_SMOKE_DIRECT is still <placeholder>; set DOTFILES_SMOKE_DIRECT"
internal_overrides="$(env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/fake-home" DOTFILES_MIRROR_MODE=internal \
  DOTFILES_SMOKE_VERBATIM="https://override.smoke.example/" \
  DOTFILES_SMOKE_PLACEHOLDER="https://placeholder.smoke.example/" \
  DOTFILES_SMOKE_DIRECT="https://direct.smoke.example/" \
  bash -c "$mirror_probe_command" _ "$repo_root/bootstrap/scripts/common.sh" "$synthetic_mirrors_env" "$tmp_dir/internal-override.err")"
if [[ "$internal_overrides" != "https://override.smoke.example/|https://placeholder.smoke.example/|https://direct.smoke.example/" ]]; then
  fail_test "internal mode overrides exported '$internal_overrides'"
fi
if [[ -s "$tmp_dir/internal-override.err" ]]; then
  fail_test "internal mode warned although every key was overridden: $(<"$tmp_dir/internal-override.err")"
fi

# External mode is a no-op that preserves whatever the caller exported.
external_preserved="$(env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/fake-home" SMOKE_VERBATIM=caller \
  bash -c "$mirror_probe_command" _ "$repo_root/bootstrap/scripts/common.sh" "$synthetic_mirrors_env" "$tmp_dir/external.err")"
if [[ "$external_preserved" != "caller|<unset>|<unset>" ]]; then
  fail_test "external mode changed the caller environment: '$external_preserved'"
fi

# An unknown mode warns and falls back to external.
# shellcheck disable=SC2016
resolved_unknown="$(env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/fake-home" DOTFILES_MIRROR_MODE=bogus \
  bash -c 'source "$1"; dotfiles_resolve_mirror_mode' _ "$repo_root/bootstrap/scripts/common.sh" 2>"$tmp_dir/unknown-mode.err")"
if [[ "$resolved_unknown" != "external" ]]; then
  fail_test "unknown DOTFILES_MIRROR_MODE must fall back to external (got '$resolved_unknown')"
fi
assert_file_contains "$tmp_dir/unknown-mode.err" "unknown DOTFILES_MIRROR_MODE=bogus"

# Malformed or missing manifests fail internal mode instead of skipping keys.
# shellcheck disable=SC2016
mirror_fail_command='set -euo pipefail; source "$1"; dotfiles_apply_mirror_env "$2"'
for malformed_row in 'lowercase_key value' 'ONLY_KEY' 'KEY value extra'; do
  printf '%s\n' "$malformed_row" >"$tmp_dir/mirrors.malformed.env"
  expect_failure "$tmp_dir/mirror-malformed.err" env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/fake-home" DOTFILES_MIRROR_MODE=internal \
    bash -c "$mirror_fail_command" _ "$repo_root/bootstrap/scripts/common.sh" "$tmp_dir/mirrors.malformed.env"
  assert_file_contains "$tmp_dir/mirror-malformed.err" "invalid mirror manifest entry"
done
expect_failure "$tmp_dir/mirror-missing.err" env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/fake-home" DOTFILES_MIRROR_MODE=internal \
  bash -c "$mirror_fail_command" _ "$repo_root/bootstrap/scripts/common.sh" "$tmp_dir/mirrors.missing.env"
assert_file_contains "$tmp_dir/mirror-missing.err" "not found"

# Every consumer that should honor mirror mode actually calls
# dotfiles_apply_mirror_env. If we forget to wire one, the module is
# silently bypassed for that installer.
for consumer in \
  "bootstrap/scripts/install-go-tools.sh" \
  "bootstrap/scripts/install-uv-tools.sh" \
  "bootstrap/scripts/install-brew-packages.sh" \
  "bootstrap/scripts/install-oh-my-zsh-assets.sh"; do
  if ! grep -Fq "dotfiles_apply_mirror_env" "$repo_root/$consumer"; then
    fail_test "$consumer is missing dotfiles_apply_mirror_env (mirror mode would be silently bypassed)"
  fi
done
# 30-install-mise.sh.tmpl is the only consumer inside a chezmoi template. On
# Linux the installer URL must honor the mirror override; on macOS mise comes
# from Homebrew. Both platform renders are exercised regardless of the host so
# the Linux behavior is covered on macOS too. The default URL itself is owned
# by the template and is deliberately not asserted here.
assert_file_contains "$tmp_dir/run_onchange_after_30-install-mise.sh" "dotfiles_apply_mirror_env"
mise_hook_template="$repo_root/.chezmoiscripts/run_onchange_after_30-install-mise.sh.tmpl"
synthetic_linux_mise_hook="$tmp_dir/run_onchange_after_30-install-mise.linux.sh"
synthetic_macos_mise_hook="$tmp_dir/run_onchange_after_30-install-mise.macos.sh"
chezmoi --source="$repo_root" \
  --override-data "{\"chezmoi\":$supported_linux_chezmoi_data}" \
  execute-template --file "$mise_hook_template" >"$synthetic_linux_mise_hook"
chezmoi --source="$repo_root" \
  --override-data "{\"chezmoi\":$darwin_chezmoi_data}" \
  execute-template --file "$mise_hook_template" >"$synthetic_macos_mise_hook"
for synthetic_mise_hook in "$synthetic_linux_mise_hook" "$synthetic_macos_mise_hook"; do
  syntax_check bash "$synthetic_mise_hook"
  shellcheck_rendered_bash "$synthetic_mise_hook"
  assert_file_contains "$synthetic_mise_hook" "dotfiles_apply_mirror_env"
done
assert_file_not_contains "$synthetic_macos_mise_hook" "DOTFILES_MISE_INSTALL_URL"
assert_file_contains "$synthetic_macos_mise_hook" "\"\$BREW_CMD\" install mise"

# Behavioral fixture: run the rendered Linux hook with a stubbed curl and no
# mise on PATH. The stub records its arguments and emits a fake installer
# that drops a stub mise into the fake HOME, so the `curl ... | sh` pipeline
# runs end to end without touching the network, the real HOME, or a real
# installer. Any curl call other than the installer download fails loudly.
mise_stub_bin="$tmp_dir/mise-stub-bin"
mise_fake_home="$tmp_dir/mise-fake-home"
mise_curl_log="$tmp_dir/mise-curl.log"
mise_hook_output="$tmp_dir/mise-hook.out"
synthetic_mise_install_url="https://mise-install.smoke.example/install.sh"
mkdir -p "$mise_stub_bin" "$mise_fake_home"
cat >"$mise_stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 2 || "$1" != "-fsSL" ]]; then
  printf 'unexpected curl invocation: %s\n' "$*" >&2
  exit 1
fi
printf '%s\n' "$2" >>"$SMOKE_MISE_CURL_LOG"
cat <<'INSTALLER'
#!/bin/sh
set -eu
mkdir -p "$HOME/.local/bin"
printf '%s\n' '#!/bin/sh' 'echo "mise smoke-stub"' >"$HOME/.local/bin/mise"
chmod +x "$HOME/.local/bin/mise"
INSTALLER
EOF
chmod +x "$mise_stub_bin/curl"
if env -i PATH="$mise_stub_bin:/usr/bin:/bin" HOME="$mise_fake_home" \
  bash -c 'command -v mise' >/dev/null 2>&1; then
  fail_test "mise fixture PATH must not already provide mise"
fi
env -i PATH="$mise_stub_bin:/usr/bin:/bin" HOME="$mise_fake_home" \
  SMOKE_MISE_CURL_LOG="$mise_curl_log" \
  DOTFILES_MISE_INSTALL_URL="$synthetic_mise_install_url" \
  bash "$synthetic_linux_mise_hook" >"$mise_hook_output" 2>&1 \
  || fail_test "rendered Linux mise hook failed: $(<"$mise_hook_output")"
if [[ ! -f "$mise_curl_log" || "$(<"$mise_curl_log")" != "$synthetic_mise_install_url" ]]; then
  fail_test "Linux mise hook must download exactly DOTFILES_MISE_INSTALL_URL once (log: $(cat "$mise_curl_log" 2>/dev/null))"
fi
if [[ ! -x "$mise_fake_home/.local/bin/mise" ]]; then
  fail_test "Linux mise hook did not pipe the downloaded installer into sh"
fi
assert_file_contains "$mise_hook_output" "mise smoke-stub"
assert_file_contains "$mise_hook_output" "mise installed successfully."

log_step "🧬" "Verifying chezmoi init template renders..."

# Render the init template once (it uses promptStringOnce, so it needs
# --init plus the gitName/gitEmail stand-ins). Assert the non-script bits we
# rely on: the status exclude that keeps hooks out of `chezmoi status`, the
# rendered identity block, and the mise attestation defaults. Platform
# branching lives in downstream templates and keys off `.chezmoi.os`, so
# there is nothing WSL-specific to render here.
tmp_chezmoi_toml="$tmp_dir/chezmoi-toml.rendered"
render_chezmoi_toml_tmpl "$tmp_chezmoi_toml"
assert_file_contains "$tmp_chezmoi_toml" "[status]"
assert_toml_section_contains "$tmp_chezmoi_toml" "status" 'exclude = ["scripts"]'
assert_file_contains "$tmp_chezmoi_toml" "[diff]"
assert_toml_section_contains "$tmp_chezmoi_toml" "diff" 'exclude = ["scripts"]'
assert_file_contains "$tmp_chezmoi_toml" 'name = "Smoke Tests"'
assert_file_contains "$tmp_chezmoi_toml" 'email = "smoke@example.com"'
assert_file_contains "$tmp_chezmoi_toml" 'desktopBaseline = true'
# The init template asks for the desktop baseline once; the prompt text and
# the platform default are owned by the template.
assert_file_contains "$repo_root/.chezmoi.toml.tmpl" 'promptBoolOnce . "desktopBaseline"'

log_step "🔍" "Running shellcheck on bootstrap scripts..."
shellcheck "$repo_root/bootstrap/scripts/common.sh" \
  "$repo_root/bootstrap/scripts/go-env.sh" \
  "$repo_root/bootstrap/scripts/install-apt-packages.sh" \
  "$repo_root/bootstrap/scripts/install-brew-packages.sh" \
  "$repo_root/bootstrap/scripts/install-go-tools.sh" \
  "$repo_root/bootstrap/scripts/install-maple-mono-font.sh" \
  "$repo_root/bootstrap/scripts/install-oh-my-zsh-assets.sh" \
  "$repo_root/bootstrap/scripts/install-shell-completions.sh" \
  "$repo_root/bootstrap/scripts/install-uv-tools.sh" \
  "$repo_root/bootstrap/scripts/local-overlays.sh" \
  "$repo_root/bootstrap/scripts/mirrors.sh" \
  "$repo_root/bootstrap/scripts/uninstall.sh" \
  "$repo_root/bootstrap/scripts/xdg-config.sh" \
  "$repo_root/bootstrap/scripts/run-smoke-tests.sh" \
  "$repo_root/docs/local-overlay-examples/git-pre-push.example"

log_step "✅" "Smoke tests passed."
