// language: Objective-C, file: ZLModUtilities.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Encrypted Private Notes per conversation, Quick Reply templates with safe
// composer insertion (never auto-sends), and 5-state atomic Delay Send Undo
// manager hooking ZAChatSendingManager -sendChat:checkUpload:.

#import "ZLMod.h"
#import <os/lock.h>

static const NSInteger kZLModUndoBannerTag = 0x5A1E;
static const void *kZLModDelaySendBypassAssocKey = &kZLModDelaySendBypassAssocKey;
static const void *kZLModUndoButtonSendIdAssocKey = &kZLModUndoButtonSendIdAssocKey;

#pragma mark - 1. ZLModPrivateNotesStore (Encrypted per-conversation notes)

@interface ZLModPrivateNotesStore () {
    os_unfair_lock _lock;
}
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *records;
@property (nonatomic, copy) NSString *storagePath;
@end

@implementation ZLModPrivateNotesStore

+ (instancetype)shared {
    static ZLModPrivateNotesStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModPrivateNotesStore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _records = [NSMutableDictionary dictionary];

        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
        _storagePath = [docs stringByAppendingPathComponent:@"ZLModNotes.plist"];

        [self loadFromDiskLocked];
    }
    return self;
}

+ (NSString *)compoundKeyForAccountScope:(NSString *)scope threadId:(NSString *)threadId {
    if (scope.length == 0 || threadId.length == 0) return nil;
    return [NSString stringWithFormat:@"%@:%@", scope, threadId];
}

