// language: Objective-C, file: ZLMod.h, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// ZLMod umbrella header — shared interfaces for all modules.

#ifndef ZLMOD_H
#define ZLMOD_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define ZLMOD_VERSION @"4.0"
#define ZLMOD_BUILD   @"Build 5"

/** Appends a redacted, formatted line to the ring buffer and <Documents>/ZLMod.log (plus App Group fallback). */
void ZLModFileLog(NSString *format, ...);

#define ZLMOD_LOG(fmt, ...) do { \
    NSString *_zlmodMessage = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; \
    NSString *_zlmodSafe = ZLModRedactText(_zlmodMessage); \
    NSLog(@"[ZLMod] %@", _zlmodSafe); \
    ZLModFileLog(@"[ZLMod] %@", _zlmodSafe); \
} while (0)

#pragma mark - Notifications & status constants

extern NSString *const ZLModPrefsDidChangeNotification;
extern NSString *const ZLModAccountDidChangeNotification;
extern NSString *const ZLModConversationPolicyDidChangeNotification;
extern NSString *const ZLModPolicyThreadIdKey;
extern NSString *const ZLModThemeDidChangeNotification;
extern NSString *const ZLModAntiRecallNoticePrefix;

extern NSString *const ZLModModuleStatusNotInstalled;
extern NSString *const ZLModModuleStatusHookInstalled;

#pragma mark - Preference keys (all BOOL OFF / empty default unless noted)

extern NSString *const kZLModGlassTabBar;         // zlmod.appearance.glass
extern NSString *const kZLModThemePreset;         // zlmod.appearance.themePreset (NSString, default @"")
extern NSString *const kZLModThemeTintHex;        // zlmod.appearance.themeTintHex (NSString, default @"")
extern NSString *const kZLModHideTyping;          // zlmod.privacy.hideTyping
extern NSString *const kZLModHideSeen;            // zlmod.privacy.hideSeen
extern NSString *const kZLModHideReadReceipts;    // zlmod.privacy.hideReadReceipts
extern NSString *const kZLModBlockTracking;       // zlmod.privacy.blockTracking
extern NSString *const kZLModBlockFirebase;       // zlmod.privacy.blockFirebase
extern NSString *const kZLModHideAds;             // zlmod.ads.hide
extern NSString *const kZLModBlockAdRequests;     // zlmod.ads.blockRequests
extern NSString *const kZLModRestoreProfileMusic; // zlmod.features.profileMusic
extern NSString *const kZLModRestoreGDrive;       // zlmod.features.gdriveBackup
extern NSString *const kZLModRestoreMoreTab;      // zlmod.features.moreTab
extern NSString *const kZLModAntiRecall;          // zlmod.messaging.antiRecall
extern NSString *const kZLModDelaySend;           // zlmod.utilities.delaySend
extern NSString *const kZLModDelaySendSeconds;    // zlmod.utilities.delaySendSeconds (double, default 3.0)

#pragma mark - ZLModPreferences

@interface ZLModPreferences : NSObject
+ (instancetype)shared;
- (BOOL)boolForKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (double)doubleForKey:(NSString *)key defaultValue:(double)defaultValue;
- (void)setDouble:(double)value forKey:(NSString *)key;
- (NSString *)stringForKey:(NSString *)key defaultValue:(NSString *)defaultValue;
- (void)setString:(NSString *)value forKey:(NSString *)key;
- (void)removeObjectForKey:(NSString *)key;
- (void)resetAllPreferences;
/** Mirrors a value into standard defaults + the Zalo settings App Group, remembering the previous value. */
- (void)writeExternalValue:(id)value forKey:(NSString *)key;
- (void)restoreExternalValueForKey:(NSString *)key;
@end

#pragma mark - Runtime hook engine & safe property readers

void ZLModEnumerateAppClasses(void (^enumerator)(Class cls));
BOOL ZLModIsAppRelatedClass(Class cls);
BOOL ZLModClassHasInstanceMethod(Class cls, SEL sel);
BOOL ZLModClassHasClassMethod(Class cls, SEL sel);
BOOL ZLModClassHasIvar(Class cls, const char *name);

/**
 * Replaces an instance method implementation after strict validation:
 * arity must match (declaredArgs + 2) and the return encoding head must be in
 * allowedReturns (e.g. "v" for void, "Bc" for BOOL variants).
 */
BOOL ZLModReplaceMethod(Class cls, SEL sel, NSUInteger declaredArgs,
                        const char *allowedReturns, id hookBlock);

/** Validates and replaces a class (+) method on the metaclass of `cls`. */
BOOL ZLModReplaceClassMethod(Class cls, SEL sel, NSUInteger declaredArgs,
                             const char *allowedReturns, id hookBlock);

