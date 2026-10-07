#!/usr/bin/env python3
"""E7c guards: reviewed inputs, embedded config, payload header/layout/manifest.

No hardware tests; compiled DT semantics and U-Boot relocation remain for E8.
"""
import hashlib
import json
import pathlib
import re
import struct
import sys
import zlib

PIN = 'e2acc2211022246c77740d5df08265cc27eedcc5'
CONFIG_SHA = 'f016cbd3aeb47a615fad9ce65e116e310481ba628af4bd24ed3c01cbede2f499'
DTS_SHA = 'fdf7ebfdf4608c19b4dddbdd311d2031614779c8eb0c444d4c272bb8e1c68b50'
FRAGMENT_SHA = 'a1a65a61675107e5824e9b69bb9dadaaaf3666776733a9fe3a642c363c6437fd'
ROOTFS_SHA = '7eb45684d0a3f879f92742950abdd6adf6c6dcbe54ba07d266a1d4c027b817c7'
RELEASE = '6.12.111-epcb-ihc3308gw-lab5'


def need(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def config(path):
    values = {}
    for line in path.read_text().splitlines():
        if line.startswith('CONFIG_') and '=' in line:
            key, value = line.split('=', 1)
            values[key] = value
        else:
            m = re.fullmatch(r'# (CONFIG_\w+) is not set', line)
            if m:
                values[m[1]] = 'n'
    return values


def inputs(run):
    for name, digest in [
        ('build/.config', CONFIG_SHA),
        ('inputs/rk3308-ihc3308gw.dts', DTS_SHA),
        ('inputs/ihc3308gw.fragment', FRAGMENT_SHA),
        ('src/arch/arm64/boot/dts/rockchip/rk3308-ihc3308gw.dts', DTS_SHA),
    ]:
        need(sha(run/name) == digest, f'Reviewed hash mismatch: {name}')
    report = json.loads((run/'configuration.json').read_text())
    for key, expected in {
        'kernel_commit': PIN, 'bsp_baseline': 'cf4190d',
        'config_sha256': CONFIG_SHA, 'dts_sha256': DTS_SHA,
        'fragment_sha256': FRAGMENT_SHA,
    }.items():
        need(report.get(key) == expected, f'E7b manifest mismatch: {key}')
    old = config(run/'inputs/lab4.validated.config')
    new = config(run/'build/.config')
    changes = {k: (old.get(k), new.get(k)) for k in old.keys() | new.keys() if old.get(k) != new.get(k)}
    expected = {f'CONFIG_{k}': ('m', 'y') for k in ['STMMAC_ETH', 'STMMAC_PLATFORM', 'DWMAC_ROCKCHIP', 'PCS_XPCS']}
    expected['CONFIG_LOCALVERSION'] = ('"-epcb-ihc3308gw-lab4"', '"-epcb-ihc3308gw-lab5"')
    need(changes == expected, 'Config diff differs from reviewed five changes')
    makefile = 'arch/arm64/boot/dts/rockchip/Makefile'
    expected_make = (run/'inputs/rockchip.Makefile.upstream').read_bytes() + b'\ndtb-$(CONFIG_ARCH_ROCKCHIP) += rk3308-ihc3308gw.dtb\n'
    need((run/'src'/makefile).read_bytes() == expected_make, 'Rockchip Makefile differs from E7b transformation')
    # Confirm the dependency in this exact local kernel tree, not an online version.
    kconfig = (run/'src/drivers/net/ethernet/stmicro/stmmac/Kconfig').read_text()
    stanza = re.search(r'^config STMMAC_ETH\n(.*?)(?=^(?:config |menuconfig |if |endif)|\Z)', kconfig, re.M | re.S)
    need(stanza is not None and re.search(r'^\s+select PCS_XPCS\s*$', stanza[1], re.M), 'STMMAC_ETH select PCS_XPCS was not found in the pinned source')
    print('REVIEWED_INPUTS_PASS')


def payload_layout(image, dtb, rootfs_size):
    need(len(image) >= 64, 'Image shorter than ARM64 header')
    need(struct.unpack_from('<I', image, 56)[0] == 0x644d5241, 'Bad ARM64 Image magic')
    offset, effective_size, flags = struct.unpack_from('<QQQ', image, 8)
    need(effective_size > 0, 'Unknown effective Image size; layout needs manual review')
    need(not (flags & 1), 'Expected little-endian kernel')
    need(flags & 8, 'Image placement flag requires a different layout review')
    need(len(dtb) >= 40, 'DTB shorter than header')
    magic, dtb_size = struct.unpack_from('>II', dtb)
    need(magic == 0xd00dfeed and dtb_size == len(dtb), 'Invalid DTB magic/total size')
    need(dtb_size <= 2 * 1024 * 1024, 'DTB exceeds ARM64 boot limit')
    kernel_at, dtb_at, rootfs_at = 0x02000000, 0x08000000, 0x09000000
    need(kernel_at >= offset and (kernel_at - offset) % 0x200000 == 0, 'Kernel address does not satisfy text_offset/alignment')
    need(dtb_at % 8 == 0 and rootfs_size > 0, 'Invalid payload alignment/size')
    spans = [
        ('Image', kernel_at, kernel_at + max(len(image), effective_size)),
        ('ihc3308gw-eth.dtb', dtb_at, dtb_at + len(dtb)),
        ('rootfs.cpio.gz', rootfs_at, rootfs_at + rootfs_size),
    ]
    for name, start, end in spans:
        need(0x00200000 <= start < end <= 0x20000000, f'{name} outside the validated RAM bank')
    for left, right in zip(spans, spans[1:]):
        need(left[2] <= right[1], f'Payload overlap: {left[0]} / {right[0]}')
    need(kernel_at // 0x40000000 == (spans[-1][2] - 1) // 0x40000000, 'Kernel/initrd do not fit the same 1 GiB window')
    return {
        'text_offset': hex(offset), 'image_size': hex(effective_size), 'flags': hex(flags),
        'image_end_exclusive': hex(kernel_at + effective_size),
        'candidate_payload_ranges': {name: {'start': hex(start), 'end_exclusive': hex(end)} for name, start, end in spans},
        'payload_overlap_check': 'pass',
        'uboot_placement_and_runtime': 'pending',
    }


def artifacts(run):
    inputs(run)
    p = run/'artifacts'
    need(sha(p/'linux.config') == CONFIG_SHA, 'Artifact config hash mismatch')
    need(config(p/'image.config') == config(p/'linux.config'), 'Embedded Image config differs')
    need((p/'kernel.release').read_text().strip() == RELEASE, 'Kernel release mismatch')
    need(sha(p/'rootfs.cpio.gz') == ROOTFS_SHA, 'Rootfs is not the validated Lab 4 payload')
    layout = payload_layout((p/'Image').read_bytes(), (p/'ihc3308gw-eth.dtb').read_bytes(), (p/'rootfs.cpio.gz').stat().st_size)
    names = ['Image', 'ihc3308gw-eth.dtb', 'rootfs.cpio.gz']
    files = {}
    for name in names:
        data = (p/name).read_bytes()
        files[name] = {'bytes': len(data), 'bytes_hex': hex(len(data)), 'sha256': hashlib.sha256(data).hexdigest(), 'crc32': f'{zlib.crc32(data) & 0xffffffff:08x}'}
    report = {
        'stage': 'built-not-booted', 'runtime': 'not-tested', 'kernel_commit': PIN,
        'bsp_baseline': 'cf4190d', 'kernel_release': RELEASE,
        'builder_image': 'sha256:c77af91629b6c50b9abe5335c68355a26a9db8ba06138d0d87d648d1280960b7',
        'reviewed_config_sha256': CONFIG_SHA, 'reviewed_dts_sha256': DTS_SHA,
        'reviewed_fragment_sha256': FRAGMENT_SHA,
        'files': files, 'arm64_header_and_layout': layout,
        'dtb_compile': 'pass', 'dtb_semantic_review': 'pending',
        'dt_schema_validation': 'not-run',
    }
    (p/'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    print('IMAGE_HEADER_LAYOUT_PASS')
    print('LAB5_MANIFEST_READY')


if __name__ == '__main__':
    try:
        need(len(sys.argv) == 3 and sys.argv[1] in ('inputs', 'artifacts'), 'Usage: kernel-lab5-artifact-check.py inputs|artifacts RUN')
        (inputs if sys.argv[1] == 'inputs' else artifacts)(pathlib.Path(sys.argv[2]))
    except (ValueError, OSError, KeyError, struct.error) as error:
        raise SystemExit(f'ERROR: {error}')
