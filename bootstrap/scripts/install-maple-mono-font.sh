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

MAPLE_MONO_VERSION=""
MAPLE_MONO_ARCHIVE=""
MAPLE_MONO_URL=""
MAPLE_MONO_SHA256=""
# This repository-owned manifest contains only fixed scalar assignments.
# shellcheck disable=SC1090
source "$MANIFEST"

for required_value in \
  MAPLE_MONO_VERSION \
  MAPLE_MONO_ARCHIVE \
  MAPLE_MONO_URL \
  MAPLE_MONO_SHA256; do
  if [[ -z "${!required_value:-}" ]]; then
    echo "ERROR: $MANIFEST does not define $required_value" >&2
    exit 1
  fi
done

if [[ ! "$MAPLE_MONO_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR: MAPLE_MONO_SHA256 is not a lowercase SHA-256 digest" >&2
  exit 1
fi

for required_command in curl fc-cache fc-list fc-scan sha256sum unzip; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $required_command" >&2
    exit 1
  fi
done

required_postscript_names=(
  MapleMono-NF-CN-Regular
  MapleMono-NF-CN-Bold
  MapleMono-NF-CN-Italic
  MapleMono-NF-CN-BoldItalic
)

font_family_complete() {
  local installed_names=""
  local postscript_name=""

  installed_names="$(fc-list -f '%{postscriptname}\n' ':family=Maple Mono NF CN')"
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
  echo "Maple Mono NF CN $MAPLE_MONO_VERSION is already installed."
  exit 0
fi

if [[ ! -f "$managed_marker" ]] && font_family_complete; then
  echo "A compatible Maple Mono NF CN installation already exists; leaving it untouched."
  exit 0
fi

download_dir="${XDG_CACHE_HOME:-$HOME/.cache}/oh-my-devenv/downloads"
archive_path="$download_dir/$MAPLE_MONO_ARCHIVE"
font_url="${DOTFILES_MAPLE_MONO_URL:-$MAPLE_MONO_URL}"
mkdir -p "$download_dir"

if ! checksum_matches "$archive_path"; then
  echo "==> Downloading Maple Mono NF CN $MAPLE_MONO_VERSION"
  curl_args=(
    --fail
    --location
    --show-error
    --retry 5
    --retry-delay 2
    --retry-all-errors
    --output "$archive_path"
  )
  if [[ -f "$archive_path" ]]; then
    curl_args+=(--continue-at -)
  fi
  curl "${curl_args[@]}" "$font_url" || true
fi

if ! checksum_matches "$archive_path"; then
  invalid_archive="$archive_path.invalid"
  if [[ -f "$archive_path" ]]; then
    mv -f "$archive_path" "$invalid_archive"
  fi
  echo "==> Restarting the font download after an invalid or incomplete cached archive"
  curl \
    --fail \
    --location \
    --show-error \
    --retry 5 \
    --retry-delay 2 \
    --retry-all-errors \
    --output "$archive_path" \
    "$font_url"
  rm -f "$invalid_archive"
fi

if ! checksum_matches "$archive_path"; then
  echo "ERROR: checksum verification failed for $MAPLE_MONO_ARCHIVE" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
stage_dir=""
previous_dir=""
installed_new_dir=0
install_committed=0
cleanup() {
  rm -rf "$work_dir"
  if [[ -n "$stage_dir" && -d "$stage_dir" ]]; then
    rm -rf "$stage_dir"
  fi

  if (( install_committed == 0 )); then
    if (( installed_new_dir == 1 )); then
      rm -rf "$font_dir"
    fi
    if [[ -n "$previous_dir" && -d "$previous_dir" ]]; then
      if mv "$previous_dir" "$font_dir"; then
        fc-cache -f "$font_dir" >/dev/null 2>&1 || true
      else
        echo "ERROR: failed to restore previous font directory: $previous_dir" >&2
      fi
    fi
  elif [[ -n "$previous_dir" && -d "$previous_dir" ]]; then
    rm -rf "$previous_dir"
  fi
}
trap cleanup EXIT

unzip -q "$archive_path" -d "$work_dir"
mapfile -d '' font_files < <(find "$work_dir" -type f -name '*.ttf' -print0 | sort -z)
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

mkdir -p "$fonts_root"
stage_dir="$(mktemp -d "$fonts_root/.maple-mono-nf-cn.XXXXXX")"
for font_file in "${font_files[@]}"; do
  install -m 0644 "$font_file" "$stage_dir/$(basename "$font_file")"
done
printf '%s\n' "$expected_marker" >"$stage_dir/.oh-my-devenv-managed"

if [[ -d "$font_dir" ]]; then
  if [[ ! -f "$managed_marker" ]]; then
    echo "ERROR: refusing to replace unowned font directory: $font_dir" >&2
    exit 1
  fi
  previous_dir="$(mktemp -d "$fonts_root/.maple-mono-nf-cn.previous.XXXXXX")"
  rmdir "$previous_dir"
  mv "$font_dir" "$previous_dir"
fi

mv "$stage_dir" "$font_dir"
stage_dir=""
installed_new_dir=1

fc-cache -f "$font_dir" >/dev/null
if ! font_family_complete; then
  echo "ERROR: Maple Mono NF CN did not register with Fontconfig" >&2
  exit 1
fi

install_committed=1
if [[ -n "$previous_dir" && -d "$previous_dir" ]]; then
  rm -rf "$previous_dir"
  previous_dir=""
fi

echo "==> Maple Mono NF CN $MAPLE_MONO_VERSION installed successfully."
