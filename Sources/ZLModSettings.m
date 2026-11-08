// language: Objective-C, file: ZLModSettings.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Native Settings integration — injects "ZLMod Customize" as a cloned sibling of
// the "Account and security" row inside SettingUI40TableViewController (the
// settings hub class that owns accountAndSecurityObject / _accountAndSecurityObject).
//
// Primary tier: deep-copy the real cell object, retitle it, insert it directly
// above "Account and security" in the arranged content, and intercept row
// selection to push the ZLMod dashboard. The row that ships is a genuine Zalo
// cell object — identical height, padding, typography, separator and behaviour.
//
// Fallback tier (only if the model cannot be reached): one extra row injected
// via numberOfRows/cellForRow interception using a Zalo cell class when it can
// be instantiated, otherwise a standard grouped cell.

#import "ZLMod.h"

#pragma mark - State

static id gOurRow = nil;
static NSArray<NSArray *> *gSectionSnapshot = nil;
static BOOL gSnapshotAligned = NO;
static BOOL gFallbackActive = NO;
static NSUInteger gInjectAttempts = 0;
static Class gSettingsClass = Nil;

static NSArray<NSString *> *ZLModKnownAccountTitleValues(void) {
    return @[@"Tài khoản và bảo mật",
             @"Account and security",
             @"00Zh8W",
             @"tabme.section_items.account_security.title",
             @"tabme_account_security"];
}

static void ZLModEnsureRow(id vc);
static char ZLModRetryCountKey;
static const NSUInteger kZLModMaxBFNodes = 4000;

// class_copyIvarList only returns ivars declared on the exact class — model,
// cell and category state in Zalo lives on superclasses (e.g. model/actions
// on BasicSettingTableViewController, title on BasicSettingCellV2Object
// parents). Walk the full chain so discovery, cloning and retitling all see
// inherited state.
static NSArray<NSValue *> *ZLModAllIvars(Class cls) {
    NSMutableArray<NSValue *> *list = [NSMutableArray array];
    Class current = cls;
    while (current && current != [NSObject class]) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned int i = 0; i < count; i++) {
            [list addObject:[NSValue valueWithPointer:(void *)ivars[i]]];
        }
        free(ivars);
        current = class_getSuperclass(current);
    }
    return list;
}

#pragma mark - Object cloning

// object_setIvar does not retain; ARC-managed ivars will release on dealloc.
// Retain once here so the clone owns exactly one reference, like a normal assignment.
static void ZLModSetIvarRetained(id object, Ivar ivar, id value) {
    if (value) CFRetain((__bridge CFTypeRef)value);
    object_setIvar(object, ivar, value);
}

static id ZLModCloneCellObject(id source) {
    if (!source) return nil;
    Class cls = object_getClass(source);
    if (!cls) return nil;

    // NSObject's default copyWithZone: returns self — only a real copy helps.
    if ([source respondsToSelector:@selector(copyWithZone:)]) {
        @try {
            id copy = [source copy];
            if (copy && copy != source && object_getClass(copy) == cls) return copy;
        } @catch (__unused NSException *e) {}
    }

    id clone = nil;
    @try { clone = [[cls alloc] init]; } @catch (__unused NSException *e) { return nil; }
    if (!clone) return nil;

    for (NSValue *boxed in ZLModAllIvars(cls)) {
        Ivar ivar = (Ivar)boxed.pointerValue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] == '\0') continue;
        if (type[0] == '@') {
            @try {
                id value = object_getIvar(source, ivar);
                if (value) ZLModSetIvarRetained(clone, ivar, value);
            } @catch (__unused NSException *e) {}
        } else {
            NSUInteger size = 0;
            NSGetSizeAndAlignment(type, &size, NULL);
            if (size > 0 && size <= 64) {
                ptrdiff_t offset = ivar_getOffset(ivar);
                memcpy((uint8_t *)(__bridge void *)clone + offset,
                       (const uint8_t *)(__bridge const void *)source + offset, size);
            }
        }
    }
    return clone;
}

