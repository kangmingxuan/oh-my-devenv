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

fail_test() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
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

# Stand-in chezmoi data for template rendering. Carries two concerns at
# once:
#   - `name` / `email` mirror the shape that `.chezmoi.toml.tmpl` produces
#     after `chezmoi init`, which normal templates (dot_gitconfig, shell
#     env, etc.) read via .name / .email.
#   - `gitName` / `gitEmail` short-circuit the `promptStringOnce` calls in
#     `.chezmoi.toml.tmpl` itself so render_chezmoi_toml_tmpl can run
#     non-interactively.
tmp_data_file="$tmp_dir/chezmoi-data.toml"
cat >"$tmp_data_file" <<EOF
name = "Smoke Tests"
email = "smoke@example.com"
gitName = "Smoke Tests"
gitEmail = "smoke@example.com"
EOF

# Literal strings asserted against rendered templates.
# shellcheck disable=SC2016
shared_env_literal='${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/env.sh'
# shellcheck disable=SC2016
shared_secrets_literal='${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/secrets.sh'
# shellcheck disable=SC2016
zsh_overlay_literal='${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/zshrc.zsh'
# shellcheck disable=SC2016
bash_overlay_literal='${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-devenv/bashrc.bash'
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

log_step "📝" "Rendering and checking shell templates..."
render_template dot_zshrc.tmpl "$tmp_dir/dot_zshrc"
syntax_check zsh "$tmp_dir/dot_zshrc"
assert_file_contains "$tmp_dir/dot_zshrc" "$shared_secrets_literal"
assert_file_contains "$tmp_dir/dot_zshrc" "$zsh_overlay_literal"

render_template dot_zprofile.tmpl "$tmp_dir/dot_zprofile"
syntax_check zsh "$tmp_dir/dot_zprofile"

render_template dot_zsh/env.zsh.tmpl "$tmp_dir/env.zsh"
syntax_check zsh "$tmp_dir/env.zsh"
assert_file_contains "$tmp_dir/env.zsh" "$shared_env_literal"
assert_file_not_contains "$tmp_dir/env.zsh" "$shared_secrets_literal"
assert_file_not_contains "$tmp_dir/env.zsh" "$zsh_overlay_literal"

render_template dot_bashrc.tmpl "$tmp_dir/dot_bashrc"
syntax_check bash "$tmp_dir/dot_bashrc"
assert_file_contains "$tmp_dir/dot_bashrc" "$shared_secrets_literal"
assert_file_contains "$tmp_dir/dot_bashrc" "$bash_overlay_literal"

render_template dot_bash/env.bash.tmpl "$tmp_dir/env.bash"
syntax_check bash "$tmp_dir/env.bash"
assert_file_contains "$tmp_dir/env.bash" "$shared_env_literal"
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
# Defend the boundary property without naming any organization: the managed
# gitconfig must not carry a host-specific URL rewrite. Real internal-host
# denylist patterns live in the internal overlay's boundary-denylist.txt.
assert_file_not_contains "$tmp_dir/dot_gitconfig" 'insteadOf'
assert_file_contains "$repo_root/bootstrap/scripts/common.sh" "$shared_env_literal"
assert_file_not_contains "$repo_root/bootstrap/scripts/common.sh" "$shared_secrets_literal"

log_step "📜" "Rendering and checking chezmoi bootstrap scripts..."
render_template .chezmoiscripts/run_once_before_10-bootstrap.sh.tmpl "$tmp_dir/run_once_before_10-bootstrap.sh"
syntax_check bash "$tmp_dir/run_once_before_10-bootstrap.sh"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "backup_existing_managed_configs()"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "chezmoi-first-run-backup"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" ".ssh/config"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" ".config/mise/config.toml"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" ".zshrc"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" ".gitconfig"
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "cp -Lp \"\$existing_path\" \"\$backup_path\""
assert_file_contains "$tmp_dir/run_once_before_10-bootstrap.sh" "install_error_trap"

render_template .chezmoiscripts/run_onchange_after_20-install-system-packages.sh.tmpl "$tmp_dir/run_onchange_after_20-install-system-packages.sh"
syntax_check bash "$tmp_dir/run_onchange_after_20-install-system-packages.sh"
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

render_template .chezmoiscripts/run_onchange_after_25-install-shell-assets.sh.tmpl "$tmp_dir/run_onchange_after_25-install-shell-assets.sh"
syntax_check bash "$tmp_dir/run_onchange_after_25-install-shell-assets.sh"
assert_file_contains "$tmp_dir/run_onchange_after_25-install-shell-assets.sh" "install_error_trap"

