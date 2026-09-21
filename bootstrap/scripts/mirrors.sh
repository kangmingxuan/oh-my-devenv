#!/usr/bin/env bash
#
# Mirror-mode helpers sourced by common.sh.
#
# Modes:
#   - `external` (the default) leaves the caller environment untouched.
#     Downstream tools use their own defaults or whatever the caller exported.
#   - `internal` exports each key declared in
#     bootstrap/manifests/system/mirrors.env. A caller-provided DOTFILES_<KEY>
#     override always wins; a <placeholder-...> manifest value is inert and
#     only warns, so this public manifest never carries a private hostname.
#   - `auto` probes DOTFILES_INTERNAL_PROBE_URL and selects `internal` when the
#     probe succeeds. An empty or unset probe URL selects `external` without a
#     network call.
#
# All functions are idempotent and safe to source twice.

if [[ -z "${_DOTFILES_MIRRORS_SH_DIR:-}" ]]; then
  _DOTFILES_MIRRORS_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

_dotfiles_mirrors_manifest() {
  printf '%s/../manifests/system/mirrors.env\n' "$_DOTFILES_MIRRORS_SH_DIR"
}

# Echo the requested mode, without resolving `auto`.
dotfiles_mirror_mode() {
  printf '%s\n' "${DOTFILES_MIRROR_MODE:-external}"
}

# Echo the concrete mode (`external` or `internal`).
dotfiles_resolve_mirror_mode() {
  local mode=""
  local probe_url="${DOTFILES_INTERNAL_PROBE_URL:-}"

  mode="$(dotfiles_mirror_mode)"

  case "$mode" in
    external | internal)
      printf '%s\n' "$mode"
      return 0
      ;;
    auto)
      if [[ -z "$probe_url" ]]; then
        printf 'external\n'
        return 0
      fi
      if command -v curl >/dev/null 2>&1 \
        && curl --max-time 3 -fsS -o /dev/null "$probe_url" 2>/dev/null; then
        printf 'internal\n'
      else
        printf 'external\n'
      fi
      return 0
      ;;
    *)
      printf 'WARNING: unknown DOTFILES_MIRROR_MODE=%s, falling back to external\n' "$mode" >&2
      printf 'external\n'
      return 0
      ;;
  esac
}

# Print one `<ENV_VAR_NAME> <value>` line per manifest entry. Fails on a
# missing manifest or a malformed row so consumers never silently skip a key.
dotfiles_mirrors_entries() {
  local manifest="${1:-$(_dotfiles_mirrors_manifest)}"
  local entries=""
  local entry=""
  local key=""
  local value=""
  local extra=""
  local key_pattern='^[A-Z][A-Z0-9_]*$'

  entries="$(manifest_entries "$manifest")" || return 1

  while IFS= read -r entry; do
    if [[ -z "$entry" ]]; then
      continue
    fi
    read -r key value extra <<<"$entry"
    if [[ ! "$key" =~ $key_pattern || -z "$value" || -n "$extra" ]]; then
      printf 'ERROR: invalid mirror manifest entry in %s: %s\n' "$manifest" "$entry" >&2
      return 1
    fi
    printf '%s %s\n' "$key" "$value"
  done <<<"$entries"
}

# Export the internal mirror environment for the resolved mode.
#
# - external: no-op; the caller environment is preserved as is.
# - internal: export every manifest key. A caller-provided DOTFILES_<KEY>
#   override wins, a <placeholder-...> value only warns, and any other value
#   is exported verbatim.
#
# An optional manifest path argument replaces the repository manifest.
dotfiles_apply_mirror_env() {
  local manifest="${1:-$(_dotfiles_mirrors_manifest)}"
  local resolved=""
  local entries=""
  local key=""
  local value=""
  local override_name=""
  local override_value=""

  resolved="$(dotfiles_resolve_mirror_mode)"

  if [[ "$resolved" != "internal" ]]; then
    return 0
  fi

  entries="$(dotfiles_mirrors_entries "$manifest")" || return 1

  while read -r key value; do
    if [[ -z "$key" ]]; then
      continue
    fi

    # Keys that already carry the DOTFILES_ prefix are overridden directly.
    if [[ "$key" == DOTFILES_* ]]; then
      override_name="$key"
    else
      override_name="DOTFILES_${key}"
    fi
    override_value="${!override_name:-}"

    if [[ -n "$override_value" ]]; then
      export "$key=$override_value"
      continue
    fi

    if [[ "$value" == '<placeholder'*'>' ]]; then
      printf 'WARNING: internal mirror value for %s is still <placeholder>; set %s to activate\n' \
        "$key" "$override_name" >&2
      continue
    fi

    export "$key=$value"
  done <<<"$entries"
}
