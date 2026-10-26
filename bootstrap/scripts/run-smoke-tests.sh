#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bootstrap_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$bootstrap_dir/.." && pwd)"
real_home="$(cd "$HOME" && pwd -P)"
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

# The zsh-completions fallback must sit after user completions and before
# oh-my-zsh runs compinit.
check_zsh_completions_fpath_order() {
  local rendered_zshrc="$1"
  local fallback_path="$2"
  local user_fpath_line=""
  local fallback_fpath_line=""
  local omz_source_line=""

  # shellcheck disable=SC2016
  user_fpath_line="$(grep -nF 'fpath=("$XDG_DATA_HOME/zsh/site-functions" $fpath)' "$rendered_zshrc" | cut -d: -f1)"
  fallback_fpath_line="$(grep -nF "$fallback_path" "$rendered_zshrc" | cut -d: -f1)"
  # shellcheck disable=SC2016
  omz_source_line="$(grep -nF 'source "$ZSH/oh-my-zsh.sh"' "$rendered_zshrc" | cut -d: -f1)"
  if [[ -z "$user_fpath_line" || -z "$fallback_fpath_line" || -z "$omz_source_line" \
    || "$user_fpath_line" -ge "$fallback_fpath_line" || "$fallback_fpath_line" -ge "$omz_source_line" ]]; then
    fail_test "Zsh completion fpath precedence must be user, system/oh-my-zsh, then zsh-completions fallback"
  fi
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
      assert_file_not_contains "$rendered_zshrc" "    zsh-completions"
      check_zsh_completions_fpath_order "$rendered_zshrc" "$plugin_path/src"
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

# Stand-in chezmoi data for template rendering. `name`, `email`, and
# `desktopBaseline` are the keys `.chezmoi.toml.tmpl` stores after
# `chezmoi init`; the init-template check reads them back instead of prompting.
# `desktopPlatformSupported` and `desktopFontFamily` are what xdg-config.sh
# injects into the nested XDG source.
desktop_font_manifest="$repo_root/bootstrap/manifests/desktop/maple-mono-nf-cn.env"
desktop_font_manifest_load "$desktop_font_manifest"
tmp_data_file="$tmp_dir/chezmoi-data.toml"
cat >"$tmp_data_file" <<EOF
name = "Smoke Tests"
email = "smoke@example.com"
desktopBaseline = true
desktopPlatformSupported = $desktop_platform_supported_data
desktopFontFamily = "$MAPLE_MONO_FAMILY"
EOF

# Synthetic chezmoi platform data for boundary renders. --override-data merges
# into the host data, so every osRelease field the templates read is explicit.
darwin_chezmoi_data='{"os":"darwin","osRelease":null,"kernel":null}'
supported_linux_chezmoi_data='{"os":"linux","osRelease":{"id":"ubuntu","versionID":"99.04","idLike":""},"kernel":{"osrelease":"linux"}}'
wsl_chezmoi_data='{"os":"linux","osRelease":{"id":"ubuntu","versionID":"99.04","idLike":""},"kernel":{"osrelease":"microsoft-standard-WSL2"}}'
unsupported_chezmoi_data='{"os":"linux","osRelease":{"id":"unsupported-smoke-distro","idLike":"","versionID":""},"kernel":{"osrelease":"linux"}}'

# Literal strings asserted against rendered templates.
shared_secrets_literal="$(local_overlay_location secrets)"
env_overlay_literal="$(local_overlay_location env)"
bootstrap_overlay_literal="$(local_overlay_location bootstrap_env)"
zsh_overlay_literal="$(local_overlay_location zshrc)"
bash_overlay_literal="$(local_overlay_location bashrc)"
gitconfig_overlay_literal="$(local_overlay_location gitconfig)"
ssh_overlay_literal="$(local_overlay_location ssh_config)"
ghostty_overlay_literal="$(local_overlay_location ghostty)"
gitconfig_include_path="$(local_overlay_expand "$gitconfig_overlay_literal" exact)"
gitconfig_include_literal="path = \"$gitconfig_include_path\""
ssh_include_literal="Include ~/${ssh_overlay_literal#\$HOME/}"
ghostty_include_literal="config-file = ?${ghostty_overlay_literal##*/}"
# shellcheck disable=SC2016
xdg_source_literal='source "$HOME/.local/share/oh-my-devenv/xdg.sh"'

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
synthetic_macos_zshrc="$tmp_dir/dot_zshrc.macos"
chezmoi --source="$repo_root" \
  --override-data '{"chezmoi":{"os":"darwin","osRelease":null,"kernel":null}}' \
  execute-template --file "$repo_root/dot_zshrc.tmpl" >"$synthetic_macos_zshrc"
syntax_check zsh "$synthetic_macos_zshrc"
# shellcheck disable=SC2016
assert_file_contains "$synthetic_macos_zshrc" 'fpath+=("$HOMEBREW_PREFIX/share/zsh/site-functions")'

syntax_check zsh "$repo_root/dot_zprofile"

render_template dot_zsh/env.zsh.tmpl "$tmp_dir/env.zsh"
syntax_check zsh "$tmp_dir/env.zsh"
assert_file_contains "$tmp_dir/env.zsh" "$xdg_source_literal"
assert_file_contains "$tmp_dir/env.zsh" "oh_my_devenv_setup_xdg_dirs"
assert_file_contains "$tmp_dir/env.zsh" "oh_my_devenv_source_env_file"
assert_file_contains "$tmp_dir/env.zsh" "$env_overlay_literal"
assert_file_not_contains "$tmp_dir/env.zsh" "$bootstrap_overlay_literal"
assert_file_not_contains "$tmp_dir/env.zsh" "$shared_secrets_literal"
assert_file_not_contains "$tmp_dir/env.zsh" "$zsh_overlay_literal"

# The oh-my-zsh location comes from the shared resolver; inherited ZSH and
# ZSH_CUSTOM values must not redirect the zshrc or the installer.
omz_home="$tmp_dir/omz-home"
omz_elsewhere="$tmp_dir/omz-elsewhere"
mkdir -p "$omz_home/.zsh" "$omz_home/.local/share/oh-my-devenv" "$tmp_dir/omz-empty-config"
cp "$xdg_resolver" "$omz_home/.local/share/oh-my-devenv/xdg.sh"
cp "$tmp_dir/env.zsh" "$omz_home/.zsh/env.zsh"
cp "$tmp_dir/dot_zshrc" "$omz_home/.zshrc"
omz_dir="$(HOME="$omz_home" bash -c 'source "$1"; oh_my_devenv_oh_my_zsh_dir' _ "$xdg_resolver")"
mkdir -p "$omz_dir"
# The stub stops the shell after reporting, so the rest of the zshrc never
# initializes host tools such as mise or fzf.
# shellcheck disable=SC2016
printf 'print -r -- "$ZSH|$ZSH_CUSTOM"\nexit 0\n' >"$omz_dir/oh-my-zsh.sh"
# shellcheck disable=SC2016
omz_loaded="$(env -i HOME="$omz_home" PATH=/usr/bin:/bin XDG_CONFIG_HOME="$tmp_dir/omz-empty-config" \
  ZSH="$omz_elsewhere" ZSH_CUSTOM="$omz_elsewhere/custom" \
  zsh -fc 'source "$HOME/.zshrc"')"
[[ "$omz_loaded" == "$omz_dir|$omz_dir/custom" ]] \
  || fail_test "zshrc loaded oh-my-zsh as '$omz_loaded'; expected '$omz_dir|$omz_dir/custom'"

omz_stub_bin="$tmp_dir/omz-stub-bin"
omz_git_log="$tmp_dir/omz-git.log"
mkdir -p "$omz_stub_bin"
cat >"$omz_stub_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${!#}"
printf '%s\n' "$target" >>"$OMZ_GIT_LOG"
mkdir -p "$target/.git"
EOF
chmod +x "$omz_stub_bin/git"
ln -s "$(command -v zsh)" "$omz_stub_bin/zsh"
printf '%s\n' 'example/plugin plugins/example-plugin' >"$tmp_dir/omz-plugins.txt"
env -i HOME="$omz_home" PATH="$omz_stub_bin:/usr/bin:/bin" XDG_CONFIG_HOME="$tmp_dir/omz-empty-config" \
  ZSH="$omz_elsewhere" ZSH_CUSTOM="$omz_elsewhere/custom" OMZ_GIT_LOG="$omz_git_log" \
  bash "$repo_root/bootstrap/scripts/install-oh-my-zsh-assets.sh" "$tmp_dir/omz-plugins.txt" >/dev/null
printf '%s\n' "$omz_dir/custom/plugins/example-plugin" >"$tmp_dir/omz-git.expected"
# The fixture oh-my-zsh directory already exists without .git, so only the
# plugin is cloned; the installer must target the resolved custom directory.
cmp -s "$tmp_dir/omz-git.expected" "$omz_git_log" \
  || fail_test "oh-my-zsh installer cloned into: $(<"$omz_git_log")"
[[ ! -e "$omz_elsewhere" ]] || fail_test "oh-my-zsh installer followed an inherited ZSH or ZSH_CUSTOM"

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
syntax_check bash "$repo_root/dot_bash_profile"

# Login shells must load the shared overlay even though .bashrc returns early
# for non-interactive shells. Source the exact login entry in a clean Bash
# without host /etc/profile or dotfiles; every managed dependency is a fixture.
login_home="$tmp_dir/login-home"
mkdir -p "$login_home/.bash" "$login_home/.config/oh-my-devenv" "$login_home/.local/share/oh-my-devenv"
cp "$repo_root/dot_bash_profile" "$login_home/.bash_profile"
cp "$repo_root/dot_profile" "$login_home/.profile"
cp "$xdg_resolver" "$login_home/.local/share/oh-my-devenv/xdg.sh"
cp "$tmp_dir/env.bash" "$login_home/.bash/env.bash"
cp "$tmp_dir/dot_bashrc" "$login_home/.bashrc"
printf 'overlay_probe() { printf "loaded"; }\n' >"$login_home/.config/oh-my-devenv/env.sh"
# shellcheck disable=SC2016
login_overlay="$(env -u __BASH_ENV_DONE HOME="$login_home" XDG_CONFIG_HOME="$login_home/.config" \
  bash --noprofile --norc -c '. "$HOME/.bash_profile"; overlay_probe')"
[[ "$login_overlay" == loaded ]] || fail_test "non-interactive login shells must load the env.sh overlay"

# path_reorder_front is the PATH API for the shared env.sh overlay. Both shells
# run the same overlay and scenario through their deployed login entry in a
# clean fixture HOME, and must report the same fixture-only PATH projection.
# Fixture names include spaces, glob metacharacters, and decoys they would
# match as patterns; the inherited PATH holds adjacent and scattered duplicates.
# Nonfixture entries must keep their order through every move, and calls that
# move nothing must leave PATH byte-for-byte unchanged. Empty entries (the
# current directory) are kept in Bash; Zsh deduplicates them via typeset -U.
path_root="$tmp_dir/path-fixture"
for path_fixture_dir in a b c d gx 'g*' qz 'q?' '[c]' 'with space'; do
  mkdir -p "$path_root/$path_fixture_dir"
done
path_inherited="$path_root/a:$path_root/a:$path_root/b:$path_root/c:$path_root/gx:$path_root/g*"
path_inherited="$path_inherited:$path_root/qz:$path_root/q?:$path_root/with space:$path_root/[c]"
path_inherited="$path_inherited:$path_root/d:$path_root/c:/usr/bin:/bin"
path_overlay="$tmp_dir/path-overlay.sh"
cat >"$path_overlay" <<'EOF'
path_overlay_loads=$(( ${path_overlay_loads:-0} + 1 ))
root="$OH_MY_DEVENV_SMOKE_PATH_ROOT"
[ -n "${path_before_overlay+set}" ] || path_before_overlay="$PATH"
path_reorder_front "$root/c" "$root/a" "" "$root/missing" "$root/c"
EOF
path_scenario="$tmp_dir/path-scenario.sh"
cat >"$path_scenario" <<'EOF'
report() { printf '%s|%s\n' "$1" "$2"; }
root="$OH_MY_DEVENV_SMOKE_PATH_ROOT"
report before-overlay "$path_before_overlay"
report overlay "$PATH"
report child "$("$OH_MY_DEVENV_SMOKE_SHELL" "$OH_MY_DEVENV_SMOKE_SHELL_FLAG" -c '. "$HOME/$1"; printf "%s" "$PATH"' _ "$OH_MY_DEVENV_SMOKE_ENTRY")"
path_reorder_front "$root/g*" "$root/q?" "$root/[c]" "$root/with space"
report literal "$PATH"
path_reorder_front "$root/g*" "$root/q?" "$root/[c]" "$root/with space"
report repeated-call "$PATH"
path_reorder_front
report no-args "$PATH"
path_reorder_front "" "$root/missing" "$root/*"
report skipped "$PATH"
. "$HOME/$OH_MY_DEVENV_SMOKE_ENV"
report resourced "$PATH"
report overlay-loads "$path_overlay_loads"
report sentinels "$i:$d:$dir:$entry:$keep"
(
  cd "$root" || exit 1
  for edge in "" "a:" ":a" "::" ":b::a:"; do
    PATH="$edge"
    path_reorder_front a
    report "edge:[$edge]" "$PATH"
  done
)
EOF

path_projection() {
  local output="$1"
  local line label value entry projected nonfixture baseline="" literal=""
  local -a entries

  while IFS= read -r line; do
    label="${line%%|*}"
    value="${line#*|}"
    case "$label" in
      overlay-loads | sentinels | functions | edge:*)
        printf '%s|%s\n' "$label" "$value"
        continue
        ;;
    esac
    projected=""
    nonfixture=""
    IFS=: read -r -a entries <<<"$value"
    for entry in "${entries[@]}"; do
      if [[ "$entry" == "$path_root"/* ]]; then
        projected="${projected:+$projected:}${entry#"$path_root"/}"
      else
        nonfixture="$nonfixture:$entry"
      fi
    done
    # The pre-overlay PATH only supplies the nonfixture baseline; its fixture
    # order depends on each shell's own deduplication.
    if [[ "$label" == before-overlay ]]; then
      baseline="$nonfixture"
      continue
    fi
    printf '%s|%s\n' "$label" "$projected"
    [[ "$nonfixture" == "$baseline" ]] || printf '%s-nonfixture|%s\n' "$label" "$nonfixture"
    case "$label" in
      literal) literal="$value" ;;
      repeated-call | no-args | skipped | resourced)
        [[ "$value" == "$literal" ]] || printf '%s-full|%s\n' "$label" "$value"
        ;;
    esac
  done <<<"$output"
}

path_expected_overlay='c:a:b:gx:g*:qz:q?:with space:[c]:d'
path_expected_literal='g*:q?:[c]:with space:c:a:b:gx:qz:d'
path_expected="$(printf '%s\n' \
  "functions|path_reorder_front" \
  "overlay|$path_expected_overlay" \
  "child|$path_expected_overlay" \
  "literal|$path_expected_literal" \
  "repeated-call|$path_expected_literal" \
  "no-args|$path_expected_literal" \
  "skipped|$path_expected_literal" \
  "resourced|$path_expected_literal" \
  "overlay-loads|1" \
  "sentinels|sentinel:sentinel:sentinel:sentinel:sentinel")"
# Edge inputs move fixture "a" (relative to the fixture root) past empty entries.
path_expected_edges_shared="$(printf '%s\n' \
  "edge:[]|a:" \
  "edge:[a:]|a:" \
  "edge:[:a]|a:")"
path_expected_edges_bash="$(printf '%s\n' \
  "edge:[::]|a:::" \
  "edge:[:b::a:]|a::b::")"
path_expected_edges_zsh="$(printf '%s\n' \
  "edge:[::]|a:" \
  "edge:[:b::a:]|a::b")"

bash_bin="$(command -v bash)"
zsh_bin="$(command -v zsh)"
for path_shell in bash zsh; do
  path_home="$tmp_dir/path-home-$path_shell"
  mkdir -p "$path_home/.config/oh-my-devenv" "$path_home/.local/share/oh-my-devenv"
  cp "$xdg_resolver" "$path_home/.local/share/oh-my-devenv/xdg.sh"
  cp "$path_overlay" "$path_home/.config/oh-my-devenv/env.sh"
  if [[ "$path_shell" == bash ]]; then
    mkdir -p "$path_home/.bash"
    cp "$repo_root/dot_bash_profile" "$path_home/.bash_profile"
    cp "$repo_root/dot_profile" "$path_home/.profile"
    cp "$tmp_dir/env.bash" "$path_home/.bash/env.bash"
    cp "$tmp_dir/dot_bashrc" "$path_home/.bashrc"
    path_shell_bin="$bash_bin"
    path_shell_flag=--norc
    path_entry=.bash_profile
    path_env=.bash/env.bash
    # shellcheck disable=SC2016
    path_functions='compgen -A function path_'
    path_shell_expected="$path_expected
$path_expected_edges_shared
$path_expected_edges_bash"
  else
    mkdir -p "$path_home/.zsh"
    cp "$repo_root/dot_zprofile" "$path_home/.zprofile"
    cp "$tmp_dir/env.zsh" "$path_home/.zsh/env.zsh"
    path_shell_bin="$zsh_bin"
    path_shell_flag=-f
    path_entry=.zprofile
    path_env=.zsh/env.zsh
    # shellcheck disable=SC2016
    path_functions='print -rl -- ${(ok)functions[(I)path_*]}'
    path_shell_expected="$path_expected
$path_expected_edges_shared
$path_expected_edges_zsh"
  fi
  # shellcheck disable=SC2016
  path_command='i=sentinel d=sentinel dir=sentinel entry=sentinel keep=sentinel
. "$HOME/$OH_MY_DEVENV_SMOKE_ENTRY"
for f in $('"$path_functions"'); do printf "functions|%s\n" "$f"; done
. "$1"'
  path_output="$(env -i HOME="$path_home" PATH="$path_inherited" \
    OH_MY_DEVENV_SMOKE_PATH_ROOT="$path_root" OH_MY_DEVENV_SMOKE_SHELL="$path_shell_bin" \
    OH_MY_DEVENV_SMOKE_SHELL_FLAG="$path_shell_flag" \
    OH_MY_DEVENV_SMOKE_ENTRY="$path_entry" OH_MY_DEVENV_SMOKE_ENV="$path_env" \
    "$path_shell_bin" "$path_shell_flag" -c "$path_command" _ "$path_scenario" 2>"$tmp_dir/path-$path_shell.err")" \
    || fail_test "$path_shell path_reorder_front scenario exited with status $?"
  [[ ! -s "$tmp_dir/path-$path_shell.err" ]] \
    || fail_test "$path_shell path_reorder_front scenario wrote to stderr: $(cat "$tmp_dir/path-$path_shell.err")"
  path_actual="$(path_projection "$path_output")"
  if [[ "$path_actual" != "$path_shell_expected" ]]; then
    printf 'Expected:\n%s\nActual:\n%s\n' "$path_shell_expected" "$path_actual" >&2
    fail_test "$path_shell path_reorder_front contract mismatch"
  fi
done

# Bash directory comparison must stay case-sensitive under nocasematch, and the
# caller's option state must survive every call. Foo and foo are distinct PATH
# strings even where the filesystem folds them to one directory. The CPU limit
# bounds a scenario that loops instead of making progress.
mkdir -p "$path_root/Foo" "$path_root/foo"
# shellcheck disable=SC2016
path_case_command='. "$HOME/.bash/env.bash"
r="$OH_MY_DEVENV_SMOKE_PATH_ROOT"
shopt -s nocasematch
PATH="$r/foo:$r/Foo::$r/foo:$r/keep:$r/Foo"
path_reorder_front "$r/Foo"; printf "upper|%s\n" "$PATH"
path_reorder_front "$r/Foo"; printf "repeated-call|%s\n" "$PATH"
path_reorder_front "$r/foo" "$r/Foo"; printf "both|%s\n" "$PATH"
path_reorder_front "$r/Foo" "$r/foo"; printf "both-reversed|%s\n" "$PATH"
path_reorder_front "" "$r/missing"; printf "skipped|%s\n" "$PATH"
path_reorder_front; printf "no-args|%s\n" "$PATH"
shopt -q nocasematch && printf "option|enabled\n"
shopt -u nocasematch
path_reorder_front "$r/foo"; printf "disabled|%s\n" "$PATH"
shopt -q nocasematch || printf "option|disabled\n"'
path_case_output="$(
  ulimit -t 10
  env -i HOME="$tmp_dir/path-home-bash" PATH="$path_inherited" \
    OH_MY_DEVENV_SMOKE_PATH_ROOT="$path_root" \
    "$bash_bin" --norc -c "$path_case_command" 2>"$tmp_dir/path-case.err"
)" || fail_test "bash nocasematch path_reorder_front scenario exited with status $?"
[[ ! -s "$tmp_dir/path-case.err" ]] \
  || fail_test "bash nocasematch path_reorder_front scenario wrote to stderr: $(cat "$tmp_dir/path-case.err")"
path_case_expected="$(printf '%s\n' \
  "upper|$path_root/Foo:$path_root/foo::$path_root/foo:$path_root/keep" \
  "repeated-call|$path_root/Foo:$path_root/foo::$path_root/foo:$path_root/keep" \
  "both|$path_root/foo:$path_root/Foo::$path_root/keep" \
  "both-reversed|$path_root/Foo:$path_root/foo::$path_root/keep" \
  "skipped|$path_root/Foo:$path_root/foo::$path_root/keep" \
  "no-args|$path_root/Foo:$path_root/foo::$path_root/keep" \
  "option|enabled" \
  "disabled|$path_root/foo:$path_root/Foo::$path_root/keep" \
  "option|disabled")"
if [[ "$path_case_output" != "$path_case_expected" ]]; then
  printf 'Expected:\n%s\nActual:\n%s\n' "$path_case_expected" "$path_case_output" >&2
  fail_test "bash path_reorder_front must compare directories case-sensitively under nocasematch"
fi

# Both shells put the mise shim directory first, resolved with mise's own
# precedence: MISE_SHIMS_DIR, then MISE_DATA_DIR, then XDG_DATA_HOME.
# The fixture root contains spaces so every path stays a single argument.
mise_root="$tmp_dir/mise shims fixture"
mise_home="$mise_root/home"
# The default data root comes from the XDG resolver, which has its own tests;
# only mise's "<data root>/mise/shims" layout is asserted here.
# shellcheck disable=SC2016
mise_default_data="$(env -i HOME="$mise_home" bash -c 'source "$1"; oh_my_devenv_resolve_xdg_data_home' _ "$xdg_resolver")"
mkdir -p "$mise_default_data/mise/shims" "$mise_root/xdg-data/mise/shims" \
  "$mise_root/mise-data/shims" "$mise_root/shims-override" "$mise_root/empty-config"
cp "$tmp_dir/env.bash" "$mise_root/env.bash"
cp "$tmp_dir/env.zsh" "$mise_root/env.zsh"
mkdir -p "$mise_home/.local/share/oh-my-devenv"
cp "$xdg_resolver" "$mise_home/.local/share/oh-my-devenv/xdg.sh"
for mise_case in default xdg-data mise-data shims-dir; do
  mise_env=()
  case "$mise_case" in
    default)
      expected_shims="$mise_default_data/mise/shims"
      ;;
    xdg-data)
      mise_env=("XDG_DATA_HOME=$mise_root/xdg-data")
      expected_shims="$mise_root/xdg-data/mise/shims"
      ;;
    mise-data)
      mise_env=("XDG_DATA_HOME=$mise_root/xdg-data" "MISE_DATA_DIR=$mise_root/mise-data")
      expected_shims="$mise_root/mise-data/shims"
      ;;
    shims-dir)
      mise_env=("MISE_DATA_DIR=$mise_root/mise-data" "MISE_SHIMS_DIR=$mise_root/shims-override")
      expected_shims="$mise_root/shims-override"
      ;;
  esac
  for mise_shell in bash zsh; do
    # shellcheck disable=SC2016
    actual_shims="$(env -i HOME="$mise_home" PATH=/usr/bin:/bin XDG_CONFIG_HOME="$mise_root/empty-config" \
      ${mise_env[@]+"${mise_env[@]}"} \
      "$mise_shell" -c '. "$1"; printf "%s\n" "${PATH%%:*}"' _ "$mise_root/env.$mise_shell")"
    [[ "$actual_shims" == "$expected_shims" ]] \
      || fail_test "$mise_shell mise shims for $mise_case resolved to '$actual_shims'; expected '$expected_shims'"
  done
done

render_template dot_gitconfig.tmpl "$tmp_dir/dot_gitconfig"
assert_file_contains "$tmp_dir/dot_gitconfig" "$gitconfig_include_literal"
# The managed gitconfig must stay host-neutral: no hard-coded URL rewrites, so
# the baseline carries no organization-specific Git routing.
assert_file_not_contains "$tmp_dir/dot_gitconfig" 'insteadOf'

render_template private_dot_ssh/private_config.tmpl "$tmp_dir/private_dot_ssh_config"
assert_file_contains "$tmp_dir/private_dot_ssh_config" "$ssh_include_literal"

log_step "📜" "Rendering and checking chezmoi hooks..."
# Render every hook for synthetic platforms so each package-manager and desktop
# template arm is syntax-checked and linted on any host.
hook_platforms=(
  "macos|$darwin_chezmoi_data"
  "ubuntu|$supported_linux_chezmoi_data"
  'debian|{"os":"linux","osRelease":{"id":"debian","versionID":"13","idLike":""},"kernel":{"osrelease":"linux"}}'
  'arch|{"os":"linux","osRelease":{"id":"arch","idLike":"","versionID":""},"kernel":{"osrelease":"linux"}}'
  "wsl|$wsl_chezmoi_data"
  "unsupported|$unsupported_chezmoi_data"
)
for hook_platform in "${hook_platforms[@]}"; do
  hook_platform_name="${hook_platform%%|*}"
  for hook_template in "$repo_root"/.chezmoiscripts/*.sh.tmpl; do
    rendered_hook="$tmp_dir/hook-$hook_platform_name-$(basename "$hook_template" .tmpl)"
    chezmoi --source="$repo_root" \
      --override-data "{\"desktopBaseline\":true,\"chezmoi\":${hook_platform#*|}}" \
      execute-template --file "$hook_template" >"$rendered_hook"
    syntax_check bash "$rendered_hook"
    shellcheck_rendered_bash "$rendered_hook"
  done
done

# Rendered hooks run below with only these commands on PATH, so a hook that
# unexpectedly reaches an installer fails instead of touching the host.
hook_stub_bin="$tmp_dir/hook-stub-bin"
mkdir -p "$hook_stub_bin" "$tmp_dir/hook-home"
for fixture_command in bash dirname; do
  ln -s "$(command -v "$fixture_command")" "$hook_stub_bin/$fixture_command"
done
run_rendered_hook() {
  env -i PATH="$hook_stub_bin" HOME="$tmp_dir/hook-home" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    bash "$tmp_dir/hook-$1-$2.sh"
}

# Unsupported systems stop in the first hooks instead of guessing a package manager.
for hook_name in run_once_before_10-bootstrap run_onchange_after_20-install-system-packages; do
  expect_failure "$tmp_dir/unsupported-hook.err" run_rendered_hook unsupported "$hook_name"
  assert_file_contains "$tmp_dir/unsupported-hook.err" "ERROR:"
done
# A requested desktop baseline on a platform without desktop support only warns.
run_rendered_hook wsl run_onchange_after_22-install-desktop-assets >/dev/null 2>"$tmp_dir/wsl-desktop.err" \
  || fail_test "desktop hook must not install anything on a platform without desktop support"
assert_file_contains "$tmp_dir/wsl-desktop.err" "Desktop baseline requested"

# The runtime hook finds mise through the resolved shim directory before any
# runtime exists and without GOBIN.
hook_mise_data="$tmp_dir/hook-mise-data"
mkdir -p "$hook_mise_data/shims"
printf '#!/bin/sh\necho "mise stub: $*"\n' >"$hook_mise_data/shims/mise"
chmod +x "$hook_mise_data/shims/mise"
env -i PATH="$hook_stub_bin" HOME="$tmp_dir/hook-home" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
  MISE_DATA_DIR="$hook_mise_data" \
  bash "$tmp_dir/hook-ubuntu-run_onchange_after_40-install-runtimes.sh" >"$tmp_dir/hook-mise.out" 2>&1 \
  || fail_test "runtime hook did not find mise in the resolved shim directory: $(<"$tmp_dir/hook-mise.out")"
assert_file_contains "$tmp_dir/hook-mise.out" "mise stub: install --yes"

# The top-level call reports an explicit function failure without errtrace.
# Bash 3.2 errtrace would also report guarded command substitutions, so verify
# both the diagnostic and the absence of that false positive.
error_trap_env=(
  HOME="$tmp_dir/hook-home"
  PATH=/usr/bin:/bin
  XDG_CONFIG_HOME="$XDG_CONFIG_HOME"
)
# shellcheck disable=SC2016
expect_failure "$tmp_dir/error-trap-function.err" \
  env -i "${error_trap_env[@]}" /bin/bash -c \
  'set -euo pipefail; source "$1"; install_error_trap smoke; failing_function() { return 1; }; failing_function' \
  _ "$script_dir/common.sh"
assert_file_contains "$tmp_dir/error-trap-function.err" "Bootstrap step failed."
# shellcheck disable=SC2016
if ! env -i "${error_trap_env[@]}" /bin/bash -c \
  'set -euo pipefail; source "$1"; install_error_trap smoke; x="$(false)" || true' \
  _ "$script_dir/common.sh" >"$tmp_dir/error-trap-guarded.out" 2>"$tmp_dir/error-trap-guarded.err"; then
  fail_test "a guarded command substitution must succeed after install_error_trap"
fi
assert_file_not_contains "$tmp_dir/error-trap-guarded.out" "Bootstrap step failed."
assert_file_not_contains "$tmp_dir/error-trap-guarded.err" "Bootstrap step failed."

# Resolve Homebrew independently of the parent PATH on macOS. The lookup stub
# keeps the fixture away from the host's standard Homebrew prefixes.
homebrew_fixture_bin="$tmp_dir/homebrew-fixture/bin"
mkdir -p "$homebrew_fixture_bin"
for fixture_command in brew mise; do
  printf '#!/bin/sh\nexit 0\n' >"$homebrew_fixture_bin/$fixture_command"
  chmod +x "$homebrew_fixture_bin/$fixture_command"
done
# shellcheck disable=SC2016
env -i "${error_trap_env[@]}" OSTYPE=darwin HOMEBREW_FIXTURE_BIN="$homebrew_fixture_bin" \
  /bin/bash -c 'set -euo pipefail; source "$1"; brew_command() { printf "%s/brew\n" "$HOMEBREW_FIXTURE_BIN"; }; export_tool_path; command -v brew; command -v mise' \
  _ "$script_dir/common.sh" >"$tmp_dir/homebrew-tool-path.out" \
  || fail_test "export_tool_path did not expose the resolved Homebrew bin directory"
printf '%s/brew\n%s/mise\n' "$homebrew_fixture_bin" "$homebrew_fixture_bin" >"$tmp_dir/homebrew-tool-path.expected"
cmp -s "$tmp_dir/homebrew-tool-path.expected" "$tmp_dir/homebrew-tool-path.out" \
  || fail_test "export_tool_path resolved unexpected Homebrew tools: $(<"$tmp_dir/homebrew-tool-path.out")"
# shellcheck disable=SC2016
env -i "${error_trap_env[@]}" OSTYPE=darwin /bin/bash -c \
  'set -euo pipefail; source "$1"; brew_command() { return 1; }; export_tool_path' \
  _ "$script_dir/common.sh" || fail_test "export_tool_path must succeed when Homebrew is absent"
# shellcheck disable=SC2016
env -i "${error_trap_env[@]}" OSTYPE=linux HOMEBREW_FIXTURE_BIN="$homebrew_fixture_bin" \
  /bin/bash -c 'set -euo pipefail; source "$1"; brew_command() { printf "%s/brew\n" "$HOMEBREW_FIXTURE_BIN"; }; export_tool_path; [[ "$PATH" == "$HOME/.local/bin:$(oh_my_devenv_mise_shims_dir):/usr/bin:/bin" ]]' \
  _ "$script_dir/common.sh" || fail_test "export_tool_path changed Linux PATH construction"

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
if [[ -s "$disabled_desktop_hook" || -s "$disabled_ghostty_config" || -s "$disabled_fontconfig_fragment" ]]; then
  fail_test "desktop templates must render zero bytes when desktopBaseline is disabled"
fi

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

# `list` reports existing owned assets, not hypothetical manifest targets.
completion_list_data="$tmp_dir/completion-list-data"
for completion_platform in linux darwin; do
  completion_listing="$(run_completion_installer "$completion_list_data" \
    list "$completion_platform" "$completion_manifest")"
  if [[ -n "$completion_listing" ]]; then
    fail_test "completion list must be empty before installation: $completion_listing"
  fi
done

# The Linux inventory uses package-owned bat/batcat completions, so the
# production Linux install runs only on Linux.
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
run_completion_installer "$synthetic_completion_data" install darwin "$synthetic_completion_manifest"
synthetic_darwin_listing="$(run_completion_installer "$synthetic_completion_data" list darwin "$synthetic_completion_manifest")"
expected_darwin_listing="$synthetic_completion_data/zsh/site-functions/_uv
$synthetic_completion_data/zsh/site-functions/_chezmoi"
if [[ "$synthetic_darwin_listing" != "$expected_darwin_listing" ]]; then
  fail_test "synthetic darwin completion inventory was: $synthetic_darwin_listing"
fi
run_completion_installer "$synthetic_completion_data" install linux "$synthetic_completion_manifest"
synthetic_linux_listing="$(run_completion_installer "$synthetic_completion_data" list linux "$synthetic_completion_manifest")"
expected_linux_listing="$synthetic_completion_data/zsh/site-functions/_uv
$synthetic_completion_data/bash-completion/completions/uv.bash
$synthetic_completion_data/zsh/site-functions/_ruff
$synthetic_completion_data/bash-completion/completions/ruff.bash"
if [[ "$synthetic_linux_listing" != "$expected_linux_listing" ]]; then
  fail_test "synthetic linux completion inventory was: $synthetic_linux_listing"
fi

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

# Registered desktop faces pass and missing faces fail. Font identities come
# from the manifest.
# These stubs are called by the extracted function, outside static analysis.
# shellcheck disable=SC2317,SC2329
(
  eval "$(sed -n '/^check_desktop_font_fontconfig() {$/,/^}$/p' "$script_dir/check.sh")"
  fc-list() {
    local face
    for face in $MAPLE_MONO_POSTSCRIPT_NAMES; do printf '%s\n' "$face"; done
  }
  errors=0
  check_desktop_font_fontconfig >/dev/null
  [[ "$errors" == 0 ]] || fail_test "registered desktop fonts must pass validation"
  fc-list() { :; }
  check_desktop_font_fontconfig >/dev/null
  [[ "$errors" == 1 ]] || fail_test "missing desktop fonts must still fail validation"
)

# The shared check helpers count every missing command and path.
(
  eval "$(sed -n '/^check_cmd() {$/,/^}$/p; /^check_path() {$/,/^}$/p' "$script_dir/check.sh")"
  errors=0
  check_cmd smoke-missing-command 2>/dev/null
  check_path "$tmp_dir/smoke-missing-path" "smoke missing path" 2>/dev/null
  [[ "$errors" == 2 ]] || fail_test "check helpers must count each missing command and path; counted $errors"
)

log_step "🔎" "Testing the standalone environment check with stubbed tools..."
check_root="$tmp_dir/check-fixture"
check_stub_bin="$check_root/bin"
check_config="$check_root/config/chezmoi/chezmoi.toml"
mkdir -p "$check_stub_bin" "$check_root/bootstrap/scripts" "$check_root/.chezmoitemplates" \
  "$check_root/dot_local/share/oh-my-devenv" "$check_root/config/mise" "$check_root/config/chezmoi" \
  "$check_root/config/ghostty" "$check_root/home/Library/Fonts"
cp "$script_dir/check.sh" "$script_dir/common.sh" "$check_root/bootstrap/scripts/"
cp -R "$repo_root/bootstrap/manifests" "$check_root/bootstrap/"
cp "$repo_root/dot_local/share/oh-my-devenv/xdg.sh" "$check_root/dot_local/share/oh-my-devenv/"
cp "$repo_root/.chezmoitemplates/system-package-manager" \
  "$repo_root/.chezmoitemplates/desktop-platform-supported" "$check_root/.chezmoitemplates/"
printf '[data]\ndesktopBaseline = true\n' >"$check_config"
printf '# fixture\n' >"$check_root/config/mise/config.toml"
printf '# fixture\n' >"$check_root/config/ghostty/config.ghostty"
printf '%s\n' "$MAPLE_MONO_POSTSCRIPT_NAMES" | tr ' ' '\n' >"$check_root/font-faces"
for font_face in $MAPLE_MONO_POSTSCRIPT_NAMES; do
  touch "$check_root/home/Library/Fonts/$font_face.ttf"
done
# Derive shell directories and ecosystem command names from the current manifests.
check_omz_dir="$(HOME="$check_root/home" XDG_DATA_HOME="$check_root/data" \
  bash -c 'source "$1"; oh_my_devenv_oh_my_zsh_dir' _ "$script_dir/common.sh")"
mkdir -p "$check_omz_dir"
touch "$check_omz_dir/oh-my-zsh.sh"
while read -r plugin_repo plugin_path _; do
  mkdir -p "$check_omz_dir/custom/$plugin_path"
done < <(manifest_entries "$repo_root/bootstrap/manifests/shell/oh-my-zsh-plugins.txt")
cat >"$check_stub_bin/check-tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name="${0##*/}"
printf '%s %s\n' "$name" "$*" >>"$CHECK_ROOT/calls"
case "$name" in
  chezmoi | selected-chezmoi)
    if [[ "${1:-}" == --version ]]; then
      printf 'chezmoi version fixture,\n'
    else
      exec "$REAL_CHEZMOI" --override-data "{\"chezmoi\":$CHECK_PLATFORM_DATA}" "$@"
    fi
    ;;
  mise)
    case "${1:-}" in
      ls) [[ "${FAIL_CHECK:-}" != mise ]] ;;
      current) printf 'smoke-runtime fixture\n' ;;
      --version) printf 'fixture\n' ;;
      *) exit 1 ;;
    esac
    ;;
  brew)
    [[ "$1 $2" == 'bundle check' ]]
    ;;
  dpkg-query) printf 'install ok installed\n' ;;
  pacman) [[ "$1" == -Q ]] ;;
  uv) [[ "$1 $2" == 'tool dir' ]] || exit 1; printf '%s/uv-tools\n' "$CHECK_ROOT" ;;
  fc-list) cat "$CHECK_ROOT/font-faces" ;;
  ghostty)
    [[ "${FAIL_CHECK:-}" != ghostty ]] || exit 1
    [[ "$1" != --version ]] || printf 'ghostty fixture\n'
    ;;
  git) printf 'git version fixture\n' ;;
