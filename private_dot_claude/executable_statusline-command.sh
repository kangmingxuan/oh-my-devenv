#!/usr/bin/env bash

# Claude Code status line: cwd, git branch/state, model, and context remaining.
set -uo pipefail

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)"
model="$(printf '%s' "$input" | jq -r '.model.display_name // .model.id // "unknown"' 2>/dev/null)"
remaining="$(
  printf '%s' "$input" | jq -r '
    if .context_window.remaining_percentage != null then
      (.context_window.remaining_percentage | floor | tostring)
    elif .context_window.used_percentage != null then
      ((100 - .context_window.used_percentage) | floor | tostring)
    else
      ""
    end
  ' 2>/dev/null
)"

[[ -n "$cwd" ]] || cwd="$PWD"
display_cwd="$cwd"
if [[ "$cwd" == "$HOME" ]]; then
  display_cwd="~"
elif [[ "$cwd" == "$HOME/"* ]]; then
  printf -v display_cwd '\x7e/%s' "${cwd#"$HOME/"}"
fi

branch=""
dirty=""
if [[ -d "$cwd" ]] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$cwd" branch --show-current 2>/dev/null)"
  if [[ -z "$branch" ]]; then
    branch="@$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)"
  fi
  if [[ -n "$(git -C "$cwd" status --porcelain --ignore-submodules=dirty 2>/dev/null)" ]]; then
    dirty="*"
  fi
fi

printf '\033[1;34m➜\033[0m \033[1;36m%s\033[0m' "$display_cwd"
if [[ -n "$branch" ]]; then
  printf ' \033[1;35mgit:(\033[31m%s%s\033[35m)\033[0m' "$branch" "$dirty"
fi
printf ' \033[2m%s\033[0m' "$model"
if [[ -n "$remaining" ]]; then
  printf ' \033[2mctx:%s%%\033[0m' "$remaining"
fi
printf '\n'
