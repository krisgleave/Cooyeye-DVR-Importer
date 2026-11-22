# Cooyeye DVR Importer update

## Changes
- Two workflow tabs: SD card recordings and local video converter.
- Live extraction and conversion progress (file and overall), with cancel.
- SD extraction always keeps the original AVI/MP4 in the output directory.
- Optional automatic MP4 conversion; converted MP4 is saved alongside AVI.
- Local AVI/MOV/MKV/MP4 conversion without the SD card.
- Automatically opens the output folder in Finder on success (toggleable).
- Dark interface with orange accents and simplified controls.
- Fixed the refresh/scan busy-state race; scan now runs sequentially.
- Python reports newline-delimited JSON progress to the Swift interface.
- Existing native read-only reader and its installer are unchanged.
- Existing build script still copies and verifies the latest Python sources.

## Installation
1. Back up your existing working `Cooyeye-DVR-Importer` folder.
2. Extract this archive and copy its *source files* into the existing project folder, replacing matching files. Do not overwrite your working `.app` with an old bundle.
3. Quit the app and run `./build-on-mac.sh` from the project folder.
4. Run `open "Cooyeye DVR Importer.app"`.
5. No helper reinstall is expected; existing native reader and permissions are preserved.

## Verification performed
- Python syntax compilation and shell script syntax check.
- Local AVI-to-MP4 conversion with a generated video and ffprobe duration validation.
- Mock FAT32 extraction both with and without conversion, checking original AVI retention and unique filenames.

## Not verified in this environment
- The SwiftUI application cannot be compiled on this Linux container (macOS SwiftUI/AppKit unavailable).
- Physical SD-card import and native helper cannot be exercised here; verify these on your Mac before relying on the update.

## Safety
- The SD card is accessed via the existing read-only native helper.
- Output files are created with collision-safe names; existing originals are not overwritten.
- Cancellation leaves already completed AVI/MP4 files in place.
