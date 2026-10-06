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

if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: git not found in PATH" >&2
  exit 1
fi

if ! command -v zsh >/dev/null 2>&1; then
  echo "ERROR: zsh not found in PATH" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"

ZSH_DIR="$(oh_my_devenv_oh_my_zsh_dir)"
ZSH_CUSTOM_DIR="$ZSH_DIR/custom"

# bootstrap.env may point the oh-my-zsh clone elsewhere; plugin repositories
# are cloned from github.com.
OH_MY_ZSH_REPO="${DOTFILES_OH_MY_ZSH_GIT_URL:-https://github.com/ohmyzsh/ohmyzsh.git}"

clone_or_update_repo() {
  local repo_url="$1"
  local target_dir="$2"

  if [[ ! -e "$target_dir" ]]; then
    mkdir -p "$(dirname "$target_dir")"
    git clone --depth 1 "$repo_url" "$target_dir"
    return 0
  fi

  if [[ ! -d "$target_dir/.git" ]]; then
    echo "WARNING: $target_dir exists but is not a git repository, skipping" >&2
    return 0
  fi

  if [[ -n "$(git -C "$target_dir" status --porcelain 2>/dev/null)" ]]; then
    echo "WARNING: $target_dir has local changes, skipping update" >&2
    return 0
  fi

  git -C "$target_dir" pull --ff-only --quiet
}

echo "==> Ensuring oh-my-zsh is installed in $ZSH_DIR"
clone_or_update_repo "$OH_MY_ZSH_REPO" "$ZSH_DIR"

mkdir -p "$ZSH_CUSTOM_DIR"

plugins=()
while IFS= read -r plugin; do
  plugins+=("$plugin")
done < <(manifest_entries "$MANIFEST")

if [[ ${#plugins[@]} -eq 0 ]]; then
  echo "No oh-my-zsh plugins to install."
  exit 0
fi

echo "==> Ensuring oh-my-zsh plugins from $MANIFEST"
for plugin in "${plugins[@]}"; do
  read -r repo path extra <<<"$plugin"

  if [[ -z "$repo" || -z "$path" || -n "$extra" ]]; then
    echo "ERROR: invalid plugin entry '$plugin' in $MANIFEST" >&2
    exit 1
  fi

  echo "  -> $repo"
  clone_or_update_repo "https://github.com/$repo.git" "$ZSH_CUSTOM_DIR/$path"
done

echo "==> oh-my-zsh assets are ready."
