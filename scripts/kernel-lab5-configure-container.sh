#!/usr/bin/env bash
# Runs only Kconfig generation. DTB/Image build and runtime are later checkpoints.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Expected run directory and source epoch.' >&2; exit 1; }
run=$1
source_epoch=$2
[[ $run =~ ^/work/out/[A-Za-z0-9][A-Za-z0-9._-]*$ && $source_epoch =~ ^[0-9]+$ ]] || { echo 'Invalid parameters.' >&2; exit 1; }
ksrc="$run/src"
kout="$run/build"
inputs="$run/inputs"
cross=/work/out/docker-ihc3308/host/bin/aarch64-buildroot-linux-musl-
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH="$source_epoch"
export KBUILD_BUILD_TIMESTAMP
KBUILD_BUILD_TIMESTAMP=$(date -u -d "@$source_epoch" '+%a %b %d %T %Z %Y')
export KBUILD_BUILD_USER=epcb KBUILD_BUILD_HOST=ihc3308gw KBUILD_BUILD_VERSION=1
unset KCONFIG_CONFIG KCONFIG_ALLCONFIG KCFLAGS KCPPFLAGS KBUILD_OUTPUT
(cd "$inputs" && sha256sum -c SHA256SUMS)
[[ $("${cross}gcc" -dumpmachine) == aarch64-buildroot-linux-musl ]]
[[ $("${cross}gcc" -dumpfullversion -dumpversion) == 13.4.0 ]]
{
    "${cross}gcc" --version
    "${cross}ld" --version
    printf 'KBUILD_BUILD_TIMESTAMP=%s\nKBUILD_BUILD_USER=%s\nKBUILD_BUILD_HOST=%s\nKBUILD_BUILD_VERSION=%s\nLOCALVERSION=<empty make override>\n' \
        "$KBUILD_BUILD_TIMESTAMP" "$KBUILD_BUILD_USER" "$KBUILD_BUILD_HOST" "$KBUILD_BUILD_VERSION"
} >> "$run/build-context.txt"
dpkg-query -W -f='${Package}\t${Version}\n' > "$run/builder-packages.tsv"
for label in gmac rmiim1_pins macm1_refclk_12ma mac_clkin; do
    grep -Eq "^[[:space:]]*$label:" "$ksrc/arch/arm64/boot/dts/rockchip/rk3308.dtsi" \
        || { printf 'Missing upstream label: %s\n' "$label" >&2; exit 1; }
done
test ! -e "$ksrc/arch/arm64/boot/dts/rockchip/rk3308-ihc3308gw.dts"
! grep -Fq 'rk3308-ihc3308gw.dtb' "$ksrc/arch/arm64/boot/dts/rockchip/Makefile"
cp "$ksrc/arch/arm64/boot/dts/rockchip/Makefile" "$inputs/rockchip.Makefile.upstream"
cp "$inputs/rk3308-ihc3308gw.dts" "$ksrc/arch/arm64/boot/dts/rockchip/"
printf '\ndtb-$(CONFIG_ARCH_ROCKCHIP) += rk3308-ihc3308gw.dtb\n' >> "$ksrc/arch/arm64/boot/dts/rockchip/Makefile"
python3 - "$inputs" "$ksrc" <<'PY'
import difflib, pathlib, sys
p, src = map(pathlib.Path, sys.argv[1:])
name = 'arch/arm64/boot/dts/rockchip/Makefile'
patch = ''.join(difflib.unified_diff(
    (p/'rockchip.Makefile.upstream').read_text().splitlines(keepends=True),
    (src/name).read_text().splitlines(keepends=True), fromfile='a/'+name, tofile='b/'+name))
name = 'arch/arm64/boot/dts/rockchip/rk3308-ihc3308gw.dts'
patch += ''.join(difflib.unified_diff([], (src/name).read_text().splitlines(keepends=True),
                                     fromfile='/dev/null', tofile='b/'+name))
(p/'board-port.patch').write_text(patch)
PY
(cd "$inputs" && sha256sum rockchip.Makefile.upstream board-port.patch >> SHA256SUMS)
kmake=(make -s -C "$ksrc" O="$kout" ARCH=arm64 CROSS_COMPILE="$cross" LOCALVERSION=)
# Preserve the complete validated baseline and apply only the Lab 5 overrides.
cp "$inputs/lab4.validated.config" "$kout/.config"
(cd "$kout" && "$ksrc/scripts/kconfig/merge_config.sh" -m -O "$kout" "$kout/.config" "$inputs/ihc3308gw.fragment")
"${kmake[@]}" olddefconfig
python3 "$ksrc/scripts/diffconfig" "$inputs/lab4.validated.config" "$kout/.config" > "$run/config-vs-lab4.diff"
printf '\nCONFIG_DIFF_BEGIN\n'
cat "$run/config-vs-lab4.diff"
printf 'CONFIG_DIFF_END\n\n'
python3 - "$run" <<'PY'
import hashlib, json, pathlib, re, sys
p = pathlib.Path(sys.argv[1])
def read_config(path):
    values = {}
    for line in path.read_text().splitlines():
        if line.startswith('CONFIG_') and '=' in line:
            key, value = line.split('=', 1)
            values[key] = value
        else:
            match = re.fullmatch(r'# (CONFIG_\w+) is not set', line)
            if match:
                values[match.group(1)] = 'n'
    return values
actual = read_config(p/'build/.config')
required = read_config(p/'inputs/ihc3308gw.fragment')
required.update({
    'CONFIG_PHYLIB': 'y',
    'CONFIG_REGULATOR': 'y',
    'CONFIG_REGULATOR_FIXED_VOLTAGE': 'y',
})
errors = [f'{k}: expected {v}, got {actual.get(k, "missing")}'
          for k, v in required.items() if actual.get(k) != v]
if errors:
    raise SystemExit('CONFIG_REQUEST_FAIL\n' + '\n'.join(errors))
before = read_config(p/'inputs/lab4.validated.config')
changes = {k: {'before': before.get(k), 'after': actual.get(k)}
           for k in sorted(before.keys() | actual.keys()) if before.get(k) != actual.get(k)}
hash_file = lambda name: hashlib.sha256((p/name).read_bytes()).hexdigest()
config_sha = hash_file('build/.config')
report = {
    'stage': 'configured-not-built', 'runtime': 'not-tested',
    'kernel_commit': 'e2acc2211022246c77740d5df08265cc27eedcc5',
    'bsp_baseline': 'cf4190d',
    'config_sha256': config_sha,
    'dts_sha256': hash_file('inputs/rk3308-ihc3308gw.dts'),
    'fragment_sha256': hash_file('inputs/ihc3308gw.fragment'),
    'changes': changes,
}
(p/'configuration.json').write_text(json.dumps(report, indent=2) + '\n')
print('CONFIG_REQUEST_PASS')
print(f'CONFIG_CHANGE_COUNT={len(changes)}')
print(f'LAB5_CONFIG_SHA256={config_sha}')
print(f'LAB5_DTS_SHA256={report["dts_sha256"]}')
print('NEXT=Review config-vs-lab4.diff before DTB/Image build.')
PY
(cd "$inputs" && sha256sum -c SHA256SUMS)
