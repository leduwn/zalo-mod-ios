# ZLMod — IPA Analysis (Zalo 26.11.01)

Nguồn: `vn.com.vng.zingalo-26.11.01-eeveedecrypter.ipa` (135,649,595 B, 1,076 entries,
binary `Payload/Zalo.app/Zalo` 182,755,664 B). Phân tích tĩnh: plistlib,
llvm-otool/objdump, `strings -a -n 4` (897,614 dòng), parser Mach-O chained-fixup
để bóc `__objc_classlist` (19,645 classes) và `__objc_methname` (244,652 selectors).

## 1. Danh tính bundle

| Trường | Giá trị |
|---|---|
| CFBundleIdentifier | `vn.com.vng.zingalo` |
| Phiên bản | `261101` / build `261101802` (store 26.11.01) |
| MinimumOSVersion | **15.1** |
| SDK | `iphoneos26.2`, DTXcode 2630 (Xcode 26.3) |
| `UIDesignRequiresCompatibility` | **YES** (opt-out iOS 26 redesign) |
| UIDeviceFamily | [1,2] (iPhone + iPad), arm64 |
| URL schemes | `zalo`, `zalosdk`, `zalosdk7`, `zaloshareext`, `zalosdkgame`, FB + Google reversed client |
| ATS | `NSAllowsArbitraryLoads = true` |

## 2. Binary

- arm64 thin `MH_EXECUTE`, PIE; `LC_ENCRYPTION_INFO_64 cryptid=0` → đã decrypt.
- 156 dependency (`@rpath` + weak), 31 framework nhúng (ZADesignSystem, ZDSTokens,
  ZAFoundation, ZKit, IGListKit, Firebase suite, ZFaceEffect, libzjxl, …).
- 5 app extension: NotificationContent/Service, Share, ZaloIntents, ZaloToday.
- Jailbreak detection có sẵn: `/Applications/Cydia.app`, `MobileSubstrate.dylib`,
  `/bin/bash`, `/usr/sbin/sshd`, `/etc/apt`, `isJailbroken`, `_dyld_image_count`.

## 3. Entitlements (từ superblob 0xfade0cc0)

- team `CVB6BX97VM`; `aps-environment=production`; pushkit voip; associated domains `applinks:zalo.me`;
  iCloud `iCloud.vn.com.vng.zingalo`; keychain group `CVB6BX97VM.group.keychain.vn.com.vng.zalo`.
- **6 App Group**: `group.zcontacts…`, `group.zfriends…`, **`group.zsettings…`**,
  `group.vn.com.vng.zingalo`, `group.zgroups…`, `group.noti…`
  → `group.zsettings.vn.com.vng.zingalo` là nơi ZLMod mirror external keys.
- Không có `embedded.mobileprovision` → package cần re-sign để chạy.

## 4. Settings (xác minh)

| Bằng chứng | Ghi chú |
|---|---|
| `SettingUI40TableViewController` (128 methods parsed) | settings hub; class **duy nhất** implement `accountAndSecurityObject` |
| `BasicSettingUI40TableViewController` → `BasicSettingTableViewController` | parent chain (local, đáng tin) |
| `AccountSettingUI40ViewController` (130 methods) | màn Account & Security |
| `getArrangedTableContent`, `updateTitleObjects`, `createTableViewFactory` | API dựng nội dung bảng |
| `_accountAndSecurityObject` ivar; type `BasicSettingCellV2Object` | cell object thật của hàng cần chèn cạnh |
| Key `00Zh8W` = "Tài khoản và bảo mật" (vi) / "Account and security" (en) | xuất hiện đúng 1 lần trong binary |
| `tabme.section_items.account_security.title` + `tabme.*` | row keys của Me tab |
| Cell object family | `BasicSettingCell(V2)Object`, `BasicSettingCell`, `BasicSettingCellV2`, `BasicSettingTableViewAction`, `CheckSettingCellObject`, `ZSectionObject` |

## 5. Tab bar (xác minh)

- `ZaloTabBarViewController` — 80 selectors: `changeSelectedTabIndex:`,
  `changeTabbarAtIndexWithNotification:`, `_reloadTabBarAppearanceWithNotification:`,
  `getSystemItemPositionWithCurrentIndex:`, `checkShowReddotTipTabDiscovery`, …
- Hỗ trợ: `ZaloTabBarChildDelegate`, `TabbarBadgeView`, `ASZTabbarConfig`,
  `ZATimelineTabBarProcessor`, `ContactSubTabbarView`.
- Lưu ý: parent UIKit chưa xác minh được từ parse tĩnh (import ordinal decode lỗi);
  ZLMod không giả định parent nào.

## 6. Messaging (xác minh — dùng làm hook anchors)

- Typing: `sendStatusTyping:withCommand:withSubCommand:withDestType:withGlobalMessageId:`,
  `TypingMessageInfo`, `_typeTyping`, `_lastTimeSendTyping`, `_typeEventGetTyping`.
