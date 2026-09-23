# Kiểm tra recipe v1.1

Sau output H7b trên SDK thực: SOURCE_PASS và INITCALL_PLACEMENT_PASS đã được
người dùng xác nhận. Image và vmlinux khớp mốc. Hash composite thật do người
dùng đọc lại có 64 ký tự, kết thúc bằng `f0f3`; mốc v1 thiếu ký tự cuối.

Bản 1.1 sửa lỗi dữ liệu tham chiếu, không cần đổi kernel. Đã thêm 6 ca regression:
định dạng 64 hex; từ chối mốc 63 ký tự; evidence khớp constants; bộ hash người
dùng cung cấp trả YES; khác riêng composite không đòi thử board; khác Image
yêu cầu kiểm chứng binary mới. Cộng 12 ca bên dưới: 18 ca PASS.

Đã kiểm tra tại môi trường tạo gói:

- Cú pháp Python tương thích 3.6; JSON evidence hợp lệ.
- 12 ca kiểm tra với ELF64 AArch64 tổng hợp và Git repository fixture:
  valid object; từ chối section level 6; từ chối relocation sai;
  final pointer đúng; từ chối final pointer sai; từ chối khoảng level 7 sai;
  áp dụng lên Makefile gốc; chạy lặp không đổi file; giữ sửa đổi Makefile ngoài phạm vi;
  từ chối candidate sai hash; từ chối vendor input sai hash; từ chối commit khác.
- Đối chiếu các fingerprint đóng gói với dữ liệu người dùng đã cung cấp.

Các fixture chỉ kiểm logic parser và các điều kiện bảo vệ. Test dùng fingerprint
riêng trong bộ nhớ; không sửa constants của script phát hành.

Chưa có binary vendor hoặc checkout SDK thật tại môi trường của trợ lý để chạy
objcopy Linaro, full kernel build hay check-build trực tiếp trên vmlinux thật.
Kết quả check-build v1 trên SDK thực là log do người dùng cung cấp, như ghi trên.
Build mode cần được xác minh tại server khi thực sự tái tạo kernel.
Không đồng nhất kiểm thử recipe với kết quả phần cứng người dùng đã cung cấp.

Có thể chạy lại fixture bằng:

```bash
python3 tests/test_recipe.py
```

Checkpoint kế tiếp được giao cho người dùng là lệnh read-only:

```bash
python3 wk-late.py check-build
```
