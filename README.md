# ZLMod — Tùy biến Native cho Zalo iOS

Dylib độc lập chất lượng cao dành cho các bản Zalo được hỗ trợ chính xác (`261002/261002802` và `261101/261101802`; bundle `vn.com.vng.zingalo` hoặc `vn.com.vng.zingalo2`, arm64, iOS 15.1+):
Tùy chỉnh giao diện, bảo vệ quyền riêng tư toàn cục & theo từng cuộc trò chuyện, chống thu hồi tin nhắn (Anti-Recall) mã hóa cục bộ với tính năng Hiện/Ẩn trực tiếp trong ô chat, tiện ích nhắn tin, chặn quảng cáo — tích hợp mượt mà theo phong cách native của iOS, mặc định tắt hoàn toàn khi mới cài đặt để bảo đảm an toàn tuyệt đối.

---

## 1. Thành phần kiến trúc (Build 9)

| Module | Chức năng & Vai trò |
|---|---|
| `ZLModCore` | Khởi tạo, cô lập từng module, ring-buffer + file log có lọc dữ liệu nhạy cảm (redaction), theo dõi phiên đăng nhập/đăng xuất. |
| `ZLModCompatibility` | Nhận diện phiên bản ứng dụng, kiểm tra exact build gate + xác minh tính toàn vẹn 84 anchors runtime. |
| `ZLModPreferences` | Quản lý cấu hình (suite `com.zlmod.preferences` + mirror App Group `group.zsettings.vn.com.vng.zingalo` + nút khôi phục mặc định). |
| `ZLModHookEngine` | Engine hook phương thức runtime (Objective-C runtime), kiểm tra nghiêm ngặt kiểu dữ liệu/arity/return type trước khi thay thế. |
| `ZLModCryptoStore` | Hộp lưu trữ mã hóa chuẩn quân đội AES-256-CBC + HMAC-SHA256 v2 bằng khóa trong iOS Keychain, định danh `accountScope` (fail-closed). |
| `ZLModPolicyStore` | Theo dõi ngữ cảnh chat đang mở + lưu chính sách Seen/Typing/Unread riêng biệt theo từng cuộc trò chuyện. |
| `ZLModURIFilter` | Chặn các endpoint thu thập dữ liệu phân tích / tracking / quảng cáo ngay trong tiến trình (`NSURLProtocol`). |
| `ZLModPrivacy` | Ẩn trạng thái đang nhập (typing), kiểm soát trạng thái đã xem (seen receipts) toàn cục & từng người, vô hiệu hóa Firebase Analytics. |
| `ZLModConversationMenu` | Menu ngữ cảnh khi nhấn giữ hội thoại (`InboxContextMenuManager` - phân nhóm Section an toàn, chống crash) + chấm xanh chưa đọc độc lập. |
| `ZLModAntiRecall` | Chống thu hồi tin nhắn: Lưu bản sao mã hóa cục bộ (14 ngày), nút **Hiện / Ẩn** trực tiếp ngay trong bong bóng chat, hỗ trợ ảnh chất lượng cao. |
| `ZLModUtilities` | Ghi chú riêng tư mã hóa theo từng người, mẫu câu trả lời nhanh (chỉ điền vào khung soạn thảo), hoãn gửi tin nhắn (Delay Send Undo FSM 1-10s). |
| `ZLModTheme` | Bộ theme màu (`classic_blue`, `dark_oled`, `pure_black`, `ocean_teal`) + màu nhấn `#HEX` tùy chỉnh, có lưu baseline khôi phục sạch. |
| `ZLModAds` | Vô hiệu hóa và ẩn hoàn toàn các thành phần quảng cáo feed, OA quảng cáo. |
| `ZLModFeatures` | Khôi phục Profile Music, Google Drive Backup, hiển thị More Tab. |
| `ZLModSettings` | Mục cấu hình "ZLMod Customize" lồng ghép chuẩn native vào Cài đặt Zalo (clone `BasicSettingCellV2Object`). |
| `ZLModUI` | Bảng điều khiển cài đặt trung tâm + 6 màn hình quản lý, nhật ký chẩn đoán chi tiết. |
| `ZLModGlass` | Hiệu ứng Liquid Glass cho Tab Bar (tương thích iOS 15 - iOS 18+, loại trừ treo giao diện do Watchdog). |

---

## 2. Tính năng nổi bật trong Build 9

### 👁️ Chống thu hồi tin nhắn (Anti-Recall) — Khôi phục trực tiếp trong ô chat (In-Place Toggle)
- Khi đối phương thu hồi tin nhắn, ZLMod đã tự động chụp snapshot và lưu bản sao mã hóa AES-256-CBC an toàn trong Keychain.
- **Bấm "Hiện" (icon con mắt 👁):**
  - Nhấn giữ vào ô *"Tin nhắn đã được thu hồi"*, menu ngữ cảnh sẽ xuất hiện nút **"Hiện"**.
  - Bấm **"Hiện"**, nội dung tin nhắn sẽ lập tức **hiển thị trực tiếp ngay bên trong bong bóng chat** thay cho dòng thông báo thu hồi, bong bóng tự động co giãn theo văn bản.
  - Đối với **Ảnh thu hồi**: Hiển thị nhãn phục hồi trong chat và tự động mở trình xem ảnh chất lượng cao cho phép phóng to, lưu về máy hoặc sao chép.
