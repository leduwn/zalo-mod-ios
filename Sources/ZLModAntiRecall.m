// language: Objective-C, file: ZLModAntiRecall.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Local-only Anti-Recall Ghost Preview with Keychain-backed AES-256-CBC + HMAC-SHA256
// storage, 14-day TTL pruning, account-scope isolation, and explicit local-copy labeling.
// Never mutates Zalo's SQLite database or ChatEntity.message property.

#import "ZLMod.h"
#import <os/lock.h>
#import <math.h>

NSString *const ZLModAntiRecallNoticePrefix = @"[ZLMod Bản sao cục bộ — tin nhắn gốc đã thu hồi]";

static const NSTimeInterval kZLModAntiRecallTTLSeconds = 14.0 * 86400.0;
static const NSUInteger kZLModMaxPersistedRecalls = 300;
static const NSUInteger kZLModMaxLiveSnapshots = 400;

@interface ZLModLiveMessageSnapshot : NSObject
@property (nonatomic, assign) int64_t globalId;
@property (nonatomic, assign) int64_t clientId;
@property (nonatomic, copy) NSString *accountScope;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSString *senderName;
@property (nonatomic, copy) NSString *senderId;
@property (nonatomic, copy) NSString *threadId;
@property (nonatomic, assign) NSTimeInterval timestamp;
@end

@implementation ZLModLiveMessageSnapshot
@end

@interface ZLModAntiRecallStore () {
    os_unfair_lock _lock;
}
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *records;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ZLModLiveMessageSnapshot *> *liveByKey;
@property (nonatomic, strong) NSMutableArray<NSString *> *liveOrder;
@property (nonatomic, copy) NSString *storagePath;
@end

@implementation ZLModAntiRecallStore

+ (instancetype)shared {
    static ZLModAntiRecallStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModAntiRecallStore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _records = [NSMutableDictionary dictionary];
        _liveByKey = [NSMutableDictionary dictionary];
        _liveOrder = [NSMutableArray array];

        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
        _storagePath = [docs stringByAppendingPathComponent:@"ZLModAntiRecall.plist"];

        [self loadFromDiskLocked];
        [self pruneExpiredLockedAndPersist:YES];

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            [self purgeLiveSnapshots];
            [self pruneExpiredEntries];
        }];

        [nc addObserverForName:UIApplicationWillTerminateNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            [self purgeLiveSnapshots];
        }];

        [nc addObserverForName:ZLModAccountDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            [self purgeLiveSnapshots];
        }];

        [nc addObserverForName:ZLModPrefsDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            if ([note.object isEqualToString:kZLModAntiRecall] || [note.object isEqualToString:@"*"]) {
                if (![[ZLModPreferences shared] boolForKey:kZLModAntiRecall]) {
                    [self purgeLiveSnapshots];
                }
            }
        }];
    }
    return self;
}

#pragma mark - Keys & metadata binding

+ (NSString *)primaryKeyForAccountScope:(NSString *)scope globalId:(int64_t)globalId clientId:(int64_t)clientId {
    if (scope.length == 0) return nil;
    if (globalId > 0) {
        return [NSString stringWithFormat:@"%@:g_%lld", scope, (long long)globalId];
    }
    if (clientId > 0) {
        return [NSString stringWithFormat:@"%@:c_%lld", scope, (long long)clientId];
    }
    return nil;
}

