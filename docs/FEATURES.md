# ZLMod — Danh sách tính năng & trạng thái triển khai

Tài liệu này phân tách rõ ràng giữa:
- **Source & Mach-O Static Verified:** Đã triển khai trong mã nguồn Objective-C (`Sources/*.m`), vượt qua kiểm thử hợp đồng portable (`Tests/test_*.py`), và đối chiếu khớp 100% chữ ký/type encoding với binary Mach-O của Zalo (`84/84` anchors trong `Scripts/anchors.txt`).
- **Build & Device Runtime Verification:** Cần biên dịch bằng `xcrun --sdk iphoneos clang` trên macOS (`make && make gates`) và kiểm thử thực tế trên iPhone vật lý chạy Zalo `26.10.02` / `26.11.01`.

## A. Appearance & Theme (`ZLModGlass.m`, `ZLModTheme.m`)

| Tính năng | Trạng thái | Cơ chế | Anchor |
|---|---|---|---|
| Liquid Glass Tab Bar | ✅ Source + Mach-O Verified | Overlay `UIVisualEffectView` trong bounds tab bar; `UIGlassEffect` khi runtime có (iOS 26+), fallback `systemUltraThinMaterial` | `ZaloTabBarViewController` |
| Theme Presets (`classic_blue`, `dark_oled`, `pure_black`, `ocean_teal`) | ✅ Source Verified | Áp dụng `UINavigationBarAppearance`, `UITabBarAppearance`, `overrideUserInterfaceStyle`; chụp baseline trước khi đổi để khôi phục nguyên trạng khi tắt | UIKit `UIWindowScene` |
| Custom Accent Tint (`#RRGGBB`) | ✅ Source Verified | Chuẩn hóa mã màu hex 6 ký tự và áp dụng `tintColor` trên các cửa sổ/thanh điều hướng | `kZLModThemeTintHex` |

## B. Privacy — Toàn cục & Theo từng cuộc trò chuyện (`ZLModPrivacy.m`, `ZLModPolicyStore.m`)

| Tính năng | Trạng thái | Cơ chế | Anchor |
|---|---|---|---|
| Hide Typing Indicator (Global & Per-Chat) | ✅ Source + Mach-O Verified | Chặn `ChatDataManager -sendTypingWithType:toUserId:messageType:isE2eeChat:` (`[B44@0:8Q16@24Q32B40]`) và `ChatSocketCmdHelper +sendStatusTyping:...` (`[Q56@0:8Q16q24Q32q40q48]`) | `ChatDataManager`, `ChatSocketCmdHelper`, `BaseChatTVC` |
| Control Seen Status & Read Receipts (Global & Per-Chat) | ✅ Source + Mach-O Verified | Chặn gửi seen cấp entity/talk item/batch/server, lọc từng `threadId` trong `-sendSeenLastMessageWithThreadIds:withMessageType:`, chặn `+sendSeenChatACK:...`, `+sendSeenGroupChatACKByData:...` và `FriendRequestManager` (`sourceView` kiểu `int` `i`) | `ChatSendSeenDataManager`, `ChatSocketCmdHelper`, `FriendRequestManager` |
| Active Chat Context Tracking | ✅ Source + Mach-O Verified | Theo dõi hội thoại đang hiển thị qua `BaseChatTVC -zaloViewDidAppear:` và `-zaloViewWillDisappear:`, tự xóa khi đăng xuất | `BaseChatTVC` |
| Disable Tracking & Analytics | ✅ Source + Mach-O Verified | `NSURLProtocol` chặn `log.api.zaloapp.com`, `/tracking*`, `/tracking-v3` → HTTP 204 | `log.api.zaloapp.com`, `/tracking-v3` |
| Disable Firebase Collection | ✅ Source Verified | Gọi API chính thức `setAnalyticsCollectionEnabled:NO`, `setDataCollectionEnabled:NO`, Crashlytics off (respond-guarded) | `FIRAnalytics`, `FIRPerformance`, `FIRCrashlytics` |

## C. Conversation Context Menu & Local Unread (`ZLModConversationMenu.m`)

| Tính năng | Trạng thái | Cơ chế | Anchor |
|---|---|---|---|
| Long-press Conversation Actions (`98001..98004`) | ✅ Source + Mach-O Verified | Hook `InboxContextMenuManager -getActionsWithItem:` (`[@24@0:8@16]`) và `-contextMenu:didSelectActionId:forIdentifier:` (`[v40@0:8@16q24@32]`); tạo `ContextMenuViewModel` kèm phiên `ZLModMenuSession` (TTL 120s, dùng 1 lần, kiểm tra `accountScope`) | `InboxContextMenuManager`, `ContextMenuViewModel`, `UXInboxMessageCellItem` |
| Local Mark Unread (Chấm xanh `#0068FF`) | ✅ Source + Mach-O Verified | Theo dõi cell qua `NSHashTable` yếu trên cả `UXInboxMessageCell` (`-setObject:`, `-prepareForReuse`) và `ChatListItemCell` (`-setListItem:`, `-prepareForReuse`), gắn chấm xanh `tag=0x5A1D` (`userInteractionEnabled=NO`) | `UXInboxMessageCell`, `ChatListItemCell` |

