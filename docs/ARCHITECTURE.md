# ZLMod — Kiến trúc Kỹ thuật (Build 9)

## 1. Sơ đồ kiến trúc tổng quan

```text
┌───────────────────────────────────────────────────────────────────────────────┐
│ ZLModCore (Constructor Hook Engine → DidFinishLaunching / Safe Fallback)       │
│   ├─ Session observers: AppDelegate -didLogout / -didLogin                     │
│   ├─ Redacted ring-buffer (200 lines) + rotating ZLMod.log (max 512 KB)       │
│   └─ Module status registry (HOOK_INSTALLED / NOT_INSTALLED)                  │
│                                                                               │
│  ZLModCryptoStore ───── Keychain AES-256-CBC + HMAC-SHA256 v2 + accountScope  │
│  ZLModPolicyStore ───── ZLModPrivacyContext + ZLModConversationPolicyStore    │
│  ZLModURIFilter ─────── NSURLProtocol (In-process tracking + ads → HTTP 204)  │
│  ZLModPrivacy ───────── Mach-O ABI-verified Seen / Typing / Firebase hooks    │
│  ZLModConversationMenu  InboxContextMenuManager (Sectioned Array Safe)        │
│  ZLModAntiRecall ────── In-Place Bubble Unhide/Hide + Encrypted Local Archive │
│  ZLModUtilities ─────── Private Notes, Quick Replies, Delay Send Undo FSM     │
│  ZLModTheme ─────────── Presets + Hex Tint with Baseline Capture & Restore    │
│  ZLModAds ───────────── Ad View Disarming & Network Interception              │
│  ZLModFeatures ──────── Profile Music / GDrive Backup Bridge / More Tab       │
│  ZLModSettings ──────── Cloned Native Cell + Navigation Interception          │
│  ZLModGlass ─────────── Liquid Glass Tab Bar Overlay (Anti-Freeze Guarded)    │
│  ZLModUI ────────────── Settings Dashboard + 6 Child Management Controllers   │
└───────────────────────────────────────────────────────────────────────────────┘
```

Một dylib duy nhất (`libZLMod.dylib`), **không framework phụ, không Theos, không Cydia Substrate, không ElleKit**.
Liên kết duy nhất với các framework chính chủ của hệ điều hành iOS: `UIKit`, `Foundation`, `QuartzCore`, `Security`.

---

## 2. Các nguyên tắc kỹ thuật cốt lõi

1. **Không dùng địa chỉ cố định, không selector đoán mò:**
   - Toàn bộ 84 ký hiệu runtime (`sel`, `cls`, `key`, `url`) được liệt kê trong `Scripts/anchors.txt` và được đối chiếu trực tiếp với bảng `__objc_methname`, `__objc_classname`, `__objc_classlist` trong binary Mach-O của Zalo `26.10.02` & `26.11.01`.
2. **Kiểm chứng kiểu dữ liệu & Arity trước khi hook:**
   - `ZLModReplaceMethod` (instance `-`) và `ZLModReplaceClassMethod` (metaclass `+`) kiểm tra nghiêm ngặt:
     `method_getNumberOfArguments(m) == declaredArgs + 2` và ký tự đầu của `method_getTypeEncoding(m)` thuộc tập hợp `allowedReturns`.
3. **Đọc thuộc tính an toàn ABI (Safe Property Readers):**
   - Các hàm `ZLModSafeObjectProperty`, `ZLModSafeStringProperty`, `ZLModSafeBoolProperty`, `ZLModSafeInt64Property` kiểm tra selector tồn tại, đúng 0 tham số tường minh (`numberOfArguments == 2`) và khớp kiểu trả về trước khi gọi `objc_msgSend`.
4. **Cách ly đa tài khoản (`accountScope`) & Cơ chế Fail-Closed:**
   - `ZLModCurrentAccountScope()` truy vấn `userId` từ các singleton đã xác minh (`ZAApplicationContext +sharedContext`, `ChatDataManager +sharedChatDataManager`), băm SHA-256 thành `acc_<16hex>`.
   - Khi chưa xác định được tài khoản (lúc khởi động hoặc chưa đăng nhập), mọi kho dữ liệu nhạy cảm tự động từ chối truy cập (fail-closed), không bao giờ dùng chung bộ nhớ toàn cục.
