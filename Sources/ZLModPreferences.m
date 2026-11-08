// language: Objective-C, file: ZLModPreferences.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Persistent configuration. Primary suite: vn.com.vng.zingalo.zlmod.
// External values (read by Zalo itself) are mirrored into standard defaults and
// the settings App Group "group.zsettings.vn.com.vng.zingalo", with the previous
// value remembered so toggling a feature off can restore the user's data.

#import "ZLMod.h"

NSString *const ZLModPrefsDidChangeNotification = @"ZLModPrefsDidChangeNotification";

NSString *const kZLModGlassTabBar         = @"zlmod.appearance.glass";
NSString *const kZLModThemePreset         = @"zlmod.appearance.themePreset";
NSString *const kZLModThemeTintHex        = @"zlmod.appearance.themeTintHex";
NSString *const kZLModHideTyping          = @"zlmod.privacy.hideTyping";
NSString *const kZLModHideSeen            = @"zlmod.privacy.hideSeen";
NSString *const kZLModHideReadReceipts    = @"zlmod.privacy.hideReadReceipts";
NSString *const kZLModBlockTracking       = @"zlmod.privacy.blockTracking";
NSString *const kZLModBlockFirebase       = @"zlmod.privacy.blockFirebase";
NSString *const kZLModHideAds             = @"zlmod.ads.hide";
NSString *const kZLModBlockAdRequests     = @"zlmod.ads.blockRequests";
NSString *const kZLModRestoreProfileMusic = @"zlmod.features.profileMusic";
NSString *const kZLModRestoreGDrive       = @"zlmod.features.gdriveBackup";
NSString *const kZLModRestoreMoreTab      = @"zlmod.features.moreTab";
NSString *const kZLModAntiRecall          = @"zlmod.messaging.antiRecall";
NSString *const kZLModDelaySend           = @"zlmod.utilities.delaySend";
NSString *const kZLModDelaySendSeconds    = @"zlmod.utilities.delaySendSeconds";

static NSString *const kZLModSuite      = @"vn.com.vng.zingalo.zlmod";
static NSString *const kZLModGroupSuite = @"group.zsettings.vn.com.vng.zingalo";
static NSString *const kZLModPrevPrefix = @"zlmod.internal.prev.";

static NSArray<NSString *> *ZLModAllPreferenceKeys(void) {
    return @[
        kZLModGlassTabBar,
        kZLModThemePreset,
        kZLModThemeTintHex,
        kZLModHideTyping,
        kZLModHideSeen,
        kZLModHideReadReceipts,
        kZLModBlockTracking,
        kZLModBlockFirebase,
        kZLModHideAds,
        kZLModBlockAdRequests,
        kZLModRestoreProfileMusic,
        kZLModRestoreGDrive,
        kZLModRestoreMoreTab,
        kZLModAntiRecall,
        kZLModDelaySend,
        kZLModDelaySendSeconds
    ];
}

static NSArray<NSString *> *ZLModKnownExternalKeys(void) {
    return @[
        @"kProfileMusicSetting",
        @"profile_music",
        @"features@profile_music",
        @"enable_rbt",
        @"restore_gdrive_photo_csc",
        @"enable_tabmore"
    ];
}

@interface ZLModPreferences ()
@property (nonatomic, strong) NSUserDefaults *own;
@property (nonatomic, strong) NSUserDefaults *group;
@property (nonatomic, strong) NSUserDefaults *standard;
@end

@implementation ZLModPreferences

+ (instancetype)shared {
    static ZLModPreferences *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[ZLModPreferences alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _own      = [[NSUserDefaults alloc] initWithSuiteName:kZLModSuite] ?: [NSUserDefaults standardUserDefaults];
        _group    = [[NSUserDefaults alloc] initWithSuiteName:kZLModGroupSuite];
        _standard = [NSUserDefaults standardUserDefaults];
    }
    return self;
}

- (BOOL)boolForKey:(NSString *)key {
    if (!key) return NO;
    if ([self.own objectForKey:key] != nil) return [self.own boolForKey:key];
    if (self.group && [self.group objectForKey:key] != nil) return [self.group boolForKey:key];
    return NO;
}

- (void)setBool:(BOOL)value forKey:(NSString *)key {
    if (!key) return;
    [self.own setBool:value forKey:key];
    if (self.group) [self.group setBool:value forKey:key];
    [self.own synchronize];
    [self.group synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:ZLModPrefsDidChangeNotification object:key];
    ZLMOD_LOG(@"pref %@ = %@", key, value ? @"ON" : @"OFF");
}

- (double)doubleForKey:(NSString *)key defaultValue:(double)defaultValue {
    if (!key) return defaultValue;
    id val = [self.own objectForKey:key];
    if (!val && self.group) val = [self.group objectForKey:key];
    if ([val isKindOfClass:[NSNumber class]] || [val isKindOfClass:[NSString class]]) {
        return [val doubleValue];
    }
    return defaultValue;
}

