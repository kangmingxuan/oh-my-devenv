#!/usr/bin/env bash
#
# Reverse chezmoi-managed baseline files plus a small whitelist of
# bootstrap-owned directories. Default is dry-run; nothing is deleted
# unless you pass --confirm.
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"

usage() {
  log_phase "Usage: uninstall.sh [--confirm] [--no-backup]"
  log_info "Default: preview the candidate paths and state buckets."
  log_info "--confirm: back up and remove the candidates, then clear scriptState and entryState."
  log_info "--no-backup: skip the pre-delete tarball with --confirm."
  log_info "The source checkout and installed packages, mise shims, and Go and uv tools stay in place."
  log_phase_done
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
      log_error "unknown argument: $1" "Usage: uninstall.sh [--confirm] [--no-backup]"
      exit 1
      ;;
  esac
  shift
done

# shellcheck disable=SC1091
source "$script_dir/local-overlays.sh"
local_overlay_load

install_error_trap "$0"
if (( CONFIRM )); then
  log_phase "Uninstalling the baseline..."
else
  log_phase "Uninstall preview"
fi

if ! command -v chezmoi >/dev/null 2>&1; then
  log_error "chezmoi is not on PATH; cannot enumerate managed files."
  exit 1
fi

report_uninstall_skip() {
  if (( CONFIRM )); then
    log_skip "$1"
  else
    log_would skip "$1"
  fi
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
  log_error "chezmoi managed failed."
  exit 1
}
completion_candidates="$(list_owned_completions)" || {
  log_error "shell completion inventory failed."
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
    report_uninstall_skip "overlay-protected: $p"
    continue
  fi

  if [[ -d "$p" ]]; then
    if is_whitelist_dir "$p"; then
      if (( CONFIRM == 0 )); then log_would remove "directory (whitelist): $p"; fi
      rem_dirs+=("$p")
    else
      report_uninstall_skip "directory not on whitelist (manual cleanup if needed): $p"
    fi
    continue
  fi

  if [[ -f "$p" || -L "$p" ]]; then
    if (( CONFIRM == 0 )); then log_would remove "file: $p"; fi
    rem_files+=("$p")
    continue
  fi

  report_uninstall_skip "path does not exist: $p"
done < <(printf '%s\n' "$candidates" | sort -u | longest_first)

# User-created overlays may not appear in `chezmoi managed`; still log them
# when present so the dry run documents their protection.
while IFS= read -r p; do
  [[ "$overlay_logged" == *$'\n'"$p"$'\n'* ]] && continue
  report_uninstall_skip "overlay-protected: $p"
done < <(local_overlay_existing_paths)

if (( CONFIRM == 0 )); then
  for bucket in scriptState entryState; do
    log_would reset "main chezmoi state bucket: $bucket"
  done
  log_phase_done
  log_summary "Dry-run complete (--confirm not passed). No files were deleted."
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
    log_ok backed-up "$backup_archive"
  fi

  for d in ${rem_dirs[@]+"${rem_dirs[@]}"}; do
    [[ -d "$d" ]] || continue
    arc="$backup_root/tree-$(basename "$d").tgz"
    tar -czf "$arc" -C "$(dirname "$d")" "$(basename "$d")"
    log_ok backed-up "$arc"
  done
else
  log_skip "backup (--no-backup)"
fi

# --- Remove ---------------------------------------------------------------

for p in ${rem_files[@]+"${rem_files[@]}"}; do
  if [[ $'\n'"$completion_candidates"$'\n' == *$'\n'"$p"$'\n'* ]]; then
    # Reuse the installer's ownership check immediately before deletion. A
    # user may have replaced a generated file since the initial inventory.
    current_completions="$(list_owned_completions)"
    if [[ $'\n'"$current_completions"$'\n' != *$'\n'"$p"$'\n'* ]]; then
      log_skip "completion is no longer owned: $p"
      continue
    fi
  fi
  if [[ -f "$p" || -L "$p" ]]; then
    rm -f "$p"
    log_ok removed "$p"
  fi
done

for d in ${rem_dirs[@]+"${rem_dirs[@]}"}; do
  if [[ -d "$d" ]]; then
    rm -rf "$d"
    log_ok removed "$d"
  fi
done

# Use the same source and default config resolution as the managed inventory.
# run_once scripts use scriptState; run_onchange scripts use entryState.
for bucket in scriptState entryState; do
  chezmoi --source="$repo_root" state delete-bucket --bucket="$bucket"
  log_ok reset "main chezmoi state bucket: $bucket"
done

log_phase_done
log_summary "Uninstall finished (--confirm). Source checkout kept."
log_next "Re-run chezmoi apply to restore the baseline."
