#!/usr/bin/env python3
"""Read-only Cooyeye SD importer and local AVI-to-MP4 converter.

All progress is newline-delimited JSON on stdout. The native helper only reads.
"""
import argparse
import json
import os
import plistlib
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

from cooyeye_backend import FAT


def report(obj):
    print(json.dumps(obj), flush=True)


def devices():
    """Find external partitions, tolerating diskutil plist failures.

    An unplugged card is an empty device list, not a fatal app error.
    """
    import re
    found = {}
    try:
        proc = subprocess.run(['/usr/sbin/diskutil', 'list', '-external', '-plist'],
                              capture_output=True, timeout=12)
        if proc.returncode == 0:
            info = plistlib.loads(proc.stdout)
            for disk in info.get('AllDisksAndPartitions', []):
                for part in disk.get('Partitions', []):
                    ident = part.get('DeviceIdentifier', '')
                    if not re.fullmatch(r'disk\d+s\d+', ident):
                        continue
                    name = str(part.get('Content') or 'Unknown')
                    if name.lower() == 'linux':
                        name = 'Linux partition (possible Cooyeye)'
                    found[ident] = {'device': '/dev/r' + ident, 'name': name,
                                    'size': int(part.get('Size') or 0),
                                    'parent': disk.get('DeviceIdentifier', '')}
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.TimeoutExpired):
        pass
    # Text output fallback for macOS versions that reject plist arguments.
    try:
        proc = subprocess.run(['/usr/sbin/diskutil', 'list', 'external'],
                              capture_output=True, text=True, timeout=12)
        if proc.returncode == 0:
            parent = ''
            for line in proc.stdout.splitlines():
                disk = re.match(r'^/dev/(disk\d+)\s+\(external', line)
                if disk:
                    parent = disk.group(1)
                    continue
                match = re.search(r'^\s*\d+:\s+(.+?)\s+(\d+(?:\.\d+)?\s*[KMGT]B)\s+(disk\d+s\d+)\s*$', line)
                if not match:
                    continue
                label, size_text, ident = match.groups()
                if ident in found:
                    if 'linux' in label.lower():
                        found[ident]['name'] = 'Linux partition (possible Cooyeye)'
                    continue
                size_match = re.match(r'(\d+(?:\.\d+)?)\s*([KMGT])B', size_text)
                size = int(float(size_match.group(1)) * 1000 ** ('KMGT'.index(size_match.group(2)) + 1)) if size_match else 0
                found[ident] = {'device': '/dev/r' + ident,
                                'name': 'Linux partition (possible Cooyeye)' if 'linux' in label.lower() else label.strip(),
                                'size': size, 'parent': parent}
    except (OSError, subprocess.TimeoutExpired):
        pass
    return sorted(found.values(), key=lambda d: ('linux' not in d['name'].lower(), d['device']))


def ensure_visible(path):
    """Remove macOS hidden flag from completed files, without changing data."""
    if sys.platform == 'darwin':
        # Explicitly clear Finder's hidden attribute on the final named file.
        subprocess.run(['/usr/bin/chflags', 'nohidden', str(path)],
                       capture_output=True, check=False)
        subprocess.run(['/usr/bin/xattr', '-d', 'com.apple.FinderInfo', str(path)],
                       capture_output=True, check=False)



def unique_path(directory, stem, extension):
    candidate = directory / (stem + extension)
    counter = 1
    while candidate.exists():
        candidate = directory / f'{stem}_{counter}{extension}'
        counter += 1
    return candidate


def ffmpeg_path():
    path = shutil.which('ffmpeg') or next((p for p in ('/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg') if Path(p).exists()), None)
    if not path:
        raise ValueError('FFmpeg missing. Install with brew install ffmpeg')
    return path


def duration_seconds(path):
    probe = shutil.which('ffprobe') or next((p for p in ('/opt/homebrew/bin/ffprobe', '/usr/local/bin/ffprobe') if Path(p).exists()), None)
    if not probe:
        return None
    try:
        proc = subprocess.run([probe, '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', str(path)], capture_output=True, text=True, timeout=15)
        value = float(proc.stdout.strip())
        return value if value > 0 else None
    except (ValueError, OSError, subprocess.TimeoutExpired):
        return None