5. **Mã hóa cục bộ chuẩn quân đội Encrypt-then-MAC:**
   - Khóa chính 256-bit được sinh bằng `CCRandomGenerateBytes` và bảo vệ trong iOS Keychain với thuộc tính `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
   - Hai khóa con độc lập (`ENC` và `MAC`) được dẫn xuất qua SHA-256 để mã hóa `AES-256-CBC` và xác thực toàn vẹn `HMAC-SHA256` (so sánh hằng thời gian).

---

## 3. Các cải tiến kiến trúc đột phá từ Build 6 đến Build 9

### A. Cơ chế Sectioned Array trong `ZLModConversationMenu.m` (Build 9)
- **Vấn đề trên Zalo 26.10:**
  `InboxContextMenuManager -getActionsWithItem:` và `InboxContextMenuProvider contextMenuSectionsForItem:info:` trả về danh sách các section dạng mảng lồng nhau: `NSArray<NSArray<ZAContextMenuAction *> *>`. Nếu chèn phẳng các action vào mảng ngoài, UIKit duyệt qua và gọi `countByEnumeratingWithState:objects:count:` lên đối tượng action, gây crash tức thì với lỗi `unrecognized selector`.
- **Giải pháp trong Build 9:**
  - Kiểm tra `isSectioned = (origArray.count > 0 && [origArray.firstObject isKindOfClass:[NSArray class]])`.
  - Đóng gói 4 action tùy chỉnh vào một section độc lập (`NSArray<ZAContextMenuAction *> *`).
  - Chèn an toàn vào trước các thao tác nguy hiểm (Xóa, Chọn nhiều). Menu hiển thị phân nhóm đẹp mắt và hoàn toàn không crash.

### B. Cơ chế In-Place Toggle & Non-Mutating Dynamic Hook trong `ZLModAntiRecall.m` (Build 9)
- **Vấn đề cần giải quyết:** Người dùng muốn phục hồi tin nhắn thu hồi trực tiếp ngay trong bong bóng chat thay vì chỉ xem qua hộp thoại pop-up, và có thể ẩn lại khi cần.
- **Giải pháp trong Build 9:**
  - Bảng tra cứu luồng an toàn (Thread-safe Lookup Table) `ZLModUnhiddenKey` lưu trạng thái hiển thị của từng `globalId` / `clientId`.
  - Hook `MenuButton -showContextMenuViewWithMenuItemArray:hasReaction:`:
    - Nếu tin nhắn bị thu hồi và chưa hiện: Chèn nút **"Hiện"** (Action ID `99001`, icon `eye`).
    - Nếu tin nhắn đã được hiện: Chèn nút **"Ẩn"** (Action ID `99002`, icon `eye.slash`).
  - Khi bấm **"Hiện"**: Đánh dấu trạng thái unhidden, giải mã nội dung từ `ZLModCryptoStore`, cập nhật `UILabel` trực tiếp và gọi `[chat reloadCellIfNeed]` để kích hoạt layout engine của Zalo tính lại kích thước bong bóng. Đối với ảnh, mở thêm modal xem ảnh chất lượng cao.
  - Hook động trên `-[ChatEntity message]` và `-[ChatEntity _getRecalledMsgPreviewFromSource:]`: Khi tin nhắn đang ở trạng thái unhidden, phương thức trả về nội dung giải mã mà **tuyệt đối không sửa đổi SQLite database của Zalo**, bảo đảm nguyên vẹn 100% dữ liệu gốc.

### C. Ngăn chặn Deadlock / Watchdog Timeout trong `ZLModGlass.m` (Build 8)
- Thay thế các thao tác layout đồng bộ trên main thread bằng cấu trúc cập nhật nhẹ nhàng theo chu kỳ view lifecycle.
- Fallback an toàn sang `systemUltraThinMaterial` khi hệ điều hành chưa hỗ trợ `UIGlassEffect`, ngăn chặn triệt để mã lỗi `0x8BADF00D` (FrontBoard Watchdog 5.0s timeout).

---

## 4. Kiểm chứng chất lượng & CI Automation

```text
Kiểm thử cục bộ (Python 3):
  python -m unittest discover -s Tests -p "test_*.py" -v   (36/36 tests PASSED)
  python Scripts/project_gate.py .                        (Exit code 0)

Biên dịch & Đóng gói CI (GitHub Actions macos-26):
  - Biên dịch: make → libZLMod.dylib
  - Kiểm định cửa cổng: make gates → gates.sh
  - Đóng gói IPA: Packaging/package_ipa.py → Zalo-26.10.02-ZLMod-build9-noappex-unsigned.ipa
  - Kiểm tra chữ ký & Mach-O: Packaging/ipa_preflight.py
```
