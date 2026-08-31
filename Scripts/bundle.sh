#!/bin/bash
# Builds NotchLimits in release mode and assembles build/NotchLimits.app,
# ad-hoc signed so it launches without a paid Developer ID.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c release

APP_DIR="build/NotchLimits.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

cp ".build/release/NotchLimits" "$APP_DIR/Contents/MacOS/NotchLimits"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

codesign --force --deep -s - "$APP_DIR"

echo "Built $APP_DIR"
