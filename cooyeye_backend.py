import socket
#!/usr/bin/env python3
"""Read-only FAT32 DVR importer. Requires root for raw external partition access."""
import argparse, json, os, plistlib, re, shutil, struct, subprocess, sys, tempfile
from pathlib import Path

def report(obj): print(json.dumps(obj), flush=True)
def diskutil(*args):
    p=subprocess.run(['/usr/sbin/diskutil',args[0],'-plist',*args[1:]],capture_output=True,check=True)
    return plistlib.loads(p.stdout)
def devices():
    """Discover external partitions by device identity, never by mount point.

    diskutil's plist keys differ across macOS releases, so retain a text-list
    fallback for unmounted MBR 0x83 (Linux) partitions.
    """
    results = {}
    try:
        info = diskutil('list', 'external')
        for disk in info.get('AllDisksAndPartitions', []):
            parent = disk.get('DeviceIdentifier', '')
            for part in disk.get('Partitions', []):
                ident = part.get('DeviceIdentifier', '')
                if not re.fullmatch(r'disk\d+s\d+', ident):
                    continue
                content = str(part.get('Content') or part.get('VolumeName') or 'Unknown')
                results[ident] = {
                    'device': '/dev/r' + ident,
                    'name': content,
                    'size': int(part.get('Size') or 0),
                    'parent': parent
                }
    except (subprocess.CalledProcessError, ValueError, KeyError):
        pass

    # diskutil's human-readable output reliably shows Linux partitions even
    # when there is no filesystem mount or volume name.
    listing = subprocess.run(['/usr/sbin/diskutil', 'list', 'external'],
                             capture_output=True, text=True, check=True).stdout
    parent = ''
    for line in listing.splitlines():
        m = re.match(r'^/dev/(disk\d+)\s+\(external', line)
        if m:
            parent = m.group(1)
            continue
        m = re.search(r'^\s*\d+:\s+(.+?)\s+(\d+(?:\.\d+)?\s*[KMGT]B)\s+(disk\d+s\d+)\s*$', line)
        if not m:
            continue
        label, size_text, ident = m.groups()
        if ident in results:
            if 'linux' in label.lower():
                results[ident]['name'] = 'Linux partition (possible Cooyeye)'
            continue
        num, unit = re.match(r'(\d+(?:\.\d+)?)\s*([KMGT])B', size_text).groups()
        results[ident] = {
            'device': '/dev/r' + ident,
            'name': 'Linux partition (possible Cooyeye)' if 'linux' in label.lower() else label.strip(),
            'size': int(float(num) * (1000 ** ('KMGT'.index(unit) + 1))),
            'parent': parent
        }
    return sorted(results.values(), key=lambda d: (
        'linux' not in d['name'].lower(), d['parent'], d['device']))

def validate_device(path):
    if not path.startswith('/dev/rdisk') or not path[10:].replace('s','').isdigit() or 's' not in path[10:]:
        raise ValueError('Select an external partition, not a whole disk')
    ident=path.removeprefix('/dev/r')
    known={d['device'] for d in devices()}
    if path not in known: raise ValueError('Selected partition is not on an external disk')
    info=diskutil('info','/dev/'+ident)
    if info.get('Internal') is not False or info.get('WholeDisk'): raise ValueError('Unsafe disk selection')

class RawReader:
    """Read-only channel to the native root broker; never opens a disk in Python."""
    def __init__(self, device):
        import socket
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(f'/var/run/cooyeye-importer-{os.getuid()}.sock')
        self.stream = self.sock.makefile('rb')
        self.sock.sendall(('OPEN ' + device + '\n').encode('ascii'))
        response = self.stream.readline(256)
        if response != b'OK\n':
            self.close()
            raise PermissionError(response.decode('utf8', 'replace').strip() or 'SD reader disconnected')

    def read(self, offset, size):
        result = bytearray()
        while len(result) < size:
            count = min(size - len(result), 1024 * 1024)
            self.sock.sendall(f'READ {offset + len(result)} {count}\n'.encode('ascii'))
            header = self.stream.readline(256)
            if not header.startswith(b'OK '):
                raise IOError(header.decode('utf8', 'replace').strip() or 'SD reader disconnected')
            received = int(header[3:])
            if received != count:
                raise IOError('Incomplete SD card read')
            while received:
                data = self.stream.read(received)
                if not data:
                    raise IOError('SD reader disconnected')
                result.extend(data)
                received -= len(data)
        return bytes(result)

    def close(self):
        try: self.stream.close()
        except OSError: pass
        try: self.sock.shutdown(socket.SHUT_RDWR)
        except OSError: pass
        try: self.sock.close()
        except OSError: pass

