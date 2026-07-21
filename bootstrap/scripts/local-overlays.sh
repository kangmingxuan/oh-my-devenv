#!/usr/bin/env bash

declare -a OH_MY_DEVENV_LOCAL_OVERLAY_ROWS=()
OH_MY_DEVENV_LOCAL_OVERLAY_MANIFEST=""

local_overlay_manifest_path() {
  local script_dir=""

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s/../manifests/local-overlays.tsv\n' "$script_dir"
}

local_overlay_load() {
  local manifest="${1:-$(local_overlay_manifest_path)}"
  local inventory=""
  local row=""
  local -a rows=()

  if [[ "$OH_MY_DEVENV_LOCAL_OVERLAY_MANIFEST" == "$manifest" ]]; then
    return 0
  fi

  if [[ ! -f "$manifest" ]]; then
    printf 'ERROR: local overlay inventory not found: %s\n' "$manifest" >&2
    return 1
  fi

  inventory="$(awk -F '\t' '
    /^#/ || /^[[:space:]]*$/ { next }
    {
      rows++
      id = $1
      example = $2
      location = $3
      match_type = $4
      consumers = $5
      lifecycle = $6
    }
    NF != 6 {
      printf "ERROR: invalid local overlay inventory row %d: expected 6 fields, got %d\n", NR, NF > "/dev/stderr"
      invalid = 1
      next
    }
    id !~ /^[a-z][a-z0-9_]*$/ {
      printf "ERROR: invalid local overlay id on row %d: %s\n", NR, id > "/dev/stderr"
      invalid = 1
    }
    example !~ /\.example$/ {
      printf "ERROR: invalid local overlay example on row %d: %s\n", NR, example > "/dev/stderr"
      invalid = 1
    }
    location !~ /^\$(HOME|XDG_CONFIG_HOME)\// {
      printf "ERROR: invalid local overlay location on row %d: %s\n", NR, location > "/dev/stderr"
      invalid = 1
    }
    match_type != "exact" && match_type != "glob" {
      printf "ERROR: invalid local overlay match type on row %d: %s\n", NR, match_type > "/dev/stderr"
      invalid = 1
    }
    {
      has_glob = index(location, "*") || index(location, "?") || index(location, "[")
      if (match_type == "exact" && has_glob) {
        printf "ERROR: exact local overlay contains a glob on row %d: %s\n", NR, location > "/dev/stderr"
        invalid = 1
      }
      if (match_type == "glob" && !has_glob) {
        printf "ERROR: glob local overlay has no pattern on row %d: %s\n", NR, location > "/dev/stderr"
        invalid = 1
      }
    }
    consumers == "" || lifecycle == "" {
      printf "ERROR: missing local overlay metadata on row %d\n", NR > "/dev/stderr"
      invalid = 1
    }
    {
      if (seen_id[id]++) {
        printf "ERROR: duplicate local overlay id on row %d: %s\n", NR, id > "/dev/stderr"
        invalid = 1
      }
      if (seen_example[example]++) {
        printf "ERROR: duplicate local overlay example on row %d: %s\n", NR, example > "/dev/stderr"
        invalid = 1
      }
      if (seen_location[location]++) {
        printf "ERROR: duplicate local overlay location on row %d: %s\n", NR, location > "/dev/stderr"
        invalid = 1
      }
    }
    { print }
    END {
      if (rows == 0) {
        printf "ERROR: local overlay inventory is empty\n" > "/dev/stderr"
        invalid = 1
      }
      exit invalid ? 1 : 0
    }
  ' "$manifest")" || return 1

  while IFS= read -r row; do
    rows[${#rows[@]}]="$row"
  done <<<"$inventory"

  OH_MY_DEVENV_LOCAL_OVERLAY_ROWS=("${rows[@]}")
  OH_MY_DEVENV_LOCAL_OVERLAY_MANIFEST="$manifest"
}

local_overlay_inventory() {
  local manifest="${1:-$(local_overlay_manifest_path)}"

  local_overlay_load "$manifest" || return 1
  printf '%s\n' "${OH_MY_DEVENV_LOCAL_OVERLAY_ROWS[@]}"
}

local_overlay_resolve_location() {
  local location="$1"
  local base=""
  local prefix=""

  case "$location" in
    "\$HOME/"*)
      prefix="\$HOME/"
      base="${HOME%/}"
      ;;
    "\$XDG_CONFIG_HOME/"*)
      prefix="\$XDG_CONFIG_HOME/"
      base="${XDG_CONFIG_HOME%/}"
      ;;
    *)
      printf 'ERROR: unsupported local overlay location: %s\n' "$location" >&2
      return 1
      ;;
  esac

  if [[ -n "$base" ]]; then
    printf '%s/%s\n' "$base" "${location#"$prefix"}"
  else
    printf '/%s\n' "${location#"$prefix"}"
  fi
}

