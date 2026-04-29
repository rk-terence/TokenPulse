#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TokenPulse"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
PACKAGED_APP="$OUTPUT_DIR/$APP_NAME.app"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

# Pin the resolved OUTPUT_DIR so package_app.sh sees the same value we'll
# read back from PACKAGED_APP, even if the caller didn't export it.
export OUTPUT_DIR

"$ROOT_DIR/Scripts/package_app.sh"

if [[ ! -d "$PACKAGED_APP" ]]; then
    echo "error: packaged app not found at $PACKAGED_APP" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
ditto "$PACKAGED_APP" "$INSTALLED_APP"

echo "Installed $INSTALLED_APP"
echo "Launch:   open \"$INSTALLED_APP\""