esac
EOF
chmod +x "$check_stub_bin/check-tool"
for fixture_command in chezmoi mise brew dpkg-query pacman uv fc-list ghostty git; do
  ln -s check-tool "$check_stub_bin/$fixture_command"
done
for tool_manifest_kind in go uv; do
  while IFS= read -r tool_spec; do
    command_name="$("${tool_manifest_kind}_tool_binary_name" "$tool_spec")"
    [[ -e "$check_stub_bin/$command_name" ]] || ln -s check-tool "$check_stub_bin/$command_name"
  done < <(manifest_entries "$repo_root/bootstrap/manifests/ecosystem/$tool_manifest_kind-tools.txt")
done
# Completion behavior has its own tests above. Here verify the check delegates
# with the runtime platform and the same manifest, without host package assets.
cat >"$check_root/bootstrap/scripts/install-shell-completions.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == check && "$3" == "$CHECK_ROOT/bootstrap/manifests/shell/completions.txt" ]] || exit 1
printf 'completions %s\n' "$2" >>"$CHECK_ROOT/calls"
EOF
run_check_fixture() {
  local platform_data="$1"
  shift
  env -i PATH="$check_stub_bin:/usr/bin:/bin" HOME="$check_root/home" OSTYPE=linux \
    XDG_CONFIG_HOME="$check_root/config" XDG_DATA_HOME="$check_root/data" \
    XDG_STATE_HOME="$check_root/state" CHECK_ROOT="$check_root" \
    REAL_CHEZMOI="$(command -v chezmoi)" \
    CHEZMOI_EXECUTABLE="${CHECK_CHEZMOI_EXECUTABLE-$check_stub_bin/chezmoi}" \
    CHECK_PLATFORM_DATA="$platform_data" FAIL_CHECK="${FAIL_CHECK:-}" "$@"
}
for check_platform in "${hook_platforms[@]}"; do
  check_platform_name="${check_platform%%|*}"
  [[ "$check_platform_name" != unsupported ]] || continue
  : >"$check_root/calls"
  check_log="$check_root/$check_platform_name.log"
  run_check_fixture "${check_platform#*|}" bash "$check_root/bootstrap/scripts/check.sh" \
    "$check_config" >"$check_log" 2>&1
  assert_file_contains "$check_log" 'All checks passed.'
  assert_file_contains "$check_log" 'Core tools in this environment:'
  assert_file_contains "$check_log" 'smoke-runtime'
  assert_file_not_contains "$check_log" 'Next steps:'
  assert_file_contains "$check_root/calls" "--config=$check_config"
  case "$check_platform_name" in
    macos) assert_file_contains "$check_root/calls" 'brew bundle check'; completion_platform=darwin ;;
    arch) assert_file_contains "$check_root/calls" 'pacman -Q'; completion_platform=linux ;;
    *) assert_file_contains "$check_root/calls" 'dpkg-query -W'; completion_platform=linux ;;
  esac
  assert_file_contains "$check_root/calls" "completions $completion_platform"
  case "$check_platform_name" in
    macos | ubuntu | arch) assert_file_contains "$check_root/calls" 'ghostty +validate-config' ;;
    *) assert_file_not_contains "$check_root/calls" 'ghostty +validate-config' ;;
  esac
