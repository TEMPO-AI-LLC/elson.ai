#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
MODERN_DMG="$SCRIPT_DIR/elson-modern-latest.dmg"
COMPAT_DMG="$SCRIPT_DIR/elson-compat15-latest.dmg"

log() {
  echo "$*"
}

fail() {
  echo "❌ $*" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || fail "Missing required file: $1"
}

detect_host_macos_major_version() {
  if [ -n "${ELSON_INSTALLER_OS_VERSION_OVERRIDE:-}" ]; then
    printf '%s\n' "$ELSON_INSTALLER_OS_VERSION_OVERRIDE"
    return
  fi

  /usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{ print $1 }'
}

variant_minimum_major_version() {
  case "$1" in
    modern) printf '%s\n' '26' ;;
    compat15) printf '%s\n' '15' ;;
    *) fail "Unknown variant: $1" ;;
  esac
}

variant_artifact_path() {
  case "$1" in
    modern) printf '%s\n' "$MODERN_DMG" ;;
    compat15) printf '%s\n' "$COMPAT_DMG" ;;
    *) fail "Unknown variant: $1" ;;
  esac
}

variant_supported_on_host() {
  local variant="$1"
  local host_major="$2"
  local min_major=""

  min_major="$(variant_minimum_major_version "$variant")"
  [ "$host_major" -ge "$min_major" ]
}

resolve_variant_order() {
  local host_major="$1"

  if [ "$host_major" -ge 26 ]; then
    printf '%s\n%s\n' 'modern' 'compat15'
  elif [ "$host_major" -ge 15 ]; then
    printf '%s\n%s\n' 'compat15' 'modern'
  else
    fail "macOS ${host_major} is not supported. Elson requires macOS 15 or newer."
  fi
}

choose_local_artifact() {
  local host_major="$1"
  local variant=""
  local artifact_path=""

  while IFS= read -r variant; do
    [ -n "$variant" ] || continue
    artifact_path="$(variant_artifact_path "$variant")"

    if [ ! -f "$artifact_path" ]; then
      continue
    fi

    if variant_supported_on_host "$variant" "$host_major"; then
      printf '%s\n' "$artifact_path"
      return 0
    fi
  done < <(resolve_variant_order "$host_major")

  return 1
}

require_file "$UPDATE_SCRIPT"

HOST_MACOS_MAJOR="$(detect_host_macos_major_version)"
SELECTED_ARTIFACT="$(choose_local_artifact "$HOST_MACOS_MAJOR" || true)"

if [ -z "$SELECTED_ARTIFACT" ]; then
  fail "No compatible Elson DMG is available for macOS ${HOST_MACOS_MAJOR} in this ZIP."
fi

log "📦 Selected $(basename "$SELECTED_ARTIFACT") for macOS ${HOST_MACOS_MAJOR}."
exec /bin/bash "$UPDATE_SCRIPT" --artifact "$SELECTED_ARTIFACT" "$@"
