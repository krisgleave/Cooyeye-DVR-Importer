#!/bin/bash
set -euo pipefail
UID_NUMBER=$(id -u)
LABEL="uk.cooyeye.dvrreader.${UID_NUMBER}"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
SUPPORT='/Library/Application Support/Cooyeye DVR Importer'
sudo /bin/launchctl bootout system "$PLIST" 2>/dev/null || true
sudo /bin/rm -f "$PLIST" "/var/run/cooyeye-importer-${UID_NUMBER}.sock" "$SUPPORT/cooyeye-reader" "$SUPPORT/cooyeye_helper.py" "$SUPPORT/cooyeye_backend.py"
echo 'Cooyeye reader service and installed helper files removed.'
