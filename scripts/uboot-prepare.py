#!/usr/bin/env python3
"""Apply a small, guarded board port to an archived upstream source tree."""
import difflib
from pathlib import Path
import re
import shutil
import sys


def prepare(source: Path, recipe: Path, report: Path):
    changes = []

    def change(relative, text):
        path = source / relative
        old = path.read_text() if path.exists() else ""
        changes.extend(difflib.unified_diff(
            old.splitlines(True), text.splitlines(True),
            fromfile=f"a/{relative}" if path.exists() else "/dev/null",
            tofile=f"b/{relative}",
        ))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    header = source / "arch/arm/include/asm/arch-rockchip/grf_rk3308.h"
    if not re.search(r"\bgpio4b_iomux\b", header.read_text()):
        raise RuntimeError("GRF layout changed: gpio4b_iomux is absent")
    pinctrl = (source / "drivers/pinctrl/rockchip/pinctrl-rk3308.c").read_text()
    bank = re.search(r'PIN_BANK_IOMUX_FLAGS\(\s*4,\s*32,\s*"gpio4",([^)]*)\)', pinctrl)
    if not bank:
        raise RuntimeError("Cannot verify the GPIO4 bank in the pinned pinctrl driver")
    flags = [value.strip() for value in bank.group(1).split(",")]
    if len(flags) != 4 or flags[1] not in {"IOMUX_8WIDTH_2BIT", "IOMUX_WIDTH_2BIT", "0"}:
        raise RuntimeError("GPIO4_B does not use the expected two-bit pinmux fields")
    for entry in re.findall(r"\{([^{}]*)\}", pinctrl, re.S):
        if re.search(r"\.(?:num|bank_num)\s*=\s*4\s*,", entry) and re.search(r"\.pin\s*=\s*(?:8|9)\s*,", entry):
            raise RuntimeError("GPIO4_PB0/PB1 has a pinctrl override; review early UART register writes")

    # Keep the original UART2 implementation byte-for-byte in the fallback.
    relative = "arch/arm/mach-rockchip/rk3308/rk3308.c"
    original = (source / relative).read_text()
    function = re.search(
        r"(?m)^__weak void board_debug_uart_init\(void\)\s*\{.*?^\}",
        original, re.S,
    )
    if not function:
        raise RuntimeError("Cannot find the pinned weak debug UART initializer")
    body = function.group()
    marker = "\t/* Enable early UART2 channel m1 on the rk3308 */"
    if body.count(marker) != 1 or "&grf->gpio4d_iomux" not in body:
        raise RuntimeError("UART initializer differs from the reviewed source")
    if "#if" in body:
        raise RuntimeError("UART initializer is already modified")
    replacement = body.replace(marker, (recipe / "uart4-init.cfrag").read_text() + marker)
    replacement = replacement[:-1] + "#endif\n}"
    change(relative, original[:function.start()] + replacement + original[function.end():])

    for name in ("rk3308-ihc3308gw.dts", "rk3308-ihc3308gw-u-boot.dtsi"):
        change(f"arch/arm/dts/{name}", (recipe / name).read_text())
    relative = "arch/arm/dts/Makefile"
    change(relative, (source / relative).read_text() +
           "\n# EPCB IHC-3308GW board port\n" +
           "dtb-$(CONFIG_ROCKCHIP_RK3308) += rk3308-ihc3308gw.dtb\n")

    base = (source / "configs/roc-cc-rk3308_defconfig").read_text().splitlines()
    fragment = (recipe / "ihc3308gw.fragment").read_text().splitlines()
    pattern = re.compile(r"^(?:# )?(CONFIG_[A-Z0-9_]+)(?:=| is not set)")
    keys = {m.group(1) for line in fragment if (m := pattern.match(line))}
    kept = [line for line in base
            if not ((m := pattern.match(line)) and m.group(1) in keys)]
    overrides = [line for line in fragment if pattern.match(line)]
    change("configs/ihc3308gw_defconfig", "\n".join(kept + overrides) + "\n")
    report.write_text("".join(changes))
    shutil.copy2(source / "configs/ihc3308gw_defconfig", report.parent / "ihc3308gw_defconfig")


if __name__ == "__main__":
    try:
        prepare(*(Path(p) for p in sys.argv[1:]))
    except (OSError, RuntimeError, TypeError) as error:
        sys.exit(f"prepare: {error}")
