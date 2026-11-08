// language: Objective-C, file: ZLModPolicyStore.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Active chat context tracker and per-conversation policy persistence
// scoped by verified accountScope (fail-closed when unidentified).

#import "ZLMod.h"
#import <os/lock.h>

NSString *const ZLModConversationPolicyDidChangeNotification = @"ZLModConversationPolicyDidChangeNotification";
NSString *const ZLModPolicyThreadIdKey = @"threadId";

#pragma mark - ZLModPrivacyContext

static os_unfair_lock gPrivacyCtxLock = OS_UNFAIR_LOCK_INIT;
static __weak id gActiveChatController = nil;
static NSString *gActiveThreadId = nil;
static NSString *gActiveConvType = nil;

@implementation ZLModPrivacyContext

+ (void)noteChatControllerDidAppear:(id)controller
                           threadId:(NSString *)threadId
                   conversationType:(NSString *)convType {
    if (!controller) return;
    NSString *cleanThread = ([threadId isKindOfClass:[NSString class]] && threadId.length > 0) ? [threadId copy] : nil;
    NSString *cleanType = [convType isEqualToString:@"group"] ? @"group" : @"single";

    os_unfair_lock_lock(&gPrivacyCtxLock);
    gActiveChatController = controller;
    gActiveThreadId = cleanThread;
    gActiveConvType = cleanType;
    os_unfair_lock_unlock(&gPrivacyCtxLock);
}

+ (void)noteChatControllerWillDisappear:(id)controller {
    os_unfair_lock_lock(&gPrivacyCtxLock);
    id current = gActiveChatController;
    if (!controller || current == nil || current == controller) {
        gActiveChatController = nil;
        gActiveThreadId = nil;
        gActiveConvType = nil;
    }
    os_unfair_lock_unlock(&gPrivacyCtxLock);
}

+ (id)activeChatController {
    os_unfair_lock_lock(&gPrivacyCtxLock);
    id controller = gActiveChatController;
    os_unfair_lock_unlock(&gPrivacyCtxLock);
    return controller;
}

+ (NSString *)activeThreadId {
    os_unfair_lock_lock(&gPrivacyCtxLock);
    NSString *tid = gActiveThreadId;
    os_unfair_lock_unlock(&gPrivacyCtxLock);
    return tid;
}

+ (NSString *)activeConversationType {
    os_unfair_lock_lock(&gPrivacyCtxLock);
    NSString *ct = gActiveConvType;
    os_unfair_lock_unlock(&gPrivacyCtxLock);
    return ct;
}

+ (void)clearActiveContext {
    os_unfair_lock_lock(&gPrivacyCtxLock);
    gActiveChatController = nil;
    gActiveThreadId = nil;
    gActiveConvType = nil;
    os_unfair_lock_unlock(&gPrivacyCtxLock);
}

@end

#pragma mark - ZLModConversationPolicyStore

@interface ZLModConversationPolicyStore () {
    os_unfair_lock _lock;
}
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *policies;
@property (nonatomic, copy) NSString *storagePath;
@end

@implementation ZLModConversationPolicyStore

+ (instancetype)shared {
    static ZLModConversationPolicyStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModConversationPolicyStore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _policies = [NSMutableDictionary dictionary];

        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
        _storagePath = [docs stringByAppendingPathComponent:@"ZLModPolicies.plist"];

        [self loadFromDiskLocked];

        [[NSNotificationCenter defaultCenter] addObserverForName:ZLModAccountDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            [ZLModPrivacyContext clearActiveContext];
            [[NSNotificationCenter defaultCenter] postNotificationName:ZLModConversationPolicyDidChangeNotification
                                                                object:nil
                                                              userInfo:nil];
        }];
    }
    return self;
}

+ (NSString *)normalizedType:(NSString *)convType {
    if ([convType isEqualToString:@"group"]) return @"group";
    return @"single";
}

+ (NSString *)compoundKeyForAccountScope:(NSString *)accountScope
                        conversationType:(NSString *)convType
                                threadId:(NSString *)threadId {
    if (![accountScope isKindOfClass:[NSString class]] || accountScope.length == 0) return nil;
    if (![threadId isKindOfClass:[NSString class]] || threadId.length == 0) return nil;
    return [NSString stringWithFormat:@"%@:%@:%@", accountScope, [self normalizedType:convType], threadId];
}

