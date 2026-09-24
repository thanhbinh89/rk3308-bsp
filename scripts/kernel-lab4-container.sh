#!/usr/bin/env bash
# Called by kernel-lab4.sh inside the pinned builder.
set -euo pipefail
[[ $# == 3 ]] || { echo 'Expected run directory, source epoch, jobs.' >&2; exit 1; }
run=$1
source_epoch=$2
jobs=$3
[[ $run =~ ^/work/out/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Invalid run directory.' >&2; exit 1; }
[[ $source_epoch =~ ^[0-9]+$ && $jobs =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid build parameters.' >&2; exit 1; }
ksrc="$run/src"
kout="$run/build"
inputs="$run/inputs"
artifacts="$run/artifacts"
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
# Apply only the two source changes reviewed at K14.
test ! -e "$ksrc/arch/arm64/boot/dts/rockchip/rk3308-ihc3308gw.dts"
! grep -Fq 'rk3308-ihc3308gw.dtb' "$ksrc/arch/arm64/boot/dts/rockchip/Makefile"
cp "$ksrc/arch/arm64/boot/dts/rockchip/Makefile" "$inputs/rockchip.Makefile.upstream"
cp "$inputs/rk3308-ihc3308gw.dts" "$ksrc/arch/arm64/boot/dts/rockchip/"
printf '\ndtb-$(CONFIG_ARCH_ROCKCHIP) += rk3308-ihc3308gw.dtb\n' >> "$ksrc/arch/arm64/boot/dts/rockchip/Makefile"
# Record the transformation as a reviewable patch; original Git worktree is untouched.
python3 - "$inputs" "$ksrc" <<'PY'
import difflib, pathlib, sys
inp, src = map(pathlib.Path, sys.argv[1:])
name = 'arch/arm64/boot/dts/rockchip/Makefile'
patch = ''.join(difflib.unified_diff(
    (inp/'rockchip.Makefile.upstream').read_text().splitlines(keepends=True),
    (src/name).read_text().splitlines(keepends=True), fromfile='a/'+name, tofile='b/'+name))
name = 'arch/arm64/boot/dts/rockchip/rk3308-ihc3308gw.dts'
patch += ''.join(difflib.unified_diff([], (src/name).read_text().splitlines(keepends=True),
                                     fromfile='/dev/null', tofile='b/'+name))
(inp/'board-port.patch').write_text(patch)
PY
(cd "$inputs" && sha256sum rockchip.Makefile.upstream board-port.patch >> SHA256SUMS)
kmake=(make -s -C "$ksrc" O="$kout" ARCH=arm64 CROSS_COMPILE="$cross" LOCALVERSION=)
"${kmake[@]}" defconfig
(cd "$kout" && "$ksrc/scripts/kconfig/merge_config.sh" -m -O "$kout" "$kout/.config" "$inputs/ihc3308gw.fragment")
"${kmake[@]}" olddefconfig
python3 "$ksrc/scripts/diffconfig" "$inputs/linux-6.12.111.validated.config" "$kout/.config" | tee "$run/config-replay.diff"
test ! -s "$run/config-replay.diff"
printf 'CONFIG_REPLAY_PASS\n'
# Synchronize generated configuration before querying the full release string.
"${kmake[@]}" -j"$jobs" prepare
"${kmake[@]}" kernelrelease | tee "$artifacts/kernel.release"
expected_release=6.12.111-epcb-ihc3308gw-lab4
actual_release=$(cat "$artifacts/kernel.release")
if [[ $actual_release != "$expected_release" ]]; then
    printf 'ERROR: kernelrelease expected %s; got %s\n' "$expected_release" "$actual_release" >&2
    exit 1
fi
printf 'KERNEL_RELEASE_PASS\n'
"${kmake[@]}" -j"$jobs" rockchip/rk3308-ihc3308gw.dtb
cp "$kout/arch/arm64/boot/dts/rockchip/rk3308-ihc3308gw.dtb" "$artifacts/ihc3308gw-emmc25.dtb"
(cd "$artifacts" && printf '%s  %s\n' aa0ee43c8184ae500763d3b345fb0b48b2d2ce720a5d77f44ac78b1217338a8f ihc3308gw-emmc25.dtb | sha256sum -c -)
printf 'DTB_BASELINE_PASS\n'
"${kmake[@]}" -j"$jobs" Image
cp "$kout/arch/arm64/boot/Image" "$artifacts/Image"
cp "$kout/.config" "$artifacts/linux.config"
"${kmake[@]}" kernelrelease > "$artifacts/kernel.release"
"$ksrc/scripts/extract-ikconfig" "$artifacts/Image" > "$artifacts/image.config"
python3 "$ksrc/scripts/diffconfig" "$inputs/linux-6.12.111.validated.config" "$artifacts/image.config" | tee "$run/embedded-config.diff"
test ! -s "$run/embedded-config.diff"
"$kout/scripts/dtc/dtc" -I dtb -O dts -o "$artifacts/ihc3308gw-expanded.dts" "$artifacts/ihc3308gw-emmc25.dtb" 2> "$run/dtc.log"
python3 "$inputs/kernel-lab4-check.py" "$artifacts"
(cd "$artifacts" && sha256sum Image ihc3308gw-emmc25.dtb linux.config image.config kernel.release ihc3308gw-expanded.dts manifest.json > SHA256SUMS)
(cd "$artifacts" && sha256sum -c SHA256SUMS)
printf 'EMBEDDED_CONFIG_PASS\n'
cat "$artifacts/manifest.json"