done
# Missing initialization must fail with a direct instruction, before the
# baseline checks. Cover normal config discovery and an explicit config path.
mv "$check_config" "$check_config.saved"
for check_config_state in missing uninitialized; do
  if [[ "$check_config_state" == uninitialized ]]; then
    printf '[data]\n' >"$check_config"
  fi
  for check_config_mode in default explicit; do
    check_config_args=()
    if [[ "$check_config_mode" == explicit ]]; then
      check_config_args=("$check_config")
    fi
    check_config_error="$check_root/$check_config_state-$check_config_mode.err"
    expect_failure "$check_config_error" run_check_fixture "$darwin_chezmoi_data" \
      bash "$check_root/bootstrap/scripts/check.sh" ${check_config_args[@]+"${check_config_args[@]}"}
    assert_file_contains "$check_config_error" "Run 'chezmoi init' first."
    assert_file_not_contains "$check_config_error" 'Bootstrap step failed.'
    assert_file_not_contains "$check_config_error" 'map has no entry'
    assert_file_not_contains "$check_config_error" 'required tool(s) or asset(s) are missing.'
  done
done
mv "$check_config.saved" "$check_config"

# A shell without user-local binaries on PATH must still find chezmoi after
# shared PATH setup. An explicitly selected binary must also supply its version.
mkdir -p "$check_root/home/.local/bin"
rm "$check_stub_bin/chezmoi"
ln -s "$check_stub_bin/check-tool" "$check_root/home/.local/bin/chezmoi"
CHECK_CHEZMOI_EXECUTABLE="" run_check_fixture "$darwin_chezmoi_data" \
  bash "$check_root/bootstrap/scripts/check.sh" "$check_config" >"$check_root/path.log" 2>&1
