#!/usr/bin/env bash
#
# Mirror-mode helpers sourced by common.sh.
#
# Design:
#   - `external` (the implicit default) never touches the environment.
#     This keeps today's install behavior byte-for-byte.
#   - `internal` pulls per-key values from bootstrap/manifests/system/mirrors.env
#     and exports them, unless the user already set a matching
#     DOTFILES_<KEY> override (user env wins).
#   - `auto` probes DOTFILES_INTERNAL_PROBE_URL; if that env var is empty
#     or unset, `auto` collapses to `external` WITHOUT any network call.
#     No corporate hostname is ever baked in.
#
# All functions are idempotent and safe to source twice.

# Path to this file's directory, resolved once when sourced.
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

# Echo the concrete mode (`external` or `internal`). Resolves `auto` by
# probing DOTFILES_INTERNAL_PROBE_URL when that variable is non-empty.
# When the probe URL is empty/unset, `auto` collapses to `external` and
# no curl is invoked.
dotfiles_resolve_mirror_mode() {
  local mode=""
  local probe_url="${DOTFILES_INTERNAL_PROBE_URL:-}"

  mode="$(dotfiles_mirror_mode)"

  case "$mode" in
    external|internal)
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

# Echo the mirrors.env value for the given mode+key, or empty if no row
# matches. Never fails (missing manifest returns empty so callers can
# degrade gracefully).
_dotfiles_mirrors_lookup() {
  local mode="$1"
  local key="$2"
  local manifest=""
  local entry_mode=""
  local entry_key=""
  local entry_value=""

  manifest="$(_dotfiles_mirrors_manifest)"

  if [[ ! -f "$manifest" ]]; then
    return 0
  fi

  while read -r entry_mode entry_key entry_value; do
    if [[ "$entry_mode" == "$mode" ]] && [[ "$entry_key" == "$key" ]]; then
      printf '%s\n' "$entry_value"
      return 0
    fi
  done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$manifest" | awk 'NF>=3 { mode=$1; key=$2; $1=""; $2=""; sub(/^ +/,""); print mode, key, $0 }')
}

# Apply mirror-env exports for the resolved mode.
#
# - external: no-op. The environment is not touched, so a baseline run
#   behaves exactly as before mirrors.sh existed.
# - internal: for each key declared in mirrors.env, export the manifest
#   value UNLESS the caller already exported a matching DOTFILES_<KEY>
#   override (user-provided values always win).
#
# Returns 0 in all normal paths. Unknown modes trigger a warning in
# dotfiles_resolve_mirror_mode and fall back to external behavior here.
dotfiles_apply_mirror_env() {
  local resolved=""
  local manifest=""
  local mode=""
  local key=""
  local value=""
  local override_name=""
  local override_value=""

  resolved="$(dotfiles_resolve_mirror_mode)"

  if [[ "$resolved" != "internal" ]]; then
    return 0
  fi

  manifest="$(_dotfiles_mirrors_manifest)"

  if [[ ! -f "$manifest" ]]; then
    return 0
  fi

  while read -r mode key value; do
    if [[ "$mode" != "internal" ]]; then
      continue
    fi
    if [[ -z "$key" ]]; then
      continue
    fi

    # Allow per-key opt-out via DOTFILES_<KEY>. User env beats manifest.
    # The DOTFILES_ prefix is honored even when the key already starts
    # with DOTFILES_ (e.g. DOTFILES_DOTFILES_OH_MY_ZSH_GIT_URL would be
    # absurd, so in that case we just consult the key itself).
    if [[ "$key" == DOTFILES_* ]]; then
      override_name="$key"
    else
      override_name="DOTFILES_${key}"
    fi
    override_value="${!override_name:-}"

    if [[ -n "$override_value" ]]; then
      # User told us the value; export it verbatim under the real key.
      export "$key=$override_value"
      continue
    fi

    # No user override: fall back to whatever the manifest says.
    # Refuse to export placeholder-shaped values; they exist to remind
    # users that they still need to provide a real mirror, not to be
    # silently propagated to downstream tooling.
    if [[ "$value" == '<placeholder'*'>' ]]; then
      printf 'WARNING: internal mirror value for %s is still <placeholder>; set %s to activate\n' \
        "$key" "$override_name" >&2
      continue
    fi

    export "$key=$value"
  done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$manifest" | awk 'NF>=3 { mode=$1; key=$2; $1=""; $2=""; sub(/^ +/,""); print mode, key, $0 }')
}
