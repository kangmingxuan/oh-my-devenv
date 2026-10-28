#!/usr/bin/env bash
#
# Run the clean-machine round trip that CI requires on every platform: apply,
# reapply, uninstall, and restore. The script applies to and uninstalls from
# $HOME, so it runs only in disposable environments that set CI=true.
set -euo pipefail

if [[ $# -ne 1 || ( "$1" != true && "$1" != false ) ]]; then
  printf 'USAGE: %s <desktop-baseline: true|false>\n' "$0" >&2
  exit 2
fi
desktop_baseline="$1"

if [[ "${CI:-}" != true ]]; then
  printf 'ERROR: %s applies to and uninstalls from the home directory. Run it only in a disposable environment with CI=true.\n' "$0" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

# shellcheck disable=SC1091
source "$script_dir/common.sh"

work_dir="$(mktemp -d)"
default_config_root="$HOME/.config"
xdg_config_root="${XDG_CONFIG_HOME:-$default_config_root}"

step() {
  printf '\n==> %s\n' "$*"
}

apply_baseline() {
  local log_file="$1"
  chezmoi apply --source="$repo_root" 2>&1 | tee "$log_file"
}

assert_hooks_ran() {
  if ! grep -Fq "All checks passed." "$1"; then
    printf 'ERROR: the final hook did not report success in %s.\n' "$1" >&2
    exit 1
  fi
}

step "Seed pre-existing user files"
mkdir -p "$HOME" "$default_config_root/mise"
printf '%s\n' '# pre-existing zshrc' >"$HOME/.zshrc"
printf '%s\n' 'unmanaged_sentinel = true' >"$default_config_root/mise/config.toml"

step "Render the chezmoi config at its default location"
config_file="$xdg_config_root/chezmoi/chezmoi.toml"
mkdir -p "$(dirname "$config_file")"
cat >"$work_dir/data.toml" <<EOF
name = "CI Runner"
email = "ci@example.com"
desktopBaseline = $desktop_baseline
EOF
chezmoi execute-template --init \
  --source="$repo_root" \
  --override-data-file "$work_dir/data.toml" \
  --file "$repo_root/.chezmoi.toml.tmpl" >"$config_file"

step "First apply"
apply_baseline "$work_dir/apply-first.log"
assert_hooks_ran "$work_dir/apply-first.log"
bash "$script_dir/check.sh"

step "Check the first-run backup and unmanaged files"
backup_root="$(first_run_backup_root)"
grep -Fxq '# pre-existing zshrc' "$backup_root"/*"$HOME/.zshrc"
if [[ "$xdg_config_root" == "$default_config_root" ]]; then
  # The managed mise config replaced the seeded file after the backup.
  grep -Fxq 'unmanaged_sentinel = true' "$backup_root"/*"$default_config_root/mise/config.toml"
else
  # A custom XDG root leaves the default location unmanaged.
  grep -Fxq 'unmanaged_sentinel = true' "$default_config_root/mise/config.toml"
  test -f "$xdg_config_root/mise/config.toml"
fi

step "Reapply without changes"
apply_baseline "$work_dir/apply-again.log"
if grep -Fq "All checks passed." "$work_dir/apply-again.log"; then
  printf 'ERROR: an unchanged reapply reran the change-triggered final hook.\n' >&2
  exit 1
fi
bash "$script_dir/check.sh"

step "Uninstall"
bash "$script_dir/uninstall.sh" --confirm --no-backup
# Restore depends on both buckets being empty, not only on the final hook.
for bucket in scriptState entryState; do
  bucket_contents="$(chezmoi --source="$repo_root" state get-bucket --bucket="$bucket")"
  if [[ "$bucket_contents" != "{}" ]]; then
    printf 'ERROR: uninstall left entries in the chezmoi %s bucket.\n' "$bucket" >&2
    exit 1
  fi
done
if bash "$script_dir/check.sh" >"$work_dir/check-after-uninstall.log" 2>&1; then
  cat "$work_dir/check-after-uninstall.log"
  printf 'ERROR: the environment check passed after uninstall.\n' >&2
  exit 1
fi

step "Restore with apply"
apply_baseline "$work_dir/apply-restore.log"
assert_hooks_ran "$work_dir/apply-restore.log"
bash "$script_dir/check.sh"

step "Round trip passed"
