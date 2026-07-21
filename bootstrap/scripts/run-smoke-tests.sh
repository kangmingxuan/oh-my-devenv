#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bootstrap_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$bootstrap_dir/.." && pwd)"

# shellcheck disable=SC1091
source "$script_dir/common.sh"

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

  if ! grep -Fq "$expected" "$file_path"; then
    fail_test "$file_path is missing expected content: $expected"
  fi
}

assert_file_not_contains() {
  local file_path="$1"
  local unexpected="$2"

  if grep -Fq "$unexpected" "$file_path"; then
    fail_test "$file_path contains unexpected content: $unexpected"
  fi
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
require_command zsh
require_command sh

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

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
tmp_data_file="$tmp_dir/chezmoi-data.toml"
cat >"$tmp_data_file" <<EOF
name = "Smoke Tests"
email = "smoke@example.com"
gitName = "Smoke Tests"
gitEmail = "smoke@example.com"
desktopBaseline = true
desktopPlatformSupported = $desktop_platform_supported_data
EOF

# Literal strings asserted against rendered templates.
# shellcheck disable=SC2016
shared_secrets_literal='$XDG_CONFIG_HOME/oh-my-devenv/secrets.sh'
# shellcheck disable=SC2016
zsh_overlay_literal='$XDG_CONFIG_HOME/oh-my-devenv/zshrc.zsh'
# shellcheck disable=SC2016
bash_overlay_literal='$XDG_CONFIG_HOME/oh-my-devenv/bashrc.bash'
# shellcheck disable=SC2016
xdg_source_literal='source "$HOME/.local/share/oh-my-devenv/xdg.sh"'
# shellcheck disable=SC2016
backup_mise_literal='xdg-config/mise/config.toml|$XDG_CONFIG_HOME/mise/config.toml'
# shellcheck disable=SC2016
backup_fontconfig_literal='xdg-config/fontconfig/conf.d/99-oh-my-devenv-maple-mono-nf-cn.conf|$XDG_CONFIG_HOME/fontconfig/conf.d/99-oh-my-devenv-maple-mono-nf-cn.conf'
# shellcheck disable=SC2016
backup_ghostty_literal='xdg-config/ghostty/config.ghostty|$XDG_CONFIG_HOME/ghostty/config.ghostty'
# shellcheck disable=SC2016
xdg_apply_literal='bash "$scripts_dir/xdg-config.sh" apply "$config_file"'
old_shell_overlay_patterns=(
  '.zshrc.secrets'
  '.bashrc.secrets'
  '.zsh/work.zsh'
  '.bash/work.bash'
  'work/env.sh'
  'work-env.sh.example'
  'zshrc.secrets.example'
  'bashrc.secrets.example'
  'zsh-work.zsh.example'
  'bash-work.bash.example'
)

log_step "🧪" "Running local smoke tests..."

log_step "📂" "Checking XDG_CONFIG_HOME resolution..."
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

mkdir -p "$tmp_dir/env-must-not-move-xdg/oh-my-devenv"
printf '%s\n' 'unset XDG_CONFIG_HOME' >"$tmp_dir/env-must-not-move-xdg/oh-my-devenv/env.sh"
if XDG_CONFIG_HOME="$tmp_dir/env-must-not-move-xdg" \
  bash -c 'source "$1"; oh_my_devenv_setup_xdg_config_home; oh_my_devenv_source_shared_env' \
  _ "$xdg_resolver" 2>"$tmp_dir/env-moved-xdg.err"; then
  fail_test "env.sh must not be able to change XDG_CONFIG_HOME"
fi
assert_file_contains "$tmp_dir/env-moved-xdg.err" "must not change XDG_CONFIG_HOME"

log_step "📝" "Rendering and checking shell templates..."
render_template dot_zshrc.tmpl "$tmp_dir/dot_zshrc"
syntax_check zsh "$tmp_dir/dot_zshrc"
assert_file_contains "$tmp_dir/dot_zshrc" "$shared_secrets_literal"
assert_file_contains "$tmp_dir/dot_zshrc" "$zsh_overlay_literal"

render_template dot_zprofile.tmpl "$tmp_dir/dot_zprofile"
syntax_check zsh "$tmp_dir/dot_zprofile"

render_template dot_zsh/env.zsh.tmpl "$tmp_dir/env.zsh"
syntax_check zsh "$tmp_dir/env.zsh"
assert_file_contains "$tmp_dir/env.zsh" "$xdg_source_literal"
assert_file_contains "$tmp_dir/env.zsh" "oh_my_devenv_setup_xdg_config_home"
assert_file_contains "$tmp_dir/env.zsh" "oh_my_devenv_source_shared_env"
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
assert_file_contains "$tmp_dir/env.bash" "oh_my_devenv_setup_xdg_config_home"
assert_file_contains "$tmp_dir/env.bash" "oh_my_devenv_source_shared_env"
assert_file_not_contains "$tmp_dir/env.bash" "$shared_secrets_literal"
assert_file_not_contains "$tmp_dir/env.bash" "$bash_overlay_literal"

for old_shell_overlay_pattern in "${old_shell_overlay_patterns[@]}"; do
  assert_file_not_contains "$tmp_dir/dot_zshrc" "$old_shell_overlay_pattern"
  assert_file_not_contains "$tmp_dir/env.zsh" "$old_shell_overlay_pattern"
  assert_file_not_contains "$tmp_dir/dot_bashrc" "$old_shell_overlay_pattern"
  assert_file_not_contains "$tmp_dir/env.bash" "$old_shell_overlay_pattern"
  assert_file_not_contains "$repo_root/bootstrap/scripts/common.sh" "$old_shell_overlay_pattern"
  if grep -RInF -- "$old_shell_overlay_pattern" "$repo_root/docs/local-overlay-examples" >/dev/null 2>&1; then
    fail_test "docs/local-overlay-examples still references legacy shell overlay path: $old_shell_overlay_pattern"
  fi
done

syntax_check sh "$repo_root/dot_profile"

render_template dot_gitconfig.tmpl "$tmp_dir/dot_gitconfig"
assert_file_contains "$tmp_dir/dot_gitconfig" "path = ~/.gitconfig.local"
# The managed gitconfig must stay host-neutral: no hard-coded URL rewrites, so
# the baseline carries no organization-specific Git routing.
assert_file_not_contains "$tmp_dir/dot_gitconfig" 'insteadOf'
assert_file_contains "$repo_root/bootstrap/scripts/common.sh" "oh_my_devenv_setup_xdg_config_home"
assert_file_contains "$repo_root/bootstrap/scripts/common.sh" "oh_my_devenv_source_shared_env"
assert_file_not_contains "$repo_root/bootstrap/scripts/common.sh" "$shared_secrets_literal"

log_step "📜" "Rendering and checking chezmoi bootstrap scripts..."
render_template .chezmoiscripts/run_once_before_10-bootstrap.sh.tmpl "$tmp_dir/run_once_before_10-bootstrap.sh"
syntax_check bash "$tmp_dir/run_once_before_10-bootstrap.sh"
shellcheck_rendered_bash "$tmp_dir/run_once_before_10-bootstrap.sh"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "backup_existing_managed_configs()"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "chezmoi-first-run-backup"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" ".ssh/config"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "$backup_mise_literal"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "$backup_fontconfig_literal"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "$backup_ghostty_literal"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" ".zshrc"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" ".gitconfig"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "cp -Lp \"\$existing_path\" \"\$backup_path\""
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "install_error_trap"

render_template .chezmoiscripts/run_after_35-apply-xdg-config.sh.tmpl "$tmp_dir/run_after_35-apply-xdg-config.sh"
syntax_check bash "$tmp_dir/run_after_35-apply-xdg-config.sh"
shellcheck_rendered_bash "$tmp_dir/run_after_35-apply-xdg-config.sh"
assert_file_contains "$tmp_dir/run_after_35-apply-xdg-config.sh" "$xdg_apply_literal"

render_template .chezmoiscripts/run_onchange_after_20-install-system-packages.sh.tmpl "$tmp_dir/run_onchange_after_20-install-system-packages.sh"
syntax_check bash "$tmp_dir/run_onchange_after_20-install-system-packages.sh"
shellcheck_rendered_bash "$tmp_dir/run_onchange_after_20-install-system-packages.sh"
assert_file_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "install_error_trap"
if grep -Fq "Installing system packages via Homebrew" "$tmp_dir/run_onchange_after_20-install-system-packages.sh"; then
  assert_file_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "Brewfile.optional hash:"
  assert_file_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "DOTFILES_INSTALL_REPO_OPTIONAL_BREWFILE"
  assert_file_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "DOTFILES_EXTRA_BREWFILES"
  assert_file_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "entries must be absolute paths"
  assert_file_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "extra Homebrew Brewfile not found"
  assert_file_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "\"\$manifests_dir/system/Brewfile\""
else
  assert_file_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "Installing system packages via apt"
  assert_file_not_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "Brewfile.optional"
  assert_file_not_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "DOTFILES_INSTALL_REPO_OPTIONAL_BREWFILE"
  assert_file_not_contains "$tmp_dir/run_onchange_after_20-install-system-packages.sh" "DOTFILES_EXTRA_BREWFILES"
fi

render_template .chezmoiscripts/run_onchange_after_22-install-desktop-assets.sh.tmpl "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh"
syntax_check bash "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh"
shellcheck_rendered_bash "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh"
assert_file_contains "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh" "install_error_trap"
desktop_platform_supported=0
linux_fontconfig_alias_enabled=0
if grep -Fq "desktop baseline via Homebrew" "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh"; then
  desktop_platform_supported=1
  assert_file_contains "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh" 'manifests_dir/desktop/Brewfile'
elif grep -Fq "Ubuntu desktop baseline" "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh"; then
  desktop_platform_supported=1
  linux_fontconfig_alias_enabled=1
  assert_file_contains "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh" 'manifests_dir/desktop/apt-packages.txt'
  assert_file_contains "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh" 'install-maple-mono-font.sh'
  assert_file_contains "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh" 'maple-mono-nf-cn.env'
else
  assert_file_contains "$tmp_dir/run_onchange_after_22-install-desktop-assets.sh" "supported only on macOS and Ubuntu 26.04+ outside WSL"
fi

unsupported_desktop_hook="$tmp_dir/run_onchange_after_22-install-desktop-assets.unsupported-linux.sh"
chezmoi --source="$repo_root" \
  --override-data '{"desktopBaseline":true,"chezmoi":{"os":"linux","osRelease":{"id":"ubuntu","versionID":"24.04"},"kernel":{"osrelease":"linux"}}}' \
  execute-template \
  --file "$repo_root/.chezmoiscripts/run_onchange_after_22-install-desktop-assets.sh.tmpl" \
  >"$unsupported_desktop_hook"
syntax_check bash "$unsupported_desktop_hook"
shellcheck_rendered_bash "$unsupported_desktop_hook"
assert_file_contains "$unsupported_desktop_hook" "supported only on macOS and Ubuntu 26.04+ outside WSL"
assert_file_not_contains "$unsupported_desktop_hook" 'manifests_dir='
assert_file_not_contains "$unsupported_desktop_hook" "Desktop baseline installation complete."

render_template xdg_config/ghostty/config.ghostty.tmpl "$tmp_dir/config.ghostty"
if (( desktop_platform_supported == 1 )); then
  assert_file_contains "$tmp_dir/config.ghostty" "font-family = Maple Mono NF CN"
  assert_file_contains "$tmp_dir/config.ghostty" "notify-on-command-finish = unfocused"
  assert_file_contains "$tmp_dir/config.ghostty" "keybind = global:f12=toggle_quick_terminal"
  assert_file_contains "$tmp_dir/config.ghostty" "config-file = ?config.local.ghostty"
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
  assert_file_contains "$tmp_dir/99-oh-my-devenv-maple-mono-nf-cn.conf" "Maple Mono NF CN"
else
  assert_file_not_contains "$tmp_dir/99-oh-my-devenv-maple-mono-nf-cn.conf" 'binding="strong"'
  assert_file_not_contains "$tmp_dir/99-oh-my-devenv-maple-mono-nf-cn.conf" "Maple Mono NF CN"
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
assert_file_not_contains "$disabled_fontconfig_fragment" "Maple Mono NF CN"

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
assert_file_contains "$tmp_dir/run_onchange_after_40-install-runtimes.sh" "MISE_GITHUB_ATTESTATIONS=\"\${MISE_GITHUB_ATTESTATIONS:-false}\""
assert_file_contains "$tmp_dir/run_onchange_after_40-install-runtimes.sh" "MISE_AQUA_GITHUB_ATTESTATIONS=\"\${MISE_AQUA_GITHUB_ATTESTATIONS:-false}\""
assert_file_contains "$tmp_dir/run_onchange_after_40-install-runtimes.sh" "MISE_PYTHON_GITHUB_ATTESTATIONS=\"\${MISE_PYTHON_GITHUB_ATTESTATIONS:-\$MISE_GITHUB_ATTESTATIONS}\""
assert_file_contains "$tmp_dir/run_onchange_after_40-install-runtimes.sh" "mise install --yes"

render_template .chezmoiscripts/run_onchange_after_50-sync-ecosystem-tools.sh.tmpl "$tmp_dir/run_onchange_after_50-sync-ecosystem-tools.sh"
syntax_check bash "$tmp_dir/run_onchange_after_50-sync-ecosystem-tools.sh"
shellcheck_rendered_bash "$tmp_dir/run_onchange_after_50-sync-ecosystem-tools.sh"
assert_file_contains "$tmp_dir/run_onchange_after_50-sync-ecosystem-tools.sh" "install_error_trap"

render_template .chezmoiscripts/run_onchange_after_60-check.sh.tmpl "$tmp_dir/run_onchange_after_60-check.sh"
syntax_check bash "$tmp_dir/run_onchange_after_60-check.sh"
shellcheck_rendered_bash "$tmp_dir/run_onchange_after_60-check.sh"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "install_error_trap"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "Core tools in this environment"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "print_version_line chezmoi"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "print_version_line git"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "print_diagnostic_hints"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "Maple Mono NF CN monospace alias"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "fc-conflist"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "fc-match -f '%{postscriptname}\\n' monospace"

log_step "🤖" "Verifying docs and repo-only files stay undeployed..."
managed_listing="$(chezmoi managed --source="$repo_root" --path-style=absolute)"
if grep -Fq "$HOME/xdg_config" <<<"$managed_listing"; then
  fail_test "main chezmoi source must not deploy the nested xdg_config source under HOME"
fi
for nested_target in \
  "$HOME/.config/mise/config.toml" \
  "$HOME/.config/ghostty/config.ghostty" \
  "$HOME/.config/fontconfig/conf.d/99-oh-my-devenv-maple-mono-nf-cn.conf"; do
  if grep -Fxq "$nested_target" <<<"$managed_listing"; then
    fail_test "main chezmoi source must not manage nested XDG target: $nested_target"
  fi
done
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

log_step "📁" "Applying the nested XDG chezmoi source..."
xdg_test_home="$tmp_dir/xdg-config-home"
xdg_test_config="$tmp_dir/xdg-chezmoi.toml"
cat >"$xdg_test_config" <<'EOF'
[data]
desktopBaseline = false
EOF
chezmoi --config="$xdg_test_config" --source="$repo_root" execute-template \
  --file "$repo_root/.chezmoiscripts/run_after_35-apply-xdg-config.sh.tmpl" \
  >"$tmp_dir/run_after_35-custom-xdg.sh"
XDG_CONFIG_HOME="$xdg_test_home" bash "$tmp_dir/run_after_35-custom-xdg.sh"
assert_file_contains "$xdg_test_home/mise/config.toml" "[tools]"
assert_file_contains "$xdg_test_home/fontconfig/conf.d/99-oh-my-devenv-maple-mono-nf-cn.conf" "<fontconfig>"

xdg_managed_listing="$(XDG_CONFIG_HOME="$xdg_test_home" \
  bash "$repo_root/bootstrap/scripts/xdg-config.sh" managed "$xdg_test_config")"
if ! grep -Fxq "$xdg_test_home/mise/config.toml" <<<"$xdg_managed_listing"; then
  fail_test "nested XDG source does not manage mise/config.toml under XDG_CONFIG_HOME"
fi
if ! grep -Fxq "$xdg_test_home/fontconfig/conf.d/99-oh-my-devenv-maple-mono-nf-cn.conf" <<<"$xdg_managed_listing"; then
  fail_test "nested XDG source does not manage the Fontconfig fragment under XDG_CONFIG_HOME"
fi

xdg_status="$(XDG_CONFIG_HOME="$xdg_test_home" \
  bash "$repo_root/bootstrap/scripts/xdg-config.sh" status "$xdg_test_config")"
if [[ -n "$xdg_status" ]]; then
  fail_test "nested XDG source is not clean after apply: $xdg_status"
fi

# uninstall.sh already relies on Bash 4 features (mapfile and associative
# arrays), so execute its dynamic preview where that existing requirement holds.
if (( BASH_VERSINFO[0] >= 4 )); then
  mkdir -p "$xdg_test_home/oh-my-devenv"
  touch "$xdg_test_home/oh-my-devenv/secrets.sh"
  uninstall_preview="$(HOME="$tmp_dir/uninstall-home" XDG_CONFIG_HOME="$xdg_test_home" \
    bash "$repo_root/bootstrap/scripts/uninstall.sh")"
  if ! grep -Fq "[would-remove] file: $xdg_test_home/mise/config.toml" <<<"$uninstall_preview"; then
    fail_test "uninstall preview does not include the custom-XDG mise config"
  fi
  if ! grep -Fq "[would-skip] overlay-protected: $xdg_test_home/oh-my-devenv/secrets.sh" <<<"$uninstall_preview"; then
    fail_test "uninstall preview does not protect the custom-XDG secrets overlay"
  fi
  if grep -Fq "$tmp_dir/uninstall-home/.config/mise/config.toml" <<<"$uninstall_preview"; then
    fail_test "uninstall preview fell back to HOME/.config instead of custom XDG_CONFIG_HOME"
  fi
fi

log_step "🧩" "Running manifest contract checks..."
assert_desktop_platform_support '{"chezmoi":{"os":"darwin","osRelease":null,"kernel":null}}' true
assert_desktop_platform_support '{"chezmoi":{"os":"linux","osRelease":{"id":"ubuntu","versionID":"26.04"},"kernel":{"osrelease":"linux"}}}' true
assert_desktop_platform_support '{"chezmoi":{"os":"linux","osRelease":{"id":"ubuntu","versionID":"24.04"},"kernel":{"osrelease":"linux"}}}' ''
assert_desktop_platform_support '{"chezmoi":{"os":"linux","osRelease":{"id":"ubuntu","versionID":"26.04"},"kernel":{"osrelease":"microsoft-standard-WSL2"}}}' ''
assert_desktop_platform_support '{"chezmoi":{"os":"linux","osRelease":{"id":"debian","versionID":"26.04"},"kernel":{"osrelease":"linux"}}}' ''
synthetic_fontconfig_template="$repo_root/xdg_config/fontconfig/conf.d/99-oh-my-devenv-maple-mono-nf-cn.conf.tmpl"
synthetic_supported_fontconfig="$tmp_dir/fontconfig-supported-linux.conf"
synthetic_unsupported_fontconfig="$tmp_dir/fontconfig-unsupported-linux.conf"
synthetic_macos_fontconfig="$tmp_dir/fontconfig-macos.conf"
chezmoi --source="$repo_root" \
  --override-data '{"desktopBaseline":true,"desktopPlatformSupported":true,"chezmoi":{"os":"linux","osRelease":{"id":"ubuntu","versionID":"26.04"},"kernel":{"osrelease":"linux"}}}' \
  execute-template --file "$synthetic_fontconfig_template" \
  >"$synthetic_supported_fontconfig"
chezmoi --source="$repo_root" \
  --override-data '{"desktopBaseline":true,"desktopPlatformSupported":false,"chezmoi":{"os":"linux","osRelease":{"id":"ubuntu","versionID":"24.04"},"kernel":{"osrelease":"linux"}}}' \
  execute-template --file "$synthetic_fontconfig_template" \
  >"$synthetic_unsupported_fontconfig"
chezmoi --source="$repo_root" \
  --override-data '{"desktopBaseline":true,"desktopPlatformSupported":true,"chezmoi":{"os":"darwin","osRelease":null,"kernel":null}}' \
  execute-template --file "$synthetic_fontconfig_template" \
  >"$synthetic_macos_fontconfig"
assert_file_contains "$synthetic_supported_fontconfig" '<edit name="family" mode="prepend" binding="strong">'
assert_file_contains "$synthetic_supported_fontconfig" "Maple Mono NF CN"
assert_file_not_contains "$synthetic_unsupported_fontconfig" 'binding="strong"'
assert_file_not_contains "$synthetic_unsupported_fontconfig" "Maple Mono NF CN"
assert_file_not_contains "$synthetic_macos_fontconfig" 'binding="strong"'
assert_file_not_contains "$synthetic_macos_fontconfig" "Maple Mono NF CN"
check_tool_manifest_parser "$repo_root/bootstrap/manifests/ecosystem/go-tools.txt" go_tool_binary_name
check_tool_manifest_parser "$repo_root/bootstrap/manifests/ecosystem/uv-tools.txt" uv_tool_binary_name
if grep -Eq '@latest([[:space:]]|$)' "$repo_root/bootstrap/manifests/ecosystem/go-tools.txt"; then
  fail_test "go-tools.txt must pin exact versions instead of @latest"
fi

mise_config="$repo_root/xdg_config/mise/config.toml.tmpl"
for runtime in go node python; do
  if ! grep -Eq "^${runtime} = \"v?[0-9]+\.[0-9]+\.[0-9]+\"$" "$mise_config"; then
    fail_test "mise config must pin $runtime to a complete major.minor.patch version"
  fi
done
check_oh_my_zsh_manifest_contract "$repo_root/bootstrap/manifests/shell/oh-my-zsh-plugins.txt" "$tmp_dir/dot_zshrc"
desktop_font_manifest="$repo_root/bootstrap/manifests/desktop/maple-mono-nf-cn.env"
desktop_font_sha="$(sed -n 's/^MAPLE_MONO_SHA256=//p' "$desktop_font_manifest")"
if [[ ! "$desktop_font_sha" =~ ^[0-9a-f]{64}$ ]]; then
  fail_test "Maple Mono desktop manifest must pin a lowercase SHA-256 digest"
fi
assert_file_contains "$desktop_font_manifest" "MAPLE_MONO_VERSION=7.9"
assert_file_contains "$desktop_font_manifest" "/releases/download/v7.9/MapleMono-NF-CN-unhinted.zip"
assert_file_contains "$repo_root/bootstrap/manifests/desktop/apt-packages.txt" "fontconfig"
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

# Protect the external defaults: these are the values today's baseline
# has always handed to downstream tooling. If someone changes them, the
# byte-for-byte guarantee for external mode is at risk.
expected_external_goproxy="proxy.golang.org,direct"
if ! grep -Eq "^external[[:space:]]+GOPROXY[[:space:]]+${expected_external_goproxy}[[:space:]]*$" "$mirrors_env"; then
  fail_test "mirrors.env: external GOPROXY default drifted from $expected_external_goproxy"
fi

# Every <placeholder-...> the manifest ships must live only under the
# `internal` mode. If a placeholder leaks into the `external` rows we'd
# silently export it in default installs.
if awk '$1 == "external" && $3 ~ /<placeholder/ { found=1 } END { exit found?0:1 }' "$mirrors_env"; then
  fail_test "mirrors.env: an external row contains a <placeholder> value (would leak into default installs)"
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

# Internal mode + user override actually exports the real key.
# shellcheck disable=SC2016
internal_export_check="$(env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/fake-home" \
  DOTFILES_MIRROR_MODE=internal \
  DOTFILES_GOPROXY="https://goproxy.smoke.example/" \
  bash -c '
    set -euo pipefail
    source "$1"
    dotfiles_apply_mirror_env 2>/dev/null
    printf "%s\n" "${GOPROXY:-<unset>}"
  ' _ "$repo_root/bootstrap/scripts/common.sh")"
if [[ "$internal_export_check" != "https://goproxy.smoke.example/" ]]; then
  fail_test "internal mode + DOTFILES_GOPROXY override did not export GOPROXY (got '$internal_export_check')"
fi

# Internal mode without any override must warn (not silently export a
# <placeholder>) and must leave GOPROXY unset.
# shellcheck disable=SC2016
internal_no_override="$(env -i PATH="/usr/bin:/bin" HOME="$tmp_dir/fake-home" \
  DOTFILES_MIRROR_MODE=internal \
  bash -c '
    set -euo pipefail
    source "$1"
    dotfiles_apply_mirror_env 2>"$2"
    printf "GOPROXY=%s\n" "${GOPROXY:-<unset>}"
  ' _ "$repo_root/bootstrap/scripts/common.sh" "$tmp_dir/internal-warn.err")"
if [[ "$internal_no_override" != "GOPROXY=<unset>" ]]; then
  fail_test "internal mode without override should leave GOPROXY unset (got '$internal_no_override')"
fi
if ! grep -Fq "WARNING: internal mirror value for GOPROXY is still <placeholder>" "$tmp_dir/internal-warn.err"; then
  fail_test "internal mode without override did not emit the expected placeholder warning"
fi

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
# 30-install-mise.sh.tmpl is the only consumer we touched inside a
# chezmoi template; assert its rendered form also wired the helper.
mise_install_line="mise_install_url=\"\${DOTFILES_MISE_INSTALL_URL:-https://mise.run}\""
mise_curl_line="curl -fsSL \"\$mise_install_url\" | sh"
assert_file_contains "$tmp_dir/run_onchange_after_30-install-mise.sh" "dotfiles_apply_mirror_env"
if grep -Fq 'curl -fsSL' "$tmp_dir/run_onchange_after_30-install-mise.sh"; then
  assert_file_contains "$tmp_dir/run_onchange_after_30-install-mise.sh" "$mise_install_line"
  assert_file_contains "$tmp_dir/run_onchange_after_30-install-mise.sh" "$mise_curl_line"
else
  assert_file_not_contains "$tmp_dir/run_onchange_after_30-install-mise.sh" "$mise_install_line"
  assert_file_not_contains "$tmp_dir/run_onchange_after_30-install-mise.sh" "$mise_curl_line"
  assert_file_contains "$tmp_dir/run_onchange_after_30-install-mise.sh" "\"\$BREW_CMD\" install mise"
fi

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
assert_file_contains "$repo_root/xdg_config/mise/config.toml.tmpl" "[settings]"
assert_file_contains "$repo_root/xdg_config/mise/config.toml.tmpl" "github_attestations = false"
assert_file_contains "$repo_root/xdg_config/mise/config.toml.tmpl" "[settings.aqua]"

log_step "🔍" "Running shellcheck on bootstrap scripts..."
shellcheck "$repo_root/bootstrap/scripts/common.sh" \
  "$repo_root/bootstrap/scripts/go-env.sh" \
  "$repo_root/bootstrap/scripts/install-apt-packages.sh" \
  "$repo_root/bootstrap/scripts/install-brew-packages.sh" \
  "$repo_root/bootstrap/scripts/install-go-tools.sh" \
  "$repo_root/bootstrap/scripts/install-maple-mono-font.sh" \
  "$repo_root/bootstrap/scripts/install-oh-my-zsh-assets.sh" \
  "$repo_root/bootstrap/scripts/install-uv-tools.sh" \
  "$repo_root/bootstrap/scripts/mirrors.sh" \
  "$repo_root/bootstrap/scripts/uninstall.sh" \
  "$repo_root/bootstrap/scripts/xdg-config.sh" \
  "$repo_root/bootstrap/scripts/run-smoke-tests.sh"

log_step "✅" "Smoke tests passed."
