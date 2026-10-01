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

BREW_CMD="$(brew_command)"

# Load Homebrew environment for this script invocation.
eval "$($BREW_CMD shellenv)"

echo "==> Installing Homebrew packages from $BREWFILE"
"$BREW_CMD" bundle install --file="$BREWFILE"

echo "==> Homebrew packages installed successfully."
