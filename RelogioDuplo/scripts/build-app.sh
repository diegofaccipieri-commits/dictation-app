#!/bin/bash
# Monta build/RelogioDuplo.app. Com --install, copia para /Applications e abre.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/RelogioDuplo.app"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/RelogioDuplo"

rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RelogioDuplo"

swift scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>RelogioDuplo</string>
    <key>CFBundleIdentifier</key><string>com.diegofaccipieri.RelogioDuplo</string>
    <key>CFBundleName</key><string>RelogioDuplo</string>
    <key>CFBundleDisplayName</key><string>RelogioDuplo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Necessário para mostrar no Calendar o dia em que você clicou.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Pronto: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x RelogioDuplo 2>/dev/null || true
    while pgrep -x RelogioDuplo >/dev/null; do sleep 0.2; done
    rm -rf "/Applications/RelogioDuplo.app"
    cp -R "$APP" "/Applications/RelogioDuplo.app"
    open "/Applications/RelogioDuplo.app"
    echo "Instalado em /Applications/RelogioDuplo.app"
fi
