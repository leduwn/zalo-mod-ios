// language: Objective-C, file: ZLModConversationMenu.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Inbox long-press context menu injection (Seen/Typing per-conversation toggles,
// Local Unread mark, Encrypted Private Note) and live unread blue-dot indicator
// across UXInboxMessageCell and ChatListItemCell.

#import "ZLMod.h"
#import <os/lock.h>

static const NSInteger kZLModActionToggleSeen   = 98001;
static const NSInteger kZLModActionToggleTyping = 98002;
static const NSInteger kZLModActionToggleUnread = 98003;
static const NSInteger kZLModActionPrivateNote  = 98004;

static const NSInteger kZLModToastViewTag       = 0x5A1C;
static const NSInteger kZLModUnreadDotViewTag   = 0x5A1D;
static const NSTimeInterval kZLModMenuSessionTTL = 120.0;

static const void *kZLModMenuSessionAssocKey    = &kZLModMenuSessionAssocKey;
static const void *kZLModCellThreadIdAssocKey   = &kZLModCellThreadIdAssocKey;

#pragma mark - Immutable menu session

@interface ZLModMenuSession : NSObject
@property (nonatomic, copy, readonly) NSString *sessionId;
@property (nonatomic, copy, readonly) NSString *threadId;
@property (nonatomic, copy, readonly) NSString *conversationType;
@property (nonatomic, copy, readonly) NSString *displayTitle;
@property (nonatomic, copy, readonly) NSString *accountScope;
@property (nonatomic, assign, readonly) NSTimeInterval createdAt;
@property (nonatomic, assign) BOOL executed;
- (instancetype)initWithThreadId:(NSString *)threadId
                conversationType:(NSString *)convType
                    displayTitle:(NSString *)title
                    accountScope:(NSString *)accountScope;
@end

@implementation ZLModMenuSession

- (instancetype)initWithThreadId:(NSString *)threadId
                conversationType:(NSString *)convType
                    displayTitle:(NSString *)title
                    accountScope:(NSString *)accountScope {
    self = [super init];
    if (self) {
        _sessionId = [[[NSUUID UUID] UUIDString] copy];
        _threadId = [threadId copy];
        _conversationType = [convType isEqualToString:@"group"] ? @"group" : @"single";
        _displayTitle = (title.length > 0) ? [title copy] : @"Cuộc trò chuyện";
        _accountScope = [accountScope copy];
        _createdAt = [[NSDate date] timeIntervalSince1970];
        _executed = NO;
    }
    return self;
}

@end

static os_unfair_lock gMenuSessionLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, ZLModMenuSession *> *gMenuSessions = nil;
static ZLModMenuSession *gLatestMenuSession = nil;
static NSHashTable<UIView *> *gTrackedInboxCells = nil;

#pragma mark - Toast helper (non-interactive)

void ZLModShowToast(NSString *message) {
    if (!message || message.length == 0) return;
    if (![NSThread isMainThread]) {
        NSString *copied = [message copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            ZLModShowToast(copied);
        });
        return;
    }

    UIWindow *window = ZLModActiveKeyWindow();
    if (!window) return;

    UIView *existing = [window viewWithTag:kZLModToastViewTag];
    if (existing) {
        [existing removeFromSuperview];
    }

    UIView *banner = [[UIView alloc] init];
    banner.tag = kZLModToastViewTag;
    banner.userInteractionEnabled = NO;
    banner.backgroundColor = [[UIColor colorWithWhite:0.12 alpha:0.92] colorWithAlphaComponent:0.94];
    banner.layer.cornerRadius = 18.0;
    banner.layer.masksToBounds = YES;

    UILabel *label = [[UILabel alloc] init];
    label.text = message;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    label.numberOfLines = 2;
    label.textAlignment = NSTextAlignmentCenter;

    CGFloat maxWidth = MAX(window.bounds.size.width - 40.0, 200.0);
    CGSize textSize = [label sizeThatFits:CGSizeMake(maxWidth - 32.0, 60.0)];
    CGFloat bannerW = MIN(MAX(textSize.width + 32.0, 160.0), maxWidth);
    CGFloat bannerH = MAX(textSize.height + 16.0, 36.0);
    CGFloat topY = MAX(window.safeAreaInsets.top + 8.0, 44.0);

    banner.frame = CGRectMake((window.bounds.size.width - bannerW) * 0.5, topY, bannerW, bannerH);
    label.frame = CGRectInset(banner.bounds, 14.0, 6.0);
    [banner addSubview:label];

    banner.alpha = 0.0;
    banner.transform = CGAffineTransformMakeTranslation(0.0, -8.0);
    [window addSubview:banner];

    [UIView animateWithDuration:0.2
                     animations:^{
        banner.alpha = 1.0;
        banner.transform = CGAffineTransformIdentity;
    } completion:^(__unused BOOL finished) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!banner.superview) return;
            [UIView animateWithDuration:0.2
                             animations:^{
                banner.alpha = 0.0;
            } completion:^(__unused BOOL done) {
                [banner removeFromSuperview];
            }];
        });
    }];
}