static BOOL ZLModRetitleCellObject(id object, NSString *newTitle, NSString **outOldValue) {
    if (!object) return NO;
    NSArray<NSString *> *known = ZLModKnownAccountTitleValues();
    Class cls = object_getClass(object);
    BOOL done = NO;
    for (NSValue *boxed in ZLModAllIvars(cls)) {
        if (done) break;
        Ivar ivar = (Ivar)boxed.pointerValue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@') continue;
        id value = nil;
        @try { value = object_getIvar(object, ivar); } @catch (__unused NSException *e) { continue; }
        if (![value isKindOfClass:[NSString class]]) continue;
        if ([known containsObject:value]) {
            if (outOldValue) *outOldValue = value;
            @try { ZLModSetIvarRetained(object, ivar, newTitle); } @catch (__unused NSException *e) { continue; }
            done = YES;
        }
    }

    if (!done) {
        for (NSString *key in @[@"title", @"name", @"text", @"cellTitle", @"localizedTitle"]) {
            @try {
                id value = [object valueForKey:key];
                if ([value isKindOfClass:[NSString class]] &&
                    ([ZLModKnownAccountTitleValues() containsObject:value] || [value containsString:@"account_security"])) {
                    [object setValue:newTitle forKey:key];
                    done = YES;
                    break;
                }
            } @catch (__unused NSException *e) {}
        }
    }
    return done;
}

#pragma mark - Model discovery

@interface ZLModBFSNode : NSObject
@property (nonatomic, strong) id node;
@property (nonatomic, strong) id parent;
@property (nonatomic, strong) ZLModBFSNode *parentEntry;
@property (nonatomic, assign) NSUInteger indexInParent;
@property (nonatomic, strong) id keyInParent;
@property (nonatomic, assign) Ivar parentIvar;
@end

@implementation ZLModBFSNode
@end

static BOOL ZLModSkipTraversalClass(id node) {
    return [node isKindOfClass:[NSString class]] || [node isKindOfClass:[NSNumber class]] ||
           [node isKindOfClass:[NSData class]] || [node isKindOfClass:[NSDate class]] ||
           [node isKindOfClass:[NSURL class]] || [node isKindOfClass:[NSSet class]] ||
           [node isKindOfClass:[NSValue class]] || [node isKindOfClass:[NSNull class]] ||
           [node isKindOfClass:[UIView class]] || [node isKindOfClass:[UIViewController class]];
}

static NSMutableArray<ZLModBFSNode *> *ZLModCollectCandidates(id root, NSUInteger maxDepth) {
    NSMutableArray<ZLModBFSNode *> *all = [NSMutableArray array];
    NSMutableArray<ZLModBFSNode *> *queue = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];

    ZLModBFSNode *rootNode = [ZLModBFSNode new];
    rootNode.node = root;
    [queue addObject:rootNode];

    NSUInteger depth = 0;
    while (queue.count > 0 && depth < maxDepth && all.count < kZLModMaxBFNodes) {
        NSMutableArray<ZLModBFSNode *> *next = [NSMutableArray array];
        for (ZLModBFSNode *entry in queue) {
            id node = entry.node;
            if (!node || ZLModSkipTraversalClass(node)) continue;
            NSValue *ptr = [NSValue valueWithPointer:(__bridge const void *)node];
            if ([seen containsObject:ptr]) continue;
            [seen addObject:ptr];
            [all addObject:entry];

            if ([node isKindOfClass:[NSArray class]]) {
                NSArray *array = node;
                for (NSUInteger i = 0; i < array.count; i++) {
                    id child = array[i];
                    if (!child || ZLModSkipTraversalClass(child)) continue;
                    ZLModBFSNode *n = [ZLModBFSNode new];
                    n.node = child;
                    n.parent = node;
                    n.parentEntry = entry;
                    n.indexInParent = i;
                    [next addObject:n];
                }
            } else if ([node isKindOfClass:[NSDictionary class]]) {
                NSDictionary *dict = node;
                for (id key in dict) {
                    id child = dict[key];
                    if (!child || ZLModSkipTraversalClass(child)) continue;
                    ZLModBFSNode *n = [ZLModBFSNode new];
                    n.node = child;
                    n.parent = node;
                    n.parentEntry = entry;
                    n.keyInParent = key;
                    [next addObject:n];
                }
            } else {
                for (NSValue *boxed in ZLModAllIvars(object_getClass(node))) {
                    Ivar ivar = (Ivar)boxed.pointerValue;
                    const char *type = ivar_getTypeEncoding(ivar);
                    if (!type || type[0] != '@') continue;
                    id child = nil;
                    @try { child = object_getIvar(node, ivar); } @catch (__unused NSException *e) { continue; }
                    if (!child || ZLModSkipTraversalClass(child)) continue;
                    ZLModBFSNode *n = [ZLModBFSNode new];
                    n.node = child;
                    n.parent = node;
                    n.parentEntry = entry;
                    n.parentIvar = ivar;
                    [next addObject:n];
                }
            }
        }
        [queue setArray:next];
        depth++;
    }
    return all;
}

