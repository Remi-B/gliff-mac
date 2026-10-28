#!/usr/bin/env python3
"""Prepare QEMU from the host distribution packages without changing the system."""

from pathlib import Path
import os
import concurrent.futures
import hashlib
import json
import subprocess
import tarfile
import urllib.request
import urllib.parse

state=Path(os.environ.get('GLIFF_VM_DIR',str(Path.home()/'.local/share/gliff-mac-vm')))
pid_file=state/'qemu.pid'
if pid_file.exists():
    try:
        os.kill(int(pid_file.read_text().strip()),0)
    except ProcessLookupError:
        pass
    else:
        raise SystemExit('Stop the VM before refreshing its QEMU runtime.')
cache=state/'cache/qemu-packages'
runtime=state/'runtime'
cache.mkdir(parents=True,exist_ok=True)
runtime.mkdir(exist_ok=True)
raw=subprocess.check_output(['pacman','-Sp','--print-format','%n %r %l','qemu-system-x86','qemu-img','qemu-block-dmg'],text=True)
packages=[line.split(' ',2) for line in raw.splitlines() if line.strip()]
requested={name:url for name,repository,url in packages}
repositories={name:repository for name,repository,url in packages}
metadata={}
for database in Path('/var/lib/pacman/sync').glob('*.db'):
    with tarfile.open(database) as archive:
        for member in archive:
            if not member.name.endswith('/desc'):
                continue
            entries=archive.extractfile(member).read().decode().split('\n\n')
            fields={part.splitlines()[0].strip('%'):part.splitlines()[1:] for part in entries if len(part.splitlines())>1}
            name=fields.get('NAME',[''])[0]
            if name in requested and database.stem == repositories[name] and fields.get('FILENAME',[''])[0] == urllib.parse.unquote(urllib.parse.urlsplit(requested[name]).path.rsplit('/',1)[-1]):
                metadata[name]={key:values[0] for key,values in fields.items()}
if not set(requested)<=set(metadata):
    raise SystemExit('Missing package metadata: {}'.format(set(requested)-set(metadata)))

def download(item):
    name,url=item
    info=metadata[name]
    package=cache/info['FILENAME']
    expected=info['SHA256SUM']
    if not package.exists() or hashlib.sha256(package.read_bytes()).hexdigest()!=expected:
        with urllib.request.urlopen(url,timeout=60) as response,package.open('wb') as output:
            while block:=response.read(1024*1024):
                output.write(block)
    if hashlib.sha256(package.read_bytes()).hexdigest()!=expected:
        raise SystemExit('Package checksum mismatch: {}'.format(name))
    return name,package,expected

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    downloaded=list(pool.map(download,requested.items()))
for name,package,digest in downloaded:
    subprocess.run(['tar','--zstd','-xf',str(package),'-C',str(runtime),'--exclude=.INSTALL','--exclude=.BUILDINFO','--exclude=.MTREE','--exclude=.PKGINFO'],check=True)
record=[{'name':name,'repository':repositories[name],'filename':package.name,'sha256':digest,'url':requested[name]} for name,package,digest in downloaded]
(state/'runtime-packages.json').write_text(json.dumps(record,indent=2)+'\n')
print(f'Prepared {len(downloaded)} checksum-verified distribution packages in the user-owned VM runtime; system package state is unchanged.')
