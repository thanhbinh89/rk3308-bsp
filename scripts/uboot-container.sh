#!/usr/bin/env bash
set -euo pipefail
action="$1"
out="/work/$2"
jobs="$3"
src="$out/source"
obj="$out/build"
recipe=/work/board/ihc3308gw/uboot
firmware=/work/firmware/rk3308
cross=aarch64-linux-gnu-

if [[ "$action" == build ]]; then
    if [[ ! -e "$src" ]]; then
        stage="$(mktemp -d "$out/source-stage.XXXXXX")"
        git -C /work/u-boot archive "$(cat "$recipe/upstream.commit")" | tar -x -C "$stage"
        python3 /work/scripts/uboot-prepare.py "$stage" "$recipe" "$out/board-port.patch"
        mv "$stage" "$src"
    fi
    mkdir -p "$obj"
    cp /opt/uboot-builder-packages.txt "$out/builder-packages.txt"
    "${cross}gcc" --version > "$out/compiler-version.txt"
    if [[ ! -e "$obj/.config" ]]; then
        make -C "$src" O="$obj" CROSS_COMPILE="$cross" ihc3308gw_defconfig
    fi
    python3 /work/scripts/uboot-check.py config "$obj"
    make -C "$src" O="$obj" CROSS_COMPILE="$cross" -j"$jobs" \
        BL31="$firmware/rk3308_bl31_v2.24.elf" \
        ROCKCHIP_TPL="$firmware/rk3308_ddr_589MHz_uart4_m0_v2.06.bin"
    make -C "$src" O="$obj" CROSS_COMPILE="$cross" savedefconfig
    cp "$obj/.config" "$out/resolved.config"
    cp "$obj/defconfig" "$out/resolved.defconfig"
fi
python3 /work/scripts/uboot-check.py artifacts "$obj"
(
    cd "$obj"
    sha256sum u-boot u-boot.dtb spl/u-boot-spl.dtb spl/u-boot-spl.bin \
        u-boot.itb u-boot-rockchip.bin > "$out/artifacts.sha256"
)
cat "$out/build-context.txt" "$out/compiler-version.txt"
cat "$out/artifacts.sha256"