render_template .chezmoiscripts/run_onchange_after_30-install-mise.sh.tmpl "$tmp_dir/run_onchange_after_30-install-mise.sh"
syntax_check bash "$tmp_dir/run_onchange_after_30-install-mise.sh"
assert_file_contains "$tmp_dir/run_onchange_after_30-install-mise.sh" "install_error_trap"

render_template .chezmoiscripts/run_onchange_after_40-install-runtimes.sh.tmpl "$tmp_dir/run_onchange_after_40-install-runtimes.sh"
syntax_check bash "$tmp_dir/run_onchange_after_40-install-runtimes.sh"
assert_file_contains "$tmp_dir/run_onchange_after_40-install-runtimes.sh" "install_error_trap"
assert_file_contains "$tmp_dir/run_onchange_after_40-install-runtimes.sh" "MISE_GITHUB_ATTESTATIONS=\"\${MISE_GITHUB_ATTESTATIONS:-false}\""
assert_file_contains "$tmp_dir/run_onchange_after_40-install-runtimes.sh" "MISE_AQUA_GITHUB_ATTESTATIONS=\"\${MISE_AQUA_GITHUB_ATTESTATIONS:-false}\""
assert_file_contains "$tmp_dir/run_onchange_after_40-install-runtimes.sh" "MISE_PYTHON_GITHUB_ATTESTATIONS=\"\${MISE_PYTHON_GITHUB_ATTESTATIONS:-\$MISE_GITHUB_ATTESTATIONS}\""
assert_file_contains "$tmp_dir/run_onchange_after_40-install-runtimes.sh" "mise install --yes"

render_template .chezmoiscripts/run_onchange_after_50-sync-ecosystem-tools.sh.tmpl "$tmp_dir/run_onchange_after_50-sync-ecosystem-tools.sh"
syntax_check bash "$tmp_dir/run_onchange_after_50-sync-ecosystem-tools.sh"
assert_file_contains "$tmp_dir/run_onchange_after_50-sync-ecosystem-tools.sh" "install_error_trap"

render_template .chezmoiscripts/run_onchange_after_60-check.sh.tmpl "$tmp_dir/run_onchange_after_60-check.sh"
syntax_check bash "$tmp_dir/run_onchange_after_60-check.sh"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "install_error_trap"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "Core tools in this environment"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "print_version_line chezmoi"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "print_version_line git"
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "print_diagnostic_hints"

log_step "🤖" "Verifying docs and repo-only files stay undeployed..."
managed_listing="$(chezmoi managed --source="$repo_root")"
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
log_step "🧩" "Running manifest contract checks..."
check_tool_manifest_parser "$repo_root/bootstrap/manifests/ecosystem/go-tools.txt" go_tool_binary_name
check_tool_manifest_parser "$repo_root/bootstrap/manifests/ecosystem/uv-tools.txt" uv_tool_binary_name
check_oh_my_zsh_manifest_contract "$repo_root/bootstrap/manifests/shell/oh-my-zsh-plugins.txt" "$tmp_dir/dot_zshrc"
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
assert_file_contains "$tmp_dir/run_onchange_after_30-install-mise.sh" "dotfiles_apply_mirror_env"
assert_file_contains "$tmp_dir/run_onchange_after_30-install-mise.sh" "DOTFILES_MISE_INSTALL_URL"

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
assert_file_contains "$repo_root/dot_config/mise/config.toml.tmpl" "[settings]"
assert_file_contains "$repo_root/dot_config/mise/config.toml.tmpl" "github_attestations = false"
assert_file_contains "$repo_root/dot_config/mise/config.toml.tmpl" "[settings.aqua]"

log_step "🔍" "Running shellcheck on bootstrap scripts..."
shellcheck "$repo_root/bootstrap/scripts/common.sh" \
  "$repo_root/bootstrap/scripts/go-env.sh" \
  "$repo_root/bootstrap/scripts/install-apt-packages.sh" \
  "$repo_root/bootstrap/scripts/install-brew-packages.sh" \
  "$repo_root/bootstrap/scripts/install-go-tools.sh" \
  "$repo_root/bootstrap/scripts/install-oh-my-zsh-assets.sh" \
  "$repo_root/bootstrap/scripts/install-uv-tools.sh" \
  "$repo_root/bootstrap/scripts/lint-public-boundary.sh" \
  "$repo_root/bootstrap/scripts/mirrors.sh" \
  "$repo_root/bootstrap/scripts/sync-public-into-internal.sh" \
  "$repo_root/bootstrap/scripts/uninstall.sh" \
  "$repo_root/bootstrap/scripts/run-smoke-tests.sh"

log_step "✅" "Smoke tests passed."