assert_file_contains "$check_root/path.log" 'All checks passed.'
rm "$check_root/home/.local/bin/chezmoi"
ln -s "$check_stub_bin/check-tool" "$check_root/selected-chezmoi"
: >"$check_root/calls"
CHECK_CHEZMOI_EXECUTABLE="$check_root/selected-chezmoi" run_check_fixture "$darwin_chezmoi_data" \
  bash "$check_root/bootstrap/scripts/check.sh" "$check_config" >"$check_root/selected.log" 2>&1
assert_file_contains "$check_root/selected.log" 'All checks passed.'
assert_file_contains "$check_root/calls" 'selected-chezmoi --version'
ln -s check-tool "$check_stub_bin/chezmoi"

# A persisted opt-out suppresses desktop checks even on a supported platform.
printf '[data]\ndesktopBaseline = false\n' >"$check_config"
: >"$check_root/calls"
run_check_fixture "$darwin_chezmoi_data" bash "$check_root/bootstrap/scripts/check.sh" \
  >"$check_root/opt-out.log" 2>&1
assert_file_contains "$check_root/opt-out.log" 'All checks passed.'
assert_file_not_contains "$check_root/calls" 'ghostty +validate-config'
printf '[data]\ndesktopBaseline = true\n' >"$check_config"
for failed_check in mise ghostty; do
  if FAIL_CHECK="$failed_check" run_check_fixture "$darwin_chezmoi_data" \
    bash "$check_root/bootstrap/scripts/check.sh" "$check_config" >"$check_root/failure.log" 2>&1; then
    fail_test "environment check must fail when $failed_check fails"
  fi
  assert_file_contains "$check_root/failure.log" 'required tool(s) or asset(s) are missing.'
  assert_file_contains "$check_root/failure.log" 'What to try next:'
  assert_file_not_contains "$check_root/failure.log" 'All checks passed.'
done
expect_failure "$check_root/usage.err" bash "$script_dir/check.sh" extra extra
assert_file_contains "$check_root/usage.err" 'USAGE:'
# Render the actual hook, then run it against the same isolated fixture.
chezmoi --source="$repo_root" \
  --override-data "{\"desktopBaseline\":true,\"chezmoi\":{\"os\":\"darwin\",\"sourceDir\":\"$check_root\",\"configFile\":\"$check_config\"}}" \
  execute-template --file "$repo_root/.chezmoiscripts/run_onchange_after_60-check.sh.tmpl" \
  >"$check_root/hook.sh"
run_check_fixture "$darwin_chezmoi_data" bash "$check_root/hook.sh" >"$check_root/hook.log" 2>&1
assert_file_contains "$check_root/hook.log" 'All checks passed.'
assert_file_contains "$check_root/hook.log" 'Next steps:'
if FAIL_CHECK=mise run_check_fixture "$darwin_chezmoi_data" bash "$check_root/hook.sh" \
  >"$check_root/hook-failure.log" 2>&1; then
  fail_test "hook must propagate a failed environment check"
fi
assert_file_not_contains "$check_root/hook-failure.log" 'Next steps:'