+ (NSData *)metadataForAccountScope:(NSString *)scope
                           globalId:(int64_t)globalId
                           clientId:(int64_t)clientId
                           threadId:(NSString *)threadId
                          timestamp:(NSTimeInterval)timestamp {
    NSMutableData *meta = [NSMutableData data];
    NSData *scopeData = [(scope ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (scopeData) [meta appendData:scopeData];

    uint64_t gidBE = CFSwapInt64HostToBig((uint64_t)globalId);
    uint64_t cidBE = CFSwapInt64HostToBig((uint64_t)clientId);
    int64_t quantizedTs = (int64_t)llround(timestamp);
    uint64_t tsBE = CFSwapInt64HostToBig((uint64_t)quantizedTs);

    [meta appendBytes:&gidBE length:sizeof(gidBE)];
    [meta appendBytes:&cidBE length:sizeof(cidBE)];
    [meta appendBytes:&tsBE length:sizeof(tsBE)];

    NSData *tidData = [(threadId ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (tidData) [meta appendData:tidData];
    return [meta copy];
}

#pragma mark - Disk persistence

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
        NSNumber *ver = plist[@"version"];
        NSDictionary *stored = plist[@"records"];
        if (![ver isKindOfClass:[NSNumber class]] || ver.integerValue != 2 ||
            ![stored isKindOfClass:[NSDictionary class]]) {
            return;
        }
        [stored enumerateKeysAndObjectsUsingBlock:^(id key, id obj, __unused BOOL *stop) {
            if ([key isKindOfClass:[NSString class]] && [obj isKindOfClass:[NSDictionary class]]) {
                self.records[(NSString *)key] = (NSDictionary *)obj;
            }
        }];
    } @catch (__unused NSException *e) {
        ZLMOD_LOG(@"antirecall: exception loading plist");
    }
}

- (BOOL)persistLocked {
    NSDictionary *root = @{
        @"version": @2,
        @"records": [self.records copy]
    };
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:root
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:&error];
    if (!data || error) return NO;
    return [data writeToFile:self.storagePath options:NSDataWritingAtomic error:&error];
}

- (void)pruneExpiredLockedAndPersist:(BOOL)shouldPersist {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSMutableArray<NSString *> *expiredKeys = [NSMutableArray array];

    [self.records enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, __unused BOOL *stop) {
        NSTimeInterval savedAt = [entry[@"savedAt"] doubleValue];
        if (savedAt <= 0 || (now - savedAt) > kZLModAntiRecallTTLSeconds) {
            [expiredKeys addObject:key];
        }
    }];

    BOOL mutated = NO;
    if (expiredKeys.count > 0) {
        [self.records removeObjectsForKeys:expiredKeys];
        mutated = YES;
    }

    if (self.records.count > kZLModMaxPersistedRecalls) {
        NSArray<NSString *> *sortedKeys = [self.records keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"savedAt"] compare:b[@"savedAt"]];
        }];
        NSUInteger excess = self.records.count - kZLModMaxPersistedRecalls;
        for (NSUInteger i = 0; i < excess && i < sortedKeys.count; i++) {
            [self.records removeObjectForKey:sortedKeys[i]];
        }
        mutated = YES;
    }

    if (mutated && shouldPersist) {
        [self persistLocked];
    }
}