+ (NSData *)metadataForAccountScope:(NSString *)scope threadId:(NSString *)threadId {
    NSString *bound = [NSString stringWithFormat:@"ZLModNote.v2|%@|%@", scope ?: @"", threadId ?: @""];
    return [bound dataUsingEncoding:NSUTF8StringEncoding];
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
        ZLMOD_LOG(@"notes: exception loading plist");
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

- (NSString *)noteForThreadId:(NSString *)threadId {
    NSString *scope = ZLModCurrentAccountScope();
    NSString *key = [[self class] compoundKeyForAccountScope:scope threadId:threadId];
    if (!key) return nil;

    os_unfair_lock_lock(&_lock);
    NSDictionary *rec = self.records[key];
    os_unfair_lock_unlock(&_lock);
    if (!rec) return nil;

    NSData *cipher = rec[@"cipher"];
    if (![cipher isKindOfClass:[NSData class]]) return nil;
    NSData *meta = [[self class] metadataForAccountScope:scope threadId:threadId];
    return [[ZLModCryptoBox shared] decryptData:cipher metadata:meta];
}

- (BOOL)setNote:(NSString *)note forThreadId:(NSString *)threadId {
    NSString *trimmed = [note isKindOfClass:[NSString class]]
        ? [note stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : @"";
    if (trimmed.length == 0) {
        return [self removeNoteForThreadId:threadId];
    }

    NSString *scope = ZLModCurrentAccountScope();
    NSString *key = [[self class] compoundKeyForAccountScope:scope threadId:threadId];
    if (!key) return NO;

    NSData *meta = [[self class] metadataForAccountScope:scope threadId:threadId];
    NSData *cipher = [[ZLModCryptoBox shared] encryptString:trimmed metadata:meta];
    if (!cipher) return NO;

    NSDictionary *record = @{
        @"accountScope": scope,
        @"threadId": [threadId copy],
        @"threadHash": ZLModSafeIdHash(threadId),
        @"updatedAt": @([[NSDate date] timeIntervalSince1970]),
        @"cipher": cipher
    };

    BOOL saved = NO;
    os_unfair_lock_lock(&_lock);
    NSDictionary *prev = self.records[key];
    self.records[key] = record;
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

- (BOOL)removeNoteForThreadId:(NSString *)threadId {
    NSString *scope = ZLModCurrentAccountScope();
    NSString *key = [[self class] compoundKeyForAccountScope:scope threadId:threadId];
    if (!key) return NO;

    BOOL saved = YES;
    os_unfair_lock_lock(&_lock);
    NSDictionary *prev = self.records[key];
    if (prev) {
        [self.records removeObjectForKey:key];
        saved = [self persistLocked];
        if (!saved) {
            self.records[key] = prev;
        }
    }
    os_unfair_lock_unlock(&_lock);
    return saved;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)allEntriesForCurrentAccount {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return @[];
    NSString *prefix = [scope stringByAppendingString:@":"];

    NSMutableArray<NSDictionary *> *rawList = [NSMutableArray array];
    os_unfair_lock_lock(&_lock);
    [self.records enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *rec, __unused BOOL *stop) {
        if ([key hasPrefix:prefix]) {
            [rawList addObject:rec];
        }
    }];
    os_unfair_lock_unlock(&_lock);

    [rawList sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [(b[@"updatedAt"] ?: @0) compare:(a[@"updatedAt"] ?: @0)];
    }];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *results = [NSMutableArray array];
    for (NSDictionary *rec in rawList) {
        NSString *tid = rec[@"threadId"];
        NSData *cipher = rec[@"cipher"];
        if (![tid isKindOfClass:[NSString class]] || ![cipher isKindOfClass:[NSData class]]) continue;
        NSData *meta = [[self class] metadataForAccountScope:scope threadId:tid];
        NSString *note = [[ZLModCryptoBox shared] decryptData:cipher metadata:meta];
        if (note.length == 0) continue;
        [results addObject:@{
            @"threadId": tid,
            @"threadHash": rec[@"threadHash"] ?: ZLModSafeIdHash(tid),
            @"note": note
        }];
    }
    return [results copy];
}

- (void)clearCurrentAccountNotes {
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

@end

void ZLModPresentPrivateNoteEditor(UIViewController *presenter,
                                   NSString *threadId,
                                   NSString *displayTitle,
                                   void (^completion)(BOOL saved)) {
    if (!presenter || threadId.length == 0) {
        if (completion) completion(NO);
        return;
    }
    NSString *existing = [[ZLModPrivateNotesStore shared] noteForThreadId:threadId] ?: @"";
    NSString *subtitle = (displayTitle.length > 0)
        ? [NSString stringWithFormat:@"%@ (%@)", displayTitle, ZLModSafeIdHash(threadId)]
        : ZLModSafeIdHash(threadId);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Ghi chú riêng tư (Mã hóa)"
                                                                   message:subtitle
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Nhập ghi chú cục bộ cho cuộc trò chuyện...";
        textField.text = existing;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Lưu"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        BOOL ok = [[ZLModPrivateNotesStore shared] setNote:text forThreadId:threadId];
        if (completion) completion(ok);
    }]];

    if (existing.length > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Xóa ghi chú"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            BOOL ok = [[ZLModPrivateNotesStore shared] removeNoteForThreadId:threadId];
            if (completion) completion(ok);
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy"
                                              style:UIAlertActionStyleCancel
                                            handler:^(__unused UIAlertAction *action) {
        if (completion) completion(NO);
    }]];

    [presenter presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 2. ZLModQuickReplyStore (Template manager + safe composer insert)

static const NSUInteger kZLModMaxQuickReplies = 50;

@interface ZLModQuickReplyStore () {
    os_unfair_lock _lock;
}
@property (nonatomic, strong) NSMutableArray<NSString *> *templates;
@property (nonatomic, copy) NSString *storagePath;
@end

@implementation ZLModQuickReplyStore

+ (instancetype)shared {
    static ZLModQuickReplyStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModQuickReplyStore alloc] init];
    });
    return instance;
}

+ (NSArray<NSString *> *)defaultTemplates {
    return @[
        @"Mình đang bận một chút, lát mình nhắn lại nhé!",
        @"Đã nhận thông tin, cảm ơn bạn nhé.",
        @"Ok bạn, để mình kiểm tra rồi phản hồi ngay."
    ];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _templates = [NSMutableArray array];

        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
        _storagePath = [docs stringByAppendingPathComponent:@"ZLModQuickReplies.plist"];

        if (![self loadFromDiskLocked]) {
            [_templates addObjectsFromArray:[[self class] defaultTemplates]];
        }
    }
    return self;
}

- (BOOL)loadFromDiskLocked {
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.storagePath]) return NO;
    @try {
        NSData *data = [NSData dataWithContentsOfFile:self.storagePath];
        if (!data) return NO;
        id plist = [NSPropertyListSerialization propertyListWithData:data
                                                             options:NSPropertyListImmutable
                                                              format:NULL
                                                               error:nil];
        if (![plist isKindOfClass:[NSArray class]]) return NO;
        [self.templates removeAllObjects];
        for (id item in (NSArray *)plist) {
            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0) {
                [self.templates addObject:item];
            }
        }
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

- (BOOL)persistLocked {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:[self.templates copy]
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:&error];
    if (!data || error) return NO;
    return [data writeToFile:self.storagePath options:NSDataWritingAtomic error:&error];
}

