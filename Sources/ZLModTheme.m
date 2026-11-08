// language: Objective-C, file: ZLModTheme.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Optional theme presets and custom accent tint manager.
// Strictly neutral by default (empty preset + empty tint leaves Zalo chrome untouched)
// and captures per-window/bar baseline state before first override for clean restoration.

#import "ZLMod.h"

NSString *const ZLModThemeDidChangeNotification = @"ZLModThemeDidChangeNotification";

static const void *kZLModBaselineCapturedAssocKey = &kZLModBaselineCapturedAssocKey;
static const void *kZLModBaselineStyleAssocKey    = &kZLModBaselineStyleAssocKey;
static const void *kZLModBaselineTintAssocKey     = &kZLModBaselineTintAssocKey;
static const void *kZLModBaselineBarTintAssocKey  = &kZLModBaselineBarTintAssocKey;
static const void *kZLModBaselineStdAppAssocKey   = &kZLModBaselineStdAppAssocKey;
static const void *kZLModBaselineScrollAppAssocKey = &kZLModBaselineScrollAppAssocKey;

#pragma mark - Color utilities

static UIColor *ZLModColorFromHexString(NSString *hexString) {
    if (![hexString isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [[hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([clean hasPrefix:@"#"]) {
        clean = [clean substringFromIndex:1];
    }
    if ([clean hasPrefix:@"0X"]) {
        clean = [clean substringFromIndex:2];
    }
    if (clean.length != 6) return nil;

    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] invertedSet];
    if ([clean rangeOfCharacterFromSet:nonHex].location != NSNotFound) {
        return nil;
    }

    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&rgb]) return nil;

    CGFloat r = ((rgb >> 16) & 0xFF) / 255.0;
    CGFloat g = ((rgb >> 8) & 0xFF) / 255.0;
    CGFloat b = (rgb & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
}

static NSString *ZLModNormalizeHexString(NSString *hexString) {
    if (![hexString isKindOfClass:[NSString class]]) return @"";
    NSString *clean = [[hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([clean hasPrefix:@"#"]) clean = [clean substringFromIndex:1];
    if ([clean hasPrefix:@"0X"]) clean = [clean substringFromIndex:2];
    if (clean.length != 6) return @"";
    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] invertedSet];
    if ([clean rangeOfCharacterFromSet:nonHex].location != NSNotFound) return @"";
    return [NSString stringWithFormat:@"#%@", clean];
}

#pragma mark - View hierarchy traversal

static void ZLModEnumerateSubviewsWithClass(UIView *root, Class targetClass, void (^block)(UIView *view)) {
    if (!root || !targetClass || !block) return;
    if ([root isKindOfClass:targetClass]) {
        block(root);
    }
    for (UIView *sub in root.subviews) {
        ZLModEnumerateSubviewsWithClass(sub, targetClass, block);
    }
}

static NSArray<UIWindow *> *ZLModAllApplicationWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *win in ws.windows) {
            [windows addObject:win];
        }
    }
    return windows;
}

#pragma mark - ZLModThemeManager

@interface ZLModThemeManager ()
@property (nonatomic, assign) BOOL hasAppliedCustomTheme;
@end

@implementation ZLModThemeManager

+ (instancetype)shared {
    static ZLModThemeManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModThemeManager alloc] init];
    });
    return instance;
}

- (NSArray<NSString *> *)availablePresetIds {
    return @[
        @"",
        @"classic_blue",
        @"dark_oled",
        @"pure_black",
        @"ocean_teal"
    ];
}

- (NSString *)displayNameForPreset:(NSString *)presetId {
    if (!presetId || presetId.length == 0) return @"Mặc định hệ thống (Tắt)";
    if ([presetId isEqualToString:@"classic_blue"]) return @"Zalo Classic Blue (#0068FF)";
    if ([presetId isEqualToString:@"dark_oled"]) return @"Dark OLED (#0A84FF)";
    if ([presetId isEqualToString:@"pure_black"]) return @"Pure Black (#30D158)";
    if ([presetId isEqualToString:@"ocean_teal"]) return @"Ocean Teal (#00B4D8)";
    return presetId;
}

