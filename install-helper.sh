#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
UID_NUMBER=$(id -u)
if [[ "$UID_NUMBER" -eq 0 ]]; then echo 'Run as your normal macOS user, not sudo.'; exit 1; fi
command -v clang >/dev/null || { echo 'Install Xcode Command Line Tools first.'; exit 1; }
LABEL="uk.cooyeye.dvrreader.${UID_NUMBER}"
SUPPORT='/Library/Application Support/Cooyeye DVR Importer'
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
clang -O2 -Wall -Wextra -o "$TMP/cooyeye-reader" cooyeye_reader.c
codesign --force --sign - "$TMP/cooyeye-reader"
cat > "$TMP/helper.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${LABEL}</string>
<key>ProgramArguments</key><array>
<string>${SUPPORT}/cooyeye-reader</string>
<string>${UID_NUMBER}</string>
</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardErrorPath</key><string>/var/log/cooyeye-reader.log</string>
</dict></plist>
PLIST
printf 'Installing native read-only reader (one administrator authorisation required).\n'
sudo /bin/launchctl bootout system "$PLIST" 2>/dev/null || true
sudo /bin/mkdir -p "$SUPPORT"
sudo /usr/bin/install -o root -g wheel -m 0755 "$TMP/cooyeye-reader" "$SUPPORT/cooyeye-reader"
sudo /usr/bin/install -o root -g wheel -m 0644 "$TMP/helper.plist" "$PLIST"
sudo /bin/rm -f "$SUPPORT/cooyeye_helper.py" "$SUPPORT/cooyeye_backend.py"
sudo /bin/launchctl bootstrap system "$PLIST"
sudo /bin/launchctl kickstart -k "system/$LABEL"
printf '\nNative reader installed at: %s/cooyeye-reader\n' "$SUPPORT"
printf 'If Scan Recordings says Operation not permitted, add THAT native executable to System Settings > Privacy & Security > Full Disk Access, then restart the helper:\n'
printf 'sudo launchctl kickstart -k system/%s\n' "$LABEL"
