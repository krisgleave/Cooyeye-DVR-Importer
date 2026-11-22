#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
command -v swift >/dev/null || { echo 'Install Xcode Command Line Tools: xcode-select --install'; exit 1; }
command -v ffmpeg >/dev/null || { echo 'Install FFmpeg: brew install ffmpeg'; exit 1; }
cp cooyeye_client.py cooyeye_backend.py Sources/CooyeyeImporter/Resources/
swift build -c release
./scripts/make-icon.sh
APP="$PWD/Cooyeye DVR Importer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PWD/assets/CooyeyeIcon.icns" "$APP/Contents/Resources/CooyeyeIcon.icns"
cp .build/release/CooyeyeImporter "$APP/Contents/MacOS/CooyeyeImporter"
# SwiftPM Bundle.module looks for the target resource bundle in Contents/Resources.
BUNDLE=$(find .build -type d -name 'CooyeyeImporter_CooyeyeImporter.bundle' -print -quit)
if [[ -z "$BUNDLE" ]]; then
  echo "ERROR: SwiftPM resource bundle missing" >&2
  exit 1
fi
ditto "$BUNDLE" "$APP/Contents/Resources/$(basename "$BUNDLE")"

# Always package the current, tested Python source files.
RESOURCE_DIR="$APP/Contents/Resources/$(basename "$BUNDLE")/Contents/Resources"

cp "$PWD/cooyeye_client.py" "$RESOURCE_DIR/cooyeye_client.py"
cp "$PWD/cooyeye_backend.py" "$RESOURCE_DIR/cooyeye_backend.py"

python3 -m py_compile "$RESOURCE_DIR/cooyeye_client.py" "$RESOURCE_DIR/cooyeye_backend.py"

cmp "$PWD/cooyeye_client.py" "$RESOURCE_DIR/cooyeye_client.py"
cmp "$PWD/cooyeye_backend.py" "$RESOURCE_DIR/cooyeye_backend.py"

echo "Verified: latest Python files included in app."
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CooyeyeImporter</string>
<key>CFBundleIdentifier</key><string>uk.cooyeye.dvrimporter</string>
<key>CFBundleName</key><string>Cooyeye DVR Importer</string>
<key>CFBundleIconFile</key><string>CooyeyeIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
cp "scripts/Setup Dependencies.command" "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 1.0.0' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$APP/Contents/Info.plist"
[[ -s "$APP/Contents/Resources/CooyeyeIcon.icns" ]] || { echo "Missing bundled icon" >&2; exit 1; }
echo "Created: $APP"
echo 'Open it with: open "Cooyeye DVR Importer.app"'