- (NSString *)activePresetId {
    NSString *preset = [[ZLModPreferences shared] stringForKey:kZLModThemePreset defaultValue:@""];
    if (![[self availablePresetIds] containsObject:preset]) return @"";
    return preset ?: @"";
}

- (NSString *)customTintHex {
    NSString *raw = [[ZLModPreferences shared] stringForKey:kZLModThemeTintHex defaultValue:@""];
    return ZLModNormalizeHexString(raw);
}

- (BOOL)isThemeCustomized {
    return (self.activePresetId.length > 0) || (self.customTintHex.length > 0);
}

- (BOOL)applyPresetNamed:(NSString *)presetId {
    NSString *normalized = presetId ?: @"";
    if (![[self availablePresetIds] containsObject:normalized]) {
        return NO;
    }
    [[ZLModPreferences shared] setString:normalized forKey:kZLModThemePreset];
    if (normalized.length == 0 && self.customTintHex.length == 0) {
        [self restoreBaselineChrome];
    } else {
        [self refreshAppChrome];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:ZLModThemeDidChangeNotification object:nil];
    return YES;
}

- (void)applyCustomTintHex:(NSString *)hex {
    NSString *normalized = ZLModNormalizeHexString(hex);
    if (normalized.length > 0) {
        [[ZLModPreferences shared] setString:normalized forKey:kZLModThemeTintHex];
        [self refreshAppChrome];
    } else {
        [[ZLModPreferences shared] removeObjectForKey:kZLModThemeTintHex];
        if (self.activePresetId.length == 0) {
            [self restoreBaselineChrome];
        } else {
            [self refreshAppChrome];
        }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:ZLModThemeDidChangeNotification object:nil];
}

- (void)resetTheme {
    [[ZLModPreferences shared] removeObjectForKey:kZLModThemePreset];
    [[ZLModPreferences shared] removeObjectForKey:kZLModThemeTintHex];
    [self restoreBaselineChrome];
    [[NSNotificationCenter defaultCenter] postNotificationName:ZLModThemeDidChangeNotification object:nil];
}

#pragma mark - Baseline capture & restoration