- **Bấm "Ẩn" (icon con mắt gạch 👁‍🗨):**
  - Sau khi đã hiện, nếu bạn nhấn giữ lại vào ô tin nhắn đó, nút sẽ đổi thành **"Ẩn"**. Bấm vào sẽ đưa ô chat trở lại trạng thái *"Tin nhắn đã được thu hồi"* như ban đầu.
- **Hoàn toàn không can thiệp SQLite database gốc** của Zalo — an toàn tuyệt đối, không gây hỏng dữ liệu.

### 🛡️ Menu ngữ cảnh hội thoại phân nhóm (Fix Crash triệt để)
- Nhấn giữ vào bất kỳ cuộc trò chuyện nào trong danh sách tin nhắn để mở menu tùy chỉnh riêng:
  1. **Bật/Tắt Ẩn đã xem với người này**
  2. **Bật/Tắt Ẩn đang soạn tin với người này**
  3. **Đánh dấu chưa đọc cục bộ (Chấm xanh `#0068FF`)**
  4. **Ghi chú riêng tư (Mã hóa Keychain)**
- **Khắc phục lỗi crash trong Build 8:** ZLMod Build 9 đóng gói các tùy chọn vào một Section độc lập chuẩn cấu trúc UIKit `NSArray<NSArray<ZAContextMenuAction *> *>`. Nhấn giữ mượt mà, phân nhóm ngăn nắp và không bị văng app.

### 🫧 Liquid Glass Tab Bar (Chống đơ / Chống treo Watchdog)
- Tối ưu hóa render phân luồng nền, giải quyết dứt điểm hiện tượng đơ app hoặc bị hệ thống ngắt tiến trình (`0x8BADF00D` Watchdog Timeout) khi bật hiệu ứng Liquid Glass.

---

## 3. Hướng dẫn cài đặt & Sideload

### Các bản IPA cung cấp sẵn trong thư mục `dist/`:
1. **Bản khuyến nghị:** `Zalo-26.10.02-ZLMod-build9-noappex-unsigned.ipa` (130 MB)
   - Đã loại bỏ toàn bộ App Extension (Share, Siri, Notification Service...) để chỉ cần **duy nhất 1 App ID**.
   - Phù hợp nhất cho **xtool**, **Sideloadly**, **AltStore** khi dùng tài khoản Apple ID miễn phí.
2. **Bản đầy đủ:** `Zalo-26.10.02-ZLMod-build9-unsigned.ipa` (140 MB)
   - Giữ nguyên toàn bộ extension, dành cho chứng chỉ Doanh nghiệp / Nhà phát triển trả phí hoặc cài qua **TrollStore**.

### Quy trình cài đặt chuẩn (Tránh lỗi "Không thể cài đặt app"):
1. **Xóa bản Zalo ZLMod cũ:** Nếu trên màn hình đã có bản ZLMod trước đó, hãy nhấn giữ và Xóa app trước khi cài bản mới để tránh xung đột chữ ký/container.
2. **Ký và nạp vào máy:**
   - Dùng **xtool** hoặc **Sideloadly** trên máy tính: Cắm cáp iPhone, kéo file `build9-noappex-unsigned.ipa` vào, nhập Apple ID và bấm Start.
   - Hoặc cài trực tiếp bằng **TrollStore** nếu máy hỗ trợ.
3. **Mở app và cấp quyền tin cậy:** Vào *Cài đặt iPhone → Cài đặt chung → Quản lý VPN & Thiết bị* để Tin cậy nhà phát triển.

---

## 4. Biên dịch & Kiểm thử

```bash
# Kiểm thử hợp đồng portable trên mọi hệ điều hành (Python 3):
python -m unittest discover -s Tests -p "test_*.py" -v
python Scripts/project_gate.py .

# Biên dịch dylib trên macOS (Xcode iphoneos SDK):
make
make gates    # Xác minh arm64, dependencies sạch, minos 15.1, UIGlassEffect runtime guard
```

---

## 5. Ranh giới an toàn kỹ thuật (Clean-Room Boundary)
ZLMod được thiết kế độc lập theo chuẩn công nghệ sạch (Clean-room engineering), không sử dụng Theos, Cydia Substrate, Substitute hay ElleKit. Các tính năng vi phạm chính sách máy chủ như vượt giới hạn dung lượng tải lên, gian lận quyền Admin nhóm, hoặc bẻ khóa ZCloud Premium cố ý không được triển khai vì do máy chủ Zalo quyết định (Server-authoritative).
