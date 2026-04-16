#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Elson"
PREVIOUS_APP_NAME="Gairvis"
BUILD_APP="$ROOT_DIR/Elson/build/${APP_NAME}.app"
INSTALL_APP="/Applications/${APP_NAME}.app"
PLIST_PATH="$ROOT_DIR/Elson/Resources/Info.plist"
BUNDLE_ID="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST_PATH" 2>/dev/null || echo 'ai.elson.desktop'
)"
PREVIOUS_BUNDLE_ID="${PREVIOUS_BUNDLE_ID:-com.gairvis.app}"
DMG_NAME="${DMG_NAME:-elson-dev-rebuild.dmg}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
APP_SUPPORT_ROOT="$HOME/Library/Application Support"
ELSON_APP_SUPPORT_DIR="$APP_SUPPORT_ROOT/Elson"
PREVIOUS_APP_SUPPORT_DIR="$APP_SUPPORT_ROOT/Gairvis"
PREFERENCES_ROOT="$HOME/Library/Preferences"
SETTINGS_WAS_OPEN=0

stop_app_processes() {
  local name="$1"
  /usr/bin/killall "$name" 2>/dev/null || true
  /usr/bin/pkill -f "/Applications/${name}\\.app/Contents/MacOS/${name}" 2>/dev/null || true
  /usr/bin/pkill -f "$name\\.app" 2>/dev/null || true
}

remove_installed_app_copies() {
  local name="$1"
  local repo_build_app="$2"

  /usr/bin/mdfind "kMDItemFSName == '${name}.app'" | while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ "$path" = "$repo_build_app" ] && continue
    case "$path" in
      "/Applications/${name}.app" | "$HOME/Applications/${name}.app" | /Volumes/*/"${name}.app")
        echo "🗑️  Removing $path"
        rm -rf "$path"
        ;;
    esac
  done

  rm -rf "/Applications/${name}.app" "$HOME/Applications/${name}.app"
}

reset_tcc_for_bundle() {
  local bundle_id="$1"
  [ -z "$bundle_id" ] && return 0

  echo "🧽 Resetting TCC for ${bundle_id}"
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
    /usr/bin/tccutil reset "$service" "$bundle_id" || true
  done
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

reset_tcc_permissions() {
  reset_tcc_for_bundle "$BUNDLE_ID"
  reset_tcc_for_bundle "$PREVIOUS_BUNDLE_ID"
}

clear_preferences_domain() {
  local domain="$1"
  [ -z "$domain" ] && return 0

  echo "🧽 Clearing preferences for ${domain}"
  /usr/bin/defaults delete "$domain" >/dev/null 2>&1 || true
  rm -f "$PREFERENCES_ROOT/${domain}.plist"
}

clear_keychain_state_for_service() {
  local service="$1"
  [ -z "$service" ] && return 0

  echo "🧽 Clearing keychain items for ${service}"
  /usr/bin/security delete-generic-password -s "$service" -a "groq_api_key" >/dev/null 2>&1 || true
  /usr/bin/security delete-generic-password -s "$service" -a "cerebras_api_key" >/dev/null 2>&1 || true
  /usr/bin/security delete-generic-password -s "$service" -a "gemini_api_key" >/dev/null 2>&1 || true
  /usr/bin/security delete-generic-password -s "$service" -a "zeroclaw_auth_token" >/dev/null 2>&1 || true
}

clear_application_support_state() {
  local path="$1"
  [ -n "$path" ] || return 0

  if [ -d "$path" ]; then
    echo "🧽 Removing app support state at ${path}"
    rm -rf "$path"
  fi
}

clear_local_app_state() {
  clear_preferences_domain "$BUNDLE_ID"
  clear_preferences_domain "$PREVIOUS_BUNDLE_ID"
  clear_preferences_domain "$APP_NAME"
  clear_preferences_domain "$PREVIOUS_APP_NAME"
  clear_keychain_state_for_service "$BUNDLE_ID"
  clear_keychain_state_for_service "$PREVIOUS_BUNDLE_ID"
  clear_application_support_state "$ELSON_APP_SUPPORT_DIR"
  clear_application_support_state "$PREVIOUS_APP_SUPPORT_DIR"
  /usr/bin/killall cfprefsd >/dev/null 2>&1 || true
  /bin/sleep 1
}

if /usr/bin/pgrep -x "System Settings" >/dev/null 2>&1; then
  SETTINGS_WAS_OPEN=1
fi

echo "🧹 Stopping Elson and previous app processes"
stop_app_processes "$APP_NAME"
stop_app_processes "$PREVIOUS_APP_NAME"
/usr/bin/osascript -e 'tell application "System Settings" to quit' >/dev/null 2>&1 || true
/bin/sleep 1

echo "🧽 Unregistering installed Elson and previous app bundles"
unregister_bundle_if_present "/Applications/${APP_NAME}.app"
unregister_bundle_if_present "$HOME/Applications/${APP_NAME}.app"
unregister_bundle_if_present "/Applications/${PREVIOUS_APP_NAME}.app"
unregister_bundle_if_present "$HOME/Applications/${PREVIOUS_APP_NAME}.app"

echo "🧹 Removing installed Elson and previous app copies"
remove_installed_app_copies "$APP_NAME" "$BUILD_APP"
remove_installed_app_copies "$PREVIOUS_APP_NAME" ""

echo "🔨 Rebuilding Elson"
FW_RESET_SCREEN_TCC=0 DMG_NAME="$DMG_NAME" "$ROOT_DIR/build.sh"

if [ ! -d "$BUILD_APP" ]; then
  echo "❌ Missing built app: $BUILD_APP"
  exit 1
fi

echo "📦 Installing Elson into /Applications"
rm -rf "$INSTALL_APP"
cp -R "$BUILD_APP" "$INSTALL_APP"

echo "🧽 Cleaning stale Elson login items and bundle registrations"
remove_stale_login_items "$INSTALL_APP"
unregister_bundle_if_present "$BUILD_APP"
echo "🗂️  Registering fresh Elson bundle"
register_bundle_if_present "$INSTALL_APP"

echo "🧽 Resetting permissions for Elson and any legacy app bundle"
reset_tcc_permissions

echo "🧽 Clearing local Elson and legacy app state"
clear_local_app_state

if [ "$SETTINGS_WAS_OPEN" -eq 1 ]; then
  echo "🔄 Refreshing System Settings privacy pane"
  /usr/bin/open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
  /bin/sleep 1
fi

echo "🚀 Launching Elson"
open "$INSTALL_APP"

echo "✅ Rebuild complete"
echo "   App: $INSTALL_APP"
echo "   DMG: $ROOT_DIR/$DMG_NAME"
