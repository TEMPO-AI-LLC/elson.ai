#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Elson"
PLIST_TEMPLATE_PATH="$ROOT_DIR/Elson/Resources/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST_TEMPLATE_PATH")"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
DEST_APP="/Applications/${APP_NAME}.app"
APP_SUPPORT_DIR="$HOME/Library/Application Support/${APP_NAME}"
CONTAINER_DIR="$HOME/Library/Containers/${BUNDLE_ID}"
DEFAULT_WORKSPACE_CONFIG="$HOME/Documents/${APP_NAME}/Config/local-config.json"
PREFERENCES_PLIST="$HOME/Library/Preferences/${BUNDLE_ID}.plist"
BUILD_ROOT="$ROOT_DIR/Elson/build"
UNIVERSAL_ZIP_NAME="${UNIVERSAL_ZIP_NAME:-elson-universal-installer.zip}"
VARIANT="auto"
PACKAGE_ZIP=0
INSTALL_AFTER_BUILD=1
SETTINGS_WAS_OPEN=0
HOST_MACOS_MAJOR=""
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_TEMPLATE_PATH" 2>/dev/null || echo '0.0.1')"
VERSION_DASH="${VERSION//./-}"
TCC_SERVICES=(
  "All"
  "ScreenCapture"
  "Microphone"
  "Accessibility"
  "SystemPolicyDocumentsFolder"
  "SystemPolicyDesktopFolder"
  "SystemPolicyDownloadsFolder"
  "SystemPolicyAllFiles"
)

declare -a VARIANTS_TO_BUILD=()

usage() {
  cat <<'EOF'
Usage:
  ./build.sh [--variant auto|modern|compat15|all] [--package-zip] [--no-install]

Options:
  --variant VALUE  Build variant to produce. Default is auto (host-compatible variant).
  --package-zip    Package both DMGs plus a local installer into elson-universal-installer.zip.
  --no-install     Build artifacts without reinstalling Elson locally.
  --help           Show this help.
EOF
}

log() {
  echo "$*"
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

variant_minimum_system_version() {
  case "$1" in
    modern) printf '%s\n' '26.0' ;;
    compat15) printf '%s\n' '15.0' ;;
    *) fail "Unknown variant: $1" ;;
  esac
}

variant_versioned_dmg_name() {
  local variant="$1"

  if [ "${#VARIANTS_TO_BUILD[@]}" -eq 1 ] && [ -n "${DMG_NAME:-}" ]; then
    printf '%s\n' "$DMG_NAME"
    return
  fi

  printf 'elson-%s-v-%s.dmg\n' "$variant" "$VERSION_DASH"
}

variant_latest_dmg_name() {
  local variant="$1"

  if [ "${#VARIANTS_TO_BUILD[@]}" -eq 1 ] && [ -n "${DMG_LATEST_NAME:-}" ]; then
    printf '%s\n' "$DMG_LATEST_NAME"
    return
  fi

  printf 'elson-%s-latest.dmg\n' "$variant"
}

variant_display_name() {
  case "$1" in
    modern) printf '%s\n' 'modern' ;;
    compat15) printf '%s\n' 'compat15' ;;
    *) fail "Unknown variant: $1" ;;
  esac
}

detect_host_macos_major_version() {
  if [ -n "${ELSON_HOST_MACOS_MAJOR_OVERRIDE:-}" ]; then
    printf '%s\n' "$ELSON_HOST_MACOS_MAJOR_OVERRIDE"
    return
  fi

  /usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{ print $1 }'
}

resolve_auto_variant() {
  local host_major="$1"

  if [ "$host_major" -ge 26 ]; then
    printf '%s\n' 'modern'
  elif [ "$host_major" -ge 15 ]; then
    printf '%s\n' 'compat15'
  else
    fail "macOS ${host_major} is not supported. Elson requires macOS 15 or newer."
  fi
}

variant_supported_on_host() {
  local variant="$1"
  local host_major="$2"

  case "$variant" in
    modern) [ "$host_major" -ge 26 ] ;;
    compat15) [ "$host_major" -ge 15 ] ;;
    *) return 1 ;;
  esac
}