- (void)loadFromDiskLocked {
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.storagePath]) return;
    @try {
        NSData *data = [NSData dataWithContentsOfFile:self.storagePath];
        if (!data) return;
        id plist = [NSPropertyListSerialization propertyListWithData:data
                                                             options:NSPropertyListImmutable
                                                              format:NULL
                                                               error:nil];
        if (![plist isKindOfClass:[NSDictionary class]]) return;
        NSNumber *version = plist[@"version"];
        NSDictionary *rawPolicies = plist[@"policies"];
        if (![version isKindOfClass:[NSNumber class]] || version.integerValue != 2 ||
            ![rawPolicies isKindOfClass:[NSDictionary class]]) {
            return;
        }
        [rawPolicies enumerateKeysAndObjectsUsingBlock:^(id key, id obj, __unused BOOL *stop) {
            if ([key isKindOfClass:[NSString class]] && [obj isKindOfClass:[NSDictionary class]]) {
                self.policies[(NSString *)key] = [(NSDictionary *)obj mutableCopy];
            }
        }];
    } @catch (__unused NSException *e) {
        ZLMOD_LOG(@"policy store: exception loading plist");
    }
}

- (BOOL)persistLocked {
    NSMutableDictionary *serializedPolicies = [NSMutableDictionary dictionaryWithCapacity:self.policies.count];
    [self.policies enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSMutableDictionary *val, __unused BOOL *stop) {
        serializedPolicies[key] = [val copy];
    }];
    NSDictionary *root = @{
        @"version": @2,
        @"policies": serializedPolicies
    };
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:root
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:&error];
    if (!data || error) {
        ZLMOD_LOG(@"policy store: serialization failed (%@)", error.localizedDescription ?: @"unknown");
        return NO;
    }
    BOOL written = [data writeToFile:self.storagePath options:NSDataWritingAtomic error:&error];
    if (!written) {
        ZLMOD_LOG(@"policy store: atomic write failed (%@)", error.localizedDescription ?: @"unknown");
    }
    return written;
}

- (NSMutableDictionary *)entryLockedForAccountScope:(NSString *)accountScope
                                   conversationType:(NSString *)convType
                                           threadId:(NSString *)threadId {
    NSString *key = [[self class] compoundKeyForAccountScope:accountScope conversationType:convType threadId:threadId];
    if (!key) return nil;
    return self.policies[key];
}

- (BOOL)updateField:(NSString *)field
              value:(id)value
    forAccountScope:(NSString *)accountScope
   conversationType:(NSString *)convType
           threadId:(NSString *)threadId {
    NSString *key = [[self class] compoundKeyForAccountScope:accountScope conversationType:convType threadId:threadId];
    if (!key) return NO;

    BOOL saved = NO;
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *previousEntry = self.policies[key] ? [self.policies[key] mutableCopy] : nil;
    NSMutableDictionary *entry = previousEntry ? [previousEntry mutableCopy] : [NSMutableDictionary dictionary];
    entry[field] = value;
    entry[@"convType"] = [[self class] normalizedType:convType];
    entry[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]);

    BOOL allDefault = ([entry[@"seen"] integerValue] == 0 &&
                       [entry[@"typing"] integerValue] == 0 &&
                       ![entry[@"unread"] boolValue]);
    if (allDefault) {
        [self.policies removeObjectForKey:key];
    } else {
        self.policies[key] = entry;
    }

    saved = [self persistLocked];
    if (!saved) {
        if (previousEntry) {
            self.policies[key] = previousEntry;
        } else {
            [self.policies removeObjectForKey:key];
        }
    }
    os_unfair_lock_unlock(&_lock);

    if (saved) {
        [self postPolicyDidChangeForThreadId:threadId];
    }
    return saved;
}

- (void)postPolicyDidChangeForThreadId:(NSString *)threadId {
    NSDictionary *info = (threadId.length > 0) ? @{ ZLModPolicyThreadIdKey: [threadId copy] } : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ZLModConversationPolicyDidChangeNotification
                                                            object:nil
                                                          userInfo:info];
    });
}

#pragma mark - Seen policy

- (ZLModSeenPolicy)seenPolicyForAccountScope:(NSString *)accountScope
                             conversationType:(NSString *)convType
                                     threadId:(NSString *)threadId {
    if (accountScope.length == 0 || threadId.length == 0) return ZLModSeenPolicyFollowOriginal;
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *entry = [self entryLockedForAccountScope:accountScope conversationType:convType threadId:threadId];
    NSInteger raw = entry ? [entry[@"seen"] integerValue] : ZLModSeenPolicyFollowOriginal;
    os_unfair_lock_unlock(&_lock);
    return (raw == ZLModSeenPolicyHideSeen) ? ZLModSeenPolicyHideSeen : ZLModSeenPolicyFollowOriginal;
}

