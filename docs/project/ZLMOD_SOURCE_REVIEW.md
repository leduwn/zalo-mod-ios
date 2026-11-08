# ZLMod source and feature review

Updated: 2026-11-09

Zync supplies the clean-room MIT runtime foundation. The `leduwn` engines and
ZepLaoModMilanVu are used strictly as behavioral references, never as drop-in
hook implementations.

| Candidate | Decision | Status in Build 5 |
|---|---|---|
| Anti-recall cache, history and marker | Implemented (`ZLModAntiRecall.m`) | Mach-O verified (`ConversationModel`, `ChatEntity -_getRecalledMsgPreviewFromSource:`), Keychain AES-256-CBC + HMAC-SHA256 v2, 14-day TTL, explicit local-copy prefix, non-mutating |
| Per-conversation selective seen & typing | Implemented (`ZLModPolicyStore.m`, `ZLModPrivacy.m`) | Mach-O verified instance & class (`+`) hooks, account-scoped (`ZLModPolicies.plist`), fail-closed when account unidentified |
| Local mark unread | Implemented (`ZLModConversationMenu.m`) | Hooks both `UXInboxMessageCell` and `ChatListItemCell`, weak `NSHashTable` live refresh, zero server write |
| Conversation context menu | Implemented (`ZLModConversationMenu.m`) | Hooks `InboxContextMenuManager -getActionsWithItem:` and `-contextMenu:didSelectActionId:forIdentifier:` with 120s single-use `ZLModMenuSession` |
| Quick replies | Implemented (`ZLModUtilities.m`) | Template CRUD + reorder + safe composer insertion via `BaseChatTVC -fillChatBarWithText:` or `firstResponder` (never auto-sends) |
| Delayed send undo | Implemented (`ZLModUtilities.m`) | 5-state atomic FSM on `ZAChatSendingManager -sendChat:checkUpload:`, interactive undo banner, auto-cancel on background/logout/disable |
| Private conversation notes | Implemented (`ZLModUtilities.m`) | Encrypted with `ZLModCryptoBox` in `ZLModNotes.plist`, bound to `(accountScope, threadId)` |
| Theme presets & custom tint | Implemented (`ZLModTheme.m`) | Default-OFF (`@""`), captures window/bar baseline before first override and restores cleanly on reset |
| In-app redacted log & module status viewer | Implemented (`ZLModCore.m`, `ZLModUI.m`) | 200-line redacted ring buffer + 512 KB rotating file log + live `HOOK_INSTALLED` / `NOT_INSTALLED` viewer |
| Original photo default | Excluded | Multiple unverified picker/upload compression paths across builds |
| Video transcode bypass | Excluded | Media-pipeline and receiver compatibility risk |
| Upload-limit override | Excluded | Server-enforced limits |
| Message TTL override | Excluded | Server-authoritative protocol semantics |
| Editable `rules.json` hooks | Excluded | Cannot safely guarantee Objective-C ABI signatures at runtime |
| Floating overlay bubble | Excluded | Unnecessary window/hit-test lifecycle complexity |
| Paid entitlement / ZCloud unlock / fake role | Rejected | Server-authoritative and outside project safety/ethics boundaries |

All implemented modules are verified at the source, portable contract test, and
Mach-O binary anchor/signature level (`84/84` anchors in `Scripts/anchors.txt`).
Compilation of `build/libZLMod.dylib` requires macOS with the Xcode `iphoneos`
SDK (`macos-26` CI), and runtime validation requires physical iPhone testing on
allowlisted builds `261002/261002802` and `261101/261101802`.
