# ZLMod — Danh sách tính năng & Trạng thái triển khai (Build 9)

Tài liệu này chi tiết hóa toàn bộ các tính năng của ZLMod trên Zalo iOS `26.10.02` (261002802) & `26.11.01` (261101802), kiến trúc `arm64`, iOS 15.1+.

---

## 1. Appearance & Theme (`ZLModGlass.m`, `ZLModTheme.m`)

| Tính năng | Trạng thái | Cơ chế thực thi | Anchor / Lớp liên quan |
|---|---|---|---|
| **Liquid Glass Tab Bar** | ✅ Hoàn thiện (Build 8+) | Phủ `UIVisualEffectView` trên thanh Tab Bar; sử dụng `UIGlassEffect` khi runtime có (iOS 26+), fallback `systemUltraThinMaterial`. Cơ chế background task loại bỏ hoàn toàn deadlock / watchdog timeout `0x8BADF00D`. | `ZaloTabBarViewController` |
| **Theme Presets** (`classic_blue`, `dark_oled`, `pure_black`, `ocean_teal`) | ✅ Hoàn thiện | Áp dụng `UINavigationBarAppearance`, `UITabBarAppearance`, `overrideUserInterfaceStyle`; lưu baseline trước khi đổi để khôi phục nguyên trạng. | UIKit `UIWindowScene` |
| **Custom Accent Tint (`#RRGGBB`)** | ✅ Hoàn thiện | Chuẩn hóa mã màu hex 6 ký tự và áp dụng `tintColor` trên các cửa sổ / navigation bar. | `kZLModThemeTintHex` |

---

## 2. Quyền riêng tư — Privacy Toàn cục & Từng cuộc trò chuyện (`ZLModPrivacy.m`, `ZLModPolicyStore.m`)

| Tính năng | Trạng thái | Cơ chế thực thi | Anchor / Lớp liên quan |
|---|---|---|---|
| **Ẩn trạng thái đang soạn tin (Hide Typing)** | ✅ Hoàn thiện | Chặn `ChatDataManager -sendTypingWithType:toUserId:messageType:isE2eeChat:` (`[B44@0:8Q16@24Q32B40]`) và `ChatSocketCmdHelper +sendStatusTyping:...` (`[Q56@0:8Q16q24Q32q40q48]`). Hỗ trợ bật/tắt toàn cục hoặc cho riêng từng người. | `ChatDataManager`, `ChatSocketCmdHelper`, `BaseChatTVC` |
| **Kiểm soát đã xem (Control Seen / Read Receipts)** | ✅ Hoàn thiện | Chặn gửi seen cấp entity/talk item/batch/server, lọc danh sách `sendSeenLastMessageWithThreadIds:withMessageType:`, chặn `+sendSeenChatACK:...`, `+sendSeenGroupChatACKByData:...` và `FriendRequestManager`. | `ChatSendSeenDataManager`, `ChatSocketCmdHelper`, `FriendRequestManager` |
| **Theo dõi ngữ cảnh hội thoại (Active Chat Context)** | ✅ Hoàn thiện | Theo dõi hội thoại đang mở qua `BaseChatTVC -zaloViewDidAppear:` và `-zaloViewWillDisappear:`, tự động dọn dẹp khi đăng xuất. | `BaseChatTVC` |
| **Chặn theo dõi & Phân tích (Disable Analytics / Tracking)** | ✅ Hoàn thiện | `NSURLProtocol` chặn `log.api.zaloapp.com`, `/tracking*`, `/tracking-v3` → HTTP 204. | `log.api.zaloapp.com`, `/tracking-v3` |
| **Tắt thu thập Firebase** | ✅ Hoàn thiện | Vô hiệu hóa `setAnalyticsCollectionEnabled:NO`, `setDataCollectionEnabled:NO`, Crashlytics. | `FIRAnalytics`, `FIRPerformance`, `FIRCrashlytics` |

---

## 3. Menu ngữ cảnh hội thoại & Đánh dấu chưa đọc (`ZLModConversationMenu.m`)

| Tính năng | Trạng thái | Cơ chế thực thi | Anchor / Lớp liên quan |
|---|---|---|---|
| **Menu nhấn giữ hội thoại (Long-press Context Actions)** | ✅ Hoàn thiện (Build 9) | Hook `InboxContextMenuManager -getActionsWithItem:` và `InboxContextMenuProvider contextMenuSectionsForItem:info:`. Đóng gói 4 tùy chọn vào một **Section độc lập** (`NSArray<NSArray<ZAContextMenuAction *> *>`), ngăn chặn triệt để lỗi crash `unrecognized selector`. | `InboxContextMenuManager`, `ZAContextMenuAction`, `InboxContextMenuProvider` |
| **Tùy chỉnh từng người (Per-Chat Policies)** | ✅ Hoàn thiện | Tích hợp 4 nút nhanh: Bật/tắt Ẩn đã xem, Bật/tắt Ẩn soạn tin, Đánh dấu chưa đọc cục bộ, và Ghi chú riêng tư mã hóa. | `ZLModPolicyStore`, `ZLModPrivateNotesStore` |
| **Đánh dấu chưa đọc cục bộ (Chấm xanh `#0068FF`)** | ✅ Hoàn thiện | Theo dõi qua `NSHashTable` yếu trên `UXInboxMessageCell` (`-setObject:`) và `ChatListItemCell` (`-setListItem:`), hiển thị chấm xanh `tag=0x5A1D` mà không gửi gói tin lên máy chủ. | `UXInboxMessageCell`, `ChatListItemCell` |

---

## 4. Chống thu hồi tin nhắn — Anti-Recall In-Place (`ZLModAntiRecall.m`, `ZLModCryptoStore.m`)

