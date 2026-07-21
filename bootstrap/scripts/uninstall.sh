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

  Structured log prefixes (grep-friendly):
    [would-remove] [would-skip] [removed] [skipped] [backed-up]
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
# shellcheck disable=SC1091
source "$script_dir/common.sh"

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

# Paths we never delete (local overlays and secrets).
is_overlay_path() {
  local p="$1"

  case "$p" in
    "$XDG_CONFIG_HOME/oh-my-devenv/env.sh" | \
      "$XDG_CONFIG_HOME/oh-my-devenv/secrets.sh" | \
      "$XDG_CONFIG_HOME/oh-my-devenv/zshrc.zsh" | \
      "$XDG_CONFIG_HOME/oh-my-devenv/bashrc.bash" | \
      "$XDG_CONFIG_HOME/ghostty/config.local.ghostty" | \
      "$HOME/.gitconfig.local" | \
      "$XDG_CONFIG_HOME/git/hooks/pre-push" | \
      "$HOME/.npmrc")
      return 0
      ;;
  esac

  if [[ "$p" == "$HOME/.ssh/config.d/"*.conf ]]; then
    return 0
  fi

  return 1
}

# Only auto-delete the chezmoi source tree when it lives under the
# canonical per-user data dir. A `chezmoi init --apply --source=$PWD`
# checkout (CI, contributors hacking the repo) must not be removed.
can_remove_chezmoi_source() {
  local sp="$1"

  [[ "$sp" == "$HOME/.local/share/"* ]]
}

is_whitelist_dir() {
  local p="$1"

  case "$p" in
    "$HOME/.oh-my-zsh" | \
      "${XDG_DATA_HOME:-$HOME/.local/share}/fonts/maple-mono-nf-cn")
      return 0
      ;;
    "${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi-first-run-backup")
      return 0
      ;;
  esac

  if [[ "$p" == "$HOME/.local/share/chezmoi" || "$p" == "$HOME/.local/share/chezmoi/"* ]]; then
    return 0
  fi

  return 1
}

declare -A seen=()
declare -A overlay_logged=()

add_candidate() {
  local p="$1"

  [[ -z "$p" ]] && return 0
  [[ -n "${seen[$p]:-}" ]] && return 0
  seen["$p"]=1
}

# Output format also varies by environment: some builds emit newline-delimited
# paths, others emit JSON when stdout is not a TTY. Capture raw output, then
# decode JSON when needed or split newline records otherwise.
read_managed_paths_from() {
  local label="$1"
  local cap err first

  shift

  cap="$(mktemp)"
  err="$(mktemp)"
  if ! "$@" >"$cap" 2>"$err"; then
    printf 'ERROR: %s failed:\n' "$label" >&2
    cat "$err" >&2
    rm -f "$cap" "$err"
    exit 1
  fi
  if [[ -s "$err" ]]; then
    # Managed paths still went to stdout; keep stderr visible for debugging.
    cat "$err" >&2
  fi
  rm -f "$err"

  if [[ ! -s "$cap" ]]; then
    rm -f "$cap"
    return 0
  fi

  first="$(head -c1 "$cap")"
  if [[ "$first" == '[' ]]; then
    if command -v python3 >/dev/null 2>&1; then
      python3 -c '
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
if not isinstance(data, list):
    print("chezmoi managed JSON is not a list", file=sys.stderr)
    sys.exit(1)
for item in data:
    if isinstance(item, str) and item:
        print(item)
' "$cap" || {
        rm -f "$cap"
        printf 'ERROR: failed to parse chezmoi managed JSON output.\n' >&2
        exit 1
      }
    else
      rm -f "$cap"
      printf 'ERROR: %s emitted JSON but python3 is not on PATH.\n' "$label" >&2
      exit 1
    fi
  else
    sed '/^$/d' "$cap"
  fi
  rm -f "$cap"
}

read_managed_paths() {
  # Always point chezmoi at the repo that contains this script. A bare command
  # can resolve to an empty default source on CI or a source checkout.
  read_managed_paths_from \
    "chezmoi managed" \
    chezmoi --source="$repo_root" managed \
    --include=files,symlinks \
    --path-style=absolute
}

read_xdg_managed_paths() {
  read_managed_paths_from \
    "XDG chezmoi managed" \
    bash "$script_dir/xdg-config.sh" managed
}

# --- Build candidate list -------------------------------------------------

mapfile -t managed_lines < <(read_managed_paths)
mapfile -t xdg_managed_lines < <(read_xdg_managed_paths)

