import contextlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import tempfile

script = Path(__file__).resolve().parents[1] / 'wk-late.py'
spec = importlib.util.spec_from_file_location('recipe', script)
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def fixture(path, linked=False, level=7, bad_reloc=False, bad_pointer=False, bad_range=False):
    names = ['', '.shstrtab', '.strtab', '.symtab', '.init.text', '.initcall%d.init' % level, '.rela.initcall%d.init' % level]
    shstrings = b'\0'
    shoffsets = []
    for name in names:
        shoffsets.append(len(shstrings))
        shstrings += name.encode() + b'\0'
    strings = b'\0'
    symbolnames = ['wk2xxx_init', '__initcall_wk2xxx_init6', '__initcall7_start', '__initcall_end']
    offsets = {}
    for name in symbolnames:
        offsets[name] = len(strings)
        strings += name.encode() + b'\0'
    code, call = (0x1000, 0x2000) if linked else (0, 0)
    symbols = bytes(24)
    symbols += struct.pack('<IBBHQQ', 0, 3, 0, 4, code, 0)
    symbols += struct.pack('<IBBHQQ', offsets[symbolnames[0]], 2, 0, 4, code, 4)
    symbols += struct.pack('<IBBHQQ', offsets[symbolnames[1]], 1, 0, 5, call, 8)
    if linked:
        symbols += struct.pack('<IBBHQQ', offsets[symbolnames[2]], 0, 0, 5, call + (8 if bad_range else 0), 0)
        symbols += struct.pack('<IBBHQQ', offsets[symbolnames[3]], 0, 0, 5, call + 8, 0)
    payloads = [b'', shstrings, strings, symbols, b'\xc0\x03\x5f\xd6', struct.pack('<Q', code + (4 if bad_pointer else 0)), struct.pack('<QQq', 0, (1 << 32) | 257, 4 if bad_reloc else 0)]
    data = bytearray(64)
    headers = []
    for i, payload in enumerate(payloads):
        data += b'\0' * ((-len(data)) % 8)
        offset = len(data)
        data += payload
        stype = [0, 3, 3, 2, 1, 1, 4][i]
        link = 2 if i == 3 else (3 if i == 6 else 0)
        info = 5 if i == 6 else (len(symbols)//24 if i == 3 else 0)
        flags = 6 if i == 4 else (3 if i == 5 else 0)
        addr = code if i == 4 else (call if i == 5 else 0)
        headers.append(struct.pack('<IIQQQQIIQQ', shoffsets[i], stype, flags, addr, offset, len(payload), link, info, 8, 24 if i in (3, 6) else 0))
    data += b'\0' * ((-len(data)) % 8)
    shoff = len(data)
    data += b''.join(headers)
    ident = b'\x7fELF\x02\x01\x01' + bytes(9)
    data[:64] = struct.pack('<16sHHIQQQIHHHHHH', ident, 2 if linked else 1, 183, 1, 0, 0, shoff, 0, 64, 0, 0, 64, len(headers), 1)
    path.write_bytes(data)


passes = []
def test(name, fn, fail=False):
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            fn()
    except RuntimeError:
        if not fail:
            raise
    else:
        if fail:
            raise AssertionError('Expected refusal: ' + name)
    passes.append(name)


test('reference-format-64-hex', r.validate_references)
original_reference = r.REFERENCES['drivers/spi/spi-wk2xxx.o']
r.REFERENCES['drivers/spi/spi-wk2xxx.o'] = original_reference[:-1]
test('reject-regression-63-character-reference', r.validate_references, True)
r.REFERENCES['drivers/spi/spi-wk2xxx.o'] = original_reference


def check_evidence():
    evidence = json.loads((script.parent / 'evidence.json').read_text())['sha256']
    expected = dict(r.REFERENCES)
    expected.update({r.INPUT: r.ORIGINAL, r.OUTPUT: r.CANDIDATE})
    assert evidence == expected


test('evidence-matches-script-references', check_evidence)
observed = {
    'drivers/spi/spi-wk2xxx.o': '8d9262d5c51603cc4c0bca2c1f90d889b540bfd0eb697ff38de4c9183598f0f3',
    'vmlinux': '7ffe906490388c65f99388c9ad9610457d7addc891b4e9e6150b68362ebfe3c5',
    'arch/arm64/boot/Image': 'd8a7551c14f1c47847c79bd71304a7d35f68a6e340734585febf90498aeb7679',
}


def check_report(hashes, full_match, image_match):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        matches = r.report_references(hashes)
    assert all(matches.values()) == full_match
    assert matches['arch/arm64/boot/Image'] == image_match
    assert ('test this Image on the board' in output.getvalue()) == (not image_match)
    assert ('IMAGE_REFERENCE_MATCH=YES' in output.getvalue()) == image_match


test('user-observed-artifact-set-passes', lambda: check_report(observed, True, True))
different_composite = dict(observed)
different_composite['drivers/spi/spi-wk2xxx.o'] = '0' * 64
test('composite-only-difference-does-not-demand-board-test', lambda: check_report(different_composite, False, True))
different_image = dict(observed)
different_image['arch/arm64/boot/Image'] = '0' * 64
test('changed-image-requires-board-validation', lambda: check_report(different_image, False, False))


with tempfile.TemporaryDirectory() as td:
    p = Path(td)
    for name, kwargs, method, reject in [
        ('valid-object', {}, 'check_object', False),
        ('reject-level6', {'level': 6}, 'check_object', True),
        ('reject-wrong-relocation', {'bad_reloc': True}, 'check_object', True),
        ('valid-linked-pointer', {'linked': True}, 'placement', False),
        ('reject-wrong-linked-pointer', {'linked': True, 'bad_pointer': True}, 'placement', True),
        ('reject-wrong-level7-range', {'linked': True, 'bad_range': True}, 'placement', True),
    ]:
        f = p / name
        fixture(f, **kwargs)
        test(name, lambda f=f, method=method: getattr(r.Elf(f), method)(), reject)
    kernel = p / 'kernel'
    (kernel / 'drivers/spi').mkdir(parents=True)
    base = b'# fixture\nspi-wk2xxx-objs                        := spi-wk2xxx\n# trailing\n'
    (kernel / r.MAKEFILE).write_bytes(base)
    (kernel / r.INPUT).write_bytes(b'test-only vendor input')
    for args in [ ['init', '-q'], ['add', '.'], ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'] ]:
        subprocess.check_call(['git'] + args, cwd=str(kernel))
    # Only this QA module's constants are replaced. Delivered source is unchanged.
    r.HEAD = r.run(['git', 'rev-parse', 'HEAD'], kernel).strip()
    r.ORIGINAL = r.digest(kernel / r.INPUT)
    fixture(kernel / r.OUTPUT)
    r.CANDIDATE = r.digest(kernel / r.OUTPUT)
    test('apply-original-rule', lambda: r.apply(kernel, None))
    state = {name: (kernel/name).read_bytes() for name in [r.INPUT, r.OUTPUT, r.MAKEFILE]}
    test('apply-idempotent', lambda: r.apply(kernel, None))
    assert all((kernel/name).read_bytes() == content for name, content in state.items())
    (kernel/r.MAKEFILE).write_bytes(state[r.MAKEFILE] + b'# unrelated change\n')
    test('preserve-unrelated-makefile-edit', lambda: r.apply(kernel, None), True)
    assert (kernel/r.MAKEFILE).read_bytes().endswith(b'# unrelated change\n')
    (kernel/r.MAKEFILE).write_bytes(state[r.MAKEFILE])
    (kernel/r.OUTPUT).write_bytes(b'wrong candidate')
    test('reject-existing-wrong-candidate', lambda: r.apply(kernel, None), True)
    assert (kernel/r.OUTPUT).read_bytes() == b'wrong candidate'
    (kernel/r.OUTPUT).write_bytes(state[r.OUTPUT])
    (kernel/r.INPUT).write_bytes(b'changed input')
    test('reject-vendor-input-change', lambda: r.apply(kernel, None), True)
    (kernel/r.INPUT).write_bytes(state[r.INPUT])
    r.HEAD = '0'*40
    test('reject-wrong-commit', lambda: r.apply(kernel, None), True)

print('\n'.join('PASS ' + name for name in passes))
print('TOTAL', len(passes))