- (void)pruneExpiredEntries {
    os_unfair_lock_lock(&_lock);
    [self pruneExpiredLockedAndPersist:YES];
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - Live in-memory snapshot cache (bounded, purged on disable/background)

- (void)purgeLiveSnapshots {
    os_unfair_lock_lock(&_lock);
    [self.liveByKey removeAllObjects];
    [self.liveOrder removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}

- (void)cacheLiveSnapshotWithGlobalId:(int64_t)globalId
                             clientId:(int64_t)clientId
                              message:(NSString *)message
                           senderName:(NSString *)senderName
                             senderId:(NSString *)senderId
                             threadId:(NSString *)threadId
                            timestamp:(NSTimeInterval)timestamp {
    if (![[ZLModPreferences shared] boolForKey:kZLModAntiRecall]) return;
    if (![message isKindOfClass:[NSString class]] || message.length == 0) return;
    if ([message hasPrefix:ZLModAntiRecallNoticePrefix]) return;

    NSString *scope = ZLModCurrentAccountScope();
    NSString *primaryKey = [[self class] primaryKeyForAccountScope:scope globalId:globalId clientId:clientId];
    if (!primaryKey) return;

    ZLModLiveMessageSnapshot *snap = [[ZLModLiveMessageSnapshot alloc] init];
    snap.globalId = globalId;
    snap.clientId = clientId;
    snap.accountScope = scope;
    snap.message = message;
    snap.senderName = senderName ?: @"";
    snap.senderId = senderId ?: @"";
    snap.threadId = threadId ?: @"";
    snap.timestamp = (timestamp > 0) ? timestamp : [[NSDate date] timeIntervalSince1970];

    os_unfair_lock_lock(&_lock);
    if (!self.liveByKey[primaryKey]) {
        [self.liveOrder addObject:primaryKey];
    }
    self.liveByKey[primaryKey] = snap;
    if (globalId > 0 && clientId > 0) {
        NSString *altKey = [NSString stringWithFormat:@"%@:c_%lld", scope, (long long)clientId];
        self.liveByKey[altKey] = snap;
    }
    while (self.liveOrder.count > kZLModMaxLiveSnapshots) {
        NSString *oldest = self.liveOrder.firstObject;
        [self.liveOrder removeObjectAtIndex:0];
        if (oldest) [self.liveByKey removeObjectForKey:oldest];
    }
    os_unfair_lock_unlock(&_lock);
}

- (ZLModLiveMessageSnapshot *)liveSnapshotForAccountScope:(NSString *)scope
                                                 globalId:(int64_t)globalId
                                                 clientId:(int64_t)clientId {
    if (scope.length == 0) return nil;
    os_unfair_lock_lock(&_lock);
    ZLModLiveMessageSnapshot *snap = nil;
    if (globalId > 0) {
        snap = self.liveByKey[[NSString stringWithFormat:@"%@:g_%lld", scope, (long long)globalId]];
    }
    if (!snap && clientId > 0) {
        snap = self.liveByKey[[NSString stringWithFormat:@"%@:c_%lld", scope, (long long)clientId]];
    }
    os_unfair_lock_unlock(&_lock);
    return snap;
}

#pragma mark - Encrypted recalled record persistence & lookup

- (BOOL)saveSnapshotWithGlobalId:(int64_t)globalId
                        clientId:(int64_t)clientId
                         message:(NSString *)message
                      senderName:(NSString *)senderName
                        senderId:(NSString *)senderId
                        threadId:(NSString *)threadId
                       timestamp:(NSTimeInterval)timestamp {
    if (![message isKindOfClass:[NSString class]] || message.length == 0) return NO;
    if ([message hasPrefix:ZLModAntiRecallNoticePrefix]) return NO;

    NSString *scope = ZLModCurrentAccountScope();
    NSString *key = [[self class] primaryKeyForAccountScope:scope globalId:globalId clientId:clientId];
    if (!key) return NO;

    NSTimeInterval effectiveTs = (timestamp > 0) ? timestamp : [[NSDate date] timeIntervalSince1970];
    int64_t quantizedTs = (int64_t)llround(effectiveTs);
    NSString *safeThread = threadId ?: @"";
    NSString *safeSender = (senderName.length > 0) ? senderName : @"Người gửi";

    NSString *payloadText = [NSString stringWithFormat:@"%@\n%@", safeSender, message];
    NSData *metadata = [[self class] metadataForAccountScope:scope
                                                    globalId:globalId
                                                    clientId:clientId
                                                    threadId:safeThread
                                                   timestamp:(NSTimeInterval)quantizedTs];
    NSData *cipher = [[ZLModCryptoBox shared] encryptString:payloadText metadata:metadata];
    if (!cipher) return NO;

    NSDictionary *record = @{
        @"accountScope": scope,
        @"globalId": @(globalId),
        @"clientId": @(clientId),
        @"threadId": safeThread,
        @"threadHash": ZLModSafeIdHash(safeThread),
        @"senderHash": ZLModSafeIdHash(senderId ?: @""),
        @"msgTimestamp": @(quantizedTs),
        @"savedAt": @([[NSDate date] timeIntervalSince1970]),
        @"cipher": cipher
    };

    BOOL saved = NO;
    os_unfair_lock_lock(&_lock);
    NSDictionary *prev = self.records[key];
    self.records[key] = record;
    [self pruneExpiredLockedAndPersist:NO];
    saved = [self persistLocked];
    if (!saved) {
        if (prev) {
            self.records[key] = prev;
        } else {
            [self.records removeObjectForKey:key];
        }
    }
    os_unfair_lock_unlock(&_lock);
    return saved;
}

- (NSDictionary *)recordLockedForAccountScope:(NSString *)scope
                                     globalId:(int64_t)globalId
                                     clientId:(int64_t)clientId {
    if (scope.length == 0) return nil;
    if (globalId > 0) {
        NSString *gKey = [NSString stringWithFormat:@"%@:g_%lld", scope, (long long)globalId];
        if (self.records[gKey]) return self.records[gKey];
    }
    if (clientId > 0) {
        NSString *cKey = [NSString stringWithFormat:@"%@:c_%lld", scope, (long long)clientId];
        if (self.records[cKey]) return self.records[cKey];
    }
    if (globalId > 0 || clientId > 0) {
        NSString *prefix = [scope stringByAppendingString:@":"];
        for (NSString *k in self.records) {
            if (![k hasPrefix:prefix]) continue;
            NSDictionary *rec = self.records[k];
            int64_t rGid = [rec[@"globalId"] longLongValue];
            int64_t rCid = [rec[@"clientId"] longLongValue];
            if ((globalId > 0 && rGid == globalId) || (clientId > 0 && rCid == clientId)) {
                return rec;
            }
        }
    }
    return nil;
}

- (NSString *)decryptMessageFromRecord:(NSDictionary *)record expectedScope:(NSString *)scope {
    if (!record || scope.length == 0) return nil;
    NSString *recScope = record[@"accountScope"];
    if (![recScope isKindOfClass:[NSString class]] || ![recScope isEqualToString:scope]) return nil;

    NSTimeInterval savedAt = [record[@"savedAt"] doubleValue];
    if (savedAt <= 0 || ([[NSDate date] timeIntervalSince1970] - savedAt) > kZLModAntiRecallTTLSeconds) {
        return nil;
    }

    NSData *cipher = record[@"cipher"];
    if (![cipher isKindOfClass:[NSData class]]) return nil;

    int64_t gid = [record[@"globalId"] longLongValue];
    int64_t cid = [record[@"clientId"] longLongValue];
    NSString *tid = [record[@"threadId"] isKindOfClass:[NSString class]] ? record[@"threadId"] : @"";
    NSTimeInterval msgTs = [record[@"msgTimestamp"] doubleValue];

    NSData *meta = [[self class] metadataForAccountScope:scope
                                                globalId:gid
                                                clientId:cid
                                                threadId:tid
                                               timestamp:msgTs];
    NSString *plain = [[ZLModCryptoBox shared] decryptData:cipher metadata:meta];
    if (!plain || plain.length == 0) return nil;

    NSRange nl = [plain rangeOfString:@"\n"];
    if (nl.location == NSNotFound) return plain;
    return [plain substringFromIndex:nl.location + 1];
}

- (NSString *)recalledTextForGlobalId:(int64_t)globalId clientId:(int64_t)clientId {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return nil;

    os_unfair_lock_lock(&_lock);
    NSDictionary *rec = [self recordLockedForAccountScope:scope globalId:globalId clientId:clientId];
    os_unfair_lock_unlock(&_lock);

    return [self decryptMessageFromRecord:rec expectedScope:scope];
}

- (NSString *)formattedNoticeForGlobalId:(int64_t)globalId clientId:(int64_t)clientId {
    NSString *text = [self recalledTextForGlobalId:globalId clientId:clientId];
    if (text.length == 0) return nil;
    return [NSString stringWithFormat:@"%@ %@", ZLModAntiRecallNoticePrefix, text];
}

#pragma mark - History inspection & clearing

- (NSArray<NSDictionary<NSString *, id> *> *)entriesForCurrentAccount {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return @[];
    NSString *prefix = [scope stringByAppendingString:@":"];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    NSMutableArray<NSDictionary<NSString *, id> *> *list = [NSMutableArray array];
    os_unfair_lock_lock(&_lock);
    [self.records enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *rec, __unused BOOL *stop) {
        if (![key hasPrefix:prefix]) return;
        NSTimeInterval savedAt = [rec[@"savedAt"] doubleValue];
        if (savedAt <= 0 || (now - savedAt) > kZLModAntiRecallTTLSeconds) return;
        [list addObject:@{
            @"key": key,
            @"globalId": rec[@"globalId"] ?: @0,
            @"clientId": rec[@"clientId"] ?: @0,
            @"threadHash": rec[@"threadHash"] ?: @"none",
            @"senderHash": rec[@"senderHash"] ?: @"none",
            @"savedAt": @(savedAt),
            @"msgTimestamp": rec[@"msgTimestamp"] ?: @(savedAt)
        }];
    }];
    os_unfair_lock_unlock(&_lock);

    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"savedAt"] compare:a[@"savedAt"]];
    }];
    return [list copy];
}

