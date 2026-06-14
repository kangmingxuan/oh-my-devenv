#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bootstrap_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$bootstrap_dir/.." && pwd)"

cd "$repo_root"

denylist_file="bootstrap/manifests/system/boundary-denylist.txt"

failures=0

check_path_absent() {
  local path="$1"

  if [[ -e "$path" ]]; then
    printf 'ERROR: public repo should not contain %s\n' "$path" >&2
    failures=1
  fi
}

# Scan the entire working tree for a forbidden pattern. Unlike the previous
# fixed list of paths, this covers the lint script itself, every dot_*
# template, the bootstrap scripts, and the CI files, so a regression cannot
# hide in an unscanned file. The denylist file is excluded because it
# legitimately contains the patterns.
check_pattern_absent() {
  local pattern="$1"
  local matches=""

  matches="$(grep -RInE \
    --binary-files=without-match \
    --exclude-dir='.git' \
    --exclude="$(basename "$denylist_file")" \
    "$pattern" . 2>/dev/null || true)"

  if [[ -n "$matches" ]]; then
    printf '%s\n' "$matches" >&2
    printf 'ERROR: public-boundary lint found forbidden pattern: %s\n' "$pattern" >&2
    failures=1
  fi
}

# Collaboration and workflow files that must never ship in the public core.
check_path_absent ".gitlab"
check_path_absent ".gitlab-ci.yml"
check_path_absent "AGENTS.md"
check_path_absent "CODEOWNERS"
check_path_absent "docs/02-corp-network-integration.md"

# Forbidden text patterns come from a denylist file, never hard-coded here, so
# the public script names no internal infrastructure. The public file ships
# only generic placeholders; the internal overlay extends it with
# organization-specific hostnames, email domains, and identity strings.
if [[ -f "$denylist_file" ]]; then
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    check_pattern_absent "$pattern"
  done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$denylist_file")
fi

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

printf 'Public boundary lint passed.\n'
