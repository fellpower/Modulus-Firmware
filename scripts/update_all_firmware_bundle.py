"""Add verified full BINs to an existing release bundle without rebuilding firmware.

The source directory must contain the original all-firmware ZIP, MANIFEST.json,
FLASH-INSTRUCTIONS-EN-DE.md and release SHA256SUMS.txt. Output uses a fresh folder.
"""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile


def sha(data):
    return hashlib.sha256(data).hexdigest()


def parse_sums(data):
    return {name: digest for digest, name in
            (line.split(None, 1) for line in data.decode('utf-8-sig').splitlines() if line.strip())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--full-images', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads((args.source / 'MANIFEST.json').read_text(encoding='utf-8-sig'))
    tag = manifest['release']
    zip_name = f'modulus-all-firmware-{tag}.zip'
    sums = parse_sums((args.source / 'SHA256SUMS.txt').read_bytes())
    for name in [zip_name, 'MANIFEST.json', 'FLASH-INSTRUCTIONS-EN-DE.md']:
        if sha((args.source / name).read_bytes()) != sums[name]:
            raise ValueError(f'Source checksum mismatch: {name}')
    with zipfile.ZipFile(args.source / zip_name) as z:
        if len(z.namelist()) != len(set(z.namelist())):
            raise ValueError('Duplicate ZIP entries')
        files = {item.filename: z.read(item) for item in z.infolist() if not item.is_dir()}
    original = dict(files)
    for name, digest in parse_sums(files['SHA256SUMS.txt']).items():
        if sha(files[name]) != digest:
            raise ValueError(f'Original bundle checksum mismatch: {name}')
    if json.loads(files['MANIFEST.json']) != manifest:
        raise ValueError('Internal/external manifests differ')

    full_sums = parse_sums((args.full_images / 'SHA256SUMS-full.txt').read_bytes())
    entries = []
    for target, output in [('tab5-p4', 'tab5-p4'), ('tab5-c6', 'tab5-c6'), ('s3-xiao', 'xiao-s3')]:
        name = f'modulus-{output}-full-{tag}.bin'
        data = (args.full_images / name).read_bytes()
        if sha(data) != full_sums[name]:
            raise ValueError(f'Full image checksum mismatch: {name}')
        config = json.loads(files[f'{target}/flasher_args.json'])
        end = 0
        for address, rel in sorted(config['flash_files'].items(), key=lambda x: int(x[0], 16)):
            offset = int(address, 16)
            part = files[f'{target}/{rel}']
            if offset < end or data[end:offset] != b'\xff' * (offset-end) or data[offset:offset+len(part)] != part:
                raise ValueError(f'Full image differs from original bundle: {target}/{rel}')
            end = offset + len(part)
        if len(data) != end:
            raise ValueError(f'Unexpected image size: {name}')
        files[name] = data
        entries.append({'file': name, 'bytes': len(data), 'sha256': sha(data),
                        'flash_offset': '0x0', 'chip': config['extra_esptool_args']['chip']})
    manifest['full_images'] = entries
    manifest['packaging_note'] = 'Full images merged from original release files; no firmware rebuilt.'
    files['MANIFEST.json'] = (json.dumps(manifest, indent=2, ensure_ascii=False)+'\n').encode()
    files['FLASH-full.md'] = (args.full_images / 'FLASH-full.md').read_bytes()
    files['SHA256SUMS-full.txt'] = (args.full_images / 'SHA256SUMS-full.txt').read_bytes()
    files['VIDEOANLEITUNG.de.md'] = (Path(__file__).resolve().parents[1] / 'VIDEOANLEITUNG.de.md').read_bytes()
    note = f'''# Single-BIN full images / Full-Images als einzelne BIN

The three `*-full-{tag}.bin` files are now included **in the ZIP root**.
Flash exactly one matching BIN at `0x0`; see `FLASH-full.md` for commands.
The original per-target files, OTA apps and licenses remain included.
Full images are for wired installation/recovery, never the OTA menus.
The Tab5 C6 uses its internal programming connector and a USB-TTL programmer;
the normal Tab5 USB-C port programs the P4.

Die drei `*-full-{tag}.bin` liegen jetzt **direkt im ZIP-Hauptordner**.
Pro Chip genau eine passende BIN bei `0x0` flashen; Befehle in `FLASH-full.md`.
Einzeldateien, OTA-Apps und Lizenzen bleiben enthalten. Full-BINs niemals im
OTA-Menü auswählen. Der C6 wird über seinen internen Programmieranschluss mit
USB-TTL-Downloader geflasht; die normale Tab5-USB-C-Buchse flasht den P4.
Deutsche Video-Stichpunkte: `VIDEOANLEITUNG.de.md`.

**No firmware rebuild / Kein Firmware-Neubau:** This package still contains the
original {tag} firmware. The later C6 legacy OTA fix (commit 69ca844) is NOT
in these BINs and requires a newly built P4 image for testing.
Das Paket enthält weiterhin die ursprüngliche {tag}-Firmware. Der spätere
C6-Legacy-OTA-Fix (Commit 69ca844) ist NICHT in diesen BINs enthalten.

---

'''.encode()
    instructions = note + (args.source / 'FLASH-INSTRUCTIONS-EN-DE.md').read_bytes()
    files['README.md'] = instructions
    files['SHA256SUMS.txt'] = ''.join(f'{sha(data)}  {name}\n' for name, data in sorted(files.items())
                                     if name != 'SHA256SUMS.txt').encode()
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError('Output must be empty; original files are never overwritten locally')
    with zipfile.ZipFile(args.output / zip_name, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name, data in sorted(files.items()):
            z.writestr(name, data)
    # Reopen and verify every original firmware/license plus all internal checksums.
    with zipfile.ZipFile(args.output / zip_name) as z:
        assert z.testzip() is None
        for name, data in original.items():
            if name not in ('MANIFEST.json', 'README.md', 'SHA256SUMS.txt'):
                assert z.read(name) == data, name
        for name, digest in parse_sums(z.read('SHA256SUMS.txt')).items():
            assert sha(z.read(name)) == digest, name
    (args.output / 'MANIFEST.json').write_bytes(files['MANIFEST.json'])
    (args.output / 'FLASH-INSTRUCTIONS-EN-DE.md').write_bytes(instructions)
    for name in [zip_name, 'MANIFEST.json', 'FLASH-INSTRUCTIONS-EN-DE.md']:
        sums[name] = sha((args.output / name).read_bytes())
    for item in entries:
        sums[item['file']] = item['sha256']
    (args.output / 'SHA256SUMS.txt').write_text(''.join(f'{digest}  {name}\n' for name, digest in sorted(sums.items())), encoding='utf-8')
    print(f'Verified {len(files)} bundle files; preserved all original firmware and licenses.')
    print(f'{zip_name}: {sums[zip_name]}')


if __name__ == '__main__':
    main()
