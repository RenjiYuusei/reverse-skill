---
name: patch-delta-vng
description: "Tự động patch Delta Executor quốc tế sang bản VNG, đổi package, icon, và máy chủ mạng"
---

# Skill: Patch Delta to VNG

Skill này cung cấp công cụ tự động hóa toàn bộ quy trình chỉnh sửa file APK của Delta (quốc tế) để hoạt động như một bản cập nhật của Roblox VNG.

## Tính năng tự động
- Đổi Package Name (`com.roblox.client` -> `com.roblox.client.vnggames`)
- Đổi URL Scheme và Authorities để tránh xung đột
- Thay thế toàn bộ endpoint mạng (`www.roblox.com` -> `www.robloxapp.vnggames.com`)
- Trích xuất và copy Icon, Splits config từ APK VNG gốc
- Xử lý lỗi UTF-8 BOM
- Hỗ trợ ký APK chuẩn **V1 + V2 + V3** (nếu máy có cài sẵn Android SDK `apksigner`).
- Tự động tạo và sử dụng keystore độc quyền mang thương hiệu **Kasumi** để ký APK đầu ra.

## Hướng dẫn sử dụng (Giao diện dòng lệnh tự động)

Bạn không cần gõ lệnh thủ công nữa, chỉ cần:
1. Chép file APK của Delta (tên có chữ `Delta`) vào cùng thư mục `skills\patch-delta-vng\scripts\`.
2. Chép file APK của Roblox VNG gốc vào cùng thư mục đó.
3. Chạy (Double-click) file **`Auto-Patch-Kasumi.bat`**.

Script giao diện tự động sẽ tự nhận diện file APK, hiển thị thông báo tiến trình và tự động gọi bộ vá lỗi. Khi hoàn tất, bạn sẽ nhận được file `Delta-VNG-Auto.apk` dùng được ngay!

## Hướng dẫn sử dụng PowerShell thủ công (Nâng cao)

Nếu muốn chạy thủ công bằng lệnh, mở PowerShell:

```powershell
pwsh -File skills\patch-delta-vng\scripts\patch-delta-vng.ps1 -DeltaApk <path_to_delta.apk> -VngApk <path_to_vng.apk> -OutApk <output_path>
```

**Tham số:**
- `-DeltaApk`: (Bắt buộc) File APK của Delta quốc tế.
- `-VngApk`: (Bắt buộc) File APK của Roblox VNG gốc (để trích xuất icon).
- `-OutApk`: (Tùy chọn) Đường dẫn lưu APK đầu ra. Mặc định là `Delta-VNG-Patched.apk`.
