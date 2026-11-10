# ZLMod — Lịch sử cập nhật (Changelog)

Toàn bộ quá trình phát triển và các mốc phát hành của dự án ZLMod cho Zalo iOS.

---

## [Build 9] — 2026-11-10
### Đột phá tính năng & Sửa lỗi toàn diện
- **Sửa triệt để lỗi crash khi nhấn giữ hội thoại ở màn hình chính:**
  - Phân tích dịch ngược ARM64 binary cho thấy `InboxContextMenuManager -getActionsWithItem:` và `InboxContextMenuProvider contextMenuSectionsForItem:info:` trả về mảng lồng nhau dạng Section: `NSArray<NSArray<ZAContextMenuAction *> *>`.
  - Đóng gói 4 action tùy chỉnh của ZLMod vào một Section độc lập, loại bỏ hoàn toàn lỗi crash `unrecognized selector` do UIKit duyệt qua action phẳng.
- **Tính năng Hiện / Ẩn tin nhắn thu hồi trực tiếp tại ô chat (In-Place Toggle):**
  - Nhấn giữ ô *"Tin nhắn đã được thu hồi"* xuất hiện nút **"Hiện"** (icon con mắt 👁).
  - Bấm **"Hiện"**: Khôi phục trực tiếp nội dung tin nhắn gốc ngay bên trong bong bóng chat, kích hoạt layout engine Zalo tính lại kích thước bong bóng (`[chat reloadCellIfNeed]`).
  - Đối với **Ảnh thu hồi**: Mở modal xem trước ảnh chất lượng cao kèm tính năng phóng to, lưu vào album ảnh hoặc sao chép.
  - Sau khi tin nhắn đã được hiện, nhấn giữ lại sẽ chuyển nút thành **"Ẩn"** (icon con mắt gạch 👁‍🗨), bấm vào sẽ hoàn nguyên về ô thu hồi ban đầu.
  - Hook động `-[ChatEntity message]` và `-[ChatEntity _getRecalledMsgPreviewFromSource:]` bảo đảm không can thiệp SQLite database gốc của Zalo.
- **Phân phối & Tối ưu cài đặt:**
  - Tải trực tiếp file IPA hoàn chỉnh `Zalo-26.10.02-ZLMod-build9-noappex-unsigned.ipa` (130 MB) lên mục GitHub Releases.
  - Kiểm thử forensics và chữ ký Mach-O toàn vẹn.

---

## [Build 8] — 2026-11-10
### Khắc phục treo Tab Bar & Thêm nút Hiện thu hồi
- **Khắc phục lỗi đơ Zalo khi bật Liquid Glass Tab Bar:**
  - Loại bỏ hoàn toàn deadlock trên Main Thread và hiện tượng bị ngắt tiến trình do Watchdog timeout `0x8BADF00D` (FrontBoard 5.0s timeout).
  - Tối ưu hóa chu kỳ render của `UIVisualEffectView`.
- **Thêm nút "Hiện" vào menu ngữ cảnh bong bóng chat:**
  - Tích hợp vào `MenuButton -showContextMenuViewWithMenuItemArray:hasReaction:` và `MSContextMenuItemCreator`.
  - Hiển thị pop-up thông báo nội dung tin nhắn đã thu hồi kèm nút Sao chép.

---

## [Build 7] — 2026-11-10
### Ổn định hóa Anti-Recall & Giao diện Native
- **Chụp snapshot tin nhắn ngay khi đến:** Tự động bắt tin nhắn tại `ConversationModel -didLoadChats:config:` trước khi sự kiện thu hồi xảy ra.
- **Chuẩn hóa giao diện menu:** Loại bỏ việc khởi tạo nil `ZDSColor`, sử dụng native-styled menu rows.
- **Fallback an toàn cho Glass Effect:** Sử dụng `systemUltraThinMaterial` trên các phiên bản iOS chưa hỗ trợ `UIGlassEffect`.

---

## [Build 6] — 2026-11-09
### Tối ưu hóa khởi tạo & Cô lập Module
- Đảm bảo an toàn tuyệt đối khi khởi tạo dylib trong tiến trình Zalo, kiểm tra context đăng nhập trước khi kích hoạt các hook nhạy cảm.
- Bảo vệ ring-buffer log và luồng xoay vòng file log `ZLMod.log`.

---

## [Build 5] — 2026-11-09
### Hoàn thiện bộ tính năng Phase 2 & Phase 3
- **Tùy chỉnh từng cuộc trò chuyện (Per-Chat Policies):** Quản lý Seen, Typing, Unread và Private Note riêng biệt cho từng người thông qua `ZLModPolicyStore`.
- **Đánh dấu chưa đọc cục bộ:** Chấm xanh `#0068FF` trên cả `UXInboxMessageCell` và `ChatListItemCell`.
- **Delay Send Undo FSM (1–10s):** Máy trạng thái 5 bước cho phép đếm ngược và hủy gửi tin nhắn trước khi truyền lên socket.
- **Quick Reply Templates:** Quản lý và chèn mẫu câu trả lời nhanh vào thanh soạn thảo.
- **Mã hóa Keychain AES-256-CBC + HMAC-SHA256:** Cơ chế Encrypt-then-MAC bảo vệ toàn bộ dữ liệu nhạy cảm theo `accountScope`.
- **Chặn quảng cáo toàn diện:** Vô hiệu hóa `ZInstantFeedAdsView`, `LocationOAAdsCell` và chặn network requests quảng cáo.

---

## [Build 1 - 4] — 2026-11-08
### Nền tảng & Clean-Room Architecture
- Thiết lập kiến trúc Clean-room độc lập (không Theos, không Substrate/ElleKit).
- Xây dựng `ZLModHookEngine` với kiểm chứng ABI và chữ ký phương thức nghiêm ngặt.
- Xác lập bộ 84 anchors đối chiếu trực tiếp với binary Zalo `26.10.02` / `26.11.01`.
- Triển khai `Packaging/package_ipa.py` tiêm dylib và đóng gói IPA no-jailbreak.
