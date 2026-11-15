#!/bin/bash
# Build and install ServerDrop.app with its Dock tile, start the launchd
# receiver, and put `tomac` on the server.
#   ./install.sh <server>     # the server's Tailscale machine name, also an ssh host
set -euo pipefail
cd "$(dirname "$0")"

SERVER=${1:?usage: ./install.sh <server-tailscale-name>}
MAC=$(/usr/local/bin/tailscale status --self --peers=false | awk 'NR==1 {print $2}')
APP="$HOME/Applications/ServerDrop.app"
SUPPORT="$HOME/Library/Application Support/ServerDrop"
LABEL=io.github.tg1482.serverdrop.recv
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# app
rm -rf build && mkdir -p build/ServerDrop.app/Contents/{MacOS,Resources} build/icon.iconset
swiftc -O -o build/ServerDrop.app/Contents/MacOS/ServerDrop ServerDrop.swift
swift icon.swift build/icon.png
for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o build/ServerDrop.app/Contents/Resources/AppIcon.icns
cat > build/ServerDrop.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.tg1482.serverdrop</string>
  <key>CFBundleExecutable</key><string>ServerDrop</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <!-- accept any file or folder dropped on the Dock tile -->
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>None</string>
    <key>LSItemContentTypes</key><array><string>public.item</string></array>
  </dict></array>
</dict></plist>
EOF
codesign --force --sign - build/ServerDrop.app
osascript -e 'tell application "ServerDrop" to quit' >/dev/null 2>&1 || true
mkdir -p "$HOME/Applications" && rm -rf "$APP" && cp -R build/ServerDrop.app "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
if ! defaults read com.apple.dock persistent-apps | grep -q "ServerDrop.app"; then
    defaults write com.apple.dock persistent-apps -array-add \
        "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file://$APP/</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>"
    killall Dock
fi

# receiver
mkdir -p "$SUPPORT"
install -m 755 recv.sh "$SUPPORT/recv.sh"
echo "SERVER=$SERVER" > "$SUPPORT/config"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SUPPORT/recv.sh</string></array>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/ServerDrop-recv.log</string>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

# server
sed "s/@MAC@/$MAC/" tomac | ssh "$SERVER" 'mkdir -p ~/.local/bin && cat > ~/.local/bin/tomac && chmod 755 ~/.local/bin/tomac'

echo "installed ServerDrop; $SERVER can now run: tomac FILE  (sends to $MAC)"