- (NSArray<NSString *> *)quickReplies {
    os_unfair_lock_lock(&_lock);
    NSArray<NSString *> *copy = [self.templates copy];
    os_unfair_lock_unlock(&_lock);
    return copy;
}

- (BOOL)addQuickReply:(NSString *)text {
    NSString *trimmed = [text isKindOfClass:[NSString class]]
        ? [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : @"";
    if (trimmed.length == 0) return NO;

    BOOL saved = NO;
    os_unfair_lock_lock(&_lock);
    if (self.templates.count < kZLModMaxQuickReplies) {
        [self.templates addObject:trimmed];
        saved = [self persistLocked];
        if (!saved) [self.templates removeLastObject];
    }
    os_unfair_lock_unlock(&_lock);
    return saved;
}

- (BOOL)updateQuickReplyAtIndex:(NSUInteger)index withText:(NSString *)text {
    NSString *trimmed = [text isKindOfClass:[NSString class]]
        ? [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : @"";
    if (trimmed.length == 0) return NO;

    BOOL saved = NO;
    os_unfair_lock_lock(&_lock);
    if (index < self.templates.count) {
        NSString *prev = self.templates[index];
        self.templates[index] = trimmed;
        saved = [self persistLocked];
        if (!saved) self.templates[index] = prev;
    }
    os_unfair_lock_unlock(&_lock);
    return saved;
}

- (BOOL)removeQuickReplyAtIndex:(NSUInteger)index {
    BOOL saved = NO;
    os_unfair_lock_lock(&_lock);
    if (index < self.templates.count) {
        NSString *prev = self.templates[index];
        [self.templates removeObjectAtIndex:index];
        saved = [self persistLocked];
        if (!saved) [self.templates insertObject:prev atIndex:index];
    }
    os_unfair_lock_unlock(&_lock);
    return saved;
}

- (BOOL)moveQuickReplyFromIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex {
    BOOL saved = NO;
    os_unfair_lock_lock(&_lock);
    if (fromIndex < self.templates.count && toIndex < self.templates.count && fromIndex != toIndex) {
        NSString *item = self.templates[fromIndex];
        [self.templates removeObjectAtIndex:fromIndex];
        [self.templates insertObject:item atIndex:toIndex];
        saved = [self persistLocked];
        if (!saved) {
            [self.templates removeObjectAtIndex:toIndex];
            [self.templates insertObject:item atIndex:fromIndex];
        }
    }
    os_unfair_lock_unlock(&_lock);
    return saved;
}

- (void)resetDefaults {
    os_unfair_lock_lock(&_lock);
    [self.templates setArray:[[self class] defaultTemplates]];
    [self persistLocked];
    os_unfair_lock_unlock(&_lock);
}

static UIView *ZLModFindFirstResponderInView(UIView *root) {
    if (!root) return nil;
    if (root.isFirstResponder) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = ZLModFindFirstResponderInView(sub);
        if (found) return found;
    }
    return nil;
}

- (BOOL)insertTemplateIntoComposer:(NSString *)text {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;

    // 1. Active BaseChatTVC -fillChatBarWithText: [v24@0:8@16] (never auto-sends)
    id activeChat = [ZLModPrivacyContext activeChatController];
    SEL fillSel = sel_registerName("fillChatBarWithText:");
    if (activeChat && [activeChat respondsToSelector:fillSel]) {
        Method m = class_getInstanceMethod(object_getClass(activeChat), fillSel);
        if (m && method_getNumberOfArguments(m) == 3) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(activeChat, fillSel, text);
                return YES;
            } @catch (__unused NSException *e) {}
        }
    }

    // 2. Fallback: active firstResponder UITextView or UITextField in key window
    UIWindow *win = ZLModActiveKeyWindow();
    UIView *responder = ZLModFindFirstResponderInView(win);
    if ([responder isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)responder;
        if (tv.isEditable) {
            tv.text = (tv.text.length > 0) ? [tv.text stringByAppendingFormat:@" %@", text] : text;
            if ([tv.delegate respondsToSelector:@selector(textViewDidChange:)]) {
                [tv.delegate textViewDidChange:tv];
            }
            return YES;
        }
    } else if ([responder isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)responder;
        tf.text = (tf.text.length > 0) ? [tf.text stringByAppendingFormat:@" %@", text] : text;
        [tf sendActionsForControlEvents:UIControlEventEditingChanged];
        return YES;
    }

    return NO;
}

