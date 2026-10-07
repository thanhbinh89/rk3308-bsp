#!/usr/bin/env python3
"""G5: configure an isolated GPIO rootfs; no toolchain/rootfs build or staging."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone

BR_PIN = "d030e36bbc9669230c015be971b14b6e062cfdde"
BUILDER = "sha256:c77af91629b6c50b9abe5335c68355a26a9db8ba06138d0d87d648d1280960b7"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def capture(*args):
    return subprocess.check_output(args, text=True).strip()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def config(path):
    result = {}
    for line in path.read_text().splitlines():
        if line.startswith("BR2_") and "=" in line:
            key, value = line.split("=", 1)
            result[key] = value
        elif line.startswith("# BR2_") and line.endswith(" is not set"):
            result[line[2:-11]] = "n"
    return result


def patch_config(text, values):
    for key, value in values.items():
        pattern = rf"^(?:{re.escape(key)}=.*|# {re.escape(key)} is not set)$"
        text = re.sub(pattern + r"\n?", "", text, flags=re.MULTILINE)
        text += f"{key}={value}\n" if value != "n" else f"# {key} is not set\n"
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", default="out/buildroot-lab5-gpio-1")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    require(re.fullmatch(r"out/[A-Za-z0-9][A-Za-z0-9._-]*", args.output),
            "Output must be one directory directly below out/.")
    require(not any(c.isspace() for c in str(root)), "BSP path must not contain whitespace.")
    run = root / args.output
    require(not run.exists() and not run.is_symlink(), "Output exists; choose a new output name.")
    require(not (root / "out").is_symlink(), "out/ must not be a symlink.")
    for tool in ("git", "docker", "tar", "make"):
        require(shutil.which(tool), f"Missing host tool: {tool}")
    source = root / "buildroot"
    baseline = root / "out/docker-ihc3308/.config"
    external = root / "br2-external-rk3308"
    board_defconfig = external / "configs/ihc3308gw_defconfig"
    require(baseline.is_file() and board_defconfig.is_file(), "Missing baseline config/defconfig.")
    require(capture("git", "-C", str(source), "rev-parse", "HEAD") == BR_PIN,
            "Buildroot HEAD differs from the audited pin; inspect before configuring.")
    subprocess.run(["git", "-C", str(source), "diff", "--exit-code", "HEAD", "--"], check=True)
    require(capture("docker", "image", "inspect", "--format", "{{.Id}}", BUILDER) == BUILDER,
            "Pinned builder is unavailable.")
    before = config(baseline)
    require(before.get("BR2_DEFAULT_KERNEL_HEADERS") == '"4.4.143"', "Unexpected baseline headers.")
    require(before.get("BR2_TOOLCHAIN_BUILDROOT_MUSL") == "y", "Expected musl baseline.")
    require(before.get("BR2_HOST_DIR") == '"$(BASE_DIR)/host"', "Expected output-relative HOST_DIR.")
    require(config(board_defconfig).get("BR2_TARGET_GENERIC_GETTY_PORT") == '"ttyS4"',
            "Board defconfig must retain ttyS4.")
    for key in ("BR2_LINUX_KERNEL", "BR2_TARGET_UBOOT"):
        require(before.get(key, "n") == "n", f"{key} must remain disabled for this rootfs-only run.")

    run.mkdir(parents=True)
    for name in ("src", "build", "inputs", "artifacts"):
        (run / name).mkdir()
    inp = run / "inputs"
    shutil.copy2(baseline, inp / "baseline.config")
    shutil.copy2(board_defconfig, inp / "baseline.defconfig")
    shutil.copy2(__file__, inp / "buildroot-lab5-gpio-configure.py")
    # Dereference external-tree symlinks so the snapshot is self-contained.
    shutil.copytree(external, inp / "br2-external-rk3308", symlinks=False,
                    ignore=shutil.ignore_patterns(".git"))
    require((inp / "br2-external-rk3308/board/ihc3308gw/overlay").is_dir(),
            "Expected rootfs overlay missing from external snapshot.")
    with (run / "bsp-status.txt").open("w") as log:
        subprocess.run(["git", "-C", str(root), "status", "--short"], stdout=log, check=True)
    archive = subprocess.Popen(["git", "-C", str(source), "archive", BR_PIN], stdout=subprocess.PIPE)
    try:
        subprocess.run(["tar", "-xf", "-", "-C", str(run / "src")], stdin=archive.stdout, check=True)
    finally:
        archive.stdout.close()
    require(archive.wait() == 0, "git archive failed.")
    header_kconfig = (run / "src/package/linux-headers/Config.in.host").read_text()
    require(re.search(r"^config BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_12$", header_kconfig, re.M),
            "Pinned source lacks expected 6.12 custom-header option.")
    package = (run / "src/package/libgpiod/libgpiod.mk").read_text()
    require(re.search(r"^LIBGPIOD_VERSION\s*=\s*1\.6\.5\s*$", package, re.M),
            "Expected libgpiod 1.6.5 in pinned source.")
    options = {
        key: "n" for key in before
        if key.startswith("BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_")
    }
    options.update({
        "BR2_KERNEL_HEADERS_VERSION": "y",
        "BR2_DEFAULT_KERNEL_VERSION": '"6.12.111"',
        "BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_12": "y",
        "BR2_PACKAGE_LIBGPIOD": "y",
        "BR2_PACKAGE_LIBGPIOD_TOOLS": "y",
        "BR2_TARGET_GENERIC_GETTY_PORT": '"ttyS4"',
        "BR2_ROOTFS_OVERLAY": '"$(BR2_EXTERNAL_EPCB_RK3308_PATH)/board/ihc3308gw/overlay"',
        "BR2_JLEVEL": "4",
    })
    (inp / "gpio.seed.config").write_text(patch_config(baseline.read_text(), options))
    (inp / "SHA256SUMS").write_text("".join(
        f"{sha(p)}  {p.relative_to(inp).as_posix()}\n"
        for p in sorted(inp.rglob("*")) if p.is_file() and p != inp / "SHA256SUMS"
    ))
    container_run = f"/work/{args.output}"
    configure = '''
run=$1
make -C "$run/src" O="$run/build" \
    BR2_EXTERNAL="$run/inputs/br2-external-rk3308" \
    BR2_DEFCONFIG="$run/inputs/gpio.seed.config" defconfig
make -C "$run/src" O="$run/build" \
    BR2_EXTERNAL="$run/inputs/br2-external-rk3308" \
    BR2_DEFCONFIG="$run/artifacts/ihc3308gw_gpio_defconfig" savedefconfig
'''
    cmd = ["docker", "run", "--rm", "--pull", "never", "--network", "none",
           "--user", f"{os.getuid()}:{os.getgid()}",
           "--mount", f"type=bind,src={root},dst=/work,readonly",
           "--mount", f"type=bind,src={run},dst={container_run}",
           "--workdir", container_run, "--env", "LC_ALL=C", BUILDER,
           "bash", "-euc", configure, "g5", container_run]
    with (run / "configure.log").open("w") as log:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in proc.stdout:
            print(line, end="", flush=True)
            log.write(line)
        require(proc.wait() == 0, "Configuration failed; inspect configure.log.")
    after = config(run / "build/.config")
    changes = {key: {"before": before.get(key, "n"), "after": after.get(key, "n")}
               for key in sorted(before.keys() | after.keys())
               if before.get(key, "n") != after.get(key, "n")}
    (run / "config-vs-baseline.diff").write_text("".join(
        f"{key}: {value['before']} -> {value['after']}\n" for key, value in changes.items()))
    for key, expected in {
        "BR2_DEFAULT_KERNEL_HEADERS": '"6.12.111"',
        "BR2_TOOLCHAIN_HEADERS_AT_LEAST": '"6.12"',
        "BR2_PACKAGE_LIBGPIOD": "y", "BR2_PACKAGE_LIBGPIOD_TOOLS": "y",
        "BR2_TARGET_GENERIC_GETTY_PORT": '"ttyS4"',
        "BR2_ROOTFS_OVERLAY": '"$(BR2_EXTERNAL_EPCB_RK3308_PATH)/board/ihc3308gw/overlay"',
        "BR2_TARGET_ROOTFS_CPIO": "y", "BR2_TARGET_ROOTFS_CPIO_GZIP": "y",
        "BR2_HOST_DIR": '"$(BASE_DIR)/host"',
    }.items():
        require(after.get(key) == expected, f"Unexpected {key}: {after.get(key)}; inspect diff.")
    for key in ("BR2_GCC_VERSION", "BR2_BINUTILS_VERSION", "BR2_ARCH", "BR2_ENDIAN",
                "BR2_aarch64", "BR2_cortex_a35", "BR2_TOOLCHAIN_BUILDROOT_MUSL"):
        require(key in before and before[key] == after.get(key), f"Baseline mismatch: {key}.")
    for key in ("BR2_LINUX_KERNEL", "BR2_TARGET_UBOOT", "BR2_TOOLCHAIN_EXTERNAL"):
        require(after.get(key, "n") == "n", f"Unexpected enabled option: {key}.")
    shutil.copy2(run / "build/.config", run / "artifacts/buildroot.config")
    metadata = {
        "stage": "configured-not-built", "runtime": "not-tested",
        "diff_review": "pending", "created_utc": datetime.now(timezone.utc).isoformat(),
        "buildroot_commit": BR_PIN, "builder_image": BUILDER,
        "headers_version": "6.12.111", "libgpiod_version": "1.6.5", "gpio_abi": "v1",
        "gcc_version": after["BR2_GCC_VERSION"].strip('"'),
        "binutils_version": after["BR2_BINUTILS_VERSION"].strip('"'),
        "baseline_config_sha256": sha(inp / "baseline.config"),
        "config_sha256": sha(run / "build/.config"),
        "defconfig_sha256": sha(run / "artifacts/ihc3308gw_gpio_defconfig"),
        "inputs_checksums_sha256": sha(inp / "SHA256SUMS"),
        "changes": changes,
    }
    (run / "configuration.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print((run / "config-vs-baseline.diff").read_text(), end="")
    print(f"G5_CONFIG_PASS\nDIFF_REVIEW_PENDING\nOUTPUT={run}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
