#!/bin/bash

set -euo pipefail

DEFAULT_GITHUB_REPO="TEMPO-AI-LLC/elson.ai"
DEFAULT_GITHUB_REF="main"

GITHUB_REPO="${ELSON_GITHUB_REPO:-$DEFAULT_GITHUB_REPO}"
GITHUB_REF="${ELSON_GITHUB_REF:-$DEFAULT_GITHUB_REF}"
RAW_BASE_URL="${ELSON_GITHUB_RAW_BASE_URL:-https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_REF}}"
RELEASE_BASE_URL="${ELSON_GITHUB_RELEASE_BASE_URL:-https://github.com/${GITHUB_REPO}/releases/latest/download}"

PRESERVE_STATE=0
PRINT_COMMAND=0
PASS_THROUGH_ARGS=()
TMP_DIR=""

usage() {
  cat <<EOF
Usage:
  curl -fsSL ${RAW_BASE_URL}/github-install.sh | bash
  curl -fsSL ${RAW_BASE_URL}/github-install.sh | bash -s -- --preserve-state

Options:
  --preserve-state  Install the latest app while keeping local config, API keys, history, and app state.
  --print-command   Resolve the installer URL + asset URL and print the final install command without running it.
  --help            Show this help.

Environment overrides:
  ELSON_INSTALLER_OS_VERSION_OVERRIDE  Override detected macOS major version for testing.
  ELSON_GITHUB_REPO                    Override owner/repo. Default: ${DEFAULT_GITHUB_REPO}
  ELSON_GITHUB_REF                     Override raw GitHub ref. Default: ${DEFAULT_GITHUB_REF}
  ELSON_GITHUB_RAW_BASE_URL            Override raw GitHub base URL.
  ELSON_GITHUB_RELEASE_BASE_URL        Override GitHub Releases base URL.
EOF
}

info() {
  echo "• $*" >&2
}

fail() {
  echo "❌ $*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing required command: $1"
  fi
}

probe_url() {
  local url="$1"
  /usr/bin/curl --fail --silent --show-error --location --range 0-0 --output /dev/null "$url" >/dev/null 2>&1
}

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

detect_host_macos_major_version() {
  if [ -n "${ELSON_INSTALLER_OS_VERSION_OVERRIDE:-}" ]; then
    printf '%s\n' "$ELSON_INSTALLER_OS_VERSION_OVERRIDE"
    return
  fi

  /usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{ print $1 }'
}

resolve_asset_name() {
  local host_major="$1"

  if [ "$host_major" -ge 26 ]; then
    printf '%s\n' 'elson-modern-latest.dmg'
  elif [ "$host_major" -ge 15 ]; then
    printf '%s\n' 'elson-compat15-latest.dmg'
  else
    fail "macOS ${host_major} is not supported. Elson requires macOS 15 or newer."
  fi
}

quote_args() {
  printf '%q ' "$@"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --preserve-state)
      PRESERVE_STATE=1
      shift
      ;;
    --print-command)
      PRINT_COMMAND=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      PASS_THROUGH_ARGS+=("$1")
      shift
      ;;
  esac
done

trap cleanup EXIT

[ "$(/usr/bin/uname -s)" = "Darwin" ] || fail "This installer currently supports macOS only."

require_cmd /usr/bin/curl
require_cmd /usr/bin/sw_vers
require_cmd /usr/bin/awk

HOST_MACOS_MAJOR="$(detect_host_macos_major_version)"
ASSET_NAME="$(resolve_asset_name "$HOST_MACOS_MAJOR")"
INSTALL_SCRIPT_URL="${RAW_BASE_URL}/install.sh"
RELEASE_APP_URL="${RELEASE_BASE_URL}/${ASSET_NAME}"
RAW_APP_URL="${RAW_BASE_URL}/${ASSET_NAME}"

if probe_url "$RELEASE_APP_URL"; then
  APP_URL="$RELEASE_APP_URL"
  info "Using GitHub release asset."
elif probe_url "$RAW_APP_URL"; then
  APP_URL="$RAW_APP_URL"
  info "Release asset not found. Falling back to repo-tracked raw asset."
else
  fail "Could not resolve ${ASSET_NAME} from GitHub Releases or repo raw files."
fi

TMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/elson-github-install.XXXXXX")"
INSTALL_SCRIPT_PATH="${TMP_DIR}/install.sh"

info "Resolved macOS ${HOST_MACOS_MAJOR} -> ${ASSET_NAME}"
info "Using install script: ${INSTALL_SCRIPT_URL}"
info "Using release asset: ${APP_URL}"

/usr/bin/curl --fail --silent --show-error --location --retry 3 --output "$INSTALL_SCRIPT_PATH" "$INSTALL_SCRIPT_URL"
/bin/chmod +x "$INSTALL_SCRIPT_PATH"

INSTALL_CMD=(/bin/bash "$INSTALL_SCRIPT_PATH" --app-url "$APP_URL")
if [ "$PRESERVE_STATE" -eq 1 ]; then
  INSTALL_CMD+=(--preserve-state)
fi
if [ "${#PASS_THROUGH_ARGS[@]}" -gt 0 ]; then
  INSTALL_CMD+=("${PASS_THROUGH_ARGS[@]}")
fi

if [ "$PRINT_COMMAND" -eq 1 ]; then
  quote_args "${INSTALL_CMD[@]}"
  printf '\n'
  exit 0
fi

exec "${INSTALL_CMD[@]}"
