// language: Objective-C, file: ZLModCore.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Initialization, lifecycle, redacted bounded logging, module status registry,
// and login/logout session notifications.

#import "ZLMod.h"
#include <stdio.h>
#import <os/lock.h>

NSString *const ZLModAccountDidChangeNotification = @"ZLModAccountDidChangeNotification";
NSString *const ZLModModuleStatusNotInstalled = @"NOT_INSTALLED";
NSString *const ZLModModuleStatusHookInstalled = @"HOOK_INSTALLED";

static const NSUInteger kZLModRingBufferCapacity = 200;
static const unsigned long long kZLModMaxLogFileBytes = 512ULL * 1024ULL;
static const NSUInteger kZLModKeepTailBytes = 256U * 1024U;

static os_unfair_lock gLogRingLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<NSString *> *gLogRingBuffer = nil;

static os_unfair_lock gStatusLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *gModuleStatuses = nil;

#pragma mark - Redaction & persistent file log

NSString *ZLModRedactText(NSString *input) {
    if (!input || input.length == 0) return input ?: @"";
    static NSRegularExpression *querySecretRegex = nil;
    static NSRegularExpression *bearerRegex = nil;
    static NSRegularExpression *longDigitsRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        querySecretRegex = [NSRegularExpression
            regularExpressionWithPattern:@"((?:access_token|token|session|auth|sig|secret|password|pwd)=)([^&\\s]+)"
                                 options:NSRegularExpressionCaseInsensitive
                                   error:nil];
        bearerRegex = [NSRegularExpression
            regularExpressionWithPattern:@"(Bearer\\s+)[A-Za-z0-9._\\-+/=]+"
                                 options:NSRegularExpressionCaseInsensitive
                                   error:nil];
        // Redact 10+ digit numbers (user IDs / phone numbers) while leaving
        // 9-digit Zalo build codes (261002802 / 261101802) and timestamps readable.
        longDigitsRegex = [NSRegularExpression
            regularExpressionWithPattern:@"(?<![0-9A-Za-z_])[0-9]{10,}(?![0-9A-Za-z_])"
                                 options:0
                                   error:nil];
    });

    NSString *output = input;
    @try {
        if (querySecretRegex) {
            output = [querySecretRegex stringByReplacingMatchesInString:output
                                                                options:0
                                                                  range:NSMakeRange(0, output.length)
                                                           withTemplate:@"$1<redacted>"];
        }
        if (bearerRegex) {
            output = [bearerRegex stringByReplacingMatchesInString:output
                                                           options:0
                                                             range:NSMakeRange(0, output.length)
                                                      withTemplate:@"$1<redacted>"];
        }
        if (longDigitsRegex) {
            output = [longDigitsRegex stringByReplacingMatchesInString:output
                                                               options:0
                                                                 range:NSMakeRange(0, output.length)
                                                          withTemplate:@"<id_redacted>"];
        }
    } @catch (__unused NSException *e) {
        return input;
    }
    return output;
}

static dispatch_queue_t ZLModFileLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("zlmod.filelog", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSArray<NSURL *> *ZLModFileLogURLs(void) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSURL *documents = nil;
    @try {
        NSArray<NSURL *> *found = [[NSFileManager defaultManager]
                                    URLsForDirectory:NSDocumentDirectory
                                            inDomains:NSUserDomainMask];
        documents = found.firstObject;
    } @catch (__unused NSException *e) { documents = nil; }
    if (documents) {
        [urls addObject:[documents URLByAppendingPathComponent:@"ZLMod.log"]];
    } else {
        NSString *tmpPath = NSTemporaryDirectory();
        if (tmpPath) {
            [urls addObject:[NSURL fileURLWithPath:[tmpPath stringByAppendingPathComponent:@"ZLMod.log"]]];
        }
    }
    @try {
        NSURL *group = [[NSFileManager defaultManager]
                        containerURLForSecurityApplicationGroupIdentifier:@"group.zsettings.vn.com.vng.zingalo"];
        if (group) [urls addObject:[group URLByAppendingPathComponent:@"ZLMod.log"]];
    } @catch (__unused NSException *e) {}
    return urls;
}

