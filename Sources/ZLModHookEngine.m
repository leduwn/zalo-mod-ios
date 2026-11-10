// language: Objective-C, file: ZLModHookEngine.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Runtime discovery, strictly validated instance/class method replacement,
// and ABI-verified property inspection helpers.

#import "ZLMod.h"

BOOL ZLModIsAppRelatedClass(Class cls) {
    if (!cls) return NO;
    // Never message arbitrary classes here: objc_getClassList also returns classes whose
    // superclass is missing (weak-linked), and any message send would trip _objc_fatal.
    // class_getImageName only reads runtime metadata and is always safe.
    const char *image = class_getImageName(cls);
    if (!image) return NO;
    if (strstr(image, "/libZLMod.dylib") != NULL) return NO;
    return strstr(image, "/Zalo.app/") != NULL;
}

BOOL ZLModClassHasInstanceMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    return class_getInstanceMethod(cls, sel) != NULL;
}

BOOL ZLModClassHasClassMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    return class_getClassMethod(cls, sel) != NULL;
}

BOOL ZLModClassHasIvar(Class cls, const char *name) {
    if (!cls || !name) return NO;
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    if (!ivars) return NO;
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        const char *ivarName = ivar_getName(ivars[i]);
        if (ivarName && strcmp(ivarName, name) == 0) { found = YES; break; }
    }
    free(ivars);
    return found;
}

static NSArray<Class> *ZLModAppClassList(void) {
    static NSArray<Class> *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<Class> *result = [NSMutableArray array];
        int count = objc_getClassList(NULL, 0);
        if (count > 0) {
            Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
            if (classes) {
                count = objc_getClassList(classes, count);
                for (int i = 0; i < count; i++) {
                    Class cls = classes[i];
                    if (ZLModIsAppRelatedClass(cls)) [result addObject:cls];
                }
                free(classes);
            }
        }
        cached = [result copy];
        NSLog(@"[ZLMod] app class list cached: %lu classes", (unsigned long)cached.count);
    });
    return cached;
}

void ZLModEnumerateAppClasses(void (^enumerator)(Class cls)) {
    if (!enumerator) return;
    for (Class cls in ZLModAppClassList()) enumerator(cls);
}

static BOOL ZLModValidateAndReplace(Class cls, BOOL isClassMethod, SEL sel,
                                    NSUInteger declaredArgs, const char *allowedReturns,
                                    id hookBlock) {
    if (!cls || !sel || !hookBlock || !allowedReturns) return NO;

    Method method = isClassMethod ? class_getClassMethod(cls, sel)
                                  : class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    NSUInteger totalArgs = method_getNumberOfArguments(method);
    if (totalArgs != declaredArgs + 2) return NO;

    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || encoding[0] == '\0') return NO;
    if (strchr(allowedReturns, encoding[0]) == NULL) return NO;

    static NSMutableSet *hooked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ hooked = [NSMutableSet set]; });
    NSString *pairKey = [NSString stringWithFormat:@"%c|%s|%s",
                         isClassMethod ? '+' : '-',
                         class_getName(cls),
                         sel_getName(sel)];
    @synchronized (hooked) {
        if ([hooked containsObject:pairKey]) return NO;
        [hooked addObject:pairKey];
    }

    IMP replacement = imp_implementationWithBlock(hookBlock);
    if (!replacement) return NO;

    Class targetClass = isClassMethod ? object_getClass(cls) : cls;
    if (!targetClass) return NO;
    class_replaceMethod(targetClass, sel, replacement, encoding);
    ZLMOD_LOG(@"hook %s %c[%s]", sel_getName(sel), isClassMethod ? '+' : '-', class_getName(cls));
    return YES;
}

BOOL ZLModReplaceMethod(Class cls, SEL sel, NSUInteger declaredArgs,
                        const char *allowedReturns, id hookBlock) {
    return ZLModValidateAndReplace(cls, NO, sel, declaredArgs, allowedReturns, hookBlock);
}

