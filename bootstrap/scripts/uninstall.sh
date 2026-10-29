#!/usr/bin/env bash
#
# Reverse chezmoi-managed baseline files plus a small whitelist of
# bootstrap-owned directories. Default is dry-run; nothing is deleted
# unless you pass --confirm.
#
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: uninstall.sh [--confirm] [--no-backup]

  Default (no flags): dry-run. Prints [would-remove] / [would-skip] for
  every candidate path and exits 0 without deleting anything.

  --confirm       Actually remove candidates after an optional backup.
  --no-backup     With --confirm, skip the pre-delete tarball (for CI).

  Never removes apt/Homebrew packages, mise shims, or Go/uv-managed installs.
  Always keeps the chezmoi source checkout. Confirmation also clears the main
  scriptState and entryState buckets so the next apply can rerun the hooks.

  Structured log prefixes (grep-friendly):
    [would-remove] [would-skip] [would-reset] [removed] [skipped] [backed-up] [reset]
USAGE
}

CONFIRM=0
NO_BACKUP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm)
      CONFIRM=1
      ;;
    --no-backup)
      NO_BACKUP=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# common.sh resolves the XDG directories and loads bootstrap.env, so this
# process and the producers it calls see the same paths.
# shellcheck disable=SC1091
source "$script_dir/common.sh"
# shellcheck disable=SC1091
source "$script_dir/local-overlays.sh"
local_overlay_load

if ! command -v chezmoi >/dev/null 2>&1; then
  printf 'ERROR: chezmoi is not on PATH; cannot enumerate managed files.\n' >&2
  exit 1
fi

would_remove() {
  printf '[would-remove] %s\n' "$*"
}

would_skip() {
  printf '[would-skip] %s\n' "$*"
}

removed() {
  printf '[removed] %s\n' "$*"
}

backed_up() {
  printf '[backed-up] %s\n' "$*"
}

is_whitelist_dir() {
  case "$1" in
    "$(oh_my_devenv_oh_my_zsh_dir)" | \
      "$(maple_mono_font_dir)" | \
      "$(first_run_backup_root)")
      return 0
      ;;
  esac

  return 1
}

# Print one path per line, longest first, so nested files disappear before
# their parent directories.
longest_first() {
  awk 'NF { print length, $0 }' | sort -nr | cut -d' ' -f2-
}

# --- Build candidate list -------------------------------------------------

# chezmoi prints one absolute path per line with `--format=`. Always point it
# at the repo that contains this script; a bare command can resolve to an
# empty default source on CI or a source checkout. A failing producer aborts
# the run instead of yielding an empty candidate list.
case "$(uname -s)" in
  Darwin) completion_platform=darwin ;;
  *) completion_platform=linux ;;
esac

list_owned_completions() {
  "$BASH" "$script_dir/install-shell-completions.sh" list "$completion_platform" \
    "$repo_root/bootstrap/manifests/shell/completions.txt"
}

candidates="$(
  chezmoi --source="$repo_root" managed \
    --include=files,symlinks \
    --path-style=absolute \
    --format=
)" || {
  printf 'ERROR: chezmoi managed failed.\n' >&2
  exit 1
}
completion_candidates="$(list_owned_completions)" || {
  printf 'ERROR: shell completion inventory failed.\n' >&2
  exit 1
}
candidates+=$'\n'"$completion_candidates"

if [[ -d "$(oh_my_devenv_oh_my_zsh_dir)" ]]; then
  candidates+=$'\n'"$(oh_my_devenv_oh_my_zsh_dir)"
fi

if [[ -f "$(maple_mono_font_marker)" ]]; then
  candidates+=$'\n'"$(maple_mono_font_dir)"
fi

if [[ -d "$(first_run_backup_root)" ]]; then
  candidates+=$'\n'"$(first_run_backup_root)"
fi

rem_files=()
rem_dirs=()
overlay_logged=$'\n'

while IFS= read -r p; do
  if local_overlay_matches_path "$p"; then
    overlay_logged+="$p"$'\n'
    would_skip "overlay-protected: $p"
    continue
  fi

  if [[ -d "$p" ]]; then
    if is_whitelist_dir "$p"; then
      would_remove "directory (whitelist): $p"
      rem_dirs+=("$p")
    else
      would_skip "directory not on whitelist (manual cleanup if needed): $p"
    fi
    continue
  fi

  if [[ -f "$p" || -L "$p" ]]; then
    would_remove "file: $p"
    rem_files+=("$p")
    continue
  fi

  would_skip "path does not exist: $p"
done < <(printf '%s\n' "$candidates" | sort -u | longest_first)

# User-created overlays may not appear in `chezmoi managed`; still log them
# when present so the dry run documents their protection.
while IFS= read -r p; do
  [[ "$overlay_logged" == *$'\n'"$p"$'\n'* ]] && continue
  would_skip "overlay-protected: $p"
done < <(local_overlay_existing_paths)

if (( CONFIRM == 0 )); then
  printf '[would-reset] main chezmoi state bucket: %s\n' scriptState entryState
  printf '\nDry-run complete (--confirm not passed). No files were deleted.\n'
  exit 0
fi

# --- Backup ---------------------------------------------------------------

if (( NO_BACKUP == 0 )); then
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_root="${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi-uninstall-backup/$ts"
  mkdir -p "$backup_root"
  listfile="$(mktemp)"
  trap 'rm -f "$listfile"' EXIT

  for p in ${rem_files[@]+"${rem_files[@]}"}; do
    if [[ -e "$p" || -L "$p" ]]; then
      printf '%s\n' "$p" >>"$listfile"
    fi
  done

  if [[ -s "$listfile" ]]; then
    backup_archive="$backup_root/managed-files.tgz"
    tar -P -czf "$backup_archive" -T "$listfile"
    backed_up "$backup_archive"
  fi

  for d in ${rem_dirs[@]+"${rem_dirs[@]}"}; do
    [[ -d "$d" ]] || continue
    arc="$backup_root/tree-$(basename "$d").tgz"
    tar -czf "$arc" -C "$(dirname "$d")" "$(basename "$d")"
    backed_up "$arc"
  done
else
  printf '[skipped] backup (--no-backup)\n'
fi

# --- Remove ---------------------------------------------------------------

for p in ${rem_files[@]+"${rem_files[@]}"}; do
  if [[ $'\n'"$completion_candidates"$'\n' == *$'\n'"$p"$'\n'* ]]; then
    # Reuse the installer's ownership check immediately before deletion. A
    # user may have replaced a generated file since the initial inventory.
    current_completions="$(list_owned_completions)"
    if [[ $'\n'"$current_completions"$'\n' != *$'\n'"$p"$'\n'* ]]; then
      printf '[skipped] completion is no longer owned: %s\n' "$p"
      continue
    fi
  fi
  if [[ -f "$p" || -L "$p" ]]; then
    rm -f "$p"
    removed "$p"
  fi
done

for d in ${rem_dirs[@]+"${rem_dirs[@]}"}; do
  if [[ -d "$d" ]]; then
    rm -rf "$d"
    removed "$d"
  fi
done

# Use the same source and default config resolution as the managed inventory.
# run_once scripts use scriptState; run_onchange scripts use entryState.
for bucket in scriptState entryState; do
  chezmoi --source="$repo_root" state delete-bucket --bucket="$bucket"
  printf '[reset] main chezmoi state bucket: %s\n' "$bucket"
done

printf '\nUninstall finished (--confirm). Source checkout kept. Re-run chezmoi apply to restore the baseline.\n'
