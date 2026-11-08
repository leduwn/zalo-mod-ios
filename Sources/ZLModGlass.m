// language: Objective-C, file: ZLModGlass.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Liquid Glass tab bar material.
//
// Zalo 26.11.01 opts out of the iOS 26 redesign (UIDesignRequiresCompatibility=YES),
// so the *system* tab bar cannot adopt Liquid Glass while that key is present.
// ZLMod therefore applies the two available honest tiers at runtime:
//   Tier REAL_GLASS — UIVisualEffectView backed by UIGlassEffect (iOS 26+ runtime);
//   Tier BLUR       — UIVisualEffectView backed by systemUltraThinMaterial.
// The overlay sits inside the tab bar bounds, ignores touches, and never alters
// navigation, safe areas or layout.

#import "ZLMod.h"

typedef void (*ZLModV0)(id, SEL);
typedef void (*ZLModV1Bool)(id, SEL, BOOL);

static const NSInteger kZLModGlassOverlayTag = 0x5A7C;
static __weak id gTabBarController = nil;
static NSString *gMaterialDescription = nil;

NSString *ZLModGlassMaterialDescription(void) {
    if (gMaterialDescription) return gMaterialDescription;
    Class glass = NSClassFromString(@"UIGlassEffect");
    gMaterialDescription = (glass && [glass respondsToSelector:NSSelectorFromString(@"effectWithStyle:")])
        ? @"Liquid Glass (UIGlassEffect)"
        : @"System blur material";
    return gMaterialDescription;
}

static UIVisualEffect *ZLModMakeEffect(void) {
    Class glass = NSClassFromString(@"UIGlassEffect");
    SEL styleSel = NSSelectorFromString(@"effectWithStyle:");
    if (glass && [glass respondsToSelector:styleSel]) {
        IMP imp = class_getMethodImplementation(object_getClass(glass), styleSel);
        if (imp) {
            UIVisualEffect *(*fn)(id, SEL, NSInteger) = (void *)imp;
            UIVisualEffect *effect = fn(glass, styleSel, 0); // .regular
            if (effect) {
                @try { [effect setValue:[UIColor colorWithWhite:1.0 alpha:0.05] forKey:@"tintColor"]; } @catch (__unused NSException *e) {}
                return effect;
            }
        }
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
}

static UIView *ZLModFindTabBarView(UIView *root) {
    NSString *rootName = NSStringFromClass(object_getClass(root)).lowercaseString;
    if ([rootName containsString:@"tabbar"] && root.bounds.size.height >= 30.0 &&
        root.bounds.size.width >= 200.0 && root.hidden == NO) {
        return root;
    }
    for (UIView *sub in root.subviews) {
        UIView *found = ZLModFindTabBarView(sub);
        if (found) return found;
    }
    // Heuristic fallback: bottom-docked bar-shaped subview.
    CGRect rootBounds = root.bounds;
    for (UIView *sub in root.subviews) {
        CGRect f = sub.frame;
        BOOL bottom = CGRectGetMaxY(f) >= rootBounds.size.height - 2.0;
        BOOL wide = f.size.width >= rootBounds.size.width - 2.0;
        BOOL barShaped = f.size.height >= 30.0 && f.size.height <= 120.0;
        if (bottom && wide && barShaped && sub.hidden == NO) return sub;
    }
    return nil;
}

static UIView *ZLModFindOverlay(UIView *root) {
    if (root.tag == kZLModGlassOverlayTag) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = ZLModFindOverlay(sub);
        if (found) return found;
    }
    return nil;
}

static void ZLModGlassRemove(void) {
    id vc = gTabBarController;
    if (!vc) return;
    UIView *root = [vc isKindOfClass:[UIViewController class]] ? [vc view] : nil;
    if (!root) return;
    UIView *overlay = ZLModFindOverlay(root);
    if (overlay) {
        [overlay removeFromSuperview];
        ZLMOD_LOG(@"glass overlay removed");
    }
}

static BOOL gApplying = NO;

static void ZLModGlassApply(void) {
    if (gApplying) return;
    if (![[ZLModPreferences shared] boolForKey:kZLModGlassTabBar]) return;
    gApplying = YES;
    @try {
        id vc = gTabBarController;
        if (![vc isKindOfClass:[UIViewController class]]) return;
        UIViewController *controller = (UIViewController *)vc;
        UIView *root = controller.view;
        if (!root) return;

        UIView *bar = ZLModFindTabBarView(root);
        if (!bar) return;

        UIView *overlay = ZLModFindOverlay(root);
        if (overlay && overlay.superview == bar) {
            overlay.frame = bar.bounds;
            return;
        }

        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:ZLModMakeEffect()];
        glass.tag = kZLModGlassOverlayTag;
        glass.frame = bar.bounds;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO; // never intercepts navigation touches
        glass.layer.cornerRadius = bar.layer.cornerRadius;
        glass.layer.masksToBounds = YES;

        UIView *hairline = [[UIView alloc] initWithFrame:CGRectMake(0, 0, bar.bounds.size.width, 0.5)];
        hairline.backgroundColor = [UIColor separatorColor];
        hairline.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
        hairline.alpha = 0.6;
        [glass.contentView addSubview:hairline];

        [bar insertSubview:glass atIndex:0];
        ZLMOD_LOG(@"glass overlay applied — %@", ZLModGlassMaterialDescription());
    } @finally {
        gApplying = NO;
    }
}

static void ZLModGlassRefreshForCurrentUI(void) {
    if (!gTabBarController) {
        UIWindow *window = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) { window = w; break; }
                }
            }
            if (window) break;
        }
        if (!window) return;
        UIViewController *root = window.rootViewController;
        if (!root) return;
        NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *cursor = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if ([NSStringFromClass(object_getClass(cursor)) containsString:@"ZaloTabBarViewController"]) {
                gTabBarController = cursor;
                break;
            }
            [stack addObjectsFromArray:cursor.childViewControllers];
            if (cursor.presentedViewController) [stack addObject:cursor.presentedViewController];
        }
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
        ZLModGlassApply();
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
