# Linux 6.12.111 — baseline tối thiểu IHC-3308GW

Trạng thái: K16 build và K17 staging PASS; K18 đã tới shell với release/cmdline đúng; K19 kiểm CPU/RAM/rootfs và đọc eMMC đạt theo xác nhận người học. Raw output K19 và log byte/CRC tại U-Boot K18 chưa được gửi. Chi tiết bằng chứng và fingerprint nằm trong `board/ihc3308gw/linux/lab4-evidence.json`.

## Phạm vi đã kiểm

- Firefly IHC-3308GW / RK3308B, DDR 512 MiB, bank Linux 510 MiB.
- UART4 `ff0e0000`, console/getty `ttyS4`, 1500000 baud, 8N1; CPU online `0-3`.
- BusyBox init và rootfs RAM; eMMC High Speed giới hạn 25 MHz, bus 8-bit.
- Image tái tạo đã boot; đọc 16 MiB đầu eMMC khớp mốc tham chiếu. K19 dựa trên xác nhận người học, không có raw log để lưu kèm.

DDR init/BL31 vẫn dùng vendor. CPU_FREQ tắt; CPU_IDLE=y nhưng boot với `cpuidle.off=1`. HS200, ghi/mount rootfs eMMC, tải dài, peripheral port và phát hành distro thuộc các bước sau. Chưa kiểm hai lượt build cho Image giống từng byte.

## Linux server — đầu vào

| Đầu vào | Giá trị |
| --- | --- |
| Kernel source cache | `out/linux-6.12.111` chứa commit `e2acc2211022246c77740d5df08265cc27eedcc5` |
| Docker builder | `sha256:c77af91629b6c50b9abe5335c68355a26a9db8ba06138d0d87d648d1280960b7` |
| Toolchain | `out/docker-ihc3308/host/bin/aarch64-buildroot-linux-musl-`; GCC 13.4.0, binutils 2.43.1 |
| Cấu hình | ARM64 defconfig + `board/ihc3308gw/linux/ihc3308gw.fragment` |
| DTS board | `board/ihc3308gw/linux/rk3308-ihc3308gw.dts` |
| Config tham chiếu | `board/ihc3308gw/linux/linux-6.12.111.validated.config`, trích từ Image baseline và kiểm ở K15 |
| Recipe | `scripts/kernel-lab4.sh`, `kernel-lab4-container.sh`, `kernel-lab4-check.py` |

Toolchain và Docker image là dependency đã có trên server. Recipe này build Image/DTB; bootstrap toolchain, build rootfs và tích hợp toàn distro chưa nằm trong lệnh này. Chạy tại BSP bằng tài khoản có quyền dùng Docker; đường dẫn BSP không chứa khoảng trắng và `out/` là thư mục thật.

## Linux server — build và kiểm

Từ thư mục gốc BSP, chọn output mới chưa tồn tại:

```bash
(
set -eu
BSP_JOBS=4 ./scripts/kernel-lab4.sh build out/kernel-6.12.111-new
./scripts/kernel-lab4.sh check out/kernel-6.12.111-new
)
```

`BSP_JOBS` mặc định 4. Lượt đã đạt K16 dùng 20 jobs, output `out/kernel-6.12.111-replay-3/`. Kiểm lại lượt đó bằng:

```bash
./scripts/kernel-lab4.sh check out/kernel-6.12.111-replay-3
```

Recipe thực hiện các bước cần tái tạo:

1. `git archive` đúng commit sang source mới; snapshot DTS/fragment/config và script kèm checksum.
2. Tích hợp DTS và dòng đăng ký DTB, lưu `inputs/board-port.patch`.
3. Defconfig → merge fragment → olddefconfig; so cấu hình với bản đã trích từ Image baseline.
4. `make prepare` đồng bộ cấu hình/header sinh ra; kiểm full `kernelrelease`.
5. Build DTB, yêu cầu khớp hash baseline; build Image, trích lại config nhúng và kiểm header/vùng RAM.
6. Xuất manifest, SHA-256 và CRC32; truyền lỗi build về host qua `pipefail`.

Container chạy bằng UID/GID host, BSP mount chỉ đọc và chỉ output mới được ghi; network tắt. `.config` và `include/config/auto.conf` là hai lớp dữ liệu: kiểm diff `.config` chưa thay thế bước đồng bộ của Kbuild.