BOOL ZLModReplaceClassMethod(Class cls, SEL sel, NSUInteger declaredArgs,
                             const char *allowedReturns, id hookBlock) {
    return ZLModValidateAndReplace(cls, YES, sel, declaredArgs, allowedReturns, hookBlock);
}

#pragma mark - ABI-validated safe property readers

id ZLModSafeObjectProperty(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m || method_getNumberOfArguments(m) != 2) return nil;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || enc[0] != '@') return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

NSString *ZLModSafeStringProperty(id obj, SEL sel) {
    id val = ZLModSafeObjectProperty(obj, sel);
    if ([val isKindOfClass:[NSString class]]) return (NSString *)val;
    if ([val isKindOfClass:[NSNumber class]]) return [(NSNumber *)val stringValue];
    return nil;
}

BOOL ZLModSafeBoolProperty(id obj, SEL sel, BOOL defaultValue) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return defaultValue;
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m || method_getNumberOfArguments(m) != 2) return defaultValue;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || enc[0] == '\0') return defaultValue;
    @try {
        if (enc[0] == 'B') {
            return ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
        }
        if (enc[0] == 'c') {
            return ((signed char (*)(id, SEL))objc_msgSend)(obj, sel) != 0;
        }
        if (enc[0] == 'i' || enc[0] == 'q') {
            return ((NSInteger (*)(id, SEL))objc_msgSend)(obj, sel) != 0;
        }
        if (enc[0] == '@') {
            id val = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
            if ([val respondsToSelector:@selector(boolValue)]) return [val boolValue];
        }
    } @catch (__unused NSException *e) {}
    return defaultValue;
}

int64_t ZLModSafeInt64Property(id obj, SEL sel, int64_t defaultValue) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return defaultValue;
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m || method_getNumberOfArguments(m) != 2) return defaultValue;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || enc[0] == '\0') return defaultValue;
    @try {
        switch (enc[0]) {
            case 'q': return ((int64_t (*)(id, SEL))objc_msgSend)(obj, sel);
            case 'Q': return (int64_t)((uint64_t (*)(id, SEL))objc_msgSend)(obj, sel);
            case 'i': return (int64_t)((int (*)(id, SEL))objc_msgSend)(obj, sel);
            case 'I': return (int64_t)((unsigned int (*)(id, SEL))objc_msgSend)(obj, sel);
            case 'l': return (int64_t)((long (*)(id, SEL))objc_msgSend)(obj, sel);
            case 's': return (int64_t)((short (*)(id, SEL))objc_msgSend)(obj, sel);
            case '@': {
                id val = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
                if ([val respondsToSelector:@selector(longLongValue)]) return [val longLongValue];
                break;
            }
            default: break;
        }
    } @catch (__unused NSException *e) {}
    return defaultValue;
}

double ZLModSafeDoubleProperty(id obj, SEL sel, double defaultValue) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return defaultValue;
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m || method_getNumberOfArguments(m) != 2) return defaultValue;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || enc[0] == '\0') return defaultValue;
    @try {
        switch (enc[0]) {
            case 'd': return ((double (*)(id, SEL))objc_msgSend)(obj, sel);
            case 'f': return (double)((float (*)(id, SEL))objc_msgSend)(obj, sel);
            case 'q': return (double)((int64_t (*)(id, SEL))objc_msgSend)(obj, sel);
            case 'Q': return (double)((uint64_t (*)(id, SEL))objc_msgSend)(obj, sel);
            case '@': {
                id val = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
                if ([val respondsToSelector:@selector(doubleValue)]) return [val doubleValue];
                break;
            }
            default: break;
        }
    } @catch (__unused NSException *e) {}
    return defaultValue;
}

UIWindow *ZLModActiveKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    UIWindow *fallback = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        BOOL isForeground = (ws.activationState == UISceneActivationStateForegroundActive);
        for (UIWindow *win in ws.windows) {
            if (isForeground && win.isKeyWindow) return win;
            if (!fallback && !win.hidden) fallback = win;
        }
    }
    return fallback;
}