NSString *ZLModPrimaryLogPath(void) {
    return ZLModFileLogURLs().firstObject.path ?: @"";
}

static void ZLModAppendRingLine(NSString *line) {
    if (!line || line.length == 0) return;
    os_unfair_lock_lock(&gLogRingLock);
    if (!gLogRingBuffer) {
        gLogRingBuffer = [NSMutableArray arrayWithCapacity:kZLModRingBufferCapacity];
    }
    [gLogRingBuffer addObject:line];
    while (gLogRingBuffer.count > kZLModRingBufferCapacity) {
        [gLogRingBuffer removeObjectAtIndex:0];
    }
    os_unfair_lock_unlock(&gLogRingLock);
}

static void ZLModRotateLogIfNeeded(NSFileManager *manager, NSURL *url) {
    NSDictionary *attrs = [manager attributesOfItemAtPath:url.path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size <= kZLModMaxLogFileBytes) return;

    NSData *existing = [NSData dataWithContentsOfURL:url];
    if (!existing || existing.length <= kZLModKeepTailBytes) return;
    NSUInteger start = existing.length - kZLModKeepTailBytes;
    const uint8_t *bytes = (const uint8_t *)existing.bytes;
    while (start < existing.length && bytes[start] != '\n') {
        start++;
    }
    if (start < existing.length) start++;
    NSData *tail = (start < existing.length)
        ? [existing subdataWithRange:NSMakeRange(start, existing.length - start)]
        : [NSData data];
    [tail writeToURL:url options:NSDataWritingAtomic error:nil];
}

void ZLModFileLog(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message) return;

    NSString *safeMessage = ZLModRedactText(message);
    static NSDateFormatter *formatter = nil;
    static os_unfair_lock fmtLock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&fmtLock);
    if (!formatter) {
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    }
    NSString *stamp = [formatter stringFromDate:[NSDate date]];
    os_unfair_lock_unlock(&fmtLock);

    NSString *entry = [NSString stringWithFormat:@"%@ %@", stamp, safeMessage];
    ZLModAppendRingLine(entry);

    NSString *line = [entry stringByAppendingString:@"\n"];
    dispatch_async(ZLModFileLogQueue(), ^{
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) return;
        for (NSURL *url in ZLModFileLogURLs()) {
            @try {
                NSFileManager *manager = [NSFileManager defaultManager];
                NSString *directory = url.URLByDeletingLastPathComponent.path;
                if (directory) {
                    [manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
                }
                if (![manager fileExistsAtPath:url.path]) {
                    [data writeToURL:url options:NSDataWritingAtomic error:nil];
                } else {
                    ZLModRotateLogIfNeeded(manager, url);
                    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:url.path];
                    if (handle) {
                        @try {
                            [handle seekToEndOfFile];
                            [handle writeData:data];
                        } @catch (__unused NSException *e) {}
                        @try { [handle closeFile]; } @catch (__unused NSException *e) {}
                    }
                }
            } @catch (__unused NSException *e) {}
        }
    });
}

NSArray<NSString *> *ZLModReadRecentLogs(NSUInteger maxLines) {
    NSUInteger limit = maxLines > 0 ? maxLines : 100;
    os_unfair_lock_lock(&gLogRingLock);
    NSArray<NSString *> *ringSnapshot = gLogRingBuffer ? [gLogRingBuffer copy] : @[];
    os_unfair_lock_unlock(&gLogRingLock);

    if (ringSnapshot.count > 0) {
        if (ringSnapshot.count <= limit) return ringSnapshot;
        return [ringSnapshot subarrayWithRange:NSMakeRange(ringSnapshot.count - limit, limit)];
    }

    NSString *primary = ZLModPrimaryLogPath();
    if (primary.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:primary]) {
        return @[];
    }
    NSString *content = [NSString stringWithContentsOfFile:primary encoding:NSUTF8StringEncoding error:nil];
    if (content.length == 0) return @[];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (line.length > 0) [lines addObject:line];
    }
    if (lines.count <= limit) return lines;
    return [lines subarrayWithRange:NSMakeRange(lines.count - limit, limit)];
}

