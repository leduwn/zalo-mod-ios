// language: Objective-C, file: ZLModGlass.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Glass-style tab bar material.
//
// Zalo opts out of the iOS 26 redesign (UIDesignRequiresCompatibility=YES), so the system
// tab bar cannot adopt Liquid Glass. Field testing showed that embedding a UIGlassEffect
// view inside the compat-mode UITabBar freezes the app, so ZLMod now uses only a
// UIVisualEffectView backed by systemUltraThinMaterial. The overlay is attached once to the
// real UITabBar, ignores touches, never alters navigation/safe areas/layout and the tab
// bar's original appearance is restored exactly when the feature is switched off.

#import "ZLMod.h"

typedef void (*ZLModV1Bool)(id, SEL, BOOL);

static const NSInteger kZLModGlassOverlayTag = 0x5A7C;
static __weak id gTabBarController = nil;
static __weak UIView *gOverlay = nil;
static __weak UITabBar *gStyledBar = nil;
static UITabBarAppearance *gSavedStandard = nil;
static UITabBarAppearance *gSavedScrollEdge = nil;
static BOOL gSavedAppearanceValid = NO;

NSString *ZLModGlassMaterialDescription(void) {
    return @"System blur material (UIBlurEffect)";
}

static UITabBar *ZLModFindUITabBar(UIView *root, NSUInteger depth) {
    if (!root || depth > 6) return nil;
    if ([root isKindOfClass:[UITabBar class]]) return (UITabBar *)root;
    for (UIView *sub in root.subviews) {
        UITabBar *found = ZLModFindUITabBar(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

static UITabBar *ZLModResolveTabBar(UIViewController *controller) {
    if ([controller isKindOfClass:[UITabBarController class]]) {
        return ((UITabBarController *)controller).tabBar;
    }
    return ZLModFindUITabBar(controller.view, 0);
}

static void ZLModGlassRemove(void) {
    UITabBar *bar = gStyledBar;
    if (bar && gSavedAppearanceValid) {
        bar.standardAppearance = gSavedStandard ?: [[UITabBarAppearance alloc] init];
        bar.scrollEdgeAppearance = gSavedScrollEdge;
        ZLMOD_LOG(@"glass appearance restored");
    }
    gSavedStandard = nil;
    gSavedScrollEdge = nil;
    gSavedAppearanceValid = NO;
    gStyledBar = nil;
}

static BOOL gApplying = NO;

static void ZLModGlassApply(void) {
    if (gApplying) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ZLModGlassApply(); });
        return;
    }
    if (![[ZLModPreferences shared] boolForKey:kZLModGlassTabBar]) return;
    gApplying = YES;
    @try {
        id vc = gTabBarController;
        if (![vc isKindOfClass:[UIViewController class]]) return;
        UITabBar *bar = ZLModResolveTabBar((UIViewController *)vc);
        if (!bar) return;

        if (gStyledBar == bar && gSavedAppearanceValid) {
            return;
        }

        // Keep the original appearance so switching the feature off restores it exactly.
        gSavedStandard = [bar.standardAppearance copy];
        gSavedScrollEdge = [bar.scrollEdgeAppearance copy];
        gSavedAppearanceValid = YES;
        gStyledBar = bar;

        UITabBarAppearance *glassApp = [bar.standardAppearance copy] ?: [[UITabBarAppearance alloc] init];
        [glassApp configureWithDefaultBackground];
        glassApp.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
        glassApp.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        bar.standardAppearance = glassApp;
        bar.scrollEdgeAppearance = glassApp;
        ZLMOD_LOG(@"glass appearance applied natively — %@", ZLModGlassMaterialDescription());
    } @finally {
        gApplying = NO;
    }
}

static void ZLModGlassRefreshForCurrentUI(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ZLModGlassRefreshForCurrentUI(); });
        return;
    }
    if (![[ZLModPreferences shared] boolForKey:kZLModGlassTabBar]) { ZLModGlassRemove(); return; }
    ZLModGlassApply();
}

void ZLModGlassInstall(void) {
    Class tabCls = NSClassFromString(@"ZaloTabBarViewController");
    if (!tabCls) {
        ZLModSetModuleStatus(@"Glass", ZLModModuleStatusNotInstalled,
                             @"ZaloTabBarViewController not found");
        ZLMOD_LOG(@"tab bar class not found — glass module idle");
        return;
    }

    SEL appearSel = sel_registerName("viewDidAppear:");
    IMP appearOrig = class_getMethodImplementation(tabCls, appearSel);
    BOOL hooked = ZLModReplaceMethod(tabCls, appearSel, 1, "v", ^(id self, BOOL animated) {
        ((ZLModV1Bool)appearOrig)(self, appearSel, animated);
        gTabBarController = self;
        // Defer one runloop turn so UIKit finishes its own layout pass first.
        dispatch_async(dispatch_get_main_queue(), ^{ ZLModGlassApply(); });
    });

    [[NSNotificationCenter defaultCenter] addObserverForName:ZLModPrefsDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        if ([note.object isEqualToString:kZLModGlassTabBar] ||
            [note.object isEqualToString:@"*"]) {
            ZLModGlassRefreshForCurrentUI();
        }
    }];

    ZLModSetModuleStatus(@"Glass",
                         hooked ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         ZLModGlassMaterialDescription());
    ZLMOD_LOG(@"glass installed — %@", ZLModGlassMaterialDescription());
}