#pragma mark - Session registry

static void ZLModRegisterMenuSession(ZLModMenuSession *session) {
    if (!session || session.sessionId.length == 0) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    os_unfair_lock_lock(&gMenuSessionLock);
    if (!gMenuSessions) {
        gMenuSessions = [NSMutableDictionary dictionary];
    }
    NSMutableArray<NSString *> *expired = [NSMutableArray array];
    [gMenuSessions enumerateKeysAndObjectsUsingBlock:^(NSString *sid, ZLModMenuSession *entry, __unused BOOL *stop) {
        if ((now - entry.createdAt) > kZLModMenuSessionTTL || entry.executed) {
            [expired addObject:sid];
        }
    }];
    if (expired.count > 0) {
        [gMenuSessions removeObjectsForKeys:expired];
    }
    gMenuSessions[session.sessionId] = session;
    gLatestMenuSession = session;
    os_unfair_lock_unlock(&gMenuSessionLock);
}

static ZLModMenuSession *ZLModConsumeMenuSessionForIdentifier(id menuObj, id identifier) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *currentScope = ZLModCurrentAccountScope();
    if (currentScope.length == 0) return nil;

    os_unfair_lock_lock(&gMenuSessionLock);
    ZLModMenuSession *candidate = nil;

    if (identifier) {
        ZLModMenuSession *assoc = objc_getAssociatedObject(identifier, kZLModMenuSessionAssocKey);
        if ([assoc isKindOfClass:[ZLModMenuSession class]]) {
            candidate = assoc;
        }
    }
    if (!candidate && menuObj) {
        ZLModMenuSession *assoc = objc_getAssociatedObject(menuObj, kZLModMenuSessionAssocKey);
        if ([assoc isKindOfClass:[ZLModMenuSession class]]) {
            candidate = assoc;
        }
    }
    if (!candidate && [identifier isKindOfClass:[NSString class]]) {
        NSString *idStr = (NSString *)identifier;
        if (gMenuSessions[idStr]) {
            candidate = gMenuSessions[idStr];
        } else {
            __block ZLModMenuSession *newestMatch = nil;
            [gMenuSessions enumerateKeysAndObjectsUsingBlock:^(__unused NSString *sid, ZLModMenuSession *entry, __unused BOOL *stop) {
                if (!entry.executed && [entry.threadId isEqualToString:idStr]) {
                    if (!newestMatch || entry.createdAt > newestMatch.createdAt) {
                        newestMatch = entry;
                    }
                }
            }];
            candidate = newestMatch;
        }
    }
    if (!candidate && gLatestMenuSession && !gLatestMenuSession.executed) {
        candidate = gLatestMenuSession;
    }

    if (!candidate ||
        candidate.executed ||
        (now - candidate.createdAt) > kZLModMenuSessionTTL ||
        ![candidate.accountScope isEqualToString:currentScope]) {
        os_unfair_lock_unlock(&gMenuSessionLock);
        return nil;
    }

    candidate.executed = YES;
    [gMenuSessions removeObjectForKey:candidate.sessionId];
    if (gLatestMenuSession == candidate) {
        gLatestMenuSession = nil;
    }
    os_unfair_lock_unlock(&gMenuSessionLock);
    return candidate;
}