id ZLModSafeObjectProperty(id obj, SEL sel);
NSString *ZLModSafeStringProperty(id obj, SEL sel);
BOOL ZLModSafeBoolProperty(id obj, SEL sel, BOOL defaultValue);
int64_t ZLModSafeInt64Property(id obj, SEL sel, int64_t defaultValue);
double ZLModSafeDoubleProperty(id obj, SEL sel, double defaultValue);
UIWindow *ZLModActiveKeyWindow(void);
UIViewController *ZLModTopPresenterViewController(void);

#pragma mark - Diagnostics, hashing & account scope

NSString *ZLModRedactText(NSString *input);
NSArray<NSString *> *ZLModReadRecentLogs(NSUInteger maxLines);
void ZLModClearLogs(void);
NSString *ZLModPrimaryLogPath(void);

void ZLModSetModuleStatus(NSString *moduleName, NSString *status, NSString *detail);
NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *ZLModAllModuleStatuses(void);

NSString *ZLModSha256Hex(NSString *input);
NSString *ZLModSafeIdHash(NSString *identifier);
NSString *ZLModCurrentAccountScope(void);
NSArray<NSString *> *ZLModCandidateAccountScopesForMigration(void);
void ZLModInvalidateCachedAccountScope(void);

#pragma mark - Encrypted local storage box (ZLModCryptoStore.m)

@interface ZLModCryptoBox : NSObject
+ (instancetype)shared;
- (BOOL)isReady;
- (NSData *)encryptString:(NSString *)plainText metadata:(NSData *)metadata;
- (NSString *)decryptData:(NSData *)packageData metadata:(NSData *)metadata;
@end

#pragma mark - Per-conversation policies & chat context (ZLModPolicyStore.m)

typedef NS_ENUM(NSInteger, ZLModSeenPolicy) {
    ZLModSeenPolicyFollowOriginal = 0,
    ZLModSeenPolicyHideSeen = 1
};

typedef NS_ENUM(NSInteger, ZLModTypingPolicy) {
    ZLModTypingPolicyFollowOriginal = 0,
    ZLModTypingPolicyHideTyping = 1
};

@interface ZLModPrivacyContext : NSObject
+ (void)noteChatControllerDidAppear:(id)controller
                           threadId:(NSString *)threadId
                   conversationType:(NSString *)convType;
+ (void)noteChatControllerWillDisappear:(id)controller;
+ (id)activeChatController;
+ (NSString *)activeThreadId;
+ (NSString *)activeConversationType;
+ (void)clearActiveContext;
@end

@interface ZLModConversationPolicyStore : NSObject
+ (instancetype)shared;
- (ZLModSeenPolicy)seenPolicyForAccountScope:(NSString *)accountScope
                             conversationType:(NSString *)convType
                                     threadId:(NSString *)threadId;
- (BOOL)setSeenPolicy:(ZLModSeenPolicy)policy
      forAccountScope:(NSString *)accountScope
     conversationType:(NSString *)convType
             threadId:(NSString *)threadId;
- (BOOL)isHideSeenForThreadId:(NSString *)threadId conversationType:(NSString *)convType;

- (ZLModTypingPolicy)typingPolicyForAccountScope:(NSString *)accountScope
                                 conversationType:(NSString *)convType
                                         threadId:(NSString *)threadId;
- (BOOL)setTypingPolicy:(ZLModTypingPolicy)policy
        forAccountScope:(NSString *)accountScope
       conversationType:(NSString *)convType
               threadId:(NSString *)threadId;
- (BOOL)isHideTypingForThreadId:(NSString *)threadId conversationType:(NSString *)convType;

- (BOOL)isLocalUnreadForAccountScope:(NSString *)accountScope
                     conversationType:(NSString *)convType
                             threadId:(NSString *)threadId;
- (BOOL)setLocalUnread:(BOOL)marked
       forAccountScope:(NSString *)accountScope
      conversationType:(NSString *)convType
              threadId:(NSString *)threadId;
- (BOOL)isLocalUnreadAnyTypeForThreadId:(NSString *)threadId;

- (NSArray<NSDictionary<NSString *, id> *> *)summaryEntriesForCurrentAccount;
- (NSUInteger)customizedCountForCurrentAccount;
- (BOOL)resetPolicyAtCompoundKey:(NSString *)compoundKey;
- (NSUInteger)resetPoliciesForCurrentAccount;
- (void)resetAllPolicies;
@end

#pragma mark - Anti-Recall store (ZLModAntiRecall.m)

