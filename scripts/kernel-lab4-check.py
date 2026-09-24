#!/usr/bin/env python3
"""Validate the ARM64 Image header, known DTB and Lab 4 RAM layout."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib

DTB_SHA256 = 'aa0ee43c8184ae500763d3b345fb0b48b2d2ce720a5d77f44ac78b1217338a8f'
RELEASE = '6.12.111-epcb-ihc3308gw-lab4'
KERNEL_ADDR = 0x02000000
DTB_ADDR = 0x08000000
INITRD_ADDR = 0x09000000


def inspect_image(data):
    if len(data) < 64 or data[56:60] != b'ARM\x64':
        raise ValueError('Image does not have a valid ARM64 Image magic/header')
    text_offset, image_size = struct.unpack_from('<QQ', data, 8)
    if text_offset != 0 or image_size == 0:
        raise ValueError('Image offset/size differs from the supported Lab 4 load policy')
    end = KERNEL_ADDR + max(len(data), image_size)
    if end > DTB_ADDR:
        raise ValueError('Kernel file or runtime image overlaps the DTB load address')
    return {'text_offset': hex(text_offset), 'image_size': hex(image_size),
            'reserved_end_exclusive': hex(end)}


def fingerprint(path, address):
    data = path.read_bytes()
    return data, {'file': path.name, 'load_address': hex(address),
                  'bytes': len(data), 'bytes_hex': hex(len(data)),
                  'sha256': hashlib.sha256(data).hexdigest(),
                  'crc32': f'{zlib.crc32(data) & 0xffffffff:08x}'}


def main():
    if len(sys.argv) != 2:
        raise ValueError('Usage: kernel-lab4-check.py ARTIFACT_DIRECTORY')
    out = Path(sys.argv[1])
    release = (out/'kernel.release').read_text().strip()
    if release != RELEASE:
        raise ValueError(f'Unexpected kernel.release: {release!r}; expected {RELEASE!r}')
    image, image_info = fingerprint(out/'Image', KERNEL_ADDR)
    dtb, dtb_info = fingerprint(out/'ihc3308gw-emmc25.dtb', DTB_ADDR)
    if dtb_info['sha256'] != DTB_SHA256:
        raise ValueError('DTB differs from the validated K11/K12/K13 baseline')
    if DTB_ADDR + len(dtb) > INITRD_ADDR:
        raise ValueError('DTB overlaps the initramfs load address')
    header = inspect_image(image)
    manifest = {'kernel_release': release, 'image_header': header,
                'payloads': [image_info, dtb_info],
                'runtime_test': 'pending: this manifest records build checks only'}
    (out/'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('IMAGE_LAYOUT_PASS')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, struct.error) as exc:
        sys.exit(f'CHECK FAILED: {exc}')
