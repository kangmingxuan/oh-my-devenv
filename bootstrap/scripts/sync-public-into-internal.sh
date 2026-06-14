#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash bootstrap/scripts/sync-public-into-internal.sh [sync-branch-name]

Run this from the internal repository worktree.

Environment overrides:
  PUBLIC_REMOTE   default: public
  INTERNAL_REMOTE default: origin
  PUBLIC_REF      default: main
  INTERNAL_REF    default: main
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$#" -gt 1 ]]; then
  usage >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  printf 'ERROR: git is required\n' >&2
  exit 1
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf 'ERROR: run this script inside a git repository\n' >&2
  exit 1
fi

if [[ -n "$(git status --short)" ]]; then
  printf 'ERROR: worktree must be clean before syncing public into internal\n' >&2
  exit 1
fi

public_remote="${PUBLIC_REMOTE:-public}"
internal_remote="${INTERNAL_REMOTE:-origin}"
public_ref="${PUBLIC_REF:-main}"
internal_ref="${INTERNAL_REF:-main}"
sync_branch="${1:-sync/public-$(date +%Y%m%d)}"

if git show-ref --verify --quiet "refs/heads/$sync_branch"; then
  printf 'ERROR: local branch already exists: %s\n' "$sync_branch" >&2
  exit 1
fi

printf 'Fetching %s and %s...\n' "$public_remote" "$internal_remote"
git fetch --multiple "$public_remote" "$internal_remote" --prune

printf 'Creating sync branch %s from %s/%s...\n' "$sync_branch" "$internal_remote" "$internal_ref"
git switch -c "$sync_branch" "$internal_remote/$internal_ref"

printf 'Merging %s/%s...\n' "$public_remote" "$public_ref"
git merge --no-ff "$public_remote/$public_ref"

cat <<EOF
Sync branch ready: $sync_branch

Next steps:
  1. Resolve conflicts using docs/04-maintenance.md if the merge stopped.
  2. Run:
       bash bootstrap/scripts/run-smoke-tests.sh
  3. Open a review branch / MR back into $internal_ref on the internal repo.
EOF
