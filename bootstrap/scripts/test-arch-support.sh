#!/usr/bin/env bash
# Fixture-only checks; never invoke the real package manager or change live HOME.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

render_for() {
  local id="$1" like="$2" template="$3"
  chezmoi --source="$repo_root" --override-data \
    "{\"desktopBaseline\":true,\"chezmoi\":{\"os\":\"linux\",\"osRelease\":{\"id\":\"$id\",\"idLike\":\"$like\",\"versionID\":\"26.04\"},\"kernel\":{\"osrelease\":\"linux\"}}}" \
    execute-template --file "$repo_root/$template"
}
for entry in 'arch::pacman' 'derivative:arch:pacman' 'ubuntu:debian:apt' 'debian::apt' 'fedora::unsupported' 'unknown:notarch:unsupported'; do
  IFS=: read -r distro like expected <<<"$entry"
  actual="$(render_for "$distro" "$like" .chezmoitemplates/system-package-manager)"
  [[ "$actual" == "$expected" ]] || { echo "Wrong package manager for $distro" >&2; exit 1; }
  for hook in run_once_before_10-bootstrap run_onchange_after_20-install-system-packages run_onchange_after_22-install-desktop-assets run_onchange_after_60-check; do
    render_for "$distro" "$like" ".chezmoiscripts/$hook.sh.tmpl" >"$test_root/$hook.sh"
    bash -n "$test_root/$hook.sh"
    shellcheck -s bash -e SC1091 "$test_root/$hook.sh"
  done
done
[[ "$(render_for arch '' .chezmoitemplates/desktop-platform-supported)" == true ]]
[[ "$(render_for debian '' .chezmoitemplates/desktop-platform-supported)" == '' ]]

# Exercise package argument handling and failure propagation using a fake sudo.
mkdir -p "$test_root/bin" "$test_root/config"
cat >"$test_root/bin/sudo" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == -n || "${1:-}" == -v ]] && exit 0
printf '%s\n' "$@" >"$PACMAN_TEST_LOG"
exit "${PACMAN_TEST_EXIT:-0}"
STUB
chmod +x "$test_root/bin/sudo"
export PACMAN_TEST_LOG="$test_root/pacman-args"
export PATH="$test_root/bin:$PATH"
export XDG_CONFIG_HOME="$test_root/config"
printf '# test inventory\nexample-one\n\nexample-two # inline comment\n' >"$test_root/packages"
bash "$repo_root/bootstrap/scripts/install-pacman-packages.sh" "$test_root/packages"
printf 'pacman\n-S\n--needed\n--noconfirm\n--\nexample-one\nexample-two\n' >"$test_root/expected"
cmp "$test_root/expected" "$PACMAN_TEST_LOG"
if PACMAN_TEST_EXIT=42 bash "$repo_root/bootstrap/scripts/install-pacman-packages.sh" "$test_root/packages"; then
  echo 'Package manager failure was ignored' >&2; exit 1
fi
printf '%s\n' '--bad-option' >"$test_root/packages"
if bash "$repo_root/bootstrap/scripts/install-pacman-packages.sh" "$test_root/packages" 2>/dev/null; then
  echo 'Invalid manifest entry accepted' >&2; exit 1
fi

# Login shells must load quiet overrides even though .bashrc returns early.
fixture_home="$test_root/home"
mkdir -p "$fixture_home/.bash" "$fixture_home/.config/oh-my-devenv" "$fixture_home/.local/share/oh-my-devenv"
cp "$repo_root/dot_bash_profile" "$fixture_home/.bash_profile"
cp "$repo_root/dot_profile" "$fixture_home/.profile"
cp "$repo_root/dot_local/share/oh-my-devenv/xdg.sh" "$fixture_home/.local/share/oh-my-devenv/xdg.sh"
render_for arch '' dot_bash/env.bash.tmpl >"$fixture_home/.bash/env.bash"
render_for arch '' dot_bashrc.tmpl >"$fixture_home/.bashrc"
printf 'overlay_probe() { printf "loaded"; }\n' >"$fixture_home/.config/oh-my-devenv/env.sh"
# Source the exact login entry in a non-interactive clean Bash, without reading
# host /etc/profile or host dotfiles. All managed dependencies remain fixtures.
# shellcheck disable=SC2016
actual="$(env -u __BASH_ENV_DONE HOME="$fixture_home" XDG_CONFIG_HOME="$fixture_home/.config" \
  bash --noprofile --norc -c '. "$HOME/.bash_profile"; overlay_probe')"
[[ "$actual" == loaded ]] || { echo 'Non-interactive login overlay was not loaded' >&2; exit 1; }
echo 'Arch routing, package installer, and login overlay checks passed.'
