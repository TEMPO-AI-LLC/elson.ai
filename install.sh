#!/bin/bash

set -euo pipefail

APP_NAME="Elson"
PREVIOUS_APP_NAME="Gairvis"
PREVIOUS_BUNDLE_ID="${PREVIOUS_BUNDLE_ID:-com.gairvis.app}"
BOOTSTRAP_METADATA_DIR="$HOME/Library/Application Support/Elson"
BOOTSTRAP_METADATA_PATH="$BOOTSTRAP_METADATA_DIR/bootstrap.env"
APP_SUPPORT_ROOT="$HOME/Library/Application Support"
ELSON_APP_SUPPORT_DIR="$APP_SUPPORT_ROOT/Elson"
PREVIOUS_APP_SUPPORT_DIR="$APP_SUPPORT_ROOT/Gairvis"
PREFERENCES_ROOT="$HOME/Library/Preferences"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

ORIGIN="${ELSON_ORIGIN:-}"
APP_URL="${ELSON_APP_URL:-}"
LOCAL_ARTIFACT=""
BOOTSTRAP_TOKEN="${ELSON_BOOTSTRAP_TOKEN:-}"
DEVICE_FINGERPRINT="${ELSON_DEVICE_FINGERPRINT:-}"
OPEN_APP=1
PRESERVE_STATE=0

TMP_DIR=""
MOUNT_POINT=""
INSTALL_ROOT="/Applications"
INSTALL_APP=""
SETTINGS_WAS_OPEN=0

usage() {
  cat <<'EOF'
Usage:
  curl -fsSL https://example.com/install.sh | bash -s -- --origin https://example.com

Options:
  --origin URL                Base origin for Elson artifacts. Custom origins default to /elson-latest.dmg.
  --app-url URL               Exact Elson artifact URL (.dmg or .zip). Overrides --origin.
  --artifact PATH             Install from a local .dmg or .zip file instead of downloading.
  --token VALUE               Optional opaque bootstrap token stored for later use.
  --device-fingerprint VALUE  Optional opaque device fingerprint stored for later use.
  --preserve-state            Update Elson without clearing local config, API keys, history, or local app state.
  --no-open                   Do not launch Elson after installation.
  --help                      Show this help.
EOF
}

info() {
  echo "• $*" >&2
}