- (void)captureBaselineForWindowIfNeeded:(UIWindow *)window {
    if (!window) return;
    if ([objc_getAssociatedObject(window, kZLModBaselineCapturedAssocKey) boolValue]) return;
    objc_setAssociatedObject(window, kZLModBaselineCapturedAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, kZLModBaselineStyleAssocKey, @(window.overrideUserInterfaceStyle), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, kZLModBaselineTintAssocKey, window.tintColor ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)captureBaselineForNavBarIfNeeded:(UINavigationBar *)navBar {
    if (!navBar) return;
    if ([objc_getAssociatedObject(navBar, kZLModBaselineCapturedAssocKey) boolValue]) return;
    objc_setAssociatedObject(navBar, kZLModBaselineCapturedAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(navBar, kZLModBaselineTintAssocKey, navBar.tintColor ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(navBar, kZLModBaselineBarTintAssocKey, navBar.barTintColor ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(navBar, kZLModBaselineStdAppAssocKey, [navBar.standardAppearance copy] ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(navBar, kZLModBaselineScrollAppAssocKey, [navBar.scrollEdgeAppearance copy] ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)captureBaselineForTabBarIfNeeded:(UITabBar *)tabBar {
    if (!tabBar) return;
    if ([objc_getAssociatedObject(tabBar, kZLModBaselineCapturedAssocKey) boolValue]) return;
    objc_setAssociatedObject(tabBar, kZLModBaselineCapturedAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tabBar, kZLModBaselineTintAssocKey, tabBar.tintColor ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tabBar, kZLModBaselineBarTintAssocKey, tabBar.barTintColor ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tabBar, kZLModBaselineStdAppAssocKey, [tabBar.standardAppearance copy] ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)restoreBaselineChrome {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self restoreBaselineChrome];
        });
        return;
    }
    if (!self.hasAppliedCustomTheme) return;

    for (UIWindow *win in ZLModAllApplicationWindows()) {
        if ([objc_getAssociatedObject(win, kZLModBaselineCapturedAssocKey) boolValue]) {
            NSNumber *styleNum = objc_getAssociatedObject(win, kZLModBaselineStyleAssocKey);
            win.overrideUserInterfaceStyle = styleNum ? (UIUserInterfaceStyle)[styleNum integerValue] : UIUserInterfaceStyleUnspecified;
            id tintObj = objc_getAssociatedObject(win, kZLModBaselineTintAssocKey);
            win.tintColor = [tintObj isKindOfClass:[UIColor class]] ? (UIColor *)tintObj : nil;
        }

        ZLModEnumerateSubviewsWithClass(win, [UINavigationBar class], ^(UIView *view) {
            UINavigationBar *navBar = (UINavigationBar *)view;
            if (![objc_getAssociatedObject(navBar, kZLModBaselineCapturedAssocKey) boolValue]) return;
            id tintObj = objc_getAssociatedObject(navBar, kZLModBaselineTintAssocKey);
            id barTintObj = objc_getAssociatedObject(navBar, kZLModBaselineBarTintAssocKey);
            id stdApp = objc_getAssociatedObject(navBar, kZLModBaselineStdAppAssocKey);
            id scrollApp = objc_getAssociatedObject(navBar, kZLModBaselineScrollAppAssocKey);
            navBar.tintColor = [tintObj isKindOfClass:[UIColor class]] ? (UIColor *)tintObj : nil;
            navBar.barTintColor = [barTintObj isKindOfClass:[UIColor class]] ? (UIColor *)barTintObj : nil;
            if ([stdApp isKindOfClass:[UINavigationBarAppearance class]]) {
                navBar.standardAppearance = (UINavigationBarAppearance *)stdApp;
            }
            navBar.scrollEdgeAppearance = [scrollApp isKindOfClass:[UINavigationBarAppearance class]]
                ? (UINavigationBarAppearance *)scrollApp
                : nil;
            [navBar setNeedsLayout];
        });

        ZLModEnumerateSubviewsWithClass(win, [UITabBar class], ^(UIView *view) {
            UITabBar *tabBar = (UITabBar *)view;
            if (![objc_getAssociatedObject(tabBar, kZLModBaselineCapturedAssocKey) boolValue]) return;
            id tintObj = objc_getAssociatedObject(tabBar, kZLModBaselineTintAssocKey);
            id barTintObj = objc_getAssociatedObject(tabBar, kZLModBaselineBarTintAssocKey);
            id stdApp = objc_getAssociatedObject(tabBar, kZLModBaselineStdAppAssocKey);
            tabBar.tintColor = [tintObj isKindOfClass:[UIColor class]] ? (UIColor *)tintObj : nil;
            tabBar.barTintColor = [barTintObj isKindOfClass:[UIColor class]] ? (UIColor *)barTintObj : nil;
            if ([stdApp isKindOfClass:[UITabBarAppearance class]]) {
                tabBar.standardAppearance = (UITabBarAppearance *)stdApp;
            }
            [tabBar setNeedsLayout];
        });
    }
    self.hasAppliedCustomTheme = NO;
}

#pragma mark - Apply active preset / custom tint

- (void)refreshAppChrome {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshAppChrome];
        });
        return;
    }

    if (![self isThemeCustomized]) {
        [self restoreBaselineChrome];
        return;
    }

    NSString *preset = [self activePresetId];
    UIColor *customTint = ZLModColorFromHexString([self customTintHex]);

    UIUserInterfaceStyle targetStyle = UIUserInterfaceStyleUnspecified;
    UIColor *accentColor = [UIColor colorWithRed:0.0 green:104.0 / 255.0 blue:1.0 alpha:1.0];
    UIColor *barBgColor = nil;

    if ([preset isEqualToString:@"classic_blue"]) {
        accentColor = [UIColor colorWithRed:0.0 green:104.0 / 255.0 blue:1.0 alpha:1.0];
    } else if ([preset isEqualToString:@"dark_oled"]) {
        targetStyle = UIUserInterfaceStyleDark;
        accentColor = [UIColor colorWithRed:10.0 / 255.0 green:132.0 / 255.0 blue:1.0 alpha:1.0];
        barBgColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.08 alpha:0.96];
    } else if ([preset isEqualToString:@"pure_black"]) {
        targetStyle = UIUserInterfaceStyleDark;
        accentColor = [UIColor colorWithRed:48.0 / 255.0 green:209.0 / 255.0 blue:88.0 / 255.0 alpha:1.0];
        barBgColor = [UIColor blackColor];
    } else if ([preset isEqualToString:@"ocean_teal"]) {
        accentColor = [UIColor colorWithRed:0.0 green:180.0 / 255.0 blue:216.0 / 255.0 alpha:1.0];
    }

    if (customTint) {
        accentColor = customTint;
    }

    BOOL glassTabBarActive = [[ZLModPreferences shared] boolForKey:kZLModGlassTabBar];

    for (UIWindow *win in ZLModAllApplicationWindows()) {
        [self captureBaselineForWindowIfNeeded:win];
        win.overrideUserInterfaceStyle = targetStyle;
        win.tintColor = accentColor;

        ZLModEnumerateSubviewsWithClass(win, [UINavigationBar class], ^(UIView *view) {
            UINavigationBar *navBar = (UINavigationBar *)view;
            [self captureBaselineForNavBarIfNeeded:navBar];
            navBar.tintColor = accentColor;
            if (barBgColor) {
                UINavigationBarAppearance *app = [navBar.standardAppearance copy] ?: [[UINavigationBarAppearance alloc] init];
                [app configureWithOpaqueBackground];
                app.backgroundColor = barBgColor;
                navBar.standardAppearance = app;
                navBar.scrollEdgeAppearance = app;
                navBar.barTintColor = barBgColor;
            }
        });

        ZLModEnumerateSubviewsWithClass(win, [UITabBar class], ^(UIView *view) {
            UITabBar *tabBar = (UITabBar *)view;
            [self captureBaselineForTabBarIfNeeded:tabBar];
            tabBar.tintColor = accentColor;
            if (barBgColor && !glassTabBarActive) {
                UITabBarAppearance *app = [tabBar.standardAppearance copy] ?: [[UITabBarAppearance alloc] init];
                [app configureWithOpaqueBackground];
                app.backgroundColor = barBgColor;
                tabBar.standardAppearance = app;
                tabBar.barTintColor = barBgColor;
            }
        });
    }

    self.hasAppliedCustomTheme = YES;
}