void ZLModClearLogs(void) {
    os_unfair_lock_lock(&gLogRingLock);
    [gLogRingBuffer removeAllObjects];
    os_unfair_lock_unlock(&gLogRingLock);

    dispatch_async(ZLModFileLogQueue(), ^{
        NSFileManager *manager = [NSFileManager defaultManager];
        for (NSURL *url in ZLModFileLogURLs()) {
            @try {
                [manager removeItemAtURL:url error:nil];
            } @catch (__unused NSException *e) {}
        }
    });
}

#pragma mark - Module status registry

void ZLModSetModuleStatus(NSString *moduleName, NSString *status, NSString *detail) {
    if (!moduleName || moduleName.length == 0) return;
    NSString *safeStatus = (status.length > 0) ? status : ZLModModuleStatusNotInstalled;
    NSString *safeDetail = ZLModRedactText(detail ?: @"");

    os_unfair_lock_lock(&gStatusLock);
    if (!gModuleStatuses) {
        gModuleStatuses = [NSMutableDictionary dictionary];
    }
    gModuleStatuses[moduleName] = @{
        @"status": [safeStatus copy],
        @"detail": [safeDetail copy]
    };
    os_unfair_lock_unlock(&gStatusLock);
}

NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *ZLModAllModuleStatuses(void) {
    os_unfair_lock_lock(&gStatusLock);
    NSDictionary *copy = gModuleStatuses ? [gModuleStatuses copy] : @{};
    os_unfair_lock_unlock(&gStatusLock);
    return copy;
}

#pragma mark - Session / account transition hooks

static void ZLModDispatchAccountChange(NSString *eventName) {
    ZLModInvalidateCachedAccountScope();
    ZLMOD_LOG(@"session event=%@ (account scope cache invalidated)", eventName ?: @"unknown");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ZLModAccountDidChangeNotification
                                                            object:nil
                                                          userInfo:@{ @"event": eventName ?: @"unknown" }];
    });
}

static void ZLModInstallSessionLifecycleObservers(void) {
    Class appDelegateCls = NSClassFromString(@"AppDelegate");
    if (appDelegateCls) {
        SEL logoutSel = sel_registerName("didLogout");
        if (ZLModClassHasInstanceMethod(appDelegateCls, logoutSel)) {
            IMP orig = class_getMethodImplementation(appDelegateCls, logoutSel);
            ZLModReplaceMethod(appDelegateCls, logoutSel, 0, "v", ^(id self) {
                ZLModDispatchAccountChange(@"logout");
                if (orig) ((void (*)(id, SEL))orig)(self, logoutSel);
            });
        }

        SEL loginSel = sel_registerName("didLogin");
        if (ZLModClassHasInstanceMethod(appDelegateCls, loginSel)) {
            IMP orig = class_getMethodImplementation(appDelegateCls, loginSel);
            ZLModReplaceMethod(appDelegateCls, loginSel, 0, "v", ^(id self) {
                if (orig) ((void (*)(id, SEL))orig)(self, loginSel);
                ZLModDispatchAccountChange(@"login");
            });
        }
    }

    [[NSNotificationCenter defaultCenter] addObserverForName:@"kNotifyDidLogoutAnimation"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ZLModDispatchAccountChange(@"logout_animation");
    }];
}

#pragma mark - Boot sequence

static void ZLModRunInstaller(NSString *name, void (*installer)(void)) {
    ZLMOD_LOG(@"module %@ start", name);
    @try {
        installer();
        ZLMOD_LOG(@"module %@ success", name);
    } @catch (NSException *exception) {
        ZLModSetModuleStatus(name, ZLModModuleStatusNotInstalled,
                             exception.reason ?: @"installer threw exception");
        ZLMOD_LOG(@"module %@ failed: %@", name, exception.reason);
    }
}

