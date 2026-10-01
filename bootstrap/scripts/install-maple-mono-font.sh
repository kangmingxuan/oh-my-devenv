#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${1:-}"

if [[ -z "$MANIFEST" ]]; then
  echo "USAGE: $0 <manifest-path>" >&2
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: $MANIFEST not found" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"

desktop_font_manifest_load "$MANIFEST"

for required_command in curl fc-cache fc-list fc-scan sha256sum unzip; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $required_command" >&2
    exit 1
  fi
done

required_postscript_names=()
for postscript_name in $MAPLE_MONO_POSTSCRIPT_NAMES; do
  required_postscript_names+=("$postscript_name")
done

font_family_complete() {
  local installed_names=""
  local postscript_name=""

  installed_names="$(fc-list -f '%{postscriptname}\n' ":family=$MAPLE_MONO_FAMILY")"
  for postscript_name in "${required_postscript_names[@]}"; do
    if ! grep -Fxq "$postscript_name" <<<"$installed_names"; then
      return 1
    fi
  done
}

checksum_matches() {
  local archive_path="$1"

  [[ -f "$archive_path" ]] || return 1
  printf '%s  %s\n' "$MAPLE_MONO_SHA256" "$archive_path" | sha256sum --check --status
}

fonts_root="${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
font_dir="$fonts_root/maple-mono-nf-cn"
managed_marker="$font_dir/.oh-my-devenv-managed"
expected_marker="version=$MAPLE_MONO_VERSION sha256=$MAPLE_MONO_SHA256"

if [[ -f "$managed_marker" ]] && \
  grep -Fxq "$expected_marker" "$managed_marker" && \
  font_family_complete; then
  echo "$MAPLE_MONO_FAMILY $MAPLE_MONO_VERSION is already installed."
  exit 0
fi

if [[ ! -f "$managed_marker" ]] && font_family_complete; then
  echo "A compatible $MAPLE_MONO_FAMILY installation already exists; leaving it untouched."
  exit 0
fi

download_dir="${XDG_CACHE_HOME:-$HOME/.cache}/oh-my-devenv/downloads"
archive_path="$download_dir/$MAPLE_MONO_ARCHIVE"
mkdir -p "$download_dir"

download_font_archive() {
  curl \
    --fail \
    --location \
    --show-error \
    --retry 5 \
    --retry-delay 2 \
    --retry-all-errors \
    "$@" \
    --output "$archive_path.part" \
    "${DOTFILES_MAPLE_MONO_URL:-$MAPLE_MONO_URL}"
}

# A partial download resumes on the next run, and restarts when the server
# cannot resume it. A complete archive that fails verification is discarded so
# the next run starts over.
if ! checksum_matches "$archive_path"; then
  echo "==> Downloading $MAPLE_MONO_FAMILY $MAPLE_MONO_VERSION"
  if ! download_font_archive --continue-at -; then
    rm -f "$archive_path.part"
    download_font_archive
  fi
  mv -f "$archive_path.part" "$archive_path"
  if ! checksum_matches "$archive_path"; then
    rm -f "$archive_path"
    echo "ERROR: checksum verification failed for $MAPLE_MONO_ARCHIVE" >&2
    exit 1
  fi
fi

work_dir="$(mktemp -d)"
stage_dir=""
previous_dir=""
swapped=0
committed=0
# Until Fontconfig confirms the new faces, any exit removes the new directory
# and restores the previous managed one.
cleanup() {
  rm -rf "$work_dir"
  if [[ -n "$stage_dir" ]]; then
    rm -rf "$stage_dir"
  fi
  if (( committed == 1 )); then
    return
  fi
  if (( swapped == 1 )); then
    rm -rf "$font_dir"
  fi
  if [[ -n "$previous_dir" && -d "$previous_dir" ]]; then
    mv "$previous_dir" "$font_dir"
    fc-cache -f "$font_dir" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

unzip -q "$archive_path" -d "$work_dir"
font_files=()
while IFS= read -r -d '' font_file; do
  font_files+=("$font_file")
done < <(find "$work_dir" -type f -name '*.ttf' -print0 | sort -z)
if [[ ${#font_files[@]} -eq 0 ]]; then
  echo "ERROR: $MAPLE_MONO_ARCHIVE contains no TTF files" >&2
  exit 1
fi

archive_postscript_names=""
for font_file in "${font_files[@]}"; do
  archive_postscript_names+="$(fc-scan --format='%{postscriptname}\n' "$font_file")"$'\n'
done
for postscript_name in "${required_postscript_names[@]}"; do
  if ! grep -Fxq "$postscript_name" <<<"$archive_postscript_names"; then
    echo "ERROR: archive is missing required font $postscript_name" >&2
    exit 1
  fi
done

if [[ -d "$font_dir" && ! -f "$managed_marker" ]]; then
  echo "ERROR: refusing to replace unowned font directory: $font_dir" >&2
  exit 1
fi

mkdir -p "$fonts_root"
stage_dir="$(mktemp -d "$fonts_root/.maple-mono-nf-cn.XXXXXX")"
for font_file in "${font_files[@]}"; do
  install -m 0644 "$font_file" "$stage_dir/$(basename "$font_file")"
done
printf '%s\n' "$expected_marker" >"$stage_dir/.oh-my-devenv-managed"

# Swap the staged directory into place, keeping the previous managed copy
# beside it until Fontconfig confirms the new faces.
if [[ -d "$font_dir" ]]; then
  previous_dir="$stage_dir.previous"
  mv "$font_dir" "$previous_dir"
fi
mv "$stage_dir" "$font_dir"
stage_dir=""
swapped=1

fc-cache -f "$font_dir" >/dev/null
if ! font_family_complete; then
  echo "ERROR: $MAPLE_MONO_FAMILY did not register with Fontconfig" >&2
  exit 1
fi
committed=1
rm -rf "$previous_dir"

echo "==> $MAPLE_MONO_FAMILY $MAPLE_MONO_VERSION installed successfully."