for line in "${managed_lines[@]}" "${xdg_managed_lines[@]}"; do
  add_candidate "$line"
done

add_candidate "${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/oh-my-devenv-xdg.boltdb"

if [[ -d "$HOME/.oh-my-zsh" ]]; then
  add_candidate "$HOME/.oh-my-zsh"
fi

managed_font_dir="${XDG_DATA_HOME:-$HOME/.local/share}/fonts/maple-mono-nf-cn"
if [[ -f "$managed_font_dir/.oh-my-devenv-managed" ]]; then
  add_candidate "$managed_font_dir"
fi

if [[ -d "${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi-first-run-backup" ]]; then
  add_candidate "${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi-first-run-backup"
fi

source_path="$(chezmoi --source="$repo_root" source-path 2>/dev/null || true)"
if [[ -n "$source_path" && -e "$source_path" ]]; then
  if can_remove_chezmoi_source "$source_path"; then
    add_candidate "$source_path"
  else
    would_skip "chezmoi source-path $source_path (outside ~/.local/share — not auto-deleted)"
  fi
fi

# Longest paths first so nested files disappear before parent dirs.
mapfile -t candidates < <(printf '%s\n' "${!seen[@]}" | awk '{ print length, $0 }' | sort -nr | cut -d' ' -f2-)

declare -a rem_files=()
declare -a rem_dirs=()

for p in "${candidates[@]}"; do
  if is_overlay_path "$p"; then
    overlay_logged["$p"]=1
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
done

# User-created overlays may not appear in `chezmoi managed`; still log them
# when present so dry-run output documents protection (CI smoke greps this).
emit_standalone_overlay_slots() {
  local f

  for f in \
    "$XDG_CONFIG_HOME/oh-my-devenv/env.sh" \
    "$XDG_CONFIG_HOME/oh-my-devenv/secrets.sh" \
    "$XDG_CONFIG_HOME/oh-my-devenv/zshrc.zsh" \
    "$XDG_CONFIG_HOME/oh-my-devenv/bashrc.bash" \
    "$XDG_CONFIG_HOME/ghostty/config.local.ghostty" \
    "$HOME/.gitconfig.local" \
    "$XDG_CONFIG_HOME/git/hooks/pre-push" \
    "$HOME/.npmrc"; do
    [[ -e "$f" ]] || continue
    [[ -n "${overlay_logged[$f]:-}" ]] && continue
    would_skip "overlay-protected: $f"
  done

  if [[ -d "$HOME/.ssh/config.d" ]]; then
    for f in "$HOME/.ssh/config.d/"*.conf; do
      [[ -e "$f" ]] || continue
      [[ -n "${overlay_logged[$f]:-}" ]] && continue
      would_skip "overlay-protected: $f"
    done
  fi
}

emit_standalone_overlay_slots

if (( CONFIRM == 0 )); then
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

  for p in "${rem_files[@]}"; do
    if [[ -e "$p" ]]; then
      printf '%s\n' "$p" >>"$listfile"
    fi
  done

  if [[ -s "$listfile" ]]; then
    backup_archive="$backup_root/managed-files.tgz"
    tar --absolute-names -czf "$backup_archive" -T "$listfile"
    backed_up "$backup_archive"
  fi

  mapfile -t rem_dirs_sorted < <(printf '%s\n' "${rem_dirs[@]}" | awk '{ print length, $0 }' | sort -nr | cut -d' ' -f2-)
  for d in "${rem_dirs_sorted[@]}"; do
    [[ -d "$d" ]] || continue
    base="$(basename "$d")"
    parent="$(dirname "$d")"
    safe_name="${base//\//_}"
    arc="$backup_root/tree-${safe_name}.tgz"
    tar -czf "$arc" -C "$parent" "$base"
    backed_up "$arc"
  done

  trap - EXIT
  rm -f "$listfile"
else
  printf '[skipped] backup (--no-backup)\n'
fi

# --- Remove ---------------------------------------------------------------

for p in "${rem_files[@]}"; do
  if [[ -f "$p" || -L "$p" ]]; then
    rm -f "$p"
    removed "$p"
  fi
done

mapfile -t rem_dirs_sorted < <(printf '%s\n' "${rem_dirs[@]}" | awk '{ print length, $0 }' | sort -nr | cut -d' ' -f2-)
for d in "${rem_dirs_sorted[@]}"; do
  if [[ -d "$d" ]]; then
    rm -rf "$d"
    removed "$d"
  fi
done

printf '\nUninstall finished (--confirm). Re-run chezmoi init when you want the baseline back.\n'