@interface ZLModAntiRecallStore : NSObject
+ (instancetype)shared;
- (BOOL)saveSnapshotWithGlobalId:(int64_t)globalId
                        clientId:(int64_t)clientId
                         message:(NSString *)message
                      senderName:(NSString *)senderName
                        senderId:(NSString *)senderId
                        threadId:(NSString *)threadId
                       timestamp:(NSTimeInterval)timestamp;
- (NSString *)recalledTextForGlobalId:(int64_t)globalId clientId:(int64_t)clientId;
- (NSString *)formattedNoticeForGlobalId:(int64_t)globalId clientId:(int64_t)clientId;
- (NSArray<NSDictionary<NSString *, id> *> *)entriesForCurrentAccount;
- (NSString *)revealTextForEntryKey:(NSString *)entryKey;
- (NSUInteger)preservedCountForCurrentAccount;
- (void)clearCurrentAccountHistory;
- (void)clearAllHistory;
- (void)pruneExpiredEntries;
@end

#pragma mark - Utilities (ZLModUtilities.m)

typedef NS_ENUM(NSInteger, ZLModDelaySendState) {
    ZLModDelaySendStatePending = 0,
    ZLModDelaySendStateCancelled = 1,
    ZLModDelaySendStateDispatching = 2,
    ZLModDelaySendStateDispatched = 3,
    ZLModDelaySendStateFailed = 4
};

@interface ZLModPrivateNotesStore : NSObject
+ (instancetype)shared;
- (NSString *)noteForThreadId:(NSString *)threadId;
- (BOOL)setNote:(NSString *)note forThreadId:(NSString *)threadId;
- (BOOL)removeNoteForThreadId:(NSString *)threadId;
- (NSArray<NSDictionary<NSString *, NSString *> *> *)allEntriesForCurrentAccount;
- (void)clearCurrentAccountNotes;
@end

@interface ZLModQuickReplyStore : NSObject
+ (instancetype)shared;
- (NSArray<NSString *> *)quickReplies;
- (BOOL)addQuickReply:(NSString *)text;
- (BOOL)updateQuickReplyAtIndex:(NSUInteger)index withText:(NSString *)text;
- (BOOL)removeQuickReplyAtIndex:(NSUInteger)index;
- (BOOL)moveQuickReplyFromIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex;
- (void)resetDefaults;
/** Inserts into active chat bar or active text input only; returns NO if none active (never auto-sends). */
- (BOOL)insertTemplateIntoComposer:(NSString *)text;
@end

@interface ZLModDelaySendManager : NSObject
+ (instancetype)shared;
- (NSTimeInterval)delayDuration;
- (void)setDelayDuration:(NSTimeInterval)seconds;
- (NSUInteger)pendingCount;
- (BOOL)cancelPendingSendWithId:(NSString *)sendId;
- (void)cancelAllPendingSends;
@end

#pragma mark - Theme manager (ZLModTheme.m)

@interface ZLModThemeManager : NSObject
+ (instancetype)shared;
- (NSArray<NSString *> *)availablePresetIds;
- (NSString *)displayNameForPreset:(NSString *)presetId;
- (NSString *)activePresetId;
- (NSString *)customTintHex;
- (BOOL)applyPresetNamed:(NSString *)presetId;
- (void)applyCustomTintHex:(NSString *)hex;
- (void)resetTheme;
- (void)refreshAppChrome;
@end

#pragma mark - UI helpers (ZLModConversationMenu.m / ZLModUtilities.m)

void ZLModShowToast(NSString *message);
void ZLModPresentPrivateNoteEditor(UIViewController *presenter,
                                   NSString *threadId,
                                   NSString *displayTitle,
                                   void (^completion)(BOOL saved));

#pragma mark - Module installers (called by ZLModCore)

void ZLModURIFilterInstall(void);
void ZLModPrivacyInstall(void);
void ZLModAdsInstall(void);
void ZLModFeaturesInstall(void);
void ZLModSettingsInstall(void);
void ZLModGlassInstall(void);
void ZLModConversationMenuInstall(void);
void ZLModAntiRecallInstall(void);
void ZLModUtilitiesInstall(void);
void ZLModThemeInstall(void);

#pragma mark - Compatibility

@interface ZLModCompatibility : NSObject
+ (BOOL)hostSupported;
+ (NSString *)hostVersion;
+ (NSString *)supportReason;
+ (BOOL)anchorExists:(NSString *)className;
@end

#pragma mark - Dashboard UI

@interface ZLModSettingsViewController : UITableViewController
+ (instancetype)make;
/** Pushes the dashboard on the host's navigation controller (presents a wrapper if none). */
+ (void)pushFrom:(UIViewController *)host;
@end

#endif /* ZLMOD_H */