## D. Anti-Recall — Ghost Preview cục bộ (`ZLModAntiRecall.m`, `ZLModCryptoStore.m`)

| Tính năng | Trạng thái | Cơ chế | Anchor |
|---|---|---|---|
| Encrypted Local Recall Archive | ✅ Source + Mach-O Verified | Hook `ConversationModel -didLoadChats:config:` (`[v32@0:8@16@24]`), `-updateDBWhenRecalledChats:completion:` (`[v32@0:8@16@?24]`) và `ChatEntity -_getRecalledMsgPreviewFromSource:` (`[@24@0:8q16]`) | `ConversationModel`, `ChatEntity` |
| Keychain AES-256-CBC + HMAC-SHA256 v2 | ✅ Source Verified | Khóa chính lưu trong iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), ràng buộc MAC với `(accountScope, globalId, clientId, threadId, timestamp)`, tự hết hạn sau 14 ngày | `Security.framework`, `CommonCrypto` |
| Nhãn bản sao cục bộ minh bạch | ✅ Source Verified | Mọi nội dung hiển thị đều mang tiền tố `[ZLMod Bản sao cục bộ — tin nhắn gốc đã thu hồi]` và không bao giờ sửa đổi `ChatEntity.message` hay SQLite DB của Zalo | `ZLModAntiRecallNoticePrefix` |

## E. Utilities (`ZLModUtilities.m`)

| Tính năng | Trạng thái | Cơ chế | Anchor |
|---|---|---|---|
| Delay Send Undo (1–10s) | ✅ Source + Mach-O Verified | Máy trạng thái 5 bước (`Pending`/`Cancelled`/`Dispatching`/`Dispatched`/`Failed`) trên `ZAChatSendingManager -sendChat:checkUpload:` (`[v28@0:8@16B24]`), thanh đếm ngược có nút **Hủy gửi**, tự hủy khi xuống nền/đổi tài khoản | `ZAChatSendingManager` |
| Quick Reply Templates | ✅ Source + Mach-O Verified | Lưu mẫu câu trong `ZLModQuickReplies.plist`, điền vào thanh chat qua `BaseChatTVC -fillChatBarWithText:` (`[v24@0:8@16]`) hoặc `firstResponder` — không bao giờ tự động gửi | `BaseChatTVC`, `fillChatBarWithText:` |
| Encrypted Private Notes | ✅ Source Verified | Ghi chú riêng tư mã hóa AES-256-CBC + HMAC-SHA256 theo từng `threadId` và `accountScope` trong `ZLModNotes.plist` | `ZLModPrivateNotesStore` |

## F. Ad Blocking & Feature Restoration (`ZLModAds.m`, `ZLModFeatures.m`, `ZLModSettings.m`)

| Tính năng | Trạng thái | Cơ chế | Anchor |
|---|---|---|---|
| Hide Ads & Block Ad Requests | ✅ Source + Mach-O Verified | Ẩn view quảng cáo (`ZInstantFeedAdsView`, `LocationOAAdsCell`) + chặn `/zpads/`, `/get/ads`, `/ads_out_stream`, `/ads_boost`, `/v1/ads/`, `ads.platform.zalo.me` | `ZInstantFeedAdsView`, `LocationOAAdsCell` |
| Profile Music / Google Drive Backup / More Tab | ✅ Source + Mach-O Verified | Force getter `enableProfileMusic*`, bridge `_basicBackupGDriveSectionZInstantData` ↔ `__basicBackupGDriveSectionZInstantData`, mirror external keys có khôi phục nguyên trạng | `ZLExtendedProfileMusic`, `ProfileMusicItemModel` |
| ZLMod Customize (Native Settings Row + Dashboard) | ✅ Source + Mach-O Verified | Clone `BasicSettingCellV2Object` của "Tài khoản và bảo mật" (`00Zh8W`) trong `SettingUI40TableViewController` + 6 màn hình quản lý/chẩn đoán con | `SettingUI40TableViewController` |

## G. Không triển khai (ranh giới kỹ thuật & an toàn)

| Mục | Lý do |
|---|---|
| Original Photo Default | Phụ thuộc nhiều luồng nén/picker khác nhau; loại trừ để tránh hỏng luồng gửi ảnh |
| Unlock ZCloud Premium / Paid Entitlements | Quyền lợi do máy chủ quyết định; can thiệp phía client chỉ gây sai lệch hiển thị |
| Fake admin/owner nhóm | Dữ liệu phân quyền nhóm do máy chủ quyết định |
| Video transcode bypass / Upload-limit / TTL override | Phụ thuộc kiểm tra của máy chủ và tính tương thích phía người nhận |
| Editable `rules.json` hooks / Chat head nổi | Không đảm bảo an toàn kiểu dữ liệu ABI Objective-C ở runtime |
