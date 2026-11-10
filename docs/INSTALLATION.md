# ZLMod — Hướng dẫn cài đặt & Khắc phục sự cố

Tài liệu này cung cấp hướng dẫn từng bước để cài đặt Zalo ZLMod lên iPhone (iOS 15.1 - iOS 18+) và các bước xử lý triệt để khi gặp sự cố trong quá trình cài đặt.

---

## 1. Phân biệt các bản IPA trong thư mục `dist/`

Trong thư mục `dist/`, ZLMod cung cấp 2 bản IPA đã được giải mã và tiêm `libZLMod.dylib`:

| Tên file IPA | Dung lượng | Mục đích & Công cụ khuyên dùng |
|---|---|---|
| **`Zalo-26.10.02-ZLMod-build9-noappex-unsigned.ipa`** *(Khuyên dùng)* | ~130 MB | **Dành cho Apple ID miễn phí qua xtool / Sideloadly / AltStore / Scarlet / Esign / TrollStore**.<br>Bản này đã gỡ bỏ toàn bộ 5 App Extension (Share, Siri, Notification, Widget...) để giảm số lượng App ID xuống còn **1 App ID duy nhất**, giúp tài khoản Apple ID miễn phí không bao giờ bị lỗi vượt hạn mức (App ID Limit Exceeded). |
| **`Zalo-26.10.02-ZLMod-build9-unsigned.ipa`** | ~140 MB | **Dành cho TrollStore hoặc tài khoản Apple Developer trả phí**.<br>Bản này giữ nguyên toàn bộ 5 App Extension gốc. Không khuyên dùng cho tài khoản cá nhân miễn phí. |

---

## 2. Hướng dẫn cài đặt qua từng công cụ

### Cách 1: Sử dụng `xtool` hoặc `Sideloadly` trên máy tính Windows / macOS (Khuyên dùng nhất)
1. **Chuẩn bị:**
   - Kết nối iPhone với máy tính bằng cáp Lightning / Type-C.
   - Mở iTunes / Apple Devices để đảm bảo máy tính đã nhận diện được iPhone ("Tin cậy máy tính này").
2. **Thực hiện:**
   - Mở `xtool` hoặc `Sideloadly`.
   - Chọn thiết bị iPhone của bạn.
   - Kéo file `Zalo-26.10.02-ZLMod-build9-noappex-unsigned.ipa` vào khung cài đặt.
   - Nhập thông tin Apple ID cá nhân để ký ứng dụng.
   - Bấm **Start** / **Cài đặt** và chờ tiến trình hoàn tất 100%.
3. **Cấp quyền tin cậy trên iPhone:**
   - Vào *Cài đặt (Settings) → Cài đặt chung (General) → Quản lý VPN & Thiết bị (VPN & Device Management)*.
   - Nhấn vào email Apple ID của bạn và chọn **Tin cậy (Trust)**.

---

### Cách 2: Cài đặt trực tiếp qua `TrollStore` (Dành cho máy đã cài TrollStore)
1. Mở Safari trên iPhone, truy cập vào link tải IPA trực tiếp từ GitHub Releases:
   `https://github.com/leduwn/zalo-mod-ios/releases/download/build-9/Zalo-26.10.02-ZLMod-build9-noappex-unsigned.ipa`
2. Sau khi tải xong, chọn chia sẻ (Share) và mở bằng **TrollStore**.
3. TrollStore sẽ cài đặt tức thì mà không cần ký lại và không bao giờ hết hạn 7 ngày.

---

### Cách 3: Cài qua `Scarlet` / `Esign` / `GBox` trên điện thoại
1. Mở ứng dụng Scarlet hoặc Esign trên iPhone.
2. Nạp file IPA `build9-noappex` vào danh sách ứng dụng.
3. Nhấn **Ký ứng dụng (Sign)** và chọn **Cài đặt (Install)**.

---

## 3. Khắc phục sự cố thường gặp (Troubleshooting)

### ❌ Lỗi "Không thể cài đặt app" / "Unable to Install App"
Đây là thông báo của hệ điều hành iOS khi tiến trình cài đặt bị chặn. Các nguyên nhân và cách xử lý:

1. **Xung đột với bản Zalo ZLMod cũ đang có trên máy:**
   - *Nguyên nhân:* Trên máy đã có sẵn bản Zalo ZLMod (Build 7 hoặc Build 8) mang cùng Bundle ID `vn.com.vng.zingalo2`. Khi cài bản mới mà Profile ký bị lệch, iOS sẽ chặn ghi đè.
   - *Cách xử lý:* **Xóa bản Zalo ZLMod cũ trên màn hình chính** → Khởi động lại iPhone → Cài đặt lại bản mới.

2. **Tải nhầm file dylib / zip trên GitHub:**
   - *Nguyên nhân:* Trước đó trên GitHub Releases chỉ có file `ZLMod-build-9.zip` (163 KB). File này không phải là ứng dụng hoàn chỉnh.
   - *Cách xử lý:* Tải đúng file `.ipa` có dung lượng ~130 MB từ link release chính thức.

3. **Vượt quá hạn mức App ID của Apple (Tài khoản Apple ID miễn phí):**
   - *Nguyên nhân:* Apple giới hạn mỗi Apple ID miễn phí chỉ được tạo tối đa 10 App ID trong 7 ngày và kích hoạt tối đa 3 ứng dụng sideload cùng lúc.
   - *Cách xử lý:* Luôn dùng bản **`noappex`**, đồng thời xóa bớt các ứng dụng sideload không dùng trên iPhone.

4. **Chứng chỉ doanh nghiệp bị Apple thu hồi (Revoke):**
   - *Nguyên nhân:* Các chứng chỉ miễn phí dùng trong Scarlet / Esign (như Sunshine, Victoria, HDFC...) rất nhanh bị Apple quét thu hồi.
   - *Cách xử lý:* Chuyển sang dùng `xtool` hoặc `Sideloadly` trên máy tính để tự ký bằng Apple ID cá nhân.
