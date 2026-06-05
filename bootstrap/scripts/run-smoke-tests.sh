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
  # .name / .email / .isWsl explode on a fresh CI runner where
  # `chezmoi init` has never run. Values are fake-but-well-formed; real
  # users supply their own at init time.
  chezmoi --source="$repo_root" \
    --override-data-file "$tmp_data_file" \
    execute-template \
    --file "$repo_root/$template_path" >"$output_path"
}

# Render .chezmoi.toml.tmpl specifically. That template uses
# `promptStringOnce`, which is only wired up under `chezmoi init` (or
# `execute-template --init`). Using render_template() on it fails with
# `function "promptStringOnce" not defined`. This helper exists so
# smoke can exercise the WSL detection logic living in the init
# template without hacking the general renderer.
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
#   - `name` / `email` / `isWsl` mirror the shape that `.chezmoi.toml.tmpl`
#     produces after `chezmoi init`, which normal templates (dot_gitconfig,
#     shell env, etc.) read via .name / .email / .isWsl.
#   - `gitName` / `gitEmail` short-circuit the `promptStringOnce` calls in
#     `.chezmoi.toml.tmpl` itself so render_chezmoi_toml_tmpl can run
#     non-interactively.
#
# isWsl tracks DOTFILES_FORCE_WSL so the WSL-shaped CI job (which exports
# DOTFILES_FORCE_WSL=1) actually renders every downstream template with
# .isWsl = true. Without this, the WSL job would only be testing the
# four `.chezmoi.toml.tmpl` arms inside the escape-hatch block below
# and every other render_template call would silently stay on the
# non-WSL arm.
smoke_is_wsl=false
case "${DOTFILES_FORCE_WSL:-}" in
1 | true | yes)
  smoke_is_wsl=true
  ;;
esac
tmp_data_file="$tmp_dir/chezmoi-data.toml"
cat >"$tmp_data_file" <<EOF
name = "Smoke Tests"
email = "smoke@example.com"
isWsl = $smoke_is_wsl
gitName = "Smoke Tests"
gitEmail = "smoke@example.com"
EOF
unset smoke_is_wsl

# Literal strings asserted against rendered templates.
# shellcheck disable=SC2016
shared_work_env_literal='${XDG_CONFIG_HOME:-$HOME/.config}/work/env.sh'
# shellcheck disable=SC2016
zsh_work_env_literal='$HOME/.zsh/work.zsh'

log_step "🧪" "Running local smoke tests..."

log_step "📝" "Rendering and checking shell templates..."
render_template dot_zshrc.tmpl "$tmp_dir/dot_zshrc"
syntax_check zsh "$tmp_dir/dot_zshrc"
assert_file_contains "$tmp_dir/dot_zshrc" "\$HOME/.zshrc.secrets"
assert_file_contains "$tmp_dir/dot_zshrc" "\$HOME/.zsh/work.zsh"

render_template dot_zprofile.tmpl "$tmp_dir/dot_zprofile"
syntax_check zsh "$tmp_dir/dot_zprofile"

render_template dot_zsh/env.zsh.tmpl "$tmp_dir/env.zsh"
syntax_check zsh "$tmp_dir/env.zsh"
assert_file_contains "$tmp_dir/env.zsh" "$shared_work_env_literal"
assert_file_not_contains "$tmp_dir/env.zsh" "$zsh_work_env_literal"

render_template dot_bashrc.tmpl "$tmp_dir/dot_bashrc"
syntax_check bash "$tmp_dir/dot_bashrc"
assert_file_contains "$tmp_dir/dot_bashrc" "\$HOME/.bashrc.secrets"
assert_file_contains "$tmp_dir/dot_bashrc" "\$HOME/.bash/work.bash"

render_template dot_bash/env.bash.tmpl "$tmp_dir/env.bash"
syntax_check bash "$tmp_dir/env.bash"
assert_file_contains "$tmp_dir/env.bash" "$shared_work_env_literal"

syntax_check sh "$repo_root/dot_profile"

render_template dot_gitconfig.tmpl "$tmp_dir/dot_gitconfig"
assert_file_contains "$tmp_dir/dot_gitconfig" "path = ~/.gitconfig.local"
assert_file_not_contains "$tmp_dir/dot_gitconfig" 'git.garena.com'
assert_file_contains "$repo_root/bootstrap/scripts/common.sh" "$shared_work_env_literal"

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
assert_file_contains "$tmp_dir/run_onchange_after_60-check.sh" "Diagnostic hints"

log_step "🤖" "Verifying docs and repo-only files stay undeployed..."
managed_listing="$(chezmoi managed --source="$repo_root")"
if grep -Fq 'local-overlay-examples' <<<"$managed_listing"; then
  fail_test "chezmoi managed lists something under docs/local-overlay-examples/ (examples must stay undeployed)"
fi
undeployed_path="$HOME/CHANGELOG.md"
if grep -Fxq "$undeployed_path" <<<"$managed_listing"; then
  fail_test "chezmoi managed lists ${undeployed_path#"$HOME"/} (repo-only files must stay undeployed)"
