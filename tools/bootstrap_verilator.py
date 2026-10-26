"""Install a user-local Verilator from checksum-verified official Debian packages.

Initial discovery authenticates Debian InRelease with the system Debian keyring;
subsequent installs use the committed package SHA-256 lock. No root is required.
"""
from pathlib import Path
import argparse
import hashlib
import json
import lzma
import os
import shutil
import subprocess
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--prefix', type=Path, default=ROOT/'build/toolchain/verilator')
parser.add_argument('--discover', action='store_true', help='Authenticate current Debian metadata and write a package lock')
args = parser.parse_args()
prefix = args.prefix.resolve()
prefix.mkdir(parents=True, exist_ok=True)
lock_path = ROOT/'tools/verilator.lock.json'

def fetch(url, destination, digest=None):
    if destination.is_file() and digest and hashlib.sha256(destination.read_bytes()).hexdigest() == digest:
        return
    with urlopen(url, timeout=90) as response:
        data = response.read()
    if digest and hashlib.sha256(data).hexdigest() != digest:
        raise RuntimeError('SHA-256 mismatch: '+url)
    destination.write_bytes(data)

if args.discover or not lock_path.exists():
    if not shutil.which('sqv'):
        raise SystemExit('sqv and /usr/share/keyrings/debian-archive-keyring.gpg are required for initial discovery')
    signed = prefix/'InRelease'
    release = prefix/'Release.authenticated'
    fetch('https://deb.debian.org/debian/dists/trixie/InRelease', signed)
    if release.exists():
        release.unlink()
    subprocess.run(['sqv','--keyring','/usr/share/keyrings/debian-archive-keyring.gpg',
                    '--cleartext','--output',str(release),str(signed)], check=True)
    sha_section = release.read_text().split('SHA256:\n',1)[1].split('\nSHA',1)[0]
    matches = [line.split() for line in sha_section.splitlines() if line.strip().endswith(' main/binary-amd64/Packages.xz')]
    if len(matches) != 1:
        raise RuntimeError('Could not uniquely locate signed amd64 package index')
    index_hash = matches[0][0]
    index = prefix/'Packages.xz'
    fetch('https://deb.debian.org/debian/dists/trixie/main/binary-amd64/by-hash/SHA256/'+index_hash, index, index_hash)
    entries = lzma.decompress(index.read_bytes()).decode().split('\n\n')
    package = next(entry for entry in entries if entry.startswith('Package: verilator\n'))
    fields = dict(line.split(': ',1) for line in package.splitlines() if ': ' in line and not line.startswith(' '))
    lock = {'package':'verilator','version':fields['Version'],'architecture':'amd64',
            'url':'https://deb.debian.org/debian/'+fields['Filename'],
            'sha256':fields['SHA256'],'index_sha256':index_hash,
            'verification':'Debian InRelease -> signed index SHA256 -> package SHA256'}
    lock_path.write_text(json.dumps(lock,indent=2)+'\n')
else:
    lock = json.loads(lock_path.read_text())

archive = prefix/'verilator.deb'
fetch(lock['url'], archive, lock['sha256'])
subprocess.run(['dpkg-deb','-x',str(archive),str(prefix)], check=True)
binary = prefix/'usr/bin/verilator'
environment = dict(os.environ, VERILATOR_ROOT=str(prefix/'usr/share/verilator'))
result = subprocess.run([str(binary),'--version'], env=environment, text=True, capture_output=True, check=True)
print(result.stdout.strip())
print('VERILATOR_ROOT='+environment['VERILATOR_ROOT'])
print('VERILATOR='+str(binary))
