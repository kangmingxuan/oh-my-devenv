#!/usr/bin/env bash

# Claude Code hook: send a native desktop notification where possible.
# Hook JSON arrives on stdin; the first argument is the fallback message.
set -uo pipefail

input="$(cat)"
message="$(printf '%s' "$input" | jq -r '.message // empty' 2>/dev/null)"
[[ -n "$message" ]] || message="${1:-任务结束}"
message="${message//$'\r'/ }"
message="${message//$'\n'/ }"
message="${message:0:240}"

if [[ "$(uname -s)" == "Darwin" ]] && command -v osascript >/dev/null 2>&1; then
  osascript \
    -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "Claude Code" sound name "Glass"' \
    -e 'end run' \
    -- "$message" >/dev/null 2>&1 || true
elif command -v powershell.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  windows_script="$(wslpath -w "$script_dir/notify.ps1")"
  nohup powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$windows_script" -Message "$message" \
    </dev/null >/dev/null 2>&1 &
elif command -v notify-send >/dev/null 2>&1; then
  notify-send --app-name="Claude Code" "Claude Code" "$message" >/dev/null 2>&1 || true
fi

exit 0