// Places `value` into the slot that currently holds `child.node` (parent object
// via ivar, or parent collection via index/key). Returns NO when the parent is
// an immutable collection (caller must climb one level and retry with a copy).
static BOOL ZLModPlaceValue(id value, ZLModBFSNode *child) {
    id parent = child.parent;
    @try {
        if ([parent isKindOfClass:[NSMutableArray class]]) {
            [(NSMutableArray *)parent replaceObjectAtIndex:child.indexInParent withObject:value];
            return YES;
        }
        if ([parent isKindOfClass:[NSMutableDictionary class]]) {
            [(NSMutableDictionary *)parent setObject:value forKey:child.keyInParent];
            return YES;
        }
        if (child.parentIvar != NULL) {
            ZLModSetIvarRetained(parent, child.parentIvar, value);
            return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

// Walks up from the matched array, converting every immutable ancestor
// (array/dictionary) into a mutable copy that is re-linked into its own parent,
// so the returned NSMutableArray is reachable from the live object graph.
static NSMutableArray *ZLModMakeMutableChain(ZLModBFSNode *match) {
    id node = match.node;
    if (![node isKindOfClass:[NSArray class]]) return nil;

    id value = [node isKindOfClass:[NSMutableArray class]] ? node : [node mutableCopy];
    if (![value isKindOfClass:[NSMutableArray class]]) return nil;

    ZLModBFSNode *child = match;
    while (child) {
        if (ZLModPlaceValue(value, child)) return (NSMutableArray *)value;

        id parent = child.parent;
        if (![parent isKindOfClass:[NSArray class]] && ![parent isKindOfClass:[NSDictionary class]]) return nil;
        id newParent = [parent mutableCopy];
        if (!newParent) return nil;
        if ([newParent isKindOfClass:[NSMutableArray class]]) {
            [(NSMutableArray *)newParent replaceObjectAtIndex:child.indexInParent withObject:value];
        } else if ([newParent isKindOfClass:[NSMutableDictionary class]] && child.keyInParent) {
            [(NSMutableDictionary *)newParent setObject:value forKey:child.keyInParent];
        } else {
            return nil;
        }
        value = newParent;
        child = child.parentEntry;
    }
    return nil;
}

static NSMutableArray *ZLModFindContainerForObject(id root, id target, NSUInteger *outIndex) {
    NSMutableArray<ZLModBFSNode *> *nodes = ZLModCollectCandidates(root, 7);
    for (ZLModBFSNode *entry in nodes) {
        id node = entry.node;
        if (![node isKindOfClass:[NSArray class]]) continue;
        if ([node indexOfObjectIdenticalTo:target] == NSNotFound) continue;

        NSMutableArray *container = ZLModMakeMutableChain(entry);
        if (!container) continue;
        if (outIndex) *outIndex = [container indexOfObjectIdenticalTo:target];
        ZLMOD_LOG(@"ensure: container found via ivar graph");
        return container;
    }

    // Stage 2: arranged content may come from a getter (getArrangedTableContent),
    // not a stored ivar. Only mutate when a containing array is reachable and
    // mutable-ized via the existing chain logic — a throwaway copy is ignored.
    SEL arrangedSel = sel_registerName("getArrangedTableContent");
    if (root && [root respondsToSelector:arrangedSel]) {
        id arranged = nil;
        @try { IMP arrangedImp = [root methodForSelector:arrangedSel]; if (arrangedImp) arranged = ((id (*)(id, SEL))arrangedImp)(root, arrangedSel); } @catch (__unused NSException *e) {}
        if (arranged && arranged != root) {
            if ([arranged isKindOfClass:[NSMutableArray class]] &&
                [arranged indexOfObjectIdenticalTo:target] != NSNotFound) {
                if (outIndex) *outIndex = [arranged indexOfObjectIdenticalTo:target];
                ZLMOD_LOG(@"ensure: container via getArrangedTableContent (mutable root)");
                return arranged;
            }
            NSMutableArray<ZLModBFSNode *> *subNodes = ZLModCollectCandidates(arranged, 4);
            for (ZLModBFSNode *entry in subNodes) {
                id node = entry.node;
                if (![node isKindOfClass:[NSArray class]]) continue;
                if ([node indexOfObjectIdenticalTo:target] == NSNotFound) continue;
                NSMutableArray *container = ZLModMakeMutableChain(entry);
                if (!container) continue;
                if (outIndex) *outIndex = [container indexOfObjectIdenticalTo:target];
                ZLMOD_LOG(@"ensure: container via getArrangedTableContent");
                return container;
            }
            ZLMOD_LOG(@"ensure: getArrangedTableContent reachable but no mutable container");
        }
    }
    ZLMOD_LOG(@"ensure: container not found");
    return nil;
}

static id ZLModFetchAccountObject(id vc) {
    if (!vc) return nil;
    @try {
        id value = [vc valueForKey:@"accountAndSecurityObject"];
        if (value) return value;
    } @catch (__unused NSException *e) {}

    for (NSValue *boxed in ZLModAllIvars(object_getClass(vc))) {
        Ivar ivar = (Ivar)boxed.pointerValue;
        const char *name = ivar_getName(ivar);
        if (name && strcmp(name, "_accountAndSecurityObject") == 0) {
            id found = nil;
            @try { found = object_getIvar(vc, ivar); } @catch (__unused NSException *e) {}
            return found;
        }
    }
    return nil;
}

#pragma mark - Snapshot (for row mapping)

static void ZLModRefreshSnapshot(id vc) {
    NSMutableArray<NSArray *> *sections = [NSMutableArray array];
    NSMutableArray<ZLModBFSNode *> *nodes = ZLModCollectCandidates(vc, 7);
    for (ZLModBFSNode *entry in nodes) {
        id node = entry.node;
        if (![node isKindOfClass:[NSArray class]]) continue;
        NSArray *array = node;
        if (array.count == 0) continue;
        BOOL cellObjectLike = YES;
        for (id element in array) {
            if ([element isKindOfClass:[NSArray class]] || [element isKindOfClass:[NSDictionary class]]) { cellObjectLike = NO; break; }
            NSString *clsName = NSStringFromClass(object_getClass(element));
            if (!([clsName containsString:@"CellObject"] || [clsName containsString:@"Object"])) { cellObjectLike = NO; break; }
        }
        if (cellObjectLike) [sections addObject:array];
    }
    gSectionSnapshot = sections;

    gSnapshotAligned = NO;
    if ([vc isKindOfClass:[UITableViewController class]]) {
        UITableView *tv = [(UITableViewController *)vc tableView];
        NSInteger sectionCount = [tv numberOfSections];
        if (sectionCount == (NSInteger)sections.count) {
            gSnapshotAligned = YES;
            for (NSInteger s = 0; s < sectionCount; s++) {
                if ([tv numberOfRowsInSection:s] != (NSInteger)sections[(NSUInteger)s].count) {
                    gSnapshotAligned = NO;
                    break;
                }
            }
        }
    }
}

#pragma mark - Injection

static BOOL ZLModInjectRow(id vc) {
    if (gOurRow) return YES;
    id accountObject = ZLModFetchAccountObject(vc);
    ZLMOD_LOG(@"ensure: accountObject=%@",
             accountObject ? NSStringFromClass(object_getClass(accountObject)) : @"<nil>");
    if (!accountObject) return NO;

    NSUInteger accountIndex = 0;
    NSMutableArray *container = ZLModFindContainerForObject(vc, accountObject, &accountIndex);
    ZLMOD_LOG(@"ensure: container=%@ count=%lu index=%lu",
             container ? NSStringFromClass(object_getClass(container)) : @"<nil>",
             (unsigned long)container.count, (unsigned long)accountIndex);
    if (!container) return NO;

    id clone = ZLModCloneCellObject(accountObject);
    ZLMOD_LOG(@"ensure: clone=%@", clone ? NSStringFromClass(object_getClass(clone)) : @"<nil>");
    if (!clone) return NO;
    NSString *oldTitle = nil;
    if (!ZLModRetitleCellObject(clone, @"ZLMod Customize", &oldTitle)) {
        ZLMOD_LOG(@"ensure: retitle failed (old=%@) — row not injected", oldTitle ? oldTitle : @"<nil>");
        return NO;
    }
    ZLMOD_LOG(@"ensure: retitled %@ -> ZLMod Customize", oldTitle ? oldTitle : @"<unknown>");

    NSUInteger insertIndex = MIN(accountIndex, container.count);
    @try {
        [container insertObject:clone atIndex:insertIndex];
    } @catch (__unused NSException *e) {
        ZLMOD_LOG(@"ensure: insert threw");
        return NO;
    }

    gOurRow = clone;
    gFallbackActive = NO;
    ZLModRefreshSnapshot(vc);
    BOOL visibleInSnapshot = NO;
    if (gSectionSnapshot) {
        for (NSArray *array in gSectionSnapshot) {
            if ([array indexOfObjectIdenticalTo:gOurRow] != NSNotFound) { visibleInSnapshot = YES; break; }
        }
    }
    ZLMOD_LOG(@"ensure: ZLMod Customize row injected at index %lu (visible-in-snapshot=%d)",
             (unsigned long)insertIndex, visibleInSnapshot);
    return YES;
}

static void ZLModReloadTable(id vc) {
    if (![NSThread isMainThread]) {
        __weak id weakVC = vc;
        dispatch_async(dispatch_get_main_queue(), ^{ ZLModReloadTable(weakVC); });
        return;
    }
    UITableView *tv = nil;
    if ([vc isKindOfClass:[UITableViewController class]]) {
        tv = [(UITableViewController *)vc tableView];
    } else if ([vc isKindOfClass:[UIViewController class]]) {
        NSArray *subviews = [[(UIViewController *)vc view] subviews];
        for (UIView *view in subviews) {
            if ([view isKindOfClass:[UITableView class]]) { tv = (UITableView *)view; break; }
        }
    }
    if (tv) [tv reloadData];
}

static UITableView *ZLModTableViewForVC(id vc) {
    if (!vc) return nil;
    UITableView *tv = nil;
    if ([vc isKindOfClass:[UITableViewController class]]) {
        tv = [(UITableViewController *)vc tableView];
    } else if ([vc isKindOfClass:[UIViewController class]]) {
        NSArray *subviews = [[(UIViewController *)vc view] subviews];
        for (UIView *view in subviews) {
            if ([view isKindOfClass:[UITableView class]]) { tv = (UITableView *)view; break; }
        }
    }
    return tv;
}

static BOOL ZLModTableReady(id vc) {
    UITableView *tv = nil;
    if ([vc isKindOfClass:[UITableViewController class]]) {
        tv = [(UITableViewController *)vc tableView];
    }
    return tv != nil && [tv numberOfSections] > 0;
}

static void ZLModScheduleRetry(id vc) {
    if (gOurRow || gFallbackActive) return;
    NSNumber *doneNum = objc_getAssociatedObject(vc, &ZLModRetryCountKey);
    NSInteger tries = doneNum ? doneNum.integerValue : 0;
    if (tries >= 2) return;
    objc_setAssociatedObject(vc, &ZLModRetryCountKey, @(tries + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSTimeInterval delay = tries == 0 ? 1.0 : 3.0;
    ZLMOD_LOG(@"ensure: retry %ld in %.0fs", (long)(tries + 1), delay);
    __weak id weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (weakVC && !gOurRow && !gFallbackActive) {
            @try { ZLModEnsureRow(weakVC); } @catch (__unused NSException *e) {}
        }
    });
}

static void ZLModEnsureRow(id vc) {
    if (!vc) return;
    if (gOurRow) {
        // Re-insert if the model was rebuilt without our row.
        BOOL stillPresent = NO;
        if (gSectionSnapshot) {
            for (NSArray *array in gSectionSnapshot) {
                if ([array indexOfObjectIdenticalTo:gOurRow] != NSNotFound) { stillPresent = YES; break; }
            }
        }
        if (!stillPresent) {
            gInjectAttempts++;
            id accountObject = ZLModFetchAccountObject(vc);
            NSUInteger idx = 0;
            NSMutableArray *container = accountObject ? ZLModFindContainerForObject(vc, accountObject, &idx) : nil;
            if (container) {
                if ([container indexOfObjectIdenticalTo:gOurRow] == NSNotFound) {
                    BOOL inserted = NO;
                    @try { [container insertObject:gOurRow atIndex:MIN(idx, container.count)]; inserted = YES; } @catch (__unused NSException *e) {}
                    ZLMOD_LOG(@"ensure: re-inserted row=%d", inserted);
                    if (inserted) ZLModReloadTable(vc);
                }
            } else {
                ZLMOD_LOG(@"ensure: model gone — clearing row for re-clone");
                gOurRow = nil; // model gone; re-clone next pass
            }
        }
        ZLModRefreshSnapshot(vc);
        if (!gOurRow) ZLModInjectRow(vc);
        return;
    }

    gInjectAttempts++;
    BOOL injected = NO;
    @try { injected = ZLModInjectRow(vc); } @catch (__unused NSException *e) { injected = NO; }
    if (injected) {
        // Per-VC retry count (associated object) resets on primary success;
        // the global attempt counter remains a backstop only and never gates
        // fallback on its own (see below).
        objc_setAssociatedObject(vc, &ZLModRetryCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ZLModReloadTable(vc);
    } else {
        NSNumber *doneNum = objc_getAssociatedObject(vc, &ZLModRetryCountKey);
        NSInteger tries = doneNum ? doneNum.integerValue : 0;
        UITableView *tableView = ZLModTableViewForVC(vc);
        BOOL hasTableView = tableView != nil;
        BOOL tableReady = ZLModTableReady(vc);
        ZLMOD_LOG(@"ensure: primary inject failed (attempts=%lu perVCtries=%ld hasTableView=%d tableReady=%d)",
                 (unsigned long)gInjectAttempts, (long)tries, hasTableView, tableReady);
        // Deterministic fallback: two primary failures in a row with a
        // non-nil tableView show the fallback immediately. tableReady alone
        // never blocks fallback (a buggy ready check is a suspected
        // blocker) — once per-VC retries are exhausted, fall back anyway.
        if ((tries >= 1 && hasTableView) || tries >= 2 || gInjectAttempts >= 10) {
            gFallbackActive = YES;
            ZLMOD_LOG(@"ensure: primary exhausted after %lu attempts (perVCtries=%ld hasTableView=%d tableReady=%d) — fallback row active",
                     (unsigned long)gInjectAttempts, (long)tries, hasTableView, tableReady);
            ZLModReloadTable(vc);
        } else {
            ZLModScheduleRetry(vc);
        }
    }
}

#pragma mark - Fallback cell

static UITableViewCell *ZLModBuildFallbackCell(UITableView *tv, NSIndexPath *indexPath) {
    NSString *reuse = @"ZLModCustomizeRow";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:reuse];
    if (cell) return cell;

    for (NSString *name in @[@"BasicSettingCell", @"BasicSettingCellV2"]) {
        Class cls = NSClassFromString(name);
        if (!cls || ![cls isSubclassOfClass:[UITableViewCell class]]) continue;
        @try {
            cell = [[cls alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse];
        } @catch (__unused NSException *e) { cell = nil; }
        if (cell) break;
    }

    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse];
        cell.textLabel.font = [UIFont systemFontOfSize:17.0];
        cell.textLabel.textColor = [UIColor labelColor];
    }
    cell.textLabel.text = @"ZLMod Customize";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark - Row selection

static BOOL ZLModHandleSelection(id vc, NSIndexPath *indexPath, UITableView *tv) {
    if (gOurRow) {
        id tapped = nil;
        if (gSnapshotAligned && indexPath.section < (NSInteger)gSectionSnapshot.count) {
            NSArray *section = gSectionSnapshot[(NSUInteger)indexPath.section];
            if (indexPath.row < (NSInteger)section.count) tapped = section[(NSUInteger)indexPath.row];
        }
        if (!tapped) {
            for (NSArray *section in gSectionSnapshot) {
                NSUInteger idx = [section indexOfObjectIdenticalTo:gOurRow];
                if (idx != NSNotFound && (NSInteger)idx == indexPath.row &&
                    [tv numberOfRowsInSection:indexPath.section] == (NSInteger)section.count) {
                    tapped = section[idx];
                    break;
                }
            }
        }
        if (tapped == gOurRow) {
            [ZLModSettingsViewController pushFrom:vc];
            [tv deselectRowAtIndexPath:indexPath animated:YES];
            return YES;
        }
        return NO;
    }

    if (gFallbackActive && indexPath.section == 0 && indexPath.row == 0) {
        [ZLModSettingsViewController pushFrom:vc];
        [tv deselectRowAtIndexPath:indexPath animated:YES];
        return YES;
    }
    return NO;
}

#pragma mark - Install

typedef void (*ZLModV0)(id, SEL);
typedef void (*ZLModV1Bool)(id, SEL, BOOL);
typedef void (*ZLModV2)(id, SEL, id, id);
typedef NSInteger (*ZLModQ2)(id, SEL, id, NSInteger);
typedef id (*ZLModObj2)(id, SEL, id, id);

void ZLModSettingsInstall(void) {
    gSettingsClass = NSClassFromString(@"SettingUI40TableViewController");
    BOOL settingsClassFound = gSettingsClass != Nil;
    ZLMOD_LOG(@"settings hub class SettingUI40TableViewController found=%d (%@)",
             settingsClassFound, gSettingsClass ? NSStringFromClass(gSettingsClass) : @"<nil>");
    if (!gSettingsClass) {
        ZLModSetModuleStatus(@"Settings", ZLModModuleStatusNotInstalled,
                             @"SettingUI40TableViewController not found");
        ZLMOD_LOG(@"settings hub class not found — settings integration idle");
        return;
    }

    SEL viewDidLoadSel = sel_registerName("viewDidLoad");
    IMP viewDidLoadOrig = class_getMethodImplementation(gSettingsClass, viewDidLoadSel);
    BOOL okViewDidLoad = ZLModReplaceMethod(gSettingsClass, viewDidLoadSel, 0, "v", ^(id self) {
        ((ZLModV0)viewDidLoadOrig)(self, viewDidLoadSel);
        dispatch_async(dispatch_get_main_queue(), ^{ ZLModEnsureRow(self); });
    });
    ZLMOD_LOG(@"settings hook viewDidLoad validated=%d", okViewDidLoad);

    SEL willAppearSel = sel_registerName("viewWillAppear:");
    IMP willAppearOrig = class_getMethodImplementation(gSettingsClass, willAppearSel);
    BOOL okViewWillAppear = ZLModReplaceMethod(gSettingsClass, willAppearSel, 1, "v", ^(id self, BOOL animated) {
        ((ZLModV1Bool)willAppearOrig)(self, willAppearSel, animated);
        ZLModEnsureRow(self);
    });
    ZLMOD_LOG(@"settings hook viewWillAppear: validated=%d", okViewWillAppear);

    SEL didAppearSel = sel_registerName("viewDidAppear:");
    IMP didAppearOrig = class_getMethodImplementation(gSettingsClass, didAppearSel);
    BOOL okViewDidAppear = ZLModReplaceMethod(gSettingsClass, didAppearSel, 1, "v", ^(id self, BOOL animated) {
        ((ZLModV1Bool)didAppearOrig)(self, didAppearSel, animated);
        dispatch_async(dispatch_get_main_queue(), ^{ ZLModEnsureRow(self); });
    });
    ZLMOD_LOG(@"settings hook viewDidAppear: validated=%d", okViewDidAppear);

    SEL updateTitleSel = sel_registerName("updateTitleObjects");
    BOOL okUpdateTitle = NO;
    if (ZLModClassHasInstanceMethod(gSettingsClass, updateTitleSel)) {
        IMP updateTitleOrig = class_getMethodImplementation(gSettingsClass, updateTitleSel);
        okUpdateTitle = ZLModReplaceMethod(gSettingsClass, updateTitleSel, 0, "v", ^(id self) {
            ((ZLModV0)updateTitleOrig)(self, updateTitleSel);
            dispatch_async(dispatch_get_main_queue(), ^{ ZLModEnsureRow(self); });
        });
    }
    ZLMOD_LOG(@"settings hook updateTitleObjects validated=%d", okUpdateTitle);

    SEL didSelectSel = sel_registerName("tableView:didSelectRowAtIndexPath:");
    IMP didSelectOrig = class_getMethodImplementation(gSettingsClass, didSelectSel);
    BOOL okDidSelect = ZLModReplaceMethod(gSettingsClass, didSelectSel, 2, "v", ^(id self, UITableView *tv, NSIndexPath *indexPath) {
        if (ZLModHandleSelection(self, indexPath, tv)) return;
        NSIndexPath *forward = indexPath;
        if (gFallbackActive && !gOurRow && indexPath.section == 0 && indexPath.row > 0) {
            forward = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
        }
        ((ZLModV2)didSelectOrig)(self, didSelectSel, tv, forward);
    });
    ZLMOD_LOG(@"settings hook didSelect validated=%d (tableView:didSelectRowAtIndexPath:)", okDidSelect);

    SEL rowsSel = sel_registerName("tableView:numberOfRowsInSection:");
    BOOL okNumberOfRows = NO;
    if (ZLModClassHasInstanceMethod(gSettingsClass, rowsSel)) {
        IMP rowsOrig = class_getMethodImplementation(gSettingsClass, rowsSel);
        okNumberOfRows = ZLModReplaceMethod(gSettingsClass, rowsSel, 2, "q", ^NSInteger(id self, UITableView *tv, NSInteger section) {
            NSInteger rows = ((ZLModQ2)rowsOrig)(self, rowsSel, tv, section);
            if (gFallbackActive && !gOurRow && section == 0) rows += 1;
            return rows;
        });
    }
    ZLMOD_LOG(@"settings hook numberOfRows validated=%d (tableView:numberOfRowsInSection:)", okNumberOfRows);

    SEL cellSel = sel_registerName("tableView:cellForRowAtIndexPath:");
    BOOL okCellForRow = NO;
    if (ZLModClassHasInstanceMethod(gSettingsClass, cellSel)) {
        IMP cellOrig = class_getMethodImplementation(gSettingsClass, cellSel);
        okCellForRow = ZLModReplaceMethod(gSettingsClass, cellSel, 2, "@", ^id(id self, UITableView *tv, NSIndexPath *indexPath) {
            if (gFallbackActive && !gOurRow && indexPath.section == 0) {
                if (indexPath.row == 0) return ZLModBuildFallbackCell(tv, indexPath);
                NSIndexPath *forward = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
                return ((ZLModObj2)cellOrig)(self, cellSel, tv, forward);
            }
            return ((ZLModObj2)cellOrig)(self, cellSel, tv, indexPath);
        });
    }
    ZLMOD_LOG(@"settings hook cellForRow validated=%d (tableView:cellForRowAtIndexPath:)", okCellForRow);
    ZLMOD_LOG(@"settings hooks summary viewDidAppear:=%d viewWillAppear:=%d updateTitleObjects=%d cellForRow=%d numberOfRows=%d didSelect=%d",
             okViewDidAppear, okViewWillAppear, okUpdateTitle, okCellForRow, okNumberOfRows, okDidSelect);

    // Late install: Settings may already be on screen before hooks land.
    // Scan the key window once (main queue) so the visible instance still
    // gets an injection attempt — no polling loop.
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = ZLModActiveKeyWindow();
        UIViewController *root = window.rootViewController;
        if (!root || window == nil) return;
        NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithObject:root];
        id found = nil;
        while (stack.count > 0 && !found) {
            UIViewController *cursor = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (object_getClass(cursor) == gSettingsClass) { found = cursor; break; }
            [stack addObjectsFromArray:cursor.childViewControllers];
            if (cursor.presentedViewController) [stack addObject:cursor.presentedViewController];
            if ([cursor isKindOfClass:[UINavigationController class]]) {
                [stack addObjectsFromArray:[(UINavigationController *)cursor viewControllers]];
            }
        }
        if (found) {
            ZLMOD_LOG(@"ensure: late install found visible settings screen — injecting");
            @try { ZLModEnsureRow(found); } @catch (__unused NSException *e) {}
        }
    });

    ZLModSetModuleStatus(@"Settings",
                         okDidSelect ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"didAppear=%d willAppear=%d didSelect=%d",
                          okViewDidAppear, okViewWillAppear, okDidSelect]);
    ZLMOD_LOG(@"settings integration installed");
}
