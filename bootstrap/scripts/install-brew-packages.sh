#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/common.sh"

BREWFILE="${1:-}"
BREW_CMD=""

if [[ -z "$BREWFILE" ]]; then
  log_error "$0 <brewfile-path>"
  exit 1
fi

if [[ ! -f "$BREWFILE" ]]; then
  log_error "$BREWFILE not found"
  exit 1
fi

BREW_CMD="$(brew_command)"

# Load Homebrew environment for this script invocation.
eval "$("$BREW_CMD" shellenv)"

log_info "Installing Homebrew packages from $BREWFILE"
"$BREW_CMD" bundle install --file="$BREWFILE"

log_ok Homebrew "Packages installed."
