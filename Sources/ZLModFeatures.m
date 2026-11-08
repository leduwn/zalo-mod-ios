// language: Objective-C, file: ZLModFeatures.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Feature restoration — mechanisms ported (clean-room) from the feature set of
// ZaloXposed, re-anchored on iOS evidence found in the Zalo 26.11.01 binary:
//
// Profile Music: keys kProfileMusicSetting / profile_music / features@profile_music /
//   enable_rbt exist in the binary (features@profile_music at strings line 285173).
//   Getters enableProfileMusic / enableProfileMusicRBT / enableShareProfileMusic /
//   newFlagEnableProfileMusic are forced while the toggle is on; the local setter
//   is forced to YES. External keys are mirrored into standard defaults and the
//   settings App Group so BaseUserDefault-backed code reads them.
//
// Google Drive Backup: the legacy ZAGDrive* stack (ZAGDriveAuthorization,
//   ZAGDriveService, ZAGDriveListApi, ...) plus migration strings
//   (restore_gdrive_photo_csc, kCloudMigrGDriveState) ship in the binary.
//   The backup entry is bridged when the migration path returns nil:
//   _basicBackupGDriveSectionZInstantData <-> __basicBackupGDriveSectionZInstantData.
//
// More Tab: enable_tabmore key (present in the binary) is mirrored on.

#import "ZLMod.h"

#pragma mark - Generic BOOL getter forcing

static NSUInteger ZyForceBoolGetter(const char *selName, NSString *toggleKey, BOOL (^predicate)(Class)) {
    SEL sel = sel_registerName(selName);
    __block NSUInteger hooked = 0;
    ZLModEnumerateAppClasses(^(Class cls) {
        if (predicate && !predicate(cls)) return;
        if (!ZLModClassHasInstanceMethod(cls, sel)) return;
        IMP original = class_getMethodImplementation(cls, sel);
        if (ZLModReplaceMethod(cls, sel, 0, "Bc", ^BOOL(id self) {
            if ([[ZLModPreferences shared] boolForKey:toggleKey]) return YES;
            return ((BOOL (*)(id, SEL))original)(self, sel);
        })) {
            hooked++;
        }
    });
    return hooked;
}

static BOOL ZLModClassLooksProfileMusic(Class cls) {
    if (ZLModClassHasIvar(cls, "_enableProfileMusic")) return YES;
    if (ZLModClassHasIvar(cls, "_enableProfileMusicRBT")) return YES;
    if (ZLModClassHasIvar(cls, "_enableShareProfileMusic")) return YES;
    NSString *name = [NSString stringWithUTF8String:class_getName(cls)];
    return [name containsString:@"ProfileMusic"];
}

#pragma mark - Profile Music

static NSArray<NSString *> *ZLModProfileMusicExternalKeys(void) {
    return @[@"kProfileMusicSetting", @"profile_music", @"features@profile_music", @"enable_rbt"];
}

static void ZLModApplyProfileMusicState(void) {
    ZLModPreferences *prefs = [ZLModPreferences shared];
    BOOL enabled = [prefs boolForKey:kZLModRestoreProfileMusic];
    for (NSString *key in ZLModProfileMusicExternalKeys()) {
        if (enabled) {
            [prefs writeExternalValue:@YES forKey:key];
        } else {
            [prefs restoreExternalValueForKey:key];
        }
    }
}

static NSUInteger ZLModInstallProfileMusicHooks(void) {
    __block NSUInteger hooked = 0;
    NSArray<NSString *> *getters = @[@"enableProfileMusic",
                                     @"enableProfileMusicRBT",
                                     @"enableShareProfileMusic",
                                     @"newFlagEnableProfileMusic"];
    for (NSString *getter in getters) {
        hooked += ZyForceBoolGetter(getter.UTF8String, kZLModRestoreProfileMusic, ^BOOL(Class cls) {
            return ZLModClassLooksProfileMusic(cls);
        });
    }

    SEL localSetter = sel_registerName("setEnableProfileMusicLocal:");
    ZLModEnumerateAppClasses(^(Class cls) {
        if (!ZLModClassHasInstanceMethod(cls, localSetter)) return;
        IMP original = class_getMethodImplementation(cls, localSetter);
        if (ZLModReplaceMethod(cls, localSetter, 1, "v", ^(id self, BOOL value) {
            BOOL force = [[ZLModPreferences shared] boolForKey:kZLModRestoreProfileMusic];
            ((void (*)(id, SEL, BOOL))original)(self, localSetter, force ? YES : value);
        })) {
            hooked++;
        }
    });
    return hooked;
}

