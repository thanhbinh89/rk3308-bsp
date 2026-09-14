#!/usr/bin/env bash
# Invoked by bsp.sh inside the Docker builder.
set -euo pipefail
die() { printf 'builder: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" != 0 ]] || die 'Buildroot must run as the non-root builder user'
: "${BSP_OUT:?invoke scripts/bsp.sh from the host}"
: "${BSP_JOBS:?invoke scripts/bsp.sh from the host}"
: "${BSP_BUILDER_IMAGE_ID:?invoke scripts/bsp.sh from the host}"
[[ "$BSP_OUT" =~ ^out/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die 'invalid output path'
[[ "$BSP_JOBS" =~ ^[1-9][0-9]*$ ]] || die 'invalid job count'
bsp_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
bsp_output="$bsp_root/$BSP_OUT"
bsp_external="$bsp_root/br2-external-rk3308"
bsp_defconfig="$bsp_external/configs/ihc3308gw_defconfig"
bsp_command="${1:-build}"
cd "$bsp_root"
mkdir -p "$bsp_output/logs" "$bsp_root/dl" "$bsp_external/configs"
[[ -w "$bsp_output" && -w "$bsp_root/dl" ]] || die 'output/cache is not writable with the host UID/GID'
rg -q '^name:[[:space:]]+EPCB_RK3308[[:space:]]*$' "$bsp_external/external.desc" \
    || die 'external.desc must declare EPCB_RK3308 for this lab profile'

bsp_commit="$(git -C "$bsp_root/buildroot" rev-parse HEAD)"
bsp_context="$(printf 'image=%s\nsource=%s\noutput=%s\n' \
    "$BSP_BUILDER_IMAGE_ID" "$bsp_commit" "$bsp_output")"
if [[ -f "$bsp_output/build-context.txt" ]]; then
    [[ "$(cat "$bsp_output/build-context.txt")" == "$bsp_context" ]] \
        || die 'builder/source/path changed; select a fresh output, e.g. BSP_OUT=out/docker-ihc3308-v2'
elif [[ -f "$bsp_output/.config" || -d "$bsp_output/host" || -d "$bsp_output/build" ]]; then
    die 'output contains an earlier build without a Docker context; choose a new BSP_OUT'
else
    printf '%s\n' "$bsp_context" > "$bsp_output/build-context.txt"
fi

# Preserve the user's existing defconfig; this template is only the initial baseline.
if [[ ! -f "$bsp_defconfig" ]]; then
    cp "$bsp_root/docker/ihc3308gw_defconfig" "$bsp_defconfig"
fi
{
    printf 'builder_image_id=%s\n' "$BSP_BUILDER_IMAGE_ID"
    printf 'buildroot_commit=%s\n' "$bsp_commit"
    printf 'buildroot_version=%s\n' "$(cat "$bsp_root/buildroot.version")"
    printf 'jobs=%s\ncommand=%s\n' "$BSP_JOBS" "$bsp_command"
    printf 'host_libc=%s\n' "$(getconf GNU_LIBC_VERSION)"
} > "$bsp_output/build-environment.txt"
dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$bsp_output/builder-packages.txt"

br_make() {
    make -C "$bsp_root/buildroot" O="$bsp_output" \
        BR2_EXTERNAL="$bsp_external" BR2_DL_DIR="$bsp_root/dl" \
        BR2_DEFCONFIG="$bsp_defconfig" BR2_JLEVEL="$BSP_JOBS" "$@"
}
run_logged() {
    local step="$1"
    shift
    local log_name="${step}-$(date -u +%Y%m%dT%H%M%S-%N).log"
    ln -sfn "logs/$log_name" "$bsp_output/$step.log"
    "$@" 2>&1 | tee "$bsp_output/logs/$log_name"
}
verify_lab_config() {
    local expected
    for expected in \
        'BR2_aarch64=y' 'BR2_cortex_a35=y' \
        'BR2_TOOLCHAIN_BUILDROOT_MUSL=y' \
        'BR2_DEFAULT_KERNEL_HEADERS="4.4.143"' \
        'BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_4_4=y'; do
        rg -Fqx "$expected" "$bsp_output/.config" \
            || die "configuration differs from the Lab 2 baseline: $expected"
    done
}
load_config() {
    if [[ -f "$bsp_output/.config" ]]; then
        cp "$bsp_output/.config" "$bsp_output/config.before-defconfig"
    fi
    run_logged config br_make ihc3308gw_defconfig
    verify_lab_config
}
ensure_config() {
    if [[ ! -f "$bsp_output/.config" ]]; then load_config; fi
    verify_lab_config
}
check_artifacts() {
    local cc="$bsp_output/host/bin/aarch64-buildroot-linux-musl-gcc"
    local elf_reader="$bsp_output/host/bin/aarch64-buildroot-linux-musl-readelf"
    local busybox="$bsp_output/target/bin/busybox"
    local ext2="$bsp_output/images/rootfs.ext2"
    local cpio="$bsp_output/images/rootfs.cpio.gz"
    local triple elf_header program_headers
    [[ -x "$cc" && -x "$elf_reader" && -f "$busybox" && -f "$ext2" && -f "$cpio" ]] \
        || die 'expected artifacts are missing; finish the build first'
    triple="$("$cc" -dumpmachine)"
    [[ "$triple" == aarch64-buildroot-linux-musl ]] || die "unexpected compiler target: $triple"
    printf 'compiler_target=%s\n' "$triple"
    "$cc" -print-sysroot
    file "$busybox" "$ext2"
    elf_header="$("$elf_reader" -h "$busybox")"
    rg -q 'Machine:[[:space:]]+AArch64' <<< "$elf_header" || die 'BusyBox is not AArch64'
    program_headers="$("$elf_reader" -l "$busybox")"
    rg -F '/lib/ld-musl-aarch64.so.1' <<< "$program_headers" || die 'unexpected ELF interpreter'
    [[ "$(blkid -p -s TYPE -o value "$ext2")" == ext2 ]] || die 'rootfs is not ext2'
    [[ "$(stat -c %s "$ext2")" == 134217728 ]] || die 'rootfs.ext2 is not 128 MiB'
    gzip -t "$cpio"
    ls -lh "$cpio" "$ext2"
}

case "$bsp_command" in
    config) load_config ;;
    menuconfig) ensure_config; br_make menuconfig ;;
    savedefconfig) ensure_config; run_logged savedefconfig br_make savedefconfig ;;
    build) ensure_config; run_logged build br_make ;;
    source|sdk|legal-info) ensure_config; run_logged "$bsp_command" br_make "$bsp_command" ;;
    check) ensure_config; run_logged check check_artifacts ;;
    shell) exec /bin/bash ;;
    *) die "unsupported command: $bsp_command" ;;
esac
