#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -m) == arm64 ]] || { echo 'Current package script targets Apple Silicon.'; exit 1; }
./build-on-mac.sh
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/root/Applications" "$stage/root/Library/Application Support/Cooyeye DVR Importer" dist
/usr/bin/ditto 'Cooyeye DVR Importer.app' "$stage/root/Applications/Cooyeye DVR Importer.app"
clang -O2 -Wall -Wextra -o "$stage/root/Library/Application Support/Cooyeye DVR Importer/cooyeye-reader" cooyeye_reader.c
codesign --force --sign - "$stage/root/Library/Application Support/Cooyeye DVR Importer/cooyeye-reader"
pkgbuild --root "$stage/root" --scripts packaging --identifier uk.cooyeye.dvrimporter.installer --version 1.0.0 --install-location / --ownership recommended dist/Cooyeye-DVR-Importer-1.0.0-arm64.pkg
/usr/bin/ditto -c -k --keepParent 'Cooyeye DVR Importer.app' dist/Cooyeye-DVR-Importer-1.0.0-arm64-app.zip
cp 'scripts/Setup Dependencies.command' dist/