clean_installed_elson() {
  log "🧽 Cleaning installed ${APP_NAME} app and local state..."
  /usr/bin/pkill -x "$APP_NAME" 2>/dev/null || true
  /bin/sleep 1

  for path in "$DEST_APP" "$HOME/Applications/${APP_NAME}.app"; do
    if [ -d "$path" ]; then
      if [ -x "$LSREGISTER" ]; then
        "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
      fi
      /bin/rm -rf "$path"
    fi
  done

  /bin/rm -rf "$APP_SUPPORT_DIR"
  /bin/rm -rf "$CONTAINER_DIR/Data" 2>/dev/null || true
  /bin/rm -f "$DEFAULT_WORKSPACE_CONFIG" 2>/dev/null || true
  /bin/rm -rf "$HOME/Library/Caches/${BUNDLE_ID}" 2>/dev/null || true
  /bin/rm -rf "$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState" 2>/dev/null || true
  /bin/rm -f "$PREFERENCES_PLIST" 2>/dev/null || true
}

install_and_reset_tcc() {
  local source_app="$1"

  log "🚚 Installing fresh ${APP_NAME}.app..."
  /usr/bin/ditto "$source_app" "$DEST_APP"
  if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
  fi

  log "🧽 Resetting TCC permissions for ${BUNDLE_ID}..."
  for service in "${TCC_SERVICES[@]}"; do
    /usr/bin/tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 || true
  done

  if [ "$SETTINGS_WAS_OPEN" -eq 1 ]; then
    log "🔄 Refreshing System Settings privacy pane..."
    /usr/bin/open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
    /bin/sleep 1
  fi

  /usr/bin/codesign --verify --deep --strict "$DEST_APP"
  /usr/bin/open "$DEST_APP"
}

copy_resources() {
  local resources_dir="$1"
  local resource=""

  mkdir -p "$resources_dir"

  for resource in AppIcon.icns model-config.json prompt-config.json; do
    if [ -f "$ROOT_DIR/Elson/Resources/$resource" ]; then
      /bin/cp "$ROOT_DIR/Elson/Resources/$resource" "$resources_dir/"
    fi
  done
}