- (BOOL)setSeenPolicy:(ZLModSeenPolicy)policy
      forAccountScope:(NSString *)accountScope
     conversationType:(NSString *)convType
             threadId:(NSString *)threadId {
    return [self updateField:@"seen"
                       value:@(policy)
             forAccountScope:accountScope
            conversationType:convType
                    threadId:threadId];
}

- (BOOL)isHideSeenForThreadId:(NSString *)threadId conversationType:(NSString *)convType {
    if (threadId.length == 0) return NO;
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return NO;

    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *exact = (convType.length > 0)
        ? [self entryLockedForAccountScope:scope conversationType:convType threadId:threadId]
        : nil;
    BOOL hide = NO;
    if (exact) {
        hide = ([exact[@"seen"] integerValue] == ZLModSeenPolicyHideSeen);
    } else if (convType.length == 0) {
        NSMutableDictionary *s = [self entryLockedForAccountScope:scope conversationType:@"single" threadId:threadId];
        NSMutableDictionary *g = [self entryLockedForAccountScope:scope conversationType:@"group" threadId:threadId];
        hide = ([s[@"seen"] integerValue] == ZLModSeenPolicyHideSeen) ||
               ([g[@"seen"] integerValue] == ZLModSeenPolicyHideSeen);
    } else {
        NSString *alt = [[self class] normalizedType:convType];
        NSString *other = [alt isEqualToString:@"group"] ? @"single" : @"group";
        NSMutableDictionary *fallback = [self entryLockedForAccountScope:scope conversationType:other threadId:threadId];
        hide = fallback ? ([fallback[@"seen"] integerValue] == ZLModSeenPolicyHideSeen) : NO;
    }
    os_unfair_lock_unlock(&_lock);
    return hide;
}

#pragma mark - Typing policy

- (ZLModTypingPolicy)typingPolicyForAccountScope:(NSString *)accountScope
                                 conversationType:(NSString *)convType
                                         threadId:(NSString *)threadId {
    if (accountScope.length == 0 || threadId.length == 0) return ZLModTypingPolicyFollowOriginal;
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *entry = [self entryLockedForAccountScope:accountScope conversationType:convType threadId:threadId];
    NSInteger raw = entry ? [entry[@"typing"] integerValue] : ZLModTypingPolicyFollowOriginal;
    os_unfair_lock_unlock(&_lock);
    return (raw == ZLModTypingPolicyHideTyping) ? ZLModTypingPolicyHideTyping : ZLModTypingPolicyFollowOriginal;
}

- (BOOL)setTypingPolicy:(ZLModTypingPolicy)policy
        forAccountScope:(NSString *)accountScope
       conversationType:(NSString *)convType
               threadId:(NSString *)threadId {
    return [self updateField:@"typing"
                       value:@(policy)
             forAccountScope:accountScope
            conversationType:convType
                    threadId:threadId];
}

- (BOOL)isHideTypingForThreadId:(NSString *)threadId conversationType:(NSString *)convType {
    if (threadId.length == 0) return NO;
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return NO;

    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *exact = (convType.length > 0)
        ? [self entryLockedForAccountScope:scope conversationType:convType threadId:threadId]
        : nil;
    BOOL hide = NO;
    if (exact) {
        hide = ([exact[@"typing"] integerValue] == ZLModTypingPolicyHideTyping);
    } else if (convType.length == 0) {
        NSMutableDictionary *s = [self entryLockedForAccountScope:scope conversationType:@"single" threadId:threadId];
        NSMutableDictionary *g = [self entryLockedForAccountScope:scope conversationType:@"group" threadId:threadId];
        hide = ([s[@"typing"] integerValue] == ZLModTypingPolicyHideTyping) ||
               ([g[@"typing"] integerValue] == ZLModTypingPolicyHideTyping);
    } else {
        NSString *alt = [[self class] normalizedType:convType];
        NSString *other = [alt isEqualToString:@"group"] ? @"single" : @"group";
        NSMutableDictionary *fallback = [self entryLockedForAccountScope:scope conversationType:other threadId:threadId];
        hide = fallback ? ([fallback[@"typing"] integerValue] == ZLModTypingPolicyHideTyping) : NO;
    }
    os_unfair_lock_unlock(&_lock);
    return hide;
}

#pragma mark - Local unread mark

- (BOOL)isLocalUnreadForAccountScope:(NSString *)accountScope
                     conversationType:(NSString *)convType
                             threadId:(NSString *)threadId {
    if (accountScope.length == 0 || threadId.length == 0) return NO;
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *entry = [self entryLockedForAccountScope:accountScope conversationType:convType threadId:threadId];
    BOOL unread = entry ? [entry[@"unread"] boolValue] : NO;
    os_unfair_lock_unlock(&_lock);
    return unread;
}