local_overlay_glob_pattern() {
  local location="$1"
  local base=""
  local prefix=""
  local relative=""

  case "$location" in
    "\$HOME/"*)
      prefix="\$HOME/"
      base="${HOME%/}"
      ;;
    "\$XDG_CONFIG_HOME/"*)
      prefix="\$XDG_CONFIG_HOME/"
      base="${XDG_CONFIG_HOME%/}"
      ;;
    *)
      printf 'ERROR: unsupported local overlay location: %s\n' "$location" >&2
      return 1
      ;;
  esac

  relative="${location#"$prefix"}"
  base="${base//\\/\\\\}"
  base="${base//\*/\\*}"
  base="${base//\?/\\?}"
  base="${base//\[/\\[}"
  base="${base//\]/\\]}"

  if [[ -n "$base" ]]; then
    printf '%s/%s\n' "$base" "$relative"
  else
    printf '/%s\n' "$relative"
  fi
}

local_overlay_location() {
  local wanted_id="$1"
  local row=""
  local -a fields=()

  local_overlay_load || return 1
  for row in "${OH_MY_DEVENV_LOCAL_OVERLAY_ROWS[@]}"; do
    IFS=$'\t' read -r -a fields <<<"$row"
    if [[ "${fields[0]}" == "$wanted_id" ]]; then
      printf '%s\n' "${fields[2]}"
      return 0
    fi
  done

  printf 'ERROR: local overlay id not found: %s\n' "$wanted_id" >&2
  return 1
}

local_overlay_matches_path() {
  local target="$1"
  local row location match resolved
  local -a fields=()

  local_overlay_load || return 1
  for row in "${OH_MY_DEVENV_LOCAL_OVERLAY_ROWS[@]}"; do
    IFS=$'\t' read -r -a fields <<<"$row"
    location="${fields[2]}"
    match="${fields[3]}"
    case "$match" in
      exact)
        resolved="$(local_overlay_resolve_location "$location")" || return 1
        [[ "$target" == "$resolved" ]] && return 0
        ;;
      glob)
        resolved="$(local_overlay_glob_pattern "$location")" || return 1
        # shellcheck disable=SC2053
        [[ "$target" == $resolved ]] && return 0
        ;;
    esac
  done

  return 1
}

local_overlay_existing_paths() {
  local row location match resolved path
  local -a fields=()

  local_overlay_load || return 1
  for row in "${OH_MY_DEVENV_LOCAL_OVERLAY_ROWS[@]}"; do
    IFS=$'\t' read -r -a fields <<<"$row"
    location="${fields[2]}"
    match="${fields[3]}"
    case "$match" in
      exact)
        resolved="$(local_overlay_resolve_location "$location")" || return 1
        [[ -e "$resolved" || -L "$resolved" ]] && printf '%s\n' "$resolved"
        ;;
      glob)
        resolved="$(local_overlay_glob_pattern "$location")" || return 1
        while IFS= read -r path; do
          [[ -e "$path" || -L "$path" ]] && printf '%s\n' "$path"
        done < <(compgen -G "$resolved" || true)
        ;;
    esac
  done

  return 0
}
