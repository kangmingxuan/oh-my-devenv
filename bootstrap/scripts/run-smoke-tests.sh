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
supported_linux_chezmoi_data='{"os":"linux","osRelease":{"id":"ubuntu","versionID":"26.04","idLike":""},"kernel":{"osrelease":"linux"}}'
wsl_chezmoi_data='{"os":"linux","osRelease":{"id":"ubuntu","versionID":"26.04","idLike":""},"kernel":{"osrelease":"microsoft-standard-WSL2"}}'
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

render_template .chezmoiscripts/run_onchange_after_60-check.sh.tmpl "$tmp_dir/run_onchange_after_60-check.sh"

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

# Registered desktop faces pass and missing faces fail. Font identities come
# from the manifest.
# These stubs are called by the extracted function, outside static analysis.
# shellcheck disable=SC2317,SC2329
(
  eval "$(sed -n '/^check_desktop_font_fontconfig() {$/,/^}$/p' "$tmp_dir/run_onchange_after_60-check.sh")"
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
# Disabling the baseline renders the desktop templates empty, and chezmoi then
# removes the targets an earlier apply wrote.
XDG_CONFIG_HOME="$xdg_desktop_home" XDG_STATE_HOME="$tmp_dir/xdg-desktop-state-home" \
  bash "$repo_root/bootstrap/scripts/xdg-config.sh" apply "$xdg_test_config"
for desktop_target in ghostty/config.ghostty fontconfig/conf.d/99-oh-my-devenv-maple-mono-nf-cn.conf; do
  if [[ -e "$xdg_desktop_home/$desktop_target" ]]; then
    fail_test "disabling the desktop baseline left $desktop_target in place"
  fi
done
xdg_status="$(XDG_CONFIG_HOME="$xdg_test_home" XDG_STATE_HOME="$xdg_test_state" \
  bash "$repo_root/bootstrap/scripts/xdg-config.sh" status "$xdg_test_config")"
if [[ -n "$xdg_status" ]]; then
  fail_test "nested XDG source is not clean after apply: $xdg_status"
fi

# Preview uninstall against fixture roots.
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
uninstall_xdg_fixture=""
while IFS= read -r xdg_managed_path; do
  if [[ -f "$xdg_managed_path" ]]; then
    uninstall_xdg_fixture="$xdg_managed_path"
    break
  fi
done <<<"$xdg_managed_listing"
[[ -n "$uninstall_xdg_fixture" ]] || fail_test "nested XDG apply created no managed file"
overlay_fixture_listing="$(
  export HOME="$tmp_dir/uninstall-home"
  export XDG_CONFIG_HOME="$xdg_test_home"
  while IFS=$'\t' read -r -a overlay_fields; do
    overlay_fixture="$(local_overlay_expand "${overlay_fields[2]}" exact)"
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

log_step "🧩" "Running manifest and template contract checks..."
# WSL never receives the desktop baseline, whatever the distribution.
assert_desktop_platform_support "{\"chezmoi\":$wsl_chezmoi_data}" ''

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