- Seen: `ChatSendSeenDataManager`, `_sendingSeenDic`, `_retrySendSeenList`,
  `sendSeenMessageWithChatEntity:`, `sendSeenMessageWithTalkTableItem:`,
  `sendSeenMessages:messageDict:incomingData:`, `_sendSeenMessageWithSeenData:messageType:`,
  `sendSeenChatACK:withSubCommandType:`, `sendSeenGroupChatACKByData:withSubCommandType:`,
  `sendSeenServer`, `sendSeenServerPARQueue`, `forceSendSeenServer`,
  `sendSeenLastMessageWithThreadIds:withMessageType:`,
  `sendSeenCurrentUnreadFriendRequest:(retryTime:)sourceView:`.
- Anti-recall (tham khảo, không triển khai): `chat.undo` (1), `chat.delete` (5).

## 7. Privacy / Ads (xác minh)

- Tracking: `%@/tracking` (line 172689), `%@/tracking-v3` (173927),
  `https://log.api.zaloapp.com/tracking` (211876), `…/tracking-rt` (172696).
- Ads: `%@/zpads/inboxnative/getads`, `/v1/user/core/get/ads`, `adsv2`,
  `ads_out_stream`, `ads_boost`, `/v1/ads/impression`, host `ads.platform.zalo.me`.
- Ad UI: `ZInstantFeedAdsView`, `LocationOAAdsCell` (cell/view classes có thật);
  models: `CSCAdsModel`, `CommunityAds`, `PhotoAdsEntity`, `OAAdsEntity`,
  `ZCCRCommunityAdsConfig`.
- Firebase: FirebaseAnalytics *không* nhúng như framework rời, nhưng có
  `GoogleDataTransport`, `FirebaseCore*`, `FirebaseSessions`, `nanopb`, `GoogleUtilities`
  → hook qua `NSClassFromString(@"FIRAnalytics"/"FIRPerformance"/"FIRCrashlytics")`
  với responds-check (chỉ chạy khi class hiện diện).

## 8. Feature Restoration (xác minh)

- **Profile Music**: `ProfileMusicSetting`/`kProfileMusicSetting` (strings 162346–162347),
  `profile_music`, `features@profile_music` (line 285173!), `enable_rbt`, getters
  `enableProfileMusic`, `enableProfileMusicRBT`, `enableShareProfileMusic`,
  `newFlagEnableProfileMusic`, `setEnableProfileMusicLocal:`;
  classes `ProfileMusicListView`, `ProfileMusicItemModel`, `ZLExtendedProfileMusic`.
- **Google Drive**: stack `ZAGDrive*` (Authorization/Service/ListApi/FileApi/AboutApi…)
  + migration `kCloudMigrGDriveState`, `restore_gdrive_photo_csc`,
  `ux://stopUsingGGDrive`, `_basicBackupGDriveSectionZInstantData`,
  `__basicBackupGDriveSectionZInstantData`, `_backupGDriveCellObj`.
- **More Tab**: `enable_tabmore`.

## 9. Đối chiếu ZaloXposed → iOS

| ZaloXposed (Android) | iOS verdict | ZLMod |
|---|---|---|
| SilentTypingHook (MessageRepository) | (b) → chọn selector gửi typing | Hide Typing ✅ |
| BlockSendSeenHook (SendSeenManager) | (b) → 12 selectors seen/ACK | Seen + Read Receipts ✅ |
| DisableZaloTrackingHook (URL/enum) | (b) URL layer; enum ordinals Android-only | URL filter ✅ |
| DisableFirebaseLoggingHook | (b) → dùng API chính thức | Firebase off ✅ |
| HideAdsHook (view type + endpoints) | (a/b) view Android-only; endpoints port được | view class + endpoints ✅ |
| RestoreProfileMusicHook (`ENABLE_PROFILE_MUSIC_*`) | (b) → `features@profile_music` + getters | ✅ |
| RestoreGoogleDriveBackupHook | (b) → GDrive stack + bridge section | ✅ |
| CustomizeBottomRowHook (`ENABLE_GROUP_TAB`, …) | (b) → `enable_tabmore` | More Tab ✅ |
| UnlockZCloudHook | server-authoritative | không port |
| FakeAdmin/FakeOwnerHook | server-authoritative, rủi ro ban | không port |
| EnableChatHeadHook | (c) iOS không có overlay API | không port |
| AntiRecallDeleteHook | JSON `chat.undo`/`chat.delete` có trong binary | (không nằm trong yêu cầu — để dành) |

## 10. Phương pháp tái tạo dumps

```bash
unzip -o vn.com.vng.zingalo-26.11.01-eeveedecrypter.ipa -d extracted
strings -a -n 4 extracted/Payload/Zalo.app/Zalo > zalo.strings
# class/selector lists: parser Mach-O __objc_classlist / __objc_methname
ZLMOD_IPA_DUMP=. ./Scripts/anchors-verify.sh   # 49 anchors, 0 missing
```