- (void)setDouble:(double)value forKey:(NSString *)key {
    if (!key) return;
    [self.own setDouble:value forKey:key];
    if (self.group) [self.group setDouble:value forKey:key];
    [self.own synchronize];
    [self.group synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:ZLModPrefsDidChangeNotification object:key];
    ZLMOD_LOG(@"pref %@ = %.1f", key, value);
}

- (NSString *)stringForKey:(NSString *)key defaultValue:(NSString *)defaultValue {
    if (!key) return defaultValue;
    id val = [self.own objectForKey:key];
    if (!val && self.group) val = [self.group objectForKey:key];
    if ([val isKindOfClass:[NSString class]]) {
        return (NSString *)val;
    }
    return defaultValue;
}

- (void)setString:(NSString *)value forKey:(NSString *)key {
    if (!key) return;
    if (value) {
        [self.own setObject:value forKey:key];
        if (self.group) [self.group setObject:value forKey:key];
    } else {
        [self.own removeObjectForKey:key];
        if (self.group) [self.group removeObjectForKey:key];
    }
    [self.own synchronize];
    [self.group synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:ZLModPrefsDidChangeNotification object:key];
    ZLMOD_LOG(@"pref %@ updated", key);
}

- (void)removeObjectForKey:(NSString *)key {
    if (!key) return;
    [self.own removeObjectForKey:key];
    if (self.group) [self.group removeObjectForKey:key];
    [self.own synchronize];
    [self.group synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:ZLModPrefsDidChangeNotification object:key];
}

- (void)resetAllPreferences {
    for (NSString *extKey in ZLModKnownExternalKeys()) {
        [self restoreExternalValueForKey:extKey];
    }
    for (NSString *key in ZLModAllPreferenceKeys()) {
        [self.own removeObjectForKey:key];
        if (self.group) [self.group removeObjectForKey:key];
    }
    [self.own synchronize];
    [self.group synchronize];
    for (NSString *key in ZLModAllPreferenceKeys()) {
        [[NSNotificationCenter defaultCenter] postNotificationName:ZLModPrefsDidChangeNotification object:key];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:ZLModPrefsDidChangeNotification object:@"*"];
    ZLMOD_LOG(@"all preferences reset to default");
}

- (void)writeExternalValue:(id)value forKey:(NSString *)key {
    [self rememberExternalValueForKey:key];
    [self writeValue:value toExternalKey:key];
    ZLMOD_LOG(@"external %@ written", key);
}

- (void)restoreExternalValueForKey:(NSString *)key {
    NSString *slot = [kZLModPrevPrefix stringByAppendingString:key];
    if ([self.own objectForKey:slot] == nil) return;
    id previous = [self.own objectForKey:slot];
    if ([previous isKindOfClass:[NSNumber class]] && [previous boolValue] == NO &&
        ![self wasExternalKeyPresentBeforeWrite:key]) {
        // previous value was "absent" — remove what we wrote
        [self.standard removeObjectForKey:key];
        [self.group removeObjectForKey:key];
    } else if (previous) {
        [self writeValue:previous toExternalKey:key];
    } else {
        [self.standard removeObjectForKey:key];
        [self.group removeObjectForKey:key];
    }
    [self.own removeObjectForKey:slot];
    NSString *flag = [kZLModPrevPrefix stringByAppendingFormat:@"present.%@", key];
    [self.own removeObjectForKey:flag];
    [self.own synchronize];
    ZLMOD_LOG(@"external %@ restored", key);
}

- (BOOL)wasExternalKeyPresentBeforeWrite:(NSString *)key {
    NSString *flag = [kZLModPrevPrefix stringByAppendingFormat:@"present.%@", key];
    return [[self.own objectForKey:flag] boolValue];
}

- (void)rememberExternalValueForKey:(NSString *)key {
    NSString *slot = [kZLModPrevPrefix stringByAppendingString:key];
    if ([self.own objectForKey:slot] != nil) return; // keep the very first captured value
    id current = [self readExternalKey:key];
    NSString *flag = [kZLModPrevPrefix stringByAppendingFormat:@"present.%@", key];
    if (current) {
        [self.own setObject:current forKey:slot];
        [self.own setBool:YES forKey:flag];
    } else {
        // Nothing existed before; remember that absence with an explicit marker value.
        [self.own setObject:@NO forKey:slot];
        [self.own setBool:NO forKey:flag];
    }
    [self.own synchronize];
}

- (id)readExternalKey:(NSString *)key {
    if ([self.standard objectForKey:key] != nil) return [self.standard objectForKey:key];
    if (self.group && [self.group objectForKey:key] != nil) return [self.group objectForKey:key];
    return nil;
}

- (void)writeValue:(id)value toExternalKey:(NSString *)key {
    if (value) {
        [self.standard setObject:value forKey:key];
        if (self.group) [self.group setObject:value forKey:key];
    } else {
        [self.standard removeObjectForKey:key];
        if (self.group) [self.group removeObjectForKey:key];
    }
    [self.standard synchronize];
    [self.group synchronize];
}

@end
