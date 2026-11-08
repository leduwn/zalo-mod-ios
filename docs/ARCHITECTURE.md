# ZLMod — Kiến trúc (Build 5)

## 1. Tổng quan

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ ZLModCore (constructor → DidFinishLaunching / late-window fallback)      │
│   ├─ Session observers: AppDelegate -didLogout/-didLogin,                │
│   │                     kNotifyDidLogoutAnimation → AccountDidChange     │
│   ├─ Redacted ring-buffer (200 lines) + rotating ZLMod.log (max 512 KB)  │
│   └─ Module status registry (HOOK_INSTALLED / NOT_INSTALLED)             │
│                                                                          │
│  ZLModCryptoStore ── Keychain AES-256-CBC + HMAC-SHA256 + accountScope   │
│  ZLModPolicyStore ── ZLModPrivacyContext + ZLModConversationPolicyStore  │
│  ZLModURIFilter ──── NSURLProtocol (in-process tracking + ads → 204)     │
│  ZLModPrivacy ────── Mach-O ABI-verified Seen / Typing / Firebase hooks  │
│  ZLModConversationMenu ─ InboxContextMenuManager + cell blue-dot badge   │
│  ZLModAntiRecall ─── Encrypted local Ghost Preview (14d TTL, non-DB)     │
│  ZLModUtilities ──── Private Notes, Quick Replies, Delay Send Undo FSM   │
│  ZLModTheme ──────── Optional presets + hex tint with baseline restore   │
│  ZLModAds ────────── Ad view class disarming                             │
│  ZLModFeatures ───── Profile Music / GDrive bridge / More Tab            │
│  ZLModSettings ───── Cloned native cell + navigation interception        │
│  ZLModGlass ──────── Tab bar material overlay (REAL_GLASS / BLUR)        │
│  ZLModUI ─────────── Grouped settings dashboard + 6 child controllers    │
└──────────────────────────────────────────────────────────────────────────┘
```

Một dylib duy nhất (`libZLMod.dylib`), không framework phụ, không Theos,
không Substrate/ElleKit. Link duy nhất các system frameworks: `UIKit`,
`Foundation`, `QuartzCore`, `Security`.

## 2. Nguyên tắc ABI & Fail-Closed

1. **Không địa chỉ cứng, không selector đoán mò.** Toàn bộ 84 ký hiệu runtime
   (`sel`, `cls`, `key`, `url`) nằm trong `Scripts/anchors.txt` và đã được đối
   chiếu trực tiếp với bảng `__objc_methname`, `__objc_classname`, `__objc_classlist`
   của binary `Zalo` Mach-O.
2. **Kiểm chứng chữ ký trước khi hook.** `ZLModReplaceMethod` (instance `-`) và
   `ZLModReplaceClassMethod` (metaclass `+`) kiểm tra nghiêm ngặt
   `method_getNumberOfArguments(m) == declaredArgs + 2` và ký tự đầu của
   `method_getTypeEncoding(m)` thuộc `allowedReturns`.
3. **Đọc thuộc tính an toàn ABI.** Các hàm `ZLModSafeObjectProperty`,
   `ZLModSafeStringProperty`, `ZLModSafeBoolProperty`, `ZLModSafeInt64Property`,
   `ZLModSafeDoubleProperty` kiểm tra selector tồn tại, đúng 0 tham số tường
   minh (`numberOfArguments == 2`) và giải mã đúng kiểu trả về (`@`, `B`, `c`,
   `q`, `Q`, `i`, `d`, `f`) trước khi gọi `objc_msgSend`.
4. **Cách ly đa tài khoản (`accountScope`) & Fail-Closed.**
   `ZLModCurrentAccountScope()` truy vấn `userId` từ các singleton đã xác minh
   trong Mach-O (`ZAApplicationContext +sharedContext`,
   `ChatDataManager +sharedChatDataManager`,
   `ChatSendSeenDataManager +shared`,
   `FTSDatabaseManager +sharedInstance`), loại bỏ giá trị rỗng/`"0"`/`null` và
   băm SHA-256 thành `acc_<16hex>`. Khi chưa xác định được tài khoản, mọi kho
   dữ liệu nhạy cảm (`ZLModConversationPolicyStore`, `ZLModAntiRecallStore`,
   `ZLModPrivateNotesStore`, `ZLModConversationMenu`) tự động từ chối ghi/đọc
   (fail-closed), không bao giờ dùng chung bucket toàn cục.
5. **Mã hóa cục bộ Encrypt-then-MAC (`ZLModCryptoBox`).**
   Khóa chính 256-bit được sinh bằng `CCRandomGenerateBytes` và lưu trong iOS
   Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Hai khóa con
   độc lập (`ENC` và `MAC`) được dẫn xuất qua SHA-256 để mã hóa `AES-256-CBC` +
   xác thực `HMAC-SHA256` (so sánh hằng thời gian) gắn chặt với metadata ngữ cảnh.

## 3. Các điểm sửa ABI quan trọng so với bản mẫu nghiên cứu

| Hạng mục | Thực tế trong Mach-O Zalo `26.10.02` / `26.11.01` | Cách xử lý trong ZLMod |
|---|---|---|
| `ChatSendSeenDataManager -sendSeenServerPARQueue` | Encoding `[@16@0:8]` — là getter trả về đối tượng queue, **không phải** hàm void gửi seen | Không bao giờ hook selector này; đã loại bỏ khỏi `Scripts/anchors.txt` |
| `ChatSocketCmdHelper` seen & typing | `+sendSeenChatACK:withSubCommandType:`, `+sendSeenGroupChatACKByData:withSubCommandType:`, `+sendStatusTyping:...` là **class methods (`+`)**; `+sendStatusTyping:...` trả về `Q` (`unsigned long long`) | Hook trên metaclass bằng `ZLModReplaceClassMethod` với đúng kiểu trả về |
| `ChatDataManager -sendTypingWithType:toUserId:messageType:isE2eeChat:` | Encoding `[B44@0:8Q16@24Q32B40]` — trả về `BOOL` (`B`), nhận 4 tham số | Hook với `declaredArgs=4`, `allowedReturns="Bc"`, trả về `NO` khi chặn |
| `FriendRequestManager` unread receipts | Tham số `sourceView` có kiểu `i` (`int` 32-bit) | Khai báo block nhận `int sourceView` khớp ABI |
| `InboxContextMenuManager -contextMenu:didSelectActionId:forIdentifier:` | Encoding `[v40@0:8@16q24@32]` — 3 tham số `(id, NSInteger, id)` | Hook đúng `declaredArgs=3`, kiểm tra `ZLModMenuSession` (TTL 120s, dùng 1 lần) |
| `ContextMenuViewModel` | `textColor` / `iconColor` nhận kiểu `ZDSColor *`, không phải `UIColor *` | Chỉ gán `text`, `iconImage`, `menuType`, `accessibilityIdentifier` |
| Cell danh sách hội thoại | Zalo sử dụng cả `UXInboxMessageCell` (`-setObject:`) và `ChatListItemCell` (`-setListItem:`) của `ZADesignSystem` | Hook cả hai lớp cell và theo dõi qua `NSHashTable` yếu để cập nhật chấm xanh tức thì |
| `ChatEntity` target ID | Có `tuid` và `threadId`, **không có** `toUid` | Đọc `tuid` / `threadId` qua `ZLModSafeStringProperty` |
| `ChatEntity -_getRecalledMsgPreviewFromSource:` | Encoding `[@24@0:8q16]` — 1 tham số `NSInteger source` (`q`) | Hook đúng `declaredArgs=1`, trả về chuỗi có tiền tố `ZLModAntiRecallNoticePrefix` |

## 4. Build & Kiểm chứng

```text
Portable (mọi OS có Python 3):
  python -m unittest discover -s Tests -p "test_*.py" -v
  python Scripts/project_gate.py .

macOS CI (macos-26 + Xcode iphoneos SDK):
  make          → build/libZLMod.dylib
  make gates    → Scripts/gates.sh (arm64, deps, install_name, minos 15.1,
                  UIGlassEffect runtime guard, codesign, size)
  Scripts/report.sh → SHA-256, nm, otool, IMPLEMENTATION-REPORT.md, COMPATIBILITY-REPORT.md
```