| Tính năng | Trạng thái | Cơ chế thực thi | Anchor / Lớp liên quan |
|---|---|---|---|
| **Snapshot & Mã hóa tin nhắn cục bộ** | ✅ Hoàn thiện | Tự động bắt tin nhắn trước khi bị thu hồi tại `ConversationModel -didLoadChats:config:` và lưu vào `ZLModCryptoStore` với mã hóa AES-256-CBC + HMAC-SHA256, tự hủy sau 14 ngày. | `ConversationModel`, `ZLModCryptoStore` |
| **Nút "Hiện" (Unhide Button, icon con mắt 👁)** | ✅ Hoàn thiện (Build 8+) | Chèn vào menu ngữ cảnh bong bóng chat (`MenuButton -showContextMenuViewWithMenuItemArray:hasReaction:`). | `MenuButton`, `MSContextMenuItemCreator` |
| **Khôi phục trực tiếp trong ô chat (In-Place Toggle)** | ✅ Hoàn thiện (Build 9) | Bấm **"Hiện"** sẽ thay thế trực tiếp nhãn *"Tin nhắn đã được thu hồi"* thành nội dung gốc trong ô chat, tự động tính toán lại kích thước ô chat qua `[chat reloadCellIfNeed]`. Hook động `-[ChatEntity message]` không can thiệp SQLite DB gốc. | `ChatEntity`, `MenuButton`, `UILabel` |
| **Nút "Ẩn" (Hide Button, icon con mắt gạch 👁‍🗨)** | ✅ Hoàn thiện (Build 9) | Khi tin nhắn đang ở trạng thái hiện, nhấn giữ lại sẽ chuyển nút thành **"Ẩn"**. Bấm vào sẽ đưa ô chat trở lại trạng thái *"Tin nhắn đã được thu hồi"*. | `kZLModActionHideRecall` |
| **Xem trước ảnh thu hồi chất lượng cao (Photo Preview)** | ✅ Hoàn thiện (Build 9) | Tự động mở modal phóng to ảnh chất lượng cao kèm tính năng **Lưu vào Ảnh** hoặc **Sao chép ảnh** đối với tin nhắn ảnh bị thu hồi. | `ZLModShowPhotoPreview`, `UIActivityViewController` |

---

## 5. Tiện ích nhắn tin — Utilities (`ZLModUtilities.m`)

| Tính năng | Trạng thái | Cơ chế thực thi | Anchor / Lớp liên quan |
|---|---|---|---|
| **Hoãn gửi tin nhắn (Delay Send Undo FSM 1–10s)** | ✅ Hoàn thiện | Máy trạng thái 5 bước (`Pending`/`Cancelled`/`Dispatching`/`Dispatched`/`Failed`) trên `ZAChatSendingManager -sendChat:checkUpload:`. Hiển thị thanh đếm ngược kèm nút **Hủy gửi**, tự hủy an toàn khi app xuống nền hoặc chuyển tài khoản. | `ZAChatSendingManager` |
| **Mẫu câu trả lời nhanh (Quick Reply Templates)** | ✅ Hoàn thiện | Lưu mẫu câu trong `ZLModQuickReplies.plist`, điền trực tiếp vào khung soạn thảo qua `BaseChatTVC -fillChatBarWithText:` — tuyệt đối không tự động gửi. | `BaseChatTVC` |
| **Ghi chú riêng tư mã hóa (Encrypted Private Notes)** | ✅ Hoàn thiện | Ghi chú mã hóa AES-256-CBC theo từng hội thoại và gắn chặt với `accountScope`. | `ZLModPrivateNotesStore` |

---

## 6. Chặn quảng cáo & Khôi phục tính năng (`ZLModAds.m`, `ZLModFeatures.m`, `ZLModSettings.m`)

| Tính năng | Trạng thái | Cơ chế thực thi | Anchor / Lớp liên quan |
|---|---|---|---|
| **Chặn quảng cáo Feed & OA** | ✅ Hoàn thiện | Ẩn `ZInstantFeedAdsView`, `LocationOAAdsCell` + chặn request tới các endpoint `/zpads/`, `/get/ads`, `ads.platform.zalo.me`. | `ZInstantFeedAdsView`, `LocationOAAdsCell` |
| **Khôi phục Profile Music / GDrive Backup** | ✅ Hoàn thiện | Bật cờ `enableProfileMusic*`, bridge cấu hình sao lưu Google Drive. | `ZLExtendedProfileMusic`, `ProfileMusicItemModel` |
| **Bảng điều khiển ZLMod Customize** | ✅ Hoàn thiện | Clone hàng cài đặt chuẩn native trong `SettingUI40TableViewController` + 6 màn hình quản lý, nhật ký chẩn đoán. | `SettingUI40TableViewController`, `ZLModUI` |

---

## 7. Ranh giới kỹ thuật không triển khai (Non-Goals)

| Tính năng | Lý do không triển khai |
|---|---|
| **Original Photo Mặc định** | Luồng nén ảnh của Zalo đa dạng; bỏ qua để bảo đảm tin cậy tuyệt đối khi gửi file đa phương tiện. |
| **Mở khóa ZCloud Premium / Gói trả phí** | Hoàn toàn do máy chủ Zalo xác thực (Server-authoritative). |
| **Gian lận quyền Admin/Trưởng nhóm** | Thuộc tính phân quyền được quản lý và kiểm duyệt trực tiếp từ backend máy chủ. |
| **Bỏ qua giới hạn tải video / Override TTL** | Máy chủ Zalo từ chối tiếp nhận các file vượt quá hạn mức cho phép. |