@end

#pragma mark - 3. ZLModDelaySendManager (5-state atomic FSM + Undo Banner)

@interface ZLModPendingSendItem : NSObject
@property (nonatomic, copy) NSString *sendId;
@property (nonatomic, assign) ZLModDelaySendState state;
@property (nonatomic, weak) id senderManager;
@property (nonatomic, strong) id chatEntity;
@property (nonatomic, assign) BOOL checkUpload;
@property (nonatomic, copy) NSString *targetHash;
@property (nonatomic, assign) NSTimeInterval fireTime;
@property (nonatomic, strong) dispatch_source_t timer;
@end

@implementation ZLModPendingSendItem
@end

@interface ZLModDelaySendManager () {
    os_unfair_lock _lock;
}
@property (nonatomic, strong) NSMutableDictionary<NSString *, ZLModPendingSendItem *> *items;
@property (nonatomic, assign) IMP origSendChatIMP;
@end

@implementation ZLModDelaySendManager

+ (instancetype)shared {
    static ZLModDelaySendManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModDelaySendManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _items = [NSMutableDictionary dictionary];

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            [self cancelAllPendingSendsWithReason:@"app_backgrounded"];
        }];
        [nc addObserverForName:UIApplicationWillTerminateNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            [self cancelAllPendingSendsWithReason:@"app_terminated"];
        }];
        [nc addObserverForName:ZLModAccountDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            [self cancelAllPendingSendsWithReason:@"account_changed"];
        }];
        [nc addObserverForName:ZLModPrefsDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            if ([note.object isEqualToString:kZLModDelaySend] || [note.object isEqualToString:@"*"]) {
                if (![[ZLModPreferences shared] boolForKey:kZLModDelaySend]) {
                    [self cancelAllPendingSendsWithReason:@"feature_disabled"];
                }
            }
        }];
    }
    return self;
}

- (NSTimeInterval)delayDuration {
    double val = [[ZLModPreferences shared] doubleForKey:kZLModDelaySendSeconds defaultValue:3.0];
    if (val < 1.0) return 1.0;
    if (val > 10.0) return 10.0;
    return val;
}

- (void)setDelayDuration:(NSTimeInterval)seconds {
    double clamped = seconds;
    if (clamped < 1.0) clamped = 1.0;
    if (clamped > 10.0) clamped = 10.0;
    [[ZLModPreferences shared] setDouble:clamped forKey:kZLModDelaySendSeconds];
}

- (NSUInteger)pendingCount {
    NSUInteger count = 0;
    os_unfair_lock_lock(&_lock);
    for (NSString *sid in self.items) {
        if (self.items[sid].state == ZLModDelaySendStatePending) {
            count++;
        }
    }
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (void)enqueueSendFromManager:(id)manager
                    chatEntity:(id)chatEntity
                   checkUpload:(BOOL)checkUpload
                       origIMP:(IMP)origIMP {
    SEL sendSel = sel_registerName("sendChat:checkUpload:");
    if (!manager || !chatEntity || !origIMP) {
        if (origIMP && manager) {
            ((void (*)(id, SEL, id, BOOL))origIMP)(manager, sendSel, chatEntity, checkUpload);
        }
        return;
    }

    NSNumber *bypass = objc_getAssociatedObject(chatEntity, kZLModDelaySendBypassAssocKey);
    if ([bypass boolValue] || ![[ZLModPreferences shared] boolForKey:kZLModDelaySend]) {
        objc_setAssociatedObject(chatEntity, kZLModDelaySendBypassAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, id, BOOL))origIMP)(manager, sendSel, chatEntity, checkUpload);
        return;
    }

    NSTimeInterval delay = [self delayDuration];
    NSString *sendId = [[NSUUID UUID] UUIDString];

    // Extract target thread via verified ChatEntity selectors tuid or threadId
    NSString *targetId = ZLModSafeStringProperty(chatEntity, sel_registerName("tuid"));
    if (targetId.length == 0) {
        targetId = ZLModSafeStringProperty(chatEntity, sel_registerName("threadId"));
    }

    ZLModPendingSendItem *item = [[ZLModPendingSendItem alloc] init];
    item.sendId = sendId;
    item.state = ZLModDelaySendStatePending;
    item.senderManager = manager;
    item.chatEntity = chatEntity;
    item.checkUpload = checkUpload;
    item.targetHash = ZLModSafeIdHash(targetId);
    item.fireTime = [[NSDate date] timeIntervalSince1970] + delay;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    item.timer = timer;

    os_unfair_lock_lock(&_lock);
    self.origSendChatIMP = origIMP;
    self.items[sendId] = item;
    os_unfair_lock_unlock(&_lock);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(50 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf timerFiredForSendId:sendId];
    });
    dispatch_resume(timer);

    ZLMOD_LOG(@"delaysend: queued sendId=%@ target=%@ delay=%.1fs",
              sendId, item.targetHash, delay);

    dispatch_async(dispatch_get_main_queue(), ^{
        [self showUndoBannerForSendId:sendId duration:delay];
    });
}

