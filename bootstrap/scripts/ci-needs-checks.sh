#!/usr/bin/env bash
#
# Read changed paths from stdin, one per line. Print "false" only when at least
# one path changed and no check consumes any of them. Print "true" otherwise, so
# an unknown path or an empty list runs every check.
set -euo pipefail

saw_path=false
while IFS= read -r path; do
  saw_path=true
  case "$path" in
    # The smoke suite consumes these examples as fixtures.
    docs/local-overlay-examples/*) echo true; exit 0 ;;
    # Only Markdown: the Bash compatibility check scans every other file type.
    docs/*.md | README.md | README.zh.md | CHANGELOG.md | CONTRIBUTING.md | AGENTS.md | LICENSE) ;;
    *) echo true; exit 0 ;;
  esac
done

if [[ "$saw_path" == true ]]; then
  echo false
else
  echo true
fi
