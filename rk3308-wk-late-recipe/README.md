# RK3308 WK2xxx late-init — recipe thí nghiệm v1.1

Sửa lỗi của gói v1: hash composite bị thiếu ký tự `3` cuối, chỉ còn 63 ký tự,
làm bộ kiểm tra báo NO dù các artifact thật đều khớp. Bản 1.1 sửa mốc từ output
`sha256sum` trực tiếp của người dùng, kiểm định dạng SHA-256 trước khi chạy và
báo riêng từng artifact. Tên archive v1 được giữ để cập nhật gói đã phát hành.

## Mục đích và giới hạn

Tạo lại phép biến đổi đã thử trên Firefly IHC-3308GW: giữ nguyên object vendor
`drivers/spi/spi-wk2xxx`, tạo bản sao có `.initcall7.init` thay `.initcall6.init`,
và đổi một dòng trong Kbuild để dùng bản sao. Tên symbol
`__initcall_wk2xxx_init6` giữ nguyên là có chủ đích.

Đây là workaround của kernel vendor 4.4.143, không phải driver source mới,
port mainline hay giải thích nguyên nhân reset. Thứ tự late-init không tương
đương một khoảng delay cố định. Không đóng gói binary vendor trong bộ này.

## Chạy bước đầu trên Linux server

Yêu cầu: Python >=3.6, Git. Hai lệnh `check-*` không sửa source hoặc build output.
Giải nén bộ này bên trong `/home/epcb/workspace/rockchip/rk3308-bsp/`, rồi:

```bash
cd /home/epcb/workspace/rockchip/rk3308-bsp/rk3308-wk-late-recipe
python3 wk-late.py check-build
```

Kernel mặc định là:
`/home/epcb/workspace/rockchip/rk3308-src/rk3308_linux_release_v1.5.0a_20221212/kernel`.
Dùng `--kernel /duong/dan/kernel` nếu khác.

Mong đợi:

```text
SOURCE_PASS: ...
INITCALL_PLACEMENT_PASS ...
COMPOSITE_REFERENCE_MATCH=YES
VMLINUX_REFERENCE_MATCH=YES
IMAGE_REFERENCE_MATCH=YES
BOARD_TESTED_REFERENCE_MATCH=YES
IMAGE_SHA256=d8a7551c14f1c47847c79bd71304a7d35f68a6e340734585febf90498aeb7679
IMAGE_BYTES=12718088
```

`SOURCE_PASS` kiểm commit, hash input/candidate, một dòng Kbuild và relocation.
`INITCALL_PLACEMENT_PASS` kiểm cả khoảng level 7 và giá trị con trỏ trỏ đúng
`wk2xxx_init` trong vmlinux. Không dùng hậu tố `6` của tên symbol để suy level.
`BOARD_TESTED_REFERENCE_MATCH` vẫn là kết quả chung của ba file, để tương thích
gói v1. Các dòng `COMPOSITE_REFERENCE_MATCH`, `VMLINUX_REFERENCE_MATCH` và
`IMAGE_REFERENCE_MATCH` cho biết chính xác file nào khác; hash từng file cũng
được in. Nếu Image khớp binary đã thử, khác composite/vmlinux không tự tạo yêu
cầu rebuild hoặc thử lại Image đó. Nếu Image khác thì cần kiểm thử binary mới.
Việc kiểm vị trí trong vmlinux tự nó không chứng minh Image được sinh từ vmlinux đó.

## Tái tạo thay đổi trên SDK đúng commit

Thực hiện trong cùng môi trường Linux/container có toolchain và source SDK.
`--cross-prefix` là đường dẫn thực đến prefix Linaro, không phải compiler ARM64
khác đang có trong PATH. Không sao chép nguyên placeholder dưới đây.

```bash
python3 wk-late.py apply --kernel /duong/dan/kernel \
  --cross-prefix /duong/dan/linaro/bin/aarch64-linux-gnu-
```

- Commit kernel và hash object vendor phải khớp `evidence.json`.
- Binutils objcopy phải là 2.27; hash candidate sinh ra phải khớp trước khi sửa Makefile.
- Candidate đúng đã tồn tại: dùng lại, không cần tạo mới. Chạy apply lần hai là no-op.
- Makefile có sửa đổi khác ngoài đúng một dòng WK2xxx: dừng để review.
- File candidate khác hash: dừng, không ghi đè.
- Object gốc được giữ nguyên. Candidate được tạo từ input gốc, không từ composite `.o`.

## Build lại khi cần