log_step "🍺" "Testing the Homebrew installer with a stubbed brew..."
brew_fixture="$tmp_dir/brew-installer"
mkdir -p "$brew_fixture/bin"
cat >"$brew_fixture/bin/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$BREW_CALLS"
case "$1" in
  shellenv) printf 'export BREW_FIXTURE_ENV=loaded\n' ;;
  bundle)
    [[ "$BREW_FIXTURE_ENV" == loaded && "$2" == install && -f "${3#--file=}" ]] || exit 1
    [[ "${FAIL_BREW:-0}" != 1 ]]
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$brew_fixture/bin/brew"
for brewfile in "$repo_root/bootstrap/manifests/system/Brewfile" "$repo_root/bootstrap/manifests/desktop/Brewfile"; do
  env -i PATH="$brew_fixture/bin:/usr/bin:/bin" HOME="$brew_fixture" \
    XDG_CONFIG_HOME="$brew_fixture/config" BREW_CALLS="$brew_fixture/calls" \
    bash "$script_dir/install-brew-packages.sh" "$brewfile" >"$brew_fixture/install.log"
  assert_file_contains "$brew_fixture/calls" "bundle install --file=$brewfile"
done
expect_failure "$brew_fixture/failure.err" env -i \
  PATH="$brew_fixture/bin:/usr/bin:/bin" HOME="$brew_fixture" XDG_CONFIG_HOME="$brew_fixture/config" \
  BREW_CALLS="$brew_fixture/calls" FAIL_BREW=1 \
  bash "$script_dir/install-brew-packages.sh" "$repo_root/bootstrap/manifests/system/Brewfile"

log_step "🔤" "Testing the desktop font installer with a local archive..."
require_command zip
require_command unzip
font_fixture="$tmp_dir/font-installer"
mkdir -p "$font_fixture/bin" "$font_fixture/archive"
# Synthetic TTF payloads carry their manifest-derived face names. Fontconfig is
# stubbed; archive extraction, SHA-256 verification, and directory swaps are real.
for font_face in $MAPLE_MONO_POSTSCRIPT_NAMES; do
  printf '%s\n' "$font_face" >"$font_fixture/archive/$font_face.ttf"
done
(cd "$font_fixture/archive" && zip -q "$font_fixture/fonts.zip" ./*.ttf)
# macOS can provide shasum instead of the GNU SHA-256 command.
if command -v sha256sum >/dev/null 2>&1 && \
  sha256sum "$font_fixture/fonts.zip" | sha256sum --check --status >/dev/null 2>&1; then
  ln -s "$(command -v sha256sum)" "$font_fixture/bin/sha256sum"
else
  require_command shasum
  printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' >"$font_fixture/bin/sha256sum"
  chmod +x "$font_fixture/bin/sha256sum"
fi
font_archive_sha="$("$font_fixture/bin/sha256sum" "$font_fixture/fonts.zip" | awk '{print $1}')"
sed "s/^MAPLE_MONO_SHA256=.*/MAPLE_MONO_SHA256=$font_archive_sha/" \
  "$desktop_font_manifest" >"$font_fixture/manifest.env"
cat >"$font_fixture/bin/font-tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${0##*/}" in
  curl)
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --output ]]; then
        cp "$FONT_ARCHIVE" "$2"
        exit 0
      fi
      shift
    done
    exit 1
    ;;
  fc-scan) cat "${@: -1}" ;;
  fc-cache) [[ "${FAIL_FONT_CACHE:-0}" != 1 ]] ;;
  fc-list)
    for font_file in "$FONT_INSTALL_DIR"/*.ttf; do
      [[ -f "$font_file" ]] || continue
      cat "$font_file"
    done
    ;;
esac
EOF
chmod +x "$font_fixture/bin/font-tool"
for fixture_command in curl fc-scan fc-cache fc-list; do
  ln -s font-tool "$font_fixture/bin/$fixture_command"
done
font_data="$font_fixture/data"
font_install_dir="$(XDG_DATA_HOME="$font_data" maple_mono_font_dir)"
font_marker="$(XDG_DATA_HOME="$font_data" maple_mono_font_marker)"
run_font_installer() {
  env -i PATH="$font_fixture/bin:$PATH" HOME="$font_fixture/home" \
    XDG_CONFIG_HOME="$font_fixture/config" XDG_DATA_HOME="$font_data" XDG_CACHE_HOME="$font_fixture/cache" \
    FONT_ARCHIVE="$font_fixture/fonts.zip" FONT_INSTALL_DIR="$font_install_dir" \
    FAIL_FONT_CACHE="${FAIL_FONT_CACHE:-0}" \
    bash "$script_dir/install-maple-mono-font.sh" "$1"
}
run_font_installer "$font_fixture/manifest.env" >"$font_fixture/install.log" 2>&1
assert_file_contains "$font_fixture/install.log" 'installed successfully.'
assert_file_contains "$font_marker" "version=$MAPLE_MONO_VERSION sha256=$font_archive_sha"
for font_face in $MAPLE_MONO_POSTSCRIPT_NAMES; do
  cmp -s "$font_fixture/archive/$font_face.ttf" "$font_install_dir/$font_face.ttf" \
    || fail_test "font installer did not install declared face $font_face"
done
cp -R "$font_install_dir" "$font_fixture/previous"
# A stale managed marker forces an update. Neither a checksum mismatch nor a
# failed post-swap Fontconfig refresh may damage the previous installation.
printf 'previous installation\n' >"$font_marker"
cp "$font_marker" "$font_fixture/previous/$(basename "$font_marker")"
bad_font_sha="$(printf 'invalid archive checksum\n' | "$font_fixture/bin/sha256sum" | awk '{print $1}')"
sed "s/^MAPLE_MONO_SHA256=.*/MAPLE_MONO_SHA256=$bad_font_sha/" \
  "$desktop_font_manifest" >"$font_fixture/mismatch.env"
expect_failure "$font_fixture/mismatch.err" run_font_installer "$font_fixture/mismatch.env"
assert_file_contains "$font_fixture/mismatch.err" 'checksum verification failed'
diff -r "$font_fixture/previous" "$font_install_dir" \
  || fail_test "checksum mismatch changed the existing font installation"
[[ ! -e "$font_fixture/cache/oh-my-devenv/downloads/$MAPLE_MONO_ARCHIVE" ]] \
  || fail_test "checksum mismatch left a corrupt cached archive"
expect_failure "$font_fixture/cache-failure.err" env -i \
  PATH="$font_fixture/bin:$PATH" HOME="$font_fixture/home" XDG_CONFIG_HOME="$font_fixture/config" \
  XDG_DATA_HOME="$font_data" XDG_CACHE_HOME="$font_fixture/cache" \
  FONT_ARCHIVE="$font_fixture/fonts.zip" FONT_INSTALL_DIR="$font_install_dir" FAIL_FONT_CACHE=1 \
  bash "$script_dir/install-maple-mono-font.sh" "$font_fixture/manifest.env"
diff -r "$font_fixture/previous" "$font_install_dir" \
  || fail_test "failed Fontconfig refresh did not restore the previous installation"

log_step "🤖" "Verifying the main source deploys only dotfiles..."
# Repository documentation, metadata, and the nested sources are not targets:
# every path the main source manages is a dot-path directly under HOME.
managed_listing="$(chezmoi managed --source="$repo_root" --override-data-file "$tmp_data_file" --path-style=absolute)"
while IFS= read -r managed_path; do
  [[ "$managed_path" == "$HOME/."* ]] \
    || fail_test "main chezmoi source deploys a non-dotfile target: $managed_path"
done <<<"$managed_listing"

log_step "📋" "Checking the local overlay inventory..."
overlay_manifest="$repo_root/bootstrap/manifests/local-overlays.tsv"
overlay_examples_dir="$repo_root/docs/local-overlay-examples"

if ! local_overlay_load "$overlay_manifest"; then
  fail_test "local overlay inventory validation failed"
fi

if local_overlay_inventory "$tmp_dir/missing-local-overlays.tsv" >/dev/null 2>&1; then
  fail_test "missing local overlay inventory must fail validation"
fi
invalid_overlay_manifest="$tmp_dir/invalid-local-overlays.tsv"
printf '%s\n' $'broken\tbroken.example\t$HOME/.broken\tinvalid' >"$invalid_overlay_manifest"
if local_overlay_inventory "$invalid_overlay_manifest" >/dev/null 2>&1; then
  fail_test "invalid local overlay inventory must fail validation"
fi

duplicate_overlay_manifest="$tmp_dir/duplicate-local-overlays.tsv"
duplicate_overlay_errors="$tmp_dir/duplicate-local-overlays.err"
printf '%s\n' \
  $'first\tfirst.example\t$HOME/.first\texact' \
  $'second\tfirst.example\t$HOME/.second\texact' \
  $'third\tthird.example\t$HOME/.second\texact' \
  >"$duplicate_overlay_manifest"
if local_overlay_inventory "$duplicate_overlay_manifest" >/dev/null 2>"$duplicate_overlay_errors"; then
  fail_test "duplicate local overlay inventory must fail validation"
fi
assert_file_contains "$duplicate_overlay_errors" "duplicate local overlay example"
assert_file_contains "$duplicate_overlay_errors" "duplicate local overlay location"

trailing_xdg="$tmp_dir/trailing-xdg/"
trailing_env_path="${trailing_xdg%/}/oh-my-devenv/env.sh"
resolved_trailing_env="$(XDG_CONFIG_HOME="$trailing_xdg" local_overlay_expand "$env_overlay_literal" exact)"
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

# Every inventory row names an existing example, and every example is
# protected by exactly one inventory row.
while IFS=$'\t' read -r -a overlay_fields; do
  if [[ ! -f "$overlay_examples_dir/${overlay_fields[1]}" ]]; then
    fail_test "overlay inventory example is missing: ${overlay_fields[1]}"
  fi
done < <(local_overlay_inventory "$overlay_manifest")

