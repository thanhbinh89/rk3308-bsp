#!/usr/bin/env python3
"""Fail if Kconfig drops required options or if the compiled UART DT is wrong."""
from pathlib import Path
import re
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def config(obj):
    text = (obj / ".config").read_text()
    values = dict(re.findall(r"^(CONFIG_\w+)=(.*)$", text, re.M))
    expected = {
        "ARM64": "y", "ROCKCHIP_RK3308": "y", "TARGET_ROC_RK3308_CC": "y",
        "DEFAULT_DEVICE_TREE": '"rk3308-ihc3308gw"', "DEBUG_UART": "y",
        "DEBUG_UART_BOARD_INIT": "y", "DEBUG_UART_CLOCK": "24000000",
        "DEBUG_UART_SHIFT": "2", "BAUDRATE": "1500000", "SPL": "y",
        "SPL_ATF": "y", "SPL_LOAD_FIT": "y", "ROCKCHIP_EXTERNAL_TPL": "y",
        "CMD_BDI": "y", "CMD_BOOTI": "y", "CMD_FDT": "y",
        "CMD_TFTPBOOT": "y", "CMD_PING": "y", "BOOTDELAY": "-1",
    }
    for key, wanted in expected.items():
        if values.get("CONFIG_" + key) != wanted:
            raise RuntimeError(f"CONFIG_{key}: expected {wanted}, got {values.get('CONFIG_' + key)}")
    if values.get("CONFIG_OF_UPSTREAM") == "y":
        raise RuntimeError("OF_UPSTREAM is still enabled; the custom arch/arm/dts tree was not selected")
    if int(values.get("CONFIG_DEBUG_UART_BASE", "0"), 0) != 0xff0e0000:
        raise RuntimeError("DEBUG_UART_BASE is not UART4")
    print("config: ARM64, SPL/FIT, external DDR and UART4 settings verified")


def dt_get(dtb, node, prop, kind="s"):
    return run("fdtget", "-t", kind, str(dtb), node, prop)


def properties(dtb, node):
    return run("fdtget", "-p", str(dtb), node).splitlines()


def nodes(dtb, node="/"):
    yield node
    for child in run("fdtget", "-l", str(dtb), node).splitlines():
        yield from nodes(dtb, node.rstrip("/") + "/" + child)


def check_dt(dtb, check_phase_tags=True):
    stdout = dt_get(dtb, "/chosen", "stdout-path")
    if stdout != "serial4:1500000n8":
        raise RuntimeError(f"{dtb.name}: wrong stdout-path: {stdout}")
    uart = dt_get(dtb, "/aliases", "serial4")
    if not uart.endswith("serial@ff0e0000") or dt_get(dtb, uart, "status") != "okay":
        raise RuntimeError(f"{dtb.name}: UART4 alias or status is wrong")
    if "uart-has-rtscts" in properties(dtb, uart):
        raise RuntimeError(f"{dtb.name}: RTS/CTS must not be selected")
    handles = dt_get(dtb, uart, "pinctrl-0", "x").split()
    if len(handles) != 1:
        raise RuntimeError(f"{dtb.name}: expected exactly one TX/RX pin group")
    wanted = int(handles[0], 16)
    group = None
    for node in nodes(dtb):
        if "phandle" in properties(dtb, node):
            if int(dt_get(dtb, node, "phandle", "x"), 16) == wanted:
                group = node
                break
    if not group:
        raise RuntimeError(f"{dtb.name}: pinctrl phandle is unresolved")
    cells = [int(word, 16) for word in dt_get(dtb, group, "rockchip,pins", "x").split()]
    # Each Rockchip pin entry has bank, pin number, mux, and configuration phandle.
    if len(cells) != 8 or {tuple(cells[i:i + 3]) for i in (0, 4)} != {(4, 8, 1), (4, 9, 1)}:
        raise RuntimeError(f"{dtb.name}: UART4 must use only GPIO4_PB0/PB1 mux1; got {cells}")
    # fdtgrep may remove bootph tags from the filtered SPL tree after using them.
    if check_phase_tags and ("bootph-all" not in properties(dtb, uart) or "bootph-all" not in properties(dtb, group)):
        raise RuntimeError(f"{dtb.name}: UART4 boot phase properties missing")
    print(f"{dtb.name}: {stdout}, {group}, TX/RX only")


def artifacts(obj):
    config(obj)
    for name in ("u-boot", "u-boot.dtb", "spl/u-boot-spl.dtb", "spl/u-boot-spl.bin",
                 "u-boot.itb", "u-boot-rockchip.bin"):
        path = obj / name
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"missing or empty artifact: {path}")
        print(f"artifact: {name} {path.stat().st_size} bytes")
    elf = run("aarch64-linux-gnu-readelf", "-h", str(obj / "u-boot"))
    if "AArch64" not in elf:
        raise RuntimeError("u-boot ELF is not AArch64")
    check_dt(obj / "u-boot.dtb")
    check_dt(obj / "spl/u-boot-spl.dtb", check_phase_tags=False)
    print(run(str(obj / "tools/dumpimage"), "-l", str(obj / "u-boot.itb")))
    print("CHECK PASS: build artifacts inspected; hardware boot is still pending")


if __name__ == "__main__":
    try:
        {"config": config, "artifacts": artifacts}[sys.argv[1]](Path(sys.argv[2]))
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"check: {error}")