copy_swiftpm_resource_bundles() {
  local bin_dir="$1"
  local resources_dir="$2"
  local bundle_path=""
  local found_target_bundle=0

  shopt -s nullglob
  for bundle_path in "$bin_dir"/*.bundle; do
    [ -d "$bundle_path" ] || continue
    /bin/cp -R "$bundle_path" "$resources_dir/"

    if [ "$(basename "$bundle_path")" = "Elson_Elson.bundle" ]; then
      found_target_bundle=1
    fi
  done
  shopt -u nullglob

  if [ "$found_target_bundle" -ne 1 ]; then
    fail "Missing SwiftPM resource bundle Elson_Elson.bundle in $bin_dir"
  fi
}

variant_app_path() {
  local variant="$1"
  printf '%s/%s/%s.app\n' "$BUILD_ROOT" "$variant" "$APP_NAME"
}

prepare_variant_plist() {
  local variant="$1"
  local plist_path="$2"
  local min_version=""

  min_version="$(variant_minimum_system_version "$variant")"
  /bin/cp "$PLIST_TEMPLATE_PATH" "$plist_path"
  /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $min_version" "$plist_path" >/dev/null
}

create_dmg_for_variant() {
  local variant="$1"
  local source_dir="$2"
  local versioned_name=""
  local latest_name=""
  local versioned_path=""
  local latest_path=""
  local volume_name=""

  versioned_name="$(variant_versioned_dmg_name "$variant")"
  latest_name="$(variant_latest_dmg_name "$variant")"
  versioned_path="$ROOT_DIR/$versioned_name"
  latest_path="$ROOT_DIR/$latest_name"
  volume_name="Elson $(variant_display_name "$variant") v${VERSION}"

  log "📦 Creating DMG: $versioned_name"
  /bin/rm -f "$versioned_path" "$latest_path"

  if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
      --volname "$volume_name" \
      --volicon "$ROOT_DIR/Elson/Resources/AppIcon.icns" \
      --window-pos 200 120 \
      --window-size 600 300 \
      --icon-size 100 \
      --icon "${APP_NAME}.app" 175 120 \
      --hide-extension "${APP_NAME}.app" \
      --app-drop-link 425 120 \
      "$versioned_path" \
      "$source_dir"
  else
    /usr/bin/hdiutil create \
      -volname "$volume_name" \
      -srcfolder "$source_dir" \
      -ov \
      -format UDZO \
      "$versioned_path" \
      >/dev/null
  fi

  if [ "$versioned_path" != "$latest_path" ]; then
    /bin/cp "$versioned_path" "$latest_path"
  fi

}

build_variant() {
  local variant="$1"
  local scratch_path="$ROOT_DIR/.build/$variant"
  local variant_root="$BUILD_ROOT/$variant"
  local app_dir=""
  local contents_dir=""
  local macos_dir=""
  local resources_dir=""
  local plist_path=""
  local bin_dir=""
  local executable_path=""

  log "🔨 Building ${APP_NAME} (${variant})..."
  app_dir="$(variant_app_path "$variant")"
  contents_dir="$app_dir/Contents"
  macos_dir="$contents_dir/MacOS"
  resources_dir="$contents_dir/Resources"
  plist_path="$contents_dir/Info.plist"

  /bin/rm -rf "$scratch_path" "$variant_root"
  /bin/mkdir -p "$macos_dir" "$resources_dir"

  (
    cd "$ROOT_DIR"
    ELSON_BUILD_VARIANT="$variant" swift build -c release --scratch-path "$scratch_path"
  )

  bin_dir="$(
    cd "$ROOT_DIR"
    ELSON_BUILD_VARIANT="$variant" swift build -c release --scratch-path "$scratch_path" --show-bin-path
  )"
  executable_path="$bin_dir/${APP_NAME}"

  if [ ! -x "$executable_path" ]; then
    fail "Missing release executable for ${variant}: $executable_path"
  fi

  log "📦 Creating app bundle for ${variant}..."
  /bin/cp "$executable_path" "$macos_dir/${APP_NAME}"
  /bin/chmod +x "$macos_dir/${APP_NAME}"
  prepare_variant_plist "$variant" "$plist_path"
  copy_resources "$resources_dir"
  copy_swiftpm_resource_bundles "$bin_dir" "$resources_dir"

  log "🔏 Code signing app bundle (${variant})..."
  /usr/bin/codesign --force --deep --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" "$app_dir"
  create_dmg_for_variant "$variant" "$variant_root"
}

package_universal_zip() {
  local package_root="$BUILD_ROOT/package/Elson Universal Installer"
  local zip_path="$ROOT_DIR/$UNIVERSAL_ZIP_NAME"

  log "🗜️  Packaging universal installer ZIP..."
  /bin/rm -rf "$package_root" "$zip_path"
  /bin/mkdir -p "$package_root"

  /bin/cp "$ROOT_DIR/distribution/Install Elson.command" "$package_root/Install Elson.command"
  /bin/cp "$ROOT_DIR/distribution/Update Elson.command" "$package_root/Update Elson.command"
  /bin/cp "$ROOT_DIR/install.sh" "$package_root/install.sh"
  /bin/cp "$ROOT_DIR/update.sh" "$package_root/update.sh"
  /bin/cp "$ROOT_DIR/distribution/README.txt" "$package_root/README.txt"
  /bin/cp "$ROOT_DIR/$(variant_latest_dmg_name modern)" "$package_root/$(variant_latest_dmg_name modern)"
  /bin/cp "$ROOT_DIR/$(variant_latest_dmg_name compat15)" "$package_root/$(variant_latest_dmg_name compat15)"
  /bin/chmod +x "$package_root/Install Elson.command" "$package_root/Update Elson.command" "$package_root/install.sh" "$package_root/update.sh"

  (
    cd "$BUILD_ROOT/package"
    /usr/bin/zip -qry -X "$zip_path" "Elson Universal Installer"
  )
  log "✅ Universal ZIP created: $zip_path"
}

resolve_install_variant() {
  case "$VARIANT" in
    auto|all)
      resolve_auto_variant "$HOST_MACOS_MAJOR"
      ;;
    modern|compat15)
      if variant_supported_on_host "$VARIANT" "$HOST_MACOS_MAJOR"; then
        printf '%s\n' "$VARIANT"
      else
        fail "Variant '$VARIANT' is not installable on macOS ${HOST_MACOS_MAJOR}. Re-run with --no-install or choose a compatible variant."
      fi
      ;;
    *)
      fail "Unknown variant: $VARIANT"
      ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --variant)
      [ "$#" -ge 2 ] || fail "Missing value for --variant"
      VARIANT="$2"
      shift 2
      ;;
    --package-zip)
      PACKAGE_ZIP=1
      shift
      ;;
    --no-install)
      INSTALL_AFTER_BUILD=0
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

case "$VARIANT" in
  auto)
    HOST_MACOS_MAJOR="$(detect_host_macos_major_version)"
    VARIANTS_TO_BUILD=("$(resolve_auto_variant "$HOST_MACOS_MAJOR")")
    ;;
  modern|compat15)
    HOST_MACOS_MAJOR="$(detect_host_macos_major_version)"
    VARIANTS_TO_BUILD=("$VARIANT")
    ;;
  all)
    HOST_MACOS_MAJOR="$(detect_host_macos_major_version)"
    VARIANTS_TO_BUILD=(modern compat15)
    ;;
  *)
    fail "Unsupported variant '$VARIANT'. Use auto, modern, compat15, or all."
    ;;
esac

if [ "$PACKAGE_ZIP" -eq 1 ] && [ "$VARIANT" != "all" ]; then
  fail "--package-zip requires --variant all."
fi

log "🎙️  Building ${APP_NAME}..."

require_cmd swift
require_cmd /usr/libexec/PlistBuddy
require_cmd /usr/bin/ditto
require_cmd /usr/bin/hdiutil
require_cmd /usr/bin/sw_vers
require_cmd /usr/bin/zip

if [ "$INSTALL_AFTER_BUILD" -eq 1 ] && /usr/bin/pgrep -x "System Settings" >/dev/null 2>&1; then
  SETTINGS_WAS_OPEN=1
fi

if [ "$INSTALL_AFTER_BUILD" -eq 1 ]; then
  /usr/bin/osascript -e 'tell application "System Settings" to quit' >/dev/null 2>&1 || true
fi

log "🧹 Cleaning build output..."
/bin/rm -rf "$ROOT_DIR/.build" "$BUILD_ROOT"
/bin/mkdir -p "$BUILD_ROOT"

for variant_to_build in "${VARIANTS_TO_BUILD[@]}"; do
  build_variant "$variant_to_build"
done

if [ "$PACKAGE_ZIP" -eq 1 ]; then
  package_universal_zip
fi

if [ "$INSTALL_AFTER_BUILD" -eq 1 ]; then
  install_variant="$(resolve_install_variant)"
  clean_installed_elson
  install_and_reset_tcc "$(variant_app_path "$install_variant")"
  log "✅ App installed: $DEST_APP"
else
  log "ℹ️  Skipping local reinstall (--no-install)."
fi

for built_variant in "${VARIANTS_TO_BUILD[@]}"; do
  log "✅ ${built_variant} app bundle: $(variant_app_path "$built_variant")"
  log "✅ ${built_variant} DMG: $ROOT_DIR/$(variant_versioned_dmg_name "$built_variant")"
  if [ "$(variant_versioned_dmg_name "$built_variant")" != "$(variant_latest_dmg_name "$built_variant")" ]; then
    log "✅ ${built_variant} latest DMG: $ROOT_DIR/$(variant_latest_dmg_name "$built_variant")"
  fi
done
