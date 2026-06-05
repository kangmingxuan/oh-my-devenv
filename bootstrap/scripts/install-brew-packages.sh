#!/usr/bin/env bash
set -euo pipefail

BREWFILE="${1:-}"
BREW_CMD=""

if [[ -z "$BREWFILE" ]]; then
  echo "USAGE: $0 <brewfile-path>" >&2
  exit 1
fi

if [[ ! -f "$BREWFILE" ]]; then
  echo "ERROR: $BREWFILE not found" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"

# Honor mirror-mode overrides for HOMEBREW_API_DOMAIN /
# HOMEBREW_BOTTLE_DOMAIN. A no-op in external mode; in internal mode,
# exports these iff the user supplied DOTFILES_HOMEBREW_* overrides.
dotfiles_apply_mirror_env

if command -v brew >/dev/null 2>&1; then
  BREW_CMD="$(command -v brew)"
elif [[ -x /opt/homebrew/bin/brew ]]; then
  BREW_CMD="/opt/homebrew/bin/brew"
elif [[ -x /usr/local/bin/brew ]]; then
  BREW_CMD="/usr/local/bin/brew"
else
  echo "ERROR: brew not found in PATH or common install locations" >&2
  exit 1
fi

# Load Homebrew environment for this script invocation.
eval "$($BREW_CMD shellenv)"

echo "==> Installing Homebrew packages from $BREWFILE"
"$BREW_CMD" bundle install --file="$BREWFILE"

echo "==> Homebrew packages installed successfully."