static void ZLModBoot(void) {
    // Exactly-once guard: DidFinishLaunching, the 5s fallback timer and the
    // 1s late-injection window check can all race — only the first wins.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (![ZLModCompatibility hostSupported]) {
            ZLMOD_LOG(@"host not supported (%@) — ZLMod idle", [ZLModCompatibility hostVersion]);
            return;
        }

        ZLMOD_LOG(@"compatibility: %@", [ZLModCompatibility supportReason]);
        ZLMOD_LOG(@"booting %@ (%@) on %@", ZLMOD_VERSION, ZLMOD_BUILD, [ZLModCompatibility hostVersion]);
        ZLMOD_LOG(@"anchors: settings=%d tabbar=%d",
                  [ZLModCompatibility anchorExists:@"SettingUI40TableViewController"],
                  [ZLModCompatibility anchorExists:@"ZaloTabBarViewController"]);

        ZLModInstallSessionLifecycleObservers();

        ZLModRunInstaller(@"URIFilter", ZLModURIFilterInstall);
        ZLModRunInstaller(@"Privacy", ZLModPrivacyInstall);
        ZLModRunInstaller(@"Ads", ZLModAdsInstall);
        ZLModRunInstaller(@"Features", ZLModFeaturesInstall);
        ZLModRunInstaller(@"Settings", ZLModSettingsInstall);
        ZLModRunInstaller(@"Glass", ZLModGlassInstall);
        ZLModRunInstaller(@"ConversationMenu", ZLModConversationMenuInstall);
        ZLModRunInstaller(@"AntiRecall", ZLModAntiRecallInstall);
        ZLModRunInstaller(@"Utilities", ZLModUtilitiesInstall);
        ZLModRunInstaller(@"Theme", ZLModThemeInstall);

        ZLMOD_LOG(@"boot complete");
    });
}

static void ZLModBootAsync(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            ZLModBoot();
        } @catch (NSException *exception) {
            ZLMOD_LOG(@"boot failed: %@", exception.reason);
        }
    });
}

static void ZLModScheduleBootAfterLaunch(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                          queue:nil
                     usingBlock:^(NSNotification *note) {
                         (void)note;
                         ZLMOD_LOG(@"boot: DidFinishLaunching notification received");
                         ZLModBootAsync();
                     }];

        // Safety net: the dylib constructor can run after the notification
        // already fired (late injection), so the observer above can miss it.
        // A 5s main-queue timer force-runs boot when no path ran it yet.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ZLMOD_LOG(@"boot: 5s fallback timer fired — ensuring boot");
            ZLModBootAsync();
        });

        // Late-injection window check: if a window already exists at
        // constructor time the host is already running — boot in 1s so the
        // visible Settings screen still gets its injection attempt.
        @try {
            if (ZLModActiveKeyWindow() != nil) {
                ZLMOD_LOG(@"boot: window already present at constructor — scheduling boot in 1s");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    ZLMOD_LOG(@"boot: 1s late-injection timer fired — ensuring boot");
                    ZLModBootAsync();
                });
            } else {
                ZLMOD_LOG(@"boot: no window at constructor time — waiting for DidFinishLaunching");
            }
        } @catch (NSException *exception) {
            ZLMOD_LOG(@"boot: window check threw (%@) — relying on notification + 5s fallback", exception.reason);
        }
    });
}

__attribute__((constructor))
static void ZLModEntry(void) {
    fprintf(stderr, "[ZLMod] loaded %s (%s)\n", [ZLMOD_VERSION UTF8String], [ZLMOD_BUILD UTF8String]);
    fflush(stderr);
    ZLMOD_LOG(@"loaded %@ (%@)", ZLMOD_VERSION, ZLMOD_BUILD);
    ZLModScheduleBootAfterLaunch();
}