Release của lượt đã kiểm là `6.12.111-epcb-ihc3308gw-lab4`. Recipe cố định timestamp từ commit, build user/host/number và đặt `LOCALVERSION=`. Hash Image dưới đây định danh lượt K16; không được dùng riêng version string để suy ra file giống nhau. Đường dẫn/debug metadata và dependency vẫn cần đánh giá khi yêu cầu tái lập từng byte.

## U-Boot — payload và layout RAM

Thư mục TFTP đã kiểm trên Linux server: `/srv/tftp/rk3308/lab4-6.12.111-replay-3/`. Rootfs dùng lại từ `/srv/tftp/rk3308/lab4-6.12.111/rootfs.cpio.gz`.

| Payload | Địa chỉ nạp | Bytes / hex | CRC32 tham chiếu |
| --- | --- | --- | --- |
| `Image` | `0x02000000` | 38124032 / `0x245ba00` | `e92b1cac` |
| `ihc3308gw-emmc25.dtb` | `0x08000000` | 30984 / `0x7908` | `74da2f63` |
| `rootfs.cpio.gz` | `0x09000000` | 957091 / `0xe9aa3` | `c7440387` |

Image header: `text_offset=0`, `image_size=0x2530000`, vùng kernel kết thúc exclusive tại `0x04530000`. Ba SHA-256 đã kiểm sau staging:

```text
3bac04394e6cd0eef88b0c26865203d1bfc14231e7f2476f5bae55190b1b2284  Image
aa0ee43c8184ae500763d3b345fb0b48b2d2ce720a5d77f44ac78b1217338a8f  ihc3308gw-emmc25.dtb
7eb45684d0a3f879f92742950abdd6adf6c6dcbe54ba07d266a1d4c027b817c7  rootfs.cpio.gz
```

Server `192.168.1.19`, board `192.168.1.50/24`. Trong U-Boot đặt `autostart=no`, các biến địa chỉ theo bảng. Nạp CPIO → Image → DTB; xóa `filesize` trước mỗi transfer, lưu `initrd_size=${filesize}` ngay sau CPIO và đối chiếu byte/CRC. Dừng nếu transfer hoặc đối chiếu không đạt. Boot bằng:

```bash
setenv bootargs earlycon=uart8250,mmio32,0xff0e0000 console=ttyS4,1500000n8 rdinit=/init cpuidle.off=1 epcb_lab=linux612_replay ignore_loglevel initcall_debug panic=0
booti ${kernel_addr_r} ${ramdisk_addr_r}:${initrd_size} ${fdt_addr_r}
```

Phạm vi lab là boot RAM; không `saveenv` hoặc ghi kernel/rootfs thử vào eMMC. Log transfer/CRC K18 chưa có trong evidence; các CRC ở bảng là giá trị tham chiếu, không phải raw kết quả U-Boot đã nhận.

## Linux board — bằng chứng runtime

K18 đã gửi output `uname -r` đúng release ở trên và cmdline có `epcb_lab=linux612_replay`. K19 được xác nhận: PID1=`init`, `/` là rootfs RAM, CPU=`0-3`, System RAM `00200000–1fffffff`. Một lượt đọc trực tiếp 16 MiB đầu `/dev/mmcblk0` vào file RAM trả 0, đủ 16777216 byte và SHA-256:

```text
876fe5f72a64686aeff24d32a36d3c6ec8612d6641b3d6269e24493f58ac8053
```

Hash này là mốc nội dung eMMC sau khi thay U-Boot, không phải hash backup trước đó. Phép đọc không chứng minh toàn dung lượng, stress hoặc toàn bộ boot log sạch lỗi.

## Lưu baseline

Git giữ ba script, DTS/fragment/config tham chiếu, tài liệu này, evidence JSON và đổi getty Buildroot sang `ttyS4`. Giữ artifact lớn riêng cùng checksum.

Trong output đã đạt, giữ `inputs/`, `build-context.txt`, `builder-packages.tsv`, `build.log`, `build/.config`, `build/vmlinux`, `artifacts/manifest.json`, `artifacts/SHA256SUMS` và các payload. Manifest build K16 giữ trạng thái runtime tại thời điểm build; evidence JSON ghi bổ sung kết quả K18/K19 và nguồn xác nhận.