fi
if grep -Fq "$HOME/_skynet" <<<"$managed_listing"; then
  fail_test "chezmoi managed lists something under _skynet/ (repo-only tooling must stay undeployed)"
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

log_step "🪟" "Verifying WSL detection and DOTFILES_FORCE_WSL escape hatch..."

# The baseline `.chezmoi.toml.tmpl` probes /proc/version for the
# "microsoft" marker to decide isWsl. We add DOTFILES_FORCE_WSL as an
# explicit override (accepts 1/true/yes to force on, 0/false/no to
# force off; any other value falls through to the probe). These
# assertions exercise every arm, including the fall-through, by saving
# the caller's value once and driving each branch explicitly.
_saved_force_wsl="${DOTFILES_FORCE_WSL+"$DOTFILES_FORCE_WSL"}"
unset DOTFILES_FORCE_WSL

tmp_wsl_probe="$tmp_dir/chezmoi-toml.probe"
tmp_wsl_on="$tmp_dir/chezmoi-toml.force-on"
tmp_wsl_off="$tmp_dir/chezmoi-toml.force-off"
tmp_wsl_garbage="$tmp_dir/chezmoi-toml.garbage"

render_chezmoi_toml_tmpl "$tmp_wsl_probe"
if ! grep -Eq '^[[:space:]]*isWsl = (true|false)' "$tmp_wsl_probe"; then
  fail_test ".chezmoi.toml.tmpl must emit 'isWsl = true|false' (got: $(grep -E '^[[:space:]]*isWsl' "$tmp_wsl_probe" || printf '<missing>'))"
fi
assert_file_contains "$tmp_wsl_probe" "[status]"
assert_file_contains "$tmp_wsl_probe" 'exclude = ["scripts"]'
assert_file_contains "$repo_root/dot_config/mise/config.toml.tmpl" "[settings]"
assert_file_contains "$repo_root/dot_config/mise/config.toml.tmpl" "github_attestations = false"
assert_file_contains "$repo_root/dot_config/mise/config.toml.tmpl" "[settings.aqua]"

DOTFILES_FORCE_WSL=1 render_chezmoi_toml_tmpl "$tmp_wsl_on"
if ! grep -Eq '^[[:space:]]*isWsl = true[[:space:]]*$' "$tmp_wsl_on"; then
  fail_test "DOTFILES_FORCE_WSL=1 did not flip isWsl to true"
fi

DOTFILES_FORCE_WSL=0 render_chezmoi_toml_tmpl "$tmp_wsl_off"
if ! grep -Eq '^[[:space:]]*isWsl = false[[:space:]]*$' "$tmp_wsl_off"; then
  fail_test "DOTFILES_FORCE_WSL=0 did not explicitly set isWsl to false"
fi

# Fall-through: anything that is not a recognised true/false keyword
# must behave exactly like the probe-only case so a stray "maybe"
# doesn't silently flip behaviour.
DOTFILES_FORCE_WSL=maybe render_chezmoi_toml_tmpl "$tmp_wsl_garbage"
if ! diff -q "$tmp_wsl_probe" "$tmp_wsl_garbage" >/dev/null; then
  fail_test "DOTFILES_FORCE_WSL=maybe must fall through to the probe (got different output from probe-only baseline)"
fi

# Cheap shape invariant: force-on and force-off diverge only on the
# isWsl line. If the hatch ever leaks into name/email rendering, this
# trips.
differing_lines="$(diff "$tmp_wsl_on" "$tmp_wsl_off" | grep -c '^[<>]' || true)"
if [[ "$differing_lines" != "2" ]]; then
  fail_test "force-on vs force-off should differ by exactly one line pair (got $differing_lines changed lines; isWsl should be the only delta)"
fi

# Restore the caller's DOTFILES_FORCE_WSL so any later smoke checks keep
# the shape the CI job asked for.
if [[ -n "${_saved_force_wsl+x}" ]]; then
  export DOTFILES_FORCE_WSL="$_saved_force_wsl"
fi
unset _saved_force_wsl

log_step "🔍" "Running shellcheck on bootstrap scripts..."
shellcheck "$repo_root/bootstrap/scripts/common.sh" \
  "$repo_root/bootstrap/scripts/go-env.sh" \
  "$repo_root/bootstrap/scripts/install-apt-packages.sh" \
  "$repo_root/bootstrap/scripts/install-brew-packages.sh" \
  "$repo_root/bootstrap/scripts/install-go-tools.sh" \
  "$repo_root/bootstrap/scripts/install-oh-my-zsh-assets.sh" \
  "$repo_root/bootstrap/scripts/install-uv-tools.sh" \
  "$repo_root/bootstrap/scripts/mirrors.sh" \
  "$repo_root/bootstrap/scripts/uninstall.sh" \
  "$repo_root/bootstrap/scripts/run-smoke-tests.sh"

log_step "✅" "Smoke tests passed."
