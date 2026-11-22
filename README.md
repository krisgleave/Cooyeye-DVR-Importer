# Cooyeye DVR Importer

A native macOS SwiftUI application for reading recordings from compatible Cooyeye DVR SD cards without mounting or modifying them. Keeps the original AVI and optionally creates a playable H.264/AAC MP4. Includes a local video converter, two-column recording selection with blue checkmarks, per-file/overall progress and cancellation.

## Why the card does not mount

The card tested for this project has an MBR partition advertised as **Linux (type 0x83)**, but its recording data uses FAT32 structures. The partition label is not evidence that it contains an ext filesystem. macOS does not normally expose this particular layout as a mounted Finder volume. This importer reads the partition's FAT32 structures directly, through a narrowly scoped native reader. This is a description of the tested card, not a guarantee for every Cooyeye model or firmware.

**Choose Ignore when macOS offers to initialize the card. Do not erase, repartition, repair or change its partition type.** This application is an importer, not a filesystem repair utility.

## Install

Download assets from [Releases](https://github.com/krisgleave/Cooyeye-DVR-Importer/releases).

1. This release is built for **Apple Silicon (arm64)**. The app targets macOS 13+, but runtime verification was performed on macOS 27.2.1 only. Homebrew dependencies may require a newer macOS; consult Homebrew's supported systems. Intel binaries and a clean-Mac test are not included.
2. Install [Homebrew](https://brew.sh) using its official instructions if needed. Run `Setup Dependencies.command` from the release. It checks for Python 3 and FFmpeg/FFprobe, asks before installing missing packages and runs Homebrew as your normal user. Internet access is needed for missing dependencies. It does not download or run a Homebrew bootstrap script automatically. Alternatively run `brew install python ffmpeg` yourself.
3. Open `Cooyeye-DVR-Importer-1.0.0-arm64.pkg` while logged into your normal desktop account. Approve the macOS administrator prompt. It installs the real app in `/Applications` and the native reader in `/Library/Application Support/Cooyeye DVR Importer`. Existing installed apps are backed up under that support directory's `Backups` folder.
4. Launch **Cooyeye DVR Importer** from Applications. Setup & Help repeats dependency and permissions guidance.
5. If a scan reports **Operation not permitted**, grant Full Disk Access to `/Library/Application Support/Cooyeye DVR Importer/cooyeye-reader` in System Settings → Privacy & Security. Use the app's Show reader button to find it. Restart the Mac after granting access. The app cannot grant this privacy permission itself.

### Signing and Gatekeeper

The app and reader have **ad-hoc signatures**, verified locally. The installer is **unsigned**. None is Developer ID signed or Apple notarized. A signature check does not establish publisher identity or Apple approval. Downloaded files may be blocked by Gatekeeper; follow [Apple's per-app Open Anyway guidance](https://support.apple.com/en-us/102445) only after verifying the source and published SHA-256 hashes. No script disables Gatekeeper or strips quarantine. Managed Macs may prohibit overrides. Public distribution with a standard trusted installation experience requires Developer ID Application/Installer certificates, signing, notarization and stapling, followed by testing of those exact artifacts.

## Use

Insert the card, select SD card and Refresh. Confirm the selected device; choose Scan if needed. Select recordings using the blue checks. Choose an output folder and whether to automatically convert to MP4, then Import. Original AVIs are retained even if conversion fails. Files already present receive numbered names. Invalid or absent recording timestamps are omitted rather than invented. Progress and the import log report failures.

For existing files, choose Local converter → Add videos → Choose output → Convert. AVI, MP4, MOV and MKV inputs are supported by the client; codec support depends on FFmpeg. Originals are unchanged. Cancel stops the active operation and removes its incomplete temporary output; completed files remain.

## Security and permissions

The GUI, Python and FFmpeg run as the logged-in user. Only the small C reader runs as root via launchd. It accepts a user-owned `0600` Unix socket, checks peer UID, verifies a `/dev/rdiskNsM` path against external partitions, and opens it with `O_RDONLY`. Its protocol only supports OPEN, bounded READ (up to 1 MiB), and CLOSE. It has no write/format command and does not execute caller-supplied shell commands. It uses a fixed `diskutil` command to identify external partitions.

The helper permits **any process running as the installing user** to read eligible external partitions; it is not cryptographically restricted to this GUI or to Cooyeye cards. Full Disk Access is a powerful grant. The helper is single-client and not designed for hostile multi-user service workloads. Installation configures the current desktop user's UID. Fast-user-switching/multiple simultaneous users are not tested. No recording is uploaded and no telemetry is implemented. Homebrew installation contacts its upstream services. Source/release artifacts exclude recordings, personal paths, credentials and build caches.

To uninstall the helper, run `./uninstall-helper.sh` as the user who installed it and authorize its sudo prompt, then remove the app from Applications. Homebrew dependencies are shared and deliberately retained. Remove the reader's Full Disk Access entry manually. User recordings and backups are preserved.

## Troubleshooting

- **No card:** reinsert it, check the reader/cable and Refresh. `diskutil list external` should show a partition. Do not initialize it.
- **No such file / connection refused:** reinstall the package to register/start the reader. Check `/var/run/cooyeye-importer-$(id -u).sock` and `sudo launchctl print system/uk.cooyeye.dvrreader.$(id -u)`.
- **Operation not permitted:** grant Full Disk Access to the native executable, not Python. A replaced ad-hoc reader can require renewing that permission. Restart after changing it.
- **Missing Python or FFmpeg:** run Setup & Help → Set up dependencies. Finder does not inherit Terminal's PATH; the app checks the standard Homebrew Python locations and python.org's Current framework installation. FFmpeg/FFprobe are searched in PATH and standard Homebrew locations.
- **Unsupported FAT32 / broken chain:** stop and preserve the card. This reader intentionally rejects unsupported or damaged structures; it does not repair them.
- **Conversion failed:** the AVI remains available. Read the log; try Local converter. An incomplete DVR recording may not decode.
- **Cannot save:** choose a writable folder, grant a requested Files & Folders permission, and check free disk space. MP4 files can be larger than the original.

## Build from source

Install Xcode Command Line Tools (Swift 5.9+), Python 3.9+ and FFmpeg. On an Apple Silicon Mac:

```sh
brew install python ffmpeg
./build-on-mac.sh
open 'Cooyeye DVR Importer.app'
./scripts/package.sh
```

The build copies the canonical root Python files into SwiftPM resources, creates ICNS sizes from the included approved cyan-blue SD-card PNG, builds a release executable and applies/verifies an ad-hoc signature. Packaging compiles the reader and creates the app ZIP and actual macOS installer in `dist/`. Dependencies are **not bundled**. End users do not need Swift or a C compiler to install the prebuilt package. A source-only helper installation remains available via `./install-helper.sh`, which does require the C compiler.

Review `packaging/preinstall` and `postinstall` before installing. Build on the oldest macOS you intend to support and test dependency compatibility there before expanding support claims. Do not label an arm64 build universal. See [CHANGELOG](CHANGELOG.md) and [verification report](VERIFICATION.md).
