#!/usr/bin/env python3
"""Pinned RK3308 vendor-object workaround. Python >=3.6; no third-party modules."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

HEAD = '95ca1f76fe3a33b6c3061f200e9f4be6e47293dd'
ORIGINAL = 'edabae700a3439331f996904aec77a3bddefbf49c578d4176a54af494e3f7d4a'
CANDIDATE = '7b92411868b99ef71b16853c7fe041881fec061a1f217e5836efbe6c30fce29f'
REFERENCES = {
    'drivers/spi/spi-wk2xxx.o': '8d9262d5c51603cc4c0bca2c1f90d889b540bfd0eb697ff38de4c9183598f0f3',
    'vmlinux': '7ffe906490388c65f99388c9ad9610457d7addc891b4e9e6150b68362ebfe3c5',
    'arch/arm64/boot/Image': 'd8a7551c14f1c47847c79bd71304a7d35f68a6e340734585febf90498aeb7679',
}
DEFAULT_KERNEL = '/home/epcb/workspace/rockchip/rk3308-src/rk3308_linux_release_v1.5.0a_20221212/kernel'
INPUT = 'drivers/spi/spi-wk2xxx'
OUTPUT = 'drivers/spi/spi-wk2xxx-late'
MAKEFILE = 'drivers/spi/Makefile'


def need(condition, message):
    if not condition:
        raise RuntimeError(message)


def validate_references():
    values = dict(REFERENCES)
    values.update({INPUT: ORIGINAL, OUTPUT: CANDIDATE})
    for path, value in values.items():
        need(re.fullmatch(r'[0-9a-f]{64}', value) is not None,
             'Invalid reference SHA-256 (expected 64 lowercase hex characters): ' + path)


def report_references(hashes):
    validate_references()
    matches = {path: hashes[path] == expected for path, expected in REFERENCES.items()}
    labels = [('COMPOSITE', 'drivers/spi/spi-wk2xxx.o'),
              ('VMLINUX', 'vmlinux'), ('IMAGE', 'arch/arm64/boot/Image')]
    for label, path in labels:
        print(label + '_REFERENCE_MATCH=' + ('YES' if matches[path] else 'NO'))
        print(label + '_SHA256=' + hashes[path])
    print('BOARD_TESTED_REFERENCE_MATCH=' + ('YES' if all(matches.values()) else 'NO'))
    image_match = matches['arch/arm64/boot/Image']
    if not image_match:
        print('Image differs from board-tested binary: test this Image on the board before accepting it.')
    elif not all(matches.values()):
        print('Image matches board-tested binary; build/debug artifacts differ. Inspect their hashes; this mismatch alone does not require a rebuild or another board test.')
    return matches


def run(args, cwd=None):
    return subprocess.check_output(args, cwd=str(cwd) if cwd else None).decode()


def digest(path):
    h = hashlib.sha256()
    with open(str(path), 'rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


class Elf:
    """Small reader for trusted ELF64 little-endian AArch64 build artifacts."""
    def __init__(self, path):
        self.data = Path(path).read_bytes()
        need(self.data[:6] == b'\x7fELF\x02\x01', 'Expected ELF64 little-endian: ' + str(path))
        need(struct.unpack_from('<H', self.data, 18)[0] == 183, 'Expected AArch64: ' + str(path))
        self.etype = struct.unpack_from('<H', self.data, 16)[0]
        shoff = struct.unpack_from('<Q', self.data, 40)[0]
        size, count, names_index = struct.unpack_from('<HHH', self.data, 58)
        need(size == 64 and count > 0, 'Unsupported section table')
        self.sections = [struct.unpack_from('<IIQQQQIIQQ', self.data, shoff + size*i) for i in range(count)]
        names = self.payload(names_index)
        self.names = [self.string(names, s[0]) for s in self.sections]
        self.symbols = {}
        self.tables = {}
        for i, sec in enumerate(self.sections):
            if sec[1] != 2:  # SHT_SYMTAB
                continue
            need(sec[9] == 24, 'Unexpected symbol size')
            strings = self.payload(sec[6])
            table = []
            for off in range(sec[4], sec[4] + sec[5], 24):
                name, info, other, index, value, length = struct.unpack_from('<IBBHQQ', self.data, off)
                entry = (self.string(strings, name), index, value, length)
                table.append(entry)
                if entry[0]:
                    self.symbols.setdefault(entry[0], []).append(entry)
            self.tables[i] = table

    @staticmethod
    def string(blob, offset):
        return blob[offset:blob.index(b'\0', offset)].decode()

    def payload(self, index):
        s = self.sections[index]
        return self.data[s[4]:s[4] + s[5]]

    def symbol(self, name):
        matches = self.symbols.get(name, [])
        need(len(matches) == 1, 'Expected unique symbol: ' + name)
        return matches[0]

    def check_object(self):
        need(self.etype == 1, 'Expected relocatable object')
        need('.initcall6.init' not in self.names, 'Stale level-6 initcall section')
        need(self.names.count('.initcall7.init') == 1, 'Missing/duplicate level-7 section')
        idx = self.names.index('.initcall7.init')
        need(self.sections[idx][5] == 8, 'Expected one initcall pointer')
        sym = self.symbol('__initcall_wk2xxx_init6')
        need(sym[1] == idx and sym[2] == 0 and sym[3] == 8, 'Initcall symbol section/size mismatch')
        rels = [s for s in self.sections if s[1] == 4 and s[7] == idx]
        need(len(rels) == 1 and rels[0][5] == 24 and rels[0][9] == 24, 'Expected one RELA entry')
        r = rels[0]
        offset, info, addend = struct.unpack_from('<QQq', self.data, r[4])
        need(offset == 0 and (info & 0xffffffff) == 257, 'Expected R_AARCH64_ABS64 at offset 0')
        target = self.tables[r[6]][info >> 32]
        init = self.symbol('wk2xxx_init')
        need(target[1] == init[1] and target[2] + addend == init[2], 'Relocation does not target wk2xxx_init')

    def placement(self):
        need(self.etype == 2, 'Expected linked ET_EXEC vmlinux')
        start = self.symbol('__initcall7_start')[2]
        end = self.symbol('__initcall_end')[2]
        entry = self.symbol('__initcall_wk2xxx_init6')
        need(start <= entry[2] and entry[2] + 8 <= end, 'WK2xxx is outside level-7 range')
        sec = self.sections[entry[1]]
        offset = entry[2] - sec[3]
        need(0 <= offset and offset + 8 <= sec[5], 'Pointer is outside its section')
        pointer = struct.unpack_from('<Q', self.data, sec[4] + offset)[0]
        need(pointer == self.symbol('wk2xxx_init')[2], 'Final initcall pointer does not target wk2xxx_init')
        return {'level7_start': hex(start), 'entry': hex(entry[2]), 'end': hex(end), 'function': hex(pointer)}


def source_state(kernel):
    need(run(['git', 'rev-parse', 'HEAD'], kernel).strip() == HEAD, 'Kernel HEAD does not match pinned commit')
    for rel in (INPUT, MAKEFILE):
        need(not (kernel / rel).is_symlink(), 'Refusing symlink: ' + rel)
    need(digest(kernel / INPUT) == ORIGINAL, 'Vendor input hash mismatch')
    base = subprocess.check_output(['git', 'show', 'HEAD:' + MAKEFILE], cwd=str(kernel))
    pattern = rb'(?m)^spi-wk2xxx-objs[ \t]*:=[ \t]*spi-wk2xxx[ \t]*$'
    patched, count = re.subn(pattern, b'spi-wk2xxx-objs := spi-wk2xxx-late', base)
    need(count == 1, 'Expected exactly one vendor Kbuild assignment')
    current = (kernel / MAKEFILE).read_bytes()
    need(current in (base, patched), 'Other changes in drivers/spi/Makefile; review manually')
    candidate = kernel / OUTPUT
    need(not candidate.is_symlink(), 'Refusing candidate symlink')
    if candidate.exists():
        need(digest(candidate) == CANDIDATE, 'Existing candidate hash mismatch; not overwritten')
        Elf(candidate).check_object()
    return patched, current == patched, candidate.exists()


def check_source(kernel):
    _, patched, candidate = source_state(kernel)
    need(patched and candidate, 'Run apply first')
    print('SOURCE_PASS: pinned commit, original/candidate hashes, Kbuild rule, relocation')


def apply(kernel, prefix):
    patched, is_patched, has_candidate = source_state(kernel)
    if not has_candidate:
        need(prefix, '--cross-prefix is required to generate the candidate')
        objcopy = prefix + 'objcopy'
        banner = run([objcopy, '--version']).splitlines()[0]
        need(re.search(r'\b2\.27\b', banner), 'Use the original Linaro Binutils 2.27 objcopy')
        with tempfile.TemporaryDirectory(prefix='.wk-late-', dir=str(kernel / 'drivers/spi')) as tmp:
            generated = Path(tmp) / 'candidate'
            subprocess.check_call([objcopy, '--rename-section', '.initcall6.init=.initcall7.init', str(kernel / INPUT), str(generated)])
            need(digest(generated) == CANDIDATE, 'Generated hash mismatch; source Makefile unchanged')
            Elf(generated).check_object()
            need(not (kernel / OUTPUT).exists(), 'Candidate appeared concurrently')
            os.replace(str(generated), str(kernel / OUTPUT))
    if not is_patched:
        # Only the checked single-line difference is applied; vendor input is untouched.
        (kernel / MAKEFILE).write_bytes(patched)
    check_source(kernel)
    print('APPLY_PASS (idempotent)')


def check_build(kernel):
    validate_references()
    check_source(kernel)
    need('CONFIG_SPI_WK2XXX=y' in (kernel / '.config').read_text().splitlines(), 'Expected built-in CONFIG_SPI_WK2XXX=y')
    import shlex
    cmdfile = kernel / 'drivers/spi/.spi-wk2xxx.o.cmd'
    records = [line for line in cmdfile.read_text().splitlines() if line.startswith('cmd_') and ':=' in line]
    need(len(records) == 1, 'Unexpected composite .cmd format')
    tokens = shlex.split(records[0].split(':=', 1)[1])
    need(OUTPUT in tokens and INPUT not in tokens, 'Composite command still uses old input')
    Elf(kernel / 'drivers/spi/spi-wk2xxx.o').check_object()
    placement = Elf(kernel / 'vmlinux').placement()
    hashes = {p: digest(kernel / p) for p in REFERENCES}
    print('INITCALL_PLACEMENT_PASS ' + json.dumps(placement, sort_keys=True))
    matches = report_references(hashes)
    print('IMAGE_BYTES=' + str((kernel / 'arch/arm64/boot/Image').stat().st_size))
    return {'hashes': hashes, 'placement': placement,
            'artifact_reference_matches': matches,
            'board_tested_image_match': matches['arch/arm64/boot/Image'],
            'board_tested_reference_match': all(matches.values())}


def build(kernel, prefix, checkpoint_root, jobs):
    check_source(kernel)
    need(prefix and checkpoint_root, 'build requires --cross-prefix and --checkpoint-dir')
    need(not os.environ.get('KBUILD_OUTPUT') and not os.environ.get('KCONFIG_CONFIG'), 'Unset KBUILD_OUTPUT/KCONFIG_CONFIG; this recipe builds in-tree')
    need(not os.environ.get('MAKEFLAGS') and not os.environ.get('MFLAGS'), 'Unset MAKEFLAGS/MFLAGS to avoid inherited dry-run/output overrides')
    need('CONFIG_SPI_WK2XXX=y' in (kernel / '.config').read_text().splitlines(), 'Reuse the validated .config with CONFIG_SPI_WK2XXX=y')
    versions = {name: run([prefix + name, '--version']).splitlines()[0] for name in ('gcc', 'ld', 'objcopy')}
    need('6.3.1' in versions['gcc'] and '2.27' in versions['ld'], 'Use the original Linaro GCC 6.3.1 / Binutils 2.27')
    need(run([prefix + 'gcc', '-dumpmachine']).strip() == 'aarch64-linux-gnu', 'Unexpected compiler target')
    root = Path(checkpoint_root).resolve()
    need(root != kernel and kernel not in root.parents, 'Checkpoint directory must be outside kernel tree')
    root.mkdir(parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix='wk-late-', dir=str(root)))
    for rel in list(REFERENCES) + ['.config', MAKEFILE, 'drivers/spi/.spi-wk2xxx.o.cmd']:
        source = kernel / rel
        need(not source.is_symlink(), 'Refusing build-artifact symlink: ' + rel)
        if source.exists():
            dest = backup / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(source), str(dest))
    (backup / 'toolchain.json').write_text(json.dumps(versions, indent=2) + '\n')
    (backup / 'kernel.diff').write_bytes(subprocess.check_output(['git', 'diff', 'HEAD'], cwd=str(kernel)))
    (backup / 'kernel-status.txt').write_text(run(['git', 'status', '--short'], kernel))
    print('CHECKPOINT=' + str(backup), flush=True)
    # The top-level intermediate .o goal did not rebuild in this SDK. Invalidate
    # only the backed-up composite, then let the full Image target recurse Kbuild.
    composite = kernel / 'drivers/spi/spi-wk2xxx.o'
    if composite.exists():
        composite.unlink()
    command = ['make', '-j' + str(jobs), 'ARCH=arm64', 'CROSS_COMPILE=' + prefix, 'HOSTCFLAGS=-O2 -fcommon', 'Image']
    (backup / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    with open(str(backup / 'build.log'), 'w') as logfile:
        process = subprocess.Popen(command, cwd=str(kernel), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        for line in process.stdout:
            print(line, end='', flush=True)
            logfile.write(line)
        need(process.wait() == 0, 'Build failed; keep checkpoint and inspect build.log')
    result = check_build(kernel)
    result['config_sha256'] = digest(kernel / '.config')
    (backup / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('BUILD_PASS; artifacts still require the appropriate board checks')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['check-source', 'apply', 'check-build', 'build'])
    p.add_argument('--kernel', default=DEFAULT_KERNEL)
    p.add_argument('--cross-prefix', help='Full prefix ending in aarch64-linux-gnu-; same execution environment as SDK build')
    p.add_argument('--checkpoint-dir', help='Outside kernel tree; required only by build')
    p.add_argument('--jobs', type=int, default=4)
    args = p.parse_args()
    validate_references()
    need(args.jobs > 0, '--jobs must be positive')
    kernel = Path(args.kernel).resolve()
    if args.action == 'check-source':
        check_source(kernel)
    elif args.action == 'apply':
        apply(kernel, args.cross_prefix)
    elif args.action == 'check-build':
        check_build(kernel)
    else:
        build(kernel, args.cross_prefix, args.checkpoint_dir, args.jobs)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, IndexError, struct.error, subprocess.CalledProcessError) as error:
        print('FAIL: ' + str(error), file=sys.stderr)
        sys.exit(1)