warn() {
  echo "⚠️  $*" >&2
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

cleanup() {
  if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

normalize_origin() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "${value%/}"
}

bootstrap_origin_install_hint() {
  local origin="$1"
  if [ -z "$origin" ]; then
    return 1
  fi
  printf "curl -fsSL %s/install.sh | bash -s -- --origin '%s'\n" "$origin" "$origin"
}

resolve_install_root() {
  if [ -w "/Applications" ]; then
    printf '%s\n' "/Applications"
  else
    mkdir -p "$HOME/Applications"
    printf '%s\n' "$HOME/Applications"
  fi
}

stop_app_processes() {
  local name="$1"
  /usr/bin/killall "$name" 2>/dev/null || true
  /usr/bin/pkill -f "/Applications/${name}\\.app/Contents/MacOS/${name}" 2>/dev/null || true
  /usr/bin/pkill -f "$HOME/Applications/${name}\\.app/Contents/MacOS/${name}" 2>/dev/null || true
  /usr/bin/pkill -f "${name}\\.app" 2>/dev/null || true
}

remove_installed_app_copies() {
  local name="$1"
  rm -rf "/Applications/${name}.app" "$HOME/Applications/${name}.app"
}

register_bundle_if_present() {
  local app_path="$1"
  [ -d "$app_path" ] || return 0
  [ -x "$LSREGISTER" ] || return 0
  "$LSREGISTER" -f "$app_path" >/dev/null 2>&1 || true
}

unregister_bundle_if_present() {
  local app_path="$1"
  [ -d "$app_path" ] || return 0
  [ -x "$LSREGISTER" ] || return 0
  "$LSREGISTER" -u "$app_path" >/dev/null 2>&1 || true
}

remove_stale_login_items() {
  local desired_app_path="$1"

  /usr/bin/osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "System Events"
  try
    delete every login item whose name is "${PREVIOUS_APP_NAME}"
  end try
  try
    delete every login item whose name is "${APP_NAME}" and path is not "${desired_app_path}"
  end try
end tell
APPLESCRIPT
}

bundle_identifier_for_app() {
  local app_path="$1"
  local plist_path="$app_path/Contents/Info.plist"
  [ -f "$plist_path" ] || return 1

  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist_path" 2>/dev/null || return 1
}

reset_tcc_for_client() {
  local client="$1"
  [ -n "$client" ] || return 0

  info "Resetting macOS permissions for ${client}"
  for service in \
    All \
    ScreenCapture \
    Microphone \
    Accessibility \
    SystemPolicyDocumentsFolder \
    SystemPolicyDesktopFolder \
    SystemPolicyDownloadsFolder \
    SystemPolicyAllFiles
  do
    /usr/bin/tccutil reset "$service" "$client" >/dev/null 2>&1 || true
  done
}

reset_tcc_permissions_for_reinstall() {
  local primary_client="$1"

  reset_tcc_for_client "$primary_client"
  if [ -n "$PREVIOUS_BUNDLE_ID" ] && [ "$PREVIOUS_BUNDLE_ID" != "$primary_client" ]; then
    reset_tcc_for_client "$PREVIOUS_BUNDLE_ID"
  fi
}

clear_preferences_domain() {
  local domain="$1"
  [ -n "$domain" ] || return 0

  info "Clearing preferences for ${domain}"
  /usr/bin/defaults delete "$domain" >/dev/null 2>&1 || true
  rm -f "$PREFERENCES_ROOT/${domain}.plist"
}

clear_keychain_state_for_client() {
  local client="$1"
  [ -n "$client" ] || return 0

  info "Clearing keychain secrets for ${client}"
  /usr/bin/security delete-generic-password -s "$client" -a "groq_api_key" >/dev/null 2>&1 || true
  /usr/bin/security delete-generic-password -s "$client" -a "cerebras_api_key" >/dev/null 2>&1 || true
  /usr/bin/security delete-generic-password -s "$client" -a "zeroclaw_auth_token" >/dev/null 2>&1 || true
}

clear_application_support_state() {
  local path="$1"
  [ -n "$path" ] || return 0

  if [ -d "$path" ]; then
    info "Removing local app state at ${path}"
    rm -rf "$path"
  fi
}

clear_onboarding_state_for_reinstall() {
  local primary_client="$1"

  clear_preferences_domain "$primary_client"
  if [ -n "$PREVIOUS_BUNDLE_ID" ] && [ "$PREVIOUS_BUNDLE_ID" != "$primary_client" ]; then
    clear_preferences_domain "$PREVIOUS_BUNDLE_ID"
  fi
  clear_preferences_domain "$APP_NAME"
  clear_preferences_domain "$PREVIOUS_APP_NAME"
}

clear_keychain_state_for_reinstall() {
  local primary_client="$1"

  clear_keychain_state_for_client "$primary_client"
  if [ -n "$PREVIOUS_BUNDLE_ID" ] && [ "$PREVIOUS_BUNDLE_ID" != "$primary_client" ]; then
    clear_keychain_state_for_client "$PREVIOUS_BUNDLE_ID"
  fi
}

clear_application_support_state_for_reinstall() {
  clear_application_support_state "$ELSON_APP_SUPPORT_DIR"
  clear_application_support_state "$PREVIOUS_APP_SUPPORT_DIR"
}

restart_preferences_daemon() {
  /usr/bin/killall cfprefsd >/dev/null 2>&1 || true
  /bin/sleep 1
}

detect_zeroclaw_binary() {
  local candidate=""

  if [ -n "${ELSON_ZEROCLAW_BINARY_PATH:-}" ] && [ -x "${ELSON_ZEROCLAW_BINARY_PATH:-}" ]; then
    printf '%s\n' "${ELSON_ZEROCLAW_BINARY_PATH}"
    return 0
  fi

  candidate="$(command -v zeroclaw 2>/dev/null || true)"
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  for candidate in \
    "$HOME/.cargo/bin/zeroclaw" \
    "$HOME/.local/bin/zeroclaw" \
    "/opt/homebrew/bin/zeroclaw" \
    "/usr/local/bin/zeroclaw"
  do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

remove_legacy_zeroclaw_from_machine() {
  local zeroclaw_bin=""
  zeroclaw_bin="$(detect_zeroclaw_binary || true)"

  if [ -n "$zeroclaw_bin" ]; then
    info "Stopping legacy ZeroClaw service"
    "$zeroclaw_bin" service stop >/dev/null 2>&1 || true
    "$zeroclaw_bin" service uninstall >/dev/null 2>&1 || true
    "$zeroclaw_bin" service remove >/dev/null 2>&1 || true
  fi

  /bin/launchctl remove com.zeroclaw.daemon >/dev/null 2>&1 || true
  rm -f "$HOME/Library/LaunchAgents/com.zeroclaw.daemon.plist"
  rm -rf "$HOME/.zeroclaw"
  rm -f "$HOME/.cargo/bin/zeroclaw" "$HOME/.local/bin/zeroclaw"

  if [ -n "$zeroclaw_bin" ] && [ -w "$zeroclaw_bin" ]; then
    rm -f "$zeroclaw_bin"
  fi
}

persist_bootstrap_metadata() {
  mkdir -p "$BOOTSTRAP_METADATA_DIR"
  {
    printf "ELSON_BOOTSTRAP_ORIGIN=%q\n" "$ORIGIN"
    printf "ELSON_BOOTSTRAP_APP_URL=%q\n" "$APP_URL"
    printf "ELSON_BOOTSTRAP_TOKEN=%q\n" "$BOOTSTRAP_TOKEN"
    printf "ELSON_BOOTSTRAP_DEVICE_FINGERPRINT=%q\n" "$DEVICE_FINGERPRINT"
    printf "ELSON_BOOTSTRAP_INSTALLED_AT=%q\n" "$(/bin/date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } > "$BOOTSTRAP_METADATA_PATH"
  chmod 600 "$BOOTSTRAP_METADATA_PATH"
}

probe_url() {
  local url="$1"
  /usr/bin/curl --fail --silent --show-error --location --range 0-0 --output /dev/null "$url" >/dev/null 2>&1
}

resolve_app_url() {
  if [ -n "$LOCAL_ARTIFACT" ]; then
    fail "--artifact cannot be used with --origin or --app-url."
  fi

  if [ -n "$APP_URL" ]; then
    printf '%s\n' "$APP_URL"
    return 0
  fi

  [ -n "$ORIGIN" ] || fail "Provide --origin or --app-url."

  local origin
  origin="$(normalize_origin "$ORIGIN")"
  local candidates=()

  if [[ "$origin" =~ ^https://github\.com/[^/]+/[^/]+$ ]]; then
    candidates+=(
      "${origin}/releases/latest/download/elson-latest.dmg"
      "${origin}/releases/latest/download/Elson.dmg"
      "${origin}/releases/latest/download/elson-latest.zip"
    )
  else
    candidates+=(
      "${origin}/elson-latest.dmg"
      "${origin}/downloads/elson-latest.dmg"
      "${origin}/Elson.dmg"
      "${origin}/downloads/Elson.dmg"
      "${origin}/elson-latest.zip"
    )
  fi

  local candidate=""
  for candidate in "${candidates[@]}"; do
    if probe_url "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  fail "Could not resolve an Elson artifact from ${origin}. Pass --app-url explicitly."
}

download_file() {
  local url="$1"
  local destination="$2"
  /usr/bin/curl --fail --silent --show-error --location --retry 3 --output "$destination" "$url"
}

find_app_bundle() {
  local search_root="$1"
  local app_path=""
  app_path="$(/usr/bin/find "$search_root" -maxdepth 3 -type d -name "${APP_NAME}.app" -print -quit 2>/dev/null || true)"
  [ -n "$app_path" ] || fail "Could not find ${APP_NAME}.app inside downloaded artifact."
  printf '%s\n' "$app_path"
}

install_app_bundle() {
  local source_app="$1"
  info "Installing ${APP_NAME}.app into ${INSTALL_ROOT}"
  stop_app_processes "$APP_NAME"
  unregister_bundle_if_present "/Applications/${APP_NAME}.app"
  unregister_bundle_if_present "$HOME/Applications/${APP_NAME}.app"
  unregister_bundle_if_present "/Applications/${PREVIOUS_APP_NAME}.app"
  unregister_bundle_if_present "$HOME/Applications/${PREVIOUS_APP_NAME}.app"
  remove_installed_app_copies "$APP_NAME"
  /usr/bin/ditto "$source_app" "$INSTALL_APP"
  /usr/bin/xattr -dr com.apple.quarantine "$INSTALL_APP" 2>/dev/null || true
  register_bundle_if_present "$INSTALL_APP"
  unregister_bundle_if_present "$source_app"
  remove_stale_login_items "$INSTALL_APP"
}

install_app_from_artifact() {
  local artifact="$1"
  local app_bundle=""

  case "$artifact" in
    *.dmg)
      MOUNT_POINT="$TMP_DIR/mount"
      mkdir -p "$MOUNT_POINT"
      /usr/bin/hdiutil attach "$artifact" -mountpoint "$MOUNT_POINT" -nobrowse -quiet >/dev/null
      app_bundle="$(find_app_bundle "$MOUNT_POINT")"
      install_app_bundle "$app_bundle"
      /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet >/dev/null || true
      MOUNT_POINT=""
      ;;
    *.zip)
      local unzip_dir="$TMP_DIR/unpacked"
      mkdir -p "$unzip_dir"
      /usr/bin/ditto -x -k "$artifact" "$unzip_dir"
      app_bundle="$(find_app_bundle "$unzip_dir")"
      install_app_bundle "$app_bundle"
      ;;
    *)
      fail "Unsupported artifact type: $artifact"
      ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --origin)
      [ "$#" -ge 2 ] || fail "Missing value for --origin"
      ORIGIN="$2"
      shift 2
      ;;
    --app-url)
      [ "$#" -ge 2 ] || fail "Missing value for --app-url"
      APP_URL="$2"
      shift 2
      ;;
    --artifact)
      [ "$#" -ge 2 ] || fail "Missing value for --artifact"
      LOCAL_ARTIFACT="$2"
      shift 2
      ;;
    --token)
      [ "$#" -ge 2 ] || fail "Missing value for --token"
      BOOTSTRAP_TOKEN="$2"
      shift 2
      ;;
    --device-fingerprint)
      [ "$#" -ge 2 ] || fail "Missing value for --device-fingerprint"
      DEVICE_FINGERPRINT="$2"
      shift 2
      ;;
    --preserve-state)
      PRESERVE_STATE=1
      shift
      ;;
    --no-open)
      OPEN_APP=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

