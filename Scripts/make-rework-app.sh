#!/bin/zsh
# LumiRework.app — mevcut Lumi.app'in YANINDA test için ayrı kimlikli macOS build'i.
# Farklı bundle id (com.lumi.rework) + ad "Lumi Rework"; çalışan Lumi.app'e dokunmaz.
# Kullanım: Scripts/make-rework-app.sh   (release build + ad-hoc imza)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/LumiPackages"
# KALICI scratch: bu SwiftPM sürümünün resource_bundle_accessor'ı bundle'ları
# derleme-zamanı scratch yolundan (Bundle(path: buildPath)) okur; /tmp reboot'ta
# silinince app açılmaz. Kalıcı dizin reboot'a dayanır. Bu dizini SİLME.
SCRATCH="${SCRATCH:-$HOME/.lumi/lumi-rework-build}"
DEST="${DEST:-$HOME/Applications}"
APP="$DEST/LumiRework.app"
VERSION="${VERSION:-0.6.0-rework}"

echo "▸ Release build (scratch: $SCRATCH)…"
cd "$PKG"
swift build -c release --product Lumi --scratch-path "$SCRATCH"
BIN="$SCRATCH/release/Lumi"

echo "▸ Bundle iskeleti… ($APP)"
mkdir -p "$DEST"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LumiRework"
# NOT: Bu SwiftPM sürümünün resource_bundle_accessor'ı resource bundle'ları
# Bundle(path: buildPath) ile KALICI scratch yolundan okur (Contents/Resources'a
# bakmaz). Bundle'lar zaten $SCRATCH/*/release/ altında; app-kökü temiz kalsın
# (imza geçerli → `open` çalışır). Kopyalama/sarma gerekmez.

echo "▸ App icon…"
ICON_SRC="$ROOT/Assets/icon.png"
ICONSET="/tmp/LumiRework.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z $retina $retina "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.lumi.rework</string>
    <key>CFBundleName</key>
    <string>Lumi Rework</string>
    <key>CFBundleDisplayName</key>
    <string>Lumi Rework</string>
    <key>CFBundleExecutable</key>
    <string>LumiRework</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Lumi needs microphone access for Claude Code voice mode.</string>
</dict>
</plist>
PLIST

ENTITLEMENTS="/tmp/LumiRework.entitlements"
cat > "$ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENT

echo "▸ Ad-hoc imza…"
codesign --force --entitlements "$ENTITLEMENTS" --sign - "$APP"
codesign --verify --verbose=2 "$APP"
echo "✓ $APP hazır (bundle: com.lumi.rework — mevcut Lumi.app'ten ayrı)"

# LaunchServices bayat kaydını yenile (open ile açılması için)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
echo "  LaunchServices kaydı yenilendi."