- (BOOL)setLocalUnread:(BOOL)marked
       forAccountScope:(NSString *)accountScope
      conversationType:(NSString *)convType
              threadId:(NSString *)threadId {
    return [self updateField:@"unread"
                       value:@(marked)
             forAccountScope:accountScope
            conversationType:convType
                    threadId:threadId];
}

- (BOOL)isLocalUnreadAnyTypeForThreadId:(NSString *)threadId {
    if (threadId.length == 0) return NO;
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return NO;

    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *s = [self entryLockedForAccountScope:scope conversationType:@"single" threadId:threadId];
    NSMutableDictionary *g = [self entryLockedForAccountScope:scope conversationType:@"group" threadId:threadId];
    BOOL marked = (s && [s[@"unread"] boolValue]) || (g && [g[@"unread"] boolValue]);
    os_unfair_lock_unlock(&_lock);
    return marked;
}

#pragma mark - Inspection & reset

- (NSArray<NSDictionary<NSString *, id> *> *)summaryEntriesForCurrentAccount {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return @[];
    NSString *prefix = [scope stringByAppendingString:@":"];

    NSMutableArray<NSDictionary<NSString *, id> *> *rows = [NSMutableArray array];
    os_unfair_lock_lock(&_lock);
    [self.policies enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSMutableDictionary *entry, __unused BOOL *stop) {
        if (![key hasPrefix:prefix]) return;
        NSString *rest = [key substringFromIndex:prefix.length];
        NSRange colon = [rest rangeOfString:@":"];
        if (colon.location == NSNotFound) return;
        NSString *convType = [rest substringToIndex:colon.location];
        NSString *threadId = [rest substringFromIndex:colon.location + 1];

        BOOL hideSeen = ([entry[@"seen"] integerValue] == ZLModSeenPolicyHideSeen);
        BOOL hideTyping = ([entry[@"typing"] integerValue] == ZLModTypingPolicyHideTyping);
        BOOL localUnread = [entry[@"unread"] boolValue];
        if (!hideSeen && !hideTyping && !localUnread) return;

        [rows addObject:@{
            @"key": key,
            @"convType": convType,
            @"threadHash": ZLModSafeIdHash(threadId),
            @"hideSeen": @(hideSeen),
            @"hideTyping": @(hideTyping),
            @"localUnread": @(localUnread),
            @"updatedAt": entry[@"updatedAt"] ?: @0
        }];
    }];
    os_unfair_lock_unlock(&_lock);

    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"updatedAt"] compare:a[@"updatedAt"]];
    }];
    return [rows copy];
}

- (NSUInteger)customizedCountForCurrentAccount {
    return [self summaryEntriesForCurrentAccount].count;
}

- (BOOL)resetPolicyAtCompoundKey:(NSString *)compoundKey {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0 || compoundKey.length == 0) return NO;
    NSString *prefix = [scope stringByAppendingString:@":"];
    if (![compoundKey hasPrefix:prefix]) return NO; // fail-closed cross-account guard

    BOOL saved = NO;
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *prev = self.policies[compoundKey];
    if (prev) {
        [self.policies removeObjectForKey:compoundKey];
        saved = [self persistLocked];
        if (!saved) {
            self.policies[compoundKey] = prev;
        }
    }
    os_unfair_lock_unlock(&_lock);

    if (saved) {
        [self postPolicyDidChangeForThreadId:nil];
    }
    return saved;
}

- (NSUInteger)resetPoliciesForCurrentAccount {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return 0;
    NSString *prefix = [scope stringByAppendingString:@":"];

    NSUInteger removedCount = 0;
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *backup = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *toRemove = [NSMutableArray array];
    for (NSString *key in self.policies) {
        if ([key hasPrefix:prefix]) {
            [toRemove addObject:key];
            backup[key] = self.policies[key];
        }
    }
    if (toRemove.count > 0) {
        [self.policies removeObjectsForKeys:toRemove];
        if ([self persistLocked]) {
            removedCount = toRemove.count;
        } else {
            [self.policies addEntriesFromDictionary:backup];
        }
    }
    os_unfair_lock_unlock(&_lock);

    if (removedCount > 0) {
        [self postPolicyDidChangeForThreadId:nil];
    }
    return removedCount;
}

- (void)resetAllPolicies {
    os_unfair_lock_lock(&_lock);
    [self.policies removeAllObjects];
    [[NSFileManager defaultManager] removeItemAtPath:self.storagePath error:nil];
    os_unfair_lock_unlock(&_lock);
    [self postPolicyDidChangeForThreadId:nil];
    ZLMOD_LOG(@"policy store: all policies reset");
}

@end