trap cleanup EXIT

[ "$(/usr/bin/uname -s)" = "Darwin" ] || fail "This installer currently supports macOS only."

require_cmd /usr/bin/curl
require_cmd /usr/bin/hdiutil
require_cmd /usr/bin/ditto
require_cmd /usr/bin/find
require_cmd /usr/libexec/PlistBuddy
require_cmd /usr/bin/tar

ORIGIN="$(normalize_origin "$ORIGIN")"
INSTALL_ROOT="$(resolve_install_root)"
INSTALL_APP="${INSTALL_ROOT}/${APP_NAME}.app"

if [ -n "$LOCAL_ARTIFACT" ] && { [ -n "$ORIGIN" ] || [ -n "$APP_URL" ]; }; then
  fail "--artifact cannot be combined with --origin or --app-url."
fi

TMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/elson-install.XXXXXX")"

if /usr/bin/pgrep -x "System Settings" >/dev/null 2>&1; then
  SETTINGS_WAS_OPEN=1
fi

info "Stopping existing Elson or previous app processes"
stop_app_processes "$APP_NAME"
stop_app_processes "$PREVIOUS_APP_NAME"
/usr/bin/osascript -e 'tell application "System Settings" to quit' >/dev/null 2>&1 || true
unregister_bundle_if_present "/Applications/${PREVIOUS_APP_NAME}.app"
unregister_bundle_if_present "$HOME/Applications/${PREVIOUS_APP_NAME}.app"
remove_installed_app_copies "$PREVIOUS_APP_NAME"