@end

#pragma mark - Installer

void ZLModThemeInstall(void) {
    ZLModThemeManager *mgr = [ZLModThemeManager shared];

    [[NSNotificationCenter defaultCenter] addObserverForName:ZLModPrefsDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSString *key = [note.object isKindOfClass:[NSString class]] ? (NSString *)note.object : @"";
        if ([key isEqualToString:kZLModThemePreset] ||
            [key isEqualToString:kZLModThemeTintHex] ||
            [key isEqualToString:@"*"]) {
            [mgr refreshAppChrome];
        }
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        if (mgr.activePresetId.length > 0 || mgr.customTintHex.length > 0) {
            [mgr refreshAppChrome];
        }
    }];

    // Only apply on startup if the user explicitly enabled a preset or custom tint
    if (mgr.activePresetId.length > 0 || mgr.customTintHex.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [mgr refreshAppChrome];
        });
    }

    ZLModSetModuleStatus(@"Theme",
                         ZLModModuleStatusHookInstalled,
                         [NSString stringWithFormat:@"preset=%@ tint=%@",
                          mgr.activePresetId.length > 0 ? mgr.activePresetId : @"default",
                          mgr.customTintHex.length > 0 ? mgr.customTintHex : @"default"]);
    ZLMOD_LOG(@"theme installed (preset=%@)", mgr.activePresetId.length > 0 ? mgr.activePresetId : @"default");
}
