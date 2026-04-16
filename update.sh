#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

VARIANT="auto"
ARTIFACT=""
PASS_THROUGH_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --variant)
      [ "$#" -ge 2 ] || {
        echo "❌ Missing value for --variant" >&2
        exit 1
      }
      VARIANT="$2"
      shift 2
      ;;
    --artifact)
      [ "$#" -ge 2 ] || {
        echo "❌ Missing value for --artifact" >&2
        exit 1
      }
      ARTIFACT="$2"
      shift 2
      ;;
    *)
      PASS_THROUGH_ARGS+=("$1")
      shift
      ;;
  esac
done

if [ -z "$ARTIFACT" ]; then
  /bin/bash "$SCRIPT_DIR/build.sh" --variant "$VARIANT" --no-install
  case "$VARIANT" in
    auto)
      HOST_MACOS_MAJOR="$(
        if [ -n "${ELSON_HOST_MACOS_MAJOR_OVERRIDE:-}" ]; then
          printf '%s\n' "$ELSON_HOST_MACOS_MAJOR_OVERRIDE"
        else
          /usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{ print $1 }'
        fi
      )"
      if [ "$HOST_MACOS_MAJOR" -ge 26 ]; then
        ARTIFACT="$SCRIPT_DIR/elson-modern-latest.dmg"
      else
        ARTIFACT="$SCRIPT_DIR/elson-compat15-latest.dmg"
      fi
      ;;
    modern)
      ARTIFACT="$SCRIPT_DIR/elson-modern-latest.dmg"
      ;;
    compat15)
      ARTIFACT="$SCRIPT_DIR/elson-compat15-latest.dmg"
      ;;
    *)
      echo "❌ Unsupported variant '$VARIANT'. Use auto, modern, or compat15." >&2
      exit 1
      ;;
  esac
fi

if [ "${#PASS_THROUGH_ARGS[@]}" -gt 0 ]; then
  exec /bin/bash "$SCRIPT_DIR/install.sh" --preserve-state --artifact "$ARTIFACT" "${PASS_THROUGH_ARGS[@]}"
else
  exec /bin/bash "$SCRIPT_DIR/install.sh" --preserve-state --artifact "$ARTIFACT"
fi