- (void)timerFiredForSendId:(NSString *)sendId {
    if (sendId.length == 0) return;

    ZLModPendingSendItem *item = nil;
    IMP origIMP = NULL;

    os_unfair_lock_lock(&_lock);
    ZLModPendingSendItem *candidate = self.items[sendId];
    if (candidate && candidate.state == ZLModDelaySendStatePending) {
        candidate.state = ZLModDelaySendStateDispatching;
        item = candidate;
        origIMP = self.origSendChatIMP;
    }
    os_unfair_lock_unlock(&_lock);

    if (!item) return;

    if (item.timer) {
        dispatch_source_cancel(item.timer);
        item.timer = nil;
    }
    [self dismissUndoBannerIfMatchingSendId:sendId];

    id manager = item.senderManager;
    id chat = item.chatEntity;
    SEL sendSel = sel_registerName("sendChat:checkUpload:");

    BOOL dispatchedOK = NO;
    if (manager && chat && origIMP) {
        @try {
            objc_setAssociatedObject(chat, kZLModDelaySendBypassAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ((void (*)(id, SEL, id, BOOL))origIMP)(manager, sendSel, chat, item.checkUpload);
            dispatchedOK = YES;
        } @catch (NSException *e) {
            ZLMOD_LOG(@"delaysend: dispatch threw exception (%@)", e.reason ?: @"unknown");
            dispatchedOK = NO;
        }
    }

    os_unfair_lock_lock(&_lock);
    item.state = dispatchedOK ? ZLModDelaySendStateDispatched : ZLModDelaySendStateFailed;
    [self.items removeObjectForKey:sendId];
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)cancelPendingSendWithId:(NSString *)sendId {
    if (sendId.length == 0) return NO;

    ZLModPendingSendItem *cancelledItem = nil;
    os_unfair_lock_lock(&_lock);
    ZLModPendingSendItem *item = self.items[sendId];
    if (item && item.state == ZLModDelaySendStatePending) {
        item.state = ZLModDelaySendStateCancelled;
        cancelledItem = item;
        [self.items removeObjectForKey:sendId];
    }
    os_unfair_lock_unlock(&_lock);

    if (!cancelledItem) return NO;

    if (cancelledItem.timer) {
        dispatch_source_cancel(cancelledItem.timer);
        cancelledItem.timer = nil;
    }
    [self dismissUndoBannerIfMatchingSendId:sendId];
    ZLMOD_LOG(@"delaysend: cancelled sendId=%@ target=%@", sendId, cancelledItem.targetHash);
    ZLModShowToast(@"Đã hủy gửi tin nhắn");
    return YES;
}

- (void)cancelAllPendingSends {
    [self cancelAllPendingSendsWithReason:@"manual_cancel_all"];
}

- (void)cancelAllPendingSendsWithReason:(NSString *)reason {
    NSMutableArray<ZLModPendingSendItem *> *toCancel = [NSMutableArray array];
    os_unfair_lock_lock(&_lock);
    for (NSString *sid in [self.items allKeys]) {
        ZLModPendingSendItem *item = self.items[sid];
        if (item.state == ZLModDelaySendStatePending) {
            item.state = ZLModDelaySendStateCancelled;
            [toCancel addObject:item];
        }
        [self.items removeObjectForKey:sid];
    }
    os_unfair_lock_unlock(&_lock);

    for (ZLModPendingSendItem *item in toCancel) {
        if (item.timer) {
            dispatch_source_cancel(item.timer);
            item.timer = nil;
        }
    }
    if (toCancel.count > 0) {
        ZLMOD_LOG(@"delaysend: cancelled %lu pending sends (reason=%@)",
                  (unsigned long)toCancel.count, reason ?: @"unknown");
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *win = ZLModActiveKeyWindow();
            UIView *banner = [win viewWithTag:kZLModUndoBannerTag];
            if (banner) [banner removeFromSuperview];
        });
    }
}

