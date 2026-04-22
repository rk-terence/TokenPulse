#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TokenPulse"
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
SWIFT_BUILD_ARGS=(
    --package-path "$ROOT_DIR"
    -c "$CONFIGURATION"
    --disable-sandbox
)
BUILD_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
EXECUTABLE_PATH="$BUILD_DIR/$APP_NAME"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_SOURCE_DIR="$ROOT_DIR/TokenPulse/Assets.xcassets/AppIcon.appiconset"
ICONSET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tokenpulse-iconset.XXXXXX")"
ICON_PATH="$RESOURCES_DIR/AppIcon.icns"
ENTITLEMENTS_PATH="$ROOT_DIR/TokenPulse/TokenPulse.entitlements"

resolve_signing_mode() {
    if [[ -n "${TOKENPULSE_SIGNING:-}" ]]; then
        printf '%s\n' "$TOKENPULSE_SIGNING"
        return
    fi

    local dotenv_path="$ROOT_DIR/.env"
    if [[ -f "$dotenv_path" ]]; then
        local dotenv_signing_mode
        dotenv_signing_mode="$(
            DOTENV_PATH="$dotenv_path" bash -c '
                set -a
                # shellcheck source=/dev/null
                source "$DOTENV_PATH"
                set +a
                printf "%s" "${TOKENPULSE_SIGNING:-}"
            '
        )"
        if [[ -n "$dotenv_signing_mode" ]]; then
            printf '%s\n' "$dotenv_signing_mode"
            return
        fi
    fi

    printf 'adhoc\n'
}

SIGNING_MODE="$(resolve_signing_mode)"

cleanup() {
    rm -rf "$ICONSET_DIR"
}
trap cleanup EXIT

swift build "${SWIFT_BUILD_ARGS[@]}"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    echo "error: built executable not found at $EXECUTABLE_PATH" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/TokenPulse/Info.plist" "$CONTENTS_DIR/Info.plist"

mkdir -p "$ICONSET_DIR/AppIcon.iconset"
cp "$ICONSET_SOURCE_DIR"/*.png "$ICONSET_DIR/AppIcon.iconset/"
if ! iconutil -c icns "$ICONSET_DIR/AppIcon.iconset" -o "$ICON_PATH"; then
    echo "warning: failed to generate AppIcon.icns; packaging app without a custom Finder icon" >&2
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
fi

case "$SIGNING_MODE" in
    off)
        ;;
    adhoc)
        codesign --force --sign - --entitlements "$ENTITLEMENTS_PATH" "$APP_DIR"
        ;;
    *)
        codesign --force --sign "$SIGNING_MODE" --entitlements "$ENTITLEMENTS_PATH" --options runtime "$APP_DIR"
        ;;
esac

echo "Packaged $APP_DIR"