Không cần build lại để thực hiện checkpoint hiện tại. Lệnh dưới đây dành cho lần
tái tạo sau, với `.config` đã chuẩn bị theo profile vendor và `CONFIG_SPI_WK2XXX=y`.
Recipe không tự tạo defconfig và không cố biến object built-in thành module.

```bash
python3 wk-late.py build --kernel /duong/dan/kernel \
  --cross-prefix /duong/dan/linaro/bin/aarch64-linux-gnu- \
  --checkpoint-dir /home/epcb/workspace/rockchip/rk3308-bsp/out/wk-late-checkpoints \
  --jobs 4
```

Lệnh này chạy trong cây kernel hiện tại. Dùng mặc định build in-tree; không đặt
`KBUILD_OUTPUT` hoặc `KCONFIG_CONFIG` sang cây khác. Dừng các build khác trên cùng cây.
Toolchain được kiểm là GCC 6.3.1, target aarch64-linux-gnu và linker 2.27.

Trước build, recipe sao lưu Image, vmlinux, composite, `.cmd`, `.config`, Makefile,
diff, trạng thái Git và phiên bản toolchain vào thư mục checkpoint mới. Cần dung
lượng cho các bản sao, riêng vmlinux đã khoảng 159 MB. Checkpoint là bản lưu các
đầu ra và cấu hình liên quan, không phải backup đầy đủ mọi file untracked trong SDK.

Sau khi sao lưu thành công, recipe xóa riêng composite build-cache
`drivers/spi/spi-wk2xxx.o`, rồi gọi top-level `make ... Image` để Kbuild đệ quy tạo
lại nó. Cách này tránh goal trung gian `.o` từng trả "Nothing to be done".
Đây là cách buộc rebuild được chọn cho recipe; khác cách gọi trực tiếp
`scripts/Makefile.build` đã dùng trong lab. Chưa chạy cách này trên SDK thực tại
môi trường của trợ lý; cần xem `build.log` và kết quả kiểm sau build tại server.

Build dùng `HOSTCFLAGS="-O2 -fcommon"`. Có `build.log`, `command.json` và
`result.json` khi thành công. Nếu lỗi, giữ checkpoint và log; recipe không tự
khôi phục đè lên output mới. Không chạy recipe đồng thời với một build khác.

Hash Image mới có thể khác do timestamp, build counter, config hoặc môi trường.
Recipe tái tạo phép biến đổi source/object; chưa cam kết kernel bit-for-bit
reproducible. Không coi khác hash là tự động lỗi, cũng không tự công nhận binary
mới đã được kiểm chứng. Trước phát hành cần pin đầy đủ config/build inputs và
kiểm thử artifact mới trên board.

## Bằng chứng board hiện có

Nguồn: nhật ký v39 và output người dùng trong phiên học 23/09/2026.

| Checkpoint | Kết quả đã cung cấp |
|---|---|
| H0 | TFTP đúng size/CRC, GPIO gốc, SPI0/WK okay |
| H1/H2 | Shell; WK init bắt đầu 2.333773 s, kết thúc 2.505687 s; bind wk2xxxspi |
| H3 | DT runtime power `<0x1a 0x8 0>`, reset `<0x1b 0x10 0>` |
| H4 | RS485_1/WK0 và RS485_2/WK1, chuỗi ngắn đúng cả hai chiều lần lượt, 9600 8N1 |
| H5 | Linux reboot về U-Boot; tải lại rồi boot; init bắt đầu 2.333739 s; bind thành công |
| H6 | Người dùng báo cold boot; init bắt đầu 2.332142 s; shell và bind thành công |
| H7a | Commit, diff một dòng và hash input/candidate/Image khớp |

UART được thử trong lượt H4, không mặc nhiên coi đã thử lại trong H5/H6.
Chưa kiểm WK2/WK3, tải dài, nhiều chu kỳ boot hoặc nguyên nhân điện/nguồn gốc.
Cảnh báo SPI0 DMA vẫn có trong lượt sống; CAN MCP251x timeout chưa xử lý.
DDR/BL31, kernel và object WK vẫn có phụ thuộc vendor.

Mốc Image đã thử: 12718088 byte, CRC32 `d8b97ae7`, TFTP
`/srv/tftp/rk3308/Image-wk-late`. Kernel cũ vẫn là `/srv/tftp/rk3308/Image`.
Recipe không chép TFTP, ghi eMMC, chạy saveenv hoặc tác động tới board.

## Kiểm tra bộ recipe

`VALIDATION.md` ghi rõ kiểm tra cục bộ và giới hạn. Chạy trên server để xác minh
các file thật bằng `check-build` trước. Khi đạt, có thể đưa các file recipe,
README và evidence vào Git của BSP riêng; candidate sinh tự động từ SDK input.