- (NSString *)revealTextForEntryKey:(NSString *)entryKey {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0 || entryKey.length == 0) return nil;
    NSString *prefix = [scope stringByAppendingString:@":"];
    if (![entryKey hasPrefix:prefix]) return nil;

    os_unfair_lock_lock(&_lock);
    NSDictionary *rec = self.records[entryKey];
    os_unfair_lock_unlock(&_lock);
    if (!rec) return nil;

    int64_t gid = [rec[@"globalId"] longLongValue];
    int64_t cid = [rec[@"clientId"] longLongValue];
    NSString *tid = [rec[@"threadId"] isKindOfClass:[NSString class]] ? rec[@"threadId"] : @"";
    NSTimeInterval msgTs = [rec[@"msgTimestamp"] doubleValue];
    NSData *cipher = rec[@"cipher"];
    if (![cipher isKindOfClass:[NSData class]]) return nil;

    NSData *meta = [[self class] metadataForAccountScope:scope
                                                globalId:gid
                                                clientId:cid
                                                threadId:tid
                                               timestamp:msgTs];
    NSString *plain = [[ZLModCryptoBox shared] decryptData:cipher metadata:meta];
    if (!plain || plain.length == 0) return nil;

    NSRange nl = [plain rangeOfString:@"\n"];
    if (nl.location == NSNotFound) {
        return [NSString stringWithFormat:@"%@\n%@", ZLModAntiRecallNoticePrefix, plain];
    }
    NSString *sender = [plain substringToIndex:nl.location];
    NSString *body = [plain substringFromIndex:nl.location + 1];
    return [NSString stringWithFormat:@"%@\nNgười gửi: %@\nNội dung: %@",
            ZLModAntiRecallNoticePrefix, sender, body];
}

