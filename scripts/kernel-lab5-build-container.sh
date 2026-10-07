#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 ]] || { echo 'Expected run directory, epoch, jobs.' >&2; exit 1; }
run=$1
source_epoch=$2
jobs=$3
[[ $run =~ ^/work/out/[A-Za-z0-9][A-Za-z0-9._-]*$ && $source_epoch =~ ^[0-9]+$ && $jobs =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid arguments.' >&2; exit 1; }
ksrc="$run/src"
kout="$run/build"
inputs="$run/e7c-inputs"
artifacts="$run/artifacts"
cross=/work/out/docker-ihc3308/host/bin/aarch64-buildroot-linux-musl-
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH="$source_epoch"
export KBUILD_BUILD_TIMESTAMP
KBUILD_BUILD_TIMESTAMP=$(date -u -d "@$source_epoch" '+%a %b %d %T %Z %Y')
export KBUILD_BUILD_USER=epcb KBUILD_BUILD_HOST=ihc3308gw KBUILD_BUILD_VERSION=1
unset KCONFIG_CONFIG KCONFIG_ALLCONFIG KCFLAGS KCPPFLAGS KBUILD_OUTPUT
(cd "$run/inputs" && sha256sum -c SHA256SUMS)
(cd "$inputs" && sha256sum -c SHA256SUMS)
python3 "$inputs/kernel-lab5-artifact-check.py" inputs "$run"
[[ $("${cross}gcc" -dumpmachine) == aarch64-buildroot-linux-musl ]]
[[ $("${cross}gcc" -dumpfullversion -dumpversion) == 13.4.0 ]]
{
    printf 'builder_image=sha256:c77af91629b6c50b9abe5335c68355a26a9db8ba06138d0d87d648d1280960b7\n'
    printf 'jobs=%s\nKBUILD_BUILD_TIMESTAMP=%s\nKBUILD_BUILD_USER=%s\nKBUILD_BUILD_HOST=%s\nKBUILD_BUILD_VERSION=%s\nLOCALVERSION=<empty make override>\n' \
        "$jobs" "$KBUILD_BUILD_TIMESTAMP" "$KBUILD_BUILD_USER" "$KBUILD_BUILD_HOST" "$KBUILD_BUILD_VERSION"
    "${cross}gcc" --version
    "${cross}ld" --version
} > "$run/lab5-build-context.txt"
dpkg-query -W -f='${Package}\t${Version}\n' > "$run/builder-packages-build.tsv"
kmake=(make -s -C "$ksrc" O="$kout" ARCH=arm64 CROSS_COMPILE="$cross" LOCALVERSION=)
"${kmake[@]}" -j"$jobs" prepare
python3 "$inputs/kernel-lab5-artifact-check.py" inputs "$run"
"${kmake[@]}" kernelrelease > "$artifacts/kernel.release"
[[ $(cat "$artifacts/kernel.release") == 6.12.111-epcb-ihc3308gw-lab5 ]] || { echo 'KERNEL_RELEASE_FAIL' >&2; exit 1; }
printf 'KERNEL_RELEASE_PASS\n'
"${kmake[@]}" -j"$jobs" rockchip/rk3308-ihc3308gw.dtb
cp "$kout/arch/arm64/boot/dts/rockchip/rk3308-ihc3308gw.dtb" "$artifacts/ihc3308gw-eth.dtb"
"$kout/scripts/dtc/dtc" -I dtb -O dts -o "$artifacts/ihc3308gw-expanded.dts" "$artifacts/ihc3308gw-eth.dtb" 2> "$run/dtc.log"
"${kmake[@]}" -j"$jobs" Image
python3 "$inputs/kernel-lab5-artifact-check.py" inputs "$run"
cp "$kout/arch/arm64/boot/Image" "$artifacts/Image"
cp "$kout/.config" "$artifacts/linux.config"
cp "$inputs/rootfs.cpio.gz" "$artifacts/rootfs.cpio.gz"
"$ksrc/scripts/extract-ikconfig" "$artifacts/Image" > "$artifacts/image.config"
python3 "$ksrc/scripts/diffconfig" "$kout/.config" "$artifacts/image.config" | tee "$run/embedded-config.diff"
test ! -s "$run/embedded-config.diff"
printf 'EMBEDDED_CONFIG_PASS\n'
python3 "$inputs/kernel-lab5-artifact-check.py" artifacts "$run"
(cd "$artifacts" && sha256sum Image ihc3308gw-eth.dtb rootfs.cpio.gz linux.config image.config kernel.release ihc3308gw-expanded.dts manifest.json > SHA256SUMS)
(cd "$artifacts" && sha256sum -c SHA256SUMS)
cat "$artifacts/manifest.json"