#pragma mark - Item inspection & ContextMenuViewModel construction

static NSString *ZLModExtractThreadIdFromInboxItem(id item) {
    if (!item) return nil;
    for (NSString *selName in @[@"threadid", @"threadId", @"swipeKey", @"key"]) {
        NSString *val = ZLModSafeStringProperty(item, NSSelectorFromString(selName));
        if (val.length > 0 && ![val isEqualToString:@"0"]) {
            return val;
        }
    }
    for (NSString *cfgSelName in @[@"zds_swipeConfiguration", @"swipeConfiguration", @"configuration"]) {
        id cfg = ZLModSafeObjectProperty(item, NSSelectorFromString(cfgSelName));
        if (cfg) {
            for (NSString *keySelName in @[@"key", @"swipeKey", @"threadId", @"threadid", @"identifier"]) {
                NSString *val = ZLModSafeStringProperty(cfg, NSSelectorFromString(keySelName));
                if (val.length > 0 && ![val isEqualToString:@"0"]) {
                    return val;
                }
            }
        }
    }
    return nil;
}

static NSString *ZLModExtractTitleFromInboxItem(id item) {
    if (!item) return @"Cuộc trò chuyện";
    id info = ZLModSafeObjectProperty(item, sel_registerName("info"));
    if (info) {
        NSString *t = ZLModSafeStringProperty(info, sel_registerName("title"));
        if (t.length > 0) return t;
    }
    NSString *direct = ZLModSafeStringProperty(item, sel_registerName("title"));
    if (direct.length > 0) return direct;
    return @"Cuộc trò chuyện";
}

static NSString *ZLModExtractConvTypeFromInboxItem(id item) {
    if (!item) return @"single";
    if (ZLModClassHasInstanceMethod(object_getClass(item), sel_registerName("isGroup")) &&
        ZLModSafeBoolProperty(item, sel_registerName("isGroup"), NO)) {
        return @"group";
    }
    int64_t msgType = ZLModSafeInt64Property(item, sel_registerName("messageType"), 0);
    if (msgType == 2) return @"group";
    return @"single";
}

static BOOL ZLModIsEligibleInboxMessageItem(id item) {
    if (!item) return NO;
    Class cls = object_getClass(item);
    if (ZLModClassHasInstanceMethod(cls, sel_registerName("isMessageCell"))) {
        if (!ZLModSafeBoolProperty(item, sel_registerName("isMessageCell"), YES)) return NO;
    }
    if (ZLModClassHasInstanceMethod(cls, sel_registerName("isPromotion"))) {
        if (ZLModSafeBoolProperty(item, sel_registerName("isPromotion"), NO)) return NO;
    }
    if (ZLModClassHasInstanceMethod(cls, sel_registerName("isFolder"))) {
        if (ZLModSafeBoolProperty(item, sel_registerName("isFolder"), NO)) return NO;
    }
    return YES;
}

// Copies every visual attribute the native menu renderer dereferences (ZDSColor
// text/icon colors, disabled colors, promote type, padding) from a genuine model so the
// injected rows are structurally identical to Zalo's own rows. Rows built with nil
// ZDSColor values crash the renderer as soon as the menu is shown.
static void ZLModCopyMenuAppearance(id from, id to) {
    static NSArray<NSArray<NSString *> *> *pairs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pairs = @[
            @[@"textColor", @"setTextColor:"],
            @[@"iconColor", @"setIconColor:"],
            @[@"disabledTextColor", @"setDisabledTextColor:"],
            @[@"disabledIconColor", @"setDisabledIconColor:"],
        ];
    });
    for (NSArray<NSString *> *pair in pairs) {
        SEL getter = NSSelectorFromString(pair[0]);
        SEL setter = NSSelectorFromString(pair[1]);
        if (!ZLModClassHasInstanceMethod(object_getClass(from), getter) ||
            !ZLModClassHasInstanceMethod(object_getClass(to), setter)) continue;
        id value = ZLModSafeObjectProperty(from, getter);
        if (value) ((void (*)(id, SEL, id))objc_msgSend)(to, setter, value);
    }
    SEL setPromote = sel_registerName("setPromoteType:");
    if (ZLModClassHasInstanceMethod(object_getClass(to), setPromote)) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(to, setPromote,
            (NSInteger)ZLModSafeInt64Property(from, sel_registerName("promoteType"), 0));
    }
    SEL setPad = sel_registerName("setTopTextPadding:");
    if (ZLModClassHasInstanceMethod(object_getClass(to), setPad)) {
        ((void (*)(id, SEL, double))objc_msgSend)(to, setPad,
            ZLModSafeDoubleProperty(from, sel_registerName("topTextPadding"), 0.0));
    }
}