#pragma mark - Interactive Undo Banner

- (void)showUndoBannerForSendId:(NSString *)sendId duration:(NSTimeInterval)duration {
    UIWindow *win = ZLModActiveKeyWindow();
    if (!win || sendId.length == 0) return;

    UIView *existing = [win viewWithTag:kZLModUndoBannerTag];
    if (existing) [existing removeFromSuperview];

    CGFloat width = MIN(win.bounds.size.width - 32.0, 380.0);
    CGFloat height = 46.0;
    CGFloat bottomY = win.bounds.size.height - MAX(win.safeAreaInsets.bottom + 68.0, 92.0) - height;

    UIView *banner = [[UIView alloc] initWithFrame:CGRectMake((win.bounds.size.width - width) * 0.5,
                                                              bottomY,
                                                              width,
                                                              height)];
    banner.tag = kZLModUndoBannerTag;
    banner.userInteractionEnabled = YES;
    banner.backgroundColor = [UIColor colorWithRed:0.08 green:0.10 blue:0.14 alpha:0.95];
    banner.layer.cornerRadius = 14.0;
    banner.layer.masksToBounds = YES;
    objc_setAssociatedObject(banner, kZLModUndoButtonSendIdAssocKey, sendId, OBJC_ASSOCIATION_COPY_NONATOMIC);

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(14.0, 0.0, width - 126.0, height)];
    label.text = [NSString stringWithFormat:@"Đang chờ gửi (%.0fs)...", duration];
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    [banner addSubview:label];

    UIButton *undoBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    undoBtn.frame = CGRectMake(width - 108.0, 7.0, 96.0, 32.0);
    [undoBtn setTitle:@"Hủy gửi" forState:UIControlStateNormal];
    [undoBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    undoBtn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightBold];
    undoBtn.backgroundColor = [UIColor systemRedColor];
    undoBtn.layer.cornerRadius = 10.0;
    objc_setAssociatedObject(undoBtn, kZLModUndoButtonSendIdAssocKey, sendId, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [undoBtn addTarget:self action:@selector(undoButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [banner addSubview:undoBtn];

    [win addSubview:banner];
}

- (void)undoButtonTapped:(UIButton *)sender {
    NSString *sendId = objc_getAssociatedObject(sender, kZLModUndoButtonSendIdAssocKey);
    if (sendId.length > 0) {
        [self cancelPendingSendWithId:sendId];
    }
}

- (void)dismissUndoBannerIfMatchingSendId:(NSString *)sendId {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self dismissUndoBannerIfMatchingSendId:sendId];
        });
        return;
    }
    UIWindow *win = ZLModActiveKeyWindow();
    UIView *banner = [win viewWithTag:kZLModUndoBannerTag];
    if (!banner) return;
    NSString *bannerSendId = objc_getAssociatedObject(banner, kZLModUndoButtonSendIdAssocKey);
    if (!sendId || [bannerSendId isEqualToString:sendId]) {
        [banner removeFromSuperview];
    }
}

@end

#pragma mark - Module installer

void ZLModUtilitiesInstall(void) {
    // Initialize singletons so lifecycle observers are registered
    (void)[ZLModPrivateNotesStore shared];
    (void)[ZLModQuickReplyStore shared];
    (void)[ZLModDelaySendManager shared];

    NSUInteger installed = 0;
    Class sendMgrCls = NSClassFromString(@"ZAChatSendingManager");
    if (sendMgrCls) {
        // ZAChatSendingManager -sendChat:checkUpload: [v28@0:8@16B24]
        SEL sendSel = sel_registerName("sendChat:checkUpload:");
        if (ZLModClassHasInstanceMethod(sendMgrCls, sendSel)) {
            IMP orig = class_getMethodImplementation(sendMgrCls, sendSel);
            if (ZLModReplaceMethod(sendMgrCls, sendSel, 2, "v", ^(id selfObj, id chatEntity, BOOL checkUpload) {
                [[ZLModDelaySendManager shared] enqueueSendFromManager:selfObj
                                                            chatEntity:chatEntity
                                                           checkUpload:checkUpload
                                                               origIMP:orig];
            })) {
                installed++;
            }
        }
    }

    ZLModSetModuleStatus(@"Utilities",
                         (installed > 0) ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"delaySendHook=%lu", (unsigned long)installed]);
    ZLMOD_LOG(@"utilities installed (delaySendHook=%lu)", (unsigned long)installed);
}
