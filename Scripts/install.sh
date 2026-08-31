#!/bin/bash
# Builds NotchLimits and installs it to /Applications, then launches it.
# Pass --launch-agent to also install + load a login LaunchAgent
# (RunAtLoad only — this app is not a daemon, so KeepAlive is false).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

./Scripts/bundle.sh

pkill -x NotchLimits || true

DEST="/Applications/NotchLimits.app"
mkdir -p "$DEST/Contents/MacOS"
rsync -a --delete "build/NotchLimits.app/" "$DEST/"

open "$DEST"
echo "Installed $DEST"

if [[ "${1:-}" == "--launch-agent" ]]; then
    LABEL="com.hayden.notchlimits"
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    mkdir -p "$HOME/Library/LaunchAgents"

    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/Contents/MacOS/NotchLimits</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
PLIST_EOF

    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    echo "Launch agent installed and loaded: $PLIST"
fi