static id ZLModMakeContextMenuViewModel(NSInteger actionId,
                                        NSString *title,
                                        NSString *symbolName,
                                        ZLModMenuSession *session,
                                        id template) {
    Class vmClass = NSClassFromString(@"ContextMenuViewModel");
    if (!vmClass || !template) return nil;

    id vm = nil;
    @try {
        vm = [[vmClass alloc] init];
    } @catch (__unused NSException *e) {
        return nil;
    }
    if (!vm) return nil;
    ZLModCopyMenuAppearance(template, vm);

    SEL setTextSel = sel_registerName("setText:");
    if ([vm respondsToSelector:setTextSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(vm, setTextSel, title ?: @"");
    }

    SEL setMenuTypeSel = sel_registerName("setMenuType:");
    if ([vm respondsToSelector:setMenuTypeSel]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(vm, setMenuTypeSel, actionId);
    }

    {
        UIImage *icon = symbolName.length > 0 ? [UIImage systemImageNamed:symbolName] : nil;
        if (!icon) icon = [UIImage systemImageNamed:@"circle"];
        icon = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        SEL setIconSel = sel_registerName("setIconImage:");
        if (icon && [vm respondsToSelector:setIconSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(vm, setIconSel, icon);
        }
    }

    SEL setAccessIdSel = sel_registerName("setAccessibilityIdentifier:");
    if ([vm respondsToSelector:setAccessIdSel] && session.sessionId.length > 0) {
        NSString *aid = [NSString stringWithFormat:@"zlmod.action.%ld.%@", (long)actionId, session.sessionId];
        ((void (*)(id, SEL, id))objc_msgSend)(vm, setAccessIdSel, aid);
    }

    if (session) {
        objc_setAssociatedObject(vm, kZLModMenuSessionAssocKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return vm;
}

static id ZLModMakeContextMenuAction(NSInteger actionId,
                                     NSString *title,
                                     NSString *symbolName,
                                     ZLModMenuSession *session,
                                     id template) {
    Class modernActionCls = NSClassFromString(@"_TtC13ZAContextMenu19ZAContextMenuAction");
    if (modernActionCls) {
        UIImage *icon = symbolName.length > 0 ? [UIImage systemImageNamed:symbolName] : nil;
        if (!icon) icon = [UIImage systemImageNamed:@"circle"];

        SEL initSel = sel_registerName("initWithActionId:title:image:style:");
        if ([modernActionCls instancesRespondToSelector:initSel]) {
            id action = [modernActionCls alloc];
            action = ((id (*)(id, SEL, NSInteger, id, id, NSInteger))objc_msgSend)(
                action, initSel, actionId, title ?: @"", icon, (NSInteger)0);
            if (action && session) {
                objc_setAssociatedObject(action, kZLModMenuSessionAssocKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            return action;
        }
    }

    return ZLModMakeContextMenuViewModel(actionId, title, symbolName, session, template);
}

#pragma mark - Unread blue-dot rendering on inbox cells

static NSString *ZLModResolveThreadIdForCell(UIView *cell) {
    if (!cell) return nil;
    NSString *assoc = objc_getAssociatedObject(cell, kZLModCellThreadIdAssocKey);
    if ([assoc isKindOfClass:[NSString class]] && assoc.length > 0) {
        return assoc;
    }
    for (NSString *selName in @[@"messageItem", @"cachedItem", @"listItem"]) {
        id item = ZLModSafeObjectProperty(cell, NSSelectorFromString(selName));
        NSString *tid = ZLModExtractThreadIdFromInboxItem(item);
        if (tid.length > 0) return tid;
    }
    return nil;
}

static void ZLModUpdateUnreadDotForCell(UIView *cell) {
    if (!cell || ![cell isKindOfClass:[UIView class]]) return;
    UIView *container = [cell isKindOfClass:[UITableViewCell class]]
        ? ([(UITableViewCell *)cell contentView] ?: cell)
        : cell;

    NSString *tid = ZLModResolveThreadIdForCell(cell);
    BOOL showDot = (tid.length > 0) && [[ZLModConversationPolicyStore shared] isLocalUnreadAnyTypeForThreadId:tid];

    UIView *dot = [container viewWithTag:kZLModUnreadDotViewTag];
    if (!showDot) {
        if (dot) dot.hidden = YES;
        return;
    }

    if (!dot) {
        dot = [[UIView alloc] initWithFrame:CGRectMake(10.0, 12.0, 10.0, 10.0)];
        dot.tag = kZLModUnreadDotViewTag;
        dot.userInteractionEnabled = NO;
        dot.backgroundColor = [UIColor colorWithRed:0.0 green:104.0 / 255.0 blue:1.0 alpha:1.0];
        dot.layer.cornerRadius = 5.0;
        dot.layer.borderWidth = 1.5;
        dot.layer.borderColor = [UIColor whiteColor].CGColor;
        dot.layer.masksToBounds = YES;
        [container addSubview:dot];
    }
    dot.hidden = NO;
    [container bringSubviewToFront:dot];
}

static void ZLModTrackAndRefreshInboxCell(UIView *cell, id item) {
    if (!cell || ![cell isKindOfClass:[UIView class]]) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ZLModTrackAndRefreshInboxCell(cell, item);
        });
        return;
    }
    if (!gTrackedInboxCells) {
        gTrackedInboxCells = [NSHashTable weakObjectsHashTable];
    }
    [gTrackedInboxCells addObject:cell];

    NSString *tid = ZLModExtractThreadIdFromInboxItem(item);
    objc_setAssociatedObject(cell, kZLModCellThreadIdAssocKey, tid, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ZLModUpdateUnreadDotForCell(cell);
}

static void ZLModRefreshAllTrackedInboxCells(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ZLModRefreshAllTrackedInboxCells();
        });
        return;
    }
    for (UIView *cell in gTrackedInboxCells) {
        ZLModUpdateUnreadDotForCell(cell);
    }
}

#pragma mark - Action handler

static void ZLModExecuteMenuAction(NSInteger actionId, ZLModMenuSession *session) {
    if (!session || session.threadId.length == 0 || session.accountScope.length == 0) return;

    ZLModConversationPolicyStore *policyStore = [ZLModConversationPolicyStore shared];
    NSString *scope = session.accountScope;
    NSString *ctype = session.conversationType;
    NSString *tid = session.threadId;

    if (actionId == kZLModActionToggleSeen) {
        ZLModSeenPolicy cur = [policyStore seenPolicyForAccountScope:scope conversationType:ctype threadId:tid];
        ZLModSeenPolicy next = (cur == ZLModSeenPolicyHideSeen) ? ZLModSeenPolicyFollowOriginal : ZLModSeenPolicyHideSeen;
        if ([policyStore setSeenPolicy:next forAccountScope:scope conversationType:ctype threadId:tid]) {
            ZLModShowToast(next == ZLModSeenPolicyHideSeen
                           ? @"Đã bật Ẩn đã xem cho cuộc trò chuyện này"
                           : @"Đã tắt Ẩn đã xem cho cuộc trò chuyện này");
        } else {
            ZLModShowToast(@"Không thể lưu thiết lập Ẩn đã xem");
        }
        return;
    }

    if (actionId == kZLModActionToggleTyping) {
        ZLModTypingPolicy cur = [policyStore typingPolicyForAccountScope:scope conversationType:ctype threadId:tid];
        ZLModTypingPolicy next = (cur == ZLModTypingPolicyHideTyping) ? ZLModTypingPolicyFollowOriginal : ZLModTypingPolicyHideTyping;
        if ([policyStore setTypingPolicy:next forAccountScope:scope conversationType:ctype threadId:tid]) {
            ZLModShowToast(next == ZLModTypingPolicyHideTyping
                           ? @"Đã bật Ẩn đang nhập cho cuộc trò chuyện này"
                           : @"Đã tắt Ẩn đang nhập cho cuộc trò chuyện này");
        } else {
            ZLModShowToast(@"Không thể lưu thiết lập Ẩn đang nhập");
        }
        return;
    }

    if (actionId == kZLModActionToggleUnread) {
        BOOL cur = [policyStore isLocalUnreadForAccountScope:scope conversationType:ctype threadId:tid];
        BOOL next = !cur;
        if ([policyStore setLocalUnread:next forAccountScope:scope conversationType:ctype threadId:tid]) {
            ZLModRefreshAllTrackedInboxCells();
            ZLModShowToast(next ? @"Đã đánh dấu chưa đọc (Chấm xanh)" : @"Đã bỏ đánh dấu chưa đọc");
        } else {
            ZLModShowToast(@"Không thể cập nhật trạng thái chưa đọc");
        }
        return;
    }

    if (actionId == kZLModActionPrivateNote) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = ZLModTopPresenterViewController();
            if (!presenter) {
                ZLModShowToast(@"Không tìm thấy màn hình để mở ghi chú");
                return;
            }
            ZLModPresentPrivateNoteEditor(presenter, tid, session.displayTitle, ^(BOOL saved) {
                if (saved) {
                    ZLModShowToast(@"Đã cập nhật ghi chú riêng tư");
                }
            });
        });
    }
}