class FAT:
    def __init__(self,path,remote=False):
        validate_device(path)
        self.reader=RawReader(path) if remote else None
        self.fd=None if remote else os.open(path,os.O_RDONLY)
        b=self.read(0,512)
        self.bps=struct.unpack_from('<H',b,11)[0]
        self.spc=b[13]
        self.reserved=struct.unpack_from('<H',b,14)[0]
        self.fats=b[16]
        self.fatsize=struct.unpack_from('<I',b,36)[0]
        self.root=struct.unpack_from('<I',b,44)[0]
        total=struct.unpack_from('<I',b,32)[0] or struct.unpack_from('<H',b,19)[0]
        if b[510:512]!=b'\x55\xaa' or self.bps!=512 or not self.spc or self.spc & (self.spc-1) or not self.reserved or not self.fats or not self.fatsize or self.root<2:
            raise ValueError('Not a supported FAT32 volume')
        self.data_sector=self.reserved+self.fats*self.fatsize
        self.max_cluster=(total-self.data_sector)//self.spc+1
        if self.max_cluster<65526: raise ValueError('Volume is not FAT32')
        self.cache={}
    def close(self):
        if self.reader: self.reader.close()
        elif self.fd is not None: os.close(self.fd)
    def read(self,offset,size):
        start=offset//512*512
        end=(offset+size+511)//512*512
        b=self.reader.read(start,end-start) if self.reader else os.pread(self.fd,end-start,start)
        if len(b)!=end-start: raise IOError('Incomplete SD read')
        return b[offset-start:offset-start+size]
    def next(self,c):
        off=c*4
        sector=off//512
        if sector not in self.cache: self.cache[sector]=self.read((self.reserved+sector)*512,512)
        return struct.unpack_from('<I',self.cache[sector],off%512)[0]&0x0fffffff
    def chain(self,c):
        seen=set()
        while 2<=c<=self.max_cluster:
            if c in seen: raise IOError('Circular FAT chain')
            seen.add(c)
            yield c
            n=self.next(c)
            if n>=0x0ffffff8: return
            if n<2 or n>self.max_cluster: raise IOError('Broken FAT chain')
            c=n
        raise IOError('Invalid FAT cluster')
    def cluster(self,c): return self.read((self.data_sector+(c-2)*self.spc)*512,self.spc*512)
    def entries(self,c):
        lfn=[]
        for cluster in self.chain(c):
            data=self.cluster(cluster)
            for pos in range(0,len(data),32):
                e=data[pos:pos+32]
                if e[0]==0: return
                if e[0]==0xe5: lfn=[]; continue
                attr=e[11]
                if attr==15:
                    raw=e[1:11]+e[14:26]+e[28:32]
                    lfn.append(raw.decode('utf-16le','ignore').split('\0')[0].replace('\uffff',''))
                    continue
                if attr&8: lfn=[]; continue
                short=e[:8].decode('ascii','replace').strip()
                ext=e[8:11].decode('ascii','replace').strip()
                name=''.join(reversed(lfn)) if lfn else short+('.'+ext if ext else '')
                lfn=[]
                first=(struct.unpack_from('<H',e,20)[0]<<16)|struct.unpack_from('<H',e,26)[0]
                size=struct.unpack_from('<I',e,28)[0]
                d=struct.unpack_from('<H',e,24)[0]
                t=struct.unpack_from('<H',e,22)[0]
                stamp=None
                year=1980+(d>>9);month=(d>>5)&15;day=d&31
                hour=t>>11;minute=(t>>5)&63;second=(t&31)*2
                if 2000<=year<=2107 and 1<=month<=12 and 1<=day<=31 and hour<24 and minute<60 and second<60:
                    stamp=f'{year:04d}{month:02d}{day:02d}-{hour:02d}{minute:02d}{second:02d}'
                yield {'name':name,'first':first,'size':size,'dir':bool(attr&16),'timestamp':stamp}
    def files(self):
        found=[];visited=set()
        def walk(c,prefix=''):
            if c in visited: return
            visited.add(c)
            for e in self.entries(c):
                name=e['name']
                if name in ('.','..'): continue
                if e['dir']:
                    if name.upper() not in ('.TRASHES','.FSEVENTSD','.SPOTLIGHT-V100') and e['first']>=2:
                        walk(e['first'],prefix+name+'/')
                elif Path(name).suffix.lower() in ('.avi','.mp4') and e['size']:
                    e['path']=prefix+name;found.append(e)
        walk(self.root)
        return found
    def extract(self,e,target,progress=None):
        remaining=e['size']
        with open(target,'wb') as f:
            for c in self.chain(e['first']):
                block=self.cluster(c)
                n=min(remaining,len(block));f.write(block[:n]);remaining-=n
                if progress: progress(e['size']-remaining,e['size'])
                if remaining==0: break
        if remaining: raise IOError('Incomplete recording')

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('action',choices=['devices','scan','import'])
    parser.add_argument('--device');parser.add_argument('--output');parser.add_argument('--files',nargs='*')
    args=parser.parse_args()
    if args.action=='devices': report({'devices':devices()});return
    if not args.device: raise ValueError('Missing device')
    fs=FAT(args.device)
    try:
        files=fs.files()
        if args.action=='scan': report({'files':files});return
        if not args.output: raise ValueError('Missing output directory')
        ffmpeg=shutil.which('ffmpeg') or next((p for p in ('/opt/homebrew/bin/ffmpeg','/usr/local/bin/ffmpeg') if Path(p).exists()),None)
        if not ffmpeg: raise ValueError('FFmpeg missing. Install with brew install ffmpeg')
        output=Path(args.output).expanduser()
        if not output.is_dir(): raise ValueError('Output folder does not exist')
        chosen=set(args.files or [])
        for i,e in enumerate(files):
            if e['path'] not in chosen: continue
            stamp=e['timestamp']
            stem=Path(e['name']).stem
            filename=stem+(('_'+stamp) if stamp else '')+'.mp4'
            final=output/filename;n=1
            while final.exists(): final=output/(stem+(('_'+stamp) if stamp else '')+f'_{n}.mp4');n+=1
            report({'event':'start','file':e['path']})
            with tempfile.TemporaryDirectory(prefix='cooyeye-') as tmp:
                source=Path(tmp)/('recording'+Path(e['name']).suffix.lower())
                partial=Path(tmp)/'converted.mp4'
                fs.extract(e,source)
                if source.suffix.lower()=='.mp4':
                    shutil.copy2(source,partial)
                else:
                    cmd=[ffmpeg,'-hide_banner','-loglevel','error','-fflags','+genpts+discardcorrupt','-err_detect','ignore_err','-i',str(source),'-map','0:v:0','-map','0:a?','-c:v','libx264','-preset','fast','-crf','19','-pix_fmt','yuv420p','-c:a','aac','-b:a','128k','-movflags','+faststart','-y',str(partial)]
                    p=subprocess.run(cmd,capture_output=True,text=True)
                    if p.returncode: raise RuntimeError(p.stderr[-1500:])
                shutil.move(str(partial),str(final))
            report({'event':'done','file':e['path'],'output':str(final)})
        report({'event':'complete'})
    finally: fs.close()
if __name__=='__main__':
    try: main()
    except Exception as e: report({'error':str(e)});sys.exit(1)
