#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bootstrap_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$bootstrap_dir/.." && pwd)"

cd "$repo_root"

failures=0

check_path_absent() {
  local path="$1"

  if [[ -e "$path" ]]; then
    printf 'ERROR: public repo should not contain %s\n' "$path" >&2
    failures=1
  fi
}

check_pattern_absent() {
  local pattern="$1"
  shift
  local matches=""

  matches="$(grep -RInE \
    --include='*.md' \
    --include='*.tmpl' \
    --include='*.example' \
    --include='*.sh' \
    --include='*.yml' \
    --include='*.yaml' \
    "$pattern" "$@" 2>/dev/null || true)"

  if [[ -n "$matches" ]]; then
    printf '%s\n' "$matches" >&2
    printf 'ERROR: public-boundary lint found forbidden pattern: %s\n' "$pattern" >&2
    failures=1
  fi
}

check_path_absent ".gitlab"
check_path_absent "AGENTS.md"
check_path_absent "CODEOWNERS"
check_path_absent "docs/02-corp-network-integration.md"

scan_paths=(
  "README.md"
  "CONTRIBUTING.md"
  "CHANGELOG.md"
  ".chezmoi.toml.tmpl"
  "dot_gitconfig.tmpl"
  "docs/README.md"
  "docs/01-onboarding.md"
  "docs/03-macos-preflight.md"
  "docs/04-maintenance.md"
  "docs/local-overlay-examples"
  ".github"
)

check_pattern_absent 'git\.garena\.com' "${scan_paths[@]}"
check_pattern_absent '@shopee\.com' "${scan_paths[@]}"
check_pattern_absent 'ssh://gitlab@' "${scan_paths[@]}"
check_pattern_absent 'Shopee GitLab' "${scan_paths[@]}"
check_pattern_absent 'Shopee identity' "${scan_paths[@]}"
check_pattern_absent 'non-Shopee' "${scan_paths[@]}"
check_pattern_absent 'Shopee-native' "${scan_paths[@]}"
check_pattern_absent '<ssh-clone-url>' "${scan_paths[@]}"
check_pattern_absent '<https-clone-url>' "${scan_paths[@]}"

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

printf 'Public boundary lint passed.\n'