#pragma mark - Install hooks

static NSUInteger ZLModInstallInboxContextMenuHooks(void) {
    Class mgrClass = NSClassFromString(@"InboxContextMenuManager");
    if (!mgrClass) return 0;

    NSUInteger installed = 0;

    // 1. -getActionsWithItem: [@24@0:8@16]
    SEL getActionsSel = sel_registerName("getActionsWithItem:");
    if (ZLModClassHasInstanceMethod(mgrClass, getActionsSel)) {
        IMP orig = class_getMethodImplementation(mgrClass, getActionsSel);
        if (ZLModReplaceMethod(mgrClass, getActionsSel, 1, "@", ^id(id selfObj, id item) {
            id origList = orig ? ((id (*)(id, SEL, id))orig)(selfObj, getActionsSel, item) : nil;
            if (![origList isKindOfClass:[NSArray class]]) return origList;
            if (!ZLModIsEligibleInboxMessageItem(item)) return origList;

            Class modernActionCls = NSClassFromString(@"_TtC13ZAContextMenu19ZAContextMenuAction");
            Class vmCls = NSClassFromString(@"ContextMenuViewModel");
            id template = nil;
            if (vmCls) {
                for (id candidate in (NSArray *)origList) {
                    if ([candidate isKindOfClass:vmCls]) { template = candidate; break; }
                }
            }
            if (!modernActionCls && !template) return origList; // never inject rows we cannot style like native ones

            NSString *tid = ZLModExtractThreadIdFromInboxItem(item);
            NSString *scope = ZLModCurrentAccountScope();
            if (tid.length == 0 || scope.length == 0) return origList;

            NSString *ctype = ZLModExtractConvTypeFromInboxItem(item);
            NSString *title = ZLModExtractTitleFromInboxItem(item);

            ZLModMenuSession *session = [[ZLModMenuSession alloc] initWithThreadId:tid
                                                                  conversationType:ctype
                                                                      displayTitle:title
                                                                      accountScope:scope];
            ZLModRegisterMenuSession(session);
            objc_setAssociatedObject(selfObj, kZLModMenuSessionAssocKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(item, kZLModMenuSessionAssocKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            ZLModConversationPolicyStore *policyStore = [ZLModConversationPolicyStore shared];
            BOOL hideSeen = ([policyStore seenPolicyForAccountScope:scope conversationType:ctype threadId:tid] == ZLModSeenPolicyHideSeen);
            BOOL hideTyping = ([policyStore typingPolicyForAccountScope:scope conversationType:ctype threadId:tid] == ZLModTypingPolicyHideTyping);
            BOOL unread = [policyStore isLocalUnreadForAccountScope:scope conversationType:ctype threadId:tid];
            BOOL hasNote = ([[ZLModPrivateNotesStore shared] noteForThreadId:tid].length > 0);

            NSArray *origArray = (NSArray *)origList;
            BOOL isSectioned = (origArray.count > 0 && [origArray.firstObject isKindOfClass:[NSArray class]]);

            NSMutableArray *customItems = [NSMutableArray arrayWithCapacity:4];
            id a1 = ZLModMakeContextMenuAction(kZLModActionToggleSeen,
                                               hideSeen ? @"Tắt Ẩn đã xem (Đang bật)" : @"Bật Ẩn đã xem cuộc trò chuyện",
                                               hideSeen ? @"eye.fill" : @"eye.slash",
                                               session,
                                               template);
            id a2 = ZLModMakeContextMenuAction(kZLModActionToggleTyping,
                                               hideTyping ? @"Tắt Ẩn đang nhập (Đang bật)" : @"Bật Ẩn đang nhập cuộc trò chuyện",
                                               hideTyping ? @"keyboard" : @"keyboard.chevron.compact.down",
                                               session,
                                               template);
            id a3 = ZLModMakeContextMenuAction(kZLModActionToggleUnread,
                                               unread ? @"Bỏ đánh dấu chưa đọc" : @"Đánh dấu chưa đọc (Chấm xanh)",
                                               unread ? @"envelope.open" : @"envelope.badge",
                                               session,
                                               template);
            id a4 = ZLModMakeContextMenuAction(kZLModActionPrivateNote,
                                               hasNote ? @"Ghi chú riêng tư (Đã có)" : @"Thêm ghi chú riêng tư...",
                                               hasNote ? @"note.text" : @"note.text.badge.plus",
                                               session,
                                               template);
            if (a1) [customItems addObject:a1];
            if (a2) [customItems addObject:a2];
            if (a3) [customItems addObject:a3];
            if (a4) [customItems addObject:a4];

            if (isSectioned) {
                if (customItems.count == 0) return origList;
                NSMutableArray *sections = [origArray mutableCopy];
                NSUInteger insertIdx = (sections.count > 1) ? (sections.count - 1) : sections.count;
                [sections insertObject:[customItems copy] atIndex:insertIdx];
                return [sections copy];
            } else {
                NSMutableArray *combined = [origArray mutableCopy];
                [combined addObjectsFromArray:customItems];
                return [combined copy];
            }
        })) {
            installed++;
        }
    }

    // 2. -contextMenu:didSelectActionId:forIdentifier: [v40@0:8@16q24@32]
    SEL selectSel = sel_registerName("contextMenu:didSelectActionId:forIdentifier:");
    if (ZLModClassHasInstanceMethod(mgrClass, selectSel)) {
        IMP orig = class_getMethodImplementation(mgrClass, selectSel);
        if (ZLModReplaceMethod(mgrClass, selectSel, 3, "v", ^(id selfObj, id menu, NSInteger actionId, id identifier) {
            if (actionId >= kZLModActionToggleSeen && actionId <= kZLModActionPrivateNote) {
                ZLModMenuSession *session = ZLModConsumeMenuSessionForIdentifier(menu ?: selfObj, identifier);
                if (session) {
                    ZLModExecuteMenuAction(actionId, session);
                } else {
                    ZLModShowToast(@"Phiên menu đã hết hạn — vui lòng thử lại");
                }
                return;
            }
            if (orig) ((void (*)(id, SEL, id, NSInteger, id))orig)(selfObj, selectSel, menu, actionId, identifier);
        })) {
            installed++;
        }
    }

    return installed;
}

static NSUInteger ZLModInstallInboxCellBadgeHooks(void) {
    NSUInteger installed = 0;

    // 1. Legacy/standard UXInboxMessageCell (-setObject:, -prepareForReuse)
    Class uxCellCls = NSClassFromString(@"UXInboxMessageCell");
    if (uxCellCls) {
        SEL setObjSel = sel_registerName("setObject:");
        if (ZLModClassHasInstanceMethod(uxCellCls, setObjSel)) {
            IMP orig = class_getMethodImplementation(uxCellCls, setObjSel);
            if (ZLModReplaceMethod(uxCellCls, setObjSel, 1, "v", ^(id selfObj, id item) {
                if (orig) ((void (*)(id, SEL, id))orig)(selfObj, setObjSel, item);
                ZLModTrackAndRefreshInboxCell((UIView *)selfObj, item);
            })) {
                installed++;
            }
        }

        SEL reuseSel = sel_registerName("prepareForReuse");
        if (ZLModClassHasInstanceMethod(uxCellCls, reuseSel)) {
            IMP orig = class_getMethodImplementation(uxCellCls, reuseSel);
            if (ZLModReplaceMethod(uxCellCls, reuseSel, 0, "v", ^(id selfObj) {
                if (orig) ((void (*)(id, SEL))orig)(selfObj, reuseSel);
                objc_setAssociatedObject(selfObj, kZLModCellThreadIdAssocKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
                ZLModUpdateUnreadDotForCell((UIView *)selfObj);
            })) {
                installed++;
            }
        }
    }

    // 2. ZADesignSystem ChatListItemCell (-setListItem:, -prepareForReuse)
    Class zdsCellCls = NSClassFromString(@"ChatListItemCell");
    if (zdsCellCls) {
        SEL setListSel = sel_registerName("setListItem:");
        if (ZLModClassHasInstanceMethod(zdsCellCls, setListSel)) {
            IMP orig = class_getMethodImplementation(zdsCellCls, setListSel);
            if (ZLModReplaceMethod(zdsCellCls, setListSel, 1, "v", ^(id selfObj, id listItem) {
                if (orig) ((void (*)(id, SEL, id))orig)(selfObj, setListSel, listItem);
                ZLModTrackAndRefreshInboxCell((UIView *)selfObj, listItem);
            })) {
                installed++;
            }
        }

        SEL reuseSel = sel_registerName("prepareForReuse");
        if (ZLModClassHasInstanceMethod(zdsCellCls, reuseSel)) {
            IMP orig = class_getMethodImplementation(zdsCellCls, reuseSel);
            if (ZLModReplaceMethod(zdsCellCls, reuseSel, 0, "v", ^(id selfObj) {
                if (orig) ((void (*)(id, SEL))orig)(selfObj, reuseSel);
                objc_setAssociatedObject(selfObj, kZLModCellThreadIdAssocKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
                ZLModUpdateUnreadDotForCell((UIView *)selfObj);
            })) {
                installed++;
            }
        }
    }

    return installed;
}

void ZLModConversationMenuInstall(void) {
    NSUInteger menuHooks = ZLModInstallInboxContextMenuHooks();
    NSUInteger cellHooks = ZLModInstallInboxCellBadgeHooks();

    [[NSNotificationCenter defaultCenter] addObserverForName:ZLModConversationPolicyDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ZLModRefreshAllTrackedInboxCells();
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:ZLModAccountDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        os_unfair_lock_lock(&gMenuSessionLock);
        [gMenuSessions removeAllObjects];
        gLatestMenuSession = nil;
        os_unfair_lock_unlock(&gMenuSessionLock);
        ZLModRefreshAllTrackedInboxCells();
    }];

    ZLModSetModuleStatus(@"ConversationMenu",
                         (menuHooks >= 2) ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"menuHooks=%lu cellHooks=%lu",
                          (unsigned long)menuHooks, (unsigned long)cellHooks]);

    ZLMOD_LOG(@"conversation menu installed (menuHooks=%lu cellHooks=%lu)",
              (unsigned long)menuHooks, (unsigned long)cellHooks);
}