- (NSUInteger)preservedCountForCurrentAccount {
    return [self entriesForCurrentAccount].count;
}

- (void)clearCurrentAccountHistory {
    [self purgeLiveSnapshots];
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return;
    NSString *prefix = [scope stringByAppendingString:@":"];

    os_unfair_lock_lock(&_lock);
    NSMutableArray<NSString *> *toRemove = [NSMutableArray array];
    for (NSString *k in self.records) {
        if ([k hasPrefix:prefix]) [toRemove addObject:k];
    }
    if (toRemove.count > 0) {
        [self.records removeObjectsForKeys:toRemove];
        [self persistLocked];
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)clearAllHistory {
    [self purgeLiveSnapshots];
    os_unfair_lock_lock(&_lock);
    [self.records removeAllObjects];
    [[NSFileManager defaultManager] removeItemAtPath:self.storagePath error:nil];
    os_unfair_lock_unlock(&_lock);
    ZLMOD_LOG(@"antirecall: all local history cleared");
}

@end

#pragma mark - ChatEntity inspection & runtime hooks

static void ZLModExtractChatEntityFields(id chatEntity,
                                         NSString *fallbackThreadId,
                                         int64_t *outGlobalId,
                                         int64_t *outClientId,
                                         NSString **outMessage,
                                         NSString **outSenderName,
                                         NSString **outSenderId,
                                         NSString **outThreadId,
                                         NSTimeInterval *outTimestamp) {
    int64_t gid = ZLModSafeInt64Property(chatEntity, sel_registerName("globalId"), 0);
    int64_t cid = ZLModSafeInt64Property(chatEntity, sel_registerName("clientId"), 0);
    NSString *msg = ZLModSafeStringProperty(chatEntity, sel_registerName("message"));
    NSString *senderName = ZLModSafeStringProperty(chatEntity, sel_registerName("displayname"));
    NSString *senderId = ZLModSafeStringProperty(chatEntity, sel_registerName("fuid"));
    NSString *tid = ZLModSafeStringProperty(chatEntity, sel_registerName("threadId"));
    if (tid.length == 0) {
        tid = ZLModSafeStringProperty(chatEntity, sel_registerName("tuid"));
    }
    if (tid.length == 0) {
        tid = fallbackThreadId;
    }
    NSTimeInterval ts = ZLModSafeDoubleProperty(chatEntity, sel_registerName("time"), 0.0);
    if (ts > 100000000000.0) {
        ts /= 1000.0; // normalize ms to seconds if needed
    }

    if (outGlobalId) *outGlobalId = gid;
    if (outClientId) *outClientId = cid;
    if (outMessage) *outMessage = msg;
    if (outSenderName) *outSenderName = senderName;
    if (outSenderId) *outSenderId = senderId;
    if (outThreadId) *outThreadId = tid;
    if (outTimestamp) *outTimestamp = ts;
}

static void ZLModEnumerateChatEntities(id container, void (^block)(id entity)) {
    if (!container || !block) return;
    if ([container isKindOfClass:[NSArray class]] || [container isKindOfClass:[NSSet class]]) {
        for (id item in container) {
            block(item);
        }
        return;
    }
    if ([container isKindOfClass:[NSDictionary class]]) {
        [(NSDictionary *)container enumerateKeysAndObjectsUsingBlock:^(__unused id key, id obj, __unused BOOL *stop) {
            if ([obj isKindOfClass:[NSArray class]]) {
                for (id sub in (NSArray *)obj) block(sub);
            } else {
                block(obj);
            }
        }];
        return;
    }
    block(container);
}

static void ZLModSnapshotEntities(id container, NSString *fallbackThreadId) {
    ZLModEnumerateChatEntities(container, ^(id entity) {
        int64_t gid = 0, cid = 0;
        NSString *msg = nil, *sName = nil, *sId = nil, *tid = nil;
        NSTimeInterval ts = 0;
        ZLModExtractChatEntityFields(entity, fallbackThreadId, &gid, &cid, &msg, &sName, &sId, &tid, &ts);
        if ((gid > 0 || cid > 0) && msg.length > 0 && ![msg hasPrefix:ZLModAntiRecallNoticePrefix] &&
            ![msg hasPrefix:@"Tin nhắn đã được thu hồi"]) {
            [[ZLModAntiRecallStore shared] cacheLiveSnapshotWithGlobalId:gid
                                                                clientId:cid
                                                                 message:msg
                                                              senderName:sName
                                                                senderId:sId
                                                                threadId:tid
                                                               timestamp:ts];
        }
    });
}

void ZLModAntiRecallInstall(void) {
    NSUInteger installed = 0;

    Class convModelCls = NSClassFromString(@"ConversationModel");
    if (convModelCls) {
        // 1. ConversationModel -didLoadChats:config: [v32@0:8@16@24]
        SEL didLoadSel = sel_registerName("didLoadChats:config:");
        if (ZLModClassHasInstanceMethod(convModelCls, didLoadSel)) {
            IMP orig = class_getMethodImplementation(convModelCls, didLoadSel);
            if (ZLModReplaceMethod(convModelCls, didLoadSel, 2, "v", ^(id selfObj, id chats, id config) {
                if ([[ZLModPreferences shared] boolForKey:kZLModAntiRecall] && chats) {
                    NSString *convTid = ZLModSafeStringProperty(selfObj, sel_registerName("threadId"));
                    ZLModSnapshotEntities(chats, convTid);
                }
                if (orig) ((void (*)(id, SEL, id, id))orig)(selfObj, didLoadSel, chats, config);
            })) {
                installed++;
            }
        }

        // 2. ConversationModel -updateDBWhenRecalledChats:completion: [v32@0:8@16@?24]
        SEL recallSel = sel_registerName("updateDBWhenRecalledChats:completion:");
        if (ZLModClassHasInstanceMethod(convModelCls, recallSel)) {
            IMP orig = class_getMethodImplementation(convModelCls, recallSel);
            if (ZLModReplaceMethod(convModelCls, recallSel, 2, "v", ^(id selfObj, id recalledChats, id completion) {
                if ([[ZLModPreferences shared] boolForKey:kZLModAntiRecall] && recalledChats) {
                    NSString *scope = ZLModCurrentAccountScope();
                    NSString *convTid = ZLModSafeStringProperty(selfObj, sel_registerName("threadId"));
                    ZLModAntiRecallStore *store = [ZLModAntiRecallStore shared];

                    ZLModEnumerateChatEntities(recalledChats, ^(id entity) {
                        int64_t gid = 0, cid = 0;
                        NSString *msg = nil, *sName = nil, *sId = nil, *tid = nil;
                        NSTimeInterval ts = 0;
                        ZLModExtractChatEntityFields(entity, convTid, &gid, &cid, &msg, &sName, &sId, &tid, &ts);

                        ZLModLiveMessageSnapshot *cached = [store liveSnapshotForAccountScope:scope globalId:gid clientId:cid];
                        if (cached) {
                            // The entity may already carry Zalo's recalled placeholder; the
                            // pre-recall snapshot is always the authoritative original text.
                            if (cached.message.length > 0) msg = cached.message;
                            if (sName.length == 0) sName = cached.senderName;
                            if (sId.length == 0) sId = cached.senderId;
                            if (tid.length == 0) tid = cached.threadId;
                            if (ts <= 0) ts = cached.timestamp;
                        }
                        BOOL looksRecalled = (!cached &&
                            ([msg localizedCaseInsensitiveContainsString:@"thu hồi"] ||
                             [msg localizedCaseInsensitiveContainsString:@"recalled"]));
                        if ((gid > 0 || cid > 0) && msg.length > 0 && !looksRecalled) {
                            [store saveSnapshotWithGlobalId:gid
                                                   clientId:cid
                                                    message:msg
                                                 senderName:sName
                                                   senderId:sId
                                                   threadId:tid
                                                  timestamp:ts];
                        }
                    });
                }
                if (orig) ((void (*)(id, SEL, id, id))orig)(selfObj, recallSel, recalledChats, completion);
            })) {
                installed++;
            }
        }
    }

    // 2b. ChatDataManager incoming-message entry points. Messages that arrive while the
    // app is running never pass through didLoadChats:, so the original text must be
    // snapshotted here, before any later recall rewrites the entity.
    Class chatMgrCls = NSClassFromString(@"ChatDataManager");
    if (chatMgrCls) {
        // -addChats:byUserId:willAlert:fromSrc: [v44@0:8@16@24B32q36]
        SEL addChatsSel = sel_registerName("addChats:byUserId:willAlert:fromSrc:");
        if (ZLModClassHasInstanceMethod(chatMgrCls, addChatsSel)) {
            IMP orig = class_getMethodImplementation(chatMgrCls, addChatsSel);
            if (ZLModReplaceMethod(chatMgrCls, addChatsSel, 4, "v",
                                   ^(id selfObj, id chats, id userId, BOOL willAlert, NSInteger src) {
                if ([[ZLModPreferences shared] boolForKey:kZLModAntiRecall] && chats) {
                    ZLModSnapshotEntities(chats, nil);
                }
                if (orig) ((void (*)(id, SEL, id, id, BOOL, NSInteger))orig)(selfObj, addChatsSel, chats, userId, willAlert, src);
            })) {
                installed++;
            }
        }

        // -addChat:byUserId:willAlert:fromSrc: [v44@0:8@16@24B32q36]
        SEL addChatSel = sel_registerName("addChat:byUserId:willAlert:fromSrc:");
        if (ZLModClassHasInstanceMethod(chatMgrCls, addChatSel)) {
            IMP orig = class_getMethodImplementation(chatMgrCls, addChatSel);
            if (ZLModReplaceMethod(chatMgrCls, addChatSel, 4, "v",
                                   ^(id selfObj, id chat, id userId, BOOL willAlert, NSInteger src) {
                if ([[ZLModPreferences shared] boolForKey:kZLModAntiRecall] && chat) {
                    ZLModSnapshotEntities(chat, nil);
                }
                if (orig) ((void (*)(id, SEL, id, id, BOOL, NSInteger))orig)(selfObj, addChatSel, chat, userId, willAlert, src);
            })) {
                installed++;
            }
        }
    }

    // 3. ChatEntity -_getRecalledMsgPreviewFromSource: [@24@0:8q16]
    Class chatEntityCls = NSClassFromString(@"ChatEntity");
    if (chatEntityCls) {
        SEL previewSel = sel_registerName("_getRecalledMsgPreviewFromSource:");
        if (ZLModClassHasInstanceMethod(chatEntityCls, previewSel)) {
            IMP orig = class_getMethodImplementation(chatEntityCls, previewSel);
            if (ZLModReplaceMethod(chatEntityCls, previewSel, 1, "@", ^id(id selfObj, NSInteger source) {
                id origPreview = orig ? ((id (*)(id, SEL, NSInteger))orig)(selfObj, previewSel, source) : nil;
                if (![[ZLModPreferences shared] boolForKey:kZLModAntiRecall]) {
                    return origPreview;
                }
                int64_t gid = ZLModSafeInt64Property(selfObj, sel_registerName("globalId"), 0);
                int64_t cid = ZLModSafeInt64Property(selfObj, sel_registerName("clientId"), 0);
                if (gid <= 0 && cid <= 0) return origPreview;

                NSString *notice = [[ZLModAntiRecallStore shared] formattedNoticeForGlobalId:gid clientId:cid];
                return (notice.length > 0) ? notice : origPreview;
            })) {
                installed++;
            }
        }
    }

    ZLModSetModuleStatus(@"AntiRecall",
                         (installed >= 2) ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"hooks=%lu", (unsigned long)installed]);
    ZLMOD_LOG(@"anti-recall installed (hooks=%lu)", (unsigned long)installed);
}
