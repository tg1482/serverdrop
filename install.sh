#!/bin/bash
# Build ServerDrop.app into ~/Applications, start the launchd receiver, put the
# app in the Dock, and install `tomac` on the server.
#
#   ./install.sh <server>     # the server's Tailscale machine name, also an ssh host
set -euo pipefail
cd "$(dirname "$0")"

SERVER=${1:?usage: ./install.sh <server-tailscale-name>}
# this Mac's Tailscale name, which the server sends to
MAC=$(/usr/local/bin/tailscale status --self --peers=false | awk 'NR==1 {print $2}')

APP="$HOME/Applications/ServerDrop.app"
SUPPORT="$HOME/Library/Application Support/ServerDrop"
LABEL=io.github.tg1482.serverdrop.recv
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BUILD=build/ServerDrop.app

rm -rf build && mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
swiftc -O -o "$BUILD/Contents/MacOS/ServerDrop" ServerDrop.swift

swift icon.swift build/icon.png
mkdir -p build/icon.iconset
for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$BUILD/Contents/Resources/AppIcon.icns"

cat > "$BUILD/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.tg1482.serverdrop</string>
  <key>CFBundleName</key><string>ServerDrop</string>
  <key>CFBundleExecutable</key><string>ServerDrop</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Any file or folder</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>None</string>
    <key>LSItemContentTypes</key><array><string>public.item</string></array>
  </dict></array>
</dict></plist>
EOF
codesign --force --sign - "$BUILD"

mkdir -p "$HOME/Applications"
osascript -e 'tell application "ServerDrop" to quit' >/dev/null 2>&1 || true
rm -rf "$APP" && cp -R "$BUILD" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

# receiver
mkdir -p "$SUPPORT"
install -m 755 recv.sh "$SUPPORT/recv.sh"
echo "SERVER=$SERVER" > "$SUPPORT/config"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SUPPORT/recv.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/ServerDrop-recv.log</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/ServerDrop-recv.log</string>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

# Dock tile, added once
if ! defaults read com.apple.dock persistent-apps | grep -q "ServerDrop.app"; then
    defaults write com.apple.dock persistent-apps -array-add \
        "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file://$APP/</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>"
    killall Dock
fi

# server side: tomac
sed "s/@MAC@/$MAC/" tomac > build/tomac
ssh "$SERVER" 'mkdir -p ~/.local/bin'
scp -q build/tomac "$SERVER:.local/bin/tomac"
ssh "$SERVER" 'chmod 755 ~/.local/bin/tomac'

echo "installed $APP, receiver $LABEL, and tomac on $SERVER (sends to $MAC)"