if [ -n "$LOCAL_ARTIFACT" ]; then
  [ -f "$LOCAL_ARTIFACT" ] || fail "Local artifact not found: $LOCAL_ARTIFACT"
  info "Installing Elson from local artifact ${LOCAL_ARTIFACT}"
  install_app_from_artifact "$LOCAL_ARTIFACT"
else
  APP_URL="$(resolve_app_url)"
  ARTIFACT_PATH="$TMP_DIR/$(basename "${APP_URL%%\?*}")"

  info "Downloading Elson artifact from ${APP_URL}"
  download_file "$APP_URL" "$ARTIFACT_PATH"
  install_app_from_artifact "$ARTIFACT_PATH"
fi
PRIMARY_BUNDLE_ID="$(bundle_identifier_for_app "$INSTALL_APP" || true)"
if [ -z "$PRIMARY_BUNDLE_ID" ]; then
  warn "Could not resolve installed bundle identifier for ${INSTALL_APP}; skipping primary TCC reset."
else
  reset_tcc_permissions_for_reinstall "$PRIMARY_BUNDLE_ID"
if [ "$PRESERVE_STATE" -eq 1 ]; then
  info "Preserving local config, API keys, history, and app state while resetting permissions"
else
    clear_onboarding_state_for_reinstall "$PRIMARY_BUNDLE_ID"
    clear_keychain_state_for_reinstall "$PRIMARY_BUNDLE_ID"
    clear_application_support_state_for_reinstall
    restart_preferences_daemon
  fi
fi

if [ "$SETTINGS_WAS_OPEN" -eq 1 ]; then
  info "Refreshing System Settings privacy pane"
  /usr/bin/open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
  /bin/sleep 1
fi

persist_bootstrap_metadata

remove_legacy_zeroclaw_from_machine

if [ "$OPEN_APP" -eq 1 ]; then
  info "Launching ${APP_NAME}"
  open "$INSTALL_APP"
fi

echo
if [ "$PRESERVE_STATE" -eq 1 ]; then
  echo "✅ Update complete"
else
  echo "✅ Installation complete"
fi
echo "   App: $INSTALL_APP"
if [ -n "$ORIGIN" ]; then
  echo "   Bootstrap origin: $ORIGIN"
fi
if [ -n "$ORIGIN" ]; then
  echo "   Reinstall hint: $(bootstrap_origin_install_hint "$ORIGIN")"
fi