def convert(source, destination, file_id, index, total):
    duration = duration_seconds(source)
    temp = destination.with_name('.' + destination.stem + '.partial.mp4')
    # Never overwrite an unrelated partial file.
    temp = unique_path(destination.parent, temp.stem, '.mp4')
    command = [ffmpeg_path(), '-hide_banner', '-loglevel', 'error', '-fflags', '+genpts+discardcorrupt',
               '-err_detect', 'ignore_err', '-i', str(source), '-map', '0:v:0', '-map', '0:a?',
               '-c:v', 'libx264', '-preset', 'fast', '-crf', '19', '-pix_fmt', 'yuv420p',
               '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart',
               '-progress', 'pipe:1', '-nostats', '-y', str(temp)]
    report({'event': 'stage', 'stage': 'convert', 'file': file_id, 'index': index, 'total': total, 'progress': 0})
    process = None
    try:
        with tempfile.TemporaryFile(mode='w+t') as errors:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors, text=True, bufsize=1)
            for line in process.stdout:
                if line.startswith('out_time_us=') or line.startswith('out_time_ms='):
                    try:
                        elapsed = int(line.split('=', 1)[1]) / 1000000
                        if duration:
                            report({'event': 'progress', 'stage': 'convert', 'file': file_id,
                                    'index': index, 'total': total, 'progress': min(0.99, max(0, elapsed / duration))})
                    except ValueError:
                        pass
            result = process.wait()
            errors.seek(0)
            stderr = errors.read()
            if result != 0:
                raise RuntimeError(stderr[-1800:] or 'FFmpeg conversion failed')
        if not temp.is_file() or temp.stat().st_size == 0:
            raise RuntimeError('FFmpeg returned success without producing a video')
        os.replace(temp, destination)
        ensure_visible(destination)
        report({'event': 'progress', 'stage': 'convert', 'file': file_id, 'index': index, 'total': total, 'progress': 1})
    finally:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if temp.exists():
            temp.unlink()


def import_files(args):
    if not args.device or not args.output:
        raise ValueError('Missing SD card or output directory')
    output = Path(args.output).expanduser()
    output.mkdir(parents=True, exist_ok=True)
    if args.convert:
        ffmpeg_path()
    fs = FAT(args.device, remote=True)
    try:
        all_files = fs.files()
        requested = set(args.files or [])
        chosen = [e for e in all_files if e['path'] in requested]
        if len(chosen) != len(requested):
            raise ValueError('One or more selected recordings could not be found')
        for index, entry in enumerate(chosen, 1):
            file_id = entry['path']
            name = Path(entry['name'])
            stem = name.stem + ('_' + entry['timestamp'] if entry.get('timestamp') else '')
            avi_destination = unique_path(output, stem, name.suffix.lower())
            report({'event': 'start', 'file': file_id, 'index': index, 'total': len(chosen)})
            report({'event': 'stage', 'stage': 'extract', 'file': file_id, 'index': index, 'total': len(chosen), 'progress': 0})
            partial = unique_path(output, '.' + avi_destination.name + '.partial', '.tmp')
            try:
                fs.extract(entry, partial, progress=lambda copied, size: report({
                    'event': 'progress', 'stage': 'extract', 'file': file_id,
                    'index': index, 'total': len(chosen), 'progress': copied / size if size else 1,
                    'bytes': copied, 'size': size}))
                os.replace(partial, avi_destination)
                ensure_visible(avi_destination)
            finally:
                if partial.exists():
                    partial.unlink()
            report({'event': 'extracted', 'file': file_id, 'output': str(avi_destination)})
            if args.convert and avi_destination.suffix.lower() != '.mp4':
                mp4_destination = unique_path(output, avi_destination.stem, '.mp4')
                try:
                    convert(avi_destination, mp4_destination, file_id, index, len(chosen))
                except Exception as exc:
                    report({'event': 'file_error', 'file': file_id, 'index': index,
                            'total': len(chosen), 'error': str(exc), 'avi': str(avi_destination)})
                    continue
                report({'event': 'done', 'file': file_id, 'output': str(mp4_destination), 'avi': str(avi_destination)})
            else:
                report({'event': 'done', 'file': file_id, 'output': str(avi_destination)})
        report({'event': 'complete', 'count': len(chosen)})
    finally:
        fs.close()


def local_convert(args):
    if not args.output:
        raise ValueError('Missing output directory')
    output = Path(args.output).expanduser()
    output.mkdir(parents=True, exist_ok=True)
    ffmpeg_path()
    paths = [Path(p).expanduser() for p in (args.files or [])]
    if not paths:
        raise ValueError('Select local AVI files first')
    for index, source in enumerate(paths, 1):
        if not source.is_file() or source.suffix.lower() not in ('.avi', '.mp4', '.mov', '.mkv'):
            raise ValueError(f'Unsupported or missing local video: {source}')
        destination = unique_path(output, source.stem, '.mp4')
        report({'event': 'start', 'file': str(source), 'index': index, 'total': len(paths)})
        convert(source, destination, str(source), index, len(paths))
        report({'event': 'done', 'file': str(source), 'output': str(destination)})
    report({'event': 'complete', 'count': len(paths)})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['devices', 'scan', 'import', 'convert'])
    parser.add_argument('--device')
    parser.add_argument('--output')
    parser.add_argument('--files', nargs='*')
    parser.add_argument('--convert', action='store_true')
    args = parser.parse_args()
    if args.action == 'devices':
        report({'devices': devices()})
    elif args.action == 'scan':
        if not args.device:
            raise ValueError('Missing device')
        fs = FAT(args.device, remote=True)
        try:
            report({'files': fs.files()})
        finally:
            fs.close()
    elif args.action == 'import':
        import_files(args)
    else:
        local_convert(args)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        main()
    except KeyboardInterrupt:
        report({'event': 'cancelled'})
        sys.exit(130)
    except Exception as exc:
        report({'event': 'error', 'error': str(exc)})
        sys.exit(1)
