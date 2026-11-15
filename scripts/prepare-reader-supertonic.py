#!/usr/bin/env python3
"""Provision the same pinned files as Settings; models remain outside Git."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--directory', type=Path, default=Path('build/supertonic-model'))
args = parser.parse_args()
manifest = json.loads((Path(__file__).resolve().parents[1] / 'assets/supertonic/manifest.json').read_text())
root = args.directory
root.mkdir(parents=True, exist_ok=True)
receipt = root / 'installed.json'
receipt.unlink(missing_ok=True)

def valid(path, entry):
    return path.is_file() and path.stat().st_size == entry['bytes'] and hashlib.file_digest(path.open('rb'), 'sha256').hexdigest() == entry['sha256']

def download(entry):
    path = root / entry['path']
    if not valid(path, entry):
        path.parent.mkdir(parents=True, exist_ok=True)
        partial = path.with_name(path.name + '.part')
        url = f"https://huggingface.co/{manifest['repository']}/resolve/{manifest['revision']}/{entry['path']}"
        for attempt in range(3):
            try:
                with urllib.request.urlopen(url, timeout=60) as response, partial.open('wb') as output:
                    while chunk := response.read(1024 * 1024):
                        output.write(chunk)
                if not valid(partial, entry):
                    raise ValueError(f"Checksum mismatch: {entry['path']}")
                partial.replace(path)
                break
            except Exception:
                partial.unlink(missing_ok=True)
                if attempt == 2:
                    raise
    print(entry['path'], flush=True)

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    list(pool.map(download, manifest['files']))
digest = hashlib.sha256(json.dumps(manifest, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
receipt.write_text(json.dumps({'manifest': digest}))
print(f'Installed {manifest["bytes"] / 1e6:.1f} MB at {root}', flush=True)
