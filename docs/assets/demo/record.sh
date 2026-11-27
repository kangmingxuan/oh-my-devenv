#!/usr/bin/env bash
#
# Re-record docs/assets/demo.gif. Requires Docker. The script builds a
# disposable container from the tracked source, applies the baseline inside it,
# and runs demo.tape with VHS. It never touches the host home directory.
set -euo pipefail

demo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$demo_dir/../../.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$work_dir/src"
git -C "$repo_root" ls-files -z | (cd "$repo_root" && xargs -0 tar -cf -) | tar -xf - -C "$work_dir/src"
cp "$demo_dir/Dockerfile" "$work_dir/Dockerfile"

docker build -t oh-my-devenv-demo "$work_dir"
docker run --rm \
  -v "$demo_dir/demo.tape:/demo.tape:ro" \
  -v "$repo_root/docs/assets:/out" \
  oh-my-devenv-demo /demo.tape