#pragma mark - Google Drive Backup

static NSUInteger ZLModInstallGDriveBridge(void) {
    SEL modern = sel_registerName("__basicBackupGDriveSectionZInstantData");
    SEL legacy = sel_registerName("_basicBackupGDriveSectionZInstantData");
    __block NSUInteger hooked = 0;

    ZLModEnumerateAppClasses(^(Class cls) {
        BOOL hasModern = ZLModClassHasInstanceMethod(cls, modern);
        BOOL hasLegacy = ZLModClassHasInstanceMethod(cls, legacy);
        if (!hasModern && !hasLegacy) return;

        // Capture both originals BEFORE replacing either, then call them directly —
        // never objc_msgSend on self, which would recurse into our own replacement.
        IMP modernOrig = hasModern ? class_getMethodImplementation(cls, modern) : NULL;
        IMP legacyOrig = hasLegacy ? class_getMethodImplementation(cls, legacy) : NULL;

        if (hasModern) {
            if (ZLModReplaceMethod(cls, modern, 0, "@", ^id(id self) {
                id result = ((id (*)(id, SEL))modernOrig)(self, modern);
                if (result) return result;
                if (![[ZLModPreferences shared] boolForKey:kZLModRestoreGDrive]) return nil;
                if (legacyOrig) {
                    id fallback = ((id (*)(id, SEL))legacyOrig)(self, legacy);
                    if (fallback) { ZLMOD_LOG(@"gdrive section restored (legacy path)"); return fallback; }
                }
                return nil;
            })) {
                hooked++;
            }
        }

        if (hasLegacy) {
            if (ZLModReplaceMethod(cls, legacy, 0, "@", ^id(id self) {
                id result = ((id (*)(id, SEL))legacyOrig)(self, legacy);
                if (result) return result;
                if (![[ZLModPreferences shared] boolForKey:kZLModRestoreGDrive]) return nil;
                if (modernOrig) {
                    id fallback = ((id (*)(id, SEL))modernOrig)(self, modern);
                    if (fallback) { ZLMOD_LOG(@"gdrive section restored (modern path)"); return fallback; }
                }
                return nil;
            })) {
                hooked++;
            }
        }
    });
    return hooked;
}

static void ZLModApplyGDriveState(void) {
    ZLModPreferences *prefs = [ZLModPreferences shared];
    if ([prefs boolForKey:kZLModRestoreGDrive]) {
        [prefs writeExternalValue:@YES forKey:@"restore_gdrive_photo_csc"];
    } else {
        [prefs restoreExternalValueForKey:@"restore_gdrive_photo_csc"];
    }
}

#pragma mark - More Tab

static void ZLModApplyMoreTabState(void) {
    ZLModPreferences *prefs = [ZLModPreferences shared];
    if ([prefs boolForKey:kZLModRestoreMoreTab]) {
        [prefs writeExternalValue:@YES forKey:@"enable_tabmore"];
    } else {
        [prefs restoreExternalValueForKey:@"enable_tabmore"];
    }
}

#pragma mark - Install

void ZLModFeaturesInstall(void) {
    NSUInteger pmCount = ZLModInstallProfileMusicHooks();
    NSUInteger gdCount = ZLModInstallGDriveBridge();

    ZLModApplyProfileMusicState();
    ZLModApplyGDriveState();
    ZLModApplyMoreTabState();

    [[NSNotificationCenter defaultCenter] addObserverForName:ZLModPrefsDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSString *key = note.object;
        if ([key isEqualToString:kZLModRestoreProfileMusic]) ZLModApplyProfileMusicState();
        if ([key isEqualToString:kZLModRestoreGDrive]) ZLModApplyGDriveState();
        if ([key isEqualToString:kZLModRestoreMoreTab]) ZLModApplyMoreTabState();
        if ([key isEqualToString:@"*"]) {
            ZLModApplyProfileMusicState();
            ZLModApplyGDriveState();
            ZLModApplyMoreTabState();
        }
    }];

    ZLModSetModuleStatus(@"Features",
                         (pmCount + gdCount) > 0 ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"profileMusic=%lu gdrive=%lu",
                          (unsigned long)pmCount, (unsigned long)gdCount]);
    ZLMOD_LOG(@"features installed");
}
