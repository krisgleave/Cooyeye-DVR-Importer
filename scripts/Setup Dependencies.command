#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
echo 'Cooyeye DVR Importer — dependency setup'
echo 'Python 3 runs the importer. FFmpeg converts AVI to MP4. Both remain separate Homebrew installations.'
if ! command -v brew >/dev/null; then
  echo 'Install Homebrew using its official installer, then run this setup again.'
  open https://brew.sh
  read -r -p 'Press Return to close.'
  exit 1
fi
missing=()
command -v python3 >/dev/null && [[ "$(command -v python3)" != /usr/bin/python3 ]] || missing+=(python)
command -v ffmpeg >/dev/null || missing+=(ffmpeg)
if (( ${#missing[@]} )); then
  echo "Homebrew will install: ${missing[*]} (internet access and disk space required)."
  read -r -p 'Continue? [y/N] ' answer
  [[ "$answer" == y || "$answer" == Y ]] || exit 1
  brew install "${missing[@]}"
fi
python3 -c 'import sys; assert sys.version_info >= (3, 9); print("Python ready:", sys.version.split()[0])'
ffmpeg -version | head -n 1
ffprobe -version | head -n 1
echo 'Dependencies ready. Return to Cooyeye DVR Importer and click Refresh.'
read -r -p 'Press Return to close.'
