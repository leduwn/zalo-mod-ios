# ZLMod Phase 2 & Phase 3 Implementation Record (Build 5)

**Date:** 2026-11-09  
**Target workspace:** `d:\Projects\zalo-mod-ios\zlmod`  
**Supported allowlisted targets:** `261002/261002802` and `261101/261101802` (`vn.com.vng.zingalo`, `vn.com.vng.zingalo2`, arm64, iOS 15.1+)

## 1. Delivered Modules

1. **Core, Preferences & Hook Engine (`ZLModCore.m`, `ZLModPreferences.m`, `ZLModHookEngine.m`):**
   - Added `ZLModReplaceClassMethod` for metaclass (`+`) hooks alongside `ZLModReplaceMethod`.
   - Added ABI-validated property readers (`ZLModSafeObjectProperty`, `ZLModSafeStringProperty`, `ZLModSafeBoolProperty`, `ZLModSafeInt64Property`, `ZLModSafeDoubleProperty`) and `ZLModActiveKeyWindow()`.
   - Added regex-redacted 200-line ring buffer + 512 KB rotating `ZLMod.log`, module status registry (`HOOK_INSTALLED` / `NOT_INSTALLED`), and session transition observers (`AppDelegate -didLogout`, `-didLogin`, `kNotifyDidLogoutAnimation`).
2. **Encrypted Storage & Account Scope (`ZLModCryptoStore.m`):**
   - Verified `ZLModCurrentAccountScope()` across `ZAApplicationContext +sharedContext`, `ChatDataManager +sharedChatDataManager`, `ChatSendSeenDataManager +shared`, and `FTSDatabaseManager +sharedInstance` (filtering `"0"`/null, SHA-256 `acc_<16hex>`, fail-closed `nil`).
   - Implemented `ZLModCryptoBox` using iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `AES-256-CBC` + `HMAC-SHA256` v2, constant-time MAC check).
3. **Selective Seen/Typing & Privacy (`ZLModPolicyStore.m`, `ZLModPrivacy.m`):**
   - Implemented `ZLModPrivacyContext` (`BaseChatTVC -zaloViewDidAppear:` / `-zaloViewWillDisappear:`) and `ZLModConversationPolicyStore` (`Documents/ZLModPolicies.plist`, schema v2).
   - Fixed all Mach-O signatures: removed invalid `sendSeenServerPARQueue` hook, used `ZLModReplaceClassMethod` for `ChatSocketCmdHelper` (`+sendSeenChatACK:withSubCommandType:`, `+sendSeenGroupChatACKByData:withSubCommandType:`, `+sendStatusTyping:...` returning `Q`), hooked `ChatDataManager -sendTypingWithType:toUserId:messageType:isE2eeChat:` returning `B`, filtered `sendSeenLastMessageWithThreadIds:withMessageType:` per conversation, and matched `int` (`i`) `sourceView` on `FriendRequestManager`.
4. **Conversation Context Menu & Local Unread (`ZLModConversationMenu.m`):**
   - Hooked `InboxContextMenuManager -getActionsWithItem:` and `-contextMenu:didSelectActionId:forIdentifier:` (`[v40@0:8@16q24@32]`) with single-use 120s `ZLModMenuSession`.
   - Hooked both `UXInboxMessageCell` and `ChatListItemCell` with weak `NSHashTable` tracking to render/toggle the `#0068FF` unread dot (`tag = 0x5A1D`) immediately.
5. **Local Anti-Recall Ghost Preview (`ZLModAntiRecall.m`):**
   - Hooked `ConversationModel -didLoadChats:config:`, `-updateDBWhenRecalledChats:completion:`, and `ChatEntity -_getRecalledMsgPreviewFromSource:` (`[@24@0:8q16]`).
   - Encrypted snapshots with metadata MAC binding `(accountScope, globalId, clientId, threadId, timestamp)`, 14-day TTL, explicit `[ZLMod Bản sao cục bộ — tin nhắn gốc đã thu hồi]` prefix, and zero mutation of `ChatEntity.message` or Zalo's SQLite DB.
6. **Utilities (`ZLModUtilities.m`):**
   - `ZLModPrivateNotesStore` (`Documents/ZLModNotes.plist`, encrypted per conversation).
   - `ZLModQuickReplyStore` (`Documents/ZLModQuickReplies.plist`, CRUD + reorder + safe composer insertion via `BaseChatTVC -fillChatBarWithText:` or `firstResponder`, never auto-sends).
   - `ZLModDelaySendManager` (5-state atomic FSM on `ZAChatSendingManager -sendChat:checkUpload:` `[v28@0:8@16B24]`, interactive undo banner, auto-cancel on background/logout/disable).
7. **Theme & Dashboard UI (`ZLModTheme.m`, `ZLModUI.m`):**
   - `ZLModThemeManager` (default-OFF `@""`, baseline capture & clean restoration on reset).
   - Expanded `ZLModSettingsViewController` with 6 child management/diagnostic view controllers.

## 2. Verification Status

- **Portable Python test suite (`Tests/test_*.py`):** Verified locally on Windows.
- **Product identity & license gates (`Scripts/project_gate.py`, `Tests/test_license_boundary.py`):** Verified locally on Windows (`0` violations).
- **Mach-O anchor & signature verification (`Scripts/anchors.txt`):** `84/84` anchors verified against `Payload/Zalo.app/Zalo`.
- **Pending macOS CI / Physical Device:** `make && make gates` requires macOS + Xcode `iphoneos` SDK (`macos-26` runner), and runtime behavioral testing requires a physical iPhone running Zalo `26.10.02` or `26.11.01`.