for overlay_example_path in "$overlay_examples_dir"/*.example; do
  overlay_example="$(basename "$overlay_example_path")"
  overlay_example_count="$(awk -F '\t' -v example="$overlay_example" '$0 !~ /^#/ && $2 == example { count++ } END { print count + 0 }' "$overlay_manifest")"
  if [[ "$overlay_example_count" != "1" ]]; then
    fail_test "overlay example must appear exactly once in inventory: $overlay_example"
  fi
done

git_config_example="$overlay_examples_dir/git-config.example"
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
  # The main source must not manage the same target.
  if grep -Fxq "$HOME/.config/$xdg_managed_relative" <<<"$managed_listing"; then
    fail_test "main chezmoi source must not manage nested XDG target: $xdg_managed_relative"
  fi
done <<<"$xdg_managed_listing"
# Local overlays under XDG_CONFIG_HOME stay user-owned.
while IFS=$'\t' read -r -a overlay_fields; do
  [[ "${overlay_fields[3]}" == "exact" ]] || continue
  overlay_target="$(XDG_CONFIG_HOME="$xdg_test_home" local_overlay_expand "${overlay_fields[2]}" exact)"
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
# Desktop targets are the nested XDG targets that render content with the
# baseline enabled and render empty with it disabled. Derive them for each
# synthetic platform, then check that enabling writes them and disabling makes
# chezmoi remove them.
desktop_empty_config="$tmp_dir/desktop-empty-chezmoi.toml"
: >"$desktop_empty_config"
desktop_chezmoi() {
  local destination="$1"
  local override_data="$2"
  shift 2

  chezmoi --config="$desktop_empty_config" --persistent-state="$destination.boltdb" \
    --source="$repo_root/xdg_config" --destination="$destination" \
    --override-data="$override_data" "$@"
}
desktop_platform_cases=(
  "macos|true|$darwin_chezmoi_data"
  "ubuntu|true|$supported_linux_chezmoi_data"
  "unsupported|false|$unsupported_chezmoi_data"
)
for desktop_case in "${desktop_platform_cases[@]}"; do
  IFS='|' read -r desktop_name desktop_supported desktop_platform_data <<<"$desktop_case"
  desktop_home="$tmp_dir/desktop-$desktop_name-home"
  mkdir -p "$desktop_home"
  desktop_enabled="$(printf '{"desktopBaseline":true,"desktopPlatformSupported":%s,"desktopFontFamily":"%s","chezmoi":%s}' \
    "$desktop_supported" "$MAPLE_MONO_FAMILY" "$desktop_platform_data")"
  desktop_disabled="${desktop_enabled/\"desktopBaseline\":true/\"desktopBaseline\":false}"
  desktop_targets=()
  while IFS= read -r desktop_target; do
    [[ -n "$(desktop_chezmoi "$desktop_home" "$desktop_enabled" cat "$desktop_target")" ]] || continue
    [[ -z "$(desktop_chezmoi "$desktop_home" "$desktop_disabled" cat "$desktop_target")" ]] || continue
    desktop_targets+=("$desktop_target")
  done < <(desktop_chezmoi "$desktop_home" "$desktop_enabled" managed --include=files --path-style=absolute --format=)
  if [[ "$desktop_supported" == true && ${#desktop_targets[@]} -eq 0 ]]; then
    fail_test "desktop baseline renders no targets on supported platform $desktop_name"
  fi
  if [[ "$desktop_supported" != true && ${#desktop_targets[@]} -ne 0 ]]; then
    fail_test "desktop baseline renders targets on unsupported platform $desktop_name: ${desktop_targets[*]}"
  fi
  desktop_chezmoi "$desktop_home" "$desktop_enabled" apply
  for desktop_target in ${desktop_targets[@]+"${desktop_targets[@]}"}; do
    [[ -s "$desktop_target" ]] || fail_test "enabling the desktop baseline did not write $desktop_target"
  done
  desktop_chezmoi "$desktop_home" "$desktop_disabled" apply
  for desktop_target in ${desktop_targets[@]+"${desktop_targets[@]}"}; do
    [[ ! -e "$desktop_target" ]] || fail_test "disabling the desktop baseline left $desktop_target in place"
  done
  printf '%s\n' ${desktop_targets[@]+"${desktop_targets[@]}"} >"$tmp_dir/desktop-$desktop_name-targets"
done
# Only the Ubuntu desktop adds the Fontconfig workaround, so it manages more
# desktop targets than macOS.
if [[ "$(wc -l <"$tmp_dir/desktop-ubuntu-targets")" -le "$(wc -l <"$tmp_dir/desktop-macos-targets")" ]]; then
  fail_test "Ubuntu desktop targets must include the Fontconfig workaround beyond the macOS set"
fi
xdg_status="$(XDG_CONFIG_HOME="$xdg_test_home" XDG_STATE_HOME="$xdg_test_state" \
  bash "$repo_root/bootstrap/scripts/xdg-config.sh" status "$xdg_test_config")"
if [[ -n "$xdg_status" ]]; then
  fail_test "nested XDG source is not clean after apply: $xdg_status"
fi

log_step "🧹" "Testing uninstall previews, backups, deletion, and state reset..."
uninstall_home="$tmp_dir/uninstall-home"
uninstall_config_home="$tmp_dir/uninstall-config"
uninstall_data_home="$tmp_dir/uninstall-data"
uninstall_state_home="$tmp_dir/uninstall-state"
mkdir -p "$uninstall_home" "$uninstall_config_home/chezmoi" "$uninstall_state_home"
cat >"$uninstall_config_home/chezmoi/chezmoi.toml" <<EOF
persistentState = "$uninstall_state_home/main.boltdb"
[data]
name = "Uninstall Smoke"
email = "uninstall@example.com"
desktopBaseline = false
EOF

# Every command, including every --confirm invocation, uses explicit fixture
# roots. Resolve symlinks before checking HOME so an alias cannot pass the guard.
with_uninstall_fixture() (
  export HOME="$uninstall_home"
  export XDG_CONFIG_HOME="$uninstall_config_home"
  export XDG_DATA_HOME="$uninstall_data_home"
  export XDG_STATE_HOME="$uninstall_state_home"
  export XDG_CACHE_HOME="$tmp_dir/uninstall-cache"
  fixture_home="$(cd "$HOME" && pwd -P)"
  fixture_root="$(cd "$tmp_dir" && pwd -P)"
  if [[ "$fixture_home" == "$real_home" || "$fixture_home" != "$fixture_root/"* ]]; then
    fail_test "refusing uninstall test outside a temporary HOME: $fixture_home"
  fi
  "$@"
)

case "$(uname -s)" in
  Darwin) uninstall_completion_platform=darwin ;;
  *) uninstall_completion_platform=linux ;;
esac
with_uninstall_fixture run_completion_installer "$uninstall_data_home" \
  install "$uninstall_completion_platform" "$completion_manifest" >/dev/null
uninstall_unowned_completion="$(with_uninstall_fixture run_completion_installer "$uninstall_data_home" \
  list "$uninstall_completion_platform" "$completion_manifest" | sed -n '1p')"
[[ -n "$uninstall_unowned_completion" ]] || fail_test "uninstall fixture generated no completions"
printf '# user completion at a current manifest target\n' >"$uninstall_unowned_completion"
# Reuse generated bytes so the installer remains the authority for ownership.
uninstall_obsolete_completion="$uninstall_data_home/zsh/site-functions/_smoke-obsolete"
cp "$reconcile_zsh_dir/_uv" "$uninstall_obsolete_completion"
uninstall_linked_completion="$uninstall_data_home/zsh/site-functions/_smoke-linked"
ln -s "$uninstall_obsolete_completion" "$uninstall_linked_completion"
uninstall_owned_completions="$(with_uninstall_fixture run_completion_installer "$uninstall_data_home" \
  list "$uninstall_completion_platform" "$completion_manifest")"
uninstall_replaced_completion="$uninstall_data_home/zsh/site-functions/_smoke-replaced"
cp "$reconcile_zsh_dir/_uv" "$uninstall_replaced_completion"

# Create ordinary and dangling-link fixtures from the real managed inventory.
uninstall_main_listing="$(with_uninstall_fixture chezmoi --source="$repo_root" managed \
  --include=files,symlinks --path-style=absolute --format=)"
while IFS= read -r uninstall_target; do
  [[ "$uninstall_target" == "$uninstall_home/"* ]] \
    || fail_test "uninstall fixture manages a path outside temporary HOME: $uninstall_target"
done <<<"$uninstall_main_listing"
uninstall_main_file="$(sed -n '1p' <<<"$uninstall_main_listing")"
uninstall_dangling_link="$(sed -n '2p' <<<"$uninstall_main_listing")"
[[ -n "$uninstall_main_file" && -n "$uninstall_dangling_link" ]] \
  || fail_test "uninstall test needs two managed fixture paths"
mkdir -p "$(dirname "$uninstall_main_file")" "$(dirname "$uninstall_dangling_link")"
printf 'managed fixture\n' >"$uninstall_main_file"
ln -s "$uninstall_home/missing-link-target" "$uninstall_dangling_link"
with_uninstall_fixture bash "$script_dir/xdg-config.sh" apply >/dev/null
uninstall_xdg_listing="$(with_uninstall_fixture bash "$script_dir/xdg-config.sh" managed)"
uninstall_xdg_listing="$(while IFS= read -r uninstall_target; do
  if [[ -f "$uninstall_target" || -L "$uninstall_target" ]]; then
    printf '%s\n' "$uninstall_target"
  fi
done <<<"$uninstall_xdg_listing")"
[[ -n "$uninstall_xdg_listing" ]] || fail_test "nested XDG apply created no managed fixture"
# shellcheck disable=SC2016
uninstall_state_file="$(with_uninstall_fixture bash -c \
  'source "$1"; xdg_chezmoi_state_file' _ "$script_dir/common.sh")"
# shellcheck disable=SC2016
uninstall_owned_directory="$(with_uninstall_fixture bash -c \
  'source "$1"; oh_my_devenv_oh_my_zsh_dir' _ "$script_dir/common.sh")"
mkdir -p "$uninstall_owned_directory"
printf 'owned tree fixture\n' >"$uninstall_owned_directory/smoke-owned"
uninstall_sentinel="$uninstall_home/unrelated/sentinel"
mkdir -p "$(dirname "$uninstall_sentinel")"
printf 'keep unrelated file\n' >"$uninstall_sentinel"
create_uninstall_overlays() {
  local fixture=""
  local -a fields=()

  while IFS=$'\t' read -r -a fields; do
    fixture="$(local_overlay_expand "${fields[2]}" exact)"
    if [[ "${fields[3]}" == glob ]]; then
      fixture="${fixture/\*/smoke}"
    fi
    mkdir -p "$(dirname "$fixture")"
    printf '# keep overlay\n' >"$fixture"
    printf '%s\n' "$fixture"
  done < <(local_overlay_inventory "$overlay_manifest")
}
overlay_fixture_listing="$(with_uninstall_fixture create_uninstall_overlays)"

for uninstall_bucket in scriptState entryState smokePreserved; do
  with_uninstall_fixture chezmoi --source="$repo_root" state set \
    --bucket="$uninstall_bucket" --key=smoke --value='{"seeded":true}'
done
uninstall_preview="$(with_uninstall_fixture bash "$script_dir/uninstall.sh")"
for uninstall_bucket in scriptState entryState; do
  assert_file_contains <(printf '%s\n' "$uninstall_preview") \
    "[would-reset] main chezmoi state bucket: $uninstall_bucket"
  uninstall_bucket_data="$(with_uninstall_fixture chezmoi --source="$repo_root" state get-bucket --bucket="$uninstall_bucket")"
  [[ "$uninstall_bucket_data" == *seeded* ]] || fail_test "uninstall preview changed $uninstall_bucket"
done
uninstall_removed_files="$uninstall_main_file
$uninstall_dangling_link
$uninstall_xdg_listing
$uninstall_owned_completions
$uninstall_state_file"
while IFS= read -r uninstall_target; do
  [[ -n "$uninstall_target" ]] || continue
  assert_file_contains <(printf '%s\n' "$uninstall_preview") "[would-remove] file: $uninstall_target"
  [[ -e "$uninstall_target" || -L "$uninstall_target" ]] \
    || fail_test "uninstall preview removed a fixture: $uninstall_target"
done <<<"$uninstall_removed_files"
while IFS= read -r overlay_fixture; do
  assert_file_contains <(printf '%s\n' "$uninstall_preview") "[would-skip] overlay-protected: $overlay_fixture"
done <<<"$overlay_fixture_listing"
for uninstall_target in "$uninstall_unowned_completion" "$uninstall_linked_completion"; do
  if grep -Fxq "[would-remove] file: $uninstall_target" <<<"$uninstall_preview"; then
    fail_test "uninstall preview includes an unowned completion: $uninstall_target"
  fi
done

# bootstrap.env may move the state root; the producer and uninstall must agree.
uninstall_bootstrap_env="$uninstall_config_home/oh-my-devenv/bootstrap.env"
uninstall_overlay_state_home="$tmp_dir/uninstall-overlay-state"
printf 'export XDG_STATE_HOME=%q\n' "$uninstall_overlay_state_home" >"$uninstall_bootstrap_env"
uninstall_overlay_preview="$(with_uninstall_fixture bash "$script_dir/uninstall.sh")"
assert_file_contains <(printf '%s\n' "$uninstall_overlay_preview") "$uninstall_overlay_state_home/"
: >"$uninstall_bootstrap_env"

# Replace one owned file during backup to exercise the final ownership check.
uninstall_backup_stub_bin="$tmp_dir/uninstall-backup-stub-bin"
uninstall_real_tar="$(command -v tar)"
mkdir -p "$uninstall_backup_stub_bin"
cat >"$uninstall_backup_stub_bin/tar" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == -P ]]; then
  printf '# replaced after inventory\n' >"$UNINSTALL_TEST_COMPLETION"
fi
exec "$UNINSTALL_TEST_TAR" "$@"
STUB
chmod +x "$uninstall_backup_stub_bin/tar"
uninstall_log="$tmp_dir/uninstall-confirm.log"
with_uninstall_fixture env PATH="$uninstall_backup_stub_bin:$PATH" \
  UNINSTALL_TEST_TAR="$uninstall_real_tar" UNINSTALL_TEST_COMPLETION="$uninstall_replaced_completion" \
  bash "$script_dir/uninstall.sh" --confirm >"$uninstall_log"
assert_file_contains "$uninstall_log" "[skipped] completion is no longer owned: $uninstall_replaced_completion"
uninstall_archive="$(sed -n 's/^\[backed-up\] //p' "$uninstall_log" | sed -n '/\/managed-files\.tgz$/p')"
[[ -f "$uninstall_archive" ]] || fail_test "confirmed uninstall did not create a file backup"
tar -tzf "$uninstall_archive" 2>/dev/null | sed 's|^/||' >"$tmp_dir/uninstall-archive-list"
while IFS= read -r uninstall_target; do
  [[ -n "$uninstall_target" ]] || continue
  [[ ! -e "$uninstall_target" && ! -L "$uninstall_target" ]] \
    || fail_test "confirmed uninstall left a managed fixture: $uninstall_target"
  grep -Fxq "${uninstall_target#/}" "$tmp_dir/uninstall-archive-list" \
    || fail_test "uninstall archive omitted a removed file: $uninstall_target"
done <<<"$uninstall_removed_files"
[[ ! -e "$uninstall_owned_directory" ]] || fail_test "confirmed uninstall left an owned directory"
uninstall_tree_archive="$(sed -n 's/^\[backed-up\] //p' "$uninstall_log" | sed -n '/\/tree-.*\.tgz$/p')"
[[ -f "$uninstall_tree_archive" ]] || fail_test "confirmed uninstall did not back up the owned directory"
tar -tzf "$uninstall_tree_archive" | grep -Fq '/smoke-owned' \
  || fail_test "uninstall tree archive omitted the owned directory contents"
for uninstall_bucket in scriptState entryState; do
  [[ "$(with_uninstall_fixture chezmoi --source="$repo_root" state get-bucket --bucket="$uninstall_bucket")" == '{}' ]] \
    || fail_test "confirmed uninstall did not clear $uninstall_bucket"
done
[[ "$(with_uninstall_fixture chezmoi --source="$repo_root" state get-bucket --bucket=smokePreserved)" == *seeded* ]] \
  || fail_test "uninstall reset an unrelated state bucket"
uninstall_preserved_files="$overlay_fixture_listing
$uninstall_sentinel
$uninstall_unowned_completion
$uninstall_replaced_completion
$uninstall_linked_completion"
while IFS= read -r uninstall_target; do
  [[ -e "$uninstall_target" || -L "$uninstall_target" ]] \
    || fail_test "confirmed uninstall removed a protected fixture: $uninstall_target"
done <<<"$uninstall_preserved_files"
[[ -d "$repo_root" && -f "$script_dir/uninstall.sh" ]] \
  || fail_test "uninstall removed the source checkout"

# A second confirmed run skips backup while still deleting files and clearing
# both script buckets. Keep the first run's archives for comparison.
find "$uninstall_state_home" -name '*.tgz' | sort >"$tmp_dir/uninstall-backups-before"
printf 'managed fixture without backup\n' >"$uninstall_main_file"
for uninstall_bucket in scriptState entryState; do
  with_uninstall_fixture chezmoi --source="$repo_root" state set \
    --bucket="$uninstall_bucket" --key=smoke --value='{"seeded":true}'
done
with_uninstall_fixture bash "$script_dir/uninstall.sh" --confirm --no-backup >"$uninstall_log"
assert_file_contains "$uninstall_log" '[skipped] backup (--no-backup)'
assert_file_not_contains "$uninstall_log" '[backed-up]'
[[ ! -e "$uninstall_main_file" ]] || fail_test "--no-backup did not remove the managed fixture"
find "$uninstall_state_home" -name '*.tgz' | sort >"$tmp_dir/uninstall-backups-after"
cmp -s "$tmp_dir/uninstall-backups-before" "$tmp_dir/uninstall-backups-after" \
  || fail_test "--no-backup changed the backup inventory"
for uninstall_bucket in scriptState entryState; do
  [[ "$(with_uninstall_fixture chezmoi --source="$repo_root" state get-bucket --bucket="$uninstall_bucket")" == '{}' ]] \
    || fail_test "--no-backup did not clear $uninstall_bucket"
done

log_step "🧩" "Running manifest and template contract checks..."
# The real desktop support rule. Ubuntu versions sit far on either side of the
# release floor, so these cases check that the floor exists, not its value.
# WSL never receives the desktop baseline, whatever the distribution.
while IFS='|' read -r desktop_support_expected desktop_support_platform; do
  assert_desktop_platform_support "{\"chezmoi\":$desktop_support_platform}" "$desktop_support_expected"
done <<EOF
true|$darwin_chezmoi_data
true|$supported_linux_chezmoi_data
true|{"os":"linux","osRelease":{"id":"arch","idLike":"","versionID":""},"kernel":{"osrelease":"linux"}}
true|{"os":"linux","osRelease":{"id":"smoke-arch-derivative","idLike":"smoke arch","versionID":""},"kernel":{"osrelease":"linux"}}
|{"os":"linux","osRelease":{"id":"ubuntu","versionID":"20.04","idLike":""},"kernel":{"osrelease":"linux"}}
|{"os":"linux","osRelease":{"id":"ubuntu","versionID":"","idLike":""},"kernel":{"osrelease":"linux"}}
|{"os":"linux","osRelease":{"id":"debian","versionID":"13","idLike":""},"kernel":{"osrelease":"linux"}}
|$wsl_chezmoi_data
|{"os":"linux","osRelease":{"id":"arch","idLike":"","versionID":""},"kernel":{"osrelease":"microsoft-standard-WSL2"}}
|$unsupported_chezmoi_data
EOF

# A run_onchange hook reruns only when its rendered text changes, so it must
# hash every script it runs or sources and every manifest it passes to a script.
for hook_template in "$repo_root"/.chezmoiscripts/run_onchange_*.sh.tmpl; do
  # The patterns match the literal $scripts_dir and $manifests_dir hook text.
  # shellcheck disable=SC2016
  hook_inputs="$(
    grep -oE '((bash|source) "\$scripts_dir|"\$manifests_dir)/[^"]+"' "$hook_template" \
      | sed -E 's#^(bash|source) "\$scripts_dir/#bootstrap/scripts/#; s|^"\$manifests_dir/|bootstrap/manifests/|; s|"$||' \
      | sort -u
  )" || true
  while IFS= read -r hook_input; do
    [[ -n "$hook_input" ]] || continue
    if [[ "$hook_input" == bootstrap/scripts/common.sh ]]; then
      assert_file_contains "$hook_template" 'includeTemplate "common-bootstrap-hashes" .'
    else
      assert_file_contains "$hook_template" "include \"$hook_input\" | sha256sum"
    fi
  done <<<"$hook_inputs"
done

# Changes to either shared source file must change a rendered hook. Use a
# minimal source fixture so the working tree remains untouched.
shared_hash_source="$tmp_dir/shared-hash-source"
shared_hash_hook=.chezmoiscripts/run_onchange_after_30-install-mise.sh.tmpl
mkdir -p "$shared_hash_source/.chezmoiscripts" "$shared_hash_source/.chezmoitemplates" \
  "$shared_hash_source/bootstrap/scripts" "$shared_hash_source/dot_local/share/oh-my-devenv"
cp "$repo_root/$shared_hash_hook" "$shared_hash_source/$shared_hash_hook"
cp "$repo_root/.chezmoitemplates/common-bootstrap-hashes" \
  "$shared_hash_source/.chezmoitemplates/common-bootstrap-hashes"
cp "$repo_root/bootstrap/scripts/common.sh" "$shared_hash_source/bootstrap/scripts/common.sh"
cp "$repo_root/dot_local/share/oh-my-devenv/xdg.sh" \
  "$shared_hash_source/dot_local/share/oh-my-devenv/xdg.sh"
shared_hash_before="$tmp_dir/shared-hash.before"
chezmoi --source="$shared_hash_source" execute-template \
  --file "$shared_hash_source/$shared_hash_hook" >"$shared_hash_before"
for shared_hash_input in bootstrap/scripts/common.sh dot_local/share/oh-my-devenv/xdg.sh; do
  printf '\n# smoke hash change\n' >>"$shared_hash_source/$shared_hash_input"
  shared_hash_after="$tmp_dir/shared-hash.$(basename "$shared_hash_input").after"
  chezmoi --source="$shared_hash_source" execute-template \
    --file "$shared_hash_source/$shared_hash_hook" >"$shared_hash_after"
  if cmp -s "$shared_hash_before" "$shared_hash_after"; then
    fail_test "changing $shared_hash_input did not change the rendered hook"
  fi
  shared_hash_before="$shared_hash_after"
done

# The Ghostty font workaround renders only for the supported Ubuntu desktop.
synthetic_fontconfig_template="$repo_root/xdg_config/fontconfig/conf.d/99-oh-my-devenv-maple-mono-nf-cn.conf.tmpl"
synthetic_supported_fontconfig="$tmp_dir/fontconfig-supported-linux.conf"
chezmoi --source="$repo_root" \
  --override-data "$(desktop_override_data true "$supported_linux_chezmoi_data")" \
  execute-template --file "$synthetic_fontconfig_template" \
  >"$synthetic_supported_fontconfig"
assert_file_contains "$synthetic_supported_fontconfig" '<edit name="family" mode="prepend" binding="strong">'
assert_file_contains "$synthetic_supported_fontconfig" "<string>$MAPLE_MONO_FAMILY</string>"
for platform_data in \
  "$darwin_chezmoi_data" \
  '{"os":"linux","osRelease":{"id":"arch","idLike":"","versionID":""},"kernel":{"osrelease":"linux"}}'; do
  synthetic_inactive_fontconfig="$tmp_dir/fontconfig-inactive.conf"
  chezmoi --source="$repo_root" \
    --override-data "$(desktop_override_data true "$platform_data")" \
    execute-template --file "$synthetic_fontconfig_template" >"$synthetic_inactive_fontconfig"
  if [[ -s "$synthetic_inactive_fontconfig" ]]; then
    fail_test "Ghostty font workaround must render empty outside Ubuntu: $platform_data"
  fi
done

# Exercise Fontconfig substitutions without installed fonts or the host's rules.
# Linux CI installs Fontconfig; macOS only needs the cross-platform render checks.
if [[ "$(uname -s)" != Darwin ]]; then
  require_command fc-pattern
  for program in ghostty foot chromium; do
    actual_family="$(FONTCONFIG_FILE="$synthetic_supported_fontconfig" \
      fc-pattern -c -f '%{family}' "monospace:prgname=$program")"
    if [[ "$program" == ghostty ]]; then
      [[ "$actual_family" == "$MAPLE_MONO_FAMILY,monospace" ]] || fail_test "Ghostty workaround did not prefer the manifest font"
    else
      [[ "$actual_family" == monospace ]] || fail_test "Ghostty workaround changed $program fonts"
    fi
  done
  actual_family="$(FONTCONFIG_FILE="$synthetic_supported_fontconfig" fc-pattern -c -f '%{family}' monospace)"
  [[ "$actual_family" == monospace ]] || fail_test "Ghostty workaround changed the default monospace preference"
  actual_family="$(FONTCONFIG_FILE="$synthetic_supported_fontconfig" \
    fc-pattern -c -f '%{family}' 'Smoke Explicit Font,monospace:prgname=ghostty')"
  [[ "$actual_family" == "Smoke Explicit Font,$MAPLE_MONO_FAMILY,monospace" ]] || fail_test "Ghostty workaround displaced an explicitly selected font"
fi

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

render_template xdg_config/mise/config.toml.tmpl "$tmp_dir/mise-config.toml"
# shellcheck disable=SC2016
chezmoi --source="$repo_root" execute-template --with-stdin '{{ .chezmoi.stdin | fromToml | toJson }}' \
  <"$tmp_dir/mise-config.toml" >/dev/null \
  || fail_test "mise config does not parse as TOML"
check_oh_my_zsh_manifest_contract "$repo_root/bootstrap/manifests/shell/oh-my-zsh-plugins.txt" "$tmp_dir/dot_zshrc"
# Synthetic manifests render the zshrc from a minimal source copy: one without
# zsh-completions, and one that keeps it under a different parent directory.
omz_contract_source="$tmp_dir/omz-contract-source"
mkdir -p "$omz_contract_source/bootstrap/manifests/shell"
cp "$repo_root/dot_zshrc.tmpl" "$omz_contract_source/dot_zshrc.tmpl"
omz_contract_manifest="$omz_contract_source/bootstrap/manifests/shell/oh-my-zsh-plugins.txt"
while IFS='|' read -r omz_contract_case omz_contract_rows; do
  printf '%b\n' "$omz_contract_rows" >"$omz_contract_manifest"
  chezmoi --source="$omz_contract_source" execute-template \
    --file "$omz_contract_source/dot_zshrc.tmpl" >"$tmp_dir/dot_zshrc.$omz_contract_case"
  syntax_check zsh "$tmp_dir/dot_zshrc.$omz_contract_case"
  check_oh_my_zsh_manifest_contract "$omz_contract_manifest" "$tmp_dir/dot_zshrc.$omz_contract_case"
done <<'OMZ_CASES'
without-completions|example/one plugins/one
vendor-completions|example/one plugins/one\nzsh-users/zsh-completions vendor/zsh-completions
OMZ_CASES
assert_file_not_contains "$tmp_dir/dot_zshrc.without-completions" '/src")'
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
log_step "🛠️" "Running the rendered Linux mise hook against a stubbed installer..."
# The stub curl records its arguments and emits a fake installer that drops a
# stub mise into the fake HOME, so the `curl ... | sh` pipeline runs end to end
# without touching the network, the real HOME, or a real installer.
synthetic_linux_mise_hook="$tmp_dir/hook-debian-run_onchange_after_30-install-mise.sh"
synthetic_mise_install_url="https://mise-install.smoke.example/install.sh"
mise_stub_bin="$tmp_dir/mise-stub-bin"
mise_fake_home="$tmp_dir/mise-fake-home"
mise_curl_log="$tmp_dir/mise-curl.log"
mise_hook_output="$tmp_dir/mise-hook.out"
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
# Expose only fixture prerequisites, even on hosts with mise in /usr/bin.
for fixture_command in bash sh dirname cat mkdir chmod; do
  ln -s "$(command -v "$fixture_command")" "$mise_stub_bin/$fixture_command"
done
if env -i PATH="$mise_stub_bin" HOME="$mise_fake_home" \
  bash -c 'command -v mise' >/dev/null 2>&1; then
  fail_test "mise fixture PATH must not already provide mise"
fi
env -i PATH="$mise_stub_bin" HOME="$mise_fake_home" \
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

log_step "🧬" "Verifying the chezmoi init template..."
# Values stored by an earlier init are reused; the prompt answers below would
# only appear if the template asked again.
tmp_chezmoi_toml="$tmp_dir/chezmoi-toml.rendered"
chezmoi execute-template --init \
  --source="$repo_root" \
  --override-data-file "$tmp_data_file" \
  --promptString 'Git author name=Prompted Again,Git author email address=prompted@example.com' \
  --file "$repo_root/.chezmoi.toml.tmpl" >"$tmp_chezmoi_toml"
assert_toml_section_contains "$tmp_chezmoi_toml" "data" 'name = "Smoke Tests"'
assert_toml_section_contains "$tmp_chezmoi_toml" "data" 'email = "smoke@example.com"'
assert_toml_section_contains "$tmp_chezmoi_toml" "data" 'desktopBaseline = true'

log_step "📦" "Exercising the pacman installer with a stubbed sudo..."
pacman_stub_bin="$tmp_dir/pacman-stub-bin"
pacman_manifest="$tmp_dir/pacman-packages.txt"
pacman_log="$tmp_dir/pacman-args"
mkdir -p "$pacman_stub_bin"
cat >"$pacman_stub_bin/sudo" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == -n || "${1:-}" == -v ]] && exit 0
printf '%s\n' "$@" >"$PACMAN_TEST_LOG"
exit "${PACMAN_TEST_EXIT:-0}"
STUB
chmod +x "$pacman_stub_bin/sudo"
run_pacman_installer() {
  PATH="$pacman_stub_bin:$PATH" PACMAN_TEST_LOG="$pacman_log" \
    bash "$repo_root/bootstrap/scripts/install-pacman-packages.sh" "$pacman_manifest"
}
printf '# test inventory\nexample-one\n\nexample-two # inline comment\n' >"$pacman_manifest"
run_pacman_installer
printf 'pacman\n-S\n--needed\n--noconfirm\n--\nexample-one\nexample-two\n' >"$tmp_dir/pacman-expected"
cmp -s "$tmp_dir/pacman-expected" "$pacman_log" \
  || fail_test "pacman installer passed unexpected arguments: $(<"$pacman_log")"
if PACMAN_TEST_EXIT=42 run_pacman_installer >/dev/null 2>&1; then
  fail_test "pacman installer must propagate package manager failures"
fi
printf '%s\n' '--bad-option' >"$pacman_manifest"
expect_failure "$tmp_dir/pacman.err" run_pacman_installer
assert_file_contains "$tmp_dir/pacman.err" "invalid pacman package"

log_step "🐍" "Exercising the uv tool installer against stale tool environments..."
# Every fixture interpreter reports Python 3.13.16. The environments record the
# Python they were built on, as uv writes it into pyvenv.cfg.
uv_stub_bin="$tmp_dir/uv-stub-bin"
uv_tool_dir="$tmp_dir/uv-tools"
uv_manifest="$tmp_dir/uv-tools.txt"
uv_log="$tmp_dir/uv-args"
mkdir -p "$uv_stub_bin" "$tmp_dir/uv-python"
cat >"$uv_stub_bin/uv" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tool dir") printf '%s\n' "$UV_TEST_TOOL_DIR" ;;
  "tool list") [[ -z "${UV_TEST_LIST_EXIT:-}" ]] || exit "$UV_TEST_LIST_EXIT"; printf 'healthy v1.0\n- healthy\ndrifted v1.0\n- drifted\norphaned v1.0\n- orphaned\nbumped v0.9\n- bumped\n' ;;
  *) printf '%s\n' "$*" >>"$UV_TEST_LOG" ;;
esac
STUB
printf '#!/bin/sh\necho 3.13.16\n' >"$tmp_dir/uv-python/python"
chmod +x "$uv_stub_bin/uv" "$tmp_dir/uv-python/python"
make_uv_tool_env() {
  mkdir -p "$uv_tool_dir/$1/bin"
  printf 'home = %s\nversion_info = %s\n' "$tmp_dir/uv-python" "$2" >"$uv_tool_dir/$1/pyvenv.cfg"
  ln -s "$3" "$uv_tool_dir/$1/bin/python"
}
make_uv_tool_env healthy 3.13.16.final.0 "$tmp_dir/uv-python/python"
make_uv_tool_env drifted 3.13.14 "$tmp_dir/uv-python/python"
make_uv_tool_env orphaned 3.13.14 "$tmp_dir/uv-python-removed/python"
make_uv_tool_env bumped 3.13.16.final.0 "$tmp_dir/uv-python/python"
printf 'healthy==1.0\ndrifted==1.0\norphaned==1.0\nbumped==1.0\nabsent==1.0\n' >"$uv_manifest"

uv_tool_env_healthy "$uv_tool_dir" healthy >/dev/null \
  || fail_test "a uv tool environment on its recorded Python must be healthy"
[[ "$(uv_tool_env_healthy "$uv_tool_dir" drifted)" == "built on Python 3.13.14 but runs Python 3.13.16" ]] \
  || fail_test "a uv tool environment on a different Python must report the drift"
[[ "$(uv_tool_env_healthy "$uv_tool_dir" orphaned)" == "interpreter is missing" ]] \
  || fail_test "a uv tool environment without its interpreter must report it"

run_uv_installer() {
  : >"$uv_log"
  PATH="$uv_stub_bin:$PATH" UV_TEST_TOOL_DIR="$uv_tool_dir" UV_TEST_LOG="$uv_log" \
    bash "$repo_root/bootstrap/scripts/install-uv-tools.sh" "$uv_manifest" >/dev/null
}
run_uv_installer
printf '%s\n' 'tool uninstall drifted' 'tool install drifted==1.0' \
  'tool uninstall orphaned' 'tool install orphaned==1.0' 'tool install bumped==1.0' \
  'tool install absent==1.0' >"$tmp_dir/uv-expected"
cmp -s "$tmp_dir/uv-expected" "$uv_log" \
  || fail_test "uv installer must rebuild only stale tool environments: $(<"$uv_log")"
DOTFILES_FORCE_REINSTALL=1 run_uv_installer
printf '%s\n' 'tool uninstall healthy' 'tool install healthy==1.0' 'tool uninstall drifted' \
  'tool install drifted==1.0' 'tool uninstall orphaned' 'tool install orphaned==1.0' \
  'tool uninstall bumped' 'tool install bumped==1.0' 'tool install absent==1.0' >"$tmp_dir/uv-expected"
cmp -s "$tmp_dir/uv-expected" "$uv_log" \
  || fail_test "uv installer must rebuild every installed tool on force reinstall: $(<"$uv_log")"
if UV_TEST_LIST_EXIT=42 run_uv_installer 2>/dev/null; then
  fail_test "uv installer must fail when uv cannot list installed tools"
fi

log_step "🐚" "Checking Bash 3.2 compatibility..."
# All Bash code must run on macOS /bin/bash 3.2. Bash sources are discovered:
# files with a Bash shebang or ShellCheck directive, Bash dotfiles, and Bash
# overlay examples. `bash -n` rejects newer syntax; the pattern rejects Bash 4+
# features that parse under Bash 3.2 and fail only when executed, which
# ShellCheck does not flag: mapfile/readarray/coproc, wait -n, declare/typeset/
# local attributes -A -g -l -n -u, case-modifying and @ transformations,
# negative subscripts, and [[ -v ]]. Bracketed letters keep the pattern from
# matching its own definition.
bash4_pattern='(^|[^[:alnum:]_])(ma[p]file|rea[d]array|co[p]roc)([^[:alnum:]_]|$)|wa[i]t +-n|(de[c]lare|ty[p]eset|lo[c]al) +-[a-zA-Z]*[Aglnu]|\$\{#?[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?([\^,]|@[QEPAaKk])|\[[ ]*-[0-9]+[ ]*\]\}|\[\[ +-[v] '
bash_sources="$(
  {
    grep -rlE --exclude-dir=.git --exclude='*.md' '^#!.*bash|^# shellcheck shell=bash' "$repo_root"
    find "$repo_root" -path "$repo_root/.git" -prune -o -type f \
      \( -name 'dot_bash*' -o -path '*/dot_bash/*' -o -name dot_profile \
      -o -name '*.bash' -o -name '*.bash.example' \) -print
  } | sort -u
)"
[[ -n "$bash_sources" ]] || fail_test "no Bash sources discovered"
while IFS= read -r bash_source; do
  if [[ "$bash_source" != *.tmpl ]]; then
    syntax_check bash "$bash_source"
  fi
  if grep -nE -- "$bash4_pattern" "$bash_source" | grep -vE '^[0-9]+:[[:space:]]*#'; then
    fail_test "Bash 4+ construct in $bash_source; Bash code must run on Bash 3.2"
  fi
done <<<"$bash_sources"
log_step "🔍" "Running shellcheck on bootstrap scripts..."
shellcheck "$repo_root"/bootstrap/scripts/*.sh \
  "$repo_root/docs/local-overlay-examples/git-pre-push.example"

log_step "✅" "Smoke tests passed."
